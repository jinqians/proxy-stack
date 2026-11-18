#!/usr/bin/env bash
# gost's version as PSM reads it from `gost -V`. Its form changed after 3.3.0
# ("gost v3.3.0 (…)" → "gost 3.3.3 (…)"); read as nothing, a fresh install was
# refused as "older than 3.3.0" and no gost relay or tunnel could be made.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$PSM_ROOT/lib/gost.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
GOST_BIN="$tmp_dir/gost"
says() { printf '#!/bin/sh\necho "%s"\n' "$1" > "$GOST_BIN"; chmod +x "$GOST_BIN"; }

says 'gost v3.3.0 (go1.25.1 linux/amd64)'
[[ "$(gost_version)" == 3.3.0 ]] || fail "3.3.0's form read as '$(gost_version)'"
_gost_new_enough || fail "3.3.0 not new enough"
says 'gost 3.3.3 (go1.27.3 linux/amd64)'
[[ "$(gost_version)" == 3.3.3 ]] || fail "3.3.3's form read as '$(gost_version)'"
_gost_new_enough || fail "3.3.3 not new enough"
says 'gost v3.2.6 (go1.24 linux/amd64)'
! _gost_new_enough || fail "3.2.6 counted as new enough"
says 'gost 2.12.0 (go1.22 linux/amd64)'   # gost v2, as other relay scripts install it
! _gost_new_enough || fail "gost v2 counted as new enough"
says 'something else'
[[ -z "$(gost_version)" ]] || fail "read a version from another program"
! _gost_new_enough || fail "an unreadable version counted as new enough"

echo "ok: gost version"
