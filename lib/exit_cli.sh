#!/usr/bin/env bash
# exit_cli.sh — the WARP and free residential (VPNGate) exits without
# questions: `psm exit status|warp|vpngate`, and the per-node exit rules that
# `psm node add|update --exit …` writes (the PSM panel's 出口分流).
#
# A node's exit is one routing rule in its core: what came in on that node's
# inbound (its tag) and matches the chosen sites — or all of it — leaves
# through WARP or the residential tunnel; everything else goes out directly as
# before. The rule carries the node's tag (.node), so updating or deleting the
# node rewrites or removes exactly that rule. The outbounds are the menus' own
# (out-warp / warp-out, out-vpngate / vpngate-out), shared by every node.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# The panel's basic choices, as geosite lists (checked against sing-geosite,
# Xray's and mihomo's geosite data).
EXIT_PRESET_AI="openai,anthropic,google-gemini"
EXIT_PRESET_STREAMING="netflix,disney,hbo,primevideo,spotify"
EXIT_WARP_FAMILY="${EXIT_WARP_FAMILY:-4}"
EXIT_VPNGATE_COUNTRY="${EXIT_VPNGATE_COUNTRY:-JP}"

_exit_err() { printf 'psm exit: %s\n' "$*" >&2; }

# <sites> → a geosite list, or nothing for all traffic.
# sites: all | ai | streaming | geosite names, comma-separated and mixed.
exit_sites_geosite() {
    local s="$1" out="" part
    [[ -z "$s" || "$s" == all ]] && return 0
    local -a parts
    IFS=',' read -ra parts <<<"$s"
    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"
        case "$part" in
            "") ;;
            ai) out+=",$EXIT_PRESET_AI" ;;
            streaming) out+=",$EXIT_PRESET_STREAMING" ;;
            *) [[ "$part" =~ ^[a-z0-9][a-z0-9!@._-]{0,63}$ ]] || { _exit_err "not a geosite name: $part"; return 1; }
               out+=",$part" ;;
        esac
    done
    printf '%s' "${out#,}" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

_exit_target() {   # <core> <warp|vpngate> → the outbound's tag in that core
    case "$1/$2" in
        xray/warp|sing-box/warp) printf out-warp ;;
        mihomo/warp) printf warp-out ;;
        xray/vpngate|sing-box/vpngate) printf out-vpngate ;;
        mihomo/vpngate) printf vpngate-out ;;
        *) return 1 ;;
    esac
}

_exit_load_core() {   # <core>: its routing module
    case "$1" in
        xray)     source "$LIB_DIR/xray/routing.sh" ;;
        sing-box) source "$LIB_DIR/singbox/routing.sh" ;;
        mihomo)   source "$LIB_DIR/mihomo/routing.sh" ;;
        *) _exit_err "unknown core: $1"; return 1 ;;
    esac
}

