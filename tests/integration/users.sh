#!/bin/bash
# psm user end to end: accounts are merged into all three cores; every user's
# links (their own credentials) get through each node they were given and no
# other; the owners' links keep working; expiry, the Xray quota, disable and
# delete take effect, including through the periodic check.
# Run via tests/integration/container.sh debian|alpine users.
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
X=/usr/local/etc/xray/config.json; S=/etc/sing-box/config.json; M=/etc/mihomo/config.yaml

sec "install + cores"
chk "install.sh"   bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh"
chk "xray_install" bash -c "source lib/xray/core.sh; xray_install <<< \$'n\n0\n0\n0\n0\n'"
chk "sb_install"   bash -c "source lib/singbox/core.sh; sb_install <<< \$'1\nn\n0\n0\n'"
chk "mh_install"   bash -c "source lib/mihomo/core.sh; mh_install <<< \$'n\n0\n0\n0\n'"

sec "test CA and certificates"
CA=/root/users-ca
mkdir -p "$CA" /etc/psm/certs /etc/nginx/ssl/x.example.com
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 \
    -subj "/CN=PSM users CA" -keyout "$CA/ca.key" -out "$CA/ca.crt" >/dev/null 2>&1
issue() {
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
        -keyout "$2" -out "$CA/$1.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "$1" > "$CA/$1.ext"
    openssl x509 -req -in "$CA/$1.csr" -CA "$CA/ca.crt" -CAkey "$CA/ca.key" -CAcreateserial \
        -days 7 -extfile "$CA/$1.ext" -out "$3" >/dev/null 2>&1
}
issue x.example.com /etc/nginx/ssl/x.example.com/privkey.pem /etc/nginx/ssl/x.example.com/fullchain.pem
issue t.example.com /etc/psm/certs/t.key /etc/psm/certs/t.crt
C=(--sni t.example.com --cert-path /etc/psm/certs/t.crt --key-path /etc/psm/certs/t.key --insecure 0)
RD=(--server-name learn.microsoft.com --dest learn.microsoft.com:443)
AUTH=(--listen-addr 0.0.0.0 --username own --password own-socks-pass)

sec "nodes"
add xray reality       u-xr  --port 31001 "${RD[@]}"
add xray vision        u-xv  --port 31002 --domain x.example.com
add xray trojan        u-xt  --port 31007 --domain x.example.com
add xray vmess         u-xvm --port 31008 --domain x.example.com
add xray socks         u-xs5 --port 31010 "${AUTH[@]}"
add xray hysteria2     u-xhy --port 31011 "${C[@]}" --obfs-pass users-obfs
add sing-box reality   u-sr  --port 32001 "${RD[@]}"
add sing-box ss2022    u-sss --port 32002
add sing-box hysteria2 u-shy --port 32003 "${C[@]}" --obfs-pass users-obfs
add sing-box anytls    u-sat --port 32004 "${C[@]}"
add sing-box vless     u-svw --port 32008 "${C[@]}" --transport ws
add sing-box tuic      u-stu --port 32011 "${C[@]}"
add mihomo reality     u-mr  --port 33001 "${RD[@]}"
add mihomo hysteria2   u-mhy --port 33003 "${C[@]}" --obfs-pass users-obfs
add mihomo anytls      u-mat --port 33004 "${C[@]}"
add mihomo trojan      u-mt  --port 33005 "${C[@]}"
add mihomo vmess       u-mvm --port 33006 "${C[@]}"
add mihomo tuic        u-mtu --port 33011 "${C[@]}"
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_collect_uris 127.0.0.1' > /root/owner.txt 2>/dev/null

