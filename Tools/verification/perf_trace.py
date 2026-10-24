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
        [--workloads studio-idle,studio-orbit] [--seconds 10] [--wrap /path/to/lock.sh] \
        [--main-load-ms 20 [--main-load-hz 30]]

    python3 Tools/verification/perf_trace.py summarize .local/perf/debug [.local/perf/release ...]

`--xctrace TEMPLATE` (for example "Time Profiler" or "Metal System Trace")
also records each workload with `xcrun xctrace record`, writing
`<workload>.<template>.trace` next to the report. The script starts the app
itself and attaches xctrace to that process id: `xctrace record --launch` with
an executable inside an `.app` resolves the bundle identifier through Launch
Services and can start another registered copy of the app (another checkout's
build) instead of the one named. The app still writes its own report and
exits; xctrace stops recording when it does.

    python3 Tools/verification/perf_trace.py profile <workload>.time-profiler.trace [--thread "Main Thread"]

aggregates a Time Profiler trace's samples between the app's `recordingBegin`
and `recordingEnd` marks: time per binary, the heaviest functions by self
time and by inclusive time.

`--main-load-ms N` busy-waits N ms on the app's main thread
`--main-load-hz` (default 30) times per second while recording, so the
summary's presented-interval p95 shows whether presentation keeps pace with
a busy main thread. Its reports are named `<workload>+load<N>.json`.
"""

import argparse
import collections
import json
import os
import re
import signal
import subprocess
import sys

WORKLOADS = ["studio-idle", "studio-orbit", "studio-fk-drag", "studio-hover",
             "maker-slider", "maker-idle", "studio-native", "viewport-lifecycle", "startup"]

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
    if workload in ("studio-native", "viewport-lifecycle"):
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
    load_ms = getattr(args, "main_load_ms", 0) or 0
    if load_ms:
        extra["IKKOKU_PERF_MAIN_LOAD_MS"] = str(load_ms)
        extra["IKKOKU_PERF_MAIN_LOAD_HZ"] = str(getattr(args, "main_load_hz", 30) or 30)
    os.makedirs(args.out, exist_ok=True)
    failures = []
    for repeat in range(args.repeat):
        for workload in workloads:
            suffix = ("+load%d" % load_ms if load_ms else "") + ("" if args.repeat == 1 else ".%d" % (repeat + 1))
            output = os.path.abspath(os.path.join(args.out, workload + suffix + ".json"))
            seconds = 2 if workload == "startup" else args.seconds
            warmup = 0 if workload == "startup" else args.warmup
            env = launch_environment(workload, fixtures, output, seconds, warmup, extra)
            # The timeout bounds the app run only, not the wait for the lock, so
            # the wrapper runs this script's own `_exec` guard around the app.
            target = [os.path.abspath(args.app)]
            guard = [sys.executable, os.path.abspath(__file__), "_exec",
                     "--timeout", str(warmup + seconds + args.startup_timeout)]
            if args.xctrace:
                slug = args.xctrace.lower().replace(" ", "-")
                guard += ["--xctrace", args.xctrace, "--trace", output[:-5] + "." + slug + ".trace"]
            guard += ["--"] + target
            argv = ([args.wrap] if args.wrap else []) + guard
            log_path = output[:-5] + ".log"
            print("[perf] %s -> %s" % (workload, output), flush=True)
            # A run whose window was not composited (the user switched Spaces,
            # say) says nothing about presentation: run it again.
            for attempt in range(1 + args.retries):
                # An exit-zero launch that writes no report must not inherit a
                # successful report from an earlier invocation or retry.
                if os.path.exists(output):
                    os.unlink(output)
                with open(log_path, "w", encoding="utf-8") as log:
                    code = subprocess.run(argv, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
                reason = None
                if code == 0 and os.path.exists(output) and workload not in PRESENTATION_EXEMPT:
                    with open(output, encoding="utf-8") as handle:
                        reason = uncomposited(json.load(handle))
                if not reason:
                    break
                print("[perf] %s: %s; %s" % (workload, reason, "running it again" if attempt < args.retries else "giving up"), flush=True)
            if code != 0 or not os.path.exists(output):
                failures.append("%s: exit %s (see %s)" % (workload, code, log_path))
            elif reason:
                failures.append("%s: window not composited in %d attempts (%s)" % (workload, 1 + args.retries, reason))
    summarize([args.out])
    if failures:
        print("\n".join(["[perf] FAILED"] + failures), file=sys.stderr)
        return 1
    return 0


def stop(process, grace):
    """SIGINT, then SIGKILL after `grace` seconds; xctrace finishes its trace on SIGINT."""
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def guarded_exec(args):
    """Runs one app launch, killing it if it outlives `--timeout` seconds.

    With `--xctrace TEMPLATE --trace PATH` an `xctrace record --attach` of the
    launched process id records it until it exits (see the module notes on
    why the app is not launched by xctrace)."""
    process = subprocess.Popen(args.argv)
    recorder = None
    if getattr(args, "xctrace", None):
        recorder = subprocess.Popen(["xcrun", "xctrace", "record", "--template", args.xctrace, "--output", args.trace,
                                     "--no-prompt", "--attach", str(process.pid), "--time-limit", "%ds" % (args.timeout + 60)])
    try:
        code = process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        stop(process, 10)
        print("[perf] launch stopped after %d s" % args.timeout, flush=True)
        code = 124
    if recorder is not None:
        # An attached recording ends when its process exits; give it time to save.
        try:
            recorder.wait(timeout=120)
        except subprocess.TimeoutExpired:
            stop(recorder, 60)
        if recorder.returncode not in (0, None) and code == 0:
            print("[perf] xctrace exited %s" % recorder.returncode, flush=True)
    return code


def load(directory):
    reports = {}
    for name in sorted(os.listdir(directory)):
        if name.endswith(".json") and not name.startswith("summary"):
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                reports[name[:-5]] = json.load(handle)
    return reports


HEADER = ("| report | app/engine | draw thread | main load | presented FPS | hitches (/s) | presented interval ms p50/p95 "
          "| draw ms p50/p95 | GPU ms p50/p95 | main busy ms/s | main draw ms/s | model ms/s | load ms/s | other ms/s "
          "| render-thread draw ms/s | model phases ms p50/p95 × rate | peak footprint MiB |")


def row(name, report):
    """One summary line. Schema 2 reports (before the render thread) lack the
    draw thread, load and render-thread fields; their draws ran on the main thread."""
    summary = report["summary"]
    phases = summary["phases"]
    main = summary["mainThread"]

    def phase(key, field="p50"):
        entry = phases.get(key)
        return "%.2f" % entry[field] if entry else "-"

    def stat(entry, field):
        return "%.2f" % entry[field] if entry and field in entry else "-"

    model = [k for k in ("studioTick", "studioRefresh", "studioCameraRefresh", "makerTick", "makerRefresh", "input") if k in phases]
    model_text = ", ".join("%s %s/%s ×%.0f/s" % (k, phase(k), phase(k, "p95"), phases[k]["perSecond"]) for k in model) or "-"
    build = report["build"]
    configuration = report.get("configuration", {})
    load = configuration.get("mainLoadMs", 0)
    load_text = "%g ms × %g/s" % (load, configuration.get("mainLoadHz", 30)) if load else "-"
    seconds = summary.get("recordedSeconds")
    hitches = "%d (%.1f/s)" % (summary["hitches"], summary["hitches"] / seconds) if seconds else "%d" % summary["hitches"]
    interval = summary.get("presentedIntervalMs")
    render = summary.get("renderThread", {})
    return "| %s | %s/%s | %s | %s | %.1f | %s | %s/%s | %s/%s | %s/%s | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %s | %.0f |" % (
        name, build["appAssertConfiguration"], build["engineAssertConfiguration"], summary.get("drawThread", "main"), load_text,
        summary["presentedFPS"], hitches, stat(interval, "p50"), stat(interval, "p95"),
        phase("draw"), phase("draw", "p95"), phase("gpu"), phase("gpu", "p95"),
        main["busyMsPerSecond"], main["drawMsPerSecond"], main["modelMsPerSecond"], main.get("loadMsPerSecond", 0),
        main["otherMsPerSecond"], render.get("drawMsPerSecond", 0),
        model_text, summary["memory"]["peakFootprintBytes"] / 1048576)


def attribution_row(name, report, top=6):
    """Model events and SwiftUI body evaluations per second, and per input
    event when the workload sends input (schema 2 reports; older ones lack them)."""
    summary = report["summary"]
    inputs = sum(summary.get("inputCalls", {}).values()) / summary["recordedSeconds"] if summary.get("recordedSeconds") else 0

    def rate(entry):
        per_second = entry["perSecond"]
        return "%.0f/s (%.2f/input)" % (per_second, per_second / inputs) if inputs else "%.0f/s" % per_second

    events = summary.get("events", {})
    bodies = sorted(summary.get("viewBodies", {}).items(), key=lambda item: (-item[1]["perSecond"], item[0]))
    event_text = ", ".join("%s %s" % (key, rate(events[key])) for key in sorted(events)) or "-"
    body_text = ", ".join("%s %s" % (key, rate(entry)) for key, entry in bodies[:top]) or "-"
    if len(bodies) > top:
        body_text += ", +%d more" % (len(bodies) - top)
    return "| %s | %.0f | %s | %s |" % (name, inputs, event_text, body_text)


def uncomposited(report):
    """Why a report's presentation numbers cannot be trusted, or None.

    A drawable whose presented handler reports time 0 was never shown. When a
    frame takes seconds (Debug source scenes), the few drawables of a run can
    expire legitimately. Otherwise a large dropped share means the window was
    not being composited (another Space, a full-screen app or Mission Control
    during the run): over a tenth with the main thread not saturated, or over a
    quarter of at least 100 drawables even when it is."""
    summary = report["summary"]
    callbacks = summary.get("displayLinkCallbacks", 0)
    dropped = summary.get("droppedDrawables", 0)
    busy = summary["mainThread"]["busyMsPerSecond"]
    idle_drops = callbacks >= 30 and dropped > 0.1 * callbacks and busy < 900
    saturated_drops = callbacks >= 100 and dropped > 0.25 * callbacks
    if idle_drops or saturated_drops:
        return "%d of %d drawables never presented with the main thread %.0f ms/s busy" % (dropped, callbacks, busy)
    return None


# Workloads that send no viewport input, so any input call came from a person.
INPUTLESS_WORKLOADS = {"studio-idle", "maker-idle", "studio-native", "viewport-lifecycle", "startup"}

# Workloads whose window is minimized on purpose: their drawables are not all
# shown, so the composited check does not apply and their frame rates are not cited.
PRESENTATION_EXEMPT = {"viewport-lifecycle"}


def lifecycle_problem(report):
    """Why a `viewport-lifecycle` run failed its own checks, or None: render
    threads left over after the viewport was replaced (more at the end than
    before the first step), or no frame presented after the window was restored."""
    lifecycle = report.get("details", {}).get("lifecycle")
    if report.get("workload") != "viewport-lifecycle" or lifecycle is None:
        return None
    steps = lifecycle.get("steps", [])
    if not steps:
        return "the lifecycle steps did not run"
    start, end = steps[0]["renderThreadsBefore"], lifecycle["renderThreadsAtEnd"]
    peak = max([s["renderThreadsBefore"] for s in steps] + [end])
    problems = []
    if end > start or peak > max(start, 1):
        problems.append("render threads %d before, %d at most, %d at the end" % (start, peak, end))
    if lifecycle.get("presentedAfterRestore", 0) == 0:
        problems.append("no frame presented after the window was restored")
    if lifecycle.get("windowMiniaturized"):
        problems.append("the window was still minimized at the end")
    return "; ".join(problems) or None


def lifecycle_line(name, report):
    lifecycle = report["details"]["lifecycle"]
    steps = lifecycle.get("steps", [])
    return "[perf] %s: %d steps, render threads before each step %s, at the end %d; %d draws and %d presented frames after the restore" % (
        name, len(steps), [s["renderThreadsBefore"] for s in steps], lifecycle.get("renderThreadsAtEnd", -1),
        lifecycle.get("drawsAfterRestore", 0), lifecycle.get("presentedAfterRestore", 0))


def ring_line(name, report):
    """The frame ring's per-draw skin palettes (G4), or None for a report without them."""
    ring = report["summary"].get("frameRing")
    if not ring or not ring.get("skinPalettesPerDraw", {}).get("count"):
        return None
    return "[perf] %s: frame ring %g skin palettes and %g KiB per draw (p50), %d palette buffers created, %d draws with overflow" % (
        name, ring["skinPalettesPerDraw"]["p50"], ring["paletteKiBPerDraw"]["p50"], ring.get("paletteBuffersCreated", 0),
        ring.get("drawsWithOverflow", 0))


