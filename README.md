# ye-olde-jellyfin

Run Jellyfin on the internet from a home server, and keep a close eye on what that lets in.

Exposing anything at home means it gets scanned within minutes, and keeps getting scanned. So this stack doesn't just put Jellyfin behind Caddy. It watches every connection with [ye-olde-monitoring](https://github.com/andrewalexander/ye-olde-monitoring): every request, your network's DNS lookups, the router's IDS alerts, and fail2ban bans, each checked afterwards to confirm it held. It also gives you a LAN-only explorer to see all of it.

Separately, and optionally, the same server can run **Transmission + Jackett confined to a Mullvad-only network namespace**. If the tunnel drops, they have no network at all, and Jellyfin keeps its normal uplink.

NixOS modules:

| Module | What it is |
|---|---|
| `nixosModules.default` | Jellyfin + Caddy (`services.mediaStack`) with ye-olde-monitoring and its fail2ban guard turned on |
| `nixosModules.vpnNamespace` | optional: the Mullvad-only namespace for downloads (`services.vpnNamespace`) |
| `nixosModules.wifiWatchdog` | optional: recovers a Wi-Fi link that stops passing traffic while still "connected" |

```nix
inputs.jellyfin.url = "github:andrewalexander/ye-olde-jellyfin";
# modules = [
#   jellyfin.nixosModules.default
#   {
#     services.mediaStack = { lans = [ "192.168.1.0/24" ]; serverAddress = "192.168.1.10"; domain = "jellyfin.example.com"; };
#     services.dnscount.environmentFile = "/var/lib/secrets/dnscount.env";
#   }
# ];
```

**[docs/runbook.md](docs/runbook.md)** goes from a bare NixOS box to an exposed, watched server, in phases: SSH, monitoring, Jellyfin on the LAN, then exposure. The download namespace has its own section.

## What `services.mediaStack` does

- **Caddy fronts everything.** Jellyfin moves to 8097, which the firewall keeps closed, and Caddy takes 8096. LAN apps (Roku) find it through discovery (UDP 7359), which advertises Caddy's address.
- **`domain`** adds a TLS site and opens 80/443. It's only reachable from the internet once the router forwards 443.
- **LAN-only front doors** on 8096 (Jellyfin), 8082 (the monitoring explorer), and 9091/9117 (the torrent UIs). The firewall only opens these to `lans`, and Caddy aborts non-private sources.
- **Caddy writes the log** that monitoring reads. Credentials Jellyfin clients put in URLs and headers are stripped before they reach disk.
- **Jellyfin owns nothing it doesn't need.** It runs as its own user, shares the library through the `media` group, and can't reach the torrent UIs (`jellyfinDeny`). The module also owns `network.xml`, so make network changes in the module, not the dashboard.
- **Caddy is sandboxed.** It gets no capabilities beyond binding low ports, a read-only system, and no HTTP/3 (the router only forwards TCP).

## What blocks what

| Layer | Blocks | Where |
|---|---|---|
| Router port forward | Everything except TCP 443 to the server | UniFi port forwarding |
| Router IPS ("Notify and Block") | Known-bad sources and attack signatures, including on the forward | UniFi → CyberSecure → Intrusion Prevention |
| `caddy-probe` jail | Two requests in an hour for paths no Jellyfin client asks for (`.env`, `.git`, `.php`, `wp-`, traversal…) → 1 day | ye-olde-monitoring's guard |
| `caddy-404` jail | 20 other 404s in 10 minutes, outside the paths Jellyfin clients 404 on → 1 hour | the guard, with `notFoundIgnore` from `media.nix` |
| `jellyfin` jail | 5 denied logins in 10 minutes → 1 hour | `media.nix`, on the guard |
| Repeat offenders | Each new ban of the same IP lasts twice as long, up to a week, across all jails | the guard |
| Caddy's sandbox | What a compromised Caddy could touch | `media.nix` |

LAN networks (`loginBanExempt`, which defaults to `lans`) are never banned, so a mistyped password at home can't lock you out.

## Hardening, before and after exposing

- Jellyfin: everyday accounts aren't admins. Admins have **Allow remote connections** off. Lockout is set on every account. Passwords are strong and unique.
- The router forwards only TCP 443, with logging on.
- The IPS mode is **Notify and Block**, and security events go to the server's syslog.
- From cellular, requesting `/.env` twice gets the phone banned, and `dnscount-admin report bans` shows the ban with 0 hits during it.

## Tests

`nix build .#checks.x86_64-linux.media` and `.vpn` boot VMs (KVM needed). The media test covers discovery, the firewall, redaction, Jellyfin's isolation, and bans (login, probe, Jellyfin's own 404s). The VPN test runs against a fake Mullvad server and covers the kill switch and DNS leaks.

## License

MIT
