#!/usr/bin/env bash
# ssrust.sh — ss-rust (ss-rust) management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SS_BIN="/usr/local/bin/ss-rust"
SS_CONF="/etc/ss-rust/config.json"
SS_SERVICE="ss-rust"
SS_INSTALLER="https://raw.githubusercontent.com/jinqians/ss-2022/main/ss-2022.sh"

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
    _uses_systemd || { _ssrust_native_install install; return; }
    log_step "$(t ssrust.downloading_install)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl "${PSM_DL[@]}" -fsSL "$SS_INSTALLER" -o "$tmp"; then
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

# ── Native install (no systemd, e.g. Alpine/OpenRC) ──────────────────────────
# The upstream ss-2022.sh only writes systemd units. Here: the static musl build
# from the shadowsocks-rust releases, the same config.json layout the upstream
# script writes (so show/uninstall/traffic handle both the same way), and an
# OpenRC service. `update` swaps the binary and keeps the config.
SS_NATIVE_FALLBACK="v1.25.0"   # used only when the GitHub API is unreachable

_ssrust_free_port() {
    local p _
    for _ in {1..30}; do
        p=$(( RANDOM % 40000 + 20000 ))
        ss -Hltun "sport = :$p" 2>/dev/null | grep -q . || { echo "$p"; return 0; }
    done
    echo "$p"
}

# The static musl ssserver of the latest shadowsocks-rust release, installed as
# $SS_BIN (it runs on glibc and musl alike). Prints the release tag. Also used
# by `psm standalone install ss2022` (lib/standalone_cli.sh), which passes
# "quiet": the menu's "no systemd here" step line would be wrong there.
# shellcheck disable=SC2120  # "quiet" comes from lib/standalone_cli.sh only
_ssrust_fetch_binary() {
    local quiet="${1:-}" triple
    case "$(get_arch)" in
        amd64) triple="x86_64-unknown-linux-musl" ;;
        arm64) triple="aarch64-unknown-linux-musl" ;;
        arm32) triple="armv7-unknown-linux-musleabihf" ;;
    esac
    local tag
    tag=$(gh_latest_tag shadowsocks/shadowsocks-rust)
    [[ "$tag" =~ ^v[0-9] ]] || tag="$SS_NATIVE_FALLBACK"
    [[ -n "$quiet" ]] || log_step "$(t common.native.installing ss-rust "$tag")" >&2

    local file="shadowsocks-${tag}.${triple}.tar.xz"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/${file}"
    local tmp; tmp=$(mktemp -d)
    if ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/$file" "$url" \
        || ! xz -dc "$tmp/$file" | tar -x -C "$tmp" ssserver \
        || [[ ! -f "$tmp/ssserver" ]]; then
        rm -rf "$tmp"
        log_error "$(t common.native.download_fail "$url")"
        return 1
    fi
    install -m 755 "$tmp/ssserver" "$SS_BIN"
    rm -rf "$tmp"
    mkdir -p "$(dirname "$SS_CONF")"
    echo "${tag#v}" > "$(dirname "$SS_CONF")/ver.txt"
    printf '%s' "$tag"
}

_ssrust_native_install() {
    local mode="${1:-install}"
    ensure_pkg_deps curl jq tar xz openssl
    require_cmd curl jq tar xz openssl

    _ssrust_fetch_binary >/dev/null || return 1

    if [[ "$mode" == "install" || ! -f "$SS_CONF" ]]; then
        local listen="0.0.0.0"
        [[ -s /proc/net/if_inet6 ]] && listen="::"
        jq -n --arg server "$listen" --argjson port "$(_ssrust_free_port)" \
              --arg password "$(openssl rand -base64 16)" \
            '{server: $server, server_port: $port, password: $password,
              method: "2022-blake3-aes-128-gcm", fast_open: false,
              mode: "tcp_and_udp", user: "nobody", timeout: 300}' > "$SS_CONF"
        chmod 600 "$SS_CONF"
    fi

    psm_write_openrc_service "$SS_SERVICE" "Shadowsocks Rust" "$SS_BIN" "-c $SS_CONF" || return 1
    svc_enable "$SS_SERVICE" || true
    svc_restart "$SS_SERVICE" >/dev/null 2>&1 || true
    sleep 2
    if ! svc_is_active "$SS_SERVICE"; then
        log_error "$(t common.native.start_fail ss-rust)"
        svc_log_tail "$SS_SERVICE" 15 >&2
        return 1
    fi
    # SS2022 refuses clients whose clock is more than 30 s off: keep ours synced.
    { pkg_install chrony && _svc_enable_now chronyd; } >/dev/null 2>&1 || true
    declare -f firewall_open_port &>/dev/null \
        && firewall_open_port "$(jq -r '.server_port' "$SS_CONF")" both || true
    log_ok "$(t ssrust.install_done)"
    [[ "$mode" == "install" ]] && ssrust_show_config
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
    psm_remove_openrc_service "$SS_SERVICE"
    rm -f "$SS_BIN"
    rm -f /etc/systemd/system/ss-rust.service
    rm -rf /etc/ss-rust
    svc_daemon_reload
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "ss2022"
    fi
    log_ok "$(t ssrust.uninstalled)"
}

# ── Update ────────────────────────────────────────────────────────────────────
ssrust_update() {
    _uses_systemd || { _ssrust_native_install update; return; }
    log_step "$(t ssrust.downloading_update)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl "${PSM_DL[@]}" -fsSL "$SS_INSTALLER" -o "$tmp"; then
        log_error "$(t ssrust.download_update_fail)"; rm -f "$tmp"; return 1
    fi
    bash "$tmp"; local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "$(t ssrust.update_rc "$rc")" || log_ok "$(t ssrust.update_done)"
    return 0
}

# ── Logs ──────────────────────────────────────────────────────────────────────
ssrust_logs() {
    svc_logs "$SS_SERVICE"
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
