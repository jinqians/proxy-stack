#!/usr/bin/env bash
# snell.sh — Snell proxy management

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF_DIR="/etc/snell"
SNELL_MAIN_CONF="${SNELL_CONF_DIR}/users/snell-main.conf"
SNELL_SERVICE="snell"
SNELL_INSTALLER="https://raw.githubusercontent.com/jinqians/snell/main/snell.sh"
# musl (Alpine): the official build cannot start there, so Snell runs in the
# upstream image, which carries its own glibc runtime (see _snell_docker_install).
SNELL_IMAGE="jinqians/snell-server:v5"
SNELL_CONTAINER="psm-snell"

# Docker mode = the OpenRC service runs the snell-server image, not a host binary.
_snell_is_docker() {
    [[ -f "/etc/init.d/${SNELL_SERVICE}" ]] && grep -q 'jinqians/snell-server' "/etc/init.d/${SNELL_SERVICE}"
}
_snell_installed() { [[ -f "$SNELL_BIN" ]] || _snell_is_docker; }

# ── Dependency check ──────────────────────────────────────────────────────────
_snell_check_deps() {
    ensure_pkg_deps curl unzip jq
    _snell_installed && return 0
    log_warn "$(t snell.not_installed)"
    ask_yn "$(t snell.ask_install)" Y \
        && snell_install \
        || { log_error "$(t snell.need)"; return 1; }
}

# ── Install ───────────────────────────────────────────────────────────────────
snell_install() {
    if ! _uses_systemd; then
        if is_musl; then _snell_docker_install install; else _snell_native_install install; fi
        return
    fi
    log_step "$(t snell.downloading_install)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl "${PSM_DL[@]}" -fsSL "$SNELL_INSTALLER" -o "$tmp"; then
        log_error "$(t snell.download_install_fail)"
        rm -f "$tmp"
        return 1
    fi
    log_step "$(t snell.running_install)"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    # rc != 0 通常是 snell-server 首次启动失败（二进制兼容性问题），
    # 配置文件已写入，不中断 PSM 菜单，改为提示诊断。
    if (( rc != 0 )); then
        log_warn "$(t snell.install_rc "$rc")"
    else
        log_ok "$(t snell.install_done)"
    fi
    return 0
}

# ── Native install (no systemd, e.g. Alpine/OpenRC) ──────────────────────────
# The upstream snell.sh only writes systemd units, so on OpenRC we fetch the
# official snell-server directly, write the same snell-main.conf layout the
# upstream script writes (so show/uninstall/traffic handle both alike) and add
# an OpenRC service. `update` swaps the binary and keeps the config.
#
# Not on musl (Alpine): the official build is a packed static-pie that `file`
# reports as statically linked, yet it will not start there — exec fails
# (exit 127), and with gcompat it is "not a valid dynamic program". Tested on
# Alpine 3.22. Snell on Alpine goes through sing-box (v5/v6) or mihomo (v4/v5).
SNELL_NATIVE_FALLBACK="v5.0.1"   # used only when the release notes are unreachable
SNELL_RELEASE_NOTES="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"

# Latest stable v5 from the official release notes. Download links look like
# snell-server-v5.0.1-linux-amd64.zip; betas (v5.0.2b1-linux…) don't match.
_snell_latest_v5() {
    local v
    v=$(curl "${PSM_DL[@]}" -fsSL --max-time 15 "$SNELL_RELEASE_NOTES" 2>/dev/null \
        | grep -oE 'snell-server-v5\.[0-9]+\.[0-9]+-linux' \
        | sed -e 's/^snell-server-//' -e 's/-linux$//' | sort -uV | tail -1)
    printf '%s' "${v:-$SNELL_NATIVE_FALLBACK}"
}

