#!/usr/bin/env bash
# security/core.sh — Entry menu for the security/hardening modules

if [[ -z "${PSM_ROOT:-}" ]]; then
    _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    source "$_D/common.sh"
    unset _D
fi

security_menu() {
    while true; do
        show_menu "$(t security.menu.title)" \
            "$(t security.menu.ssh)" \
            "$(t security.menu.fail2ban)" \
            "$(t security.menu.honeypot)"

        case "$MENU_CHOICE" in
            1) source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh";      ssh_menu ;;
            2) source "$(dirname "${BASH_SOURCE[0]}")/fail2ban.sh"; f2b_menu ;;
            3) source "$(dirname "${BASH_SOURCE[0]}")/honeypot.sh"; hp_menu ;;
            0) return ;;
        esac
    done
}
