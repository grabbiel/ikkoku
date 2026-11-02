#!/usr/bin/env python3
"""Generate the converted CharaStudio item catalog from local bundles (ST-T04).

Every step reads and writes explicit paths, and output must stay in the
repository's ignored .local directory:

  list      the effective item table of the supplied info bundles (`catalog.item_table`)
  coverage  how many used items and scenes the table covers, from an anonymous
            key-usage file (per-scene key counts, nothing else)
  export    converts every selected row's prefab with export_prefab.py's rules in
            one process, loading each bundle set once; `--dry-run` is the survey
  catalog   a `KoikatsuAssetCatalog` version 1 file plus `notConverted`, `sources`
            and `coverage`, without timestamps, so two runs are byte-identical

Nothing is guessed. A row is converted, or it is listed in `notConverted` with the
exporter's own error message, or with the reason its bundle cannot be read here.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[2]
ITEM_FIELDS = ("group", "category", "no", "name", "manifest", "bundlePath", "prefab", "childRoot", "animated",
               "colorSlots", "patternSlots", "scalable", "emission", "glass")
# export_prefab.py's refusal for these rows, word for word.
SEPARATE_MAPPING = "Animated items and alternate child roots require a separate mapping"
SOURCE_ARCHIVE = "source-dumps.tar.zst"
# Written after the manifest: the export report and the catalog.
RUN_FILES = ("export-report.json", "catalog.json")


def key_text(row: dict) -> str:
    return f"{row['group']}/{row['category']}/{row['no']}"


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=1, ensure_ascii=False, sort_keys=True) + "\n")


def item_list_from_table(table: dict) -> dict:
    """The `list` output for a `catalog.item_table` result: effective rows sorted by key,
    with labels and evidence named by bundle file, not by local path."""
    items = []
    for (group, category, _), record in sorted(table["effective"].items()):
        row = {field: record[field] for field in ITEM_FIELDS}
        row["groupName"] = table["groups"].get(group)
        row["categoryName"] = table["categories"].get((group, category))
        evidence = record["evidence"]
        row["evidence"] = {"infoBundle": Path(evidence["infoBundle"]).name, "assetName": evidence["assetName"],
                           "pathID": evidence["pathID"], "rowIndex": evidence["rowIndex"]}
        items.append(row)
    sources = [{"file": Path(source["path"]).name, "bytes": source["bytes"], "sha256": source["sha256"]}
               for source in table["sources"]]
    return {"kind": "ikkoku.sourceStudioItemList", "version": 1, "sources": sources,
            "rowsExamined": table["rowCount"], "items": items}


def coverage(item_list: dict, usage: dict, groups: set[int] | None = None) -> dict:
    """Used items and scenes the table has a row for. `usage["scenes"]` holds one
    {"group/category/no": count} map per scene; scenes carry no other identity."""
    known = {key_text(row) for row in item_list["items"]}

    def scope(group_filter):
        items = in_table = 0
        keys, keys_in_table = set(), set()
        scenes = scenes_covered = 0
        for scene in usage["scenes"]:
            used = {key: count for key, count in scene.items()
                    if group_filter is None or int(key.split("/")[0]) in group_filter}
            if not used:
                continue
            scenes += 1
            scenes_covered += all(key in known for key in used)
            for key, count in used.items():
                items += count
                keys.add(key)
                if key in known:
                    in_table += count
                    keys_in_table.add(key)
        return {"items": items, "itemsInTable": in_table, "keys": len(keys), "keysInTable": len(keys_in_table),
                "scenes": scenes, "scenesFullyInTable": scenes_covered,
                "absentKeys": sorted(keys - keys_in_table, key=lambda k: tuple(map(int, k.split("/"))))}

    result = {"all": scope(None)}
    if groups:
        result["groups " + ",".join(map(str, sorted(groups)))] = scope(groups)
    return result


def stems(rows: list[dict]) -> dict[tuple[str, str], str]:
    """One export folder name per (bundle, prefab); a prefab name in two bundles is refused."""
    from export_prefab import safe_name
    result: dict[tuple[str, str], str] = {}
    for row in rows:
        result[(row["bundlePath"], row["prefab"])] = safe_name(row["prefab"])
    names = sorted(result.values())
    duplicates = {name for name in names if names.count(name) > 1}
    if duplicates:
        raise ValueError(f"Prefab names repeat across bundles: {sorted(duplicates)}")
    return result


def export_items(item_list: dict, *, groups: set[int], abdata: Path, bundle_sets: dict[str, list[str]],
                 output: Path, dry_run: bool = False, loader=None, exporter=None, auditor=None,
                 compressor=None) -> dict:
    """Converts the selected rows' prefabs into `output/<stem>/` and returns the report.

    `bundle_sets` maps a row's `bundlePath` to the bundles its prefab loads with
    (itself first, then dependencies), relative to `abdata`. `loader`, `exporter`
    and `auditor` default to export_prefab.py's `load_bundles` and `export_loaded`
    and test_export_prefab.py's `verify_export`, and `compressor` to the zstd CLI;
    tests pass synthetic ones. The survey (`dry_run`) audits too, in a temporary
    directory it removes, so it refuses exactly what the export refuses.
    """
    if loader is None or exporter is None:
        from export_prefab import export_loaded, load_bundles
        loader, exporter = loader or load_bundles, exporter or export_loaded
    if auditor is None:
        from test_export_prefab import verify_export as auditor
    rows = [row for row in item_list["items"] if row["group"] in groups]
    folder = stems(rows)
    wanted = sorted({(row["bundlePath"], row["prefab"]) for row in rows
                     if not (row["animated"] or row["childRoot"])})
    environments: dict[str, tuple] = {}
    hashes: dict[str, str] = {}
    outcomes: dict[tuple[str, str], dict] = {}
    if not dry_run and output.exists() and any(output.iterdir()):
        # Only a previous export is replaced, never a directory this tool did not write.
        if not (output / SOURCE_ARCHIVE).is_file():
            raise ValueError(f"{output} is not empty and holds no previous export")
        shutil.rmtree(output)
    work = Path(tempfile.mkdtemp(prefix="item-survey-")) if dry_run else output
    work.mkdir(parents=True, exist_ok=True)
    try:
        for bundle_path, prefab in wanted:
            stem = folder[(bundle_path, prefab)]
            if bundle_path not in bundle_sets:
                outcomes[(bundle_path, prefab)] = {"status": "notConverted",
                                                   "reason": f"Bundle {bundle_path} is not available here"}
                continue
            if bundle_path not in environments:
                environments[bundle_path] = loader([abdata / name for name in bundle_sets[bundle_path]])
            environment, sources = environments[bundle_path]
            staging = work / f".staging-{stem}"
            if staging.exists():
                shutil.rmtree(staging)
            try:
                provenance = exporter(environment, sources, prefab, staging, stem)
                audit = None if auditor is None else auditor(staging, hashes)
            except ValueError as error:
                shutil.rmtree(staging, ignore_errors=True)
                outcomes[(bundle_path, prefab)] = {"status": "notConverted", "reason": str(error)}
                continue
            final = work / stem
            if final.exists():
                shutil.rmtree(final)
            staging.rename(final)
            outcomes[(bundle_path, prefab)] = {"status": "converted", "folder": stem,
                                               "file": f"{stem}/{stem}.gltf", "meshes": provenance["meshes"],
                                               "materials": provenance["materials"],
                                               "triangles": provenance["triangles"],
                                               "auditedTriangles": None if audit is None else audit["verifiedTriangles"]}
        report_rows = []
        for row in rows:
            entry = {"group": row["group"], "category": row["category"], "no": row["no"],
                     "bundlePath": row["bundlePath"], "prefab": row["prefab"]}
            if row["animated"] or row["childRoot"]:
                entry.update(status="notConverted", reason=SEPARATE_MAPPING)
            else:
                entry.update(outcomes[(row["bundlePath"], row["prefab"])])
            report_rows.append(entry)
        if not dry_run:
            archive_source_dumps(output, sorted({o["folder"] for o in outcomes.values() if o["status"] == "converted"}),
                                 compressor or zstd)
            clone_duplicates(output)
    finally:
        if dry_run:
            shutil.rmtree(work, ignore_errors=True)
    return {"kind": "ikkoku.sourceStudioItemExport", "version": 1, "groups": sorted(groups),
            "dryRun": dry_run, "bundleSets": bundle_sets, "rows": report_rows,
            "manifest": None if dry_run else manifest(output)}


def zstd(data: bytes) -> bytes:
    return subprocess.run(["zstd", "-q", "-19", "-c"], input=data, capture_output=True, check=True).stdout


def archive_source_dumps(output: Path, folders: list[str], compressor) -> None:
    """Moves each export's `source.unity.json` (the audit's input, up to ~120 KB) into
    one deterministic zstd-compressed tar: sorted members, zero times and owners."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for folder in folders:
            dump = output / folder / "source.unity.json"
            data = dump.read_bytes()
            info = tarfile.TarInfo(f"{folder}/source.unity.json")
            info.size, info.mtime, info.mode = len(data), 0, 0o644
            archive.addfile(info, io.BytesIO(data))
    (output / SOURCE_ARCHIVE).write_bytes(compressor(buffer.getvalue()))
    for folder in folders:
        (output / folder / "source.unity.json").unlink()


