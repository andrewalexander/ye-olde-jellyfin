# Recovers a Wi-Fi link that stops passing traffic while NetworkManager still
# says "connected", which nothing else notices. a laptop's Broadcom wl driver does
# this: on 2026-11-01 it stopped receiving for 3 and then 17 minutes, with nothing
# in the logs, and a disconnect + connect fixed it both times.
#
# The gateway can keep answering pings during one of these, so a ping isn't
# enough. inboundPath is a directory that something on the network keeps writing
# to, which proves traffic is still arriving.
#
# Every 30 seconds it checks both. After 3 straight failures it reconnects. If
# the gateway stays unreachable after 3 reconnects it reloads the driver, then
# backs off. A quiet inboundPath only ever causes reconnects, since that could
# just mean the sender has stopped.
#
# See what it has done: journalctl -u wifi-watchdog
{ config, lib, pkgs, ... }:

let
  cfg = config.services.wifiWatchdog;
in
{
  options.services.wifiWatchdog = {
    enable = lib.mkEnableOption "the Wi-Fi link watchdog";
    interface = lib.mkOption {
      type = lib.types.str;
      example = "wlp2s0";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.1";
    };
    driver = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wl";
      description = "Kernel module to reload as a last resort.";
    };
    inboundPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/dnscount/raw";
      description = "Directory where a file should change every few minutes if traffic is arriving.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.wifi-watchdog = {
      description = "Reconnect Wi-Fi when the gateway stops answering";
      after = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iputils pkgs.kmod pkgs.findutils config.networking.networkmanager.package ];
      serviceConfig = {
        Restart = "always";
        RestartSec = 30;
      };
      script = ''
        interval=30
        fails=0
        reconnects=0
        problem=""

        healthy() {
          if ! ping -q -c 3 -W 2 -I ${cfg.interface} ${cfg.gateway} >/dev/null 2>&1; then
            problem=gateway
            return 1
          fi
          ${lib.optionalString (cfg.inboundPath != null) ''
            if [ -z "$(find ${cfg.inboundPath} -type f -mmin -3 -print -quit 2>/dev/null)" ]; then
              problem=inbound
              return 1
            fi
          ''}
          return 0
        }

        while sleep "$interval"; do
          if healthy; then
            if [ "$reconnects" -gt 0 ]; then
              echo "link recovered after $reconnects reconnect(s)"
            fi
            fails=0
            reconnects=0
            interval=30
            continue
          fi
          fails=$((fails + 1))
          [ "$fails" -ge 3 ] || continue
          fails=0
          reconnects=$((reconnects + 1))
          if [ "$reconnects" -le 3 ]; then
            if [ "$problem" = gateway ]; then
              echo "${cfg.gateway} unreachable; reconnecting ${cfg.interface} (attempt $reconnects)"
            else
              echo "nothing arriving in ${toString cfg.inboundPath}; reconnecting ${cfg.interface} (attempt $reconnects)"
            fi
            nmcli device disconnect ${cfg.interface} || true
            sleep 2
            nmcli --wait 30 device connect ${cfg.interface} || true
          else
            ${lib.optionalString (cfg.driver != null) ''
              if [ "$problem" = gateway ]; then
                echo "reconnecting didn't help; reloading ${cfg.driver}"
                modprobe -r ${cfg.driver} && modprobe ${cfg.driver} || echo "driver reload failed"
              fi
            ''}
            echo "still failing ($problem); checking less often"
            reconnects=0
            interval=300
          fi
        done
      '';
    };
  };
}
