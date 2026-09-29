import math
import unittest

from neck_target_angle import (FORWARD, UP, angle_around_axis, angle_axis, angle_degrees,
                               away_adjust, cross, dot, from_to_rotation, get_angle_to_target,
                               limit_check, multiply_quaternions, predict_now_angle,
                               project, rotate, verify_trace)


def yaw(angle):
    """Synthetic yaw rotation around y, Unity x,y,z,w."""
    half = math.radians(angle) / 2.0
    return [0.0, math.sin(half), 0.0, math.cos(half)]


def geometry_frame(*, target, head_rotation=None):
    """A minimal TARGET frame record with every geometry entry the formula reads."""
    return {'phase': 0, 'frameCount': 7,
            'neck': {'ptnNo': 1, 'target': target,
                     'calculators': [{'lookType': 'TARGET', 'nowAngle': [0.0, 0.0]}]},
            'geometry': {'aim': {'position': [0.0, 1.4, 0.0], 'rotation': [0.0, 0.0, 0.0, 1.0]},
                         'neckRef': {'position': [0.0, 1.4, 0.0], 'rotation': [0.0, 0.0, 0.0, 1.0]},
                         'headBone': {'rotation': head_rotation or [0.0, 0.0, 0.0, 1.0]},
                         'isLimitBreakBackup': False}}


STATE = {'hAngleLimit': 90.0, 'vAngleLimit': 90.0, 'limitBreakCorrectionValue': 10.0,
         'limitAway': 10.0,
         'aParam': [{'minBendingAngle': -40.0, 'maxBendingAngle': 40.0},
                    {'minBendingAngle': -20.0, 'maxBendingAngle': 20.0}]}


class VectorHelperTests(unittest.TestCase):
    def test_project_drops_and_keeps_axis_parts(self):
        for index, component in enumerate(project([1.0, 2.0, 3.0], [0.0, 1.0, 0.0])):
            self.assertAlmostEqual(component, [0.0, 2.0, 0.0][index], places=12)
        self.assertEqual(cross([1.0, 0.0, 0.0], [0.0, 1.0, 0.0]), [0.0, 0.0, 1.0])
        self.assertEqual(dot([1.0, 2.0, 3.0], [0.0, 1.0, 0.0]), 2.0)

    def test_project_rejects_degenerate_normal(self):
        with self.assertRaises(ValueError):
            project([1.0, 0.0, 0.0], [0.0, 0.0, 0.0])


class AngleAroundAxisTests(unittest.TestCase):
    def test_signs_follow_the_axis_handedness(self):
        # Unity left-handed: FORWARD to RIGHT about +y is +90, the reverse -90.
        self.assertAlmostEqual(angle_around_axis([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], UP), 90.0, places=9)
        self.assertAlmostEqual(angle_around_axis([1.0, 0.0, 0.0], [0.0, 0.0, 1.0], UP), -90.0, places=9)
        self.assertAlmostEqual(angle_around_axis([0.0, 0.0, 1.0], [0.0, 0.0, 1.0], UP), 0.0, places=12)
        # Antiparallel in-plane vectors keep Unity's unsigned 180 (Cross is
        # zero, so the sign term reads +1).
        self.assertAlmostEqual(angle_around_axis([0.0, 0.0, 1.0], [0.0, 0.0, -1.0], UP), 180.0, places=9)

    def test_axis_parts_are_projected_out(self):
        # A vector tilted out of the plane reads as its in-plane projection.
        self.assertAlmostEqual(angle_around_axis([0.0, 5.0, 1.0], [0.0, 0.0, 1.0], UP), 0.0, places=12)
        # [1,5,1] projects to 45 deg right of +z; Cross(that, +z) opposes up.
        self.assertAlmostEqual(angle_around_axis([1.0, 5.0, 1.0], [0.0, 2.0, 2.0], UP), -45.0, places=9)

    def test_degenerate_operand_reads_zero(self):
        self.assertAlmostEqual(angle_around_axis([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], UP), 0.0, places=12)


