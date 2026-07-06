#!/usr/bin/env bash
# cert.sh — SSL certificate management via acme.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ACME_INSTALL_URL="https://get.acme.sh"
SSL_DIR="$NGINX_SSL_DIR"    # /etc/nginx/ssl

# ── Install acme.sh ───────────────────────────────────────────────────────────
acme_install() {
    if [[ -f "$ACME_HOME/acme.sh" ]]; then
        log_info "$(t cert.acme.already_installed)"
        return 0
    fi
    local email; ask email "$(t cert.acme.ask_email)" ""
    [[ -z "$email" ]] && email="admin@$(hostname -f 2>/dev/null || echo 'example.com')"

    # acme.sh 用 crontab 做自动续期——RHEL 系最小安装没有 cronie，装好 acme.sh
    # 也不会续期（安装器只是打印一行警告），这里先保证 cron 可用。
    ensure_cron || true

    # acme.sh installer expects  email=xxx  (no dashes), not --email xxx
    curl -fsSL "$ACME_INSTALL_URL" | sh -s "email=$email"

    export PATH="$ACME_HOME:$PATH"
    if [[ ! -f "$ACME_HOME/acme.sh" ]]; then
        log_error "$(t cert.acme.install_failed "$ACME_HOME/acme.sh")"
        return 1
    fi
    log_ok "$(t cert.acme.installed)"
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
    echo -e "$(t cert.ca.menu)"
    read -rp "$(echo -e "${CYAN}$(t cert.ca.select)${NC}")" ca_choice
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

# ── Let's Encrypt 限流检测与处理 ──────────────────────────────────────────────
# 判断 acme.sh 输出是否命中「按完全相同域名集合」的签发限流（7 天 5 张）。
_cert_is_ratelimited() {
    grep -qiE 'rateLimited|too many certificates' <<<"${1:-}"
}

# 命中限流时给出针对性提示，并可选切换 ZeroSSL 重试一次。
# 用法：_cert_ratelimit_handle <安装用域名> <acme输出> <acme --issue 的参数...>
# 换 CA 重试成功返回 0，否则返回 1。
_cert_ratelimit_handle() {
    local domain="$1" output="$2"; shift 2
    log_error "$(t cert.rate.limit_error "$domain")"
    log_warn "$(t cert.rate.rule_same_set)"
    log_warn "$(t cert.rate.no_dns_bypass)"
    # 尽量从输出中提取解封时间
    local retry
    retry=$(grep -oiE 'retry after[^,"]*' <<<"$output" | head -1)
    [[ -n "$retry" ]] && log_warn "$(t cert.rate.retry_time "$retry")"
    echo -e "$(t cert.rate.options)"
    if ask_yn "$(t cert.rate.ask_zerossl)" N; then
        _acme --set-default-ca --server zerossl \
            || { log_error "$(t cert.rate.switch_zerossl_failed)"; return 1; }
        if _acme --issue "$@"; then
            cert_install_domain "$domain"
            return 0
        fi
        log_error "$(t cert.rate.zerossl_failed)"
        log_warn "$(t cert.rate.zerossl_need_email)"
        echo -e "$(t cert.rate.zerossl_register_cmd)"
        log_warn "$(t cert.rate.zerossl_retry_after_register)"
    fi
    return 1
}

# ── Shared HTTP-01 issue logic ────────────────────────────────────────────────
# Issues a cert for $1, choosing webroot (Nginx running) or standalone.
# Returns 0 and installs to SSL_DIR on success.
_cert_http01_issue() {
    local domain="$1"
    local webroot="/var/www/${domain}"
    mkdir -p "$webroot"
    local issued=0
    local acme_out=""       # 捕获 acme.sh 输出，用于识别限流
    local issue_args=()     # 记录本次签发参数，供限流后换 CA 重试复用

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
        issue_args=(-d "$domain" --webroot "$webroot")
        local rc=0
        acme_out=$(set -o pipefail; _acme --issue "${issue_args[@]}" 2>&1 | tee /dev/stderr) || rc=$?
        (( rc == 0 )) && issued=1
        rm -f "$http_conf"
        nginx -s reload 2>/dev/null || true
    else
        # Nginx not running → standalone (acme.sh binds port 80 directly)
        log_info "$(t cert.http.standalone)"
        log_warn "$(t cert.http.check_points)"
        echo -e "$(t cert.http.need_port80_cloud)"
        echo -e "$(t cert.http.need_port80_local)"

        local fw_tag; fw_tag=$(_fw_open80)
        [[ -n "$fw_tag" ]] && log_info "$(t cert.http.fw_opened "$fw_tag")"

        issue_args=(-d "$domain" --standalone)
        local rc=0
        acme_out=$(set -o pipefail; _acme --issue "${issue_args[@]}" 2>&1 | tee /dev/stderr) || rc=$?
        (( rc == 0 )) && issued=1

        if [[ -n "$fw_tag" ]]; then
            _fw_close80 "$fw_tag"
            log_info "$(t cert.http.fw_restored "$fw_tag")"
        fi
    fi

    if (( !issued )) && _acme_cert_cached "$domain"; then
        log_info "$(t cert.cached.installing "$SSL_DIR")"
        issued=1
    fi

    if (( issued )); then
        cert_install_domain "$domain"
        return 0
    fi

    # 先判断是否命中 Let's Encrypt 限流——限流与验证方式无关，换 DNS-01 也绕不过，
    # 因此这里直接给出针对性提示并跳过下面的「切 DNS-01 重试」分支。
    if _cert_is_ratelimited "$acme_out"; then
        _cert_ratelimit_handle "$domain" "$acme_out" "${issue_args[@]}" && return 0
        return 1
    fi

    log_error "$(t cert.issue.failed_domain "$domain")"
    log_warn "$(t cert.http.conn_refused_hint)"
    log_warn "$(t cert.http.iptables_cannot_fix)"
    echo -e "$(t cert.http.solution_open80)"
    echo -e "$(t cert.http.solution_dns01)"

    # Auto-fallback: if Cloudflare token already configured, offer DNS-01 immediately
    local cf_token; cf_token=$(state_get "cf_api_token" 2>/dev/null || true)
    if [[ -n "$cf_token" ]]; then
        log_info "$(t cert.http.cf_token_detected)"
        if ask_yn "$(t cert.http.ask_dns_retry)" Y; then
            _ensure_cf_env
            if _acme --issue --dns dns_cf -d "$domain"; then
                cert_install_domain "$domain"
                return 0
            else
                log_error "$(t cert.http.dns_failed_cf)"
            fi
        fi
    fi

    return 1
}

# ── Issue via HTTP-01 (standalone / webroot) ──────────────────────────────────
cert_issue_http() {
    [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
    _select_ca
    local domain; ask domain "$(t cert.ask_domain)"
    is_domain "$domain" || { log_error "$(t cert.invalid_domain)"; return 1; }
    _cert_http01_issue "$domain"
}

# ── Issue via DNS-01 ──────────────────────────────────────────────────────────
cert_issue_dns() {
    [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
    _select_ca

    local domain; ask domain "$(t cert.ask_domain_wildcard)"
    is_domain "${domain#\*.}" || { log_error "$(t cert.invalid_domain)"; return 1; }

    echo -e "$(t cert.dns_api.menu5)"
    read -rp "$(echo -e "${CYAN}$(t cert.dns_provider.select)${NC}")" dns_choice

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
            ask ali_key    "$(t cert.ask_ali_key)"
            ask ali_secret "$(t cert.ask_ali_secret)"
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
        *) log_error "$(t cert.invalid_option)"; return 1 ;;
    esac

    local dns_out rc=0
    dns_out=$(set -o pipefail; _acme --issue --dns "$dns_plugin" -d "$domain" $extra_args 2>&1 | tee /dev/stderr) || rc=$?
    if (( rc != 0 )); then
        # 限流时给针对性提示并可选换 ZeroSSL 重试；否则按普通失败处理
        if _cert_is_ratelimited "$dns_out"; then
            _cert_ratelimit_handle "${domain#\*.}" "$dns_out" \
                --dns "$dns_plugin" -d "$domain" $extra_args && return 0
        fi
        log_error "$(t cert.issue.failed)"; return 1
    fi

    cert_install_domain "${domain#\*.}"
}

# ── Manual import ─────────────────────────────────────────────────────────────
cert_import_manual() {
    local domain; ask domain "$(t cert.ask_domain)"
    local cert_file key_file ca_file

    ask cert_file "$(t cert.import.ask_cert_file)"
    ask key_file  "$(t cert.import.ask_key_file)"
    ask ca_file   "$(t cert.import.ask_ca_file)" ""

    [[ -f "$cert_file" ]] || { log_error "$(t cert.import.cert_not_found)"; return 1; }
    [[ -f "$key_file"  ]] || { log_error "$(t cert.import.key_not_found)";  return 1; }

    local dest="$SSL_DIR/$domain"
    mkdir -p "$dest"
    cp "$cert_file" "$dest/fullchain.pem"
    cp "$key_file"  "$dest/privkey.pem"
    [[ -n "$ca_file" && -f "$ca_file" ]] && cp "$ca_file" "$dest/chain.pem"
    chmod 600 "$dest/privkey.pem"
    log_ok "$(t cert.import.imported_to "$dest")"
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
    log_ok "$(t cert.install.installed "$dest")"
}

# ── Renew ─────────────────────────────────────────────────────────────────────
cert_renew() {
    local domain; ask domain "$(t cert.renew.ask_domain)" ""
    # 默认普通续期，由 acme.sh 自行判断是否到期；强制续期会忽略有效期，易触发限流
    local force=""
    ask_yn "$(t cert.renew.ask_force)" N && force="--force"
    # 普通续期时 acme.sh 对「未到续期时间」返回 2，需吞掉，避免 errexit 中断菜单
    local rc=0
    if [[ -z "$domain" ]]; then
        _acme --renew-all $force || {
            rc=$?
            if (( rc == 2 )); then
                log_info "$(t cert.renew.not_due)"
            else
                log_error "$(t cert.renew.failed)"
            fi
        }
    else
        _acme --renew -d "$domain" $force || {
            rc=$?
            if (( rc == 2 )); then
                log_info "$(t cert.renew.not_due)"
            else
                log_error "$(t cert.renew.failed)"
            fi
        }
    fi
}

cert_auto_renew() {
    # acme.sh sets up a cron job on install; this makes it explicit
    _acme --install-cronjob
    log_ok "$(t cert.auto_renew.installed)"
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
    local domain; ask domain "$(t cert.delete.ask_domain)"
    # 域名为空时直接返回，避免 rm -rf 在空值下清空整个证书目录
    [[ -z "$domain" ]] && { log_error "$(t cert.domain_required)"; return 1; }
    _acme --remove -d "$domain" 2>/dev/null
    ask_yn "$(t cert.delete.ask_local "$SSL_DIR/$domain")" N \
        && rm -rf "${SSL_DIR:?}/${domain:?}"
    log_ok "$(t cert.delete.deleted)"
}

# ── Cloudflare env helper ─────────────────────────────────────────────────────
_ensure_cf_env() {
    local cf_token; cf_token=$(state_get "cf_api_token")
    if [[ -z "$cf_token" ]]; then
        ask cf_token "$(t cert.cf.ask_token)"
        state_set "cf_api_token" "$cf_token"
    fi
    export CF_Token="$cf_token"
}

# ── Ensure cert exists for a domain ──────────────────────────────────────────
# Usage: cert_ensure_domain <domain> [reason_text]
# Returns 0 if cert is ready, 1 if not/skipped.
cert_ensure_domain() {
    local domain="$1"
    local reason="${2:-$(t cert.ensure.default_reason)}"
    local cert_dir="$SSL_DIR/$domain"

    if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
        log_ok "$(t cert.ensure.found "$domain")"
        return 0
    fi

    # acme.sh cache exists but nginx ssl dir was deleted (e.g. after uninstall) → reinstall
    if _acme_cert_cached "$domain"; then
        log_info "$(t cert.cached.installing "$cert_dir")"
        cert_install_domain "$domain"
        return 0
    fi

    log_warn "$(t cert.ensure.missing "$domain")"
    echo -e "\n  ${reason}"
    echo -e "$(t cert.ensure.menu)"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" cc

    case "${cc:-0}" in
        1)
            [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
            [[ -f "$ACME_HOME/acme.sh" ]] || { log_error "$(t cert.ensure.acme_unavailable)"; return 1; }
            _select_ca
            _cert_http01_issue "$domain" || return 1
            ;;
        2)
            [[ -f "$ACME_HOME/acme.sh" ]] || acme_install
            _select_ca
            echo -e "$(t cert.dns_api.menu4)"
            read -rp "$(echo -e "${CYAN}$(t cert.dns_provider.select)${NC}")" dns_choice
            local dns_plugin
            case "${dns_choice:-1}" in
                1) dns_plugin="dns_cf"; _ensure_cf_env ;;
                2) dns_plugin="dns_dp"
                   local dp_id dp_key
                   ask dp_id  "DNSPod App ID"; ask dp_key "DNSPod App Key"
                   export DP_Id="$dp_id" DP_Key="$dp_key" ;;
                3) dns_plugin="dns_ali"
                   local ali_key ali_secret
                   ask ali_key "$(t cert.ask_ali_key_short)"; ask ali_secret "$(t cert.ask_ali_secret_short)"
                   export Ali_Key="$ali_key" Ali_Secret="$ali_secret" ;;
                4) dns_plugin="dns_manual" ;;
                *) log_error "$(t cert.invalid_option)"; return 1 ;;
            esac
            local dns_out rc=0
            dns_out=$(set -o pipefail; _acme --issue --dns "$dns_plugin" -d "$domain" 2>&1 | tee /dev/stderr) || rc=$?
            if (( rc == 0 )); then
                cert_install_domain "$domain"
            elif _cert_is_ratelimited "$dns_out"; then
                # 限流与验证方式无关，给针对性提示并可选换 ZeroSSL 重试
                _cert_ratelimit_handle "$domain" "$dns_out" \
                    --dns "$dns_plugin" -d "$domain" || return 1
            else
                log_error "$(t cert.issue.failed_domain "$domain")"
                return 1
            fi
            ;;
        3)
            local cert_file key_file
            ask cert_file "$(t cert.import.ask_cert_file)"
            ask key_file  "$(t cert.import.ask_key_file)"
            [[ -f "$cert_file" ]] || { log_error "$(t cert.import.cert_not_found_path "$cert_file")"; return 1; }
            [[ -f "$key_file"  ]] || { log_error "$(t cert.import.key_not_found_path "$key_file")";   return 1; }
            mkdir -p "$cert_dir"
            cp "$cert_file" "$cert_dir/fullchain.pem"
            cp "$key_file"  "$cert_dir/privkey.pem"
            chmod 600 "$cert_dir/privkey.pem"
            log_ok "$(t cert.install.installed_to "$cert_dir")"
            ;;
        0)
            log_warn "$(t cert.ensure.skipped)"
            return 1
            ;;
        *)
            log_error "$(t cert.invalid_option)"
            return 1
            ;;
    esac
}

# ── Dependency check ─────────────────────────────────────────────────────────
_cert_check_deps() {
    ensure_pkg_deps curl openssl socat
    if ! [[ -f "$ACME_HOME/acme.sh" ]]; then
        log_warn "$(t cert.deps.acme_missing)"
        ask_yn "$(t cert.deps.ask_install)" Y && acme_install || log_warn "$(t cert.deps.required)"
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
cert_menu() {
    _cert_check_deps
    while true; do
        show_menu "$(t cert.menu.title)" \
            "$(t cert.menu.install_acme)" \
            "$(t cert.menu.issue_http)" \
            "$(t cert.menu.issue_dns)" \
            "$(t cert.menu.import)" \
            "$(t cert.menu.renew)" \
            "$(t cert.menu.auto_renew)" \
            "$(t cert.menu.list)" \
            "$(t cert.menu.delete)"

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
