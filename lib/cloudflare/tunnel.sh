#!/usr/bin/env bash
# cloudflare/tunnel.sh — Cloudflare Tunnel: expose a local service (Docker app,
# admin panel, anything on 127.0.0.1) to the internet without opening any
# inbound port — cloudflared makes an outbound-only connection to Cloudflare's
# edge. One tunnel per server is enough; each exposed hostname is just another
# ingress rule on that same tunnel.
#
# Reuses the API token already configured via cloudflare.sh's cf_setup_api()
# (state_get cf_api_token / _cf_curl) — does not touch cloudflare.sh. Only the
# Cloudflare Account ID (a Tunnel-specific credential the DNS/DDNS flows never
# needed) is stored here, in its own config file.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../cloudflare.sh"

CFT_CFG_DIR="$CFG_DIR/cloudflare"
CFT_CFG="$CFT_CFG_DIR/tunnel.conf"
CFT_BIN="/usr/local/bin/cloudflared"

_cft_load_cfg() {
    CF_ACCOUNT_ID=""
    CFT_TUNNEL_ID=""
    CFT_TUNNEL_NAME=""
    # shellcheck source=/dev/null
    [[ -f "$CFT_CFG" ]] && source "$CFT_CFG"
}

_cft_save_cfg() {
    mkdir -p "$CFT_CFG_DIR"
    cat > "$CFT_CFG" <<EOF
CF_ACCOUNT_ID="${CF_ACCOUNT_ID}"
CFT_TUNNEL_ID="${CFT_TUNNEL_ID}"
CFT_TUNNEL_NAME="${CFT_TUNNEL_NAME}"
EOF
}

_cft_ensure_account_id() {
    _cft_load_cfg
    [[ -n "$CF_ACCOUNT_ID" ]] && return 0
    echo -e "${YELLOW}$(t cf.tunnel.need_account_id_1)${NC}"
    echo -e "${YELLOW}$(t cf.tunnel.need_account_id_2)${NC}"
    ask CF_ACCOUNT_ID "Cloudflare Account ID"
    [[ -z "$CF_ACCOUNT_ID" ]] && { log_error "$(t cf.tunnel.account_required)"; return 1; }
    _cft_save_cfg
}

_cft_install_binary() {
    command -v cloudflared &>/dev/null && return 0
    log_step "$(t cf.tunnel.installing)"
    local arch; arch=$(get_arch)
    local cf_arch
    case "$arch" in
        amd64) cf_arch="amd64" ;;
        arm64) cf_arch="arm64" ;;
        arm32) cf_arch="arm" ;;
        *) log_error "$(t cf.tunnel.unsupported_arch "$arch")"; return 1 ;;
    esac
    curl -fsSL -o "$CFT_BIN" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
        || { log_error "$(t cf.tunnel.download_failed)"; return 1; }
    chmod +x "$CFT_BIN"
    log_ok "$(t cf.tunnel.installed "$("$CFT_BIN" --version 2>/dev/null | head -1)")"
}

