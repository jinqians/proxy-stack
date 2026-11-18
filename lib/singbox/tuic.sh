#!/usr/bin/env bash
# singbox/tuic.sh — TUIC v5 (QUIC) inbound via sing-box
#
# 节点存储（config/singbox/tuic.json）是唯一事实源，apply 时整体重建 sing-box 的
# tuic 入站。与 Hysteria2 同为 QUIC/UDP：证书可用真实域名或自签名，客户端用
# uuid + password 认证。终端输出走 i18n（t sb.tuic.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_TUIC_CFG="$SB_STORE_DIR/tuic.json"
SB_TUIC_DEFAULT_PORT=443

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_tuic_load() { [[ -f "$SB_TUIC_CFG" ]] && jq '.' "$SB_TUIC_CFG" 2>/dev/null || echo '[]'; }
_sb_tuic_save() { mkdir -p "$(dirname "$SB_TUIC_CFG")"; printf '%s' "$1" | jq '.' > "$SB_TUIC_CFG"; }

_sb_tuic_list()      { _sb_tuic_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.insecure)"' 2>/dev/null; }
_sb_tuic_count()     { _sb_tuic_load | jq 'length' 2>/dev/null; }
_sb_tuic_get_by_tag(){ _sb_tuic_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_tuic_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_sb_tuic_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_tuic_save "$nodes"
}

_sb_tuic_delete() {
    local nodes; nodes=$(_sb_tuic_load)
    _sb_tuic_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_sb_tuic_select_node() {
    SB_TUIC_SEL_TAG=""
    local count; count=$(_sb_tuic_count)
    (( count == 0 )) && { log_warn "$(t sb.tuic.none)"; return 1; }
    local tags_arr=() i=0 tag port sni insec
    while IFS=$'\t' read -r tag port sni insec; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.tuic.col_port) %-6s SNI %s\n" "$i" "$tag" "$port" "$sni"
    done < <(_sb_tuic_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.tuic.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_TUIC_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build sing-box tuic inbound ───────────────────────────────────────────────
# zero_rtt_handshake 保持关闭：0-RTT 可被重放（sing-box 文档明确建议关闭）。
# ECH is merged in when the node has keys (lib/common.sh: _sb_ech_merge)
_sb_tuic_build_inbound() { _sb_tuic_build_inbound_base "$1" | _sb_ech_merge "$1"; }
_sb_tuic_build_inbound_base() {
    local n="$1"
    jq -n --argjson n "$n" '{
        type: "tuic",
        tag: $n.tag,
        listen: "::",
        listen_port: $n.port,
        users: [ { name: "psm", uuid: $n.uuid, password: $n.password } ],
        congestion_control: ($n.congestion_control // "bbr"),
        auth_timeout: "3s",
        zero_rtt_handshake: false,
        heartbeat: "10s",
        tls: {
            enabled: true,
            server_name: $n.sni,
            alpn: ["h3"],
            certificate_path: $n.cert_path,
            key_path: $n.key_path
        }
    }'
}

# ── Apply all TUIC nodes into sing-box config ─────────────────────────────────
_sb_tuic_apply() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_tuic_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-tuic-")) or (.type == "tuic")))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        sb_add_inbound "$(_sb_tuic_build_inbound "$(echo "$nodes" | jq -c ".[$i]")")"
    done
    sb_test_restart
}

_sb_tuic_apply_or_revert() {
    _sb_tuic_apply && return 0
    _sb_tuic_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Share link ────────────────────────────────────────────────────────────────
# tuic://UUID:PASSWORD@HOST:PORT?sni=…&alpn=h3&congestion_control=…&udp_relay_mode=native
# 自签名证书时同时写 insecure 与 allow_insecure：不同客户端认的参数名不一样。
_sb_tuic_link() {   # <node-json> <server>
    local n="$1" server="$2" insec
    insec=$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')
    printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=%s&udp_relay_mode=native' \
        "$(printf '%s' "$n" | jq -r '.uuid')" "$(url_encode "$(printf '%s' "$n" | jq -r '.password')")" \
        "$server" "$(printf '%s' "$n" | jq -r '.port')" "$(printf '%s' "$n" | jq -r '.sni')" \
        "$(printf '%s' "$n" | jq -r '.congestion_control // "bbr"')"
    [[ "$insec" == "1" ]] && printf '&insecure=1&allow_insecure=1'
    printf '#%s\n' "$(psm_link_label "$(printf '%s' "$n" | jq -r '.tag')" "$n")"
}

_sb_tuic_uri() {
    local tag="$1"
    local node; node=$(_sb_tuic_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.tuic.not_found "$tag")"; return 1; }

    local port uuid pass sni insec cc ip uri
    port=$(echo "$node"  | jq -r '.port')
    uuid=$(echo "$node"  | jq -r '.uuid')
    pass=$(echo "$node"  | jq -r '.password')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')
    cc=$(echo "$node"    | jq -r '.congestion_control // "bbr"')
    ip=$(get_ipv4)
    uri=$(_sb_tuic_link "$node" "$ip")

    echo -e "\n${BOLD}${GREEN}── sing-box TUIC: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t sb.tuic.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t sb.tuic.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t sb.tuic.label_port):"   "$port"
    printf "  %-12s %s\n" "UUID:"                      "$uuid"
    printf "  %-12s %s\n" "$(t sb.tuic.label_pass):"   "$pass"
    printf "  %-12s %s\n" "SNI:"                       "$sni"
    printf "  %-12s %s\n" "$(t sb.tuic.label_cc):"     "$cc"
    echo ""
    echo -e "${BOLD}$(t sb.tuic.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true

    echo -e "\n${BOLD}$(t sb.tuic.clash_label):${NC}"
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

# 选择拥塞控制算法，结果写入 SB_TUIC_CC
_sb_tuic_ask_cc() {
    SB_TUIC_CC="bbr"
    echo -e "  1. bbr ($(t sb.tuic.cc_default))\n  2. cubic\n  3. new_reno"
    local c; read -rp "$(echo -e "${CYAN}$(t sb.tuic.ask_cc)${NC}")" c
    case "$c" in 2) SB_TUIC_CC="cubic" ;; 3) SB_TUIC_CC="new_reno" ;; esac
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_tuic_add_node() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.tuic.add_title)${NC}"

    local tag port uuid password domain
    ask tag  "$(t sb.tuic.ask_tag)"  "sb-tuic-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-tuic- ]] || tag="sb-tuic-${tag}"
    ask port "$(t sb.tuic.ask_port)" "$SB_TUIC_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.tuic.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.tuic.cancelled)"; return 1; }

    uuid=$("$SB_BIN" generate uuid 2>/dev/null || uuid_gen)
    password=$(rand_str 24)
    ask password "$(t sb.tuic.ask_pass)" "$password"

    domain=""
    if ask_yn "$(t sb.tuic.ask_has_domain)" N; then
        ask domain "$(t sb.tuic.ask_domain)"
    fi
    local tls; tls=$(_sb_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"
    _sb_tls_tuple_valid "$cert_path" "$key_path" "$sni" "$insecure" \
        || { log_error "$(t sb.tls.resolve_failed)"; return 1; }

    _sb_tuic_ask_cc

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg pass "$password" \
        --arg domain "$domain" --arg sni "$sni" --arg cert "$cert_path" --arg key "$key_path" \
        --argjson insec "$insecure" --arg cc "$SB_TUIC_CC" \
        '{tag:$tag, port:$port, uuid:$uuid, password:$pass, domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, congestion_control:$cc}')

    local _prev_store; _prev_store=$(_sb_tuic_load)
    _sb_tuic_upsert "$node_json"
    _sb_tuic_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.tuic.added "$tag" "$port")"

    ask_yn "$(t sb.tuic.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "udp"
    }
    _sb_tuic_uri "$tag"
}

