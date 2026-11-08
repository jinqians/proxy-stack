#!/usr/bin/env bash
# IP certificates (proxy-stack #9): the names lib/cert.sh takes, what it asks
# acme.sh for an IP, the import check, the shared 443, and doctor's expiry
# margin for a certificate that lives days, not months. Offline: acme.sh,
# Nginx and the firewall are stand-ins.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$PSM_ROOT/lib/cert.sh"
source "$PSM_ROOT/lib/doctor.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# names: a domain, a wildcard, an IPv4 address; never a path or a wildcard IP
for n in example.com '*.example.com' 203.0.113.5; do
    _cert_valid_name "$n" || fail "refused $n"
done
for n in '*.203.0.113.5' 203.0.113.256 '../conf.d' '203.0.113.5/..' '' 2001:db8::1; do
    ! _cert_valid_name "$n" || fail "accepted $n"
done

# the shared 443 routes by SNI, which a client connecting to an IP never sends
cert_name_shares_443 example.com || fail "a domain kept off the shared 443"
! cert_name_shares_443 203.0.113.5 2>/dev/null || fail "an IP put behind the shared 443"

# the account email an earlier PSM made up (admin@<hostname without a dot>,
# which Let's Encrypt refuses) leaves acme.sh's account.conf and every ca.conf
# before an issue; a real address, the other settings and the mode stay
ACME_HOME="$tmp_dir/acme"
le="$ACME_HOME/ca/acme-v02.api.letsencrypt.org/directory"; zs="$ACME_HOME/ca/acme.zerossl.com/v2/DV90"
mkdir -p "$le" "$zs"
printf "ACCOUNT_EMAIL='admin@alpha-317f2761d9'\nUPGRADE_HASH='h'\n" > "$ACME_HOME/account.conf"; chmod 600 "$ACME_HOME/account.conf"
printf "CA_EMAIL='admin@alpha-317f2761d9'\nCA_EAB_KEY_ID='k'\n" > "$le/ca.conf"
printf "CA_EMAIL='me@example.com'\n" > "$zs/ca.conf"
printf '#!/bin/sh\n' > "$ACME_HOME/acme.sh"; chmod +x "$ACME_HOME/acme.sh"
_acme --list 2>/dev/null
grep -q "admin@alpha" "$ACME_HOME/account.conf" || fail "the email was touched by a command that issues nothing"
_acme --issue -d example.com 2>/dev/null
[[ "$(cat "$ACME_HOME/account.conf")" == "UPGRADE_HASH='h'" ]] || fail "account.conf: $(cat "$ACME_HOME/account.conf")"
[[ "$(ls -l "$ACME_HOME/account.conf" | cut -c1-10)" == "-rw-------" ]] || fail "account.conf lost its mode"
[[ "$(cat "$le/ca.conf")" == "CA_EAB_KEY_ID='k'" ]] || fail "ca.conf: $(cat "$le/ca.conf")"
[[ "$(cat "$zs/ca.conf")" == "CA_EMAIL='me@example.com'" ]] || fail "a real address was removed"

# issuing for an IP: Let's Encrypt, the short-lived profile, renewal every 3 days
_acme() {
    case "$1" in
        --help) echo '  --cert-profile, --certificate-profile <profile>' ;;
        --issue) shift; printf '%s\n' "$*" >> "$tmp_dir/acme-args" ;;
    esac
}
is_installed() { return 1; }        # no Nginx: the standalone path
_fw_open80() { :; }
mkdir() { [[ "$*" == *" /var/www/"* ]] || command mkdir "$@"; }   # the webroot it would make
cert_install_domain() { echo "$1" > "$tmp_dir/installed"; }
_cert_http01_issue 203.0.113.5 &>/dev/null
[[ "$(cat "$tmp_dir/acme-args")" == "-d 203.0.113.5 --standalone --server letsencrypt --cert-profile shortlived --days 3" ]] \
    || fail "acme.sh args for an IP: $(cat "$tmp_dir/acme-args")"
[[ "$(cat "$tmp_dir/installed")" == 203.0.113.5 ]] || fail "IP certificate not installed"
rm -f "$tmp_dir/acme-args"
_cert_http01_issue example.com &>/dev/null
[[ "$(cat "$tmp_dir/acme-args")" == "-d example.com --standalone" ]] \
    || fail "acme.sh args for a domain changed: $(cat "$tmp_dir/acme-args")"

# an acme.sh too old for profiles is refused before it asks
_acme() { case "$1" in --help) echo '  --days <ndays>' ;; --issue) fail "issued with an old acme.sh" ;; esac; }
! _cert_http01_issue 203.0.113.5 &>/dev/null || fail "old acme.sh: issue went on"

# an imported IP certificate must name the IP
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 6 \
    -subj '/CN=ip' -addext 'subjectAltName=IP:203.0.113.5' \
    -keyout "$tmp_dir/ip.key" -out "$tmp_dir/ip.pem" 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
    -subj '/CN=example.com' -addext 'subjectAltName=DNS:example.com' \
    -keyout "$tmp_dir/dom.key" -out "$tmp_dir/dom.pem" 2>/dev/null
_cert_covers_ip "$tmp_dir/ip.pem" 203.0.113.5 || fail "IP certificate does not cover its IP"
! _cert_covers_ip "$tmp_dir/ip.pem" 203.0.113.6 || fail "IP certificate covers another IP"
! _cert_covers_ip "$tmp_dir/dom.pem" 203.0.113.5 || fail "domain certificate covers an IP"

# doctor: a 6-day certificate is expiring in its last 2 days, a 90-day one in its last 14
if date -d 'Jan 1 00:00:00 2026 GMT' +%s >/dev/null 2>&1; then
    m=$(_doctor_cert_margin "$tmp_dir/ip.pem")
    (( m == 6 * 86400 / 3 )) || fail "6-day margin $m"
    openssl x509 -in "$tmp_dir/ip.pem" -noout -checkend "$m" >/dev/null || fail "fresh IP certificate counted as expiring"
    m=$(_doctor_cert_margin "$tmp_dir/dom.pem")
    (( m == 1209600 )) || fail "90-day margin $m"
else
    echo "skip: doctor margin (this date has no -d)"
fi
[[ "$(_doctor_cert_margin /nonexistent)" == 1209600 ]] || fail "unreadable certificate margin"

echo "ok: IP certificates"
