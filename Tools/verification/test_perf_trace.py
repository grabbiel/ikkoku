"""Self-tests for perf_trace.py: launch environments, report rows, the
xctrace export reader and the launch guard. No app, trace or fixture is
needed; xctrace exports are synthetic XML in the shape `xctrace export` writes.
"""

import argparse
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perf_trace  # noqa: E402


def report(app="Release", engine="Release"):
    phase = {"count": 30, "p50": 1.5, "p95": 2.5, "perSecond": 30}
    return {
        "build": {"appAssertConfiguration": app, "engineAssertConfiguration": engine},
        "summary": {
            "presentedFPS": 118.4, "hitches": 3,
            "phases": {"draw": phase, "gpu": dict(phase, p50=4.0, p95=5.0), "studioTick": phase},
            "mainThread": {"busyMsPerSecond": 400, "drawMsPerSecond": 200, "modelMsPerSecond": 150, "otherMsPerSecond": 50},
            "memory": {"peakFootprintBytes": 512 * 1048576},
        },
    }


# One sample at 1 ms per weight unit; frames run leaf first, refs reuse ids.
PROFILE = """<?xml version="1.0"?>
<trace-query-result><node>
<row><sample-time id="1">100</sample-time><thread id="2" fmt="Main Thread (0x1) (Ikkoku)"/><weight id="3">2000000</weight>
<tagged-backtrace id="4"><frame id="5" name="leaf"><binary id="6" name="libswiftCore.dylib"/></frame>
<frame id="7" name="callee"><binary id="8" name="Ikkoku"/></frame><frame id="9" name="hot"><binary ref="8"/></frame>
<frame id="10" name="main"><binary ref="8"/></frame></tagged-backtrace></row>
<row><sample-time id="11">200</sample-time><thread ref="2"/><weight id="12">1000000</weight><tagged-backtrace ref="4"/></row>
<row><sample-time id="13">300</sample-time><thread id="14" fmt="Worker (0x2) (Ikkoku)"/><weight ref="12"/>
<tagged-backtrace id="15"><frame ref="10"/></tagged-backtrace></row>
</node></trace-query-result>"""


def signposts(*marks):
    """An os-signpost export with one `Mark` event per (name, ns); later rows ref the first's name."""
    rows = []
    for index, (name, time) in enumerate(marks):
        signpost = '<signpost-name id="2" fmt="Mark">Mark</signpost-name>' if index == 0 else '<signpost-name ref="2"/>'
        rows.append('<row><event-time id="t%d">%d</event-time>%s<os-log-metadata id="m%d" fmt="%s"><string>%s</string></os-log-metadata></row>'
                    % (index, time, signpost, index, name, name))
    rows.append('<row><event-time id="x">5</event-time><signpost-name id="3" fmt="Input">Input</signpost-name>'
                '<os-log-metadata id="y" fmt="recordingBegin"/></row>')  # not a Mark
    return ('<?xml version="1.0"?><trace-query-result><node>%s</node></trace-query-result>' % "".join(rows)).encode()


