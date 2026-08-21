#!/usr/bin/env bash
# Self-contained executable tests for install/bmad.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SHIM="$SCRIPT_DIR/bmad"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orvex-bmad-test.XXXXXX")"
TMP_ROOT="$TEST_ROOT/tmp"
HTTP_ROOT="$TEST_ROOT/http-root"
PORT_FILE="$TEST_ROOT/http-port"
HTTP_STATUS_FILE="$TEST_ROOT/http-500"
REQUEST_LOG="$TEST_ROOT/http-requests.log"
HTTP_PID=""
mkdir -p "$TMP_ROOT" "$HTTP_ROOT/releases/latest/download"
export TMPDIR="$TMP_ROOT"
HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
export HOME

cleanup_test() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test EXIT

if grep -nE '\$\{[^}]+,,\}|\$\{[^}]+\^\^\}|declare[[:space:]]+-A|(^|[[:space:]])mapfile([[:space:]]|$)|readarray' "$SHIM"; then
  echo 'FAIL: shim contains bash-4-only constructs; bash 3.2 compatibility is required' >&2
  exit 1
fi

STUB_BIN="$TEST_ROOT/bin"
RELEASE_ROOT="$HTTP_ROOT/releases/latest/download"
mkdir -p "$STUB_BIN"

REAL_SHA256SUM="$(command -v sha256sum 2>/dev/null || true)"
REAL_SHASUM="$(command -v shasum 2>/dev/null || true)"
[ -n "$REAL_SHA256SUM" ] || [ -n "$REAL_SHASUM" ] || { echo "test requires sha256sum or shasum" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'test requires curl' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'test requires python3' >&2; exit 1; }

UNAME_S="Linux"
UNAME_M="x86_64"
CURL_LOG="$REQUEST_LOG"
HASH_LOG="$TEST_ROOT/hash.log"
EXEC_LOG="$TEST_ROOT/exec.log"
RECORD_FILE="$TEST_ROOT/record.log"
SCRIPT_PATH="/bmad-copy"

cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "$ORVEX_TEST_UNAME_S" ;;
  -m) printf '%s\n' "$ORVEX_TEST_UNAME_M" ;;
  *) exit 1 ;;
esac
EOF

cat > "$STUB_BIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="$1"
if mode="$(stat -c '%a' "$file" 2>/dev/null)"; then :; else mode="$(stat -f '%Lp' "$file")"; fi
printf '%s %s\n' "$mode" "$file" >> "$ORVEX_TEST_HASH_LOG"
exec "$ORVEX_TEST_REAL_SHA256SUM" "$file"
EOF

cat > "$STUB_BIN/shasum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "-a" ] && shift 2
exec "$ORVEX_TEST_REAL_SHASUM" -a 256 "$1"
EOF

chmod 755 "$STUB_BIN/uname" "$STUB_BIN/sha256sum" "$STUB_BIN/shasum"

cat > "$TEST_ROOT/http-server.py" <<'PY'
import http.server
import os
import sys

root, port_file, status_file, request_log = sys.argv[1:]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def do_GET(self):
        with open(request_log, "a", encoding="utf-8") as log:
            log.write(self.path + "\n")
        if os.path.exists(status_file) and self.path == "/releases/latest/download/orvex-installer-linux-amd64":
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"intentional test 500\n")
            return
        super().do_GET()

    def log_message(self, _format, *_args):
        return

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as port:
    port.write(str(server.server_port))
server.serve_forever()
PY

python3 -u "$TEST_ROOT/http-server.py" "$HTTP_ROOT" "$PORT_FILE" "$HTTP_STATUS_FILE" "$REQUEST_LOG" &
HTTP_PID=$!
for _attempt in $(seq 1 100); do
  [ -s "$PORT_FILE" ] && break
  kill -0 "$HTTP_PID" 2>/dev/null || { echo 'FAIL: HTTP server exited before readiness' >&2; exit 1; }
  sleep 0.01
done
[ -s "$PORT_FILE" ] || { echo 'FAIL: HTTP server did not become ready' >&2; exit 1; }
HTTP_BASE="http://127.0.0.1:$(cat "$PORT_FILE")"
SCRIPT_URL="$HTTP_BASE$SCRIPT_PATH"
cp "$SHIM" "$HTTP_ROOT/bmad-copy"


