#!/usr/bin/env bash
# security/fail2ban.sh — Fail2ban brute-force protection (SSH-focused)
#
# Writes PSM-managed drop-ins under /etc/ssh's sibling /etc/fail2ban/jail.d/
# rather than editing jail.conf/jail.local, so re-running never clobbers
# anything an admin configured by hand outside PSM.

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

F2B_SEC_DIR="$CFG_DIR/security"
F2B_JAIL_DIR="/etc/fail2ban/jail.d"
F2B_SSHD_JAIL="$F2B_JAIL_DIR/psm-sshd.conf"
F2B_RECIDIVE_JAIL="$F2B_JAIL_DIR/psm-recidive.conf"
F2B_DEFAULTS_JAIL="$F2B_JAIL_DIR/psm-defaults.conf"
F2B_WHITELIST_FILE="$F2B_SEC_DIR/f2b_whitelist.txt"

# ── Install ───────────────────────────────────────────────────────────────────
f2b_install() {
    if command -v fail2ban-client &>/dev/null; then
        log_info "fail2ban 已安装"
    else
        log_step "正在安装 fail2ban..."
        detect_os
        [[ "$PKG_MGR" == "yum" ]] && yum install -y epel-release 2>/dev/null
        # python3-systemd: required for the systemd journal backend we use for
        # the sshd jail — without it fail2ban falls back to reading log files
        # that may not exist on journald-only systems (e.g. Debian 12+).
        pkg_install fail2ban python3-systemd || { log_error "安装失败"; return 1; }
        log_ok "fail2ban 已安装"
    fi
    svc_enable fail2ban
    svc_start fail2ban 2>/dev/null || svc_restart fail2ban

    ask_yn "是否现在配置 SSH 防爆破规则（推荐）？" Y && f2b_setup_wizard
}

# ── Firewall backend detection ───────────────────────────────────────────────
# fail2ban STARTS fine without a firewall, but a ban then silently no-ops: the
# banaction shells out to a firewall command that either isn't installed or
# (for ufw/firewalld) isn't actually enforcing. Two rules:
#   (a) pick a banaction whose action file this fail2ban version ships — the
#       nftables action names changed across releases;
#   (b) prefer a managed frontend's native action ONLY when that frontend is
#       *active*. An installed-but-inactive ufw (the Debian default) can't apply
#       a ban, and meanwhile traffic.sh is driving raw iptables — so we fall
#       through to iptables-multiport, keeping ALL of PSM's firewall writes
#       (traffic accounting/pause + fail2ban bans) on the same backend instead
#       of splitting across ufw-managed and raw-iptables rule sets.
_f2b_has() { command -v "$1" &>/dev/null; }
_f2b_action_exists() { [[ -f "/etc/fail2ban/action.d/$1.conf" ]]; }
_f2b_ufw_active()      { _f2b_has ufw && ufw status 2>/dev/null | grep -q "^Status: active"; }
_f2b_firewalld_active() { _f2b_has firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; }

_f2b_detect_banaction() {
    if   _f2b_ufw_active       && _f2b_action_exists ufw;                    then echo "ufw"
    elif _f2b_firewalld_active && _f2b_action_exists firewallcmd-multiport;  then echo "firewallcmd-multiport"
    # No active frontend: prefer iptables to match what traffic.sh uses (single
    # backend). Only fall to nftables if the iptables command is truly absent.
    elif _f2b_has iptables;                                                  then echo "iptables-multiport"
    elif _f2b_has nft          && _f2b_action_exists nftables-multiport;     then echo "nftables-multiport"
    elif _f2b_has nft          && _f2b_action_exists nftables;               then echo "nftables"
    else echo ""   # no usable firewall backend on this host
    fi
}

# Which firewall to install when the host has none — matched to the distro AND
# to what the rest of PSM already manages: ufw on Debian/Ubuntu, firewalld on
# RHEL (see system.sh's configure_firewall / firewall_open_port). Both are what
# fail2ban's ufw / firewallcmd-multiport banactions drive, so the whole stack
# stays consistent.
_f2b_preferred_firewall() {
    detect_os
    case "$OS_ID" in
        centos|rhel|rocky|almalinux|ol|amzn|fedora) echo "firewalld" ;;
        *)                                          echo "ufw" ;;
    esac
}

