# Changelog

All notable user-facing changes should be recorded here.

## Unreleased

- Added a VPNGate residential-IP exit, shared by Xray, sing-box, and mihomo. It fetches the public VPNGate server list, classifies each candidate IP through ip-api's batch endpoint, and keeps the ones that are actually home broadband — datacenter nodes and VPNGate's own relays at `219.100.37.x` are demoted, because those are hosted, widely known, and already blocked by the services people want to unlock. The `proxy` flag is deliberately not used for that verdict (nearly every VPNGate node is in public proxy databases, so it would reject the entire list); it is shown as a risk hint instead. Candidates are tried in order until one connects and its exit IP can actually be probed. The exit country is always chosen by the operator from a numbered list of the countries that actually have nodes (with their node counts) rather than defaulted to, since the exit country is what decides which catalogue a streaming service shows.
- The residential tunnel is an openvpn client on its own `psmvg0` device with `--route-nopull`, writing only into a dedicated routing table: the main table is never touched, so SSH and every existing node keep using the datacenter link. Cores reach it by marking connections (`sockopt.mark` on Xray, `routing_mark` on sing-box, `routing-mark` on mihomo) — not by binding to the interface, which needs `CAP_NET_RAW` that none of the three systemd units carry, while `SO_MARK` only needs the `CAP_NET_ADMIN` they already have. Because the outbound refers to a mark rather than a node, rotating to a different residential IP never rewrites any core config. When the tunnel is down the table keeps only a blackhole route, so matched traffic fails closed instead of leaking back out through the datacenter IP.
- Failover is automatic and stays inside the chosen country. VPNGate nodes are volunteers' own machines that can be powered off, renumbered, or unplugged at any moment, so a watchdog probes the tunnel every two minutes and, after two consecutive failures, moves to another node **in the same country** — drifting to a different country would silently change which regional catalogue the unlock rules reach. The dead node is put on a six-hour cooldown so rotation does not keep landing back on it, and when every same-country candidate is exhausted the list for that country is refetched before giving up. OpenVPN is also given `ping`/`ping-restart`, because a peer that loses power never sends a FIN and would otherwise leave the tunnel hanging.
- VPNGate nodes still run AES-128-CBC with SHA-1 certificates, which OpenSSL 3 refuses by default, so generated configs relax `tls-cipher` and `data-ciphers` — but only on OpenVPN 2.5+, since those options do not exist on the 2.4 that ships with Debian 10 / Ubuntu 20.04. A first failure that looks like a legacy-algorithm rejection is retried once with `providers legacy default`. Compression directives from the official config are kept as-is: they describe the framing the far end expects, so dropping them breaks the tunnel.

- Removed the shipped Reality camouflage defaults (`www.cloudflare.com` for Xray/sing-box/mihomo Reality, `www.microsoft.com` for XHTTP reality-layer) on every server-side path, interactive and `psm node` alike. Cloudflare's own domain is the exact case the Xray docs warn about, and any hardcoded well-known domain can move behind a CDN later without the script noticing — while everyone sharing one default is itself a fingerprint. Xray now defaults to mapping-engine discovery, which finds same-ASN targets and so naturally avoids both CDN frontends and large content-distribution sources, matching upstream's "steal a certificate from your own ASN" best practice. sing-box and mihomo have no discovery path, so they require an explicit target instead. The non-interactive CLI fails with a clear message rather than silently building a node on a borrowed default. Client-side outbound SNI prompts are unchanged — they are not affected by this.

- Hardened the Nginx 443 SNI multiplexer against being used as a free relay. Unknown SNI used to fall through to the Reality inbound, and REALITY forwards every connection that fails authentication straight to its `dest` — so anyone who could reach port 443 made the server pay for a round trip to `dest`. When `dest` sits on a multi-tenant CDN frontend, an attacker only had to put an arbitrary CDN-hosted hostname in the ClientHello to get a free tunnel into that entire CDN. Unknown SNI is now dropped without opening any upstream connection, and existing installs are migrated on the next Nginx sync. Mounted nodes are unaffected: each one already has an explicit SNI entry, and a prober using the node's real serverName still gets the full genuine REALITY fallback.
- Added multi-tenant CDN frontend detection for Reality camouflage targets across Xray, sing-box, and mihomo. The check probes the target's IP with unrelated SNIs and flags it when a valid certificate comes back for a hostname the target does not own — testing the property that actually matters (does this IP serve arbitrary tenants?) rather than tracking CDN IP ranges or ASNs. It warns rather than blocks, since the verdict can misfire and the risk is the operator's to weigh.
- Added REALITY fallback rate limiting (`limitFallback*` on Xray, `limit-fallback-*` on mihomo) for nodes whose target was flagged as a shared CDN frontend. It only touches connections that fail REALITY authentication; authenticated clients are unaffected. This is a backstop, not a fix: both parameters are per-connection, so an abuser who reconnects in a loop bypasses them. sing-box has no equivalent option, so nodes on it are warned when a flagged target is combined with direct-listen mode, which leaves no protection layer at all.

