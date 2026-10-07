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

# /usr/local/bin first: PSM's cores live there, and so does the jq it installs
# where the distro's is too old (ensure_modern_jq). cron and some systemd
# units run PSM with a PATH that lacks it or puts it last.
PATH="/usr/local/bin:${PATH}"

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
        alpine)
            PKG_MGR="apk" ;;
        ubuntu|debian|raspbian)
            PKG_MGR="apt-get" ;;
        centos|rhel|fedora|rocky|almalinux|ol|amzn)
            PKG_MGR="yum" ;;
        *)
            # fallback: check ID_LIKE (e.g. "rhel centos fedora")
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) PKG_MGR="apt-get" ;;
                *rhel*|*centos*|*fedora*) PKG_MGR="yum" ;;
                *alpine*) PKG_MGR="apk" ;;
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
        apk)     apk add --no-cache "$@" ;;
    esac
}

pkg_update() {
    detect_os
    case "$PKG_MGR" in
        apt-get) apt-get update -qq ;;
        yum)     "$(_rhel_pkg_cmd)" makecache -q 2>/dev/null || "$(_rhel_pkg_cmd)" makecache ;;
        # `apk add --no-cache` refreshes its own index, so no separate cache
        # update (and no stale index left in an Alpine image) is needed.
        apk)     : ;;
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
    [[ "$rhel_ver" =~ ^[0-9]+$ ]] || rhel_ver="${OS_VERSION:-}"; rhel_ver="${rhel_ver%%.*}"
    [[ "$rhel_ver" =~ ^[0-9]+$ ]] || { log_warn "$(t common.epel.amzn_unsupported)"; return 1; }

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

# ── jq 1.7 or newer ──────────────────────────────────────────────────────────
# jq 1.6 (the EL8 / EL9 package) exits 0 for `jq -e` on empty input, where 1.7
# exits 4, and PSM branches on `jq -e` in many places whose input can be empty
# (an outbound that is not there, an empty store). On such a host PSM installs
# the official static jq, checked against the release's sha256sum.txt, into
# /usr/local/bin, which is first on PATH for everything PSM runs.
PSM_JQ_VERSION="1.8.1"

_jq_is_modern() {   # [jq binary]
    local v; v=$("${1:-jq}" --version 2>/dev/null) || return 1
    [[ "${v#jq-}" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > 1 || BASH_REMATCH[2] >= 7 ))
}

ensure_modern_jq() {
    _jq_is_modern && return 0
    local arch dir="/usr/local/bin" base sums
    case "$(uname -m)" in
        x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l|armv7) arch=armhf ;;
        *) log_warn "$(t common.jq.old "$(jq --version 2>/dev/null)")"; return 0 ;;
    esac
    base="https://github.com/jqlang/jq/releases/download/jq-${PSM_JQ_VERSION}"
    mkdir -p "$dir"
    if curl "${PSM_DL[@]}" -fsSL -o "$dir/.jq.new" "$base/jq-linux-${arch}" \
        && sums=$(curl "${PSM_DL[@]}" -fsSL "$base/sha256sum.txt") \
        && [[ "$(sha256sum "$dir/.jq.new" | awk '{print $1}')" == \
              "$(awk -v f="jq-linux-${arch}" '$2 == f {print $1}' <<<"$sums")" ]] \
        && chmod 755 "$dir/.jq.new" && _jq_is_modern "$dir/.jq.new"; then
        mv -f "$dir/.jq.new" "$dir/jq"
        hash -r
        log_ok "$(t common.jq.upgraded "$("$dir/jq" --version)")"
    else
        rm -f "$dir/.jq.new"
        log_warn "$(t common.jq.old "$(jq --version 2>/dev/null)")"
    fi
    return 0
}

# ── Downloads ────────────────────────────────────────────────────────────────
# GitHub (and the other hosts PSM downloads from) now and then answers 500 or
# times out for a moment, and one such answer used to fail a whole install.
# Every download of a core, a tool, an installer or a data file passes these:
# curl retries timeouts and HTTP 408, 429, 500, 502, 503 and 504 five times,
# backing off 1, 2, 4, 8 and 16 s (about 30 s: GitHub has answered 504 for
# longer than 15 s in CI), and truncates a partly written -o file before it
# does. No --retry-delay: a fixed delay would turn the backoff off.
# bootstrap.sh spells the same flags out: it runs before this file exists.
PSM_DL=(--retry 5 --connect-timeout 15)

# ── PSM's own version ────────────────────────────────────────────────────────
# PSM has no release numbers: its version is the date and commit of the checkout.
psm_version() {
    local v
    v=$(git -C "${PSM_ROOT:-/opt/psm}" log -1 --format='%cs %h' 2>/dev/null || true)
    printf '%s\n' "${v:-unknown}"
}

