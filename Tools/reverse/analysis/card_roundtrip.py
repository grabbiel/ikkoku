#!/usr/bin/env python3
"""Independent byte-span audit of native edited original-format cards.

Consumes explicit synthetic source/edited files emitted by the Swift tests. No
source images are decoded and no file is overwritten. Unknown tokens must remain
byte-identical, including within otherwise edited appearance records.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import struct

from card_contract import Cursor, Limits, mapping, parse_card, png_end, sha, unpack

LIMITS = Limits()
ROOT = Path(__file__).resolve().parents[3]


def records(card):
    blocks = {block["name"]: block for block in card.blocks}
    custom = Cursor(blocks["Custom"]["raw"])
    result = {name: custom.take(custom.number("<i")) for name in ("face", "body", "hair")}
    if custom.offset != len(custom.data):
        raise ValueError("Unexpected custom trailer")
    coordinate_bytes = blocks["Coordinate"]["raw"]
    coordinates = unpack(coordinate_bytes, LIMITS)
    if coordinates.kind != "array":
        raise ValueError("Expected coordinate list")
    for index, node in enumerate(coordinates.value):
        if node.kind != "bin":
            raise ValueError("Expected coordinate binary entry")
        reader = Cursor(node.value)
        result[f"clothes:{index}"] = reader.take(reader.number("<i"))
        result[f"accessory:{index}"] = reader.take(reader.number("<i"))
        result[f"enabled:{index}"] = reader.take(1)
        result[f"makeup:{index}"] = reader.take(reader.number("<i"))
        if reader.offset != len(reader.data):
            raise ValueError("Unexpected coordinate trailer")
    return result


def compare_tokens(before: bytes, after: bytes, allowed: dict[tuple, float]):
    """Assert exact token bytes except the explicitly selected float32 leaves."""
    visited = set()
    original, edited = unpack(before, LIMITS), unpack(after, LIMITS)

    def visit(a, b, path=()):
        # Unknown containers may legally use integer/duplicate keys. If no edit
        # descends into them, compare their complete wire bytes without imposing
        # the typed string-map schema of the surrounding character record.
        if not any(target[:len(path)] == path for target in allowed):
            if before[a.start:a.end] != after[b.start:b.end]:
                raise ValueError(f"Unedited token changed at {path}")
            return
        if path in allowed:
            visited.add(path)
            if b.kind not in ("float", "int") or struct.pack("<f", b.value) != struct.pack("<f", allowed[path]):
                raise ValueError(f"Incorrect edited value at {path}")
            return
        if a.kind != b.kind:
            raise ValueError(f"Unexpected changed token kind at {path}")
        if a.kind == "map":
            # Count/order/key wire encodings must remain unchanged.
            if len(a.value) != len(b.value):
                raise ValueError(f"Changed map fields at {path}")
            old_fields, new_fields = mapping(a), mapping(b)
            if list(old_fields) != list(new_fields):
                raise ValueError(f"Changed map order at {path}")
            a_header_end = a.value[0][0].start if a.value else a.end
            b_header_end = b.value[0][0].start if b.value else b.end
            if before[a.start:a_header_end] != after[b.start:b_header_end]:
                raise ValueError(f"Changed map header encoding at {path}")
            for (ak, av), (bk, bv) in zip(a.value, b.value):
                if before[ak.start:ak.end] != after[bk.start:bk.end]:
                    raise ValueError(f"Changed key encoding at {path}")
                visit(av, bv, path + (ak.value,))
        elif a.kind == "array":
            if len(a.value) != len(b.value):
                raise ValueError(f"Changed array count at {path}")
            ah = a.value[0].start if a.value else a.end
            bh = b.value[0].start if b.value else b.end
            if before[a.start:ah] != after[b.start:bh]:
                raise ValueError(f"Changed array header at {path}")
            for i, (av, bv) in enumerate(zip(a.value, b.value)):
                visit(av, bv, path + (i,))
        elif before[a.start:a.end] != after[b.start:b.end]:
            raise ValueError(f"Unedited token changed at {path}")
    visit(original, edited)
    if visited != set(allowed):
        raise ValueError("An edited field is absent")
    return len(visited)


def validate(directory: Path) -> dict:
    source_path, edited_path = directory / "source.png", directory / "edited.png"
    source, edited = parse_card(source_path.read_bytes()), parse_card(edited_path.read_bytes())
    edits = json.loads((directory / "edits.json").read_text())
    for key, expected in (("shapeValueFace", edits["faceValues"]), ("shapeValueBody", edits["bodyValues"])):
        if source.report["custom"][key] == edited.report["custom"][key]:
            raise ValueError(f"Expected nontrivial {key} edit")
        actual = edited.report["custom"][key]
        if len(actual) != len(expected) or any(struct.pack("<f", a) != struct.pack("<f", b) for a, b in zip(actual, expected)):
            raise ValueError(f"Shape parity failed for {key}")
    source_blocks = {block["name"]: block for block in source.blocks}
    edited_blocks = {block["name"]: block for block in edited.blocks}
    if list(source_blocks) != list(edited_blocks):
        raise ValueError("Block header order changed")
    for name, block in source_blocks.items():
        if name not in ("Custom", "Coordinate") and block["raw"] != edited_blocks[name]["raw"]:
            raise ValueError(f"Opaque block {name} changed")
        if block["version"] != edited_blocks[name]["version"]:
            raise ValueError("Block version changed")
    s_offsets, e_offsets = source.report["offsets"], edited.report["offsets"]
    if source.raw[s_offsets["payloadEnd"]:] != edited.raw[e_offsets["payloadEnd"]:]:
        raise ValueError("Legacy/trailer bytes changed")
    if source.raw[:s_offsets["pngEnd"]] != edited.raw[:e_offsets["pngEnd"]]:
        raise ValueError("Unedited thumbnail changed")
    if source.raw[s_offsets["pngEnd"]:s_offsets["facePngLength"]] != edited.raw[e_offsets["pngEnd"]:e_offsets["facePngLength"]]:
        raise ValueError("Unedited framing changed")
    face = edited.raw[e_offsets["facePngStart"]:e_offsets["facePngStart"] + edited.report["facePngBytes"]]
    if png_end(face, LIMITS) != len(face):
        raise ValueError("Replacement face PNG is invalid")

    header_changes = {}
    for index, block in enumerate(edited.blocks):
        for field in ("pos", "size"):
            if block[field] != source.blocks[index][field]:
                header_changes[("lstInfo", index, field)] = block[field]
    header_before = source.raw[s_offsets["headerStart"]:s_offsets["headerStart"] + source.report["headerBytes"]]
    header_after = edited.raw[e_offsets["headerStart"]:e_offsets["headerStart"] + edited.report["headerBytes"]]
    compare_tokens(header_before, header_after, header_changes)
    record_before, record_after = records(source), records(edited)
    allow = {name: {} for name in record_before}
    for record, array_name, expected in (("face", "shapeValueFace", edits["faceValues"]), ("body", "shapeValueBody", edits["bodyValues"])):
        original = source.report["custom"][array_name]
        for index, (a, b) in enumerate(zip(original, expected)):
            if struct.pack("<f", a) != struct.pack("<f", b):
                allow[record][(array_name, index)] = b
    colors = {
        "face": ("eyebrowColor",), "body": ("skinMainColor",),
        "hair": ("parts", 0, "baseColor"),
        "clothes:1": ("parts", 0, "colorInfo", 0, "baseColor"),
        "accessory:1": ("parts", 0, "color", 0), "makeup:1": ("lipColor",)
    }
    for record, path in colors.items():
        for index, value in enumerate(edits["rgba"]):
            allow[record][path + (index,)] = value
    checked = 0
    for name, before in record_before.items():
        if name.startswith("enabled:"):
            if before != record_after[name]:
                raise ValueError("Coordinate enableMakeup changed")
        else:
            checked += compare_tokens(before, record_after[name], allow[name])
    if source.report["parameter"] != edited.report["parameter"]:
        raise ValueError("Character identity changed")
    if source.report["extendedDataSource"] != edited.report["extendedDataSource"]:
        raise ValueError("Extended Save precedence changed")
    if [(p["id"], p["raw"]) for p in source.plugins] != [(p["id"], p["raw"]) for p in edited.plugins]:
        raise ValueError("Selected plug-in data changed")
    return {"schemaVersion": 1, "sourceSHA256": sha(source.raw), "editedSHA256": sha(edited.raw),
            "sourceBytes": len(source.raw), "editedBytes": len(edited.raw), "editedNumericLeaves": checked,
            "relocatedHeaderFields": len(header_changes), "characterSex": edited.report["parameter"]["sex"],
            "unchangedBlocks": [n for n in source_blocks if n not in ("Custom", "Coordinate")],
            "unknownTokensAndTrailerPreserved": True, "originalLoaderFramingValid": True,
            "extendedDataSource": edited.report["extendedDataSource"], "success": True}



def evidence_contract() -> dict:
    base = json.loads((ROOT / ".local/reverse/cards/contract.json").read_text())
    evidence = list(base["evidence"])
    for item in evidence:
        if sha((ROOT / item["path"]).read_bytes()) != item["sha256"]:
            raise ValueError(f"Changed original card evidence: {item['path']}")
    recovered = ROOT / ".local/reverse/managed-recovery"
    targets = {
        "0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5":
            ["ChaFileCoordinate.cs", "ChaFileFace.cs", "ChaFileBody.cs", "ChaFileHair.cs", "ChaFileClothes.cs", "ChaFileAccessory.cs", "ChaFileMakeup.cs"],
        "ca572fff8740bbcd58d549723c80b0088d6676611eae2ab91624f460739aea10":
            ["MessagePack.Unity/ColorFormatter.cs"]
    }
    for assembly, names in targets.items():
        for name in names:
            choices = sorted((recovered / assembly).glob("*/project/" + name))
            if not choices:
                raise ValueError(f"Required source evidence unavailable: {name}")
            path = choices[0]
            evidence.append({"path": str(path.relative_to(ROOT)), "sha256": sha(path.read_bytes()), "assemblySHA256": assembly})
    return {"schemaVersion": 1, "kind": "koikatsu-edited-card-contract", "evidence": evidence,
            "shapeCounts": {"face": 52, "body": 44},
            "recordVersions": {"face": "0.0.2", "body": "0.0.2", "hair": "0.0.4", "clothes": "0.0.1", "accessory": "0.0.2", "makeup": "0.0.0"},
            "coordinateFraming": "MessagePack array of binary values, each i32 clothesSize + clothes + i32 accessorySize + accessory + bool enableMakeup + i32 makeupSize + makeup",
            "colorFraming": "RGBA array of four Float32 values; original Unity ColorFormatter permits extra/missing slots but this editor requires the current writer's exact four slots",
            "scope": "Token-preserving existing shapes/colors and thumbnail editing; asset identity and plug-in bytes stay unchanged"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?", default=ROOT / ".local/reverse/cards/edited-roundtrip")
    args = parser.parse_args()
    directory = args.directory.resolve()
    if not directory.is_relative_to((ROOT / ".local").resolve()):
        raise ValueError("Evidence directory must be under ignored .local")
    report = validate(directory)
    contract = evidence_contract()
    (directory / "contract.json").write_text(json.dumps(contract, indent=2) + "\n")
    (directory / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
