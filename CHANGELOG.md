# Changelog

All notable user-facing changes should be recorded here.

## Unreleased

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
