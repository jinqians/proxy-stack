#!/usr/bin/env bash
# xray/reality.sh — VLESS + Reality node management

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

REALITY_CFG="$CFG_DIR/xray/reality.json"

REALITY_DEFAULT_PORT=443
REALITY_DEFAULT_DEST="www.cloudflare.com:443"
REALITY_DEFAULT_SERVER_NAME="www.cloudflare.com"

# Ports clouds/ISPs commonly block upstream, or well-known service ports unfit
# for a public proxy listener. A direct-listen node landing on one builds fine
# but stays unreachable from real clients — the old REALITY_DEFAULT_PORT+count
# default could hit 445 (SMB/microsoft-ds), which virtually every cloud/ISP
# blocks even when the security group is open. Used to steer the suggested
# default away from them and to warn if the operator picks one anyway.
REALITY_RISKY_PORTS="23 25 110 111 135 137 138 139 143 161 389 445 465 587 993 995 1433 2049 3306 3389 5432 6379 27017"

# ── Key generation ────────────────────────────────────────────────────────────
_reality_gen_keys() {
    local pair
    pair=$(xray_gen_x25519_keys) || return 1
    REALITY_PRIVATE_KEY="${pair%%$'\t'*}"
    REALITY_PUBLIC_KEY="${pair#*$'\t'}"
}

_reality_gen_shortid() {
    openssl rand -hex 4
}

