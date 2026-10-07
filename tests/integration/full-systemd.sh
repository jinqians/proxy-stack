#!/bin/bash
# Full feature matrix on Debian 13 / systemd (run via tests/integration/container.sh).
# Full feature run on Debian 13 / systemd (inside psm-deb on the VPS).
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0; FAILS=()
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); FAILS+=("$*"); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -4 /tmp/chk.out | sed 's/^/       /'; fi; }
psm() { bash manager.sh "$@"; }
NODES=()
add() {   # add <core> <proto> <tag> <args...>
    local core="$1" proto="$2" tag="$3"; shift 3
    local out; out=$(psm node add "$core" "$proto" --tag "$tag" "$@" --json 2>&1)
    if grep -qE '"status": ?"created"' <<<"$out"; then
        ok "add $core/$proto $tag"; NODES+=("$core $proto $tag")
    else
        bad "add $core/$proto $tag"; echo "$out" | grep -vE '^\s*$|Penetrates|anti-censorship' | tail -4 | sed 's/^/       /'
    fi
}
active() { chk "$1 service active" systemctl is-active --quiet "$1"; }
listening() { local p i; for p in "$@"; do for i in $(seq 1 10); do ss -Hltun "sport = :$p" | grep -q . && break; sleep 0.5; done; ss -Hltun "sport = :$p" | grep -q . && ok "port $p listening" || bad "port $p listening"; done; }
export_all() {   # export every node added so far for <core>
    local c p t fmt out
    for n in "${NODES[@]}"; do
        read -r c p t <<<"$n"; [[ "$c" == "$1" ]] || continue
        fmt=uri; [[ "$p" == "snell" || "$t" == *-st ]] && fmt=surge
        out=$(psm node export "$c" "$p" "$t" --server 203.0.113.9 --format "$fmt" 2>&1)
        local rc=$?
        # a loopback-only SOCKS node has no shareable address by design
        if [[ "$p" == "socks" && "$out" == *"loopback-only"* ]]; then ok "export $c/$p $t refused (loopback, by design)"; continue; fi
        if [[ $rc -eq 0 && -n "$out" ]]; then ok "export $c/$p $t ($fmt): ${out:0:60}"; else bad "export $c/$p $t"; echo "$out" | tail -2 | sed 's/^/       /'; fi
    done
}

sec "static checks"
f=0; while IFS= read -r x; do bash -n "$x" || f=1; done < <(find . -name '*.sh'); [[ $f == 0 ]] && ok "bash -n all" || bad "bash -n all"
chk "i18n key alignment" bash scripts/i18n-check.sh

sec "install.sh"
chk "install.sh" bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh"
chk "psm command" test -x /usr/local/bin/psm

sec "certificates for TLS nodes"
mkdir -p /etc/psm/certs
for d in vi.example.com x.example.com t.example.com v.example.com; do
    mkdir -p /etc/nginx/ssl/$d
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=$d \
        -keyout /etc/nginx/ssl/$d/privkey.pem -out /etc/nginx/ssl/$d/fullchain.pem >/dev/null 2>&1
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=www.bing.com \
    -keyout /etc/psm/certs/t.key -out /etc/psm/certs/t.crt >/dev/null 2>&1
C=(--sni www.bing.com --cert-path /etc/psm/certs/t.crt --key-path /etc/psm/certs/t.key --insecure 1)
RD=(--server-name www.bing.com --dest www.bing.com:443)

