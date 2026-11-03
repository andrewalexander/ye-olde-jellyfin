# VM test for deploy/nixos/media.nix with dnscount's module:
#   nix build .#checks.x86_64-linux.media
{ pkgs, ... }:
let
  # The test framework numbers nodes on eth1 in name order.
  attacker = "192.168.1.1";
  client = "192.168.1.2";
  outsider = "192.168.1.3";
  server = "192.168.1.4";

  badLogin = pkgs.writeShellScript "bad-login" ''
    ${pkgs.curl}/bin/curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H 'Authorization: MediaBrowser Client="test", Device="test", DeviceId="test", Version="1"' \
      -d '{"Username":"nobody","Pw":"wrong"}' \
      http://${server}:8096/Users/AuthenticateByName
  '';

  # What the Jellyfin apps broadcast to find a server.
  discover = pkgs.writeText "discover.py" ''
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    s.sendto(b"who is JellyfinServer?", ("${server}", 7359))
    print(s.recvfrom(4096)[0].decode())
  '';

  clientTools = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.curl pkgs.python3 ];
    networking.firewall.enable = false;
    networking.hosts.${server} = [ "jellyfin.test" ];
  };

  localAddress = pkgs.writeShellScript "local-address" ''
    ${pkgs.curl}/bin/curl -fsSk --max-time 10 "$1/System/Info/Public" | ${pkgs.jq}/bin/jq -r .LocalAddress
  '';
