#!/usr/bin/env bash
# manager.sh — Proxy Stack Manager main entry point

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

# ── Scriptable command interface ───────────────────────────────────────────────
# These commands run before the interactive root check and automatic updater.
# Read-only automation must not unexpectedly mutate the checked-out program.
case "${1:-}" in
    doctor)
        shift
        source "$LIB_DIR/doctor.sh"
        psm_doctor_cli "$@"
        exit $?
        ;;
    node)
        shift
        source "$LIB_DIR/node_cli.sh"
        psm_node_cli "$@"
        exit $?
        ;;
    help|--help|-h)
        cat <<'EOF'
Usage:
  psm                         Open the interactive manager
  psm doctor [--json]         Run read-only system and configuration checks
  psm node <command> [...]    Manage nodes non-interactively

Node commands:
  psm node list [--core CORE] [--protocol PROTOCOL] [--json]
  psm node show CORE PROTOCOL TAG [--json]
  psm node add CORE PROTOCOL --tag TAG [options]
  psm node update CORE PROTOCOL TAG [options]
  psm node delete CORE PROTOCOL TAG [--yes]
  psm node export CORE PROTOCOL TAG [--format FORMAT] [--json]

Run `psm node help` for the full option reference.
EOF
        exit 0
        ;;
esac

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
    log_step "$(t mgr.update.checking)"
    # Discard any local modifications to script files before pulling.
    # User data lives in /etc/psm/, not in the git repo, so dropping
    # uncommitted changes to scripts is always safe.
    timeout 5  git -C "$PSM_ROOT" checkout -- . 2>/dev/null || true
    timeout 15 git -C "$PSM_ROOT" pull --ff-only -q 2>/dev/null || return 0
    local after
    after=$(git -C "$PSM_ROOT" rev-parse HEAD 2>/dev/null) || return 0
    [[ "$before" == "$after" ]] && return 0
    log_ok "$(t mgr.update.restarting)"
    chmod +x "$PSM_ROOT"/*.sh "$LIB_DIR"/*.sh 2>/dev/null || true
    exec bash "$PSM_ROOT/manager.sh"
}
_auto_update

_banner() {
    clear
    local ipv4; ipv4=$(get_ipv4 2>/dev/null || echo "N/A")

    local nginx_ver
    nginx_ver="$(t mgr.status.not_installed)"
    command -v nginx &>/dev/null \
        && nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    local xray_ver
    xray_ver="$(t mgr.status.not_installed)"
    [[ -x "${XRAY_BIN:-}" ]] \
        && xray_ver=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')

    local sb_ver
    sb_ver="$(t mgr.status.not_installed)"
    [[ -x "${SINGBOX_BIN:-}" ]] \
        && sb_ver=$("$SINGBOX_BIN" version 2>/dev/null | awk 'NR==1{print $3}')

    local mh_ver
    mh_ver="$(t mgr.status.not_installed)"
    [[ -x "${MIHOMO_BIN:-}" ]] \
        && mh_ver=$("$MIHOMO_BIN" -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    [[ -z "$mh_ver" ]] && mh_ver="$(t mgr.status.installed)"

    local hy2_ver
    hy2_ver="$(t mgr.status.not_installed)"
    if [[ -x "/usr/local/bin/hysteria" ]]; then
        hy2_ver=$(/usr/local/bin/hysteria version 2>/dev/null | awk 'NR==1{print $NF}')
        [[ -z "$hy2_ver" ]] && hy2_ver="$(t mgr.status.installed)"
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
        [[ -z "$ss_ver" ]] && ss_ver="$(t mgr.status.installed)"
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
    printf "  ${CYAN}Sing-box${NC} ▶  %-20s  ${CYAN}Mihomo${NC}     ▶  %s\n"  "$sb_ver" "$mh_ver"
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
    echo -e "${BOLD}                  $(t menu.main.title)${NC}"
    echo -e "${B}══════════════════════════════════════════════════════════════${NC}"
    printf "  ${C} 1.${N} %s  ${C}12.${N} %s\n"  "$(_mpad "$(t menu.main.system)")"     "$(t menu.main.realm)"
    printf "  ${C} 2.${N} %s  ${C}13.${N} %s\n"  "$(_mpad "$(t menu.main.singbox)")"    "$(t menu.main.ddns)"
    printf "  ${C} 3.${N} %s  ${C}14.${N} %s\n"  "$(_mpad "$(t menu.main.mihomo)")"     "$(t menu.main.docker)"
    printf "  ${C} 4.${N} %s  ${C}15.${N} %s\n"  "$(_mpad "$(t menu.main.xray)")"       "$(t menu.main.traffic)"
    printf "  ${C} 5.${N} %s  ${C}16.${N} %s\n"  "$(_mpad "$(t menu.main.snell)")"      "$(t menu.main.tgbot)"
    printf "  ${C} 6.${N} %s  ${C}17.${N} %s\n"  "$(_mpad "$(t menu.main.ssrust)")"     "$(t menu.main.backup)"
    printf "  ${C} 7.${N} %s  ${C}18.${N} %s\n"  "$(_mpad "$(t menu.main.hysteria2)")"  "$(t menu.main.restore)"
    printf "  ${C} 8.${N} %s  ${C}19.${N} %s\n"  "$(_mpad "$(t menu.main.nginx)")"      "$(t menu.main.update)"
    printf "  ${C} 9.${N} %s  ${C}20.${N} %s\n"  "$(_mpad "$(t menu.main.website)")"    "$(t menu.main.security)"
    printf "  ${C}10.${N} %s  ${C}21.${N} %s\n"  "$(_mpad "$(t menu.main.cert)")"       "$(t menu.main.language)"
    printf "  ${C}11.${N} %s\n"  "$(t menu.main.view_nodes)"
    echo -e "${B}──────────────────────────────────────────────────────────────${NC}"
    printf "  ${C} 0.${N} %s\n" "$(t menu.main.exit)"
    echo -e "${B}══════════════════════════════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" MENU_CHOICE
}

_view_all_nodes() {
    echo -e "\n${BOLD}${BLUE}══ $(t mgr.nodes.title) ══════════════════${NC}"

    source "$LIB_DIR/xray/reality.sh"   2>/dev/null; _show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/vision.sh"    2>/dev/null; _show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/xhttp.sh"     2>/dev/null; _show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/ss2022.sh"    2>/dev/null; _xss_show_node_list 2>/dev/null || true

    source "$LIB_DIR/singbox/reality.sh"   2>/dev/null; _sb_reality_show_node_list 2>/dev/null || true
    source "$LIB_DIR/singbox/ss2022.sh"    2>/dev/null; _sb_ss_show_node_list      2>/dev/null || true
    source "$LIB_DIR/singbox/hysteria2.sh" 2>/dev/null; _sb_hy2_show_node_list     2>/dev/null || true
    source "$LIB_DIR/singbox/anytls.sh"    2>/dev/null; _sb_anytls_show_node_list  2>/dev/null || true
    source "$LIB_DIR/singbox/snell.sh"     2>/dev/null; _sb_snell_show_node_list   2>/dev/null || true

    source "$LIB_DIR/mihomo/reality.sh"   2>/dev/null; _mh_reality_show_node_list 2>/dev/null || true
    source "$LIB_DIR/mihomo/ss2022.sh"    2>/dev/null; _mh_ss_show_node_list      2>/dev/null || true
    source "$LIB_DIR/mihomo/hysteria2.sh" 2>/dev/null; _mh_hy2_show_node_list     2>/dev/null || true
    source "$LIB_DIR/mihomo/anytls.sh"    2>/dev/null; _mh_anytls_show_node_list  2>/dev/null || true
    source "$LIB_DIR/mihomo/snell.sh"     2>/dev/null; _mh_snell_show_node_list   2>/dev/null || true

    echo -e "\n${BOLD}Hysteria2:${NC}"
    if [[ -f /etc/hysteria/config.yaml ]]; then
        local domain; domain=$(state_get "hy2_domain" 2>/dev/null || echo "?")
        local pw;     pw=$(state_get "hy2_password"   2>/dev/null || echo "?")
        printf "$(t mgr.nodes.hy2_line)" "$domain" "$pw"
    else
        echo "  $(t mgr.nodes.none)"
    fi

    source "$LIB_DIR/snell.sh"   2>/dev/null; _snell_show_node_list   2>/dev/null || true
    source "$LIB_DIR/ssrust.sh"   2>/dev/null; _ssrust_show_node_list  2>/dev/null || true
    source "$LIB_DIR/realm.sh"    2>/dev/null; _realm_show_node_list   2>/dev/null || true
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
                source "$LIB_DIR/singbox/core.sh"
                sb_menu
                ;;
            3)
                source "$LIB_DIR/mihomo/core.sh"
                mh_menu
                ;;
            4)
                source "$LIB_DIR/xray/core.sh"
                xray_menu
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
                source "$LIB_DIR/hysteria2.sh"
                hysteria2_menu
                ;;
            8)
                source "$LIB_DIR/nginx.sh"
                nginx_menu
                ;;
            9)
                source "$LIB_DIR/nginx.sh"
                nginx_menu
                ;;
            10)
                source "$LIB_DIR/cert.sh"
                cert_menu
                ;;
            11)
                _view_all_nodes
                press_enter
                ;;
            12)
                source "$LIB_DIR/realm.sh"
                realm_menu
                ;;
            13)
                source "$LIB_DIR/cloudflare.sh"
                cloudflare_menu
                ;;
            14)
                source "$LIB_DIR/docker.sh"
                docker_menu
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
                source "$LIB_DIR/backup.sh"
                backup_menu
                ;;
            18)
                source "$LIB_DIR/backup.sh"
                do_restore
                ;;
            19)
                source "$PSM_ROOT/update.sh"
                psm_update
                ;;
            20)
                source "$LIB_DIR/security/core.sh"
                security_menu
                ;;
            21)
                i18n_pick_lang
                ;;
            0)
                echo -e "\n${GREEN}$(t mgr.exited)${NC}\n"
                exit 0
                ;;
            *)
                log_warn "$(t mgr.invalid_option "$MENU_CHOICE")"
                ;;
        esac
    done
}

main
