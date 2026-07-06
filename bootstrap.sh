#!/usr/bin/env bash
# bootstrap.sh — JQ's PSM one-liner installer / updater
#
# First install:
#   bash <(curl -fsSL https://psm.jinqians.com)
#
# Re-run to update:
#   same command — detects existing install and does git pull only

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PSM_REPO="https://github.com/jinqians/proxy-stack.git"   # ← fill in before publishing
PSM_BRANCH="main"
PSM_DIR="/opt/psm"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()      { log_error "$*"; exit 1; }

# ── Language ──────────────────────────────────────────────────────────────────
# bootstrap runs via `curl | bash` before the repo (and lib/i18n.sh) exists, so it
# carries its own tiny zh/en map. PSM_LANG overrides; otherwise infer from the
# system locale, falling back to English (installer reach / unknown locale).
_bt_lang="${PSM_LANG:-}"
if [[ -z "$_bt_lang" ]]; then
    case "${LC_ALL:-}${LC_MESSAGES:-}${LANG:-}" in *[Zz][Hh]*) _bt_lang=zh ;; *) _bt_lang=en ;; esac
fi
bt() { [[ "$_bt_lang" == zh ]] && printf '%s' "$1" || printf '%s' "$2"; }

banner() {
    local BC='\033[96m' BB='\033[94m' WH='\033[97m' DM='\033[2m'
    local L1='     _    ___          ____    ____    __  __ '
    local L2='    | |  / _ \        |  _ \  / ___| |  \/  |'
    local L3=" _  | | | | | |       | |_) | \___ \ | |\/| |"
    local L4='| |_| | | |_| |       |  __/   ___) | | |  | |'
    local L5=' \___/   \__\_|       |_|     |____/ |_|  |_|'
    echo ""
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L1"
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L2"
    printf "  ${BOLD}${BB}%s${NC}\n"  "$L3"
    printf "  ${BOLD}${BB}%s${NC}\n"  "$L4"
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L5"
    printf "\n"
    printf "  ${BOLD}${WH}Proxy Stack Manager${NC}  ${DM}·····${NC}  ${YELLOW}◆ jinqians.com${NC}\n"
    echo ""
}

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "$(bt "请以 root 身份运行：  sudo bash <(curl -fsSL <url>)" "Please run as root:  sudo bash <(curl -fsSL <url>)")"

banner

# ── Helper: install packages via available package manager ────────────────────
_pkg_install() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y "$@"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$@"
    elif command -v yum &>/dev/null; then
        yum install -y "$@"
    else
        die "$(bt "无法自动安装软件包，请手动安装： $*" "Cannot install packages automatically. Please install manually: $*")"
    fi
}

# ── Ensure curl is available (may already be installed) ───────────────────────
if ! command -v curl &>/dev/null; then
    log_step "$(bt "正在安装 curl..." "Installing curl...")"
    _pkg_install curl
    log_ok "$(bt "curl 已安装。" "curl installed.")"
fi

# ── Install git if missing ────────────────────────────────────────────────────
if ! command -v git &>/dev/null; then
    log_step "$(bt "正在安装 git..." "Installing git...")"
    _pkg_install git
    log_ok "$(bt "git 已安装。" "git installed.")"
fi

# ── Clone or update ───────────────────────────────────────────────────────────
if [[ -d "$PSM_DIR/.git" ]]; then
    log_step "$(bt "正在更新已安装的 PSM（$PSM_DIR）..." "Updating existing PSM installation at $PSM_DIR ...")"
    git -C "$PSM_DIR" pull --ff-only
    chmod +x "$PSM_DIR"/*.sh "$PSM_DIR/lib"/*.sh 2>/dev/null || true
    log_ok "$(bt "PSM 已更新。" "PSM updated.")"

    psm_cmd_target="$(readlink -f /usr/local/bin/psm 2>/dev/null || true)"
    if [[ ! -x /usr/local/bin/psm || "$psm_cmd_target" != "$PSM_DIR/manager.sh" || ! -d "$PSM_DIR/config" ]]; then
        log_warn "$(bt "现有安装不完整，正在运行安装程序修复..." "Existing checkout is incomplete; running installer to repair it...")"
        exec bash "$PSM_DIR/install.sh"
    fi

    echo ""
    echo -e "  $(bt "运行 ${BOLD}psm${NC} 打开菜单。" "Run ${BOLD}psm${NC} to open the menu.")"
    echo ""
    exit 0
fi

log_step "$(bt "正在克隆 PSM 到 $PSM_DIR ..." "Cloning PSM to $PSM_DIR ...")"
git clone --depth=1 -b "$PSM_BRANCH" "$PSM_REPO" "$PSM_DIR"
log_ok "$(bt "仓库已下载。" "Repository downloaded.")"

# ── Hand off to the real installer ───────────────────────────────────────────
exec bash "$PSM_DIR/install.sh"