_snell_native_install() {
    local mode="${1:-install}"
    is_musl && { log_error "$(t common.native.snell_musl)"; return 1; }
    ensure_pkg_deps curl unzip openssl
    require_cmd curl unzip openssl

    local zarch
    case "$(get_arch)" in
        amd64) zarch="amd64" ;;
        arm64) zarch="aarch64" ;;
        arm32) zarch="armv7l" ;;
    esac
    local ver; ver=$(_snell_latest_v5)
    log_step "$(t common.native.installing Snell "$ver")"

    local url="https://dl.nssurge.com/snell/snell-server-${ver}-linux-${zarch}.zip"
    local tmp; tmp=$(mktemp -d)
    if ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/snell.zip" "$url" \
        || ! unzip -qo "$tmp/snell.zip" -d "$tmp" \
        || [[ ! -f "$tmp/snell-server" ]]; then
        rm -rf "$tmp"
        log_error "$(t common.native.download_fail "$url")"
        return 1
    fi
    install -m 755 "$tmp/snell-server" "$SNELL_BIN"
    rm -rf "$tmp"

    [[ "$mode" == "install" || ! -f "$SNELL_MAIN_CONF" ]] && _snell_write_default_conf
    psm_write_openrc_service "$SNELL_SERVICE" "Snell Server" "$SNELL_BIN" "-c $SNELL_MAIN_CONF" || return 1
    _snell_start_and_report "$mode"
}

# The same snell-main.conf layout the upstream script writes, so show /
# uninstall / traffic handle every install method alike.
_snell_write_default_conf() {
    mkdir -p "$(dirname "$SNELL_MAIN_CONF")"
    local listen="0.0.0.0" port psk dns
    [[ -s /proc/net/if_inet6 ]] && listen="::0"
    port=$(( RANDOM % 40000 + 20000 ))
    psk=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd, -)
    {
        echo "#version-choice = v5"
        echo "[snell-server]"
        echo "listen = ${listen}:${port}"
        echo "psk = ${psk}"
        echo "ipv6 = true"
        echo "dns = ${dns:-1.1.1.1,8.8.8.8}"
    } > "$SNELL_MAIN_CONF"
    chmod 600 "$SNELL_MAIN_CONF"
}

# Start the OpenRC service and only report success once the port is really
# listening (a process alone is not proof: a container can still be starting,
# or a crashing child can be caught between two respawns).
_snell_start_and_report() {
    local mode="$1" p i
    p=$(awk -F: '/^listen/ { gsub(/[^0-9]/,"",$NF); print $NF; exit }' "$SNELL_MAIN_CONF")
    svc_enable "$SNELL_SERVICE" || true
    svc_restart "$SNELL_SERVICE" >/dev/null 2>&1 || true
    for i in $(seq 1 20); do
        ss -Hltn "sport = :${p}" 2>/dev/null | grep -q . && break
        sleep 1
    done
    if ! svc_is_active "$SNELL_SERVICE" || ! ss -Hltn "sport = :${p}" 2>/dev/null | grep -q .; then
        log_error "$(t common.native.start_fail Snell)"
        svc_log_tail "$SNELL_SERVICE" 15 >&2
        return 1
    fi
    declare -f firewall_open_port &>/dev/null && firewall_open_port "$p" both || true
    log_ok "$(t snell.install_done)"
    [[ "$mode" == "install" ]] && snell_show_config
    return 0
}

