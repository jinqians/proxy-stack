#!/usr/bin/env bash
# system.sh — system detection, optimization, BBR, swap, DNS, timezone

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── System info ───────────────────────────────────────────────────────────────
show_system_info() {
    local ipv4; ipv4=$(get_ipv4)
    local ipv6; ipv6=$(get_ipv6)
    local cpu_model; cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
    local mem_total; mem_total=$(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)
    local disk_free; disk_free=$(df -h / | awk 'NR==2{print $4}')
    local kernel; kernel=$(uname -r)
    local os_name; os_name=$(source /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
    local uptime_str; uptime_str=$(uptime -p 2>/dev/null || uptime)
    local bbr_status; bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local swap_total; swap_total=$(awk '/SwapTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)

    echo -e "\n${BOLD}${BLUE}══ $(t system.info.title) ════════════════════════════${NC}"
    printf "  %-18s %s\n" "$(t system.info.os)"     "$os_name"
    printf "  %-18s %s\n" "$(t system.info.kernel)" "$kernel"
    printf "  %-18s %s\n" "$(t system.info.cpu)"    "$cpu_model"
    printf "  %-18s %s\n" "$(t system.info.mem)"    "$mem_total"
    printf "  %-18s %s\n" "$(t system.info.swap)"   "$swap_total"
    printf "  %-18s %s\n" "$(t system.info.disk)"   "$disk_free"
    printf "  %-18s %s\n" "IPv4:"       "${ipv4:-N/A}"
    printf "  %-18s %s\n" "IPv6:"       "${ipv6:-N/A}"
    printf "  %-18s %s\n" "BBR:"        "${bbr_status:-$(t system.info.unknown)}"
    printf "  %-18s %s\n" "$(t system.info.uptime)" "$uptime_str"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}\n"
}

# ── Architecture check ────────────────────────────────────────────────────────
# ── BBR ───────────────────────────────────────────────────────────────────────
check_bbr() {
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ "$cc" == "bbr" ]]
}

enable_bbr() {
    if check_bbr; then
        log_info "$(t system.bbr.enabled "$(sysctl -n net.ipv4.tcp_congestion_control)" "$(sysctl -n net.core.default_qdisc)")"
        return 0
    fi

    local kmajor kminor
    kmajor=$(uname -r | cut -d. -f1)
    kminor=$(uname -r | cut -d. -f2 | grep -oE '^[0-9]+')
    if (( kmajor < 4 )) || { (( kmajor == 4 )) && (( kminor < 12 )); }; then
        log_warn "$(t system.bbr.kernel_warn "$(uname -r)")"
        ask_yn "$(t system.ask_continue)" N || return 1
    fi

    # Load BBR now (no-op if built-in) AND ensure it loads at every boot. This
    # second part is the important one on Debian 12: systemd-sysctl applies the
    # drop-in early at boot, and if tcp_bbr isn't loaded yet the kernel silently
    # rejects `tcp_congestion_control = bbr` and falls back to the default — so
    # BBR "disappears" after a reboot even though 99-bbr.conf is present.
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

    # systemd-sysctl.service (boot-time apply, all supported distros) reads
    # /etc/sysctl.d/*.conf, not /etc/sysctl.conf — which some Debian 12
    # installs don't even have. Editing it via `sed -i` on a missing file
    # used to fail and, under this script's `set -e`, abort before anything
    # persisted. Drop-in only, matching apply_sysctl_tuning() below.
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # Apply immediately (explicit file target — works regardless of whether
    # /etc/sysctl.conf exists, unlike bare `sysctl -p`)
    sysctl -p /etc/sysctl.d/99-bbr.conf &>/dev/null || true

    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc; qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [[ "$cc" == "bbr" ]]; then
        log_ok "$(t system.bbr.done)"
        log_info "$(t system.bbr.algo "$cc" "$qdisc")"
        # sysctl -p (no arg) only reads /etc/sysctl.conf and will NOT show a
        # drop-in — steer users to a check that reflects the live value.
        log_info "$(t system.bbr.verify "$BOLD" "$NC" "$BOLD" "$NC")"
    else
        log_warn "$(t system.bbr.not_active "${cc:-$(t system.info.unknown)}")"
        log_warn "  sysctl net.ipv4.tcp_congestion_control"
    fi
}

