#!/usr/bin/env bash
# mihomo/routing.sh — proxies / proxy-groups / rules management
#
# 节点入站模块只管理 .listeners；本文件独占 .proxies / .proxy-groups / .rules。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

MH_ROUTE_CFG="$MH_STORE_DIR/routing.json"
MH_WARP_ACCOUNT="$CFG_DIR/xray/warp_account.json"

_mh_route_load() {
    mkdir -p "$(dirname "$MH_ROUTE_CFG")"
    [[ -f "$MH_ROUTE_CFG" ]] && jq '.' "$MH_ROUTE_CFG" 2>/dev/null || echo '{"outbounds":[],"rules":[]}'
}
_mh_route_save() { mkdir -p "$(dirname "$MH_ROUTE_CFG")"; printf '%s' "$1" | jq '.' > "$MH_ROUTE_CFG"; }
_mh_route_outbounds() { _mh_route_load | jq '.outbounds // []'; }
_mh_route_rules() { _mh_route_load | jq '.rules // []'; }
_mh_route_next_id() {
    local max; max=$(_mh_route_rules | jq '[.[].id // "r0" | ltrimstr("r") | tonumber] | max // 0' 2>/dev/null)
    printf 'r%d' "$(( max + 1 ))"
}

_mh_outb_list() {
    _mh_route_outbounds | jq -r '.[] | "\(.name)\t\(.type)\t\(.server // "-"):\(.port // "-")\t\(.remark // "")"' 2>/dev/null
}
_mh_outb_count() { _mh_route_outbounds | jq 'length' 2>/dev/null; }
_mh_rule_count() { _mh_route_rules | jq 'length' 2>/dev/null; }

_mh_outb_upsert() {
    local node="$1" name; name=$(echo "$node" | jq -r '.name')
    local state; state=$(_mh_route_load)
    state=$(echo "$state" | jq --arg n "$name" --argjson node "$node" \
        '.outbounds = ((.outbounds // []) | del(.[] | select(.name == $n)) | . += [$node])')
    _mh_route_save "$state"
}
_mh_outb_delete() {
    local state; state=$(_mh_route_load)
    _mh_route_save "$(echo "$state" | jq --arg n "$1" '.outbounds = ((.outbounds // []) | del(.[] | select(.name == $n)))')"
}
_mh_rule_add() {
    local rule="$1" state; state=$(_mh_route_load)
    _mh_route_save "$(echo "$state" | jq --argjson r "$rule" '.rules = ((.rules // []) + [$r])')"
}
_mh_rule_delete() {
    local state; state=$(_mh_route_load)
    _mh_route_save "$(echo "$state" | jq --arg id "$1" '.rules = ((.rules // []) | del(.[] | select(.id == $id)))')"
}

