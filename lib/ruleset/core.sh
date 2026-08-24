#!/usr/bin/env bash
# ruleset/core.sh — 订阅式规则集：拉取、解析、校验、入库（与代理核心无关）。
#
# 解决的问题：想让 ChatGPT 走家宽出口，以前得一条条手敲 DOMAIN-SUFFIX，域名一变
# 还得自己跟。这里改成贴一个社区维护的规则表 URL，把「规则维护」外包出去。
#
# 吃的是 Surge / Clash 的 classical 文本格式（`DOMAIN-SUFFIX,openai.com` 这种），
# 社区规则表绝大多数都是它。三个核心对规则集的支持差别很大，所以解析在这里做一次，
# 各核心再按自己的方式落地（见 apply.sh）：
#   mihomo   → 原生 rule-providers，URL 直接交给它，自己定时刷新
#   sing-box → 转成 source JSON 落地成 local rule_set（1.10+ 文件改动会自动重载）
#   Xray     → 没有规则集概念，只能内联展开进 routing rules
#
# 刻意只认域名与 IP 这几类：PROCESS-NAME / USER-AGENT 这些是客户端才有的信息，
# 服务端根本看不到；IP-ASN 只有 mihomo 支持。被丢弃的条数会明确报给用户看，
# 而不是悄悄跳过——用户以为规则全生效、实际漏了一半，是最难查的那种问题。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

RS_DIR="$CFG_DIR/ruleset"
RS_SETS="$RS_DIR/sets.json"        # 规则集目录：[{name,url,total,counts,dropped,updated_at}]
RS_CACHE_DIR="$RS_DIR/cache"       # 原始 .list 副本
RS_PARSED_DIR="$RS_DIR/parsed"     # 解析结果 JSON
RS_LOG="$LOG_DIR/ruleset.log"

# 条数上限：Xray 要把规则内联进 config.json，mihomo 的 classical 行为是逐条线性
# 匹配，两者都受不了几万行的全量分流表。那种表属于客户端的活，这里直接拒绝。
RS_MAX_RULES="${RS_MAX_RULES:-5000}"
RS_WARN_RULES="${RS_WARN_RULES:-1000}"
RS_MAX_BYTES="${RS_MAX_BYTES:-5000000}"

# 内置常用规则集（blackmatrix7，社区事实标准，路径长期稳定）。
# 一律指向专题表而不是 ChinaMax 那种全量表：这里是「选出口」，不是「走不走代理」。
RS_PRESET_BASE="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash"
RS_PRESETS=(
    "openai|${RS_PRESET_BASE}/OpenAI/OpenAI.list"
    "netflix|${RS_PRESET_BASE}/Netflix/Netflix.list"
    "disney|${RS_PRESET_BASE}/Disney/Disney.list"
    "youtube|${RS_PRESET_BASE}/YouTube/YouTube.list"
    "spotify|${RS_PRESET_BASE}/Spotify/Spotify.list"
)

# ── 存储 ─────────────────────────────────────────────────────────────────────
_rs_init() {
    mkdir -p "$RS_DIR" "$RS_CACHE_DIR" "$RS_PARSED_DIR"
    chmod 700 "$RS_DIR" 2>/dev/null || true
    [[ -f "$RS_SETS" ]] || echo '[]' > "$RS_SETS"
    return 0
}

rs_sets_load() { _rs_init; jq '.' "$RS_SETS" 2>/dev/null || echo '[]'; }
rs_sets_save() { _rs_init; printf '%s' "$1" | jq '.' > "$RS_SETS"; }
rs_set_get()   { rs_sets_load | jq -c --arg n "$1" '[.[] | select(.name == $n)][0] // empty'; }
rs_set_names() { rs_sets_load | jq -r '.[].name'; }
rs_set_count() { rs_sets_load | jq 'length'; }

rs_set_upsert() {
    local entry="$1" name
    name=$(jq -r '.name' <<<"$entry")
    rs_sets_save "$(rs_sets_load | jq --arg n "$name" --argjson e "$entry" \
        '[.[] | select(.name != $n)] + [$e]')"
}

rs_set_delete() {
    rs_sets_save "$(rs_sets_load | jq --arg n "$1" '[.[] | select(.name != $n)]')"
    rm -f "$RS_CACHE_DIR/$1.list" "$RS_PARSED_DIR/$1.json"
}

