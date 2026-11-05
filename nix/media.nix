# Jellyfin behind Caddy, with every request logged for dnscount, plus LAN-only
# front doors for the Transmission/Jackett UIs in the vpn namespace
# (vpn-netns.nix). Needs ye-olde-monitoring's module (services.dnscount).
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
  lanPorts = [ 8096 9091 9117 explorerPort ];
  # The dnscount explorer (table UI), LAN only like the torrent UIs.
  explorerPort = 8082;

  strings = l: concatMapStrings (s: "<string>${s}</string>") l;

  # Jellyfin doesn't know Caddy is in front of it, so it would report its own
  # port. By-request makes HTTP clients get back the address they used, whether
  # that's the LAN one or the domain. Discovery has no request to copy, so it gets
  # this entry. It can only come from the LAN, and "all" works from any VLAN:
  # Jellyfin ignores a subnet entry unless this host has an interface in it.
  lanUri = "http://${cfg.serverAddress}:8096";

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
      <EnablePublishedServerUriByRequest>true</EnablePublishedServerUriByRequest>
      <PublishedServerUriBySubnet>${strings [ "all=${lanUri}" ]}</PublishedServerUriBySubnet>
      <RemoteIPFilter />
      <IsRemoteIPFilterBlacklist>false</IsRemoteIPFilterBlacklist>
    </NetworkConfiguration>
  '';

  jellyfinSetup =
    let
      jf = config.services.jellyfin;
      dirs = "${jf.dataDir} ${jf.cacheDir} ${jf.configDir} ${jf.logDir}";
    in
    pkgs.writeShellScript "jellyfin-setup" ''
      if [ -n "$(${pkgs.findutils}/bin/find ${dirs} \( ! -user ${jf.user} -o ! -group ${jf.group} \) -print -quit)" ]; then
        echo "taking ownership of Jellyfin's data for ${jf.user}"
        ${pkgs.coreutils}/bin/chown -R ${jf.user}:${jf.group} ${dirs}
      fi
      ${pkgs.coreutils}/bin/install -m 0640 -o ${jf.user} -g ${jf.group} ${networkXml} ${jf.configDir}/network.xml
    '';

  # The access log dnscount-caddy-log tails and the guard's jails read, with
  # the credentials Jellyfin clients put in URLs and headers stripped. It
  # replaces the Caddy module's default per-site log.
  accessLog = config.services.dnscount.caddyLog.format;

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
    jellyfinDeny = mkOption {
      type = types.listOf types.str;
      default = [ "${vpnUIs}/30" ];
      defaultText = lib.literalExpression ''[ "10.200.0.2/30" ]'';
      description = ''
        Addresses Jellyfin itself can't reach, to limit what a compromised public
        service can touch. Defaults to the Transmission and Jackett network. Caddy
        still reaches those UIs, because it's a separate service.
      '';
    };
    loginBanExempt = mkOption {
      type = types.listOf types.str;
      default = cfg.lans;
      defaultText = lib.literalExpression "config.services.mediaStack.lans";
      description = "Networks that fail2ban never bans, so a mistyped password at home can't lock you out.";
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
    # The library is shared through this group (see docs/runbook.md).
    users.groups.media = { };
    users.users.${config.services.jellyfin.user}.extraGroups = [ "media" ];
    # Runs as root, so it can also take back data left by a previous user.
    systemd.services.jellyfin.serviceConfig = {
      ExecStartPre = [ "+${jellyfinSetup}" ];
      IPAddressDeny = cfg.jellyfinDeny;
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
      #
      # (add those inside the servers block below.)
      #
      # No HTTP/3: the router forwards TCP 443 only, so a UDP listener would
      # only advertise something clients can't reach. Without it Caddy needs
      # no CAP_NET_ADMIN (it only uses that for QUIC's UDP buffers).
      globalConfig = ''
        servers {
          protocols h1 h2
        }
      '';

      virtualHosts = {
        # The port LAN apps (Roku) expect after discovery. Plain HTTP.
        "http://:8096" = lanSite jellyfin;
        # Torrent UIs: never on the public site.
        "http://:9091" = lanSite "${vpnUIs}:9091";
        "http://:9117" = lanSite "${vpnUIs}:9117";
        # dnscount's table explorer: read-only, no password, never public.
        "http://:${toString explorerPort}" = lanSite config.services.dnscount.explore.addr;
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
    # Caddy is the one process the internet talks to. It needs to bind low
    # ports, write its state and logs, and connect out (ACME, the upstreams);
    # nothing else.
    systemd.services.caddy.serviceConfig = {
      AmbientCapabilities = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      ProtectSystem = lib.mkForce "strict";
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" ];
      SystemCallErrorNumber = "EPERM";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
    };

    services.dnscount.caddyLog.enable = true;
    services.dnscount.explore.enable = lib.mkDefault true;
    # Outside services (InternetDB, AbuseIPDB hourly; Censys by hand). The
    # public site's own name is never sent to them.
    services.dnscount.lookups.enable = lib.mkDefault true;
    services.dnscount.lookups.neverLookup = lib.optional (cfg.domain != null) cfg.domain;
    # ABUSE_IPDB_KEY and CENSYS_TOKEN (mode 0640, root:dnscount). Until it
    # exists, only InternetDB (no key) runs.
    services.dnscount.lookups.keyFile = lib.mkDefault "/var/lib/dnscount/lookups.env";

    # Scanners and password guessers are banned at the firewall by
    # ye-olde-monitoring's guard (fail2ban over Caddy's log), which also checks
    # that each ban held.
    services.dnscount.guard = {
      enable = true;
      ports = "80,443,8096";
      exempt = cfg.loginBanExempt;
      # Where Jellyfin's own clients 404 in normal use (a missing poster, a
      # stale web-client file), so those don't count as scanning.
      notFoundIgnore = [ "items" "users" "web" "videos" "audio" "shows" ];
      # Jellyfin's lockout disables the account, which lets a stranger lock you
      # out on purpose. This blocks the guesser instead, sooner than that
      # lockout. The IP in Jellyfin's log is the real visitor because Caddy is
      # a known proxy.
      extraJails.jellyfin = {
        filter.Definition.failregex = "Authentication request for .* has been denied \\(IP: <HOST>\\)";
        settings = {
          journalmatch = "_SYSTEMD_UNIT=jellyfin.service";
          port = "80,443,8096";
          maxretry = 5;
          findtime = "10m";
          bantime = "1h";
        };
      };
    };

    networking.firewall =
      let
        ports = concatStringsSep "," (map toString lanPorts);
        nftPorts = concatStringsSep ", " (map toString lanPorts);
      in
      {
        # 443 is the public site. 80 only does Caddy's redirect to HTTPS and its
        # Let's Encrypt HTTP check. The router forwards 443 alone, so 80 is only
        # reachable from the LAN, and certificates are issued over 443.
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