sec "Xray: real install + every protocol"
chk "xray_install" bash -c "source lib/xray/core.sh; xray_install <<< \$'n\n0\n0\n0\n0\n'"
/usr/local/bin/xray version | head -1
add xray reality   x-rea     --port 21001 "${RD[@]}"
add xray reality   x-rea-enc --port 21002 "${RD[@]}" --vless-enc x25519
add xray vision    x-vis     --port 21003 --domain vi.example.com
add xray vision    x-vis-enc --port 21004 --domain vi.example.com --vless-enc mlkem768
add xray xhttp     x-xh      --port 21010 --domain x.example.com --mode xhttp
add xray xhttp     x-ws      --port 21011 --domain x.example.com --mode upgrade
add xray xhttp     x-grpc    --port 21012 --domain x.example.com --mode grpc
add xray xhttp     x-hu      --port 21013 --domain x.example.com --mode httpupgrade
add xray xhttp     x-h2      --port 21014 --domain x.example.com --mode h2
add xray xhttp     x-kcp     --port 21015 --mode mkcp --kcp-seed seed-all --kcp-header wechat-video
add xray xhttp     x-rl      --port 21016 --mode reality-layer --server-name www.bing.com
add xray xhttp     x-rlg     --port 21017 --mode reality-layer --reality-transport grpc --server-name www.bing.com
add xray xhttp     x-xh-enc  --port 21018 --domain x.example.com --mode xhttp --vless-enc x25519
add xray ss2022    x-ss      --port 21020
add xray trojan    x-tro     --port 21021 --domain t.example.com
add xray vmess     x-vm      --port 21022 --domain v.example.com
add xray socks     x-s5      --port 21023
add xray socks     x-s5p     --port 21024 --listen-addr 0.0.0.0 --username u --password p
add xray hysteria2 x-hy2     --port 21025 "${C[@]}" --obfs-pass pw12 --obfs-type gecko
active xray
listening 21001 21003 21010 21012 21014 21015 21020 21021 21022 21024 21025
chk "xray -test on live config" /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
export_all xray
sec "Xray: update / delete / rebuild"
chk "update port" bash -c "psm() { bash manager.sh \"\$@\"; }; psm node update xray ss2022 x-ss --port 21030 --json | grep -q updated"
listening 21030
chk "delete node" bash -c "bash manager.sh node delete xray socks x-s5 --yes --json | grep -q deleted"
chk "rebuild from stores keeps every inbound" bash -c "source lib/xray/core.sh; n1=\$(jq '.inbounds|length' \$XRAY_CFG); xray_rebuild_from_stores && [ \"\$(jq '.inbounds|length' \$XRAY_CFG)\" = \"\$n1\" ]"

sec "sing-box: real install + every protocol"
chk "sb_install" bash -c "source lib/singbox/core.sh; sb_install <<< \$'1\nn\n0\n0\n'"
/usr/local/bin/sing-box version | head -1
add sing-box reality   s-rea  --port 22001 "${RD[@]}"
add sing-box ss2022    s-ss   --port 22002
add sing-box hysteria2 s-hy2  --port 22003 "${C[@]}" --obfs-pass pw12
add sing-box hysteria2 s-hy2g --port 22004 "${C[@]}" --obfs-pass pw12 --obfs-type gecko
add sing-box anytls    s-any  --port 22005 "${C[@]}"
add sing-box snell     s-sn5  --port 22006 --version 5
add sing-box snell     s-sn6  --port 22007 --version 6
add sing-box trojan    s-tro  --port 22008 "${C[@]}"
add sing-box vmess     s-vm   --port 22009 "${C[@]}"
add sing-box socks     s-s5   --port 22010
i=0; for tr in tcp ws grpc http httpupgrade quic; do i=$((i+1)); add sing-box vless "s-vl-$tr" --port $((22020 + i)) "${C[@]}" --transport $tr; done
active sing-box
listening 22001 22002 22003 22004 22005 22006 22007 22008 22009 22010
chk "sing-box check on live config" /usr/local/bin/sing-box check -c /etc/sing-box/config.json
export_all sing-box

