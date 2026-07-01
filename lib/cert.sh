#!/usr/bin/env bash
# cert.sh — SSL certificate management via acme.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ACME_INSTALL_URL="https://get.acme.sh"
SSL_DIR="$NGINX_SSL_DIR"    # /etc/nginx/ssl

# ── Install acme.sh ───────────────────────────────────────────────────────────
acme_install() {
    if [[ -f "$ACME_HOME/acme.sh" ]]; then
        log_info "acme.sh 已安装。"
        return 0
    fi
    local email; ask email "证书注册邮箱" ""
    [[ -z "$email" ]] && email="admin@$(hostname -f 2>/dev/null || echo 'example.com')"

    # acme.sh installer expects  email=xxx  (no dashes), not --email xxx
    curl -fsSL "$ACME_INSTALL_URL" | sh -s "email=$email"

    export PATH="$ACME_HOME:$PATH"
    if [[ ! -f "$ACME_HOME/acme.sh" ]]; then
        log_error "acme.sh 安装失败——未找到可执行文件：$ACME_HOME/acme.sh"
        return 1
    fi
    log_ok "acme.sh 已安装，自动续期定时任务已设置。"
}

_acme() {
    export PATH="$ACME_HOME:$PATH"
    "$ACME_HOME/acme.sh" "$@"
}

# acme.sh returns non-zero when it skips renewal ("Domains not changed"),
# even though the cert already exists in its cache.  Check for that case.
_acme_cert_cached() {
    local domain="$1"
    [[ -f "$ACME_HOME/${domain}_ecc/fullchain.cer" ]] || \
    [[ -f "$ACME_HOME/${domain}/fullchain.cer" ]]
}

# ── CA selection ──────────────────────────────────────────────────────────────
_select_ca() {
    echo -e "  CA:\n  1. Let's Encrypt（默认）\n  2. ZeroSSL\n  3. Google Trust Services"
    read -rp "$(echo -e "${CYAN}请选择 [1]: ${NC}")" ca_choice
    case "${ca_choice:-1}" in
        1) _acme --set-default-ca --server letsencrypt ;;
        2) _acme --set-default-ca --server zerossl ;;
        3) _acme --set-default-ca --server google ;;
    esac
}

# ── Firewall helpers for standalone ACME challenge ────────────────────────────
# Opens port 80 in the local firewall and prints the method used ("iptables"
# or "ufw") so the caller can pass it to _fw_close80 afterwards.
_fw_open80() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null 2>&1 && echo "ufw" || true
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null && echo "iptables" || true
    fi
}

_fw_close80() {
    case "${1:-}" in
        iptables) iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true ;;
        ufw)      ufw delete allow 80/tcp >/dev/null 2>&1 || true ;;
    esac
}

