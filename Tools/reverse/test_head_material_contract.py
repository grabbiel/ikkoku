#!/usr/bin/env python3
"""Numerical invariants for the recovered base-color shader equations."""
import unittest
from pathlib import Path
from types import SimpleNamespace
import numpy as np
from head_material_contract import (BODY_TEXTURES, CHEEK_BUNDLE, CHEEK_NAME, LIPLINE_BUNDLE, LIPLINE_NAME, body_texture_metadata,
                                    cheek_catalog_row, cheek_texture_metadata,
                                    lipline_catalog_row, lipline_texture_metadata,
                                    create_head_base, create_eye_base, create_eye_white)


class ShaderBaseTests(unittest.TestCase):
    def test_head_masks_select_primary_secondary_and_preserve_blue_region(self):
        main = np.ones((1, 4, 4), dtype=np.float32)
        mask = np.array([[[1, 0, 0, 1], [0, 1, 0, 1], [1, 1, 0, 1], [1, 1, 1, 1]]], dtype=np.float32)
        a, b = np.array([.8, .6, .4, .3]), np.array([.7, .5, .3, .2])
        result = create_head_base(main, mask, a, b)
        np.testing.assert_allclose(result[0, 0, :3], a[:3])
        np.testing.assert_allclose(result[0, 1, :3], b[:3])
        np.testing.assert_allclose(result[0, 2, :3], a[:3] * b[:3])
        np.testing.assert_allclose(result[0, 3], [1, 1, 1, 1])
        self.assertTrue(np.all(result[..., 3] == 1))

    def test_eye_includes_original_clear_target_blending(self):
        main = np.array([[[.25, .9, .8, .5]]], dtype=np.float32)
        tint = np.array([.6, .4, .2, .8], dtype=np.float32)
        # Blend zero removes the nonlinear term; only MainTex.R controls RGB.
        result = create_eye_base(main, tint, 0)
        np.testing.assert_allclose(result[0, 0, :3], tint[:3] * .25 * .4)
        self.assertAlmostEqual(float(result[0, 0, 3]), .16, places=6)

    def test_eye_nonlinear_branches_and_white_interpolation(self):
        main = np.array([[[.25, 0, 0, 1], [.75, 0, 0, 1]]], dtype=np.float32)
        tint = np.array([.8, .6, .4, 1], dtype=np.float32)
        result = create_eye_base(main, tint, 1)
        np.testing.assert_allclose(result[0, 0], [.6, .2, 0, 1], atol=1e-6)
        np.testing.assert_allclose(result[0, 1], [1, 1, .8, 1], atol=1e-6)
        white = create_eye_white(main, np.array([1, .8, .6, 1]), np.array([.2, .4, .6, 1]))
        np.testing.assert_allclose(white[0, 0], [.4, .5, .6, 1])
        np.testing.assert_allclose(white[0, 1], [.8, .7, .6, 1])


class BodyMetadataTests(unittest.TestCase):
    def fixture(self):
        class Texture:
            def __init__(self, size, fmt, color_space):
                self.m_Width = self.m_Height = size
                self.m_TextureFormat = fmt
                self.m_ColorSpace = color_space

            @property
            def image(self):
                raise AssertionError("The body metadata extension must not decode pixels")

        class Reader:
            type = SimpleNamespace(name="Texture2D")
            def __init__(self, name, path_id):
                self.name = name
                self.path_id = path_id
                self.assets_file = SimpleNamespace(name="CAB-test")
            def peek_name(self): return self.name
            def read(self):
                return Texture(2048 if self.name.endswith("_t") else 1024,
                               4 if self.name.endswith("_t") else 10 if self.name.endswith("_mp") else 3,
                               1 if self.name.endswith("_mp") else 0)

        root = Path("/synthetic")
        bundles = {root / bundle: SimpleNamespace(objects=[Reader(name, i + 1) for i, name in enumerate(names)])
                   for bundle, names in BODY_TEXTURES.items()}
        return root, bundles

    def test_body_extension_preserves_distinct_size_format_and_color_space_without_pixels(self):
        root, bundles = self.fixture()
        records = body_texture_metadata(bundles, root)
        self.assertEqual([(r["name"], r["width"], r["height"], r["format"], r["serializedColorSpace"]) for r in records],
                         [("cf_body_00_t", 2048, 2048, 4, 0), ("cf_body_00_mc", 1024, 1024, 3, 0),
                          ("cf_body_01_mp", 1024, 1024, 10, 1)])
        self.assertTrue(all(r["metadataOnly"] and "file" not in r and "pngSHA256" not in r for r in records))

    def test_missing_or_ambiguous_texture_is_not_substituted_from_another_bundle(self):
        for ambiguous in [False, True]:
            root, bundles = self.fixture()
            objects = bundles[root / "chara/oo_base.unity3d"].objects
            main = objects[0]
            if ambiguous: objects.append(main)
            else:
                objects.remove(main)
                bundles[root / "chara/mm_base.unity3d"].objects.append(main)
            with self.subTest(ambiguous=ambiguous), self.assertRaisesRegex(ValueError, "Expected one cf_body_00_t"):
                body_texture_metadata(bundles, root)


