#!/usr/bin/env bash
# xray/reality.sh — VLESS + Reality node management

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

REALITY_CFG="$CFG_DIR/xray/reality.json"

REALITY_DEFAULT_PORT=443
REALITY_DEFAULT_DEST="www.cloudflare.com:443"
REALITY_DEFAULT_SERVER_NAME="www.cloudflare.com"

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
    _reality_load | jq ".[] | select(.tag == \"$1\")" 2>/dev/null
}

_reality_upsert() {
    local node_json="$1"
    local tag; tag=$(echo "$node_json" | jq -r '.tag')
    local nodes; nodes=$(_reality_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$tag\")) | . += [$node_json]")
    _reality_save "$nodes"
}

_reality_delete() {
    local nodes; nodes=$(_reality_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$1\"))")
    _reality_save "$nodes"
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
    log_step "正在配置 VLESS + Reality 节点..."
    echo -e "  ${YELLOW}Reality 使用 x25519 密钥认证，本身不需要 TLS 证书。"
    echo -e "  如果使用自己的域名，签发证书可让 Nginx 提供真实 HTTPS 伪装站点，"
    echo -e "  这样被探测时更像正常网站。${NC}\n"

    local tag port uuid flow server_names_raw dest
    local count; count=$(_reality_count)
    local own_domain=0 domain=""

    ask tag  "节点标识"    "reality-$((count+1))"

    # ── Domain choice: own domain or public camouflage ────────────────────────
    echo ""
    if ask_yn "是否使用自己的域名作为 SNI？（伪装更好，需要证书）" N; then
        own_domain=1
        ask domain "你的域名（也会作为 SNI）"
        [[ -z "$domain" ]] && { log_error "域名不能为空。"; return 1; }

        source "$LIB_DIR/cert.sh"
        cert_ensure_domain "$domain" \
            "Reality 本身不需要证书。这个证书用于本机 HTTPS 伪装站点
  (127.0.0.1:8443)，探测者连接你的服务器时会看到它。
  如果没有证书，伪装会表现为普通 TLS 错误，较容易被识别。" || {
            log_warn "将继续安装节点，但伪装站点质量会降低。"
        }

        server_names_raw="$domain"
        # dest receives raw TLS stream → must be an HTTPS (TLS-capable) backend
        dest="127.0.0.1:8443"
        log_info "伪装目标已设置为 127.0.0.1:8443（本机 HTTPS 站点）"
    else
        own_domain=0
        ask server_names_raw "伪装 SNI（例如 www.apple.com）"     "$REALITY_DEFAULT_SERVER_NAME"
        ask dest             "伪装目标（例如 www.apple.com:443）"  "$REALITY_DEFAULT_DEST"
        domain="$server_names_raw"
    fi

    ask uuid "UUID（留空自动生成）" ""
    [[ -z "$uuid" ]] && uuid=$(uuid_gen)
    ask flow "Flow 参数" "xtls-rprx-vision"

    # ── Nginx reverse proxy choice ────────────────────────────────────────────
    local listen_addr="" use_nginx=0 public_port="$REALITY_DEFAULT_PORT"
    local _primary_sn="" reuse_node="" reuse_sni=0
    echo ""
    if (( own_domain )); then
        echo -e "  ${CYAN}使用自己的域名时，建议通过 Nginx 提供伪装网站。${NC}"
        if ask_yn "是否使用 Nginx 反向代理？" Y; then
            use_nginx=1; listen_addr="127.0.0.1"
        else
            use_nginx=0; listen_addr="0.0.0.0"
        fi
    elif ask_yn "是否使用 Nginx 反向代理？（可让多个协议复用 443 端口）" N; then
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
            log_warn "SNI '$_primary_sn' 已被现有节点使用（端口 $port）"
            log_info "新节点将共享该端口和密钥对，仅添加新 UUID 作为独立用户"
        else
            ask port "本机 Xray 监听端口" "$((1443 + count))"
            _xray_check_port_conflict "$port" || { log_info "已取消"; return 1; }
        fi
        public_port=443
    else
        # For direct-listen (no Nginx), each node needs its own public port.
        ask port "监听端口" "$((REALITY_DEFAULT_PORT + count))"
        _xray_check_port_conflict "$port" || { log_info "已取消"; return 1; }
        public_port="$port"
    fi

    if (( use_nginx )); then
        source "$LIB_DIR/nginx.sh"
        if ! is_installed nginx; then
            log_warn "Nginx 尚未安装。"
            ask_yn "是否现在安装 Nginx？" Y \
                && nginx_install \
                || { log_error "反向代理模式需要 Nginx。"; return 1; }
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
                || log_warn "HTTPS 伪装站点未启用，但 Reality 节点会继续安装。"
        fi
    fi

    # ── Generate keys ─────────────────────────────────────────────────────────
    if (( reuse_sni )); then
        # Same SNI = same Xray inbound = must share the same key pair.
        # Clients connecting with any UUID under this inbound use the same public key.
        REALITY_PRIVATE_KEY=$(echo "$reuse_node" | jq -r '.private_key')
        REALITY_PUBLIC_KEY=$(echo "$reuse_node"  | jq -r '.public_key')
        log_info "复用密钥对 → 公钥：$REALITY_PUBLIC_KEY"
    else
        log_step "正在生成 x25519 密钥对..."
        _reality_gen_keys
    fi
    local short_id; short_id=$(_reality_gen_shortid)
    local server_name; server_name=$(echo "$server_names_raw" | cut -d',' -f1 | tr -d ' ')

    log_info "私钥 Private Key : $REALITY_PRIVATE_KEY"
    log_info "公钥 Public Key  : $REALITY_PUBLIC_KEY"
    log_info "短 ID Short ID   : $short_id"
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
    log_ok "Reality 节点 '$tag' → ${listen_addr}:${port}"

    if (( use_nginx == 0 )); then
        ask_yn "是否现在放行防火墙端口 ${port}/tcp？" Y && {
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
    local tag; ask tag "要删除的节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到：$tag"; return 1; }
    ask_yn "确认删除节点 '$tag'？" N || return 0

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
    log_ok "节点 '$tag' 已删除。"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
