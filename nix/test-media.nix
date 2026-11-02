# VM test for deploy/nixos/media.nix with dnscount's module:
#   nix build .#checks.x86_64-linux.media
{ pkgs, ... }:
let
  # The test framework numbers nodes on eth1 in name order.
  client = "192.168.1.1";
  outsider = "192.168.1.2";
  server = "192.168.1.3";

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
  };
in
{
  name = "media";

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
    # Only the client is allowed in, so the outsider can test the firewall.
    services.mediaStack = {
      lans = [ "${client}/32" ];
      serverAddress = server;
    };
    environment.systemPackages = [ pkgs.curl pkgs.iproute2 pkgs.procps pkgs.util-linux pkgs.shadow ];
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
