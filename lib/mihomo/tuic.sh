#!/usr/bin/env bash
# mihomo/tuic.sh — TUIC v5 (QUIC) listener via mihomo
#
# 节点存储（config/mihomo/tuic.json）是唯一事实源，apply 时整体重建 mihomo 的
# tuic 入站。证书可用真实域名或自签名（证书目录由 _mh_sync_safe_paths 放进
# SAFE_PATHS）。终端输出走 i18n（t mh.tuic.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

MH_TUIC_CFG="$MH_STORE_DIR/tuic.json"
MH_TUIC_DEFAULT_PORT=443

# ── State helpers ─────────────────────────────────────────────────────────────
_mh_tuic_load() { [[ -f "$MH_TUIC_CFG" ]] && jq '.' "$MH_TUIC_CFG" 2>/dev/null || echo '[]'; }
_mh_tuic_save() { mkdir -p "$(dirname "$MH_TUIC_CFG")"; printf '%s' "$1" | jq '.' > "$MH_TUIC_CFG"; }

_mh_tuic_list()      { _mh_tuic_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.insecure)"' 2>/dev/null; }
_mh_tuic_count()     { _mh_tuic_load | jq 'length' 2>/dev/null; }
_mh_tuic_get_by_tag(){ _mh_tuic_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_mh_tuic_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_mh_tuic_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _mh_tuic_save "$nodes"
}