# ── Shared HTTP-01 issue logic ────────────────────────────────────────────────
# Issues a cert for $1, choosing webroot (Nginx running) or standalone.
# Returns 0 and installs to SSL_DIR on success.
_cert_http01_issue() {
    local domain="$1"
    local webroot="/var/www/${domain}"
    mkdir -p "$webroot"
    local issued=0

    if is_installed nginx && svc_is_active nginx; then
        # Nginx is running → use webroot (no need to touch port 80)
        mkdir -p "$NGINX_HTTP_DIR"
        local http_conf="$NGINX_HTTP_DIR/_acme_${domain}.conf"
        cat > "$http_conf" <<NGINXEOF
server {
    listen 80;
    server_name ${domain};
    location /.well-known/acme-challenge/ { root ${webroot}; }
}
NGINXEOF
        nginx -s reload 2>/dev/null || true
        _acme --issue -d "$domain" --webroot "$webroot" && issued=1
        rm -f "$http_conf"
        nginx -s reload 2>/dev/null || true
    else
        # Nginx not running → standalone (acme.sh binds port 80 directly)
        log_info "Nginx 未运行，使用独立模式..."
        log_warn "请确认以下两点，否则签发会失败："
        echo -e "    1. 云服务商安全组 / 控制台防火墙 已放行 TCP 80"
        echo -e "    2. 本机没有其他程序占用端口 80\n"

        local fw_tag; fw_tag=$(_fw_open80)
        [[ -n "$fw_tag" ]] && log_info "已临时开放本机防火墙端口 80（$fw_tag）"

        _acme --issue -d "$domain" --standalone && issued=1

        if [[ -n "$fw_tag" ]]; then
            _fw_close80 "$fw_tag"
            log_info "已还原防火墙规则（$fw_tag）"
        fi
    fi

    if (( !issued )) && _acme_cert_cached "$domain"; then
        log_info "证书已在 acme.sh 缓存中——正在安装到 $SSL_DIR。"
        issued=1
    fi

    if (( issued )); then
        cert_install_domain "$domain"
        return 0
    fi

    log_error "$domain 的证书签发失败。"
    log_warn "如果错误是 'Connection refused'，说明云安全组在网络层封锁了端口 80，"
    log_warn "本机 iptables 无法解决此问题。解决方法："
    echo -e "    A. 登录云控制台将 TCP 80 入方向放行，申请完再关闭"
    echo -e "    B. 改用 DNS-01 方式（无需开放任何端口）\n"

    # Auto-fallback: if Cloudflare token already configured, offer DNS-01 immediately
    local cf_token; cf_token=$(state_get "cf_api_token" 2>/dev/null || true)
    if [[ -n "$cf_token" ]]; then
        log_info "检测到已配置 Cloudflare API Token，可直接用 DNS-01 方式重试。"
        if ask_yn "是否立即切换 DNS-01（Cloudflare）重新签发？" Y; then
            _ensure_cf_env
            if _acme --issue --dns dns_cf -d "$domain"; then
                cert_install_domain "$domain"
                return 0
            else
                log_error "DNS-01 签发同样失败，请检查 Cloudflare Token 权限（需 Zone:DNS:Edit）。"
            fi
        fi
    fi

    return 1
}

# ── Issue via HTTP-01 (standalone / webroot) ──────────────────────────────────
cert_issue_http() {
    [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
    _select_ca
    local domain; ask domain "域名"
    is_domain "$domain" || { log_error "无效的域名"; return 1; }
    _cert_http01_issue "$domain"
}

# ── Issue via DNS-01 ──────────────────────────────────────────────────────────
cert_issue_dns() {
    [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
    _select_ca

    local domain; ask domain "域名（支持通配符 *.example.com）"
    is_domain "${domain#\*.}" || { log_error "无效的域名"; return 1; }

    echo -e "\n  DNS API:\n  1. Cloudflare\n  2. DNSPod\n  3. 阿里云\n  4. CloudXNS\n  5. 手动"
    read -rp "$(echo -e "${CYAN}DNS 提供商 [1]: ${NC}")" dns_choice

    local dns_plugin extra_args=""
    case "${dns_choice:-1}" in
        1)
            dns_plugin="dns_cf"
            _ensure_cf_env
            ;;
        2)
            dns_plugin="dns_dp"
            local dp_id dp_key
            ask dp_id  "DNSPod App ID"
            ask dp_key "DNSPod App Key"
            export DP_Id="$dp_id" DP_Key="$dp_key"
            ;;
        3)
            dns_plugin="dns_ali"
            local ali_key ali_secret
            ask ali_key    "阿里云 Access Key ID"
            ask ali_secret "阿里云 Access Key Secret"
            export Ali_Key="$ali_key" Ali_Secret="$ali_secret"
            ;;
        4)
            dns_plugin="dns_cx"
            local cx_key cx_secret
            ask cx_key    "CloudXNS API Key"
            ask cx_secret "CloudXNS Secret Key"
            export CX_Key="$cx_key" CX_Secret="$cx_secret"
            ;;
        5)
            dns_plugin="dns_manual"
            ;;
        *) log_error "无效选项"; return 1 ;;
    esac

    _acme --issue --dns "$dns_plugin" -d "$domain" $extra_args \
        || { log_error "签发失败"; return 1; }

    cert_install_domain "${domain#\*.}"
}

