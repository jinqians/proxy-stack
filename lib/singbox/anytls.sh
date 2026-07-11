#!/usr/bin/env bash
# singbox/anytls.sh — AnyTLS (TCP+TLS) inbound via sing-box
#
# AnyTLS 入站需要 sing-box 1.12.0+。节点存储（config/singbox/anytls.json）是唯一
# 事实源，apply 时整体重建 anytls 入站。支持真实域名证书或自签名。i18n（t sb.anytls.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_ANYTLS_CFG="$SB_STORE_DIR/anytls.json"
SB_ANYTLS_DEFAULT_PORT=8443

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_anytls_load() { [[ -f "$SB_ANYTLS_CFG" ]] && jq '.' "$SB_ANYTLS_CFG" 2>/dev/null || echo '[]'; }
_sb_anytls_save() { mkdir -p "$(dirname "$SB_ANYTLS_CFG")"; printf '%s' "$1" | jq '.' > "$SB_ANYTLS_CFG"; }

_sb_anytls_list()      { _sb_anytls_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.insecure)"' 2>/dev/null; }
_sb_anytls_count()     { _sb_anytls_load | jq 'length' 2>/dev/null; }
_sb_anytls_get_by_tag(){ _sb_anytls_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_anytls_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_sb_anytls_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_anytls_save "$nodes"
}

