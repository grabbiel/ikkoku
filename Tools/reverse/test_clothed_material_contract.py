import unittest
import numpy as np
from clothed_material_contract import ordered_tint, clothes_base, hair_base


class ClothedMaterialTests(unittest.TestCase):
    def test_later_regions_replace_earlier_regions(self):
        colors = np.array([[.8, .6, .4, 1], [.3, .5, .7, 1], [.2, .4, .9, 1]])
        mask = np.array([[[0, 0, 0, 1], [1, 0, 0, 1], [1, 1, 0, 1], [1, 1, 1, 1]]])
        np.testing.assert_allclose(ordered_tint(mask, colors), [[np.ones(3), *colors[:, :3]]])
        np.testing.assert_allclose(hair_base(mask, colors)[..., 3], 1)

    def test_clothes_clear_target_blend_preserves_original_alpha_equation(self):
        main = np.array([[[.8, .4, .2, .5]]])
        mask = np.array([[[1, 0, 0, 1]]])
        colors = np.array([[.5, .6, .7, 1], [1, 1, 1, 1], [1, 1, 1, 1]])
        np.testing.assert_allclose(clothes_base(main, mask, colors), [[[.2, .12, .07, .25]]])


if __name__ == '__main__':
    unittest.main()
