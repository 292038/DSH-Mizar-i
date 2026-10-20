#!/usr/bin/env bash
#
# Run the tests that a diff can affect.
#
#   scripts/test-select.sh                 # diff against origin/main + working tree
#   scripts/test-select.sh --base HEAD~2   # diff against an explicit revision
#   scripts/test-select.sh --dry-run       # print the plan, run nothing
#   scripts/test-select.sh --full          # ignore selection, run everything
#   scripts/test-select.sh --files a.swift,b.swift   # verification hook
#   scripts/test-select.sh --live                    # live layer (real host; not the default)
#
# The unit suite (MizarKit on the host, seconds) always runs whole: selecting
# inside it costs more in risk than the run costs in time. Only the UI suite is
# selectable, and only when test/impact-map.json or test-routing.json can prove
# which tests reach the changed files. Everything else falls back to the full
# UI suite: a missed test is worse than a slow run.
#
# The selected subset runs with MIZAR_TEST_MODE=replay exported, so phase 2's
# recorded-LLM replay is the default and no live model call is made.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIMULATOR="iPhone 18 Pro"
BASE="${MIZAR_TEST_BASE:-}"
FILES=""
FULL=0
DRY_RUN=0
KEEP_GOING=0
LIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --files) FILES="$2"; shift 2 ;;
    --simulator) SIMULATOR="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --live) LIVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep-going) KEEP_GOING=1; shift ;;
    --help|-h) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-select: unknown argument: $1" >&2; exit 2 ;;
  esac
done

timestamp() { date +%s; }
elapsed() { echo $(( $(timestamp) - $1 )); }

mkdir -p .devcache/test-select

# --- the diff ---------------------------------------------------------------

if [ -n "$FILES" ]; then
  changed="$(printf '%s' "$FILES" | tr ',' '\n' | sed '/^$/d')"
  base_label="--files"
else
  if [ -z "$BASE" ]; then
    if git rev-parse --verify --quiet origin/main >/dev/null; then
      if [ "$(git rev-parse HEAD 2>/dev/null)" = "$(git rev-parse origin/main 2>/dev/null)" ] \
         && [ -z "$(git status --porcelain)" ]; then
        BASE="HEAD"
      else
        BASE="origin/main"
      fi
    else
      BASE="HEAD"
    fi
  fi
  if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "test-select: base revision '$BASE' does not exist; running the full suite" >&2
    BASE=""
  fi
  if [ -n "$BASE" ] && [ "$BASE" != "HEAD" ]; then
    changed="$( { git diff --name-only "$BASE"...HEAD 2>/dev/null || git diff --name-only "$BASE" 2>/dev/null || true; } )"
  else
    changed=""
  fi
  changed="$changed
$(git diff --name-only HEAD 2>/dev/null || true)
$(git ls-files --others --exclude-standard 2>/dev/null || true)"
  changed="$(printf '%s\n' "$changed" | sed '/^$/d' | sort -u)"
  base_label="${BASE:-none}+worktree"
fi

# --- the plan ---------------------------------------------------------------

if ! plan="$(printf '%s\n' "$changed" | python3 scripts/test-selection.py \
      --repo-root "$ROOT" --config test/test-routing.json --json 2>.devcache/test-select/selection.err)"; then
  echo "test-select: cannot build a selection plan; falling back to the full suite" >&2
  sed -n '1,5p' .devcache/test-select/selection.err >&2 || true
  plan='{"mode":"full","reasons":["selection failed"],"notes":[],"changed":[],"ignored":[],"ui":{"tests":[],"classes":[],"selected":0,"full":0,"skippedClasses":{}},"unit":{"mode":"full","tests":null},"warnings":[]}'
fi

if [ "$FULL" = "1" ]; then
  plan="$(printf '%s' "$plan" | jq '.mode = "full" | .reasons = ["--full requested"]')"
fi

mode="$(printf '%s' "$plan" | jq -r '.mode')"
ui_full="$(printf '%s' "$plan" | jq -r '.ui.full')"
ui_selected="$(printf '%s' "$plan" | jq -r '.ui.selected')"
classes="$(printf '%s' "$plan" | jq -r '.ui.classes | join(", ")')"
skipped="$(printf '%s' "$plan" | jq -r '.ui.skippedClasses | to_entries | map("\(.key) (\(.value))") | join(", ")')"

echo "select: mode=$mode  changed=$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')  base=$base_label  full-ui=$ui_full"
printf '%s' "$plan" | jq -r '.reasons[] | "  fallback: " + .'
printf '%s' "$plan" | jq -r '.notes[] | "  mapped:   " + .'
echo "  unit: whole suite (by design); $( [ "$mode" = "none" ] && echo "ui: none" || echo "ui: $ui_selected/$ui_full tests in [${classes:-none}]" )"
echo "  layer: $( [ "$LIVE" = "1" ] && echo "live (real network, explicit)" || echo "replay (default; live tests skip)" )"
if [ "$mode" != "full" ] && [ -n "$skipped" ]; then
  echo "  not run:  $skipped"