# ── WARP ─────────────────────────────────────────────────────────────────────
# One WARP identity for the server (registered once, as the menus do), and
# its outbound in <core>.
exit_warp_ensure() {   # <core>
    local core="$1"
    source "$LIB_DIR/xray/warp.sh"   # _warp_register, WARP_ACCOUNT (shared by the three cores)
    if ! _warp_registered; then
        _warp_register >&2 || { _exit_err "WARP registration with Cloudflare failed"; return 1; }
    fi
    _exit_load_core "$core" || return 1
    case "$core" in
        xray)
            _outb_load | jq -e --arg t "$WARP_OUTBOUND_TAG" 'any(.[]; .tag == $t)' >/dev/null 2>&1 && return 0
            _warp_apply_outbound "$EXIT_WARP_FAMILY" >&2 && xray_test_restart >&2 \
                || { _exit_err "Xray did not take the WARP outbound"; return 1; }
            ;;
        sing-box)
            _sb_outb_load | jq -e 'any(.[]; .tag == "out-warp")' >/dev/null 2>&1 && return 0
            local prev; prev=$(_sb_outb_load)
            _sb_outb_upsert "$(jq -nc --arg f "$EXIT_WARP_FAMILY" '{tag:"out-warp", remark:"WARP", protocol:"warp", family:$f}')"
            _sb_route_apply >&2 || { _sb_outb_save "$prev"; _exit_err "sing-box did not take the WARP outbound"; return 1; }
            ;;
        mihomo)
            _mh_route_outbounds | jq -e 'any(.[]; .name == "warp-out")' >/dev/null 2>&1 && return 0
            local acc="$MH_WARP_ACCOUNT" endpoint host port entry prev
            endpoint=$(jq -r '.endpoint // "engage.cloudflareclient.com:2408"' "$acc")
            host="${endpoint%%:*}"; port="${endpoint##*:}"; [[ "$port" =~ ^[0-9]+$ ]] || port=2408
            entry=$(jq -c --arg host "$host" --argjson port "$port" '
                {name:"warp-out", remark:"WARP", type:"wireguard", server:$host, port:$port, family:"4",
                 "private-key":(.secret_key // .private_key), "public-key":.peer_public_key,
                 reserved:(.reserved // [0,0,0]), mtu:1280, ip:((.local_v4 // "172.16.0.2") + "/32")}' "$acc")
            prev=$(_mh_route_load)
            _mh_outb_upsert "$entry"
            _mh_route_apply >&2 || { _mh_route_save "$prev"; _exit_err "mihomo did not take the WARP outbound"; return 1; }
            ;;
    esac
}

# ── The residential exit (VPNGate) ───────────────────────────────────────────
# One tunnel per server (lib/vpngate/): made the first time, in <country>,
# from a residential or mobile line; a tunnel that is already up is kept,
# whatever its country. The watchdog that moves it to another line when one
# goes away is switched on with it, as the menu does.
exit_vpngate_ensure() {   # <core> [country]
    local core="$1" cc="${2:-$EXIT_VPNGATE_COUNTRY}" vcore
    [[ "$cc" =~ ^[A-Z]{2}$ ]] || { _exit_err "country must be a two-letter code (JP, KR, US …): $cc"; return 1; }
    source "$LIB_DIR/vpngate.sh"
    vcore="$core"; [[ "$core" == sing-box ]] && vcore=singbox
    _exit_load_core "$core" || return 1
    if ! { vg_tun_installed && vg_tun_dev_up && _vg_tun_route_ready; }; then
        _vg_ensure_openvpn >&2 || { _exit_err "openvpn is not available (and /dev/net/tun is needed)"; return 1; }
        vg_scan "$cc" 1 >&2 || { _exit_err "no residential VPNGate line in $cc right now; try another country"; return 1; }
        vg_connect_best 3 >&2 || { _exit_err "none of the VPNGate lines in $cc answered; try again or another country"; return 1; }
        vg_watchdog_enabled || vg_watchdog_enable >&2
    fi
    vg_is_bound "$vcore" || vg_bind_core "$vcore" >&2 || { _exit_err "$core did not take the residential outbound"; return 1; }
}

exit_ensure() {   # <core> <warp|vpngate> [country]
    case "$2" in
        warp) exit_warp_ensure "$1" ;;
        vpngate) exit_vpngate_ensure "$1" "${3:-}" ;;
        *) _exit_err "unknown exit: $2 (warp, vpngate)"; return 1 ;;
    esac
}

# ── Per-node rules ───────────────────────────────────────────────────────────
_exit_rules_load() {   # <core>
    case "$1" in
        xray) _route_load ;;
        sing-box) _sb_route_load ;;
        mihomo) _mh_route_rules ;;
    esac
}
_exit_rules_save() {   # <core> <rules json>
    case "$1" in
        xray) _route_save "$2" ;;
        sing-box) _sb_route_save "$2" ;;
        mihomo) _mh_route_save "$(_mh_route_load | jq --argjson r "$2" '.rules = $r')" ;;
    esac
}
_exit_rules_apply() {   # <core>
    case "$1" in
        xray) _route_apply_to_xray >&2 && xray_test_restart >&2 ;;
        sing-box) _sb_route_apply >&2 ;;
        mihomo) _mh_route_apply >&2 ;;
    esac
}

