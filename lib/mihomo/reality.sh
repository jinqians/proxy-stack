#!/usr/bin/env bash
# reality.sh — VLESS + Reality (+Vision) node management for mihomo
#
# 直连监听模式：每个节点占用自己的公网端口，自带 x25519 密钥对与 UUID。
# 节点存储（config/mihomo/reality.json）是唯一事实源，apply 时整体重建
# mihomo 的 vless+reality 入站。所有终端输出走 i18n（t mh.reality.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

MH_REALITY_CFG="$MH_STORE_DIR/reality.json"

MH_REALITY_DEFAULT_PORT=443
# 不出厂预置伪装域名：任何写死的知名域名都可能迁到 CDN 后面变成共享前端（见
# lib/common.sh 的 reality_dest_is_shared_frontend），且全网共用同一个默认值本身
# 就是指纹。本核心没有测绘发现（那是 Xray 专有），所以这里要求显式输入。
MH_REALITY_DEFAULT_DEST=""
MH_REALITY_DEFAULT_SN=""

# 云厂商/ISP 常在上游封锁的端口，直连节点落在这些端口会连不上。
MH_REALITY_RISKY_PORTS="23 25 110 111 135 137 138 139 143 161 389 445 465 587 993 995 1433 2049 3306 3389 5432 6379 27017"

# ── Key generation ────────────────────────────────────────────────────────────
_mh_reality_gen_keys() {
    local pair
    pair=$(mh_gen_reality_keys) || return 1
    MH_REALITY_PRIVATE_KEY="${pair%%$'\t'*}"
    MH_REALITY_PUBLIC_KEY="${pair#*$'\t'}"
}

_mh_reality_gen_shortid() { openssl rand -hex 4; }

# ── Node store ────────────────────────────────────────────────────────────────
_mh_reality_load() { mkdir -p "$(dirname "$MH_REALITY_CFG")"; [[ -f "$MH_REALITY_CFG" ]] || echo "[]" > "$MH_REALITY_CFG"; cat "$MH_REALITY_CFG"; }
_mh_reality_save() { mkdir -p "$(dirname "$MH_REALITY_CFG")"; echo "$1" > "$MH_REALITY_CFG"; }

_mh_reality_list() {
    _mh_reality_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.listen_addr // "::")\t\(.server_name)"' 2>/dev/null
}

_mh_reality_count()      { _mh_reality_load | jq 'length' 2>/dev/null; }
_mh_reality_get_by_tag() { _mh_reality_load | jq --arg tag "$1" '.[] | select(.tag == $tag)' 2>/dev/null; }

_mh_reality_upsert() {
    local node_json="$1" tag; tag=$(echo "$node_json" | jq -r '.tag')
    local nodes; nodes=$(_mh_reality_load)
    nodes=$(echo "$nodes" | jq --arg tag "$tag" --argjson node "$node_json" \
        'del(.[] | select(.tag == $tag)) | . += [$node]')
    _mh_reality_save "$nodes"
}

_mh_reality_delete() {
    local nodes; nodes=$(_mh_reality_load)
    nodes=$(echo "$nodes" | jq --arg tag "$1" 'del(.[] | select(.tag == $tag))')
    _mh_reality_save "$nodes"
}