reality_modify_uuid() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }
    local new_uuid; ask new_uuid "新 UUID（留空自动生成）" ""
    [[ -z "$new_uuid" ]] && new_uuid=$(uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid = $v')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "UUID 已更新：$new_uuid"
}

reality_rotate_keys() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }
    _reality_gen_keys
    node=$(echo "$node" | jq \
        --arg k "$REALITY_PRIVATE_KEY" \
        --arg p "$REALITY_PUBLIC_KEY" \
        '.private_key=$k | .public_key=$p')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "密钥已轮换。新公钥：$REALITY_PUBLIC_KEY"
}

reality_rotate_shortid() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }
    local sid; sid=$(_reality_gen_shortid)
    node=$(echo "$node" | jq --argjson s "[\"$sid\"]" '.short_ids = $s')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "Short ID 已更新：$sid"
}

reality_modify_servername() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }
    local sn; ask sn "新的伪装 SNI（多个用逗号分隔）"
    local primary; primary=$(echo "$sn" | cut -d',' -f1 | tr -d ' ')
    node=$(echo "$node" | jq --arg v "$sn" --arg p "$primary" \
        '.server_names_raw=$v | .server_name=$p')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "伪装 SNI 已更新。"
}

reality_modify_dest() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }
    local dest; ask dest "新的伪装目标（例如 www.apple.com:443）"
    node=$(echo "$node" | jq --arg v "$dest" '.dest = $v')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "伪装目标已更新。"
}

reality_modify_flow() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }
    echo -e "  1. xtls-rprx-vision\n  2. (none)"
    read -rp "$(echo -e "${CYAN}Flow 选项: ${NC}")" fc
    local flow; [[ "$fc" == "2" ]] && flow="" || flow="xtls-rprx-vision"
    node=$(echo "$node" | jq --arg v "$flow" '.flow = $v')
    _reality_upsert "$node"
    _reality_apply_all
    log_ok "Flow 已更新。"
}

