#!/usr/bin/env bash
# vpngate/core.sh — VPNGate 名单获取、家宽判定、候选排序（与代理核心无关）。
#
# VPNGate（筑波大学的志愿者中继计划）每天公开一份 CSV 名单，里面绝大多数节点
# 是志愿者家里的宽带线路——正是流媒体/风控最认的「家宽 IP」。名单同时也混着
# 不少机房 VPS，所以本模块做三件事：
#   1) 拉取并缓存 CSV 名单（VG_LIST_TTL 秒内复用，避免反复打官方接口）；
#   2) 按国家/评分粗筛后，用 ip-api.com 批量接口判定 IP 归属类型；
#   3) 输出按「家宽优先 + 评分」排序的候选表，供 tunnel.sh 逐个试连。
#
# 家宽判定只看 ip-api 的 hosting 字段（机房/托管 = 非家宽），刻意不看 proxy 字段：
# VPNGate 节点本身就是公开 VPN 出口，几乎全部会被标记 proxy=true，拿它判定会把
# 所有节点误杀成机房。proxy 只作为「已被公开代理库收录」的风险提示单独展示。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

VG_DIR="$CFG_DIR/vpngate"
VG_CSV="$VG_DIR/servers.csv"          # 原始 CSV 名单（含各节点的 base64 ovpn 配置）
VG_CAND="$VG_DIR/candidates.json"     # 已判定并排序的候选表
VG_IPINFO="$VG_DIR/ipinfo.json"       # ip-api 判定结果缓存：{ "<ip>": {...} }
VG_STATE="$VG_DIR/state.json"         # 当前隧道 / 绑定 / 守护状态

VG_LIST_TTL="${VG_LIST_TTL:-3600}"    # 名单缓存有效期（秒）
VG_SCAN_LIMIT="${VG_SCAN_LIMIT:-100}" # 送去判定的最大条数（ip-api 批量上限即 100/次）

# 官方接口先 https 后 http：部分机房出网会拦 https 到 vpngate.net，http 反而能通。
VG_API_URLS=(
    "https://www.vpngate.net/api/iphone/"
    "http://www.vpngate.net/api/iphone/"
)
VG_IPAPI_URL="http://ip-api.com/batch"
VG_IPAPI_FIELDS="status,message,query,country,countryCode,isp,org,as,mobile,proxy,hosting"

# ── 状态存取 ─────────────────────────────────────────────────────────────────
_vg_init() {
    mkdir -p "$VG_DIR"
    chmod 700 "$VG_DIR" 2>/dev/null || true
    [[ -f "$VG_STATE" ]]  || echo '{}' > "$VG_STATE"
    [[ -f "$VG_IPINFO" ]] || echo '{}' > "$VG_IPINFO"
    [[ -f "$VG_CAND" ]]   || echo '[]' > "$VG_CAND"
    return 0
}

vg_state_load() { _vg_init; jq '.' "$VG_STATE" 2>/dev/null || echo '{}'; }
vg_state_save() { _vg_init; printf '%s' "$1" | jq '.' > "$VG_STATE"; }

# vg_state_put <顶层键> <JSON 值>
vg_state_put() {
    local key="$1" val="$2" st
    st=$(vg_state_load)
    vg_state_save "$(echo "$st" | jq --arg k "$key" --argjson v "$val" '.[$k] = $v')"
}

# vg_state_get <jq 表达式> → stdout（缺失时输出空）
vg_state_get() { vg_state_load | jq -r "$1 // empty" 2>/dev/null || true; }

# ── 名单获取 ─────────────────────────────────────────────────────────────────
_vg_csv_rows() {
    [[ -s "$VG_CSV" ]] || { echo 0; return 0; }
    # grep -c 在零匹配时同时打印 0 并返回 1，所以取输出而不是靠 || 兜底，
    # 否则会输出两行 0。
    local n
    n=$(grep -cE '^[^*#]' "$VG_CSV" 2>/dev/null) || true
    echo "${n:-0}"
}

_vg_csv_age() {
    [[ -s "$VG_CSV" ]] || { echo 999999; return 0; }
    # GNU stat 优先，BSD（开发机 macOS）回落 -f %m，两者都没有就当作很旧。
    local mtime
    mtime=$(stat -c %Y "$VG_CSV" 2>/dev/null || stat -f %m "$VG_CSV" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - mtime ))
}