# probe <links file> [once]: a mihomo client loads the links; prints "NAME CODE"
# for each proxy after one request to the internet through it.
probe() {
    local D=/root/uc want n name code tries=2 cp
    [[ "${2:-}" == once ]] && tries=1
    rm -rf "$D"; mkdir -p "$D"
    openssl base64 -A < "$1" > "$D/prov.txt"
    cat "$(ls /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null | head -1)" "$CA/ca.crt" > "$D/ca.pem"
    printf 'mixed-port: 17890\nbind-address: 127.0.0.1\nexternal-controller: 127.0.0.1:19090\nproxy-providers:\n  p: {type: file, path: ./prov.txt}\nproxy-groups:\n  - {name: G, type: select, use: [p]}\nrules:\n  - MATCH,G\n' > "$D/config.yaml"
    want=$(grep -c . "$1")
    (( want > 0 )) || { echo "(no links in $1)"; return 0; }
    for attempt in 1 2; do   # a client that comes up empty is started again once
        SSL_CERT_FILE="$D/ca.pem" /usr/local/bin/mihomo -d "$D" -f "$D/config.yaml" > "$D/log" 2>&1 &
        cp=$!
        for _ in $(seq 1 60); do
            n=$(curl -s 127.0.0.1:19090/proxies/G | jq -r '.all | length' 2>/dev/null)
            [[ "${n:-0}" -ge "$want" ]] && break; sleep 0.5
        done
        curl -s 127.0.0.1:19090/proxies/G | jq -r '.all[]' 2>/dev/null | grep -qvxE 'COMPATIBLE|DIRECT|REJECT|PASS' && break
        echo "(client loaded nothing, attempt $attempt)" >&2; tail -3 "$D/log" >&2
        kill "$cp" 2>/dev/null; wait "$cp" 2>/dev/null
    done
    # only proxies from the links: an empty or unparsable provider leaves the
    # group with mihomo's built-in COMPATIBLE (= direct), which would "pass"
    for name in $(curl -s 127.0.0.1:19090/proxies/G | jq -r '.all[]' 2>/dev/null | grep -vxE 'COMPATIBLE|DIRECT|REJECT|PASS'); do
        curl -s -o /dev/null -X PUT 127.0.0.1:19090/proxies/G -d "{\"name\":\"$name\"}"
        for (( i = 0; i < tries; i++ )); do
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -x socks5h://127.0.0.1:17890 https://www.gstatic.com/generate_204)
            [[ "$code" == 204 ]] && break
        done
        echo "$name $code"
    done
    kill "$cp" 2>/dev/null; wait "$cp" 2>/dev/null
}
all_204()  { local r; r=$(probe "$1"); [[ -n "$r" ]] && ! grep -qv ' 204$' <<<"$r" || { echo "$r" | grep -v ' 204$'; return 1; }; echo "$(grep -c . <<<"$r") of $(grep -c . <<<"$r")"; }
none_204() { local r; r=$(probe "$1" once); [[ -n "$r" ]] && ! grep -q ' 204$' <<<"$r" || { echo "$r" | grep ' 204$'; return 1; }; }
pick() { grep -E "#PSM-($2)\$" "$1"; }   # pick <links> 'tag|tag': non-VMess links of those nodes

sec "accounts"
chk "user add alice (every node)"               psm user add alice --json
chk "user add bob (u-sr, u-mt; 30 days)"        psm user add bob --nodes u-sr,u-mt --days 30 --json
chk "duplicate name refused"                    bash -c "! bash manager.sh user add alice"
chk "invalid name refused"                      bash -c "! bash manager.sh user add 'Bad Name'"
chk "list --json: two active users"             bash -c "bash manager.sh user list --json | jq -e '.users | length == 2 and all(.state == \"active\")'"
chk "list (table) shows both users"             bash -c "out=\$(bash manager.sh user list); grep -q '^alice ' <<<\"\$out\" && grep -q '^bob ' <<<\"\$out\""
chk "list --json redacts credentials"           bash -c "bash manager.sh user list --json | jq -e 'all(.users[]; .password == \"***\" and .uuid == \"***\")'"
chk "Xray: alice on its 6 inbounds (email)"     bash -c "[[ \$(jq '[.inbounds[] | select(any(.settings.clients[]?; .email == \"psmu-alice@psm\") or any(.settings.accounts[]?; .user == \"psmu-alice\"))] | length' $X) == 6 ]]"
chk "Xray: per-user counters switched on"       jq -e '.policy.levels."0".statsUserUplink == true' $X
chk "sing-box: bob only on u-sr"                jq -e '[.inbounds[] | select(any(.users[]?; .name == "psmu-bob")) | .tag] == ["u-sr"]' $S
chk "mihomo: bob only on u-mt"                  jq -e '[.listeners[] | select((.users | type) == "array" and any(.users[]; .username == "psmu-bob")) | .name] == ["u-mt"]' $M
chk "SS2022 stays single-key"                   jq -e '.inbounds[] | select(.tag == "u-sss") | tostring | contains("psmu-") | not' $S
# The accounts restart each core; on OpenRC the restart can still be under way here, so wait for it
for c in xray sing-box mihomo; do chk "$c active" bash -c "source lib/common.sh; for i in \$(seq 30); do svc_is_active $c && exit 0; sleep 1; done; exit 1"; done

