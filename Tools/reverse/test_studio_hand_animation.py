"""Synthetic controller/clip/table coverage for the studio hand converters."""
import unittest

from animation_assets import convert_clip, f32
from studio_hand_animation import (convert_all_patterns, convert_hand, convert_pattern, curve_values,
                                   default_clip, pattern_bones, pattern_frames, pattern_rows, wrapped_time)

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


def dense_clip(name):
    """One looping 1/6 s clip whose rotation is two dense frames and whose scale is constant."""
    return {'m_Name': name, 'm_Legacy': False, 'm_Compressed': False, 'm_Events': [], 'm_PPtrCurves': [],
            'm_SampleRate': 30, 'm_MuscleClip': {'m_StartTime': 0, 'm_StopTime': 0.1666667, 'm_Mirror': False,
                'm_LoopBlend': False, 'm_LoopTime': True, 'm_Clip': {'data': {
                    'm_StreamedClip': {'curveCount': 0, 'data': []},
                    'm_DenseClip': {'m_FrameCount': 2, 'm_CurveCount': 4, 'm_SampleRate': 30, 'm_BeginTime': 0,
                        'm_SampleArray': [0, 0, 0, 1, 0, 0, 0.5, 0.5]},
                    'm_ConstantClip': {'data': [1.1, 1.2, 1.3]}}}},
            'm_ClipBindingConstant': {'genericBindings': [
                {'path': 42, 'attribute': 2, 'typeID': 4, 'customType': 0, 'isPPtrCurve': 0,
                 'script': {'m_FileID': 0, 'm_PathID': 0}},
                {'path': 43, 'attribute': 3, 'typeID': 4, 'customType': 0, 'isPPtrCurve': 0,
                 'script': {'m_FileID': 0, 'm_PathID': 0}}]}}


def constant_clip(name):
    """A clip with no dense slots at all, like patterns 9/13/17/20/21 in the original bundle."""
    raw = dense_clip(name)
    raw['m_MuscleClip']['m_Clip']['data']['m_DenseClip'] = {'m_FrameCount': 0, 'm_CurveCount': 0,
                                                            'm_SampleRate': 30, 'm_BeginTime': 0, 'm_SampleArray': []}
    raw['m_MuscleClip']['m_Clip']['data']['m_ConstantClip'] = {'data': [0, 0.5, 0, 0.5, 2, 2, 2]}
    return raw


def pattern_state(name_id, clip_index):
    return {'data': {'m_NameID': name_id, 'm_FullPathID': name_id + 3, 'm_Mirror': False, 'm_MirrorParamID': 0,
            'm_CycleOffsetParamID': 0, 'm_IKOnFeet': False, 'm_TransitionConstantArray': [],
            'm_Speed': 1, 'm_SpeedParamID': 0, 'm_CycleOffset': 0, 'm_Loop': True,
            'm_BlendTreeConstantArray': [{'data': {'m_NodeArray': [motion(clip_index)]}}]}}


def pattern_controller():
    return {'m_TOS': [(1, 'goo'), (2, 'scissors'), (4, 'Hand.goo'), (5, 'Hand.scissors')],
            'm_AnimationClips': [{'m_FileID': 0, 'm_PathID': 100}, {'m_FileID': 0, 'm_PathID': 101}],
            'm_Controller': {'m_StateMachineArray': [{'data': {'m_DefaultState': 0,
                'm_StateConstantArray': [pattern_state(1, 0), pattern_state(2, 1)]}}],
                'm_LayerArray': [{}],
                'm_DefaultValues': {'data': {'m_FloatValues': []}},
                'm_Values': {'data': {'m_ValueArray': []}}}}


def pattern_table(name, controller_name, rows):
    header = [{'list': ['0', 'name', 'bundle', 'controller', 'state']}]
    return {'m_Name': name, 'list': header + [{'list': [str(pid), disp, 'studio/base/00.unity3d', controller_name, state]}
                                              for pid, disp, state in rows]}


