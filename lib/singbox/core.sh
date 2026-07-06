#!/usr/bin/env bash
# singbox/core.sh — sing-box install, upgrade, service management
#
# sing-box 与 Xray 是两个独立内核：单二进制、单配置文件（/etc/sing-box/config.json），
# 结构为 inbounds / outbounds / route。本模块与 lib/xray/ 平行，互不干扰，可共存。
# 所有终端输出走 i18n（t sb.*），支持中/英切换。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

SB_BIN="$SINGBOX_BIN"
SB_CFG_DIR="$SINGBOX_CFG_DIR"
SB_CFG="$SB_CFG_DIR/config.json"
SB_SERVICE="/etc/systemd/system/sing-box.service"
SB_STORE_DIR="$CFG_DIR/singbox"        # 各协议节点存储（唯一事实源）
SB_RELEASES="https://github.com/SagerNet/sing-box/releases"

# ── Install ───────────────────────────────────────────────────────────────────
sb_install() {
    ensure_pkg_deps curl tar jq
    require_cmd curl tar jq

    if [[ -f "$SB_BIN" ]]; then
        log_info "$(t sb.installed "$($SB_BIN version 2>/dev/null | head -1)")"
        ask_yn "$(t sb.ask_reinstall)" N || return 0
    fi

    local arch; arch=$(get_arch)
    local sb_arch
    case "$arch" in
        amd64) sb_arch="amd64" ;;
        arm64) sb_arch="arm64" ;;
        arm32) sb_arch="armv7" ;;
        *)     die "$(t sb.unsupported_arch "$arch")" ;;
    esac

    local tag
    log_step "$(t sb.fetching_latest)"
    tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
          | jq -r '.tag_name // empty' || true)
    # 主路径始终取 GitHub 最新稳定版（/releases/latest 已排除 alpha/beta）。
    # 备用版本仅在 API 不可达时使用，固定为一个支持全部协议的版本
    # （Snell 入站需 1.14+，AnyTLS 需 1.12+）。
    [[ "$tag" =~ ^v[0-9] ]] || { log_warn "$(t sb.latest_fallback)"; tag="v1.14.0"; }

    local ver="${tag#v}"
    local tarball="sing-box-${ver}-linux-${sb_arch}.tar.gz"
    local url="${SB_RELEASES}/download/${tag}/${tarball}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    log_step "$(t sb.downloading "$tag" "$sb_arch")"
    curl -fsSL -o "$tmp_dir/$tarball" "$url" \
        || { rm -rf "$tmp_dir"; die "$(t sb.download_fail "$url")"; }

    tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir" \
        || { rm -rf "$tmp_dir"; die "$(t sb.extract_fail)"; }

    local bin_src; bin_src=$(find "$tmp_dir" -type f -name sing-box | head -1)
    [[ -n "$bin_src" ]] || { rm -rf "$tmp_dir"; die "$(t sb.extract_fail)"; }
    install -m 755 "$bin_src" "$SB_BIN"
    rm -rf "$tmp_dir"

    mkdir -p "$SB_CFG_DIR"
    # config.json 内含各节点密钥（UUID/密码/Reality 私钥）。目录设为仅 root 可读，
    # sing-box.service 以 root 运行，不受影响。
    chmod 700 "$SB_CFG_DIR" 2>/dev/null || true
    mkdir -p "$SB_STORE_DIR"

    if [[ -f "$SB_CFG" ]]; then
        if ! "$SB_BIN" check -c "$SB_CFG" &>/dev/null; then
            local backup_cfg="${SB_CFG}.bad.$(date +%Y%m%d%H%M%S)"
            cp -a "$SB_CFG" "$backup_cfg"
            log_warn "$(t sb.bad_config_backup "$backup_cfg")"
            _sb_write_skeleton_config
        fi
    else
        _sb_write_skeleton_config
    fi

    _sb_write_service
    systemctl daemon-reload
    svc_enable sing-box
    svc_restart sing-box || svc_start sing-box
    log_ok "$(t sb.install_done "$tag")"
    _sb_post_install_wizard
}

# 现代 sing-box（1.11+）路由使用 action 语义：sniff 嗅探、reject 拦截私网。
_sb_write_skeleton_config() {
    cat > "$SB_CFG" <<'EOF'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "ip_is_private": true, "action": "reject" }
    ],
    "final": "direct"
  }
}
EOF
}

