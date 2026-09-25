#!/usr/bin/env python3
"""Independent source-card framing, preservation and bounded-input regression tests."""
import dataclasses
import math
import struct
import unittest

import msgpack

from analysis import card_contract as card


def pack(value):
    return msgpack.packb(value, use_bin_type=True, use_single_float=True)


def frame(infos, payload, footer=b""):
    header = pack({"lstInfo": infos})
    return (struct.pack("<i", 100) + card.dotnet_string(card.MAGIC) + card.dotnet_string("0.0.0") +
            struct.pack("<ii", 0, len(header)) + header + struct.pack("<q", len(payload)) + payload + footer)


class CardContractTests(unittest.TestCase):
    def setUp(self):
        # A tiny valid source-format ABMX array; real decoder coverage is separate.
        self.bone_data = pack([["synthetic_bone", [[[1., 1., 1.], 1., [0., 0., 0.], [0., 0., 0.]]], 1]])
        self.data = card.fixture_bytes(self.bone_data)
        self.parsed = card.parse_card(self.data)

    def corrupt(self, offset, fmt, value):
        data = bytearray(self.data)
        struct.pack_into(fmt, data, offset, value)
        return bytes(data)

    def test_complete_card_shape_and_binary_fields(self):
        report = self.parsed.report
        self.assertEqual((report["productNo"], report["version"], report["parameter"]["sex"], report["custom"]["headId"]), (100, "0.0.0", 1, 0))
        self.assertEqual([len(report["custom"][key]) for key in ("shapeValueFace", "shapeValueBody")], [52, 44])
        self.assertEqual(report["custom"]["shapeValueFace"][0], 0)
        self.assertEqual(report["custom"]["shapeValueFace"][-1], 1)
        self.assertEqual(report["custom"]["shapeValueBody"][-1], 1)
        self.assertEqual(report["extendedDataSource"], "current-v3")
        abmx = next(plugin for plugin in self.parsed.plugins if plugin["id"] == card.ABMX)
        self.assertEqual(abmx["version"], 2)
        self.assertEqual(abmx["binaryValues"]["boneData"]["raw"], self.bone_data)

    def test_offsets_refer_to_exact_original_bytes(self):
        report = self.parsed.report
        offsets = report["offsets"]
        self.assertEqual(self.data[:offsets["pngEnd"]], card.blank_png())
        self.assertEqual(struct.unpack_from("<i", self.data, offsets["productNo"])[0], 100)
        self.assertEqual(struct.unpack_from("<q", self.data, offsets["payloadLength"])[0], report["payloadBytes"])
        self.assertEqual(offsets["payloadEnd"] - offsets["payloadStart"], report["payloadBytes"])
        for block in self.parsed.blocks:
            self.assertEqual(self.data[block["offset"]:block["offset"] + block["size"]], block["raw"])
        for plugin in self.parsed.plugins:
            self.assertEqual(self.data[plugin["offset"]:plugin["offset"] + plugin["size"]], plugin["raw"])

    def test_unknown_block_plugin_and_original_are_retained(self):
        self.assertIs(self.parsed.raw, self.data)
        block = next(block for block in self.parsed.blocks if block["name"] == "FixtureUnknown")
        self.assertEqual(block["raw"], b"\x00opaque unknown block\xff")
        plugin = next(plugin for plugin in self.parsed.plugins if plugin["id"] == "example.unknown")
        self.assertEqual(msgpack.unpackb(plugin["raw"]), [7, {"origin": "current", "opaque": b"\x00\xffunknown\x00"}])

    def test_header_order_is_not_payload_order(self):
        self.assertEqual(self.parsed.blocks[0]["name"], "KKEx")
        self.assertGreater(self.parsed.blocks[0]["pos"], self.parsed.blocks[1]["pos"])

    def test_no_png_and_no_extended_data(self):
        parsed = card.parse_card(card.fixture_bytes(self.bone_data, png=False, current=False))
        self.assertEqual(parsed.report["pngBytes"], 0)
        self.assertEqual(parsed.report["extendedDataSource"], "none")
        self.assertEqual(parsed.plugins, [])

    def test_legacy_v2_framing_and_precedence(self):
        for current in (False, True):
            with self.subTest(current=current):
                parsed = card.parse_card(card.fixture_bytes(self.bone_data, current=current, legacy=True))
                self.assertEqual(parsed.report["extendedDataSource"], "legacy-v2")
                plugin = next(plugin for plugin in parsed.plugins if plugin["id"] == "example.unknown")
                self.assertEqual(plugin["dataNodes"]["origin"].value, "legacy")
                self.assertEqual(parsed.footer, b"")

    def test_unknown_footer_is_retained_without_losing_current_data(self):
        footer = b"opaque trailer\0\xff"
        parsed = card.parse_card(card.fixture_bytes(self.bone_data, footer=footer))
        self.assertEqual(parsed.footer, footer)
        self.assertEqual(parsed.report["extendedDataSource"], "current-v3")

    def test_broken_legacy_retains_current_and_complete_footer(self):
        for raw, count in ((b"\xc1", 1), (b"\x81", 1000), (b"", -1)):
            footer = card.dotnet_string("KKEx") + struct.pack("<ii", 2, count) + raw
            parsed = card.parse_card(card.fixture_bytes(self.bone_data, footer=footer))
            self.assertEqual(parsed.report["extendedDataSource"], "current-v3")
            self.assertEqual(parsed.footer, footer)
            self.assertIn("unparsed-footer-preserved", parsed.report["diagnostics"])

    def test_legacy_valid_short_read_at_eof_overrides_current(self):
        raw = pack({"legacy": [2, {}]})
        count = len(raw) + 50
        footer = card.dotnet_string("KKEx") + struct.pack("<ii", 2, count) + raw
        parsed = card.parse_card(card.fixture_bytes(self.bone_data, footer=footer))
        self.assertEqual(parsed.report["extendedDataSource"], "legacy-v2")
        self.assertEqual(parsed.plugins[0]["id"], "legacy")
        self.assertEqual(parsed.report["legacy"]["declaredSize"], count)
        self.assertEqual(parsed.report["legacy"]["size"], len(raw))
        self.assertEqual(parsed.footer, b"")

    def test_current_error_yields_empty_plugins_but_preserves_block(self):
        raw = b"\xc1"
        parsed = card.parse_card(frame([{"name": "KKEx", "version": "3", "pos": 0, "size": len(raw)}], raw))
        self.assertEqual(parsed.plugins, [])
        self.assertEqual(parsed.blocks[0]["raw"], raw)
        self.assertIn("current-kkex-invalid-preserved", parsed.report["diagnostics"])

    def test_valid_legacy_recovers_after_current_error(self):
        raw, legacy = b"\xc1", pack({"legacy": [2, {}]})
        footer = card.dotnet_string("KKEx") + struct.pack("<ii", 2, len(legacy)) + legacy
        parsed = card.parse_card(frame([{"name": "KKEx", "version": "3", "pos": 0, "size": 1}], raw, footer))
        self.assertEqual(parsed.report["extendedDataSource"], "legacy-v2")
        self.assertEqual(parsed.plugins[0]["id"], "legacy")

    def test_plugin_nil_missing_and_trailing_slots_follow_formatter(self):
        raw = pack({"nil": None, "empty": [], "versionOnly": [7], "nilData": [8, None],
                    "extra": [9, {"opaque": b"x"}, {"future": [1, 2, 3]}]})
        parsed = {plugin["id"]: plugin for plugin in card.parse_plugins(raw, 100, card.Limits())}
        self.assertTrue(parsed["nil"]["isNull"])
        self.assertEqual(parsed["empty"]["version"], 0)
        self.assertTrue(all(parsed[key]["dataIsNull"] for key in ("empty", "versionOnly", "nilData")))
        self.assertEqual(parsed["extra"]["trailingSlots"], 1)
        self.assertEqual(parsed["extra"]["binaryValues"]["opaque"]["raw"], b"x")
        self.assertEqual(card.parse_plugins(b"\xc0", 0, card.Limits()), [])

    def test_dictionary_duplicate_keys_and_plugin_schema_are_rejected(self):
        duplicate = b"\x82" + (pack("same") + pack([2, {}])) * 2
        for raw in (duplicate, pack({"bad": {"version": 2}}), pack({"bad": [True, {}]}),
                    pack({"bad": [2**31, {}]}), pack({"bad": [2, []]})):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                card.parse_plugins(raw, 0, card.Limits())

    def test_source_hook_base_uses_end_minus_size_sum(self):
        # Deliberately noncanonical: the hook starts after the payload gap.
        raw = pack({"source": [2, {}]})
        parsed = card.parse_card(frame([{"name": "KKEx", "version": "3", "pos": 0, "size": len(raw)}], b"gap" + raw))
        self.assertEqual(parsed.report["extendedDataSource"], "current-v3")
        self.assertEqual(parsed.plugins[0]["id"], "source")
        self.assertEqual(parsed.report["offsets"]["currentExtendedData"], parsed.report["offsets"]["payloadStart"] + 3)

    def test_source_hook_reads_across_declared_payload_boundary(self):
        raw = pack({"source": [2, {}]})
        payload, footer = b"gap!" + raw[:-2], raw[-2:]
        info = {"name": "KKEx", "version": "3", "pos": 2, "size": len(raw)}
        parsed = card.parse_card(frame([info], payload, footer))
        self.assertEqual(parsed.report["extendedDataSource"], "current-v3")
        self.assertEqual(parsed.plugins[0]["id"], "source")
        self.assertEqual(parsed.report["offsets"]["currentExtendedData"], parsed.report["offsets"]["payloadStart"] + 4)
        self.assertEqual(parsed.footer, footer)

    def test_source_hook_accepts_valid_short_read_at_eof(self):
        raw = pack({"source": [2, {}]})
        info = {"name": "KKEx", "version": "3", "pos": 2, "size": len(raw) + 2}
        parsed = card.parse_card(frame([info], b"gap!" + raw))
        self.assertEqual(parsed.report["extendedDataSource"], "current-v3")
        self.assertEqual(parsed.plugins[0]["id"], "source")
        self.assertEqual(parsed.report["offsets"]["currentExtendedData"], parsed.report["offsets"]["payloadStart"] + 4)

    def test_first_block_name_lookup_matches_source(self):
        raw = pack({"first": [2, {}]})
        infos = [{"name": "KKEx", "version": "unsupported", "pos": 0, "size": 0},
                 {"name": "KKEx", "version": "3", "pos": 0, "size": len(raw)}]
        parsed = card.parse_card(frame(infos, raw))
        self.assertEqual(parsed.report["extendedDataSource"], "none")
        self.assertIn("unsupported-current-kkex-version", parsed.report["diagnostics"])

    def test_framing_lengths_truncation_and_product_are_bounded(self):
        offsets = self.parsed.report["offsets"]
        for key, fmt, value in (("productNo", "<i", 101), ("facePngLength", "<i", -1),
                                ("headerLength", "<i", -1), ("headerLength", "<i", 2**31 - 1),
                                ("payloadLength", "<q", -1), ("payloadLength", "<q", 2**63 - 1)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                card.parse_card(self.corrupt(offsets[key], fmt, value))
        for count in (0, 8, offsets["headerStart"] + 1, offsets["payloadEnd"] - 1):
            with self.subTest(count=count), self.assertRaises(ValueError):
                card.parse_card(self.data[:count])
        with self.assertRaises(ValueError):
            card.parse_card(self.data, dataclasses.replace(card.Limits(), card_bytes=len(self.data) - 1))

    def test_block_ranges_are_bounded_before_slicing(self):
        for pos, size in ((-1, 1), (0, -1), (2, 1), (1, 2), (2**63, 0)):
            with self.subTest(pos=pos, size=size), self.assertRaises(ValueError):
                card.parse_card(frame([{"name": "unknown", "version": "1", "pos": pos, "size": size}], b"x"))

    def test_png_crc_length_and_chunk_count_are_bounded(self):
        data = bytearray(self.data)
        data[29] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"):
            card.parse_card(bytes(data))
        with self.assertRaises(ValueError):
            card.parse_card(self.corrupt(8, ">I", 2**32 - 1))
        with self.assertRaises(ValueError):
            card.parse_card(self.data, dataclasses.replace(card.Limits(), png_chunks=1))

    def test_dotnet_string_byte_length_and_overflow(self):
        for value in (card.MAGIC, "x" * 128, "𐀀" * 100):
            cursor = card.Cursor(card.dotnet_string(value))
            self.assertEqual(cursor.dotnet_string(), value)
            self.assertEqual(cursor.offset, len(cursor.data))
        for data in (b"\x80", b"\xff\xff\xff\xff\x7f", b"\x80\x80\x80\x80\x80", b"\x01\xff"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                card.Cursor(data).dotnet_string()

    def test_messagepack_budgets_extensions_and_trailing_bytes(self):
        for data, limits in ((b"\xdd\xff\xff\xff\xff", card.Limits()),
                             (b"\xdb\x7f\xff\xff\xff", card.Limits()),
                             (pack([[[1]]]), dataclasses.replace(card.Limits(), depth=1)),
                             (pack([1, 2, 3]), dataclasses.replace(card.Limits(), nodes=2)),
                             (b"\xc0\xc0", card.Limits()), (b"\xc1", card.Limits())):
            with self.subTest(data=data), self.assertRaises(ValueError):
                card.unpack(data, limits)
        ext = card.unpack(pack(msgpack.ExtType(99, b"opaque")), card.Limits())
        self.assertEqual((ext.kind, ext.value), ("ext", (99, b"opaque")))

    def test_invalid_shape_numbers_counts_and_booleans(self):
        for values in ([0.] * 51, [0.] * 51 + [math.nan], [0.] * 51 + [math.inf], [0.] * 51 + [True]):
            with self.subTest(values=values[-1:]), self.assertRaises(ValueError):
                card.shape_values(card.unpack(pack(values), card.Limits()), 52)

    def test_fixture_generation_is_deterministic(self):
        self.assertEqual(self.data, card.fixture_bytes(self.bone_data))
        self.assertEqual(self.parsed.report, card.parse_card(self.data).report)


if __name__ == "__main__":
    unittest.main()
