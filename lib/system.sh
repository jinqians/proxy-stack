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

    echo -e "\n${BOLD}${BLUE}══ 系统信息 ════════════════════════════${NC}"
    printf "  %-18s %s\n" "操作系统:"   "$os_name"
    printf "  %-18s %s\n" "内核:"       "$kernel"
    printf "  %-18s %s\n" "处理器:"     "$cpu_model"
    printf "  %-18s %s\n" "内存:"       "$mem_total"
    printf "  %-18s %s\n" "交换空间:"   "$swap_total"
    printf "  %-18s %s\n" "磁盘可用:"   "$disk_free"
    printf "  %-18s %s\n" "IPv4:"       "${ipv4:-N/A}"
    printf "  %-18s %s\n" "IPv6:"       "${ipv6:-N/A}"
    printf "  %-18s %s\n" "BBR:"        "${bbr_status:-未知}"
    printf "  %-18s %s\n" "运行时间:"   "$uptime_str"
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
        log_info "BBR 已启用（$(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)）"
        return 0
    fi

    local kmajor kminor
    kmajor=$(uname -r | cut -d. -f1)
    kminor=$(uname -r | cut -d. -f2 | grep -oE '^[0-9]+')
    if (( kmajor < 4 )) || { (( kmajor == 4 )) && (( kminor < 12 )); }; then
        log_warn "内核 $(uname -r) 可能不支持 BBR（最低要求：4.12）"
        ask_yn "是否继续？" N || return 1
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
        log_ok "BBR 已启用，配置写入 /etc/sysctl.d/99-bbr.conf（开机由 systemd-sysctl 自动应用）"
        log_info "拥塞算法：$cc   队列：$qdisc"
        # sysctl -p (no arg) only reads /etc/sysctl.conf and will NOT show a
        # drop-in — steer users to a check that reflects the live value.
        log_info "验证用 ${BOLD}sysctl net.ipv4.tcp_congestion_control${NC} 或 ${BOLD}sysctl --system${NC}（sysctl -p 看不到 drop-in）"
    else
        log_warn "BBR 未立即生效（当前：${cc:-未知}），请重启后验证："
        log_warn "  sysctl net.ipv4.tcp_congestion_control"
    fi
}

# ── Swap ──────────────────────────────────────────────────────────────────────
show_swap() {
    local swap; swap=$(swapon --show 2>/dev/null)
    if [[ -z "$swap" ]]; then
        log_info "未配置交换空间。"
    else
        echo "$swap"
    fi
}

create_swap() {
    local size_mb
    ask size_mb "交换空间大小（MB）" "512"
    [[ "$size_mb" =~ ^[0-9]+$ ]] || { log_error "无效的大小"; return 1; }

    local swapfile="/swapfile"
    if [[ -f "$swapfile" ]]; then
        ask_yn "Swap 文件已存在，是否删除并重新创建？" N || return 0
        swapoff "$swapfile" 2>/dev/null
        rm -f "$swapfile"
    fi

    log_step "正在创建 ${size_mb}MB 交换空间..."
    fallocate -l "${size_mb}M" "$swapfile" 2>/dev/null \
        || dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=none
    chmod 600 "$swapfile"
    mkswap "$swapfile" &>/dev/null
    swapon "$swapfile"

    grep -q "$swapfile" /etc/fstab \
        || echo "$swapfile none swap sw 0 0" >> /etc/fstab

    log_ok "已创建并激活 ${size_mb}MB 交换空间。"
}

delete_swap() {
    swapoff /swapfile 2>/dev/null
    rm -f /swapfile
    sed -i '/swapfile/d' /etc/fstab
    log_ok "Swap 文件已删除。"
}

# ── DNS ───────────────────────────────────────────────────────────────────────
set_dns() {
    echo -e "\n  1. Cloudflare (1.1.1.1 / 1.0.0.1)"
    echo    "  2. Google     (8.8.8.8 / 8.8.4.4)"
    echo    "  3. 自定义"
    read -rp "$(echo -e "${CYAN}请选择 [1]: ${NC}")" dns_choice
    dns_choice="${dns_choice:-1}"

    local ns1 ns2
    case "$dns_choice" in
        1) ns1="1.1.1.1"; ns2="1.0.0.1" ;;
        2) ns1="8.8.8.8";  ns2="8.8.4.4" ;;
        3) ask ns1 "主 DNS"; ask ns2 "备用 DNS" ;;
        *) log_warn "无效选项"; return 1 ;;
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
    log_ok "DNS 已设置为 $ns1 / $ns2"
}