# ── Docker install (musl / Alpine) ───────────────────────────────────────────
# The upstream project's own answer for Alpine 3.19+ (where its glibc shim no
# longer works) is its Docker image. PSM's snell-main.conf is mounted over the
# image's /etc/snell/snell-server.conf — the entrypoint keeps an existing file —
# with host networking, so the port, firewall rule and traffic counters are the
# host's own. supervise-daemon keeps `docker run` in the foreground, so status,
# restart, logs and crash detection go through the same OpenRC service as the
# native install.
_snell_docker_install() {
    local mode="${1:-install}" i
    log_info "$(t snell.docker.why)"
    if ! command -v docker &>/dev/null; then
        ask_yn "$(t snell.docker.ask_install)" Y || { log_error "$(t common.native.snell_musl)"; return 1; }
        source "$LIB_DIR/docker.sh"
        docker_install || return 1
    fi
    svc_is_active docker || svc_start docker >/dev/null 2>&1 || true
    for i in $(seq 1 30); do docker info &>/dev/null && break; sleep 1; done
    docker info &>/dev/null || { log_error "$(t snell.docker.daemon_down)"; return 1; }

    log_step "$(t snell.docker.pulling "$SNELL_IMAGE")"
    docker pull -q "$SNELL_IMAGE" >/dev/null || { log_error "$(t snell.docker.pull_fail "$SNELL_IMAGE")"; return 1; }
    [[ "$mode" == "install" || ! -f "$SNELL_MAIN_CONF" ]] && _snell_write_default_conf
    _snell_write_docker_service || return 1
    _snell_start_and_report "$mode"
}

_snell_write_docker_service() {
    _uses_openrc || { log_error "$(t common.err.need_init "$SNELL_SERVICE")"; return 1; }
    local docker_bin; docker_bin=$(command -v docker)
    cat > "/etc/init.d/${SNELL_SERVICE}" <<EOF
#!/sbin/openrc-run
# Managed by PSM — Snell in the ${SNELL_IMAGE} image (the official build cannot run on musl)
description="Snell Server (Docker)"
command="${docker_bin}"
command_args="run --rm --name ${SNELL_CONTAINER} --network host -e SNELL_VER=v5 -e SNELL_IP_LOOKUP=0 -v ${SNELL_MAIN_CONF}:/etc/snell/snell-server.conf:ro ${SNELL_IMAGE}"
pidfile="/run/${SNELL_SERVICE}.pid"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay 5"
output_log="$(_svc_log_file "$SNELL_SERVICE")"
error_log="$(_svc_log_file "$SNELL_SERVICE")"

depend() {
    need docker
    after firewall
}

start_pre() {
    checkpath -d -m 0755 /var/log/psm
    ${docker_bin} rm -f ${SNELL_CONTAINER} >/dev/null 2>&1 || true
}

stop_post() {
    ${docker_bin} rm -f ${SNELL_CONTAINER} >/dev/null 2>&1 || true
}
EOF
    chmod 755 "/etc/init.d/${SNELL_SERVICE}"
}

