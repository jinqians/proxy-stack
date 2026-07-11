#!/usr/bin/env bash
# xray/warp.sh — Cloudflare WARP outbound: register a free WARP identity and
# wire it up as an Xray outbound (tag "out-warp"), so selected domains
# (Netflix/OpenAI/Disney+/...) can be routed through it via routing.sh.
#
# Registration talks directly to Cloudflare's WARP client API (the same one
# the official app and tools like wgcf/warp-reg.sh use) — no wgcf/warp-cli
# binary required, just curl + jq + wg (wireguard-tools, for keypair gen).

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/outbound.sh"
source "$(dirname "${BASH_SOURCE[0]}")/routing.sh"

WARP_ACCOUNT="$CFG_DIR/xray/warp_account.json"
WARP_OUTBOUND_TAG="out-warp"
_WARP_API="https://api.cloudflareclient.com/v0a2158/reg"
_WARP_CLIENT_VERSION="a-7.21-0721"
WARP_FAMILY="4"   # egress family: 4 | 6 | 46 (set by _warp_choose_family)

# ── Dependencies ────────────────────────────────────────────────────────────
_warp_ensure_deps() {
    ensure_pkg_deps curl jq
    if ! command -v wg &>/dev/null; then
        log_step "$(t xray.warp.install_wg)"
        detect_os
        # EL8/9（CentOS/Rocky/Alma/RHEL/Oracle）的 wireguard-tools 在 EPEL；
        # AL2023/Fedora 在基础仓库。ensure_epel 会按发行版正确启用。
        [[ "$PKG_MGR" == "yum" ]] && ensure_epel 2>/dev/null || true
        pkg_install wireguard-tools \
            && log_ok "$(t xray.warp.wg_installed)" \
            || { log_error "$(t xray.warp.wg_install_fail)"; return 1; }
    fi
    require_cmd wg curl jq
}

_warp_registered() {
    [[ -f "$WARP_ACCOUNT" ]] && [[ -n "$(jq -r '.secret_key // empty' "$WARP_ACCOUNT" 2>/dev/null)" ]]
}

# ── Registration ────────────────────────────────────────────────────────────
# Registers a brand-new free WARP identity and saves it to $WARP_ACCOUNT.
_warp_register() {
    _warp_ensure_deps || return 1

    log_step "$(t xray.warp.gen_keys)"
    local priv pub
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)
    [[ -z "$priv" || -z "$pub" ]] && { log_error "$(t xray.warp.key_fail)"; return 1; }

    log_step "$(t xray.warp.registering)"
    local tos body resp http_code
    tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    body=$(jq -n --arg key "$pub" --arg tos "$tos" \
        '{fcm_token:"", install_id:"", key:$key, locale:"en_US",
          model:"PC", tos:$tos, type:"Android"}')

    resp=$(curl -sL -w '\n%{http_code}' -X POST "$_WARP_API" \
        -H "CF-Client-Version: ${_WARP_CLIENT_VERSION}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: okhttp/3.12.1" \
        -d "$body" 2>/dev/null)
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [[ "$http_code" != "200" ]] || ! echo "$resp" | jq -e '.config' &>/dev/null; then
        log_error "$(t xray.warp.register_fail "$http_code")"
        echo "$resp" | jq -r '.errors[]? // .' 2>/dev/null || echo "$resp"
        return 1
    fi

    local client_id v4 v6 peer_pk endpoint_host reserved
    client_id=$(echo "$resp" | jq -r '.config.client_id')
    v4=$(echo "$resp"        | jq -r '.config.interface.addresses.v4')
    v6=$(echo "$resp"        | jq -r '.config.interface.addresses.v6 // ""')
    peer_pk=$(echo "$resp"   | jq -r '.config.peers[0].public_key')
    endpoint_host=$(echo "$resp" | jq -r '.config.peers[0].endpoint.host')
    reserved=$(echo -n "$client_id" | base64 -d 2>/dev/null | od -An -tu1 \
        | tr -s ' ' '\n' | grep -v '^$' | jq -sc '.')

    if [[ -z "$peer_pk" || -z "$v4" || "$reserved" == "[]" ]]; then
        log_error "$(t xray.warp.parse_fail)"
        return 1
    fi

    mkdir -p "$(dirname "$WARP_ACCOUNT")"
    jq -n \
        --arg secret "$priv" --arg pub "$pub" \
        --arg client_id "$client_id" --argjson reserved "$reserved" \
        --arg v4 "$v4" --arg v6 "$v6" \
        --arg peer_pk "$peer_pk" --arg endpoint "$endpoint_host" \
        --arg registered_at "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{secret_key:$secret, public_key:$pub, client_id:$client_id, reserved:$reserved,
          local_v4:$v4, local_v6:$v6, peer_public_key:$peer_pk, endpoint:$endpoint,
          registered_at:$registered_at}' > "$WARP_ACCOUNT"

    # NOTE: ${v4} here (e.g. 172.16.0.2) is the INTERNAL tunnel address Cloudflare
    # gives every free-WARP client — NOT the exit IP. The real egress IP is only
    # known once traffic flows; use "查看 WARP 实际出口 IP" to probe it.
    log_ok "$(t xray.warp.registered "$v4")"
}