# ── Sync store from live config ───────────────────────────────────────────────
# 手动编辑 config.yaml（改端口/UUID）后，把改动同步回节点存储，否则菜单显示旧值
# 且下次 apply 会用旧值覆盖手动修改。入站与节点按 tag 一一对应。
_mh_reality_sync_from_live() {
    [[ -f "$MH_CFG" ]] || return 0
    local nodes; nodes=$(_mh_reality_load)
    local count; count=$(echo "$nodes" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    local i changed=0
    for ((i = 0; i < count; i++)); do
        local node tag port uuid live live_port live_uuid
        node=$(echo "$nodes" | jq ".[$i]")
        tag=$(echo "$node"  | jq -r '.tag')
        port=$(echo "$node" | jq -r '.port')
        uuid=$(echo "$node" | jq -r '.uuid')
        live=$(jq -c --arg t "$tag" 'first(.listeners[]? | select(.name == $t)) // empty' "$MH_CFG" 2>/dev/null || true)
        [[ -z "$live" ]] && continue
        live_port=$(echo "$live" | jq -r '.port')
        live_uuid=$(echo "$live" | jq -r '.users[0].uuid')
        [[ "$live_port" == "$port" && "$live_uuid" == "$uuid" ]] && continue
        changed=1
        nodes=$(echo "$nodes" | jq --arg t "$tag" --arg p "$live_port" --arg u "$live_uuid" \
            '(.[] | select(.tag == $t)) |= (.port = ($p|tonumber) | .uuid = $u)')
    done
    if (( changed )); then
        _mh_reality_save "$nodes"
        log_info "$(t mh.reality.synced)"
    fi
    return 0
}

# ── Port selection ────────────────────────────────────────────────────────────
_mh_reality_port_is_risky() {
    local port="$1"; [[ "$port" =~ ^[0-9]+$ ]] || return 1
    echo " $MH_REALITY_RISKY_PORTS " | grep -qF " ${port} "
}

_mh_reality_port_in_use() {
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
_mh_reality_suggest_port() {
    local used port i
    used=" $(_mh_reality_load | jq -r '.[].port' 2>/dev/null | tr '\n' ' ') "
    if [[ "$used" != *" 443 "* ]] && ! _mh_reality_port_in_use 443; then
        printf '443'; return 0
    fi
    for (( i = 0; i < 40; i++ )); do
        port=$(( 20000 + RANDOM * 40001 / 32768 ))
        _mh_reality_port_is_risky "$port" && continue
        [[ "$used" == *" $port "* ]] && continue
        _mh_reality_port_in_use "$port" && continue
        printf '%s' "$port"; return 0
    done
    printf '20000'
}

# ── Build mihomo vless+reality listener ──────────────────────────────────────
_mh_reality_build_listener() {
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
    # 回落限速：仅在 dest 被判定为共享 CDN 前端时写出（见 common.sh 的取值权衡）。
    # 只影响「认证未通过」的回落连接，已认证客户端的代理流量不受任何影响。
    local limit_fb; limit_fb=$(echo "$node_json" | jq -r '.limit_fallback // false')
    local limit_json='{}'
    if [[ "$limit_fb" == "true" ]]; then
        limit_json=$(jq -n \
            --argjson after "$REALITY_FALLBACK_AFTER_BYTES" \
            --argjson rate  "$REALITY_FALLBACK_BYTES_PER_SEC" \
            --argjson burst "$REALITY_FALLBACK_BURST_BYTES_PER_SEC" \
            '{ "limit-fallback-upload":   { "after-bytes": $after, "bytes-per-sec": $rate, "burst-bytes-per-sec": $burst },
               "limit-fallback-download": { "after-bytes": $after, "bytes-per-sec": $rate, "burst-bytes-per-sec": $burst } }')
    fi

    jq -n \
        --argjson limit    "$limit_json" \
        --arg  tag         "$tag" \
        --arg  listen      "$listen_addr" \
        --argjson port     "$port" \
        --arg  uuid        "$uuid" \
        --arg  flow        "$flow" \
        --arg  sn          "$server_name" \
        --arg  dest        "$dest" \
        --arg  priv_key    "$priv_key" \
        --argjson short    "$short_ids" \
    '{
        name: $tag,
        type: "vless",
        port: $port,
        listen: $listen,
        users: [
            ( { username: "u1", uuid: $uuid } + (if $flow == "" then {} else { flow: $flow } end) )
        ],
        "reality-config": ({
            dest: $dest,
            "private-key": $priv_key,
            "short-id": $short,
            "server-names": [$sn]
        } + $limit)
    }'
}

# ── Apply all Reality nodes to mihomo config ────────────────────────────────
_mh_reality_apply_all() {
    _mh_cfg_backup   # 事务化：先备份，mh_test_restart 校验失败时回滚
    local nodes; nodes=$(_mh_reality_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.listeners[] | select(
        ((.name // "") | startswith("mh-reality")) or
        ((.type == "vless") and (has("reality-config")))
    ))' "$MH_CFG" > "$tmp" && mv "$tmp" "$MH_CFG"

    local i
    for ((i = 0; i < count; i++)); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        local listener; listener=$(_mh_reality_build_listener "$node")
        mh_add_listener "$listener"
    done

    mh_test_restart
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_mh_reality_apply_or_revert() {
    _mh_reality_apply_all && return 0
    _mh_reality_save "$1"
    log_error "$(t mh.change_reverted)"
    return 1
}

# ── Add node ──────────────────────────────────────────────────────────────────
mh_reality_add_node() {
    _mh_reality_sync_from_live
    log_step "$(t mh.reality.configuring)"

    local tag port uuid flow server_names_raw dest
    # dest 被判定为共享 CDN 前端且使用者选择继续时置 1 → 给该节点开启回落限速兜底
    local _dest_shared=0
    local count; count=$(_mh_reality_count)

    ask tag "$(t mh.reality.ask_tag)" "mh-reality-$((count+1))"
    [[ "$tag" =~ ^mh-reality ]] || tag="mh-reality-${tag}"

    # P1: ask the SNI first, compute the primary server_name, then default the
    # camouflage dest to it. Reality forwards the client handshake to dest, whose
    # cert must cover the presented SNI — a hardcoded dest that ignored the SNI
    # builds and passes the config test yet lets no client handshake.
    local server_name
    while :; do
        while :; do
            ask server_names_raw "$(t mh.reality.ask_sni)" "$MH_REALITY_DEFAULT_SN"
            server_name=$(echo "$server_names_raw" | cut -d',' -f1 | tr -d ' ')
            [[ -n "$server_name" ]] && break
            log_error "$(t common.reality.sni_empty)"
        done
        [[ -n "$server_name" ]] && break
        log_error "$(t common.reality.sni_empty)"
    done
    ask dest "$(t mh.reality.ask_dest)" "${server_name}:443"

    # P2: advisory validation of the (SNI, dest) pair via the shared openssl-only
    # validator. Never hard-blocks: on failure the operator can re-enter or
    # proceed anyway. Skipped for local/loopback dests.
    while ! reality_dest_is_local "$dest"; do
        log_step "$(t common.reality.checking_dest "$dest" "$server_name")"
        if reality_validate_dest "$dest" "$server_name"; then
            [[ -n "$REALITY_DEST_RTT_MS" ]] && log_info "$(t common.reality.dest_ok "$REALITY_DEST_RTT_MS")"
            # 共享 CDN 前端：握手一切正常，但会让 Reality 的回落变成通往整个 CDN 的
            # 免费隧道。告警而非否决 —— 判定可能误伤，风险由使用者自行取舍。
            # 选择继续时给该节点打开回落限速作为兜底。
            [[ "$REALITY_DEST_WARN" != shared_frontend:* ]] && break
            log_warn "$(t common.reality.dest_shared_frontend "${REALITY_DEST_WARN#shared_frontend:}")"
            ask_yn "$(t common.reality.proceed_anyway)" N && { _dest_shared=1; break; }
        else
            log_warn "$(t common.reality.dest_check_failed "${REALITY_DEST_REASON:-unknown}")"
            ask_yn "$(t common.reality.proceed_anyway)" N && break
        fi
        ask server_names_raw "$(t mh.reality.ask_sni)" "$MH_REALITY_DEFAULT_SN"
        server_name=$(echo "$server_names_raw" | cut -d',' -f1 | tr -d ' ')
        ask dest "$(t mh.reality.ask_dest)" "${server_name}:443"
    done

    ask uuid "$(t mh.reality.ask_uuid)" ""
    [[ -z "$uuid" ]] && uuid=$(mh_gen_uuid)

    echo -e "  1. xtls-rprx-vision\n  2. (none)"
    read -rp "$(echo -e "${CYAN}$(t mh.reality.ask_flow)${NC}")" fc
    [[ "$fc" == "2" ]] && flow="" || flow="xtls-rprx-vision"

    # ── 监听模式：直连独占公网端口（默认），或挂到 Nginx 443 SNI 分流 ──
    # 挂载模式不要求自有域名：Reality 的伪装域名（decoy SNI）就是路由键。
    local listen_addr="0.0.0.0" public_port="" use_nginx=0
    echo ""
    ask_yn "$(t mh.front.ask_mount)" N && use_nginx=1

    if (( use_nginx )); then
        _mh_front_ensure_nginx || { log_info "$(t mh.reality.cancelled)"; return 1; }
        if _mh_front_sni_conflict "$server_name"; then
            log_info "$(t mh.reality.cancelled)"; return 1
        fi
        listen_addr="127.0.0.1"
        public_port=443
        while true; do
            ask port "$(t mh.front.ask_local_port)" "$(_mh_front_suggest_local_port $((4443 + count)))"
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                log_error "$(t mh.reality.invalid_port)"; continue
            fi
            if _mh_local_port_in_use "$port"; then
                log_warn "$(t mh.reality.port_in_use "$port")"
                ask_yn "$(t mh.reality.ask_use_port)" N || continue
            fi
            break
        done
        _mh_check_port_conflict "$port" || { log_info "$(t mh.reality.cancelled)"; return 1; }
    else
        # 端口选择：直连监听，每节点独占公网端口
        while true; do
            ask port "$(t mh.reality.ask_port)" "$(_mh_reality_suggest_port)"
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                log_error "$(t mh.reality.invalid_port)"; continue
            fi
            if _mh_reality_port_is_risky "$port"; then
                log_warn "$(t mh.reality.risky_port "$port")"
                ask_yn "$(t mh.reality.ask_use_port)" N || continue
            fi
            if _mh_reality_port_in_use "$port"; then
                log_warn "$(t mh.reality.port_in_use "$port")"
                ask_yn "$(t mh.reality.ask_use_port)" N || continue
            fi
            break
        done
        _mh_check_port_conflict "$port" || { log_info "$(t mh.reality.cancelled)"; return 1; }
        public_port="$port"
    fi

    log_step "$(t mh.reality.gen_keys)"
    _mh_reality_gen_keys || return 1
    local short_id; short_id=$(_mh_reality_gen_shortid)

    log_info "$(t mh.reality.priv_key "$MH_REALITY_PRIVATE_KEY")"
    log_info "$(t mh.reality.pub_key  "$MH_REALITY_PUBLIC_KEY")"
    log_info "$(t mh.reality.short_id "$short_id")"
    log_info "UUID: $uuid"

    local node_json
    node_json=$(jq -n \
        --arg tag         "$tag" \
        --argjson port    "$port" \
        --argjson public_port "$public_port" \
        --arg uuid        "$uuid" \
        --arg priv_key    "$MH_REALITY_PRIVATE_KEY" \
        --arg pub_key     "$MH_REALITY_PUBLIC_KEY" \
        --arg server_name "$server_name" \
        --arg dest        "$dest" \
        --arg flow        "$flow" \
        --argjson short   "[\"$short_id\"]" \
        --arg listen_addr "$listen_addr" \
        --argjson limit_fb "$([[ $_dest_shared == 1 ]] && echo true || echo false)" \
        '{
          tag: $tag, port: $port, public_port: $public_port, uuid: $uuid,
          private_key: $priv_key, public_key: $pub_key,
          server_name: $server_name, dest: $dest, flow: $flow,
          short_ids: $short, listen_addr: $listen_addr,
          limit_fallback: $limit_fb
        }')

    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node_json"
    _mh_reality_apply_or_revert "$_prev_store" || return 1

    echo ""
    log_ok "$(t mh.reality.added "$tag" "$port")"

    if (( use_nginx )); then
        # 路由条目在 mihomo 应用成功后再写，避免失败时留下指向死端口的路由
        _sni_add_entry "$server_name" "127.0.0.1:${port}" \
            || log_warn "$(t mh.front.map_failed "$server_name")"
        log_ok "$(t mh.front.mounted "$server_name" "$port")"
    else
        ask_yn "$(t mh.reality.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
    fi

    echo ""
    mh_reality_show_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
mh_reality_delete_node() {
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag_del)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    ask_yn "$(t mh.reality.ask_confirm_del "$tag")" N || return 0

    # 挂载在 Nginx 443 上的节点：先摘除 SNI 路由条目
    if [[ "$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')" == "127.0.0.1" ]]; then
        local sn; sn=$(echo "$node" | jq -r '.server_name')
        source "$LIB_DIR/nginx.sh"
        _sni_remove_entry "$sn" 2>/dev/null || true
    fi

    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_delete "$tag"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    if [[ -f "${CFG_DIR}/traffic/state.json" ]]; then
        source "$LIB_DIR/traffic.sh"; _trf_init; _trf_cleanup_node "$tag"
    fi
    log_ok "$(t mh.reality.deleted "$tag")"
}

# ── Modify helpers ────────────────────────────────────────────────────────────
mh_reality_modify_uuid() {
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    local new_uuid; ask new_uuid "$(t mh.reality.ask_new_uuid)" ""
    [[ -z "$new_uuid" ]] && new_uuid=$("$MH_BIN" generate uuid 2>/dev/null || uuid_gen)
    node=$(echo "$node" | jq --arg v "$new_uuid" '.uuid = $v')
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.reality.uuid_updated "$new_uuid")"
}

mh_reality_modify_port() {
    _mh_reality_sync_from_live
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    local old_port; old_port=$(echo "$node" | jq -r '.port')
    local fronted=0
    [[ "$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')" == "127.0.0.1" ]] && fronted=1

    local port
    while true; do
        if (( fronted )); then
            ask port "$(t mh.front.ask_local_port)" "$old_port"
        else
            ask port "$(t mh.reality.ask_new_port)" "$old_port"
        fi
        [[ "$port" == "$old_port" ]] && { log_info "$(t mh.reality.port_unchanged)"; return 0; }
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_error "$(t mh.reality.invalid_port)"; continue
        fi
        # 回环端口不暴露公网，风险端口告警只对直连模式有意义
        if (( ! fronted )) && _mh_reality_port_is_risky "$port"; then
            log_warn "$(t mh.reality.risky_port "$port")"
            ask_yn "$(t mh.reality.ask_use_port)" N || continue
        fi
        if _mh_reality_port_in_use "$port"; then
            log_warn "$(t mh.reality.port_in_use "$port")"
            ask_yn "$(t mh.reality.ask_use_port)" N || continue
        fi
        break
    done
    _mh_check_port_conflict "$port" || { log_info "$(t mh.reality.cancelled)"; return 1; }

    node=$(echo "$node" | jq --argjson p "$port" \
        '.port = $p | (if .listen_addr != "127.0.0.1" then .public_port = $p else . end)')
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.reality.port_updated "$tag" "$old_port" "$port")"

    if (( fronted )); then
        # 同步 SNI 路由到新的回环端口
        local sn; sn=$(echo "$node" | jq -r '.server_name')
        source "$LIB_DIR/nginx.sh"
        _sni_add_entry "$sn" "127.0.0.1:${port}" \
            || log_warn "$(t mh.front.map_failed "$sn")"
    else
        ask_yn "$(t mh.reality.ask_firewall "$port")" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$port" "tcp"
        }
        log_info "$(t mh.reality.old_port_hint "$old_port")"
    fi
}

mh_reality_rotate_keys() {
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    _mh_reality_gen_keys || return 1
    node=$(echo "$node" | jq --arg k "$MH_REALITY_PRIVATE_KEY" --arg p "$MH_REALITY_PUBLIC_KEY" \
        '.private_key=$k | .public_key=$p')
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.reality.keys_rotated "$MH_REALITY_PUBLIC_KEY")"
}

mh_reality_rotate_shortid() {
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    local sid; sid=$(_mh_reality_gen_shortid)
    node=$(echo "$node" | jq --argjson s "[\"$sid\"]" '.short_ids = $s')
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.reality.shortid_updated "$sid")"
}

