#!/usr/bin/env bash
# PSM-managed — generated from templates/openvpn/vpngate-up.sh.tpl. Do not edit.
#
# OpenVPN 在隧道建立后调用（需要配置里的 script-security 2 + up/up-restart）。
# 全部路由只写进独立路由表，主表一个字节都不碰——SSH、面板、节点本身的出网
# 完全不受影响，只有打了 fwmark 或显式绑定到隧道网卡的连接才会走家宽出口。
set -u

TABLE="{{TABLE}}"
PRIO="{{PRIO}}"
MARK="{{MARK}}"
DEV="${dev:-{{DEV}}}"
GW="${route_vpn_gateway:-${ifconfig_remote:-}}"

if [ -n "$GW" ]; then
    ip route replace default via "$GW" dev "$DEV" table "$TABLE"
else
    ip route replace default dev "$DEV" table "$TABLE"
fi

# 兜底黑洞（metric 远高于隧道路由，隧道在时永远轮不到它）：隧道一断，网卡路由
# 随之消失，命中该表的流量直接失败而不是回落主表。宁可断，也不要顶着机房 IP
# 裸奔出去——解锁流量一旦漏出真实 IP，风控记住的就是那个 IP。
ip route replace blackhole default metric 4096 table "$TABLE"
ip -6 route replace blackhole default metric 4096 table "$TABLE" 2>/dev/null || true

# 两条规则各有分工：
#   fwmark → 代理核心（xray/sing-box/mihomo）给出站连接打的标记，核心以 root
#            运行且 systemd 单元带 CAP_NET_ADMIN，设 SO_MARK 没有权限问题；
#   oif    → 本机 root 进程显式绑定网卡时（curl --interface）用来查表。
# 刻意不用 SO_BINDTODEVICE 让核心绑网卡：那需要 CAP_NET_RAW，而三个核心的
# systemd 单元 CapabilityBoundingSet 里都没有它。
if ! ip rule list | grep -q "lookup $TABLE"; then
    ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO"
    ip rule add oif "$DEV" lookup "$TABLE" priority "$((PRIO + 1))"
fi
if ! ip -6 rule list 2>/dev/null | grep -q "lookup $TABLE"; then
    ip -6 rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO" 2>/dev/null || true
fi

exit 0
