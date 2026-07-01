#!/usr/bin/env bash
# traffic.sh — Per-node traffic metering and limiting

# manager.sh already sources common.sh; only source it ourselves when run standalone
if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

# Telegram notification helpers (non-fatal if missing)
source "$(dirname "${BASH_SOURCE[0]}")/tgbot/notify.sh" 2>/dev/null || true
# Expiry management module (non-fatal if missing)
source "$(dirname "${BASH_SOURCE[0]}")/expiry/core.sh" 2>/dev/null || true

# ── Constants ─────────────────────────────────────────────────────────────────
TRAFFIC_DIR="$CFG_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
TRAFFIC_LOG="$LOG_DIR/traffic.log"
XRAY_API_PORT=10085
XRAY_API_ADDR="127.0.0.1:${XRAY_API_PORT}"
PSM_TRAFFIC_SVC="/etc/systemd/system/psm-traffic.service"
PSM_TRAFFIC_TIMER="/etc/systemd/system/psm-traffic.timer"
PSM_TRAFFIC_SHUTDOWN="/etc/systemd/system/psm-traffic-shutdown.service"

_GB=$((1024 * 1024 * 1024))
IPT_CHAIN="PSM_TRF"   # dedicated iptables accounting chain
XRAY_CFG="${XRAY_CFG_DIR}/config.json"

# Resolve iptables binary — systemd services run with a minimal PATH that
# often omits /usr/sbin and /sbin where iptables lives.
_IPT=$(command -v iptables 2>/dev/null \
    || command -v iptables-legacy 2>/dev/null \
    || { for _p in /usr/sbin/iptables /sbin/iptables; do
             [[ -x "$_p" ]] && echo "$_p" && break; done; } \
    || echo "iptables")
unset _p

# ── State helpers ─────────────────────────────────────────────────────────────
_trf_init() {
    mkdir -p "$TRAFFIC_DIR"
    [[ -f "$TRAFFIC_STATE" ]] || echo '{}' > "$TRAFFIC_STATE"
}

_trf_get_tags() {
    [[ -f "$TRAFFIC_STATE" ]] || return 0
    jq -r 'keys[]' "$TRAFFIC_STATE" 2>/dev/null || true
}

_trf_get() {
    local tag="$1" field="$2"
    [[ -f "$TRAFFIC_STATE" ]] || { echo ""; return; }
    jq -r --arg t "$tag" --arg f "$field" '.[$t][$f] // ""' "$TRAFFIC_STATE" 2>/dev/null || echo ""
}

_trf_init_tag() {
    local tag="$1" port="$2"
    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" --argjson p "$port" '
        if .[$t] == null then
            .[$t] = {
                "port": $p,
                "limit_bytes": 0,
                "accumulated_bytes": 0,
                "checkpoint_bytes": 0,
                "paused": false,
                "paused_at": null,
                "reset_day": 1,
                "last_reset": "",
                "warned90": false
            }
        else
            .[$t].port = $p
        end
    ' "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"
}

_trf_set_field() {
    local tag="$1" field="$2" val="$3"   # val must be valid JSON
    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" --arg f "$field" --argjson v "$val" \
        '.[$t][$f] = $v' "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"
}

_trf_set_str() {
    local tag="$1" field="$2" val="$3"
    _trf_set_field "$tag" "$field" "\"$val\""
}

_trf_delete_tag() {
    local tmp; tmp=$(mktemp)
    jq --arg t "$1" 'del(.[$t])' "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"
}

# Called by protocol delete/uninstall to remove a node's traffic monitoring state.
# Handles paused DROP rules and iptables accounting rules, then removes the entry.
_trf_cleanup_node() {
    local tag="$1"
    [[ -f "$TRAFFIC_STATE" ]] || return 0
    jq -e --arg t "$tag" '.[$t]' "$TRAFFIC_STATE" &>/dev/null || return 0

    local port;   port=$(_trf_get "$tag" "port")
    local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"
    local paused; paused=$(_trf_get "$tag" "paused")

    if [[ "$paused" == "true" ]]; then
        case "$source" in
            xray)     _trf_xray_unblock_inbound "$tag" 2>/dev/null || true ;;
            iptables) [[ -n "$port" ]] && _trf_iptables_resume "$port" ;;
        esac
    fi
    [[ "$source" == "iptables" ]] && [[ -n "$port" ]] && _trf_ipt_remove_rules "$tag" "$port"
    _trf_delete_tag "$tag"
    # Also remove expiry record if the expiry module is loaded
    declare -f exp_delete &>/dev/null && exp_delete "$tag" 2>/dev/null || true
    log_ok "节点 ${tag} 的流量监控记录已清除"
}

# ── Xray Stats API ─────────────────────────────────────────────────────────────
_trf_stats_enabled() {
    [[ -f "$XRAY_CFG" ]] || return 1
    jq -e '.stats != null and .api != null' "$XRAY_CFG" &>/dev/null && \
    jq -e '[.inbounds[]? | select(.tag == "api")] | length > 0' "$XRAY_CFG" &>/dev/null
}

