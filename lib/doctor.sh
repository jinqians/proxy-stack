#!/usr/bin/env bash
# doctor.sh — PSM host/configuration diagnostics. Read-only unless --fix is
# given: then every problem a check knows a safe repair for is repaired, and
# everything is checked again. Invalid configs are only ever reported.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOCTOR_SCHEMA_VERSION="1"

declare -a _DOCTOR_IDS=()
declare -a _DOCTOR_CATEGORIES=()
declare -a _DOCTOR_STATUSES=()
declare -a _DOCTOR_MESSAGES=()
declare -a _DOCTOR_DETAILS=()
declare -a _DOCTOR_FIXES=()        # repair action per check ("" = none)
declare -a _DOCTOR_FIX_IDS=() _DOCTOR_FIX_RESULTS=()

_doctor_json_escape() {
    local value="${1-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    value=${value//$'\f'/\\f}
    value=${value//$'\b'/\\b}
    # any other control character (a colour code, say) has no place in JSON text
    value=${value//[$'\x01'-$'\x1f']/}
    printf '%s' "$value"
}

_doctor_json_string() {
    printf '"%s"' "$(_doctor_json_escape "${1-}")"
}

_doctor_details() {
    # _doctor_details key value [key value ...]
    local first=1 key value
    printf '{'
    while (( $# >= 2 )); do
        key="$1"; value="$2"; shift 2
        (( first == 1 )) || printf ','
        first=0
        printf '"%s":"%s"' "$(_doctor_json_escape "$key")" "$(_doctor_json_escape "$value")"
    done
    printf '}'
}

_doctor_add() {
    local id="$1" category="$2" status="$3" message="$4" details="${5-}" fix="${6-}"
    [[ -n "$details" ]] || details='{}'
    _DOCTOR_FIXES+=("$fix")
    _DOCTOR_IDS+=("$id")
    _DOCTOR_CATEGORIES+=("$category")
    _DOCTOR_STATUSES+=("$status")
    _DOCTOR_MESSAGES+=("$message")
    _DOCTOR_DETAILS+=("$details")
}

_doctor_reset() {
    _DOCTOR_IDS=()
    _DOCTOR_CATEGORIES=()
    _DOCTOR_STATUSES=()
    _DOCTOR_MESSAGES=()
    _DOCTOR_DETAILS=()
    _DOCTOR_FIXES=()
}

_doctor_os_value() {
    local key="$1" value=""
    [[ -r /etc/os-release ]] || return 0
    value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' /etc/os-release 2>/dev/null || true)
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    printf '%s' "$value"
}

_doctor_check_system() {
    local os_id os_version pretty supported=false
    os_id=$(_doctor_os_value ID)
    os_version=$(_doctor_os_value VERSION_ID)
    pretty=$(_doctor_os_value PRETTY_NAME)
    [[ -n "$pretty" ]] || pretty="${os_id:-unknown} ${os_version:-}"

    case "$os_id" in
        alpine|ubuntu|debian|raspbian|centos|rhel|fedora|rocky|almalinux|ol|amzn) supported=true ;;
    esac
    if [[ "$supported" == true ]]; then
        _doctor_add "system.os" "system" "ok" \
            "$(t doctor.msg.os_ok "$pretty")" \
            "$(_doctor_details id "$os_id" version "$os_version" supported "true")"
    else
        _doctor_add "system.os" "system" "critical" \
            "$(t doctor.msg.os_bad "$pretty")" \
            "$(_doctor_details id "${os_id:-unknown}" version "$os_version" supported "false")"
    fi

    if (( EUID == 0 )); then
        _doctor_add "system.root" "system" "ok" "$(t doctor.msg.root_ok)" \
            "$(_doctor_details euid "$EUID" root "true")"
    else
        _doctor_add "system.root" "system" "critical" "$(t doctor.msg.root_bad "$EUID")" \
            "$(_doctor_details euid "$EUID" root "false")"
    fi
}

_doctor_check_commands() {
    local cmd commands=(bash curl jq openssl)
    # Alpine's normal init is OpenRC. Treat rc-service as the required service
    # controller there instead of reporting a false-critical missing systemctl.
    if [[ "$(_doctor_os_value ID)" == "alpine" ]] && command -v rc-service &>/dev/null; then
        commands+=(rc-service)
    else
        commands+=(systemctl)
    fi
    for cmd in "${commands[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            _doctor_add "command.${cmd}" "dependency" "ok" \
                "$(t doctor.msg.command_ok "$cmd")" \
                "$(_doctor_details command "$cmd" path "$(command -v "$cmd")")"
        else
            local fix="" level=critical
            [[ "$cmd" == curl || "$cmd" == jq || "$cmd" == openssl ]] && fix="_doctor_fix_pkg $cmd"
            # no service manager (a container without an init): the cores
            # cannot run as services, which each core's own check reports —
            # a warning here, as there
            [[ "$cmd" == systemctl || "$cmd" == rc-service ]] && level=warning
            _doctor_add "command.${cmd}" "dependency" "$level" \
                "$(t doctor.msg.command_bad "$cmd")" \
                "$(_doctor_details command "$cmd" path "")" "$fix"
        fi
    done
}

# jq 1.6 treats `jq -e` on empty input as true (see ensure_modern_jq)
_doctor_check_jq_version() {
    command -v jq &>/dev/null || return 0
    local v; v=$(jq --version 2>/dev/null)
    if _jq_is_modern; then
        _doctor_add "dependency.jq_version" "dependency" "ok" "$(t doctor.msg.jq_ok "$v")" \
            "$(_doctor_details version "$v")"
    else
        _doctor_add "dependency.jq_version" "dependency" "warning" "$(t doctor.msg.jq_old "$v")" \
            "$(_doctor_details version "$v")" "_doctor_fix_jq"
    fi
}

_doctor_json_valid() {
    local file="$1"
    if command -v jq &>/dev/null; then
        jq empty "$file" &>/dev/null
    elif command -v python3 &>/dev/null; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1], "rb"))' "$file" &>/dev/null
    else
        return 2
    fi
}