# ── Egress address-family selection ──────────────────────────────────────────
_warp_family_label() {
    case "$1" in 4) t xray.warp.family.v4;; 6) t xray.warp.family.v6;; 46) t xray.warp.family.dual;; *) echo "$1";; esac
}

# Sets WARP_FAMILY to 4|6|46. WARP hands out both a v4 and v6 egress regardless
# of the box's own stack, so all three are usable everywhere — EXCEPT an
# IPv6-only box, where the entire reason to run WARP is to gain IPv4, so we pin
# v4 and don't prompt. Everyone else chooses (default = existing/IPv4).
_warp_choose_family() {
    local has4=0 has6=0
    ip -4 addr show scope global 2>/dev/null | grep -q 'inet '  && has4=1
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' && has6=1

    if (( has6 && ! has4 )); then
        WARP_FAMILY="4"
        log_info "$(t xray.warp.ipv6_only)"
        return
    fi

    local cur def=1
    cur=$(_outb_get_by_tag "$WARP_OUTBOUND_TAG" 2>/dev/null | jq -r '.family // "4"' 2>/dev/null)
    case "$cur" in 6) def=2 ;; 46) def=3 ;; esac

    echo ""
    echo -e "  ${BOLD}$(t xray.warp.choose_family)${NC}"
    echo -e "    $(t xray.warp.family_opt1)"
    echo -e "    $(t xray.warp.family_opt2)"
    echo -e "    $(t xray.warp.family_opt3)"
    local sel; read -rp "$(echo -e "${CYAN}$(t xray.warp.ask_select "$def")${NC}")" sel
    case "${sel:-$def}" in
        2) WARP_FAMILY="6" ;;
        3) WARP_FAMILY="46" ;;
        *) WARP_FAMILY="4" ;;
    esac
}

# ── Sync registered account → outbound.sh state → Xray config ───────────────
_warp_apply_outbound() {
    local family="${1:-4}"
    _warp_registered || return 1
    local acc; acc=$(cat "$WARP_ACCOUNT")
    local host port_="2408"
    local endpoint; endpoint=$(echo "$acc" | jq -r '.endpoint')
    host="${endpoint%%:*}"
    [[ "$endpoint" == *:* ]] && port_="${endpoint##*:}"

    local entry
    entry=$(echo "$acc" | jq --arg tag "$WARP_OUTBOUND_TAG" --arg host "$host" \
                             --argjson port "$port_" --arg family "$family" \
        '{tag:$tag, remark:"Cloudflare WARP", protocol:"wireguard",
          address:$host, port:$port, family:$family,
          secret_key:.secret_key, local_v4:.local_v4, local_v6:.local_v6,
          peer_public_key:.peer_public_key, reserved:.reserved}')

    _outb_upsert "$entry"
    _outb_apply_to_xray
}

