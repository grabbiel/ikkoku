#!/usr/bin/env python3
"""Independent UniversalAutoResolver card oracle from installed managed sources.

Only metadata is decoded: no managed plugin, game binary or asset is executed.
Original source and generated synthetic cards remain in ignored .local storage.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import re
import struct

try:
    from . import card_contract as card
    from . import mod_catalog_contract as catalog
except ImportError:
    import card_contract as card
    import mod_catalog_contract as catalog


REPO = card.REPO
EC_ID = "EC.Core.Sideloader.UniversalAutoResolver"
KK_ID = "com.bepis.sideloader.universalautoresolver"
STRINGS = ("ModID", "Property", "Author", "Website", "Name")
INTEGERS = ("Slot", "LocalSlot", "CategoryNo")
MAX_RECORDS = 10000
MAX_RECORD_BYTES = 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_FIELD_BYTES = 65536


def pack(value):
    import msgpack
    return msgpack.packb(value, use_bin_type=True, use_single_float=True)


def record(data: bytes, *, strict: bool = False) -> dict:
    """Source class formatter: defaults, sequential validation, last known key wins.

    Source Deserialize(byte[]) ignores readSize. strict=True imposes the native
    exact-consumption policy. Null object records are rejected by this oracle,
    since original subsequent list access dereferences them and fails anyway.
    """
    if not data or len(data) > MAX_RECORD_BYTES:
        raise ValueError("Resolver record exceeds byte bound or is empty")
    reader = card.MessagePackReader(data, card.Limits())
    root = reader.node()
    if strict and reader.offset != len(data):
        raise ValueError("Trailing bytes after ResolveInfo object")
    if root.kind != "map":
        raise ValueError("ResolveInfo must be a non-null string-key map")
    values = {**{key: None for key in STRINGS}, **{key: 0 for key in INTEGERS}}
    occurrences, unknown = {}, []
    for key, value in root.value:
        if key.kind != "str":
            raise ValueError("ResolveInfo keys must be strings")
        key = key.value
        occurrences[key] = occurrences.get(key, 0) + 1
        if key in STRINGS:
            if value.kind not in ("str", "nil"):
                raise ValueError(f"ResolveInfo {key} must be string or nil")
            if value.kind == "str" and len(value.value.encode("utf-8")) > MAX_FIELD_BYTES:
                raise ValueError(f"ResolveInfo {key} exceeds known-string byte bound")
            values[key] = value.value
        elif key in INTEGERS:
            if value.kind != "int" or data[value.start] in (0xcf, 0xd3) or not -(2**31) <= value.value < 2**31:
                raise ValueError(f"ResolveInfo {key} must be Int32")
            values[key] = value.value
        else:
            unknown.append(key)
    if values["ModID"] is not None:
        values["ModID"] = catalog.trim(values["ModID"])
    return {**values, "sha256": card.sha(data), "bytes": len(data), "consumedBytes": reader.offset,
            "trailingBytes": len(data) - reader.offset,
            "duplicateKeys": [key for key, count in occurrences.items() if count > 1],
            "unknownKeys": unknown}


def extract(parsed: card.ParsedCard, *, strict: bool = False) -> dict:
    plugins = {plugin["id"]: plugin for plugin in parsed.plugins if not plugin["isNull"]}
    selected = plugins.get(EC_ID) or plugins.get(KK_ID)
    result = {"schemaVersion": 1, "kind": "koikatsu-card-resolver-oracle",
              "cardSHA256": card.sha(parsed.raw), "extensionFormat": parsed.report["extendedDataSource"],
              "pluginID": selected["id"] if selected else None,
              "pluginVersion": selected["version"] if selected else None,
              "records": [], "diagnostics": []}
    if selected is None:
        return result
    if selected["dataIsNull"]:
        # The source calls data.ContainsKey without a null guard.
        raise ValueError("Selected resolver PluginData.data is null")
    info = selected["dataNodes"].get("info")
    if info is None:
        result["diagnostics"].append("selected-plugin-has-no-info-marker")
        return result
    if info.kind != "array" or len(info.value) > MAX_RECORDS:
        raise ValueError("Resolver info must be a bounded array")
    total = 0
    for index, item in enumerate(info.value):
        if item.kind != "bin":
            raise ValueError("Resolver info entries must be binary")
        total += len(item.value)
        if total > MAX_TOTAL_BYTES:
            raise ValueError("Resolver info byte total exceeds bound")
        result["records"].append({"ordinal": index, **record(item.value, strict=strict)})
    return result


def destination(property_name: str, category: int, source_slot: int) -> dict:
    """Canonical prefixes emitted by source traversal; no guessing unknown paths."""
    match = re.fullmatch(r"(?:outfit(0|[1-9][0-9]*)\.)?(?:accessory(0|[1-9][0-9]*)\.)?(.+)", property_name)
    if match is None:
        raise ValueError("Invalid destination")
    outfit, accessory, base = match.groups()
    return {"property": property_name, "catalogProperty": base, "category": category,
            "sourceSlot": source_slot, "coordinateIndex": int(outfit) if outfit is not None else None,
            "accessoryIndex": int(accessory) if accessory is not None else None}


def direct_resolution(records: list[dict], destinations: list[dict], loaded: list[dict]) -> list[dict]:
    """Only explicit GUID lookup; source compatibility/missing-asset fallbacks stay explicit.

    Current category comes from the actual card structure. CategoryNo in the
    resolver record is intentionally not used for this lookup. First full
    property and first loaded registration win. Comparisons are case-sensitive.
    """
    result = []
    for target in destinations:
        ext = next((item for item in records if item["Property"] == target["property"]), None)
        entry = {"destination": target, "recordOrdinal": ext.get("ordinal") if ext else None}
        if ext is None or ext["ModID"] is None or not catalog.trim(ext["ModID"]):
            entry.update(status="requires-compatibility-resolution", selected=None)
        else:
            selected = next((item for item in loaded if item["Slot"] == ext["Slot"]
                             and item["CategoryNo"] == target["category"]
                             and item["Property"] == target["catalogProperty"]
                             and item["GUID"] == ext["ModID"]), None)
            entry.update(status="resolved" if selected else "missing-exact-reference", selected=selected,
                         recordedCategoryMatches=ext["CategoryNo"] == target["category"])
        result.append(entry)
    return result


def migrate_record(item: dict, migrations: list[dict], installed_guids: set[str]) -> dict:
    """One original MigrateData pass. This is evidence, not native migration support."""
    result = copy.deepcopy(item)
    guid = result["ModID"]
    if guid is None or not catalog.trim(guid):
        return result
    matches = [rule for rule in migrations if rule["GUIDOld"] == catalog.trim(guid)]
    if any(rule["MigrationType"] == "StripAll" for rule in matches):
        result["ModID"] = ""
        return result
    for rule in matches:
        if (rule.get("IDOld", 0) == result["Slot"] and rule.get("Category", 0) == result["CategoryNo"]
                and rule["GUIDNew"] and catalog.trim(rule["GUIDNew"]) in installed_guids):
            result["ModID"], result["Slot"] = catalog.trim(rule["GUIDNew"]), rule.get("IDNew", 0)
            return result
    for rule in matches:
        if (rule["MigrationType"] == "MigrateAll" and rule["GUIDNew"]
                and catalog.trim(rule["GUIDNew"]) in installed_guids):
            result["ModID"] = catalog.trim(rule["GUIDNew"])
            break
    return result


def frame(blocks: list[tuple[str, str, bytes]], *, legacy_plugins=None) -> bytes:
    infos, payload = [], bytearray()
    for name, version, data in blocks:
        infos.append({"name": name, "version": version, "pos": len(payload), "size": len(data)})
        payload.extend(data)
    infos.sort(key=lambda item: item["name"] != "KKEx")
    header = pack({"lstInfo": infos})
    output = (card.blank_png() + struct.pack("<i", 100) + card.dotnet_string(card.MAGIC)
              + card.dotnet_string("0.0.0") + struct.pack("<ii", 0, len(header))
              + header + struct.pack("<q", len(payload)) + payload)
    if legacy_plugins is not None:
        raw = pack(legacy_plugins)
        output += card.dotnet_string("KKEx") + struct.pack("<ii", 2, len(raw)) + raw
    return bytes(output)


def fixture_card(plugins: dict, *, legacy_plugins=None) -> bytes:
    base = card.parse_card(card.fixture_bytes(pack([]), current=False))
    blocks = [(item["name"], item["version"], item["raw"]) for item in sorted(base.blocks, key=lambda item: item["pos"])]
    custom_index = next(index for index, item in enumerate(blocks) if item[0] == "Custom")
    reader = card.Cursor(blocks[custom_index][2])
    maps = []
    import msgpack
    for _ in range(3):
        maps.append(msgpack.unpackb(reader.take(reader.number("<i")), raw=False))
    maps[0].update(pupil=[{"id": 17, "gradMaskId": 0}, {"id": 18, "gradMaskId": 0}])
    custom = b"".join(struct.pack("<i", len(raw)) + raw for raw in map(pack, maps))
    blocks[custom_index] = ("Custom", "0.0.0", custom)
    coordinate_index = next(index for index, item in enumerate(blocks) if item[0] == "Coordinate")
    clothes = pack({"version": "0.0.1", "parts": []})
    accessory = pack({"version": "0.0.2", "parts": [{"type": 122, "id": 1080}]})
    makeup = pack({"version": "0.0.0"})
    coordinate = (struct.pack("<i", len(clothes)) + clothes + struct.pack("<i", len(accessory)) + accessory
                  + b"\0" + struct.pack("<i", len(makeup)) + makeup)
    blocks[coordinate_index] = ("Coordinate", "0.0.0", pack([coordinate]))
    blocks.append(("KKEx", "3", pack(plugins)))
    return frame(blocks, legacy_plugins=legacy_plugins)


def fixture_records() -> list[bytes]:
    first = {"ModID": "\u00a0fixture.pupil\u3000", "Slot": 17, "LocalSlot": 100012345,
             "Property": "ChaFileFace.Pupil1", "CategoryNo": 122, "Author": "Synthetic",
             "Website": None, "Name": "Synthetic pupil reference", "Unknown": {"retain": b"\x00\xff"}}
    # Duplicate full destination must not overwrite first record.
    second = {**first, "ModID": "wrong.duplicate", "CategoryNo": 408, "Slot": 99}
    accessory = {"ModID": "enk.acc.bald", "Slot": 1080, "LocalSlot": 100099999,
                 "Property": "outfit0.accessory0.ChaFileAccessory.PartsInfo.id", "CategoryNo": 122}
    return [pack(first), pack(second), pack(accessory), pack({})]


def evidence() -> dict:
    relative_paths = [
        ".local/reverse/mods/source/BepInEx/plugins/KK_BepisPlugins/Sideloader.dll",
        ".local/reverse/mods/decompiled/Sideloader.AutoResolver.UniversalAutoResolver.decompiled.cs",
        ".local/reverse/mods/decompiled/Sideloader.AutoResolver.ResolveInfo.decompiled.cs",
        ".local/reverse/mods/decompiled/Sideloader.AutoResolver.StructReference.decompiled.cs",
        ".local/reverse/mods/decompiled/Sideloader.AutoResolver.CategoryProperty.decompiled.cs",
        ".local/reverse/mods/decompiled/Sideloader.AutoResolver.MigrationInfo.decompiled.cs",
        ".local/reverse/mods/decompiled/Sideloader.Manifest.decompiled.cs",
        ".local/reverse/mods/decompiled/Sideloader.Sideloader.decompiled.cs",
        ".local/reverse/cards/decompiled/MessagePack.Internal.DynamicObjectTypeBuilder.decompiled.cs",
        ".local/reverse/cards/decompiled/MessagePack.MessagePackSerializer.decompiled.cs",
        ".local/reverse/cards/decompiled/MessagePack.MessagePackBinary.decompiled.cs",
        ".local/reverse/cards/decompiled/MessagePack.Decoders.UInt32Int32.decompiled.cs",
    ]
    return {"schemaVersion": 1, "kind": "koikatsu-card-resolver-contract",
            "pluginPrecedence": [EC_ID, KK_ID], "versionReadBySource": False,
            "field": "info", "encoding": "array of binary MessagePack string-key ResolveInfo maps; uncompressed",
            "stringFields": list(STRINGS), "integerFields": list(INTEGERS),
            "defaults": "String fields nil; Int32 fields 0. GUID setter uses .NET Char.IsWhiteSpace Trim.",
            "duplicates": "Known map keys last wins after each value validates; full Property records first wins.",
            "sourceIntegerTokens": "ReadInt32 accepts fixints, cc/cd/ce and d0/d1/d2 only; cf/d3 rejected even when value fits Int32. UInt32 conversion checked.",
            "lookup": "record Slot + actual destination category + unprefixed property + trimmed ordinal GUID; first loaded record wins",
            "migration": "Optional one pass: StripAll wins; first installed target matching record Slot/CategoryNo; else first installed MigrateAll.",
            "nativeHardening": "Reject null records and trailing bytes; 10000 records, 1 MiB per record, 64 MiB total, 65536 UTF8 bytes per known string field.",
            "evidence": [{"path": path, "sha256": card.sha((REPO / path).read_bytes())} for path in relative_paths]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--card", type=Path)
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/cards/resolver")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(REPO / ".local"):
        parser.error("Evidence output must stay under ignored .local")
    output.mkdir(parents=True, exist_ok=True)
    if args.card:
        with args.card.open("rb") as stream:
            parsed = card.parse_card(stream.read(card.Limits().card_bytes + 1))
        report = extract(parsed)
        (output / "card-report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps({"report": str(output / "card-report.json"), "records": len(report["records"])}))
        return
    records = fixture_records()
    normal = {KK_ID: [0, {"info": records}], "fixture.unknown": [91, {"opaque": b"preserve"}]}
    ec = {**normal, EC_ID: [888, {"info": [records[2]]}]}
    cases = [("current", normal, None), ("ec-precedence", ec, None),
             ("ec-without-info", {**normal, EC_ID: [12, {}]}, None),
             ("null-ec-falls-back", {**normal, EC_ID: None}, None),
             ("legacy-override", normal, ec)]
    fixture_list = []
    for name, plugins, legacy in cases:
        raw = fixture_card(plugins, legacy_plugins=legacy)
        report = extract(card.parse_card(raw), strict=True)
        path = output / ("synthetic-" + name + ".png")
        path.write_bytes(raw)
        report_path = path.with_suffix(".json")
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        fixture_list.append({"name": name, "path": str(path.relative_to(REPO)), "sha256": card.sha(raw),
                             "report": str(report_path.relative_to(REPO))})
    duplicate = b"\x84" + pack("ModID") + pack("old") + pack("ModID") + pack(" final ") + pack("Slot") + pack(1) + pack("Slot") + pack(2)
    raw_cases = {"defaults": pack({}), "duplicate-keys": duplicate, "unknown-fields": records[0]}
    for name, raw in raw_cases.items():
        (output / (name + ".bin")).write_bytes(raw)
        (output / (name + ".json")).write_text(json.dumps(record(raw, strict=True), indent=2, ensure_ascii=False) + "\n")
    contract = evidence()
    contract["fixtures"] = fixture_list
    (output / "contract.json").write_text(json.dumps(contract, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"contract": str(output / "contract.json"), "fixtures": len(cases), "recordFixtures": len(raw_cases)}))


if __name__ == "__main__":
    main()
