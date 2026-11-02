# Mullvad WireGuard in its own network namespace, for Transmission + Jackett only.
# Everything else on the host (Jellyfin, Caddy, dnscount, ssh) keeps the normal
# uplink, so inbound connections keep working.
#
# Why this is a kill switch: inside the "vpn" namespace the only interfaces are
# lo, wg-mullvad and a /30 veth to the host. There is no default route except
# through wg-mullvad, so if the tunnel is down, traffic goes nowhere instead of
# out the normal uplink.
#
# Reach the web UIs through the veth, for example:
#   ssh -L 9091:10.200.0.2:9091 -L 9117:10.200.0.2:9117 <host>
# Jackett has no password until you set one in its UI.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;
  cfg = config.services.vpnNamespace;

  ns = "vpn";
  hostSide = "10.200.0.1"; # veth-vpn0, in the main namespace
  nsSide = "10.200.0.2"; # veth-vpn1, inside the namespace (the UIs listen here)

  ip = "${pkgs.iproute2}/bin/ip";
  nft = "${pkgs.nftables}/bin/nft";
  wgUnit = "wireguard-wg-mullvad.service";
  # The peer, and so the default route, comes up in its own unit a little later.
  wgReady = "wireguard-wg-mullvad.target";

  # Joins a service to the namespace, and stops or restarts it with the tunnel.
  namespaced = {
    bindsTo = [ wgUnit "vpn-veth.service" ];
    partOf = [ wgUnit ];
    after = [ wgUnit wgReady "vpn-veth.service" ];
    serviceConfig = {
      NetworkNamespacePath = "/run/netns/${ns}";
      BindReadOnlyPaths = [ "/etc/netns/${ns}/resolv.conf:/etc/resolv.conf" ];
      # NixOS resolves names through nscd, which lives in the main namespace and
      # would send lookups out the normal uplink. Hide it so glibc reads the
      # namespace's resolv.conf itself.
      InaccessiblePaths = [ "-/run/nscd" ];
    };
  };

  # Nothing starts a connection in through the tunnel. Mullvad has no port
  # forwarding, and Jackett listens on every address in the namespace.
  firewall = pkgs.writeText "vpn-netns.nft" ''
    table inet vpn {
      chain input {
        type filter hook input priority 0; policy accept;
        iifname "wg-mullvad" ct state established,related accept
        iifname "wg-mullvad" drop
      }
    }
  '';
