#!/usr/bin/env bash
# standalone_cli.sh — psm standalone: the standalone Snell and ss-rust servers,
# without questions (for scripts and the PSM panel)
#
#   psm standalone install snell  --port PORT [--psk PSK] [--version 4|5|6] [--json]
#   psm standalone install ss2022 --port PORT [--password KEY] [--method METHOD] [--json]
#   psm standalone show    snell|ss2022 [--json]
#   psm standalone export  snell|ss2022 [--server HOST] [--name NAME] [--format uri|surge|singbox]
#   psm standalone remove  snell|ss2022 --yes [--json]
#
# The official snell-server (v4, v5 or v6; v6 is still a beta upstream) and the
# shadowsocks-rust build run as a systemd or OpenRC service with the config
# files the menus use (/etc/snell/users/snell-main.conf, /etc/ss-rust/config.json),
# so the menus, traffic metering (tags "snell" and "ss2022") and subscription
# exports see them as before. install replaces what is running (a new port or
# key); the menus' own installs are unchanged.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/snell.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/ssrust.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/system.sh"   # firewall_open_port

SNELL_BUILD_FILE="$SNELL_CONF_DIR/psm-build"

_sa_err() { printf 'psm standalone: %s\n' "$*" >&2; }

_sa_usage() {
    cat <<'EOF'
Usage:
  psm standalone install snell  --port PORT [--psk PSK] [--version 4|5|6] [--json]
  psm standalone install ss2022 --port PORT [--password KEY] [--method METHOD] [--json]
  psm standalone show    snell|ss2022 [--json]
  psm standalone export  snell|ss2022 [--server HOST] [--name NAME] [--format uri|surge|singbox]
  psm standalone remove  snell|ss2022 --yes [--json]

ss2022 methods: 2022-blake3-aes-128-gcm (default), 2022-blake3-aes-256-gcm,
2022-blake3-chacha20-poly1305. --password is the base64 key (16 bytes for
aes-128, 32 for the others); PSK and key are generated when not given.
EOF
}

_sa_proto() {
    case "${1:-}" in
        snell) echo snell ;;
        ss2022|ss-rust|ssrust) echo ss2022 ;;
        *) return 1 ;;
    esac
}

_sa_key_len() { case "$1" in 2022-blake3-aes-128-gcm) echo 16 ;; *) echo 32 ;; esac; }

# A TCP socket listens on this port (from /proc, no ss/netstat needed).
_sa_port_listening() {
    local hex; hex=$(printf '%04X' "$1")
    awk -v p=":${hex}\$" '$4 == "0A" && toupper($2) ~ p { found = 1 } END { exit !found }' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# ── Snell builds ──────────────────────────────────────────────────────────────
_sa_snell_fallback() { case "$1" in 4) echo v4.1.1 ;; 5) echo v5.0.1 ;; 6) echo v6.0.0rc2 ;; esac; }

# The newest official build of a Snell major version, from the release notes.
# v6 has only betas and release candidates so far: the newest of those until a
# final v6 is out.
_sa_snell_latest() {
    local major="$1" all final pre
    all=$(curl "${PSM_DL[@]}" -fsSL --max-time 15 "$SNELL_RELEASE_NOTES" 2>/dev/null \
          | grep -oE "snell-server-v${major}\.[0-9]+\.[0-9]+((b|rc)[0-9]*)?-linux" \
          | sed -e 's/^snell-server-//' -e 's/-linux$//' | sort -uV || true)
    final=$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$all" | tail -1 || true)
    pre=$(printf '%s\n' "$all" | sed '/^$/d' | tail -1)
    printf '%s' "${final:-${pre:-$(_sa_snell_fallback "$major")}}"
}

# ── services ──────────────────────────────────────────────────────────────────
_sa_write_service() {   # <name> <description> <binary> <arguments>
    if _uses_systemd; then
        cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$2 (managed by PSM)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$3 $4
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        psm_write_openrc_service "$1" "$2" "$3" "$4"
    fi
}