_sb_write_service() {
    cat > "$SB_SERVICE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SB_BIN} run -c ${SB_CFG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ── Key / id generation ───────────────────────────────────────────────────────
# 解析 `sing-box generate reality-keypair` 输出，回填 SB_REALITY_PRIVATE_KEY /
# SB_REALITY_PUBLIC_KEY。输出形如：PrivateKey: xxxx / PublicKey: yyyy。
sb_gen_reality_keys() {
    local output private_key public_key
    output=$("$SB_BIN" generate reality-keypair 2>&1) || {
        log_error "$(t sb.keypair_gen_fail)"
        echo "$output" >&2
        return 1
    }
    private_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
    public_key=$(echo "$output"  | awk -F': *' 'tolower($1) ~ /public/  {print $2; exit}')
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "$(t sb.keypair_parse_fail)"
        echo "$output" >&2
        return 1
    fi
    printf '%s\t%s\n' "$private_key" "$public_key"
}

# ── TLS helpers (shared by hysteria2 / anytls) ───────────────────────────────
# 生成 P-256 自签名证书（无真实域名时的 TLS 兜底）。输出：<crt>\t<key>。
_sb_ensure_self_signed() {
    local cn="$1" name="$2"
    local dir="$SB_CFG_DIR/certs"; mkdir -p "$dir"
    local crt="$dir/${name}.crt" key="$dir/${name}.key"
    if [[ ! -s "$crt" || ! -s "$key" ]]; then
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "$key" -out "$crt" -days 3650 -subj "/CN=${cn}" 2>/dev/null
        chmod 600 "$key" 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$crt" "$key"
}

# 解析 TLS 证书来源：有真实域名走 cert.sh 签发的证书，否则自签名。
# 用法：_sb_resolve_tls <domain-or-empty> <self-signed-name> <fake-sni>
# 输出（\t 分隔）：cert_path  key_path  sni  insecure(0/1)
_sb_resolve_tls() {
    local domain="$1" name="$2" fake_sni="$3"
    if [[ -n "$domain" ]]; then
        source "$LIB_DIR/cert.sh"
        if cert_ensure_domain "$domain" 2>/dev/null; then
            local d="$NGINX_SSL_DIR/$domain"
            if [[ -s "$d/fullchain.pem" && -s "$d/privkey.pem" ]]; then
                printf '%s\t%s\t%s\t0\n' "$d/fullchain.pem" "$d/privkey.pem" "$domain"
                return 0
            fi
        fi
        log_warn "$(t sb.tls.cert_unavailable)"
    fi
    local pair; pair=$(_sb_ensure_self_signed "$fake_sni" "$name")
    printf '%s\t%s\t%s\t1\n' "${pair%%$'\t'*}" "${pair#*$'\t'}" "$fake_sni"
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
sb_upgrade() {
    log_step "$(t sb.upgrading)"
    sb_install
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
sb_uninstall() {
    echo -e "\n${YELLOW}$(t sb.uninstall_warn)${NC}"
    ask_yn "$(t sb.ask_uninstall)" N || return 0

    svc_stop sing-box 2>/dev/null || true
    systemctl disable sing-box --quiet 2>/dev/null || true

    # 清理各协议节点的流量记录（节点存储随目录一并删除）
    source "$LIB_DIR/traffic.sh" 2>/dev/null || true
    [[ -f "${CFG_DIR}/traffic/state.json" ]] && _trf_init 2>/dev/null || true
    if [[ -f "$SB_STORE_DIR/reality.json" ]]; then
        while IFS=$'\t' read -r _tag _rest; do
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(jq -r '.[]?.tag' "$SB_STORE_DIR/reality.json" 2>/dev/null)
    fi
    local _store
    for _store in ss2022 hysteria2 anytls snell; do
        [[ -f "$SB_STORE_DIR/$_store.json" ]] || continue
        while IFS=$'\t' read -r _tag _rest; do
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(jq -r '.[]?.tag' "$SB_STORE_DIR/$_store.json" 2>/dev/null)
    done

    rm -f  "$SB_BIN" "$SB_SERVICE"
    rm -rf "$SB_CFG_DIR" "$SB_STORE_DIR"
    systemctl daemon-reload

    log_ok "$(t sb.uninstalled)"
}

# ── Config helpers ────────────────────────────────────────────────────────────
sb_get_inbounds() {
    jq -r '.inbounds[]? | "\(.tag // "unnamed")\t\(.type)\t\(.listen_port // "-")"' "$SB_CFG" 2>/dev/null
}

sb_add_inbound() {
    local fragment="$1"
    local tmp; tmp=$(mktemp)
    jq ".inbounds += [$fragment]" "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"
}

sb_remove_inbound_by_tag() {
    local tag="$1"
    local tmp; tmp=$(mktemp)
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"
}

# 原子替换 SB_CFG：仅当候选文件为非空合法 JSON 时才落盘，避免 jq 半路失败
# 写入空/残缺内容抹掉运行中的配置。语义校验由调用方的 sb_test_restart 负责。
_sb_write_cfg_checked() {
    local candidate="$1"
    if [[ ! -s "$candidate" ]] || ! jq -e . "$candidate" >/dev/null 2>&1; then
        log_error "$(t sb.write_invalid)"
        rm -f "$candidate"
        return 1
    fi
    mv -f "$candidate" "$SB_CFG"
}

# 校验并重启：先 sing-box check，通过再 restart。失败保留原配置并回显错误。
sb_test_restart() {
    local test_out
    if test_out=$("$SB_BIN" check -c "$SB_CFG" 2>&1); then
        svc_restart sing-box && { log_ok "$(t sb.restarted)"; return 0; }
        log_error "$(t sb.restart_fail)"
        return 1
    fi
    log_error "$(t sb.test_fail)"
    echo "$test_out" >&2
    return 1
}

# ── Status & logs ─────────────────────────────────────────────────────────────
sb_version() {
    "$SB_BIN" version 2>/dev/null | head -3
}

sb_logs() {
    journalctl -u sing-box -f --no-pager
}

# ── Post-install protocol wizard ─────────────────────────────────────────────
_sb_post_install_wizard() {
    echo ""
    ask_yn "$(t sb.ask_protocol_now)" Y || return 0
    echo -e "\n  $(t sb.protocol_choose)"
    echo -e "  1. $(t sb.protocol.reality)"
    echo -e "  2. $(t sb.protocol.ss2022)"
    echo -e "  3. $(t sb.protocol.hysteria2)"
    echo -e "  4. $(t sb.protocol.anytls)"
    echo -e "  5. $(t sb.protocol.snell)"
    read -rp "$(echo -e "${CYAN}$(t sb.ask_select_default)${NC}")" pc
    echo ""
    case "${pc:-1}" in
        1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh";   sb_reality_add_node ;;
        2) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh";    sb_ss_add_node ;;
        3) source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"; sb_hy2_add_node ;;
        4) source "$(dirname "${BASH_SOURCE[0]}")/anytls.sh";    sb_anytls_add_node ;;
        5) source "$(dirname "${BASH_SOURCE[0]}")/snell.sh";     sb_snell_add_node ;;
        *) log_info "$(t sb.protocol_skipped)" ;;
    esac
}

