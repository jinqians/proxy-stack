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

# Port used for iptables accounting/pause rules. Falls back to the public port
# for entries enrolled before count_port existed. When 443-multiplexed nodes
# (Nginx SNI → 127.0.0.1:backend) arrive, count_port will hold the loopback
# backend port while "port" stays the public-facing one shown to users.
_trf_count_port() {
    local cp; cp=$(_trf_get "$1" "count_port")
    [[ -n "$cp" ]] && printf '%s' "$cp" || _trf_get "$1" "port"
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

    local cport;  cport=$(_trf_count_port "$tag")
    local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"
    local paused; paused=$(_trf_get "$tag" "paused")

    if [[ "$paused" == "true" ]]; then
        case "$source" in
            xray)     _trf_xray_unblock_inbound "$tag" 2>/dev/null || true ;;
            iptables) [[ -n "$cport" ]] && _trf_iptables_resume "$cport" ;;
        esac
    fi
    [[ "$source" == "iptables" ]] && [[ -n "$cport" ]] && \
        _trf_ipt_remove_rules "$tag" "$cport" "$(_trf_get "$tag" "count_iface")"
    _trf_delete_tag "$tag"
    # Also remove expiry record if the expiry module is loaded
    declare -f exp_delete &>/dev/null && exp_delete "$tag" 2>/dev/null || true
    log_ok "$(t traffic.cleanup.removed "$tag")"
}

# ── Xray Stats API ─────────────────────────────────────────────────────────────
_trf_stats_enabled() {
    [[ -f "$XRAY_CFG" ]] || return 1
    jq -e '.stats != null and .api != null' "$XRAY_CFG" &>/dev/null && \
    jq -e '[.inbounds[]? | select(.tag == "api")] | length > 0' "$XRAY_CFG" &>/dev/null
}

_trf_enable_stats() {
    if _trf_stats_enabled; then
        log_info "$(t traffic.xray.api_enabled "$XRAY_API_PORT")"
        return 0
    fi
    [[ -f "$XRAY_CFG" ]] || { log_error "$(t traffic.xray.config_missing)"; return 1; }

    log_step "$(t traffic.xray.enabling_api)"
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

    log_ok "$(t traffic.xray.api_enabled "$XRAY_API_PORT")"
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

        log_info "$(t traffic.monthly_reset "$tag" "$reset_day")"
        echo "$(TZ="Asia/Hong_Kong" date '+%Y-%m-%d %H:%M:%S') RESET tag=${tag}" >> "$TRAFFIC_LOG"

        local cport;  cport=$(_trf_count_port "$tag")
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
            iptables) [[ -n "$cport" ]] && _trf_iptables_resume "$cport" ;;
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
    log_warn "$(t traffic.iptables.installing)"
    if command -v apt-get &>/dev/null; then
        apt-get install -y iptables >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        # EL9+ 的包名是 iptables-nft（提供 iptables 命令，nft 后端）
        dnf install -y iptables >/dev/null 2>&1 \
            || dnf install -y iptables-nft >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y iptables >/dev/null 2>&1 \
            || yum install -y iptables-nft >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add --no-cache iptables >/dev/null 2>&1
    fi
    if command -v iptables &>/dev/null; then
        # Re-resolve _IPT now that iptables is installed
        _IPT=$(command -v iptables)
        log_ok "$(t traffic.iptables.installed "$_IPT")"
        return 0
    else
        log_error "$(t traffic.iptables.install_failed)"
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
    # $3 (optional) = interface for loopback-backend nodes ("lo"). Nginx-fronted
    # nodes are metered on their 127.0.0.1 backend port; loopback packets
    # traverse BOTH PREROUTING and POSTROUTING (which both jump into this
    # chain), so bare port matching would count them twice. Restricting the
    # in-rule to -i lo and the out-rule to -o lo makes each direction match in
    # exactly one hook.
    local tag="$1" port="$2" iface="${3:-}"
    _trf_ipt_ensure_chain
    local proto
    local -a in_if=() out_if=()
    [[ -n "$iface" ]] && { in_if=(-i "$iface"); out_if=(-o "$iface"); }
    for proto in tcp udp; do
        $_IPT -t mangle -C "$IPT_CHAIN" "${in_if[@]}" -p "$proto" --dport "$port" \
            -m comment --comment "psm-in-${tag}" -j RETURN 2>/dev/null || \
            $_IPT -t mangle -A "$IPT_CHAIN" "${in_if[@]}" -p "$proto" --dport "$port" \
                -m comment --comment "psm-in-${tag}" -j RETURN
        $_IPT -t mangle -C "$IPT_CHAIN" "${out_if[@]}" -p "$proto" --sport "$port" \
            -m comment --comment "psm-out-${tag}" -j RETURN 2>/dev/null || \
            $_IPT -t mangle -A "$IPT_CHAIN" "${out_if[@]}" -p "$proto" --sport "$port" \
                -m comment --comment "psm-out-${tag}" -j RETURN
    done
}

