import json
import math
import unittest

from iris_reference import (TEX_SLOTS, _clamp, _inverse_lerp, _lerp, card_values, eye_fields,
                            f32, iris_rotations, iris_texture_transforms, settings_from_exported)

# The same bo_head_00 eyeMaterial block the Swift fixture tests embed
# (SourceStudioIrisOffsetTests / SourceStudioIrisRenderingTests), decoded from
# the studio-look-settings.json export.  The Swift tests replay the formulas
# in Double and pin double literals; this module replays the same arithmetic
# in float32 with the game's operand order, so most hand values land on the
# nearest float32 to Swift's double and a few land 1 ulp away where an
# intermediate (num * (power * num3), a float32-multiply the Double replay
# folds differently) rounds differently.  Those exact float32 answers are
# pinned equal and cross-checked against the Swift double within 1e-7.
EXPORTED_EYE_MATERIAL = json.loads(
    '[{"DownLimit": 80.0, "DownWait": 100, "InsideLimit": -100.0, "InsideWait": -100,'
    ' "OutsideLimit": 100.0, "OutsideWait": 100, "UpLimit": -80.0, "UpWait": -100,'
    ' "YureDown": -4, "YureInside": 4, "YureOutside": -4, "YureTime": 0.30000001192092896,'
    ' "YureUp": 4, "eyeLR": 0, "gameObject": "cf_Ohitomi_L02", "hlDownOffsetY": 0.0,'
    ' "hlUpOffsetY": 0.0, "materials": ["cf_m_hitomi_00"],'
    ' "offset": [-0.20000000298023224, -0.20000000298023224], "power": 0.0010000000474974513,'
    ' "scale": [0.0, 0.0], "texStates": [{"isYure": 0, "texID": -1, "texName": "_MainTex"},'
    ' {"isYure": 0, "texID": -1, "texName": "_overtex1"},'
    ' {"isYure": 0, "texID": -1, "texName": "_overtex2"}]},'
    ' {"DownLimit": 80.0, "DownWait": 100, "InsideLimit": -100.0, "InsideWait": -100,'
    ' "OutsideLimit": 100.0, "OutsideWait": 100, "UpLimit": -80.0, "UpWait": -100,'
    ' "YureDown": -4, "YureInside": 4, "YureOutside": -4, "YureTime": 0.30000001192092896,'
    ' "YureUp": 4, "eyeLR": 1, "gameObject": "cf_Ohitomi_R02", "hlDownOffsetY": 0.0,'
    ' "hlUpOffsetY": 0.0, "materials": ["cf_m_hitomi_00"],'
    ' "offset": [0.20000000298023224, -0.20000000298023224], "power": 0.0010000000474974513,'
    ' "scale": [0.0, 0.0], "texStates": [{"isYure": 0, "texID": -1, "texName": "_MainTex"},'
    ' {"isYure": 0, "texID": -1, "texName": "_overtex1"},'
    ' {"isYure": 0, "texID": -1, "texName": "_overtex2"}]}]')

# +-0.020000001247972264 / 0.020000001247972264 are the Swift resting doubles;
# the float32 replay lands on these two (the R x is its own float32 because
# InverseLerp(0.4) and InverseLerp(0.6) carry different roundings).
RESTING_L = [-0.020000001415610313, 0.020000001415610313]
RESTING_R = [0.02000000886619091, 0.020000001415610313]


def exported(eye: int = 0, **overrides):
    """The exported entry, with JSON-level replacements for the branch tests.

    Waits/limits overrides pass script_defaults=False — the guard exists to
    catch a prefab that moved off the Initialize defaults, and the branch
    tests deliberately move one number.
    """
    entry = json.loads(json.dumps(EXPORTED_EYE_MATERIAL[eye]))
    for key, value in overrides.items():
        if key not in entry:
            raise KeyError(f'the exported entry has no {key}')
        entry[key] = value
    return settings_from_exported(entry,
                                  script_defaults=not any(
                                      key in ('InsideWait', 'OutsideWait', 'UpWait', 'DownWait',
                                              'InsideLimit', 'OutsideLimit', 'UpLimit', 'DownLimit',
                                              'power') for key in overrides))