def live_line(name, report):
    """The Studio live step off the main thread (R7 phase 2, item 3): its
    background job's wall time and worker CPU, the main thread's waits for it,
    and the steps skipped, run serially or re-evaluated; None for a report
    without live steps."""
    summary = report["summary"]
    phases = summary["phases"]
    job = phases.get("studioLiveJob")
    events = summary.get("events", {})
    serial = events.get("studioLiveTickSerial", {}).get("perSecond", 0)
    if not job and not serial:
        return None
    cpu = phases.get("studioLiveCPU", {})
    wait = phases.get("studioLiveWait", {})
    text = "[perf] %s: live step" % name
    if job:
        text += " job wall %.2f/%.2f ms (p50/p95) x %.1f/s, worker CPU %.2f ms per job (%.0f ms/s)" % (
            job["p50"], job["p95"], job["perSecond"], cpu.get("mean", 0), cpu.get("msPerSecond", 0))
        text += ", main waits %.1f/s (%.2f ms/s)" % (wait.get("perSecond", 0), wait.get("msPerSecond", 0))
    return text + ", skipped %.1f/s, serial %.1f/s, re-evaluated %.1f/s" % (
        events.get("studioLiveTickSkipped", {}).get("perSecond", 0), serial,
        events.get("studioLiveTickDiscarded", {}).get("perSecond", 0))