_trf_ipt_remove_rules() {
    # Deletes both the bare and the interface-restricted rule variants so a
    # node cleans up correctly regardless of which mode it was enrolled in.
    local tag="$1" port="$2" iface="${3:-}"
    local proto
    for proto in tcp udp; do
        $_IPT -t mangle -D "$IPT_CHAIN" -p "$proto" --dport "$port" \
            -m comment --comment "psm-in-${tag}"  -j RETURN 2>/dev/null || true
        $_IPT -t mangle -D "$IPT_CHAIN" -p "$proto" --sport "$port" \
            -m comment --comment "psm-out-${tag}" -j RETURN 2>/dev/null || true
        if [[ -n "$iface" ]]; then
            $_IPT -t mangle -D "$IPT_CHAIN" -i "$iface" -p "$proto" --dport "$port" \
                -m comment --comment "psm-in-${tag}"  -j RETURN 2>/dev/null || true
            $_IPT -t mangle -D "$IPT_CHAIN" -o "$iface" -p "$proto" --sport "$port" \
                -m comment --comment "psm-out-${tag}" -j RETURN 2>/dev/null || true
        fi
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
        local cport; cport=$(_trf_count_port "$tag")
        local ciface; ciface=$(_trf_get "$tag" "count_iface")
        [[ -n "$cport" ]] && _trf_ipt_ensure_rules "$tag" "$cport" "$ciface"
    done < <(_trf_get_tags)
}

_trf_pause_tag() {
    local tag="$1"
    local port;   port=$(_trf_get "$tag" "port")
    local cport;  cport=$(_trf_count_port "$tag")
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
            _trf_iptables_pause "$cport"
            ;;
    esac

    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" --arg ts "$ts" \
        '.[$t].paused = true | .[$t].paused_at = $ts' \
        "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"

    echo "$(TZ="Asia/Hong_Kong" date '+%Y-%m-%d %H:%M:%S') PAUSE tag=${tag} port=${port}" >> "$TRAFFIC_LOG"
    log_warn "$(t traffic.limit.paused "$tag" "$port")"

    # Notify tenant via Telegram (non-fatal)
    local acc_b lim_b
    acc_b=$(_trf_to_int "$(_trf_get "$tag" "accumulated_bytes")")
    lim_b=$(_trf_to_int "$(_trf_get "$tag" "limit_bytes")")
    tg_notify_traffic_paused "$port" "$acc_b" "$lim_b" 2>/dev/null || true
}

_trf_resume_tag() {
    local tag="$1"
    local port;   port=$(_trf_get "$tag" "port")
    local cport;  cport=$(_trf_count_port "$tag")
    local source; source=$(_trf_get "$tag" "source"); source="${source:-xray}"

    case "$source" in
        xray)
            _trf_xray_unblock_inbound "$tag"
            ;;
        iptables)
            _trf_iptables_resume "$cport"
            ;;
    esac

    local tmp; tmp=$(mktemp)
    jq --arg t "$tag" \
        '.[$t].paused = false | .[$t].paused_at = null' \
        "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"

    echo "$(TZ="Asia/Hong_Kong" date '+%Y-%m-%d %H:%M:%S') RESUME tag=${tag} port=${port}" >> "$TRAFFIC_LOG"
    log_ok "$(t traffic.limit.resumed "$tag" "$port")"
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
        if [[ "$paused" == "true" ]]; then
            local source_e; source_e=$(_trf_get "$tag" "source"); source_e="${source_e:-xray}"
            local cport_e;  cport_e=$(_trf_count_port "$tag")
            case "$source_e" in
                xray)
                    _trf_xray_block_inbound "$tag" 2>/dev/null || true
                    ;;
                iptables)
                    # Re-apply both TCP and UDP block rules lost on reboot.
                    # _trf_iptables_pause is idempotent (-C before -I).
                    [[ -n "$cport_e" ]] && _trf_iptables_pause "$cport_e" 2>/dev/null || true
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
    log_ok "$(t traffic.timer.installed)"
    log_ok "$(t traffic.timer.line_check)"
    log_ok "$(t traffic.timer.line_shutdown)"
}

