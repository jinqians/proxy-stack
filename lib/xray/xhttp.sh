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
        log_info "$(t xray.manual_sync_port_uuid)"
    fi
    return 0
}

_show_node_list() {
    local lst; lst=$(_xhttp_list)
    [[ -z "$lst" ]] && { log_warn "$(t xray.xhttp.no_nodes)"; return; }
    echo -e "\n${BOLD}$(t xray.xhttp.nodes_title)${NC}"
    printf "  %-20s %-6s %-15s %-14s %s\n" "$(t xray.header.tag)" "$(t xray.header.port)" "$(t xray.header.listen)" "$(t xray.header.mode)" "$(t xray.header.domain)"
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

    # TLS 三件套对所有走 TLS 的模式都一样，抽出来避免四份重复
    local tls_common
    tls_common=$(jq -n --arg sn "$domain" \
        --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/privkey.pem" \
        '{ "serverName": $sn,
           "certificates": [{ "certificateFile": $cert, "keyFile": $key }] }')

    local stream_json
    case "$mode" in
        xhttp|splithttp)
            stream_json=$(jq -n --arg path "$path" --argjson tls "$tls_common" \
                '{ "network": "xhttp", "security": "tls",
                   "xhttpSettings": { "path": $path, "mode": "auto" },
                   "tlsSettings": ($tls + { "alpn": ["h2","http/1.1"] }) }')
            ;;
        upgrade|ws)
            # 历史遗留：模式名叫 upgrade，产出的却是 WebSocket。菜单上的标签一直
            # 写的是 WebSocket，行为与标签一致，所以保持原样——改名会让已存节点
            # （store 里 mode="upgrade"）在下一次 apply 时找不到分支。
            # 真正的 HTTPUpgrade 传输是下面独立的 httpupgrade 模式。
            stream_json=$(jq -n --arg path "$path" --argjson tls "$tls_common" \
                '{ "network": "websocket", "security": "tls",
                   "wsSettings": { "path": $path },
                   "tlsSettings": ($tls + { "alpn": ["http/1.1"] }) }')
            ;;
        grpc)
            # serviceName 不带前导斜杠，客户端那边也一样，多一个斜杠就对不上
            stream_json=$(jq -n --arg service "${path#/}" --argjson tls "$tls_common" \
                '{ "network": "grpc", "security": "tls",
                   "grpcSettings": { "serviceName": $service },
                   "tlsSettings": ($tls + { "alpn": ["h2"] }) }')
            ;;
        httpupgrade)
            # HTTPUpgrade：只借用 HTTP Upgrade 握手，之后是裸 TCP，没有 WebSocket
            # 的帧开销。host 必须填，反代与 CDN 靠它路由。
            stream_json=$(jq -n --arg path "$path" --arg host "$domain" --argjson tls "$tls_common" \
                '{ "network": "httpupgrade", "security": "tls",
                   "httpupgradeSettings": { "path": $path, "host": $host },
                   "tlsSettings": ($tls + { "alpn": ["http/1.1"] }) }')
            ;;
        h2)
            # HTTP/2：host 是数组（Xray 的 httpSettings 允许多个虚拟主机名）。
            # alpn 必须只有 h2，混进 http/1.1 会让客户端协商到 1.1 后连不上。
            stream_json=$(jq -n --arg path "$path" --arg host "$domain" --argjson tls "$tls_common" \
                '{ "network": "http", "security": "tls",
                   "httpSettings": { "path": $path, "host": [$host] },
                   "tlsSettings": ($tls + { "alpn": ["h2"] }) }')
            ;;
        mkcp)
            # mKCP 走 UDP，自带伪装头与 seed 加密，因此不套 TLS，也就不需要域名和
            # 证书。security 必须显式写 none——省略会让 Xray 按默认走 TLS 分支。
            local kcp_seed;   kcp_seed=$(echo "$n" | jq -r '.kcp_seed // empty')
            local kcp_header; kcp_header=$(echo "$n" | jq -r '.kcp_header // "none"')
            stream_json=$(jq -n --arg seed "$kcp_seed" --arg header "$kcp_header" \
                '{ "network": "kcp", "security": "none",
                   "kcpSettings": {
                     "seed": $seed,
                     "header": { "type": $header },
                     "mtu": 1350, "tti": 50,
                     "uplinkCapacity": 5, "downlinkCapacity": 20,
                     "congestion": false,
                     "readBufferSize": 2, "writeBufferSize": 2
                   } }')
            ;;
        reality-layer)
            local priv_key; priv_key=$(echo "$n" | jq -r '.private_key // empty')
            local sid;      sid=$(echo "$n"      | jq -r '.short_id // empty')
            local sn;       sn=$(echo "$n"       | jq -r '.server_name // empty')
            # Reality 之上的传输层可选。默认 xhttp（保持与老节点一致）。
            local rtrans;   rtrans=$(echo "$n"   | jq -r '.reality_transport // "xhttp"')
            # 回落限速：仅在 dest 被判定为共享 CDN 前端时写出（见 common.sh 的取值权衡）。
            # 只影响「认证未通过」的回落连接，已认证客户端的代理流量不受任何影响。
            local limit_fb; limit_fb=$(echo "$n" | jq -r '.limit_fallback // false')
            local limit_json='{}'
            if [[ "$limit_fb" == "true" ]]; then
                limit_json=$(jq -n \
                    --argjson after "$REALITY_FALLBACK_AFTER_BYTES" \
                    --argjson rate  "$REALITY_FALLBACK_BYTES_PER_SEC" \
                    --argjson burst "$REALITY_FALLBACK_BURST_BYTES_PER_SEC" \
                    '{ "limitFallbackUpload":   { "afterBytes": $after, "bytesPerSec": $rate, "burstBytesPerSec": $burst },
                       "limitFallbackDownload": { "afterBytes": $after, "bytesPerSec": $rate, "burstBytesPerSec": $burst } }')
            fi

            local transport_json
            case "$rtrans" in
                ws)   transport_json=$(jq -n --arg path "$path" \
                        '{ "network": "websocket", "wsSettings": { "path": $path } }') ;;
                grpc) transport_json=$(jq -n --arg svc "${path#/}" \
                        '{ "network": "grpc", "grpcSettings": { "serviceName": $svc } }') ;;
                h2)   transport_json=$(jq -n --arg path "$path" --arg host "$sn" \
                        '{ "network": "http", "httpSettings": { "path": $path, "host": [$host] } }') ;;
                *)    transport_json=$(jq -n --arg path "$path" \
                        '{ "network": "xhttp", "xhttpSettings": { "path": $path, "mode": "auto" } }') ;;
            esac

            stream_json=$(jq -n \
                --arg sn "$sn" --arg priv "$priv_key" --arg sid "$sid" \
                --argjson limit "$limit_json" --argjson transport "$transport_json" \
                '$transport + {
                  "security": "reality",
                  "realitySettings": ({
                    "show": false,
                    "dest": ($sn + ":443"),
                    "serverNames": [$sn],
                    "privateKey": $priv,
                    "shortIds": [$sid]
                  } + $limit)
                }')
            ;;
        *)
            die "$(t xray.xhttp.unknown_mode "$mode")"
            ;;
    esac

    local fallbacks_json="[]"
    # reality-layer 与 mkcp 都不在 Xray 侧终止 TLS → 没有可回落的 HTTP 服务
    if [[ "$mode" != "reality-layer" && "$mode" != "mkcp" && "$fallback_enabled" == "true" ]]; then
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

    ask tag  "$(t xray.ask.node_tag)"   "xhttp-$((count+1))"
    ask port "$(t xray.ask.local_port)" "$((XHTTP_DEFAULT_PORT + count * 10))"
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    echo -e "\n  $(t xray.xhttp.transport_title)"
    echo -e "  $(t xray.xhttp.mode1)"
    echo -e "  $(t xray.xhttp.mode2)"
    echo -e "  $(t xray.xhttp.mode3)"
    echo -e "  $(t xray.xhttp.mode4)"
    echo -e "  $(t xray.xhttp.mode5)"
    echo -e "  $(t xray.xhttp.mode6)"
    echo -e "  $(t xray.xhttp.mode7)"
    read -rp "$(echo -e "${CYAN}$(t xray.xhttp.ask_mode)${NC}")" mc
    case "${mc:-1}" in
        1) mode="xhttp" ;;
        2) mode="upgrade" ;;
        3) mode="grpc" ;;
        4) mode="reality-layer" ;;
        5) mode="httpupgrade" ;;
        6) mode="h2" ;;
        7) mode="mkcp" ;;
        *) mode="xhttp" ;;
    esac

    # Reality 之上的传输层可选
    local reality_transport="xhttp"
    if [[ "$mode" == "reality-layer" ]]; then
        echo ""
        echo -e "  $(t xray.xhttp.rt1)"
        echo -e "  $(t xray.xhttp.rt2)"
        echo -e "  $(t xray.xhttp.rt3)"
        echo -e "  $(t xray.xhttp.rt4)"
        local rc; read -rp "$(echo -e "${CYAN}$(t xray.xhttp.ask_reality_transport)${NC}")" rc
        case "${rc:-1}" in
            2) reality_transport="ws" ;;
            3) reality_transport="grpc" ;;
            4) reality_transport="h2" ;;
            *) reality_transport="xhttp" ;;
        esac
    fi

    # mKCP 不走 TLS，需要 seed 与伪装头类型
    local kcp_seed="" kcp_header="none"
    if [[ "$mode" == "mkcp" ]]; then
        echo ""
        log_info "$(t xray.xhttp.mkcp_hint)"
        ask kcp_seed "$(t xray.xhttp.ask_kcp_seed)" "$(rand_str 16)"
        echo -e "  $(t xray.xhttp.kcp_h1)"
        echo -e "  $(t xray.xhttp.kcp_h2)"
        echo -e "  $(t xray.xhttp.kcp_h3)"
        echo -e "  $(t xray.xhttp.kcp_h4)"
        local hc; read -rp "$(echo -e "${CYAN}$(t xray.xhttp.ask_kcp_header)${NC}")" hc
        case "${hc:-1}" in
            2) kcp_header="srtp" ;;
            3) kcp_header="utp" ;;
            4) kcp_header="wechat-video" ;;
            *) kcp_header="none" ;;
        esac
    fi

    # ── Domain + cert：只有走 TLS 的模式需要 ─────────────────────────────────
    # reality-layer 借伪装站的证书，mkcp 根本不套 TLS，两者都不需要自有域名。
    domain=""
    if [[ "$mode" != "reality-layer" && "$mode" != "mkcp" ]]; then
        echo -e "  ${YELLOW}$(t xray.xhttp.mode_need_cert)${NC}"
        ask domain "$(t xray.ask.domain_required)"
        [[ -z "$domain" ]] && { log_error "$(t xray.xhttp.domain_required)"; return 1; }
        source "$LIB_DIR/cert.sh"
        cert_ensure_domain "$domain" || {
            log_warn "$(t xray.cancel_no_cert)"
            return 1
        }
    fi

    # ── Nginx reverse proxy choice ────────────────────────────────────────────
    local listen_addr="" use_nginx=0 public_port fallback_enabled=true
    echo ""
    # mKCP 走 UDP，而 443 分流表是 Nginx stream 层按 TLS ClientHello 的 SNI 路由的，
    # 既没有 TCP 也没有 SNI，挂不上去。直接跳过询问，避免给出一个必然失败的选项。
    if [[ "$mode" == "mkcp" ]]; then
        log_info "$(t xray.xhttp.mkcp_no_mount)"
        listen_addr="0.0.0.0"; public_port="$port"; fallback_enabled=false
    elif ask_yn "$(t xray.ask.nginx_proxy)" N; then
        use_nginx=1; listen_addr="127.0.0.1"
        if ! is_installed nginx; then
            log_warn "$(t xray.nginx_not_installed)"
            ask_yn "$(t xray.ask_install_nginx)" Y \
                && nginx_install \
                || { log_error "$(t xray.proxy_need_nginx)"; return 1; }
        fi
        if [[ -n "$domain" ]]; then
            _sni_add_entry "$domain" "127.0.0.1:${port}"
        fi
        public_port=443
    else
        listen_addr="0.0.0.0"
        public_port="$port"
        if [[ "$mode" != "reality-layer" ]] && ! is_installed nginx; then
            ask_yn "$(t xray.ask_nginx_fallback)" Y \
                && nginx_install \
                || fallback_enabled=false
        fi
    fi

    ask uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask path "$(t xray.xhttp.ask_path_auto)" ""
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
        --arg reality_transport "$reality_transport" \
        --arg kcp_seed "$kcp_seed" --arg kcp_header "$kcp_header" \
        '{tag:$tag, port:$port, public_port:$public_port, uuid:$uuid, domain:$domain, path:$path, mode:$mode, listen_addr:$listen_addr, fallback_enabled:$fallback_enabled}
         # 只在用得上的模式里写出这些字段，避免给每个节点塞一堆恒为默认值的键
         | (if $mode == "reality-layer" then .reality_transport = $reality_transport else . end)
         | (if $mode == "mkcp" then .kcp_seed = $kcp_seed | .kcp_header = $kcp_header else . end)')

    if [[ "$mode" == "reality-layer" ]]; then
        log_step "$(t xray.xhttp.generating_reality_keys)"
        local pair; pair=$(xray_gen_x25519_keys) || return 1
        local priv_key="${pair%%$'\t'*}"
        local pub_key="${pair#*$'\t'}"
        local sid; sid=$(openssl rand -hex 4)
        local sn=""
        if ask_yn "$(t xray.xhttp.ask_discover_sni)" Y; then
            source "$LIB_DIR/xray/sni_finder.sh"
            local _picked; _picked=$(sni_finder_pick_one) || true
            # reality-layer 的 dest 固定为 sn:443（见 _xhttp_build_inbound），此处只取 SNI
            [[ -n "$_picked" ]] && { sn="${_picked%%|*}"; log_info "$(t xray.xhttp.picked_sni "$sn")"; }
        fi
        # 不预置伪装域名：reality-layer 的 dest 就是 sn:443，若 sn 落在多租户 CDN 前端上，
        # Reality 的回落会把本机变成通往整个 CDN 的免费中继（见 common.sh）。
        while [[ -z "$sn" ]]; do
            ask sn "$(t xray.xhttp.ask_sni)" ""
            [[ -n "$sn" ]] || log_error "$(t common.reality.sni_empty)"
        done
        local _xh_shared=false
        if reality_dest_is_shared_frontend "$sn" 443; then
            log_warn "$(t common.reality.dest_shared_frontend "${REALITY_DEST_SHARED_BY:-unknown}")"
            ask_yn "$(t common.reality.proceed_anyway)" N || return 1
            _xh_shared=true
        fi
        node=$(echo "$node" | jq \
            --arg pk "$priv_key" --arg pub "$pub_key" \
            --arg sid "$sid" --arg sn "$sn" --argjson lfb "$_xh_shared" \
            '.private_key=$pk | .public_key=$pub | .short_id=$sid | .server_name=$sn
             | .limit_fallback=$lfb')
        if (( use_nginx )); then
            _sni_add_entry "$sn" "127.0.0.1:${port}"
        fi
        log_info "$(t xray.xhttp.keys "$pub_key" "$sid")"
    fi

    _xhttp_upsert "$node"
    _xhttp_apply_all

    echo ""
    log_ok "$(t xray.xhttp.added "$tag" "$listen_addr" "$port")"

    if (( use_nginx == 0 )); then
        # mKCP 是 UDP 传输，放行 TCP 端口对它毫无用处
        local _fw_proto="tcp"; [[ "$mode" == "mkcp" ]] && _fw_proto="udp"
        ask_yn "$(t xray.ask.open_firewall_proto "$port" "$_fw_proto")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "$_fw_proto"
        }
    fi

    echo ""
    xhttp_show_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
