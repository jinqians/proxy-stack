#!/usr/bin/env bash
# security/ssh.sh — SSH hardening: key-only login, disable password auth, change port
#
# Safety model: every risky change (one that could lock the admin out) is
# applied via `reload` (keeps the current session alive) and gets a scheduled
# auto-rollback timer. If the admin doesn't explicitly confirm from a NEW
# session within SSH_ROLLBACK_DELAY seconds, a background job restores the
# pre-change config automatically. Only one such change may be pending at a
# time — a new risky change is refused while one is still unconfirmed.

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

SSHD_CFG="/etc/ssh/sshd_config"
SSH_SEC_DIR="$CFG_DIR/security"
SSH_BACKUP_DIR="$SSH_SEC_DIR/backups"
SSH_ROLLBACK_STATE="$SSH_SEC_DIR/pending_rollback.json"
SSH_ROLLBACK_LOG="$SSH_SEC_DIR/rollback.log"
SSH_ROLLBACK_DELAY=300   # seconds before an unconfirmed change auto-reverts
SSH_MARKER_BEGIN="# PSM-SSH-HARDENING-BEGIN — managed by PSM, do not hand-edit directives in this block"
SSH_MARKER_END="# PSM-SSH-HARDENING-END"

_ssh_svc_name() {
    detect_os
    case "$OS_ID" in
        ubuntu|debian|raspbian) echo "ssh" ;;
        *)                      echo "sshd" ;;
    esac
}

_ssh_init() { mkdir -p "$SSH_BACKUP_DIR"; }

# ── Config file editing (idempotent, wins under sshd's first-match-wins rule) ─
_ssh_ensure_marker_block() {
    grep -q "^${SSH_MARKER_BEGIN}$" "$SSHD_CFG" 2>/dev/null && return 0
    local tmp; tmp=$(mktemp)
    { echo "$SSH_MARKER_BEGIN"; echo "$SSH_MARKER_END"; cat "$SSHD_CFG"; } > "$tmp"
    mv "$tmp" "$SSHD_CFG"
}

# Insert a line right after the marker's BEGIN line. Uses awk rather than
# `sed -i '/pat/a text'` — that GNU-sed insert syntax isn't portable across
# sed implementations and fails silently different ways elsewhere.
_ssh_insert_after_marker() {
    local text="$1"
    local tmp; tmp=$(mktemp)
    awk -v ins="$text" -v marker="$SSH_MARKER_BEGIN" \
        '{ print } $0 == marker { print ins }' "$SSHD_CFG" > "$tmp"
    mv "$tmp" "$SSHD_CFG"
}

# Strip every existing occurrence (commented or not) of a directive, then
# insert the new value right after the marker's BEGIN line, so it's the
# first — and therefore effective — occurrence sshd sees.
_ssh_set_directive() {
    local key="$1" value="$2"
    local tmp; tmp=$(mktemp)
    grep -viE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$SSHD_CFG" > "$tmp" || true
    mv "$tmp" "$SSHD_CFG"
    [[ -n "$value" ]] || return 0
    _ssh_ensure_marker_block
    _ssh_insert_after_marker "${key} ${value}"
}

_ssh_set_ports() {
    local ports=("$@")
    local tmp; tmp=$(mktemp)
    grep -viE "^[[:space:]]*#?[[:space:]]*Port[[:space:]]" "$SSHD_CFG" > "$tmp" || true
    mv "$tmp" "$SSHD_CFG"
    _ssh_ensure_marker_block
    local p
    for p in "${ports[@]}"; do
        _ssh_insert_after_marker "Port ${p}"
    done
}

_ssh_backup() {
    _ssh_init
    local dst
    dst="$SSH_BACKUP_DIR/sshd_config.$(date +%Y%m%d%H%M%S)"
    cp -a "$SSHD_CFG" "$dst"
    printf '%s' "$dst"
}

_ssh_test_config() { sshd -t 2>&1; }
_ssh_reload()      { svc_reload "$(_ssh_svc_name)"; }