_trf_uninstall_timer() {
    systemctl disable --now psm-traffic.timer            2>/dev/null || true
    systemctl disable     psm-traffic-shutdown.service   2>/dev/null || true
    rm -f "$PSM_TRAFFIC_SVC" "$PSM_TRAFFIC_TIMER" "$PSM_TRAFFIC_SHUTDOWN"
    systemctl daemon-reload
    log_ok "$(t traffic.timer.removed)"
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
    echo -e "\n${BOLD}${BLUE}$(t traffic.status.title)${NC}"

    local api_ok timer_ok
    _trf_stats_enabled  && api_ok="${GREEN}$(t traffic.status.enabled)${NC}"    || api_ok="${RED}$(t traffic.status.disabled)${NC}"
    _trf_timer_active   && timer_ok="${GREEN}$(t traffic.status.running)${NC}"  || timer_ok="${YELLOW}$(t traffic.status.not_running)${NC}"
    printf "$(t traffic.status.api_label)" "$api_ok"
    printf "$(t traffic.status.timer_label)" "$timer_ok"
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
            status_icon="${RED}$(t traffic.status.paused)${NC}"
        else
            local pct=0
            (( limit > 0 )) && pct=$(( accumulated * 100 / limit ))
            if   (( pct >= 90 )); then status_icon="${YELLOW}$(t traffic.status.warning)${NC}"
            elif (( pct >= 50 )); then status_icon="${CYAN}$(t traffic.status.ok)${NC}"
            else                        status_icon="${GREEN}$(t traffic.status.ok)${NC}"
            fi
        fi

        echo -e "  ${BOLD}${CYAN}${tag}${NC}  ($(t traffic.port_label) ${port})  $(echo -e "$status_icon")"
        printf "$(t traffic.status.progress)" "$(_fmt_pct_bar "$accumulated" "$limit")"
        printf "$(t traffic.status.used_limit)" "$(_fmt_bytes "$accumulated")" "$(_fmt_bytes "$limit")"
        printf "$(t traffic.status.reset_line)" \
            "$reset_day" "${last_reset:-$(t traffic.status.never)}" "${last_check:-$(t traffic.status.never)}"
        [[ "$paused" == "true" ]] && printf "$(t traffic.status.paused_at)" "${paused_at}"
        echo ""

    done < <(_trf_get_tags)

    if (( count == 0 )); then
        echo -e "  ${YELLOW}$(t traffic.status.empty)${NC}\n"
        echo -e "  $(t traffic.status.hint_add)\n"
    fi

    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════${NC}"
}