class CheekMetadataTests(unittest.TestCase):
    def test_additive_row_does_not_mutate_zero_default_or_accept_other_input(self):
        table = {"mark": "【ChaListData】", "categoryNo": 402,
                 "lstKey": ["MainAB", "CheekTex"],
                 "dictList": {0: ["0", "0"], 1: [CHEEK_BUNDLE, CHEEK_NAME], 2: ["other", "other"]}}
        reader = SimpleNamespace(assets_file=SimpleNamespace(name="CAB-table"), path_id=4)
        row = cheek_catalog_row(table, reader)
        self.assertEqual((row["category"], row["selectedID"], row["row"]),
                         (402, 1, {"MainAB": CHEEK_BUNDLE, "CheekTex": CHEEK_NAME}))
        self.assertEqual(table["dictList"][0], ["0", "0"])
        self.assertEqual(set(table["dictList"]), {0, 1, 2})
        for invalid in [dict(table, categoryNo=403), dict(table, mark="other"),
                        dict(table, dictList={0: ["0", "0"]}),
                        dict(table, dictList={1: [CHEEK_BUNDLE, "other"]})]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                cheek_catalog_row(invalid, reader)

    def test_metadata_preserves_non_square_one_mip_srgb_and_sampler_without_pixels(self):
        class Reader:
            type = SimpleNamespace(name="Texture2D")
            assets_file = SimpleNamespace(name="CAB-cheek")
            path_id = 123
            def peek_name(self): return CHEEK_NAME
            def read(self): raise AssertionError("The cheek extension must not decode pixels")
            def read_typetree(self):
                return {"m_Width": 832, "m_Height": 312, "m_MipCount": 1,
                        "m_TextureFormat": 4, "m_ColorSpace": 1,
                        "m_TextureSettings": {"m_FilterMode": 1, "m_WrapMode": 1, "m_Aniso": 1}}
        root = Path("/synthetic")
        objects = [Reader()]
        bundles = {root / CHEEK_BUNDLE: SimpleNamespace(objects=objects)}
        row = cheek_texture_metadata(bundles, root)
        self.assertEqual({key: row[key] for key in ["width", "height", "mipLevels", "format", "serializedColorSpace", "filter", "wrap", "aniso"]},
                         {"width": 832, "height": 312, "mipLevels": 1, "format": 4, "serializedColorSpace": 1,
                          "filter": "Bilinear", "wrap": "Clamp", "aniso": 1})
        self.assertTrue(row["metadataOnly"] and "file" not in row and "pngSHA256" not in row)
        objects.append(objects[0])
        with self.assertRaisesRegex(ValueError, "Expected one cw_t_cheek_000"):
            cheek_texture_metadata(bundles, root)
        objects.clear()
        with self.assertRaisesRegex(ValueError, "Expected one cw_t_cheek_000"):
            cheek_texture_metadata(bundles, root)


