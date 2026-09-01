#!/usr/bin/env bash
# snell.sh — Snell proxy management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF_DIR="/etc/snell"
SNELL_MAIN_CONF="${SNELL_CONF_DIR}/users/snell-main.conf"
SNELL_SERVICE="snell"
SNELL_INSTALLER="https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh"

# ── Dependency check ──────────────────────────────────────────────────────────
_snell_check_deps() {
    ensure_pkg_deps curl unzip jq
    [[ -f "$SNELL_BIN" ]] && return 0
    log_warn "$(t snell.not_installed)"
    ask_yn "$(t snell.ask_install)" Y \
        && snell_install \
        || { log_error "$(t snell.need)"; return 1; }
}

# ── Install ───────────────────────────────────────────────────────────────────
snell_install() {
    log_step "$(t snell.downloading_install)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SNELL_INSTALLER" -o "$tmp"; then
        log_error "$(t snell.download_install_fail)"
        rm -f "$tmp"
        return 1
    fi
    log_step "$(t snell.running_install)"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    # rc != 0 通常是 snell-server 首次启动失败（二进制兼容性问题），
    # 配置文件已写入，不中断 PSM 菜单，改为提示诊断。
    if (( rc != 0 )); then
        log_warn "$(t snell.install_rc "$rc")"
    else
        log_ok "$(t snell.install_done)"
    fi
    return 0
}

