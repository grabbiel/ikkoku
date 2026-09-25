#!/usr/bin/env python3
"""Numerical invariants for the recovered base-color shader equations."""
import unittest
import numpy as np
from head_material_contract import create_head_base, create_eye_base, create_eye_white


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


if __name__ == "__main__":
    unittest.main()