def stray_input(report):
    """Input calls the workload did not send (someone moved the mouse over the window), or None."""
    if report.get("workload") not in INPUTLESS_WORKLOADS:
        return None
    calls = sum(report["summary"].get("inputCalls", {}).values())
    if calls:
        return "%d input calls the workload did not send; someone used the mouse over the window, check it against a rerun" % calls
    return None


def summarize(directories):
    print(HEADER)
    print("|---|---|---|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|")
    warnings = []
    attributed = []
    lifecycles = []
    rings = []
    for directory in directories:
        for name, report in load(directory).items():
            if "summary" not in report:
                continue
            label = "%s/%s" % (os.path.basename(os.path.normpath(directory)), name)
            print(row(label, report))
            if "viewBodies" in report["summary"] or "events" in report["summary"]:
                attributed.append(attribution_row(label, report))
            ring = ring_line(label, report)
            if ring:
                rings.append(ring)
            live = live_line(label, report)
            if live:
                rings.append(live)
            if report.get("workload") == "viewport-lifecycle" and "lifecycle" in report.get("details", {}):
                lifecycles.append(lifecycle_line(label, report))
                problem = lifecycle_problem(report)
                if problem:
                    warnings.append("%s: %s" % (label, problem))
            reason = None if report.get("workload") in PRESENTATION_EXEMPT else uncomposited(report)
            if reason:
                warnings.append("%s: %s; the window was probably not on screen, rerun it" % (label, reason))
            stray = stray_input(report)
            if stray:
                warnings.append("%s: %s" % (label, stray))
    if attributed:
        print()
        print("| report | input events/s | model events | view bodies (most evaluated first) |")
        print("|---|---:|---|---|")
        for line in attributed:
            print(line)
    for line in rings + lifecycles:
        print(line)
    for warning in warnings:
        print("[perf] WARNING " + warning)
    return 0


