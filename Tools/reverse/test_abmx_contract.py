#!/usr/bin/env python3
"""Synthetic wire-format/repair checks; no original cards or DLLs are required."""
import copy
import struct
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
            [["bone", [abmx.IDENTITY]]],  # Missing current BoneLocation key.
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


if __name__ == "__main__":
    unittest.main()
