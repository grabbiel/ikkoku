#!/usr/bin/env python3
"""#410: checks that Studio scene loads do not grow the workspace list's
per-row objects.

Before the fix, the workspace panel kept one scroll view for the whole
session. Its rows are keyed by object id, and every Open or New Scene brings
new ids, so each load added an entry per row the lazy stack built to two
caches that are never pruned: SwiftUI's lazy-stack child cache (one
`AnyHashableBox<UUID>` per row id) and AppKit's KVO dependency set on the
scroll view's group container (one `NSKeyValueDependency`, its context, an
`__NSMallocBlock__` and an `__NSExactBlockVariable__` per row id). That was
about 44 of each per load in a 3,769-object scene.

The check runs `perf_trace.py run --workloads studio-load` (File > New Scene,
then File > Open of the source scene, repeated) and takes two
`heap --forkCorpse -s` snapshots of the app by pid: an early one and a late
one. It counts the loads between the two from the studio-load report, and
compares the rows' counts (v2.1, below).

Frozen bar (set before the first run on the fix):
- valid only with at least MIN_LOADS loads between the snapshots and both
  snapshots read;
- passes when every type grows by at most PER_LOAD per load plus
  SCENE_ALLOWANCE.
The allowance covers one scene's rows. A snapshot can land while the scene
is shown, with its rows built, or in the New Scene gap, with none, so even a
fix that frees everything reads up to about +-44 between two snapshots. At
40 loads the bar is 104, so a residual leak of 3 per load (120) fails.

Snapshots (v2, changed a priori after two runs whose 8 s snapshot failed,
before any run with this version): the early snapshot is taken at
EARLY_SECONDS (12 s) instead of 8 s, and a snapshot whose `heap` exits
non-zero is retried once, RETRY_AFTER seconds later. The loads are counted
between the snapshots that were read, so a retry only moves the window. The
bar is unchanged.

Rows (v2.1, stricter, set before any run with this version): a fix keyed
by position (#410 B) moved the child-cache growth from `AnyHashableBox<UUID>`
to `AnyHashableBox<Int>`, which v2 did not count. Every `_AnyHashableBox<T>`
instantiation in either snapshot is now a row of its own under the same bar
(the UUID and Int rows always print). Adding rows only makes the check
stricter. Every other `heap -s` class that grows by at least the bar is
listed as a FLAG for review. A flag does not change the verdict or the
exit code.

Usage (every app launch goes through the machine's app lock with --wrap):
  workspace_growth_check.py --app <.../Ikkoku.app/Contents/MacOS/Ikkoku>
      --environment <environment.json> --out <dir> [--wrap <lock script>]
      [--seconds 65] [--early 12] [--late 56]
Exit 0 pass, 1 fail, 2 invalid. Writes <out>/workspace-growth.json with the
raw counts. Self-tests: test_workspace_growth_check.py.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

PER_LOAD = 1
SCENE_ALLOWANCE = 64
MIN_LOADS = 40
EARLY_SECONDS = 12.0
LATE_SECONDS = 56.0
RETRY_AFTER = 2.0

# heap -s class names: AppKit's dependency set, one row each.
TYPES = (
    ("NSKeyValueDependency", re.compile(r"NSKeyValueDependency")),
    ("NSKeyValueDependencyContext", re.compile(r"NSKeyValueDependencyContext")),
    ("__NSMallocBlock__", re.compile(r"__NSMallocBlock__")),
    ("__NSExactBlockVariable__", re.compile(r"__NSExactBlockVariable__")),
)
# v2.1: every SwiftUI hashable box is a row of its own, named for its payload
# type. The box's mangled context differs by build.
BOX = re.compile(r"SwiftUI\.\(_AnyHashableBox in [^)]*\)<(.+)>")
ALWAYS_BOXES = ("AnyHashableBox<Foundation.UUID>", "AnyHashableBox<Swift.Int>")
ROW = re.compile(r"^\s*(\d+)\s+(\d+)\s+[\d.]+\s+(.+?)\s+(ObjC|Swift|C\+\+|CFType|C)\s+\S.*$")


def parse_classes(text):
    """Every class's count from `heap -s` output (a name listed for more than
    one binary is summed), or None when the output has no class table (heap
    failed)."""
    if not re.search(r"^\s*COUNT\s+BYTES\s+AVG\s+CLASS_NAME", text, re.M):
        return None
    classes = {}
    for line in text.splitlines():
        match = ROW.match(line)
        if match:
            name = match.group(3).strip()
            classes[name] = classes.get(name, 0) + int(match.group(1))
    return classes


def row_name(class_name):
    """The row a class counts in: a TYPES name, `AnyHashableBox<T>`, or None."""
    for name, pattern in TYPES:
        if pattern.fullmatch(class_name):
            return name
    box = BOX.fullmatch(class_name)
    return "AnyHashableBox<%s>" % box.group(1) if box else None


def parse_heap(text):
    """The rows' counts from `heap -s` output: the TYPES, the UUID and Int
    boxes (0 when absent) and every other box present, or None when heap
    failed."""
    classes = parse_classes(text)
    if classes is None:
        return None
    counts = {name: 0 for name, _ in TYPES}
    counts.update({name: 0 for name in ALWAYS_BOXES})
    for class_name, count in classes.items():
        name = row_name(class_name)
        if name:
            counts[name] = counts.get(name, 0) + count
    return counts


def flags(early_classes, late_classes, loads):
    """v2.1, for review only: every class that is not a row and grows by at
    least the bar between the snapshots, largest growth first."""
    if early_classes is None or late_classes is None or loads < MIN_LOADS:
        return []
    bar = PER_LOAD * loads + SCENE_ALLOWANCE
    out = []
    for name in set(early_classes) | set(late_classes):
        growth = late_classes.get(name, 0) - early_classes.get(name, 0)
        if row_name(name) is None and growth >= bar:
            out.append({"type": name, "early": early_classes.get(name, 0), "late": late_classes.get(name, 0),
                        "growth": growth, "perLoad": round(growth / loads, 2), "bar": bar})
    return sorted(out, key=lambda row: (-row["growth"], row["type"]))


def count_loads(report, early, late):
    """Loads that started between the two snapshots. `early` and `late` are
    seconds after launch; an action's start is `recordingBegin` (seconds
    after launch) plus its `startSeconds` (seconds after recording began)."""
    begin = report["startupSeconds"]["recordingBegin"]
    return sum(1 for action in report["details"]["actions"]
               if action["name"] == "load" and early <= begin + action["startSeconds"] < late)


def judge(early_counts, late_counts, loads):
    """(verdict, rows): verdict is "pass", "fail" or "invalid"."""
    if early_counts is None or late_counts is None or loads < MIN_LOADS:
        return "invalid", []
    bar = PER_LOAD * loads + SCENE_ALLOWANCE
    boxes = sorted((set(early_counts) | set(late_counts)) - {name for name, _ in TYPES})
    rows = []
    for name in [name for name, _ in TYPES] + boxes:
        early, late = early_counts.get(name, 0), late_counts.get(name, 0)
        growth = late - early
        rows.append({"type": name, "early": early, "late": late, "growth": growth,
                     "perLoad": round(growth / loads, 2), "bar": bar, "ok": growth <= bar})
    return ("pass" if all(row["ok"] for row in rows) else "fail"), rows


def snapshot(pid, clock, run_heap, wait, retry_after=RETRY_AFTER):
    """Takes one `heap -s` snapshot, retried once `retry_after` seconds after a
    non-zero exit. Returns (attempts, text): attempts lists each try's start
    (clock()) and exit; text is the output of the last try."""
    attempts = []
    for attempt in range(2):
        if attempt:
            wait(retry_after)
        start = clock()
        code, text = run_heap(pid)
        attempts.append({"seconds": round(start, 3), "exit": code})
        if code == 0:
            break
    return attempts, text


def app_pid(app):
    result = subprocess.run(["pgrep", "-f", "-x", app], capture_output=True, text=True)
    pids = [int(p) for p in result.stdout.split()]
    return pids[0] if len(pids) == 1 else None


def run_heap(pid):
    heap = subprocess.run(["heap", "--forkCorpse", "-s", "-q", str(pid)], capture_output=True, text=True)
    return heap.returncode, heap.stdout + (heap.stderr if heap.returncode else "")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--wrap")
    parser.add_argument("--seconds", type=int, default=65)
    parser.add_argument("--early", type=float, default=EARLY_SECONDS)
    parser.add_argument("--late", type=float, default=LATE_SECONDS)
    args = parser.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    perf = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf_trace.py")
    cmd = [sys.executable, "-I", perf, "run", "--app", args.app, "--environment", args.environment, "--out", args.out,
           "--workloads", "studio-load", "--seconds", str(args.seconds), "--retries", "0"]
    if args.wrap:
        cmd += ["--wrap", args.wrap]
    with open(os.path.join(args.out, "perf_trace.out"), "w") as log:
        run = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        pid = None
        while run.poll() is None and pid is None:
            pid = app_pid(args.app)
            if pid is None:
                time.sleep(0.1)
        launched = time.monotonic()
        snaps, classes = {}, {}
        for name, at in (("early", args.early), ("late", args.late)):
            while pid and run.poll() is None and time.monotonic() - launched < at:
                time.sleep(0.05)
            if not pid or run.poll() is not None:
                break
            attempts, text = snapshot(pid, lambda: time.monotonic() - launched, run_heap, time.sleep)
            with open(os.path.join(args.out, "heap-%s.txt" % name), "w") as handle:
                handle.write(text)
            last = attempts[-1]
            snaps[name] = {"seconds": last["seconds"], "exit": last["exit"], "attempts": attempts,
                           "counts": parse_heap(text) if last["exit"] == 0 else None}
            classes[name] = parse_classes(text) if last["exit"] == 0 else None
        code = run.wait()
    loads = 0
    report_path = os.path.join(args.out, "studio-load.json")
    if "early" in snaps and "late" in snaps and os.path.exists(report_path):
        with open(report_path) as handle:
            loads = count_loads(json.load(handle), snaps["early"]["seconds"], snaps["late"]["seconds"])
    verdict, rows = judge(snaps.get("early", {}).get("counts"), snaps.get("late", {}).get("counts"), loads)
    flagged = flags(classes.get("early"), classes.get("late"), loads) if verdict != "invalid" else []
    result = {"verdict": verdict, "loads": loads, "minLoads": MIN_LOADS, "perLoad": PER_LOAD,
              "sceneAllowance": SCENE_ALLOWANCE, "snapshots": snaps, "rows": rows, "flags": flagged,
              "perfTraceExit": code}
    with open(os.path.join(args.out, "workspace-growth.json"), "w") as handle:
        json.dump(result, handle, indent=1)
        handle.write("\n")
    print("workspace growth: %s (%d loads between snapshots at %s s and %s s)" % (
        verdict, loads, snaps.get("early", {}).get("seconds"), snaps.get("late", {}).get("seconds")))
    for row in rows:
        print("  %-36s %6d -> %6d  growth %5d (%.2f/load), bar %d%s" % (
            row["type"], row["early"], row["late"], row["growth"], row["perLoad"], row["bar"], "" if row["ok"] else "  FAIL"))
    if verdict != "invalid":
        print("  flags (other classes growing by >= the bar; reviewed, not judged): %s" % (len(flagged) or "none"))
    for row in flagged:
        print("  FLAG %-60s %6d -> %6d  growth %5d (%.2f/load)" % (
            row["type"][:60], row["early"], row["late"], row["growth"], row["perLoad"]))
    return {"pass": 0, "fail": 1}.get(verdict, 2)


if __name__ == "__main__":
    sys.exit(main())
