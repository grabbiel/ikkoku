"""Contract tests for the character-light mapping helpers.

Checks are hand-computed closed forms for the Euler/quaternion helpers plus two
synthetic rigs run through ``analyze``: a camera-attached one whose true mapping
(Q1 above transRoot, Q2 below it) is known in advance, and a scene-static one
that must be reported as *not* camera-relative.
"""
import math
import unittest

import chara_light_mapping as m


def close(test, left, right, places=6):
    test.assertEqual(len(left), len(right))
    for a, b in zip(left, right):
        test.assertAlmostEqual(a, b, places=places, msg='%r != %r' % (left, right))


def _xyzw(q):
    w, x, y, z = q
    return [x, y, z, w]


class QuaternionHelperTests(unittest.TestCase):
    def test_xyzw_conversion(self):
        self.assertEqual(m.quat_xyzw((1, 2, 3, 4)), (4, 1, 2, 3))

    def test_from_euler_cardinal_axes(self):
        c = math.sqrt(0.5)
        close(self, m.quat_from_euler((0, 0, 0)), (1, 0, 0, 0))
        close(self, m.quat_from_euler((90, 0, 0)), (c, c, 0, 0))
        close(self, m.quat_from_euler((0, 90, 0)), (c, 0, c, 0))
        close(self, m.quat_from_euler((0, 0, 90)), (c, 0, 0, c))

    def test_from_euler_is_ry_rx_rz(self):
        # Quaternion.Euler applies the Z-X-Y composition Ry * Rx * Rz.
        s30, c30 = math.sin(math.radians(15)), math.cos(math.radians(15))
        s45, c45 = math.sin(math.radians(22.5)), math.cos(math.radians(22.5))
        close(self, m.quat_from_euler((30, 45, 0)), m.quat_mul((c45, 0, s45, 0), (c30, s30, 0, 0)))

    def test_hamilton_product(self):
        i, j, k = (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1)
        close(self, m.quat_mul(i, j), k)
        close(self, m.quat_mul(j, i), (0, 0, 0, -1))  # j*i = -k; quat_angle_deg is sign-insensitive

    def test_conjugate_inverts(self):
        q = m.quat_from_euler((17, -63, 8))
        close(self, m.quat_mul(q, m.quat_conj(q)), (1, 0, 0, 0))

    def test_rotate_matches_euler_intuitions(self):
        close(self, m.quat_rotate(m.quat_from_euler((0, 90, 0)), (0, 0, 1)), (1, 0, 0), places=5)
        close(self, m.quat_rotate(m.quat_from_euler((0, 90, 0)), (1, 0, 0)), (0, 0, -1), places=5)
        close(self, m.quat_rotate(m.quat_from_euler((90, 0, 0)), (0, 1, 0)), (0, 0, 1), places=5)

    def test_forward_is_rotated_plus_z(self):
        close(self, m.forward_of(m.quat_from_euler((0, 90, 0))), (1, 0, 0), places=5)

    def test_angle_is_sign_insensitive(self):
        q = m.quat_from_euler((0, 10, 0))
        self.assertAlmostEqual(m.quat_angle_deg((1, 0, 0, 0), q), 10.0, places=5)
        self.assertAlmostEqual(m.quat_angle_deg(q, tuple(-c for c in q)), 0.0, places=9)


class ChainProductTests(unittest.TestCase):
    def test_empty_is_identity(self):
        self.assertEqual(m._chain_product([]), (1, 0, 0, 0))

    def test_orders_ancestor_first(self):
        a = m.quat_from_euler((10, 0, 0))
        b = m.quat_from_euler((0, 20, 0))
        # Lightwards-first [aChild under bChild] means the world factor b * a.
        close(self, m._chain_product([a, b]), m.quat_mul(b, a))

    def test_variation_zero_on_empty_level(self):
        self.assertEqual(m._variation([[], []]), 0.0)


