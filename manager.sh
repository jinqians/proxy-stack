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
    migrate)
        shift
        source "$LIB_DIR/migrate.sh"
        psm_migrate_cli "$@"
        exit $?
        ;;
    user)
        shift
        source "$LIB_DIR/users.sh"
        psm_users_cli "$@"
        exit $?
        ;;
    core)
        shift
        source "$LIB_DIR/core_cli.sh"
        psm_core_cli "$@"
        exit $?
        ;;
    standalone)
        shift
        source "$LIB_DIR/standalone_cli.sh"
        psm_standalone_cli "$@"
        exit $?
        ;;
    traffic)
        shift
        source "$LIB_DIR/traffic_cli.sh"
        psm_traffic_cli "$@"
        exit $?
        ;;
    agent)
        shift
        source "$LIB_DIR/agent.sh"
        psm_agent_cli "$@"
        exit $?
        ;;
    sni)
        shift
        source "$LIB_DIR/sni_cli.sh"
        psm_sni_cli "$@"
        exit $?
        ;;
    exit)
        shift
        source "$LIB_DIR/exit_cli.sh"
        psm_exit_cli "$@"
        exit $?
        ;;
    relay)
        shift
        source "$LIB_DIR/relay_cli.sh"
        psm_relay_cli "$@"
        exit $?
        ;;
    check)
        shift
        source "$LIB_DIR/check_cli.sh"
        psm_check_cli "$@"
        exit $?
        ;;
    version|--version)
        psm_version
        exit 0
        ;;
    help|--help|-h)
        cat <<'EOF'
Usage:
  psm                         Open the interactive manager
  psm doctor [--json] [--fix] Run system and configuration checks; --fix repairs what it safely can
  psm node <command> [...]    Manage nodes non-interactively
  psm user <command> [...]    Accounts on the nodes: add, list, show, update, delete, links, token
  psm core list|install [...] The cores: list them, install one without questions
  psm standalone <command> [...]
                              Standalone Snell (v4/v5/v6) and ss-rust: install, show, export, remove
  psm traffic list|set|reset|unset [...]
                              Traffic metering and limits per node
  psm agent join|status|remove [...]
                              Connect this server to a PSM panel (psm-agent)
  psm sni find [...]          REALITY camouflage targets in this server's network (mapping engine + TLS check)
  psm sni check --input -     the TLS check alone, for candidates found elsewhere (the panel's engine query)
  psm exit status|warp|vpngate [...]
                              The WARP and free residential exits (a node uses one with --exit)
  psm relay list|show|add|update|delete|probe|install [...]
                              Relays (realm or gost): forward a port to other servers,
                              balance and fail over between them, tunnel to an exit
                              machine over TLS / WSS, with rate limits, quotas and expiry
  psm check [all|ip|mail|unlock] [-4|-6] [--keys-stdin] [--json]
                              This server's IP from outside: owner, native or broadcast,
                              kind, risk scores, mail and blacklists, and which streaming
                              and AI services let it in (jinqians/ipcheck, fetched when it runs)
  psm version                 The PSM version (date and commit)
  psm migrate export|import|push [...]
                              Move this server to another host (psm migrate --help)

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
        psm_update "${2:-}"
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
    --vpngate-watchdog)
        source "$LIB_DIR/vpngate/tunnel.sh"
        vg_watchdog_run
        exit $?
        ;;
    --ruleset-update)
        source "$LIB_DIR/ruleset/apply.sh"
        rs_update_cli
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

# A terminal left non-blocking by an earlier program (O_NONBLOCK sits on the
# open file the login shell shares with what it starts) makes every read fail at
# once with "Resource temporarily unavailable", and set -e ended PSM at its first
# prompt (#5). A fresh open of the terminal does not carry the flag.
if [[ -t 0 ]] && ( : </dev/tty ) 2>/dev/null; then
    exec 0</dev/tty
fi

