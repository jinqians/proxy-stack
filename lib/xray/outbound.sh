#!/usr/bin/env bash
# xray/outbound.sh — Custom outbound management (forward to VPS B, etc.)
# Outbound tags are prefixed with "out-" so routing.sh can identify them.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

OUTB_CFG="$CFG_DIR/xray/outbounds.json"

# ── State helpers ─────────────────────────────────────────────────────────────
_outb_load() {
    [[ -f "$OUTB_CFG" ]] && jq '.' "$OUTB_CFG" 2>/dev/null || echo '[]'
}

_outb_save() {
    mkdir -p "$(dirname "$OUTB_CFG")"
    printf '%s' "$1" | jq '.' > "$OUTB_CFG"
}

_outb_list() {
    _outb_load | jq -r '.[] | "\(.tag)\t\(.protocol)\t\(.address):\(.port)\t\(.remark // "")"' 2>/dev/null
}

_outb_count() { _outb_load | jq 'length' 2>/dev/null; }

_outb_get_by_tag() {
    _outb_load | jq ".[] | select(.tag == \"$1\")" 2>/dev/null
}

_outb_upsert() {
    local entry="$1"
    local tag; tag=$(echo "$entry" | jq -r '.tag')
    local nodes; nodes=$(_outb_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$tag\")) | . += [$entry]")
    _outb_save "$nodes"
}

_outb_delete() {
    local nodes; nodes=$(_outb_load)
    nodes=$(echo "$nodes" | jq "del(.[] | select(.tag == \"$1\"))")
    _outb_save "$nodes"
}

