#!/usr/bin/env bash
# xray/xhttp.sh — VLESS + XHTTP / SplitHTTP node management

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$LIB_DIR/nginx.sh"

XHTTP_CFG="$CFG_DIR/xray/xhttp.json"
XHTTP_DEFAULT_PORT=2024

# ── Node store ────────────────────────────────────────────────────────────────
_xhttp_load()         { [[ -f "$XHTTP_CFG" ]] || echo "[]" > "$XHTTP_CFG"; cat "$XHTTP_CFG"; }
_xhttp_save()         { mkdir -p "$(dirname "$XHTTP_CFG")"; echo "$1" > "$XHTTP_CFG"; }
_xhttp_get_by_tag()   { _xhttp_load | jq ".[] | select(.tag == \"$1\")" 2>/dev/null; }
_xhttp_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_xhttp_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$tag\")) | . += [$n]")
    _xhttp_save "$nodes"
}
_xhttp_delete() {
    local nodes; nodes=$(_xhttp_load)
    _xhttp_save "$(echo "$nodes" | jq "del(.[] | select(.tag == \"$1\"))")"
}
_xhttp_list() {
    _xhttp_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "127.0.0.1")\t\(.mode)\t\(.domain // "")"' 2>/dev/null
}

# 节点存储是唯一事实源：手动编辑 config.json 后菜单显示旧值，且下一次
# _xhttp_apply_all 会覆盖手动修改。查看/修改前把 config.json 的端口/UUID
# 同步回存储（XHTTP 入站与节点 1:1，按 tag 匹配）。
_xhttp_sync_from_live() {
    [[ -f "$XRAY_CFG" ]] || return 0
    local nodes; nodes=$(_xhttp_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag uuid port listen skey live live_port live_uuid
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node"    | jq -r '.tag')
        uuid=$(echo "$node"   | jq -r '.uuid')
        port=$(echo "$node"   | jq -r '.port')
        listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
        # SNI 路由键：普通模式是域名，reality-layer 模式是伪装 SNI
        skey=$(echo "$node"   | jq -r 'if (.domain // "") != "" then .domain else (.server_name // "") end')
        live=$(jq -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) // empty' "$XRAY_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue
        live_port=$(echo "$live" | jq -r '.port')
        live_uuid=$(echo "$live" | jq -r '.settings.clients[0].id // empty')
        [[ -z "$live_uuid" ]] && live_uuid="$uuid"
        [[ "$live_port" == "$port" && "$live_uuid" == "$uuid" ]] && continue
        changed=1
        if [[ "$listen" == "127.0.0.1" && "$live_port" != "$port" && -n "$skey" ]]; then
            _sni_add_entry "$skey" "127.0.0.1:${live_port}" 2>/dev/null || true
        fi
        nodes=$(echo "$nodes" | jq --arg t "$tag" --arg p "$live_port" --arg u "$live_uuid" \
            '(.[] | select(.tag == $t)) |= (.port = ($p|tonumber) | .uuid = $u
             | (if (.listen_addr // "127.0.0.1") != "127.0.0.1" then .public_port = ($p|tonumber) else . end))')
    done
    if (( changed )); then
        _xhttp_save "$nodes"
        log_info "检测到 config.json 中的手动修改，已同步端口/UUID 到节点存储。"
    fi
    return 0
}

_show_node_list() {
    local lst; lst=$(_xhttp_list)
    [[ -z "$lst" ]] && { log_warn "暂无 XHTTP 节点。"; return; }
    echo -e "\n${BOLD}XHTTP 节点：${NC}"
    printf "  %-20s %-6s %-15s %-14s %s\n" "标识" "端口" "监听" "模式" "域名"
    echo "$lst" | while IFS=$'\t' read -r t p l m d; do
        printf "  %-20s %-6s %-15s %-14s %s\n" "$t" "$p" "$l" "$m" "$d"
    done
}

# ── Build inbound ─────────────────────────────────────────────────────────────
_xhttp_build_inbound() {
    local n="$1"
    local tag;        tag=$(echo "$n"        | jq -r '.tag')
    local port;       port=$(echo "$n"       | jq -r '.port')
    local uuid;       uuid=$(echo "$n"       | jq -r '.uuid')
    local mode;       mode=$(echo "$n"       | jq -r '.mode')
    local path;       path=$(echo "$n"       | jq -r '.path')
    local domain;     domain=$(echo "$n"     | jq -r '.domain // ""')
    local listen_addr; listen_addr=$(echo "$n" | jq -r '.listen_addr // "127.0.0.1"')
    local cert_dir="$NGINX_SSL_DIR/$domain"
    local fallback_enabled; fallback_enabled=$(echo "$n" | jq -r '.fallback_enabled // true')

    local stream_json
    case "$mode" in
        xhttp|splithttp)
            stream_json=$(jq -n \
                --arg path "$path" --arg sn "$domain" \
                --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/privkey.pem" \
                '{
                  "network": "xhttp",
                  "security": "tls",
                  "xhttpSettings": { "path": $path, "mode": "auto" },
                  "tlsSettings": {
                    "serverName": $sn,
                    "certificates": [{ "certificateFile": $cert, "keyFile": $key }],
                    "alpn": ["h2","http/1.1"]
                  }
                }')
            ;;
        upgrade|ws)
            stream_json=$(jq -n \
                --arg path "$path" --arg sn "$domain" \
                --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/privkey.pem" \
                '{
                  "network": "websocket",
                  "security": "tls",
                  "wsSettings": { "path": $path },
                  "tlsSettings": {
                    "serverName": $sn,
                    "certificates": [{ "certificateFile": $cert, "keyFile": $key }],
                    "alpn": ["http/1.1"]
                  }
                }')
            ;;
        grpc)
            local service_name="${path#/}"
            stream_json=$(jq -n \
                --arg service "$service_name" --arg sn "$domain" \
                --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/privkey.pem" \
                '{
                  "network": "grpc",
                  "security": "tls",
                  "grpcSettings": { "serviceName": $service },
                  "tlsSettings": {
                    "serverName": $sn,
                    "certificates": [{ "certificateFile": $cert, "keyFile": $key }],
                    "alpn": ["h2"]
                  }
                }')
            ;;
        reality-layer)
            local priv_key; priv_key=$(echo "$n" | jq -r '.private_key // empty')
            local sid;      sid=$(echo "$n"      | jq -r '.short_id // empty')
            local sn;       sn=$(echo "$n"       | jq -r '.server_name // "www.microsoft.com"')
            stream_json=$(jq -n \
                --arg path "$path" --arg sn "$sn" \
                --arg priv "$priv_key" --arg sid "$sid" \
                '{
                  "network": "xhttp",
                  "security": "reality",
                  "xhttpSettings": { "path": $path, "mode": "auto" },
                  "realitySettings": {
                    "show": false,
                    "dest": ($sn + ":443"),
                    "serverNames": [$sn],
                    "privateKey": $priv,
                    "shortIds": [$sid]
                  }
                }')
            ;;
        *)
            die "未知 XHTTP 模式：$mode"
            ;;
    esac

    local fallbacks_json="[]"
    # reality-layer has no TLS termination in Xray → no fallback needed
    if [[ "$mode" != "reality-layer" && "$fallback_enabled" == "true" ]]; then
        fallbacks_json='[{"dest": "127.0.0.1:8080", "xver": 0}]'
    fi

    jq -n \
        --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
        --arg listen "$listen_addr" --argjson stream "$stream_json" \
        --argjson fallbacks "$fallbacks_json" \
        '{
          "tag": $tag,
          "listen": $listen,
          "port": $port,
          "protocol": "vless",
          "settings": {
            "clients": [{ "id": $uuid, "flow": "" }],
            "decryption": "none",
            "fallbacks": $fallbacks
          },
          "streamSettings": $stream,
          "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
        }'
}

