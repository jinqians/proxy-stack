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
    t security.hp.custom
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
    log_warn "$(t security.hp.iptables_missing)"
    log_step "$(t security.hp.installing_iptables)"
    detect_os
    # EL9+ renamed the package to iptables-nft (provides the iptables command)
    pkg_install iptables 2>/dev/null || pkg_install iptables-nft 2>/dev/null || true
    if command -v iptables &>/dev/null; then
        log_ok "$(t security.hp.iptables_installed)"
        return 0
    fi
    log_error "$(t security.hp.iptables_install_fail)"
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
    # RHEL family keeps rules in /etc/sysconfig (dir always exists there);
    # Debian family uses /etc/iptables, which only exists once
    # iptables-persistent is installed — create it so the save can land.
    [[ -d /etc/sysconfig ]] || mkdir -p /etc/iptables 2>/dev/null || true
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
    # An empty banaction produces `action = %(banaction)s[...]` with no action
    # name — fail2ban then fails to start. iptables-multiport ships with every
    # version, so fall back to it (same last-resort literal as the sshd jail).
    [[ -z "$banaction" ]] && banaction="iptables-multiport"

    # Where to read the kernel's iptables LOG lines from. Prefer the journal
    # (works on journald-only boxes); without python3-systemd fall back to the
    # rsyslog kernel log file — /var/log/kern.log on Debian/Ubuntu,
    # /var/log/messages on the RHEL family.
    local source_lines
    if declare -f _f2b_journal_ok &>/dev/null && _f2b_journal_ok; then
        source_lines=$'backend      = systemd\njournalmatch = _TRANSPORT=kernel'
    elif [[ -f /var/log/kern.log ]]; then
        source_lines=$'backend      = auto\nlogpath      = /var/log/kern.log'
    elif [[ -f /var/log/messages ]]; then
        source_lines=$'backend      = auto\nlogpath      = /var/log/messages'
    else
        # Last resort: keep the journal backend and let f2b_reload surface the
        # error — better than a jail with no log source at all.
        source_lines=$'backend      = systemd\njournalmatch = _TRANSPORT=kernel'
        log_warn "$(t security.hp.log_source_warn)"
    fi

    cat > "$HP_JAIL_FILE" <<EOF
# Managed by PSM — 命中即永久封禁：这些端口本机没有任何合法服务，第一次触碰就是探测
[psm-honeypot]
enabled      = true
filter       = psm-honeypot
${source_lines}
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
    tg_notify_admins "$(t security.hp.alert_template "$ip" "${port:-$(t security.hp.unknown)}" "$label" "$now")"
}

# ── Install / uninstall ───────────────────────────────────────────────────────
hp_install() {
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "$(t security.hp.need_fail2ban)"
        ask_yn "$(t security.hp.ask_install_fail2ban)" Y && f2b_install || return 1
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
        log_warn "$(t security.hp.conflicts_skipped "$conflicts")"
        HONEYPOT_PORTS=$(echo "$HONEYPOT_PORTS" | tr ',' '\n' | grep -vFf <(echo "$conflicts" | tr ' ' '\n') | paste -sd, -)
        _hp_save_cfg
    fi

    echo -e "\n${YELLOW}$(t security.hp.apply_intro)${NC}"
    echo "  ${HONEYPOT_PORTS}"
    echo -e "${YELLOW}$(t security.hp.apply_note1)${NC}"
    echo -e "${YELLOW}$(t security.hp.apply_note2)${NC}"
    echo -e "${YELLOW}$(t security.hp.apply_note3)${NC}"
    ask_yn "$(t security.hp.ask_apply)" Y || { log_info "$(t common.cancelled)"; return 0; }

    hp_apply_rules
    _hp_write_filter
    _hp_write_action
    _hp_write_jail
    f2b_reload

    log_ok "$(t security.hp.enabled "$HONEYPOT_PORTS")"
}

hp_uninstall() {
    ask_yn "$(t security.hp.ask_uninstall)" N || return 0
    hp_remove_rules
    rm -f "$HP_FILTER_FILE" "$HP_ACTION_FILE" "$HP_JAIL_FILE"
    command -v fail2ban-client &>/dev/null && f2b_reload
    log_ok "$(t security.hp.disabled)"
}