# ── Node store ────────────────────────────────────────────────────────────────
_reality_load() {
    [[ -f "$REALITY_CFG" ]] || echo "[]" > "$REALITY_CFG"
    local nodes normalized
    nodes=$(cat "$REALITY_CFG")
    normalized=$(echo "$nodes" | jq '
      to_entries
      | map(
          .value as $n
          | if (($n.listen_addr // "") == "127.0.0.1" and (($n.port // 0) | tonumber) == 443) then
              .value.port = (1443 + .key)
              | .value.public_port = 443
            else
              .value.public_port = ($n.public_port // (if (($n.listen_addr // "") == "127.0.0.1") then 443 else $n.port end))
            end
          | .value
        )
    ' 2>/dev/null) || normalized="$nodes"

    if [[ "$normalized" != "$nodes" && -n "$normalized" ]]; then
        _reality_save "$normalized"
    fi
    echo "$normalized"
}

_reality_save() {
    mkdir -p "$(dirname "$REALITY_CFG")"
    echo "$1" > "$REALITY_CFG"
}

_reality_list() {
    _reality_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "0.0.0.0")\t\(.server_name)"' 2>/dev/null
}

_reality_count() {
    _reality_load | jq 'length' 2>/dev/null
}

_reality_get_by_tag() {
    _reality_load | jq --arg tag "$1" '.[] | select(.tag == $tag)' 2>/dev/null
}

_reality_upsert() {
    local node_json="$1"
    local tag; tag=$(echo "$node_json" | jq -r '.tag')
    local nodes; nodes=$(_reality_load)
    nodes=$(echo "$nodes" | jq --arg tag "$tag" --argjson node "$node_json" 'del(.[] | select(.tag == $tag)) | . += [$node]')
    _reality_save "$nodes"
}

_reality_delete() {
    local nodes; nodes=$(_reality_load)
    nodes=$(echo "$nodes" | jq --arg tag "$1" 'del(.[] | select(.tag == $tag))')
    _reality_save "$nodes"
}

# ── Sync store from live config ───────────────────────────────────────────────
# 节点存储是唯一事实源：手动编辑 config.json（改端口/UUID）后菜单仍显示旧值，
# 且下一次 _reality_apply_all 会用旧值覆盖手动修改。查看/修改前先把 config.json
# 中的端口和 UUID 同步回存储，使手动修改持久生效。匹配顺序：先按 tag，再按
# 客户端 UUID（合并入站的 tag 只属于同端口组的第一个节点）。
_reality_sync_from_live() {
    [[ -f "$XRAY_CFG" ]] || return 0
    local nodes; nodes=$(_reality_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag uuid port listen sn live
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node"    | jq -r '.tag')
        uuid=$(echo "$node"   | jq -r '.uuid')
        port=$(echo "$node"   | jq -r '.port')
        listen=$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')
        sn=$(echo "$node"     | jq -r '.server_name')

        live=$(jq -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) // empty' "$XRAY_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && live=$(jq -c --arg u "$uuid" \
            'first(.inbounds[]? | select(.settings.clients[]?.id == $u)) // empty' "$XRAY_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue

        local live_port live_uuid nclients
        live_port=$(echo "$live" | jq -r '.port')
        nclients=$(echo "$live" | jq '.settings.clients | length' 2>/dev/null || echo 0)
        live_uuid="$uuid"
        if [[ "$nclients" == "1" ]]; then
            live_uuid=$(echo "$live" | jq -r '.settings.clients[0].id')
        elif ! echo "$live" | jq -e --arg u "$uuid" '.settings.clients[]? | select(.id == $u)' >/dev/null 2>&1; then
            log_warn "$(t xray.reality.multi_user_sync_warn "$tag")"
        fi

        [[ "$live_port" == "$port" && "$live_uuid" == "$uuid" ]] && continue
        changed=1
        if [[ "$listen" == "127.0.0.1" && "$live_port" != "$port" ]]; then
            source "$LIB_DIR/nginx.sh"
            _sni_add_entry "$sn" "127.0.0.1:${live_port}" 2>/dev/null || true
            if [[ "$(state_get reality_local_port)" == "$port" ]]; then
                state_set reality_local_port "$live_port"
                _sni_set_default_backend "127.0.0.1:${live_port}" 2>/dev/null || true
            fi
        fi
        nodes=$(echo "$nodes" | jq --arg t "$tag" --arg p "$live_port" --arg u "$live_uuid" \
            '(.[] | select(.tag == $t)) |= (.port = ($p|tonumber) | .uuid = $u
             | (if (.listen_addr // "0.0.0.0") != "127.0.0.1" then .public_port = ($p|tonumber) else . end))')
    done
    if (( changed )); then
        _reality_save "$nodes"
        log_info "$(t xray.manual_sync_port_uuid)"
    fi
    return 0
}

# ── Port selection ────────────────────────────────────────────────────────────
_reality_port_is_risky() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    echo " $REALITY_RISKY_PORTS " | grep -qF " ${port} "
}

# True (0) when some process is already LISTENING on this TCP port. Checks the
# live socket table (ss, then netstat) rather than any config file, so a port
# held by a non-PSM service is caught too. If neither tool exists we can't tell,
# so we fail open (report "not in use") and let the add proceed.
_reality_port_in_use() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
        return
    fi
    if command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
        return
    fi
    return 1
}

# Suggest a sensible default public port for a new direct-listen node: a high
# port that is not risky, not already used by an existing Reality node, not
# reserved (honeypot/other services) when that check is available, and not
# currently listening. Tries pseudo-random high ports (20000–60000) first, then
# scans upward from a fixed base. Bash arithmetic only — no external dependency.
_reality_suggest_direct_port() {
    local used port i
    used=" $(_reality_load | jq -r '.[].port' 2>/dev/null | tr '\n' ' ') "

    for (( i = 0; i < 40; i++ )); do
        port=$(( 20000 + RANDOM * 40001 / 32768 ))
        _reality_port_is_risky "$port" && continue
        [[ "$used" == *" $port "* ]] && continue
        declare -f _hp_is_reserved_port &>/dev/null && _hp_is_reserved_port "$port" && continue
        _reality_port_in_use "$port" && continue
        printf '%s' "$port"; return 0
    done

    for (( port = 20000; port <= 60000; port++ )); do
        _reality_port_is_risky "$port" && continue
        [[ "$used" == *" $port "* ]] && continue
        declare -f _hp_is_reserved_port &>/dev/null && _hp_is_reserved_port "$port" && continue
        _reality_port_in_use "$port" && continue
        printf '%s' "$port"; return 0
    done

    printf '%s' "20000"
}

# ── Build Xray inbound JSON ───────────────────────────────────────────────────
_reality_build_inbound() {
    local node_json="$1"
    local tag;         tag=$(echo "$node_json"         | jq -r '.tag')
    local port;        port=$(echo "$node_json"        | jq -r '.port')
    local uuid;        uuid=$(echo "$node_json"        | jq -r '.uuid')
    local priv_key;    priv_key=$(echo "$node_json"    | jq -r '.private_key')
    local server_name; server_name=$(echo "$node_json" | jq -r '.server_name')
    local dest;        dest=$(echo "$node_json"        | jq -r '.dest')
    local flow;        flow=$(echo "$node_json"        | jq -r '.flow')
    local short_ids;   short_ids=$(echo "$node_json"   | jq -c '.short_ids')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "0.0.0.0"')

    local server_names_raw; server_names_raw=$(echo "$node_json" | jq -r '.server_names_raw // .server_name')
    local server_names_json
    server_names_json=$(echo "$server_names_raw" | tr ',' '\n' | jq -R . | jq -sc .)

    cat <<EOF
{
  "tag": "$tag",
  "listen": "$listen_addr",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [
      { "id": "$uuid", "flow": "$flow" }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$dest",
      "xver": 0,
      "serverNames": $server_names_json,
      "privateKey": "$priv_key",
      "shortIds": $short_ids
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
EOF
}

# ── Apply all Reality nodes to Xray config ────────────────────────────────────
# Nodes sharing the same (listen_addr, port) are merged into one inbound with
# multiple clients — this supports multiple UUIDs behind the same SNI/Nginx route.
_reality_apply_all() {
    local nodes; nodes=$(_reality_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(
        (.tag | startswith("reality")) or
        ((.streamSettings.security // "") == "reality" and (.streamSettings.network // "") == "tcp")
    ))' "$XRAY_CFG" > "$tmp" \
        && mv "$tmp" "$XRAY_CFG"

    # Track already-added (listen:port) pairs to avoid duplicate inbounds
    local seen_ports=""

    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        local nport; nport=$(echo "$node" | jq -r '.port')
        local nlisten; nlisten=$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')
        local portkey="${nlisten}:${nport}"

        # Skip if we already created an inbound for this port
        echo "$seen_ports" | grep -qF "|${portkey}|" && continue
        seen_ports="${seen_ports}|${portkey}|"

        # Merge clients (UUIDs) from all nodes sharing this (listen, port)
        local clients_json; clients_json=$(echo "$nodes" | jq \
            --arg p "$nport" --arg l "$nlisten" \
            '[.[] | select((.port | tostring) == $p
                       and (.listen_addr // "0.0.0.0") == $l)
             | {id: .uuid, flow: .flow}]')

        # Merge shortIds from all nodes on this port so each client can authenticate
        local short_ids_merged; short_ids_merged=$(echo "$nodes" | jq \
            --arg p "$nport" --arg l "$nlisten" \
            '[.[] | select((.port | tostring) == $p
                       and (.listen_addr // "0.0.0.0") == $l)
             | .short_ids[]] | unique')

        # Build inbound from the first node's config, inject merged clients + shortIds
        local inbound; inbound=$(_reality_build_inbound "$node")
        inbound=$(echo "$inbound" | jq \
            --argjson c "$clients_json" \
            --argjson s "$short_ids_merged" \
            '.settings.clients = $c | .streamSettings.realitySettings.shortIds = $s')

        xray_add_inbound "$inbound"
    done

    xray_test_restart
}

# ── Add node ──────────────────────────────────────────────────────────────────
reality_add_node() {
    _reality_sync_from_live
    log_step "$(t xray.reality.adding)"
    echo -e "  ${YELLOW}$(t xray.reality.desc1)"
    echo -e "  $(t xray.reality.desc2)"
    echo -e "  $(t xray.reality.desc3)${NC}\n"

    local tag port uuid flow server_names_raw dest
    local count; count=$(_reality_count)
    local own_domain=0 domain=""

    ask tag  "$(t xray.ask.node_tag)" "reality-$((count+1))"

    # ── Domain choice: own domain or public camouflage ────────────────────────
    echo ""
    if ask_yn "$(t xray.reality.ask_own_domain)" N; then
        own_domain=1
        ask domain "$(t xray.reality.ask_domain_sni)"
        [[ -z "$domain" ]] && { log_error "$(t xray.reality.domain_empty)"; return 1; }

        source "$LIB_DIR/cert.sh"
        if cert_ensure_domain "$domain" \
            "$(t xray.reality.cert_note)"; then
            server_names_raw="$domain"
            # dest receives raw TLS stream → must be an HTTPS (TLS-capable) backend
            dest="127.0.0.1:8443"
            log_info "$(t xray.reality.dest_local_https)"
        else
            # 没有证书时 nginx 不会创建 8443 伪装站（见 nginx_setup_camouflage_site），
            # 若仍把 dest 指向 127.0.0.1:8443 会得到 connection refused，反而暴露。
            # 因此回退到公共域名伪装：dest 指向真实存在的外部 HTTPS 站点。
            log_warn "$(t xray.reality.no_cert_fallback)"
            own_domain=0
            server_names_raw="$REALITY_DEFAULT_SERVER_NAME"
            dest="$REALITY_DEFAULT_DEST"
            domain="$server_names_raw"
            log_info "$(t xray.reality.dest_public_fallback "$dest")"
        fi
    else
        own_domain=0
        if ask_yn "$(t xray.reality.ask_discover_sni)" N; then
            source "$LIB_DIR/xray/sni_finder.sh"
            local _picked; _picked=$(sni_finder_pick_one) || true
            if [[ -n "$_picked" ]]; then
                server_names_raw="${_picked%%|*}"
                dest="${_picked#*|}"
                log_info "$(t xray.reality.picked_sni "$server_names_raw" "$dest")"
            fi
        fi
        [[ -z "$server_names_raw" ]] && \
            ask server_names_raw "$(t xray.reality.ask_sni)" "$REALITY_DEFAULT_SERVER_NAME"
        [[ -z "$dest" ]] && \
            ask dest             "$(t xray.reality.ask_dest)" "$REALITY_DEFAULT_DEST"
        domain="$server_names_raw"
    fi

    ask uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask flow "$(t xray.ask.flow)" "xtls-rprx-vision"

    # ── Nginx reverse proxy choice ────────────────────────────────────────────
    local listen_addr="" use_nginx=0 public_port="$REALITY_DEFAULT_PORT"
    local _primary_sn="" reuse_node="" reuse_sni=0
    echo ""
    if (( own_domain )); then
        echo -e "  ${CYAN}$(t xray.reality.own_domain_nginx_hint)${NC}"
        if ask_yn "$(t xray.reality.ask_nginx_proxy_short)" Y; then
            use_nginx=1; listen_addr="127.0.0.1"
        else
            use_nginx=0; listen_addr="0.0.0.0"
        fi
    elif ask_yn "$(t xray.ask.nginx_proxy)" N; then
        use_nginx=1; listen_addr="127.0.0.1"
    else
        use_nginx=0; listen_addr="0.0.0.0"
    fi

    if (( use_nginx )); then
        _primary_sn=$(echo "$server_names_raw" | cut -d',' -f1 | tr -d ' ')
        # Detect if this SNI already routes to an existing Reality node.
        # Two nodes with the same SNI must share one Xray inbound (same port +
        # key pair); only their UUIDs differ. Overwriting the SNI route would
        # break the first node, so we reuse its port and keys instead.
        reuse_node=$(_reality_load | jq -r \
            --arg sn "$_primary_sn" \
            'first(.[] | select(.server_name == $sn
                            and (.listen_addr // "0.0.0.0") == "127.0.0.1")) // ""' \
            2>/dev/null || true)
        if [[ -n "$reuse_node" && "$reuse_node" != "null" ]]; then
            reuse_sni=1
            port=$(echo "$reuse_node" | jq -r '.port')
            log_warn "$(t xray.reality.sni_reuse_warn "$_primary_sn" "$port")"
            log_info "$(t xray.reality.sni_reuse_info)"
        else
            ask port "$(t xray.reality.ask_local_xray_port)" "$((1443 + count))"
            _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
        fi
        public_port=443
    else
        # For direct-listen (no Nginx), each node needs its own public port. The
        # suggested default avoids well-known/ISP-blocked ports; if the operator
        # picks a risky one anyway (e.g. 445 = SMB), warn and re-ask until they
        # give a safe port or explicitly confirm the risky one.
        while true; do
            ask port "$(t xray.reality.ask_listen_port)" "$(_reality_suggest_direct_port)"
            if _reality_port_is_risky "$port"; then
                if [[ "$port" == "445" ]]; then
                    log_warn "$(t xray.reality.port_445_warn)"
                else
                    log_warn "$(t xray.reality.risky_port_warn "$port")"
                fi
                log_warn "$(t xray.reality.risky_port_note)"
                ask_yn "$(t xray.ask_use_port)" N || continue
            fi
            if _reality_port_in_use "$port"; then
                log_warn "$(t xray.reality.port_in_use "$port")"
                ask_yn "$(t xray.ask_use_port)" N || continue
            fi
            break
        done
        _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
        public_port="$port"
    fi

    if (( use_nginx )); then
        source "$LIB_DIR/nginx.sh"
        if ! is_installed nginx; then
            log_warn "$(t xray.reality.nginx_not_installed)"
            ask_yn "$(t xray.ask_install_nginx)" Y \
                && nginx_install \
                || { log_error "$(t xray.proxy_need_nginx)"; return 1; }
        fi
        # Always update the SNI entry. When reuse_sni=1, $port is the shared port
        # of the existing node — this also fixes any stale entry that pointed to a
        # different port (e.g. a previous failed add that overwrote the mapping).
        _sni_add_entry "$_primary_sn" "127.0.0.1:${port}"
        if (( count == 0 )); then
            _sni_set_default_backend "127.0.0.1:${port}"
            state_set "reality_local_port" "$port"
        fi
        if (( own_domain )); then
            nginx_setup_camouflage_site "$domain" \
                || log_warn "$(t xray.reality.camouflage_not_enabled)"
        fi
    fi

    # ── Generate keys ─────────────────────────────────────────────────────────
    if (( reuse_sni )); then
        # Same SNI = same Xray inbound = must share the same key pair.
        # Clients connecting with any UUID under this inbound use the same public key.
        REALITY_PRIVATE_KEY=$(echo "$reuse_node" | jq -r '.private_key')
        REALITY_PUBLIC_KEY=$(echo "$reuse_node"  | jq -r '.public_key')
        log_info "$(t xray.reality.reuse_key "$REALITY_PUBLIC_KEY")"
    else
        log_step "$(t xray.reality.generating_keys)"
        _reality_gen_keys
    fi
    local short_id; short_id=$(_reality_gen_shortid)
    local server_name; server_name=$(echo "$server_names_raw" | cut -d',' -f1 | tr -d ' ')

    log_info "$(t xray.reality.private_key "$REALITY_PRIVATE_KEY")"
    log_info "$(t xray.reality.public_key "$REALITY_PUBLIC_KEY")"
    log_info "$(t xray.reality.short_id "$short_id")"
    log_info "UUID        : $uuid"

    local node_json
    node_json=$(jq -n \
        --arg  tag              "$tag" \
        --argjson port          "$port" \
        --arg  uuid             "$uuid" \
        --arg  priv_key         "$REALITY_PRIVATE_KEY" \
        --arg  pub_key          "$REALITY_PUBLIC_KEY" \
        --arg  server_name      "$server_name" \
        --arg  server_names_raw "$server_names_raw" \
        --arg  dest             "$dest" \
        --arg  flow             "$flow" \
        --argjson short_ids     "[\"$short_id\"]" \
        --arg  listen_addr      "$listen_addr" \
        --argjson public_port   "$public_port" \
        '{
          tag:              $tag,
          port:             $port,
          public_port:      $public_port,
          uuid:             $uuid,
          private_key:      $priv_key,
          public_key:       $pub_key,
          server_name:      $server_name,
          server_names_raw: $server_names_raw,
          dest:             $dest,
          flow:             $flow,
          short_ids:        $short_ids,
          listen_addr:      $listen_addr
        }')

    _reality_upsert "$node_json"
    _reality_apply_all

    echo ""
    log_ok "$(t xray.reality.added "$tag" "$listen_addr" "$port")"

    if (( use_nginx == 0 )); then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    reality_show_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
reality_delete_node() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.delete_node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.not_found "$tag")"; return 1; }
    ask_yn "$(t xray.ask.delete_node "$tag")" N || return 0

    # Clean up the Nginx SNI entry added when this node was created
    local listen_addr; listen_addr=$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')
    if [[ "$listen_addr" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.server_name')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi

    _reality_delete "$tag"
    _reality_apply_all
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t xray.reality.deleted "$tag")"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
reality_modify_uuid() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local new_uuid; ask new_uuid "$(t xray.ask.uuid_auto)" ""
    [[ -z "$new_uuid" ]] && new_uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid = $v')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "$(t xray.uuid_updated_value "$new_uuid")"
}

reality_modify_port() {
    _reality_sync_from_live
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

    local old_port listen sn
    old_port=$(echo "$node" | jq -r '.port')
    listen=$(echo "$node"   | jq -r '.listen_addr // "0.0.0.0"')
    sn=$(echo "$node"       | jq -r '.server_name')

    local port
    if [[ "$listen" == "127.0.0.1" ]]; then
        log_info "$(t xray.nginx_proxy_port_note)"
        ask port "$(t xray.reality.ask_new_local_port)" "$old_port"
        [[ "$port" == "$old_port" ]] && { log_info "$(t xray.port_unchanged)"; return 0; }
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_error "$(t xray.invalid_port_short)"; return 1
        fi
        _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
    else
        while true; do
            ask port "$(t xray.reality.ask_new_listen_port)" "$(_reality_suggest_direct_port)"
            [[ "$port" == "$old_port" ]] && { log_info "$(t xray.port_unchanged)"; return 0; }
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                log_error "$(t xray.invalid_port_short)"; continue
            fi
            if _reality_port_is_risky "$port"; then
                log_warn "$(t xray.reality.risky_port_warn "$port")"
                ask_yn "$(t xray.ask_use_port)" N || continue
            fi
            if _reality_port_in_use "$port"; then
                log_warn "$(t xray.reality.port_in_use "$port")"
                ask_yn "$(t xray.ask_use_port)" N || continue
            fi
            break
        done
        _xray_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
    fi

    # 同端口+同 SNI 的节点共享一个入站（同一密钥对，仅 UUID 不同），必须整组迁移，
    # 否则 SNI 路由指向新端口后组内其它节点全部失联。直连节点各占独立公网端口，只移动自己。
    local nodes; nodes=$(_reality_load)
    nodes=$(echo "$nodes" | jq \
        --arg t "$tag" --arg l "$listen" --arg sn "$sn" \
        --arg old "$old_port" --arg new "$port" \
        'map(if (if $l == "127.0.0.1"
                 then ((.listen_addr // "0.0.0.0") == $l and (.port|tostring) == $old and .server_name == $sn)
                 else .tag == $t end)
             then .port = ($new|tonumber)
                  | (if $l != "127.0.0.1" then .public_port = ($new|tonumber) else . end)
             else . end)')
    _reality_save "$nodes"

    if [[ "$listen" == "127.0.0.1" ]]; then
        source "$LIB_DIR/nginx.sh"
        _sni_add_entry "$sn" "127.0.0.1:${port}"
        if [[ "$(state_get reality_local_port)" == "$old_port" ]]; then
            state_set reality_local_port "$port"
            _sni_set_default_backend "127.0.0.1:${port}"
        fi
    fi

    _reality_apply_all
    log_ok "$(t xray.port_updated "$tag" "$old_port" "$port")"

    if [[ "$listen" != "127.0.0.1" ]]; then
        ask_yn "$(t xray.ask.open_firewall_tcp "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
        log_info "$(t xray.old_port_note "$old_port")"
    fi
}

reality_rotate_keys() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    _reality_gen_keys
    node=$(echo "$node" | jq \
        --arg k "$REALITY_PRIVATE_KEY" \
        --arg p "$REALITY_PUBLIC_KEY" \
        '.private_key=$k | .public_key=$p')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "$(t xray.reality.key_rotated "$REALITY_PUBLIC_KEY")"
}

reality_rotate_shortid() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local sid; sid=$(_reality_gen_shortid)
    node=$(echo "$node" | jq --argjson s "[\"$sid\"]" '.short_ids = $s')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "$(t xray.reality.shortid_updated "$sid")"
}

reality_modify_servername() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local sn; ask sn "$(t xray.reality.ask_new_sni)"
    local primary; primary=$(echo "$sn" | cut -d',' -f1 | tr -d ' ')
    node=$(echo "$node" | jq --arg v "$sn" --arg p "$primary" \
        '.server_names_raw=$v | .server_name=$p')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "$(t xray.reality.sni_updated)"
}

reality_modify_dest() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    local dest; ask dest "$(t xray.reality.ask_new_dest)"
    node=$(echo "$node" | jq --arg v "$dest" '.dest = $v')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "$(t xray.reality.dest_updated)"
}

reality_modify_flow() {
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    echo -e "  1. xtls-rprx-vision\n  2. (none)"
    read -rp "$(echo -e "${CYAN}$(t xray.reality.ask_flow)${NC}")" fc
    local flow; [[ "$fc" == "2" ]] && flow="" || flow="xtls-rprx-vision"
    node=$(echo "$node" | jq --arg v "$flow" '.flow = $v')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "$(t xray.reality.flow_updated)"
}

# ── Export / share ────────────────────────────────────────────────────────────
reality_show_uri() {
    local tag="$1"
    _reality_sync_from_live
    [[ -z "$tag" ]] && { _show_node_list; ask tag "$(t xray.ask.node_tag)"; }
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.not_found "$tag")"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.port')
    local public_port; public_port=$(echo "$node" | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')
    local ipv4;        ipv4=$(get_ipv4)
    local ipv6;        ipv6=$(get_ipv6 2>/dev/null || echo "")

    echo -e "\n${BOLD}${BLUE}══ Reality Node: $tag ══════════════════${NC}"
    printf "  %-14s %s\n" "UUID:"        "$uuid"
    printf "  %-14s %s\n" "Public Key:"  "$pub_key"
    printf "  %-14s %s\n" "Short ID:"    "$short_id"
    printf "  %-14s %s\n" "$(t xray.reality.local_port_label)" "$port"
    printf "  %-14s %s\n" "$(t xray.reality.public_port_label)" "$public_port"
    printf "  %-14s %s\n" "SNI:"         "$server_name"
    printf "  %-14s %s\n" "Flow:"        "$flow"
    echo ""

    # Ensure qrencode is available (needs EPEL on RHEL-family)
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true

    if [[ -n "$ipv4" ]]; then
        local uri_v4="vless://${uuid}@${ipv4}:${public_port}?encryption=none&flow=${flow}&security=reality&sni=${server_name}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#PSM-${tag}-v4"
        echo -e "${BOLD}${GREEN}$(t xray.reality.ipv4_link)${NC}"
        echo "  $uri_v4"
        echo ""
        command -v qrencode &>/dev/null && echo "$uri_v4" | qrencode -t ANSIUTF8 2>/dev/null || true
    fi

    if [[ -n "$ipv6" ]]; then
        local uri_v6="vless://${uuid}@[${ipv6}]:${public_port}?encryption=none&flow=${flow}&security=reality&sni=${server_name}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#PSM-${tag}-v6"
        echo -e "${BOLD}${GREEN}$(t xray.reality.ipv6_link)${NC}"
        echo "  $uri_v6"
        echo ""
        command -v qrencode &>/dev/null && echo "$uri_v6" | qrencode -t ANSIUTF8 2>/dev/null || true
    fi
}

reality_export_clash() {
    _reality_sync_from_live
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')
    local ip;          ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}$(t xray.reality.clash_title)${NC}"
    cat <<EOF
proxies:
  - name: PSM-${tag}
    type: vless
    server: ${ip}
    port: ${port}
    uuid: ${uuid}
    flow: ${flow}
    tls: true
    udp: true
    reality-opts:
      public-key: ${pub_key}
      short-id: ${short_id}
    client-fingerprint: chrome
    servername: ${server_name}
    network: tcp
EOF
}

reality_export_singbox() {
    _reality_sync_from_live
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')
    local ip;          ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}$(t xray.reality.singbox_title)${NC}"
    jq -n \
        --arg tag "$tag" --arg ip "$ip" --arg uuid "$uuid" \
        --arg flow "$flow" --arg pub_key "$pub_key" \
        --arg short_id "$short_id" --arg sn "$server_name" \
        --argjson port "$port" \
        '{
          "type": "vless",
          "tag": ("PSM-" + $tag),
          "server": $ip,
          "server_port": $port,
          "uuid": $uuid,
          "flow": $flow,
          "tls": {
            "enabled": true,
            "server_name": $sn,
            "utls": { "enabled": true, "fingerprint": "chrome" },
            "reality": {
              "enabled": true,
              "public_key": $pub_key,
              "short_id": $short_id
            }
          }
        }'
}

# ── List helpers ──────────────────────────────────────────────────────────────
_show_node_list() {
    local nodes; nodes=$(_reality_list)
    if [[ -z "$nodes" ]]; then
        log_warn "$(t xray.reality.no_nodes)"
    else
        echo -e "\n${BOLD}$(t xray.reality.nodes_title)${NC}"
        printf "  %-20s %-6s %-15s %s\n" "$(t xray.header.tag)" "$(t xray.header.port)" "$(t xray.header.listen)" "SNI"
        echo "$nodes" | while IFS=$'\t' read -r tag port listen sn; do
            printf "  %-20s %-6s %-15s %s\n" "$tag" "$port" "$listen" "$sn"
        done
    fi
}

reality_show_config() {
    _reality_sync_from_live
    _show_node_list
    local tag; ask tag "$(t xray.ask.node_tag)"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t xray.node_not_found)"; return 1; }
    echo "$node" | jq .
}

# ── Dependency check ──────────────────────────────────────────────────────────
_reality_check_deps() {
    ensure_pkg_deps jq openssl qrencode
    if [[ ! -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
        ask_yn "$(t xray.ask_install_xray)" Y \
            && xray_install \
            || { log_error "$(t xray.reality.need_xray)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
reality_menu() {
    _reality_check_deps || return
    while true; do
        # 每轮菜单前同步一次，避免任何走 _reality_apply_all 的操作
        # 用过期的节点存储覆盖 config.json 中的手动修改。
        _reality_sync_from_live
        show_menu "$(t xray.reality.menu.title)" \
            "$(t xray.reality.menu.add)" \
            "$(t xray.reality.menu.delete)" \
            "$(t xray.reality.menu.uuid)" \
            "$(t xray.reality.menu.port)" \
            "$(t xray.reality.menu.rotate_key)" \
            "$(t xray.reality.menu.shortid)" \
            "$(t xray.reality.menu.sni)" \
            "$(t xray.reality.menu.flow)" \
            "$(t xray.reality.menu.dest)" \
            "$(t xray.reality.menu.uri)" \
            "$(t xray.reality.menu.clash)" \
            "$(t xray.reality.menu.singbox)" \
            "$(t xray.reality.menu.config)" \
            "$(t xray.reality.menu.list)" \
            "$(t xray.reality.menu.watchdog)"

        case "$MENU_CHOICE" in
            1)  reality_add_node ;;
            2)  reality_delete_node ;;
            3)  reality_modify_uuid ;;
            4)  reality_modify_port ;;
            5)  reality_rotate_keys ;;
            6)  reality_rotate_shortid ;;
            7)  reality_modify_servername ;;
            8)  reality_modify_flow ;;
            9)  reality_modify_dest ;;
            10) reality_show_uri "" ;;
            11) reality_export_clash ;;
            12) reality_export_singbox ;;
            13) reality_show_config ;;
            14) _show_node_list ;;
            15)
                source "$(dirname "${BASH_SOURCE[0]}")/reality_watchdog.sh"
                rwd_menu
                continue ;;
            0)  return ;;
        esac
        press_enter
    done
}
