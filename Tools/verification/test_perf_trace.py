"""Self-tests for perf_trace.py: launch environments, report rows, the
xctrace export reader and the launch guard. No app, trace or fixture is
needed; xctrace exports are synthetic XML in the shape `xctrace export` writes.
"""

import argparse
import contextlib
import io
import os
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


class PerfTraceTests(unittest.TestCase):
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
        line = perf_trace.row("release/studio-idle", report(app="Debug", engine="Release"))
        self.assertTrue(line.startswith("| release/studio-idle | Debug/Release | 118.4 | 3 | 1.50/2.50 | 4.00/5.00 | 400 | 200 | 150 | 50 |"))
        self.assertIn("studioTick 1.50/2.50 ×30/s", line)
        self.assertTrue(line.endswith("| 512 |"))

    def test_profile_resolves_refs_and_charges_focus_callees(self):
        args = argparse.Namespace(trace="unused.trace", whole=True, thread="Main Thread", top=10, binary="Ikkoku", focus="^hot$")
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


if __name__ == "__main__":
    unittest.main()
