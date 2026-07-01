#!/usr/bin/env bash
# tgbot/notify.sh — Lightweight Telegram notification helpers
# Sourceable by any lib module; does not depend on tg_bot.sh.

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

_TG_NOTIFY_CFG="${CFG_DIR}/tg_bot.conf"
_TG_BIND_TOKENS="${CFG_DIR}/bind_tokens.json"

# Cache the token/admin list in variables so we only read the file once per process.
_TG_NOTIFY_TOKEN=""
_TG_NOTIFY_ADMIN_IDS=""

_tg_load_token() {
    [[ -n "$_TG_NOTIFY_TOKEN" ]] && return 0
    [[ -f "$_TG_NOTIFY_CFG" ]] || return 1
    _TG_NOTIFY_TOKEN=$(. "$_TG_NOTIFY_CFG" 2>/dev/null && echo "${TG_BOT_TOKEN:-}")
    [[ -n "$_TG_NOTIFY_TOKEN" ]]
}

# Send a Markdown message to a Telegram chat_id.
# Returns 0 even on failure so callers never abort on a notification error.
tg_send() {
    local chat_id="$1" text="$2"
    _tg_load_token || return 0
    curl -fsSL --max-time 10 \
        "https://api.telegram.org/bot${_TG_NOTIFY_TOKEN}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=Markdown" \
        -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

# Broadcast a Markdown message to every configured admin (TG_ADMIN_IDS).
# Silently does nothing if no admins are configured — never aborts the caller.
tg_notify_admins() {
    local text="$1"
    [[ -n "$_TG_NOTIFY_ADMIN_IDS" ]] || \
        _TG_NOTIFY_ADMIN_IDS=$(. "$_TG_NOTIFY_CFG" 2>/dev/null && echo "${TG_ADMIN_IDS:-${TG_ALLOWED_IDS:-}}")
    local aid
    IFS=',' read -ra _aids <<< "$_TG_NOTIFY_ADMIN_IDS"
    for aid in "${_aids[@]}"; do
        aid="${aid// /}"
        [[ -n "$aid" ]] && tg_send "$aid" "$text"
    done
}

# Return the tenant Telegram UID bound to <port>, or empty string.
tg_uid_for_port() {
    local port="$1"
    [[ -f "$_TG_BIND_TOKENS" ]] || return 0
    local uid
    uid=$(jq -r --arg p "$port" '
        if (.[$p] | type) == "object" then .[$p].uid // empty
        else empty
        end' "$_TG_BIND_TOKENS" 2>/dev/null) || true
    [[ "$uid" == "null" ]] && uid=""
    printf '%s' "$uid"
}

# 90% traffic warning to the tenant bound to <port>.
# Usage: tg_notify_traffic_warn <port> <used_bytes> <limit_bytes>
tg_notify_traffic_warn() {
    local port="$1" used="$2" limit="$3"
    local uid; uid=$(tg_uid_for_port "$port")
    [[ -z "$uid" ]] && return 0
    local pct=$(( used * 100 / limit ))
    local used_h limit_h
    used_h=$(declare -f _fmt_bytes &>/dev/null && _fmt_bytes "$used" || echo "${used} B")
    limit_h=$(declare -f _fmt_bytes &>/dev/null && _fmt_bytes "$limit" || echo "${limit} B")
    tg_send "$uid" "$(printf \
'⚠️ *流量预警*

您的节点（端口 `%s`）流量已用 *%d%%*
📊 已用：%s　／　上限：%s

请及时联系管理员续费，避免服务中断。' \
        "$port" "$pct" "$used_h" "$limit_h")"
}

# Service-paused notification to the tenant bound to <port>.
# Usage: tg_notify_traffic_paused <port> <used_bytes> <limit_bytes>
tg_notify_traffic_paused() {
    local port="$1" used="$2" limit="$3"
    local uid; uid=$(tg_uid_for_port "$port")
    [[ -z "$uid" ]] && return 0
    local used_h limit_h
    used_h=$(declare -f _fmt_bytes &>/dev/null && _fmt_bytes "$used" || echo "${used} B")
    limit_h=$(declare -f _fmt_bytes &>/dev/null && _fmt_bytes "$limit" || echo "${limit} B")
    tg_send "$uid" "$(printf \
'🚫 *服务已暂停*

您的节点（端口 `%s`）流量已耗尽
📊 已用：%s　／　上限：%s

请联系管理员重置配额后方可恢复使用。' \
        "$port" "$used_h" "$limit_h")"
}
