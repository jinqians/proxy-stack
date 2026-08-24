#!/usr/bin/env bash
# node_cli.sh — non-interactive node CRUD/export API for PSM
#
# Public entry points:
#   node_cli_main [node] <list|show|add|update|delete|export> ...
#   psm_node_cli  [node] <list|show|add|update|delete|export> ...
#
# Node stores remain the source of truth.  Mutations are serialized, written
# atomically, applied through the protocol module, and rolled back together with
# the live core config if validation/restart fails.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_NODE_CLI_VERSION=1
_NODE_CLI_LOCK=""

_node_cli_err() { printf 'psm node: %s\n' "$*" >&2; }

_node_cli_usage() {
    cat <<'EOF'
Usage:
  psm node list [--core CORE] [--protocol PROTO] [--json] [--show-secrets]
  psm node show CORE PROTO TAG [--json] [--show-secrets]
  psm node add CORE PROTO [--tag TAG] [--port PORT]
               [--input FILE|- | --data JSON|@FILE] [--set KEY=VALUE ...]
               [--set-json KEY=JSON ...] [--replace] [--store-only] [--json]
  psm node update CORE PROTO TAG
               [--input FILE|- | --data JSON|@FILE] [--set KEY=VALUE ...]
               [--set-json KEY=JSON ...] [--unset KEY ...] [--store-only] [--json]
  psm node delete CORE PROTO TAG --yes
               [--if-exists] [--store-only] [--json]
  psm node export CORE PROTO TAG
               [--server HOST] [--format uri|json|surge]

Cores: xray, sing-box (alias: singbox), mihomo
Protocols:
  xray:     reality, vision, xhttp, ss2022
  sing-box: reality, ss2022, hysteria2, anytls, snell
  mihomo:   reality, ss2022, hysteria2, anytls, snell

Protocol inputs:
  reality:   --port; UUID/keys/short ID/SNI/dest receive safe defaults
  vision:    --port --domain
  xhttp:     --port --domain [--mode xhttp|upgrade|ws|grpc]
  ss2022:    --port [--method ...] [--password ...]
  hysteria2: --port --sni --cert-path --key-path [--password ...]
  anytls:    --port --sni --cert-path --key-path [--password ...]
  snell:     --port [--version 5|6 for sing-box; 4|5 for mihomo] [--psk ...]

Common field options are accepted directly, for example --uuid, --password,
--method, --listen, --listen-addr, --domain, --sni, --cert-path and --key-path.
Use --set for future/protocol-specific fields. Values for numeric, boolean and
array fields are typed automatically; --set-json is always interpreted as JSON.

Queries redact credentials by default. Use --show-secrets only in a protected
terminal or pipeline. Export intentionally includes the credentials required by
clients. --store-only skips core validation/restart and is intended for offline
provisioning and tests.

Selector flags remain supported for scripting compatibility, for example:
  psm node show TAG --core CORE --protocol PROTO --json
EOF
}

_node_cli_pairs() {
    printf '%s\n' \
        $'xray\treality' $'xray\tvision' $'xray\txhttp' $'xray\tss2022' \
        $'sing-box\treality' $'sing-box\tss2022' $'sing-box\thysteria2' \
        $'sing-box\tanytls' $'sing-box\tsnell' \
        $'mihomo\treality' $'mihomo\tss2022' $'mihomo\thysteria2' \
        $'mihomo\tanytls' $'mihomo\tsnell'
}

_node_cli_norm_core() {
    case "${1:-}" in
        xray) printf 'xray' ;;
        singbox|sing-box|sb) printf 'sing-box' ;;
        mihomo|mh) printf 'mihomo' ;;
        *) return 1 ;;
    esac
}

_node_cli_norm_protocol() {
    case "${1:-}" in
        reality|vision|xhttp|anytls|snell) printf '%s' "$1" ;;
        ss|ss2022|shadowsocks|shadowsocks2022) printf 'ss2022' ;;
        hy2|hysteria2) printf 'hysteria2' ;;
        *) return 1 ;;
    esac
}

_node_cli_pair_supported() {
    local core="$1" proto="$2" c p
    while IFS=$'\t' read -r c p; do
        [[ "$c" == "$core" && "$p" == "$proto" ]] && return 0
    done < <(_node_cli_pairs)
    return 1
}

_node_cli_store_path() {
    local core="$1" proto="$2"
    case "$core" in
        xray) printf '%s/xray/%s.json' "$CFG_DIR" "$proto" ;;
        sing-box) printf '%s/singbox/%s.json' "$CFG_DIR" "$proto" ;;
        mihomo) printf '%s/mihomo/%s.json' "$CFG_DIR" "$proto" ;;
        *) return 1 ;;
    esac
}

_node_cli_module_path() {
    local core="$1" proto="$2"
    case "$core" in
        xray) printf '%s/xray/%s.sh' "$LIB_DIR" "$proto" ;;
        sing-box) printf '%s/singbox/%s.sh' "$LIB_DIR" "$proto" ;;
        mihomo) printf '%s/mihomo/%s.sh' "$LIB_DIR" "$proto" ;;
    esac
}

_node_cli_apply_fn() {
    case "$1/$2" in
        xray/reality) printf '_reality_apply_all' ;;
        xray/vision) printf '_vision_apply_all' ;;
        xray/xhttp) printf '_xhttp_apply_all' ;;
        xray/ss2022) printf '_xss_apply_to_xray' ;;
        sing-box/reality) printf '_sb_reality_apply_all' ;;
        sing-box/ss2022) printf '_sb_ss_apply' ;;
        sing-box/hysteria2) printf '_sb_hy2_apply' ;;
        sing-box/anytls) printf '_sb_anytls_apply' ;;
        sing-box/snell) printf '_sb_snell_apply' ;;
        mihomo/reality) printf '_mh_reality_apply_all' ;;
        mihomo/ss2022) printf '_mh_ss_apply' ;;
        mihomo/hysteria2) printf '_mh_hy2_apply' ;;
        mihomo/anytls) printf '_mh_anytls_apply' ;;
        mihomo/snell) printf '_mh_snell_apply' ;;
        *) return 1 ;;
    esac
}

_node_cli_live_cfg() {
    case "$1" in
        xray) printf '%s/config.json' "$XRAY_CFG_DIR" ;;
        sing-box) printf '%s/config.json' "$SINGBOX_CFG_DIR" ;;
        mihomo) printf '%s/config.yaml' "$MIHOMO_CFG_DIR" ;;
    esac
}

_node_cli_core_bin() {
    case "$1" in
        xray) printf '%s' "$XRAY_BIN" ;;
        sing-box) printf '%s' "$SINGBOX_BIN" ;;
        mihomo) printf '%s' "$MIHOMO_BIN" ;;
    esac
}

_node_cli_read_store() {
    local path="$1"
    [[ -f "$path" ]] || { printf '[]'; return 0; }
    if ! jq -e 'type == "array"' "$path" >/dev/null 2>&1; then
        _node_cli_err "invalid node store (expected a JSON array): $path"
        return 1
    fi
    jq -c '.' "$path"
}

_node_cli_atomic_write() {
    local path="$1" json="$2" dir tmp
    dir=$(dirname "$path")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.node-cli.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if ! printf '%s\n' "$json" | jq -e 'if type == "array" then . else error("not array") end' >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$path"
}

