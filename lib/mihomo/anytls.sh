#!/usr/bin/env bash
# anytls.sh — AnyTLS (TCP+TLS) listener via mihomo
#
# AnyTLS 入站需要 mihomo 1.12.0+。节点存储（config/mihomo/anytls.json）是唯一
# 事实源，apply 时整体重建 anytls 入站。支持真实域名证书或自签名。i18n（t mh.anytls.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

MH_ANYTLS_CFG="$MH_STORE_DIR/anytls.json"
MH_ANYTLS_DEFAULT_PORT=8443

# ── State helpers ─────────────────────────────────────────────────────────────
_mh_anytls_load() { [[ -f "$MH_ANYTLS_CFG" ]] && jq '.' "$MH_ANYTLS_CFG" 2>/dev/null || echo '[]'; }
_mh_anytls_save() { mkdir -p "$(dirname "$MH_ANYTLS_CFG")"; printf '%s' "$1" | jq '.' > "$MH_ANYTLS_CFG"; }

_mh_anytls_list()      { _mh_anytls_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.insecure)"' 2>/dev/null; }
_mh_anytls_count()     { _mh_anytls_load | jq 'length' 2>/dev/null; }
_mh_anytls_get_by_tag(){ _mh_anytls_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_mh_anytls_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_mh_anytls_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _mh_anytls_save "$nodes"
}

_mh_anytls_delete() {
    local nodes; nodes=$(_mh_anytls_load)
    _mh_anytls_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_mh_anytls_select_node() {
    MH_ANYTLS_SEL_TAG=""
    local count; count=$(_mh_anytls_count)
    (( count == 0 )) && { log_warn "$(t mh.anytls.none)"; return 1; }
    local tags_arr=() i=0 tag port sni insec
    while IFS=$'\t' read -r tag port sni insec; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t mh.anytls.col_port) %-6s SNI %s\n" "$i" "$tag" "$port" "$sni"
    done < <(_mh_anytls_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.anytls.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t mh.invalid_option)"; return 1; fi
    MH_ANYTLS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build mihomo anytls listener ─────────────────────────────────────────────
_mh_anytls_build_listener() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local pass; pass=$(echo "$node_json" | jq -r '.password')
    local sni;  sni=$(echo "$node_json"  | jq -r '.sni')
    local cert; cert=$(echo "$node_json" | jq -r '.cert_path')
    local key;  key=$(echo "$node_json"  | jq -r '.key_path')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "0.0.0.0"')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg pass "$pass" \
        --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        --arg listen "$listen_addr" \
    '{
        name: $tag,
        type: "anytls",
        port: $p,
        listen: $listen,
        users: { "u1": $pass },
        certificate: $cert,
        "private-key": $key
    }'
}

