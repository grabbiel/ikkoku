import unittest
from analysis.studio_scene_contract import scene_fixture, inspect_scene


class StudioSceneContractTests(unittest.TestCase):
    def test_full_current_character_route_and_tail(self):
        raw, expected = scene_fixture(); result = inspect_scene(raw)
        self.assertEqual(result["objectSectionEndOffset"], expected["objectSectionEndOffset"])
        self.assertEqual(result["baseSceneEndOffset"], expected["baseSceneEndOffset"])
        character = result["roots"]["10"]
        self.assertEqual(character["card"]["sha256"], expected["cardSHA256"])
        self.assertEqual(character["bones"]["1"]["transform"]["rotation"], [0, 15, 0])
        self.assertEqual(character["accessories"]["7"][0]["key"], 11)
        self.assertEqual(character["time"], 0.625)
        self.assertEqual(result["roots"]["20"]["points"][1]["linked"], True)
        self.assertEqual(result["settings"]["outside"]["source"], "sample.wav")
        self.assertEqual(len(result["settings"]["cameras"]), 11)

    def test_embedded_legacy_extension_does_not_consume_next_record(self):
        raw, expected = scene_fixture(legacy_card=True); result = inspect_scene(raw)
        self.assertEqual(result["roots"]["10"]["card"]["sha256"], expected["cardSHA256"])
        self.assertEqual(len(result["roots"]["10"]["bones"]), 2)

    def test_every_truncated_base_scene_rejects(self):
        raw, expected = scene_fixture()
        for size in range(expected["baseSceneEndOffset"]):
            with self.assertRaises((ValueError, UnicodeDecodeError, IndexError, KeyError)):
                inspect_scene(raw[:size])

    def test_unknown_trailer_preserved_and_dual_flags_retained(self):
        raw, expected = scene_fixture(both_modes=True)
        data = raw[:expected["baseSceneEndOffset"]] + b"opaque trailer"
        result = inspect_scene(data)
        self.assertEqual(result["trailingBytes"], 14)
        self.assertTrue(result["roots"]["10"]["enableFK"] and result["roots"]["10"]["enableIK"])


if __name__ == "__main__": unittest.main()
