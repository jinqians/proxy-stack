#!/usr/bin/env bash
# nginx.sh — Nginx install, stream/http site management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NGINX_STREAM_D="$NGINX_STREAM_DIR"    # /etc/nginx/stream.d
NGINX_HTTP_D="$NGINX_HTTP_DIR"         # /etc/nginx/conf.d
NGINX_MAIN="/etc/nginx/nginx.conf"

# ── Install ───────────────────────────────────────────────────────────────────
nginx_install() {
    if is_installed nginx; then
        log_info "$(t nginx.installed "$(nginx -v 2>&1)")"
        nginx_ensure_stream_sni
        return 0
    fi

    detect_os
    log_step "$(t nginx.installing)"
    case "$OS_ID" in
        ubuntu|debian|raspbian)
            pkg_update
            # libnginx-mod-stream provides the stream {} / ssl_preread support
            pkg_install nginx libnginx-mod-stream
            ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora)
            # nginx + nginx-mod-stream live in AppStream on EL8/9 (and in the
            # base repos on AL2023/Fedora) — EPEL is normally NOT needed. Fall
            # back to enabling EPEL only if the base install fails (older CentOS).
            pkg_install nginx 2>/dev/null \
                || { ensure_epel || true; pkg_install nginx 2>/dev/null || true; }
            is_installed nginx || die "$(t nginx.install_fail_sources)"
            pkg_install nginx-mod-stream 2>/dev/null || true
            ;;
    esac
    _nginx_selinux_permit

    mkdir -p "$NGINX_STREAM_D" "$NGINX_HTTP_D" "$NGINX_SSL_DIR"

    _write_nginx_main
    init_stream_sni
    svc_enable nginx
    # Verify the generated config BEFORE (re)starting. A `stream {}` block with
    # the stream module missing fails `nginx -t` and takes down ALL of nginx
    # (including plain reverse-proxy sites), so never blindly restart — and never
    # report success when the service didn't actually come up.
    local test_out
    if test_out=$(nginx -t 2>&1); then
        if svc_restart nginx; then
            log_ok "$(t nginx.installed_done)"
        else
            log_error "$(t nginx.config_valid_start_fail)"
            svc_status nginx 2>&1 | tail -n 15 >&2 || true
            return 1
        fi
    else
        log_error "$(t nginx.config_test_fail_no_start)"
        echo "$test_out" >&2
        if grep -q 'unknown directive "stream"' <<<"$test_out"; then
            log_error "$(t nginx.stream_directive_missing)"
        fi
        return 1
    fi
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

