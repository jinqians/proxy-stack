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
        [[ "$proto" == "snell" ]] && continue
        if [[ "$proto" == "socks" ]] \
           && [[ "$(printf '%s' "$node" | jq -r '.listen_addr // ""')" == "127.0.0.1" ]]; then
            continue
        fi
        _node_cli_export_uri "$core" "$proto" "$node" "$server" 2>/dev/null || true
    done < <(printf '%s' "$all" | jq -c '.[]')

    # 独立协议（Hysteria2 / ss-rust / Snell）不在三内核的节点存储里，单独收集。
    # 「导出全部节点」漏掉它们的话，用户拿到的订阅是残缺的，而且不会有任何提示。
    _sub_standalone_uris "$server"
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
        [[ -n "$pw" ]] && printf 'hysteria2://%s@%s:%s?insecure=%s&sni=%s#PSM-Hysteria2\n' \
            "$(url_encode "$pw")" "$server" "$port" "$insecure" "$sni"
    fi

    # 独立 ss-rust
    local ss_cfg="/etc/ss-rust/config.json"
    if [[ -f "$ss_cfg" ]]; then
        local port method pw
        port=$(jq -r '.server_port // empty' "$ss_cfg" 2>/dev/null)
        method=$(jq -r '.method // empty'    "$ss_cfg" 2>/dev/null)
        pw=$(jq -r '.password // empty'      "$ss_cfg" 2>/dev/null)
        if [[ -n "$port" && -n "$method" && -n "$pw" ]]; then
            printf 'ss://%s@%s:%s#PSM-ss-rust\n' \
                "$(printf '%s:%s' "$method" "$pw" | openssl base64 -A | tr '+/' '-_' | tr -d '=')" \
                "$server" "$port"
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
            printf '# Surge: PSM-Snell = snell, %s, %s, psk=%s, version=%s\n' \
                "$server" "$port" "$psk" "${ver:-4}"
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
        ob=$(_sub_sb_outbound "$core" "$proto" "$node" "$server" "$tag") || continue
        [[ -n "$ob" ]] || continue
        obs=$(printf '%s' "$obs"   | jq -c --argjson o "$ob" '. += [$o]')
        tags=$(printf '%s' "$tags" | jq -c --arg t "PSM-$tag" '. += [$t]')
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

