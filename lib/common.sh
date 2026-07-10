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
log_info()    { echo -e "${GREEN}[$(t log.info)]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[$(t log.warn)]${NC}  $*"; }
log_error()   { echo -e "${RED}[$(t log.error)]${NC}  $*" >&2; }
log_step()    { echo -e "${CYAN}[$(t log.step)]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[$(t log.ok)]${NC}  $*"; }

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