_mh_outb_build() {
    local e="$1" type; type=$(echo "$e" | jq -r '.type')
    case "$type" in
        ss)
            echo "$e" | jq '{
                name, type:"ss", server, port, cipher, password
            }'
            ;;
        vless-reality)
            echo "$e" | jq '{
                name, type:"vless", server, port, uuid,
                flow: (.flow // "xtls-rprx-vision"),
                tls: true,
                servername: .servername,
                network: "tcp",
                "client-fingerprint": (.fingerprint // "chrome"),
                "reality-opts": {"public-key": ."public-key", "short-id": ."short-id"}
            }'
            ;;
        vless-tls)
            echo "$e" | jq '{
                name, type:"vless", server, port, uuid,
                tls: true, servername: .servername, network: "tcp",
                "client-fingerprint": (.fingerprint // "chrome")
            }'
            ;;
        trojan)
            echo "$e" | jq '{name, type:"trojan", server, port, password, sni:(.sni // .servername // .server)}'
            ;;
        socks5)
            echo "$e" | jq '{
                name, type:"socks5", server, port
            } + (if (.username // "") != "" then {username, password:(.password // "")} else {} end)'
            ;;
        anytls)
            echo "$e" | jq '{
                name, type:"anytls", server, port, password,
                sni:(.sni // .server),
                "skip-cert-verify": (.insecure // false)
            }'
            ;;
        snell)
            echo "$e" | jq '{
                name, type:"snell", server, port, psk, version:(.version // 4)
            } + (if (.obfs_mode // "") != "" then {"obfs-opts": {mode:.obfs_mode, host:(.obfs_host // "bing.com")}} else {} end)'
            ;;
        hysteria2)
            echo "$e" | jq '{
                name, type:"hysteria2", server, port, password,
                sni:(.sni // .server),
                "skip-cert-verify": (.insecure // false)
            } + (if (.obfs_password // "") != "" then {obfs:"salamander", "obfs-password":.obfs_password} else {} end)'
            ;;
        tuic)
            echo "$e" | jq '{
                name, type:"tuic", server, port, uuid, password,
                sni:(.sni // .server), alpn:(.alpn // ["h3"]),
                "skip-cert-verify": (.insecure // false)
            }'
            ;;
        wireguard)
            echo "$e" | jq '{
                name, type:"wireguard", server, port,
                ip, "private-key": ."private-key", "public-key": ."public-key",
                reserved:(.reserved // [0,0,0]), udp:true, mtu:(.mtu // 1280)
            }'
            ;;
    esac
}

_mh_rule_build() {
    local r="$1" kind value target no_resolve
    kind=$(echo "$r" | jq -r '.kind')
    value=$(echo "$r" | jq -r '.value // ""')
    target=$(echo "$r" | jq -r '.target')
    no_resolve=$(echo "$r" | jq -r '.no_resolve // false')
    case "$kind" in
        domain-suffix) printf 'DOMAIN-SUFFIX,%s,%s' "$value" "$target" ;;
        domain-keyword) printf 'DOMAIN-KEYWORD,%s,%s' "$value" "$target" ;;
        geosite) printf 'GEOSITE,%s,%s' "$value" "$target" ;;
        geoip) printf 'GEOIP,%s,%s%s' "$value" "$target" "$([[ "$no_resolve" == "true" ]] && printf ',no-resolve')" ;;
        ip-cidr) printf 'IP-CIDR,%s,%s%s' "$value" "$target" "$([[ "$no_resolve" == "true" ]] && printf ',no-resolve')" ;;
        in-name) printf 'IN-NAME,%s,%s' "$value" "$target" ;;
        ads) printf 'GEOSITE,category-ads-all,REJECT' ;;
        quic) printf 'AND,((NETWORK,udp),(DST-PORT,443)),REJECT' ;;
    esac
}

_mh_route_apply() {
    [[ -f "$MH_CFG" ]] || { log_error "$(t mh.route.no_config)"; return 1; }

    local state outs rules proxies='[]' rules_json='[]' count i
    state=$(_mh_route_load)
    outs=$(echo "$state" | jq '.outbounds // []')
    rules=$(echo "$state" | jq '.rules // []')

    count=$(echo "$outs" | jq 'length')
    for (( i=0; i<count; i++ )); do
        local proxy; proxy=$(_mh_outb_build "$(echo "$outs" | jq ".[$i]")")
        [[ -n "$proxy" ]] && proxies=$(echo "$proxies" | jq --argjson p "$proxy" '. += [$p]')
    done

    count=$(echo "$rules" | jq 'length')
    for (( i=0; i<count; i++ )); do
        local rule; rule=$(_mh_rule_build "$(echo "$rules" | jq ".[$i]")")
        [[ -n "$rule" ]] && rules_json=$(echo "$rules_json" | jq --arg r "$rule" '. += [$r]')
    done
    rules_json=$(echo "$rules_json" | jq '. + ["MATCH,DIRECT"]')

    local tmp; tmp=$(mktemp)
    jq --argjson proxies "$proxies" --argjson rules "$rules_json" \
        '.proxies = $proxies | .["proxy-groups"] = [] | .rules = $rules' "$MH_CFG" > "$tmp" \
        || { rm -f "$tmp"; log_error "$(t mh.route.build_fail)"; return 1; }

    _mh_cfg_backup
    _mh_write_cfg_checked "$tmp" || { rm -f "${MH_CFG}.prev"; return 1; }
    mh_test_restart
}

_mh_ask_outbound_common() {
    local prefix="$1"
    local -n _name="${prefix}_name"
    local -n _remark="${prefix}_remark"
    local -n _server="${prefix}_server"
    local -n _port="${prefix}_port"
    ask "${prefix}_name" "$(t mh.outb.ask_tag)" "out-$(rand_str 5)"
    [[ "$_name" == out-* ]] || _name="out-${_name}"
    ask "${prefix}_remark" "$(t mh.outb.ask_remark)" "$_name"
    ask "${prefix}_server" "$(t mh.outb.ask_addr)" ""
    ask "${prefix}_port" "$(t mh.outb.ask_port)" "443"
    [[ "$_port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$_remark" && -n "$_server" ]] || true
}