# ── Export / share ────────────────────────────────────────────────────────────
reality_show_uri() {
    local tag="$1"
    [[ -z "$tag" ]] && { _show_node_list; ask tag "节点标识"; }
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到：$tag"; return 1; }

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
    printf "  %-14s %s\n" "本机端口:"    "$port"
    printf "  %-14s %s\n" "公网端口:"    "$public_port"
    printf "  %-14s %s\n" "SNI:"         "$server_name"
    printf "  %-14s %s\n" "Flow:"        "$flow"
    echo ""

    # Ensure qrencode is available (needs EPEL on RHEL-family)
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true

    if [[ -n "$ipv4" ]]; then
        local uri_v4="vless://${uuid}@${ipv4}:${public_port}?encryption=none&flow=${flow}&security=reality&sni=${server_name}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#PSM-${tag}-v4"
        echo -e "${BOLD}${GREEN}IPv4 链接:${NC}"
        echo "  $uri_v4"
        echo ""
        command -v qrencode &>/dev/null && echo "$uri_v4" | qrencode -t ANSIUTF8 2>/dev/null || true
    fi

    if [[ -n "$ipv6" ]]; then
        local uri_v6="vless://${uuid}@[${ipv6}]:${public_port}?encryption=none&flow=${flow}&security=reality&sni=${server_name}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#PSM-${tag}-v6"
        echo -e "${BOLD}${GREEN}IPv6 链接:${NC}"
        echo "  $uri_v6"
        echo ""
        command -v qrencode &>/dev/null && echo "$uri_v6" | qrencode -t ANSIUTF8 2>/dev/null || true
    fi
}

reality_export_clash() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')
    local ip;          ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}── Clash Meta 配置 ──${NC}"
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
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // (if (.listen_addr // "") == "127.0.0.1" then 443 else .port end)')
    local ip;          ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}── Sing-box 出站配置 ──${NC}"
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
        log_warn "尚未配置 Reality 节点。"
    else
        echo -e "\n${BOLD}Reality 节点:${NC}"
        printf "  %-20s %-6s %-15s %s\n" "标识" "端口" "监听" "SNI"
        echo "$nodes" | while IFS=$'\t' read -r tag port listen sn; do
            printf "  %-20s %-6s %-15s %s\n" "$tag" "$port" "$listen" "$sn"
        done
    fi
}

reality_show_config() {
    _show_node_list
    local tag; ask tag "节点标识"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到节点"; return 1; }
    echo "$node" | jq .
}

# ── Dependency check ──────────────────────────────────────────────────────────
_reality_check_deps() {
    ensure_pkg_deps jq openssl qrencode
    if [[ ! -f "$XRAY_BIN" ]]; then
        log_warn "Xray 尚未安装。"
        ask_yn "是否现在安装 Xray？" Y \
            && xray_install \
            || { log_error "Reality 需要 Xray。"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
reality_menu() {
    _reality_check_deps || return
    while true; do
        show_menu "Reality 管理" \
            "添加节点" \
            "删除节点" \
            "修改 UUID" \
            "轮换密钥（私钥 / 公钥）" \
            "轮换 Short ID" \
            "修改伪装 SNI" \
            "修改 Flow" \
            "修改伪装目标" \
            "显示 URI / 二维码" \
            "导出 Clash Meta" \
            "导出 Sing-box" \
            "显示节点配置（JSON）" \
            "列出节点" \
            "多目标自动测活切换（抗封锁）"

        case "$MENU_CHOICE" in
            1)  reality_add_node ;;
            2)  reality_delete_node ;;
            3)  reality_modify_uuid ;;
            4)  reality_rotate_keys ;;
            5)  reality_rotate_shortid ;;
            6)  reality_modify_servername ;;
            7)  reality_modify_flow ;;
            8)  reality_modify_dest ;;
            9)  reality_show_uri "" ;;
            10) reality_export_clash ;;
            11) reality_export_singbox ;;
            12) reality_show_config ;;
            13) _show_node_list ;;
            14)
                source "$(dirname "${BASH_SOURCE[0]}")/reality_watchdog.sh"
                rwd_menu
                continue ;;
            0)  return ;;
        esac
        press_enter
    done
}
