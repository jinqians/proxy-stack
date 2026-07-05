#!/usr/bin/env bash
# xray/sni_finder.sh — Reality 伪装目标发现（测绘引擎，按同 ASN 过滤，零本机扫描）
#
# Reality 把客户端 TLS 握手真实转发给 dest 站点做伪装，理想的 dest 应真实、稳定、
# 支持 TLS1.3 + X25519 + h2，且网络路径上离 VPS 近（同机房 / 同 ASN）。本模块通过
# 网络空间测绘引擎（Netlas / Quake / ZoomEye / FOFA，四选一）按 `asn=<本机 ASN>`
# 查询同网络主机的「IP + 证书域名」，组成候选 `sni|dest` 对，再复用 watchdog 的
# _rwd_check_dest 对入围候选逐个做一次 TLS 握手校验。
#
# ⚠️ 默认路径零本机扫描：发现完全由引擎（其数据来自各自合规的全网采集）完成，本机只
# 发只读查询请求；校验仅对最终入围的少量候选各握手一次，与 watchdog 周期测活同性质。
# 本机主动扫描邻居 IP（附录 B）默认禁用，不在本模块实现。

# 载入守卫：本模块被 reality.sh / xhttp.sh / reality_watchdog.sh 惰性 source，且自身又
# source reality_watchdog.sh（→ reality.sh），需防止重复载入导致的重复定义 / 潜在环路。
[[ -n "${_SNI_FINDER_LOADED:-}" ]] && return 0
_SNI_FINDER_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/reality_watchdog.sh"   # 复用 _rwd_check_dest / rwd_add_candidate

SNI_CACHE="$CFG_DIR/xray/sni_pool_cache.json"
SNI_VALIDATE_CAP="${SNI_VALIDATE_CAP:-15}"     # 本地握手校验最多尝试的候选数
SNI_HEALTHY_TARGET="${SNI_HEALTHY_TARGET:-6}"  # 凑够这么多健康候选即提前停止校验
SNI_FORCE_REFRESH="${SNI_FORCE_REFRESH:-0}"    # =1 时忽略缓存，强制重新查询引擎

# ── 小工具 ────────────────────────────────────────────────────────────────────
_sni_check_deps() { ensure_pkg_deps curl jq openssl 2>/dev/null || true; }

# 掩码显示 key（前 4 后 4），绝不完整打印。
_sni_mask_key() {
    local k="$1" n=${#1}
    if (( n <= 8 )); then printf '****'; else printf '%s****%s' "${k:0:4}" "${k: -4}"; fi
}

# ── 引擎选择与凭据 ─────────────────────────────────────────────────────────────
# 选引擎 + 存 key（state_set，600/root-only），并立即用账号信息端点验证/显示剩余额度。
# 所有交互输出走 stderr，保证从 pick_one 命令替换里调用时 stdout 洁净。
_sni_setup_engine() {
    _sni_check_deps
    echo -e "\n  ${BOLD}测绘引擎选择${NC}" >&2
    echo -e "  1. Netlas     （免费额度实用，推荐）" >&2
    echo -e "  2. Quake(360)" >&2
    echo -e "  3. ZoomEye" >&2
    echo -e "  4. FOFA" >&2
    local e; read -rp "$(echo -e "${CYAN}请选择 [1]: ${NC}")" e
    local engine
    case "${e:-1}" in
        2) engine=quake ;;
        3) engine=zoomeye ;;
        4) engine=fofa ;;
        *) engine=netlas ;;
    esac

    local key; ask key "${engine} API Key"
    [[ -z "$key" ]] && { log_warn "未输入 API Key，已取消。" >&2; return 1; }

    state_set "sni_engine"    "$engine"
    state_set "${engine}_key" "$key"
    log_ok "已保存测绘引擎：${engine}（Key：$(_sni_mask_key "$key")）" >&2

    # 立即预检额度（best-effort，字段以各引擎文档为准，取不到不阻断）
    _sni_engine_quota "$engine" || true
    return 0
}

_sni_have_engine() {
    local eng; eng=$(state_get sni_engine)
    [[ -n "$eng" && -n "$(state_get "${eng}_key")" ]]
}