# ── Effective (live, parsed) config readers — via `sshd -T`, not raw grep ────
_ssh_get() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }
_ssh_ports() { _ssh_get port | paste -sd, - ; }

_ssh_authorized_keys_file() { echo "/root/.ssh/authorized_keys"; }
_ssh_has_pubkey() {
    local f; f=$(_ssh_authorized_keys_file)
    [[ -s "$f" ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null
}

# ── Rollback safety net ────────────────────────────────────────────────────
_ssh_guard_no_pending() {
    if [[ -f "$SSH_ROLLBACK_STATE" ]]; then
        log_error "$(t security.ssh.pending_change)"
        return 1
    fi
    return 0
}

_ssh_schedule_rollback() {
    local backup="$1" reason="$2"
    _ssh_init
    local svc; svc=$(_ssh_svc_name)
    local rollback_msg; rollback_msg="$(t security.ssh.rollback_executed "$reason")"
    nohup bash -c "
        sleep ${SSH_ROLLBACK_DELAY}
        if [[ -f '${SSH_ROLLBACK_STATE}' ]]; then
            cp -a '${backup}' '${SSHD_CFG}'
            if sshd -t 2>/dev/null; then systemctl reload ${svc} 2>/dev/null || systemctl restart ${svc} 2>/dev/null; fi
            rm -f '${SSH_ROLLBACK_STATE}'
            echo \"\$(date '+%Y-%m-%d %H:%M:%S') ${rollback_msg}\" >> '${SSH_ROLLBACK_LOG}'
        fi
    " >/dev/null 2>&1 &
    disown
    jq -n --arg pid "$!" --arg backup "$backup" --arg reason "$reason" \
          --arg at "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{pid:$pid, backup:$backup, reason:$reason, scheduled_at:$at, delay:'"$SSH_ROLLBACK_DELAY"'}' \
        > "$SSH_ROLLBACK_STATE"
}

_ssh_confirm_hardening() {
    if [[ ! -f "$SSH_ROLLBACK_STATE" ]]; then
        log_warn "$(t security.ssh.no_pending)"
        return 0
    fi
    local pid; pid=$(jq -r '.pid' "$SSH_ROLLBACK_STATE" 2>/dev/null)
    rm -f "$SSH_ROLLBACK_STATE"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    log_ok "$(t security.ssh.confirmed)"
}

_ssh_pending_rollback_info() {
    [[ -f "$SSH_ROLLBACK_STATE" ]] || return 1
    local scheduled_at delay elapsed remaining
    scheduled_at=$(jq -r '.scheduled_at' "$SSH_ROLLBACK_STATE")
    delay=$(jq -r '.delay' "$SSH_ROLLBACK_STATE")
    elapsed=$(( $(date +%s) - $(date -d "$scheduled_at" +%s 2>/dev/null || echo 0) ))
    remaining=$(( delay - elapsed ))
    (( remaining < 0 )) && remaining=0
    printf '%s' "$remaining"
}

# Apply validated changes: test → reload → schedule rollback. On config-test
# failure, restores the pre-change backup immediately (never reloads a bad config).
_ssh_apply_and_protect() {
    local backup="$1" reason="$2"
    local test_out
    if ! test_out=$(_ssh_test_config); then
        log_error "$(t security.ssh.config_test_fail)"
        echo "$test_out"
        cp -a "$backup" "$SSHD_CFG"
        return 1
    fi
    _ssh_reload
    _ssh_schedule_rollback "$backup" "$reason"
    log_warn "$(t security.ssh.change_active_warn "$((SSH_ROLLBACK_DELAY / 60))")"
    log_warn "$(t security.ssh.keep_session_warn)"
    return 0
}

# ── Add a public key ─────────────────────────────────────────────────────────
_ssh_add_pubkey_wizard() {
    local akfile; akfile=$(_ssh_authorized_keys_file)
    mkdir -p "$(dirname "$akfile")" && chmod 700 "$(dirname "$akfile")"
    echo -e "\n${YELLOW}$(t security.ssh.paste_key)${NC}"
    local key
    read -r key
    if ! [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)[[:space:]] ]]; then
        log_error "$(t security.ssh.invalid_pubkey)"
        return 1
    fi
    touch "$akfile"; chmod 600 "$akfile"
    if grep -qF "$key" "$akfile" 2>/dev/null; then
        log_info "$(t security.ssh.key_exists "$akfile")"
    else
        echo "$key" >> "$akfile"
        log_ok "$(t security.ssh.key_added "$akfile")"
    fi
}