def export_table(trace, schema, extra=""):
    xpath = '/trace-toc/run[@number="1"]/data/table[@schema="%s"%s]' % (schema, extra)
    return subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                          check=True, capture_output=True).stdout


class Resolver:
    """xctrace export writes each value once with an `id` and later as a `ref`."""

    def __init__(self):
        self.seen = {}

    def __call__(self, element):
        if "ref" in element.attrib:
            return self.seen[element.attrib["ref"]]
        if "id" in element.attrib:
            self.seen[element.attrib["id"]] = element
        for child in element:
            self(child)
        return element


def xml_rows(data, resolve=None):
    """Yields each exported row as a list of (tag, element) with refs resolved."""
    import xml.etree.ElementTree as ElementTree
    root = ElementTree.fromstring(data)
    resolve = resolve or Resolver()
    for row in root.iter("row"):
        yield [(child.tag, resolve(child)) for child in row]


def signpost_marks(trace):
    """Trace time (ns) of each `Mark` signpost the app emitted, by mark name."""
    data = export_table(trace, "os-signpost", ' and @category="PointsOfInterest"')
    marks = {}
    for row in xml_rows(data):
        fields = dict(row)
        name, metadata = fields.get("signpost-name"), fields.get("os-log-metadata")
        if name is None or metadata is None or name.attrib.get("fmt") != "Mark":
            continue
        marks.setdefault(metadata.attrib.get("fmt", ""), int(fields["event-time"].text))
    return marks


