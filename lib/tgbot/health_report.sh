#!/usr/bin/env bash
# tgbot/health_report.sh — Daily digest: pulls status from every monitoring
# module already built (traffic, expiry, Reality watchdog, fail2ban, honeypot,
# SSH hardening, BBR, WARP) into one Telegram message. Read-only — never
# triggers new probes (no TLS handshakes, no WARP registration), just reads
# whatever state each module already persisted, so it's cheap and safe to run
# daily. Unlike notify.sh/expiry_notify.sh (thin templates fed pre-computed
# values by their caller), this module does its own cross-module aggregation
# and only uses notify.sh as its output channel — same relationship traffic.sh
# has with notify.sh, just living alongside it here for easier upkeep.

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

HR_CFG="$CFG_DIR/health_report.conf"
HR_SVC="/etc/systemd/system/psm-health-report.service"
HR_TIMER="/etc/systemd/system/psm-health-report.timer"

_hr_load_cfg() {
    HR_ENABLED="false"
    HR_HOUR="8"
    # shellcheck source=/dev/null
    [[ -f "$HR_CFG" ]] && source "$HR_CFG"
}

_hr_save_cfg() {
    mkdir -p "$CFG_DIR"
    cat > "$HR_CFG" <<EOF
HR_ENABLED="${HR_ENABLED}"
HR_HOUR="${HR_HOUR}"
EOF
}

# ── Section builders ──────────────────────────────────────────────────────────
_hr_section_services() {
    command -v systemctl &>/dev/null || return 0
    local lines="" total=0 down=0 entry name svc state
    for entry in "Xray:xray" "sing-box:sing-box" "mihomo:mihomo" \
                 "Hysteria2:hysteria-server" "ss-rust:ss-rust" "Snell:snell" \
                 "Nginx:nginx"; do
        name="${entry%%:*}"; svc="${entry#*:}"
        state=$(systemctl show "$svc" --property=LoadState --value 2>/dev/null || true)
        [[ "$state" == "loaded" ]] || continue
        total=$(( total + 1 ))
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            down=$(( down + 1 ))
            lines="${lines}$(t tgbot.hr.svc_down_line "$name" "$svc")"
        fi
    done
    (( total == 0 )) && return 0
    printf "$(t tgbot.hr.services_section)" "$total" "$(( total - down ))" "$down" "$lines"
}

_hr_section_traffic() {
    source "$LIB_DIR/traffic.sh" 2>/dev/null || return 0
    declare -f _trf_get_tags &>/dev/null || return 0
    _trf_init 2>/dev/null

    local tag count=0 warn=0 paused=0 lines=""
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        count=$(( count + 1 ))
        local limit acc is_paused port pct=0
        limit=$(_trf_to_int "$(_trf_get "$tag" "limit_bytes")")
        acc=$(_trf_to_int "$(_trf_get "$tag" "accumulated_bytes")")
        is_paused=$(_trf_get "$tag" "paused")
        port=$(_trf_get "$tag" "port")
        (( limit > 0 )) && pct=$(( acc * 100 / limit ))

        if [[ "$is_paused" == "true" ]]; then
            paused=$(( paused + 1 ))
            lines="${lines}$(t tgbot.hr.traffic_paused_line "$tag" "$port")"
        elif (( pct >= 90 )); then
            warn=$(( warn + 1 ))
            lines="${lines}$(t tgbot.hr.traffic_warn_line "$tag" "$port" "$pct")"
        fi
    done < <(_trf_get_tags)

    (( count == 0 )) && return 0
    printf "$(t tgbot.hr.traffic_section)" "$count" "$warn" "$paused" "$lines"
}

