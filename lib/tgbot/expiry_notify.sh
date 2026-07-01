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
        1) header="🔴 *紧急到期提醒*" ;;
        3) header="🟡 *节点临期提醒*" ;;
        *) header="🟢 *节点到期提醒*" ;;
    esac
    tg_send "$uid" "$(printf \
'%s

您的节点（端口 `%s`）将在 *%d 天后* 到期
🕐 到期时间（香港）：`%s`

请及时联系管理员续费，避免服务中断。' \
        "$header" "$port" "$days" "$exp_str")"
}

# Notify tenant that their node has expired and been paused.
# Usage: tg_notify_expiry_expired <port> <expires_hkt>
tg_notify_expiry_expired() {
    local port="$1" exp_str="$2"
    local uid; uid=$(tg_uid_for_port "$port")
    [[ -z "$uid" ]] && return 0
    tg_send "$uid" "$(printf \
'🚫 *节点已到期暂停*

您的节点（端口 `%s`）已于 `%s`（香港时间）到期，服务已自动暂停。

请联系管理员续费后方可恢复使用。' \
        "$port" "$exp_str")"
}

# Notify tenant that admin has renewed their node.
# Usage: tg_notify_expiry_renewed <port> <new_expires_hkt>
tg_notify_expiry_renewed() {
    local port="$1" new_exp="$2"
    local uid; uid=$(tg_uid_for_port "$port")
    [[ -z "$uid" ]] && return 0
    tg_send "$uid" "$(printf \
'✅ *续期成功*

您的节点（端口 `%s`）已成功续期。
📅 新到期时间（香港）：`%s`

感谢您的使用！' \
        "$port" "$new_exp")"
}
