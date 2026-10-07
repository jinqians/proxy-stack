#!/usr/bin/env bash
# Snapshot regression tests for pure protocol config builders.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$PSM_ROOT/tests/fixtures/node-builders.json"
SNAPSHOT_DIR="$PSM_ROOT/tests/snapshots"

for cmd in bash jq diff; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "missing test dependency: $cmd" >&2
        exit 2
    }
done

# Sourcing these modules only declares functions and constants. The builders
# exercised below do not touch systemd, the network, or privileged paths.
source "$PSM_ROOT/lib/xray/reality.sh"
source "$PSM_ROOT/lib/xray/vision.sh"
source "$PSM_ROOT/lib/xray/trojan.sh"
source "$PSM_ROOT/lib/xray/vmess.sh"
source "$PSM_ROOT/lib/xray/socks.sh"
source "$PSM_ROOT/lib/xray/xhttp.sh"
source "$PSM_ROOT/lib/singbox/reality.sh"
source "$PSM_ROOT/lib/singbox/snell.sh"
source "$PSM_ROOT/lib/singbox/trojan.sh"
source "$PSM_ROOT/lib/singbox/vmess.sh"
source "$PSM_ROOT/lib/singbox/socks.sh"
source "$PSM_ROOT/lib/singbox/vless.sh"
source "$PSM_ROOT/lib/mihomo/reality.sh"
source "$PSM_ROOT/lib/mihomo/trojan.sh"
source "$PSM_ROOT/lib/mihomo/vmess.sh"
source "$PSM_ROOT/lib/mihomo/socks.sh"
source "$PSM_ROOT/lib/mihomo/vless.sh"
source "$PSM_ROOT/lib/xray/outbound.sh"
source "$PSM_ROOT/lib/singbox/routing.sh"
source "$PSM_ROOT/lib/mihomo/routing.sh"
source "$PSM_ROOT/lib/ruleset/apply.sh"
source "$PSM_ROOT/lib/xray/routing.sh"
source "$PSM_ROOT/lib/xray/hysteria2.sh"
source "$PSM_ROOT/lib/singbox/hysteria2.sh"
source "$PSM_ROOT/lib/mihomo/hysteria2.sh"
source "$PSM_ROOT/lib/singbox/tuic.sh"
source "$PSM_ROOT/lib/mihomo/tuic.sh"
source "$PSM_ROOT/lib/singbox/wireguard.sh"
source "$PSM_ROOT/lib/mihomo/ss2022.sh"
source "$PSM_ROOT/lib/mihomo/snell.sh"
source "$PSM_ROOT/lib/gost.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

passed=0

assert_snapshot() {
    local name="$1" fixture_key="$2" builder="$3"
    local node actual expected
    node="$(jq -c --arg key "$fixture_key" '.[$key]' "$FIXTURE")"
    actual="$tmp_dir/${name}.json"
    expected="$SNAPSHOT_DIR/${name}.json"

    "$builder" "$node" | jq -S . > "$actual"
    jq -e . "$actual" >/dev/null

    if [[ "${UPDATE_SNAPSHOTS:-0}" == "1" ]]; then
        cp "$actual" "$expected"
        echo "updated: $name"
    elif [[ ! -f "$expected" ]]; then
        echo "missing snapshot: $expected" >&2
        echo "run UPDATE_SNAPSHOTS=1 tests/config-regression.sh" >&2
        return 1
    elif ! diff -u "$expected" "$actual"; then
        echo "snapshot mismatch: $name" >&2
        echo "review the diff, then run UPDATE_SNAPSHOTS=1 tests/config-regression.sh if intentional" >&2
        return 1
    else
        echo "ok: $name"
    fi

    passed=$((passed + 1))
}