# ── Dependency & install check ────────────────────────────────────────────────
_sb_check_deps() {
    ensure_pkg_deps curl tar jq
}

_sb_require_installed() {
    if [[ ! -f "$SB_BIN" ]]; then
        log_warn "$(t sb.need_install)"
        press_enter
        return 1
    fi
}

# 端口冲突提示（复用蜜罐模块的保留端口检测，与 xray 逻辑一致）。
# 返回 0=继续，1=中止。
_sb_check_port_conflict() {
    local port="$1"
    source "$LIB_DIR/security/honeypot.sh" 2>/dev/null || return 0
    declare -f _hp_is_reserved_port &>/dev/null || return 0
    _hp_is_reserved_port "$port" || return 0
    log_warn "$(t sb.port_conflict "$port")"
    ask_yn "$(t sb.ask_use_port)" N
}

# ── Centralized node viewer ───────────────────────────────────────────────────
_sb_view_all_nodes() {
    source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/anytls.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/snell.sh"

    _sb_reality_sync_from_live || true
    _sb_ss_sync_from_live      || true

    local -a _protos _tags
    local i=0

    echo -e "\n${BOLD}${BLUE}══ $(t sb.nodes.title) ════════════════${NC}"

    while IFS=$'\t' read -r tag port listen sn; do
        i=$((i+1)); _protos+=("reality"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Reality]${NC}  %-18s  port=%-6s  listen=%-15s  sni=%s\n" \
               "$i" "$tag" "$port" "$listen" "$sn"
    done < <(_sb_reality_list 2>/dev/null)

    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); _protos+=("ss2022"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${CYAN}[SS2022]${NC}   %-18s  port=%-6s  %s\n" \
               "$i" "$tag" "$port" "$method"
    done < <(_sb_ss_list 2>/dev/null)

    while IFS=$'\t' read -r tag port sn _; do
        i=$((i+1)); _protos+=("hysteria2"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${YELLOW}[Hysteria2]${NC} %-16s  port=%-6s  sni=%s\n" \
               "$i" "$tag" "$port" "$sn"
    done < <(_sb_hy2_list 2>/dev/null)

    while IFS=$'\t' read -r tag port sn _; do
        i=$((i+1)); _protos+=("anytls"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${BLUE}[AnyTLS]${NC}   %-18s  port=%-6s  sni=%s\n" \
               "$i" "$tag" "$port" "$sn"
    done < <(_sb_anytls_list 2>/dev/null)

    while IFS=$'\t' read -r tag port ver _; do
        i=$((i+1)); _protos+=("snell"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Snell]${NC}    %-18s  port=%-6s  v%s\n" \
               "$i" "$tag" "$port" "$ver"
    done < <(_sb_snell_list 2>/dev/null)

    if (( i == 0 )); then
        log_warn "$(t sb.no_nodes)"
        return
    fi

    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t sb.ask_node_share): ${NC}")" sel

    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return
    fi

    local proto="${_protos[$((sel-1))]}"
    local tag="${_tags[$((sel-1))]}"
    echo ""
    case "$proto" in
        reality)   sb_reality_show_uri "$tag" ;;
        ss2022)    _sb_ss_uri          "$tag" ;;
        hysteria2) _sb_hy2_uri         "$tag" ;;
        anytls)    _sb_anytls_uri      "$tag" ;;
        snell)     _sb_snell_share     "$tag" ;;
    esac
}

