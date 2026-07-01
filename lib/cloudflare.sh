#!/usr/bin/env bash
# cloudflare.sh — Cloudflare DNS, DDNS, API management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CF_API="https://api.cloudflare.com/client/v4"

# ── API credentials ───────────────────────────────────────────────────────────
cf_setup_api() {
    echo -e "  认证方式：\n  1. API Token（推荐）\n  2. Global API Key"
    read -rp "$(echo -e "${CYAN}请选择 [1]: ${NC}")" am

    local cf_email="" cf_token="" cf_key=""
    if [[ "${am:-1}" == "2" ]]; then
        ask cf_email "Cloudflare 账号邮箱"
        ask cf_key   "Global API Key"
        state_set "cf_auth_method" "apikey"
        state_set "cf_email"       "$cf_email"
        state_set "cf_global_key"  "$cf_key"
    else
        ask cf_token "Cloudflare API Token（含 Zone DNS 编辑权限）"
        state_set "cf_auth_method" "token"
        state_set "cf_api_token"   "$cf_token"
    fi
    log_ok "Cloudflare 凭据已保存。"
}

_cf_headers() {
    local method; method=$(state_get "cf_auth_method")
    if [[ "$method" == "apikey" ]]; then
        echo -H "X-Auth-Email: $(state_get cf_email)" \
             -H "X-Auth-Key: $(state_get cf_global_key)"
    else
        echo -H "Authorization: Bearer $(state_get cf_api_token)"
    fi
}

_cf_curl() {
    local token; token=$(state_get "cf_api_token")
    local email; email=$(state_get "cf_email")
    local key;   key=$(state_get "cf_global_key")
    local method; method=$(state_get "cf_auth_method")

    if [[ "$method" == "apikey" ]]; then
        curl -s -H "X-Auth-Email: $email" -H "X-Auth-Key: $key" \
             -H "Content-Type: application/json" "$@"
    else
        curl -s -H "Authorization: Bearer $token" \
             -H "Content-Type: application/json" "$@"
    fi
}

# ── Zone helpers ──────────────────────────────────────────────────────────────
cf_list_zones() {
    _cf_curl "$CF_API/zones?per_page=50" | jq -r '.result[] | "\(.id)\t\(.name)"' 2>/dev/null
}

cf_get_zone_id() {
    local domain="$1"
    # try exact match first, then root domain
    local root_domain; root_domain=$(echo "$domain" | awk -F'.' '{print $(NF-1)"."$NF}')
    _cf_curl "$CF_API/zones?name=$root_domain" | jq -r '.result[0].id' 2>/dev/null
}

# ── DNS record management ─────────────────────────────────────────────────────
cf_list_dns() {
    local domain; ask domain "域名（例如 example.com）"
    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "未找到该域名的 Zone"; return 1; }
    _cf_curl "$CF_API/zones/$zone_id/dns_records?per_page=100" \
        | jq -r '.result[] | "\(.id)\t\(.type)\t\(.name)\t\(.content)\tproxied:\(.proxied)"' 2>/dev/null \
        | column -t
}

cf_add_dns() {
    local domain type name content proxied ttl
    ask domain  "根域名（Zone）"
    ask type    "记录类型" "A"
    ask name    "记录名称（例如 www 或 @）"
    ask content "记录值（IP 或目标）"
    ask_yn "是否开启 Cloudflare 代理？" N && proxied="true" || proxied="false"
    ask ttl "TTL（1=自动）" "1"

    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "未找到该域名的 Zone"; return 1; }

    local full_name; [[ "$name" == "@" ]] && full_name="$domain" || full_name="${name}.${domain}"

    local result
    result=$(_cf_curl -X POST "$CF_API/zones/$zone_id/dns_records" \
        -d "{\"type\":\"$type\",\"name\":\"$full_name\",\"content\":\"$content\",\"ttl\":$ttl,\"proxied\":$proxied}")
    echo "$result" | jq -r 'if .success then "记录已创建：\(.result.id)" else "错误：\(.errors[0].message)" end'
}

cf_delete_dns() {
    local domain; ask domain "根域名"
    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "未找到该域名的 Zone"; return 1; }

    cf_list_dns <<< "$domain" 2>/dev/null || true
    local record_id; ask record_id "要删除的记录 ID"
    local result
    result=$(_cf_curl -X DELETE "$CF_API/zones/$zone_id/dns_records/$record_id")
    echo "$result" | jq -r 'if .success then "已删除。" else "错误：\(.errors[0].message)" end'
}