def fields(offset_x=0.0, offset_y=0.0, scale=(0.0, 0.0), hl_up=0.0, hl_down=0.0):
    """A card-shaped field set for the branch tests: the values eye_fields
    would hold after the ChangeSettingEye* setters ran, already narrowed to
    the float32 the controller keeps (offset_x is the SetEyeTexOffsetX input
    before the per-eye R negation)."""
    return {'offsetX': f32(offset_x), 'offsetY': f32(offset_y),
            'scale': [f32(scale[0]), f32(scale[1])],
            'hlUp': f32(hl_up), 'hlDown': f32(hl_down)}


class UnityFloat32SemanticsTests(unittest.TestCase):
    def test_f32_narrows_and_rejects(self):
        self.assertEqual(f32(0.1), 0.10000000149011612)
        self.assertEqual(f32(0.1), f32(f32(0.1)))
        for bad in (True, 'x', None, math.inf, math.nan):
            with self.assertRaises(ValueError):
                f32(bad)

    def test_lerp_clamps_t_and_narrows_endpoints(self):
        self.assertEqual(_lerp(2.0, 6.0, 0.5), 4.0)
        self.assertEqual(_lerp(2.0, 6.0, 1.7), 6.0)
        self.assertEqual(_lerp(2.0, 6.0, -0.2), 2.0)
        # The game holds 0.1f/1.8f as float32, so Mathf.Lerp(0.1f, -0.1f, 0.5f)
        # is exactly 0 — a double 0.1 endpoint would land the result 1 ulp
        # (1.49e-9) below zero instead.
        self.assertEqual(_lerp(0.1, -0.1, 0.5), 0.0)
        self.assertEqual(_lerp(1.8, -0.2, 0.9), 0.0)

    def test_inverse_lerp_clamps_and_degenerate_range(self):
        self.assertEqual(_inverse_lerp(-1.0, 1.0, 0.0), 0.5)
        self.assertEqual(_inverse_lerp(-1.0, 1.0, 2.0), 1.0)
        self.assertEqual(_inverse_lerp(-1.0, 1.0, -2.0), 0.0)
        self.assertEqual(_inverse_lerp(3.0, 3.0, 3.0), 1.0)

    def test_clamp_rejects_inverted_range(self):
        self.assertEqual(_clamp(0.5, 0.0, 1.0), 0.5)
        self.assertEqual(_clamp(9.0, -2.0, 3.0), f32(3.0))
        with self.assertRaises(ValueError):
            _clamp(5.0, 10.0, 1.0)


class SettingsFromExportedTests(unittest.TestCase):
    def test_decodes_both_exported_eyes(self):
        for index, (game_object, eye_lr, offset_x) in enumerate(
                [('cf_Ohitomi_L02', 0, -0.20000000298023224),
                 ('cf_Ohitomi_R02', 1, 0.20000000298023224)]):
            eye = exported(index)
            self.assertEqual(eye['gameObject'], game_object)
            self.assertEqual(eye['eyeLR'], eye_lr)
            self.assertEqual(eye['offset'], [offset_x, -0.20000000298023224])
            for key, want in [('insideWait', -100), ('outsideWait', 100),
                              ('upWait', -100), ('downWait', 100),
                              ('insideLimit', -100.0), ('outsideLimit', 100.0),
                              ('upLimit', -80.0), ('downLimit', 80.0),
                              ('power', 0.0010000000474974513),
                              ('hlUpOffsetY', 0.0), ('hlDownOffsetY', 0.0)]:
                self.assertEqual(eye[key], f32(want), f'{game_object} {key}')
            self.assertEqual(eye['scale'], [0.0, 0.0])
            self.assertEqual([state['texName'] for state in eye['texStates']], list(TEX_SLOTS))
            self.assertFalse(any(state['isYure'] for state in eye['texStates']),
                             'the prefab marks none of the three Yure')

    def test_rejects_malformed_entries(self):
        broken = [dict(offset=[-0.2, -0.2, 0.0]), dict(scale=[0.0]),
                  dict(texStates=[{'isYure': 0, 'texName': ''}]), dict(texStates=[]),
                  dict(power='fast')]
        for override in broken:
            with self.assertRaises(ValueError, msg=f'{override} is a diagnostic'):
                exported(0, **override)

    def test_default_guard_pins_initialize_values(self):
        # A prefab that moved off the Initialize defaults is refused while
        # the guard is on, and admitted with script_defaults=False.
        with self.assertRaises(ValueError):
            settings_from_exported({**EXPORTED_EYE_MATERIAL[0], 'OutsideWait': 90})
        moved = settings_from_exported({**EXPORTED_EYE_MATERIAL[0], 'OutsideWait': 90},
                                       script_defaults=False)
        self.assertEqual(moved['outsideWait'], 90.0)


