#!/usr/bin/env bash
# Downloads survive a moment of GitHub trouble: every download of a core, a
# tool, an installer or a data file passes PSM_DL (lib/common.sh), so a 500 or
# a timeout is retried instead of failing the install. Seen for real in CI:
# one 500 from GitHub while fetching sing-box failed the whole suite.
#
# A local server stands in for a flaky GitHub: each path answers 500 twice,
# then redirects to the real github.com. The sing-box and Xray installs are
# pointed at it and must still install.

set -uo pipefail
cd /opt/psm || exit 1

pass=0; fail=0; failed=()
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); failed+=("$1"); }
chk() {
    local n="$1"; shift
    if "$@" >/tmp/chk.out 2>&1; then ok "$n"; else bad "$n"; tail -15 /tmp/chk.out | sed 's/^/       /'; fi
}
sec() { echo; echo "=== $1"; }

sec "every download retries"
# lines that download (to a file, into a shell, from GitHub releases or its API,
# an installer or release notes) must carry PSM_DL; vps_test.sh has its own
missing=$(grep -rnE 'curl [^#]*(-o |\| *sh|/releases|api\.github\.com|_INSTALLER|_RELEASE_NOTES|sha256sum\.txt|--max-filesize)' \
              lib update.sh | grep -v 'PSM_DL' | grep -v '^lib/vps_test.sh:' | grep -v -- '-o /dev/null' \
              | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)   # a comment that names such a command is not one
chk "no download without PSM_DL" test -z "$missing"
[[ -z "$missing" ]] || echo "$missing" | sed 's/^/       /'
chk "bootstrap.sh retries its download" grep -q "curl --retry 5 --connect-timeout 15 -fsSL" bootstrap.sh
chk "PSM_DL is defined once common.sh is loaded" bash -c 'source lib/common.sh && [[ "${PSM_DL[*]}" == "--retry 5 --connect-timeout 15" ]]'

sec "a flaky stand-in for GitHub"
# the Alpine image has no curl until PSM installs it; python3 runs the stand-in
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then apk add -q --no-cache python3 curl >/dev/null
    elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null && apt-get install -y -qq python3 curl >/dev/null
    else dnf install -y -q python3 curl >/dev/null; fi
fi
cat > /tmp/flaky.py <<'EOF'
import http.server
seen = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.answer(True)
    def do_HEAD(self): self.answer(False)
    def answer(self, body):
        n = seen.get(self.path, 0) + 1
        seen[self.path] = n
        with open("/tmp/flaky.log", "a") as f:
            f.write("%s %d\n" % (self.path, n))
        if self.path.startswith("/always/") or n <= 2:
            self.send_response(500); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.path.startswith("/plain/"):
            b = b"ok\n"
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
            if body: self.wfile.write(b)
            return
        self.send_response(302); self.send_header("Location", "https://github.com" + self.path)
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8765), H).serve_forever()
EOF
rm -f /tmp/flaky.log
python3 /tmp/flaky.py & flaky=$!
trap 'kill $flaky 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:8765/warmup && break; sleep 0.5; done
F=http://127.0.0.1:8765
hits() { grep -c "^$1 " /tmp/flaky.log; }
chk "the stand-in answers (500 first)" test "$(curl -s -o /dev/null -w '%{http_code}' $F/up)" = 500

chk "without retries a 500 fails the download" bash -c "! curl -fsSL $F/plain/once -o /tmp/once"
chk "… after one request" test "$(hits /plain/once)" = 1
chk "with PSM_DL the third try gets through" bash -c "source lib/common.sh && curl \"\${PSM_DL[@]}\" -fsSL $F/plain/twice -o /tmp/twice && grep -qx ok /tmp/twice"
chk "… after exactly three requests" test "$(hits /plain/twice)" = 3
chk "a lasting 500 still fails, after 1 + 5 tries" bash -c "source lib/common.sh && ! curl \"\${PSM_DL[@]}\" -fsSL $F/always/x -o /tmp/always"
chk "… and no more" test "$(hits /always/x)" = 6

sec "real installs through the flaky stand-in"
chk "sing-box installs" bash -c "source lib/singbox/core.sh && SB_RELEASES=$F/SagerNet/sing-box/releases PSM_SB_TAG=v1.14.0 sb_install <<< \$'1\nn\n0\n0\n'"
chk "… and runs" bash -c '/usr/local/bin/sing-box version | grep -q "1.14.0"'
chk "… its download was refused twice first" bash -c "grep -E '^/SagerNet/sing-box/releases/download/v1.14.0/[^ ]+ 3$' /tmp/flaky.log"
chk "Xray installs" bash -c "source lib/xray/core.sh && XRAY_RELEASES=$F/XTLS/Xray-core/releases PSM_XRAY_TAG=v26.3.27 xray_install <<< \$'n\n0\n0\n0\n0\n'"
chk "… and runs" bash -c '/usr/local/bin/xray version | grep -q "26.3.27"'
chk "… its download was refused twice first" bash -c "grep -E '^/XTLS/Xray-core/releases/download/v26.3.27/[^ ]+ 3$' /tmp/flaky.log"

echo
echo "=== RESULT: $pass ok, $fail failed"
(( fail == 0 )) || { printf '  - %s\n' "${failed[@]}"; exit 1; }
