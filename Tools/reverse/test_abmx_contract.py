#!/usr/bin/env python3
"""Synthetic wire-format/repair checks; no original cards or DLLs are required."""
import copy
import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

import lz4.block
import msgpack

from analysis import abmx_contract as abmx


def packed(records):
    return msgpack.packb(records, use_bin_type=True, use_single_float=True)


def wrapped(raw, size=None):
    # Independent fixture construction from the inspected source wire format.
    content = b"\xd2" + struct.pack(">i", len(raw) if size is None else size)
    content += lz4.block.compress(raw, store_size=False)
    return b"\xc9" + struct.pack(">I", len(content)) + b"\x63" + content


def modifier(name="synthetic_bone", coordinates=None, location=1):
    if coordinates is None:
        coordinates = [copy.deepcopy(abmx.IDENTITY)]
    return [name, coordinates, location]


class ABMXContractTests(unittest.TestCase):
    def test_plain_and_original_lz4_extension_decode_identical_records(self):
        values = [[1.25, 0.75, 1], 1.5, [0.125, -0.25, 0.5], [10, 20, 30]]
        records = [modifier(coordinates=[values]), modifier("second", location=0)]
        raw = packed(records)
        compressed = wrapped(raw)
        self.assertGreaterEqual(len(raw), 64)
        self.assertEqual(compressed[0], 0xC9)
        self.assertEqual(compressed[5:7], b"\x63\xd2")
        a, b = abmx.convert(raw), abmx.convert(compressed)
        self.assertEqual(a["modifiers"], b["modifiers"])
        self.assertEqual(a["diagnostics"], [])
        self.assertEqual(b["source"]["payloadSHA256"], abmx.sha(compressed))
        self.assertNotEqual(a["source"]["payloadSHA256"], b["source"]["payloadSHA256"])
        self.assertEqual(abmx.source_payload([]), packed([]))

    def test_bone_names_keep_a_leading_bom(self):
        # #418 mirror: a "\ufeffbone" record names another bone; the hash is over the original bytes.
        raw = packed([modifier("\ufeffsynthetic_bone"), modifier("synthetic_bone", location=0)])
        for payload in (raw, wrapped(raw)):
            result = abmx.convert(payload)
            self.assertEqual([m["boneName"] for m in result["modifiers"]], ["\ufeffsynthetic_bone", "synthetic_bone"])
            self.assertEqual(result["source"]["payloadSHA256"], abmx.sha(payload))

    def test_current_card_and_coordinate_versions_preserve_data(self):
        payload = packed([modifier()])
        for kind, version in [("card", 2), ("coordinate", 3)]:
            with self.subTest(kind=kind, version=version):
                result = abmx.convert(payload, kind, version)
                self.assertEqual(result["source"]["dataKind"], kind)
                self.assertEqual(result["source"]["dataVersion"], version)
                self.assertEqual(result["modifiers"][0]["boneName"], "synthetic_bone")
        for kind, version in [("card", 1), ("card", 3), ("coordinate", 2), ("coordinate", 4), ("unknown", 2)]:
            with self.subTest(kind=kind, version=version), self.assertRaisesRegex(ValueError, "source versions"):
                abmx.convert(payload, kind, version)

    def test_null_coordinate_elements_are_repaired_without_losing_other_outfits(self):
        changed = [[1.5, 1, 1], 2, [0.25, 0, 0], [0, 15, 0]]
        records = [modifier(coordinates=[None, changed, None])]
        for payload in [packed(records), wrapped(packed(records))]:
            converted = abmx.convert(payload)
            data = converted["modifiers"][0]["coordinateModifiers"]
            identity = {"scaleModifier": [1, 1, 1], "lengthModifier": 1,
                        "positionModifier": [0, 0, 0], "rotationModifier": [0, 0, 0]}
            self.assertEqual(len(data), 3)
            self.assertEqual(data[0], identity)
            self.assertEqual(data[2], identity)
            self.assertEqual(data[1]["scaleModifier"], changed[0])
            self.assertEqual(data[1]["lengthModifier"], 2)
            self.assertEqual(data[1]["positionModifier"], changed[2])
            self.assertEqual(data[1]["rotationModifier"], changed[3])
            diagnostics = converted["diagnostics"]
            self.assertEqual([d["coordinateIndex"] for d in diagnostics], [0, 2])
            self.assertTrue(all(d["code"] == "repaired-null-coordinate" and d["severity"] == "warning"
                                for d in diagnostics))
            self.assertIn("#1", diagnostics[0]["message"])
            self.assertIn("#3", diagnostics[1]["message"])

    def test_null_and_empty_coordinate_arrays_match_constructor_rejection(self):
        for coordinates in [None, []]:
            with self.subTest(coordinates=coordinates), self.assertRaisesRegex(ValueError, "null/empty arrays"):
                abmx.convert(packed([["bone", coordinates, 1]]))
        self.assertEqual(abmx.convert(packed([]))["modifiers"], [])

    def test_truncated_messagepack_and_lz4_fail_instead_of_partial_import(self):
        records = [modifier(), modifier("second")]
        for payload in [packed(records), wrapped(packed(records))]:
            for length in range(len(payload)):
                with self.subTest(payload_bytes=len(payload), prefix_bytes=length), self.assertRaises(ValueError):
                    abmx.convert(payload[:length])
        with self.assertRaises(ValueError):
            abmx.convert(msgpack.packb(msgpack.ExtType(99, b"\xd2\0")))
        with self.assertRaisesRegex(ValueError, "LZ4"):
            abmx.convert(msgpack.packb(msgpack.ExtType(99, b"\xd2\0\0\0\x10\xff")))
        raw = packed(records)
        with self.assertRaisesRegex(ValueError, "byte count"):
            abmx.convert(wrapped(raw, size=len(raw) + 1))

    def test_payload_expansion_record_coordinate_and_name_limits(self):
        payload = packed([modifier()])
        with patch.object(abmx, "MAX_PAYLOAD", len(payload) - 1), self.assertRaisesRegex(ValueError, "payload"):
            abmx.convert(payload)
        for size in [0, -1, abmx.MAX_EXPANDED + 1]:
            value = msgpack.ExtType(99, b"\xd2" + struct.pack(">i", size) + b"\0")
            with self.subTest(expanded_size=size), self.assertRaisesRegex(ValueError, "expanded byte count"):
                abmx.convert(msgpack.packb(value))
        with patch.object(abmx, "MAX_RECORDS", 1), self.assertRaisesRegex(ValueError, "at most 1"):
            abmx.convert(packed([modifier(), modifier("second")]))
        with patch.object(abmx, "MAX_COORDINATES", 2), self.assertRaisesRegex(ValueError, "1 through 2"):
            abmx.convert(packed([modifier(coordinates=[abmx.IDENTITY] * 3)]))
        with patch.object(abmx, "MAX_BONE_NAME", 3), self.assertRaisesRegex(ValueError, "BoneName"):
            abmx.convert(packed([modifier("long")]))

    def test_scope_and_dynamic_limits_preserve_records_with_explicit_diagnostics(self):
        changed = [[1.25, 1, 1], 1, [0, 0, 0], [0, 0, 0]]
        records = [modifier("accessory_bone", [changed], 12), modifier("future_scope", [changed], 2),
                   modifier("cf_d_sk_probe", [changed], 1)]
        result = abmx.convert(packed(records))
        self.assertEqual([m["boneName"] for m in result["modifiers"]], [r[0] for r in records])
        self.assertEqual([m["boneLocation"] for m in result["modifiers"]], [12, 2, 1])
        self.assertEqual([d["code"] for d in result["diagnostics"]],
                         ["unsupported-bone-location", "unsupported-bone-location", "unsupported-dynamic-bone"])
        self.assertTrue(all(d["severity"] == "warning" and "rejects active" in d["message"] for d in result["diagnostics"]))

    def test_invalid_record_shapes_duplicate_identity_and_nonfinite_values(self):
        malformed = [
            [["bone"]],  # No CoordinateModifiers: the source constructor fails.
            [["bone", [[[1, 1, 1]]], 1]],  # A coordinate entry with one field.
            [["bone", [[]], 1]],  # A coordinate entry with no fields.
            [["bone", [abmx.IDENTITY], -1]],
            [modifier(), modifier()],
            [["bone", [[[1, 1], 1, [0, 0, 0], [0, 0, 0]]], 1]],
            [["bone", [[[1, 1, 1], float("nan"), [0, 0, 0], [0, 0, 0]]], 1]],
            [["bone", [[[1, 1, 1], float("inf"), [0, 0, 0], [0, 0, 0]]], 1]],
            [["bone", [[[1, 1, 1], 1e39, [0, 0, 0], [0, 0, 0]]], 1]],
            [["bone", [[[1, 1, 1], True, [0, 0, 0], [0, 0, 0]]], 1]],
        ]
        for index, records in enumerate(malformed):
            with self.subTest(index=index), self.assertRaises(ValueError):
                abmx.convert(msgpack.packb(records, use_bin_type=True))
        with self.assertRaisesRegex(ValueError, "extension"):
            abmx.convert(msgpack.packb(msgpack.ExtType(42, b"other-codec")))

    def test_older_and_longer_layouts_read_like_the_source_formatter(self):
        # #401: saves from before BoneLocation ([BoneName, CoordinateModifiers]) and
        # before Position/Rotation ([Scale, Length]) read with default values.
        older = abmx.convert(wrapped(packed([["cf_s_older", [[[1.25, 0.5, 1], 1.5]]]])))
        current = abmx.convert(packed([["cf_s_older", [[[1.25, 0.5, 1], 1.5, [0, 0, 0], [0, 0, 0]]], 0]]))
        self.assertEqual(older["modifiers"], current["modifiers"])
        self.assertEqual(older["modifiers"][0]["boneLocation"], 0)
        self.assertEqual(older["diagnostics"], [])
        three = abmx.convert(packed([["bone", [[[1, 1, 1], 1, [0.5, 0, 0]]], 1]]))
        self.assertEqual(three["modifiers"][0]["coordinateModifiers"][0]["positionModifier"], [0.5, 0.0, 0.0])
        self.assertEqual(three["modifiers"][0]["coordinateModifiers"][0]["rotationModifier"], [0.0, 0.0, 0.0])
        # Unknown trailing keys are skipped, with a diagnostic for each.
        longer = abmx.convert(packed([["bone", [[[1, 1, 1], 1, [0, 0, 0], [0, 0, 0], "extra"]], 1, None]]))
        self.assertEqual(longer["modifiers"], abmx.convert(packed([modifier("bone")]))["modifiers"])
        self.assertEqual([d["code"] for d in longer["diagnostics"]], ["skipped-unknown-fields", "skipped-unknown-fields"])
        self.assertEqual(longer["diagnostics"][0]["message"],
                         "ABMX record 'bone' has 4 fields; fields after BoneLocation are skipped, as the original's formatter skips unknown keys.")
        self.assertEqual(longer["diagnostics"][1]["message"],
                         "ABMX coordinate #1 for 'bone' has 5 fields; fields after Rotation are skipped, as the original's formatter skips unknown keys.")
        for entry, count in [([], 0), ([[1, 1, 1]], 1)]:
            with self.subTest(fields=count), self.assertRaisesRegex(ValueError, f"has {count} field\\(s\\). The original would read it with default values"):
                abmx.convert(packed([["bone", [entry], 1]]))
        with self.assertRaisesRegex(ValueError, "BoneName and CoordinateModifiers"):
            abmx.convert(packed([["bone"]]))


