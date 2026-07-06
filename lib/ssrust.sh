#!/usr/bin/env bash
# ssrust.sh — ss-rust (ss-rust) management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SS_BIN="/usr/local/bin/ss-rust"
SS_CONF="/etc/ss-rust/config.json"
SS_SERVICE="ss-rust"
SS_INSTALLER="https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh"

# ── Dependency check ──────────────────────────────────────────────────────────
_ssrust_check_deps() {
    ensure_pkg_deps curl jq qrencode
    [[ -f "$SS_BIN" ]] && return 0
    log_warn "$(t ssrust.not_installed)"
    ask_yn "$(t ssrust.ask_install)" Y \
        && ssrust_install \
        || { log_error "$(t ssrust.need)"; return 1; }
}

# ── Install ───────────────────────────────────────────────────────────────────
ssrust_install() {
    log_step "$(t ssrust.downloading_install)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SS_INSTALLER" -o "$tmp"; then
        log_error "$(t ssrust.download_install_fail)"
        rm -f "$tmp"
        return 1
    fi
    log_step "$(t ssrust.running_install)"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "$(t ssrust.install_rc "$rc")" \
                  || log_ok "$(t ssrust.install_done)"
    return 0
}

# ── Show config / SS URI ──────────────────────────────────────────────────────
ssrust_show_config() {
    [[ -f "$SS_CONF" ]] || { log_error "$(t ssrust.conf_missing "$SS_CONF")"; return 1; }

    local port method password tfo nameserver
    port=$(jq -r '.server_port'        "$SS_CONF")
    method=$(jq -r '.method'            "$SS_CONF")
    password=$(jq -r '.password'        "$SS_CONF")
    tfo=$(jq -r '.fast_open // false'   "$SS_CONF")
    nameserver=$(jq -r '.nameserver // empty' "$SS_CONF")

    local ip; ip=$(get_ipv4)

    # SIP002: ss://base64url(method:password)@host:port#name
    local userinfo; userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local uri="ss://${userinfo}@${ip}:${port}#PSM-ss-rust"

    echo -e "\n${BOLD}${GREEN}── $(t ssrust.config_title) ──${NC}"
    printf "  %-12s %s\n" "$(t ssrust.lbl_server)"   "$ip"
    printf "  %-12s %s\n" "$(t ssrust.lbl_port)"     "$port"
    printf "  %-12s %s\n" "$(t ssrust.lbl_method)"   "$method"
    printf "  %-12s %s\n" "$(t ssrust.lbl_password)" "$password"
    printf "  %-12s %s\n" "TFO:"        "$tfo"
    [[ -n "$nameserver" ]] && printf "  %-12s %s\n" "DNS:"  "$nameserver"
    echo -e "\n${BOLD}$(t ssrust.link_label)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
ssrust_uninstall() {
    ask_yn "$(t ssrust.ask_uninstall)" N || return 0
    systemctl stop "$SS_SERVICE" 2>/dev/null || true
    systemctl disable "$SS_SERVICE" 2>/dev/null || true
    rm -f "$SS_BIN"
    rm -f /etc/systemd/system/ss-rust.service
    rm -rf /etc/ss-rust
    systemctl daemon-reload
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "ss2022"
    fi
    log_ok "$(t ssrust.uninstalled)"
}

# ── Update ────────────────────────────────────────────────────────────────────
ssrust_update() {
    log_step "$(t ssrust.downloading_update)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SS_INSTALLER" -o "$tmp"; then
        log_error "$(t ssrust.download_update_fail)"; rm -f "$tmp"; return 1
    fi
    bash "$tmp"; local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "$(t ssrust.update_rc "$rc")" || log_ok "$(t ssrust.update_done)"
    return 0
}

# ── Logs ──────────────────────────────────────────────────────────────────────
ssrust_logs() {
    journalctl -u "$SS_SERVICE" -f --no-pager
}

# ── List helper (called by _view_all_nodes in manager.sh) ────────────────────
_ssrust_show_node_list() {
    echo -e "\n${BOLD}$(t ssrust.list_header)${NC}"
    if [[ ! -f "$SS_CONF" ]]; then
        echo "  $(t common.not_configured)"
        return
    fi
    local port method
    port=$(jq -r '.server_port' "$SS_CONF" 2>/dev/null)
    method=$(jq -r '.method'    "$SS_CONF" 2>/dev/null)
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    printf "$(t ssrust.list_line)" "$ip" "$port" "$method"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
ssrust_menu() {
    _ssrust_check_deps || return
    while true; do
        show_menu "$(t ssrust.menu.title)" \
            "$(t ssrust.menu.install)" \
            "$(t ssrust.menu.show_config)" \
            "$(t ssrust.menu.status)" \
            "$(t ssrust.menu.restart)" \
            "$(t ssrust.menu.logs)" \
            "$(t ssrust.menu.update)" \
            "$(t ssrust.menu.uninstall)"

        case "$MENU_CHOICE" in
            1) ssrust_install;                                                press_enter ;;
            2) ssrust_show_config;                                            press_enter ;;
            3) svc_status "$SS_SERVICE";                                      press_enter ;;
            4) svc_restart "$SS_SERVICE"; log_ok "$(t ssrust.restarted)"; press_enter ;;
            5) ssrust_logs ;;
            6) ssrust_update;                                                 press_enter ;;
            7) ssrust_uninstall;                                              press_enter ;;
            0) return ;;
        esac
    done
}