# Whether <core> has an exit rule for node <tag> (without loading the core's modules).
exit_node_has() {   # <core> <tag>
    local f
    case "$1" in
        xray) f="$CFG_DIR/xray/routing_rules.json" ;;
        sing-box) f="$CFG_DIR/singbox/routing_rules.json" ;;
        mihomo) f="$CFG_DIR/mihomo/routing.json" ;;
        *) return 1 ;;
    esac
    [[ -s "$f" ]] && jq -e --arg t "$2" '[(if type == "object" then .rules else . end)[]? | select(.node == $t)] | length > 0' "$f" >/dev/null 2>&1
}

# Point node <tag>'s traffic at an exit (after exit_ensure), or at none.
exit_node_set() {   # <core> <tag> <warp|vpngate|""> [sites]
    local core="$1" tag="$2" exit="$3" sites="${4:-}" geo="" target rules id entry prev
    _exit_load_core "$core" || return 1
    if [[ -n "$exit" ]]; then
        geo=$(exit_sites_geosite "$sites") || return 1
        target=$(_exit_target "$core" "$exit") || { _exit_err "unknown exit: $exit"; return 1; }
    fi
    prev=$(_exit_rules_load "$core")
    rules=$(jq -c --arg t "$tag" '[.[] | select(.node != $t)]' <<<"$prev") || return 1
    if [[ -n "$exit" ]]; then
        case "$core" in
            xray) id=$(_route_next_id) ;;
            sing-box) id=$(_sb_route_next_id) ;;
            mihomo) id=$(_mh_route_next_id) ;;
        esac
        # first in the list: a node's own exit goes before the core-wide rules
        entry=$(jq -nc --arg id "$id" --arg t "$tag" --arg g "$geo" --arg ot "$target" --arg core "$core" '
            { id: $id, remark: ("node " + $t + " → " + $ot), node: $t, geosite: $g }
            + (if $core == "mihomo" then {kind: "in-name", value: $t, target: $ot}
               elif $core == "sing-box" then {rule_type: "inbound", value: $t, target: $ot}
               else {rule_type: "inbound", value: $t, outbound_tag: $ot} end)')
        rules=$(jq -c --argjson e "$entry" '[$e] + .' <<<"$rules") || return 1
    fi
    jq -e --argjson a "$prev" --argjson b "$rules" -n '$a == $b' >/dev/null && return 0
    _exit_rules_save "$core" "$rules"
    if ! _exit_rules_apply "$core"; then
        _exit_rules_save "$core" "$prev"; _exit_rules_apply "$core" >/dev/null 2>&1 || true
        _exit_err "$core did not take the exit rule for $tag; nothing changed"
        return 1
    fi
}

# ── The menus' per-node exit ─────────────────────────────────────────────────
# What `psm node add --exit …` writes from the command line, offered as one
# entry in each core's menu: pick one of that core's nodes, then its exit and
# what goes through it. It ends in exit_node_set, the very function the command
# line and the panel use, so a node set up here is the same thing — and an
# existing node can be changed, or its exit cleared, the same way.

