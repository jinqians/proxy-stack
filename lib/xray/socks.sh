#!/usr/bin/env bash
# xray/socks.sh — SOCKS5 inbound via Xray
#
# 节点存储（config/xray/socks.json）是唯一事实源，apply 时整体重建 socks 入站。
#
# ⚠ SOCKS5 本身不加密，也不做任何伪装：凭据与全部流量都是明文，任何中间人都能看到，
# 端口被扫到就会被拿去当开放代理。因此本模块的默认监听地址是 127.0.0.1，只服务本机
# 程序、Docker 容器或作为代理链的一环。选择监听公网时会强制设置用户名密码，并明确
# 提示风险——但用户名密码同样是明文传输的，认证只挡住随手扫描，挡不住嗅探。
#
# 需要对外暴露的入站请用 Reality / Trojan / VMess，它们都有 TLS 外壳。
#
# 也因为没有 TLS 就没有 SNI，SOCKS5 无法挂到 Nginx 443 SNI 分流上（那张表按 SNI
# 路由）。node_cli 的 _node_cli_fronted_pair 刻意不包含 socks。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SOCKS_CFG="$CFG_DIR/xray/socks.json"
SOCKS_DEFAULT_PORT=1080

# ── Node store ────────────────────────────────────────────────────────────────
_socks_load() { [[ -f "$SOCKS_CFG" ]] || echo "[]" > "$SOCKS_CFG"; cat "$SOCKS_CFG"; }
_socks_save() { mkdir -p "$(dirname "$SOCKS_CFG")"; echo "$1" > "$SOCKS_CFG"; }

_socks_get_by_tag() { _socks_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_socks_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_socks_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _socks_save "$nodes"
}

