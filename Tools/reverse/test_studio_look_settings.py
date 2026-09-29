"""Synthetic typetree coverage for the look-settings converter (no bundle reads)."""
import unittest

from studio_look_settings import (NECK_LOOK_TYPES, eye_controller_settings, eye_material_settings,
                                  eyes_settings, enum, neck_controller_settings, neck_settings,
                                  pointer_name, quaternion, transform_root, vector2, vector3)


class FakeObject:
    def __init__(self, name):
        self.m_Name = name

    def read(self):
        return self


def pptr(path_id):
    return {'m_FileID': 0, 'm_PathID': path_id}


def transforms():
    """head <- neck chain plus the two eye transforms."""
    return {
        10: {'m_GameObject': pptr(100), 'm_Father': None},
        11: {'m_GameObject': pptr(101), 'm_Father': pptr(10)},
        12: {'m_GameObject': pptr(102), 'm_Father': None},
    }, {100: FakeObject('p_cf_body_bone'), 101: FakeObject('cf_j_neck'), 102: FakeObject('p_cf_head_bone')}


class PointerTests(unittest.TestCase):
    def test_zero_and_missing_pointers_resolve_to_null_only_for_zero(self):
        tree, objects = transforms()
        names = {path_id: objects[tree[path_id]['m_GameObject']['m_PathID']].m_Name for path_id in tree}
        self.assertIsNone(pointer_name(None, names))
        self.assertIsNone(pointer_name(pptr(0), names))
        self.assertEqual(pointer_name(pptr(11), names), 'cf_j_neck')
        with self.assertRaises(ValueError):
            pointer_name(pptr(99), names)

    def test_transform_root_walks_fathers_to_the_prefab_root(self):
        tree, objects = transforms()
        self.assertEqual(transform_root(tree[11], tree, objects), 'p_cf_body_bone')
        self.assertEqual(transform_root(tree[10], tree, objects), 'p_cf_body_bone')
        self.assertEqual(transform_root(tree[12], tree, objects), 'p_cf_head_bone')

    def test_transform_root_rejects_a_parent_cycle(self):
        tree = {1: {'m_GameObject': pptr(100), 'm_Father': pptr(2)}, 2: {'m_GameObject': pptr(100), 'm_Father': pptr(1)}}
        with self.assertRaises(ValueError):
            transform_root(tree[1], tree, {100: FakeObject('root')})


class EnumTests(unittest.TestCase):
    def test_look_types_keep_value_and_name(self):
        self.assertEqual(enum(3, NECK_LOOK_TYPES, 'neck'), {'value': 3, 'name': 'FORWARD'})
        with self.assertRaises(ValueError):
            enum(6, NECK_LOOK_TYPES, 'neck')

    def test_vectors_and_quaternions_keep_source_component_order(self):
        self.assertEqual(vector3({'x': 1, 'y': 2, 'z': 3}), [1, 2, 3])
        self.assertEqual(vector2({'x': 0.25, 'y': -0.75}), [0.25, -0.75])
        self.assertEqual(quaternion({'x': 0, 'y': 0, 'z': 0, 'w': 1}), [0, 0, 0, 1])


def neck_tree():
    return {
        'isEnabled': 1,
        'transformAim': pptr(0),
        'boneCalcAngle': pptr(11),
        'aBones': [{'name': '首', 'referenceCalc': pptr(11), 'neckBone': pptr(11), 'controlBone': pptr(0),
                    'fixAngle': {'x': 0, 'y': 0, 'z': 0, 'w': 1}, 'angleHRate': 0.0, 'angleVRate': 0.0,
                    'angleH': 0.0, 'angleV': 0.0}],
        'neckTypeStates': [{'name': '正面', 'aParam': [{'name': '', 'upBendingAngle': 0.0, 'downBendingAngle': 0.0,
                                                        'minBendingAngle': 0.0, 'maxBendingAngle': 0.0}] * 2,
                            'leapSpeed': 2.0, 'hAngleLimit': 0.0, 'vAngleLimit': 0.0,
                            'limitBreakCorrectionValue': 0.0, 'limitAway': 0.0, 'isLimitBreakBackup': 0,
                            'lookType': 3}],
        'changeTypeLeapTime': 0.2,
        'changeTypeLerpCurve': {'m_Curve': [{'time': 0.0, 'value': 0.002166748046875, 'inSlope': 2.2, 'outSlope': 2.2}],
                                 'm_PreInfinity': 2, 'm_PostInfinity': 2, 'm_RotationOrder': 0},
        'calcLerp': 1, 'skipCalc': 0,
    }


def eye_tree():
    return {
        'correct': 1, 'rootNode': pptr(12), 'trfCenter': pptr(0),
        'closeEyeLength': 4.0, 'centerEyeLength': 0.05,
        'eyeObjs': [{'eyeTransform': pptr(11), 'eyeLR': 0}, {'eyeTransform': pptr(0), 'eyeLR': 1}],
        'headLookVector': {'x': 0, 'y': 0, 'z': 1}, 'headUpVector': {'x': 0, 'y': 1, 'z': 0},
        'eyeTypeStates': [{'comment': '正面', 'thresholdAngleDifference': 0.0, 'bendingMultiplier': 0.4,
                           'maxAngleDifference': 10.0, 'upBendingAngle': -30.0, 'downBendingAngle': 10.0,
                           'minBendingAngle': -36.0, 'maxBendingAngle': 23.0, 'leapSpeed': 22.8,
                           'forntTagDis': 1.0, 'nearDis': 2.0, 'hAngleLimit': 110.0, 'vAngleLimit': 80.0,
                           'lookType': 3}],
        'angleHRate': [0.0, 0.0], 'angleVRate': 0.0, 'sorasiRate': 1.0, 'targetObjMaxDir': 0.5,
    }