class LiplineMetadataTests(unittest.TestCase):
    def test_additive_row_preserves_defaults_and_rejects_other_catalog_inputs(self):
        table = {"mark": "【ChaListData】", "categoryNo": 404,
                 "lstKey": ["MainAB", "LiplineTex"],
                 "dictList": {0: ["0", "0"], 1: [LIPLINE_BUNDLE, LIPLINE_NAME], 2: ["other", "other"]}}
        reader = SimpleNamespace(assets_file=SimpleNamespace(name="CAB-table"), path_id=4)
        row = lipline_catalog_row(table, reader)
        self.assertEqual((row["table"], row["category"], row["selectedID"], row["row"]),
                         ("mt_lipline_00", 404, 1, {"MainAB": LIPLINE_BUNDLE, "LiplineTex": LIPLINE_NAME}))
        self.assertEqual(table["dictList"], {0: ["0", "0"], 1: [LIPLINE_BUNDLE, LIPLINE_NAME], 2: ["other", "other"]})
        for invalid in [dict(table, categoryNo=402), dict(table, mark="other"),
                        dict(table, dictList={0: ["0", "0"]}),
                        dict(table, dictList={1: ["other", LIPLINE_NAME]}),
                        dict(table, dictList={1: [LIPLINE_BUNDLE, "other"]})]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                lipline_catalog_row(invalid, reader)

    def fixture(self):
        class Reader:
            type = SimpleNamespace(name="Texture2D")
            assets_file = SimpleNamespace(name="CAB-lipline")
            path_id = 123
            def __init__(self):
                self.tree = {"m_Width": 80, "m_Height": 36, "m_MipCount": 1,
                             "m_TextureFormat": 4, "m_ColorSpace": 1,
                             "m_TextureSettings": {"m_FilterMode": 1, "m_WrapMode": 1, "m_Aniso": 1}}
            def peek_name(self): return LIPLINE_NAME
            def read(self): raise AssertionError("The lipline extension must not decode pixels")
            def read_typetree(self): return self.tree
        root, reader = Path("/synthetic"), Reader()
        return root, reader, {root / LIPLINE_BUNDLE: SimpleNamespace(objects=[reader])}

    def test_exact_non_square_metadata_without_decoding_or_cross_bundle_substitution(self):
        root, reader, bundles = self.fixture()
        row = lipline_texture_metadata(bundles, root)
        self.assertEqual({key: row[key] for key in ["width", "height", "mipLevels", "format", "serializedColorSpace", "filter", "wrap", "aniso"]},
                         {"width": 80, "height": 36, "mipLevels": 1, "format": 4, "serializedColorSpace": 1,
                          "filter": "Bilinear", "wrap": "Clamp", "aniso": 1})
        self.assertTrue(row["metadataOnly"] and "file" not in row and "pngSHA256" not in row)
        bundles[root / LIPLINE_BUNDLE].objects.append(reader)
        with self.assertRaisesRegex(ValueError, "Expected one cw_t_lip_line_000"):
            lipline_texture_metadata(bundles, root)
        bundles[root / LIPLINE_BUNDLE].objects.clear()
        bundles[root / "unrelated.unity3d"] = SimpleNamespace(objects=[reader])
        with self.assertRaisesRegex(ValueError, "Expected one cw_t_lip_line_000"):
            lipline_texture_metadata(bundles, root)

    def test_rejects_unverified_dimensions_format_color_space_mips_and_sampler(self):
        for field, value in [("m_Width", 81), ("m_Height", 37), ("m_MipCount", 2),
                             ("m_TextureFormat", 10), ("m_ColorSpace", 0)]:
            root, reader, bundles = self.fixture()
            reader.tree[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Unverified lipline"):
                lipline_texture_metadata(bundles, root)
        for field, value in [("m_FilterMode", 0), ("m_WrapMode", 0), ("m_Aniso", 2)]:
            root, reader, bundles = self.fixture()
            reader.tree["m_TextureSettings"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Unverified lipline"):
                lipline_texture_metadata(bundles, root)


if __name__ == "__main__":
    unittest.main()
