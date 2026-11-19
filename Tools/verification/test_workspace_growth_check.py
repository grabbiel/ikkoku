"""Self-tests for workspace_growth_check.py (#410): the heap -s reader, the
load count, the frozen bar, the snapshot attempts (v2.2: up to 4), and v2.1's box rows and flags. No app is needed; the heap output is synthetic
text in the shape `heap -s` writes."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import workspace_growth_check as check  # noqa: E402

HEAP = """Process 1234: 7 zones

All zones: 252836 nodes (42417735 bytes)

   COUNT      BYTES       AVG   CLASS_NAME                                        TYPE    BINARY
   =====      =====       ===   ==========                                        ====    ======

    5396     261024      48.4   __NSMallocBlock__                                 ObjC    libsystem_blocks.dylib
    4824     231216      47.9   __NSExactBlockVariable__                          ObjC    libsystem_blocks.dylib
    6230     199360      32.0   NSKeyValueDependency                              ObjC    AppKit
    4773     152736      32.0   NSKeyValueDependencyContext                       ObjC    AppKit
    4120     131840      32.0   SwiftUI.(_AnyHashableBox in $23c934774)<Foundation.UUID>  Swift   SwiftUI
     146       9344      64.0   NSKeyValueDependencyInfo                          ObjC    AppKit
     258       8256      32.0   SwiftUI.(_AnyHashableBox in $23c934774)<SwiftUI.UniqueID>  Swift   SwiftUI
       9        288      32.0   SwiftUI.(_AnyHashableBox in $23c934774)<Swift.Optional<Foundation.UUID>>  Swift   SwiftUI
      50       3200      64.0   NSKeyValueDependencyInfo._classInfo (struct NSDPClassInfo)  C       AppKit
      15        240      16.0   NSKeyValueObservation.Helper.lock (malloc)                Foundation