class TextureTransformTests(unittest.TestCase):
    def setUp(self):
        self.l = exported(0)
        self.r = exported(1)

    def offsets(self, rate_h, rate_v, settings=None, card=None):
        return [entry['offset'] for entry in
                iris_texture_transforms(rate_h, rate_v, settings or self.l, card)]

    def test_resting_rates_write_exported_offsets_on_all_three(self):
        for settings, expected in [(self.l, RESTING_L), (self.r, RESTING_R)]:
            transforms = iris_texture_transforms(0, 0, settings, None)
            self.assertEqual([entry['texName'] for entry in transforms], list(TEX_SLOTS))
            for entry in transforms:
                self.assertEqual(entry['offset'], expected)
                self.assertEqual(entry['scale'], [1.0, 1.0])
                self.assertFalse(entry['yure'])
                for got, want in zip(entry['offset'],
                                     [-0.020000001247972264, 0.020000001247972264]
                                     if settings is self.l else
                                     [0.020000001247972264, 0.020000001247972264]):
                    self.assertAlmostEqual(got, want, delta=1e-7, msg='Swift double anchor')

    def test_normalizes_only_outside_the_unit_circle(self):
        # (3, 4) renormalizes to (0.6, 0.8); (0.6, 0.8) sits on the circle and
        # the gate is strict (> 1), so both read the same write — the Swift
        # double 0.06000000284984708 / -0.0800000037997961.
        for rate in [(3, 4), (0.6, 0.8)]:
            offset = self.offsets(*rate, card=fields())[0]
            self.assertEqual(offset, [0.06000000238418579, -0.08000000566244125])
            self.assertAlmostEqual(offset[0], 0.06000000284984708, delta=1e-7)
            self.assertAlmostEqual(offset[1], -0.0800000037997961, delta=1e-7)

    def test_signs_follow_the_waits(self):
        # InsideWait -100 / OutsideWait +100 and DownWait +100 / UpWait -100
        # with Down-first: Swift pins +-0.10000000474974513 (double); the
        # float32 replay is f32(0.1) with the sign the wait pair dictates.
        for rate, expected in [((1, 0), [f32(0.1), 0.0]),
                               ((-1, 0), [-f32(0.1), 0.0]),
                               ((0, 1), [0.0, -f32(0.1)]),
                               ((0, -1), [0.0, f32(0.1)])]:
            self.assertEqual(self.offsets(*rate, card=fields())[0], expected)

    def test_limits_clamp_and_inverted_range_raises(self):
        tightened = exported(0, OutsideLimit=0.02, DownLimit=0.05)
        self.assertEqual(self.offsets(1, -1, tightened, fields())[0],
                         [f32(0.02), f32(0.05)])
        inverted = exported(0, InsideLimit=300.0)
        with self.assertRaises(ValueError):
            iris_texture_transforms(0, 0, inverted, fields())

    def test_highlight_offsets_touch_only_textures_one_and_two(self):
        # The prefab y (+0.02...) shifts by hlUp/hlDown AFTER the clamp, on
        # texStates 1 and 2 only; the x column never sees the highlights.
        card = fields(offset_x=self.l['offset'][0], offset_y=self.l['offset'][1],
                      hl_up=0.5, hl_down=-0.25)
        offsets = self.offsets(0, 0, self.l, card)
        self.assertEqual(offsets[0], RESTING_L)
        self.assertEqual(offsets[1], [RESTING_L[0], 0.5199999809265137])
        self.assertEqual(offsets[2], [RESTING_L[0], -0.23000000417232513])

    def test_scale_subtracts_half_and_writes_one_plus_scale(self):
        # scale (2, 4): Lerp(1, 5, t) clamps both factors to 5, so at rateH
        # 0.5 the main tex reads 50 * power * 5 = 0.25, minus scale.x/2 gives
        # -0.75 (Swift double -0.7499999881256372) and y 0 - 2 = -2, with the
        # texture scale 1 + scale = (3, 5).
        transforms = iris_texture_transforms(0.5, 0, self.l, fields(scale=(2, 4)))
        for entry in transforms:
            self.assertEqual(entry['offset'], [-0.75, -2.0])
            self.assertAlmostEqual(entry['offset'][0], -0.7499999881256372, delta=1e-7)
            self.assertEqual(entry['scale'], [3.0, 5.0])

    def test_yure_entry_is_unjittered_placeholder(self):
        # The Swift modeling of the random YureAddScale / YureAddVec writes:
        # power steps 0.8/0.5, no scale/2 subtract and texture scale (1, 1),
        # yure set (Swift double 0.20000000949949026, 0).
        settings = exported(0, texStates=[{'isYure': 1, 'texID': -1, 'texName': '_MainTex'},
                                         {'isYure': 0, 'texID': -1, 'texName': '_overtex1'},
                                         {'isYure': 0, 'texID': -1, 'texName': '_overtex2'}])
        transforms = iris_texture_transforms(0.5, 0, settings, fields(scale=(2, 4)))
        self.assertEqual(transforms[0]['offset'], [0.20000000298023224, 0.0])
        self.assertAlmostEqual(transforms[0]['offset'][0], 0.20000000949949026, delta=1e-7)
        self.assertEqual(transforms[0]['scale'], [1.0, 1.0])
        self.assertTrue(transforms[0]['yure'])
        self.assertEqual(transforms[1]['offset'], [-0.75, -2.0])
        self.assertFalse(transforms[1]['yure'] or transforms[2]['yure'])