# ── Build Xray outbound JSON from stored entry ─────────────────────────────────
_outb_build_xray() {
    local e="$1"
    local proto; proto=$(echo "$e" | jq -r '.protocol')
    local tag;   tag=$(echo "$e"   | jq -r '.tag')
    local addr;  addr=$(echo "$e"  | jq -r '.address')
    local port;  port=$(echo "$e"  | jq -r '.port')

    case "$proto" in
    vless-reality)
        local uuid flow sni fp pk sid
        uuid=$(echo "$e" | jq -r '.uuid')
        flow=$(echo "$e" | jq -r '.flow // "xtls-rprx-vision"')
        sni=$(echo "$e"  | jq -r '.sni')
        fp=$(echo "$e"   | jq -r '.fingerprint // "chrome"')
        pk=$(echo "$e"   | jq -r '.public_key')
        sid=$(echo "$e"  | jq -r '.short_id')
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
               --arg uuid "$uuid" --arg flow "$flow" \
               --arg sni "$sni" --arg fp "$fp" --arg pk "$pk" --arg sid "$sid" \
        '{
            tag: $tag, protocol: "vless",
            settings: { vnext: [{ address: $addr, port: $port,
                users: [{ id: $uuid, flow: $flow, encryption: "none" }] }] },
            streamSettings: {
                network: "tcp", security: "reality",
                realitySettings: { serverName: $sni, fingerprint: $fp,
                                   publicKey: $pk, shortId: $sid }
            }
        }'
        ;;
    vless-tls)
        local uuid flow domain fp
        uuid=$(echo "$e"   | jq -r '.uuid')
        flow=$(echo "$e"   | jq -r '.flow // "xtls-rprx-vision"')
        domain=$(echo "$e" | jq -r '.domain // .address')
        fp=$(echo "$e"     | jq -r '.fingerprint // "chrome"')
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
               --arg uuid "$uuid" --arg flow "$flow" --arg domain "$domain" --arg fp "$fp" \
        '{
            tag: $tag, protocol: "vless",
            settings: { vnext: [{ address: $addr, port: $port,
                users: [{ id: $uuid, flow: $flow, encryption: "none" }] }] },
            streamSettings: {
                network: "tcp", security: "tls",
                tlsSettings: { serverName: $domain, fingerprint: $fp }
            }
        }'
        ;;
    vless-xhttp)
        local uuid domain fp path
        uuid=$(echo "$e"   | jq -r '.uuid')
        domain=$(echo "$e" | jq -r '.domain // .address')
        fp=$(echo "$e"     | jq -r '.fingerprint // "chrome"')
        path=$(echo "$e"   | jq -r '.path // "/"')
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
               --arg uuid "$uuid" --arg domain "$domain" --arg fp "$fp" --arg path "$path" \
        '{
            tag: $tag, protocol: "vless",
            settings: { vnext: [{ address: $addr, port: $port,
                users: [{ id: $uuid, encryption: "none" }] }] },
            streamSettings: {
                network: "xhttp", security: "tls",
                tlsSettings: { serverName: $domain, fingerprint: $fp },
                xhttpSettings: { path: $path }
            }
        }'
        ;;
    shadowsocks)
        local method pass
        method=$(echo "$e" | jq -r '.method')
        pass=$(echo "$e"   | jq -r '.password')
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
               --arg method "$method" --arg pass "$pass" \
        '{
            tag: $tag, protocol: "shadowsocks",
            settings: { servers: [{ address: $addr, port: $port,
                method: $method, password: $pass }] }
        }'
        ;;
    trojan)
        local pass domain fp
        pass=$(echo "$e"   | jq -r '.password')
        domain=$(echo "$e" | jq -r '.domain // .address')
        fp=$(echo "$e"     | jq -r '.fingerprint // "chrome"')
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
               --arg pass "$pass" --arg domain "$domain" --arg fp "$fp" \
        '{
            tag: $tag, protocol: "trojan",
            settings: { servers: [{ address: $addr, port: $port, password: $pass }] },
            streamSettings: {
                network: "tcp", security: "tls",
                tlsSettings: { serverName: $domain, fingerprint: $fp }
            }
        }'
        ;;
    socks5)
        local user pass
        user=$(echo "$e" | jq -r '.username // ""')
        pass=$(echo "$e" | jq -r '.password // ""')
        if [[ -n "$user" ]]; then
            jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
                   --arg user "$user" --arg pass "$pass" \
            '{
                tag: $tag, protocol: "socks",
                settings: { servers: [{ address: $addr, port: $port,
                    users: [{ user: $user, pass: $pass }] }] }
            }'
        else
            jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
            '{
                tag: $tag, protocol: "socks",
                settings: { servers: [{ address: $addr, port: $port }] }
            }'
        fi
        ;;
    wireguard)
        # Cloudflare WARP (or any WireGuard peer). Populated by warp.sh.
        # .family selects which WARP address family the tunnel egresses through:
        #   "4"  → only the v4 tunnel addr + allowedIPs 0.0.0.0/0 + ForceIPv4
        #          → destinations exit via WARP's IPv4
        #   "6"  → only the v6 tunnel addr + allowedIPs ::/0 + ForceIPv6
        #          → destinations exit via WARP's IPv6
        #   "46" → both addrs + both allowedIPs + ForceIP (per-destination)
        # domainStrategy makes domain targets resolve to the chosen family, so a
        # v4-only allowedIPs tunnel never tries to route a AAAA it can't carry.
        local secret v4 v6 pk reserved family addr_arr allowed dstrat
        secret=$(echo "$e" | jq -r '.secret_key')
        v4=$(echo "$e"     | jq -r '.local_v4')
        v6=$(echo "$e"     | jq -r '.local_v6 // ""')
        pk=$(echo "$e"     | jq -r '.peer_public_key')
        reserved=$(echo "$e" | jq -c '.reserved // [0,0,0]')
        family=$(echo "$e" | jq -r '.family // "4"')
        case "$family" in
            6)
                if [[ -n "$v6" ]]; then
                    addr_arr=$(jq -nc --arg a "${v6}/128" '[$a]'); allowed='["::/0"]'; dstrat="ForceIPv6"
                else
                    addr_arr=$(jq -nc --arg a "${v4}/32" '[$a]'); allowed='["0.0.0.0/0"]'; dstrat="ForceIPv4"
                fi
                ;;
            46)
                if [[ -n "$v6" ]]; then
                    addr_arr=$(jq -nc --arg a "${v4}/32" --arg b "${v6}/128" '[$a,$b]'); allowed='["0.0.0.0/0","::/0"]'
                else
                    addr_arr=$(jq -nc --arg a "${v4}/32" '[$a]'); allowed='["0.0.0.0/0"]'
                fi
                dstrat="ForceIP"
                ;;
            *)
                addr_arr=$(jq -nc --arg a "${v4}/32" '[$a]'); allowed='["0.0.0.0/0"]'; dstrat="ForceIPv4"
                ;;
        esac
        # $addr is the endpoint host; an IPv6 literal must be bracketed
        # ([2606:...]:2408) or Xray parses the last ':2408' as part of the IP.
        local ep_host="$addr"
        [[ "$ep_host" == *:* && "$ep_host" != \[*\] ]] && ep_host="[${ep_host}]"
        jq -n --arg tag "$tag" --arg secret "$secret" --argjson addr "$addr_arr" \
               --arg pk "$pk" --arg endpoint "${ep_host}:${port}" --argjson reserved "$reserved" \
               --argjson allowed "$allowed" --arg dstrat "$dstrat" \
        '{
            tag: $tag, protocol: "wireguard",
            settings: {
                secretKey: $secret,
                address: $addr,
                peers: [{ publicKey: $pk, endpoint: $endpoint, allowedIPs: $allowed }],
                reserved: $reserved,
                mtu: 1280,
                domainStrategy: $dstrat
            }
        }'
        ;;
    vpngate)
        # VPNGate 家宽出口（lib/vpngate/）。出站本身就是 freedom 直连，只是给
        # 连接打上 fwmark：内核的 ip rule 认标记，把这些连接引进家宽隧道的独立
        # 路由表。这样出站配置与具体家宽节点无关——换节点只重拨隧道，配置不动。
        # 锁 UseIPv4：隧道只承载 IPv4，解析到 AAAA 会打进隧道表里的 IPv6 黑洞。
        local mark
        mark=$(echo "$e" | jq -r '.mark // 8433')
        jq -n --arg tag "$tag" --argjson mark "$mark" \
        '{
            tag: $tag, protocol: "freedom",
            settings: { domainStrategy: "UseIPv4" },
            streamSettings: { sockopt: { mark: $mark } }
        }'
        ;;
    esac
}

