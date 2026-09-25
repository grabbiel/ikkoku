"""Animation curve decoding and binding boundaries without game assets."""
import copy
import math
import struct
import unittest
import zlib

from animation_assets import convert_clip, project_states, rig_paths, sample_curve, streamed_curves


def words(frames):
    raw = bytearray()
    for time, keys in frames:
        raw += struct.pack('<fi', time, len(keys))
        for index, coefficients in keys: raw += struct.pack('<i4f', index, *coefficients)
    return list(struct.unpack('<' + 'I' * (len(raw) // 4), raw))


class SourceAnimationAssetTests(unittest.TestCase):
    def test_streamed_sentinels_and_exact_cubic_coefficients(self):
        data = words([(-3.4028234663852886e38, [(0, [0, 0, 0, 4])]),
                      (0, [(0, [2, 3, 5, 7])]), (1, [(0, [0, 0, 0, 17])]), (math.inf, [])])
        curve = streamed_curves(data, 1, 0)[0]
        self.assertEqual([k['time'] for k in curve['keys']], [0, 1])
        self.assertEqual(sample_curve(curve, 0.5), 10.5)
        self.assertEqual(sample_curve(curve, 1), 17)

    def test_streamed_rejects_truncation_duplicate_index_and_missing_start(self):
        good = words([(0, [(0, [0, 0, 0, 1])]), (math.inf, [])])
        malformed = [good[:-1], words([(0, [(1, [0, 0, 0, 1])]), (math.inf, [])]),
                     words([(0, [(0, [0, 0, 0, 1]), (0, [0, 0, 0, 2])]), (math.inf, [])]),
                     words([(0.1, [(0, [0, 0, 0, 1])]), (math.inf, [])]),
                     words([(0, [(0, [0, 0, math.nan, 1])]), (math.inf, [])])]
        for data in malformed:
            with self.subTest(data=data), self.assertRaises(ValueError): streamed_curves(data, 1, 0)

    def test_streamed_initialization_samples_fill_only_the_prekey_interval(self):
        first = 2.384185791015625e-7
        data = words([(-3.4028234663852886e38, [(0, [0, 0, 0, 4])]),
                      (first, [(0, [0, 0, 0, 7])]), (math.inf, [])])
        curve = streamed_curves(data, 1, 0)[0]
        self.assertEqual(sample_curve(curve, 0), 4)
        self.assertEqual(sample_curve(curve, first), 7)
        data = words([(-1, [(0, [2, 3, 5, 7])]), (1, [(0, [0, 0, 0, 33])]), (math.inf, [])])
        curve = streamed_curves(data, 1, 0)[0]
        self.assertEqual(sample_curve(curve, 0.5), ((2*1.5+3)*1.5+5)*1.5+7)

    def test_dense_sampling_interpolates_and_clamps(self):
        curve = {'kind': 'dense', 'beginTime': 0, 'sampleRate': 2, 'samples': [1, 5, 9]}
        self.assertEqual(sample_curve(curve, 0.25), 3)
        self.assertEqual(sample_curve(curve, -1), 1)
        self.assertEqual(sample_curve(curve, 3), 9)
        self.assertEqual(sample_curve({'kind': 'constant', 'value': 7}, 99), 7)

    def test_dense_curve_can_begin_after_clip_start(self):
        raw = self.clip(); clip = raw['m_MuscleClip']['m_Clip']['data']
        clip['m_DenseClip'].update(m_FrameCount=2, m_CurveCount=3, m_BeginTime=0.25, m_SampleRate=2,
                                 m_SampleArray=[1,2,3,4,5,6])
        clip['m_ConstantClip']['data'] = []
        converted = convert_clip(raw, 'late-dense', {})
        self.assertEqual([sample_curve(c, 0) for c in converted['curves']], [1,2,3])
        self.assertEqual([sample_curve(c, 0.5) for c in converted['curves']], [2.5,3.5,4.5])

    def test_binding_hash_uses_full_root_relative_path_and_explicit_source_id(self):
        rig = {'nodes': [{'name': 'root', 'sourceID': '0', 'parent': None},
                         {'name': 'hips', 'sourceID': '1', 'parent': 0},
                         {'name': 'joint', 'sourceID': '2', 'parent': 1},
                         {'name': 'joint', 'sourceID': '3', 'parent': 0}]}
        mapping = rig_paths(rig, 'body-master/')
        self.assertEqual(mapping[zlib.crc32(b'hips/joint')]['targetSourceID'], 'body-master/2')
        self.assertEqual(mapping[zlib.crc32(b'joint')]['targetSourceID'], 'body-master/3')
        self.assertEqual(mapping[0]['sourcePath'], '')
        rig['nodes'][1]['parent'] = 2
        with self.assertRaises(ValueError): rig_paths(rig, '')

    @staticmethod
    def clip():
        return {'m_Name': 'synthetic', 'm_Legacy': False, 'm_Compressed': False, 'm_Events': [], 'm_PPtrCurves': [],
            'm_SampleRate': 30, 'm_MuscleClip': {'m_StartTime': 0, 'm_StopTime': 1, 'm_Mirror': False,
                'm_LoopBlend': False, 'm_LoopTime': True, 'm_Clip': {'data': {
                    'm_StreamedClip': {'curveCount': 0, 'data': []},
                    'm_DenseClip': {'m_FrameCount': 0, 'm_CurveCount': 0, 'm_SampleRate': 30, 'm_BeginTime': 0, 'm_SampleArray': []},
                    'm_ConstantClip': {'data': [1, 2, 3]}}}},
            'm_ClipBindingConstant': {'genericBindings': [{'path': 42, 'attribute': 1, 'typeID': 4,
                'customType': 0, 'isPPtrCurve': 0, 'script': {'m_FileID': 0, 'm_PathID': 0}}]}}

    def test_generic_clip_preserves_unbound_identity_without_guessing(self):
        clip = convert_clip(self.clip(), 'source:clip', {})
        self.assertEqual(clip['unboundPathHashes'], [42])
        self.assertNotIn('targetSourceID', clip['bindings'][0])
        self.assertEqual(clip['bindings'][0]['curveOffset'], 0)
        self.assertEqual([sample_curve(c, 0) for c in clip['curves']], [1, 2, 3])

    def test_clip_rejects_humanoid_other_types_and_inconsistent_curve_dimensions(self):
        for attribute, value in [('typeID', 95), ('attribute', 4), ('customType', 1), ('isPPtrCurve', 1)]:
            raw = self.clip(); raw['m_ClipBindingConstant']['genericBindings'][0][attribute] = value
            with self.subTest(attribute=attribute), self.assertRaises(ValueError): convert_clip(raw, 'clip', {})
        raw = self.clip(); raw['m_MuscleClip']['m_Clip']['data']['m_ConstantClip']['data'].pop()
        with self.assertRaises(ValueError): convert_clip(raw, 'clip', {})

    def test_clip_rejects_events_mirroring_and_loop_pose_correction(self):
        raw = self.clip(); raw['m_Events'] = [{'time': 0}]
        with self.assertRaises(ValueError): convert_clip(raw, 'clip', {})
        for key in ['m_Mirror', 'm_LoopBlend']:
            raw = self.clip(); raw['m_MuscleClip'][key] = True
            with self.subTest(key=key), self.assertRaises(ValueError): convert_clip(raw, 'clip', {})

    @staticmethod
    def controller():
        def leaf(clip):
            return {'data': {'m_ChildIndices': [], 'm_Mirror': False, 'm_Duration': 1, 'm_ClipID': clip, 'm_CycleOffset': 0}}
        root = {'data': {'m_ChildIndices': [1, 2], 'm_BlendType': 0, 'm_BlendEventID': 2,
                         'm_Blend1dData': {'data': {'m_ChildThresholdArray': [0, 1]}}}}
        state = {'m_NameID': 1, 'm_FullPathID': 4, 'm_Mirror': False, 'm_MirrorParamID': 0,
                 'm_CycleOffsetParamID': 0, 'm_IKOnFeet': False, 'm_TransitionConstantArray': [],
                 'm_Speed': 0.7, 'm_SpeedParamID': 3, 'm_CycleOffset': 0, 'm_Loop': True,
                 'm_BlendTreeConstantArray': [{'data': {'m_NodeArray': [root, leaf(0), leaf(1)]}}]}
        return {'m_TOS': [(1, 'Locomotion'), (2, 'Speed'), (3, 'MotionSpeed'), (4, 'Base.Locomotion')],
                'm_AnimationClips': [{'m_FileID': 0, 'm_PathID': 100}, {'m_FileID': 0, 'm_PathID': 200}],
                'm_Controller': {'m_StateMachineArray': [{'data': {'m_StateConstantArray': [{'data': state}]}}],
                    'm_DefaultValues': {'data': {'m_FloatValues': [0, 1]}},
                    'm_Values': {'data': {'m_ValueArray': [{'m_ID': 2, 'm_Type': 1, 'm_Index': 0},
                                                         {'m_ID': 3, 'm_Type': 1, 'm_Index': 1}]}}}}

    def test_controller_projection_preserves_clip_ids_thresholds_parameters(self):
        states, parameters = project_states(self.controller(), ['Locomotion'], {100: 'source:walk', 200: 'source:run'})
        self.assertEqual(states[0]['blendParameter'], 'Speed')
        self.assertEqual(states[0]['speedParameter'], 'MotionSpeed')
        self.assertEqual(states[0]['motions'], [
            {'clipID': 'source:walk', 'threshold': 0, 'cycleOffset': 0},
            {'clipID': 'source:run', 'threshold': 1, 'cycleOffset': 0}])
        self.assertEqual(parameters, [{'name': 'Speed', 'type': 'float', 'defaultValue': 0},
                                      {'name': 'MotionSpeed', 'type': 'float', 'defaultValue': 1}])

    def test_controller_projection_rejects_automatic_transitions_foreign_clips_and_ambiguous_states(self):
        for case in ['transition', 'foreign', 'duplicate', 'missing']:
            raw = self.controller()
            if case == 'transition': raw['m_Controller']['m_StateMachineArray'][0]['data']['m_StateConstantArray'][0]['data']['m_TransitionConstantArray'] = [{}]
            elif case == 'foreign': raw['m_AnimationClips'][0]['m_FileID'] = 1
            elif case == 'duplicate':
                states = raw['m_Controller']['m_StateMachineArray'][0]['data']['m_StateConstantArray']; states.append(copy.deepcopy(states[0]))
            with self.subTest(case=case), self.assertRaises(ValueError):
                project_states(raw, ['Missing' if case == 'missing' else 'Locomotion'], {100: 'walk', 200: 'run'})


if __name__ == '__main__': unittest.main()