assert_snapshot xray-reality xray_reality _reality_build_inbound
assert_snapshot xray-vision xray_vision _vision_build_inbound
# Trojan 的入站删除条件必须按 protocol == "trojan" 精确匹配。照抄 vision 里那条
# 「security=tls 且 network=tcp」的兜底会把 Vision 自己的入站一并删掉——两者的
# streamSettings 完全同构，只有 protocol 字段能区分。快照钉住生成结果。
assert_snapshot xray-trojan xray_trojan _trojan_build_inbound
# minClientVer 只在节点显式设过时才写入 realitySettings：未设置的 xray-reality
# 快照必须不含该字段（老内核不认识它，且新内核有自己的默认值）。
assert_snapshot xray-reality-min-client-ver xray_reality_min_client_ver _reality_build_inbound
assert_snapshot singbox-reality singbox_reality _sb_reality_build_inbound
# Snell 入站只接受 obfs_mode；obfs_host 是 outbound 专属字段，混进入站会让
# sing-box 报 `unknown field "obfs_host"` 并拒绝整份配置。快照锁住这一点。
assert_snapshot singbox-snell-v5-obfs singbox_snell_v5_obfs _sb_snell_build_inbound
assert_snapshot singbox-snell-v6 singbox_snell_v6 _sb_snell_build_inbound
assert_snapshot mihomo-reality mihomo_reality _mh_reality_build_listener
# Trojan 入站在三个内核里的用户字段结构互不相同，写错会让内核拒绝整份配置：
#   Xray      settings.clients[]  = [{password}]
#   sing-box  users[]             = [{name, password}]
#   mihomo    users[]             = [{username, password}]  ← 不是 anytls/hysteria2
#                                    那种 {"u1": pass} 映射
# 三张快照把这三种形状分别钉死。
assert_snapshot singbox-trojan singbox_trojan _sb_trojan_build_inbound
assert_snapshot mihomo-trojan mihomo_trojan _mh_trojan_build_listener

# VMess 的三处内核差异，写错任何一处内核都会拒绝整份配置：
#   1. 用户字段：Xray  settings.clients[] = [{id}]（无 alterId，1.8+ 只认 AEAD）
#              sing-box users[] = [{name, uuid, alterId}]
#              mihomo   users[] = [{username, uuid, alterId}]
#   2. WS 路径：Xray  streamSettings.wsSettings.path
#              sing-box transport: {type:"ws", path}
#              mihomo   顶层 ws-path（不是嵌套块）
#   3. 传输名：Xray 用 "websocket"（与本项目 xhttp.sh 的 ws 模式一致）
assert_snapshot xray-vmess xray_vmess _vmess_build_inbound
assert_snapshot singbox-vmess singbox_vmess _sb_vmess_build_inbound
assert_snapshot mihomo-vmess mihomo_vmess _mh_vmess_build_listener

# SOCKS5 的两处易错点：
#   1. 免认证时 users 必须是【空数组】而不是 null —— 写 null 会让 sing-box /
#      mihomo 报类型错误并拒绝整份配置。singbox-socks 这张快照就是免认证的。
#   2. Xray 的 auth 字段只有 noauth / password 两个取值，且写 password 时
#      accounts 不能为空，否则表现为「能连上但一律认证失败」。
assert_snapshot xray-socks xray_socks _socks_build_inbound
assert_snapshot singbox-socks singbox_socks _sb_socks_build_inbound
assert_snapshot mihomo-socks mihomo_socks _mh_socks_build_listener

# VLESS 传输组合。四张快照分别锁住：
#   httpupgrade  network=httpupgrade + httpupgradeSettings{path,host}
#                （区别于 mode=upgrade —— 那个历史命名产出的其实是 WebSocket）
#   h2           network=http + httpSettings.host 是【数组】，alpn 只能有 h2
#   mkcp         network=kcp + security=none（必须显式写，省略会走 TLS 分支）
#                且不带 tlsSettings / fallbacks
#   reality      security=reality 与传输层解耦；Xray 只接受 RAW / XHTTP / gRPC
#
# 以下几处都是用真实内核（Xray v26.3.27 / v26.9.9）校验后改的，见 tests/core-validate.sh：
#   h2      旧 HTTP 传输已被 Xray 移除 → 改由 XHTTP stream-one 承载（network=xhttp）
#   mkcp    seed/header 有三种写法（kcpSettings / finalmask mkcp-aes128gcm / mkcp-legacy），运行时由 _xray_kcp_form 探测本机
#           内核二选一；这里两条分支都打桩，结果不随测试机上装没装 Xray 而变
#   reality+ws  Xray 会拒绝整份配置；store 里残留的 ws 值必须落到 xhttp，快照钉住这一点
assert_snapshot xray-xhttp-httpupgrade xray_xhttp_httpupgrade _xhttp_build_inbound
assert_snapshot xray-xhttp-h2 xray_xhttp_h2 _xhttp_build_inbound
# hermetic: neither the form nor the mask order may depend on an Xray installed
# where the tests run (the full suites run them after installing v26.3.27)
_xhttp_build_kcp_legacy()     { ( _xray_kcp_form() { printf legacy; };      _xray_masks_reversed() { return 1; }; _xhttp_build_inbound "$1" ); }
_xhttp_build_kcp_finalmask()  { ( _xray_kcp_form() { printf finalmask; };   _xray_masks_reversed() { return 0; }; _xhttp_build_inbound "$1" ); }
_xhttp_build_kcp_mkcplegacy() { ( _xray_kcp_form() { printf mkcp-legacy; }; _xray_masks_reversed() { return 1; }; _xhttp_build_inbound "$1" ); }
assert_snapshot xray-xhttp-mkcp             xray_xhttp_mkcp _xhttp_build_kcp_legacy
assert_snapshot xray-xhttp-mkcp-finalmask   xray_xhttp_mkcp _xhttp_build_kcp_finalmask
assert_snapshot xray-xhttp-mkcp-mkcplegacy  xray_xhttp_mkcp _xhttp_build_kcp_mkcplegacy
assert_snapshot xray-xhttp-reality-ws   xray_xhttp_reality_ws   _xhttp_build_inbound
assert_snapshot xray-xhttp-reality-grpc xray_xhttp_reality_grpc _xhttp_build_inbound

