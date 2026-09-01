#!/usr/bin/env bash
# singbox/reality.sh — VLESS + Reality (+Vision) node management for sing-box
#
# 直连监听模式：每个节点占用自己的公网端口，自带 x25519 密钥对与 UUID。
# 节点存储（config/singbox/reality.json）是唯一事实源，apply 时整体重建
# sing-box 的 vless+reality 入站。所有终端输出走 i18n（t sb.reality.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_REALITY_CFG="$SB_STORE_DIR/reality.json"

SB_REALITY_DEFAULT_PORT=443
# 不出厂预置伪装域名：任何写死的知名域名都可能迁到 CDN 后面变成共享前端（见
# lib/common.sh 的 reality_dest_is_shared_frontend），且全网共用同一个默认值本身
# 就是指纹。本核心没有测绘发现（那是 Xray 专有），所以这里要求显式输入。
SB_REALITY_DEFAULT_DEST=""
SB_REALITY_DEFAULT_SN=""

# 云厂商/ISP 常在上游封锁的端口，直连节点落在这些端口会连不上。
SB_REALITY_RISKY_PORTS="23 25 110 111 135 137 138 139 143 161 389 445 465 587 993 995 1433 2049 3306 3389 5432 6379 27017"

# ── Key generation ────────────────────────────────────────────────────────────
_sb_reality_gen_keys() {
    local pair
    pair=$(sb_gen_reality_keys) || return 1
    SB_REALITY_PRIVATE_KEY="${pair%%$'\t'*}"
    SB_REALITY_PUBLIC_KEY="${pair#*$'\t'}"
}

_sb_reality_gen_shortid() { openssl rand -hex 4; }

# ── Node store ────────────────────────────────────────────────────────────────
_sb_reality_load() { [[ -f "$SB_REALITY_CFG" ]] || echo "[]" > "$SB_REALITY_CFG"; cat "$SB_REALITY_CFG"; }
_sb_reality_save() { mkdir -p "$(dirname "$SB_REALITY_CFG")"; echo "$1" > "$SB_REALITY_CFG"; }

_sb_reality_list() {
    _sb_reality_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "::")\t\(.server_name)"' 2>/dev/null
}

_sb_reality_count()      { _sb_reality_load | jq 'length' 2>/dev/null; }
_sb_reality_get_by_tag() { _sb_reality_load | jq --arg tag "$1" '.[] | select(.tag == $tag)' 2>/dev/null; }

_sb_reality_upsert() {
    local node_json="$1" tag; tag=$(echo "$node_json" | jq -r '.tag')
    local nodes; nodes=$(_sb_reality_load)
    nodes=$(echo "$nodes" | jq --arg tag "$tag" --argjson node "$node_json" \
        'del(.[] | select(.tag == $tag)) | . += [$node]')
    _sb_reality_save "$nodes"
}

_sb_reality_delete() {
    local nodes; nodes=$(_sb_reality_load)
    nodes=$(echo "$nodes" | jq --arg tag "$1" 'del(.[] | select(.tag == $tag))')
    _sb_reality_save "$nodes"
}

