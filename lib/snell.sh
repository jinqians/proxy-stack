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
    log_warn "Snell 未安装。"
    ask_yn "是否现在安装 Snell？" Y \
        && snell_install \
        || { log_error "需要 Snell。"; return 1; }
}

# ── Install ───────────────────────────────────────────────────────────────────
snell_install() {
    log_step "正在下载 Snell 安装脚本..."
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SNELL_INSTALLER" -o "$tmp"; then
        log_error "下载安装脚本失败，请检查网络连接"
        rm -f "$tmp"
        return 1
    fi
    log_step "正在运行 Snell 安装程序..."
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    # rc != 0 通常是 snell-server 首次启动失败（二进制兼容性问题），
    # 配置文件已写入，不中断 PSM 菜单，改为提示诊断。
    if (( rc != 0 )); then
        log_warn "安装脚本退出码：${rc}（服务可能未能启动，运行「诊断 Snell 崩溃」排查）"
    else
        log_ok "Snell 安装完成"
    fi
    return 0
}

# ── Show config / Surge URI ───────────────────────────────────────────────────
snell_show_config() {
    [[ -f "$SNELL_MAIN_CONF" ]] || { log_error "未找到配置文件：$SNELL_MAIN_CONF"; return 1; }

    local port psk ipv6 dns
    port=$(grep -E '^listen' "$SNELL_MAIN_CONF" | grep -oP ':\K[0-9]+$' || true)
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

    echo -e "\n${BOLD}${GREEN}── Snell 配置 ──${NC}"
    printf "  %-12s %s\n" "服务器:"  "$ip"
    printf "  %-12s %s\n" "端口:"    "$port"
    printf "  %-12s %s\n" "PSK:"     "$psk"
    printf "  %-12s %s\n" "IPv6:"    "${ipv6:-true}"
    printf "  %-12s %s\n" "DNS:"     "${dns:-（系统默认）}"
    printf "  %-12s %s\n" "版本:"    "$version"

    echo -e "\n${BOLD}Surge 格式：${NC}"
    echo "  PSM-Snell = snell, ${ip}, ${port}, psk = ${psk}, version = ${version}, reuse = true, tfo = true"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
snell_uninstall() {
    ask_yn "是否卸载 Snell（程序 + 配置 + 服务）？" N || return 0
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
    log_ok "Snell 已卸载。"
}

# ── Update ────────────────────────────────────────────────────────────────────
snell_update() {
    log_step "正在下载 Snell 更新脚本..."
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl -fsSL "$SNELL_INSTALLER" -o "$tmp"; then
        log_error "下载更新脚本失败"; rm -f "$tmp"; return 1
    fi
    bash "$tmp"; local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "更新脚本退出码：${rc}" || log_ok "Snell 更新完成"
    return 0
}

# ── Diagnose crash ────────────────────────────────────────────────────────────
snell_diagnose() {
    echo -e "\n${BOLD}${BLUE}══ Snell 崩溃诊断 ══════════════════════════════${NC}"

    echo -e "\n${BOLD}▶ Binary 类型:${NC}"
    file "$SNELL_BIN" 2>/dev/null || echo "  无法检测（binary 不存在？）"

    echo -e "\n${BOLD}▶ 动态库依赖:${NC}"
    ldd "$SNELL_BIN" 2>/dev/null || echo "  ldd 失败（静态链接或不存在）"

    echo -e "\n${BOLD}▶ 系统 GLIBC 版本:${NC}"
    ldd --version 2>/dev/null | head -1

    echo -e "\n${BOLD}▶ 系统架构:${NC}"
    uname -m

    echo -e "\n${BOLD}▶ 配置文件:${NC}"
    if [[ -f "$SNELL_MAIN_CONF" ]]; then
        cat "$SNELL_MAIN_CONF"
    else
        echo "  未找到：$SNELL_MAIN_CONF"
    fi

    echo -e "\n${BOLD}▶ 手动测试运行:${NC}"
    echo "  （尝试前台启动，捕获真实错误信息）"
    "$SNELL_BIN" --help 2>&1 | head -5 || true
    echo ""

    echo -e "${BOLD}常见原因:${NC}"
    echo "  1. glibc 版本过旧（升级系统或使用兼容版 snell）"
    echo "  2. 下载了错误架构的 binary（x86_64 / arm64 不匹配）"
    echo "  3. 配置文件格式错误（检查上方配置）"
    echo "  4. 解决方案：先卸载，再通过「安装/重新安装」重新安装"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════${NC}"
}

# ── Logs ──────────────────────────────────────────────────────────────────────
snell_logs() {
    journalctl -u "$SNELL_SERVICE" -f --no-pager
}

# ── List helper (called by _view_all_nodes) ───────────────────────────────────
_snell_show_node_list() {
    echo -e "\n${BOLD}Snell：${NC}"
    if [[ ! -f "$SNELL_MAIN_CONF" ]]; then
        echo "  未配置"
        return
    fi
    local port; port=$(grep -E '^listen' "$SNELL_MAIN_CONF" | grep -oP ':\K[0-9]+$' || true)
    local psk;  psk=$(grep -E '^psk' "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)
    local ip;   ip=$(get_ipv4 2>/dev/null || echo "?")
    printf "  TCP %s | 端口: %s | psk: %s\n" "$ip" "$port" "$psk"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
snell_menu() {
    _snell_check_deps || return
    while true; do
        show_menu "Snell 管理" \
            "安装 / 重新安装" \
            "显示配置 / Surge URI" \
            "服务状态" \
            "重启服务" \
            "查看日志" \
            "更新 Snell" \
            "卸载" \
            "诊断 Snell 崩溃"

        case "$MENU_CHOICE" in
            1) snell_install;                                          press_enter ;;
            2) snell_show_config;                                      press_enter ;;
            3) svc_status "$SNELL_SERVICE";                            press_enter ;;
            4) svc_restart "$SNELL_SERVICE"; log_ok "Snell 已重启。"; press_enter ;;
            5) snell_logs ;;
            6) snell_update;                                           press_enter ;;
            7) snell_uninstall;                                        press_enter ;;
            8) snell_diagnose;                                         press_enter ;;
            0) return ;;
        esac
    done
}