_doctor_check_json_file() {
    local id="$1" label="$2" file="$3" rc=0 validator="jq"
    if [[ ! -e "$file" ]]; then
        _doctor_add "$id" "configuration" "skipped" "$(t doctor.msg.config_absent "$label")" \
            "$(_doctor_details name "$label" path "$file" format "json" present "false")"
        return 0
    fi
    if [[ ! -r "$file" ]]; then
        _doctor_add "$id" "configuration" "critical" "$(t doctor.msg.config_unreadable "$label")" \
            "$(_doctor_details name "$label" path "$file" format "json" present "true")"
        return 0
    fi
    if [[ ! -s "$file" ]]; then
        _doctor_add "$id" "configuration" "critical" "$(t doctor.msg.config_empty "$label")" \
            "$(_doctor_details name "$label" path "$file" format "json" present "true")"
        return 0
    fi
    command -v jq &>/dev/null || validator="python3"
    _doctor_json_valid "$file" || rc=$?
    case "$rc" in
        0) _doctor_add "$id" "configuration" "ok" "$(t doctor.msg.config_ok "$label")" \
               "$(_doctor_details name "$label" path "$file" format "json" validator "$validator" present "true")" ;;
        2) _doctor_add "$id" "configuration" "warning" "$(t doctor.msg.config_no_validator "$label")" \
               "$(_doctor_details name "$label" path "$file" format "json" validator "none" present "true")" ;;
        *) _doctor_add "$id" "configuration" "critical" "$(t doctor.msg.config_bad "$label")" \
               "$(_doctor_details name "$label" path "$file" format "json" validator "$validator" present "true")" ;;
    esac
}

