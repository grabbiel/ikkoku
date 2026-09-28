import math
import unittest

from neck_look_reference import (DEFAULT_CALC_LERP, DEFAULT_CHANGE_TYPE_LEAP_TIME,
                                 DEFAULT_CHANGE_TYPE_LERP_CURVE, IDENTITY,
                                 evaluate_curve, initial_state, neck_step, slerp)

KEYS = DEFAULT_CHANGE_TYPE_LERP_CURVE['keys']


def yaw(angle):
    """Synthetic yaw rotation around y, Unity x,y,z,w."""
    half = math.radians(angle) / 2.0
    return [0.0, math.sin(half), 0.0, math.cos(half)]


def norm(quaternion):
    length = math.sqrt(sum(component * component for component in quaternion))
    return [component / length for component in quaternion]


class LookReferenceTestCase(unittest.TestCase):
    def assertQuaternionAlmostEqual(self, a, b):
        self.assertEqual(len(a), 4)
        for x, y in zip(a, b):
            self.assertAlmostEqual(x, y, delta=1e-12)


class EvaluateCurveTests(LookReferenceTestCase):
    def test_endpoints_and_clamps(self):
        self.assertAlmostEqual(evaluate_curve(KEYS, 0.0), 0.002166748046875, places=12)
        self.assertAlmostEqual(evaluate_curve(KEYS, 1.0), 1.0, places=12)
        self.assertAlmostEqual(evaluate_curve(KEYS, -0.5), 0.002166748046875, places=12)
        self.assertAlmostEqual(evaluate_curve(KEYS, 3.0), 1.0, places=12)

    def test_midpoint_hermite(self):
        # Both keys span dt = 1: h00*v0 + h10*outSlope + h01*v1 + h11*inSlope,
        # so the left key's 2.2096 outSlope lifts the midpoint above linear.
        u = 0.5
        value = ((2 * u ** 3 - 3 * u ** 2 + 1) * KEYS[0]['value']
                 + (u ** 3 - 2 * u ** 2 + u) * KEYS[0]['outSlope']
                 + (-2 * u ** 3 + 3 * u ** 2) * KEYS[1]['value']
                 + (u ** 3 - u ** 2) * KEYS[1]['inSlope'])
        self.assertAlmostEqual(evaluate_curve(KEYS, 0.5), value, places=12)
        self.assertGreater(value, 0.5)

    def test_left_key_out_slope_shapes_the_start(self):
        # At small u the outSlope term 2.2096*du dominates the value growth.
        t, du = 0.1, 0.1
        h10 = t ** 3 - 2 * t ** 2 + t
        lower = evaluate_curve(KEYS, 0.0) + 0.0  # value at 0 is the key itself
        self.assertGreater(evaluate_curve(KEYS, du), lower + h10 * KEYS[0]['outSlope'])

    def test_needs_keys(self):
        with self.assertRaises(ValueError):
            evaluate_curve([], 0.5)


class SlerpTests(LookReferenceTestCase):
    def test_identities(self):
        a, b = yaw(30.0), yaw(-20.0)
        self.assertQuaternionAlmostEqual(slerp(a, b, 0.0), a)
        self.assertQuaternionAlmostEqual(slerp(a, b, 1.0), b)
        self.assertQuaternionAlmostEqual(slerp(a, a, 0.37), a)
        self.assertQuaternionAlmostEqual(slerp(a, b, 2.0), b)  # parameter clamps
        self.assertQuaternionAlmostEqual(slerp(a, b, -1.0), a)

    def test_halfway_and_shortest_arc(self):
        middle = slerp(yaw(0.0), yaw(80.0), 0.5)
        self.assertAlmostEqual(math.degrees(2 * math.acos(min(1.0, abs(middle[3])))), 40.0, places=6)
        # q and -q are the same rotation: the negated target keeps the short arc.
        negated = slerp(yaw(0.0), [-c for c in yaw(20.0)], 0.5)
        self.assertQuaternionAlmostEqual(negated, slerp(yaw(0.0), yaw(20.0), 0.5))

    def test_degenerate_inputs_rejected(self):
        with self.assertRaises(ValueError):
            slerp([0, 0, 0, 0], yaw(10.0), 0.5)
        with self.assertRaises(ValueError):
            slerp(yaw(10.0), yaw(0.0), float('nan'))


