#!/usr/bin/env bash
# hysteria2.sh — Hysteria2 install, config, management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HY2_BIN="/usr/local/bin/hysteria"
HY2_CFG="/etc/hysteria/config.yaml"
HY2_SERVICE="/etc/systemd/system/hysteria-server.service"
HY2_SELF_SIGNED_CERT="/etc/hysteria/self-signed.crt"
HY2_SELF_SIGNED_KEY="/etc/hysteria/self-signed.key"

HY2_RELEASES="https://github.com/apernet/hysteria/releases"

# ── Install binary ────────────────────────────────────────────────────────────
hy2_install() {
    ensure_pkg_deps curl jq
    require_cmd curl jq

    if [[ -f "$HY2_BIN" ]]; then
        log_info "$(t hysteria2.installed "$($HY2_BIN version 2>/dev/null | head -1)")"
        if [[ ! -f "$HY2_CFG" ]]; then
            log_warn "$(t hysteria2.config_missing_wizard)"
            _hy2_setup_wizard
            return $?
        fi
        ask_yn "$(t hysteria2.ask_reconfigure)" N && {
            _hy2_setup_wizard
            return $?
        }
        ask_yn "$(t hysteria2.ask_reinstall_bin)" N || return 0
    fi

    local arch; arch=$(get_arch)
    local tag

    log_step "$(t hysteria2.fetching_latest)"
    tag=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
          | jq -r '.tag_name // empty' || true)
    [[ "$tag" =~ ^app/v[0-9] ]] || { log_warn "$(t hysteria2.latest_fallback)"; tag="app/v2.6.0"; }

    local hy2_arch
    case "$arch" in
        amd64) hy2_arch="amd64" ;;
        arm64) hy2_arch="arm64" ;;
        arm32) hy2_arch="arm" ;;
        *)     die "$(t hysteria2.unsupported_arch "$arch")" ;;
    esac

    local filename="hysteria-linux-${hy2_arch}"
    local tag_url="${tag//\//%2F}"
    local url="${HY2_RELEASES}/download/${tag_url}/${filename}"
    local tmp; tmp=$(mktemp)

    log_step "$(t hysteria2.downloading "$tag" "$hy2_arch")"
    curl -fsSL -o "$tmp" "$url" || die "$(t hysteria2.download_fail "$url")"
    install -m 755 "$tmp" "$HY2_BIN"
    rm -f "$tmp"

    mkdir -p /etc/hysteria

    _hy2_write_service
    systemctl daemon-reload

    log_ok "$(t hysteria2.install_done "$tag")"

    # Configure immediately if no config exists
    if [[ ! -f "$HY2_CFG" ]]; then
        _hy2_setup_wizard
    fi
}

# ── Setup wizard (called after fresh install) ─────────────────────────────────
_hy2_setup_wizard() {
    log_step "$(t hysteria2.configuring)"
    mkdir -p /etc/hysteria

    local port; ask port "$(t hysteria2.ask_port)" "443"
    local password; password=$(rand_str 24)
    ask password "$(t hysteria2.ask_password)" "$password"

    local domain="" cert_block="" masquerade_block=""

    echo ""
    if ask_yn "$(t hysteria2.ask_has_domain)" Y; then
        ask domain "$(t hysteria2.ask_domain)"
        source "$LIB_DIR/cert.sh"
        if cert_ensure_domain "$domain"; then
            local cert_dir="$NGINX_SSL_DIR/$domain"
            cert_block="tls:
  cert: ${cert_dir}/fullchain.pem
  key:  ${cert_dir}/privkey.pem"
            masquerade_block="masquerade:
  type: proxy
  proxy:
    url: https://${domain}
    rewriteHost: true"
        else
            log_warn "$(t hysteria2.cert_unavailable_self)"
            domain=""
        fi
    fi

    if [[ -z "$domain" ]]; then
        log_step "$(t hysteria2.generating_self_cert)"
        openssl req -x509 -nodes -newkey ec \
            -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "$HY2_SELF_SIGNED_KEY" \
            -out    "$HY2_SELF_SIGNED_CERT" \
            -days 3650 -subj "/CN=Hysteria2" 2>/dev/null
        chmod 600 "$HY2_SELF_SIGNED_KEY"
        cert_block="tls:
  cert: ${HY2_SELF_SIGNED_CERT}
  key:  ${HY2_SELF_SIGNED_KEY}"
        log_warn "$(t hysteria2.self_cert_warn)"
    fi

    cat > "$HY2_CFG" <<EOF
listen: :${port}

${cert_block}

auth:
  type: password
  password: "${password}"

${masquerade_block}

bandwidth:
  up: 100 mbps
  down: 300 mbps

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: "80,443,8000-9000"
  udpPorts: "all"
EOF

    state_set "hy2_domain"   "$domain"
    state_set "hy2_password" "$password"
    state_set "hy2_port"     "$port"

    svc_enable hysteria-server
    svc_start  hysteria-server
    log_ok "$(t hysteria2.config_done)"
    log_info "$(t hysteria2.password_line "$password")"
    [[ -n "$domain" ]] && log_info "$(t hysteria2.domain_line "$domain")" || log_info "$(t hysteria2.mode_self_cert)"

    echo ""
    ask_yn "$(t hysteria2.ask_open_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "udp"
    }

    echo ""
    hy2_show_share
}