# 四种「老」传输模式的输出快照。加新传输时 _xhttp_build_inbound 的 case 被整体重写过，
# 当时漏掉了 grpc 分支——它直接掉进 die，而当时没有任何快照覆盖这几个模式，CI 全绿。
# 这四张就是补上的那道网：改这个函数时它们必须一字不变。
assert_snapshot xray-xhttp-legacy-xhttp   xray_xhttp_legacy   _xhttp_build_inbound
assert_snapshot xray-xhttp-legacy-upgrade xray_upgrade_legacy _xhttp_build_inbound
assert_snapshot xray-xhttp-legacy-grpc    xray_grpc_legacy    _xhttp_build_inbound
assert_snapshot xray-xhttp-legacy-reality xray_reality_legacy _xhttp_build_inbound

# 出口分流：新增的 catch-all 规则类型，以及原有 geosite 类型未被波及。
# catch-all 靠一条只声明 network 的 field 规则实现——Xray 没有 catch-all 关键字，
# 若误写成带空 domain 数组的规则会永远不命中。
assert_snapshot xray-route-all     xray_route_all     _route_build_xray_rule
assert_snapshot xray-route-geosite xray_route_geosite _route_build_xray_rule

# VLESS 多传输。两边的传输表达方式完全不同，且各自支持的传输集合也不同——
#   sing-box：嵌套 transport 块；有 quic，【没有】xhttp
#   mihomo：  顶层字段 ws-path / grpc-service-name / xhttp-config；有 xhttp，【没有】h2 和 httpupgrade
# flow 只在 tcp 传输下写：Vision 是 TCP 上的流控，套进 ws/grpc 客户端对不上。
# 以下每种组合都用真实内核验过（sing-box check / mihomo 实跑监听）。
assert_snapshot singbox-vless-vision singbox_vless_vision _sb_vless_build_inbound
assert_snapshot singbox-vless-ws     singbox_vless_ws     _sb_vless_build_inbound
assert_snapshot singbox-vless-grpc   singbox_vless_grpc   _sb_vless_build_inbound
assert_snapshot singbox-vless-h2     singbox_vless_h2     _sb_vless_build_inbound
assert_snapshot singbox-vless-hu     singbox_vless_hu     _sb_vless_build_inbound
assert_snapshot singbox-vless-quic   singbox_vless_quic   _sb_vless_build_inbound
assert_snapshot mihomo-vless-vision  mihomo_vless_vision  _mh_vless_build_listener
assert_snapshot mihomo-vless-ws      mihomo_vless_ws      _mh_vless_build_listener
assert_snapshot mihomo-vless-grpc    mihomo_vless_grpc    _mh_vless_build_listener
assert_snapshot mihomo-vless-xhttp   mihomo_vless_xhttp   _mh_vless_build_listener

