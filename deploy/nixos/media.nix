# Jellyfin behind Caddy, with every request logged for dnscount, plus LAN-only
# front doors for the Transmission/Jackett UIs that live in the vpn namespace
# (vpn-netns.nix). Import alongside dnscount's module. Fill in the `let` block.
#
# Jellyfin settings that live in its own config, not here (Dashboard -> Networking):
#   Local HTTP port:        8097
#   Bind to local address:  127.0.0.1       (Caddy is the only way in)
#   Known proxies:          127.0.0.1       (so it sees real client IPs)
#   Published server URIs:  <each LAN>=http://<server LAN IP>:8096, all=https://<domain>
#   Enable auto discovery:  on              (Roku finds the server via UDP 7359)
# If discovery stops answering with Jellyfin bound to 127.0.0.1, bind it to the
# LAN IP on 8096 instead and drop the :8096 Caddy block (LAN playback is then
# only in Jellyfin's own logs). See docs/homelab.md.
{ config, lib, pkgs, ... }:

let
  domain = "jellyfin.example.com"; # a CNAME to your DDNS name
  lans = "192.168.1.0/24"; # every network allowed in, comma-separated

  jellyfin = "127.0.0.1:8097";
  vpnUIs = "10.200.0.2"; # vpn-netns.nix nsSide

  # The access log dnscount-caddy-log tails (the inside of Caddy's `log {}`;
  # it replaces the module's default per-site log). Jellyfin clients put
  # credentials in URLs and headers; strip them before they reach disk.
  # dnscount redacts the same keys again on ingest.
  accessLog = ''
    output file /var/log/caddy/access.log {
      mode 640
    }
    format filter {
      request>uri query {
        replace api_key REDACTED
        replace ApiKey REDACTED
        replace X-Emby-Token REDACTED
        replace token REDACTED
      }
      request>headers>Referer regexp "(?i)(api_?key|token)=[^&#]*" "$1=REDACTED"
      request>headers>X-Emby-Authorization delete
      request>headers>X-Emby-Token delete
      request>headers>X-Mediabrowser-Token delete
      wrap json
    }
  '';

  lanOnly = ''
    @notlan not remote_ip private_ranges
    abort @notlan
  '';
in
{
  services.jellyfin = {
    enable = true;
    openFirewall = false; # firewall below opens only what's needed, LAN only
  };

  services.caddy = {
    enable = true;
    # When a VPS proxies in front of this host (VPS -> router -> here), use ONE of:
    #  - VPS runs an HTTP proxy: trust it, so client_ip is the real visitor.
    #      servers { trusted_proxies static <vps-ip-or-tunnel-subnet> }
    #    and add the same range to services.dnscount.trustedProxies.
    #  - VPS passes TCP through (TLS stays end to end): read the PROXY header.
    #      servers { listener_wrappers { proxy_protocol { allow <vps-ip>/32 } tls } }
    #    and restrict the router's port forward to the VPS's address.
    # globalConfig = ''
    #   servers { ... }
    # '';

    virtualHosts = {
      # Internet and LAN-by-name (split-horizon DNS points the name at serverIP).
      ${domain} = {
        logFormat = accessLog;
        extraConfig = "reverse_proxy ${jellyfin}";
      };

      # The port LAN apps (Roku) expect after discovery. Plain HTTP, LAN only.
      "http://:8096" = {
        logFormat = accessLog;
        extraConfig = lanOnly + "reverse_proxy ${jellyfin}";
      };

      # Torrent UIs: LAN only, never on the public site.
      "http://:9091" = {
        logFormat = accessLog;
        extraConfig = lanOnly + "reverse_proxy ${vpnUIs}:9091";
      };
      "http://:9117" = {
        logFormat = accessLog;
        extraConfig = lanOnly + "reverse_proxy ${vpnUIs}:9117";
      };
    };
  };

  services.dnscount.caddyLog.enable = true;

  networking.nftables.enable = true;
  networking.firewall = {
    allowedTCPPorts = [ 80 443 ]; # public, via the router's port forward
    extraInputRules = ''
      ip saddr { ${lans} } tcp dport { 8096, 9091, 9117 } accept
      ip saddr { ${lans} } udp dport 7359 accept
    '';
  };
}
