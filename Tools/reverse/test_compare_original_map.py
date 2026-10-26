"""ST-A11 map comparison: the independent Quaternion.Euler, the basis and matrix layout, and
every gate and control on small synthetic captures. No VM or private data is needed."""
import copy, gzip, json, math, tempfile, unittest, zlib
from pathlib import Path
import numpy as np
from PIL import Image
import compare_original_map as compare

W, H, FAR = 32, 24, 25.0


def rotation(axis, degrees):
    c, s = math.cos(math.radians(degrees)), math.sin(math.radians(degrees))
    return {'x': np.array([[1, 0, 0], [0, c, -s], [0, s, c]]),
            'y': np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]]),
            'z': np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])}[axis]


def quaternion_rotation(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def column_major(m):
    return [float(v) for v in np.asarray(m).T.reshape(16)]


def save(path, pixels):
    Image.fromarray(pixels.astype(np.uint8), 'RGBA').save(path)


class EulerTests(unittest.TestCase):
    def test_single_axes_match_known_quaternions(self):
        h = math.sqrt(0.5)
        np.testing.assert_allclose(compare.unity_euler([90, 0, 0]), [h, 0, 0, h], atol=1e-12)
        np.testing.assert_allclose(compare.unity_euler([0, 90, 0]), [0, h, 0, h], atol=1e-12)
        np.testing.assert_allclose(compare.unity_euler([0, 0, 90]), [0, 0, h, h], atol=1e-12)

    def test_unity_order_is_z_then_x_then_y(self):
        q = compare.unity_euler([4, 25, -3])
        expected = rotation('y', 25) @ rotation('x', 4) @ rotation('z', -3)
        np.testing.assert_allclose(quaternion_rotation(q), expected, atol=1e-12)

    def test_the_wrong_order_differs_beyond_the_rule_tolerance(self):
        degrees = compare.angle_degrees(compare.unity_euler([4, 25, -3]), compare.unity_euler([4, 25, -3], 'xyz'))
        self.assertGreater(degrees, 1e-3)
        # One nonzero axis: every order is the same rotation (acos rounding stays far below 1e-3).
        self.assertLess(compare.angle_degrees(compare.unity_euler([0, 25, 0]), compare.unity_euler([0, 25, 0], 'xyz')), 1e-5)

    def test_angle_ignores_quaternion_sign(self):
        q = compare.unity_euler([10, 20, 30])
        self.assertLess(compare.angle_degrees(q, -q), 1e-5)

    def test_matrix_reads_column_major(self):
        m = compare.matrix(list(range(16)))
        self.assertEqual(m[0, 1], 4); self.assertEqual(m[1, 0], 1); self.assertEqual(m[3, 2], 11)


class CaseFixture(unittest.TestCase):
    """A consistent original trace and our capture in temporary folders (no tests of its own)."""
    POS, ROT = [0.3, -0.05, -0.5], [4, 25, -3]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); root = Path(self.tmp.name)
        self.original, self.ours = root / 'original', root / 'ours'
        self.original.mkdir(); self.ours.mkdir()
        self.write(self.POS, self.ROT)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, pos, rot, ours_rot=None, view_offset=0.0, ours_mask_shift=0):
        """A consistent original trace and our capture; `ours_rot` places our map root with
        another rotation, `view_offset` moves our camera, `ours_mask_shift` moves our silhouette."""
        unity = np.eye(4); unity[:3, :3] = quaternion_rotation(compare.unity_euler(rot)); unity[:3, 3] = pos
        ours = np.eye(4); ours[:3, :3] = quaternion_rotation(compare.unity_euler(ours_rot or rot)); ours[:3, 3] = pos
        ours = compare.BASIS @ ours @ compare.BASIS
        world_to_camera = np.eye(4); world_to_camera[:3, 3] = [0.1, -1.2, 2.0]
        view = world_to_camera @ compare.BASIS; view[0, 3] += view_offset
        settled = dict(mapRoot=dict(localPosition=pos, localRotation=list(compare.unity_euler(rot)), lossyScale=[1, 1, 1],
                                    localToWorld=column_major(unity)),
                       caMap=dict(pos=pos, rot=rot), sceneInfoMap=33)
        trace = dict(mapNo=33, depthFar=FAR, width=W, height=H,
                     cases={'c': dict(scene='scene.png', sceneSHA256='ab' * 32, settled=settled,
                                      capture=dict(main=dict(worldToCamera=column_major(world_to_camera), fieldOfView=45.0)))})
        (self.original / 'map-trace.json').write_text(json.dumps(trace))
        native = dict(depthFar=FAR, width=W, height=H, map=33, sceneSHA256='ab' * 32,
                      transform=dict(position=pos, rotationDegrees=rot), mapRoot=column_major(ours),
                      camera=dict(view=column_major(view), fovDegrees=45.0),
                      draws=[dict(model=column_major(ours), objectID=0, pickOccluder=True, castsShadow=False, outline=False)] * 2)
        (self.ours / 'native-map.json').write_text(json.dumps(native))
        # A wall silhouette whose encoded depth steps one EncodeFloatRG high byte per column.
        def images(shift):
            geometry = np.zeros((H, W, 4)); geometry[..., 3] = 255
            geometry[4:20, 6 + shift:26 + shift, :3] = 255
            depth = np.full((H, W, 4), 255.0); depth[..., 0] = 128; depth[..., 1] = 100
            depth[..., 2] = np.arange(W)[None, :] * 3; depth[..., 3] = 7
            return geometry, depth
        for folder, prefix, shift in ((self.original, 'original-c-', 0), (self.ours, 'native-', ours_mask_shift)):
            geometry, depth = images(shift)
            save(folder / (prefix + 'map-geometry.png'), geometry)
            save(folder / (prefix + 'map-depth-normals.png'), depth)
            save(folder / (prefix + 'color.png'), np.full((H, W, 4), 90 if shift else 80))

    def run_case(self):
        return compare.compare(self.original, [('c', self.ours)])['cases'][0]


