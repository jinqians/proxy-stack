#!/usr/bin/env bash
# snell.sh — Snell listener via mihomo (需 mihomo 1.14.0+)
#
# 与独立的 lib/snell.sh（官方 snell-server 二进制）不同：这里用 mihomo 内核提供
# Snell 入站，好处是能和 mihomo 的路由分流、其它协议共用一个内核与配置。
# Snell 无标准分享 URI，导出 Surge / Clash Meta 配置。终端输出走 i18n（t mh.snell.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

MH_SNELL_CFG="$MH_STORE_DIR/snell.json"
MH_SNELL_DEFAULT_PORT=6160

# ── State helpers ─────────────────────────────────────────────────────────────
_mh_snell_load() { [[ -f "$MH_SNELL_CFG" ]] && jq '.' "$MH_SNELL_CFG" 2>/dev/null || echo '[]'; }
_mh_snell_save() { mkdir -p "$(dirname "$MH_SNELL_CFG")"; printf '%s' "$1" | jq '.' > "$MH_SNELL_CFG"; }

_mh_snell_list()      { _mh_snell_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.version)\t\(.listen // "::")"' 2>/dev/null; }
_mh_snell_count()     { _mh_snell_load | jq 'length' 2>/dev/null; }
_mh_snell_get_by_tag(){ _mh_snell_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_mh_snell_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_mh_snell_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _mh_snell_save "$nodes"
}
_mh_snell_delete() {
    local nodes; nodes=$(_mh_snell_load)
    _mh_snell_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_mh_snell_select_node() {
    MH_SNELL_SEL_TAG=""
    local count; count=$(_mh_snell_count)
    (( count == 0 )) && { log_warn "$(t mh.snell.none)"; return 1; }
    local tags_arr=() i=0 tag port ver _
    while IFS=$'\t' read -r tag port ver _; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t mh.snell.col_port) %-6s v%s\n" "$i" "$tag" "$port" "$ver"
    done < <(_mh_snell_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.snell.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t mh.invalid_option)"; return 1; fi
    MH_SNELL_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build mihomo snell listener ──────────────────────────────────────────────
# v4/v5：可选 http/tls 混淆。psk 即预共享密钥。
_mh_snell_build_listener() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local ver;  ver=$(echo "$node_json"  | jq -r '.version')
    local psk;  psk=$(echo "$node_json"  | jq -r '.psk')
    local listen; listen=$(echo "$node_json" | jq -r '.listen // "::"')
    local om;   om=$(echo "$node_json"   | jq -r '.obfs_mode // ""')
    local oh;   oh=$(echo "$node_json"   | jq -r '.obfs_host // ""')

    jq -n \
        --arg tag "$tag" --arg listen "$listen" --argjson p "$port" \
        --argjson ver "$ver" --arg psk "$psk" --arg om "$om" --arg oh "$oh" \
    '{
        name: $tag,
        type: "snell",
        port: $p,
        listen: $listen,
        version: $ver,
        psk: $psk,
        udp: true
    }
    + (if ($om == "http" or $om == "tls")
       then { "obfs-opts": { mode: $om, host: (if $oh == "" then "bing.com" else $oh end) } }
       else {} end)'
}

