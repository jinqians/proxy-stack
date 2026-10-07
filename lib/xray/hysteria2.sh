#!/usr/bin/env bash
# xray/hysteria2.sh — Hysteria2 (QUIC/UDP) inbound via Xray
#
# Xray v26.3.27 added a native Hysteria2 inbound (protocol "hysteria" with
# version 2 + the "hysteria" transport), so users who only run Xray no longer
# need the standalone hysteria binary or a second core for Hy2.
#
# The node fields deliberately match sing-box / mihomo hysteria2 nodes
# (password, sni, cert_path, key_path, insecure, obfs_pass, obfs_type), so
# `psm node` reuses the same defaults, schema and hysteria2:// export.
#
# Obfuscation lives in Xray's finalmask (not in the protocol settings):
#   salamander → {type: "salamander", settings: {password}}
#   gecko      → the same entry plus settings.packetSize ("512-1200"); Xray models
#                Gecko as Salamander with long-header fragment padding.
# Both forms, and the plain inbound, pass `xray run -test` on v26.3.27 and v26.9.9.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

XHY2_CFG="$CFG_DIR/xray/hysteria2.json"
XHY2_CERT_DIR="$CFG_DIR/xray/certs"
XHY2_DEFAULT_PORT=8443
XHY2_MIN_CORE="26.3.27"          # first Xray with the Hysteria2 inbound
XHY2_BBR_MIN_CORE="26.4.13"      # first Xray with finalmask quicParams.bbrProfile
XHY2_GECKO_PACKET_SIZE="512-1200"

# ── Node store ────────────────────────────────────────────────────────────────
_xhy2_load() { [[ -f "$XHY2_CFG" ]] || echo "[]" > "$XHY2_CFG"; cat "$XHY2_CFG"; }
_xhy2_save() { mkdir -p "$(dirname "$XHY2_CFG")"; echo "$1" > "$XHY2_CFG"; }
_xhy2_get_by_tag() { _xhy2_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }
_xhy2_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_xhy2_load)
    _xhy2_save "$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')"
}
_xhy2_delete() {
    local nodes; nodes=$(_xhy2_load)
    _xhy2_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}
_xhy2_list() {
    _xhy2_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.obfs_type // (if (.obfs_pass // "") != "" then "salamander" else "-" end))"' 2>/dev/null
}

_xhy2_show_node_list() {
    local lst; lst=$(_xhy2_list)
    if [[ -z "$lst" ]]; then log_warn "$(t xray.hy2.no_nodes)"; return; fi
    echo -e "\n${BOLD}$(t xray.hy2.nodes_title)${NC}"
    printf "  %-20s %-6s %-24s %s\n" "$(t xray.header.tag)" "$(t xray.header.port)" "SNI" "Obfs"
    echo "$lst" | while IFS=$'\t' read -r t p s o; do
        printf "  %-20s %-6s %-24s %s\n" "$t" "$p" "$s" "$o"
    done
}

# ── Core version gate ─────────────────────────────────────────────────────────
_xhy2_core_ok() {   # [minimum version, default XHY2_MIN_CORE]
    local min="${1:-$XHY2_MIN_CORE}" v; v=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {print $2}')
    [[ -n "$v" ]] && [[ "$(printf '%s\n%s\n' "$min" "$v" | sort -V | head -1)" == "$min" ]]
}

# ── TLS: a real domain certificate, or a self-signed one ─────────────────────
# Prints "cert<TAB>key<TAB>sni<TAB>insecure". Self-signed nodes put the
# certificate's SHA-256 into the share link (pinSHA256) so clients can pin it
# instead of skipping verification altogether.
_xhy2_resolve_tls() {
    local domain="$1" tag="$2"
    if [[ -n "$domain" ]]; then
        source "$LIB_DIR/cert.sh"
        cert_ensure_domain "$domain" || return 1
        printf '%s\t%s\t%s\t0\n' "$NGINX_SSL_DIR/$domain/fullchain.pem" "$NGINX_SSL_DIR/$domain/privkey.pem" "$domain"
        return 0
    fi
    mkdir -p "$XHY2_CERT_DIR"; chmod 700 "$XHY2_CERT_DIR" 2>/dev/null || true
    local crt="$XHY2_CERT_DIR/${tag}.crt" key="$XHY2_CERT_DIR/${tag}.key" sni="www.bing.com"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj "/CN=${sni}" -addext "subjectAltName=DNS:${sni}" \
        -keyout "$key" -out "$crt" >/dev/null 2>&1 || return 1
    chmod 600 "$key"
    printf '%s\t%s\t%s\t1\n' "$crt" "$key" "$sni"
}

