#!/usr/bin/env python3
"""Run the app's IKKOKU_PERF_TRACE workloads and summarize their reports (R7).

Each workload is one app launch: the app opens its editor window, sets the
workload up, warms up, records for a fixed time, writes a JSON report and
exits (see docs/reference/performance.md). This script only builds each
launch's environment from the private fixture map, runs the launches one at a
time (optionally through a lock wrapper, so at most one app instance runs on
the machine) and prints a comparison table. It never interprets frames itself
beyond reading the report's summary block.

    python3 Tools/verification/perf_trace.py run \
        --app .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku \
        --environment /path/to/environment.json --out .local/perf/debug \
        [--workloads studio-idle,studio-orbit] [--seconds 10] [--wrap /path/to/lock.sh]

    python3 Tools/verification/perf_trace.py summarize .local/perf/debug [.local/perf/release ...]

`--xctrace TEMPLATE` (for example "Time Profiler" or "Metal System Trace")
launches each workload under `xcrun xctrace record` instead, writing
`<workload>.<template>.trace` next to the report. The app still writes its own
report and exits; xctrace stops recording when it does.
"""

import argparse
import json
import os
import signal
import subprocess
import sys

WORKLOADS = ["studio-idle", "studio-orbit", "studio-fk-drag", "studio-hover",
             "maker-slider", "maker-idle", "studio-native", "startup"]

# Fixture variables each workload family reads, by their environment.json
# names. `IKKOKU_SOURCE_SCENE` comes from the scenario scene, the Maker card
# from the Maker scenario card, like the scenario lanes.
STUDIO_FIXTURES = {
    "IKKOKU_SOURCE_SCENE": "IKKOKU_STUDIO_SCENARIO_SCENE",
    "IKKOKU_SOURCE_AVATAR": "IKKOKU_SOURCE_AVATAR",
    "IKKOKU_SOURCE_MALE_AVATAR": "IKKOKU_SOURCE_MALE_AVATAR",
    "IKKOKU_MAKER_LIBRARY": "IKKOKU_MAKER_LIBRARY",
    "IKKOKU_STUDIO_ANIMATION_CATALOG": "IKKOKU_STUDIO_ANIMATION_CATALOG",
    "IKKOKU_STUDIO_LOOK_SETTINGS": "IKKOKU_STUDIO_LOOK_SETTINGS",
    "IKKOKU_STUDIO_HAND_PATTERNS": "IKKOKU_STUDIO_HAND_PATTERNS",
    "IKKOKU_STUDIO_ITEM_CATALOG": "IKKOKU_STUDIO_ITEM_CATALOG",
}
MAKER_FIXTURES = {
    "IKKOKU_SOURCE_CARD": "IKKOKU_MAKER_SCENARIO_CARD",
    "IKKOKU_SOURCE_AVATAR": "IKKOKU_SOURCE_AVATAR",
    "IKKOKU_SOURCE_MALE_AVATAR": "IKKOKU_SOURCE_MALE_AVATAR",
    "IKKOKU_MAKER_LIBRARY": "IKKOKU_MAKER_LIBRARY",
}
NATIVE_FIXTURES = {
    "IKKOKU_SOURCE_AVATAR": "IKKOKU_SOURCE_AVATAR",
    "IKKOKU_MAKER_LIBRARY": "IKKOKU_MAKER_LIBRARY",
}


def fixtures_for(workload):
    if workload.startswith("maker-"):
        return MAKER_FIXTURES
    if workload == "studio-native":
        return NATIVE_FIXTURES
    # Startup measures the full source-scene startup.
    return STUDIO_FIXTURES


def launch_environment(workload, fixtures, output, seconds, warmup, extra):
    env = {key: value for key, value in os.environ.items() if not key.startswith("IKKOKU_")}
    for variable, source in fixtures_for(workload).items():
        path = fixtures.get(source)
        if not path:
            raise SystemExit("environment file has no %s (needed by %s)" % (source, workload))
        if not os.path.exists(path):
            raise SystemExit("%s does not exist: %s" % (source, path))
        env[variable] = path
    env["IKKOKU_PERF_TRACE"] = output
    env["IKKOKU_PERF_WORKLOAD"] = workload
    env["IKKOKU_PERF_SECONDS"] = str(seconds)
    env["IKKOKU_PERF_WARMUP_SECONDS"] = str(warmup)
    env.update(extra)
    return env