# ── Show config / Surge URI ───────────────────────────────────────────────────
snell_show_config() {
    [[ -f "$SNELL_MAIN_CONF" ]] || { log_error "$(t snell.conf_missing "$SNELL_MAIN_CONF")"; return 1; }

    local port psk ipv6 dns
    port=$(awk -F: '/^listen/ { gsub(/[^0-9]/,"",$NF); print $NF; exit }' "$SNELL_MAIN_CONF" || true)
    psk=$(grep  -E '^psk'    "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)
    ipv6=$(grep -E '^ipv6'   "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)
    dns=$(grep  -E '^dns'    "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)

    local ip; ip=$(get_ipv4)

    local version=4
    if [[ -f "$SNELL_BIN" ]]; then
        local vout; vout=$("$SNELL_BIN" --v 2>&1 || true)
        echo "$vout" | grep -q "v6" && version=6
        echo "$vout" | grep -q "v5" && version=5
    fi

    echo -e "\n${BOLD}${GREEN}── $(t snell.config_title) ──${NC}"
    printf "  %-12s %s\n" "$(t snell.lbl_server)"  "$ip"
    printf "  %-12s %s\n" "$(t snell.lbl_port)"    "$port"
    printf "  %-12s %s\n" "PSK:"     "$psk"
    printf "  %-12s %s\n" "IPv6:"    "${ipv6:-true}"
    printf "  %-12s %s\n" "DNS:"     "${dns:-$(t snell.lbl_dns_default)}"
    printf "  %-12s %s\n" "$(t snell.lbl_version)" "$version"

    echo -e "\n${BOLD}$(t snell.surge_format)${NC}"
    echo "  PSM-Snell = snell, ${ip}, ${port}, psk = ${psk}, version = ${version}, reuse = true, tfo = true"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
snell_uninstall() {
    ask_yn "$(t snell.ask_uninstall)" N || return 0
    systemctl stop snell snell.socket snell-netns 2>/dev/null || true
    systemctl disable snell snell.socket snell-netns 2>/dev/null || true
    rm -f /usr/local/bin/snell-server /usr/local/bin/snell
    rm -f /etc/systemd/system/snell.service \
          /etc/systemd/system/snell.socket \
          /etc/systemd/system/snell-netns.service
    rm -rf "$SNELL_CONF_DIR"
    systemctl daemon-reload
    # Clean up traffic monitoring state (port is stored in state.json, no need to read config first)
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "snell"
    fi
    log_ok "$(t snell.uninstalled)"
}

# ── Update ────────────────────────────────────────────────────────────────────
snell_update() {
    log_step "$(t snell.downloading_update)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SNELL_INSTALLER" -o "$tmp"; then
        log_error "$(t snell.download_update_fail)"; rm -f "$tmp"; return 1
    fi
    bash "$tmp"; local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "$(t snell.update_rc "$rc")" || log_ok "$(t snell.update_done)"
    return 0
}

# ── Diagnose crash ────────────────────────────────────────────────────────────
snell_diagnose() {
    echo -e "\n${BOLD}${BLUE}══ $(t snell.diagnose_title) ══════════════════════════════${NC}"

    echo -e "\n${BOLD}▶ $(t snell.diag_binary)${NC}"
    file "$SNELL_BIN" 2>/dev/null || echo "$(t snell.diag_binary_fail)"

    echo -e "\n${BOLD}▶ $(t snell.diag_libs)${NC}"
    ldd "$SNELL_BIN" 2>/dev/null || echo "$(t snell.diag_ldd_fail)"

    echo -e "\n${BOLD}▶ $(t snell.diag_glibc)${NC}"
    ldd --version 2>/dev/null | head -1

    echo -e "\n${BOLD}▶ $(t snell.diag_arch)${NC}"
    uname -m

    echo -e "\n${BOLD}▶ $(t snell.diag_config)${NC}"
    if [[ -f "$SNELL_MAIN_CONF" ]]; then
        cat "$SNELL_MAIN_CONF"
    else
        echo "  $(t snell.conf_missing "$SNELL_MAIN_CONF")"
    fi

    echo -e "\n${BOLD}▶ $(t snell.diag_manual)${NC}"
    echo "$(t snell.diag_manual_note)"
    "$SNELL_BIN" --help 2>&1 | head -5 || true
    echo ""

    echo -e "${BOLD}$(t snell.diag_reasons)${NC}"
    echo "$(t snell.diag_reason1)"
    echo "$(t snell.diag_reason2)"
    echo "$(t snell.diag_reason3)"
    echo "$(t snell.diag_reason4)"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════${NC}"
}

# ── Logs ──────────────────────────────────────────────────────────────────────
snell_logs() {
    journalctl -u "$SNELL_SERVICE" -f --no-pager
}

# ── List helper (called by _view_all_nodes) ───────────────────────────────────
_snell_show_node_list() {
    echo -e "\n${BOLD}$(t snell.list_header)${NC}"
    if [[ ! -f "$SNELL_MAIN_CONF" ]]; then
        echo "  $(t common.not_configured)"
        return
    fi
    local port; port=$(awk -F: '/^listen/ { gsub(/[^0-9]/,"",$NF); print $NF; exit }' "$SNELL_MAIN_CONF" || true)
    local psk;  psk=$(grep -E '^psk' "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)
    local ip;   ip=$(get_ipv4 2>/dev/null || echo "?")
    printf "$(t snell.list_line)" "$ip" "$port" "$psk"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
snell_menu() {
    _snell_check_deps || return
    while true; do
        show_menu "$(t snell.menu.title)" \
            "$(t snell.menu.install)" \
            "$(t snell.menu.show_config)" \
            "$(t snell.menu.status)" \
            "$(t snell.menu.restart)" \
            "$(t snell.menu.logs)" \
            "$(t snell.menu.update)" \
            "$(t snell.menu.uninstall)" \
            "$(t snell.menu.diagnose)"

        case "$MENU_CHOICE" in
            1) snell_install;                                          press_enter ;;
            2) snell_show_config;                                      press_enter ;;
            3) svc_status "$SNELL_SERVICE";                            press_enter ;;
            4) svc_restart "$SNELL_SERVICE"; log_ok "$(t snell.restarted)"; press_enter ;;
            5) snell_logs ;;
            6) snell_update;                                           press_enter ;;
            7) snell_uninstall;                                        press_enter ;;
            8) snell_diagnose;                                         press_enter ;;
            0) return ;;
        esac
    done
}
