#!/usr/bin/env bash
# exit_routing.sh — 「哪些流量走这个出口」的统一选择器
#
# 背景：WARP 和 VPNGate 过去都是配置完就自动推一组写死的 geosite 规则
# （WARP 是 netflix/openai/disney/hbo/spotify，VPNGate 是 netflix/disney/openai/tiktok）。
# 那套预设只覆盖流媒体和 AI，而出口的用途远不止这些；更要紧的是它不给选择，
# 用户想按自己的规则走就得配完再回头去别处改。
#
# 现在改成配置出口时显式询问，四条路径：
#   1) 内置预设      —— 原来的那组 geosite，保留为一个选项而不是默认行为
#   2) 订阅式规则集  —— 复用 lib/ruleset（可挑已有的，也可新贴一个 URL）
#   3) 手写路由规则  —— 进各内核的路由分流菜单，出口已预选
#   4) 全部流量      —— 改内核的兜底（Xray catch-all 规则 / sing-box route.final /
#                        mihomo MATCH），带明确警告
#   0) 暂不配置      —— 出站已建好，规则以后自己加
#
# 调用方只需给出「内核 + 出口标识 + 该出口的预设 geosite 列表 + 展示名」。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── 内置预设：写成 geosite 规则 ───────────────────────────────────────────────
_er_apply_preset() {
    local core="$1" target="$2" presets="$3"
    case "$core" in
        xray)
            source "$LIB_DIR/xray/routing.sh"
            local id; id=$(_route_next_id)
            local e; e=$(jq -nc --arg id "$id" --arg remark "$(t er.remark.preset)" \
                                --arg val "$presets" --arg ot "$target" \
                '{id:$id, remark:$remark, rule_type:"geosite", value:$val, outbound_tag:$ot}')
            _route_save "$(_route_load | jq ". += [$e]")"
            _route_apply_to_xray || return 1
            xray_test_restart || return 1
            ;;
        singbox)
            source "$LIB_DIR/singbox/routing.sh"
            local id; id=$(_sb_route_next_id)
            local e; e=$(jq -nc --arg id "$id" --arg remark "$(t er.remark.preset)" \
                                --arg val "$presets" --arg tgt "$target" \
                '{id:$id, remark:$remark, rule_type:"geosite", value:$val, target:$tgt}')
            _sb_route_save "$(_sb_route_load | jq ". += [$e]")"
            _sb_route_apply || return 1
            ;;
        mihomo)
            source "$LIB_DIR/mihomo/routing.sh"
            # mihomo 的 GEOSITE 规则一条只吃一个类别，按预设逐条写入
            local site
            for site in ${presets//,/ }; do
                local id; id=$(_mh_route_next_id)
                _mh_rule_add "$(jq -nc --arg id "$id" --arg v "$site" --arg t "$target" \
                    '{id:$id, kind:"geosite", value:$v, target:$t}')" || return 1
            done
            ;;
        *) log_error "$(t er.unsupported_core "$core")"; return 1 ;;
    esac
    log_ok "$(t er.done.preset "$presets" "$target")"
}

# ── 全部流量走该出口 ─────────────────────────────────────────────────────────
# 三个内核的实现完全不同：Xray 没有 catch-all 关键字，靠一条只声明 network 的
# field 规则；sing-box 是 route.final；mihomo 是最后那条 MATCH。
_er_apply_all() {
    local core="$1" target="$2" label="$3"

    log_warn "$(t er.all.warning "$label")"
    echo -e "  ${YELLOW}$(t er.all.warning_detail)${NC}"
    ask_yn "$(t er.all.confirm)" N || { log_info "$(t common.cancelled)"; return 1; }

    case "$core" in
        xray)
            source "$LIB_DIR/xray/routing.sh"
            local id; id=$(_route_next_id)
            local e; e=$(jq -nc --arg id "$id" --arg remark "$(t er.remark.all)" \
                                --arg ot "$target" \
                '{id:$id, remark:$remark, rule_type:"all", value:"", outbound_tag:$ot}')
            _route_save "$(_route_load | jq ". += [$e]")"
            _route_apply_to_xray || return 1
            xray_test_restart || return 1
            ;;
        singbox)
            # route.final 由 apply 时读环境变量决定，所以要持久化到状态里，
            # 否则下一次任何变更重建配置就把它冲回 direct 了。
            state_set sb_route_final "$target"
            source "$LIB_DIR/singbox/routing.sh"
            SB_ROUTE_FINAL="$target" _sb_route_apply || return 1
            ;;
        mihomo)
            state_set mh_route_final "$target"
            source "$LIB_DIR/mihomo/routing.sh"
            MH_ROUTE_FINAL="$target" _mh_route_apply || return 1
            ;;
        *) log_error "$(t er.unsupported_core "$core")"; return 1 ;;
    esac
    log_ok "$(t er.done.all "$target")"
}

# ── 手写路由规则：进对应内核的路由菜单 ───────────────────────────────────────
_er_manual() {
    local core="$1" target="$2"
    log_info "$(t er.manual.hint "$target")"
    case "$core" in
        xray)    source "$LIB_DIR/xray/routing.sh";    route_menu ;;
        singbox) source "$LIB_DIR/singbox/routing.sh"; sb_route_menu ;;
        mihomo)  source "$LIB_DIR/mihomo/routing.sh";  mh_route_menu ;;
        *) log_error "$(t er.unsupported_core "$core")"; return 1 ;;
    esac
}

# ── 订阅式规则集 ─────────────────────────────────────────────────────────────
_er_ruleset() {
    local core="$1" target="$2"
    source "$LIB_DIR/ruleset.sh"
    echo ""
    echo -e "  $(t er.rs.opt_existing)"
    echo -e "  $(t er.rs.opt_new)"
    local c; read -rp "$(echo -e "${CYAN}$(t er.rs.prompt)${NC}")" c
    case "${c:-1}" in
        2) rs_add "$core" 0 "$target" ;;
        *) rs_bind_existing "$core" "$target" \
               || { log_info "$(t er.rs.fallback_new)"; rs_add "$core" 0 "$target"; } ;;
    esac
}

# ── 入口 ─────────────────────────────────────────────────────────────────────
# exit_routing_choose <core> <target> <preset_geosite_csv> <label>
exit_routing_choose() {
    local core="$1" target="$2" presets="$3" label="${4:-$2}"

    echo ""
    echo -e "${BOLD}$(t er.title "$label")${NC}"
    echo -e "  $(t er.opt1 "$presets")"
    echo -e "  $(t er.opt2)"
    echo -e "  $(t er.opt3)"
    echo -e "  $(t er.opt4)"
    echo -e "  $(t er.opt0)"
    local c; read -rp "$(echo -e "${CYAN}$(t er.prompt)${NC}")" c
    case "${c:-1}" in
        1) _er_apply_preset "$core" "$target" "$presets" ;;
        2) _er_ruleset      "$core" "$target" ;;
        3) _er_manual       "$core" "$target" ;;
        4) _er_apply_all    "$core" "$target" "$label" ;;
        0) log_info "$(t er.skipped "$target")" ;;
        *) log_warn "$(t er.invalid)"; return 1 ;;
    esac
}
