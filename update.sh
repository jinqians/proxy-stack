#!/usr/bin/env bash
# update.sh — PSM self-update and component upgrade

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

PSM_VERSION_FILE="$PSM_ROOT/.version"
CURRENT_VERSION=$(cat "$PSM_VERSION_FILE" 2>/dev/null || echo "dev")

psm_check_version() {
    log_info "当前 PSM 版本：$CURRENT_VERSION"
    if [[ -d "$PSM_ROOT/.git" ]]; then
        local behind
        behind=$(timeout 10 git -C "$PSM_ROOT" fetch --dry-run 2>&1 | wc -l)
        (( behind > 0 )) && log_info "上游有可用更新。" \
                         || log_info "PSM 已是最新版本。"
    else
        log_info "非 git 仓库，无法检查版本。"
    fi
}

psm_update_scripts() {
    log_step "正在备份当前脚本..."
    source "$LIB_DIR/backup.sh"
    do_quick_backup "pre-update" &>/dev/null

    log_step "正在拉取最新 PSM 脚本..."
    if [[ -d "$PSM_ROOT/.git" ]]; then
        # Discard local script changes — user data lives in /etc/psm/, not in the repo
        timeout 5 git -C "$PSM_ROOT" checkout -- . 2>/dev/null || true
        timeout 30 git -C "$PSM_ROOT" pull --ff-only \
            && log_ok "脚本已通过 git 更新。" \
            || log_error "git pull 失败或超时。"
    else
        log_warn "非 git 仓库。请重新运行安装命令以通过 git 重装。"
    fi
    # Recursively chmod — covers lib/xray/, lib/tgbot/, lib/expiry/ etc.
    find "$PSM_ROOT" -name "*.sh" -exec chmod +x {} +
}

psm_update_xray() {
    log_step "正在升级 Xray..."
    source "$LIB_DIR/xray/core.sh"
    xray_upgrade
}

psm_update_hysteria2() {
    log_step "正在升级 Hysteria2..."
    source "$LIB_DIR/hysteria2.sh"
    hy2_install
}

psm_update_nginx() {
    log_step "正在升级 Nginx..."
    source "$LIB_DIR/nginx.sh"
    nginx_upgrade
}

psm_update_geofiles() {
    log_step "正在更新地理数据文件..."
    local base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    curl -fsSL "$base/geoip.dat"   -o /usr/local/share/xray/geoip.dat
    curl -fsSL "$base/geosite.dat" -o /usr/local/share/xray/geosite.dat
    log_ok "地理数据文件已更新。"
    svc_restart xray 2>/dev/null || true
}

psm_update() {
    require_root

    echo -e "\n${BOLD}${CYAN}PSM 更新管理器${NC}\n"
    psm_check_version

    show_menu "更新选项" \
        "更新 PSM 脚本" \
        "升级 Xray-core" \
        "升级 Hysteria2" \
        "升级 Nginx" \
        "更新地理数据文件（geoip/geosite）" \
        "更新所有组件"

    case "$MENU_CHOICE" in
        1) psm_update_scripts ;;
        2) psm_update_xray ;;
        3) psm_update_hysteria2 ;;
        4) psm_update_nginx ;;
        5) psm_update_geofiles ;;
        6)
            psm_update_scripts
            psm_update_xray
            psm_update_hysteria2
            psm_update_nginx
            psm_update_geofiles
            ;;
        0) return ;;
    esac
}

# If called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    psm_update
fi