# ── Protocol nodes sub-menu ───────────────────────────────────────────────────
_sb_protocol_menu() {
    while true; do
        show_menu "$(t sb.protocol_menu.title)" \
            "$(t sb.protocol_menu.reality)" \
            "$(t sb.protocol_menu.ss2022)" \
            "$(t sb.protocol_menu.hysteria2)" \
            "$(t sb.protocol_menu.anytls)" \
            "$(t sb.protocol_menu.snell)"

        case "$MENU_CHOICE" in
            1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh";   sb_reality_menu ;;
            2) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh";    sb_ss_menu ;;
            3) source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"; sb_hy2_menu ;;
            4) source "$(dirname "${BASH_SOURCE[0]}")/anytls.sh";    sb_anytls_menu ;;
            5) source "$(dirname "${BASH_SOURCE[0]}")/snell.sh";     sb_snell_menu ;;
            0) return ;;
        esac
    done
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_menu() {
    _sb_check_deps
    while true; do
        show_menu "$(t sb.menu.title)" \
            "$(t sb.menu.install)" \
            "$(t sb.menu.upgrade)" \
            "$(t sb.menu.uninstall)" \
            "$(t sb.menu.nodes)" \
            "$(t sb.menu.routing)" \
            "$(t sb.menu.version)" \
            "$(t sb.menu.inbounds)" \
            "$(t sb.menu.test)" \
            "$(t sb.menu.restart)" \
            "$(t sb.menu.status)" \
            "$(t sb.menu.logs)" \
            "$(t sb.menu.share)"

        case "$MENU_CHOICE" in
            1)  sb_install;    press_enter ;;
            2)  sb_upgrade;    press_enter ;;
            3)  sb_uninstall;  press_enter ;;
            4)  _sb_require_installed && _sb_protocol_menu ;;
            5)  _sb_require_installed && {
                    source "$(dirname "${BASH_SOURCE[0]}")/routing.sh"
                    sb_route_menu
                } ;;
            6)  sb_version;    press_enter ;;
            7)  echo -e "\n${BOLD}$(t sb.inbounds_title)${NC}"; sb_get_inbounds; press_enter ;;
            8)  "$SB_BIN" check -c "$SB_CFG" && log_ok "$(t sb.config_ok)" || log_error "$(t sb.config_bad)"; press_enter ;;
            9)  sb_test_restart; press_enter ;;
            10) svc_status sing-box;   press_enter ;;
            11) sb_logs ;;
            12) _sb_require_installed && { _sb_view_all_nodes; press_enter; } ;;
            0)  return ;;
        esac
    done
}