# ── SELinux (RHEL family: CentOS/Rocky/Alma/Oracle default to Enforcing) ─────
# nginx runs confined as httpd_t there, and httpd_t may NOT initiate outbound
# connections by default — so proxy_pass to the local Xray/camouflage upstream
# (127.0.0.1:1443/8443/8080) fails with "Permission denied (13)" and the whole
# SNI-routing design silently breaks. Flip the standard boolean that allows it.
# No-op when SELinux is absent (Debian/Ubuntu) or not enforcing.
_nginx_selinux_permit() {
    command -v getenforce &>/dev/null || return 0
    [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return 0
    if command -v getsebool &>/dev/null \
        && getsebool httpd_can_network_connect 2>/dev/null | grep -q 'on$'; then
        return 0
    fi
    log_step "$(t nginx.selinux.permitting)"
    if setsebool -P httpd_can_network_connect 1 2>/dev/null; then
        log_ok "$(t nginx.selinux.enabled)"
    else
        log_warn "$(t nginx.selinux.failed)"
        log_warn "  setsebool -P httpd_can_network_connect 1"
    fi
}

# Locate a dynamic nginx module .so by name across distro-specific module dirs.
_nginx_find_module() {
    find /usr/lib/nginx/modules /usr/lib64/nginx/modules \
         /usr/share/nginx/modules /etc/nginx/modules \
         -name "$1" 2>/dev/null | head -1
}

# True if the stream module can actually be used: compiled statically into
# nginx, OR present on disk as a dynamic .so we can load. Checks the real .so —
# NOT the package DB, since a package in "rc" (removed, config-only) state makes
# `dpkg -l` succeed while the .so is gone.
_nginx_stream_module_available() {
    local nginx_v; nginx_v=$(nginx -V 2>&1)
    if grep -qw -- '--with-stream' <<<"$nginx_v" && ! grep -q -- '--with-stream=dynamic' <<<"$nginx_v"; then
        return 0   # static build → always available
    fi
    [[ -n "$(_nginx_find_module ngx_stream_module.so)" ]]
}

# Emit the top-level directive(s) that make the `stream {}` block + ssl_preread
# work, tolerant of every packaging layout:
#   - static build   (--with-stream, no =dynamic): built-in → emit nothing
#   - dynamic build:  load ngx_stream_module.so (+ a separate ssl_preread .so if
#                     the distro splits it out, e.g. nginx.org / RHEL builds)
#   - .so not found on disk but Debian ships load lines under modules-enabled:
#                     fall back to the distro-native include (last resort)
# We never emit BOTH an explicit load_module and the include — loading the same
# module twice makes nginx refuse to start.
_nginx_stream_load_directive() {
    local nginx_v; nginx_v=$(nginx -V 2>&1)
    if grep -qw -- '--with-stream' <<<"$nginx_v" && ! grep -q -- '--with-stream=dynamic' <<<"$nginx_v"; then
        return 0   # static → nothing to load
    fi

    local out="" so found
    for so in ngx_stream_module.so ngx_stream_ssl_preread_module.so; do
        found=$(_nginx_find_module "$so")
        [[ -n "$found" ]] && out+="load_module ${found};"$'\n'
    done
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
        return 0
    fi

    # Couldn't find the .so directly — use Debian's modules-enabled include.
    if compgen -G '/etc/nginx/modules-enabled/*.conf' >/dev/null 2>&1; then
        echo 'include /etc/nginx/modules-enabled/*.conf;'
    fi
}

_write_nginx_main() {
    local nginx_user stream_load
    # Make sure the stream module is installed BEFORE we compute the load
    # directive — otherwise we'd write a `stream {}` block with nothing to load.
    _nginx_ensure_stream_module || true
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
    log_step "$(t nginx.upgrading)"
    case "$OS_ID" in
        ubuntu|debian|raspbian) apt-get install --only-upgrade -y nginx ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora) "$(_rhel_pkg_cmd)" update -y nginx ;;
    esac
    nginx_test_reload
    log_ok "$(t nginx.upgraded)"
}

nginx_uninstall() {
    ask_yn "$(t nginx.ask_uninstall)" N || return 0
    svc_stop nginx
    detect_os
    case "$OS_ID" in
        ubuntu|debian|raspbian) apt-get purge -y nginx nginx-common ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora) "$(_rhel_pkg_cmd)" remove -y nginx ;;
    esac
    log_ok "$(t nginx.uninstalled)"
}

# ── Stream SNI routing ────────────────────────────────────────────────────────
# Each SNI block lives in /etc/nginx/stream.d/00-sni-map.conf
# Additional stream entries are separate files.

_sni_map_file() { echo "$NGINX_STREAM_D/00-sni-map.conf"; }

# 未知 SNI 的兜底。空值让 ngx_stream_proxy 解析 proxy_pass 失败并直接关闭连接，
# 不建立任何上游连接 —— 零回源流量。
#
# 为什么必须是黑洞而不能兜底到 Reality：Reality 会把「认证未通过」的连接原样转发给
# dest 以维持伪装（官方语义）。一旦未知 SNI 也被喂给 Reality，任何人只要连上 443 就能
# 让本机替他跑一趟到 dest 的流量；若 dest 又是 Cloudflare 这类多租户共享前端，攻击者
# 只需把 ClientHello 的 SNI 填成任意 CF 站点，就能拿到一条通往全 CF 网络的免费隧道。
#
# 黑洞化不削弱伪装：拿本机真实 serverName 来探测的连接仍在 ENTRIES 里命中并走完整的
# Reality 回落；被关掉的只有随机 SNI 扫描，而对未知 SNI 断连正是普通服务器的行为。
SNI_DEFAULT_BLACKHOLE='default     "";'

