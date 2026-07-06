#!/usr/bin/env bash
# cloudflare.sh — Cloudflare DNS, DDNS, API management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CF_API="https://api.cloudflare.com/client/v4"

# ── API credentials ───────────────────────────────────────────────────────────
cf_setup_api() {
    echo -e "$(t cf.auth.menu)"
    read -rp "$(echo -e "${CYAN}$(t cf.auth.select)${NC}")" am

    local cf_email="" cf_token="" cf_key=""
    if [[ "${am:-1}" == "2" ]]; then
        ask cf_email "$(t cf.auth.ask_email)"
        ask cf_key   "Global API Key"
        state_set "cf_auth_method" "apikey"
        state_set "cf_email"       "$cf_email"
        state_set "cf_global_key"  "$cf_key"
    else
        ask cf_token "$(t cf.auth.ask_token)"
        state_set "cf_auth_method" "token"
        state_set "cf_api_token"   "$cf_token"
    fi
    log_ok "$(t cf.auth.saved)"
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
    local domain; ask domain "$(t cf.ask_domain_example)"
    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "$(t cf.zone.not_found)"; return 1; }
    _cf_curl "$CF_API/zones/$zone_id/dns_records?per_page=100" \
        | jq -r '.result[] | "\(.id)\t\(.type)\t\(.name)\t\(.content)\tproxied:\(.proxied)"' 2>/dev/null \
        | column -t
}

cf_add_dns() {
    local domain type name content proxied ttl
    ask domain  "$(t cf.ask_root_domain)"
    ask type    "$(t cf.ask_record_type)" "A"
    ask name    "$(t cf.ask_record_name)"
    ask content "$(t cf.ask_record_content)"
    ask_yn "$(t cf.ask_proxied)" N && proxied="true" || proxied="false"
    ask ttl "$(t cf.ask_ttl)" "1"

    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "$(t cf.zone.not_found)"; return 1; }

    local full_name; [[ "$name" == "@" ]] && full_name="$domain" || full_name="${name}.${domain}"

    local result
    result=$(_cf_curl -X POST "$CF_API/zones/$zone_id/dns_records" \
        -d "{\"type\":\"$type\",\"name\":\"$full_name\",\"content\":\"$content\",\"ttl\":$ttl,\"proxied\":$proxied}")
    if [[ "$(echo "$result" | jq -r '.success')" == "true" ]]; then
        echo "$(t cf.record.created "$(echo "$result" | jq -r '.result.id')")"
    else
        echo "$(t cf.error "$(echo "$result" | jq -r '.errors[0].message // empty')")"
    fi
}

cf_delete_dns() {
    local domain; ask domain "$(t cf.ask_root_domain)"
    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "$(t cf.zone.not_found)"; return 1; }

    cf_list_dns <<< "$domain" 2>/dev/null || true
    local record_id; ask record_id "$(t cf.ask_record_id_delete)"
    local result
    result=$(_cf_curl -X DELETE "$CF_API/zones/$zone_id/dns_records/$record_id")
    if [[ "$(echo "$result" | jq -r '.success')" == "true" ]]; then
        echo "$(t cf.record.deleted)"
    else
        echo "$(t cf.error "$(echo "$result" | jq -r '.errors[0].message // empty')")"
    fi
}

# ── DDNS ──────────────────────────────────────────────────────────────────────
cf_ddns_update() {
    local domain; domain=$(state_get "ddns_domain")
    [[ -z "$domain" ]] && ask domain "$(t cf.ddns.ask_domain)"

    local zone_id; zone_id=$(cf_get_zone_id "$domain")
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { log_error "$(t cf.zone.not_found_domain "$domain")"; return 1; }

    local current_ip; current_ip=$(get_ipv4)
    [[ -z "$current_ip" ]] && { log_error "$(t cf.ddns.public_ip_failed)"; return 1; }

    # Find existing A record
    local record; record=$(_cf_curl "$CF_API/zones/$zone_id/dns_records?type=A&name=$domain")
    local record_id; record_id=$(echo "$record" | jq -r '.result[0].id')
    local old_ip;    old_ip=$(echo "$record"    | jq -r '.result[0].content')

    if [[ "$current_ip" == "$old_ip" ]]; then
        log_info "$(t cf.ddns.no_change "$current_ip")"
        return 0
    fi

    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        # Create new record
        local result
        result=$(_cf_curl -X POST "$CF_API/zones/$zone_id/dns_records" \
            -d "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$current_ip\",\"ttl\":60,\"proxied\":false}")
        if [[ "$(echo "$result" | jq -r '.success')" == "true" ]]; then
            echo "$(t cf.ddns.created "$(echo "$result" | jq -r '.result.content')")"
        else
            echo "$result" | jq -r '.errors'
        fi
    else
        # Update existing
        local result
        result=$(_cf_curl -X PATCH "$CF_API/zones/$zone_id/dns_records/$record_id" \
            -d "{\"content\":\"$current_ip\"}")
        if [[ "$(echo "$result" | jq -r '.success')" == "true" ]]; then
            echo "$(t cf.ddns.updated "$(echo "$result" | jq -r '.result.content')")"
        else
            echo "$result" | jq -r '.errors'
        fi
    fi

    state_set "ddns_domain"    "$domain"
    state_set "ddns_last_ip"   "$current_ip"
    state_set "ddns_last_time" "$(date '+%Y-%m-%d %H:%M:%S')"
}

