#!/usr/bin/env bash
# vpngate/bind.sh — 把家宽隧道接进 xray / sing-box / mihomo 的出站与分流。
#
# 三个核心的接法本质相同：一条「直连出站 + 打 fwmark」的出站，标记由
# tunnel.sh 写下的 ip rule 引到家宽隧道的独立路由表。这样做的好处是出站配置
# 与具体节点无关——换家宽 IP 只重拨隧道，核心配置一个字都不用改，服务也不用重启。
#
# 为什么是 fwmark 而不是绑定网卡：绑网卡走 SO_BINDTODEVICE，内核要求 CAP_NET_RAW，
# 而三个核心的 systemd 单元 CapabilityBoundingSet 都只给了 CAP_NET_ADMIN +
# CAP_NET_BIND_SERVICE；SO_MARK 恰好只要 CAP_NET_ADMIN，现成可用。
#
# 出站一律锁 IPv4：VPNGate 隧道只承载 IPv4，隧道路由表里的 IPv6 只有黑洞路由。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tunnel.sh"

VG_XRAY_TAG="out-vpngate"
VG_SB_TAG="out-vpngate"
VG_MH_NAME="vpngate-out"
VG_PRESET_GEOSITE="netflix,disney,openai,tiktok"

vg_core_label() {
    case "$1" in
        xray)    echo "Xray" ;;
        singbox) echo "sing-box" ;;
        mihomo)  echo "mihomo" ;;
        *)       echo "$1" ;;
    esac
}

_vg_mark_bound() {
    local core="$1" val="$2" st
    st=$(vg_state_load)
    vg_state_save "$(echo "$st" | jq --arg c "$core" --argjson v "$val" \
        '.bound = ((.bound // {}) | .[$c] = $v)')"
}