# <core> <tag> → "<target>\t<sites>" when that node has an exit rule.
_exit_menu_rule_of() {
    local f
    case "$1" in
        xray) f="$CFG_DIR/xray/routing_rules.json" ;;
        sing-box) f="$CFG_DIR/singbox/routing_rules.json" ;;
        mihomo) f="$CFG_DIR/mihomo/routing.json" ;;
        *) return 1 ;;
    esac
    [[ -s "$f" ]] || return 0
    jq -r --arg t "$2" '
        [(if type == "object" then .rules else . end)[]? | select(.node == $t)][0]
        | if . == null then empty
          else ((.target // .outbound_tag // "?") + " " + ((.geosite // "") | if . == "" then "all" else . end))
          end' "$f" 2>/dev/null
}

exit_menu_node() {   # <core>
    local core="$1" nodes count sel tag ex scope sites cc cur i=0
    local -a _tags
    source "$LIB_DIR/node_cli.sh"
    nodes=$(_node_cli_collect "$core" "") || return 1
    count=$(printf '%s' "$nodes" | jq 'length' 2>/dev/null || echo 0)
    (( count == 0 )) && { log_warn "$(t exm.none)"; return 0; }

    echo -e "\n${BOLD}${BLUE}══ $(t exm.title) ════════════════${NC}"
    local p tg po
    while IFS=$'\t' read -r p tg po; do
        i=$((i+1)); _tags+=("$tg")
        cur=$(_exit_menu_rule_of "$core" "$tg")
        if [[ -n "$cur" ]]; then
            printf "  ${CYAN}%2d.${NC} %-12s %-22s port=%-6s ${GREEN}%s${NC}\n" "$i" "[$p]" "$tg" "$po" "$cur"
        else
            printf "  ${CYAN}%2d.${NC} %-12s %-22s port=%-6s ${YELLOW}%s${NC}\n" "$i" "[$p]" "$tg" "$po" "$(t exm.no_exit)"
        fi
    done < <(printf '%s' "$nodes" | jq -r '.[] | [.protocol, .tag, (.port // "-")] | @tsv')
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"

    read -rp "$(echo -e "${CYAN}$(t exm.ask_node): ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t exm.invalid)"; return 0
    fi
    tag="${_tags[$((sel-1))]}"

    echo ""
    echo -e "${BOLD}$(t exm.exit_title "$tag")${NC}"
    echo "  $(t exm.exit0)"
    echo "  $(t exm.exit1)"
    echo "  $(t exm.exit2)"
    read -rp "$(echo -e "${CYAN}$(t exm.ask_exit)${NC}")" ex
    case "${ex:-0}" in
        0) if exit_node_set "$core" "$tag" ""; then log_ok "$(t exm.cleared "$tag")"; else log_error "$(t exm.fail)"; return 1; fi
           return 0 ;;
        1) ex=warp ;;
        2) ex=vpngate ;;
        *) log_warn "$(t exm.invalid)"; return 0 ;;
    esac

    echo ""
    echo -e "${BOLD}$(t exm.scope_title)${NC}"
    echo "  $(t exm.scope1)"
    echo "  $(t exm.scope2)"
    echo "  $(t exm.scope3)"
    echo "  $(t exm.scope4)"
    echo "  $(t exm.scope5)"
    read -rp "$(echo -e "${CYAN}$(t exm.ask_scope)${NC}")" scope
    case "${scope:-1}" in
        1) sites=ai ;;
        2) sites=streaming ;;
        3) sites="ai,streaming" ;;
        4) sites=all ;;
        5) ask sites "$(t exm.ask_geosite)" ""
           [[ -n "$sites" ]] || { log_warn "$(t exm.invalid)"; return 0; } ;;
        *) log_warn "$(t exm.invalid)"; return 0 ;;
    esac
    exit_sites_geosite "$sites" >/dev/null || return 1

    cc=""
    if [[ "$ex" == vpngate ]]; then
        ask cc "$(t exm.ask_country)" "$EXIT_VPNGATE_COUNTRY"
        cc="${cc^^}"
        [[ "$cc" =~ ^[A-Z]{2}$ ]] || { _exit_err "country must be a two-letter code (JP, KR, US …): $cc"; return 1; }
    fi

    log_info "$(t exm.preparing)"
    exit_ensure "$core" "$ex" "$cc" || { log_error "$(t exm.fail)"; return 1; }
    exit_node_set "$core" "$tag" "$ex" "$sites" || { log_error "$(t exm.fail)"; return 1; }
    log_ok "$(t exm.done "$tag" "$sites" "$ex")"
}

# ── The menus' node editor ───────────────────────────────────────────────────
# What `psm node update` does from the command line, offered as one entry in
# each core's menu: pick one of that core's nodes, then the field to change.
# The protocols' own menus only ever offered a subset (AnyTLS could change its
# password but not its port; Hysteria2, TUIC, VLESS and WireGuard on sing-box
# and mihomo offered nothing at all), so a node made in the menus could not be
# edited there. This ends in _node_cli_cmd_update, the same code path the
# command line and the panel use, so every core and protocol behaves alike.

