"""Synthetic coverage for the look-at trace summarizer's settle math."""
import math
import unittest

from summarize_look_trace import SETTLE_THRESHOLD_DEGREES, format_table, settle_frame, summarize, track_quaternions


def yaw(degrees: float) -> list[float]:
    """Quaternion for a rotation about the y axis, Unity's [x, y, z, w] order."""
    return [0.0, math.sin(math.radians(degrees) / 2), 0.0, math.cos(math.radians(degrees) / 2)]


def neck_bone(name: str, rotation: list[float], fix=None) -> dict:
    return {'bone': name, 'angleH': 0.0, 'angleV': 0.0, 'fixAngle': fix if fix else [0.0, 0.0, 0.0, 1.0],
            'localRotation': rotation, 'worldRotation': rotation}


def frame(phase: int, neck_angles, eye_angle=0.0, neck_ptn=1, eyes_ptn=1) -> dict:
    return {'phase': phase, 'frameCount': 100 + phase, 'deltaTime': 0.02, 'cameraPosition': [0.0, 1.4, 1.5],
            'neck': {'ptnNo': neck_ptn, 'target': [0.0, 1.4, 1.5], 'calculators': [],
                     'bones': [neck_bone('cf_j_neck', yaw(neck_angles[0])), neck_bone('cf_j_head', yaw(neck_angles[1]))]},
            'eyes': {'ptnNo': eyes_ptn, 'target': [0.0, 1.4, 1.5], 'calculators': [],
                     'eyes': [{'eye': 'eye_L', 'localRotation': yaw(eye_angle), 'angleH': 0.0, 'angleV': 0.0},
                              {'eye': 'eye_R', 'localRotation': yaw(eye_angle), 'angleH': 0.0, 'angleV': 0.0}]}}


def trace(frames, phases, error=None) -> dict:
    return {'error': error, 'frameCount': 200, 'phases': phases, 'frames': frames}


def moving_frames(phase, turns):
    """One phase whose neck turns per the `turns` list and whose head and eyes hold still."""
    return [frame(phase, (turn, 0.0)) for turn in turns]


class SettleFrameTest(unittest.TestCase):
    def test_first_quiet_onward_frame_is_the_settle_frame(self):
        self.assertEqual(settle_frame([], SETTLE_THRESHOLD_DEGREES), 0)
        self.assertEqual(settle_frame([0.0, 0.0], SETTLE_THRESHOLD_DEGREES), 0)
        self.assertEqual(settle_frame([0.5, 0.2, 0.0, 0.005], SETTLE_THRESHOLD_DEGREES), 2)

    def test_change_at_or_above_the_threshold_counts_as_moving(self):
        # A big change into the last recorded frame leaves no quiet frame onward.
        self.assertIsNone(settle_frame([0.5, SETTLE_THRESHOLD_DEGREES], SETTLE_THRESHOLD_DEGREES))
        self.assertIsNone(settle_frame([SETTLE_THRESHOLD_DEGREES], SETTLE_THRESHOLD_DEGREES))
        with self.assertRaises(ValueError):
            settle_frame([-0.1], SETTLE_THRESHOLD_DEGREES)


class SummarizeTest(unittest.TestCase):
    def setUp(self):
        phases = [{'neckPattern': 1, 'eyesPattern': 1, 'frames': 5, 'cameraPosition': [0.0, 1.4, 1.5]},
                  {'neckPattern': 4, 'eyesPattern': 2, 'frames': 3, 'cameraPosition': [1.2, 1.8, 1.2]}]
        fixed = yaw(12.0)
        turning = moving_frames(0, (0.0, 10.0, 20.0, 20.0, 20.0))
        still = []
        for _ in range(3):
            f = frame(1, (0.0, 0.0), neck_ptn=4, eyes_ptn=2)
            for bone in f['neck']['bones']:
                bone['localRotation'] = list(fixed)
                bone['fixAngle'] = list(fixed)
            still.append(f)
        self.summaries = summarize(trace(turning + still, phases))

    def test_turning_phase_settles_after_its_last_big_step(self):
        neck = self.summaries[0]['tracks']['cf_j_neck']
        self.assertEqual(neck['settleFrame'], 2)  # changes 0->1 and 1->2 are 10° each, quiet from frame 2 on
        self.assertAlmostEqual(neck['maxStepDegrees'], 10.0, places=6)
        self.assertAlmostEqual(neck['settledAngleDegrees'], 20.0, places=6)  # first frame to last frame
        self.assertEqual(self.summaries[0]['tracks']['cf_j_head']['settleFrame'], 0)  # never moved
        self.assertEqual(self.summaries[0]['tracks']['eye_L']['settleFrame'], 0)

    def test_fix_phase_reports_zero_deviation_from_fix_angle(self):
        for track in ('cf_j_neck', 'cf_j_head'):
            entry = self.summaries[1]['tracks'][track]
            self.assertEqual(entry['settleFrame'], 0)
            self.assertAlmostEqual(entry['fixAngleDeviationDegrees'], 0.0, places=9)
            self.assertEqual(entry['settledAngleDegrees'], 0.0)
        self.assertNotIn('fixAngleDeviationDegrees', self.summaries[1]['tracks']['eye_L'])

    def test_deviation_from_fix_angle_is_measured(self):
        phases = [{'neckPattern': 4, 'eyesPattern': 0, 'frames': 1, 'cameraPosition': [0.0, 0.0, 0.0]}]
        f = frame(0, (0.0, 0.0), neck_ptn=4)
        f['neck']['bones'][0]['fixAngle'] = yaw(30.0)  # bone holds identity, fixAngle is a 30° yaw
        summaries = summarize(trace([f], phases))
        self.assertAlmostEqual(summaries[0]['tracks']['cf_j_neck']['fixAngleDeviationDegrees'], 30.0, places=6)

    def test_broken_traces_are_rejected(self):
        with self.assertRaises(ValueError):
            summarize(trace([], [{'neckPattern': 1, 'eyesPattern': 1, 'frames': 3, 'cameraPosition': [0, 0, 0]}], error='boom'))
        with self.assertRaises(ValueError):  # fewer frames than the phase asked for
            summarize(trace(moving_frames(0, (0.0, 1.0)), [{'neckPattern': 1, 'eyesPattern': 1, 'frames': 3, 'cameraPosition': [0, 0, 0]}]))

    def test_table_marks_a_never_settled_track(self):
        phases = [{'neckPattern': 3, 'eyesPattern': 1, 'frames': 3, 'cameraPosition': [0, 0, 0]}]
        summaries = summarize(trace(moving_frames(0, (0.0, 10.0, 20.0)), phases))
        self.assertIsNone(summaries[0]['tracks']['cf_j_neck']['settleFrame'])
        self.assertIn('| 0 | 3 / 1 | cf_j_neck | never |', format_table(summaries))

    def test_track_quaternions_requires_every_frame(self):
        with self.assertRaises(ValueError):
            track_quaternions([{'phase': 0, 'neck': {'bones': []}}], 'cf_j_neck')


if __name__ == '__main__':
    unittest.main()
