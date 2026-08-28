#!/usr/bin/env bash
# xray/vmess.sh — VMess + WebSocket + TLS node management via Xray
#
# 结构与 xray/vision.sh、xray/trojan.sh 平行：节点存储（config/xray/vmess.json）
# 是唯一事实源，apply 时整体重建 vmess 入站。
#
# 传输固定为 WebSocket + TLS，理由：裸 TCP 的 VMess 没有 TLS 外壳，特征明显且早已
# 被主动探测识别；WS+TLS 是 VMess 唯一还值得部署的形态，也是能被 CDN 前置的那个。
# 需要免证书的方案请用 Reality。
#
# alterId：Xray 自 1.8 起只支持 VMessAEAD，alterId 已无意义，服务端配置里不写这个
# 字段。但分享链接仍要带 aid=0——大量客户端解析 vmess:// 时会拿它当必填项。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$LIB_DIR/nginx.sh"

VMESS_CFG="$CFG_DIR/xray/vmess.json"
VMESS_DEFAULT_PORT=7443

# ── Node store ────────────────────────────────────────────────────────────────
_vmess_load() { [[ -f "$VMESS_CFG" ]] || echo "[]" > "$VMESS_CFG"; cat "$VMESS_CFG"; }
_vmess_save() { mkdir -p "$(dirname "$VMESS_CFG")"; echo "$1" > "$VMESS_CFG"; }

_vmess_get_by_tag() { _vmess_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_vmess_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_vmess_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _vmess_save "$nodes"
}

_vmess_delete() {
    local nodes; nodes=$(_vmess_load)
    _vmess_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_vmess_list() {
    _vmess_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "127.0.0.1")\t\(.domain)"' 2>/dev/null
}

