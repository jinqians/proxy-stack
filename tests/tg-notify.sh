#!/usr/bin/env bash
# Telegram pushes (lib/tgbot/notify.sh through the health report) against a
# stand-in curl: what Telegram answers decides what PSM reports, and it never
# says "sent" when nothing went (proxy-stack #12).

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# The stand-in answers request n with line n of $FAKE_TG_ANSWERS and notes
# the requests that asked for Markdown.
mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE_TG_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_TG_COUNT"
for a in "$@"; do [[ "$a" == parse_mode=* ]] && echo "$n $a" >> "$FAKE_TG_LOG"; done
sed -n "${n}p" "$FAKE_TG_ANSWERS"
EOF
chmod +x "$tmp_dir/bin/curl"
export PATH="$tmp_dir/bin:$PATH"
export FAKE_TG_ANSWERS="$tmp_dir/answers" FAKE_TG_COUNT="$tmp_dir/count" FAKE_TG_LOG="$tmp_dir/log"

source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
mkdir -p "$CFG_DIR"
source "$PSM_ROOT/lib/tgbot/health_report.sh"
hr_build_report() { printf 'report for node_a'; }   # only the sending is under test

fail() { echo "FAIL: $*" >&2; exit 1; }
requests() { cat "$FAKE_TG_COUNT" 2>/dev/null || echo 0; }
reset() { rm -f "$FAKE_TG_COUNT" "$FAKE_TG_LOG"; printf '%s\n' "$@" > "$FAKE_TG_ANSWERS"; }
send() { rc=0; hr_send_report 2>"$tmp_dir/err" || rc=$?; }
said() { grep -qF -- "$1" "$tmp_dir/err" || fail "expected on stderr: $1 (got: $(cat "$tmp_dir/err"))"; }

# no bot configured
reset; send
[[ $rc == 1 ]] || fail "no bot: rc $rc"
said "$(t tgbot.hr.no_bot)"
[[ $(requests) == 0 ]] || fail "no bot: Telegram was called"

# a bot whose admin list is empty ("everyone is an admin"): nobody to send to
printf 'TG_BOT_TOKEN="123:abc"\nTG_ADMIN_IDS=""\n' > "$CFG_DIR/tg_bot.conf"
reset; send
[[ $rc == 1 ]] || fail "no admin: rc $rc"
said "$(t tgbot.hr.no_admin)"
[[ $(requests) == 0 ]] || fail "no admin: Telegram was called"

# two admins: the first one's Markdown is refused and goes again as plain
# text; the second never talked to the bot
printf 'TG_BOT_TOKEN="123:abc"\nTG_ADMIN_IDS="111, 222"\n' > "$CFG_DIR/tg_bot.conf"
reset '{"ok":false,"error_code":400,"description":"Bad Request: can'"'"'t parse entities: Can'"'"'t find end of the entity starting at byte offset 16"}' \
      '{"ok":true,"result":{"message_id":1}}' \
      '{"ok":false,"error_code":403,"description":"Forbidden: bot can'"'"'t initiate conversation with a user"}'
send
[[ $rc == 0 ]] || fail "one of two delivered: rc $rc"
[[ $TG_NOTIFY_SENT == 1 ]] || fail "sent count $TG_NOTIFY_SENT"
[[ ${#TG_NOTIFY_ERRORS[@]} == 1 && ${TG_NOTIFY_ERRORS[0]} == "222: Forbidden: bot can't initiate conversation with a user" ]] \
    || fail "errors: ${TG_NOTIFY_ERRORS[*]}"
[[ $(requests) == 3 ]] || fail "requests: $(requests)"
grep -qx '1 parse_mode=Markdown' "$FAKE_TG_LOG" || fail "first request not Markdown"
! grep -q '^2 ' "$FAKE_TG_LOG" || fail "the retry still asked for Markdown"
said "$(t tgbot.hr.send_failed "222: Forbidden: bot can't initiate conversation with a user")"
said "$(t tgbot.hr.hint_start)"
said "$(t tgbot.hr.sent 1)"

# Telegram unreachable: curl's own error is the reason
printf 'TG_BOT_TOKEN="123:abc"\nTG_ADMIN_IDS="111"\n' > "$CFG_DIR/tg_bot.conf"
reset 'curl: (28) Connection timed out after 10001 milliseconds'
send
[[ $rc == 1 ]] || fail "unreachable: rc $rc"
said "111: curl: (28) Connection timed out"

# the notifiers other modules call still never fail their caller
reset ''
tg_notify_admins "x" || fail "tg_notify_admins returned non-zero"
tg_send 111 "x" || fail "tg_send returned non-zero"
[[ $TG_SEND_ERROR == "no answer from api.telegram.org" ]] || fail "empty answer: $TG_SEND_ERROR"

echo "ok: Telegram push outcomes"
