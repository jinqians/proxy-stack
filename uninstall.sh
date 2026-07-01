#!/usr/bin/env bash
# uninstall.sh — PSM full uninstall

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

require_root

echo -e "\n${RED}${BOLD}PSM 卸载程序${NC}"
echo -e "${YELLOW}此操作将删除所有 PSM 管理的组件。${NC}"
echo -e "${YELLOW}备份文件目录 $BAK_DIR 将会保留。${NC}\n"

ask_yn "确定要卸载吗？" N || { log_info "已取消。"; exit 0; }

# ── Optional component removal ────────────────────────────────────────────────
ask_yn "是否删除 Nginx？" N && {
    svc_stop nginx 2>/dev/null || true
    systemctl disable nginx --quiet 2>/dev/null || true
    detect_os
    case "$OS_ID" in
        ubuntu|debian) apt-get purge -y nginx nginx-common ;;
        centos|rhel)   yum remove -y nginx ;;
    esac
    rm -rf /etc/nginx
    log_ok "Nginx 已删除。"
}

ask_yn "是否删除 Xray？" N && {
    svc_stop xray 2>/dev/null || true
    systemctl disable xray --quiet 2>/dev/null || true
    rm -f /usr/local/bin/xray /etc/systemd/system/xray.service
    rm -rf "$XRAY_CFG_DIR" /var/log/xray /usr/local/share/xray
    systemctl daemon-reload
    log_ok "Xray 已删除。"
}

ask_yn "是否删除 Hysteria2？" N && {
    svc_stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server --quiet 2>/dev/null || true
    rm -f /usr/local/bin/hysteria /etc/systemd/system/hysteria-server.service
    rm -rf /etc/hysteria
    systemctl daemon-reload
    log_ok "Hysteria2 已删除。"
}

ask_yn "是否删除 acme.sh？（SSL 证书将保留在 $NGINX_SSL_DIR）" N && {
    [[ -f "$ACME_HOME/acme.sh" ]] && "$ACME_HOME/acme.sh" --uninstall
    rm -rf "$ACME_HOME"
    log_ok "acme.sh 已删除。"
}

ask_yn "是否删除 $NGINX_SSL_DIR 中的 SSL 证书？" N && {
    rm -rf "$NGINX_SSL_DIR"
    log_ok "证书已删除。"
}

ask_yn "是否删除 PSM 配置/状态（$CFG_DIR）？" N && {
    rm -rf "$CFG_DIR"
    log_ok "PSM 配置已删除。"
}

# Remove crons
rm -f /etc/cron.d/psm-backup /etc/cron.d/psm-ddns
# Remove Reality camouflage-target watchdog timer
systemctl disable --now psm-reality-watchdog.timer 2>/dev/null || true
rm -f /etc/systemd/system/psm-reality-watchdog.service /etc/systemd/system/psm-reality-watchdog.timer
# Remove daily health report timer
systemctl disable --now psm-health-report.timer 2>/dev/null || true
rm -f /etc/systemd/system/psm-health-report.service /etc/systemd/system/psm-health-report.timer
# Remove symlink
rm -f /usr/local/bin/psm
# Remove sysctl / limits files
rm -f /etc/sysctl.d/99-psm.conf /etc/sysctl.d/99-bbr.conf /etc/security/limits.d/99-psm.conf
# Remove honeypot iptables rules + fail2ban wiring (leaves already-banned IPs banned)
if [[ -f "$CFG_DIR/security/honeypot.conf" ]]; then
    source "$LIB_DIR/security/honeypot.sh" 2>/dev/null && hp_remove_rules 2>/dev/null || true
fi
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

log_ok "PSM 卸载完成。"
echo -e "  备份文件保留在：${YELLOW}$BAK_DIR${NC}"
