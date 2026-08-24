#!/usr/bin/env bash
# singbox/routing.sh — Traffic routing / split (分流) management for sing-box
#
# 管理三样东西，routing.sh 独占 sing-box config 的 .route / .outbounds / .endpoints：
#   1) 出站节点（转发到 VPS B、WARP 等）— 存 config/singbox/outbounds.json
#   2) 路由规则（geosite/geoip/域名/IP/入站 → 出站，或拦截）— 存 config/singbox/routing_rules.json
#   3) 预设玩法：一键拦截广告、屏蔽 QUIC、WARP 解锁 Netflix/OpenAI
# sing-box 1.11+ 用 rule_set（远程 .srs）替代 geoip.dat/geosite.dat；WARP 走 wireguard endpoint。
# 终端输出走 i18n（t sb.route.* / sb.outb.*）。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../warp_probe.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_OUTB_CFG="$SB_STORE_DIR/outbounds.json"
SB_ROUTE_CFG="$SB_STORE_DIR/routing_rules.json"
SB_WARP_ACCOUNT="$CFG_DIR/xray/warp_account.json"   # 复用 xray 注册的 WARP 身份

SB_GEOSITE_BASE="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
SB_GEOIP_BASE="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set"

# ── Outbound store ────────────────────────────────────────────────────────────
_sb_outb_load()  { [[ -f "$SB_OUTB_CFG" ]] && jq '.' "$SB_OUTB_CFG" 2>/dev/null || echo '[]'; }
_sb_outb_save()  { mkdir -p "$(dirname "$SB_OUTB_CFG")"; printf '%s' "$1" | jq '.' > "$SB_OUTB_CFG"; }
_sb_outb_list()  { _sb_outb_load | jq -r '.[] | "\(.tag)\t\(.protocol)\t\(.address // "-"):\(.port // "-")\t\(.remark // "")"' 2>/dev/null; }
_sb_outb_count() { _sb_outb_load | jq 'length' 2>/dev/null; }

