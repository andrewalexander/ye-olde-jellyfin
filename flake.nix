{
  description = "ye-olde-jellyfin: Jellyfin on the internet, watched, with an optional VPN-only download namespace on the same server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    monitoring = {
      url = "github:andrewalexander/ye-olde-monitoring";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, monitoring }:
    let
      linux = [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # In a host's flake:
      #   inputs.jellyfin.url = "github:andrewalexander/ye-olde-jellyfin";
      #   modules = [ jellyfin.nixosModules.default { services.mediaStack = { ... }; } ];
      nixosModules = {
        # Jellyfin + Caddy + ye-olde-monitoring (services.dnscount and its guard).
        default = {
          imports = [ monitoring.nixosModules.default ./nix/media.nix ];
          services.dnscount.enable = true;
        };
        media = ./nix/media.nix;
        # Optional: Transmission + Jackett confined to a Mullvad-only namespace.
        vpnNamespace = ./nix/vpn-netns.nix;
        # Optional: for a server on Wi-Fi whose link can stall silently.
        wifiWatchdog = ./nix/wifi-watchdog.nix;
      };

      # Boot VMs (need KVM): nix build .#checks.x86_64-linux.media
      checks = nixpkgs.lib.genAttrs linux (system: {
        media = nixpkgs.legacyPackages.${system}.testers.runNixOSTest (import ./nix/tests/media.nix monitoring);
        vpn = nixpkgs.legacyPackages.${system}.testers.runNixOSTest ./nix/tests/vpn.nix;
      });
    };
}
