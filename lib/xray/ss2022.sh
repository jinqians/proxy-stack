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
    [[ -z "$node" ]] && { log_error "节点 ${tag} 不存在"; return 1; }

    local port method pass
    port=$(echo "$node"   | jq -r '.port')
    method=$(echo "$node" | jq -r '.method')
    pass=$(echo "$node"   | jq -r '.password')

    local ip; ip=$(get_ipv4)
    local userinfo; userinfo=$(printf '%s:%s' "$method" "$pass" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local uri="ss://${userinfo}@${ip}:${port}#${tag}"

    echo -e "\n${BOLD}${GREEN}── Xray SS2022 节点：${tag} ──${NC}"
    printf "  %-12s %s\n" "服务器:"   "$ip"
    printf "  %-12s %s\n" "端口:"     "$port"
    printf "  %-12s %s\n" "加密:"     "$method"
    printf "  %-12s %s\n" "密码:"     "$pass"
    echo ""
    echo -e "${BOLD}SS 链接：${NC}"
    echo "  $uri"
    echo ""
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Interactive: add node ─────────────────────────────────────────────────────
xss_add_node() {
    _xray_require_installed || return

    echo -e "\n${BOLD}添加 Xray SS2022 节点${NC}"

    local tag port method listen
    ask tag    "节点标签 (tag)"        "xss-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    ask port   "监听端口"               "$XSS_DEFAULT_PORT"
    echo "  加密方式："
    echo "    1. 2022-blake3-aes-128-gcm  (16字节密钥，推荐)"
    echo "    2. 2022-blake3-aes-256-gcm  (32字节密钥)"
    echo "    3. 2022-blake3-chacha20-poly1305 (32字节密钥)"
    local cipher_sel
    read -rp "$(echo -e "${CYAN}选择 [1]: ${NC}")" cipher_sel
    case "${cipher_sel:-1}" in
        2) method="2022-blake3-aes-256-gcm" ;;
        3) method="2022-blake3-chacha20-poly1305" ;;
        *) method="2022-blake3-aes-128-gcm" ;;
    esac

    ask listen "监听地址 (0.0.0.0=全部)" "0.0.0.0"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "无效端口"; return 1
    fi
    _xray_check_port_conflict "$port" || { log_info "已取消"; return 1; }
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

    log_ok "节点 ${tag} 已添加（端口 ${port}，${method}）"
    _xss_uri "$tag"
}

# ── Interactive: delete node ──────────────────────────────────────────────────
xss_delete_node() {
    local count; count=$(_xss_count)
    (( count == 0 )) && { log_warn "没有 SS2022 节点"; return; }

    echo -e "\n${BOLD}删除 Xray SS2022 节点${NC}"
    local tags_arr=()
    local i=0
    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s 端口 %-6s %s\n" "$i" "$tag" "$port" "$method"
    done < <(_xss_list)

    local sel
    read -rp "$(echo -e "${CYAN}选择序号（0=取消）: ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "无效选项"; return; fi

    local tag="${tags_arr[$((sel-1))]}"
    ask_yn "确认删除节点 ${tag}？" N || return

    _xss_delete "$tag"
    _xss_apply_to_xray

    # Also clean up traffic monitoring if set
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && \
        _trf_cleanup_node "$tag" 2>/dev/null || true

    log_ok "节点 ${tag} 已删除"
}

# ── List helper (called by _view_all_nodes in manager.sh) ────────────────────
_xss_show_node_list() {
    local count; count=$(_xss_count)
    echo -e "\n${BOLD}Xray SS2022：${NC}"
    if (( count == 0 )); then echo "  未配置"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port method _; do
        printf "  TCP+UDP %s | 端口: %-6s | 加密: %-36s | tag: %s\n" \
            "$ip" "$port" "$method" "$tag"
    done < <(_xss_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
xss_menu() {
    _xray_require_installed || return
    while true; do
        show_menu "Xray SS2022 管理" \
            "添加节点" \
            "查看节点 / SS 链接" \
            "删除节点" \
            "重启 Xray"

        case "$MENU_CHOICE" in
            1) xss_add_node;  press_enter ;;
            2)
                local count; count=$(_xss_count)
                if (( count == 0 )); then
                    log_warn "没有 SS2022 节点"; press_enter; continue; fi
                local tags_arr=() i=0
                while IFS=$'\t' read -r tag port method _; do
                    i=$((i+1)); tags_arr+=("$tag")
                    printf "  ${CYAN}%2d.${NC} %-20s 端口 %-6s %s\n" "$i" "$tag" "$port" "$method"
                done < <(_xss_list)
                local sel
                read -rp "$(echo -e "${CYAN}选择节点（0=取消）: ${NC}")" sel
                [[ -z "$sel" || "$sel" == "0" ]] && continue
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )); then
                    _xss_uri "${tags_arr[$((sel-1))]}"
                fi
                press_enter ;;
            3) xss_delete_node; press_enter ;;
            4) xray_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