_sb_outb_upsert() {
    local e="$1" tag; tag=$(echo "$e" | jq -r '.tag')
    local nodes; nodes=$(_sb_outb_load)
    nodes=$(echo "$nodes" | jq --arg t "$tag" --argjson e "$e" 'del(.[] | select(.tag == $t)) | . += [$e]')
    _sb_outb_save "$nodes"
}
_sb_outb_delete() {
    local nodes; nodes=$(_sb_outb_load)
    _sb_outb_save "$(echo "$nodes" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

# ── Rule store ────────────────────────────────────────────────────────────────
_sb_route_load()  { [[ -f "$SB_ROUTE_CFG" ]] && jq '.' "$SB_ROUTE_CFG" 2>/dev/null || echo '[]'; }
_sb_route_save()  { mkdir -p "$(dirname "$SB_ROUTE_CFG")"; printf '%s' "$1" | jq '.' > "$SB_ROUTE_CFG"; }
_sb_route_count() { _sb_route_load | jq 'length' 2>/dev/null; }
_sb_route_next_id() {
    local max; max=$(_sb_route_load | jq '[.[].id // "r0" | ltrimstr("r") | tonumber] | max // 0' 2>/dev/null)
    printf 'r%d' "$(( max + 1 ))"
}

# ── Build one sing-box outbound (non-WARP) from a stored entry ─────────────────
_sb_outb_build() {
    local e="$1"
    local proto; proto=$(echo "$e" | jq -r '.protocol')
    local tag;   tag=$(echo "$e"   | jq -r '.tag')
    local addr;  addr=$(echo "$e"  | jq -r '.address')
    local port;  port=$(echo "$e"  | jq -r '.port')

    case "$proto" in
    shadowsocks)
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --arg method "$(echo "$e" | jq -r '.method')" \
              --arg pass "$(echo "$e" | jq -r '.password')" \
        '{type:"shadowsocks", tag:$tag, server:$addr, server_port:$port, method:$method, password:$pass}'
        ;;
    vless-reality)
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --arg uuid "$(echo "$e" | jq -r '.uuid')" \
              --arg flow "$(echo "$e" | jq -r '.flow // "xtls-rprx-vision"')" \
              --arg sni  "$(echo "$e" | jq -r '.sni')" \
              --arg fp   "$(echo "$e" | jq -r '.fingerprint // "chrome"')" \
              --arg pk   "$(echo "$e" | jq -r '.public_key')" \
              --arg sid  "$(echo "$e" | jq -r '.short_id')" \
        '{type:"vless", tag:$tag, server:$addr, server_port:$port, uuid:$uuid, flow:$flow,
          tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:$fp},
               reality:{enabled:true, public_key:$pk, short_id:$sid}}}'
        ;;
    vless-tls)
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --arg uuid "$(echo "$e" | jq -r '.uuid')" \
              --arg flow "$(echo "$e" | jq -r '.flow // "xtls-rprx-vision"')" \
              --arg domain "$(echo "$e" | jq -r '.domain // .address')" \
              --arg fp "$(echo "$e" | jq -r '.fingerprint // "chrome"')" \
        '{type:"vless", tag:$tag, server:$addr, server_port:$port, uuid:$uuid, flow:$flow,
          tls:{enabled:true, server_name:$domain, utls:{enabled:true, fingerprint:$fp}}}'
        ;;
    trojan)
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --arg pass "$(echo "$e" | jq -r '.password')" \
              --arg domain "$(echo "$e" | jq -r '.domain // .address')" \
              --arg fp "$(echo "$e" | jq -r '.fingerprint // "chrome"')" \
        '{type:"trojan", tag:$tag, server:$addr, server_port:$port, password:$pass,
          tls:{enabled:true, server_name:$domain, utls:{enabled:true, fingerprint:$fp}}}'
        ;;
    socks5)
        local user; user=$(echo "$e" | jq -r '.username // ""')
        if [[ -n "$user" ]]; then
            jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
                  --arg user "$user" --arg pass "$(echo "$e" | jq -r '.password // ""')" \
            '{type:"socks", tag:$tag, server:$addr, server_port:$port, version:"5", username:$user, password:$pass}'
        else
            jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
            '{type:"socks", tag:$tag, server:$addr, server_port:$port, version:"5"}'
        fi
        ;;
    anytls)
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --arg pass "$(echo "$e" | jq -r '.password')" \
              --arg sni "$(echo "$e" | jq -r '.sni // .address')" \
              --argjson insec "$(echo "$e" | jq -r '.insecure // false')" \
              --arg fp "$(echo "$e" | jq -r '.fingerprint // "chrome"')" \
        '{type:"anytls", tag:$tag, server:$addr, server_port:$port, password:$pass,
          tls:{enabled:true, server_name:$sni, insecure:$insec, utls:{enabled:true, fingerprint:$fp}}}'
        ;;
    snell)
        # sing-box 无 Snell 入站，但支持 Snell 出站 → 可对流量做「走 Snell 服务器」的分流。
        # v4 支持 http 混淆；v6 用整形模式，psk 需 12–255 字节。
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --argjson ver "$(echo "$e" | jq -r '.version // 4')" \
              --arg psk "$(echo "$e" | jq -r '.psk')" \
              --arg om "$(echo "$e" | jq -r '.obfs_mode // ""')" \
              --arg oh "$(echo "$e" | jq -r '.obfs_host // ""')" \
        '{type:"snell", tag:$tag, server:$addr, server_port:$port, version:$ver, psk:$psk}
         + (if $om == "http" then {obfs_mode:"http", obfs_host:(if $oh == "" then "bing.com" else $oh end)} else {} end)'
        ;;
    hysteria2)
        # 空 up/down → 客户端走 BBR。可选 salamander 混淆。
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --arg pass "$(echo "$e" | jq -r '.password')" \
              --arg sni "$(echo "$e" | jq -r '.sni // .address')" \
              --argjson insec "$(echo "$e" | jq -r '.insecure // false')" \
              --arg obfs "$(echo "$e" | jq -r '.obfs_pass // ""')" \
        '{type:"hysteria2", tag:$tag, server:$addr, server_port:$port, password:$pass,
          tls:{enabled:true, server_name:$sni, insecure:$insec, alpn:["h3"]}}
         + (if $obfs != "" then {obfs:{type:"salamander", password:$obfs}} else {} end)'
        ;;
    tuic)
        jq -n --arg tag "$tag" --arg addr "$addr" --argjson port "$port" \
              --arg uuid "$(echo "$e" | jq -r '.uuid')" \
              --arg pass "$(echo "$e" | jq -r '.password // ""')" \
              --arg sni "$(echo "$e" | jq -r '.sni // .address')" \
              --argjson insec "$(echo "$e" | jq -r '.insecure // false')" \
              --arg cc "$(echo "$e" | jq -r '.congestion // "bbr"')" \
        '{type:"tuic", tag:$tag, server:$addr, server_port:$port, uuid:$uuid, password:$pass,
          congestion_control:$cc,
          tls:{enabled:true, server_name:$sni, insecure:$insec, alpn:["h3"]}}'
        ;;
    vpngate)
        # VPNGate 家宽出口（lib/vpngate/）：direct 出站 + routing_mark。标记由内核
        # 的 ip rule 引进家宽隧道的独立路由表，出站配置因此与具体节点无关，换家宽
        # IP 时这里一个字都不用改。
        # 域名一律解析成 IPv4：隧道只承载 IPv4，AAAA 会撞上隧道表里的 IPv6 黑洞。
        # 1.12 起 dial 字段 domain_strategy 被 domain_resolver 取代（1.14 已移除），
        # 按实装版本二选一；psm-local 这个 DNS server 由 _sb_route_apply 顺带补齐。
        local mark cur dr
        mark=$(echo "$e" | jq -r '.mark // 8433')
        cur=$(_sb_installed_version 2>/dev/null) || cur=""
        if [[ -n "$cur" ]] && _sb_version_ge "$cur" "1.12.0"; then
            dr='{"domain_resolver":{"server":"psm-local","strategy":"ipv4_only"}}'
        else
            dr='{"domain_strategy":"ipv4_only"}'
        fi
        jq -n --arg tag "$tag" --argjson mark "$mark" --argjson dr "$dr" \
        '{type:"direct", tag:$tag, routing_mark:$mark} + $dr'
        ;;
    esac
}

