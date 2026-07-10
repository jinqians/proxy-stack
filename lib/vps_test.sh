#!/usr/bin/env bash
# vps_test.sh - quick VPS checks and curated third-party test launchers

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_vps_test_check_deps() {
    ensure_pkg_deps curl
    if ! command -v curl &>/dev/null; then
        log_error "$(t common.err.missing_cmd "curl")"
        return 1
    fi
    if ! command -v bash &>/dev/null; then
        log_error "$(t common.err.missing_cmd "bash")"
        return 1
    fi
}

_vps_public_ip() {
    local ipv4 ipv6 org
    ipv4=$(get_ipv4 2>/dev/null || true)
    ipv6=$(get_ipv6 2>/dev/null || true)
    org=$(curl -fsSL --max-time 8 https://ipinfo.io/org 2>/dev/null || true)

    printf "  %-18s %s\n" "IPv4:" "${ipv4:-N/A}"
    printf "  %-18s %s\n" "IPv6:" "${ipv6:-N/A}"
    [[ -n "$org" ]] && printf "  %-18s %s\n" "ASN/ORG:" "$org"
}

_vps_disk_io_probe() {
    local tmp out
    tmp=$(mktemp "${TMPDIR:-/tmp}/psm-vps-io.XXXXXX") || {
        log_warn "$(t vps_test.quick.disk_failed)"
        return 0
    }

    out=$(dd if=/dev/zero of="$tmp" bs=64M count=2 conv=fdatasync 2>&1 | tail -n 1) \
        || out="$(t vps_test.quick.disk_failed)"
    rm -f "$tmp" 2>/dev/null || true
    printf "  %-18s %s\n" "$(t vps_test.quick.disk_io)" "$out"
}

vps_test_quick_check() {
    local os_name kernel arch virt cpu cores mem swap disk bbr qdisc

    os_name=$(source /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$(uname -s)}" || uname -s)
    kernel=$(uname -r 2>/dev/null || echo "N/A")
    arch=$(uname -m 2>/dev/null || echo "N/A")
    if command -v systemd-detect-virt &>/dev/null; then
        virt=$(systemd-detect-virt 2>/dev/null || true)
        [[ -n "$virt" ]] || virt="N/A"
    else
        virt="N/A"
    fi
    cpu=$(awk -F: '/model name|Hardware|Processor/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
    cores=$(nproc 2>/dev/null || awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null || echo "N/A")
    mem=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if(t) printf "%.0f MB total, %.0f MB available", t/1024, a/1024}' /proc/meminfo 2>/dev/null || true)
    swap=$(awk '/SwapTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo 2>/dev/null || true)
    disk=$(df -hP / 2>/dev/null | awk 'NR==2{printf "%s total, %s free, %s used", $2, $4, $5}' || true)
    bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "N/A")

    echo -e "\n${BOLD}${BLUE}══ $(t vps_test.quick.title) ════════════════════════════${NC}"
    printf "  %-18s %s\n" "$(t system.info.os)" "$os_name"
    printf "  %-18s %s\n" "$(t system.info.kernel)" "$kernel"
    printf "  %-18s %s\n" "$(t vps_test.quick.arch)" "$arch"
    printf "  %-18s %s\n" "$(t vps_test.quick.virt)" "$virt"
    printf "  %-18s %s\n" "$(t system.info.cpu)" "${cpu:-N/A} (${cores} cores)"
    printf "  %-18s %s\n" "$(t system.info.mem)" "${mem:-N/A}"
    printf "  %-18s %s\n" "$(t system.info.swap)" "${swap:-N/A}"
    printf "  %-18s %s\n" "$(t system.info.disk)" "${disk:-N/A}"
    printf "  %-18s %s / %s\n" "BBR/Qdisc:" "$bbr" "$qdisc"
    _vps_public_ip
    _vps_disk_io_probe
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}\n"
}

_vps_ping_one() {
    local target="$1" out avg

    if ! command -v ping &>/dev/null; then
        log_warn "$(t vps_test.net.no_ping)"
        return 1
    fi

    out=$(ping -c 4 -W 2 "$target" 2>/dev/null || true)
    avg=$(printf '%s\n' "$out" | awk -F'/' '/min\/avg\/max|round-trip/ {print $5; exit}')
    if [[ -n "$avg" ]]; then
        printf "  %-20s %s ms\n" "$target" "$avg"
    else
        printf "  %-20s %s\n" "$target" "$(t vps_test.net.failed)"
    fi
}

