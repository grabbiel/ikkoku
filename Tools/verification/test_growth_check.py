"""Self-tests for growth_check.py (#440): the heap -s reader with the focus
ring row, the frozen bar, the slope note, the flags, the timed action count,
the parking protocol against a fake app, and the snapshot attempts. No app
is needed; the heap output is synthetic text in the shape `heap -s` writes."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import growth_check as check  # noqa: E402

HEAP = """Process 1234: 7 zones

All zones: 252836 nodes (42417735 bytes)

   COUNT      BYTES       AVG   CLASS_NAME                                        TYPE    BINARY
   =====      =====       ===   ==========                                        ====    ======

    5396     261024      48.4   __NSMallocBlock__                                 ObjC    libsystem_blocks.dylib
    4824     231216      47.9   __NSExactBlockVariable__                          ObjC    libsystem_blocks.dylib
    6230     199360      32.0   NSKeyValueDependency                              ObjC    AppKit
    4773     152736      32.0   NSKeyValueDependencyContext                       ObjC    AppKit
      23      11776     512.0   _FocusRingView                                    Swift   SwiftUI
      23       1472      64.0   SwiftUI.FocusEffectView                           Swift   SwiftUI
    4120     131840      32.0   SwiftUI.(_AnyHashableBox in $23c934774)<Foundation.UUID>  Swift   SwiftUI
     146       9344      64.0   NSKeyValueDependencyInfo                          ObjC    AppKit
     258       8256      32.0   SwiftUI.(_AnyHashableBox in $23c934774)<SwiftUI.UniqueID>  Swift   SwiftUI
       1         48      48.0   _NSAutomaticFocusRingState                        ObjC    AppKit
