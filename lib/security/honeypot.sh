#!/usr/bin/env bash
# security/honeypot.sh — Tripwire ports for zero-false-positive scan detection
#
# Listens for connection attempts on ports this box has no legitimate reason
# to expose (RDP/MSSQL/Telnet/etc — this is a proxy VPS, not a database or
# Windows host). Any packet to these ports is inherently a probe, so unlike
# fail2ban's SSH jail (which tolerates a few retries because real users mistype
# passwords), a single hit here is enough to ban permanently.
#
# Mechanism: iptables LOG+DROP on each port (no fake service needed — a SYN
# is already the signal), consumed by a dedicated fail2ban jail (maxretry=1,
# bantime=-1) that also fires a Telegram alert via a custom fail2ban action.

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

source "$(dirname "${BASH_SOURCE[0]}")/fail2ban.sh" 2>/dev/null || true
# Needed for _ssh_ports() below — SSH's *current* port, not just 22, since
# the admin may have moved it via 安全加固 → SSH 安全加固.
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh" 2>/dev/null || true

HP_SEC_DIR="$CFG_DIR/security"
HP_CFG="$HP_SEC_DIR/honeypot.conf"
HP_LOG="${LOG_DIR}/honeypot.log"
HP_LOG_PREFIX="PSM-HONEYPOT: "
HP_FILTER_FILE="/etc/fail2ban/filter.d/psm-honeypot.conf"
HP_ACTION_FILE="/etc/fail2ban/action.d/psm-honeypot-alert.conf"
HP_JAIL_FILE="/etc/fail2ban/jail.d/psm-honeypot.conf"

# port:label — curated set of "never legitimately open on a proxy box" ports.
HP_DEFAULT_PORTS="21:FTP 23:Telnet 445:SMB 1433:MSSQL 3306:MySQL 3389:RDP 5432:PostgreSQL 5900:VNC 6379:Redis 9200:Elasticsearch 27017:MongoDB"

_hp_init() { mkdir -p "$HP_SEC_DIR"; }

_hp_load_cfg() {
    HONEYPOT_PORTS=""
    # shellcheck source=/dev/null
    [[ -f "$HP_CFG" ]] && source "$HP_CFG"
    if [[ -z "$HONEYPOT_PORTS" ]]; then
        HONEYPOT_PORTS=$(echo "$HP_DEFAULT_PORTS" | tr ' ' '\n' | cut -d: -f1 | paste -sd, -)
    fi
}

_hp_save_cfg() {
    _hp_init
    printf 'HONEYPOT_PORTS="%s"\n' "$HONEYPOT_PORTS" > "$HP_CFG"
}

_hp_port_label() {
    local port="$1" entry
    for entry in $HP_DEFAULT_PORTS; do
        [[ "${entry%%:*}" == "$port" ]] && { printf '%s' "${entry#*:}"; return 0; }
    done
    printf '自定义'
}

# Ports this box always needs, regardless of whether something happens to be
# listening on them right now — SSH/HTTP/HTTPS plus every port PSM has ever
# configured for a proxy protocol. A honeypot rule is a firewall DROP; adding
# one of these here would self-inflict an outage the moment that service
# (re)starts, so these are refused outright rather than just "not currently busy".
_hp_reserved_ports() {
    # 22 stays reserved unconditionally — belt-and-suspenders in case sshd is
    # ever unreachable (_ssh_ports queries `sshd -T` live) — on top of
    # whatever the *current* SSH port(s) actually are, since the admin may
    # have moved it via SSH 安全加固.
    local ports="80 443 22"
    declare -f _ssh_ports &>/dev/null && ports="$ports $(_ssh_ports | tr ',' ' ')"

    if [[ -f "${XRAY_CFG:-$XRAY_CFG_DIR/config.json}" ]] && command -v jq &>/dev/null; then
        ports="$ports $(jq -r '.inbounds[]?.port // empty' "${XRAY_CFG:-$XRAY_CFG_DIR/config.json}" 2>/dev/null | tr '\n' ' ')"
    fi
    if [[ -f "${HY2_CFG:-/etc/hysteria/config.yaml}" ]]; then
        ports="$ports $(grep '^listen:' "${HY2_CFG:-/etc/hysteria/config.yaml}" 2>/dev/null | grep -oE '[0-9]+' | tr '\n' ' ')"
    fi
    if [[ -d "${SNELL_CONF_DIR:-/etc/snell}/users" ]]; then
        ports="$ports $(grep -hE '^listen' "${SNELL_CONF_DIR:-/etc/snell}"/users/snell-*.conf 2>/dev/null \
            | grep -oE '[0-9]+$' | tr '\n' ' ')"
    fi
    if [[ -f "${SS_CONF:-/etc/ss-rust/config.json}" ]] && command -v jq &>/dev/null; then
        ports="$ports $(jq -r '.server_port // empty' "${SS_CONF:-/etc/ss-rust/config.json}" 2>/dev/null)"
    fi
    # ShadowTLS units front Snell/SS-rust on their own public listen port,
    # separate from the backend port above — shadowtls-ss.service (SS-rust,
    # single instance) and shadowtls-snell-<port>.service (Snell, one per user).
    ports="$ports $(grep -hoP '(?<=--listen ::0:)\d+' /etc/systemd/system/shadowtls-*.service 2>/dev/null | tr '\n' ' ')"

    # Generic catch-all: anything explicitly opened in the firewall, or
    # currently listening, regardless of whether PSM knows what it is. This
    # is what actually protects services set up outside PSM entirely (a
    # personal site, a database, a game server, anything) — the checks above
    # only cover services PSM itself manages, which can never be a complete list.
    ports="$ports $(_hp_firewall_opened_ports) $(_hp_listening_ports)"

    echo "$ports" | tr -s ' ' '\n' | grep -v '^$' | sort -un | tr '\n' ' '
}

