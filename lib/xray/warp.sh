#!/usr/bin/env bash
# xray/warp.sh — Cloudflare WARP outbound: register a free WARP identity and
# wire it up as an Xray outbound (tag "out-warp"), so selected domains
# (Netflix/OpenAI/Disney+/...) can be routed through it via routing.sh.
#
# Registration talks directly to Cloudflare's WARP client API (the same one
# the official app and tools like wgcf/warp-reg.sh use) — no wgcf/warp-cli
# binary required, just curl + jq + wg (wireguard-tools, for keypair gen).

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/outbound.sh"
source "$(dirname "${BASH_SOURCE[0]}")/routing.sh"

WARP_ACCOUNT="$CFG_DIR/xray/warp_account.json"
WARP_OUTBOUND_TAG="out-warp"
_WARP_API="https://api.cloudflareclient.com/v0a2158/reg"
_WARP_CLIENT_VERSION="a-7.21-0721"
WARP_FAMILY="4"   # egress family: 4 | 6 | 46 (set by _warp_choose_family)

# ── Dependencies ────────────────────────────────────────────────────────────
_warp_ensure_deps() {
    ensure_pkg_deps curl jq
    if ! command -v wg &>/dev/null; then
        log_step "正在安装 wireguard-tools（生成密钥对需要）..."
        detect_os
        if [[ "$PKG_MGR" == "yum" ]]; then
            yum install -y epel-release 2>/dev/null || true
        fi
        pkg_install wireguard-tools \
            && log_ok "wireguard-tools 已安装" \
            || { log_error "wireguard-tools 安装失败，无法生成密钥对"; return 1; }
    fi
    require_cmd wg curl jq
}

_warp_registered() {
    [[ -f "$WARP_ACCOUNT" ]] && [[ -n "$(jq -r '.secret_key // empty' "$WARP_ACCOUNT" 2>/dev/null)" ]]
}

# ── Registration ────────────────────────────────────────────────────────────
# Registers a brand-new free WARP identity and saves it to $WARP_ACCOUNT.
_warp_register() {
    _warp_ensure_deps || return 1

    log_step "正在生成 WireGuard 密钥对..."
    local priv pub
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)
    [[ -z "$priv" || -z "$pub" ]] && { log_error "密钥对生成失败"; return 1; }

    log_step "正在向 Cloudflare 注册 WARP 账号..."
    local tos body resp http_code
    tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    body=$(jq -n --arg key "$pub" --arg tos "$tos" \
        '{fcm_token:"", install_id:"", key:$key, locale:"en_US",
          model:"PC", tos:$tos, type:"Android"}')

    resp=$(curl -sL -w '\n%{http_code}' -X POST "$_WARP_API" \
        -H "CF-Client-Version: ${_WARP_CLIENT_VERSION}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: okhttp/3.12.1" \
        -d "$body" 2>/dev/null)
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [[ "$http_code" != "200" ]] || ! echo "$resp" | jq -e '.config' &>/dev/null; then
        log_error "WARP 注册失败（HTTP ${http_code}）："
        echo "$resp" | jq -r '.errors[]? // .' 2>/dev/null || echo "$resp"
        return 1
    fi

    local client_id v4 v6 peer_pk endpoint_host reserved
    client_id=$(echo "$resp" | jq -r '.config.client_id')
    v4=$(echo "$resp"        | jq -r '.config.interface.addresses.v4')
    v6=$(echo "$resp"        | jq -r '.config.interface.addresses.v6 // ""')
    peer_pk=$(echo "$resp"   | jq -r '.config.peers[0].public_key')
    endpoint_host=$(echo "$resp" | jq -r '.config.peers[0].endpoint.host')
    reserved=$(echo -n "$client_id" | base64 -d 2>/dev/null | od -An -tu1 \
        | tr -s ' ' '\n' | grep -v '^$' | jq -sc '.')

    if [[ -z "$peer_pk" || -z "$v4" || "$reserved" == "[]" ]]; then
        log_error "WARP 注册响应解析失败，字段缺失"
        return 1
    fi

    mkdir -p "$(dirname "$WARP_ACCOUNT")"
    jq -n \
        --arg secret "$priv" --arg pub "$pub" \
        --arg client_id "$client_id" --argjson reserved "$reserved" \
        --arg v4 "$v4" --arg v6 "$v6" \
        --arg peer_pk "$peer_pk" --arg endpoint "$endpoint_host" \
        --arg registered_at "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{secret_key:$secret, public_key:$pub, client_id:$client_id, reserved:$reserved,
          local_v4:$v4, local_v6:$v6, peer_public_key:$peer_pk, endpoint:$endpoint,
          registered_at:$registered_at}' > "$WARP_ACCOUNT"

    # NOTE: ${v4} here (e.g. 172.16.0.2) is the INTERNAL tunnel address Cloudflare
    # gives every free-WARP client — NOT the exit IP. The real egress IP is only
    # known once traffic flows; use "查看 WARP 实际出口 IP" to probe it.
    log_ok "WARP 账号注册成功（隧道内网地址: ${v4}，这不是出口 IP）"
}

