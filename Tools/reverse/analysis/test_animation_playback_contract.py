import json
import unittest

import animation_playback_contract as playback


class AnimationPlaybackContractTests(unittest.TestCase):
    def test_default_strict_deadline_and_random_call_order(self):
        state = playback.Blink()
        state.update(0, playback.Draws())
        self.assertEqual(state.mode, 0)
        draws = playback.Draws([0], [0.05])
        state.update(playback.f32(1), draws)
        self.assertEqual([r["kind"] for r in draws.requests], ["float", "integer"])
        self.assertEqual((state.openness, state.mode, state.count), (1, 1, 1))
        state.update(state.deadline, playback.Draws())
        self.assertEqual((state.openness, state.mode, state.count), (0, 1, 1))

    def test_counted_closed_hold_and_no_elapsed_time_catchup(self):
        state = playback.Blink()
        state.schedule(0, playback.Draws([2], [0]), True)
        state.update(100, playback.Draws())
        self.assertEqual((state.mode, state.count), (1, 2))
        state.update(100, playback.Draws())
        self.assertEqual((state.mode, state.count), (1, 1))
        state.update(100, playback.Draws([], [0]))
        self.assertEqual((state.mode, state.count, state.openness), (-1, 0, 0))
        self.assertEqual(state.deadline, playback.f32(100.15))

    def test_any_fixed_flag_preserves_rate_deadline_and_count(self):
        state = playback.Blink(fixedFlags=128, mode=1, calculatedSpeed=0.15, deadline=1, count=3, openness=0.25)
        before = playback.asdict(state)
        state.update(100, playback.Draws())
        self.assertEqual(playback.asdict(state), before)

    def test_frequency_zero_and_source_rounding_are_not_integer_shortcut(self):
        state = playback.Blink(frequency=0)
        state.idle_deadline(4, playback.Draws([0]))
        self.assertEqual(state.deadline, 4)
        # Source divide-multiply pair has observable float32 rounding for some values.
        mismatch = []
        for frequency in range(1, 256):
            for draw in range(frequency):
                amount = playback.mul(frequency, playback.div(draw, frequency))
                if amount != draw: mismatch.append((frequency, draw, amount))
        self.assertGreater(len(mismatch), 100)

    def test_set_speed_clamps_up_and_does_not_change_active_duration(self):
        state = playback.Blink()
        state.schedule(0, playback.Draws([0], [0]), True)
        state.action({"operation": "speed", "value": 0.2}, playback.Draws())
        self.assertEqual(state.baseSpeed, 1)
        self.assertEqual(state.calculatedSpeed, playback.f32(0.15))

    def test_progress_constructor_start_end_and_duration_edit(self):
        state = playback.Progress()
        self.assertEqual(state.rate, 1)
        self.assertEqual(state.calculate(playback.f32(0.075)), 0.5)
        state.end()
        self.assertEqual(state.count, playback.f32(0.15))
        state.progressTime = playback.f32(0.3)
        self.assertEqual(state.calculate(0), 0.5)
        state.start()
        self.assertEqual((state.rate, state.count), (0, 0))
        self.assertEqual(state.calculate(1000), 1)
        self.assertEqual(state.count, state.progressTime)

    def test_explicit_draws_reject_wrong_ranges_and_unused_values(self):
        with self.assertRaises(ValueError): playback.Draws([3]).integer(0, 3)
        with self.assertRaises(ValueError): playback.Draws([1]).integer(0, 0)
        with self.assertRaises(ValueError): playback.Draws([], [0.06]).floating(0, 0.05)
        with self.assertRaises(ValueError): playback.Draws([0]).finish()

    def test_random_progress_returns_one_after_restarting_at_zero(self):
        state = playback.RandomProgress()
        state.initialize(0.1, 0.2, playback.Draws([], [0.1]))
        self.assertEqual(state.calculate(playback.f32(0.1), playback.Draws([], [0.2])), 1)
        self.assertEqual((state.progress.count, state.progress.rate), (0, 0))
        self.assertEqual(state.progress.progressTime, playback.f32(0.2))
        self.assertEqual(state.calculate(playback.f32(0.1), playback.Draws(), 0.4, 0.5), 0.5)
        self.assertEqual(state.progress.progressTime, playback.f32(0.2))
        self.assertEqual(state.calculate(playback.f32(0.1), playback.Draws([], [0.5])), 1)
        self.assertEqual(state.progress.progressTime, 0.5)

    def test_reference_is_deterministic_json_and_covers_all_actions(self):
        reference = playback.reference()
        encoded = json.dumps(reference, allow_nan=False, sort_keys=True)
        self.assertEqual(encoded, json.dumps(playback.reference(), allow_nan=False, sort_keys=True))
        actions = [action for scenario in reference["scenarios"] for action in scenario["actions"]]
        self.assertEqual(len(actions), 48)
        self.assertEqual({a["operation"] for a in actions}, {"update", "frequency", "speed", "flags", "forceOpen", "forceClose"})
        self.assertTrue(any(a["expressionBlinkRate"] == -1 for a in actions))
        self.assertTrue(any(a["expected"]["mode"] == -1 for a in actions))


if __name__ == "__main__": unittest.main()