_hp_firewall_opened_ports() {
    local ports=""
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        ports="$ports $(ufw status 2>/dev/null | grep -oE '^[0-9]+' | tr '\n' ' ')"
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        ports="$ports $(firewall-cmd --list-ports 2>/dev/null | grep -oE '[0-9]+' | tr '\n' ' ')"
    fi
    if command -v iptables &>/dev/null; then
        ports="$ports $(iptables -L INPUT -n 2>/dev/null | grep ACCEPT | grep -oE 'dpt:[0-9]+' | cut -d: -f2 | tr '\n' ' ')"
    fi
    echo "$ports"
}

# Anything actually bound and listening right now, TCP or UDP — catches
# services that were never explicitly "opened" via a firewall rule (e.g. the
# host firewall is off, or the service only binds to a public interface
# without any port-open step).
_hp_listening_ports() {
    command -v ss &>/dev/null || return 0
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$'
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$'
}

_hp_is_reserved_port() {
    local port="$1"
    echo " $(_hp_reserved_ports) " | grep -qF " ${port} "
}

# ── iptables rule management ─────────────────────────────────────────────────
# The honeypot tripwire IS an iptables LOG+DROP rule (the LOG line is what the
# fail2ban jail matches). On nftables-only / minimal boxes the iptables command
# can be absent -> "iptables: command not found". Install it (the nft-backed
# wrapper on modern distros — same backend traffic.sh already writes to) so the
# mechanism works. Returns non-zero if it truly can't be provided.
_hp_ensure_iptables() {
    command -v iptables &>/dev/null && return 0
    log_warn "未找到 iptables（蜜罐的 LOG+DROP 规则依赖它）"
    log_step "正在安装 iptables..."
    detect_os
    pkg_install iptables 2>/dev/null || true
    if command -v iptables &>/dev/null; then
        log_ok "iptables 已安装"
        return 0
    fi
    log_error "iptables 安装失败，蜜罐无法设置规则，请手动安装 iptables 后重试"
    return 1
}

_hp_apply_port() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4
    iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$port" -j DROP
    ip6tables -C INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4 2>/dev/null \
        || ip6tables -A INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4 2>/dev/null || true
    ip6tables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null \
        || ip6tables -A INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
}

_hp_remove_port() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4 2>/dev/null \
        && iptables -D INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4
    iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null \
        && iptables -D INPUT -p tcp --dport "$port" -j DROP
    ip6tables -C INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4 2>/dev/null \
        && ip6tables -D INPUT -p tcp --dport "$port" -j LOG --log-prefix "$HP_LOG_PREFIX" --log-level 4 2>/dev/null
    ip6tables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null \
        && ip6tables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    true
}

_hp_persist_iptables() {
    iptables-save  > /etc/sysconfig/iptables    2>/dev/null \
        || iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6     2>/dev/null || true
}

hp_apply_rules() {
    _hp_load_cfg
    local port
    IFS=',' read -ra _ports <<< "$HONEYPOT_PORTS"
    for port in "${_ports[@]}"; do
        [[ -n "$port" ]] && _hp_apply_port "$port"
    done
    _hp_persist_iptables
}

hp_remove_rules() {
    _hp_load_cfg
    local port
    IFS=',' read -ra _ports <<< "$HONEYPOT_PORTS"
    for port in "${_ports[@]}"; do
        [[ -n "$port" ]] && _hp_remove_port "$port"
    done
    _hp_persist_iptables
}