# ── Build inbound ─────────────────────────────────────────────────────────────
_xhy2_build_inbound() {
    local n="$1"
    jq -n --argjson n "$n" --arg gecko "$XHY2_GECKO_PACKET_SIZE" '
      ($n.obfs_pass // "") as $obfs
      | ($n.obfs_type // "salamander") as $otype
      | ($n.bbr_profile // "") as $bbr
      # quicParams: the BBR profile the server sends with (Xray v26.4.13+) and
      # switching off path MTU discovery (every Xray with Hysteria2)
      | ({} + (if $bbr == "" then {} else { bbrProfile: $bbr } end)
            + (if $n.disable_pmtud == true then { disablePathMTUDiscovery: true } else {} end)) as $qp
      | {
          tag: $n.tag,
          listen: ($n.listen_addr // "0.0.0.0"),
          port: $n.port,
          protocol: "hysteria",
          settings: { version: 2, clients: [ { auth: $n.password } ] },
          streamSettings: ({
            network: "hysteria",
            hysteriaSettings: { version: 2 },
            security: "tls",
            tlsSettings: {
              alpn: ["h3"],
              certificates: [ { certificateFile: $n.cert_path, keyFile: $n.key_path } ]
            }
          } + (if $obfs == "" and ($qp | length) == 0 then {} else
                 { finalmask: ((if $obfs == "" then {} else
                     { udp: [ { type: "salamander",
                       settings: ({ password: $obfs }
                                  + (if $otype == "gecko" then { packetSize: $gecko } else {} end)) } ] } end)
                   + (if ($qp | length) == 0 then {} else { quicParams: $qp } end)) }
               end)),
          sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
        }'
}

_xhy2_apply_all() {
    local nodes; nodes=$(_xhy2_load)
    local count; count=$(echo "$nodes" | jq 'length')
    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select((.protocol // "") == "hysteria"))' "$XRAY_CFG" > "$tmp" \
        && mv "$tmp" "$XRAY_CFG"
    local i
    for ((i = 0; i < count; i++)); do
        xray_add_inbound "$(_xhy2_build_inbound "$(echo "$nodes" | jq ".[$i]")")"
    done
    xray_test_restart || return 1
    source "$LIB_DIR/hop.sh" && psm_hop_sync
}

# ── Share URI ─────────────────────────────────────────────────────────────────
# _xhy2_share_uri <node_json> <host> → hysteria2:// link (also used by psm node export)
_xhy2_share_uri() {
    local n="$1" host="$2"
    local tag pass port sni insec obfs otype q
    tag=$(echo "$n"   | jq -r '.tag');      pass=$(echo "$n"  | jq -r '.password')
    port=$(echo "$n"  | jq -r '.port');     sni=$(echo "$n"   | jq -r '.sni')
    insec=$(echo "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')
    obfs=$(echo "$n"  | jq -r '.obfs_pass // ""'); otype=$(echo "$n" | jq -r '.obfs_type // "salamander"')
    q="insecure=${insec}&sni=${sni}$(psm_pin_q "$n" pinSHA256)"
    [[ -n "$obfs" ]] && q="${q}&obfs=${otype}&obfs-password=$(url_encode "$obfs")"
    local hop; hop=$(echo "$n" | jq -r '.hop_ports // ""')
    printf 'hysteria2://%s@%s:%s?%s#PSM-%s\n' "$(url_encode "$pass")" "$host" "${port}${hop:+,$hop}" "$q" "$tag"
}

xhy2_show_share() {
    local tag="$1"
    [[ -z "$tag" ]] && { _xhy2_show_node_list; ask tag "$(t xray.ask.node_tag)"; }
    local node; node=$(_xhy2_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local uri; uri=$(_xhy2_share_uri "$node" "$(get_ipv4)") || return 1
    echo -e "\n${BOLD}${GREEN}$(t xray.hy2.share_title)${NC}"
    [[ "$(echo "$node" | jq -r '.insecure')" == "1" ]] && echo -e "  ${YELLOW}$(t xray.hy2.self_cert_hint)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Add / modify / delete ─────────────────────────────────────────────────────
xhy2_add_node() {
    _xhy2_core_ok || { log_error "$(t xray.hy2.core_too_old "$XHY2_MIN_CORE")"; return 1; }
    local count; count=$(_xhy2_load | jq 'length')
    local tag port password domain=""
    ask tag  "$(t xray.ask.node_tag)"   "xhy2-$((count + 1))"
    ask port "$(t xray.ask.local_port)" "$((XHY2_DEFAULT_PORT + count))"
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
    ask password "$(t xray.ask.password_auto)" ""
    [[ -z "$password" ]] && password=$(rand_str 24)
    ask_yn "$(t xray.hy2.ask_has_domain)" N && ask domain "$(t xray.ask.domain_required)"

    local tls cert key sni insecure
    tls=$(_xhy2_resolve_tls "$domain" "$tag") || { log_error "$(t xray.cancel_no_cert)"; return 1; }
    IFS=$'\t' read -r cert key sni insecure <<<"$tls"

    local obfs_pass="" obfs_type="salamander"
    if ask_yn "$(t xray.hy2.ask_obfs)" N; then
        ask_hy2_obfs_pass obfs_pass "$(t xray.hy2.ask_obfs_pass)"
        echo -e "  $(t xray.hy2.obfs_t1)"
        echo -e "  $(t xray.hy2.obfs_t2)"
        local oc; read -rp "$(echo -e "${CYAN}$(t xray.hy2.ask_obfs_type)${NC}")" oc
        [[ "$oc" == "2" ]] && obfs_type="gecko"
    fi

    # BBR 配置档（finalmask quicParams.bbrProfile，Xray v26.4.13+）
    local bbr_profile=""
    _xhy2_core_ok "$XHY2_BBR_MIN_CORE" && ask_hy2_bbr_profile bbr_profile
    local pmtud=""
    ask_hy2_pmtud pmtud

    local hop_ports=""
    source "$LIB_DIR/hop.sh"; ask_hy2_hop_ports hop_ports "$port" "$tag"

    local node
    node=$(jq -n --arg hop "$hop_ports" --arg tag "$tag" --argjson port "$port" --arg pass "$password" \
        --arg domain "$domain" --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        --argjson insec "$insecure" --arg obfs "$obfs_pass" --arg otype "$obfs_type" --arg bbr "$bbr_profile" \
        --arg pmtud "$pmtud" \
        '{tag:$tag, port:$port, password:$pass, domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, listen_addr:"0.0.0.0", obfs_pass:$obfs}
         | (if $obfs != "" then .obfs_type = $otype else . end)
         | (if $bbr != "" then .bbr_profile = $bbr else . end)
         | (if $pmtud == "true" then .disable_pmtud = true else . end)
         | (if $hop != "" then .hop_ports = $hop else . end)')
    local prev; prev=$(_xhy2_load)
    _xhy2_upsert "$node"
    _xhy2_apply_all || { _xhy2_save "$prev"; log_error "$(t xray.hy2.reverted)"; return 1; }
    log_ok "$(t xray.hy2.added "$tag" "$port")"
    ask_yn "$(t xray.ask.open_firewall_proto "$port" "udp")" Y && {
        source "$LIB_DIR/system.sh"; firewall_open_port "$port" "udp"
    }
    xhy2_show_share "$tag"
}

xhy2_modify_password() {
    _xhy2_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_xhy2_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local pass; ask pass "$(t xray.ask.password_auto)" ""
    [[ -z "$pass" ]] && pass=$(rand_str 24)
    local prev; prev=$(_xhy2_load)
    _xhy2_upsert "$(echo "$node" | jq --arg v "$pass" '.password = $v')"
    _xhy2_apply_all || { _xhy2_save "$prev"; log_error "$(t xray.hy2.reverted)"; return 1; }
    xhy2_show_share "$tag"
}

xhy2_delete_node() {
    _xhy2_show_node_list
    local tag; ask tag "$(t xray.ask.delete_node_tag)"
    [[ -z "$(_xhy2_get_by_tag "$tag")" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    ask_yn "$(t xray.ask.delete_node "$tag")" N || return 0
    local prev; prev=$(_xhy2_load)
    _xhy2_delete "$tag"
    _xhy2_apply_all || { _xhy2_save "$prev"; log_error "$(t xray.hy2.reverted)"; return 1; }
    rm -f "$XHY2_CERT_DIR/${tag}.crt" "$XHY2_CERT_DIR/${tag}.key"
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t xray.deleted)"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
xhy2_menu() {
    ensure_pkg_deps jq qrencode openssl
    [[ -f "$XRAY_BIN" ]] || { log_error "$(t xray.need_install)"; return 1; }
    while true; do
        show_menu "$(t xray.hy2.menu.title)" \
            "$(t xray.hy2.menu.add)" \
            "$(t xray.hy2.menu.delete)" \
            "$(t xray.hy2.menu.password)" \
            "$(t xray.hy2.menu.share)" \
            "$(t xray.hy2.menu.list)"
        case "$MENU_CHOICE" in
            1) xhy2_add_node ;;
            2) xhy2_delete_node ;;
            3) xhy2_modify_password ;;
            4) xhy2_show_share "" ;;
            5) _xhy2_show_node_list ;;
            0) return ;;
        esac
        press_enter
    done
}
