# Jellyfin behind Caddy, with every request logged for dnscount, plus LAN-only
# front doors for the Transmission/Jackett UIs in the vpn namespace
# (vpn-netns.nix). Import alongside dnscount's module.
#
# This module owns Jellyfin's network.xml and rewrites it on every start, so
# change those settings here rather than in Dashboard -> Networking.
#
# Jellyfin listens on 8097 on all addresses, because client discovery (UDP 7359,
# how a Roku finds it) mustn't depend on a bind address. The firewall leaves 8097
# closed, so Caddy on 8096 is still the only way in.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types concatMapStrings concatStringsSep;
  cfg = config.services.mediaStack;

  jellyfinPort = 8097;
  jellyfin = "127.0.0.1:${toString jellyfinPort}";
  vpnUIs = "10.200.0.2"; # vpn-netns.nix nsSide
  lanPorts = [ 8096 9091 9117 ];

  strings = l: concatMapStrings (s: "<string>${s}</string>") l;

  # Jellyfin ignores a subnet entry unless this host has an interface in that
  # subnet, so entries can't cover clients on another VLAN. "all" can. With a
  # domain, LAN clients on other VLANs need the name or the address by hand.
  lanUri = "http://${cfg.serverAddress}:8096";
  publishedUris =
    if cfg.domain == null then [ "all=${lanUri}" ]
    else map (lan: "${lan}=${lanUri}") cfg.lans ++ [ "external=https://${cfg.domain}" ];

  networkXml = pkgs.writeText "jellyfin-network.xml" ''
    <?xml version="1.0" encoding="utf-8"?>
    <NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <BaseUrl />
      <EnableHttps>false</EnableHttps>
      <RequireHttps>false</RequireHttps>
      <InternalHttpPort>${toString jellyfinPort}</InternalHttpPort>
      <InternalHttpsPort>8920</InternalHttpsPort>
      <PublicHttpPort>8096</PublicHttpPort>
      <PublicHttpsPort>8920</PublicHttpsPort>
      <AutoDiscovery>true</AutoDiscovery>
      <EnableIPv4>true</EnableIPv4>
      <EnableIPv6>false</EnableIPv6>
      <EnableRemoteAccess>true</EnableRemoteAccess>
      <LocalNetworkSubnets>${strings cfg.lans}</LocalNetworkSubnets>
      <LocalNetworkAddresses />
      <KnownProxies><string>127.0.0.1</string></KnownProxies>
      <IgnoreVirtualInterfaces>true</IgnoreVirtualInterfaces>
      <VirtualInterfaceNames><string>veth</string></VirtualInterfaceNames>
      <EnablePublishedServerUriByRequest>false</EnablePublishedServerUriByRequest>
      <PublishedServerUriBySubnet>${strings publishedUris}</PublishedServerUriBySubnet>
      <RemoteIPFilter />
      <IsRemoteIPFilterBlacklist>false</IsRemoteIPFilterBlacklist>
    </NetworkConfiguration>
  '';

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
  lanSite = upstream: {
    logFormat = accessLog;
    extraConfig = lanOnly + "reverse_proxy ${upstream}";
  };
in
{
  options.services.mediaStack = {
    lans = mkOption {
      type = types.listOf types.str;
      example = [ "192.168.1.0/24" ];
      description = "Networks allowed to reach Jellyfin, its discovery, and the torrent UIs.";
    };
    serverAddress = mkOption {
      type = types.str;
      example = "192.168.1.10";
      description = "This host's LAN address, which Jellyfin hands out through discovery.";
    };
    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "jellyfin.example.com";
      description = ''
        Public name for Jellyfin, a CNAME to your DDNS name. Setting it adds a
        TLS site and opens 80 and 443; it's only reachable from the internet
        once the router forwards them.
      '';
    };
  };

  config = {
    services.jellyfin = {
      enable = true;
      openFirewall = false; # the firewall rules below open only what's needed
    };
    systemd.services.jellyfin.preStart = ''
      install -m 0640 ${networkXml} ${config.services.jellyfin.configDir}/network.xml
    '';

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
        # The port LAN apps (Roku) expect after discovery. Plain HTTP.
        "http://:8096" = lanSite jellyfin;
        # Torrent UIs: never on the public site.
        "http://:9091" = lanSite "${vpnUIs}:9091";
        "http://:9117" = lanSite "${vpnUIs}:9117";
      } // lib.optionalAttrs (cfg.domain != null) {
        # Internet and LAN-by-name (split-horizon DNS points the name at this host).
        ${cfg.domain} = {
          logFormat = accessLog;
          extraConfig = "reverse_proxy ${jellyfin}";
        };
      };
    };
    # Jellyfin has to let go of 8096 before Caddy can bind it.
    systemd.services.caddy.after = [ "jellyfin.service" ];

    services.dnscount.caddyLog.enable = true;

    networking.firewall =
      let
        ports = concatStringsSep "," (map toString lanPorts);
        nftPorts = concatStringsSep ", " (map toString lanPorts);
      in
      {
        allowedTCPPorts = lib.optionals (cfg.domain != null) [ 80 443 ];
      }
      // (if config.networking.nftables.enable then {
        extraInputRules = ''
          ip saddr { ${concatStringsSep ", " cfg.lans} } tcp dport { ${nftPorts} } accept
          ip saddr { ${concatStringsSep ", " cfg.lans} } udp dport 7359 accept
        '';
      } else {
        extraCommands = concatMapStrings (lan: ''
          iptables -I nixos-fw -p tcp -s ${lan} -m multiport --dports ${ports} -j nixos-fw-accept
          iptables -I nixos-fw -p udp -s ${lan} --dport 7359 -j nixos-fw-accept
        '') cfg.lans;
      });
  };
}
