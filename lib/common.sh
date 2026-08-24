#!/usr/bin/env bash
# common.sh — shared utilities, constants, and helpers

# ── 加载守卫 ──────────────────────────────────────────────────────────────────
# 本文件会被大量模块重复 source（每个模块头部各 source 一次，manager.sh 也先
# source）。若无守卫，每次重复 source 都会把 CFG_DIR / PSM_STATE 等路径变量重置
# 回默认值——上层（测试或自定义流程）一旦先覆盖过这些路径，随后任意模块再 source
# 本文件就会把覆盖悄悄冲掉。首次加载后置位，后续 source 直接返回，保证变量与函数
# 只初始化一次。（return 仅在被 source 时执行；首次加载因守卫未置位不会触发。）
[[ -n "${_PSM_COMMON_LOADED:-}" ]] && return 0
_PSM_COMMON_LOADED=1

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$PSM_ROOT/lib"
TPL_DIR="$PSM_ROOT/templates"
CFG_DIR="$PSM_ROOT/config"
BAK_DIR="$PSM_ROOT/backup"
LOG_DIR="$PSM_ROOT/logs"

NGINX_STREAM_DIR="/etc/nginx/stream.d"
NGINX_HTTP_DIR="/etc/nginx/conf.d"
NGINX_SSL_DIR="/etc/nginx/ssl"
XRAY_CFG_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
SINGBOX_CFG_DIR="/etc/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
MIHOMO_CFG_DIR="/etc/mihomo"
MIHOMO_BIN="/usr/local/bin/mihomo"
HYSTERIA_CFG="/etc/hysteria/config.yaml"
HYSTERIA_BIN="/usr/local/bin/hysteria"
ACME_HOME="/root/.acme.sh"

PSM_STATE="$CFG_DIR/psm.state"   # key=value runtime state

# ── Logging ───────────────────────────────────────────────────────────────────
# 全部写 stderr（不只是 log_error）。日志是给人看的诊断信息，不是函数的返回值：
# 本仓库有大量「stdout 返回一个值、中途 log_step 报进度」的函数，例如三个核心的
# 版本解析 `tag=$(_xray_resolve_tag ...)`。日志一旦落在 stdout，就会被命令替换
# 连同返回值一起吃进变量，拼出
#   https://github.com/.../download/[步骤] 正在获取最新版本...\nv26.3.27/Xray-linux-64.zip
# 这种 URL，安装直接失败。改到 stderr 后这一整类 bug 从根上不可能再发生；交互体验
# 不变（终端照样显示），`--json` 之类的机器可读输出反而更干净。
log_info()    { echo -e "${GREEN}[$(t log.info)]${NC}  $*" >&2; }
log_warn()    { echo -e "${YELLOW}[$(t log.warn)]${NC}  $*" >&2; }
log_error()   { echo -e "${RED}[$(t log.error)]${NC}  $*" >&2; }
log_step()    { echo -e "${CYAN}[$(t log.step)]${NC}  $*" >&2; }
log_ok()      { echo -e "${GREEN}[$(t log.ok)]${NC}  $*" >&2; }

die() { log_error "$*"; exit 1; }

# ── Privilege ─────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "$(t common.err.need_root)"
}

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="centos"
    else
        die "$(t common.err.unsupported_os)"
    fi

    case "$OS_ID" in
        ubuntu|debian|raspbian)
            PKG_MGR="apt-get" ;;
        centos|rhel|fedora|rocky|almalinux|ol|amzn)
            PKG_MGR="yum" ;;
        *)
            # fallback: check ID_LIKE (e.g. "rhel centos fedora")
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) PKG_MGR="apt-get" ;;
                *rhel*|*centos*|*fedora*) PKG_MGR="yum" ;;
            *) die "$(t common.err.unsupported_distro "$OS_ID")" ;;
            esac
            ;;
    esac
}

# On the RHEL family prefer dnf when present (RHEL8+/Rocky/Alma/OL8+/AL2023/
# Fedora); fall back to yum for anything older. PKG_MGR stays "yum" as the
# family marker — existing `[[ "$PKG_MGR" == "yum" ]]` checks keep working.
_rhel_pkg_cmd() { command -v dnf &>/dev/null && echo dnf || echo yum; }