# ── Disable password login ───────────────────────────────────────────────────
ssh_disable_password() {
    _ssh_init
    _ssh_guard_no_pending || return 1

    if ! _ssh_has_pubkey; then
        log_warn "$(t security.ssh.no_root_key "$(_ssh_authorized_keys_file)")"
        ask_yn "$(t security.ssh.ask_add_key)" Y && _ssh_add_pubkey_wizard
        _ssh_has_pubkey || { log_error "$(t security.ssh.no_key_cancel)"; return 1; }
    fi

    echo -e "\n${RED}${BOLD}$(t security.ssh.disable_pw_warn)${NC}"
    echo -e "${YELLOW}$(t security.ssh.test_key_warn)${NC}"
    ask_yn "$(t security.ssh.confirm_continue)" N || return 0

    local backup; backup=$(_ssh_backup)
    _ssh_set_directive "PasswordAuthentication"      "no"
    _ssh_set_directive "KbdInteractiveAuthentication" "no"
    _ssh_set_directive "PubkeyAuthentication"         "yes"
    _ssh_set_directive "PermitRootLogin"              "prohibit-password"

    _ssh_apply_and_protect "$backup" "$(t security.ssh.reason_disable_pw)"
}

# ── Change / add SSH port ────────────────────────────────────────────────────
ssh_change_port() {
    _ssh_guard_no_pending || return 1

    local cur; cur=$(_ssh_ports)
    log_info "$(t security.ssh.current_ports "${cur:-22}")"
    local new_port
    ask new_port "$(t security.ssh.ask_new_port)" ""
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        log_error "$(t security.ssh.invalid_port)"; return 1
    fi
    if echo ",${cur}," | grep -qF ",${new_port},"; then
        log_warn "$(t security.ssh.port_already_current "$new_port")"; return 0
    fi

    echo -e "\n${RED}${BOLD}$(t security.ssh.change_port_warn "$cur")${NC}"
    echo -e "${YELLOW}$(t security.ssh.test_new_port_warn)${NC}"
    echo -e "${YELLOW}$(t security.ssh.rollback_port_warn "$((SSH_ROLLBACK_DELAY / 60))")${NC}"
    echo -e "${YELLOW}$(t security.ssh.no_dual_port_warn)${NC}"
    ask_yn "$(t security.ssh.ask_switch_port "$new_port")" N || return 0

    local backup; backup=$(_ssh_backup)
    source "$LIB_DIR/system.sh" 2>/dev/null || true
    declare -f firewall_open_port &>/dev/null && firewall_open_port "$new_port" "tcp"

    _ssh_set_ports "$new_port"

    _ssh_apply_and_protect "$backup" "$(t security.ssh.reason_change_port "$new_port")"
}

# ── One-click wizard (key + disable password only; port change is separate) ──
ssh_harden_wizard() {
    echo -e "\n${BOLD}${BLUE}══ $(t security.ssh.wizard_title) ══════════════════${NC}"
    echo "$(t security.ssh.wizard_steps)"
    echo -e "${YELLOW}$(t security.ssh.wizard_port_note)${NC}"
    echo -e "${YELLOW}$(t security.ssh.wizard_risk_note)${NC}\n"

    if _ssh_has_pubkey; then
        log_info "$(t security.ssh.key_detected)"
    else
        log_step "$(t security.ssh.step_add_key)"
        _ssh_add_pubkey_wizard || return 1
        _ssh_has_pubkey || { log_error "$(t security.ssh.key_add_failed)"; return 1; }
    fi

    log_step "$(t security.ssh.step_disable_pw)"
    ssh_disable_password
}