# If the host has zero firewall tooling, fail2ban can run but can't actually ban
# anyone (the banaction shells out to a command that isn't there). Install the
# distro-appropriate managed firewall and open SSH + 443 BEFORE enabling it, so
# turning it on can't lock the admin out or kill the proxy. No-op when any
# firewall tool is already present.
_f2b_ensure_firewall_backend() {
    if _f2b_has ufw || _f2b_has firewall-cmd || _f2b_has nft || _f2b_has iptables; then
        return 0
    fi
    log_warn "未检测到任何防火墙（ufw / firewalld / nftables / iptables）"
    log_warn "没有防火墙后端，fail2ban 能启动但无法真正封禁 IP。"

    local fw; fw=$(_f2b_preferred_firewall)
    ask_yn "是否安装并启用 ${fw}（本项目推荐的防火墙，会自动放行 SSH 与 443 端口）？" Y || {
        log_warn "已跳过。fail2ban 的封禁在你安装 ufw/firewalld/nftables/iptables 之一前不会生效。"
        return 1
    }

    log_step "正在安装 ${fw}..."
    pkg_install "$fw" 2>/dev/null || { log_error "${fw} 安装失败"; return 1; }

    # Before enabling a default-deny firewall, open EVERY port PSM's nodes are
    # actually using — not just SSH + 443 — or we'd cut off Reality/SS2022/
    # Hysteria2/Snell/ShadowTLS nodes on their own ports the instant the
    # firewall comes up. tcp+udp for each so QUIC/Hysteria2 (UDP) also survive.
    local ports p; ports=$(_f2b_ports_to_open)
    if [[ "$fw" == "ufw" ]] && _f2b_has ufw; then
        for p in $ports; do
            ufw allow "${p}/tcp" &>/dev/null || true
            ufw allow "${p}/udp" &>/dev/null || true
        done
        ufw --force enable &>/dev/null || true
        log_ok "ufw 已安装并启用（已放行现有节点端口：${ports}）"
        _f2b_resync_traffic_rules
        return 0
    fi
    if [[ "$fw" == "firewalld" ]] && _f2b_has firewall-cmd; then
        systemctl enable --now firewalld 2>/dev/null || true
        for p in $ports; do
            firewall-cmd --permanent --add-port="${p}/tcp" &>/dev/null || true
            firewall-cmd --permanent --add-port="${p}/udp" &>/dev/null || true
        done
        firewall-cmd --reload &>/dev/null || true
        log_ok "firewalld 已安装并启用（已放行现有节点端口：${ports}）"
        _f2b_resync_traffic_rules
        return 0
    fi
    log_error "${fw} 安装后仍不可用，请手动检查"
    return 1
}

# Bringing a firewall up from scratch rebuilds the filter/INPUT chain, which can
# transiently drop the iptables pause rules traffic.sh uses to block over-quota
# nodes. (Accounting lives in the mangle table and is untouched; xray-source
# pauses live in Xray's own config and are untouched too.) traffic.sh self-heals
# these on its next timer tick, but re-assert now so an over-quota node isn't
# briefly reachable the moment we enable the firewall. No-op if traffic metering
# isn't in use. Sourced lazily — traffic.sh pulls in tgbot/expiry, not us.
_f2b_resync_traffic_rules() {
    [[ -f "$CFG_DIR/traffic/state.json" ]] || return 0
    source "$LIB_DIR/traffic.sh" 2>/dev/null || return 0
    declare -f _trf_enforce &>/dev/null || return 0
    log_step "正在重新同步流量限额的防火墙规则（traffic.sh）..."
    _trf_init            2>/dev/null || true
    _trf_ipt_restore_all 2>/dev/null || true   # accounting rules (mangle)
    _trf_enforce         2>/dev/null || true   # re-apply over-quota pause rules
}

# The set of ports to open when we bring a firewall up from scratch. Reuses
# honeypot.sh's _hp_reserved_ports — the project's single source of truth for
# "every port PSM uses" (SSH, 80/443, all proxy node ports, plus anything
# currently listening). Sourced lazily here, NOT at file top: honeypot.sh
# sources fail2ban.sh back, so a top-level include would recurse forever.
_f2b_ports_to_open() {
    source "$(dirname "${BASH_SOURCE[0]}")/honeypot.sh" 2>/dev/null || true
    if declare -f _hp_reserved_ports &>/dev/null; then
        _hp_reserved_ports
    else
        printf '%s 80 443' "$(_f2b_current_ssh_ports)"
    fi
}

# ── SSH port lookup (reuses security/ssh.sh's live-config reader) ────────────
_f2b_current_ssh_ports() {
    source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh" 2>/dev/null || true
    local p=""
    declare -f _ssh_ports &>/dev/null && p=$(_ssh_ports)
    printf '%s' "${p:-22}"
}

