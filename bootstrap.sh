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
[[ $EUID -eq 0 ]] || die "Please run as root:  sudo bash <(curl -fsSL <url>)"

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
        die "Cannot install packages automatically. Please install manually: $*"
    fi
}

# ── Ensure curl is available (may already be installed) ───────────────────────
if ! command -v curl &>/dev/null; then
    log_step "Installing curl..."
    _pkg_install curl
    log_ok "curl installed."
fi

# ── Install git if missing ────────────────────────────────────────────────────
if ! command -v git &>/dev/null; then
    log_step "Installing git..."
    _pkg_install git
    log_ok "git installed."
fi

# ── Clone or update ───────────────────────────────────────────────────────────
if [[ -d "$PSM_DIR/.git" ]]; then
    log_step "Updating existing PSM installation at $PSM_DIR ..."
    git -C "$PSM_DIR" pull --ff-only
    chmod +x "$PSM_DIR"/*.sh "$PSM_DIR/lib"/*.sh 2>/dev/null || true
    log_ok "PSM updated."
    echo ""
    echo -e "  Run ${BOLD}psm${NC} to open the menu."
    echo ""
    exit 0
fi

log_step "Cloning PSM to $PSM_DIR ..."
git clone --depth=1 -b "$PSM_BRANCH" "$PSM_REPO" "$PSM_DIR"
log_ok "Repository downloaded."

# ── Hand off to the real installer ───────────────────────────────────────────
exec bash "$PSM_DIR/install.sh"