_node_cli_lock_acquire() {
    local lock_root="${CFG_DIR}/.node-cli.lock" owner=""
    mkdir -p "$CFG_DIR" || return 1
    if mkdir "$lock_root" 2>/dev/null; then
        printf '%s\n' "$$" >"$lock_root/pid"
        _NODE_CLI_LOCK="$lock_root"
        return 0
    fi
    [[ -f "$lock_root/pid" ]] && owner=$(sed -n '1p' "$lock_root/pid" 2>/dev/null || true)
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        rm -f "$lock_root/pid" 2>/dev/null || true
        rmdir "$lock_root" 2>/dev/null || true
        if mkdir "$lock_root" 2>/dev/null; then
            printf '%s\n' "$$" >"$lock_root/pid"
            _NODE_CLI_LOCK="$lock_root"
            return 0
        fi
    fi
    _node_cli_err "another node mutation is in progress${owner:+ (pid $owner)}"
    return 1
}

_node_cli_lock_release() {
    [[ -n "$_NODE_CLI_LOCK" ]] || return 0
    rm -f "$_NODE_CLI_LOCK/pid" 2>/dev/null || true
    rmdir "$_NODE_CLI_LOCK" 2>/dev/null || true
    _NODE_CLI_LOCK=""
}

_node_cli_envelope() {
    local core="$1" proto="$2"
    jq -c --arg core "$core" --arg protocol "$proto" '
      map({
        id: ($core + "/" + $protocol + "/" + (.tag // "")),
        core: $core,
        protocol: $protocol,
        tag: (.tag // ""),
        port: (.port // null),
        node: .
      })'
}

_node_cli_collect() {
    local want_core="$1" want_proto="$2" all='[]' core proto path nodes wrapped
    while IFS=$'\t' read -r core proto; do
        [[ -n "$want_core" && "$core" != "$want_core" ]] && continue
        [[ -n "$want_proto" && "$proto" != "$want_proto" ]] && continue
        path=$(_node_cli_store_path "$core" "$proto")
        nodes=$(_node_cli_read_store "$path") || return 1
        wrapped=$(printf '%s' "$nodes" | _node_cli_envelope "$core" "$proto") || return 1
        all=$(jq -cn --argjson a "$all" --argjson b "$wrapped" '$a + $b') || return 1
    done < <(_node_cli_pairs)
    printf '%s' "$all"
}

_node_cli_redact() {
    jq -c '
      def secret_key:
        test("^(password|private_key|psk|uuid|short_id|short_ids|obfs_pass|token|secret)$"; "i");
      def redact:
        if type == "object" then
          with_entries(if (.key | secret_key) then .value = "***" else .value |= redact end)
        elif type == "array" then map(redact)
        else . end;
      redact'
}

_node_cli_maybe_redact() {
    if [[ "$1" == "1" ]]; then jq -c '.'; else _node_cli_redact; fi
}

_node_cli_find() {
    local tag="$1" core="$2" proto="$3" quiet="${4:-0}" all matches count
    all=$(_node_cli_collect "$core" "$proto") || return 1
    matches=$(printf '%s' "$all" | jq -c --arg tag "$tag" '[.[] | select(.tag == $tag)]') || return 1
    count=$(printf '%s' "$matches" | jq 'length')
    if (( count == 0 )); then
        [[ "$quiet" == "1" ]] || _node_cli_err "node not found: $tag"
        return 1
    fi
    if (( count > 1 )); then
        _node_cli_err "node tag is ambiguous: $tag; specify --core and --protocol"
        printf '%s' "$matches" | jq -r '.[] | "  \(.core)/\(.protocol)/\(.tag)"' >&2
        return 1
    fi
    printf '%s' "$matches" | jq -c '.[0]'
}

_node_cli_field_name() {
    case "$1" in
        listen-addr) printf 'listen_addr' ;; public-port) printf 'public_port' ;;
        server-name) printf 'server_name' ;; server-names-raw) printf 'server_names_raw' ;;
        private-key) printf 'private_key' ;; public-key) printf 'public_key' ;;
        short-id) printf 'short_id' ;; short-ids) printf 'short_ids' ;;
        cert-path) printf 'cert_path' ;; key-path) printf 'key_path' ;;
        fallback-enabled) printf 'fallback_enabled' ;; obfs-pass) printf 'obfs_pass' ;;
        obfs-mode) printf 'obfs_mode' ;; obfs-host) printf 'obfs_host' ;;
        *) printf '%s' "$1" ;;
    esac
}

_node_cli_is_field_opt() {
    case "$1" in
        tag|port|uuid|password|method|listen|listen-addr|public-port|domain|sni|flow|dest|path|mode|version|psk|up|down|masquerade|insecure|server-name|server-names-raw|private-key|public-key|short-id|short-ids|cert-path|key-path|fallback-enabled|obfs-pass|obfs-mode|obfs-host) return 0 ;;
        *) return 1 ;;
    esac
}

_node_cli_set_value() {
    local json="$1" key="$2" value="$3" json_mode="${4:-0}"
    if [[ "$json_mode" == "1" ]]; then
        jq -c --arg k "$key" --argjson v "$value" '.[$k] = $v' <<<"$json"
        return
    fi
    jq -c --arg k "$key" --arg v "$value" '
      def typed:
        if ($k | test("^(port|public_port|version|up|down|insecure)$")) then ($v | tonumber)
        elif ($k | test("^(fallback_enabled)$")) then
          if $v == "true" or $v == "1" or $v == "yes" then true
          elif $v == "false" or $v == "0" or $v == "no" then false
          else error("invalid boolean") end
        elif $k == "short_ids" then
          if ($v | startswith("[")) then ($v | fromjson) else [$v] end
        else $v end;
      .[$k] = typed' <<<"$json"
}

_node_cli_load_input() {
    local spec="$1" content
    case "$spec" in
        -) content=$(command cat) ;;
        @*) content=$(command cat "${spec#@}") || return 1 ;;
        *)
            if [[ -f "$spec" ]]; then content=$(command cat "$spec") || return 1
            else content="$spec"
            fi
            ;;
    esac
    if ! printf '%s' "$content" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _node_cli_err "input must be a JSON object"
        return 1
    fi
    printf '%s' "$content" | jq -c '.'
}

_node_cli_ss_password() {
    local method="$1" bytes=16
    case "$method" in *256*|*chacha20*) bytes=32 ;; esac
    openssl rand -base64 "$bytes" | tr -d '\n'
}

_node_cli_keypair() {
    local core="$1" proto="$2" module pair
    module=$(_node_cli_module_path "$core" "$proto")
    # shellcheck source=/dev/null
    source "$module"
    case "$core" in
        xray) pair=$(xray_gen_x25519_keys) || return 1 ;;
        sing-box) pair=$(sb_gen_reality_keys) || return 1 ;;
        mihomo) pair=$(mh_gen_reality_keys) || return 1 ;;
    esac
    printf '%s' "$pair"
}

