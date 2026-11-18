#!/usr/bin/env bash

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# offline: the names of nodes do without the flag of the server's country
export PSM_SERVER_COUNTRY="${PSM_SERVER_COUNTRY-}"

"$PSM_ROOT/tests/config-regression.sh"
"$PSM_ROOT/tests/doctor-smoke.sh"
"$PSM_ROOT/tests/node-cli-smoke.sh"
"$PSM_ROOT/tests/tg-notify.sh"
"$PSM_ROOT/tests/cert-ip.sh"
"$PSM_ROOT/tests/gost-version.sh"
"$PSM_ROOT/tests/client-exports.sh"
"$PSM_ROOT/tests/tg-bot.sh"
