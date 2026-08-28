#!/usr/bin/env bash
# singbox/vmess.sh — VMess + WebSocket + TLS inbound via sing-box
#
# 结构与 singbox/trojan.sh 平行：节点存储（config/singbox/vmess.json）是唯一事实源，
# apply 时整体重建 vmess 入站。i18n（t sb.vmess.*）。
#
# 传输固定为 WebSocket + TLS：裸 TCP 的 VMess 没有 TLS 外壳，特征明显且早已被主动
# 探测识别，WS+TLS 是 VMess 唯一还值得部署的形态。需要免证书方案请用 Reality。
#
# alterId 固定 0：VMess 自 AEAD 起已废弃 AlterID，写 0 是各核心公认的「AEAD 模式」
# 取值。分享链接里的 aid 也必须是 "0"，大量客户端拿它当必填项。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_VMESS_CFG="$SB_STORE_DIR/vmess.json"
SB_VMESS_DEFAULT_PORT=7553

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_vmess_load() { [[ -f "$SB_VMESS_CFG" ]] && jq '.' "$SB_VMESS_CFG" 2>/dev/null || echo '[]'; }
_sb_vmess_save() { mkdir -p "$(dirname "$SB_VMESS_CFG")"; printf '%s' "$1" | jq '.' > "$SB_VMESS_CFG"; }

_sb_vmess_list()      { _sb_vmess_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.insecure)"' 2>/dev/null; }
_sb_vmess_count()     { _sb_vmess_load | jq 'length' 2>/dev/null; }
_sb_vmess_get_by_tag(){ _sb_vmess_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_vmess_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_sb_vmess_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_vmess_save "$nodes"
}