_node_cli_defaults() {
    local core="$1" proto="$2" json="$3" port method pair private public sid mode
    port=$(printf '%s' "$json" | jq -r '.port // empty')
    json=$(printf '%s' "$json" | jq -c --arg tag_prefix "${core}-${proto}" \
        '.tag //= ($tag_prefix + "-1")') || return 1
    case "$proto" in
        reality)
            json=$(printf '%s' "$json" | jq -c \
                --arg uuid "$(uuid_gen)" --arg sid "$(openssl rand -hex 4)" '
                .uuid //= $uuid |
                .flow //= "xtls-rprx-vision" |
                .short_ids //= [$sid]') || return 1
            # 不给伪装目标兜底默认值。非交互路径没人可问，而任何写死的知名域名都可能
            # 是（或变成）多租户 CDN 前端，那会让 Reality 的回落把本机变成通往整个 CDN
            # 的免费中继。宁可让调用方显式指定，也不静默建出一个有洞的节点。
            local _sn _dest
            _sn=$(printf '%s' "$json"   | jq -r '.server_name // empty')
            _dest=$(printf '%s' "$json" | jq -r '.dest // empty')
            if [[ -z "$_sn" || -z "$_dest" ]]; then
                _node_cli_err "Reality camouflage target is required; pass --server-name and --dest (pick a single-tenant site, ideally in your own ASN — a target behind a shared CDN frontend lets anyone use this host as a free relay)"
                return 1
            fi
            # 与交互流程一致：命中共享前端时告警并给该节点打开回落限速兜底。
            local _dh _dp
            if [[ "$_dest" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
                _dh="${BASH_REMATCH[1]}"; _dp="${BASH_REMATCH[2]}"
            else
                _dh="${_dest%:*}"; _dp="${_dest##*:}"
            fi
            if reality_dest_is_shared_frontend "$_dh" "$_dp"; then
                _node_cli_err "warning: dest ${_dest} is a shared CDN frontend (probe ${REALITY_DEST_SHARED_BY} got a valid certificate on the same IP); enabling REALITY fallback rate limiting for this node"
                json=$(printf '%s' "$json" | jq -c '.limit_fallback = true') || return 1
            fi
            if [[ "$core" == "xray" ]]; then
                json=$(printf '%s' "$json" | jq -c --arg p "$port" '
                  .listen_addr //= "0.0.0.0" |
                  .public_port //= ($p | tonumber) |
                  .server_names_raw //= .server_name') || return 1
            elif [[ "$core" == "mihomo" ]]; then
                json=$(printf '%s' "$json" | jq -c '.listen_addr //= "0.0.0.0"') || return 1
            else
                json=$(printf '%s' "$json" | jq -c '.listen_addr //= "::"') || return 1
            fi
            private=$(printf '%s' "$json" | jq -r '.private_key // empty')
            public=$(printf '%s' "$json" | jq -r '.public_key // empty')
            if [[ -z "$private" || -z "$public" ]]; then
                pair=$(_node_cli_keypair "$core" "$proto") || {
                    _node_cli_err "Reality keys are missing and $core could not generate them; pass --private-key and --public-key"
                    return 1
                }
                private=${pair%%$'\t'*}; public=${pair#*$'\t'}
                json=$(printf '%s' "$json" | jq -c --arg private "$private" --arg public "$public" \
                    '.private_key=$private | .public_key=$public') || return 1
            fi
            ;;
        vision)
            json=$(printf '%s' "$json" | jq -c --arg uuid "$(uuid_gen)" --arg p "$port" '
              .uuid //= $uuid | .flow //= "xtls-rprx-vision" |
              .listen_addr //= "0.0.0.0" | .public_port //= ($p | tonumber) |
              .fallback_enabled //= false') || return 1
            ;;
        xhttp)
            json=$(printf '%s' "$json" | jq -c --arg uuid "$(uuid_gen)" --arg p "$port" --arg path "$(rand_path)" '
              .uuid //= $uuid | .mode //= "xhttp" | .path //= $path |
              .domain //= "" | .listen_addr //= "0.0.0.0" |
              .public_port //= ($p | tonumber) | .fallback_enabled //= false') || return 1
            mode=$(printf '%s' "$json" | jq -r '.mode')
            if [[ "$mode" == "reality-layer" ]]; then
                sid=$(openssl rand -hex 4)
                json=$(printf '%s' "$json" | jq -c --arg sid "$sid" '.short_id //= $sid') || return 1
                # 与 reality 同理：reality-layer 的 dest 就是 server_name:443，不给兜底默认值。
                local _xsn; _xsn=$(printf '%s' "$json" | jq -r '.server_name // empty')
                if [[ -z "$_xsn" ]]; then
                    _node_cli_err "XHTTP reality-layer camouflage target is required; pass --server-name (its dest is <server-name>:443 — pick a single-tenant site, ideally in your own ASN)"
                    return 1
                fi
                if reality_dest_is_shared_frontend "$_xsn" 443; then
                    _node_cli_err "warning: server-name ${_xsn} is a shared CDN frontend (probe ${REALITY_DEST_SHARED_BY} got a valid certificate on the same IP); enabling REALITY fallback rate limiting for this node"
                    json=$(printf '%s' "$json" | jq -c '.limit_fallback = true') || return 1
                fi
                private=$(printf '%s' "$json" | jq -r '.private_key // empty')
                public=$(printf '%s' "$json" | jq -r '.public_key // empty')
                if [[ -z "$private" || -z "$public" ]]; then
                    pair=$(_node_cli_keypair xray xhttp) || {
                        _node_cli_err "XHTTP Reality keys are missing and Xray could not generate them"
                        return 1
                    }
                    private=${pair%%$'\t'*}; public=${pair#*$'\t'}
                    json=$(printf '%s' "$json" | jq -c --arg private "$private" --arg public "$public" \
                        '.private_key=$private | .public_key=$public') || return 1
                fi
            fi
            ;;
        ss2022)
            method=$(printf '%s' "$json" | jq -r '.method // "2022-blake3-aes-128-gcm"')
            json=$(printf '%s' "$json" | jq -c --arg method "$method" --arg password "$(_node_cli_ss_password "$method")" '
              .method //= $method | .password //= $password') || return 1
            if [[ "$core" == "xray" ]]; then
                json=$(printf '%s' "$json" | jq -c '.listen //= "0.0.0.0"') || return 1
            else
                json=$(printf '%s' "$json" | jq -c '.listen //= "::"') || return 1
            fi
            ;;
        hysteria2)
            json=$(printf '%s' "$json" | jq -c --arg password "$(rand_str 24)" '
              .password //= $password | .insecure //= 0 | .up //= 0 | .down //= 0 |
              .masquerade //= "https://www.bing.com" | .obfs_pass //= "" | .domain //= ""') || return 1
            ;;
        anytls)
            json=$(printf '%s' "$json" | jq -c --arg password "$(rand_str 20)" '
              .password //= $password | .insecure //= 0 | .domain //= ""') || return 1
            ;;
        snell)
            local snell_default=4
            [[ "$core" == "sing-box" ]] && snell_default=5
            json=$(printf '%s' "$json" | jq -c --arg psk "$(rand_str 24)" --argjson version "$snell_default" '
              .version //= $version | .psk //= $psk | .listen //= "::" |
              .obfs_mode //= "" | .obfs_host //= ""') || return 1
            ;;
    esac
    printf '%s' "$json"
}

_node_cli_validate() {
    local core="$1" proto="$2" json="$3" context="${4:-update}" mode method
    if ! printf '%s' "$json" | jq -e '
        type == "object" and
        (.tag | type == "string" and length > 0 and length <= 128) and
        (.port | type == "number" and floor == . and . >= 1 and . <= 65535)' >/dev/null; then
        _node_cli_err "node requires a non-empty tag and an integer port in 1..65535"
        return 1
    fi
    if ! printf '%s' "$json" | jq -e --arg proto "$proto" '
      if $proto == "reality" then
        ([.uuid,.private_key,.public_key,.server_name,.dest,.flow] | all(type == "string" and length > 0)) and
        (.short_ids | type == "array" and length > 0)
      elif $proto == "vision" then
        ([.uuid,.domain,.flow,.listen_addr] | all(type == "string" and length > 0)) and
        (.public_port | type == "number") and (.fallback_enabled | type == "boolean")
      elif $proto == "xhttp" then
        ([.uuid,.mode,.path,.listen_addr] | all(type == "string" and length > 0)) and
        (.public_port | type == "number") and (.fallback_enabled | type == "boolean") and
        (if .mode == "reality-layer" then
           ([.private_key,.public_key,.short_id,.server_name] | all(type == "string" and length > 0))
         else (.domain | type == "string" and length > 0) end)
      elif $proto == "ss2022" then
        ([.method,.password,.listen] | all(type == "string" and length > 0))
      elif $proto == "hysteria2" then
        ([.password,.sni,.cert_path,.key_path] | all(type == "string" and length > 0)) and
        (.insecure | type == "number" or type == "boolean")
      elif $proto == "anytls" then
        ([.password,.sni,.cert_path,.key_path] | all(type == "string" and length > 0)) and
        (.insecure | type == "number" or type == "boolean")
      elif $proto == "snell" then
        ([.psk,.listen] | all(type == "string" and length > 0)) and
        (.version | type == "number")
      else false end' >/dev/null; then
        _node_cli_err "node does not satisfy the $core/$proto schema; use --help for input options"
        return 1
    fi
    case "$proto" in
        ss2022)
            method=$(printf '%s' "$json" | jq -r '.method')
            case "$method" in
                2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;;
                *) _node_cli_err "unsupported SS2022 method: $method"; return 1 ;;
            esac
            ;;
        snell)
            if ! printf '%s' "$json" | jq -e --arg core "$core" '
              if $core == "sing-box" then (.version == 5 or .version == 6)
              else (.version == 4 or .version == 5) end' >/dev/null; then
                _node_cli_err "unsupported Snell version for $core"
                return 1
            fi
            ;;
        xhttp)
            mode=$(printf '%s' "$json" | jq -r '.mode')
            case "$mode" in xhttp|upgrade|ws|grpc|reality-layer) ;; *) _node_cli_err "unsupported XHTTP mode: $mode"; return 1 ;; esac
            ;;
    esac
    # Creating a loopback listener also requires transactional Nginx SNI
    # map/certificate changes. Keep that cross-module workflow interactive.
    if [[ "$context" == "add" ]] && _node_cli_fronted_pair "$core" "$proto" \
        && [[ "$(printf '%s' "$json" | jq -r '.listen_addr // ""')" == "127.0.0.1" ]]; then
        _node_cli_err "creating an Nginx-fronted $core node is not supported non-interactively; use a direct listen_addr or the interactive menu"
        return 1
    fi
    return 0
}