_socks_delete() {
    local nodes; nodes=$(_socks_load)
    _socks_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_socks_list() {
    _socks_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "127.0.0.1")\t\(if (.username // "") == "" then "noauth" else "password" end)"' 2>/dev/null
}

_socks_show_node_list() {
    local lst; lst=$(_socks_list)
    if [[ -z "$lst" ]]; then log_warn "$(t xray.socks.no_nodes)"; return; fi
    echo -e "\n${BOLD}$(t xray.socks.nodes_title)${NC}"
    printf "  %-20s %-6s %-15s %s\n" "$(t xray.header.tag)" "$(t xray.header.port)" "$(t xray.header.listen)" "$(t xray.socks.header_auth)"
    echo "$lst" | while IFS=$'\t' read -r t p l a; do
        printf "  %-20s %-6s %-15s %s\n" "$t" "$p" "$l" "$a"
    done
}

# ── Build inbound ─────────────────────────────────────────────────────────────
# auth 字段只有 "noauth" / "password" 两个取值；写 password 时 accounts 不能为空，
# 否则 Xray 会拒绝所有连接（配置本身合法，表现为「能连上但一律认证失败」）。
_socks_build_inbound() {
    local n="$1"
    local tag;         tag=$(echo "$n"      | jq -r '.tag')
    local port;        port=$(echo "$n"     | jq -r '.port')
    local user;        user=$(echo "$n"     | jq -r '.username // ""')
    local pass;        pass=$(echo "$n"     | jq -r '.password // ""')
    local listen_addr; listen_addr=$(echo "$n" | jq -r '.listen_addr // "127.0.0.1"')
    local udp;         udp=$(echo "$n"      | jq -r '.udp // true')

    local settings
    if [[ -n "$user" ]]; then
        settings=$(jq -n --arg u "$user" --arg p "$pass" --argjson udp "$udp" \
            '{auth:"password", accounts:[{user:$u, pass:$p}], udp:$udp}')
    else
        settings=$(jq -n --argjson udp "$udp" '{auth:"noauth", udp:$udp}')
    fi

    jq -n \
        --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" \
        --argjson settings "$settings" \
        '{
          "tag": $tag,
          "listen": $listen,
          "port": $port,
          "protocol": "socks",
          "settings": $settings,
          "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
        }'
}

_socks_apply_all() {
    local nodes; nodes=$(_socks_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select((.protocol // "") == "socks"))' "$XRAY_CFG" > "$tmp" \
        && mv "$tmp" "$XRAY_CFG"

    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        xray_add_inbound "$(_socks_build_inbound "$node")"
    done

    xray_test_restart
}

# ── Add node ──────────────────────────────────────────────────────────────────
socks_add_node() {
    log_step "$(t xray.socks.adding)"
    echo -e "  ${YELLOW}$(t xray.socks.plaintext_warning)${NC}\n"

    local count; count=$(_socks_load | jq 'length')
    local tag port username password listen_addr

    ask tag  "$(t xray.ask.node_tag)"   "socks-$((count+1))"
    ask port "$(t xray.ask.local_port)" "$((SOCKS_DEFAULT_PORT + count))"
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    # ── 监听范围：默认仅本机 ──────────────────────────────────────────────
    echo ""
    echo -e "  $(t xray.socks.listen_opt_local)"
    echo -e "  $(t xray.socks.listen_opt_public)"
    local lc; read -rp "$(echo -e "${CYAN}$(t xray.socks.ask_listen_mode)${NC}")" lc
    if [[ "${lc:-1}" == "2" ]]; then
        listen_addr="0.0.0.0"
        # 公网监听强制认证。认证只挡住随手扫描——凭据同样是明文，挡不住嗅探。
        log_warn "$(t xray.socks.public_warning)"
        ask_yn "$(t xray.socks.confirm_public)" N || { log_info "$(t common.cancelled)"; return 1; }
        ask username "$(t xray.socks.ask_user)" "psm"
        [[ -z "$username" ]] && username="psm"
        ask password "$(t xray.ask.password_auto)" ""
        [[ -z "$password" ]] && password=$(rand_str 20)
    else
        listen_addr="127.0.0.1"
        username=""; password=""
        if ask_yn "$(t xray.socks.ask_local_auth)" N; then
            ask username "$(t xray.socks.ask_user)" "psm"
            [[ -z "$username" ]] && username="psm"
            ask password "$(t xray.ask.password_auto)" ""
            [[ -z "$password" ]] && password=$(rand_str 20)
        fi
    fi

    local node
    node=$(jq -n \
        --arg tag "$tag" --argjson port "$port" \
        --arg username "$username" --arg password "$password" \
        --arg listen_addr "$listen_addr" \
        '{tag:$tag, port:$port, public_port:$port, username:$username,
          password:$password, listen_addr:$listen_addr, udp:true}')
    _socks_upsert "$node"
    _socks_apply_all

    echo ""
    log_ok "$(t xray.socks.added "$tag" "$listen_addr" "$port")"

    if [[ "$listen_addr" != "127.0.0.1" ]]; then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    socks_show_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
socks_delete_node() {
    _socks_show_node_list
    local tag; ask tag "$(t xray.ask.delete_node_tag)"
    local node; node=$(_socks_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    ask_yn "$(t xray.ask.delete_node "$tag")" N || return 0
    _socks_delete "$tag"
    _socks_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t xray.deleted)"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
socks_modify_auth() {
    _socks_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_socks_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local listen; listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')

    local username password
    if [[ "$listen" != "127.0.0.1" ]]; then
        # 公网节点不允许退回免认证
        log_info "$(t xray.socks.public_auth_required)"
        ask username "$(t xray.socks.ask_user)" "$(echo "$node" | jq -r '.username // "psm"')"
        [[ -z "$username" ]] && username="psm"
        ask password "$(t xray.ask.password_auto)" ""
        [[ -z "$password" ]] && password=$(rand_str 20)
    elif ask_yn "$(t xray.socks.ask_local_auth)" N; then
        ask username "$(t xray.socks.ask_user)" "psm"
        [[ -z "$username" ]] && username="psm"
        ask password "$(t xray.ask.password_auto)" ""
        [[ -z "$password" ]] && password=$(rand_str 20)
    else
        username=""; password=""
    fi

    node=$(echo "$node" | jq --arg u "$username" --arg p "$password" '.username=$u | .password=$p')
    _socks_upsert "$node"
    _socks_apply_all
    log_ok "$(t xray.socks.auth_updated "$tag")"
    echo ""
    socks_show_share "$tag"
}

socks_modify_port() {
    _socks_show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_socks_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local old_port; old_port=$(echo "$node" | jq -r '.port')
    local listen;   listen=$(echo "$node"   | jq -r '.listen_addr // "127.0.0.1"')
    ask port "$(t xray.ask.new_port)" "$old_port"
    [[ "$port" == "$old_port" ]] && { log_info "$(t xray.port_unchanged)"; return 0; }
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t xray.invalid_port_short)"; return 1
    fi
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    node=$(echo "$node" | jq --argjson p "$port" '.port = $p | .public_port = $p')
    _socks_upsert "$node"
    _socks_apply_all
    log_ok "$(t xray.port_updated "$tag" "$old_port" "$port")"

    if [[ "$listen" != "127.0.0.1" ]]; then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
        log_info "$(t xray.old_port_note "$old_port")"
    fi
}

# ── Share / connection info ───────────────────────────────────────────────────
# 仅本机的节点没有「分享」可言——它的地址就是 127.0.0.1，别的机器连不上。
# 这种情况下只打印连接信息，不生成二维码。
socks_show_share() {
    local tag="$1"
    [[ -z "$tag" ]] && { _socks_show_node_list; ask tag "$(t xray.ask.node_tag)"; }
    local node; node=$(_socks_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

    local port user pass listen host
    port=$(echo "$node"   | jq -r '.port')
    user=$(echo "$node"   | jq -r '.username // ""')
    pass=$(echo "$node"   | jq -r '.password // ""')
    listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')

    echo -e "\n${BOLD}${GREEN}$(t xray.socks.share_title)${NC}"
    if [[ "$listen" == "127.0.0.1" ]]; then
        host="127.0.0.1"
        echo -e "  ${YELLOW}$(t xray.socks.local_only_hint)${NC}"
    else
        host=$(get_ipv4)
    fi
    printf "  %-12s %s\n" "$(t xray.socks.label_server):" "$host"
    printf "  %-12s %s\n" "$(t xray.socks.label_port):"   "$port"
    if [[ -n "$user" ]]; then
        printf "  %-12s %s\n" "$(t xray.socks.label_user):" "$user"
        printf "  %-12s %s\n" "$(t xray.socks.label_pass):" "$pass"
    else
        printf "  %-12s %s\n" "$(t xray.socks.header_auth):" "noauth"
    fi

    # 仅本机节点不生成 URI / 二维码：换台机器扫了也连不上，只会造成误解
    [[ "$listen" == "127.0.0.1" ]] && return 0

    local uri
    if [[ -n "$user" ]]; then
        uri="socks://$(printf '%s:%s' "$user" "$pass" | openssl base64 -A)@${host}:${port}#PSM-${tag}"
    else
        uri="socks://${host}:${port}#PSM-${tag}"
    fi
    echo ""
    echo -e "${BOLD}$(t xray.socks.link_label):${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Dependency check ──────────────────────────────────────────────────────────
_socks_check_deps() {
    ensure_pkg_deps jq qrencode
    if ! [[ -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
        ask_yn "$(t xray.ask_install_xray)" Y \
            && xray_install \
            || { log_error "$(t xray.socks.need_xray)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
socks_menu() {
    _socks_check_deps || return
    while true; do
        show_menu "$(t xray.socks.menu.title)" \
            "$(t xray.socks.menu.add)" \
            "$(t xray.socks.menu.delete)" \
            "$(t xray.socks.menu.auth)" \
            "$(t xray.socks.menu.port)" \
            "$(t xray.socks.menu.share)" \
            "$(t xray.socks.menu.list)"

        case "$MENU_CHOICE" in
            1) socks_add_node ;;
            2) socks_delete_node ;;
            3) socks_modify_auth ;;
            4) socks_modify_port ;;
            5) socks_show_share "" ;;
            6) _socks_show_node_list ;;
            0) return ;;
        esac
        press_enter
    done
}