class CaseTests(CaseFixture):

    def test_a_consistent_capture_passes_every_gate_and_both_controls_fail(self):
        case = self.run_case()
        self.assertTrue(case['passes'], json.dumps(case, indent=1, default=str))
        self.assertLess(case['rule']['rotationErrorDegrees'], 1e-5)
        self.assertEqual(case['geometry']['intersectionOverUnion'], 1.0)
        self.assertEqual(case['depthNormals']['p99Metres'], 0.0)
        self.assertTrue(case['depthNormals']['onePixelShiftControl']['fails'])
        self.assertTrue(case['rule']['wrongEulerOrderControl']['applicable'] and case['rule']['wrongEulerOrderControl']['fails'])
        self.assertFalse(case['color']['gated'])

    def test_a_map_root_in_the_wrong_euler_order_fails_placement(self):
        native = json.loads((self.ours / 'native-map.json').read_text())
        wrong = np.eye(4); wrong[:3, :3] = quaternion_rotation(compare.unity_euler(self.ROT, 'xyz')); wrong[:3, 3] = self.POS
        native['mapRoot'] = column_major(compare.BASIS @ wrong @ compare.BASIS)
        (self.ours / 'native-map.json').write_text(json.dumps(native))
        case = self.run_case()
        self.assertFalse(case['placement']['passes']); self.assertFalse(case['passes'])

    def test_a_moved_camera_and_a_shifted_silhouette_fail(self):
        self.write(self.POS, self.ROT, view_offset=1e-3)
        self.assertFalse(self.run_case()['camera']['passes'])
        self.write(self.POS, self.ROT, ours_mask_shift=1)
        case = self.run_case()
        self.assertFalse(case['geometry']['passes']); self.assertFalse(case['passes'])

    def test_a_draw_that_picks_casts_shadows_or_leaves_the_root_fails(self):
        native = json.loads((self.ours / 'native-map.json').read_text())
        for change in (dict(objectID=7), dict(pickOccluder=False), dict(castsShadow=True), dict(outline=True)):
            edited = copy.deepcopy(native); edited['draws'][1].update(change)
            (self.ours / 'native-map.json').write_text(json.dumps(edited))
            self.assertFalse(self.run_case()['placement']['passes'], change)
        edited = copy.deepcopy(native); edited['draws'][1]['model'][12] += 1e-3
        (self.ours / 'native-map.json').write_text(json.dumps(edited))
        self.assertFalse(self.run_case()['placement']['passes'])

    def test_a_record_mismatch_fails(self):
        native = json.loads((self.ours / 'native-map.json').read_text())
        native['transform']['rotationDegrees'][1] += 1e-4
        (self.ours / 'native-map.json').write_text(json.dumps(native))
        self.assertFalse(self.run_case()['record']['passes'])

    def test_a_zero_rotation_makes_the_euler_control_inapplicable_but_still_passes(self):
        self.write(self.POS, [0, 0, 0])
        case = self.run_case()
        self.assertFalse(case['rule']['wrongEulerOrderControl']['applicable'])
        self.assertTrue(case['passes'])

    def test_another_size_or_far_plane_is_refused(self):
        native = json.loads((self.ours / 'native-map.json').read_text()); native['depthFar'] = 1000
        (self.ours / 'native-map.json').write_text(json.dumps(native))
        with self.assertRaisesRegex(ValueError, 'size and far plane'):
            self.run_case()