xhttp_delete_node() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.delete_node_tag)"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local domain; domain=$(echo "$node" | jq -r '.domain // ""')
    ask_yn "$(t xray.ask.delete_node "$tag")" N || return 0
    _xhttp_delete "$tag"
    [[ -n "$domain" ]] && _sni_remove_entry "$domain" 2>/dev/null || true
    _xhttp_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t xray.deleted)"
}

xhttp_modify_path() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local new_path; ask new_path "$(t xray.xhttp.ask_new_path)" ""
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
    log_ok "$(t xray.xhttp.path_updated "$new_path")"
}

xhttp_modify_uuid() {
    _xhttp_sync_from_live
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local new_uuid; ask new_uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$new_uuid" ]] && new_uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid=$v')
    _xhttp_upsert "$node"
    _xhttp_apply_all
    log_ok "$(t xray.uuid_updated_value "$new_uuid")"
}

xhttp_modify_port() {
    _xhttp_sync_from_live
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local old_port listen skey
    old_port=$(echo "$node" | jq -r '.port')
    listen=$(echo "$node"   | jq -r '.listen_addr // "127.0.0.1"')
    skey=$(echo "$node"     | jq -r 'if (.domain // "") != "" then .domain else (.server_name // "") end')

    local port
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
    _xhttp_upsert "$node"
    [[ "$listen" == "127.0.0.1" && -n "$skey" ]] && _sni_add_entry "$skey" "127.0.0.1:${port}" || true
    _xhttp_apply_all
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
xhttp_show_share() {
    local tag="$1"
    _xhttp_sync_from_live
    [[ -z "$tag" ]] && { _show_node_list; ask tag "$(t xray.ask.node_tag)"; }
    local node; node=$(_xhttp_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

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
        httpupgrade)     net="httpupgrade" ;;
        h2)              net="http" ;;
        mkcp)            net="kcp" ;;
        # Reality 之上的传输层是可选的，链接里的 type 必须跟着走，
        # 否则客户端会按 xhttp 去握手而服务端在等 ws / grpc / h2。
        reality-layer)
            case "$(echo "$node" | jq -r '.reality_transport // "xhttp"')" in
                ws)   net="ws" ;;
                grpc) net="grpc" ;;
                h2)   net="http" ;;
                *)    net="xhttp" ;;
            esac
            ;;
    esac

    if [[ "$listen" == "127.0.0.1" && -n "$domain" ]]; then
        host="$domain"; ref_port="$public_port"
    else
        host=$(get_ipv4); ref_port="$public_port"
    fi

    # 用 common.sh 的 url_encode（jq @uri）。原先这里调 python3，而项目其余部分
    # 并不依赖 python3——没装时会静默退回不编码，路径含特殊字符的链接就是坏的。
    local encoded_path
    encoded_path=$(url_encode "$path") || return 1

    local security
    case "$mode" in
        reality-layer) security="reality" ;;
        mkcp)          security="none" ;;   # mKCP 自带伪装与 seed 加密，不套 TLS
        *)             security="tls" ;;
    esac
    local query="encryption=none&security=${security}&type=${net}"
    # mKCP 没有 TLS 就没有 SNI，带上只会让客户端困惑
    [[ "$mode" != "mkcp" ]] && query="${query}&sni=${sn}"
    case "$mode" in
        grpc)
            query="${query}&serviceName=${encoded_path}"
            ;;
        mkcp)
            local kcp_seed; kcp_seed=$(echo "$node" | jq -r '.kcp_seed // ""')
            local kcp_header; kcp_header=$(echo "$node" | jq -r '.kcp_header // "none"')
            query="${query}&headerType=${kcp_header}"
            [[ -n "$kcp_seed" ]] && query="${query}&seed=$(url_encode "$kcp_seed")"
            ;;
        h2|httpupgrade)
            query="${query}&path=${encoded_path}&host=${sn}"
            ;;
        reality-layer)
            local pub_key; pub_key=$(echo "$node" | jq -r '.public_key')
            local sid; sid=$(echo "$node" | jq -r '.short_id')
            local rt; rt=$(echo "$node" | jq -r '.reality_transport // "xhttp"')
            if [[ "$rt" == "grpc" ]]; then
                query="${query}&serviceName=${encoded_path}&fp=chrome&pbk=${pub_key}&sid=${sid}"
            else
                query="${query}&path=${encoded_path}&fp=chrome&pbk=${pub_key}&sid=${sid}"
                [[ "$rt" == "xhttp" ]] && query="${query}&mode=auto"
            fi
            ;;
        xhttp|splithttp)
            query="${query}&path=${encoded_path}&mode=auto"
            ;;
        *)
            query="${query}&path=${encoded_path}"
            ;;
    esac
    local uri="vless://${uuid}@${host}:${ref_port}?${query}#PSM-${tag}"

    echo -e "\n${BOLD}${GREEN}$(t xray.xhttp.share_title)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
_xhttp_check_deps() {
    ensure_pkg_deps jq qrencode
    if ! [[ -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
        ask_yn "$(t xray.ask_install_xray)" Y \
            && xray_install \
            || { log_error "$(t xray.xhttp.need_xray)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
xhttp_menu() {
    _xhttp_check_deps || return
    while true; do
        # 每轮菜单前同步一次，避免任何走 _xhttp_apply_all 的操作
        # 用过期的节点存储覆盖 config.json 中的手动修改。
        _xhttp_sync_from_live
        show_menu "$(t xray.xhttp.menu.title)" \
            "$(t xray.xhttp.menu.add)" \
            "$(t xray.xhttp.menu.delete)" \
            "$(t xray.xhttp.menu.path)" \
            "$(t xray.xhttp.menu.uuid)" \
            "$(t xray.xhttp.menu.port)" \
            "$(t xray.xhttp.menu.share)" \
            "$(t xray.xhttp.menu.list)"

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
