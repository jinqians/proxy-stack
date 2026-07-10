#!/usr/bin/env bash
# mihomo/core.sh — mihomo install, upgrade, service management
#
# mihomo 与 Xray 是两个独立内核：单二进制、单配置文件（/etc/mihomo/config.yaml），
# 结构为 listeners / proxies / proxy-groups / rules。本模块与 lib/xray/ 平行，互不干扰，可共存。
# 所有终端输出走 i18n（t mh.*），支持中 / 英 / 韩 / 俄四语言。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

MH_BIN="$MIHOMO_BIN"
MH_CFG_DIR="$MIHOMO_CFG_DIR"
MH_CFG="$MH_CFG_DIR/config.yaml"
MH_SERVICE="/etc/systemd/system/mihomo.service"
MH_STORE_DIR="$CFG_DIR/mihomo"        # 各协议节点存储（唯一事实源）
MH_RELEASES="https://github.com/MetaCubeX/mihomo/releases"

# ── Install ───────────────────────────────────────────────────────────────────
mh_install() {
    ensure_pkg_deps curl gzip jq openssl
    require_cmd curl gunzip jq openssl

    if [[ -f "$MH_BIN" ]]; then
        log_info "$(t mh.installed "$($MH_BIN -v 2>/dev/null | head -1)")"
        ask_yn "$(t mh.ask_reinstall)" N || return 0
    fi

    local arch; arch=$(get_arch)
    local asset_arch
    case "$arch" in
        amd64) asset_arch="amd64-compatible" ;;
        arm64) asset_arch="arm64" ;;
        arm32) asset_arch="armv7" ;;
        *)     die "$(t mh.unsupported_arch "$arch")" ;;
    esac

    local tag
    log_step "$(t mh.fetching_latest)"
    tag=$(curl -fsSL "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
          | jq -r '.tag_name // empty' || true)
    [[ "$tag" =~ ^v[0-9] ]] || { log_warn "$(t mh.latest_fallback)"; tag="v1.19.27"; }

    local asset="mihomo-linux-${asset_arch}-${tag}.gz"
    local url="${MH_RELEASES}/download/${tag}/${asset}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    log_step "$(t mh.downloading "$tag" "$asset_arch")"
    curl -fsSL -o "$tmp_dir/$asset" "$url" \
        || { rm -rf "$tmp_dir"; die "$(t mh.download_fail "$url")"; }

    gunzip -f "$tmp_dir/$asset" \
        || { rm -rf "$tmp_dir"; die "$(t mh.extract_fail)"; }

    local bin_src; bin_src=$(find "$tmp_dir" -type f -name 'mihomo-*' | head -1)
    [[ -n "$bin_src" ]] || { rm -rf "$tmp_dir"; die "$(t mh.extract_fail)"; }
    install -m 755 "$bin_src" "$MH_BIN"
    rm -rf "$tmp_dir"

    mkdir -p "$MH_CFG_DIR"
    # config.yaml 内含各节点密钥（UUID/密码/Reality 私钥）。目录设为仅 root 可读，
    # mihomo.service 以 root 运行，不受影响。
    chmod 700 "$MH_CFG_DIR" 2>/dev/null || true
    mkdir -p "$MH_STORE_DIR"

    if [[ -f "$MH_CFG" ]]; then
        if ! "$MH_BIN" -t -d "$MH_CFG_DIR" -f "$MH_CFG" &>/dev/null; then
            local backup_cfg="${MH_CFG}.bad.$(date +%Y%m%d%H%M%S)"
            cp -a "$MH_CFG" "$backup_cfg"
            log_warn "$(t mh.bad_config_backup "$backup_cfg")"
            _mh_write_skeleton_config
        fi
    else
        _mh_write_skeleton_config
    fi

    _mh_write_service
    systemctl daemon-reload
    svc_enable mihomo
    svc_restart mihomo || svc_start mihomo
    log_ok "$(t mh.install_done "$tag")"
    _mh_post_install_wizard
}

