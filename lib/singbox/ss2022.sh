#!/usr/bin/env bash
# singbox/ss2022.sh — Shadowsocks 2022 via sing-box inbound
#
# 节点存储（config/singbox/ss2022.json）是唯一事实源，apply 时整体重建
# sing-box 的 shadowsocks 入站。所有终端输出走 i18n（t sb.ss.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_SS_CFG="$SB_STORE_DIR/ss2022.json"
SB_SS_DEFAULT_PORT=8388

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_ss_load() { [[ -f "$SB_SS_CFG" ]] && jq '.' "$SB_SS_CFG" 2>/dev/null || echo '[]'; }
_sb_ss_save() { mkdir -p "$(dirname "$SB_SS_CFG")"; printf '%s' "$1" | jq '.' > "$SB_SS_CFG"; }

_sb_ss_list()      { _sb_ss_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.method)\t\(.listen // "::")"' 2>/dev/null; }
_sb_ss_count()     { _sb_ss_load | jq 'length' 2>/dev/null; }
_sb_ss_get_by_tag(){ _sb_ss_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_ss_upsert() {
    local node_json="$1" tag; tag=$(echo "$node_json" | jq -r '.tag')
    local nodes; nodes=$(_sb_ss_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$node_json" \
        'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_ss_save "$nodes"
}

_sb_ss_delete() {
    local nodes; nodes=$(_sb_ss_load)
    nodes=$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')
    _sb_ss_save "$nodes"
}

# 手动编辑 config.json 后把端口/密码/加密同步回节点存储（入站与节点按 tag 一一对应）。
_sb_ss_sync_from_live() {
    [[ -f "$SB_CFG" ]] || return 0
    local nodes; nodes=$(_sb_ss_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag live upd
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node" | jq -r '.tag')
        live=$(jq -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) // empty' "$SB_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue
        upd=$(echo "$node" | jq --argjson l "$live" \
            '.port     = ($l.listen_port // .port)
           | .method   = ($l.method // .method)
           | .password = ($l.password // .password)
           | .listen   = ($l.listen // .listen)')
        [[ "$upd" == "$node" ]] && continue
        changed=1
        nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$upd" \
            'map(if .tag == $t then $n else . end)')
    done
    if (( changed )); then
        _sb_ss_save "$nodes"
        log_info "$(t sb.ss.synced)"
    fi
    return 0
}

# 交互式按序号选择节点；选中的 tag 写入 SB_SS_SEL_TAG，取消/无节点返回 1。
_sb_ss_select_node() {
    SB_SS_SEL_TAG=""
    local count; count=$(_sb_ss_count)
    (( count == 0 )) && { log_warn "$(t sb.ss.none)"; return 1; }
    local tags_arr=() i=0 tag port method _
    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.ss.col_port) %-6s %s\n" "$i" "$tag" "$port" "$method"
    done < <(_sb_ss_list)
    local sel
    read -rp "$(echo -e "${CYAN}$(t sb.ss.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_SS_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Password generation ───────────────────────────────────────────────────────
# SS2022 密码是与加密方式匹配长度的随机密钥的 base64（aes-128 → 16 字节，其余 → 32）。
_sb_ss_gen_password() {
    local method="${1:-2022-blake3-aes-128-gcm}"
    local bytes=16
    case "$method" in *256*|*chacha20*) bytes=32 ;; esac
    openssl rand -base64 "$bytes" | tr -d '\n'
}

# ── Build sing-box shadowsocks inbound ────────────────────────────────────────
_sb_ss_build_inbound() {
    local node_json="$1"
    local tag;    tag=$(echo "$node_json"    | jq -r '.tag')
    local port;   port=$(echo "$node_json"   | jq -r '.port')
    local method; method=$(echo "$node_json" | jq -r '.method')
    local pass;   pass=$(echo "$node_json"   | jq -r '.password')
    local listen; listen=$(echo "$node_json" | jq -r '.listen // "::"')

    jq -n \
        --arg tag "$tag" --argjson p "$port" \
        --arg method "$method" --arg pass "$pass" --arg listen "$listen" \
    '{
        type: "shadowsocks",
        tag: $tag,
        listen: $listen,
        listen_port: $p,
        method: $method,
        password: $pass
    }'
}

# ── Apply all SS2022 nodes into sing-box config ───────────────────────────────
_sb_ss_apply() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_ss_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-ss-")) or (.type == "shadowsocks")))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        local inbound; inbound=$(_sb_ss_build_inbound "$node")
        sb_add_inbound "$inbound"
    done

    sb_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_sb_ss_apply_or_revert() {
    _sb_ss_apply && return 0
    _sb_ss_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Share URI (SIP002) ────────────────────────────────────────────────────────
_sb_ss_uri() {
    local tag="$1"
    local node; node=$(_sb_ss_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.ss.not_found "$tag")"; return 1; }

    local port method pass
    port=$(echo "$node"   | jq -r '.port')
    method=$(echo "$node" | jq -r '.method')
    pass=$(echo "$node"   | jq -r '.password')

    local ip; ip=$(get_ipv4)
    local userinfo; userinfo=$(printf '%s:%s' "$method" "$pass" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local uri="ss://${userinfo}@${ip}:${port}#${tag}"

    echo -e "\n${BOLD}${GREEN}── sing-box SS2022: ${tag} ──${NC}"
    printf "  %-12s %s\n" "$(t sb.ss.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t sb.ss.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t sb.ss.label_method):" "$method"
    printf "  %-12s %s\n" "$(t sb.ss.label_pass):"   "$pass"
    echo ""
    echo -e "${BOLD}$(t sb.ss.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ── Interactive: add node ─────────────────────────────────────────────────────
sb_ss_add_node() {
    _sb_require_installed || return
    _sb_ss_sync_from_live

    echo -e "\n${BOLD}$(t sb.ss.add_title)${NC}"

    local tag port method listen
    ask tag  "$(t sb.ss.ask_tag)"  "sb-ss-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    ask port "$(t sb.ss.ask_port)" "$SB_SS_DEFAULT_PORT"
    echo "  $(t sb.ss.method_title)"
    echo "    1. 2022-blake3-aes-128-gcm  $(t sb.ss.method_128)"
    echo "    2. 2022-blake3-aes-256-gcm  $(t sb.ss.method_256)"
    echo "    3. 2022-blake3-chacha20-poly1305  $(t sb.ss.method_cc)"
    local cipher_sel
    read -rp "$(echo -e "${CYAN}$(t sb.ss.ask_select_default)${NC}")" cipher_sel
    case "${cipher_sel:-1}" in
        2) method="2022-blake3-aes-256-gcm" ;;
        3) method="2022-blake3-chacha20-poly1305" ;;
        *) method="2022-blake3-aes-128-gcm" ;;
    esac

    ask listen "$(t sb.ss.ask_listen)" "::"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.ss.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.ss.cancelled)"; return 1; }
    [[ "$tag" =~ ^sb-ss- ]] || tag="sb-ss-${tag}"

    local pass; pass=$(_sb_ss_gen_password "$method")

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson p "$port" \
        --arg method "$method" --arg pass "$pass" --arg listen "$listen" \
        '{tag: $tag, port: $p, method: $method, password: $pass, listen: $listen}')

    local _prev_store; _prev_store=$(_sb_ss_load)
    _sb_ss_upsert "$node_json"
    _sb_ss_apply_or_revert "$_prev_store" || return 1

    log_ok "$(t sb.ss.added "$tag" "$port" "$method")"

    ask_yn "$(t sb.ss.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "both"
    }

    _sb_ss_uri "$tag"
}

# ── Interactive: modify port / password ──────────────────────────────────────
sb_ss_modify_port() {
    _sb_ss_sync_from_live
    echo -e "\n${BOLD}$(t sb.ss.modify_port_title)${NC}"
    _sb_ss_select_node || return
    local tag="$SB_SS_SEL_TAG"
    local node; node=$(_sb_ss_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.ss.not_found "$tag")"; return 1; }
    local old_port; old_port=$(echo "$node" | jq -r '.port')

    local port; ask port "$(t sb.ss.ask_new_port)" "$old_port"
    [[ "$port" == "$old_port" ]] && { log_info "$(t sb.ss.port_unchanged)"; return 0; }
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.ss.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.ss.cancelled)"; return 1; }

    node=$(echo "$node" | jq --argjson p "$port" '.port = $p')
    local _prev_store; _prev_store=$(_sb_ss_load)
    _sb_ss_upsert "$node"
    _sb_ss_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.ss.port_updated "$tag" "$old_port" "$port")"

    ask_yn "$(t sb.ss.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "both"
    }
    log_info "$(t sb.ss.old_port_hint "$old_port")"
    _sb_ss_uri "$tag"
}

sb_ss_modify_password() {
    _sb_ss_sync_from_live
    echo -e "\n${BOLD}$(t sb.ss.modify_pass_title)${NC}"
    _sb_ss_select_node || return
    local tag="$SB_SS_SEL_TAG"
    local node; node=$(_sb_ss_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.ss.not_found "$tag")"; return 1; }
    local method; method=$(echo "$node" | jq -r '.method')

    local pass; ask pass "$(t sb.ss.ask_new_pass)" ""
    if [[ -z "$pass" ]]; then
        pass=$(_sb_ss_gen_password "$method")
    else
        local need=16
        case "$method" in *256*|*chacha20*) need=32 ;; esac
        local got; got=$(printf '%s' "$pass" | base64 -d 2>/dev/null | wc -c | tr -d ' ') || got=0
        if [[ "$got" != "$need" ]]; then
            log_error "$(t sb.ss.pass_len_err "$need" "${got:-0}")"
            return 1
        fi
    fi

    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    local _prev_store; _prev_store=$(_sb_ss_load)
    _sb_ss_upsert "$node"
    _sb_ss_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.ss.pass_updated "$tag")"
    _sb_ss_uri "$tag"
}

