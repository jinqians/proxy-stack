#!/usr/bin/env bash
# doctor.sh — read-only PSM host/configuration diagnostics.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOCTOR_SCHEMA_VERSION="1"

declare -a _DOCTOR_IDS=()
declare -a _DOCTOR_CATEGORIES=()
declare -a _DOCTOR_STATUSES=()
declare -a _DOCTOR_MESSAGES=()
declare -a _DOCTOR_DETAILS=()

_doctor_json_escape() {
    local value="${1-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
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
    local id="$1" category="$2" status="$3" message="$4" details="${5-}"
    [[ -n "$details" ]] || details='{}'
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
        ubuntu|debian|raspbian|centos|rhel|fedora|rocky|almalinux|ol|amzn) supported=true ;;
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
    local cmd
    for cmd in bash curl jq openssl systemctl; do
        if command -v "$cmd" &>/dev/null; then
            _doctor_add "command.${cmd}" "dependency" "ok" \
                "$(t doctor.msg.command_ok "$cmd")" \
                "$(_doctor_details command "$cmd" path "$(command -v "$cmd")")"
        else
            _doctor_add "command.${cmd}" "dependency" "critical" \
                "$(t doctor.msg.command_bad "$cmd")" \
                "$(_doctor_details command "$cmd" path "")"
        fi
    done
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
    if ! command -v systemctl &>/dev/null; then
        _doctor_add "core.${id}" "core" "warning" "$(t doctor.msg.service_unavailable "$label")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "unknown")"
        return 0
    fi
    active_state=$(systemctl is-active "$service" 2>/dev/null || true)
    [[ -n "$active_state" ]] || active_state="inactive"
    if [[ "$load_state" == "not-found" ]]; then
        _doctor_add "core.${id}" "core" "critical" "$(t doctor.msg.service_missing "$label" "$service")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "$active_state")"
    elif [[ "$active_state" == "active" ]]; then
        _doctor_add "core.${id}" "core" "ok" "$(t doctor.msg.service_ok "$label")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "$active_state")"
    else
        _doctor_add "core.${id}" "core" "critical" "$(t doctor.msg.service_bad "$label" "$active_state")" \
            "$(_doctor_details name "$label" binary "$binary" service "$service" config "$config" state "$active_state")"
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
            "$(_doctor_details mount "/" total_kb "$total" available_kb "$available" used_percent "$used_pct")"
    elif (( used_pct >= 90 )); then
        _doctor_add "resource.disk_root" "resource" "warning" "$(t doctor.msg.disk_warning "$used_pct")" \
            "$(_doctor_details mount "/" total_kb "$total" available_kb "$available" used_percent "$used_pct")"
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
    done < <(find "$NGINX_SSL_DIR" -type f \( -name '*.crt' -o -name '*.cer' -o -name '*fullchain*.pem' \) -print 2>/dev/null)

    local details
    details=$(_doctor_details directory "$NGINX_SSL_DIR" total "$total" expiring "$expiring" expired "$expired" invalid "$invalid")
    if (( total == 0 )); then
        _doctor_add "certificate.nginx" "certificate" "skipped" "$(t doctor.msg.cert_absent)" "$details"
    elif (( expired > 0 || invalid > 0 )); then
        _doctor_add "certificate.nginx" "certificate" "critical" "$(t doctor.msg.cert_critical "$expired" "$invalid")" "$details"
    elif (( expiring > 0 )); then
        _doctor_add "certificate.nginx" "certificate" "warning" "$(t doctor.msg.cert_warning "$expiring")" "$details"
    else
        _doctor_add "certificate.nginx" "certificate" "ok" "$(t doctor.msg.cert_ok "$total")" "$details"
    fi
}

_doctor_collect() {
    _doctor_reset
    _doctor_check_system
    _doctor_check_commands
    _doctor_check_configs
    _doctor_check_cores
    _doctor_check_disk
    _doctor_check_certificates
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
    printf '"checks":['
    for (( i=0; i<${#_DOCTOR_IDS[@]}; i++ )); do
        (( i == 0 )) || printf ','
        printf '{"id":"%s","category":"%s","status":"%s","message":"%s","details":%s}' \
            "$(_doctor_json_escape "${_DOCTOR_IDS[$i]}")" \
            "$(_doctor_json_escape "${_DOCTOR_CATEGORIES[$i]}")" \
            "$(_doctor_json_escape "${_DOCTOR_STATUSES[$i]}")" \
            "$(_doctor_json_escape "${_DOCTOR_MESSAGES[$i]}")" \
            "${_DOCTOR_DETAILS[$i]}"
    done
    printf ']}\n'
}

_doctor_render_human() {
    local summary status ok warning critical skipped total i color label
    summary=$(_doctor_summary)
    IFS=$'\t' read -r status ok warning critical skipped total <<< "$summary"
    echo -e "\n${BOLD}${BLUE}══ $(t doctor.title) ══════════════════════════════${NC}"
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
}

psm_doctor() {
    local format="human"
    if (( $# > 1 )); then
        printf '%s\n' "$(t doctor.bad_option "$2")" >&2
        printf '%s\n' "$(t doctor.usage)" >&2
        return 2
    fi
    case "${1:-}" in
        ""|--human) format="human" ;;
        --json) format="json" ;;
        -h|--help)
            printf '%s\n' "$(t doctor.usage)"
            return 0
            ;;
        *)
            printf '%s\n' "$(t doctor.bad_option "$1")" >&2
            printf '%s\n' "$(t doctor.usage)" >&2
            return 2
            ;;
    esac

    _doctor_collect
    if [[ "$format" == "json" ]]; then
        _doctor_render_json
    else
        _doctor_render_human
    fi

    local summary status
    summary=$(_doctor_summary)
    status=${summary%%$'\t'*}
    [[ "$status" != "critical" ]]
}

# Alias kept intentionally small so callers may use either public spelling.
doctor_main() { psm_doctor "$@"; }
psm_doctor_cli() { psm_doctor "$@"; }
