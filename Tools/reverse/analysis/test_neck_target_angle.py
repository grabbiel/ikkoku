import math
import unittest

from neck_target_angle import (FORWARD, UP, angle_around_axis, angle_axis, angle_degrees,
                               cross, dot, from_to_rotation, get_angle_to_target,
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


STATE = {'hAngleLimit': 90.0, 'vAngleLimit': 90.0, 'limitBreakCorrectionValue': 10.0}


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

    def test_away_frames_report_without_equality(self):
        frame = geometry_frame(target=[2.0, 1.4, 2.0])
        frame['neck']['calculators'][0]['lookType'] = 'AWAY'
        frame['neck']['calculators'][0]['nowAngle'] = [-135.0, 0.0]
        report = verify_trace({'error': None, 'frames': [frame], 'phases': [{'frames': 1}]}, self.settings())
        self.assertEqual(report['targetFrames'], 0)
        self.assertEqual(len(report['awayFrames']), 1)
        self.assertAlmostEqual(report['awayFrames'][0]['raw'][0], 0.0, delta=1e-6)
        self.assertAlmostEqual(report['awayFrames'][0]['raw'][1], 45.0, delta=1e-6)
        self.assertEqual(report['phases'][0]['awayFrames'], 1)

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


if __name__ == '__main__':
    unittest.main()