_xhttp_apply_all() {
    local nodes; nodes=$(_xhttp_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(
        (.tag | startswith("xhttp")) or
        ((.streamSettings.network // "") as $n | ["xhttp", "splithttp", "websocket", "ws", "grpc"] | index($n))
    ))' "$XRAY_CFG" > "$tmp" \
        && mv "$tmp" "$XRAY_CFG"

    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        xray_add_inbound "$(_xhttp_build_inbound "$node")"
    done

    xray_test_restart
}

# ── Add node ──────────────────────────────────────────────────────────────────
xhttp_add_node() {
    _xhttp_sync_from_live
    local count; count=$(_xhttp_load | jq 'length')
    local tag port uuid domain path mode

    ask tag  "节点标识"   "xhttp-$((count+1))"
    ask port "本机端口"   "$((XHTTP_DEFAULT_PORT + count * 10))"
    _xray_check_port_conflict "$port" || { log_info "已取消"; return 1; }

    echo -e "\n  传输模式："
    echo -e "  1. XHTTP/SplitHTTP  （需要自己的域名 + TLS 证书）"
    echo -e "  2. WebSocket        （需要自己的域名 + TLS 证书）"
    echo -e "  3. gRPC             （需要自己的域名 + TLS 证书）"
    echo -e "  4. Reality layer    （无需域名/证书，使用伪装 SNI）"
    read -rp "$(echo -e "${CYAN}模式 [1]: ${NC}")" mc
    case "${mc:-1}" in
        1) mode="xhttp" ;;
        2) mode="upgrade" ;;
        3) mode="grpc" ;;
        4) mode="reality-layer" ;;
        *) mode="xhttp" ;;
    esac

    # ── Domain + cert (modes 1-3 only) ───────────────────────────────────────
    domain=""
    if [[ "$mode" != "reality-layer" ]]; then
        echo -e "  ${YELLOW}此模式需要自己的域名和 TLS 证书。${NC}"
        ask domain "你的域名（必须解析到本机）"
        [[ -z "$domain" ]] && { log_error "此模式需要填写域名。"; return 1; }
        source "$LIB_DIR/cert.sh"
        cert_ensure_domain "$domain" || {
            log_warn "取消——无有效证书。"
            return 1
        }
    fi

    # ── Nginx reverse proxy choice ────────────────────────────────────────────
    local listen_addr="" use_nginx=0 public_port fallback_enabled=true
    echo ""
    if ask_yn "是否使用 Nginx 反向代理？（可让多个协议复用 443 端口）" N; then
        use_nginx=1; listen_addr="127.0.0.1"
        if ! is_installed nginx; then
            log_warn "Nginx 未安装。"
            ask_yn "是否现在安装 Nginx？" Y \
                && nginx_install \
                || { log_error "反向代理模式需要 Nginx。"; return 1; }
        fi
        if [[ -n "$domain" ]]; then
            _sni_add_entry "$domain" "127.0.0.1:${port}"
        fi
        public_port=443
    else
        listen_addr="0.0.0.0"
        public_port="$port"
        if [[ "$mode" != "reality-layer" ]] && ! is_installed nginx; then
            ask_yn "是否安装 Nginx 作为本地伪装 fallback？" Y \
                && nginx_install \
                || fallback_enabled=false
        fi
    fi

    ask uuid "UUID（留空自动生成）" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask path "路径（留空随机生成）" ""
    [[ -z "$path" ]] && path=$(rand_path)
    if [[ "$mode" == "grpc" ]]; then
        path="${path#/}"
        [[ -n "$path" ]] || path="$(rand_str 8)"
    else
        [[ "$path" == /* ]] || path="/$path"
    fi

    if [[ "$mode" != "reality-layer" && "$fallback_enabled" == "true" ]] && is_installed nginx; then
        nginx_setup_http_camouflage "$domain" || fallback_enabled=false
    fi

    local node
    node=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
        --arg domain "$domain" --arg path "$path" --arg mode "$mode" \
        --arg listen_addr "$listen_addr" \
        --argjson public_port "$public_port" \
        --argjson fallback_enabled "$fallback_enabled" \
        '{tag:$tag, port:$port, public_port:$public_port, uuid:$uuid, domain:$domain, path:$path, mode:$mode, listen_addr:$listen_addr, fallback_enabled:$fallback_enabled}')

    if [[ "$mode" == "reality-layer" ]]; then
        log_step "正在为 XHTTP Reality 层生成密钥..."
        local pair; pair=$(xray_gen_x25519_keys) || return 1
        local priv_key="${pair%%$'\t'*}"
        local pub_key="${pair#*$'\t'}"
        local sid; sid=$(openssl rand -hex 4)
        local sn=""
        if ask_yn "是否用测绘引擎发现同网络/同机房的伪装 SNI？" N; then
            source "$LIB_DIR/xray/sni_finder.sh"
            local _picked; _picked=$(sni_finder_pick_one) || true
            # reality-layer 的 dest 固定为 sn:443（见 _xhttp_build_inbound），此处只取 SNI
            [[ -n "$_picked" ]] && { sn="${_picked%%|*}"; log_info "已选用发现的伪装 SNI：${sn}"; }
        fi
        [[ -z "$sn" ]] && ask sn "伪装 SNI（例如 www.apple.com）" "www.microsoft.com"
        node=$(echo "$node" | jq \
            --arg pk "$priv_key" --arg pub "$pub_key" \
            --arg sid "$sid" --arg sn "$sn" \
            '.private_key=$pk | .public_key=$pub | .short_id=$sid | .server_name=$sn')
        if (( use_nginx )); then
            _sni_add_entry "$sn" "127.0.0.1:${port}"
        fi
        log_info "公钥：$pub_key  Short ID：$sid"
    fi

    _xhttp_upsert "$node"
    _xhttp_apply_all

    echo ""
    log_ok "XHTTP 节点 '$tag' → ${listen_addr}:${port}"

    if (( use_nginx == 0 )); then
        ask_yn "是否现在放行防火墙端口 ${port}/tcp？" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    xhttp_show_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
xhttp_delete_node() {
    _show_node_list
    local tag; ask tag "要删除的节点标识"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }
    local domain; domain=$(echo "$node" | jq -r '.domain // ""')
    ask_yn "确认删除节点 '$tag'？" N || return 0
    _xhttp_delete "$tag"
    [[ -n "$domain" ]] && _sni_remove_entry "$domain" 2>/dev/null || true
    _xhttp_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "已删除。"
}

xhttp_modify_path() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }
    local new_path; ask new_path "新路径（留空随机生成）" ""
    [[ -z "$new_path" ]] && new_path=$(rand_path)
    local mode; mode=$(echo "$node" | jq -r '.mode')
    if [[ "$mode" == "grpc" ]]; then
        new_path="${new_path#/}"
        [[ -n "$new_path" ]] || new_path="$(rand_str 8)"
    else
        [[ "$new_path" == /* ]] || new_path="/$new_path"
    fi
    node=$(echo "$node" | jq --arg v "$new_path" '.path=$v')
    _xhttp_upsert "$node"
    _xhttp_apply_all
    log_ok "路径已更新为 $new_path"
}

xhttp_modify_uuid() {
    _xhttp_sync_from_live
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }
    local new_uuid; ask new_uuid "新 UUID（留空自动生成）" ""
    [[ -z "$new_uuid" ]] && new_uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid=$v')
    _xhttp_upsert "$node"
    _xhttp_apply_all
    log_ok "UUID 已更新：$new_uuid"
}

xhttp_modify_port() {
    _xhttp_sync_from_live
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }
    local old_port listen skey
    old_port=$(echo "$node" | jq -r '.port')
    listen=$(echo "$node"   | jq -r '.listen_addr // "127.0.0.1"')
    skey=$(echo "$node"     | jq -r 'if (.domain // "") != "" then .domain else (.server_name // "") end')

    local port
    [[ "$listen" == "127.0.0.1" ]] \
        && log_info "该节点经 Nginx 反代（公网端口保持 443），修改的是本机 Xray 监听端口。"
    ask port "新端口" "$old_port"
    [[ "$port" == "$old_port" ]] && { log_info "端口未变。"; return 0; }
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "无效端口"; return 1
    fi
    _xray_check_port_conflict "$port" || { log_info "已取消"; return 1; }

    node=$(echo "$node" | jq --argjson p "$port" \
        '.port = $p | (if (.listen_addr // "127.0.0.1") != "127.0.0.1" then .public_port = $p else . end)')
    _xhttp_upsert "$node"
    [[ "$listen" == "127.0.0.1" && -n "$skey" ]] && _sni_add_entry "$skey" "127.0.0.1:${port}" || true
    _xhttp_apply_all
    log_ok "节点 '$tag' 端口已更新：${old_port} → ${port}"

    if [[ "$listen" != "127.0.0.1" ]]; then
        ask_yn "是否现在放行防火墙端口 ${port}/tcp？" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
        log_info "原端口 ${old_port}/tcp 若已在防火墙放行，不再使用时请手动关闭。"
    fi
}

# ── Share URI ─────────────────────────────────────────────────────────────────
xhttp_show_share() {
    local tag="$1"
    _xhttp_sync_from_live
    [[ -z "$tag" ]] && { _show_node_list; ask tag "节点标识"; }
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }

    local uuid;       uuid=$(echo "$node"       | jq -r '.uuid')
    local domain;     domain=$(echo "$node"     | jq -r '.domain // ""')
    local path;       path=$(echo "$node"       | jq -r '.path')
    local mode;       mode=$(echo "$node"       | jq -r '.mode')
    local listen;     listen=$(echo "$node"     | jq -r '.listen_addr // "127.0.0.1"')
    local port;       port=$(echo "$node"       | jq -r '.port')
    local sn;         sn=$(echo "$node"         | jq -r '.server_name // .domain // ""')
    local public_port; public_port=$(echo "$node" | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')

    local net host ref_port
    case "$mode" in
        xhttp|splithttp) net="xhttp" ;;
        upgrade|ws)      net="ws" ;;
        grpc)            net="grpc" ;;
        reality-layer)   net="xhttp" ;;
    esac

    if [[ "$listen" == "127.0.0.1" && -n "$domain" ]]; then
        host="$domain"; ref_port="$public_port"
    else
        host=$(get_ipv4); ref_port="$public_port"
    fi

    local encoded_path
    encoded_path=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$path" 2>/dev/null || echo "${path}")

    local security; [[ "$mode" == "reality-layer" ]] && security="reality" || security="tls"
    local query="encryption=none&security=${security}&sni=${sn}&type=${net}"
    case "$mode" in
        grpc)
            query="${query}&serviceName=${encoded_path}"
            ;;
        reality-layer)
            local pub_key; pub_key=$(echo "$node" | jq -r '.public_key')
            local sid; sid=$(echo "$node" | jq -r '.short_id')
            query="${query}&path=${encoded_path}&mode=auto&fp=chrome&pbk=${pub_key}&sid=${sid}"
            ;;
        xhttp|splithttp)
            query="${query}&path=${encoded_path}&mode=auto"
            ;;
        *)
            query="${query}&path=${encoded_path}"
            ;;
    esac
    local uri="vless://${uuid}@${host}:${ref_port}?${query}#PSM-${tag}"

    echo -e "\n${BOLD}${GREEN}── XHTTP 分享链接 ──${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
_xhttp_check_deps() {
    ensure_pkg_deps jq qrencode python3
    if ! [[ -f "$XRAY_BIN" ]]; then
        log_warn "Xray 未安装。"
        ask_yn "是否现在安装 Xray？" Y \
            && xray_install \
            || { log_error "XHTTP 需要 Xray。"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
xhttp_menu() {
    _xhttp_check_deps || return
    while true; do
        # 每轮菜单前同步一次，避免任何走 _xhttp_apply_all 的操作
        # 用过期的节点存储覆盖 config.json 中的手动修改。
        _xhttp_sync_from_live
        show_menu "XHTTP 管理" \
            "添加节点" \
            "删除节点" \
            "修改路径" \
            "修改 UUID" \
            "修改端口" \
            "显示分享链接 / URI" \
            "列出节点"

        case "$MENU_CHOICE" in
            1) xhttp_add_node ;;
            2) xhttp_delete_node ;;
            3) xhttp_modify_path ;;
            4) xhttp_modify_uuid ;;
            5) xhttp_modify_port ;;
            6) xhttp_show_share "" ;;
            7) _show_node_list ;;
            0) return ;;
        esac
        press_enter
    done
}