# ── Sync outbound state → Xray config ─────────────────────────────────────────
_outb_apply_to_xray() {
    [[ -f "$XRAY_CFG" ]] || return 1
    local nodes; nodes=$(_outb_load)
    local count; count=$(echo "$nodes" | jq 'length')

    local tmp; tmp=$(mktemp)
    # Remove all PSM-managed outbounds (tag starts with "out-"). Guard the tag
    # with // "" — a tagless outbound (e.g. a "dns" outbound) would otherwise
    # crash jq (startswith needs a string) and blank out the whole config.
    if ! jq 'del(.outbounds[] | select((.tag // "") | startswith("out-")))' "$XRAY_CFG" > "$tmp"; then
        log_error "$(t xray.outbound.read_fail)"; rm -f "$tmp"; return 1
    fi

    local i
    for (( i=0; i<count; i++ )); do
        local entry; entry=$(echo "$nodes" | jq ".[$i]")
        local xray_ob; xray_ob=$(_outb_build_xray "$entry")
        if [[ -n "$xray_ob" ]]; then
            local tmp2; tmp2=$(mktemp)
            if jq --argjson ob "$xray_ob" '.outbounds += [$ob]' "$tmp" > "$tmp2"; then
                mv "$tmp2" "$tmp"
            else
                rm -f "$tmp2"
            fi
        fi
    done

    _xray_write_cfg_checked "$tmp"
}

