#!/usr/bin/env bash
# xray/core.sh — Xray-core install, upgrade, service management

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_CFG="$XRAY_CFG_DIR/config.json"
XRAY_RELEASES="https://github.com/XTLS/Xray-core/releases"

# ── Timezone wizard ───────────────────────────────────────────────────────────
_tz_set_wizard() {
    local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null \
                     || cat /etc/timezone 2>/dev/null || echo "unknown")
    echo -e "\n${BOLD}时区设置${NC}  当前：${CYAN}${cur}${NC}"
    echo -e "  ${CYAN}1.${NC} Asia/Hong_Kong   (UTC+8 · 香港)  [默认]"
    echo -e "  ${CYAN}2.${NC} Asia/Singapore   (UTC+8 · 新加坡)"
    echo -e "  ${CYAN}3.${NC} Asia/Shanghai    (UTC+8 · 上海)"
    echo -e "  ${CYAN}4.${NC} UTC              (协调世界时)"
    echo -e "  ${CYAN}0.${NC} 跳过，保持当前时区"
    local choice
    read -rp "$(echo -e "${CYAN}选择时区 [默认 1]: ${NC}")" choice
    choice="${choice:-1}"

    local tz=""
    case "$choice" in
        1) tz="Asia/Hong_Kong" ;;
        2) tz="Asia/Singapore" ;;
        3) tz="Asia/Shanghai"  ;;
        4) tz="UTC"            ;;
        0) log_info "跳过时区设置。"; return ;;
        *) log_warn "无效选项，跳过时区设置。"; return ;;
    esac

    if timedatectl set-timezone "$tz" 2>/dev/null; then
        : # timedatectl handles /etc/localtime symlink automatically
    else
        # Fallback for containers / systems without timedatectl
        ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null || true
        echo "$tz" > /etc/timezone 2>/dev/null || true
    fi
    timedatectl set-ntp true 2>/dev/null || true
    log_ok "时区已设置为 ${CYAN}${tz}${NC}，NTP 同步已启用。"
}

# ── Install ───────────────────────────────────────────────────────────────────
xray_install() {
    ensure_pkg_deps curl unzip jq
    require_cmd curl unzip jq

    if is_installed xray || [[ -f "$XRAY_BIN" ]]; then
        log_info "Xray 已安装：$($XRAY_BIN version 2>/dev/null | head -1)"
        ask_yn "是否重新安装 Xray？" N || return 0
    fi

    _tz_set_wizard

    local arch; arch=$(get_arch)
    local xray_arch
    case "$arch" in
        amd64) xray_arch="64" ;;
        arm64) xray_arch="arm64-v8a" ;;
        arm32) xray_arch="arm32-v7a" ;;
        *)     die "Xray 不支持此架构：$arch" ;;
    esac

    local tag

    log_step "正在获取 Xray 最新版本..."
    tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
          | grep '"tag_name"' | cut -d'"' -f4 || true)
    [[ -z "$tag" ]] && { log_warn "无法获取最新版本，使用备用版本 v24.9.30"; tag="v24.9.30"; }

    local zip_name="Xray-linux-${xray_arch}.zip"
    local url="${XRAY_RELEASES}/download/${tag}/${zip_name}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    log_step "正在下载 Xray ${tag} (${xray_arch})..."
    curl -fsSL -o "$tmp_dir/$zip_name" "$url" \
        || die "下载失败：$url"

    unzip -q "$tmp_dir/$zip_name" -d "$tmp_dir/xray"

    install -m 755 "$tmp_dir/xray/xray"    /usr/local/bin/xray
    install -m 644 "$tmp_dir/xray/geoip.dat"   /usr/local/share/xray/ 2>/dev/null || true
    install -m 644 "$tmp_dir/xray/geosite.dat" /usr/local/share/xray/ 2>/dev/null || true
    mkdir -p /usr/local/share/xray
    cp "$tmp_dir/xray"/geo*.dat /usr/local/share/xray/ 2>/dev/null || true

    rm -rf "$tmp_dir"
    mkdir -p "$XRAY_CFG_DIR"

    if [[ -f "$XRAY_CFG" ]]; then
        if ! "$XRAY_BIN" run -test -config "$XRAY_CFG" &>/dev/null \
            && ! "$XRAY_BIN" -test -config "$XRAY_CFG" &>/dev/null; then
            local backup_cfg="${XRAY_CFG}.bad.$(date +%Y%m%d%H%M%S)"
            cp -a "$XRAY_CFG" "$backup_cfg"
            log_warn "现有 Xray 配置无效，已备份到 $backup_cfg，并写入干净的基础配置。"
            _write_skeleton_config
        fi
    else
        _write_skeleton_config
    fi

    _write_xray_service
    systemctl daemon-reload
    svc_enable xray
    svc_restart xray || svc_start xray
    log_ok "Xray ${tag} 已安装。"
    _xray_post_install_wizard
}

