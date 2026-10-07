#!/bin/bash
# Nginx 443 SNI path on a fresh box (Alpine/OpenRC or Debian/systemd), inside a
# disposable container on the test VPS: the exact flow that failed for the user,
# then every core mounted on 443 with real client traffic through it.
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0; FAILS=()
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); FAILS+=("$*"); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -5 /tmp/chk.out | sed 's/^/       /'; fi; }
psm() { bash manager.sh "$@"; }
ALPINE=0; [[ -f /etc/alpine-release ]] && ALPINE=1
lib() { bash -c "source lib/common.sh; source lib/nginx.sh; $*"; }
listening() { local i; for i in $(seq 1 10); do ss -Hltn "sport = :$1" | grep -q . && return 0; sleep 0.5; done; return 1; }

sec "install.sh"
chk "install.sh" bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh"

sec "the reported flow: 443 SNI mount with nginx not installed yet"
is_installed_nginx() { command -v nginx >/dev/null; }
is_installed_nginx && bad "nginx preinstalled (test is not fresh)" || ok "nginx not installed before"
chk "nginx_ensure_stream_sni (installs nginx)" lib "nginx_ensure_stream_sni </dev/null"
chk "nginx -t" nginx -t
chk "nginx service active" lib "svc_is_active nginx"
pidp=$(nginx -V 2>&1 | tr ' ' '\n' | sed -n 's/^--pid-path=//p')
chk "nginx.conf pid matches build ($pidp)" grep -q "^pid ${pidp};" /etc/nginx/nginx.conf
chk "pid file holds the running master" bash -c "[[ -s $pidp ]] && kill -0 \$(cat $pidp)"
chk "port 443 listening" listening 443
if (( ALPINE )); then
    chk "distro conf.d/stream.conf neutralized" bash -c "! grep -qE '^[[:space:]]*stream' /etc/nginx/conf.d/stream.conf"
    chk "original kept as .psm-disabled" grep -q '^stream' /etc/nginx/conf.d/stream.conf.psm-disabled
fi

sec "idempotent re-run + service control"
chk "second nginx_ensure_stream_sni" lib "nginx_ensure_stream_sni </dev/null"
(( ALPINE )) && chk "backup not overwritten by re-run" grep -q '^stream' /etc/nginx/conf.d/stream.conf.psm-disabled
chk "restart via init system" lib "svc_restart nginx && sleep 1 && svc_is_active nginx"
chk "stop stops nginx" bash -c "source lib/common.sh; svc_stop nginx; sleep 1; ! pgrep -x nginx >/dev/null && ! svc_is_active nginx"
chk "start again" lib "svc_start nginx && sleep 1 && svc_is_active nginx && nginx -t"
if (( ALPINE )); then
    sec "package reinstall (what an apk upgrade does to conf.d/stream.conf)"
    apk fix -q nginx-mod-stream >/dev/null 2>&1
    ls /etc/nginx/conf.d/ | sed 's/^/       conf.d: /'
    chk "nginx -t still ok after apk fix" nginx -t
    chk "nginx_test_reload after apk fix" lib "nginx_test_reload"
fi

sec "cores"
chk "xray_install" bash -c "source lib/xray/core.sh; xray_install <<< \$'n\n0\n0\n0\n0\n'"
chk "sb_install"   bash -c "source lib/singbox/core.sh; sb_install <<< \$'1\nn\n0\n0\n'"
chk "mh_install"   bash -c "source lib/mihomo/core.sh; mh_install <<< \$'n\n0\n0\n0\n'"
add() {
    local core="$1" proto="$2" tag="$3"; shift 3
    local out; out=$(psm node add "$core" "$proto" --tag "$tag" "$@" --json 2>&1)
    grep -qE '"status": ?"created"' <<<"$out" && ok "add $core/$proto $tag" \
        || { bad "add $core/$proto $tag"; echo "$out" | grep -vE '^\s*$' | tail -4 | sed 's/^/       /'; }
}
# One REALITY node per core on the shared 443, each behind its own SNI — mounted
# the way automation does it: psm node add ... --mount-443.
add xray     reality n-xr --port 21001 --server-name learn.microsoft.com --dest learn.microsoft.com:443 --mount-443
add sing-box reality n-sr --port 22001 --server-name www.bing.com        --dest www.bing.com:443        --mount-443
add mihomo   reality n-mr --port 23001 --server-name dl.google.com       --dest dl.google.com:443       --mount-443
MAP=/etc/nginx/stream.d/00-sni-map.conf
for e in "learn.microsoft.com 127.0.0.1:21001" "www.bing.com 127.0.0.1:22001" "dl.google.com 127.0.0.1:23001"; do
    set -- $e; chk "SNI map: $1 -> $2" grep -qE "^[[:space:]]*$1[[:space:]]+$2;" $MAP