# ── Apply all Snell nodes into mihomo config ────────────────────────────────
_mh_snell_apply() {
    _mh_cfg_backup   # 事务化：先备份，mh_test_restart 校验失败时回滚
    local nodes; nodes=$(_mh_snell_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.listeners[] | select(((.name // "") | startswith("mh-snell-")) or (.type == "snell")))' \
        "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        mh_add_listener "$(_mh_snell_build_listener "$node")"
    done
    mh_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_mh_snell_apply_or_revert() {
    _mh_snell_apply && return 0
    _mh_snell_save "$1"
    log_error "$(t mh.change_reverted)"
    return 1
}

# ── Share (Surge / Clash Meta — Snell 无标准 URI) ─────────────────────────────
_mh_snell_share() {
    local tag="$1"
    local node; node=$(_mh_snell_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.snell.not_found "$tag")"; return 1; }

    local port ver psk om oh
    port=$(echo "$node" | jq -r '.port')
    ver=$(echo "$node"  | jq -r '.version')
    psk=$(echo "$node"  | jq -r '.psk')
    om=$(echo "$node"   | jq -r '.obfs_mode // ""')
    oh=$(echo "$node"   | jq -r '.obfs_host // ""')
    local ip; ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}── mihomo Snell: ${tag} ──${NC}"
    printf "  %-12s %s\n" "$(t mh.snell.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t mh.snell.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t mh.snell.label_psk):"    "$psk"
    printf "  %-12s v%s\n" "$(t mh.snell.label_ver):"   "$ver"
    echo ""

    local surge="PSM-${tag} = snell, ${ip}, ${port}, psk=${psk}, version=${ver}"
    [[ -n "$om" ]] && surge="${surge}, obfs=${om}, obfs-host=${oh:-bing.com}"
    echo -e "${BOLD}$(t mh.snell.surge_label):${NC}"
    echo "  $surge"
    echo ""
    echo -e "${BOLD}$(t mh.snell.clash_label):${NC}"
    echo "proxies:"
    echo "  - name: PSM-${tag}"
    echo "    type: snell"
    echo "    server: ${ip}"
    echo "    port: ${port}"
    echo "    psk: ${psk}"
    echo "    version: ${ver}"
    if [[ -n "$om" ]]; then
        echo "    obfs-opts:"
        echo "      mode: ${om}"
        echo "      host: ${oh:-bing.com}"
    fi
}

# ── Add node ──────────────────────────────────────────────────────────────────
mh_snell_add_node() {
    _mh_require_installed || return
    echo -e "\n${BOLD}$(t mh.snell.add_title)${NC}"
    log_info "$(t mh.snell.version_hint)"

    local tag port version psk listen
    ask tag  "$(t mh.snell.ask_tag)"  "mh-snell-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^mh-snell- ]] || tag="mh-snell-${tag}"
    ask port "$(t mh.snell.ask_port)" "$MH_SNELL_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t mh.snell.invalid_port)"; return 1
    fi
    _mh_check_port_conflict "$port" || { log_info "$(t mh.snell.cancelled)"; return 1; }

    echo "  $(t mh.snell.ver_title)"
    echo "    1. v4  $(t mh.snell.ver4_hint)"
    echo "    2. v5  $(t mh.snell.ver5_hint)"
    local vs; read -rp "$(echo -e "${CYAN}$(t mh.snell.ask_ver)${NC}")" vs
    case "${vs:-1}" in 2) version=5 ;; *) version=4 ;; esac

    psk=$(rand_str 24)
    ask psk "$(t mh.snell.ask_psk)" "$psk"
    ask listen "$(t mh.snell.ask_listen)" "0.0.0.0"

    local obfs_mode="" obfs_host=""
    if ask_yn "$(t mh.snell.ask_obfs)" N; then
        read -rp "$(echo -e "${CYAN}$(t mh.snell.ask_obfs_mode)${NC}")" obfs_mode
        case "${obfs_mode:-http}" in tls) obfs_mode="tls" ;; *) obfs_mode="http" ;; esac
        ask obfs_host "$(t mh.snell.ask_obfs_host)" "bing.com"
    fi

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --argjson ver "$version" \
        --arg psk "$psk" --arg listen "$listen" \
        --arg om "$obfs_mode" --arg oh "$obfs_host" \
        '{tag:$tag, port:$port, version:$ver, psk:$psk, listen:$listen, obfs_mode:$om, obfs_host:$oh}')

    local _prev_store; _prev_store=$(_mh_snell_load)
    _mh_snell_upsert "$node_json"
    _mh_snell_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.snell.added "$tag" "$port" "$version")"

    ask_yn "$(t mh.snell.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "both"
    }
    _mh_snell_share "$tag"
}

# ── Modify PSK ────────────────────────────────────────────────────────────────
mh_snell_modify_psk() {
    echo -e "\n${BOLD}$(t mh.snell.modify_psk_title)${NC}"
    _mh_snell_select_node || return
    local tag="$MH_SNELL_SEL_TAG"
    local node; node=$(_mh_snell_get_by_tag "$tag")
    local psk; ask psk "$(t mh.snell.ask_new_psk)" ""
    [[ -z "$psk" ]] && psk=$(rand_str 24)
    node=$(echo "$node" | jq --arg v "$psk" '.psk = $v')
    local _prev_store; _prev_store=$(_mh_snell_load)
    _mh_snell_upsert "$node"
    _mh_snell_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.snell.psk_updated "$tag")"
    _mh_snell_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
mh_snell_delete_node() {
    echo -e "\n${BOLD}$(t mh.snell.del_title)${NC}"
    _mh_snell_select_node || return
    local tag="$MH_SNELL_SEL_TAG"
    ask_yn "$(t mh.snell.ask_confirm_del "$tag")" N || return
    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_mh_snell_load)
    _mh_snell_delete "$tag"
    _mh_snell_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t mh.snell.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_mh_snell_show_node_list() {
    local count; count=$(_mh_snell_count)
    echo -e "\n${BOLD}mihomo Snell:${NC}"
    if (( count == 0 )); then echo "  $(t mh.snell.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port ver _; do
        printf "  TCP %s | $(t mh.snell.col_port): %-6s | v%s | tag: %s\n" "$ip" "$port" "$ver" "$tag"
    done < <(_mh_snell_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
mh_snell_menu() {
    _mh_require_installed || return
    while true; do
        show_menu "$(t mh.snell.menu_title)" \
            "$(t mh.snell.menu.add)" \
            "$(t mh.snell.menu.view)" \
            "$(t mh.snell.menu.psk)" \
            "$(t mh.snell.menu.del)" \
            "$(t mh.snell.menu.restart)"

        case "$MENU_CHOICE" in
            1) mh_snell_add_node;  press_enter ;;
            2) _mh_snell_select_node && _mh_snell_share "$MH_SNELL_SEL_TAG"; press_enter ;;
            3) mh_snell_modify_psk; press_enter ;;
            4) mh_snell_delete_node; press_enter ;;
            5) mh_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
