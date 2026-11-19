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
compares the five types' counts.

Frozen bar (set before the first run on the fix):
- valid only with at least MIN_LOADS loads between the snapshots and both
  snapshots read;
- passes when every type grows by at most PER_LOAD per load plus
  SCENE_ALLOWANCE.
The allowance covers one scene's rows. A snapshot can land while the scene
is shown, with its rows built, or in the New Scene gap, with none, so even a
fix that frees everything reads up to about +-44 between two snapshots. At
40 loads the bar is 104, so a residual leak of 3 per load (120) fails.

Usage (every app launch goes through the machine's app lock with --wrap):
  workspace_growth_check.py --app <.../Ikkoku.app/Contents/MacOS/Ikkoku>
      --environment <environment.json> --out <dir> [--wrap <lock script>]
      [--seconds 65] [--early 8] [--late 56]
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

# heap -s class names. The SwiftUI box's mangled context differs by build.
TYPES = (
    ("NSKeyValueDependency", re.compile(r"NSKeyValueDependency")),
    ("NSKeyValueDependencyContext", re.compile(r"NSKeyValueDependencyContext")),
    ("__NSMallocBlock__", re.compile(r"__NSMallocBlock__")),
    ("__NSExactBlockVariable__", re.compile(r"__NSExactBlockVariable__")),
    ("AnyHashableBox<UUID>", re.compile(r"SwiftUI\.\(_AnyHashableBox in [^)]*\)<Foundation\.UUID>")),
)
ROW = re.compile(r"^\s*(\d+)\s+(\d+)\s+[\d.]+\s+(.+?)\s+(ObjC|Swift|C\+\+|CFType|C)\s+\S.*$")


def parse_heap(text):
    """The five types' counts from `heap -s` output, or None when the output
    has no class table (heap failed)."""
    if not re.search(r"^\s*COUNT\s+BYTES\s+AVG\s+CLASS_NAME", text, re.M):
        return None
    counts = {name: 0 for name, _ in TYPES}
    for line in text.splitlines():
        match = ROW.match(line)
        if not match:
            continue
        class_name = match.group(3).strip()
        for name, pattern in TYPES:
            if pattern.fullmatch(class_name):
                counts[name] += int(match.group(1))
    return counts


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
    rows = []
    for name, _ in TYPES:
        growth = late_counts[name] - early_counts[name]
        rows.append({"type": name, "early": early_counts[name], "late": late_counts[name], "growth": growth,
                     "perLoad": round(growth / loads, 2), "bar": bar, "ok": growth <= bar})
    return ("pass" if all(row["ok"] for row in rows) else "fail"), rows


def app_pid(app):
    result = subprocess.run(["pgrep", "-f", "-x", app], capture_output=True, text=True)
    pids = [int(p) for p in result.stdout.split()]
    return pids[0] if len(pids) == 1 else None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--wrap")
    parser.add_argument("--seconds", type=int, default=65)
    parser.add_argument("--early", type=float, default=8)
    parser.add_argument("--late", type=float, default=56)
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
        snaps = {}
        for name, at in (("early", args.early), ("late", args.late)):
            while pid and run.poll() is None and time.monotonic() - launched < at:
                time.sleep(0.05)
            if not pid or run.poll() is not None:
                break
            start = time.monotonic() - launched
            heap = subprocess.run(["heap", "--forkCorpse", "-s", "-q", str(pid)], capture_output=True, text=True)
            with open(os.path.join(args.out, "heap-%s.txt" % name), "w") as handle:
                handle.write(heap.stdout + heap.stderr)
            snaps[name] = {"seconds": round(start, 3), "exit": heap.returncode,
                           "counts": parse_heap(heap.stdout) if heap.returncode == 0 else None}
        code = run.wait()
    loads = 0
    report_path = os.path.join(args.out, "studio-load.json")
    if "early" in snaps and "late" in snaps and os.path.exists(report_path):
        with open(report_path) as handle:
            loads = count_loads(json.load(handle), snaps["early"]["seconds"], snaps["late"]["seconds"])
    verdict, rows = judge(snaps.get("early", {}).get("counts"), snaps.get("late", {}).get("counts"), loads)
    result = {"verdict": verdict, "loads": loads, "minLoads": MIN_LOADS, "perLoad": PER_LOAD,
              "sceneAllowance": SCENE_ALLOWANCE, "snapshots": snaps, "rows": rows, "perfTraceExit": code}
    with open(os.path.join(args.out, "workspace-growth.json"), "w") as handle:
        json.dump(result, handle, indent=1)
        handle.write("\n")
    print("workspace growth: %s (%d loads between snapshots at %s s and %s s)" % (
        verdict, loads, snaps.get("early", {}).get("seconds"), snaps.get("late", {}).get("seconds")))
    for row in rows:
        print("  %-28s %6d -> %6d  growth %5d (%.2f/load), bar %d" % (
            row["type"], row["early"], row["late"], row["growth"], row["perLoad"], row["bar"]))
    return {"pass": 0, "fail": 1}.get(verdict, 2)


if __name__ == "__main__":
    sys.exit(main())
