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
    log_warn "ss-rust 未安装。"
    ask_yn "是否现在安装 ss-rust？" Y \
        && ssrust_install \
        || { log_error "需要 ss-rust。"; return 1; }
}

# ── Install ───────────────────────────────────────────────────────────────────
ssrust_install() {
    log_step "正在下载 ss-rust 安装脚本..."
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SS_INSTALLER" -o "$tmp"; then
        log_error "下载安装脚本失败，请检查网络连接"
        rm -f "$tmp"
        return 1
    fi
    log_step "正在运行 ss-rust 安装程序..."
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "安装脚本退出码：${rc}（服务可能未能启动，请检查 journalctl -u ss-rust）" \
                  || log_ok "ss-rust 安装完成"
    return 0
}

# ── Show config / SS URI ──────────────────────────────────────────────────────
ssrust_show_config() {
    [[ -f "$SS_CONF" ]] || { log_error "未找到配置文件：$SS_CONF"; return 1; }

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

    echo -e "\n${BOLD}${GREEN}── ss-rust 配置 ──${NC}"
    printf "  %-12s %s\n" "服务器:"     "$ip"
    printf "  %-12s %s\n" "端口:"       "$port"
    printf "  %-12s %s\n" "加密方式:"   "$method"
    printf "  %-12s %s\n" "密码:"       "$password"
    printf "  %-12s %s\n" "TFO:"        "$tfo"
    [[ -n "$nameserver" ]] && printf "  %-12s %s\n" "DNS:"  "$nameserver"
    echo -e "\n${BOLD}SS 链接：${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
ssrust_uninstall() {
    ask_yn "是否卸载 ss-rust（程序 + 配置 + 服务）？" N || return 0
    systemctl stop "$SS_SERVICE" 2>/dev/null || true
    systemctl disable "$SS_SERVICE" 2>/dev/null || true
    rm -f "$SS_BIN"
    rm -f /etc/systemd/system/ss-rust.service
    rm -rf /etc/ss-rust
    systemctl daemon-reload
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "ss2022"
    fi
    log_ok "ss-rust 已卸载。"
}

# ── Update ────────────────────────────────────────────────────────────────────
ssrust_update() {
    log_step "正在下载 ss-rust 更新脚本..."
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SS_INSTALLER" -o "$tmp"; then
        log_error "下载更新脚本失败"; rm -f "$tmp"; return 1
    fi
    bash "$tmp"; local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "更新脚本退出码：${rc}" || log_ok "ss-rust 更新完成"
    return 0
}

# ── Logs ──────────────────────────────────────────────────────────────────────
ssrust_logs() {
    journalctl -u "$SS_SERVICE" -f --no-pager
}

# ── List helper (called by _view_all_nodes in manager.sh) ────────────────────
_ssrust_show_node_list() {
    echo -e "\n${BOLD}ss-rust：${NC}"
    if [[ ! -f "$SS_CONF" ]]; then
        echo "  未配置"
        return
    fi
    local port method
    port=$(jq -r '.server_port' "$SS_CONF" 2>/dev/null)
    method=$(jq -r '.method'    "$SS_CONF" 2>/dev/null)
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    printf "  TCP+UDP %s | 端口: %s | 加密: %s\n" "$ip" "$port" "$method"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
ssrust_menu() {
    _ssrust_check_deps || return
    while true; do
        show_menu "ss-rust 管理" \
            "安装 / 重新安装" \
            "显示配置 / SS 链接" \
            "服务状态" \
            "重启服务" \
            "查看日志" \
            "更新" \
            "卸载"

        case "$MENU_CHOICE" in
            1) ssrust_install;                                                press_enter ;;
            2) ssrust_show_config;                                            press_enter ;;
            3) svc_status "$SS_SERVICE";                                      press_enter ;;
            4) svc_restart "$SS_SERVICE"; log_ok "ss-rust 已重启。"; press_enter ;;
            5) ssrust_logs ;;
            6) ssrust_update;                                                 press_enter ;;
            7) ssrust_uninstall;                                              press_enter ;;
            0) return ;;
        esac
    done
}