_node_cli_validate_update_side_effects() {
    local core="$1" proto="$2" old="$3" new="$4"
    _node_cli_fronted_pair "$core" "$proto" || return 0
    if printf '%s' "$old" | jq -e '.listen_addr == "127.0.0.1"' >/dev/null 2>&1 \
        || printf '%s' "$new" | jq -e '.listen_addr == "127.0.0.1"' >/dev/null 2>&1; then
        if ! jq -en --argjson old "$old" --argjson new "$new" --arg proto "$proto" '
          if $proto == "reality" then
            [$old.listen_addr,$old.port,$old.server_name] == [$new.listen_addr,$new.port,$new.server_name]
          elif $proto == "vision" then
            [$old.listen_addr,$old.port,$old.domain] == [$new.listen_addr,$new.port,$new.domain]
          elif $proto == "anytls" then
            [$old.listen_addr,$old.port,$old.sni] == [$new.listen_addr,$new.port,$new.sni]
          else
            [$old.listen_addr,$old.port,$old.domain,$old.server_name] ==
            [$new.listen_addr,$new.port,$new.domain,$new.server_name]
          end' >/dev/null; then
            _node_cli_err "changing Nginx routing fields on a loopback $core node is not supported non-interactively; use the interactive menu"
            return 1
        fi
    fi
}

_node_cli_check_port_conflict() {
    local core="$1" proto="$2" tag="$3" port="$4" all conflict transport
    transport=$(_node_cli_transport "$proto")
    # Listener ports are machine-wide, not core-local. TCP and UDP namespaces
    # are independent, however, so Reality:443/tcp may coexist with HY2:443/udp.
    all=$(_node_cli_collect "" "") || return 1
    conflict=$(printf '%s' "$all" | jq -r \
      --arg core "$core" --arg proto "$proto" --arg tag "$tag" \
      --arg transport "$transport" --argjson port "$port" '
      def transport: if .protocol == "hysteria2" then "udp" else "tcp" end;
      first(.[] | select(
        .port == $port and transport == $transport and
        ((.core != $core) or (.protocol != $proto) or (.tag != $tag))
      ) | .id) // empty')
    if [[ -n "$conflict" ]]; then
        _node_cli_err "port $port is already used by $conflict"
        return 1
    fi
}

_node_cli_transport() {
    [[ "$1" == "hysteria2" ]] && printf udp || printf tcp
}

# Core/protocol pairs that support Nginx 443 SNI fronting (listen_addr
# 127.0.0.1 + shared SNI map). Mutating those non-interactively would require
# transactional Nginx map/certificate changes, so the CLI refuses them.
_node_cli_fronted_pair() {
    case "$1/$2" in
        xray/reality|xray/vision|xray/xhttp) return 0 ;;
        sing-box/reality|sing-box/anytls)    return 0 ;;
        mihomo/reality|mihomo/anytls)        return 0 ;;
        *) return 1 ;;
    esac
}

_node_cli_port_is_listening() {
    local port="$1" transport="$2"
    if command -v ss >/dev/null 2>&1; then
        if [[ "$transport" == "udp" ]]; then
            ss -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
        else
            ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
        fi
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        if [[ "$transport" == "udp" ]]; then
            netstat -anu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
        else
            netstat -ant 2>/dev/null | awk '$6 == "LISTEN" {print $4}' | grep -qE "[:.]${port}$"
        fi
        return
    fi
    return 1
}

_node_cli_restart_old_cfg() {
    case "$1" in
        xray) xray_test_restart >&2 || true ;;
        sing-box) sb_test_restart >&2 || true ;;
        mihomo) mh_test_restart >&2 || true ;;
    esac
}

_node_cli_commit_store() {
    local core="$1" proto="$2" new_store="$3" store_only="$4"
    local path module apply live bin old_store existed=0 live_backup="" ok=0
    path=$(_node_cli_store_path "$core" "$proto")
    old_store=$(_node_cli_read_store "$path") || return 1
    [[ -f "$path" ]] && existed=1

    if [[ "$store_only" != "1" ]]; then
        module=$(_node_cli_module_path "$core" "$proto")
        apply=$(_node_cli_apply_fn "$core" "$proto") || return 1
        live=$(_node_cli_live_cfg "$core")
        bin=$(_node_cli_core_bin "$core")
        [[ -x "$bin" ]] || { _node_cli_err "$core is not installed: $bin"; return 1; }
        [[ -f "$live" ]] || { _node_cli_err "$core config does not exist: $live"; return 1; }
        live_backup=$(mktemp) || return 1
        cp -a "$live" "$live_backup" || { rm -f "$live_backup"; return 1; }
        # shellcheck source=/dev/null
        source "$module"
    fi

    if ! _node_cli_atomic_write "$path" "$new_store"; then
        _node_cli_err "failed to write node store: $path"
        [[ -n "$live_backup" ]] && rm -f "$live_backup"
        return 1
    fi

    if [[ "$store_only" == "1" ]]; then return 0; fi
    if "$apply" >&2; then
        ok=1
    else
        _node_cli_err "apply failed; restoring node store and live config"
        if (( existed )); then _node_cli_atomic_write "$path" "$old_store" || true
        else rm -f "$path"
        fi
        cp -a "$live_backup" "$live" 2>/dev/null || true
        _node_cli_restart_old_cfg "$core"
    fi
    rm -f "$live_backup"
    (( ok == 1 ))
}

