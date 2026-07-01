#!/usr/bin/env bash
# expiry/core.sh — Node expiry date management (Hong Kong time, UTC+8)

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

source "$(dirname "${BASH_SOURCE[0]}")/../tgbot/expiry_notify.sh" 2>/dev/null || true

EXPIRY_DIR="${CFG_DIR}/expiry"
EXPIRY_STATE="${EXPIRY_DIR}/state.json"
EXPIRY_LOG="${LOG_DIR}/expiry.log"
_EXP_TZ="Asia/Hong_Kong"

# ── State helpers ─────────────────────────────────────────────────────────────
_exp_init() {
    mkdir -p "$EXPIRY_DIR"
    [[ -f "$EXPIRY_STATE" ]] || echo '{}' > "$EXPIRY_STATE"
}

_exp_get() {
    local tag="$1" field="$2"
    [[ -f "$EXPIRY_STATE" ]] || { echo ""; return; }
    jq -r --arg t "$tag" --arg f "$field" '.[$t][$f] // ""' "$EXPIRY_STATE" 2>/dev/null || echo ""
}

_exp_get_tags() {
    [[ -f "$EXPIRY_STATE" ]] || return 0
    jq -r 'keys[]' "$EXPIRY_STATE" 2>/dev/null || true
}

# ── Time helpers ──────────────────────────────────────────────────────────────
_exp_now_ts()    { TZ="$_EXP_TZ" date +%s; }
_exp_hk_now()    { TZ="$_EXP_TZ" date '+%Y-%m-%d %H:%M:%S'; }
_exp_str_to_ts() { TZ="$_EXP_TZ" date -d "${1:-}" +%s 2>/dev/null || echo 0; }

# ── CRUD ──────────────────────────────────────────────────────────────────────

