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
    log_ok "$(t backup.quick_saved "$bak")"
    echo "$bak"
}

# ── Full backup ───────────────────────────────────────────────────────────────
do_full_backup() {
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local name="${ts}_full"
    local bak="$BAK_ROOT/$name"
    mkdir -p "$bak"

    log_step "$(t backup.full_creating "$bak")"

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
    log_ok "$(t backup.full_done "$archive")"
    echo "$archive"
}

# ── Selective backup ──────────────────────────────────────────────────────────
do_selective_backup() {
    echo -e "\n  $(t backup.select_prompt)"
    echo    "  1. $(t backup.item.nginx)"
    echo    "  2. $(t backup.item.xray)"
    echo    "  3. $(t backup.item.hysteria)"
    echo    "  4. $(t backup.item.psm)"
    echo    "  5. $(t backup.item.ssl)"
    echo    "  6. $(t backup.item.docker_compose)"
    echo    "  7. $(t backup.item.docker_volumes)"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" choices

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
    log_ok "$(t backup.select_done "$archive")"
}

# ── List backups ──────────────────────────────────────────────────────────────
list_backups() {
    echo -e "\n${BOLD}$(t backup.available)${NC}"
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
    local archive; ask archive "$(t backup.ask_archive)"
    local full_path="$BAK_ROOT/$archive"
    [[ -f "$full_path" ]] || { log_error "$(t backup.not_found "$full_path")"; return 1; }

    ask_yn "$(t backup.ask_restore "$archive")" N || return 0

    local tmp_dir; tmp_dir=$(mktemp -d)
    tar -xzf "$full_path" -C "$tmp_dir"
    local bak_dir; bak_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)

    echo -e "\n  $(t backup.restore_prompt)"
    echo    "  1. $(t backup.item.nginx)"
    echo    "  2. $(t backup.item.xray)"
    echo    "  3. $(t backup.item.hysteria)"
    echo    "  4. $(t backup.item.psm)"
    echo    "  5. $(t backup.item.ssl)"
    echo    "  6. $(t backup.item.docker_restore)"
    echo    "  7. $(t backup.item.all)"
    read -rp "$(echo -e "${CYAN}$(t backup.select_default7)${NC}")" rc; rc="${rc:-7}"
    # 选 7（全部恢复）时展开为全部组件；否则保留用户输入的多个数字（空格分隔）
    [[ "$rc" == *7* ]] && rc="1 2 3 4 5 6"

    _stop_services

    for c in $rc; do
        case "$c" in
            1)
                [[ -d "$bak_dir/nginx"      ]] && { rm -rf /etc/nginx && cp -a "$bak_dir/nginx" /etc/nginx; log_ok "$(t backup.restored.nginx)"; } ;;
            2)
                [[ -d "$bak_dir/xray"       ]] && { rm -rf "$XRAY_CFG_DIR" && cp -a "$bak_dir/xray" "$XRAY_CFG_DIR"; log_ok "$(t backup.restored.xray)"; } ;;
            3)
                [[ -d "$bak_dir/hysteria"   ]] && { rm -rf /etc/hysteria && cp -a "$bak_dir/hysteria" /etc/hysteria; log_ok "$(t backup.restored.hysteria)"; } ;;
            4)
                [[ -d "$bak_dir/psm_config" ]] && { rm -rf "$CFG_DIR" && cp -a "$bak_dir/psm_config" "$CFG_DIR"; log_ok "$(t backup.restored.psm)"; } ;;
            5)
                [[ -d "$bak_dir/ssl"        ]] && { rm -rf "$NGINX_SSL_DIR" && cp -a "$bak_dir/ssl" "$NGINX_SSL_DIR"; log_ok "$(t backup.restored.ssl)"; } ;;
            6)
                [[ -d "$bak_dir/docker_compose" ]] && { rm -rf /opt/psm/compose && cp -a "$bak_dir/docker_compose" /opt/psm/compose; log_ok "$(t backup.restored.docker)"; }
                source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
                    && declare -f docker_restore_volumes &>/dev/null \
                    && docker_restore_volumes "$bak_dir"
                ;;
        esac
    done

    rm -rf "$tmp_dir"
    _start_services
    log_ok "$(t backup.restore_done)"
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
        log_info "$(t backup.rotated "$MAX_BACKUPS")"
    fi
}

# ── Schedule auto-backup ──────────────────────────────────────────────────────
auto_backup_enable() {
    local hour; ask hour "$(t backup.ask_hour)" "3"
    ensure_cron || true   # RHEL 系最小安装没有 cronie，/etc/cron.d 会被无声忽略
    cat > /etc/cron.d/psm-backup <<EOF
0 ${hour} * * * root $PSM_ROOT/manager.sh --backup-full >> $LOG_DIR/backup.log 2>&1
EOF
    log_ok "$(t backup.auto_enabled "$hour")"
}

auto_backup_disable() {
    rm -f /etc/cron.d/psm-backup
    log_ok "$(t backup.auto_disabled)"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_backup_check_deps() {
    ensure_pkg_deps tar
}

# ── Menu ──────────────────────────────────────────────────────────────────────
backup_menu() {
    _backup_check_deps
    while true; do
        show_menu "$(t backup.menu.title)" \
            "$(t backup.menu.full)" \
            "$(t backup.menu.selective)" \
            "$(t backup.menu.restore)" \
            "$(t backup.menu.list)" \
            "$(t backup.menu.auto_enable)" \
            "$(t backup.menu.auto_disable)"

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
