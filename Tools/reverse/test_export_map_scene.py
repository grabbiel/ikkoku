"""ST-A11 map converter: the pure rules (sun-type visibility, lightmap selection, material
contracts, the Map_ catalog, transforms) and the .local output guard. No bundle is read."""
import hashlib, math, os, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import export_map_scene as maps


def close(test, a, b, places=9):
    for x, y in zip(a, b):
        if isinstance(x, list): close(test, x, y, places)
        else: test.assertAlmostEqual(x, y, places=places)


class TransformTests(unittest.TestCase):
    Q = [math.sin(math.radians(15)), 0.0, 0.0, math.cos(math.radians(15))]  # 30 degrees about X

    def test_trs_is_translation_rotation_then_scale(self):
        m = maps.trs([1, 2, 3], self.Q, [2, 3, 4])
        c, s = math.cos(math.radians(30)), math.sin(math.radians(30))
        close(self, m, [[2, 0, 0, 1], [0, 3 * c, -4 * s, 2], [0, 3 * s, 4 * c, 3], [0, 0, 0, 1]])
        close(self, maps.apply_point(m, [1, 0, 0]), [3, 2, 3])

    def test_inverse_affine_undoes_trs(self):
        m = maps.trs([0.3, -0.05, -0.5], self.Q, [1, 2, 0.5])
        close(self, maps.matmul(maps.inverse_affine(m), m), [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])

    def test_singular_transform_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'Singular'):
            maps.inverse_affine(maps.trs([0, 0, 0], [0, 0, 0, 1], [1, 0, 1]))

    def test_normal_matrix_keeps_normals_perpendicular_under_nonuniform_scale(self):
        m = maps.trs([0, 0, 0], [0, 0, 0, 1], [1, 4, 1])
        tangent = maps.apply_linear(maps.linear(m), [1, -1, 0])
        normal = maps.apply_linear(maps.normal_matrix(m), [1, 1, 0])
        self.assertAlmostEqual(sum(a * b for a, b in zip(tangent, normal)), 0, places=12)


class UVTests(unittest.TestCase):
    def test_lightmap_uv_applies_scale_offset_then_flips_v(self):
        close(self, maps.lightmap_uv([0.5, 0.5], [0.5, 0.25, 0.1, 0.2]), [0.35, 1 - 0.325])

    def test_tiled_uv_bakes_main_tex_st_before_the_flip(self):
        close(self, maps.tiled_uv([0.5, 0.25], [2, 4], [0.1, 0]), [1.1, 0.0])


class SunTypeTests(unittest.TestCase):
    AUTHORED = {'a': True, 'b': False, 'c': True, 'd': True}

    def test_chosen_entry_activates_and_every_other_entry_deactivates(self):
        result = maps.sun_type_active(self.AUTHORED, [(0, ['a']), (1, ['b'])])
        self.assertEqual(result[0], {'a': True, 'b': False, 'c': True, 'd': True})
        self.assertEqual(result[1], {'a': False, 'b': True, 'c': True, 'd': True})

    def test_a_key_without_an_entry_and_other_values_keep_the_authored_state(self):
        result = maps.sun_type_active(self.AUTHORED, [(0, ['a']), (1, ['b'])])
        self.assertEqual(result[2], self.AUTHORED)
        self.assertEqual(result[maps.OTHER_SUN_TYPE], self.AUTHORED)
        self.assertEqual(set(result), {0, 1, 2, -1})

    def test_first_entry_of_a_repeated_type_wins_and_later_lists_override_earlier_ones(self):
        # FirstOrDefault picks entry 0 for type 0; entry 2 (also type 0) is "another" entry and
        # is deactivated. A node listed twice takes the later list's value.
        result = maps.sun_type_active(self.AUTHORED, [(0, ['a', 'd']), (1, ['b', 'd']), (0, ['c'])])
        self.assertEqual(result[0], {'a': True, 'b': False, 'c': False, 'd': False})
        self.assertEqual(result[1], {'a': False, 'b': True, 'c': False, 'd': True})

    def test_visibility_needs_every_ancestor_active(self):
        parents = {'child': 'parent', 'parent': None}
        active = {0: {'child': True, 'parent': True}, 1: {'child': True, 'parent': False}, 2: {'child': False, 'parent': True}}
        self.assertEqual(maps.visibility_keys('child', parents, active), [0])
        self.assertEqual(maps.visibility_keys('parent', parents, active), [0, 2])
        self.assertEqual(maps.visibility_keys('unknown', {}, active), [])


