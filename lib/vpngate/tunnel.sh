#!/usr/bin/env bash
# vpngate/tunnel.sh — 用 openvpn 客户端把选中的 VPNGate 家宽节点拉成一条独立隧道。
#
# 设计要点：
#   • 独立网卡 psmvg0 + 独立路由表，--route-nopull 拒收服务器推来的默认路由，
#     主路由表完全不动 → SSH 与所有既有节点不受影响；
#   • 只有代理核心打了 fwmark 的连接才进这张表，也就是「按分流规则走家宽出口」；
#   • 隧道断开时该表只剩黑洞路由 → 解锁流量失败而不是漏回机房 IP（fail-closed）；
#   • 换节点只改隧道本身，核心配置里的出站是设备/标记级的，永远不用重写。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

VG_DEV="psmvg0"
VG_TABLE="8433"        # 独立路由表号
VG_PRIO="8433"         # ip rule 优先级
VG_MARK="8433"         # 代理核心给「走家宽」的连接打的 fwmark（十进制）

VG_OVPN_DIR="/etc/openvpn"
VG_OVPN_CONF="$VG_OVPN_DIR/psm-vpngate.conf"
VG_OVPN_AUTH="$VG_OVPN_DIR/psm-vpngate.auth"
VG_UP_SCRIPT="$VG_OVPN_DIR/psm-vpngate-up.sh"
VG_DOWN_SCRIPT="$VG_OVPN_DIR/psm-vpngate-down.sh"
VG_SVC_NAME="psm-vpngate"
VG_SVC="/etc/systemd/system/${VG_SVC_NAME}.service"
VG_WD_SVC="/etc/systemd/system/psm-vpngate-watchdog.service"
VG_WD_TIMER="/etc/systemd/system/psm-vpngate-watchdog.timer"
VG_LOG="$LOG_DIR/vpngate.log"

VG_CONNECT_TIMEOUT="${VG_CONNECT_TIMEOUT:-45}"   # 等隧道就绪的秒数
VG_WD_FAIL_THRESHOLD=2                           # 连续几次探测失败才换节点
VG_FAIL_COOLDOWN="${VG_FAIL_COOLDOWN:-21600}"    # 失败节点的冷却期（秒，默认 6 小时）

# ── 依赖 ─────────────────────────────────────────────────────────────────────
_vg_ovpn_bin() { command -v openvpn 2>/dev/null || echo /usr/sbin/openvpn; }

_vg_ensure_openvpn() {
    if [[ ! -c /dev/net/tun ]]; then
        log_error "$(t vg.tun.no_tun_dev)"
        return 1
    fi
    if ! command -v openvpn &>/dev/null; then
        log_step "$(t vg.tun.installing_openvpn)"
        ensure_pkg_deps openvpn
    fi
    if ! command -v openvpn &>/dev/null; then
        log_error "$(t vg.tun.openvpn_missing)"
        return 1
    fi
    require_cmd ip curl jq
    return 0
}

_vg_ovpn_version() {
    local v
    v=$("$(_vg_ovpn_bin)" --version 2>/dev/null | awk 'NR==1 { print $2 }') || v=""
    printf '%s' "${v:-0.0}"
}

