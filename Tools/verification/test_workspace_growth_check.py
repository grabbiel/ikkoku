"""Self-tests for workspace_growth_check.py (#410): the heap -s reader, the
load count, the frozen bar and the snapshot retry. No app is needed; the heap output is synthetic
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
    def test_reads_the_five_types_exactly(self):
        counts = check.parse_heap(HEAP)
        self.assertEqual(counts, {"NSKeyValueDependency": 6230, "NSKeyValueDependencyContext": 4773,
                                  "__NSMallocBlock__": 5396, "__NSExactBlockVariable__": 4824,
                                  "AnyHashableBox<UUID>": 4120})

    def test_missing_type_counts_zero(self):
        text = "\n".join(line for line in HEAP.splitlines() if "Foundation.UUID>  Swift" not in line)
        self.assertEqual(check.parse_heap(text)["AnyHashableBox<UUID>"], 0)

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
        return {name: value for name, _ in check.TYPES}

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
        late["AnyHashableBox<UUID>"] = 800 + 105
        self.assertEqual(check.judge(self.counts(800), late, 40)[0], "fail")

    def test_too_few_loads_or_an_unread_snapshot_is_invalid(self):
        self.assertEqual(check.judge(self.counts(800), self.counts(800), 39)[0], "invalid")
        self.assertEqual(check.judge(None, self.counts(800), 48)[0], "invalid")
        self.assertEqual(check.judge(self.counts(800), None, 48)[0], "invalid")


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

    def test_a_good_snapshot_is_taken_once(self):
        attempts, text, waits, calls = self.take([0])
        self.assertEqual(attempts, [{"seconds": 10.0, "exit": 0}])
        self.assertEqual((text, waits, calls), (HEAP, [], [42]))

    def test_a_failed_snapshot_is_retried_once_two_seconds_later(self):
        attempts, text, waits, _ = self.take([255, 0])
        self.assertEqual(attempts, [{"seconds": 10.0, "exit": 255}, {"seconds": 15.0, "exit": 0}])
        self.assertEqual((text, waits), (HEAP, [2.0]))
        self.assertIsNotNone(check.parse_heap(text))

    def test_a_second_failure_is_not_retried(self):
        attempts, text, waits, calls = self.take([255, 255])
        self.assertEqual([a["exit"] for a in attempts], [255, 255])
        self.assertEqual((waits, len(calls)), ([2.0], 2))
        self.assertIsNone(check.parse_heap(text))

    def test_loads_are_counted_from_the_snapshot_that_was_read(self):
        # Loads 1 s apart from 5 s on. A retried early snapshot read at 15 s
        # instead of 10 s drops the loads that started before 15 s.
        rep = report([5 + i for i in range(60)])
        self.assertEqual(check.count_loads(rep, 10.0, 56.0), 46)
        self.assertEqual(check.count_loads(rep, 15.0, 56.0), 41)


if __name__ == "__main__":
    unittest.main()
