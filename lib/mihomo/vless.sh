#!/usr/bin/env bash
# mihomo/vless.sh — VLESS（TLS）多传输入站 via mihomo
#
# 结构与 mihomo/trojan.sh 平行：节点存储（config/mihomo/vless.json）是唯一事实源，
# apply 时整体重建 vless listener。Reality 不在这里 —— 见 mihomo/reality.sh。
#
# 支持的传输（取自上游 listener/inbound/vless.go 的 VlessOption 结构体，并用
# mihomo v1.19.30 实跑监听逐个验证）：
#   tcp    裸 TLS；配 flow=xtls-rprx-vision 就是 Vision
#   ws     WebSocket（顶层 ws-path，不是嵌套块）
#   grpc   gRPC（grpc-service-name）
#   xhttp  XHTTP（xhttp-config 块）—— mihomo 有，sing-box 没有
#
# mihomo 的 VLESS listener【没有】h2 和 HTTPUpgrade：结构体里只有上面这几个字段。
# 特别注意：mihomo 会静默忽略未知字段，`mihomo -t` 对 listener 几乎不做校验，
# 所以「配置能过 -t」不等于「字段生效」。本模块的字段照结构体写，不是试出来的。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

MH_VLESS_CFG="$MH_STORE_DIR/vless.json"
MH_VLESS_DEFAULT_PORT=9443

# ── State helpers ─────────────────────────────────────────────────────────────
_mh_vless_load() { [[ -f "$MH_VLESS_CFG" ]] && jq '.' "$MH_VLESS_CFG" 2>/dev/null || echo '[]'; }
_mh_vless_save() { mkdir -p "$(dirname "$MH_VLESS_CFG")"; printf '%s' "$1" | jq '.' > "$MH_VLESS_CFG"; }

_mh_vless_list()      { _mh_vless_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.transport)"' 2>/dev/null; }
_mh_vless_count()     { _mh_vless_load | jq 'length' 2>/dev/null; }
_mh_vless_get_by_tag(){ _mh_vless_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_mh_vless_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_mh_vless_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _mh_vless_save "$nodes"
}

_mh_vless_delete() {
    local nodes; nodes=$(_mh_vless_load)
    _mh_vless_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_mh_vless_select_node() {
    MH_VLESS_SEL_TAG=""
    local count; count=$(_mh_vless_count)
    (( count == 0 )) && { log_warn "$(t mh.vless.none)"; return 1; }
    local tags_arr=() i=0 tag port sni tr
    while IFS=$'\t' read -r tag port sni tr; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t mh.vless.col_port) %-6s %-12s SNI %s\n" "$i" "$tag" "$port" "$tr" "$sni"
    done < <(_mh_vless_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.vless.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t mh.invalid_option)"; return 1; fi
    MH_VLESS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build mihomo vless listener ───────────────────────────────────────────────
# users 是 {username, uuid[, flow]}（对象数组）。传输是【顶层字段】而非嵌套块：
# ws → ws-path，grpc → grpc-service-name，xhttp → xhttp-config。这一点与
# sing-box 的 transport 嵌套块完全不同，两边不能互抄。
# flow 只在 tcp 传输下写：Vision 是 TCP 上的流控，套进 ws/grpc/xhttp 没有意义。
_mh_vless_build_listener() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local uuid; uuid=$(echo "$node_json" | jq -r '.uuid')
    local flow; flow=$(echo "$node_json" | jq -r '.flow // ""')
    local tr;   tr=$(echo "$node_json"   | jq -r '.transport // "tcp"')
    local path; path=$(echo "$node_json" | jq -r '.path // "/"')
    local cert; cert=$(echo "$node_json" | jq -r '.cert_path')
    local key;  key=$(echo "$node_json"  | jq -r '.key_path')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "0.0.0.0"')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg uuid "$uuid" --arg flow "$flow" \
        --arg tr "$tr" --arg path "$path" \
        --arg cert "$cert" --arg key "$key" --arg listen "$listen_addr" \
    '{
        name: $tag,
        type: "vless",
        port: $p,
        listen: $listen,
        users: [ ({ username: "u1", uuid: $uuid }
                  + (if $tr == "tcp" and $flow != "" then { flow: $flow } else {} end)) ],
        certificate: $cert,
        "private-key": $key
     }
     + (if   $tr == "ws"    then { "ws-path": $path }
        elif $tr == "grpc"  then { "grpc-service-name": ($path | ltrimstr("/")) }
        elif $tr == "xhttp" then { "xhttp-config": { path: $path, mode: "auto" } }
        else {} end)'
}