class LightmapTests(unittest.TestCase):
    ST = [0.5, 0.5, 0.25, 0]

    def test_renderer_values_stand_without_a_prefab_entry(self):
        self.assertEqual(maps.effective_lightmap(3, self.ST, None), (3, self.ST, 'renderer'))

    def test_lightmap_prefab_overrides_a_listed_renderer(self):
        self.assertEqual(maps.effective_lightmap(3, self.ST, (0, [1, 1, 0, 0])), (0, [1, 1, 0, 0], 'LightmapPrefab'))

    def test_a_negative_prefab_index_leaves_the_renderer_values(self):
        self.assertEqual(maps.effective_lightmap(2, self.ST, (-1, [1, 1, 0, 0])), (2, self.ST, 'renderer'))

    def test_unity_none_and_realtime_indices_mean_no_baked_lightmap(self):
        for index in (0xFFFF, 0xFFFE, -1):
            self.assertEqual(maps.effective_lightmap(index, self.ST, None)[:2], (maps.NO_LIGHTMAP, None))


class MaterialTests(unittest.TestCase):
    def test_standard_alpha_modes(self):
        color = {'_Color': [0.5, 0.6, 0.7, 0.4]}
        self.assertEqual(maps.standard_contract(color, {'_Cutoff': 0.3}, ['_ALPHATEST_ON']),
                         {'baseColorFactor': [0.5, 0.6, 0.7, 1], 'alphaMode': 'MASK', 'alphaCutoff': 0.3, 'doubleSided': False})
        self.assertEqual(maps.standard_contract(color, {}, ['_ALPHAPREMULTIPLY_ON'])['baseColorFactor'], [0.5, 0.6, 0.7, 0.4])
        self.assertEqual(maps.standard_contract(color, {}, ['_ALPHABLEND_ON'])['alphaMode'], 'BLEND')
        self.assertEqual(maps.standard_contract({}, {}, []), {'baseColorFactor': [1, 1, 1, 1], 'alphaMode': 'OPAQUE', 'doubleSided': False})

    def test_particles_double_the_tint_and_clamp(self):
        contract = maps.particle_contract({'_TintColor': [0.25, 0.5, 0.75, 0.1]})
        self.assertEqual(contract['baseColorFactor'], [0.5, 1.0, 1, 0.2])
        self.assertTrue(contract['unlit'] and contract['vertexColor'] and contract['doubleSided'])

    def test_unmapped_shaders_fail_by_name_and_mapped_ones_list_their_dropped_terms(self):
        with self.assertRaisesRegex(ValueError, "Legacy Shaders/Diffuse"):
            maps.map_material_contract('Legacy Shaders/Diffuse', {}, {}, [])
        contract = maps.map_material_contract('Standard', {}, {}, [])
        self.assertEqual(contract['shaderParity'], 'approximated')
        self.assertIn('normal maps', contract['dropped'])
        self.assertIsNot(contract['dropped'], maps.MAP_SHADER_RULES['Standard']['dropped'])