# 节点存储是唯一事实源：手动编辑 config.json 后菜单显示旧值，且下一次
# _vmess_apply_all 会覆盖手动修改。查看/修改前把 config.json 的端口和 UUID
# 同步回存储（vmess 入站与节点 1:1，按 tag 匹配）。与 vision / trojan 同源逻辑。
_vmess_sync_from_live() {
    [[ -f "$XRAY_CFG" ]] || return 0
    local nodes; nodes=$(_vmess_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag uuid port listen domain live live_port live_uuid
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node"    | jq -r '.tag')
        uuid=$(echo "$node"   | jq -r '.uuid')
        port=$(echo "$node"   | jq -r '.port')
        listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
        domain=$(echo "$node" | jq -r '.domain')
        live=$(jq -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) // empty' "$XRAY_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue
        live_port=$(echo "$live" | jq -r '.port')
        live_uuid=$(echo "$live" | jq -r '.settings.clients[0].id // empty')
        [[ -z "$live_uuid" ]] && live_uuid="$uuid"
        [[ "$live_port" == "$port" && "$live_uuid" == "$uuid" ]] && continue
        changed=1
        if [[ "$listen" == "127.0.0.1" && "$live_port" != "$port" ]]; then
            _sni_add_entry "$domain" "127.0.0.1:${live_port}" 2>/dev/null || true
        fi
        nodes=$(echo "$nodes" | jq --arg t "$tag" --arg p "$live_port" --arg u "$live_uuid" \
            '(.[] | select(.tag == $t)) |= (.port = ($p|tonumber) | .uuid = $u
             | (if (.listen_addr // "127.0.0.1") != "127.0.0.1" then .public_port = ($p|tonumber) else . end))')
    done
    if (( changed )); then
        _vmess_save "$nodes"
        log_info "$(t xray.manual_sync_port_uuid)"
    fi
    return 0
}

_vmess_show_node_list() {
    local lst; lst=$(_vmess_list)
    if [[ -z "$lst" ]]; then log_warn "$(t xray.vmess.no_nodes)"; return; fi
    echo -e "\n${BOLD}$(t xray.vmess.nodes_title)${NC}"
    printf "  %-20s %-6s %-15s %s\n" "$(t xray.header.tag)" "$(t xray.header.port)" "$(t xray.header.listen)" "$(t xray.header.domain)"
    echo "$lst" | while IFS=$'\t' read -r t p l d; do
        printf "  %-20s %-6s %-15s %s\n" "$t" "$p" "$l" "$d"
    done
}

# ── Build inbound ─────────────────────────────────────────────────────────────
_vmess_build_inbound() {
    local n="$1"
    local tag;         tag=$(echo "$n"    | jq -r '.tag')
    local port;        port=$(echo "$n"   | jq -r '.port')
    local uuid;        uuid=$(echo "$n"   | jq -r '.uuid')
    local domain;      domain=$(echo "$n" | jq -r '.domain')
    local path;        path=$(echo "$n"   | jq -r '.path')
    local listen_addr; listen_addr=$(echo "$n" | jq -r '.listen_addr // "127.0.0.1"')
    local cert_dir="$NGINX_SSL_DIR/$domain"

    # clients 里刻意不写 alterId：Xray 1.8+ 只认 VMessAEAD，该字段已被忽略，
    # 写上去只会让配置看起来还停留在 AlterID 时代。分享链接那边仍会带 aid=0。
    jq -n \
        --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" \
        --arg uuid "$uuid" --arg path "$path" --arg sn "$domain" \
        --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/privkey.pem" \
        '{
          "tag": $tag,
          "listen": $listen,
          "port": $port,
          "protocol": "vmess",
          "settings": {
            "clients": [{ "id": $uuid }]
          },
          "streamSettings": {
            "network": "websocket",
            "security": "tls",
            "wsSettings": { "path": $path },
            "tlsSettings": {
              "serverName": $sn,
              "certificates": [{
                "certificateFile": $cert,
                "keyFile": $key
              }],
              "minVersion": "1.2",
              "alpn": ["http/1.1"]
            }
          },
          "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
        }'
}

_vmess_apply_all() {
    local nodes; nodes=$(_vmess_load)
    local count; count=$(echo "$nodes" | jq 'length')

    # 只删 protocol == "vmess" 的入站。按 streamSettings 匹配会误伤 XHTTP 的
    # ws 模式节点（两者的 network/security 完全相同，只有 protocol 能区分）。
    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select((.protocol // "") == "vmess"))' "$XRAY_CFG" > "$tmp" \
        && mv "$tmp" "$XRAY_CFG"

    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        xray_add_inbound "$(_vmess_build_inbound "$node")"
    done

    xray_test_restart
}

# ── Add node ──────────────────────────────────────────────────────────────────
vmess_add_node() {
    _vmess_sync_from_live
    log_step "$(t xray.vmess.adding)"
    echo -e "  ${YELLOW}$(t xray.vmess.need_domain_cert)${NC}\n"

    local count; count=$(_vmess_load | jq 'length')
    local tag port uuid domain path

    ask tag  "$(t xray.ask.node_tag)"   "vmess-$((count+1))"
    ask port "$(t xray.ask.local_port)" "$((VMESS_DEFAULT_PORT + count))"
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    ask domain "$(t xray.ask.domain_required)"
    [[ -z "$domain" ]] && { log_error "$(t xray.vmess.domain_required)"; return 1; }

    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$domain" || {
        log_warn "$(t xray.vmess.cancel_no_tls)"
        return 1
    }

    ask uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask path "$(t xray.vmess.ask_path)" "$(rand_path)"
    [[ "$path" == /* ]] || path="/$path"

    # ── Nginx reverse proxy choice ────────────────────────────────────────────
    local listen_addr="" use_nginx=0 public_port
    echo ""
    if ask_yn "$(t xray.ask.nginx_proxy)" N; then
        use_nginx=1; listen_addr="127.0.0.1"
        if ! is_installed nginx; then
            log_warn "$(t xray.nginx_not_installed)"
            ask_yn "$(t xray.ask_install_nginx)" Y \
                && nginx_install \
                || { log_error "$(t xray.proxy_need_nginx)"; return 1; }
        fi
        _sni_add_entry "$domain" "127.0.0.1:${port}"
        public_port=443
    else
        listen_addr="0.0.0.0"
        public_port="$port"
    fi

    local node
    node=$(jq -n \
        --arg tag "$tag" --argjson port "$port" \
        --arg uuid "$uuid" --arg domain "$domain" --arg path "$path" \
        --arg listen_addr "$listen_addr" \
        --argjson public_port "$public_port" \
        '{tag:$tag, port:$port, public_port:$public_port, uuid:$uuid,
          domain:$domain, path:$path, listen_addr:$listen_addr}')
    _vmess_upsert "$node"
    _vmess_apply_all

    echo ""
    log_ok "$(t xray.vmess.added "$tag" "$listen_addr" "$port")"

    if (( use_nginx == 0 )); then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    vmess_show_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
vmess_delete_node() {
    _vmess_show_node_list
    local tag; ask tag "$(t xray.ask.delete_node_tag)"
    local node; node=$(_vmess_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local domain; domain=$(echo "$node" | jq -r '.domain')
    ask_yn "$(t xray.ask.delete_node "$tag")" N || return 0
    _vmess_delete "$tag"
    _sni_remove_entry "$domain" 2>/dev/null || true
    _vmess_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t xray.deleted)"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
vmess_modify_domain() {
    _vmess_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_vmess_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local old_domain; old_domain=$(echo "$node" | jq -r '.domain')
    local new_domain; ask new_domain "$(t xray.ask.new_domain)"
    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$new_domain" || { log_warn "$(t xray.cancel_no_cert)"; return 1; }
    _sni_remove_entry "$old_domain" 2>/dev/null || true
    node=$(echo "$node" | jq --arg v "$new_domain" '.domain=$v')
    _vmess_upsert "$node"
    local port; port=$(echo "$node" | jq -r '.port')
    local listen_addr; listen_addr=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
    [[ "$listen_addr" == "127.0.0.1" ]] && _sni_add_entry "$new_domain" "127.0.0.1:${port}" 2>/dev/null || true
    _vmess_apply_all
    log_ok "$(t xray.vmess.domain_updated "$tag" "$new_domain")"
}

vmess_modify_uuid() {
    _vmess_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_vmess_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local new_uuid; ask new_uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$new_uuid" ]] && new_uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid=$v')
    _vmess_upsert "$node"
    _vmess_apply_all
    log_ok "$(t xray.vmess.uuid_updated "$tag")"
    echo ""
    vmess_show_share "$tag"
}

vmess_modify_path() {
    _vmess_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_vmess_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local new_path; ask new_path "$(t xray.vmess.ask_path)" "$(rand_path)"
    [[ "$new_path" == /* ]] || new_path="/$new_path"
    node=$(echo "$node" | jq --arg v "$new_path" '.path=$v')
    _vmess_upsert "$node"
    _vmess_apply_all
    log_ok "$(t xray.vmess.path_updated "$tag" "$new_path")"
    echo ""
    vmess_show_share "$tag"
}

vmess_modify_port() {
    _vmess_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_vmess_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local old_port; old_port=$(echo "$node" | jq -r '.port')
    local listen;   listen=$(echo "$node"   | jq -r '.listen_addr // "127.0.0.1"')
    local domain;   domain=$(echo "$node"   | jq -r '.domain')
    [[ "$listen" == "127.0.0.1" ]] \
        && log_info "$(t xray.nginx_proxy_port_note)"
    ask port "$(t xray.ask.new_port)" "$old_port"
    [[ "$port" == "$old_port" ]] && { log_info "$(t xray.port_unchanged)"; return 0; }
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t xray.invalid_port_short)"; return 1
    fi
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    node=$(echo "$node" | jq --argjson p "$port" \
        '.port = $p | (if (.listen_addr // "127.0.0.1") != "127.0.0.1" then .public_port = $p else . end)')
    _vmess_upsert "$node"
    [[ "$listen" == "127.0.0.1" ]] && _sni_add_entry "$domain" "127.0.0.1:${port}" || true
    _vmess_apply_all
    log_ok "$(t xray.port_updated "$tag" "$old_port" "$port")"

    if [[ "$listen" != "127.0.0.1" ]]; then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
        log_info "$(t xray.old_port_note "$old_port")"
    fi
}

# ── Share URI ─────────────────────────────────────────────────────────────────
# VMess 没有查询参数式的 URI：链接是 vmess:// 后面跟一段 base64 的 JSON
# （v2rayN 事实标准）。字段名是固定的三字母缩写，改名客户端就解析不出来。
_vmess_build_uri() {
    local tag="$1" host="$2" port="$3" uuid="$4" domain="$5" path="$6"
    local payload
    payload=$(jq -nc \
        --arg ps "PSM-$tag" --arg add "$host" --arg port "$port" \
        --arg id "$uuid" --arg host_hdr "$domain" --arg path "$path" \
        '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto",
          net:"ws", type:"none", host:$host_hdr, path:$path, tls:"tls", sni:$host_hdr}')
    printf 'vmess://%s' "$(printf '%s' "$payload" | openssl base64 -A)"
}

vmess_show_share() {
    local tag="$1"
    _vmess_sync_from_live
    [[ -z "$tag" ]] && { _vmess_show_node_list; ask tag "$(t xray.ask.node_tag)"; }
    local node; node=$(_vmess_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

    local uuid;   uuid=$(echo "$node"   | jq -r '.uuid')
    local domain; domain=$(echo "$node" | jq -r '.domain')
    local path;   path=$(echo "$node"   | jq -r '.path')
    local listen; listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
    local public_port; public_port=$(echo "$node" | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')

    # 挂 Nginx 时用证书域名；直连时用服务器 IP，但 Host / SNI 仍是证书域名，
    # 否则 TLS 握手对不上、WebSocket 的 Host 头也会被服务端拒。
    local host
    if [[ "$listen" == "127.0.0.1" ]]; then
        host="$domain"
    else
        host=$(get_ipv4)
    fi

    local uri; uri=$(_vmess_build_uri "$tag" "$host" "$public_port" "$uuid" "$domain" "$path")
    echo -e "\n${BOLD}${GREEN}$(t xray.vmess.share_title)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
_vmess_check_deps() {
    ensure_pkg_deps jq qrencode
    if ! [[ -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
        ask_yn "$(t xray.ask_install_xray)" Y \
            && xray_install \
            || { log_error "$(t xray.vmess.need_xray)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
vmess_menu() {
    _vmess_check_deps || return
    while true; do
        _vmess_sync_from_live
        show_menu "$(t xray.vmess.menu.title)" \
            "$(t xray.vmess.menu.add)" \
            "$(t xray.vmess.menu.delete)" \
            "$(t xray.vmess.menu.domain)" \
            "$(t xray.vmess.menu.uuid)" \
            "$(t xray.vmess.menu.path)" \
            "$(t xray.vmess.menu.port)" \
            "$(t xray.vmess.menu.share)" \
            "$(t xray.vmess.menu.list)"

        case "$MENU_CHOICE" in
            1) vmess_add_node ;;
            2) vmess_delete_node ;;
            3) vmess_modify_domain ;;
            4) vmess_modify_uuid ;;
            5) vmess_modify_path ;;
            6) vmess_modify_port ;;
            7) vmess_show_share "" ;;
            8) _vmess_show_node_list ;;
            0) return ;;
        esac
        press_enter
    done
}
