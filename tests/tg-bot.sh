#!/usr/bin/env bash
# The Telegram bot with one bot on several servers (#14): which messages it
# acts on in a group, the 409 conflict said once a day, /list naming its
# server, and replies going through tg_send (plain text when Markdown fails).

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"; mkdir -p "$CFG_DIR/traffic"
source "$PSM_ROOT/lib/tg_bot.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# which text the bot acts on
TG_BOT_USERNAME=psm_hk_bot
own() { _tgbot_own_text "$1" "$2" || echo "<none>"; }
[[ "$(own private /list)" == /list ]]                       || fail "private /list"
[[ "$(own private /list@PSM_HK_bot)" == /list ]]            || fail "private /list@this bot"
[[ "$(own private 'tok-123 abc')" == 'tok-123 abc' ]]       || fail "private plain text (tenant binding) dropped"
[[ "$(own group /list)" == /list ]]                         || fail "group /list"
[[ "$(own supergroup '/traffic@psm_hk_bot 443')" == '/traffic 443' ]] || fail "group command for this bot"
[[ "$(own group /list@psm_jp_bot)" == '<none>' ]]           || fail "group command for another bot answered"
[[ "$(own private /list@psm_jp_bot)" == '<none>' ]]         || fail "private command for another bot answered"
[[ "$(own group 'hello everyone')" == '<none>' ]]           || fail "group chatter answered"
TG_BOT_USERNAME=""   # getMe did not answer: a command for some bot is taken
[[ "$(own group /list@psm_jp_bot)" == /list ]]              || fail "unknown own name: command dropped"

# the conflict: said in the journal and to the admins once a day, seen by the menu
told=0
tg_notify_admins() { told=$((told + 1)); [[ "$1" == *"vps1 · 203.0.113.5"* ]] || fail "notice without the server: $1"; }
TG_SERVER_LABEL="vps1 · 203.0.113.5"
! _tgbot_conflict_recent || fail "a conflict before any was seen"
_tgbot_conflict 2>"$tmp_dir/err"
[[ $told == 1 ]] || fail "first conflict: told $told"
grep -q "409" "$tmp_dir/err" || fail "nothing in the journal"
_tgbot_conflict_recent || fail "the menu does not see it"
_tgbot_conflict 2>/dev/null; _tgbot_conflict 2>/dev/null
[[ $told == 1 ]] || fail "told again within the day: $told"
echo $(( $(date +%s) - 90000 )) > "$TG_BOT_CONFLICT_SAID"
_tgbot_conflict 2>/dev/null
[[ $told == 2 ]] || fail "not told again a day later: $told"
echo $(( $(date +%s) - 700 )) > "$TG_BOT_CONFLICT"
! _tgbot_conflict_recent || fail "an old conflict still shown"

# /list names the server, in a code span (a _ in a hostname is no Markdown there)
TG_SERVER_LABEL="vps_1 · 203.0.113.5"
out=$(_tgbot_list_nodes)
[[ "$out" == *'🖥 `vps_1 · 203.0.113.5`'* ]] || fail "no server in the empty answer: $out"
printf '{"x-rea":{"port":31001,"accumulated_bytes":1073741824,"limit_bytes":0,"paused":false}}' > "$CFG_DIR/traffic/state.json"
out=$(_tgbot_list_nodes)
[[ "$out" == *'🖥 `vps_1 · 203.0.113.5`'* && "$out" == *x-rea* && "$out" == *31001* ]] || fail "/list: $out"

# replies go through tg_send
tg_send() { echo "$1|$2" > "$tmp_dir/sent"; }
_tgbot_send 42 "hello_world"
[[ "$(cat "$tmp_dir/sent")" == "42|hello_world" ]] || fail "_tgbot_send did not go through tg_send"

echo "ok: Telegram bot on several servers"