vps_test_network_check() {
    echo -e "\n${BOLD}${BLUE}══ $(t vps_test.net.title) ════════════════════════════${NC}"
    _vps_ping_one "1.1.1.1" || true
    _vps_ping_one "8.8.8.8" || true
    _vps_ping_one "9.9.9.9" || true
    _vps_ping_one "github.com" || true
    _vps_ping_one "cloudflare.com" || true
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}\n"
}

vps_test_trace_route() {
    local target
    ask target "$(t vps_test.trace.ask_target)" "1.1.1.1"
    [[ -n "$target" ]] || { log_info "$(t common.cancelled)"; return 0; }

    if command -v nexttrace &>/dev/null; then
        nexttrace "$target" || true
    elif command -v traceroute &>/dev/null; then
        traceroute "$target" || true
    elif command -v tracepath &>/dev/null; then
        tracepath "$target" || true
    else
        log_warn "$(t vps_test.trace.no_tool)"
    fi
}

_vps_confirm_remote() {
    local name="$1" url="$2"
    log_warn "$(t vps_test.remote.warn "$name")"
    log_info "$(t vps_test.remote.source "$url")"
    ask_yn "$(t vps_test.remote.ask)" N || {
        log_info "$(t common.cancelled)"
        return 1
    }
}

_vps_run_remote_script() {
    local name="$1" url="$2" tmp rc
    shift 2

    _vps_confirm_remote "$name" "$url" || return 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/psm-vps-test.XXXXXX") || {
        log_error "$(t vps_test.remote.tmp_fail)"
        return 0
    }

    log_step "$(t vps_test.remote.downloading "$name")"
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 "$url" -o "$tmp"; then
        log_error "$(t vps_test.remote.download_fail "$url")"
        rm -f "$tmp" 2>/dev/null || true
        return 0
    fi

    chmod 700 "$tmp" 2>/dev/null || true
    log_step "$(t vps_test.remote.running "$name")"
    if bash "$tmp" "$@"; then
        log_ok "$(t vps_test.remote.done "$name")"
    else
        rc=$?
        log_warn "$(t vps_test.remote.exit_code "$name" "$rc")"
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 0
}

vps_test_bench_sh() {
    _vps_run_remote_script "bench.sh" "https://bench.sh"
}

vps_test_node_quality() {
    log_warn "$(t vps_test.heavy_warn)"
    _vps_run_remote_script "NodeQuality" "https://run.NodeQuality.com"
}

vps_test_yabs() {
    log_warn "$(t vps_test.heavy_warn)"
    _vps_run_remote_script "YABS" "https://yabs.sh"
}

vps_test_lemonbench() {
    log_warn "$(t vps_test.heavy_warn)"
    _vps_run_remote_script "LemonBench Fast" "https://ilemonra.in/LemonBenchIntl" fast
}

vps_test_ip_quality() {
    _vps_run_remote_script "IP Quality Check" "https://IP.Check.Place"
}

vps_test_streaming() {
    _vps_run_remote_script "RegionRestrictionCheck" "https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/check.sh"
}

vps_test_menu() {
    _vps_test_check_deps || return 0
    while true; do
        show_menu "$(t vps_test.menu.title)" \
            "$(t vps_test.menu.quick)" \
            "$(t vps_test.menu.network)" \
            "$(t vps_test.menu.trace)" \
            "$(t vps_test.menu.node_quality)" \
            "$(t vps_test.menu.yabs)" \
            "$(t vps_test.menu.ip_quality)" \
            "$(t vps_test.menu.streaming)" \
            "$(t vps_test.menu.bench)" \
            "$(t vps_test.menu.lemonbench)"

        case "$MENU_CHOICE" in
            1) vps_test_quick_check;   press_enter ;;
            2) vps_test_network_check; press_enter ;;
            3) vps_test_trace_route;   press_enter ;;
            4) vps_test_node_quality;  press_enter ;;
            5) vps_test_yabs;          press_enter ;;
            6) vps_test_ip_quality;    press_enter ;;
            7) vps_test_streaming;     press_enter ;;
            8) vps_test_bench_sh;      press_enter ;;
            9) vps_test_lemonbench;    press_enter ;;
            0) return ;;
            *) log_warn "$(t system.invalid_option)"; press_enter ;;
        esac
    done
}