# vg_fetch_list [1=强制刷新]
vg_fetch_list() {
    local force="${1:-0}"
    _vg_init
    ensure_pkg_deps curl jq
    require_cmd curl jq

    if [[ "$force" != "1" ]] && [[ -s "$VG_CSV" ]]; then
        local age; age=$(_vg_csv_age)
        if (( age < VG_LIST_TTL )); then
            log_info "$(t vg.list.cached "$(_vg_csv_rows)" "$(( age / 60 ))")"
            return 0
        fi
    fi

    log_step "$(t vg.list.fetching)"
    local url tmp rc=1
    tmp=$(mktemp)
    for url in "${VG_API_URLS[@]}"; do
        # 名单约 1–3 MB，超时给足；拿到后校验表头，避免把运营商劫持页当成名单存下来。
        if curl -fsSL --max-time 60 "$url" -o "$tmp" 2>/dev/null && grep -q '^#HostName' "$tmp"; then
            rc=0; break
        fi
    done
    if (( rc )); then
        rm -f "$tmp"
        log_error "$(t vg.list.fetch_fail)"
        return 1
    fi
    mv "$tmp" "$VG_CSV"
    chmod 600 "$VG_CSV" 2>/dev/null || true
    log_ok "$(t vg.list.fetched "$(_vg_csv_rows)")"
}

# 名单里有哪些国家：每行「国家码 <TAB> 英文名 <TAB> 节点数」，按节点数倒序。
# 节点数多的国家排前面——挑家宽出口时它们才是真正有得选的那几个（JP/KR/US/TW）。
vg_country_table() {
    [[ -s "$VG_CSV" ]] || return 1
    awk -F, '/^[*#]/ { next } NF >= 15 { print $7 "\t" $6 }' "$VG_CSV" \
        | sort | uniq -c | sort -rn \
        | awk '{ cnt = $1; line = $0; sub(/^[ ]*[0-9]+[ ]+/, "", line); print line "\t" cnt }'
}

