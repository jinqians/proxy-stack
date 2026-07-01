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
    declare -f _cft_ensure_account_id &>/dev/null || { log_error "无法加载 Cloudflare Tunnel 模块（Access 复用它的 Account ID）"; return 1; }
    _cft_ensure_account_id || return 1
    _cft_load_cfg

    local app_id; app_id=$(_cfa_get_app_id "$hostname")
    if [[ -n "$app_id" ]]; then
        log_info "${hostname} 已经配置了 Cloudflare Access（Application ID: ${app_id}）"
        ask_yn "是否重新设置允许访问的邮箱/域名？" Y || return 0
    else
        log_step "正在为 ${hostname} 创建 Access Application..."
        local resp
        resp=$(_cf_curl -X POST "$CF_API/accounts/${CF_ACCOUNT_ID}/access/apps" \
            -d "{\"type\":\"self_hosted\",\"domain\":\"${hostname}\",\"name\":\"PSM - ${hostname}\",\"session_duration\":\"24h\"}")
        if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
            log_error "创建 Access Application 失败：$(echo "$resp" | jq -r '.errors[0].message // "未知错误"')"
            return 1
        fi
        app_id=$(echo "$resp" | jq -r '.result.id')
        _cfa_save_app "$hostname" "$app_id"
        log_ok "Access Application 已创建"
    fi

    echo ""
    echo "  谁可以访问 ${hostname}？"
    echo "    1. 指定邮箱地址（可多个，逗号分隔）"
    echo "    2. 整个邮箱域名（例如允许 @example.com 的所有人）"
    local choice; read -rp "$(echo -e "${CYAN}选择 [1]: ${NC}")" choice
    local include_json
    case "${choice:-1}" in
        2)
            local domain; ask domain "允许的邮箱域名（例如 example.com）"
            [[ -z "$domain" ]] && { log_error "域名不能为空"; return 1; }
            include_json=$(jq -n --arg d "$domain" '[{"email_domain":{"domain":$d}}]')
            ;;
        *)
            local emails; ask emails "允许的邮箱地址（多个用逗号分隔）"
            [[ -z "$emails" ]] && { log_error "邮箱不能为空"; return 1; }
            include_json=$(echo "$emails" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | grep -v '^$' | jq -R '{"email":{"email":.}}' | jq -sc '.')
            ;;
    esac

    local resp; resp=$(_cf_curl -X POST "$CF_API/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies" \
        -d "{\"name\":\"psm-allow\",\"decision\":\"allow\",\"include\":${include_json}}")
    if [[ "$(echo "$resp" | jq -r '.success')" == "true" ]]; then
        log_ok "访问策略已生效：只有符合条件的邮箱通过 Cloudflare 验证后，才能打开 https://${hostname}"
    else
        log_error "策略配置失败：$(echo "$resp" | jq -r '.errors[0].message // "未知错误"')"
        return 1
    fi
}

cfa_remove() {
    local hostname="$1"
    _cft_load_cfg
    local app_id; app_id=$(_cfa_get_app_id "$hostname")
    [[ -z "$app_id" ]] && { log_warn "${hostname} 没有配置 Access 保护"; return 0; }
    ask_yn "确认移除 ${hostname} 的 Access 保护？（移除后任何人都能直接打开这个地址）" N || return 0
    _cf_curl -X DELETE "$CF_API/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}" >/dev/null
    _cfa_remove_saved "$hostname"
    log_ok "已移除 Access 保护"
}

cfa_list() {
    _cfa_init
    echo -e "\n${BOLD}${BLUE}══ Cloudflare Access 保护列表 ══════════════${NC}"
    local count; count=$(jq 'length' "$CFA_APPS_FILE" 2>/dev/null || echo 0)
    if (( count == 0 )); then
        echo -e "  ${YELLOW}尚未配置任何 Access 保护${NC}"
    else
        jq -r '.[] | "  \(.hostname)"' "$CFA_APPS_FILE"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
cfa_menu() {
    while true; do
        cfa_list
        show_menu "Cloudflare Access（管理面板前置门禁）" \
            "为域名添加 / 更新 Access 保护" \
            "移除 Access 保护"

        case "$MENU_CHOICE" in
            1)
                local h; ask h "要保护的域名（需已通过 Cloudflare 代理，例如已用 Tunnel 暴露的域名）"
                cfa_protect "$h"
                press_enter ;;
            2)
                local h; ask h "要移除保护的域名"
                cfa_remove "$h"
                press_enter ;;
            0) return ;;
        esac
    done
}