class NeckStepTests(LookReferenceTestCase):
    def start(self, look_type='AWAY', fix=None):
        return initial_state(look_type, fix or [yaw(-30.0), yaw(10.0)])

    def test_zero_delta_time_is_a_no_op(self):
        state, rotations = neck_step(self.start(), 'FORWARD', 0.0, [yaw(-30.0), yaw(10.0)])
        self.assertQuaternionAlmostEqual(rotations[0], yaw(-30.0))
        self.assertQuaternionAlmostEqual(rotations[1], yaw(10.0))
        self.assertEqual(state['lookType'], 'FORWARD')
        self.assertEqual(state['timer'], 0.0)

    def test_type_change_resets_timer_and_backs_up_fix_angle(self):
        state = self.start('TARGET')
        state, _ = neck_step(state, 'FORWARD', 0.1, [IDENTITY, IDENTITY])
        self.assertEqual(state['lookType'], 'FORWARD')
        self.assertAlmostEqual(state['timer'], 0.1, places=12)
        self.assertEqual(state['fixAngleBackup'], [yaw(-30.0), yaw(10.0)])
        self.assertEqual(state['fixAngle'], [IDENTITY, IDENTITY])

    def test_forward_transition(self):
        state = self.start('AWAY')
        first, rotations = neck_step(state, 'FORWARD', 0.01631067, [yaw(-38.0), yaw(10.0)])
        num = evaluate_curve(KEYS, 0.01631067)
        for bone, backup in enumerate([yaw(-30.0), yaw(10.0)]):
            expected = slerp(backup, IDENTITY, num)
            for a, b in zip(rotations[bone], expected):
                self.assertAlmostEqual(a, b, places=12)
        # the arc runs backup -> identity, so the angle shrinks monotonically
        second, rotations = neck_step(first, 'FORWARD', 0.5, [yaw(-38.0), yaw(10.0)])
        angle = math.degrees(2 * math.acos(min(1.0, abs(rotations[0][3]))))
        self.assertLess(angle, 15.0)
        # calcLerp 1 means the entry pose is never read; it still must not crash on junk
        _, same = neck_step(second, 'FORWARD', 0.2, [IDENTITY, IDENTITY])
        self.assertAlmostEqual(second['timer'], 0.51631067, places=8)

    def test_timer_clamps_at_leap_time(self):
        state = self.start('AWAY')
        state, rotations = neck_step(state, 'FORWARD', 2.0, [IDENTITY, IDENTITY])
        self.assertEqual(state['timer'], DEFAULT_CHANGE_TYPE_LEAP_TIME)
        self.assertQuaternionAlmostEqual(rotations[0], IDENTITY)  # num = 1 lands on identity

    def test_fix_hold(self):
        saved = [yaw(-20.0), yaw(15.0)]
        state = self.start('FIX', fix=saved)
        # No type change: timer keeps accumulating but the result is the saved
        # angle from the very first frame, for any animated pose.
        for dt in (0.01, 0.3, 1.0):
            state, rotations = neck_step(state, 'FIX', dt, [yaw(40.0), yaw(-40.0)])
            for bone in range(2):
                self.assertQuaternionAlmostEqual(rotations[bone], saved[bone])
        self.assertEqual(state['fixAngle'], saved)

    def test_animation_blends_backup_to_pose(self):
        state = self.start('FIX')
        backups = [list(angle) for angle in state['fixAngle']]
        pose = [yaw(-5.0), yaw(8.0)]
        state, rotations = neck_step(state, 'ANIMATION', 0.5, pose)
        num = evaluate_curve(KEYS, 0.5)
        for bone in range(2):
            expected = slerp(backups[bone], pose[bone], num)
            self.assertQuaternionAlmostEqual(rotations[bone], expected)
        self.assertEqual(state['fixAngle'], [norm(p) for p in pose])

    def test_unsupported_types_and_shapes_rejected(self):
        with self.assertRaisesRegex(ValueError, 'not simulated'):
            neck_step(self.start('FORWARD'), 'TARGET', 0.1, [IDENTITY, IDENTITY])
        with self.assertRaises(ValueError):
            neck_step(self.start('FORWARD'), 'FIX', 0.1, [IDENTITY])