# ── Swap ──────────────────────────────────────────────────────────────────────
show_swap() {
    local swap; swap=$(swapon --show 2>/dev/null)
    if [[ -z "$swap" ]]; then
        log_info "$(t system.swap.none)"
    else
        echo "$swap"
    fi
}

create_swap() {
    local size_mb
    ask size_mb "$(t system.swap.ask_size)" "512"
    [[ "$size_mb" =~ ^[0-9]+$ ]] || { log_error "$(t system.invalid_size)"; return 1; }

    local swapfile="/swapfile"
    if [[ -f "$swapfile" ]]; then
        ask_yn "$(t system.swap.ask_recreate)" N || return 0
        swapoff "$swapfile" 2>/dev/null
        rm -f "$swapfile"
    fi

    log_step "$(t system.swap.creating "$size_mb")"
    fallocate -l "${size_mb}M" "$swapfile" 2>/dev/null \
        || dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=none
    chmod 600 "$swapfile"
    mkswap "$swapfile" &>/dev/null
    swapon "$swapfile"

    grep -q "$swapfile" /etc/fstab \
        || echo "$swapfile none swap sw 0 0" >> /etc/fstab

    log_ok "$(t system.swap.created "$size_mb")"
}

delete_swap() {
    swapoff /swapfile 2>/dev/null
    rm -f /swapfile
    sed -i '/swapfile/d' /etc/fstab
    log_ok "$(t system.swap.deleted)"
}

# ── DNS ───────────────────────────────────────────────────────────────────────
set_dns() {
    echo -e "\n  1. Cloudflare (1.1.1.1 / 1.0.0.1)"
    echo    "  2. Google     (8.8.8.8 / 8.8.4.4)"
    echo    "  3. $(t system.dns.custom)"
    read -rp "$(echo -e "${CYAN}$(t system.select_default)${NC}")" dns_choice
    dns_choice="${dns_choice:-1}"

    local ns1 ns2
    case "$dns_choice" in
        1) ns1="1.1.1.1"; ns2="1.0.0.1" ;;
        2) ns1="8.8.8.8";  ns2="8.8.4.4" ;;
        3) ask ns1 "$(t system.dns.primary)"; ask ns2 "$(t system.dns.secondary)" ;;
        *) log_warn "$(t system.invalid_option)"; return 1 ;;
    esac

    # disable systemd-resolved stub if present
    if systemctl is-active --quiet systemd-resolved; then
        sed -i 's/^#DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
        svc_restart systemd-resolved 2>/dev/null
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null
    fi

    cat > /etc/resolv.conf <<EOF
nameserver $ns1
nameserver $ns2
EOF
    chattr +i /etc/resolv.conf 2>/dev/null   # prevent overwrite
    log_ok "$(t system.dns.set "$ns1" "$ns2")"
}

# ── Timezone ──────────────────────────────────────────────────────────────────
set_timezone() {
    local tz; ask tz "$(t system.timezone.ask)" "Asia/Shanghai"
    timedatectl set-timezone "$tz" 2>/dev/null \
        || { ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime && echo "$tz" > /etc/timezone; }
    log_ok "$(t system.timezone.set "$tz")"
}

sync_time() {
    if command -v chronyc &>/dev/null; then
        chronyc makestep &>/dev/null
        log_ok "$(t system.time.synced_chrony)"
    elif command -v ntpdate &>/dev/null; then
        ntpdate -u pool.ntp.org &>/dev/null
        log_ok "$(t system.time.synced_ntpdate)"
    else
        pkg_install chrony
        svc_enable chronyd 2>/dev/null || svc_enable chrony 2>/dev/null || true
        svc_start chronyd 2>/dev/null || svc_start chrony 2>/dev/null || true
        chronyc makestep &>/dev/null
        log_ok "$(t system.time.chrony_installed)"
    fi
}