mh_outb_add_wizard() {
    _mh_require_installed || return
    echo -e "\n${BOLD}$(t mh.outb.add_title)${NC}\n"
    echo "  1. Shadowsocks"
    echo "  2. VLESS Reality"
    echo "  3. VLESS TLS"
    echo "  4. Trojan"
    echo "  5. SOCKS5"
    echo "  6. AnyTLS"
    echo "  7. Snell"
    echo "  8. Hysteria2"
    echo "  9. TUIC v5"
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.outb.ask_proto)${NC}")" sel

    local o_name o_remark o_server o_port entry
    _mh_ask_outbound_common o || { log_error "$(t mh.outb.err_addr)"; return 1; }
    [[ -z "$o_server" ]] && { log_error "$(t mh.outb.err_addr)"; return 1; }

    case "${sel:-1}" in
        1)
            local cipher pass
            ask cipher "$(t mh.outb.ask_cipher)" "2022-blake3-aes-128-gcm"
            ask pass "$(t mh.outb.ask_pass)" ""
            [[ -z "$pass" ]] && { log_error "$(t mh.outb.err_addr_pass)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" \
                --argjson port "$o_port" --arg cipher "$cipher" --arg password "$pass" \
                '{name:$name,remark:$remark,type:"ss",server:$server,port:$port,cipher:$cipher,password:$password}') ;;
        2)
            local uuid sni pk sid flow fp
            ask uuid "UUID" ""; ask sni "SNI" "$o_server"; ask pk "Public Key" ""; ask sid "Short ID" ""
            ask flow "Flow" "xtls-rprx-vision"; ask fp "Fingerprint" "chrome"
            [[ -z "$uuid" || -z "$pk" ]] && { log_error "$(t mh.outb.err_addr_pk)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg uuid "$uuid" --arg sni "$sni" --arg pk "$pk" --arg sid "$sid" --arg flow "$flow" --arg fp "$fp" \
                '{name:$name,remark:$remark,type:"vless-reality",server:$server,port:$port,uuid:$uuid,servername:$sni,
                  "public-key":$pk,"short-id":$sid,flow:$flow,fingerprint:$fp}') ;;
        3)
            local uuid sni fp
            ask uuid "UUID" ""; ask sni "SNI" "$o_server"; ask fp "Fingerprint" "chrome"
            [[ -z "$uuid" ]] && { log_error "$(t mh.outb.err_addr_uuid)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg uuid "$uuid" --arg sni "$sni" --arg fp "$fp" \
                '{name:$name,remark:$remark,type:"vless-tls",server:$server,port:$port,uuid:$uuid,servername:$sni,fingerprint:$fp}') ;;
        4)
            local pass sni
            ask pass "$(t mh.outb.ask_pass)" ""; ask sni "SNI" "$o_server"
            [[ -z "$pass" ]] && { log_error "$(t mh.outb.err_domain_pass)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg password "$pass" --arg sni "$sni" \
                '{name:$name,remark:$remark,type:"trojan",server:$server,port:$port,password:$password,sni:$sni}') ;;
        5)
            local user pass
            ask user "$(t mh.outb.ask_user)" ""; [[ -n "$user" ]] && ask pass "$(t mh.outb.ask_pass)" ""
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg username "$user" --arg password "${pass:-}" \
                '{name:$name,remark:$remark,type:"socks5",server:$server,port:$port,username:$username,password:$password}') ;;
        6)
            local pass sni insecure=false
            ask pass "$(t mh.outb.ask_pass)" ""; ask sni "SNI" "$o_server"; ask_yn "$(t mh.outb.ask_insecure)" N && insecure=true
            [[ -z "$pass" ]] && { log_error "$(t mh.outb.err_addr_pass)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg password "$pass" --arg sni "$sni" --argjson insecure "$insecure" \
                '{name:$name,remark:$remark,type:"anytls",server:$server,port:$port,password:$password,sni:$sni,insecure:$insecure}') ;;
        7)
            local psk version om oh
            ask psk "$(t mh.outb.ask_snell_psk)" ""; ask version "$(t mh.outb.ask_snell_ver)" "4"
            [[ "$version" =~ ^[0-9]+$ ]] || version=4   # 非数字回落 v4，避免 --argjson 解析失败在 set -e 下退出
            om=""; oh=""
            if ask_yn "$(t mh.outb.ask_snell_obfs)" N; then
                read -rp "$(echo -e "${CYAN}$(t mh.snell.ask_obfs_mode)${NC}")" om
                case "${om:-http}" in tls) om="tls" ;; *) om="http" ;; esac
                ask oh "$(t mh.outb.ask_snell_obfs_host)" "bing.com"
            fi
            [[ -z "$psk" ]] && { log_error "$(t mh.outb.err_addr_pass)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg psk "$psk" --argjson version "$version" --arg om "$om" --arg oh "$oh" \
                '{name:$name,remark:$remark,type:"snell",server:$server,port:$port,psk:$psk,version:$version,obfs_mode:$om,obfs_host:$oh}') ;;
        8)
            local pass sni obfs insecure=false
            ask pass "$(t mh.outb.ask_pass)" ""; ask sni "SNI" "$o_server"; ask obfs "$(t mh.outb.ask_hy2_obfs)" ""
            ask_yn "$(t mh.outb.ask_insecure)" N && insecure=true
            [[ -z "$pass" ]] && { log_error "$(t mh.outb.err_addr_pass)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg password "$pass" --arg sni "$sni" --arg obfs "$obfs" --argjson insecure "$insecure" \
                '{name:$name,remark:$remark,type:"hysteria2",server:$server,port:$port,password:$password,sni:$sni,obfs_password:$obfs,insecure:$insecure}') ;;
        9)
            local uuid pass sni insecure=false
            ask uuid "UUID" ""; ask pass "$(t mh.outb.ask_pass)" ""; ask sni "SNI" "$o_server"
            ask_yn "$(t mh.outb.ask_insecure)" N && insecure=true
            [[ -z "$uuid" ]] && { log_error "$(t mh.outb.err_addr_uuid)"; return 1; }
            entry=$(jq -n --arg name "$o_name" --arg remark "$o_remark" --arg server "$o_server" --argjson port "$o_port" \
                --arg uuid "$uuid" --arg password "$pass" --arg sni "$sni" --argjson insecure "$insecure" \
                '{name:$name,remark:$remark,type:"tuic",server:$server,port:$port,uuid:$uuid,password:$password,sni:$sni,insecure:$insecure}') ;;
        *) log_warn "$(t mh.invalid_option)"; return ;;
    esac

    local prev; prev=$(_mh_route_load)
    _mh_outb_upsert "$entry"
    if _mh_route_apply; then
        log_ok "$(t mh.outb.added "$o_name" "$o_remark")"
    else
        _mh_route_save "$prev"
        log_error "$(t mh.change_reverted)"
        return 1
    fi
}

