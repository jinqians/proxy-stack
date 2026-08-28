#!/usr/bin/env bash
# singbox/socks.sh — SOCKS5 inbound via sing-box
#
# 节点存储（config/singbox/socks.json）是唯一事实源，apply 时整体重建 socks 入站。
#
# ⚠ SOCKS5 不加密也不伪装：凭据与流量全是明文。默认只监听 127.0.0.1，供本机程序、
# Docker 容器或代理链使用。选择公网监听时强制用户名密码，但那同样是明文传输的，
# 认证只挡随手扫描、挡不住嗅探。要对外暴露请用 Reality / Trojan / VMess。
#
# 没有 TLS 就没有 SNI，因此 SOCKS5 无法挂到 Nginx 443 SNI 分流上。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_SOCKS_CFG="$SB_STORE_DIR/socks.json"
SB_SOCKS_DEFAULT_PORT=1080

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_socks_load() { [[ -f "$SB_SOCKS_CFG" ]] && jq '.' "$SB_SOCKS_CFG" 2>/dev/null || echo '[]'; }
_sb_socks_save() { mkdir -p "$(dirname "$SB_SOCKS_CFG")"; printf '%s' "$1" | jq '.' > "$SB_SOCKS_CFG"; }

_sb_socks_list()      { _sb_socks_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "127.0.0.1")\t\(if (.username // "") == "" then "noauth" else "password" end)"' 2>/dev/null; }
_sb_socks_count()     { _sb_socks_load | jq 'length' 2>/dev/null; }
_sb_socks_get_by_tag(){ _sb_socks_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_socks_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_sb_socks_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_socks_save "$nodes"
}

_sb_socks_delete() {
    local nodes; nodes=$(_sb_socks_load)
    _sb_socks_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_sb_socks_select_node() {
    SB_SOCKS_SEL_TAG=""
    local count; count=$(_sb_socks_count)
    (( count == 0 )) && { log_warn "$(t sb.socks.none)"; return 1; }
    local tags_arr=() i=0 tag port laddr auth
    while IFS=$'\t' read -r tag port laddr auth; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.socks.col_port) %-6s %-15s %s\n" "$i" "$tag" "$port" "$laddr" "$auth"
    done < <(_sb_socks_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.socks.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_SOCKS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build sing-box socks inbound ───────────────────────────────────────────────
# sing-box 的 socks 入站：users 为空数组即免认证；有条目则强制用户名密码。
# 不能写成 users: null —— sing-box 会报类型错误而拒绝整份配置。
_sb_socks_build_inbound() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local user; user=$(echo "$node_json" | jq -r '.username // ""')
    local pass; pass=$(echo "$node_json" | jq -r '.password // ""')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "127.0.0.1"')

    local users_json="[]"
    [[ -n "$user" ]] && users_json=$(jq -nc --arg u "$user" --arg p "$pass" \
        '[{username:$u, password:$p}]')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg listen "$listen_addr" \
        --argjson users "$users_json" \
    '{
        type: "socks",
        tag: $tag,
        listen: $listen,
        listen_port: $p,
        users: $users
    }'
}

# ── Apply all SOCKS5 nodes ────────────────────────────────────────────────────
_sb_socks_apply() {
    _sb_cfg_backup   # 事务化：先备份，校验失败时回滚
    local nodes; nodes=$(_sb_socks_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-socks-")) or (.type == "socks")))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        sb_add_inbound "$(_sb_socks_build_inbound "$node")"
    done
    sb_test_restart
}

_sb_socks_apply_or_revert() {
    _sb_socks_apply && return 0
    _sb_socks_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Connection info ───────────────────────────────────────────────────────────
# 仅本机的节点没有「分享」可言：地址就是 127.0.0.1，别的机器连不上，
# 所以不生成 URI / 二维码，只打印连接信息。
_sb_socks_uri() {
    local tag="$1"
    local node; node=$(_sb_socks_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.socks.not_found "$tag")"; return 1; }

    local port user pass listen host
    port=$(echo "$node"   | jq -r '.port')
    user=$(echo "$node"   | jq -r '.username // ""')
    pass=$(echo "$node"   | jq -r '.password // ""')
    listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')

    echo -e "\n${BOLD}${GREEN}── sing-box SOCKS5: ${tag} ──${NC}"
    if [[ "$listen" == "127.0.0.1" ]]; then
        host="127.0.0.1"
        echo -e "  ${YELLOW}$(t sb.socks.local_only_hint)${NC}"
    else
        host=$(get_ipv4)
    fi
    printf "  %-12s %s\n" "$(t sb.socks.label_server):" "$host"
    printf "  %-12s %s\n" "$(t sb.socks.label_port):"   "$port"
    if [[ -n "$user" ]]; then
        printf "  %-12s %s\n" "$(t sb.socks.label_user):" "$user"
        printf "  %-12s %s\n" "$(t sb.socks.label_pass):" "$pass"
    else
        printf "  %-12s %s\n" "$(t sb.socks.header_auth):" "noauth"
    fi

    [[ "$listen" == "127.0.0.1" ]] && return 0

    local uri
    if [[ -n "$user" ]]; then
        uri="socks://$(printf '%s:%s' "$user" "$pass" | openssl base64 -A)@${host}:${port}#PSM-${tag}"
    else
        uri="socks://${host}:${port}#PSM-${tag}"
    fi
    echo ""
    echo -e "${BOLD}$(t sb.socks.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_socks_add_node() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.socks.add_title)${NC}"
    echo -e "  ${YELLOW}$(t sb.socks.plaintext_warning)${NC}\n"

    local tag port username password listen_addr
    ask tag  "$(t sb.socks.ask_tag)"  "sb-socks-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-socks- ]] || tag="sb-socks-${tag}"

    ask port "$(t sb.socks.ask_port)" "$SB_SOCKS_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.socks.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.socks.cancelled)"; return 1; }

    echo ""
    echo -e "  $(t sb.socks.listen_opt_local)"
    echo -e "  $(t sb.socks.listen_opt_public)"
    local lc; read -rp "$(echo -e "${CYAN}$(t sb.socks.ask_listen_mode)${NC}")" lc
    if [[ "${lc:-1}" == "2" ]]; then
        listen_addr="::"
        log_warn "$(t sb.socks.public_warning)"
        ask_yn "$(t sb.socks.confirm_public)" N || { log_info "$(t sb.socks.cancelled)"; return 1; }
        ask username "$(t sb.socks.ask_user)" "psm"
        [[ -z "$username" ]] && username="psm"
        ask password "$(t sb.socks.ask_pass)" ""
        [[ -z "$password" ]] && password=$(rand_str 20)
    else
        listen_addr="127.0.0.1"
        username=""; password=""
        if ask_yn "$(t sb.socks.ask_local_auth)" N; then
            ask username "$(t sb.socks.ask_user)" "psm"
            [[ -z "$username" ]] && username="psm"
            ask password "$(t sb.socks.ask_pass)" ""
            [[ -z "$password" ]] && password=$(rand_str 20)
        fi
    fi

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" \
        --arg username "$username" --arg password "$password" \
        --arg listen_addr "$listen_addr" \
        '{tag:$tag, port:$port, public_port:$port, username:$username,
          password:$password, listen_addr:$listen_addr, udp:true}')

    local _prev_store; _prev_store=$(_sb_socks_load)
    _sb_socks_upsert "$node_json"
    _sb_socks_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.socks.added "$tag" "$port")"

    if [[ "$listen_addr" != "127.0.0.1" ]]; then
        ask_yn "$(t sb.socks.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi
    _sb_socks_uri "$tag"
}

# ── Modify auth ───────────────────────────────────────────────────────────────
sb_socks_modify_auth() {
    echo -e "\n${BOLD}$(t sb.socks.modify_auth_title)${NC}"
    _sb_socks_select_node || return
    local tag="$SB_SOCKS_SEL_TAG"
    local node; node=$(_sb_socks_get_by_tag "$tag")
    local listen; listen=$(echo "$node" | jq -r '.listen_addr // "127.0.0.1"')

    local username password
    if [[ "$listen" != "127.0.0.1" ]]; then
        log_info "$(t sb.socks.public_auth_required)"
        ask username "$(t sb.socks.ask_user)" "$(echo "$node" | jq -r '.username // "psm"')"
        [[ -z "$username" ]] && username="psm"
        ask password "$(t sb.socks.ask_pass)" ""
        [[ -z "$password" ]] && password=$(rand_str 20)
    elif ask_yn "$(t sb.socks.ask_local_auth)" N; then
        ask username "$(t sb.socks.ask_user)" "psm"
        [[ -z "$username" ]] && username="psm"
        ask password "$(t sb.socks.ask_pass)" ""
        [[ -z "$password" ]] && password=$(rand_str 20)
    else
        username=""; password=""
    fi

    node=$(echo "$node" | jq --arg u "$username" --arg p "$password" '.username=$u | .password=$p')
    local _prev_store; _prev_store=$(_sb_socks_load)
    _sb_socks_upsert "$node"
    _sb_socks_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.socks.auth_updated "$tag")"
    _sb_socks_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_socks_delete_node() {
    echo -e "\n${BOLD}$(t sb.socks.del_title)${NC}"
    _sb_socks_select_node || return
    local tag="$SB_SOCKS_SEL_TAG"
    ask_yn "$(t sb.socks.ask_confirm_del "$tag")" N || return
    local _prev_store; _prev_store=$(_sb_socks_load)
    _sb_socks_delete "$tag"
    _sb_socks_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.socks.deleted "$tag")"
}

# manager.sh 的「查看所有节点」调用
_sb_socks_show_node_list() {
    local count; count=$(_sb_socks_count)
    echo -e "\n${BOLD}sing-box SOCKS5:${NC}"
    if (( count == 0 )); then echo "  $(t sb.socks.none)"; return; fi
    while IFS=$'\t' read -r tag port laddr auth; do
        printf "  TCP %-15s | $(t sb.socks.col_port): %-6s | %s | tag: %s\n" "$laddr" "$port" "$auth" "$tag"
    done < <(_sb_socks_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_socks_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.socks.menu_title)" \
            "$(t sb.socks.menu.add)" \
            "$(t sb.socks.menu.view)" \
            "$(t sb.socks.menu.auth)" \
            "$(t sb.socks.menu.del)" \
            "$(t sb.socks.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_socks_add_node;  press_enter ;;
            2) _sb_socks_select_node && _sb_socks_uri "$SB_SOCKS_SEL_TAG"; press_enter ;;
            3) sb_socks_modify_auth; press_enter ;;
            4) sb_socks_delete_node; press_enter ;;
            5) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
