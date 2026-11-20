#!/usr/bin/env python3
"""#440: checks that a perf workload's repeated actions do not grow AppKit's
focus-ring state or SwiftUI's hashable boxes.

#410 found that a SwiftUI control with the system focus effect, shown again
inside a long-lived scroll view, leaves AppKit state behind on every show:
one `NSKeyValueDependency`, its context, an `__NSMallocBlock__` and an
`__NSExactBlockVariable__` in the scroll view's group container, never
pruned. `workspace_growth_check.py` (v2.2) measured that for Studio loads and
stays frozen as #410's record. This check (v3) runs any `perf_trace.py`
workload with the same two `heap --forkCorpse -s` snapshots by pid and
judges the growth per measured action.

Parked snapshots (the default): both snapshots see the same UI state. The
check passes `IKKOKU_PERF_PARK_FILE=<out>/park` to the app and writes
`park <n>` into that file. At the start of its next action cycle (step 0)
the workload stops, writes `<out>/park.parked` (`parked <n> <measured>
<index> <cycle>`: the measured actions finished so far, the next action's
index and the cycle's length) and waits until the park file reads
`resume <n>`. The check takes the snapshot, then writes `resume <n>`. No file
is deleted. The unit is the measured actions finished between the two parks,
read from the two `.parked` lines. Early park at EARLY_SECONDS, late at
LATE_SECONDS after launch.

Timed snapshots (`--timed`, for builds without parking): v2.2's schedule;
the unit is the measured actions that started between the snapshots that
were read, and the allowance is v2.2's.

Bar (frozen before the first run, #440 rules):
- valid only with both snapshots read, both parks at step 0 (parked mode),
  and at least MIN_ACTIONS measured actions between the snapshots;
- passes when every row grows by at most PER_ACTION per action plus the
  allowance: PARKED_ALLOWANCE (no phase term: both snapshots in one state;
  it covers incidental allocations) or TIMED_ALLOWANCE (v2.2's 64: a
  snapshot with or without one scene's rows).
Rows: the four AppKit types, `_FocusRingView` (the view the mechanism adds)
and every `_AnyHashableBox<T>` instantiation (the UUID and Int boxes always
print). Every other class that grows by at least the bar is a FLAG for
review; flags do not change the verdict.

Slopes (information only, not the verdict): each row's growth per action.
A pass with a slope of at least SLOPE_NOTE per action on one of the four
types or `_FocusRingView` prints as "pass, slope X": a section that leaks one
control per show (0.5 per action) passes the 1-per-action bar.

Usage (every app launch goes through the machine's app lock with --wrap):
  growth_check.py --app <.../Ikkoku.app/Contents/MacOS/Ikkoku>
      --environment <environment.json> --out <dir> --workload <name>
      [--wrap <lock script>] [--set IKKOKU_PERF_X=VALUE ...] [--timed]
      [--seconds 65] [--early 12] [--late 56]
Exit 0 pass, 1 fail, 2 invalid. Writes <out>/growth.json with the counts.
Self-tests: test_growth_check.py.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

CHECK_VERSION = "3"
PER_ACTION = 1
PARKED_ALLOWANCE = 32
TIMED_ALLOWANCE = 64
MIN_ACTIONS = 40
EARLY_SECONDS = 12.0
LATE_SECONDS = 56.0
RETRY_AFTER = 2.0
SNAPSHOT_ATTEMPTS = 4
PARK_TIMEOUT = 20.0
SLOPE_NOTE = 0.25

# heap -s class names: AppKit's dependency set and the focus ring view, one row each.
TYPES = (
    ("NSKeyValueDependency", re.compile(r"NSKeyValueDependency")),
    ("NSKeyValueDependencyContext", re.compile(r"NSKeyValueDependencyContext")),
    ("__NSMallocBlock__", re.compile(r"__NSMallocBlock__")),
    ("__NSExactBlockVariable__", re.compile(r"__NSExactBlockVariable__")),
    ("_FocusRingView", re.compile(r"_FocusRingView")),
)
SLOPE_ROWS = tuple(name for name, _ in TYPES)
# Every SwiftUI hashable box is a row of its own, named for its payload type.
# The box's mangled context differs by build.
BOX = re.compile(r"SwiftUI\.\(_AnyHashableBox in [^)]*\)<(.+)>")
ALWAYS_BOXES = ("AnyHashableBox<Foundation.UUID>", "AnyHashableBox<Swift.Int>")
ROW = re.compile(r"^\s*(\d+)\s+(\d+)\s+[\d.]+\s+(.+?)\s+(ObjC|Swift|C\+\+|CFType|C)\s+\S.*$")
PARKED = re.compile(r"^parked (\d+) (\d+) (\d+) (\d+)\s*$")


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


def bar_for(actions, allowance):
    return PER_ACTION * actions + allowance


def judge(early_counts, late_counts, actions, allowance):
    """(verdict, rows): verdict is "pass", "fail" or "invalid"."""
    if early_counts is None or late_counts is None or actions < MIN_ACTIONS:
        return "invalid", []
    bar = bar_for(actions, allowance)
    boxes = sorted((set(early_counts) | set(late_counts)) - {name for name, _ in TYPES})
    rows = []
    for name in [name for name, _ in TYPES] + boxes:
        early, late = early_counts.get(name, 0), late_counts.get(name, 0)
        growth = late - early
        rows.append({"type": name, "early": early, "late": late, "growth": growth,
                     "perAction": round(growth / actions, 3), "bar": bar, "ok": growth <= bar})
    return ("pass" if all(row["ok"] for row in rows) else "fail"), rows


def slope_note(verdict, rows):
    """The steepest of the four types and `_FocusRingView` when the verdict is
    a pass and that slope is at least SLOPE_NOTE per action, else None."""
    if verdict != "pass":
        return None
    steep = [row for row in rows if row["type"] in SLOPE_ROWS and row["perAction"] >= SLOPE_NOTE]
    if not steep:
        return None
    top = max(steep, key=lambda row: (row["perAction"], row["type"]))
    return {"type": top["type"], "perAction": top["perAction"],
            "rows": sorted(row["type"] for row in steep)}


def flags(early_classes, late_classes, actions, allowance):
    """For review only: every class that is not a row and grows by at least
    the bar between the snapshots, largest growth first."""
    if early_classes is None or late_classes is None or actions < MIN_ACTIONS:
        return []
    bar = bar_for(actions, allowance)
    out = []
    for name in set(early_classes) | set(late_classes):
        growth = late_classes.get(name, 0) - early_classes.get(name, 0)
        if row_name(name) is None and growth >= bar:
            out.append({"type": name, "early": early_classes.get(name, 0), "late": late_classes.get(name, 0),
                        "growth": growth, "perAction": round(growth / actions, 3), "bar": bar})
    return sorted(out, key=lambda row: (-row["growth"], row["type"]))


def count_actions(report, early, late):
    """Timed mode: measured actions that started between the two snapshots.
    `early` and `late` are seconds after launch; an action's start is
    `recordingBegin` (seconds after launch) plus its `startSeconds` (seconds
    after recording began)."""
    begin = report["startupSeconds"]["recordingBegin"]
    return sum(1 for action in report["details"]["actions"]
               if action.get("measured") and early <= begin + action["startSeconds"] < late)


# --- parking: the check writes the park file, the app writes `.parked`; nothing is deleted ---
def write_text(path, text):
    with open(path, "w") as handle:
        handle.write(text)


def request_park(park, n):
    write_text(park, "park %d\n" % n)


def resume(park, n):
    write_text(park, "resume %d\n" % n)


def read_parked(park, n):
    """The `.parked` line for park `n` as a dict, or None (absent, partial, or another park's)."""
    try:
        with open(park + ".parked") as handle:
            match = PARKED.match(handle.read())
    except OSError:
        return None
    if not match or int(match.group(1)) != n:
        return None
    return {"park": n, "measured": int(match.group(2)), "index": int(match.group(3)), "cycle": int(match.group(4))}


def wait_parked(park, n, clock, sleep, alive, timeout=PARK_TIMEOUT):
    """Polls for park `n`'s `.parked` line until `timeout` seconds pass or the
    app is gone. Returns (parked or None, seconds waited)."""
    start = clock()
    while True:
        parked = read_parked(park, n)
        if parked or not alive() or clock() - start >= timeout:
            return parked, round(clock() - start, 3)
        sleep(0.05)


def parks_valid(first, second):
    """Both parks reached, both at step 0 of the same cycle, the second after the first."""
    return (first is not None and second is not None and first["cycle"] > 0 and first["cycle"] == second["cycle"]
            and first["index"] % first["cycle"] == 0 and second["index"] % second["cycle"] == 0
            and second["measured"] >= first["measured"])


def snapshot(pid, clock, run_heap, wait, retry_after=RETRY_AFTER):
    """Takes one `heap -s` snapshot, tried up to SNAPSHOT_ATTEMPTS times,
    `retry_after` seconds after each non-zero exit. Returns (attempts, text):
    attempts lists each try's start (clock()) and exit; text is the output of
    the last try."""
    attempts = []
    for attempt in range(SNAPSHOT_ATTEMPTS):
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
    parser.add_argument("--workload", required=True)
    parser.add_argument("--wrap")
    parser.add_argument("--set", action="append", default=[], metavar="IKKOKU_PERF_X=VALUE")
    parser.add_argument("--timed", action="store_true", help="v2.2's timed snapshots, for builds without parking")
    parser.add_argument("--seconds", type=int, default=65)
    parser.add_argument("--early", type=float, default=EARLY_SECONDS)
    parser.add_argument("--late", type=float, default=LATE_SECONDS)
    args = parser.parse_args(argv)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    park = os.path.join(out, "park")
    allowance = TIMED_ALLOWANCE if args.timed else PARKED_ALLOWANCE
    perf = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf_trace.py")
    cmd = [sys.executable, "-I", perf, "run", "--app", args.app, "--environment", args.environment, "--out", out,
           "--workloads", args.workload, "--seconds", str(args.seconds), "--retries", "0"]
    for pair in args.set:
        cmd += ["--set", pair]
    if not args.timed:
        write_text(park, "run 0\n")
        cmd += ["--set", "IKKOKU_PERF_PARK_FILE=" + park]
    if args.wrap:
        cmd += ["--wrap", args.wrap]
    snaps, classes, parks, reached, problems = {}, {}, {}, {}, []
    with open(os.path.join(out, "perf_trace.out"), "w") as log:
        run = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        pid = None
        while run.poll() is None and pid is None:
            pid = app_pid(args.app)
            if pid is None:
                time.sleep(0.1)
        launched = time.monotonic()
        clock = lambda: time.monotonic() - launched  # noqa: E731
        for n, name, at in ((1, "early", args.early), (2, "late", args.late)):
            while pid and run.poll() is None and clock() < at:
                time.sleep(0.05)
            if not pid or run.poll() is not None:
                problems.append("the app ended before the %s snapshot" % name)
                break
            if not args.timed:
                request_park(park, n)
                parked, waited = wait_parked(park, n, clock, time.sleep, lambda: run.poll() is None)
                reached[name] = parked
                parks[name] = {"reached": parked, "waited": waited, "requested": round(at, 3)}
                print("park %d (%s): %s after %.3f s" % (n, name, "reached" if parked else "NOT reached", waited), flush=True)
                if not parked:
                    resume(park, n)
                    problems.append("park %d not reached" % n)
                    break
            attempts, text = snapshot(pid, clock, run_heap, time.sleep)
            if not args.timed:
                resume(park, n)
            with open(os.path.join(out, "heap-%s.txt" % name), "w") as handle:
                handle.write(text)
            last = attempts[-1]
            print("snapshot %s: %s" % (name, ", ".join("%.3f s exit %d" % (a["seconds"], a["exit"]) for a in attempts)), flush=True)
            snaps[name] = {"seconds": last["seconds"], "exit": last["exit"], "attempts": attempts,
                           "counts": parse_heap(text) if last["exit"] == 0 else None}
            classes[name] = parse_classes(text) if last["exit"] == 0 else None
        code = run.wait()
    actions = 0
    report_path = os.path.join(out, "%s.json" % args.workload)
    if "early" in snaps and "late" in snaps:
        if args.timed:
            if os.path.exists(report_path):
                with open(report_path) as handle:
                    actions = count_actions(json.load(handle), snaps["early"]["seconds"], snaps["late"]["seconds"])
        elif parks_valid(reached.get("early"), reached.get("late")):
            actions = reached["late"]["measured"] - reached["early"]["measured"]
        else:
            problems.append("the parks were not both at step 0 of one cycle")
    verdict, rows = judge(snaps.get("early", {}).get("counts"), snaps.get("late", {}).get("counts"), actions, allowance)
    flagged = flags(classes.get("early"), classes.get("late"), actions, allowance) if verdict != "invalid" else []
    note = slope_note(verdict, rows)
    result = {"checkVersion": CHECK_VERSION, "workload": args.workload, "mode": "timed" if args.timed else "parked",
              "set": args.set, "verdict": verdict, "slopeNote": note, "actions": actions, "minActions": MIN_ACTIONS,
              "perAction": PER_ACTION, "allowance": allowance, "parks": parks, "snapshots": snaps, "rows": rows,
              "flags": flagged, "problems": problems, "perfTraceExit": code}
    with open(os.path.join(out, "growth.json"), "w") as handle:
        json.dump(result, handle, indent=1)
        handle.write("\n")
    shown = verdict + (", slope %.3f (%s)" % (note["perAction"], note["type"]) if note else "")
    print("growth (%s, %s): %s (%d actions between snapshots at %s s and %s s)%s" % (
        args.workload, result["mode"], shown, actions, snaps.get("early", {}).get("seconds"),
        snaps.get("late", {}).get("seconds"), "; " + "; ".join(problems) if problems else ""))
    for row in rows:
        print("  %-36s %6d -> %6d  growth %5d (%.3f/action), bar %d%s" % (
            row["type"], row["early"], row["late"], row["growth"], row["perAction"], row["bar"], "" if row["ok"] else "  FAIL"))
    if verdict != "invalid":
        print("  flags (other classes growing by >= the bar; reviewed, not judged): %s" % (len(flagged) or "none"))
    for row in flagged:
        print("  FLAG %-60s %6d -> %6d  growth %5d (%.3f/action)" % (
            row["type"][:60], row["early"], row["late"], row["growth"], row["perAction"]))
    return {"pass": 0, "fail": 1}.get(verdict, 2)


if __name__ == "__main__":
    sys.exit(main())