done
out=$(psm node add sing-box reality n-dup --port 22002 --server-name www.bing.com --dest www.bing.com:443 --mount-443 --json 2>&1)
grep -q 'already routes to' <<<"$out" && ok "second node on a taken SNI is refused" || { bad "SNI conflict not refused"; echo "$out" | tail -2 | sed 's/^/       /'; }
out=$(psm node add xray vision n-lb --port 21050 --domain x.example.com --listen-addr 127.0.0.1 --json 2>&1)
grep -q -- '--mount-443' <<<"$out" && ok "loopback add without --mount-443 is refused with a hint" || bad "loopback add without --mount-443 not refused"
out=$(psm node add xray reality n-bad --port 21060 --server-name www.microsoft.com --dest www.microsoft.com:443 --json 2>&1)
grep -q 'cannot complete a REALITY handshake' <<<"$out" && ok "REALITY target Xray cannot use is refused by the core probe" || { bad "bad REALITY target accepted"; echo "$out" | tail -2 | sed 's/^/       /'; }

X=/usr/local/bin/xray; W=/tmp/e2e; rm -rf $W; mkdir -p $W; PIDS=()
stop_clients() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap stop_clients EXIT
qp() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
e2e() {   # e2e <core> <tag> <socks-port>: real xray client -> nginx 443 SNI -> core REALITY node
    local uri u sni pbk sid flow
    uri=$(psm node export "$1" reality "$2" 2>/dev/null | grep -m1 -o 'vless://[^ ]*')
    [[ -n "$uri" ]] || { bad "export $1 $2"; return; }
    u=${uri#vless://}; u=${u%%@*}; sni=$(qp "$uri" sni); pbk=$(qp "$uri" pbk); sid=$(qp "$uri" sid); flow=$(qp "$uri" flow)
    jq -n --argjson sp "$3" --arg u "$u" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" '{
      inbounds: [{listen: "127.0.0.1", port: $sp, protocol: "socks"}],
      outbounds: [{protocol: "vless",
        settings: {vnext: [{address: "127.0.0.1", port: 443, users: [{id: $u, encryption: "none", flow: $flow}]}]},
        streamSettings: {network: "tcp", security: "reality",
          realitySettings: {serverName: $sni, publicKey: $pbk, shortId: $sid, fingerprint: "chrome"}}}]}' > $W/c-$3.json
    $X run -config $W/c-$3.json >$W/c-$3.log 2>&1 & PIDS+=($!); sleep 2
    local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:$3 https://www.gstatic.com/generate_204)
    [[ $code == 204 ]] && ok "E2E $1 REALITY via nginx 443 (SNI $sni): HTTP 204" || bad "E2E $1 via 443 (SNI $sni): HTTP $code"
}
sec "real traffic through nginx 443 SNI"
e2e xray     n-xr 41001
e2e sing-box n-sr 41002
e2e mihomo   n-mr 41003
chk "unknown SNI is dropped (no relay)" bash -c "! timeout 8 openssl s_client -connect 127.0.0.1:443 -servername not-mapped.example </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE'"

sec "update / delete of mounted nodes keep the SNI map in step"
chk "update n-sr --port 22009" psm node update sing-box reality n-sr --port 22009
chk "SNI map follows the new port" grep -qE "^[[:space:]]*www.bing.com[[:space:]]+127.0.0.1:22009;" $MAP
e2e sing-box n-sr 41004
chk "delete n-mr" psm node delete mihomo reality n-mr --yes
chk "its SNI route is gone" bash -c "! grep -q 'dl.google.com' $MAP"
chk "other routes untouched" grep -q 'learn.microsoft.com' $MAP
chk "nginx -t after update/delete" nginx -t