export PATH="$STUB_BIN:$PATH"
export ORVEX_TEST_UNAME_S="$UNAME_S"
export ORVEX_TEST_UNAME_M="$UNAME_M"
export ORVEX_TEST_HASH_LOG="$HASH_LOG"
export ORVEX_TEST_REAL_SHA256SUM="$REAL_SHA256SUM"
export ORVEX_TEST_REAL_SHASUM="$REAL_SHASUM"
export ORVEX_TEST_RECORD="$RECORD_FILE"
export ORVEX_TEST_EXEC_LOG="$EXEC_LOG"

make_binary() {
  cat > "$RELEASE_ROOT/$1" <<'EOF'
#!/usr/bin/env bash
printf 'EXECUTED\n' >> "$ORVEX_TEST_EXEC_LOG"
{
  printf 'ARGC=%s\n' "$#"
  i=0
  for arg in "$@"; do
    printf 'ARG[%s]=%s\n' "$i" "$arg"
    i=$((i + 1))
  done
  for name in ORVEX_BMAD_PROJECT ORVEX_BMAD_CUSTOM ORVEX_BMAD_EMPTY ORVEX_BMAD_COMMAND ORVEX_BMAD_BOOTSTRAPPED_VERSION ORVEX_BMAD_RELEASE_BASE_URL; do
    if [ "${!name+x}" = x ]; then printf '%s=%s\n' "$name" "${!name}"; else printf '%s=<unset>\n' "$name"; fi
  done
} > "$ORVEX_TEST_RECORD"
EOF
  chmod 644 "$RELEASE_ROOT/$1"
}

make_checksums() {
  : > "$RELEASE_ROOT/checksums.txt"
  for asset in "$@"; do
    if [ -n "$REAL_SHA256SUM" ]; then
      digest="$("$REAL_SHA256SUM" "$RELEASE_ROOT/$asset")"
      digest="${digest%% *}"
    else
      digest="$("$REAL_SHASUM" -a 256 "$RELEASE_ROOT/$asset")"
      digest="${digest%% *}"
    fi
    printf '%s  %s\n' "$digest" "$asset" >> "$RELEASE_ROOT/checksums.txt"
  done
}