# ── DDNS ──────────────────────────────────────────────────────────────────────
cf_ddns_update() {
    local domain; domain=$(state_get "ddns_domain")
    [[ -z "$domain" ]] && ask domain "DDNS 域名（例如 home.example.com）"

    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "未找到 $domain 的 Zone"; return 1; }

    local current_ip; current_ip=$(get_ipv4)
    [[ -z "$current_ip" ]] && { log_error "无法获取公网 IP"; return 1; }

    # Find existing A record
    local record; record=$(_cf_curl "$CF_API/zones/$zone_id/dns_records?type=A&name=$domain")
    local record_id; record_id=$(echo "$record" | jq -r '.result[0].id')
    local old_ip;    old_ip=$(echo "$record"    | jq -r '.result[0].content')

    if [[ "$current_ip" == "$old_ip" ]]; then
        log_info "DDNS：IP 未变化（$current_ip）"
        return 0
    fi

    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        # Create new record
        _cf_curl -X POST "$CF_API/zones/$zone_id/dns_records" \
            -d "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$current_ip\",\"ttl\":60,\"proxied\":false}" \
            | jq -r 'if .success then "DDNS 记录已创建：\(.result.content)" else .errors end'
    else
        # Update existing
        _cf_curl -X PATCH "$CF_API/zones/$zone_id/dns_records/$record_id" \
            -d "{\"content\":\"$current_ip\"}" \
            | jq -r 'if .success then "DDNS 已更新：\(.result.content)" else .errors end'
    fi

    state_set "ddns_domain"    "$domain"
    state_set "ddns_last_ip"   "$current_ip"
    state_set "ddns_last_time" "$(date '+%Y-%m-%d %H:%M:%S')"
}

cf_ddns_install_cron() {
    local domain; ask domain "DDNS 域名"
    state_set "ddns_domain" "$domain"

    local interval
    ask interval "更新间隔（分钟，1-60）" "5"
    [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 60 )) \
        || { log_error "无效间隔，必须为 1-60。"; return 1; }

    local cron_expr
    if (( interval == 60 )); then
        cron_expr="0 * * * *"
    else
        cron_expr="*/${interval} * * * *"
    fi

    echo "${cron_expr} root ${PSM_ROOT}/manager.sh --ddns-update >> /var/log/psm-ddns.log 2>&1" \
        > /etc/cron.d/psm-ddns
    state_set "ddns_interval" "$interval"
    log_ok "DDNS 定时任务已安装（每 ${interval} 分钟）for $domain"
}

cf_ddns_remove_cron() {
    rm -f /etc/cron.d/psm-ddns
    log_ok "DDNS 定时任务已删除。"
}

# ── Auto cert via DNS ─────────────────────────────────────────────────────────
cf_auto_cert() {
    local domain; ask domain "域名（支持通配符，例如 *.example.com）"
    local token; token=$(state_get "cf_api_token")
    [[ -z "$token" ]] && { cf_setup_api; token=$(state_get "cf_api_token"); }

    export CF_Token="$token"
    export PATH="$ACME_HOME:$PATH"

    "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$domain" \
        && "$ACME_HOME/acme.sh" --install-cert -d "${domain#\*.}" \
            --fullchain-file "$NGINX_SSL_DIR/${domain#\*.}/fullchain.pem" \
            --key-file       "$NGINX_SSL_DIR/${domain#\*.}/privkey.pem" \
            --reloadcmd      "systemctl reload nginx" \
        && log_ok "通配符证书已签发并安装：$domain" \
        || log_error "证书签发失败。"
}

# ── Show saved config ─────────────────────────────────────────────────────────
cf_show_config() {
    echo -e "\n${BOLD}Cloudflare 配置：${NC}"
    local method;   method=$(state_get "cf_auth_method")
    local ddns;     ddns=$(state_get "ddns_domain")
    local interval; interval=$(state_get "ddns_interval")
    printf "  %-20s %s\n" "认证方式:"    "${method:-未设置}"
    printf "  %-20s %s\n" "DDNS 域名:"   "${ddns:-未设置}"
    printf "  %-20s %s\n" "DDNS 间隔:"   "${interval:+${interval} 分钟}${interval:-未设置}"
    printf "  %-20s %s\n" "上次 DDNS IP:" "$(state_get ddns_last_ip)"
    printf "  %-20s %s\n" "上次更新时间:" "$(state_get ddns_last_time)"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_cf_check_deps() {
    ensure_pkg_deps curl jq
}

# ── Menu ──────────────────────────────────────────────────────────────────────
cloudflare_menu() {
    _cf_check_deps
    while true; do
        show_menu "Cloudflare 管理" \
            "设置 API 凭据" \
            "列出 DNS 记录" \
            "添加 DNS 记录" \
            "删除 DNS 记录" \
            "DDNS：立即更新" \
            "DDNS：安装定时任务（5 分钟）" \
            "DDNS：删除定时任务" \
            "自动签发证书（DNS-01 通配符）" \
            "显示配置" \
            "Cloudflare Tunnel（免开端口暴露服务）" \
            "Cloudflare Access（管理面板前置门禁）"

        case "$MENU_CHOICE" in
            1) cf_setup_api ;;
            2) cf_list_dns ;;
            3) cf_add_dns ;;
            4) cf_delete_dns ;;
            5) cf_ddns_update ;;
            6) cf_ddns_install_cron ;;
            7) cf_ddns_remove_cron ;;
            8) cf_auto_cert ;;
            9) cf_show_config ;;
            10) source "$(dirname "${BASH_SOURCE[0]}")/cloudflare/tunnel.sh"; cft_menu ;;
            11) source "$(dirname "${BASH_SOURCE[0]}")/cloudflare/access.sh"; cfa_menu ;;
            0) return ;;
        esac
        press_enter
    done
}
