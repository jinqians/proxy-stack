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
        log_info "$(t security.f2b.installed)"
    else
        log_step "$(t security.f2b.installing)"
        detect_os
        # On the RHEL family fail2ban lives in EPEL — enable it the right way
        # per distro (Oracle/RHEL/Amazon each differ; see ensure_epel).
        # `|| true`: ensure_epel returns 1 on AL2023/EPEL-unavailable, and a bare
        # `&& ensure_epel` would abort f2b_install under `set -e`.
        [[ "$PKG_MGR" == "yum" ]] && ensure_epel || true
        # Install separately: batching would let a missing python3-systemd (not
        # packaged everywhere) abort the fail2ban install itself.
        pkg_install fail2ban || { log_error "$(t security.f2b.install_fail)"; return 1; }
        # python3-systemd: required for the systemd journal backend we prefer for
        # the sshd jail — without it fail2ban falls back to reading log files
        # that may not exist on journald-only systems (e.g. Debian 12+).
        pkg_install python3-systemd 2>/dev/null \
            || log_warn "$(t security.f2b.py_systemd_warn)"
        log_ok "$(t security.f2b.installed)"
    fi
    svc_enable fail2ban

    # Older PSM versions shipped a self-referential `ignoreip = %(ignoreip)s ...`
    # in psm-defaults.conf, which makes fail2ban abort at startup with
    # "Recursion limit exceeded in value substitution". Repair any such leftover
    # BEFORE starting, then start with validation so a broken drop-in can't
    # silently wedge the service (and we don't falsely report success).
    _f2b_repair_stale_configs
    if ! _f2b_start_validated; then
        log_error "$(t security.f2b.service_start_fail)"
        return 1
    fi

    ask_yn "$(t security.f2b.ask_setup_ssh)" Y && f2b_setup_wizard
}

# ── Startup safety ────────────────────────────────────────────────────────────
# Repair PSM drop-ins written by older versions that make fail2ban abort with
# "Recursion limit exceeded in value substitution" — the classic culprit is a
# self-referential `ignoreip = %(ignoreip)s ...`. Rewrites our defaults drop-in
# cleanly so an upgrade heals itself instead of staying broken.
_f2b_repair_stale_configs() {
    local f
    for f in "$F2B_DEFAULTS_JAIL" "$F2B_JAIL_DIR"/psm-*.conf; do
        [[ -f "$f" ]] || continue
        if grep -Eq '^[[:space:]]*ignoreip[[:space:]]*=.*%\(ignoreip\)s' "$f"; then
            log_warn "$(t security.f2b.repair_recursive "$(basename "$f")")"
            if [[ "$f" == "$F2B_DEFAULTS_JAIL" ]]; then
                _f2b_write_defaults_jail
            else
                sed -i -E 's/%\(ignoreip\)s//g' "$f"
            fi
        fi
    done
}

# Move every PSM-managed jail.d drop-in aside so a single bad file can't keep the
# whole service down. Admin/non-PSM configs are left untouched.
_f2b_quarantine_dropins() {
    local dir="$F2B_JAIL_DIR"
    compgen -G "$dir/psm-*.conf" >/dev/null 2>&1 || return 0
    local q="$dir/psm-quarantine.$(date +%Y%m%d%H%M%S)"
    mkdir -p "$q"
    mv "$dir"/psm-*.conf "$q"/ 2>/dev/null || true
    log_warn "$(t security.f2b.quarantined "$q")"
}

