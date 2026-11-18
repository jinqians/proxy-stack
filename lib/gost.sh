#!/usr/bin/env bash
# gost.sh — gost v3, the second relay engine (psm relay --engine gost).
#
# realm forwards a port, and spreads connections over several targets; gost
# does what realm cannot: health checks and failover between the targets, a
# rate limit, and the encrypted tunnel from an entry machine to an exit machine
# (gost's relay protocol over TLS, multiplexed TLS, WebSocket or multiplexed
# WebSocket over TLS), the exit alone forwarding to the landing side.
#
# Its config is generated from the relay store (config/realm/rules.json, the
# rules of both engines), the way realm's config.toml is. It is installed as
# psm-gost (/usr/local/bin/psm-gost, /etc/psm-gost, service psm-gost), never as
# "gost": relay scripts commonly install gost v2 under that name, with a config
# format of its own, and PSM must not take it over.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# the rule store is realm's (config/realm/rules.json): both engines' rules live there
declare -f _realm_load >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/realm.sh"

GOST_BIN="/usr/local/bin/psm-gost"
GOST_DIR="/etc/psm-gost"
GOST_CFG="$GOST_DIR/config.json"
GOST_SVC="psm-gost"
GOST_SERVICE="/etc/systemd/system/psm-gost.service"
GOST_RELEASES="https://github.com/go-gost/gost/releases"
GOST_FALLBACK_TAG="v3.3.0"
# 3.3.0 brought active probes on a forwarder's targets, which failover needs
GOST_MIN_VERSION="3.3.0"

_gost_err() { printf 'psm relay: %s\n' "$*" >&2; }

gost_version() {   # the installed version (3.3.0), nothing when there is none
    [[ -x "$GOST_BIN" ]] || return 1
    # "gost v3.3.0 (go1.25 linux/amd64)" up to 3.3.0, "gost 3.3.3 (…)" since:
    # without the v nothing was read, and every install ended as "older than 3.3.0"
    "$GOST_BIN" -V 2>/dev/null | sed -n 's/^gost v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -1
}

_gost_new_enough() {
    local v; v=$(gost_version) || return 1
    [[ -n "$v" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$GOST_MIN_VERSION" "$v" | sort -V | head -1)" == "$GOST_MIN_VERSION" ]]
}

# gost itself, without questions, the first time a gost rule needs it (and to
# replace one older than GOST_MIN_VERSION).
gost_install_unattended() {
    _gost_new_enough && return 0
    ensure_pkg_deps curl tar jq >/dev/null 2>&1 || true
    require_cmd curl tar jq || return 1

    local arch garch
    arch=$(get_arch)
    case "$arch" in
        amd64) garch=amd64 ;;
        arm64) garch=arm64 ;;
        arm32) garch=armv7 ;;
        *) _gost_err "gost has no build for $arch"; return 1 ;;
    esac

    local tag; tag=$(gh_latest_tag go-gost/gost)
    [[ "$tag" =~ ^v3\.[0-9]+\.[0-9]+$ ]] || tag="$GOST_FALLBACK_TAG"
    local file="gost_${tag#v}_linux_${garch}.tar.gz"
    local url="${GOST_RELEASES}/download/${tag}/${file}"
    local tmp; tmp=$(mktemp -d) || return 1
    if ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/$file" "$url"; then
        rm -rf "$tmp"; _gost_err "could not download gost: $url"; return 1
    fi
    tar -xzf "$tmp/$file" -C "$tmp" gost 2>/dev/null || tar -xzf "$tmp/$file" -C "$tmp" \
        || { rm -rf "$tmp"; _gost_err "could not unpack $file"; return 1; }
    [[ -f "$tmp/gost" ]] || { rm -rf "$tmp"; _gost_err "$file holds no gost binary"; return 1; }
    install -m 755 "$tmp/gost" "$GOST_BIN"
    rm -rf "$tmp"
    _gost_new_enough || { _gost_err "gost $(gost_version) is older than $GOST_MIN_VERSION"; return 1; }

    mkdir -p "$GOST_DIR"
    _gost_write_service
    svc_daemon_reload
    log_ok "gost $tag installed ($GOST_BIN)" >&2
}