mh_outb_delete() {
    local count; count=$(_mh_outb_count)
    (( count == 0 )) && { log_warn "$(t mh.outb.none)"; return; }
    local names=() i=0 name type addr remark
    while IFS=$'\t' read -r name type addr remark; do
        i=$((i+1)); names+=("$name")
        printf "  ${CYAN}%2d.${NC} %-18s %-12s %-24s %s\n" "$i" "$name" "$type" "$addr" "$remark"
    done < <(_mh_outb_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.route.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then log_warn "$(t mh.invalid_option)"; return; fi
    local name2="${names[$((sel-1))]}"
    ask_yn "$(t mh.outb.ask_confirm_del "$name2")" N || return
    local prev; prev=$(_mh_route_load)
    _mh_outb_delete "$name2"
    if _mh_route_apply; then
        log_ok "$(t mh.outb.deleted "$name2")"
    else
        _mh_route_save "$prev"
        log_error "$(t mh.change_reverted)"
        return 1
    fi
}

mh_outb_show() {
    echo -e "\n${BOLD}${BLUE}══ $(t mh.outb.list_title) ════════════════════════${NC}"
    if (( $(_mh_outb_count) == 0 )); then
        echo "  $(t mh.outb.none)"
    else
        while IFS=$'\t' read -r name type addr remark; do
            printf "  ${CYAN}%-18s${NC} %-12s %-24s %s\n" "$name" "$type" "$addr" "$remark"
        done < <(_mh_outb_list)
    fi
}

mh_route_add_wizard() {
    _mh_require_installed || return
    local target
    echo -e "\n${BOLD}$(t mh.route.target_title)${NC}"
    echo "  1. DIRECT"
    echo "  2. REJECT"
    local tags=() i=2 name type addr remark
    while IFS=$'\t' read -r name type addr remark; do
        i=$((i+1)); tags+=("$name")
        printf "  ${CYAN}%2d.${NC} %s\n" "$i" "$name"
    done < <(_mh_outb_list)
    local tsel; read -rp "$(echo -e "${CYAN}$(t mh.route.ask_target)${NC}")" tsel
    case "$tsel" in
        1) target="DIRECT" ;;
        2) target="REJECT" ;;
        *) if [[ "$tsel" =~ ^[0-9]+$ ]] && (( tsel >= 3 && tsel <= i )); then
               target="${tags[$((tsel-3))]}"
           else
               log_warn "$(t mh.invalid_option)"; return
           fi ;;
    esac

    echo -e "\n${BOLD}$(t mh.route.type_title)${NC}"
    echo "  1. DOMAIN-SUFFIX"
    echo "  2. DOMAIN-KEYWORD"
    echo "  3. GEOSITE"
    echo "  4. GEOIP"
    echo "  5. IP-CIDR"
    echo "  6. IN-NAME"
    local ksel kind value no_resolve=false
    read -rp "$(echo -e "${CYAN}$(t mh.route.ask_type)${NC}")" ksel
    case "${ksel:-1}" in
        1) kind="domain-suffix"; ask value "$(t mh.route.ask_domain)" "" ;;
        2) kind="domain-keyword"; ask value "$(t mh.route.ask_domain)" "" ;;
        3) kind="geosite"; ask value "$(t mh.route.ask_geosite)" "category-ads-all" ;;
        4) kind="geoip"; ask value "$(t mh.route.ask_geoip)" "cn"; no_resolve=true ;;
        5) kind="ip-cidr"; ask value "$(t mh.route.ask_ip)" ""; no_resolve=true ;;
        6) kind="in-name"; ask value "$(t mh.route.ask_inbound)" "" ;;
        *) log_warn "$(t mh.invalid_option)"; return ;;
    esac
    [[ -z "$value" ]] && { log_error "$(t mh.route.err_empty)"; return 1; }

    local id; id=$(_mh_route_next_id)
    local rule; rule=$(jq -n --arg id "$id" --arg kind "$kind" --arg value "$value" \
        --arg target "$target" --argjson no_resolve "$no_resolve" \
        '{id:$id,kind:$kind,value:$value,target:$target,no_resolve:$no_resolve}')
    local prev; prev=$(_mh_route_load)
    _mh_rule_add "$rule"
    if _mh_route_apply; then
        log_ok "$(t mh.route.added "$kind,$value,$target")"
    else
        _mh_route_save "$prev"
        log_error "$(t mh.change_reverted)"
        return 1
    fi
}