# ── Show config / Surge URI ───────────────────────────────────────────────────
snell_show_config() {
    [[ -f "$SNELL_MAIN_CONF" ]] || { log_error "$(t snell.conf_missing "$SNELL_MAIN_CONF")"; return 1; }

    local port psk ipv6 dns
    port=$(awk -F: '/^listen/ { gsub(/[^0-9]/,"",$NF); print $NF; exit }' "$SNELL_MAIN_CONF" || true)
    psk=$(grep  -E '^psk'    "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)
    ipv6=$(grep -E '^ipv6'   "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)
    dns=$(grep  -E '^dns'    "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)

    local ip; ip=$(get_ipv4)

    local version=4
    if [[ -f "$SNELL_BIN" ]]; then
        local vout; vout=$("$SNELL_BIN" --v 2>&1 || true)
        echo "$vout" | grep -q "v6" && version=6
        echo "$vout" | grep -q "v5" && version=5
    fi
    _snell_is_docker && version=5

    echo -e "\n${BOLD}${GREEN}── $(t snell.config_title) ──${NC}"
    printf "  %-12s %s\n" "$(t snell.lbl_server)"  "$ip"
    printf "  %-12s %s\n" "$(t snell.lbl_port)"    "$port"
    printf "  %-12s %s\n" "PSK:"     "$psk"
    printf "  %-12s %s\n" "IPv6:"    "${ipv6:-true}"
    printf "  %-12s %s\n" "DNS:"     "${dns:-$(t snell.lbl_dns_default)}"
    printf "  %-12s %s\n" "$(t snell.lbl_version)" "$version"

    echo -e "\n${BOLD}$(t snell.surge_format)${NC}"
    echo "  PSM-Snell = snell, ${ip}, ${port}, psk = ${psk}, version = ${version}, reuse = true, tfo = true"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
# On systemd the upstream snell.sh installs Snell, and what it may have added
# goes too, as its own uninstall does: the binary of each channel (v4 / v5 /
# v6) and their backups, its per-user services (snell-<port>), the ShadowTLS
# in front of them, its rule-based routing (sing-box as snell-router, with its
# interception rules) and its egress control (a network namespace). The ports
# the Snell services listened on are closed in the firewall.

# snell.sh's rule-based routing: stopped, its interception rules taken down (by
# its own script, and by hand for a half-removed install), removed with the
# drop-ins that made root-run Snell services run as the snell user
_snell_remove_router() {
    local unit=/etc/systemd/system/snell-router.service net=/usr/local/bin/snell-router-net d
    if [[ -f "$unit" ]]; then
        systemctl stop snell-router 2>/dev/null || true
        systemctl disable snell-router 2>/dev/null || true
    fi
    [[ -x "$net" ]] && { "$net" down >/dev/null 2>&1 || true; }
    if command -v nft &>/dev/null; then nft delete table inet snell_router 2>/dev/null || true; fi
    if command -v ip &>/dev/null; then
        ip rule del fwmark 0x736e lookup 7391 pref 7391 2>/dev/null || true
        ip -6 rule del fwmark 0x736e lookup 7391 pref 7391 2>/dev/null || true
        ip route flush table 7391 2>/dev/null || true
        ip -6 route flush table 7391 2>/dev/null || true
    fi
    for d in /etc/systemd/system/snell*.service.d; do
        [[ -f "$d/snell-router.conf" ]] || continue
        rm -f "$d/snell-router.conf"
        rmdir "$d" 2>/dev/null || true
    done
    rm -f "$unit" "$net" /usr/local/bin/snell-router
    rm -rf /etc/snell-router
}

# snell.sh's egress control: the namespace, its veth pair, NAT and FORWARD rules
_snell_remove_egress() {
    local setup=/usr/local/bin/snell-netns-setup.sh ns="snell-egress" n rule
    if [[ -f "$setup" ]]; then
        n=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "$setup" | head -n 1)
        [[ -n "$n" ]] && ns="$n"
    fi
    if command -v ip &>/dev/null; then
        ip netns del "$ns" 2>/dev/null || true
        ip link del veth-host 2>/dev/null || true
    fi
    rm -rf "/etc/netns/${ns}" "$setup"
    if command -v nft &>/dev/null; then
        nft delete table ip snell_nat 2>/dev/null || true
        nft delete table inet snell_filter 2>/dev/null || true
    fi
    if command -v iptables &>/dev/null; then
        while rule=$(iptables -S FORWARD 2>/dev/null | grep -- '-A FORWARD.*veth-host' | head -n 1) && [[ -n "$rule" ]]; do
            # shellcheck disable=SC2086 # the rule's own words
            iptables ${rule/-A /-D } 2>/dev/null || break
        done
    fi
}

# a port Snell took, closed: in the enforcing firewall, and the iptables ACCEPT
# rules snell.sh adds even where iptables enforces nothing (they would let the
# port in once it did, and they are saved for the next boot)
_snell_iptables_dropped=0
_snell_close_port() {   # <port> <tcp|udp>
    local t
    firewall_close_port "$1" "$2" >/dev/null 2>&1 || true
    for t in iptables ip6tables; do
        command -v "$t" &>/dev/null || continue
        while "$t" -D INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null; do _snell_iptables_dropped=1; done
    done
}

snell_uninstall() {
    ask_yn "$(t snell.ask_uninstall)" N || return 0
    _snell_iptables_dropped=0
    declare -f firewall_close_port &>/dev/null || source "$LIB_DIR/system.sh"
    _snell_remove_router

    # every Snell service (the main one, snell.sh's snell-<port>) and the ShadowTLS
    # in front of them, with the ports they took (read before the configs go)
    local f name port units=(snell snell.socket snell-netns) tcp_ports=() both_ports=()
    for f in "$SNELL_CONF_DIR"/users/*.conf "$SNELL_CONF_DIR"/snell-server.conf; do
        [[ -f "$f" ]] || continue
        port=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$f" | head -n 1)
        [[ -n "$port" ]] && both_ports+=("$port")
    done
    for f in /etc/systemd/system/snell-*.service /etc/systemd/system/shadowtls-snell-*.service; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .service)
        if [[ "$name" == shadowtls-snell-* ]]; then
            port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$f" | head -n 1)
            [[ -n "$port" ]] && tcp_ports+=("$port")
        elif [[ ! "$name" =~ ^snell-[0-9]+$ ]]; then
            continue   # snell-netns, snell-router: not a per-user service
        fi
        units+=("$name")
    done
    systemctl stop "${units[@]}" 2>/dev/null || true
    systemctl disable "${units[@]}" 2>/dev/null || true
    psm_remove_openrc_service "$SNELL_SERVICE"
    if command -v docker &>/dev/null; then
        docker rm -f "$SNELL_CONTAINER" &>/dev/null || true
        docker rmi "$SNELL_IMAGE" &>/dev/null || true
    fi
    _snell_remove_egress

    rm -f /usr/local/bin/snell-server /usr/local/bin/snell \
          /usr/local/bin/snell-server-v4 /usr/local/bin/snell-server-v5 /usr/local/bin/snell-server-v6 \
          /usr/local/bin/snell-server-v[456].bak.*
    for name in "${units[@]}"; do
        if [[ "$name" == *.socket ]]; then rm -f "/etc/systemd/system/${name}"; else rm -f "/etc/systemd/system/${name}.service"; fi
    done
    rm -f /lib/systemd/system/snell.service /usr/lib/systemd/system-preset/90-snell.preset
    # the ShadowTLS binary, once no ShadowTLS service is left
    compgen -G '/etc/systemd/system/shadowtls-*.service' >/dev/null || rm -f /usr/local/bin/shadow-tls
    rm -rf "$SNELL_CONF_DIR"
    svc_daemon_reload
    for port in "${both_ports[@]}"; do
        _snell_close_port "$port" tcp
        _snell_close_port "$port" udp
    done
    for port in "${tcp_ports[@]}"; do _snell_close_port "$port" tcp; done
    (( _snell_iptables_dropped )) && psm_iptables_persist
    # Clean up traffic monitoring state (port is stored in state.json, no need to read config first)
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "snell"
    fi
    log_ok "$(t snell.uninstalled)"
}

# ── Update ────────────────────────────────────────────────────────────────────
snell_update() {
    if ! _uses_systemd; then
        if is_musl || _snell_is_docker; then _snell_docker_install update; else _snell_native_install update; fi
        return
    fi
    log_step "$(t snell.downloading_update)"
    local tmp; tmp=$(mktemp --suffix=.sh)
    if ! curl "${PSM_DL[@]}" -fsSL "$SNELL_INSTALLER" -o "$tmp"; then
        log_error "$(t snell.download_update_fail)"; rm -f "$tmp"; return 1
    fi
    bash "$tmp"; local rc=$?
    rm -f "$tmp"
    (( rc != 0 )) && log_warn "$(t snell.update_rc "$rc")" || log_ok "$(t snell.update_done)"
    return 0
}

# ── Diagnose crash ────────────────────────────────────────────────────────────
snell_diagnose() {
    echo -e "\n${BOLD}${BLUE}══ $(t snell.diagnose_title) ══════════════════════════════${NC}"

    if _snell_is_docker; then
        echo -e "\n${BOLD}▶ Docker${NC}"
        docker ps -a --filter "name=^${SNELL_CONTAINER}$" --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>&1
        docker image inspect -f '{{.Id}}  {{.Created}}' "$SNELL_IMAGE" 2>&1 | cut -c1-100
        echo -e "\n${BOLD}▶ $(t snell.diag_config)${NC}"
        cat "$SNELL_MAIN_CONF" 2>/dev/null || echo "  $(t snell.conf_missing "$SNELL_MAIN_CONF")"
        echo -e "\n${BOLD}▶ $(t snell.menu.logs)${NC}"
        svc_log_tail "$SNELL_SERVICE" 20
        echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════${NC}"
        return 0
    fi

    echo -e "\n${BOLD}▶ $(t snell.diag_binary)${NC}"
    file "$SNELL_BIN" 2>/dev/null || echo "$(t snell.diag_binary_fail)"

    echo -e "\n${BOLD}▶ $(t snell.diag_libs)${NC}"
    ldd "$SNELL_BIN" 2>/dev/null || echo "$(t snell.diag_ldd_fail)"

    echo -e "\n${BOLD}▶ $(t snell.diag_glibc)${NC}"
    ldd --version 2>/dev/null | head -1

    echo -e "\n${BOLD}▶ $(t snell.diag_arch)${NC}"
    uname -m

    echo -e "\n${BOLD}▶ $(t snell.diag_config)${NC}"
    if [[ -f "$SNELL_MAIN_CONF" ]]; then
        cat "$SNELL_MAIN_CONF"
    else
        echo "  $(t snell.conf_missing "$SNELL_MAIN_CONF")"
    fi

    echo -e "\n${BOLD}▶ $(t snell.diag_manual)${NC}"
    echo "$(t snell.diag_manual_note)"
    "$SNELL_BIN" --help 2>&1 | head -5 || true
    echo ""

    echo -e "${BOLD}$(t snell.diag_reasons)${NC}"
    echo "$(t snell.diag_reason1)"
    echo "$(t snell.diag_reason2)"
    echo "$(t snell.diag_reason3)"
    echo "$(t snell.diag_reason4)"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════${NC}"
}

# ── Logs ──────────────────────────────────────────────────────────────────────
snell_logs() {
    svc_logs "$SNELL_SERVICE"
}

# ── List helper (called by _view_all_nodes) ───────────────────────────────────
_snell_show_node_list() {
    echo -e "\n${BOLD}$(t snell.list_header)${NC}"
    if [[ ! -f "$SNELL_MAIN_CONF" ]]; then
        echo "  $(t common.not_configured)"
        return
    fi
    local port; port=$(awk -F: '/^listen/ { gsub(/[^0-9]/,"",$NF); print $NF; exit }' "$SNELL_MAIN_CONF" || true)
    local psk;  psk=$(grep -E '^psk' "$SNELL_MAIN_CONF" | awk -F'= ' '{print $2}' | tr -d '[:space:]' || true)
    local ip;   ip=$(get_ipv4 2>/dev/null || echo "?")
    printf "$(t snell.list_line)" "$ip" "$port" "$psk"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
snell_menu() {
    _snell_check_deps || return
    while true; do
        show_menu "$(t snell.menu.title)" \
            "$(t snell.menu.install)" \
            "$(t snell.menu.show_config)" \
            "$(t snell.menu.status)" \
            "$(t snell.menu.restart)" \
            "$(t snell.menu.logs)" \
            "$(t snell.menu.update)" \
            "$(t snell.menu.uninstall)" \
            "$(t snell.menu.diagnose)"

        case "$MENU_CHOICE" in
            1) snell_install;                                          press_enter ;;
            2) snell_show_config;                                      press_enter ;;
            3) svc_status "$SNELL_SERVICE";                            press_enter ;;
            4) svc_restart "$SNELL_SERVICE"; log_ok "$(t snell.restarted)"; press_enter ;;
            5) snell_logs ;;
            6) snell_update;                                           press_enter ;;
            7) snell_uninstall;                                        press_enter ;;
            8) snell_diagnose;                                         press_enter ;;
            0) return ;;
        esac
    done
}