_write_skeleton_config() {
    cat > "$XRAY_CFG" <<'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
    mkdir -p /var/log/xray
}

_write_xray_service() {
    cat > "$XRAY_SERVICE" <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

xray_gen_x25519_keys() {
    local output private_key public_key
    output=$("$XRAY_BIN" x25519 2>&1) || {
        log_error "生成 x25519 密钥失败。"
        echo "$output" >&2
        return 1
    }

    private_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
    public_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "解析 x25519 密钥失败，原始输出："
        echo "$output" >&2
        return 1
    fi

    printf '%s\t%s\n' "$private_key" "$public_key"
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
xray_upgrade() {
    log_step "正在升级 Xray（重新运行安装流程）..."
    xray_install
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
xray_uninstall() {
    echo -e "\n${YELLOW}将同时删除：Xray 程序/服务/配置，以及所有 Reality、Vision、XHTTP、SS2022 节点。${NC}"
    ask_yn "确认完全卸载？" N || return 0

    # ── Stop service ──────────────────────────────────────────────────────────
    svc_stop xray 2>/dev/null || true
    systemctl disable xray --quiet 2>/dev/null || true
    systemctl disable --now psm-reality-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/psm-reality-watchdog.service /etc/systemd/system/psm-reality-watchdog.timer

    # ── Clean protocol nodes: SNI entries + traffic records ───────────────────
    source "$LIB_DIR/nginx.sh"   2>/dev/null || true
    source "$LIB_DIR/traffic.sh" 2>/dev/null || true
    [[ -f "${CFG_DIR}/traffic/state.json" ]] && _trf_init 2>/dev/null || true

    # Reality
    if [[ -f "$CFG_DIR/xray/reality.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/reality.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _listen _sn; do
            [[ "$_listen" == "127.0.0.1" ]] && _sni_remove_entry "$_sn" 2>/dev/null || true
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_reality_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/reality.json"
    fi

    # Vision
    if [[ -f "$CFG_DIR/xray/vision.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/vision.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _listen _domain; do
            _sni_remove_entry "$_domain" 2>/dev/null || true
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_vision_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/vision.json"
    fi

    # XHTTP
    if [[ -f "$CFG_DIR/xray/xhttp.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _listen _mode _domain; do
            [[ -n "$_domain" ]] && _sni_remove_entry "$_domain" 2>/dev/null || true
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_xhttp_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/xhttp.json"
    fi

    # SS2022
    if [[ -f "$CFG_DIR/xray/ss2022.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _method _listen; do
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_xss_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/ss2022.json"
    fi

    # Custom outbounds (incl. WARP) + routing rules + saved WARP identity
    rm -f "$CFG_DIR/xray/outbounds.json" "$CFG_DIR/xray/routing_rules.json" \
          "$CFG_DIR/xray/warp_account.json" "$CFG_DIR/xray/reality_watchdog.json"

    # ── Binary, service, Xray config dir, geo data, logs ─────────────────────
    rm -f  "$XRAY_BIN" "$XRAY_SERVICE"
    rm -rf "$XRAY_CFG_DIR" /usr/local/share/xray /var/log/xray
    systemctl daemon-reload

    log_ok "Xray 及所有 Reality / Vision / XHTTP / SS2022 节点配置已完全删除。"
}

# ── Config helpers ────────────────────────────────────────────────────────────
xray_get_inbounds() {
    jq -r '.inbounds[]? | "\(.tag // "unnamed")\t\(.protocol)\t\(.port)"' "$XRAY_CFG" 2>/dev/null
}

xray_add_inbound() {
    local fragment="$1"
    local tmp; tmp=$(mktemp)
    jq ".inbounds += [$fragment]" "$XRAY_CFG" > "$tmp" && mv "$tmp" "$XRAY_CFG"
}

xray_remove_inbound_by_tag() {
    local tag="$1"
    local tmp; tmp=$(mktemp)
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$XRAY_CFG" > "$tmp" && mv "$tmp" "$XRAY_CFG"
}

xray_update_inbound() {
    local tag="$1" new_json="$2"
    xray_remove_inbound_by_tag "$tag"
    xray_add_inbound "$new_json"
}

# ── Status & logs ─────────────────────────────────────────────────────────────
xray_version() {
    "$XRAY_BIN" version 2>/dev/null | head -3
}

xray_logs() {
    echo -e "\n  1. 访问日志\n  2. 错误日志\n  3. Systemd 日志"
    read -rp "$(echo -e "${CYAN}请选择: ${NC}")" lc
    case "$lc" in
        1) tail -f /var/log/xray/access.log ;;
        2) tail -f /var/log/xray/error.log ;;
        3) journalctl -u xray -f --no-pager ;;
    esac
}

# ── Post-install protocol wizard ─────────────────────────────────────────────
_xray_post_install_wizard() {
    echo ""
    ask_yn "是否现在配置一个协议节点？" Y || return 0
    echo -e "\n  请选择协议："
    echo -e "  1. VLESS + Reality   (可用任意伪装 SNI，无需 TLS 证书)"
    echo -e "  2. VLESS + Vision    (需要自己的域名和 TLS 证书)"
    echo -e "  3. VLESS + XHTTP     (支持多种传输模式)"
    echo -e "  4. Shadowsocks 2022  (AEAD-2022 加密，无需域名/TLS)"
    read -rp "$(echo -e "${CYAN}请选择 [1]: ${NC}")" pc
    echo ""
    case "${pc:-1}" in
        1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"; reality_add_node ;;
        2) source "$(dirname "${BASH_SOURCE[0]}")/vision.sh";  vision_add_node ;;
        3) source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh";   xhttp_add_node ;;
        4) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh";  xss_add_node ;;
        *) log_info "已跳过。之后可在“协议节点”菜单中配置。" ;;
    esac
}

# ── Dependency & install check ────────────────────────────────────────────────
_xray_check_deps() {
    ensure_pkg_deps curl unzip jq
}

_xray_require_installed() {
    if [[ ! -f "$XRAY_BIN" ]]; then
        log_warn "Xray 尚未安装，请先选择“安装”。"
        press_enter
        return 1
    fi
}

# Warn (don't hard-block — reusing a port across sibling nodes/redeploys is
# legitimate) if a freshly-chosen port collides with anything PSM already
# knows about (SSH, other protocols, honeypot ports) or is currently
# listening. Same detection the Docker app-store deploy flow reuses.
# Returns 0 = proceed, 1 = abort. Only call this for a port the user just
# picked — not for ports inherited via SNI/port reuse between sibling nodes.
_xray_check_port_conflict() {
    local port="$1"
    source "$LIB_DIR/security/honeypot.sh" 2>/dev/null || return 0
    declare -f _hp_is_reserved_port &>/dev/null || return 0
    _hp_is_reserved_port "$port" || return 0
    log_warn "端口 ${port} 似乎已被占用（本机服务、防火墙已放行的端口，或已配置的代理节点/蜜罐）"
    ask_yn "仍要使用这个端口吗？" N
}

# ── Centralized node viewer ───────────────────────────────────────────────────
_xray_view_all_nodes() {
    source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/vision.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh"

    local -a _protos _tags
    local i=0

    echo -e "\n${BOLD}${BLUE}══ 已配置的 Xray 节点 ════════════════${NC}"

    while IFS=$'\t' read -r tag port listen sn; do
        i=$((i+1)); _protos+=("reality"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Reality]${NC}  %-18s  port=%-6s  listen=%-15s  sni=%s\n" \
               "$i" "$tag" "$port" "$listen" "$sn"
    done < <(_reality_list 2>/dev/null)

    while IFS=$'\t' read -r tag port listen domain; do
        i=$((i+1)); _protos+=("vision"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${BLUE}[Vision]${NC}   %-18s  port=%-6s  listen=%-15s  domain=%s\n" \
               "$i" "$tag" "$port" "$listen" "$domain"
    done < <(_vision_list 2>/dev/null)

    while IFS=$'\t' read -r tag port listen mode domain; do
        i=$((i+1)); _protos+=("xhttp"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${YELLOW}[XHTTP/%-8s]${NC} %-18s  port=%-6s  listen=%-15s  domain=%s\n" \
               "$i" "$mode" "$tag" "$port" "$listen" "$domain"
    done < <(_xhttp_list 2>/dev/null)

    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); _protos+=("ss2022"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${CYAN}[SS2022]${NC}   %-18s  port=%-6s  %s\n" \
               "$i" "$tag" "$port" "$method"
    done < <(_xss_list 2>/dev/null)

    if (( i == 0 )); then
        log_warn "尚未配置任何节点。"
        return
    fi

    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}选择节点查看链接和二维码（0 = 返回）: ${NC}")" sel

    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "无效选项。"; return
    fi

    local proto="${_protos[$((sel-1))]}"
    local tag="${_tags[$((sel-1))]}"
    echo ""
    case "$proto" in
        reality) reality_show_uri  "$tag" ;;
        vision)  vision_show_share "$tag" ;;
        xhttp)   xhttp_show_share  "$tag" ;;
        ss2022)  _xss_uri          "$tag" ;;
    esac
}

# ── Protocol nodes sub-menu ───────────────────────────────────────────────────
_xray_protocol_menu() {
    while true; do
        show_menu "节点管理 — 选择协议进入" \
            "Reality   (VLESS + XTLS-Reality，无需 TLS 证书)" \
            "Vision    (VLESS + TLS + TCP，需要域名和证书)" \
            "XHTTP     (VLESS + XHTTP / WebSocket，需要域名和证书)" \
            "SS2022    (Shadowsocks 2022，AEAD-2022 加密)"

        case "$MENU_CHOICE" in
            1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"; reality_menu ;;
            2) source "$LIB_DIR/nginx.sh"; source "$(dirname "${BASH_SOURCE[0]}")/vision.sh"; vision_menu ;;
            3) source "$LIB_DIR/nginx.sh"; source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh"; xhttp_menu ;;
            4) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh"; xss_menu ;;
            0) return ;;
        esac
    done
}

