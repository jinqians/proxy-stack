#!/usr/bin/env bash
# xray/ss2022.sh — Shadowsocks 2022 via Xray inbound

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

XSS_CFG="$CFG_DIR/xray/ss2022.json"
XSS_DEFAULT_PORT=8388

# ── State helpers ─────────────────────────────────────────────────────────────
_xss_load() {
    [[ -f "$XSS_CFG" ]] && jq '.' "$XSS_CFG" 2>/dev/null || echo '[]'
}

_xss_save() {
    local dir; dir=$(dirname "$XSS_CFG")
    mkdir -p "$dir"
    printf '%s' "$1" | jq '.' > "$XSS_CFG"
}

_xss_list() {
    _xss_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.method)\t\(.listen // "0.0.0.0")"' 2>/dev/null
}

_xss_count() { _xss_load | jq 'length' 2>/dev/null; }

_xss_get_by_tag() {
    _xss_load | jq ".[] | select(.tag == \"$1\")" 2>/dev/null
}

_xss_upsert() {
    local node_json="$1"
    local tag; tag=$(echo "$node_json" | jq -r '.tag')
    local nodes; nodes=$(_xss_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$tag\")) | . += [$node_json]")
    _xss_save "$nodes"
}

_xss_delete() {
    local nodes; nodes=$(_xss_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$1\"))")
    _xss_save "$nodes"
}

