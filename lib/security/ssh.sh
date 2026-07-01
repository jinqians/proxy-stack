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
    local dst="$SSH_BACKUP_DIR/sshd_config.$(date +%Y%m%d%H%M%S)"
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
        log_error "存在尚未确认的 SSH 加固变更，请先在菜单中「确认加固生效」或等待其自动回滚，再进行下一步操作"
        return 1
    fi
    return 0
}

_ssh_schedule_rollback() {
    local backup="$1" reason="$2"
    _ssh_init
    local svc; svc=$(_ssh_svc_name)
    nohup bash -c "
        sleep ${SSH_ROLLBACK_DELAY}
        if [[ -f '${SSH_ROLLBACK_STATE}' ]]; then
            cp -a '${backup}' '${SSHD_CFG}'
            if sshd -t 2>/dev/null; then systemctl reload ${svc} 2>/dev/null || systemctl restart ${svc} 2>/dev/null; fi
            rm -f '${SSH_ROLLBACK_STATE}'
            echo \"\$(date '+%Y-%m-%d %H:%M:%S') 自动回滚已执行：${reason}\" >> '${SSH_ROLLBACK_LOG}'
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
        log_warn "当前没有待确认的 SSH 加固变更"
        return 0
    fi
    local pid; pid=$(jq -r '.pid' "$SSH_ROLLBACK_STATE" 2>/dev/null)
    rm -f "$SSH_ROLLBACK_STATE"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    log_ok "已确认加固生效，自动回滚已取消"
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
        log_error "sshd 配置校验失败，已回滚到修改前的配置："
        echo "$test_out"
        cp -a "$backup" "$SSHD_CFG"
        return 1
    fi
    _ssh_reload
    _ssh_schedule_rollback "$backup" "$reason"
    log_warn "变更已生效（reload，不影响当前已连接的会话），但 $((SSH_ROLLBACK_DELAY / 60)) 分钟内未确认将自动回滚。"
    log_warn "请【保持当前会话不要关闭】，立即在新终端窗口验证连接，成功后回到本菜单选择「确认加固生效」。"
    return 0
}

# ── Add a public key ─────────────────────────────────────────────────────────
_ssh_add_pubkey_wizard() {
    local akfile; akfile=$(_ssh_authorized_keys_file)
    mkdir -p "$(dirname "$akfile")" && chmod 700 "$(dirname "$akfile")"
    echo -e "\n${YELLOW}请粘贴你的 SSH 公钥整行内容（来自本机 ~/.ssh/id_ed25519.pub 等文件，以 ssh-ed25519 / ssh-rsa 开头）：${NC}"
    local key
    read -r key
    if ! [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)[[:space:]] ]]; then
        log_error "不是合法的公钥格式，已取消"
        return 1
    fi
    touch "$akfile"; chmod 600 "$akfile"
    if grep -qF "$key" "$akfile" 2>/dev/null; then
        log_info "该公钥已存在于 $akfile，无需重复添加"
    else
        echo "$key" >> "$akfile"
        log_ok "公钥已添加到 $akfile"
    fi
}

# ── Disable password login ───────────────────────────────────────────────────
ssh_disable_password() {
    _ssh_init
    _ssh_guard_no_pending || return 1

    if ! _ssh_has_pubkey; then
        log_warn "未检测到 root 的任何 SSH 公钥（$(_ssh_authorized_keys_file) 为空）"
        ask_yn "是否现在添加一个公钥？" Y && _ssh_add_pubkey_wizard
        _ssh_has_pubkey || { log_error "没有可用公钥时禁用密码登录会导致无法登录，已取消"; return 1; }
    fi

    echo -e "\n${RED}${BOLD}警告：此操作会禁用密码登录，仅允许密钥登录。${NC}"
    echo -e "${YELLOW}请不要关闭当前会话，操作后请立刻在新终端窗口测试密钥登录。${NC}"
    ask_yn "确认继续？" N || return 0

    local backup; backup=$(_ssh_backup)
    _ssh_set_directive "PasswordAuthentication"      "no"
    _ssh_set_directive "KbdInteractiveAuthentication" "no"
    _ssh_set_directive "PubkeyAuthentication"         "yes"
    _ssh_set_directive "PermitRootLogin"              "prohibit-password"

    _ssh_apply_and_protect "$backup" "密码登录禁用未在时限内确认"
}

