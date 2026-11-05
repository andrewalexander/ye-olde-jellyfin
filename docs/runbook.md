# Runbook: Jellyfin on the internet, watched

| | Host | Role |
|---|---|---|
| A | `<controller>` | your laptop; holds the admin SSH key `~/.ssh/<ssh-key>` |
| B | `<server>` | NixOS: Jellyfin, Caddy, ye-olde-monitoring (and optionally Transmission + Jackett behind Mullvad) |
| C | `<router>` | UniFi: sends syslog (DNS lookups, firewall logs, IDS alerts) to B; forwards 443 |

The phases are ordered so that:
- monitoring is running before anything is exposed;
- Jellyfin works on the LAN before it faces the internet;
- public exposure comes last.

The download namespace is optional and separate. Its section near the end can be done any time after Phase 2.

**Values to fill in as you go:**

| Placeholder | Meaning | Example |
|---|---|---|
| `<controller>`, `<server>`, `<router>` | SSH host aliases for A, B, C | `laptop`, `media-box`, `router` |
| `<ssh-key>` | admin key file name in `~/.ssh` | `homelab` |
| `<key-comment>` | that key's comment | `you@laptop` |
| `<you>` | your login on B | `alice` |
| `<github-user>` | your GitHub user (its public keys) | `alice` |
| `<B-IP>`, `<router-ip>` | B's fixed LAN address, the router's | `192.168.1.10`, `192.168.1.1` |
| `<lan>` | your LAN networks | `192.168.1.0/24` |
| `<media-dir>` | where the library lives | `/srv/media` |
| `<domain>` | your domain | `example.com` |

## Phase 0: inventory (changes nothing)

```sh
ssh <you>@<B-IP> 'uname -m; nixos-version'
```
- Where does B's config live? A flake is assumed below. Without one, import the modules by path (see Phase 2).
- C: note the model and UniFi OS version.
- **CGNAT check.** Compare the WAN IP in UniFi with `curl -s ifconfig.me`. If they differ, port forwarding can't work, and you need a VPS in front (Phase 4).
- In UniFi, give B a fixed IP (DHCP reservation). Everything below keys on it.

## Phase 1: SSH

1. **Add the key to GitHub.** Add `~/.ssh/<ssh-key>.pub` to the account, and note its fingerprint from `ssh-keygen -lf`.
2. **Pull it once on each host and check the fingerprint.** This is a one-time copy, not a sync: anyone who got into the GitHub account could otherwise add a key to the router.
   ```sh
   curl -fsS https://github.com/<github-user>.keys | tee /tmp/k | ssh-keygen -lf -   # must list the fingerprint above
   ```
   - On C: `cat /tmp/k >> ~/.ssh/authorized_keys`. UniFi OS can drop this on firmware updates. If your firmware has SSH keys under Settings → System → Advanced, add the key there too.
   - On B: pin the key in config, then rebuild:
     ```nix
     users.users.<you>.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... <key-comment>" ];
     services.openssh = {
       enable = true;
       settings = {
         PasswordAuthentication = false;     # sshd only: console/desktop logins keep the password
         KbdInteractiveAuthentication = false;
         PermitRootLogin = "no";
       };
     };
     ```
     Keep the current session open. Test a new SSH session before closing it. The physical console is the fallback.
3. **On A, add host aliases** to `~/.ssh/config`:
   ```
   Host <server>
     HostName <B-IP>
     User <you>
     IdentityFile ~/.ssh/<ssh-key>
     IdentitiesOnly yes
   Host <router>
     HostName <router-ip>
     User root
     IdentityFile ~/.ssh/<ssh-key>
     IdentitiesOnly yes
   ```

**Check:** `ssh <server> true` and `ssh <router> true` both work, `ssh -o PubkeyAuthentication=no <server>` is refused, and the console login on B still works.

## Phase 2: monitoring on B, and the router's syslog

```nix
inputs.jellyfin.url = "github:andrewalexander/ye-olde-jellyfin";

# in the nixosSystem modules list (this is monitoring alone; Phase 3 adds Jellyfin):
jellyfin.inputs.monitoring.nixosModules.default
{
  services.dnscount = {
    enable = true;
    environmentFile = "/var/lib/secrets/dnscount.env";   # DNSCOUNT_TOKEN=..., root-only, outside the store
    syslog = {
      enable = true;
      address = "<B-IP>";
      allow = [ "<router-ip>" ];     # the firewall opens 5514/udp for this source only
    };
  };
}
```

