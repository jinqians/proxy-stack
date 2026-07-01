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
    if [[ -f "$HY2_BIN" ]]; then
        log_info "Hysteria2 已安装：$($HY2_BIN version 2>/dev/null | head -1)"
        if [[ ! -f "$HY2_CFG" ]]; then
            log_warn "未找到 Hysteria2 配置文件，启动配置向导。"
            _hy2_setup_wizard
            return $?
        fi
        ask_yn "是否重新配置 Hysteria2？" N && {
            _hy2_setup_wizard
            return $?
        }
        ask_yn "是否重新安装二进制文件？" N || return 0
    fi

    local arch; arch=$(get_arch)
    local tag

    log_step "正在获取 Hysteria2 最新版本..."
    tag=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
          | grep '"tag_name"' | cut -d'"' -f4 || true)
    [[ -z "$tag" ]] && { log_warn "无法获取最新版本，使用备用版本 app/v2.6.0"; tag="app/v2.6.0"; }

    local hy2_arch
    case "$arch" in
        amd64) hy2_arch="amd64" ;;
        arm64) hy2_arch="arm64" ;;
        arm32) hy2_arch="arm" ;;
        *)     die "Hysteria2 不支持此架构：$arch" ;;
    esac

    local filename="hysteria-linux-${hy2_arch}"
    local tag_url="${tag//\//%2F}"
    local url="${HY2_RELEASES}/download/${tag_url}/${filename}"
    local tmp; tmp=$(mktemp)

    log_step "正在下载 Hysteria2 ${tag}（${hy2_arch}）..."
    curl -fsSL -o "$tmp" "$url" || die "下载失败：$url"
    install -m 755 "$tmp" "$HY2_BIN"
    rm -f "$tmp"

    mkdir -p /etc/hysteria

    _hy2_write_service
    systemctl daemon-reload

    log_ok "Hysteria2 ${tag} 已安装。"

    # Configure immediately if no config exists
    if [[ ! -f "$HY2_CFG" ]]; then
        _hy2_setup_wizard
    fi
}

# ── Setup wizard (called after fresh install) ─────────────────────────────────
_hy2_setup_wizard() {
    log_step "正在配置 Hysteria2..."
    mkdir -p /etc/hysteria

    local port; ask port "监听端口（UDP）" "443"
    local password; password=$(rand_str 24)
    ask password "密码（留空自动生成）" "$password"

    local domain="" cert_block="" masquerade_block=""

    echo ""
    if ask_yn "你是否有解析到本机的域名？" Y; then
        ask domain "你的域名"
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
            log_warn "证书不可用，将使用自签名证书。"
            domain=""
        fi
    fi

    if [[ -z "$domain" ]]; then
        log_step "正在生成自签名证书..."
        openssl req -x509 -nodes -newkey ec \
            -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "$HY2_SELF_SIGNED_KEY" \
            -out    "$HY2_SELF_SIGNED_CERT" \
            -days 3650 -subj "/CN=Hysteria2" 2>/dev/null
        chmod 600 "$HY2_SELF_SIGNED_KEY"
        cert_block="tls:
  cert: ${HY2_SELF_SIGNED_CERT}
  key:  ${HY2_SELF_SIGNED_KEY}"
        log_warn "自签名证书——客户端需设置 insecure=true（或 skip-cert-verify: true）。"
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
    log_ok "Hysteria2 配置完成。"
    log_info "密码：$password"
    [[ -n "$domain" ]] && log_info "域名：$domain" || log_info "模式：自签名证书（无域名）"

    echo ""
    ask_yn "是否现在放行防火墙端口 ${port}/udp？" Y && {
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
    [[ -f "$HY2_CFG" ]] || { log_error "未找到配置文件"; return 1; }
    local cur; cur=$(state_get "hy2_password")
    log_info "当前密码：$cur"
    local new_pw; ask new_pw "新密码（留空自动生成）" ""
    [[ -z "$new_pw" ]] && new_pw=$(rand_str 24)
    sed -i "s/  password:.*/  password: \"$new_pw\"/" "$HY2_CFG"
    state_set "hy2_password" "$new_pw"
    svc_restart hysteria-server
    log_ok "密码已更新：$new_pw"
}

hy2_modify_bandwidth() {
    [[ -f "$HY2_CFG" ]] || { log_error "未找到配置文件"; return 1; }
    local up down
    ask up   "上行限速（例如 100 mbps）"  "100 mbps"
    ask down "下行限速（例如 300 mbps）"  "300 mbps"
    sed -i "s/  up:.*/  up: $up/"     "$HY2_CFG"
    sed -i "s/  down:.*/  down: $down/" "$HY2_CFG"
    svc_restart hysteria-server
    log_ok "带宽限速——上行：$up，下行：$down"
}

hy2_modify_cert() {
    [[ -f "$HY2_CFG" ]] || { log_error "未找到配置文件"; return 1; }
    local domain; ask domain "域名（证书须在 $NGINX_SSL_DIR/域名/ 目录下）"
    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$domain" || { log_warn "证书不可用。"; return 1; }
    local cert_dir="$NGINX_SSL_DIR/$domain"
    sed -i "s|  cert:.*|  cert: $cert_dir/fullchain.pem|" "$HY2_CFG"
    sed -i "s|  key:.*|  key:  $cert_dir/privkey.pem|"    "$HY2_CFG"
    state_set "hy2_domain" "$domain"
    svc_restart hysteria-server
    log_ok "已更新 $domain 的证书"
}

# ── Show share ────────────────────────────────────────────────────────────────
hy2_show_share() {
    [[ -f "$HY2_CFG" ]] || { log_error "未找到配置文件"; return 1; }

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

    echo -e "\n${BOLD}${GREEN}── Hysteria2 分享链接 ──${NC}"
    [[ $insecure -eq 1 ]] && echo -e "  ${YELLOW}（自签名证书——客户端需设置 insecure=1）${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true

    echo -e "\n${BOLD}Clash Meta：${NC}"
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
    ask_yn "是否删除 Hysteria2 程序和服务？（保留配置）" N || return 0
    svc_stop hysteria-server
    systemctl disable hysteria-server --quiet 2>/dev/null
    rm -f "$HY2_BIN" "$HY2_SERVICE"
    systemctl daemon-reload
    log_ok "Hysteria2 已删除。"
}

hy2_logs() {
    journalctl -u hysteria-server -f --no-pager
}

# ── Dependency check ──────────────────────────────────────────────────────────
_hy2_check_deps() {
    ensure_pkg_deps curl qrencode openssl
    [[ -f "$HY2_BIN" ]] && return 0
    log_warn "Hysteria2 未安装。"
    ask_yn "是否现在安装 Hysteria2？" Y \
        && hy2_install \
        || { log_error "此菜单需要 Hysteria2。"; return 1; }
}

# ── Menu ──────────────────────────────────────────────────────────────────────
hysteria2_menu() {
    _hy2_check_deps || return
    while true; do
        show_menu "Hysteria2 管理" \
            "安装 / 重新配置" \
            "卸载" \
            "修改密码" \
            "修改带宽限速" \
            "修改证书" \
            "显示分享链接 / URI" \
            "服务状态" \
            "查看日志" \
            "重启服务"

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