# ── 自身 ASN / 国家（免 key）───────────────────────────────────────────────────
# 用现成 get_ipv4 拿本机公网 IP，再按序试 ip-api → ipinfo → BGPView 查其归属。
# 只把「本就公开的公网 IP」发给这些免费源，非扫描。设 SNI_SELF_ASN / SNI_SELF_COUNTRY。
_sni_self_asn_country() {
    SNI_SELF_ASN=""
    SNI_SELF_COUNTRY=""
    local ip asn="" cc="" resp=""
    ip=$(get_ipv4) || true
    [[ -z "$ip" ]] && { log_warn "无法获取本机公网 IP。" >&2; return 1; }

    # 1. ip-api.com（.as = "AS24940 Hetzner ..."，取 AS 后数字；.countryCode）
    resp=$(curl -s --max-time 8 "http://ip-api.com/json/${ip}?fields=as,countryCode" 2>/dev/null) || true
    if [[ -n "$resp" ]]; then
        asn=$(printf '%s' "$resp" | jq -r '.as // empty' 2>/dev/null | grep -oiE 'AS[0-9]+' | head -1 | tr -dc '0-9') || true
        cc=$(printf '%s' "$resp" | jq -r '.countryCode // empty' 2>/dev/null) || true
    fi

    # 2. ipinfo.io（.org = "AS24940 ..."；.country）
    if [[ -z "$asn" ]]; then
        resp=$(curl -s --max-time 8 "https://ipinfo.io/${ip}/json" 2>/dev/null) || true
        asn=$(printf '%s' "$resp" | jq -r '.org // empty' 2>/dev/null | grep -oiE 'AS[0-9]+' | head -1 | tr -dc '0-9') || true
        [[ -z "$cc" ]] && cc=$(printf '%s' "$resp" | jq -r '.country // empty' 2>/dev/null) || true
    fi

    # 3. api.bgpview.io
    if [[ -z "$asn" ]]; then
        resp=$(curl -s --max-time 8 "https://api.bgpview.io/ip/${ip}" 2>/dev/null) || true
        asn=$(printf '%s' "$resp" | jq -r '.data.prefixes[0].asn.asn // empty' 2>/dev/null | tr -dc '0-9') || true
        [[ -z "$cc" ]] && cc=$(printf '%s' "$resp" | jq -r '.data.prefixes[0].asn.country_code // empty' 2>/dev/null) || true
    fi

    # 三源都失败 → 让用户手输 ASN（留空则由上层退回手输 SNI）
    if ! [[ "$asn" =~ ^[0-9]+$ ]]; then
        log_warn "无法自动识别本机 ASN（ip-api / ipinfo / BGPView 均失败）。" >&2
        local manual=""
        ask manual "请手输本机 ASN 号（纯数字，留空放弃）"
        manual=$(printf '%s' "$manual" | tr -dc '0-9')
        [[ -z "$manual" ]] && return 1
        asn="$manual"
    fi

    SNI_SELF_ASN="$asn"
    SNI_SELF_COUNTRY="$cc"
    log_info "本机归属：ASN=AS${SNI_SELF_ASN}${cc:+  国家=${cc}}" >&2
    return 0
}

# ── 各引擎 curl 封装（对照 cloudflare.sh 的 _cf_curl 风格）────────────────────
_netlas_curl()  { curl -s --max-time 25 -H "X-API-Key: $(state_get netlas_key)"  "$@"; }
_quake_curl()   { curl -s --max-time 25 -H "X-QuakeToken: $(state_get quake_key)" -H "Content-Type: application/json" "$@"; }
_zoomeye_curl() { curl -s --max-time 25 -H "API-KEY: $(state_get zoomeye_key)" -H "Content-Type: application/json" "$@"; }
_fofa_curl()    { curl -s --max-time 25 "$@"; }   # FOFA 的 key 作为 query 参数传递