# ── Apply ─────────────────────────────────────────────────────────────────────
_mh_vless_apply() {
    _mh_cfg_backup   # 事务化：先备份，mh_test_restart 校验失败时回滚
    local nodes; nodes=$(_mh_vless_load)
    local count; count=$(echo "$nodes" | jq 'length')

    # 只删本模块管的入站。不能按 type == "vless" 一刀切 —— Reality 节点也是
    # type vless，那是 mihomo/reality.sh 的地盘，删掉会把用户的 Reality 节点抹掉。
    local tmp; tmp=$(mktemp)
    jq 'del(.listeners[] | select(((.name // "") | startswith("mh-vless-"))))' \
        "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        mh_add_listener "$(_mh_vless_build_listener "$node")"
    done
    mh_test_restart
}

_mh_vless_apply_or_revert() {
    _mh_vless_apply && return 0
    _mh_vless_save "$1"
    log_error "$(t mh.change_reverted)"
    return 1
}

# ── Share URI ─────────────────────────────────────────────────────────────────
_mh_vless_uri() {
    local tag="$1"
    local node; node=$(_mh_vless_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.vless.not_found "$tag")"; return 1; }

    local port uuid flow tr path sni insec host
    port=$(echo "$node"  | jq -r '.public_port // .port')
    uuid=$(echo "$node"  | jq -r '.uuid')
    flow=$(echo "$node"  | jq -r '.flow // ""')
    tr=$(echo "$node"    | jq -r '.transport // "tcp"')
    path=$(echo "$node"  | jq -r '.path // "/"')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')

    if [[ "$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')" == "127.0.0.1" ]]; then
        host="$sni"
    else
        host=$(get_ipv4)
    fi

    # 链接里的 type 用客户端认识的名字：mihomo 内部叫 http，客户端叫 h2。
    local net="$tr"
    # 分开声明与赋值：local 的返回值会盖掉 url_encode 的（SC2155）
    local enc_sni q
    enc_sni=$(url_encode "$sni") || return 1
    q="encryption=none&security=tls&sni=${enc_sni}&type=${net}"
    [[ -n "$flow" && "$tr" == "tcp" ]] && q="${q}&flow=$(url_encode "$flow")"
    case "$tr" in
        grpc)                 q="${q}&serviceName=$(url_encode "${path#/}")" ;;
        ws|xhttp)             q="${q}&path=$(url_encode "$path")&host=$(url_encode "$sni")" ;;
    esac
    [[ "$insec" == "1" ]] && q="${q}&allowInsecure=1"

    local uri="vless://${uuid}@${host}:${port}?${q}#PSM-${tag}"
    echo -e "\n${BOLD}${GREEN}── mihomo VLESS: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t mh.vless.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t mh.vless.label_server):" "$host"
    printf "  %-12s %s\n" "$(t mh.vless.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t mh.vless.label_transport):" "$tr"
    printf "  %-12s %s\n" "SNI:"                        "$sni"
    echo ""
    echo -e "${BOLD}$(t mh.vless.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Add node ──────────────────────────────────────────────────────────────────
