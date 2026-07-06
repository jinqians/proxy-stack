#!/usr/bin/env bash
# tgbot/relay_status.sh — 中转服务器状态报告（realm）
# 供 Telegram Bot（/relay 命令、中转状态按钮）和 realm 菜单共用：
# 汇总 realm 服务状态、本机资源消耗（CPU/内存/磁盘/负载）、实时网速，
# 以及每条中转规则到落地机的 TCP 可达性 / 延迟 / 抖动。
# 输出为 Telegram Markdown；本机终端显示时由调用方剥掉标记符。

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

source "$LIB_DIR/realm.sh" 2>/dev/null || true

# ── 探测参数 ──────────────────────────────────────────────────────────────────
RS_PROBE_COUNT=3      # 每条规则的 TCP 连接探测次数
RS_PROBE_TIMEOUT=2    # 单次探测超时（秒）
RS_MAX_RULES=8        # 最多探测的规则数（防止规则太多时报告耗时过长）

# ── 基础采样 ──────────────────────────────────────────────────────────────────
# /proc/stat 首行快照：输出 "total idle"
_rs_cpu_snapshot() {
    awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print total, idle}' \
        /proc/stat 2>/dev/null
}

# 默认路由网卡名（用于网速采样）
_rs_default_iface() {
    ip -o route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# 网卡累计收发字节：输出 "rx_bytes tx_bytes"
_rs_net_snapshot() {
    local iface="$1"
    [[ -n "$iface" ]] || { echo "0 0"; return; }
    awk -v ifc="${iface}:" '$1 == ifc {print $2, $10}' /proc/net/dev 2>/dev/null \
        || echo "0 0"
}

# 字节速率 → 人类可读（B/s、KB/s、MB/s）
_rs_fmt_rate() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1048576)   printf "%.1f MB/s", b/1048576;
        else if (b >= 1024) printf "%.1f KB/s", b/1024;
        else                printf "%d B/s", b;
    }'
}

# 对 host:port 做 n 次 TCP 连接测量。
# 输出 "ok总数 探测次数 平均延迟ms 抖动ms"；抖动 = 相邻两次成功延迟差的均值。
_rs_tcp_probe() {
    local host="$1" port="$2" n="${3:-$RS_PROBE_COUNT}"
    local i t0 t1 ms ok=0 total=0 prev="" jsum=0 jn=0
    for ((i = 0; i < n; i++)); do
        t0=$(date +%s%3N)
        if timeout "$RS_PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
            t1=$(date +%s%3N)
            ms=$(( t1 - t0 ))
            ok=$(( ok + 1 )); total=$(( total + ms ))
            if [[ -n "$prev" ]]; then
                local d=$(( ms > prev ? ms - prev : prev - ms ))
                jsum=$(( jsum + d )); jn=$(( jn + 1 ))
            fi
            prev=$ms
        fi
    done
    local avg=0 jit=0
    (( ok > 0 )) && avg=$(( total / ok ))
    (( jn > 0 )) && jit=$(( jsum / jn ))
    printf '%s %s %s %s' "$ok" "$n" "$avg" "$jit"
}

# 监听端口当前 ESTABLISHED 连接数
_rs_conn_count() {
    local port="$1"
    command -v ss &>/dev/null || { echo "?"; return; }
    ss -Htn state established "( sport = :${port} )" 2>/dev/null | wc -l | tr -d ' '
}

# ── 报告分节 ──────────────────────────────────────────────────────────────────
_rs_section_service() {
    local bin="${REALM_BIN:-/usr/local/bin/realm}"
    if [[ ! -f "$bin" ]]; then
        printf "$(t tgbot.rs.service_not_installed)"
        return
    fi
    local ver; ver=$("$bin" --version 2>/dev/null | head -1 | awk '{print $NF}')
    local state uptime=""
    state=$(systemctl is-active realm 2>/dev/null || true)
    if [[ "$state" == "active" ]]; then
        local since
        since=$(systemctl show realm --property=ActiveEnterTimestamp --value 2>/dev/null)
        if [[ -n "$since" ]]; then
            local since_ts now_ts
            since_ts=$(date -d "$since" +%s 2>/dev/null || echo 0)
            now_ts=$(date +%s)
            if (( since_ts > 0 )); then
                local s=$(( now_ts - since_ts ))
                uptime="$(t tgbot.rs.uptime $((s/86400)) $((s%86400/3600)) $((s%3600/60)))"
            fi
        fi
        printf "$(t tgbot.rs.service_running)" "${ver:-?}" "${uptime:+$(t tgbot.rs.service_uptime_suffix "$uptime")}"
    else
        printf "$(t tgbot.rs.service_stopped)" "${state:-unknown}"
    fi
}

