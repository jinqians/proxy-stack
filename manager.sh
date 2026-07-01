#!/usr/bin/env bash
# manager.sh — Proxy Stack Manager main entry point

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

# ── Non-interactive invocation (--flag mode) ──────────────────────────────────
case "${1:-}" in
    --ddns-update)
        source "$LIB_DIR/cloudflare.sh"
        cf_ddns_update
        exit $?
        ;;
    --backup-full)
        source "$LIB_DIR/backup.sh"
        do_full_backup
        exit $?
        ;;
    --backup-quick)
        source "$LIB_DIR/backup.sh"
        do_quick_backup "${2:-scheduled}"
        exit $?
        ;;
    --update)
        source "$PSM_ROOT/update.sh"
        psm_update
        exit $?
        ;;
    --traffic-check)
        source "$LIB_DIR/traffic.sh"
        traffic_check
        exit $?
        ;;
    --tgbot)
        source "$LIB_DIR/tg_bot.sh"
        tgbot_daemon
        exit $?
        ;;
    --reality-watchdog)
        source "$LIB_DIR/xray/reality_watchdog.sh"
        rwd_check_all
        exit $?
        ;;
    --honeypot-alert)
        source "$LIB_DIR/security/honeypot.sh"
        hp_alert "${2:-}" "${3:-}"
        exit $?
        ;;
    --health-report)
        source "$LIB_DIR/tgbot/health_report.sh"
        hr_send_report
        exit $?
        ;;
esac

# ── Interactive mode ──────────────────────────────────────────────────────────
require_root