def pattern_objects():
    return {100: Reader(dense_clip('Goo')), 101: Reader(constant_clip('Scissors'))}


PATTERN_POINTERS = {100: 'source:100', 101: 'source:101'}


def pattern_readers():
    controllers = {name: Reader(pattern_controller()) for name in ('cf_hand_L_00', 'cf_hand_R_00')}
    avatars = {name: Reader({'m_TOS': HAND_TOS}) for name in ('cf_hand_L_00Avatar', 'cf_hand_R_00Avatar')}
    return controllers, avatars


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

    def test_pattern_rows_skips_header_and_blank_trailer(self):
        table = pattern_table('HandAnime_00_00', 'cf_hand_L_00', [(1, 'goo', 'goo'), (2, 'scissors', 'scissors')])
        table['list'] += [{'list': []}, {'list': ['', '', '']}]
        self.assertEqual(pattern_rows(table, 'cf_hand_L_00', '00.unity3d'), {1: 'goo', 2: 'scissors'})

    def test_pattern_rows_rejects_malformed_tables(self):
        good = pattern_table('HandAnime_00_00', 'cf_hand_L_00', [(1, 'goo', 'goo')])['list'][1]['list']
        for case, row in [('short', good[:3]), ('textId', ['x'] + good[1:]), ('zeroId', ['0'] + good[1:]),
                          ('foreignController', good[:3] + ['cf_body_00', 'goo']),
                          ('foreignBundle', good[:2] + ['studio/anime/00.unity3d'] + good[3:]),
                          ('blankState', good[:4] + [''])]:
            table = {'m_Name': 'HandAnime_00_00', 'list': [{'list': ['0', 'name', 'bundle', 'controller', 'state']}, {'list': row}]}
            with self.subTest(case=case), self.assertRaises(ValueError):
                pattern_rows(table, 'cf_hand_L_00', '00.unity3d')
        duplicate = pattern_table('HandAnime_00_00', 'cf_hand_L_00', [(1, 'goo', 'goo'), (1, 'repeat', 'scissors')])
        with self.assertRaises(ValueError):
            pattern_rows(duplicate, 'cf_hand_L_00', '00.unity3d')
        empty = pattern_table('HandAnime_00_00', 'cf_hand_L_00', [])
        empty['list'].append({'list': ['', '', '']})
        with self.assertRaises(ValueError):
            pattern_rows(empty, 'cf_hand_L_00', '00.unity3d')

    def test_pattern_frames_lists_dense_slots_and_broadcasts_constant_only_clips(self):
        targets = {hash: {'sourcePath': path, 'targetSourceID': f'x/{path}', 'targetName': path.rsplit('/', 1)[-1]}
                   for hash, path in HAND_TOS.items()}
        dense = convert_clip(dense_clip('Goo'), 'source:100', targets)
        self.assertEqual(pattern_frames(dense), [f32(0.0), f32(1 / 30)])
        constant = convert_clip(constant_clip('Ok'), 'source:101', targets)
        self.assertEqual(pattern_frames(constant), [0.0])

    def test_pattern_frames_rejects_disagreeing_dense_geometry(self):
        clip = {'name': 'mixed', 'startTime': 0, 'curves': [
            {'kind': 'dense', 'beginTime': 0, 'sampleRate': 30, 'samples': [0, 1]},
            {'kind': 'dense', 'beginTime': 0, 'sampleRate': 60, 'samples': [0, 1]}]}
        with self.assertRaises(ValueError):
            pattern_frames(clip)

    def test_convert_pattern_emits_every_native_frame(self):
        converted = convert_pattern(pattern_controller(), 'cf_hand_L_00', 1, 'goo', {'m_TOS': HAND_TOS},
                                    'cf_hand_L_00Avatar', pattern_objects(), PATTERN_POINTERS)
        self.assertEqual((converted['id'], converted['name'], converted['state']), (1, 'Goo', 'goo'))
        self.assertEqual(converted['clip'], {'startTime': 0, 'stopTime': 0.1666667, 'sampleRate': 30, 'loop': True})
        self.assertEqual(converted['frameTimes'], [f32(0.0), f32(1 / 30)])
        bone = converted['bones']['cf_j_middle01_L']
        self.assertEqual(bone['frames'], [[0, 0, 0, 1], [0, 0, 0.5, 0.5]])
        self.assertEqual(bone['scale'], [[f32(1.1), f32(1.2), f32(1.3)]] * 2)

    def test_convert_pattern_broadcasts_constant_only_clip_frames(self):
        converted = convert_pattern(pattern_controller(), 'cf_hand_L_00', 2, 'scissors', {'m_TOS': HAND_TOS},
                                    'cf_hand_L_00Avatar', pattern_objects(), PATTERN_POINTERS)
        self.assertEqual(converted['name'], 'Scissors')
        self.assertEqual(converted['frameTimes'], [0.0])
        self.assertEqual(converted['bones']['cf_j_middle01_L']['frames'], [[0, 0.5, 0, 0.5]])

    def test_convert_pattern_rejects_multi_clip_states(self):
        raw = pattern_controller()
        state = raw['m_Controller']['m_StateMachineArray'][0]['data']['m_StateConstantArray'][0]['data']
        state['m_BlendTreeConstantArray'] = [{'data': {'m_NodeArray': [
            {'data': {'m_ChildIndices': [1, 2], 'm_BlendType': 0, 'm_BlendEventID': 4,
                      'm_Blend1dData': {'data': {'m_ChildThresholdArray': [0, 1]}}}}, motion(0), motion(1)]}}]
        with self.assertRaises(ValueError):
            convert_pattern(raw, 'cf_hand_L_00', 1, 'goo', {'m_TOS': HAND_TOS},
                            'cf_hand_L_00Avatar', pattern_objects(), PATTERN_POINTERS)

    def test_convert_all_patterns_walks_both_tables(self):
        controllers, avatars = pattern_readers()
        tables = {name: pattern_table(name, f'cf_hand_{hand}_00', [(1, 'goo', 'goo'), (2, 'scissors', 'scissors')])
                  for hand, name in (('L', 'HandAnime_00_00'), ('R', 'HandAnime_01_00'))}
        tables['HandAnime_01_00']['list'].append({'list': []})
        hands = convert_all_patterns(tables, controllers, avatars, pattern_objects(), PATTERN_POINTERS, '00.unity3d')
        self.assertEqual(sorted(hands), ['L', 'R'])
        for hand in ('L', 'R'):
            patterns = hands[hand]['patterns']
            self.assertEqual([pattern['id'] for pattern in patterns], [1, 2])
            self.assertEqual([pattern['name'] for pattern in patterns], ['Goo', 'Scissors'])
            self.assertEqual([len(pattern['frameTimes']) for pattern in patterns], [2, 1])
        for case in ('missingTable', 'extraTable'):
            subset = dict(tables)
            if case == 'missingTable':
                subset.pop('HandAnime_00_00')
            else:
                subset['HandAnime_02_00'] = tables['HandAnime_00_00']
            with self.subTest(case=case), self.assertRaises(ValueError):
                convert_all_patterns(subset, controllers, avatars, pattern_objects(), PATTERN_POINTERS, '00.unity3d')

    def test_pattern_bones_requires_an_animated_rotation(self):
        clip = {'name': 'scaleOnly', 'unboundPathHashes': [],
                'bindings': [{'attribute': 3, 'curveOffset': 0, 'targetName': 'cf_j_middle01_L'}],
                'curves': [{'kind': 'constant', 'value': value} for value in (1, 1, 1)]}
        with self.assertRaises(ValueError):
            pattern_bones(clip, [0.0])


if __name__ == '__main__':
    unittest.main()
