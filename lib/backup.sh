#!/usr/bin/env bash
# backup.sh — backup and restore for PSM-managed configs

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BAK_ROOT="$BAK_DIR"
MAX_BACKUPS=10

# ── Quick backup (called before modifications) ────────────────────────────────
do_quick_backup() {
    local desc="${1:-manual}"
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local name="${ts}_${desc// /_}"
    local bak="$BAK_ROOT/$name"
    mkdir -p "$bak"

    # Nginx
    [[ -d /etc/nginx ]] && cp -a /etc/nginx "$bak/nginx" 2>/dev/null

    # Xray
    [[ -d "$XRAY_CFG_DIR" ]] && cp -a "$XRAY_CFG_DIR" "$bak/xray" 2>/dev/null

    # Hysteria2
    [[ -d /etc/hysteria ]] && cp -a /etc/hysteria "$bak/hysteria" 2>/dev/null

    # PSM config state
    [[ -d "$CFG_DIR" ]] && cp -a "$CFG_DIR" "$bak/psm_config" 2>/dev/null

    # Certificates
    [[ -d "$NGINX_SSL_DIR" ]] && cp -a "$NGINX_SSL_DIR" "$bak/ssl" 2>/dev/null

    _rotate_backups
    log_ok "快速备份已保存：$bak"
    echo "$bak"
}

# ── Full backup ───────────────────────────────────────────────────────────────
do_full_backup() {
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local name="${ts}_full"
    local bak="$BAK_ROOT/$name"
    mkdir -p "$bak"

    log_step "正在创建完整备份 → $bak"

    # All PSM components
    [[ -d /etc/nginx      ]] && cp -a /etc/nginx      "$bak/nginx"
    [[ -d "$XRAY_CFG_DIR" ]] && cp -a "$XRAY_CFG_DIR" "$bak/xray"
    [[ -d /etc/hysteria   ]] && cp -a /etc/hysteria   "$bak/hysteria"
    [[ -d "$CFG_DIR"      ]] && cp -a "$CFG_DIR"      "$bak/psm_config"
    [[ -d "$NGINX_SSL_DIR" ]] && cp -a "$NGINX_SSL_DIR" "$bak/ssl"

    # Docker compose files (includes any bind-mount data dirs under them)
    [[ -d /opt/psm/compose ]] && cp -a /opt/psm/compose "$bak/docker_compose"

    # Docker named volumes (Portainer/Vaultwarden/etc. — live outside /opt/psm/compose)
    source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
        && declare -f docker_backup_volumes &>/dev/null \
        && docker_backup_volumes "$bak"

    # Compress
    local archive="$BAK_ROOT/${name}.tar.gz"
    tar -czf "$archive" -C "$BAK_ROOT" "$name" && rm -rf "$bak"
    _rotate_backups
    log_ok "完整备份：$archive"
    echo "$archive"
}

# ── Selective backup ──────────────────────────────────────────────────────────
do_selective_backup() {
    echo -e "\n  选择要备份的组件（用空格分隔多个序号）："
    echo    "  1. Nginx 配置"
    echo    "  2. Xray 配置"
    echo    "  3. Hysteria2 配置"
    echo    "  4. PSM 状态 / 节点配置"
    echo    "  5. SSL 证书"
    echo    "  6. Docker Compose 文件"
    echo    "  7. Docker 数据卷（Portainer/Vaultwarden 等应用商店应用的数据）"
    read -rp "$(echo -e "${CYAN}请选择: ${NC}")" choices

    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local bak="$BAK_ROOT/${ts}_selective"
    mkdir -p "$bak"

    for c in $choices; do
        case "$c" in
            1) [[ -d /etc/nginx        ]] && cp -a /etc/nginx      "$bak/nginx" ;;
            2) [[ -d "$XRAY_CFG_DIR"   ]] && cp -a "$XRAY_CFG_DIR" "$bak/xray" ;;
            3) [[ -d /etc/hysteria     ]] && cp -a /etc/hysteria   "$bak/hysteria" ;;
            4) [[ -d "$CFG_DIR"        ]] && cp -a "$CFG_DIR"      "$bak/psm_config" ;;
            5) [[ -d "$NGINX_SSL_DIR"  ]] && cp -a "$NGINX_SSL_DIR" "$bak/ssl" ;;
            6) [[ -d /opt/psm/compose  ]] && cp -a /opt/psm/compose "$bak/docker_compose" ;;
            7) source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
                   && declare -f docker_backup_volumes &>/dev/null \
                   && docker_backup_volumes "$bak" ;;
        esac
    done

    local archive="$BAK_ROOT/${ts}_selective.tar.gz"
    tar -czf "$archive" -C "$BAK_ROOT" "${ts}_selective" && rm -rf "$bak"
    log_ok "选择性备份：$archive"
}

# ── List backups ──────────────────────────────────────────────────────────────
list_backups() {
    echo -e "\n${BOLD}可用备份：${NC}"
    local i=1
    find "$BAK_ROOT" -maxdepth 1 \( -name "*.tar.gz" -o -type d \) \
        | sort -r | while read -r f; do
            local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
            printf "  %2d. %-50s %s\n" "$i" "$(basename "$f")" "$size"
            ((i++))
          done
}