class QuaternionTests(unittest.TestCase):
    def assertVectorAlmostEqual(self, a, b):
        self.assertEqual(len(a), 3)
        for x, y in zip(a, b):
            self.assertAlmostEqual(x, y, delta=1e-9)

    def assertQuaternionAlmostEqual(self, a, b):
        self.assertEqual(len(a), 4)
        for x, y in zip(a, b):
            self.assertAlmostEqual(x, y, delta=1e-9)

    def test_angle_axis_rotates_about_the_axis(self):
        self.assertVectorAlmostEqual(rotate(angle_axis(90.0, UP), FORWARD), [1.0, 0.0, 0.0])
        self.assertVectorAlmostEqual(rotate(angle_axis(-90.0, UP), FORWARD), [-1.0, 0.0, 0.0])
        self.assertVectorAlmostEqual(rotate(angle_axis(90.0, [0.0, 1.0, 0.0]), [0.0, 1.0, 0.0]), [0.0, 1.0, 0.0])

    def test_from_to_rotation_shortest_arc(self):
        self.assertVectorAlmostEqual(rotate(from_to_rotation(FORWARD, [1.0, 0.0, 1.0]), FORWARD),
                                     [math.sqrt(.5), 0.0, math.sqrt(.5)])
        self.assertQuaternionAlmostEqual(from_to_rotation([2.0, 0.0, 0.0], [2.0, 0.0, 0.0]),
                                         [0.0, 0.0, 0.0, 1.0])
        # The antiparallel fallback only has to reverse the direction; either
        # perpendicular axis Unity might pick rotates FORWARD to BACK.
        self.assertVectorAlmostEqual(rotate(from_to_rotation(FORWARD, [0.0, 0.0, -1.0]), FORWARD),
                                     [0.0, 0.0, -1.0])

    def test_from_to_rotation_matches_angle_axis_when_perpendicular(self):
        self.assertQuaternionAlmostEqual(from_to_rotation(FORWARD, [1.0, 0.0, 0.0]), angle_axis(90.0, UP))
        # dot < 0 but not antiparallel: the target lies 135 deg LEFT of
        # forward, which is the shortest arc about -y, i.e. -135 about +y.
        self.assertQuaternionAlmostEqual(from_to_rotation(FORWARD, [-1.0, 0.0, -1.0]), angle_axis(-135.0, UP))

    def test_quaternion_product_composes_rotations(self):
        a, b, v = yaw(30.0), angle_axis(50.0, [0.3, 0.6, 0.8]), [1.0, -2.0, 3.0]
        composed = rotate(multiply_quaternions(a, b), v)
        self.assertEqual(len(composed), 3)
        for x, y in zip(composed, rotate(a, rotate(b, v))):
            self.assertAlmostEqual(x, y, delta=1e-9)

    def test_rejects_non_finite_input(self):
        with self.assertRaises(ValueError):
            rotate([float('nan'), 0.0, 0.0, 1.0], FORWARD)


