#!/usr/bin/env bash
# singbox/hysteria2.sh — Hysteria2 (QUIC) inbound via sing-box
#
# 节点存储（config/singbox/hysteria2.json）是唯一事实源，apply 时整体重建
# sing-box 的 hysteria2 入站。支持真实域名证书或自签名。终端输出走 i18n（t sb.hy2.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_HY2_CFG="$SB_STORE_DIR/hysteria2.json"
SB_HY2_DEFAULT_PORT=443
SB_HY2_DEFAULT_MASQ="https://www.bing.com"

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_hy2_load() { [[ -f "$SB_HY2_CFG" ]] && jq '.' "$SB_HY2_CFG" 2>/dev/null || echo '[]'; }
_sb_hy2_save() { mkdir -p "$(dirname "$SB_HY2_CFG")"; printf '%s' "$1" | jq '.' > "$SB_HY2_CFG"; }

_sb_hy2_list()      { _sb_hy2_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.sni)\t\(.insecure)"' 2>/dev/null; }
_sb_hy2_count()     { _sb_hy2_load | jq 'length' 2>/dev/null; }
_sb_hy2_get_by_tag(){ _sb_hy2_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }

_sb_hy2_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local nodes; nodes=$(_sb_hy2_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _sb_hy2_save "$nodes"
}

_sb_hy2_delete() {
    local nodes; nodes=$(_sb_hy2_load)
    _sb_hy2_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

_sb_hy2_select_node() {
    SB_HY2_SEL_TAG=""
    local count; count=$(_sb_hy2_count)
    (( count == 0 )) && { log_warn "$(t sb.hy2.none)"; return 1; }
    local tags_arr=() i=0 tag port sni insec
    while IFS=$'\t' read -r tag port sni insec; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s $(t sb.hy2.col_port) %-6s SNI %s\n" "$i" "$tag" "$port" "$sni"
    done < <(_sb_hy2_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.hy2.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t sb.invalid_option)"; return 1; fi
    SB_HY2_SEL_TAG="${tags_arr[$((sel-1))]}"
}

# ── Build sing-box hysteria2 inbound ──────────────────────────────────────────
# ECH is merged in when the node has keys (lib/common.sh: _sb_ech_merge)
_sb_hy2_build_inbound() { _sb_hy2_build_inbound_base "$1" | _sb_ech_merge "$1"; }
_sb_hy2_build_inbound_base() {
    local node_json="$1"
    local tag;   tag=$(echo "$node_json"   | jq -r '.tag')
    local port;  port=$(echo "$node_json"  | jq -r '.port')
    local pass;  pass=$(echo "$node_json"  | jq -r '.password')
    local sni;   sni=$(echo "$node_json"   | jq -r '.sni')
    local cert;  cert=$(echo "$node_json"  | jq -r '.cert_path')
    local key;   key=$(echo "$node_json"   | jq -r '.key_path')
    local up;    up=$(echo "$node_json"    | jq -r '.up // 0')
    local down;  down=$(echo "$node_json"  | jq -r '.down // 0')
    local masq;  masq=$(echo "$node_json"  | jq -r '.masquerade // ""')
    local obfs;  obfs=$(echo "$node_json"  | jq -r '.obfs_pass // ""')
    # 混淆类型：salamander（默认，老节点没有这个字段）或 gecko（sing-box 1.14+，
    # 在 Salamander 之上对 QUIC 长包头再做分片填充；min/max_packet_size 用内核默认值）
    local otype; otype=$(echo "$node_json" | jq -r '.obfs_type // "salamander"')
    # BBR 配置档（sing-box 1.14+）：conservative / standard / aggressive；未设置不写
    local bbr;   bbr=$(echo "$node_json"   | jq -r '.bbr_profile // ""')
    # 关闭 QUIC 路径 MTU 探测（sing-box 1.14+ 的 QUIC 字段）
    local pmtud; pmtud=$(echo "$node_json" | jq -r 'if .disable_pmtud == true then "true" else "false" end')

    jq -n \
        --arg tag "$tag" --argjson p "$port" --arg pass "$pass" \
        --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        --argjson up "$up" --argjson down "$down" --arg masq "$masq" --arg obfs "$obfs" \
        --arg otype "$otype" --arg bbr "$bbr" --argjson pmtud "$pmtud" \
    '{
        type: "hysteria2",
        tag: $tag,
        listen: "::",
        listen_port: $p,
        users: [ { password: $pass } ]
    }
    + (if $up   > 0 then { up_mbps: $up }     else {} end)
    + (if $down > 0 then { down_mbps: $down } else {} end)
    + (if $obfs != "" then { obfs: { type: $otype, password: $obfs } } else {} end)
    + (if $bbr  != "" then { bbr_profile: $bbr } else {} end)
    + (if $pmtud then { disable_path_mtu_discovery: true } else {} end)
    + (if $masq != ""
       then { masquerade: { type: "proxy", url: $masq, rewrite_host: true } }
       else {} end)
    + {
        tls: {
            enabled: true,
            server_name: $sni,
            alpn: ["h3"],
            certificate_path: $cert,
            key_path: $key
        }
    }'
}