_doctor_check_yaml_file() {
    local id="$1" label="$2" file="$3" first_line
    if [[ ! -e "$file" ]]; then
        _doctor_add "$id" "configuration" "skipped" "$(t doctor.msg.config_absent "$label")" \
            "$(_doctor_details name "$label" path "$file" format "yaml" present "false")"
        return 0
    fi
    if [[ ! -r "$file" ]]; then
        _doctor_add "$id" "configuration" "critical" "$(t doctor.msg.config_unreadable "$label")" \
            "$(_doctor_details name "$label" path "$file" format "yaml" present "true")"
        return 0
    fi
    if [[ ! -s "$file" ]]; then
        _doctor_add "$id" "configuration" "critical" "$(t doctor.msg.config_empty "$label")" \
            "$(_doctor_details name "$label" path "$file" format "yaml" present "true")"
        return 0
    fi

    first_line=$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' "$file" 2>/dev/null || true)
    if [[ "$first_line" =~ ^[[:space:]]*[\{\[] ]]; then
        _doctor_check_json_file "$id" "$label" "$file"
    elif grep -q $'^\t' "$file" 2>/dev/null; then
        _doctor_add "$id" "configuration" "critical" "$(t doctor.msg.yaml_tabs "$label")" \
            "$(_doctor_details name "$label" path "$file" format "yaml" validator "basic" present "true")"
    elif grep -Eq '^[[:space:]]*([A-Za-z0-9_.-]+|"[^"]+"|\x27[^\x27]+\x27)[[:space:]]*:' "$file" 2>/dev/null; then
        _doctor_add "$id" "configuration" "ok" "$(t doctor.msg.config_ok "$label")" \
            "$(_doctor_details name "$label" path "$file" format "yaml" validator "basic" present "true")"
    else
        _doctor_add "$id" "configuration" "critical" "$(t doctor.msg.config_bad "$label")" \
            "$(_doctor_details name "$label" path "$file" format "yaml" validator "basic" present "true")"
    fi
}

_doctor_check_configs() {
    _doctor_check_json_file "config.xray" "Xray" "$XRAY_CFG_DIR/config.json"
    _doctor_check_json_file "config.singbox" "sing-box" "$SINGBOX_CFG_DIR/config.json"
    _doctor_check_yaml_file "config.mihomo" "mihomo" "$MIHOMO_CFG_DIR/config.yaml"
    _doctor_check_yaml_file "config.hysteria2" "Hysteria2" "$HYSTERIA_CFG"
    _doctor_check_json_file "config.ssrust" "ss-rust" "/etc/ss-rust/config.json"

    local file rel slug
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        rel="${file#"$CFG_DIR"/}"
        # The five runtime files above live outside CFG_DIR; every match here is
        # a PSM state/node-store JSON file and therefore has its own stable id.
        slug=${rel//\//.}; slug=${slug%.json}
        _doctor_check_json_file "config.store.${slug}" "PSM ${rel}" "$file"
    done < <(find "$CFG_DIR" -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
}

_doctor_service_load_state() {
    local service="$1"
    if _uses_openrc; then
        svc_exists "$service" && printf 'loaded' || printf 'not-found'
        return
    fi
    command -v systemctl &>/dev/null || { printf 'unavailable'; return; }
    systemctl show "$service" --property=LoadState --value 2>/dev/null || printf 'not-found'
}

_doctor_check_core() {
    local id="$1" label="$2" binary="$3" service="$4" config="$5"
    local has_binary=false has_config=false load_state="not-found" active_state="unknown"
    [[ -e "$binary" ]] && has_binary=true
    [[ -e "$config" ]] && has_config=true
    load_state=$(_doctor_service_load_state "$service")
    [[ -n "$load_state" ]] || load_state="not-found"

    if [[ "$has_binary" == false && "$has_config" == false \
        && ( "$load_state" == "not-found" || "$load_state" == "unavailable" ) ]]; then
        _doctor_add "core.${id}" "core" "skipped" "$(t doctor.msg.core_absent "$label")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" installed "false")"
        return 0
    fi
    if [[ "$has_binary" == false ]]; then
        _doctor_add "core.${id}" "core" "critical" "$(t doctor.msg.core_binary_bad "$label" "$binary")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" installed "false")"
        return 0
    fi
    if [[ ! -x "$binary" ]]; then
        _doctor_add "core.${id}" "core" "critical" "$(t doctor.msg.core_not_executable "$label")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" installed "true")"
        return 0
    fi
    if ! command -v systemctl &>/dev/null && ! _uses_openrc; then
        _doctor_add "core.${id}" "core" "warning" "$(t doctor.msg.service_unavailable "$label")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "unknown")"
        return 0
    fi
    if _uses_openrc; then
        svc_is_active "$service" && active_state="active" || active_state="inactive"
    else
        active_state=$(systemctl is-active "$service" 2>/dev/null || true)
    fi
    [[ -n "$active_state" ]] || active_state="inactive"
    if [[ "$load_state" == "not-found" ]]; then
        # ss-rust's unit is written by its installer alone: --fix cannot make
        # it, so it is not offered (it would fail every time)
        local fix="_doctor_fix_core $id"
        [[ "$id" == ssrust ]] && fix=""
        _doctor_add "core.${id}" "core" "critical" "$(t doctor.msg.service_missing "$label" "$service")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "$active_state")" \
            "$fix"
    elif [[ "$active_state" == "active" ]]; then
        _doctor_add "core.${id}" "core" "ok" "$(t doctor.msg.service_ok "$label")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "$active_state")"
    else
        _doctor_add "core.${id}" "core" "critical" "$(t doctor.msg.service_bad "$label" "$active_state")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "$active_state")" \
            "_doctor_fix_core $id"
    fi
    [[ "$load_state" == "loaded" ]] && _doctor_check_core_extra "$id" "$label" "$service"
}

# Starts at boot; and, for the three proxy cores, runs as psm-core (lib/coreperm.sh).
_doctor_check_core_extra() {
    local id="$1" label="$2" service="$3" def pid user=""
    if svc_is_enabled "$service" 2>/dev/null; then
        _doctor_add "core.${id}.boot" "core" "ok" "$(t doctor.msg.boot_ok "$label")" \
            "$(_doctor_details service "$service" enabled "true")"
    else
        _doctor_add "core.${id}.boot" "core" "warning" "$(t doctor.msg.boot_disabled "$label")" \
            "$(_doctor_details service "$service" enabled "false")" "_doctor_fix_boot $service"
    fi
    case "$id" in xray|singbox|mihomo) ;; *) return 0 ;; esac
    source "$LIB_DIR/coreperm.sh"
    if ! psm_core_nonroot_supported; then
        _doctor_add "core.${id}.user" "core" "skipped" "$(t doctor.msg.core_root_old_systemd "$label")" \
            "$(_doctor_details service "$service" user "root" reason "systemd<231")"
        return 0
    fi
    if _uses_systemd; then
        def="/etc/systemd/system/${service}.service"
        pid=$(systemctl show -p MainPID --value "$service" 2>/dev/null || true)
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] && user=$(stat -c %U "/proc/$pid" 2>/dev/null)
    else
        def="/etc/init.d/${service}"
    fi
    if grep -qE '^(User=|command_user="?)psm-core' "$def" 2>/dev/null && [[ "$user" != root ]]; then
        _doctor_add "core.${id}.user" "core" "ok" "$(t doctor.msg.core_user_ok "$label")" \
            "$(_doctor_details service "$service" definition "$def" user "${user:-psm-core}")"
    else
        _doctor_add "core.${id}.user" "core" "warning" "$(t doctor.msg.core_root "$label")" \
            "$(_doctor_details service "$service" definition "$def" user "${user:-root}")" "_doctor_fix_core $id"
    fi
}