# ── Sync store from live config ───────────────────────────────────────────────
# 手动编辑 config.json（改端口/UUID）后，把改动同步回节点存储，否则菜单显示旧值
# 且下次 apply 会用旧值覆盖手动修改。入站与节点按 tag 一一对应。
_sb_reality_sync_from_live() {
    [[ -f "$SB_CFG" ]] || return 0
    local nodes; nodes=$(_sb_reality_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag port uuid live live_port live_uuid
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node"  | jq -r '.tag')
        port=$(echo "$node" | jq -r '.port')
        uuid=$(echo "$node" | jq -r '.uuid')
        live=$(jq -c --arg t "$tag" 'first(.inbounds[]? | select(.tag == $t)) // empty' "$SB_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue
        live_port=$(echo "$live" | jq -r '.listen_port')
        live_uuid=$(echo "$live" | jq -r '.users[0].uuid')
        [[ "$live_port" == "$port" && "$live_uuid" == "$uuid" ]] && continue
        changed=1
        nodes=$(echo "$nodes" | jq --arg t "$tag" --arg p "$live_port" --arg u "$live_uuid" \
            '(.[] | select(.tag == $t)) |= (.port = ($p|tonumber) | .uuid = $u)')
    done
    if (( changed )); then
        _sb_reality_save "$nodes"
        log_info "$(t sb.reality.synced)"
    fi
    return 0
}

# ── Port selection ────────────────────────────────────────────────────────────
_sb_reality_port_is_risky() {
    local port="$1"; [[ "$port" =~ ^[0-9]+$ ]] || return 1
    echo " $SB_REALITY_RISKY_PORTS " | grep -qF " ${port} "
}

_sb_reality_port_in_use() {
    local port="$1"; [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; return
    fi
    if command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; return
    fi
    return 1
}

# 建议端口：443 若空闲则优先（reality 直连常用 443），否则挑一个非风险、未占用的高端口。
_sb_reality_suggest_port() {
    local used port i
    used=" $(_sb_reality_load | jq -r '.[].port' 2>/dev/null | tr '\n' ' ') "
    if [[ "$used" != *" 443 "* ]] && ! _sb_reality_port_in_use 443; then
        printf '443'; return 0
    fi
    for (( i = 0; i < 40; i++ )); do
        port=$(( 20000 + RANDOM * 40001 / 32768 ))
        _sb_reality_port_is_risky "$port" && continue
        [[ "$used" == *" $port "* ]] && continue
        _sb_reality_port_in_use "$port" && continue
        printf '%s' "$port"; return 0
    done
    printf '20000'
}

# ── Build sing-box vless+reality inbound ──────────────────────────────────────
_sb_reality_build_inbound() {
    local node_json="$1"
    local tag;         tag=$(echo "$node_json"         | jq -r '.tag')
    local port;        port=$(echo "$node_json"        | jq -r '.port')
    local uuid;        uuid=$(echo "$node_json"        | jq -r '.uuid')
    local priv_key;    priv_key=$(echo "$node_json"    | jq -r '.private_key')
    local server_name; server_name=$(echo "$node_json" | jq -r '.server_name')
    local dest;        dest=$(echo "$node_json"        | jq -r '.dest')
    local flow;        flow=$(echo "$node_json"        | jq -r '.flow')
    local short_ids;   short_ids=$(echo "$node_json"   | jq -c '.short_ids')
    local listen_addr; listen_addr=$(echo "$node_json" | jq -r '.listen_addr // "::"')

    local hs_server="${dest%%:*}"
    local hs_port="${dest##*:}"
    [[ "$hs_port" =~ ^[0-9]+$ ]] || hs_port=443

    jq -n \
        --arg  tag         "$tag" \
        --arg  listen      "$listen_addr" \
        --argjson port     "$port" \
        --arg  uuid        "$uuid" \
        --arg  flow        "$flow" \
        --arg  sn          "$server_name" \
        --arg  hs_server   "$hs_server" \
        --argjson hs_port  "$hs_port" \
        --arg  priv_key    "$priv_key" \
        --argjson short    "$short_ids" \
    '{
        type: "vless",
        tag: $tag,
        listen: $listen,
        listen_port: $port,
        users: [ ( { uuid: $uuid } + (if $flow == "" then {} else { flow: $flow } end) ) ],
        tls: {
            enabled: true,
            server_name: $sn,
            reality: {
                enabled: true,
                handshake: { server: $hs_server, server_port: $hs_port },
                private_key: $priv_key,
                short_id: $short
            }
        }
    }'
}

# ── Apply all Reality nodes to sing-box config ────────────────────────────────
_sb_reality_apply_all() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_reality_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(
        ((.tag // "") | startswith("sb-reality")) or
        ((.type == "vless") and ((.tls.reality.enabled // false) == true))
    ))' "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        local inbound; inbound=$(_sb_reality_build_inbound "$node")
        sb_add_inbound "$inbound"
    done

    sb_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_sb_reality_apply_or_revert() {
    _sb_reality_apply_all && return 0
    _sb_reality_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_reality_add_node() {
    _sb_reality_sync_from_live
    log_step "$(t sb.reality.configuring)"

    local tag port uuid flow server_names_raw dest server_name
    local count; count=$(_sb_reality_count)

    ask tag "$(t sb.reality.ask_tag)" "sb-reality-$((count+1))"
    [[ "$tag" =~ ^sb-reality ]] || tag="sb-reality-${tag}"


    # ── 自有域名 + 本地伪装站 ─────────────────────────────────────────────────
    # 域名直接解析到本机时，不必去借别人的站点：签一张自己的证书，用 Nginx 在
    # 127.0.0.1:8443 起一个真的 HTTPS 站，让 Reality 的回落打到它。DNS、证书、
    # 实际服务三者一致，比借用公共域名更自洽（借来的域名解析到别人的 IP，
    # 一比对就露馅）。与 Xray 侧 reality.sh 的同名流程保持一致。
    local own_domain=0 domain=""
    echo ""
    if ask_yn "$(t sb.reality.ask_own_domain)" N; then
        own_domain=1
        ask domain "$(t sb.reality.ask_domain_sni)"
        [[ -z "$domain" ]] && { log_error "$(t sb.reality.domain_empty)"; return 1; }

        source "$LIB_DIR/cert.sh"
        if cert_ensure_domain "$domain" "$(t sb.reality.cert_note)"; then
            server_names_raw="$domain"
            server_name="$domain"
            # dest 收到的是原始 TLS 流，必须指向一个会说 TLS 的后端
            dest="127.0.0.1:8443"
            log_info "$(t sb.reality.dest_local_https)"
        else
            # 证书签不下来时 Nginx 不会创建 8443 伪装站，此时 dest 还指过去只会拿到
            # connection refused —— 那比不做伪装更暴露。回退到公共域名伪装。
            log_warn "$(t sb.reality.no_cert_fallback)"
            own_domain=0; server_names_raw=""; server_name=""; dest=""
        fi
    fi

    # P1: ask the SNI first, compute the primary server_name, then default the
    # camouflage dest to it. Reality forwards the client handshake to dest, whose
    # cert must cover the presented SNI — a hardcoded dest that ignored the SNI
    # builds and passes the config test yet lets no client handshake.
    if (( ! own_domain )); then
        while :; do
            ask server_names_raw "$(t sb.reality.ask_sni)" "$SB_REALITY_DEFAULT_SN"
            server_name=$(echo "$server_names_raw" | cut -d',' -f1 | tr -d ' ')
            [[ -n "$server_name" ]] && break
            log_error "$(t common.reality.sni_empty)"
        done
        ask dest "$(t sb.reality.ask_dest)" "${server_name}:443"
    fi

    # P2: advisory validation of the (SNI, dest) pair via the shared openssl-only
    # validator. Never hard-blocks: on failure the operator can re-enter or
    # proceed anyway. Skipped for local/loopback dests.
    while ! reality_dest_is_local "$dest"; do
        log_step "$(t common.reality.checking_dest "$dest" "$server_name")"
        if reality_validate_dest "$dest" "$server_name"; then
            [[ -n "$REALITY_DEST_RTT_MS" ]] && log_info "$(t common.reality.dest_ok "$REALITY_DEST_RTT_MS")"
            # 共享 CDN 前端：握手一切正常，但会让 Reality 的回落变成通往整个 CDN 的
            # 免费隧道。告警而非否决 —— 判定可能误伤，风险由使用者自行取舍。
            [[ "$REALITY_DEST_WARN" != shared_frontend:* ]] && break
            log_warn "$(t common.reality.dest_shared_frontend "${REALITY_DEST_WARN#shared_frontend:}")"
        else
            log_warn "$(t common.reality.dest_check_failed "${REALITY_DEST_REASON:-unknown}")"
        fi
        ask_yn "$(t common.reality.proceed_anyway)" N && break
        ask server_names_raw "$(t sb.reality.ask_sni)" "$SB_REALITY_DEFAULT_SN"
        server_name=$(echo "$server_names_raw" | cut -d',' -f1 | tr -d ' ')
        ask dest "$(t sb.reality.ask_dest)" "${server_name}:443"
    done

    ask uuid "$(t sb.reality.ask_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$("$SB_BIN" generate uuid 2>/dev/null || uuid_gen)

    echo -e "  1. xtls-rprx-vision\n  2. (none)"
    read -rp "$(echo -e "${CYAN}$(t sb.reality.ask_flow)${NC}")" fc
    [[ "$fc" == "2" ]] && flow="" || flow="xtls-rprx-vision"

    # ── 监听模式：直连独占公网端口（默认），或挂到 Nginx 443 SNI 分流 ──
    # 挂载模式不要求自有域名：Reality 的伪装域名（decoy SNI）就是路由键。
    local listen_addr="::" public_port="" use_nginx=0
    echo ""
    # sing-box 的 reality 入站没有回落限速（Xray/mihomo 有 limitFallback）。dest 又是
    # 共享 CDN 前端时，直连模式等于三层防护全空 —— 没有 Nginx 的未知 SNI 黑洞挡在前面，
    # 也没有限速兜底，只剩 dest 选择这一条线。这是所有组合里最容易被当免费中继的一种，
    # 所以在这里显式提示改走挂载模式。
    # 自有域名模式下 dest 是本机 8443，挂到 443 分流才是完整形态，所以默认 Y；
    # 借用公共域名时维持原来的默认 N。
    if (( own_domain )); then
        ask_yn "$(t sb.front.ask_mount)" Y && use_nginx=1
    else
        ask_yn "$(t sb.front.ask_mount)" N && use_nginx=1
    fi
    if (( use_nginx == 0 )) && [[ "$REALITY_DEST_WARN" == shared_frontend:* ]]; then
        log_warn "$(t sb.reality.direct_shared_frontend)"
        ask_yn "$(t sb.front.ask_mount)" Y && use_nginx=1
    fi

    if (( use_nginx )); then
        _sb_front_ensure_nginx || { log_info "$(t sb.reality.cancelled)"; return 1; }
        if _sb_front_sni_conflict "$server_name"; then
            log_info "$(t sb.reality.cancelled)"; return 1
        fi
        listen_addr="127.0.0.1"
        public_port=443
        while true; do
            ask port "$(t sb.front.ask_local_port)" "$(_sb_front_suggest_local_port $((2443 + count)))"
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                log_error "$(t sb.reality.invalid_port)"; continue
            fi
            if _sb_local_port_in_use "$port"; then
                log_warn "$(t sb.reality.port_in_use "$port")"
                ask_yn "$(t sb.reality.ask_use_port)" N || continue
            fi
            break
        done
        _sb_check_port_conflict "$port" || { log_info "$(t sb.reality.cancelled)"; return 1; }
    else
        # 端口选择：直连监听，每节点独占公网端口
        while true; do
            ask port "$(t sb.reality.ask_port)" "$(_sb_reality_suggest_port)"
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                log_error "$(t sb.reality.invalid_port)"; continue
            fi
            if _sb_reality_port_is_risky "$port"; then
                log_warn "$(t sb.reality.risky_port "$port")"
                ask_yn "$(t sb.reality.ask_use_port)" N || continue
            fi
            if _sb_reality_port_in_use "$port"; then
                log_warn "$(t sb.reality.port_in_use "$port")"
                ask_yn "$(t sb.reality.ask_use_port)" N || continue
            fi
            break
        done
        _sb_check_port_conflict "$port" || { log_info "$(t sb.reality.cancelled)"; return 1; }
        public_port="$port"
    fi

    log_step "$(t sb.reality.gen_keys)"
    _sb_reality_gen_keys || return 1
    local short_id; short_id=$(_sb_reality_gen_shortid)

    log_info "$(t sb.reality.priv_key "$SB_REALITY_PRIVATE_KEY")"
    log_info "$(t sb.reality.pub_key  "$SB_REALITY_PUBLIC_KEY")"
    log_info "$(t sb.reality.short_id "$short_id")"
    log_info "UUID: $uuid"

    local node_json
    node_json=$(jq -n \
        --arg tag         "$tag" \
        --argjson port    "$port" \
        --argjson public_port "$public_port" \
        --arg uuid        "$uuid" \
        --arg priv_key    "$SB_REALITY_PRIVATE_KEY" \
        --arg pub_key     "$SB_REALITY_PUBLIC_KEY" \
        --arg server_name "$server_name" \
        --arg dest        "$dest" \
        --arg flow        "$flow" \
        --argjson short   "[\"$short_id\"]" \
        --arg listen_addr "$listen_addr" \
        '{
          tag: $tag, port: $port, public_port: $public_port, uuid: $uuid,
          private_key: $priv_key, public_key: $pub_key,
          server_name: $server_name, dest: $dest, flow: $flow,
          short_ids: $short, listen_addr: $listen_addr
        }')

    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node_json"
    _sb_reality_apply_or_revert "$_prev_store" || return 1

    echo ""
    log_ok "$(t sb.reality.added "$tag" "$port")"

    # 自有域名模式的 dest 是 127.0.0.1:8443，那个伪装站必须建起来 —— 不管节点挂不挂
    # 443 分流。放在 use_nginx 判断之外：否则「选了自有域名但拒绝挂载」会让 dest 指向
    # 一个从未创建的端口，Reality 回落拿到 connection refused，比不做伪装更暴露。
    if (( own_domain )); then
        source "$LIB_DIR/nginx.sh"
        nginx_setup_camouflage_site "$domain" \
            || log_warn "$(t sb.reality.camouflage_not_enabled)"
    fi

    if (( use_nginx )); then
        # 路由条目在 sing-box 应用成功后再写，避免失败时留下指向死端口的路由
        _sni_add_entry "$server_name" "127.0.0.1:${port}" \
            || log_warn "$(t sb.front.map_failed "$server_name")"
        log_ok "$(t sb.front.mounted "$server_name" "$port")"
    else
        ask_yn "$(t sb.reality.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    sb_reality_show_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_reality_delete_node() {
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag_del)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    ask_yn "$(t sb.reality.ask_confirm_del "$tag")" N || return 0

    # 挂载在 Nginx 443 上的节点：先摘除 SNI 路由条目
    if [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.server_name')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi

    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_delete "$tag"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t sb.reality.deleted "$tag")"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
sb_reality_modify_uuid() {
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    local new_uuid; ask new_uuid "$(t sb.reality.ask_new_uuid)" ""
    [[ -z "$new_uuid" ]] && new_uuid=$("$SB_BIN" generate uuid 2>/dev/null || uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid = $v')
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.reality.uuid_updated "$new_uuid")"
}

sb_reality_modify_port() {
    _sb_reality_sync_from_live
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    local old_port; old_port=$(echo "$node" | jq -r '.port')
    local fronted=0
    [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]] && fronted=1

    local port
    while true; do
        if (( fronted )); then
            ask port "$(t sb.front.ask_local_port)" "$old_port"
        else
            ask port "$(t sb.reality.ask_new_port)" "$old_port"
        fi
        [[ "$port" == "$old_port" ]] && { log_info "$(t sb.reality.port_unchanged)"; return 0; }
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_error "$(t sb.reality.invalid_port)"; continue
        fi
        # 回环端口不暴露公网，风险端口告警只对直连模式有意义
        if (( ! fronted )) && _sb_reality_port_is_risky "$port"; then
            log_warn "$(t sb.reality.risky_port "$port")"
            ask_yn "$(t sb.reality.ask_use_port)" N || continue
        fi
        if _sb_reality_port_in_use "$port"; then
            log_warn "$(t sb.reality.port_in_use "$port")"
            ask_yn "$(t sb.reality.ask_use_port)" N || continue
        fi
        break
    done
    _sb_check_port_conflict "$port" || { log_info "$(t sb.reality.cancelled)"; return 1; }

    node=$(echo "$node" | jq --argjson p "$port" \
        '.port = $p | (if .listen_addr != "127.0.0.1" then .public_port = $p else . end)')
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.reality.port_updated "$tag" "$old_port" "$port")"

    if (( fronted )); then
        # 同步 SNI 路由到新的回环端口
        local sn; sn=$(echo "$node" | jq -r '.server_name')
        source "$LIB_DIR/nginx.sh"
        _sni_add_entry "$sn" "127.0.0.1:${port}" \
            || log_warn "$(t sb.front.map_failed "$sn")"
    else
        ask_yn "$(t sb.reality.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
        log_info "$(t sb.reality.old_port_hint "$old_port")"
    fi
}

sb_reality_rotate_keys() {
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    _sb_reality_gen_keys || return 1
    node=$(echo "$node" | jq --arg k "$SB_REALITY_PRIVATE_KEY" --arg p "$SB_REALITY_PUBLIC_KEY" \
        '.private_key=$k | .public_key=$p')
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.reality.keys_rotated "$SB_REALITY_PUBLIC_KEY")"
}

sb_reality_rotate_shortid() {
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    local sid; sid=$(_sb_reality_gen_shortid)
    node=$(echo "$node" | jq --argjson s "[\"$sid\"]" '.short_ids = $s')
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.reality.shortid_updated "$sid")"
}

sb_reality_modify_servername() {
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    local fronted=0 old_sn port
    [[ "$(echo "$node" | jq -r '.listen_addr // "::"')" == "127.0.0.1" ]] && fronted=1
    old_sn=$(echo "$node" | jq -r '.server_name')
    port=$(echo "$node" | jq -r '.port')
    local sn; ask sn "$(t sb.reality.ask_new_sni)"
    local primary; primary=$(echo "$sn" | cut -d',' -f1 | tr -d ' ')
    if (( fronted )); then
        source "$LIB_DIR/nginx.sh"
        _sb_front_sni_conflict "$primary" "$port" && return 1
    fi
    node=$(echo "$node" | jq --arg p "$primary" '.server_name=$p')
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    if (( fronted )); then
        # SNI 是路由键：迁移 map 条目到新域名
        [[ "$old_sn" != "$primary" ]] && _sni_remove_entry "$old_sn" 2>/dev/null || true
        _sni_add_entry "$primary" "127.0.0.1:${port}" \
            || log_warn "$(t sb.front.map_failed "$primary")"
    fi
    log_ok "$(t sb.reality.sni_updated)"
}

sb_reality_modify_dest() {
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    local dest; ask dest "$(t sb.reality.ask_new_dest)"
    node=$(echo "$node" | jq --arg v "$dest" '.dest = $v')
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.reality.dest_updated)"
}

sb_reality_modify_flow() {
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    echo -e "  1. xtls-rprx-vision\n  2. (none)"
    read -rp "$(echo -e "${CYAN}$(t sb.reality.ask_flow)${NC}")" fc
    local flow; [[ "$fc" == "2" ]] && flow="" || flow="xtls-rprx-vision"
    node=$(echo "$node" | jq --arg v "$flow" '.flow = $v')
    local _prev_store; _prev_store=$(_sb_reality_load)
    _sb_reality_upsert "$node"
    _sb_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.reality.flow_updated)"
}

# ── Export / share ────────────────────────────────────────────────────────────
sb_reality_show_uri() {
    local tag="$1"
    _sb_reality_sync_from_live
    [[ -z "$tag" ]] && { _sb_reality_show_list; ask tag "$(t sb.reality.ask_tag)"; }
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // .port')
    local ipv4;        ipv4=$(get_ipv4)
    local ipv6;        ipv6=$(get_ipv6 2>/dev/null || echo "")

    echo -e "\n${BOLD}${BLUE}══ Reality Node: $tag ══════════════════${NC}"
    printf "  %-14s %s\n" "UUID:"       "$uuid"
    printf "  %-14s %s\n" "Public Key:" "$pub_key"
    printf "  %-14s %s\n" "Short ID:"   "$short_id"
    printf "  %-14s %s\n" "$(t sb.reality.label_port):" "$port"
    printf "  %-14s %s\n" "SNI:"        "$server_name"
    printf "  %-14s %s\n" "Flow:"       "$flow"
    echo ""

    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true

    if [[ -n "$ipv4" ]]; then
        local uri_v4="vless://${uuid}@${ipv4}:${port}?encryption=none&flow=${flow}&security=reality&sni=${server_name}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#PSM-${tag}-v4"
        echo -e "${BOLD}${GREEN}IPv4:${NC}"
        echo "  $uri_v4"
        echo ""
        command -v qrencode &>/dev/null && echo "$uri_v4" | qrencode -t ANSIUTF8 2>/dev/null || true
    fi
    if [[ -n "$ipv6" ]]; then
        local uri_v6="vless://${uuid}@[${ipv6}]:${port}?encryption=none&flow=${flow}&security=reality&sni=${server_name}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#PSM-${tag}-v6"
        echo -e "${BOLD}${GREEN}IPv6:${NC}"
        echo "  $uri_v6"
        echo ""
        command -v qrencode &>/dev/null && echo "$uri_v6" | qrencode -t ANSIUTF8 2>/dev/null || true
    fi
}

sb_reality_export_clash() {
    _sb_reality_sync_from_live
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // .port')
    local ip;          ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}── Clash Meta ──${NC}"
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

# 导出「客户端」用的 sing-box 出站配置（本机是服务端）。
sb_reality_export_singbox() {
    _sb_reality_sync_from_live
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // .port')
    local ip;          ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}── Sing-box $(t sb.reality.outbound_label) ──${NC}"
    jq -n \
        --arg tag "$tag" --arg ip "$ip" --arg uuid "$uuid" \
        --arg flow "$flow" --arg pub_key "$pub_key" \
        --arg short_id "$short_id" --arg sn "$server_name" \
        --argjson port "$port" \
        '{
          type: "vless",
          tag: ("PSM-" + $tag),
          server: $ip,
          server_port: $port,
          uuid: $uuid,
          flow: $flow,
          tls: {
            enabled: true,
            server_name: $sn,
            utls: { enabled: true, fingerprint: "chrome" },
            reality: { enabled: true, public_key: $pub_key, short_id: $short_id }
          }
        }'
}