def report_for(trace):
    """The report `run` wrote beside a trace: <workload>.<template>.trace -> <workload>.json."""
    stem = os.path.splitext(os.path.splitext(trace.rstrip("/"))[0])[0]
    return stem + ".json"


def recording_window(trace, report=None):
    """(begin ns, end ns, how) of the recording window in trace time.

    The app emits recordingBegin/recordingEnd signposts. A trace recorded by
    an older harness lacks them; then the report's startup marks (seconds since
    process start) are shifted onto trace time through a mark both share, as
    an attached recorder misses the marks emitted before it attached."""
    marks = signpost_marks(trace)
    if "recordingBegin" in marks and "recordingEnd" in marks:
        return marks["recordingBegin"], marks["recordingEnd"], "recordingBegin..recordingEnd signposts"
    report = report or report_for(trace)
    if not os.path.exists(report):
        return None, None, "whole trace"
    with open(report, encoding="utf-8") as handle:
        startup = json.load(handle).get("startupSeconds", {})
    shared = [name for name in ("contentAppeared", "appStateReady", "sourceSceneImport.end", "makerReady")
              if name in marks and name in startup]
    if not shared or "recordingBegin" not in startup or "recordingEnd" not in startup:
        return None, None, "whole trace"
    offset = marks[shared[0]] - startup[shared[0]] * 1e9
    return (int(startup["recordingBegin"] * 1e9 + offset), int(startup["recordingEnd"] * 1e9 + offset),
            "report marks aligned on %s (%s)" % (shared[0], os.path.basename(report)))


def traced_processes(trace):
    """The recorded target processes' paths from the trace's table of contents."""
    import xml.etree.ElementTree as ElementTree
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], check=True, capture_output=True).stdout
    return sorted({p.attrib["path"] for p in ElementTree.fromstring(toc).iter("process")
                   if p.attrib.get("path") and p.attrib.get("pid") != "0"})


