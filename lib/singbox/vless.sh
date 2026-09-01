#!/usr/bin/env bash
# singbox/vless.sh — VLESS（TLS）多传输入站 via sing-box
#
# 结构与 singbox/trojan.sh 平行：节点存储（config/singbox/vless.json）是唯一事实源，
# apply 时整体重建 vless 入站。Reality 不在这里 —— 它在 singbox/reality.sh，因为
# Reality 不用证书，整套交互（伪装目标校验、CDN 前端检测）也完全不同。
#
# 支持的传输（每一种都用 sing-box 1.14.0 的 `check` 实测过）：
#   tcp          裸 TLS；配 flow=xtls-rprx-vision 就是 Vision
#   ws           WebSocket
#   grpc         gRPC（用 service_name，不是 path）
#   http         HTTP/2
#   httpupgrade  HTTPUpgrade（只借 Upgrade 握手，之后是裸 TCP，比 ws 少一层帧开销）
#   quic         QUIC —— 走 UDP，防火墙要放行 UDP，且挂不到 Nginx 443 分流上
#
# sing-box 没有 xhttp 传输（实测 `unknown transport type: xhttp`），那是 Xray 与
# mihomo 才有的；mKCP 同理。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_VLESS_CFG="$SB_STORE_DIR/vless.json"
SB_VLESS_DEFAULT_PORT=9443

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_vless_load() { [[ -f "$SB_VLESS_CFG" ]] && jq '.' "$SB_VLESS_CFG" 2>/dev/null || echo '[]'; }
_sb_vless_save() { mkdir -p "$(dirname "$SB_VLESS_CFG")"; printf '%s' "$1" | jq '.' > "$SB_VLESS_CFG"; }

_sb_vless_list()      { _sb_vless_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.transport)"' 2>/dev/null; }
_sb_vless_count()     { _sb_vless_load | jq 'length' 2>/dev/null; }
_sb_vless_get_by_tag(){ _sb_vless_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_vless_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_sb_vless_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_vless_save "$nodes"
}

_sb_vless_delete() {
    local nodes; nodes=$(_sb_vless_load)
    _sb_vless_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_sb_vless_select_node() {
    SB_VLESS_SEL_TAG=""
    local count; count=$(_sb_vless_count)
    (( count == 0 )) && { log_warn "$(t sb.vless.none)"; return 1; }
    local tags_arr=() i=0 tag port sni tr
    while IFS=$'\t' read -r tag port sni tr; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.vless.col_port) %-6s %-12s SNI %s\n" "$i" "$tag" "$port" "$tr" "$sni"
    done < <(_sb_vless_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.vless.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_VLESS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# QUIC 走 UDP，其余传输走 TCP。防火墙放行和「能不能挂 443 SNI 分流」都看这个。
_sb_vless_is_udp() { [[ "$1" == "quic" ]]; }

# ── Build sing-box vless inbound ──────────────────────────────────────────────
# users 是 {name, uuid[, flow]}；flow 只有 tcp 传输下才写（Vision 是 TCP 上的流控，
# 套在 ws/grpc/h2 里没有意义，客户端也对不上）。
# grpc 用 service_name 而不是 path —— 写成 path 会被 sing-box 拒绝。
_sb_vless_build_inbound() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local uuid; uuid=$(echo "$node_json" | jq -r '.uuid')
    local flow; flow=$(echo "$node_json" | jq -r '.flow // ""')
    local tr;   tr=$(echo "$node_json"   | jq -r '.transport // "tcp"')
    local path; path=$(echo "$node_json" | jq -r '.path // "/"')
    local sni;  sni=$(echo "$node_json"  | jq -r '.sni')
    local cert; cert=$(echo "$node_json" | jq -r '.cert_path')
    local key;  key=$(echo "$node_json"  | jq -r '.key_path')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "::"')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg uuid "$uuid" --arg flow "$flow" \
        --arg tr "$tr" --arg path "$path" \
        --arg sni "$sni" --arg cert "$cert" --arg key "$key" --arg listen "$listen_addr" \
    '{
        type: "vless",
        tag: $tag,
        listen: $listen,
        listen_port: $p,
        users: [ ({ name: "psm", uuid: $uuid }
                  + (if $tr == "tcp" and $flow != "" then { flow: $flow } else {} end)) ],
        tls: {
            enabled: true,
            server_name: $sni,
            certificate_path: $cert,
            key_path: $key
        }
     }
     + (if   $tr == "tcp"  then {}
        elif $tr == "grpc" then { transport: { type: "grpc", service_name: ($path | ltrimstr("/")) } }
        elif $tr == "quic" then { transport: { type: "quic" } }
        else { transport: { type: $tr, path: $path } } end)'
}

# ── Apply ─────────────────────────────────────────────────────────────────────
_sb_vless_apply() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_vless_load)
    local count; count=$(echo "$nodes" | jq 'length')

    # 只删本模块管的入站。不能按 type == "vless" 一刀切 —— Reality 节点也是
    # type vless，那是 singbox/reality.sh 的地盘，删掉会把用户的 Reality 节点抹掉。
    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-vless-"))))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        sb_add_inbound "$(_sb_vless_build_inbound "$node")"
    done
    sb_test_restart
}