# ── Modify password ───────────────────────────────────────────────────────────
sb_tuic_modify_password() {
    echo -e "\n${BOLD}$(t sb.tuic.modify_pass_title)${NC}"
    _sb_tuic_select_node || return
    local tag="$SB_TUIC_SEL_TAG"
    local node; node=$(_sb_tuic_get_by_tag "$tag")
    local pass; ask pass "$(t sb.tuic.ask_new_pass)" ""
    [[ -z "$pass" ]] && pass=$(rand_str 24)
    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    local _prev_store; _prev_store=$(_sb_tuic_load)
    _sb_tuic_upsert "$node"
    _sb_tuic_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.tuic.pass_updated "$tag")"
    _sb_tuic_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_tuic_delete_node() {
    echo -e "\n${BOLD}$(t sb.tuic.del_title)${NC}"
    _sb_tuic_select_node || return
    local tag="$SB_TUIC_SEL_TAG"
    ask_yn "$(t sb.tuic.ask_confirm_del "$tag")" N || return
    local _prev_store; _prev_store=$(_sb_tuic_load)
    _sb_tuic_delete "$tag"
    _sb_tuic_apply_or_revert "$_prev_store" || return 1
    source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.tuic.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_sb_tuic_show_node_list() {
    local count; count=$(_sb_tuic_count)
    echo -e "\n${BOLD}sing-box TUIC:${NC}"
    if (( count == 0 )); then echo "  $(t sb.tuic.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni insec; do
        printf "  UDP %s | $(t sb.tuic.col_port): %-6s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$sni" "$tag"
    done < <(_sb_tuic_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_tuic_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.tuic.menu_title)" \
            "$(t sb.tuic.menu.add)" \
            "$(t sb.tuic.menu.view)" \
            "$(t sb.tuic.menu.pass)" \
            "$(t sb.tuic.menu.del)" \
            "$(t sb.tuic.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_tuic_add_node;  press_enter ;;
            2) _sb_tuic_select_node && _sb_tuic_uri "$SB_TUIC_SEL_TAG"; press_enter ;;
            3) sb_tuic_modify_password; press_enter ;;
            4) sb_tuic_delete_node; press_enter ;;
            5) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
