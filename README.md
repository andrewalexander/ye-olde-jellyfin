# ye-olde-jellyfin

Run Jellyfin on the internet from a home server, and keep a close eye on what that lets in.

"Just put jellyfin on the Internet" I said.. But I know what the Internet is like. Before I could expose myself to that, I wanted to know who was scanning me and I also knew I needed to be able to take action if necessary. I couldn't at the time.. so my efforts to just host a website quickly rabbit holed into a few different repos and projects: 
- A systemd unit with dedicated networks to vpns and kill switches

- A jellyfin server instance (this)
- [ye-olde-monitoring](https://github.com/andrewalexander/ye-olde-monitoring) - a network monitoring stack to see all incoming requests, all outgoing DNS to the router, any alerts the router blocked, and any fail2ban actions we took against noisy scanners; with a table based UI to dive into the sqlite database storing it all behind the scenes. 
- some systemd units for transmission + jackett, with kill switches (jackett still leaks dns with thumbnails/hovers - not sure how best to solve)
- a bunch of NixOS modules for all of the above, as well as wifi hackery (the joys of running a server on a laptop)

If enabled, Transmission and Jackett get confined to a VPN-only systemd network namespace with a kill switch. If the connection to vpn drops, they have no network at all, and Jellyfin keeps its normal uplink.

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

- **Caddy fronts everything.** Jellyfin moves to 8097, which the firewall keeps closed, and Caddy takes 8096. LAN apps (Roku) find us through discovery (UDP 7359), which advertises Caddy's address (:8096). Means it is transparent to jellyfin clients but we get to sit in the middle
- **`domain`** adds a TLS site and opens 80/443. It's only reachable from the internet once the router forwards 443.
- **LAN-only front doors** on 8096 (Jellyfin), 8082 (the monitoring explorer), and 9091/9117 (the torrent UIs). The firewall only opens these to `lans`, and Caddy aborts any source outside `lans`.
- **Caddy writes the log** that monitoring reads. Credentials that Jellyfin clients put in URLs and headers are stripped before they reach disk.
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

e.g. requesting `/.env` twice gets you banned, and `dnscount-admin report bans` should show the ban with 0 hits during the active ban.

## Development test

`nix build .#checks.x86_64-linux.media` and `.vpn` boot VMs (KVM needed). The media test covers discovery, the firewall, redaction, Jellyfin's isolation, and bans (login, probe, Jellyfin's own 404s). The VPN test runs against a fake Mullvad server and covers the kill switch and DNS leaks.

## License

MIT
