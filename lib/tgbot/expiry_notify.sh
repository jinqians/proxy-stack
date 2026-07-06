#!/usr/bin/env bash
# tgbot/expiry_notify.sh — Expiry reminder Telegram notification templates
# Depends on tgbot/notify.sh (tg_send, tg_uid_for_port).

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

source "$(dirname "${BASH_SOURCE[0]}")/notify.sh" 2>/dev/null || true

# Warn tenant that their node is expiring in <days> days.
# Usage: tg_notify_expiry_warn <port> <expires_hkt> <days>
tg_notify_expiry_warn() {
    local port="$1" exp_str="$2" days="$3"
    local uid; uid=$(tg_uid_for_port "$port")
    [[ -z "$uid" ]] && return 0
    local header
    case "$days" in
        1) header="$(t tgbot.expiry.header_1d)" ;;
        3) header="$(t tgbot.expiry.header_3d)" ;;
        *) header="$(t tgbot.expiry.header_default)" ;;
    esac
    tg_send "$uid" "$(t tgbot.expiry.warn "$header" "$port" "$days" "$exp_str")"
}

# Notify tenant that their node has expired and been paused.
# Usage: tg_notify_expiry_expired <port> <expires_hkt>
tg_notify_expiry_expired() {
    local port="$1" exp_str="$2"
    local uid; uid=$(tg_uid_for_port "$port")
    [[ -z "$uid" ]] && return 0
    tg_send "$uid" "$(t tgbot.expiry.expired "$port" "$exp_str")"
}

# Notify tenant that admin has renewed their node.
# Usage: tg_notify_expiry_renewed <port> <new_expires_hkt>
tg_notify_expiry_renewed() {
    local port="$1" new_exp="$2"
    local uid; uid=$(tg_uid_for_port "$port")
    [[ -z "$uid" ]] && return 0
    tg_send "$uid" "$(t tgbot.expiry.renewed "$port" "$new_exp")"
}