rs_parsed_path() { printf '%s/%s.json' "$RS_PARSED_DIR" "$1"; }
rs_parsed_json() {
    local p; p=$(rs_parsed_path "$1")
    [[ -s "$p" ]] || return 1
    cat "$p"
}

# 名字要当文件名、sing-box rule_set tag、mihomo provider key 用，收紧到安全字符集。
rs_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }

# ── 拉取 ─────────────────────────────────────────────────────────────────────
# 只认 https：这份内容会被写进路由配置，决定哪些流量走哪个出口，明文 http 传输
# 等于把这个决定权交给路上的任何人。
rs_fetch() {
    local url="$1" out="$2"
    ensure_pkg_deps curl jq
    require_cmd curl jq
    if [[ "$url" != https://* ]]; then
        log_error "$(t rs.fetch.https_only)"
        return 1
    fi
    if ! curl -fsSL --max-time 30 --max-filesize "$RS_MAX_BYTES" "$url" -o "$out" 2>/dev/null; then
        log_error "$(t rs.fetch.fail "$url")"
        return 1
    fi
    [[ -s "$out" ]] || { log_error "$(t rs.fetch.empty)"; return 1; }
}

# ── 解析 ─────────────────────────────────────────────────────────────────────
# 输入：Surge/Clash classical 文本；输出：分类后的 JSON。
# 值都过一遍正则：规则表是第三方内容，畸形条目会让核心整份配置校验失败，
# 与其让服务起不来，不如在这里丢掉并计数。
rs_parse() {
    local file="$1"
    awk -F, '
        { sub(/\r$/, "") }
        /^[[:space:]]*(#|;|\/\/|$)/ { next }
        {
            t = toupper($1); gsub(/^[ \t]+|[ \t]+$/, "", t)
            v = $2;          gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v == "") next
            print t "\t" v
        }' "$file" \
    | jq -Rc 'split("\t") | {type: .[0], value: .[1]}' \
    | jq -sc '
        def dom_ok: test("^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$");
        def kw_ok:  test("^[A-Za-z0-9._-]{2,}$");
        def cidr_ok: test("^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$");
        def norm_cidr: if test("/") then . elif test(":") then . + "/128" else . + "/32" end;
        # 每个字段都必须用括号包住：jq 里对象值表达式中的 `|` 优先级低于 `,`，
        # 不加括号会变成「整个对象再管道给 unique」，直接报错。
        {
          domain:         ( [ .[] | select(.type == "DOMAIN")         | .value | select(dom_ok) ] | unique ),
          domain_suffix:  ( [ .[] | select(.type == "DOMAIN-SUFFIX")  | .value | select(dom_ok) ] | unique ),
          domain_keyword: ( [ .[] | select(.type == "DOMAIN-KEYWORD") | .value | select(kw_ok)  ] | unique ),
          ip_cidr:        ( [ .[] | select(.type == "IP-CIDR" or .type == "IP-CIDR6")
                                  | .value | select(cidr_ok) | norm_cidr ] | unique ),
          # 先把类型绑成 $t 再查表：写成 `[...] | index(.type)` 的话，管道右侧的 `.`
          # 已经是那个常量数组了，.type 会取到 null，所有类型都会被判成「已丢弃」。
          dropped: ( [ .[]
                       | . as $r
                       | select( ["DOMAIN","DOMAIN-SUFFIX","DOMAIN-KEYWORD","IP-CIDR","IP-CIDR6"]
                                 | index($r.type) | not )
                       | .type ]
                     | group_by(.) | map({key: .[0], value: length}) | from_entries )
        }
        | . + { total: ((.domain | length) + (.domain_suffix | length)
                        + (.domain_keyword | length) + (.ip_cidr | length)) }'
}

rs_counts_of() {   # <parsed> → "域名 N / 关键字 N / IP N"
    jq -r '"\((.domain|length) + (.domain_suffix|length)) + \(.domain_keyword|length) + \(.ip_cidr|length)"' <<<"$1"
}

# ── 预检：拉 + 解析 + 体检报告 ────────────────────────────────────────────────
# 返回 0 表示可用；解析结果写到 $RS_STAGE_PARSED，原始表写到 $RS_STAGE_RAW。
RS_STAGE_RAW=""
RS_STAGE_PARSED=""

rs_stage() {
    local url="$1" quiet="${2:-0}"
    _rs_init
    local tmpdir; tmpdir=$(mktemp -d)
    RS_STAGE_RAW="$tmpdir/raw.list"
    RS_STAGE_PARSED="$tmpdir/parsed.json"

    rs_fetch "$url" "$RS_STAGE_RAW" || { rm -rf "$tmpdir"; return 1; }
    if ! rs_parse "$RS_STAGE_RAW" > "$RS_STAGE_PARSED" 2>/dev/null; then
        log_error "$(t rs.parse.fail)"; rm -rf "$tmpdir"; return 1
    fi

    local total; total=$(jq -r '.total' "$RS_STAGE_PARSED")
    if (( total == 0 )); then
        log_error "$(t rs.parse.nothing)"
        rm -rf "$tmpdir"; return 1
    fi
    if (( total > RS_MAX_RULES )); then
        log_error "$(t rs.parse.too_big "$total" "$RS_MAX_RULES")"
        log_warn  "$(t rs.parse.too_big_hint)"
        rm -rf "$tmpdir"; return 1
    fi
    (( quiet )) || rs_report "$RS_STAGE_PARSED"
    return 0
}

# 体检报告：分类条数 + 被丢弃的类型（以及为什么丢）。
rs_report() {
    local parsed="$1"
    local d ds dk ip total
    d=$(jq -r '.domain|length' "$parsed");         ds=$(jq -r '.domain_suffix|length' "$parsed")
    dk=$(jq -r '.domain_keyword|length' "$parsed"); ip=$(jq -r '.ip_cidr|length' "$parsed")
    total=$(jq -r '.total' "$parsed")

    echo ""
    echo -e "  ${BOLD}$(t rs.report.title)${NC}"
    echo -e "  $(t rs.report.counts "$total" "$((d + ds))" "$dk" "$ip")"

    local dropped; dropped=$(jq -r '.dropped | to_entries | map("\(.key)×\(.value)") | join("  ")' "$parsed")
    if [[ -n "$dropped" && "$dropped" != "null" ]]; then
        echo -e "  ${YELLOW}$(t rs.report.dropped "$dropped")${NC}"
        echo -e "  ${YELLOW}$(t rs.report.dropped_why)${NC}"
    fi
    (( total > RS_WARN_RULES )) && echo -e "  ${YELLOW}$(t rs.report.big_warn "$total" "$RS_WARN_RULES")${NC}"
    return 0
}

# ── 变更闸门 ─────────────────────────────────────────────────────────────────
# 往路由里注入第三方 URL 的内容，等于把「哪些流量走哪个出口」的决定权交给了那个
# 仓库的维护者。上游被投毒或改名时，规模通常会异常抖动——所以更新时先比条数，
# 暴涨暴跌一律拦下来要人工确认，而不是照单全收。
rs_change_ok() {
    local old="$1" new="$2"
    (( old <= 0 )) && return 0
    (( new <= 0 )) && return 1
    (( new * 2 < old )) && return 1      # 缩水超过一半
    (( new > old * 5 )) && return 1      # 膨胀超过五倍
    return 0
}

# 落库：把暂存的原始表与解析结果收进 $RS_DIR，并更新目录。
rs_commit() {
    local name="$1" url="$2"
    _rs_init
    cp "$RS_STAGE_RAW"    "$RS_CACHE_DIR/$name.list"
    cp "$RS_STAGE_PARSED" "$(rs_parsed_path "$name")"
    chmod 600 "$RS_CACHE_DIR/$name.list" "$(rs_parsed_path "$name")" 2>/dev/null || true

    local entry
    entry=$(jq -c --arg n "$name" --arg u "$url" \
        '{name: $n, url: $u, total: .total,
          counts: {domain: (.domain|length), domain_suffix: (.domain_suffix|length),
                   domain_keyword: (.domain_keyword|length), ip_cidr: (.ip_cidr|length)},
          dropped: .dropped, updated_at: (now | todate)}' "$RS_STAGE_PARSED")
    rs_set_upsert "$entry"
}

rs_stage_cleanup() {
    [[ -n "$RS_STAGE_RAW" ]] && rm -rf "$(dirname "$RS_STAGE_RAW")"
    RS_STAGE_RAW=""; RS_STAGE_PARSED=""
    return 0
}

_rs_log() {
    mkdir -p "$LOG_DIR"
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$RS_LOG"
}