# VPNGate 家宽出口：三个核心的出站都只是「直连 + fwmark」，锁死这一点——写成
# 绑定网卡（SO_BINDTODEVICE）会因为核心 systemd 单元没有 CAP_NET_RAW 而失败。
assert_snapshot xray-vpngate xray_vpngate _outb_build_xray
assert_snapshot mihomo-vpngate mihomo_vpngate _mh_outb_build
# sing-box 分两条分支快照：1.12 之前用 dial 字段 domain_strategy，1.12+ 改用
# domain_resolver（domain_strategy 已在 1.14 移除）。两条分支都在子 shell 里给
# _sb_installed_version 打桩（旧分支 = 空版本号，等同未安装），结果不能随测试机
# 上装没装 sing-box 而变——之前旧分支没打桩，装了 sing-box 1.14 的机器上必挂。
_sb_outb_build_legacy() { ( _sb_installed_version() { printf ''; }; _sb_outb_build "$1" ); }
assert_snapshot singbox-vpngate-legacy singbox_vpngate _sb_outb_build_legacy
_sb_outb_build_v114() { ( _sb_installed_version() { printf '1.14.0'; }; _sb_outb_build "$1" ); }
assert_snapshot singbox-vpngate singbox_vpngate _sb_outb_build_v114

# 订阅式规则集：解析器要稳定（去重、排序、丢弃客户端专用类型、给裸 IP 补掩码），
# 生成的 sing-box 规则集必须是【两条】headless rule——域名和 IP 写进同一条是 AND
# 语义，永远不会命中；域名三兄弟同属一个匹配器放一起才是 OR。
_rs_parse_fixture() { local f; f=$(mktemp); jq -r '.list' <<<"$1" > "$f"; rs_parse "$f"; rm -f "$f"; }
assert_snapshot ruleset-parse ruleset_raw _rs_parse_fixture
assert_snapshot ruleset-singbox-source ruleset_parsed _rs_sb_source_json

# Xray 内联展开：必须是【两条】规则（域名一条、IP 一条）。同一条 rule 里 domain 与
# ip 是 AND 语义，合并写会让规则永远不触发——快照就是用来钉死这一点的。
_route_build_xray_ruleset() {
    local saved="$CFG_DIR" dir="$tmp_dir/ruleset/parsed"
    mkdir -p "$dir"
    jq -c '.parsed' <<<"$1" > "$dir/openai.json"
    CFG_DIR="$tmp_dir"
    _route_build_xray_rule "$(jq -c '.rule' <<<"$1")"
    CFG_DIR="$saved"
}
assert_snapshot ruleset-xray-inline xray_ruleset _route_build_xray_ruleset

# Hysteria2 QUIC 混淆。salamander 是老节点的隐含默认（obfs_type 缺省时），gecko 是
# sing-box 1.14 / mihomo 1.19.26 起的新类型；Xray 没有单独的 gecko 类型，而是
# finalmask 里 salamander + packetSize。Xray 的 Hy2 入站是 v26.3.27 新增的。
# 全部用真实内核校验过（tests/core-validate.sh）。
assert_snapshot singbox-hy2-salamander singbox_hy2_salamander _sb_hy2_build_inbound
assert_snapshot singbox-hy2-gecko      singbox_hy2_gecko      _sb_hy2_build_inbound
assert_snapshot mihomo-hy2-salamander  mihomo_hy2_salamander  _mh_hy2_build_listener
assert_snapshot mihomo-hy2-gecko       mihomo_hy2_gecko       _mh_hy2_build_listener
assert_snapshot xray-hy2-plain         xray_hy2_plain         _xhy2_build_inbound
assert_snapshot xray-hy2-gecko         xray_hy2_gecko         _xhy2_build_inbound
assert_snapshot singbox-tuic           singbox_tuic           _sb_tuic_build_inbound
assert_snapshot mihomo-tuic            mihomo_tuic            _mh_tuic_build_listener
assert_snapshot singbox-wireguard      singbox_wireguard      _sb_wg_build_endpoint
assert_snapshot singbox-hy2-ech        singbox_hy2_ech        _sb_hy2_build_inbound
assert_snapshot mihomo-hy2-ech         mihomo_hy2_ech         _mh_hy2_build_listener