# 单个节点 → sing-box 客户端 outbound。不支持的协议返回空串由调用方跳过。
_sub_sb_outbound() {
    local core="$1" proto="$2" n="$3" server="$4" tag="$5"
    local port; port=$(printf '%s' "$n" | jq -r '.public_port // .port')
    case "$proto" in
        reality)
            jq -n --arg t "PSM-$tag" --arg s "$server" --argjson p "$port" \
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
            jq -n --arg t "PSM-$tag" --arg s "$server" --argjson p "$port" \
                  --arg u "$(printf '%s' "$n" | jq -r '.uuid')" \
                  --arg f "$(printf '%s' "$n" | jq -r '.flow // ""')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni // .domain')" \
                  --arg tr "$(printf '%s' "$n" | jq -r '.transport // "tcp"')" \
                  --arg path "$(printf '%s' "$n" | jq -r '.path // "/"')" '
                { type:"vless", tag:$t, server:$s, server_port:$p, uuid:$u,
                  tls:{ enabled:true, server_name:$sn } }
                + (if $f == "" then {} else {flow:$f} end)
                + (if   $tr == "tcp"  then {}
                   elif $tr == "grpc" then {transport:{type:"grpc", service_name:($path|ltrimstr("/"))}}
                   elif $tr == "quic" then {transport:{type:"quic"}}
                   else {transport:{type:$tr, path:$path}} end)' ;;
        trojan)
            jq -n --arg t "PSM-$tag" --arg s "$server" --argjson p "$port" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni // .domain')" '
                { type:"trojan", tag:$t, server:$s, server_port:$p, password:$pw,
                  tls:{ enabled:true, server_name:$sn } }' ;;
        vmess)
            jq -n --arg t "PSM-$tag" --arg s "$server" --argjson p "$port" \
                  --arg u "$(printf '%s' "$n" | jq -r '.uuid')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni // .domain')" \
                  --arg path "$(printf '%s' "$n" | jq -r '.path // "/"')" '
                { type:"vmess", tag:$t, server:$s, server_port:$p, uuid:$u, security:"auto",
                  tls:{ enabled:true, server_name:$sn },
                  transport:{ type:"ws", path:$path } }' ;;
        ss2022)
            jq -n --arg t "PSM-$tag" --arg s "$server" --argjson p "$port" \
                  --arg m "$(printf '%s' "$n" | jq -r '.method')" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" '
                { type:"shadowsocks", tag:$t, server:$s, server_port:$p, method:$m, password:$pw }' ;;
        hysteria2)
            jq -n --arg t "PSM-$tag" --arg s "$server" --argjson p "$port" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni')" \
                  --argjson ins "$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')" '
                { type:"hysteria2", tag:$t, server:$s, server_port:$p, password:$pw,
                  tls:{ enabled:true, server_name:$sn, insecure:($ins == 1) } }' ;;
        anytls)
            jq -n --arg t "PSM-$tag" --arg s "$server" --argjson p "$port" \
                  --arg pw "$(printf '%s' "$n" | jq -r '.password')" \
                  --arg sn "$(printf '%s' "$n" | jq -r '.sni')" \
                  --argjson ins "$(printf '%s' "$n" | jq -r '.insecure | if . == true then 1 elif . == false then 0 else . end')" '
                { type:"anytls", tag:$t, server:$s, server_port:$p, password:$pw,
                  tls:{ enabled:true, server_name:$sn, insecure:($ins == 1) } }' ;;
        *) printf '' ;;   # vision/xhttp/snell/socks 交给 URI 订阅，不进原生配置
    esac
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
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: PSM
    type: select
    use:
      - psm
  - name: DIRECT-ONLY
    type: select
    proxies:
      - DIRECT

rules:
  - GEOIP,PRIVATE,DIRECT,no-resolve
  - MATCH,PSM
YAML
}

# ── 本地导出 ─────────────────────────────────────────────────────────────────
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

    local days; ask days "$(t sub.online.ask_days)" "$SUB_DEFAULT_DAYS"
    [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || { log_error "$(t sub.online.bad_days)"; return 1; }

    local server; server=$(get_ipv4 2>/dev/null || echo "$domain")
    ask server "$(t sub.ask_server)" "$server"

    # 旧 token 先删干净，避免留下一个仍然可用的旧链接
    local old; old=$(_sub_state_get '.token')
    [[ -n "$old" ]] && rm -rf "$(_sub_token_dir "$old")" 2>/dev/null || true

    local token; token=$(rand_str 48) || return 1
    local dir; dir=$(_sub_token_dir "$token")
    mkdir -p "$dir"

    log_step "$(t sub.building)"
    local uris; uris=$(_sub_collect_uris "$server")
    [[ -n "$uris" ]] || { log_warn "$(t sub.no_nodes)"; rm -rf "$dir"; return 1; }

    local base="https://${domain}/${SUB_URL_PREFIX}/${token}"
    printf '%s' "$(printf '%s' "$uris" | openssl base64 -A)" > "$dir/sub.txt"
    _sub_build_singbox_client "$server" > "$dir/singbox.json"
    # mihomo 的 provider 要指回订阅本身，这里把占位符换成真实 URL
    _sub_build_mihomo_client "$server" | sed "s|__SUB_URL__|${base}/sub.txt|" > "$dir/mihomo.yaml"
    chmod 644 "$dir"/*            # Nginx 要读；保密性靠不可猜的 token，不靠权限
    chmod 711 "$dir"              # 不可列目录

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
