"""Pure-helper regressions for the eye shader contract tool."""
import unittest

from eye_shader_contract import shader_dependency_paths


class ShaderDependencyTests(unittest.TestCase):
    def test_file_id_zero_keeps_the_shader_in_the_material_bundle(self):
        self.assertEqual(shader_dependency_paths(0, ["chara/sibling.unity3d"]), [])
        self.assertEqual(shader_dependency_paths(0, []), [])

    def test_positive_file_id_indexes_externals_one_based(self):
        externals = ["archive:/cab-aaaa", "unity default resources"]
        self.assertEqual(shader_dependency_paths(2, externals), ["unity default resources"])

    def test_file_id_beyond_the_externals_is_rejected(self):
        with self.assertRaises(ValueError):
            shader_dependency_paths(2, ["only-one"])


if __name__ == "__main__":
    unittest.main()