_doctor_check_cores() {
    _doctor_check_core "xray" "Xray" "$XRAY_BIN" "xray" "$XRAY_CFG_DIR/config.json"
    _doctor_check_core "singbox" "sing-box" "$SINGBOX_BIN" "sing-box" "$SINGBOX_CFG_DIR/config.json"
    _doctor_check_core "mihomo" "mihomo" "$MIHOMO_BIN" "mihomo" "$MIHOMO_CFG_DIR/config.yaml"
    _doctor_check_core "hysteria2" "Hysteria2" "$HYSTERIA_BIN" "hysteria-server" "$HYSTERIA_CFG"
    _doctor_check_core "ssrust" "ss-rust" "/usr/local/bin/ss-rust" "ss-rust" "/etc/ss-rust/config.json"
}

_doctor_check_disk() {
    local line total available used_pct
    line=$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $2, $4, $5 }' || true)
    read -r total available used_pct <<< "$line"
    used_pct="${used_pct%%%}"
    if ! [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$used_pct" =~ ^[0-9]+$ ]]; then
        _doctor_add "resource.disk_root" "resource" "warning" "$(t doctor.msg.disk_unknown)" \
            "$(_doctor_details mount "/" total_kb "" available_kb "" used_percent "")"
    elif (( used_pct >= 95 )); then
        _doctor_add "resource.disk_root" "resource" "critical" "$(t doctor.msg.disk_critical "$used_pct")" \
            "$(_doctor_details mount "/" total_kb "$total" available_kb "$available" used_percent "$used_pct")" "_doctor_fix_disk"
    elif (( used_pct >= 90 )); then
        _doctor_add "resource.disk_root" "resource" "warning" "$(t doctor.msg.disk_warning "$used_pct")" \
            "$(_doctor_details mount "/" total_kb "$total" available_kb "$available" used_percent "$used_pct")" "_doctor_fix_disk"
    else
        _doctor_add "resource.disk_root" "resource" "ok" "$(t doctor.msg.disk_ok "$used_pct")" \
            "$(_doctor_details mount "/" total_kb "$total" available_kb "$available" used_percent "$used_pct")"
    fi
}

_doctor_check_certificates() {
    local total=0 expiring=0 expired=0 invalid=0 cert
    if [[ ! -d "$NGINX_SSL_DIR" ]]; then
        _doctor_add "certificate.nginx" "certificate" "skipped" "$(t doctor.msg.cert_absent)" \
            "$(_doctor_details directory "$NGINX_SSL_DIR" total "0" expiring "0" expired "0" invalid "0")"
        return 0
    fi
    while IFS= read -r cert; do
        [[ -n "$cert" ]] || continue
        total=$(( total + 1 ))
        if ! openssl x509 -in "$cert" -noout &>/dev/null; then
            invalid=$(( invalid + 1 ))
        elif ! openssl x509 -in "$cert" -noout -checkend 0 &>/dev/null; then
            expired=$(( expired + 1 ))
        elif ! openssl x509 -in "$cert" -noout -checkend 1209600 &>/dev/null; then
            expiring=$(( expiring + 1 ))
        fi
    # certificates by any of their usual names (cert.pem, fullchain.pem, *.crt…), keys left out
    done < <(find "$NGINX_SSL_DIR" -type f \( -name '*.crt' -o -name '*.cer' -o -name '*.pem' \) \
                 -not -iname '*key*' -not -iname '*priv*' -print 2>/dev/null)

    local details fix=""
    details=$(_doctor_details directory "$NGINX_SSL_DIR" total "$total" expiring "$expiring" expired "$expired" invalid "$invalid")
    [[ -f "$ACME_HOME/acme.sh" ]] && fix="_doctor_fix_cert"
    if (( total == 0 )); then
        _doctor_add "certificate.nginx" "certificate" "skipped" "$(t doctor.msg.cert_absent)" "$details"
    elif (( expired > 0 || invalid > 0 )); then
        _doctor_add "certificate.nginx" "certificate" "critical" "$(t doctor.msg.cert_critical "$expired" "$invalid")" "$details" "$fix"
    elif (( expiring > 0 )); then
        _doctor_add "certificate.nginx" "certificate" "warning" "$(t doctor.msg.cert_warning "$expiring")" "$details" "$fix"
    else
        _doctor_add "certificate.nginx" "certificate" "ok" "$(t doctor.msg.cert_ok "$total")" "$details"
    fi
}