in
{
  options.services.vpnNamespace = {
    address = mkOption {
      type = types.listOf types.str;
      description = "Address lines from the Mullvad WireGuard config.";
    };
    publicKey = mkOption {
      type = types.str;
      description = "The Mullvad server's PublicKey.";
    };
    endpoint = mkOption {
      type = types.str;
      description = "The Mullvad server's Endpoint.";
    };
    privateKeyFile = mkOption {
      type = types.str;
      default = "/var/lib/secrets/mullvad.key";
      description = "Root-only file with this device's PrivateKey. Outside the Nix store, which is world-readable.";
    };
    dns = mkOption {
      type = types.str;
      default = "10.64.0.1";
      description = "Resolver inside the tunnel.";
    };
    downloadDir = mkOption {
      type = types.str;
      description = "Where Transmission saves files.";
    };
    downloadGroup = mkOption {
      type = types.str;
      default = "media";
      description = "Group that owns downloads. Add anything that needs to read or tidy them.";
    };
  };

  config = {
    systemd.services."netns-${ns}" = {
      description = "Network namespace ${ns}";
      before = [ wgUnit ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [ "${ip} netns add ${ns}" "${ip} -n ${ns} link set lo up" ];
        ExecStop = "${ip} netns del ${ns}";
      };
    };

    networking.wireguard.interfaces.wg-mullvad = {
      # Created in the main namespace (so its encrypted UDP uses the real uplink),
      # then moved into ${ns}. allowedIPs 0.0.0.0/0 becomes ${ns}'s default route.
      socketNamespace = "init";
      interfaceNamespace = ns;
      ips = cfg.address;
      inherit (cfg) privateKeyFile;
      peers = [{
        inherit (cfg) publicKey endpoint;
        allowedIPs = [ "0.0.0.0/0" "::/0" ];
        persistentKeepalive = 25;
      }];
    };
    systemd.services.wireguard-wg-mullvad = {
      bindsTo = [ "netns-${ns}.service" ];
      after = [ "netns-${ns}.service" ];
    };

    # A /30 between the host and the namespace, so the host can reach the web UIs.
    # Deliberately no default route over it.
    systemd.services.vpn-veth = {
      description = "veth pair and firewall for the ${ns} namespace";
      bindsTo = [ "netns-${ns}.service" ];
      after = [ "netns-${ns}.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${ip} link add veth-vpn0 type veth peer name veth-vpn1 netns ${ns}"
          "${ip} addr add ${hostSide}/30 dev veth-vpn0"
          "${ip} link set veth-vpn0 up"
          "${ip} -n ${ns} addr add ${nsSide}/30 dev veth-vpn1"
          "${ip} -n ${ns} link set veth-vpn1 up"
          "${ip} netns exec ${ns} ${nft} -f ${firewall}"
        ];
        ExecStop = "-${ip} link del veth-vpn0";
      };
    };
    networking.networkmanager.unmanaged = [ "veth-vpn0" ];

    environment.etc."netns/${ns}/resolv.conf".text = "nameserver ${cfg.dns}\n";

    users.groups.${cfg.downloadGroup} = { };

    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;
      group = cfg.downloadGroup;
      openFirewall = false; # the peer port is inside the namespace anyway
      # Group-writable, and new files keep the group, so its members can read them.
      downloadDirPermissions = "2775";
      settings = {
        download-dir = cfg.downloadDir;
        incomplete-dir-enabled = false;
        umask = "002";
        rpc-bind-address = nsSide;
        rpc-whitelist-enabled = true;
        rpc-whitelist = "127.0.0.1,${hostSide}";
        rpc-host-whitelist-enabled = false; # only reachable through the veth
        # Mullvad has no port forwarding, so no incoming peer connections.
        port-forwarding-enabled = false;
      };
    };
    systemd.services.transmission = lib.recursiveUpdate namespaced {
      # The module doesn't pull in its own setup unit, which creates downloadDir.
      requires = [ "transmission-setup.service" ];
      after = [ "transmission-setup.service" ] ++ namespaced.after;
      # Fail rather than write to the root disk if the drive isn't mounted.
      unitConfig.RequiresMountsFor = [ cfg.downloadDir ];
    };
    systemd.services.transmission-setup.unitConfig.RequiresMountsFor = [ cfg.downloadDir ];

    services.jackett = {
      enable = true;
      openFirewall = false;
    };
    systemd.services.jackett = lib.recursiveUpdate namespaced {
      # Jackett only listens on localhost by default, which the host can't reach
      # from outside the namespace.
      serviceConfig.ExecStart = lib.mkForce
        "${config.services.jackett.package}/bin/Jackett --NoUpdates --ListenPublic --Port ${toString config.services.jackett.port} --DataFolder '${config.services.jackett.dataDir}'";
    };

    # Proof the tunnel is the way out. Every 5 minutes, from inside the namespace:
    # Mullvad must say this is one of its exits, and the handshake must be fresh.
    systemd.services.vpn-check = {
      description = "Check the ${ns} namespace exits through Mullvad";
      after = [ wgReady ];
      path = [ pkgs.curl pkgs.jq pkgs.wireguard-tools pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        NetworkNamespacePath = "/run/netns/${ns}";
        BindReadOnlyPaths = [ "/etc/netns/${ns}/resolv.conf:/etc/resolv.conf" ];
        InaccessiblePaths = [ "-/run/nscd" ];
      };
      script = ''
        set -eu
        info=$(curl -fsS --max-time 15 https://am.i.mullvad.net/json)
        echo "$info" | jq -c '{ip, mullvad_exit_ip, mullvad_exit_ip_hostname}'
        [ "$(echo "$info" | jq -r .mullvad_exit_ip)" = true ] || { echo "NOT a Mullvad exit"; exit 1; }
        last=$(wg show wg-mullvad latest-handshakes | cut -f2)
        age=$(( $(date +%s) - last ))
        echo "handshake age: ''${age}s"
        [ "$age" -lt 180 ] || { echo "handshake stale"; exit 1; }
      '';
    };
    systemd.timers.vpn-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2m"; OnUnitActiveSec = "5m"; };
    };
  };
}
