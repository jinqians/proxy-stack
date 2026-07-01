#!/usr/bin/env bash
# nginx.sh — Nginx install, stream/http site management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NGINX_STREAM_D="$NGINX_STREAM_DIR"    # /etc/nginx/stream.d
NGINX_HTTP_D="$NGINX_HTTP_DIR"         # /etc/nginx/conf.d
NGINX_MAIN="/etc/nginx/nginx.conf"

# ── Install ───────────────────────────────────────────────────────────────────
nginx_install() {
    if is_installed nginx; then
        log_info "Nginx 已安装：$(nginx -v 2>&1)"
        nginx_ensure_stream_sni
        return 0
    fi

    detect_os
    log_step "正在安装 Nginx..."
    case "$OS_ID" in
        ubuntu|debian|raspbian)
            pkg_update
            # libnginx-mod-stream provides the stream {} / ssl_preread support
            pkg_install nginx libnginx-mod-stream
            ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora)
            yum install -y epel-release 2>/dev/null || true
            pkg_install nginx
            # On RHEL-family, stream is a dynamic module; install the package
            yum install -y nginx-mod-stream 2>/dev/null || true
            ;;
    esac

    mkdir -p "$NGINX_STREAM_D" "$NGINX_HTTP_D" "$NGINX_SSL_DIR"

    _write_nginx_main
    init_stream_sni
    svc_enable nginx
    # restart (not start) so nginx loads our custom config, not the distro default
    svc_restart nginx
    log_ok "Nginx 已安装。"
}

_nginx_runtime_user() {
    if id -u www-data &>/dev/null; then
        echo "www-data"
    elif id -u nginx &>/dev/null; then
        echo "nginx"
    elif id -u nobody &>/dev/null; then
        echo "nobody"
    else
        echo "root"
    fi
}

# Emit the `load_module ...;` line needed to make the `stream {}` block work.
# Relying on `include /etc/nginx/modules-enabled/*.conf` proved unreliable
# (the include didn't pull in ngx_stream_module.so → "unknown directive stream"),
# so we load the module explicitly instead:
#   - static build   (--with-stream, no =dynamic): built-in, load nothing
#   - dynamic build  (--with-stream=dynamic):       must load the .so ourselves
#   - not compiled at all:                          emit nothing; nginx -t will fail
# We deliberately do NOT `include modules-enabled/*.conf` alongside this — doing
# both would load the stream module twice and nginx would refuse to start.
_nginx_stream_load_directive() {
    local nginx_v; nginx_v=$(nginx -V 2>&1)
    grep -q 'with-stream=dynamic' <<<"$nginx_v" || return 0   # static or absent → nothing to load
    local so
    so=$(find /usr/lib/nginx/modules /usr/lib64/nginx/modules \
              /usr/share/nginx/modules /etc/nginx/modules \
              -name 'ngx_stream_module.so' 2>/dev/null | head -1)
    [[ -n "$so" ]] && printf 'load_module %s;' "$so"
}

