#!/usr/bin/env bash
# xray/vision.sh — VLESS + Vision (TLS) node management

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$LIB_DIR/nginx.sh"

VISION_CFG="$CFG_DIR/xray/vision.json"
VISION_DEFAULT_PORT=3443

# ── Node store ────────────────────────────────────────────────────────────────
_vision_load() { [[ -f "$VISION_CFG" ]] || echo "[]" > "$VISION_CFG"; cat "$VISION_CFG"; }
_vision_save() { mkdir -p "$(dirname "$VISION_CFG")"; echo "$1" > "$VISION_CFG"; }

_vision_get_by_tag() {
    _vision_load | jq ".[] | select(.tag == \"$1\")" 2>/dev/null
}

_vision_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_vision_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$tag\")) | . += [$n]")
    _vision_save "$nodes"
}

_vision_delete() {
    local nodes; nodes=$(_vision_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$1\"))")
    _vision_save "$nodes"
}

_vision_list() {
    _vision_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "127.0.0.1")\t\(.domain)"' 2>/dev/null
}

_show_node_list() {
    local lst; lst=$(_vision_list)
    if [[ -z "$lst" ]]; then log_warn "暂无 Vision 节点。"; return; fi
    echo -e "\n${BOLD}Vision 节点：${NC}"
    printf "  %-20s %-6s %-15s %s\n" "标识" "端口" "监听" "域名"
    echo "$lst" | while IFS=$'\t' read -r t p l d; do
        printf "  %-20s %-6s %-15s %s\n" "$t" "$p" "$l" "$d"
    done
}

# ── Build inbound ─────────────────────────────────────────────────────────────
_vision_build_inbound() {
    local n="$1"
    local tag;        tag=$(echo "$n"        | jq -r '.tag')
    local port;       port=$(echo "$n"       | jq -r '.port')
    local uuid;       uuid=$(echo "$n"       | jq -r '.uuid')
    local domain;     domain=$(echo "$n"     | jq -r '.domain')
    local flow;       flow=$(echo "$n"       | jq -r '.flow')
    local listen_addr; listen_addr=$(echo "$n" | jq -r '.listen_addr // "127.0.0.1"')
    local cert_dir="$NGINX_SSL_DIR/$domain"
    local fallback_enabled; fallback_enabled=$(echo "$n" | jq -r '.fallback_enabled // true')
    local fallbacks_json="[]"
    [[ "$fallback_enabled" == "true" ]] && fallbacks_json='[{"dest":"127.0.0.1:8080","xver":0}]'

    jq -n \
        --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" \
        --arg uuid "$uuid" --arg flow "$flow" \
        --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/privkey.pem" \
        --argjson fallbacks "$fallbacks_json" \
        '{
          "tag": $tag,
          "listen": $listen,
          "port": $port,
          "protocol": "vless",
          "settings": {
            "clients": [{ "id": $uuid, "flow": $flow }],
            "decryption": "none",
            "fallbacks": $fallbacks
          },
          "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
              "certificates": [{
                "certificateFile": $cert,
                "keyFile": $key
              }],
              "minVersion": "1.2",
              "alpn": ["h2", "http/1.1"]
            }
          },
          "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
        }'
}

