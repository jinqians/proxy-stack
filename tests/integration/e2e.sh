#!/bin/bash
# Real client traffic through every protocol, using the exact share links PSM
# exports (the base64 URI subscription users import) with mihomo as the client.
# A node counts only when a client that imported its link reaches the internet
# through it. Certificates come from a throwaway CA that the client trusts, so
# TLS is verified for real rather than skipped.
# Run via tests/integration/container.sh debian|alpine e2e.
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0; FAILS=(); ADDED=()
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); FAILS+=("$*"); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -5 /tmp/chk.out | sed 's/^/       /'; fi; }
psm() { bash manager.sh "$@"; }
add() {
    local core="$1" proto="$2" tag="$3"; shift 3
    local out; out=$(psm node add "$core" "$proto" --tag "$tag" "$@" --json 2>&1)
    if grep -qE '"status": ?"created"' <<<"$out"; then
        ok "add $core/$proto $tag"; ADDED+=("$tag")
    else
        bad "add $core/$proto $tag"; echo "$out" | grep -vE '^\s*$' | tail -4 | sed 's/^/       /'
    fi
}

sec "install + cores"
chk "install.sh"   bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh"
chk "xray_install" bash -c "source lib/xray/core.sh; xray_install <<< \$'n\n0\n0\n0\n0\n'"
chk "sb_install"   bash -c "source lib/singbox/core.sh; sb_install <<< \$'1\nn\n0\n0\n'"
chk "mh_install"   bash -c "source lib/mihomo/core.sh; mh_install <<< \$'n\n0\n0\n0\n'"

sec "test CA and certificates"
CA=/root/e2e-ca
mkdir -p "$CA" /etc/psm/certs /etc/nginx/ssl/x.example.com
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 \
    -subj "/CN=PSM E2E CA" -keyout "$CA/ca.key" -out "$CA/ca.crt" >/dev/null 2>&1
issue() {   # issue <dns-name> <key-out> <cert-out>
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
        -keyout "$2" -out "$CA/$1.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "$1" > "$CA/$1.ext"
    openssl x509 -req -in "$CA/$1.csr" -CA "$CA/ca.crt" -CAkey "$CA/ca.key" -CAcreateserial \
        -days 7 -extfile "$CA/$1.ext" -out "$3" >/dev/null 2>&1
}
issue x.example.com /etc/nginx/ssl/x.example.com/privkey.pem /etc/nginx/ssl/x.example.com/fullchain.pem
issue t.example.com /etc/psm/certs/t.key /etc/psm/certs/t.crt
chk "certificates signed by the test CA" bash -c "openssl verify -CAfile $CA/ca.crt /etc/psm/certs/t.crt /etc/nginx/ssl/x.example.com/fullchain.pem"
C=(--sni t.example.com --cert-path /etc/psm/certs/t.crt --key-path /etc/psm/certs/t.key --insecure 0)
# learn.microsoft.com: the one target that passed with all three cores in every run
# (www.bing.com intermittently failed a REALITY handshake from one core or another)
RD=(--server-name learn.microsoft.com --dest learn.microsoft.com:443)
AUTH=(--listen-addr 0.0.0.0 --username e2e --password e2e-pass-1)

