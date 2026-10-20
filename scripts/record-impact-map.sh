#!/usr/bin/env bash
#
# Record test/impact-map.json: which app files each UI test executes.
#
# One xcodebuild test-without-building run per test with coverage on, then
# xccov parses each bundle. This is a one-time generator (~30–40 min for the
# current 80 tests); run it on a quiet machine, not on every change.
#
#   scripts/record-impact-map.sh ["iPhone 18 Pro"] [output-path]
#
# The output keeps every file under DSH-Mizar/Views/. Changes under App/ and
# Design/ stay on the full suite by rule in test/test-routing.json, so mapping
# them would only add noise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIMULATOR="${1:-iPhone 18 Pro}"
OUT="${2:-test/impact-map.json}"
WORK="$ROOT/.devcache/impact"
DERIVED="$ROOT/.devcache/DerivedData"
mkdir -p "$WORK/logs"
# Keep runs.tsv: a resumed run continues where the last one stopped. Only the
# coverage stderr log is per-run.
rm -f "$WORK/coverage.err"

MOCK_PIDS=()
cleanup() {
  local pid
  for pid in "${MOCK_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

ensure_mock() {
  local port="$1" attempt
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    return
  fi
  ( cd "$ROOT" && exec node scripts/mock-host.mjs "$port" ) >"$WORK/mock-$port.log" 2>&1 &
  MOCK_PIDS+=("$!")
  for attempt in {1..60}; do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return
    fi
    sleep 0.2
  done
  echo "record-impact-map: mock host on $port did not start" >&2
  exit 1
}

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

ensure_mock 19395
ensure_mock 19396

python3 scripts/impact-map.py --repo-root "$ROOT" list-tests > "$WORK/tests.txt"
total="$(wc -l < "$WORK/tests.txt" | tr -d ' ')"
echo "record-impact-map: $total tests, simulator=$SIMULATOR"

# Coverage has to be enabled on the test action: a build-for-testing pass with
# the flag writes the instrumentation, but test-without-building then records
# only the test bundle's own coverage. `xcodebuild test` costs ~5 s of
# incremental build check per test and records the app's coverage too.
xcb build-for-testing -enableCodeCoverage YES > "$WORK/build.log" 2>&1 || {
  echo "record-impact-map: build-for-testing failed" >&2
  tail -5 "$WORK/build.log" >&2
  exit 1
}

# Resume: a run that was interrupted keeps the tests it already recorded.
if [ -s "$WORK/runs.tsv" ]; then
  cut -f1 "$WORK/runs.tsv" > "$WORK/done.txt"
else
  : > "$WORK/done.txt"
fi
echo "record-impact-map: resuming, $(wc -l < "$WORK/done.txt" | tr -d ' ') already recorded"

started=$(date +%s)
index=0
launch_failures=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if grep -qxF "$id" "$WORK/done.txt"; then
    continue
  fi
  index=$((index + 1))
  slug="${id//\//_}"
  bundle="$WORK/$slug.xcresult"
  log="$WORK/logs/$slug.log"
  rm -rf "$bundle"
  status=PASS
  attempt=0
  files=""
  while :; do
    attempt=$((attempt + 1))
    rm -rf "$bundle"
    if xcb test \
          -collect-test-diagnostics never \
          -only-testing:"DSH-MizarUITests/$id" \
          -enableCodeCoverage YES \
          -resultBundlePath "$bundle" >"$log" 2>&1; then
      status=PASS
    else
      status=FAIL
    fi
    # A wedged simulator fails every launch in the same way; grinding through
    # the remaining tests would record a map with no coverage at all.
    if grep -qE "Failed to install or launch the test runner|failed preflight checks|hung before establishing connection" "$log" 2>/dev/null; then
      launch_failures=$((launch_failures + 1))
    else
      launch_failures=0
    fi
    if [ "$launch_failures" -ge 3 ]; then
      echo "record-impact-map: the test runner cannot launch on $SIMULATOR (3 consecutive); reboot the simulator and rerun" >&2
      exit 2
    fi
    files="$(python3 scripts/impact-map.py --repo-root "$ROOT" files "$bundle" 2>>"$WORK/coverage.err" | tr '\n' ' ' || true)"
    files="${files% }"
    if [ "$status" = "PASS" ] && [ -n "$files" ]; then
      break
    fi
    # The screenshot tour is gated by MIZAR_SHOTS, so a green skip with no
    # coverage is expected for it and only for it.
    if [ "$status" = "PASS" ] && [ -z "$files" ] && [ "${id#ScreenshotTour/}" != "$id" ]; then
      status=SKIP
      break
    fi
    if [ "$attempt" -gt "${MIZAR_IMPACT_RETRIES:-1}" ]; then
      if [ "$status" = "PASS" ]; then
        status=NOCOVERAGE
      fi
      break
    fi
    echo "impact: retrying $id after $status (attempt $attempt)"
  done
  rm -rf "$bundle"
  printf '%s\t%s\t%s\n' "$id" "$status" "$files" >> "$WORK/runs.tsv"
  wall=$(( $(date +%s) - started ))
  printf 'impact: [%d/%d] %-58s %s files=%-2s +%ss\n' \
    "$index" "$total" "$id" "$status" "$(printf '%s' "$files" | wc -w | tr -d ' ')" "$wall"
done < "$WORK/tests.txt"

python3 scripts/impact-map.py --repo-root "$ROOT" merge "$WORK/runs.tsv" --out "$OUT"
echo "record-impact-map: wrote $OUT"