_hr_section_expiry() {
    source "$LIB_DIR/expiry/core.sh" 2>/dev/null || return 0
    declare -f _exp_get_tags &>/dev/null || return 0
    _exp_init 2>/dev/null

    local tag count=0 soon=0 expired=0 lines=""
    local now_ts; now_ts=$(_exp_now_ts)
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        local exp_at; exp_at=$(_exp_get "$tag" "expires_at")
        [[ -z "$exp_at" ]] && continue
        count=$(( count + 1 ))
        local exp_ts diff; exp_ts=$(_exp_str_to_ts "$exp_at"); diff=$(( exp_ts - now_ts ))
        if (( diff <= 0 )); then
            expired=$(( expired + 1 ))
            lines="${lines}$(t tgbot.hr.expired_line "$tag")"
        elif (( diff <= 7 * 86400 )); then
            soon=$(( soon + 1 ))
            lines="${lines}$(t tgbot.hr.expiring_line "$tag" "$(( diff / 86400 ))" "$exp_at")"
        fi
    done < <(_exp_get_tags)

    (( count == 0 )) && return 0
    printf "$(t tgbot.hr.expiry_section)" "$count" "$expired" "$soon" "$lines"
}

_hr_section_reality_watchdog() {
    source "$LIB_DIR/xray/reality_watchdog.sh" 2>/dev/null || return 0
    declare -f _rwd_enabled_tags &>/dev/null || return 0

    local tag count=0 recent_switch=0 lines=""
    local now_ts; now_ts=$(date +%s)
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        count=$(( count + 1 ))
        local entry; entry=$(_rwd_get_entry "$tag")
        local active last_switch; active=$(echo "$entry" | jq -r '.active'); last_switch=$(echo "$entry" | jq -r '.last_switch')
        if [[ -n "$last_switch" ]]; then
            local sw_ts; sw_ts=$(date -d "$last_switch" +%s 2>/dev/null || echo 0)
            if (( sw_ts > 0 )) && (( now_ts - sw_ts <= 86400 )); then
                recent_switch=$(( recent_switch + 1 ))
                lines="${lines}$(t tgbot.hr.reality_switch_line "$tag" "$active")"
            fi
        fi
    done < <(_rwd_enabled_tags)

    (( count == 0 )) && return 0
    printf "$(t tgbot.hr.reality_section)" "$count" "$recent_switch" "$lines"
}