# ── Jail configuration ───────────────────────────────────────────────────────
f2b_configure_sshd_jail() {
    mkdir -p "$F2B_JAIL_DIR"
    _f2b_ensure_firewall_backend || true
    local ports; ports=$(_f2b_current_ssh_ports)
    local banaction; banaction=$(_f2b_detect_banaction)
    # Last-resort literal: iptables-multiport ships with every fail2ban version,
    # so the jail stays valid even if detection came up empty.
    [[ -z "$banaction" ]] && banaction="iptables-multiport"

    local maxretry findtime bantime
    ask maxretry "统计窗口内允许的最大失败次数" "5"
    ask findtime "统计窗口（如 10m / 1h）" "10m"
    ask bantime  "封禁时长（如 1h / 1d）" "1h"

    cat > "$F2B_SSHD_JAIL" <<EOF
# Managed by PSM — 通过「安全加固 → Fail2ban」菜单重新生成，请勿手动编辑
[sshd]
enabled   = true
backend   = systemd
port      = ${ports}
maxretry  = ${maxretry}
findtime  = ${findtime}
bantime   = ${bantime}
banaction = ${banaction}
EOF
    log_ok "SSH 防爆破规则已写入（端口 ${ports}，${findtime} 内失败 ${maxretry} 次封禁 ${bantime}，banaction=${banaction}）"
}

f2b_configure_recidive_jail() {
    mkdir -p "$F2B_JAIL_DIR"
    cat > "$F2B_RECIDIVE_JAIL" <<'EOF'
# Managed by PSM — 多次被封的"惯犯" IP 施以更长封禁（沿用 fail2ban 内置默认：1 周封禁 / 1 天统计窗口）
[recidive]
enabled = true
EOF
    log_ok "惯犯（recidive）规则已启用"
}

f2b_reload() {
    if fail2ban-client reload &>/dev/null; then
        log_ok "fail2ban 配置已重新加载"
    else
        log_warn "reload 失败，尝试重启服务"
        svc_restart fail2ban
    fi
}

# ── Whitelist (never-ban) IPs ─────────────────────────────────────────────────
_f2b_current_client_ip() {
    # Set by sshd for the current session: "<client_ip> <client_port> <server_ip> <server_port>"
    [[ -n "${SSH_CONNECTION:-}" ]] && echo "$SSH_CONNECTION" | awk '{print $1}'
}

_f2b_write_defaults_jail() {
    mkdir -p "$F2B_JAIL_DIR" "$F2B_SEC_DIR"
    local ips=""
    [[ -f "$F2B_WHITELIST_FILE" ]] && ips=$(tr '\n' ' ' < "$F2B_WHITELIST_FILE")
    # NOTE: do NOT write `ignoreip = %(ignoreip)s ...` — referencing `ignoreip`
    # inside its own value makes fail2ban's configparser recurse infinitely
    # ("Recursion limit exceeded in value substitution", service exits 255).
    # Spell out localhost literally (matches fail2ban's own built-in default).
    cat > "$F2B_DEFAULTS_JAIL" <<EOF
# Managed by PSM — 白名单 IP 永不封禁（含本机回环，避免误封自己）
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${ips}
EOF
}

f2b_whitelist_add() {
    mkdir -p "$F2B_SEC_DIR"
    local suggested; suggested=$(_f2b_current_client_ip)
    local ip
    ask ip "要加入白名单的 IP/CIDR" "${suggested:-}"
    [[ -z "$ip" ]] && { log_warn "未输入，已取消"; return 1; }
    touch "$F2B_WHITELIST_FILE"
    if grep -qxF "$ip" "$F2B_WHITELIST_FILE"; then
        log_info "该 IP 已在白名单中"
        return 0
    fi
    echo "$ip" >> "$F2B_WHITELIST_FILE"
    _f2b_write_defaults_jail
    command -v fail2ban-client &>/dev/null && f2b_reload
    log_ok "已加入白名单：$ip"
}

f2b_whitelist_remove() {
    [[ -s "$F2B_WHITELIST_FILE" ]] || { log_warn "白名单为空"; return 0; }
    echo -e "\n${BOLD}当前白名单：${NC}"
    nl -ba "$F2B_WHITELIST_FILE"
    local ip; ask ip "要移除的 IP" ""
    [[ -z "$ip" ]] && return 0
    local tmp; tmp=$(mktemp)
    grep -vxF "$ip" "$F2B_WHITELIST_FILE" > "$tmp" && mv "$tmp" "$F2B_WHITELIST_FILE"
    _f2b_write_defaults_jail
    command -v fail2ban-client &>/dev/null && f2b_reload
    log_ok "已移除：$ip"
}

