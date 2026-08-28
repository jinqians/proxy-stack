#!/usr/bin/env bash
# xray/trojan.sh — Trojan (TCP+TLS) node management via Xray
#
# 结构与 xray/vision.sh 平行：节点存储（config/xray/trojan.json）是唯一事实源，
# apply 时整体重建 trojan 入站。Trojan 与 Vision 的差别只有三处：
#   1. 凭据是 password 而非 UUID（Trojan 协议本身没有 UUID 概念）
#   2. 没有 flow 字段（XTLS flow 是 VLESS 专属）
#   3. 回落是协议设计的一部分——认证失败的连接交给 fallbacks，所以默认开启
# 其余（域名+证书必需、可挂 Nginx 443 SNI 分流、直连独占端口）与 Vision 一致。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$LIB_DIR/nginx.sh"

TROJAN_CFG="$CFG_DIR/xray/trojan.json"
TROJAN_DEFAULT_PORT=4443

# ── Node store ────────────────────────────────────────────────────────────────
_trojan_load() { [[ -f "$TROJAN_CFG" ]] || echo "[]" > "$TROJAN_CFG"; cat "$TROJAN_CFG"; }
_trojan_save() { mkdir -p "$(dirname "$TROJAN_CFG")"; echo "$1" > "$TROJAN_CFG"; }

_trojan_get_by_tag() {
    _trojan_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null
}

_trojan_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_trojan_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _trojan_save "$nodes"
}

_trojan_delete() {
    local nodes; nodes=$(_trojan_load)
    _trojan_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_trojan_list() {
    _trojan_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "127.0.0.1")\t\(.domain)"' 2>/dev/null
}