# ── Menu ──────────────────────────────────────────────────────────────────────
xray_menu() {
    _xray_check_deps
    while true; do
        show_menu "Xray 管理" \
            "安装" \
            "升级" \
            "卸载" \
            "节点管理" \
            "路由分流管理" \
            "显示版本" \
            "列出入站配置" \
            "测试配置" \
            "重启服务" \
            "服务状态" \
            "查看日志" \
            "查看节点链接和二维码"

        case "$MENU_CHOICE" in
            1)  xray_install;    press_enter ;;
            2)  xray_upgrade;    press_enter ;;
            3)  xray_uninstall;  press_enter ;;
            4)  _xray_require_installed && _xray_protocol_menu ;;
            5)  _xray_require_installed && {
                    source "$(dirname "${BASH_SOURCE[0]}")/routing.sh"
                    route_menu
                } ;;
            6)  xray_version;    press_enter ;;
            7)  echo -e "\n${BOLD}入站配置:${NC}"; xray_get_inbounds; press_enter ;;
            8)  "$XRAY_BIN" -test -config "$XRAY_CFG" && log_ok "配置正常" || log_error "配置有误"; press_enter ;;
            9)  xray_test_restart; press_enter ;;
            10) svc_status xray;   press_enter ;;
            11) xray_logs ;;
            12) _xray_require_installed && { _xray_view_all_nodes; press_enter; } ;;
            0)  return ;;
        esac
    done
}
