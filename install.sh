#!/usr/bin/env bash
# install.sh — PSM first-run setup (deps only, then launches manager)

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

require_root

banner() {
    clear
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

check_requirements() {
    log_step "$(t install.checking_env)"
    detect_os
    log_info "OS: $OS_ID $OS_VERSION"
    log_info "$(t install.arch "$(uname -m)")"
    log_info "IPv4: $(get_ipv4)"
    log_info "IPv6: $(get_ipv6 || echo "$(t common.none)")"
}

install_base_packages() {
    log_step "$(t install.deps_installing)"
    pkg_update
    # RHEL 系（CentOS/Rocky/Alma/RHEL/Oracle）的 qrencode 在 EPEL——先启用，
    # 否则 dnf 的严格模式会因为一个包不可用而放弃整个事务（curl/jq 也装不上）。
    detect_os
    [[ "$PKG_MGR" == "yum" ]] && { ensure_epel || true; }
    # ensure_pkg_deps 逐个安装：任何一个包失败都不影响其余的。
    ensure_pkg_deps curl wget unzip jq openssl socat qrencode
    # 这些是 PSM 运行的硬性依赖，缺了直接失败并给出明确指引。
    require_cmd curl jq unzip openssl
    log_ok "$(t install.deps_done)"
}

setup_directories() {
    log_step "$(t install.dirs_creating)"
    mkdir -p \
        "$CFG_DIR/stream" \
        "$CFG_DIR/http" \
        "$CFG_DIR/xray" \
        "$CFG_DIR/ssl" \
        "$CFG_DIR/traffic" \
        "$BAK_DIR" \
        "$LOG_DIR" \
        "$NGINX_SSL_DIR" \
        /usr/local/share/xray \
        /var/log/xray \
        /etc/hysteria \
        /opt/psm/compose
    log_ok "$(t install.dirs_done)"
}

make_executable() {
    chmod +x "$PSM_ROOT/manager.sh" \
              "$PSM_ROOT/install.sh" \
              "$PSM_ROOT/update.sh" \
              "$PSM_ROOT/uninstall.sh" \
              "$LIB_DIR"/*.sh
}

install_symlink() {
    ln -sf "$PSM_ROOT/manager.sh" /usr/local/bin/psm
    log_ok "$(t install.cmd_created "$PSM_ROOT/manager.sh")"
}

main() {
    banner
    # 首次安装时选择界面语言（写入 state_set psm_lang，随后菜单/日志按此语言显示）。
    i18n_pick_lang
    check_requirements
    install_base_packages
    setup_directories
    make_executable
    install_symlink

    echo ""
    log_ok "$(t install.done)"
    echo ""
    exec bash "$PSM_ROOT/manager.sh"
}

main