"""


def report(loads_at, begin=3.5):
    actions = []
    for at in loads_at:
        actions.append({"name": "new scene", "startSeconds": at - begin - 0.4})
        actions.append({"name": "load", "startSeconds": at - begin})
    return {"startupSeconds": {"recordingBegin": begin}, "details": {"actions": actions}}


class ParseHeapTests(unittest.TestCase):
    def test_reads_the_types_and_every_box_exactly(self):
        counts = check.parse_heap(HEAP)
        self.assertEqual(counts, {"NSKeyValueDependency": 6230, "NSKeyValueDependencyContext": 4773,
                                  "__NSMallocBlock__": 5396, "__NSExactBlockVariable__": 4824,
                                  "AnyHashableBox<Foundation.UUID>": 4120, "AnyHashableBox<Swift.Int>": 0,
                                  "AnyHashableBox<SwiftUI.UniqueID>": 258,
                                  "AnyHashableBox<Swift.Optional<Foundation.UUID>>": 9})

    def test_missing_type_counts_zero(self):
        text = "\n".join(line for line in HEAP.splitlines() if "Foundation.UUID>  Swift" not in line)
        self.assertEqual(check.parse_heap(text)["AnyHashableBox<Foundation.UUID>"], 0)

    def test_a_box_from_another_build_counts_in_the_same_row(self):
        text = HEAP + "     700      22400      32.0   SwiftUI.(_AnyHashableBox in $1d0f00000)<Swift.Int>  Swift   SwiftUI\n"
        self.assertEqual(check.parse_heap(text)["AnyHashableBox<Swift.Int>"], 700)

    def test_reads_every_class_for_the_flags(self):
        classes = check.parse_classes(HEAP)
        self.assertEqual(classes["NSKeyValueDependencyInfo"], 146)
        self.assertEqual(classes["NSKeyValueDependencyInfo._classInfo (struct NSDPClassInfo)"], 50)
        self.assertIsNone(check.parse_classes("heap: could not enumerate zone\n"))

    def test_output_without_a_class_table_is_unreadable(self):
        self.assertIsNone(check.parse_heap("heap: could not enumerate zone\n"))


class CountLoadsTests(unittest.TestCase):
    def test_counts_loads_started_between_the_snapshots(self):
        # Loads at 5, 6, ..., 64 s after launch; snapshots at 8 and 56 s.
        self.assertEqual(check.count_loads(report([5 + i for i in range(60)]), 8, 56), 48)

    def test_new_scene_actions_are_not_loads(self):
        data = report([10, 11])
        data["details"]["actions"].append({"name": "new scene", "startSeconds": 20})
        self.assertEqual(check.count_loads(data, 0, 100), 2)


class JudgeTests(unittest.TestCase):
    def counts(self, value):
        counts = {name: value for name, _ in check.TYPES}
        counts.update({name: value for name in check.ALWAYS_BOXES})
        return counts

    def test_the_bar_is_frozen(self):
        self.assertEqual((check.PER_LOAD, check.SCENE_ALLOWANCE, check.MIN_LOADS), (1, 64, 40))

    def test_unfixed_growth_fails(self):
        verdict, rows = check.judge(self.counts(800), self.counts(800 + 44 * 48), 48)
        self.assertEqual(verdict, "fail")
        self.assertEqual(rows[0]["bar"], 112)
        self.assertEqual(rows[0]["perLoad"], 44.0)

    def test_one_scenes_rows_pass(self):
        # A late snapshot with the scene shown and an early one in the New
        # Scene gap: one scene's rows, no growth per load.
        self.assertEqual(check.judge(self.counts(800), self.counts(844), 40)[0], "pass")
        self.assertEqual(check.judge(self.counts(844), self.counts(800), 40)[0], "pass")

    def test_a_residual_leak_of_three_per_load_fails_at_forty_loads(self):
        self.assertEqual(check.judge(self.counts(800), self.counts(800 + 3 * 40), 40)[0], "fail")

    def test_one_type_over_the_bar_fails(self):
        late = self.counts(800)
        late["AnyHashableBox<Foundation.UUID>"] = 800 + 105
        self.assertEqual(check.judge(self.counts(800), late, 40)[0], "fail")

    def test_the_growth_moved_to_int_boxes_fails(self):
        # #410 B (gc-b): UUID boxes flat, Int boxes 666 -> 2906 over 56 loads.
        early, late = self.counts(800), self.counts(800)
        early["AnyHashableBox<Swift.Int>"], late["AnyHashableBox<Swift.Int>"] = 666, 2906
        verdict, rows = check.judge(early, late, 56)
        self.assertEqual(verdict, "fail")
        self.assertEqual([row["type"] for row in rows if not row["ok"]], ["AnyHashableBox<Swift.Int>"])

    def test_a_box_only_in_one_snapshot_is_judged(self):
        late = dict(self.counts(800), **{"AnyHashableBox<Some.NewID>": 41 * 48})
        verdict, rows = check.judge(self.counts(800), late, 48)
        self.assertEqual(verdict, "fail")
        row = [row for row in rows if row["type"] == "AnyHashableBox<Some.NewID>"][0]
        self.assertEqual((row["early"], row["growth"], row["ok"]), (0, 41 * 48, False))

    def test_too_few_loads_or_an_unread_snapshot_is_invalid(self):
        self.assertEqual(check.judge(self.counts(800), self.counts(800), 39)[0], "invalid")
        self.assertEqual(check.judge(None, self.counts(800), 48)[0], "invalid")
        self.assertEqual(check.judge(self.counts(800), None, 48)[0], "invalid")


class FlagTests(unittest.TestCase):
    def test_other_classes_growing_by_the_bar_are_flagged_largest_first(self):
        early = {"NSKeyValueDependency": 800, "Some.Container": 100, "Other.Cache": 10, "Steady": 500}
        late = {"NSKeyValueDependency": 4000, "Some.Container": 100 + 112, "Other.Cache": 10 + 300, "Steady": 520}
        out = check.flags(early, late, 48)
        self.assertEqual([(row["type"], row["growth"], row["bar"]) for row in out],
                         [("Other.Cache", 300, 112), ("Some.Container", 112, 112)])

    def test_rows_are_not_flagged_and_a_class_new_in_late_is(self):
        early = {"SwiftUI.(_AnyHashableBox in $23c934774)<Swift.Int>": 0}
        late = {"SwiftUI.(_AnyHashableBox in $23c934774)<Swift.Int>": 5000, "New.Thing": 200}
        self.assertEqual([row["type"] for row in check.flags(early, late, 48)], ["New.Thing"])

    def test_no_flags_without_a_valid_window(self):
        self.assertEqual(check.flags(None, {"A": 9999}, 48), [])
        self.assertEqual(check.flags({"A": 0}, {"A": 9999}, 39), [])


class SnapshotTests(unittest.TestCase):
    def take(self, exits):
        """Runs snapshot() with a fake heap that exits with `exits` in turn
        and a fake clock that the fake heap and wait advance."""
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
        self.assertEqual((check.SNAPSHOT_ATTEMPTS, check.CHECK_VERSION), (4, "2.2"))

    def test_a_good_snapshot_is_taken_once(self):
        attempts, text, waits, calls = self.take([0])
        self.assertEqual(attempts, [{"seconds": 10.0, "exit": 0}])
        self.assertEqual((text, waits, calls), (HEAP, [], [42]))

    def test_a_failed_snapshot_is_retried_once_two_seconds_later(self):
        attempts, text, waits, _ = self.take([255, 0])
        self.assertEqual(attempts, [{"seconds": 10.0, "exit": 255}, {"seconds": 15.0, "exit": 0}])
        self.assertEqual((text, waits), (HEAP, [2.0]))
        self.assertIsNotNone(check.parse_heap(text))

    def test_a_fourth_attempt_can_succeed(self):
        # v2.2: attempts 2 s after each failure, at 10, 15, 20 and 25 s.
        attempts, text, waits, _ = self.take([255, 255, 255, 0])
        self.assertEqual(attempts, [{"seconds": 10.0, "exit": 255}, {"seconds": 15.0, "exit": 255},
                                    {"seconds": 20.0, "exit": 255}, {"seconds": 25.0, "exit": 0}])
        self.assertEqual((text, waits), (HEAP, [2.0, 2.0, 2.0]))

    def test_a_fourth_failure_is_not_retried(self):
        attempts, text, waits, calls = self.take([255, 255, 255, 255])
        self.assertEqual([a["exit"] for a in attempts], [255, 255, 255, 255])
        self.assertEqual((waits, len(calls)), ([2.0, 2.0, 2.0], 4))
        self.assertIsNone(check.parse_heap(text))

    def test_loads_are_counted_from_the_snapshot_that_was_read(self):
        # Loads 1 s apart from 5 s on. A retried early snapshot read at 15 s
        # instead of 10 s drops the loads that started before 15 s.
        rep = report([5 + i for i in range(60)])
        self.assertEqual(check.count_loads(rep, 10.0, 56.0), 46)
        self.assertEqual(check.count_loads(rep, 15.0, 56.0), 41)


if __name__ == "__main__":
    unittest.main()