# ── Auto self-update via git pull ─────────────────────────────────────────────
_auto_update() {
    [[ -d "$PSM_ROOT/.git" ]] || return 0
    local before
    before=$(git -C "$PSM_ROOT" rev-parse HEAD 2>/dev/null) || return 0
    log_step "正在检查 PSM 更新..."
    # Discard any local modifications to script files before pulling.
    # User data lives in /etc/psm/, not in the git repo, so dropping
    # uncommitted changes to scripts is always safe.
    timeout 5  git -C "$PSM_ROOT" checkout -- . 2>/dev/null || true
    timeout 15 git -C "$PSM_ROOT" pull --ff-only -q 2>/dev/null || return 0
    local after
    after=$(git -C "$PSM_ROOT" rev-parse HEAD 2>/dev/null) || return 0
    [[ "$before" == "$after" ]] && return 0
    log_ok "PSM 已更新，正在重启..."
    chmod +x "$PSM_ROOT"/*.sh "$LIB_DIR"/*.sh 2>/dev/null || true
    exec bash "$PSM_ROOT/manager.sh"
}
_auto_update

_banner() {
    clear
    local ipv4; ipv4=$(get_ipv4 2>/dev/null || echo "N/A")

    local nginx_ver="未安装"
    command -v nginx &>/dev/null \
        && nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    local xray_ver="未安装"
    [[ -x "${XRAY_BIN:-}" ]] \
        && xray_ver=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')

    local hy2_ver="未安装"
    if [[ -x "/usr/local/bin/hysteria" ]]; then
        hy2_ver=$(/usr/local/bin/hysteria version 2>/dev/null | awk 'NR==1{print $NF}')
        [[ -z "$hy2_ver" ]] && hy2_ver="已安装"
    fi

    local snell_ver="" ss_ver=""
    if [[ -x "/usr/local/bin/snell-server" ]]; then
        local _sv; _sv=$(/usr/local/bin/snell-server --v 2>&1 || true)
        if   echo "$_sv" | grep -q "v6"; then snell_ver="v6"
        elif echo "$_sv" | grep -q "v5"; then snell_ver="v5"
        else snell_ver="v4"
        fi
    fi
    if [[ -x "/usr/local/bin/ss-rust" ]]; then
        ss_ver=$(/usr/local/bin/ss-rust --version 2>/dev/null | awk '{print $2}' | head -1)
        [[ -z "$ss_ver" ]] && ss_ver="已安装"
    fi

    # Bright color variants (local, not in common.sh)
    local BC='\033[96m'   # bright cyan
    local BB='\033[94m'   # bright blue
    local WH='\033[97m'   # bright white
    local DM='\033[2m'    # dim

    # ASCII art — "JQ PSM" with letter spacing (J Q · P S M)
    local L1='     _    ___          ____    ____    __  __ '
    local L2='    | |  / _ \        |  _ \  / ___| |  \/  |'
    local L3=" _  | | | | | |       | |_) | \___ \ | |\/| |"
    local L4='| |_| | | |_| |       |  __/   ___) | | |  | |'
    local L5=' \___/   \__\_|       |_|     |____/ |_|  |_|'

    echo ""
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L1"
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L2"
    printf "  ${BOLD}${BB}%s${NC}\n"  "$L3"
    printf "  ${BOLD}${BB}%s${NC}\n"  "$L4"
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L5"
    printf "\n"
    printf "  ${BOLD}${WH}Proxy Stack Manager${NC}  ${DM}·····${NC}  ${YELLOW}◆ jinqians.com${NC}\n"
    printf "  ${BLUE}──────────────────────────────────────────${NC}\n"
    printf "  ${CYAN}IP   ${NC}▶  %-20s  ${CYAN}Nginx${NC}     ▶  %s\n"  "$ipv4"     "$nginx_ver"
    printf "  ${CYAN}Xray ${NC}▶  %-20s  ${CYAN}Hysteria2${NC} ▶  %s\n"  "$xray_ver" "$hy2_ver"
    [[ -n "$snell_ver" || -n "$ss_ver" ]] && \
        printf "  ${CYAN}Snell${NC} ▶  %-20s  ${CYAN}ss-rust${NC}   ▶  %s\n" \
               "${snell_ver:----}" "${ss_ver:----}"
    printf "  ${BLUE}──────────────────────────────────────────${NC}\n"
    echo ""
}

# Pad string to a fixed display-column width, accounting for CJK double-width chars.
# CJK (3-byte UTF-8): 1 char but 2 display cols → display = chars + (bytes-chars)/2
_mpad() {
    local s="$1" w="${2:-20}"
    local b c disp pad
    b=$(printf '%s' "$s" | wc -c)
    c=${#s}
    disp=$(( c + (b - c) / 2 ))
    pad=$(( w - disp > 0 ? w - disp : 0 ))
    printf '%s%*s' "$s" "$pad" ''
}

_main_menu() {
    local C="${CYAN}" N="${NC}" B="${BOLD}${BLUE}"
    echo -e "${B}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                  JQ's Proxy Stack Manager${NC}"
    echo -e "${B}══════════════════════════════════════════════════════════════${NC}"
    printf "  ${C} 1.${N} %s  ${C} 9.${N} %s\n"  "$(_mpad "系统管理")"        "Cloudflare DDNS"
    printf "  ${C} 2.${N} %s  ${C}10.${N} %s\n"  "$(_mpad "Nginx 管理")"      "网站管理"
    printf "  ${C} 3.${N} %s  ${C}11.${N} %s\n"  "$(_mpad "Xray 管理")"       "查看所有节点"
    printf "  ${C} 4.${N} %s  ${C}12.${N} %s\n"  "$(_mpad "Hysteria2 管理")"  "备份管理"
    printf "  ${C} 5.${N} %s  ${C}13.${N} %s\n"  "$(_mpad "Snell 管理")"      "恢复备份"
    printf "  ${C} 6.${N} %s  ${C}14.${N} %s\n"  "$(_mpad "SS 2022 管理")"    "更新 PSM"
    printf "  ${C} 7.${N} %s  ${C}15.${N} %s\n"  "$(_mpad "Docker 管理")"     "流量管理"
    printf "  ${C} 8.${N} %s  ${C}16.${N} %s\n"  "$(_mpad "SSL 证书管理")"    "Telegram Bot"
    printf "  ${C}17.${N} %s\n"                  "$(_mpad "安全加固")"
    echo -e "${B}──────────────────────────────────────────────────────────────${NC}"
    printf "  ${C} 0.${N} %s\n" "退出"
    echo -e "${B}══════════════════════════════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}请选择: ${NC}")" MENU_CHOICE
}

_view_all_nodes() {
    echo -e "\n${BOLD}${BLUE}══ 已配置节点总览 ══════════════════${NC}"

    source "$LIB_DIR/xray/reality.sh"   2>/dev/null; _show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/vision.sh"    2>/dev/null; _show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/xhttp.sh"     2>/dev/null; _show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/ss2022.sh"    2>/dev/null; _xss_show_node_list 2>/dev/null || true

    echo -e "\n${BOLD}Hysteria2:${NC}"
    if [[ -f /etc/hysteria/config.yaml ]]; then
        local domain; domain=$(state_get "hy2_domain" 2>/dev/null || echo "?")
        local pw;     pw=$(state_get "hy2_password"   2>/dev/null || echo "?")
        printf "  UDP 443 | 域名: %s | 密码: %s\n" "$domain" "$pw"
    else
        echo "  未配置"
    fi

    source "$LIB_DIR/snell.sh"   2>/dev/null; _snell_show_node_list   2>/dev/null || true
    source "$LIB_DIR/ssrust.sh"   2>/dev/null; _ssrust_show_node_list  2>/dev/null || true
}

main() {
    while true; do
        _banner
        _main_menu

        case "$MENU_CHOICE" in
            1)
                source "$LIB_DIR/system.sh"
                system_menu
                ;;
            2)
                source "$LIB_DIR/nginx.sh"
                nginx_menu
                ;;
            3)
                source "$LIB_DIR/xray/core.sh"
                xray_menu
                ;;
            4)
                source "$LIB_DIR/hysteria2.sh"
                hysteria2_menu
                ;;
            5)
                source "$LIB_DIR/snell.sh"
                snell_menu
                ;;
            6)
                source "$LIB_DIR/ssrust.sh"
                ssrust_menu
                ;;
            7)
                source "$LIB_DIR/docker.sh"
                docker_menu
                ;;
            8)
                source "$LIB_DIR/cert.sh"
                cert_menu
                ;;
            9)
                source "$LIB_DIR/cloudflare.sh"
                cloudflare_menu
                ;;
            10)
                source "$LIB_DIR/nginx.sh"
                nginx_menu
                ;;
            11)
                _view_all_nodes
                press_enter
                ;;
            12)
                source "$LIB_DIR/backup.sh"
                backup_menu
                ;;
            13)
                source "$LIB_DIR/backup.sh"
                do_restore
                ;;
            14)
                source "$PSM_ROOT/update.sh"
                psm_update
                ;;
            15)
                source "$LIB_DIR/traffic.sh"
                traffic_menu
                ;;
            16)
                source "$LIB_DIR/tg_bot.sh"
                tgbot_menu
                ;;
            17)
                source "$LIB_DIR/security/core.sh"
                security_menu
                ;;
            0)
                echo -e "\n${GREEN}已退出。${NC}\n"
                exit 0
                ;;
            *)
                log_warn "无效选项：$MENU_CHOICE"
                ;;
        esac
    done
}

main
