#!/usr/bin/env bash
# cloudflare/access.sh — Cloudflare Access: require a Cloudflare-verified
# identity (email OTP / SSO) before a request ever reaches the origin — a
# login gate in front of management UIs (Portainer, Nginx Proxy Manager,
# etc.) whose own built-in login is otherwise the only thing standing
# between the public internet and root-equivalent control of the box.
#
# Independent of how the hostname is proxied — works the same whether it's
# fronted by Cloudflare Tunnel or a plain Cloudflare-proxied DNS record.
# Reuses the Account ID already collected for Tunnel (cloudflare/tunnel.sh)
# and the API token from cloudflare.sh; no new credentials needed.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../cloudflare.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tunnel.sh" 2>/dev/null || true

CFA_CFG_DIR="$CFG_DIR/cloudflare"
CFA_APPS_FILE="$CFA_CFG_DIR/access_apps.json"

_cfa_init() {
    mkdir -p "$CFA_CFG_DIR"
    [[ -f "$CFA_APPS_FILE" ]] || echo '[]' > "$CFA_APPS_FILE"
}

_cfa_save_app() {
    local hostname="$1" app_id="$2"
    _cfa_init
    local tmp; tmp=$(mktemp)
    jq --arg h "$hostname" --arg id "$app_id" \
        '[.[] | select(.hostname != $h)] + [{"hostname":$h,"app_id":$id}]' \
        "$CFA_APPS_FILE" > "$tmp" && mv "$tmp" "$CFA_APPS_FILE"
}

_cfa_get_app_id() {
    local hostname="$1"
    _cfa_init
    jq -r --arg h "$hostname" '.[] | select(.hostname == $h) | .app_id' "$CFA_APPS_FILE" 2>/dev/null
}

_cfa_remove_saved() {
    local hostname="$1"
    _cfa_init
    local tmp; tmp=$(mktemp)
    jq --arg h "$hostname" '[.[] | select(.hostname != $h)]' "$CFA_APPS_FILE" > "$tmp" && mv "$tmp" "$CFA_APPS_FILE"
}

# ── Protect / unprotect a hostname ────────────────────────────────────────────
# Usage: cfa_protect <hostname>
cfa_protect() {
    local hostname="$1"
    declare -f _cft_ensure_account_id &>/dev/null || { log_error "$(t cf.access.load_tunnel_failed)"; return 1; }
    _cft_ensure_account_id || return 1
    _cft_load_cfg

    local app_id; app_id=$(_cfa_get_app_id "$hostname")
    if [[ -n "$app_id" ]]; then
        log_info "$(t cf.access.already_configured "$hostname" "$app_id")"
        ask_yn "$(t cf.access.ask_reset)" Y || return 0
    else
        log_step "$(t cf.access.creating "$hostname")"
        local resp
        resp=$(_cf_curl -X POST "$CF_API/accounts/${CF_ACCOUNT_ID}/access/apps" \
            -d "{\"type\":\"self_hosted\",\"domain\":\"${hostname}\",\"name\":\"PSM - ${hostname}\",\"session_duration\":\"24h\"}")
        if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
            log_error "$(t cf.access.create_failed "$(echo "$resp" | jq -r ".errors[0].message // \"$(t cf.access.unknown_error)\"")")"
            return 1
        fi
        app_id=$(echo "$resp" | jq -r '.result.id')
        _cfa_save_app "$hostname" "$app_id"
        log_ok "$(t cf.access.created)"
    fi

    echo ""
    echo "$(t cf.access.who_can_access "$hostname")"
    echo "$(t cf.access.choice_email)"
    echo "$(t cf.access.choice_domain)"
    local choice; read -rp "$(echo -e "${CYAN}$(t cf.access.select)${NC}")" choice
    local include_json
    case "${choice:-1}" in
        2)
            local domain; ask domain "$(t cf.access.ask_allowed_domain)"
            [[ -z "$domain" ]] && { log_error "$(t cf.access.domain_required)"; return 1; }
            include_json=$(jq -n --arg d "$domain" '[{"email_domain":{"domain":$d}}]')
            ;;
        *)
            local emails; ask emails "$(t cf.access.ask_allowed_emails)"
            [[ -z "$emails" ]] && { log_error "$(t cf.access.email_required)"; return 1; }
            include_json=$(echo "$emails" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | grep -v '^$' | jq -R '{"email":{"email":.}}' | jq -sc '.')
            ;;
    esac

    local resp; resp=$(_cf_curl -X POST "$CF_API/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies" \
        -d "{\"name\":\"psm-allow\",\"decision\":\"allow\",\"include\":${include_json}}")
    if [[ "$(echo "$resp" | jq -r '.success')" == "true" ]]; then
        log_ok "$(t cf.access.policy_ok "$hostname")"
    else
        log_error "$(t cf.access.policy_failed "$(echo "$resp" | jq -r ".errors[0].message // \"$(t cf.access.unknown_error)\"")")"
        return 1
    fi
}

cfa_remove() {
    local hostname="$1"
    _cft_load_cfg
    local app_id; app_id=$(_cfa_get_app_id "$hostname")
    [[ -z "$app_id" ]] && { log_warn "$(t cf.access.no_protection "$hostname")"; return 0; }
    ask_yn "$(t cf.access.ask_remove "$hostname")" N || return 0
    _cf_curl -X DELETE "$CF_API/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}" >/dev/null
    _cfa_remove_saved "$hostname"
    log_ok "$(t cf.access.removed)"
}

cfa_list() {
    _cfa_init
    echo -e "\n${BOLD}${BLUE}$(t cf.access.list_title)${NC}"
    local count; count=$(jq 'length' "$CFA_APPS_FILE" 2>/dev/null || echo 0)
    if (( count == 0 )); then
        echo -e "  ${YELLOW}$(t cf.access.list_empty)${NC}"
    else
        jq -r '.[] | "  \(.hostname)"' "$CFA_APPS_FILE"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
cfa_menu() {
    while true; do
        cfa_list
        show_menu "$(t cf.access.menu.title)" \
            "$(t cf.access.menu.add)" \
            "$(t cf.access.menu.remove)"

        case "$MENU_CHOICE" in
            1)
                local h; ask h "$(t cf.access.ask_protect_host)"
                cfa_protect "$h"
                press_enter ;;
            2)
                local h; ask h "$(t cf.access.ask_remove_host)"
                cfa_remove "$h"
                press_enter ;;
            0) return ;;
        esac
    done
}