def clone_duplicates(output: Path) -> int:
    """Rewrites byte-identical images across export folders as APFS clones of the
    first copy (`cp -c`), so they take their bytes once. Each glTF still finds its
    images in its own folder (its package root). Returns the files cloned."""
    if sys.platform != "darwin":
        return 0
    first: dict[str, Path] = {}
    cloned = 0
    for path in sorted(output.glob("*/*.png")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest not in first:
            first[digest] = path
            continue
        temporary = path.with_name(path.name + ".clone")
        # A volume without clones keeps the plain copy.
        if subprocess.run(["cp", "-c", str(first[digest]), str(temporary)], capture_output=True).returncode == 0:
            temporary.replace(path)
            cloned += 1
    return cloned


def manifest(output: Path) -> list[dict]:
    """SHA-256 of every generated file under `output`, by relative path."""
    return [{"path": path.relative_to(output).as_posix(), "bytes": path.stat().st_size,
             "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in sorted(output.rglob("*")) if path.is_file() and path.name not in RUN_FILES]


def build_catalog(item_list: dict, report: dict, *, bundle_hashes: list[dict]) -> dict:
    """`KoikatsuAssetCatalog` version 1 (`items` with relative files) plus the rows the
    export refused (`notConverted`). Rows outside the exported groups are absent:
    the runtime reports their keys as not in the catalog."""
    names = {key_text(row): row["name"] for row in item_list["items"]}
    items, refused, reasons = [], [], {}
    for row in report["rows"]:
        base = {"group": row["group"], "category": row["category"], "no": row["no"]}
        if row["status"] == "converted":
            items.append({**base, "name": names[key_text(row)], "file": row["file"]})
        else:
            refused.append({**base, "reason": row["reason"]})
            reasons[row["reason"]] = reasons.get(row["reason"], 0) + 1
    return {"version": 1, "kind": "ikkoku.sourceStudioItemCatalog", "groups": report["groups"],
            "sources": {"infoBundles": item_list["sources"], "assetBundles": bundle_hashes},
            "coverage": {"rows": len(report["rows"]), "converted": len(items), "notConverted": len(refused),
                         "prefabs": len({row["file"] for row in report["rows"] if row["status"] == "converted"}),
                         "reasons": [{"reason": reason, "rows": count} for reason, count in sorted(reasons.items())]},
            "items": items, "notConverted": refused}


def local_roots() -> list[Path]:
    """This checkout's .local, and the main checkout's when this is a linked worktree."""
    roots = [(REPO / ".local").resolve()]
    common = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True)
    if common.returncode == 0 and common.stdout.strip():
        roots.append((Path(common.stdout.strip()).parent / ".local").resolve())
    return roots


def local_output(parser: argparse.ArgumentParser, path: Path) -> Path:
    resolved = path.resolve()
    if not any(resolved.is_relative_to(root) for root in local_roots()):
        parser.error(f"Source-derived output must stay in the repository's ignored .local directory: {path}")
    return resolved


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--info-dir", type=Path, required=True, help="Directory of studio/info/*.unity3d bundles")
    listing.add_argument("--output", type=Path, required=True)
    covered = commands.add_parser("coverage")
    covered.add_argument("--item-list", type=Path, required=True)
    covered.add_argument("--usage", type=Path, required=True, help='{"scenes": [{"group/category/no": count}]}')
    covered.add_argument("--group", type=int, action="append", default=[])
    covered.add_argument("--output", type=Path, required=True)
    for name in ("export", "catalog"):
        command = commands.add_parser(name)
        command.add_argument("--item-list", type=Path, required=True)
        command.add_argument("--abdata", type=Path, required=True)
        command.add_argument("--bundle-set", action="append", required=True, metavar="BUNDLE=FILE[+DEPENDENCY...]",
                             help="A row bundle path and the abdata-relative bundles its prefab loads with")
        command.add_argument("--group", type=int, action="append", required=True)
        command.add_argument("--output", type=Path, required=True, help="Export directory (the catalog's directory)")
    commands.choices["export"].add_argument("--dry-run", action="store_true", help="Survey only: nothing is kept")
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parent))

    if args.command == "list":
        import catalog
        output = local_output(parser, args.output)
        result = item_list_from_table(catalog.item_table(sorted(args.info_dir.glob("*.unity3d"))))
        write_json(output, result)
        print(json.dumps({"output": str(output), "rows": len(result["items"]), "bundles": len(result["sources"])}))
        return
    item_list = json.loads(args.item_list.read_text())
    if args.command == "coverage":
        output = local_output(parser, args.output)
        result = coverage(item_list, json.loads(args.usage.read_text()), set(args.group))
        write_json(output, result)
        print(json.dumps({scope: {k: v for k, v in values.items() if k != "absentKeys"} for scope, values in result.items()}))
        return
    bundle_sets = {}
    for entry in args.bundle_set:
        bundle, _, files = entry.partition("=")
        bundle_sets[bundle] = files.split("+") if files else [bundle]
    output = local_output(parser, args.output)
    report_path = output / "export-report.json"
    if args.command == "export":
        report = export_items(item_list, groups=set(args.group), abdata=args.abdata, bundle_sets=bundle_sets,
                              output=output, dry_run=args.dry_run)
        target = output.parent / (output.name + "-survey.json") if args.dry_run else report_path
        write_json(target, report)
        statuses = {}
        for row in report["rows"]:
            statuses[row["status"]] = statuses.get(row["status"], 0) + 1
        print(json.dumps({"report": str(target), "rows": statuses}))
        return
    report = json.loads(report_path.read_text())
    if report["groups"] != sorted(set(args.group)) or report["bundleSets"] != bundle_sets:
        parser.error("The export report was made for other groups or bundle sets")
    hashes = [{"file": name, "sha256": hashlib.sha256((args.abdata / name).read_bytes()).hexdigest()}
              for name in sorted({name for files in bundle_sets.values() for name in files})]
    result = build_catalog(item_list, report, bundle_hashes=hashes)
    write_json(output / "catalog.json", result)
    print(json.dumps({"catalog": str(output / "catalog.json"), **{k: v for k, v in result["coverage"].items() if k != "reasons"}}))


if __name__ == "__main__":
    main()