# Hysteria2 port hopping: every node with a hop range has its REDIRECT rule.
# Nothing restores them after a reboot but PSM's boot hook, and minimal
# Debian has no iptables at all.
_doctor_check_hop() {
    [[ -f "$LIB_DIR/hop.sh" ]] || return 0
    source "$LIB_DIR/hop.sh"
    local wanted tag n=0 have=0 rules
    # `|| true`: under manager.sh's errexit a failed substitution (no iptables
    # at all, exit 127) would end doctor right here
    wanted=$(_hop_wanted || true)
    rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null || true)
    while IFS=$'\t' read -r tag _ _; do
        [[ -n "$tag" ]] || continue
        n=$((n + 1))
        # the comment as text: a tag is no pattern
        awk -v c="/* psm-hop:${tag} */" 'index($0, c) { f = 1 } END { exit !f }' <<<"$rules" && have=$((have + 1))
    done <<<"$wanted"
    if (( n == 0 )); then
        _doctor_add "network.hop" "network" "skipped" "$(t doctor.msg.hop_none)" "$(_doctor_details nodes "0" rules "0")"
    elif (( have == n )); then
        _doctor_add "network.hop" "network" "ok" "$(t doctor.msg.hop_ok "$n")" "$(_doctor_details nodes "$n" rules "$have")"
    else
        _doctor_add "network.hop" "network" "warning" "$(t doctor.msg.hop_missing "$have" "$n")" \
            "$(_doctor_details nodes "$n" rules "$have")" "_doctor_fix_hop"
    fi
}

# Xray mKCP: each node's inbound as this Xray needs it (_xray_kcp_form and the
# mask order, xray/xhttp.sh). Older PSM wrote kcpSettings.seed on v26.9.9 and the
# disguise header after the cipher on v26.3.27 — both accepted by the core and
# reachable by no client. The node store is the truth: an inbound that differs
# from what it builds now is rewritten by --fix.
_doctor_check_kcp() {
    local cfg="$XRAY_CFG_DIR/config.json" store="$CFG_DIR/xray/xhttp.json" node tag want live n=0 stale=0
    [[ -r "$cfg" && -r "$store" && -x "$XRAY_BIN" ]] || return 0
    jq -e 'any(.[]?; .mode == "mkcp")' "$store" >/dev/null 2>&1 || return 0
    source "$LIB_DIR/xray/xhttp.sh"
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        n=$((n + 1)); tag=$(jq -r '.tag' <<<"$node")
        # a node that does not build (or a config jq cannot read) counts as
        # stale: under set -e a failed substitution here ended doctor
        want=$(_xhttp_build_inbound "$node" 2>/dev/null | jq -S -c '.streamSettings' 2>/dev/null || true)
        live=$(jq -S -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) | .streamSettings' "$cfg" 2>/dev/null || true)
        [[ -n "$want" && "$want" == "$live" ]] || stale=$((stale + 1))
    done < <(jq -c '.[] | select(.mode == "mkcp")' "$store" 2>/dev/null)
    local form; form=$(_xray_kcp_form 2>/dev/null || true)
    if (( stale > 0 )); then
        _doctor_add "xray.kcp" "configuration" "warning" "$(t doctor.msg.kcp_old "$stale" "$n")" \
            "$(_doctor_details nodes "$n" stale "$stale" xray_form "$form")" "_doctor_fix_kcp"
    else
        _doctor_add "xray.kcp" "configuration" "ok" "$(t doctor.msg.kcp_ok "$n")" \
            "$(_doctor_details nodes "$n" stale "0" xray_form "$form")"
    fi
}

