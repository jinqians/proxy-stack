#!/usr/bin/env bash
# security/core.sh — Entry menu for the security/hardening modules

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

security_menu() {
    while true; do
        show_menu "安全加固" \
            "SSH 安全加固（密钥登录 / 改端口）" \
            "Fail2ban 防爆破" \
            "蜜罐诱捕"

        case "$MENU_CHOICE" in
            1) source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh";      ssh_menu ;;
            2) source "$(dirname "${BASH_SOURCE[0]}")/fail2ban.sh"; f2b_menu ;;
            3) source "$(dirname "${BASH_SOURCE[0]}")/honeypot.sh"; hp_menu ;;
            0) return ;;
        esac
    done
}