# <core> <proto> → the fields worth offering, as "option<TAB>label" lines.
_node_menu_fields() {
    local core="$1" proto="$2"
    printf 'display-name\t%s\n' "$(t nme.f.display_name)"
    printf 'port\t%s\n' "$(t nme.f.port)"
    case "$proto" in
        reality)
            printf 'uuid\t%s\nserver-name\t%s\ndest\t%s\nshort-ids\t%s\n' \
                "$(t nme.f.uuid)" "$(t nme.f.server_name)" "$(t nme.f.dest)" "$(t nme.f.short_ids)" ;;
        vision|xhttp|vmess|vless)
            printf 'uuid\t%s\ndomain\t%s\n' "$(t nme.f.uuid)" "$(t nme.f.domain)" ;;
        anytls|trojan|hysteria2|snell)
            printf 'password\t%s\nsni\t%s\n' "$(t nme.f.password)" "$(t nme.f.sni)" ;;
        tuic)
            printf 'uuid\t%s\npassword\t%s\nsni\t%s\n' "$(t nme.f.uuid)" "$(t nme.f.password)" "$(t nme.f.sni)" ;;
        ss2022)
            printf 'password\t%s\n' "$(t nme.f.password)" ;;
        socks)
            printf 'username\t%s\npassword\t%s\n' "$(t nme.f.username)" "$(t nme.f.password)" ;;
    esac
    printf 'public-port\t%s\n' "$(t nme.f.public_port)"
}

node_menu_edit() {   # <core>
    local core="$1" nodes count sel i=0 tag proto opt label value
    local -a _tags _protos _opts
    source "$LIB_DIR/node_cli.sh"
    nodes=$(_node_cli_collect "$core" "") || return 1
    count=$(printf '%s' "$nodes" | jq 'length' 2>/dev/null || echo 0)
    (( count == 0 )) && { log_warn "$(t nme.none)"; return 0; }

    echo -e "\n${BOLD}${BLUE}══ $(t nme.title) ════════════════${NC}"
    local p tg po dn
    while IFS=$'\t' read -r p tg po dn; do
        i=$((i+1)); _tags+=("$tg"); _protos+=("$p")
        printf "  ${CYAN}%2d.${NC} %-12s %-22s port=%s%s\n" "$i" "[$p]" "$tg" "$po" "${dn:+  $dn}"
    done < <(printf '%s' "$nodes" | jq -r '.[] | [.protocol, .tag, (.port // "-"), (.node.display_name // "")] | @tsv')
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"

    read -rp "$(echo -e "${CYAN}$(t nme.ask_node): ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then log_warn "$(t nme.invalid)"; return 0; fi
    tag="${_tags[$((sel-1))]}"; proto="${_protos[$((sel-1))]}"

    echo ""
    echo -e "${BOLD}$(t nme.field_title "$tag")${NC}"
    i=0
    while IFS=$'\t' read -r opt label; do
        i=$((i+1)); _opts+=("$opt")
        printf "  ${CYAN}%2d.${NC} %s\n" "$i" "$label"
    done < <(_node_menu_fields "$core" "$proto")
    printf "  ${CYAN} 0.${NC} %s\n" "$(t common.back_exit)"
    read -rp "$(echo -e "${CYAN}$(t nme.ask_field): ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then log_warn "$(t nme.invalid)"; return 0; fi
    opt="${_opts[$((sel-1))]}"

    echo ""
    echo -e "  $(t nme.blank_hint)"
    [[ "$opt" == display-name ]] && echo -e "  $(t nme.dn_hint "$(psm_node_label "$tag")")"
    ask value "$(t nme.ask_value "$opt")" ""
    # Nothing typed: leave the node alone. An empty value would be written as an
    # empty field — a node with no password — rather than meaning "keep it".
    [[ -n "$value" ]] || { log_info "$(t nme.unchanged)"; return 0; }
    [[ "$opt" == display-name && "$value" == "-" ]] && value=""   # back to the flag and tag
    # Positional core/protocol/tag: _node_cli_cmd_update reads its target that
    # way, and takes the tag from $1 only when it is not an option.
    if _node_cli_cmd_update "$core" "$proto" "$tag" "--$opt" "$value"; then
        log_ok "$(t nme.done "$tag" "$opt")"
    else
        log_error "$(t nme.fail)"
        return 1
    fi
}