sec "nodes"
add xray reality     e-xr   --port 31001 "${RD[@]}"
add xray vision      e-xv   --port 31002 --domain x.example.com
add xray xhttp       e-xh   --port 31003 --domain x.example.com --mode xhttp
add xray xhttp       e-xws  --port 31004 --domain x.example.com --mode ws
add xray xhttp       e-xg   --port 31005 --domain x.example.com --mode grpc
add xray xhttp       e-xhu  --port 31006 --domain x.example.com --mode httpupgrade
add xray trojan      e-xt   --port 31007 --domain x.example.com
add xray vmess       e-xvm  --port 31008 --domain x.example.com
add xray ss2022      e-xss  --port 31009
add xray socks       e-xs5  --port 31010 "${AUTH[@]}"
add xray hysteria2   e-xhy  --port 31011 "${C[@]}" --obfs-pass e2e-obfs --disable-pmtud true
add sing-box reality   e-sr   --port 32001 "${RD[@]}"
add sing-box ss2022    e-sss  --port 32002
add sing-box hysteria2 e-shy  --port 32003 "${C[@]}" --obfs-pass e2e-obfs --disable-pmtud true
add sing-box anytls    e-sat  --port 32004 "${C[@]}"
add sing-box trojan    e-st   --port 32005 "${C[@]}"
add sing-box vmess     e-svm  --port 32006 "${C[@]}"
add sing-box vless     e-svt  --port 32007 "${C[@]}" --transport tcp
add sing-box vless     e-svw  --port 32008 "${C[@]}" --transport ws
add sing-box vless     e-svg  --port 32009 "${C[@]}" --transport grpc
add sing-box socks     e-ss5  --port 32010 "${AUTH[@]}"
add sing-box tuic      e-stu  --port 32011 "${C[@]}"
add mihomo reality     e-mr   --port 33001 "${RD[@]}"
add mihomo ss2022      e-mss  --port 33002
add mihomo hysteria2   e-mhy  --port 33003 "${C[@]}" --obfs-pass e2e-obfs
# e-xhy and e-shy run with path MTU discovery off (#7); every node is then reached through its link below
chk "e-shy: disable_path_mtu_discovery in the live sing-box inbound" bash -c "jq -e '.inbounds[] | select(.tag == \"e-shy\") | .disable_path_mtu_discovery == true' /etc/sing-box/config.json"
chk "e-xhy: quicParams.disablePathMTUDiscovery beside the Salamander mask" bash -c "jq -e '.inbounds[] | select(.tag == \"e-xhy\") | .streamSettings.finalmask | (.quicParams.disablePathMTUDiscovery == true) and (.udp[0].type == \"salamander\")' /usr/local/etc/xray/config.json"
add mihomo anytls      e-mat  --port 33004 "${C[@]}"
add mihomo trojan      e-mt   --port 33005 "${C[@]}"
add mihomo vmess       e-mvm  --port 33006 "${C[@]}"
add mihomo vless       e-mvt  --port 33007 "${C[@]}" --transport tcp
add mihomo vless       e-mvw  --port 33008 "${C[@]}" --transport ws
add mihomo vless       e-mvg  --port 33009 "${C[@]}" --transport grpc
add mihomo socks       e-ms5  --port 33010 "${AUTH[@]}"
add mihomo tuic        e-mtu  --port 33011 "${C[@]}" --congestion-control cubic