_hr_section_security() {
    local lines=""

    # SSH
    source "$LIB_DIR/security/ssh.sh" 2>/dev/null || true
    if command -v sshd &>/dev/null && declare -f _ssh_get &>/dev/null; then
        local pwauth; pwauth=$(_ssh_get passwordauthentication)
        if [[ "$pwauth" == "no" ]]; then
            lines="${lines}$(t tgbot.hr.ssh_pw_disabled)"
        else
            lines="${lines}$(t tgbot.hr.ssh_pw_enabled)"
        fi
        local remaining
        if remaining=$(_ssh_pending_rollback_info); then
            lines="${lines}$(t tgbot.hr.ssh_pending "$remaining")"
        fi
    fi

    # BBR
    if declare -f check_bbr &>/dev/null; then
        check_bbr && lines="${lines}$(t tgbot.hr.bbr_enabled)" || lines="${lines}$(t tgbot.hr.bbr_disabled)"
    fi

    # fail2ban
    source "$LIB_DIR/security/fail2ban.sh" 2>/dev/null || true
    if command -v fail2ban-client &>/dev/null; then
        local sshd_banned hp_banned
        sshd_banned=$(fail2ban-client status psm-sshd 2>/dev/null \
            | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')
        hp_banned=$(fail2ban-client status psm-honeypot 2>/dev/null \
            | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')
        [[ -n "$sshd_banned" ]] && lines="${lines}$(t tgbot.hr.fail2ban_banned "$sshd_banned")"
        [[ -n "$hp_banned" ]] && lines="${lines}$(t tgbot.hr.honeypot_banned "$hp_banned")"
    fi
    if [[ -f "${HP_LOG:-$CFG_DIR/../logs/honeypot.log}" ]]; then
        local today; today=$(date '+%Y-%m-%d')
        local hits; hits=$(grep -c "^${today}" "${HP_LOG:-$CFG_DIR/../logs/honeypot.log}" 2>/dev/null || echo 0)
        (( hits > 0 )) && lines="${lines}$(t tgbot.hr.honeypot_hits "$hits")"
    fi

    [[ -z "$lines" ]] && return 0
    printf "$(t tgbot.hr.security_section)" "$lines"
}

_hr_section_warp() {
    source "$LIB_DIR/xray/warp.sh" 2>/dev/null || return 0
    declare -f _warp_registered &>/dev/null || return 0
    _warp_registered || return 0

    local applied
    if _outb_get_by_tag "$WARP_OUTBOUND_TAG" 2>/dev/null | jq -e '.tag' &>/dev/null; then
        applied="$(t tgbot.hr.warp_applied)"
    else
        applied="$(t tgbot.hr.warp_not_applied)"
    fi
    printf "$(t tgbot.hr.warp_section)" "$applied"
}

# ── Assemble & send ───────────────────────────────────────────────────────────
hr_build_report() {
    local now; now=$(date '+%Y-%m-%d %H:%M')
    local body=""
    local section
    for section in _hr_section_services _hr_section_traffic _hr_section_expiry \
                   _hr_section_reality_watchdog _hr_section_security _hr_section_warp; do
        local part; part=$("$section")
        [[ -n "$part" ]] && body="${body}${part}\n\n"
    done

    [[ -z "$body" ]] && body="$(t tgbot.hr.empty)"

    printf "$(t tgbot.hr.report)" "$now" "$body"
}

hr_send_report() {
    source "$(dirname "${BASH_SOURCE[0]}")/notify.sh" 2>/dev/null || return 0
    declare -f tg_notify_admins &>/dev/null || return 0
    tg_notify_admins "$(hr_build_report)"
}

# ── Systemd timer ───────────────────────────────────────────────────────────
_hr_install_timer() {
    _hr_load_cfg
    cat > "$HR_SVC" <<EOF
[Unit]
Description=PSM Daily Health Report
After=network.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PSM_ROOT}/manager.sh --health-report
StandardOutput=journal
StandardError=journal
EOF

    cat > "$HR_TIMER" <<EOF
[Unit]
Description=PSM Daily Health Report Timer

[Timer]
OnCalendar=*-*-* $(printf '%02d' "$HR_HOUR"):00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now psm-health-report.timer
    log_ok "$(t tgbot.hr.enabled "$HR_HOUR")"
}

_hr_uninstall_timer() {
    systemctl disable --now psm-health-report.timer 2>/dev/null || true
    rm -f "$HR_SVC" "$HR_TIMER"
    systemctl daemon-reload
    log_ok "$(t tgbot.hr.disabled)"
}

_hr_timer_active() { systemctl is-active --quiet psm-health-report.timer 2>/dev/null; }

# ── Wizard / menu ─────────────────────────────────────────────────────────────
hr_setup_wizard() {
    _hr_load_cfg
    echo -e "\n${BOLD}${BLUE}══ $(t tgbot.hr.setup_title) ══════════════════════${NC}"
    local hour
    ask hour "$(t tgbot.hr.ask_hour)" "${HR_HOUR:-8}"
    if ! [[ "$hour" =~ ^[0-9]+$ ]] || (( hour < 0 || hour > 23 )); then
        log_error "$(t tgbot.hr.invalid_hour)"; return 1
    fi
    HR_HOUR="$hour"
    HR_ENABLED="true"
    _hr_save_cfg
    _hr_install_timer
}

hr_disable() {
    HR_ENABLED="false"
    _hr_save_cfg
    _hr_uninstall_timer
}

hr_status() {
    _hr_load_cfg
    echo -e "\n${BOLD}${BLUE}══ $(t tgbot.hr.status_title) ══════════════════════${NC}"
    if [[ "$HR_ENABLED" == "true" ]] && _hr_timer_active; then
        echo -e "  ${GREEN}$(t tgbot.hr.status_enabled "$HR_HOUR")${NC}"
    else
        echo -e "  ${YELLOW}$(t tgbot.hr.status_disabled)${NC}"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

hr_menu() {
    while true; do
        hr_status
        show_menu "$(t tgbot.hr.menu.title)" \
            "$(t tgbot.hr.menu.setup)" \
            "$(t tgbot.hr.menu.send_now)" \
            "$(t tgbot.hr.menu.disable)"

        case "$MENU_CHOICE" in
            1) hr_setup_wizard; press_enter ;;
            2) log_step "$(t tgbot.hr.sending)"; hr_send_report; log_ok "$(t tgbot.hr.sent)"; press_enter ;;
            3) hr_disable; press_enter ;;
            0) return ;;
        esac
    done
}