# ── fail2ban wiring ───────────────────────────────────────────────────────────
_hp_write_filter() {
    mkdir -p "$(dirname "$HP_FILTER_FILE")"
    cat > "$HP_FILTER_FILE" <<EOF
# Managed by PSM — matches the LOG line iptables writes right before DROPping
# a connection to a honeypot port. Any match is inherently malicious.
[Definition]
failregex = ^.*${HP_LOG_PREFIX}.*SRC=<HOST> .*DPT=<F-PORT>\d+</F-PORT>
ignoreregex =
EOF
}

_hp_write_action() {
    mkdir -p "$(dirname "$HP_ACTION_FILE")"
    cat > "$HP_ACTION_FILE" <<EOF
# Managed by PSM — fires a Telegram alert to all bot admins on every honeypot hit.
[Definition]
actionban = ${PSM_ROOT}/manager.sh --honeypot-alert <ip> <F-PORT>
EOF
}

_hp_write_jail() {
    mkdir -p "$(dirname "$HP_JAIL_FILE")"
    local banaction; banaction=$(_f2b_detect_banaction)
    cat > "$HP_JAIL_FILE" <<EOF
# Managed by PSM — 命中即永久封禁：这些端口本机没有任何合法服务，第一次触碰就是探测
[psm-honeypot]
enabled      = true
filter       = psm-honeypot
backend      = systemd
journalmatch = _TRANSPORT=kernel
maxretry     = 1
findtime     = 1d
bantime      = -1
port         = 0:65535
banaction    = ${banaction}
action       = %(banaction)s[port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
               psm-honeypot-alert[name=%(__name__)s]
EOF
}

# ── Alert (invoked by fail2ban's actionban, via manager.sh --honeypot-alert) ──
hp_alert() {
    local ip="$1" port="$2"
    _hp_init
    local now; now=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${now} BANNED ip=${ip} port=${port:-?}" >> "$HP_LOG"

    source "$(dirname "${BASH_SOURCE[0]}")/../tgbot/notify.sh" 2>/dev/null || true
    declare -f tg_notify_admins &>/dev/null || return 0
    local label; label=$(_hp_port_label "${port:-}")
    tg_notify_admins "$(printf \
'🍯 *蜜罐触发*
━━━━━━━━━━━━━━━━━━━━
IP：`%s`
目标端口：`%s`（%s，本机无合法服务监听此端口）
时间：%s

该 IP 正在扫描/踩点本机，已自动永久封禁。' \
        "$ip" "${port:-未知}" "$label" "$now")"
}

# ── Install / uninstall ───────────────────────────────────────────────────────
hp_install() {
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "蜜罐依赖 fail2ban 做封禁，请先安装（安全加固 → Fail2ban）"
        ask_yn "是否现在安装 fail2ban？" Y && f2b_install || return 1
    fi
    _hp_ensure_iptables || return 1

    _hp_load_cfg
    local port conflicts=""
    IFS=',' read -ra _ports <<< "$HONEYPOT_PORTS"
    for port in "${_ports[@]}"; do
        [[ -n "$port" ]] || continue
        _hp_is_reserved_port "$port" && conflicts="${conflicts}${port} "
    done
    if [[ -n "$conflicts" ]]; then
        log_warn "以下端口已被占用（本机服务、防火墙已放行的端口，或 PSM 认识的代理节点），跳过：${conflicts}"
        HONEYPOT_PORTS=$(echo "$HONEYPOT_PORTS" | tr ',' '\n' | grep -vFf <(echo "$conflicts" | tr ' ' '\n') | paste -sd, -)
        _hp_save_cfg
    fi

    echo -e "\n${YELLOW}即将对以下端口设置蜜罐（命中即永久封禁）：${NC}"
    echo "  ${HONEYPOT_PORTS}"
    echo -e "${YELLOW}以上是自动排除已知冲突后的结果，但 PSM 只能识别防火墙已放行/当前正在监听的服务。${NC}"
    echo -e "${YELLOW}如果你在这台机器上还部署了其它不走防火墙规则、此刻也没在监听的公网服务${NC}"
    echo -e "${YELLOW}（例如还没启动、或监听在稍后才会打开的端口），请自行确认没有冲突。${NC}"
    ask_yn "确认应用以上蜜罐端口？" Y || { log_info "已取消"; return 0; }

    hp_apply_rules
    _hp_write_filter
    _hp_write_action
    _hp_write_jail
    f2b_reload

    log_ok "蜜罐已启用（端口：${HONEYPOT_PORTS}）。命中即永久封禁 + 推送 Telegram 告警。"
}

hp_uninstall() {
    ask_yn "确认关闭蜜罐？（会移除 iptables 规则和 fail2ban 规则，已封禁的 IP 不受影响）" N || return 0
    hp_remove_rules
    rm -f "$HP_FILTER_FILE" "$HP_ACTION_FILE" "$HP_JAIL_FILE"
    command -v fail2ban-client &>/dev/null && f2b_reload
    log_ok "蜜罐已关闭"
}

# ── Port management ───────────────────────────────────────────────────────────
hp_add_port() {
    _hp_load_cfg
    local port
    ask port "要新增的蜜罐端口" ""
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "端口无效"; return 1
    fi
    if echo ",${HONEYPOT_PORTS}," | grep -qF ",${port},"; then
        log_warn "端口 ${port} 已在蜜罐列表中"; return 0
    fi
    if _hp_is_reserved_port "$port"; then
        log_error "端口 ${port} 已被占用（本机服务、防火墙已放行的端口，或 PSM 认识的代理节点），拒绝添加"
        return 1
    fi
    _hp_ensure_iptables || return 1
    HONEYPOT_PORTS="${HONEYPOT_PORTS:+${HONEYPOT_PORTS},}${port}"
    _hp_save_cfg
    _hp_apply_port "$port"
    _hp_persist_iptables
    log_ok "端口 ${port} 已加入蜜罐"
}

hp_remove_port() {
    _hp_load_cfg
    [[ -z "$HONEYPOT_PORTS" ]] && { log_warn "蜜罐端口列表为空"; return 0; }
    echo -e "\n当前蜜罐端口：${HONEYPOT_PORTS}"
    local port; ask port "要移除的端口" ""
    [[ -z "$port" ]] && return 0
    if ! echo ",${HONEYPOT_PORTS}," | grep -qF ",${port},"; then
        log_warn "端口 ${port} 不在蜜罐列表中"; return 0
    fi
    HONEYPOT_PORTS=$(echo "$HONEYPOT_PORTS" | tr ',' '\n' | grep -vxF "$port" | paste -sd, -)
    _hp_save_cfg
    _hp_remove_port "$port"
    _hp_persist_iptables
    log_ok "端口 ${port} 已从蜜罐移除"
}

# ── Status ────────────────────────────────────────────────────────────────────
hp_status() {
    echo -e "\n${BOLD}${BLUE}══ 蜜罐诱捕状态 ══════════════════════════${NC}"
    _hp_load_cfg
    if [[ -z "$HONEYPOT_PORTS" ]]; then
        echo -e "  ${YELLOW}未配置${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
        return 0
    fi
    local port applied=0 total=0 have_ipt=1
    command -v iptables &>/dev/null || have_ipt=0
    IFS=',' read -ra _ports <<< "$HONEYPOT_PORTS"
    for port in "${_ports[@]}"; do
        [[ -z "$port" ]] && continue
        total=$((total+1))
        local state
        if (( ! have_ipt )); then
            state="${YELLOW}iptables 未安装${NC}"
        elif iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
            applied=$((applied+1)); state="${GREEN}规则已生效${NC}"
        else
            state="${RED}未生效${NC}"
        fi
        printf "  端口 %-6s %-14s %b\n" "$port" "$(_hp_port_label "$port")" "$state"
    done
    (( have_ipt )) || echo -e "  ${YELLOW}提示：本机未安装 iptables，蜜罐规则无法生效，请重新执行「启用蜜罐」自动安装。${NC}"

    if [[ -f "$HP_JAIL_FILE" ]] && command -v fail2ban-client &>/dev/null; then
        local banned; banned=$(fail2ban-client status psm-honeypot 2>/dev/null \
            | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')
        echo -e "  已封禁 IP 数：${banned:-0}"
    fi
    if [[ -s "$HP_LOG" ]]; then
        echo -e "  最近命中："
        tail -n 5 "$HP_LOG" | sed 's/^/    /'
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
hp_menu() {
    while true; do
        hp_status
        show_menu "蜜罐诱捕" \
            "启用蜜罐（安装规则 + fail2ban 联动）" \
            "添加蜜罐端口" \
            "移除蜜罐端口" \
            "查看完整命中日志" \
            "关闭蜜罐"

        case "$MENU_CHOICE" in
            1) hp_install;      press_enter ;;
            2) hp_add_port;     press_enter ;;
            3) hp_remove_port;  press_enter ;;
            4) [[ -f "$HP_LOG" ]] && tail -n 50 "$HP_LOG" || log_warn "暂无日志"; press_enter ;;
            5) hp_uninstall;    press_enter ;;
            0) return ;;
        esac
    done
}