_mh_write_skeleton_config() {
    cat > "$MH_CFG" <<'EOF'
{
  "log-level": "warning",
  "mode": "rule",
  "listeners": [],
  "proxies": [],
  "proxy-groups": [],
  "rules": ["MATCH,DIRECT"]
}
EOF
}

_mh_write_service() {
    cat > "$MH_SERVICE" <<EOF
[Unit]
Description=mihomo Meta service
Documentation=https://wiki.metacubex.one
After=network.target nss-lookup.target network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${MH_BIN} -d ${MH_CFG_DIR} -f ${MH_CFG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ── Key / id generation ───────────────────────────────────────────────────────
# 解析 `mihomo generate reality-keypair` 输出，回填 MH_REALITY_PRIVATE_KEY /
# MH_REALITY_PUBLIC_KEY。输出形如：PrivateKey: xxxx / PublicKey: yyyy。
mh_gen_reality_keys() {
    local output private_key public_key
    output=$("$MH_BIN" generate reality-keypair 2>&1) || {
        log_error "$(t mh.keypair_gen_fail)"
        echo "$output" >&2
        return 1
    }
    private_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
    public_key=$(echo "$output"  | awk -F': *' 'tolower($1) ~ /public/  {print $2; exit}')
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "$(t mh.keypair_parse_fail)"
        echo "$output" >&2
        return 1
    fi
    printf '%s\t%s\n' "$private_key" "$public_key"
}

mh_gen_uuid() {
    "$MH_BIN" generate uuid 2>/dev/null || uuid_gen
}

# ── TLS helpers (shared by hysteria2 / anytls) ───────────────────────────────
# 生成 P-256 自签名证书（无真实域名时的 TLS 兜底）。输出：<crt>\t<key>。
_mh_ensure_self_signed() {
    local cn="$1" name="$2"
    local dir="$MH_CFG_DIR/certs"; mkdir -p "$dir"
    local crt="$dir/${name}.crt" key="$dir/${name}.key"
    if [[ ! -s "$crt" || ! -s "$key" ]]; then
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "$key" -out "$crt" -days 3650 -subj "/CN=${cn}" 2>/dev/null
        chmod 600 "$key" 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$crt" "$key"
}

# 解析 TLS 证书来源：有真实域名走 cert.sh 签发的证书，否则自签名。
# 用法：_mh_resolve_tls <domain-or-empty> <self-signed-name> <fake-sni>
# 输出（\t 分隔）：cert_path  key_path  sni  insecure(0/1)
_mh_resolve_tls() {
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
        log_warn "$(t mh.tls.cert_unavailable)"
    fi
    local pair; pair=$(_mh_ensure_self_signed "$fake_sni" "$name")
    printf '%s\t%s\t%s\t1\n' "${pair%%$'\t'*}" "${pair#*$'\t'}" "$fake_sni"
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
mh_upgrade() {
    log_step "$(t mh.upgrading)"
    mh_install
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
mh_uninstall() {
    echo -e "\n${YELLOW}$(t mh.uninstall_warn)${NC}"
    ask_yn "$(t mh.ask_uninstall)" N || return 0

    svc_stop mihomo 2>/dev/null || true
    systemctl disable mihomo --quiet 2>/dev/null || true

    # 清理各协议节点的流量记录（节点存储随目录一并删除）
    source "$LIB_DIR/traffic.sh" 2>/dev/null || true
    [[ -f "${CFG_DIR}/traffic/state.json" ]] && _trf_init 2>/dev/null || true
    if [[ -f "$MH_STORE_DIR/reality.json" ]]; then
        while IFS=$'\t' read -r _tag _rest; do
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(jq -r '.[]?.tag' "$MH_STORE_DIR/reality.json" 2>/dev/null)
    fi
    local _store
    for _store in ss2022 hysteria2 anytls snell; do
        [[ -f "$MH_STORE_DIR/$_store.json" ]] || continue
        while IFS=$'\t' read -r _tag _rest; do
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(jq -r '.[]?.tag' "$MH_STORE_DIR/$_store.json" 2>/dev/null)
    done

    rm -f  "$MH_BIN" "$MH_SERVICE"
    rm -rf "$MH_CFG_DIR" "$MH_STORE_DIR"
    systemctl daemon-reload

    log_ok "$(t mh.uninstalled)"
}

# ── Config helpers ────────────────────────────────────────────────────────────
mh_get_listeners() {
    jq -r '.listeners[]? | "\(.name // "unnamed")\t\(.type)\t\(.port // "-")"' "$MH_CFG" 2>/dev/null
}

mh_add_listener() {
    local fragment="$1"
    local tmp; tmp=$(mktemp)
    jq ".listeners += [$fragment]" "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"
}

mh_remove_listener_by_tag() {
    local tag="$1"
    local tmp; tmp=$(mktemp)
    jq "del(.listeners[] | select(.name == \"$tag\"))" "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"
}

# 原子替换 MH_CFG：仅当候选文件为非空合法 JSON 时才落盘，避免 jq 半路失败
# 写入空/残缺内容抹掉运行中的配置。语义校验由调用方的 mh_test_restart 负责。
_mh_write_cfg_checked() {
    local candidate="$1"
    if [[ ! -s "$candidate" ]] || ! jq -e . "$candidate" >/dev/null 2>&1; then
        log_error "$(t mh.write_invalid)"
        rm -f "$candidate"
        return 1
    fi
    mv -f "$candidate" "$MH_CFG"
}

# 事务化备份：协议模块 apply 前调用，把当前配置存为 ${MH_CFG}.prev。
# 协议模块是「先改配置再校验」，坏配置会先落盘；此备份供 mh_test_restart 回滚。
_mh_cfg_backup() {
    [[ -f "$MH_CFG" ]] || return 0
    cp -a "$MH_CFG" "${MH_CFG}.prev" 2>/dev/null || true
}

# 校验并重启：先 mihomo -t。
#  - 通过：删除 .prev 备份，再 restart（restart 失败维持原状返回 1）。
#  - 失败：坏配置已落盘，若存在 .prev 则 mv 回去真正恢复变更前配置，再回显错误。
mh_test_restart() {
    local test_out
    if test_out=$("$MH_BIN" -t -d "$MH_CFG_DIR" -f "$MH_CFG" 2>&1); then
        rm -f "${MH_CFG}.prev"
        svc_restart mihomo && { log_ok "$(t mh.restarted)"; return 0; }
        log_error "$(t mh.restart_fail)"
        return 1
    fi
    log_error "$(t mh.test_fail)"
    if [[ -f "${MH_CFG}.prev" ]]; then
        mv -f "${MH_CFG}.prev" "$MH_CFG"
        log_warn "$(t mh.rolled_back)"
    fi
    echo "$test_out" >&2
    return 1
}

# ── Version gate ──────────────────────────────────────────────────────────────
# 已安装 mihomo 的版本号（形如 1.13.14）；二进制缺失或无法解析时输出空串。
# `mihomo version` 首行形如：mihomo version 1.13.14 (...)。
_mh_installed_version() {
    [[ -x "$MH_BIN" ]] || return 1
    "$MH_BIN" -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# 点分版本比较：$1 >= $2 返回 0，否则返回 1。纯 bash 实现，不依赖 GNU sort -V
# （开发机 macOS 的 BSD sort 无 -V）。非数字后缀（如 1.14.0-beta）按 0 处理。
_mh_version_ge() {
    local a="$1" b="$2" i len x y
    local -a av bv
    IFS='.' read -ra av <<<"$a"
    IFS='.' read -ra bv <<<"$b"
    len=${#av[@]}; (( ${#bv[@]} > len )) && len=${#bv[@]}
    for (( i=0; i<len; i++ )); do
        x=${av[i]:-0}; y=${bv[i]:-0}
        x=${x%%[!0-9]*}; y=${y%%[!0-9]*}
        (( 10#${x:-0} > 10#${y:-0} )) && return 0
        (( 10#${x:-0} < 10#${y:-0} )) && return 1
    done
    return 0
}

# 运行时功能门禁：已装版本 < min 时 log_error 并 return 1。
# feature_key 是功能名的 i18n 键（如 mh.snell.feature），文案含当前版本与最低版本。
# 安装装的是 GitHub 最新稳定版，新协议入站可能要等更高稳定版发布，故提示升级路径。
_mh_require_version() {
    local min="$1" feature_key="$2"
    local feature; feature=$(t "$feature_key")
    local cur; cur=$(_mh_installed_version)
    if [[ -z "$cur" ]]; then
        log_error "$(t mh.ver.unknown "$feature" "$min")"
        return 1
    fi
    if ! _mh_version_ge "$cur" "$min"; then
        log_error "$(t mh.ver.too_low "$feature" "$cur" "$min")"
        return 1
    fi
    return 0
}

# ── Status & logs ─────────────────────────────────────────────────────────────
mh_version() {
    "$MH_BIN" -v 2>/dev/null | head -3
}

mh_logs() {
    journalctl -u mihomo -f --no-pager
}

# ── Post-install protocol wizard ─────────────────────────────────────────────
_mh_post_install_wizard() {
    echo ""
    ask_yn "$(t mh.ask_protocol_now)" Y || return 0
    echo -e "\n  $(t mh.protocol_choose)"
    echo -e "  1. $(t mh.protocol.reality)"
    echo -e "  2. $(t mh.protocol.ss2022)"
    echo -e "  3. $(t mh.protocol.hysteria2)"
    echo -e "  4. $(t mh.protocol.anytls)"
    echo -e "  5. $(t mh.protocol.snell)"
    read -rp "$(echo -e "${CYAN}$(t mh.ask_select_default)${NC}")" pc
    echo ""
    case "${pc:-1}" in
        1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh";   mh_reality_add_node ;;
        2) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh";    mh_ss_add_node ;;
        3) source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"; mh_hy2_add_node ;;
        4) source "$(dirname "${BASH_SOURCE[0]}")/anytls.sh";    mh_anytls_add_node ;;
        5) source "$(dirname "${BASH_SOURCE[0]}")/snell.sh";     mh_snell_add_node ;;
        *) log_info "$(t mh.protocol_skipped)" ;;
    esac
}

# ── Dependency & install check ────────────────────────────────────────────────
_mh_check_deps() {
    ensure_pkg_deps curl gzip jq openssl
}

_mh_require_installed() {
    if [[ ! -f "$MH_BIN" ]]; then
        log_warn "$(t mh.need_install)"
        press_enter
        return 1
    fi
}

# 端口冲突提示（复用蜜罐模块的保留端口检测，与 xray 逻辑一致）。
# 返回 0=继续，1=中止。
_mh_check_port_conflict() {
    local port="$1"
    source "$LIB_DIR/security/honeypot.sh" 2>/dev/null || return 0
    declare -f _hp_is_reserved_port &>/dev/null || return 0
    _hp_is_reserved_port "$port" || return 0
    log_warn "$(t mh.port_conflict "$port")"
    ask_yn "$(t mh.ask_use_port)" N
}

# ── Centralized node viewer ───────────────────────────────────────────────────
_mh_view_all_nodes() {
    source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/anytls.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/snell.sh"

    _mh_reality_sync_from_live || true
    _mh_ss_sync_from_live      || true

    local -a _protos _tags
    local i=0

    echo -e "\n${BOLD}${BLUE}══ $(t mh.nodes.title) ════════════════${NC}"

    while IFS=$'\t' read -r tag port listen sn; do
        i=$((i+1)); _protos+=("reality"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Reality]${NC}  %-18s  port=%-6s  listen=%-15s  sni=%s\n" \
               "$i" "$tag" "$port" "$listen" "$sn"
    done < <(_mh_reality_list 2>/dev/null)

    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); _protos+=("ss2022"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${CYAN}[SS2022]${NC}   %-18s  port=%-6s  %s\n" \
               "$i" "$tag" "$port" "$method"
    done < <(_mh_ss_list 2>/dev/null)

    while IFS=$'\t' read -r tag port sn _; do
        i=$((i+1)); _protos+=("hysteria2"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${YELLOW}[Hysteria2]${NC} %-16s  port=%-6s  sni=%s\n" \
               "$i" "$tag" "$port" "$sn"
    done < <(_mh_hy2_list 2>/dev/null)

    while IFS=$'\t' read -r tag port sn _; do
        i=$((i+1)); _protos+=("anytls"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${BLUE}[AnyTLS]${NC}   %-18s  port=%-6s  sni=%s\n" \
               "$i" "$tag" "$port" "$sn"
    done < <(_mh_anytls_list 2>/dev/null)

    while IFS=$'\t' read -r tag port ver _; do
        i=$((i+1)); _protos+=("snell"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Snell]${NC}    %-18s  port=%-6s  v%s\n" \
               "$i" "$tag" "$port" "$ver"
    done < <(_mh_snell_list 2>/dev/null)

    if (( i == 0 )); then
        log_warn "$(t mh.no_nodes)"
        return
    fi

    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t mh.ask_node_share): ${NC}")" sel

    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t mh.invalid_option)"; return
    fi

    local proto="${_protos[$((sel-1))]}"
    local tag="${_tags[$((sel-1))]}"
    echo ""
    case "$proto" in
        reality)   mh_reality_show_uri "$tag" ;;
        ss2022)    _mh_ss_uri          "$tag" ;;
        hysteria2) _mh_hy2_uri         "$tag" ;;
        anytls)    _mh_anytls_uri      "$tag" ;;
        snell)     _mh_snell_share     "$tag" ;;
    esac
}