# _vg_ver_ge <当前版本> <最低版本>：$1 >= $2 返回 0。纯 bash 比较，不依赖 sort -V
# （开发机 macOS 的 BSD sort 没有 -V），非数字后缀如 2.6.3-rc1 按 0 处理。
_vg_ver_ge() {
    local i len x y
    local -a av bv
    IFS='.' read -ra av <<<"$1"
    IFS='.' read -ra bv <<<"$2"
    len=${#av[@]}; (( ${#bv[@]} > len )) && len=${#bv[@]}
    for (( i=0; i<len; i++ )); do
        x=${av[i]:-0}; y=${bv[i]:-0}
        x=${x%%[!0-9]*}; y=${y%%[!0-9]*}
        (( 10#${x:-0} > 10#${y:-0} )) && return 0
        (( 10#${x:-0} < 10#${y:-0} )) && return 1
    done
    return 0
}

# ── 生成配置 ─────────────────────────────────────────────────────────────────
_vg_write_scripts() {
    mkdir -p "$VG_OVPN_DIR"
    render_tpl "$TPL_DIR/openvpn/vpngate-up.sh.tpl"   "$VG_UP_SCRIPT" \
        "TABLE=$VG_TABLE" "PRIO=$VG_PRIO" "MARK=$VG_MARK" "DEV=$VG_DEV"
    render_tpl "$TPL_DIR/openvpn/vpngate-down.sh.tpl" "$VG_DOWN_SCRIPT" \
        "TABLE=$VG_TABLE" "DEV=$VG_DEV"
    chmod 700 "$VG_UP_SCRIPT" "$VG_DOWN_SCRIPT"
}

# VPNGate 的 OpenVPN 服务端对所有人开放，用户名密码固定是 vpn/vpn；证书认证的
# 节点不会索要它，多写无害。
_vg_write_auth() {
    mkdir -p "$VG_OVPN_DIR"
    printf 'vpn\nvpn\n' > "$VG_OVPN_AUTH"
    chmod 600 "$VG_OVPN_AUTH"
}

# _vg_write_config <ip> [1=追加 OpenSSL legacy provider]
_vg_write_config() {
    local ip="$1" legacy="${2:-0}"
    local cfg
    cfg=$(vg_ovpn_config "$ip") || cfg=""
    [[ -n "$cfg" ]] || { log_error "$(t vg.ovpn.not_found "$ip")"; return 1; }

    # 剥掉官方配置里会与下面覆盖项打架的指令（网卡名、路由、日志、加密套件等），
    # 证书块 <ca>/<cert>/<key> 与 remote/proto 原样保留。压缩指令（comp-lzo 等）
    # 也保留：那是对端要求的帧格式，删掉反而连不上；2.5+ 用 allow-compression
    # 把它重新放行即可。
    local stripped
    stripped=$(printf '%s\n' "$cfg" | grep -vE \
        '^[[:space:]]*(dev|dev-type|dev-node|verb|script-security|up|down|route|redirect-gateway|auth-user-pass|resolv-retry|persist-tun|persist-key|nobind|allow-compression|data-ciphers|data-ciphers-fallback|tls-cipher|connect-retry|connect-retry-max|remote-random|float|log|log-append|status|mute)([[:space:]]|$)' \
        || true)
    [[ -n "$stripped" ]] || { log_error "$(t vg.ovpn.not_found "$ip")"; return 1; }

    local ver; ver=$(_vg_ovpn_version)
    mkdir -p "$VG_OVPN_DIR"
    {
        printf '%s\n' "$stripped"
        cat <<EOF

# ── PSM overrides (generated, do not edit) ───────────────────────────────────
dev $VG_DEV
dev-type tun
nobind
persist-key
persist-tun
# 不接受服务器推送的路由/DNS：默认路由必须留在机房网卡上，否则 SSH 当场断线。
route-nopull
pull-filter ignore "redirect-gateway"
pull-filter ignore "dhcp-option"
pull-filter ignore "block-outside-dns"
auth-user-pass $VG_OVPN_AUTH
auth-nocache
script-security 2
up $VG_UP_SCRIPT
down $VG_DOWN_SCRIPT
# persist-tun 下重连不会重跑 --up，加 up-restart 让重连后重新写回路由表。
up-restart
resolv-retry 30
connect-retry 5 30
# 对端拔电源/断网时不会有 FIN，只会静默消失。ping/ping-restart 让 openvpn 自己
# 在 60 秒内察觉并重拨；真的换节点由看门狗决定。
ping 10
ping-restart 60
mute-replay-warnings
verb 3
EOF
        # VPNGate 的节点普遍还在用 AES-128-CBC + SHA1 证书。OpenVPN 2.5 起默认
        # 只协商 AEAD 套件，OpenSSL 3 又把 SHA1 证书判为「too weak」直接拒握手，
        # 因此 2.5+ 必须显式放开这两处，否则连不上的其实是本地而不是对端。
        if _vg_ver_ge "$ver" "2.5"; then
            cat <<'EOF'
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC:AES-128-CBC
data-ciphers-fallback AES-128-CBC
allow-compression yes
tls-cipher DEFAULT:@SECLEVEL=0
EOF
        fi
        # 个别节点的证书用到了 OpenSSL 3 默认关闭的老算法，只有在首连失败并从
        # 日志里认出这一类报错时才追加，避免在没装 legacy provider 的机器上误伤。
        (( legacy )) && echo "providers legacy default"
    } > "$VG_OVPN_CONF"
    chmod 600 "$VG_OVPN_CONF"
}

_vg_write_unit() {
    cat > "$VG_SVC" <<EOF
[Unit]
Description=PSM VPNGate residential-IP exit tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(_vg_ovpn_bin) --config $VG_OVPN_CONF --cd $VG_OVPN_DIR
Restart=always
RestartSec=10
KillMode=process
LimitNPROC=64

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ── 隧道状态 ─────────────────────────────────────────────────────────────────
vg_tun_installed() { [[ -f "$VG_SVC" && -f "$VG_OVPN_CONF" ]]; }
vg_tun_active()    { svc_is_active "$VG_SVC_NAME"; }
vg_tun_dev_up()    { ip link show "$VG_DEV" &>/dev/null; }

# 注意：这些检查都先把输出收进变量再 grep。管道里用 grep -q 会让上游进程吃到
# SIGPIPE，而 manager.sh 全程 set -o pipefail，会把「匹配成功」误判成失败。
_vg_tun_route_ready() {
    local routes
    routes=$(ip route show table "$VG_TABLE" 2>/dev/null) || return 1
    grep -q "dev $VG_DEV" <<<"$routes"
}

# 经隧道查真实出口 IP 及其归属。curl --interface 走 SO_BINDTODEVICE，配合 up
# 脚本里的 oif 规则命中独立路由表；本函数以 root 运行，权限没有问题。
vg_tun_exit_info() {
    vg_tun_dev_up || return 1
    local resp
    resp=$(curl --interface "$VG_DEV" -fsS --max-time 12 \
                "http://ip-api.com/json/?fields=${VG_IPAPI_FIELDS}" 2>/dev/null) || resp=""
    if [[ -n "$resp" ]] && jq -e '.status == "success"' <<<"$resp" >/dev/null 2>&1; then
        printf '%s' "$resp"
        return 0
    fi
    # ip-api 限频或不可达时退而求其次：只要能拿到出口 IP 就算隧道通。
    local trace ip
    trace=$(curl --interface "$VG_DEV" -fsS --max-time 12 \
                 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null) || trace=""
    ip=$(awk -F= '/^ip=/ { print $2 }' <<<"$trace")
    [[ -n "$ip" ]] || return 1
    jq -nc --arg ip "$ip" '{status:"success", query:$ip}'
}

# ── 连接 ─────────────────────────────────────────────────────────────────────
_vg_journal_tail() { journalctl -u "$VG_SVC_NAME" -n "${1:-15}" --no-pager 2>/dev/null || true; }

# OpenSSL 3 上的 legacy 算法报错特征，命中则值得带 legacy provider 重试一次。
_vg_needs_legacy() {
    local logtail
    logtail=$(_vg_journal_tail 40)
    grep -qiE 'unsupported|legacy|digital envelope routines|EVP_DecryptInit' <<<"$logtail"
}

_vg_wait_ready() {
    local waited=0
    while (( waited < VG_CONNECT_TIMEOUT )); do
        vg_tun_active || return 1
        if vg_tun_dev_up && _vg_tun_route_ready; then return 0; fi
        sleep 2
        waited=$(( waited + 2 ))
    done
    return 1
}

# vg_tun_connect <ip> [静默 0|1] → 0 = 隧道已通且拿到出口 IP
vg_tun_connect() {
    local ip="$1" quiet="${2:-0}"
    _vg_ensure_openvpn || return 1
    _vg_write_scripts
    _vg_write_auth
    _vg_write_config "$ip" 0 || return 1
    _vg_write_unit

    local attempt
    for attempt in 1 2; do
        (( quiet )) || log_step "$(t vg.tun.connecting "$ip")"
        systemctl restart "$VG_SVC_NAME" 2>/dev/null || true

        if _vg_wait_ready; then
            local info
            if info=$(vg_tun_exit_info); then
                # 只有真正连通的节点才值得开机自启——试连失败的配置留在磁盘上
                # 但不自启，免得重启后对着一个死节点空转。
                systemctl enable "$VG_SVC_NAME" &>/dev/null || true
                _vg_record_active "$ip" "$info"
                (( quiet )) || log_ok "$(t vg.tun.connected "$ip" "$(jq -r '.query' <<<"$info")")"
                return 0
            fi
            (( quiet )) || log_warn "$(t vg.tun.no_exit "$ip")"
        else
            (( quiet )) || log_warn "$(t vg.tun.handshake_fail "$ip")"
        fi

        # 第一轮失败且日志像是 OpenSSL legacy 算法问题 → 带 legacy provider 再试一次。
        if (( attempt == 1 )) && _vg_needs_legacy; then
            (( quiet )) || log_info "$(t vg.tun.retry_legacy)"
            _vg_write_config "$ip" 1 || break
            continue
        fi
        break
    done

    systemctl stop "$VG_SVC_NAME" 2>/dev/null || true
    if (( ! quiet )); then
        echo -e "${YELLOW}$(t vg.tun.log_tail)${NC}"
        _vg_journal_tail 12 | sed 's/^/    /'
    fi
    return 1
}

_vg_record_active() {
    local ip="$1" info="$2"
    local cand; cand=$(vg_candidates | jq -c --arg ip "$ip" '[.[] | select(.ip == $ip)][0] // {}')
    local entry
    entry=$(jq -nc --arg ip "$ip" --argjson c "$cand" --argjson i "$info" \
        '{ip: $ip, country: ($c.country // $i.countryCode // ""),
          kind: ($c.kind // ""), isp: ($i.isp // $c.isp // ""),
          exit_ip: ($i.query // ""), exit_hosting: $i.hosting,
          exit_isp: ($i.isp // ""), connected_at: (now | todate)}')
    vg_state_put active "$entry"
}

# ── 故障转移的候选池 ─────────────────────────────────────────────────────────
# VPNGate 的节点全是志愿者的家用线路，随时可能关机、换 IP、断电。所以「当前节点
# 挂了怎么办」不是可选项：轮换必须自动、而且必须留在同一个国家——解锁效果是按
# 出口国判定的，掉线后悄悄漂到另一个国家，等于把 Netflix 的区默默换掉了。
#
# 锚定国家的顺序：扫描时用户选定的国家 → 当前在用节点的国家（选了 ALL 时）。
# 顺序不能反过来：用户刚把国家从 JP 改成 KR 时，.active 还停在上一个 JP 节点上，
# 先看 .active 会把候选池按 JP 过滤，于是一个 KR 候选都匹配不到。
_vg_pool_country() {
    local cc
    cc=$(vg_state_get '.filter.country')
    if [[ -n "$cc" && "$cc" != "ALL" ]]; then printf '%s' "$cc"; return 0; fi
    cc=$(vg_state_get '.active.country')
    [[ -n "$cc" && "$cc" != "null" ]] && printf '%s' "$cc"
    return 0
}

_vg_home_only() {
    [[ "$(vg_state_get '.filter.home_only')" == "false" ]] && { printf '0'; return 0; }
    printf '1'
}

# 刚失败过的节点先冷却，避免看门狗每次都从同一个死节点头铁重试。
_vg_mark_failed() {
    local ip="$1" st now
    now=$(date +%s)
    st=$(vg_state_load)
    vg_state_save "$(echo "$st" | jq --arg ip "$ip" --argjson now "$now" \
                                    --argjson keep "$VG_FAIL_COOLDOWN" '
        .failed = ( ( (.failed // [])
                      | map(select((($now - (.ts // 0)) < $keep) and .ip != $ip)) )
                    + [{ip: $ip, ts: $now}] | .[-50:] )')"
}

# 候选池：同国家 + 不在冷却期 + 排除 skip，顺序沿用候选表（家宽优先、评分倒序）。
_vg_pool_ips() {
    local skip="${1:-}" cc now
    cc=$(_vg_pool_country)
    now=$(date +%s)
    vg_candidates | jq -r --arg cc "$cc" --arg skip "$skip" \
                          --argjson now "$now" --argjson keep "$VG_FAIL_COOLDOWN" \
                          --slurpfile st "$VG_STATE" '
        [ ($st[0].failed // [])[] | select(($now - (.ts // 0)) < $keep) | .ip ] as $cooling
        | [ .[]
            | select( ($cc == "" or .country == $cc)
                      and .ip != $skip
                      and ( .ip as $x | ($cooling | index($x)) == null ) )
            | .ip ]
        | .[]' 2>/dev/null || true
}

# 依次试连候选池，第一个能通的就留下。max=最多试几个。
# 池子空了（同国家的候选都试过或都在冷却）→ 就地重新拉一次该国家的名单再试，
# 这样「提供者集体关机」这种情况也能自愈，而不是停在没有候选可用上。
vg_connect_best() {
    local max="${1:-3}" skip="${2:-}"
    local ips cc
    ips=$(_vg_pool_ips "$skip")
    if [[ -z "$ips" ]]; then
        cc=$(_vg_pool_country)
        if [[ -n "$cc" ]]; then
            log_step "$(t vg.rotate.rescan "$cc")"
            vg_scan "$cc" "$(_vg_home_only)" >/dev/null 2>&1 || true
            ips=$(_vg_pool_ips "$skip")
        fi
    fi
    if [[ -z "$ips" ]]; then
        log_warn "$(t vg.rotate.pool_empty)"
        return 1
    fi

    local -a pool=()
    local ip
    while IFS= read -r ip; do [[ -n "$ip" ]] && pool+=("$ip"); done <<<"$ips"
    (( ${#pool[@]} )) || { log_warn "$(t vg.rotate.pool_empty)"; return 1; }

    local tried=0
    for ip in "${pool[@]}"; do
        (( tried >= max )) && break
        tried=$(( tried + 1 ))
        log_info "$(t vg.tun.trying "$tried" "$max" "$ip")"
        if vg_tun_connect "$ip"; then
            return 0
        fi
        _vg_mark_failed "$ip"
    done
    log_error "$(t vg.tun.all_failed "$tried")"
    return 1
}

vg_tun_down() {
    vg_tun_installed || { log_warn "$(t vg.tun.not_installed)"; return 1; }
    systemctl stop "$VG_SVC_NAME" 2>/dev/null || true
    log_ok "$(t vg.tun.stopped)"
}

# 彻底清理：停服务、删配置、撤掉路由表与规则。
vg_tun_remove() {
    systemctl disable --now "$VG_SVC_NAME" &>/dev/null || true
    rm -f "$VG_SVC" "$VG_OVPN_CONF" "$VG_OVPN_AUTH" "$VG_UP_SCRIPT" "$VG_DOWN_SCRIPT"
    systemctl daemon-reload 2>/dev/null || true

    # 规则可能被 up 脚本重复写过，循环删到没有为止（每次 del 只删一条）。
    local guard=0 rules
    while :; do
        rules=$(ip rule list 2>/dev/null) || break
        grep -q "lookup $VG_TABLE" <<<"$rules" || break
        ip rule del lookup "$VG_TABLE" 2>/dev/null || break
        guard=$(( guard + 1 )); (( guard > 16 )) && break
    done
    guard=0
    while :; do
        rules=$(ip -6 rule list 2>/dev/null) || break
        grep -q "lookup $VG_TABLE" <<<"$rules" || break
        ip -6 rule del lookup "$VG_TABLE" 2>/dev/null || break
        guard=$(( guard + 1 )); (( guard > 16 )) && break
    done
    ip route flush table "$VG_TABLE" 2>/dev/null || true
    ip -6 route flush table "$VG_TABLE" 2>/dev/null || true

    vg_state_put active 'null'
    log_ok "$(t vg.tun.removed)"
}

# ── 看门狗：掉线自动换家宽节点 ────────────────────────────────────────────────
_vg_wd_log() {
    mkdir -p "$LOG_DIR"
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$VG_LOG"
}

vg_watchdog_enabled() { [[ "$(vg_state_get '.watchdog.enabled')" == "true" ]]; }

vg_watchdog_enable() {
    cat > "$VG_WD_SVC" <<EOF
[Unit]
Description=PSM VPNGate tunnel watchdog
After=network.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PSM_ROOT}/manager.sh --vpngate-watchdog
StandardOutput=journal
StandardError=journal
EOF
    cat > "$VG_WD_TIMER" <<'EOF'
[Unit]
Description=PSM VPNGate tunnel watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now psm-vpngate-watchdog.timer &>/dev/null || true
    vg_state_put watchdog "$(jq -nc '{enabled: true, fail: 0}')"
    log_ok "$(t vg.wd.enabled)"
}

vg_watchdog_disable() {
    systemctl disable --now psm-vpngate-watchdog.timer &>/dev/null || true
    rm -f "$VG_WD_SVC" "$VG_WD_TIMER"
    systemctl daemon-reload 2>/dev/null || true
    vg_state_put watchdog "$(jq -nc '{enabled: false, fail: 0}')"
    log_ok "$(t vg.wd.disabled)"
}

# 非交互执行：manager.sh --vpngate-watchdog（systemd timer 每 5 分钟调用一次）。
vg_watchdog_run() {
    _vg_init
    vg_watchdog_enabled || return 0
    vg_tun_installed || return 0

    local cur; cur=$(vg_state_get '.active.ip')
    local fail; fail=$(vg_state_get '.watchdog.fail'); [[ -n "$fail" ]] || fail=0

    if ! vg_tun_active; then
        _vg_wd_log "service inactive → restart"
        systemctl restart "$VG_SVC_NAME" 2>/dev/null || true
        sleep 10
    fi

    local info
    if info=$(vg_tun_exit_info); then
        local exit_ip; exit_ip=$(jq -r '.query // ""' <<<"$info")
        if (( fail > 0 )); then _vg_wd_log "recovered via ${cur:-?} (exit $exit_ip)"; fi
        vg_state_put watchdog "$(jq -nc '{enabled: true, fail: 0}')"
        # 出口 IP 可能随对端重拨变化，顺手刷新记录。
        [[ -n "$cur" ]] && _vg_record_active "$cur" "$info"
        return 0
    fi

    fail=$(( fail + 1 ))
    vg_state_put watchdog "$(jq -nc --argjson f "$fail" '{enabled: true, fail: $f}')"
    _vg_wd_log "probe failed (${fail}/${VG_WD_FAIL_THRESHOLD}) on ${cur:-?}"
    (( fail < VG_WD_FAIL_THRESHOLD )) && return 0

    # 连续失败达到阈值 → 在同一个国家里换一个候选。候选表过期（>24h）先刷新。
    local cc; cc=$(_vg_pool_country)
    local scanned age_ok=1
    scanned=$(vg_state_get '.filter.scanned_at')
    if [[ -n "$scanned" ]]; then
        local ts now
        ts=$(date -d "$scanned" +%s 2>/dev/null || echo 0)
        now=$(date +%s)
        (( now - ts > 86400 )) && age_ok=0
    else
        age_ok=0
    fi
    if (( ! age_ok )); then
        _vg_wd_log "refreshing candidate list (${cc:-ALL})"
        vg_scan "${cc:-ALL}" "$(_vg_home_only)" >/dev/null 2>&1 || true
    fi

    # 把刚挂掉的节点打进冷却，免得轮换又转回它身上。
    [[ -n "$cur" ]] && _vg_mark_failed "$cur"

    _vg_wd_log "rotating away from ${cur:-?} within ${cc:-any country}"
    if vg_connect_best 3 "$cur" >/dev/null 2>&1; then
        _vg_wd_log "rotated to $(vg_state_get '.active.ip') (exit $(vg_state_get '.active.exit_ip'))"
        vg_state_put watchdog "$(jq -nc '{enabled: true, fail: 0}')"
    else
        _vg_wd_log "rotation failed — tunnel still down"
    fi
    return 0
}
