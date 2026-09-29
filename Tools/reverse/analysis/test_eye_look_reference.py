import math
import unittest

from eye_look_reference import (IDENTITY, _bend, add, angle_between_quaternions,
                                correct_eye_targets, cross, eye_bending, eye_update,
                                inverse_lerp, inverse_quaternion, local_to_world,
                                look_rotation, lerp, normalize_or_zero, ortho_normalize,
                                resolve_target, scale, slerp_vector, sorasi_horizontal,
                                world_to_local)
from neck_target_angle import FORWARD, RIGHT, UP, angle_axis, rotate

# The run1 studio settings the replay uses: pattern 1 (TARGET) bending numbers
# and the exported eye block.
TARGET_STATE = {'lookType': 'TARGET', 'thresholdAngleDifference': 0.0,
                'bendingMultiplier': 0.4000000059604645, 'maxAngleDifference': 10.0,
                'upBendingAngle': -30.0, 'downBendingAngle': 10.0,
                'minBendingAngle': -36.0, 'maxBendingAngle': 23.0,
                'leapSpeed': 38.0, 'forntTagDis': 50.0, 'nearDis': 2.0,
                'hAngleLimit': 110.0, 'vAngleLimit': 80.0}
AWAY_STATE = dict(TARGET_STATE, lookType='AWAY', leapSpeed=2.5)
SETTINGS = {'correct': 1, 'centerEyeLength': 0.05000000074505806, 'sorasiRate': 1.0}


def node(position=(0.0, 0.0, 0.0), rotation=None, lossy_scale=(1.0, 1.0, 1.0)):
    return {'position': list(position), 'rotation': rotation or list(IDENTITY),
            'lossyScale': list(lossy_scale)}


def eye_geometry(index, position):
    """The per-eye internals record the probe writes, at a chosen eye position."""
    return {'eye': f'cf_Ohitomi_{"L" if index == 0 else "R"}',
            'target': node(position), 'origRotation': list(IDENTITY),
            'referenceLookDir': [0.0, 0.0, 1.0], 'referenceUpDir': [0.0, 1.0, 0.0],
            'dirUp': [0.0, 1.0, 0.0]}


