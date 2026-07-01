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
    log_step "正在检查系统环境..."
    detect_os
    log_info "OS: $OS_ID $OS_VERSION"
    log_info "架构: $(uname -m)"
    log_info "IPv4: $(get_ipv4)"
    log_info "IPv6: $(get_ipv6 || echo '无')"
}

install_base_packages() {
    log_step "正在安装基础依赖..."
    pkg_update
    pkg_install curl wget unzip jq openssl socat qrencode 2>/dev/null || true
    log_ok "基础依赖已安装。"
}

setup_directories() {
    log_step "正在创建 PSM 目录结构..."
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
    log_ok "目录已准备好。"
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
    log_ok "快捷命令已创建：psm → $PSM_ROOT/manager.sh"
}

main() {
    banner
    check_requirements
    install_base_packages
    setup_directories
    make_executable
    install_symlink

    echo ""
    log_ok "PSM 初始化完成，正在打开管理菜单..."
    echo ""
    exec bash "$PSM_ROOT/manager.sh"
}

main