# 节点存储是唯一事实源：手动编辑 config.json 后菜单会显示旧值，且下一次
# _trojan_apply_all 会覆盖手动修改。查看/修改前把 config.json 里的端口和密码
# 同步回存储（Trojan 入站与节点 1:1，按 tag 匹配）。与 vision 同源逻辑。
_trojan_sync_from_live() {
    [[ -f "$XRAY_CFG" ]] || return 0
    local nodes; nodes=$(_trojan_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag pass port listen domain live live_port live_pass
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node"    | jq -r '.tag')
        pass=$(echo "$node"   | jq -r '.password')
        port=$(echo "$node"   | jq -r '.port')
        listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
        domain=$(echo "$node" | jq -r '.domain')
        live=$(jq -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) // empty' "$XRAY_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue
        live_port=$(echo "$live" | jq -r '.port')
        live_pass=$(echo "$live" | jq -r '.settings.clients[0].password // empty')
        [[ -z "$live_pass" ]] && live_pass="$pass"
        [[ "$live_port" == "$port" && "$live_pass" == "$pass" ]] && continue
        changed=1
        if [[ "$listen" == "127.0.0.1" && "$live_port" != "$port" ]]; then
            _sni_add_entry "$domain" "127.0.0.1:${live_port}" 2>/dev/null || true
        fi
        nodes=$(echo "$nodes" | jq --arg t "$tag" --arg p "$live_port" --arg w "$live_pass" \
            '(.[] | select(.tag == $t)) |= (.port = ($p|tonumber) | .password = $w
             | (if (.listen_addr // "127.0.0.1") != "127.0.0.1" then .public_port = ($p|tonumber) else . end))')
    done
    if (( changed )); then
        _trojan_save "$nodes"
        log_info "$(t xray.manual_sync_port_uuid)"
    fi
    return 0
}

_trojan_show_node_list() {
    local lst; lst=$(_trojan_list)
    if [[ -z "$lst" ]]; then log_warn "$(t xray.trojan.no_nodes)"; return; fi
    echo -e "\n${BOLD}$(t xray.trojan.nodes_title)${NC}"
    printf "  %-20s %-6s %-15s %s\n" "$(t xray.header.tag)" "$(t xray.header.port)" "$(t xray.header.listen)" "$(t xray.header.domain)"
    echo "$lst" | while IFS=$'\t' read -r t p l d; do
        printf "  %-20s %-6s %-15s %s\n" "$t" "$p" "$l" "$d"
    done
}

# ── Build inbound ─────────────────────────────────────────────────────────────
_trojan_build_inbound() {
    local n="$1"
    local tag;         tag=$(echo "$n"    | jq -r '.tag')
    local port;        port=$(echo "$n"   | jq -r '.port')
    local pass;        pass=$(echo "$n"   | jq -r '.password')
    local domain;      domain=$(echo "$n" | jq -r '.domain')
    local listen_addr; listen_addr=$(echo "$n" | jq -r '.listen_addr // "127.0.0.1"')
    local cert_dir="$NGINX_SSL_DIR/$domain"
    local fallback_enabled; fallback_enabled=$(echo "$n" | jq -r '.fallback_enabled // true')
    # Trojan 的回落是协议设计的一部分：认证失败的连接原样交给 fallbacks，
    # 探测者看到的是一个正常网站而不是连接重置。
    local fallbacks_json="[]"
    [[ "$fallback_enabled" == "true" ]] && fallbacks_json='[{"dest":"127.0.0.1:8080","xver":0}]'

    jq -n \
        --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" \
        --arg pass "$pass" \
        --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/privkey.pem" \
        --argjson fallbacks "$fallbacks_json" \
        '{
          "tag": $tag,
          "listen": $listen,
          "port": $port,
          "protocol": "trojan",
          "settings": {
            "clients": [{ "password": $pass }],
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

_trojan_apply_all() {
    local nodes; nodes=$(_trojan_load)
    local count; count=$(echo "$nodes" | jq 'length')

    # 只删 protocol == "trojan" 的入站。不能照抄 vision 里那条按
    # security/network 匹配的兜底条件——那会把 Vision 自己的入站也删掉。
    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select((.protocol // "") == "trojan"))' "$XRAY_CFG" > "$tmp" \
        && mv "$tmp" "$XRAY_CFG"

    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        xray_add_inbound "$(_trojan_build_inbound "$node")"
    done

    xray_test_restart
}

# ── Add node ──────────────────────────────────────────────────────────────────
trojan_add_node() {
    _trojan_sync_from_live
    log_step "$(t xray.trojan.adding)"
    echo -e "  ${YELLOW}$(t xray.trojan.need_domain_cert)${NC}\n"

    local count; count=$(_trojan_load | jq 'length')
    local tag port password domain

    ask tag  "$(t xray.ask.node_tag)"   "trojan-$((count+1))"
    ask port "$(t xray.ask.local_port)" "$((TROJAN_DEFAULT_PORT + count))"
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    ask domain "$(t xray.ask.domain_required)"
    [[ -z "$domain" ]] && { log_error "$(t xray.trojan.domain_required)"; return 1; }

    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$domain" || {
        log_warn "$(t xray.trojan.cancel_no_tls)"
        return 1
    }

    ask password "$(t xray.ask.password_auto)" ""
    [[ -z "$password" ]] && password=$(rand_str 20)

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
        --arg password "$password" --arg domain "$domain" \
        --arg listen_addr "$listen_addr" \
        --argjson public_port "$public_port" \
        --argjson fallback_enabled "$fallback_enabled" \
        '{tag:$tag, port:$port, public_port:$public_port, password:$password, domain:$domain, listen_addr:$listen_addr, fallback_enabled:$fallback_enabled}')
    _trojan_upsert "$node"
    _trojan_apply_all

    echo ""
    log_ok "$(t xray.trojan.added "$tag" "$listen_addr" "$port")"

    if (( use_nginx == 0 )); then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    trojan_show_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
trojan_delete_node() {
    _trojan_show_node_list
    local tag; ask tag "$(t xray.ask.delete_node_tag)"
    local node; node=$(_trojan_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local domain; domain=$(echo "$node" | jq -r '.domain')
    ask_yn "$(t xray.ask.delete_node "$tag")" N || return 0
    _trojan_delete "$tag"
    _sni_remove_entry "$domain" 2>/dev/null || true
    _trojan_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t xray.deleted)"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
trojan_modify_domain() {
    _trojan_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_trojan_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local old_domain; old_domain=$(echo "$node" | jq -r '.domain')
    local new_domain; ask new_domain "$(t xray.ask.new_domain)"
    source "$LIB_DIR/cert.sh"
    cert_ensure_domain "$new_domain" || { log_warn "$(t xray.cancel_no_cert)"; return 1; }
    _sni_remove_entry "$old_domain" 2>/dev/null || true
    node=$(echo "$node" | jq --arg v "$new_domain" '.domain=$v')
    _trojan_upsert "$node"
    local port; port=$(echo "$node" | jq -r '.port')
    local listen_addr; listen_addr=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
    [[ "$listen_addr" == "127.0.0.1" ]] && _sni_add_entry "$new_domain" "127.0.0.1:${port}" 2>/dev/null || true
    _trojan_apply_all
    log_ok "$(t xray.trojan.domain_updated "$tag" "$new_domain")"
}

trojan_modify_password() {
    _trojan_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_trojan_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local new_pass; ask new_pass "$(t xray.ask.password_auto)" ""
    [[ -z "$new_pass" ]] && new_pass=$(rand_str 20)
    node=$(echo "$node" | jq --arg v "$new_pass" '.password=$v')
    _trojan_upsert "$node"
    _trojan_apply_all
    log_ok "$(t xray.trojan.password_updated "$tag")"
    echo ""
    trojan_show_share "$tag"
}

trojan_modify_port() {
    _trojan_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_trojan_get_by_tag "$tag")
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
    _trojan_upsert "$node"
    [[ "$listen" == "127.0.0.1" ]] && _sni_add_entry "$domain" "127.0.0.1:${port}" || true
    _trojan_apply_all
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
trojan_show_share() {
    local tag="$1"
    _trojan_sync_from_live
    [[ -z "$tag" ]] && { _trojan_show_node_list; ask tag "$(t xray.ask.node_tag)"; }
    local node; node=$(_trojan_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

    local pass;   pass=$(echo "$node"   | jq -r '.password')
    local domain; domain=$(echo "$node" | jq -r '.domain')
    local listen; listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')
    local public_port; public_port=$(echo "$node" | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')

    # 挂 Nginx 时链接用域名:443；直连时用服务器 IP + 实际端口，但 SNI 仍是证书域名。
    local host
    if [[ "$listen" == "127.0.0.1" ]]; then
        host="$domain"
    else
        host=$(get_ipv4)
    fi

    # 分开声明与赋值：写成 local uri="...$(url_encode ...)..." 会让 local 的返回值
    # 覆盖掉 url_encode 的，jq 缺失时的失败会被静默吞掉（SC2155）。
    local enc_pass uri
    enc_pass=$(url_encode "$pass") || return 1
    uri="trojan://${enc_pass}@${host}:${public_port}?security=tls&sni=${domain}&type=tcp&alpn=h2%2Chttp%2F1.1#PSM-${tag}"
    echo -e "\n${BOLD}${GREEN}$(t xray.trojan.share_title)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
_trojan_check_deps() {
    ensure_pkg_deps jq qrencode
    if ! [[ -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
        ask_yn "$(t xray.ask_install_xray)" Y \
            && xray_install \
            || { log_error "$(t xray.trojan.need_xray)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
trojan_menu() {
    _trojan_check_deps || return
    while true; do
        _trojan_sync_from_live
        show_menu "$(t xray.trojan.menu.title)" \
            "$(t xray.trojan.menu.add)" \
            "$(t xray.trojan.menu.delete)" \
            "$(t xray.trojan.menu.domain)" \
            "$(t xray.trojan.menu.password)" \
            "$(t xray.trojan.menu.port)" \
            "$(t xray.trojan.menu.share)" \
            "$(t xray.trojan.menu.list)"

        case "$MENU_CHOICE" in
            1) trojan_add_node ;;
            2) trojan_delete_node ;;
            3) trojan_modify_domain ;;
            4) trojan_modify_password ;;
            5) trojan_modify_port ;;
            6) trojan_show_share "" ;;
            7) _trojan_show_node_list ;;
            0) return ;;
        esac
        press_enter
    done
}