# ── Latest release of a GitHub project ───────────────────────────────────────
# The /releases/latest redirect comes first: api.github.com allows 60 requests
# an hour per IP without a token, which a few installs behind one address use
# up, and every core install then fell back to an old pinned version (sing-box
# 1.13 cannot run Snell or gecko nodes). The redirect is not rate limited; it
# is followed to the end (apernet/hysteria now redirects to HyNetworks/hysteria)
# and URL-encoded tags such as app%2Fv2.6.1 are decoded. The API is the second
# try; callers keep their pinned fallback for when both fail.
gh_latest_tag() {   # <owner/repo>
    local url tag=""
    url=$(curl "${PSM_DL[@]}" -fsSIL --max-time 15 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$1/releases/latest" 2>/dev/null || true)
    if [[ "$url" == */releases/tag/* ]]; then
        tag=${url##*/releases/tag/}; tag=${tag//%2F//}; tag=${tag//%2f//}
    fi
    [[ -n "$tag" ]] || tag=$(curl "${PSM_DL[@]}" -fsSL --max-time 15 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true)
    printf '%s' "$tag"
}

# ── Slim checkout of PSM itself ──────────────────────────────────────────────
# A server needs the scripts, not the READMEs, screenshots, CI files and tests.
# Sparse checkout keeps those out of $PSM_ROOT; the partial-clone filter keeps
# later pulls from downloading their contents at all. An older full clone is
# converted in place. Idempotent. bootstrap.sh has a copy (_psm_slim) for the
# first clone, before this file exists: keep the two in step
# (tests/integration/slim.sh compares them).
psm_repo_slim() {   # [repo dir]
    local d="${1:-$PSM_ROOT}" want
    [[ -d "$d/.git" ]] || return 0
    want=$(printf '%s\n' '/*' '!/README*.md' '!/.github/' '!/tests/')
    if [[ "$(git -C "$d" config --get core.sparseCheckout || true)" != true \
          || "$(cat "$d/.git/info/sparse-checkout" 2>/dev/null)" != "$want" ]]; then
        mkdir -p "$d/.git/info"
        printf '%s\n' "$want" > "$d/.git/info/sparse-checkout"
        git -C "$d" config core.sparseCheckout true
        git -C "$d" read-tree -mu HEAD || return 1
    fi
    if [[ -z "$(git -C "$d" config --get remote.origin.promisor || true)" ]]; then
        git -C "$d" config remote.origin.promisor true
        git -C "$d" config remote.origin.partialclonefilter blob:none
        # git before 2.24 knows the promisor remote only from this extension,
        # and takes the filter for later fetches from core.partialCloneFilter
        git -C "$d" config core.repositoryformatversion 1
        git -C "$d" config extensions.partialClone origin
        git -C "$d" config core.partialCloneFilter blob:none
    fi
}

# ── Tables ───────────────────────────────────────────────────────────────────
# Aligns tab-separated rows into columns. Not `column -t`: a minimal Debian
# has no bsdextrautils, and lists piped through it came out empty there.
psm_table() {
    awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
                   if (NF > nf) nf = NF }
                 END { for (r = 1; r <= NR; r++) { line = ""
                           for (i = 1; i <= nf; i++) line = line sprintf("%-" w[i] "s", c[r, i]) (i < nf ? "  " : "")
                           print line } }'
}

# ── Cron daemon (for /etc/cron.d drop-ins) ────────────────────────────────────
# Debian minimal / RHEL-family minimal installs may have no cron daemon at all
# (RHEL ships it as "cronie"), in which case /etc/cron.d/psm-* files are never
# executed. Install + enable the distro's daemon before relying on them.
ensure_cron() {
    detect_os
    if [[ "$PKG_MGR" == "apk" ]]; then
        # Alpine's default busybox crond never reads /etc/cron.d. cronie does,
        # and it also runs /etc/crontabs/root (acme.sh's renewal entry), so it
        # replaces busybox crond outright instead of running next to it.
        svc_is_active cronie && return 0
        log_step "$(t common.cron.installing)"
        pkg_install cronie &>/dev/null || true
        svc_stop crond &>/dev/null || true
        svc_disable crond || true
        if _svc_enable_now cronie; then
            log_ok "$(t common.cron.enabled cronie)"
            return 0
        fi
        log_warn "$(t common.cron.failed)"
        return 1
    fi
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
        if _svc_enable_now "$svc"; then
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

# musl libc (Alpine). Release binaries linked against glibc cannot exec there
# ("required file not found"), so downloaders pick a -musl/static build.
is_musl() { compgen -G '/lib/ld-musl-*.so.1' >/dev/null; }

# ── Network ───────────────────────────────────────────────────────────────────
get_ipv4() {
    # the last resort is the source address of the default route: iproute2
    # prints "1.0.0.0 via GW dev IF src ADDR uid 0", so the field after "src"
    curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null \
        || ip -4 route get 1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

get_ipv6() {
    curl -s6 --max-time 5 https://api6.ipify.org 2>/dev/null
}

has_ipv6() { [[ -n "$(get_ipv6)" ]]; }

# ── Service helpers ───────────────────────────────────────────────────────────
# Two init systems are supported: systemd (Debian/Ubuntu/RHEL family) and
# OpenRC (Alpine). /run/systemd/system is systemd's own "booted with systemd"
# marker (what sd_booted() checks). The answer is cached: these helpers run in
# loops, and it cannot change while PSM is running.
_psm_detect_init() {
    [[ -n "${_PSM_INIT:-}" ]] && return 0
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        _PSM_INIT=systemd
    elif command -v openrc-run &>/dev/null && command -v rc-service &>/dev/null; then
        _PSM_INIT=openrc
    else
        _PSM_INIT=none
    fi
}
_uses_systemd() { _psm_detect_init; [[ "$_PSM_INIT" == "systemd" ]]; }
_uses_openrc()  { _psm_detect_init; [[ "$_PSM_INIT" == "openrc" ]]; }

_svc_enable_now() {
    local svc="$1"
    if _uses_systemd; then
        systemctl enable --now "$svc" &>/dev/null
    elif _uses_openrc; then
        [[ -x "/etc/init.d/${svc}" ]] || return 1
        rc-update add "$svc" default &>/dev/null || true
        rc-service "$svc" start &>/dev/null
    else
        return 1
    fi
}
# Neither systemd nor OpenRC (a container started without an init): said
# once, plainly, instead of "rc-service: command not found" from every call.
_svc_no_init() {
    _uses_openrc && return 1
    [[ -n "${_PSM_NO_INIT_SAID:-}" ]] || { log_error "$(t common.err.need_init "$1")"; _PSM_NO_INIT_SAID=1; }
    return 0
}
svc_enable() {
    if _uses_systemd; then systemctl enable "$1" --quiet 2>/dev/null
    elif _svc_no_init "$1"; then return 1
    else rc-update add "$1" default &>/dev/null; fi
}
svc_disable() {
    if _uses_systemd; then systemctl disable "$1" --quiet 2>/dev/null
    elif _svc_no_init "$1"; then return 1
    else rc-update del "$1" default &>/dev/null; fi
}
svc_start()   { if _uses_systemd; then systemctl start "$1"; elif _svc_no_init "$1"; then return 1; else rc-service "$1" start; fi; }
svc_stop()    { if _uses_systemd; then systemctl stop  "$1"; elif _svc_no_init "$1"; then return 1; else rc-service "$1" stop;  fi; }
# reset-failed first: every node change restarts the core, and systemd's default
# start limit (5 starts / 10 s) otherwise locks the unit into "start-limit-hit"
# after a handful of quick changes (measured with `psm node add` in a loop) —
# every later change then fails although the config is valid.
svc_restart() {
    if _uses_systemd; then systemctl reset-failed "$1" 2>/dev/null; systemctl restart "$1"
    elif _svc_no_init "$1"; then return 1
    else rc-service "$1" restart; fi
}
svc_reload() {
    if _uses_systemd; then systemctl reload "$1" 2>/dev/null || systemctl restart "$1"
    elif _svc_no_init "$1"; then return 1
    else rc-service "$1" reload 2>/dev/null || rc-service "$1" restart; fi
}
svc_status() {
    if _uses_systemd; then systemctl status "$1" --no-pager -l
    elif _svc_no_init "$1"; then return 1
    else rc-service "$1" status; fi
}
svc_is_active() {
    if _uses_systemd; then systemctl is-active --quiet "$1"; return; fi
    rc-service "$1" status &>/dev/null || return 1
    # supervise-daemon keeps reporting "started" for as long as it is retrying a
    # child that dies on start (measured: >20s of "started" with no child). Its
    # pidfile holds the supervisor, not the service, so require a live child.
    # Distro daemons (nginx, cron …) are not supervised and pass straight through.
    local sup; sup=$(cat "/run/$1.pid" 2>/dev/null) || return 0
    [[ "$(cat "/proc/${sup}/comm" 2>/dev/null)" == supervise-daemo* ]] || return 0
    pgrep -P "$sup" >/dev/null 2>&1
}
# Enabled = starts at boot (systemd: is-enabled; OpenRC: in the default runlevel).
svc_is_enabled() {
    if _uses_systemd; then systemctl is-enabled --quiet "$1" 2>/dev/null
    else [[ -e "/etc/runlevels/default/$1" ]]; fi
}
# Exists = the init system knows the service (a unit is loaded / an init script is present).
svc_exists() {
    if _uses_systemd; then [[ "$(systemctl show "$1" --property=LoadState --value 2>/dev/null)" == "loaded" ]]
    else [[ -x "/etc/init.d/$1" ]]; fi
}
svc_daemon_reload() {
    if _uses_systemd; then systemctl daemon-reload || true; fi
    return 0
}

# OpenRC has no journal: services written by psm_write_openrc_service send
# stdout+stderr here instead, and svc_logs / svc_log_tail read it back.
_svc_log_file() { printf '/var/log/psm/%s.log' "$1"; }

# Write an OpenRC service for a PSM-managed daemon (the OpenRC counterpart of
# the systemd units the modules write). command_args is one string because
# openrc-run word-splits it itself.
psm_write_openrc_service() {
    # [env_file]：可选，存在时整份导出给守护进程（systemd 的 EnvironmentFile=- 同义）
    # [run_as] [pre_cmd]：以非 root 用户运行（附 bind/net_admin 两项能力）；pre_cmd
    # 在 start_pre 里以 root 执行（lib/coreperm.sh 修权限）。supervise-daemon 在降权
    # 之后才打开 output_log，所以日志文件要先建好、归该用户所有。
    local name="$1" description="$2" command="$3" command_args="$4" env_file="${5:-}" env_line=""
    local run_as="${6:-}" pre_cmd="${7:-}" user_lines="command_user=\"root\"" log_line=""
    _uses_openrc || { log_error "$(t common.err.need_init "$name")"; return 1; }
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { log_error "psm_write_openrc_service: bad name: $name"; return 1; }
    local v
    for v in "$description" "$command" "$command_args" "$env_file" "$run_as"; do
        [[ "$v" != *[\"\`\$\\]* && "$v" != *$'\n'* ]] \
            || { log_error "psm_write_openrc_service: a value would break the script's quoting: $v"; return 1; }
    done
    [[ -n "$env_file" ]] && env_line="[ -f \"${env_file}\" ] && { set -a; . \"${env_file}\"; set +a; }"
    if [[ -n "$run_as" ]]; then
        user_lines="command_user=\"${run_as}:${run_as}\""$'\n'"capabilities=\"^cap_net_bind_service,^cap_net_admin\""
        log_line="checkpath -f -o ${run_as}:${run_as} -m 0640 $(_svc_log_file "$name")"
    fi
    cat > "/etc/init.d/${name}" <<EOF
#!/sbin/openrc-run
# Managed by PSM
description="${description}"
command="${command}"
command_args="${command_args}"
${user_lines}
pidfile="/run/${name}.pid"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay 5"
output_log="$(_svc_log_file "$name")"
error_log="$(_svc_log_file "$name")"
rc_ulimit="-n 1048576"
# Append, never replace: openrc-run puts its own helpers (checkpath, einfo, …) on PATH.
export PATH="\${PATH}:/usr/local/sbin:/usr/local/bin"
${env_line}

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 /var/log/psm
    ${log_line}
    ${pre_cmd}
}
EOF
    chmod 755 "/etc/init.d/${name}"
}

psm_remove_openrc_service() {
    local name="$1"
    _uses_openrc || return 0
    svc_stop "$name" &>/dev/null || true
    svc_disable "$name" &>/dev/null || true
    rm -f "/etc/init.d/${name}" "$(_svc_log_file "$name")"
}

svc_logs() {
    local name="$1" file
    if _uses_systemd; then
        journalctl -u "$name" -f --no-pager
        return
    fi
    file=$(_svc_log_file "$name")
    if [[ -f "$file" ]]; then
        tail -n 50 -F "$file"
    else
        log_warn "$(t common.svc.no_log "$name" "$file")"
        return 1
    fi
}

# Last <n> log lines of a service, non-following (for error reports).
svc_log_tail() {
    local name="$1" n="${2:-15}"
    if _uses_systemd; then
        journalctl -u "$name" -n "$n" --no-pager 2>/dev/null || true
    else
        tail -n "$n" "$(_svc_log_file "$name")" 2>/dev/null || true
    fi
}

# ── Periodic jobs without systemd timers ─────────────────────────────────────
# The modules keep their systemd timers as-is; on OpenRC the same manager.sh
# entry point runs from an /etc/cron.d drop-in instead (see ensure_cron).
psm_cron_set() {
    local name="$1" spec="$2" args="$3"
    # the file name is ours to pick and the job is one line: nothing that could
    # leave /etc/cron.d or start a second line
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { log_error "psm_cron_set: bad name: $name"; return 1; }
    [[ "$spec$args" != *$'\n'* && "$spec$args" != *$'\r'* ]] || { log_error "psm_cron_set: a job is one line"; return 1; }
    ensure_cron || true
    mkdir -p /etc/cron.d
    cat > "/etc/cron.d/${name}" <<EOF
# Managed by PSM
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${spec} root ${PSM_ROOT}/manager.sh ${args} >/dev/null 2>&1
EOF
    chmod 644 "/etc/cron.d/${name}"
}
psm_cron_remove() { rm -f "/etc/cron.d/$1"; }
psm_cron_active() { [[ -f "/etc/cron.d/$1" ]]; }

# ── Firewall persistence ─────────────────────────────────────────────────────
# Save the live iptables rules so they survive a reboot:
#   Alpine      : `rc-service iptables save` → /etc/iptables/rules-save, which the
#                 iptables service loads at boot (so that service is enabled too)
#   RHEL family : /etc/sysconfig/iptables (the dir always exists there)
#   Debian      : /etc/iptables/rules.v4 (what iptables-persistent restores)
psm_iptables_persist() {
    if _uses_openrc && [[ -x /etc/init.d/iptables ]]; then
        local s
        for s in iptables ip6tables; do
            [[ -x "/etc/init.d/$s" ]] || continue
            rc-service "$s" save &>/dev/null || true
            svc_enable "$s" || true
        done
        return 0
    fi
    [[ -d /etc/sysconfig ]] || mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save  > /etc/sysconfig/iptables 2>/dev/null \
        || iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6  2>/dev/null || true
}

# ── Prompts ───────────────────────────────────────────────────────────────────
ask() {
    # ask <var_name> <prompt> [default]
    local var="$1" prompt="$2" default="${3:-}"
    local hint="" _ask_val=""
    [[ -n "$default" ]] && hint=" [${default}]"
    read -rp "$(echo -e "${CYAN}${prompt}${hint}: ${NC}")" _ask_val || true
    [[ -z "$_ask_val" && -n "$default" ]] && _ask_val="$default"
    printf -v "$var" '%s' "$_ask_val"
}

# ask_hy2_obfs_pass <var_name> <prompt>
# Hysteria2 混淆密码：默认随机 16 位；Xray 的 salamander 要求 ≥4 字节，
# 太短会让整个 Xray 起不来，三个核心统一按这个下限重问。
ask_hy2_obfs_pass() {
    local _hy2_var="$1" _hy2_prompt="$2" _hy2_pw
    while :; do
        ask _hy2_pw "$_hy2_prompt" "$(rand_str 16)"
        (( ${#_hy2_pw} >= 4 )) && break
        log_warn "$(t common.hy2.obfs_too_short)"
    done
    printf -v "$_hy2_var" '%s' "$_hy2_pw"
}

# ask_hy2_bbr_profile <var_name>: how hard a Hysteria2 server's BBR sends —
# empty (the core's default, standard), conservative or aggressive. New in all
# three cores this year (sing-box 1.14, mihomo 1.19.24, Xray v26.4.13).
ask_hy2_bbr_profile() {
    local _bbr_var="$1" _bbr_c
    echo -e "  $(t common.hy2.bbr_title)"
    echo -e "    $(t common.hy2.bbr1)"
    echo -e "    $(t common.hy2.bbr2)"
    echo -e "    $(t common.hy2.bbr3)"
    read -rp "$(echo -e "${CYAN}$(t common.hy2.ask_bbr)${NC}")" _bbr_c
    case "$_bbr_c" in
        2) printf -v "$_bbr_var" '%s' conservative ;;
        3) printf -v "$_bbr_var" '%s' aggressive ;;
        *) printf -v "$_bbr_var" '%s' '' ;;
    esac
}

# ask_hy2_pmtud <var_name>: switch off QUIC path MTU discovery (3x-ui's "Disable
# Path MTU Discovery", #7). The server stops probing for larger packets and keeps
# to small ones, which helps on paths that drop large packets. "true" or empty.
# sing-box 1.14+, Xray (every release with Hysteria2), the official server;
# mihomo has no such option.
ask_hy2_pmtud() {
    local _pm_var="$1"
    echo -e "  $(t common.hy2.pmtud_title)"
    if ask_yn "$(t common.hy2.ask_pmtud)" N; then
        printf -v "$_pm_var" '%s' true
    else
        printf -v "$_pm_var" '%s' ''
    fi
}

ask_yn() {
    # ask_yn <prompt> [Y|N]  → returns 0=yes 1=no
    local prompt="$1" default="${2:-Y}" _ask_ans=""
    local hint; [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "$(echo -e "${CYAN}${prompt} ${hint}: ${NC}")" _ask_ans || true
    [[ -z "$_ask_ans" ]] && _ask_ans="$default"
    case "$_ask_ans" in
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
    local tmp
    tmp=$(umask 077; mktemp "$PSM_STATE.XXXXXX") || return 1
    { awk -v k="$key=" 'index($0, k) != 1' "$PSM_STATE" 2>/dev/null || true
      printf '%s=%s\n' "$key" "$val"; } > "$tmp" && mv -f "$tmp" "$PSM_STATE" || { rm -f "$tmp"; return 1; }
    chmod 600 "$PSM_STATE" 2>/dev/null || true
}

# 读一个「兜底出口」状态值，未设置时回落到默认。不能直接写
# `$(state_get k || echo d)`——state_get 内部有 `|| true`，未设置时是
# 「退出码 0 + 空串」，那样写会让调用方拿到空字符串而不是默认值。
_er_route_final() {
    local v; v=$(state_get "$1")
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$2"
}

state_get() {
    local key="$1"
    # the key as text, not as a pattern; nothing (and 0) when it is not set
    awk -v k="$key=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$PSM_STATE" 2>/dev/null || true
}

# ── Random helpers ────────────────────────────────────────────────────────────
rand_port() {
    # rand_port <min> <max>
    shuf -i "${1:-10000}-${2:-60000}" -n 1
}

# 把任意字符串编码成 URL 组件（RFC 3986）。分享链接把密码放在 userinfo 里，
# 用户自定义的密码可能含 @ : / ? # & 等字符，不编码会把 URI 截断或改变含义
# （trojan://p@ss@host 会被解析成主机是 "ss@host"）。
# 用 jq @uri：jq 本就是项目硬依赖，且 node_cli.sh 里的 _node_cli_urlencode
# 用的是同一实现，两处行为保持一致。
url_encode() { jq -nr --arg v "$1" '$v | @uri'; }

rand_str() {
    # rand_str <length>
    local len="${1:-16}"
    [[ "$len" =~ ^[0-9]+$ && "$len" -gt 0 ]] || len=16

    local out=""
    if command -v openssl &>/dev/null; then
        out=$(openssl rand -hex "$(((len + 1) / 2))" 2>/dev/null) || out=""
        out=${out:0:len}
    fi

    # head exits after len bytes, which gives tr a SIGPIPE under pipefail.
    # The output is still correct, so suppress that expected non-zero status.
    # LC_ALL=C 不能省：UTF-8 locale 下 tr 读 /dev/urandom 会以
    # "Illegal byte sequence" 报错退出，结果是空串或一两个字符。
    (( ${#out} >= len )) || out=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c "$len" || true)

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
    # Alpine: a top-level stream {} from the distro in conf.d breaks PSM's
    # nginx.conf (see lib/nginx.sh). Only defined once lib/nginx.sh is loaded.
    declare -F _nginx_neutralize_toplevel_confd >/dev/null && _nginx_neutralize_toplevel_confd
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

# Accounts (lib/users.sh) go into a core's config right before it is checked,
# so every restart PSM does carries the current users.
psm_users_merge() {
    [[ -f "$LIB_DIR/users.sh" ]] || return 0
    declare -F psm_users_inject >/dev/null || source "$LIB_DIR/users.sh"
    psm_users_inject "$1"
}

xray_test_restart() {
    # xray_rebuild_from_stores runs every module's apply in a row and tests the
    # finished config once; testing each half-rebuilt intermediate would fail.
    [[ -n "${PSM_XRAY_DEFER_RESTART:-}" ]] && return 0
    # psm-core must be able to read what PSM just wrote (lib/coreperm.sh)
    source "$LIB_DIR/coreperm.sh" && psm_core_nonroot_ensure xray
    # Camouflage sites from before the h2 fallback (lib/nginx.sh); only defined
    # once a module that uses the fallback has loaded lib/nginx.sh.
    declare -F nginx_upgrade_http_camouflage >/dev/null && nginx_upgrade_http_camouflage
    psm_users_merge xray
    # The last config that passed its test and started is kept beside it; one
    # that fails either is replaced by it, and Xray started again — sing-box
    # and mihomo roll back the same way (their .prev). Before, a change Xray
    # refused stayed on disk, and the next restart of any kind took every node
    # down with it.
    local cfg="$XRAY_CFG_DIR/config.json" good="$XRAY_CFG_DIR/config.json.good" test_out
    if test_out=$("$XRAY_BIN" run -test -config "$cfg" 2>&1) \
        || test_out=$("$XRAY_BIN" -test -config "$cfg" 2>&1); then
        if svc_restart xray; then
            cp -p "$cfg" "$good" 2>/dev/null || true
            log_ok "$(t common.xray.restarted)"
            return 0
        fi
        log_error "$(t common.xray.restart_fail)"
    else
        log_error "$(t common.xray.test_fail)"
        echo "$test_out" >&2
    fi
    if [[ -f "$good" ]] && ! cmp -s "$good" "$cfg"; then
        cat "$good" > "$cfg"
        log_warn "$(t common.xray.rolled_back)"
        svc_restart xray >/dev/null 2>&1 || true
    fi
    return 1
}

# ── Dependency check ──────────────────────────────────────────────────────────
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "$(t common.err.missing_cmd "$cmd")"
    done
}

is_installed() { command -v "$1" &>/dev/null; }

# Package providing command <cmd>, where a distro names it differently.
_pkg_name() {
    case "${PKG_MGR}:$1" in
        apk:qrencode)       echo "libqrencode-tools" ;;
        apt:xz|apt-get:xz)  echo "xz-utils" ;;
        *)                  echo "$1" ;;
    esac
}

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
    detect_os
    for pkg in "${missing[@]}"; do
        pkg_install "$(_pkg_name "$pkg")" &>/dev/null && continue
        if [[ "$PKG_MGR" == "yum" && $epel_tried -eq 0 ]]; then
            epel_tried=1
            ensure_epel || true
        fi
        pkg_install "$(_pkg_name "$pkg")" &>/dev/null && continue
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

# Alpine ships busybox applets where PSM relies on GNU behaviour (date -d
# "now +1 month", mktemp --suffix, ps -C, grep -P, ss, …) and ships no zoneinfo.
# Installing the GNU userland once makes every module behave as it does on
# Debian. procps-ng was named procps before Alpine 3.19, hence the fallback.
ensure_alpine_base() {
    detect_os
    [[ "$PKG_MGR" == "apk" ]] || return 0
    log_step "$(t common.alpine.base_installing)"
    local failed=() pkg
    for pkg in bash coreutils findutils grep sed gawk procps-ng iproute2 \
               util-linux tzdata ca-certificates iptables ip6tables; do
        apk info -e "$pkg" &>/dev/null && continue
        pkg_install "$pkg" &>/dev/null && continue
        [[ "$pkg" == "procps-ng" ]] && pkg_install procps &>/dev/null && continue
        failed+=("$pkg")
    done
    (( ${#failed[@]} == 0 )) || log_warn "$(t common.pkg.install_fail "${failed[*]}")"
    return 0
}

# ── IP / domain validation ────────────────────────────────────────────────────
is_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
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

# ── ECH (Encrypted Client Hello) for sing-box / mihomo TLS nodes ──────────────
# A node with ECH carries ech_key (the server's "ECH KEYS" PEM) and ech_config
# (the base64 ECHConfigList clients need). Measured with the real cores: an
# ECH-enabled server still accepts clients that do not use ECH, so turning it
# on never breaks existing share links; it also works over QUIC (Hysteria2,
# TUIC). Share links cannot carry the config: clients get it from PSM's
# sing-box client export or `psm node export … --format ech` (mihomo ech-opts).

# psm_ech_keypair <public-name>: sets ECH_KEY_PEM and ECH_CONFIG_B64, using
# whichever of sing-box / mihomo is installed.
psm_ech_keypair() {
    local name="$1" out sb="${SB_BIN:-${SINGBOX_BIN:-/usr/local/bin/sing-box}}" mh="${MH_BIN:-${MIHOMO_BIN:-/usr/local/bin/mihomo}}"
    ECH_KEY_PEM=""; ECH_CONFIG_B64=""
    if [[ -x "$sb" ]] && out=$("$sb" generate ech-keypair "$name" 2>/dev/null); then
        ECH_KEY_PEM=$(sed -n '/BEGIN ECH KEYS/,/END ECH KEYS/p' <<<"$out")
        ECH_CONFIG_B64=$(sed -n '/BEGIN ECH CONFIGS/,/END ECH CONFIGS/p' <<<"$out" | grep -v -- '-----' | tr -d '\n')
    elif [[ -x "$mh" ]] && out=$("$mh" generate ech-keypair "$name" 2>/dev/null); then
        # mihomo prints "Config: <base64>" then "Key: -----BEGIN ECH KEYS-----" …
        ECH_CONFIG_B64=$(sed -n 's/^Config: *//p' <<<"$out" | head -1)
        ECH_KEY_PEM=$(sed -e 's/^Key: *//' <<<"$out" | sed -n '/BEGIN ECH KEYS/,/END ECH KEYS/p')
    fi
    [[ -n "$ECH_KEY_PEM" && -n "$ECH_CONFIG_B64" ]]
}

# ECH config as the PEM block sing-box clients take (tls.ech.config lines)
psm_ech_config_pem() {
    printf -- '-----BEGIN ECH CONFIGS-----\n%s\n-----END ECH CONFIGS-----\n' "$(fold -w 64 <<<"$1")"
}

# Builder wrappers: stdin is the inbound/listener JSON, $1 the node JSON.
_sb_ech_merge() {
    jq --argjson n "$1" 'if ($n.ech_key // "") != ""
        then .tls.ech = { enabled: true, key: ($n.ech_key | split("\n") | map(select(length > 0))) }
        else . end'
}
_mh_ech_merge() {
    jq --argjson n "$1" 'if ($n.ech_key // "") != "" then ."ech-key" = $n.ech_key else . end'
}

# ── Certificate pinning for self-signed TLS nodes ────────────────────────────
# A node with insecure = 1 has a certificate no CA vouches for (PSM signed it,
# or the user brought a self-signed one). Its exports used to tell clients to
# skip verification, but Xray refuses "allowInsecure" outright since
# 2026-06-01 (v26.6.2 deleted the field), and v2rayN, v2rayNG, Happ … no
# longer pass it on: they pin the certificate given in the link instead (pcs =
# pinnedPeerCertSha256, hysteria2:// pinSHA256). So every export of such a node
# carries the pin next to the old flag: clients that know the pin check the one
# certificate, the others keep skipping verification as before.

# psm_cert_sha256 <cert file>: SHA-256 of its first (leaf) certificate, DER,
# as 64 lowercase hex digits — what pcs, pinSHA256, mihomo's fingerprint,
# Surge, Quantumult X and Loon take.
psm_cert_sha256() {
    [[ -r "${1:-}" ]] || return 1
    local fp
    fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null) || return 1
    fp=${fp#*=}; fp=${fp//:/}
    [[ "$fp" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s' "${fp,,}"
}

# psm_cert_spki_sha256 <cert file>: SHA-256 of its public key (SPKI, DER) in
# base64 — sing-box's certificate_public_key_sha256 (1.13+).
psm_cert_spki_sha256() {
    [[ -r "${1:-}" ]] || return 1
    local h
    h=$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null) || return 1
    [[ ${#h} -eq 44 ]] || return 1
    printf '%s' "$h"
}

# psm_node_pins <node json>: {"sha256": hex, "spki": base64} for a node whose
# certificate is self-signed (insecure = 1 and cert_path readable), else {}.
# The export builders merge it into the node (._pin) — jq cannot hash files.
psm_node_pins() {
    local n="$1" cp crt spki
    [[ "$(printf '%s' "$n" | jq -r '(.insecure // 0) | tostring')" =~ ^(1|true)$ ]] || { printf '{}'; return 0; }
    cp=$(printf '%s' "$n" | jq -r '.cert_path // ""')
    crt=$(psm_cert_sha256 "$cp") || { printf '{}'; return 0; }
    spki=$(psm_cert_spki_sha256 "$cp") || spki=""
    jq -cn --arg c "$crt" --arg s "$spki" '{sha256: $c} + (if $s == "" then {} else {spki: $s} end)'
}

# psm_node_with_pins <node json>: the node with ._pin set (see psm_node_pins)
psm_node_with_pins() {
    printf '%s' "$1" | jq -c --argjson p "$(psm_node_pins "$1")" '._pin = $p'
}

# psm_pin_q <node json> <parameter>: "&<parameter>=<sha256>" for a
# self-signed node, for its share link (pcs, pinSHA256, hpkp); else nothing.
psm_pin_q() {
    [[ "$(printf '%s' "$1" | jq -r '(.insecure // 0) | tostring')" =~ ^(1|true)$ ]] || return 0
    local pin; pin=$(psm_cert_sha256 "$(printf '%s' "$1" | jq -r '.cert_path // ""')") || return 0
    printf '&%s=%s' "$2" "$pin"
}

# psm_pin_yaml <node json>: "    fingerprint: <sha256>" and a newline for a
# self-signed node, to go into a Clash proxy the menus print; else nothing.
psm_pin_yaml() {
    local q; q=$(psm_pin_q "$1" fingerprint)
    [[ -n "$q" ]] && printf '    fingerprint: %s\n' "${q#&fingerprint=}"
    return 0
}

# psm_tcp_listening <port>: something listens on that TCP port (read from
# /proc, so it needs neither ss nor netstat).
psm_tcp_listening() {
    local hex; hex=$(printf '%04X' "$1")
    awk -v p=":${hex}\$" '$4 == "0A" && toupper($2) ~ p { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# Free TCP port on loopback for throwaway listeners (probes).
_psm_free_port() {
    local p i
    for i in $(seq 1 50); do
        p=$(( RANDOM % 20000 + 40000 ))
        psm_tcp_listening "$p" || { printf '%s' "$p"; return 0; }
    done
    return 1
}

# Real-core REALITY probe. The openssl checks in reality_validate_dest cannot
# tell whether a target actually works with REALITY: measured, www.microsoft.com
# passes all of them, yet an Xray REALITY node pointed at it never completes a
# handshake. Start a throwaway server + client of the same core on loopback and
# push one HTTPS request to the target through the tunnel.
# Returns 0 = works, 1 = handshake/tunnel failed (REALITY_PROBE_REASON),
# 2 = not tested (core or curl missing) — callers treat 2 as unknown, not bad.
reality_probe_core() {
    local core="$1" dest="$2" sni="$3" bin
    REALITY_PROBE_REASON=""
    case "$core" in
        xray)     bin="${XRAY_BIN:-/usr/local/bin/xray}" ;;
        sing-box) bin="${SB_BIN:-/usr/local/bin/sing-box}" ;;
        mihomo)   bin="${MH_BIN:-/usr/local/bin/mihomo}" ;;
        *) REALITY_PROBE_REASON="bad_core"; return 2 ;;
    esac
    [[ -x "$bin" ]] || { REALITY_PROBE_REASON="no_core"; return 2; }
    command -v curl >/dev/null 2>&1 || { REALITY_PROBE_REASON="no_curl"; return 2; }

    local host port
    if [[ "$dest" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    else
        host="${dest%:*}"; port="${dest##*:}"
    fi
    [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || { REALITY_PROBE_REASON="bad_dest"; return 1; }

    local dir sp cp uuid keys priv pub
    dir=$(mktemp -d) || { REALITY_PROBE_REASON="tmp_failed"; return 2; }
    if ! sp=$(_psm_free_port) || ! cp=$(_psm_free_port); then
        rm -rf "$dir"; REALITY_PROBE_REASON="no_port"; return 2
    fi
    [[ "$sp" == "$cp" ]] && cp=$(( sp + 1 ))
    uuid=$(uuid_gen) && [[ -n "$uuid" ]] || { rm -rf "$dir"; REALITY_PROBE_REASON="uuid_failed"; return 2; }
    case "$core" in
        xray) keys=$("$bin" x25519 2>/dev/null) ;;
        *)    keys=$("$bin" generate reality-keypair 2>/dev/null) ;;
    esac
    # Xray prints "PrivateKey:" + "Password (PublicKey):" (older: "Public key:");
    # sing-box and mihomo print "PrivateKey:" + "PublicKey:".
    priv=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$keys")
    pub=$(awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' <<<"$keys")
    [[ -n "$priv" && -n "$pub" ]] || { rm -rf "$dir"; REALITY_PROBE_REASON="keygen_failed"; return 2; }

    local -a sargs cargs
    case "$core" in
        xray)
            jq -n --argjson p "$sp" --arg u "$uuid" --arg d "$dest" --arg sn "$sni" --arg k "$priv" '{
              log: {loglevel: "none"},
              inbounds: [{listen: "127.0.0.1", port: $p, protocol: "vless",
                settings: {clients: [{id: $u}], decryption: "none"},
                streamSettings: {network: "tcp", security: "reality",
                  realitySettings: {dest: $d, serverNames: [$sn], privateKey: $k, shortIds: [""]}}}],
              outbounds: [{protocol: "freedom"}]}' > "$dir/s.json"
            jq -n --argjson c "$cp" --argjson p "$sp" --arg u "$uuid" --arg sn "$sni" --arg k "$pub" '{
              log: {loglevel: "none"},
              inbounds: [{listen: "127.0.0.1", port: $c, protocol: "socks", settings: {udp: false}}],
              outbounds: [{protocol: "vless",
                settings: {vnext: [{address: "127.0.0.1", port: $p, users: [{id: $u, encryption: "none"}]}]},
                streamSettings: {network: "tcp", security: "reality",
                  realitySettings: {serverName: $sn, publicKey: $k, shortId: "", fingerprint: "chrome"}}}]}' > "$dir/c.json"
            sargs=(run -c "$dir/s.json"); cargs=(run -c "$dir/c.json") ;;
        sing-box)
            jq -n --argjson p "$sp" --arg u "$uuid" --arg h "$host" --argjson hp "$port" --arg sn "$sni" --arg k "$priv" '{
              log: {level: "panic"},
              inbounds: [{type: "vless", listen: "127.0.0.1", listen_port: $p, users: [{uuid: $u}],
                tls: {enabled: true, server_name: $sn,
                  reality: {enabled: true, handshake: {server: $h, server_port: $hp},
                            private_key: $k, short_id: [""]}}}],
              outbounds: [{type: "direct"}]}' > "$dir/s.json"
            jq -n --argjson c "$cp" --argjson p "$sp" --arg u "$uuid" --arg sn "$sni" --arg k "$pub" '{
              log: {level: "panic"},
              inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: $c}],
              outbounds: [{type: "vless", server: "127.0.0.1", server_port: $p, uuid: $u,
                tls: {enabled: true, server_name: $sn, utls: {enabled: true, fingerprint: "chrome"},
                  reality: {enabled: true, public_key: $k, short_id: ""}}}]}' > "$dir/c.json"
            sargs=(run -c "$dir/s.json"); cargs=(run -c "$dir/c.json") ;;
        mihomo)
            mkdir -p "$dir/s" "$dir/c"
            jq -n --argjson p "$sp" --arg u "$uuid" --arg d "$dest" --arg sn "$sni" --arg k "$priv" '{
              "log-level": "silent",
              listeners: [{name: "probe", type: "vless", listen: "127.0.0.1", port: $p,
                users: [{username: "probe", uuid: $u}],
                "reality-config": {dest: $d, "private-key": $k, "short-id": [""], "server-names": [$sn]}}],
              rules: ["MATCH,DIRECT"]}' > "$dir/s/config.yaml"
            jq -n --argjson c "$cp" --argjson p "$sp" --arg u "$uuid" --arg sn "$sni" --arg k "$pub" '{
              "log-level": "silent", "mixed-port": $c, "bind-address": "127.0.0.1", "allow-lan": false,
              proxies: [{name: "probe", type: "vless", server: "127.0.0.1", port: $p, uuid: $u,
                network: "tcp", tls: true, servername: $sn, "client-fingerprint": "chrome",
                "reality-opts": {"public-key": $k, "short-id": ""}}],
              rules: ["MATCH,probe"]}' > "$dir/c/config.yaml"
            sargs=(-d "$dir/s" -f "$dir/s/config.yaml"); cargs=(-d "$dir/c" -f "$dir/c/config.yaml") ;;
    esac

    local spid cpid code i
    "$bin" "${sargs[@]}" >"$dir/s.log" 2>&1 & spid=$!
    "$bin" "${cargs[@]}" >"$dir/c.log" 2>&1 & cpid=$!
    for i in $(seq 1 25); do
        psm_tcp_listening "$sp" && psm_tcp_listening "$cp" && break
        sleep 0.2
    done
    # One retry: a single slow response must not condemn a working target.
    for i in 1 2; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -x "socks5h://127.0.0.1:$cp" "https://${sni}/" 2>/dev/null)
        [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && break
    done
    kill "$spid" "$cpid" 2>/dev/null || true
    wait "$spid" "$cpid" 2>/dev/null || true
    rm -rf "$dir"
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && return 0
    REALITY_PROBE_REASON="handshake_failed"
    return 1
}

# Probe step for the interactive flows: returns 1 only when the probe ran and
# failed (a missing core or curl never blocks), and leaves the reason where
# each flow's failure message reads it.
reality_probe_step() {
    local rc
    log_step "$(t common.reality.probing_core "$1")"
    rc=0; reality_probe_core "$1" "$2" "$3" || rc=$?
    (( rc == 1 )) || return 0
    REALITY_DEST_REASON="core_handshake"; RWD_CHECK_REASON="core_handshake"
    log_warn "$(t common.reality.core_probe_failed "$1" "$3")"
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
        cert=$(mktemp) || { rm -f "$out"; return 1; }
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

# psm_file_replace <file> <file with the new content>: the new content takes
# the file's place atomically (a rename within its directory, never across
# file systems from /tmp), keeping the file's mode and owner.
psm_file_replace() {
    local file="$1" new="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    cat "$new" > "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -e "$file" ]]; then
        chmod "$(stat -c %a "$file" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null || true
        chown "$(stat -c %u:%g "$file" 2>/dev/null || echo 0:0)" "$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$file"
}

jq_set() {
    # jq_set <file> <jq_filter_with_value>: rewritten in place, atomically (the
    # temp file is next to it), with the file's own mode and owner
    local file="$1" filter="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    if jq "$filter" "$file" > "$tmp" && [[ -s "$tmp" ]]; then
        chmod "$(stat -c %a "$file" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null || true
        chown "$(stat -c %u:%g "$file" 2>/dev/null || echo 0:0)" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"; return 1
    fi
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
source "$LIB_DIR/i18n.sh" || { echo "PSM: cannot load $LIB_DIR/i18n.sh" >&2; exit 1; }
i18n_init
