#!/bin/bash
# Destination side of tests/integration/migrate.sh. The server that came out of
# `psm migrate` must be the one that went in (byte-identical core configs, the
# same share links) and must work on this host: its init system, its Nginx,
# its firewall rules, and a client that imports the links and gets through.
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0; FAILS=()
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); FAILS+=("$*"); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
# a node's name in clients: the flag of this server's country and its tag (#10)
label() { bash -c 'source lib/common.sh; psm_node_label "$1"' _ "$1"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -5 /tmp/chk.out | sed 's/^/       /'; fi; }
E=/root/mig-expect

sec "the move (${MIG_MODE:-?})"
[[ "${MIG_RC:-1}" == 0 ]] && ok "psm migrate exited 0" || bad "psm migrate exited ${MIG_RC:-?}"
if [[ "${MIG_MODE:-}" == push ]]; then
    chk "no bundle left on the new host (it holds private keys)" bash -c "! ls /root/psm-migrate*.tgz /root/psm.tgz 2>/dev/null | grep -q ."
    chk "psm command installed" test -x /usr/local/bin/psm
fi

sec "the same server"
chk "core configs byte-identical" bash -c "cd / && sha256sum -c $E/cfg.sha"
chk "share links identical (keys, UUIDs, ports)" bash -c "diff <(bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_collect_uris 10.9.9.9' 2>/dev/null | sort) <(sort $E/uris.txt)"

sec "re-applied for this host"
for c in xray sing-box mihomo; do
    chk "$c active" bash -c "source lib/common.sh; svc_is_active $c"
    u=$(for p in $(pgrep -x "$c"); do stat -c %U "/proc/$p" 2>/dev/null; done | sort -u | tr '\n' ' ')
    [[ " $u" == *" psm-core "* ]] && ok "$c runs as psm-core" || bad "$c: processes owned by '${u:-nobody}'"
done
if [[ -d /run/systemd/system ]]; then
    chk "systemd units run the cores as psm-core" grep -q '^User=psm-core' /etc/systemd/system/sing-box.service
else
    chk "OpenRC scripts run the cores as psm-core" grep -q '^command_user="psm-core' /etc/init.d/sing-box
fi
chk "Nginx config valid, 443 listening" bash -c "nginx -t && ss -Hltn 'sport = :443' | grep -q ."
chk "hop rule for m-shy" bash -c "iptables -t nat -S PREROUTING | grep -q 'psm-hop:m-shy'"
chk "hop boot hook" bash -c "test -f /etc/systemd/system/psm-hop.service || test -x /etc/local.d/psm-hop.start"
chk "traffic job" bash -c "source lib/traffic.sh; _trf_timer_active"
chk "rule-set job" bash -c "source lib/ruleset/apply.sh; rs_timer_active"
chk "certificate key group psm-core" bash -c "[[ \$(stat -c %G /etc/nginx/ssl/x.example.com/privkey.pem) == psm-core ]]"
tok=$(cat "$E/sub_token")
chk "online subscription: same URL, served here" bash -c "curl -sk --resolve x.example.com:443:127.0.0.1 https://x.example.com/psm-sub/$tok/sub.txt | openssl base64 -d -A | grep -c '://' | grep -qvx 0"
chk "doctor: nothing critical" bash -c "bash manager.sh doctor --json | jq -e '.status != \"critical\"'"

sec "client -> new host -> internet"
M=/root/mig-client; rm -rf "$M"; mkdir -p "$M"
# The hop range is left out: its REDIRECT sits in PREROUTING, which a client on
# this same host never passes (e2e.sh tests hopping from its own namespace;
# here the rule's presence is checked above).
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_collect_uris 127.0.0.1' 2>/dev/null \
    | sed -E 's/(@127\.0\.0\.1:[0-9]+),[0-9]+-[0-9]+/\1/' | openssl base64 -A > "$M/sub.txt"
cat "$(ls /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null | head -1)" "$E/ca.crt" > "$M/ca-bundle.pem"
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_build_mihomo_client 127.0.0.1' > "$M/export.yaml" 2>/dev/null
# the same test-only changes as e2e.sh: local provider file, no GEOIP, own ports, API on
{
    printf 'external-controller: 127.0.0.1:19090\nbind-address: 127.0.0.1\n'
    sed -e 's|^mixed-port: .*|mixed-port: 17890|' -e 's|^    type: http$|    type: file|' \
        -e '/^    url: "__SUB_URL__"$/d' -e '/^    interval: 3600$/d' -e '/GEOIP,PRIVATE/d' "$M/export.yaml"
} > "$M/config.yaml"
cp "$M/sub.txt" "$M/psm-provider.yaml"
SSL_CERT_FILE="$M/ca-bundle.pem" /usr/local/bin/mihomo -d "$M" -f "$M/config.yaml" > "$M/client.log" 2>&1 &
CPID=$!
trap 'kill $CPID 2>/dev/null' EXIT
mapfile -t TAGS < "$E/tags.txt"
for _ in $(seq 1 30); do curl -s -o /dev/null 127.0.0.1:19090/version && break; sleep 0.5; done
for _ in $(seq 1 60); do
    names=$(curl -s 127.0.0.1:19090/proxies/PSM | jq -r '.all[]' 2>/dev/null)
    (( $(grep -c . <<<"$names") >= ${#TAGS[@]} )) && break
    sleep 0.5
done
for tag in "${TAGS[@]}"; do
    name=$(label "$tag")
    if ! grep -qxF "$name" <<<"$names"; then bad "$tag: the client could not import its share link"; continue; fi
    curl -s -o /dev/null -X PUT 127.0.0.1:19090/proxies/PSM -d "{\"name\":\"$name\"}"
    for _ in 1 2; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:17890 https://www.gstatic.com/generate_204)
        [[ "$code" == 204 ]] && break
    done
    [[ "$code" == 204 ]] && ok "$tag: link -> new host -> internet (HTTP 204)" || bad "$tag: HTTP $code through its link"
done
kill $CPID 2>/dev/null

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done
exit $(( FAIL > 0 ))
