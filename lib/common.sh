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

pkg_install() {
    detect_os
    case "$PKG_MGR" in
        apt-get) apt-get install -y "$@" ;;
        yum)     yum install -y "$@" ;;
    esac
}

pkg_update() {
    detect_os
    case "$PKG_MGR" in
        apt-get) apt-get update -qq ;;
        yum)     yum makecache -q ;;
    esac
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
    local tmp; tmp=$(grep -v "^${key}=" "$PSM_STATE" 2>/dev/null || true)
    echo "$tmp" > "$PSM_STATE"
    echo "${key}=${val}" >> "$PSM_STATE"
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
    # ensure_pkg_deps <pkg1> [pkg2] ... — install any whose binary is missing
    local missing=()
    for pkg in "$@"; do
        command -v "$pkg" &>/dev/null || missing+=("$pkg")
    done
    (( ${#missing[@]} == 0 )) && return 0
    log_step "正在安装缺少的软件包：${missing[*]}"
    pkg_install "${missing[@]}" \
        && log_ok "已安装：${missing[*]}" \
        || log_warn "部分软件包可能未正确安装：${missing[*]}"
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