# ── Default unlock routing rules ─────────────────────────────────────────────
_warp_add_default_rules() {
    local presets=("netflix" "openai" "disney" "hbo" "spotify")
    local p
    for p in "${presets[@]}"; do
        ask_yn "$(t xray.warp.ask_route "$p")" N || continue
        local id; id=$(_route_next_id)
        local entry
        entry=$(jq -n --arg id "$id" --arg remark "$(t xray.warp.rule_remark "$p")" \
                       --arg val "$p" --arg ot "$WARP_OUTBOUND_TAG" \
            '{id:$id,remark:$remark,rule_type:"geosite",value:$val,outbound_tag:$ot}')
        local rules; rules=$(_route_load)
        rules=$(echo "$rules" | jq ". += [$entry]")
        _route_save "$rules"
    done
    _route_apply_to_xray
    xray_test_restart   # unlock rules don't take effect until Xray reloads
}

# ── Interactive: one-click setup ─────────────────────────────────────────────
warp_setup() {
    _xray_require_installed || return

    if _warp_registered; then
        log_info "$(t xray.warp.already_registered "$(jq -r '.registered_at' "$WARP_ACCOUNT")")"
        ask_yn "$(t xray.warp.ask_reregister)" N && { _warp_register || return 1; }
    else
        _warp_register || return 1
    fi

    _warp_choose_family

    log_step "$(t xray.warp.writing_outbound)"
    _warp_apply_outbound "$WARP_FAMILY"
    xray_test_restart
    log_ok "$(t xray.warp.outbound_written "$WARP_OUTBOUND_TAG" "$(_warp_family_label "$WARP_FAMILY")")"

    # Prerequisite: WARP shunting only makes sense if the tunnel actually reaches
    # the public internet. Verify the real exit IP FIRST and gate everything on
    # it — no point adding unlock rules for a WARP that can't egress.
    echo ""
    if ! warp_check_exit_ip; then
        echo ""
        log_warn "$(t xray.warp.tunnel_bad1)"
        log_warn "$(t xray.warp.tunnel_bad2)"
        log_warn "$(t xray.warp.tunnel_bad3)"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}$(t xray.warp.ready_unlock)${NC}"
    _warp_add_default_rules
    log_ok "$(t xray.warp.setup_done)"
}

