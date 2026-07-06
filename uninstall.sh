#!/usr/bin/env bash
# uninstall.sh — PSM full uninstall

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

require_root

echo -e "\n${RED}${BOLD}$(t uninstall.title)${NC}"
echo -e "${YELLOW}$(t uninstall.warn1)${NC}"
echo -e "${YELLOW}$(t uninstall.warn2 "$PSM_ROOT")${NC}\n"

ask_yn "$(t uninstall.confirm)" N || { log_info "$(t common.cancelled)"; exit 0; }

_systemctl_disable_now() {
    local unit="$1"
    systemctl disable --now "$unit" 2>/dev/null || true
}

_systemctl_stop_disable() {
    local unit="$1"
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" --quiet 2>/dev/null || true
}

_remove_systemd_units() {
    local unit
    for unit in "$@"; do
        rm -f "/etc/systemd/system/$unit"
    done
}

_compose_down_all() {
    local compose_file
    [[ -d /opt/psm/compose ]] || return 0
    command -v docker &>/dev/null || command -v docker-compose &>/dev/null || return 0
    while IFS= read -r compose_file; do
        if docker compose version &>/dev/null 2>&1; then
            docker compose -f "$compose_file" down 2>/dev/null || true
        elif command -v docker-compose &>/dev/null; then
            docker-compose -f "$compose_file" down 2>/dev/null || true
        fi
    done < <(find /opt/psm/compose -name docker-compose.yml -type f 2>/dev/null)
}

_remove_psm_iptables() {
    local ipt port
    for ipt in iptables ip6tables; do
        command -v "$ipt" &>/dev/null || continue
        while "$ipt" -D INPUT -j PSM_TRF 2>/dev/null; do :; done
        while "$ipt" -D OUTPUT -j PSM_TRF 2>/dev/null; do :; done
        "$ipt" -F PSM_TRF 2>/dev/null || true
        "$ipt" -X PSM_TRF 2>/dev/null || true

        while IFS= read -r port; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            "$ipt" -D INPUT -p tcp --dport "$port" -j LOG --log-prefix "PSM-HONEYPOT: " --log-level 4 2>/dev/null || true
            "$ipt" -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
        done < <("$ipt" -S INPUT 2>/dev/null | awk '/PSM-HONEYPOT/ {for (i=1; i<=NF; i++) if ($i == "--dport") print $(i+1)}' || true)
    done
}

# ── Optional component removal ────────────────────────────────────────────────
ask_yn "$(t uninstall.ask_nginx)" N && {
    _systemctl_stop_disable nginx
    detect_os
    case "$OS_ID" in
        ubuntu|debian|raspbian)
            apt-get purge -y nginx nginx-common 2>/dev/null || true ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora)
            "$(_rhel_pkg_cmd)" remove -y nginx 2>/dev/null || true ;;
    esac
    rm -rf /etc/nginx
    log_ok "$(t uninstall.nginx_removed)"
}

ask_yn "$(t uninstall.ask_xray)" N && {
    _systemctl_stop_disable xray
    rm -f /usr/local/bin/xray /etc/systemd/system/xray.service
    rm -rf "$XRAY_CFG_DIR" /var/log/xray /usr/local/share/xray
    systemctl daemon-reload
    log_ok "$(t uninstall.xray_removed)"
}

ask_yn "$(t uninstall.ask_singbox)" N && {
    _systemctl_stop_disable sing-box
    rm -f "$SINGBOX_BIN" /etc/systemd/system/sing-box.service
    rm -rf "$SINGBOX_CFG_DIR"
    systemctl daemon-reload
    log_ok "$(t uninstall.singbox_removed)"
}

ask_yn "$(t uninstall.ask_hy2)" N && {
    _systemctl_stop_disable hysteria-server
    rm -f /usr/local/bin/hysteria /etc/systemd/system/hysteria-server.service
    rm -rf /etc/hysteria
    systemctl daemon-reload
    log_ok "$(t uninstall.hy2_removed)"
}

ask_yn "$(t uninstall.ask_snell)" N && {
    systemctl stop snell snell.socket snell-netns 2>/dev/null || true
    systemctl disable snell snell.socket snell-netns 2>/dev/null || true
    rm -f /usr/local/bin/snell-server /usr/local/bin/snell
    _remove_systemd_units snell.service snell.socket snell-netns.service
    rm -rf /etc/snell
    systemctl daemon-reload
    log_ok "$(t uninstall.snell_removed)"
}