# ── Build a WARP wireguard endpoint (sing-box 1.11+ .endpoints) ────────────────
_sb_outb_build_warp() {
    local e="$1"
    local tag; tag=$(echo "$e" | jq -r '.tag')
    local family; family=$(echo "$e" | jq -r '.family // "4"')
    [[ -f "$SB_WARP_ACCOUNT" ]] || return 1
    local acc; acc=$(cat "$SB_WARP_ACCOUNT")

    local secret v4 v6 pk reserved endpoint host port
    secret=$(echo "$acc" | jq -r '.secret_key')
    v4=$(echo "$acc"     | jq -r '.local_v4')
    v6=$(echo "$acc"     | jq -r '.local_v6 // ""')
    pk=$(echo "$acc"     | jq -r '.peer_public_key')
    reserved=$(echo "$acc" | jq -c '.reserved // [0,0,0]')
    endpoint=$(echo "$acc" | jq -r '.endpoint')
    host="${endpoint%%:*}"; port="${endpoint##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || port=2408

    local addr_arr allowed
    case "$family" in
        6)  if [[ -n "$v6" ]]; then addr_arr=$(jq -nc --arg a "${v6}/128" '[$a]'); allowed='["::/0"]'
            else addr_arr=$(jq -nc --arg a "${v4}/32" '[$a]'); allowed='["0.0.0.0/0"]'; fi ;;
        46) if [[ -n "$v6" ]]; then addr_arr=$(jq -nc --arg a "${v4}/32" --arg b "${v6}/128" '[$a,$b]'); allowed='["0.0.0.0/0","::/0"]'
            else addr_arr=$(jq -nc --arg a "${v4}/32" '[$a]'); allowed='["0.0.0.0/0"]'; fi ;;
        *)  addr_arr=$(jq -nc --arg a "${v4}/32" '[$a]'); allowed='["0.0.0.0/0"]' ;;
    esac

    jq -n --arg tag "$tag" --argjson addr "$addr_arr" --arg secret "$secret" \
          --arg host "$host" --argjson port "$port" --arg pk "$pk" \
          --argjson reserved "$reserved" --argjson allowed "$allowed" \
    '{
        type:"wireguard", tag:$tag, system:false, mtu:1280,
        address:$addr, private_key:$secret,
        peers:[{ address:$host, port:$port, public_key:$pk, reserved:$reserved,
                 allowed_ips:$allowed, persistent_keepalive_interval:25 }]
    }'
}

# ── Rule-set definition for a geosite-/geoip- tag ─────────────────────────────
# 下载出站的写法随内核版本变化，两种形式互不兼容，必须按已装版本二选一：
#   < 1.14  →  download_detour:"direct"   （1.14 起弃用，1.16 移除；1.13 不认识 http_client）
#  >= 1.14  →  http_client:{detour:"direct"} （1.14 新增，同时消掉「隐式默认 HTTP 客户端」弃用告警）
# 版本读不出来时按旧写法处理：老内核用新字段会直接 fatal，新内核用旧字段只是告警。
_sb_ruleset_def() {
    local tag="$1" url
    case "$tag" in
        geosite-*) url="${SB_GEOSITE_BASE}/${tag}.srs" ;;
        geoip-*)   url="${SB_GEOIP_BASE}/${tag}.srs" ;;
        *) return 1 ;;
    esac
    local cur; cur=$(_sb_installed_version)
    local detour
    if [[ -n "$cur" ]] && _sb_version_ge "$cur" "1.14.0"; then
        detour='{"http_client":{"detour":"direct"}}'
    else
        detour='{"download_detour":"direct"}'
    fi
    jq -n --arg tag "$tag" --arg url "$url" --argjson d "$detour" \
        '{tag:$tag, type:"remote", format:"binary", url:$url} + $d'
}

# 目标片段：reject → {action:reject}；否则 → {outbound:tag}
_sb_route_target_obj() {
    local target="$1"
    if [[ "$target" == "reject" ]]; then echo '{"action":"reject"}'
    else jq -n --arg o "$target" '{outbound:$o}'; fi
}

# 单条规则条目 → 它用到的 rule_set tag（空格分隔，无则为空）。
# 独立函数：在父 shell 收集 tag，避免 _sb_route_build_rule 在 $() 子 shell 里改全局丢失。
_sb_route_ruleset_tags() {
    local e="$1"
    local rtype; rtype=$(echo "$e" | jq -r '.rule_type')
    local val;   val=$(echo "$e"  | jq -r '.value')
    case "$rtype" in
    geosite)    echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d;s/^/geosite-/' | tr '\n' ' ' ;;
    geoip)      echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d;s/^/geoip-/'   | tr '\n' ' ' ;;
    preset-ads) echo "geosite-category-ads-all" ;;
    esac
}

# 单条规则条目 → sing-box route 规则对象（纯函数，只吐 JSON，不改全局）。
_sb_route_build_rule() {
    local e="$1"
    local rtype; rtype=$(echo "$e" | jq -r '.rule_type')
    local val;   val=$(echo "$e"  | jq -r '.value')
    local target; target=$(echo "$e" | jq -r '.target')
    local tgt; tgt=$(_sb_route_target_obj "$target")

    case "$rtype" in
    geosite)
        local tags; tags=$(echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d;s/^/geosite-/' | jq -R . | jq -sc .)
        jq -nc --argjson rs "$tags" --argjson t "$tgt" '{rule_set:$rs} + $t' ;;
    geoip)
        local tags; tags=$(echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d;s/^/geoip-/' | jq -R . | jq -sc .)
        jq -nc --argjson rs "$tags" --argjson t "$tgt" '{rule_set:$rs} + $t' ;;
    domain)
        local arr; arr=$(echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d' | jq -R . | jq -sc .)
        jq -nc --argjson d "$arr" --argjson t "$tgt" '{domain_suffix:$d} + $t' ;;
    ip)
        local arr; arr=$(echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d' | jq -R . | jq -sc .)
        jq -nc --argjson c "$arr" --argjson t "$tgt" '{ip_cidr:$c} + $t' ;;
    inbound)
        local arr; arr=$(echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//;/^$/d' | jq -R . | jq -sc .)
        jq -nc --argjson i "$arr" --argjson t "$tgt" '{inbound:$i} + $t' ;;
    preset-ads)
        jq -nc '{rule_set:["geosite-category-ads-all"], action:"reject"}' ;;
    preset-quic)
        jq -nc '{network:"udp", port:[443], action:"reject"}' ;;
    esac
}

