#!/usr/bin/env python3
"""Resolve one CharaStudio item query from explicitly selected local info bundles.

Reads serialized ExcelData through UnityPy. Writes only matching rows and their
provenance, never the full catalog. No source installation files are modified.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

import UnityPy

REPO = Path(__file__).resolve().parents[2]
DEFAULT_BUNDLE = REPO / ".local/reverse/source/abdata/studio/info/00.unity3d"
ITEM_NAME = re.compile(r"ItemList_(\d+)_(\d+)_(\d+)$", re.IGNORECASE)
CATEGORY_NAME = re.compile(r"ItemCategory_(\d+)_(\d+)$", re.IGNORECASE)
GROUP_NAME = re.compile(r"ItemGroup_(\d+)$", re.IGNORECASE)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def integer(value: str) -> int | None:
    try:
        number = int(value)
        return number if -(2**31) <= number < 2**31 else None
    except ValueError:
        return None


def boolean(value: str, *, optional: bool = False) -> bool:
    value = value.strip().lower()
    if value in ("true", "false"):
        return value == "true"
    if optional:
        return False  # Original optional columns use bool.TryParse.
    raise ValueError(f"Invalid required Boolean cell: {value!r}")


def rows(table: dict):
    for row_index, entry in enumerate(table.get("list", [])):
        if row_index == 0:
            continue
        values = entry.get("list", [])
        if not isinstance(values, list) or not all(isinstance(cell, str) for cell in values):
            raise ValueError(f"Malformed ExcelData row in {table.get('m_Name')}")
        yield row_index, values


def item_record(values: list[str], evidence: dict) -> dict:
    if len(values) < 16:
        raise ValueError(f"Item row has {len(values)} columns; expected at least 16: {evidence}")
    no, group, category = (integer(value) for value in values[:3])
    if no is None or group is None or category is None:
        raise ValueError(f"Invalid item catalog key: {evidence}")
    return {
        "group": group, "category": category, "no": no, "name": values[3],
        "manifest": values[4], "bundlePath": values[5], "prefab": values[6],
        "childRoot": values[7], "animated": boolean(values[8]),
        "colorSlots": [boolean(values[index]) for index in (9, 11, 13)],
        "patternSlots": [boolean(values[index]) for index in (10, 12, 14)],
        "scalable": boolean(values[15]),
        "emission": boolean(values[16], optional=True) if len(values) > 16 else False,
        "glass": boolean(values[17], optional=True) if len(values) > 17 else False,
        "evidence": evidence,
    }


def lookup(bundles: list[Path], *, prefab: str | None, key: tuple[int, int, int] | None) -> dict:
    effective: dict[tuple[int, int, int], dict] = {}
    groups: dict[int, str] = {}
    categories: dict[tuple[int, int], str] = {}
    matches = []
    sources = []
    row_count = 0

    def selected(record: dict) -> bool:
        if prefab is not None:
            return record["prefab"] == prefab
        return (record["group"], record["category"], record["no"]) == key

    # Studio.Info sorts bundle paths, then item tables by group/category/revision.
    for bundle in sorted(set(path.resolve() for path in bundles), key=lambda path: str(path).casefold()):
        if not bundle.is_file() or bundle.stat().st_size > 32 * 1024 * 1024:
            raise ValueError(f"Missing info bundle or exceeds the 32 MiB bound: {bundle}")
        source = {"path": str(bundle), "bytes": bundle.stat().st_size, "sha256": sha256(bundle)}
        sources.append(source)
        tables = []
        for obj in UnityPy.load(str(bundle)).objects:
            if obj.type.name != "MonoBehaviour":
                continue
            table = obj.read_typetree()
            name = table.get("m_Name", "")
            if ITEM_NAME.fullmatch(name) or CATEGORY_NAME.fullmatch(name) or GROUP_NAME.fullmatch(name):
                tables.append((name, obj.path_id, table))

        for name, _, table in sorted(tables):
            group_match, category_match = GROUP_NAME.fullmatch(name), CATEGORY_NAME.fullmatch(name)
            if not group_match and not category_match:
                continue
            for _, values in rows(table):
                number = integer(values[0]) if values else None
                if number is None or len(values) < 2:
                    continue
                if group_match:
                    groups[number] = values[1]
                else:
                    categories[(int(category_match[2]), number)] = values[1]

        item_tables = [(tuple(map(int, match.groups())), name, path_id, table)
                       for name, path_id, table in tables if (match := ITEM_NAME.fullmatch(name))]
        item_tables.sort(key=lambda item: (item[0][1], item[0][2], item[0][0]))
        for _, name, path_id, table in item_tables:
            for row_index, values in rows(table):
                # The original LoadItemLoadInfo stops at the first nonnumeric ID.
                if not values or integer(values[0]) is None:
                    break
                row_count += 1
                evidence = {"infoBundle": str(bundle), "assetName": name,
                            "pathID": str(path_id), "rowIndex": row_index}
                record = item_record(values, evidence)
                item_key = (record["group"], record["category"], record["no"])
                effective[item_key] = record
                if selected(record):
                    matches.append(record)

    effective_matches = []
    for record in effective.values():
        if selected(record):
            enriched = dict(record)
            enriched["groupName"] = groups.get(record["group"])
            enriched["categoryName"] = categories.get((record["group"], record["category"]))
            effective_matches.append(enriched)
    effective_matches.sort(key=lambda record: (record["group"], record["category"], record["no"]))
    return {
        "schemaVersion": 1, "capturedAtUTC": datetime.now(timezone.utc).isoformat(),
        "query": {"prefab": prefab} if prefab is not None else {"group": key[0], "category": key[1], "no": key[2]},
        "coverage": "Only the explicitly supplied info bundles; runtime mod patches are not evaluated.",
        "sources": sources, "itemRowsExamined": row_count,
        "observedMatches": matches, "effectiveMatchesInSuppliedBundles": effective_matches,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, action="append", help="Repeat for explicit info bundles; paths are sorted before loading")
    query = parser.add_mutually_exclusive_group(required=True)
    query.add_argument("--prefab", help="Exact prefab name, not a substring")
    query.add_argument("--key", type=int, nargs=3, metavar=("GROUP", "CATEGORY", "NO"))
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/catalog/lookup.json")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((REPO / ".local").resolve()):
        parser.error("Source-derived catalog output must stay in the repository's ignored .local directory")
    bundles = args.bundle or [DEFAULT_BUNDLE]
    if len(bundles) > 32:
        parser.error("At most 32 explicitly selected info bundles may be inspected")
    result = lookup(bundles, prefab=args.prefab, key=tuple(args.key) if args.key else None)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(output), "matches": result["effectiveMatchesInSuppliedBundles"]}, indent=2, ensure_ascii=False))
    raise SystemExit(0 if result["effectiveMatchesInSuppliedBundles"] else 2)


if __name__ == "__main__":
    main()