# ── List helpers ──────────────────────────────────────────────────────────────
_sb_reality_show_list() {
    local nodes; nodes=$(_sb_reality_list)
    if [[ -z "$nodes" ]]; then
        log_warn "$(t sb.reality.none)"
    else
        echo -e "\n${BOLD}$(t sb.reality.list_title):${NC}"
        printf "  %-22s %-6s %-15s %s\n" "$(t sb.reality.col_tag)" "$(t sb.reality.col_port)" "$(t sb.reality.col_listen)" "SNI"
        echo "$nodes" | while IFS=$'\t' read -r tag port listen sn; do
            printf "  %-22s %-6s %-15s %s\n" "$tag" "$port" "$listen" "$sn"
        done
    fi
}

# manager.sh 的“查看所有节点”调用
_sb_reality_show_node_list() {
    local count; count=$(_sb_reality_count)
    echo -e "\n${BOLD}sing-box Reality:${NC}"
    if (( count == 0 )); then echo "  $(t sb.reality.none)"; return; fi
    _sb_reality_list | while IFS=$'\t' read -r tag port listen sn; do
        printf "  %-22s port=%-6s sni=%s\n" "$tag" "$port" "$sn"
    done
}

sb_reality_show_config() {
    _sb_reality_sync_from_live
    _sb_reality_show_list
    local tag; ask tag "$(t sb.reality.ask_tag)"
    local node; node=$(_sb_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.reality.not_found "$tag")"; return 1; }
    echo "$node" | jq .
}