class CardValueTests(unittest.TestCase):
    def test_cha_file_face_defaults(self):
        # pupilX/Y 0.5, pupilWidth/Height 0.9, hlUpY/hlDownY 0.5 — the
        # ChaFileFace Initialize defaults the fixture card carries.  Every
        # float32 endpoint Lerp here lands on an exact value: the Swift test
        # pins offsetX -0.2 (1e-7), offsetY 0, scale (0, 0) and hl 0 exactly.
        card = card_values(0.5, 0.5, 0.9, 0.9, 0.5, 0.5, sex=1, ex_type=0)
        self.assertEqual(card, {'offsetX': -0.20000000298023224, 'offsetY': 0.0,
                                'scale': [0.0, 0.0], 'hlUp': 0.0, 'hlDown': 0.0})

    def test_field_extremes_land_on_the_lerp_endpoints(self):
        zero = card_values(0, 0, 0, 0, 0, 0, sex=1, ex_type=0)
        self.assertEqual(zero, {'offsetX': 0.20000000298023224, 'offsetY': -0.5,
                                'scale': [1.7999999523162842, 1.7999999523162842],
                                'hlUp': 0.10000000149011612, 'hlDown': 0.10000000149011612})
        one = card_values(1, 1, 1, 1, 1, 1, sex=1, ex_type=0)
        # t = 1 keeps the float32 round-trip of 0.2f - 1.8f's rounding, the
        # 1 ulp Swift absorbs with its 1e-7 (double answer -0.20000000298023224).
        self.assertEqual(one['offsetX'], -0.6000000238418579)
        self.assertEqual(one['offsetY'], 0.5)
        self.assertEqual(one['scale'], [-0.20000004768371582, -0.20000004768371582])
        for value in one['scale']:
            self.assertAlmostEqual(value, -0.2, delta=1e-7)
        self.assertEqual(one['hlUp'], -0.10000000149011612)
        self.assertEqual(one['hlDown'], -0.10000000149011612)

    def test_out_of_range_fields_clamp(self):
        low = card_values(-3, -1, -0.5, -2, -1, -0.25, sex=1, ex_type=0)
        self.assertEqual(low, card_values(0, 0, 0, 0, 0, 0, sex=1, ex_type=0))
        high = card_values(4, 2, 1.5, 3, 1.2, 8, sex=1, ex_type=0)
        self.assertEqual(high, card_values(1, 1, 1, 1, 1, 1, sex=1, ex_type=0))

    def test_special_male_skips(self):
        # sex 0 with exType 1: every ChangeSettingEye* returns early and the
        # prefab snapshot stays; the other identities apply.
        self.assertIsNone(card_values(0, 1, 0, 1, 0, 0, sex=0, ex_type=1))
        self.assertIsNotNone(card_values(0.5, 0.5, 0.9, 0.9, 0.5, 0.5, sex=0, ex_type=0))
        self.assertIsNotNone(card_values(0.5, 0.5, 0.9, 0.9, 0.5, 0.5, sex=1, ex_type=1))

    def test_right_eye_negates_only_offset_x(self):
        settings_l, settings_r = exported(0), exported(1)
        self.assertEqual(eye_fields(settings_l, None)['offset'],
                         [-0.20000000298023224, -0.20000000298023224])
        card = card_values(0.5, 0.5, 0.9, 0.9, 0.5, 0.5, sex=1, ex_type=0)
        self.assertEqual(eye_fields(settings_l, card)['offset'], [-0.20000000298023224, 0.0])
        self.assertEqual(eye_fields(settings_r, card)['offset'], [0.20000000298023224, 0.0])
        # A card offsetX of 0.3 passes through SetEyeTexOffsetX: L keeps it,
        # R stores the negation (Swift pins +-0.030000000000000002 at 1e-7).
        shifted = fields(offset_x=0.3)
        self.assertEqual(iris_texture_transforms(0, 0, settings_l, shifted)[0]['offset'],
                         [0.030000001192092896, 0.0])
        self.assertEqual(iris_texture_transforms(0, 0, settings_r, shifted)[0]['offset'],
                         [-0.030000001192092896, 0.0])

    def test_default_card_rests_grounding_the_v_write(self):
        # The Swift end-to-end default-card test: v = (0, 0) + (-0.2/0.2, 0),
        # so u coincides with the prefab +-0.02 while the prefab's +0.02 v
        # write drops to 0 (offset.y 0 is the Down/Up midpoint) and hl 0 adds
        # nothing to _overtex1/2.
        card = card_values(0.5, 0.5, 0.9, 0.9, 0.5, 0.5, sex=1, ex_type=0)
        for settings, expected_u in [(exported(0), RESTING_L[0]), (exported(1), RESTING_R[0])]:
            for entry in iris_texture_transforms(0, 0, settings, card):
                self.assertEqual(entry['offset'], [expected_u, 0.0])
                self.assertEqual(entry['scale'], [1.0, 1.0])


class IrisRotationTests(unittest.TestCase):
    def test_shape_value_33_rotates_the_two_eyes_oppositely(self):
        # ChangeSettingEyeTilt writes Lerp(0.02f, -0.02f, v33) on eye 0 and
        # Lerp(-0.02f, 0.02f, v33) on eye 1 straight onto the rendEye
        # materials; the fixture card holds v33 = 0, so the captured
        # _rotation must sit at +-0.02 float32 (Swift pins the double
        # 0.020000001247972264 in its tilt contract).
        self.assertEqual(iris_rotations(0), [0.019999999552965164, -0.019999999552965164])
        self.assertEqual(iris_rotations(1), [-0.019999999552965164, 0.019999999552965164])
        self.assertEqual(iris_rotations(0.5), [0.0, 0.0])
        for rotation in iris_rotations(0):
            self.assertAlmostEqual(abs(rotation), 0.020000001247972264, delta=1e-7)


if __name__ == '__main__':
    unittest.main()