mh_route_delete() {
    local count; count=$(_mh_rule_count)
    (( count == 0 )) && { log_warn "$(t mh.route.none)"; return; }
    local ids=() i=0 rules; rules=$(_mh_route_rules)
    while IFS= read -r r; do
        i=$((i+1)); ids+=("$(echo "$r" | jq -r '.id')")
        printf "  ${CYAN}%2d.${NC} %-14s %-28s → %s\n" "$i" "$(echo "$r" | jq -r '.kind')" "$(echo "$r" | jq -r '.value')" "$(echo "$r" | jq -r '.target')"
    done < <(echo "$rules" | jq -c '.[]')
    local sel; read -rp "$(echo -e "${CYAN}$(t mh.route.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then log_warn "$(t mh.invalid_option)"; return; fi
    local prev; prev=$(_mh_route_load)
    _mh_rule_delete "${ids[$((sel-1))]}"
    if _mh_route_apply; then
        log_ok "$(t mh.route.deleted "${ids[$((sel-1))]}")"
    else
        _mh_route_save "$prev"
        log_error "$(t mh.change_reverted)"
        return 1
    fi
}

mh_route_show() {
    echo -e "\n${BOLD}${BLUE}══ $(t mh.route.list_title) ════════════════════════${NC}"
    if (( $(_mh_rule_count) == 0 )); then
        echo "  $(t mh.route.none)"
    else
        local r
        while IFS= read -r r; do
            printf "  %-14s %-28s → %s\n" "$(echo "$r" | jq -r '.kind')" "$(echo "$r" | jq -r '.value')" "$(echo "$r" | jq -r '.target')"
        done < <(_mh_route_rules | jq -c '.[]')
    fi
    echo "  MATCH,DIRECT"
}

mh_route_toggle_preset() {
    local kind="$1" rules; rules=$(_mh_route_rules)
    if echo "$rules" | jq -e --arg k "$kind" 'any(.[]; .kind == $k)' >/dev/null 2>&1; then
        local state; state=$(_mh_route_load)
        local prev="$state"
        _mh_route_save "$(echo "$state" | jq --arg k "$kind" '.rules = ((.rules // []) | del(.[] | select(.kind == $k)))')"
        if _mh_route_apply; then
            log_ok "$(t mh.route.preset_off "$kind")"
        else
            _mh_route_save "$prev"
            log_error "$(t mh.change_reverted)"
            return 1
        fi
    else
        local id; id=$(_mh_route_next_id)
        local prev; prev=$(_mh_route_load)
        _mh_rule_add "$(jq -n --arg id "$id" --arg kind "$kind" '{id:$id,kind:$kind,value:"",target:"REJECT"}')"
        if _mh_route_apply; then
            log_ok "$(t mh.route.preset_on "$kind")"
        else
            _mh_route_save "$prev"
            log_error "$(t mh.change_reverted)"
            return 1
        fi
    fi
}

mh_warp_setup() {
    _mh_require_installed || return
    [[ -f "$MH_WARP_ACCOUNT" ]] || { log_error "$(t mh.warp.register_fail)"; return 1; }
    local priv reserved ip peer endpoint host port
    priv=$(jq -r '.secret_key // .private_key // empty' "$MH_WARP_ACCOUNT")
    ip=$(jq -r '.local_v4 // "172.16.0.2"' "$MH_WARP_ACCOUNT")
    peer=$(jq -r '.peer_public_key // empty' "$MH_WARP_ACCOUNT")
    reserved=$(jq -c '.reserved // [0,0,0]' "$MH_WARP_ACCOUNT")
    endpoint=$(jq -r '.endpoint // "engage.cloudflareclient.com:2408"' "$MH_WARP_ACCOUNT")
    host="${endpoint%%:*}"
    port="${endpoint##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || port=2408
    [[ -z "$priv" || -z "$peer" ]] && { log_error "$(t mh.warp.register_fail)"; return 1; }
    local entry; entry=$(jq -n --argjson reserved "$reserved" --arg priv "$priv" \
        --arg ip "$ip" --arg peer "$peer" --arg host "$host" --argjson port "$port" \
        '{name:"warp-out",remark:"WARP",type:"wireguard",server:$host,port:$port,
          ip:($ip + "/32"),"private-key":$priv,"public-key":$peer,reserved:$reserved,mtu:1280}')
    local prev; prev=$(_mh_route_load)
    _mh_outb_upsert "$entry"
    if _mh_route_apply; then
        log_ok "$(t mh.warp.added)"
    else
        _mh_route_save "$prev"
        log_error "$(t mh.change_reverted)"
        return 1
    fi
}

mh_route_menu() {
    _mh_require_installed || return
    while true; do
        show_menu "$(t mh.route.menu_title)" \
            "$(t mh.route.menu.show)" \
            "$(t mh.route.menu.add)" \
            "$(t mh.route.menu.del)" \
            "$(t mh.route.menu.outb_show)" \
            "$(t mh.route.menu.outb_add)" \
            "$(t mh.route.menu.outb_del)" \
            "$(t mh.route.menu.warp)" \
            "$(t mh.route.menu.ads)" \
            "$(t mh.route.menu.quic)"

        case "$MENU_CHOICE" in
            1) mh_route_show; press_enter ;;
            2) mh_route_add_wizard; press_enter ;;
            3) mh_route_delete; press_enter ;;
            4) mh_outb_show; press_enter ;;
            5) mh_outb_add_wizard; press_enter ;;
            6) mh_outb_delete; press_enter ;;
            7) mh_warp_setup; press_enter ;;
            8) mh_route_toggle_preset "ads"; press_enter ;;
            9) mh_route_toggle_preset "quic"; press_enter ;;
            0) return ;;
        esac
    done
}