# ── Apply routing state → sing-box config ─────────────────────────────────────
# routing.sh 独占 .route / .outbounds / .endpoints，按存储确定性重建，避免脆弱的
# 增量删改。协议模块只碰 .inbounds，互不干扰。
_sb_route_apply() {
    [[ -f "$SB_CFG" ]] || { log_error "$(t sb.route.no_config)"; return 1; }
    local outs; outs=$(_sb_outb_load)
    local rules; rules=$(_sb_route_load)
    local ocount; ocount=$(echo "$outs" | jq 'length')
    local rcount; rcount=$(echo "$rules" | jq 'length')

    # 1) 构建出站 / endpoints
    local OBS='[]' EPS='[]' i
    for (( i=0; i<ocount; i++ )); do
        local e; e=$(echo "$outs" | jq ".[$i]")
        local proto; proto=$(echo "$e" | jq -r '.protocol')
        if [[ "$proto" == "warp" ]]; then
            local ep; ep=$(_sb_outb_build_warp "$e") || continue
            [[ -n "$ep" ]] && EPS=$(echo "$EPS" | jq --argjson o "$ep" '. += [$o]')
        else
            local ob; ob=$(_sb_outb_build "$e")
            [[ -n "$ob" ]] && OBS=$(echo "$OBS" | jq --argjson o "$ob" '. += [$o]')
        fi
    done

    # 2) 构建路由规则 + 收集 rule_set tag（在父 shell 累积，避免子 shell 丢失）
    local RR='[]' rs_tags=""
    for (( i=0; i<rcount; i++ )); do
        local e; e=$(echo "$rules" | jq ".[$i]")
        local r; r=$(_sb_route_build_rule "$e")
        [[ -n "$r" ]] && RR=$(echo "$RR" | jq --argjson x "$r" '. += [$x]')
        rs_tags="$rs_tags $(_sb_route_ruleset_tags "$e")"
    done
    # 去重 rule_set tags → 定义数组
    local RS='[]' t
    for t in $(echo "$rs_tags" | tr ' ' '\n' | sed '/^$/d' | sort -u); do
        local def; def=$(_sb_ruleset_def "$t") || continue
        RS=$(echo "$RS" | jq --argjson d "$def" '. += [$d]')
    done

    # VPNGate 家宽出口在 sing-box 1.12+ 需要一个具名 DNS server 供 domain_resolver
    # 引用（dial 字段 domain_strategy 已于 1.14 移除）。没有家宽出站时不碰 .dns，
    # 有则补一个 type:local 的 psm-local——它等价于原本隐式的系统解析行为。
    local NEEDDNS=false cur_ver
    cur_ver=$(_sb_installed_version 2>/dev/null) || cur_ver=""
    if [[ "$(echo "$outs" | jq '[.[] | select(.protocol == "vpngate")] | length')" != "0" ]] \
        && [[ -n "$cur_ver" ]] && _sb_version_ge "$cur_ver" "1.12.0"; then
        NEEDDNS=true
    fi

    # 3) 一次性写回 .outbounds / .endpoints / .route / .experimental
    local tmp; tmp=$(mktemp)
    if ! jq \
        --argjson obs "$OBS" --argjson eps "$EPS" \
        --argjson rr "$RR" --argjson rs "$RS" --argjson needdns "$NEEDDNS" '
        .outbounds = ( [ .outbounds[]? | select((.tag // "") | (startswith("out-") | not)) ] )
        | (if ([ .outbounds[]? | select(.tag == "direct") ] | length) == 0
           then .outbounds += [ {type:"direct", tag:"direct"} ] else . end)
        | .outbounds += $obs
        | .endpoints = ( [ (.endpoints // [])[]? | select((.tag // "") | (startswith("out-") | not)) ] + $eps )
        | (if (.endpoints | length) == 0 then del(.endpoints) else . end)
        | .route.rules = ( [ {action:"sniff"} ] + $rr + [ {ip_is_private:true, action:"reject"} ] )
        | .route.final = "direct"
        | .route.rule_set = $rs
        | (if ($rs | length) == 0 then del(.route.rule_set) else . end)
        | (if ($rs | length) > 0
           then .experimental.cache_file = {enabled:true, path:"/etc/sing-box/cache.db"}
           else . end)
        | (if $needdns
           then .dns = ((.dns // {}) | .servers = (((.servers // []) | map(select(.tag != "psm-local"))) + [{type:"local", tag:"psm-local"}]))
                | (if (.route.default_domain_resolver // null) == null
                   then .route.default_domain_resolver = "psm-local" else . end)
           else .dns = ((.dns // {}) | .servers = ((.servers // []) | map(select(.tag != "psm-local"))))
                | (if ((.dns | keys) == ["servers"] and (.dns.servers | length) == 0)
                   then del(.dns) else . end)
                | (if (.route.default_domain_resolver // "") == "psm-local"
                   then del(.route.default_domain_resolver) else . end)
           end)
    ' "$SB_CFG" > "$tmp"; then
        log_error "$(t sb.route.build_fail)"; rm -f "$tmp"; return 1
    fi
    _sb_cfg_backup   # 事务化：写回前备份，sb_test_restart 校验失败时回滚
    # _sb_write_cfg_checked 失败时 SB_CFG 未变，清理多余的 .prev，避免残留
    _sb_write_cfg_checked "$tmp" || { rm -f "${SB_CFG}.prev"; return 1; }
    sb_test_restart
}

# ── Outbound: add wizard ──────────────────────────────────────────────────────
sb_outb_add_wizard() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.outb.add_title)${NC}\n"
    echo "  $(t sb.outb.proto_title)"
    echo "    1. $(t sb.outb.proto_reality)"
    echo "    2. $(t sb.outb.proto_tls)"
    echo "    3. $(t sb.outb.proto_ss)"
    echo "    4. $(t sb.outb.proto_trojan)"
    echo "    5. $(t sb.outb.proto_socks)"
    echo "    6. $(t sb.outb.proto_anytls)"
    echo "    7. $(t sb.outb.proto_snell)"
    echo "    8. $(t sb.outb.proto_hy2)"
    echo "    9. $(t sb.outb.proto_tuic)"
    local ps; read -rp "$(echo -e "${CYAN}$(t sb.outb.ask_proto)${NC}")" ps
    ps="${ps:-1}"

    local remark addr port tag
    ask remark "$(t sb.outb.ask_remark)" "VPS-B"
    tag="out-$(echo "$remark" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-' | head -c12)"
    ask tag "$(t sb.outb.ask_tag)" "$tag"
    [[ "$tag" == out-* ]] || tag="out-${tag}"

    local entry
    case "$ps" in
    1)
        ask addr "$(t sb.outb.ask_addr)" ""
        ask port "$(t sb.outb.ask_port)" "443"
        local uuid sni pk sid flow fp
        ask uuid "UUID" "$("$SB_BIN" generate uuid 2>/dev/null || uuid_gen)"
        ask sni  "SNI" "www.cloudflare.com"
        ask pk   "Public Key" ""
        ask sid  "Short ID" ""
        ask fp   "Fingerprint" "chrome"
        ask flow "Flow" "xtls-rprx-vision"
        [[ -z "$addr" || -z "$pk" ]] && { log_error "$(t sb.outb.err_addr_pk)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "vless-reality" \
            --arg addr "$addr" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" \
            --arg pk "$pk" --arg sid "$sid" --arg fp "$fp" --arg flow "$flow" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,uuid:$uuid,
              sni:$sni,public_key:$pk,short_id:$sid,fingerprint:$fp,flow:$flow}') ;;
    2)
        ask addr "$(t sb.outb.ask_domain)" ""
        ask port "$(t sb.outb.ask_port)" "443"
        local uuid domain fp flow
        ask uuid "UUID" "$("$SB_BIN" generate uuid 2>/dev/null || uuid_gen)"
        ask domain "SNI" "$addr"
        ask fp "Fingerprint" "chrome"
        ask flow "Flow" "xtls-rprx-vision"
        [[ -z "$addr" ]] && { log_error "$(t sb.outb.err_domain)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "vless-tls" \
            --arg addr "$addr" --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" \
            --arg fp "$fp" --arg flow "$flow" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,uuid:$uuid,
              domain:$domain,fingerprint:$fp,flow:$flow}') ;;
    3)
        ask addr "$(t sb.outb.ask_addr)" ""
        ask port "$(t sb.outb.ask_port)" "8388"
        local method pass
        echo "  $(t sb.outb.ss_method)"
        local ms; read -rp "$(echo -e "${CYAN}$(t sb.outb.ask_select)${NC}")" ms
        case "${ms:-1}" in
            2) method="2022-blake3-aes-256-gcm" ;;
            3) method="2022-blake3-chacha20-poly1305" ;;
            4) method="aes-256-gcm" ;;
            5) method="chacha20-ietf-poly1305" ;;
            *) method="2022-blake3-aes-128-gcm" ;;
        esac
        ask pass "$(t sb.outb.ask_pass)" ""
        [[ -z "$addr" || -z "$pass" ]] && { log_error "$(t sb.outb.err_addr_pass)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "shadowsocks" \
            --arg addr "$addr" --argjson port "$port" --arg method "$method" --arg pass "$pass" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,method:$method,password:$pass}') ;;
    4)
        ask addr "$(t sb.outb.ask_domain)" ""
        ask port "$(t sb.outb.ask_port)" "443"
        local pass domain fp
        ask pass "$(t sb.outb.ask_pass)" ""
        ask domain "SNI" "$addr"
        ask fp "Fingerprint" "chrome"
        [[ -z "$addr" || -z "$pass" ]] && { log_error "$(t sb.outb.err_domain_pass)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "trojan" \
            --arg addr "$addr" --argjson port "$port" --arg pass "$pass" --arg domain "$domain" --arg fp "$fp" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,password:$pass,domain:$domain,fingerprint:$fp}') ;;
    5)
        ask addr "$(t sb.outb.ask_addr)" ""
        ask port "$(t sb.outb.ask_port)" "1080"
        local user pass
        ask user "$(t sb.outb.ask_user)" ""
        [[ -n "$user" ]] && ask pass "$(t sb.outb.ask_pass)" ""
        [[ -z "$addr" ]] && { log_error "$(t sb.outb.err_addr)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "socks5" \
            --arg addr "$addr" --argjson port "$port" --arg user "$user" --arg pass "${pass:-}" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,username:$user,password:$pass}') ;;
    6)
        ask addr "$(t sb.outb.ask_addr)" ""
        ask port "$(t sb.outb.ask_port)" "8443"
        local pass sni; ask pass "$(t sb.outb.ask_pass)" ""; ask sni "SNI" "$addr"
        local insec="false"; ask_yn "$(t sb.outb.ask_insecure)" N && insec="true"
        [[ -z "$addr" || -z "$pass" ]] && { log_error "$(t sb.outb.err_addr_pass)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "anytls" \
            --arg addr "$addr" --argjson port "$port" --arg pass "$pass" --arg sni "$sni" \
            --argjson insec "$insec" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,password:$pass,
              sni:$sni,insecure:$insec,fingerprint:"chrome"}') ;;
    7)
        ask addr "$(t sb.outb.ask_addr)" ""
        ask port "$(t sb.outb.ask_port)" "6160"
        local ver psk om oh
        ask ver "$(t sb.outb.ask_snell_ver)" "4"
        [[ "$ver" =~ ^[0-9]+$ ]] || ver=4
        ask psk "$(t sb.outb.ask_snell_psk)" ""
        [[ -z "$addr" || -z "$psk" ]] && { log_error "$(t sb.outb.err_addr_pass)"; return 1; }
        om=""; oh=""
        if [[ "$ver" == "4" ]] && ask_yn "$(t sb.outb.ask_snell_obfs)" N; then
            om="http"; ask oh "$(t sb.outb.ask_snell_obfs_host)" "bing.com"
        fi
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "snell" \
            --arg addr "$addr" --argjson port "$port" --argjson ver "$ver" --arg psk "$psk" \
            --arg om "$om" --arg oh "$oh" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,version:$ver,psk:$psk,obfs_mode:$om,obfs_host:$oh}') ;;
    8)
        ask addr "$(t sb.outb.ask_addr)" ""
        ask port "$(t sb.outb.ask_port)" "443"
        local pass sni obfs; ask pass "$(t sb.outb.ask_pass)" ""; ask sni "SNI" "$addr"
        local insec="false"; ask_yn "$(t sb.outb.ask_insecure)" N && insec="true"
        ask obfs "$(t sb.outb.ask_hy2_obfs)" ""
        [[ -z "$addr" || -z "$pass" ]] && { log_error "$(t sb.outb.err_addr_pass)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "hysteria2" \
            --arg addr "$addr" --argjson port "$port" --arg pass "$pass" --arg sni "$sni" \
            --argjson insec "$insec" --arg obfs "$obfs" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,password:$pass,
              sni:$sni,insecure:$insec,obfs_pass:$obfs}') ;;
    9)
        ask addr "$(t sb.outb.ask_addr)" ""
        ask port "$(t sb.outb.ask_port)" "443"
        local uuid pass sni; ask uuid "UUID" ""; ask pass "$(t sb.outb.ask_pass)" ""; ask sni "SNI" "$addr"
        local insec="false"; ask_yn "$(t sb.outb.ask_insecure)" N && insec="true"
        [[ -z "$addr" || -z "$uuid" ]] && { log_error "$(t sb.outb.err_addr_uuid)"; return 1; }
        entry=$(jq -n --arg tag "$tag" --arg remark "$remark" --arg proto "tuic" \
            --arg addr "$addr" --argjson port "$port" --arg uuid "$uuid" --arg pass "$pass" --arg sni "$sni" \
            --argjson insec "$insec" \
            '{tag:$tag,remark:$remark,protocol:$proto,address:$addr,port:$port,uuid:$uuid,password:$pass,
              sni:$sni,insecure:$insec,congestion:"bbr"}') ;;
    *) log_warn "$(t sb.invalid_option)"; return ;;
    esac

    _sb_outb_upsert "$entry"
    _sb_route_apply
    log_ok "$(t sb.outb.added "$tag" "$remark")"
}