# ── Apply all Hysteria2 nodes into sing-box config ────────────────────────────
_sb_hy2_apply() {
    _sb_cfg_backup   # 事务化：先备份，sb_test_restart 校验失败时回滚
    local nodes; nodes=$(_sb_hy2_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    jq 'del(.inbounds[] | select(((.tag // "") | startswith("sb-hy2-")) or (.type == "hysteria2")))' \
        "$SB_CFG" > "$tmp" && mv "$tmp" "$SB_CFG"

    local i
    for (( i=0; i<count; i++ )); do
        local node; node=$(echo "$nodes" | jq ".[$i]")
        sb_add_inbound "$(_sb_hy2_build_inbound "$node")"
    done
    sb_test_restart || return 1
    source "$LIB_DIR/hop.sh" && psm_hop_sync
}

# 事务化：apply 失败时把节点存储还原为快照 $1，并提示本次变更已撤销。
_sb_hy2_apply_or_revert() {
    _sb_hy2_apply && return 0
    _sb_hy2_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Share URI ─────────────────────────────────────────────────────────────────
_sb_hy2_uri() {
    local tag="$1"
    local node; node=$(_sb_hy2_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "$(t sb.hy2.not_found "$tag")"; return 1; }

    local port pass sni insec obfs otype
    port=$(echo "$node"  | jq -r '.port')
    pass=$(echo "$node"  | jq -r '.password')
    sni=$(echo "$node"   | jq -r '.sni')
    insec=$(echo "$node" | jq -r '.insecure')
    obfs=$(echo "$node"  | jq -r '.obfs_pass // ""')
    otype=$(echo "$node" | jq -r '.obfs_type // "salamander"')
    local hop; hop=$(echo "$node" | jq -r '.hop_ports // ""')

    local ip; ip=$(get_ipv4)
    local uri
    uri="hysteria2://${pass}@${ip}:${port}${hop:+,$hop}?insecure=${insec}&sni=${sni}$(psm_pin_q "$node" pinSHA256)"
    [[ -n "$obfs" ]] && uri="${uri}&obfs=${otype}&obfs-password=${obfs}"
    uri="${uri}#PSM-${tag}"

    echo -e "\n${BOLD}${GREEN}── sing-box Hysteria2: ${tag} ──${NC}"
    [[ "$insec" == "1" ]] && echo -e "  ${YELLOW}$(t sb.hy2.self_cert_hint)${NC}"
    printf "  %-12s %s\n" "$(t sb.hy2.label_server):" "$ip"
    printf "  %-12s %s\n" "$(t sb.hy2.label_port):"   "$port"
    printf "  %-12s %s\n" "$(t sb.hy2.label_pass):"   "$pass"
    printf "  %-12s %s\n" "SNI:"                      "$sni"
    [[ -n "$obfs" ]] && printf "  %-12s %s\n" "Obfs:" "$otype"
    [[ -n "$hop" ]] && printf "  %-12s %s\n" "$(t common.hop.label):" "$hop"
    echo ""
    echo -e "${BOLD}$(t sb.hy2.link_label):${NC}"
    echo "  $uri"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$uri" | qrencode -t ANSIUTF8 2>/dev/null || true

    local obfs_yaml=""
    [[ -n "$obfs" ]] && obfs_yaml=$'\n    obfs: '"${otype}"$'\n    obfs-password: '"${obfs}"
    [[ -n "$hop" ]] && obfs_yaml="${obfs_yaml}"$'\n    ports: '"${hop}"
    echo -e "\n${BOLD}$(t sb.hy2.clash_label):${NC}"
    # a self-signed certificate: mihomo pins it (fingerprint) — see psm_node_pins
    local pin_yaml; pin_yaml=$(psm_pin_yaml "$node")
    [[ -n "$pin_yaml" ]] && pin_yaml=$'\n'"$pin_yaml"
    cat <<EOF
proxies:
  - name: PSM-${tag}
    type: hysteria2
    server: ${ip}
    port: ${port}
    password: "${pass}"
    sni: ${sni}${obfs_yaml}
    skip-cert-verify: $([[ "$insec" == "1" ]] && echo true || echo false)${pin_yaml}
EOF
}

# ── Add node ──────────────────────────────────────────────────────────────────
sb_hy2_add_node() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.hy2.add_title)${NC}"

    local tag port password domain up down masq
    ask tag  "$(t sb.hy2.ask_tag)"  "sb-hy2-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-hy2- ]] || tag="sb-hy2-${tag}"
    ask port "$(t sb.hy2.ask_port)" "$SB_HY2_DEFAULT_PORT"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "$(t sb.hy2.invalid_port)"; return 1
    fi
    _sb_check_port_conflict "$port" || { log_info "$(t sb.hy2.cancelled)"; return 1; }

    password=$(rand_str 24)
    ask password "$(t sb.hy2.ask_pass)" "$password"

    domain=""
    if ask_yn "$(t sb.hy2.ask_has_domain)" N; then
        ask domain "$(t sb.hy2.ask_domain)"
    fi

    # 解析 TLS：域名证书或自签名（自签名时客户端需 insecure=1）
    local tls; tls=$(_sb_resolve_tls "$domain" "$tag" "www.bing.com")
    local cert_path key_path sni insecure
    IFS=$'\t' read -r cert_path key_path sni insecure <<<"$tls"
    _sb_tls_tuple_valid "$cert_path" "$key_path" "$sni" "$insecure" \
        || { log_error "$(t sb.tls.resolve_failed)"; return 1; }

    ask masq "$(t sb.hy2.ask_masq)" "$SB_HY2_DEFAULT_MASQ"
    ask up   "$(t sb.hy2.ask_up)"   "0"
    ask down "$(t sb.hy2.ask_down)" "0"
    [[ "$up"   =~ ^[0-9]+$ ]] || up=0
    [[ "$down" =~ ^[0-9]+$ ]] || down=0

    # Salamander 混淆：开启后 QUIC 报文被混淆，更难被主动探测识别。
    # 服务端与客户端必须使用相同密码，故会写入分享链接。
    local obfs_pass="" obfs_type="salamander"
    if ask_yn "$(t sb.hy2.ask_obfs)" N; then
        ask_hy2_obfs_pass obfs_pass "$(t sb.hy2.ask_obfs_pass)"
        # Gecko：在 Salamander 之上对 QUIC 长包头再做分片填充，抗握手指纹更好，
        # 但服务端需 sing-box 1.14+，客户端也要认识 gecko（mihomo 1.19.26+ / sing-box 1.14+）
        echo -e "  $(t sb.hy2.obfs_t1)"
        echo -e "  $(t sb.hy2.obfs_t2)"
        local oc; read -rp "$(echo -e "${CYAN}$(t sb.hy2.ask_obfs_type)${NC}")" oc
        if [[ "$oc" == "2" ]]; then
            if _sb_version_ge "$(_sb_installed_version)" "1.14.0"; then
                obfs_type="gecko"
            else
                log_warn "$(t sb.hy2.gecko_needs_114)"
            fi
        fi
    fi

    # BBR 配置档（sing-box 1.14+）：只在不限速、走 BBR 时有意义
    local bbr_profile=""
    if (( up == 0 && down == 0 )) && _sb_version_ge "$(_sb_installed_version)" "1.14.0"; then
        ask_hy2_bbr_profile bbr_profile
    fi
    local pmtud=""
    _sb_version_ge "$(_sb_installed_version)" "1.14.0" && ask_hy2_pmtud pmtud

    local hop_ports=""
    source "$LIB_DIR/hop.sh"; ask_hy2_hop_ports hop_ports "$port" "$tag"

    local node_json
    node_json=$(jq -n --arg hop "$hop_ports" \
        --arg tag "$tag" --argjson port "$port" --arg pass "$password" \
        --arg domain "$domain" --arg sni "$sni" \
        --arg cert "$cert_path" --arg key "$key_path" --argjson insec "$insecure" \
        --argjson up "$up" --argjson down "$down" --arg masq "$masq" --arg obfs "$obfs_pass" \
        --arg otype "$obfs_type" --arg bbr "$bbr_profile" --arg pmtud "$pmtud" \
        '{tag:$tag, port:$port, password:$pass, domain:$domain, sni:$sni,
          cert_path:$cert, key_path:$key, insecure:$insec, up:$up, down:$down,
          masquerade:$masq, obfs_pass:$obfs}
         | (if $obfs != "" then .obfs_type = $otype else . end)
         | (if $bbr != "" then .bbr_profile = $bbr else . end)
         | (if $pmtud == "true" then .disable_pmtud = true else . end)
         | (if $hop != "" then .hop_ports = $hop else . end)')

    local _prev_store; _prev_store=$(_sb_hy2_load)
    _sb_hy2_upsert "$node_json"
    _sb_hy2_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.hy2.added "$tag" "$port")"

    ask_yn "$(t sb.hy2.ask_firewall "$port")" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$port" "udp"
    }
    _sb_hy2_uri "$tag"
}