# Hysteria2 BBR 配置档（服务端发送方向）：sing-box 1.14 的 bbr_profile、mihomo 1.19.24
# 的 bbr-profile、Xray v26.4.13 的 finalmask.quicParams.bbrProfile——Xray 那边要与
# 混淆的 finalmask.udp 并存在同一个 finalmask 里，没有混淆时 finalmask 只有 quicParams。
assert_snapshot singbox-hy2-bbr        singbox_hy2_bbr        _sb_hy2_build_inbound
assert_snapshot mihomo-hy2-bbr         mihomo_hy2_bbr         _mh_hy2_build_listener
assert_snapshot xray-hy2-bbr           xray_hy2_bbr           _xhy2_build_inbound
assert_snapshot xray-hy2-bbr-plain     xray_hy2_bbr_plain     _xhy2_build_inbound
# 关闭 QUIC 路径 MTU 探测（#7）：sing-box 1.14 的 disable_path_mtu_discovery、Xray 的
# finalmask.quicParams.disablePathMTUDiscovery（与 bbrProfile、混淆并存；只有它时
# finalmask 里只有 quicParams）。mihomo 没有这个选项。
assert_snapshot singbox-hy2-pmtud      singbox_hy2_pmtud      _sb_hy2_build_inbound
assert_snapshot xray-hy2-pmtud         xray_hy2_pmtud         _xhy2_build_inbound
assert_snapshot xray-hy2-pmtud-plain   xray_hy2_pmtud_plain   _xhy2_build_inbound

# VLESS Encryption（后量子）：decryption 串原样写进入站；Vision / XHTTP 启用后
# fallbacks 必须清空——Xray 规定两者互斥（两张夹具都故意开着 fallback_enabled）。
# mihomo vless listener 用同一种串格式（由 mihomo generate 的裸密钥拼出）。
assert_snapshot xray-vision-enc  xray_vision_enc  _vision_build_inbound
assert_snapshot xray-reality-enc xray_reality_enc _reality_build_inbound
assert_snapshot xray-xhttp-enc   xray_xhttp_enc   _xhttp_build_inbound
# mKCP 默认带 VLESS Encryption（Xray v26.7.7 起客户端拒绝无 TLS 的明文 VLESS）；
# seed/header 两种写法与 xray-xhttp-mkcp 一样成对钉住
assert_snapshot xray-xhttp-mkcp-enc             xray_xhttp_mkcp_enc _xhttp_build_kcp_legacy
assert_snapshot xray-xhttp-mkcp-enc-finalmask   xray_xhttp_mkcp_enc _xhttp_build_kcp_finalmask
assert_snapshot xray-xhttp-mkcp-enc-mkcplegacy  xray_xhttp_mkcp_enc _xhttp_build_kcp_mkcplegacy
assert_snapshot mihomo-vless-enc mihomo_vless_enc _mh_vless_build_listener

# ShadowTLS v3（mihomo listener）：users 是 [{name, password}]，握手目标写在
# handshake.dest（host:port）；snell 上它与 obfs-opts 互斥，快照钉住只出现 shadow-tls。
assert_snapshot mihomo-ss-stls    mihomo_ss_stls    _mh_ss_build_listener
assert_snapshot mihomo-snell-stls mihomo_snell_stls _mh_snell_build_listener

# Relays (psm relay): one store, two engines. gost's config carries its rules
# only — forwards with their selector (and TCP probes when there is more than
# one target and the probe is not turned off), a rate limit in bytes a second,
# the tunnel's exit (relay handler with a password, its own targets, the
# transport's path) and entry (one chain, without nodelay, which loses the
# client's data; the exit's certificate pinned, skipped, or verified by name). realm's takes the realm
# rules: extra targets as extra_remotes with a balance, the old TLS hop.
_relay_gost_config() { gost_gen_config "$1"; }
_relay_realm_toml() {
    local store="$REALM_STORE" toml="$REALM_TOML" dir="$REALM_CFG_DIR"
    REALM_STORE="$tmp_dir/relay-rules.json"; REALM_CFG_DIR="$tmp_dir/realm"; REALM_TOML="$REALM_CFG_DIR/config.toml"
    printf '%s\n' "$1" > "$REALM_STORE"
    _realm_gen_toml
    grep -v '^#' "$REALM_TOML" | jq -R -s 'split("\n")'
    REALM_STORE="$store"; REALM_TOML="$toml"; REALM_CFG_DIR="$dir"
}
assert_snapshot relay-gost  relay_rules _relay_gost_config
assert_snapshot relay-realm relay_rules _relay_realm_toml

echo "config regression: $passed snapshots passed"