sb_outb_delete() {
    local count; count=$(_sb_outb_count)
    (( count == 0 )) && { log_warn "$(t sb.outb.none)"; return; }
    echo -e "\n${BOLD}$(t sb.outb.del_title)${NC}"
    local tags_arr=() i=0 tag proto addr remark
    while IFS=$'\t' read -r tag proto addr remark; do
        i=$((i+1)); tags_arr+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s %-16s %-24s %s\n" "$i" "$tag" "$proto" "$addr" "$remark"
    done < <(_sb_outb_list)
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.route.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then log_warn "$(t sb.invalid_option)"; return; fi
    local tag2="${tags_arr[$((sel-1))]}"
    ask_yn "$(t sb.outb.ask_confirm_del "$tag2")" N || return
    _sb_outb_delete "$tag2"
    _sb_route_apply
    log_ok "$(t sb.outb.deleted "$tag2")"
    log_warn "$(t sb.outb.check_rules_hint)"
}

sb_outb_show() {
    local count; count=$(_sb_outb_count)
    echo -e "\n${BOLD}${BLUE}══ $(t sb.outb.list_title) ════════════════════════${NC}"
    if (( count == 0 )); then
        echo -e "  ${YELLOW}$(t sb.outb.none)${NC}"
    else
        while IFS=$'\t' read -r tag proto addr remark; do
            printf "  ${CYAN}%-20s${NC} %-16s %-26s %s\n" "$tag" "$proto" "$addr" "$remark"
        done < <(_sb_outb_list)
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Rule: add wizard ──────────────────────────────────────────────────────────
sb_route_add_wizard() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.route.add_title)${NC}"

    # 目标：某个出站 或 拦截
    local target=""
    echo -e "\n  $(t sb.route.target_title)"
    local ob_tags=() ob_i=0 tag proto addr remark
    while IFS=$'\t' read -r tag proto addr remark; do
        ob_i=$((ob_i+1)); ob_tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s %-16s %s  %s\n" "$ob_i" "$tag" "$proto" "$addr" "$remark"
    done < <(_sb_outb_list)
    printf "  ${CYAN}%2d.${NC} %s\n" "$((ob_i+1))" "$(t sb.route.target_reject)"
    local tsel; read -rp "$(echo -e "${CYAN}$(t sb.route.ask_target)${NC}")" tsel
    if [[ "$tsel" == "$((ob_i+1))" ]]; then
        target="reject"
    elif [[ "$tsel" =~ ^[0-9]+$ ]] && (( tsel >= 1 && tsel <= ob_i )); then
        target="${ob_tags[$((tsel-1))]}"
    else
        log_warn "$(t sb.invalid_option)"; return
    fi

    echo -e "\n  $(t sb.route.type_title)"
    echo "    1. $(t sb.route.type_geosite)"
    echo "    2. $(t sb.route.type_geoip)"
    echo "    3. $(t sb.route.type_domain)"
    echo "    4. $(t sb.route.type_ip)"
    echo "    5. $(t sb.route.type_inbound)"
    local rt; read -rp "$(echo -e "${CYAN}$(t sb.route.ask_type)${NC}")" rt
    rt="${rt:-1}"

    local rule_type value remark2
    case "$rt" in
    1) rule_type="geosite"; echo "  $(t sb.route.geosite_hint)"; ask value "$(t sb.route.ask_geosite)" "netflix" ;;
    2) rule_type="geoip";   echo "  $(t sb.route.geoip_hint)";   ask value "$(t sb.route.ask_geoip)" "us" ;;
    3) rule_type="domain";  ask value "$(t sb.route.ask_domain)" ""; [[ -z "$value" ]] && { log_error "$(t sb.route.err_empty)"; return 1; } ;;
    4) rule_type="ip";      ask value "$(t sb.route.ask_ip)" ""; [[ -z "$value" ]] && { log_error "$(t sb.route.err_empty)"; return 1; } ;;
    5) rule_type="inbound"; echo "  $(t sb.route.inbound_hint)"; ask value "$(t sb.route.ask_inbound)" ""; [[ -z "$value" ]] && { log_error "$(t sb.route.err_empty)"; return 1; } ;;
    *) log_warn "$(t sb.invalid_option)"; return ;;
    esac
    remark2="${value} → ${target}"

    local id; id=$(_sb_route_next_id)
    local entry
    entry=$(jq -n --arg id "$id" --arg remark "$remark2" --arg rtype "$rule_type" \
        --arg val "$value" --arg tgt "$target" \
        '{id:$id,remark:$remark,rule_type:$rtype,value:$val,target:$tgt}')
    _sb_route_save "$(_sb_route_load | jq ". += [$entry]")"
    _sb_route_apply
    log_ok "$(t sb.route.added "$remark2")"
}

