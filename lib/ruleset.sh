#!/usr/bin/env bash
# ruleset.sh — 订阅式规则集分流：交互菜单（sing-box / mihomo）。
#
# 三个核心都支持，但代价不同：mihomo / sing-box 刷新不重启，Xray 因为规则是内联进
# config.json 的，内容变化时必须重启一次。
#
# 定位很重要，UI 上也要说清楚：这里的规则是用来**选出口**的（哪些域名走家宽 /
# 走 WARP / 走中转），不是用来决定「走不走代理」的。后者属于客户端的活——流量
# 已经跨洋到这台机器上了才判断直连，钱和延迟早花完了。所以这里只该贴
# OpenAI.list 这种几百条的专题表，而不是 ChinaMax 那种几万条的全量分流表。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ruleset/apply.sh"

# ── 概览 ─────────────────────────────────────────────────────────────────────
rs_status_panel() {
    local core="$1"
    echo -e "\n${BOLD}${BLUE}$(t rs.status.title "$(rs_core_label "$core")")${NC}"
    echo -e "  ${YELLOW}$(t rs.status.purpose)${NC}"

    if rs_timer_active; then
        echo -e "  $(t rs.status.timer_on)"
    else
        echo -e "  ${YELLOW}$(t rs.status.timer_off)${NC}"
    fi

    local sets n
    sets=$(rs_sets_load)
    n=$(jq 'length' <<<"$sets")
    if (( n == 0 )); then
        echo -e "  $(t rs.list.empty)"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
        return 0
    fi

    printf "  %-14s %-6s %-18s %s\n" "NAME" "RULES" "TARGET" "UPDATED"
    local i name total target updated
    for (( i = 0; i < n; i++ )); do
        name=$(jq -r --argjson i "$i" '.[$i].name' <<<"$sets")
        total=$(jq -r --argjson i "$i" '.[$i].total' <<<"$sets")
        updated=$(jq -r --argjson i "$i" '.[$i].updated_at // "" | .[0:10]' <<<"$sets")
        target=$(rs_target_of "$core" "$name") || target=""
        [[ -n "$target" ]] || target="-"
        printf "  %-14s %-6s %-18s %s\n" "$name" "$total" "$target" "$updated"
    done
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

# ── 选出口 ───────────────────────────────────────────────────────────────────
# 列出该核心当前可用的出站，外加直连/拒绝。规则集的价值全在「绑到哪个出口」上，
# 所以这一步必须让用户看见现有出站，而不是让人凭记忆敲 tag。
_rs_pick_target() {
    local core="$1"
    local -a opts=()
    case "$core" in
        xray)
            source "$LIB_DIR/xray/outbound.sh"
            while IFS= read -r tag; do [[ -n "$tag" ]] && opts+=("$tag"); done \
                < <(_outb_load | jq -r '.[].tag')
            opts+=("direct" "blocked")
            ;;
        singbox)
            source "$LIB_DIR/singbox/routing.sh"
            while IFS= read -r tag; do [[ -n "$tag" ]] && opts+=("$tag"); done \
                < <(_sb_outb_load | jq -r '.[].tag')
            opts+=("direct" "reject")
            ;;
        mihomo)
            source "$LIB_DIR/mihomo/routing.sh"
            while IFS= read -r nm; do [[ -n "$nm" ]] && opts+=("$nm"); done \
                < <(_mh_route_outbounds | jq -r '.[].name')
            opts+=("DIRECT" "REJECT")
            ;;
    esac

    {
        echo ""
        echo -e "  ${BOLD}$(t rs.target.title)${NC}"
        local i
        for (( i = 0; i < ${#opts[@]}; i++ )); do
            printf "  %3d) %s\n" "$(( i + 1 ))" "${opts[$i]}"
        done
    } >&2

    local sel; ask sel "$(t rs.target.prompt)" "1" >&2
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )) || { echo "" ; return 1; }
    printf '%s' "${opts[$(( sel - 1 ))]}"
}