sec "share links -> mihomo client -> internet"
M=/root/e2e-client; rm -rf "$M"; mkdir -p "$M"
# The subscription users import, with the server address pointed at this box.
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_build_uri_sub 127.0.0.1' > "$M/sub.txt" 2>/dev/null
n=$(openssl base64 -d -A < "$M/sub.txt" 2>/dev/null | grep -c '://')
(( n >= ${#ADDED[@]} )) && ok "subscription holds $n links" || bad "subscription holds $n links for ${#ADDED[@]} nodes"
cat "$(ls /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null | head -1)" "$CA/ca.crt" > "$M/ca-bundle.pem"
# The client config is PSM's own mihomo export, as users import it. Only two
# test-only changes: the provider reads the subscription from a local file (its
# URL would serve exactly that), and the GEOIP rule goes (it needs a database
# download); ports move off 7890 and the controller API is switched on.
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_build_mihomo_client 127.0.0.1' > "$M/export.yaml" 2>/dev/null
chk "PSM's mihomo client export" grep -q 'proxy-providers:' "$M/export.yaml"
{
    printf 'external-controller: 127.0.0.1:19090\nbind-address: 127.0.0.1\n'
    sed -e 's|^mixed-port: .*|mixed-port: 17890|' -e 's|^    type: http$|    type: file|' \
        -e '/^    url: "__SUB_URL__"$/d' -e '/^    interval: 3600$/d' -e '/GEOIP,PRIVATE/d' "$M/export.yaml"
} > "$M/config.yaml"
cp "$M/sub.txt" "$M/psm-provider.yaml"
SSL_CERT_FILE="$M/ca-bundle.pem" /usr/local/bin/mihomo -d "$M" -f "$M/config.yaml" > "$M/client.log" 2>&1 &
CPID=$!
trap 'kill $CPID 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null 127.0.0.1:19090/version && break; sleep 0.5; done
# The provider loads after the API is up: wait until the group is populated.
for _ in $(seq 1 60); do
    names=$(curl -s 127.0.0.1:19090/proxies/PSM | jq -r '.all[]' 2>/dev/null)
    (( $(grep -c . <<<"$names") >= ${#ADDED[@]} )) && break
    sleep 0.5
done
[[ -n "$names" ]] && ok "mihomo loaded $(wc -l <<<"$names") nodes from the export" || { bad "mihomo loaded nothing"; tail -5 "$M/client.log" | sed 's/^/       /'; }
for tag in "${ADDED[@]}"; do
    name="PSM-$tag"
    if ! grep -qxF "$name" <<<"$names"; then bad "$tag: the client could not import its share link"; continue; fi
    curl -s -o /dev/null -X PUT 127.0.0.1:19090/proxies/PSM -d "{\"name\":\"$name\"}"
    for _ in 1 2; do   # one retry: a single slow request must not fail a node
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:17890 https://www.gstatic.com/generate_204)
        [[ "$code" == 204 ]] && break
    done
    [[ "$code" == 204 ]] && ok "$tag: link -> server -> internet (HTTP 204)" || bad "$tag: HTTP $code through its link"
done
kill $CPID 2>/dev/null

sec "self-signed nodes: every client pins the certificate PSM signed"
# No test CA here: these nodes get PSM's own self-signed certificate, which no
# client trusts. Xray refuses allowInsecure since 2026-06-01, so the links
# carry the certificate's SHA-256 (pcs / pinSHA256); PSM's sing-box and mihomo
# exports pin it too. A wrong pin must fail: that proves it is checked, not
# skipped.
source tests/integration/xray-link.sh
add sing-box trojan    p-st   --port 35001
add sing-box vless     p-svt  --port 35002 --transport tcp
add sing-box vless     p-svw  --port 35003 --transport ws
add sing-box vmess     p-svm  --port 35004
add sing-box hysteria2 p-shy  --port 35005
add sing-box anytls    p-sat  --port 35006
add sing-box tuic      p-stu  --port 35007
add mihomo trojan      p-mt   --port 35011
add mihomo vless       p-mvg  --port 35012 --transport grpc
add mihomo vmess       p-mvm  --port 35013
add mihomo hysteria2   p-mhy  --port 35014 --obfs-pass e2e-obfs
add mihomo anytls      p-mat  --port 35015
add mihomo tuic        p-mtu  --port 35016
X=/root/xray-client; mkdir -p "$X"
if [[ ! -x "$X/xray" ]]; then   # the Xray v2rayN ships today, whatever the server runs
    curl -fsSL --retry 3 -o "$X/x.zip" https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-64.zip \
        && unzip -qo "$X/x.zip" xray -d "$X"
fi
chk "Xray v26.9.9 as the client" "$X/xray" version
through() {   # through <socks port> → HTTP code of generate_204 through it
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "socks5h://127.0.0.1:$1" https://www.gstatic.com/generate_204
}
xray_try() {   # xray_try <link> <port>: sets code
    xray_link_client "$1" "$2" > "$X/c-$2.json" || { code=unsupported; return; }
    "$X/xray" run -config "$X/c-$2.json" > "$X/c-$2.log" 2>&1 & local xp=$!; sleep 2
    code=$(through "$2"); [[ "$code" == 204 ]] || { sleep 2; code=$(through "$2"); }
    kill $xp 2>/dev/null; wait $xp 2>/dev/null
}
i=0
for tag in p-st p-svt p-svw p-svm p-shy p-mt p-mvg p-mvm p-mhy; do
    i=$((i + 1))
    link=$(psm node export "$tag" --server 127.0.0.1 2>/dev/null)
    case "$tag" in p-svm|p-mvm) pin=$(printf '%s' "${link#vmess://}" | base64 -d | jq -r '.pcs // ""') ;;
                   *) pin=$(sed -nE 's/.*[?&](pcs|pinSHA256)=([0-9a-f]{64}).*/\2/p' <<<"$link") ;; esac
    [[ ${#pin} == 64 ]] || { bad "$tag: its link carries no certificate pin: $link"; continue; }
    xray_try "$link" $((18100 + i))
    [[ "$code" == 204 ]] && ok "$tag: Xray v26.9.9 with the share link, certificate pinned: HTTP 204" \
        || { bad "$tag: Xray with the share link: HTTP $code"; tail -3 "$X/c-$((18100 + i)).log" | sed 's/^/       /'; }
done
link=$(psm node export p-st --server 127.0.0.1 2>/dev/null)
pin=$(sed -nE 's/.*pcs=([0-9a-f]{64}).*/\1/p' <<<"$link")
[[ "${pin:0:1}" == 0 ]] && flip=1 || flip=0
xray_try "${link/pcs=$pin/pcs=$flip${pin:1}}" 18150
[[ "$code" != 204 ]] && ok "a wrong pcs is refused by Xray (HTTP $code)" || bad "Xray accepted a wrong pcs"
# without the pin the node cannot be used from Xray at all (what the old links did)
xray_try "$(sed -E 's/&pcs=[0-9a-f]{64}//' <<<"$link")" 18151
[[ "$code" != 204 ]] && ok "the same link without pcs fails in Xray (HTTP $code): why the pin is needed" || bad "Xray connected to a self-signed node without a pin"

# sing-box: PSM's own outbound export, certificate_public_key_sha256 instead of insecure
sb_try() {   # sb_try <outbound json> <port>: sets code
    jq -n --argjson o "$1" --argjson p "$2" '{log: {level: "warn"}, inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: $p}],
        outbounds: [($o + {tag: "proxy"})], route: {final: "proxy"}}' > "$X/s-$2.json"
    /usr/local/bin/sing-box run -c "$X/s-$2.json" > "$X/s-$2.log" 2>&1 & local sp=$!; sleep 2
    code=$(through "$2"); [[ "$code" == 204 ]] || { sleep 2; code=$(through "$2"); }
    kill $sp 2>/dev/null; wait $sp 2>/dev/null
}
i=0
for tag in p-st p-svw p-svm p-shy p-sat p-stu p-mt p-mvg p-mhy p-mat p-mtu; do
    i=$((i + 1))
    ob=$(psm node export "$tag" --format singbox --server 127.0.0.1 2>/dev/null)
    if ! jq -e '(.tls.certificate_public_key_sha256 | length) == 1 and (.tls.insecure | not)' <<<"$ob" >/dev/null 2>&1; then
        bad "$tag: sing-box export without a pinned key: $ob"; continue
    fi
    sb_try "$ob" $((18200 + i))
    [[ "$code" == 204 ]] && ok "$tag: sing-box with PSM's outbound, public key pinned: HTTP 204" \
        || { bad "$tag: sing-box with PSM's outbound: HTTP $code"; tail -3 "$X/s-$((18200 + i)).log" | sed 's/^/       /'; }
done
ob=$(psm node export p-st --format singbox --server 127.0.0.1 2>/dev/null)
sb_try "$(jq -c '.tls.certificate_public_key_sha256 = ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]' <<<"$ob")" 18250
[[ "$code" != 204 ]] && ok "a wrong key pin is refused by sing-box (HTTP $code)" || bad "sing-box accepted a wrong key pin"

# mihomo: PSM's Clash export keeps skip-cert-verify (for Stash) and adds fingerprint, which mihomo checks regardless
mh_try() {   # mh_try <proxy json> <port>: sets code
    mkdir -p "$X/m-$2"
    jq -n --argjson p "$1" --argjson port "$2" '{"mixed-port": $port, "bind-address": "127.0.0.1", "log-level": "warning",
        proxies: [($p + {name: "P"})], rules: ["MATCH,P"]}' > "$X/m-$2/config.yaml"
    /usr/local/bin/mihomo -d "$X/m-$2" -f "$X/m-$2/config.yaml" > "$X/m-$2/log" 2>&1 & local mp=$!; sleep 2
    code=$(through "$2"); [[ "$code" == 204 ]] || { sleep 2; code=$(through "$2"); }
    kill $mp 2>/dev/null; wait $mp 2>/dev/null
}
i=0
for tag in p-st p-svt p-svm p-shy p-sat p-stu p-mt p-mvg p-mvm p-mhy p-mat p-mtu; do
    i=$((i + 1))
    px=$(psm node export "$tag" --format clash --server 127.0.0.1 2>/dev/null)
    if ! jq -e '(.fingerprint | test("^[0-9a-f]{64}$")) and ."skip-cert-verify" == true' <<<"$px" >/dev/null 2>&1; then
        bad "$tag: Clash export without a fingerprint: $px"; continue
    fi
    mh_try "$px" $((18300 + i))
    [[ "$code" == 204 ]] && ok "$tag: mihomo with PSM's Clash proxy, fingerprint checked: HTTP 204" \
        || { bad "$tag: mihomo with PSM's Clash proxy: HTTP $code"; tail -3 "$X/m-$((18300 + i))/log" | sed 's/^/       /'; }
done
px=$(psm node export p-mt --format clash --server 127.0.0.1 2>/dev/null)
mh_try "$(jq -c '.fingerprint = ("0" * 64)' <<<"$px")" 18350
[[ "$code" != 204 ]] && ok "a wrong fingerprint is refused by mihomo even with skip-cert-verify (HTTP $code)" || bad "mihomo accepted a wrong fingerprint"
# mihomo also reads the pin from the links (pcs → fingerprint, pinSHA256, hpkp)
i=0
for tag in p-st p-svt p-shy p-sat p-mt p-mvg p-mhy p-mat; do
    i=$((i + 1)); d="$X/l-$i"; mkdir -p "$d"
    psm node export "$tag" --server 127.0.0.1 2>/dev/null | openssl base64 -A > "$d/sub.txt"
    printf 'mixed-port: %s\nbind-address: 127.0.0.1\nlog-level: warning\nproxy-providers:\n  p: {type: file, path: ./sub.txt}\nproxy-groups:\n  - {name: P, type: select, use: [p]}\nrules:\n  - MATCH,P\n' \
        $((18400 + i)) > "$d/config.yaml"
    /usr/local/bin/mihomo -d "$d" -f "$d/config.yaml" > "$d/log" 2>&1 & MP=$!; sleep 3
    code=$(through $((18400 + i))); [[ "$code" == 204 ]] || { sleep 2; code=$(through $((18400 + i))); }
    kill $MP 2>/dev/null; wait $MP 2>/dev/null
    [[ "$code" == 204 ]] && ok "$tag: mihomo with the share link (pin read from it): HTTP 204" \
        || { bad "$tag: mihomo with the share link: HTTP $code"; tail -3 "$d/log" | sed 's/^/       /'; }
done
for tag in p-st p-svt p-svw p-svm p-shy p-sat p-stu p-mt p-mvg p-mvm p-mhy p-mat p-mtu; do
    bash manager.sh node delete "$tag" --yes >/dev/null 2>&1 || bad "delete $tag"
done

sec "cores run unprivileged (psm-core)"
for c in xray sing-box mihomo; do
    # by owner, not the first match: the suite's own mihomo clients run as root
    u=$(for p in $(pgrep -x "$c"); do stat -c %U "/proc/$p" 2>/dev/null; done | sort -u | tr '\n' ' ')
    [[ " $u" == *" psm-core "* ]] && ok "$c runs as psm-core" || bad "$c: processes owned by '${u:-nobody}'"
done
# acme.sh renewals rewrite keys as root 0600: a restart must still work
chown root:root /etc/psm/certs/t.key; chmod 600 /etc/psm/certs/t.key
chk "sing-box restart with a root-only key" bash -c "source lib/common.sh; svc_restart sing-box && sleep 2 && svc_is_active sing-box"
chk "the key is group-readable again (psm-core)" bash -c "[[ \$(stat -c '%G %a' /etc/psm/certs/t.key) == 'psm-core 640' ]]"

sec "ECH: PSM's sing-box client export and mihomo ech-opts"
add sing-box vless e-sve --port 32040 "${C[@]}" --transport tcp --ech true
ech=$(psm node export sing-box vless e-sve --format ech 2>/dev/null)
[[ -n "$ech" ]] && ok "export --format ech gives the ECH config" || bad "no ECH config exported"
chk "live sing-box inbound has tls.ech" bash -c "jq -e '.inbounds[] | select(.tag == \"e-sve\") | .tls.ech.enabled' /etc/sing-box/config.json"
E=/root/ech-sb; mkdir -p $E
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_build_singbox_client 127.0.0.1' > $E/export.json 2>/dev/null
jq '.inbounds[0].listen_port = 17896 | (.outbounds[] | select(.type == "selector")).default = "PSM-e-sve"' $E/export.json > $E/client.json
chk "the sing-box client export carries tls.ech for e-sve" jq -e '.outbounds[] | select(.tag == "PSM-e-sve") | .tls.ech.config | length > 0' $E/client.json
SSL_CERT_FILE="$M/ca-bundle.pem" /usr/local/bin/sing-box run -c $E/client.json > $E/log 2>&1 & EP=$!; sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:17896 https://www.gstatic.com/generate_204); kill $EP 2>/dev/null
[[ "$code" == 204 ]] && ok "PSM's sing-box client export over ECH: HTTP 204" || { bad "sing-box client export over ECH: HTTP $code"; tail -3 $E/log | sed 's/^/       /'; }
uuid=$(jq -r '.[] | select(.tag == "e-sve") | .uuid' /opt/psm/config/singbox/vless.json)
mh_ech() {   # mh_ech <dir> <port> <config>: mihomo client with ech-opts
    mkdir -p "$1"
    printf 'mixed-port: %s\nbind-address: 127.0.0.1\nlog-level: warning\nproxies:\n  - {name: P, type: vless, server: 127.0.0.1, port: 32040, uuid: %s, tls: true, servername: t.example.com, network: tcp, flow: xtls-rprx-vision, ech-opts: {enable: true, config: "%s"}}\nrules:\n  - MATCH,P\n' "$2" "$uuid" "$3" > "$1/config.yaml"
    SSL_CERT_FILE="$M/ca-bundle.pem" /usr/local/bin/mihomo -d "$1" -f "$1/config.yaml" > "$1/log" 2>&1 & MP=$!; sleep 3
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -x "socks5h://127.0.0.1:$2" https://www.gstatic.com/generate_204); kill $MP 2>/dev/null
}
mh_ech /root/ech-m1 17897 "$ech"
[[ "$code" == 204 ]] && ok "mihomo with the exported ECH config: HTTP 204" || bad "mihomo with ECH: HTTP $code"
other=$(bash -c 'source lib/common.sh; psm_ech_keypair t.example.com && printf %s "$ECH_CONFIG_B64"')
mh_ech /root/ech-m2 17898 "$other"
[[ "$code" != 204 ]] && ok "another server's ECH config is rejected (HTTP $code)" || bad "a foreign ECH config was accepted"
chk "update --ech false" psm node update sing-box vless e-sve --ech false
chk "ECH keys removed from the node" bash -c "! jq -e '.[] | select(.tag == \"e-sve\") | .ech_key' /opt/psm/config/singbox/vless.json"

sec "WireGuard (sing-box endpoint) <- mihomo WireGuard clients built from PSM's wg-quick files"
add sing-box wireguard e-swg --port 32030 --peer-count 2
wg=$(psm node export sing-box wireguard e-swg 2>/dev/null)
[[ $(grep -c '^\[Interface\]' <<<"$wg") == 2 ]] && ok "export: one wg-quick file per client (2)" || bad "export did not give 2 wg-quick files"
wgpub=$(awk -F' = ' '/^PublicKey/ {print $2; exit}' <<<"$wg")
i=0
while IFS=$'\t' read -r wpriv waddr; do
    i=$((i + 1)); d=/root/wg$i; mkdir -p $d
    printf 'mixed-port: %s\nbind-address: 127.0.0.1\nlog-level: warning\nproxies:\n  - {name: P, type: wireguard, server: 127.0.0.1, port: 32030, ip: %s, private-key: "%s", public-key: "%s", allowed-ips: ["0.0.0.0/0"], udp: true}\nrules:\n  - MATCH,P\n' \
        $((17880 + i)) "${waddr%/*}" "$wpriv" "$wgpub" > $d/config.yaml
    /usr/local/bin/mihomo -d $d -f $d/config.yaml > $d/log 2>&1 & WPID=$!; sleep 3
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:$((17880 + i)) https://www.gstatic.com/generate_204)
    kill $WPID 2>/dev/null
    [[ "$code" == 204 ]] && ok "WireGuard client $i (${waddr%/*}): HTTP 204" || bad "WireGuard client $i: HTTP $code"
done < <(awk -F' = ' '/^PrivateKey/ {k=$2} /^Address/ {print k "\t" $2}' <<<"$wg")

sec "Hysteria2 port hopping (client in its own network namespace)"
add sing-box hysteria2 e-shop --port 32020 "${C[@]}" --hop-ports 42000-42100
chk "REDIRECT 42000-42100 -> 32020 (psm-hop:e-shop)" bash -c "iptables -t nat -S PREROUTING | grep 'psm-hop:e-shop' | grep -q 'to-ports 32020'"
chk "boot hook installed" bash -c "test -f /etc/systemd/system/psm-hop.service || test -x /etc/local.d/psm-hop.start"
hl=$(bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_collect_uris 10.99.0.1' 2>/dev/null | grep -m1 'PSM-e-shop')
[[ "$hl" == *":32020,42000-42100?"* ]] && ok "share link carries the hop range" || bad "share link without the hop range: $hl"
ip netns add cns; ip link add vh type veth peer name vc; ip link set vc netns cns
ip addr add 10.99.0.1/24 dev vh; ip link set vh up
ip netns exec cns ip addr add 10.99.0.2/24 dev vc; ip netns exec cns ip link set vc up; ip netns exec cns ip link set lo up
ip netns exec cns ip route add default via 10.99.0.1
hop_client() {   # hop_client <dir> <port> <link>: mihomo in the namespace, fed one link
    mkdir -p "$1"; printf '%s\n' "$3" | openssl base64 -A > "$1/sub.txt"
    printf 'mixed-port: %s\nbind-address: 127.0.0.1\nlog-level: warning\nproxy-providers:\n  p: {type: file, path: ./sub.txt}\nproxy-groups:\n  - {name: P, type: select, use: [p]}\nrules:\n  - MATCH,P\n' "$2" > "$1/config.yaml"
    SSL_CERT_FILE="$M/ca-bundle.pem" ip netns exec cns /usr/local/bin/mihomo -d "$1" -f "$1/config.yaml" > "$1/log" 2>&1 &
    HPID=$!; sleep 3
    code=$(ip netns exec cns curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "socks5h://127.0.0.1:$2" https://www.gstatic.com/generate_204)
    kill $HPID 2>/dev/null
}
hop_client /root/hop1 17891 "$hl"
[[ "$code" == 204 ]] && ok "PSM's hop link from another host: HTTP 204" || bad "hop link: HTTP $code"
hop_client /root/hop2 17892 "${hl/:32020,42000-42100?/:42000-42100?}"
[[ "$code" == 204 ]] && ok "hop ports only (never the node port): HTTP 204, the redirect carries it" || bad "hop ports only: HTTP $code"
chk "delete e-shop" bash manager.sh node delete sing-box hysteria2 e-shop --yes
chk "its REDIRECT rule is gone" bash -c "! iptables -t nat -S PREROUTING | grep -q 'psm-hop:e-shop'"
chk "boot hook removed with the last hop node" bash -c "! test -f /etc/systemd/system/psm-hop.service && ! test -f /etc/local.d/psm-hop.start"

sec "psm doctor --fix"
add sing-box hysteria2 e-hop2 --port 32021 "${C[@]}" --hop-ports 43000-43100
bash -c 'source lib/common.sh; source lib/hop.sh; _hop_flush'          # rules lost (a reboot without the hook)
# an install from before the cores ran unprivileged: sing-box's unit runs it as root
if [[ -d /run/systemd/system ]]; then
    sed -i 's/^User=psm-core/User=root/; s/^Group=psm-core/Group=root/' /etc/systemd/system/sing-box.service
    systemctl daemon-reload
else
    sed -i 's/^command_user=.*/command_user="root"/; /^capabilities=/d' /etc/init.d/sing-box
fi
bash -c 'source lib/common.sh; svc_restart sing-box; sleep 2; svc_stop sing-box; svc_disable mihomo' >/dev/null 2>&1
bash manager.sh doctor --json > /root/doc1.json 2>/dev/null
chk "doctor: sing-box down, fixable"   jq -e '.checks[] | select(.id=="core.singbox") | .status=="critical" and .fixable' /root/doc1.json
chk "doctor: sing-box unit runs as root" jq -e '.checks[] | select(.id=="core.singbox.user") | .status=="warning"' /root/doc1.json
chk "doctor: mihomo not started at boot" jq -e '.checks[] | select(.id=="core.mihomo.boot") | .status=="warning"' /root/doc1.json
chk "doctor: hop rules missing"          jq -e '.checks[] | select(.id=="network.hop") | .status=="warning"' /root/doc1.json
chk "human report points at --fix"       bash -c "bash manager.sh doctor 2>/dev/null | grep -q 'doctor --fix'"
bash manager.sh doctor --fix --json > /root/doc2.json 2>/root/doc2.err
chk "the three repairs succeeded" jq -e '[.fixes[] | select(.id | IN("core.singbox","core.mihomo.boot","network.hop")) | .result] | length == 3 and all(. == "ok")' /root/doc2.json
chk "re-check: core, user, boot, hop all ok" jq -e '[.checks[] | select(.id | IN("core.singbox","core.singbox.user","core.mihomo.boot","network.hop")) | .status] | length == 4 and all(. == "ok")' /root/doc2.json
u=$(for p in $(pgrep -x sing-box); do stat -c %U "/proc/$p" 2>/dev/null; done | sort -u | tr '\n' ' ')
[[ " $u" == *" psm-core "* ]] && ok "sing-box moved to psm-core by the repair" || bad "sing-box processes owned by '${u:-nobody}'"
chk "hop rule restored" bash -c "iptables -t nat -S PREROUTING | grep -q 'psm-hop:e-hop2'"
[[ -s /root/doc2.err ]] && sed 's/^/       /' /root/doc2.err | tail -8
chk "delete e-hop2" bash manager.sh node delete sing-box hysteria2 e-hop2 --yes

sec "mKCP with a disguise header, from v2rayN's config and an older core's"
# The wire format of seed + header is the classic one of Xray v25 (kcpSettings)
# in every form PSM writes: finalmask [header, cipher] before v26.6.22, which
# applied masks backwards, and mkcp-legacy [cipher, header] after (v2rayN's
# form). Xray v26.9.9 takes kcpSettings.seed again, but that form reaches no
# other client. Clients: Xray v26.9.9 from the link (mkcp-legacy, as v2rayN)
# and Xray v25.12.8 with the classic kcpSettings.
X25=/root/xray-v25; mkdir -p "$X25"
[[ -x "$X25/xray" ]] || { curl -fsSL --retry 3 -o "$X25/x.zip" https://github.com/XTLS/Xray-core/releases/download/v25.12.8/Xray-linux-64.zip && unzip -qo "$X25/x.zip" xray -d "$X25"; }
kcp_v25() {   # kcp_v25 <tag> <node port> <socks port>: the classic kcpSettings client, Xray v25.12.8 (sets code)
    local n; n=$(jq -c --arg t "$1" '.[] | select(.tag == $t)' config/xray/xhttp.json)
    jq -n --argjson n "$n" --argjson np "$2" --argjson p "$3" '{log: {loglevel: "warning"},
        inbounds: [{listen: "127.0.0.1", port: $p, protocol: "socks"}],
        outbounds: [{protocol: "vless", settings: {vnext: [{address: "127.0.0.1", port: $np,
                       users: [{id: $n.uuid, encryption: ($n.vless_encryption // "none")}]}]},
                     streamSettings: {network: "kcp", kcpSettings: {seed: $n.kcp_seed, header: {type: $n.kcp_header}}}}]}' > "$X25/c.json"
    "$X25/xray" run -config "$X25/c.json" > "$X25/c.log" 2>&1 & local xp=$!; sleep 2
    code=$(through "$3"); [[ "$code" == 204 ]] || { sleep 2; code=$(through "$3"); }
    kill $xp 2>/dev/null; wait $xp 2>/dev/null
}
kcp_both() {   # kcp_both <tag> <node port> <socks port>: both clients through the node
    xray_try "$(psm node export xray xhttp "$1" --server 127.0.0.1 2>/dev/null)" "$3"
    [[ "$code" == 204 ]] && ok "$1: Xray v26.9.9 as v2rayN writes it (mkcp-legacy): HTTP 204" || { bad "$1 from v26.9.9: HTTP $code"; tail -3 "$X/c-$3.log" | sed 's/^/       /'; }
    kcp_v25 "$1" "$2" $(($3 + 1))
    [[ "$code" == 204 ]] && ok "$1: Xray v25.12.8 (classic kcpSettings.seed/header): HTTP 204" || { bad "$1 from v25.12.8: HTTP $code"; tail -3 "$X25/c.log" | sed 's/^/       /'; }
}
xv=$(/usr/local/bin/xray version | awk 'NR==1 {print $2}')
add xray xhttp e-kcp3 --port 31019 --mode mkcp --kcp-header srtp
if [[ "$(printf '26.6.22\n%s\n' "$xv" | sort -V | head -1)" != 26.6.22 ]]; then
    chk "on Xray $xv: the header before the cipher (it applies masks backwards)" jq -e \
        '.inbounds[] | select(.tag == "e-kcp3") | [.streamSettings.finalmask.udp[].type] == ["header-srtp", "mkcp-aes128gcm"]' /usr/local/etc/xray/config.json
fi
kcp_both e-kcp3 31019 18510
chk "delete e-kcp3" bash manager.sh node delete xray xhttp e-kcp3 --yes

chk "Xray v26.9.9 installed over the stable one" bash -c \
    "PSM_NO_WIZARD=1 PSM_XRAY_TAG=v26.9.9 bash -c 'source lib/xray/core.sh; xray_install' <<< \$'y\n0\n0\n0\n0\n' >/root/x9.log 2>&1; /usr/local/bin/xray version | grep -q '^Xray 26.9.9'"
add xray xhttp e-kcp9 --port 31020 --mode mkcp --kcp-header srtp
chk "on v26.9.9: finalmask mkcp-legacy, the seed then the srtp header" jq -e \
    '.inbounds[] | select(.tag == "e-kcp9") | .streamSettings | (.kcpSettings.seed == null) and ([.finalmask.udp[].type] == ["mkcp-legacy", "mkcp-legacy"]) and (.finalmask.udp[1].settings.header == "srtp")' \
    /usr/local/etc/xray/config.json
klink=$(psm node export xray xhttp e-kcp9 --server 127.0.0.1 2>/dev/null)
chk "its link: VLESS Encryption on, seed and header" bash -c "[[ '$klink' == *encryption=mlkem768x25519plus* && '$klink' == *seed=* && '$klink' == *headerType=srtp* ]]"
kcp_both e-kcp9 31020 18512
# the form PSM wrote here before: accepted by this Xray, reachable by no client
jq '(.inbounds[] | select(.tag == "e-kcp9") | .streamSettings) |= (del(.finalmask) | .kcpSettings += {seed: "planted", header: {type: "srtp"}})' \
    /usr/local/etc/xray/config.json > /root/x.planted && cat /root/x.planted > /usr/local/etc/xray/config.json
bash -c 'source lib/common.sh; svc_restart xray' >/dev/null 2>&1; sleep 2
bash manager.sh doctor --json > /root/doc-kcp.json 2>/dev/null
chk "doctor: an mKCP node not in this Xray's form, fixable" jq -e '.checks[] | select(.id == "xray.kcp") | .status == "warning" and .fixable' /root/doc-kcp.json
bash manager.sh doctor --fix --json > /root/doc-kcp2.json 2>/dev/null
chk "doctor --fix rewrites it (ok on the re-check)" jq -e '.checks[] | select(.id == "xray.kcp") | .status == "ok"' /root/doc-kcp2.json
kcp_v25 e-kcp9 31020 18514
[[ "$code" == 204 ]] && ok "e-kcp9 after the fix: the v25.12.8 client again: HTTP 204" || bad "e-kcp9 after the fix: HTTP $code"
chk "delete e-kcp9" bash manager.sh node delete xray xhttp e-kcp9 --yes

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done
exit $(( FAIL > 0 ))
