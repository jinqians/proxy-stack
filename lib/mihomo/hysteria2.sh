#!/usr/bin/env bash
# hysteria2.sh — Hysteria2 (QUIC) listener via mihomo
#
# 节点存储（config/mihomo/hysteria2.json）是唯一事实源，apply 时整体重建
# mihomo 的 hysteria2 入站。支持真实域名证书或自签名。终端输出走 i18n（t mh.hy2.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

MH_HY2_CFG="$MH_STORE_DIR/hysteria2.json"
MH_HY2_DEFAULT_PORT=443
MH_HY2_DEFAULT_MASQ="https://www.bing.com"

# ── State helpers ─────────────────────────────────────────────────────────────
_mh_hy2_load() { [[ -f "$MH_HY2_CFG" ]] && jq '.' "$MH_HY2_CFG" 2>/dev/null || echo '[]'; }
_mh_hy2_save() { mkdir -p "$(dirname "$MH_HY2_CFG")"; printf '%s' "$1" | jq '.' > "$MH_HY2_CFG"; }

_mh_hy2_list()      { _mh_hy2_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.insecure)"' 2>/dev/null; }
_mh_hy2_count()     { _mh_hy2_load | jq 'length' 2>/dev/null; }
_mh_hy2_get_by_tag(){ _mh_hy2_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_mh_hy2_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_mh_hy2_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _mh_hy2_save "$nodes"
}

_mh_hy2_delete() {
    local nodes; nodes=$(_mh_hy2_load)
    _mh_hy2_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_mh_hy2_select_node() {
    MH_HY2_SEL_TAG=""
    local count; count=$(_mh_hy2_count)
    (( count == 0 )) && { log_warn "$(t mh.hy2.none)"; return 1; }
    local tags_arr=() i=0 tag port sni insec
    while IFS=$'\t' read -r tag port sni insec; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t mh.hy2.col_port) %-6s SNI %s\n" "$i" "$tag" "$port" "$sni"
    done < <(_mh_hy2_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.hy2.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t mh.invalid_option)"; return 1; fi
    MH_HY2_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build mihomo hysteria2 listener ──────────────────────────────────────────
_mh_hy2_build_listener() {
    local node_json="$1"
    local tag;   tag=$(echo "$node_json"   | jq -r '.tag')
    local port;  port=$(echo "$node_json"  | jq -r '.port')
    local pass;  pass=$(echo "$node_json"  | jq -r '.password')
    local sni;   sni=$(echo "$node_json"   | jq -r '.sni')
    local cert;  cert=$(echo "$node_json"  | jq -r '.cert_path')
    local key;   key=$(echo "$node_json"   | jq -r '.key_path')
    local masq;  masq=$(echo "$node_json"  | jq -r '.masquerade // ""')
    local obfs;  obfs=$(echo "$node_json"  | jq -r '.obfs_pass // ""')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg pass "$pass" \
        --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        --arg masq "$masq" --arg obfs "$obfs" \
    '{
        name: $tag,
        type: "hysteria2",
        port: $p,
        listen: "0.0.0.0",
        users: { "u1": $pass },
        alpn: ["h3"],
        certificate: $cert,
        "private-key": $key
    }
    + (if $obfs != "" then { obfs: "salamander", "obfs-password": $obfs } else {} end)
    + (if $masq != "" then { masquerade: $masq } else {} end)'
}