reset_logs() {
  : > "$CURL_LOG"
  : > "$HASH_LOG"
  : > "$EXEC_LOG"
  : > "$RECORD_FILE"
  : > "$REQUEST_LOG"
  rm -f "$HTTP_STATUS_FILE"
  rm -f "$RELEASE_ROOT"/*
}

assert_contains() {
  needle="$1"
  file="$2"
  grep -Fq -- "$needle" "$file" || { echo "FAIL: missing '$needle' in $file" >&2; exit 1; }
}

assert_not_contains() {
  needle="$1"
  file="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "FAIL: unexpected '$needle' in $file" >&2
    exit 1
  fi
}

run_capture() {
  output_file="$TEST_ROOT/stdout"
  error_file="$TEST_ROOT/stderr"
  if "$@" >"$output_file" 2>"$error_file"; then
    LAST_RC=0
  else
    LAST_RC=$?
  fi
}

snapshot_temps() {
  find "$TMP_ROOT" -maxdepth 1 -type f -name 'orvex-bmad*' -print > "$1"
}

begin_failure() {
  failure_label="$1"
  TEMP_BEFORE="$TEST_ROOT/${failure_label}.before"
  TEMP_AFTER="$TEST_ROOT/${failure_label}.after"
  snapshot_temps "$TEMP_BEFORE"
}

assert_failure_cleanup() {
  snapshot_temps "$TEMP_AFTER"
  cmp -s "$TEMP_BEFORE" "$TEMP_AFTER" || { echo "FAIL: $failure_label changed the temp snapshot" >&2; exit 1; }
}

assert_success_asset_only() {
  success_dir="$1"
  success_snapshot="$TEST_ROOT/success.snapshot"
  find "$success_dir" -maxdepth 1 -type f -name 'orvex-bmad*' -print > "$success_snapshot"
  success_count="$(wc -l < "$success_snapshot")"
  [ "$success_count" -eq 1 ] || { echo "FAIL: successful run left $success_count BMAD temp files; expected one asset" >&2; exit 1; }
  success_file=""
  IFS= read -r success_file < "$success_snapshot"
  case "$success_file" in
    *orvex-bmad-asset.*) ;;
    *) echo "FAIL: successful run left unexpected temp file: $success_file" >&2; exit 1 ;;
  esac
}

run_matrix_case() {
  platform="$1"
  machine="$2"
  expected="$3"
  reset_logs
  make_binary "$expected"
  make_checksums "$expected"
  export ORVEX_TEST_UNAME_S="$platform" ORVEX_TEST_UNAME_M="$machine"
  export ORVEX_BMAD_RELEASE_BASE_URL="$HTTP_BASE/releases/latest/download"
  unset ORVEX_BMAD_BOOTSTRAPPED_VERSION ORVEX_BMAD_PROJECT ORVEX_BMAD_CUSTOM ORVEX_BMAD_EMPTY ORVEX_BMAD_COMMAND
  run_capture bash "$SHIM" --non-interactive
  [ "$LAST_RC" -eq 0 ] || { echo "FAIL: matrix case $platform/$machine exited $LAST_RC" >&2; exit 1; }
  assert_contains "/releases/latest/download/$expected" "$CURL_LOG"
  assert_contains 'ORVEX_BMAD_BOOTSTRAPPED_VERSION=latest' "$RECORD_FILE"
}

echo '1. architecture/platform matrix'
run_matrix_case Linux x86_64 orvex-installer-linux-amd64
run_matrix_case Linux amd64 orvex-installer-linux-amd64
run_matrix_case Linux aarch64 orvex-installer-linux-arm64
run_matrix_case Linux arm64 orvex-installer-linux-arm64
run_matrix_case Darwin x86_64 orvex-installer-darwin-amd64
run_matrix_case Darwin amd64 orvex-installer-darwin-amd64
run_matrix_case Darwin aarch64 orvex-installer-darwin-arm64
run_matrix_case Darwin arm64 orvex-installer-darwin-arm64
echo '   PASS'

echo '2. unsupported platform/architecture'
reset_logs
export ORVEX_TEST_UNAME_S=Windows ORVEX_TEST_UNAME_M=x86_64
begin_failure unsupported-platform
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: unsupported platform succeeded' >&2; exit 1; }
assert_contains "ERROR: unsupported platform 'Windows'" "$TEST_ROOT/stderr"
assert_failure_cleanup
export ORVEX_TEST_UNAME_S=Linux ORVEX_TEST_UNAME_M=386
begin_failure unsupported-architecture
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: unsupported architecture succeeded' >&2; exit 1; }
assert_contains "ERROR: unsupported architecture '386'" "$TEST_ROOT/stderr"
assert_failure_cleanup
echo '   PASS'

echo '3. missing asset (HTTP 404)'
reset_logs
export ORVEX_TEST_UNAME_S=Linux ORVEX_TEST_UNAME_M=x86_64
begin_failure missing-asset
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: missing asset succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: missing asset executed binary' >&2; exit 1; }
assert_contains 'ERROR: download failed:' "$TEST_ROOT/stderr"
assert_contains '/releases/latest/download/orvex-installer-linux-amd64' "$CURL_LOG"
assert_failure_cleanup
echo '   PASS'

echo '4. checksum mismatch: non-executable and not executed'
reset_logs
make_binary orvex-installer-linux-amd64
printf '%064d  orvex-installer-linux-amd64\n' 0 > "$RELEASE_ROOT/checksums.txt"
begin_failure checksum-mismatch
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: checksum mismatch succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: checksum mismatch executed binary' >&2; exit 1; }
mode="$(cut -d' ' -f1 "$HASH_LOG")"
[ "$mode" != 755 ] || { echo 'FAIL: checksum mismatch made asset executable' >&2; exit 1; }
assert_failure_cleanup
echo '   PASS (hash stub observed mode '"$mode"'; exec log empty)'

echo '5. no-argument defaults to install'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
SUCCESS_TMP_ROOT="$TEST_ROOT/success-tmp"
mkdir -p "$SUCCESS_TMP_ROOT"
OLD_TMPDIR="$TMPDIR"
export TMPDIR="$SUCCESS_TMP_ROOT"
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
run_capture bash "$SHIM"
[ "$LAST_RC" -eq 0 ] || { echo 'FAIL: no-argument invocation failed' >&2; exit 1; }
assert_contains 'ARGC=1' "$RECORD_FILE"
assert_contains 'ARG[0]=install' "$RECORD_FILE"
assert_success_asset_only "$SUCCESS_TMP_ROOT"
export TMPDIR="$OLD_TMPDIR"
echo '   PASS'

echo '6. args and ORVEX_BMAD_* forwarding'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_BMAD_PROJECT=project-a ORVEX_BMAD_CUSTOM='value with spaces' ORVEX_BMAD_EMPTY='' ORVEX_BMAD_COMMAND=update
export ORVEX_BMAD_BOOTSTRAPPED_VERSION=caller-version
run_capture bash "$SHIM" --non-interactive update --flag 'two words'
[ "$LAST_RC" -eq 0 ] || { echo 'FAIL: forwarding invocation failed' >&2; exit 1; }
assert_contains 'ARGC=4' "$RECORD_FILE"
assert_contains 'ARG[0]=--non-interactive' "$RECORD_FILE"
assert_contains 'ARG[1]=update' "$RECORD_FILE"
assert_contains 'ARG[2]=--flag' "$RECORD_FILE"
assert_contains 'ARG[3]=two words' "$RECORD_FILE"
assert_contains 'ORVEX_BMAD_PROJECT=project-a' "$RECORD_FILE"
assert_contains 'ORVEX_BMAD_CUSTOM=value with spaces' "$RECORD_FILE"
assert_contains 'ORVEX_BMAD_EMPTY=' "$RECORD_FILE"
assert_contains 'ORVEX_BMAD_COMMAND=update' "$RECORD_FILE"
assert_contains 'ORVEX_BMAD_BOOTSTRAPPED_VERSION=caller-version' "$RECORD_FILE"
echo '   PASS'

echo '7. curl | bash self-re-exec'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_TEST_UNAME_S=Linux ORVEX_TEST_UNAME_M=x86_64
export ORVEX_BMAD_SCRIPT_URL="$SCRIPT_URL"
unset ORVEX_BMAD_BOOTSTRAPPED_VERSION ORVEX_BMAD_PROJECT ORVEX_BMAD_CUSTOM ORVEX_BMAD_EMPTY ORVEX_BMAD_COMMAND
if command -v script >/dev/null 2>&1; then
  transcript="$TEST_ROOT/transcript"
  if script -qec "cat '$SHIM' | bash" "$transcript" >"$TEST_ROOT/script.stdout" 2>"$TEST_ROOT/script.stderr"; then
    LAST_RC=0
  else
    LAST_RC=$?
  fi
  [ "$LAST_RC" -eq 0 ] || { echo "FAIL: pty self-reexec exited $LAST_RC" >&2; exit 1; }
  [ "$(grep -Fxc -- "$SCRIPT_PATH" "$CURL_LOG")" -eq 1 ] || { echo 'FAIL: self-reexec did not fetch script exactly once' >&2; exit 1; }
  assert_contains 'ARG[0]=install' "$RECORD_FILE"
  echo '   PASS (script URL fetched once, then stdin came from /dev/tty)'
else
  echo '   FAIL (script command unavailable; pty re-exec cannot be measured)' >&2
  exit 1
fi

echo '8. --non-interactive skips self-re-exec'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_BMAD_SCRIPT_URL="$HTTP_BASE/should-not-be-fetched"
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -eq 0 ] || { echo 'FAIL: non-interactive invocation failed' >&2; exit 1; }
assert_not_contains '/should-not-be-fetched' "$CURL_LOG"
echo '   PASS'

echo '9. --quiet skips self-re-exec'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_BMAD_SCRIPT_URL="$HTTP_BASE/should-not-be-fetched"
run_capture bash "$SHIM" --quiet
[ "$LAST_RC" -eq 0 ] || { echo 'FAIL: quiet invocation failed' >&2; exit 1; }
assert_not_contains '/should-not-be-fetched' "$CURL_LOG"
echo '   PASS'

echo '10. missing checksums.txt (HTTP 404)'
reset_logs
make_binary orvex-installer-linux-amd64
begin_failure missing-checksums
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: missing checksums succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: missing checksums executed binary' >&2; exit 1; }
assert_contains 'ERROR: download failed:' "$TEST_ROOT/stderr"
assert_contains '/releases/latest/download/checksums.txt' "$CURL_LOG"
assert_failure_cleanup
echo '   PASS'

echo '11. asset server error (HTTP 500)'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
: > "$HTTP_STATUS_FILE"
begin_failure asset-500
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: HTTP 500 asset succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: HTTP 500 asset executed binary' >&2; exit 1; }
assert_contains 'ERROR: download failed:' "$TEST_ROOT/stderr"
assert_contains '/releases/latest/download/orvex-installer-linux-amd64' "$CURL_LOG"
assert_failure_cleanup
echo '   PASS'

echo '12. bootstrap temp cleanup on a post-reexec failure'
reset_logs
export ORVEX_BMAD_SCRIPT_URL="$SCRIPT_URL"
begin_failure bootstrap-failure
if script -qec "cat '$SHIM' | bash" "$TEST_ROOT/bootstrap-failure.transcript" >"$TEST_ROOT/bootstrap-failure.stdout" 2>"$TEST_ROOT/bootstrap-failure.stderr"; then
  LAST_RC=0
else
  LAST_RC=$?
fi
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: post-reexec missing asset succeeded' >&2; exit 1; }
[ "$(grep -Fxc -- "$SCRIPT_PATH" "$CURL_LOG")" -eq 1 ] || { echo 'FAIL: post-reexec failure did not fetch the script exactly once' >&2; exit 1; }
assert_failure_cleanup
echo '   PASS'

# --- A19: downloading when the installer repo is private -------------------
#
# These tests never contact a real repository. The curl wrapper answers any
# github.com URL with 404 without touching the network, and delegates every
# other URL to the real curl so the local-server tests are unaffected. The
# fixture repo below deliberately does not exist, so even a scoping regression
# cannot reach a real one.
GH_LOG="$TEST_ROOT/gh.log"
GH_BIN="$TEST_ROOT/gh-bin"
NOGH_BIN="$TEST_ROOT/nogh-bin"
FIXTURE_REPO='orvex-shim-test/fixture'
FIXTURE_BASE="https://github.com/$FIXTURE_REPO/releases/latest/download"
mkdir -p "$GH_BIN" "$NOGH_BIN"
export ORVEX_TEST_REAL_CURL="$(command -v curl)"
export ORVEX_TEST_GH_LOG="$GH_LOG"
export ORVEX_TEST_RELEASE_ROOT="$RELEASE_ROOT"
export ORVEX_TEST_CURL_LOG="$CURL_LOG"

cat > "$GH_BIN/curl" <<'EOF'
#!/usr/bin/env bash
dest=""
gh_url=""
prev=""
for arg in "$@"; do
  case "$prev" in -o) dest="$arg" ;; esac
  case "$arg" in https://github.com/*) gh_url="$arg" ;; esac
  prev="$arg"
done
if [ -n "$gh_url" ]; then
  printf '%s\n' "$gh_url" >> "$ORVEX_TEST_CURL_LOG"
  [ -z "$dest" ] || : > "$dest"
  printf '404'
  exit 0
fi
exec "$ORVEX_TEST_REAL_CURL" "$@"
EOF

cat > "$GH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORVEX_TEST_GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  if [ -n "${ORVEX_TEST_GH_UNAUTH:-}" ]; then
    printf 'not logged into any GitHub hosts; run gh auth login\n' >&2
    exit 1
  fi
  exit 0
fi
out=""
pattern=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --output|-O) out="$arg" ;;
    --pattern|-p) pattern="$arg" ;;
  esac
  prev="$arg"
done
[ -z "${ORVEX_TEST_GH_FAIL:-}" ] || exit 1
[ -n "$out" ] && [ -n "$pattern" ] || exit 1
cp "$ORVEX_TEST_RELEASE_ROOT/$pattern" "$out"
EOF

# A PATH that genuinely lacks gh. It cannot simply exclude the stub directory:
# gh ships in /usr/bin on developer machines and on GitHub's runners alike, so
# an "absent gh" test that keeps /usr/bin on PATH silently exercises the
# gh-present branch instead — which is how this test first passed for the wrong
# reason. Symlink only what the shim needs, then prove gh is unreachable.
cp "$GH_BIN/curl" "$NOGH_BIN/curl"
cp "$STUB_BIN/uname" "$NOGH_BIN/uname"
cp "$STUB_BIN/sha256sum" "$NOGH_BIN/sha256sum"
cp "$STUB_BIN/shasum" "$NOGH_BIN/shasum"
for _tool in bash mktemp awk chmod rm tr stat; do
  _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
  [ -n "$_tool_path" ] || { echo "FAIL: test setup needs $_tool" >&2; exit 1; }
  ln -sf "$_tool_path" "$NOGH_BIN/$_tool"
done
chmod 755 "$GH_BIN/curl" "$GH_BIN/gh" "$NOGH_BIN/curl" "$NOGH_BIN/uname" "$NOGH_BIN/sha256sum" "$NOGH_BIN/shasum"
# Assert the precondition rather than assuming it.
if PATH="$NOGH_BIN" command -v gh >/dev/null 2>&1; then
  echo 'FAIL: the no-gh PATH still resolves gh; test 14 would measure the wrong branch' >&2
  exit 1
fi

echo '13. anonymous 200 never invokes gh'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_BMAD_RELEASE_BASE_URL="$HTTP_BASE/releases/latest/download"
export ORVEX_BMAD_GH_REPO="$FIXTURE_REPO"
run_capture env PATH="$GH_BIN:$PATH" bash "$SHIM" --non-interactive
[ "$LAST_RC" -eq 0 ] || { echo "FAIL: anonymous 200 did not install (rc=$LAST_RC)" >&2; exit 1; }
[ ! -s "$GH_LOG" ] || { echo 'FAIL: gh was invoked after an anonymous 200' >&2; cat "$GH_LOG" >&2; exit 1; }
[ -s "$EXEC_LOG" ] || { echo 'FAIL: anonymous 200 did not execute the binary' >&2; exit 1; }
echo "   PASS (exit $LAST_RC; gh call log stayed empty)"

echo '14. private-repo 404 falls back to gh and installs'
reset_logs
: > "$GH_LOG"
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_BMAD_RELEASE_BASE_URL="$FIXTURE_BASE"
export ORVEX_BMAD_GH_REPO="$FIXTURE_REPO"
run_capture env PATH="$GH_BIN:$PATH" bash "$SHIM" --non-interactive
[ "$LAST_RC" -eq 0 ] || { echo "FAIL: gh fallback did not install (rc=$LAST_RC)" >&2; cat "$TEST_ROOT/stderr" >&2; exit 1; }
[ -s "$EXEC_LOG" ] || { echo 'FAIL: gh fallback did not execute the binary' >&2; exit 1; }
assert_contains 'auth status' "$GH_LOG"
assert_contains "--repo $FIXTURE_REPO" "$GH_LOG"
assert_contains '--pattern orvex-installer-linux-amd64' "$GH_LOG"
assert_contains '--pattern checksums.txt' "$GH_LOG"
echo "   PASS (exit $LAST_RC; anonymous 404, then gh supplied both asset and checksums)"

echo '15. 404 with no gh available says GitHub CLI is required'
reset_logs
: > "$GH_LOG"
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_BMAD_RELEASE_BASE_URL="$FIXTURE_BASE"
begin_failure no-gh
run_capture env -i \
  PATH="$NOGH_BIN" \
  HOME="$HOME" \
  TMPDIR="$TMPDIR" \
  ORVEX_BMAD_RELEASE_BASE_URL="$FIXTURE_BASE" \
  ORVEX_TEST_UNAME_S="$ORVEX_TEST_UNAME_S" \
  ORVEX_TEST_UNAME_M="$ORVEX_TEST_UNAME_M" \
  ORVEX_TEST_HASH_LOG="$HASH_LOG" \
  ORVEX_TEST_REAL_SHA256SUM="$REAL_SHA256SUM" \
  ORVEX_TEST_REAL_SHASUM="$REAL_SHASUM" \
  ORVEX_TEST_REAL_CURL="$ORVEX_TEST_REAL_CURL" \
  ORVEX_TEST_CURL_LOG="$CURL_LOG" \
  ORVEX_TEST_GH_LOG="$GH_LOG" \
  ORVEX_TEST_EXEC_LOG="$EXEC_LOG" \
  ORVEX_TEST_RECORD="$RECORD_FILE" \
  bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: 404 without gh succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: 404 without gh executed the binary' >&2; exit 1; }
[ ! -s "$GH_LOG" ] || { echo 'FAIL: the gh stub ran while gh was meant to be absent' >&2; exit 1; }
# Distinctive to this branch: the authenticated-gh branch says the asset is
# missing, while this branch says the CLI itself is required.
assert_contains 'GitHub CLI is required' "$TEST_ROOT/stderr"
assert_contains 'Install GitHub CLI' "$TEST_ROOT/stderr"
assert_not_contains 'gh is not authenticated' "$TEST_ROOT/stderr"
assert_not_contains 'The asset does not exist' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo "   PASS (exit $LAST_RC; private-repo/gh-absent diagnostic was selected)"

echo '16. gh present but unauthenticated says gh auth login is needed'
reset_logs
: > "$GH_LOG"
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
export ORVEX_BMAD_RELEASE_BASE_URL="$FIXTURE_BASE"
export ORVEX_BMAD_GH_REPO="$FIXTURE_REPO"
begin_failure gh-fails
run_capture env PATH="$GH_BIN:$PATH" ORVEX_TEST_GH_UNAUTH=1 bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: unauthenticated gh still succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: failing gh executed the binary' >&2; exit 1; }
[ -s "$GH_LOG" ] || { echo 'FAIL: gh was never attempted' >&2; exit 1; }
assert_contains 'gh is not authenticated' "$TEST_ROOT/stderr"
assert_contains 'gh auth login' "$TEST_ROOT/stderr"
assert_not_contains 'The asset does not exist' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo "   PASS (exit $LAST_RC; unauthenticated-gh diagnostic was selected)"

echo '17. authenticated gh reports a genuinely missing asset'
reset_logs
: > "$GH_LOG"
export ORVEX_BMAD_RELEASE_BASE_URL="$FIXTURE_BASE"
export ORVEX_BMAD_GH_REPO="$FIXTURE_REPO"
begin_failure gh-missing-asset
run_capture env PATH="$GH_BIN:$PATH" bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: missing gh asset succeeded' >&2; exit 1; }
[ -s "$GH_LOG" ] || { echo 'FAIL: authenticated gh was never attempted' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: missing gh asset executed the binary' >&2; exit 1; }
assert_contains "release asset 'orvex-installer-linux-amd64' is missing" "$TEST_ROOT/stderr"
assert_contains 'The asset does not exist: orvex-installer-linux-amd64' "$TEST_ROOT/stderr"
assert_not_contains 'gh is not authenticated' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo "   PASS (exit $LAST_RC; missing asset was named explicitly)"

echo '18. checksum mismatch after gh download is not executable or executed'
reset_logs
make_binary orvex-installer-linux-amd64
printf '%064d  orvex-installer-linux-amd64\n' 0 > "$RELEASE_ROOT/checksums.txt"
export ORVEX_BMAD_RELEASE_BASE_URL="$FIXTURE_BASE"
export ORVEX_BMAD_GH_REPO="$FIXTURE_REPO"
begin_failure gh-checksum-mismatch
run_capture env PATH="$GH_BIN:$PATH" bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: gh checksum mismatch succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: gh checksum mismatch executed the binary' >&2; exit 1; }
mode="$(cut -d' ' -f1 "$HASH_LOG")"
[ "$mode" != 755 ] || { echo 'FAIL: gh checksum mismatch made asset executable' >&2; exit 1; }
assert_contains 'ERROR: SHA-256 mismatch for orvex-installer-linux-amd64' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo "   PASS (exit $LAST_RC; hash observed mode $mode and exec log stayed empty)"

echo '19. a non-github base URL must never reach gh without an override'
reset_logs
: > "$GH_LOG"
export ORVEX_BMAD_RELEASE_BASE_URL="$HTTP_BASE/releases/latest/download"
unset ORVEX_BMAD_GH_REPO
begin_failure no-fallback-for-custom-base
run_capture env PATH="$GH_BIN:$PATH" bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: missing asset on a custom base succeeded' >&2; exit 1; }
[ ! -s "$GH_LOG" ] || { echo 'FAIL: custom base URL fell back to gh, masking a local failure' >&2; cat "$GH_LOG" >&2; exit 1; }
assert_contains 'ERROR: download failed:' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo '   PASS (local failure surfaced as itself, not routed to a different source)'

echo '20. the default release URL targets the real installer repo'
reset_logs
: > "$GH_LOG"
unset ORVEX_BMAD_RELEASE_BASE_URL
unset ORVEX_BMAD_GH_REPO
begin_failure default-base-url
run_capture env PATH="$GH_BIN:$PATH" ORVEX_TEST_GH_UNAUTH=1 bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: default base URL unexpectedly installed' >&2; exit 1; }
assert_contains 'https://github.com/orvexai/orvex-installer/releases/latest/download/orvex-installer-linux-amd64' "$CURL_LOG"
assert_contains 'auth status' "$GH_LOG"
assert_contains 'ERROR: orvexai/orvex-installer is unreachable anonymously (HTTP 404), and gh is not authenticated.' "$TEST_ROOT/stderr"
assert_contains 'gh auth login' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo "   PASS (exit $LAST_RC; default repo named in auth diagnostic)"

# A18 mutation: change the resolved default slug and require this branch's
# exact diagnostic to name the mutation, rather than passing generically.
MUTATED_DEFAULT_REPO='orvexai/mutated-installer'
reset_logs
: > "$GH_LOG"
unset ORVEX_BMAD_RELEASE_BASE_URL
export ORVEX_BMAD_GH_REPO="$MUTATED_DEFAULT_REPO"
begin_failure default-base-url-mutated-unauth
run_capture env PATH="$GH_BIN:$PATH" ORVEX_TEST_GH_UNAUTH=1 bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: mutated unauthenticated default repo succeeded' >&2; exit 1; }
MUTATED_UNAUTH_ERROR="ERROR: $MUTATED_DEFAULT_REPO is unreachable anonymously (HTTP 404), and gh is not authenticated."
assert_contains "$MUTATED_UNAUTH_ERROR" "$TEST_ROOT/stderr"
assert_not_contains 'ERROR: orvexai/orvex-installer is unreachable anonymously' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo "   PASS (mutation $MUTATED_DEFAULT_REPO; exact failure: $MUTATED_UNAUTH_ERROR)"

echo '21. authenticated default repo is passed to gh release download'
reset_logs
: > "$GH_LOG"
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
unset ORVEX_BMAD_RELEASE_BASE_URL
unset ORVEX_BMAD_GH_REPO
run_capture env PATH="$GH_BIN:$PATH" bash "$SHIM" --non-interactive
[ "$LAST_RC" -eq 0 ] || { echo "FAIL: authenticated default fallback did not install (rc=$LAST_RC)" >&2; cat "$TEST_ROOT/stderr" >&2; exit 1; }
[ -s "$EXEC_LOG" ] || { echo 'FAIL: authenticated default fallback did not execute the binary' >&2; exit 1; }
assert_contains 'https://github.com/orvexai/orvex-installer/releases/latest/download/orvex-installer-linux-amd64' "$CURL_LOG"
assert_contains '--repo orvexai/orvex-installer' "$GH_LOG"
assert_contains '--pattern orvex-installer-linux-amd64' "$GH_LOG"
assert_contains '--pattern checksums.txt' "$GH_LOG"
echo "   PASS (exit $LAST_RC; gh release download received --repo orvexai/orvex-installer)"

# A18 mutation: with auth available, the missing-asset diagnostic must name
# the mutated slug too; otherwise a generic missing-asset assertion could pass.
reset_logs
: > "$GH_LOG"
unset ORVEX_BMAD_RELEASE_BASE_URL
export ORVEX_BMAD_GH_REPO="$MUTATED_DEFAULT_REPO"
begin_failure default-base-url-mutated-missing
run_capture env PATH="$GH_BIN:$PATH" bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: mutated authenticated default repo succeeded' >&2; exit 1; }
MUTATED_MISSING_ERROR="ERROR: $MUTATED_DEFAULT_REPO is reachable with gh, but release asset 'orvex-installer-linux-amd64' is missing for this platform/release."
assert_contains "$MUTATED_MISSING_ERROR" "$TEST_ROOT/stderr"
assert_not_contains 'gh is not authenticated' "$TEST_ROOT/stderr"
assert_failure_cleanup
echo "   PASS (mutation $MUTATED_DEFAULT_REPO; exact failure: $MUTATED_MISSING_ERROR)"


echo 'All numbered BMAD shim tests passed.'
