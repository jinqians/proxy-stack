#!/usr/bin/env bash
# subscribe.sh — 客户端配置导出与在线订阅
#
# 两件事：
#   1) 本地导出 —— 把当前所有节点导成
#        · 通用 URI 订阅（base64，v2rayN / Shadowrocket / Clash 系都认）
#        · sing-box 客户端 config.json（含 outbounds、selector 选择组、基础分流）
#        · mihomo 客户端 config.yaml（含 proxies、proxy-groups、rules）
#   2) 在线订阅 —— 把上面的产物放进伪装站的 webroot，用一个随机 token 做路径，
#      经既有的 443 SNI 分流以 HTTPS 提供。
#
# ⚠ 订阅链接等于「所有节点凭据的明文托管」：谁拿到链接谁就能连上你全部节点。
# 因此：token 是 48 位随机串、只走 HTTPS、带有效期、可随时重置（旧链接立即失效）。
# 生成的文件权限 600，目录不开 autoindex —— 没有 token 就枚举不出来。
#
# 节点来源直接复用 node_cli 的 _node_cli_collect / _node_cli_export_uri，
# 不重写一遍各协议的 URI 拼装：那样必然和各模块的实现漂移。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SUB_DIR="$CFG_DIR/subscribe"
SUB_STATE="$SUB_DIR/state.json"
SUB_WEBROOT="/var/www/psm-camouflage"
SUB_URL_PREFIX="psm-sub"
SUB_DEFAULT_DAYS=30

_sub_state_load() { [[ -f "$SUB_STATE" ]] && jq '.' "$SUB_STATE" 2>/dev/null || echo '{}'; }
_sub_state_save() { mkdir -p "$SUB_DIR"; printf '%s' "$1" | jq '.' > "$SUB_STATE"; chmod 600 "$SUB_STATE"; }
_sub_state_get()  { _sub_state_load | jq -r "$1 // empty" 2>/dev/null || true; }

# ── 收集节点 URI ──────────────────────────────────────────────────────────────
# 返回每行一条 URI。跳过没有标准 URI 的协议（Snell）和仅本机的 SOCKS5 —— 后者
# 的地址是 127.0.0.1，放进订阅只会让客户端连一个连不上的地址。
# psm user: a node as one user sees it — their credentials — or status 1 when
# the node is not theirs or has no per-user login (Shadowsocks 2022, Snell,
# WireGuard, SOCKS without a password). Active only while _SUB_USER is set.
_sub_as_user() {   # <protocol> <node JSON>
    case "$1" in ss2022|snell|wireguard) return 1 ;; esac
    jq -ce --argjson u "$_SUB_USER" '
        .tag as $t | select((($u.nodes | index("*")) != null) or (($u.nodes | index($t)) != null))
        | if has("uuid") then .uuid = $u.uuid else . end
        | if has("password") then .password = $u.password else . end
        | if has("username") then (if (.username // "") == "" then empty else .username = ("psmu-" + $u.name) end)
          else . end' <<<"$2"
}

_sub_collect_uris() {
    local server="$1"
    source "$LIB_DIR/node_cli.sh"
    local all; all=$(_node_cli_collect "" "") || return 1
    local n core proto node
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        core=$(printf '%s' "$n"  | jq -r '.core')
        proto=$(printf '%s' "$n" | jq -r '.protocol')
        node=$(printf '%s' "$n"  | jq -c '.node')
        if [[ -n "${_SUB_USER:-}" ]]; then node=$(_sub_as_user "$proto" "$node") || continue; fi
        [[ "$proto" == "snell" || "$proto" == "wireguard" ]] && continue   # no URI: Snell, wg-quick files
        if [[ "$proto" == "socks" ]] \
           && [[ "$(printf '%s' "$node" | jq -r '.listen_addr // ""')" == "127.0.0.1" ]]; then
            continue
        fi
        _node_cli_export_uri "$core" "$proto" "$node" "$server" 2>/dev/null || true
    done < <(printf '%s' "$all" | jq -c '.[]')

    # 独立协议（Hysteria2 / ss-rust / Snell）不在三内核的节点存储里，单独收集。
    # 「导出全部节点」漏掉它们的话，用户拿到的订阅是残缺的，而且不会有任何提示。
    [[ -n "${_SUB_USER:-}" ]] || _sub_standalone_uris "$server"
}

# ── 独立协议（不走三内核，节点信息在各自的配置文件里）────────────────────────
# 这三个是「一键导出全部节点」里最容易漏的：它们不在 node_cli 的 pairs 表里，
# 因为它们是独立二进制 + 独立配置，没有 PSM 的节点存储。
# realm 刻意不导出：它是中转转发规则，不是客户端能连的节点。
_sub_standalone_uris() {
    local server="$1"

    # 独立 Hysteria2：端口和密码优先取 PSM 状态，取不到再从配置文件里挖
    local hy2_cfg="/etc/hysteria/config.yaml"
    if [[ -f "$hy2_cfg" ]]; then
        local d pw port sni insecure=0
        d=$(state_get "hy2_domain"); pw=$(state_get "hy2_password"); port=$(state_get "hy2_port")
        [[ -z "$port" ]] && port=$(awk -F: '/^listen:/ {gsub(/[^0-9]/,"",$NF); print $NF; exit}' "$hy2_cfg" 2>/dev/null)
        [[ -z "$port" ]] && port=443
        # PSM 写出的形如 `  password: "xxx"`。用 awk 而不是 sed：BSD sed 不认 \?，
        # 在 macOS 上会把整行原样吐回来（本地测试时就是这么发现的）。
        [[ -z "$pw" ]] && pw=$(awk -F'password:' '/password:/ {
                v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/^"|"$/,"",v); print v; exit }' \
            "$hy2_cfg" 2>/dev/null)
        [[ -z "$d" ]] && insecure=1
        sni="${d:-$server}"
        # the certificate the server presents (tls.cert), pinned when self-signed
        local hy2_crt; hy2_crt=$(awk '/^[ \t]+cert:/ {print $2; exit}' "$hy2_cfg" 2>/dev/null)
        [[ -n "$pw" ]] && printf 'hysteria2://%s@%s:%s?insecure=%s&sni=%s%s#%s\n' \
            "$(url_encode "$pw")" "$server" "$port" "$insecure" "$sni" \
            "$(psm_pin_q "$(jq -cn --argjson i "$insecure" --arg c "$hy2_crt" '{insecure: $i, cert_path: $c}')" pinSHA256)" \
            "$(psm_link_label Hysteria2)"
    fi

    # 独立 ss-rust
    local ss_cfg="/etc/ss-rust/config.json"
    if [[ -f "$ss_cfg" ]]; then
        local port method pw
        port=$(jq -r '.server_port // empty' "$ss_cfg" 2>/dev/null)
        method=$(jq -r '.method // empty'    "$ss_cfg" 2>/dev/null)
        pw=$(jq -r '.password // empty'      "$ss_cfg" 2>/dev/null)
        if [[ -n "$port" && -n "$method" && -n "$pw" ]]; then
            printf 'ss://%s@%s:%s#%s\n' \
                "$(printf '%s:%s' "$method" "$pw" | openssl base64 -A | tr '+/' '-_' | tr -d '=')" \
                "$server" "$port" "$(psm_link_label ss-rust)"
        fi
    fi

    # 独立 Snell：没有标准 URI，用 Surge 段落形式给出（Surge 是它唯一的主流客户端）
    local snell_cfg="/etc/snell/users/snell-main.conf"
    if [[ -f "$snell_cfg" ]]; then
        local port psk ver
        port=$(grep -E '^listen' "$snell_cfg" 2>/dev/null | sed 's/.*://' | tr -d ' ')
        psk=$(grep -E '^psk'     "$snell_cfg" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d '[:space:]')
        ver=$(grep -E '^version' "$snell_cfg" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d '[:space:]')
        [[ -n "$port" && -n "$psk" ]] && \
            printf '# Surge: %s = snell, %s, %s, psk=%s, version=%s\n' \
                "$(psm_node_label Snell)" "$server" "$port" "$psk" "${ver:-4}"
    fi
}