# ── Port management ───────────────────────────────────────────────────────────
hp_add_port() {
    _hp_load_cfg
    local port
    ask port "$(t security.hp.ask_add_port)" ""
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t security.hp.invalid_port)"; return 1
    fi
    if echo ",${HONEYPOT_PORTS}," | grep -qF ",${port},"; then
        log_warn "$(t security.hp.port_exists "$port")"; return 0
    fi
    if _hp_is_reserved_port "$port"; then
        log_error "$(t security.hp.port_reserved "$port")"
        return 1
    fi
    _hp_ensure_iptables || return 1
    HONEYPOT_PORTS="${HONEYPOT_PORTS:+${HONEYPOT_PORTS},}${port}"
    _hp_save_cfg
    _hp_apply_port "$port"
    _hp_persist_iptables
    log_ok "$(t security.hp.port_added "$port")"
}

hp_remove_port() {
    _hp_load_cfg
    [[ -z "$HONEYPOT_PORTS" ]] && { log_warn "$(t security.hp.empty_ports)"; return 0; }
    echo -e "\n$(t security.hp.current_ports "$HONEYPOT_PORTS")"
    local port; ask port "$(t security.hp.ask_remove_port)" ""
    [[ -z "$port" ]] && return 0
    if ! echo ",${HONEYPOT_PORTS}," | grep -qF ",${port},"; then
        log_warn "$(t security.hp.port_missing "$port")"; return 0
    fi
    HONEYPOT_PORTS=$(echo "$HONEYPOT_PORTS" | tr ',' '\n' | grep -vxF "$port" | paste -sd, -)
    _hp_save_cfg
    _hp_remove_port "$port"
    _hp_persist_iptables
    log_ok "$(t security.hp.port_removed "$port")"
}

# ── Status ────────────────────────────────────────────────────────────────────
hp_status() {
    echo -e "\n${BOLD}${BLUE}══ $(t security.hp.status_title) ══════════════════════════${NC}"
    _hp_load_cfg
    if [[ -z "$HONEYPOT_PORTS" ]]; then
        echo -e "  ${YELLOW}$(t security.hp.not_configured)${NC}"
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
            state="${YELLOW}$(t security.hp.state_iptables_missing)${NC}"
        elif iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
            applied=$((applied+1)); state="${GREEN}$(t security.hp.state_applied)${NC}"
        else
            state="${RED}$(t security.hp.state_not_applied)${NC}"
        fi
        printf "  $(t security.hp.port_line)" "$port" "$(_hp_port_label "$port")" "$state"
    done
    (( have_ipt )) || echo -e "  ${YELLOW}$(t security.hp.iptables_hint)${NC}"

    if [[ -f "$HP_JAIL_FILE" ]] && command -v fail2ban-client &>/dev/null; then
        local banned; banned=$(fail2ban-client status psm-honeypot 2>/dev/null \
            | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')
        echo -e "  $(t security.hp.banned_count "${banned:-0}")"
    fi
    if [[ -s "$HP_LOG" ]]; then
        echo -e "  $(t security.hp.recent_hits)"
        tail -n 5 "$HP_LOG" | sed 's/^/    /'
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
hp_menu() {
    while true; do
        hp_status
        show_menu "$(t security.hp.menu.title)" \
            "$(t security.hp.menu.enable)" \
            "$(t security.hp.menu.add_port)" \
            "$(t security.hp.menu.remove_port)" \
            "$(t security.hp.menu.full_log)" \
            "$(t security.hp.menu.disable)"

        case "$MENU_CHOICE" in
            1) hp_install;      press_enter ;;
            2) hp_add_port;     press_enter ;;
            3) hp_remove_port;  press_enter ;;
            4) [[ -f "$HP_LOG" ]] && tail -n 50 "$HP_LOG" || log_warn "$(t security.f2b.no_logs)"; press_enter ;;
            5) hp_uninstall;    press_enter ;;
            0) return ;;
        esac
    done
}