- Added a Xray release channel choice at install/upgrade time (stable or preview). XTLS has marked every release since v26.3.27 as a pre-release, so the stable channel can lag months behind; preview installs the newest build. Stable stays the default and non-interactive runs always use it.
- Added a per-node `minClientVer` setting for Xray Reality nodes. Xray v26.4.13 and newer default it to 26.3.27, which makes the server refuse clients running an older core — including the cores bundled in many phone apps. The installer now warns about this when the preview channel is chosen, and the Reality menu lets you relax the threshold per node. Leaving it unset writes no field at all, so older Xray builds are unaffected.
- Fixed the Xray installer falling back to `v24.9.30`, a release from 2024, and parameterised the fallback message so the version appears in one place only.
- Replaced `www.apple.com` with a neutral placeholder in the twelve Reality/XHTTP camouflage SNI and target prompts across all four languages. Xray now warns that targets containing `apple`, `icloud`, or `microsoft` (and `.cn`/`.ru`/`.ir` suffixes) raise the risk of the server IP being blocked, so the prompts no longer suggest one. The watchdog advice that names these domains as ones to avoid is unchanged.
- Bumped the mihomo fallback version to the current stable and parameterised its message. No mihomo compatibility changes were needed: all five listener types validate cleanly on both v1.19.27 and v1.19.30.
- Fixed the sing-box installer falling back to `v1.14.0`, a tag that does not exist upstream: when the GitHub API is unreachable the fallback is now the latest real stable tag, so the download no longer 404s.
- Added a sing-box release channel choice at install/upgrade time (stable or preview). The preview channel installs the latest beta/rc, which is currently the only way to reach protocols that have not been stabilised upstream yet, such as the Snell inbound (requires 1.14+, still in beta). Stable remains the default and non-interactive runs always use it.
- Added a downgrade guard that refuses to silently install a sing-box build without Snell support while Snell nodes are configured, which would otherwise leave the config failing validation and the service unable to start.
- Fixed the sing-box Snell v5 inbound writing `obfs_host`, a field the Snell inbound does not accept (it belongs to the outbound). sing-box rejected the whole config with `unknown field "obfs_host"`, so obfuscated v5 nodes could never be added. The value is still stored and used for the Surge/Clash client exports.
- Switched remote rule-set downloads to `http_client` on sing-box 1.14+, where the previous `download_detour` is deprecated (removed in 1.16). Installs older than 1.14 keep `download_detour`, since they do not recognise the new field.
- Fixed dual-stack WARP egress verification showing only the IPv6 exit IP: probing is now done per address family via IP-literal endpoints (IPv4 through 1.1.1.1, IPv6 through 2606:4700:4700::1111), so a dual-stack egress reports both its IPv4 and IPv6 WARP exit IPs.
- Added WARP exit-IP verification to sing-box and mihomo, matching Xray: after setup the real egress IP and warp status are probed and shown per family, and a new "Show real WARP exit IP" menu item allows re-checking at any time.
- mihomo WARP setup now registers a WARP identity when missing and supports choosing the egress address family (IPv4 / IPv6 / dual-stack), including an IPv6 tunnel address.
- Extended Nginx 443 SNI multiplexing to sing-box and mihomo Reality/AnyTLS nodes, letting them share the public 443 port alongside Xray nodes.
- Extended per-node traffic metering and quota enforcement (with Telegram quota warnings and automatic pause) to sing-box and mihomo nodes.
- Added a core-services section to the Telegram daily health report covering every proxy core and Nginx.
- Added `psm doctor` with human-readable and stable JSON reports for system, dependency, configuration, core-service, disk, and certificate health.
- Added a non-interactive `psm node` CLI covering 14 Xray/sing-box/mihomo node types with CRUD, export, JSON input/output, default credential redaction, locking, port checks, and transactional rollback.
- Expanded Chinese and English README files with clearer positioning, target users, reasons to choose PSM, uninstall behavior, system write paths, FAQ, and project resource links.
- Added GitHub Issue templates for installation failures, bug reports, and feature requests to make user feedback easier to triage.
- Added `CHANGELOG.md` to track user-visible changes by commit/date until formal versioned releases are introduced.

## 2026-07-03

### Fix uninstall cleanup and reinstall detection

- Fixed incomplete uninstall cleanup so PSM-owned cron entries, systemd units, firewall/Fail2ban wiring, shortcut commands, and the `/opt/psm` install directory can be removed cleanly.
- Added cleanup coverage for additional PSM-managed components such as Snell, ss-rust, and PSM-managed Docker Compose apps.
- Added bootstrap repair detection for stale partial installs, so rerunning the one-line installer can rerun setup when `/opt/psm` exists but the install is incomplete.

## 2026-07-02

### Fix nginx/fail2ban/xray cross-distro bugs and cert rate-limit handling

- Improved cross-distro compatibility across Nginx, Fail2ban, Xray, Docker, system tuning, traffic accounting, and related modules.
- Hardened certificate handling to reduce accidental Let's Encrypt rate-limit risk during acme.sh removal and reinstall flows.
- Improved package/repository handling for RHEL-family systems, including EPEL-dependent dependencies.
- Fixed multiple service-management and config-generation edge cases across proxy, security, backup, and routing modules.

### Initial commit: JQ's Proxy Stack Manager

- Added the initial PSM codebase with one-line install, interactive `psm` menu, update, uninstall, and shared utility framework.
- Added multi-protocol management for Xray Reality / Vision / XHTTP / SS2022, Hysteria2, Snell, and shadowsocks-rust.
- Added Nginx SNI routing, SSL certificate management, Cloudflare DNS/DDNS/Tunnel/Access, Docker app management, traffic accounting, expiry management, Telegram Bot, backup/restore, and security hardening.
- Added Chinese and English README files, templates, and initial project structure.
