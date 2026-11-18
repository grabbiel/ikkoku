"""Synthetic tests of the generated item catalog (ST-T04): table order, coverage,
export orchestration, refusals and byte determinism. No game data is read."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from catalog import apply_tables
from item_catalog import (SEPARATE_MAPPING, SOURCE_ARCHIVE, archive_source_dumps, build_catalog, coverage,
                          export_items, item_list_from_table, stems)

HEADER = {"list": ["no", "group", "category", "name"]}


def row(no, group, category, name, bundle, prefab, *, animated=False, child_root=""):
    cells = [str(no), str(group), str(category), name, "manifest", bundle, prefab, child_root,
             "True" if animated else "False", "True", "False", "False", "False", "False", "False", "True"]
    return {"list": cells}


def table(name, rows):
    return {"m_Name": name, "list": [HEADER, *rows]}


def synthetic_table():
    """Two info bundles: the later one replaces key 0/0/2 and adds 1/0/1."""
    effective, observed, groups, categories = {}, [], {}, {}
    first = [("ItemGroup_00", 1, table("ItemGroup_00", [{"list": ["0", "Shapes"]}, {"list": ["1", "Props"]}])),
             ("ItemCategory_00_00", 2, table("ItemCategory_00_00", [{"list": ["0", "Basic"]}])),
             ("ItemList_00_00_00", 3, table("ItemList_00_00_00", [
                 row(1, 0, 0, "Shape one", "shapes/a", "shape_one"),
                 row(2, 0, 0, "Shape two", "shapes/a", "shape_two"),
                 row(3, 0, 0, "Turning shape", "shapes/a", "shape_turning", animated=True),
                 row(4, 0, 0, "Shape four", "shapes/b", "shape_four"),
                 row(5, 0, 0, "Bent shape", "shapes/a", "shape_bent"),
                 {"list": ["end", "", ""]},
                 row(9, 0, 0, "After the end", "shapes/a", "shape_never")]))]
    count = apply_tables(first, Path("/info/00.unity3d"), effective, observed, groups, categories)
    second = [("ItemList_01_00_00", 4, table("ItemList_01_00_00", [row(2, 0, 0, "Shape two again", "shapes/a", "shape_two_b")])),
              ("ItemList_01_01_00", 5, table("ItemList_01_01_00", [row(1, 1, 0, "A prop", "props/a", "prop_one")]))]
    count += apply_tables(second, Path("/info/01.unity3d"), effective, observed, groups, categories)
    sources = [{"path": "/info/00.unity3d", "bytes": 10, "sha256": "a" * 64},
               {"path": "/info/01.unity3d", "bytes": 20, "sha256": "b" * 64}]
    return {"effective": effective, "observed": observed, "groups": groups, "categories": categories,
            "sources": sources, "rowCount": count}


class FakeExports:
    """export_prefab.py's loader, exporter and audit, writing deterministic files."""

    def __init__(self):
        self.loads = []

    def loader(self, paths):
        self.loads.append([path.name for path in paths])
        return ("environment", [{"path": path.as_posix(), "sha256": "c" * 64} for path in paths])

    def exporter(self, environment, sources, prefab, output, stem):
        output.mkdir(parents=True)
        (output / f"{stem}.gltf").write_text(json.dumps({"prefab": prefab}) + "\n")
        (output / f"{stem}.bin").write_bytes(prefab.encode() * 3)
        (output / "0_shared.png").write_bytes(b"shared image")
        (output / "source.unity.json").write_text(json.dumps({"prefab": prefab}) + "\n")
        (output / "provenance.json").write_text(json.dumps({"sources": sources}) + "\n")
        if prefab == "shape_bent":
            raise ValueError("Converted triangle faces away from authored normals")
        return {"meshes": 1, "materials": 1, "triangles": 12}

    def auditor(self, directory, hashes):
        return {"verifiedTriangles": 12}


def identity(data):
    return data


class ItemCatalogTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.item_list = item_list_from_table(synthetic_table())
        self.sets = {"shapes/a": ["shapes/a", "materials/a"]}

    def tearDown(self):
        shutil.rmtree(self.directory)

    def export(self, name, **arguments):
        fakes = FakeExports()
        report = export_items(self.item_list, groups={0}, abdata=Path("/abdata"), bundle_sets=self.sets,
                              output=self.directory / name, loader=fakes.loader, exporter=fakes.exporter,
                              auditor=fakes.auditor, compressor=identity, **arguments)
        return report, fakes

    def test_later_rows_replace_earlier_ones_and_a_nonnumeric_id_ends_a_table(self):
        keys = [(row["group"], row["category"], row["no"]) for row in self.item_list["items"]]
        self.assertEqual(keys, [(0, 0, 1), (0, 0, 2), (0, 0, 3), (0, 0, 4), (0, 0, 5), (1, 0, 1)])
        replaced = self.item_list["items"][1]
        self.assertEqual((replaced["prefab"], replaced["evidence"]["infoBundle"]), ("shape_two_b", "01.unity3d"))
        self.assertEqual((replaced["groupName"], replaced["categoryName"]), ("Shapes", "Basic"))
        self.assertEqual(self.item_list["rowsExamined"], 7)
        self.assertEqual([source["file"] for source in self.item_list["sources"]], ["00.unity3d", "01.unity3d"])

    def test_coverage_counts_items_keys_and_fully_covered_scenes(self):
        usage = {"scenes": [{"0/0/1": 3, "0/0/2": 1}, {"0/0/1": 1, "0/7/9": 2}, {"5/1/1": 4}]}
        result = coverage(self.item_list, usage, {0})
        self.assertEqual({k: v for k, v in result["all"].items() if k != "absentKeys"},
                         {"items": 11, "itemsInTable": 5, "keys": 4, "keysInTable": 2, "scenes": 3, "scenesFullyInTable": 1})
        self.assertEqual(result["groups 0"]["absentKeys"], ["0/7/9"])
        self.assertEqual((result["groups 0"]["scenes"], result["groups 0"]["scenesFullyInTable"]), (2, 1))

    def test_rows_are_converted_or_refused_by_name(self):
        report, fakes = self.export("items")
        statuses = {(row["no"]): (row["status"], row.get("reason")) for row in report["rows"]}
        self.assertEqual(statuses, {
            1: ("converted", None), 2: ("converted", None),
            3: ("notConverted", SEPARATE_MAPPING),
            4: ("notConverted", "Bundle shapes/b is not available here"),
            5: ("notConverted", "Converted triangle faces away from authored normals")})
        self.assertEqual(fakes.loads, [["a", "a"]], "one load per bundle set")
        output = self.directory / "items"
        self.assertEqual(sorted(path.name for path in output.iterdir()), ["shape_one", "shape_two_b", SOURCE_ARCHIVE])
        self.assertFalse((output / "shape_one" / "source.unity.json").exists(), "source dumps are archived")
        archive = (output / SOURCE_ARCHIVE).read_bytes()
        self.assertIn(b"shape_one/source.unity.json", archive)
        self.assertIn(b"shape_two_b/source.unity.json", archive)

    def test_the_survey_refuses_what_the_export_refuses_and_keeps_nothing(self):
        survey, _ = self.export("survey", dry_run=True)
        export, _ = self.export("items")
        self.assertEqual([{k: v for k, v in row.items() if k != "auditedTriangles"} for row in survey["rows"]],
                         [{k: v for k, v in row.items() if k != "auditedTriangles"} for row in export["rows"]])
        self.assertFalse((self.directory / "survey").exists())
        self.assertIsNone(survey["manifest"])

    def test_two_runs_give_a_byte_identical_catalog_and_export_manifest(self):
        results = []
        for name in ("first", "second"):
            report, _ = self.export(name)
            catalog = build_catalog(self.item_list, report, bundle_hashes=[{"file": "shapes/a", "sha256": "d" * 64}])
            results.append((json.dumps(catalog, indent=1, ensure_ascii=False, sort_keys=True), report["manifest"]))
        self.assertEqual(results[0], results[1])
        self.assertEqual([entry["path"] for entry in results[0][1]], [
            "shape_one/0_shared.png", "shape_one/provenance.json", "shape_one/shape_one.bin", "shape_one/shape_one.gltf",
            "shape_two_b/0_shared.png", "shape_two_b/provenance.json", "shape_two_b/shape_two_b.bin",
            "shape_two_b/shape_two_b.gltf", SOURCE_ARCHIVE])

    def test_a_second_export_replaces_the_first_but_never_a_foreign_directory(self):
        self.export("items")
        report, _ = self.export("items")
        self.assertEqual(len([row for row in report["rows"] if row["status"] == "converted"]), 2)
        foreign = self.directory / "foreign"
        foreign.mkdir()
        (foreign / "keep.txt").write_text("not an export")
        with self.assertRaises(ValueError):
            self.export("foreign")
        self.assertTrue((foreign / "keep.txt").exists())

    def test_the_catalog_keeps_the_version_1_shape_and_lists_refusals(self):
        report, _ = self.export("items")
        catalog = build_catalog(self.item_list, report, bundle_hashes=[])
        self.assertEqual(catalog["version"], 1)
        self.assertEqual(catalog["items"], [
            {"group": 0, "category": 0, "no": 1, "name": "Shape one", "file": "shape_one/shape_one.gltf"},
            {"group": 0, "category": 0, "no": 2, "name": "Shape two again", "file": "shape_two_b/shape_two_b.gltf"}])
        self.assertEqual([(entry["no"], entry["reason"]) for entry in catalog["notConverted"]], [
            (3, SEPARATE_MAPPING), (4, "Bundle shapes/b is not available here"),
            (5, "Converted triangle faces away from authored normals")])
        self.assertEqual((catalog["coverage"]["converted"], catalog["coverage"]["notConverted"]), (2, 3))
        self.assertNotIn(1, [entry["group"] for entry in catalog["items"] + catalog["notConverted"]],
                         "rows outside the exported groups are absent")

    def test_prefab_names_repeated_across_bundles_are_refused(self):
        rows = [{"bundlePath": "a", "prefab": "same"}, {"bundlePath": "b", "prefab": "same"}]
        with self.assertRaises(ValueError):
            stems(rows)

    @unittest.skipUnless(shutil.which("zstd"), "zstd CLI not installed")
    def test_the_source_archive_is_deterministic_zstd(self):
        from item_catalog import zstd
        archives = []
        for name in ("one", "two"):
            folder = self.directory / name / "shape"
            folder.mkdir(parents=True)
            (folder / "source.unity.json").write_text('{"x": 1}\n')
            archive_source_dumps(self.directory / name, ["shape"], zstd)
            archives.append((self.directory / name / SOURCE_ARCHIVE).read_bytes())
        self.assertEqual(archives[0], archives[1])
        self.assertTrue(archives[0].startswith(b"\x28\xb5\x2f\xfd"))


if __name__ == "__main__":
    unittest.main()
