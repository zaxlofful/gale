#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LAUNCHER="$ROOT/packaging/macos/gale-wine"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

assert_status() {
  expected=$1
  shift
  set +e
  "$@" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    printf 'expected status %s, got %s\n' "$expected" "$actual" >&2
    cat "$TMP_ROOT/stderr" >&2
    exit 1
  fi
}

assert_stderr_contains() {
  if ! grep -F "$1" "$TMP_ROOT/stderr" >/dev/null; then
    printf 'stderr did not contain: %s\n' "$1" >&2
    cat "$TMP_ROOT/stderr" >&2
    exit 1
  fi
}

assert_file_equals() {
  expected=$1
  file=$2
  actual=$(cat "$file")
  if [ "$actual" != "$expected" ]; then
    printf 'expected %s to contain "%s", got "%s"\n' "$file" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_log_count() {
  expected=$1
  pattern=$2
  actual=$(grep -F -c "$pattern" "$LOG" || true)
  if [ "$actual" -ne "$expected" ]; then
    printf 'expected %s log entries matching "%s", got %s\n' "$expected" "$pattern" "$actual" >&2
    cat "$LOG" >&2
    exit 1
  fi
}

assert_status 64 env GALE_WINE_OS=Linux GALE_WINE_ARCH=arm64 "$LAUNCHER"
assert_stderr_contains "requires macOS"

assert_status 64 env GALE_WINE_OS=Darwin GALE_WINE_ARCH=x86_64 "$LAUNCHER"
assert_stderr_contains "requires Apple Silicon"

assert_status 69 env \
  GALE_WINE_OS=Darwin \
  GALE_WINE_ARCH=arm64 \
  GALE_WINE_ROSETTA_CHECK=false \
  "$LAUNCHER"
assert_stderr_contains "Rosetta 2"

FAKE_BIN="$TMP_ROOT/fake wine/bin"
mkdir -p "$FAKE_BIN"
for tool in wine wineboot winepath; do
  printf '#!/bin/sh\nexit 0\n' >"$FAKE_BIN/$tool"
  chmod +x "$FAKE_BIN/$tool"
done

assert_status 66 env \
  GALE_WINE_OS=Darwin \
  GALE_WINE_ARCH=arm64 \
  GALE_WINE_ROSETTA_CHECK=true \
  GALE_WINE_BIN="$FAKE_BIN/wine" \
  GALE_WINE_MSI="$TMP_ROOT/missing.msi" \
  "$LAUNCHER"
assert_stderr_contains "MSI payload is missing"

assert_status 69 env \
  PATH=/usr/bin:/bin \
  GALE_WINE_OS=Darwin \
  GALE_WINE_ARCH=arm64 \
  GALE_WINE_ROSETTA_CHECK=true \
  GALE_WINE_MSI="$TMP_ROOT/missing.msi" \
  "$LAUNCHER"
assert_stderr_contains "no compatible Wine runtime"

cat >"$FAKE_BIN/wineboot" <<'EOF'
#!/bin/sh
printf 'wineboot %s\n' "$*" >>"$GALE_WINE_TEST_LOG"
mkdir -p "$WINEPREFIX"
touch "$WINEPREFIX/system.reg"
exit 0
EOF

cat >"$FAKE_BIN/winepath" <<'EOF'
#!/bin/sh
printf 'winepath %s\n' "$*" >>"$GALE_WINE_TEST_LOG"
printf 'Z:\\Gale 1.16.1.msi\n'
EOF

cat >"$FAKE_BIN/wine" <<'EOF'
#!/bin/sh
printf 'wine %s\n' "$*" >>"$GALE_WINE_TEST_LOG"
if [ "${1:-}" = msiexec ] && [ "${GALE_WINE_TEST_INSTALL_FAIL:-0}" = 1 ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$FAKE_BIN/wine" "$FAKE_BIN/wineboot" "$FAKE_BIN/winepath"

PREFIX="$TMP_ROOT/Application Support/GaleWine"
MSI="$TMP_ROOT/Gale 1.16.1.msi"
LOG="$TMP_ROOT/wine.log"
GALE_EXE="$PREFIX/drive_c/Program Files/Gale/gale.exe"
touch "$MSI"
mkdir -p "$(dirname -- "$GALE_EXE")"
touch "$GALE_EXE"

run_gale() {
  env \
    GALE_WINE_OS=Darwin \
    GALE_WINE_ARCH=arm64 \
    GALE_WINE_ROSETTA_CHECK=true \
    GALE_WINE_BIN="$FAKE_BIN/wine" \
    GALE_WINE_PREFIX="$PREFIX" \
    GALE_WINE_MSI="$MSI" \
    GALE_WINE_VERSION="${GALE_TEST_VERSION:-1.16.1}" \
    GALE_WINE_TEST_LOG="$LOG" \
    "$LAUNCHER"
}

: >"$LOG"
assert_status 0 run_gale
assert_log_count 1 "wineboot -u"
assert_log_count 1 "wine msiexec /i"
assert_log_count 1 "wine $GALE_EXE"
assert_file_equals "1.16.1" "$PREFIX/.gale-wrapper-version"

assert_status 0 run_gale
assert_log_count 1 "wine msiexec /i"
assert_log_count 2 "wine $GALE_EXE"

GALE_TEST_VERSION=1.16.2
export GALE_TEST_VERSION
assert_status 0 run_gale
assert_log_count 2 "wine msiexec /i"
assert_file_equals "1.16.2" "$PREFIX/.gale-wrapper-version"

GALE_TEST_VERSION=1.16.3
GALE_WINE_TEST_INSTALL_FAIL=1
export GALE_TEST_VERSION GALE_WINE_TEST_INSTALL_FAIL
assert_status 70 run_gale
assert_stderr_contains "MSI installation failed"
assert_file_equals "1.16.2" "$PREFIX/.gale-wrapper-version"
unset GALE_WINE_TEST_INSTALL_FAIL
