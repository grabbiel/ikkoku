#!/usr/bin/env python3
"""Bridge an explicit ABMX boneData payload to a native static-baseline document.

Without --bone-data, emit local evidence, synthetic source-format examples, and
an independent NumPy pose oracle. This does not read character cards or run mods.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct

import lz4.block
import msgpack
import numpy as np

REPO = Path(__file__).resolve().parents[3]
ASSEMBLY_SHA = "f3e2d9877b08b2b25187cbc101478ea0d484bcfe4856244050ba3119578e9f68"
MAX_PAYLOAD = 16 * 1024 * 1024
MAX_EXPANDED = 64 * 1024 * 1024
MAX_RECORDS = 10000
MAX_COORDINATES = 1024
MAX_BONE_NAME = 1024
MAX_FLOAT32 = float(np.finfo(np.float32).max)
IDENTITY = [[1.0, 1.0, 1.0], 1.0, [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
DYNAMIC_INFLUENCE_PREFIXES = ("cf_d_sk_", "cf_j_bust0", "cf_d_siri01_", "cf_j_siri_")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value):
    path = path.resolve()
    if not path.is_relative_to(REPO / ".local"):
        raise ValueError("Recovered source and derived local data must remain under ignored .local")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2) + "\n")


def unpack_payload(payload: bytes):
    if not payload or len(payload) > MAX_PAYLOAD:
        raise ValueError("boneData payload must contain 1 byte through 16 MiB")
    options = dict(raw=False, strict_map_key=False, max_array_len=100000, max_map_len=100000,
                   max_str_len=1024 * 1024, max_bin_len=MAX_EXPANDED, max_ext_len=MAX_PAYLOAD)
    value = msgpack.unpackb(payload, **options)
    if isinstance(value, msgpack.ExtType):
        if value.code != 99:
            raise ValueError(f"Unsupported MessagePack extension {value.code}; ABMX uses LZ4 extension99")
        reader = msgpack.Unpacker(raw=False, max_buffer_size=MAX_PAYLOAD)
        reader.feed(value.data)
        try:
            size = next(reader)
        except StopIteration as error:
            raise ValueError("Truncated ABMX LZ4 expanded-size header") from error
        if type(size) is not int or not 0 < size <= MAX_EXPANDED:
            raise ValueError("Invalid or oversized ABMX LZ4 expanded byte count")
        try:
            expanded = lz4.block.decompress(value.data[reader.tell():], uncompressed_size=size)
        except lz4.block.LZ4BlockError as error:
            raise ValueError("Invalid or truncated ABMX LZ4 block") from error
        if len(expanded) != size:
            raise ValueError("LZ4 expansion did not match its source byte count")
        value = msgpack.unpackb(expanded, **options)
    return value


def source_payload(records: list, compress: bool = True) -> bytes:
    raw = msgpack.packb(records, use_bin_type=True, use_single_float=True)
    if len(raw) < 64 or not compress:
        return raw
    data = b"\xd2" + struct.pack(">i", len(raw)) + lz4.block.compress(raw, store_size=False)
    # Original MessagePack v1 serializer forces ext32 + signed int32 headers.
    return b"\xc9" + struct.pack(">I", len(data)) + b"\x63" + data


def convert(payload: bytes, data_kind: str = "card", data_version: int = 2) -> dict:
    if (data_kind, data_version) not in (("card", 2), ("coordinate", 3)):
        raise ValueError("Supported source versions are card v2 and coordinate v3; card v1 is legacy text (convert_legacy), and coordinate v2 migration is not ported")
    raw = unpack_payload(payload)
    if not isinstance(raw, list) or len(raw) > MAX_RECORDS:
        raise ValueError(f"boneData must be a list of at most {MAX_RECORDS} BoneModifier records")

    def number(value):
        if type(value) not in (float, int) or not math.isfinite(value) or abs(value) > MAX_FLOAT32:
            raise ValueError("BoneModifier numeric values must be finite float32 scalars")
        return float(np.float32(value))

    def vector(value):
        if not isinstance(value, list) or len(value) != 3:
            raise ValueError("Source Unity Vector3 must contain exactly three scalars")
        return [number(x) for x in value]

    modifiers, identities, diagnostics = [], set(), []
    for record in raw:
        # Int-keyed MessagePack object (keys 0 BoneName, 1 CoordinateModifiers,
        # 2 BoneLocation): the original's formatter reads an array of any length,
        # gives a missing key its default and skips unknown keys (#401). Saves from
        # before BoneLocation have two fields (location 0, Unknown). The source
        # constructor fails without a name or coordinates.
        if not isinstance(record, list) or len(record) < 2:
            raise ValueError("ABMX records require BoneName and CoordinateModifiers in source order (BoneLocation may follow)")
        name, coordinates = record[0], record[1]
        location = record[2] if len(record) >= 3 else 0
        if not isinstance(name, str) or not name or len(name) > MAX_BONE_NAME or "\0" in name:
            raise ValueError("BoneName must be a nonempty source name")
        if type(location) is not int or location < 0:
            raise ValueError("BoneLocation must be a nonnegative integer")
        if len(record) > 3:
            diagnostics.append({"code": "skipped-unknown-fields", "severity": "warning", "boneName": name,
                                "message": f"ABMX record '{name}' has {len(record)} fields; fields after BoneLocation are skipped, as the original's formatter skips unknown keys."})
        if (location, name) in identities:
            raise ValueError(f"Duplicate ABMX location/name: {location}/{name}")
        identities.add((location, name))
        if not isinstance(coordinates, list) or not 1 <= len(coordinates) <= MAX_COORDINATES:
            raise ValueError(f"CoordinateModifiers requires 1 through {MAX_COORDINATES} data records; null/empty arrays are rejected by the source constructor")
        values = []
        for coordinate_index, data in enumerate(coordinates):
            if data is None:
                # The serialization constructor routes through the ordinary
                # constructor, which repairs each null element and logs a warning.
                data = IDENTITY
                diagnostics.append({"code": "repaired-null-coordinate", "severity": "warning", "boneName": name,
                                    "coordinateIndex": coordinate_index,
                                    "message": f"ABMX repaired null coordinate #{coordinate_index + 1} for '{name}' to identity; the converted document preserves this repair."})
            # Keys 0 Scale, 1 Length, 2 Position, 3 Rotation. Saves from before
            # Position and Rotation have two fields; a missing one is Vector3.zero.
            if not isinstance(data, list):
                raise ValueError("Expected source modifier keys0 Scale,1 Length,2 Position,3 Rotation")
            if len(data) < 2:
                raise ValueError(f"ABMX coordinate entry #{coordinate_index + 1} for '{name}' has {len(data)} field(s). The original would read it with default values (a zero Scale or Length), which is not implemented; no known card uses this layout.")
            if len(data) > 4:
                diagnostics.append({"code": "skipped-unknown-fields", "severity": "warning", "boneName": name,
                                    "coordinateIndex": coordinate_index,
                                    "message": f"ABMX coordinate #{coordinate_index + 1} for '{name}' has {len(data)} fields; fields after Rotation are skipped, as the original's formatter skips unknown keys."})
            values.append({"scaleModifier": vector(data[0]), "lengthModifier": number(data[1]),
                           "positionModifier": vector(data[2]) if len(data) > 2 else [0.0, 0.0, 0.0],
                           "rotationModifier": vector(data[3]) if len(data) > 3 else [0.0, 0.0, 0.0]})
        modifiers.append({"boneName": name, "boneLocation": location, "coordinateModifiers": values})
        if location not in (0, 1):
            diagnostics.append({"code": "unsupported-bone-location", "severity": "warning", "boneName": name,
                                "boneLocation": location,
                                "message": f"ABMX bone '{name}' uses location {location}; the native static evaluator rejects active accessory/unknown-scope modifiers."})
        elif name.startswith(DYNAMIC_INFLUENCE_PREFIXES):
            diagnostics.append({"code": "unsupported-dynamic-bone", "severity": "warning", "boneName": name,
                                "message": f"ABMX bone '{name}' uses the source dynamic-baseline/gravity path; the native static evaluator rejects active modifiers on this target."})
    return {
        "schemaVersion": 1, "kind": "ikkoku-source-bone-modifiers",
        "coordinateSpace": "unity-left-handed-y-up", "angleUnit": "degrees", "mode": "staticBaseline",
        "source": {"pluginGUID": "KKABMX.Core", "dataGUID": "KKABMPlugin.ABMData", "pluginVersion": "5.4",
                   "dataKind": data_kind, "dataVersion": data_version,
                   "assemblySHA256": ASSEMBLY_SHA, "payloadSHA256": sha(payload)},
        "modifiers": modifiers, "diagnostics": diagnostics,
    }


# ABMX card PluginData version 1: the legacy text boneData that KKABMX 5.4 reads
# through OldDataConverter.MigrateOldExtData (#403). Mirrors
# SourceBoneModifiersLegacy.swift rule for rule, with the same messages.
# char.IsWhiteSpace, which string.Split() with no separators uses: U+0009-U+000D,
# U+0085 and the Zs, Zl and Zp characters; U+180E because Mono's Unicode data
# predates its move out of Zs. Not str.split(), which also splits on U+001C-U+001F.
LEGACY_WHITESPACE = frozenset([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x180E,
                               0x2028, 0x2029, 0x202F, 0x205F, 0x3000, *range(0x2000, 0x200B)])
LEGACY_NUMBER = re.compile(r"[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?")
LEGACY_FAILURE = object()


def legacy_number(text: str):
    """float.Parse with the invariant culture on a token with no whitespace or
    commas left: a decimal with an optional sign and exponent, or Infinity,
    -Infinity and NaN. Parsed as a double and rounded to float32, as Mono does; a
    double beyond float32 range (|x| > float32 max, even when it would round to
    it) becomes infinite, which the caller refuses (#403 decision 5). Returns
    LEGACY_FAILURE when the original would fail to parse."""
    symbols = {"Infinity": math.inf, "-Infinity": -math.inf, "NaN": math.nan}
    if text in symbols:
        return symbols[text]
    if not LEGACY_NUMBER.fullmatch(text):
        return LEGACY_FAILURE
    double = float(text)
    if abs(double) > MAX_FLOAT32:
        return -math.inf if double < 0 else math.inf
    return struct.unpack("<f", struct.pack("<f", double))[0]


def _utf16(text: str) -> tuple:
    data = text.encode("utf-16-le", "surrogatepass")
    return struct.unpack(f"<{len(data) // 2}H", data)


def _legacy_document(text: str, modifiers: list, diagnostics: list) -> dict:
    return {
        "schemaVersion": 1, "kind": "ikkoku-source-bone-modifiers",
        "coordinateSpace": "unity-left-handed-y-up", "angleUnit": "degrees", "mode": "staticBaseline",
        "source": {"pluginGUID": "KKABMX.Core", "dataGUID": "KKABMPlugin.ABMData", "pluginVersion": "5.4",
                   "dataKind": "card", "dataVersion": 1,
                   "assemblySHA256": ASSEMBLY_SHA, "payloadSHA256": sha(text.encode("utf-8"))},
        "modifiers": modifiers, "diagnostics": diagnostics,
    }


def _legacy_dropped(text: str, line: int) -> dict:
    return _legacy_document(text, [], [{
        "code": "legacy-data-dropped", "severity": "warning", "line": line,
        "message": f"ABMX legacy line {line} has a bone name the original cannot read; the original drops all ABMX data for this card."}])


def legacy_not_text() -> dict:
    """Version 1 data whose boneData is not a string: the original's legacy reader
    returns no modifiers, so the character loads without ABMX."""
    return _legacy_document("", [], [{
        "code": "legacy-bone-data-not-text", "severity": "warning",
        "message": "ABMX card v1 boneData is not text; the original's legacy reader returns no modifiers, so the character loads without ABMX."}])


def convert_legacy(text: str) -> dict:
    """Migrate card v1 text, as OldDataConverter.DeserializeToModifiers:
    whitespace-separated lines of comma-separated fields, grouped by bone name with
    the "__<coordinate>" suffix trimmed, Scale from fields 3-5 and Length from
    field 6 (1 when absent), at location 0 (Unknown)."""
    if not text or len(text.encode("utf-8")) > MAX_PAYLOAD:
        raise ValueError("ABMX card v1 boneData must contain 1 byte through 16 MiB of text.")
    # text.Split(), then Trim() and IsNullOrEmpty: whitespace-free tokens.
    tokens, current = [], []
    for character in text:
        if ord(character) in LEGACY_WHITESPACE:
            if current:
                tokens.append("".join(current))
                current = []
        else:
            current.append(character)
    if current:
        tokens.append("".join(current))
    # Split(',') keeps empty fields; tokens with fewer than 6 fields are dropped.
    lines = []
    for index, token in enumerate(tokens):
        fields = token.split(",")
        if len(fields) >= 6:
            lines.append((index + 1, fields, _utf16(fields[1])))
    # GroupBy(GetTrimmedName) runs over every line before the first group is read,
    # in UTF-16 indices: name[len-2] first, name[len-3] only when it is '_'. A name
    # too short for those reads throws, and ReadModifiers' catch then returns no
    # modifiers for the whole card.
    underscore = ord("_")
    groups = {}
    for line in lines:
        name = line[2]
        if len(name) < 2 or (len(name) == 2 and name[0] == underscore):
            return _legacy_dropped(text, line[0])
        key = name[:-3] if name[-2] == underscore and name[-3] == underscore else name
        groups.setdefault(key, []).append(line)
    if len(groups) > MAX_RECORDS:
        raise ValueError(f"ABMX boneData requires at most {MAX_RECORDS} BoneModifier records.")

    modifiers, diagnostics, non_finite = [], [], None
    for key, group in groups.items():
        # OrderBy(fields[1]), stable; ordinal UTF-16 order (the original's
        # comparer is culture-sensitive).
        entries = sorted(group, key=lambda line: line[2])
        name = struct.pack(f"<{len(key)}H", *key).decode("utf-16-le")
        kept = []
        for number, fields, _ in entries:
            parsed, failed = [], None
            for field in range(3, min(len(fields), 7)):
                value = legacy_number(fields[field])
                if value is LEGACY_FAILURE:
                    failed = field
                    break
                parsed.append(value)
            if failed is not None:
                diagnostics.append({"code": "skipped-legacy-line", "severity": "warning", "boneName": name, "line": number,
                                    "message": f"ABMX legacy line {number} for '{name}' has an unparsable value in field {failed}; it is skipped, as the original skips lines that fail to parse."})
                continue
            kept.append((number, {"scaleModifier": parsed[:3], "lengthModifier": parsed[3] if len(parsed) > 3 else 1.0,
                                  "positionModifier": [0.0, 0.0, 0.0], "rotationModifier": [0.0, 0.0, 0.0]}))
        if not kept:
            continue
        # new BoneModifier(key, ...) throws for an empty name; that also reaches
        # ReadModifiers' catch and drops every modifier.
        if not key:
            return _legacy_dropped(text, kept[0][0])
        parsed_count = len(kept)
        if len(kept) > 7:
            kept = kept[-7:]
        if 1 < len(kept) < 7:
            kept = kept[-1:]
        # Only the kept entries reach the character.
        for number, values in kept:
            if non_finite is None:
                scalars = values["scaleModifier"] + [values["lengthModifier"]]
                bad = next((index for index, value in enumerate(scalars) if not math.isfinite(value)), None)
                if bad is not None:
                    non_finite = (number, name, bad + 3)
        if len(kept) != parsed_count:
            diagnostics.append({"code": "legacy-coordinates-truncated", "severity": "warning", "boneName": name,
                                "message": f"ABMX legacy bone '{name}' has {parsed_count} parsed lines; the original keeps the last {len(kept)}."})
        if len(name) > MAX_BONE_NAME or "\0" in name:
            raise ValueError("ABMX BoneName must contain 1 through 1024 source characters and no NUL.")
        modifiers.append({"boneName": name, "boneLocation": 0, "coordinateModifiers": [values for _, values in kept]})
        if name.startswith(DYNAMIC_INFLUENCE_PREFIXES):
            diagnostics.append({"code": "unsupported-dynamic-bone", "severity": "warning", "boneName": name,
                                "message": f"ABMX bone '{name}' uses the source dynamic-baseline/gravity path; the native static evaluator rejects active modifiers on this target."})
    if non_finite is not None:
        line, name, field = non_finite
        raise ValueError(f"ABMX legacy line {line} for '{name}' has a non-finite or out-of-range value in field {field}; ABMX modifier values must be finite float32 numbers.")
    return _legacy_document(text, modifiers, diagnostics)


def quaternion_mul(a, b):
    ax, ay, az, aw = map(float, a)
    bx, by, bz, bw = map(float, b)
    return np.array([aw * bx + ax * bw + ay * bz - az * by,
                     aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw,
                     aw * bw - ax * bx - ay * by - az * bz], dtype=np.float32)


def unity_euler(value):
    half = np.asarray(value, dtype=np.float32) * np.float32(math.pi / 360)
    sine, cosine = np.sin(half), np.cos(half)
    return quaternion_mul(quaternion_mul([0, sine[1], 0, cosine[1]], [sine[0], 0, 0, cosine[0]]),
                          [0, 0, sine[2], cosine[2]])


def matrix(position, rotation, scale):
    # Independent source-space quaternion matrix, then a Z reflection into native.
    x, y, z, w = map(float, rotation)
    rotation_matrix = np.array([[1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w],
                                [2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w],
                                [2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y]], dtype=np.float32)
    result = np.eye(4, dtype=np.float32)
    result[:3, :3] = rotation_matrix * np.asarray(scale, dtype=np.float32)[None, :]
    result[:3, 3] = position
    reflect = np.diag([1, 1, -1, 1]).astype(np.float32)
    return reflect @ result @ reflect


def oracle():
    baseline = [
        {"name": "root", "parent": None, "translation": [0.1, -0.2, 0.3],
         "rotation": unity_euler([5, 10, -15]).tolist(), "scale": [1.2, 0.8, 1.1]},
        {"name": "test_bone", "parent": 0, "translation": [1.0, 2.0, 3.0],
         "rotation": unity_euler([12, -24, 36]).tolist(), "scale": [1.5, 0.75, 2.0]},
        {"name": "test_child", "parent": 1, "translation": [0.4, -0.5, 0.6],
         "rotation": unity_euler([-8, 16, 24]).tolist(), "scale": [0.9, 1.0, 1.1]},
    ]
    combined = [[0.8, 1.2, 0.9], 1.3, [0.1, -0.2, 0.3], [10, 25, -5]]
    cases = [
        ("allFourProperties", [["test_bone", [combined], 1]], 0),
        ("globalCoordinate", [["test_bone", [combined], 1]], 5),
        ("coordinateZero", [["test_bone", [IDENTITY, combined], 1]], 0),
        ("coordinateOne", [["test_bone", [IDENTITY, combined], 1]], 1),
        ("coordinateMissing", [["test_bone", [IDENTITY, combined], 1]], 2),
        ("lengthPlusPosition", [["test_bone", [[[1, 1, 1], 1.4, [-0.1, 0.2, 0.3], [0, 0, 0]]], 0]], 0),
        ("negativeScale", [["test_bone", [[[-1, 0.75, 1], 1, [0, 0, 0], [0, 0, 0]]], 1]], 0),
        ("independentParentChild", [["test_child", [combined], 0], ["test_bone", [combined], 1]], 0),
    ]
    output = []
    for name, records, coordinate in cases:
        # Use the original array schema directly, independent of the JSON adapter.
        raw = unpack_payload(source_payload(records))
        transforms = {b["name"]: [np.array(b[k], dtype=np.float32) for k in ("translation", "rotation", "scale")]
                      for b in baseline}
        for _, record in sorted(enumerate(raw), key=lambda pair: (pair[1][2], pair[0])):
            bone, coordinates, location = record
            values = coordinates[0] if len(coordinates) == 1 else coordinates[coordinate] if coordinate < len(coordinates) else None
            if values is None:
                continue
            scale, length, offset, euler = values
            p, r, s = transforms[bone]
            transforms[bone] = [p * np.float32(length) + np.array(offset, dtype=np.float32),
                                quaternion_mul(r, unity_euler(euler)), s * np.array(scale, dtype=np.float32)]
        local, world = [], []
        for node in baseline:
            m = matrix(*transforms[node["name"]])
            local.append(m)
            world.append(m if node["parent"] is None else world[node["parent"]] @ m)
        output.append({"id": name, "coordinate": coordinate, "document": convert(source_payload(records)),
                       "baselineNodes": baseline,
                       "expectedLocalMatrices": [m.flatten(order="F").tolist() for m in local],
                       "expectedWorldMatrices": [m.flatten(order="F").tolist() for m in world]})
    return {"schemaVersion": 1, "matrixLayout": "column-major", "coordinateSpace": "native-right-handed-y-up",
            "description": "Independent NumPy application of original array records and Unity ZXY quaternion composition; synthetic bones only.",
            "cases": output}


def evidence() -> dict:
    root = REPO / ".local/reverse/decompiled/ABMX"
    manifest = json.loads((root / "manifest.json").read_text())
    assert sha((REPO / manifest["assembly"]).read_bytes()) == ASSEMBLY_SHA == manifest["sha256"]
    for entry in manifest["types"]:
        assert sha((REPO / entry["path"]).read_bytes()) == entry["sha256"]
    return {"schemaVersion": 1, "provenance": manifest,
            "sourcePluginGUID": "KKABMX.Core", "extendedDataGUID": "KKABMPlugin.ABMData",
            "sourceVersions": {"cardWrite": 2, "cardRead": [1, 2], "coordinateWrite": 3, "coordinateRead": [2, 3]},
            "supportedConversionVersions": {"card": [2], "coordinate": [3]}, "pluginDataKey": "boneData",
            "payload": {"encoding": "MessagePack", "lz4ExtensionCode": 99, "compressionThresholdBytes": 64,
                        "extensionData": "MessagePack signed int32 expanded size, then raw LZ4 block",
                        "boneModifierKeys": ["BoneName", "CoordinateModifiers", "BoneLocation"],
                        "modifierDataKeys": ["ScaleModifier", "LengthModifier", "PositionModifier", "RotationModifier"],
                        "vector3Encoding": "three float32 array elements"},
            "location": {"unknown": 0, "bodyTop": 1, "accessoryBase": 10},
            "nullCoordinateBehavior": {"individualEntry": "repair to identity and warn",
                                       "wholeArray": "throw ArgumentNullException", "emptyArray": "throw ArgumentException"},
            "updateOrder": ["scale", "rotation", "position"],
            "formulas": {"scale": "baselineScale * scaleModifier (componentwise)",
                         "rotation": "baselineRotation * Quaternion.Euler(rotationModifierDegrees), Z then X then Y",
                         "position": "baselinePosition * lengthModifier + positionModifier"},
            "combiningAdditionalEffects": {"scale": "componentwise multiply", "length": "multiply",
                                            "position": "add", "rotationDegrees": "add before Euler conversion"},
            "unsupported": ["Card v1 and coordinate v2 legacy migration", "DynamicBone and gravity corrections",
                            "Accessory location lookup", "BoneEffect callbacks", "Partial/animated baseline updates",
                            "Duplicate/ambiguous bone resolution", "Reflected/singular/sheared baseline rotation extraction"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bone-data", type=Path, help="Explicit extracted PluginData.data['boneData'] bytes (card v1: its UTF-8 text); not a whole card")
    parser.add_argument("--data-kind", choices=["card", "coordinate"], default="card")
    parser.add_argument("--data-version", type=int, default=2)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.bone_data:
        if not args.output:
            parser.error("--bone-data requires an explicit --output under .local")
        if args.bone_data.stat().st_size > MAX_PAYLOAD:
            raise ValueError("boneData payload exceeds 16 MiB")
        payload = args.bone_data.read_bytes()
        if (args.data_kind, args.data_version) == ("card", 1):
            # Card v1 boneData is a string: the file holds its UTF-8 text.
            try:
                text = payload.decode("utf-8")
            except UnicodeDecodeError as error:
                raise ValueError("ABMX card v1 boneData must be UTF-8 text") from error
            document = convert_legacy(text)
        else:
            document = convert(payload, args.data_kind, args.data_version)
        write_json(args.output, document)
        print(f"Converted {len(document['modifiers'])} ABMX records to {args.output}")
        for diagnostic in document["diagnostics"]:
            print(f"{diagnostic['severity']}: {diagnostic['message']}")
        return
    root = REPO / ".local/reverse/mods/abmx"
    write_json(root / "contract.json", evidence())
    example = [["cf_J_FaceRoot", [[[1.03, 1.02, 1.0], 1.0, [0, 0.002, 0], [0, 0, 2]]], 1],
               ["cf_j_forearm01_L", [[[1, 1, 1], 1.02, [0, 0, 0], [0, 0, 0]]], 1],
               ["cf_j_forearm01_R", [[[1, 1, 1], 1.02, [0, 0, 0], [0, 0, 0]]], 1]]
    payload = source_payload(example)
    (root / "synthetic.boneData.bin").write_bytes(payload)
    converted = convert(payload)
    assert converted["modifiers"] == convert(source_payload(example, compress=False))["modifiers"]
    output = args.output or REPO / ".local/reverse/rigs/source-abmx-example.json"
    write_json(output, converted)
    reference = REPO / ".local/reverse/rigs/source-abmx-reference.json"
    write_json(reference, oracle())
    print(f"Evidence: {root / 'contract.json'}")
    print(f"Synthetic source-format example: {output}; reference: {reference}")


if __name__ == "__main__":
    main()