# ── Egress address-family selection ──────────────────────────────────────────
_warp_family_label() {
    case "$1" in 4) echo "仅 IPv4";; 6) echo "仅 IPv6";; 46) echo "IPv4 + IPv6";; *) echo "$1";; esac
}

# Sets WARP_FAMILY to 4|6|46. WARP hands out both a v4 and v6 egress regardless
# of the box's own stack, so all three are usable everywhere — EXCEPT an
# IPv6-only box, where the entire reason to run WARP is to gain IPv4, so we pin
# v4 and don't prompt. Everyone else chooses (default = existing/IPv4).
_warp_choose_family() {
    local has4=0 has6=0
    ip -4 addr show scope global 2>/dev/null | grep -q 'inet '  && has4=1
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' && has6=1

    if (( has6 && ! has4 )); then
        WARP_FAMILY="4"
        log_info "本机为 IPv6-only，WARP 出口固定使用 IPv4（以获得访问 IPv4 服务的能力）"
        return
    fi

    local cur def=1
    cur=$(_outb_get_by_tag "$WARP_OUTBOUND_TAG" 2>/dev/null | jq -r '.family // "4"' 2>/dev/null)
    case "$cur" in 6) def=2 ;; 46) def=3 ;; esac

    echo ""
    echo -e "  ${BOLD}选择 WARP 出口 IP（分流走 WARP 时对外呈现的地址族）：${NC}"
    echo -e "    1. 仅 IPv4（兼容性最好，推荐）"
    echo -e "    2. 仅 IPv6"
    echo -e "    3. 同时 IPv4 + IPv6（按目标自动选择）"
    local sel; read -rp "$(echo -e "${CYAN}请选择 [${def}]: ${NC}")" sel
    case "${sel:-$def}" in
        2) WARP_FAMILY="6" ;;
        3) WARP_FAMILY="46" ;;
        *) WARP_FAMILY="4" ;;
    esac
}

# ── Sync registered account → outbound.sh state → Xray config ───────────────
_warp_apply_outbound() {
    local family="${1:-4}"
    _warp_registered || return 1
    local acc; acc=$(cat "$WARP_ACCOUNT")
    local host port_="2408"
    local endpoint; endpoint=$(echo "$acc" | jq -r '.endpoint')
    host="${endpoint%%:*}"
    [[ "$endpoint" == *:* ]] && port_="${endpoint##*:}"

    local entry
    entry=$(echo "$acc" | jq --arg tag "$WARP_OUTBOUND_TAG" --arg host "$host" \
                             --argjson port "$port_" --arg family "$family" \
        '{tag:$tag, remark:"Cloudflare WARP", protocol:"wireguard",
          address:$host, port:$port, family:$family,
          secret_key:.secret_key, local_v4:.local_v4, local_v6:.local_v6,
          peer_public_key:.peer_public_key, reserved:.reserved}')

    _outb_upsert "$entry"
    _outb_apply_to_xray
}

