#!/usr/bin/env python3
"""Small synthetic pose comparisons; no captured game data is read."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np

import compare_original_pose as subject


def bone(path, position=(0, 0, 0), rotation=(0, 0, 0, 1), scale=(1, 1, 1)):
    return {"path": path, "position": list(position), "rotation": list(rotation),
            "scale": list(scale)}


def native_tree(names, parents, matrices):
    # Column-major flat arrays, as emitted by card-pose.
    return subject.build_native_tree({
        "nodeNames": names, "nodeParents": parents,
        "nodeWorldMatrices": [matrix.T.reshape(-1).tolist() for matrix in matrices],
    })


def compare(original, native):
    matching = subject.match_bones(native, original)
    return subject.compare_bones(native, original, matching, 1e-4, 0.01, 1e-4)


class PoseComparisonTest(unittest.TestCase):
    def test_identity_match_composes_local_trs_and_ignores_wrapper_transform(self):
        original = subject.compose_original_worlds([
            bone("Wrapper", (100, 0, 0)),
            bone("Wrapper/Extra", (1, 0, 0)),
            bone("Wrapper/Extra/p_cf_body_bone", (0, 2, 0), scale=(1, 2, 3)),
            bone("Wrapper/Extra/p_cf_body_bone/cf_j_spine", (0, 1, -1)),
        ])
        np.testing.assert_array_equal(original["world"]["Wrapper"], np.eye(4))
        paths = ["Wrapper/Extra/p_cf_body_bone",
                 "Wrapper/Extra/p_cf_body_bone/cf_j_spine"]
        native = native_tree(
            ["Native", "p_cf_body_bone", "cf_j_spine"], [-1, 0, 1],
            [np.eye(4)] + [subject.REFLECTION @ original["world"][path] @ subject.REFLECTION
                           for path in paths])
        result = compare(original, native)
        self.assertEqual(result["boneCount"], 2)
        self.assertEqual(result["outlierCount"], 0)
        self.assertLess(result["summary"]["position"]["max"], 1e-12)
        self.assertLess(result["summary"]["rotationDeg"]["max"], 1e-5)
        self.assertLess(result["summary"]["scale"]["max"], 1e-12)
        self.assertEqual(result["unmatchedOriginalKeys"], [])
        self.assertEqual(result["unmatchedNativeKeys"], [])

    def test_known_ninety_degree_rotation_outlier(self):
        original = subject.compose_original_worlds([
            bone("Wrapper"), bone("Wrapper/p_cf_body_bone")])
        quarter_turn = subject.local_matrix(bone("unused", rotation=(
            math.sin(math.pi / 4), 0, 0, math.cos(math.pi / 4))))
        native = native_tree(["Native", "p_cf_body_bone"], [-1, 0],
                             [np.eye(4), quarter_turn])
        result = compare(original, native)
        self.assertAlmostEqual(result["summary"]["rotationDeg"]["max"], 90.0)
        self.assertEqual(result["summary"]["rotationDeg"]["overTolerance"], 1)
        self.assertEqual(result["classification"]["other"]["count"], 1)

    def test_column_major_translation_is_last_column(self):
        matrix = np.eye(4)
        matrix[:3, 3] = [3, 7, 11]
        native = native_tree(["p_cf_body_bone"], [-1], [matrix])
        np.testing.assert_array_equal(native["matrices"][0][:3, 3], [3, 7, 11])
        self.assertEqual(native["paths"][0], "p_cf_body_bone")

    def test_errors_use_euclidean_position_and_column_norm_scales(self):
        quarter_turn = (math.sin(math.pi / 4), 0, 0, math.cos(math.pi / 4))
        reference = subject.local_matrix(bone("unused", rotation=quarter_turn,
                                              scale=(2, 3, 4)))
        native = subject.local_matrix(bone("unused", (3, 4, 0), quarter_turn,
                                           scale=(2, 3, 4.5)))
        errors = subject.transform_errors(reference, native)
        self.assertAlmostEqual(errors["position"], 5.0)
        self.assertAlmostEqual(errors["scale"], 0.5)
        self.assertAlmostEqual(errors["rotationDeg"], 0.0, delta=1e-5)

    def test_z_reflection_applies_only_to_original_world(self):
        original = subject.compose_original_worlds([
            bone("Wrapper"), bone("Wrapper/p_cf_body_bone", (1, 2, -3))])
        native = native_tree(["Native", "p_cf_body_bone"], [-1, 0],
                             [np.eye(4), subject.local_matrix(
                                 bone("unused", (1, 2, 3)))])
        self.assertEqual(compare(original, native)["outlierCount"], 0)
        self.assertAlmostEqual(subject.transform_errors(
            original["world"]["Wrapper/p_cf_body_bone"],
            native["matrices"][1])["position"], 6.0)

    def test_duplicate_path_and_suffix_ambiguities_are_excluded(self):
        original = subject.compose_original_worlds([
            bone("Wrapper"), bone("Wrapper/p_cf_body_bone"),
            bone("Wrapper/p_cf_body_bone/cf_j_spine"),
            bone("Wrapper/p_cf_body_bone/cf_j_spine", (1, 0, 0)),
            bone("Wrapper/p_cf_body_bone/cf_j_spine/child"),
            bone("Wrapper/A"), bone("Wrapper/A/p_cf_body_bone"),
            bone("Wrapper/B"), bone("Wrapper/B/p_cf_body_bone"),
        ])
        native = native_tree(
            ["Native", "p_cf_body_bone", "cf_j_spine", "p_cf_body_bone", "ghost"],
            [-1, 0, 1, 0, 1], [np.eye(4)] * 5)
        matching = subject.match_bones(native, original)
        self.assertEqual(matching["pairs"], {})
        self.assertEqual({item["key"] for item in matching["ambiguousKeys"]},
                         {"p_cf_body_bone", "p_cf_body_bone/cf_j_spine"})
        self.assertEqual(matching["ambiguousKeys"][0]["nativePaths"],
                         ["Native/p_cf_body_bone", "Native/p_cf_body_bone"])
        self.assertIn("Wrapper/p_cf_body_bone/cf_j_spine/child",
                      matching["excludedOriginalPaths"])
        self.assertEqual(matching["unmatchedNativeKeys"],
                         ["p_cf_body_bone/ghost"])
        self.assertEqual(matching["unmatchedOriginalKeys"], [])
        self.assertEqual(original["duplicates"],
                         [{"path": "Wrapper/p_cf_body_bone/cf_j_spine", "copies": 2}])

    def test_hand_classification_and_diagnostic_gate(self):
        for name in ("cf_j_hand_L", "cf_j_hand_R/child", "cf_j_thumb01_L",
                     "cf_j_index01_R", "cf_j_middle01_L", "cf_j_ring01_R",
                     "cf_j_little01_L"):
            self.assertEqual(subject.classification(f"p_cf_body_bone/{name}"), "hand")
        self.assertEqual(subject.classification("p_cf_body_bone/cf_j_shoulder_L"), "other")

        with tempfile.TemporaryDirectory() as folder:
            probe = Path(folder)
            (probe / "frame.json").write_text(json.dumps({
                "card": "card.bin",
                "bones": [bone("Wrapper"), bone("Wrapper/p_cf_body_bone"),
                          bone("Wrapper/p_cf_body_bone/cf_j_hand_L")],
            }))
            (probe / "card.bin").write_bytes(b"synthetic card")
            (probe / "avatar.json").write_text("{}")
            native = {"nodeNames": ["Native", "p_cf_body_bone", "cf_j_hand_L"],
                      "nodeParents": [-1, 0, 1],
                      "nodeWorldMatrices": [np.eye(4).T.reshape(-1).tolist(),
                                            np.eye(4).T.reshape(-1).tolist(),
                                            subject.local_matrix(bone("unused", (1, 0, 0)))
                                            .T.reshape(-1).tolist()],
                      "appliedInputs": {}}
            (probe / "native.json").write_text(json.dumps(native))
            output = io.StringIO()
            argv = ["compare_original_pose.py", str(probe), str(probe / "native.json"),
                    "--avatar", str(probe / "avatar.json")]
            with mock.patch.object(sys, "argv", argv), redirect_stdout(output):
                with self.assertRaises(SystemExit) as exit_context:
                    subject.main()
            self.assertEqual(exit_context.exception.code, 1)
            report = json.loads(output.getvalue())
            self.assertFalse(report["gatePassed"])
            self.assertTrue(report["gatePassedExcludingHands"])
            self.assertIn("Diagnostic only", report["gatePassedExcludingHandsNote"])
            self.assertEqual(report["comparison"]["classification"]["hand"]["count"], 1)
            self.assertEqual(report["comparison"]["classification"]["other"]["count"], 0)
            self.assertEqual(report["comparison"]["outlierCount"], 1)
            self.assertEqual(len(report["sourceFrameSHA256"]), 64)
            self.assertEqual(len(report["cardSHA256"]), 64)
            self.assertEqual(len(report["avatarSHA256"]), 64)
            self.assertEqual(report["numpyVersion"], np.__version__)
            self.assertIn("scope", report)

    def test_avatar_defaults_to_native_snapshot_source(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Path(folder)
            (probe / "frame.json").write_text(json.dumps({
                "card": "card.bin",
                "bones": [bone("Wrapper"), bone("Wrapper/p_cf_body_bone")],
            }))
            (probe / "card.bin").write_bytes(b"synthetic card")
            avatar = probe / "avatar.json"
            avatar.write_text("{}")
            snapshot = probe / "native.json"
            native = {
                "source": str(avatar),
                "nodeNames": ["Native", "p_cf_body_bone"],
                "nodeParents": [-1, 0],
                "nodeWorldMatrices": [np.eye(4).T.reshape(-1).tolist()] * 2,
                "appliedInputs": {},
            }
            snapshot.write_text(json.dumps(native))
            output = io.StringIO()
            argv = ["compare_original_pose.py", str(probe), str(snapshot)]
            with mock.patch.object(sys, "argv", argv), redirect_stdout(output):
                subject.main()
            report = json.loads(output.getvalue())
            self.assertTrue(report["gatePassed"])
            self.assertEqual(report["verifiedSources"][-1]["path"], str(avatar))
            self.assertEqual(report["avatarSHA256"], subject.file_record(avatar)["sha256"])

            del native["source"]
            snapshot.write_text(json.dumps(native))
            error = io.StringIO()
            with mock.patch.object(sys, "argv", argv), redirect_stderr(error):
                with self.assertRaises(SystemExit) as exit_context:
                    subject.main()
            self.assertEqual(exit_context.exception.code, 2)
            self.assertIn("missing 'source' field", error.getvalue())


if __name__ == "__main__":
    unittest.main()
