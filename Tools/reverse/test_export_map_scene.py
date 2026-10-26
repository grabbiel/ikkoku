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

    def test_lightmapped_standard_materials_list_only_what_the_lightmap_material_drops(self):
        def material(shader, standard=True):
            extras = {"unityShader": shader, "droppedTerms": ["item"]}
            if standard:
                extras["ikkokuStandard"] = {}
            return {"extras": extras}
        def mesh(material_index, lightmap_index):
            return {"extras": {"ikkokuMap": {"lightmapIndex": lightmap_index}}, "primitives": [{"material": material_index}]}
        gltf = {"materials": [material("Standard"), material("Standard"), material("Standard"),
                              material("Particles/Alpha Blended", False)],
                "meshes": [mesh(0, 0), mesh(1, -1), mesh(2, 0), mesh(2, -1), mesh(3, 0)]}
        maps.lightmapped_dropped_terms(gltf)
        rule = maps.MAP_SHADER_RULES["Standard"]
        self.assertEqual(gltf["materials"][0]["extras"]["droppedTerms"], rule["droppedLightmapped"])
        self.assertEqual(gltf["materials"][1]["extras"]["droppedTerms"], ["item"])
        both = gltf["materials"][2]["extras"]["droppedTerms"]
        self.assertEqual(both[:len(rule["droppedLightmapped"])], rule["droppedLightmapped"])
        self.assertIn("emission", both)
        self.assertNotIn("emission", rule["droppedLightmapped"])
        self.assertEqual(gltf["materials"][3]["extras"]["droppedTerms"], ["item"])