# ── Default unlock routing rules ─────────────────────────────────────────────
_warp_add_default_rules() {
    local presets=("netflix" "openai" "disney" "hbo" "spotify")
    local p
    for p in "${presets[@]}"; do
        ask_yn "  是否将 ${p} 流量路由到 WARP？" N || continue
        local id; id=$(_route_next_id)
        local entry
        entry=$(jq -n --arg id "$id" --arg remark "${p} → WARP 解锁" \
                       --arg val "$p" --arg ot "$WARP_OUTBOUND_TAG" \
            '{id:$id,remark:$remark,rule_type:"geosite",value:$val,outbound_tag:$ot}')
        local rules; rules=$(_route_load)
        rules=$(echo "$rules" | jq ". += [$entry]")
        _route_save "$rules"
    done
    _route_apply_to_xray
    xray_test_restart   # unlock rules don't take effect until Xray reloads
}

# ── Interactive: one-click setup ─────────────────────────────────────────────
warp_setup() {
    _xray_require_installed || return

    if _warp_registered; then
        log_info "已注册 WARP 账号（$(jq -r '.registered_at' "$WARP_ACCOUNT")）"
        ask_yn "是否重新注册（会丢弃当前 WARP 身份）？" N && { _warp_register || return 1; }
    else
        _warp_register || return 1
    fi

    _warp_choose_family

    log_step "正在写入 Xray 出站配置..."
    _warp_apply_outbound "$WARP_FAMILY"
    xray_test_restart
    log_ok "WARP 出站（tag: ${WARP_OUTBOUND_TAG}，出口：$(_warp_family_label "$WARP_FAMILY")）已写入"

    # Prerequisite: WARP shunting only makes sense if the tunnel actually reaches
    # the public internet. Verify the real exit IP FIRST and gate everything on
    # it — no point adding unlock rules for a WARP that can't egress.
    echo ""
    if ! warp_check_exit_ip; then
        echo ""
        log_warn "WARP 隧道未能正常出网，已暂停配置分流规则。"
        log_warn "请先排查 WARP 连通性（provider 是否放行 UDP 2408、握手是否成功），"
        log_warn "确认能拿到公网出口 IP 后，再回到本菜单添加解锁分流。"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}WARP 已确认可正常出网，接下来可将部分流量路由到 WARP 解锁：${NC}"
    _warp_add_default_rules
    log_ok "WARP 配置完成。如需自定义更多分流规则，请前往「路由分流管理」。"
}