# ── Restore ───────────────────────────────────────────────────────────────────
do_restore() {
    list_backups
    local archive; ask archive "备份文件名（从上方列表选择）"
    local full_path="$BAK_ROOT/$archive"
    [[ -f "$full_path" ]] || { log_error "未找到：$full_path"; return 1; }

    ask_yn "是否从 $archive 恢复？（当前配置将被覆盖）" N || return 0

    local tmp_dir; tmp_dir=$(mktemp -d)
    tar -xzf "$full_path" -C "$tmp_dir"
    local bak_dir; bak_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)

    echo -e "\n  选择要恢复的组件："
    echo    "  1. Nginx 配置"
    echo    "  2. Xray 配置"
    echo    "  3. Hysteria2 配置"
    echo    "  4. PSM 状态 / 节点配置"
    echo    "  5. SSL 证书"
    echo    "  6. Docker Compose 项目 / 数据卷"
    echo    "  7. 全部（完整恢复）"
    read -rp "$(echo -e "${CYAN}请选择 [7]: ${NC}")" rc; rc="${rc:-7}"

    _stop_services

    for c in $rc; do
        case "$c" in
            1|7)
                [[ -d "$bak_dir/nginx"      ]] && { rm -rf /etc/nginx && cp -a "$bak_dir/nginx" /etc/nginx; log_ok "Nginx 已恢复。"; } ;;
            2|7)
                [[ -d "$bak_dir/xray"       ]] && { rm -rf "$XRAY_CFG_DIR" && cp -a "$bak_dir/xray" "$XRAY_CFG_DIR"; log_ok "Xray 已恢复。"; } ;;
            3|7)
                [[ -d "$bak_dir/hysteria"   ]] && { rm -rf /etc/hysteria && cp -a "$bak_dir/hysteria" /etc/hysteria; log_ok "Hysteria2 已恢复。"; } ;;
            4|7)
                [[ -d "$bak_dir/psm_config" ]] && { rm -rf "$CFG_DIR" && cp -a "$bak_dir/psm_config" "$CFG_DIR"; log_ok "PSM 配置已恢复。"; } ;;
            5|7)
                [[ -d "$bak_dir/ssl"        ]] && { rm -rf "$NGINX_SSL_DIR" && cp -a "$bak_dir/ssl" "$NGINX_SSL_DIR"; log_ok "SSL 证书已恢复。"; } ;;
            6|7)
                [[ -d "$bak_dir/docker_compose" ]] && { rm -rf /opt/psm/compose && cp -a "$bak_dir/docker_compose" /opt/psm/compose; log_ok "Docker Compose 项目已恢复。"; }
                source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
                    && declare -f docker_restore_volumes &>/dev/null \
                    && docker_restore_volumes "$bak_dir"
                ;;
        esac
    done

    rm -rf "$tmp_dir"
    _start_services
    log_ok "恢复完成。"
}

_stop_services() {
    for svc in nginx xray hysteria-server; do
        svc_is_active "$svc" && svc_stop "$svc"
    done
}

_start_services() {
    for svc in nginx xray hysteria-server; do
        systemctl is-enabled --quiet "$svc" 2>/dev/null && svc_start "$svc"
    done
}

# ── Rotate old backups ────────────────────────────────────────────────────────
_rotate_backups() {
    local count; count=$(find "$BAK_ROOT" -maxdepth 1 -name "*.tar.gz" | wc -l)
    if (( count > MAX_BACKUPS )); then
        find "$BAK_ROOT" -maxdepth 1 -name "*.tar.gz" \
            | sort | head -$((count - MAX_BACKUPS)) \
            | xargs rm -f
        log_info "已轮换旧备份（保留最近 $MAX_BACKUPS 个）。"
    fi
}

# ── Schedule auto-backup ──────────────────────────────────────────────────────
auto_backup_enable() {
    local hour; ask hour "每日备份执行时刻（0-23）" "3"
    cat > /etc/cron.d/psm-backup <<EOF
0 ${hour} * * * root $PSM_ROOT/manager.sh --backup-full >> $LOG_DIR/backup.log 2>&1
EOF
    log_ok "自动备份已设置，每日 ${hour}:00 执行。"
}

auto_backup_disable() {
    rm -f /etc/cron.d/psm-backup
    log_ok "自动备份定时任务已删除。"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_backup_check_deps() {
    ensure_pkg_deps tar
}

# ── Menu ──────────────────────────────────────────────────────────────────────
backup_menu() {
    _backup_check_deps
    while true; do
        show_menu "备份与恢复" \
            "完整备份（所有组件）" \
            "选择性备份" \
            "从备份恢复" \
            "列出备份" \
            "启用自动备份（每日定时）" \
            "禁用自动备份"

        case "$MENU_CHOICE" in
            1) do_full_backup ;;
            2) do_selective_backup ;;
            3) do_restore ;;
            4) list_backups ;;
            5) auto_backup_enable ;;
            6) auto_backup_disable ;;
            0) return ;;
        esac
        press_enter
    done
}
