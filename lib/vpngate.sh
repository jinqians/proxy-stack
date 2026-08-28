#!/usr/bin/env bash
# vpngate.sh — VPNGate 家宽出口：交互菜单（xray / sing-box / mihomo 共用）。
#
# 一句话：从 VPNGate 的公开名单里挑一个真正的家宽 IP，用 openvpn 拉一条只给
# 分流流量用的隧道，让 Netflix/ChatGPT 这类看 IP 归属的服务看到住宅宽带出口，
# 而不是机房 IP。机器本身的默认出网、SSH、既有节点全程不受影响。
#
# 三个核心共用同一条隧道：谁接入就在谁的配置里加一条打 fwmark 的出站，
# 隧道换节点时核心侧零改动。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/vpngate/bind.sh"

# ── 状态面板 ─────────────────────────────────────────────────────────────────
vg_status_panel() {
    local core="$1"
    echo -e "\n${BOLD}${BLUE}$(t vg.status.title)${NC}"

    # 名单 / 候选
    if [[ -s "$VG_CSV" ]]; then
        echo -e "  $(t vg.status.list "$(_vg_csv_rows)" "$(( $(_vg_csv_age) / 60 ))")"
    else
        echo -e "  ${YELLOW}$(t vg.status.list_none)${NC}"
    fi
    local total home
    total=$(vg_candidate_count)
    home=$(vg_candidates | jq '[.[] | select(.kind == "home")] | length')
    echo -e "  $(t vg.status.candidates "$total" "$home")"

    # 故障转移锚定的国家，以及同国家还剩多少个可切换的候选。
    local pool_cc pool_n
    pool_cc=$(_vg_pool_country)
    pool_n=$(_vg_pool_ips "" | grep -c . || true)
    if [[ -n "$pool_cc" ]]; then
        echo -e "  $(t vg.status.country "$pool_cc" "${pool_n:-0}")"
    else
        echo -e "  $(t vg.status.country_any "${pool_n:-0}")"
    fi

    # 隧道
    if ! vg_tun_installed; then
        echo -e "  ${YELLOW}$(t vg.status.tun_none)${NC}"
    elif vg_tun_active && vg_tun_dev_up; then
        local ip cc isp exit_ip
        ip=$(vg_state_get '.active.ip');            [[ -n "$ip" ]] || ip="?"
        cc=$(vg_state_get '.active.country')
        isp=$(vg_state_get '.active.isp')
        exit_ip=$(vg_state_get '.active.exit_ip')
        echo -e "  ${GREEN}$(t vg.status.tun_up "$ip" "${cc:-?}" "${isp:-?}")${NC}"
        echo -e "  ${GREEN}$(t vg.status.exit_ip "${exit_ip:-?}")${NC}"
    else
        echo -e "  ${RED}$(t vg.status.tun_down)${NC}"
    fi

    # 绑定 / 规则 / 看门狗
    if vg_is_bound "$core"; then
        echo -e "  ${GREEN}$(t vg.status.bound "$(vg_core_label "$core")" "$(vg_rule_count "$core")")${NC}"
    else
        echo -e "  ${YELLOW}$(t vg.status.unbound "$(vg_core_label "$core")")${NC}"
    fi
    if vg_watchdog_enabled; then
        echo -e "  $(t vg.status.wd_on)"
    else
        echo -e "  $(t vg.status.wd_off)"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

# ── 扫描 ─────────────────────────────────────────────────────────────────────
vg_do_scan() {
    local cc; cc=$(vg_pick_country) || return 1
    [[ -n "$cc" ]] || return 1
    local home_only=1
    ask_yn "$(t vg.ask.home_only)" Y || home_only=0
    vg_scan "$cc" "$home_only" || return 1
    echo -e "  ${YELLOW}$(t vg.rotate.same_country "$(_vg_country_label "$cc")")${NC}"
    vg_show_candidates 20
}

_vg_country_label() {
    [[ -z "$1" || "$1" == "ALL" ]] && { t vg.pick.all; return 0; }
    printf '%s' "$1"
}

# ── 一键接入 ─────────────────────────────────────────────────────────────────
_vg_report_exit() {
    local info; info=$(vg_tun_exit_info) || { log_error "$(t vg.exit.probe_fail)"; return 1; }
    local ip isp cc hosting
    ip=$(jq -r '.query // "?"' <<<"$info")
    isp=$(jq -r '.isp // "?"' <<<"$info")
    cc=$(jq -r '.countryCode // "?"' <<<"$info")
    hosting=$(jq -r '.hosting // "null"' <<<"$info")
    echo ""
    echo -e "  ${GREEN}$(t vg.exit.ok "$ip" "$cc" "$isp")${NC}"
    case "$hosting" in
        false) echo -e "  ${GREEN}$(t vg.exit.is_home)${NC}" ;;
        true)  echo -e "  ${YELLOW}$(t vg.exit.is_dc)${NC}" ;;
        *)     echo -e "  ${YELLOW}$(t vg.exit.unknown)${NC}" ;;
    esac
    return 0
}