_trf_enable_stats() {
    if _trf_stats_enabled; then
        log_info "Xray 统计 API 已启用（端口 ${XRAY_API_PORT}）"
        return 0
    fi
    [[ -f "$XRAY_CFG" ]] || { log_error "Xray 配置不存在，请先安装 Xray"; return 1; }

    log_step "正在启用 Xray 统计 API..."
    cp "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%Y%m%d%H%M%S)"

    local tmp; tmp=$(mktemp)
    jq --argjson ap "$XRAY_API_PORT" '
        . + {"stats": {}}
        | . + {"policy": {"system": {"statsInboundUplink": true, "statsInboundDownlink": true}}}
        | . + {"api": {"tag": "api", "services": ["StatsService"]}}
        | .inbounds = [
              { "tag": "api", "listen": "127.0.0.1", "port": $ap,
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"},
                "streamSettings": {"network": "tcp"} }
          ] + [.inbounds[]? | select(.tag != "api")]
        | .routing.rules = [
              {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}
          ] + [.routing.rules[]? | select(.outboundTag != "api")]
    ' "$XRAY_CFG" > "$tmp" && mv "$tmp" "$XRAY_CFG"

    log_ok "Xray 统计 API 已启用（端口 ${XRAY_API_PORT}）"
    xray_test_restart
}

_trf_query_bytes() {
    # Returns uplink+downlink bytes for an inbound tag from the Xray stats API.
    # Returns 0 if the API is unreachable or the tag has no data yet.
    local tag="$1"
    local output=""

    output=$("$XRAY_BIN" api statsquery \
        --server="$XRAY_API_ADDR" \
        -pattern "inbound>>>${tag}>>>traffic" 2>/dev/null) \
    || output=$("$XRAY_BIN" api statsquery \
        -s "$XRAY_API_ADDR" \
        -pattern "inbound>>>${tag}>>>traffic" 2>/dev/null) || true

    [[ -z "$output" ]] && { echo 0; return; }

    echo "$output" | awk '
        /uplink/   { fu=1 }
        fu && /value/ { match($0, /[0-9]+/); up += substr($0, RSTART, RLENGTH)+0; fu=0 }
        /downlink/ { fd=1 }
        fd && /value/ { match($0, /[0-9]+/); dn += substr($0, RSTART, RLENGTH)+0; fd=0 }
        END { printf "%.0f\n", up+dn }
    '
}

# ── Integer sanitiser ────────────────────────────────────────────────────────
# mawk (Debian default) prints byte counts >= ~1e6 in %.6g scientific notation
# (e.g. 1.58e+09). Bash (( )) cannot parse that. This coerces any number to a
# plain decimal integer before arithmetic.
_trf_to_int() {
    LC_NUMERIC=C printf "%.0f" "${1:-0}" 2>/dev/null || echo 0
}

# ── Checkpoint: pull current stats into accumulated totals ────────────────────
# Handles two sources:
#   xray     — Xray Stats API (Reality / Vision / XHTTP inbounds)
#   iptables — PSM_TRF chain byte counters (Snell / SS2022 / any other)
_trf_checkpoint_all() {
    local xray_ok=0
    _trf_stats_enabled && xray_ok=1

    local now; now=$(TZ="Asia/Hong_Kong" date '+%Y-%m-%dT%H:%M:%S')

    while IFS= read -r tag; do
        local limit; limit=$(_trf_get "$tag" "limit_bytes")
        [[ "${limit:-0}" -le 0 ]] && continue

        local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"

        local current_bytes=0
        case "$source" in
            xray)
                (( xray_ok )) && current_bytes=$(_trf_query_bytes "$tag") || continue
                ;;
            iptables)
                current_bytes=$(_trf_ipt_query_bytes "$tag")
                ;;
            *)
                continue
                ;;
        esac

        # Sanitise all three values to plain integers before arithmetic —
        # state.json may contain floats written by a previous buggy awk run.
        current_bytes=$(_trf_to_int "$current_bytes")
        local checkpoint; checkpoint=$(_trf_to_int "$(_trf_get "$tag" "checkpoint_bytes")")
        local accumulated; accumulated=$(_trf_to_int "$(_trf_get "$tag" "accumulated_bytes")")

        local delta
        if (( current_bytes >= checkpoint )); then
            delta=$(( current_bytes - checkpoint ))
        else
            # Counter was reset (Xray restart / iptables flush) — treat current as full delta
            delta=$current_bytes
        fi

        local new_acc=$(( accumulated + delta ))
        local tmp; tmp=$(mktemp)
        jq --arg t "$tag" \
           --argjson cb "$current_bytes" \
           --argjson acc "$new_acc" \
           --arg now "$now" \
           '.[$t].checkpoint_bytes = $cb
            | .[$t].accumulated_bytes = $acc
            | .[$t].last_check = $now' \
           "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"

    done < <(_trf_get_tags)
}

# ── Monthly reset ─────────────────────────────────────────────────────────────
_trf_check_monthly_reset() {
    local current_month; current_month=$(date +%Y-%m)
    local current_day; current_day=$(date +%-d)   # no leading zero

    while IFS= read -r tag; do
        local reset_day; reset_day=$(_trf_get "$tag" "reset_day"); reset_day="${reset_day:-0}"
        local last_reset; last_reset=$(_trf_get "$tag" "last_reset")

        [[ "$reset_day" -le 0 ]]                && continue
        [[ "$last_reset" == "$current_month" ]] && continue  # already reset this month
        (( current_day < reset_day ))           && continue  # reset day not yet reached

        log_info "[流量] 节点 ${tag} 月度流量重置（每月 ${reset_day} 日）"
        echo "$(TZ="Asia/Hong_Kong" date '+%Y-%m-%d %H:%M:%S') RESET tag=${tag}" >> "$TRAFFIC_LOG"

        local port;   port=$(_trf_get "$tag" "port")
        local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"
        # Snapshot the live counter and use it as the new checkpoint so that
        # the next delta = current - checkpoint = 0 (not a ghost re-accumulation).
        local cur_cb=0
        case "$source" in
            xray)     cur_cb=$(_trf_query_bytes "$tag" 2>/dev/null || echo 0) ;;
            iptables) cur_cb=$(_trf_ipt_query_bytes "$tag" 2>/dev/null || echo 0) ;;
        esac
        cur_cb=$(_trf_to_int "$cur_cb")
        local tmp; tmp=$(mktemp)
        jq --arg t "$tag" --arg m "$current_month" --argjson cb "$cur_cb" '
            .[$t].accumulated_bytes  = 0
            | .[$t].checkpoint_bytes = $cb
            | .[$t].last_reset       = $m
            | .[$t].paused           = false
            | .[$t].paused_at        = null
            | .[$t].warned90         = false
        ' "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"

        case "$source" in
            xray)     _trf_xray_unblock_inbound "$tag" 2>/dev/null || true ;;
            iptables) [[ -n "$port" ]] && _trf_iptables_resume "$port" ;;
        esac

    done < <(_trf_get_tags)
}

