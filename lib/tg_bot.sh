#!/usr/bin/env bash
# tg_bot.sh — PSM Telegram Bot: traffic query via Telegram

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

# Expiry module (non-fatal if missing)
source "$(dirname "${BASH_SOURCE[0]}")/expiry/core.sh" 2>/dev/null || true

TG_BOT_CFG="${CFG_DIR}/tg_bot.conf"
TG_BOT_OFFSET="${CFG_DIR}/tg_bot.offset"
TG_BOT_SVC="/etc/systemd/system/psm-tgbot.service"
TG_API_BASE="https://api.telegram.org/bot"
TG_USERS_FILE="${CFG_DIR}/tg_users.json"      # tenant uid → port bindings
BIND_TOKENS_FILE="${CFG_DIR}/bind_tokens.json" # port → bind token

# ── Config helpers ─────────────────────────────────────────────────────────────
_tgbot_load_cfg() {
    [[ -f "$TG_BOT_CFG" ]] || { log_error "Telegram Bot 未配置，请先运行「配置 Telegram Bot」"; return 1; }
    # shellcheck source=/dev/null
    source "$TG_BOT_CFG"
    [[ -n "${TG_BOT_TOKEN:-}" ]] || { log_error "TG_BOT_TOKEN 未设置"; return 1; }
    # Backward compat: old configs used TG_ALLOWED_IDS for admins
    if [[ -z "${TG_ADMIN_IDS:-}" && -n "${TG_ALLOWED_IDS:-}" ]]; then
        TG_ADMIN_IDS="$TG_ALLOWED_IDS"
    fi
}

_tgbot_save_cfg() {
    mkdir -p "$CFG_DIR"
    cat > "$TG_BOT_CFG" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_ADMIN_IDS="${TG_ADMIN_IDS:-}"
EOF
    chmod 600 "$TG_BOT_CFG"
}

# ── Telegram API ───────────────────────────────────────────────────────────────
_tgbot_api() {
    local method="$1"; shift
    curl -fsSL --max-time 35 \
        "${TG_API_BASE}${TG_BOT_TOKEN}/${method}" "$@" 2>/dev/null
}

_tgbot_send() {
    local chat_id="$1" text="$2"
    _tgbot_api sendMessage \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=Markdown" \
        -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" >/dev/null
}

# Send a message with an inline keyboard.
# $3 = JSON string for reply_markup (inline_keyboard)
_tgbot_send_kb() {
    local chat_id="$1" text="$2" keyboard="$3"
    _tgbot_api sendMessage \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=Markdown" \
        -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" \
        --data-urlencode "reply_markup=${keyboard}" >/dev/null
}

# Acknowledge a callback_query (required; otherwise the button spins forever).
_tgbot_answer_cb() {
    _tgbot_api answerCallbackQuery \
        -d "callback_query_id=${1}" >/dev/null
}

# ── Inline keyboard layouts ────────────────────────────────────────────────────
_tgbot_kb_admin() {
    printf '%s' \
      '{"inline_keyboard":['\
        '[{"text":"📋 所有节点","callback_data":"admin:list"},'\
         '{"text":"👥 租客列表","callback_data":"admin:users"}],'\
        '[{"text":"ℹ️ 使用说明","callback_data":"admin:help"}]'\
      ']}'
}

_tgbot_kb_tenant() {
    printf '%s' \
      '{"inline_keyboard":['\
        '[{"text":"📊 查看我的流量","callback_data":"tenant:mytraffic"}],'\
        '[{"text":"🔄 刷新","callback_data":"tenant:mytraffic"}]'\
      ']}'
}

# ── Callback handler ───────────────────────────────────────────────────────────
_tgbot_handle_callback() {
    local cb_id="$1" chat_id="$2" user_id="$3" data="$4"
    _tgbot_answer_cb "$cb_id"   # must always ack

    if _tgbot_is_admin "$user_id"; then
        case "$data" in
            admin:list)
                _tgbot_send "$chat_id" "$(_tgbot_list_nodes)"
                ;;
            admin:users)
                _tgbot_cmd_users "$chat_id"
                ;;
            admin:help)
                _tgbot_send_kb "$chat_id" \