# ── 添加 ─────────────────────────────────────────────────────────────────────
_rs_pick_preset() {
    {
        echo ""
        echo -e "  ${BOLD}$(t rs.preset.title)${NC}"
        local i entry
        for (( i = 0; i < ${#RS_PRESETS[@]}; i++ )); do
            entry="${RS_PRESETS[$i]}"
            printf "  %3d) %-10s %s\n" "$(( i + 1 ))" "${entry%%|*}" "${entry#*|}"
        done
        echo -e "  ${YELLOW}$(t rs.preset.hint)${NC}"
    } >&2
    local sel; ask sel "$(t rs.preset.prompt)" "1" >&2
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#RS_PRESETS[@]} )) || return 1
    printf '%s' "${RS_PRESETS[$(( sel - 1 ))]}"
}

# 把一个【已存在】的规则集重新绑定到指定出口。WARP / VPNGate 的配置流程会用它，
# 让用户从已订阅的表里挑一个，而不是每次都重新贴 URL。
rs_bind_existing() {
    local core="$1" target="$2"
    local names; names=$(rs_set_names)
    [[ -n "$names" ]] || { log_warn "$(t rs.bind_existing.none)"; return 1; }

    local arr=() i=0 n
    echo -e "\n  ${BOLD}$(t rs.bind_existing.title)${NC}"
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        i=$((i+1)); arr+=("$n")
        printf "  ${CYAN}%2d.${NC} %s\n" "$i" "$n"
    done <<< "$names"

    local sel; ask sel "$(t rs.bind_existing.prompt)" "1"
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) \
        || { log_error "$(t rs.ask.bad_index)"; return 1; }
    local name="${arr[$((sel-1))]}"
    local url; url=$(rs_set_get "$name" | jq -r '.url // ""')
    rs_bind_core "$core" "$name" "$target" "$url" || return 1
    log_ok "$(t rs.bind_existing.done "$name" "$target")"
}

# rs_add <core> [from_preset] [preset_target]
# preset_target 非空时跳过「选出口」那一步，直接绑到调用方指定的出口。给
# WARP / VPNGate 的配置流程用——那里出口是已知的，再问一遍纯属多余且容易选错。
rs_add() {
    local core="$1" from_preset="${2:-0}" preset_target="${3:-}"
    local name="" url=""

    if (( from_preset )); then
        local entry; entry=$(_rs_pick_preset) || { log_error "$(t rs.ask.bad_index)"; return 1; }
        name="${entry%%|*}"; url="${entry#*|}"
    else
        ask url "$(t rs.ask.url)" ""
        [[ -n "$url" ]] || return 1
        local suggest; suggest=$(basename "${url%%\?*}"); suggest="${suggest%.list}"
        suggest=$(echo "$suggest" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
        suggest="${suggest%%-}"
        ask name "$(t rs.ask.name)" "${suggest:-custom}"
    fi

    if ! rs_valid_name "$name"; then
        log_error "$(t rs.ask.bad_name)"
        return 1
    fi

    log_step "$(t rs.fetch.fetching "$url")"
    rs_stage "$url" || return 1
    if ! ask_yn "$(t rs.ask.confirm)" Y; then
        rs_stage_cleanup
        return 1
    fi

    local target
    if [[ -n "$preset_target" ]]; then
        target="$preset_target"
    else
        target=$(_rs_pick_target "$core")
    fi
    [[ -n "$target" ]] || { log_error "$(t rs.ask.bad_index)"; rs_stage_cleanup; return 1; }

    rs_commit "$name" "$url"
    rs_stage_cleanup
    rs_bind_core "$core" "$name" "$target" "$url" || return 1

    # 订阅规则表的全部意义就在于它会自己跟上游走，所以默认把每日更新打开。
    # mihomo 的 provider 由内核自己刷新，但 sing-box 的本地规则集文件和 Xray 的
    # 内联规则都得靠这个定时任务重写，不开等于订了个永远不变的表。
    if ! rs_timer_active; then
        rs_timer_enable
        log_info "$(t rs.update.auto_on)"
    fi
    echo -e "  ${YELLOW}$(t rs.add.reminder)${NC}"
}

# ── 删除 ─────────────────────────────────────────────────────────────────────
rs_remove() {
    local core="$1"
    local names; names=$(rs_set_names)
    [[ -n "$names" ]] || { log_warn "$(t rs.list.empty)"; return 1; }

    local -a arr=()
    while IFS= read -r n; do [[ -n "$n" ]] && arr+=("$n"); done <<<"$names"
    echo ""
    local i
    for (( i = 0; i < ${#arr[@]}; i++ )); do printf "  %3d) %s\n" "$(( i + 1 ))" "${arr[$i]}"; done
    local sel; ask sel "$(t rs.ask.pick_set)" "1"
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) \
        || { log_error "$(t rs.ask.bad_index)"; return 1; }
    local name="${arr[$(( sel - 1 ))]}"

    ask_yn "$(t rs.ask.remove "$name")" N || return 0
    rs_unbind_core "$core" "$name" || true
    # 只有没有任何核心还绑着它时才删本地副本
    local still=0 c
    for c in xray singbox mihomo; do
        [[ "$c" == "$core" ]] && continue
        [[ -n "$(rs_target_of "$c" "$name" 2>/dev/null || true)" ]] && still=1
    done
    if (( still )); then
        log_ok "$(t rs.remove.unbound "$name" "$(rs_core_label "$core")")"
    else
        rs_set_delete "$name"
        log_ok "$(t rs.remove.done "$name")"
    fi
}

# ── 菜单 ─────────────────────────────────────────────────────────────────────
# ruleset_menu <singbox|mihomo>
ruleset_menu() {
    local core="${1:-singbox}"
    _rs_init
    while true; do
        rs_status_panel "$core"
        show_menu "$(t rs.menu.title "$(rs_core_label "$core")")" \
            "$(t rs.menu.add_preset)" \
            "$(t rs.menu.add_custom)" \
            "$(t rs.menu.update)" \
            "$(t rs.menu.timer)" \
            "$(t rs.menu.remove)"

        case "$MENU_CHOICE" in
            1) rs_add "$core" 1;  press_enter ;;
            2) rs_add "$core" 0;  press_enter ;;
            3) rs_refresh_all;    press_enter ;;
            4)
                if rs_timer_active; then rs_timer_disable; else rs_timer_enable; fi
                press_enter ;;
            5) rs_remove "$core"; press_enter ;;
            0) return ;;
        esac
    done
}