mh_reality_modify_servername() {
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    local fronted=0 old_sn port
    [[ "$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')" == "127.0.0.1" ]] && fronted=1
    old_sn=$(echo "$node" | jq -r '.server_name')
    port=$(echo "$node" | jq -r '.port')
    local sn; ask sn "$(t mh.reality.ask_new_sni)"
    local primary; primary=$(echo "$sn" | cut -d',' -f1 | tr -d ' ')
    if (( fronted )); then
        source "$LIB_DIR/nginx.sh"
        _mh_front_sni_conflict "$primary" "$port" && return 1
    fi
    node=$(echo "$node" | jq --arg p "$primary" '.server_name=$p')
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    if (( fronted )); then
        # SNI 是路由键：迁移 map 条目到新域名
        [[ "$old_sn" != "$primary" ]] && _sni_remove_entry "$old_sn" 2>/dev/null || true
        _sni_add_entry "$primary" "127.0.0.1:${port}" \
            || log_warn "$(t mh.front.map_failed "$primary")"
    fi
    log_ok "$(t mh.reality.sni_updated)"
}

mh_reality_modify_dest() {
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    local dest; ask dest "$(t mh.reality.ask_new_dest)"
    node=$(echo "$node" | jq --arg v "$dest" '.dest = $v')
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.reality.dest_updated)"
}

