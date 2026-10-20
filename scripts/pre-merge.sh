#!/usr/bin/env bash
#
# Pre-merge gate: the local, CI-shaped minimum before a merge.
#
#   scripts/pre-merge.sh            # unit suite + snapshot suite + selection plan
#   scripts/pre-merge.sh --with-ui  # also actually run the selected UI subset
#
# Never runs the live layer; a default regression must not touch a real host.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SIMULATOR="Mizar Runs"
SNAP_DERIVED=".devcache/DerivedData-snap"

WITH_UI=0
[ "${1:-}" = "--with-ui" ] && WITH_UI=1

if pgrep -f "xcodebuild -project" >/dev/null 2>&1; then
  echo "pre-merge: another xcodebuild is running; wait for it (parallel runs wedge testmanagerd)" >&2
  exit 1
fi

t0=$(date +%s)

echo "== 1/3 unit suite (host, whole) =="
scripts/swift.sh test 2>&1 | tail -2
t1=$(date +%s)
echo "pre-merge: unit $((t1-t0))s"

echo "== 2/3 snapshot suite =="
xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR" -b >/dev/null 2>&1 || true
xcodebuild test \
  -project DSH-Mizar.xcodeproj \
  -scheme DSH-Mizar-Snapshots \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -derivedDataPath "$SNAP_DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -collect-test-diagnostics never 2>&1 | tail -3
t2=$(date +%s)
echo "pre-merge: snapshots $((t2-t1))s"

echo "== 3/3 test selection =="
if [ "$WITH_UI" = "1" ]; then
  scripts/test-select.sh
else
  scripts/test-select.sh --dry-run
fi
t3=$(date +%s)
echo "pre-merge: selection $((t3-t2))s"

echo "pre-merge: all gates finished in $((t3-t0))s"