pkg_install() {
    detect_os
    case "$PKG_MGR" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        yum)     "$(_rhel_pkg_cmd)" install -y "$@" ;;
    esac
}

pkg_update() {
    detect_os
    case "$PKG_MGR" in
        apt-get) apt-get update -qq ;;
        yum)     "$(_rhel_pkg_cmd)" makecache -q 2>/dev/null || "$(_rhel_pkg_cmd)" makecache ;;
    esac
}

# ── EPEL (RHEL family only) ───────────────────────────────────────────────────
# Several packages PSM needs (qrencode, fail2ban, wireguard-tools, …) live in
# EPEL on the RHEL family, and HOW to enable EPEL differs per distro:
#   CentOS/Rocky/Alma : dnf install epel-release            (in base repos)
#   Oracle Linux      : dnf install oracle-epel-release-elN (Oracle's mirror)
#   RHEL proper       : the epel-release RPM from Fedora    (needs the URL)
#   Amazon Linux 2023 : EPEL is NOT supported at all → warn and fail
#   Fedora / Debian 系 : not applicable → succeed as a no-op
# Returns 0 when EPEL is (already) enabled or not needed, 1 otherwise.
ensure_epel() {
    detect_os
    [[ "$PKG_MGR" == "yum" ]] || return 0          # Debian family: no EPEL concept
    case "$OS_ID" in fedora) return 0 ;; esac       # Fedora: everything is in base

    # Fast path: already enabled? Match EPEL anywhere in the enabled repo list —
    # the repo id differs by distro (`epel` on CentOS/Rocky/Alma, `ol9_…_EPEL`
    # on Oracle), so an anchored/exact match would miss Oracle's.
    rpm -q epel-release &>/dev/null && return 0
    "$(_rhel_pkg_cmd)" repolist enabled 2>/dev/null | grep -qi 'epel' && return 0

    local pkg_cmd rhel_ver
    pkg_cmd=$(_rhel_pkg_cmd)
    rhel_ver=$(rpm -E %rhel 2>/dev/null)
    [[ "$rhel_ver" =~ ^[0-9]+$ ]] || rhel_ver="${OS_VERSION%%.*}"

    log_step "$(t common.epel.enabling)"
    case "$OS_ID" in
        amzn)
            if command -v amazon-linux-extras &>/dev/null; then
                amazon-linux-extras install -y epel 2>/dev/null && return 0   # AL2
            fi
            log_warn "$(t common.epel.amzn_unsupported)"
            return 1
            ;;
        ol)
            "$pkg_cmd" install -y "oracle-epel-release-el${rhel_ver}" 2>/dev/null && return 0
            # Older OL or naming miss — fall through to the Fedora RPM
            "$pkg_cmd" install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm" \
                2>/dev/null && return 0
            ;;
        rhel)
            "$pkg_cmd" install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm" \
                2>/dev/null && return 0
            ;;
        *)  # centos / rocky / almalinux / stream
            "$pkg_cmd" install -y epel-release 2>/dev/null && return 0
            "$pkg_cmd" install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm" \
                2>/dev/null && return 0
            ;;
    esac
    log_warn "$(t common.epel.failed)"
    return 1
}

# ── Cron daemon (for /etc/cron.d drop-ins) ────────────────────────────────────
# Debian minimal / RHEL-family minimal installs may have no cron daemon at all
# (RHEL ships it as "cronie"), in which case /etc/cron.d/psm-* files are never
# executed. Install + enable the distro's daemon before relying on them.
ensure_cron() {
    if command -v crontab &>/dev/null \
        && { svc_is_active cron 2>/dev/null || svc_is_active crond 2>/dev/null \
             || svc_is_active cronie 2>/dev/null; }; then
        return 0
    fi
    detect_os
    log_step "$(t common.cron.installing)"
    case "$PKG_MGR" in
        apt-get) pkg_install cron   2>/dev/null || true ;;
        yum)     pkg_install cronie 2>/dev/null || true ;;
    esac
    local svc
    for svc in cron crond cronie; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null \
            && systemctl enable --now "$svc" &>/dev/null; then
            log_ok "$(t common.cron.enabled "$svc")"
            return 0
        fi
    done
    command -v crontab &>/dev/null && return 0
    log_warn "$(t common.cron.failed)"
    return 1
}