# ── Restore from backup ──────────────────────────────────────────────────────
ssh_restore_backup_menu() {
    _ssh_init
    local -a files=()
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$SSH_BACKUP_DIR"/sshd_config.* 2>/dev/null)
    if (( ${#files[@]} == 0 )); then
        log_warn "$(t security.ssh.no_backups)"; return 0
    fi
    echo -e "\n${BOLD}$(t security.ssh.backup_title)${NC}"
    local i=0
    for f in "${files[@]}"; do i=$((i+1)); printf "  %2d. %s\n" "$i" "$(basename "$f")"; done

    local sel
    read -rp "$(echo -e "${CYAN}$(t security.ssh.ask_restore_backup): ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t security.ssh.invalid_option)"; return 1
    fi
    local chosen="${files[$((sel-1))]}"
    ask_yn "$(t security.ssh.ask_confirm_restore "$(basename "$chosen")")" N || return 0

    _ssh_backup >/dev/null   # snapshot current config first, just in case
    cp -a "$chosen" "$SSHD_CFG"
    local test_out
    if ! test_out=$(_ssh_test_config); then
        log_error "$(t security.ssh.backup_test_fail)"; echo "$test_out"; return 1
    fi
    _ssh_reload
    rm -f "$SSH_ROLLBACK_STATE"
    log_ok "$(t security.ssh.restored "$(basename "$chosen")")"
}

# ── Status ────────────────────────────────────────────────────────────────────
ssh_status() {
    echo -e "\n${BOLD}${BLUE}══ $(t security.ssh.status_title) ══════════════════════════════════${NC}"
    local ports pwauth pubkeyauth rootlogin
    ports=$(_ssh_ports)
    pwauth=$(_ssh_get passwordauthentication)
    pubkeyauth=$(_ssh_get pubkeyauthentication)
    rootlogin=$(_ssh_get permitrootlogin)

    echo -e "  $(t security.ssh.status_ports "${ports:-22}")"
    if [[ "$pwauth" == "no" ]]; then
        echo -e "  $(t security.ssh.password_login)${GREEN}$(t security.ssh.disabled_key_only)${NC}"
    else
        echo -e "  $(t security.ssh.password_login)${RED}$(t security.ssh.still_enabled)${NC}"
    fi
    echo -e "  $(t security.ssh.pubkey_login "${pubkeyauth:-$(t common.not_configured)}")"
    echo -e "  $(t security.ssh.root_policy "${rootlogin:-$(t common.not_configured)}")"
    if _ssh_has_pubkey; then
        echo -e "  $(t security.ssh.key_configured)${GREEN}$(t security.ssh.yes)${NC}"
    else
        echo -e "  $(t security.ssh.key_configured)${RED}$(t security.ssh.no)${NC}"
    fi

    local remaining
    if remaining=$(_ssh_pending_rollback_info); then
        local reason; reason=$(jq -r '.reason' "$SSH_ROLLBACK_STATE" 2>/dev/null)
        echo -e "  ${YELLOW}$(t security.ssh.pending_status "$reason" "$remaining")${NC}"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
ssh_menu() {
    if ! command -v sshd &>/dev/null; then
        log_warn "$(t security.ssh.no_sshd)"
        return 1
    fi
    while true; do
        ssh_status
        show_menu "$(t security.ssh.menu.title)" \
            "$(t security.ssh.menu.wizard)" \
            "$(t security.ssh.menu.confirm)" \
            "$(t security.ssh.menu.add_key)" \
            "$(t security.ssh.menu.disable_pw)" \
            "$(t security.ssh.menu.change_port)" \
            "$(t security.ssh.menu.restore)"

        case "$MENU_CHOICE" in
            1) ssh_harden_wizard;       press_enter ;;
            2) _ssh_confirm_hardening;  press_enter ;;
            3) _ssh_add_pubkey_wizard;  press_enter ;;
            4) ssh_disable_password;    press_enter ;;
            5) ssh_change_port;         press_enter ;;
            6) ssh_restore_backup_menu; press_enter ;;
            0) return ;;
        esac
    done
}
