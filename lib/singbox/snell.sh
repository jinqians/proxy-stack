#!/usr/bin/env bash
# singbox/snell.sh — Snell inbound via sing-box (需 sing-box 1.14.0+)
#
# 与独立的 lib/snell.sh（官方 snell-server 二进制）不同：这里用 sing-box 内核提供
# Snell 入站，好处是能和 sing-box 的路由分流、其它协议共用一个内核与配置。
# Snell 无标准分享 URI，导出 Surge / Clash Meta 配置。终端输出走 i18n（t sb.snell.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_SNELL_CFG="$SB_STORE_DIR/snell.json"
SB_SNELL_DEFAULT_PORT=6160

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_snell_load() { [[ -f "$SB_SNELL_CFG" ]] && jq '.' "$SB_SNELL_CFG" 2>/dev/null || echo '[]'; }
_sb_snell_save() { mkdir -p "$(dirname "$SB_SNELL_CFG")"; printf '%s' "$1" | jq '.' > "$SB_SNELL_CFG"; }

_sb_snell_list()      { _sb_snell_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.version)\t\(.listen // "::")"' 2>/dev/null; }
_sb_snell_count()     { _sb_snell_load | jq 'length' 2>/dev/null; }
_sb_snell_get_by_tag(){ _sb_snell_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_snell_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_sb_snell_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_snell_save "$nodes"
}
_sb_snell_delete() {
    local nodes; nodes=$(_sb_snell_load)
    _sb_snell_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_sb_snell_select_node() {
    SB_SNELL_SEL_TAG=""
    local count; count=$(_sb_snell_count)
    (( count == 0 )) && { log_warn "$(t sb.snell.none)"; return 1; }
    local tags_arr=() i=0 tag port ver _
    while IFS=$'\t' read -r tag port ver _; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.snell.col_port) %-6s v%s\n" "$i" "$tag" "$port" "$ver"
    done < <(_sb_snell_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.snell.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_SNELL_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build sing-box snell inbound ──────────────────────────────────────────────
# v5：可选 http 混淆（入站只有 obfs_mode）；v6：整形模式（mode）。psk 即预共享密钥。
_sb_snell_build_inbound() {
    local node_json="$1"
    local tag;  tag=$(echo "$node_json"  | jq -r '.tag')
    local port; port=$(echo "$node_json" | jq -r '.port')
    local ver;  ver=$(echo "$node_json"  | jq -r '.version')
    local psk;  psk=$(echo "$node_json"  | jq -r '.psk')
    local listen; listen=$(echo "$node_json" | jq -r '.listen // "::"')
    local om;   om=$(echo "$node_json"   | jq -r '.obfs_mode // ""')

    jq -n \
        --arg tag "$tag" --arg listen "$listen" --argjson p "$port" \
        --argjson ver "$ver" --arg psk "$psk" --arg om "$om" \
    '{
        type: "snell",
        tag: $tag,
        listen: $listen,
        listen_port: $p,
        version: $ver,
        psk: $psk
    }
    + (if $ver == 6 then { mode: "default" } else {} end)
    # v5 入站只接受 obfs_mode：上游 SnellObfsServerOptions 没有 obfs_host，
    # 它属于 outbound 的 SnellObfsClientOptions。多写会让 sing-box 报
    # `unknown field "obfs_host"` 直接拒绝整份配置。obfs_host 仍存在节点存储里，
    # 只在 _sb_snell_share 导出 Surge / Clash 客户端配置时使用。
    + (if ($ver == 5 and $om == "http") then { obfs_mode: "http" } else {} end)'
}

# ── Apply all Snell nodes into sing-box config ────────────────────────────────
_sb_snell_apply() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_snell_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-snell-")) or (.type == "snell")))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        sb_add_inbound "$(_sb_snell_build_inbound "$node")"
    done
    sb_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_sb_snell_apply_or_revert() {
    _sb_snell_apply && return 0
    _sb_snell_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Share (Surge / Clash Meta — Snell 无标准 URI) ─────────────────────────────
_sb_snell_share() {
    local tag="$1"
    local node; node=$(_sb_snell_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.snell.not_found "$tag")"; return 1; }

    local port ver psk om oh
    port=$(echo "$node" | jq -r '.port')
    ver=$(echo "$node"  | jq -r '.version')
    psk=$(echo "$node"  | jq -r '.psk')
    om=$(echo "$node"   | jq -r '.obfs_mode // ""')
    oh=$(echo "$node"   | jq -r '.obfs_host // ""')
    local ip; ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}── sing-box Snell: ${tag} ──${NC}"
    printf "  %-12s %s\n" "$(t sb.snell.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t sb.snell.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t sb.snell.label_psk):"    "$psk"
    printf "  %-12s v%s\n" "$(t sb.snell.label_ver):"   "$ver"
    echo ""

    local surge="PSM-${tag} = snell, ${ip}, ${port}, psk=${psk}, version=${ver}"
    [[ "$om" == "http" ]] && surge="${surge}, obfs=http, obfs-host=${oh:-bing.com}"
    echo -e "${BOLD}$(t sb.snell.surge_label):${NC}"
    echo "  $surge"
    echo ""
    echo -e "${BOLD}$(t sb.snell.clash_label):${NC}"
    echo "proxies:"
    echo "  - name: PSM-${tag}"
    echo "    type: snell"
    echo "    server: ${ip}"
    echo "    port: ${port}"
    echo "    psk: ${psk}"
    echo "    version: ${ver}"
    if [[ "$om" == "http" ]]; then
        echo "    obfs-opts:"
        echo "      mode: http"
        echo "      host: ${oh:-bing.com}"
    fi
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_snell_add_node() {
    _sb_require_installed || return
    # 版本门禁：Snell 入站需 sing-box 1.14.0+，不满足则在填任何参数前拦截。
    # 1.14 尚未转正，稳定通道永远达不到门槛，所以这里指向安装菜单的预览通道，
    # 免得用户以为是脚本坏了。
    _sb_require_version "1.14.0" "sb.snell.feature" || {
        log_info "$(t sb.snell.need_preview)"
        return 1
    }
    echo -e "\n${BOLD}$(t sb.snell.add_title)${NC}"
    log_info "$(t sb.snell.version_hint)"

    local tag port version psk listen
    ask tag  "$(t sb.snell.ask_tag)"  "sb-snell-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-snell- ]] || tag="sb-snell-${tag}"
    ask port "$(t sb.snell.ask_port)" "$SB_SNELL_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.snell.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.snell.cancelled)"; return 1; }

    echo "  $(t sb.snell.ver_title)"
    echo "    1. v6  $(t sb.snell.ver6_hint)"
    echo "    2. v5  $(t sb.snell.ver5_hint)"
    local vs; read -rp "$(echo -e "${CYAN}$(t sb.snell.ask_ver)${NC}")" vs
    case "${vs:-1}" in 2) version=5 ;; *) version=6 ;; esac

    psk=$(rand_str 24)
    ask psk "$(t sb.snell.ask_psk)" "$psk"
    ask listen "$(t sb.snell.ask_listen)" "::"

    local obfs_mode="" obfs_host=""
    if [[ "$version" == "5" ]] && ask_yn "$(t sb.snell.ask_obfs)" N; then
        obfs_mode="http"; ask obfs_host "$(t sb.snell.ask_obfs_host)" "bing.com"
    fi

    local node_json
    node_json=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --argjson ver "$version" \
        --arg psk "$psk" --arg listen "$listen" \
        --arg om "$obfs_mode" --arg oh "$obfs_host" \
        '{tag:$tag, port:$port, version:$ver, psk:$psk, listen:$listen, obfs_mode:$om, obfs_host:$oh}')

    local _prev_store; _prev_store=$(_sb_snell_load)
    _sb_snell_upsert "$node_json"
    _sb_snell_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.snell.added "$tag" "$port" "$version")"

    ask_yn "$(t sb.snell.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "both"
    }
    _sb_snell_share "$tag"
}

