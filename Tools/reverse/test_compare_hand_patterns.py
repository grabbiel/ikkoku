"""Synthetic replay coverage for the hand-pattern capture comparator."""
import json
import math
from pathlib import Path
import tempfile
import unittest

from compare_hand_patterns import (angle_degrees, capture_patterns, compare_capture, compare_capture_folder, compare_frame,
                                   library_pattern, pattern_rotation, sample_frames, validate_library,
                                   wrapped_time)

BONE = 'cf_j_middle01_L'
R_BONE = 'cf_j_thumb01_R'


def pattern(pattern_id=1, stop=0.2, rate=10.0, times=(0.0, 0.1)):
    """One looping clip whose rotation lerps from identity to the quarter turn."""
    return {'id': pattern_id, 'name': 'goo', 'state': 'goo',
            'clip': {'startTime': 0.0, 'stopTime': stop, 'sampleRate': rate, 'loop': True},
            'frameTimes': list(times),
            'bones': {BONE: {'frames': [[0.0, 0.0, 0.0, 1.0], [0.0, 0.7071068, 0.0, 0.7071068]]},
                      R_BONE: {'frames': [[0.0, 0.0, 0.0, 1.0], [0.0, 0.7071068, 0.0, 0.7071068]]}}}


def library(extra=None):
    patterns = [pattern()]
    if extra:
        patterns += extra
    return {'schemaVersion': 1, 'converterVersion': '1.0.0', 'kind': 'ikkoku-studio-hand-patterns',
            'coordinateSpace': 'unity-left-handed-y-up',
            'scope': 'hand-anime-table-states-generic-transforms',
            'source': {'bundleSHA256': '0' * 64, 'bundle': 'x', 'infoBundleSHA256': '0' * 64, 'infoBundle': 'y'},
            'hands': {'L': {'patterns': patterns}, 'R': {'patterns': [dict(pattern(pattern_id=p['id'])) for p in patterns]}}}


def frame(normalized=0.5, length=0.2, rotation=None):
    """One recorded snapshot whose playhead lands exactly on frame 0.1."""
    return {'moment': 'frame0', 'bones': {BONE: [{'path': 'Root/' + BONE,
            'localRotation': rotation or [0.0, 0.7071068, 0.0, 0.7071068]}],
            R_BONE: [{'path': 'Root/' + R_BONE,
            'localRotation': rotation or [0.0, 0.7071068, 0.0, 0.7071068]}]},
            'hands': {'L': {'exists': True, 'isActiveAndEnabled': True, 'frameCount': 32, 'deltaTime': 0.02,
                            'normalizedTime': normalized, 'length': length, 'shortNameHash': 1234},
                      'R': {'exists': True, 'isActiveAndEnabled': True, 'frameCount': 32, 'deltaTime': 0.02,
                            'normalizedTime': normalized, 'length': length, 'shortNameHash': 1234}}}