# CPU / 网速共用同一个 1 秒采样窗口
_rs_section_resources_and_net() {
    [[ -f /proc/stat ]] || return 0

    local iface; iface=$(_rs_default_iface)
    local cpu0 cpu1 net0 net1
    cpu0=$(_rs_cpu_snapshot)
    net0=$(_rs_net_snapshot "$iface")
    sleep 1
    cpu1=$(_rs_cpu_snapshot)
    net1=$(_rs_net_snapshot "$iface")

    # CPU
    local t0 i0 t1 i1 cpu_pct="?"
    read -r t0 i0 <<< "$cpu0"
    read -r t1 i1 <<< "$cpu1"
    if [[ "$t1" =~ ^[0-9]+$ && "$t0" =~ ^[0-9]+$ ]] && (( t1 > t0 )); then
        cpu_pct=$(( ( (t1 - t0) - (i1 - i0) ) * 100 / (t1 - t0) ))
    fi

    # 负载 / 内存 / 磁盘
    local loadavg mem_line disk_line
    loadavg=$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)
    mem_line=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
        END {if (t>0) printf "%.0f%% (%.1f/%.1f GB)", (t-a)*100/t, (t-a)/1048576, t/1048576}' \
        /proc/meminfo 2>/dev/null)
    disk_line=$(df -P / 2>/dev/null | awk 'NR==2 {printf "%s (%.1f/%.1f GB)", $5, $3/1048576, $2/1048576}')

    # realm 进程自身占用
    local proc_line=""
    if command -v ps &>/dev/null; then
        local proc_cpu proc_mem proc_rss
        read -r proc_cpu proc_mem proc_rss <<< "$(ps -C realm -o %cpu=,%mem=,rss= 2>/dev/null | head -1 \
            | awk '{printf "%s %s %.1f", $1, $2, $3/1024}')"
        [[ -n "$proc_cpu" ]] && proc_line="$(t tgbot.rs.proc_line "$proc_cpu" "$proc_mem" "$proc_rss")"
    fi

    printf "$(t tgbot.rs.resources_title)"
    printf "$(t tgbot.rs.cpu_line)" "$cpu_pct" "${loadavg:-?}"
    printf "$(t tgbot.rs.mem_line)" "${mem_line:-?}"
    printf "$(t tgbot.rs.disk_line)" "${disk_line:-?}"
    [[ -n "$proc_line" ]] && printf "$(t tgbot.rs.realm_proc_line)" "$proc_line"

    # 网速（同一窗口的字节差）
    if [[ -n "$iface" ]]; then
        local rx0 tx0 rx1 tx1
        read -r rx0 tx0 <<< "$net0"
        read -r rx1 tx1 <<< "$net1"
        if [[ "$rx1" =~ ^[0-9]+$ && "$rx0" =~ ^[0-9]+$ ]]; then
            printf "$(t tgbot.rs.net_title)" "$iface"
            printf "$(t tgbot.rs.net_line)" \
                "$(_rs_fmt_rate $(( rx1 - rx0 )))" \
                "$(_rs_fmt_rate $(( tx1 - tx0 )))"
        fi
    fi
}

_rs_section_rules() {
    declare -f _realm_load &>/dev/null || return 0
    local rules; rules=$(_realm_load 2>/dev/null) || return 0
    local count; count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    printf "$(t tgbot.rs.rules_title)" "$count"
    if (( count == 0 )); then
        printf "$(t tgbot.rs.no_rules)"
        return
    fi

    local probed=$(( count < RS_MAX_RULES ? count : RS_MAX_RULES ))
    local i
    for ((i = 0; i < probed; i++)); do
        local rule tag lp rh rp udp
        rule=$(echo "$rules" | jq ".[$i]")
        tag=$(echo "$rule" | jq -r '.tag')
        lp=$(echo "$rule"  | jq -r '.listen_port')
        rh=$(echo "$rule"  | jq -r '.remote_host')
        rp=$(echo "$rule"  | jq -r '.remote_port')
        udp=$(echo "$rule" | jq -r 'if .udp then "TCP+UDP" else "TCP" end')

        local conns; conns=$(_rs_conn_count "$lp")
        local ok n avg jit
        read -r ok n avg jit <<< "$(_rs_tcp_probe "$rh" "$rp")"

        local status lat_str
        if (( ok == 0 )); then
            status="$(t tgbot.rs.status_unreachable)"
            lat_str="$(t tgbot.rs.lat_fail "$n" "$n")"
        else
            if (( ok < n )); then
                status="$(t tgbot.rs.status_loss)"
            elif (( avg < 100 )); then
                status="$(t tgbot.rs.status_good)"
            elif (( avg < 250 )); then
                status="$(t tgbot.rs.status_ok)"
            else
                status="$(t tgbot.rs.status_slow)"
            fi
            lat_str="$(t tgbot.rs.lat_ok "$avg" "$jit" "$ok" "$n")"
        fi
        printf "$(t tgbot.rs.rule_line)" "$tag" "$lp" "$rh" "$rp" "$udp"
        printf '%s · %s\n' "$status" "$lat_str"
        printf "$(t tgbot.rs.current_conn)" "$conns"
    done
    (( count > probed )) && printf "$(t tgbot.rs.skipped)" $(( count - probed ))
    return 0
}

# ── 组装 ──────────────────────────────────────────────────────────────────────
rs_build_report() {
    local now host_ip
    now=$(date '+%Y-%m-%d %H:%M:%S')
    host_ip=$(get_ipv4 2>/dev/null || echo "?")

    local body="" part section
    for section in _rs_section_service _rs_section_resources_and_net _rs_section_rules; do
        part=$("$section" 2>/dev/null) || part=""
        [[ -n "$part" ]] && body="${body}${part}\n\n"
    done

    printf "$(t tgbot.rs.report)" "$host_ip" "$now" "$body"
}

# 推送给所有管理员（走 notify.sh，Bot 未配置时静默跳过）
rs_send_report() {
    source "$(dirname "${BASH_SOURCE[0]}")/notify.sh" 2>/dev/null || return 0
    declare -f tg_notify_admins &>/dev/null || return 0
    tg_notify_admins "$(rs_build_report)"
}