mh_reality_modify_flow() {
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    echo -e "  1. xtls-rprx-vision\n  2. (none)"
    read -rp "$(echo -e "${CYAN}$(t mh.reality.ask_flow)${NC}")" fc
    local flow; [[ "$fc" == "2" ]] && flow="" || flow="xtls-rprx-vision"
    node=$(echo "$node" | jq --arg v "$flow" '.flow = $v')
    local _prev_store; _prev_store=$(_mh_reality_load)
    _mh_reality_upsert "$node"
    _mh_reality_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t mh.reality.flow_updated)"
}

# ── Export / share ────────────────────────────────────────────────────────────
mh_reality_show_uri() {
    local tag="$1"
    _mh_reality_sync_from_live
    [[ -z "$tag" ]] && { _mh_reality_show_list; ask tag "$(t mh.reality.ask_tag)"; }
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }

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
    printf "  %-14s %s\n" "$(t mh.reality.label_port):" "$port"
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

mh_reality_export_clash() {
    _mh_reality_sync_from_live
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }

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

# 导出「客户端」用的 mihomo 出站配置（本机是服务端）。
mh_reality_export_mihomo() {
    _mh_reality_sync_from_live
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }

    local uuid;        uuid=$(echo "$node"        | jq -r '.uuid')
    local pub_key;     pub_key=$(echo "$node"     | jq -r '.public_key')
    local short_id;    short_id=$(echo "$node"    | jq -r '.short_ids[0]')
    local server_name; server_name=$(echo "$node" | jq -r '.server_name')
    local flow;        flow=$(echo "$node"        | jq -r '.flow')
    local port;        port=$(echo "$node"        | jq -r '.public_port // .port')
    local ip;          ip=$(get_ipv4)

    echo -e "\n${BOLD}${GREEN}── mihomo $(t mh.reality.outbound_label) ──${NC}"
    jq -n \
        --arg tag "$tag" --arg ip "$ip" --arg uuid "$uuid" \
        --arg flow "$flow" --arg pub_key "$pub_key" \
        --arg short_id "$short_id" --arg sn "$server_name" \
        --argjson port "$port" \
        '{
          name: ("PSM-" + $tag),
          type: "vless",
          server: $ip,
          port: $port,
          uuid: $uuid,
          flow: $flow,
          tls: true,
          servername: $sn,
          network: "tcp",
          "client-fingerprint": "chrome",
          "reality-opts": {
            "public-key": $pub_key,
            "short-id": $short_id
          }
        }'
}