# Relays (psm relay): each rule's port has to be listening, or its engine is
# down (a realm or gost that did not come back, a binary gone). The store is
# the truth; --fix installs a missing engine and applies its rules again.
# nginx.conf as an older PSM wrote it: no map_hash_bucket_size for stream {} (in
# nginx.conf or a stream.d file it includes), so a domain longer than 32 bytes in
# the SNI map stops nginx ("could not build map_hash", #6). --fix writes the
# current one and reloads.
_doctor_check_nginx_main() {
    local conf="/etc/nginx/nginx.conf"
    [[ -r "$conf" ]] && grep -q 'PSM-managed nginx.conf' "$conf" || return 0
    if grep -q '^stream {' "$conf" && ! grep -qsE '^[[:space:]]*map_hash_bucket_size[[:space:]]' "$conf" /etc/nginx/stream.d/*.conf; then
        _doctor_add "nginx.main" "configuration" "warning" "$(t doctor.msg.nginx_main_old)" \
            "$(_doctor_details file "$conf")" "_doctor_fix_nginx_main"
    else
        _doctor_add "nginx.main" "configuration" "ok" "$(t doctor.msg.nginx_main_ok)" "$(_doctor_details file "$conf")"
    fi
}

_doctor_check_relays() {
    local store="$CFG_DIR/realm/rules.json" n down=0 dead="" rule tag port proto
    [[ -s "$store" ]] || return 0
    n=$(jq 'length' "$store" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 0
    source "$LIB_DIR/relay_cli.sh"
    while IFS= read -r rule; do
        tag=$(jq -r '.tag' <<<"$rule"); port=$(jq -r '.listen_port' <<<"$rule")
        proto=$(_relay_proto "$rule")
        # a relay paused over its quota or past its expiry still listens: the
        # firewall answers for it
        _relay_port_bound "$port" "$proto" && continue
        down=$((down + 1)); dead+="${dead:+ }$tag"
    done < <(jq -c '.[]' "$store" 2>/dev/null)
    if (( down > 0 )); then
        _doctor_add "relay.listen" "network" "warning" "$(t doctor.msg.relay_down "$down" "$n" "$dead")" \
            "$(_doctor_details relays "$n" down "$down")" "_doctor_fix_relays"
    else
        _doctor_add "relay.listen" "network" "ok" "$(t doctor.msg.relay_ok "$n")" \
            "$(_doctor_details relays "$n" down "0")"
    fi
}

# ── Repairs (psm doctor --fix) ────────────────────────────────────────────────
# Each runs in a subshell with stdout on stderr and no terminal input, and
# returns 0 when it believes the problem is gone; the checks run again after.
_doctor_fix_pkg() { ensure_pkg_deps "$1" >/dev/null 2>&1; command -v "$1" &>/dev/null; }

# Restart a core through its own config-test-then-restart path; a missing
# service definition is written first. The proxy cores' restart path also
# moves a root unit to psm-core (lib/coreperm.sh).
_doctor_fix_core() {
    local svc
    case "$1" in
        xray)
            svc=xray; source "$LIB_DIR/xray/core.sh"
            svc_exists xray || { _write_xray_service; svc_daemon_reload; svc_enable xray; }
            xray_test_restart ;;
        singbox)
            svc=sing-box; source "$LIB_DIR/singbox/core.sh"
            svc_exists sing-box || { _sb_write_service; svc_daemon_reload; svc_enable sing-box; }
            sb_test_restart ;;
        mihomo)
            svc=mihomo; source "$LIB_DIR/mihomo/core.sh"
            svc_exists mihomo || { _mh_write_service; svc_daemon_reload; svc_enable mihomo; }
            mh_test_restart ;;
        hysteria2)
            svc=hysteria-server
            # the unit gone (removed by hand): written again, as the module writes it
            svc_exists "$svc" || { source "$LIB_DIR/hysteria2.sh" && _hy2_write_service && svc_daemon_reload && svc_enable "$svc"; }
            svc_restart "$svc" ;;
        ssrust)    svc=ss-rust; svc_exists "$svc" && svc_restart "$svc" ;;
        *) return 1 ;;
    esac
    local i
    for i in 1 2 3 4 5 6; do svc_is_active "$svc" && return 0; sleep 1; done
    return 1
}

_doctor_fix_jq() { ensure_modern_jq && _jq_is_modern; }

_doctor_fix_boot() { svc_enable "$1" && svc_is_enabled "$1"; }

_doctor_fix_hop() { source "$LIB_DIR/hop.sh" && psm_hop_sync; }

_doctor_fix_kcp() { source "$LIB_DIR/xray/xhttp.sh" && _xhttp_apply_all; }

_doctor_fix_nginx_main() { source "$LIB_DIR/nginx.sh" && _write_nginx_main && nginx_test_reload >/dev/null 2>&1; }

_doctor_fix_relays() {
    source "$LIB_DIR/relay_cli.sh" || return 1
    _relay_load_realm
    local e
    for e in $(_realm_load | jq -r '[.[] | .engine // "realm"] | unique | .[]'); do
        _relay_ensure_engine "$e" && _relay_engine_apply "$e" || return 1
    done
}

# acme.sh decides what is due; a 90-day certificate with under 14 days left is.
_doctor_fix_cert() {
    source "$LIB_DIR/cert.sh"
    local rc=0
    _acme --renew-all || rc=$?
    (( rc == 0 || rc == 2 ))
}

# Space PSM can give back without touching data: the journal, oversized logs,
# the package cache.
_doctor_fix_disk() {
    _uses_systemd && command -v journalctl &>/dev/null && journalctl --vacuum-size=100M >/dev/null 2>&1
    find /var/log/psm /var/log/xray "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -size +50M \
        -exec truncate -s 0 {} + 2>/dev/null
    detect_os
    case "$PKG_MGR" in
        apt-get) apt-get clean ;;
        yum)     "$(_rhel_pkg_cmd)" clean all >/dev/null 2>&1 ;;
        apk)     rm -rf /var/cache/apk/* ;;
    esac
    return 0
}

_doctor_apply_fixes() {
    local i action done_actions=$'\n'
    _DOCTOR_FIX_IDS=(); _DOCTOR_FIX_RESULTS=()
    for (( i=0; i<${#_DOCTOR_IDS[@]}; i++ )); do
        [[ "${_DOCTOR_STATUSES[$i]}" == warning || "${_DOCTOR_STATUSES[$i]}" == critical ]] || continue
        action="${_DOCTOR_FIXES[$i]}"
        [[ -n "$action" ]] || continue
        # one repair can answer several checks (a core that is stopped and still root)
        [[ "$done_actions" == *$'\n'"$action"$'\n'* ]] && continue
        done_actions+="$action"$'\n'
        log_step "$(t doctor.fix.running "${_DOCTOR_IDS[$i]}")"
        _DOCTOR_FIX_IDS+=("${_DOCTOR_IDS[$i]}")
        # shellcheck disable=SC2086  # "function arg" by design
        if ( $action ) </dev/null >&2; then
            _DOCTOR_FIX_RESULTS+=("ok")
        else
            _DOCTOR_FIX_RESULTS+=("failed")
        fi
    done
}

_doctor_fixable_count() {
    local i n=0
    for (( i=0; i<${#_DOCTOR_IDS[@]}; i++ )); do
        [[ -n "${_DOCTOR_FIXES[$i]}" && ( "${_DOCTOR_STATUSES[$i]}" == warning || "${_DOCTOR_STATUSES[$i]}" == critical ) ]] \
            && n=$((n + 1))
    done
    printf '%s' "$n"
}

# Containers (LXC, OpenVZ) usually have no /dev/net/tun unless the host hands
# one out. WARP does not need it — all three cores speak WireGuard themselves —
# but the free residential exit dials OpenVPN and cannot work without it. The
# panel shows this too: psm-agent reports `psm doctor --json` with its status.
_doctor_check_tun() {
    local virt="" tun="no"
    virt=$(systemd-detect-virt 2>/dev/null) || virt=""
    [[ -n "$virt" ]] || virt="unknown"
    [[ -c /dev/net/tun ]] && tun="yes"
    if [[ "$tun" == "yes" ]]; then
        _doctor_add "system.tun" "system" "ok" "$(t doctor.msg.tun_ok "$virt")" \
            "$(_doctor_details virtualization "$virt" tun_device "/dev/net/tun" available "yes")"
    else
        _doctor_add "system.tun" "system" "warning" "$(t doctor.msg.tun_missing "$virt")" \
            "$(_doctor_details virtualization "$virt" tun_device "/dev/net/tun" available "no")"
    fi
}

_doctor_collect() {
    _doctor_reset
    _doctor_check_system
    _doctor_check_commands
    _doctor_check_jq_version
    _doctor_check_configs
    _doctor_check_cores
    _doctor_check_disk
    _doctor_check_certificates
    _doctor_check_hop
    _doctor_check_kcp
    _doctor_check_nginx_main
    _doctor_check_relays
    _doctor_check_tun
}

_doctor_summary() {
    local ok=0 warning=0 critical=0 skipped=0 status i
    for (( i=0; i<${#_DOCTOR_STATUSES[@]}; i++ )); do
        case "${_DOCTOR_STATUSES[$i]}" in
            ok) ok=$(( ok + 1 )) ;;
            warning) warning=$(( warning + 1 )) ;;
            critical) critical=$(( critical + 1 )) ;;
            skipped) skipped=$(( skipped + 1 )) ;;
        esac
    done
    status="healthy"
    (( warning > 0 )) && status="warning"
    (( critical > 0 )) && status="critical"
    printf '%s\t%s\t%s\t%s\t%s\t%s' "$status" "$ok" "$warning" "$critical" "$skipped" "${#_DOCTOR_STATUSES[@]}"
}

_doctor_render_json() {
    local summary status ok warning critical skipped total i
    summary=$(_doctor_summary)
    IFS=$'\t' read -r status ok warning critical skipped total <<< "$summary"
    printf '{'
    printf '"schema_version":"%s",' "$DOCTOR_SCHEMA_VERSION"
    printf '"tool":"psm-doctor",'
    printf '"generated_at":"%s",' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '"status":"%s",' "$status"
    printf '"summary":{"ok":%s,"warning":%s,"critical":%s,"skipped":%s,"total":%s},' \
        "$ok" "$warning" "$critical" "$skipped" "$total"
    if [[ "${1:-}" == fixed ]]; then
        printf '"fixes":['
        for (( i=0; i<${#_DOCTOR_FIX_IDS[@]}; i++ )); do
            (( i == 0 )) || printf ','
            printf '{"id":"%s","result":"%s"}' "$(_doctor_json_escape "${_DOCTOR_FIX_IDS[$i]}")" "${_DOCTOR_FIX_RESULTS[$i]}"
        done
        printf '],'
    fi
    printf '"checks":['
    for (( i=0; i<${#_DOCTOR_IDS[@]}; i++ )); do
        (( i == 0 )) || printf ','
        printf '{"id":"%s","category":"%s","status":"%s","message":"%s","fixable":%s,"details":%s}' \
            "$(_doctor_json_escape "${_DOCTOR_IDS[$i]}")" \
            "$(_doctor_json_escape "${_DOCTOR_CATEGORIES[$i]}")" \
            "$(_doctor_json_escape "${_DOCTOR_STATUSES[$i]}")" \
            "$(_doctor_json_escape "${_DOCTOR_MESSAGES[$i]}")" \
            "$([[ -n "${_DOCTOR_FIXES[$i]}" ]] && echo true || echo false)" \
            "${_DOCTOR_DETAILS[$i]}"
    done
    printf ']}\n'
}

_doctor_render_human() {
    local summary status ok warning critical skipped total i color label
    summary=$(_doctor_summary)
    IFS=$'\t' read -r status ok warning critical skipped total <<< "$summary"
    echo -e "\n${BOLD}${BLUE}══ $(t doctor.title) ══════════════════════════════${NC}"
    if [[ "${1:-}" == fixed ]]; then
        echo -e "  ${BOLD}$(t doctor.fix.title)${NC}"
        (( ${#_DOCTOR_FIX_IDS[@]} > 0 )) || printf '    %s\n' "$(t doctor.fix.none)"
        for (( i=0; i<${#_DOCTOR_FIX_IDS[@]}; i++ )); do
            if [[ "${_DOCTOR_FIX_RESULTS[$i]}" == ok ]]; then
                printf '    %b%s%b\n' "$GREEN" "$(t doctor.fix.ok "${_DOCTOR_FIX_IDS[$i]}")" "$NC"
            else
                printf '    %b%s%b\n' "$RED" "$(t doctor.fix.failed "${_DOCTOR_FIX_IDS[$i]}")" "$NC"
            fi
        done
        echo
    fi
    for (( i=0; i<${#_DOCTOR_IDS[@]}; i++ )); do
        case "${_DOCTOR_STATUSES[$i]}" in
            ok) color="$GREEN"; label="$(t doctor.status.ok)" ;;
            warning) color="$YELLOW"; label="$(t doctor.status.warning)" ;;
            critical) color="$RED"; label="$(t doctor.status.critical)" ;;
            *) color="$CYAN"; label="$(t doctor.status.skipped)" ;;
        esac
        printf '  %b%-8s%b %-28s %s\n' "$color" "[$label]" "$NC" "${_DOCTOR_IDS[$i]}" "${_DOCTOR_MESSAGES[$i]}"
    done
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
    printf '%s\n' "$(t doctor.summary "$status" "$ok" "$warning" "$critical" "$skipped" "$total")"
    local fixable; fixable=$(_doctor_fixable_count)
    [[ "${1:-}" != fixed ]] && (( fixable > 0 )) && printf '%s\n' "$(t doctor.fix.hint "$fixable")"
    return 0
}

psm_doctor() {
    local format="human" fix="" arg
    for arg in "$@"; do
        case "$arg" in
            --human) format="human" ;;
            --json) format="json" ;;
            --fix) fix="fixed" ;;
            -h|--help)
                printf '%s\n' "$(t doctor.usage)"
                return 0
                ;;
            *)
                printf '%s\n' "$(t doctor.bad_option "$arg")" >&2
                printf '%s\n' "$(t doctor.usage)" >&2
                return 2
                ;;
        esac
    done
    if [[ -n "$fix" ]] && (( EUID != 0 )); then
        printf '%s\n' "$(t doctor.fix.need_root)" >&2
        return 2
    fi

    _doctor_collect
    if [[ -n "$fix" ]]; then
        _doctor_apply_fixes
        _doctor_collect
    fi
    if [[ "$format" == "json" ]]; then
        _doctor_render_json "$fix"
    else
        _doctor_render_human "$fix"
    fi

    local summary status
    summary=$(_doctor_summary)
    status=${summary%%$'\t'*}
    [[ "$status" != "critical" ]]
}

# Alias kept intentionally small so callers may use either public spelling.
doctor_main() { psm_doctor "$@"; }
psm_doctor_cli() { psm_doctor "$@"; }