Without flakes, fetch both repos (`builtins.fetchTarball` of a pinned GitHub archive, or a local checkout) and import `<monitoring>/nix/module.nix` and `<jellyfin>/nix/media.nix` by path, with `services.dnscount.package = pkgs.callPackage <monitoring>/nix/package.nix { }`.

**Create the token** (on B):
```sh
sudo install -d -m 0700 /var/lib/secrets
echo "DNSCOUNT_TOKEN=$(openssl rand -hex 24)" | sudo tee /var/lib/secrets/dnscount.env >/dev/null
sudo chmod 0400 /var/lib/secrets/dnscount.env
```

**Deploy:** run `sudo nixos-rebuild switch --flake .#<server>` on B. From A instead:
```sh
nixos-rebuild switch --flake .#<server> \
  --target-host <server> --build-host <server> --use-remote-sudo
```
Building on B means A doesn't need a Linux builder.

**On the router (C):**
1. In UniFi Network, Remote Logging (syslog/SIEM) → `<B-IP>`, port 5514, with security events on.
2. Turn on DNS logging and blocking in the router's own dnsmasq, then turn off UniFi's Ad Blocking on every network. Its CoreDNS sits in front of dnsmasq and makes every lookup look like it came from `127.0.0.1`:
   `ssh <router> 'sh -s' < scripts/unifi-dns-blocking.sh` (from ye-olde-monitoring). Re-run it after firmware updates.
3. Optionally, `ssh root@<router> 'sh -s' < scripts/unifi-neighbors.sh`, so IPv6 devices get names.
4. Turn on logging for the firewall rules you care about.

**Check:**
- On a LAN laptop, `dig example.org`; on B, `dnscount-admin report dns -domain example.org` lists the laptop.
- `curl -s 127.0.0.1:8081/api/health` shows no data problems.

## Phase 3: Jellyfin on the LAN, Roku included

`nix/media.nix` (`services.mediaStack`). Every HTTP request goes through Caddy, so every request lands in dnscount, and the guard bans what misbehaves.

| Who | How they connect | Path |
|---|---|---|
| Roku on B's network | UDP 7359 broadcast → Jellyfin replies with `http://<B-IP>:8096` | Caddy on 8096 → Jellyfin on 8097 |
| Devices on another VLAN | Discovery broadcasts don't cross VLANs, so enter `http://<B-IP>:8096` by hand | Caddy on 8096 → Jellyfin on 8097 |
| The explorer, from any listed network | `http://<B-IP>:8082` | Caddy → dnscount-explore |

**Set up:**
1. **Back up Jellyfin's network settings,** because the module takes them over:
   ```sh
   sudo cp -a /var/lib/jellyfin/config/network.xml /var/lib/jellyfin/config/network.xml.pre-caddy
   ```
2. **Open each library to the `media` group.** Jellyfin runs as its own user, and with `SaveLocalMetadata` on it also writes next to your media:
   ```sh
   sudo chgrp -R media <media-dir>
   sudo chmod -R g+rwX <media-dir>
   sudo find <media-dir> -type d -exec chmod g+s {} +
   ```
3. **Add `jellyfin.nixosModules.default` and set `services.mediaStack`** (`lans = [ "<lan>" ]`, `serverAddress = "<B-IP>"`). Rebuild. Jellyfin restarts on 8097 and Caddy takes 8096, with no dashboard steps. If Jellyfin ran as another user before, it takes over its data on start.

**How it's put together:**
- **`media.nix` owns `network.xml`** and rewrites it on every start. Changes made in Dashboard → Networking don't last, so make them in the module.
- **Jellyfin listens on all addresses, on 8097,** so discovery doesn't depend on a bind address. The firewall leaves 8097 closed.
- **The published address uses `all=`.** Jellyfin ignores a subnet entry unless the host has an interface in that subnet, so entries for other VLANs do nothing.
- **Jellyfin has its own user,** so a compromised public service can't read a login account's files.
- **Caddy is sandboxed:** no capabilities beyond binding low ports, a read-only system, and no HTTP/3.