# ── Combined setup wizard ─────────────────────────────────────────────────────
f2b_setup_wizard() {
    echo -e "\n${BOLD}${BLUE}══ Fail2ban 配置向导 ══════════════════${NC}"
    local my_ip; my_ip=$(_f2b_current_client_ip)
    if [[ -n "$my_ip" ]]; then
        echo -e "${YELLOW}检测到你当前的连接 IP：${my_ip}${NC}"
        ask_yn "是否将其加入白名单？（强烈建议，避免自己测试密码/密钥时被误封）" Y && {
            mkdir -p "$F2B_SEC_DIR"; touch "$F2B_WHITELIST_FILE"
            grep -qxF "$my_ip" "$F2B_WHITELIST_FILE" || echo "$my_ip" >> "$F2B_WHITELIST_FILE"
            _f2b_write_defaults_jail
        }
    else
        log_warn "未能自动识别当前连接 IP（可能不是通过 SSH 运行本工具），建议稍后在菜单里手动添加白名单"
    fi

    f2b_configure_sshd_jail
    f2b_configure_recidive_jail
    f2b_reload
    log_ok "Fail2ban 配置完成"
}

# ── Status / operations ───────────────────────────────────────────────────────
f2b_status() {
    echo -e "\n${BOLD}${BLUE}══ Fail2ban 状态 ══════════════════════${NC}"
    if ! command -v fail2ban-client &>/dev/null; then
        echo -e "  ${YELLOW}未安装${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
        return 0
    fi
    if svc_is_active fail2ban; then
        echo -e "  服务状态：${GREEN}运行中${NC}"
    else
        echo -e "  服务状态：${RED}未运行${NC}"
    fi

    local jails; jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr -d '\t')
    echo -e "  已启用规则：${jails:-（无）}"
    local j
    for j in $(echo "$jails" | tr ',' ' '); do
        [[ -z "$j" ]] && continue
        local banned; banned=$(fail2ban-client status "$j" 2>/dev/null \
            | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')
        echo -e "    ${CYAN}${j}${NC}：当前封禁 ${banned:-0} 个 IP"
    done
    if [[ -s "$F2B_WHITELIST_FILE" ]]; then
        echo -e "  白名单：$(tr '\n' ' ' < "$F2B_WHITELIST_FILE")"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
}

f2b_list_banned() {
    local jail; ask jail "查看哪个规则的封禁详情" "sshd"
    fail2ban-client status "$jail" 2>&1
}

f2b_unban() {
    local ip; ask ip "要解封的 IP（从所有规则中解封）" ""
    [[ -z "$ip" ]] && return 0
    fail2ban-client unban "$ip" &>/dev/null \
        && log_ok "已解封：$ip" \
        || log_error "解封失败（该 IP 可能当前未被封禁）"
}

f2b_uninstall() {
    ask_yn "确认卸载 fail2ban 防爆破规则？（会保留白名单记录，仅停用服务和规则）" N || return 0
    svc_stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban --quiet 2>/dev/null || true
    rm -f "$F2B_SSHD_JAIL" "$F2B_RECIDIVE_JAIL" "$F2B_DEFAULTS_JAIL"
    log_ok "fail2ban 已停用（程序本身未卸载，如需彻底移除请用系统包管理器）"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
f2b_menu() {
    while true; do
        f2b_status
        show_menu "Fail2ban 防爆破" \
            "安装 / 一键配置向导（推荐）" \
            "刷新 SSH 规则（改过 SSH 端口后执行）" \
            "查看某规则的封禁详情" \
            "解封 IP" \
            "添加 IP 到白名单" \
            "移除白名单 IP" \
            "查看 fail2ban 日志" \
            "停用防爆破规则"

        case "$MENU_CHOICE" in
            1) f2b_install;             press_enter ;;
            2)
                if command -v fail2ban-client &>/dev/null; then
                    f2b_configure_sshd_jail; f2b_reload
                else
                    log_warn "请先安装 fail2ban"
                fi
                press_enter ;;
            3) f2b_list_banned;         press_enter ;;
            4) f2b_unban;               press_enter ;;
            5) f2b_whitelist_add;       press_enter ;;
            6) f2b_whitelist_remove;    press_enter ;;
            7)
                journalctl -u fail2ban -n 50 --no-pager 2>/dev/null \
                    || tail -n 50 /var/log/fail2ban.log 2>/dev/null \
                    || log_warn "暂无日志"
                press_enter ;;
            8) f2b_uninstall;           press_enter ;;
            0) return ;;
        esac
    done
}
