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

# 节点存储是唯一事实源：手动编辑 config.json 后菜单显示旧值，且下一次
# _vision_apply_all 会覆盖手动修改。查看/修改前把 config.json 的端口/UUID
# 同步回存储（Vision 入站与节点 1:1，按 tag 匹配）。
_vision_sync_from_live() {
    [[ -f "$XRAY_CFG" ]] || return 0
    local nodes; nodes=$(_vision_load)
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
        _vision_save "$nodes"
        log_info "$(t xray.manual_sync_port_uuid)"
    fi
    return 0
}

_show_node_list() {
    local lst; lst=$(_vision_list)
    if [[ -z "$lst" ]]; then log_warn "$(t xray.vision.no_nodes)"; return; fi
    echo -e "\n${BOLD}$(t xray.vision.nodes_title)${NC}"
    printf "  %-20s %-6s %-15s %s\n" "$(t xray.header.tag)" "$(t xray.header.port)" "$(t xray.header.listen)" "$(t xray.header.domain)"
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
    _vision_sync_from_live
    log_step "$(t xray.vision.adding)"
    echo -e "  ${YELLOW}$(t xray.vision.need_domain_cert)${NC}\n"

    local count; count=$(_vision_load | jq 'length')
    local tag port uuid domain flow

    ask tag  "$(t xray.ask.node_tag)"   "vision-$((count+1))"
    ask port "$(t xray.ask.local_port)" "$((VISION_DEFAULT_PORT + count))"
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    # ── Domain + cert (always required for Vision) ────────────────────────────
    ask domain "$(t xray.ask.domain_required)"
    [[ -z "$domain" ]] && { log_error "$(t xray.vision.domain_required)"; return 1; }

    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$domain" || {
        log_warn "$(t xray.vision.cancel_no_tls)"
        return 1
    }

    ask uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask flow "$(t xray.ask.flow)" "xtls-rprx-vision"

    # ── Nginx reverse proxy choice ────────────────────────────────────────────
    local listen_addr="" use_nginx=0 public_port fallback_enabled=true
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
        if ! is_installed nginx; then
            ask_yn "$(t xray.ask_nginx_fallback)" Y \
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
    log_ok "$(t xray.vision.added "$tag" "$listen_addr" "$port")"

    if (( use_nginx == 0 )); then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
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
    local tag; ask tag "$(t xray.ask.delete_node_tag)"
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local domain; domain=$(echo "$node" | jq -r '.domain')
    ask_yn "$(t xray.ask.delete_node "$tag")" N || return 0
    _vision_delete "$tag"
    _sni_remove_entry "$domain" 2>/dev/null || true
    _vision_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t xray.deleted)"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
vision_modify_domain() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local old_domain; old_domain=$(echo "$node" | jq -r '.domain')
    local new_domain; ask new_domain "$(t xray.ask.new_domain)"
    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$new_domain" || { log_warn "$(t xray.cancel_no_cert)"; return 1; }
    _sni_remove_entry "$old_domain" 2>/dev/null || true
    node=$(echo "$node" | jq --arg v "$new_domain" '.domain=$v')
    _vision_upsert "$node"
    local port; port=$(echo "$node" | jq -r '.port')
    local listen_addr; listen_addr=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
    [[ "$listen_addr" == "127.0.0.1" ]] && _sni_add_entry "$new_domain" "127.0.0.1:${port}" 2>/dev/null || true
    _vision_apply_all
    log_ok "$(t xray.domain_updated "$new_domain")"
}

vision_modify_uuid() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local new_uuid; ask new_uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$new_uuid" ]] && new_uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid=$v')
    _vision_upsert "$node"
    _vision_apply_all
    log_ok "$(t xray.uuid_updated)"
}

vision_modify_port() {
    _vision_sync_from_live
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local old_port listen domain
    old_port=$(echo "$node" | jq -r '.port')
    listen=$(echo "$node"   | jq -r '.listen_addr // "127.0.0.1"')
    domain=$(echo "$node"   | jq -r '.domain')

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
    _vision_upsert "$node"
    [[ "$listen" == "127.0.0.1" ]] && _sni_add_entry "$domain" "127.0.0.1:${port}" || true
    _vision_apply_all
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
vision_show_share() {
    local tag="$1"
    _vision_sync_from_live
    [[ -z "$tag" ]] && { _show_node_list; ask tag "$(t xray.ask.node_tag)"; }
    local node; node=$(_vision_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

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
    echo -e "\n${BOLD}${GREEN}$(t xray.vision.share_title)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
_vision_check_deps() {
    ensure_pkg_deps jq qrencode
    if ! [[ -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
        ask_yn "$(t xray.ask_install_xray)" Y \
            && xray_install \
            || { log_error "$(t xray.vision.need_xray)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
vision_menu() {
    _vision_check_deps || return
    while true; do
        # 每轮菜单前同步一次，避免任何走 _vision_apply_all 的操作
        # 用过期的节点存储覆盖 config.json 中的手动修改。
        _vision_sync_from_live
        show_menu "$(t xray.vision.menu.title)" \
            "$(t xray.vision.menu.add)" \
            "$(t xray.vision.menu.delete)" \
            "$(t xray.vision.menu.domain)" \
            "$(t xray.vision.menu.uuid)" \
            "$(t xray.vision.menu.port)" \
            "$(t xray.vision.menu.share)" \
            "$(t xray.vision.menu.list)"

        case "$MENU_CHOICE" in
            1) vision_add_node ;;
            2) vision_delete_node ;;
            3) vision_modify_domain ;;
            4) vision_modify_uuid ;;
            5) vision_modify_port ;;
            6) vision_show_share "" ;;
            7) _show_node_list ;;
            0) return ;;
        esac
        press_enter
    done
}