# ── Apply all Hysteria2 nodes into mihomo config ────────────────────────────
_mh_hy2_apply() {
    _mh_cfg_backup   # 事务化：先备份，mh_test_restart 校验失败时回滚
    local nodes; nodes=$(_mh_hy2_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.listeners[] | select(((.name // "") | startswith("mh-hy2-")) or (.type == "hysteria2")))' \
        "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        mh_add_listener "$(_mh_hy2_build_listener "$node")"
    done
    mh_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_mh_hy2_apply_or_revert() {
    _mh_hy2_apply && return 0
    _mh_hy2_save "$1"
    log_error "$(t mh.change_reverted)"
    return 1
}

# ── Share URI ─────────────────────────────────────────────────────────────────
_mh_hy2_uri() {
    local tag="$1"
    local node; node=$(_mh_hy2_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.hy2.not_found "$tag")"; return 1; }

    local port pass sni insec obfs
    port=$(echo "$node"  | jq -r '.port')
    pass=$(echo "$node"  | jq -r '.password')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')
    obfs=$(echo "$node"  | jq -r '.obfs_pass // ""')

    local ip; ip=$(get_ipv4)
    local uri="hysteria2://${pass}@${ip}:${port}?insecure=${insec}&sni=${sni}"
    [[ -n "$obfs" ]] && uri="${uri}&obfs=salamander&obfs-password=${obfs}"
    uri="${uri}#PSM-${tag}"

    echo -e "\n${BOLD}${GREEN}── mihomo Hysteria2: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t mh.hy2.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t mh.hy2.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t mh.hy2.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t mh.hy2.label_pass):"   "$pass"
    printf "  %-12s %s\n" "SNI:"                      "$sni"
    [[ -n "$obfs" ]] && printf "  %-12s %s\n" "Obfs:" "salamander"
    echo ""
    echo -e "${BOLD}$(t mh.hy2.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true

    local obfs_yaml=""
    [[ -n "$obfs" ]] && obfs_yaml=$'\n    obfs: salamander\n    obfs-password: '"${obfs}"
    echo -e "\n${BOLD}$(t mh.hy2.clash_label):${NC}"
    cat <<EOF
proxies:
  - name: PSM-${tag}
    type: hysteria2
    server: ${ip}
    port: ${port}
    password: "${pass}"
    sni: ${sni}${obfs_yaml}
    skip-cert-verify: $([[ "$insec" == "1" ]] && echo true || echo false)
EOF
}

# ── Add node ──────────────────────────────────────────────────────────────────
mh_hy2_add_node() {
    _mh_require_installed || return
    echo -e "\n${BOLD}$(t mh.hy2.add_title)${NC}"

    local tag port password domain up down masq
    ask tag  "$(t mh.hy2.ask_tag)"  "mh-hy2-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^mh-hy2- ]] || tag="mh-hy2-${tag}"
    ask port "$(t mh.hy2.ask_port)" "$MH_HY2_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t mh.hy2.invalid_port)"; return 1
    fi
    _mh_check_port_conflict "$port" || { log_info "$(t mh.hy2.cancelled)"; return 1; }

    password=$(rand_str 24)
    ask password "$(t mh.hy2.ask_pass)" "$password"

    domain=""
    if ask_yn "$(t mh.hy2.ask_has_domain)" N; then
        ask domain "$(t mh.hy2.ask_domain)"
    fi

    # 解析 TLS：域名证书或自签名（自签名时客户端需 insecure=1）
    local tls; tls=$(_mh_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"

    ask masq "$(t mh.hy2.ask_masq)" "$MH_HY2_DEFAULT_MASQ"
    ask up   "$(t mh.hy2.ask_up)"   "0"
    ask down "$(t mh.hy2.ask_down)" "0"
    [[ "$up"   =~ ^[0-9]+$ ]] || up=0
    [[ "$down" =~ ^[0-9]+$ ]] || down=0

    # Salamander 混淆：开启后 QUIC 报文被混淆，更难被主动探测识别。
    # 服务端与客户端必须使用相同密码，故会写入分享链接。
    local obfs_pass=""
    if ask_yn "$(t mh.hy2.ask_obfs)" N; then
        obfs_pass=$(rand_str 16)
        ask obfs_pass "$(t mh.hy2.ask_obfs_pass)" "$obfs_pass"
    fi

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg pass "$password" \
        --arg domain "$domain" --arg sni "$sni" \
        --arg cert "$cert_path" --arg key "$key_path" --argjson insec "$insecure" \
        --argjson up "$up" --argjson down "$down" --arg masq "$masq" --arg obfs "$obfs_pass" \
        '{tag:$tag, port:$port, password:$pass, domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, up:$up, down:$down,
          masquerade:$masq, obfs_pass:$obfs}')

    local _prev_store; _prev_store=$(_mh_hy2_load)
    _mh_hy2_upsert "$node_json"
    _mh_hy2_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.hy2.added "$tag" "$port")"

    ask_yn "$(t mh.hy2.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "udp"
    }
    _mh_hy2_uri "$tag"
}

# ── Modify password ───────────────────────────────────────────────────────────
mh_hy2_modify_password() {
    echo -e "\n${BOLD}$(t mh.hy2.modify_pass_title)${NC}"
    _mh_hy2_select_node || return
    local tag="$MH_HY2_SEL_TAG"
    local node; node=$(_mh_hy2_get_by_tag "$tag")
    local pass; ask pass "$(t mh.hy2.ask_new_pass)" ""
    [[ -z "$pass" ]] && pass=$(rand_str 24)
    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    local _prev_store; _prev_store=$(_mh_hy2_load)
    _mh_hy2_upsert "$node"
    _mh_hy2_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.hy2.pass_updated "$tag")"
    _mh_hy2_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
mh_hy2_delete_node() {
    echo -e "\n${BOLD}$(t mh.hy2.del_title)${NC}"
    _mh_hy2_select_node || return
    local tag="$MH_HY2_SEL_TAG"
    ask_yn "$(t mh.hy2.ask_confirm_del "$tag")" N || return
    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_mh_hy2_load)
    _mh_hy2_delete "$tag"
    _mh_hy2_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t mh.hy2.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_mh_hy2_show_node_list() {
    local count; count=$(_mh_hy2_count)
    echo -e "\n${BOLD}mihomo Hysteria2:${NC}"
    if (( count == 0 )); then echo "  $(t mh.hy2.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni insec; do
        printf "  UDP %s | $(t mh.hy2.col_port): %-6s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$sni" "$tag"
    done < <(_mh_hy2_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
mh_hy2_menu() {
    _mh_require_installed || return
    while true; do
        show_menu "$(t mh.hy2.menu_title)" \
            "$(t mh.hy2.menu.add)" \
            "$(t mh.hy2.menu.view)" \
            "$(t mh.hy2.menu.pass)" \
            "$(t mh.hy2.menu.del)" \
            "$(t mh.hy2.menu.restart)"

        case "$MENU_CHOICE" in
            1) mh_hy2_add_node;  press_enter ;;
            2) _mh_hy2_select_node && _mh_hy2_uri "$MH_HY2_SEL_TAG"; press_enter ;;
            3) mh_hy2_modify_password; press_enter ;;
            4) mh_hy2_delete_node; press_enter ;;
            5) mh_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