_sb_vmess_delete() {
    local nodes; nodes=$(_sb_vmess_load)
    _sb_vmess_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_sb_vmess_select_node() {
    SB_VMESS_SEL_TAG=""
    local count; count=$(_sb_vmess_count)
    (( count == 0 )) && { log_warn "$(t sb.vmess.none)"; return 1; }
    local tags_arr=() i=0 tag port sni insec
    while IFS=$'\t' read -r tag port sni insec; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.vmess.col_port) %-6s SNI %s\n" "$i" "$tag" "$port" "$sni"
    done < <(_sb_vmess_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.vmess.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_VMESS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build sing-box vmess inbound ─────────────────────────────────────────────
# sing-box 的 vmess 用户是 {name, uuid, alterId}；对比同目录 trojan.sh 的
# {name, password}、anytls.sh 的 {name, password}。字段名写错内核会拒绝整份配置。
_sb_vmess_build_inbound() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local uuid; uuid=$(echo "$node_json" | jq -r '.uuid')
    local path; path=$(echo "$node_json" | jq -r '.path')
    local sni;  sni=$(echo "$node_json"  | jq -r '.sni')
    local cert; cert=$(echo "$node_json" | jq -r '.cert_path')
    local key;  key=$(echo "$node_json"  | jq -r '.key_path')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "::"')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg uuid "$uuid" --arg path "$path" \
        --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        --arg listen "$listen_addr" \
    '{
        type: "vmess",
        tag: $tag,
        listen: $listen,
        listen_port: $p,
        users: [ { name: "psm", uuid: $uuid, alterId: 0 } ],
        tls: {
            enabled: true,
            server_name: $sni,
            certificate_path: $cert,
            key_path: $key
        },
        transport: { type: "ws", path: $path }
    }'
}

# ── Apply all VMess nodes into sing-box config ───────────────────────────────
_sb_vmess_apply() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_vmess_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-vmess-")) or (.type == "vmess")))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        sb_add_inbound "$(_sb_vmess_build_inbound "$node")"
    done
    sb_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_sb_vmess_apply_or_revert() {
    _sb_vmess_apply && return 0
    _sb_vmess_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Share URI ─────────────────────────────────────────────────────────────────
# VMess 没有查询参数式 URI：链接是 vmess:// 后跟一段 base64 的 JSON（v2rayN 事实
# 标准）。字段名是固定的三字母缩写，改名客户端就解析不出来。
_sb_vmess_uri() {
    local tag="$1"
    local node; node=$(_sb_vmess_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.vmess.not_found "$tag")"; return 1; }

    local port uuid path sni insec host
    port=$(echo "$node"  | jq -r '.public_port // .port')
    uuid=$(echo "$node"  | jq -r '.uuid')
    path=$(echo "$node"  | jq -r '.path')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')

    # 挂 Nginx 443 分流时用伪装 SNI 作主机名（它就是路由键，且证书与之匹配）；
    # 直连时用服务器 IP，但 Host / SNI 仍必须是证书域名，否则握手与 WS Host 头对不上。
    if [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]]; then
        host="$sni"
    else
        host=$(get_ipv4)
    fi

    local payload uri
    payload=$(jq -nc \
        --arg ps "PSM-$tag" --arg add "$host" --arg port "$port" \
        --arg id "$uuid" --arg host_hdr "$sni" --arg path "$path" \
        '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto",
          net:"ws", type:"none", host:$host_hdr, path:$path, tls:"tls", sni:$host_hdr}')
    uri="vmess://$(printf '%s' "$payload" | openssl base64 -A)"

    echo -e "\n${BOLD}${GREEN}── sing-box VMess: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t sb.vmess.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t sb.vmess.label_server):" "$host"
    printf "  %-12s %s\n" "$(t sb.vmess.label_port):"   "$port"
    printf "  %-12s %s\n" "UUID:"                          "$uuid"
    printf "  %-12s %s\n" "$(t sb.vmess.label_path):"   "$path"
    printf "  %-12s %s\n" "SNI:"                           "$sni"
    echo ""
    echo -e "${BOLD}$(t sb.vmess.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_vmess_add_node() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.vmess.add_title)${NC}"

    local tag port uuid path domain
    ask tag  "$(t sb.vmess.ask_tag)"  "sb-vmess-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-vmess- ]] || tag="sb-vmess-${tag}"

    # ── 监听模式：直连独占公网端口（默认），或挂到 Nginx 443 SNI 分流 ──
    # 挂载模式不要求自有域名：自签名证书时以伪装 SNI（默认 www.bing.com）做路由键。
    local listen_addr="::" public_port="" use_nginx=0
    ask_yn "$(t sb.front.ask_mount)" N && use_nginx=1

    if (( use_nginx )); then
        _sb_front_ensure_nginx || { log_info "$(t sb.vmess.cancelled)"; return 1; }
        listen_addr="127.0.0.1"
        public_port=443
        ask port "$(t sb.front.ask_local_port)" \
            "$(_sb_front_suggest_local_port $((5443 + $(_sb_vmess_count))))"
    else
        ask port "$(t sb.vmess.ask_port)" "$SB_VMESS_DEFAULT_PORT"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.vmess.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.vmess.cancelled)"; return 1; }

    ask uuid "$(t sb.vmess.ask_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask path "$(t sb.vmess.ask_path)" "$(rand_path)"
    [[ "$path" == /* ]] || path="/$path"

    domain=""
    if ask_yn "$(t sb.vmess.ask_has_domain)" N; then
        ask domain "$(t sb.vmess.ask_domain)"
    fi

    local tls; tls=$(_sb_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"
    _sb_tls_tuple_valid "$cert_path" "$key_path" "$sni" "$insecure" \
        || { log_error "$(t sb.tls.resolve_failed)"; return 1; }

    # SNI 是 443 分流的路由键，必须全局唯一（跨内核共用一张 map）
    if (( use_nginx )) && _sb_front_sni_conflict "$sni"; then
        log_info "$(t sb.vmess.cancelled)"; return 1
    fi

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
        --arg domain "$domain" --arg sni "$sni" \
        --arg cert "$cert_path" --arg key "$key_path" --argjson insec "$insecure" \
        --arg listen_addr "$listen_addr" \
        --argjson public_port "${public_port:-$port}" \
        '{tag:$tag, port:$port, public_port:$public_port, uuid:$uuid, path:$path,
          domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, listen_addr:$listen_addr}')

    local _prev_store; _prev_store=$(_sb_vmess_load)
    _sb_vmess_upsert "$node_json"
    _sb_vmess_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.vmess.added "$tag" "$port")"

    if (( use_nginx )); then
        # 路由条目在 sing-box 应用成功后再写，避免失败时留下指向死端口的路由
        _sni_add_entry "$sni" "127.0.0.1:${port}" \
            || log_warn "$(t sb.front.map_failed "$sni")"
        log_ok "$(t sb.front.mounted "$sni" "$port")"
    else
        ask_yn "$(t sb.vmess.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi
    _sb_vmess_uri "$tag"
}

# ── Modify UUID ───────────────────────────────────────────────────────────────
sb_vmess_modify_uuid() {
    echo -e "\n${BOLD}$(t sb.vmess.modify_uuid_title)${NC}"
    _sb_vmess_select_node || return
    local tag="$SB_VMESS_SEL_TAG"
    local node; node=$(_sb_vmess_get_by_tag "$tag")
    local uuid; ask uuid "$(t sb.vmess.ask_new_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$uuid" '.uuid = $v')
    local _prev_store; _prev_store=$(_sb_vmess_load)
    _sb_vmess_upsert "$node"
    _sb_vmess_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.vmess.uuid_updated "$tag")"
    _sb_vmess_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_vmess_delete_node() {
    echo -e "\n${BOLD}$(t sb.vmess.del_title)${NC}"
    _sb_vmess_select_node || return
    local tag="$SB_VMESS_SEL_TAG"
    ask_yn "$(t sb.vmess.ask_confirm_del "$tag")" N || return
    # 挂载在 Nginx 443 上的节点：先摘除 SNI 路由条目
    local node; node=$(_sb_vmess_get_by_tag "$tag")
    if [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.sni')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi
    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_sb_vmess_load)
    _sb_vmess_delete "$tag"
    _sb_vmess_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.vmess.deleted "$tag")"
}

# manager.sh 的「查看所有节点」调用
_sb_vmess_show_node_list() {
    local count; count=$(_sb_vmess_count)
    echo -e "\n${BOLD}sing-box VMess:${NC}"
    if (( count == 0 )); then echo "  $(t sb.vmess.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni insec; do
        printf "  TCP %s | $(t sb.vmess.col_port): %-6s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$sni" "$tag"
    done < <(_sb_vmess_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_vmess_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.vmess.menu_title)" \
            "$(t sb.vmess.menu.add)" \
            "$(t sb.vmess.menu.view)" \
            "$(t sb.vmess.menu.uuid)" \
            "$(t sb.vmess.menu.del)" \
            "$(t sb.vmess.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_vmess_add_node;  press_enter ;;
            2) _sb_vmess_select_node && _sb_vmess_uri "$SB_VMESS_SEL_TAG"; press_enter ;;
            3) sb_vmess_modify_uuid; press_enter ;;
            4) sb_vmess_delete_node; press_enter ;;
            5) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