class FormulaTests(unittest.TestCase):
    def test_ahead_target_predicts_zero(self):
        frame = geometry_frame(target=[0.0, 1.4, 2.0])
        predicted = predict_now_angle(frame=frame, head_rotation=[0.0, 0.0, 0.0, 1.0], state=STATE)
        for value in predicted:
            self.assertAlmostEqual(value, 0.0, delta=1e-6)

    def test_side_target_predicts_signed_yaw(self):
        # All references aligned: the right-referenced target yaw lands in y,
        # the pitch-like x about Cross(ref.up, q3*forward) stays zero.
        frame = geometry_frame(target=[2.0, 1.4, 2.0])
        predicted = predict_now_angle(frame=frame, head_rotation=[0.0, 0.0, 0.0, 1.0], state=STATE)
        self.assertAlmostEqual(predicted[0], 0.0, places=6)
        self.assertAlmostEqual(predicted[1], 45.0, places=6)

    def test_head_rotation_enters_the_target_angle(self):
        # q2 = FromToRotation * head-rotation: an ahead target with a 45 deg
        # yawed head reads as a 45 deg yaw, the head assumption alone.
        frame = geometry_frame(target=[0.0, 1.4, 2.0])
        predicted = predict_now_angle(frame=frame, head_rotation=yaw(45.0), state=STATE)
        self.assertAlmostEqual(predicted[0], 0.0, places=6)
        self.assertAlmostEqual(predicted[1], 45.0, places=6)

    def test_limit_check_breaks_only_beyond_limit_plus_correction(self):
        aligned = [0.0, 0.0, 0.0, 1.0]
        broken, horizontal, vertical = limit_check(target=[0.0, 1.4, 2.0], reference_position=[0.0, 1.4, 0.0],
                                                   reference_rotation=aligned, horizontal_limit=90.0,
                                                   vertical_limit=90.0, correction=10.0)
        self.assertFalse(broken)
        # Straight up reads 90 deg about right: inside 90+10 with the correction.
        broken, _, vertical = limit_check(target=[0.0, 3.4, 0.0], reference_position=[0.0, 1.4, 0.0],
                                          reference_rotation=aligned, horizontal_limit=90.0,
                                          vertical_limit=90.0, correction=10.0)
        self.assertFalse(broken)
        # Cross(forward, up) opposes ref.right, so the given AngleAroundAxis
        # hands read straight up as -90 about the right axis.
        self.assertAlmostEqual(vertical, -90.0, places=6)
        # The comparison is strict, so 90 against a 90 limit does not break;
        # a 80 limit does.
        broken, _, _ = limit_check(target=[0.0, 3.4, 0.0], reference_position=[0.0, 1.4, 0.0],
                                   reference_rotation=aligned, horizontal_limit=90.0,
                                   vertical_limit=90.0, correction=0.0)
        self.assertFalse(broken)
        broken, _, _ = limit_check(target=[0.0, 3.4, 0.0], reference_position=[0.0, 1.4, 0.0],
                                   reference_rotation=aligned, horizontal_limit=90.0,
                                   vertical_limit=80.0, correction=0.0)
        self.assertTrue(broken)

    def test_broken_limit_prediction_is_zeroed(self):
        frame = geometry_frame(target=[0.0, 3.4, 0.0])  # straight up, 90 deg up tilt
        state = dict(STATE, vAngleLimit=30.0, limitBreakCorrectionValue=0.0)
        self.assertEqual(predict_now_angle(frame=frame, head_rotation=[0.0, 0.0, 0.0, 1.0], state=state),
                         [0.0, 0.0])

    def test_get_angle_to_target_rejects_zero_offset(self):
        with self.assertRaises(ValueError):
            get_angle_to_target(target=[0.0, 1.4, 0.0], aim_position=[0.0, 1.4, 0.0],
                                aim_rotation=[0.0, 0.0, 0.0, 1.0], reference_position=[0.0, 1.4, 0.0],
                                reference_rotation=[0.0, 0.0, 0.0, 1.0], head_rotation=[0.0, 0.0, 0.0, 1.0])

    def test_angle_degrees_helpers(self):
        self.assertAlmostEqual(angle_degrees([1.0, 0.0, 0.0], [0.0, 1.0, 0.0]), 90.0, places=12)
        self.assertAlmostEqual(angle_degrees([0.0, 0.0, 0.0], [1.0, 0.0, 0.0]), 0.0, places=12)