class CompareHandPatternsTests(unittest.TestCase):
    def test_wrapped_time_folds_playheads_into_the_loop(self):
        self.assertEqual(wrapped_time(pattern(), 0.0), 0.0)
        self.assertAlmostEqual(wrapped_time(pattern(), 0.25), 0.05, places=9)
        self.assertAlmostEqual(wrapped_time(pattern(), 0.35), 0.15, places=9)
        self.assertAlmostEqual(wrapped_time(pattern(), -0.05), 0.15, places=9)
        for time in (float('inf'), float('nan')):
            with self.subTest(time=time), self.assertRaises(ValueError):
                wrapped_time(pattern(), time)

    def test_sample_frames_interpolates_between_adjacent_dense_frames(self):
        times, rate = [0.0, 0.1], 10.0
        self.assertEqual(sample_frames([[1, 2], [3, 4]], times, rate, 0.0), [1, 2])
        self.assertEqual(sample_frames([[1, 2], [3, 4]], times, rate, 0.1), [3, 4])
        self.assertEqual(sample_frames([[1, 2], [3, 4]], times, rate, 0.05), [2, 3])
        self.assertEqual(sample_frames([[1, 2], [3, 4]], times, rate, 0.5), [3, 4])  # clamped to the last frame
        self.assertEqual(sample_frames([[1, 2]], [0.0], rate, 7.0), [1, 2])  # constant-broadcast clip

    def test_angle_degrees_ignores_quaternion_sign_and_measures_turns(self):
        self.assertAlmostEqual(angle_degrees([0, 0, 0, 1], [0, 0, 0, 1]), 0.0, places=9)
        self.assertAlmostEqual(angle_degrees([0, 0, 0, 1], [0, 0, 0, -1]), 0.0, places=9)
        self.assertAlmostEqual(angle_degrees([0, 0, 0, 1], [0, 0.7071068, 0, 0.7071068]), 90.0, places=4)

    def test_pattern_rotation_normalizes_the_interpolated_quaternion(self):
        unnormalized = pattern()
        unnormalized['bones'][BONE]['frames'][0] = [0.0, 0.0, 0.0, 2.0]
        self.assertEqual(pattern_rotation(unnormalized, BONE, 0.0), [0.0, 0.0, 0.0, 1.0])

    def test_constant_only_clip_reports_its_single_frame_at_every_time(self):
        constant = pattern(times=[0.0])
        self.assertEqual(pattern_rotation(constant, BONE, 0.0), [0.0, 0.0, 0.0, 1.0])
        self.assertEqual(pattern_rotation(constant, BONE, 0.5), [0.0, 0.0, 0.0, 1.0])

    def test_library_validation_accepts_the_converted_shape_and_flags_bad_libraries(self):
        validate_library(library())
        for case in ('kind', 'gap', 'badClip', 'badTime'):
            broken = library()
            if case == 'kind':
                broken['kind'] = 'something-else'
            elif case == 'gap':
                broken['hands']['L']['patterns'].append(pattern(pattern_id=3))
            elif case == 'badClip':
                broken['hands']['L']['patterns'][0]['clip']['loop'] = False
            else:
                broken['hands']['L']['patterns'][0]['frameTimes'] = [0.5]
            with self.subTest(case=case), self.assertRaises(ValueError):
                validate_library(broken)

    def test_library_pattern_reports_pattern_zero_and_missing_ids(self):
        self.assertEqual(library_pattern(library(), 'L', 1)['id'], 1)
        for case in ('zero', 'unknown'):
            with self.subTest(case=case), self.assertRaises(ValueError):
                library_pattern(library(), 'L', 0 if case == 'zero' else 9)

    def test_compare_frame_replays_at_the_recorded_playhead(self):
        result = compare_frame(library(), 'L', 1, frame())
        self.assertEqual(result['moment'], 'frame0')
        self.assertAlmostEqual(result['clipTime'], 0.1, places=9)
        self.assertEqual(result['maxAngleDegrees'], result['bones'][0]['angleDegrees'])
        self.assertAlmostEqual(result['maxAngleDegrees'], 0.0, places=4)

    def test_compare_frame_folds_whole_loops_at_the_seam(self):
        # Unity reports normalizedTime 2.0 with an f32 state length a hair
        # below the library's stopTime; multiplying would land on the final
        # frame instead of the first, so the phase must fold by stopTime.
        seam = frame(normalized=2.0, length=0.2 - 1e-6, rotation=[0.0, 0.0, 0.0, 1.0])
        result = compare_frame(library(), 'L', 1, seam)
        self.assertAlmostEqual(result['clipTime'], 0.0, places=9)
        self.assertAlmostEqual(result['maxAngleDegrees'], 0.0, places=4)

    def test_compare_frame_measures_a_rotated_capture(self):
        turned = frame(rotation=[0.0, 0.0, 0.0, 1.0])
        result = compare_frame(library(), 'L', 1, turned)
        self.assertAlmostEqual(result['maxAngleDegrees'], 90.0, places=4)
        self.assertEqual(result['stateShortNameHash'], 1234)

    def test_compare_frame_rejects_missing_animators_and_unanimated_bones(self):
        missing = frame()
        missing['hands']['L']['exists'] = False
        with self.assertRaises(ValueError):
            compare_frame(library(), 'L', 1, missing)
        extra = frame()
        extra['bones']['cf_j_ring01_L'] = [{'path': 'Root/cf_j_ring01_L', 'localRotation': [0, 0, 0, 1]}]
        with self.assertRaises(ValueError):
            compare_frame(library(), 'L', 1, extra)

    def test_compare_capture_aggregates_both_hands_and_frames(self):
        report = compare_capture(library(), [frame(), frame(normalized=1.5)], {'L': 1, 'R': 1})
        self.assertEqual(report['patterns'], {'L': 1, 'R': 1})
        self.assertEqual(report['perSide']['L']['frames'], 2)
        self.assertAlmostEqual(report['maxAngleDegrees'], 0.0, places=4)
        self.assertAlmostEqual(report['perSide']['L']['clipTimeMin'], 0.1, places=9)

    def test_frame_json_checks_all_matching_bones_at_capture_phase(self):
        converted = library()
        extra_bone = 'cf_j_middle02_L'
        converted['hands']['L']['patterns'][0]['bones'][extra_bone] = {
            'frames': [[0, 0, 0, 1], [0, 0, 0, 1]]}
        snapshot = frame(normalized=2.5, length=0.2 - 1e-6)
        snapshot['moment'] = 'frameJsonCapture'
        quarter_turn = [0, 0.7071068, 0, 0.7071068]
        one_degree = [0, math.sin(math.radians(0.5)), 0, math.cos(math.radians(0.5))]
        exported = {'bones': [
            {'path': 'Root/cf_s_hand_L/' + BONE, 'rotation': quarter_turn},
            {'path': 'Root/cf_s_hand_L/' + extra_bone, 'rotation': one_degree},
            {'path': 'Root/cf_s_hand_R/' + R_BONE, 'rotation': quarter_turn},
            {'path': 'Root/other/' + extra_bone, 'rotation': quarter_turn},
            {'path': 'Root/cf_s_hand_L/unconverted', 'rotation': quarter_turn},
        ]}
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory)
            library_path = capture / 'studio-hand-patterns.json'
            library_path.write_text(json.dumps(converted))
            (capture / 'hand-anime.json').write_text(json.dumps([snapshot]))
            (capture / 'fingers.json').write_text(json.dumps([{'handPatterns': {'L': 1, 'R': 1}}]))
            (capture / 'frame.json').write_text(json.dumps(exported))
            report = compare_capture_folder(json.loads(library_path.read_text()), capture)
            self.assertEqual(report['perSide']['L']['allBones']['count'], 2)
            self.assertEqual(report['perSide']['R']['allBones']['count'], 1)
            self.assertEqual(report['perSide']['L']['allBones']['worstBone'], extra_bone)
            self.assertAlmostEqual(report['perSide']['L']['allBones']['maxDegrees'], 1.0, places=5)
            self.assertAlmostEqual(report['perSide']['R']['allBones']['maxDegrees'], 0.0, places=4)
            self.assertAlmostEqual(report['maxAngleDegrees'], 1.0, places=5)
            self.assertFalse(report['passed'])
            exported['bones'][1]['rotation'] = [0, 0, 0, 1]
            (capture / 'frame.json').write_text(json.dumps(exported))
            self.assertTrue(compare_capture_folder(json.loads(library_path.read_text()), capture)['passed'])

    def test_capture_patterns_reads_the_recorded_ids_and_rejects_absent_modes(self):
        self.assertEqual(capture_patterns([{'handPatterns': {'L': 3, 'R': 17}}]), {'L': 3, 'R': 17})
        self.assertEqual(capture_patterns([{'handPatterns': None}, {'handPatterns': {'L': 1, 'R': 2}}]), {'L': 1, 'R': 2})
        for case in ('absent', 'half'):
            records = [{'handPatterns': None}] if case == 'absent' else [{'handPatterns': {'L': 1}}]
            with self.subTest(case=case), self.assertRaises(ValueError):
                capture_patterns(records)


if __name__ == '__main__':
    unittest.main()