# ── Auto self-update via git pull ─────────────────────────────────────────────
_auto_update() {
    [[ -d "$PSM_ROOT/.git" ]] || return 0
    local before
    before=$(git -C "$PSM_ROOT" rev-parse HEAD 2>/dev/null) || return 0
    log_step "$(t mgr.update.checking)"
    # Local edits to PSM's own scripts would stop the pull, so they are put
    # aside first — kept as a patch in logs/, the way update.sh keeps them,
    # and said. PSM's state (config/, backup/, logs/) is not tracked by git
    # (.gitignore) and is never touched by this.
    git -C "$PSM_ROOT" config core.fileMode false 2>/dev/null || true   # chmod +x is no edit
    if ! git -C "$PSM_ROOT" diff --quiet HEAD -- 2>/dev/null; then
        local patch; patch="${HOME:-/root}/psm-local-changes-$(date +%Y%m%d%H%M%S).patch"
        git -C "$PSM_ROOT" diff HEAD > "$patch" 2>/dev/null && log_warn "$(t update.local_saved "$patch")"
    fi
    timeout 5  git -C "$PSM_ROOT" reset -q --hard HEAD 2>/dev/null || true
    psm_repo_slim "$PSM_ROOT" 2>/dev/null || true
    timeout 15 git -C "$PSM_ROOT" pull --ff-only -q 2>/dev/null || return 0
    local after
    after=$(git -C "$PSM_ROOT" rev-parse HEAD 2>/dev/null) || return 0
    [[ "$before" == "$after" ]] && return 0
    log_ok "$(t mgr.update.restarting)"
    find "$PSM_ROOT" -name '*.sh' -not -path '*/.git/*' -exec chmod +x {} + 2>/dev/null || true
    exec bash "$PSM_ROOT/manager.sh"
}
_auto_update

_banner() {
    clear 2>/dev/null || true   # no TERM → clear fails, and set -e would kill the menu
    local ipv4; ipv4=$(get_ipv4 2>/dev/null || echo "N/A")

    # 逐个探测组件版本；未安装的留空 → 状态栏只显示已安装的组件
    local nginx_ver="" xray_ver="" sb_ver="" mh_ver="" hy2_ver="" snell_ver="" ss_ver=""
    if command -v nginx &>/dev/null; then
        nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        [[ -z "$nginx_ver" ]] && nginx_ver="$(t mgr.status.installed)"
    fi
    if [[ -x "${XRAY_BIN:-}" ]]; then
        xray_ver=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')
        [[ -z "$xray_ver" ]] && xray_ver="$(t mgr.status.installed)"
    fi
    if [[ -x "${SINGBOX_BIN:-}" ]]; then
        sb_ver=$("$SINGBOX_BIN" version 2>/dev/null | awk 'NR==1{print $3}')
        [[ -z "$sb_ver" ]] && sb_ver="$(t mgr.status.installed)"
    fi
    if [[ -x "${MIHOMO_BIN:-}" ]]; then
        mh_ver=$("$MIHOMO_BIN" -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        [[ -z "$mh_ver" ]] && mh_ver="$(t mgr.status.installed)"
    fi
    if [[ -x "/usr/local/bin/hysteria" ]]; then
        hy2_ver=$(/usr/local/bin/hysteria version 2>/dev/null | awk 'NR==1{print $NF}')
        [[ -z "$hy2_ver" ]] && hy2_ver="$(t mgr.status.installed)"
    fi
    if [[ -x "/usr/local/bin/snell-server" ]]; then
        local _sv; _sv=$(/usr/local/bin/snell-server --v 2>&1 || true)
        if   echo "$_sv" | grep -q "v6"; then snell_ver="v6"
        elif echo "$_sv" | grep -q "v5"; then snell_ver="v5"
        else snell_ver="v4"
        fi
    elif [[ -f /etc/init.d/snell ]] && grep -q 'jinqians/snell-server' /etc/init.d/snell; then
        snell_ver="v5 (Docker)"
    fi
    if [[ -x "/usr/local/bin/ss-rust" ]]; then
        ss_ver=$(/usr/local/bin/ss-rust --version 2>/dev/null | awk '{print $2}' | head -1)
        [[ -z "$ss_ver" ]] && ss_ver="$(t mgr.status.installed)"
    fi

    # 状态栏条目：IP 永远在首位，之后只收已安装组件（标签全 ASCII，便于对齐）
    local labels=("IP") values=("$ipv4")
    [[ -n "$nginx_ver" ]] && { labels+=("Nginx");     values+=("$nginx_ver"); }
    [[ -n "$xray_ver"  ]] && { labels+=("Xray");      values+=("$xray_ver"); }
    [[ -n "$sb_ver"    ]] && { labels+=("Sing-box");  values+=("$sb_ver"); }
    [[ -n "$mh_ver"    ]] && { labels+=("Mihomo");    values+=("$mh_ver"); }
    [[ -n "$hy2_ver"   ]] && { labels+=("Hysteria2"); values+=("$hy2_ver"); }
    [[ -n "$snell_ver" ]] && { labels+=("Snell");     values+=("$snell_ver"); }
    [[ -n "$ss_ver"    ]] && { labels+=("ss-rust");   values+=("$ss_ver"); }

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

    # The PSM logo (the documentation site's "P" with a dot), five rows beside
    # the title, in the logo's own green and blue. Each row is 11 columns wide.
    # Left out when the terminal is too narrow for both.
    # Width: stty first (a minimal Alpine has no tput), then tput, then
    # $COLUMNS. Every step may fail without ending the menu (set -e, pipefail).
    local LG=() LGC LDC cols colors
    cols=$(stty size 2>/dev/null </dev/tty | awk '{print $2}' || true)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=$(tput cols 2>/dev/null || true)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=${COLUMNS:-80}
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    if (( cols >= 66 )); then
        colors=$(tput colors 2>/dev/null || true)
        if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* || "${TERM:-}" == *256color* ]] \
            || { [[ "$colors" =~ ^[0-9]+$ ]] && (( colors >= 256 )); }; then
            LGC='\033[38;5;42m'; LDC='\033[38;5;39m'
        else
            LGC='\033[32m'; LDC='\033[34m'
        fi
        LG=("${BOLD}${LGC}━━━━━━━━┓${NC}  "
            "${BOLD}${LGC}        ┃${NC}  "
            "${BOLD}${LGC}   ┏━━━━┛${NC}  "
            "${BOLD}${LGC}   ┃${NC}       "
            "${BOLD}${LGC}   ┃${NC}    ${LDC}●${NC}  ")
    fi

    echo ""
    printf "  %b${BOLD}${BC}%s${NC}\n"  "${LG[0]:-}" "$L1"
    printf "  %b${BOLD}${BC}%s${NC}\n"  "${LG[1]:-}" "$L2"
    printf "  %b${BOLD}${BB}%s${NC}\n"  "${LG[2]:-}" "$L3"
    printf "  %b${BOLD}${BB}%s${NC}\n"  "${LG[3]:-}" "$L4"
    printf "  %b${BOLD}${BC}%s${NC}\n"  "${LG[4]:-}" "$L5"
    printf "\n"
    printf "  ${BOLD}${WH}Proxy Stack Manager${NC}  ${DM}·····${NC}  ${YELLOW}◆ https://jinqians.com${NC}\n"
    printf "  ${BLUE}──────────────────────────────────────────────${NC}\n"
    # 两列布局：标签固定 9 列（最长 Hysteria2），左列值按显示宽度补齐到 16 列
    # （值可能是中文"已安装"，占 2 显示列/字，必须用 _mpad 而不是 %-16s）
    local i n=${#labels[@]}
    for (( i=0; i<n; i+=2 )); do
        if (( i+1 < n )); then
            printf "  ${CYAN}%-9s${NC} ▶  %s ${CYAN}%-9s${NC} ▶  %s\n" \
                "${labels[i]}"   "$(_mpad "${values[i]}" 16)" \
                "${labels[i+1]}" "${values[i+1]}"
        else
            printf "  ${CYAN}%-9s${NC} ▶  %s\n" "${labels[i]}" "${values[i]}"
        fi
    done
    printf "  ${BLUE}──────────────────────────────────────────────${NC}\n"
    echo ""
}

