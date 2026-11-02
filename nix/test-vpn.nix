# VM test for deploy/nixos/vpn-netns.nix against a fake Mullvad server:
#   nix build .#checks.x86_64-linux.vpn
{ pkgs, ... }:
let
  keys = import "${pkgs.path}/nixos/tests/wireguard/snakeoil-keys.nix";
  # The test framework numbers nodes on eth1 in name order.
  exitReal = "192.168.1.1";
  serverReal = "192.168.1.2";

  # Replies with the address that connected, so the test can see the route taken.
  whoami = pkgs.writeText "whoami.py" ''
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.end_headers()
            self.wfile.write(self.client_address[0].encode())
    HTTPServer(("0.0.0.0", 8000), H).serve_forever()
  '';
in
{
  name = "vpn-netns";

  nodes.exit = { ... }: {
    networking.firewall.enable = false;
    networking.wireguard.interfaces.wg0 = {
      ips = [ "10.64.0.1/16" ];
      listenPort = 51820;
      privateKeyFile = toString (pkgs.writeText "exit.key" keys.peer0.privateKey);
      peers = [{ publicKey = keys.peer1.publicKey; allowedIPs = [ "10.66.0.2/32" ]; }];
    };
    services.dnsmasq = {
      enable = true;
      settings = {
        listen-address = "10.64.0.1";
        bind-dynamic = true;
        address = "/probe.example/10.64.0.1";
        log-queries = true;
      };
    };
    systemd.services.dnsmasq.after = [ "wireguard-wg0.service" ];
    systemd.services.whoami = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${whoami}";
    };
  };

  nodes.server = { pkgs, ... }: {
    imports = [ ../deploy/nixos/vpn-netns.nix ];
    virtualisation.memorySize = 2048;
    services.vpnNamespace = {
      address = [ "10.66.0.2/32" ];
      publicKey = keys.peer0.publicKey;
      endpoint = "${exitReal}:51820";
      privateKeyFile = toString (pkgs.writeText "server.key" keys.peer1.privateKey);
      downloadDir = "/mnt/media/Downloads";
      transmissionCredentialsFile = toString (pkgs.writeText "transmission.json" (builtins.toJSON {
        rpc-username = "tester";
        rpc-password = "test-password";
      }));
    };
    fileSystems."/mnt/media" = { device = "tmpfs"; fsType = "tmpfs"; };
    environment.systemPackages = [ pkgs.curl pkgs.iproute2 pkgs.nftables pkgs.util-linux pkgs.wireguard-tools ];
  };

  testScript = ''
    start_all()
    exit.wait_for_unit("whoami.service")
    exit.wait_for_unit("dnsmasq.service")
    exit.wait_for_open_port(8000)

    with subtest("the tunnel is in the namespace, and not on the host"):
        server.wait_for_unit("wireguard-wg-mullvad.target")
        server.wait_for_unit("vpn-veth.service")
        server.succeed("ip -n vpn link show wg-mullvad")
        server.fail("ip link show wg-mullvad")
        route = server.succeed("ip -n vpn route")
        print(route)
        assert "default dev wg-mullvad" in route, route
        assert "10.200.0.0/30" in route, route
        assert len(route.strip().splitlines()) == 2, route

    with subtest("namespace traffic goes through the tunnel, host traffic doesn't"):
        out = server.wait_until_succeeds("ip netns exec vpn curl -fsS --max-time 5 http://${exitReal}:8000/")
        assert out == "10.66.0.2", out
        out = server.succeed("curl -fsS --max-time 5 http://${exitReal}:8000/")
        assert out == "${serverReal}", out

    with subtest("the services are in the namespace and survive their sandboxes"):
        server.wait_for_unit("transmission.service")
        server.wait_for_unit("jackett.service")
        for unit in ["transmission", "jackett"]:
            pid = server.succeed(f"systemctl show -p MainPID --value {unit}").strip()
            assert server.succeed(f"readlink /proc/{pid}/ns/net") == server.succeed("ip netns exec vpn readlink /proc/self/ns/net"), unit

    with subtest("their DNS goes through the tunnel, not nscd"):
        # nscd lives in the main namespace, and this name only exists on the
        # tunnel's resolver, so resolving it proves which path the lookup took.
        for unit in ["transmission", "jackett"]:
            pid = server.succeed(f"systemctl show -p MainPID --value {unit}").strip()
            conf = server.succeed(f"nsenter -t {pid} -m cat /etc/resolv.conf")
            assert "nameserver 10.64.0.1" in conf, conf
            code, _ = server.execute(f"nsenter -t {pid} -m ls /run/nscd/socket")
            print(f"{unit}: nscd socket visible = {code == 0}")
            out = server.succeed(f"nsenter -t {pid} -m -n getent ahostsv4 {unit}.probe.example")
            assert "10.64.0.1" in out, out
            exit.wait_until_succeeds(f"journalctl -u dnsmasq | grep -q 'query.*{unit}.probe.example'")

    with subtest("the web UIs answer from the host"):
        # 401 without the password, and 409 (a normal session handshake) with it.
        server.wait_until_succeeds("curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://10.200.0.2:9091/transmission/rpc | grep -q 401", timeout=120)
        out = server.succeed("curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -u tester:test-password http://10.200.0.2:9091/transmission/rpc")
        assert out == "409", out
        out = server.succeed("curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -u tester:wrong http://10.200.0.2:9091/transmission/rpc")
        assert out == "401", out
        server.wait_until_succeeds("curl -sS --max-time 5 -o /dev/null http://10.200.0.2:9117/", timeout=240)

    with subtest("downloads land on the drive, group-writable"):
        out = server.succeed("stat -c '%a %U %G' /mnt/media/Downloads").strip()
        assert out == "2775 transmission media", out

    with subtest("nothing connects in through the tunnel"):
        exit.fail("curl -sS --max-time 5 http://10.66.0.2:9117/")

    with subtest("kill switch: with the tunnel down, nothing gets out"):
        server.succeed("ip -n vpn link set wg-mullvad down")
        server.fail("ip netns exec vpn curl -sS --max-time 5 http://${exitReal}:8000/")
        server.fail("ip netns exec vpn curl -sS --max-time 5 http://${serverReal}:22/")
        server.succeed("ip -n vpn link set wg-mullvad up")
        server.succeed("ip -n vpn route replace default dev wg-mullvad")
        out = server.wait_until_succeeds("ip netns exec vpn curl -fsS --max-time 5 http://${exitReal}:8000/")
        assert out == "10.66.0.2", out

    with subtest("the services stop when the tunnel's unit does"):
        server.succeed("systemctl stop wireguard-wg-mullvad.service")
        server.wait_until_succeeds("! systemctl is-active transmission.service")
        server.wait_until_succeeds("! systemctl is-active jackett.service")
  '';
}