# ── psm exit ─────────────────────────────────────────────────────────────────
_exit_cli_usage() {
    cat <<'EOF'
Usage:
  psm exit status [--json]
  psm exit warp --core xray|sing-box|mihomo [--json]
  psm exit vpngate --core xray|sing-box|mihomo [--country CC] [--json]

`warp` registers a free Cloudflare WARP identity (once per server) and adds
its outbound to the core; `vpngate` connects the free residential tunnel
(VPNGate, a residential or mobile line in country CC, default JP; kept while
it is up, moved to another line by its watchdog) and adds its outbound.
Neither routes anything by itself: a node does, with
  psm node add|update … --exit warp|vpngate [--exit-sites all|ai|streaming|GEOSITE,…] [--exit-country CC]
EOF
}

_exit_status_json() {
    local warp_reg=false vg='{}' cores='{}' c
    [[ -s "$CFG_DIR/xray/warp_account.json" ]] && jq -e '.secret_key // empty' "$CFG_DIR/xray/warp_account.json" >/dev/null 2>&1 && warp_reg=true
    if [[ -f "$LIB_DIR/vpngate.sh" ]]; then
        vg=$( ( source "$LIB_DIR/vpngate.sh" >/dev/null 2>&1
                up=false; vg_tun_installed && vg_tun_dev_up && _vg_tun_route_ready && up=true
                jq -nc --argjson installed "$(vg_tun_installed && echo true || echo false)" --argjson up "$up" \
                    --arg country "$(vg_state_get '.active.country' 2>/dev/null)" --arg ip "$(vg_state_get '.active.ip' 2>/dev/null)" \
                    '{installed: $installed, up: $up, country: ($country | select(. != "null")), ip: ($ip | select(. != "null"))}' ) 2>/dev/null || echo '{}')
    fi
    for c in xray sing-box mihomo; do
        local f n=0
        case "$c" in
            xray) f="$CFG_DIR/xray/routing_rules.json" ;;
            sing-box) f="$CFG_DIR/singbox/routing_rules.json" ;;
            mihomo) f="$CFG_DIR/mihomo/routing.json" ;;
        esac
        [[ -s "$f" ]] && n=$(jq '[(if type == "object" then .rules else . end)[]? | select(.node != null)] | length' "$f" 2>/dev/null || echo 0)
        cores=$(jq -c --arg c "$c" --argjson n "${n:-0}" '. + {($c): {node_rules: $n}}' <<<"$cores")
    done
    jq -nc --argjson w "$warp_reg" --argjson vg "$vg" --argjson cores "$cores" \
        '{warp: {registered: $w}, vpngate: $vg, cores: $cores}'
}

psm_exit_cli() {
    local cmd="${1:-}"; shift || true
    local core="" cc="" as_json=0
    while (( $# )); do
        case "$1" in
            --core) core="${2:-}"; [[ "$core" == singbox ]] && core=sing-box; shift 2 ;;
            --country) cc="${2:-}"; shift 2 ;;
            --json) as_json=1; shift ;;
            *) _exit_err "unknown option: $1"; return 2 ;;
        esac
    done
    exec </dev/null
    case "$cmd" in
        status)
            if (( as_json )); then _exit_status_json
            else _exit_status_json | jq -r '"WARP: \(if .warp.registered then "registered" else "not registered" end)",
                "Residential (VPNGate): \(if .vpngate.up then "up, \(.vpngate.country // "?") \(.vpngate.ip // "")" elif .vpngate.installed then "installed, down" else "not set up" end)",
                (.cores | to_entries[] | "  \(.key): \(.value.node_rules) node exit rule(s)")'; fi
            ;;
        warp|vpngate)
            [[ "$core" == xray || "$core" == sing-box || "$core" == mihomo ]] || { _exit_err "--core xray|sing-box|mihomo is required"; return 2; }
            [[ $EUID -eq 0 ]] || { _exit_err "must run as root"; return 1; }
            exit_ensure "$core" "$cmd" "$cc" || return 1
            if (( as_json )); then _exit_status_json; else printf 'ok: %s exit ready in %s\n' "$cmd" "$core"; fi
            ;;
        help|--help|-h|"") _exit_cli_usage ;;
        *) _exit_err "unknown command: $cmd"; _exit_cli_usage >&2; return 2 ;;
    esac
}