vg_is_bound() { [[ "$(vg_state_get ".bound.\"$1\"")" == "true" ]]; }

# ── Xray ─────────────────────────────────────────────────────────────────────
_vg_bind_xray() {
    source "$LIB_DIR/xray/outbound.sh"
    source "$LIB_DIR/xray/routing.sh"
    _xray_require_installed || return 1

    local entry
    entry=$(jq -nc --arg tag "$VG_XRAY_TAG" --arg remark "$(t vg.bind.remark)" \
                   --arg dev "$VG_DEV" --argjson mark "$VG_MARK" \
        '{tag:$tag, remark:$remark, protocol:"vpngate", address:$dev, port:0, mark:$mark}')
    _outb_upsert "$entry"
    _outb_apply_to_xray || return 1
    xray_test_restart || return 1
    _vg_mark_bound xray true
    log_ok "$(t vg.bind.done "Xray" "$VG_XRAY_TAG")"
}

_vg_unbind_xray() {
    source "$LIB_DIR/xray/outbound.sh"
    source "$LIB_DIR/xray/routing.sh"
    [[ -f "$XRAY_CFG" ]] || { _vg_mark_bound xray false; return 0; }

    _route_save "$(_route_load | jq --arg ot "$VG_XRAY_TAG" '[.[] | select(.outbound_tag != $ot)]')"
    _route_apply_to_xray || true
    _outb_delete "$VG_XRAY_TAG"
    _outb_apply_to_xray || true
    xray_test_restart || true
    _vg_mark_bound xray false
}

_vg_rules_xray() {
    source "$LIB_DIR/xray/routing.sh"
    local id; id=$(_route_next_id)
    local e
    e=$(jq -nc --arg id "$id" --arg remark "$(t vg.bind.rule_remark)" \
               --arg val "$VG_PRESET_GEOSITE" --arg ot "$VG_XRAY_TAG" \
        '{id:$id, remark:$remark, rule_type:"geosite", value:$val, outbound_tag:$ot}')
    _route_save "$(_route_load | jq ". += [$e]")"
    _route_apply_to_xray || return 1
    xray_test_restart || return 1
}

# ── sing-box ─────────────────────────────────────────────────────────────────
_vg_bind_singbox() {
    source "$LIB_DIR/singbox/routing.sh"
    _sb_require_installed || return 1

    local entry
    entry=$(jq -nc --arg tag "$VG_SB_TAG" --arg remark "$(t vg.bind.remark)" \
                   --arg dev "$VG_DEV" --argjson mark "$VG_MARK" \
        '{tag:$tag, remark:$remark, protocol:"vpngate", address:$dev, port:0, mark:$mark}')
    local prev; prev=$(_sb_outb_load)
    _sb_outb_upsert "$entry"
    if ! _sb_route_apply; then
        _sb_outb_save "$prev"
        log_error "$(t vg.bind.fail "sing-box")"
        return 1
    fi
    _vg_mark_bound singbox true
    log_ok "$(t vg.bind.done "sing-box" "$VG_SB_TAG")"
}

_vg_unbind_singbox() {
    source "$LIB_DIR/singbox/routing.sh"
    [[ -f "$SB_CFG" ]] || { _vg_mark_bound singbox false; return 0; }

    _sb_route_save "$(_sb_route_load | jq --arg t "$VG_SB_TAG" '[.[] | select(.target != $t)]')"
    _sb_outb_save "$(_sb_outb_load | jq --arg t "$VG_SB_TAG" '[.[] | select(.tag != $t)]')"
    _sb_route_apply || true
    _vg_mark_bound singbox false
}

_vg_rules_singbox() {
    source "$LIB_DIR/singbox/routing.sh"
    local id; id=$(_sb_route_next_id)
    local e
    e=$(jq -nc --arg id "$id" --arg remark "$(t vg.bind.rule_remark)" \
               --arg val "$VG_PRESET_GEOSITE" --arg tgt "$VG_SB_TAG" \
        '{id:$id, remark:$remark, rule_type:"geosite", value:$val, target:$tgt}')
    _sb_route_save "$(_sb_route_load | jq ". += [$e]")"
    _sb_route_apply || return 1
}

# ── mihomo ───────────────────────────────────────────────────────────────────
_vg_bind_mihomo() {
    source "$LIB_DIR/mihomo/routing.sh"
    _mh_require_installed || return 1

    local entry
    entry=$(jq -nc --arg name "$VG_MH_NAME" --arg remark "$(t vg.bind.remark)" \
                   --arg dev "$VG_DEV" --argjson mark "$VG_MARK" \
        '{name:$name, remark:$remark, type:"vpngate", server:$dev, port:0, mark:$mark}')
    local prev; prev=$(_mh_route_load)
    _mh_outb_upsert "$entry"
    if ! _mh_route_apply; then
        _mh_route_save "$prev"
        log_error "$(t vg.bind.fail "mihomo")"
        return 1
    fi
    _vg_mark_bound mihomo true
    log_ok "$(t vg.bind.done "mihomo" "$VG_MH_NAME")"
}

_vg_unbind_mihomo() {
    source "$LIB_DIR/mihomo/routing.sh"
    [[ -f "$MH_CFG" ]] || { _vg_mark_bound mihomo false; return 0; }

    local st; st=$(_mh_route_load)
    _mh_route_save "$(echo "$st" | jq --arg n "$VG_MH_NAME" \
        '.rules = ((.rules // []) | [.[] | select(.target != $n)])
         | .outbounds = ((.outbounds // []) | [.[] | select(.name != $n)])')"
    _mh_route_apply || true
    _vg_mark_bound mihomo false
}

_vg_rules_mihomo() {
    source "$LIB_DIR/mihomo/routing.sh"
    # mihomo 的 GEOSITE 规则一条只吃一个类别，按预设逐条写入。
    local site
    for site in ${VG_PRESET_GEOSITE//,/ }; do
        local id; id=$(_mh_route_next_id)
        _mh_rule_add "$(jq -nc --arg id "$id" --arg v "$site" --arg t "$VG_MH_NAME" \
            '{id:$id, kind:"geosite", value:$v, target:$t}')"
    done
    _mh_route_apply || return 1
}

# ── 对外统一入口 ──────────────────────────────────────────────────────────────
vg_bind_core() {
    case "$1" in
        xray)    _vg_bind_xray ;;
        singbox) _vg_bind_singbox ;;
        mihomo)  _vg_bind_mihomo ;;
        *) log_error "$(t vg.bind.unknown_core "$1")"; return 1 ;;
    esac
}

vg_unbind_core() {
    case "$1" in
        xray)    _vg_unbind_xray ;;
        singbox) _vg_unbind_singbox ;;
        mihomo)  _vg_unbind_mihomo ;;
        *) log_error "$(t vg.bind.unknown_core "$1")"; return 1 ;;
    esac
}

vg_add_preset_rules() {
    case "$1" in
        xray)    _vg_rules_xray ;;
        singbox) _vg_rules_singbox ;;
        mihomo)  _vg_rules_mihomo ;;
        *) log_error "$(t vg.bind.unknown_core "$1")"; return 1 ;;
    esac
}

# 当前核心指向家宽出口的分流规则条数。
vg_rule_count() {
    case "$1" in
        xray)
            source "$LIB_DIR/xray/routing.sh"
            _route_load | jq --arg ot "$VG_XRAY_TAG" '[.[] | select(.outbound_tag == $ot)] | length' ;;
        singbox)
            source "$LIB_DIR/singbox/routing.sh"
            _sb_route_load | jq --arg t "$VG_SB_TAG" '[.[] | select(.target == $t)] | length' ;;
        mihomo)
            source "$LIB_DIR/mihomo/routing.sh"
            _mh_route_load | jq --arg n "$VG_MH_NAME" '[(.rules // [])[] | select(.target == $n)] | length' ;;
        *) echo 0 ;;
    esac
}
