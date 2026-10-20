#!/usr/bin/env bash
#
# Build and run the iOS app.
#
# Usage: scripts/ios.sh build|run|test|test-fast|screenshot [simulator name] [extra args]
#
# Each UI test class runs against its own mock-host pair (fixture machine on
# its primary port, second machine on +1). prepare_ui_tests starts every pair
# from the port table in DSH-MizarUITests/MockPorts.swift. To drive one pair
# manually, e.g. AccountUITests would be:
#   node scripts/mock-host.mjs 19416 &
#   MOCK_SECONDARY_PORT=19417 node scripts/mock-host.mjs 19417 &
#
# Interim: mock-host.mjs still hard-codes its second-machine identity to port
# 19396 (that edit is write-guard-blocked), so the AppFlow second machine
# stays on 19396 and prepare_ui_tests also starts the legacy 19395/19396 pair.
#
# The project compiles MizarKit as an in-project framework target rather than as
# a Swift package reference. That is not a style choice: Xcode resolves a package
# by loading its manifest through swift-plugin-server, which writes a
# diagnostics file under ~/Library/Caches/org.swift.swiftpm. There is no build
# setting or environment variable that relocates it, so a package reference
# cannot resolve under a restricted file policy. The framework target compiles
# the same sources with no resolution step, and `swift test` still exercises the
# package for the test suite.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR="${2:-iPhone 18 Pro}"
BUNDLE_ID="me.shirazu.dshmizar"
DERIVED="$ROOT/.devcache/DerivedData"
# `never` keeps a failed local test from spending ten minutes in simctl
# diagnostics. Set MIZAR_TEST_DIAGNOSTICS=on-failure (or always) in CI.
TEST_DIAGNOSTICS="${MIZAR_TEST_DIAGNOSTICS:-never}"

# Simulator builds are signed ad-hoc. That is not cosmetic: an unsigned app has
# no keychain entitlement, and the app stores its device token in the keychain,
# so it would launch and then fail to read its own credential (errSecMissingEntitlement,
# -34018). Ad-hoc signing costs nothing and needs no developer account.
xcb() {
  xcodebuild -project "$ROOT/DSH-Mizar.xcodeproj" \
    -scheme DSH-Mizar \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    "$@"
}

# Mock hosts started by this script, so they can be stopped when it exits.
# Hosts that were already running are left alone.
MOCK_PIDS=()

cleanup_mocks() {
  local pid
  if [ "${#MOCK_PIDS[@]}" -gt 0 ]; then
    for pid in "${MOCK_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
}

trap cleanup_mocks EXIT INT TERM

# Start one mock host if the port is not already serving.
#
# Starting them here is what makes `test` and `test-fast` one command. The
# mock is a Node process (it needs `ws`); if it cannot start, fail with the
# log and the install hint instead of letting every test time out.
ensure_mock_host() {
  local port="$1"
  local log="/tmp/dsh-mizar-mock-${port}.log"
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    return
  fi
  ( cd "$ROOT" && exec node scripts/mock-host.mjs "$port" ) >"$log" 2>&1 &
  MOCK_PIDS+=("$!")
  for _ in {1..50}; do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return
    fi
    sleep 0.2
  done
  echo "ios.sh: mock host on $port did not start; last log lines:" >&2
  tail -5 "$log" >&2 || true
  echo "ios.sh: run 'cd $ROOT && npm install' once, then retry." >&2
  exit 1
}

prepare_ui_tests() {
  if [ "${MIZAR_NO_MOCK:-0}" = "1" ]; then
    return
  fi
  # One mock-host pair per UI test class. The primaries come from the
  # `// mock-ports:` line in DSH-MizarUITests/MockPorts.swift, the single
  # source of truth shared with the Swift side. A secondary is meant to learn
  # it is the second machine through MOCK_SECONDARY_PORT (mock-host.mjs); the
  # relay stand-ins need no argument, they are always port + 2.
  local ports_file="$ROOT/DSH-MizarUITests/MockPorts.swift"
  local ports_line port
  ports_line="$(grep -m1 '// mock-ports:' "$ports_file" || true)"
  if [ -z "$ports_line" ]; then
    echo "ios.sh: no '// mock-ports:' line in DSH-MizarUITests/MockPorts.swift" >&2
    exit 1
  fi
  for port in ${ports_line#// mock-ports:}; do
    ensure_mock_host "$port"
    MOCK_SECONDARY_PORT=$((port + 1)) ensure_mock_host $((port + 1))
  done
  # Temporary compat while two edits are blocked by the workspace write guard:
  # AccountUITests still reads 19395, and the AppFlow second machine still
  # pairs on 19396 -- the one port where unchanged mock-host.mjs takes its
  # second-machine identity. Drop these once both edits land.
  ensure_mock_host 19395
  ensure_mock_host 19396
}

case "${1:-build}" in
  build)
    xcb build 2>&1 | grep -E "error:|warning:|BUILD" | sort -u || true
    xcb build >/dev/null 2>&1 || { echo "ios.sh: build failed"; exit 1; }
    echo "ios.sh: built"
    ;;
  run)
    xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
    xcrun simctl bootstatus "$SIMULATOR" -b >/dev/null 2>&1 || true
    xcb build >/dev/null 2>&1 || { echo "ios.sh: build failed"; exit 1; }
    APP="$DERIVED/Build/Products/Debug-iphonesimulator/DSH-Mizar.app"
    # Uninstall first. Installing over a running app silently kept the old
    # binary in place at least once while localisation was being added, which
    # cost three rounds of screenshots that showed the previous build's English
    # strings while the bundle on disk already had the new ones.
    xcrun simctl uninstall "$SIMULATOR" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$SIMULATOR" "$APP"
    xcrun simctl terminate "$SIMULATOR" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID"
    ;;
  test)
    prepare_ui_tests
    # "${@:3}", not "${@:2}": the second argument is the simulator and is already
    # spent on -destination, so passing it through as well handed xcodebuild
    # "iPhone 18 Pro" as a build action -- which it rejected, so a single test
    # could not be run by name.
    xcb test -collect-test-diagnostics "$TEST_DIAGNOSTICS" "${@:3}" 2>&1 | grep -E "Test Case .*(passed|failed)|Executed .* tests|error:|TEST (SUCCEEDED|FAILED)" || true
    ;;
  test-fast)
    prepare_ui_tests
    # Build once, then run without rebuilding the app or the test bundle. This is
    # the loop for a change you are about to iterate on; use `test` for the full
    # pre-release run. Extra arguments (for example -only-testing:...) are passed
    # to test-without-building only. With no filter it runs the account/settings
    # suite: a useful smoke test, not the twenty-minute full run.
    extra=("${@:3}")
    if [ "${#extra[@]}" -eq 0 ]; then
      extra=(-only-testing:DSH-MizarUITests/AccountUITests)
    fi
    xcb build-for-testing >/dev/null 2>&1 || { echo "ios.sh: build-for-testing failed"; exit 1; }
    xcb test-without-building -collect-test-diagnostics "$TEST_DIAGNOSTICS" "${extra[@]}" 2>&1 | grep -E "Test Case .*(passed|failed)|Executed .* tests|error:|TEST (SUCCEEDED|FAILED)" || true
    ;;
  screenshot)
    OUT="${3:-/tmp/dsh-mizar.png}"
    xcrun simctl io "$SIMULATOR" screenshot "$OUT"
    echo "ios.sh: $OUT"
    ;;
  *)
    echo "usage: scripts/ios.sh build|run|test|test-fast|screenshot [simulator] [xcodebuild args]" >&2
    exit 1
    ;;
esac