"""

FOUR = ("NSKeyValueDependency", "NSKeyValueDependencyContext", "__NSMallocBlock__", "__NSExactBlockVariable__")


def counts(value, **extra):
    out = {name: value for name, _ in check.TYPES}
    out.update({name: value for name in check.ALWAYS_BOXES})
    out.update(extra)
    return out


class ParseHeapTests(unittest.TestCase):
    def test_reads_the_types_the_focus_ring_and_every_box(self):
        self.assertEqual(check.parse_heap(HEAP), {
            "NSKeyValueDependency": 6230, "NSKeyValueDependencyContext": 4773, "__NSMallocBlock__": 5396,
            "__NSExactBlockVariable__": 4824, "_FocusRingView": 23, "AnyHashableBox<Foundation.UUID>": 4120,
            "AnyHashableBox<Swift.Int>": 0, "AnyHashableBox<SwiftUI.UniqueID>": 258})

    def test_lookalike_classes_are_not_rows(self):
        for name in ("SwiftUI.FocusEffectView", "_NSAutomaticFocusRingState", "NSKeyValueDependencyInfo"):
            self.assertIsNone(check.row_name(name))

    def test_output_without_a_class_table_is_unreadable(self):
        self.assertIsNone(check.parse_heap("heap: could not enumerate zone\n"))
        self.assertIsNone(check.parse_classes("heap: could not enumerate zone\n"))


class JudgeTests(unittest.TestCase):
    def test_the_bar_is_frozen(self):
        self.assertEqual((check.PER_ACTION, check.PARKED_ALLOWANCE, check.TIMED_ALLOWANCE, check.MIN_ACTIONS),
                         (1, 32, 64, 40))
        self.assertEqual((check.SLOPE_NOTE, check.CHECK_VERSION), (0.25, "3"))
        self.assertEqual(check.SLOPE_ROWS, FOUR + ("_FocusRingView",))

    def test_parked_bar_is_one_per_action_plus_32(self):
        verdict, rows = check.judge(counts(800), counts(800 + 112), 80, check.PARKED_ALLOWANCE)
        self.assertEqual((verdict, rows[0]["bar"]), ("pass", 112))
        self.assertEqual(check.judge(counts(800), counts(800 + 113), 80, check.PARKED_ALLOWANCE)[0], "fail")

    def test_two_per_action_fails(self):
        verdict, rows = check.judge(counts(800), counts(800 + 160), 80, check.PARKED_ALLOWANCE)
        self.assertEqual(verdict, "fail")
        self.assertEqual(rows[0]["perAction"], 2.0)

    def test_the_probe_four_per_action_fails(self):
        # P1: 8 buttons shown every other action.
        self.assertEqual(check.judge(counts(800), counts(800 + 4 * 80), 80, check.PARKED_ALLOWANCE)[0], "fail")

    def test_timed_allowance_is_v22s(self):
        # #410's unfixed workspace: 41 per load fails; one scene's rows pass.
        self.assertEqual(check.judge(counts(800), counts(800 + 41 * 53), 53, check.TIMED_ALLOWANCE)[0], "fail")
        self.assertEqual(check.judge(counts(844), counts(800), 40, check.TIMED_ALLOWANCE)[0], "pass")
        self.assertEqual(check.judge(counts(800), counts(844 + 40), 40, check.TIMED_ALLOWANCE)[0], "pass")

    def test_the_focus_ring_row_is_judged(self):
        verdict, rows = check.judge(counts(23), counts(23, _FocusRingView=23 + 200), 80, check.PARKED_ALLOWANCE)
        self.assertEqual(verdict, "fail")
        self.assertEqual([row["type"] for row in rows if not row["ok"]], ["_FocusRingView"])

    def test_a_box_only_in_one_snapshot_is_judged(self):
        late = counts(800, **{"AnyHashableBox<Some.NewID>": 300})
        verdict, rows = check.judge(counts(800), late, 80, check.PARKED_ALLOWANCE)
        self.assertEqual(verdict, "fail")
        row = [row for row in rows if row["type"] == "AnyHashableBox<Some.NewID>"][0]
        self.assertEqual((row["early"], row["growth"], row["ok"]), (0, 300, False))

    def test_too_few_actions_or_an_unread_snapshot_is_invalid(self):
        self.assertEqual(check.judge(counts(800), counts(800), 39, 32)[0], "invalid")
        self.assertEqual(check.judge(None, counts(800), 80, 32)[0], "invalid")
        self.assertEqual(check.judge(counts(800), None, 80, 32)[0], "invalid")


class SlopeNoteTests(unittest.TestCase):
    def test_a_pass_at_half_per_action_is_noted(self):
        # A section leaking one control per show, shown every other action.
        verdict, rows = check.judge(counts(800), counts(800, NSKeyValueDependency=840), 80, 32)
        self.assertEqual(verdict, "pass")
        self.assertEqual(check.slope_note(verdict, rows),
                         {"type": "NSKeyValueDependency", "perAction": 0.5, "rows": ["NSKeyValueDependency"]})

    def test_the_steepest_of_several_is_named(self):
        late = counts(800, NSKeyValueDependency=830, __NSMallocBlock__=860, _FocusRingView=820)
        verdict, rows = check.judge(counts(800), late, 80, 32)
        note = check.slope_note(verdict, rows)
        self.assertEqual((note["type"], note["perAction"]), ("__NSMallocBlock__", 0.75))
        self.assertEqual(note["rows"], ["NSKeyValueDependency", "_FocusRingView", "__NSMallocBlock__"])

    def test_below_the_note_or_a_fail_has_none(self):
        verdict, rows = check.judge(counts(800), counts(819), 80, 32)
        self.assertEqual((verdict, check.slope_note(verdict, rows)), ("pass", None))
        verdict, rows = check.judge(counts(800), counts(1000), 80, 32)
        self.assertEqual((verdict, check.slope_note(verdict, rows)), ("fail", None))

    def test_boxes_do_not_count_for_the_note(self):
        late = counts(800, **{"AnyHashableBox<Swift.Int>": 860})
        verdict, rows = check.judge(counts(800), late, 80, 32)
        self.assertEqual((verdict, check.slope_note(verdict, rows)), ("pass", None))


class FlagTests(unittest.TestCase):
    def test_other_classes_growing_by_the_bar_are_flagged_largest_first(self):
        early = {"NSKeyValueDependency": 800, "Some.Container": 100, "Other.Cache": 10, "Steady": 500}
        late = {"NSKeyValueDependency": 4000, "Some.Container": 100 + 112, "Other.Cache": 10 + 300, "Steady": 520}
        out = check.flags(early, late, 80, 32)
        self.assertEqual([(row["type"], row["growth"], row["bar"]) for row in out],
                         [("Other.Cache", 300, 112), ("Some.Container", 112, 112)])

    def test_no_flags_without_a_valid_window(self):
        self.assertEqual(check.flags(None, {"A": 9999}, 80, 32), [])
        self.assertEqual(check.flags({"A": 0}, {"A": 9999}, 39, 32), [])


class CountActionsTests(unittest.TestCase):
    def test_counts_measured_actions_started_between_the_snapshots(self):
        actions = []
        for at in range(5, 65):
            actions.append({"name": "new scene", "measured": False, "startSeconds": at - 3.5 - 0.4})
            actions.append({"name": "load", "measured": True, "startSeconds": at - 3.5})
        report = {"startupSeconds": {"recordingBegin": 3.5}, "details": {"actions": actions}}
        self.assertEqual(check.count_actions(report, 8, 56), 48)
        self.assertEqual(check.count_actions(report, 15.0, 56.0), 41)


class FakeApp:
    """The app's side of the protocol: at each cycle start it reads the park
    file; `park n` (n newer than the last) parks it: it writes `.parked` and
    waits for `resume n`."""

    def __init__(self, park, cycle=4, measured_per_step=1, broken=False):
        self.park, self.cycle, self.broken = park, cycle, broken
        self.index, self.measured, self.last, self.parked_on = 0, 0, 0, None
        self.per_step = measured_per_step

    def step(self):
        with open(self.park) as handle:
            text = handle.read().split()
        if self.parked_on is not None:
            if text == ["resume", str(self.parked_on)]:
                self.last, self.parked_on = self.parked_on, None
            return
        if self.index % self.cycle == 0 and len(text) == 2 and text[0] == "park" and int(text[1]) > self.last:
            if not self.broken:
                self.parked_on = int(text[1])
                with open(self.park + ".parked", "w") as handle:
                    handle.write("parked %d %d %d %d\n" % (self.parked_on, self.measured, self.index, self.cycle))
                return
        self.index += 1
        self.measured += self.per_step


class ParkingTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.park = os.path.join(self.dir.name, "park")
        check.write_text(self.park, "run 0\n")
        self.now = [0.0]

    def tearDown(self):
        self.dir.cleanup()

    def wait(self, app, n, alive=lambda: True):
        def sleep(seconds):
            self.now[0] += seconds
            app.step()
        return check.wait_parked(self.park, n, lambda: self.now[0], sleep, alive)

    def test_two_parks_count_the_measured_actions_between_them(self):
        app = FakeApp(self.park)
        for _ in range(6):
            app.step()
        check.request_park(self.park, 1)
        first, waited = self.wait(app, 1)
        self.assertEqual((first["park"], first["index"] % first["cycle"]), (1, 0))
        self.assertLess(waited, 1.0)
        app.step()
        self.assertEqual(app.index, first["index"], "the app stays parked until resumed")
        check.resume(self.park, 1)
        for _ in range(83):
            app.step()
        check.request_park(self.park, 2)
        second, _ = self.wait(app, 2)
        check.resume(self.park, 2)
        self.assertTrue(check.parks_valid(first, second))
        self.assertEqual(second["measured"] - first["measured"], 84)
        app.step()
        self.assertIsNone(app.parked_on)
        # Nothing was deleted: the park file holds the last resume, `.parked` the last park.
        with open(self.park) as handle:
            self.assertEqual(handle.read(), "resume 2\n")
        self.assertEqual(check.read_parked(self.park, 2), second)

    def test_an_old_parked_line_is_not_the_new_park(self):
        app = FakeApp(self.park)
        check.request_park(self.park, 1)
        self.wait(app, 1)
        check.resume(self.park, 1)
        self.assertIsNone(check.read_parked(self.park, 2))

    def test_a_park_never_reached_times_out(self):
        app = FakeApp(self.park, broken=True)
        check.request_park(self.park, 1)
        parked, waited = self.wait(app, 1)
        self.assertIsNone(parked)
        self.assertGreaterEqual(waited, check.PARK_TIMEOUT)

    def test_a_gone_app_stops_the_wait(self):
        app = FakeApp(self.park, broken=True)
        check.request_park(self.park, 1)
        parked, waited = self.wait(app, 1, alive=lambda: False)
        self.assertEqual((parked, waited), (None, 0.0))

    def test_a_partial_or_foreign_parked_file_reads_as_none(self):
        for text in ("", "parked 1", "parked 1 2 3", "parked x 1 2 3\n", "resume 1\n"):
            check.write_text(self.park + ".parked", text)
            self.assertIsNone(check.read_parked(self.park, 1))

    def test_parks_valid_needs_step_zero_of_one_cycle(self):
        good = {"park": 1, "measured": 10, "index": 12, "cycle": 4}
        self.assertTrue(check.parks_valid(good, dict(good, park=2, measured=90, index=96)))
        self.assertFalse(check.parks_valid(good, None))
        self.assertFalse(check.parks_valid(good, dict(good, park=2, measured=90, index=97)))
        self.assertFalse(check.parks_valid(good, dict(good, park=2, measured=90, index=96, cycle=6)))
        self.assertFalse(check.parks_valid(good, dict(good, park=2, measured=5, index=96)))
        self.assertFalse(check.parks_valid(dict(good, cycle=0), dict(good, cycle=0)))


class SnapshotTests(unittest.TestCase):
    def take(self, exits):
        now, waits, calls = [10.0], [], []

        def run_heap(pid):
            calls.append(pid)
            now[0] += 3.0
            code = exits[len(calls) - 1]
            return code, HEAP if code == 0 else "heap: zone enumeration failed"

        def wait(seconds):
            waits.append(seconds)
            now[0] += seconds
        attempts, text = check.snapshot(42, lambda: now[0], run_heap, wait)
        return attempts, text, waits, calls

    def test_the_schedule_is_frozen(self):
        self.assertEqual((check.EARLY_SECONDS, check.LATE_SECONDS, check.RETRY_AFTER), (12.0, 56.0, 2.0))
        self.assertEqual((check.SNAPSHOT_ATTEMPTS, check.PARK_TIMEOUT), (4, 20.0))

    def test_a_good_snapshot_is_taken_once(self):
        attempts, text, waits, calls = self.take([0])
        self.assertEqual(attempts, [{"seconds": 10.0, "exit": 0}])
        self.assertEqual((text, waits, calls), (HEAP, [], [42]))

    def test_a_fourth_attempt_can_succeed_and_a_fourth_failure_is_final(self):
        attempts, text, waits, _ = self.take([255, 255, 255, 0])
        self.assertEqual([a["seconds"] for a in attempts], [10.0, 15.0, 20.0, 25.0])
        self.assertEqual((text, waits), (HEAP, [2.0, 2.0, 2.0]))
        attempts, text, _, calls = self.take([255, 255, 255, 255])
        self.assertEqual((len(calls), check.parse_heap(text)), (4, None))


if __name__ == "__main__":
    unittest.main()