# ── List helpers ──────────────────────────────────────────────────────────────
_mh_reality_show_list() {
    local nodes; nodes=$(_mh_reality_list)
    if [[ -z "$nodes" ]]; then
        log_warn "$(t mh.reality.none)"
    else
        echo -e "\n${BOLD}$(t mh.reality.list_title):${NC}"
        printf "  %-22s %-6s %-15s %s\n" "$(t mh.reality.col_tag)" "$(t mh.reality.col_port)" "$(t mh.reality.col_listen)" "SNI"
        echo "$nodes" | while IFS=$'\t' read -r tag port listen sn; do
            printf "  %-22s %-6s %-15s %s\n" "$tag" "$port" "$listen" "$sn"
        done
    fi
}

# manager.sh 的“查看所有节点”调用
_mh_reality_show_node_list() {
    local count; count=$(_mh_reality_count)
    echo -e "\n${BOLD}mihomo Reality:${NC}"
    if (( count == 0 )); then echo "  $(t mh.reality.none)"; return; fi
    _mh_reality_list | while IFS=$'\t' read -r tag port listen sn; do
        printf "  %-22s port=%-6s sni=%s\n" "$tag" "$port" "$sn"
    done
}

mh_reality_show_config() {
    _mh_reality_sync_from_live
    _mh_reality_show_list
    local tag; ask tag "$(t mh.reality.ask_tag)"
    local node; node=$(_mh_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t mh.reality.not_found "$tag")"; return 1; }
    echo "$node" | jq .
}