# Pad string to a fixed display-column width, accounting for CJK double-width chars.
# CJK (3-byte UTF-8): 1 char but 2 display cols → display = chars + (bytes-chars)/2
# Display width of a string in $_MW, whatever the locale. ${#s} counts bytes
# under the C locale (a fresh VPS often has no UTF-8 locale), which made every
# Chinese label look three cells wide and pushed the right-hand column left.
# So walk the UTF-8 bytes: ASCII and two-byte sequences (Latin, Cyrillic) take
# one cell, three- and four-byte ones (CJK, Hangul) two, continuation bytes none.
_mwidth() {
    local s="$1" i code
    local LC_ALL=C
    _MW=0
    for (( i = 0; i < ${#s}; i++ )); do
        printf -v code '%d' "'${s:i:1}"
        (( code < 0 )) && (( code += 256 ))
        if (( code < 0x80 || (code >= 0xC0 && code < 0xE0) )); then
            (( _MW += 1 ))
        elif (( code >= 0xE0 )); then
            (( _MW += 2 ))
        fi
    done
}

# Pads a menu label to w display cells (default: $_MPAD_W, else 20).
_mpad() {
    local s="$1" w="${2:-${_MPAD_W:-20}}" pad
    _mwidth "$s"
    pad=$(( w - _MW > 0 ? w - _MW : 0 ))
    printf '%s%*s' "$s" "$pad" ''
}

_main_menu() {
    local C="${CYAN}" N="${NC}" B="${BOLD}${BLUE}"
    # The left column is as wide as its longest label (some Russian ones pass
    # 20 cells); _mpad reads _MPAD_W.
    local _MPAD_W=20 _MW k
    for k in system singbox mihomo xray snell ssrust hysteria2 nginx website cert view_nodes; do
        _mwidth "$(t "menu.main.$k")"
        (( _MW > _MPAD_W )) && _MPAD_W=$_MW
    done
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
    printf "  ${C}11.${N} %s  ${C}22.${N} %s\n"  "$(_mpad "$(t menu.main.view_nodes)")"  "$(t menu.main.subscribe)"
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
    source "$LIB_DIR/xray/trojan.sh"    2>/dev/null; _trojan_show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/hysteria2.sh" 2>/dev/null; _xhy2_show_node_list 2>/dev/null || true
    source "$LIB_DIR/xray/vmess.sh"          2>/dev/null; _vmess_show_node_list  2>/dev/null || true
    source "$LIB_DIR/xray/socks.sh"          2>/dev/null; _socks_show_node_list  2>/dev/null || true

    source "$LIB_DIR/singbox/reality.sh"   2>/dev/null; _sb_reality_show_node_list 2>/dev/null || true
    source "$LIB_DIR/singbox/ss2022.sh"    2>/dev/null; _sb_ss_show_node_list      2>/dev/null || true
    source "$LIB_DIR/singbox/hysteria2.sh" 2>/dev/null; _sb_hy2_show_node_list     2>/dev/null || true
    source "$LIB_DIR/singbox/tuic.sh"      2>/dev/null; _sb_tuic_show_node_list    2>/dev/null || true
    source "$LIB_DIR/singbox/wireguard.sh" 2>/dev/null; _sb_wg_show_node_list      2>/dev/null || true
    source "$LIB_DIR/singbox/anytls.sh"    2>/dev/null; _sb_anytls_show_node_list  2>/dev/null || true
    source "$LIB_DIR/singbox/snell.sh"     2>/dev/null; _sb_snell_show_node_list   2>/dev/null || true
    source "$LIB_DIR/singbox/trojan.sh"    2>/dev/null; _sb_trojan_show_node_list  2>/dev/null || true
    source "$LIB_DIR/singbox/vmess.sh"       2>/dev/null; _sb_vmess_show_node_list  2>/dev/null || true
    source "$LIB_DIR/singbox/socks.sh"       2>/dev/null; _sb_socks_show_node_list  2>/dev/null || true
    source "$LIB_DIR/singbox/vless.sh"       2>/dev/null; _sb_vless_show_node_list  2>/dev/null || true

    source "$LIB_DIR/mihomo/reality.sh"   2>/dev/null; _mh_reality_show_node_list 2>/dev/null || true
    source "$LIB_DIR/mihomo/ss2022.sh"    2>/dev/null; _mh_ss_show_node_list      2>/dev/null || true
    source "$LIB_DIR/mihomo/hysteria2.sh" 2>/dev/null; _mh_hy2_show_node_list     2>/dev/null || true
    source "$LIB_DIR/mihomo/tuic.sh"      2>/dev/null; _mh_tuic_show_node_list    2>/dev/null || true
    source "$LIB_DIR/mihomo/anytls.sh"    2>/dev/null; _mh_anytls_show_node_list  2>/dev/null || true
    source "$LIB_DIR/mihomo/snell.sh"     2>/dev/null; _mh_snell_show_node_list   2>/dev/null || true
    source "$LIB_DIR/mihomo/trojan.sh"    2>/dev/null; _mh_trojan_show_node_list  2>/dev/null || true
    source "$LIB_DIR/mihomo/vmess.sh"        2>/dev/null; _mh_vmess_show_node_list  2>/dev/null || true
    source "$LIB_DIR/mihomo/socks.sh"        2>/dev/null; _mh_socks_show_node_list  2>/dev/null || true
    source "$LIB_DIR/mihomo/vless.sh"        2>/dev/null; _mh_vless_show_node_list  2>/dev/null || true

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
                website_menu
                ;;
            10)
                source "$LIB_DIR/cert.sh"
                cert_menu
                ;;
            22)
                source "$LIB_DIR/subscribe.sh"
                sub_menu
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