sec "a long domain in the SNI map (#6: a REALITY node on the user's own domain)"
LONG=psm-issue-6-a-rather-long-subdomain-name-for-the-sni-map.of-a-reality-node.example.com
# no real host has this name, so the REALITY target probe is skipped: the nginx side is what is under test
add xray reality n-long --port 21050 --server-name "$LONG" --dest www.bing.com:443 --skip-dest-probe --mount-443
chk "SNI map has the ${#LONG}-byte domain" grep -qF "$LONG" $MAP
chk "nginx -t with it" nginx -t
chk "nginx still active" lib "svc_is_active nginx"
# nginx.conf as an older PSM wrote it: the reported failure, then doctor's repair
sed -i '/map_hash_/d;/server_names_hash_bucket_size/d' /etc/nginx/nginx.conf
chk "the old nginx.conf fails on it (could not build map_hash)" bash -c "nginx -t 2>&1 | grep -q 'could not build map_hash'"
chk "doctor: nginx.main is a fixable warning" bash -c "psm doctor --json 2>/dev/null | jq -e '.checks[] | select(.id == \"nginx.main\") | .status == \"warning\" and .fixable'"
chk "doctor --fix writes the current nginx.conf; nginx -t passes" bash -c "psm doctor --fix --json >/dev/null 2>&1; nginx -t && grep -q 'map_hash_bucket_size 256;' /etc/nginx/nginx.conf"
chk "doctor: nginx.main ok" bash -c "psm doctor --json 2>/dev/null | jq -e '.checks[] | select(.id == \"nginx.main\") | .status == \"ok\"'"
chk "nginx active after the fix" lib "svc_is_active nginx"
# the workaround from #6 already in stream.d: nginx.conf must not set the same
# directives again, or nginx stops on "is duplicate"
printf 'map_hash_bucket_size 256;\nmap_hash_max_size 4096;\n' > /etc/nginx/stream.d/00-map-hash.conf
chk "with the workaround in stream.d, nginx.conf leaves the two to it; nginx -t passes" lib "_write_nginx_main && ! grep -q map_hash_ /etc/nginx/nginx.conf && nginx_test_reload"
chk "… doctor: nginx.main ok (set in stream.d)" bash -c "psm doctor --json 2>/dev/null | jq -e '.checks[] | select(.id == \"nginx.main\") | .status == \"ok\"'"
rm -f /etc/nginx/stream.d/00-map-hash.conf
chk "workaround removed: nginx.conf sets them again; nginx -t passes" lib "_write_nginx_main && grep -q 'map_hash_bucket_size 256;' /etc/nginx/nginx.conf && nginx_test_reload"
chk "delete n-long" psm node delete xray reality n-long --yes

sec "Xray Vision / Trojan with a domain: fallback to the nginx camouflage site"
mkdir -p /etc/nginx/ssl/x.example.com
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=x.example.com \
    -keyout /etc/nginx/ssl/x.example.com/privkey.pem -out /etc/nginx/ssl/x.example.com/fullchain.pem >/dev/null 2>&1
add xray vision n-xv --port 21040 --domain x.example.com
add xray trojan n-xt --port 21041 --domain x.example.com
C=/usr/local/etc/xray/config.json
for t in n-xv n-xt; do
    jq -e --arg t $t '.inbounds[] | select(.tag==$t) | ((.settings.fallbacks // []) | length) == 0' $C >/dev/null \
        && ok "$t (fallback off, the CLI default): no dead fallback to 8080" || bad "$t still falls back while disabled"
done
chk "camouflage site for x.example.com" lib "nginx_setup_http_camouflage x.example.com"
add xray vision n-xv2 --port 21042 --domain x.example.com --fallback-enabled true
chk "nginx -t after fallback sites" nginx -t
chk "nginx still active" lib "svc_is_active nginx"
for v in --http2 --http1.1; do
    code=$(curl -sk $v -o /dev/null -w '%{http_code}' --max-time 10 --resolve x.example.com:21042:127.0.0.1 https://x.example.com:21042/)
    [[ $code =~ ^[1-5][0-9][0-9]$ ]] && ok "n-xv2 ($v): a browser-like probe gets the nginx site (HTTP $code)" || bad "n-xv2 fallback $v (HTTP $code)"
done

sec "doctor"
psm doctor --json 2>/dev/null | jq -r '.checks[] | select(.category=="core" or (.id|test("nginx"))) | "       \(.id) \(.status)"'

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done

exit $(( FAIL > 0 ))
