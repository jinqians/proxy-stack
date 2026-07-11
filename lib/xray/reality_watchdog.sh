#!/usr/bin/env bash
# xray/reality_watchdog.sh — Multi-target camouflage failover for Reality nodes
#
# Reality's "dest" is the real TLS 1.3 site Xray forwards the handshake to for
# camouflage; "server_name" (SNI) must match a certificate actually served by
# that dest. If a camouflage target gets rate-limited/blocked/goes down, the
# node's handshake starts failing or looks suspicious. This module lets a
# Reality node have several candidate (SNI, dest) pairs, periodically health-
# checks the active one, and atomically switches to a healthy candidate
# (updating both the Xray inbound and, if the node is behind Nginx SNI routing,
# the Nginx SNI map) when it stays unhealthy.
#
# Health checking is layered, because a plain server→dest TLS handshake can
# report "healthy" while real clients still cannot connect:
#
#   Layer 1  Reality listener liveness — probe the local Xray inbound
#            (127.0.0.1:port) so a dead Xray / unbound port is caught, not just
#            a dead dest. Switching camouflage targets can't fix this, so it is
#            reported as a node-wide warning rather than a switch trigger.
#
#   Layer 2  dest Reality-fitness — the server→dest TLS 1.3 handshake, now
#            additionally asserting the two hard REALITY requirements the old
#            check ignored: X25519 key exchange and (soft) h2 ALPN, plus a
#            handshake-latency ceiling. A dest that is merely reachable but not
#            a valid REALITY dest no longer counts as healthy.
#
#   Layer 3  client-vantage reachability (optional) — the server can never see
#            GFW/ISP blocking of a specific SNI on the client's path, which is
#            the most common reason a "healthy" node is unusable. If the user
#            supplies an external probe (RWD_CLIENT_PROBE), its verdict for the
#            active candidate feeds the switch decision. A passive scan of
#            Xray's error.log provides best-effort visibility without one.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"

RWD_CFG="$CFG_DIR/xray/reality_watchdog.json"
RWD_LOG="${LOG_DIR}/reality_watchdog.log"
PSM_RWD_SVC="/etc/systemd/system/psm-reality-watchdog.service"
PSM_RWD_TIMER="/etc/systemd/system/psm-reality-watchdog.timer"
RWD_FAIL_THRESHOLD=2

# Handshakes slower than this (ms) are flagged as a soft "slow" warning — a
# rate-limited/overloaded dest degrades long before it fully times out.
RWD_LATENCY_CEIL_MS=6000

# Xray error log, scanned passively for REALITY handshake rejections.
RWD_XRAY_ERROR_LOG="${RWD_XRAY_ERROR_LOG:-/var/log/xray/error.log}"

# Optional Layer 3 hook: absolute path to a user-provided executable that tests
# whether the node is actually reachable from a real client's network (i.e. from
# outside, where GFW/ISP SNI blocking is visible). Called as:
#     <probe> <tag> <server_name> <public_port>
# Exit 0 = reachable, non-zero = blocked/unreachable. Unset by default.
RWD_CLIENT_PROBE="${RWD_CLIENT_PROBE:-}"

# ── State helpers ─────────────────────────────────────────────────────────────
_rwd_init() {
    mkdir -p "$(dirname "$RWD_CFG")" "$LOG_DIR"
    [[ -f "$RWD_CFG" ]] || echo '{}' > "$RWD_CFG"
}

_rwd_load() { _rwd_init; cat "$RWD_CFG"; }
_rwd_save() { printf '%s' "$1" | jq '.' > "$RWD_CFG"; }

# Entry shape per reality tag:
# { "candidates": [{"server_name":"...", "dest":"host:port", "consec_fail":0}],
#   "active": "server_name_of_active_candidate",
#   "last_check": "...", "last_switch": "..." }
_rwd_get_entry() {
    _rwd_load | jq --arg t "$1" '.[$t] // empty'
}

_rwd_enabled_tags() { _rwd_load | jq -r 'keys[]' 2>/dev/null; }

# ── Health check: real TLS 1.3 handshake to the dest, SNI-matched ─────────────
_rwd_is_ip_literal() {
    local host="${1#[}"
    host="${host%]}"
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" == *:* ]]
}

