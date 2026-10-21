#!/bin/bash
# Uses only temporary keys and loopback servers. Never package this test app for release.
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/pmap-integration.XXXXXX")"
SSH_PID=''
HTTP_PID=''
BUILT_PROBE=0
cleanup() {
    STATUS=$?
    if [[ "$STATUS" != 0 ]]; then
        tail -15 "$FIXTURE/sshd.log" "$FIXTURE/http.log" 2>/dev/null || true
    fi
    [[ -z "$SSH_PID" ]] || kill "$SSH_PID" 2>/dev/null || true
    [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true
    [[ -z "$SSH_PID" ]] || wait "$SSH_PID" 2>/dev/null || true
    [[ -z "$HTTP_PID" ]] || wait "$HTTP_PID" 2>/dev/null || true
    rm -rf "$FIXTURE"
    if [[ "$BUILT_PROBE" == 1 ]]; then rm -rf pmap-probe.app; fi
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE/client_key"
python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import getpass, sys
p = Path(sys.argv[1])
(p/'authorized_keys').write_text((p/'client_key.pub').read_text())
(p/'known_hosts').write_text('[127.0.0.1]:39227 ' + (p/'host_key.pub').read_text())
(p/'sshd_config').write_text(f'''Port 39227
ListenAddress 127.0.0.1
HostKey {p}/host_key
PidFile {p}/sshd.pid
AuthorizedKeysFile {p}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding yes
LogLevel ERROR
''')
(p/'serve.py').write_text('''from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"pmap-tunnel-ok")
    def log_message(self, *args): pass
HTTPServer(("127.0.0.1",39228),Handler).serve_forever()
''')
PY
/usr/sbin/sshd -D -e -f "$FIXTURE/sshd_config" > "$FIXTURE/sshd.log" 2>&1 &
SSH_PID=$!
python3 "$FIXTURE/serve.py" > "$FIXTURE/http.log" 2>&1 &
HTTP_PID=$!
# Poll both services and fail before testing if an existing service occupies a port.
python3 - "$SSH_PID" "$HTTP_PID" <<'PY'
import os, socket, sys, time
for port in (39227,39228):
    for attempt in range(50):
        for pid in sys.argv[1:]: os.kill(int(pid),0)
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=.1): break
        except OSError: time.sleep(.1)
    else: raise SystemExit(f'Fixture did not listen on {port}')
PY
PMAP_SANDBOX=1 PMAP_TEST_FIXTURE="$FIXTURE" PMAP_OUTPUT_APP=pmap-probe.app ./build.sh
BUILT_PROBE=1
./pmap-probe.app/Contents/MacOS/pmap --integration