vg_quick_setup() {
    local core="$1"
    _vg_ensure_openvpn || return 1

    # 国家由用户挑，不做“自动选一个”：出口国决定解锁的是哪个区，这是要用户点头
    # 的决定。已经扫过的话就先问要不要沿用，否则直接进国家选择器。
    local cur_cc; cur_cc=$(vg_state_get '.filter.country')
    if (( $(vg_candidate_count) > 0 )) && [[ -n "$cur_cc" ]]; then
        vg_show_candidates 10
        ask_yn "$(t vg.ask.keep_country "$(_vg_country_label "$cur_cc")")" Y \
            || { vg_do_scan || return 1; }
    else
        vg_do_scan || return 1
    fi

    echo ""
    log_step "$(t vg.setup.connecting)"
    vg_connect_best 3 || return 1
    _vg_report_exit || true

    echo ""
    vg_bind_core "$core" || return 1

    echo ""
    # 不再无条件推那组写死的 geosite 预设，改为显式询问「哪些流量走这个出口」。
    # 预设仍是选项之一，但和规则集 / 手写规则 / 全部流量并列，由用户选。
    source "$LIB_DIR/exit_routing.sh"
    exit_routing_choose "$core" "$(vg_target_of "$core")" \
        "$VG_PRESET_GEOSITE" "$(t vg.exit_label)"
    # 故障转移不做成可选项：家宽节点是志愿者自己的机器，关机、换 IP、拔网线都
    # 是常态，没有自动切换的话「解锁」随时会变成「不通」。装完直接开，用户不想
    # 要可以在菜单里关掉。
    if ! vg_watchdog_enabled; then
        vg_watchdog_enable
        log_info "$(t vg.setup.wd_auto)"
    fi
    log_ok "$(t vg.setup.done)"
}

vg_manual_connect() {
    local n; n=$(vg_candidate_count)
    (( n == 0 )) && { log_warn "$(t vg.cand.empty)"; return 1; }
    vg_show_candidates 30
    local sel; ask sel "$(t vg.ask.pick "$n")" "1"
    [[ "$sel" =~ ^[0-9]+$ ]] || { log_error "$(t vg.ask.bad_index)"; return 1; }
    (( sel >= 1 && sel <= n )) || { log_error "$(t vg.ask.bad_index)"; return 1; }
    local ip; ip=$(vg_candidates | jq -r --argjson i "$(( sel - 1 ))" '.[$i].ip')
    vg_tun_connect "$ip" || return 1
    _vg_report_exit || true
}

vg_do_rotate() {
    local cur; cur=$(vg_state_get '.active.ip')
    echo -e "  ${YELLOW}$(t vg.rotate.same_country "$(_vg_country_label "$(_vg_pool_country)")")${NC}"
    log_step "$(t vg.rotate.start "${cur:-?}")"
    vg_connect_best 3 "$cur" || return 1
    _vg_report_exit || true
}

vg_do_export() {
    local n; n=$(vg_candidate_count)
    (( n == 0 )) && { log_warn "$(t vg.cand.empty)"; return 1; }
    vg_show_candidates 30
    local sel; ask sel "$(t vg.ask.pick "$n")" "1"
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= n )) \
        || { log_error "$(t vg.ask.bad_index)"; return 1; }
    local ip; ip=$(vg_candidates | jq -r --argjson i "$(( sel - 1 ))" '.[$i].ip')
    vg_export_ovpn "$ip"
}

vg_do_remove() {
    local core="$1"
    ask_yn "$(t vg.ask.remove)" N || return 0
    vg_unbind_core "$core" || true

    # 隧道是三个核心共用的：还有别的核心挂在上面时只摘掉当前核心的出站与规则，
    # 隧道本身留着，否则会把另一个核心的解锁分流一起打断。
    local others=0 c
    for c in xray singbox mihomo; do
        [[ "$c" == "$core" ]] && continue
        vg_is_bound "$c" && others=1
    done
    if (( others )); then
        log_ok "$(t vg.removed "$(vg_core_label "$core")")"
        log_info "$(t vg.remove.tunnel_kept)"
        return 0
    fi

    vg_watchdog_enabled && vg_watchdog_disable
    vg_tun_remove
    log_ok "$(t vg.removed "$(vg_core_label "$core")")"
}

# ── 菜单 ─────────────────────────────────────────────────────────────────────
# vpngate_menu <xray|singbox|mihomo>
vpngate_menu() {
    local core="${1:-xray}"
    _vg_init
    while true; do
        vg_status_panel "$core"
        show_menu "$(t vg.menu.title "$(vg_core_label "$core")")" \
            "$(t vg.menu.quick)" \
            "$(t vg.menu.scan)" \
            "$(t vg.menu.list)" \
            "$(t vg.menu.pick)" \
            "$(t vg.menu.rotate)" \
            "$(t vg.menu.check)" \
            "$(t vg.menu.rules)" \
            "$(t vg.menu.watchdog)" \
            "$(t vg.menu.export)" \
            "$(t vg.menu.remove)"

        case "$MENU_CHOICE" in
            1)  vg_quick_setup "$core";     press_enter ;;
            2)  vg_do_scan;                 press_enter ;;
            3)  vg_show_candidates 30;      press_enter ;;
            4)  vg_manual_connect;          press_enter ;;
            5)  vg_do_rotate;               press_enter ;;
            6)  _vg_report_exit;            press_enter ;;
            7)
                if vg_is_bound "$core"; then
                    source "$LIB_DIR/exit_routing.sh"
                    exit_routing_choose "$core" "$(vg_target_of "$core")" \
                        "$VG_PRESET_GEOSITE" "$(t vg.exit_label)"
                else
                    log_warn "$(t vg.bind.first)"
                fi
                press_enter ;;
            8)
                if vg_watchdog_enabled; then vg_watchdog_disable; else vg_watchdog_enable; fi
                press_enter ;;
            9)  vg_do_export;               press_enter ;;
            10) vg_do_remove "$core";       press_enter ;;
            0)  return ;;
        esac
    done
}