# ── iptables pause / resume (for non-Xray nodes: Snell, SS2022) ──────────────
_trf_iptables_pause() {
    local port="$1"
    # REJECT+tcp-reset sends RST immediately, killing existing TCP sessions.
    # DROP only silently stalls them until TCP timeout (minutes).
    $_IPT -C INPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || \
        $_IPT -I INPUT 1 -p tcp --dport "$port" -j REJECT --reject-with tcp-reset
    $_IPT -C INPUT -p udp --dport "$port" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || \
        $_IPT -I INPUT 1 -p udp --dport "$port" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
    # Force-close existing TCP sessions so the over-quota user is kicked immediately
    ss -K "sport = :${port}" 2>/dev/null || true
    # Flush conntrack so the kernel forgets established session state
    conntrack -D -p tcp --dport "$port" 2>/dev/null || true
    conntrack -D -p udp --dport "$port" 2>/dev/null || true
}

_trf_iptables_resume() {
    local port="$1"
    $_IPT -D INPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || true
    $_IPT -D INPUT -p udp --dport "$port" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
    # Remove legacy DROP rules left by older versions
    $_IPT -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
    $_IPT -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null || true
}

# ── Xray blackhole pause / resume (for Reality / Vision / XHTTP) ─────────────
# Adds a routing rule that routes the specific inbound to a blackhole outbound.
# More reliable than iptables for Nginx-proxied nodes (traffic enters on port 443,
# not the local Xray port, so INPUT rules on the local port are not guaranteed to
# block loopback connections from Nginx). The routing rule persists in the Xray
# config file and survives Xray restarts — unlike iptables which is lost on reboot.
_trf_xray_block_inbound() {
    local tag="$1"
    [[ -f "$XRAY_CFG" ]] || return 1

    # Idempotent: skip if the blocking rule already exists
    if jq -e --arg t "$tag" '
        ([.routing.rules[]? |
          select(.outboundTag == "blocked" and
                 ((.inboundTag // []) | index($t)) != null)
        ] | length) > 0' "$XRAY_CFG" &>/dev/null; then
        return 0
    fi

    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" '
        # Ensure a blackhole outbound exists
        if ([.outbounds[]? | select(.tag == "blocked")] | length) == 0 then
            .outbounds += [{"tag": "blocked", "protocol": "blackhole", "settings": {}}]
        else . end
        # Prepend the blocking routing rule (high priority)
        | .routing.rules = [{"type": "field", "inboundTag": [$t], "outboundTag": "blocked"}]
            + (.routing.rules // [])
    ' "$XRAY_CFG" > "$tmp" && mv "$tmp" "$XRAY_CFG"

    # Kill existing connections on this inbound's port immediately, before Xray restarts.
    # This ensures the over-quota user is disconnected right away rather than waiting
    # for their ongoing session to naturally end after the restart.
    local iport; iport=$(_trf_get "$tag" "port" 2>/dev/null || true)
    [[ -n "$iport" ]] && ss -K "sport = :${iport}" 2>/dev/null || true

    xray_test_restart 2>/dev/null || true
}

_trf_xray_unblock_inbound() {
    local tag="$1"
    [[ -f "$XRAY_CFG" ]] || return 0

    # Idempotent: skip if no blocking rule exists for this tag
    jq -e --arg t "$tag" '
        ([.routing.rules[]? |
          select(.outboundTag == "blocked" and
                 ((.inboundTag // []) | index($t)) != null)
        ] | length) > 0' "$XRAY_CFG" &>/dev/null || return 0

    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" '
        .routing.rules = [.routing.rules[]? | select(
            (.outboundTag == "blocked" and
             ((.inboundTag // []) | index($t)) != null) | not
        )]
    ' "$XRAY_CFG" > "$tmp" && mv "$tmp" "$XRAY_CFG"

    xray_test_restart 2>/dev/null || true
}

# ── iptables availability check ───────────────────────────────────────────────
_trf_ensure_iptables() {
    command -v iptables &>/dev/null && return 0
    # iptables not found — try to install it
    log_warn "iptables 未安装，正在自动安装..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y iptables >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y iptables >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add --no-cache iptables >/dev/null 2>&1
    fi
    if command -v iptables &>/dev/null; then
        # Re-resolve _IPT now that iptables is installed
        _IPT=$(command -v iptables)
        log_ok "iptables 已安装：$_IPT"
        return 0
    else
        log_error "iptables 安装失败，请手动执行：apt install iptables"
        return 1
    fi
}

# ── iptables accounting chain (for Snell / SS2022 / any non-Xray node) ────────
# Uses a dedicated chain PSM_TRF with RETURN rules so packet fate is unchanged.
# Byte counters in those rules serve as the traffic meter.

_trf_ipt_ensure_chain() {
    _trf_ensure_iptables || return 1
    # Use mangle table PREROUTING/POSTROUTING so that traffic forwarded into
    # a network namespace (e.g. snell-netns) is counted.  These hooks see ALL
    # packets — locally-delivered AND forwarded — unlike filter INPUT/OUTPUT
    # which only see packets terminating/originating on this host.
    $_IPT -t mangle -N "$IPT_CHAIN" 2>/dev/null || true
    $_IPT -t mangle -C PREROUTING  -j "$IPT_CHAIN" 2>/dev/null || \
        $_IPT -t mangle -I PREROUTING  1 -j "$IPT_CHAIN"
    $_IPT -t mangle -C POSTROUTING -j "$IPT_CHAIN" 2>/dev/null || \
        $_IPT -t mangle -I POSTROUTING 1 -j "$IPT_CHAIN"
}

_trf_ipt_ensure_rules() {
    # Add accounting rules for tag/port if they don't already exist.
    # -C before -A preserves existing counters (no reset on re-run).
    local tag="$1" port="$2"
    _trf_ipt_ensure_chain
    local proto
    for proto in tcp udp; do
        $_IPT -t mangle -C "$IPT_CHAIN" -p "$proto" --dport "$port" \
            -m comment --comment "psm-in-${tag}" -j RETURN 2>/dev/null || \
            $_IPT -t mangle -A "$IPT_CHAIN" -p "$proto" --dport "$port" \
                -m comment --comment "psm-in-${tag}" -j RETURN
        $_IPT -t mangle -C "$IPT_CHAIN" -p "$proto" --sport "$port" \
            -m comment --comment "psm-out-${tag}" -j RETURN 2>/dev/null || \
            $_IPT -t mangle -A "$IPT_CHAIN" -p "$proto" --sport "$port" \
                -m comment --comment "psm-out-${tag}" -j RETURN
    done
}

_trf_ipt_remove_rules() {
    local tag="$1" port="$2"
    local proto
    for proto in tcp udp; do
        $_IPT -t mangle -D "$IPT_CHAIN" -p "$proto" --dport "$port" \
            -m comment --comment "psm-in-${tag}"  -j RETURN 2>/dev/null || true
        $_IPT -t mangle -D "$IPT_CHAIN" -p "$proto" --sport "$port" \
            -m comment --comment "psm-out-${tag}" -j RETURN 2>/dev/null || true
    done
}

_trf_ipt_query_bytes() {
    # Sum bytes from all accounting rules matching this tag (mangle table).
    local tag="$1"
    $_IPT -t mangle -nvxL "$IPT_CHAIN" 2>/dev/null | \
        awk -v t="$tag" '
            /psm-in-/ || /psm-out-/ {
                if ($0 ~ ("psm-in-"t" ") || $0 ~ ("psm-out-"t" ")) {
                    total += $2
                }
            }
            END { printf "%.0f\n", total+0 }
        '
}

_trf_ipt_restore_all() {
    # Called on every traffic_check to re-establish accounting rules lost after reboot.
    while IFS= read -r tag; do
        local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"
        [[ "$source" != "iptables" ]] && continue
        local port; port=$(_trf_get "$tag" "port")
        [[ -n "$port" ]] && _trf_ipt_ensure_rules "$tag" "$port"
    done < <(_trf_get_tags)
}

_trf_pause_tag() {
    local tag="$1"
    local port;   port=$(_trf_get "$tag" "port")
    local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"
    local ts;     ts=$(TZ="Asia/Hong_Kong" date '+%Y-%m-%dT%H:%M:%S')

    case "$source" in
        xray)
            # Xray nodes (Reality/Vision/XHTTP): add a blackhole routing rule so
            # Xray drops all traffic from this inbound. iptables INPUT on the local
            # Xray port is unreliable for Nginx-proxied nodes (traffic enters on
            # port 443, not the local port; loopback handling varies by system).
            _trf_xray_block_inbound "$tag"
            ;;
        iptables)
            _trf_iptables_pause "$port"
            ;;
    esac

    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" --arg ts "$ts" \
        '.[$t].paused = true | .[$t].paused_at = $ts' \
        "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"

    echo "$(TZ="Asia/Hong_Kong" date '+%Y-%m-%d %H:%M:%S') PAUSE tag=${tag} port=${port}" >> "$TRAFFIC_LOG"
    log_warn "[流量] 节点 ${tag}（端口 ${port}）已达流量上限，已暂停"

    # Notify tenant via Telegram (non-fatal)
    local acc_b lim_b
    acc_b=$(_trf_to_int "$(_trf_get "$tag" "accumulated_bytes")")
    lim_b=$(_trf_to_int "$(_trf_get "$tag" "limit_bytes")")
    tg_notify_traffic_paused "$port" "$acc_b" "$lim_b" 2>/dev/null || true
}

_trf_resume_tag() {
    local tag="$1"
    local port;   port=$(_trf_get "$tag" "port")
    local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"

    case "$source" in
        xray)
            _trf_xray_unblock_inbound "$tag"
            ;;
        iptables)
            _trf_iptables_resume "$port"
            ;;
    esac

    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" \
        '.[$t].paused = false | .[$t].paused_at = null' \
        "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"

    echo "$(TZ="Asia/Hong_Kong" date '+%Y-%m-%d %H:%M:%S') RESUME tag=${tag} port=${port}" >> "$TRAFFIC_LOG"
    log_ok "[流量] 节点 ${tag}（端口 ${port}）已恢复"
}

# ── Enforce limits ────────────────────────────────────────────────────────────
_trf_enforce() {
    while IFS= read -r tag; do
        local limit; limit=$(_trf_to_int "$(_trf_get "$tag" "limit_bytes")")
        [[ "$limit" -le 0 ]] && continue

        local accumulated; accumulated=$(_trf_to_int "$(_trf_get "$tag" "accumulated_bytes")")
        local paused; paused=$(_trf_get "$tag" "paused")
        local port; port=$(_trf_get "$tag" "port")

        # 90% warning: send once per cycle (reset on monthly/manual reset)
        if (( limit > 0 && accumulated * 100 / limit >= 90 )) \
           && [[ "$(_trf_get "$tag" "warned90")" != "true" ]] \
           && [[ "$paused" != "true" ]]; then
            tg_notify_traffic_warn "$port" "$accumulated" "$limit" 2>/dev/null || true
            local _tmp; _tmp=$(mktemp)
            jq --arg t "$tag" '.[$t].warned90 = true' \
                "$TRAFFIC_STATE" > "$_tmp" && mv "$_tmp" "$TRAFFIC_STATE"
        fi

        if (( accumulated >= limit )) && [[ "$paused" != "true" ]]; then
            _trf_pause_tag "$tag"
        fi

        # Re-apply pause rule on reboot.
        # - iptables rules are lost on reboot → re-add them.
        # - Xray blackhole rules are in the config file → survive Xray restarts,
        #   but re-calling _trf_xray_block_inbound is idempotent (no restart if
        #   the rule is already present).
        if [[ "$paused" == "true" ]] && [[ -n "$port" ]]; then
            local source_e; source_e=$(_trf_get "$tag" "source"); source_e="${source_e:-xray}"
            case "$source_e" in
                xray)
                    _trf_xray_block_inbound "$tag" 2>/dev/null || true
                    ;;
                iptables)
                    # Re-apply both TCP and UDP block rules lost on reboot.
                    # _trf_iptables_pause is idempotent (-C before -I).
                    _trf_iptables_pause "$port" 2>/dev/null || true
                    ;;
            esac
        fi

    done < <(_trf_get_tags)
}

# ── Main periodic check (invoked by systemd timer) ────────────────────────────
traffic_check() {
    _trf_init
    _trf_ipt_restore_all    # re-establish accounting rules lost after reboot
    _trf_check_monthly_reset
    _trf_checkpoint_all
    _trf_enforce
    # Expiry enforcement (non-fatal if module not loaded)
    declare -f expiry_check &>/dev/null && expiry_check || true
}

# ── Systemd timer management ──────────────────────────────────────────────────
_trf_timer_active() {
    systemctl is-active --quiet psm-traffic.timer 2>/dev/null
}

_trf_install_timer() {
    # Periodic check service (run by the timer)
    cat > "$PSM_TRAFFIC_SVC" <<EOF
[Unit]
Description=PSM Traffic Monitor
After=network.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PSM_ROOT}/manager.sh --traffic-check
StandardOutput=journal
StandardError=journal
EOF

    # Timer: first fire 30s after boot, then every 1 minute
    cat > "$PSM_TRAFFIC_TIMER" <<EOF
[Unit]
Description=PSM Traffic Monitor Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Shutdown checkpoint: runs just before halt/reboot, captures the last ~5-min window
    cat > "$PSM_TRAFFIC_SHUTDOWN" <<EOF
[Unit]
Description=PSM Traffic Checkpoint on Shutdown/Reboot
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
After=network.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PSM_ROOT}/manager.sh --traffic-check
TimeoutStartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

    systemctl daemon-reload
    systemctl enable --now psm-traffic.timer
    systemctl enable psm-traffic-shutdown.service
    log_ok "流量监控已安装："
    log_ok "  定时检查 — 开机 30 秒后首次运行，之后每 1 分钟一次"
    log_ok "  关机存档 — 每次关机/重启前自动 checkpoint，防止流量丢失"
}

_trf_uninstall_timer() {
    systemctl disable --now psm-traffic.timer            2>/dev/null || true
    systemctl disable     psm-traffic-shutdown.service   2>/dev/null || true
    rm -f "$PSM_TRAFFIC_SVC" "$PSM_TRAFFIC_TIMER" "$PSM_TRAFFIC_SHUTDOWN"
    systemctl daemon-reload
    log_ok "流量监控定时器及关机存档服务已删除"
}

# ── Formatting helpers ─────────────────────────────────────────────────────────
_fmt_bytes() {
    local b="${1:-0}"
    if   (( b >= 1099511627776 )); then
        printf "%d.%02d TB" $(( b / 1099511627776 )) $(( (b % 1099511627776) * 100 / 1099511627776 ))
    elif (( b >= 1073741824 )); then
        printf "%d.%02d GB" $(( b / 1073741824 ))    $(( (b % 1073741824)    * 100 / 1073741824 ))
    elif (( b >= 1048576 )); then
        printf "%d.%02d MB" $(( b / 1048576 ))       $(( (b % 1048576)       * 100 / 1048576 ))
    else
        printf "%d B" "$b"
    fi
}

_fmt_pct_bar() {
    # _fmt_pct_bar <used> <total>  → "██░░░░ 35%"
    local used="$1" total="$2" width=20
    local pct=0
    (( total > 0 )) && pct=$(( used * 100 / total ))
    (( pct > 100 )) && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf "%s %3d%%" "$bar" "$pct"
}

# ── Interactive: status display ───────────────────────────────────────────────
_trf_show_status() {
    _trf_init
    # Do a live checkpoint so the display always reflects current traffic,
    # not just what the last timer run captured.
    _trf_ipt_restore_all
    _trf_checkpoint_all
    echo -e "\n${BOLD}${BLUE}══ 流量管理状态 ════════════════════════════════════${NC}"

    local api_ok timer_ok
    _trf_stats_enabled  && api_ok="${GREEN}已启用${NC}"    || api_ok="${RED}未启用${NC}"
    _trf_timer_active   && timer_ok="${GREEN}运行中${NC}"  || timer_ok="${YELLOW}未运行${NC}"
    printf "  Xray 统计 API : %b\n" "$api_ok"
    printf "  自动检查定时器: %b\n" "$timer_ok"
    echo ""

    local count=0
    while IFS= read -r tag; do
        count=$(( count + 1 ))
        local limit;       limit=$(_trf_to_int "$(_trf_get "$tag" "limit_bytes")")
        local accumulated; accumulated=$(_trf_to_int "$(_trf_get "$tag" "accumulated_bytes")")
        local paused;      paused=$(_trf_get "$tag" "paused")
        local port;        port=$(_trf_get "$tag" "port")
        local reset_day;   reset_day=$(_trf_get "$tag" "reset_day")
        local last_check;  last_check=$(_trf_get "$tag" "last_check")
        local paused_at;   paused_at=$(_trf_get "$tag" "paused_at")
        local last_reset;  last_reset=$(_trf_get "$tag" "last_reset")

        local status_icon
        if [[ "$paused" == "true" ]]; then
            status_icon="${RED}● 已暂停${NC}"
        else
            local pct=0
            (( limit > 0 )) && pct=$(( accumulated * 100 / limit ))
            if   (( pct >= 90 )); then status_icon="${YELLOW}● 警告${NC}"
            elif (( pct >= 50 )); then status_icon="${CYAN}● 运行中${NC}"
            else                        status_icon="${GREEN}● 运行中${NC}"
            fi
        fi

        echo -e "  ${BOLD}${CYAN}${tag}${NC}  (端口 ${port})  $(echo -e "$status_icon")"
        printf "    进度: %s\n" "$(_fmt_pct_bar "$accumulated" "$limit")"
        printf "    已用: %-12s  限制: %s\n" "$(_fmt_bytes "$accumulated")" "$(_fmt_bytes "$limit")"
        printf "    重置: 每月 %s 日  |  本月: %s  |  上次检查: %s\n" \
            "$reset_day" "${last_reset:-(从未)}" "${last_check:-(从未)}"
        [[ "$paused" == "true" ]] && printf "    暂停时间: %s\n" "${paused_at}"
        echo ""

    done < <(_trf_get_tags)

    if (( count == 0 )); then
        echo -e "  ${YELLOW}尚未添加任何节点到流量管理${NC}\n"
        echo -e "  提示：选择「添加节点流量限制」来开始管理流量。\n"
    fi

    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════${NC}"
}

# ── Interactive: add/edit limit wizard ───────────────────────────────────────
_trf_add_wizard() {
    _trf_init

    # Collect available nodes from all supported protocols
    local tags=() ports=() sources=()
    local i=0

    echo -e "\n${BOLD}可用节点:${NC}"

    # ── Xray nodes (stats via Xray API) ──────────────────────────────────────
    {
        source "$LIB_DIR/xray/reality.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray")
                printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s ${YELLOW}[Reality / Xray API]${NC}\n" \
                    "$i" "$tag" "$port"
            done < <(_reality_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/vision.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray")
                printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s ${YELLOW}[Vision / Xray API]${NC}\n" \
                    "$i" "$tag" "$port"
            done < <(_vision_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/xhttp.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray")
                printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s ${YELLOW}[XHTTP / Xray API]${NC}\n" \
                    "$i" "$tag" "$port"
            done < <(_xhttp_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/ss2022.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray")
                printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s ${CYAN}[SS2022 / Xray API]${NC}\n" \
                    "$i" "$tag" "$port"
            done < <(_xss_list 2>/dev/null)
    } || true

    # ── Snell (stats via iptables) ────────────────────────────────────────────
    local snell_conf="/etc/snell/users/snell-main.conf"
    if [[ -f "$snell_conf" ]]; then
        local snell_port
        snell_port=$(grep -E '^listen' "$snell_conf" | grep -oP ':\K[0-9]+$' 2>/dev/null || true)
        if [[ -n "$snell_port" ]]; then
            i=$((i+1)); tags+=("snell"); ports+=("$snell_port"); sources+=("iptables")
            printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s ${GREEN}[Snell / iptables]${NC}\n" \
                "$i" "snell" "$snell_port"
        fi
    fi

    # ── SS2022 / ss-rust (stats via iptables) ────────────────────────────────
    local ss_conf="/etc/ss-rust/config.json"
    if [[ -f "$ss_conf" ]]; then
        local ss_port
        ss_port=$(jq -r '.server_port // empty' "$ss_conf" 2>/dev/null || true)
        if [[ -n "$ss_port" ]]; then
            i=$((i+1)); tags+=("ss2022"); ports+=("$ss_port"); sources+=("iptables")
            printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s ${GREEN}[SS2022 / iptables]${NC}\n" \
                "$i" "ss2022" "$ss_port"
        fi
    fi

    if (( i == 0 )); then
        log_warn "没有找到可管理的节点（Xray / Snell / SS2022）。"
        return
    fi
    echo ""

    local sel
    read -rp "$(echo -e "${CYAN}选择节点序号（0=取消）: ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "无效选项"; return
    fi

    local tag="${tags[$((sel-1))]}"
    local port="${ports[$((sel-1))]}"
    local source="${sources[$((sel-1))]}"

    # Show existing config if any
    local cur_limit; cur_limit=$(_trf_get "$tag" "limit_bytes")
    local cur_reset; cur_reset=$(_trf_get "$tag" "reset_day")
    local def_limit=100
    local def_reset=1
    [[ "${cur_limit:-0}" -gt 0 ]] && def_limit=$(( cur_limit / _GB ))
    [[ -n "$cur_reset" ]] && def_reset="$cur_reset"

    local limit_gb reset_day
    ask limit_gb  "流量限制 (GB)"    "$def_limit"
    ask reset_day "每月重置日 (1-28)" "$def_reset"

    if ! [[ "$limit_gb" =~ ^[0-9]+$ ]] || (( limit_gb <= 0 )); then
        log_error "无效的流量值，须为正整数 GB"; return 1
    fi
    if ! [[ "$reset_day" =~ ^[0-9]+$ ]] || (( reset_day < 1 || reset_day > 28 )); then
        log_error "重置日须在 1–28 之间"; return 1
    fi

    local limit_bytes=$(( limit_gb * _GB ))
    _trf_init_tag "$tag" "$port"
    _trf_set_field "$tag" "limit_bytes" "$limit_bytes"
    _trf_set_field "$tag" "reset_day"   "$reset_day"
    _trf_set_str   "$tag" "source"      "$source"

    log_ok "已为节点 ${tag}（端口 ${port}）设置 ${limit_gb} GB 限制，每月 ${reset_day} 日重置"
    log_info "计数方式: ${source}"

    # Protocol-specific setup
    case "$source" in
        xray)
            if ! _trf_stats_enabled; then
                echo ""
                log_warn "Xray 统计 API 未启用，流量将无法计数。"
                ask_yn "是否现在启用 Xray 统计 API？（需重启 Xray）" Y && _trf_enable_stats
            fi
            ;;
        iptables)
            log_step "正在初始化 iptables 流量计数规则..."
            _trf_ipt_ensure_rules "$tag" "$port"
            log_ok "iptables 计数规则已就绪（链 ${IPT_CHAIN}）"
            ;;
    esac

    if ! _trf_timer_active; then
        echo ""
        ask_yn "是否安装自动检查定时器？（推荐）" Y && _trf_install_timer
    fi

    # Optionally set an expiry date for this node
    if declare -f exp_set &>/dev/null; then
        echo ""
        if ask_yn "是否设置节点到期时间？" N; then
            local exp_months
            ask exp_months "到期时长（月数，从今日起计，香港时间）" "1"
            if [[ "$exp_months" =~ ^[0-9]+$ ]] && (( exp_months > 0 )); then
                local exp_date; exp_date=$(TZ="Asia/Hong_Kong" \
                    date -d "now +${exp_months} months" '+%Y-%m-%d 23:59:59')
                exp_set "$tag" "$port" "$exp_date"
                log_ok "到期时间：${exp_date}（香港时间）"
            fi
        fi
    fi
}

# ── Interactive: manual pause/resume/reset ────────────────────────────────────
_trf_pick_tag() {
    local prompt="$1"
    local tags_arr=()
    local i=0
    while IFS= read -r t; do
        i=$((i+1)); tags_arr+=("$t")
        local port; port=$(_trf_get "$t" "port")
        local paused; paused=$(_trf_get "$t" "paused")
        local status; [[ "$paused" == "true" ]] && status="${RED}[暂停]${NC}" || status="${GREEN}[运行]${NC}"
        printf "  ${CYAN}%2d.${NC} %-22s 端口 %-6s %b\n" "$i" "$t" "$port" "$status"
    done < <(_trf_get_tags)
    (( i == 0 )) && { log_warn "没有已配置的节点"; return 1; }
    echo ""
    local sel
    read -rp "$(echo -e "${CYAN}${prompt}（0=取消）: ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "无效选项"; return 1
    fi
    PICKED_TAG="${tags_arr[$((sel-1))]}"
}

_trf_manual_pause() {
    _trf_init
    echo -e "\n${BOLD}选择要暂停的节点:${NC}"
    local PICKED_TAG=""
    _trf_pick_tag "选择节点序号" || return
    [[ "$(_trf_get "$PICKED_TAG" "paused")" == "true" ]] && \
        { log_warn "节点 ${PICKED_TAG} 已处于暂停状态"; return; }
    _trf_pause_tag "$PICKED_TAG"
}

_trf_manual_resume() {
    _trf_init
    echo -e "\n${BOLD}选择要恢复的节点:${NC}"
    local PICKED_TAG=""
    _trf_pick_tag "选择节点序号" || return
    _trf_resume_tag "$PICKED_TAG"
}

_trf_reset_stats() {
    _trf_init
    echo -e "\n${BOLD}选择要重置流量统计的节点:${NC}"

    local tags_arr=()
    local i=0
    while IFS= read -r t; do
        i=$((i+1)); tags_arr+=("$t")
        local acc; acc=$(_trf_get "$t" "accumulated_bytes"); acc="${acc:-0}"
        printf "  ${CYAN}%2d.${NC} %-22s 已用 %s\n" "$i" "$t" "$(_fmt_bytes "$acc")"
    done < <(_trf_get_tags)
    (( i > 0 )) && printf "  ${CYAN}%2d.${NC} 全部重置\n" "$(( i+1 ))"
    (( i == 0 )) && { log_warn "没有已配置的节点"; return; }

    local sel
    read -rp "$(echo -e "${CYAN}选择（0=取消）: ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return

    local reset_all=0
    (( sel == i+1 )) && reset_all=1

    if (( reset_all )); then
        ask_yn "确认重置所有节点的流量统计？" N || return
        while IFS= read -r t; do
            local port;   port=$(_trf_get "$t" "port")
            local src;    src=$(_trf_get "$t" "source"); src="${src:-xray}"
            local cur_cb=0
            case "$src" in
                xray)     cur_cb=$(_trf_query_bytes "$t" 2>/dev/null || echo 0) ;;
                iptables) cur_cb=$(_trf_ipt_query_bytes "$t" 2>/dev/null || echo 0) ;;
            esac
            cur_cb=$(_trf_to_int "$cur_cb")
            local tmp; tmp=$(mktemp)
            jq --arg t "$t" --argjson cb "$cur_cb" '
                .[$t].accumulated_bytes  = 0
                | .[$t].checkpoint_bytes = $cb
                | .[$t].paused           = false
                | .[$t].paused_at        = null
                | .[$t].warned90         = false
            ' "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"
            case "$src" in
                xray)     _trf_xray_unblock_inbound "$t" 2>/dev/null || true ;;
                iptables) [[ -n "$port" ]] && _trf_iptables_resume "$port" ;;
            esac
        done < <(_trf_get_tags)
        log_ok "所有节点流量统计已重置"
    else
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
            log_warn "无效选项"; return
        fi
        local tag="${tags_arr[$((sel-1))]}"
        ask_yn "确认重置节点 ${tag} 的流量统计？" N || return
        local port;   port=$(_trf_get "$tag" "port")
        local src;    src=$(_trf_get "$tag" "source"); src="${src:-xray}"
        local cur_cb=0
        case "$src" in
            xray)     cur_cb=$(_trf_query_bytes "$tag" 2>/dev/null || echo 0) ;;
            iptables) cur_cb=$(_trf_ipt_query_bytes "$tag" 2>/dev/null || echo 0) ;;
        esac
        cur_cb=$(_trf_to_int "$cur_cb")
        local tmp; tmp=$(mktemp)
        jq --arg t "$tag" --argjson cb "$cur_cb" '
            .[$t].accumulated_bytes  = 0
            | .[$t].checkpoint_bytes = $cb
            | .[$t].paused           = false
            | .[$t].paused_at        = null
            | .[$t].warned90         = false
        ' "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"
        case "$src" in
            xray)     _trf_xray_unblock_inbound "$tag" 2>/dev/null || true ;;
            iptables) [[ -n "$port" ]] && _trf_iptables_resume "$port" ;;
        esac
        log_ok "节点 ${tag} 流量统计已重置"
    fi
}