# ── Modify password ───────────────────────────────────────────────────────────
sb_hy2_modify_password() {
    echo -e "\n${BOLD}$(t sb.hy2.modify_pass_title)${NC}"
    _sb_hy2_select_node || return
    local tag="$SB_HY2_SEL_TAG"
    local node; node=$(_sb_hy2_get_by_tag "$tag")
    local pass; ask pass "$(t sb.hy2.ask_new_pass)" ""
    [[ -z "$pass" ]] && pass=$(rand_str 24)
    node=$(echo "$node" | jq --arg v "$pass" '.password = $v')
    local _prev_store; _prev_store=$(_sb_hy2_load)
    _sb_hy2_upsert "$node"
    _sb_hy2_apply_or_revert "$_prev_store" || return 1
    log_ok "$(t sb.hy2.pass_updated "$tag")"
    _sb_hy2_uri "$tag"
}

# ── Delete node ───────────────────────────────────────────────────────────────
sb_hy2_delete_node() {
    echo -e "\n${BOLD}$(t sb.hy2.del_title)${NC}"
    _sb_hy2_select_node || return
    local tag="$SB_HY2_SEL_TAG"
    ask_yn "$(t sb.hy2.ask_confirm_del "$tag")" N || return
    # 删除动作 apply 成功时 store 的删除必须保留；仅在 apply 失败时才还原
    local _prev_store; _prev_store=$(_sb_hy2_load)
    _sb_hy2_delete "$tag"
    _sb_hy2_apply_or_revert "$_prev_store" || return 1
    declare -f _trf_cleanup_node &>/dev/null && \
        source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.hy2.deleted "$tag")"
}