class AwayAdjustTests(unittest.TestCase):
    # aParam sums to maxBending 60 and minBending -60, limitAway 10, so the
    # only reachable vertical values are +60 and -60 and the tests below pin
    # which side each raw angle collapses onto.
    A_PARAM = STATE['aParam']

    def adjust(self, now_angle, angle_h):
        return away_adjust(now_angle=now_angle, bone_angle_h=angle_h,
                           a_param=self.A_PARAM, limit_away=10.0)

    def test_above_bone_sum_positive_y_takes_the_minimum_bending_sum(self):
        # 45 > num4 = 20 and 45 > 0: the away target flips the vertical onto
        # the min-bending sum and negates the horizontal angle.
        self.assertEqual(self.adjust([3.0, 45.0], [10.0, 10.0]), [-3.0, -60.0])

    def test_above_bone_sum_small_negative_y_takes_the_maximum_bending_sum(self):
        # -55 > num4 = -70 but -55 < -60 + 10 and not > 0: the negative bend
        # is kept and lands on the max-bending sum instead.
        self.assertEqual(self.adjust([3.0, -55.0], [-50.0, -20.0]), [-3.0, 60.0])

    def test_at_or_below_bone_sum_large_positive_y_takes_the_minimum_bending_sum(self):
        # 55 <= num4 = 60 (the branch test is <=) but past 60 - 10 and not
        # negative: the away rule sends it to the min-bending sum.
        self.assertEqual(self.adjust([3.0, 55.0], [40.0, 20.0]), [-3.0, -60.0])

    def test_at_or_below_bone_sum_small_positive_y_takes_the_maximum_bending_sum(self):
        # 7 <= num4 = 20 and 7 <= 60 - 10: inside the away band it bends the
        # max way; the equality case 50 == 60 - 10 breaks the same way.
        self.assertEqual(self.adjust([3.0, 7.0], [10.0, 10.0]), [-3.0, 60.0])
        self.assertEqual(self.adjust([3.0, 50.0], [40.0, 20.0]), [-3.0, 60.0])

    def test_negative_y_below_bone_sum_takes_the_maximum_bending_sum(self):
        # -5 <= num4 = 20 and < 0: the or-clause fires even inside the band.
        self.assertEqual(self.adjust([3.0, -5.0], [10.0, 10.0]), [-3.0, 60.0])

    def test_rejects_degenerate_input(self):
        for kwargs in ({'now_angle': [float('nan'), 0.0], 'bone_angle_h': [1.0]},
                       {'now_angle': [0.0, 1.0], 'bone_angle_h': []},
                       {'now_angle': [0.0, 1.0], 'bone_angle_h': [1.0], 'a_param': []}):
            call = {'a_param': self.A_PARAM, 'limit_away': 10.0}
            call.update(kwargs)
            with self.assertRaises(ValueError):
                away_adjust(**call)


