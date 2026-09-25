"""Independent verifier tests, using synthetic original-format cards only."""
from pathlib import Path
import json
import struct
import sys
import tempfile
import unittest
import zlib

import msgpack

sys.path.insert(0, str(Path(__file__).parent / "analysis"))
import maker_roundtrip as audit
from card_contract import MAGIC, PNG, blank_png, dotnet_string


def png(width, height, value=0):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = (b"\0" + bytes([value, value, value, 255]) * width) * height
    return PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def pack(value):
    return msgpack.packb(value, use_bin_type=True)


def length(data):
    return struct.pack("<i", len(data)) + data


def fixture(*, edited=False, unknown=b"opaque", wrong_coordinate=False):
    face = {"version": "0.0.2", "headId": 0, "shapeValueFace": [0.5] * 52, "unknown": msgpack.ExtType(4, b"keep")}
    body = {"version": "0.0.2", "shapeValueBody": [0.5] * 44, "skinMainColor": [0.25, 0.5, 0.75, 1.0]}
    if edited:
        face["shapeValueFace"][10] = 0.625
        body["shapeValueBody"][32] = 0.25
        body["skinMainColor"] = [0.125, 0.25, 0.5, 1.0]
    hair = {"version": "0.0.4", "parts": []}
    coordinates = []
    for index in range(2):
        rgba = [0.25, 0.5, 0.75, 1.0]
        if edited and (index == 1 or wrong_coordinate):
            rgba = [0.5, 0.25, 0.125, 1.0]
        clothes = {"version": "0.0.1", "parts": [{"id": 38, "colorInfo": [{"baseColor": rgba}]}]}
        coordinates.append(length(pack(clothes)) + length(pack({"version": "0.0.2"})) + b"\x01" + length(pack({"version": "0.0.0"})))
    blocks = [
        ("Custom", "0.0.0", length(pack(face)) + length(pack(body)) + length(pack(hair))),
        ("Coordinate", "0.0.0", pack(coordinates)),
        ("Parameter", "0.0.5", pack({"version": "0.0.5", "sex": 0})),
        ("Opaque", "5", unknown),
        ("KKEx", "3", pack({"example.plugin": [4, {"savedIdentity": b"abc"}]}))
    ]
    pos, infos = 0, []
    for name, version, data in blocks:
        infos.append({"name": name, "version": version, "pos": pos, "size": len(data)})
        pos += len(data)
    header = pack({"lstInfo": infos, "extra": msgpack.ExtType(8, b"future")})
    payload = b"".join(b[2] for b in blocks)
    thumbnail = png(504, 704) if edited else blank_png()
    face_png = png(256, 256, 128) if edited else b""
    return thumbnail + struct.pack("<i", 100) + dotnet_string(MAGIC) + dotnet_string("0.0.0") + length(face_png) + length(header) + struct.pack("<q", len(payload)) + payload + b"unchanged trailer"


class MakerRoundtripTests(unittest.TestCase):
    def case(self, directory):
        source, edited = directory / "original.png", directory / "edited.png"
        source.write_bytes(fixture())
        edited.write_bytes(fixture(edited=True))
        face, body = [0.5] * 52, [0.5] * 44
        face[10], body[32] = 0.625, 0.25
        return {"name": "synthetic-maker", "source": str(source), "edited": str(edited), "coordinate": 1,
                "faceValues": face, "bodyValues": body, "colorEdits": {
                    "body.skinMainColor": [0.125, 0.25, 0.5, 1.0],
                    "clothes.parts.0.colorInfo.0.baseColor": [0.5, 0.25, 0.125, 1.0]}}

    def test_actual_export_contract_including_distinct_fresh_thumbnails(self):
        with tempfile.TemporaryDirectory() as temp:
            case = self.case(Path(temp))
            result = audit.validate_case(case)
            self.assertTrue(result["success"])
            self.assertEqual(result["thumbnailDimensions"], [504, 704])
            self.assertEqual(result["faceThumbnailDimensions"], [256, 256])
            self.assertEqual(result["shapeChanges"], {"faceValues": 1, "bodyValues": 1})
            self.assertEqual(result["changedRecords"], ["face", "body", "clothes:1"])
            self.assertEqual(result["editedNumericLeaves"], 8)
            self.assertIn("KKEx", result["unchangedOpaqueBlocks"])

    def test_wrong_shapes_and_opaque_block_edits_are_detected(self):
        with tempfile.TemporaryDirectory() as temp:
            case = self.case(Path(temp))
            case["bodyValues"][32] = 0.75
            with self.assertRaisesRegex(ValueError, "Wrong exported bodyValues"):
                audit.validate_case(case)
            case = self.case(Path(temp))
            Path(case["edited"]).write_bytes(fixture(edited=True, unknown=b"changed"))
            with self.assertRaisesRegex(ValueError, "Opaque block"):
                audit.validate_case(case)

    def test_edits_to_unselected_coordinate_are_detected(self):
        with tempfile.TemporaryDirectory() as temp:
            case = self.case(Path(temp))
            Path(case["edited"]).write_bytes(fixture(edited=True, wrong_coordinate=True))
            with self.assertRaisesRegex(ValueError, "Unedited token changed"):
                audit.validate_case(case)

    def test_crc_and_dimension_checks_do_not_decode_pixels(self):
        raw = png(504, 704)
        self.assertEqual(audit.png_dimensions(raw, (504, 704)), [504, 704])
        with self.assertRaisesRegex(ValueError, "dimensions"):
            audit.png_dimensions(raw, (256, 256))
        corrupt = bytearray(raw)
        corrupt[29] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"):
            audit.png_dimensions(bytes(corrupt), (504, 704))
        with self.assertRaises(ValueError):
            audit.png_dimensions(raw + b"trailer", (504, 704))

    def test_bounded_input_and_explicit_export_copy_requirements(self):
        with tempfile.TemporaryDirectory() as temp:
            case = self.case(Path(temp))
            case["edited"] = case["source"]
            with self.assertRaisesRegex(ValueError, "separate file"):
                audit.validate_case(case)
            spec = Path(temp) / "spec.json"
            spec.write_text(json.dumps({"cases": []}))
            with self.assertRaises(ValueError):
                audit.validate_inputs(spec)
            spec.write_text(json.dumps({"cases": [self.case(Path(temp))]}))
            self.assertTrue(audit.validate_inputs(spec)["success"])

    def test_paths_and_float32_values_are_validated(self):
        self.assertEqual(audit.color_target("clothes.parts.8.colorInfo.2.baseColor", 4),
                         ("clothes:4", ("parts", 8, "colorInfo", 2, "baseColor")))
        for field in ("Parameter.sex", "body.shapeValueBody", "skinMainColor"):
            with self.assertRaises(ValueError):
                audit.color_target(field, 0)
        for value in (True, float("nan"), float("inf"), 1e100, "0.5"):
            with self.assertRaises(ValueError):
                audit.float32(value)


if __name__ == "__main__":
    unittest.main()