# ── Dependency check ──────────────────────────────────────────────────────────
_mh_reality_check_deps() {
    ensure_pkg_deps jq openssl qrencode
    if [[ ! -f "$MH_BIN" ]]; then
        log_warn "$(t mh.reality.need_mihomo)"
        ask_yn "$(t mh.reality.ask_install)" Y \
            && mh_install \
            || { log_error "$(t mh.reality.need_mihomo)"; return 1; }
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
mh_reality_menu() {
    _mh_reality_check_deps || return
    while true; do
        _mh_reality_sync_from_live
        show_menu "$(t mh.reality.menu_title)" \
            "$(t mh.reality.menu.add)" \
            "$(t mh.reality.menu.del)" \
            "$(t mh.reality.menu.uuid)" \
            "$(t mh.reality.menu.port)" \
            "$(t mh.reality.menu.keys)" \
            "$(t mh.reality.menu.shortid)" \
            "$(t mh.reality.menu.sni)" \
            "$(t mh.reality.menu.flow)" \
            "$(t mh.reality.menu.dest)" \
            "$(t mh.reality.menu.uri)" \
            "$(t mh.reality.menu.clash)" \
            "$(t mh.reality.menu.mihomo)" \
            "$(t mh.reality.menu.config)" \
            "$(t mh.reality.menu.list)"

        case "$MENU_CHOICE" in
            1)  mh_reality_add_node ;;
            2)  mh_reality_delete_node ;;
            3)  mh_reality_modify_uuid ;;
            4)  mh_reality_modify_port ;;
            5)  mh_reality_rotate_keys ;;
            6)  mh_reality_rotate_shortid ;;
            7)  mh_reality_modify_servername ;;
            8)  mh_reality_modify_flow ;;
            9)  mh_reality_modify_dest ;;
            10) mh_reality_show_uri "" ;;
            11) mh_reality_export_clash ;;
            12) mh_reality_export_mihomo ;;
            13) mh_reality_show_config ;;
            14) _mh_reality_show_list ;;
            0)  return ;;
        esac
        press_enter
    done
}
