#!/usr/bin/env bash

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Verify the installed dispatch path remains machine-readable.
report="$(bash "$PSM_ROOT/manager.sh" node list --json)"
printf '%s' "$report" | jq -e '
    .api_version == 1 and
    (.count | type == "number") and
    (.items | type == "array") and
    (.count == (.items | length)) and
    ([.items[] | has("core") and has("protocol") and has("tag") and has("node")] | all)
' >/dev/null

# Run the complete mutation lifecycle against an isolated store. Source the
# public CLI after overriding common paths so no repository or system config is
# modified; --store-only also prevents core validation/restarts.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/node_cli.sh"

created="$(psm_node_cli node add xray ss2022 \
    --tag ci-ss2022 --port 31080 \
    --method 2022-blake3-aes-128-gcm --password ci-test-secret \
    --store-only --json)"
printf '%s' "$created" | jq -e '
    .status == "created" and
    .item.core == "xray" and
    .item.protocol == "ss2022" and
    .item.tag == "ci-ss2022" and
    .item.node.password == "***"
' >/dev/null

shown="$(psm_node_cli node show xray ss2022 ci-ss2022 --show-secrets --json)"
printf '%s' "$shown" | jq -e '
    .item.node.password == "ci-test-secret" and
    .item.node.port == 31080
' >/dev/null

updated="$(psm_node_cli node update xray ss2022 ci-ss2022 \
    --port 31081 --store-only --json)"
printf '%s' "$updated" | jq -e '
    .status == "updated" and
    .item.node.port == 31081 and
    .item.node.password == "***"
' >/dev/null

deleted="$(psm_node_cli node delete xray ss2022 ci-ss2022 \
    --yes --store-only --json)"
printf '%s' "$deleted" | jq -e '
    .status == "deleted" and .item.tag == "ci-ss2022"
' >/dev/null

empty="$(psm_node_cli node list --core xray --protocol ss2022 --json)"
printf '%s' "$empty" | jq -e '.count == 0 and .items == []' >/dev/null
jq -e '. == []' "$CFG_DIR/xray/ss2022.json" >/dev/null

# 直连节点改端口时 public_port 必须跟着走。分享链接取的是 public_port // port，
# 不同步就会导出一条指向旧端口的链接——节点在新端口监听，客户端连不上，而且
# 全流程没有任何报错。曾经在 vision / xhttp / trojan 上一起中招。
# 三个断言：直连跟随、显式 --public-port 优先、导出链接用的是新端口。
trojan_created="$(psm_node_cli node add xray trojan \
    --tag ci-trojan --port 34430 --domain trojan.example.com \
    --password 'ci-p@ss:w/rd' --store-only --json)"
printf '%s' "$trojan_created" | jq -e '
    .status == "created" and
    .item.node.public_port == 34430 and
    .item.node.password == "***"
' >/dev/null

trojan_moved="$(psm_node_cli node update xray trojan ci-trojan \
    --port 34431 --store-only --json)"
printf '%s' "$trojan_moved" | jq -e '
    .item.node.port == 34431 and .item.node.public_port == 34431
' >/dev/null || {
    echo "public_port did not follow a direct-listen port change" >&2
    exit 1
}

uri="$(psm_node_cli node export xray trojan ci-trojan --server 203.0.113.10)"
case "$uri" in
    trojan://ci-p%40ss%3Aw%2Frd@203.0.113.10:34431\?*) ;;
    *) echo "unexpected trojan share URI: $uri" >&2; exit 1 ;;
esac

trojan_pinned="$(psm_node_cli node update xray trojan ci-trojan \
    --port 34432 --public-port 443 --store-only --json)"
printf '%s' "$trojan_pinned" | jq -e '
    .item.node.port == 34432 and .item.node.public_port == 443
' >/dev/null || {
    echo "explicit --public-port was overwritten by the port sync" >&2
    exit 1
}

psm_node_cli node delete xray trojan ci-trojan --yes --store-only --json >/dev/null

# the name in clients (#10): the server's flag and the tag, or --display-name as it is
export PSM_SERVER_COUNTRY=JP
fail() { echo "FAIL: $*" >&2; exit 1; }
psm_node_cli node add xray ss2022 --tag ci-a --port 31090 \
    --method 2022-blake3-aes-128-gcm --password ci-test-secret --store-only --json >/dev/null
uri="$(psm_node_cli node export xray ss2022 ci-a --server 203.0.113.10)"
[[ "$uri" == *"#%F0%9F%87%AF%F0%9F%87%B5%20ci-a" ]] || fail "flag and tag: $uri"
psm_node_cli node add xray ss2022 --tag ci-b --port 31091 --display-name '东京 B ⚡' \
    --method 2022-blake3-aes-128-gcm --password ci-test-secret --store-only --json \
    | jq -e '.item.node.display_name == "东京 B ⚡"' >/dev/null || fail "--display-name on add"
uri="$(psm_node_cli node export xray ss2022 ci-b --server 203.0.113.10)"
[[ "$uri" == *"#$(url_encode '东京 B ⚡')" ]] || fail "display name: $uri"
long=$(printf 'x%.0s' {1..65})
for bad in 'a=b' 'a,b' $'a\nb' $'a\tb' ' a' 'a ' "$long" $'\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5 ci-a' ci-a; do
    if psm_node_cli node update xray ss2022 ci-b --display-name "$bad" --store-only --json >/dev/null 2>&1; then
        fail "--display-name '$bad' was taken"
    fi
done
psm_node_cli node show xray ss2022 ci-b --json | jq -e '.item.node.display_name == "东京 B ⚡"' >/dev/null \
    || fail "a refused --display-name changed the node"
psm_node_cli node update xray ss2022 ci-b --display-name '' --store-only --json >/dev/null
uri="$(psm_node_cli node export xray ss2022 ci-b --server 203.0.113.10)"
[[ "$uri" == *"#%F0%9F%87%AF%F0%9F%87%B5%20ci-b" ]] || fail "--display-name '' did not go back to the flag: $uri"
psm_node_cli node delete xray ss2022 ci-a --yes --store-only --json >/dev/null
psm_node_cli node delete xray ss2022 ci-b --yes --store-only --json >/dev/null

set +e
bash "$PSM_ROOT/manager.sh" node list --core not-a-core --json >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || {
    echo "node CLI usage error returned $rc instead of 2" >&2
    exit 1
}

echo "ok: node JSON contract, store-only CRUD, redaction, display names, and usage exit code"
