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

# Why the last tg_send did not get through (Telegram's own description, or
# curl's when Telegram did not answer); empty when it did.
TG_SEND_ERROR=""

_tg_post() {   # <chat_id> <text> [parse_mode] → Telegram's answer (or curl's error)
    local args=(-sS --max-time 10 "https://api.telegram.org/bot${_TG_NOTIFY_TOKEN}/sendMessage"
        -d "chat_id=$1" -d "disable_web_page_preview=true" --data-urlencode "text=$2")
    [[ -n "${3:-}" ]] && args+=(-d "parse_mode=$3")
    curl "${args[@]}" 2>&1 || true
}
# not `jq -e`: jq 1.6 (Debian 12, Ubuntu 22.04) exits 0 on an empty answer
_tg_ok() { [[ "$(jq -r '.ok' 2>/dev/null <<<"$1")" == true ]]; }
_tg_desc() {
    local d; d=$(jq -r '.description // empty' 2>/dev/null <<<"$1") || d=""
    [[ -n "$d" ]] || d=$(head -n1 <<<"$1")
    printf '%s' "${d:-no answer from api.telegram.org}"
}

# Send a Markdown message to a Telegram chat_id; the outcome is in TG_SEND_ERROR.
# Returns 0 even on failure so callers never abort on a notification error.
tg_send() {
    local chat_id="$1" text="$2" resp
    TG_SEND_ERROR=""
    _tg_load_token || { TG_SEND_ERROR="no bot token in $_TG_NOTIFY_CFG"; return 0; }
    resp=$(_tg_post "$chat_id" "$text" Markdown)
    # An unpaired _ or * in a name (a node tag, a hostname) makes Telegram
    # refuse the whole Markdown message; as plain text it still gets there.
    if ! _tg_ok "$resp" && [[ "$(_tg_desc "$resp")" == *"can't parse entities"* ]]; then
        resp=$(_tg_post "$chat_id" "$text")
    fi
    _tg_ok "$resp" || TG_SEND_ERROR=$(_tg_desc "$resp")
    return 0
}

# The admins' Telegram IDs (TG_ADMIN_IDS, comma-separated). Empty when the bot
# runs with "everyone is an admin": then pushed messages have no recipient.
tg_admin_ids() {
    [[ -n "$_TG_NOTIFY_ADMIN_IDS" ]] || \
        _TG_NOTIFY_ADMIN_IDS=$(. "$_TG_NOTIFY_CFG" 2>/dev/null && echo "${TG_ADMIN_IDS:-${TG_ALLOWED_IDS:-}}")
    local ids="${_TG_NOTIFY_ADMIN_IDS// /}"
    [[ -n "${ids//,/}" ]] && printf '%s' "$ids"
    return 0
}

# How the last tg_notify_admins went: how many admins got the message, and
# "ID: reason" for each one who did not.
TG_NOTIFY_SENT=0
TG_NOTIFY_ERRORS=()

# Broadcast a Markdown message to every configured admin (TG_ADMIN_IDS).
# Does nothing if no admins are configured — never aborts the caller.
tg_notify_admins() {
    local text="$1" aid
    TG_NOTIFY_SENT=0
    TG_NOTIFY_ERRORS=()
    IFS=',' read -ra _aids <<< "$(tg_admin_ids)"
    for aid in "${_aids[@]}"; do
        [[ -n "$aid" ]] || continue
        tg_send "$aid" "$text"
        if [[ -z "$TG_SEND_ERROR" ]]; then
            TG_NOTIFY_SENT=$(( TG_NOTIFY_SENT + 1 ))
        else
            TG_NOTIFY_ERRORS+=("$aid: $TG_SEND_ERROR")
        fi
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
    tg_send "$uid" "$(t tgbot.notify.traffic_warn "$port" "$pct" "$used_h" "$limit_h")"
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
    tg_send "$uid" "$(t tgbot.notify.traffic_paused "$port" "$used_h" "$limit_h")"
}