_rwd_sni_resolves() {
    local sni="$1"
    sni="${sni%.}"
    [[ "$sni" == \*.* ]] && sni="${sni#*.}"
    [[ -z "$sni" ]] && return 1
    _rwd_is_ip_literal "$sni" && return 0

    # Plain hostnames may be intentionally local. Public FQDN-style SNI values
    # must still resolve; otherwise a local dest such as 127.0.0.1:8443 can mask
    # a deleted domain and report a false healthy state.
    [[ "$sni" != *.* ]] && return 0

    if command -v getent &>/dev/null; then
        getent ahosts "$sni" >/dev/null 2>&1 || getent hosts "$sni" >/dev/null 2>&1
        return
    fi

    if command -v dig &>/dev/null; then
        local records
        records=$(
            dig +time=3 +tries=1 +short A "$sni" 2>/dev/null
            dig +time=3 +tries=1 +short AAAA "$sni" 2>/dev/null
        )
        printf '%s\n' "$records" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'
        return
    fi

    if command -v nslookup &>/dev/null; then
        nslookup "$sni" >/dev/null 2>&1
        return
    fi

    return 0
}

_rwd_parse_dest() {
    local dest="$1"
    RWD_DEST_HOST=""
    RWD_DEST_PORT=""

    if [[ "$dest" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        RWD_DEST_HOST="${BASH_REMATCH[1]}"
        RWD_DEST_PORT="${BASH_REMATCH[2]}"
    elif [[ "$dest" == *:* && "$dest" != *:*:* ]]; then
        RWD_DEST_HOST="${dest%:*}"
        RWD_DEST_PORT="${dest##*:}"
    else
        return 1
    fi

    [[ -n "$RWD_DEST_HOST" && "$RWD_DEST_PORT" =~ ^[0-9]+$ ]]
}

_rwd_extract_leaf_cert() {
    local out_file="$1" cert_file="$2"
    awk '
        /-----BEGIN CERTIFICATE-----/ { in_cert=1 }
        in_cert { print }
        /-----END CERTIFICATE-----/ { exit }
    ' "$out_file" > "$cert_file"
    grep -q "BEGIN CERTIFICATE" "$cert_file"
}

_rwd_openssl_timed_out() {
    local rc="$1"
    [[ "$rc" == "124" ]]
}

_rwd_tls13_unsupported() {
    local out_file="$1"
    grep -Eqi "protocol version|unsupported protocol|wrong version number|no protocols available|tlsv1 alert protocol version" "$out_file"
}

_rwd_tcp_failed() {
    local out_file="$1"
    grep -Eqi "connect:errno|Connection refused|No route to host|Network is unreachable|Connection timed out|Operation timed out|Operation not permitted|Name or service not known|nodename nor servname" "$out_file"
}

_rwd_tls13_negotiated() {
    local out_file="$1"
    grep -Eq "New, TLSv1\.3|Protocol *: TLSv1\.3|Protocol version: TLSv1\.3" "$out_file"
}

# REALITY embeds its auth inside the dest handshake's X25519 key share, so the
# dest must negotiate a group that CONTAINS X25519. Modern TLS 1.3 servers
# (Cloudflare, Apple, iCloud, …) increasingly pick a post-quantum hybrid such as
# X25519MLKEM768 / X25519Kyber768 — these are fine on current Xray, because the
# hybrid still carries the X25519 component REALITY uses for auth. We therefore
# accept any group whose name contains X25519 and only reject a group that has
# no X25519 at all (e.g. pure P-256/P-384/secp*). If openssl didn't report the
# group (very old build), we can't judge — don't fail.
_rwd_x25519_negotiated() {
    local out_file="$1" line
    line=$(grep -Ei "Server Temp Key|Negotiated TLS1\.3 group" "$out_file")
    [[ -z "$line" ]] && return 0
    printf '%s\n' "$line" | grep -qi "X25519"
}

# h2 ALPN is what browsers (and thus well-behaved REALITY clients) negotiate; a
# dest that only offers http/1.1 is a weaker fingerprint. Soft signal only.
_rwd_h2_negotiated() {
    local out_file="$1"
    grep -Eqi "ALPN protocol: *h2($|[^-c])" "$out_file"
}

# Millisecond wall clock. GNU date supports %3N; fall back to whole seconds on
# builds that don't so the latency ceiling still works (coarsely).
_rwd_now_ms() {
    local t; t=$(date +%s%3N 2>/dev/null)
    [[ "$t" =~ ^[0-9]+$ ]] && { printf '%s' "$t"; return; }
    printf '%s' "$(( $(date +%s) * 1000 ))"
}

_rwd_cert_trusted() {
    local out_file="$1"
    grep -Eq "Verify return code: 0 \\(ok\\)|Verification: OK" "$out_file"
}

_rwd_cert_matches_sni() {
    local cert_file="$1" sni="$2"
    local clean_sni="${sni#[}"
    clean_sni="${clean_sni%]}"
    if _rwd_is_ip_literal "$clean_sni"; then
        openssl x509 -help 2>&1 | grep -q -- "-checkip" || return 0
        openssl x509 -in "$cert_file" -noout -checkip "$clean_sni" >/dev/null 2>&1
    else
        openssl x509 -help 2>&1 | grep -q -- "-checkhost" || return 0
        openssl x509 -in "$cert_file" -noout -checkhost "$sni" >/dev/null 2>&1
    fi
}

_rwd_s_client_tls13() {
    local connect="$1" sni="$2"
    if command -v timeout &>/dev/null; then
        timeout 8 openssl s_client -connect "$connect" -servername "$sni" \
            -tls1_3 -alpn h2,http/1.1 -showcerts
    else
        openssl s_client -connect "$connect" -servername "$sni" \
            -tls1_3 -alpn h2,http/1.1 -showcerts
    fi
}

# Layer 2. Hard failures set RWD_CHECK_REASON and return 1. On success (return
# 0) any non-fatal degradations are left in RWD_CHECK_WARN (comma-separated) and
# the handshake round-trip in RWD_CHECK_RTT_MS.
_rwd_check_dest() {
    local dest="$1" sni="$2"
    RWD_CHECK_REASON=""
    RWD_CHECK_WARN=""
    RWD_CHECK_RTT_MS=""
    if ! _rwd_sni_resolves "$sni"; then
        RWD_CHECK_REASON="sni_dns_failed"
        return 1
    fi

    if ! _rwd_parse_dest "$dest"; then
        RWD_CHECK_REASON="bad_dest"
        return 1
    fi

    local host="$RWD_DEST_HOST" port="$RWD_DEST_PORT" connect
    connect="${host}:${port}"
    [[ "$host" == *:* ]] && connect="[${host}]:${port}"

    local out_file cert_file rc start_ms end_ms
    out_file=$(mktemp) || { RWD_CHECK_REASON="tmp_failed"; return 1; }
    cert_file=$(mktemp) || { rm -f "$out_file"; RWD_CHECK_REASON="tmp_failed"; return 1; }

    start_ms=$(_rwd_now_ms)
    _rwd_s_client_tls13 "$connect" "$sni" </dev/null >"$out_file" 2>&1
    rc=$?
    end_ms=$(_rwd_now_ms)
    RWD_CHECK_RTT_MS=$(( end_ms - start_ms ))

    if _rwd_openssl_timed_out "$rc"; then
        RWD_CHECK_REASON="tls_timeout"
    elif _rwd_tcp_failed "$out_file"; then
        RWD_CHECK_REASON="tcp_failed"
    elif _rwd_tls13_unsupported "$out_file"; then
        RWD_CHECK_REASON="tls13_unsupported"
    elif ! _rwd_tls13_negotiated "$out_file"; then
        RWD_CHECK_REASON="tls13_failed"
    elif ! _rwd_x25519_negotiated "$out_file"; then
        RWD_CHECK_REASON="no_x25519"
    elif ! _rwd_extract_leaf_cert "$out_file" "$cert_file"; then
        RWD_CHECK_REASON="no_certificate"
    elif ! _rwd_cert_matches_sni "$cert_file" "$sni"; then
        RWD_CHECK_REASON="sni_cert_mismatch"
    elif ! _rwd_cert_trusted "$out_file"; then
        RWD_CHECK_REASON="cert_untrusted"
    else
        _rwd_h2_negotiated "$out_file" || RWD_CHECK_WARN+="${RWD_CHECK_WARN:+,}no_h2"
        if [[ "$RWD_CHECK_RTT_MS" =~ ^[0-9]+$ ]] && (( RWD_CHECK_RTT_MS > RWD_LATENCY_CEIL_MS )); then
            RWD_CHECK_WARN+="${RWD_CHECK_WARN:+,}slow_${RWD_CHECK_RTT_MS}ms"
        fi
        rm -f "$out_file" "$cert_file"
        return 0
    fi

    rm -f "$out_file" "$cert_file"
    return 1
}

# Layer 1. Probe the node's own Xray REALITY listener at 127.0.0.1:port. A live
# inbound accepts the TCP connection (then transparently proxies our un-authed
# hello to dest); a dead Xray or unbound port is refused at TCP. Works for both
# Nginx-routed (127.0.0.1:port) and direct (0.0.0.0:port) nodes, since loopback
# is bound in either case.
#
# We only treat a TCP-level refusal as "listener down". A slow/dead dest makes
# the TLS handshake time out or error even though Xray itself is up and
# accepting — that is Layer 2's job to catch, so it must not masquerade as a
# listener failure here.
_rwd_probe_listener() {
    local port="$1" sni="$2"
    RWD_LISTENER_REASON=""
    [[ "$port" =~ ^[0-9]+$ ]] || { RWD_LISTENER_REASON="bad_port"; return 1; }

    local out_file
    out_file=$(mktemp) || { RWD_LISTENER_REASON="tmp_failed"; return 1; }
    _rwd_s_client_tls13 "127.0.0.1:${port}" "$sni" </dev/null >"$out_file" 2>&1

    if _rwd_tcp_failed "$out_file"; then
        RWD_LISTENER_REASON="listener_down"
        rm -f "$out_file"
        return 1
    fi

    rm -f "$out_file"
    return 0
}

# Layer 3 (optional). Delegate to a user-supplied external probe that tests the
# node from a real client's vantage point. Returns non-zero (with a reason) only
# when the probe is configured AND reports the node unreachable.
_rwd_client_probe() {
    local tag="$1" sni="$2" public_port="$3"
    RWD_PROBE_REASON=""
    [[ -n "$RWD_CLIENT_PROBE" && -x "$RWD_CLIENT_PROBE" ]] || return 0
    if ! "$RWD_CLIENT_PROBE" "$tag" "$sni" "$public_port" >/dev/null 2>&1; then
        RWD_PROBE_REASON="client_probe_failed"
        return 1
    fi
    return 0
}

# Best-effort passive advisory: count recent REALITY-rejection lines in Xray's
# error log. Attribution to a specific inbound is unreliable, so this only feeds
# the log for the operator, never a switch. Echoes a count (0 if none/no log).
_rwd_recent_reality_errors() {
    [[ -r "$RWD_XRAY_ERROR_LOG" ]] || { printf '0'; return; }
    tail -n 500 "$RWD_XRAY_ERROR_LOG" 2>/dev/null \
        | grep -Eic "REALITY.*(invalid|reject|fail|forbidden)" || true
}

# ── Candidate management ───────────────────────────────────────────────────────
rwd_add_candidate() {
    local tag="$1" server_name="$2" dest="$3"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.rwd.node_not_found "$tag")"; return 1; }

    _rwd_init
    local all; all=$(_rwd_load)
    local entry; entry=$(echo "$all" | jq --arg t "$tag" '.[$t] // {"candidates":[],"active":"","last_check":"","last_switch":""}')

    # Seed with the node's current (server_name, dest) as the active candidate
    # the first time a candidate pool is created for this tag.
    if [[ "$(echo "$entry" | jq -r '.candidates | length')" == "0" ]]; then
        local cur_sn cur_dest
        cur_sn=$(echo "$node" | jq -r '.server_name')
        cur_dest=$(echo "$node" | jq -r '.dest')
        entry=$(echo "$entry" | jq --arg sn "$cur_sn" --arg d "$cur_dest" \
            '.candidates += [{"server_name":$sn,"dest":$d,"consec_fail":0}] | .active = $sn')
    fi

    entry=$(echo "$entry" | jq --arg sn "$server_name" --arg d "$dest" \
        'if ([.candidates[].server_name] | index($sn)) then . else
            .candidates += [{"server_name":$sn,"dest":$d,"consec_fail":0}]
         end')

    all=$(echo "$all" | jq --arg t "$tag" --argjson e "$entry" '.[$t] = $e')
    _rwd_save "$all"
    log_ok "$(t xray.rwd.candidate_added "$server_name" "$dest" "$tag")"
}

_rwd_ensure_node_enabled() {
    local tag="$1"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.rwd.node_not_found "$tag")"; return 1; }

    _rwd_init
    local all; all=$(_rwd_load)
    local entry; entry=$(echo "$all" | jq --arg t "$tag" '.[$t] // empty')
    [[ -n "$entry" && "$(echo "$entry" | jq -r '.candidates | length')" != "0" ]] && return 0

    local cur_sn cur_dest
    cur_sn=$(echo "$node" | jq -r '.server_name')
    cur_dest=$(echo "$node" | jq -r '.dest')
    entry=$(jq -n --arg sn "$cur_sn" --arg d "$cur_dest" \
        '{"candidates":[{"server_name":$sn,"dest":$d,"consec_fail":0}],"active":$sn,"last_check":"","last_switch":""}')

    all=$(echo "$all" | jq --arg t "$tag" --argjson e "$entry" '.[$t] = $e')
    _rwd_save "$all"
}

rwd_remove_candidate() {
    local tag="$1" server_name="$2"
    local all; all=$(_rwd_load)
    local entry; entry=$(echo "$all" | jq --arg t "$tag" '.[$t] // empty')
    [[ -z "$entry" ]] && { log_warn "$(t xray.rwd.not_enabled "$tag")"; return 1; }

    local active; active=$(echo "$entry" | jq -r '.active')
    if [[ "$active" == "$server_name" ]]; then
        log_error "$(t xray.rwd.cannot_remove_active "$server_name")"
        return 1
    fi
    entry=$(echo "$entry" | jq --arg sn "$server_name" '.candidates = [.candidates[] | select(.server_name != $sn)]')
    all=$(echo "$all" | jq --arg t "$tag" --argjson e "$entry" '.[$t] = $e')
    _rwd_save "$all"
    log_ok "$(t xray.rwd.candidate_removed "$server_name")"
}

# ── Atomic switch: update reality.json + Nginx SNI map + apply to Xray ────────
_rwd_switch_node() {
    local tag="$1" new_sn="$2" new_dest="$3"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && return 1

    local old_sn listen_addr port raw
    old_sn=$(echo "$node" | jq -r '.server_name')
    listen_addr=$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')
    port=$(echo "$node" | jq -r '.port')
    raw=$(echo "$node" | jq -r '.server_names_raw // .server_name')

    # REALITY only checks the incoming SNI against the serverNames whitelist —
    # auth for an already-connected client doesn't depend on dest matching
    # that SNI. So we accumulate rather than replace: every SNI ever handed
    # out in a client link stays valid forever, only the *new* SNI (used for
    # future links) and the camouflage dest move to the healthy candidate.
    local new_raw
    if echo ",${raw}," | grep -qF ",${new_sn},"; then
        new_raw="$raw"
    else
        new_raw="${raw},${new_sn}"
    fi

    node=$(echo "$node" | jq --arg sn "$new_sn" --arg raw "$new_raw" --arg d "$new_dest" \
        '.server_name = $sn | .server_names_raw = $raw | .dest = $d')
    _reality_upsert "$node"
    _reality_apply_all

    # Nginx-routed nodes: route the new SNI to the same backend too. The old
    # SNI's entry is left in place so previously distributed links keep working.
    if [[ "$listen_addr" == "127.0.0.1" ]]; then
        source "$LIB_DIR/nginx.sh" 2>/dev/null || true
        declare -f _sni_add_entry &>/dev/null && _sni_add_entry "$new_sn" "127.0.0.1:${port}" 2>/dev/null || true
    fi

    log_warn "$(t xray.rwd.switched "$tag" "$new_sn" "$new_dest" "$old_sn")"
}

# ── Periodic check for one node ────────────────────────────────────────────────
rwd_check_node() {
    local tag="$1"
    local all; all=$(_rwd_load)
    local entry; entry=$(echo "$all" | jq --arg t "$tag" '.[$t] // empty')
    [[ -z "$entry" ]] && return 0

    # Node was deleted from reality.json since we last ran — drop its watchdog entry.
    if [[ -z "$(_reality_get_by_tag "$tag")" ]]; then
        all=$(echo "$all" | jq --arg t "$tag" 'del(.[$t])')
        _rwd_save "$all"
        return 0
    fi

    local now; now=$(date '+%Y-%m-%d %H:%M:%S')
    local count; count=$(echo "$entry" | jq '.candidates | length')
    (( count == 0 )) && return 0

    local active; active=$(echo "$entry" | jq -r '.active')

    # Node topology: Xray listens on <port> (loopback-reachable either way);
    # clients reach it on <public_port> (443 behind Nginx, else the same port).
    local node; node=$(_reality_get_by_tag "$tag")
    local nport public_port
    nport=$(echo "$node" | jq -r '.port')
    public_port=$(echo "$node" | jq -r \
        '.public_port // (if (.listen_addr // "0.0.0.0") == "127.0.0.1" then 443 else .port end)')

    # ── Layer 2: per-candidate dest health ───────────────────────────────────
    local i active_dest_ok=0
    for (( i=0; i<count; i++ )); do
        local sn dest ok reason warn rtt
        sn=$(echo "$entry"   | jq -r ".candidates[$i].server_name")
        dest=$(echo "$entry" | jq -r ".candidates[$i].dest")
        if _rwd_check_dest "$dest" "$sn"; then
            ok=1
            reason=""
            warn="$RWD_CHECK_WARN"
            entry=$(echo "$entry" | jq ".candidates[$i].consec_fail = 0")
            [[ "$sn" == "$active" ]] && active_dest_ok=1
        else
            ok=0
            reason="${RWD_CHECK_REASON:-unknown}"
            warn=""
            entry=$(echo "$entry" | jq ".candidates[$i].consec_fail += 1")
        fi
        rtt="${RWD_CHECK_RTT_MS:-}"
        entry=$(echo "$entry" | jq --arg w "$warn" --arg r "$rtt" \
            ".candidates[$i].last_warn = \$w | .candidates[$i].last_rtt_ms = \$r")
        echo "${now} tag=${tag} sni=${sn} dest=${dest} ok=${ok}${rtt:+ rtt=${rtt}ms}${reason:+ reason=${reason}}${warn:+ warn=${warn}}" >> "$RWD_LOG"
    done
    entry=$(echo "$entry" | jq --arg now "$now" '.last_check = $now')

    # ── Layer 1: local Xray REALITY listener liveness (node-wide advisory) ────
    # Switching camouflage targets can't revive a dead Xray, so this is reported
    # for the operator rather than counted toward a switch.
    if _rwd_probe_listener "$nport" "$active"; then
        entry=$(echo "$entry" | jq '.listener_ok = true | .listener_reason = ""')
    else
        entry=$(echo "$entry" | jq --arg r "${RWD_LISTENER_REASON:-unknown}" \
            '.listener_ok = false | .listener_reason = $r')
        echo "$(t xray.rwd.log_listener_bad "$now" "$tag" "${RWD_LISTENER_REASON:-unknown}" "$nport")" >> "$RWD_LOG"
    fi

    # ── Layer 3: optional external client-vantage probe for the active SNI ────
    # The only layer that can see GFW/ISP blocking of a specific SNI on the
    # client's path. A failure counts against the active candidate (at most once
    # per cycle) so persistent client-side blocking triggers a switch.
    if ! _rwd_client_probe "$tag" "$active" "$public_port"; then
        if (( active_dest_ok == 1 )); then
            entry=$(echo "$entry" | jq --arg sn "$active" \
                '(.candidates[] | select(.server_name == $sn) | .consec_fail) += 1')
        fi
        echo "$(t xray.rwd.log_external_fail "$now" "$tag" "$active" "${RWD_PROBE_REASON:-unknown}")" >> "$RWD_LOG"
    fi

    # ── Passive advisory: recent REALITY rejections in Xray's error log ──────
    local rerr; rerr=$(_rwd_recent_reality_errors)
    if [[ "$rerr" =~ ^[0-9]+$ ]] && (( rerr > 0 )); then
        echo "$(t xray.rwd.log_recent_errors "$now" "$tag" "$rerr")" >> "$RWD_LOG"
    fi

    # Decide whether the active candidate needs replacing
    local fail
    fail=$(echo "$entry" | jq -r --arg sn "$active" '[.candidates[] | select(.server_name == $sn)][0].consec_fail // 0')

    if (( fail >= RWD_FAIL_THRESHOLD )); then
        local next; next=$(echo "$entry" | jq -r --arg sn "$active" \
            '[.candidates[] | select(.server_name != $sn and .consec_fail == 0)][0] // empty')
        if [[ -n "$next" ]]; then
            local next_sn next_dest
            next_sn=$(echo "$next"   | jq -r '.server_name')
            next_dest=$(echo "$next" | jq -r '.dest')
            _rwd_switch_node "$tag" "$next_sn" "$next_dest"
            entry=$(echo "$entry" | jq --arg sn "$next_sn" --arg now "$now" '.active = $sn | .last_switch = $now')
        else
            echo "$(t xray.rwd.log_no_backup "$now" "$tag" "$fail")" >> "$RWD_LOG"
        fi
    fi

    all=$(echo "$all" | jq --arg t "$tag" --argjson e "$entry" '.[$t] = $e')
    _rwd_save "$all"
}

# ── Periodic check for all enabled nodes (systemd timer entry point) ──────────
rwd_check_all() {
    local tag
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && rwd_check_node "$tag"
    done < <(_rwd_enabled_tags)
}

# ── Status display ─────────────────────────────────────────────────────────────
rwd_status() {
    echo -e "\n${BOLD}${BLUE}$(t xray.rwd.status_title)${NC}"
    local tags; tags=$(_rwd_enabled_tags)
    if [[ -z "$tags" ]]; then
        echo -e "  ${YELLOW}$(t xray.rwd.none_enabled)${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
        return
    fi
    local tag
    while IFS= read -r tag; do
        local entry; entry=$(_rwd_get_entry "$tag")
        local active last_check; active=$(echo "$entry" | jq -r '.active'); last_check=$(echo "$entry" | jq -r '.last_check')
        echo -e "\n  ${CYAN}$(t xray.rwd.node_last_check "$tag" "${last_check:-$(t xray.rwd.not_checked)}")${NC}"

        # Layer 1 listener health line (node-wide).
        local listener_ok listener_reason
        listener_ok=$(echo "$entry" | jq -r '.listener_ok // empty')
        listener_reason=$(echo "$entry" | jq -r '.listener_reason // ""')
        if [[ "$listener_ok" == "false" ]]; then
            echo -e "    ${RED}$(t xray.rwd.listener_bad "${listener_reason:-unknown}")${NC}"
        elif [[ "$listener_ok" == "true" ]]; then
            echo -e "    ${GREEN}$(t xray.rwd.listener_ok)${NC}"
        fi

        echo "$entry" | jq -r '.candidates[] | "\(.server_name)\t\(.dest)\t\(.consec_fail)\t\(.last_rtt_ms // "")\t\(.last_warn // "")"' \
            | while IFS=$'\t' read -r sn dest fail rtt warn; do
                local mark="  "
                [[ "$sn" == "$active" ]] && mark="${GREEN}●${NC} "
                local health
                health="${GREEN}$(t xray.rwd.healthy)${NC}"
                (( fail > 0 )) && health="${RED}$(t xray.rwd.failed_times "$fail")${NC}"
                local extra=""
                [[ -n "$rtt"  ]] && extra="${extra} ${rtt}ms"
                [[ -n "$warn" ]] && extra="${extra} ${YELLOW}[${warn}]${NC}"
                printf "    %b%-28s %-28s %b%b\n" "$mark" "$sn" "$dest" "$(echo -e "$health")" "$(echo -e "$extra")"
            done
    done <<< "$tags"
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Systemd timer ───────────────────────────────────────────────────────────────
_rwd_timer_active() { systemctl is-active --quiet psm-reality-watchdog.timer 2>/dev/null; }

_rwd_install_timer() {
    cat > "$PSM_RWD_SVC" <<EOF
[Unit]
Description=PSM Reality Camouflage-Target Watchdog
After=network.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PSM_ROOT}/manager.sh --reality-watchdog
StandardOutput=journal
StandardError=journal
EOF

    cat > "$PSM_RWD_TIMER" <<EOF
[Unit]
Description=PSM Reality Camouflage-Target Watchdog Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now psm-reality-watchdog.timer
    log_ok "$(t xray.rwd.timer_installed)"
}

_rwd_uninstall_timer() {
    systemctl disable --now psm-reality-watchdog.timer 2>/dev/null || true
    rm -f "$PSM_RWD_SVC" "$PSM_RWD_TIMER"
    systemctl daemon-reload
    log_ok "$(t xray.rwd.timer_removed)"
}

# ── Interactive wizard ───────────────────────────────────────────────────────
_rwd_pick_reality_tag() {
    _show_node_list >&2
    local tag; ask tag "$(t xray.ask.node_tag)"
    [[ -z "$(_reality_get_by_tag "$tag")" ]] && { log_error "$(t xray.node_not_found): $tag"; return 1; }
    printf '%s' "$tag"
}

rwd_setup_wizard() {
    local tag; tag=$(_rwd_pick_reality_tag) || return 1
    _rwd_ensure_node_enabled "$tag" || return 1

    log_info "$(t xray.rwd.enabled "$tag")"
    echo -e "  ${YELLOW}$(t xray.rwd.keep_old1)${NC}"
    echo -e "  ${YELLOW}$(t xray.rwd.keep_old2)${NC}"
    echo ""
    echo -e "  ${YELLOW}$(t xray.rwd.advice_title)${NC}"
    echo -e "    $(t xray.rwd.advice1)"
    echo -e "      $(t xray.rwd.advice2)"
    echo -e "      $(t xray.rwd.advice3)"
    echo -e "      ${RED}$(t xray.rwd.advice4)${NC}"
    echo -e "    $(t xray.rwd.advice5)"
    echo -e "      $(t xray.rwd.advice6)"
    echo -e "    $(t xray.rwd.advice7 "${CYAN}RWD_CLIENT_PROBE${NC}")"
    echo -e "      $(t xray.rwd.advice8)"
    echo ""

    if ask_yn "$(t xray.rwd.ask_discover_many)" Y; then
        source "$LIB_DIR/xray/sni_finder.sh"
        sni_finder_pick_many "$tag" || true   # 内部逐个 rwd_add_candidate "$tag" "$sni" "$dest"
    fi

    while ask_yn "$(t xray.rwd.ask_add_more)" Y; do
        local sn dest
        ask sn   "$(t xray.rwd.ask_sni)"
        ask dest "$(t xray.rwd.ask_dest)" "${sn}:443"
        [[ -z "$sn" || -z "$dest" ]] && { log_error "$(t xray.rwd.sni_dest_empty)"; continue; }
        rwd_add_candidate "$tag" "$sn" "$dest"
    done

    ask_yn "$(t xray.rwd.ask_enable_timer)" Y && _rwd_install_timer
    log_ok "$(t xray.rwd.setup_done)"
}

rwd_disable_node() {
    local tag; tag=$(_rwd_pick_reality_tag) || return 1
    ask_yn "$(t xray.rwd.ask_disable "$tag")" N || return
    local all; all=$(_rwd_load)
    all=$(echo "$all" | jq --arg t "$tag" 'del(.[$t])')
    _rwd_save "$all"
    log_ok "$(t xray.rwd.disabled "$tag")"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
rwd_menu() {
    while true; do
        rwd_status
        show_menu "$(t xray.rwd.menu.title)" \
            "$(t xray.rwd.menu.setup)" \
            "$(t xray.rwd.menu.remove)" \
            "$(t xray.rwd.menu.check)" \
            "$(t xray.rwd.menu.timer_on)" \
            "$(t xray.rwd.menu.timer_off)" \
            "$(t xray.rwd.menu.disable)" \
            "$(t xray.rwd.menu.logs)" \
            "$(t xray.rwd.menu.discover)" \
            "$(t xray.rwd.menu.engine)"

        case "$MENU_CHOICE" in
            1) rwd_setup_wizard; press_enter ;;
            2)
                local tag; tag=$(_rwd_pick_reality_tag) && {
                    local sn; ask sn "$(t xray.rwd.ask_remove_sni)"
                    rwd_remove_candidate "$tag" "$sn"
                }
                press_enter ;;
            3) log_step "$(t xray.rwd.checking)"; rwd_check_all; log_ok "$(t xray.rwd.check_done)"; press_enter ;;
            4) _rwd_install_timer;   press_enter ;;
            5) _rwd_uninstall_timer; press_enter ;;
            6) rwd_disable_node;     press_enter ;;
            7) [[ -f "$RWD_LOG" ]] && tail -n 50 "$RWD_LOG" || log_warn "$(t xray.rwd.no_logs)"; press_enter ;;
            8)
                local tag; tag=$(_rwd_pick_reality_tag) && {
                    source "$(dirname "${BASH_SOURCE[0]}")/sni_finder.sh"
                    _rwd_ensure_node_enabled "$tag"
                    sni_finder_pick_many "$tag" || true
                }
                press_enter ;;
            9)
                source "$(dirname "${BASH_SOURCE[0]}")/sni_finder.sh"
                _sni_setup_engine || true
                press_enter ;;
            0) return ;;
        esac
    done
}
