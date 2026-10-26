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


class Slice3Tests(OracleTests):
    """Map 34: the sun type, sky placement, the class-restricted irradiance, the sky gate and particles."""
    def setUp(self):
        super().setUp()
        rows, cols = np.mgrid[0:H, 0:W]
        self.sky = np.stack([0.2 + cols / W, 0.4 + rows / H, np.full((H, W), 0.9), np.ones((H, W))], axis=-1)
        self.leaves = np.zeros((H, W, 4)); self.leaves[2:6, 3:9, :3] = [0.1, 0.3, 0.05]

    def add_oracle(self, sky=True, particles=True, classes=None, combined=False):
        trace = json.loads((self.oracle / 'oracle-trace.json').read_text())
        measured = trace['cases']['c']['oracle']
        if sky:
            (self.oracle / 'oracle-c-sky.rgba.f32.gz').write_bytes(gzip.compress(self.sky.astype('<f4').tobytes()))
            measured['sky'] = dict(written=True, file='oracle-c-sky.rgba.f32')
        if particles:
            (self.oracle / 'oracle-c-particles.rgba.f32.gz').write_bytes(gzip.compress(self.leaves.astype('<f4').tobytes()))
            measured['particles'] = dict(written=True, file='oracle-c-particles.rgba.f32')
        if classes is not None:
            save(self.oracle / 'oracle-c-classes.png', classes)
            measured['classes'] = dict(image='oracle-c-classes.png', counts=dict(lightmappedRenderers=1))
        if combined:  # one map34 folder: the oracle sits in map-trace.json next to the phase B records
            original = json.loads((self.original / 'map-trace.json').read_text())
            original['cases']['c']['oracle'] = measured
            (self.original / 'map-trace.json').write_text(json.dumps(original))
            for f in self.oracle.iterdir(): f.rename(self.original / f.name)
            (self.original / 'oracle-trace.json').unlink()
            self.oracle = self.original
        else:
            (self.oracle / 'oracle-trace.json').write_text(json.dumps(trace))

    def write_ours_groups(self, sky=None, rotation=291.0, particles=None, particle_controls=None):
        native = json.loads((self.ours / 'native-map.json').read_text())
        def deflate(image, name):
            packer = zlib.compressobj(wbits=-15)
            (self.ours / name).write_bytes(packer.compress(image.astype('<f2').tobytes()) + packer.flush())
        if sky is not None:
            files = {}
            for variant, image in sky.items():
                files[variant] = f'native-map-sky-{variant}.rgba16f.deflate'; deflate(image, files[variant])
            native['sky'] = dict(written=True, files=files, rotationDegrees=[rotation])
        if particles is not None:
            controls = particle_controls or dict(noDoubling=particles * 0.5, gammaTint=particles * np.array([1.25, 1.4, 1.4, 1]))
            files = {}
            for variant, image in dict(decoded=particles, **controls).items():
                files[variant] = f'native-map-particles-{variant}.rgba16f.deflate'; deflate(image, files[variant])
            native['particles'] = dict(written=True, files=files)
        (self.ours / 'native-map.json').write_text(json.dumps(native))

    def sky_variants(self, decoded=None, flipped=None, unrotated=None, gamma=None):
        base = self.sky if decoded is None else decoded
        return dict(decoded=base, rowsFlipped=self.sky[::-1] if flipped is None else flipped,
                    rotationIgnored=np.roll(self.sky, 5, axis=1) if unrotated is None else unrotated,
                    gammaConstants=self.sky * np.array([0.435, 0.435, 0.435, 1]) if gamma is None else gamma)

    def test_the_sky_and_particles_pass_and_every_applicable_sky_control_fails(self):
        self.add_oracle()
        self.write_ours_groups(self.sky_variants(), particles=self.leaves)
        case = self.run_oracle()
        self.assertTrue(case['passes'], json.dumps(case, indent=1, default=str))
        sky = case['sky']
        self.assertTrue(sky['gated'] and sky['passes'] and sky['coverageIoU'] == 1.0)
        self.assertLess(sky['p99Relative'], 2 ** -10)
        self.assertTrue(all(c['fails'] and c['applicable'] for c in sky['controls'].values()))
        self.assertTrue(case['particles']['passes']); self.assertEqual(case['particles']['footprintIoU'], 1.0)
        self.assertEqual(set(case['particles']['controls']), {'noDoubling', 'gammaTint'})
        self.assertTrue(all(c['fails'] for c in case['particles']['controls'].values()))

    def test_a_wrong_sky_a_passing_control_or_missing_coverage_fails(self):
        self.add_oracle(particles=False)
        self.write_ours_groups(self.sky_variants(decoded=self.sky * np.array([1.01, 1, 1, 1])))
        self.assertFalse(self.run_oracle()['sky']['passes'])
        self.write_ours_groups(self.sky_variants(flipped=self.sky))
        case = self.run_oracle()
        self.assertFalse(case['sky']['controls']['rowsFlipped']['fails']); self.assertFalse(case['passes'])
        holed = self.sky.copy(); holed[:4, :, 3] = 0
        self.write_ours_groups(self.sky_variants(decoded=holed))
        case = self.run_oracle()
        self.assertLess(case['sky']['coverageIoU'], 0.999); self.assertFalse(case['sky']['passes'])

    def test_without_a_sky_rotation_the_rotation_control_is_inapplicable(self):
        self.add_oracle(particles=False)
        self.write_ours_groups(self.sky_variants(unrotated=self.sky), rotation=0.0)
        case = self.run_oracle()
        control = case['sky']['controls']['rotationIgnored']
        self.assertFalse(control['applicable'] or control['fails']); self.assertTrue(case['passes'])

    def test_a_sky_on_one_side_only_fails(self):
        self.add_oracle(particles=False)
        case = self.run_oracle()
        self.assertTrue(case['sky']['gated']); self.assertFalse(case['sky']['passes']); self.assertFalse(case['passes'])

    def test_particles_off_by_the_tint_or_in_another_place_fail(self):
        self.add_oracle(sky=False)
        self.write_ours_groups(particles=self.leaves * 0.6)
        self.assertFalse(self.run_oracle()['particles']['passes'])
        self.write_ours_groups(particles=np.roll(self.leaves, 2, axis=1))
        case = self.run_oracle()
        self.assertLess(case['particles']['footprintIoU'], 0.98); self.assertFalse(case['passes'])

    def test_particles_out_of_view_on_both_sides_are_not_gated_and_on_one_side_fail(self):
        self.leaves[:] = 0
        self.add_oracle(sky=False)
        self.write_ours_groups(particles=self.leaves)
        case = self.run_oracle()
        self.assertFalse(case['particles']['gated']); self.assertTrue(case['passes'])
        shown = self.leaves.copy(); shown[2:6, 3:9, :3] = [0.1, 0.3, 0.05]
        self.write_ours_groups(particles=shown)
        case = self.run_oracle()
        self.assertTrue(case['particles']['gated']); self.assertFalse(case['passes'])

    def test_a_passing_particle_control_or_a_missing_control_image_fails(self):
        self.add_oracle(sky=False)
        self.write_ours_groups(particles=self.leaves, particle_controls=dict(noDoubling=self.leaves, gammaTint=self.leaves * 1.4))
        case = self.run_oracle()
        self.assertFalse(case['particles']['controls']['noDoubling']['fails']); self.assertFalse(case['particles']['passes'])
        native = json.loads((self.ours / 'native-map.json').read_text())
        del native['particles']['files']['gammaTint']
        (self.ours / 'native-map.json').write_text(json.dumps(native))
        case = self.run_oracle()
        self.assertIn('gammaTint', case['particles']['reason']); self.assertFalse(case['passes'])

    def test_the_irradiance_gate_keeps_only_the_lightmapped_class(self):
        # Unity's right half is a light-probe-lit part: our lightmapped-only image differs there.
        other = self.unity.copy(); other[:, 16:] *= 3
        self.write_ours({'decoded': other, 'nonDirectional': other * 0.8, 'gammaConstants': other * 0.3})
        self.assertFalse(self.run_oracle()['irradiance']['passes'])
        classes = np.zeros((H, W, 4)); classes[..., 3] = 255; classes[:, :16, :3] = 255; classes[:, 16:, 0] = 255
        self.add_oracle(sky=False, particles=False, classes=classes)
        case = self.run_oracle()
        self.assertTrue(case['irradiance']['passes'] and case['irradiance']['lightmappedClassOnly'])
        self.assertEqual(case['classes']['pixels']['probeLit'], H * 16)
        self.assertEqual(case['classes']['pixelsInBothSilhouettes']['lightmapped'], 16 * 10)
        self.assertTrue(case['passes'])

    def test_one_map34_folder_serves_as_original_and_oracle(self):
        self.add_oracle(particles=False, combined=True)
        self.write_ours_groups(self.sky_variants())
        result = compare.compare(self.original, [('c', self.ours)], self.original)
        self.assertTrue(result['cases'][0]['passes'], json.dumps(result['cases'][0], indent=1, default=str))
        self.assertEqual(result['oracleTraceSHA256'], result['traceSHA256'])

    def test_the_sun_type_and_the_sky_placement_are_checked(self):
        trace = json.loads((self.original / 'map-trace.json').read_text())
        trace['cases']['c']['settled']['sunLightType'] = 1
        unity_sky = np.diag([900.0, 900.0, 900.0, 1.0]); unity_sky[:3, 3] = [-15, -1.5, 168]
        trace['cases']['c']['capture']['mapRenderers'] = [dict(path='Map/sky', **{'class': 'sky'}, localToWorld=column_major(unity_sky))]
        (self.original / 'map-trace.json').write_text(json.dumps(trace))
        native = json.loads((self.ours / 'native-map.json').read_text())
        native['sunLightType'] = 1
        sky = dict(native['draws'][0], model=column_major(compare.BASIS @ unity_sky @ compare.BASIS), pickOccluder=False, draw='sky')
        native['draws'] = native['draws'] + [sky]
        (self.ours / 'native-map.json').write_text(json.dumps(native))
        case = self.run_case()
        self.assertTrue(case['passes'], json.dumps(case, indent=1, default=str))
        self.assertEqual((case['placement']['skyDraws'], case['placement']['skyModelRelativeError']), (1, 0.0))
        for change in (dict(sunLightType=2), dict(sky=dict(pickOccluder=True)), dict(sky=dict(shift=0.05))):
            edited = copy.deepcopy(native)
            if 'sunLightType' in change: edited['sunLightType'] = change['sunLightType']
            elif 'pickOccluder' in change['sky']: edited['draws'][-1]['pickOccluder'] = True
            else: edited['draws'][-1]['model'][12] += change['sky']['shift']
            (self.ours / 'native-map.json').write_text(json.dumps(edited))
            self.assertFalse(self.run_case()['passes'], change)