_sb_anytls_delete() {
    local nodes; nodes=$(_sb_anytls_load)
    _sb_anytls_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_sb_anytls_select_node() {
    SB_ANYTLS_SEL_TAG=""
    local count; count=$(_sb_anytls_count)
    (( count == 0 )) && { log_warn "$(t sb.anytls.none)"; return 1; }
    local tags_arr=() i=0 tag port sni insec
    while IFS=$'\t' read -r tag port sni insec; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.anytls.col_port) %-6s SNI %s\n" "$i" "$tag" "$port" "$sni"
    done < <(_sb_anytls_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.anytls.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_ANYTLS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build sing-box anytls inbound ─────────────────────────────────────────────
_sb_anytls_build_inbound() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local pass; pass=$(echo "$node_json" | jq -r '.password')
    local sni;  sni=$(echo "$node_json"  | jq -r '.sni')
    local cert; cert=$(echo "$node_json" | jq -r '.cert_path')
    local key;  key=$(echo "$node_json"  | jq -r '.key_path')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "::"')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg pass "$pass" \
        --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        --arg listen "$listen_addr" \
    '{
        type: "anytls",
        tag: $tag,
        listen: $listen,
        listen_port: $p,
        users: [ { name: "psm", password: $pass } ],
        tls: {
            enabled: true,
            server_name: $sni,
            certificate_path: $cert,
            key_path: $key
        }
    }'
}

# ── Apply all AnyTLS nodes into sing-box config ───────────────────────────────
_sb_anytls_apply() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_anytls_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-anytls-")) or (.type == "anytls")))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        sb_add_inbound "$(_sb_anytls_build_inbound "$node")"
    done
    sb_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_sb_anytls_apply_or_revert() {
    _sb_anytls_apply && return 0
    _sb_anytls_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Share URI ─────────────────────────────────────────────────────────────────
_sb_anytls_uri() {
    local tag="$1"
    local node; node=$(_sb_anytls_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.anytls.not_found "$tag")"; return 1; }

    local port pass sni insec
    port=$(echo "$node"  | jq -r '.public_port // .port')
    pass=$(echo "$node"  | jq -r '.password')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')

    local ip; ip=$(get_ipv4)
    local uri="anytls://${pass}@${ip}:${port}?insecure=${insec}&sni=${sni}#PSM-${tag}"

    echo -e "\n${BOLD}${GREEN}── sing-box AnyTLS: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t sb.anytls.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t sb.anytls.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t sb.anytls.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t sb.anytls.label_pass):"   "$pass"
    printf "  %-12s %s\n" "SNI:"                         "$sni"
    echo ""
    echo -e "${BOLD}$(t sb.anytls.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_anytls_add_node() {
    _sb_require_installed || return
    # 版本门禁：AnyTLS 入站需 sing-box 1.12.0+，不满足则在填任何参数前拦截
    _sb_require_version "1.12.0" "sb.anytls.feature" || return 1
    echo -e "\n${BOLD}$(t sb.anytls.add_title)${NC}"
    log_info "$(t sb.anytls.version_hint)"

    local tag port password domain
    ask tag  "$(t sb.anytls.ask_tag)"  "sb-anytls-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-anytls- ]] || tag="sb-anytls-${tag}"

    # ── 监听模式：直连独占公网端口（默认），或挂到 Nginx 443 SNI 分流 ──
    # 挂载模式不要求自有域名：自签名证书时以伪装 SNI（默认 www.bing.com）做路由键。
    local listen_addr="::" public_port="" use_nginx=0
    ask_yn "$(t sb.front.ask_mount)" N && use_nginx=1

    if (( use_nginx )); then
        _sb_front_ensure_nginx || { log_info "$(t sb.anytls.cancelled)"; return 1; }
        listen_addr="127.0.0.1"
        public_port=443
        ask port "$(t sb.front.ask_local_port)" \
            "$(_sb_front_suggest_local_port $((3443 + $(_sb_anytls_count))))"
    else
        ask port "$(t sb.anytls.ask_port)" "$SB_ANYTLS_DEFAULT_PORT"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.anytls.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.anytls.cancelled)"; return 1; }

    password=$(rand_str 20)
    ask password "$(t sb.anytls.ask_pass)" "$password"

    domain=""
    if ask_yn "$(t sb.anytls.ask_has_domain)" N; then
        ask domain "$(t sb.anytls.ask_domain)"
    fi

    local tls; tls=$(_sb_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"

    # SNI 是 443 分流的路由键，必须全局唯一（跨内核共用一张 map）
    if (( use_nginx )) && _sb_front_sni_conflict "$sni"; then
        log_info "$(t sb.anytls.cancelled)"; return 1
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

    local _prev_store; _prev_store=$(_sb_anytls_load)
    _sb_anytls_upsert "$node_json"
    _sb_anytls_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.anytls.added "$tag" "$port")"

    if (( use_nginx )); then
        # 路由条目在 sing-box 应用成功后再写，避免失败时留下指向死端口的路由
        _sni_add_entry "$sni" "127.0.0.1:${port}" \
            || log_warn "$(t sb.front.map_failed "$sni")"
        log_ok "$(t sb.front.mounted "$sni" "$port")"
    else
        ask_yn "$(t sb.anytls.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi
    _sb_anytls_uri "$tag"
}

# ── Modify password ───────────────────────────────────────────────────────────
sb_anytls_modify_password() {
    echo -e "\n${BOLD}$(t sb.anytls.modify_pass_title)${NC}"
    _sb_anytls_select_node || return
    local tag="$SB_ANYTLS_SEL_TAG"
    local node; node=$(_sb_anytls_get_by_tag "$tag")
    local pass; ask pass "$(t sb.anytls.ask_new_pass)" ""
    [[ -z "$pass" ]] && pass=$(rand_str 20)
    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    local _prev_store; _prev_store=$(_sb_anytls_load)
    _sb_anytls_upsert "$node"
    _sb_anytls_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.anytls.pass_updated "$tag")"
    _sb_anytls_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_anytls_delete_node() {
    echo -e "\n${BOLD}$(t sb.anytls.del_title)${NC}"
    _sb_anytls_select_node || return
    local tag="$SB_ANYTLS_SEL_TAG"
    ask_yn "$(t sb.anytls.ask_confirm_del "$tag")" N || return
    # 挂载在 Nginx 443 上的节点：先摘除 SNI 路由条目
    local node; node=$(_sb_anytls_get_by_tag "$tag")
    if [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.sni')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi
    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_sb_anytls_load)
    _sb_anytls_delete "$tag"
    _sb_anytls_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.anytls.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_sb_anytls_show_node_list() {
    local count; count=$(_sb_anytls_count)
    echo -e "\n${BOLD}sing-box AnyTLS:${NC}"
    if (( count == 0 )); then echo "  $(t sb.anytls.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni insec; do
        printf "  TCP %s | $(t sb.anytls.col_port): %-6s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$sni" "$tag"
    done < <(_sb_anytls_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_anytls_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.anytls.menu_title)" \
            "$(t sb.anytls.menu.add)" \
            "$(t sb.anytls.menu.view)" \
            "$(t sb.anytls.menu.pass)" \
            "$(t sb.anytls.menu.del)" \
            "$(t sb.anytls.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_anytls_add_node;  press_enter ;;
            2) _sb_anytls_select_node && _sb_anytls_uri "$SB_ANYTLS_SEL_TAG"; press_enter ;;
            3) sb_anytls_modify_password; press_enter ;;
            4) sb_anytls_delete_node; press_enter ;;
            5) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