# Start fail2ban and confirm it actually came up. If a PSM drop-in wedges the
# service, quarantine ALL PSM drop-ins and retry so the base service still runs
# — the user can then re-run the wizard to regenerate clean rules.
_f2b_start_validated() {
    if command -v fail2ban-client &>/dev/null && ! fail2ban-client -t &>/dev/null; then
        log_warn "$(t security.f2b.config_test_retry)"
        _f2b_quarantine_dropins
    fi
    svc_start fail2ban 2>/dev/null || svc_restart fail2ban 2>/dev/null || true
    svc_is_active fail2ban && return 0

    log_warn "$(t security.f2b.start_retry)"
    _f2b_quarantine_dropins
    svc_restart fail2ban 2>/dev/null || true
    if svc_is_active fail2ban; then
        log_warn "$(t security.f2b.quarantine_started)"
        return 0
    fi
    return 1
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
    log_warn "$(t security.f2b.no_firewall)"
    log_warn "$(t security.f2b.no_backend_warn)"

    local fw; fw=$(_f2b_preferred_firewall)
    ask_yn "$(t security.f2b.ask_install_firewall "$fw")" Y || {
        log_warn "$(t security.f2b.skip_firewall)"
        return 1
    }

    log_step "$(t security.f2b.installing_firewall "$fw")"
    pkg_install "$fw" 2>/dev/null || { log_error "$(t security.f2b.firewall_install_fail "$fw")"; return 1; }

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
        log_ok "$(t security.f2b.ufw_ready "$ports")"
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
        log_ok "$(t security.f2b.firewalld_ready "$ports")"
        _f2b_resync_traffic_rules
        return 0
    fi
    log_error "$(t security.f2b.firewall_unavailable "$fw")"
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
    log_step "$(t security.f2b.resync_traffic)"
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

# True when fail2ban's systemd journal backend is usable (needs the python3
# systemd bindings). Debian: python3-systemd; EL: python3-systemd from EPEL.
_f2b_journal_ok() {
    python3 -c 'import systemd.journal' &>/dev/null
}

# Backend line for jails: prefer the journal (works on journald-only systems),
# fall back to "auto" (pyinotify/polling on the distro's default log paths —
# /var/log/auth.log on Debian, /var/log/secure on the RHEL family, both of
# which fail2ban resolves itself via paths-*.conf).
_f2b_backend() {
    _f2b_journal_ok && echo "systemd" || echo "auto"
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
    local backend; backend=$(_f2b_backend)

    local maxretry findtime bantime
    ask maxretry "$(t security.f2b.ask_maxretry)" "5"
    ask findtime "$(t security.f2b.ask_findtime)" "10m"
    ask bantime  "$(t security.f2b.ask_bantime)" "1h"

    cat > "$F2B_SSHD_JAIL" <<EOF
# Managed by PSM — 通过「安全加固 → Fail2ban」菜单重新生成，请勿手动编辑
[sshd]
enabled   = true
backend   = ${backend}
port      = ${ports}
maxretry  = ${maxretry}
findtime  = ${findtime}
bantime   = ${bantime}
banaction = ${banaction}
EOF
    log_ok "$(t security.f2b.ssh_rule_written "$ports" "$findtime" "$maxretry" "$bantime" "$banaction")"
}

f2b_configure_recidive_jail() {
    mkdir -p "$F2B_JAIL_DIR"
    cat > "$F2B_RECIDIVE_JAIL" <<'EOF'
# Managed by PSM — 多次被封的"惯犯" IP 施以更长封禁（沿用 fail2ban 内置默认：1 周封禁 / 1 天统计窗口）
[recidive]
enabled = true
EOF
    log_ok "$(t security.f2b.recidive_enabled)"
}

f2b_reload() {
    if fail2ban-client reload &>/dev/null; then
        log_ok "$(t security.f2b.reloaded)"
    else
        log_warn "$(t security.f2b.reload_fail)"
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
    ask ip "$(t security.f2b.ask_whitelist_ip)" "${suggested:-}"
    [[ -z "$ip" ]] && { log_warn "$(t security.f2b.no_input_cancel)"; return 1; }
    touch "$F2B_WHITELIST_FILE"
    if grep -qxF "$ip" "$F2B_WHITELIST_FILE"; then
        log_info "$(t security.f2b.ip_already_whitelisted)"
        return 0
    fi
    echo "$ip" >> "$F2B_WHITELIST_FILE"
    _f2b_write_defaults_jail
    command -v fail2ban-client &>/dev/null && f2b_reload
    log_ok "$(t security.f2b.whitelist_added "$ip")"
}

f2b_whitelist_remove() {
    [[ -s "$F2B_WHITELIST_FILE" ]] || { log_warn "$(t security.f2b.whitelist_empty)"; return 0; }
    echo -e "\n${BOLD}$(t security.f2b.whitelist_title)${NC}"
    nl -ba "$F2B_WHITELIST_FILE"
    local ip; ask ip "$(t security.f2b.ask_remove_ip)" ""
    [[ -z "$ip" ]] && return 0
    local tmp; tmp=$(mktemp)
    grep -vxF "$ip" "$F2B_WHITELIST_FILE" > "$tmp" && mv "$tmp" "$F2B_WHITELIST_FILE"
    _f2b_write_defaults_jail
    command -v fail2ban-client &>/dev/null && f2b_reload
    log_ok "$(t security.f2b.removed "$ip")"
}

# ── Combined setup wizard ─────────────────────────────────────────────────────
f2b_setup_wizard() {
    echo -e "\n${BOLD}${BLUE}══ $(t security.f2b.wizard_title) ══════════════════${NC}"
    local my_ip; my_ip=$(_f2b_current_client_ip)
    if [[ -n "$my_ip" ]]; then
        echo -e "${YELLOW}$(t security.f2b.current_ip "$my_ip")${NC}"
        ask_yn "$(t security.f2b.ask_whitelist_current)" Y && {
            mkdir -p "$F2B_SEC_DIR"; touch "$F2B_WHITELIST_FILE"
            grep -qxF "$my_ip" "$F2B_WHITELIST_FILE" || echo "$my_ip" >> "$F2B_WHITELIST_FILE"
            _f2b_write_defaults_jail
        }
    else
        log_warn "$(t security.f2b.no_current_ip)"
    fi

    f2b_configure_sshd_jail
    f2b_configure_recidive_jail
    f2b_reload
    log_ok "$(t security.f2b.config_done)"
}

# ── Status / operations ───────────────────────────────────────────────────────
f2b_status() {
    echo -e "\n${BOLD}${BLUE}══ $(t security.f2b.status_title) ══════════════════════${NC}"
    if ! command -v fail2ban-client &>/dev/null; then
        echo -e "  ${YELLOW}$(t security.f2b.not_installed)${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
        return 0
    fi
    if svc_is_active fail2ban; then
        echo -e "  ${GREEN}$(t security.f2b.service_running)${NC}"
    else
        echo -e "  ${RED}$(t security.f2b.service_stopped)${NC}"
    fi

    local jails; jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr -d '\t')
    echo -e "  $(t security.f2b.enabled_jails "${jails:-$(t security.f2b.no_jails)}")"
    local j
    for j in $(echo "$jails" | tr ',' ' '); do
        [[ -z "$j" ]] && continue
        local banned; banned=$(fail2ban-client status "$j" 2>/dev/null \
            | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')
        echo -e "    ${CYAN}${j}${NC}: $(t security.f2b.banned_count "${banned:-0}")"
    done
    if [[ -s "$F2B_WHITELIST_FILE" ]]; then
        echo -e "  $(t security.f2b.whitelist_line "$(tr '\n' ' ' < "$F2B_WHITELIST_FILE")")"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
}

f2b_list_banned() {
    local jail; ask jail "$(t security.f2b.ask_jail_status)" "sshd"
    fail2ban-client status "$jail" 2>&1
}

f2b_unban() {
    local ip; ask ip "$(t security.f2b.ask_unban_ip)" ""
    [[ -z "$ip" ]] && return 0
    fail2ban-client unban "$ip" &>/dev/null \
        && log_ok "$(t security.f2b.unbanned "$ip")" \
        || log_error "$(t security.f2b.unban_fail)"
}

f2b_uninstall() {
    ask_yn "$(t security.f2b.ask_uninstall)" N || return 0
    svc_stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban --quiet 2>/dev/null || true
    rm -f "$F2B_SSHD_JAIL" "$F2B_RECIDIVE_JAIL" "$F2B_DEFAULTS_JAIL"
    log_ok "$(t security.f2b.uninstalled)"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
f2b_menu() {
    while true; do
        f2b_status
        show_menu "$(t security.f2b.menu.title)" \
            "$(t security.f2b.menu.install)" \
            "$(t security.f2b.menu.refresh_ssh)" \
            "$(t security.f2b.menu.status_jail)" \
            "$(t security.f2b.menu.unban)" \
            "$(t security.f2b.menu.add_whitelist)" \
            "$(t security.f2b.menu.remove_whitelist)" \
            "$(t security.f2b.menu.logs)" \
            "$(t security.f2b.menu.disable)"

        case "$MENU_CHOICE" in
            1) f2b_install;             press_enter ;;
            2)
                if command -v fail2ban-client &>/dev/null; then
                    f2b_configure_sshd_jail; f2b_reload
                else
                    log_warn "$(t security.f2b.install_first)"
                fi
                press_enter ;;
            3) f2b_list_banned;         press_enter ;;
            4) f2b_unban;               press_enter ;;
            5) f2b_whitelist_add;       press_enter ;;
            6) f2b_whitelist_remove;    press_enter ;;
            7)
                journalctl -u fail2ban -n 50 --no-pager 2>/dev/null \
                    || tail -n 50 /var/log/fail2ban.log 2>/dev/null \
                    || log_warn "$(t security.f2b.no_logs)"
                press_enter ;;
            8) f2b_uninstall;           press_enter ;;
            0) return ;;
        esac
    done
}