**Check:**
- `sudo ss -ltnp | grep -E ':(8096|8097|8082) '` shows Caddy on 8096 and 8082, and Jellyfin on 8097. A `503` from Jellyfin just after a restart means it's still starting.
- From another device, `curl -s http://<B-IP>:8096/System/Info/Public` reports `LocalAddress` as `http://<B-IP>:8096`, and port 8097 times out.
- The Roku app discovers the server and plays a video. `dnscount-admin report hits -ip <roku-ip>` shows the requests.
- No tokens were stored. This prints `0`:
  ```sh
  sudo -u dnscount nix-shell -p sqlite --run "sqlite3 /var/lib/dnscount/dnscount.db \"select count(*) from hits where (query like '%api_key=%' or query like '%ApiKey=%') and query not like '%REDACTED%'\""
  ```

**To roll back,** `network.xml` has to be restored too, or Jellyfin stays on 8097 with nothing in front of it. If the previous generation ran Jellyfin as another user, also `chown -R` `/var/lib/jellyfin` and `/var/cache/jellyfin` back to it:
```sh
sudo nixos-rebuild switch --rollback
sudo systemctl stop jellyfin
sudo cp -a /var/lib/jellyfin/config/network.xml.pre-caddy /var/lib/jellyfin/config/network.xml
sudo systemctl start jellyfin
```

## Phase 4: internet exposure (router today, VPS later)

Do these in order. Everything before the port forward happens while Jellyfin is still LAN-only.

1. **Jellyfin accounts,** in Dashboard → Users:
   - Keep **Failed login tries before user is locked out** set on every account. It locks the account rather than blocking the attacker, and another admin has to unlock it.
   - Create a separate everyday account without admin rights, for the Roku and other devices.
   - Turn off **Allow remote connections** for admin accounts, so a locked-out admin stays reachable from the LAN.
   - Use a strong, unique password on any account that can log in remotely.
2. **Test the bans** before exposing anything. The guard is already on: it bans denied logins (`jellyfin` jail), probe paths (`caddy-probe`) and 404 bursts (`caddy-404`), and never bans `services.mediaStack.loginBanExempt` (your LANs by default). Confirm the log shows real client IPs, then from a phone on cellular (once exposed), fail a few logins and confirm that IP gets banned and later released.
3. **DNS.** Make `jellyfin.<domain>` a CNAME to `<your-ddns-name>`, which the router keeps current. Set `services.mediaStack.domain`, which adds the TLS site and opens 80 and 443 on B. Caddy gets the certificate by itself once 443 is forwarded.
4. **Split-horizon DNS.** In UniFi, add a local DNS record `jellyfin.<domain>` → `<B-IP>`, so LAN devices using the name stay on the LAN. It only helps devices that use the router's DNS.
5. **UniFi, last, because this is what opens it to the internet.** Port forward TCP 443 → `<B-IP>`, with logging on, so connections also land in dnscount. Forward nothing else: not 80, 8096, 8082 or 8081.
   - B's own firewall also opens 80, for Caddy's redirect to HTTPS and its Let's Encrypt HTTP check. With no forward, only the LAN can reach it. If issuing fails over 443, forward 80 temporarily.
6. **Watch:** `dnscount-admin report hits -site jellyfin.<domain> -top ip -since 24h` and `dnscount-admin report bans`.

**Adding a VPS in front later** (visitor → VPS → router → B). Only config changes, nothing in code:

| VPS does | On B |
|---|---|
| HTTP reverse proxy | Caddy `servers { trusted_proxies static <vps-ip> }`, plus `services.dnscount.trustedProxies` += `<vps-ip>/32`. Bans must move to the VPS, since B only sees the VPS |
| TCP passthrough + PROXY protocol | Caddy `servers { listener_wrappers { proxy_protocol { allow <vps-ip>/32 } tls } }` |

In both cases, point the DNS record at the VPS, and restrict the router's port forward to the VPS's address (or replace it with a WireGuard tunnel).

**Check:** from a phone on cellular, Jellyfin plays, and `report hits` shows the carrier IP, not the router's. From outside, 8096, 8082 and 8081 are closed.

## Operating it