ask_yn "$(t uninstall.ask_ssrust)" N && {
    _systemctl_stop_disable ss-rust
    rm -f /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
    rm -rf /etc/ss-rust
    systemctl daemon-reload
    log_ok "$(t uninstall.ssrust_removed)"
}

ask_yn "$(t uninstall.ask_docker)" N && {
    _compose_down_all
    rm -rf /opt/psm/compose
    log_ok "$(t uninstall.docker_removed)"
}

ask_yn "$(t uninstall.ask_acme "$NGINX_SSL_DIR")
  ${YELLOW}$(t uninstall.ask_acme_warn)${NC}" N && {
    # 删除前先把 acme.sh 账户与证书缓存打包备份，避免重装后重新签发触发限流
    if [[ -d "$ACME_HOME" ]]; then
        mkdir -p "$BAK_DIR"
        acme_bak="$BAK_DIR/acme-home-$(date +%Y%m%d-%H%M%S).tar.gz"
        if tar -czf "$acme_bak" -C "$(dirname "$ACME_HOME")" "$(basename "$ACME_HOME")" 2>/dev/null; then
            log_ok "$(t uninstall.acme_backed_up "$acme_bak")"
        else
            log_warn "$(t uninstall.acme_backup_fail)" || true
        fi
    fi
    [[ -f "$ACME_HOME/acme.sh" ]] && "$ACME_HOME/acme.sh" --uninstall
    rm -rf "$ACME_HOME"
    log_ok "$(t uninstall.acme_removed)"
}

ask_yn "$(t uninstall.ask_certs "$NGINX_SSL_DIR")" N && {
    rm -rf "$NGINX_SSL_DIR"
    log_ok "$(t uninstall.certs_removed)"
}

# Remove crons and PSM-owned systemd units.
rm -f /etc/cron.d/psm-backup /etc/cron.d/psm-ddns
_systemctl_disable_now psm-reality-watchdog.timer
_systemctl_disable_now psm-health-report.timer
_systemctl_disable_now psm-traffic.timer
_systemctl_disable_now psm-traffic-shutdown.service
_systemctl_disable_now psm-tgbot.service
_remove_systemd_units \
    psm-reality-watchdog.service psm-reality-watchdog.timer \
    psm-health-report.service psm-health-report.timer \
    psm-traffic.service psm-traffic.timer psm-traffic-shutdown.service \
    psm-tgbot.service
# Remove symlink
rm -f /usr/local/bin/psm
# Remove sysctl / limits files
rm -f /etc/sysctl.d/99-psm.conf /etc/sysctl.d/99-bbr.conf /etc/security/limits.d/99-psm.conf
# Remove PSM iptables accounting/honeypot rules + fail2ban wiring (leaves already-banned IPs banned)
if [[ -f "$CFG_DIR/security/honeypot.conf" ]]; then
    source "$LIB_DIR/security/honeypot.sh" 2>/dev/null && hp_remove_rules 2>/dev/null || true
fi
_remove_psm_iptables
rm -f /etc/fail2ban/filter.d/psm-honeypot.conf /etc/fail2ban/action.d/psm-honeypot-alert.conf \
      /etc/fail2ban/jail.d/psm-honeypot.conf
command -v fail2ban-client &>/dev/null && fail2ban-client reload &>/dev/null || true
# Remove fail2ban SSH/recidive/whitelist wiring installed via 安全加固 → Fail2ban
rm -f /etc/fail2ban/jail.d/psm-sshd.conf /etc/fail2ban/jail.d/psm-recidive.conf \
      /etc/fail2ban/jail.d/psm-defaults.conf
# Remove the local cloudflared service (does not delete the Tunnel/DNS records
# on Cloudflare's side — that needs network access and is left for the admin
# to do from 「Cloudflare 管理 → Tunnel → 卸载 Tunnel」 while credentials are handy)
systemctl stop cloudflared 2>/dev/null || true
command -v cloudflared &>/dev/null && cloudflared service uninstall 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true

psm_root_removed=0
if ask_yn "$(t uninstall.ask_progdir "$PSM_ROOT")" Y; then
    rm -rf "$PSM_ROOT"
    psm_root_removed=1
else
    ask_yn "$(t uninstall.ask_cfg "$CFG_DIR")" N && {
        rm -rf "$CFG_DIR"
        log_ok "$(t uninstall.cfg_removed)"
    }
fi

log_ok "$(t uninstall.done)"
if (( psm_root_removed )); then
    echo -e "  $(t uninstall.removed_label)${YELLOW}$PSM_ROOT${NC}"
else
    echo -e "  $(t uninstall.kept_label)${YELLOW}$PSM_ROOT${NC}"
fi