def profile(args):
    if not getattr(args, "skip_toc", False):
        # A trace of the wrong executable would be silently misattributed.
        for path in traced_processes(args.trace):
            print("process: %s" % path)
    begin, end, how = (None, None, "whole trace") if args.whole else recording_window(args.trace, getattr(args, "report", None))
    data = export_table(args.trace, "time-profile")
    stacks = {}
    total = 0
    by_thread = collections.Counter()
    by_binary = collections.Counter()
    self_time = collections.Counter()
    inclusive = collections.Counter()
    callees = collections.Counter()
    focus_pattern = re.compile(args.focus) if args.focus else None
    thread_pattern = re.compile(args.thread) if args.thread else None
    binary_pattern = re.compile(args.binary) if args.binary else None
    resolve = Resolver()
    for row in xml_rows(data, resolve):
        fields = dict(row)
        time = int(fields["sample-time"].text)
        if (begin is not None and time < begin) or (end is not None and time > end):
            continue
        thread = fields["thread"].attrib.get("fmt", "")
        weight = int(fields["weight"].text) / 1e6 if "weight" in fields else 1.0
        by_thread[re.sub(r" \(0x[0-9a-f]+\)", "", thread)] += weight
        if thread_pattern and not thread_pattern.search(thread):
            continue
        backtrace = fields.get("tagged-backtrace")
        if backtrace is None:
            backtrace = fields.get("backtrace")
        if backtrace is None:
            continue
        key = id(backtrace)
        if key not in stacks:
            frames = []
            for frame in backtrace.findall("frame"):
                frame = resolve(frame)
                binary = frame.find("binary")
                binary = resolve(binary) if binary is not None else None
                frames.append((frame.attrib.get("name", frame.attrib.get("addr", "?")),
                               binary.attrib.get("name", "?") if binary is not None else "?"))
            stacks[key] = frames
        frames = stacks[key]
        if not frames:
            continue
        if focus_pattern:
            # Frames run leaf first: the outermost match owns the sample and
            # the frame just inside it is the callee it is charged to.
            outer = max((i for i, (name, _) in enumerate(frames) if focus_pattern.search(name)), default=None)
            if outer is None:
                continue
            callees[frames[outer - 1][0] if outer > 0 else "<self>"] += weight
        total += weight
        self_time[frames[0][0]] += weight
        by_binary[frames[0][1]] += weight
        for name, binary in set(frames):
            if binary_pattern is None or binary_pattern.search(binary):
                inclusive[name] += weight
    seconds = (end - begin) / 1e9 if begin is not None and end is not None else None
    print("window: %s" % ("%.2f s (%s)" % (seconds, how) if seconds else "whole trace"))
    print("samples ms by thread (all threads):")
    for name, value in by_thread.most_common(8):
        print("  %8.1f  %s" % (value, name))
    print("selected samples: %.1f ms%s" % (total, " (%.1f ms/s)" % (total / seconds) if seconds else ""))

    def table(title, counter):
        print(title)
        for name, value in counter.most_common(args.top):
            rate = " %7.2f ms/s" % (value / seconds) if seconds else ""
            print("  %8.1f ms %5.1f%%%s  %s" % (value, 100 * value / max(total, 1e-9), rate, name[:160]))
    table("self time by binary:", by_binary)
    table("self time by function:", self_time)
    table("inclusive time by function%s:" % (" in binaries matching %r" % args.binary if args.binary else ""), inclusive)
    if focus_pattern:
        table("direct callees of the outermost frame matching %r:" % args.focus, callees)
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
    runner.add_argument("--retries", type=int, default=2, help="reruns of a launch whose window was not composited")
    runner.add_argument("--startup-timeout", type=int, default=180, help="seconds allowed beyond warmup+recording")
    runner.add_argument("--wrap", help="command each launch runs under, e.g. a machine-wide app lock script")
    runner.add_argument("--set", action="append", metavar="IKKOKU_PERF_X=VALUE", help="extra launch variable")
    runner.add_argument("--xctrace", metavar="TEMPLATE", help="record each launch with this xctrace template")
    runner.add_argument("--main-load-ms", type=int, default=0, help="busy-wait this many ms on the main thread per load tick while recording")
    runner.add_argument("--main-load-hz", type=int, default=30, help="load ticks per second (with --main-load-ms)")
    summary = sub.add_parser("summarize", help="print a table for report directories")
    summary.add_argument("directories", nargs="+")
    prof = sub.add_parser("profile", help="aggregate a Time Profiler trace over the recording window")
    prof.add_argument("trace")
    prof.add_argument("--thread", help="regular expression a thread name must match (e.g. 'Main Thread')")
    prof.add_argument("--top", type=int, default=30)
    prof.add_argument("--binary", help="regular expression limiting the inclusive table to these binaries (e.g. 'Ikkoku')")
    prof.add_argument("--whole", action="store_true", help="ignore the recording marks")
    prof.add_argument("--report", help="report whose startup marks place the window when the trace lacks recording signposts (default: the report beside the trace)")
    prof.add_argument("--focus", help="regular expression: keep samples inside a matching frame and list what it spends its time calling")
    guard = sub.add_parser("_exec", help=argparse.SUPPRESS)
    guard.add_argument("--timeout", type=int, required=True)
    guard.add_argument("--xctrace")
    guard.add_argument("--trace")
    guard.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command == "run":
        return run(args)
    if args.command == "profile":
        return profile(args)
    if args.command == "_exec":
        if args.argv[:1] == ["--"]:
            args.argv = args.argv[1:]
        return guarded_exec(args)
    return summarize(args.directories)


if __name__ == "__main__":
    sys.exit(main())
