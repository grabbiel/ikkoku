#!/usr/bin/env python3
"""Boundaries for source skin palettes, sparse morph frames and UV channels."""
import copy
import unittest

from rig_inventory import morph_channels, skin_joint_palette, uv_channel


class SkinJointPaletteTests(unittest.TestCase):
    def test_exact_palette_is_unchanged(self):
        self.assertEqual(skin_joint_palette([4, 8], 2, [[0, 1, 0, 0]]), ([4, 8], None))

    def test_default_rejects_surplus(self):
        with self.assertRaises(ValueError):
            skin_joint_palette([4, 8, 12], 2, [[0, 1, 0, 0]])

    def test_opt_in_preserves_full_source_palette_in_audit(self):
        palette, audit = skin_joint_palette([4, 8, 12], 2, [[0, 1, 0, 0]], True)
        self.assertEqual(palette, [4, 8])
        self.assertEqual(audit["sourceRendererJointNodes"], [4, 8, 12])
        self.assertEqual((audit["originalCount"], audit["retainedCount"], audit["allLanesMax"]), (3, 2, 1))

    def test_every_lane_must_fit_even_if_it_would_have_zero_weight(self):
        with self.assertRaises(ValueError):
            skin_joint_palette([4, 8, 12], 2, [[0, 1, 2, 0]], True)

    def test_cannot_pad_missing_bones_or_accept_negative_indices(self):
        for joints, binds, indices in [([4], 2, [[0, 0, 0, 0]]), ([4, 8], 0, []), ([4, 8], 1, [[0, -1, 0, 0]])]:
            with self.assertRaises(ValueError):
                skin_joint_palette(joints, binds, indices, True)


class MorphChannelTests(unittest.TestCase):
    @staticmethod
    def fixture():
        return {"channels": [{"name": "face.example", "nameHash": 7, "frameIndex": 0, "frameCount": 1}],
                "shapes": [{"firstVertex": 0, "vertexCount": 1, "hasNormals": True, "hasTangents": True}],
                "fullWeights": [100.0],
                "vertices": [{"index": 1, "vertex": {"x": 1.0, "y": 2.0, "z": 3.0},
                              "normal": {"x": 0.0, "y": 0.2, "z": 0.0},
                              "tangent": {"x": -0.1, "y": 0.0, "z": 0.0}}]}

    def test_sparse_frame_retains_source_basis_weight_and_channel_metadata(self):
        source = self.fixture()
        before = copy.deepcopy(source)
        channels, frames = morph_channels(source, 3)
        self.assertEqual(source, before)
        self.assertEqual(channels[0]["nameHash"], 7)
        self.assertEqual(channels[0]["frames"], frames)
        self.assertEqual(frames[0], {"weight": 100.0, "indices": [1], "positionDeltas": [[1.0, 2.0, 3.0]],
                                     "normalDeltas": [[0.0, 0.2, 0.0]], "tangentDeltas": [[-0.1, 0.0, 0.0]]})

    def test_no_optional_streams_and_empty_sparse_frame_are_valid(self):
        source = self.fixture()
        source["shapes"][0].update(vertexCount=0, hasNormals=False, hasTangents=False)
        source["vertices"] = []
        _, frames = morph_channels(source, 3)
        self.assertEqual(frames[0], {"weight": 100.0, "indices": [], "positionDeltas": [], "normalDeltas": [], "tangentDeltas": []})
        self.assertEqual(morph_channels({}, 3), ([], []))

    def test_multiple_source_frames_export_without_interpolating_or_normalizing(self):
        source = self.fixture()
        source["channels"][0]["frameCount"] = 2
        source["shapes"].append(copy.deepcopy(source["shapes"][0]))
        source["fullWeights"] = [50.0, 125.0]
        channels, _ = morph_channels(source, 3)
        self.assertEqual([frame["weight"] for frame in channels[0]["frames"]], [50.0, 125.0])

    def test_invalid_frame_weight_counts_and_ranges_fail(self):
        cases = []
        source = self.fixture(); source["fullWeights"] = []; cases.append(source)
        source = self.fixture(); source["shapes"][0]["firstVertex"] = -1; cases.append(source)
        source = self.fixture(); source["shapes"][0]["vertexCount"] = 2; cases.append(source)
        source = self.fixture(); source["channels"][0]["frameIndex"] = 1; cases.append(source)
        source = self.fixture(); source["channels"][0]["frameCount"] = 0; cases.append(source)
        source = self.fixture(); source["channels"] = []; cases.append(source)
        source = self.fixture(); source["channels"].append({**source["channels"][0], "name": "overlap"}); cases.append(source)
        for source in cases:
            with self.subTest(source=source), self.assertRaises(ValueError):
                morph_channels(source, 3)

    def test_invalid_sparse_indices_fail(self):
        for index in (-1, 3, 1.5, True):
            source = self.fixture(); source["vertices"][0]["index"] = index
            with self.subTest(index=index), self.assertRaises(ValueError):
                morph_channels(source, 3)
        source = self.fixture()
        source["vertices"].append(copy.deepcopy(source["vertices"][0]))
        source["shapes"][0]["vertexCount"] = 2
        with self.assertRaises(ValueError):
            morph_channels(source, 3)

    def test_nonfinite_weights_and_delta_components_fail(self):
        for field in ("weight", "vertex", "normal", "tangent"):
            source = self.fixture()
            if field == "weight": source["fullWeights"][0] = float("nan")
            else: source["vertices"][0][field]["z"] = float("inf")
            with self.subTest(field=field), self.assertRaises(ValueError):
                morph_channels(source, 3)


class UVChannelTests(unittest.TestCase):
    def test_source_uv_values_are_preserved_without_v_flip(self):
        values = [[0.1, 0.8], [-0.2, 1.3]]
        self.assertIs(uv_channel(values, 2, "UV1"), values)
        self.assertEqual(uv_channel(None, 2, "UV2"), [])

    def test_partial_nonfinite_and_wrong_dimension_streams_fail(self):
        for values in ([[0, 1]], [[0, 1], [float("nan"), 0]], [[0, 1], [0, 1, 2]]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                uv_channel(values, 2, "UV2")


if __name__ == "__main__":
    unittest.main()