class VerifyTraceTests(unittest.TestCase):
    def settings(self):
        return {'neck': {'neckTypeStates': [{'hAngleLimit': 0.0, 'vAngleLimit': 0.0, 'limitBreakCorrectionValue': 0.0},
                                            STATE]}}

    def test_predicts_recorded_target_frames_under_both_assumptions(self):
        # Two frames whose head rotations differ: frame 1's prediction under
        # the k-1 assumption uses frame 0's head rotation, so the two
        # assumption maxima must be tracked separately.
        frame0 = geometry_frame(target=[0.0, 1.4, 2.0])
        frame0['neck']['calculators'][0]['nowAngle'] = [0.0, 0.0]
        # Head yawed 45 deg on frame 1: with the k-1 (identity) head the yaw
        # lands on the ahead-right target exactly, with frame 1's own head it
        # doubles to 90, so the two assumption maxima separate.
        frame1 = geometry_frame(target=[2.0, 1.4, 2.0], head_rotation=yaw(45.0))
        frame1['neck']['calculators'][0]['nowAngle'] = [0.0, 45.0]
        report = verify_trace({'error': None, 'frames': [frame0, frame1], 'phases': [{'frames': 2}]}, self.settings())
        self.assertEqual(report['targetFrames'], 2)
        entry = report['phases'][0]
        self.assertEqual(entry['targetFrames'], 2)
        self.assertAlmostEqual(entry['previousMaxDegrees'][1], 0.0, delta=1e-6)
        self.assertAlmostEqual(entry['sameFrameMaxDegrees'][1], 45.0, delta=1e-6)

    def test_held_target_frames_are_separated_in_the_report(self):
        # Frame 1's recorded nowAngle is byte-identical to frame 0's (a held
        # frame, the solver did not recompute it): its 30 deg residual still
        # counts in the overall maximum but not in the changed-frame one.
        frame0 = geometry_frame(target=[0.0, 1.4, 2.0])
        frame1 = geometry_frame(target=[0.0, 1.4, 2.0], head_rotation=yaw(30.0))
        frame1['neck']['calculators'][0]['nowAngle'] = [0.0, 0.0]
        report = verify_trace({'error': None, 'frames': [frame0, frame1], 'phases': [{'frames': 2}]}, self.settings())
        entry = report['phases'][0]
        self.assertEqual(entry['heldFrames'], 1)
        self.assertAlmostEqual(entry['sameFrameMaxDegrees'][1], 30.0, delta=1e-6)
        self.assertAlmostEqual(entry['movedMaxDegrees'][1], 0.0, delta=1e-6)

    def test_away_frames_compare_the_adjusted_prediction(self):
        # A TARGET frame with bone angleH 10 + 10 precedes the AWAY frame, so
        # the adjustment reads num4 = 20 (the previous frame's end-of-frame
        # values): raw y = 45 > 20 and > 0 collapses onto the min-bending sum
        # -60 and raw x = 0 negates onto the recorded 11.29876-free zero.
        ahead = geometry_frame(target=[0.0, 1.4, 2.0])
        ahead['neck']['bones'] = [{'neckBone': 'cf_j_neck', 'angleH': 10.0},
                                  {'neckBone': 'cf_j_head', 'angleH': 10.0}]
        away = geometry_frame(target=[2.0, 1.4, 2.0])
        away['phase'] = 2
        away['neck']['bones'] = [{'neckBone': 'cf_j_neck', 'angleH': 3.0},
                                 {'neckBone': 'cf_j_head', 'angleH': 5.0}]
        away['neck']['calculators'][0]['lookType'] = 'AWAY'
        away['neck']['calculators'][0]['nowAngle'] = [0.0, -60.0]
        report = verify_trace({'error': None, 'frames': [ahead, away], 'phases': [{'frames': 1}]}, self.settings())
        self.assertEqual(report['targetFrames'], 1)
        self.assertEqual(len(report['awayFrames']), 1)
        entry = report['awayFrames'][0]
        self.assertAlmostEqual(entry['raw'][0], 0.0, delta=1e-6)
        self.assertAlmostEqual(entry['raw'][1], 45.0, delta=1e-6)
        self.assertAlmostEqual(entry['adjusted'][0], 0.0, delta=1e-6)
        self.assertAlmostEqual(entry['adjusted'][1], -60.0, delta=1e-6)
        self.assertAlmostEqual(report['phases'][2]['awayMaxDegrees'][0], 0.0, delta=1e-6)
        self.assertAlmostEqual(report['phases'][2]['awayMaxDegrees'][1], 0.0, delta=1e-6)
        self.assertEqual(report['phases'][2]['awayFrames'], 1)

    def test_away_frame_without_a_previous_frame_is_rejected(self):
        away = geometry_frame(target=[2.0, 1.4, 2.0])
        away['neck']['calculators'][0]['lookType'] = 'AWAY'
        with self.assertRaises(ValueError):
            verify_trace({'error': None, 'frames': [away], 'phases': [{'frames': 1}]}, self.settings())

    def test_rejects_broken_traces(self):
        with self.assertRaises(ValueError):
            verify_trace({'error': 'boom', 'frames': []}, self.settings())
        missing = geometry_frame(target=[0.0, 1.4, 2.0])
        del missing['geometry']
        with self.assertRaises(ValueError):
            verify_trace({'error': None, 'frames': [missing], 'phases': [{'frames': 1}]}, self.settings())
        with self.assertRaises(ValueError):
            verify_trace({'error': None, 'frames': [geometry_frame(target=[0.0, 1.4, 2.0])]},
                         {'neck': {}})


class FixtureTests(unittest.TestCase):
    def test_fixture_is_deterministic_and_covers_the_branches(self):
        import json
        import tempfile
        from pathlib import Path

        from neck_target_angle import write_fixture

        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / 'fixture.json'
            second = Path(directory) / 'again.json'
            self.assertGreaterEqual(write_fixture(first), 24)
            write_fixture(second)
            self.assertEqual(first.read_text(), second.read_text())
            document = json.loads(first.read_text())
        cases = document['cases']
        self.assertTrue(all(case['id'] for case in cases))
        self.assertTrue(any(case['limits']['isLimitBreakBackup'] and case['limit']['broken'] for case in cases))
        self.assertTrue(any(not case['limits']['isLimitBreakBackup'] and case['limit']['broken'] for case in cases))
        above = below = 0
        for case in cases:
            if case['limit']['broken']:
                self.assertEqual(case['adjusted'], [0.0, 0.0])
                continue
            if case['lookType'] == 'TARGET':
                self.assertEqual(case['adjusted'], case['raw'])
                continue
            if case['raw'][1] > sum(case['away']['boneAngleH']):
                above += 1
            else:
                below += 1
        self.assertGreaterEqual(above, 2)
        self.assertGreaterEqual(below, 2)


if __name__ == '__main__':
    unittest.main()