warp_status() {
    echo -e "\n${BOLD}${BLUE}$(t xray.warp.status_title)${NC}"
    if ! _warp_registered; then
        echo -e "  ${YELLOW}$(t xray.warp.not_registered)${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
        return
    fi
    local acc; acc=$(cat "$WARP_ACCOUNT")
    echo -e "  $(t xray.warp.registered_at "$(echo "$acc" | jq -r '.registered_at')")"
    echo -e "  $(t xray.warp.local_v4 "$(echo "$acc" | jq -r '.local_v4')" "${YELLOW}$(t xray.warp.internal_not_exit)${NC}")"
    echo -e "  $(t xray.warp.local_v6 "$(echo "$acc" | jq -r ".local_v6 // \"$(t xray.warp.none)\"")")"
    echo -e "  Endpoint ：$(echo "$acc" | jq -r '.endpoint')"

    local ob_json; ob_json=$(_outb_get_by_tag "$WARP_OUTBOUND_TAG" 2>/dev/null)
    if echo "$ob_json" | jq -e '.tag' &>/dev/null; then
        echo -e "  ${GREEN}$(t xray.warp.applied "$WARP_OUTBOUND_TAG")${NC}"
        local fam; fam=$(echo "$ob_json" | jq -r '.family // "4"')
        echo -e "  ${GREEN}$(t xray.warp.egress_family "$(_warp_family_label "$fam")")${NC}"
    else
        echo -e "  ${YELLOW}$(t xray.warp.not_applied)${NC}"
    fi

    local rule_count
    rule_count=$(_route_load | jq --arg ot "$WARP_OUTBOUND_TAG" '[.[] | select(.outbound_tag == $ot)] | length')
    echo -e "  $(t xray.warp.rule_count "$rule_count")"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

warp_remove() {
    if ! _outb_get_by_tag "$WARP_OUTBOUND_TAG" | jq -e '.tag' &>/dev/null; then
        log_warn "$(t xray.warp.not_configured)"; return
    fi
    ask_yn "$(t xray.warp.ask_remove)" N || return

    local rules; rules=$(_route_load | jq --arg ot "$WARP_OUTBOUND_TAG" '[.[] | select(.outbound_tag != $ot)]')
    _route_save "$rules"
    _route_apply_to_xray

    _outb_delete "$WARP_OUTBOUND_TAG"
    _outb_apply_to_xray
    xray_test_restart

    ask_yn "$(t xray.warp.ask_delete_identity)" N \
        && rm -f "$WARP_ACCOUNT"

    log_ok "$(t xray.warp.removed)"
}

# ── Switch egress family without re-registering ───────────────────────────────
warp_switch_family() {
    _warp_registered || { log_warn "$(t xray.warp.not_registered)"; return 1; }
    if ! _outb_get_by_tag "$WARP_OUTBOUND_TAG" | jq -e '.tag' &>/dev/null; then
        log_warn "$(t xray.warp.configure_first)"; return 1
    fi
    _warp_choose_family
    _warp_apply_outbound "$WARP_FAMILY"
    xray_test_restart
    log_ok "$(t xray.warp.family_switched "$(_warp_family_label "$WARP_FAMILY")")"
    echo ""
    ask_yn "$(t xray.warp.ask_verify)" Y && { warp_check_exit_ip || true; }
}

# ── Probe the REAL exit IP ────────────────────────────────────────────────────
# Registration only yields a WARP identity + the internal 172.16.0.x tunnel
# address — never the exit IP. Cloudflare's edge decides the egress IP only when
# traffic actually flows, so the sole way to learn it is to send a request
# through the tunnel. We stand up a throwaway Xray (socks inbound -> out-warp)
# on localhost, curl Cloudflare's trace endpoint through it, then tear it down —
# without touching the production Xray.
warp_check_exit_ip() {
    _warp_registered || { log_warn "$(t xray.warp.not_registered)"; return 1; }
    command -v curl &>/dev/null || { log_error "$(t xray.warp.no_curl)"; return 1; }

    local ob; ob=$(_outb_get_by_tag "$WARP_OUTBOUND_TAG")
    if ! echo "$ob" | jq -e '.tag' &>/dev/null; then
        log_warn "$(t xray.warp.not_configured_run_setup)"
        return 1
    fi
    local xray_ob; xray_ob=$(_outb_build_xray "$ob")
    [[ -n "$xray_ob" ]] || { log_error "$(t xray.warp.build_fail)"; return 1; }

    # Pick a free localhost port for the throwaway socks inbound.
    local port=47100
    while ss -ltnH 2>/dev/null | grep -q ":${port} "; do port=$((port+1)); done

    # IMPORTANT: manager.sh runs under `set -euo pipefail`. A failing curl (the
    # tunnel not answering) must NOT abort the whole program, so every
    # potentially-non-zero command below is guarded. We avoid a RETURN trap
    # (its locals are out of scope + unbound under `set -u` when it fires) and
    # instead clean up on a single path. Xray picks config format by extension,
    # so the temp file MUST end in .json or it errors "Failed to get format".
    local xpid="" up=0 i trace="" logtail=""
    local tmpdir tmpcfg tmplog
    tmpdir=$(mktemp -d)                 # -d is portable; named .json inside
    tmpcfg="$tmpdir/probe.json"; tmplog="$tmpdir/xray.log"

    jq -n --argjson ob "$xray_ob" --argjson port "$port" '{
        log: {loglevel:"warning"},
        inbounds:  [{tag:"probe", listen:"127.0.0.1", port:$port,
                     protocol:"socks", settings:{udp:true}}],
        outbounds: [$ob]
    }' > "$tmpcfg"

    log_step "$(t xray.warp.probing)"
    "$XRAY_BIN" run -c "$tmpcfg" >"$tmplog" 2>&1 &
    xpid=$!

    # Wait (max ~6s) for the throwaway Xray's socks port to actually listen.
    for _ in $(seq 1 12); do
        kill -0 "$xpid" 2>/dev/null || break          # xray died on startup
        if ss -ltnH 2>/dev/null | grep -q "127.0.0.1:${port} "; then up=1; break; fi
        sleep 0.5
    done

    # If it came up, give the WireGuard handshake a moment, then probe.
    # socks5h → resolve the hostname through the proxy. Try two endpoints.
    if (( up )); then
        sleep 2
        trace=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:${port}" \
            "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null) || true
        if [[ -z "$trace" ]]; then
            trace=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:${port}" \
                "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null) || true
        fi
    fi

    # Single cleanup path: stop the throwaway Xray, keep its log tail, remove temps.
    kill "$xpid" 2>/dev/null || true
    wait "$xpid" 2>/dev/null || true
    logtail=$(tail -n 8 "$tmplog" 2>/dev/null) || true
    rm -rf "$tmpdir"

    if (( ! up )); then
        log_error "$(t xray.warp.temp_start_fail "$port")"
        echo -e "${YELLOW}$(t xray.warp.xray_output)${NC}"
        sed 's/^/    /' <<<"$logtail"
        return 1
    fi

    if [[ -z "$trace" ]]; then
        log_error "$(t xray.warp.probe_fail)"
        echo -e "${YELLOW}$(t xray.warp.common_reasons)${NC}"
        echo -e "${YELLOW}$(t xray.warp.xray_output)${NC}"
        sed 's/^/    /' <<<"$logtail"
        return 1
    fi

    local exit_ip loc warp_state
    exit_ip=$(awk -F= '/^ip=/{print $2}'   <<<"$trace")
    loc=$(awk -F= '/^loc=/{print $2}'      <<<"$trace")
    warp_state=$(awk -F= '/^warp=/{print $2}' <<<"$trace")

    echo ""
    echo -e "${BOLD}${BLUE}$(t xray.warp.exit_title)${NC}"
    echo -e "  ${GREEN}$(t xray.warp.exit_ip "${exit_ip:-$(t xray.warp.unknown)}")${NC}"
    echo -e "  $(t xray.warp.exit_loc "${loc:-$(t xray.warp.unknown)}")"
    if [[ "$warp_state" == "on" || "$warp_state" == "plus" ]]; then
        echo -e "  ${GREEN}$(t xray.warp.state_on "$warp_state")${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
        return 0
    fi
    # Got a public IP but warp=off → traffic reached the internet WITHOUT the
    # tunnel. WARP is not actually carrying traffic, so this counts as a failure.
    echo -e "  ${YELLOW}$(t xray.warp.state_off "${warp_state:-off}")${NC}"
    echo -e "  ${YELLOW}$(t xray.warp.off_hint)${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
    return 1
}

# ── Menu ──────────────────────────────────────────────────────────────────────
warp_menu() {
    _xray_require_installed || return
    while true; do
        warp_status
        show_menu "$(t xray.warp.menu.title)" \
            "$(t xray.warp.menu.setup)" \
            "$(t xray.warp.menu.check)" \
            "$(t xray.warp.menu.switch)" \
            "$(t xray.warp.menu.rules)" \
            "$(t xray.warp.menu.routing)" \
            "$(t xray.warp.menu.remove)"

        case "$MENU_CHOICE" in
            1) warp_setup;             press_enter ;;
            2) warp_check_exit_ip;     press_enter ;;
            3) warp_switch_family;     press_enter ;;
            4)
                if _outb_get_by_tag "$WARP_OUTBOUND_TAG" | jq -e '.tag' &>/dev/null; then
                    _warp_add_default_rules
                else
                    log_warn "$(t xray.warp.configure_first)"
                fi
                press_enter ;;
            5) route_show;             press_enter ;;
            6) warp_remove;            press_enter ;;
            0) return ;;
        esac
    done
}