# 节点存储是唯一事实源：手动编辑 config.json 后菜单显示旧值，且下一次
# _xss_apply_to_xray 会覆盖手动修改。查看/修改前把 config.json 的
# 端口/密码/加密方式同步回存储（入站与节点 1:1，按 tag 匹配）。
_xss_sync_from_live() {
    [[ -f "$XRAY_CFG" ]] || return 0
    local nodes; nodes=$(_xss_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag live upd
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node" | jq -r '.tag')
        live=$(jq -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) // empty' "$XRAY_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue
        upd=$(echo "$node" | jq --argjson l "$live" \
            '.port     = ($l.port // .port)
           | .method   = ($l.settings.method // .method)
           | .password = ($l.settings.password // .password)
           | .listen   = ($l.listen // .listen)')
        [[ "$upd" == "$node" ]] && continue
        changed=1
        nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$upd" \
            'map(if .tag == $t then $n else . end)')
    done
    if (( changed )); then
        _xss_save "$nodes"
        log_info "$(t xray.manual_sync_port_password)"
    fi
    return 0
}

# 交互式按序号选择节点；选中的 tag 写入 XSS_SEL_TAG，取消/无节点返回 1。
_xss_select_node() {
    XSS_SEL_TAG=""
    local count; count=$(_xss_count)
    (( count == 0 )) && { log_warn "$(t xray.no_ss2022_nodes)"; return 1; }
    local tags_arr=() i=0 tag port method _
    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s %s %-6s %s\n" "$i" "$tag" "$(t xray.port_label)" "$port" "$method"
    done < <(_xss_list)
    local sel
    read -rp "$(echo -e "${CYAN}$(t xray.select_index_cancel)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t xray.invalid_option)"; return 1; fi
    XSS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Password generation ───────────────────────────────────────────────────────
# SS2022 requires a random base64-encoded key:
#   2022-blake3-aes-128-gcm       → 16 bytes (24 chars base64 with padding)
#   2022-blake3-aes-256-gcm       → 32 bytes (44 chars base64 with padding)
#   2022-blake3-chacha20-poly1305 → 32 bytes (44 chars base64 with padding)
# Xray config uses standard base64 WITH '=' padding; URI encoding strips it.
_xss_gen_password() {
    local method="${1:-2022-blake3-aes-128-gcm}"
    local bytes=16
    case "$method" in
        *256*|*chacha20*) bytes=32 ;;
    esac
    openssl rand -base64 "$bytes" | tr -d '\n'
}

# ── Build Xray inbound JSON for one SS2022 node ───────────────────────────────
_xss_build_inbound() {
    local node_json="$1"
    local tag;    tag=$(echo "$node_json"    | jq -r '.tag')
    local port;   port=$(echo "$node_json"   | jq -r '.port')
    local method; method=$(echo "$node_json" | jq -r '.method')
    local pass;   pass=$(echo "$node_json"   | jq -r '.password')
    local listen; listen=$(echo "$node_json" | jq -r '.listen // "0.0.0.0"')

    jq -n \
        --arg tag    "$tag" \
        --argjson p  "$port" \
        --arg method "$method" \
        --arg pass   "$pass" \
        --arg listen "$listen" \
    '{
        "tag": $tag,
        "protocol": "shadowsocks",
        "listen": $listen,
        "port": $p,
        "settings": {
            "method": $method,
            "password": $pass,
            "network": "tcp,udp"
        },
        "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    }'
}

# ── Apply all SS2022 nodes into Xray config ───────────────────────────────────
_xss_apply_to_xray() {
    local nodes; nodes=$(_xss_load)
    local count; count=$(echo "$nodes" | jq 'length')
    (( count == 0 )) && return 0

    local tmp; tmp=$(mktemp)
    # Remove old SS2022 inbounds, then re-add from state
    jq 'del(.inbounds[] | select(.tag | startswith("xss-")))' "$XRAY_CFG" > "$tmp"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        local inbound; inbound=$(_xss_build_inbound "$node")
        tmp2=$(mktemp)
        jq --argjson ib "$inbound" '.inbounds += [$ib]' "$tmp" > "$tmp2"
        mv "$tmp2" "$tmp"
    done

    mv "$tmp" "$XRAY_CFG"
    xray_test_restart
}

# ── Share URI ─────────────────────────────────────────────────────────────────
# SIP002: ss://base64url(method:password)@host:port#name
_xss_uri() {
    local tag="$1"
    local node; node=$(_xss_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_missing "$tag")"; return 1; }

    local port method pass
    port=$(echo "$node"   | jq -r '.port')
    method=$(echo "$node" | jq -r '.method')
    pass=$(echo "$node"   | jq -r '.password')

    local ip; ip=$(get_ipv4)
    local userinfo; userinfo=$(printf '%s:%s' "$method" "$pass" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local uri="ss://${userinfo}@${ip}:${port}#${tag}"

    echo -e "\n${BOLD}${GREEN}$(t xray.ss2022.title "$tag")${NC}"
    printf "  %-12s %s\n" "$(t xray.server_label)"   "$ip"
    printf "  %-12s %s\n" "$(t xray.port_label):"     "$port"
    printf "  %-12s %s\n" "$(t xray.encrypt_label)"     "$method"
    printf "  %-12s %s\n" "$(t xray.password_label)"     "$pass"
    echo ""
    echo -e "${BOLD}$(t xray.ss_link_label)${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Interactive: add node ─────────────────────────────────────────────────────
xss_add_node() {
    _xray_require_installed || return
    _xss_sync_from_live

    echo -e "\n${BOLD}$(t xray.ss2022.add_title)${NC}"

    local tag port method listen
    ask tag    "$(t xray.ss2022.ask_tag)"        "xss-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    ask port   "$(t xray.ss2022.ask_listen_port)" "$XSS_DEFAULT_PORT"
    echo "  $(t xray.ss2022.cipher_title)"
    echo "    $(t xray.ss2022.cipher1)"
    echo "    $(t xray.ss2022.cipher2)"
    echo "    $(t xray.ss2022.cipher3)"
    local cipher_sel
    read -rp "$(echo -e "${CYAN}$(t docker.ask_select_1)${NC}")" cipher_sel
    case "${cipher_sel:-1}" in
        2) method="2022-blake3-aes-256-gcm" ;;
        3) method="2022-blake3-chacha20-poly1305" ;;
        *) method="2022-blake3-aes-128-gcm" ;;
    esac

    ask listen "$(t xray.ss2022.ask_listen_addr)" "0.0.0.0"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t xray.invalid_port_short)"; return 1
    fi
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
    if ! [[ "$tag" =~ ^xss- ]]; then
        tag="xss-${tag}"
    fi

    local pass; pass=$(_xss_gen_password "$method")

    local node_json
    node_json=$(jq -n \
        --arg tag    "$tag" \
        --argjson p  "$port" \
        --arg method "$method" \
        --arg pass   "$pass" \
        --arg listen "$listen" \
    '{tag: $tag, port: $p, method: $method, password: $pass, listen: $listen}')

    _xss_upsert "$node_json"
    _xss_apply_to_xray

    log_ok "$(t xray.ss2022.added "$tag" "$port" "$method")"

    # SS2022 直接监听自己的端口（不走 Nginx）。RHEL 系默认 firewalld 为
    # Enforcing 且只放行 SSH，不放行端口则节点从外部不可达——主动询问放行。
    ask_yn "$(t xray.ask.open_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "both"
    }

    _xss_uri "$tag"
}

# ── Interactive: modify port / password ──────────────────────────────────────
xss_modify_port() {
    _xss_sync_from_live
    echo -e "\n${BOLD}$(t xray.ss2022.modify_port_title)${NC}"
    _xss_select_node || return
    local tag="$XSS_SEL_TAG"
    local node; node=$(_xss_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_missing "$tag")"; return 1; }
    local old_port; old_port=$(echo "$node" | jq -r '.port')

    local port; ask port "$(t xray.ask.new_port)" "$old_port"
    [[ "$port" == "$old_port" ]] && { log_info "$(t xray.port_unchanged)"; return 0; }
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t xray.invalid_port_short)"; return 1
    fi
    _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }

    node=$(echo "$node" | jq --argjson p "$port" '.port = $p')
    _xss_upsert "$node"
    _xss_apply_to_xray
    log_ok "$(t xray.port_updated "$tag" "$old_port" "$port")"

    ask_yn "$(t xray.ask.open_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "both"
    }
    log_info "$(t xray.old_port_note "$old_port")"
    _xss_uri "$tag"
}

