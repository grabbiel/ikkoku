#!/usr/bin/env python3
"""Audit actual Maker edited-card exports without decoding image pixels.

Input is an explicit cases array describing original and exported card paths,
44 body values, 52 face values, coordinate index and named RGBA edits. This uses
the independent original framing/token parsers, not the native writer. It never
loads plug-ins, launches the app or modifies a card.
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path
import struct

from card_contract import Limits, mapping, parse_card, png_end, sha, unpack
from card_roundtrip import compare_tokens, records

ROOT = Path(__file__).resolve().parents[3]
LIMITS = Limits()


def float32(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
        raise ValueError("Expected a finite float32 number")
    try:
        return struct.pack("<f", value)
    except (OverflowError, struct.error) as error:
        raise ValueError("Number exceeds float32") from error


def bounded_read(path: Path, maximum=LIMITS.card_bytes):
    if not path.is_file() or path.stat().st_size > maximum:
        raise ValueError(f"Not a bounded regular file: {path}")
    with path.open("rb") as file:
        data = file.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("File grew beyond its bound")
    return data


def resolve(path: str) -> Path:
    if not isinstance(path, str) or not path:
        raise ValueError("Explicit nonempty file path required")
    result = Path(path)
    return (result if result.is_absolute() else ROOT / result).resolve()


def png_dimensions(data: bytes, expected: tuple[int, int]):
    if not data or png_end(data, LIMITS) != len(data):
        raise ValueError("Expected exactly one CRC-valid PNG")
    actual = struct.unpack(">II", data[16:24])
    if actual != expected:
        raise ValueError(f"Expected PNG dimensions {expected}, got {actual}")
    return list(actual)


def path_node(data: bytes, path: tuple):
    node = unpack(data, LIMITS)
    for field in path:
        if isinstance(field, int):
            if node.kind != "array" or not 0 <= field < len(node.value):
                raise ValueError(f"Invalid array field {path}")
            node = node.value[field]
        else:
            fields = mapping(node)
            if field not in fields:
                raise ValueError(f"Missing edited field {path}")
            node = fields[field]
    return node


def color_target(name: str, coordinate: int):
    fields = name.split(".")
    if len(fields) < 2 or fields[0] not in ("face", "body", "hair", "clothes", "accessory", "makeup"):
        raise ValueError(f"Unknown color record: {name}")
    record = fields[0] + (f":{coordinate}" if fields[0] in ("clothes", "accessory", "makeup") else "")
    if not any("color" in field.lower() for field in fields[1:]):
        raise ValueError("Color target must name a color field")
    path = tuple(int(field) if field.isdecimal() else field for field in fields[1:])
    return record, path


def numeric_edits(before: bytes, path: tuple, values: list, count: int):
    node = path_node(before, path)
    if not isinstance(values, list) or len(values) != count or node.kind != "array" or len(node.value) != count:
        raise ValueError(f"Expected {count} numeric members at {path}")
    result = {}
    for index, (original, value) in enumerate(zip(node.value, values)):
        if original.kind not in ("float", "int"):
            raise ValueError("Original edited field is not numeric")
        if float32(original.value) != float32(value):
            result[path + (index,)] = value
    return result


def payload_gaps(card):
    ranges = sorted((block["pos"], block["pos"] + block["size"]) for block in card.blocks if block["size"])
    base, size = card.report["offsets"]["payloadStart"], card.report["payloadBytes"]
    cursor, result = 0, []
    for start, end in ranges:
        if start < cursor:
            raise ValueError("Overlapping card blocks")
        result.append(card.raw[base + cursor:base + start])
        cursor = end
    result.append(card.raw[base + cursor:base + size])
    return result


def validate_case(case: dict):
    source_path, edited_path = resolve(case["source"]), resolve(case["edited"])
    if source_path == edited_path:
        raise ValueError("Export must be a separate file")
    source, edited = parse_card(bounded_read(source_path)), parse_card(bounded_read(edited_path))
    coordinate = case.get("coordinate", 0)
    if type(coordinate) is not int or not 0 <= coordinate <= 6:
        raise ValueError("Outfit index must be in 0...6")
    source_blocks = {b["name"]: b for b in source.blocks}
    edited_blocks = {b["name"]: b for b in edited.blocks}
    if len(source_blocks) != len(source.blocks) or len(edited_blocks) != len(edited.blocks):
        raise ValueError("Ambiguous duplicate block names")
    if list(source_blocks) != list(edited_blocks):
        raise ValueError("Original block header order changed")
    before, after = records(source), records(edited)
    if set(before) != set(after):
        raise ValueError("Record or coordinate count changed")
    allowed = {record: {} for record in before}
    changes = {}
    for record, key, name, count in [("face", "shapeValueFace", "faceValues", 52), ("body", "shapeValueBody", "bodyValues", 44)]:
        expected = case.get(name, source.report["custom"][key])
        allowed[record].update(numeric_edits(before[record], (key,), expected, count))
        actual = edited.report["custom"][key]
        if len(actual) != count or any(float32(a) != float32(b) for a, b in zip(actual, expected)):
            raise ValueError(f"Wrong exported {name}")
        changes[name] = len(allowed[record])
    color_edits = case.get("colorEdits", {})
    if not isinstance(color_edits, dict) or len(color_edits) > 4096:
        raise ValueError("Color edits must be a bounded field map")
    for name, expected in color_edits.items():
        record, path = color_target(name, coordinate)
        if record not in before:
            raise ValueError(f"Unavailable coordinate/record: {record}")
        changed = numeric_edits(before[record], path, expected, 4)
        if set(changed) & set(allowed[record]):
            raise ValueError("Overlapping edited fields")
        allowed[record].update(changed)
        actual = path_node(after[record], path)
        if actual.kind != "array" or len(actual.value) != 4 or any(float32(n.value) != float32(v) for n, v in zip(actual.value, expected)):
            raise ValueError(f"Wrong exported color {name}")
    leaves = 0
    changed_records = []
    for record, data in before.items():
        if record.startswith("enabled:"):
            if data != after[record]:
                raise ValueError("Unedited enableMakeup changed")
        else:
            leaves += compare_tokens(data, after[record], allowed[record])
        if data != after[record]:
            changed_records.append(record)
    # Unedited coordinate binary values must retain their original bin header,
    # not just the decoded clothes/accessory/makeup record contents.
    a_coordinates = unpack(source_blocks["Coordinate"]["raw"], LIMITS)
    b_coordinates = unpack(edited_blocks["Coordinate"]["raw"], LIMITS)
    if a_coordinates.kind != "array" or b_coordinates.kind != "array" or len(a_coordinates.value) != len(b_coordinates.value):
        raise ValueError("Coordinate list topology changed")
    a_prefix = a_coordinates.value[0].start if a_coordinates.value else a_coordinates.end
    b_prefix = b_coordinates.value[0].start if b_coordinates.value else b_coordinates.end
    if source_blocks["Coordinate"]["raw"][:a_prefix] != edited_blocks["Coordinate"]["raw"][:b_prefix]:
        raise ValueError("Coordinate array header changed")
    for index, (a, b) in enumerate(zip(a_coordinates.value, b_coordinates.value)):
        if not any(f"{kind}:{index}" in changed_records for kind in ("clothes", "accessory", "makeup")):
            if source_blocks["Coordinate"]["raw"][a.start:a.end] != edited_blocks["Coordinate"]["raw"][b.start:b.end]:
                raise ValueError(f"Unedited coordinate {index} binary token changed")
    for name, block in source_blocks.items():
        if name not in ("Custom", "Coordinate") and block["raw"] != edited_blocks[name]["raw"]:
            raise ValueError(f"Opaque block {name} changed")
        if block["version"] != edited_blocks[name]["version"]:
            raise ValueError("Block version changed")
    if payload_gaps(source) != payload_gaps(edited):
        raise ValueError("Payload gaps changed")
    original_order = [b["name"] for b in sorted(source.blocks, key=lambda b: b["pos"]) if b["size"]]
    edited_order = [b["name"] for b in sorted(edited.blocks, key=lambda b: b["pos"]) if b["size"]]
    if original_order != edited_order:
        raise ValueError("Physical block order changed")
    a, b = source.report["offsets"], edited.report["offsets"]
    if source.raw[a["payloadEnd"]:] != edited.raw[b["payloadEnd"]:]:
        raise ValueError("Extended Save/unknown trailer changed")
    if source.raw[a["pngEnd"]:a["facePngLength"]] != edited.raw[b["pngEnd"]:b["facePngLength"]]:
        raise ValueError("Original framing changed")
    thumbnail = edited.raw[:b["pngEnd"]]
    if thumbnail == source.raw[:a["pngEnd"]]:
        raise ValueError("Export did not replace its original thumbnail")
    face = edited.raw[b["facePngStart"]:b["facePngStart"] + edited.report["facePngBytes"]]
    main_dimensions = png_dimensions(thumbnail, (504, 704))
    face_dimensions = png_dimensions(face, tuple(case.get("faceDimensions", [256, 256])))
    if case.get("matchingThumbnails", False) and face != thumbnail:
        raise ValueError("Expected the same fresh native PNG in both thumbnail fields")
    header_changes = {}
    for index, block in enumerate(edited.blocks):
        for field in ("pos", "size"):
            if block[field] != source.blocks[index][field]:
                header_changes[("lstInfo", index, field)] = block[field]
    compare_tokens(source.raw[a["headerStart"]:a["headerStart"] + source.report["headerBytes"]],
                   edited.raw[b["headerStart"]:b["headerStart"] + edited.report["headerBytes"]], header_changes)
    if source.report["parameter"] != edited.report["parameter"]:
        raise ValueError("Character identity changed")
    if source.report["extendedDataSource"] != edited.report["extendedDataSource"] or [(p["id"], p["raw"]) for p in source.plugins] != [(p["id"], p["raw"]) for p in edited.plugins]:
        raise ValueError("Selected plug-in identity/data changed")
    return {"name": case.get("name", edited_path.stem), "success": True, "coordinate": coordinate,
            "sourceSHA256": sha(source.raw), "editedSHA256": sha(edited.raw), "characterSex": edited.report["parameter"]["sex"],
            "sourceBytes": len(source.raw), "editedBytes": len(edited.raw), "editedNumericLeaves": leaves,
            "shapeChanges": changes, "editedColorFields": sorted(color_edits), "changedRecords": changed_records,
            "unchangedOpaqueBlocks": [name for name in source_blocks if name not in ("Custom", "Coordinate")],
            "coordinateCount": len(a_coordinates.value), "relocatedHeaderFields": len(header_changes),
            "thumbnailDimensions": main_dimensions, "faceThumbnailDimensions": face_dimensions,
            "freshThumbnailSHA256": sha(thumbnail), "unknownTokensAndPluginDataPreserved": True}


def validate_inputs(path: Path):
    raw = bounded_read(path, 1024 * 1024)
    specification = json.loads(raw)
    cases = specification.get("cases") if isinstance(specification, dict) else specification
    if not isinstance(cases, list) or not 1 <= len(cases) <= 64:
        raise ValueError("Expected 1...64 explicit export cases")
    return {"schemaVersion": 1, "kind": "ikkoku-maker-edited-card-audit", "inputsSHA256": sha(raw),
            "cases": [validate_case(case) for case in cases], "success": True,
            "scope": "Byte framing, edited values, unedited-token preservation and PNG integrity/dimensions; image pixels are not decoded"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, default=ROOT / ".local/reverse/maker-completion/end-to-end-inputs.json")
    parser.add_argument("--output", type=Path, default=ROOT / ".local/reverse/maker-completion/export-verification.json")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / ".local").resolve()):
        raise ValueError("Evidence output must remain under ignored .local")
    result = validate_inputs(args.inputs.resolve())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