_hy2_write_service() {
    cat > "$HY2_SERVICE" <<'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ── Modify ────────────────────────────────────────────────────────────────────
hy2_modify_password() {
    [[ -f "$HY2_CFG" ]] || { log_error "$(t hysteria2.conf_missing)"; return 1; }
    local cur; cur=$(state_get "hy2_password")
    log_info "$(t hysteria2.current_password "$cur")"
    local new_pw; ask new_pw "$(t hysteria2.ask_new_password)" ""
    [[ -z "$new_pw" ]] && new_pw=$(rand_str 24)
    sed -i "s/  password:.*/  password: \"$new_pw\"/" "$HY2_CFG"
    state_set "hy2_password" "$new_pw"
    svc_restart hysteria-server
    log_ok "$(t hysteria2.password_updated "$new_pw")"
}

hy2_modify_bandwidth() {
    [[ -f "$HY2_CFG" ]] || { log_error "$(t hysteria2.conf_missing)"; return 1; }
    local up down
    ask up   "$(t hysteria2.ask_up)"  "100 mbps"
    ask down "$(t hysteria2.ask_down)"  "300 mbps"
    sed -i "s/  up:.*/  up: $up/"     "$HY2_CFG"
    sed -i "s/  down:.*/  down: $down/" "$HY2_CFG"
    svc_restart hysteria-server
    log_ok "$(t hysteria2.bandwidth_updated "$up" "$down")"
}

hy2_modify_cert() {
    [[ -f "$HY2_CFG" ]] || { log_error "$(t hysteria2.conf_missing)"; return 1; }
    local domain; ask domain "$(t hysteria2.ask_cert_domain "$NGINX_SSL_DIR")"
    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$domain" || { log_warn "$(t hysteria2.cert_unavailable)"; return 1; }
    local cert_dir="$NGINX_SSL_DIR/$domain"
    sed -i "s|  cert:.*|  cert: $cert_dir/fullchain.pem|" "$HY2_CFG"
    sed -i "s|  key:.*|  key:  $cert_dir/privkey.pem|"    "$HY2_CFG"
    state_set "hy2_domain" "$domain"
    svc_restart hysteria-server
    log_ok "$(t hysteria2.cert_updated "$domain")"
}

# ── Show share ────────────────────────────────────────────────────────────────
hy2_show_share() {
    [[ -f "$HY2_CFG" ]] || { log_error "$(t hysteria2.conf_missing)"; return 1; }

    local domain;   domain=$(state_get "hy2_domain")
    local password; password=$(state_get "hy2_password")
    local port;     port=$(state_get "hy2_port")
    [[ -z "$port" ]] && port=$(grep "^listen:" "$HY2_CFG" | sed 's/listen: *://;s/ .*//' || true)
    [[ -z "$port" ]] && port=443
    [[ -z "$password" ]] && password=$(grep "password:" "$HY2_CFG" | head -1 | sed 's/.*password: *"\?//;s/"\?.*//' || true)

    local ip; ip=$(get_ipv4)
    local insecure=0
    [[ -z "$domain" ]] && insecure=1

    local sni="${domain:-${ip}}"
    local uri="hysteria2://${password}@${ip}:${port}?insecure=${insecure}&sni=${sni}#PSM-Hysteria2"

    echo -e "\n${BOLD}${GREEN}── $(t hysteria2.share_title) ──${NC}"
    [[ $insecure -eq 1 ]] && echo -e "  ${YELLOW}$(t hysteria2.share_self_cert)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true

    echo -e "\n${BOLD}$(t hysteria2.clash_title)${NC}"
    cat <<EOF
proxies:
  - name: PSM-Hysteria2
    type: hysteria2
    server: ${ip}
    port: ${port}
    password: "${password}"
    sni: ${sni}
    skip-cert-verify: $([[ $insecure -eq 1 ]] && echo true || echo false)
EOF
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
hy2_uninstall() {
    ask_yn "$(t hysteria2.ask_uninstall)" N || return 0
    svc_stop hysteria-server
    systemctl disable hysteria-server --quiet 2>/dev/null
    rm -f "$HY2_BIN" "$HY2_SERVICE"
    systemctl daemon-reload
    log_ok "$(t hysteria2.uninstalled)"
}

hy2_logs() {
    journalctl -u hysteria-server -f --no-pager
}

# ── Dependency check ──────────────────────────────────────────────────────────
_hy2_check_deps() {
    ensure_pkg_deps curl qrencode openssl
    [[ -f "$HY2_BIN" ]] && return 0
    log_warn "$(t hysteria2.not_installed)"
    ask_yn "$(t hysteria2.ask_install)" Y \
        && hy2_install \
        || { log_error "$(t hysteria2.need)"; return 1; }
}

# ── Menu ──────────────────────────────────────────────────────────────────────
hysteria2_menu() {
    _hy2_check_deps || return
    while true; do
        show_menu "$(t hysteria2.menu.title)" \
            "$(t hysteria2.menu.install)" \
            "$(t hysteria2.menu.uninstall)" \
            "$(t hysteria2.menu.password)" \
            "$(t hysteria2.menu.bandwidth)" \
            "$(t hysteria2.menu.cert)" \
            "$(t hysteria2.menu.share)" \
            "$(t hysteria2.menu.status)" \
            "$(t hysteria2.menu.logs)" \
            "$(t hysteria2.menu.restart)"

        case "$MENU_CHOICE" in
            1) hy2_install ;;
            2) hy2_uninstall ;;
            3) hy2_modify_password ;;
            4) hy2_modify_bandwidth ;;
            5) hy2_modify_cert ;;
            6) hy2_show_share ;;
            7) svc_status hysteria-server ;;
            8) hy2_logs ;;
            9) svc_restart hysteria-server ;;
            0) return ;;
        esac
        press_enter
    done
}