_mh_tuic_delete() {
    local nodes; nodes=$(_mh_tuic_load)
    _mh_tuic_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_mh_tuic_select_node() {
    MH_TUIC_SEL_TAG=""
    local count; count=$(_mh_tuic_count)
    (( count == 0 )) && { log_warn "$(t mh.tuic.none)"; return 1; }
    local tags_arr=() i=0 tag port sni insec
    while IFS=$'\t' read -r tag port sni insec; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t mh.tuic.col_port) %-6s SNI %s\n" "$i" "$tag" "$port" "$sni"
    done < <(_mh_tuic_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.tuic.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t mh.invalid_option)"; return 1; fi
    MH_TUIC_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build mihomo tuic listener ────────────────────────────────────────────────
# users 是 {uuid: password} 映射（mihomo 的 TUIC v5 写法）。
# ECH is merged in when the node has keys (lib/common.sh: _mh_ech_merge)
_mh_tuic_build_listener() { _mh_tuic_build_listener_base "$1" | _mh_ech_merge "$1"; }
_mh_tuic_build_listener_base() {
    local n="$1"
    jq -n --argjson n "$n" '{
        name: $n.tag,
        type: "tuic",
        port: $n.port,
        listen: "0.0.0.0",
        users: { ($n.uuid): $n.password },
        certificate: $n.cert_path,
        "private-key": $n.key_path,
        "congestion-controller": ($n.congestion_control // "bbr"),
        alpn: ["h3"]
    }'
}

# ── Apply all TUIC nodes into mihomo config ───────────────────────────────────
_mh_tuic_apply() {
    _mh_cfg_backup
    local nodes; nodes=$(_mh_tuic_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.listeners[] | select(((.name // "") | startswith("mh-tuic-")) or (.type == "tuic")))' \
        "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        mh_add_listener "$(_mh_tuic_build_listener "$(echo "$nodes" | jq -c ".[$i]")")"
    done
    mh_test_restart
}

_mh_tuic_apply_or_revert() {
    _mh_tuic_apply && return 0
    _mh_tuic_save "$1"
    log_error "$(t mh.change_reverted)"
    return 1
}

# ── Share link (same form as sing-box, see singbox/tuic.sh) ───────────────────
_mh_tuic_link() {   # <node-json> <server>
    local n="$1" server="$2" insec
    insec=$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')
    printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=%s&udp_relay_mode=native' \
        "$(printf '%s' "$n" | jq -r '.uuid')" "$(url_encode "$(printf '%s' "$n" | jq -r '.password')")" \
        "$server" "$(printf '%s' "$n" | jq -r '.port')" "$(printf '%s' "$n" | jq -r '.sni')" \
        "$(printf '%s' "$n" | jq -r '.congestion_control // "bbr"')"
    [[ "$insec" == "1" ]] && printf '&insecure=1&allow_insecure=1'
    printf '#%s\n' "$(psm_link_label "$(printf '%s' "$n" | jq -r '.tag')" "$n")"
}

_mh_tuic_uri() {
    local tag="$1"
    local node; node=$(_mh_tuic_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.tuic.not_found "$tag")"; return 1; }

    local port uuid pass sni insec cc ip uri
    port=$(echo "$node"  | jq -r '.port')
    uuid=$(echo "$node"  | jq -r '.uuid')
    pass=$(echo "$node"  | jq -r '.password')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')
    cc=$(echo "$node"    | jq -r '.congestion_control // "bbr"')
    ip=$(get_ipv4)
    uri=$(_mh_tuic_link "$node" "$ip")

    echo -e "\n${BOLD}${GREEN}── mihomo TUIC: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t mh.tuic.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t mh.tuic.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t mh.tuic.label_port):"   "$port"
    printf "  %-12s %s\n" "UUID:"                      "$uuid"
    printf "  %-12s %s\n" "$(t mh.tuic.label_pass):"   "$pass"
    printf "  %-12s %s\n" "SNI:"                       "$sni"
    printf "  %-12s %s\n" "$(t mh.tuic.label_cc):"     "$cc"
    echo ""
    echo -e "${BOLD}$(t mh.tuic.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true

    echo -e "\n${BOLD}$(t mh.tuic.clash_label):${NC}"
    # a self-signed certificate: mihomo pins it (fingerprint) — see psm_node_pins
    local pin_yaml; pin_yaml=$(psm_pin_yaml "$node")
    [[ -n "$pin_yaml" ]] && pin_yaml=$'\n'"$pin_yaml"
    cat <<EOF
proxies:
  - name: $(psm_yaml_str "$(psm_node_label "$tag" "$node")")
    type: tuic
    server: ${ip}
    port: ${port}
    uuid: ${uuid}
    password: "${pass}"
    sni: ${sni}
    alpn: [h3]
    congestion-controller: ${cc}
    udp-relay-mode: native
    skip-cert-verify: $([[ "$insec" == "1" ]] && echo true || echo false)${pin_yaml}
EOF
}

_mh_tuic_ask_cc() {
    MH_TUIC_CC="bbr"
    echo -e "  1. bbr ($(t mh.tuic.cc_default))\n  2. cubic\n  3. new_reno"
    local c; read -rp "$(echo -e "${CYAN}$(t mh.tuic.ask_cc)${NC}")" c
    case "$c" in 2) MH_TUIC_CC="cubic" ;; 3) MH_TUIC_CC="new_reno" ;; esac
}

# ── Add node ──────────────────────────────────────────────────────────────────
mh_tuic_add_node() {
    _mh_require_installed || return
    echo -e "\n${BOLD}$(t mh.tuic.add_title)${NC}"

    local tag port uuid password domain
    ask tag  "$(t mh.tuic.ask_tag)"  "mh-tuic-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^mh-tuic- ]] || tag="mh-tuic-${tag}"
    ask port "$(t mh.tuic.ask_port)" "$MH_TUIC_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t mh.tuic.invalid_port)"; return 1
    fi
    _mh_check_port_conflict "$port" || { log_info "$(t mh.tuic.cancelled)"; return 1; }

    uuid=$(uuid_gen)
    password=$(rand_str 24)
    ask password "$(t mh.tuic.ask_pass)" "$password"

    domain=""
    if ask_yn "$(t mh.tuic.ask_has_domain)" N; then
        ask domain "$(t mh.tuic.ask_domain)"
    fi
    local tls; tls=$(_mh_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"
    _mh_tls_tuple_valid "$cert_path" "$key_path" "$sni" "$insecure" \
        || { log_error "$(t mh.tls.resolve_failed)"; return 1; }

    _mh_tuic_ask_cc

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg pass "$password" \
        --arg domain "$domain" --arg sni "$sni" --arg cert "$cert_path" --arg key "$key_path" \
        --argjson insec "$insecure" --arg cc "$MH_TUIC_CC" \
        '{tag:$tag, port:$port, uuid:$uuid, password:$pass, domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, congestion_control:$cc}')

    local _prev_store; _prev_store=$(_mh_tuic_load)
    _mh_tuic_upsert "$node_json"
    _mh_tuic_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.tuic.added "$tag" "$port")"

    ask_yn "$(t mh.tuic.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "udp"
    }
    _mh_tuic_uri "$tag"
}

# ── Modify password ───────────────────────────────────────────────────────────
mh_tuic_modify_password() {
    echo -e "\n${BOLD}$(t mh.tuic.modify_pass_title)${NC}"
    _mh_tuic_select_node || return
    local tag="$MH_TUIC_SEL_TAG"
    local node; node=$(_mh_tuic_get_by_tag "$tag")
    local pass; ask pass "$(t mh.tuic.ask_new_pass)" ""
    [[ -z "$pass" ]] && pass=$(rand_str 24)
    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    local _prev_store; _prev_store=$(_mh_tuic_load)
    _mh_tuic_upsert "$node"
    _mh_tuic_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.tuic.pass_updated "$tag")"
    _mh_tuic_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
mh_tuic_delete_node() {
    echo -e "\n${BOLD}$(t mh.tuic.del_title)${NC}"
    _mh_tuic_select_node || return
    local tag="$MH_TUIC_SEL_TAG"
    ask_yn "$(t mh.tuic.ask_confirm_del "$tag")" N || return
    local _prev_store; _prev_store=$(_mh_tuic_load)
    _mh_tuic_delete "$tag"
    _mh_tuic_apply_or_revert "$_prev_store" || return 1
    source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t mh.tuic.deleted "$tag")"
}

_mh_tuic_show_node_list() {
    local count; count=$(_mh_tuic_count)
    echo -e "\n${BOLD}mihomo TUIC:${NC}"
    if (( count == 0 )); then echo "  $(t mh.tuic.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni insec; do
        printf "  UDP %s | $(t mh.tuic.col_port): %-6s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$sni" "$tag"
    done < <(_mh_tuic_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
mh_tuic_menu() {
    _mh_require_installed || return
    while true; do
        show_menu "$(t mh.tuic.menu_title)" \
            "$(t mh.tuic.menu.add)" \
            "$(t mh.tuic.menu.view)" \
            "$(t mh.tuic.menu.pass)" \
            "$(t mh.tuic.menu.del)" \
            "$(t mh.tuic.menu.restart)"

        case "$MENU_CHOICE" in
            1) mh_tuic_add_node;  press_enter ;;
            2) _mh_tuic_select_node && _mh_tuic_uri "$MH_TUIC_SEL_TAG"; press_enter ;;
            3) mh_tuic_modify_password; press_enter ;;
            4) mh_tuic_delete_node; press_enter ;;
            5) mh_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