# ── Interactive: delete node ──────────────────────────────────────────────────
sb_ss_delete_node() {
    local count; count=$(_sb_ss_count)
    (( count == 0 )) && { log_warn "$(t sb.ss.none)"; return; }

    echo -e "\n${BOLD}$(t sb.ss.del_title)${NC}"
    _sb_ss_select_node || return
    local tag="$SB_SS_SEL_TAG"
    ask_yn "$(t sb.ss.ask_confirm_del "$tag")" N || return

    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_sb_ss_load)
    _sb_ss_delete "$tag"
    _sb_ss_apply_or_revert "$_prev_store" || return 1

    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && \
        _trf_cleanup_node "$tag" 2>/dev/null || true

    log_ok "$(t sb.ss.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_sb_ss_show_node_list() {
    local count; count=$(_sb_ss_count)
    echo -e "\n${BOLD}sing-box SS2022:${NC}"
    if (( count == 0 )); then echo "  $(t sb.ss.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port method _; do
        printf "  TCP+UDP %s | $(t sb.ss.col_port): %-6s | %-36s | tag: %s\n" \
            "$ip" "$port" "$method" "$tag"
    done < <(_sb_ss_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_ss_menu() {
    _sb_require_installed || return
    while true; do
        _sb_ss_sync_from_live
        show_menu "$(t sb.ss.menu_title)" \
            "$(t sb.ss.menu.add)" \
            "$(t sb.ss.menu.view)" \
            "$(t sb.ss.menu.port)" \
            "$(t sb.ss.menu.pass)" \
            "$(t sb.ss.menu.del)" \
            "$(t sb.ss.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_ss_add_node;  press_enter ;;
            2) _sb_ss_select_node && _sb_ss_uri "$SB_SS_SEL_TAG"; press_enter ;;
            3) sb_ss_modify_port; press_enter ;;
            4) sb_ss_modify_password; press_enter ;;
            5) sb_ss_delete_node; press_enter ;;
            6) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