# Start (or restart) and succeed only once the port really listens.
_sa_start() {   # <service> <port> <label>
    local i
    svc_enable "$1" || true
    svc_restart "$1" >/dev/null 2>&1 || true
    for i in $(seq 1 20); do
        if _sa_port_listening "$2" && svc_is_active "$1"; then
            firewall_open_port "$2" both >/dev/null 2>&1 || true
            return 0
        fi
        sleep 1
    done
    _sa_err "$3 did not start on port $2"
    svc_log_tail "$1" 15 >&2
    return 1
}

# ── install ───────────────────────────────────────────────────────────────────
_sa_install_snell() {   # <port> <psk> <major>
    local port="$1" psk="$2" major="$3" build zarch url tmp listen dns
    if is_musl; then
        _sa_err 'the official snell-server does not run on musl (Alpine); run Snell on sing-box or mihomo instead'
        return 1
    fi
    ensure_pkg_deps curl unzip openssl >&2
    case "$(get_arch)" in
        amd64) zarch=amd64 ;; arm64) zarch=aarch64 ;; arm32) zarch=armv7l ;;
        *) _sa_err "unsupported architecture: $(uname -m)"; return 1 ;;
    esac
    build=$(_sa_snell_latest "$major")
    url="https://dl.nssurge.com/snell/snell-server-${build}-linux-${zarch}.zip"
    tmp=$(mktemp -d)
    if ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/snell.zip" "$url" \
        || ! unzip -qo "$tmp/snell.zip" -d "$tmp" >/dev/null \
        || [[ ! -f "$tmp/snell-server" ]]; then
        rm -rf "$tmp"
        _sa_err "download failed: $url"
        return 1
    fi
    svc_stop "$SNELL_SERVICE" >/dev/null 2>&1 || true
    install -m 755 "$tmp/snell-server" "$SNELL_BIN"
    rm -rf "$tmp"

    mkdir -p "$(dirname "$SNELL_MAIN_CONF")"
    listen="0.0.0.0"
    [[ -s /proc/net/if_inet6 ]] && listen="::0"
    dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd, - || true)
    {
        echo "#version-choice = v${major}"
        echo "[snell-server]"
        echo "listen = ${listen}:${port}"
        echo "psk = ${psk}"
        echo "ipv6 = true"
        [[ "$major" == 4 ]] || echo "dns = ${dns:-1.1.1.1,8.8.8.8}"
    } > "$SNELL_MAIN_CONF"
    chmod 600 "$SNELL_MAIN_CONF"
    printf '%s\n' "$build" > "$SNELL_BUILD_FILE"
    _sa_write_service "$SNELL_SERVICE" "Snell Server" "$SNELL_BIN" "-c $SNELL_MAIN_CONF" || return 1
    _sa_start "$SNELL_SERVICE" "$port" snell-server
}

_sa_install_ss() {   # <port> <password> <method>
    local port="$1" password="$2" method="$3" listen
    ensure_pkg_deps curl jq tar xz openssl >&2
    svc_stop "$SS_SERVICE" >/dev/null 2>&1 || true
    printf 'Installing ss-rust (shadowsocks-rust, latest release)...\n' >&2
    _ssrust_fetch_binary quiet >/dev/null || return 1
    listen="0.0.0.0"
    [[ -s /proc/net/if_inet6 ]] && listen="::"
    mkdir -p "$(dirname "$SS_CONF")"
    jq -n --arg server "$listen" --argjson port "$port" --arg password "$password" --arg method "$method" \
        '{server: $server, server_port: $port, password: $password, method: $method,
          fast_open: false, mode: "tcp_and_udp", user: "nobody", timeout: 300}' > "$SS_CONF"
    chmod 600 "$SS_CONF"
    _sa_write_service "$SS_SERVICE" "Shadowsocks Rust" "$SS_BIN" "-c $SS_CONF" || return 1
    # SS2022 refuses clients whose clock is more than 30 s off: keep ours synced.
    { pkg_install chrony && _svc_enable_now chronyd; } >/dev/null 2>&1 || true
    _sa_start "$SS_SERVICE" "$port" ss-rust
}

