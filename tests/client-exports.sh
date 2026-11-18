#!/usr/bin/env bash
# What PSM hands clients for the cores of November 2026 (measured on a server:
# Xray v26.11.9, sing-box 1.14.4, mihomo v1.19.34):
# - a mihomo client reaches an Xray REALITY node (v26.9.8 on) only with
#   support-x25519mlkem768 in reality-opts; the other servers take it too;
# - a sing-box client reaches an Xray VMess node with a named cipher, not "auto".

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PSM_ROOT/lib/common.sh"
source "$PSM_ROOT/lib/subscribe.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

reality='{"tag":"r1","port":31001,"uuid":"11111111-2222-3333-4444-555555555555","flow":"xtls-rprx-vision",
          "server_name":"learn.microsoft.com","dest":"learn.microsoft.com:443","public_key":"PUB","short_ids":["1847e055"]}'
for core in xray sing-box mihomo; do
    px=$(_sub_mh_proxy "$core" reality "$reality" 203.0.113.5 r1)
    jq -e '."reality-opts" == {"public-key": "PUB", "short-id": "1847e055", "support-x25519mlkem768": true}
           and ."client-fingerprint" == "chrome" and .flow == "xtls-rprx-vision"' <<<"$px" >/dev/null \
        || fail "$core REALITY for mihomo: $px"
done

layer='{"tag":"x1","port":31008,"uuid":"11111111-2222-3333-4444-555555555555","mode":"reality-layer","reality_transport":"xhttp",
        "server_name":"learn.microsoft.com","public_key":"PUB","short_id":"ab","path":"/p"}'
px=$(_sub_mh_proxy xray xhttp "$layer" 203.0.113.5 x1)
jq -e '."reality-opts"."support-x25519mlkem768" == true and .network == "xhttp"' <<<"$px" >/dev/null \
    || fail "the REALITY layer for mihomo: $px"

# a node without REALITY gets no reality-opts from this
px=$(_sub_mh_proxy xray vision '{"tag":"v1","port":31002,"uuid":"u","flow":"xtls-rprx-vision","domain":"x.example.com"}' 203.0.113.5 v1)
jq -e 'has("reality-opts") | not' <<<"$px" >/dev/null || fail "Vision got reality-opts: $px"

# sing-box: an Xray REALITY node only while the Xray is older than v26.9.8
tmp_dir="$(mktemp -d)"; trap 'rm -rf "$tmp_dir"' EXIT
XRAY_BIN="$tmp_dir/xray"
xray_says() { printf '#!/bin/sh\necho "Xray %s (Xray, Penetrates Everything.)"\n' "$1" > "$XRAY_BIN"; chmod +x "$XRAY_BIN"; }
xray_says 26.11.9
[[ -z "$(_sub_sb_outbound xray reality "$reality" 203.0.113.5 r1)" ]] || fail "sing-box got an Xray v26.11.9 REALITY node"
xray_says 26.9.8
[[ -z "$(_sub_sb_outbound xray reality "$reality" 203.0.113.5 r1)" ]] || fail "sing-box got an Xray v26.9.8 REALITY node"
xray_says 26.3.27
_sub_sb_outbound xray reality "$reality" 203.0.113.5 r1 | jq -e '.type == "vless" and .tls.reality.enabled' >/dev/null \
    || fail "sing-box lost the REALITY node of an Xray v26.3.27"
rm -f "$XRAY_BIN"
[[ -z "$(_sub_sb_outbound xray reality "$reality" 203.0.113.5 r1)" ]] || fail "sing-box got an Xray REALITY node with no Xray to ask"
for core in sing-box mihomo; do
    _sub_sb_outbound "$core" reality "$reality" 203.0.113.5 r1 | jq -e '.type == "vless"' >/dev/null \
        || fail "sing-box lost the REALITY node of $core"
done

# the links: mihomo's importer reads support-x25519mlkem768 (Xray's REALITY only)
source "$PSM_ROOT/lib/node_cli.sh"
link=$(_node_cli_export_uri xray reality "$reality" 203.0.113.5)
[[ "$link" == *"&sid=1847e055&support-x25519mlkem768=true&type=tcp#PSM-r1" ]] || fail "Xray REALITY link: $link"
link=$(_node_cli_export_uri sing-box reality "$reality" 203.0.113.5)
[[ "$link" != *support-x25519mlkem768* && "$link" == *"&sid=1847e055&type=tcp#PSM-r1" ]] || fail "sing-box REALITY link: $link"
source "$PSM_ROOT/lib/xray/xhttp.sh"
link=$(_xhttp_share_uri "$layer" 203.0.113.5 31008)
[[ "$link" == *"&support-x25519mlkem768=true"* ]] || fail "REALITY-layer link: $link"

vmess='{"tag":"m1","port":31011,"uuid":"11111111-2222-3333-4444-555555555555","domain":"x.example.com","path":"/w"}'
ob=$(_sub_sb_outbound_plain xray vmess "$vmess" 203.0.113.5 m1)
jq -e '.type == "vmess" and .security == "chacha20-poly1305" and .transport == {"type": "ws", "path": "/w"}' <<<"$ob" >/dev/null \
    || fail "VMess for sing-box: $ob"

echo "ok: client exports"