# manager.sh 的“查看所有节点”调用
_sb_hy2_show_node_list() {
    local count; count=$(_sb_hy2_count)
    echo -e "\n${BOLD}sing-box Hysteria2:${NC}"
    if (( count == 0 )); then echo "  $(t sb.hy2.none)"; return; fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    while IFS=$'\t' read -r tag port sni insec; do
        printf "  UDP %s | $(t sb.hy2.col_port): %-6s | SNI: %-20s | tag: %s\n" "$ip" "$port" "$sni" "$tag"
    done < <(_sb_hy2_list)
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_hy2_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.hy2.menu_title)" \
            "$(t sb.hy2.menu.add)" \
            "$(t sb.hy2.menu.view)" \
            "$(t sb.hy2.menu.pass)" \
            "$(t sb.hy2.menu.del)" \
            "$(t sb.hy2.menu.restart)"

        case "$MENU_CHOICE" in
            1) sb_hy2_add_node;  press_enter ;;
            2) _sb_hy2_select_node && _sb_hy2_uri "$SB_HY2_SEL_TAG"; press_enter ;;
            3) sb_hy2_modify_password; press_enter ;;
            4) sb_hy2_delete_node; press_enter ;;
            5) sb_test_restart; press_enter ;;
            0) return ;;
        esac
    done
}