# 交互式国家选择器 → stdout：两位国家码或 ALL。
# 先把名单里“真的有节点”的国家连同节点数列出来给用户挑，而不是让人凭空猜一个
# 国家码：VPNGate 的节点分布极不均匀，很多国家只有一两个节点甚至没有。
vg_pick_country() {
    vg_fetch_list >&2 || return 1
    local def; def=$(vg_state_get '.filter.country'); [[ -n "$def" ]] || def="JP"

    local rows; rows=$(vg_country_table) || rows=""
    if [[ -z "$rows" ]]; then
        printf '%s' "$def"
        return 0
    fi

    local -a codes=()
    local cc name cnt i=0
    {
        echo ""
        echo -e "  ${BOLD}$(t vg.pick.title)${NC}"
    } >&2
    while IFS=$'\t' read -r cc name cnt; do
        [[ -n "$cc" ]] || continue
        codes+=("$cc")
        i=$(( i + 1 ))
        # 全 ASCII 定宽两列：国家名取自 CSV 的 CountryLong（都是英文），两列排布刚好
        # 落在 80 列以内，长国家名也不会被截断。
        printf "  %3d) %-2s %-24s %4s" "$i" "$cc" "${name:0:24}" "$cnt" >&2
        (( i % 2 == 0 )) && echo "" >&2
    done <<<"$rows"
    (( i % 2 == 0 )) || echo "" >&2
    {
        echo -e "    0) $(t vg.pick.all)"
        echo -e "  ${YELLOW}$(t vg.pick.hint)${NC}"
    } >&2

    local sel; ask sel "$(t vg.pick.prompt)" "$def" >&2
    sel="${sel:-$def}"
    if [[ "$sel" == "0" ]]; then
        printf 'ALL'
        return 0
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        if (( sel >= 1 && sel <= ${#codes[@]} )); then
            printf '%s' "${codes[$(( sel - 1 ))]}"
            return 0
        fi
        log_warn "$(t vg.pick.invalid "$def")" >&2
        printf '%s' "$def"
        return 0
    fi
    # 也接受直接敲国家码（含 ALL）
    printf '%s' "$(echo "$sel" | tr '[:lower:]' '[:upper:]')"
}

# 取某个 IP 对应的 .ovpn 明文配置（CSV 最后一列是 base64）。
# 用 $NF 而不是 $15：Message 列偶尔含逗号会顶掉列号，但 base64 永远是最后一列。
vg_ovpn_config() {
    local ip="$1"
    [[ -s "$VG_CSV" ]] || return 1
    local b64
    b64=$(awk -F, -v ip="$ip" '/^[*#]/ { next } $2 == ip { print $NF; exit }' "$VG_CSV" | tr -d '\r')
    [[ -n "$b64" ]] || return 1
    printf '%s' "$b64" | base64 -d 2>/dev/null
}

# ── 粗筛：按国家过滤 + 评分倒序 ───────────────────────────────────────────────
# 输出 JSON 数组。CSV 列序：1 HostName 2 IP 3 Score 4 Ping 5 Speed 6 CountryLong
# 7 CountryShort 8 NumVpnSessions 9 Uptime(ms) 10 TotalUsers 11 TotalTraffic
# 12 LogType 13 Operator 14 Message 15 OpenVPN_ConfigData_Base64
_vg_rows() {
    local cc="${1:-}" limit="${2:-100}"
    # 注意：这里用 awk 限量而不是 head——head 提前关闭管道会让上游 sort 收到
    # SIGPIPE，在 set -o pipefail 下整个脚本会被 errexit 带走。
    awk -F, -v cc="$cc" '
        /^[*#]/ { next }
        NF >= 15 {
            if (cc != "" && cc != "ALL" && $7 != cc) next
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $1, $3+0, $4+0, $5+0, $7, $9+0, $8+0
        }' "$VG_CSV" \
    | sort -t$'\t' -k3,3nr \
    | awk -F'\t' '!seen[$1]++' \
    | awk -v n="$limit" 'NR <= n' \
    | jq -R 'split("\t") | {
        ip: .[0], host: .[1],
        score:       (.[2] | tonumber),
        ping:        (.[3] | tonumber),
        speed_mbps:  ((.[4] | tonumber) / 1000000 | round),
        country:     .[5],
        uptime_days: ((.[6] | tonumber) / 86400000 | round),
        sessions:    (.[7] | tonumber)
      }' \
    | jq -sc '.'
}

# ── 家宽判定（ip-api.com 批量接口）───────────────────────────────────────────
# 只查缓存里没有的 IP，单次最多 100 个（免费批量接口上限，限频 15 次/分钟）。
_vg_classify() {
    local ips_json="$1"
    local need n
    need=$(jq -c --slurpfile c "$VG_IPINFO" '[.[] | select($c[0][.] == null)] | .[0:100]' <<<"$ips_json")
    n=$(jq 'length' <<<"$need")
    (( n == 0 )) && return 0

    log_step "$(t vg.scan.classifying "$n")"
    local body resp
    body=$(jq -c '[.[] | {query: .}]' <<<"$need")
    resp=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' \
                -d "$body" "${VG_IPAPI_URL}?fields=${VG_IPAPI_FIELDS}" 2>/dev/null) || resp=""

    if [[ -z "$resp" ]] || ! jq -e 'type == "array"' <<<"$resp" >/dev/null 2>&1; then
        log_warn "$(t vg.scan.classify_fail)"
        return 1
    fi

    local merged
    merged=$(jq -c --argjson r "$resp" \
        'reduce $r[] as $x (.; if ($x.status == "success") then .[$x.query] = $x else . end)' \
        "$VG_IPINFO") || return 1
    printf '%s' "$merged" | jq '.' > "$VG_IPINFO"
}

# ── 扫描：名单 → 粗筛 → 判定 → 候选表 ────────────────────────────────────────
# vg_scan <国家码|ALL> <只要家宽 0|1> [送判定条数]
vg_scan() {
    local cc="${1:-JP}" home_only="${2:-1}" limit="${3:-$VG_SCAN_LIMIT}"
    vg_fetch_list || return 1

    local rows n
    rows=$(_vg_rows "$cc" "$limit")
    n=$(jq 'length' <<<"$rows")
    if (( n == 0 )); then
        log_warn "$(t vg.scan.no_rows "$cc")"
        return 1
    fi
    local cc_label="$cc"
    [[ "$cc" == "ALL" || -z "$cc" ]] && cc_label="$(t vg.scan.any_country)"
    log_info "$(t vg.scan.picked "$n" "$cc_label")"

    _vg_classify "$(jq -c '[.[].ip]' <<<"$rows")" || true

    # 合并判定结果 → 排序：家宽 → 移动 → 未知 → 机房，同类按评分倒序。
    local cand
    cand=$(jq -c --slurpfile info "$VG_IPINFO" '
        [ .[] | . + ( ($info[0][.ip] // {}) | {
              isp:  (.isp // ""),
              as:   (.as // ""),
              hosting: .hosting,
              mobile:  .mobile,
              proxy_flagged: (.proxy == true)
          } )
          | . + { kind: (
                if   .hosting == true then "dc"
                elif ( ((.isp // "") + " " + (.as // "")) | ascii_downcase
                       | test("softether") ) then "dc"
                elif .mobile  == true then "mobile"
                elif .hosting == null then "unknown"
                else "home" end ) } ]
        | sort_by( (if .kind == "home" then 0 elif .kind == "mobile" then 1
                    elif .kind == "unknown" then 2 else 3 end), (-.score) )
    ' <<<"$rows")

    if [[ "$home_only" == "1" ]]; then
        cand=$(jq -c '[.[] | select(.kind == "home" or .kind == "mobile")]' <<<"$cand")
        if [[ "$(jq 'length' <<<"$cand")" == "0" ]]; then
            log_warn "$(t vg.scan.no_home "$cc")"
            return 1
        fi
    fi

    _vg_init
    printf '%s' "$cand" | jq '.' > "$VG_CAND"
    vg_state_put filter "$(jq -nc --arg cc "$cc" --arg h "$home_only" \
        '{country: $cc, home_only: ($h == "1"), scanned_at: (now | todate)}')"
    log_ok "$(t vg.scan.done "$(jq 'length' <<<"$cand")")"
}

vg_candidates() { _vg_init; jq '.' "$VG_CAND" 2>/dev/null || echo '[]'; }
vg_candidate_at() { vg_candidates | jq -c --argjson i "$1" '.[$i] // empty'; }
vg_candidate_count() { vg_candidates | jq 'length'; }

# 打印候选表（默认前 20 条）。
# 表头与「类型」一律用 ASCII：printf 的 %-Ns 数的是字符数而不是终端列宽，中日韩
# 文案一进列就会把整张表挤歪。列含义交给下面一行本地化图例说明，ISP 排在最后一
# 列，就算含非 ASCII 也不会带偏别的列。
vg_show_candidates() {
    local top="${1:-20}"
    local cands n
    cands=$(vg_candidates)
    n=$(jq 'length' <<<"$cands")
    if (( n == 0 )); then
        log_warn "$(t vg.cand.empty)"
        return 1
    fi

    echo ""
    echo -e "${BOLD}${BLUE}$(t vg.cand.title)${NC}"
    echo -e "  ${YELLOW}$(t vg.cand.legend)${NC}"
    printf "  %-3s %-16s %-3s %-7s %-6s %-7s %-5s %s\n" \
        "#" "IP" "CC" "TYPE" "PING" "SPEED" "UP" "ISP"
    local i line
    for (( i = 0; i < n && i < top; i++ )); do
        line=$(jq -r --argjson i "$i" '.[$i] |
            [ .ip, .country, .kind, (.ping|tostring), (.speed_mbps|tostring),
              (.uptime_days|tostring),
              (.isp // "" | .[0:28] | if . == "" then "-" else . end),
              (.proxy_flagged|tostring) ]
            | @tsv' <<<"$cands")
        # ISP 为空时补 "-"：IFS 设成制表符后，bash 仍会把连续的空白类分隔符
        # 折叠成一个，空字段会让后面的列整体前移。
        local ip cc kind ping speed up isp flagged
        IFS=$'\t' read -r ip cc kind ping speed up isp flagged <<<"$line"
        [[ "$flagged" == "true" ]] && isp="${isp} *"
        printf "  %-3s %-16s %-3s %-7s %-6s %-7s %-5s %s\n" \
            "$(( i + 1 ))" "$ip" "$cc" "$kind" \
            "${ping}ms" "${speed}M" "${up}d" "$isp"
    done
    echo -e "  ${YELLOW}$(t vg.cand.footnote)${NC}"
    (( n > top )) && echo -e "  $(t vg.cand.more "$(( n - top ))")"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
    return 0
}

# 导出某候选的 .ovpn（原样导出官方配置，方便在别处直接用）。
vg_export_ovpn() {
    local ip="$1" out="${2:-}"
    [[ -n "$out" ]] || out="$VG_DIR/${ip}.ovpn"
    local cfg
    cfg=$(vg_ovpn_config "$ip") || { log_error "$(t vg.ovpn.not_found "$ip")"; return 1; }
    [[ -n "$cfg" ]] || { log_error "$(t vg.ovpn.not_found "$ip")"; return 1; }
    printf '%s\n' "$cfg" > "$out"
    chmod 600 "$out" 2>/dev/null || true
    log_ok "$(t vg.ovpn.exported "$out")"
}