# ── Dependency check ──────────────────────────────────────────────────────────
_sb_reality_check_deps() {
    ensure_pkg_deps jq openssl qrencode
    if [[ ! -f "$SB_BIN" ]]; then
        log_warn "$(t sb.reality.need_singbox)"
        ask_yn "$(t sb.reality.ask_install)" Y \
            && sb_install \
            || { log_error "$(t sb.reality.need_singbox)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_reality_menu() {
    _sb_reality_check_deps || return
    while true; do
        _sb_reality_sync_from_live
        show_menu "$(t sb.reality.menu_title)" \
            "$(t sb.reality.menu.add)" \
            "$(t sb.reality.menu.del)" \
            "$(t sb.reality.menu.uuid)" \
            "$(t sb.reality.menu.port)" \
            "$(t sb.reality.menu.keys)" \
            "$(t sb.reality.menu.shortid)" \
            "$(t sb.reality.menu.sni)" \
            "$(t sb.reality.menu.flow)" \
            "$(t sb.reality.menu.dest)" \
            "$(t sb.reality.menu.uri)" \
            "$(t sb.reality.menu.clash)" \
            "$(t sb.reality.menu.singbox)" \
            "$(t sb.reality.menu.config)" \
            "$(t sb.reality.menu.list)"

        case "$MENU_CHOICE" in
            1)  sb_reality_add_node ;;
            2)  sb_reality_delete_node ;;
            3)  sb_reality_modify_uuid ;;
            4)  sb_reality_modify_port ;;
            5)  sb_reality_rotate_keys ;;
            6)  sb_reality_rotate_shortid ;;
            7)  sb_reality_modify_servername ;;
            8)  sb_reality_modify_flow ;;
            9)  sb_reality_modify_dest ;;
            10) sb_reality_show_uri "" ;;
            11) sb_reality_export_clash ;;
            12) sb_reality_export_singbox ;;
            13) sb_reality_show_config ;;
            14) _sb_reality_show_list ;;
            0)  return ;;
        esac
        press_enter
    done
}