warp_status() {
    echo -e "\n${BOLD}${BLUE}══ WARP 出站状态 ══════════════════════════${NC}"
    if ! _warp_registered; then
        echo -e "  ${YELLOW}尚未注册 WARP 账号${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
        return
    fi
    local acc; acc=$(cat "$WARP_ACCOUNT")
    echo -e "  注册时间：$(echo "$acc" | jq -r '.registered_at')"
    echo -e "  隧道内网 IPv4：$(echo "$acc" | jq -r '.local_v4') ${YELLOW}(内网地址，非出口 IP)${NC}"
    echo -e "  隧道内网 IPv6：$(echo "$acc" | jq -r '.local_v6 // "（无）"')"
    echo -e "  Endpoint ：$(echo "$acc" | jq -r '.endpoint')"

    local ob_json; ob_json=$(_outb_get_by_tag "$WARP_OUTBOUND_TAG" 2>/dev/null)
    if echo "$ob_json" | jq -e '.tag' &>/dev/null; then
        echo -e "  出站状态：${GREEN}已应用（${WARP_OUTBOUND_TAG}）${NC}"
        local fam; fam=$(echo "$ob_json" | jq -r '.family // "4"')
        echo -e "  出口地址族：${GREEN}$(_warp_family_label "$fam")${NC}"
    else
        echo -e "  出站状态：${YELLOW}未应用，请选择「注册 / 配置 WARP 出站」${NC}"
    fi

    local rule_count
    rule_count=$(_route_load | jq --arg ot "$WARP_OUTBOUND_TAG" '[.[] | select(.outbound_tag == $ot)] | length')
    echo -e "  分流规则：${rule_count} 条指向 WARP"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

warp_remove() {
    if ! _outb_get_by_tag "$WARP_OUTBOUND_TAG" | jq -e '.tag' &>/dev/null; then
        log_warn "WARP 出站尚未配置"; return
    fi
    ask_yn "确认移除 WARP 出站？（引用它的分流规则也会一并删除）" N || return

    local rules; rules=$(_route_load | jq --arg ot "$WARP_OUTBOUND_TAG" '[.[] | select(.outbound_tag != $ot)]')
    _route_save "$rules"
    _route_apply_to_xray

    _outb_delete "$WARP_OUTBOUND_TAG"
    _outb_apply_to_xray
    xray_test_restart

    ask_yn "是否同时删除本机保存的 WARP 账号身份？（下次将重新注册新账号）" N \
        && rm -f "$WARP_ACCOUNT"

    log_ok "WARP 出站及关联分流规则已移除"
}

# ── Switch egress family without re-registering ───────────────────────────────
warp_switch_family() {
    _warp_registered || { log_warn "尚未注册 WARP 账号"; return 1; }
    if ! _outb_get_by_tag "$WARP_OUTBOUND_TAG" | jq -e '.tag' &>/dev/null; then
        log_warn "请先「注册 / 配置 WARP 出站」"; return 1
    fi
    _warp_choose_family
    _warp_apply_outbound "$WARP_FAMILY"
    xray_test_restart
    log_ok "WARP 出口 IP 已切换为：$(_warp_family_label "$WARP_FAMILY")"
    echo ""
    ask_yn "是否立即验证出口 IP？" Y && { warp_check_exit_ip || true; }
}

# ── Probe the REAL exit IP ────────────────────────────────────────────────────
# Registration only yields a WARP identity + the internal 172.16.0.x tunnel
# address — never the exit IP. Cloudflare's edge decides the egress IP only when
# traffic actually flows, so the sole way to learn it is to send a request
# through the tunnel. We stand up a throwaway Xray (socks inbound -> out-warp)
# on localhost, curl Cloudflare's trace endpoint through it, then tear it down —
# without touching the production Xray.
warp_check_exit_ip() {
    _warp_registered || { log_warn "尚未注册 WARP 账号"; return 1; }
    command -v curl &>/dev/null || { log_error "缺少 curl，无法探测出口 IP"; return 1; }

    local ob; ob=$(_outb_get_by_tag "$WARP_OUTBOUND_TAG")
    if ! echo "$ob" | jq -e '.tag' &>/dev/null; then
        log_warn "WARP 出站未配置，请先执行「注册 / 配置 WARP 出站」"
        return 1
    fi
    local xray_ob; xray_ob=$(_outb_build_xray "$ob")
    [[ -n "$xray_ob" ]] || { log_error "构建 WARP 出站配置失败"; return 1; }

    # Pick a free localhost port for the throwaway socks inbound.
    local port=47100
    while ss -ltnH 2>/dev/null | grep -q ":${port} "; do port=$((port+1)); done

    # IMPORTANT: manager.sh runs under `set -euo pipefail`. A failing curl (the
    # tunnel not answering) must NOT abort the whole program, so every
    # potentially-non-zero command below is guarded. We avoid a RETURN trap
    # (its locals are out of scope + unbound under `set -u` when it fires) and
    # instead clean up on a single path. Xray picks config format by extension,
    # so the temp file MUST end in .json or it errors "Failed to get format".
    local xpid="" up=0 i trace="" logtail=""
    local tmpdir tmpcfg tmplog
    tmpdir=$(mktemp -d)                 # -d is portable; named .json inside
    tmpcfg="$tmpdir/probe.json"; tmplog="$tmpdir/xray.log"

    jq -n --argjson ob "$xray_ob" --argjson port "$port" '{
        log: {loglevel:"warning"},
        inbounds:  [{tag:"probe", listen:"127.0.0.1", port:$port,
                     protocol:"socks", settings:{udp:true}}],
        outbounds: [$ob]
    }' > "$tmpcfg"

    log_step "正在通过 WARP 隧道探测实际出口 IP（约需十几秒）..."
    "$XRAY_BIN" run -c "$tmpcfg" >"$tmplog" 2>&1 &
    xpid=$!

    # Wait (max ~6s) for the throwaway Xray's socks port to actually listen.
    for i in $(seq 1 12); do
        kill -0 "$xpid" 2>/dev/null || break          # xray died on startup
        if ss -ltnH 2>/dev/null | grep -q "127.0.0.1:${port} "; then up=1; break; fi
        sleep 0.5
    done

    # If it came up, give the WireGuard handshake a moment, then probe.
    # socks5h → resolve the hostname through the proxy. Try two endpoints.
    if (( up )); then
        sleep 2
        trace=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:${port}" \
            "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null) || true
        if [[ -z "$trace" ]]; then
            trace=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:${port}" \
                "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null) || true
        fi
    fi

    # Single cleanup path: stop the throwaway Xray, keep its log tail, remove temps.
    kill "$xpid" 2>/dev/null || true
    wait "$xpid" 2>/dev/null || true
    logtail=$(tail -n 8 "$tmplog" 2>/dev/null) || true
    rm -rf "$tmpdir"

    if (( ! up )); then
        log_error "临时 Xray 未能启动（无法监听 127.0.0.1:${port}），无法探测"
        echo -e "${YELLOW}Xray 输出（便于排查）：${NC}"
        sed 's/^/    /' <<<"$logtail"
        return 1
    fi

    if [[ -z "$trace" ]]; then
        log_error "探测失败：临时代理已就绪，但无法经 WARP 访问外网"
        echo -e "${YELLOW}常见原因：UDP 2408 出站被封 / WARP 握手失败 / 本机 IP 段被 Cloudflare 限制${NC}"
        echo -e "${YELLOW}Xray 输出（便于排查）：${NC}"
        sed 's/^/    /' <<<"$logtail"
        return 1
    fi

    local exit_ip loc warp_state
    exit_ip=$(awk -F= '/^ip=/{print $2}'   <<<"$trace")
    loc=$(awk -F= '/^loc=/{print $2}'      <<<"$trace")
    warp_state=$(awk -F= '/^warp=/{print $2}' <<<"$trace")

    echo ""
    echo -e "${BOLD}${BLUE}══ WARP 实际出口 ══════════════════════════${NC}"
    echo -e "  出口 IP ：${GREEN}${exit_ip:-未知}${NC}"
    echo -e "  出口地区：${loc:-未知}"
    if [[ "$warp_state" == "on" || "$warp_state" == "plus" ]]; then
        echo -e "  WARP 状态：${GREEN}已生效（warp=${warp_state}）${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
        return 0
    fi
    # Got a public IP but warp=off → traffic reached the internet WITHOUT the
    # tunnel. WARP is not actually carrying traffic, so this counts as a failure.
    echo -e "  WARP 状态：${YELLOW}未走 WARP（warp=${warp_state:-off}）${NC}"
    echo -e "  ${YELLOW}提示：流量没有真正经过 WARP 隧道，解锁分流不会生效。${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
    return 1
}

# ── Menu ──────────────────────────────────────────────────────────────────────
warp_menu() {
    _xray_require_installed || return
    while true; do
        warp_status
        show_menu "WARP 解锁出站" \
            "注册 / 配置 WARP 出站（一键）" \
            "查看 WARP 实际出口 IP" \
            "切换 WARP 出口 IP（IPv4 / IPv6 / 双栈）" \
            "添加常用解锁分流规则" \
            "查看 / 编辑分流规则" \
            "移除 WARP 出站"

        case "$MENU_CHOICE" in
            1) warp_setup;             press_enter ;;
            2) warp_check_exit_ip;     press_enter ;;
            3) warp_switch_family;     press_enter ;;
            4)
                if _outb_get_by_tag "$WARP_OUTBOUND_TAG" | jq -e '.tag' &>/dev/null; then
                    _warp_add_default_rules
                else
                    log_warn "请先注册 / 配置 WARP 出站"
                fi
                press_enter ;;
            5) route_show;             press_enter ;;
            6) warp_remove;            press_enter ;;
            0) return ;;
        esac
    done
}