# ── Modify PSK ────────────────────────────────────────────────────────────────
sb_snell_modify_psk() {
    echo -e "\n${BOLD}$(t sb.snell.modify_psk_title)${NC}"
    _sb_snell_select_node || return
    local tag="$SB_SNELL_SEL_TAG"
    local node; node=$(_sb_snell_get_by_tag "$tag")
    local psk; ask psk "$(t sb.snell.ask_new_psk)" ""
    [[ -z "$psk" ]] && psk=$(rand_str 24)
    node=$(echo "$node" | jq --arg v "$psk" '.psk = $v')
    local _prev_store; _prev_store=$(_sb_snell_load)
    _sb_snell_upsert "$node"
    _sb_snell_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.snell.psk_updated "$tag")"
    _sb_snell_share "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_snell_delete_node() {
    echo -e "\n${BOLD}$(t sb.snell.del_title)${NC}"
    _sb_snell_select_node || return
    local tag="$SB_SNELL_SEL_TAG"
    ask_yn "$(t sb.snell.ask_confirm_del "$tag")" N || return
    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_sb_snell_load)
    _sb_snell_delete "$tag"
    _sb_snell_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.snell.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_sb_snell_show_node_list() {
    local count; count=$(_sb_snell_count)
    echo -e "\n${BOLD}sing-box Snell:${NC}"
    if (( count == 0 )); then echo "  $(t sb.snell.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port ver _; do
        printf "  TCP %s | $(t sb.snell.col_port): %-6s | v%s | tag: %s\n" "$ip" "$port" "$ver" "$tag"
    done < <(_sb_snell_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_snell_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.snell.menu_title)" \
            "$(t sb.snell.menu.add)" \
            "$(t sb.snell.menu.view)" \
            "$(t sb.snell.menu.psk)" \
            "$(t sb.snell.menu.del)" \
            "$(t sb.snell.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_snell_add_node;  press_enter ;;
            2) _sb_snell_select_node && _sb_snell_share "$SB_SNELL_SEL_TAG"; press_enter ;;
            3) sb_snell_modify_psk; press_enter ;;
            4) sb_snell_delete_node; press_enter ;;
            5) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