# ── 额度预检（best-effort；账号信息端点字段随版本变化，取不到不阻断）──────────
# 返回 0 = 可继续（含「额度未知」）；返回 1 = 明确读到额度为 0，应退回手输。
_sni_engine_quota() {
    local engine="$1" resp="" remain=""
    case "$engine" in
        netlas)
            resp=$(_netlas_curl "https://app.netlas.io/api/users/current/" 2>/dev/null) || true
            remain=$(printf '%s' "$resp" | jq -r '
                (.total_requests_left // .requests_left // .available // .month_downloads_left // empty)' 2>/dev/null) || true
            ;;
        quake)
            resp=$(_quake_curl "https://quake.360.net/api/v3/user/info" 2>/dev/null) || true
            remain=$(printf '%s' "$resp" | jq -r '
                (.data.credit // .data.month_remaining_credit // .data.persistent_credit // empty)' 2>/dev/null) || true
            ;;
        zoomeye)
            resp=$(_zoomeye_curl "https://api.zoomeye.ai/resources-info" 2>/dev/null) || true
            remain=$(printf '%s' "$resp" | jq -r '
                (.quota_info.remain_total_quota // .quota_info.remain_free_quota // empty)' 2>/dev/null) || true
            ;;
        fofa)
            resp=$(_fofa_curl "https://fofa.info/api/v1/info/my?key=$(state_get fofa_key)" 2>/dev/null) || true
            remain=$(printf '%s' "$resp" | jq -r '(.remain_api_query // .fofa_point // empty)' 2>/dev/null) || true
            ;;
    esac
    if [[ "$remain" =~ ^[0-9]+$ ]]; then
        log_info "测绘引擎 ${engine} 剩余额度：${remain}" >&2
        (( remain == 0 )) && { log_warn "引擎 ${engine} 额度已耗尽。" >&2; return 1; }
    else
        log_info "测绘引擎 ${engine} 额度信息不可用（继续尝试查询）。" >&2
    fi
    return 0
}

# ── 结果归一化 ────────────────────────────────────────────────────────────────
# stdin: 每行 "domain<TAB>ip"（domain 可能是证书 CN / SAN / host）。
# 输出唯一的 "domain|dest" 行：去 `*.`、去空/无点域名、按域名去重、dest 优先钉引擎给的
# 同 ASN 主机 IP（IP:443），无 IP 时退化为 domain:443；截断到 max 条。
_sni_normalize_pairs() {
    local max="${1:-40}"
    awk -F'\t' '
        {
            name=$1; ip=$2
            sub(/^\*\./, "", name)                             # 去通配符前缀
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", name)
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", ip)
            if (name == "" || tolower(name) == "null") next    # 去空域名
            if (name !~ /\./) next                             # 必须是 FQDN
            if (name ~ /[^A-Za-z0-9.-]/) next                  # 仅允许主机名字符（排除数组字面量/引号/空格等脏值）
            if (ip == "" || tolower(ip) == "null") dest = name ":443"
            else dest = ip ":443"
            if (!seen[name]++) print name "|" dest             # 按域名去重
        }
    ' | head -n "$max"
}

# ── 引擎后端：产出 "sni|dest" 对（按同 ASN 过滤，低等级退化为国家过滤）─────────
# 每个后端签名：_<engine>_discover_pairs <asn> <country> <max>

# Netlas：GET /api/responses/?q=<urlenc>&start=0，头 X-API-Key
_netlas_query() {
    local q="$1" resp=""
    resp=$(_netlas_curl -G "https://app.netlas.io/api/responses/" \
        --data-urlencode "q=${q}" --data "start=0" 2>/dev/null) || true
    [[ -z "$resp" ]] && return 0
    # Netlas 的证书字段（subject.common_name / names / subject_alternative_name）常为
    # 数组，需 flatten 展平成字符串，否则会漏出 ["www.x.com"] 这样的数组字面量。
    printf '%s' "$resp" | jq -r '
        (.items // [])[]? | (.data // .) as $d
        | ($d.ip // $d.host // "") as $ip
        | ( [ ($d.certificate.subject.common_name // empty),
              ($d.certificate.subject_common_name // empty),
              ($d.certificate.names // empty),
              ($d.certificate.subject_alternative_name // empty),
              ($d.domain // empty) ]
            | flatten | map(select(type == "string" and . != "")) | .[] ) as $name
        | "\($name)\t\($ip)"
    ' 2>/dev/null || true
}

_netlas_discover_pairs() {
    local asn="$1" country="$2" max="$3" rows=""
    # responses 索引的 ASN 字段是 whois.asn.number（asn.number / asn 都取不到结果，实测确认）。
    rows=$(_netlas_query "whois.asn.number:${asn} AND port:443 AND protocol:https") || true
    if [[ -z "$rows" && -n "$country" ]]; then
        log_info "Netlas：ASN 过滤无结果，改用国家(${country})过滤。" >&2
        rows=$(_netlas_query "geo.country:${country} AND port:443 AND protocol:https") || true
    fi
    printf '%s\n' "$rows" | _sni_normalize_pairs "$max"
}

# Quake(360)：POST /api/v3/search/quake_service，头 X-QuakeToken，JSON body
_quake_query() {
    local q="$1" max="$2" body="" resp=""
    body=$(jq -nc --arg q "$q" --argjson size "$max" '{query:$q, start:0, size:$size, ignore_cache:false}') || return 0
    resp=$(_quake_curl -X POST "https://quake.360.net/api/v3/search/quake_service" --data "$body" 2>/dev/null) || true
    [[ -z "$resp" ]] && return 0
    # Quake 的 .service.cert 是原始 PEM 字符串（非结构化），域名取 .domain / .hostname 即可（实测确认）。
    printf '%s' "$resp" | jq -r '
        (.data // [])[]? | (.ip // "") as $ip
        | ( [ (.domain // empty),
              (.hostname // empty) ]
            | flatten | map(select(type == "string" and . != "")) | .[] ) as $name
        | "\($name)\t\($ip)"
    ' 2>/dev/null || true
}

_quake_discover_pairs() {
    local asn="$1" country="$2" max="$3" rows=""
    rows=$(_quake_query "asn:\"${asn}\" AND service:\"http/ssl\"" "$max") || true
    if [[ -z "$rows" && -n "$country" ]]; then
        log_info "Quake：ASN 过滤无结果，改用国家(${country})过滤。" >&2
        rows=$(_quake_query "country:\"${country}\" AND service:\"http/ssl\"" "$max") || true
    fi
    printf '%s\n' "$rows" | _sni_normalize_pairs "$max"
}

# ZoomEye v2：POST /v2/search，头 API-KEY，body 含 qbase64（旧版 GET /host/search 已停用，
# 免费 key 请求会返 402 credits_insufficient）。注意：v2 数据行字段随版本/fields 参数变化，
# 下面按文档做多路径防御性解析；若你的 ZoomEye 账号搜索额度可用但抽取为空，据实际响应调整字段路径。
_zoomeye_query() {
    local q="$1" max="${2:-40}" b64="" resp=""
    b64=$(printf '%s' "$q" | base64 | tr -d '\n') || return 0
    resp=$(_zoomeye_curl -X POST "https://api.zoomeye.ai/v2/search" \
        --data "$(jq -nc --arg q "$b64" --argjson n "$max" '{qbase64:$q, page:1, pagesize:$n}')" 2>/dev/null) || true
    [[ -z "$resp" ]] && return 0
    if printf '%s' "$resp" | jq -e '.code? and (.code != 60000)' >/dev/null 2>&1; then
        log_warn "ZoomEye 查询失败：$(printf '%s' "$resp" | jq -r '.message // .error // "unknown"' 2>/dev/null)" >&2
        return 0
    fi
    printf '%s' "$resp" | jq -r '
        (.data // [])[]? | (.ip // .ipv4 // .ip_addr // "") as $ip
        | ( [ (.domain // empty),
              (.hostname // empty),
              (.rdns // empty),
              (.ssl.cert.subject.cn // empty),
              (.ssl_cert.subject_cn // empty) ]
            | flatten | map(select(type == "string" and . != "")) | .[] ) as $name
        | "\($name)\t\($ip)"
    ' 2>/dev/null || true
}

_zoomeye_discover_pairs() {
    local asn="$1" country="$2" max="$3" rows=""
    rows=$(_zoomeye_query "asn=${asn} && service=\"https\"" "$max") || true
    if [[ -z "$rows" && -n "$country" ]]; then
        log_info "ZoomEye：ASN 过滤无结果，改用国家(${country})过滤。" >&2
        rows=$(_zoomeye_query "country=\"${country}\" && service=\"https\"" "$max") || true
    fi
    printf '%s\n' "$rows" | _sni_normalize_pairs "$max"
}

# FOFA：GET /api/v1/search/all?key=&qbase64=&fields=ip,port,domain,host,as_number&size=
_fofa_query() {
    local q="$1" max="$2" b64="" resp=""
    b64=$(printf '%s' "$q" | base64 | tr -d '\n') || return 0
    resp=$(_fofa_curl -G "https://fofa.info/api/v1/search/all" \
        --data-urlencode "key=$(state_get fofa_key)" \
        --data-urlencode "qbase64=${b64}" \
        --data "fields=ip,port,domain,host,as_number" \
        --data "size=${max}" 2>/dev/null) || true
    [[ -z "$resp" ]] && return 0
    if printf '%s' "$resp" | jq -e '.error == true' >/dev/null 2>&1; then
        log_warn "FOFA 查询失败：$(printf '%s' "$resp" | jq -r '.errmsg // "unknown"' 2>/dev/null)" >&2
        return 0
    fi
    # results 每行是 [ip, port, domain, host, as_number]（顺序对应 fields）
    printf '%s' "$resp" | jq -r '(.results // [])[]? | "\(.[2] // "")\t\(.[0] // "")"' 2>/dev/null || true
}

_fofa_discover_pairs() {
    local asn="$1" country="$2" max="$3" rows=""
    rows=$(_fofa_query "asn=\"${asn}\" && port=\"443\" && protocol=\"https\" && domain!=\"\"" "$max") || true
    if [[ -z "$rows" && -n "$country" ]]; then
        log_info "FOFA：ASN 过滤无结果，改用国家(${country})过滤。" >&2
        rows=$(_fofa_query "country=\"${country}\" && port=\"443\" && protocol=\"https\" && domain!=\"\"" "$max") || true
    fi
    printf '%s\n' "$rows" | _sni_normalize_pairs "$max"
}

# ── 缓存（config/xray/sni_pool_cache.json，24h）────────────────────────────────
# 结构：{ "<asn>_<engine>": { "ts": <epoch>, "pairs": ["domain|dest", ...] } }
_sni_cache_get() {
    local asn="$1" engine="$2"
    [[ "$SNI_FORCE_REFRESH" == "1" ]] && return 1
    [[ -f "$SNI_CACHE" ]] || return 1
    local key="${asn}_${engine}" now ts
    now=$(date +%s)
    ts=$(jq -r --arg k "$key" '.[$k].ts // empty' "$SNI_CACHE" 2>/dev/null) || true
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    (( now - ts > 86400 )) && return 1
    jq -r --arg k "$key" '.[$k].pairs[]? // empty' "$SNI_CACHE" 2>/dev/null || true
}

_sni_cache_put() {
    local asn="$1" engine="$2" pairs="$3"
    mkdir -p "$(dirname "$SNI_CACHE")"
    [[ -f "$SNI_CACHE" ]] || echo '{}' > "$SNI_CACHE"
    local key="${asn}_${engine}" now pairs_json tmp
    now=$(date +%s)
    pairs_json=$(printf '%s\n' "$pairs" | jq -R . | jq -sc 'map(select(length > 0))') || return 0
    tmp=$(mktemp) || return 0
    if jq --arg k "$key" --argjson ts "$now" --argjson p "$pairs_json" \
        '.[$k] = {"ts":$ts, "pairs":$p}' "$SNI_CACHE" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SNI_CACHE"
    else
        rm -f "$tmp"
    fi
    return 0
}

# ── 分派：按 sni_engine 调对应后端（命中缓存优先）────────────────────────────
_sni_discover_pairs() {
    local max="${1:-40}"
    local engine; engine=$(state_get sni_engine)
    [[ -z "$engine" ]] && return 1

    local cached; cached=$(_sni_cache_get "$SNI_SELF_ASN" "$engine") || true
    if [[ -n "$cached" ]]; then
        log_info "命中 24h 缓存（AS${SNI_SELF_ASN} / ${engine}），跳过引擎查询（SNI_FORCE_REFRESH=1 可强制刷新）。" >&2
        printf '%s\n' "$cached"
        return 0
    fi

    # 查询前预检额度，明确为 0 则退回手输
    _sni_engine_quota "$engine" || { log_warn "引擎额度不足，退回手输 SNI。" >&2; return 1; }

    local pairs=""
    case "$engine" in
        netlas)  pairs=$(_netlas_discover_pairs  "$SNI_SELF_ASN" "$SNI_SELF_COUNTRY" "$max") || true ;;
        quake)   pairs=$(_quake_discover_pairs   "$SNI_SELF_ASN" "$SNI_SELF_COUNTRY" "$max") || true ;;
        zoomeye) pairs=$(_zoomeye_discover_pairs  "$SNI_SELF_ASN" "$SNI_SELF_COUNTRY" "$max") || true ;;
        fofa)    pairs=$(_fofa_discover_pairs      "$SNI_SELF_ASN" "$SNI_SELF_COUNTRY" "$max") || true ;;
        *) return 1 ;;
    esac

    if [[ -n "$pairs" ]]; then
        _sni_cache_put "$SNI_SELF_ASN" "$engine" "$pairs"
        printf '%s\n' "$pairs"
    fi
    return 0
}

# ── 共享校验：逐个复用 watchdog 的 _rwd_check_dest ────────────────────────────
# 输入若干 "sni|dest" 行；对每个做一次真实 TLS1.3 握手校验，健康才输出
# "sni<TAB>dest<TAB>rtt<TAB>warn"。限 SNI_VALIDATE_CAP 次尝试，凑够 SNI_HEALTHY_TARGET
# 即停。逐候选进度打到 stderr。不另写 TLS 检测，保证「发现合格 = 测活合格」。
_sni_validate_pairs() {
    local pairs="$1"
    local attempts=0 healthy=0 line sni dest
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        (( attempts  >= SNI_VALIDATE_CAP ))   && break
        (( healthy   >= SNI_HEALTHY_TARGET )) && break
        sni="${line%%|*}"
        dest="${line#*|}"
        [[ -z "$sni" || -z "$dest" || "$sni" == "$dest" ]] && continue
        attempts=$((attempts + 1))
        printf '  [%d/%d] 校验 %s → %s ... ' "$attempts" "$SNI_VALIDATE_CAP" "$sni" "$dest" >&2
        if _rwd_check_dest "$dest" "$sni"; then
            healthy=$((healthy + 1))
            printf '%b健康%b %sms%s\n' "$GREEN" "$NC" "${RWD_CHECK_RTT_MS:-?}" \
                "${RWD_CHECK_WARN:+ [${RWD_CHECK_WARN}]}" >&2
            printf '%s\t%s\t%s\t%s\n' "$sni" "$dest" "${RWD_CHECK_RTT_MS:-0}" "${RWD_CHECK_WARN:-}"
        else
            printf '%b不合格%b（%s）\n' "$YELLOW" "$NC" "${RWD_CHECK_REASON:-unknown}" >&2
        fi
    done <<< "$pairs"
    return 0
}

# ── 对外入口 1：交互挑 1 个，stdout 只回显最终 "sni|dest" ──────────────────────
sni_finder_pick_one() {
    _sni_have_engine || { _sni_setup_engine || { log_warn "未配置测绘引擎，请手动输入 SNI。" >&2; return 1; }; }
    _sni_self_asn_country || { log_warn "无法自动识别本机 ASN，请手动输入 SNI。" >&2; return 1; }

    log_step "正在从 $(state_get sni_engine) 查询同 ASN(AS${SNI_SELF_ASN}) 的候选伪装目标..." >&2
    local pairs; pairs=$(_sni_discover_pairs 40) || true
    [[ -z "$pairs" ]] && { log_warn "未发现候选伪装目标，请手动输入 SNI。" >&2; return 1; }

    local n_found; n_found=$(printf '%s\n' "$pairs" | grep -c '|' || true)
    log_step "发现 ${n_found} 个候选，正在本地校验（TLS1.3 / X25519 / 证书匹配，逐个握手，稍候）..." >&2

    local healthy; healthy=$(_sni_validate_pairs "$pairs") || true
    [[ -z "$healthy" ]] && { log_warn "候选均未通过 Reality 合规校验，请手动输入 SNI。" >&2; return 1; }
    healthy=$(printf '%s\n' "$healthy" | sort -t"$(printf '\t')" -k3,3n) || true

    echo -e "\n  ${BOLD}通过校验的候选伪装目标（按握手延迟升序）：${NC}" >&2
    printf "  %-3s %-30s %-26s %-9s %s\n" "#" "SNI" "dest" "RTT" "警告" >&2
    local -a _snis=() _dests=()
    local idx=0 sni dest rtt warn
    while IFS=$'\t' read -r sni dest rtt warn; do
        [[ -z "$sni" ]] && continue
        idx=$((idx + 1))
        _snis+=("$sni"); _dests+=("$dest")
        local note=""
        [[ "$dest" == "${sni}:443" ]] && note="非IP钉定"
        printf "  %-3s %-30s %-26s %-9s %s\n" "$idx" "$sni" "$dest" "${rtt}ms" "${warn}${note:+ ${note}}" >&2
    done <<< "$healthy"
    (( idx == 0 )) && { log_warn "无可用候选，请手动输入 SNI。" >&2; return 1; }

    local sel; read -rp "$(echo -e "${CYAN}选择要使用的伪装目标编号 [1]（0 = 放弃并手输）: ${NC}")" sel
    sel="${sel:-1}"
    [[ "$sel" == "0" ]] && { log_info "已放弃自动发现，请手动输入 SNI。" >&2; return 1; }
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > idx )); then
        log_warn "无效选择，请手动输入 SNI。" >&2
        return 1
    fi
    printf '%s|%s' "${_snis[$((sel - 1))]}" "${_dests[$((sel - 1))]}"
}

# ── 对外入口 2：批量校验并逐个 rwd_add_candidate 到某 tag 候选池 ──────────────
sni_finder_pick_many() {
    local tag="$1"
    [[ -z "$tag" ]] && { log_error "sni_finder_pick_many：缺少节点标识。"; return 1; }

    _sni_have_engine || { _sni_setup_engine || { log_warn "未配置测绘引擎，跳过自动发现。"; return 1; }; }
    _sni_self_asn_country || { log_warn "无法自动识别本机 ASN，跳过自动发现。"; return 1; }

    log_step "正在从 $(state_get sni_engine) 查询同 ASN(AS${SNI_SELF_ASN}) 的候选伪装目标..."
    local pairs; pairs=$(_sni_discover_pairs 40) || true
    [[ -z "$pairs" ]] && { log_warn "未发现候选伪装目标。"; return 1; }

    local n_found; n_found=$(printf '%s\n' "$pairs" | grep -c '|' || true)
    log_step "发现 ${n_found} 个候选，正在本地校验（逐个 TLS 握手，稍候）..."

    local healthy; healthy=$(_sni_validate_pairs "$pairs") || true
    [[ -z "$healthy" ]] && { log_warn "候选均未通过 Reality 合规校验，未加入任何候选。"; return 1; }
    healthy=$(printf '%s\n' "$healthy" | sort -t"$(printf '\t')" -k3,3n) || true

    local added=0 sni dest rtt warn
    while IFS=$'\t' read -r sni dest rtt warn; do
        [[ -z "$sni" || -z "$dest" ]] && continue
        rwd_add_candidate "$tag" "$sni" "$dest" && added=$((added + 1))
    done <<< "$healthy"
    log_ok "已批量加入 ${added} 个通过校验的候选伪装目标到节点 ${tag}。"
    return 0
}