# ── Interactive: add outbound ─────────────────────────────────────────────────
outb_add_wizard() {
    _xray_require_installed || return
    echo -e "\n${BOLD}$(t xray.outbound.add_title)${NC}"
    echo ""
    echo "  $(t xray.outbound.protocol_title)"
    echo "    $(t xray.outbound.protocol1)"
    echo "    $(t xray.outbound.protocol2)"
    echo "    $(t xray.outbound.protocol3)"
    echo "    $(t xray.outbound.protocol4)"
    echo "    $(t xray.outbound.protocol5)"
    echo "    $(t xray.outbound.protocol6)"
    echo ""
    local proto_sel
    read -rp "$(echo -e "${CYAN}$(t xray.outbound.ask_protocol)${NC}")" proto_sel
    proto_sel="${proto_sel:-1}"

    local remark addr port tag
    ask remark "$(t xray.outbound.ask_remark)" "VPS-B"
    tag="out-$(echo "$remark" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-' | head -c12)"
    ask tag "$(t xray.outbound.ask_tag)" "$tag"
    [[ "$tag" != out-* ]] && tag="out-${tag}"

    case "$proto_sel" in
    1)  # VLESS + Reality
        ask addr "$(t xray.outbound.ask_addr)" ""
        ask port "$(t xray.outbound.ask_port)" "443"
        local uuid sni pk sid flow fp
        ask uuid "UUID"                     "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
        ask sni  "$(t xray.outbound.ask_sni)" "www.cloudflare.com"
        ask pk   "Public Key"               ""
        ask sid  "Short ID"                 ""
        ask fp   "Fingerprint"              "chrome"
        ask flow "Flow"                     "xtls-rprx-vision"
        [[ -z "$addr" || -z "$pk" ]] && { log_error "$(t xray.outbound.addr_pk_required)"; return 1; }
        local entry
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" \
                       --arg proto "vless-reality" --arg addr "$addr" --argjson port "$port" \
                       --arg uuid "$uuid" --arg sni "$sni" --arg pk "$pk" \
                       --arg sid "$sid" --arg fp "$fp" --arg flow "$flow" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,
              uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,fingerprint:$fp,flow:$flow}')
        ;;
    2)  # VLESS + TLS
        ask addr   "$(t xray.outbound.ask_domain)" ""
        ask port   "$(t xray.outbound.ask_port)" "443"
        local uuid domain fp flow
        ask uuid   "UUID"         "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
        ask domain "$(t xray.outbound.sni_domain)" "$addr"
        ask fp     "Fingerprint"  "chrome"
        ask flow   "Flow"         "xtls-rprx-vision"
        [[ -z "$addr" ]] && { log_error "$(t xray.outbound.domain_required)"; return 1; }
        local entry
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" \
                       --arg proto "vless-tls" --arg addr "$addr" --argjson port "$port" \
                       --arg uuid "$uuid" --arg domain "$domain" --arg fp "$fp" --arg flow "$flow" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,
              uuid:$uuid,domain:$domain,fingerprint:$fp,flow:$flow}')
        ;;
    3)  # VLESS + XHTTP
        ask addr   "$(t xray.outbound.ask_domain)" ""
        ask port   "$(t xray.outbound.ask_port)" "443"
        local uuid domain fp path
        ask uuid   "UUID"         "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
        ask domain "$(t xray.outbound.sni_domain)" "$addr"
        ask fp     "Fingerprint"  "chrome"
        ask path   "Path"         "/"
        [[ -z "$addr" ]] && { log_error "$(t xray.outbound.domain_required)"; return 1; }
        local entry
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" \
                       --arg proto "vless-xhttp" --arg addr "$addr" --argjson port "$port" \
                       --arg uuid "$uuid" --arg domain "$domain" --arg fp "$fp" --arg path "$path" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,
              uuid:$uuid,domain:$domain,fingerprint:$fp,path:$path}')
        ;;
    4)  # Shadowsocks
        ask addr   "$(t xray.outbound.ask_addr_short)" ""
        ask port   "$(t xray.outbound.ask_port)" "8388"
        local method pass
        echo "  $(t xray.outbound.cipher_title)"
        echo "    $(t xray.outbound.cipher_line1)"
        echo "    $(t xray.outbound.cipher_line2)"
        local ms; read -rp "$(echo -e "${CYAN}$(t docker.ask_select_1)${NC}")" ms
        case "${ms:-1}" in
            2) method="2022-blake3-aes-256-gcm" ;;
            3) method="2022-blake3-chacha20-poly1305" ;;
            4) method="aes-256-gcm" ;;
            5) method="chacha20-ietf-poly1305" ;;
            *) method="2022-blake3-aes-128-gcm" ;;
        esac
        ask pass "$(t xray.outbound.ask_password)" ""
        [[ -z "$addr" || -z "$pass" ]] && { log_error "$(t xray.outbound.addr_password_required)"; return 1; }
        local entry
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" \
                       --arg proto "shadowsocks" --arg addr "$addr" --argjson port "$port" \
                       --arg method "$method" --arg pass "$pass" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,
              method:$method,password:$pass}')
        ;;
    5)  # Trojan
        ask addr   "$(t xray.outbound.ask_domain)" ""
        ask port   "$(t xray.outbound.ask_port)" "443"
        local pass domain fp
        ask pass   "$(t xray.outbound.ask_password)" ""
        ask domain "$(t xray.outbound.sni_domain)" "$addr"
        ask fp     "Fingerprint"  "chrome"
        [[ -z "$addr" || -z "$pass" ]] && { log_error "$(t xray.outbound.domain_password_required)"; return 1; }
        local entry
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" \
                       --arg proto "trojan" --arg addr "$addr" --argjson port "$port" \
                       --arg pass "$pass" --arg domain "$domain" --arg fp "$fp" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,
              password:$pass,domain:$domain,fingerprint:$fp}')
        ;;
    6)  # SOCKS5
        ask addr "$(t xray.outbound.ask_addr_short)" ""
        ask port "$(t xray.outbound.ask_port)" "1080"
        local user pass
        ask user "$(t xray.outbound.ask_user)" ""
        [[ -n "$user" ]] && ask pass "$(t xray.outbound.ask_password)" ""
        [[ -z "$addr" ]] && { log_error "$(t xray.outbound.addr_required)"; return 1; }
        local entry
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" \
                       --arg proto "socks5" --arg addr "$addr" --argjson port "$port" \
                       --arg user "$user" --arg pass "${pass:-}" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,
              username:$user,password:$pass}')
        ;;
    *)
        log_warn "$(t xray.invalid_option)"; return ;;
    esac

    _outb_upsert "$entry"
    _outb_apply_to_xray
    xray_test_restart   # config on disk is useless until Xray reloads it
    log_ok "$(t xray.outbound.added "$tag" "$remark")"
}