# ── Protocol nodes sub-menu ───────────────────────────────────────────────────
_mh_protocol_menu() {
    while true; do
        show_menu "$(t mh.protocol_menu.title)" \
            "$(t mh.protocol_menu.reality)" \
            "$(t mh.protocol_menu.ss2022)" \
            "$(t mh.protocol_menu.hysteria2)" \
            "$(t mh.protocol_menu.anytls)" \
            "$(t mh.protocol_menu.snell)"

        case "$MENU_CHOICE" in
            1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh";   mh_reality_menu ;;
            2) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh";    mh_ss_menu ;;
            3) source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"; mh_hy2_menu ;;
            4) source "$(dirname "${BASH_SOURCE[0]}")/anytls.sh";    mh_anytls_menu ;;
            5) source "$(dirname "${BASH_SOURCE[0]}")/snell.sh";     mh_snell_menu ;;
            0) return ;;
        esac
    done
}

# ── Menu ──────────────────────────────────────────────────────────────────────
mh_menu() {
    _mh_check_deps
    while true; do
        show_menu "$(t mh.menu.title)" \
            "$(t mh.menu.install)" \
            "$(t mh.menu.upgrade)" \
            "$(t mh.menu.uninstall)" \
            "$(t mh.menu.nodes)" \
            "$(t mh.menu.routing)" \
            "$(t mh.menu.version)" \
            "$(t mh.menu.listeners)" \
            "$(t mh.menu.test)" \
            "$(t mh.menu.restart)" \
            "$(t mh.menu.status)" \
            "$(t mh.menu.logs)" \
            "$(t mh.menu.share)"

        case "$MENU_CHOICE" in
            1)  mh_install;    press_enter ;;
            2)  mh_upgrade;    press_enter ;;
            3)  mh_uninstall;  press_enter ;;
            4)  _mh_require_installed && _mh_protocol_menu ;;
            5)  _mh_require_installed && {
                    source "$(dirname "${BASH_SOURCE[0]}")/routing.sh"
                    mh_route_menu
                } ;;
            6)  mh_version;    press_enter ;;
            7)  echo -e "\n${BOLD}$(t mh.listeners_title)${NC}"; mh_get_listeners; press_enter ;;
            8)  "$MH_BIN" -t -d "$MH_CFG_DIR" -f "$MH_CFG" && log_ok "$(t mh.config_ok)" || log_error "$(t mh.config_bad)"; press_enter ;;
            9)  mh_test_restart; press_enter ;;
            10) svc_status mihomo;   press_enter ;;
            11) mh_logs ;;
            12) _mh_require_installed && { _mh_view_all_nodes; press_enter; } ;;
            0)  return ;;
        esac
    done
}