_write_nginx_main() {
    local nginx_user stream_load
    nginx_user="$(_nginx_runtime_user)"
    stream_load="$(_nginx_stream_load_directive)"

    if [[ -f "$NGINX_MAIN" ]] && ! grep -q "PSM-managed nginx.conf" "$NGINX_MAIN"; then
        cp -a "$NGINX_MAIN" "${NGINX_MAIN}.psm.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "$NGINX_MAIN" <<MAINCFG
# PSM-managed nginx.conf
user ${nginx_user};
worker_processes auto;
pid /run/nginx.pid;
${stream_load}

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    include /etc/nginx/conf.d/*.conf;
}

stream {
    log_format stream '\$remote_addr [\$time_local] '
                      '\$protocol \$status \$bytes_sent \$bytes_received '
                      '\$session_time "\$upstream_addr"';
    access_log /var/log/nginx/stream.log stream;
    error_log  /var/log/nginx/stream-error.log;

    include /etc/nginx/stream.d/*.conf;
}
MAINCFG
}

nginx_upgrade() {
    detect_os
    log_step "正在升级 Nginx..."
    case "$OS_ID" in
        ubuntu|debian|raspbian) apt-get install --only-upgrade -y nginx ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora) yum update -y nginx ;;
    esac
    nginx_test_reload
    log_ok "Nginx 已升级。"
}

nginx_uninstall() {
    ask_yn "是否删除 Nginx 及其所有配置？" N || return 0
    svc_stop nginx
    detect_os
    case "$OS_ID" in
        ubuntu|debian|raspbian) apt-get purge -y nginx nginx-common ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora) yum remove -y nginx ;;
    esac
    log_ok "Nginx 已删除。"
}

# ── Stream SNI routing ────────────────────────────────────────────────────────
# Each SNI block lives in /etc/nginx/stream.d/00-sni-map.conf
# Additional stream entries are separate files.

_sni_map_file() { echo "$NGINX_STREAM_D/00-sni-map.conf"; }

_nginx_ensure_stream_module() {
    detect_os
    case "$OS_ID" in
        ubuntu|debian|raspbian)
            if ! dpkg -l libnginx-mod-stream &>/dev/null; then
                log_step "正在安装 Nginx stream 模块..."
                pkg_install libnginx-mod-stream
                svc_restart nginx 2>/dev/null || true
            fi
            ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora)
            # Stream is a dynamic module on distro nginx; install if missing
            if ! rpm -q nginx-mod-stream &>/dev/null 2>&1; then
                log_step "正在安装 Nginx stream 模块..."
                yum install -y nginx-mod-stream 2>/dev/null || true
                svc_restart nginx 2>/dev/null || true
            fi
            ;;
    esac
}

init_stream_sni() {
    # Called once during install to set up the SNI map + listener
    mkdir -p "$NGINX_STREAM_D" "$NGINX_HTTP_D" "$NGINX_SSL_DIR"
    _nginx_ensure_stream_module

    local reality_port; reality_port=$(state_get "reality_local_port")
    reality_port="${reality_port:-1443}"
    local web_port; web_port=$(state_get "web_local_port")
    web_port="${web_port:-8443}"

    cat > "$(_sni_map_file)" <<EOF
# PSM-managed SNI map — edit via PSM, not directly
map \$ssl_preread_server_name \$psm_backend {
    # domain → upstream entries are injected below
    # PSM:ENTRIES:BEGIN
    # PSM:ENTRIES:END
    default     127.0.0.1:${reality_port};
}

server {
    listen 443 reuseport;
    listen [::]:443 reuseport;
    proxy_pass \$psm_backend;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_protocol off;
}
EOF

    # UDP 443 is handled by Hysteria2 directly (separate listener)
    log_ok "Stream SNI 映射表已初始化。"
}

nginx_ensure_stream_sni() {
    if ! is_installed nginx; then
        nginx_install
        return $?
    fi

    mkdir -p "$NGINX_STREAM_D" "$NGINX_HTTP_D" "$NGINX_SSL_DIR"
    _nginx_ensure_stream_module
    _write_nginx_main
    [[ -f "$(_sni_map_file)" ]] || init_stream_sni
    nginx_test_reload
}

nginx_ensure_local_http() {
    if ! is_installed nginx; then
        log_warn "本地伪装 HTTP 站点需要 Nginx。"
        ask_yn "是否现在安装 Nginx？" Y \
            && nginx_install \
            || { log_error "本地伪装需要 Nginx。"; return 1; }
        return 0
    fi

    mkdir -p "$NGINX_HTTP_D" "$NGINX_SSL_DIR"
    _nginx_ensure_stream_module
    _write_nginx_main
    svc_enable nginx 2>/dev/null || true
    svc_is_active nginx || svc_start nginx 2>/dev/null || true
    nginx_test_reload
}

_sni_set_default_backend() {
    local addr="$1"   # e.g. "127.0.0.1:1443"
    local file; file="$(_sni_map_file)"
    if [[ ! -f "$file" ]]; then
        log_warn "未找到 SNI 映射表，正在初始化..."
        nginx_ensure_stream_sni || return 1
    fi
    local tmp; tmp=$(mktemp)
    awk -v addr="$addr" '$1 == "default" {$0 = "    default     " addr ";"} {print}' "$file" > "$tmp" \
        && mv "$tmp" "$file"
    nginx_test_reload
    log_ok "Nginx 默认 stream 后端 → $addr"
}

_sni_add_entry() {
    local domain="$1" upstream="$2"
    local file; file="$(_sni_map_file)"
    [[ -f "$file" ]] || nginx_ensure_stream_sni || return 1

    local tmp; tmp=$(mktemp)
    if awk -v domain="$domain" '$1 == domain {found=1} END {exit found ? 0 : 1}' "$file"; then
        awk -v domain="$domain" -v upstream="$upstream" \
            '$1 == domain {$0 = "    " domain "   " upstream ";"} {print}' "$file" > "$tmp" \
            && mv "$tmp" "$file"
        log_info "已更新 SNI 条目：$domain → $upstream"
    else
        awk -v line="    ${domain}   ${upstream};" \
            '/# PSM:ENTRIES:END/ {print line} {print}' "$file" > "$tmp" \
            && mv "$tmp" "$file"
        log_info "已添加 SNI 条目：$domain → $upstream"
    fi
    nginx_test_reload
    log_ok "SNI 路由已就绪：$domain → $upstream"
}

_sni_remove_entry() {
    local domain="$1"
    local file; file="$(_sni_map_file)"
    [[ -f "$file" ]] || return 0
    local tmp; tmp=$(mktemp)
    awk -v domain="$domain" '$1 != domain {print}' "$file" > "$tmp" && mv "$tmp" "$file"
    nginx_test_reload
    log_ok "已删除 SNI 条目：$domain"
}

_sni_list_entries() {
    local file; file="$(_sni_map_file)"
    [[ -f "$file" ]] || { log_warn "SNI 映射表未初始化。"; return; }
    echo -e "\n${BOLD}当前 SNI 路由表：${NC}"
    awk '/PSM:ENTRIES:BEGIN/ {show=1; next} /PSM:ENTRIES:END/ {show=0} show && NF {print}' "$file" || true
}

stream_add_entry() {
    local domain upstream
    ask domain "域名（SNI）"
    ask upstream "上游地址（如 127.0.0.1:端口）"
    _sni_add_entry "$domain" "$upstream"
}

stream_remove_entry() {
    _sni_list_entries
    local domain
    ask domain "要删除的域名"
    _sni_remove_entry "$domain"
}

# ── HTTP site management ──────────────────────────────────────────────────────
list_sites() {
    echo -e "\n${BOLD}已配置的 HTTP 站点：${NC}"
    ls "$NGINX_HTTP_D"/*.conf 2>/dev/null | while read -r f; do
        local name; name=$(basename "$f" .conf)
        local enabled; svc_is_active nginx && enabled="运行中" || enabled="已停止"
        echo "  $name  [$enabled]"
    done
}

add_site() {
    local domain port proxy_pass tls="no" h3="no" ws="no"
    ask domain "域名（例如 blog.example.com）"
    is_domain "$domain" || { log_error "无效的域名"; return 1; }

    ask proxy_pass "本地上游（例如 127.0.0.1:3001）"
    ask_yn "是否启用 TLS（HTTPS）？" Y && tls="yes"
    ask_yn "是否启用 HTTP/3（QUIC）？" N && h3="yes"
    ask_yn "是否启用 WebSocket 支持？" N && ws="yes"

    local conf_file="$NGINX_HTTP_D/${domain}.conf"

    local tls_listen="" tls_block="" h3_block="" ws_block=""

    if [[ "$tls" == "yes" ]]; then
        source "$LIB_DIR/cert.sh"
        cert_ensure_domain "$domain" || {
            log_warn "取消——无有效证书无法启用 HTTPS。"
            return 1
        }
        local cert_dir="$NGINX_SSL_DIR/$domain"
        mkdir -p "$cert_dir"
        tls_listen="listen 127.0.0.1:8443 ssl http2;"
        tls_block="    ssl_certificate     $cert_dir/fullchain.pem;\n    ssl_certificate_key $cert_dir/privkey.pem;\n    ssl_protocols TLSv1.2 TLSv1.3;"
        [[ "$h3" == "yes" ]] && log_warn "PSM SNI 复用模式下不支持 HTTP/3。"
    else
        tls_listen="listen 80;\nlisten [::]:80;"
    fi

    [[ "$ws" == "yes" ]] && ws_block="    proxy_http_version 1.1;\n    proxy_set_header Upgrade \$http_upgrade;\n    proxy_set_header Connection \"upgrade\";"

    cat > "$conf_file" <<EOF
server {
    $(echo -e "$tls_listen")
    $(echo -e "$h3_block")
    server_name ${domain};

    $(echo -e "$tls_block")

    location / {
        proxy_pass http://${proxy_pass};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        $(echo -e "$ws_block")
    }

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;
}
EOF

    # Add SNI entry so stream routes TLS to this http server
    [[ "$tls" == "yes" ]] && _sni_add_entry "$domain" "127.0.0.1:8443"

    nginx_test_reload
    log_ok "站点已创建：$conf_file"
}

_ensure_camouflage_webroot() {
    local webroot="/var/www/psm-camouflage"
    mkdir -p "$webroot"
    [[ -f "$webroot/index.html" ]] && return 0
    cat > "$webroot/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>服务维护中</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f5f5f5;color:#333;min-height:100vh;display:flex;align-items:center;justify-content:center}
  .card{background:#fff;border-radius:8px;box-shadow:0 2px 12px rgba(0,0,0,.08);padding:48px 40px;text-align:center;max-width:480px}
  h1{font-size:1.6rem;margin-bottom:.8rem}
  p{color:#666;line-height:1.6}
</style>
</head>
<body>
<div class="card">
  <h1>服务维护中</h1>
  <p>我们正在进行计划维护，服务即将恢复。感谢您的耐心等待。</p>
</div>
</body>
</html>
HTML
}

# HTTP camouflage site on 127.0.0.1:8080
# Used as Xray Vision/XHTTP fallback: Xray terminates TLS, forwards non-VLESS HTTP to 8080
nginx_setup_http_camouflage() {
    local domain="$1"
    nginx_ensure_local_http || return 1
    _ensure_camouflage_webroot
    cat > "$NGINX_HTTP_D/http-camouflage-${domain}.conf" <<EOF
server {
    listen 127.0.0.1:8080;
    server_name ${domain};

    root /var/www/psm-camouflage;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log /var/log/nginx/camouflage-http.access.log;
    error_log  /var/log/nginx/camouflage-http.error.log;
}
EOF
    nginx_test_reload
    log_ok "HTTP 伪装站点已就绪：127.0.0.1:8080 → $domain（Xray fallback 目标）"
}

# HTTPS camouflage site on 127.0.0.1:8443
# Used as Reality dest: receives raw TLS stream forwarded by Xray when prober connects
nginx_setup_camouflage_site() {
    local domain="$1"
    local cert_dir="$NGINX_SSL_DIR/$domain"
    nginx_ensure_local_http || return 1

    [[ -f "$cert_dir/fullchain.pem" ]] || {
        log_warn "未找到 $domain 的证书，跳过伪装站点。"
        return 1
    }

    _ensure_camouflage_webroot
    local webroot="/var/www/psm-camouflage"

    # nginx HTTPS virtual host on 127.0.0.1:8443
    # Receives raw TLS stream forwarded by Xray Reality (dest) when non-Reality clients connect.
    # Must support TLS 1.3 + H2 to match what a real browser expects from a modern HTTPS site.
    # http2 on; was added in nginx 1.25.1; use the listen-flag syntax for 1.22.x
    cat > "$NGINX_HTTP_D/camouflage-${domain}.conf" <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root  ${webroot};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log /var/log/nginx/camouflage-${domain}.access.log;
    error_log  /var/log/nginx/camouflage-${domain}.error.log;
}
EOF

    nginx_test_reload
    log_ok "HTTPS 伪装站点已就绪：127.0.0.1:8443 → $domain（含有效证书）"
}

delete_site() {
    list_sites
    local domain
    ask domain "要删除的域名"
    rm -f "$NGINX_HTTP_D/${domain}.conf"
    _sni_remove_entry "$domain" 2>/dev/null
    nginx_test_reload
    log_ok "站点 $domain 已删除。"
}

modify_site_upstream() {
    list_sites
    local domain new_upstream
    ask domain "要修改的域名"
    local conf="$NGINX_HTTP_D/${domain}.conf"
    [[ -f "$conf" ]] || { log_error "未找到：$conf"; return 1; }
    local cur; cur=$(grep "proxy_pass" "$conf" | awk '{print $2}' | tr -d ';')
    log_info "当前上游：$cur"
    ask new_upstream "新上游地址"
    sed -i "s|proxy_pass .*;|proxy_pass http://${new_upstream};|" "$conf"
    nginx_test_reload
}

# ── View logs ─────────────────────────────────────────────────────────────────
nginx_logs() {
    echo -e "\n  1. 访问日志\n  2. 错误日志\n  3. Stream 日志\n  4. Stream 错误日志"
    read -rp "$(echo -e "${CYAN}请选择: ${NC}")" lc
    case "$lc" in
        1) tail -f /var/log/nginx/access.log ;;
        2) tail -f /var/log/nginx/error.log ;;
        3) tail -f /var/log/nginx/stream.log ;;
        4) tail -f /var/log/nginx/stream-error.log ;;
    esac
}

# ── Dependency check ─────────────────────────────────────────────────────────
_nginx_check_deps() {
    is_installed nginx && return 0
    log_warn "Nginx 未安装。"
    ask_yn "是否现在安装 Nginx？" Y \
        && nginx_install \
        || { log_error "需要 Nginx。"; return 1; }
}

# ── Menu ──────────────────────────────────────────────────────────────────────
nginx_menu() {
    _nginx_check_deps || return
    while true; do
        show_menu "Nginx 管理" \
            "安装" \
            "升级" \
            "卸载" \
            "测试配置" \
            "重新加载" \
            "添加 HTTP 站点" \
            "删除站点" \
            "修改站点上游" \
            "列出站点" \
            "添加 SNI 路由条目" \
            "删除 SNI 路由条目" \
            "列出 SNI 路由条目" \
            "查看日志" \
            "服务状态"

        case "$MENU_CHOICE" in
            1)  nginx_install ;;
            2)  nginx_upgrade ;;
            3)  nginx_uninstall ;;
            4)  nginx -t ;;
            5)  nginx_test_reload ;;
            6)  add_site ;;
            7)  delete_site ;;
            8)  modify_site_upstream ;;
            9)  list_sites ;;
            10) stream_add_entry ;;
            11) stream_remove_entry ;;
            12) _sni_list_entries ;;
            13) nginx_logs ;;
            14) svc_status nginx ;;
            0)  return ;;
        esac
        press_enter
    done
}