# ── Timezone ──────────────────────────────────────────────────────────────────
set_timezone() {
    ask tz "时区" "Asia/Shanghai"
    timedatectl set-timezone "$tz" 2>/dev/null \
        || { ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime && echo "$tz" > /etc/timezone; }
    log_ok "时区已设置为 $tz"
}

sync_time() {
    if command -v chronyc &>/dev/null; then
        chronyc makestep &>/dev/null
        log_ok "已通过 chrony 同步时间"
    elif command -v ntpdate &>/dev/null; then
        ntpdate -u pool.ntp.org &>/dev/null
        log_ok "已通过 ntpdate 同步时间"
    else
        pkg_install chrony
        svc_enable chronyd 2>/dev/null || svc_enable chrony 2>/dev/null || true
        svc_start chronyd 2>/dev/null || svc_start chrony 2>/dev/null || true
        chronyc makestep &>/dev/null
        log_ok "chrony 已安装并同步时间"
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
    log_ok "内核参数已优化。"

    # ulimit
    local limit_file="/etc/security/limits.d/99-psm.conf"
    cat > "$limit_file" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    log_ok "文件描述符限制已设置。"
}

# ── Open a single port without resetting the whole firewall ──────────────────
# Usage: firewall_open_port <port> [tcp|udp|both]
firewall_open_port() {
    local port="$1" proto="${2:-tcp}"
    local fw
    if command -v ufw &>/dev/null; then fw="ufw"
    elif command -v firewall-cmd &>/dev/null; then fw="firewalld"
    elif command -v iptables &>/dev/null; then fw="iptables"
    else
        log_warn "未找到防火墙工具（ufw / firewalld / iptables），请手动开放端口 $port/$proto。"
        return 0
    fi

    if [[ "$fw" == "ufw" ]]; then
        if [[ "$proto" == "both" ]]; then
            ufw allow "$port/tcp"
            ufw allow "$port/udp"
        else
            ufw allow "$port/$proto"
        fi
        ufw reload 2>/dev/null || true
    elif [[ "$fw" == "firewalld" ]]; then
        if [[ "$proto" == "both" ]]; then
            firewall-cmd --permanent --add-port="$port/tcp"
            firewall-cmd --permanent --add-port="$port/udp"
        else
            firewall-cmd --permanent --add-port="$port/$proto"
        fi
        firewall-cmd --reload
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
        # Persist rules across reboots
        iptables-save  > /etc/sysconfig/iptables 2>/dev/null \
            || iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6  2>/dev/null || true
    fi
    log_ok "防火墙：端口 $port/$proto 已开放。"
}

# ── Firewall quick-lock ───────────────────────────────────────────────────────
configure_firewall() {
    local fw
    if command -v ufw &>/dev/null; then fw="ufw"
    elif command -v firewall-cmd &>/dev/null; then fw="firewalld"
    else
        log_warn "未找到支持的防火墙（ufw / firewalld）。"
        return 0
    fi

    log_step "正在配置防火墙（$fw）——仅放行 22、443/tcp、443/udp"
    if [[ "$fw" == "ufw" ]]; then
        ufw --force reset &>/dev/null
        ufw default deny incoming &>/dev/null
        ufw default allow outgoing &>/dev/null
        ufw allow 22/tcp
        ufw allow 443/tcp
        ufw allow 443/udp
        ufw --force enable &>/dev/null
    else
        firewall-cmd --permanent --set-default-zone=drop
        firewall-cmd --permanent --add-port=22/tcp
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=443/udp
        firewall-cmd --reload
    fi
    log_ok "防火墙已配置。"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_system_check_deps() {
    ensure_pkg_deps curl
}

# ── Menu ──────────────────────────────────────────────────────────────────────
system_menu() {
    _system_check_deps
    while true; do
        show_menu "系统管理" \
            "显示系统信息" \
            "启用 BBR" \
            "创建交换空间" \
            "删除交换空间" \
            "设置 DNS" \
            "设置时区" \
            "同步时间（NTP）" \
            "应用内核参数优化" \
            "配置防火墙（仅 443+22）"

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
