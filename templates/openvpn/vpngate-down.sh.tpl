#!/usr/bin/env bash
# PSM-managed — generated from templates/openvpn/vpngate-down.sh.tpl. Do not edit.
#
# 只撤掉走隧道的那条默认路由，保留黑洞兜底与 ip rule：隧道掉线期间命中该表的
# 流量继续快速失败（而不是漏回机房 IP），看门狗换好节点后自动恢复。
# 规则与路由表的彻底清理在「断开并移除」里做。
set -u

TABLE="{{TABLE}}"
DEV="${dev:-{{DEV}}}"

ip route del default dev "$DEV" table "$TABLE" 2>/dev/null || true

exit 0
