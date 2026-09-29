"""Synthetic controller/clip coverage for the studio hand default-state converter."""
import unittest

from animation_assets import convert_clip
from studio_hand_animation import convert_hand, curve_values, default_clip, wrapped_time

HAND_TOS = {42: 'Root/cf_j_middle01_L', 43: 'Other/cf_j_middle01_L'}


def clip():
    """One looping 1/6 s clip with a constant position and rotation curve."""
    return {'m_Name': 'Goo', 'm_Legacy': False, 'm_Compressed': False, 'm_Events': [], 'm_PPtrCurves': [],
            'm_SampleRate': 30, 'm_MuscleClip': {'m_StartTime': 0, 'm_StopTime': 0.1666667, 'm_Mirror': False,
                'm_LoopBlend': False, 'm_LoopTime': True, 'm_Clip': {'data': {
                    'm_StreamedClip': {'curveCount': 0, 'data': []},
                    'm_DenseClip': {'m_FrameCount': 0, 'm_CurveCount': 0, 'm_SampleRate': 30, 'm_BeginTime': 0, 'm_SampleArray': []},
                    'm_ConstantClip': {'data': [1, 2, 3, 0, 0, 0, 1]}}}},
            'm_ClipBindingConstant': {'genericBindings': [
                {'path': 42, 'attribute': 1, 'typeID': 4, 'customType': 0, 'isPPtrCurve': 0,
                 'script': {'m_FileID': 0, 'm_PathID': 0}},
                {'path': 43, 'attribute': 2, 'typeID': 4, 'customType': 0, 'isPPtrCurve': 0,
                 'script': {'m_FileID': 0, 'm_PathID': 0}}]}}


def motion(clip_index):
    return {'data': {'m_ChildIndices': [], 'm_Mirror': False, 'm_Duration': 1, 'm_ClipID': clip_index, 'm_CycleOffset': 0}}


def controller():
    state = {'m_NameID': 1, 'm_FullPathID': 4, 'm_Mirror': False, 'm_MirrorParamID': 0,
             'm_CycleOffsetParamID': 0, 'm_IKOnFeet': False, 'm_TransitionConstantArray': [],
             'm_Speed': 1, 'm_SpeedParamID': 0, 'm_CycleOffset': 0, 'm_Loop': True,
             'm_BlendTreeConstantArray': [{'data': {'m_NodeArray': [motion(0)]}}]}
    return {'m_TOS': [(1, 'goo'), (2, 'scissors'), (4, 'Hand.goo')],
            'm_AnimationClips': [{'m_FileID': 0, 'm_PathID': 100}, {'m_FileID': 0, 'm_PathID': 101}],
            'm_Controller': {'m_StateMachineArray': [{'data': {'m_DefaultState': 0,
                'm_StateConstantArray': [{'data': state}]}}],
                'm_LayerArray': [{}],
                'm_DefaultValues': {'data': {'m_FloatValues': []}},
                'm_Values': {'data': {'m_ValueArray': []}}}}


class Reader:
    """Stands in for an `ObjectReader`; the converter never touches UnityPy here."""

    def __init__(self, data):
        self.data = data

    def read_typetree(self):
        return self.data