# Creates the (single, per-server) tunnel on first use; no-ops if one already exists.
_cft_ensure_tunnel() {
    _cft_load_cfg
    [[ -n "$CFT_TUNNEL_ID" ]] && return 0

    local token; token=$(state_get "cf_api_token")
    [[ -z "$token" ]] && { log_error "$(t cf.tunnel.need_token)"; return 1; }

    _cft_ensure_account_id || return 1
    _cft_install_binary || return 1

    local name; ask name "$(t cf.tunnel.ask_name)" "psm-$(hostname -s 2>/dev/null || echo tunnel)"
    log_step "$(t cf.tunnel.creating)"
    local resp
    resp=$(_cf_curl -X POST "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        -d "{\"name\":\"${name}\",\"config_src\":\"cloudflare\"}")
    if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
        local err; err=$(echo "$resp" | jq -r '.errors[0].message // empty')
        log_error "$(t cf.tunnel.create_failed "${err:-$(t cf.access.unknown_error)}")"
        return 1
    fi

    CFT_TUNNEL_ID=$(echo "$resp" | jq -r '.result.id')
    CFT_TUNNEL_NAME="$name"
    local tunnel_token; tunnel_token=$(echo "$resp" | jq -r '.result.token')
    _cft_save_cfg

    log_step "$(t cf.tunnel.installing_service)"
    if "$CFT_BIN" service install "$tunnel_token"; then
        log_ok "$(t cf.tunnel.created_started "$name" "$CFT_TUNNEL_ID")"
    else
        log_error "$(t cf.tunnel.service_failed)"
        return 1
    fi
}

# ── Ingress (hostname → local service) management ─────────────────────────────
_cft_get_ingress() {
    _cf_curl "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CFT_TUNNEL_ID}/configurations" \
        | jq -c '.result.config.ingress // []'
}

_cft_put_ingress() {
    _cf_curl -X PUT "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CFT_TUNNEL_ID}/configurations" \
        -d "{\"config\":{\"ingress\":${1}}}"
}

# Add (or replace) a hostname → local service rule, plus the matching DNS
# CNAME. Applies live — cloudflared picks up remotely-managed config changes
# over its existing connection, no restart needed.
# Usage: cft_add_ingress <hostname> <local_bind:local_port>
cft_add_ingress() {
    local hostname="$1" target="$2"
    _cft_ensure_tunnel || return 1
    _cft_load_cfg

    local current; current=$(_cft_get_ingress)
    # Drop any existing rule for this hostname and the trailing catch-all,
    # then re-append hostname rule + catch-all so it always stays last.
    local updated; updated=$(echo "$current" | jq -c \
        --arg h "$hostname" --arg svc "http://${target}" '
        [.[] | select((.hostname // "") != $h and (.service // "") != "http_status:404")]
        + [{"hostname":$h,"service":$svc}]
        + [{"service":"http_status:404"}]')

    local resp; resp=$(_cft_put_ingress "$updated")
    if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
        local err; err=$(echo "$resp" | jq -r '.errors[0].message // empty')
        log_error "$(t cf.tunnel.ingress_write_failed "${err:-$(t cf.access.unknown_error)}")"
        return 1
    fi

    local zone_id; zone_id=$(cf_get_zone_id "$hostname")
    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        log_error "$(t cf.tunnel.zone_not_found_host "$hostname")"
        return 1
    fi
    local dns_resp; dns_resp=$(_cf_curl -X POST "$CF_API/zones/${zone_id}/dns_records" \
        -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${CFT_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}")
    if [[ "$(echo "$dns_resp" | jq -r '.success')" != "true" ]]; then
        local dns_err; dns_err=$(echo "$dns_resp" | jq -r '.errors[0].message // empty')
        log_warn "$(t cf.tunnel.dns_record_warn "${dns_err:-$(t cf.tunnel.dns_create_failed)}")"
    fi

    log_ok "$(t cf.tunnel.exposed "$hostname" "$target")"
    log_info "$(t cf.tunnel.no_open_port)"
}

cft_remove_ingress() {
    local hostname="$1"
    _cft_load_cfg
    [[ -z "$CFT_TUNNEL_ID" ]] && { log_warn "$(t cf.tunnel.not_created)"; return 0; }

    local current; current=$(_cft_get_ingress)
    local updated; updated=$(echo "$current" | jq -c --arg h "$hostname" \
        '[.[] | select((.hostname // "") != $h)]')
    _cft_put_ingress "$updated" >/dev/null

    local zone_id; zone_id=$(cf_get_zone_id "$hostname")
    if [[ -n "$zone_id" && "$zone_id" != "null" ]]; then
        local rec_id; rec_id=$(_cf_curl "$CF_API/zones/${zone_id}/dns_records?type=CNAME&name=${hostname}" \
            | jq -r '.result[0].id // empty')
        [[ -n "$rec_id" ]] && _cf_curl -X DELETE "$CF_API/zones/${zone_id}/dns_records/${rec_id}" >/dev/null
    fi
    log_ok "$(t cf.tunnel.removed "$hostname")"
}

cft_list_ingress() {
    _cft_load_cfg
    [[ -z "$CFT_TUNNEL_ID" ]] && return 0
    echo -e "  ${BOLD}$(t cf.tunnel.ingress_title)${NC}"
    local rules; rules=$(_cft_get_ingress | jq -r '.[] | select(.hostname) | "  \(.hostname)  →  \(.service)"')
    [[ -n "$rules" ]] && echo "$rules" || echo "    $(t cf.tunnel.ingress_empty)"
}

# ── Status / menu ─────────────────────────────────────────────────────────────
cft_status() {
    _cft_load_cfg
    echo -e "\n${BOLD}${BLUE}$(t cf.tunnel.status_title)${NC}"
    if [[ -z "$CFT_TUNNEL_ID" ]]; then
        echo -e "  ${YELLOW}$(t cf.tunnel.not_created)${NC}"
    else
        echo -e "  $(t cf.tunnel.status_name "$CFT_TUNNEL_NAME")"
        echo -e "  $(t cf.tunnel.status_id "$CFT_TUNNEL_ID")"
        if systemctl is-active --quiet cloudflared 2>/dev/null; then
            echo -e "  $(t cf.tunnel.service_status)${GREEN}$(t cf.tunnel.running)${NC}"
        else
            echo -e "  $(t cf.tunnel.service_status)${RED}$(t cf.tunnel.not_running)${NC}"
        fi
        cft_list_ingress
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

cft_uninstall() {
    _cft_load_cfg
    ask_yn "$(t cf.tunnel.ask_uninstall)" N || return 0
    systemctl stop cloudflared 2>/dev/null || true
    [[ -x "$CFT_BIN" ]] && "$CFT_BIN" service uninstall 2>/dev/null || true
    if [[ -n "$CFT_TUNNEL_ID" ]]; then
        _cf_curl -X DELETE "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CFT_TUNNEL_ID}" >/dev/null
    fi
    rm -f "$CFT_CFG"
    log_ok "$(t cf.tunnel.uninstalled)"
}

cft_menu() {
    while true; do
        cft_status
        show_menu "$(t cf.tunnel.menu.title)" \
            "$(t cf.tunnel.menu.ensure)" \
            "$(t cf.tunnel.menu.add)" \
            "$(t cf.tunnel.menu.remove)" \
            "$(t cf.tunnel.menu.uninstall)"

        case "$MENU_CHOICE" in
            1) _cft_ensure_tunnel; press_enter ;;
            2)
                local h t
                ask h "$(t cf.tunnel.ask_host)"
                ask t "$(t cf.tunnel.ask_target)"
                cft_add_ingress "$h" "$t"
                press_enter ;;
            3)
                local h; ask h "$(t cf.tunnel.ask_remove_host)"
                cft_remove_ingress "$h"
                press_enter ;;
            4) cft_uninstall; press_enter ;;
            0) return ;;
        esac
    done
}