class ConverterTests(unittest.TestCase):
    def setUp(self):
        tree, objects = transforms()
        self.names = {path_id: objects[tree[path_id]['m_GameObject']['m_PathID']].m_Name for path_id in tree}

    def test_neck_settings_resolve_pointers_and_name_look_types(self):
        result = neck_settings(neck_tree(), self.names)
        self.assertIsNone(result['transformAim'])
        self.assertEqual(result['boneCalcAngle'], 'cf_j_neck')
        self.assertEqual(result['aBones'][0]['neckBone'], 'cf_j_neck')
        self.assertIsNone(result['aBones'][0]['controlBone'])
        self.assertEqual(result['aBones'][0]['fixAngle'], [0, 0, 0, 1])
        self.assertEqual(result['neckTypeStates'][0]['lookType'], {'value': 3, 'name': 'FORWARD'})
        self.assertEqual(len(result['neckTypeStates'][0]['aParam']), 2)
        self.assertEqual(result['changeTypeLerpCurve']['preInfinity'], 2)
        self.assertEqual(result['changeTypeLerpCurve']['keys'][0]['outSlope'], 2.2)
        self.assertEqual(result['calcLerp'], 1)

    def test_eyes_settings_resolve_pointers_and_name_look_types(self):
        result = eyes_settings(eye_tree(), self.names)
        self.assertEqual(result['rootNode'], 'p_cf_head_bone')
        self.assertIsNone(result['trfCenter'])
        self.assertEqual(result['eyeObjs'][0]['eyeTransform'], 'cf_j_neck')
        self.assertIsNone(result['eyeObjs'][1]['eyeTransform'])
        self.assertEqual(result['eyeTypeStates'][0]['lookType'], {'value': 3, 'name': 'FORWARD'})
        self.assertEqual(result['angleHRate'], [0.0, 0.0])

    def test_controller_settings_are_plain_scalars(self):
        self.assertEqual(neck_controller_settings({'ptnNo': 0, 'rate': 1.0}), {'ptnNo': 0, 'rate': 1.0})
        self.assertEqual(eye_controller_settings({'ptnNo': 1}), {'ptnNo': 1})

    def test_unknown_look_type_is_rejected_not_guessed(self):
        tree = neck_tree()
        tree['neckTypeStates'][0]['lookType'] = 9
        with self.assertRaises(ValueError):
            neck_settings(tree, self.names)


def eye_material_tree():
    """Synthetic EyeLookMaterialControll typetree in the captured field
    layout (texID/texName/isYure texStates), with hand-picked values."""
    return {
        'eyeLR': 1,
        'InsideWait': -100, 'OutsideWait': 100, 'UpWait': -100, 'DownWait': 100,
        'InsideLimit': -100.0, 'OutsideLimit': 100.0, 'UpLimit': -80.0, 'DownLimit': 80.0,
        'power': 0.001,
        'offset': {'x': 0.2, 'y': -0.2}, 'hlUpOffsetY': 0.0, 'hlDownOffsetY': 0.0,
        'scale': {'x': 0.0, 'y': 0.0},
        'texStates': [{'texID': -1, 'texName': '_MainTex', 'isYure': 0},
                      {'texID': -1, 'texName': '_overtex1', 'isYure': 1},
                      {'texID': -1, 'texName': '_overtex2', 'isYure': 0}],
        'YureInside': 4, 'YureOutside': -4, 'YureUp': 4, 'YureDown': -4, 'YureTime': 0.3,
    }


class EyeMaterialConverterTests(unittest.TestCase):
    def test_keeps_eye_lr_waits_limits_offsets_and_tex_states(self):
        result = eye_material_settings(eye_material_tree(), 'cf_Ohitomi_R02', ['cf_m_hitomi_00'])
        self.assertEqual(result['eyeLR'], 1)
        self.assertEqual(result['InsideWait'], -100)
        self.assertEqual(result['DownWait'], 100)
        self.assertEqual(result['UpLimit'], -80.0)
        self.assertEqual(result['power'], 0.001)
        self.assertEqual(result['offset'], [0.2, -0.2])
        self.assertEqual(result['scale'], [0.0, 0.0])
        self.assertEqual([state['texName'] for state in result['texStates']],
                         ['_MainTex', '_overtex1', '_overtex2'])
        self.assertEqual([state['isYure'] for state in result['texStates']], [0, 1, 0])
        self.assertEqual(result['YureInside'], 4)
        self.assertEqual(result['YureTime'], 0.3)
        self.assertEqual(result['gameObject'], 'cf_Ohitomi_R02')
        self.assertEqual(result['materials'], ['cf_m_hitomi_00'])

    def test_missing_required_field_is_a_diagnostic_not_a_default(self):
        for drop in ('power', 'texStates', 'YureTime'):
            tree = eye_material_tree()
            del tree[drop]
            with self.assertRaises(KeyError):
                eye_material_settings(tree, 'cf_Ohitomi_L02', [])


if __name__ == '__main__':
    unittest.main()