class PerfTraceTests(unittest.TestCase):
    def test_recording_window_prefers_signposts_and_otherwise_aligns_the_report(self):
        with mock.patch.object(perf_trace, "export_table", return_value=signposts(
                ("appStateReady", 4_000_000_000), ("recordingBegin", 7_000_000_000), ("recordingEnd", 15_000_000_000))):
            self.assertEqual(perf_trace.recording_window("w.time-profiler.trace")[:2], (7_000_000_000, 15_000_000_000))
        with tempfile.TemporaryDirectory() as folder:
            trace = os.path.join(folder, "studio-orbit.time-profiler.trace")
            self.assertEqual(perf_trace.report_for(trace + "/"), os.path.join(folder, "studio-orbit.json"))
            with open(os.path.join(folder, "studio-orbit.json"), "w") as handle:
                handle.write('{"startupSeconds": {"appStateReady": 5.5, "recordingBegin": 9.0, "recordingEnd": 17.0}}')
            # The attached recorder saw appStateReady 1.5 s earlier than process time.
            with mock.patch.object(perf_trace, "export_table", return_value=signposts(("appStateReady", 4_000_000_000))):
                begin, end, how = perf_trace.recording_window(trace)
            self.assertEqual((begin, end), (7_500_000_000, 15_500_000_000))
            self.assertIn("aligned on appStateReady", how)
            with mock.patch.object(perf_trace, "export_table", return_value=signposts(("unrelated", 1))):
                self.assertEqual(perf_trace.recording_window(trace)[:2], (None, None))


    def test_launch_environment_maps_fixtures_and_drops_inherited_ikkoku_variables(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = {}
            for name in ("IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_MAKER_SCENARIO_CARD", "IKKOKU_SOURCE_AVATAR",
                         "IKKOKU_SOURCE_MALE_AVATAR", "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_ANIMATION_CATALOG",
                         "IKKOKU_STUDIO_LOOK_SETTINGS", "IKKOKU_STUDIO_HAND_PATTERNS", "IKKOKU_STUDIO_ITEM_CATALOG"):
                paths[name] = os.path.join(folder, name)
                open(paths[name], "w").close()
            with mock.patch.dict(os.environ, {"IKKOKU_AUTOCAPTURE": "/stale.png"}):
                studio = perf_trace.launch_environment("studio-orbit", paths, "/out.json", 10, 3, {"IKKOKU_PERF_INPUT_HZ": "60"})
                maker = perf_trace.launch_environment("maker-slider", paths, "/out.json", 10, 3, {})
                native = perf_trace.launch_environment("studio-native", paths, "/out.json", 10, 3, {})
            self.assertNotIn("IKKOKU_AUTOCAPTURE", studio)
            self.assertEqual(studio["IKKOKU_SOURCE_SCENE"], paths["IKKOKU_STUDIO_SCENARIO_SCENE"])
            self.assertEqual((studio["IKKOKU_PERF_WORKLOAD"], studio["IKKOKU_PERF_SECONDS"], studio["IKKOKU_PERF_WARMUP_SECONDS"],
                              studio["IKKOKU_PERF_INPUT_HZ"]), ("studio-orbit", "10", "3", "60"))
            self.assertEqual(maker["IKKOKU_SOURCE_CARD"], paths["IKKOKU_MAKER_SCENARIO_CARD"])
            self.assertNotIn("IKKOKU_SOURCE_SCENE", maker)
            self.assertNotIn("IKKOKU_SOURCE_SCENE", native)
            self.assertNotIn("IKKOKU_SOURCE_CARD", native)
            del paths["IKKOKU_STUDIO_SCENARIO_SCENE"]
            with self.assertRaises(SystemExit):
                perf_trace.launch_environment("studio-idle", paths, "/out.json", 10, 3, {})
            paths["IKKOKU_STUDIO_SCENARIO_SCENE"] = os.path.join(folder, "missing")
            with self.assertRaises(SystemExit):
                perf_trace.launch_environment("studio-idle", paths, "/out.json", 10, 3, {})

    def test_row_reports_the_build_and_phase_percentiles(self):
        # A schema 2 report: no draw thread, load or render-thread fields.
        line = perf_trace.row("release/studio-idle", report(app="Debug", engine="Release"))
        self.assertTrue(line.startswith("| release/studio-idle | Debug/Release | main | - | 118.4 | 3 | -/- | 1.50/2.50 | 4.00/5.00 | 400 | 200 | 150 | 0 | 50 | 0 |"), line)
        self.assertIn("studioTick 1.50/2.50 ×30/s", line)
        camera = report()
        camera["summary"]["phases"]["studioCameraRefresh"] = dict(camera["summary"]["phases"]["studioTick"], perSecond=118)
        self.assertIn("studioCameraRefresh 1.50/2.50 ×118/s", perf_trace.row("after/studio-orbit", camera))
        self.assertTrue(line.endswith("| 512 |"))

    def test_row_reports_the_busy_main_thread_case_and_the_render_thread(self):
        # Schema 3: the acceptance metric of R7 phase 2, item 2 is the
        # presented-interval p95 while the main thread carries a load.
        loaded = report()
        loaded["configuration"] = {"mainLoadMs": 20, "mainLoadHz": 30}
        loaded["summary"].update(recordedSeconds=10, hitches=12, drawThread="render",
                                 presentedIntervalMs={"p50": 8.33, "p95": 8.34},
                                 renderThread={"callbacks": 1200, "drawMsPerSecond": 210})
        loaded["summary"]["mainThread"].update(drawMsPerSecond=0, loadMsPerSecond=600, otherMsPerSecond=20)
        line = perf_trace.row("after/studio-native+load20", loaded)
        self.assertTrue(line.startswith("| after/studio-native+load20 | Release/Release | render | 20 ms × 30/s | 118.4 | 12 (1.2/s) | 8.33/8.34 |"), line)
        self.assertIn("| 400 | 0 | 150 | 600 | 20 | 210 |", line)
        self.assertEqual(perf_trace.HEADER.count("|"), line.count("|"))

    def test_main_load_sets_the_launch_variables_and_names_the_report(self):
        launches = []

        def launch(argv, env, **kwargs):
            launches.append(env)
            shown = report()
            shown["summary"].update(displayLinkCallbacks=1200, droppedDrawables=0)
            with open(env["IKKOKU_PERF_TRACE"], "w") as handle:
                json.dump(shown, handle)
            return subprocess.CompletedProcess(argv, 0)

        with tempfile.TemporaryDirectory() as folder:
            fixture = os.path.join(folder, "fixture")
            open(fixture, "w").close()
            environment = os.path.join(folder, "environment.json")
            with open(environment, "w") as handle:
                json.dump({"IKKOKU_SOURCE_AVATAR": fixture, "IKKOKU_MAKER_LIBRARY": fixture}, handle)
            args = argparse.Namespace(environment=environment, workloads="studio-native", out=os.path.join(folder, "out"),
                                      repeat=1, retries=2, seconds=10, warmup=3, startup_timeout=180, set=None,
                                      app="/apps/Ikkoku", xctrace=None, wrap=None, main_load_ms=20, main_load_hz=60)
            with mock.patch.object(perf_trace.subprocess, "run", side_effect=launch), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(perf_trace.run(args), 0)
            self.assertTrue(os.path.exists(os.path.join(folder, "out", "studio-native+load20.json")))
        self.assertEqual((launches[0]["IKKOKU_PERF_MAIN_LOAD_MS"], launches[0]["IKKOKU_PERF_MAIN_LOAD_HZ"]), ("20", "60"))

    def test_ring_line_reports_the_frame_ring_palettes_only_when_recorded(self):
        report = {"summary": {"frameRing": {"skinPalettesPerDraw": {"count": 600, "p50": 6},
                                            "paletteKiBPerDraw": {"count": 600, "p50": 87.5},
                                            "paletteBuffersCreated": 0, "drawsWithOverflow": 0}}}
        self.assertEqual(perf_trace.ring_line("after/studio-orbit", report),
                         "[perf] after/studio-orbit: frame ring 6 skin palettes and 87.5 KiB per draw (p50), "
                         "0 palette buffers created, 0 draws with overflow")
        self.assertIsNone(perf_trace.ring_line("base/studio-orbit", {"summary": {}}))
        empty = {"summary": {"frameRing": {"skinPalettesPerDraw": {"count": 0}}}}
        self.assertIsNone(perf_trace.ring_line("after/maker-idle", empty))

    def test_lifecycle_run_checks_render_threads_and_presentation_after_restore(self):
        def lifecycle(before, end, presented=40, minimized=False):
            run = report()
            run["workload"] = "viewport-lifecycle"
            run["details"] = {"lifecycle": {"steps": [{"step": "studio", "seconds": 0.5, "renderThreadsBefore": n} for n in before],
                                            "renderThreadsAtEnd": end, "presentedAfterRestore": presented,
                                            "drawsAfterRestore": presented, "windowMiniaturized": minimized}}
            return run
        self.assertIsNone(perf_trace.lifecycle_problem(lifecycle([1, 1, 1], 1)))
        self.assertIsNone(perf_trace.lifecycle_problem(lifecycle([0, 0], 0)))  # main-thread display link: no render thread
        self.assertIn("1 before, 3 at most, 3 at the end", perf_trace.lifecycle_problem(lifecycle([1, 2, 3], 3)))
        self.assertIn("2 at most", perf_trace.lifecycle_problem(lifecycle([1, 2, 1], 1)))
        self.assertIn("no frame presented", perf_trace.lifecycle_problem(lifecycle([1, 1], 1, presented=0)))
        self.assertIn("still minimized", perf_trace.lifecycle_problem(lifecycle([1, 1], 1, minimized=True)))
        self.assertIsNone(perf_trace.lifecycle_problem(report()))
        # A minimized window drops drawables on purpose: no composited warning.
        hidden = lifecycle([1, 1], 1)
        hidden["summary"].update(displayLinkCallbacks=1200, droppedDrawables=600)
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, "viewport-lifecycle.json"), "w") as handle:
                json.dump(hidden, handle)
            with open(os.path.join(folder, "leaky.json"), "w") as handle:
                json.dump(lifecycle([1, 2], 2), handle)
            with contextlib.redirect_stdout(output):
                perf_trace.summarize([folder])
        text = output.getvalue()
        self.assertNotIn("not on screen", text)
        self.assertIn("render threads before each step [1, 1], at the end 1", text)
        self.assertIn("WARNING %s/leaky: render threads 1 before, 2 at most, 2 at the end" % os.path.basename(folder), text)

    def test_attribution_row_reports_events_and_view_bodies_per_input(self):
        orbit = report()
        orbit["summary"].update(recordedSeconds=10, inputCalls={"mouseDown": 1, "mouseDragged": 1199},
                                events={"studioCameraChange": {"count": 1199, "perSecond": 119.9}},
                                viewBodies={"studioToolbar": {"count": 12, "perSecond": 1.2},
                                            "studioWindow": {"count": 600, "perSecond": 60}})
        line = perf_trace.attribution_row("after/studio-orbit", orbit)
        self.assertEqual(line, "| after/studio-orbit | 120 | studioCameraChange 120/s (1.00/input) | "
                               "studioWindow 60/s (0.50/input), studioToolbar 1/s (0.01/input) |")
        idle = report()
        idle["summary"].update(recordedSeconds=10, viewBodies={"v%d" % i: {"count": i, "perSecond": i / 10} for i in range(1, 9)})
        line = perf_trace.attribution_row("after/studio-idle", idle, top=2)
        self.assertTrue(line.startswith("| after/studio-idle | 0 | - | v8 1/s, v7 1/s, +6 more |"), line)
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, "studio-orbit.json"), "w") as handle:
                json.dump(orbit, handle)
            with open(os.path.join(folder, "old.json"), "w") as handle:
                json.dump(report(), handle)  # a schema 1 report has neither block
            with contextlib.redirect_stdout(output):
                perf_trace.summarize([folder])
        text = output.getvalue()
        self.assertIn("| report | input events/s | model events | view bodies (most evaluated first) |", text)
        self.assertEqual(text.count("studioCameraChange"), 1)

    def test_summary_flags_runs_whose_window_was_not_composited(self):
        hidden = report()
        hidden["summary"].update(displayLinkCallbacks=1200, droppedDrawables=1100)
        saturated = report()
        saturated["summary"].update(displayLinkCallbacks=40, droppedDrawables=38)
        saturated["summary"]["mainThread"]["busyMsPerSecond"] = 999
        busy_hidden = report()
        busy_hidden["summary"].update(displayLinkCallbacks=265, droppedDrawables=213)
        busy_hidden["summary"]["mainThread"]["busyMsPerSecond"] = 999
        busy = report()
        busy["summary"].update(displayLinkCallbacks=432, droppedDrawables=49)
        busy["summary"]["mainThread"]["busyMsPerSecond"] = 998
        self.assertIn("1100 of 1200 drawables", perf_trace.uncomposited(hidden))
        self.assertIn("213 of 265 drawables", perf_trace.uncomposited(busy_hidden))
        self.assertIsNone(perf_trace.uncomposited(saturated))
        self.assertIsNone(perf_trace.uncomposited(busy))
        self.assertIsNone(perf_trace.uncomposited(report()))

    def test_run_repeats_a_launch_whose_window_was_not_composited(self):
        hidden = report()
        hidden["summary"].update(displayLinkCallbacks=1200, droppedDrawables=1200)
        shown = report()
        shown["summary"].update(displayLinkCallbacks=1200, droppedDrawables=0)
        launches = []

        def launch(argv, env, **kwargs):
            launches.append(argv)
            with open(env["IKKOKU_PERF_TRACE"], "w") as handle:
                json.dump(hidden if len(launches) == 1 else shown, handle)
            return subprocess.CompletedProcess(argv, 0)

        with tempfile.TemporaryDirectory() as folder:
            fixture = os.path.join(folder, "fixture")
            open(fixture, "w").close()
            environment = os.path.join(folder, "environment.json")
            with open(environment, "w") as handle:
                json.dump({"IKKOKU_SOURCE_AVATAR": fixture, "IKKOKU_MAKER_LIBRARY": fixture}, handle)
            args = argparse.Namespace(environment=environment, workloads="studio-native", out=os.path.join(folder, "out"),
                                      repeat=1, retries=2, seconds=10, warmup=3, startup_timeout=180, set=None,
                                      app="/apps/Ikkoku", xctrace=None, wrap=None)
            with mock.patch.object(perf_trace.subprocess, "run", side_effect=launch), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(perf_trace.run(args), 0)
        self.assertEqual(len(launches), 2)

    def test_summary_flags_input_that_an_idle_workload_did_not_send(self):
        idle = report()
        idle["workload"] = "studio-idle"
        idle["summary"]["inputCalls"] = {"mouseMoved": 12}
        orbit = report()
        orbit["workload"] = "studio-orbit"
        orbit["summary"]["inputCalls"] = {"mouseDragged": 900}
        self.assertIn("12 input calls", perf_trace.stray_input(idle))
        self.assertIsNone(perf_trace.stray_input(orbit))
        idle["summary"]["inputCalls"] = {}
        self.assertIsNone(perf_trace.stray_input(idle))

    def test_run_rejects_a_stale_report_when_launch_writes_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture = os.path.join(folder, "fixture")
            open(fixture, "w").close()
            environment = os.path.join(folder, "environment.json")
            with open(environment, "w") as handle:
                json.dump({"IKKOKU_SOURCE_AVATAR": fixture, "IKKOKU_MAKER_LIBRARY": fixture}, handle)
            output = os.path.join(folder, "out")
            os.mkdir(output)
            stale = os.path.join(output, "studio-native.json")
            with open(stale, "w") as handle:
                json.dump(report(), handle)
            args = argparse.Namespace(environment=environment, workloads="studio-native", out=output,
                                      repeat=1, retries=2, seconds=10, warmup=3, startup_timeout=180, set=None,
                                      app="/apps/Ikkoku", xctrace=None, wrap=None)
            with mock.patch.object(perf_trace.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(perf_trace.run(args), 1)
            self.assertFalse(os.path.exists(stale))

    def test_profile_resolves_refs_and_charges_focus_callees(self):
        args = argparse.Namespace(trace="unused.trace", whole=True, thread="Main Thread", top=10, binary="Ikkoku", focus="^hot$", skip_toc=True)
        output = io.StringIO()
        with mock.patch.object(perf_trace, "export_table", return_value=PROFILE.encode()), contextlib.redirect_stdout(output):
            self.assertEqual(perf_trace.profile(args), 0)
        text = output.getvalue()
        # Both Main Thread samples (2 ms + a 1 ms ref'd repeat); the worker is
        # counted per thread but not selected.
        self.assertIn("selected samples: 3.0 ms", text)
        self.assertIn("1.0  Worker", text)
        self.assertIn("3.0 ms 100.0%  libswiftCore.dylib", text)
        inclusive = text.split("inclusive time by function")[1].split("direct callees")[0]
        self.assertIn("hot", inclusive)
        self.assertNotIn("leaf", inclusive)  # outside the --binary filter
        callees = text.split("direct callees")[1]
        self.assertIn("3.0 ms 100.0%  callee", callees)

    def test_guard_stops_a_launch_that_outlives_its_timeout(self):
        args = argparse.Namespace(timeout=1, argv=[sys.executable, "-c", "import signal, time; signal.signal(signal.SIGINT, signal.SIG_DFL); time.sleep(30)"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(perf_trace.guarded_exec(args), 124)
        args = argparse.Namespace(timeout=30, argv=[sys.executable, "-c", "raise SystemExit(3)"])
        self.assertEqual(perf_trace.guarded_exec(args), 3)

    def test_xctrace_attaches_to_the_launched_process_instead_of_launching_by_bundle(self):
        launched = []

        class FakeProcess:
            def __init__(self, argv):
                self.argv = argv
                self.pid = 4242 if not launched else 99
                self.returncode = 0
                launched.append(self)

            def wait(self, timeout=None):
                return 0

        args = argparse.Namespace(timeout=30, argv=["/apps/Ikkoku.app/Contents/MacOS/Ikkoku"], xctrace="Time Profiler", trace="/out/w.trace")
        with mock.patch.object(perf_trace.subprocess, "Popen", FakeProcess):
            self.assertEqual(perf_trace.guarded_exec(args), 0)
        app, recorder = launched
        self.assertEqual(app.argv, ["/apps/Ikkoku.app/Contents/MacOS/Ikkoku"])
        self.assertIn("--attach", recorder.argv)
        self.assertEqual(recorder.argv[recorder.argv.index("--attach") + 1], "4242")
        self.assertNotIn("--launch", recorder.argv)


if __name__ == "__main__":
    unittest.main()