sec "links and traffic"
psm user links alice --server 127.0.0.1 > /root/alice.txt 2>/dev/null
psm user links bob   --server 127.0.0.1 > /root/bob.txt   2>/dev/null
chk "alice: a link for every node but SS2022 (17)" test "$(grep -c . /root/alice.txt)" -eq 17
chk "bob: two links"                               test "$(grep -c . /root/bob.txt)" -eq 2
chk "alice's links carry her credentials, not the owners'" bash -c "! grep -qF \"\$(jq -r '.[0].uuid' /opt/psm/config/xray/reality.json)\" /root/alice.txt"
chk "owners: every node through its own link"      all_204 /root/owner.txt
chk "alice: every node through her links"          all_204 /root/alice.txt
chk "bob: his two nodes"                           all_204 /root/bob.txt
pick /root/alice.txt 'u-xr|u-svw' > /root/alice-other.txt
sed -E "s/$(jq -r '.users[] | select(.name=="alice") | .uuid' /opt/psm/config/users.json)/$(jq -r '.users[] | select(.name=="bob") | .uuid' /opt/psm/config/users.json)/" /root/alice-other.txt > /root/bob-other.txt
chk "bob's UUID on nodes he was not given: refused" none_204 /root/bob-other.txt

sec "Xray quota (per-user counters)"
chk "periodic check counts alice's Xray traffic" bash -c "timeout 120 bash manager.sh --traffic-check >/dev/null 2>&1; bash manager.sh user show alice --json | jq -e '.used_bytes > 0'"
chk "quota 1K: over_quota"                       bash -c "bash manager.sh user update alice --quota 1K --json | jq -e '.user.state == \"over_quota\"'"
chk "alice gone from every core"                 bash -c "! grep -q psmu-alice $X $S $M"
pick /root/alice.txt 'u-xr|u-sr|u-mt' > /root/alice-3.txt
chk "alice refused on all three cores"           none_204 /root/alice-3.txt
chk "bob unaffected"                             all_204 /root/bob.txt
chk "--reset-usage: active again"                bash -c "bash manager.sh user update alice --reset-usage --no-quota --json | jq -e '.user.state == \"active\"'"
chk "alice back on all three cores"              all_204 /root/alice-3.txt

sec "expiry, disable, delete"
chk "expired date: bob expired"                  bash -c "bash manager.sh user update bob --expires 2000-01-01 --json | jq -e '.user.state == \"expired\"'"
chk "bob refused"                                none_204 /root/bob.txt
chk "--days 1: bob active again"                 bash -c "bash manager.sh user update bob --days 1 --json | jq -e '.user.state == \"active\"'"
chk "bob gets through again"                     all_204 /root/bob.txt
# the periodic path: an account that runs out between two checks
jq '(.users[] | select(.name == "bob") | .expires_at) = (now | floor) - 1' /opt/psm/config/users.json > /tmp/u.json && cat /tmp/u.json > /opt/psm/config/users.json
chk "periodic check removes an account that just expired" bash -c "timeout 120 bash manager.sh --traffic-check >/dev/null 2>&1; ! grep -q psmu-bob $X $S $M"
chk "--disable"                                  bash -c "bash manager.sh user update alice --disable >/dev/null && ! grep -q psmu-alice $S"
chk "--enable"                                   bash -c "bash manager.sh user update alice --enable >/dev/null && grep -q psmu-alice $S"
chk "applying twice adds nothing twice"          bash -c "a=\$(grep -o psmu-alice $S | wc -l); bash -c 'source lib/users.sh; users_apply' >/dev/null 2>&1; [[ \$(grep -o psmu-alice $S | wc -l) == \$a ]]"
chk "token rotates"                              bash -c "o=\$(jq -r '.users[] | select(.name==\"alice\") | .token' /opt/psm/config/users.json); bash manager.sh user token alice --json | jq -e '.status == \"rotated\"' && [[ \$(jq -r '.users[] | select(.name==\"alice\") | .token' /opt/psm/config/users.json) != \$o ]]"
chk "delete alice and bob"                       bash -c "bash manager.sh user delete alice --json | jq -e '.status == \"deleted\"' && bash manager.sh user delete bob >/dev/null"
chk "no account left in any core"                bash -c "! grep -q psmu- $X $S $M"
chk "owners still get through"                   all_204 /root/owner.txt
chk "doctor: nothing critical"                   bash -c "bash manager.sh doctor --json | jq -e '.status != \"critical\"'"

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done
exit $(( FAIL > 0 ))