_vision_apply_all() {
    local nodes; nodes=$(_vision_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(
        (.tag | startswith("vision")) or
        ((.streamSettings.security // "") == "tls" and (.streamSettings.network // "") == "tcp")
    ))' "$XRAY_CFG" > "$tmp" \
        && mv "$tmp" "$XRAY_CFG"

    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        xray_add_inbound "$(_vision_build_inbound "$node")"
    done

    xray_test_restart
}

# ── Add node ──────────────────────────────────────────────────────────────────
vision_add_node() {
    log_step "正在配置 VLESS + Vision（TLS）节点..."
    echo -e "  ${YELLOW}Vision 需要自己的域名和 TLS 证书。${NC}\n"

    local count; count=$(_vision_load | jq 'length')
    local tag port uuid domain flow

    ask tag  "节点标识"   "vision-$((count+1))"
    ask port "本机端口"   "$((VISION_DEFAULT_PORT + count))"
    _xray_check_port_conflict "$port" || { log_info "已取消"; return 1; }

    # ── Domain + cert (always required for Vision) ────────────────────────────
    ask domain "你的域名（必须解析到本机）"
    [[ -z "$domain" ]] && { log_error "Vision 需要填写域名。"; return 1; }

    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$domain" || {
        log_warn "取消——缺少有效的 TLS 证书。"
        return 1
    }

    ask uuid "UUID（留空自动生成）" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask flow "Flow 参数" "xtls-rprx-vision"

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
        _sni_add_entry "$domain" "127.0.0.1:${port}"
        public_port=443
    else
        listen_addr="0.0.0.0"
        public_port="$port"
        if ! is_installed nginx; then
            ask_yn "是否安装 Nginx 作为本地伪装 fallback？" Y \
                && nginx_install \
                || fallback_enabled=false
        fi
    fi

    if [[ "$fallback_enabled" == "true" ]] && is_installed nginx; then
        nginx_setup_http_camouflage "$domain" || fallback_enabled=false
    fi

    local node
    node=$(jq -n \
        --arg tag "$tag" --argjson port "$port" \
        --arg uuid "$uuid" --arg domain "$domain" \
        --arg flow "$flow" --arg listen_addr "$listen_addr" \
        --argjson public_port "$public_port" \
        --argjson fallback_enabled "$fallback_enabled" \
        '{tag:$tag, port:$port, public_port:$public_port, uuid:$uuid, domain:$domain, flow:$flow, listen_addr:$listen_addr, fallback_enabled:$fallback_enabled}')
    _vision_upsert "$node"
    _vision_apply_all

    echo ""
    log_ok "Vision 节点 '$tag' → ${listen_addr}:${port}"

    if (( use_nginx == 0 )); then
        ask_yn "是否现在放行防火墙端口 ${port}/tcp？" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    vision_show_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
vision_delete_node() {
    _show_node_list
    local tag; ask tag "要删除的节点标识"
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }
    local domain; domain=$(echo "$node" | jq -r '.domain')
    ask_yn "确认删除节点 '$tag'？" N || return 0
    _vision_delete "$tag"
    _sni_remove_entry "$domain" 2>/dev/null || true
    _vision_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "已删除。"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
vision_modify_domain() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }
    local old_domain; old_domain=$(echo "$node" | jq -r '.domain')
    local new_domain; ask new_domain "新域名"
    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$new_domain" || { log_warn "取消——无有效证书。"; return 1; }
    _sni_remove_entry "$old_domain" 2>/dev/null || true
    node=$(echo "$node" | jq --arg v "$new_domain" '.domain=$v')
    _vision_upsert "$node"
    local port; port=$(echo "$node" | jq -r '.port')
    local listen_addr; listen_addr=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
    [[ "$listen_addr" == "127.0.0.1" ]] && _sni_add_entry "$new_domain" "127.0.0.1:${port}" 2>/dev/null || true
    _vision_apply_all
    log_ok "域名已更新为 $new_domain"
}

vision_modify_uuid() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }
    local new_uuid; ask new_uuid "新 UUID（留空自动生成）" ""
    [[ -z "$new_uuid" ]] && new_uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid=$v')
    _vision_upsert "$node"
    _vision_apply_all
    log_ok "UUID 已更新。"
}

# ── Share URI ─────────────────────────────────────────────────────────────────
vision_show_share() {
    local tag="$1"
    [[ -z "$tag" ]] && { _show_node_list; ask tag "节点标识"; }
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到该节点"; return 1; }

    local uuid;   uuid=$(echo "$node"   | jq -r '.uuid')
    local domain; domain=$(echo "$node" | jq -r '.domain')
    local flow;   flow=$(echo "$node"   | jq -r '.flow')
    local port;   port=$(echo "$node"   | jq -r '.port')
    local listen; listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
    local public_port; public_port=$(echo "$node" | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')

    # If direct (no nginx), URI uses server IP + actual port; if nginx, uses domain:443
    local host ref_port
    if [[ "$listen" == "127.0.0.1" ]]; then
        host="$domain"; ref_port="$public_port"
    else
        host=$(get_ipv4); ref_port="$public_port"
    fi

    local uri="vless://${uuid}@${host}:${ref_port}?encryption=none&flow=${flow}&security=tls&sni=${domain}&type=tcp#PSM-${tag}"
    echo -e "\n${BOLD}${GREEN}── Vision 分享链接 ──${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
_vision_check_deps() {
    ensure_pkg_deps jq qrencode
    if ! [[ -f "$XRAY_BIN" ]]; then
        log_warn "Xray 未安装。"
        ask_yn "是否现在安装 Xray？" Y \
            && xray_install \
            || { log_error "Vision 需要 Xray。"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
vision_menu() {
    _vision_check_deps || return
    while true; do
        show_menu "Vision 管理" \
            "添加节点" \
            "删除节点" \
            "修改域名" \
            "修改 UUID" \
            "显示分享链接 / URI" \
            "列出节点"

        case "$MENU_CHOICE" in
            1) vision_add_node ;;
            2) vision_delete_node ;;
            3) vision_modify_domain ;;
            4) vision_modify_uuid ;;
            5) vision_show_share "" ;;
            6) _show_node_list ;;
            0) return ;;
        esac
        press_enter
    done
}
