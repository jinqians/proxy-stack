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
    echo -e "\n${BOLD}$(t xray.tz.title)${NC}  $(t xray.tz.current "${CYAN}${cur}${NC}")"
    echo -e "  ${CYAN}1.${NC} $(t xray.tz.hk)"
    echo -e "  ${CYAN}2.${NC} $(t xray.tz.sg)"
    echo -e "  ${CYAN}3.${NC} $(t xray.tz.sh)"
    echo -e "  ${CYAN}4.${NC} $(t xray.tz.utc)"
    echo -e "  ${CYAN}0.${NC} $(t xray.tz.skip)"
    local choice
    read -rp "$(echo -e "${CYAN}$(t xray.tz.ask)${NC}")" choice
    choice="${choice:-1}"

    local tz=""
    case "$choice" in
        1) tz="Asia/Hong_Kong" ;;
        2) tz="Asia/Singapore" ;;
        3) tz="Asia/Shanghai"  ;;
        4) tz="UTC"            ;;
        0) log_info "$(t xray.tz.skipped)"; return ;;
        *) log_warn "$(t xray.tz.invalid)"; return ;;
    esac

    if timedatectl set-timezone "$tz" 2>/dev/null; then
        : # timedatectl handles /etc/localtime symlink automatically
    else
        # Fallback for containers / systems without timedatectl
        ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null || true
        echo "$tz" > /etc/timezone 2>/dev/null || true
    fi
    timedatectl set-ntp true 2>/dev/null || true
    log_ok "$(t xray.tz.done "$CYAN" "$tz" "$NC")"
}

# ── Install ───────────────────────────────────────────────────────────────────
xray_install() {
    ensure_pkg_deps curl unzip jq
    require_cmd curl unzip jq

    if is_installed xray || [[ -f "$XRAY_BIN" ]]; then
        log_info "$(t xray.installed "$($XRAY_BIN version 2>/dev/null | head -1)")"
        ask_yn "$(t xray.ask_reinstall)" N || return 0
    fi

    _tz_set_wizard

    local arch; arch=$(get_arch)
    local xray_arch
    case "$arch" in
        amd64) xray_arch="64" ;;
        arm64) xray_arch="arm64-v8a" ;;
        arm32) xray_arch="arm32-v7a" ;;
        *)     die "$(t xray.unsupported_arch "$arch")" ;;
    esac

    local tag

    log_step "$(t xray.fetching_latest)"
    tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
          | jq -r '.tag_name // empty' || true)
    [[ "$tag" =~ ^v[0-9] ]] || { log_warn "$(t xray.latest_fallback)"; tag="v24.9.30"; }

    local zip_name="Xray-linux-${xray_arch}.zip"
    local url="${XRAY_RELEASES}/download/${tag}/${zip_name}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    log_step "$(t xray.downloading "$tag" "$xray_arch")"
    curl -fsSL -o "$tmp_dir/$zip_name" "$url" \
        || die "$(t xray.download_fail "$url")"

    unzip -q "$tmp_dir/$zip_name" -d "$tmp_dir/xray"

    install -m 755 "$tmp_dir/xray/xray" /usr/local/bin/xray

    # Geo data (geoip.dat/geosite.dat) drives every geosite:/geoip: routing rule
    # — i.e. all WARP unlock + custom shunting. Xray searches /usr/local/share/xray
    # by default, so install them there. mkdir FIRST: `install`/`cp` into a
    # missing dir is a silent no-op (the previous order left geo data uninstalled
    # on a fresh box, so shunt rules never matched). The release zip bundles them;
    # warn if it somehow didn't, so a broken shunt is diagnosable.
    mkdir -p /usr/local/share/xray
    cp -f "$tmp_dir/xray"/geoip.dat   /usr/local/share/xray/ 2>/dev/null || true
    cp -f "$tmp_dir/xray"/geosite.dat /usr/local/share/xray/ 2>/dev/null || true
    if [[ ! -s /usr/local/share/xray/geoip.dat || ! -s /usr/local/share/xray/geosite.dat ]]; then
        log_warn "$(t xray.geo_warn)"
    fi

    rm -rf "$tmp_dir"
    mkdir -p "$XRAY_CFG_DIR"
    # config.json carries every node's secrets (UUIDs, passwords, private/WARP
    # keys). Keep the dir root-only so the config isn't world-readable; xray.service
    # runs as root, so this doesn't affect it.
    chmod 700 "$XRAY_CFG_DIR" 2>/dev/null || true

    if [[ -f "$XRAY_CFG" ]]; then
        if ! "$XRAY_BIN" run -test -config "$XRAY_CFG" &>/dev/null \
            && ! "$XRAY_BIN" -test -config "$XRAY_CFG" &>/dev/null; then
            local backup_cfg
            backup_cfg="${XRAY_CFG}.bad.$(date +%Y%m%d%H%M%S)"
            cp -a "$XRAY_CFG" "$backup_cfg"
            log_warn "$(t xray.bad_config_backup "$backup_cfg")"
            _write_skeleton_config
        fi
    else
        _write_skeleton_config
    fi

    _write_xray_service
    systemctl daemon-reload
    svc_enable xray
    svc_restart xray || svc_start xray
    log_ok "$(t xray.install_done "$tag")"
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
        log_error "$(t xray.x25519_gen_fail)"
        echo "$output" >&2
        return 1
    }

    private_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
    public_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "$(t xray.x25519_parse_fail)"
        echo "$output" >&2
        return 1
    fi

    printf '%s\t%s\n' "$private_key" "$public_key"
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
xray_upgrade() {
    log_step "$(t xray.upgrading)"
    xray_install
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
xray_uninstall() {
    echo -e "\n${YELLOW}$(t xray.uninstall_warn)${NC}"
    ask_yn "$(t xray.ask_uninstall)" N || return 0

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

    log_ok "$(t xray.uninstalled)"
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

# ── Safe config replacement ───────────────────────────────────────────────────
# Atomically replace XRAY_CFG with a candidate file ONLY if it's non-empty valid
# JSON. Guards against jq pipelines that failed halfway and produced empty or
# partial output — writing that would wipe the running config. On failure the
# existing config is left untouched and we return non-zero. (Full Xray semantic
# validation is done by the caller's xray_test_restart, which then also reports.)
_xray_write_cfg_checked() {
    local candidate="$1"
    if [[ ! -s "$candidate" ]] || ! jq -e . "$candidate" >/dev/null 2>&1; then
        log_error "$(t xray.write_invalid)"
        rm -f "$candidate"
        return 1
    fi
    mv -f "$candidate" "$XRAY_CFG"
}

# ── Status & logs ─────────────────────────────────────────────────────────────
xray_version() {
    "$XRAY_BIN" version 2>/dev/null | head -3
}

xray_logs() {
    echo -e "$(t xray.logs.menu)"
    read -rp "$(echo -e "${CYAN}$(t xray.ask_select)${NC}")" lc
    case "$lc" in
        1) tail -f /var/log/xray/access.log ;;
        2) tail -f /var/log/xray/error.log ;;
        3) journalctl -u xray -f --no-pager ;;
    esac
}