# ── Manual import ─────────────────────────────────────────────────────────────
cert_import_manual() {
    local domain; ask domain "域名"
    local cert_file key_file ca_file

    ask cert_file "证书文件完整路径（fullchain.pem）"
    ask key_file  "私钥文件完整路径（privkey.pem）"
    ask ca_file   "CA 链文件完整路径（可选，直接回车跳过）" ""

    [[ -f "$cert_file" ]] || { log_error "证书文件未找到"; return 1; }
    [[ -f "$key_file"  ]] || { log_error "私钥文件未找到";  return 1; }

    local dest="$SSL_DIR/$domain"
    mkdir -p "$dest"
    cp "$cert_file" "$dest/fullchain.pem"
    cp "$key_file"  "$dest/privkey.pem"
    [[ -n "$ca_file" && -f "$ca_file" ]] && cp "$ca_file" "$dest/chain.pem"
    chmod 600 "$dest/privkey.pem"
    log_ok "证书已导入到 $dest"
}

# ── Install cert to nginx ssl dir ─────────────────────────────────────────────
cert_install_domain() {
    local domain="$1"
    local dest="$SSL_DIR/$domain"
    mkdir -p "$dest"

    _acme --install-cert -d "$domain" \
        --cert-file      "$dest/cert.pem" \
        --key-file       "$dest/privkey.pem" \
        --fullchain-file "$dest/fullchain.pem" \
        --reloadcmd      "systemctl reload nginx 2>/dev/null; systemctl reload hysteria-server 2>/dev/null || true"

    chmod 600 "$dest/privkey.pem"
    log_ok "证书已安装：$dest"
}

# ── Renew ─────────────────────────────────────────────────────────────────────
cert_renew() {
    local domain; ask domain "域名（留空则续期全部）" ""
    if [[ -z "$domain" ]]; then
        _acme --renew-all --force
    else
        _acme --renew -d "$domain" --force
    fi
}

cert_auto_renew() {
    # acme.sh sets up a cron job on install; this makes it explicit
    _acme --install-cronjob
    log_ok "自动续期定时任务已安装。"
}

# ── List / delete ─────────────────────────────────────────────────────────────
cert_list() {
    _acme --list 2>/dev/null \
        || ls -1 "$SSL_DIR" 2>/dev/null | while read -r d; do
            echo "$d  →  $SSL_DIR/$d/fullchain.pem"
           done
}

cert_delete() {
    cert_list
    local domain; ask domain "要删除的域名"
    _acme --remove -d "$domain" 2>/dev/null
    ask_yn "同时删除本地文件 $SSL_DIR/$domain？" N \
        && rm -rf "$SSL_DIR/$domain"
    log_ok "证书已删除。"
}

# ── Cloudflare env helper ─────────────────────────────────────────────────────
_ensure_cf_env() {
    local cf_token; cf_token=$(state_get "cf_api_token")
    if [[ -z "$cf_token" ]]; then
        ask cf_token "Cloudflare API Token（含 Zone DNS 编辑权限）"
        state_set "cf_api_token" "$cf_token"
    fi
    export CF_Token="$cf_token"
}