_sb_vless_apply_or_revert() {
    _sb_vless_apply && return 0
    _sb_vless_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Share URI ─────────────────────────────────────────────────────────────────
_sb_vless_uri() {
    local tag="$1"
    local node; node=$(_sb_vless_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.vless.not_found "$tag")"; return 1; }

    local port uuid flow tr path sni insec host
    port=$(echo "$node"  | jq -r '.public_port // .port')
    uuid=$(echo "$node"  | jq -r '.uuid')
    flow=$(echo "$node"  | jq -r '.flow // ""')
    tr=$(echo "$node"    | jq -r '.transport // "tcp"')
    path=$(echo "$node"  | jq -r '.path // "/"')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')

    if [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]]; then
        host="$sni"
    else
        host=$(get_ipv4)
    fi

    # 链接里的 type 用客户端认识的名字：sing-box 内部叫 http，客户端叫 h2。
    local net="$tr"
    [[ "$tr" == "http" ]] && net="h2"
    # 分开声明与赋值：local 的返回值会盖掉 url_encode 的（SC2155）
    local enc_sni q
    enc_sni=$(url_encode "$sni") || return 1
    q="encryption=none&security=tls&sni=${enc_sni}&type=${net}"
    [[ -n "$flow" && "$tr" == "tcp" ]] && q="${q}&flow=$(url_encode "$flow")"
    case "$tr" in
        grpc)                 q="${q}&serviceName=$(url_encode "${path#/}")" ;;
        ws|http|httpupgrade)  q="${q}&path=$(url_encode "$path")&host=$(url_encode "$sni")" ;;
    esac
    [[ "$insec" == "1" ]] && q="${q}&allowInsecure=1"

    local uri="vless://${uuid}@${host}:${port}?${q}#PSM-${tag}"
    echo -e "\n${BOLD}${GREEN}── sing-box VLESS: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t sb.vless.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t sb.vless.label_server):" "$host"
    printf "  %-12s %s\n" "$(t sb.vless.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t sb.vless.label_transport):" "$tr"
    printf "  %-12s %s\n" "SNI:"                        "$sni"
    echo ""
    echo -e "${BOLD}$(t sb.vless.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_vless_add_node() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.vless.add_title)${NC}"

    local tag port uuid domain transport path flow=""
    ask tag "$(t sb.vless.ask_tag)" "sb-vless-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-vless- ]] || tag="sb-vless-${tag}"

    # ── 传输选择 ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "  $(t sb.vless.tr1)"
    echo -e "  $(t sb.vless.tr2)"
    echo -e "  $(t sb.vless.tr3)"
    echo -e "  $(t sb.vless.tr4)"
    echo -e "  $(t sb.vless.tr5)"
    echo -e "  $(t sb.vless.tr6)"
    local tc; read -rp "$(echo -e "${CYAN}$(t sb.vless.ask_transport)${NC}")" tc
    case "${tc:-1}" in
        2) transport="ws" ;;
        3) transport="grpc" ;;
        4) transport="http" ;;
        5) transport="httpupgrade" ;;
        6) transport="quic" ;;
        *) transport="tcp" ;;
    esac
    # Vision 是 TCP 上的流控，只在裸 TLS 传输下有意义
    if [[ "$transport" == "tcp" ]] && ask_yn "$(t sb.vless.ask_vision)" Y; then
        flow="xtls-rprx-vision"
    fi
    path="/"
    case "$transport" in
        ws|http|httpupgrade) ask path "$(t sb.vless.ask_path)" "$(rand_path)"; [[ "$path" == /* ]] || path="/$path" ;;
        grpc)                ask path "$(t sb.vless.ask_service)" "$(rand_str 8)"; path="/${path#/}" ;;
    esac

    if _sb_vless_is_udp "$transport"; then
        log_info "$(t sb.vless.quic_note)"
        ask port "$(t sb.vless.ask_port)" "$SB_VLESS_DEFAULT_PORT"
    else
        ask port "$(t sb.vless.ask_port)" "$SB_VLESS_DEFAULT_PORT"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.vless.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.vless.cancelled)"; return 1; }

    ask uuid "$(t sb.vless.ask_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$("$SB_BIN" generate uuid 2>/dev/null || uuid_gen)

    domain=""
    if ask_yn "$(t sb.vless.ask_has_domain)" N; then
        ask domain "$(t sb.vless.ask_domain)"
    fi
    local tls; tls=$(_sb_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"
    _sb_tls_tuple_valid "$cert_path" "$key_path" "$sni" "$insecure" \
        || { log_error "$(t sb.tls.resolve_failed)"; return 1; }

    # ── 监听模式 ──────────────────────────────────────────────────────────────
    # QUIC 走 UDP，而 Nginx 443 分流是 stream 层按 TLS ClientHello 的 SNI 路由的，
    # 既没有 TCP 也没有可读的 SNI，挂不上去。直接跳过询问。
    local listen_addr="::" public_port="" use_nginx=0
    if _sb_vless_is_udp "$transport"; then
        log_info "$(t sb.vless.quic_no_mount)"
        public_port="$port"
    else
        echo ""
        ask_yn "$(t sb.front.ask_mount)" N && use_nginx=1
        if (( use_nginx )); then
            _sb_front_ensure_nginx || { log_info "$(t sb.vless.cancelled)"; return 1; }
            if _sb_front_sni_conflict "$sni"; then
                log_info "$(t sb.vless.cancelled)"; return 1
            fi
            listen_addr="127.0.0.1"; public_port=443
        else
            public_port="$port"
        fi
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

    local _prev; _prev=$(_sb_vless_load)
    _sb_vless_upsert "$node_json"
    _sb_vless_apply_or_revert "$_prev" || return 1
    log_ok "$(t sb.vless.added "$tag" "$port")"

    if (( use_nginx )); then
        _sni_add_entry "$sni" "127.0.0.1:${port}" || log_warn "$(t sb.front.map_failed "$sni")"
        log_ok "$(t sb.front.mounted "$sni" "$port")"
    else
        local proto="tcp"; _sb_vless_is_udp "$transport" && proto="udp"
        ask_yn "$(t sb.vless.ask_firewall "$port" "$proto")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "$proto"
        }
    fi
    _sb_vless_uri "$tag"
}

# ── Modify UUID ───────────────────────────────────────────────────────────────
sb_vless_modify_uuid() {
    echo -e "\n${BOLD}$(t sb.vless.modify_uuid_title)${NC}"
    _sb_vless_select_node || return
    local tag="$SB_VLESS_SEL_TAG"
    local node; node=$(_sb_vless_get_by_tag "$tag")
    local uuid; ask uuid "$(t sb.vless.ask_new_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$("$SB_BIN" generate uuid 2>/dev/null || uuid_gen)
    node=$(echo "$node" | jq --arg v "$uuid" '.uuid = $v')
    local _prev; _prev=$(_sb_vless_load)
    _sb_vless_upsert "$node"
    _sb_vless_apply_or_revert "$_prev" || return 1
    log_ok "$(t sb.vless.uuid_updated "$tag")"
    _sb_vless_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_vless_delete_node() {
    echo -e "\n${BOLD}$(t sb.vless.del_title)${NC}"
    _sb_vless_select_node || return
    local tag="$SB_VLESS_SEL_TAG"
    ask_yn "$(t sb.vless.ask_confirm_del "$tag")" N || return
    local node; node=$(_sb_vless_get_by_tag "$tag")
    if [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.sni')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi
    local _prev; _prev=$(_sb_vless_load)
    _sb_vless_delete "$tag"
    _sb_vless_apply_or_revert "$_prev" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.vless.deleted "$tag")"
}

# manager.sh 的「查看所有节点」调用
_sb_vless_show_node_list() {
    local count; count=$(_sb_vless_count)
    echo -e "\n${BOLD}sing-box VLESS:${NC}"
    if (( count == 0 )); then echo "  $(t sb.vless.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni tr; do
        printf "  %s | $(t sb.vless.col_port): %-6s | %-12s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$tr" "$sni" "$tag"
    done < <(_sb_vless_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_vless_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.vless.menu_title)" \
            "$(t sb.vless.menu.add)" \
            "$(t sb.vless.menu.view)" \
            "$(t sb.vless.menu.uuid)" \
            "$(t sb.vless.menu.del)" \
            "$(t sb.vless.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_vless_add_node;  press_enter ;;
            2) _sb_vless_select_node && _sb_vless_uri "$SB_VLESS_SEL_TAG"; press_enter ;;
            3) sb_vless_modify_uuid; press_enter ;;
            4) sb_vless_delete_node; press_enter ;;
            5) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