# ── show / export / remove ────────────────────────────────────────────────────
_sa_show_json() {   # <proto> → one JSON object
    local installed=false active=false port="" secret="" extra=""
    if [[ "$1" == snell ]]; then
        [[ -x "$SNELL_BIN" ]] && installed=true
        svc_is_active "$SNELL_SERVICE" 2>/dev/null && active=true
        local major="" build=""
        if [[ -f "$SNELL_MAIN_CONF" ]]; then
            port=$(awk -F: '/^listen/ { gsub(/[^0-9]/, "", $NF); print $NF; exit }' "$SNELL_MAIN_CONF" || true)
            secret=$(awk -F'=' '/^psk/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$SNELL_MAIN_CONF" || true)
            major=$(sed -n 's/^#version-choice = v\([0-9]\).*/\1/p' "$SNELL_MAIN_CONF" | head -1 || true)
        fi
        build=$(cat "$SNELL_BUILD_FILE" 2>/dev/null || true)
        jq -nc --argjson i "$installed" --argjson a "$active" --arg p "$port" --arg k "$secret" \
               --arg v "${major:-5}" --arg b "$build" \
            '{protocol: "snell", traffic_tag: "snell", installed: $i, active: $a, configured: ($p != ""),
              port: ($p | tonumber? // null), psk: $k, version: $v, build: $b}'
    else
        [[ -x "$SS_BIN" ]] && installed=true
        svc_is_active "$SS_SERVICE" 2>/dev/null && active=true
        if [[ -f "$SS_CONF" ]]; then
            extra=$(jq -c '{port: .server_port, password: .password, method: .method}' "$SS_CONF" 2>/dev/null || true)
        fi
        jq -nc --argjson i "$installed" --argjson a "$active" --argjson e "${extra:-{\}}" \
            '{protocol: "ss2022", traffic_tag: "ss2022", installed: $i, active: $a, configured: ($e.port != null),
              port: ($e.port // null), password: ($e.password // ""), method: ($e.method // "")}'
    fi
}

_sa_show() {   # <proto> <json 0|1>
    local s; s=$(_sa_show_json "$1")
    if (( $2 )); then printf '%s\n' "$s"; return 0; fi
    jq -r 'to_entries[] | "\(.key): \(.value)"' <<<"$s"
}

_sa_export() {   # <proto> <server> <name> <format>
    local proto="$1" server="$2" name="$3" format="$4" s host port
    s=$(_sa_show_json "$proto")
    [[ "$(jq -r '.configured' <<<"$s")" == true ]] || { _sa_err "$proto is not installed"; return 1; }
    [[ -n "$server" ]] || server=$(get_ipv4 2>/dev/null || true)
    [[ -n "$server" ]] || { _sa_err 'could not determine the public address; pass --server'; return 1; }
    host="$server"
    [[ "$server" == *:* ]] && host="[$server]"
    port=$(jq -r '.port' <<<"$s")
    if [[ "$proto" == snell ]]; then
        [[ -n "$name" ]] || name="$(psm_node_label Snell)"
        case "${format:-surge}" in
            surge) printf '%s = snell, %s, %s, psk=%s, version=%s\n' "$name" "$server" "$port" \
                       "$(jq -r '.psk' <<<"$s")" "$(jq -r '.version' <<<"$s")" ;;
            *) _sa_err 'Snell has no standard URI or sing-box outbound; use --format surge'; return 2 ;;
        esac
        return 0
    fi
    [[ -n "$name" ]] || name="$(psm_node_label ss-rust)"
    local method password
    method=$(jq -r '.method' <<<"$s"); password=$(jq -r '.password' <<<"$s")
    case "${format:-uri}" in
        uri)
            printf 'ss://%s@%s:%s#%s\n' \
                "$(printf '%s:%s' "$method" "$password" | openssl base64 -A | tr '+/' '-_' | tr -d '=')" \
                "$host" "$port" "$(jq -nr --arg v "$name" '$v | @uri')" ;;
        surge)
            printf '%s = ss, %s, %s, encrypt-method=%s, password=%s\n' "$name" "$server" "$port" "$method" "$password" ;;
        singbox|sing-box)
            jq -nc --arg t "$name" --arg s "$server" --argjson p "$port" --arg m "$method" --arg pw "$password" \
                '{type: "shadowsocks", tag: $t, server: $s, server_port: $p, method: $m, password: $pw}' ;;
        *) _sa_err "unsupported format: $format"; return 2 ;;
    esac
}

