#!/usr/bin/env bash
# update.sh — PSM self-update and component upgrade

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

PSM_VERSION_FILE="$PSM_ROOT/.version"
CURRENT_VERSION=$(cat "$PSM_VERSION_FILE" 2>/dev/null || echo "dev")

psm_check_version() {
    log_info "$(t update.current_ver "$CURRENT_VERSION")"
    if [[ -d "$PSM_ROOT/.git" ]]; then
        local behind
        behind=$(timeout 10 git -C "$PSM_ROOT" fetch --dry-run 2>&1 | wc -l)
        (( behind > 0 )) && log_info "$(t update.available)" \
                         || log_info "$(t update.uptodate)"
    else
        log_info "$(t update.not_git)"
    fi
}

psm_update_scripts() {
    log_step "$(t update.backing_up)"
    source "$LIB_DIR/backup.sh"
    do_quick_backup "pre-update" &>/dev/null

    log_step "$(t update.pulling)"
    if [[ -d "$PSM_ROOT/.git" ]]; then
        # Discard local script changes — user data lives in /etc/psm/, not in the repo
        timeout 5 git -C "$PSM_ROOT" checkout -- . 2>/dev/null || true
        timeout 30 git -C "$PSM_ROOT" pull --ff-only \
            && log_ok "$(t update.git_done)" \
            || log_error "$(t update.git_fail)"
    else
        log_warn "$(t update.not_git_reinstall)"
    fi
    # Recursively chmod — covers lib/xray/, lib/tgbot/, lib/expiry/ etc.
    find "$PSM_ROOT" -name "*.sh" -exec chmod +x {} +
}

psm_update_xray() {
    log_step "$(t update.xray)"
    source "$LIB_DIR/xray/core.sh"
    xray_upgrade
}

psm_update_singbox() {
    # 未安装则跳过：sb_upgrade 会走完整安装流程，避免「更新所有组件」意外装上第二内核
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        log_info "$(t update.singbox_not_installed)"
        return 0
    fi
    log_step "$(t update.singbox)"
    source "$LIB_DIR/singbox/core.sh"
    sb_upgrade
}

psm_update_mihomo() {
    if [[ ! -f "$MIHOMO_BIN" ]]; then
        log_info "$(t update.mihomo_not_installed)"
        return 0
    fi
    log_step "$(t update.mihomo)"
    source "$LIB_DIR/mihomo/core.sh"
    mh_upgrade
}

psm_update_hysteria2() {
    log_step "$(t update.hy2)"
    source "$LIB_DIR/hysteria2.sh"
    hy2_install
}

psm_update_nginx() {
    log_step "$(t update.nginx)"
    source "$LIB_DIR/nginx.sh"
    nginx_upgrade
}

psm_update_geofiles() {
    log_step "$(t update.geo)"
    local base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    curl -fsSL "$base/geoip.dat"   -o /usr/local/share/xray/geoip.dat
    curl -fsSL "$base/geosite.dat" -o /usr/local/share/xray/geosite.dat
    log_ok "$(t update.geo_done)"
    svc_restart xray 2>/dev/null || true
}

psm_update() {
    require_root

    echo -e "\n${BOLD}${CYAN}$(t update.header)${NC}\n"
    psm_check_version

    show_menu "$(t update.menu.title)" \
        "$(t update.menu.scripts)" \
        "$(t update.menu.xray)" \
        "$(t update.menu.singbox)" \
        "$(t update.menu.mihomo)" \
        "$(t update.menu.hy2)" \
        "$(t update.menu.nginx)" \
        "$(t update.menu.geo)" \
        "$(t update.menu.all)"

    case "$MENU_CHOICE" in
        1) psm_update_scripts ;;
        2) psm_update_xray ;;
        3) psm_update_singbox ;;
        4) psm_update_mihomo ;;
        5) psm_update_hysteria2 ;;
        6) psm_update_nginx ;;
        7) psm_update_geofiles ;;
        8)
            psm_update_scripts
            psm_update_xray
            psm_update_singbox
            psm_update_mihomo
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