xss_modify_password() {
    _xss_sync_from_live
    echo -e "\n${BOLD}$(t xray.ss2022.modify_password_title)${NC}"
    _xss_select_node || return
    local tag="$XSS_SEL_TAG"
    local node; node=$(_xss_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_missing "$tag")"; return 1; }
    local method; method=$(echo "$node" | jq -r '.method')

    local pass; ask pass "$(t xray.ss2022.ask_new_password)" ""
    if [[ -z "$pass" ]]; then
        pass=$(_xss_gen_password "$method")
    else
        # SS2022 密码必须是与加密方式匹配长度的随机密钥的 base64 编码
        # （aes-128 → 16 字节，其余 → 32 字节），长度不符 Xray 会拒绝启动。
        local need=16
        case "$method" in *256*|*chacha20*) need=32 ;; esac
        local got; got=$(printf '%s' "$pass" | base64 -d 2>/dev/null | wc -c | tr -d ' ') || got=0
        if [[ "$got" != "$need" ]]; then
            log_error "$(t xray.ss2022.bad_password "$need" "${got:-0}")"
            return 1
        fi
    fi

    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    _xss_upsert "$node"
    _xss_apply_to_xray
    log_ok "$(t xray.ss2022.password_updated "$tag")"
    _xss_uri "$tag"
}

# ── Interactive: delete node ──────────────────────────────────────────────────
xss_delete_node() {
    local count; count=$(_xss_count)
    (( count == 0 )) && { log_warn "$(t xray.no_ss2022_nodes)"; return; }

    echo -e "\n${BOLD}$(t xray.ss2022.delete_title)${NC}"
    local tags_arr=()
    local i=0
    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s %s %-6s %s\n" "$i" "$tag" "$(t xray.port_label)" "$port" "$method"
    done < <(_xss_list)

    local sel
    read -rp "$(echo -e "${CYAN}$(t xray.select_index_cancel)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t xray.invalid_option)"; return; fi

    local tag="${tags_arr[$((sel-1))]}"
    ask_yn "$(t xray.ss2022.ask_delete "$tag")" N || return

    _xss_delete "$tag"
    _xss_apply_to_xray

    # Also clean up traffic monitoring if set
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && \
        _trf_cleanup_node "$tag" 2>/dev/null || true

    log_ok "$(t xray.ss2022.deleted "$tag")"
}

# ── List helper (called by _view_all_nodes in manager.sh) ────────────────────
_xss_show_node_list() {
    local count; count=$(_xss_count)
    echo -e "\n${BOLD}Xray SS2022：${NC}"
    if (( count == 0 )); then echo "  $(t common.not_configured)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port method _; do
        printf "$(t xray.ss2022.list_line)" \
            "$ip" "$port" "$method" "$tag"
    done < <(_xss_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
xss_menu() {
    _xray_require_installed || return
    while true; do
        # 每轮菜单前同步一次，避免任何走 _xss_apply_to_xray 的操作
        # 用过期的节点存储覆盖 config.json 中的手动修改。
        _xss_sync_from_live
        show_menu "$(t xray.ss2022.menu.title)" \
            "$(t xray.ss2022.menu.add)" \
            "$(t xray.ss2022.menu.view)" \
            "$(t xray.ss2022.menu.port)" \
            "$(t xray.ss2022.menu.password)" \
            "$(t xray.ss2022.menu.delete)" \
            "$(t xray.ss2022.menu.restart)"

        case "$MENU_CHOICE" in
            1) xss_add_node;  press_enter ;;
            2)
                _xss_select_node && _xss_uri "$XSS_SEL_TAG"
                press_enter ;;
            3) xss_modify_port; press_enter ;;
            4) xss_modify_password; press_enter ;;
            5) xss_delete_node; press_enter ;;
            6) xray_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
