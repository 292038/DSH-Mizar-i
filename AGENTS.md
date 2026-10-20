# DSH-Mizar iOS — notes for coding agents

Read the project's `README.md` §四 for the plain commands. This file only lists
rules that keep the test loop cheap and safe.

## Test loop

```sh
scripts/test-select.sh              # default: diff vs origin/main + worktree, run only what it can prove is affected
scripts/test-select.sh --dry-run    # print the selection plan and the reasons, run nothing
scripts/test-select.sh --full       # ignore selection: unit suite + whole UI suite
scripts/test-select.sh --files a,b  # selection hook for a synthetic diff (verification)
```

- The MizarKit unit suite always runs whole (`scripts/swift.sh test`, host,
  ~6s). Do not try to select inside it.
- The UI suite is 80 XCTest methods / 9 classes and takes 20–25 minutes whole.
  It is only narrowed when `test/impact-map.json` (generated from a real full
  run) or an explicit route in `test/test-routing.json` names the tests that
  reach the changed file.
- Anything that is not provably local to one screen falls back to the whole
  suite ("fallback:" lines in the output). Do not silence that.
- The selected subset exports `MIZAR_TEST_MODE=replay` (phase 2: recorded LLM
  responses). Never make tests hit a live model.
- If the model picks a subset by hand, it must still list the tests it did not
  run in the reply. Never imply a subset was a full run.

## Forced-full triggers (already enforced by test-select.sh)

Changes under: the Xcode project/schemes/test plans, `MizarKit/Sources`,
`MizarKit/Package.swift`, `protocol/`, `scripts/`, `test/`, `package.json`,
`DSH-Mizar/App/`, `DSH-Mizar/Design/`, localization/asset/plist/entitlement/
storekit resources, the Live Activity target, or any unknown file. Also when the
UI test count no longer matches `expectedUiTests` in `test/test-routing.json`
(new or removed tests) or the impact map mentions tests that no longer exist.

## Adding coverage for a new screen

1. Add/extend a UI test class (`DSH-MizarUITests/…`), run the full suite once.
2. Regenerate `test/impact-map.json` with `scripts/record-impact-map.sh`
   (per-test coverage; one-time, ~30–40 min).
3. Bump `expectedUiTests` in `test/test-routing.json` if tests were added.
4. Re-run `scripts/test-select.sh --dry-run --files <changed path>` and check
   that the class shows up under "mapped:".

Until a file is in the impact map, changing it means a full run — that is the
zero-miss default, not a bug.

## Rollback

Phase commits are single-purpose commits on `main`; revert with
`git revert <sha>` (no data migration, no project-file edits).