_trf_remove_node() {
    _trf_init
    echo -e "\n${BOLD}从流量管理中移除节点（不影响代理本身）:${NC}"
    local PICKED_TAG=""
    _trf_pick_tag "选择节点序号" || return

    ask_yn "确认从流量管理中移除 ${PICKED_TAG}？（不影响节点本身）" N || return

    local port; port=$(_trf_get "$PICKED_TAG" "port")
    local source; source=$(_trf_get "$PICKED_TAG" "source"); source="${source:-xray}"
    local paused; paused=$(_trf_get "$PICKED_TAG" "paused")

    if [[ "$paused" == "true" ]]; then
        case "$source" in
            xray)     _trf_xray_unblock_inbound "$PICKED_TAG" 2>/dev/null || true ;;
            iptables) [[ -n "$port" ]] && _trf_iptables_resume "$port" ;;
        esac
    fi
    [[ "$source" == "iptables" ]] && [[ -n "$port" ]] && _trf_ipt_remove_rules "$PICKED_TAG" "$port"

    _trf_delete_tag "$PICKED_TAG"
    log_ok "已移除 ${PICKED_TAG}"
}

# ── View recent log ───────────────────────────────────────────────────────────
_trf_view_log() {
    mkdir -p "$LOG_DIR"
    if [[ ! -f "$TRAFFIC_LOG" || ! -s "$TRAFFIC_LOG" ]]; then
        log_info "流量日志为空"; return
    fi
    echo -e "\n${BOLD}最近 30 条流量日志:${NC}"
    tail -30 "$TRAFFIC_LOG"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
traffic_menu() {
    _trf_init
    while true; do
        show_menu "流量管理" \
            "查看流量状态" \
            "添加/编辑节点流量限制" \
            "手动暂停节点" \
            "手动恢复节点" \
            "重置流量统计" \
            "移除节点流量限制" \
            "启用 Xray 统计 API" \
            "安装自动检查定时器（每 1 分钟）" \
            "卸载自动检查定时器" \
            "查看流量日志" \
            "── 到期管理 ──" \
            "查看节点到期状态" \
            "设置/续期节点到期时间"

        case "$MENU_CHOICE" in
            1)  _trf_show_status;      press_enter ;;
            2)  _trf_add_wizard;       press_enter ;;
            3)  _trf_manual_pause;     press_enter ;;
            4)  _trf_manual_resume;    press_enter ;;
            5)  _trf_reset_stats;      press_enter ;;
            6)  _trf_remove_node;      press_enter ;;
            7)  _trf_enable_stats;     press_enter ;;
            8)  _trf_install_timer;    press_enter ;;
            9)  _trf_uninstall_timer;  press_enter ;;
            10) _trf_view_log;         press_enter ;;
            11) ;; # separator
            12) declare -f _exp_show_status &>/dev/null && _exp_show_status || \
                    log_warn "到期模块未加载"; press_enter ;;
            13) declare -f _exp_wizard &>/dev/null && _exp_wizard || \
                    log_warn "到期模块未加载"; press_enter ;;
            0)  return ;;
        esac
    done
}