mh_vless_add_node() {
    _mh_require_installed || return
    echo -e "\n${BOLD}$(t mh.vless.add_title)${NC}"

    local tag port uuid domain transport path flow=""
    ask tag "$(t mh.vless.ask_tag)" "mh-vless-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^mh-vless- ]] || tag="mh-vless-${tag}"

    # ── 传输选择 ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "  $(t mh.vless.tr1)"
    echo -e "  $(t mh.vless.tr2)"
    echo -e "  $(t mh.vless.tr3)"
    echo -e "  $(t mh.vless.tr4)"
    local tc; read -rp "$(echo -e "${CYAN}$(t mh.vless.ask_transport)${NC}")" tc
    case "${tc:-1}" in
        2) transport="ws" ;;
        3) transport="grpc" ;;
        4) transport="xhttp" ;;
        *) transport="tcp" ;;
    esac
    # Vision 是 TCP 上的流控，只在裸 TLS 传输下有意义
    if [[ "$transport" == "tcp" ]] && ask_yn "$(t mh.vless.ask_vision)" Y; then
        flow="xtls-rprx-vision"
    fi
    path="/"
    case "$transport" in
        ws|xhttp) ask path "$(t mh.vless.ask_path)" "$(rand_path)"; [[ "$path" == /* ]] || path="/$path" ;;
        grpc)                ask path "$(t mh.vless.ask_service)" "$(rand_str 8)"; path="/${path#/}" ;;
    esac

    ask port "$(t mh.vless.ask_port)" "$MH_VLESS_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t mh.vless.invalid_port)"; return 1
    fi
    _mh_check_port_conflict "$port" || { log_info "$(t mh.vless.cancelled)"; return 1; }

    ask uuid "$(t mh.vless.ask_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)

    domain=""
    if ask_yn "$(t mh.vless.ask_has_domain)" N; then
        ask domain "$(t mh.vless.ask_domain)"
    fi
    local tls; tls=$(_mh_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"
    _mh_tls_tuple_valid "$cert_path" "$key_path" "$sni" "$insecure" \
        || { log_error "$(t mh.tls.resolve_failed)"; return 1; }

    # ── 监听模式 ──────────────────────────────────────────────────────────────
    # QUIC 走 UDP，而 Nginx 443 分流是 stream 层按 TLS ClientHello 的 SNI 路由的，
    # 既没有 TCP 也没有可读的 SNI，挂不上去。直接跳过询问。
    local listen_addr="0.0.0.0" public_port="" use_nginx=0
    echo ""
    ask_yn "$(t mh.front.ask_mount)" N && use_nginx=1
    if (( use_nginx )); then
        _mh_front_ensure_nginx || { log_info "$(t mh.vless.cancelled)"; return 1; }
        if _mh_front_sni_conflict "$sni"; then
            log_info "$(t mh.vless.cancelled)"; return 1
        fi
        listen_addr="127.0.0.1"; public_port=443
    else
        public_port="$port"
    fi

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" \
        --arg transport "$transport" --arg path "$path" \
        --arg domain "$domain" --arg sni "$sni" \
        --arg cert "$cert_path" --arg key "$key_path" --argjson insec "$insecure" \
        --arg listen_addr "$listen_addr" --argjson public_port "$public_port" \
        '{tag:$tag, port:$port, public_port:$public_port, uuid:$uuid, flow:$flow,
          transport:$transport, path:$path, domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, listen_addr:$listen_addr}')

    local _prev; _prev=$(_mh_vless_load)
    _mh_vless_upsert "$node_json"
    _mh_vless_apply_or_revert "$_prev" || return 1
    log_ok "$(t mh.vless.added "$tag" "$port")"

    if (( use_nginx )); then
        _sni_add_entry "$sni" "127.0.0.1:${port}" || log_warn "$(t mh.front.map_failed "$sni")"
        log_ok "$(t mh.front.mounted "$sni" "$port")"
    else
        ask_yn "$(t mh.vless.ask_firewall "$port" "tcp")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi
    _mh_vless_uri "$tag"
}

# ── Modify UUID ───────────────────────────────────────────────────────────────
mh_vless_modify_uuid() {
    echo -e "\n${BOLD}$(t mh.vless.modify_uuid_title)${NC}"
    _mh_vless_select_node || return
    local tag="$MH_VLESS_SEL_TAG"
    local node; node=$(_mh_vless_get_by_tag "$tag")
    local uuid; ask uuid "$(t mh.vless.ask_new_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$uuid" '.uuid = $v')
    local _prev; _prev=$(_mh_vless_load)
    _mh_vless_upsert "$node"
    _mh_vless_apply_or_revert "$_prev" || return 1
    log_ok "$(t mh.vless.uuid_updated "$tag")"
    _mh_vless_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
mh_vless_delete_node() {
    echo -e "\n${BOLD}$(t mh.vless.del_title)${NC}"
    _mh_vless_select_node || return
    local tag="$MH_VLESS_SEL_TAG"
    ask_yn "$(t mh.vless.ask_confirm_del "$tag")" N || return
    local node; node=$(_mh_vless_get_by_tag "$tag")
    if [[ "$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.sni')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi
    local _prev; _prev=$(_mh_vless_load)
    _mh_vless_delete "$tag"
    _mh_vless_apply_or_revert "$_prev" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t mh.vless.deleted "$tag")"
}

# manager.sh 的「查看所有节点」调用
_mh_vless_show_node_list() {
    local count; count=$(_mh_vless_count)
    echo -e "\n${BOLD}mihomo VLESS:${NC}"
    if (( count == 0 )); then echo "  $(t mh.vless.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni tr; do
        printf "  %s | $(t mh.vless.col_port): %-6s | %-12s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$tr" "$sni" "$tag"
    done < <(_mh_vless_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
mh_vless_menu() {
    _mh_require_installed || return
    while true; do
        show_menu "$(t mh.vless.menu_title)" \
            "$(t mh.vless.menu.add)" \
            "$(t mh.vless.menu.view)" \
            "$(t mh.vless.menu.uuid)" \
            "$(t mh.vless.menu.del)" \
            "$(t mh.vless.menu.restart)"

        case "$MENU_CHOICE" in
            1) mh_vless_add_node;  press_enter ;;
            2) _mh_vless_select_node && _mh_vless_uri "$MH_VLESS_SEL_TAG"; press_enter ;;
            3) mh_vless_modify_uuid; press_enter ;;
            4) mh_vless_delete_node; press_enter ;;
            5) mh_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