_node_cli_cleanup_deleted_metadata() {
    local tag="$1"
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        # shellcheck source=/dev/null
        source "$LIB_DIR/traffic.sh" 2>/dev/null || return 0
        _trf_init 2>/dev/null || true
        _trf_cleanup_node "$tag" 2>/dev/null || true
    fi
}

_node_cli_result() {
    local status="$1" envelope="$2" as_json="$3" show_secrets="$4"
    if [[ "$as_json" == "1" ]]; then
        printf '%s' "$envelope" | _node_cli_maybe_redact "$show_secrets" | \
            jq -c --arg status "$status" --argjson version "$_NODE_CLI_VERSION" \
            '{status:$status, api_version:$version, item:.}'
    else
        printf '%s: %s\n' "$status" "$(printf '%s' "$envelope" | jq -r '.id')"
    fi
}

_node_cli_require_root_unless_store_only() {
    local state="$1"
    [[ "$(printf '%s' "$state" | jq -r '.store_only')" == "true" ]] && return 0
    if (( EUID != 0 )); then
        _node_cli_err 'applying node changes requires root; use --store-only only for offline provisioning/tests'
        return 1
    fi
}

_node_cli_cmd_list() {
    local core="" proto="" as_json=0 show_secrets=0 all
    while (( $# )); do
        case "$1" in
            --core) [[ $# -ge 2 ]] || { _node_cli_err '--core requires a value'; return 2; }; core=$(_node_cli_norm_core "$2") || { _node_cli_err "unknown core: $2"; return 2; }; shift 2 ;;
            --protocol) [[ $# -ge 2 ]] || { _node_cli_err '--protocol requires a value'; return 2; }; proto=$(_node_cli_norm_protocol "$2") || { _node_cli_err "unknown protocol: $2"; return 2; }; shift 2 ;;
            --json) as_json=1; shift ;;
            --show-secrets) show_secrets=1; shift ;;
            --help|-h) _node_cli_usage; return 0 ;;
            *) _node_cli_err "unknown list option: $1"; return 2 ;;
        esac
    done
    if [[ -n "$core" && -n "$proto" ]] && ! _node_cli_pair_supported "$core" "$proto"; then
        _node_cli_err "unsupported core/protocol: $core/$proto"; return 2
    fi
    all=$(_node_cli_collect "$core" "$proto") || return 1
    if [[ "$as_json" == "1" ]]; then
        printf '%s' "$all" | _node_cli_maybe_redact "$show_secrets" | jq -c \
            --argjson version "$_NODE_CLI_VERSION" '{api_version:$version, count:length, items:.}'
        return
    fi
    printf '%-10s %-12s %-28s %-7s\n' CORE PROTOCOL TAG PORT
    printf '%s' "$all" | jq -r '.[] | [.core,.protocol,.tag,(.port // "-")] | @tsv' | \
        while IFS=$'\t' read -r c p t po; do printf '%-10s %-12s %-28s %-7s\n' "$c" "$p" "$t" "$po"; done
}

_node_cli_cmd_show() {
    local tag="" core="" proto="" as_json=0 show_secrets=0 item display positional_core positional_proto
    if (( $# >= 3 )) && positional_core=$(_node_cli_norm_core "$1" 2>/dev/null) \
        && positional_proto=$(_node_cli_norm_protocol "$2" 2>/dev/null) \
        && _node_cli_pair_supported "$positional_core" "$positional_proto"; then
        core="$positional_core"; proto="$positional_proto"; tag="$3"; shift 3
    else
        tag="${1:-}"; shift || true
    fi
    [[ -n "$tag" && "$tag" != --* ]] || { _node_cli_err 'show requires TAG'; return 2; }
    while (( $# )); do
        case "$1" in
            --core) core=$(_node_cli_norm_core "${2:-}") || { _node_cli_err "unknown core: ${2:-}"; return 2; }; shift 2 ;;
            --protocol) proto=$(_node_cli_norm_protocol "${2:-}") || { _node_cli_err "unknown protocol: ${2:-}"; return 2; }; shift 2 ;;
            --json) as_json=1; shift ;;
            --show-secrets) show_secrets=1; shift ;;
            *) _node_cli_err "unknown show option: $1"; return 2 ;;
        esac
    done
    item=$(_node_cli_find "$tag" "$core" "$proto") || return 1
    display=$(printf '%s' "$item" | _node_cli_maybe_redact "$show_secrets") || return 1
    if [[ "$as_json" == "1" ]]; then
        printf '%s' "$display" | jq -c --argjson version "$_NODE_CLI_VERSION" '{api_version:$version,item:.}'
    else
        printf '%s\n' "$display" | jq -r '
          "ID:       \(.id)",
          "Core:     \(.core)",
          "Protocol: \(.protocol)",
          (.node | to_entries[] | "\(.key): \(.value | if type == "array" or type == "object" then tojson else tostring end)")'
    fi
}