# ── Interactive: delete outbound ──────────────────────────────────────────────
outb_delete() {
    local count; count=$(_outb_count)
    (( count == 0 )) && { log_warn "$(t xray.outbound.no_nodes)"; return; }

    echo -e "\n${BOLD}$(t xray.outbound.delete_title)${NC}"
    local tags_arr=() i=0
    while IFS=$'\t' read -r tag proto addr remark; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s %-16s %-24s %s\n" \
            "$i" "$tag" "$proto" "$addr" "$remark"
    done < <(_outb_list)

    local sel
    read -rp "$(echo -e "${CYAN}$(t xray.select_index_cancel)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t xray.invalid_option)"; return; fi

    local tag="${tags_arr[$((sel-1))]}"
    ask_yn "$(t xray.outbound.ask_delete "$tag")" N || return

    _outb_delete "$tag"
    _outb_apply_to_xray
    xray_test_restart
    log_ok "$(t xray.outbound.deleted "$tag")"
    log_warn "$(t xray.outbound.delete_route_hint)"
}

# ── Display ───────────────────────────────────────────────────────────────────
outb_show() {
    local count; count=$(_outb_count)
    echo -e "\n${BOLD}${BLUE}$(t xray.outbound.list_title)${NC}"
    if (( count == 0 )); then
        echo -e "  ${YELLOW}$(t xray.outbound.none)${NC}"
        echo -e "  $(t xray.outbound.hint)"
    else
        while IFS=$'\t' read -r tag proto addr remark; do
            printf "  ${CYAN}%-20s${NC} %-16s %-26s %s\n" "$tag" "$proto" "$addr" "$remark"
        done < <(_outb_list)
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
outb_menu() {
    _xray_require_installed || return
    while true; do
        show_menu "$(t xray.outbound.menu.title)" \
            "$(t xray.outbound.menu.view)" \
            "$(t xray.outbound.menu.add)" \
            "$(t xray.outbound.menu.delete)"

        case "$MENU_CHOICE" in
            1) outb_show;         press_enter ;;
            2) outb_add_wizard;   press_enter ;;
            3) outb_delete;       press_enter ;;
            0) return ;;
        esac
    done
}