cf_ddns_install_cron() {
    local domain; ask domain "$(t cf.ddns.ask_domain)"
    state_set "ddns_domain" "$domain"

    local interval
    ask interval "$(t cf.ddns.ask_interval)" "5"
    [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 60 )) \
        || { log_error "$(t cf.ddns.invalid_interval)"; return 1; }

    local cron_expr
    if (( interval == 60 )); then
        cron_expr="0 * * * *"
    else
        cron_expr="*/${interval} * * * *"
    fi

    ensure_cron || true   # RHEL 系最小安装没有 cronie，/etc/cron.d 会被无声忽略
    echo "${cron_expr} root ${PSM_ROOT}/manager.sh --ddns-update >> /var/log/psm-ddns.log 2>&1" \
        > /etc/cron.d/psm-ddns
    state_set "ddns_interval" "$interval"
    log_ok "$(t cf.ddns.cron_installed "$interval" "$domain")"
}

cf_ddns_remove_cron() {
    rm -f /etc/cron.d/psm-ddns
    log_ok "$(t cf.ddns.cron_removed)"
}

# ── Auto cert via DNS ─────────────────────────────────────────────────────────
cf_auto_cert() {
    local domain; ask domain "$(t cf.cert.ask_domain_wildcard)"
    local token; token=$(state_get "cf_api_token")
    [[ -z "$token" ]] && { cf_setup_api; token=$(state_get "cf_api_token"); }

    export CF_Token="$token"
    export PATH="$ACME_HOME:$PATH"

    "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$domain" \
        && "$ACME_HOME/acme.sh" --install-cert -d "${domain#\*.}" \
            --fullchain-file "$NGINX_SSL_DIR/${domain#\*.}/fullchain.pem" \
            --key-file       "$NGINX_SSL_DIR/${domain#\*.}/privkey.pem" \
            --reloadcmd      "systemctl reload nginx" \
        && log_ok "$(t cf.cert.issued_installed "$domain")" \
        || log_error "$(t cf.cert.failed)"
}

# ── Show saved config ─────────────────────────────────────────────────────────
cf_show_config() {
    echo -e "\n${BOLD}$(t cf.config.title)${NC}"
    local method;   method=$(state_get "cf_auth_method")
    local ddns;     ddns=$(state_get "ddns_domain")
    local interval; interval=$(state_get "ddns_interval")
    local last_ip;  last_ip=$(state_get "ddns_last_ip")
    local last_time; last_time=$(state_get "ddns_last_time")
    local interval_display
    [[ -n "$interval" ]] && interval_display="$(t cf.config.minutes "$interval")" || interval_display="$(t cf.config.not_set)"
    printf "  %-20s %s\n" "$(t cf.config.auth_method)"    "${method:-$(t cf.config.not_set)}"
    printf "  %-20s %s\n" "$(t cf.config.ddns_domain)"   "${ddns:-$(t cf.config.not_set)}"
    printf "  %-20s %s\n" "$(t cf.config.ddns_interval)" "$interval_display"
    printf "  %-20s %s\n" "$(t cf.config.last_ip)" "${last_ip:-$(t cf.config.not_set)}"
    printf "  %-20s %s\n" "$(t cf.config.last_time)" "${last_time:-$(t cf.config.not_set)}"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_cf_check_deps() {
    ensure_pkg_deps curl jq
}

# ── Menu ──────────────────────────────────────────────────────────────────────
cloudflare_menu() {
    _cf_check_deps
    while true; do
        show_menu "$(t cf.menu.title)" \
            "$(t cf.menu.setup_api)" \
            "$(t cf.menu.list_dns)" \
            "$(t cf.menu.add_dns)" \
            "$(t cf.menu.delete_dns)" \
            "$(t cf.menu.ddns_update)" \
            "$(t cf.menu.ddns_install)" \
            "$(t cf.menu.ddns_remove)" \
            "$(t cf.menu.auto_cert)" \
            "$(t cf.menu.show_config)" \
            "$(t cf.menu.tunnel)" \
            "$(t cf.menu.access)"

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