Once it faces the internet, the daily routine, the explorer, IDS alerts, bans and threat feeds are all in [ye-olde-monitoring's README](https://github.com/andrewalexander/ye-olde-monitoring#reading-it). Two things specific to this stack:
- The explorer is at `http://<B-IP>:8082/` from the LAN. It has no password: Caddy aborts anything from outside the private ranges, the firewall only opens 8082 to the LANs, and the router never forwards it.
- To check that the hardening holds: `systemd-analyze security caddy` should score well below 7.8, and from cellular, requesting `/.env` twice should get the phone banned, with `report bans` showing 0 hits during the ban.

## Optional: downloads behind Mullvad

`nix/vpn-netns.nix` (`services.vpnNamespace`) runs Transmission and Jackett on the same server, inside a `vpn` network namespace whose only way out is `wg-mullvad`. If the tunnel is down, they have no network at all, so nothing leaks. Jellyfin, Caddy, monitoring and ssh stay on the normal uplink. Whole-host Mullvad would break Jellyfin, because replies to inbound connections would leave through the tunnel.

**Set up:**
1. **Get a config.** On mullvad.net, open WireGuard configuration, generate a key, and download a config for one server. Don't put the file in a git repo.
2. **Store the private key** outside the Nix store, which anyone on the host can read. `sudo stat -c '%a %U %s'` on it should show `400 root 45`:
   ```sh
   sudo install -d -m 0700 /var/lib/secrets
   sudo install -m 0400 /dev/stdin /var/lib/secrets/mullvad.key <<< '<PrivateKey value>'
   ```
3. **Fill in the module.** Import `jellyfin.nixosModules.vpnNamespace` and set `services.vpnNamespace` (`address`, `publicKey`, `endpoint`, `downloadDir`) from the config. Rebuild, then `sudo systemctl restart wireguard-wg-mullvad` if only the key changed.
4. **Set a Jackett admin password.** The UIs listen on 10.200.0.2. `media.nix` puts Caddy in front of them for the LAN, at `http://<B-IP>:9091/transmission/web/` and `http://<B-IP>:9117`. From elsewhere: `ssh -L 9091:10.200.0.2:9091 -L 9117:10.200.0.2:9117 <server>`.

If `wg show` has no `latest handshake`, Mullvad probably doesn't recognize the key. It stays silent toward unknown keys, so generate a fresh config. `mullvad account logout` removes that device, so don't reuse a key generated for it.

**Check:**
```sh
sudo ip netns exec vpn curl -s https://am.i.mullvad.net/json   # "mullvad_exit_ip": true
curl -s https://am.i.mullvad.net/json                          # home IP; the host isn't tunnelled
sudo ip netns exec vpn ip route                                # default via wg-mullvad, plus 10.200.0.0/30; nothing else
sudo systemctl start vpn-check; journalctl -u vpn-check -n 5

# Kill switch: with the tunnel down, the namespace has no way out. The restart brings it back.
sudo ip -n vpn link set wg-mullvad down
sudo ip netns exec vpn curl -s --max-time 5 https://am.i.mullvad.net/json || echo "blocked: good"
sudo systemctl restart wireguard-wg-mullvad

# Transmission resolves names through Mullvad, not the router (no DNS leak)
sudo nsenter -t "$(systemctl show -p MainPID --value transmission)" -m cat /etc/resolv.conf   # nameserver 10.64.0.1
```

Finally, add a torrent-IP checker such as ipleak.net's. Its tracker should report the Mullvad address.

**Notes:**
- Mullvad removed port forwarding in 2023, so Transmission gets no incoming peer connections. Expect fewer peers.
- Jellyfin can't reach the torrent UIs (`services.mediaStack.jellyfinDeny`), so a compromised public service can't drive them. Caddy still can, since it's a separate service.
- If B is on Wi-Fi, `jellyfin.nixosModules.wifiWatchdog` recovers a link that silently stops passing traffic. Don't run `tcpdump` over a laptop's Wi-Fi: that can trigger exactly this kind of stall.

## Later

- **VLANs** (servers / trusted / IoT). When B moves, update `syslog.allow` and `syslog.address`, `services.mediaStack.lans`, and the router forwards and `trustedProxies`.
- **VPN setup:** compare Docker + gluetun against the namespace setup.