class UnityHelperTests(unittest.TestCase):
    def test_lerp_and_inverse_lerp_clamp(self):
        self.assertEqual(lerp(2.0, 6.0, 0.5), 4.0)
        self.assertEqual(lerp(2.0, 6.0, 1.7), 6.0)
        self.assertEqual(lerp(2.0, 6.0, -0.2), 2.0)
        self.assertEqual(inverse_lerp(0.0, 4.0, 1.0), 0.25)
        self.assertEqual(inverse_lerp(0.0, 4.0, 9.0), 1.0)
        self.assertEqual(inverse_lerp(0.0, 4.0, -1.0), 0.0)
        self.assertEqual(inverse_lerp(3.0, 3.0, 3.0), 1.0)
        self.assertEqual(inverse_lerp(4.0, 0.0, 3.0), 0.25)

    def test_normalize_or_zero_maps_zero_to_zero(self):
        self.assertEqual(normalize_or_zero([0.0, 0.0, 0.0]), [0.0, 0.0, 0.0])
        self.assertEqual(normalize_or_zero([0.0, 0.0, 5.0]), [0.0, 0.0, 1.0])

    def test_slerp_clamps_t_and_keeps_magnitude(self):
        self.assertEqual(slerp_vector([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], 0.0), [0.0, 0.0, 1.0])
        self.assertEqual(slerp_vector([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], 1.0), [1.0, 0.0, 0.0])
        self.assertEqual(slerp_vector([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], 2.0), [1.0, 0.0, 0.0])
        # Vector3.Slerp normalizes the arc but lerps the magnitudes: the
        # mean magnitude 2.5 sits at the 45 deg midpoint.
        for component, want in zip(slerp_vector([0.0, 0.0, 3.0], [2.0, 0.0, 0.0], 0.5),
                                   [2.5 * math.sqrt(0.5), 0.0, 2.5 * math.sqrt(0.5)]):
            self.assertAlmostEqual(component, want, delta=1e-12)
        # A zero operand collapses toward the other endpoint's direction scaled
        # by (1-t) the way Unity's overload does.
        for component, want in zip(slerp_vector([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 0.25),
                                   [0.0, 0.0, 0.0]):
            self.assertAlmostEqual(component, want, delta=1e-12)
        # An exact antiparallel pair rotates about a perpendicular axis.
        result = slerp_vector([0.0, 0.0, 1.0], [0.0, 0.0, -1.0], 0.5)
        self.assertAlmostEqual(math.sqrt(sum(c * c for c in result)), 1.0, delta=1e-9)
        self.assertAlmostEqual(result[2], 0.0, delta=1e-9)

    def test_ortho_normalize_orthogonalizes_and_falls_back(self):
        normal, tangent = ortho_normalize([1.0, 1.0, 0.0], [1.0, 0.0, 0.0])
        self.assertAlmostEqual(math.sqrt(sum(c * c for c in normal)), 1.0, delta=1e-12)
        self.assertAlmostEqual(sum(a * b for a, b in zip(normal, tangent)), 0.0, delta=1e-12)
        # A tangent parallel to the normal falls back to the least-aligned axis
        # and still returns an orthonormal pair.
        normal, tangent = ortho_normalize([0.0, 1.0, 0.0], [0.0, 3.0, 0.0])
        self.assertEqual(normal, [0.0, 1.0, 0.0])
        self.assertAlmostEqual(sum(a * b for a, b in zip(normal, tangent)), 0.0, delta=1e-12)

    def test_inverse_quaternion_round_trip(self):
        quaternion = [0.1, -0.2, 0.3, 0.9]
        unit = [c / math.sqrt(sum(x * x for x in quaternion)) for c in quaternion]
        # Rotating by the quaternion and then by its inverse gives back the
        # vector; a zero quaternion has no inverse and is an error.
        moved = rotate(unit, [1.0, 2.0, 3.0])
        for component, want in zip(rotate(inverse_quaternion(unit), moved), [1.0, 2.0, 3.0]):
            self.assertAlmostEqual(component, want, delta=1e-12)
        with self.assertRaises(ValueError):
            inverse_quaternion([0.0, 0.0, 0.0, 0.0])

    def test_look_rotation_maps_basis(self):
        def assert_vector(a, b, places=9):
            for x, y in zip(a, b):
                self.assertAlmostEqual(x, y, places=places)

        assert_vector(look_rotation([0.0, 0.0, 1.0], [0.0, 1.0, 0.0]), IDENTITY)
        # +z follows the (re-normalized) forward argument...
        forward = [0.0, 0.0, 2.0]
        assert_vector(rotate(look_rotation(forward, [0.0, 1.0, 0.0]), [0.0, 0.0, 1.0]), [0.0, 0.0, 1.0])
        assert_vector(rotate(look_rotation([1.0, 0.0, 0.0], [0.0, 1.0, 0.0]), [0.0, 0.0, 1.0]),
                      [1.0, 0.0, 0.0])
        # ...and +y follows the up component orthogonalized against it:
        # [0,1,1] against a +z forward is already upright, so it only shows
        # when the forward tilts.
        up = [0.0, 1.0, 1.0]
        quaternion = look_rotation([1.0, 0.0, 0.0], up)
        y_axis = rotate(quaternion, [0.0, 1.0, 0.0])
        self.assertAlmostEqual(y_axis[0], 0.0, delta=1e-9)
        self.assertAlmostEqual(y_axis[1], math.sqrt(0.5), delta=1e-12)
        self.assertAlmostEqual(y_axis[2], math.sqrt(0.5), delta=1e-12)
        with self.assertRaises(ValueError):
            look_rotation([0.0, 0.0, 0.0], [0.0, 1.0, 0.0])

    def test_angle_between_quaternions_is_sign_blind(self):
        quaternion = [0.1, -0.2, 0.3, 0.9]
        self.assertAlmostEqual(angle_between_quaternions(quaternion, quaternion), 0.0, places=9)
        flipped = [-c for c in quaternion]
        self.assertAlmostEqual(angle_between_quaternions(quaternion, flipped), 0.0, places=6)
        yaw = angle_axis(30.0, UP)
        self.assertAlmostEqual(angle_between_quaternions(yaw, IDENTITY), 30.0, places=9)

    def test_world_local_round_trip_uses_lossy_scale(self):
        entry = node(position=[0.0, 1.5, 0.0], rotation=angle_axis(90.0, UP), lossy_scale=[2.0, 1.0, 4.0])
        point = [1.0, 1.5, 0.0]
        local = world_to_local(point, entry)
        # angle_axis(90, UP) maps +z to +x, so the inverse maps the world +x
        # offset back to +z; the z part divides by the (2,1,4) scale's 4.
        for component, want in zip(local, [0.0, 0.0, 0.25]):
            self.assertAlmostEqual(component, want, delta=1e-12)
        back = local_to_world(local, entry['position'], entry['rotation'], entry['lossyScale'])
        for component, want in zip(back, point):
            self.assertAlmostEqual(component, want, delta=1e-12)
        self.assertEqual(local_to_world([0.0, 0.0, 0.0], entry['position'],
                                        entry['rotation'], entry['lossyScale']),
                         entry['position'])

    def test_add_and_scale_validate(self):
        self.assertEqual(add([1.0, 2.0, 3.0], [0.5, 0.0, -0.5]), [1.5, 2.0, 2.5])
        self.assertEqual(scale([1.0, 2.0, 3.0], 2.0), [2.0, 4.0, 6.0])
        with self.assertRaises(ValueError):
            add([1.0, 2.0], [1.0, 2.0, 3.0])
        with self.assertRaises(ValueError):
            scale([1.0, 2.0, 3.0], float('nan'))


class BendingTests(unittest.TestCase):
    def test_bend_dead_band_and_max_branches(self):
        # The multiplier branch leads until the branches cross at
        # |angle| = 16.667 (0.4 * |angle| = |angle| - 10); past it the
        # maxAngleDifference branch dominates.
        self.assertAlmostEqual(_bend(3.0, 0.0, 0.4, 10.0), 1.2, places=12)
        self.assertAlmostEqual(_bend(15.0, 0.0, 0.4, 10.0), 6.0, places=12)
        self.assertAlmostEqual(_bend(25.0, 0.0, 0.4, 10.0), 15.0, places=12)
        self.assertAlmostEqual(_bend(40.0, 0.0, 0.4, 10.0), 30.0, places=12)
        self.assertAlmostEqual(_bend(-40.0, 0.0, 0.4, 10.0), -30.0, places=12)

    def test_bend_threshold_and_sign_multiplier(self):
        self.assertAlmostEqual(_bend(3.0, 5.0, 0.4, 10.0), 0.0, places=12)
        self.assertAlmostEqual(_bend(-8.0, 5.0, 0.4, 10.0), -1.2, places=12)
        # Math.Sign(0) == 0 keeps a zero angle zero even with the excess term.
        self.assertAlmostEqual(_bend(0.0, 2.0, 0.4, 10.0), 0.0, places=12)
        # sign(multiplier) flips the outcome and abs(multiplier) scales it
        # (30 at 40 is the maxAngleDifference branch past the crossing).
        self.assertAlmostEqual(_bend(40.0, 0.0, -0.4, 10.0), -30.0, places=12)
        self.assertAlmostEqual(_bend(-40.0, 0.0, -0.4, 10.0), 30.0, places=12)

    def test_eye_bending_mirrors_the_right_eye(self):
        # eye_bending bends first: raw 30 becomes max(0.4 * 30, 30 - 10) = 20,
        # inside both eyes' horizontal ranges.
        self.assertEqual(eye_bending(horizontal=30.0, vertical=0.0,
                                     state=TARGET_STATE, left_eye=True), (20.0, 0.0))
        self.assertEqual(eye_bending(horizontal=30.0, vertical=0.0,
                                     state=TARGET_STATE, left_eye=False), (20.0, 0.0))
        # Raw 40 bends to 30: the L clamp to (minBending, maxBending) =
        # (-36, 23) stops it at 23, the R mirrored range (-maxBending,
        # -minBending) = (-23, 36) only at its 36 ceiling (30 passes).
        self.assertEqual(eye_bending(horizontal=40.0, vertical=0.0,
                                     state=TARGET_STATE, left_eye=True), (23.0, 0.0))
        self.assertEqual(eye_bending(horizontal=40.0, vertical=0.0,
                                     state=TARGET_STATE, left_eye=False), (30.0, 0.0))
        self.assertEqual(eye_bending(horizontal=100.0, vertical=0.0,
                                     state=TARGET_STATE, left_eye=False), (36.0, 0.0))
        # Raw -40 bends to -30: the L eye's -36 floor passes it, the R
        # eye's -23 ceiling clamps it - the mirroring in one pair.
        self.assertEqual(eye_bending(horizontal=-40.0, vertical=0.0,
                                     state=TARGET_STATE, left_eye=True), (-30.0, 0.0))
        self.assertEqual(eye_bending(horizontal=-40.0, vertical=0.0,
                                     state=TARGET_STATE, left_eye=False), (-23.0, 0.0))

    def test_eye_bending_vertical_clamps(self):
        # 15 * the float32 multiplier 0.40000000596... sits just above 6.
        self.assertAlmostEqual(eye_bending(horizontal=0.0, vertical=15.0,
                                           state=TARGET_STATE, left_eye=True)[1],
                               6.0, delta=1e-7)
        self.assertEqual(eye_bending(horizontal=0.0, vertical=200.0,
                                     state=TARGET_STATE, left_eye=True)[1], 10.0)
        self.assertEqual(eye_bending(horizontal=0.0, vertical=-200.0,
                                     state=TARGET_STATE, left_eye=True)[1], -30.0)


class SorasiTests(unittest.TestCase):
    """The AWAY branch with -maxBending..-minBending = -23..36 coordinates.

    a = Lerp(-1, 1, InverseLerp(-23, 36, angle)) and f = Lerp(-23, 36, num5);
    the near branch replaces a6 by a7 +- rate, a push past +-1 clamping num5
    to the range's ends.
    """
    RATE = 0.5

    def run_case(self, previous, measured, num5=-1.0):
        return sorasi_horizontal(previous_angle=previous, measured=measured,
                                 state=TARGET_STATE, sorasi_rate=self.RATE, num5=num5)

    def test_armed_num5_determines_f_alone(self):
        for num5, want in ((0.0, -23.0), (0.25, -8.25), (1.0, 36.0)):
            f, armed = self.run_case(-100.0, 100.0, num5=num5)
            self.assertAlmostEqual(f, want, delta=1e-12)
            self.assertEqual(armed, num5)

    def test_within_rate_pushes_a6_off_a7(self):
        # a6 = -0.2373 (previous -0.5), a7 = 0.2 (measured 12.4): a6 < a7 and
        # a7 is not below -rate, so a6 := a7 - rate = -0.3 -> num5 0.35.
        f, armed = self.run_case(-0.5, 12.4)
        self.assertAlmostEqual(armed, 0.35, places=12)
        self.assertAlmostEqual(f, -23.0 + 59.0 * 0.35, places=9)
        # a6 = 0.5 (previous 21.25) > a7 = 0.0678 (measured 8.5) by 0.4322,
        # inside the rate and a7 not above +rate: a6 := a7 + rate.
        f, armed = self.run_case(21.25, 8.5)
        self.assertAlmostEqual(armed, 0.7838983050847458, places=12)
        self.assertAlmostEqual(f, 23.25, places=9)
        # Equal coordinates take the +rate side; the push past +1 saturates
        # num5 (and f) at the +36 end.
        f, armed = self.run_case(24.35, 24.35)
        self.assertAlmostEqual(armed, 1.0, places=12)
        self.assertAlmostEqual(f, 36.0, places=9)
        # A saturated num5 then determines f alone, whatever the frame's
        # previous and measured angles are.
        f, armed = self.run_case(-100.0, 100.0, num5=armed)
        self.assertAlmostEqual(f, 36.0, places=12)
        self.assertEqual(armed, 1.0)

    def test_far_apart_keeps_the_previous_angle(self):
        # a6 = -1.0 against a7 = 0.2: |a6 - a7| = 1.2 outside the rate, so f
        # stays the previous angle and num5 arms to a6's clamped coordinate.
        f, armed = self.run_case(-23.0, 12.4)
        self.assertAlmostEqual(f, -23.0, places=12)
        self.assertAlmostEqual(armed, 0.0, places=12)


class ResolveTargetTests(unittest.TestCase):
    def test_target_type_skips_the_near_pushout(self):
        effective, resolved = resolve_target(target=[0.0, 0.0, 1.0], root=node(),
                                            state=TARGET_STATE, look_type='TARGET')
        self.assertEqual(effective, 'TARGET')
        self.assertEqual(resolved, [0.0, 0.0, 1.0])

    def test_non_target_types_push_to_near_dis(self):
        root = node(position=[0.0, 1.0, 0.0])
        state = dict(TARGET_STATE, lookType='CONTROL', hAngleLimit=180.0, vAngleLimit=180.0)
        effective, resolved = resolve_target(target=[0.0, 1.0, 1.0], root=root,
                                            state=state, look_type='CONTROL')
        self.assertEqual(effective, 'CONTROL')
        for component, want in zip(resolved, [0.0, 1.0, 2.0]):
            self.assertAlmostEqual(component, want, delta=1e-12)
        # A target sitting on the root has Unity's zero normalized: it stays.
        effective, resolved = resolve_target(target=[0.0, 1.0, 0.0], root=root,
                                             state=state, look_type='CONTROL')
        self.assertEqual(resolved, [0.0, 1.0, 0.0])

    def test_limit_checks_switch_to_the_front_target(self):
        root = node(rotation=angle_axis(90.0, UP))  # forward is world +x
        effective, _ = resolve_target(target=[0.0, 0.0, 1.0], root=root,
                                      state=TARGET_STATE, look_type='TARGET')
        self.assertEqual(effective, 'TARGET')  # h = 180 not > 110, v = 0
        # Ahead of the yawed root: the horizontal check drops the direction's
        # vertical part (h = 0), and the vertical check replaces v.x with
        # root.forward.x, so the same in-plane direction reads 0 deg there too.
        effective, _ = resolve_target(target=[1.0, 0.0, 0.0], root=root,
                                      state=TARGET_STATE, look_type='TARGET')
        self.assertEqual(effective, 'TARGET')
        # ...a target behind the forward axis passes hAngleLimit.
        effective, resolved = resolve_target(target=[-10.0, 0.0, 0.0], root=root,
                                             state=TARGET_STATE, look_type='TARGET')
        self.assertEqual(effective, 'FORWARD')
        # frontCorrect: rootNode child at local position 0, local euler (5,0,0);
        # forntTagDis 50 along its forward, in the root's yawed frame.
        expected = rotate(angle_axis(90.0, UP), rotate(angle_axis(5.0, RIGHT), [0.0, 0.0, 1.0]))
        for component, want in zip(resolved, [50.0 * c for c in expected]):
            self.assertAlmostEqual(component, want, delta=1e-9)
        # The vertical check on an identity root: straight down but 0.2 ahead
        # reads 78.7 deg, inside vAngleLimit 80; at 0.05 ahead it reads 87.1
        # and switches to FORWARD.
        effective, _ = resolve_target(target=[0.0, -1.0, 0.2], root=node(),
                                      state=TARGET_STATE, look_type='TARGET')
        self.assertEqual(effective, 'TARGET')
        effective, _ = resolve_target(target=[0.0, -1.0, 0.05], root=node(),
                                      state=TARGET_STATE, look_type='TARGET')
        self.assertEqual(effective, 'FORWARD')

    def test_horizontal_check_uses_the_forward_y_part(self):
        # (v.x, root.forward.y, v.z) drops the direction's own vertical part,
        # so a high target straight ahead still reads h = 0.
        state = dict(TARGET_STATE, vAngleLimit=180.0)
        effective, _ = resolve_target(target=[0.0, -50.0, 1.0], root=node(),
                                      state=state, look_type='TARGET')
        self.assertEqual(effective, 'TARGET')


class CorrectEyeTargetsTests(unittest.TestCase):
    def test_front_frame_offsets_and_z_clamp(self):
        center = node(position=[0.0, 1.5, 0.0], lossy_scale=[2.0, 2.0, 2.0])
        left, right = correct_eye_targets(target=[0.0, 1.5, -1.0], trf_center=center,
                                          center_eye_length=0.05)
        # local z -1 clamps to 0.5, world 2.0*0.5 ahead of the center; the
        # frame forward reads the clamped point's direction (+z), up stays +y,
        # and the +-0.05 local offsets run through the 2.0 lossyScale.
        for component, want in zip(left, [-0.1, 1.5, 1.0]):
            self.assertAlmostEqual(component, want, delta=1e-12)
        for component, want in zip(right, [0.1, 1.5, 1.0]):
            self.assertAlmostEqual(component, want, delta=1e-12)

    def test_target_ahead_passes_through_unclamped(self):
        center = node(position=[0.0, 1.5, 0.0])
        left, right = correct_eye_targets(target=[0.0, 1.5, 5.0], trf_center=center,
                                          center_eye_length=0.05)
        # The target is dead ahead, so the frame forward reads +z exactly and
        # the +-0.05 offsets run out along world x with the 5.0 distance.
        self.assertEqual(left, [-0.05, 1.5, 5.0])
        self.assertEqual(right, [0.05, 1.5, 5.0])


def synthetic_geometry(*, root_rotation=None, eye_positions, trf_center=None):
    return {'eyeCalc': {'rootNode': node(rotation=root_rotation),
                        'trfCenter': trf_center or node(position=[0.0, 1.5, 0.0])},
            'eyes': [eye_geometry(index, position) for index, position in enumerate(eye_positions)]}


def zero_state():
    return {'eyes': [{'angleH': 0.0, 'angleV': 0.0, 'dirUp': [0.0, 1.0, 0.0]} for _ in range(2)]}


class EyeUpdateTests(unittest.TestCase):
    EYES = [[-0.03, 1.5, 0.0], [0.03, 1.5, 0.0]]

    def test_zero_delta_time_leaves_the_state_untouched(self):
        state = {'eyes': [{'angleH': 3.0, 'angleV': -2.0, 'dirUp': [0.0, 1.0, 0.0]},
                          {'angleH': -1.0, 'angleV': 0.5, 'dirUp': [0.0, 1.0, 0.0]}]}
        predicted = eye_update(state=state, geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[0.0, 1.5, 5.0], dt=0.0, st=TARGET_STATE, settings=SETTINGS)
        for entry, want in zip(predicted, state['eyes']):
            self.assertEqual(entry['angleH'], want['angleH'])
            self.assertEqual(entry['angleV'], want['angleV'])
            self.assertEqual(entry['dirUp'], want['dirUp'])
            self.assertIsNone(entry['localRotation'])
            self.assertIsNone(entry['rotation'])
            self.assertIsNone(entry['num5'])

    def test_no_look_is_a_diagnostic_error(self):
        with self.assertRaises(ValueError):
            eye_update(state=zero_state(), geometry=synthetic_geometry(eye_positions=self.EYES),
                       target=[0.0, 1.5, 5.0], dt=0.016, st=dict(TARGET_STATE, lookType='NO_LOOK'),
                       settings=SETTINGS)

    def test_target_frame_bends_the_eye_offsets_and_blends_half(self):
        # dt = 0.5 / leapSpeed: the blend fraction is exactly 0.5 of f.
        predicted = eye_update(state=zero_state(),
                               geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[-0.05, 1.5, 5.0], dt=0.5 / 38.0,
                               st=TARGET_STATE, settings=SETTINGS)
        # The +-centerEyeLength offsets sit on the trfCenter frame, not on the
        # eye plane: the azimuths read dx = target.x -/+ 0.05 - eye.x = -0.07
        # and -0.03, both negative and unequal, not a +-symmetric pair.
        left, right = correct_eye_targets(target=[-0.05, 1.5, 5.0],
                                          trf_center=node(position=[0.0, 1.5, 0.0]),
                                          center_eye_length=SETTINGS['centerEyeLength'])
        for entry, eye, aim in zip(predicted, self.EYES, (left, right)):
            want = 0.5 * 0.4 * math.degrees(math.atan2(aim[0] - eye[0], aim[2] - eye[2]))
            self.assertAlmostEqual(entry['angleH'], want, places=7)
            self.assertGreater(abs(predicted[0]['angleH']), abs(predicted[1]['angleH']))
            # The target sits at the eye height, so the vertical reads zero.
            self.assertAlmostEqual(entry['angleV'], 0.0, places=12)
        # The rotation writeback: A * inv(B) * origRotation with look tilting
        # about +y only, so it is exactly the horizontal angle again, and the
        # world rotation is the parent's composition (identity root here).
        for index, entry in enumerate(predicted):
            self.assertAlmostEqual(angle_between_quaternions(entry['localRotation'], IDENTITY),
                                   abs(entry['angleH']), places=7)
            for component, want in zip(entry['rotation'], entry['localRotation']):
                self.assertAlmostEqual(component, want, delta=1e-12)
        self.assertEqual([entry['num5'] for entry in predicted], [-1.0, -1.0])

    def test_vertical_reads_elevation_about_its_own_axis(self):
        # Straight ahead but below the eye plane: the vertical reads the
        # elevation out of the referenceLook/referenceUp plane around
        # Cross(refUp, dir) - the direction's own horizontal-perpendicular
        # axis - and a target depressed below that plane reads POSITIVE.
        predicted = eye_update(state=zero_state(),
                               geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[-0.03, 1.0, 5.0], dt=2.0,
                               st=TARGET_STATE, settings=SETTINGS)
        left, right = correct_eye_targets(target=[-0.03, 1.0, 5.0],
                                          trf_center=node(position=[0.0, 1.5, 0.0]),
                                          center_eye_length=SETTINGS['centerEyeLength'])
        for entry, eye, aim in zip(predicted, self.EYES, (left, right)):
            dx, dy, dz = (aim[i] - eye[i] for i in range(3))
            self.assertGreater(entry['angleV'], 0.0)
            self.assertAlmostEqual(
                entry['angleV'], 0.4 * math.degrees(math.atan2(-dy, math.hypot(dx, dz))),
                places=6)
            # dt * 5 is past 1, so dirUp lands on the OrthoNormalize tangent:
            # a unit vector leaning toward the pitched-down look.
            self.assertAlmostEqual(sum(c * c for c in entry['dirUp']), 1.0, delta=1e-9)
            self.assertGreater(entry['dirUp'][2], 0.0)

    def test_full_blend_writes_look_and_dir_up(self):
        # dt * leapSpeed saturates the blend at 1.
        predicted = eye_update(state=zero_state(),
                               geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[-0.05, 1.5, 5.0], dt=1.0,
                               st=TARGET_STATE, settings=SETTINGS)
        left, right = correct_eye_targets(target=[-0.05, 1.5, 5.0],
                                          trf_center=node(position=[0.0, 1.5, 0.0]),
                                          center_eye_length=SETTINGS['centerEyeLength'])
        for entry, eye, aim in zip(predicted, self.EYES, (left, right)):
            self.assertAlmostEqual(
                entry['angleH'], 0.4 * math.degrees(math.atan2(aim[0] - eye[0], aim[2] - eye[2])),
                places=7)
            self.assertAlmostEqual(entry['angleV'], 0.0, places=12)
            # A purely horizontal look keeps +y upright: OrthoNormalize's
            # tangent is +y, Vector3.Slerp over a zero arc leaves dirUp at it.
            for component, want in zip(entry['dirUp'], [0.0, 1.0, 0.0]):
                self.assertAlmostEqual(component, want, delta=1e-9)
            # look . dirUp is orthogonalized and the rotation is a small tilt.
            look = rotate(entry['localRotation'], [0.0, 0.0, 1.0])
            self.assertAlmostEqual(sum(a * b for a, b in zip(look, entry['dirUp'])), 0.0, places=9)
            self.assertGreater(angle_between_quaternions(entry['localRotation'], IDENTITY), 0.0)

    def test_right_eye_horizontal_mirrors_through_the_clamp(self):
        # A 75 deg left azimuth bends to -65.6 (past the branch crossing the
        # |angle| - 10 term leads): the L eye's (-36, 23) range clamps it at
        # the -36 floor, the R eye's mirrored (-23, 36) range at -23 - and a
        # previous +100 blended at dt * leapSpeed 38 lands fully on f.
        state = {'eyes': [{'angleH': 100.0, 'angleV': 0.0, 'dirUp': [0.0, 1.0, 0.0]},
                          {'angleH': 100.0, 'angleV': 0.0, 'dirUp': [0.0, 1.0, 0.0]}]}
        predicted = eye_update(state=state,
                               geometry=synthetic_geometry(eye_positions=[[0.0, 1.5, 0.0]] * 2),
                               target=[-19.3, 1.5, 5.0], dt=1.0,
                               st=TARGET_STATE, settings=SETTINGS)
        self.assertAlmostEqual(predicted[0]['angleH'], -36.0, places=9)
        self.assertAlmostEqual(predicted[1]['angleH'], -23.0, places=9)
        # Each eye's writeback is LookRotation of the clamped yaw, so the
        # rotation error against identity is the clamped angle itself.
        for entry, want in zip(predicted, (-36.0, -23.0)):
            self.assertAlmostEqual(angle_between_quaternions(entry['localRotation'], IDENTITY),
                                   abs(want), places=7)

    def test_forward_type_aims_at_the_front_point(self):
        # FORWARD ptn (run1 pattern 0): leap 22.8, forntTagDis 1.0.
        state = dict(TARGET_STATE, lookType='FORWARD', leapSpeed=22.799999237060547,
                     forntTagDis=1.0, hAngleLimit=110.0, vAngleLimit=80.0)
        predicted = eye_update(state=zero_state(),
                               geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[0.0, 1.5, 5.0], dt=1.0, st=state, settings=SETTINGS)
        # The front point is forntTagDis 1.0 ahead of the root pitched 5 deg
        # down, well below the eye plane (y 1.5): the vertical reads a large
        # elevation, clamped at downBendingAngle 10 (positive reads down here).
        _, front = resolve_target(target=[0.0, 1.5, 5.0], root=node(),
                                  state=state, look_type='FORWARD')
        for component, want in zip(front, [0.0, -math.sin(math.radians(5.0)),
                                           math.cos(math.radians(5.0))]):
            self.assertAlmostEqual(component, want, delta=1e-9)
        # The front frame's +-centerEyeLength offsets make the horizontal
        # antisymmetric: the L eye turns left, the R eye right, both by the
        # bent azimuth to the shared front point.
        left, right = correct_eye_targets(target=front,
                                          trf_center=node(position=[0.0, 1.5, 0.0]),
                                          center_eye_length=SETTINGS['centerEyeLength'])
        for entry, eye, aim in zip(predicted, self.EYES, (left, right)):
            want = 0.4 * math.degrees(math.atan2(aim[0] - eye[0], aim[2] - eye[2]))
            self.assertAlmostEqual(entry['angleH'], want, places=7)
            self.assertAlmostEqual(entry['angleV'], 10.0, places=9)
        self.assertLess(predicted[0]['angleH'], 0.0)
        self.assertAlmostEqual(predicted[0]['angleH'], -predicted[1]['angleH'], places=12)

    def test_limit_switch_to_forward_inside_a_target_pattern(self):
        # A target behind the TARGET pattern's hAngleLimit reads FORWARD: the
        # aim becomes the front point (forntTagDis 50, pitched 5 deg down, so
        # 4.36 below the root), not the raw target 78 deg to the left. The
        # elevation to that distant front point reads a small POSITIVE angle
        # (0.4 * atan(5.86 / 49.8) = 2.68, the same sign convention as the
        # elevation test), and the front frame offsets keep the horizontal
        # antisymmetric at the bent +-0.023 deg azimuth.
        predicted = eye_update(state=zero_state(),
                               geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[-10.0, 1.5, 0.0], dt=1.0,
                               st=TARGET_STATE, settings=SETTINGS)
        front_y = -50.0 * math.sin(math.radians(5.0))
        front_z = 50.0 * math.cos(math.radians(5.0))
        for entry, eye, aim_x in zip(predicted, self.EYES, (-SETTINGS['centerEyeLength'],
                                                            SETTINGS['centerEyeLength'])):
            self.assertAlmostEqual(
                entry['angleV'],
                0.4 * math.degrees(math.atan2(eye[1] - front_y,
                                              math.hypot(aim_x - eye[0], front_z))),
                places=6)
            self.assertAlmostEqual(
                entry['angleH'],
                0.4 * math.degrees(math.atan2(aim_x - eye[0], front_z)), places=7)
        self.assertLess(predicted[0]['angleH'], 0.0)
        self.assertAlmostEqual(predicted[0]['angleH'], -predicted[1]['angleH'], places=12)

    def test_away_sorasi_arms_on_the_left_and_negates_vertical(self):
        # AWAY is outside TARGET/FORWARD so correctEyeTargets is skipped and
        # both eyes aim at the same point 0.5 up: azimuths +-0.03 of x read
        # +-0.1375 once bent, the elevation reads -5.71 * 0.4 (above the
        # reference plane is negative) and AWAY negates it to +2.284.
        state = {'eyes': [{'angleH': 5.0, 'angleV': 1.0, 'dirUp': [0.0, 1.0, 0.0]} for _ in range(2)]}
        predicted = eye_update(state=state,
                               geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[0.0, 2.0, 5.0], dt=1.0,
                               st=AWAY_STATE, settings=SETTINGS)
        # The L eye arms num5: a6 = -3/59 (previous 5), a7 = the bent L-eye
        # azimuth's coordinate; a6 > a7 by less than sorasiRate 1 and a7 is
        # not above it, so a6 := a7 + sorasiRate = 0.78432 -> num5 0.89216.
        # The R eye reads that armed num5, so both eyes land on the same f.
        h_left = 0.4 * math.degrees(math.atan2(0.03, 5.0))
        a7 = lerp(-1.0, 1.0, inverse_lerp(-23.0, 36.0, h_left))
        armed = inverse_lerp(-1.0, 1.0, a7 + SETTINGS['sorasiRate'])
        f = lerp(-23.0, 36.0, armed)
        self.assertGreater(armed, 0.5)
        self.assertLess(armed, 1.0)
        for entry in predicted:
            self.assertAlmostEqual(entry['num5'], armed, places=9)
            self.assertAlmostEqual(entry['angleH'], f, places=6)
            self.assertAlmostEqual(
                entry['angleV'], 0.4 * math.degrees(math.atan2(0.5, math.hypot(0.03, 5.0))),
                places=6)

    def test_away_sorasi_far_branch_keeps_the_carried_angle(self):
        # A strong leftward aim (bent -12.18, a7 = -0.596) against a previous
        # angleH at the +36 end (a6 = 1): |a6 - a7| = 1.596 > sorasiRate 1.0,
        # so f stays at the carried angleH and num5 arms to a6's coordinate.
        state = {'eyes': [{'angleH': 36.0, 'angleV': 0.0, 'dirUp': [0.0, 1.0, 0.0]} for _ in range(2)]}
        predicted = eye_update(state=state,
                               geometry=synthetic_geometry(eye_positions=self.EYES),
                               target=[-1.06, 1.5, 5.0], dt=1.0,
                               st=AWAY_STATE, settings=SETTINGS)
        self.assertAlmostEqual(predicted[0]['angleH'], 36.0, places=6)
        self.assertAlmostEqual(predicted[0]['num5'], 1.0, places=9)


if __name__ == '__main__':
    unittest.main()