# ── Ensure cert exists for a domain ──────────────────────────────────────────
# Usage: cert_ensure_domain <domain> [reason_text]
# Returns 0 if cert is ready, 1 if not/skipped.
cert_ensure_domain() {
    local domain="$1"
    local reason="${2:-此域名需要 TLS 证书。}"
    local cert_dir="$SSL_DIR/$domain"

    if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
        log_ok "已找到 $domain 的证书。"
        return 0
    fi

    # acme.sh cache exists but nginx ssl dir was deleted (e.g. after uninstall) → reinstall
    if _acme_cert_cached "$domain"; then
        log_info "证书已在 acme.sh 缓存中——正在安装到 $cert_dir"
        cert_install_domain "$domain"
        return 0
    fi

    log_warn "未找到域名 $domain 的证书"
    echo -e "\n  ${reason}"
    echo -e "  1. HTTP-01 签发  （域名 DNS 需指向本机，端口 80 必须开放）"
    echo -e "  2. DNS-01 签发   （支持通配符，无需开放端口 80）"
    echo -e "  3. 导入已有证书"
    echo -e "  0. 跳过"
    read -rp "$(echo -e "${CYAN}请选择: ${NC}")" cc

    case "${cc:-0}" in
        1)
            [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
            [[ -f "$ACME_HOME/acme.sh" ]] || { log_error "acme.sh 不可用，无法签发证书。"; return 1; }
            _select_ca
            _cert_http01_issue "$domain" || return 1
            ;;
        2)
            [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
            _select_ca
            echo -e "\n  DNS API:\n  1. Cloudflare\n  2. DNSPod\n  3. 阿里云\n  4. 手动"
            read -rp "$(echo -e "${CYAN}DNS 提供商 [1]: ${NC}")" dns_choice
            local dns_plugin
            case "${dns_choice:-1}" in
                1) dns_plugin="dns_cf"; _ensure_cf_env ;;
                2) dns_plugin="dns_dp"
                   local dp_id dp_key
                   ask dp_id  "DNSPod App ID"; ask dp_key "DNSPod App Key"
                   export DP_Id="$dp_id" DP_Key="$dp_key" ;;
                3) dns_plugin="dns_ali"
                   local ali_key ali_secret
                   ask ali_key "阿里云 Key ID"; ask ali_secret "阿里云 Secret"
                   export Ali_Key="$ali_key" Ali_Secret="$ali_secret" ;;
                4) dns_plugin="dns_manual" ;;
                *) log_error "无效选项"; return 1 ;;
            esac
            if _acme --issue --dns "$dns_plugin" -d "$domain"; then
                cert_install_domain "$domain"
            else
                log_error "$domain 的证书签发失败。"
                return 1
            fi
            ;;
        3)
            local cert_file key_file
            ask cert_file "证书文件完整路径（fullchain.pem）"
            ask key_file  "私钥文件完整路径（privkey.pem）"
            [[ -f "$cert_file" ]] || { log_error "证书文件未找到：$cert_file"; return 1; }
            [[ -f "$key_file"  ]] || { log_error "私钥文件未找到：$key_file";   return 1; }
            mkdir -p "$cert_dir"
            cp "$cert_file" "$cert_dir/fullchain.pem"
            cp "$key_file"  "$cert_dir/privkey.pem"
            chmod 600 "$cert_dir/privkey.pem"
            log_ok "证书已安装到 $cert_dir"
            ;;
        0)
            log_warn "已跳过证书。"
            return 1
            ;;
        *)
            log_error "无效选项。"
            return 1
            ;;
    esac
}

# ── Dependency check ─────────────────────────────────────────────────────────
_cert_check_deps() {
    ensure_pkg_deps curl openssl socat
    if ! [[ -f "$ACME_HOME/acme.sh" ]]; then
        log_warn "acme.sh 未安装。"
        ask_yn "是否现在安装 acme.sh？" Y && acme_install || log_warn "acme.sh 是自动签发证书的必要工具。"
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
cert_menu() {
    _cert_check_deps
    while true; do
        show_menu "SSL 证书管理" \
            "安装 acme.sh" \
            "签发证书（HTTP-01）" \
            "签发证书（DNS-01 / 通配符）" \
            "手动导入证书" \
            "续期证书" \
            "启用自动续期" \
            "列出证书" \
            "删除证书"

        case "$MENU_CHOICE" in
            1) acme_install ;;
            2) cert_issue_http ;;
            3) cert_issue_dns ;;
            4) cert_import_manual ;;
            5) cert_renew ;;
            6) cert_auto_renew ;;
            7) cert_list ;;
            8) cert_delete ;;
            0) return ;;
        esac
        press_enter
    done
}