def legacy_token(name, x="1", y="1", z="1", length="1", extra=()):
    # "field0,name,field2,scaleX,scaleY,scaleZ,length"; fields 0 and 2 are never read.
    return ",".join(["0", name, "0", x, y, z] + ([length] if length is not None else []) + list(extra))


def legacy(tokens, separator="\r\n"):
    return abmx.convert_legacy(separator.join(tokens))


def bits(text):
    value = abmx.legacy_number(text)
    return None if value is abmx.LEGACY_FAILURE else struct.unpack("<I", struct.pack("<f", value))[0]


def names(document):
    return [modifier["boneName"] for modifier in document["modifiers"]]


def scale_x(document, index=0):
    return [values["scaleModifier"][0] for values in document["modifiers"][index]["coordinateModifiers"]]


def skipped(line, name, field):
    return f"ABMX legacy line {line} for '{name}' has an unparsable value in field {field}; it is skipped, as the original skips lines that fail to parse."


def dropped(line):
    return f"ABMX legacy line {line} has a bone name the original cannot read; the original drops all ABMX data for this card."


def non_finite(line, name, field):
    return f"ABMX legacy line {line} for '{name}' has a non-finite or out-of-range value in field {field}; ABMX modifier values must be finite float32 numbers."


class LegacyABMXTests(unittest.TestCase):
    """Card v1 legacy text (#403), mirroring SourceBoneModifierLegacyTests.swift."""

    def test_splits_on_mono_white_chars_only(self):
        a, b = legacy_token("aa", length="2", extra=["0"]), legacy_token("bb", "3", "3", "3", length="3")
        # The 17 separators checked in the original player (#403, #417): True
        # when the original split there.
        observed = [(0x0009, True), (0x000B, True), (0x001C, False), (0x001F, False), (0x0085, True), (0x00A0, True),
                    (0x1680, True), (0x180E, False), (0x2000, True), (0x200A, True), (0x200B, True), (0x2028, True),
                    (0x2029, True), (0x202F, True), (0x205F, True), (0x3000, True), (0xFEFF, True)]
        self.assertEqual(len(observed), 17)
        for scalar, splits in observed:
            with self.subTest(separator=hex(scalar)):
                document = abmx.convert_legacy(a + chr(scalar) + b)
                self.assertEqual(names(document), ["aa", "bb"] if splits else ["aa"])
                self.assertEqual([v["lengthModifier"] for v in document["modifiers"][0]["coordinateModifiers"]], [2.0])
                self.assertEqual(document["diagnostics"], [])
        # The rest of the set, and runs of separators at either end.
        for separator in [" ", "\n", "\r\n", "\r", "\t", "\x0c", "\u2005", "\ufeff\u200b", " \r\n\t  "]:
            with self.subTest(separator=[hex(ord(c)) for c in separator]):
                document = abmx.convert_legacy(separator + a + separator + separator + b + separator)
                self.assertEqual(names(document), ["aa", "bb"])
                self.assertEqual(document["diagnostics"], [])
        # str.split() splits on U+001C-U+001F; Mono's WhiteChars does not.
        for separator in ["\x1c", "\x1d", "\x1e", "\x1f"]:
            with self.subTest(separator=hex(ord(separator))):
                self.assertEqual(len((a + separator + b).split()), 2)
                self.assertEqual(names(abmx.convert_legacy(a + separator + b)), ["aa"])
        self.assertEqual(len(abmx.LEGACY_WHITESPACE), 27)

    def test_field_counts_keep_empty_fields(self):
        document = legacy(["0,five,0,2,2", legacy_token("six", "2", "3", "4", length=None),
                           legacy_token("seven", "2", "3", "4", length="5"),
                           legacy_token("eight", "2", "3", "4", length="5", extra=["notanumber"]),
                           ",empty,,2,3,4", legacy_token("trailing", "2", "3", "4", length="")], separator="\n")
        self.assertEqual(names(document), ["six", "seven", "eight", "empty"])
        self.assertEqual([m["coordinateModifiers"][0]["lengthModifier"] for m in document["modifiers"]], [1, 5, 5, 1])
        for modifier in document["modifiers"]:
            self.assertEqual(modifier["boneLocation"], 0)
            self.assertEqual(len(modifier["coordinateModifiers"]), 1)
            values = modifier["coordinateModifiers"][0]
            self.assertEqual((values["scaleModifier"], values["positionModifier"], values["rotationModifier"]),
                             ([2, 3, 4], [0, 0, 0], [0, 0, 0]))
        self.assertEqual([d["message"] for d in document["diagnostics"]], [skipped(6, "trailing", 6)])

    def test_trims_the_coordinate_suffix_in_utf16(self):
        tokens = [legacy_token(f"key__{i}", str(i + 1)) for i in range(7)]
        tokens += [legacy_token(n) for n in ["a__", "x_y", "ab", "_ab", "b___", "\U0001F600__1", "c\U0001F600"]]
        document = legacy(tokens)
        self.assertEqual(names(document), ["key", "a__", "x_y", "ab", "_ab", "b", "\U0001F600", "c\U0001F600"])
        self.assertEqual(scale_x(document), [1, 2, 3, 4, 5, 6, 7])

    def test_orders_groups_by_first_use_and_entries_ordinally(self):
        zz = [legacy_token(f"zz__{i}", str(i)) for i in reversed(range(7))]
        bb = [legacy_token("bb__0", "10"), legacy_token("bb__2", "2"), legacy_token("bb__0", "11"), legacy_token("bb__1", "1"),
              legacy_token("bb__3", "3"), legacy_token("bb__4", "4"), legacy_token("bb__5", "5")]
        cc = [legacy_token(n, str(i)) for i, n in enumerate(["cc__a", "cc___", "cc__A", "cc__1", "cc__0", "cc__2", "cc__3"])]
        document = legacy([zz[0], bb[0], cc[0]] + zz[1:] + bb[1:] + cc[1:])
        self.assertEqual(names(document), ["zz", "bb", "cc"])
        self.assertEqual(scale_x(document, 0), [0, 1, 2, 3, 4, 5, 6])
        self.assertEqual(scale_x(document, 1), [10, 11, 1, 2, 3, 4, 5])
        self.assertEqual(scale_x(document, 2), [4, 3, 5, 6, 2, 1, 0])
        self.assertEqual(document["diagnostics"], [])

    def test_keeps_the_last_seven_or_the_last_one(self):
        for count, kept in [(1, 1), (2, 1), (6, 1), (7, 7), (8, 7), (9, 7)]:
            with self.subTest(count=count):
                document = legacy([legacy_token(f"b__{i}", str(i)) for i in range(count)])
                self.assertEqual(scale_x(document), list(range(count - kept, count)))
                expected = [] if count == kept else [f"ABMX legacy bone 'b' has {count} parsed lines; the original keeps the last {kept}."]
                self.assertEqual([d["message"] for d in document["diagnostics"]], expected)

    def test_skips_unparsable_lines(self):
        for text in ["abc", "1e", "e1", "0x10", "inf", "infinity", "nan", "+Infinity", "", ".", "-", "+-1", "1.2.3", "1f",
                     "1d", "１", "1_0", "Infinity1", "١"]:
            with self.subTest(text=text):
                self.assertIs(abmx.legacy_number(text), abmx.LEGACY_FAILURE)
        document = legacy([legacy_token("aa__0", "2"), legacy_token("aa__1", "1", "abc"),
                           legacy_token("bb__0", length="1e"), legacy_token("bb__1", "0x10", "Infinity")])
        self.assertEqual(names(document), ["aa"])
        self.assertEqual(scale_x(document), [2])
        self.assertEqual([d["message"] for d in document["diagnostics"]],
                         [skipped(2, "aa", 4), skipped(3, "bb", 6), skipped(4, "bb", 3)])
        self.assertEqual({d["code"] for d in document["diagnostics"]}, {"skipped-legacy-line"})

    def test_numbers_parse_as_double_then_float32(self):
        table = [("1", 0x3F800000), ("1.", 0x3F800000), (".5", 0x3F000000), ("+1", 0x3F800000), ("-0", 0x80000000),
                 ("0", 0x00000000), ("-1.25", 0xBFA00000), ("1e-3", 0x3A83126F), ("1E+2", 0x42C80000), ("1.1", 0x3F8CCCCD),
                 ("007", 0x40E00000), ("1e-50", 0x00000000), ("1e-45", 0x00000001),
                 ("3.4028234663852886e38", 0x7F7FFFFF), ("1.0000000596046448", 0x3F800000),
                 ("Infinity", 0x7F800000), ("-Infinity", 0xFF800000),
                 # Beyond float32 range as a double, either sign, even when it would round to the largest float.
                 ("3.4028235e38", 0x7F800000), ("1e39", 0x7F800000), ("-1e39", 0xFF800000),
                 ("1e400", 0x7F800000), ("-1e400", 0xFF800000)]
        for text, expected in table:
            with self.subTest(text=text):
                self.assertEqual(bits(text), expected)
        self.assertTrue(math.isnan(abmx.legacy_number("NaN")))

    def test_refuses_non_finite_kept_values(self):
        for value, field in [("NaN", 3), ("Infinity", 4), ("-Infinity", 5), ("1e39", 6), ("-1e39", 3), ("3.4028235e38", 4)]:
            fields = [value if index == field else "1" for index in range(3, 7)]
            with self.subTest(value=value), self.assertRaises(ValueError) as caught:
                abmx.convert_legacy("\n".join([legacy_token("aa"), legacy_token("bb", *fields[:3], length=fields[3])]))
            self.assertEqual(str(caught.exception), non_finite(2, "bb", field))
        document = legacy([legacy_token("aa", "Infinity", "abc"), legacy_token("bb__0", "NaN"), legacy_token("bb__1", "2")])
        self.assertEqual(names(document), ["bb"])
        self.assertEqual(scale_x(document), [2])

    def test_name_index_exception_drops_all_modifiers(self):
        for name in ["", "_", "a", "_a"]:
            with self.subTest(name=name):
                document = legacy([legacy_token("valid"), legacy_token(name, "Infinity"), legacy_token("also")])
                self.assertEqual(document["modifiers"], [])
                self.assertEqual([d["code"] for d in document["diagnostics"]], ["legacy-data-dropped"])
                self.assertEqual([d["message"] for d in document["diagnostics"]], [dropped(2)])
        empty = legacy([legacy_token("valid"), legacy_token("xx", "abc"), legacy_token("___")])
        self.assertEqual((empty["modifiers"], [d["message"] for d in empty["diagnostics"]]), ([], [dropped(3)]))
        self.assertEqual(names(legacy([legacy_token("valid"), legacy_token("___", "abc")])), ["valid"])
        self.assertEqual(names(legacy([legacy_token("\U0001F600"), legacy_token("_\U0001F600")])), ["\U0001F600", "_\U0001F600"])

    def test_limits_dynamic_bones_and_provenance(self):
        text = "\r\n".join([legacy_token("cf_d_sk_00__0", "1.5"), legacy_token("cf_J_Hips", "0.5", "1", "1", length="2")])
        document = abmx.convert_legacy(text)
        self.assertEqual((document["source"]["dataKind"], document["source"]["dataVersion"]), ("card", 1))
        self.assertEqual(document["source"]["payloadSHA256"], abmx.sha(text.encode("utf-8")))
        self.assertEqual(names(document), ["cf_d_sk_00", "cf_J_Hips"])
        self.assertEqual([d["code"] for d in document["diagnostics"]], ["unsupported-dynamic-bone"])
        size = "ABMX card v1 boneData must contain 1 byte through 16 MiB of text."
        name = "ABMX BoneName must contain 1 through 1024 source characters and no NUL."
        for text, message in [("", size), (" " * (16 * 1024 * 1024 + 1), size), (legacy_token("n" * 1025), name),
                              (legacy_token("bo\0ne"), name),
                              ("\n".join(legacy_token(f"g{i}") for i in range(10001)), "ABMX boneData requires at most 10000 BoneModifier records.")]:
            with self.subTest(message=message, length=len(text)), self.assertRaises(ValueError) as caught:
                abmx.convert_legacy(text)
            self.assertEqual(str(caught.exception), message)
        blank = abmx.convert_legacy(" \r\n ")
        self.assertEqual((blank["modifiers"], blank["diagnostics"]), ([], []))
        not_text = abmx.legacy_not_text()
        self.assertEqual((not_text["modifiers"], not_text["source"]["dataVersion"]), ([], 1))
        self.assertEqual([d["message"] for d in not_text["diagnostics"]],
                         ["ABMX card v1 boneData is not text; the original's legacy reader returns no modifiers, so the character loads without ABMX."])

    def test_cli_reads_card_v1_text(self):
        text = "\r\n".join([legacy_token("cf_J_FaceRoot__0", "1.5"), legacy_token("cf_d_sk_00", length="2")])
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "boneData.txt"
            source.write_bytes(text.encode("utf-8"))
            output = abmx.REPO / ".local/unused.json"
            argv = ["abmx_contract.py", "--bone-data", str(source), "--data-version", "1", "--output", str(output)]
            with patch.object(sys, "argv", argv), patch.object(abmx, "write_json") as write, patch("builtins.print"):
                abmx.main()
            document = write.call_args.args[1]
            self.assertEqual(document, abmx.convert_legacy(text))
            self.assertEqual(names(document), ["cf_J_FaceRoot", "cf_d_sk_00"])
            source.write_bytes(b"\xff\xfe")
            with patch.object(sys, "argv", argv), patch.object(abmx, "write_json"), \
                    self.assertRaisesRegex(ValueError, "must be UTF-8 text"):
                abmx.main()
        # Binary card v1 data still goes through convert, which refuses it.
        with self.assertRaisesRegex(ValueError, "card v1 is legacy text"):
            abmx.convert(packed([modifier()]), "card", 1)


if __name__ == "__main__":
    unittest.main()