_sa_remove() {   # <proto>
    # the menus' uninstall (it also removes the traffic metering); it asks once
    if [[ "$1" == snell ]]; then
        snell_uninstall <<<"y" >&2 || true
        rm -f "$SNELL_BUILD_FILE"
    else
        ssrust_uninstall <<<"y" >&2 || true
    fi
    [[ ! -x "$SNELL_BIN" || "$1" != snell ]] && [[ ! -x "$SS_BIN" || "$1" != ss2022 ]]
}

# ── entry point ───────────────────────────────────────────────────────────────
psm_standalone_cli() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        install|show|export|remove|uninstall) ;;
        help|--help|-h) _sa_usage; return 0 ;;
        *) _sa_usage >&2; return 2 ;;
    esac
    local proto
    proto=$(_sa_proto "${1:-}") || { _sa_err 'protocol: snell or ss2022'; return 2; }
    shift
    local port="" psk="" version="5" password="" method="2022-blake3-aes-128-gcm" server="" name="" format="" json=0 yes=0
    while (( $# )); do
        case "$1" in
            --port) port="${2:-}"; shift 2 ;;
            --psk) psk="${2:-}"; shift 2 ;;
            --version) version="${2:-}"; shift 2 ;;
            --password) password="${2:-}"; shift 2 ;;
            --method) method="${2:-}"; shift 2 ;;
            --server) server="${2:-}"; shift 2 ;;
            --name) name="${2:-}"; shift 2 ;;
            --format) format="${2:-}"; shift 2 ;;
            --json) json=1; shift ;;
            --yes|-y) yes=1; shift ;;
            *) _sa_err "unknown option: $1"; return 2 ;;
        esac
    done

    case "$cmd" in
        show) _sa_show "$proto" "$json" ;;
        export) _sa_export "$proto" "$server" "$name" "$format" ;;
        remove|uninstall)
            (( yes )) || { _sa_err 'remove needs --yes'; return 2; }
            [[ $EUID -eq 0 ]] || { _sa_err 'run as root'; return 1; }
            _sa_remove "$proto" || { _sa_err "$proto is still installed"; return 1; }
            if (( json )); then jq -nc --arg p "$proto" '{protocol: $p, status: "removed"}'; else echo "$proto removed"; fi
            ;;
        install)
            [[ $EUID -eq 0 ]] || { _sa_err 'run as root'; return 1; }
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                _sa_err '--port: 1-65535'; return 2
            fi
            local current
            current=$(_sa_show_json "$proto" | jq -r '.port // empty')
            if [[ "$current" != "$port" ]] && _sa_port_listening "$port"; then
                _sa_err "port $port is already in use"; return 1
            fi
            if [[ "$proto" == snell ]]; then
                [[ "$version" =~ ^[456]$ ]] || { _sa_err '--version: 4, 5 or 6'; return 2; }
                if [[ -z "$psk" ]]; then
                    psk=$(openssl rand -hex 16)
                elif ! [[ "$psk" =~ ^[A-Za-z0-9+/=_-]{8,128}$ ]]; then
                    _sa_err '--psk: 8-128 letters, digits and + / = _ -'; return 2
                fi
                _sa_install_snell "$port" "$psk" "$version" || return 1
            else
                case "$method" in
                    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;;
                    *) _sa_err "--method: not an SS2022 method: $method"; return 2 ;;
                esac
                local len; len=$(_sa_key_len "$method")
                if [[ -z "$password" ]]; then
                    password=$(openssl rand -base64 "$len")
                elif [[ "$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c)" -ne "$len" ]]; then
                    _sa_err "--password: the base64 of a $len-byte key for $method"; return 2
                fi
                _sa_install_ss "$port" "$password" "$method" || return 1
            fi
            _sa_show "$proto" "$json"
            ;;
    esac
}