# ── 通用 URI 订阅（base64）────────────────────────────────────────────────────
# 事实标准是「URI 列表整体 base64」，不是逐行 base64。
_sub_build_uri_sub() {
    local server="$1"
    _sub_collect_uris "$server" | openssl base64 -A
}

# ── sing-box 客户端配置 ───────────────────────────────────────────────────────
# 只写客户端必需的部分：mixed 入站 + 各节点 outbound + selector + 直连/拦截。
# 刻意不写 tun / dns 的复杂配置 —— 那些因人而异，写死反而碍事。
_sub_build_singbox_client() {
    local server="$1"
    source "$LIB_DIR/node_cli.sh"
    local all; all=$(_node_cli_collect "" "") || return 1

    local obs="[]" tags="[]" n core proto node tag ob
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        core=$(printf '%s' "$n"  | jq -r '.core')
        proto=$(printf '%s' "$n" | jq -r '.protocol')
        tag=$(printf '%s' "$n"   | jq -r '.tag')
        node=$(printf '%s' "$n"  | jq -c '.node')
        if [[ -n "${_SUB_USER:-}" ]]; then node=$(_sub_as_user "$proto" "$node") || continue; fi
        ob=$(_sub_sb_outbound "$core" "$proto" "$node" "$server" "$tag") || continue
        [[ -n "$ob" ]] || continue
        # ECH: the one place a client can get the config (share links cannot carry it)
        local ech; ech=$(printf '%s' "$node" | jq -r '.ech_config // ""')
        [[ -n "$ech" ]] && ob=$(printf '%s' "$ob" | jq -c --arg pem "$(psm_ech_config_pem "$ech")" \
            'if has("tls") then .tls.ech = { enabled: true, config: ($pem | split("\n") | map(select(length > 0))) } else . end')
        obs=$(printf '%s' "$obs"   | jq -c --argjson o "$ob" '. += [$o]')
        tags=$(printf '%s' "$tags" | jq -c --arg t "$(psm_node_label "$tag" "$node")" '. += [$t]')
    done < <(printf '%s' "$all" | jq -c '.[]')

    jq -n --argjson obs "$obs" --argjson tags "$tags" '{
      log: { level: "info" },
      inbounds: [ { type: "mixed", tag: "in", listen: "127.0.0.1", listen_port: 7890 } ],
      outbounds: ( [ { type: "selector", tag: "PSM", outbounds: ($tags + ["direct"]), default: ($tags[0] // "direct") } ]
                   + $obs
                   + [ { type: "direct", tag: "direct" } ] ),
      route: { rules: [ { action: "sniff" }, { ip_is_private: true, outbound: "direct" } ],
               final: "PSM" }
    }'
}

# An Xray REALITY server from v26.9.8 on takes only a hello with an
# X25519MLKEM768 key share (XTLS/REALITY 8cdf7bf, on purpose), and sing-box
# takes that share out of its REALITY hello (SagerNet/sing-box#4520): no
# sing-box client reaches such a node. Its own REALITY nodes, and mihomo's,
# take sing-box. An Xray that does not answer counts as a current one.
_sub_xray_refuses_sing_box() {
    local v; v=$("$XRAY_BIN" version 2>/dev/null | awk 'NR == 1 {print $2}')
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    [[ "$(printf '26.9.8\n%s\n' "$v" | sort -V | head -1)" == 26.9.8 ]]
}

# 单个节点 → sing-box 客户端 outbound。不支持的协议返回空串由调用方跳过。
# A self-signed node pins its certificate's public key
# (certificate_public_key_sha256, sing-box 1.13+) instead of skipping
# verification: see psm_node_pins in common.sh.
_sub_sb_outbound() {
    local ob pins
    # sing-box has no VLESS Encryption: such a node (REALITY, Vision, XHTTP,
    # mihomo VLESS) gets no outbound rather than one that cannot connect
    [[ "$(printf '%s' "$3" | jq -r '(.vless_encryption // "") | if . == "" then "none" else . end')" == none ]] || return 0
    # nor an Xray REALITY node, once Xray refuses its hello (_sub_xray_refuses_sing_box)
    [[ "$1/$2" == xray/reality ]] && _sub_xray_refuses_sing_box && return 0
    ob=$(_sub_sb_outbound_plain "$@") || return 1
    [[ -n "$ob" ]] || return 0
    pins=$(psm_node_pins "$3")
    printf '%s' "$ob" | jq -c --argjson p "$pins" '
        if ($p.spki // "") != "" and (.tls.insecure // false) then
            .tls |= (del(.insecure) + {certificate_public_key_sha256: [$p.spki]})
        else . end'
}

_sub_sb_outbound_plain() {
    local core="$1" proto="$2" n="$3" server="$4" tag="$5"
    local port; port=$(printf '%s' "$n" | jq -r '.public_port // .port')
    # sing-box has no XHTTP transport (mihomo's VLESS has it): such a node has
    # no sing-box outbound. Writing one anyway made sing-box refuse the whole
    # subscription it was in.
    [[ "$proto" == vless && "$(printf '%s' "$n" | jq -r '.transport // "tcp"')" == xhttp ]] && return 0
    case "$proto" in
        reality)
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" \
                  --arg u "$(printf '%s' "$n" | jq -r '.uuid')" \
                  --arg f "$(printf '%s' "$n" | jq -r '.flow // ""')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.server_name')" \
                  --arg pbk "$(printf '%s' "$n" | jq -r '.public_key')" \
                  --arg sid "$(printf '%s' "$n" | jq -r '(.short_ids[0] // .short_id) // ""')" '
                { type:"vless", tag:$t, server:$s, server_port:$p, uuid:$u,
                  tls:{ enabled:true, server_name:$sn, utls:{enabled:true, fingerprint:"chrome"},
                        reality:{ enabled:true, public_key:$pbk, short_id:$sid } } }
                + (if $f == "" then {} else {flow:$f} end)' ;;
        vless)
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" \
                  --arg u "$(printf '%s' "$n" | jq -r '.uuid')" \
                  --arg f "$(printf '%s' "$n" | jq -r '.flow // ""')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni // .domain')" \
                  --arg tr "$(printf '%s' "$n" | jq -r '.transport // "tcp"')" \
                  --arg path "$(printf '%s' "$n" | jq -r '.path // "/"')" \
                  --argjson ins "$(printf '%s' "$n" | jq '(.insecure // 0) | tostring | test("^(1|true)$")')" '
                { type:"vless", tag:$t, server:$s, server_port:$p, uuid:$u,
                  tls:{ enabled:true, server_name:$sn, insecure:$ins } }
                + (if $f == "" then {} else {flow:$f} end)
                + (if   $tr == "tcp"  then {}
                   elif $tr == "grpc" then {transport:{type:"grpc", service_name:($path|ltrimstr("/"))}}
                   elif $tr == "quic" then {transport:{type:"quic"}}
                   else {transport:{type:$tr, path:$path}} end)' ;;
        trojan)
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni // .domain')" \
                  --argjson ins "$(printf '%s' "$n" | jq '(.insecure // 0) | tostring | test("^(1|true)$")')" '
                { type:"trojan", tag:$t, server:$s, server_port:$p, password:$pw,
                  tls:{ enabled:true, server_name:$sn, insecure:$ins } }' ;;
        vmess)
            # A cipher by name, not "auto": sing-box's auto under TLS is one
            # Xray v26.11.9 answers with nothing (as it does "none"); with
            # aes-128-gcm or chacha20-poly1305 the same node carries traffic.
            # ChaCha20 is the one that is fast without AES hardware too.
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" \
                  --arg u "$(printf '%s' "$n" | jq -r '.uuid')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni // .domain')" \
                  --arg path "$(printf '%s' "$n" | jq -r '.path // "/"')" \
                  --argjson ins "$(printf '%s' "$n" | jq '(.insecure // 0) | tostring | test("^(1|true)$")')" '
                { type:"vmess", tag:$t, server:$s, server_port:$p, uuid:$u, security:"chacha20-poly1305",
                  tls:{ enabled:true, server_name:$sn, insecure:$ins },
                  transport:{ type:"ws", path:$path } }' ;;
        ss2022)
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" \
                  --arg m "$(printf '%s' "$n" | jq -r '.method')" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" '
                { type:"shadowsocks", tag:$t, server:$s, server_port:$p, method:$m, password:$pw }' ;;
        hysteria2)
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni')" \
                  --argjson ins "$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')" \
                  --arg hop "$(printf '%s' "$n" | jq -r '.hop_ports // ""')" \
                  --arg obfs "$(printf '%s' "$n" | jq -r '.obfs_pass // ""')" \
                  --arg otype "$(printf '%s' "$n" | jq -r '.obfs_type // "salamander"')" '
                { type:"hysteria2", tag:$t, server:$s, server_port:$p, password:$pw,
                  tls:{ enabled:true, server_name:$sn, insecure:($ins == 1) } }
                + (if $hop != "" then { server_ports: [($hop | sub("-"; ":"))], hop_interval: "30s" } else {} end)
                # the obfuscation the server expects (without it such a node never connected)
                + (if $obfs != "" then { obfs: { type: $otype, password: $obfs } } else {} end)' ;;
        anytls)
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni')" \
                  --argjson ins "$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')" '
                { type:"anytls", tag:$t, server:$s, server_port:$p, password:$pw,
                  tls:{ enabled:true, server_name:$sn, insecure:($ins == 1) } }' ;;
        tuic)
            jq -n --arg t "$(psm_node_label "$tag" "$n")" --arg s "$server" --argjson p "$port" --argjson n "$n" '
                { type:"tuic", tag:$t, server:$s, server_port:$p, uuid:$n.uuid, password:$n.password,
                  congestion_control:($n.congestion_control // "bbr"),
                  tls:{ enabled:true, server_name:$n.sni, alpn:["h3"],
                        insecure:(($n.insecure // 0) | tostring | test("^(1|true)$")) } }' ;;
        *) printf '' ;;   # vision/xhttp/snell/socks 交给 URI 订阅，不进原生配置
    esac
}

# ── A node as one mihomo proxy (the PSM panel's Clash subscription) ──────────
# The TLS protocols, whose certificate may be self-signed: mihomo's share-link
# import reads no "skip verification" flag for VLESS, VMess or TUIC, so such a
# node imported from its link never connects. Written out with
# skip-cert-verify (and everything else) it does. Other protocols print
# nothing: their share links import as they are.
# A self-signed node also carries its certificate's SHA-256 as fingerprint:
# mihomo then checks that one certificate even with skip-cert-verify on (its
# VerifyConnection runs either way), while clients that read the Clash format
# without fingerprint (Stash) keep skipping verification as before.
_sub_mh_proxy() {
    local core="$1" proto="$2" n="$3" server="$4" tag="$5"
    local port; port=$(printf '%s' "$n" | jq -r '.public_port // .port')
    n=$(psm_node_with_pins "$n")
    case "$proto" in vless|trojan|vmess|hysteria2|anytls|tuic|ss2022|reality|vision|socks|xhttp) ;; *) return 0 ;; esac
    # a loopback SOCKS5 node has no address a client could use
    [[ "$proto" == socks && "$(printf '%s' "$n" | jq -r '.listen_addr // ""')" == "127.0.0.1" ]] && return 0
    # Xray's mKCP: mihomo's VLESS has no mKCP transport
    [[ "$proto" == xhttp && "$(printf '%s' "$n" | jq -r '.mode // ""')" == mkcp ]] && return 0
    # mihomo's VLESS has no QUIC transport
    [[ "$proto" == vless && "$(printf '%s' "$n" | jq -r '.transport // "tcp"')" == quic ]] && return 0
    jq -cn --arg name "$(psm_node_label "$tag" "$n")" --arg core "$core" --arg proto "$proto" --arg s "$server" \
        --argjson p "$port" --argjson n "$n" '
      ((($n.insecure // 0) | tostring | test("^(1|true)$"))) as $ins
      | ($n.sni // $n.domain // "") as $sni
      | {name: $name, server: $s, port: $p}
      + (if $proto == "vless" then
           (($n.transport // "tcp") as $tr | ($n.path // "/") as $path
            | {type: "vless", uuid: $n.uuid, udp: true, tls: true, servername: $sni,
               "skip-cert-verify": $ins, "client-fingerprint": "chrome"}
            + (if ($n.flow // "") != "" and $tr == "tcp" then {flow: $n.flow} else {} end)
            + (if ($n.vless_encryption // "") != "" then {encryption: $n.vless_encryption} else {} end)
            + (if   $tr == "ws"          then {network: "ws", "ws-opts": {path: $path, headers: {Host: $sni}}}
               elif $tr == "httpupgrade" then {network: "ws", "ws-opts": {path: $path, headers: {Host: $sni}, "v2ray-http-upgrade": true}}
               elif $tr == "grpc"        then {network: "grpc", "grpc-opts": {"grpc-service-name": ($path | ltrimstr("/"))}}
               elif $tr == "http"        then {network: "h2", "h2-opts": {host: [$sni], path: $path}}
               elif $tr == "xhttp"       then {network: "xhttp", "xhttp-opts": {path: $path, host: $sni}}
               else {network: "tcp"} end))
         elif $proto == "ss2022" then
           ({type: "ss", cipher: $n.method, password: $n.password, udp: true}
            + (if ($n.stls_password // "") != "" then
                 {plugin: "shadow-tls", "plugin-opts": {host: $n.stls_sni, password: $n.stls_password, version: 3}} else {} end))
         elif $proto == "reality" then
           # support-x25519mlkem768: an Xray server from v26.9.8 on refuses a
           # REALITY client whose hello has no X25519MLKEM768 key share, and
           # mihomo sends one only when told to (and only as chrome). Older
           # Xray, sing-box and mihomo servers take the hello either way.
           ({type: "vless", uuid: $n.uuid, udp: true, tls: true, network: "tcp", servername: $n.server_name,
             "client-fingerprint": "chrome",
             "reality-opts": {"public-key": $n.public_key, "short-id": (($n.short_ids // [])[0] // $n.short_id // ""),
                              "support-x25519mlkem768": true}}
            + (if ($n.flow // "") != "" then {flow: $n.flow} else {} end)
            + (if ($n.vless_encryption // "") != "" then {encryption: $n.vless_encryption} else {} end))
         elif $proto == "vision" then
           ({type: "vless", uuid: $n.uuid, udp: true, tls: true, network: "tcp", servername: $n.domain,
             "client-fingerprint": "chrome"}
            + (if ($n.flow // "") != "" then {flow: $n.flow} else {} end)
            + (if ($n.vless_encryption // "") != "" then {encryption: $n.vless_encryption} else {} end))
         elif $proto == "xhttp" then
           # VLESS of the Xray xhttp store over XHTTP / WS / gRPC / HTTPUpgrade /
           # HTTP2 (XHTTP stream-one) or a REALITY layer, as _xhttp_share_uri links
           # them. HTTPUpgrade is the mihomo ws with v2ray-http-upgrade: the mihomo
           # link importer turns type=httpupgrade into a network its VLESS lacks.
           (($n.mode // "xhttp") as $m | ($n.path // "/") as $path | ($n.domain // "") as $dom
            | {type: "vless", uuid: $n.uuid, udp: true, tls: true, "client-fingerprint": "chrome"}
            + (if ($n.vless_encryption // "") != "" then {encryption: $n.vless_encryption} else {} end)
            + (if $m == "reality-layer" then
                 {servername: $n.server_name, "reality-opts": {"public-key": $n.public_key, "short-id": ($n.short_id // ""),
                                                               "support-x25519mlkem768": true}}
                 + (if ($n.reality_transport // "xhttp") == "grpc"
                    then {network: "grpc", "grpc-opts": {"grpc-service-name": ($path | ltrimstr("/"))}}
                    else {network: "xhttp", "xhttp-opts": {path: $path, mode: "auto"}} end)
               else {servername: $dom}
                 + (if   $m == "grpc"        then {network: "grpc", "grpc-opts": {"grpc-service-name": ($path | ltrimstr("/"))}}
                    elif $m == "ws" or $m == "upgrade" then {network: "ws", "ws-opts": {path: $path, headers: {Host: $dom}}}
                    elif $m == "httpupgrade" then {network: "ws", "ws-opts": {path: $path, headers: {Host: $dom}, "v2ray-http-upgrade": true}}
                    elif $m == "h2"          then {network: "xhttp", alpn: ["h2"], "xhttp-opts": {path: $path, host: $dom, mode: "stream-one"}}
                    else {network: "xhttp", "xhttp-opts": {path: $path, host: $dom, mode: "auto"}} end)
               end))
         elif $proto == "socks" then
           ({type: "socks5", udp: true}
            + (if ($n.username // "") != "" then {username: $n.username, password: $n.password} else {} end))
         elif $proto == "trojan" then
           ({type: "trojan", password: $n.password, udp: true, sni: $sni, "skip-cert-verify": $ins}
            + (if $core == "xray" then {alpn: ["h2", "http/1.1"]} else {} end))
         elif $proto == "vmess" then
           {type: "vmess", uuid: $n.uuid, alterId: 0, cipher: "auto", udp: true, tls: true, servername: $sni,
            "skip-cert-verify": $ins, network: "ws", "ws-opts": {path: ($n.path // "/"), headers: {Host: $sni}}}
         elif $proto == "hysteria2" then
           ({type: "hysteria2", password: $n.password, sni: $sni, "skip-cert-verify": $ins, alpn: ["h3"]}
            + (if ($n.hop_ports // "") != "" then {ports: $n.hop_ports} else {} end)
            + (if ($n.obfs_pass // "") != "" then {obfs: ($n.obfs_type // "salamander"), "obfs-password": $n.obfs_pass} else {} end))
         elif $proto == "anytls" then
           {type: "anytls", password: $n.password, udp: true, sni: $sni, "skip-cert-verify": $ins, "client-fingerprint": "chrome"}
         else
           {type: "tuic", uuid: $n.uuid, password: $n.password, sni: $sni, "skip-cert-verify": $ins, alpn: ["h3"],
            "congestion-controller": ($n.congestion_control // "bbr"), "udp-relay-mode": "native"}
         end)
      + (if ($n.ech_config // "") != "" then {"ech-opts": {enable: true, config: $n.ech_config}} else {} end)
      + (if ($n._pin.sha256 // "") != "" and $ins then {fingerprint: $n._pin.sha256} else {} end)'
}

# ── mihomo 客户端配置 ─────────────────────────────────────────────────────────
_sub_build_mihomo_client() {
    local server="$1"
    local uris; uris=$(_sub_collect_uris "$server")
    local names="" body=""
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        local nm; nm="${u##*\#}"
        names="${names}      - \"${nm}\"\n"
    done <<< "$uris"

    # proxies 直接引用订阅：mihomo 支持 proxy-provider，比在这里把每种协议再翻译
    # 一遍 YAML 更不容易漂移（协议字段一变，这里就得跟着改，而 provider 不用）。
    #
    # 唯一的例外是 HTTPUpgrade：mihomo 解析 vless://…type=httpupgrade 时把
    # network 原样写成 httpupgrade（它的 vless 客户端不认这个值），只有 path 带
    # ?ed= 时才开启升级 —— 导入后的节点根本不发 HTTP Upgrade（实测 v1.19.30）。
    # 这类节点从 provider 里排除，改为显式写成 ws + v2ray-http-upgrade。
    local hu_json hu_filter="" hu_proxies="" hu_names=""
    source "$LIB_DIR/node_cli.sh"
    hu_json=$(_node_cli_collect "" "" 2>/dev/null | jq -c --arg s "$server" --argjson u "${_SUB_USER:-null}" \
            --arg flag "$(psm_server_flag)" "$PSM_LABEL_JQ"'[.[]
        | .node.tag as $t | select($u == null or (($u.nodes | index("*")) != null) or (($u.nodes | index($t)) != null))
        | select((.core == "xray" and .protocol == "xhttp" and .node.mode == "httpupgrade")
              or (.core == "sing-box" and .protocol == "vless" and .node.transport == "httpupgrade"))
        | .node as $n
        | { name: ($n | psm_label($flag)), server: $s, port: ($n.public_port // $n.port), uuid: (if $u == null then $n.uuid else $u.uuid end),
            host: (if (.core == "xray") then $n.domain else $n.sni end), path: ($n.path // "/"),
            insecure: (($n.insecure // 0) | tostring | test("^(1|true)$")), cert_path: ($n.cert_path // "") }]' 2>/dev/null) || hu_json='[]'
    # self-signed: pin the certificate as well (psm_node_pins)
    local hu_e hu_pinned='[]'
    while IFS= read -r hu_e; do
        [[ -n "$hu_e" ]] || continue
        hu_e=$(psm_node_with_pins "$hu_e")
        hu_pinned=$(jq -c --argjson e "$hu_e" '. + [$e]' <<<"$hu_pinned")
    done < <(jq -c '.[]' <<<"${hu_json:-[]}")
    hu_json="$hu_pinned"
    if [[ "$(jq 'length' <<<"${hu_json:-[]}")" != "0" ]]; then
        hu_filter=$(jq -r '[.[].name | gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\])"; "\\\(.c)")] | "^(" + join("|") + ")$"' <<<"$hu_json")
        hu_filter=${hu_filter//\'/\'\'}   # it goes in a single-quoted YAML string
        hu_proxies=$(jq -r '.[] | "  - {name: \(.name|@json), type: vless, server: \(.server|@json), port: \(.port), uuid: \(.uuid|@json), tls: true, servername: \(.host|@json), skip-cert-verify: \(.insecure), \(if (._pin.sha256 // "") != "" and .insecure then "fingerprint: \(._pin.sha256|@json), " else "" end)network: ws, ws-opts: {path: \(.path|@json), headers: {Host: \(.host|@json)}, v2ray-http-upgrade: true}}"' <<<"$hu_json")
        hu_names=$(jq -r '.[] | "      - \(.name|@json)"' <<<"$hu_json")
    fi

    cat <<YAML
# mihomo client config generated by PSM
# Proxies come from a proxy-provider pointing at the subscription URL, so this
# file does not need editing when protocol fields change upstream.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxy-providers:
  psm:
    type: http
    url: "__SUB_URL__"
    interval: 3600
    path: ./psm-provider.yaml
${hu_filter:+    exclude-filter: '${hu_filter}'
}    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 300
${hu_proxies:+
proxies:
${hu_proxies}
}
proxy-groups:
  - name: PSM
    type: select
    use:
      - psm
${hu_names:+    proxies:
${hu_names}
}  - name: DIRECT-ONLY
    type: select
    proxies:
      - DIRECT

rules:
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - MATCH,PSM
YAML
}

# ── 本地导出 ─────────────────────────────────────────────────────────────────
# shellcheck disable=SC2120  # optional output dir; the menu uses the default
sub_export_local() {
    local server; server=$(get_ipv4 2>/dev/null || echo "")
    ask server "$(t sub.ask_server)" "$server"
    [[ -n "$server" ]] || { log_error "$(t sub.server_empty)"; return 1; }

    local out="${1:-$SUB_DIR/export}"
    mkdir -p "$out"; chmod 700 "$out"

    log_step "$(t sub.building)"
    local uris; uris=$(_sub_collect_uris "$server")
    if [[ -z "$uris" ]]; then log_warn "$(t sub.no_nodes)"; return 1; fi
    local cnt; cnt=$(printf '%s\n' "$uris" | grep -c . || true)

    printf '%s' "$(printf '%s' "$uris" | openssl base64 -A)" > "$out/psm-sub.txt"
    _sub_build_singbox_client "$server" > "$out/psm-singbox-client.json"
    _sub_build_mihomo_client  "$server" > "$out/psm-mihomo-client.yaml"
    chmod 600 "$out"/psm-*

    log_ok "$(t sub.exported "$cnt" "$out")"
    printf "  %s\n" "$out/psm-sub.txt" "$out/psm-singbox-client.json" "$out/psm-mihomo-client.yaml"
    echo -e "  ${YELLOW}$(t sub.local_warning)${NC}"
}

# ── 在线订阅 ─────────────────────────────────────────────────────────────────
# 文件落在伪装站的 webroot 下，经既有的 443 SNI 分流以 HTTPS 提供。
# 路径是 /psm-sub/<48 位随机 token>/，目录本身不可枚举（没有 autoindex），
# 没有 token 就找不到。token 可随时重置，重置即旧链接立刻失效。

_sub_token_dir() { printf '%s/%s/%s' "$SUB_WEBROOT" "$SUB_URL_PREFIX" "$1"; }

# 过期即删文件：不靠 Nginx 做时间判断（那需要额外模块），到期由定时任务清理，
# 清理后客户端拿到的是 404。有效期的意义是「泄露后的暴露窗口有限」。
sub_online_prune() {
    local exp; exp=$(_sub_state_get '.expires_at')
    [[ -n "$exp" ]] || return 0
    local now; now=$(date +%s)
    if (( now >= exp )); then
        local tok; tok=$(_sub_state_get '.token')
        [[ -n "$tok" ]] && rm -rf "$(_sub_token_dir "$tok")" 2>/dev/null || true
        _sub_state_save "$(_sub_state_load | jq '.expired = true')"
        log_info "$(t sub.online.expired_pruned)"
    fi
}

# Writes the three files of an online subscription for <server> (the address
# the share links carry). psm migrate rewrites them for the new host's address.
_sub_online_write() {   # <token> <domain> <server>
    local token="$1" domain="$2" server="$3" dir uris
    dir=$(_sub_token_dir "$token")
    uris=$(_sub_collect_uris "$server")
    [[ -n "$uris" ]] || { rm -rf "$dir"; return 1; }
    mkdir -p "$dir"
    local base="https://${domain}/${SUB_URL_PREFIX}/${token}"
    printf '%s' "$(printf '%s' "$uris" | openssl base64 -A)" > "$dir/sub.txt"
    _sub_build_singbox_client "$server" > "$dir/singbox.json"
    # mihomo 的 provider 要指回订阅本身，这里把占位符换成真实 URL
    _sub_build_mihomo_client "$server" | sed "s|__SUB_URL__|${base}/sub.txt|" > "$dir/mihomo.yaml"
    chmod 644 "$dir"/*            # Nginx 要读；保密性靠不可猜的 token，不靠权限
    chmod 711 "$dir"              # 不可列目录
}

sub_online_enable() {
    local domain; domain=$(_sub_state_get '.domain')
    [[ -n "$domain" ]] || ask domain "$(t sub.online.ask_domain)"
    [[ -n "$domain" ]] || { log_error "$(t sub.online.domain_empty)"; return 1; }

    # 订阅里全是凭据，必须走 HTTPS。伪装站是唯一现成的、带真实证书的 HTTPS 入口。
    source "$LIB_DIR/nginx.sh"
    if [[ ! -f "$NGINX_SSL_DIR/$domain/fullchain.pem" ]]; then
        log_warn "$(t sub.online.need_cert "$domain")"
        source "$LIB_DIR/cert.sh"
        cert_ensure_domain "$domain" || { log_error "$(t sub.online.no_cert)"; return 1; }
    fi
    nginx_setup_camouflage_site "$domain" || { log_error "$(t sub.online.site_failed)"; return 1; }
    # When Nginx owns 443 (SNI routing), the domain needs its own route to the
    # site (127.0.0.1:8443); without one the map's default drops the handshake.
    # A domain that already routes to a node keeps that route.
    if [[ -f "$(_sni_map_file)" ]] && ! _sni_lookup_entry "$domain" >/dev/null; then
        _sni_add_entry "$domain" "127.0.0.1:8443" || { log_error "$(t sub.online.site_failed)"; return 1; }
    fi

    local days; ask days "$(t sub.online.ask_days)" "$SUB_DEFAULT_DAYS"
    [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || { log_error "$(t sub.online.bad_days)"; return 1; }

    local server; server=$(get_ipv4 2>/dev/null || echo "$domain")
    ask server "$(t sub.ask_server)" "$server"

    # 旧 token 先删干净，避免留下一个仍然可用的旧链接
    local old; old=$(_sub_state_get '.token')
    [[ -n "$old" ]] && rm -rf "$(_sub_token_dir "$old")" 2>/dev/null || true

    local token; token=$(rand_str 48) || return 1
    log_step "$(t sub.building)"
    _sub_online_write "$token" "$domain" "$server" || { log_warn "$(t sub.no_nodes)"; return 1; }
    local base="https://${domain}/${SUB_URL_PREFIX}/${token}"

    local exp; exp=$(( $(date +%s) + days * 86400 ))
    _sub_state_save "$(jq -n --arg t "$token" --arg d "$domain" --arg s "$server" \
                             --argjson e "$exp" --argjson days "$days" \
        '{token:$t, domain:$d, server:$s, expires_at:$e, days:$days, expired:false}')"

    echo ""
    log_ok "$(t sub.online.enabled)"
    printf "  %-14s %s\n" "$(t sub.online.label_uri):"     "${base}/sub.txt"
    printf "  %-14s %s\n" "$(t sub.online.label_singbox):" "${base}/singbox.json"
    printf "  %-14s %s\n" "$(t sub.online.label_mihomo):"  "${base}/mihomo.yaml"
    printf "  %-14s %s\n" "$(t sub.online.label_expires):" "$(date -d "@$exp" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$exp" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$exp")"
    echo ""
    echo -e "  ${YELLOW}$(t sub.online.warning)${NC}"
}

sub_online_disable() {
    local tok; tok=$(_sub_state_get '.token')
    [[ -n "$tok" ]] || { log_warn "$(t sub.online.not_enabled)"; return 0; }
    ask_yn "$(t sub.online.confirm_disable)" N || return 0
    rm -rf "$(_sub_token_dir "$tok")" 2>/dev/null || true
    # the SNI route sub_online_enable added (only if it still points at the site)
    local domain; domain=$(_sub_state_get '.domain')
    source "$LIB_DIR/nginx.sh"
    if [[ -n "$domain" && "$(_sni_lookup_entry "$domain" 2>/dev/null)" == "127.0.0.1:8443" ]]; then
        _sni_remove_entry "$domain" || true
    fi
    _sub_state_save '{}'
    log_ok "$(t sub.online.disabled)"
}

sub_online_status() {
    local tok; tok=$(_sub_state_get '.token')
    if [[ -z "$tok" ]]; then echo -e "  $(t sub.online.not_enabled)"; return 0; fi
    local domain exp
    domain=$(_sub_state_get '.domain'); exp=$(_sub_state_get '.expires_at')
    local now; now=$(date +%s)
    local left=$(( (exp - now) / 86400 ))
    printf "  %-14s %s\n" "$(t sub.online.label_uri):" \
        "https://${domain}/${SUB_URL_PREFIX}/${tok}/sub.txt"
    if (( now >= exp )); then
        echo -e "  ${YELLOW}$(t sub.online.status_expired)${NC}"
    else
        printf "  %-14s %s\n" "$(t sub.online.label_expires):" "$(t sub.online.days_left "$left")"
    fi
}

# ── Menu ─────────────────────────────────────────────────────────────────────
sub_menu() {
    ensure_pkg_deps jq openssl
    while true; do
        sub_online_prune
        echo ""
        sub_online_status
        show_menu "$(t sub.menu.title)" \
            "$(t sub.menu.export_local)" \
            "$(t sub.menu.online_enable)" \
            "$(t sub.menu.online_status)" \
            "$(t sub.menu.online_disable)"
        case "$MENU_CHOICE" in
            1) sub_export_local; press_enter ;;
            2) sub_online_enable; press_enter ;;
            3) sub_online_status; press_enter ;;
            4) sub_online_disable; press_enter ;;
            0) return ;;
        esac
    done
}