def run(args):
    with open(args.environment, encoding="utf-8") as handle:
        fixtures = json.load(handle)
    workloads = args.workloads.split(",") if args.workloads else WORKLOADS
    unknown = [w for w in workloads if w not in WORKLOADS]
    if unknown:
        raise SystemExit("unknown workloads: %s" % ", ".join(unknown))
    extra = dict(pair.split("=", 1) for pair in args.set or [])
    os.makedirs(args.out, exist_ok=True)
    failures = []
    for repeat in range(args.repeat):
        for workload in workloads:
            suffix = "" if args.repeat == 1 else ".%d" % (repeat + 1)
            output = os.path.abspath(os.path.join(args.out, workload + suffix + ".json"))
            seconds = 2 if workload == "startup" else args.seconds
            warmup = 0 if workload == "startup" else args.warmup
            env = launch_environment(workload, fixtures, output, seconds, warmup, extra)
            # The timeout bounds the app run only, not the wait for the lock, so
            # the wrapper runs this script's own `_exec` guard around the app.
            target = [os.path.abspath(args.app)]
            if args.xctrace:
                slug = args.xctrace.lower().replace(" ", "-")
                trace = output[:-5] + "." + slug + ".trace"
                # xctrace starts the target with only the variables passed to it.
                passed = [item for key, value in sorted(env.items()) if key.startswith("IKKOKU_")
                          for item in ("--env", "%s=%s" % (key, value))]
                target = (["xcrun", "xctrace", "record", "--template", args.xctrace, "--output", trace, "--no-prompt", "--target-stdout", "-",
                           "--time-limit", "%ds" % (warmup + seconds + args.startup_timeout)]
                          + passed + ["--launch", "--"] + target)
            guard = [sys.executable, os.path.abspath(__file__), "_exec",
                     "--timeout", str(warmup + seconds + args.startup_timeout + (120 if args.xctrace else 0)), "--"] + target
            argv = ([args.wrap] if args.wrap else []) + guard
            log_path = output[:-5] + ".log"
            print("[perf] %s -> %s" % (workload, output), flush=True)
            with open(log_path, "w", encoding="utf-8") as log:
                code = subprocess.run(argv, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
            if code != 0 or not os.path.exists(output):
                failures.append("%s: exit %s (see %s)" % (workload, code, log_path))
    summarize([args.out])
    if failures:
        print("\n".join(["[perf] FAILED"] + failures), file=sys.stderr)
        return 1
    return 0


def guarded_exec(args):
    """Runs one app launch, killing it if it outlives `--timeout` seconds."""
    process = subprocess.Popen(args.argv)
    try:
        return process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        # SIGINT first: xctrace then stops its target and finishes the trace.
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        print("[perf] launch stopped after %d s" % args.timeout, flush=True)
        return 124


def load(directory):
    reports = {}
    for name in sorted(os.listdir(directory)):
        if name.endswith(".json") and not name.startswith("summary"):
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                reports[name[:-5]] = json.load(handle)
    return reports


def row(name, report):
    summary = report["summary"]
    phases = summary["phases"]
    main = summary["mainThread"]

    def phase(key, field="p50"):
        entry = phases.get(key)
        return "%.2f" % entry[field] if entry else "-"

    model = [k for k in ("studioTick", "studioRefresh", "makerTick", "makerRefresh", "input") if k in phases]
    model_text = ", ".join("%s %s/%s ×%.0f/s" % (k, phase(k), phase(k, "p95"), phases[k]["perSecond"]) for k in model) or "-"
    build = report["build"]
    return "| %s | %s/%s | %.1f | %d | %s/%s | %s/%s | %.0f | %.0f | %.0f | %.0f | %s | %.0f |" % (
        name, build["appAssertConfiguration"], build["engineAssertConfiguration"],
        summary["presentedFPS"], summary["hitches"],
        phase("draw"), phase("draw", "p95"), phase("gpu"), phase("gpu", "p95"),
        main["busyMsPerSecond"], main["drawMsPerSecond"], main["modelMsPerSecond"], main["otherMsPerSecond"],
        model_text, summary["memory"]["peakFootprintBytes"] / 1048576)


def summarize(directories):
    print("| report | app/engine | presented FPS | hitches | draw ms p50/p95 | GPU ms p50/p95 | main busy ms/s | draw ms/s | model ms/s | other ms/s | model phases ms p50/p95 × rate | peak footprint MiB |")
    print("|---|---|---:|---:|---|---|---:|---:|---:|---:|---|---:|")
    for directory in directories:
        for name, report in load(directory).items():
            if "summary" not in report:
                continue
            print(row("%s/%s" % (os.path.basename(os.path.normpath(directory)), name), report))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    runner = sub.add_parser("run", help="launch workloads and write one report each")
    runner.add_argument("--app", required=True, help="the Ikkoku executable (…/Ikkoku.app/Contents/MacOS/Ikkoku)")
    runner.add_argument("--environment", required=True, help="private fixture map (environment.json)")
    runner.add_argument("--out", required=True, help="directory for <workload>.json reports and logs")
    runner.add_argument("--workloads", help="comma-separated subset of: " + ", ".join(WORKLOADS))
    runner.add_argument("--seconds", type=int, default=10)
    runner.add_argument("--warmup", type=int, default=3)
    runner.add_argument("--repeat", type=int, default=1)
    runner.add_argument("--startup-timeout", type=int, default=180, help="seconds allowed beyond warmup+recording")
    runner.add_argument("--wrap", help="command each launch runs under, e.g. a machine-wide app lock script")
    runner.add_argument("--set", action="append", metavar="IKKOKU_PERF_X=VALUE", help="extra launch variable")
    runner.add_argument("--xctrace", metavar="TEMPLATE", help="record each launch with this xctrace template")
    summary = sub.add_parser("summarize", help="print a table for report directories")
    summary.add_argument("directories", nargs="+")
    guard = sub.add_parser("_exec", help=argparse.SUPPRESS)
    guard.add_argument("--timeout", type=int, required=True)
    guard.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command == "run":
        return run(args)
    if args.command == "_exec":
        if args.argv[:1] == ["--"]:
            args.argv = args.argv[1:]
        return guarded_exec(args)
    return summarize(args.directories)


if __name__ == "__main__":
    sys.exit(main())