# Ensure the stream module is usable. Checks the real .so on disk, installs the
# distro module package if it's missing, and returns non-zero if stream STILL
# isn't available afterwards — so callers can warn instead of writing a
# `stream {}` block that would break all of nginx. Does NOT restart nginx here;
# the caller reloads once, after the config is written and tested.
_nginx_ensure_stream_module() {
    _nginx_stream_module_available && return 0
    detect_os
    log_step "$(t nginx.stream.installing)"
    case "$OS_ID" in
        ubuntu|debian|raspbian)
            # Retry behind a `pkg_update` — the usual reason the .so is absent is
            # a stale/empty apt index (the module then silently didn't install
            # alongside nginx), which refreshing the index fixes.
            pkg_install libnginx-mod-stream 2>/dev/null \
                || { pkg_update 2>/dev/null || true; pkg_install libnginx-mod-stream 2>/dev/null || true; }
            ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora)
            pkg_install nginx-mod-stream 2>/dev/null || true
            ;;
    esac
    _nginx_stream_module_available && return 0
    log_warn "$(t nginx.stream.missing)"
    log_warn "$(t nginx.stream.sni_dep)"
    return 1
}

init_stream_sni() {
    # Called once during install to set up the SNI map + listener
    mkdir -p "$NGINX_STREAM_D" "$NGINX_HTTP_D" "$NGINX_SSL_DIR"
    _nginx_ensure_stream_module

    cat > "$(_sni_map_file)" <<EOF
# PSM-managed SNI map — edit via PSM, not directly
map \$ssl_preread_server_name \$psm_backend {
    # domain → upstream entries are injected below
    # PSM:ENTRIES:BEGIN
    # PSM:ENTRIES:END
    ${SNI_DEFAULT_BLACKHOLE}
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

    # 443 是 SNI 分流的公网入口。防火墙（ufw/firewalld/iptables）开启时若不放行，
    # 所有挂载节点都表现为 TCP 超时；直连分支会询问放行，挂载分支此前从未放行。
    source "$LIB_DIR/system.sh"
    firewall_open_port 443 tcp

    # UDP 443 is handled by Hysteria2 directly (separate listener)
    log_ok "$(t nginx.stream.sni_initialized)"
}

nginx_ensure_stream_sni() {
    if ! is_installed nginx; then
        nginx_install
        return $?
    fi

    mkdir -p "$NGINX_STREAM_D" "$NGINX_HTTP_D" "$NGINX_SSL_DIR"
    _nginx_ensure_stream_module
    _nginx_selinux_permit
    _write_nginx_main
    if [[ -f "$(_sni_map_file)" ]]; then
        # 幂等重放 443/tcp 放行：挂载流程每次经过这里，覆盖建表后才启用防火墙的场景
        source "$LIB_DIR/system.sh"
        firewall_open_port 443 tcp
        # 老安装的 default 可能仍指向 Reality，收敛成黑洞（幂等）
        _sni_harden_default
    else
        init_stream_sni
    fi
    nginx_test_reload
}

nginx_ensure_local_http() {
    if ! is_installed nginx; then
        log_warn "$(t nginx.local_http.need)"
        ask_yn "$(t nginx.ask_install_now)" Y \
            && nginx_install \
            || { log_error "$(t nginx.local_http.required)"; return 1; }
        return 0
    fi

    mkdir -p "$NGINX_HTTP_D" "$NGINX_SSL_DIR"
    _nginx_ensure_stream_module
    _nginx_selinux_permit
    _write_nginx_main
    svc_enable nginx 2>/dev/null || true
    svc_is_active nginx || svc_start nginx 2>/dev/null || true
    nginx_test_reload
}

# 把 map 的 default 行收敛成黑洞。对已存在的安装是一次性迁移：老版本把 Reality 设成
# 了未知 SNI 的兜底后端，那正是被当作免费中继白嫖流量的入口（见 SNI_DEFAULT_BLACKHOLE）。
# 已挂载的节点都各自有显式 ENTRIES 条目，不依赖 default，所以收敛不影响正常连接。
# 幂等：已是黑洞则不写盘、不 reload。
_sni_harden_default() {
    local file; file="$(_sni_map_file)"
    [[ -f "$file" ]] || return 0

    local old
    old=$(awk '$1 == "default" {gsub(/;$/, "", $2); print $2; exit}' "$file")
    [[ -z "$old" || "$old" == '""' ]] && return 0

    local tmp; tmp=$(mktemp)
    awk -v repl="    ${SNI_DEFAULT_BLACKHOLE}" '$1 == "default" {$0 = repl} {print}' "$file" > "$tmp" \
        && mv "$tmp" "$file"
    nginx_test_reload
    log_ok "$(t nginx.sni.default_blackholed "$old")"
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
        log_info "$(t nginx.sni.updated "$domain" "$upstream")"
    else
        awk -v line="    ${domain}   ${upstream};" \
            '/# PSM:ENTRIES:END/ {print line} {print}' "$file" > "$tmp" \
            && mv "$tmp" "$file"
        log_info "$(t nginx.sni.added "$domain" "$upstream")"
    fi
    nginx_test_reload
    log_ok "$(t nginx.sni.ready "$domain" "$upstream")"
}

# Print the upstream currently mapped to <domain> (e.g. "127.0.0.1:2443").
# Prints nothing / returns 1 when the domain has no entry. Lets callers detect
# cross-core SNI collisions before _sni_add_entry silently overwrites a route.
_sni_lookup_entry() {
    local domain="$1" file upstream
    file="$(_sni_map_file)"
    [[ -f "$file" ]] || return 1
    upstream=$(awk -v d="$domain" '
        /# PSM:ENTRIES:BEGIN/ {s=1; next}
        /# PSM:ENTRIES:END/   {s=0}
        s && $1 == d          {gsub(/;$/, "", $2); print $2; exit}
    ' "$file")
    [[ -n "$upstream" ]] || return 1
    printf '%s' "$upstream"
}

_sni_remove_entry() {
    local domain="$1"
    local file; file="$(_sni_map_file)"
    [[ -f "$file" ]] || return 0
    local tmp; tmp=$(mktemp)
    awk -v domain="$domain" '$1 != domain {print}' "$file" > "$tmp" && mv "$tmp" "$file"
    nginx_test_reload
    log_ok "$(t nginx.sni.removed "$domain")"
}

_sni_list_entries() {
    local file; file="$(_sni_map_file)"
    [[ -f "$file" ]] || { log_warn "$(t nginx.sni.not_initialized)"; return; }
    echo -e "\n${BOLD}$(t nginx.sni.table_title)${NC}"
    awk '/PSM:ENTRIES:BEGIN/ {show=1; next} /PSM:ENTRIES:END/ {show=0} show && NF {print}' "$file" || true
}

stream_add_entry() {
    local domain upstream
    ask domain "$(t nginx.ask.sni_domain)"
    ask upstream "$(t nginx.ask.sni_upstream)"
    _sni_add_entry "$domain" "$upstream"
}

stream_remove_entry() {
    _sni_list_entries
    local domain
    ask domain "$(t nginx.ask.delete_domain)"
    _sni_remove_entry "$domain"
}

# ── HTTP site management ──────────────────────────────────────────────────────
list_sites() {
    echo -e "\n${BOLD}$(t nginx.sites.title)${NC}"
    ls "$NGINX_HTTP_D"/*.conf 2>/dev/null | while read -r f; do
        local name; name=$(basename "$f" .conf)
        local enabled; svc_is_active nginx && enabled="$(t nginx.status.running)" || enabled="$(t nginx.status.stopped)"
        echo "  $name  [$enabled]"
    done
}

add_site() {
    local domain proxy_pass tls="no" h3="no" ws="no"
    ask domain "$(t nginx.ask.domain)"
    is_domain "$domain" || { log_error "$(t nginx.invalid_domain)"; return 1; }

    ask proxy_pass "$(t nginx.ask.proxy_pass)"
    ask_yn "$(t nginx.ask.tls)" Y && tls="yes"
    ask_yn "$(t nginx.ask.h3)" N && h3="yes"
    ask_yn "$(t nginx.ask.ws)" N && ws="yes"

    local conf_file="$NGINX_HTTP_D/${domain}.conf"

    local tls_listen="" tls_block="" h3_block="" ws_block=""

    if [[ "$tls" == "yes" ]]; then
        source "$LIB_DIR/cert.sh"
        cert_ensure_domain "$domain" || {
            log_warn "$(t nginx.cancel.no_cert_https)"
            return 1
        }
        local cert_dir="$NGINX_SSL_DIR/$domain"
        mkdir -p "$cert_dir"
        tls_listen="listen 127.0.0.1:8443 ssl http2;"
        tls_block="    ssl_certificate     $cert_dir/fullchain.pem;\n    ssl_certificate_key $cert_dir/privkey.pem;\n    ssl_protocols TLSv1.2 TLSv1.3;"
        [[ "$h3" == "yes" ]] && log_warn "$(t nginx.h3.unsupported_sni)"
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
    log_ok "$(t nginx.site.created "$conf_file")"
}

_ensure_camouflage_webroot() {
    local webroot="/var/www/psm-camouflage"
    mkdir -p "$webroot"
    [[ -f "$webroot/index.html" ]] && return 0
    cat > "$webroot/index.html" <<HTML
<!DOCTYPE html>
<html lang="$(t nginx.camouflage.html_lang)">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(t nginx.camouflage.title)</title>
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
  <h1>$(t nginx.camouflage.title)</h1>
  <p>$(t nginx.camouflage.body)</p>
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
    log_ok "$(t nginx.camouflage.http_ready "$domain")"
}

# HTTPS camouflage site on 127.0.0.1:8443
# Used as Reality dest: receives raw TLS stream forwarded by Xray when prober connects
nginx_setup_camouflage_site() {
    local domain="$1"
    local cert_dir="$NGINX_SSL_DIR/$domain"
    nginx_ensure_local_http || return 1

    [[ -f "$cert_dir/fullchain.pem" ]] || {
        log_warn "$(t nginx.camouflage.cert_missing "$domain")"
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
    log_ok "$(t nginx.camouflage.https_ready "$domain")"
}

delete_site() {
    list_sites
    local domain
    ask domain "$(t nginx.ask.delete_domain)"
    rm -f "$NGINX_HTTP_D/${domain}.conf"
    _sni_remove_entry "$domain" 2>/dev/null
    nginx_test_reload
    log_ok "$(t nginx.site.deleted "$domain")"
}

modify_site_upstream() {
    list_sites
    local domain new_upstream
    ask domain "$(t nginx.ask.modify_domain)"
    local conf="$NGINX_HTTP_D/${domain}.conf"
    [[ -f "$conf" ]] || { log_error "$(t nginx.not_found "$conf")"; return 1; }
    local cur; cur=$(grep "proxy_pass" "$conf" | awk '{print $2}' | tr -d ';')
    log_info "$(t nginx.current_upstream "$cur")"
    ask new_upstream "$(t nginx.ask.new_upstream)"
    sed -i "s|proxy_pass .*;|proxy_pass http://${new_upstream};|" "$conf"
    nginx_test_reload
}

# ── View logs ─────────────────────────────────────────────────────────────────
nginx_logs() {
    echo -e "$(t nginx.logs.menu)"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" lc
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
    log_warn "$(t nginx.not_installed)"
    ask_yn "$(t nginx.ask_install_now)" Y \
        && nginx_install \
        || { log_error "$(t nginx.required)"; return 1; }
}

# ── Menu ──────────────────────────────────────────────────────────────────────
nginx_menu() {
    _nginx_check_deps || return
    while true; do
        show_menu "$(t nginx.menu.title)" \
            "$(t nginx.menu.install)" \
            "$(t nginx.menu.upgrade)" \
            "$(t nginx.menu.uninstall)" \
            "$(t nginx.menu.test)" \
            "$(t nginx.menu.reload)" \
            "$(t nginx.menu.add_site)" \
            "$(t nginx.menu.delete_site)" \
            "$(t nginx.menu.modify_upstream)" \
            "$(t nginx.menu.list_sites)" \
            "$(t nginx.menu.add_sni)" \
            "$(t nginx.menu.delete_sni)" \
            "$(t nginx.menu.list_sni)" \
            "$(t nginx.menu.logs)" \
            "$(t nginx.menu.status)"

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