sec "mihomo: real install + every protocol"
chk "mh_install" bash -c "source lib/mihomo/core.sh; mh_install <<< \$'n\n0\n0\n0\n'"
/usr/local/bin/mihomo -v | head -1
add mihomo reality   m-rea   --port 23001 "${RD[@]}"
add mihomo ss2022    m-ss    --port 23002
add mihomo ss2022    m-ss-st --port 23003 --shadow-tls-sni www.microsoft.com
add mihomo hysteria2 m-hy2g  --port 23004 "${C[@]}" --obfs-pass pw12 --obfs-type gecko
add mihomo anytls    m-any   --port 23005 "${C[@]}"
add mihomo snell     m-sn4   --port 23006 --version 4
add mihomo snell     m-sn5st --port 23007 --version 5 --shadow-tls-sni www.microsoft.com
add mihomo trojan    m-tro   --port 23008 "${C[@]}"
add mihomo vmess     m-vm    --port 23009 "${C[@]}"
add mihomo socks     m-s5    --port 23010
for tr in tcp ws grpc xhttp; do add mihomo vless "m-vl-$tr" --port $((23020 + ${#tr})) "${C[@]}" --transport $tr; done
add mihomo vless     m-vl-enc --port 23030 "${C[@]}" --vless-enc x25519
active mihomo
listening 23001 23002 23003 23004 23005 23006 23007 23008 23009 23010 23030
chk "mihomo SAFE_PATHS env file" grep -q /etc/psm/certs /etc/mihomo/psm.env
chk "mihomo unit loads psm.env" grep -q "EnvironmentFile=-/etc/mihomo/psm.env" /etc/systemd/system/mihomo.service
chk "mihomo -t on live config" /usr/local/bin/mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml
export_all mihomo

sec "Hysteria2: path MTU discovery off on existing nodes (#7)"
chk "update s-hy2 --disable-pmtud true" psm node update sing-box hysteria2 s-hy2 --disable-pmtud true
chk "… the live sing-box inbound has disable_path_mtu_discovery; sing-box active" bash -c "jq -e '.inbounds[] | select(.tag == \"s-hy2\") | .disable_path_mtu_discovery == true' /etc/sing-box/config.json && systemctl is-active --quiet sing-box"
chk "update x-hy2 --disable-pmtud true" psm node update xray hysteria2 x-hy2 --disable-pmtud true
chk "… Xray: quicParams.disablePathMTUDiscovery beside the gecko mask; xray active" bash -c "jq -e '.inbounds[] | select(.tag == \"x-hy2\") | .streamSettings.finalmask | (.quicParams.disablePathMTUDiscovery == true) and (.udp[0].type == \"salamander\")' /usr/local/etc/xray/config.json && systemctl is-active --quiet xray"
chk "update s-hy2 --disable-pmtud false: the key is gone" bash -c "bash manager.sh node update sing-box hysteria2 s-hy2 --disable-pmtud false && jq -e '.inbounds[] | select(.tag == \"s-hy2\") | has(\"disable_path_mtu_discovery\") | not' /etc/sing-box/config.json"

sec "guards (must be refused)"
for a in "sing-box vless g1 --port 24001 ${C[*]} --vless-enc x25519" \
         "mihomo snell g2 --port 24002 --obfs-mode http --shadow-tls-sni www.microsoft.com" \
         "sing-box ss2022 g3 --port 24003 --shadow-tls-sni www.microsoft.com" \
         "sing-box hysteria2 g4 --port 24004 ${C[*]} --obfs-pass p --obfs-type nope" \
         "xray hysteria2 g5 --port 24005 ${C[*]} --obfs-pass abc" \
         "mihomo hysteria2 g6 --port 24006 ${C[*]} --disable-pmtud true" \
         "sing-box hysteria2 g7 --port 24007 ${C[*]} --disable-pmtud maybe"; do
    read -r c p t rest <<<"$a"
    out=$(psm node add $c $p --tag $t $rest --json 2>&1)
    grep -qE '"status": ?"created"' <<<"$out" && bad "guard $c/$p $t accepted" || ok "guard $c/$p $t refused"
done

sec "timers / periodic jobs"
chk "traffic timer"      bash -c "source lib/traffic.sh; _trf_install_timer >/dev/null 2>&1; systemctl is-active --quiet psm-traffic.timer"
chk "traffic check run"  timeout 120 bash manager.sh --traffic-check
chk "ruleset timer"      bash -c "source lib/ruleset/apply.sh; rs_timer_enable >/dev/null 2>&1; rs_timer_active"
chk "reality watchdog"   bash -c "source lib/xray/reality_watchdog.sh; _rwd_install_timer >/dev/null 2>&1; _rwd_timer_active"
chk "health report"      bash -c "source lib/tgbot/health_report.sh; HR_HOUR=9; _hr_install_timer >/dev/null 2>&1; _hr_timer_active"
chk "timers removed"     bash -c "source lib/traffic.sh; _trf_uninstall_timer >/dev/null 2>&1; ! systemctl is-active --quiet psm-traffic.timer"

sec "backup / doctor / nginx"
chk "full backup"        bash -c "timeout 300 bash manager.sh --backup-full && ls /opt/psm/backup/*.tar.gz"
chk "doctor --json"      bash -c "bash manager.sh doctor --json | jq -e '.checks | length > 0'"
bash manager.sh doctor --json 2>/dev/null | jq -r '.checks[] | select(.category=="core") | "       \(.id) \(.status)"'
chk "nginx install"      bash -c "source lib/nginx.sh; nginx_install </dev/null && nginx -t && systemctl is-active --quiet nginx"

sec "systemd older than 231 (Amazon Linux 2): the cores stay root"
U=/etc/systemd/system/sing-box.service
chk "unit written as root, no ExecStartPre=+" bash -c "PSM_SYSTEMD_VERSION=219 bash -c 'source lib/singbox/core.sh; _sb_write_service' && grep -q '^User=root' $U && ! grep -q '^ExecStartPre=+' $U"
chk "sing-box runs as root from it" bash -c "systemctl daemon-reload; systemctl restart sing-box; sleep 2; p=\$(systemctl show -p MainPID --value sing-box); u=\$(stat -c %U /proc/\$p 2>/dev/null); echo \"state=\$(systemctl is-active sing-box) user=\$u\"; journalctl -u sing-box -n 4 --no-pager 2>/dev/null; [[ \$u == root ]] && systemctl is-active --quiet sing-box"
chk "a restart through PSM leaves it root" bash -c "PSM_SYSTEMD_VERSION=219 bash -c 'source lib/singbox/core.sh; sb_test_restart' >/dev/null 2>&1; grep -q '^User=root' $U"
chk "doctor says why (skipped, not fixable)" bash -c "PSM_SYSTEMD_VERSION=219 bash manager.sh doctor --json | jq -e '.checks[] | select(.id == \"core.singbox.user\") | .status == \"skipped\" and (.fixable | not)'"
chk "current systemd: back to psm-core" bash -c "bash -c 'source lib/singbox/core.sh; sb_test_restart' >/dev/null 2>&1; grep -q '^User=psm-core' $U && systemctl is-active --quiet sing-box"

sec "main menu logo"
menu_at() { printf '0\n' | TERM=xterm-256color script -qfc "stty cols $1 rows 40; bash manager.sh" /dev/null 2>&1; }
chk "logo beside the title (100 columns)" bash -c "$(declare -f menu_at); menu_at 100 | grep -q '┏━━━━┛'"
chk "no logo on a narrow terminal (50 columns)" bash -c "$(declare -f menu_at); out=\$(menu_at 50); grep -q 'Proxy Stack Manager' <<<\"\$out\" && ! grep -q '┏━━━━┛' <<<\"\$out\""
# The eleven two-column rows (the right-hand items are 12–22, each wrapped in a
# colour code), in Chinese: padding must not depend on the locale, or the
# right-hand column drifts on servers without a UTF-8 locale.
menu_rows() { printf '0\n' | LANG="$1" PSM_LANG=zh bash manager.sh 2>&1 | tr -d '\033' | grep -aE 'm(1[2-9]|2[0-2])\.\['; }
chk "main menu columns are the same in the C and UTF-8 locales" bash -c "$(declare -f menu_rows); a=\$(menu_rows C); b=\$(menu_rows C.UTF-8); [[ \$(wc -l <<<\"\$a\") -eq 11 && \"\$a\" == \"\$b\" ]]"

sec "official Hysteria2: path MTU discovery off (#7)"
hy2() { bash -c "source lib/common.sh; source lib/hysteria2.sh; $*"; }
# the wizard: port, password, no domain (self-signed), MTU discovery off, no firewall question
chk "install + wizard: port 24443, self-signed, MTU discovery off" bash -c "$(declare -f hy2); printf '24443\nhy2-test-pass\nn\ny\nn\n' | hy2 hy2_install"
chk "config: quic.disablePathMTUDiscovery: true; hysteria-server active" bash -c "grep -A6 '^quic:' /etc/hysteria/config.yaml | grep -q '^  disablePathMTUDiscovery: true' && sleep 2 && systemctl is-active --quiet hysteria-server"
hy2_client() {   # sing-box (installed above) as a Hysteria2 client: HTTP 204 through the official server
    local sb; sb=$(bash -c 'source lib/common.sh; echo "$SINGBOX_BIN"')
    jq -n '{log: {level: "warn"}, inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: 24480}],
            outbounds: [{type: "hysteria2", server: "127.0.0.1", server_port: 24443, password: "hy2-test-pass",
                         tls: {enabled: true, insecure: true, server_name: "Hysteria2"}}]}' > /tmp/hy2c.json
    "$sb" run -c /tmp/hy2c.json > /tmp/hy2c.log 2>&1 & local pid=$!
    sleep 2; local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x http://127.0.0.1:24480 https://www.gstatic.com/generate_204)
    kill $pid; [[ $code == 204 ]] || { echo "HTTP $code"; tail -3 /tmp/hy2c.log; return 1; }
}
chk "a client through it (sing-box): HTTP 204" hy2_client
chk "menu 10: discovery back on (the line is gone), still active" bash -c "$(declare -f hy2); hy2 hy2_toggle_pmtud && ! grep -q disablePathMTUDiscovery /etc/hysteria/config.yaml && sleep 2 && systemctl is-active --quiet hysteria-server"
chk "menu 10 again: off, under quic:" bash -c "$(declare -f hy2); hy2 hy2_toggle_pmtud && grep -A1 '^quic:' /etc/hysteria/config.yaml | grep -q '^  disablePathMTUDiscovery: true' && sleep 2 && systemctl is-active --quiet hysteria-server"
chk "… a client through it" hy2_client
chk "uninstall the official Hysteria2" bash -c "$(declare -f hy2); printf 'y\n' | hy2 hy2_uninstall && ! systemctl is-active --quiet hysteria-server"

# A terminal left non-blocking before PSM starts (O_NONBLOCK sits on the open file
# shared with the login shell): every read failed with "Resource temporarily
# unavailable" and set -e ended PSM at its first prompt (#5). The answer comes
# 3 s after the start, so the menu's read finds the terminal empty.
nb_menu() { (sleep 3; printf '0\n') | TERM=xterm script -qfc "perl -MFcntl -e 'fcntl(STDIN, F_SETFL, fcntl(STDIN, F_GETFL, 0) | O_NONBLOCK) or die'; bash manager.sh" /dev/null 2>&1; }
chk "a terminal left non-blocking: the menu still reads (0 exits normally)" bash -c "$(declare -f nb_menu); out=\$(nb_menu); ! grep -q 'Resource temporarily unavailable' <<<\"\$out\" && grep -qE 'Exited|已退出' <<<\"\$out\""

sec "test suites"
chk "tests/run.sh"       bash tests/run.sh
chk "core-validate"      env XRAY_BINS="/root/cores/stable/xray /root/cores/pre/xray" SINGBOX_BIN=/root/cores/sing-box MIHOMO_BIN=/root/cores/mihomo bash tests/core-validate.sh

sec "full uninstall"
chk "uninstall.sh" bash -c "yes y | timeout 600 bash uninstall.sh"
for s in xray sing-box mihomo nginx psm-traffic.timer psm-ruleset-update.timer psm-reality-watchdog.timer psm-health-report.timer; do
    systemctl is-active --quiet $s && bad "$s still active after uninstall" || ok "$s stopped"
done
[[ -e /opt/psm ]] && bad "/opt/psm left behind" || ok "/opt/psm removed"
compgen -G '/etc/systemd/system/xray*' >/dev/null || compgen -G '/etc/systemd/system/sing-box*' >/dev/null \
    || compgen -G '/etc/systemd/system/mihomo*' >/dev/null || compgen -G '/etc/systemd/system/psm-*' >/dev/null \
    && bad "units left" || ok "no PSM units left"

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done

exit $(( FAIL > 0 ))