# ── Architecture ─────────────────────────────────────────────────────────────
get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm32" ;;
        *)       die "$(t common.err.unsupported_arch "$(uname -m)")" ;;
    esac
}

# ── Network ───────────────────────────────────────────────────────────────────
get_ipv4() {
    curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null \
        || ip -4 route get 1 2>/dev/null | awk '{print $NF; exit}'
}

get_ipv6() {
    curl -s6 --max-time 5 https://api6.ipify.org 2>/dev/null
}

has_ipv6() { [[ -n "$(get_ipv6)" ]]; }

# ── Service helpers ───────────────────────────────────────────────────────────
svc_enable()  { systemctl enable  "$1" --quiet 2>/dev/null; }
svc_start()   { systemctl start   "$1"; }
svc_stop()    { systemctl stop    "$1"; }
svc_restart() { systemctl restart "$1"; }
svc_reload()  { systemctl reload  "$1" 2>/dev/null || systemctl restart "$1"; }
svc_status()  { systemctl status  "$1" --no-pager -l; }
svc_is_active(){ systemctl is-active --quiet "$1"; }

# ── Prompts ───────────────────────────────────────────────────────────────────
ask() {
    # ask <var_name> <prompt> [default]
    local var="$1" prompt="$2" default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" [${default}]"
    read -rp "$(echo -e "${CYAN}${prompt}${hint}: ${NC}")" val
    [[ -z "$val" && -n "$default" ]] && val="$default"
    printf -v "$var" '%s' "$val"
}

ask_yn() {
    # ask_yn <prompt> [Y|N]  → returns 0=yes 1=no
    local prompt="$1" default="${2:-Y}"
    local hint; [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "$(echo -e "${CYAN}${prompt} ${hint}: ${NC}")" ans
    [[ -z "$ans" ]] && ans="$default"
    case "$ans" in
        [Yy]) return 0 ;;
        *)    return 1 ;;
    esac
}

press_enter() { read -rp "$(echo -e "${YELLOW}$(t common.press_enter)${NC}")"; }

# ── Menu builder ──────────────────────────────────────────────────────────────
show_menu() {
    # show_menu <title> <opt1> <opt2> ...
    local title="$1"; shift
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  $title${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"
    local i=1
    for opt in "$@"; do
        printf "  ${CYAN}%2d.${NC} %s\n" "$i" "$opt"
        ((i++))
    done
    echo -e "  ${CYAN} 0.${NC} $(t common.back_exit)"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" MENU_CHOICE
}

# ── Template rendering ────────────────────────────────────────────────────────
render_tpl() {
    # render_tpl <template_file> <output_file> <VAR=val> ...
    local tpl="$1" out="$2"; shift 2
    [[ -f "$tpl" ]] || die "$(t common.err.tpl_missing "$tpl")"
    local content; content="$(cat "$tpl")"
    for kv in "$@"; do
        local k="${kv%%=*}" v="${kv#*=}"
        content="${content//\{\{${k}\}\}/${v}}"
    done
    echo "$content" > "$out"
}

# ── State store ───────────────────────────────────────────────────────────────
state_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$PSM_STATE")"
    # psm.state holds credentials (passwords, etc.); keep it and its dir root-only
    # instead of relying on the default umask (which leaves them world-readable).
    chmod 700 "$CFG_DIR" 2>/dev/null || true
    local tmp; tmp=$(grep -v "^${key}=" "$PSM_STATE" 2>/dev/null || true)
    ( umask 077; echo "$tmp" > "$PSM_STATE" )
    echo "${key}=${val}" >> "$PSM_STATE"
    chmod 600 "$PSM_STATE" 2>/dev/null || true
}

state_get() {
    local key="$1"
    # grep returns 1 when key not found — suppress so set -e + pipefail don't kill the script
    grep "^${key}=" "$PSM_STATE" 2>/dev/null | cut -d= -f2- || true
}