# ── Change / add SSH port ────────────────────────────────────────────────────
ssh_change_port() {
    _ssh_guard_no_pending || return 1

    local cur; cur=$(_ssh_ports)
    log_info "当前监听端口：${cur:-22}"
    local new_port
    ask new_port "新的 SSH 端口（1-65535）" ""
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        log_error "端口无效"; return 1
    fi
    if echo ",${cur}," | grep -qF ",${new_port},"; then
        log_warn "端口 ${new_port} 已经是当前监听端口"; return 0
    fi

    echo -e "\n${RED}${BOLD}警告：此操作会直接切换 SSH 端口，不再监听旧端口（${cur}）。${NC}"
    echo -e "${YELLOW}请不要关闭当前会话，操作后请立刻在新终端窗口用新端口测试连接。${NC}"
    echo -e "${YELLOW}$((SSH_ROLLBACK_DELAY / 60)) 分钟内未确认会自动回滚回旧端口——这就是安全网，${NC}"
    echo -e "${YELLOW}不需要靠新旧端口同时开着来兜底。${NC}"
    ask_yn "确认切换到端口 ${new_port}？" N || return 0

    local backup; backup=$(_ssh_backup)
    source "$LIB_DIR/system.sh" 2>/dev/null || true
    declare -f firewall_open_port &>/dev/null && firewall_open_port "$new_port" "tcp"

    _ssh_set_ports "$new_port"

    _ssh_apply_and_protect "$backup" "SSH 端口切换至 ${new_port} 未在时限内确认"
}

# ── One-click wizard (key + disable password only; port change is separate) ──
ssh_harden_wizard() {
    echo -e "\n${BOLD}${BLUE}══ SSH 一键加固向导 ══════════════════${NC}"
    echo "依次完成：1) 确保已有可用公钥  2) 禁用密码登录"
    echo -e "${YELLOW}如需改端口，请在本向导确认生效后，再到菜单单独执行「修改/新增端口」——${NC}"
    echo -e "${YELLOW}两个高风险变更不会同时挂起，避免叠加风险导致更难排查。${NC}\n"

    if _ssh_has_pubkey; then
        log_info "已检测到公钥，跳过添加步骤"
    else
        log_step "第 1 步：添加 SSH 公钥"
        _ssh_add_pubkey_wizard || return 1
        _ssh_has_pubkey || { log_error "未成功添加公钥，向导已中止"; return 1; }
    fi

    log_step "第 2 步：禁用密码登录"
    ssh_disable_password
}

# ── Restore from backup ──────────────────────────────────────────────────────
ssh_restore_backup_menu() {
    _ssh_init
    local -a files=()
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$SSH_BACKUP_DIR"/sshd_config.* 2>/dev/null)
    if (( ${#files[@]} == 0 )); then
        log_warn "没有可用的历史备份"; return 0
    fi
    echo -e "\n${BOLD}历史 sshd_config 备份（新→旧）：${NC}"
    local i=0
    for f in "${files[@]}"; do i=$((i+1)); printf "  %2d. %s\n" "$i" "$(basename "$f")"; done

    local sel
    read -rp "$(echo -e "${CYAN}选择要恢复的备份（0=取消）: ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "无效选项"; return 1
    fi
    local chosen="${files[$((sel-1))]}"
    ask_yn "确认恢复到 $(basename "$chosen")？" N || return 0

    _ssh_backup >/dev/null   # snapshot current config first, just in case
    cp -a "$chosen" "$SSHD_CFG"
    local test_out
    if ! test_out=$(_ssh_test_config); then
        log_error "备份中的配置校验失败，未应用："; echo "$test_out"; return 1
    fi
    _ssh_reload
    rm -f "$SSH_ROLLBACK_STATE"
    log_ok "已恢复到备份：$(basename "$chosen")"
}

# ── Status ────────────────────────────────────────────────────────────────────
ssh_status() {
    echo -e "\n${BOLD}${BLUE}══ SSH 状态 ══════════════════════════════════${NC}"
    local ports pwauth pubkeyauth rootlogin
    ports=$(_ssh_ports)
    pwauth=$(_ssh_get passwordauthentication)
    pubkeyauth=$(_ssh_get pubkeyauthentication)
    rootlogin=$(_ssh_get permitrootlogin)

    echo -e "  监听端口：${ports:-22}"
    if [[ "$pwauth" == "no" ]]; then
        echo -e "  密码登录：${GREEN}已禁用（仅密钥）${NC}"
    else
        echo -e "  密码登录：${RED}仍启用${NC}"
    fi
    echo -e "  密钥登录：${pubkeyauth:-未知}"
    echo -e "  Root 登录策略：${rootlogin:-未知}"
    if _ssh_has_pubkey; then
        echo -e "  已配置公钥：${GREEN}是${NC}"
    else
        echo -e "  已配置公钥：${RED}否${NC}"
    fi

    local remaining
    if remaining=$(_ssh_pending_rollback_info); then
        local reason; reason=$(jq -r '.reason' "$SSH_ROLLBACK_STATE" 2>/dev/null)
        echo -e "  ${YELLOW}⚠ 有未确认的变更：${reason}（约 ${remaining} 秒后自动回滚）${NC}"
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
ssh_menu() {
    if ! command -v sshd &>/dev/null; then
        log_warn "未检测到 sshd，无法管理 SSH 配置"
        return 1
    fi
    while true; do
        ssh_status
        show_menu "SSH 安全加固" \
            "一键加固向导（推荐：添加公钥 + 禁用密码登录）" \
            "确认加固生效（取消自动回滚）" \
            "添加 SSH 公钥" \
            "禁用密码登录（仅密钥登录）" \
            "更改 SSH 端口" \
            "恢复历史备份"

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