fi

if [ "$DRY_RUN" = "1" ]; then
  exit 0
fi

# --- the runs ---------------------------------------------------------------

start=$(timestamp)
# The layer is exported before the unit suite too: the live layer's unit tests
# read MIZAR_TEST_MODE the same way the UI tests do.
layer="replay"
if [ "$LIVE" = "1" ]; then layer="live"; fi
export MIZAR_TEST_MODE="$layer"
export TEST_RUNNER_MIZAR_TEST_MODE="$layer"
unit_wall=""; unit_total=""; unit_verdict="SKIPPED"
ui_wall=""; ui_total=""; ui_passed=""; ui_failed=""; ui_skipped=""; ui_verdict="SKIPPED"
unit_log=.devcache/test-select/unit.log
ui_log=.devcache/test-select/ui.log
rb=.devcache/test-select/result.xcresult
rm -rf "$rb"

run_unit() {
  local begin result
  begin=$(timestamp)
  if bash scripts/swift.sh test >"$unit_log" 2>&1; then result=0; else result=1; fi
  unit_wall="$(elapsed "$begin")"
  unit_total="$(grep -oE 'Test run with [0-9]+ tests' "$unit_log" | tail -1 | grep -oE '[0-9]+' || true)"
  if [ "$result" = "0" ] && grep -qE 'Test run with .* passed after' "$unit_log"; then
    unit_verdict="PASS"
  elif [ "$result" = "0" ] && [ -n "$unit_total" ]; then
    unit_verdict="PASS"
  else
    unit_verdict="FAIL"
    grep -E '✘|failed after|error:' "$unit_log" | head -5 || true
  fi
}

if [ "$mode" != "none" ]; then
  run_unit
fi

ui_begin=$(timestamp)
if [ "$unit_verdict" = "FAIL" ] && [ "$KEEP_GOING" != "1" ]; then
  echo "  ui: not run (unit suite failed; use --keep-going to run anyway)"
  ui_verdict="NOT RUN"
elif [ "$mode" = "full" ] || [ "$mode" = "selected" ]; then
  args=(-resultBundlePath "$rb")
  if [ "$mode" = "selected" ]; then
    while IFS= read -r test_id; do
      [ -n "$test_id" ] || continue
      args+=("-only-testing:DSH-MizarUITests/$test_id")
    done < <(printf '%s' "$plan" | jq -r '.ui.tests[]')
    bash scripts/ios.sh test-fast "$SIMULATOR" "${args[@]}" >"$ui_log" 2>&1 || true
  else
    bash scripts/ios.sh test "$SIMULATOR" "${args[@]}" >"$ui_log" 2>&1 || true
  fi
  ui_wall="$(elapsed "$ui_begin")"
  # Xcode 27 writes result bundles without the database.sqlite3 the old
  # xcresulttool could read, so ask the supported CLI for the counts.
  if [ -d "$rb" ]; then
    summary="$(xcrun xcresulttool get test-results summary --path "$rb" --compact 2>/dev/null || true)"
    ui_total="$(printf '%s' "$summary" | jq -r '.totalTestCount // 0' 2>/dev/null || echo 0)"
    ui_passed="$(printf '%s' "$summary" | jq -r '.passedTests // 0' 2>/dev/null || echo 0)"
    ui_failed="$(printf '%s' "$summary" | jq -r '.failedTests // 0' 2>/dev/null || echo 0)"
    ui_skipped="$(printf '%s' "$summary" | jq -r '.skippedTests // 0' 2>/dev/null || echo 0)"
    if [ "${ui_failed:-1}" = "0" ] && [ "${ui_total:-0}" -gt 0 ]; then
      ui_verdict="PASS"
    else
      ui_verdict="FAIL"
      xcrun xcresulttool get test-results tests --path "$rb" --compact 2>/dev/null \
        | jq -r '.. | objects | select(.result? == "Failed") | "  failed: " + .nodeIdentifier' 2>/dev/null | head -10 || true
    fi
  else
    ui_verdict="FAIL"
    tail -4 "$ui_log" 2>/dev/null || true
  fi
elif [ "$mode" = "unit-only" ]; then
  echo "  ui: not run (only unit-test sources changed)"
else
  echo "  ui: not run (no source change)"
fi

total_wall="$(elapsed "$start")"
echo "  unit:  ${unit_total:-?} tests  ${unit_verdict}  ${unit_wall}s"
echo "  ui:    ${ui_total:-0} tests (${ui_passed:-0} passed, ${ui_failed:-0} failed, ${ui_skipped:-0} skipped)  ${ui_verdict}  ${ui_wall}s"
echo "  wall:  ${total_wall}s"
echo "  layer: ${layer:-none} (MIZAR_TEST_MODE)"

if [ "$unit_verdict" = "FAIL" ] || [ "$ui_verdict" = "FAIL" ]; then
  echo "  logs: $unit_log $ui_log"
  exit 1
fi
exit 0