# ── Random helpers ────────────────────────────────────────────────────────────
rand_port() {
    # rand_port <min> <max>
    shuf -i "${1:-10000}-${2:-60000}" -n 1
}

rand_str() {
    # rand_str <length>
    local len="${1:-16}"
    [[ "$len" =~ ^[0-9]+$ && "$len" -gt 0 ]] || len=16

    if command -v openssl &>/dev/null; then
        openssl rand -hex "$(((len + 1) / 2))" | cut -c1-"$len"
        return 0
    fi

    # head exits after len bytes, which gives tr a SIGPIPE under pipefail.
    # The output is still correct, so suppress that expected non-zero status.
    # LC_ALL=C 不能省：UTF-8 locale 下 tr 读 /dev/urandom 会以
    # "Illegal byte sequence" 报错退出，结果是空串或一两个字符。
    local out
    out=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c "$len" || true)

    # 最后一道兜底：本函数产出的是密码 / PSK / 伪装路径，长度不足绝不能悄悄放行。
    # 这条路径刻意不碰 tr（上面那条正是栽在 tr 上的），只用 od + bash 内建替换。
    if (( ${#out} < len )); then
        local hex
        hex=$(LC_ALL=C od -An -tx1 -N "$len" /dev/urandom 2>/dev/null) || hex=""
        hex=${hex//[[:space:]]/}
        out=${hex:0:len}
    fi

    # 还是拿不到就报错返回非零，让调用方（多在 set -e 下）当场中止：
    # 宁可装到一半失败，也不能生成一个空密码 / 空 PSK 的节点。
    if (( ${#out} < len )); then
        log_error "$(t common.err.rand_failed)"
        return 1
    fi
    printf '%s' "$out"
}

rand_path() {
    local suffix; suffix=$(rand_str 8)
    [[ -n "$suffix" ]] || suffix="$(date +%s)"
    echo "/$suffix"
}

uuid_gen() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v "$XRAY_BIN" &>/dev/null; then
        "$XRAY_BIN" uuid
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"
    fi
}

# ── Config test & reload ──────────────────────────────────────────────────────
nginx_test_reload() {
    local test_out
    if test_out=$(nginx -t 2>&1); then
        svc_reload nginx || svc_restart nginx || {
            log_error "$(t common.nginx.reload_fail)"
            return 1
        }
        log_ok "$(t common.nginx.reloaded)"
    else
        log_error "$(t common.nginx.test_fail)"
        echo "$test_out" >&2
        return 1
    fi
}

xray_test_restart() {
    local test_out
    if test_out=$("$XRAY_BIN" run -test -config "$XRAY_CFG_DIR/config.json" 2>&1) \
        || test_out=$("$XRAY_BIN" -test -config "$XRAY_CFG_DIR/config.json" 2>&1); then
        svc_restart xray && {
            log_ok "$(t common.xray.restarted)"
            return 0
        }
        log_error "$(t common.xray.restart_fail)"
        return 1
    fi

    log_error "$(t common.xray.test_fail)"
    echo "$test_out" >&2
    return 1
}

# ── Dependency check ──────────────────────────────────────────────────────────
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "$(t common.err.missing_cmd "$cmd")"
    done
}

is_installed() { command -v "$1" &>/dev/null; }

ensure_pkg_deps() {
    # ensure_pkg_deps <pkg1> [pkg2] ... — install any whose binary is missing.
    # Installs ONE AT A TIME on purpose: apt/dnf abort the whole transaction if
    # a single name is unavailable (dnf strict mode), so a batch would let one
    # EPEL-only package (e.g. qrencode on Rocky/Alma) block curl/jq/everything.
    # On the RHEL family, a failed package triggers one ensure_epel + retry —
    # that's where qrencode/fail2ban/wireguard-tools etc. live on EL8/9.
    local missing=() pkg
    for pkg in "$@"; do
        command -v "$pkg" &>/dev/null || missing+=("$pkg")
    done
    (( ${#missing[@]} == 0 )) && return 0

    log_step "$(t common.pkg.installing "${missing[*]}")"
    local failed=() epel_tried=0
    for pkg in "${missing[@]}"; do
        pkg_install "$pkg" &>/dev/null && continue
        detect_os
        if [[ "$PKG_MGR" == "yum" && $epel_tried -eq 0 ]]; then
            epel_tried=1
            ensure_epel || true
        fi
        pkg_install "$pkg" &>/dev/null && continue
        failed+=("$pkg")
    done

    if (( ${#failed[@]} == 0 )); then
        log_ok "$(t common.pkg.installed "${missing[*]}")"
    else
        # Warn but do NOT return non-zero: callers run under `set -e` and treat
        # this as best-effort; hard requirements are enforced via require_cmd.
        log_warn "$(t common.pkg.install_fail "${failed[*]}")"
    fi
    return 0
}

# ── IP / domain validation ────────────────────────────────────────────────────
is_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# ── Reality camouflage-target validation (shared by all cores) ────────────────
# A Reality "dest" is the real TLS 1.3 site the server forwards the client's
# handshake to for camouflage; the client presents <sni> and expects that dest
# to serve a certificate covering it. A mismatched (sni, dest) pair installs and
# passes -test but NO client can complete the Reality handshake. These helpers
# let an add-flow vet a manually entered pair before saving the node.

# True when <dest> points at a loopback/local backend (a private camouflage site
# the server cannot SNI-cert-validate from its own vantage — e.g. Nginx's
# 127.0.0.1:8443 HTTPS site). Callers skip the advisory check for these, mirroring
# how the watchdog's _rwd_check_dest tolerates IP literals / local hosts.
reality_dest_is_local() {
    local host="$1"
    host="${host%:*}"           # strip :port  (leaves host or [ipv6])
    host="${host#[}"; host="${host%]}"
    case "$host" in
        127.*|::1|0.0.0.0|localhost|localhost.*) return 0 ;;
    esac
    return 1
}

# Advisory validator: is <dest> a usable Reality camouflage target for <sni>?
# openssl-only distillation of xray/reality_watchdog.sh's _rwd_check_dest, so
# sing-box/mihomo (which never load the watchdog) can vet a pair too. Asserts the
# four hard Reality requirements: TCP reachable + TLS 1.3 negotiated + leaf cert
# host-matches the SNI + X25519 in the negotiated group. Returns 0 on success
# (round-trip in REALITY_DEST_RTT_MS); on failure sets REALITY_DEST_REASON to a
# short code (same vocabulary as _rwd_check_dest) and returns 1. Advisory only —
# callers may proceed regardless.
reality_validate_dest() {
    local dest="$1" sni="$2"
    REALITY_DEST_REASON=""
    REALITY_DEST_RTT_MS=""
    REALITY_DEST_WARN=""

    # Parse "host:port" or "[ipv6]:port"
    local host port
    if [[ "$dest" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    elif [[ "$dest" == *:* && "$dest" != *:*:* ]]; then
        host="${dest%:*}"; port="${dest##*:}"
    else
        REALITY_DEST_REASON="bad_dest"; return 1
    fi
    [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || { REALITY_DEST_REASON="bad_dest"; return 1; }

    local connect="${host}:${port}"
    [[ "$host" == *:* ]] && connect="[${host}]:${port}"

    local out rc start_ms end_ms
    out=$(mktemp) || { REALITY_DEST_REASON="tmp_failed"; return 1; }

    start_ms=$(date +%s%3N 2>/dev/null); [[ "$start_ms" =~ ^[0-9]+$ ]] || start_ms=$(( $(date +%s) * 1000 ))
    if command -v timeout &>/dev/null; then
        timeout 8 openssl s_client -connect "$connect" -servername "$sni" \
            -tls1_3 -alpn h2,http/1.1 -showcerts </dev/null >"$out" 2>&1
        rc=$?
    else
        openssl s_client -connect "$connect" -servername "$sni" \
            -tls1_3 -alpn h2,http/1.1 -showcerts </dev/null >"$out" 2>&1
        rc=$?
    fi
    end_ms=$(date +%s%3N 2>/dev/null); [[ "$end_ms" =~ ^[0-9]+$ ]] || end_ms=$(( $(date +%s) * 1000 ))
    REALITY_DEST_RTT_MS=$(( end_ms - start_ms ))

    local reason=""
    if [[ "$rc" == "124" ]]; then
        reason="tls_timeout"
    elif grep -Eqi "connect:errno|Connection refused|No route to host|Network is unreachable|Connection timed out|Operation timed out|Operation not permitted|Name or service not known|nodename nor servname" "$out"; then
        reason="tcp_failed"
    elif grep -Eqi "protocol version|unsupported protocol|wrong version number|no protocols available|tlsv1 alert protocol version" "$out"; then
        reason="tls13_unsupported"
    elif ! grep -Eq "New, TLSv1\.3|Protocol *: TLSv1\.3|Protocol version: TLSv1\.3" "$out"; then
        reason="tls13_failed"
    else
        # Reality auth rides on X25519, so the negotiated group must contain it
        # (a hybrid like X25519MLKEM768 still counts). If openssl didn't report
        # the group (very old build), don't judge.
        local grp; grp=$(grep -Ei "Server Temp Key|Negotiated TLS1\.3 group" "$out")
        if [[ -n "$grp" ]] && ! printf '%s\n' "$grp" | grep -qi "X25519"; then
            reason="no_x25519"
        else
            local cert; cert=$(mktemp)
            awk '/-----BEGIN CERTIFICATE-----/{c=1} c{print} /-----END CERTIFICATE-----/{exit}' "$out" > "$cert"
            if ! grep -q "BEGIN CERTIFICATE" "$cert"; then
                reason="no_certificate"
            else
                local clean_sni="${sni#[}"; clean_sni="${clean_sni%]}"
                if is_ipv4 "$clean_sni" || [[ "$clean_sni" == *:* ]]; then
                    # IP-literal SNI: assert cert covers the IP only when openssl
                    # supports -checkip; otherwise we cannot judge, so accept.
                    if openssl x509 -help 2>&1 | grep -q -- "-checkip" \
                        && ! openssl x509 -in "$cert" -noout -checkip "$clean_sni" >/dev/null 2>&1; then
                        reason="sni_cert_mismatch"
                    fi
                elif openssl x509 -help 2>&1 | grep -q -- "-checkhost" \
                    && ! openssl x509 -in "$cert" -noout -checkhost "$sni" >/dev/null 2>&1; then
                    reason="sni_cert_mismatch"
                fi
            fi
            rm -f "$cert"
        fi
    fi

    rm -f "$out"
    if [[ -n "$reason" ]]; then
        REALITY_DEST_REASON="$reason"; return 1
    fi

    # 握手层面合格后，再判一次「这个 dest 是不是多租户共享前端」。属于告警而非否决：
    # 判定可能误伤，且是否接受风险由使用者决定（见 reality_dest_is_shared_frontend）。
    if reality_dest_is_shared_frontend "$host" "$port"; then
        REALITY_DEST_WARN="shared_frontend:${REALITY_DEST_SHARED_BY}"
    fi
    return 0
}

# ── Reality dest：多租户共享前端（CDN 边缘）判定 ──────────────────────────────
# Reality 会把「认证未通过」的连接原样转发给 dest 以维持伪装。若 dest 落在共享 CDN 前端
# 上，攻击者只要把 ClientHello 的 SNI 填成该 CDN 上的任意站点，就能拿本机当作通往整个
# CDN 的免费隧道 —— Xray 官方文档亦警告此点（"your server effectively becomes a port
# forwarder for Cloudflare and may be abused after scanning"）。
#
# 判定手法：用一批与 dest 无关的探针域名当 SNI 去连同一个 IP:port。单租户站点不会为
# 别人的域名出示有效证书，共享前端会。这直接测「该 IP 是否按 SNI 服务任意租户」这一
# 性质本身，不依赖 IP 段或 ASN 名单，因此对各家 CDN 一视同仁，也不会随 IP 段变动失效。
#
# 探针必须覆盖想检出的 CDN（各家边缘只服务自家租户），且不能选那些本身常被当作 dest 的
# 域名 —— 否则 dest 恰好是探针时会因跳过自身而漏判。列表可通过环境变量扩充。
# 命中时把探针域名回填到 REALITY_DEST_SHARED_BY 并返回 0。
REALITY_SHARED_FRONTEND_PROBES="${REALITY_SHARED_FRONTEND_PROBES:-cdnjs.cloudflare.com www.fastly.com www.akamai.com}"

# ── Reality 回落限速（Xray: limitFallback* / mihomo: limit-fallback-*）────────
# 只在 dest 是共享 CDN 前端时才写出来 —— 官方口径也是「迫不得已偷了 CDN 证书时才考虑」。
# 这是兜底而非解法：两个参数都是「每连接」语义，攻击者循环重连即可绕过，真正有效的是
# 换掉 dest 和 Nginx 侧的未知 SNI 黑洞。
#
# 取值权衡：after_bytes 太小 → 主动探测者拉一次完整页面就撞限速，速度突降本身成为指纹，
# 反而削弱伪装；太大 → 每条新连接都白送一份额度，等于没限。默认取 1MiB，够覆盖一次
# 正常页面加载与证书链，又不给多连接白嫖留出太大空间。
REALITY_FALLBACK_AFTER_BYTES="${REALITY_FALLBACK_AFTER_BYTES:-1048576}"        # 1 MiB
REALITY_FALLBACK_BYTES_PER_SEC="${REALITY_FALLBACK_BYTES_PER_SEC:-262144}"     # 256 KiB/s
REALITY_FALLBACK_BURST_BYTES_PER_SEC="${REALITY_FALLBACK_BURST_BYTES_PER_SEC:-1048576}"

reality_dest_is_shared_frontend() {
    local host="$1" port="${2:-443}"
    REALITY_DEST_SHARED_BY=""
    command -v openssl &>/dev/null || return 1
    # 本地伪装站不出网，不存在被当中继的问题
    reality_dest_is_local "$host" && return 1
    # 没有 -checkhost 就无法核验证书归属，宁可不判也不误报
    openssl x509 -help 2>&1 | grep -q -- "-checkhost" || return 1

    local connect="${host}:${port}"
    [[ "$host" == *:* ]] && connect="[${host}]:${port}"

    local probe out cert hit=1
    for probe in $REALITY_SHARED_FRONTEND_PROBES; do
        [[ "$probe" == "$host" ]] && continue
        out=$(mktemp) || return 1
        if command -v timeout &>/dev/null; then
            timeout 5 openssl s_client -connect "$connect" -servername "$probe" \
                </dev/null >"$out" 2>&1
        else
            openssl s_client -connect "$connect" -servername "$probe" \
                </dev/null >"$out" 2>&1
        fi
        cert=$(mktemp)
        awk '/-----BEGIN CERTIFICATE-----/{c=1} c{print} /-----END CERTIFICATE-----/{exit}' "$out" > "$cert"
        if grep -q "BEGIN CERTIFICATE" "$cert" \
            && openssl x509 -in "$cert" -noout -checkhost "$probe" >/dev/null 2>&1; then
            REALITY_DEST_SHARED_BY="$probe"
            hit=0
        fi
        rm -f "$out" "$cert"
        (( hit == 0 )) && return 0
    done
    return 1
}

# ── JSON helpers (requires jq) ────────────────────────────────────────────────
jq_get() {
    # jq_get <file> <jq_filter>
    jq -r "$2" "$1" 2>/dev/null
}

jq_set() {
    # jq_set <file> <jq_filter_with_value>
    local file="$1" filter="$2"
    local tmp; tmp=$(mktemp)
    jq "$filter" "$file" > "$tmp" && mv "$tmp" "$file"
}

# ── Auto-backup wrapper ───────────────────────────────────────────────────────
with_backup() {
    # with_backup <description> <command...>
    local desc="$1"; shift
    # source backup module if available
    [[ -f "$LIB_DIR/backup.sh" ]] && source "$LIB_DIR/backup.sh" && do_quick_backup "$desc"
    "$@"
}

# ── i18n 初始化（放在文件末尾，state_get / 路径就绪之后）──────────────────────
source "$LIB_DIR/i18n.sh"
i18n_init