_gost_write_service() {
    if ! _uses_systemd; then
        psm_write_openrc_service "$GOST_SVC" "gost relay service (PSM)" "$GOST_BIN" "-C $GOST_CFG"
        return
    fi
    cat > "$GOST_SERVICE" <<EOF
[Unit]
Description=gost relay service (PSM)
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=${GOST_BIN} -C ${GOST_CFG}

[Install]
WantedBy=multi-user.target
EOF
}

# ── the config, from the rules ───────────────────────────────────────────────
# One gost process carries every gost rule of this machine:
#
#   forward       <tag>-tcp (and <tag>-udp): the port forwarded to the targets
#   tunnel-exit   <tag>-tun: gost's relay protocol over the chosen transport,
#                 with a password; it forwards to its own targets whatever the
#                 entry asks for, so it is no open proxy
#   tunnel-entry  <tag>-tcp (and <tag>-udp) through one chain to the exit
#
# Several targets are chosen by the selector (round, rand, fifo = the first
# healthy one, hash = by client IP); with the probe on, each target is checked
# over TCP every 15 s and one that fails is left out until it answers again,
# so a dead landing costs no client connection. Measured on gost 3.3.0:
#
#   - UDP needs the listener's keepAlive: without it every datagram leaves from
#     a new source port and QUIC (Hysteria2, TUIC) cannot hold a connection;
#   - the relay connector's nodelay (its header sent before the client speaks)
#     loses what the client sends next, on every transport: UDP through the
#     tunnel got nothing back, and SS2022 never connected. It is left off, so
#     a protocol in which the server speaks first (SMTP, FTP, VNC) cannot go
#     through a tunnel; every proxy protocol has the client speak first.
_GOST_JQ='
def hp($h; $p): if ($h | test(":")) and ($h | startswith("[") | not) then "[\($h)]:\($p)" else "\($h):\($p)" end;
def targets: if ((.targets // []) | length) > 0 then .targets else [{host: .remote_host, port: .remote_port}] end;
def strategy: (.strategy // "") | if . == "" then "round" else . end;
# a probe turned off is asked for by name: the // operator stands in for false too
def probe_on: (has("probe") and .probe == false) | not;
def forwarder:
  . as $r | targets as $ts
  | { selector: {strategy: ($r | strategy), maxFails: 1, failTimeout: "30s"},
      nodes: [ $ts | to_entries[] | {name: "\($r.tag)-t\(.key)", addr: hp(.value.host; .value.port)}
               + (if ($r | probe_on) and (($ts | length) > 1)
                  then {probe: {type: "tcp", addr: hp(.value.host; .value.port), interval: "15s", timeout: "5s"}}
                  else {} end) ] };
def limited: if ((.speed_mbps // 0) > 0) then {limiter: "\(.tag)-speed"} else {} end;
def udp_listener: {type: "udp", metadata: {keepAlive: true, ttl: "60s", readBufferSize: 8192}};
def ws: (.transport // "tls") | test("ws");
def ws_meta($keys): [ $keys[] as $k | {key: $k, value: (.["ws_" + $k] // "")} | select(.value != "") ] | from_entries;
def mode: (.mode // "forward") | if . == "" then "forward" else . end;
def dialer:
  { type: (.transport // "tls"),
    tls: (({serverName: (.tls_sni // "")} | with_entries(select(.value != "")))
          + (if (.exit_ca // "") != "" then {caFile: .exit_ca}
             elif (.tls_insecure // false) then {}
             else {secure: true} end)) }
  + (if ws then (ws_meta(["host", "path"]) | if length > 0 then {metadata: .} else {} end) else {} end);
def chain($name):
  . as $r
  | { name: $name,
      hops: [ { name: "\($name)-hop",
                nodes: [ { name: "\($name)-exit", addr: hp($r.remote_host; $r.remote_port),
                           connector: {type: "relay", auth: {username: $r.tag, password: $r.secret}},
                           dialer: ($r | dialer) } ] } ] };

[ .[] | select((.engine // "realm") == "gost") ] as $rules
| { log: {level: "error"},
    services: [ $rules[] | . as $r
      | if mode == "tunnel-exit" then
          { name: "\(.tag)-tun", addr: ":\(.listen_port)",
            handler: {type: "relay", auth: {username: .tag, password: .secret}},
            listener: ({type: (.transport // "tls"), tls: {certFile: .tls_cert, keyFile: .tls_key}}
                       + (if ws then (ws_meta(["path"]) | if length > 0 then {metadata: .} else {} end) else {} end)),
            forwarder: forwarder } + limited
        elif mode == "tunnel-entry" then
          ({ name: "\(.tag)-tcp", addr: ":\(.listen_port)",
             handler: {type: "tcp", chain: "\(.tag)-chain"}, listener: {type: "tcp"} } + limited),
          (if .udp then
            { name: "\(.tag)-udp", addr: ":\(.listen_port)",
              handler: {type: "udp", chain: "\(.tag)-chain"}, listener: udp_listener } + limited
           else empty end)
        else
          ({ name: "\(.tag)-tcp", addr: ":\(.listen_port)", handler: {type: "tcp"}, listener: {type: "tcp"},
             forwarder: forwarder } + limited),
          (if .udp then
            { name: "\(.tag)-udp", addr: ":\(.listen_port)", handler: {type: "udp"}, listener: udp_listener,
              forwarder: forwarder } + limited
           else empty end)
        end ],
    chains: [ $rules[] | select(mode == "tunnel-entry") | chain("\(.tag)-chain") ],
    limiters: [ $rules[] | select((.speed_mbps // 0) > 0)
                | (.speed_mbps * 125000 | floor) as $b
                | {name: "\(.tag)-speed", limits: ["$ \($b)B \($b)B"]} ] }
'

gost_gen_config() {   # <rules json> → the config on stdout
    printf '%s' "$1" | jq "$_GOST_JQ"
}

gost_rule_count() { _realm_load | jq '[.[] | select((.engine // "realm") == "gost")] | length' 2>/dev/null; }

# Write the config and restart gost; stop it when no gost rule is left.
gost_apply() {
    local rules count cfg
    rules=$(_realm_load)
    count=$(printf '%s' "$rules" | jq '[.[] | select((.engine // "realm") == "gost")] | length')
    mkdir -p "$GOST_DIR"
    cfg=$(gost_gen_config "$rules") || { _gost_err "could not build the gost config"; return 1; }
    printf '%s\n' "$cfg" > "$GOST_CFG.tmp" && chmod 600 "$GOST_CFG.tmp" && mv -f "$GOST_CFG.tmp" "$GOST_CFG"
    if [[ "$count" == 0 ]]; then
        if svc_exists "$GOST_SVC" 2>/dev/null; then
            svc_stop "$GOST_SVC" >/dev/null 2>&1 || true
            svc_disable "$GOST_SVC" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    [[ -x "$GOST_BIN" ]] || { _gost_err "gost is not installed ($GOST_BIN)"; return 1; }
    svc_exists "$GOST_SVC" 2>/dev/null || { _gost_write_service; svc_daemon_reload; }
    svc_enable "$GOST_SVC" >/dev/null 2>&1 || true
    if ! svc_restart "$GOST_SVC" >/dev/null 2>&1; then
        _gost_err "gost did not restart"
        svc_log_tail "$GOST_SVC" 15 >&2
        return 1
    fi
    sleep 1
    if ! svc_is_active "$GOST_SVC"; then
        _gost_err "gost is not running after the change"
        svc_log_tail "$GOST_SVC" 15 >&2
        return 1
    fi
}

gost_uninstall() {
    if svc_exists "$GOST_SVC" 2>/dev/null; then
        svc_stop "$GOST_SVC" >/dev/null 2>&1 || true
        svc_disable "$GOST_SVC" >/dev/null 2>&1 || true
    fi
    psm_remove_openrc_service "$GOST_SVC"
    rm -f "$GOST_BIN" "$GOST_SERVICE"
    rm -rf "$GOST_DIR"
    svc_daemon_reload
}