# ── Apply all AnyTLS nodes into mihomo config ───────────────────────────────
_mh_anytls_apply() {
    _mh_cfg_backup   # 事务化：先备份，mh_test_restart 校验失败时回滚
    local nodes; nodes=$(_mh_anytls_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.listeners[] | select(((.name // "") | startswith("mh-anytls-")) or (.type == "anytls")))' \
        "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        mh_add_listener "$(_mh_anytls_build_listener "$node")"
    done
    mh_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_mh_anytls_apply_or_revert() {
    _mh_anytls_apply && return 0
    _mh_anytls_save "$1"
    log_error "$(t mh.change_reverted)"
    return 1
}

# ── Share URI ─────────────────────────────────────────────────────────────────
_mh_anytls_uri() {
    local tag="$1"
    local node; node=$(_mh_anytls_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.anytls.not_found "$tag")"; return 1; }

    local port pass sni insec
    port=$(echo "$node"  | jq -r '.public_port // .port')
    pass=$(echo "$node"  | jq -r '.password')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')

    local ip; ip=$(get_ipv4)
    local uri="anytls://${pass}@${ip}:${port}?insecure=${insec}&sni=${sni}#PSM-${tag}"

    echo -e "\n${BOLD}${GREEN}── mihomo AnyTLS: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t mh.anytls.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t mh.anytls.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t mh.anytls.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t mh.anytls.label_pass):"   "$pass"
    printf "  %-12s %s\n" "SNI:"                         "$sni"
    echo ""
    echo -e "${BOLD}$(t mh.anytls.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Add node ──────────────────────────────────────────────────────────────────
mh_anytls_add_node() {
    _mh_require_installed || return
    # 版本门禁：AnyTLS 入站(listener type=anytls)由 mihomo v1.19.3 引入（feat: implement
    # anytls client and server），不满足则在填任何参数前拦截。原值 1.12.0 是照抄 sing-box
    # 的版本号，对 mihomo（1.19.x 版本线）恒成立、形同虚设，故校正为真实的 mihomo 版本。
    _mh_require_version "1.19.3" "mh.anytls.feature" || return 1
    echo -e "\n${BOLD}$(t mh.anytls.add_title)${NC}"
    log_info "$(t mh.anytls.version_hint)"

    local tag port password domain
    ask tag  "$(t mh.anytls.ask_tag)"  "mh-anytls-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^mh-anytls- ]] || tag="mh-anytls-${tag}"

    # ── 监听模式：直连独占公网端口（默认），或挂到 Nginx 443 SNI 分流 ──
    # 挂载模式不要求自有域名：自签名证书时以伪装 SNI（默认 www.bing.com）做路由键。
    local listen_addr="0.0.0.0" public_port="" use_nginx=0
    ask_yn "$(t mh.front.ask_mount)" N && use_nginx=1

    if (( use_nginx )); then
        _mh_front_ensure_nginx || { log_info "$(t mh.anytls.cancelled)"; return 1; }
        listen_addr="127.0.0.1"
        public_port=443
        ask port "$(t mh.front.ask_local_port)" \
            "$(_mh_front_suggest_local_port $((5443 + $(_mh_anytls_count))))"
    else
        ask port "$(t mh.anytls.ask_port)" "$MH_ANYTLS_DEFAULT_PORT"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t mh.anytls.invalid_port)"; return 1
    fi
    _mh_check_port_conflict "$port" || { log_info "$(t mh.anytls.cancelled)"; return 1; }

    password=$(rand_str 20)
    ask password "$(t mh.anytls.ask_pass)" "$password"

    domain=""
    if ask_yn "$(t mh.anytls.ask_has_domain)" N; then
        ask domain "$(t mh.anytls.ask_domain)"
    fi

    local tls; tls=$(_mh_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"
    _mh_tls_tuple_valid "$cert_path" "$key_path" "$sni" "$insecure" \
        || { log_error "$(t mh.tls.resolve_failed)"; return 1; }

    # SNI 是 443 分流的路由键，必须全局唯一（跨内核共用一张 map）
    if (( use_nginx )) && _mh_front_sni_conflict "$sni"; then
        log_info "$(t mh.anytls.cancelled)"; return 1
    fi

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg pass "$password" \
        --arg domain "$domain" --arg sni "$sni" \
        --arg cert "$cert_path" --arg key "$key_path" --argjson insec "$insecure" \
        --arg listen_addr "$listen_addr" \
        --argjson public_port "${public_port:-$port}" \
        '{tag:$tag, port:$port, public_port:$public_port, password:$pass,
          domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, listen_addr:$listen_addr}')

    local _prev_store; _prev_store=$(_mh_anytls_load)
    _mh_anytls_upsert "$node_json"
    _mh_anytls_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.anytls.added "$tag" "$port")"

    if (( use_nginx )); then
        # 路由条目在 mihomo 应用成功后再写，避免失败时留下指向死端口的路由
        _sni_add_entry "$sni" "127.0.0.1:${port}" \
            || log_warn "$(t mh.front.map_failed "$sni")"
        log_ok "$(t mh.front.mounted "$sni" "$port")"
    else
        ask_yn "$(t mh.anytls.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi
    _mh_anytls_uri "$tag"
}

# ── Modify password ───────────────────────────────────────────────────────────
mh_anytls_modify_password() {
    echo -e "\n${BOLD}$(t mh.anytls.modify_pass_title)${NC}"
    _mh_anytls_select_node || return
    local tag="$MH_ANYTLS_SEL_TAG"
    local node; node=$(_mh_anytls_get_by_tag "$tag")
    local pass; ask pass "$(t mh.anytls.ask_new_pass)" ""
    [[ -z "$pass" ]] && pass=$(rand_str 20)
    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    local _prev_store; _prev_store=$(_mh_anytls_load)
    _mh_anytls_upsert "$node"
    _mh_anytls_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.anytls.pass_updated "$tag")"
    _mh_anytls_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
mh_anytls_delete_node() {
    echo -e "\n${BOLD}$(t mh.anytls.del_title)${NC}"
    _mh_anytls_select_node || return
    local tag="$MH_ANYTLS_SEL_TAG"
    ask_yn "$(t mh.anytls.ask_confirm_del "$tag")" N || return
    # 挂载在 Nginx 443 上的节点：先摘除 SNI 路由条目
    local node; node=$(_mh_anytls_get_by_tag "$tag")
    if [[ "$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.sni')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi
    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_mh_anytls_load)
    _mh_anytls_delete "$tag"
    _mh_anytls_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t mh.anytls.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_mh_anytls_show_node_list() {
    local count; count=$(_mh_anytls_count)
    echo -e "\n${BOLD}mihomo AnyTLS:${NC}"
    if (( count == 0 )); then echo "  $(t mh.anytls.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni insec; do
        printf "  TCP %s | $(t mh.anytls.col_port): %-6s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$sni" "$tag"
    done < <(_mh_anytls_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
mh_anytls_menu() {
    _mh_require_installed || return
    while true; do
        show_menu "$(t mh.anytls.menu_title)" \
            "$(t mh.anytls.menu.add)" \
            "$(t mh.anytls.menu.view)" \
            "$(t mh.anytls.menu.pass)" \
            "$(t mh.anytls.menu.del)" \
            "$(t mh.anytls.menu.restart)"

        case "$MENU_CHOICE" in
            1) mh_anytls_add_node;  press_enter ;;
            2) _mh_anytls_select_node && _mh_anytls_uri "$MH_ANYTLS_SEL_TAG"; press_enter ;;
            3) mh_anytls_modify_password; press_enter ;;
            4) mh_anytls_delete_node; press_enter ;;
            5) mh_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