class Slice4Tests(Slice3Tests):
    """The maps mode: per-case map and far plane, a skipped irradiance, mob silhouettes and unlit draws."""
    MOB = [0.0, 0.0, 1.0, 0.5]

    def setUp(self):
        super().setUp()
        # Two overlapping mobs: one layer is the mob colour times its alpha, two layers blend once more.
        self.mobs = np.zeros((H, W, 4))
        self.mobs[3:14, 4:12, 2] = 0.5; self.mobs[8:20, 9:20, 2] = 0.5; self.mobs[8:14, 9:12, 2] = 0.75
        self.poster = np.zeros((H, W, 4)); self.poster[10:22, 14:28, :3] = [0.3, 0.2, 0.1]

    def add_slice4(self, silhouettes=True, unlit=True, skip_irradiance=False):
        self.add_oracle(sky=False, particles=False)
        trace = json.loads((self.oracle / 'oracle-trace.json').read_text())
        case = trace['cases']['c']; measured = case['oracle']
        case['authored'] = dict(mobColor=self.MOB)
        for name, image, on in (('silhouettes', self.mobs, silhouettes), ('unlit', self.poster, unlit)):
            if on:
                (self.oracle / f'oracle-c-{name}.rgba.f32.gz').write_bytes(gzip.compress(image.astype('<f4').tobytes()))
                measured[name] = dict(written=True, file=f'oracle-c-{name}.rgba.f32')
            else:
                measured.pop(name, None)
        if skip_irradiance:
            measured['irradiance'] = dict(written=False, reason='the map has no baked lightmaps')
            measured['irradianceLit'] = dict(written=False, reason='the map has no baked lightmaps')
        (self.oracle / 'oracle-trace.json').write_text(json.dumps(trace))

    def write_ours_slice4(self, mobs=None, alpha_ignored=None, poster=None, doubled=None):
        native = json.loads((self.ours / 'native-map.json').read_text())
        def deflate(image, name):
            packer = zlib.compressobj(wbits=-15)
            (self.ours / name).write_bytes(packer.compress(image.astype('<f2').tobytes()) + packer.flush())
        groups = (('silhouettes', dict(decoded=mobs, alphaIgnored=alpha_ignored)), ('unlit', dict(decoded=poster, doubled=doubled)))
        for group, variants in groups:
            if variants['decoded'] is None: continue
            files = {}
            for variant, image in variants.items():
                files[variant] = f'native-map-{group}-{variant}.rgba16f.deflate'; deflate(image, files[variant])
            native[group] = dict(written=True, files=files)
        (self.ours / 'native-map.json').write_text(json.dumps(native))

    def opaque_mobs(self):
        image = self.mobs.copy(); image[..., 2] = np.where(self.mobs[..., 2] > 0, 1.0, 0.0)
        return image

    def test_silhouettes_and_unlit_pass_and_their_controls_fail(self):
        self.add_slice4()
        self.write_ours_slice4(self.mobs, self.opaque_mobs(), self.poster, self.poster * 2)
        case = self.run_oracle()
        self.assertTrue(case['passes'], json.dumps(case, indent=1, default=str))
        sil = case['silhouettes']
        self.assertTrue(sil['gated'] and sil['passes'] and sil['footprintIoU'] == 1.0)
        self.assertEqual(sil['unityLevels'], {'1': sil['unityLevels']['1'], '1.5': sil['unityLevels']['1.5']})
        self.assertTrue(sil['controls']['alphaIgnored']['fails'])
        self.assertTrue(case['unlit']['passes'] and case['unlit']['controls']['doubled']['fails'])

    def test_edges_are_left_out_but_a_missing_overlap_fails(self):
        self.add_slice4(unlit=False)
        soft = self.mobs.copy(); soft[3, 4:12, 2] = 0.3; soft[3:14, 11, 2] = 0.3  # MSAA-resolved edge pixels
        self.write_ours_slice4(soft, self.opaque_mobs())
        self.assertTrue(self.run_oracle()['silhouettes']['passes'])
        once = self.mobs.copy(); once[8:14, 9:12, 2] = 0.5  # the far mob hidden by the near one's depth pass
        self.write_ours_slice4(once, self.opaque_mobs())
        case = self.run_oracle()
        self.assertFalse(case['silhouettes']['passes']); self.assertFalse(case['passes'])

    def test_silhouettes_on_one_side_without_a_mob_colour_or_a_passing_control_fail(self):
        self.add_slice4(unlit=False)
        self.write_ours_slice4(self.mobs, self.mobs)
        self.assertFalse(self.run_oracle()['silhouettes']['passes'])
        self.add_slice4(silhouettes=False, unlit=False)
        self.write_ours_slice4(self.mobs, self.opaque_mobs())
        self.assertEqual(self.run_oracle()['silhouettes']['reason'], 'only our capture draws mob silhouettes')
        self.add_slice4(unlit=False)
        trace = json.loads((self.oracle / 'oracle-trace.json').read_text()); del trace['cases']['c']['authored']
        (self.oracle / 'oracle-trace.json').write_text(json.dumps(trace))
        self.assertEqual(self.run_oracle()['silhouettes']['reason'], "the original's trace has no mob colour")

    def test_a_skipped_irradiance_is_reported_not_gated(self):
        self.add_slice4(silhouettes=False, unlit=False, skip_irradiance=True)
        self.write_ours({})
        case = self.run_oracle()
        self.assertTrue(case['passes'], json.dumps(case, indent=1, default=str))
        self.assertFalse(case['irradiance']['gated']); self.assertIn('no baked lightmaps', case['irradiance']['reason'])

    def test_particles_leave_out_what_the_renderers_other_submeshes_drew(self):
        # The oracle's particle pass draws whole renderers: a canopy submesh writes alpha 1 there, the
        # particle shader none. Our particle image holds only the particle draw.
        self.leaves[8:14, 3:12] = [0.2, 0.4, 0.1, 1.0]; self.leaves[8:10, 5:9, :3] += [0.05, 0.1, 0.02]
        self.add_oracle(sky=False)
        ours = self.leaves.copy(); ours[8:14, 3:12] = 0; ours[8:10, 5:9, :3] = [0.05, 0.1, 0.02]
        self.write_ours_groups(particles=ours)
        particles = self.run_oracle()['particles']
        self.assertTrue(particles['passes'], json.dumps(particles, indent=1, default=str))
        self.assertEqual((particles['otherSubmeshPixels'], particles['footprintIoU'], particles['comparedPixels']), (54, 1.0, 24))
        # Off by the tint where only particles drew still fails.
        self.write_ours_groups(particles=ours * np.array([1.1, 1.1, 1.1, 1]))
        self.assertFalse(self.run_oracle()['particles']['passes'])

    def test_each_case_carries_its_map_and_far_plane(self):
        trace = json.loads((self.original / 'map-trace.json').read_text())
        trace.update(mapNo=None, depthFar=None, mode='maps'); trace['cases']['c'].update(mapNo=33, depthFar=FAR)
        (self.original / 'map-trace.json').write_text(json.dumps(trace))
        result = compare.compare(self.original, [('c', self.ours)])
        self.assertTrue(result['passes']); self.assertEqual((result['mode'], result['cases'][0]['mapNo']), ('maps', 33))
        trace['cases']['c']['mapNo'] = 41
        (self.original / 'map-trace.json').write_text(json.dumps(trace))
        self.assertFalse(self.run_case()['record']['passes'])
        trace['cases']['c'].update(mapNo=33, depthFar=1000)
        (self.original / 'map-trace.json').write_text(json.dumps(trace))
        with self.assertRaisesRegex(ValueError, 'far plane'):
            self.run_case()


if __name__ == '__main__':
    unittest.main()