in
{
  name = "media";

  nodes.attacker = clientTools;
  nodes.client = clientTools;
  nodes.outsider = clientTools;

  nodes.server = { pkgs, ... }: {
    imports = [ ./module.nix ../deploy/nixos/media.nix ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 8192; # Jellyfin won't start with under 2G free
    services.dnscount = {
      enable = true;
      package = pkgs.callPackage ./package.nix { };
    };
    # The outsider isn't allowed in, to test the firewall. The attacker is, but
    # isn't exempt from bans.
    services.mediaStack = {
      lans = [ "${client}/32" "${attacker}/32" ];
      loginBanExempt = [ "${client}/32" ];
      serverAddress = server;
      domain = "jellyfin.test";
    };
    # A local certificate, since this test can't reach Let's Encrypt.
    services.caddy.virtualHosts."jellyfin.test".extraConfig = "tls internal";
    environment.systemPackages = [ pkgs.curl pkgs.iproute2 pkgs.procps pkgs.util-linux pkgs.shadow pkgs.python3 ];
  };

  testScript = ''
    start_all()
    server.wait_for_unit("jellyfin.service")
    server.wait_for_unit("caddy.service")
    server.wait_for_unit("dnscount-serve.service")
    # A temporary setup server answers on this port during first-run migrations,
    # and then Jellyfin returns 503 until startup finishes, so wait for the real thing.
    server.wait_until_succeeds("curl -fsS --max-time 10 http://127.0.0.1:8097/System/Info/Public | grep -q ServerName", timeout=900)
    server.log("Jellyfin is fully up on 8097")

    with subtest("Caddy is on 8096, Jellyfin moved to 8097"):
        listening = server.succeed("ss -ltnp")
        print(listening)
        assert "caddy" in [l for l in listening.splitlines() if ":8096 " in l][0], listening
        assert "ellyfin" in [l for l in listening.splitlines() if ":8097 " in l][0], listening

    with subtest("LAN clients reach Jellyfin through Caddy"):
        client.wait_until_succeeds("curl -fsS --max-time 5 http://${server}:8096/System/Info/Public | grep -q ServerName", timeout=60)

    with subtest("discovery answers, and hands out the address Caddy is on"):
        out = client.wait_until_succeeds("python3 ${discover}", timeout=120)
        print(out)
        assert "http://${server}:8096" in out, out

    with subtest("clients get back the address they used, not Jellyfin's own port"):
        out = client.succeed("${localAddress} http://${server}:8096").strip()
        assert out == "http://${server}:8096", out
        out = client.wait_until_succeeds("${localAddress} https://jellyfin.test", timeout=60).strip()
        assert out == "https://jellyfin.test", out
        # The same name over plain HTTP gets redirected by Caddy rather than served.
        code = client.succeed("curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://jellyfin.test/")
        assert code in ("301", "308"), code

    with subtest("the HTTPS site is the only thing open to everyone"):
        code = outsider.succeed("curl -skS --max-time 10 -o /dev/null -w '%{http_code}' https://jellyfin.test/System/Info/Public")
        assert code == "200", code
        for port in [8096, 8097, 9091, 9117, 8080, 8081]:
            outsider.fail(f"curl -sS --max-time 5 http://${server}:{port}/")

    with subtest("Jellyfin itself isn't reachable from the LAN"):
        client.fail("curl -sS --max-time 5 http://${server}:8097/System/Info/Public")

    with subtest("the firewall only lets in the listed networks"):
        outsider.fail("curl -sS --max-time 5 http://${server}:8096/System/Info/Public")
        outsider.fail("curl -sS --max-time 5 http://${server}:9091/")
        outsider.fail("python3 ${discover}")
        code = client.succeed("curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://${server}:9091/ || true")
        assert code == "502", code  # Caddy answers; nothing's behind it in this test

    with subtest("requests land in dnscount with the real client, and no tokens"):
        client.succeed("curl -sS --max-time 5 -o /dev/null 'http://${server}:8096/Items/1/Images?api_key=sekrit&maxWidth=300'")
        server.wait_until_succeeds("curl -fsS 'http://127.0.0.1:8081/api/hits?ip=${client}' | grep -q 'api_key=REDACTED'", timeout=60)
        server.fail("grep -q sekrit /var/log/caddy/access.log")
        out = server.succeed("curl -fsS 'http://127.0.0.1:8081/api/hits?limit=500'")
        assert "sekrit" not in out, out

    with subtest("network.xml has the settings the module manages"):
        conf = server.succeed("cat /var/lib/jellyfin/config/network.xml")
        assert "<InternalHttpPort>8097</InternalHttpPort>" in conf, conf
        assert "<string>127.0.0.1</string>" in conf, conf
        assert "<EnablePublishedServerUriByRequest>true<" in conf, conf

    with subtest("Jellyfin runs as its own user, and can use the shared library"):
        pid = server.succeed("systemctl show -p MainPID --value jellyfin").strip()
        out = server.succeed(f"ps -o user= -p {pid}").strip()
        assert out == "jellyfin", out
        groups = server.succeed(f"grep ^Groups /proc/{pid}/status")
        gid = server.succeed("getent group media | cut -d: -f3").strip()
        assert gid in groups.split(), groups
        server.succeed("install -d -m 2775 -o root -g media /srv/library")
        server.succeed("install -m 0640 -o root -g media /dev/null /srv/library/movie.mkv")
        server.succeed("runuser -u jellyfin -- cat /srv/library/movie.mkv")
        server.succeed("runuser -u jellyfin -- touch /srv/library/movie.nfo")
        server.fail("runuser -u jellyfin -- cat /etc/shadow")

    with subtest("Jellyfin can't reach the torrent UIs, while other services can"):
        # Built like vpn-netns.nix: the UIs live in their own namespace behind a veth.
        server.succeed(
            "ip netns add ui",
            "ip link add v0 type veth peer name v1 netns ui",
            "ip addr add 10.200.0.1/30 dev v0",
            "ip link set v0 up",
            "ip -n ui link set lo up",
            "ip -n ui addr add 10.200.0.2/30 dev v1",
            "ip -n ui link set v1 up",
            "systemd-run --unit=ui-stand-in ${pkgs.iproute2}/bin/ip netns exec ui ${pkgs.python3}/bin/python3 -m http.server 9091 --bind 10.200.0.2",
        )
        server.wait_until_succeeds("curl -fsS --max-time 5 -o /dev/null http://10.200.0.2:9091/ || { journalctl -u ui-stand-in --no-pager -n 5 >&2; false; }", timeout=60)
        # The same request from inside Jellyfin's cgroup, where its IP rules apply.
        cgroup = "/sys/fs/cgroup/system.slice/jellyfin.service/cgroup.procs"
        server.fail(f"sh -c 'echo $$ > {cgroup}; exec curl -fsS --max-time 5 -o /dev/null http://10.200.0.2:9091/'")
        server.succeed(f"sh -c 'echo $$ > {cgroup}; exec curl -fsS --max-time 10 -o /dev/null http://127.0.0.1:8097/System/Info/Public'")
        client.succeed("curl -fsS --max-time 10 http://${server}:8096/System/Info/Public | grep -q ServerName")
        client.succeed("curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://${server}:9091/ | grep -q 200")

    with subtest("repeated bad logins get an IP banned, without touching exempt clients"):
        server.wait_for_unit("fail2ban.service")
        server.succeed("fail2ban-client status jellyfin")
        for _ in range(6):
            code = client.succeed("${badLogin}")
            assert code == "401", code
        for i in range(6):
            attacker.execute("${badLogin}")
        print(server.succeed("journalctl -u jellyfin --no-pager -o cat | grep 'has been denied' | tail -3"))
        server.wait_until_succeeds("fail2ban-client status jellyfin | grep -q '${attacker}'", timeout=120)
        out = server.succeed("fail2ban-client status jellyfin")
        print(out)
        assert "${client}" not in out, out
        attacker.fail("curl -sS --max-time 5 http://${server}:8096/System/Info/Public")
        client.succeed("curl -fsS --max-time 10 http://${server}:8096/System/Info/Public | grep -q ServerName")
        server.succeed("fail2ban-client set jellyfin unbanip ${attacker}")
        attacker.wait_until_succeeds("curl -fsS --max-time 5 http://${server}:8096/System/Info/Public | grep -q ServerName", timeout=30)

    with subtest("scanners get banned, while Jellyfin's own 404s don't count"):
        server.succeed("fail2ban-client status caddy-probe", "fail2ban-client status caddy-404")
        # Well past caddy-404's limit of 20, but under paths Jellyfin clients 404 on.
        for i in range(25):
            attacker.succeed(f"curl -sS --max-time 5 -o /dev/null http://${server}:8096/web/missing-{i}.js")
        for path in ["/.env", "/.git/config"]:
            attacker.succeed(f"curl -sS --max-time 5 -o /dev/null http://${server}:8096{path}")
        server.wait_until_succeeds("fail2ban-client status caddy-probe | grep -q '${attacker}'", timeout=60)
        # By now fail2ban has read past the 404s above.
        out = server.succeed("fail2ban-client status caddy-404")
        assert "${attacker}" not in out, out
        attacker.fail("curl -sS --max-time 5 http://${server}:8096/System/Info/Public")
        client.succeed("curl -fsS --max-time 10 http://${server}:8096/System/Info/Public | grep -q ServerName")
        server.succeed("fail2ban-client set caddy-probe unbanip ${attacker}")
        attacker.wait_until_succeeds("curl -fsS --max-time 5 http://${server}:8096/System/Info/Public | grep -q ServerName", timeout=30)

    with subtest("data left by a previous user is taken over on start"):
        server.succeed("systemctl stop jellyfin")
        server.succeed("useradd oldowner")
        server.succeed("chown -R oldowner:users /var/lib/jellyfin /var/cache/jellyfin")
        server.succeed("systemctl start jellyfin")
        server.wait_until_succeeds("curl -fsS --max-time 10 http://127.0.0.1:8097/System/Info/Public | grep -q ServerName", timeout=900)
        assert server.succeed("find /var/lib/jellyfin /var/cache/jellyfin ! -user jellyfin | wc -l").strip() == "0"
        assert server.succeed("find /var/lib/jellyfin /var/cache/jellyfin ! -group jellyfin | wc -l").strip() == "0"
  '';
}
