#!/usr/bin/env bash
# common.sh — shared utilities, constants, and helpers

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
HYSTERIA_CFG="/etc/hysteria/config.yaml"
HYSTERIA_BIN="/usr/local/bin/hysteria"
ACME_HOME="/root/.acme.sh"

PSM_STATE="$CFG_DIR/psm.state"   # key=value runtime state

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "${GREEN}[信息]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[警告]${NC}  $*"; }
log_error()   { echo -e "${RED}[错误]${NC}  $*" >&2; }
log_step()    { echo -e "${CYAN}[步骤]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[完成]${NC}  $*"; }

die() { log_error "$*"; exit 1; }

# ── Privilege ─────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行此脚本。"
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
        die "不支持的操作系统"
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
            *) die "不支持的发行版：$OS_ID" ;;
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

    log_step "正在启用 EPEL 仓库..."
    case "$OS_ID" in
        amzn)
            if command -v amazon-linux-extras &>/dev/null; then
                amazon-linux-extras install -y epel 2>/dev/null && return 0   # AL2
            fi
            log_warn "Amazon Linux 2023 不支持 EPEL，部分软件包（qrencode/fail2ban 等）可能无法安装。"
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
    log_warn "EPEL 仓库启用失败，依赖 EPEL 的软件包可能装不上。"
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
    log_step "正在安装 cron 定时服务..."
    case "$PKG_MGR" in
        apt-get) pkg_install cron   2>/dev/null || true ;;
        yum)     pkg_install cronie 2>/dev/null || true ;;
    esac
    local svc
    for svc in cron crond cronie; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null \
            && systemctl enable --now "$svc" &>/dev/null; then
            log_ok "cron 服务（${svc}）已启用"
            return 0
        fi
    done
    command -v crontab &>/dev/null && return 0
    log_warn "未能安装/启动 cron 服务，/etc/cron.d 中的定时任务将不会执行。"
    return 1
}

# ── Architecture ─────────────────────────────────────────────────────────────
get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm32" ;;
        *)       die "不支持的系统架构：$(uname -m)" ;;
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
    [[ "${ans,,}" == "y" ]]
}

press_enter() { read -rp "$(echo -e "${YELLOW}按回车继续...${NC}")"; }

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
    echo -e "  ${CYAN} 0.${NC} 返回 / 退出"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}请选择: ${NC}")" MENU_CHOICE
}

# ── Template rendering ────────────────────────────────────────────────────────
render_tpl() {
    # render_tpl <template_file> <output_file> <VAR=val> ...
    local tpl="$1" out="$2"; shift 2
    [[ -f "$tpl" ]] || die "模板不存在：$tpl"
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
    LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c "$len" || true
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
            log_error "Nginx 重新加载/重启失败。"
            return 1
        }
        log_ok "Nginx 已重新加载"
    else
        log_error "Nginx 配置测试失败，已取消重新加载"
        echo "$test_out" >&2
        return 1
    fi
}

xray_test_restart() {
    local test_out
    if test_out=$("$XRAY_BIN" run -test -config "$XRAY_CFG_DIR/config.json" 2>&1) \
        || test_out=$("$XRAY_BIN" -test -config "$XRAY_CFG_DIR/config.json" 2>&1); then
        svc_restart xray && {
            log_ok "Xray 已重启"
            return 0
        }
        log_error "Xray 重启失败。"
        return 1
    fi

    log_error "Xray 配置测试失败，已取消重启"
    echo "$test_out" >&2
    return 1
}

# ── Dependency check ──────────────────────────────────────────────────────────
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "缺少必需命令：$cmd"
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

    log_step "正在安装缺少的软件包：${missing[*]}"
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
        log_ok "已安装：${missing[*]}"
    else
        # Warn but do NOT return non-zero: callers run under `set -e` and treat
        # this as best-effort; hard requirements are enforced via require_cmd.
        log_warn "以下软件包未能安装：${failed[*]}（相关功能可能受限）"
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