class CameraAttachedRigTests(unittest.TestCase):
    """Fabricated trace: chain light <- Q2 <- transRoot(Euler(rot)) <- Q1 <-
    Camera.main. The true mapping is camera-relative, so analyze must recover
    the split and mark cameraRelativeValid."""

    Q1 = m.quat_from_euler((10, 20, 0))
    Q2 = m.quat_from_euler((-5, 7, 3))
    CAMERAS = {'default': m.quat_from_euler((5, -30, 0)), 'tilt': m.quat_from_euler((20, 135, 0))}
    ROTS = [(0.0, 0.0), (30.0, -45.0), (-20.0, 90.0), (10.0, 180.0)]

    def _trace(self):
        records = []
        for pose in ('default', 'tilt'):
            c = self.CAMERAS[pose]
            for rot in self.ROTS:
                r = m.quat_from_euler((rot[0], rot[1], 0))
                world = m.quat_mul(m.quat_mul(c, self.Q1), m.quat_mul(r, self.Q2))
                chain = [dict(name='Spot Light', localRotation=_xyzw(self.Q2)),
                         dict(name='TransRoot', localRotation=_xyzw(r)),
                         dict(name='CameraRoot', localRotation=_xyzw(self.Q1)),
                         dict(name='Camera', localRotation=_xyzw(c))]
                records.append(dict(cameraPose=pose, rot=list(rot),
                                    camera=dict(rotation=_xyzw(c)),
                                    lights=[dict(name='Spot Light', type=1, enabled=True,
                                                 color=[0.9, 0.7, 0.5], intensity=1.3, shadows=0,
                                                 worldRotation=_xyzw(world), chain=chain)]))
        return dict(records=records)

    def test_identifies_transroot_and_recovers_factors(self):
        report = m.analyze(self._trace())
        self.assertEqual(report['transRootChainIndex'], 1)
        self.assertEqual(report['transRootName'], 'TransRoot')
        self.assertLess(report['transRootLocalRotationMaxErrorDeg'], 1e-9)
        close(self, report['qLight'], self.Q2, places=5)
        close(self, report['qRoot'], m.quat_mul(self.CAMERAS['default'], self.Q1), places=5)
        close(self, report['qBase'], m.quat_mul(self.Q1, self.Q2), places=5)
        self.assertLess(report['qLightMaxVariationDeg'], 1e-9)

    def test_formula_verified_on_every_record(self):
        report = m.analyze(self._trace())
        self.assertLess(report['maxErrorDeg'], 1e-9)

    def test_camera_relative_formula_holds(self):
        report = m.analyze(self._trace())
        self.assertLess(report['qBaseCameraPoseSpreadDeg'], 1e-9)
        self.assertLess(report['cameraFitResidualDeg'], 1e-9)
        self.assertTrue(report['cameraRelativeValid'])

    def test_camera_space_forward_matches_split_formula(self):
        report = m.analyze(self._trace())
        self.assertEqual(len(report['records']), 8)
        for record in report['records']:
            expected = m.quat_rotate(
                m.quat_mul(m.quat_mul(self.Q1, m.quat_from_euler((record['rot'][0], record['rot'][1], 0))),
                           self.Q2), (0, 0, 1))
            close(self, record['cameraSpaceForward'], expected, places=5)


class SceneStaticRigTests(unittest.TestCase):
    """Mimics the real capture: the chain (light local, transRoot Euler(rot),
    static root) is camera-independent while the camera moves, so no
    camera-relative mapping may be claimed."""

    QLIGHT = m.quat_mul(m.quat_from_euler((0, 180, 0)), m.quat_from_euler((40, 0, 0)))
    CAMERAS = {'default': m.quat_from_euler((-90.0 - 5.7, 180, 90)), 'tilt': m.quat_from_euler((20, 135, 0))}

    def _trace(self):
        records = []
        for pose in ('default', 'tilt'):
            c = self.CAMERAS[pose]
            for rot in ((0.0, 0.0), (30.0, -45.0), (-20.0, 90.0), (10.0, 180.0)):
                r = m.quat_from_euler((rot[0], rot[1], 0))
                world = m.quat_mul(r, self.QLIGHT)  # no camera factor anywhere
                chain = [dict(name='Directional Chara', localRotation=_xyzw(self.QLIGHT)),
                         dict(name='Light Chara', localRotation=_xyzw(r)),
                         dict(name='StudioScene', localRotation=_xyzw((1, 0, 0, 0)))]
                records.append(dict(cameraPose=pose, rot=list(rot),
                                    camera=dict(rotation=_xyzw(c)),
                                    lights=[dict(name='Directional Chara', type=1, enabled=True,
                                                 color=[0.9, 0.7, 0.5], intensity=1.3, shadows=0,
                                                 worldRotation=_xyzw(world), chain=chain)]))
        return dict(records=records)

    def test_chain_formula_holds_but_camera_relative_rejected(self):
        report = m.analyze(self._trace())
        self.assertEqual(report['transRootChainIndex'], 1)
        self.assertLess(report['maxErrorDeg'], 1e-9)  # chain product is still exact
        close(self, report['qRoot'], (1, 0, 0, 0), places=9)
        close(self, report['qLight'], self.QLIGHT, places=5)
        self.assertGreater(report['qBaseCameraPoseSpreadDeg'], 1.0)  # camera-space light moves with the camera
        self.assertGreater(report['cameraFitResidualDeg'], 1.0)
        self.assertFalse(report['cameraRelativeValid'])

    def test_same_rot_gives_same_world_rotation_across_poses(self):
        report = m.analyze(self._trace())
        by_rot = {}
        for record in report['records']:
            by_rot.setdefault(tuple(record['rot']), []).append(record)
        for records in by_rot.values():
            first = records[0]['lightCameraSpace']
            for other in records[1:]:  # camera-space differs, so camera independence must be visible
                self.assertGreater(m.quat_angle_deg(first, other['lightCameraSpace']), 1.0)


if __name__ == '__main__':
    unittest.main()