# ── Interactive: add/edit limit wizard ───────────────────────────────────────
_trf_add_wizard() {
    _trf_init

    # Collect available nodes from all supported protocols.
    # ports  = user-facing port (443 for Nginx-fronted nodes)
    # cports = accounting port (loopback backend port for fronted nodes)
    # ifaces = "lo" for fronted nodes so meter rules bind to loopback
    local tags=() ports=() sources=() cports=() ifaces=()
    local i=0

    echo -e "\n${BOLD}$(t traffic.wizard.available_nodes)${NC}"

    # ── Xray nodes (stats via Xray API) ──────────────────────────────────────
    {
        source "$LIB_DIR/xray/reality.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray"); cports+=("$port"); ifaces+=("")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${YELLOW}[Reality / Xray API]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$port"
            done < <(_reality_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/vision.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray"); cports+=("$port"); ifaces+=("")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${YELLOW}[Vision / Xray API]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$port"
            done < <(_vision_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/xhttp.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray"); cports+=("$port"); ifaces+=("")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${YELLOW}[XHTTP / Xray API]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$port"
            done < <(_xhttp_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/ss2022.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray"); cports+=("$port"); ifaces+=("")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${CYAN}[SS2022 / Xray API]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$port"
            done < <(_xss_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/trojan.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray"); cports+=("$port"); ifaces+=("")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${YELLOW}[Trojan / Xray API]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$port"
            done < <(_trojan_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/vmess.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray"); cports+=("$port"); ifaces+=("")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${YELLOW}[VMess / Xray API]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$port"
            done < <(_vmess_list 2>/dev/null)
    } || true
    {
        source "$LIB_DIR/xray/socks.sh" 2>/dev/null && \
            while IFS=$'\t' read -r tag port _; do
                i=$((i+1)); tags+=("$tag"); ports+=("$port"); sources+=("xray"); cports+=("$port"); ifaces+=("")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${YELLOW}[SOCKS5 / Xray API]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$port"
            done < <(_socks_list 2>/dev/null)
    } || true

    # ── Snell (stats via iptables) ────────────────────────────────────────────
    local snell_conf="/etc/snell/users/snell-main.conf"
    if [[ -f "$snell_conf" ]]; then
        local snell_port
        # grep -oP 依赖 PCRE（GNU 专有）；awk 写法在任何 POSIX 环境都一致
        snell_port=$(awk -F: '/^listen/ { gsub(/[^0-9]/,"",$NF); print $NF; exit }' "$snell_conf" 2>/dev/null || true)
        if [[ -n "$snell_port" ]]; then
            i=$((i+1)); tags+=("snell"); ports+=("$snell_port"); sources+=("iptables"); cports+=("$snell_port"); ifaces+=("")
            printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${GREEN}[Snell / iptables]${NC}\n" \
                "$i" "snell" "$(t traffic.port_label)" "$snell_port"
        fi
    fi

    # ── SS2022 / ss-rust (stats via iptables) ────────────────────────────────
    local ss_conf="/etc/ss-rust/config.json"
    if [[ -f "$ss_conf" ]]; then
        local ss_port
        ss_port=$(jq -r '.server_port // empty' "$ss_conf" 2>/dev/null || true)
        if [[ -n "$ss_port" ]]; then
            i=$((i+1)); tags+=("ss2022"); ports+=("$ss_port"); sources+=("iptables"); cports+=("$ss_port"); ifaces+=("")
            printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${GREEN}[SS2022 / iptables]${NC}\n" \
                "$i" "ss2022" "$(t traffic.port_label)" "$ss_port"
        fi
    fi

    # ── sing-box / mihomo nodes (stats via iptables port counters) ───────────
    # Node stores are the single source of truth. Direct-listen nodes are
    # metered on their public port; Nginx-fronted nodes (listen_addr=127.0.0.1)
    # are metered on their loopback backend port with lo-bound rules, while
    # users see the public 443.
    local pair store_dir core_label proto proto_label store_file tag dport cport laddr ifc
    for pair in "singbox:sing-box" "mihomo:mihomo"; do
        store_dir="$CFG_DIR/${pair%%:*}"; core_label="${pair#*:}"
        for proto in reality ss2022 hysteria2 anytls snell trojan vmess socks vless; do
            store_file="$store_dir/$proto.json"
            [[ -f "$store_file" ]] || continue
            case "$proto" in
                reality)   proto_label="Reality" ;;
                ss2022)    proto_label="SS2022" ;;
                hysteria2) proto_label="Hysteria2" ;;
                anytls)    proto_label="AnyTLS" ;;
                snell)     proto_label="Snell" ;;
                trojan)    proto_label="Trojan" ;;
                vmess)     proto_label="VMess" ;;
                socks)     proto_label="SOCKS5" ;;
                vless)     proto_label="VLESS" ;;
            esac
            while IFS=$'\t' read -r tag dport cport laddr; do
                [[ -n "$tag" && -n "$dport" ]] || continue
                ifc=""; [[ "$laddr" == "127.0.0.1" ]] && ifc="lo"
                i=$((i+1)); tags+=("$tag"); ports+=("$dport"); sources+=("iptables")
                cports+=("$cport"); ifaces+=("$ifc")
                printf "  ${CYAN}%2d.${NC} %-22s %s %-6s ${GREEN}[%s / %s / iptables]${NC}\n" \
                    "$i" "$tag" "$(t traffic.port_label)" "$dport" "$proto_label" "$core_label"
            done < <(jq -r '.[]? | select(.tag != null and .port != null)
                | [.tag, ((.public_port // .port) | tostring), (.port | tostring),
                   (.listen_addr // "")] | @tsv' "$store_file" 2>/dev/null)
        done
    done

    if (( i == 0 )); then
        log_warn "$(t traffic.wizard.no_nodes)"
        return
    fi
    echo ""

    local sel
    read -rp "$(echo -e "${CYAN}$(t traffic.wizard.select_node)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t traffic.invalid_option)"; return
    fi

    local tag="${tags[$((sel-1))]}"
    local port="${ports[$((sel-1))]}"
    local source="${sources[$((sel-1))]}"
    local cport="${cports[$((sel-1))]:-$port}"
    local iface="${ifaces[$((sel-1))]:-}"

    # Show existing config if any
    local cur_limit; cur_limit=$(_trf_get "$tag" "limit_bytes")
    local cur_reset; cur_reset=$(_trf_get "$tag" "reset_day")
    local def_limit=100
    local def_reset=1
    [[ "${cur_limit:-0}" -gt 0 ]] && def_limit=$(( cur_limit / _GB ))
    [[ -n "$cur_reset" ]] && def_reset="$cur_reset"

    local limit_gb reset_day
    ask limit_gb  "$(t traffic.ask_limit_gb)"    "$def_limit"
    ask reset_day "$(t traffic.ask_reset_day)" "$def_reset"

    if ! [[ "$limit_gb" =~ ^[0-9]+$ ]] || (( limit_gb <= 0 )); then
        log_error "$(t traffic.invalid_limit)"; return 1
    fi
    if ! [[ "$reset_day" =~ ^[0-9]+$ ]] || (( reset_day < 1 || reset_day > 28 )); then
        log_error "$(t traffic.invalid_reset_day)"; return 1
    fi

    local limit_bytes=$(( limit_gb * _GB ))
    _trf_init_tag "$tag" "$port"
    _trf_set_field "$tag" "limit_bytes" "$limit_bytes"
    _trf_set_field "$tag" "reset_day"   "$reset_day"
    _trf_set_str   "$tag" "source"      "$source"
    # "port" is what users/tgbot see; count_port is where iptables meters and
    # blocks. Identical for direct-listen nodes; for Nginx-fronted nodes
    # count_port is the 127.0.0.1 backend port and count_iface is "lo".
    _trf_set_field "$tag" "count_port"  "$cport"
    _trf_set_str   "$tag" "count_iface" "$iface"

    log_ok "$(t traffic.limit.set "$tag" "$port" "$limit_gb" "$reset_day")"
    log_info "$(t traffic.source_method "$source")"

    # Protocol-specific setup
    case "$source" in
        xray)
            if ! _trf_stats_enabled; then
                echo ""
                log_warn "$(t traffic.xray.api_not_enabled)"
                ask_yn "$(t traffic.ask_enable_xray_api)" Y && _trf_enable_stats
            fi
            ;;
        iptables)
            log_step "$(t traffic.iptables.init_rules)"
            _trf_ipt_ensure_rules "$tag" "$cport" "$iface"
            log_ok "$(t traffic.iptables.rules_ready "$IPT_CHAIN")"
            ;;
    esac

    if ! _trf_timer_active; then
        echo ""
        ask_yn "$(t traffic.ask_install_timer)" Y && _trf_install_timer
    fi

    # Optionally set an expiry date for this node
    if declare -f exp_set &>/dev/null; then
        echo ""
        if ask_yn "$(t traffic.ask_set_expiry)" N; then
            local exp_months
            ask exp_months "$(t traffic.ask_expiry_months)" "1"
            if [[ "$exp_months" =~ ^[0-9]+$ ]] && (( exp_months > 0 )); then
                local exp_date; exp_date=$(TZ="Asia/Hong_Kong" \
                    date -d "now +${exp_months} months" '+%Y-%m-%d 23:59:59')
                exp_set "$tag" "$port" "$exp_date"
                log_ok "$(t traffic.expiry_set "$exp_date")"
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
        local status; [[ "$paused" == "true" ]] && status="${RED}$(t traffic.pick.status_paused)${NC}" || status="${GREEN}$(t traffic.pick.status_running)${NC}"
        printf "  ${CYAN}%2d.${NC} %-22s %s %-6s %b\n" "$i" "$t" "$(t traffic.port_label)" "$port" "$status"
    done < <(_trf_get_tags)
    (( i == 0 )) && { log_warn "$(t traffic.pick.no_configured)"; return 1; }
    echo ""
    local sel
    read -rp "$(echo -e "${CYAN}$(t traffic.pick.prompt "$prompt")${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t traffic.invalid_option)"; return 1
    fi
    PICKED_TAG="${tags_arr[$((sel-1))]}"
}

_trf_manual_pause() {
    _trf_init
    echo -e "\n${BOLD}$(t traffic.manual.pause_title)${NC}"
    local PICKED_TAG=""
    _trf_pick_tag "$(t traffic.pick.select_node)" || return
    [[ "$(_trf_get "$PICKED_TAG" "paused")" == "true" ]] && \
        { log_warn "$(t traffic.manual.already_paused "$PICKED_TAG")"; return; }
    _trf_pause_tag "$PICKED_TAG"
}

_trf_manual_resume() {
    _trf_init
    echo -e "\n${BOLD}$(t traffic.manual.resume_title)${NC}"
    local PICKED_TAG=""
    _trf_pick_tag "$(t traffic.pick.select_node)" || return
    _trf_resume_tag "$PICKED_TAG"
}

_trf_reset_stats() {
    _trf_init
    echo -e "\n${BOLD}$(t traffic.reset.title)${NC}"

    local tags_arr=()
    local i=0
    while IFS= read -r t; do
        i=$((i+1)); tags_arr+=("$t")
        local acc; acc=$(_trf_get "$t" "accumulated_bytes"); acc="${acc:-0}"
        printf "  ${CYAN}%2d.${NC} %-22s %s\n" "$i" "$t" "$(t traffic.reset.used "$(_fmt_bytes "$acc")")"
    done < <(_trf_get_tags)
    (( i > 0 )) && printf "  ${CYAN}%2d.${NC} %s\n" "$(( i+1 ))" "$(t traffic.reset.all_option)"
    (( i == 0 )) && { log_warn "$(t traffic.pick.no_configured)"; return; }

    local sel
    read -rp "$(echo -e "${CYAN}$(t traffic.reset.choose)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return

    local reset_all=0
    (( sel == i+1 )) && reset_all=1

    if (( reset_all )); then
        ask_yn "$(t traffic.reset.ask_all)" N || return
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
        log_ok "$(t traffic.reset.all_done)"
    else
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
            log_warn "$(t traffic.invalid_option)"; return
        fi
        local tag="${tags_arr[$((sel-1))]}"
        ask_yn "$(t traffic.reset.ask_one "$tag")" N || return
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
        log_ok "$(t traffic.reset.one_done "$tag")"
    fi
}

_trf_remove_node() {
    _trf_init
    echo -e "\n${BOLD}$(t traffic.remove.title)${NC}"
    local PICKED_TAG=""
    _trf_pick_tag "$(t traffic.pick.select_node)" || return

    ask_yn "$(t traffic.remove.ask "$PICKED_TAG")" N || return

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
    log_ok "$(t traffic.remove.done "$PICKED_TAG")"
}

# ── View recent log ───────────────────────────────────────────────────────────
_trf_view_log() {
    mkdir -p "$LOG_DIR"
    if [[ ! -f "$TRAFFIC_LOG" || ! -s "$TRAFFIC_LOG" ]]; then
        log_info "$(t traffic.log.empty)"; return
    fi
    echo -e "\n${BOLD}$(t traffic.log.recent)${NC}"
    tail -30 "$TRAFFIC_LOG"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
traffic_menu() {
    _trf_init
    while true; do
        show_menu "$(t traffic.menu.title)" \
            "$(t traffic.menu.status)" \
            "$(t traffic.menu.add_edit)" \
            "$(t traffic.menu.pause)" \
            "$(t traffic.menu.resume)" \
            "$(t traffic.menu.reset)" \
            "$(t traffic.menu.remove)" \
            "$(t traffic.menu.enable_xray_api)" \
            "$(t traffic.menu.install_timer)" \
            "$(t traffic.menu.uninstall_timer)" \
            "$(t traffic.menu.view_log)" \
            "$(t traffic.menu.expiry_sep)" \
            "$(t traffic.menu.expiry_status)" \
            "$(t traffic.menu.expiry_set)"

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
                    log_warn "$(t traffic.expiry_module_not_loaded)"; press_enter ;;
            13) declare -f _exp_wizard &>/dev/null && _exp_wizard || \
                    log_warn "$(t traffic.expiry_module_not_loaded)"; press_enter ;;
            0)  return ;;
        esac
    done
}
