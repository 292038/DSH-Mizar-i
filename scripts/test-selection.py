#!/usr/bin/env python3
"""Turn a list of changed files into a test-selection plan.

Reads the changed paths on stdin (one per line), writes a JSON plan to
stdout. The plan names the unit suite (always the whole suite: it runs on the
host in seconds) and either the whole UI suite, a subset of UI tests, or no UI
tests at all, together with the reasons for that decision.

Selection is only allowed to shrink the UI suite when the changed file is
covered by test/impact-map.json (generated from a real full run, see
scripts/record-impact-map.sh) or by an explicit route in test-routing.json.
Anything the plan cannot classify means the whole suite: a missed test is
worse than a slow run.

Exit codes: 0 plan written, 2 configuration could not be read (the caller must
fall back to the full suite).
"""

import argparse
import json
import os
import re
import sys

MARKER = "test-selection"


def glob_to_regex(pattern):
    """Translate a small glob dialect to regex: ** crosses directories, * does not."""
    out = []
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "*":
            if pattern[i:i + 2] == "**":
                i += 2
                if i < len(pattern) and pattern[i] == "/":
                    i += 1
                    out.append("(?:.*/)?")
                else:
                    out.append(".*")
                continue
            out.append("[^/]*")
            i += 1
        elif ch == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(ch))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def matches_any(path, patterns):
    return find_matching(path, patterns) is not None


def find_matching(path, patterns):
    for pattern, regex in patterns:
        if regex.match(path):
            return pattern
    return None


def scan_ui_tests(root, ui_dir):
    """Map test class name -> list of test methods, from the UI test sources."""
    directory = os.path.join(root, ui_dir)
    classes = {}
    if not os.path.isdir(directory):
        return classes
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            source = handle.read()
        # Drop line comments so commented-out tests do not count.
        code = "\n".join(line for line in source.splitlines()
                         if not line.lstrip().startswith("//"))
        methods = re.findall(r"\bfunc\s+(test[A-Za-z0-9_]+)\s*\(", code)
        classes[name[:-6]] = methods
    return classes


