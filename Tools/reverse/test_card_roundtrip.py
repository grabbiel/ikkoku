"""Independent structural invariants for edited original-format cards."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent / "analysis"))
import card_roundtrip as oracle
from card_contract import Limits, unpack


class CardRoundtripTests(unittest.TestCase):
    def test_changed_float32_leaf_preserves_other_wire_tokens(self):
        before = bytes.fromhex("82a178cb3fe0000000000000a179d201020304")
        after = bytes.fromhex("82a178ca3e800000a179d201020304")
        self.assertEqual(oracle.compare_tokens(before, after, {("x",): 0.25}), 1)

    def test_equal_semantics_do_not_allow_unedited_encoding_changes(self):
        before = bytes.fromhex("81a17801")
        after = bytes.fromhex("81a178cc01")
        with self.assertRaisesRegex(ValueError, "Unedited token"):
            oracle.compare_tokens(before, after, {})

    def test_unknown_binary_and_extension_values_must_survive(self):
        before = bytes.fromhex("82a178c403000102a179d404fe")
        for after in [bytes.fromhex("82a178c403000103a179d404fe"), bytes.fromhex("82a178c403000102a179d404ff")]:
            with self.assertRaises(ValueError):
                oracle.compare_tokens(before, after, {})

    def test_unknown_integer_keyed_container_stays_opaque(self):
        before = bytes.fromhex("82a178ca3f000000a1798201020103")
        after = bytes.fromhex("82a178ca3e800000a1798201020103")
        self.assertEqual(oracle.compare_tokens(before, after, {("x",): 0.25}), 1)

    def test_missing_changed_field_and_wrong_value_are_rejected(self):
        card = bytes.fromhex("81a178ca3f000000")
        with self.assertRaisesRegex(ValueError, "absent"):
            oracle.compare_tokens(card, card, {("y",): 1.0})
        with self.assertRaisesRegex(ValueError, "Incorrect edited"):
            oracle.compare_tokens(card, card, {("x",): 1.0})

    def test_map_order_and_container_encodings_remain_exact(self):
        before = bytes.fromhex("82a17801a17902")
        for after in [bytes.fromhex("82a17902a17801"), bytes.fromhex("de0002a17801a17902")]:
            with self.assertRaises(ValueError):
                oracle.compare_tokens(before, after, {})

    @unittest.skipUnless((oracle.ROOT / ".local/reverse/cards/edited-roundtrip/edited.png").exists(), "Generate explicit Swift edited-card fixture first")
    def test_native_writer_against_independent_original_format_oracle(self):
        report = oracle.validate(oracle.ROOT / ".local/reverse/cards/edited-roundtrip")
        self.assertTrue(report["success"])
        self.assertEqual(report["editedNumericLeaves"], 27)
        self.assertEqual(report["characterSex"], 0)
        self.assertEqual(report["relocatedHeaderFields"], 6)
        self.assertIn("KKEx", report["unchangedBlocks"])


if __name__ == "__main__":
    unittest.main()