class StudioHandAnimationTests(unittest.TestCase):
    def test_wrapped_time_folds_every_playhead_into_the_loop(self):
        clip = {'name': 'goo', 'startTime': 0, 'stopTime': 0.1666667, 'loop': True}
        self.assertEqual(wrapped_time(clip, 0), 0)
        self.assertEqual(wrapped_time(clip, clip['stopTime']), 0)
        self.assertAlmostEqual(wrapped_time(clip, 0.1), 0.1, delta=1e-9)
        self.assertAlmostEqual(wrapped_time(clip, 1), 1 - 5 * 0.1666667, places=6)
        self.assertAlmostEqual(wrapped_time(clip, -0.001), 0.1666667 - 0.001, places=6)
        for time in (float('inf'), float('nan')):
            with self.subTest(time=time), self.assertRaises(ValueError): wrapped_time(clip, time)

    def test_nonlooping_clip_clamps_instead_of_wrapping(self):
        clip = {'name': 'oneShot', 'startTime': 0.1, 'stopTime': 0.4, 'loop': False}
        self.assertEqual([wrapped_time(clip, time) for time in (-1, 0.25, 0.9)], [0.1, 0.25, 0.4])

    def test_converter_samples_and_reports_a_wrapped_clip_time(self):
        converted = convert_hand(controller(), 'cf_hand_L_00', {'m_TOS': HAND_TOS},
                                 'cf_hand_L_00Avatar', {100: Reader(clip())}, {100: 'source:100'}, 0.3)
        self.assertEqual(converted['state'], 'goo')
        self.assertEqual(converted['stateIndex'], 0)
        self.assertEqual(converted['clip'], {'id': 'source:100', 'name': 'Goo', 'loop': True,
                                             'startTime': 0, 'stopTime': 0.1666667})
        self.assertEqual(converted['sampleTime']['requested'], 0.3)
        self.assertAlmostEqual(converted['sampleTime']['clipTime'], 0.3 - 0.1666667, places=6)
        self.assertEqual(converted['bones'], {'cf_j_middle01_L': {'position': [1, 2, 3], 'rotation': [0, 0, 0, 1]}})

    def test_converter_requires_full_binding_coverage(self):
        with self.assertRaises(ValueError):
            convert_hand(controller(), 'cf_hand_L_00', {'m_TOS': {42: 'Root/cf_j_middle01_L'}},
                         'cf_hand_L_00Avatar', {100: Reader(clip())}, {100: 'source:100'}, 0)

    def test_converter_rejects_unknown_states_layers_and_unresolved_clips(self):
        for case in ['badStateIndex', 'twoLayers', 'twoMotions', 'foreignFile']:
            raw, objects = controller(), {100: Reader(clip()), 101: Reader(clip())}
            machine = raw['m_Controller']['m_StateMachineArray'][0]['data']
            state = machine['m_StateConstantArray'][0]['data']
            if case == 'badStateIndex': machine['m_DefaultState'] = 3
            elif case == 'twoLayers': raw['m_Controller']['m_LayerArray'].append({})
            elif case == 'twoMotions': state['m_BlendTreeConstantArray'] = [{'data': {
                'm_NodeArray': [{'data': {'m_ChildIndices': [1, 2], 'm_BlendType': 0, 'm_BlendEventID': 2,
                                          'm_Blend1dData': {'data': {'m_ChildThresholdArray': [0, 1]}}}},
                                motion(0), motion(1)]}}]
            else: raw['m_AnimationClips'][0]['m_FileID'] = 1
            with self.subTest(case=case), self.assertRaises(ValueError):
                convert_hand(raw, 'cf_hand_L_00', {'m_TOS': HAND_TOS}, 'cf_hand_L_00Avatar',
                             objects, {100: 'source:100', 101: 'source:101'}, 0)

    def test_default_clip_keeps_the_converted_clip_available(self):
        raw = clip()
        raw['m_MuscleClip']['m_LoopTime'] = False
        index, name, converted = default_clip(controller(), 'cf_hand_L_00', {'m_TOS': HAND_TOS},
                                               'cf_hand_L_00Avatar', {100: Reader(raw)}, {100: 'source:100'})
        self.assertEqual((index, name, converted['name'], converted['loop']), (0, 'goo', 'Goo', False))
        self.assertEqual([curve['kind'] for curve in converted['curves']], ['constant'] * 7)

    def test_conflicting_curves_for_one_bone_are_reported(self):
        raw = clip()
        raw['m_MuscleClip']['m_Clip']['data']['m_ConstantClip']['data'] = [1, 2, 3, 4, 5, 6, 7, 8]
        raw['m_ClipBindingConstant']['genericBindings'] = [
            {'path': 42, 'attribute': 2, 'typeID': 4, 'customType': 0, 'isPPtrCurve': 0,
             'script': {'m_FileID': 0, 'm_PathID': 0}},
            {'path': 43, 'attribute': 2, 'typeID': 4, 'customType': 0, 'isPPtrCurve': 0,
             'script': {'m_FileID': 0, 'm_PathID': 0}}]
        targets = {hash: {'sourcePath': path, 'targetSourceID': f'cf_hand_L_00Avatar/{path}',
                          'targetName': path.rsplit('/', 1)[-1]} for hash, path in HAND_TOS.items()}
        with self.assertRaises(ValueError):
            curve_values(convert_clip(raw, 'source:100', targets), 0)


if __name__ == '__main__':
    unittest.main()