# Set expiry for a node (creates or overwrites).
# expires_hk: "YYYY-MM-DD" (auto-padded to 23:59:59) or "YYYY-MM-DD HH:MM:SS" in HKT.
exp_set() {
    local tag="$1" port="$2" exp_hk="$3"
    _exp_init
    [[ "$exp_hk" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && exp_hk="${exp_hk} 23:59:59"
    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" --argjson p "$port" --arg e "$exp_hk" '
        if .[$t] == null then
            .[$t] = {"port": $p, "expires_at": $e,
                     "notified_7d": false, "notified_3d": false, "notified_1d": false,
                     "expired_paused": false}
        else
            .[$t].port = $p | .[$t].expires_at = $e
            | .[$t].notified_7d   = false | .[$t].notified_3d   = false
            | .[$t].notified_1d   = false | .[$t].expired_paused = false
        end
    ' "$EXPIRY_STATE" > "$tmp" && mv "$tmp" "$EXPIRY_STATE"
}

# Renew by N months. Extends from current expiry if still in the future,
# otherwise extends from now. Returns new expiry string (HKT).
exp_renew() {
    local tag="$1" months="$2"
    _exp_init
    local current; current=$(_exp_get "$tag" "expires_at")
    local base
    if [[ -n "$current" ]]; then
        local cur_ts; cur_ts=$(_exp_str_to_ts "$current")
        local now_ts; now_ts=$(_exp_now_ts)
        if (( cur_ts > now_ts )); then base="$current"
        else base="$(_exp_hk_now)"; fi
    else
        base="$(_exp_hk_now)"
    fi
    local new_exp; new_exp=$(TZ="$_EXP_TZ" date -d "$base +${months} months" '+%Y-%m-%d %H:%M:%S')
    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" --arg e "$new_exp" '
        .[$t].expires_at      = $e
        | .[$t].notified_7d   = false
        | .[$t].notified_3d   = false
        | .[$t].notified_1d   = false
        | .[$t].expired_paused = false
    ' "$EXPIRY_STATE" > "$tmp" && mv "$tmp" "$EXPIRY_STATE"
    echo "$new_exp"
}

# Look up the tag for a port in the expiry state (empty if not found).
exp_tag_for_port() {
    local port="$1"
    [[ -f "$EXPIRY_STATE" ]] || return 0
    jq -r --argjson p "$port" \
        'to_entries[] | select(.value.port == $p) | .key' \
        "$EXPIRY_STATE" 2>/dev/null | head -1 || true
}

exp_delete() {
    local tmp; tmp=$(mktemp)
    jq --arg t "$1" 'del(.[$t])' "$EXPIRY_STATE" > "$tmp" && mv "$tmp" "$EXPIRY_STATE"
}

# ── Periodic enforcement (called from traffic_check) ──────────────────────────
expiry_check() {
    [[ -f "$EXPIRY_STATE" ]] || return 0
    local now_ts; now_ts=$(_exp_now_ts)

    while IFS= read -r tag; do
        local expires_at; expires_at=$(_exp_get "$tag" "expires_at")
        [[ -z "$expires_at" ]] && continue
        local exp_ts; exp_ts=$(_exp_str_to_ts "$expires_at")
        (( exp_ts == 0 )) && continue

        local port; port=$(_exp_get "$tag" "port")
        local diff=$(( exp_ts - now_ts ))

        # Approaching-expiry notifications (each sent once via flag)
        _exp_maybe_notify "$tag" "$port" "$expires_at" "$diff"

        # Pause on expiry (only once)
        if (( diff <= 0 )) && [[ "$(_exp_get "$tag" "expired_paused")" != "true" ]]; then
            log_warn "[到期] 节点 ${tag}（端口 ${port}）已到期，正在暂停..."
            echo "$(TZ="$_EXP_TZ" date '+%Y-%m-%d %H:%M:%S') EXPIRED tag=${tag} port=${port}" >> "$EXPIRY_LOG"
            # _trf_pause_tag is defined in traffic.sh which sources this file,
            # so it is available at call time.
            declare -f _trf_pause_tag &>/dev/null && _trf_pause_tag "$tag" 2>/dev/null || true
            local _t; _t=$(mktemp)
            jq --arg t "$tag" '.[$t].expired_paused = true' \
                "$EXPIRY_STATE" > "$_t" && mv "$_t" "$EXPIRY_STATE"
            tg_notify_expiry_expired "$port" "$expires_at" 2>/dev/null || true
        fi

    done < <(_exp_get_tags)
}

_exp_maybe_notify() {
    local tag="$1" port="$2" exp_str="$3" diff="$4"
    (( diff <= 0 )) && return 0   # already expired, handled separately
    local _t field
    for days in 7 3 1; do
        field="notified_${days}d"
        if (( diff <= days * 86400 )) && [[ "$(_exp_get "$tag" "$field")" != "true" ]]; then
            tg_notify_expiry_warn "$port" "$exp_str" "$days" 2>/dev/null || true
            _t=$(mktemp)
            jq --arg t "$tag" --arg f "$field" '.[$t][$f] = true' \
                "$EXPIRY_STATE" > "$_t" && mv "$_t" "$EXPIRY_STATE"
        fi
    done
}

# ── Interactive status display ─────────────────────────────────────────────────
_exp_show_status() {
    _exp_init
    echo -e "\n${BOLD}${BLUE}══ 节点到期管理（香港时间）════════════════════════${NC}"
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
        if   (( diff < 0 ));           then icon="${RED}● 已过期${NC}"
        elif (( diff < 86400 ));       then icon="${RED}● 即将到期${NC}"
        elif (( diff < 3*86400 ));     then icon="${YELLOW}● 3天内到期${NC}"
        elif (( diff < 7*86400 ));     then icon="${YELLOW}● 7天内到期${NC}"
        else                                icon="${GREEN}● 正常${NC}"; fi

        local days_str
        if (( diff >= 0 )); then days_str="剩余 $(( diff / 86400 )) 天"
        else                     days_str="已过期 $(( -diff / 86400 )) 天"; fi

        printf "  ${BOLD}${CYAN}%s${NC}  (端口 %s)  %b\n" "$tag" "$port" "$(echo -e "$icon")"
        printf "    到期时间 [HKT]: %s  (%s)\n" "$exp_at" "$days_str"
        echo ""
    done < <(_exp_get_tags)
    (( count == 0 )) && echo -e "  ${YELLOW}尚未为任何节点设置到期时间${NC}\n"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════${NC}"
}

# ── Interactive wizard: set or renew expiry for a node ────────────────────────
_exp_wizard() {
    _exp_init
    echo -e "\n${BOLD}设置节点到期时间（香港时间）${NC}"

    # Collect available tags from traffic state
    local trf_state="${CFG_DIR}/traffic/state.json"
    if [[ ! -f "$trf_state" ]]; then
        log_warn "尚未配置任何节点流量限制，请先在流量管理中添加节点。"
        return
    fi

    local tags_arr=() ports_arr=()
    local i=0
    while IFS= read -r tag; do
        local port; port=$(jq -r --arg t "$tag" '.[$t].port // ""' "$trf_state" 2>/dev/null)
        [[ -z "$port" ]] && continue
        i=$(( i+1 )); tags_arr+=("$tag"); ports_arr+=("$port")
        local cur_exp; cur_exp=$(_exp_get "$tag" "expires_at")
        printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s 到期: %s\n" \
            "$i" "$tag" "$port" "${cur_exp:-(未设置)}"
    done < <(jq -r 'keys[]' "$trf_state" 2>/dev/null)

    if (( i == 0 )); then log_warn "没有找到可配置的节点"; return; fi
    echo ""
    local sel
    read -rp "$(echo -e "${CYAN}选择节点序号（0=取消）: ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "无效选项"; return; fi

    local tag="${tags_arr[$((sel-1))]}"
    local port="${ports_arr[$((sel-1))]}"
    local cur_exp; cur_exp=$(_exp_get "$tag" "expires_at")

    echo ""
    if [[ -n "$cur_exp" ]]; then
        log_info "当前到期时间：${cur_exp}（香港时间）"
        echo "  1. 续期（从当前到期时间/现在起增加月数）"
        echo "  2. 重新设置（直接输入新日期）"
        local mode
        read -rp "$(echo -e "${CYAN}请选择 [1]: ${NC}")" mode
        mode="${mode:-1}"
    else
        local mode="2"
    fi

    if [[ "$mode" == "1" ]]; then
        local months
        ask months "续期月数" "1"
        if ! [[ "$months" =~ ^[0-9]+$ ]] || (( months < 1 )); then
            log_error "月数须为正整数"; return; fi
        local new_exp; new_exp=$(exp_renew "$tag" "$months")
        log_ok "节点 ${tag} 已续期至：${new_exp}（香港时间）"
    else
        local date_in
        ask date_in "到期日期（YYYY-MM-DD 或 YYYY-MM-DD HH:MM:SS，香港时间）" \
            "$(TZ="$_EXP_TZ" date -d 'now +1 month' '+%Y-%m-%d')"
        exp_set "$tag" "$port" "$date_in"
        log_ok "节点 ${tag} 到期时间已设置为：${date_in}（香港时间）"
    fi
}