sb_route_delete() {
    local count; count=$(_sb_route_count)
    (( count == 0 )) && { log_warn "$(t sb.route.none)"; return; }
    echo -e "\n${BOLD}$(t sb.route.del_title)${NC}"
    local rules; rules=$(_sb_route_load)
    local ids_arr=() i=0
    while IFS= read -r entry; do
        i=$((i+1))
        ids_arr+=("$(echo "$entry" | jq -r '.id')")
        printf "  ${CYAN}%2d.${NC} [%-10s] %-30s → %s\n" \
            "$i" "$(echo "$entry" | jq -r '.rule_type')" "$(echo "$entry" | jq -r '.value')" "$(echo "$entry" | jq -r '.target')"
    done < <(echo "$rules" | jq -c '.[]')
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.route.ask_select)${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then log_warn "$(t sb.invalid_option)"; return; fi
    local del_id="${ids_arr[$((sel-1))]}"
    _sb_route_save "$(echo "$rules" | jq --arg id "$del_id" 'del(.[] | select(.id == $id))')"
    _sb_route_apply
    log_ok "$(t sb.route.deleted "$del_id")"
}

sb_route_show() {
    local count; count=$(_sb_route_count)
    echo -e "\n${BOLD}${BLUE}══ $(t sb.route.list_title) ════════════════════════${NC}"
    if (( count == 0 )); then
        echo -e "  ${YELLOW}$(t sb.route.none)${NC}"
        echo -e "  $(t sb.route.empty_hint)"
    else
        local rules; rules=$(_sb_route_load) i=0
        while IFS= read -r entry; do
            i=$((i+1))
            printf "  ${CYAN}%2d.${NC} [${YELLOW}%-10s${NC}] %-34s ${GREEN}→${NC} %-18s %s\n" \
                "$i" "$(echo "$entry" | jq -r '.rule_type')" "$(echo "$entry" | jq -r '.value')" \
                "$(echo "$entry" | jq -r '.target')" "$(echo "$entry" | jq -r '.remark // ""')"
        done < <(echo "$rules" | jq -c '.[]')
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Presets ───────────────────────────────────────────────────────────────────
sb_route_toggle_preset() {
    local kind="$1"   # preset-ads | preset-quic
    local rules; rules=$(_sb_route_load)
    if echo "$rules" | jq -e --arg k "$kind" 'any(.[]; .rule_type == $k)' >/dev/null 2>&1; then
        _sb_route_save "$(echo "$rules" | jq --arg k "$kind" 'del(.[] | select(.rule_type == $k))')"
        _sb_route_apply
        log_ok "$(t sb.route.preset_off "$kind")"
    else
        local id; id=$(_sb_route_next_id)
        local entry; entry=$(jq -n --arg id "$id" --arg k "$kind" \
            '{id:$id, remark:$k, rule_type:$k, value:"", target:"reject"}')
        _sb_route_save "$(echo "$rules" | jq ". += [$entry]")"
        _sb_route_apply
        log_ok "$(t sb.route.preset_on "$kind")"
    fi
}

# ── WARP unlock outbound ──────────────────────────────────────────────────────
sb_warp_setup() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.warp.title)${NC}"
    # 复用 xray 模块注册的 WARP 身份；未注册则现在注册
    source "$LIB_DIR/xray/warp.sh" 2>/dev/null || true
    if [[ ! -f "$SB_WARP_ACCOUNT" ]] || ! jq -e '.secret_key // empty' "$SB_WARP_ACCOUNT" &>/dev/null; then
        log_info "$(t sb.warp.not_registered)"
        ask_yn "$(t sb.warp.ask_register)" Y || return
        if declare -f _warp_register &>/dev/null; then
            _warp_register || { log_error "$(t sb.warp.register_fail)"; return 1; }
        else
            log_error "$(t sb.warp.register_fail)"; return 1
        fi
    else
        log_info "$(t sb.warp.reuse)"
    fi

    echo -e "  $(t sb.warp.family_title)"
    echo "    1. $(t sb.warp.family_4)"
    echo "    2. $(t sb.warp.family_6)"
    echo "    3. $(t sb.warp.family_46)"
    local fs; read -rp "$(echo -e "${CYAN}$(t sb.warp.ask_family)${NC}")" fs
    local family; case "${fs:-1}" in 2) family="6" ;; 3) family="46" ;; *) family="4" ;; esac

    local entry; entry=$(jq -n --arg tag "out-warp" --arg family "$family" \
        '{tag:$tag, remark:"WARP", protocol:"warp", family:$family}')
    _sb_outb_upsert "$entry"
    _sb_route_apply
    log_ok "$(t sb.warp.added)"

    # 先验证隧道真的能出网（与 xray 流程一致）：验证不过就不必加解锁规则
    echo ""
    if ! sb_warp_check_exit_ip; then
        log_warn "$(t warp.probe.setup_warn)"
        return 1
    fi

    # 便捷：一键为常见流媒体/AI 添加走 WARP 的规则
    if ask_yn "$(t sb.warp.ask_quick_rules)" Y; then
        local id; id=$(_sb_route_next_id)
        local e; e=$(jq -n --arg id "$id" \
            '{id:$id, remark:"openai,netflix,disney → WARP", rule_type:"geosite",
              value:"openai,netflix,disney", target:"out-warp"}')
        _sb_route_save "$(_sb_route_load | jq ". += [$e]")"
        _sb_route_apply
        log_ok "$(t sb.warp.quick_added)"
    fi
}