class StandardInputTests(unittest.TestCase):
    """The baked-lightmap material's inputs (UnityCG.cginc / UnityStandardUtils.cginc v5.6.2f1)."""
    def test_gamma_to_linear_exact_matches_unity_on_each_branch(self):
        self.assertEqual(maps.gamma_to_linear_exact(0.04), 0.04 / 12.92)
        self.assertAlmostEqual(maps.gamma_to_linear_exact(0.5), 0.214041140, places=8)
        self.assertEqual(maps.gamma_to_linear_exact(1.0), 1.0)
        self.assertAlmostEqual(maps.gamma_to_linear_exact(5.0), 34.493242, places=5)  # unity_Lightmap_HDR.x in Linear

    def test_one_minus_reflectivity_uses_the_linear_dielectric_spec(self):
        self.assertAlmostEqual(maps.one_minus_reflectivity(0.0), 0.96)
        self.assertAlmostEqual(maps.one_minus_reflectivity(0.25), 0.72)
        self.assertAlmostEqual(maps.one_minus_reflectivity(1.0), 0.0)

    def test_colours_convert_to_linear_and_metallic_comes_from_the_right_source(self):
        plain = maps.standard_inputs({"_Color": [0.5, 1.0, 0.0, 0.75]}, {"_Metallic": 0.25}, [])
        close(self, plain["albedoLinear"], [0.21404114048223255, 1.0, 0.0, 0.75])
        self.assertEqual((plain["metallic"], plain["metallicSource"], plain["emission"]), (0.25, "_Metallic", None))
        self.assertAlmostEqual(plain["oneMinusReflectivity"], 0.72)
        mapped = maps.standard_inputs({}, {"_Metallic": 0.0}, ["_METALLICGLOSSMAP"], metallic_map_mean=0.5)
        self.assertEqual(mapped["metallic"], 0.5)
        self.assertIn("mean over the texture", mapped["metallicSource"])
        absent = maps.standard_inputs({}, {"_Metallic": 0.0}, ["_METALLICGLOSSMAP"])
        self.assertEqual((absent["metallic"], absent["oneMinusReflectivity"]), (1.0, 0.0))  # the white default

    def test_emission_needs_its_keyword_and_samples_white_without_a_texture(self):
        colors = {"_EmissionColor": [0.5, 0.5, 2.0, 1.0]}
        self.assertIsNone(maps.standard_inputs(colors, {}, [])["emission"])
        emission = maps.standard_inputs(colors, {}, ["_EMISSION"])["emission"]
        close(self, emission["colorLinear"], [0.21404114048223255, 0.21404114048223255, 2.0 ** 2.2])
        self.assertEqual((emission["image"], emission["srgb"]), (None, True))
        self.assertEqual(maps.standard_inputs(colors, {}, ["_EMISSION"], 4, False)["emission"]["image"], 4)

    def test_channel_mean_reads_the_texture_as_a_linear_player_samples_it(self):
        from PIL import Image
        image = Image.new("RGBA", (2, 1)); image.putdata([(0, 0, 0, 255), (255, 0, 0, 255)])
        self.assertAlmostEqual(maps.texture_channel_mean(SimpleNamespace(image=image, m_ColorSpace=0), 0), 0.5)
        image.putdata([(128, 0, 0, 255), (128, 0, 0, 255)])
        self.assertAlmostEqual(maps.texture_channel_mean(SimpleNamespace(image=image, m_ColorSpace=1), 0),
                               maps.gamma_to_linear_exact(128 / 255))


class LightmapFileTests(unittest.TestCase):
    RECORD = {"name": "Lightmap-0_comp_light", "textureFormat": 12, "width": 8, "height": 4, "mipCount": 4, "colorSpace": 1}

    def test_block_levels_keep_one_block_below_4x4(self):
        self.assertEqual(maps.block_level_bytes(8, 4, 4, 16), [32, 16, 16, 16])
        self.assertEqual(sum(maps.block_level_bytes(1024, 1024, 11, 16)), 1398128)

    def test_entry_records_the_verbatim_bytes_and_refuses_other_sizes_or_formats(self):
        data = bytes(range(80))
        entry = maps.lightmap_file_entry(self.RECORD, "lightmap-0-light.bc3", data)
        self.assertEqual(entry, {"name": "Lightmap-0_comp_light", "file": "lightmap-0-light.bc3", "format": "BC3", "width": 8, "height": 4,
                                 "mipCount": 4, "srgb": True, "bytes": 80, "sha256": hashlib.sha256(data).hexdigest()})
        with self.assertRaisesRegex(ValueError, "needs 80"):
            maps.lightmap_file_entry(self.RECORD, "f", data[:-1])
        with self.assertRaisesRegex(ValueError, "not a block format"):
            maps.lightmap_file_entry(dict(self.RECORD, textureFormat=4), "f", data)
        self.assertEqual(maps.lightmap_file_entry(dict(self.RECORD, textureFormat=10, colorSpace=0), "f", data[:40])["format"], "BC1")

    def test_extras_name_the_mode_encoding_and_row_order(self):
        extras = maps.lightmaps_extras(1, [(0, {"file": "l"}, {"file": "d"})])
        self.assertEqual({k: extras[k] for k in ("kind", "version", "mode", "encoding", "colorSpace", "rows")},
                         {"kind": "ikkoku.unityLightmaps", "version": 1, "mode": "CombinedDirectional", "encoding": "RGBM",
                          "colorSpace": "Linear", "rows": "bottomUp"})
        self.assertEqual(extras["maps"], [{"index": 0, "light": {"file": "l"}, "direction": {"file": "d"}}])
        self.assertEqual(maps.lightmaps_extras(0, [(0, {"file": "l"}, None)])["maps"], [{"index": 0, "light": {"file": "l"}}])
        with self.assertRaisesRegex(ValueError, "lacks its direction map"):
            maps.lightmaps_extras(1, [(0, {"file": "l"}, None)])
        with self.assertRaisesRegex(ValueError, "LightmapsMode 2 is not drawn"):
            maps.lightmaps_extras(2, [])