class BlockImageTests(unittest.TestCase):
    """flip_block_rows against texture2ddecoder (the decoder UnityPy's PNG export uses)."""

    @staticmethod
    def decode(data, width, height, fmt):
        import numpy as np
        return np.frombuffer(maps.decode_blocks(data, width, height, fmt), np.uint8).reshape(height, width, 4)

    def levels(self, data, width, height, mips, block):
        sizes = maps.block_level_bytes(width, height, mips, block)
        offsets = [sum(sizes[:i]) for i in range(mips)]
        return [data[o:o + n] for o, n in zip(offsets, sizes)]

    def test_every_level_decodes_to_the_source_with_its_rows_reversed(self):
        import random
        rng = random.Random(7)
        for fmt, block in (("BC1", 8), ("BC3", 16)):
            for width, height, mips in ((16, 8, 5), (8, 8, 4), (8, 4, 4)):
                data = bytes(rng.randrange(256) for _ in range(sum(maps.block_level_bytes(width, height, mips, block))))
                flipped = maps.flip_block_rows(data, width, height, mips, fmt)
                self.assertEqual(len(flipped), len(data))
                self.assertEqual(maps.flip_block_rows(flipped, width, height, mips, fmt), data)
                w, h = width, height
                for source, result in zip(self.levels(data, width, height, mips, block), self.levels(flipped, width, height, mips, block)):
                    # A level under 4 pixels is one block: only its valid rows and columns are pixels.
                    pw, ph = max(4, w), max(4, h)
                    a, b = self.decode(source, pw, ph, fmt)[:h, :w], self.decode(result, pw, ph, fmt)[:h, :w]
                    self.assertTrue((a[::-1] == b).all(), f"{fmt} {w}x{h}")
                    w, h = max(1, w // 2), max(1, h // 2)

    def test_sizes_and_partial_block_rows_are_refused(self):
        with self.assertRaisesRegex(ValueError, "needs 40"):
            maps.flip_block_rows(bytes(48), 8, 4, 4, "BC1")
        with self.assertRaisesRegex(ValueError, "too few"):
            maps.flip_block_rows(bytes(8), 8, 4, 4, "BC1")
        with self.assertRaisesRegex(ValueError, "whole number of block rows"):
            maps.flip_block_rows(bytes(8 * 4), 4, 6, 1, "BC1")
        with self.assertRaises(KeyError):
            maps.flip_block_rows(bytes(16), 4, 4, 1, "BC7")


class SkyTests(unittest.TestCase):
    N = 16

    def cube(self):
        """Faces of a smooth function of direction, row 0 at the top (D3D/Metal face mapping)."""
        import numpy as np
        c = (np.arange(self.N) + 0.5) / self.N * 2 - 1
        u, v = np.meshgrid(c, c)  # u along columns, v down the rows
        one = np.ones_like(u)
        directions = [(one, -v, -u), (-one, -v, u), (u, one, v), (u, -one, -v), (u, -v, one), (-u, -v, -one)]
        faces = []
        for x, y, z in directions:
            n = np.sqrt(x * x + y * y + z * z)
            faces.append(np.stack([(x / n + 1) * 127, (y / n + 1) * 127, (z / n + 1) * 127], axis=-1))
        return faces

    def test_seams_meet_as_stored_and_not_with_rows_reversed(self):
        errors = maps.cube_seam_errors(self.cube())
        self.assertLess(errors["asStored"], 8)
        self.assertGreater(errors["rowsFlipped"], 5 * errors["asStored"])
        flipped = maps.cube_seam_errors([f[::-1] for f in self.cube()])
        self.assertAlmostEqual(flipped["asStored"], errors["rowsFlipped"])

    def test_engine_matrix_places_reflected_points_where_the_reflected_world_point_is(self):
        m = maps.trs([-14.91, -1.5, -168.56], [0.1, 0.2, 0.3, math.sqrt(1 - 0.14)], [895.5949, 895.5958, 1225.75])
        column_major = maps.engine_matrix(m)
        engine = [[column_major[column * 4 + row] for column in range(4)] for row in range(4)]
        for point in ([0.5, 0, 0], [0, -0.5, 0.25], [0.1, 0.2, -0.3]):
            close(self, maps.apply_point(engine, maps.reflect(point)), maps.reflect(maps.apply_point(m, point)), places=6)

    def test_sky_extras_linearize_the_tint_and_the_gamma_exposure(self):
        extras = maps.sky_extras({"_Tint": [0.6691, 0.6691, 0.6691, 0.5]}, {"_Exposure": 1.3, "_Rotation": 291.0}, 2)
        self.assertEqual((extras["kind"], extras["version"], extras["cube"], extras["rotationDegrees"]),
                         ("ikkoku.unitySkyboxCubemap", 1, 2, 291.0))
        close(self, extras["tintLinear"], [maps.gamma_to_linear_exact(0.6691)] * 3)
        self.assertAlmostEqual(extras["exposure"], 1.3 ** 2.2)
        self.assertEqual((extras["exposureSerialized"], extras["colorSpaceDouble"], extras["decodeInstructions"]),
                         (1.3, 4.5947938, [1.0, 1.0, 0.0, 0.0]))
        defaults = maps.sky_extras({}, {}, 0)
        close(self, defaults["tintLinear"], [maps.gamma_to_linear_exact(0.5)] * 3)
        self.assertEqual((defaults["exposure"], defaults["rotationDegrees"]), (1.0, 0.0))

    def test_particle_tint_is_linearized_and_its_alpha_kept(self):
        extras = maps.particle_extras({"_TintColor": [0.5, 0.25, 1.0, 0.534]})
        close(self, extras["tintLinear"], [maps.gamma_to_linear_exact(0.5), maps.gamma_to_linear_exact(0.25), 1.0, 0.534])
        close(self, maps.particle_extras({})["tintLinear"], [maps.gamma_to_linear_exact(0.5)] * 3 + [0.5])

    def test_coverage_counts_standard_renderers_by_path(self):
        material = lambda shader: {"extras": {"unityShader": shader}}
        group = lambda m, lm, *paths: {"material": m, "lightmapIndex": lm, "renderers": [{"path": p, "triangles": 10} for p in paths]}
        exporter = SimpleNamespace(gltf={"materials": [material("Standard"), material("Particles/Alpha Blended")]},
                                   source={"groups": [group(0, 0, "a", "a", "b"), group(0, -1, "c"), group(1, -1, "d")]})
        self.assertEqual(maps.lightmap_coverage(exporter), {"lightmappedRenderers": 2, "lightmappedTriangles": 30,
                                                           "unlightmappedStandardRenderers": 1, "unlightmappedStandardTriangles": 10})


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
        # Particles and the cube sky are drawn by their formulas (slice 3): not listed as approximated.
        self.assertEqual(maps.approximations(dict(drawn, shaders=["Particles/Alpha Blended", "Skybox/Cubemap", "Standard"])),
                         maps.approximations(drawn))
        self.assertEqual(maps.approximations(dict(drawn, shaders=["Legacy Shaders/Diffuse", "Standard"]))[-1],
                         "shaders approximated (Legacy Shaders/Diffuse)")
        probes = dict(drawn, lightmapCoverage={"unlightmappedStandardRenderers": 37})
        self.assertEqual(maps.approximations(probes)[-1], "light probes (37 Standard renderers without a lightmap drawn as items)")
        self.assertEqual(maps.approximations({'droppedTerms': ['x'], 'shaders': ['Standard']})[-1], 'shaders approximated (Standard)')
        self.assertEqual(maps.approximations({'droppedTerms': ['x'], 'shaders': ['Skybox/Cubemap', 'Standard']})[-1],
                         'shaders approximated (Standard)')

    def test_gpu_bytes_counts_rgba8_with_a_full_mip_chain(self):
        self.assertEqual(maps.gpu_bytes(4, 2), 4 * 2 * 4 + 2 * 1 * 4 + 1 * 1 * 4)
        self.assertEqual(maps.gpu_bytes(1, 1), 4)


class SurveyTests(unittest.TestCase):
    """ST-A11 slice 4: one map's survey row from a synthetic inventory, and the scene usage counts."""
    def inventory(self, **change):
        renderer = lambda path, materials, tris, lm=-1, batch=(0, 0), enabled=True, keys=(0, 1, 2, -1): dict(
            path=path, enabled=enabled, materials=list(materials), trianglesPerMaterial=list(tris), visibleFor=list(keys),
            effectiveLightmapIndex=lm, staticBatch=list(batch))
        result = dict(
            renderers=[renderer('Map/wall', ['wall'], [100], lm=0), renderer('Map/desk', ['desk', 'glass'], [40, 2]),
                       renderer('Map/water', ['water'], [8]), renderer('Map/off', ['wall'], [5], enabled=False),
                       renderer('Map/sky', ['sky'], [768])],
            materials=[dict(name='wall', shader='Standard'), dict(name='desk', shader='Standard'),
                       dict(name='glass', shader='Legacy Shaders/Transparent/Diffuse'), dict(name='water', shader='Koikano/Water'),
                       dict(name='sky', shader='Skybox/Cubemap')],
            triangles=918, materialCount=5,
            lightmaps=[dict(index=0, Lightmap=dict(lightmapFormat=2, textureFormat=12), DirLightmap=dict(textureFormat=12))],
            lightmapSettings=dict(mode=1, lightmaps=1, lightProbes=12),
            otherComponents={'ReflectionProbe': 2, 'SkinnedMeshRenderer': 1, 'MonoBehaviour:SunLightInfo': 1, 'BoxCollider': 3},
            textures=[dict(textureFormat=10, serializedBytes=8), dict(textureFormat=25, serializedBytes=16), dict(textureFormat=10, serializedBytes=8)],
            lights=[dict(type=1, lightmapping=4, enabled=True, visibleFor=[0]), dict(type=2, lightmapping=2, enabled=True, visibleFor=[0]),
                    dict(type=2, lightmapping=2, enabled=False, visibleFor=[0])],
            sunLightInfo=dict(entries=[dict(type=1), dict(type=0)]),
            renderSettings=dict(skyboxMaterial='Skybox/Procedural', fog=False), ambientProbe=dict(ambientMode=3, l0=[0.1, 0.2, 0.3]))
        result.update(change)
        return result

    def test_every_drawn_renderer_is_counted_by_shader_with_its_triangles(self):
        row = maps.survey_summary(self.inventory())
        self.assertEqual((row['renderers'], row['drawnRenderers']), (5, 4))
        self.assertEqual(row['shaders']['Standard'], dict(family='Standard', renderers=2, materials=2, triangles=140, lightmappedRenderers=1))
        self.assertEqual(row['shaders']['Legacy Shaders/Transparent/Diffuse']['family'], 'Legacy Shaders')
        self.assertEqual(row['shaders']['Koikano/Water']['family'], 'game shader')
        self.assertEqual(row['shaders']['Skybox/Cubemap']['family'], 'Skybox')
        self.assertEqual(row['skies'], ['Skybox/Cubemap'])
        self.assertEqual((row['standardRenderers'], row['lightmappedStandardRenderers'], row['lightProbes'], row['reflectionProbes']), (2, 1, 12, 2))
        self.assertEqual(row['textureFormats'], {'BC7': dict(textures=1, bytes=16), 'DXT1': dict(textures=2, bytes=16)})
        self.assertEqual(row['lights'], {'directional realtime': 1, 'point baked': 1})
        self.assertEqual(row['sunTypes'], [0, 1])
        self.assertEqual(row['unconverted'], {'SkinnedMeshRenderer': 1, 'ReflectionProbe': 2})
        self.assertEqual(row['monoBehaviours'], ['SunLightInfo'])

    def test_refusals_name_unmapped_shaders_static_batches_and_slot_mismatches(self):
        row = maps.survey_summary(self.inventory())
        self.assertEqual(row['refusals'], ["shader 'Koikano/Water' has no map rule (1 renderers, 8 triangles)",
                                           "shader 'Legacy Shaders/Transparent/Diffuse' has no map rule (1 renderers, 2 triangles)"])
        inv = self.inventory()
        inv['renderers'][0]['staticBatch'] = [3, 1]
        inv['renderers'][2]['trianglesPerMaterial'] = []
        inv['renderers'][1]['trianglesPerMaterial'] = [40]
        refusals = maps.survey_summary(inv)['refusals']
        self.assertIn('1 static-batched renderers: their placement under the map transform needs evidence', refusals)
        self.assertIn('Map/desk: more materials than submeshes', refusals)

    def test_lightmaps_reproduce_only_as_slice_two_draws_them(self):
        self.assertEqual(maps.survey_summary(self.inventory())['lightmaps'],
                         dict(count=1, mode='CombinedDirectional', encodings=['2'], reproduced=True, problems=[]))
        cases = [
            (dict(lightmapSettings=dict(mode=2)), 'LightmapsMode 2'),
            (dict(lightmaps=[dict(index=0, Lightmap=dict(lightmapFormat=1, textureFormat=12), DirLightmap=dict(textureFormat=12))]), 'not RGBM'),
            (dict(lightmaps=[dict(index=0, Lightmap=dict(lightmapFormat=2, textureFormat=24), DirLightmap=dict(textureFormat=12))]), 'TextureFormat 24'),
            (dict(lightmaps=[dict(index=0, Lightmap=dict(lightmapFormat=2, textureFormat=12))]), 'no direction map'),
            (dict(lightmaps=[dict(index=0, Lightmap=dict(lightmapFormat=2, textureFormat=12), DirLightmap=dict(textureFormat=12),
                                  ShadowMask=dict(textureFormat=12))]), 'a shadow mask'),
        ]
        for change, problem in cases:
            with self.subTest(problem):
                lightmaps = maps.survey_summary(self.inventory(**change))['lightmaps']
                self.assertFalse(lightmaps['reproduced']); self.assertTrue(any(problem in p for p in lightmaps['problems']))
        self.assertFalse(maps.survey_summary(self.inventory(lightmaps=[]))['lightmaps']['reproduced'])

    def test_scene_usage_counts_maps_by_hashed_id_without_names(self):
        usage = maps.scene_usage([('a' * 64, 34), ('b' * 64, -1), ('c' * 64, 34), ('d' * 64, None)])
        self.assertEqual(usage, {'scenes': 4, 'unreadable': 1,
                                 'maps': {'-1': dict(scenes=1, sceneIDs=['b' * 12]), '34': dict(scenes=2, sceneIDs=['a' * 12, 'c' * 12])}})


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
