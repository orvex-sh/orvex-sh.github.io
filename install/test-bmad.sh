#!/usr/bin/env bash
# Self-contained executable tests for install/bmad.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SHIM="$SCRIPT_DIR/bmad"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orvex-bmad-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

if grep -nE '\$\{[^}]+,,\}|\$\{[^}]+\^\^\}|declare[[:space:]]+-A|(^|[[:space:]])mapfile([[:space:]]|$)|readarray' "$SHIM"; then
  echo 'FAIL: shim contains bash-4-only constructs; bash 3.2 compatibility is required' >&2
  exit 1
fi

STUB_BIN="$TEST_ROOT/bin"
RELEASE_ROOT="$TEST_ROOT/releases/latest/download"
mkdir -p "$STUB_BIN" "$RELEASE_ROOT"

REAL_SHA256SUM="$(command -v sha256sum 2>/dev/null || true)"
REAL_SHASUM="$(command -v shasum 2>/dev/null || true)"
[ -n "$REAL_SHA256SUM" ] || [ -n "$REAL_SHASUM" ] || { echo "test requires sha256sum or shasum" >&2; exit 1; }

UNAME_S="Linux"
UNAME_M="x86_64"
CURL_LOG="$TEST_ROOT/curl.log"
HASH_LOG="$TEST_ROOT/hash.log"
EXEC_LOG="$TEST_ROOT/exec.log"
RECORD_FILE="$TEST_ROOT/record.log"
SCRIPT_URL="$TEST_ROOT/bmad-copy"

cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "$ORVEX_TEST_UNAME_S" ;;
  -m) printf '%s\n' "$ORVEX_TEST_UNAME_M" ;;
  *) exit 1 ;;
esac
EOF

cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$ORVEX_TEST_CURL_LOG"
[ -n "$out" ] || { echo "curl stub: missing -o" >&2; exit 2; }
if [ "$url" = "$ORVEX_TEST_SCRIPT_URL" ]; then
  cp "$ORVEX_TEST_SHIM" "$out"
elif [ -f "$url" ]; then
  cp "$url" "$out"
else
  echo "curl stub: missing fixture $url" >&2
  exit 22
fi
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

chmod 755 "$STUB_BIN/uname" "$STUB_BIN/curl" "$STUB_BIN/sha256sum" "$STUB_BIN/shasum"
cp "$SHIM" "$SCRIPT_URL"

export PATH="$STUB_BIN:$PATH"
export ORVEX_TEST_UNAME_S="$UNAME_S"
export ORVEX_TEST_UNAME_M="$UNAME_M"
export ORVEX_TEST_CURL_LOG="$CURL_LOG"
export ORVEX_TEST_HASH_LOG="$HASH_LOG"
export ORVEX_TEST_REAL_SHA256SUM="$REAL_SHA256SUM"
export ORVEX_TEST_REAL_SHASUM="$REAL_SHASUM"
export ORVEX_TEST_SCRIPT_URL="$SCRIPT_URL"
export ORVEX_TEST_SHIM="$SHIM"
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

run_matrix_case() {
  platform="$1"
  machine="$2"
  expected="$3"
  reset_logs
  make_binary "$expected"
  make_checksums "$expected"
  export ORVEX_TEST_UNAME_S="$platform" ORVEX_TEST_UNAME_M="$machine"
  export ORVEX_BMAD_RELEASE_BASE_URL="$RELEASE_ROOT"
  unset ORVEX_BMAD_BOOTSTRAPPED_VERSION ORVEX_BMAD_PROJECT ORVEX_BMAD_CUSTOM ORVEX_BMAD_EMPTY ORVEX_BMAD_COMMAND
  run_capture bash "$SHIM" --non-interactive
  [ "$LAST_RC" -eq 0 ] || { echo "FAIL: matrix case $platform/$machine exited $LAST_RC" >&2; exit 1; }
  assert_contains "$RELEASE_ROOT/$expected" "$CURL_LOG"
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
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: unsupported platform succeeded' >&2; exit 1; }
assert_contains "ERROR: unsupported platform 'Windows'" "$TEST_ROOT/stderr"
export ORVEX_TEST_UNAME_S=Linux ORVEX_TEST_UNAME_M=386
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: unsupported architecture succeeded' >&2; exit 1; }
assert_contains "ERROR: unsupported architecture '386'" "$TEST_ROOT/stderr"
echo '   PASS'

echo '3. missing asset'
reset_logs
export ORVEX_TEST_UNAME_S=Linux ORVEX_TEST_UNAME_M=x86_64
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: missing asset succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: missing asset executed binary' >&2; exit 1; }
assert_contains 'ERROR: download failed:' "$TEST_ROOT/stderr"
echo '   PASS'

echo '4. checksum mismatch: non-executable and not executed'
reset_logs
make_binary orvex-installer-linux-amd64
printf '%064d  orvex-installer-linux-amd64\n' 0 > "$RELEASE_ROOT/checksums.txt"
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -ne 0 ] || { echo 'FAIL: checksum mismatch succeeded' >&2; exit 1; }
[ ! -s "$EXEC_LOG" ] || { echo 'FAIL: checksum mismatch executed binary' >&2; exit 1; }
mode="$(cut -d' ' -f1 "$HASH_LOG")"
[ "$mode" != 755 ] || { echo 'FAIL: checksum mismatch made asset executable' >&2; exit 1; }
echo '   PASS (hash stub observed mode '"$mode"'; exec log empty)'

echo '5. no-argument defaults to install'
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -eq 0 ] || { echo 'FAIL: setup for default command failed' >&2; exit 1; }
reset_logs
make_binary orvex-installer-linux-amd64
make_checksums orvex-installer-linux-amd64
run_capture bash "$SHIM"
[ "$LAST_RC" -eq 0 ] || { echo 'FAIL: no-argument invocation failed' >&2; exit 1; }
assert_contains 'ARGC=1' "$RECORD_FILE"
assert_contains 'ARG[0]=install' "$RECORD_FILE"
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
  [ "$(grep -Fxc -- "$SCRIPT_URL" "$CURL_LOG")" -eq 1 ] || { echo 'FAIL: self-reexec did not fetch script exactly once' >&2; exit 1; }
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
export ORVEX_BMAD_SCRIPT_URL="$TEST_ROOT/should-not-be-fetched"
run_capture bash "$SHIM" --non-interactive
[ "$LAST_RC" -eq 0 ] || { echo 'FAIL: non-interactive invocation failed' >&2; exit 1; }
assert_not_contains "$TEST_ROOT/should-not-be-fetched" "$CURL_LOG"
echo '   PASS'

echo 'All numbered BMAD shim tests passed.'