# ── WARP 出口探测 ─────────────────────────────────────────────────────────────
# 与 xray 的 warp_check_exit_ip 同思路：拉起一个临时 sing-box（socks 入站 →
# WARP endpoint，route.final 指向它），经本地 socks 按地址族逐个探测真实出口
# IP 与 warp 状态，探完即销毁，不碰生产配置。
sb_warp_check_exit_ip() {
    command -v curl &>/dev/null || { log_error "$(t warp.probe.no_curl)"; return 1; }
    local e; e=$(_sb_outb_load | jq -c '[.[] | select(.protocol == "warp")][0] // empty')
    [[ -n "$e" ]] || { log_warn "$(t sb.warp.not_configured)"; return 1; }
    local ep; ep=$(_sb_outb_build_warp "$e")
    [[ -n "$ep" ]] || { log_error "$(t sb.warp.register_fail)"; return 1; }

    local families
    families=$(warp_probe_families "$(echo "$e" | jq -r '.family // "4"')" \
                                   "$(jq -r '.local_v6 // ""' "$SB_WARP_ACCOUNT" 2>/dev/null)")

    local port=47200
    while ss -ltnH 2>/dev/null | grep -q ":${port} "; do port=$((port+1)); done

    local pid="" up=0 rc=1 logtail=""
    local tmpdir tmpcfg tmplog
    tmpdir=$(mktemp -d)
    tmpcfg="$tmpdir/probe.json"; tmplog="$tmpdir/singbox.log"
    jq -n --argjson ep "$ep" --argjson port "$port" '{
        log: {level:"warn"},
        inbounds:  [{type:"socks", tag:"probe", listen:"127.0.0.1", listen_port:$port}],
        endpoints: [$ep],
        route: {final: $ep.tag}
    }' > "$tmpcfg"

    log_step "$(t warp.probe.probing)"
    "$SB_BIN" run -c "$tmpcfg" >"$tmplog" 2>&1 &
    pid=$!
    for _ in $(seq 1 12); do
        kill -0 "$pid" 2>/dev/null || break
        if ss -ltnH 2>/dev/null | grep -q "127.0.0.1:${port} "; then up=1; break; fi
        sleep 0.5
    done
    if (( up )); then
        sleep 2
        # $families 故意不加引号（"4 6" 需要分词成两个参数）
        if warp_probe_report "$port" $families; then rc=0; fi
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    logtail=$(tail -n 8 "$tmplog" 2>/dev/null) || true
    rm -rf "$tmpdir"

    if (( ! up )); then
        log_error "$(t sb.warp.temp_start_fail "$port")"
        echo -e "${YELLOW}$(t sb.warp.core_output)${NC}"
        sed 's/^/    /' <<<"$logtail"
        return 1
    fi
    if (( rc )); then
        echo -e "${YELLOW}$(t warp.probe.common_reasons)${NC}"
        echo -e "${YELLOW}$(t sb.warp.core_output)${NC}"
        sed 's/^/    /' <<<"$logtail"
        return 1
    fi
    return 0
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_route_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.route.menu_title)" \
            "$(t sb.route.menu.show)" \
            "$(t sb.route.menu.add)" \
            "$(t sb.route.menu.del)" \
            "$(t sb.route.menu.outb_show)" \
            "$(t sb.route.menu.outb_add)" \
            "$(t sb.route.menu.outb_del)" \
            "$(t sb.route.menu.warp)" \
            "$(t sb.route.menu.warp_check)" \
            "$(t sb.route.menu.ads)" \
            "$(t sb.route.menu.quic)" \
            "$(t sb.route.menu.vpngate)"

        case "$MENU_CHOICE" in
            1) sb_route_show;         press_enter ;;
            2) sb_route_add_wizard;   press_enter ;;
            3) sb_route_delete;       press_enter ;;
            4) sb_outb_show;          press_enter ;;
            5) sb_outb_add_wizard;    press_enter ;;
            6) sb_outb_delete;        press_enter ;;
            7) sb_warp_setup;         press_enter ;;
            8) sb_warp_check_exit_ip; press_enter ;;
            9) sb_route_toggle_preset "preset-ads";  press_enter ;;
            10) sb_route_toggle_preset "preset-quic"; press_enter ;;
            11)
                source "$LIB_DIR/vpngate.sh"
                vpngate_menu singbox
                ;;
            0) return ;;
        esac
    done
}
