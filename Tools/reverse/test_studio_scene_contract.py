from pathlib import Path
import re
import sys
import unittest
from analysis.studio_scene_contract import MAX_LEVELS, Reader, Writer, scene_fixture, inspect_scene

SWIFT_READER = Path(__file__).resolve().parents[2] / "Packages/Engine/Sources/Studio/KoikatsuBinary.swift"


def nested_folders(levels):
    """Folder 0 holding folder 1, and so on down to folder levels - 1."""
    w = Writer()
    for key in range(levels):
        w.header(3, key); w.s("Synthetic folder"); w.i(0 if key == levels - 1 else 1)
    return bytes(w.data)


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


    def test_strings_keep_a_leading_bom_and_round_trip(self):
        # #418 mirror: BinaryReader.ReadString keeps a leading EF BB BF as U+FEFF; writing it back is byte-identical.
        for value in ("\ufeff", "\ufeffFolder", "\ufeff" + "y" * 200):
            writer = Writer(); writer.s(value)
            reader = Reader(bytes(writer.data))
            read = reader.s()
            self.assertEqual((read, reader.pos), (value, len(writer.data)))
            again = Writer(); again.s(read)
            self.assertEqual(again.data, writer.data)
        with self.assertRaises(ValueError):
            Reader(b"\x05\xef\xbb\xbf\xc0\x80").s()

    def test_the_depth_cap_matches_the_swift_reader(self):
        # #326: KoikatsuBinaryReader.maximumLevels, roots at depth 0.
        swift = re.search(r"static let maximumLevels = (\d+)", SWIFT_READER.read_text(encoding="utf-8"))
        self.assertEqual((MAX_LEVELS, int(swift.group(1))), (1000, 1000))
        limit = sys.getrecursionlimit()
        level, depth = Reader(nested_folders(MAX_LEVELS)).obj(), 1
        while level["children"]: level, depth = level["children"][0], depth + 1
        self.assertEqual(depth, MAX_LEVELS)
        # The same refusal as the Swift reader's, up to its "(Ikkoku reads at most ...)".
        with self.assertRaisesRegex(ValueError, "objects nested more than 1000 levels deep"):
            Reader(nested_folders(MAX_LEVELS + 1)).obj()
        self.assertEqual(sys.getrecursionlimit(), limit)


if __name__ == "__main__": unittest.main()
