#!/usr/bin/env bash

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$PSM_ROOT/tests/config-regression.sh"
"$PSM_ROOT/tests/doctor-smoke.sh"
"$PSM_ROOT/tests/node-cli-smoke.sh"
"$PSM_ROOT/tests/tg-notify.sh"
"$PSM_ROOT/tests/cert-ip.sh"
"$PSM_ROOT/tests/gost-version.sh"
"$PSM_ROOT/tests/client-exports.sh"
