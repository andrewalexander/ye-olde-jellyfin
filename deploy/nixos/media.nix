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

  # fail2ban filters over that log. Each line is one JSON object with
  # request.client_ip (the real visitor; Caddy is the only proxy) before
  # request.uri, and status after the request. Only the path is matched, not
  # the query string, so a search term can't trip them.
  #
  # Paths no Jellyfin client ever asks for: dot-directories (.env, .git, .aws),
  # server-side scripts and config files, admin panels, path traversal. These
  # are what the scanners hitting the public site send, by the hundred.
  probePaths = lib.concatStringsSep "|" [
    ''/\.(?!well-known/)''
    ''\.(?:php\d?|phtml|cgi|pl|aspx?|axd|jsp|action|env|ini|ya?ml|toml|tfstate|tfvars|hcl|sql|bak|old|sh|py|rb|cfg|conf|properties|secret|key|md)(?=[/"?]|$)''
    ''wp-|phpmyadmin|cgi-bin|webmin|actuator|_profiler|server-status|telescope|@vite|/vendor/''
    # fail2ban's config parser reads % as interpolation, so %% is one %.
    ''%%2e|%%5c|\.\.''
    ''/(?:etc|proc|root|var/task)/''
  ];
  probeRegex = ''"client_ip":"<HOST>",.*?"uri":"(?i:[^"?]*(?:${probePaths}))'';
  # Any other 404, except under the paths where Jellyfin's own clients get them
  # in normal use (a missing poster, a stale web-client file). A real client
  # elsewhere rarely sees one; a scanner guessing paths sees hundreds.
  notFoundRegex = ''"client_ip":"<HOST>",.*?"uri":"(?!/(?i:items|users|web|videos|audio|shows)/)[^"]*",.*"status":404\b'';

  caddyJail = { failregex, maxretry, findtime, bantime }: {
    filter.Definition = {
      inherit failregex;
      datepattern = ''"ts":{EPOCH}'';
    };
    settings = {
      backend = "polling";
      logpath = "/var/log/caddy/access.log";
      port = "80,443,8096";
      inherit maxretry findtime bantime;
    };
  };

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
    # The library is shared through this group (see docs/homelab.md).
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

    # Jellyfin's lockout disables the account, which lets a stranger lock you out
    # on purpose. This blocks the guesser instead, sooner than that lockout. The
    # IP in Jellyfin's log is the real visitor because Caddy is a known proxy.
    #
    # With an HTTP-proxy VPS in front, the firewall here only sees the VPS, so a
    # ban would block everyone: move the ban to the VPS.
    services.fail2ban = {
      enable = true;
      ignoreIP = cfg.loginBanExempt;
      # Each new ban of the same IP lasts twice as long as the last, up to a
      # week, whichever jail it lands in.
      bantime-increment = {
        enable = true;
        maxtime = "1w";
        overalljails = true;
      };
      # How long fail2ban remembers past bans. The 1-day default forgets a
      # scanner before it usually comes back, so the doubling above would
      # start over at the base ban each time.
      daemonSettings.Definition.dbpurgeage = "30d";
      # Scanners: two probe paths in an hour is a day's ban. A burst of other
      # 404s is an hour, since it's the looser of the two signals.
      jails.caddy-probe = caddyJail {
        failregex = probeRegex;
        maxretry = 2;
        findtime = "1h";
        bantime = "1d";
      };
      jails.caddy-404 = caddyJail {
        failregex = notFoundRegex;
        maxretry = 20;
        findtime = "10m";
        bantime = "1h";
      };
      jails.jellyfin = {
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

    # fail2ban won't start if a jail's log file is missing, and Caddy creates
    # its access log when it loads its config.
    systemd.services.fail2ban = {
      after = [ "caddy.service" ];
      wants = [ "caddy.service" ];
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