# ── Post-install protocol wizard ─────────────────────────────────────────────
_xray_post_install_wizard() {
    echo ""
    ask_yn "$(t xray.ask_protocol_now)" Y || return 0
    echo -e "\n  $(t xray.protocol_choose)"
    echo -e "  1. $(t xray.protocol.reality)"
    echo -e "  2. $(t xray.protocol.vision)"
    echo -e "  3. $(t xray.protocol.xhttp)"
    echo -e "  4. $(t xray.protocol.ss2022)"
    read -rp "$(echo -e "${CYAN}$(t xray.ask_select_default)${NC}")" pc
    echo ""
    case "${pc:-1}" in
        1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"; reality_add_node ;;
        2) source "$(dirname "${BASH_SOURCE[0]}")/vision.sh";  vision_add_node ;;
        3) source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh";   xhttp_add_node ;;
        4) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh";  xss_add_node ;;
        *) log_info "$(t xray.protocol_skipped)" ;;
    esac
}

# ── Dependency & install check ────────────────────────────────────────────────
_xray_check_deps() {
    ensure_pkg_deps curl unzip jq
}

_xray_require_installed() {
    if [[ ! -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
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
    log_warn "$(t xray.port_conflict "$port")"
    ask_yn "$(t xray.ask_use_port)" N
}

# ── Centralized node viewer ───────────────────────────────────────────────────
_xray_view_all_nodes() {
    source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/vision.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh"

    # 展示前把 config.json 中的手动修改（端口/UUID/密码）同步回各协议的
    # 节点存储，否则这里和后续 show 函数显示的都是旧值。
    _reality_sync_from_live || true
    _vision_sync_from_live  || true
    _xhttp_sync_from_live   || true
    _xss_sync_from_live     || true

    local -a _protos _tags
    local i=0

    echo -e "\n${BOLD}${BLUE}══ $(t xray.nodes.title) ════════════════${NC}"

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
        log_warn "$(t xray.no_nodes)"
        return
    fi

    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t xray.ask_node_share): ${NC}")" sel

    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t xray.invalid_option)"; return
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
        show_menu "$(t xray.protocol_menu.title)" \
            "$(t xray.protocol_menu.reality)" \
            "$(t xray.protocol_menu.vision)" \
            "$(t xray.protocol_menu.xhttp)" \
            "$(t xray.protocol_menu.ss2022)"

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
        show_menu "$(t xray.menu.title)" \
            "$(t xray.menu.install)" \
            "$(t xray.menu.upgrade)" \
            "$(t xray.menu.uninstall)" \
            "$(t xray.menu.nodes)" \
            "$(t xray.menu.routing)" \
            "$(t xray.menu.version)" \
            "$(t xray.menu.inbounds)" \
            "$(t xray.menu.test)" \
            "$(t xray.menu.restart)" \
            "$(t xray.menu.status)" \
            "$(t xray.menu.logs)" \
            "$(t xray.menu.share)"

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
            7)  echo -e "\n${BOLD}$(t xray.inbounds_title)${NC}"; xray_get_inbounds; press_enter ;;
            8)  "$XRAY_BIN" -test -config "$XRAY_CFG" && log_ok "$(t xray.config_ok)" || log_error "$(t xray.config_bad)"; press_enter ;;
            9)  xray_test_restart; press_enter ;;
            10) svc_status xray;   press_enter ;;
            11) xray_logs ;;
            12) _xray_require_installed && { _xray_view_all_nodes; press_enter; } ;;
            0)  return ;;
        esac
    done
}