# ── Kernel optimizations ──────────────────────────────────────────────────────
apply_sysctl_tuning() {
    cat > /etc/sysctl.d/99-psm.conf <<'EOF'
# Network performance
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# UDP buffer (for QUIC / Hysteria2)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# File handles
fs.file-max = 1048576
EOF
    sysctl -p /etc/sysctl.d/99-psm.conf &>/dev/null
    log_ok "$(t system.tuning.kernel_done)"

    # ulimit
    local limit_file="/etc/security/limits.d/99-psm.conf"
    cat > "$limit_file" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    log_ok "$(t system.tuning.nofile_done)"
}

# ── Firewall backend detection — prefer a RUNNING backend over a merely
#    installed one (a package can be present while its daemon is down) ──────────
_fw_ufw_active()       { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'; }
_fw_firewalld_active() { command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; }
# iptables counts only when INPUT actually enforces (default DROP/REJECT policy
# or an explicit drop/reject rule); an empty default-ACCEPT table is not a
# firewall and appending ACCEPT rules to it would be meaningless noise.
_fw_iptables_enforcing() {
    command -v iptables &>/dev/null || return 1
    { iptables -S INPUT 2>/dev/null; ip6tables -S INPUT 2>/dev/null; } \
        | grep -Eq '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'
}

# ── Open a single port without resetting the whole firewall ──────────────────
# Usage: firewall_open_port <port> [tcp|udp|both]
firewall_open_port() {
    local port="$1" proto="${2:-tcp}"
    local fw=""
    if _fw_ufw_active; then fw="ufw"
    elif _fw_firewalld_active; then fw="firewalld"
    elif _fw_iptables_enforcing; then fw="iptables"
    fi

    if [[ -z "$fw" ]]; then
        # No firewall is enforcing. Name any installed-but-idle backends so the
        # user knows what they would have to configure by hand later on.
        local installed=()
        command -v ufw &>/dev/null          && installed+=("ufw")
        command -v firewall-cmd &>/dev/null && installed+=("firewalld")
        command -v iptables &>/dev/null     && installed+=("iptables")
        if (( ${#installed[@]} == 0 )); then
            log_warn "$(t system.fw.no_tools "$port" "$proto")"
            return 0
        fi
        local idle="" sep _fw_name; sep="$(t system.fw.list_sep)"
        for _fw_name in "${installed[@]}"; do
            idle="${idle:+${idle}${sep}}${_fw_name}"
        done
        log_warn "$(t system.fw.no_running "$idle" "$port" "$proto")"
        return 0
    fi

    if [[ "$fw" == "ufw" ]]; then
        if [[ "$proto" == "both" ]]; then
            ufw allow "$port/tcp" || { log_error "$(t system.fw.ufw_allow_fail "ufw allow $port/tcp")"; return 1; }
            ufw allow "$port/udp" || { log_error "$(t system.fw.ufw_allow_fail "ufw allow $port/udp")"; return 1; }
        else
            ufw allow "$port/$proto" || { log_error "$(t system.fw.ufw_allow_fail "ufw allow $port/$proto")"; return 1; }
        fi
        ufw reload 2>/dev/null || true
    elif [[ "$fw" == "firewalld" ]]; then
        if [[ "$proto" == "both" ]]; then
            firewall-cmd --permanent --add-port="$port/tcp" || { log_error "$(t system.fw.firewalld_allow_fail "firewall-cmd --permanent --add-port=$port/tcp && firewall-cmd --reload")"; return 1; }
            firewall-cmd --permanent --add-port="$port/udp" || { log_error "$(t system.fw.firewalld_allow_fail "firewall-cmd --permanent --add-port=$port/udp && firewall-cmd --reload")"; return 1; }
        else
            firewall-cmd --permanent --add-port="$port/$proto" || { log_error "$(t system.fw.firewalld_allow_fail "firewall-cmd --permanent --add-port=$port/$proto && firewall-cmd --reload")"; return 1; }
        fi
        firewall-cmd --reload || { log_error "$(t system.fw.firewalld_reload_fail)"; return 1; }
    else
        # iptables fallback (RHEL without firewalld, or minimal installs)
        local protos=()
        [[ "$proto" == "both" ]] && protos=(tcp udp) || protos=("$proto")
        for p in "${protos[@]}"; do
            iptables  -C INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null \
                || iptables  -I INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null || true
            ip6tables -C INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null \
                || ip6tables -I INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null || true
        done
        # Persist rules across reboots (RHEL family: /etc/sysconfig always
        # exists; Debian family: create /etc/iptables so the save can land)
        [[ -d /etc/sysconfig ]] || mkdir -p /etc/iptables 2>/dev/null || true
        iptables-save  > /etc/sysconfig/iptables 2>/dev/null \
            || iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6  2>/dev/null || true
    fi
    log_ok "$(t system.fw.opened "$fw" "$port" "$proto")"
}

# ── Firewall quick-lock ───────────────────────────────────────────────────────
configure_firewall() {
    local fw=""
    # Prefer a running backend; otherwise fall back to whichever is installed
    # (ufw's branch force-enables it; firewalld we start explicitly below).
    if _fw_ufw_active; then fw="ufw"
    elif _fw_firewalld_active; then fw="firewalld"
    elif command -v ufw &>/dev/null; then fw="ufw"
    elif command -v firewall-cmd &>/dev/null; then fw="firewalld"
    else
        log_warn "$(t system.fw.no_supported)"
        return 0
    fi

    log_step "$(t system.fw.configuring "$fw")"
    if [[ "$fw" == "ufw" ]]; then
        ufw --force reset &>/dev/null
        ufw default deny incoming &>/dev/null
        ufw default allow outgoing &>/dev/null
        ufw allow 22/tcp
        ufw allow 443/tcp
        ufw allow 443/udp
        ufw --force enable &>/dev/null
    else
        # firewalld may be installed but stopped — start it before we rely on it.
        if ! _fw_firewalld_active; then
            command -v systemctl &>/dev/null && systemctl enable --now firewalld &>/dev/null
            if ! firewall-cmd --state &>/dev/null; then
                log_error "$(t system.fw.firewalld_start_fail)"
                return 1
            fi
        fi
        firewall-cmd --permanent --set-default-zone=drop || { log_error "$(t system.fw.firewalld_config_fail "firewall-cmd --permanent --set-default-zone=drop")"; return 1; }
        firewall-cmd --permanent --add-port=22/tcp  || { log_error "$(t system.fw.firewalld_config_fail "firewall-cmd --permanent --add-port=22/tcp")"; return 1; }
        firewall-cmd --permanent --add-port=443/tcp || { log_error "$(t system.fw.firewalld_config_fail "firewall-cmd --permanent --add-port=443/tcp")"; return 1; }
        firewall-cmd --permanent --add-port=443/udp || { log_error "$(t system.fw.firewalld_config_fail "firewall-cmd --permanent --add-port=443/udp")"; return 1; }
        firewall-cmd --reload || { log_error "$(t system.fw.firewalld_reload_fail)"; return 1; }
    fi
    log_ok "$(t system.fw.configured)"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_system_check_deps() {
    ensure_pkg_deps curl
}

# ── Menu ──────────────────────────────────────────────────────────────────────
system_menu() {
    _system_check_deps
    while true; do
        show_menu "$(t system.menu.title)" \
            "$(t system.menu.info)" \
            "$(t system.menu.bbr)" \
            "$(t system.menu.create_swap)" \
            "$(t system.menu.delete_swap)" \
            "$(t system.menu.dns)" \
            "$(t system.menu.timezone)" \
            "$(t system.menu.sync_time)" \
            "$(t system.menu.tuning)" \
            "$(t system.menu.firewall)"

        case "$MENU_CHOICE" in
            1) show_system_info ;;
            2) enable_bbr ;;
            3) create_swap ;;
            4) delete_swap ;;
            5) set_dns ;;
            6) set_timezone ;;
            7) sync_time ;;
            8) apply_sysctl_tuning ;;
            9) configure_firewall ;;
            0) return ;;
        esac
        press_enter
    done
}
