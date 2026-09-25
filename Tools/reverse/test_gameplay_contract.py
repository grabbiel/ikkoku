import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from analysis.gameplay_contract import Oracle, PERIODS, WEEKS, TIME_ZONES, fixtures


class GameplayContractTests(unittest.TestCase):
    def test_original_enum_and_default_state(self):
        self.assertEqual((len(PERIODS), len(WEEKS)), (12, 7))
        self.assertEqual(TIME_ZONES, (0, 0, 0, 0, 0, 1, 1, 1, 2, 3, 3, 4))
        self.assertEqual((Oracle().week, Oracle().period), (6, 0))
        self.assertEqual(Oracle(opening=False).period, 11)

    def test_direct_backward_changes_age_but_next_wrap_does_not(self):
        state = Oracle(opening=False, week=6)
        self.assertEqual(state.apply(dict(op="nextPeriod")), [])
        self.assertEqual((state.period, state.week), (0, 6))
        state.apply(dict(op="changePeriod", value=11))
        self.assertEqual(state.apply(dict(op="changePeriod", value=0)), [1])
        self.assertEqual(state.week, 0)

    def test_same_weekday_and_full_week_multiples_age_seven(self):
        for plus in (0, 7, 14):
            state = Oracle(week=2)
            self.assertEqual(state.apply(dict(op="nextWeek", value=plus)), [7])
        self.assertEqual(Oracle(week=4).apply(dict(op="changeWeek", value=4)), [7])

    def test_night_menu_performs_the_day_advance(self):
        state = Oracle(opening=False)
        self.assertEqual(state.apply(dict(op="completeNightMenu")), [1])
        self.assertEqual((state.week, state.period), (0, 0))

    def test_night_reload_and_scene_exit_do_not_age(self):
        state = Oracle(opening=False)
        self.assertEqual(state.apply(dict(op="reloadNightMenuWeek", value=3)), [])
        self.assertEqual(state.apply(dict(op="completeNightMenu", returningToTitle=True)), [])
        self.assertEqual((state.week, state.period), (3, 11))

    def test_map_timer_overshoots_and_display_finishes_at_one(self):
        state = Oracle(week=0)
        state.apply(dict(op="changePeriod", value=5))
        state.apply(dict(op="beginMapMove"))
        state.apply(dict(op="tickMapMove", deltaTime=501.5, cursorLocked=True, gameRegulated=False))
        self.assertGreater(state.time_pass, 1)
        state.apply(dict(op="finishMapMove"))
        self.assertEqual((state.timer, state.time_pass), (501.5, 1))

    def test_clock_visibility_and_time_regulation_are_distinct(self):
        state = Oracle(week=0)
        state.apply(dict(op="changePeriod", value=5))
        state.apply(dict(op="beginMapMove"))
        state.apply(dict(op="tickMapMove", deltaTime=4, cursorLocked=True, gameRegulated=False, advProcessing=True))
        self.assertEqual(state.timer, 4)
        self.assertFalse(state.visible)

    def test_invalid_negative_source_remainder_rejected_without_mutation(self):
        state = Oracle(week=0)
        before = state.snapshot()
        with self.assertRaisesRegex(ValueError, "invalidWeekAdvance"):
            state.apply(dict(op="nextWeek", value=-1))
        self.assertEqual(state.snapshot(), before)

    def test_fixture_matrix_covers_every_period_pair_and_week_pair(self):
        data = fixtures()
        self.assertEqual(len(data["cases"]), 264)
        names = {case["name"] for case in data["cases"]}
        for first in range(12):
            for second in range(12):
                self.assertIn(f"period-{first}-{second}", names)
        for first in range(7):
            for second in range(7):
                self.assertIn(f"weekday-{first}-{second}", names)


@unittest.skipUnless(os.environ.get("IKKOKU_INSPECTOR"), "set IKKOKU_INSPECTOR to exercise the built native CLI")
class GameplayCLIIntegerTests(unittest.TestCase):
    def invoke(self, value, op="nextWeek", initial_week=None):
        command = '{"op":' + json.dumps(op) + ',"value":' + value + '}'
        initial = '' if initial_week is None else ',"initial":{"week":' + initial_week + '}'
        source = '{"cases":[{"name":"integer-regression"' + initial + ',"steps":[{"command":' + command + '}]}]}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.json"
            path.write_text(source)
            return subprocess.run([os.environ["IKKOKU_INSPECTOR"], "gameplay-trace", str(path)],
                                  capture_output=True, text=True, timeout=10)

    def test_fractions_hidden_by_binary64_rounding_are_rejected(self):
        for value in ("1.00000000000000001", "2147483647.0000000001"):
            with self.subTest(value=value):
                result = self.invoke(value)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("exact Int32", result.stderr)

    def test_int32_boundaries_and_integral_decimal_forms(self):
        for value in ("-2147483648", "2147483647", "1.0", "1e0"):
            with self.subTest(value=value):
                result = self.invoke(value)
                self.assertEqual(result.returncode, 0, result.stderr)
        for value in ("-2147483649", "2147483648"):
            with self.subTest(value=value):
                self.assertEqual(self.invoke(value).returncode, 1)

    def test_timer_fractions_keep_floating_point_semantics(self):
        result = self.invoke("0.25", op="addTimer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["cases"][0]["steps"][0]["state"]["timer"], 125)

    def test_initial_week_uses_decimal_integer_validation(self):
        result = self.invoke("1", initial_week="1.00000000000000001")
        self.assertEqual(result.returncode, 1)
        self.assertIn("initial weekday", result.stderr)

    def test_source_period_argument_rejects_hidden_fraction(self):
        result = self.invoke("5.00000000000000001", op="changePeriod")
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
