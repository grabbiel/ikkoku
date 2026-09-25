import unittest
import numpy as np
from analysis.studio_pose_contract import ActivationOracle, FK_PARTS, bone_group, source_matrix, synthetic_oracle


class StudioPoseContractTests(unittest.TestCase):
    def test_body_and_guide_categories_are_distinct(self):
        self.assertEqual([bone_group(v) for v in range(5)], [1] * 5)
        self.assertEqual([bone_group(v, guide=True) for v in range(5)], [1, 3, 5, 9, 17])
        self.assertEqual([bone_group(v) for v in range(7, 14)], [128, 128, 128, 256, 512, 512, 1024])
        with self.assertRaises(ValueError): bone_group(14)

    def test_euler_order_reflection_and_preserved_native_translation(self):
        matrix = np.array(source_matrix([90, 90, 0], [1, 2, -3], [2, 3, 4]))
        np.testing.assert_allclose(matrix, [[0, 3, 0, 1], [0, 0, 4, 2], [2, 0, 0, -3], [0, 0, 0, 1]], atol=1e-12)
        np.testing.assert_allclose(source_matrix([450, -720, 1080]), source_matrix([90, 0, 0]), atol=1e-12)
        with self.assertRaises(ValueError): source_matrix([float("nan"), 0, 0])

    def test_disabled_fk_changes_preference_only(self):
        state = ActivationOracle()
        report = state.command(["fk", 32, True, False])
        self.assertTrue(report["activeFK"][4]); self.assertEqual(report["events"], [])
        self.assertEqual(report["enabledTargets"], [True] * 7)

    def test_disabling_resets_only_reactive_groups_and_only_once(self):
        state = ActivationOracle()
        report = state.command(["fk", sum(FK_PARTS), False, True])
        self.assertEqual(report["resetGroups"], [128, 1, 1024])
        self.assertEqual(state.command(["fk", sum(FK_PARTS), False, True])["resetGroups"], [])
        self.assertEqual(state.fk_preferences, [False, True, False, True, False, False, False])

    def test_force_neck_activation_recaptures_pattern(self):
        state = ActivationOracle()
        state.command(["fk", 256, True, True]); self.assertEqual(state.old_neck, 2)
        state.command(["fk", 256, True, True]); self.assertEqual(state.old_neck, 4)
        state.command(["fk", 256, False, True]); self.assertEqual(state.neck, 4)

    def test_mode_exclusivity_preserves_preferences(self):
        state = ActivationOracle()
        state.command(["mode", "fk", True, False])
        self.assertTrue(state.fk); self.assertFalse(state.ik)
        report = state.command(["mode", "ik", True, False])
        self.assertFalse(state.fk); self.assertTrue(state.ik)
        self.assertEqual(state.fk_preferences, [False, True, False, True, False, False, False])
        self.assertEqual(report["events"][-2:], [["pv", True, False, True, False]] * 2)

    def test_ik_off_still_changes_solver_weights_but_not_guides(self):
        state = ActivationOracle()
        report = state.command(["ik", 8, False, False])
        self.assertEqual(report["events"], [["ikWeights", 8, 0], ["ikGuide", 8, False]])
        report = state.command(["ik", 8, True, False])
        self.assertEqual(report["events"], [["ikWeights", 8, 1], ["ikGuide", 8, False]])

    def test_oracle_covers_angular_and_activation_boundaries(self):
        oracle = synthetic_oracle()
        self.assertEqual(len(oracle["matrixCases"]), 7)
        self.assertEqual(len(oracle["activationCases"]), 12)
        self.assertEqual(len(oracle["groupCases"]), 14)


if __name__ == "__main__": unittest.main()
