#!/usr/bin/env bash
# warp_probe.sh — 三核（Xray / sing-box / mihomo）共用的 WARP 出口探测。
#
# 探测方式：各核心自行拉起一个临时进程（socks 入站 → WARP 出站），把本地
# socks 端口交给这里，按地址族逐个 curl Cloudflare 的 cdn-cgi/trace。
#
# 为什么必须用 IP 字面量而不是域名：域名会被核心的域名策略解析到"它偏好"
# 的那一族——双栈出口下通常是 IPv6，于是 IPv4 出口永远探不到（表现为
# "双栈只显示 IPv6"）。IP 字面量能把请求钉死在指定地址族的隧道路径上：
#   IPv4 → https://1.1.1.1/cdn-cgi/trace
#   IPv6 → https://[2606:4700:4700::1111]/cdn-cgi/trace
# （两个地址同属 Cloudflare，证书含 IP SAN，trace 会回显 ip= 与 warp= 状态。）

# _warp_trace_family <socks端口> <4|6> → stdout：trace 文本；失败输出为空。
_warp_trace_family() {
    local port="$1" fam="$2" url
    case "$fam" in
        6) url="https://[2606:4700:4700::1111]/cdn-cgi/trace" ;;
        *) url="https://1.1.1.1/cdn-cgi/trace" ;;
    esac
    curl -s --max-time 15 -x "socks5h://127.0.0.1:${port}" "$url" 2>/dev/null
}

# warp_probe_families <family: 4|6|46> <local_v6>
# → 应探测的地址族列表（"4"、"6" 或 "4 6"）。
# 与各核心构建出站时的降级逻辑一致：账号没有 v6 隧道地址时一律回落纯 v4。
warp_probe_families() {
    local family="${1:-4}" v6="${2:-}"
    case "$family" in
        6)  [[ -n "$v6" ]] && echo "6"   || echo "4" ;;
        46) [[ -n "$v6" ]] && echo "4 6" || echo "4" ;;
        *)  echo "4" ;;
    esac
}

# warp_probe_report <socks端口> <family...>   （family ∈ 4|6）
# 每个地址族打印一行结果（出口 IP、地区、warp 状态）。
# 所有请求的地址族均为 warp=on/plus 时才返回 0。
warp_probe_report() {
    local port="$1"; shift
    local ok=1 fam label trace exit_ip loc state
    echo ""
    echo -e "${BOLD}${BLUE}$(t warp.probe.title)${NC}"
    for fam in "$@"; do
        [[ "$fam" == "6" ]] && label="IPv6" || label="IPv4"
        trace=$(_warp_trace_family "$port" "$fam") || true
        if [[ -z "$trace" ]]; then
            echo -e "  ${RED}$(t warp.probe.fail "$label")${NC}"
            ok=0; continue
        fi
        exit_ip=$(awk -F= '/^ip=/{print $2}'   <<<"$trace")
        loc=$(awk -F= '/^loc=/{print $2}'      <<<"$trace")
        state=$(awk -F= '/^warp=/{print $2}'   <<<"$trace")
        if [[ "$state" == "on" || "$state" == "plus" ]]; then
            echo -e "  ${GREEN}$(t warp.probe.ok "$label" "${exit_ip:-?}" "${loc:-?}" "$state")${NC}"
        else
            # 拿到了公网 IP 但 warp=off → 流量没走隧道，按失败处理
            echo -e "  ${YELLOW}$(t warp.probe.not_warp "$label" "${exit_ip:-?}" "${state:-off}")${NC}"
            ok=0
        fi
    done
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
    (( ok ))
}