class CatalogTests(unittest.TestCase):
    HEADER = [['#no', 'name'], ['', '']]

    def test_rows_follow_load_info_rules(self):
        first = self.HEADER + [['33', '空き部室', 'studio/map/bushitu.unity3d', 'bushitu'],
                               ['x', 'skipped'], ['35', 'short', 'b'], [],
                               ['2', 'Gym', 'map/gym.unity3d', 'gym', 'abdata', 'map/vanish.unity3d', 'gym_vanish']]
        later = self.HEADER + [['33', 'replaced', 'studio/map/other.unity3d', 'other']]
        rows = maps.catalog_rows([('00.unity3d', 'Map_00', first), ('01.unity3d', 'Map_01', later)])
        self.assertEqual([r['no'] for r in rows], [2, 33])
        gym, room = rows
        self.assertEqual(gym['manifest'], 'abdata')
        self.assertEqual(gym['vanish'], {'bundlePath': 'map/vanish.unity3d', 'file': 'gym_vanish'})
        self.assertEqual((room['name'], room['scene'], room['manifest'], room['vanish']), ('replaced', 'other', None, None))
        self.assertEqual(room['evidence'], {'infoBundle': '01.unity3d', 'table': 'Map_01', 'row': 2})

    def test_header_rows_are_skipped_even_when_numeric(self):
        rows = maps.catalog_rows([('b', 'Map_00', [['1', 'a', 'b', 'c'], ['2', 'a', 'b', 'c'], ['3', 'a', 'b', 'c']])])
        self.assertEqual([r['no'] for r in rows], [3])

    def test_out_of_range_numbers_are_skipped(self):
        rows = maps.catalog_rows([('b', 'Map_00', self.HEADER + [[str(2 ** 31), 'a', 'b', 'c'], ['-1', 'a', 'b', 'c']])])
        self.assertEqual([r['no'] for r in rows], [-1])

    def test_label_lists_what_the_preview_leaves_out(self):
        self.assertEqual(maps.approximations({}), ['no baked lightmaps', 'map lights', 'sun-type lighting', 'fog', 'ambient'])
        drawn = {"lightmapExport": {"drawn": True}, "shaders": ["Standard"]}
        self.assertEqual(maps.approximations(drawn), ["realtime sun and its shadows", "specular and reflections",
                                                      "normal, metallic and detail maps", "fog", "camera effects"])
        self.assertEqual(maps.approximations(dict(drawn, shaders=["Standard", "Particles/Alpha Blended"]))[-1],
                         "shaders approximated (Particles/Alpha Blended)")
        self.assertEqual(maps.approximations({'droppedTerms': ['x'], 'shaders': ['Standard']})[-1], 'shaders approximated (Standard)')

    def test_gpu_bytes_counts_rgba8_with_a_full_mip_chain(self):
        self.assertEqual(maps.gpu_bytes(4, 2), 4 * 2 * 4 + 2 * 1 * 4 + 1 * 1 * 4)
        self.assertEqual(maps.gpu_bytes(1, 1), 4)


class PrivateOutputTests(unittest.TestCase):
    def test_outputs_must_resolve_into_local_or_a_link_placed_in_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, linked = Path(tmp) / 'repo', Path(tmp) / 'main-local' / 'reverse'
            (repo / '.local').mkdir(parents=True); linked.mkdir(parents=True)
            os.symlink(linked, repo / '.local' / 'reverse')
            with patch.object(maps, 'REPO', repo):
                self.assertEqual(maps.private(repo / '.local' / 'x' / 'catalog.json'), (repo / '.local' / 'x' / 'catalog.json').resolve())
                self.assertEqual(maps.private(repo / '.local' / 'reverse' / 'maps'), (linked / 'maps').resolve())
                for outside in (repo / 'docs' / 'catalog.json', Path(tmp) / 'main-local' / 'other', repo / '.local' / '..' / 'x'):
                    with self.assertRaisesRegex(ValueError, 'ignored .local'):
                        maps.private(outside)


if __name__ == '__main__':
    unittest.main()
