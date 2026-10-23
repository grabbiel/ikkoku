#!/usr/bin/env python3
"""Pure helpers of the shader-binding supplement exporter on synthetic trees."""
import unittest
from source_binding_supplement import catalog_rows, keywords, texture_settings


class KeywordTests(unittest.TestCase):
    def test_unity_56_single_string_and_later_lists(self):
        self.assertEqual(keywords({"m_ShaderKeywords": "_A  _B "}), ["_A", "_B"])
        self.assertEqual(keywords({"m_ShaderKeywords": ""}), [])
        self.assertEqual(keywords({"m_ShaderKeywords": ["_A", ""]}), ["_A"])
        self.assertEqual(keywords({"m_ValidKeywords": ["_V"], "m_InvalidKeywords": ["_X"]}), ["_V"])

    def test_missing_keyword_field_fails(self):
        with self.assertRaises(ValueError):
            keywords({"m_Name": "material"})


class TextureSettingsTests(unittest.TestCase):
    def tree(self, **settings):
        base = {"m_FilterMode": 1, "m_Aniso": 1, "m_WrapMode": 1}
        base.update(settings)
        return {"m_TextureSettings": base, "m_MipCount": 11, "m_Width": 1024, "m_Height": 512}

    def test_maps_unity_enums_and_mip_count(self):
        self.assertEqual(texture_settings(self.tree()),
                         {"filter": "Bilinear", "wrap": "Clamp", "aniso": 1, "mipLevels": 11, "width": 1024, "height": 512})
        self.assertEqual(texture_settings(self.tree(m_FilterMode=2, m_WrapMode=0, m_Aniso=9))["filter"], "Trilinear")
        # Per-axis serialization uses the U axis like Texture.wrapMode does.
        per_axis = self.tree()
        del per_axis["m_TextureSettings"]["m_WrapMode"]
        per_axis["m_TextureSettings"]["m_WrapU"] = 2
        self.assertEqual(texture_settings(per_axis)["wrap"], "Mirror")

    def test_boolean_mip_flag_leaves_count_unknown(self):
        tree = self.tree()
        del tree["m_MipCount"]
        tree["m_MipMap"] = True
        self.assertIsNone(texture_settings(tree)["mipLevels"])

    def test_incomplete_settings_fail(self):
        for tree in [{"m_Width": 1, "m_Height": 1}, self.tree(m_Aniso=None)]:
            with self.assertRaises(ValueError):
                texture_settings(tree)
        tree = self.tree()
        del tree["m_MipCount"]
        with self.assertRaises(ValueError):
            texture_settings(tree)


class CatalogRowTests(unittest.TestCase):
    table = {"mark": "【ChaListData】", "categoryNo": 432, "lstKey": ["ID", "MainTexAB", "MainTex"],
             "dictList": {2: ["2", "chara/mt_ramp_00.unity3d", "ramp_b"], 1: ["1", "chara/mt_ramp_00.unity3d", "ramp_a"]}}

    def test_selected_category_rows_in_id_order(self):
        rows = catalog_rows(self.table, "mt_ramp_00", {432})
        self.assertEqual([row["id"] for row in rows], [1, 2])
        self.assertEqual(rows[0], {"table": "mt_ramp_00", "category": 432, "id": 1,
                                   "row": {"ID": "1", "MainTexAB": "chara/mt_ramp_00.unity3d", "MainTex": "ramp_a"}})
        self.assertEqual(catalog_rows(self.table, "mt_ramp_00", {433}), [])

    def test_schema_and_row_width_are_checked(self):
        with self.assertRaises(ValueError):
            catalog_rows({**self.table, "mark": "other"}, "x", {432})
        with self.assertRaises(ValueError):
            catalog_rows({**self.table, "dictList": {1: ["1", "bundle"]}}, "x", {432})


if __name__ == "__main__":
    unittest.main()