"ℹ️ *使用说明*  🔑 管理员
━━━━━━━━━━━━━━━━━━━━
*流量查询*
› 直接发送端口号
› \`/traffic <端口>\`
› \`/list\`  所有节点

*租客管理*
› \`/token <端口>\`  生成绑定码
› \`/bind <ID> <端口>\`  手动绑定
› \`/unbind <ID>\`  解绑
› \`/users\`  查看列表

*其他*
› \`/id\`  查看自己的 ID" \
                    "$(_tgbot_kb_admin)"
                ;;
        esac
        return
    fi

    local tenant_port; tenant_port=$(_tgbot_tenant_port "$user_id")
    if [[ -n "$tenant_port" ]]; then
        case "$data" in
            tenant:mytraffic)
                _tgbot_send_kb "$chat_id" \
                    "$(_tgbot_query_port "$tenant_port")" \
                    "$(_tgbot_kb_tenant)"
                ;;
        esac
    fi
}

# ── Bind-token helpers ────────────────────────────────────────────────────────
_tgbot_gen_token() {
    tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 12
}

_tgbot_port_token() {
    local port="$1"
    [[ -f "$BIND_TOKENS_FILE" ]] || return 0   # no file → no token configured (not an error)
    # Support both old string format and new object format
    local t; t=$(jq -r --arg p "$port" \
        'if (.[$p] | type) == "object" then .[$p].token else .[$p] end // empty' \
        "$BIND_TOKENS_FILE" 2>/dev/null) || true
    [[ -n "$t" ]] && printf '%s' "$t"
    return 0
}

_tgbot_set_token() {
    local port="$1" token="$2"
    [[ -f "$BIND_TOKENS_FILE" ]] || echo '{}' > "$BIND_TOKENS_FILE"
    local tmp; tmp=$(mktemp)
    jq --arg p "$port" --arg t "$token" \
        '.[$p] = {"token": $t, "uid": null, "bound_at": null}' \
        "$BIND_TOKENS_FILE" > "$tmp" && mv "$tmp" "$BIND_TOKENS_FILE"
}

_tgbot_record_token_uid() {
    local port="$1" uid="$2"
    [[ -f "$BIND_TOKENS_FILE" ]] || return 0
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp; tmp=$(mktemp)
    jq --arg p "$port" --arg u "$uid" --arg ts "$ts" \
        'if (.[$p] | type) == "object"
         then .[$p].uid = $u | .[$p].bound_at = $ts
         else .[$p] = {"token": .[$p], "uid": $u, "bound_at": $ts}
         end' \
        "$BIND_TOKENS_FILE" > "$tmp" && mv "$tmp" "$BIND_TOKENS_FILE"
}

# ── Formatting ─────────────────────────────────────────────────────────────────
_tgbot_fmt_bytes() {
    local b="${1:-0}"
    if   (( b >= 1099511627776 )); then
        printf "%d.%02d TB" $(( b / 1099511627776 )) \
               $(( (b % 1099511627776) * 100 / 1099511627776 ))
    elif (( b >= 1073741824 )); then
        printf "%d.%02d GB" $(( b / 1073741824 )) \
               $(( (b % 1073741824) * 100 / 1073741824 ))
    elif (( b >= 1048576 )); then
        printf "%d.%02d MB" $(( b / 1048576 )) \
               $(( (b % 1048576) * 100 / 1048576 ))
    else
        printf "%d B" "$b"
    fi
}

_tgbot_bar() {
    local used="$1" total="$2" width=12
    local pct=0; (( total > 0 )) && pct=$(( used * 100 / total ))
    (( pct > 100 )) && pct=100
    local filled=$(( pct * width / 100 )) empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty;  i++)); do bar+="░"; done
    printf "%s  %d%%" "$bar" "$pct"
}

_tgbot_next_reset() {
    local reset_day="$1" last_reset="$2"
    local cy cm cd
    cy=$(date +%Y); cm=$(date +%-m); cd=$(date +%-d)
    local cur_ym; cur_ym=$(date +%Y-%m)

    if [[ "$last_reset" == "$cur_ym" ]]; then
        # Already reset this month → next is next month
        local nm=$(( cm + 1 )) ny=$cy
        (( nm > 12 )) && { nm=1; (( ny++ )); }
        printf "%d-%02d-%02d" "$ny" "$nm" "$reset_day"
    elif (( cd < reset_day )); then
        # Reset day not yet reached this month
        printf "%d-%02d-%02d" "$cy" "$cm" "$reset_day"
    else
        # Reset day passed but timer may not have fired yet → show as today/imminent
        printf "%d-%02d-%02d（今日）" "$cy" "$cm" "$reset_day"
    fi
}

# ── Traffic query ──────────────────────────────────────────────────────────────
_tgbot_query_port() {
    local port="$1"
    local state="${CFG_DIR}/traffic/state.json"

    [[ -f "$state" ]] || { echo "❌ 暂无流量统计数据（流量监控未启用）"; return; }

    # Find tag by port
    local tag
    tag=$(jq -r --argjson p "$port" \
        'to_entries[] | select((.value.port | tostring) == ($p | tostring)) | .key' \
        "$state" 2>/dev/null | head -1)

    if [[ -z "$tag" || "$tag" == "null" ]]; then
        echo "❌ 端口 *${port}* 未在流量监控中"$'\n'"💡 发送 /list 查看已监控节点"
        return
    fi

    local accumulated limit reset_day last_reset paused last_check
    accumulated=$(jq -r --arg t "$tag" '.[$t].accumulated_bytes // 0' "$state")
    limit=$(jq -r --arg t "$tag" '.[$t].limit_bytes // 0' "$state")
    reset_day=$(jq -r --arg t "$tag" '.[$t].reset_day // 1' "$state")
    last_reset=$(jq -r --arg t "$tag" '.[$t].last_reset // ""' "$state")
    paused=$(jq -r --arg t "$tag" '.[$t].paused // false' "$state")
    last_check=$(jq -r --arg t "$tag" '.[$t].last_check // "未知"' "$state")

    local remaining=$(( limit - accumulated ))
    (( remaining < 0 )) && remaining=0
    local pct=0; (( limit > 0 )) && pct=$(( accumulated * 100 / limit ))

    local status_icon status_text
    if [[ "$paused" == "true" ]]; then
        status_icon="🔴"  status_text="已暂停"
    elif (( pct >= 90 )); then
        status_icon="🟡"  status_text="即将达限"
    else
        status_icon="🟢"  status_text="运行中"
    fi

    local next_reset; next_reset=$(_tgbot_next_reset "$reset_day" "$last_reset")
    local time_str; time_str=$(echo "$last_check" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
    [[ -z "$time_str" ]] && time_str="$last_check"

    printf '📡 *%s*\n' "$tag"
    printf '━━━━━━━━━━━━━━━━━━━━\n'
    printf '%s *%s*   端口 `%s`\n\n' "$status_icon" "$status_text" "$port"
    printf '`%s`\n\n' "$(_tgbot_bar "$accumulated" "$limit")"
    printf '📤 已用   *%s*\n' "$(_tgbot_fmt_bytes "$accumulated")"
    printf '📦 限额   *%s*\n' "$(_tgbot_fmt_bytes "$limit")"
    printf '💾 剩余   *%s*\n' "$(_tgbot_fmt_bytes "$remaining")"
    printf '━━━━━━━━━━━━━━━━━━━━\n'
    printf '🔄 每月 *%s* 日重置  ·  下次 *%s*\n' "$reset_day" "$next_reset"
    printf '🕐 更新于 *%s*\n' "$time_str"
}

_tgbot_list_nodes() {
    local state="${CFG_DIR}/traffic/state.json"
    [[ -f "$state" ]] || { echo "❌ 暂无流量统计数据"; return; }

    local count; count=$(jq 'length' "$state" 2>/dev/null || echo 0)
    (( count == 0 )) && { echo "📭 尚无节点在流量监控中"; return; }

    printf '📊 *流量总览*\n'
    printf '━━━━━━━━━━━━━━━━━━━━\n'

    while IFS= read -r tag; do
        local port accumulated limit paused pct
        port=$(jq -r --arg t "$tag" '.[$t].port' "$state")
        accumulated=$(jq -r --arg t "$tag" '.[$t].accumulated_bytes // 0' "$state")
        limit=$(jq -r --arg t "$tag" '.[$t].limit_bytes // 0' "$state")
        paused=$(jq -r --arg t "$tag" '.[$t].paused // false' "$state")
        pct=0; (( limit > 0 )) && pct=$(( accumulated * 100 / limit ))

        local icon="🟢"
        [[ "$paused" == "true" ]] && icon="🔴"
        (( pct >= 90 )) && [[ "$paused" != "true" ]] && icon="🟡"

        local extra=""
        [[ "$paused" == "true" ]] && extra="  *已暂停*"

        printf '\n%s *%s*  `%s`%s\n' "$icon" "$tag" "$port" "$extra"
        printf '`%s`\n' "$(_tgbot_bar "$accumulated" "$limit")"
        printf '%s / %s\n' \
            "$(_tgbot_fmt_bytes "$accumulated")" \
            "$(_tgbot_fmt_bytes "$limit")"
    done < <(jq -r 'keys[]' "$state" 2>/dev/null)

    printf '\n━━━━━━━━━━━━━━━━━━━━\n'
    printf '💡 `/traffic <端口>` 查看详情\n'
}

# ── Permission helpers ─────────────────────────────────────────────────────────
_tgbot_is_admin() {
    local user_id="$1"
    [[ -z "${TG_ADMIN_IDS:-}" ]] && return 0   # no admin list → everyone is admin
    echo ",${TG_ADMIN_IDS}," | grep -q ",${user_id},"
}

_tgbot_tenant_port() {
    local user_id="$1"
    [[ -f "$TG_USERS_FILE" ]] || return 1
    jq -r --arg u "$user_id" '.[$u].port // empty' "$TG_USERS_FILE" 2>/dev/null
}

_tgbot_is_tenant() {
    local user_id="$1"
    [[ -f "$TG_USERS_FILE" ]] || return 1
    jq -e --arg u "$user_id" 'has($u)' "$TG_USERS_FILE" &>/dev/null
}

# ── Admin-only commands ────────────────────────────────────────────────────────
_tgbot_cmd_token() {
    local chat_id="$1" args="$2"
    local port reset_flag
    port=$(echo "$args" | awk '{print $1}')
    reset_flag=$(echo "$args" | awk '{print $2}')

    if [[ -z "$port" ]]; then
        _tgbot_send "$chat_id" \
"⚠️ 用法：
\`/token <端口>\`  查看或生成绑定码
\`/token <端口> reset\`  重新生成"
        return
    fi

    local existing; existing=$(_tgbot_port_token "$port") || true

    if [[ -z "$existing" || "$reset_flag" == "reset" ]]; then
        local new_token; new_token=$(_tgbot_gen_token)
        _tgbot_set_token "$port" "$new_token"
        local action; [[ "$reset_flag" == "reset" ]] && action="已重新生成" || action="已生成"
        _tgbot_send "$chat_id" \
"🔑 *绑定码 ${action}*
━━━━━━━━━━━━━━━━━━━━
端口    \`${port}\`
绑定码  \`${new_token}\`
━━━━━━━━━━━━━━━━━━━━
发给租客，让他向 Bot 发送：
\`${port} ${new_token}\`"
    else
        # Show existing token + bound uid if any
        local bound_uid; bound_uid=$(jq -r --arg p "$port" \
            'if (.[$p] | type) == "object" then (.[$p].uid // "未绑定") else "未绑定" end' \
            "$BIND_TOKENS_FILE" 2>/dev/null) || true
        local bound_at; bound_at=$(jq -r --arg p "$port" \
            'if (.[$p] | type) == "object" then (.[$p].bound_at // "") else "" end' \
            "$BIND_TOKENS_FILE" 2>/dev/null) || true
        local uid_line=""
        [[ "$bound_uid" != "未绑定" && "$bound_uid" != "null" && -n "$bound_uid" ]] && \
            uid_line=$'\n'"租客 ID  \`${bound_uid}\`${bound_at:+  (${bound_at})}"
        _tgbot_send "$chat_id" \
"🔑 *绑定码*
━━━━━━━━━━━━━━━━━━━━
端口    \`${port}\`
绑定码  \`${existing}\`${uid_line}
━━━━━━━━━━━━━━━━━━━━
发给租客，让他向 Bot 发送：
\`${port} ${existing}\`

_\`/token ${port} reset\` 重新生成_"
    fi
}

_tgbot_cmd_bind() {
    local chat_id="$1" args="$2"
    local uid port
    uid=$(echo "$args" | awk '{print $1}')
    port=$(echo "$args" | awk '{print $2}')
    if [[ -z "$uid" || -z "$port" ]]; then
        _tgbot_send "$chat_id" "⚠️ 用法：\`/bind <用户ID> <端口>\`"
        return
    fi
    # Resolve tag from traffic state
    local tag=""
    local state="${CFG_DIR}/traffic/state.json"
    [[ -f "$state" ]] && tag=$(jq -r --argjson p "$port" \
        'to_entries[] | select((.value.port | tostring) == ($p | tostring)) | .key' \
        "$state" 2>/dev/null | head -1)

    [[ -f "$TG_USERS_FILE" ]] || echo '{}' > "$TG_USERS_FILE"
    local tmp; tmp=$(mktemp)
    jq --arg u "$uid" --arg p "$port" --arg t "${tag:-}" \
        '.[$u] = {"port": $p, "tag": $t}' \
        "$TG_USERS_FILE" > "$tmp" && mv "$tmp" "$TG_USERS_FILE"
    _tgbot_send "$chat_id" \
"✅ *绑定成功*
━━━━━━━━━━━━━━━━━━━━
用户  \`${uid}\`
端口  \`${port}\`${tag:+  (${tag})}
━━━━━━━━━━━━━━━━━━━━
💡 让租客发送 /start 开始查询"
}

_tgbot_cmd_unbind() {
    local chat_id="$1" uid="$2"
    if [[ -z "$uid" ]]; then
        _tgbot_send "$chat_id" "⚠️ 用法：\`/unbind <用户ID>\`"
        return
    fi
    if ! _tgbot_is_tenant "$uid"; then
        _tgbot_send "$chat_id" "❌ 用户 \`${uid}\` 未绑定任何端口"
        return
    fi
    local tmp; tmp=$(mktemp)
    jq --arg u "$uid" 'del(.[$u])' "$TG_USERS_FILE" > "$tmp" && mv "$tmp" "$TG_USERS_FILE"
    _tgbot_send "$chat_id" \
"✅ *解绑成功*
━━━━━━━━━━━━━━━━━━━━
用户 \`${uid}\` 已移除"
}

_tgbot_cmd_users() {
    local chat_id="$1"
    if [[ ! -f "$TG_USERS_FILE" ]] || \
       [[ "$(jq 'length' "$TG_USERS_FILE" 2>/dev/null || echo 0)" == "0" ]]; then
        _tgbot_send "$chat_id" \
"📭 *暂无租客*
━━━━━━━━━━━━━━━━━━━━
\`/bind <ID> <端口>\` 添加租客"
        return
    fi
    local msg="👥 *租客列表*"$'\n''━━━━━━━━━━━━━━━━━━━━'$'\n'
    while IFS=$'\t' read -r uid port tag; do
        msg+=$'\n'"🔑 \`${uid}\`"$'\n'
        msg+="   端口 \`${port}\`"
        [[ -n "$tag" && "$tag" != "null" && "$tag" != "" ]] && msg+="  (${tag})"
        msg+=$'\n'
    done < <(jq -r 'to_entries[] | [.key, .value.port, (.value.tag // "")] | @tsv' \
                "$TG_USERS_FILE" 2>/dev/null)
    msg+=$'\n''━━━━━━━━━━━━━━━━━━━━'$'\n'
    msg+='`/bind` · `/unbind` 管理绑定'
    _tgbot_send "$chat_id" "$msg"
}

# ── Expiry admin commands ──────────────────────────────────────────────────────

# /expiry — list all node expiry statuses
_tgbot_cmd_expiry() {
    local chat_id="$1"
    if ! declare -f _exp_get_tags &>/dev/null; then
        _tgbot_send "$chat_id" "⚠️ 到期模块未加载"; return; fi
    _exp_init
    local msg="📅 *节点到期状态*
━━━━━━━━━━━━━━━━━━━━"
    local count=0
    while IFS= read -r tag; do
        count=$(( count + 1 ))
        local port exp_at exp_ts now_ts diff
        port=$(_exp_get "$tag" "port")
        exp_at=$(_exp_get "$tag" "expires_at")
        exp_ts=$(_exp_str_to_ts "$exp_at")
        now_ts=$(_exp_now_ts)
        diff=$(( exp_ts - now_ts ))
        local icon
        if   (( diff < 0 ));        then icon="🔴"
        elif (( diff < 86400 ));    then icon="🔴"
        elif (( diff < 3*86400 ));  then icon="🟡"
        elif (( diff < 7*86400 ));  then icon="🟡"
        else                             icon="🟢"; fi
        local days_str
        if (( diff >= 0 )); then days_str="剩 $(( diff/86400 )) 天"
        else                     days_str="已过期 $(( -diff/86400 )) 天"; fi
        msg+="
${icon} *${tag}*  端口 \`${port}\`
   到期：\`${exp_at}\`（${days_str}）"
    done < <(_exp_get_tags)
    if (( count == 0 )); then
        msg+="
_尚未设置任何节点到期时间_"; fi
    _tgbot_send "$chat_id" "$msg"
}

# /renew <port> <months> — renew a node by N months
_tgbot_cmd_renew() {
    local chat_id="$1" arg="$2"
    if ! declare -f exp_renew &>/dev/null; then
        _tgbot_send "$chat_id" "⚠️ 到期模块未加载"; return; fi
    local port months
    port=$(echo "$arg" | awk '{print $1}')
    months=$(echo "$arg" | awk '{print $2}')
    if ! [[ "$port" =~ ^[0-9]+$ ]] || ! [[ "$months" =~ ^[0-9]+$ ]] || (( months < 1 )); then
        _tgbot_send "$chat_id" "⚠️ 用法：\`/renew <端口> <月数>\`
例如：\`/renew 49123 3\`"
        return
    fi
    local tag; tag=$(exp_tag_for_port "$port")
    if [[ -z "$tag" ]]; then
        _tgbot_send "$chat_id" "❌ 端口 \`${port}\` 未配置到期记录
请先在「流量管理 → 到期管理」中设置到期时间。"
        return
    fi
    # Snapshot paused state BEFORE exp_renew clears it
    local was_paused; was_paused=$(_exp_get "$tag" "expired_paused")
    local new_exp; new_exp=$(exp_renew "$tag" "$months")
    # Resume the node if it was paused by expiry
    if [[ "$was_paused" == "true" ]]; then
        # traffic.sh may not be sourced in the bot daemon — load it on demand
        declare -f _trf_resume_tag &>/dev/null || \
            source "${PSM_ROOT}/lib/traffic.sh" 2>/dev/null || true
        declare -f _trf_resume_tag &>/dev/null && _trf_resume_tag "$tag" 2>/dev/null || true
    fi
    _tgbot_send "$chat_id" "✅ *续期成功*
━━━━━━━━━━━━━━━━━━━━
节点：\`${tag}\`　端口：\`${port}\`
续期：+${months} 个月
新到期时间（香港）：
\`${new_exp}\`"
    # Notify tenant
    tg_notify_expiry_renewed "$port" "$new_exp" 2>/dev/null || true
}

# ── Message dispatch ───────────────────────────────────────────────────────────

_tgbot_handle() {
    local chat_id="$1" user_id="$2" text="$3"
    local cmd arg
    cmd=$(echo "$text" | awk '{print $1}')
    arg=$(echo "$text" | awk 'NF>1{$1=""; sub(/^ /,""); print}')

    # ── Admin path ────────────────────────────────────────────────────────────
    if _tgbot_is_admin "$user_id"; then
        case "$cmd" in
            /start|/help)
                _tgbot_send_kb "$chat_id" \
"*PSM 流量管理*  🔑 管理员
━━━━━━━━━━━━━━━━━━━━
*流量查询*
› 直接发送端口号查询
› \`/traffic <端口>\`  指定端口
› \`/list\`  所有节点概览

*租客管理*
› \`/token <端口>\`  生成绑定码
› \`/bind <ID> <端口>\`  手动绑定
› \`/unbind <ID>\`  解绑
› \`/users\`  查看列表

*到期管理*
› \`/expiry\`  查看所有节点到期状态
› \`/renew <端口> <月数>\`  为节点续期

_每分钟自动更新_" \
                    "$(_tgbot_kb_admin)"
                ;;
            /list|/all|/nodes)
                _tgbot_send "$chat_id" "$(_tgbot_list_nodes)"
                ;;
            /traffic)
                if [[ "$arg" =~ ^[0-9]+$ ]]; then
                    _tgbot_send "$chat_id" "$(_tgbot_query_port "$arg")"
                else
                    _tgbot_send "$chat_id" "⚠️ 用法：\`/traffic <端口号>\`"
                fi
                ;;
            /token)  _tgbot_cmd_token  "$chat_id" "$arg"  ;;
            /bind)   _tgbot_cmd_bind   "$chat_id" "$arg"  ;;
            /unbind) _tgbot_cmd_unbind "$chat_id" "$arg"  ;;
            /users)  _tgbot_cmd_users  "$chat_id"         ;;
            /expiry) _tgbot_cmd_expiry "$chat_id"         ;;
            /renew)  _tgbot_cmd_renew  "$chat_id" "$arg"  ;;
            /id)
                _tgbot_send "$chat_id" \
"🪪 *您的 Telegram ID*
━━━━━━━━━━━━━━━━━━━━
\`${user_id}\`"
                ;;
            *)
                if [[ "$text" =~ ^[0-9]+$ ]] && (( text >= 1 && text <= 65535 )); then
                    _tgbot_send "$chat_id" "$(_tgbot_query_port "$text")"
                fi
                ;;
        esac
        return
    fi

    # ── Tenant path ───────────────────────────────────────────────────────────
    local tenant_port; tenant_port=$(_tgbot_tenant_port "$user_id")
    if [[ -n "$tenant_port" ]]; then
        case "$cmd" in
            /start|/help)
                _tgbot_send_kb "$chat_id" \
"*PSM 流量查询*
━━━━━━━━━━━━━━━━━━━━
您的端口：\`${tenant_port}\`

👇 点击按钮查看实时流量用量
_每分钟自动更新_" \
                    "$(_tgbot_kb_tenant)"
                ;;
            /traffic)
                _tgbot_send_kb "$chat_id" \
                    "$(_tgbot_query_port "$tenant_port")" \
                    "$(_tgbot_kb_tenant)"
                ;;
            /id)
                _tgbot_send "$chat_id" \
"🪪 *您的 Telegram ID*
━━━━━━━━━━━━━━━━━━━━
\`${user_id}\`"
                ;;
            /list|/all|/nodes|/bind|/unbind|/users)
                _tgbot_send "$chat_id" "⛔ 权限不足，无法执行此操作"
                ;;
            *)
                _tgbot_send_kb "$chat_id" \
                    "$(_tgbot_query_port "$tenant_port")" \
                    "$(_tgbot_kb_tenant)"
                ;;
        esac
        return
    fi

    # ── Self-registration: <port> <token> ────────────────────────────────────
    local state="${CFG_DIR}/traffic/state.json"
    if [[ -f "$state" ]]; then
        local input_port input_token
        input_port=$(echo "$text" | awk '{print $1}')
        input_token=$(echo "$text" | awk '{print $2}')

        # Resolve port → tag (support both port number and tag name as first word)
        local matched_port="" matched_tag=""
        if [[ "$input_port" =~ ^[0-9]+$ ]]; then
            matched_tag=$(jq -r --argjson p "$input_port" \
                'to_entries[] | select((.value.port | tostring) == ($p | tostring)) | .key' \
                "$state" 2>/dev/null | head -1)
            [[ -n "$matched_tag" && "$matched_tag" != "null" ]] && matched_port="$input_port"
        else
            matched_port=$(jq -r --arg t "$input_port" \
                'to_entries[] | select(.key == $t) | .value.port' \
                "$state" 2>/dev/null | head -1)
            [[ -n "$matched_port" && "$matched_port" != "null" ]] && matched_tag="$input_port"
        fi

        if [[ -n "$matched_port" ]]; then
            local expected; expected=$(_tgbot_port_token "$matched_port")

            if [[ -n "$expected" ]]; then
                # Token required for this port
                if [[ -z "$input_token" ]]; then
                    _tgbot_send "$chat_id" \
"🔐 端口 \`${matched_port}\` 需要绑定码
━━━━━━━━━━━━━━━━━━━━
请向 Bot 发送：
\`${matched_port} <绑定码>\`

_绑定码由管理员提供_"
                    return
                fi
                if [[ "$input_token" != "$expected" ]]; then
                    _tgbot_send "$chat_id" "❌ 绑定码错误，请检查后重试"
                    return
                fi
            fi

            # Token valid (or no token required) → bind
            [[ -f "$TG_USERS_FILE" ]] || echo '{}' > "$TG_USERS_FILE"
            local tmp; tmp=$(mktemp)
            jq --arg u "$user_id" --arg p "$matched_port" --arg t "${matched_tag:-}" \
                '.[$u] = {"port": $p, "tag": $t}' \
                "$TG_USERS_FILE" > "$tmp" && mv "$tmp" "$TG_USERS_FILE"

            # Record uid into bind_tokens.json so admin can see who is bound to each port
            _tgbot_record_token_uid "$matched_port" "$user_id" || true

            # Notify all admins
            local notify_msg
            notify_msg="🔔 *新租客绑定*
━━━━━━━━━━━━━━━━━━━━
用户 ID  \`${user_id}\`
端口      \`${matched_port}\`${matched_tag:+  (${matched_tag})}
━━━━━━━━━━━━━━━━━━━━
\`/unbind ${user_id}\`  解除绑定"
            local aid
            IFS=',' read -ra _aids <<< "${TG_ADMIN_IDS:-}"
            for aid in "${_aids[@]}"; do
                aid="${aid// /}"
                [[ -n "$aid" ]] && _tgbot_send "$aid" "$notify_msg"
            done

            local traffic_card; traffic_card=$(_tgbot_query_port "$matched_port")
            _tgbot_send_kb "$chat_id" \
"✅ *绑定成功*  ·  端口 \`${matched_port}\`
━━━━━━━━━━━━━━━━━━━━
${traffic_card}
━━━━━━━━━━━━━━━━━━━━
_后续直接发消息可刷新流量_" \
                "$(_tgbot_kb_tenant)"
            return
        fi
    fi

    # ── No access ─────────────────────────────────────────────────────────────
    _tgbot_send "$chat_id" \
"⛔ *访问受限*
━━━━━━━━━━━━━━━━━━━━
发送 \`<端口> <绑定码>\` 完成绑定。

您的 ID：\`${user_id}\`
_绑定码由管理员提供_"
}

# ── Daemon (long-polling loop) ─────────────────────────────────────────────────
tgbot_daemon() {
    _tgbot_load_cfg || exit 1

    # Source traffic helpers for live checkpoint
    source "$LIB_DIR/traffic.sh" 2>/dev/null || true
    _trf_init 2>/dev/null || true

    local offset=0
    [[ -f "$TG_BOT_OFFSET" ]] && offset=$(cat "$TG_BOT_OFFSET" 2>/dev/null || echo 0)

    echo "$(date '+%Y-%m-%d %H:%M:%S') PSM Telegram Bot started (offset=${offset})"

    while true; do
        local resp
        resp=$(_tgbot_api getUpdates \
            -d "offset=${offset}" \
            -d "timeout=30" \
            -d 'allowed_updates=["message","callback_query"]') || { sleep 5; continue; }

        local ok; ok=$(echo "$resp" | jq -r '.ok' 2>/dev/null)
        [[ "$ok" != "true" ]] && { sleep 5; continue; }

        local n; n=$(echo "$resp" | jq '.result | length' 2>/dev/null || echo 0)

        for (( i=0; i<n; i++ )); do
            local upd; upd=$(echo "$resp" | jq ".result[$i]")
            local upd_id; upd_id=$(echo "$upd" | jq -r '.update_id')

            # Advance offset BEFORE processing — prevents infinite crash loop
            # if a message handler exits non-zero under set -e
            offset=$(( upd_id + 1 ))
            echo "$offset" > "$TG_BOT_OFFSET"

            # callback_query (inline button press)
            local cb_id; cb_id=$(echo "$upd" | jq -r '.callback_query.id // empty')
            if [[ -n "$cb_id" ]]; then
                local cb_chat cb_user cb_data
                cb_chat=$(echo "$upd" | jq -r '.callback_query.message.chat.id // empty')
                cb_user=$(echo "$upd" | jq -r '.callback_query.from.id // empty')
                cb_data=$(echo "$upd" | jq -r '.callback_query.data // empty')
                [[ -n "$cb_chat" && -n "$cb_user" && -n "$cb_data" ]] && \
                    _tgbot_handle_callback "$cb_id" "$cb_chat" "$cb_user" "$cb_data" || true
            else
                # Regular text message
                local chat_id user_id text
                chat_id=$(echo "$upd" | jq -r '.message.chat.id // empty')
                user_id=$(echo "$upd" | jq -r '.message.from.id // empty')
                text=$(echo "$upd" | jq -r '.message.text // empty')
                [[ -n "$chat_id" && -n "$text" ]] && \
                    _tgbot_handle "$chat_id" "$user_id" "$text" || true
            fi
        done

        # Refresh traffic data so queries always return up-to-date numbers
        _trf_ipt_restore_all 2>/dev/null || true
        _trf_checkpoint_all  2>/dev/null || true
    done
}

# ── Systemd service management ─────────────────────────────────────────────────
_tgbot_install_svc() {
    cat > "$TG_BOT_SVC" <<EOF
[Unit]
Description=PSM Telegram Traffic Bot
After=network.target

[Service]
Type=simple
ExecStart=${PSM_ROOT}/manager.sh --tgbot
Restart=always
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now psm-tgbot.service
    log_ok "Telegram Bot 服务已启动"
}

_tgbot_uninstall_svc() {
    systemctl disable --now psm-tgbot.service 2>/dev/null || true
    rm -f "$TG_BOT_SVC"
    systemctl daemon-reload
    log_ok "Telegram Bot 服务已删除"
}

_tgbot_svc_active() {
    systemctl is-active --quiet psm-tgbot.service 2>/dev/null
}

# ── Setup wizard ───────────────────────────────────────────────────────────────
tgbot_setup() {
    echo -e "\n${BOLD}${BLUE}══ Telegram Bot 配置向导 ═══════════════════════════${NC}"
    echo -e "  1. 在 Telegram 中搜索 ${CYAN}@BotFather${NC}"
    echo -e "  2. 发送 /newbot，按提示创建机器人"
    echo -e "  3. 复制 BotFather 给出的 Token（格式：123456:ABC...）"
    echo ""

    local cur_token=""
    [[ -f "$TG_BOT_CFG" ]] && { source "$TG_BOT_CFG" 2>/dev/null; cur_token="${TG_BOT_TOKEN:-}"; }

    local token
    if [[ -n "$cur_token" ]]; then
        ask token "Bot Token（回车保留现有）" "$cur_token"
    else
        ask token "Bot Token"
    fi
    [[ -z "$token" ]] && { log_error "Token 不能为空"; return 1; }

    # Validate token
    log_step "正在验证 Token..."
    local bot_info
    bot_info=$(curl -fsSL --max-time 10 \
        "${TG_API_BASE}${token}/getMe" 2>/dev/null)
    local bot_ok; bot_ok=$(echo "$bot_info" | jq -r '.ok' 2>/dev/null)
    if [[ "$bot_ok" != "true" ]]; then
        log_error "Token 无效或网络不通，请检查后重试"
        return 1
    fi
    local bot_name; bot_name=$(echo "$bot_info" | jq -r '.result.username')
    log_ok "Bot 验证成功：@${bot_name}"

    # Admin whitelist
    echo ""
    echo -e "  ${YELLOW}管理员权限（可查所有节点 / 管理租客绑定）：${NC}"
    echo -e "  留空 = 任何人均为管理员（适合个人独用）"
    echo -e "  填写 ID = 仅指定用户为管理员（多租户推荐）"
    echo -e "  不知道自己的 ID？启动 Bot 后发送 /id 查看"
    echo ""

    local cur_ids="${TG_ADMIN_IDS:-${TG_ALLOWED_IDS:-}}"
    local admin_ids
    ask admin_ids "管理员 Telegram ID（多个用逗号分隔，留空不限制）" "$cur_ids"

    TG_BOT_TOKEN="$token"
    TG_ADMIN_IDS="$admin_ids"
    _tgbot_save_cfg

    log_ok "配置已保存：${TG_BOT_CFG}"
    echo ""

    if _tgbot_svc_active; then
        ask_yn "Bot 服务正在运行，是否重启以应用新配置？" Y && \
            systemctl restart psm-tgbot.service && log_ok "Bot 已重启"
    else
        ask_yn "是否现在启动 Telegram Bot 服务？" Y && _tgbot_install_svc
    fi
}

# ── Tenant management (PSM menu) ──────────────────────────────────────────────
tgbot_tenant_menu() {
    local state="${CFG_DIR}/traffic/state.json"
    while true; do
        echo -e "\n${BOLD}${BLUE}══ 租客绑定管理 ══════════════════════════${NC}"

        # Show current bindings
        if [[ -f "$TG_USERS_FILE" ]] && \
           [[ "$(jq 'length' "$TG_USERS_FILE" 2>/dev/null || echo 0)" -gt 0 ]]; then
            echo -e "${BOLD}当前绑定：${NC}"
            while IFS=$'\t' read -r uid port tag; do
                printf "  🔑 用户 %-15s → 端口 %-8s %s\n" \
                    "$uid" "$port" "${tag:+(${tag})}"
            done < <(jq -r 'to_entries[] | [.key, .value.port, (.value.tag // "")] | @tsv' \
                        "$TG_USERS_FILE" 2>/dev/null)
        else
            echo -e "  ${YELLOW}暂无租客绑定${NC}"
        fi
        echo ""

        show_menu "租客绑定管理" \
            "绑定租客到端口" \
            "解除租客绑定" \
            "查看所有绑定"

        case "$MENU_CHOICE" in
            1)
                local uid port
                ask uid  "租客的 Telegram 用户 ID"
                ask port "绑定的端口号"
                if [[ -z "$uid" || -z "$port" ]]; then
                    log_error "用户 ID 和端口不能为空"; continue
                fi
                local tag=""
                [[ -f "$state" ]] && tag=$(jq -r --argjson p "$port" \
                    'to_entries[] | select((.value.port | tostring) == ($p | tostring)) | .key' \
                    "$state" 2>/dev/null | head -1)
                [[ -f "$TG_USERS_FILE" ]] || echo '{}' > "$TG_USERS_FILE"
                local tmp; tmp=$(mktemp)
                jq --arg u "$uid" --arg p "$port" --arg t "${tag:-}" \
                    '.[$u] = {"port": $p, "tag": $t}' \
                    "$TG_USERS_FILE" > "$tmp" && mv "$tmp" "$TG_USERS_FILE"
                log_ok "已绑定用户 ${uid} → 端口 ${port}${tag:+ (${tag})}"
                press_enter
                ;;
            2)
                local uid
                ask uid "要解绑的租客 Telegram 用户 ID"
                if [[ -z "$uid" ]]; then continue; fi
                if ! jq -e --arg u "$uid" 'has($u)' "$TG_USERS_FILE" &>/dev/null 2>&1; then
                    log_warn "用户 ${uid} 未绑定任何端口"; press_enter; continue
                fi
                local tmp; tmp=$(mktemp)
                jq --arg u "$uid" 'del(.[$u])' "$TG_USERS_FILE" > "$tmp" && \
                    mv "$tmp" "$TG_USERS_FILE"
                log_ok "已解绑用户 ${uid}"
                press_enter
                ;;
            3)
                if [[ ! -f "$TG_USERS_FILE" ]] || \
                   [[ "$(jq 'length' "$TG_USERS_FILE" 2>/dev/null || echo 0)" == "0" ]]; then
                    log_warn "暂无租客绑定"
                else
                    echo -e "\n${BOLD}绑定详情：${NC}"
                    jq -r 'to_entries[] | "  \(.key)  →  端口 \(.value.port)  \(if .value.tag != "" then "(\(.value.tag))" else "" end)"' \
                        "$TG_USERS_FILE" 2>/dev/null
                fi
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# ── Menu ───────────────────────────────────────────────────────────────────────
tgbot_menu() {
    while true; do
        local svc_status
        if _tgbot_svc_active; then
            svc_status="${GREEN}运行中${NC}"
        else
            svc_status="${RED}未运行${NC}"
        fi

        echo -e "\n${BOLD}${BLUE}══ Telegram Bot 管理${NC}  (服务状态: $(echo -e "$svc_status")${BOLD}${BLUE})${NC}"
        show_menu "Telegram Bot" \
            "配置 Bot Token / 管理员权限" \
            "管理租客绑定（绑定/解绑/查看）" \
            "启动 Bot 服务" \
            "停止 Bot 服务" \
            "重启 Bot 服务" \
            "查看 Bot 服务日志" \
            "卸载 Bot 服务" \
            "每日体检报告"

        case "$MENU_CHOICE" in
            1) tgbot_setup ;;
            2) _tgbot_load_cfg && tgbot_tenant_menu; press_enter ;;
            3) _tgbot_load_cfg && _tgbot_install_svc; press_enter ;;
            4) systemctl stop psm-tgbot.service 2>/dev/null && log_ok "Bot 已停止"; press_enter ;;
            5) systemctl restart psm-tgbot.service 2>/dev/null && log_ok "Bot 已重启"; press_enter ;;
            6) journalctl -u psm-tgbot.service -f --no-pager ;;
            7) ask_yn "确认卸载 Telegram Bot 服务？" N && _tgbot_uninstall_svc; press_enter ;;
            8) source "$LIB_DIR/tgbot/health_report.sh"; hr_menu ;;
            0) return ;;
        esac
    done
}