_node_cli_parse_mutation() {
    # Outputs a shell-safe JSON parser state consumed by add/update. Positional
    # tag is passed as $1 (possibly empty), remaining arguments follow.
    local tag="$1"; shift
    local core="" proto="" input="" store_only=0 replace=0 if_exists=0 yes=0 as_json=0 show_secrets=0
    local json='{}' arg key value
    local -a sets=() sets_json=() unsets=()
    while (( $# )); do
        arg="$1"
        case "$arg" in
            --core) [[ $# -ge 2 ]] || { _node_cli_err '--core requires a value'; return 2; }; core=$(_node_cli_norm_core "$2") || { _node_cli_err "unknown core: $2"; return 2; }; shift 2 ;;
            --protocol) [[ $# -ge 2 ]] || { _node_cli_err '--protocol requires a value'; return 2; }; proto=$(_node_cli_norm_protocol "$2") || { _node_cli_err "unknown protocol: $2"; return 2; }; shift 2 ;;
            --input) [[ $# -ge 2 ]] || { _node_cli_err '--input requires FILE or -'; return 2; }; input="$2"; shift 2 ;;
            --data) [[ $# -ge 2 ]] || { _node_cli_err '--data requires JSON or @FILE'; return 2; }; input="$2"; shift 2 ;;
            --set) [[ $# -ge 2 && "$2" == *=* ]] || { _node_cli_err '--set requires KEY=VALUE'; return 2; }; sets+=("$2"); shift 2 ;;
            --set-json) [[ $# -ge 2 && "$2" == *=* ]] || { _node_cli_err '--set-json requires KEY=JSON'; return 2; }; sets_json+=("$2"); shift 2 ;;
            --unset) [[ $# -ge 2 ]] || { _node_cli_err '--unset requires KEY'; return 2; }; unsets+=("$2"); shift 2 ;;
            --store-only|--no-apply) store_only=1; shift ;;
            --replace) replace=1; shift ;;
            --if-exists) if_exists=1; shift ;;
            --yes|-y) yes=1; shift ;;
            --json) as_json=1; shift ;;
            --show-secrets) show_secrets=1; shift ;;
            --tag) [[ $# -ge 2 ]] || { _node_cli_err '--tag requires a value'; return 2; }; tag="$2"; shift 2 ;;
            --*)
                key=${arg#--}
                if ! _node_cli_is_field_opt "$key"; then _node_cli_err "unknown option: $arg"; return 2; fi
                [[ $# -ge 2 ]] || { _node_cli_err "$arg requires a value"; return 2; }
                sets+=("$(_node_cli_field_name "$key")=$2"); shift 2
                ;;
            *)
                if [[ -z "$tag" ]]; then tag="$arg"; shift
                else _node_cli_err "unexpected argument: $arg"; return 2
                fi
                ;;
        esac
    done
    if [[ -n "$input" ]]; then
        json=$(_node_cli_load_input "$input") || return 2
    fi
    [[ -n "$tag" ]] && json=$(_node_cli_set_value "$json" tag "$tag") || true
    for arg in "${sets[@]}"; do
        key=${arg%%=*}; value=${arg#*=}
        key=$(_node_cli_field_name "$key")
        json=$(_node_cli_set_value "$json" "$key" "$value") || { _node_cli_err "invalid value for $key"; return 2; }
    done
    for arg in "${sets_json[@]}"; do
        key=${arg%%=*}; value=${arg#*=}
        key=$(_node_cli_field_name "$key")
        json=$(_node_cli_set_value "$json" "$key" "$value" 1) || { _node_cli_err "invalid JSON value for $key"; return 2; }
    done
    for key in "${unsets[@]}"; do
        key=$(_node_cli_field_name "$key")
        json=$(printf '%s' "$json" | jq -c --arg k "$key" 'del(.[$k])') || return 2
    done
    jq -cn --arg core "$core" --arg proto "$proto" --argjson node "$json" \
        --argjson store_only "$store_only" --argjson replace "$replace" \
        --argjson if_exists "$if_exists" --argjson yes "$yes" --argjson out_json "$as_json" \
        --argjson show_secrets "$show_secrets" \
        '{core:$core,protocol:$proto,node:$node,
          store_only:($store_only == 1), replace:($replace == 1),
          if_exists:($if_exists == 1), yes:($yes == 1), json:($out_json == 1),
          show_secrets:($show_secrets == 1)}'
}

_node_cli_cmd_add() {
    local state core proto node path old existing tag port new envelope changed
    if (( $# >= 2 )) && core=$(_node_cli_norm_core "$1" 2>/dev/null) \
        && proto=$(_node_cli_norm_protocol "$2" 2>/dev/null) \
        && _node_cli_pair_supported "$core" "$proto"; then
        shift 2
        set -- --core "$core" --protocol "$proto" "$@"
    fi
    state=$(_node_cli_parse_mutation "" "$@") || return $?
    _node_cli_require_root_unless_store_only "$state" || return 1
    core=$(printf '%s' "$state" | jq -r '.core'); proto=$(printf '%s' "$state" | jq -r '.protocol')
    [[ -n "$core" && -n "$proto" ]] || { _node_cli_err 'add requires --core and --protocol'; return 2; }
    _node_cli_pair_supported "$core" "$proto" || { _node_cli_err "unsupported core/protocol: $core/$proto"; return 2; }
    node=$(printf '%s' "$state" | jq -c '.node')
    if ! printf '%s' "$node" | jq -e '.port != null' >/dev/null; then _node_cli_err 'add requires --port or input.port'; return 2; fi
    _node_cli_lock_acquire || return 1
    path=$(_node_cli_store_path "$core" "$proto")
    old=$(_node_cli_read_store "$path") || { _node_cli_lock_release; return 1; }
    tag=$(printf '%s' "$node" | jq -r --arg fallback "${core}-${proto}-1" '.tag // $fallback')
    existing=$(printf '%s' "$old" | jq -c --arg tag "$tag" 'first(.[] | select(.tag == $tag)) // empty')
    # Preserve generated credentials on retries. An add request that repeats the
    # desired public fields therefore resolves to the exact existing node.
    [[ -n "$existing" ]] && node=$(jq -cn --argjson old "$existing" --argjson patch "$node" '$old * $patch')
    node=$(_node_cli_defaults "$core" "$proto" "$node") || { _node_cli_lock_release; return 1; }
    _node_cli_validate "$core" "$proto" "$node" add || { _node_cli_lock_release; return 2; }
    tag=$(printf '%s' "$node" | jq -r '.tag'); port=$(printf '%s' "$node" | jq -r '.port')
    if [[ -n "$existing" ]]; then
        if jq -e --argjson a "$existing" --argjson b "$node" -n '$a == $b' >/dev/null; then
            _node_cli_lock_release
            envelope=$(printf '[%s]' "$existing" | _node_cli_envelope "$core" "$proto" | jq -c '.[0]')
            _node_cli_result unchanged "$envelope" "$(printf '%s' "$state" | jq -r '.json|if . then 1 else 0 end')" "$(printf '%s' "$state" | jq -r '.show_secrets|if . then 1 else 0 end')"
            return 0
        fi
        if [[ "$(printf '%s' "$state" | jq -r '.replace')" != "true" ]]; then
            _node_cli_lock_release; _node_cli_err "node already exists with different data: $core/$proto/$tag (use --replace)"; return 1
        fi
    fi
    _node_cli_check_port_conflict "$core" "$proto" "$tag" "$port" || { _node_cli_lock_release; return 1; }
    if [[ -z "$existing" && "$(printf '%s' "$state" | jq -r '.store_only')" != "true" ]] \
        && _node_cli_port_is_listening "$port" "$(_node_cli_transport "$proto")"; then
        _node_cli_lock_release
        _node_cli_err "$(_node_cli_transport "$proto") port $port is already held by a running process"
        return 1
    fi
    new=$(printf '%s' "$old" | jq -c --arg tag "$tag" --argjson node "$node" 'del(.[] | select(.tag == $tag)) + [$node]') || { _node_cli_lock_release; return 1; }
    _node_cli_commit_store "$core" "$proto" "$new" "$(printf '%s' "$state" | jq -r '.store_only|if . then 1 else 0 end')" || { _node_cli_lock_release; return 1; }
    _node_cli_lock_release
    envelope=$(printf '[%s]' "$node" | _node_cli_envelope "$core" "$proto" | jq -c '.[0]')
    changed=created; [[ -n "$existing" ]] && changed=replaced
    _node_cli_result "$changed" "$envelope" "$(printf '%s' "$state" | jq -r '.json|if . then 1 else 0 end')" "$(printf '%s' "$state" | jq -r '.show_secrets|if . then 1 else 0 end')"
}

_node_cli_cmd_update() {
    local tag="" state filter_core filter_proto item core proto old_node patch node path store new port envelope positional_core positional_proto
    if (( $# >= 3 )) && positional_core=$(_node_cli_norm_core "$1" 2>/dev/null) \
        && positional_proto=$(_node_cli_norm_protocol "$2" 2>/dev/null) \
        && _node_cli_pair_supported "$positional_core" "$positional_proto"; then
        tag="$3"; shift 3
        set -- --core "$positional_core" --protocol "$positional_proto" "$@"
    else
        tag="${1:-}"; shift || true
    fi
    [[ -n "$tag" && "$tag" != --* ]] || { _node_cli_err 'update requires TAG'; return 2; }
    state=$(_node_cli_parse_mutation "$tag" "$@") || return $?
    _node_cli_require_root_unless_store_only "$state" || return 1
    filter_core=$(printf '%s' "$state" | jq -r '.core'); filter_proto=$(printf '%s' "$state" | jq -r '.protocol')
    item=$(_node_cli_find "$tag" "$filter_core" "$filter_proto") || return 1
    core=$(printf '%s' "$item" | jq -r '.core'); proto=$(printf '%s' "$item" | jq -r '.protocol')
    old_node=$(printf '%s' "$item" | jq -c '.node'); patch=$(printf '%s' "$state" | jq -c '.node | del(.tag)')
    node=$(jq -cn --argjson old "$old_node" --argjson patch "$patch" '$old * $patch') || return 1
    _node_cli_validate_update_side_effects "$core" "$proto" "$old_node" "$node" || return 2
    _node_cli_validate "$core" "$proto" "$node" update || return 2
    port=$(printf '%s' "$node" | jq -r '.port')
    if jq -e --argjson a "$old_node" --argjson b "$node" -n '$a == $b' >/dev/null; then
        _node_cli_result unchanged "$item" "$(printf '%s' "$state" | jq -r '.json|if . then 1 else 0 end')" "$(printf '%s' "$state" | jq -r '.show_secrets|if . then 1 else 0 end')"
        return 0
    fi
    _node_cli_lock_acquire || return 1
    _node_cli_check_port_conflict "$core" "$proto" "$tag" "$port" || { _node_cli_lock_release; return 1; }
    path=$(_node_cli_store_path "$core" "$proto"); store=$(_node_cli_read_store "$path") || { _node_cli_lock_release; return 1; }
    # Re-check under lock to avoid overwriting a concurrent change.
    if ! printf '%s' "$store" | jq -e --arg tag "$tag" --argjson old "$old_node" 'first(.[] | select(.tag == $tag)) == $old' >/dev/null; then
        _node_cli_lock_release; _node_cli_err "node changed concurrently: $core/$proto/$tag"; return 1
    fi
    new=$(printf '%s' "$store" | jq -c --arg tag "$tag" --argjson node "$node" 'map(if .tag == $tag then $node else . end)') || { _node_cli_lock_release; return 1; }
    _node_cli_commit_store "$core" "$proto" "$new" "$(printf '%s' "$state" | jq -r '.store_only|if . then 1 else 0 end')" || { _node_cli_lock_release; return 1; }
    _node_cli_lock_release
    envelope=$(printf '[%s]' "$node" | _node_cli_envelope "$core" "$proto" | jq -c '.[0]')
    _node_cli_result updated "$envelope" "$(printf '%s' "$state" | jq -r '.json|if . then 1 else 0 end')" "$(printf '%s' "$state" | jq -r '.show_secrets|if . then 1 else 0 end')"
}

_node_cli_cmd_delete() {
    local tag="" state core_filter proto_filter item core proto path store old_node new envelope positional_core positional_proto
    if (( $# >= 3 )) && positional_core=$(_node_cli_norm_core "$1" 2>/dev/null) \
        && positional_proto=$(_node_cli_norm_protocol "$2" 2>/dev/null) \
        && _node_cli_pair_supported "$positional_core" "$positional_proto"; then
        tag="$3"; shift 3
        set -- --core "$positional_core" --protocol "$positional_proto" "$@"
    else
        tag="${1:-}"; shift || true
    fi
    [[ -n "$tag" && "$tag" != --* ]] || { _node_cli_err 'delete requires TAG'; return 2; }
    state=$(_node_cli_parse_mutation "$tag" "$@") || return $?
    _node_cli_require_root_unless_store_only "$state" || return 1
    if [[ "$(printf '%s' "$state" | jq -r '.yes')" != "true" ]]; then _node_cli_err 'delete requires --yes'; return 2; fi
    core_filter=$(printf '%s' "$state" | jq -r '.core'); proto_filter=$(printf '%s' "$state" | jq -r '.protocol')
    if ! item=$(_node_cli_find "$tag" "$core_filter" "$proto_filter" \
        "$([[ "$(printf '%s' "$state" | jq -r '.if_exists')" == "true" ]] && printf 1 || printf 0)"); then
        if [[ "$(printf '%s' "$state" | jq -r '.if_exists')" == "true" ]]; then
            if [[ "$(printf '%s' "$state" | jq -r '.json')" == "true" ]]; then jq -cn --arg tag "$tag" '{status:"absent",tag:$tag}'; else printf 'absent: %s\n' "$tag"; fi
            return 0
        fi
        return 1
    fi
    core=$(printf '%s' "$item" | jq -r '.core'); proto=$(printf '%s' "$item" | jq -r '.protocol'); old_node=$(printf '%s' "$item" | jq -c '.node')
    if [[ "$(printf '%s' "$state" | jq -r '.store_only')" != "true" ]] \
        && _node_cli_fronted_pair "$core" "$proto" \
        && printf '%s' "$old_node" | jq -e '.listen_addr == "127.0.0.1"' >/dev/null 2>&1; then
        _node_cli_err "deleting an Nginx-fronted $core node is not supported non-interactively; use the interactive menu"
        return 2
    fi
    _node_cli_lock_acquire || return 1
    path=$(_node_cli_store_path "$core" "$proto"); store=$(_node_cli_read_store "$path") || { _node_cli_lock_release; return 1; }
    if ! printf '%s' "$store" | jq -e --arg tag "$tag" --argjson old "$old_node" 'first(.[] | select(.tag == $tag)) == $old' >/dev/null; then
        _node_cli_lock_release; _node_cli_err "node changed concurrently: $core/$proto/$tag"; return 1
    fi
    new=$(printf '%s' "$store" | jq -c --arg tag "$tag" 'del(.[] | select(.tag == $tag))') || { _node_cli_lock_release; return 1; }
    _node_cli_commit_store "$core" "$proto" "$new" "$(printf '%s' "$state" | jq -r '.store_only|if . then 1 else 0 end')" || { _node_cli_lock_release; return 1; }
    _node_cli_lock_release
    _node_cli_cleanup_deleted_metadata "$tag"
    envelope=$(printf '[%s]' "$old_node" | _node_cli_envelope "$core" "$proto" | jq -c '.[0]')
    _node_cli_result deleted "$envelope" "$(printf '%s' "$state" | jq -r '.json|if . then 1 else 0 end')" "$(printf '%s' "$state" | jq -r '.show_secrets|if . then 1 else 0 end')"
}

_node_cli_urlencode() { jq -nr --arg v "$1" '$v | @uri'; }

_node_cli_ss_userinfo() {
    printf '%s' "$1:$2" | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

_node_cli_export_uri() {
    local core="$1" proto="$2" n="$3" server="$4"
    local tag port uuid flow sn pbk sid mode path domain method password sni insecure obfs psk version
    tag=$(printf '%s' "$n" | jq -r '.tag'); port=$(printf '%s' "$n" | jq -r '.public_port // .port')
    case "$proto" in
        reality)
            uuid=$(printf '%s' "$n" | jq -r '.uuid'); flow=$(printf '%s' "$n" | jq -r '.flow'); sn=$(printf '%s' "$n" | jq -r '.server_name')
            pbk=$(printf '%s' "$n" | jq -r '.public_key'); sid=$(printf '%s' "$n" | jq -r '.short_ids[0]')
            printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
                "$uuid" "$server" "$port" "$(_node_cli_urlencode "$flow")" "$(_node_cli_urlencode "$sn")" \
                "$(_node_cli_urlencode "$pbk")" "$(_node_cli_urlencode "$sid")" "$(_node_cli_urlencode "PSM-$tag")"
            ;;
        vision)
            uuid=$(printf '%s' "$n" | jq -r '.uuid'); flow=$(printf '%s' "$n" | jq -r '.flow'); domain=$(printf '%s' "$n" | jq -r '.domain')
            printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=tls&sni=%s&type=tcp#%s\n' \
                "$uuid" "$server" "$port" "$(_node_cli_urlencode "$flow")" "$(_node_cli_urlencode "$domain")" "$(_node_cli_urlencode "PSM-$tag")"
            ;;
        xhttp)
            uuid=$(printf '%s' "$n" | jq -r '.uuid'); mode=$(printf '%s' "$n" | jq -r '.mode'); path=$(printf '%s' "$n" | jq -r '.path'); domain=$(printf '%s' "$n" | jq -r '.domain // ""')
            if [[ "$mode" == "reality-layer" ]]; then
                sn=$(printf '%s' "$n" | jq -r '.server_name'); pbk=$(printf '%s' "$n" | jq -r '.public_key'); sid=$(printf '%s' "$n" | jq -r '.short_id')
                printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s&mode=auto#%s\n' \
                    "$uuid" "$server" "$port" "$(_node_cli_urlencode "$sn")" "$(_node_cli_urlencode "$pbk")" "$(_node_cli_urlencode "$sid")" "$(_node_cli_urlencode "$path")" "$(_node_cli_urlencode "PSM-$tag")"
            elif [[ "$mode" == "grpc" ]]; then
                printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=grpc&serviceName=%s#%s\n' \
                    "$uuid" "$server" "$port" "$(_node_cli_urlencode "$domain")" "$(_node_cli_urlencode "${path#/}")" "$(_node_cli_urlencode "PSM-$tag")"
            elif [[ "$mode" == "upgrade" || "$mode" == "ws" ]]; then
                printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&path=%s#%s\n' \
                    "$uuid" "$server" "$port" "$(_node_cli_urlencode "$domain")" "$(_node_cli_urlencode "$path")" "$(_node_cli_urlencode "PSM-$tag")"
            else
                printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=xhttp&path=%s&mode=auto#%s\n' \
                    "$uuid" "$server" "$port" "$(_node_cli_urlencode "$domain")" "$(_node_cli_urlencode "$path")" "$(_node_cli_urlencode "PSM-$tag")"
            fi
            ;;
        ss2022)
            method=$(printf '%s' "$n" | jq -r '.method'); password=$(printf '%s' "$n" | jq -r '.password')
            printf 'ss://%s@%s:%s#%s\n' "$(_node_cli_ss_userinfo "$method" "$password")" "$server" "$port" "$(_node_cli_urlencode "PSM-$tag")"
            ;;
        hysteria2)
            password=$(printf '%s' "$n" | jq -r '.password'); sni=$(printf '%s' "$n" | jq -r '.sni'); insecure=$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end'); obfs=$(printf '%s' "$n" | jq -r '.obfs_pass // ""')
            printf 'hysteria2://%s@%s:%s?insecure=%s&sni=%s' "$(_node_cli_urlencode "$password")" "$server" "$port" "$insecure" "$(_node_cli_urlencode "$sni")"
            [[ -n "$obfs" ]] && printf '&obfs=salamander&obfs-password=%s' "$(_node_cli_urlencode "$obfs")"
            printf '#%s\n' "$(_node_cli_urlencode "PSM-$tag")"
            ;;
        anytls)
            password=$(printf '%s' "$n" | jq -r '.password'); sni=$(printf '%s' "$n" | jq -r '.sni'); insecure=$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')
            printf 'anytls://%s@%s:%s?insecure=%s&sni=%s#%s\n' "$(_node_cli_urlencode "$password")" "$server" "$port" "$insecure" "$(_node_cli_urlencode "$sni")" "$(_node_cli_urlencode "PSM-$tag")"
            ;;
        snell)
            _node_cli_err 'Snell has no standard URI; use --format surge'
            return 2
            ;;
    esac
}

_node_cli_export_surge() {
    local n="$1" server="$2" tag port psk version om oh line
    tag=$(printf '%s' "$n" | jq -r '.tag'); port=$(printf '%s' "$n" | jq -r '.port'); psk=$(printf '%s' "$n" | jq -r '.psk'); version=$(printf '%s' "$n" | jq -r '.version')
    om=$(printf '%s' "$n" | jq -r '.obfs_mode // ""'); oh=$(printf '%s' "$n" | jq -r '.obfs_host // ""')
    line="PSM-${tag} = snell, ${server}, ${port}, psk=${psk}, version=${version}"
    [[ -n "$om" ]] && line="${line}, obfs=${om}, obfs-host=${oh:-bing.com}"
    printf '%s\n' "$line"
}

_node_cli_cmd_export() {
    local tag="" core="" proto="" format="" server="" item n positional_core positional_proto
    if (( $# >= 3 )) && positional_core=$(_node_cli_norm_core "$1" 2>/dev/null) \
        && positional_proto=$(_node_cli_norm_protocol "$2" 2>/dev/null) \
        && _node_cli_pair_supported "$positional_core" "$positional_proto"; then
        core="$positional_core"; proto="$positional_proto"; tag="$3"; shift 3
    else
        tag="${1:-}"; shift || true
    fi
    [[ -n "$tag" && "$tag" != --* ]] || { _node_cli_err 'export requires TAG'; return 2; }
    while (( $# )); do
        case "$1" in
            --core) core=$(_node_cli_norm_core "${2:-}") || { _node_cli_err "unknown core: ${2:-}"; return 2; }; shift 2 ;;
            --protocol) proto=$(_node_cli_norm_protocol "${2:-}") || { _node_cli_err "unknown protocol: ${2:-}"; return 2; }; shift 2 ;;
            --format) format="${2:-}"; shift 2 ;;
            --server) server="${2:-}"; shift 2 ;;
            --json) format=json; shift ;;
            *) _node_cli_err "unknown export option: $1"; return 2 ;;
        esac
    done
    item=$(_node_cli_find "$tag" "$core" "$proto") || return 1
    core=$(printf '%s' "$item" | jq -r '.core'); proto=$(printf '%s' "$item" | jq -r '.protocol'); n=$(printf '%s' "$item" | jq -c '.node')
    [[ -n "$format" ]] || { [[ "$proto" == "snell" ]] && format=surge || format=uri; }
    if [[ "$format" == "json" ]]; then printf '%s\n' "$item" | jq -c '.'; return; fi
    [[ -n "$server" ]] || server=$(get_ipv4 2>/dev/null || true)
    [[ -n "$server" ]] || { _node_cli_err 'could not determine public server address; pass --server'; return 1; }
    case "$format" in
        uri) _node_cli_export_uri "$core" "$proto" "$n" "$server" ;;
        surge)
            [[ "$proto" == "snell" ]] || { _node_cli_err '--format surge is only available for Snell'; return 2; }
            _node_cli_export_surge "$n" "$server"
            ;;
        *) _node_cli_err "unsupported export format: $format"; return 2 ;;
    esac
}

node_cli_main() {
    command -v jq >/dev/null 2>&1 || { _node_cli_err 'jq is required'; return 127; }
    [[ "${1:-}" == "node" ]] && shift
    local command="${1:-}"
    [[ -n "$command" ]] || { _node_cli_usage >&2; return 2; }
    shift
    case "$command" in
        list) _node_cli_cmd_list "$@" ;;
        show) _node_cli_cmd_show "$@" ;;
        add) _node_cli_cmd_add "$@" ;;
        update) _node_cli_cmd_update "$@" ;;
        delete|remove|rm) _node_cli_cmd_delete "$@" ;;
        export) _node_cli_cmd_export "$@" ;;
        help|--help|-h) _node_cli_usage ;;
        *) _node_cli_err "unknown command: $command"; _node_cli_usage >&2; return 2 ;;
    esac
}

psm_node_cli() { node_cli_main "$@"; }
