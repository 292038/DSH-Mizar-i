#!/usr/bin/env python3
"""Build test/impact-map.json from per-test coverage bundles.

The map answers one question: for a given app source file, which UI tests
executed it? scripts/test-selection.py only narrows the UI suite to tests that
the map names; a file the map does not cover means a full run.

Subcommands:
  list-tests [--repo-root DIR]
      Print Class/testMethod for every test method in the UI test target.
  files BUNDLE [--repo-root DIR]
      Print the app source files covered by one .xcresult bundle, repo-relative.
      Only files under DSH-Mizar/Views/ are reported: everything else is held
      to the full suite by test-routing.json's forceFull rules.
  merge RUNS.tsv --out test/impact-map.json [--repo-root DIR] [--commit SHA]
      RUNS.tsv has one line per test:  test-id <TAB> status <TAB> space-separated files
"""

import argparse
import json
import os
import re
import subprocess
import sys

SELECTABLE_PREFIX = "DSH-Mizar/Views/"
APP_TARGET_PREFIX = "DSH-Mizar.app"


def ui_tests(root, ui_dir="DSH-MizarUITests"):
    directory = os.path.join(root, ui_dir)
    tests = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8", errors="replace") as handle:
            source = handle.read()
        code = "\n".join(line for line in source.splitlines()
                         if not line.lstrip().startswith("//"))
        for method in re.findall(r"\bfunc\s+(test[A-Za-z0-9_]+)\s*\(", code):
            tests.append("%s/%s" % (name[:-6], method))
    return tests


def bundle_files(root, bundle):
    """Covered repo-relative app files in one result bundle."""
    report = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", bundle],
        capture_output=True, text=True)
    if report.returncode != 0 or not report.stdout.strip():
        print("coverage: cannot read %s: %s" % (bundle, report.stderr.strip()[:200]),
              file=sys.stderr)
        return []
    try:
        data = json.loads(report.stdout)
    except ValueError:
        return []
    covered = set()
    for target in data.get("targets", []):
        if not str(target.get("name", "")).startswith(APP_TARGET_PREFIX):
            continue
        for item in target.get("files", []):
            if item.get("coveredLines", 0) <= 0:
                continue
            path = item.get("path", "")
            if path.startswith(root + os.sep):
                relative = path[len(root) + 1:]
            elif path.startswith("DSH-Mizar/"):
                relative = path
            else:
                continue
            if relative.startswith(SELECTABLE_PREFIX):
                covered.add(relative)
    return sorted(covered)


def do_list(args):
    for test in ui_tests(os.path.abspath(args.repo_root)):
        print(test)


def do_files(args):
    for path in bundle_files(os.path.abspath(args.repo_root), args.bundle):
        print(path)


def do_merge(args):
    root = os.path.abspath(args.repo_root)
    files = {}
    runs = {}
    with open(args.runs, encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            test_id = parts[0]
            runs[test_id] = parts[1]
            covered = parts[2].split() if len(parts) > 2 else []
            # Never attribute coverage from a non-passing run. An isolated
            # run can fail before the test reaches the views a full-suite
            # pass would cover; trusting that partial evidence under-maps
            # files and lets a regression slip past a narrowed run. The row
            # still counts toward uiTestCount, so the completeness check in
            # test-selection.py is unaffected.
            if parts[1] != "PASS":
                covered = []
            for path in covered:
                files.setdefault(path, []).append(test_id)
    commit = args.commit
    if commit is None:
        commit = subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"],
                                capture_output=True, text=True).stdout.strip()
    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True,
                           text=True).stdout.splitlines()
    payload = {
        "schema": 1,
        "generatedAt": subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
                                      capture_output=True, text=True).stdout.strip(),
        "commit": commit,
        "xcode": xcode[1].strip() if len(xcode) > 1 else xcode[0].strip() if xcode else "",
        "uiTestCount": len(runs),
        "source": "per-test coverage from one xcodebuild test-without-building per test",
        "files": {path: sorted(set(tests)) for path, tests in sorted(files.items())},
        "runs": dict(sorted(runs.items())),
    }
    out = args.out if os.path.isabs(args.out) else os.path.join(root, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=False)
        handle.write("\n")
    failures = [test for test, status in runs.items() if status != "PASS"]
    print("impact: %d tests, %d files, %d non-passing (%s)"
          % (len(runs), len(files), len(failures), ", ".join(failures[:5]) or "none"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list-tests")
    files_parser = sub.add_parser("files")
    files_parser.add_argument("bundle")
    merge_parser = sub.add_parser("merge")
    merge_parser.add_argument("runs")
    merge_parser.add_argument("--out", default="test/impact-map.json")
    merge_parser.add_argument("--commit", default=None)
    args = parser.parse_args()
    if args.command == "list-tests":
        do_list(args)
    elif args.command == "files":
        do_files(args)
    else:
        do_merge(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