class OracleTests(CaseFixture):
    """The --oracle sections: cleanColor, the irradiance gate with its two negative controls, irradianceLit."""
    def setUp(self):
        super().setUp()
        self.oracle = Path(self.tmp.name) / 'oracle'; self.oracle.mkdir()
        # One wall whose depth rises three low-byte steps per column: smooth for the interior test,
        # steep enough for the one-pixel-shift depth control to fail.
        flat = self.wall()
        save(self.original / 'original-c-map-depth-normals.png', flat); save(self.ours / 'native-map-depth-normals.png', flat)
        rows, cols = np.mgrid[0:H, 0:W]
        self.unity = np.stack([0.5 + cols / W, 1.0 + rows / H, np.full((H, W), 1.5)], axis=-1)
        self.write_oracle(self.unity)
        self.write_ours({'decoded': self.unity, 'nonDirectional': self.unity * 0.8, 'gammaConstants': self.unity * 0.3})

    @staticmethod
    def wall():
        image = np.full((H, W, 4), 255.0); image[..., 0] = 128; image[..., 1] = 100; image[..., 2] = 40
        image[..., 3] = np.arange(W)[None, :] * 3
        return image

    def write_oracle(self, unity, lit=None, repeat=0.0):
        for name, image in (('oracle-c-irradiance.f32', unity), ('oracle-c-irradiance-lit.f32', unity if lit is None else lit)):
            (self.oracle / (name + '.gz')).write_bytes(gzip.compress(image.astype('<f4').tobytes()))
        save(self.oracle / 'oracle-c-clean-color.png', np.full((H, W, 4), 70))
        trace = dict(width=W, height=H, cases={'c': dict(sceneSHA256='ab' * 32, oracle=dict(
            clean=dict(image='oracle-c-clean-color.png'),
            irradiance=dict(file='oracle-c-irradiance.f32', repeatMaximumDifference=repeat),
            irradianceLit=dict(file='oracle-c-irradiance-lit.f32')))})
        (self.oracle / 'oracle-trace.json').write_text(json.dumps(trace))

    def write_ours(self, variants):
        native = json.loads((self.ours / 'native-map.json').read_text())
        files = {}
        for variant, image in variants.items():
            rgba = np.concatenate([image, np.ones((H, W, 1))], axis=-1).astype('<f2').tobytes()
            packer = zlib.compressobj(wbits=-15); data = packer.compress(rgba) + packer.flush()
            files[variant] = f'native-map-irradiance-{variant}.rgba16f.deflate'
            (self.ours / files[variant]).write_bytes(data)
        native['irradiance'] = dict(written=bool(variants), files=files)
        native['census'] = dict(lightmappedDraws=2 if variants else 0)
        (self.ours / 'native-map.json').write_text(json.dumps(native))

    def run_oracle(self):
        return compare.compare(self.original, [('c', self.ours)], self.oracle)['cases'][0]

    def test_a_matching_irradiance_passes_and_both_controls_fail(self):
        case = self.run_oracle()
        self.assertTrue(case['passes'], json.dumps(case, indent=1, default=str))
        irradiance = case['irradiance']
        self.assertTrue(irradiance['gated'] and irradiance['passes'])
        self.assertLess(irradiance['p99Relative'], 1e-3)  # float16 rounding only
        self.assertEqual(irradiance['interior']['pixels'], 14 * 18)  # the silhouette eroded by one pixel
        self.assertTrue(all(c['fails'] for c in irradiance['controls'].values()))
        self.assertEqual(case['cleanColor']['meanAbsoluteChannelBytes'], 10.0)
        self.assertEqual(case['irradianceLit']['pixelsAddedOverOnePercent'], 0)
        self.assertIn('baked lightmaps are drawn', case['color']['reason'])

    def test_a_wrong_decode_a_control_that_passes_or_an_unrepeatable_oracle_fails(self):
        self.write_ours({'decoded': self.unity * 1.05, 'nonDirectional': self.unity * 0.8, 'gammaConstants': self.unity * 0.3})
        case = self.run_oracle()
        self.assertFalse(case['irradiance']['passes']); self.assertFalse(case['passes'])
        self.write_ours({'decoded': self.unity, 'nonDirectional': self.unity, 'gammaConstants': self.unity * 0.3})
        case = self.run_oracle()
        self.assertFalse(case['irradiance']['controls']['nonDirectional']['fails']); self.assertFalse(case['passes'])
        self.write_ours({'decoded': self.unity, 'nonDirectional': self.unity * 0.8, 'gammaConstants': self.unity * 0.3})
        self.write_oracle(self.unity, repeat=1e-6)
        self.assertFalse(self.run_oracle()['passes'])

    def test_depth_steps_leave_the_interior_and_lit_pixels_are_counted(self):
        step = self.wall(); step[:, 16:, 2] = 80  # a wall twice as far from column 16 on
        save(self.original / 'original-c-map-depth-normals.png', step); save(self.ours / 'native-map-depth-normals.png', step)
        lit = self.unity.copy(); lit[10, 10] += 0.5
        self.write_oracle(self.unity, lit=lit)
        case = self.run_oracle()
        self.assertEqual(case['irradiance']['interior']['pixels'], 14 * 18 - 14 * 2)
        self.assertEqual(case['irradianceLit']['pixelsAddedOverOnePercent'], 1)
        self.assertAlmostEqual(case['irradianceLit']['maximumAdded'], 0.5, places=5)

    def test_a_capture_without_lightmaps_reports_without_the_gate(self):
        self.write_ours({})
        case = self.run_oracle()
        self.assertFalse(case['irradiance']['gated']); self.assertTrue(case['passes'])
        self.assertIn('item toon material', case['color']['reason'])

if __name__ == '__main__':
    unittest.main()