def load_impact_map(root, relative):
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        return None, "impact map not present: %s" % relative
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        return None, "impact map unreadable (%s)" % error
    files = data.get("files")
    if not isinstance(files, dict):
        return None, "impact map has no files table"
    return files, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--config", default="test/test-routing.json")
    parser.add_argument("--changed", nargs="*", default=None,
                        help="changed paths (testing hook; default: read stdin)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    root = os.path.abspath(args.repo_root)
    config_path = args.config
    if not os.path.isabs(config_path):
        config_path = os.path.join(root, config_path)
    try:
        with open(config_path, encoding="utf-8") as handle:
            config = json.load(handle)
    except (OSError, ValueError) as error:
        print("%s: cannot read routing config: %s" % (MARKER, error), file=sys.stderr)
        return 2

    if args.changed is None:
        raw = sys.stdin.read()
    else:
        raw = "\n".join(args.changed)
    changed = []
    for line in raw.splitlines():
        path = line.strip()
        if path and path not in changed:
            changed.append(path)

    ui_dir = config.get("uiTestDir", "DSH-MizarUITests")
    ui_tests = scan_ui_tests(root, ui_dir)
    ui_test_count = sum(len(methods) for methods in ui_tests.values())

    force_full = [(item, glob_to_regex(item)) for item in config.get("forceFull", [])]
    unit_only = [(item, glob_to_regex(item)) for item in config.get("unitOnly", [])]
    no_tests = [(item, glob_to_regex(item)) for item in config.get("noTests", [])]
    routes = []
    for route in config.get("routes", []):
        regexes = [(item, glob_to_regex(item)) for item in route.get("paths", [])]
        routes.append((route.get("select", []), regexes, route.get("note", "")))

    expected = config.get("expectedUiTests")
    drift = expected is not None and ui_test_count != expected

    impact_files, impact_note = load_impact_map(root, config.get("impactMap", ""))
    if impact_files is not None and impact_files.get("__meta__"):
        pass  # reserved for future metadata

    reasons = []
    notes = []
    selected = set()
    ignored = []
    full = False

    if not changed:
        full = True
        reasons.append("no changed files: scope unknown, running the full suite")
    if drift:
        full = True
        reasons.append(
            "UI test count drifted (%d source tests, expected %s): update "
            "test/test-routing.json and regenerate the impact map"
            % (ui_test_count, expected))
    if impact_files is None:
        notes.append(impact_note)
    if config.get("impactMap") and impact_files is not None:
        map_tests = set()
        for methods in impact_files.values():
            if isinstance(methods, list):
                map_tests.update(methods)
        unknown = sorted(t for t in map_tests if t.split("/")[0] not in ui_tests)
        if unknown:
            full = True
            reasons.append("impact map references tests that no longer exist: %s"
                           % ", ".join(unknown[:5]))

    unit_only_hit = False
    for path in changed:
        if matches_any(path, no_tests):
            ignored.append(path)
            continue
        pattern = find_matching(path, force_full)
        if pattern is not None:
            full = True
            reasons.append("%s matches force-full pattern %s" % (path, pattern))
            continue
        if matches_any(path, unit_only):
            unit_only_hit = True
            continue
        if path.startswith(ui_dir + "/"):
            if path.endswith(".swift") and os.path.basename(path)[:-6] in ui_tests:
                selected.add(os.path.basename(path)[:-6])
                notes.append("%s: its own test class" % path)
            else:
                full = True
                reasons.append("%s: unknown or non-test file in the UI test target"
                               % path)
            continue
        if impact_files is not None and path in impact_files:
            entries = impact_files[path]
            if not entries:
                full = True
                reasons.append("%s is covered by no test in the impact map" % path)
            else:
                selected.update(entries)
                notes.append("%s: %d test(s) from the impact map" % (path, len(entries)))
            continue
        route_hit = False
        for selects, regexes, route_note in routes:
            if matches_any(path, regexes):
                route_hit = True
                selected.update(selects)
                notes.append("%s: route %s" % (path, route_note or "explicit"))
                break
        if route_hit:
            continue
        full = True
        reasons.append("%s: no impact data, cannot decide its blast radius" % path)

    # Expand class-level entries and drop anything that is not a real test.
    expanded = set()
    for entry in selected:
        if "/" in entry:
            cls, method = entry.split("/", 1)
            if cls in ui_tests and method in ui_tests[cls]:
                expanded.add(entry)
            else:
                full = True
                reasons.append("selection names an unknown test: %s" % entry)
        elif entry in ui_tests:
            for method in ui_tests[entry]:
                expanded.add("%s/%s" % (entry, method))
        else:
            full = True
            reasons.append("selection names an unknown class: %s" % entry)

    if full:
        mode = "full"
    elif ignored and not [p for p in changed if p not in ignored]:
        mode = "none"
    elif unit_only_hit and not [p for p in changed
                                if p not in ignored
                                and not matches_any(p, unit_only)]:
        mode = "unit-only"
    elif expanded:
        mode = "selected"
    else:
        mode = "full"
        reasons.append("nothing selected from %d changed file(s)" % len(changed))

    selected_tests = sorted(expanded)
    selected_classes = sorted({test.split("/")[0] for test in selected_tests})
    skipped_classes = {cls: len(methods) for cls, methods in ui_tests.items()
                       if cls not in selected_classes}
    plan = {
        "mode": mode,
        "reasons": reasons,
        "notes": notes,
        "changed": changed,
        "ignored": ignored,
        "ui": {
            "tests": selected_tests,
            "classes": selected_classes,
            "selected": len(selected_tests),
            "full": ui_test_count,
            "skippedClasses": skipped_classes,
            "expected": expected,
        },
        "unit": {"mode": "full", "tests": None},
        "warnings": [],
    }
    if drift:
        plan["warnings"].append("UI test count drift")
    if args.json:
        json.dump(plan, sys.stdout, indent=2)
    else:
        print(json.dumps(plan, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
