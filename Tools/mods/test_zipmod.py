#!/usr/bin/env python3
"""Synthetic archive security and identity contracts; no game assets needed."""
import dataclasses
import hashlib
import io
import json
from pathlib import Path
import stat
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import warnings
import zipfile

import zipmod


MANIFEST = b'<manifest schema-ver="1"><guid> example.mod </guid><name>Example</name><version>2</version><game>Koikatsu</game><game>Studio</game><migrationInfo><info guidOld="old.mod" idOld="4" idNew="9" category="Eye" /></migrationInfo></manifest>'
CATALOG = b'122\r\n0\r\nAssets/list.bytes\r\nID,Name,MainAB,MainData\r\n4,"Name, with comma",chara/x.unity3d,asset_x\r\n'


class ZipmodTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.count = 0

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, entries=(), manifest=MANIFEST, compression=zipfile.ZIP_STORED):
        self.count += 1
        path = self.root / f"input{self.count}.zipmod"
        with warnings.catch_warnings(), zipfile.ZipFile(path, "w", compression=compression) as output:
            warnings.simplefilter("ignore", UserWarning)
            if manifest is not None:
                output.writestr("manifest.xml", manifest)
            for name, data in entries:
                output.writestr(name, data)
        return path

    def reject(self, path, **kwargs):
        output = self.root / "rejected"
        with self.assertRaises((zipmod.ImportFailure, zipfile.BadZipFile)):
            zipmod.import_archive(path, output, **kwargs)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob(".zipmod-*")))

    def test_metadata_raw_files_catalog_and_migrations_are_preserved(self):
        source = self.archive([("abdata/list/test.csv", CATALOG), ("notes.txt", b"source bytes")])
        output = self.root / "package"
        result = zipmod.import_archive(source, output)
        self.assertEqual((result["schemaVersion"], result["kind"]), (1, "ikkoku-mod-package"))
        self.assertEqual(result["converter"], {"id": "ikkoku.zipmod", "version": "1.1.0"})
        self.assertEqual(result["bundleRegistrationOrder"], [])
        self.assertEqual(result["source"], {"guid": "example.mod", "name": "Example", "version": "2",
                         "games": ["Koikatsu", "Studio"], "archiveSHA256": hashlib.sha256(source.read_bytes()).hexdigest()})
        self.assertEqual((output / result["sourceManifest"]["path"]).read_bytes(), MANIFEST)
        self.assertEqual(result["sourceManifest"]["migrations"][0]["attributes"]["guidOld"], "old.mod")
        catalog = result["catalogs"][0]
        self.assertEqual(catalog["preamble"], ["122", "0", "Assets/list.bytes"])
        self.assertEqual(catalog["rows"][0], ["4", "Name, with comma", "chara/x.unity3d", "asset_x"])
        self.assertEqual((output / catalog["path"]).read_bytes(), CATALOG)
        for entry in result["archiveEntries"]:
            self.assertEqual(hashlib.sha256((output / entry["path"]).read_bytes()).hexdigest(), entry["sha256"])
        self.assertEqual(json.loads((output / "manifest.json").read_text()), result)

    def test_same_archive_produces_byte_identical_packages(self):
        source = self.archive([("b.txt", b"B"), ("a.txt", b"A")])
        one, two = self.root / "one", self.root / "two"
        zipmod.import_archive(source, one)
        zipmod.import_archive(source, two)
        snapshot = lambda root: {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}
        self.assertEqual(snapshot(one), snapshot(two))

    def test_entry_order_does_not_change_file_index_or_asset_ids(self):
        a = zipmod.import_archive(self.archive([("b.txt", b"B"), ("a.txt", b"A")]), self.root / "a")
        b = zipmod.import_archive(self.archive([("a.txt", b"A"), ("b.txt", b"B")]), self.root / "b")
        self.assertEqual(a["archiveEntries"], b["archiveEntries"])
        first = zipmod.stable_id(a["source"]["guid"], "abdata/chara/x.unity3d", "Eye")
        self.assertEqual(first, zipmod.stable_id(b["source"]["guid"], "abdata/chara/x.unity3d", "Eye"))
        self.assertNotEqual(first, zipmod.stable_id(a["source"]["guid"], "abdata/chara/x.unity3d", "eye"))
        self.assertNotEqual(first, zipmod.stable_id("other.mod", "abdata/chara/x.unity3d", "Eye"))

    def test_bundle_registration_tracks_zip_order_without_changing_resource_ids(self):
        # Both original paths trim to the same source alias, chara/x.unity3d.
        # Its registration order is significant even though the file index is sorted.
        entries = [("other/chara/x.unity3d", b"second prefix"),
                   ("abdata/chara/x.unity3d", b"first prefix")]
        fake_unity = SimpleNamespace(load=lambda _: SimpleNamespace(objects=[self.texture_object("Eye", 17)]))
        with mock.patch.dict("sys.modules", {"UnityPy": fake_unity}), mock.patch.object(zipmod, "validate_unityfs", return_value={}):
            a = zipmod.import_archive(self.archive(entries), self.root / "a", textures=True)
            b = zipmod.import_archive(self.archive(list(reversed(entries))), self.root / "b", textures=True)
        self.assertEqual(a["bundleRegistrationOrder"], [name for name, _ in entries])
        self.assertEqual(b["bundleRegistrationOrder"], list(reversed(a["bundleRegistrationOrder"])))
        self.assertEqual(a["archiveEntries"], b["archiveEntries"])
        self.assertEqual(a["bundles"], b["bundles"])
        self.assertEqual(a["resources"], b["resources"])
        self.assertEqual(len(a["resources"]), 2)
        for resource in a["resources"]:
            self.assertEqual(resource["id"], zipmod.stable_id("example.mod", resource["bundlePath"], "Eye"))

    def test_source_bundle_discovery_uses_case_insensitive_suffix_and_any_root(self):
        entries = [("other/chara/eyes.UnItY3D", b"registered even without Unity magic"),
                   ("root.UNITY3D", b"also registered"), ("folder.UNITY3D/", b""),
                   ("abdata/chara/ignored.bundle", b"UnityFS\0payload"),
                   ("abdata/chara/ignored.assets", b"UnityRaw\0payload"),
                   ("abdata/chara/ignored.unity3d.bak", b"UnityWeb\0payload"),
                   ("no-extension", b"UnityFS\0payload"), ("notes.txt", b"preserved")]
        with mock.patch.object(zipmod, "extract_textures") as decoder:
            result = zipmod.import_archive(self.archive(entries), self.root / "out", textures=True)
        registered = [name for name, _ in entries[:2]]
        self.assertEqual(result["bundleRegistrationOrder"], registered)
        self.assertEqual([bundle["bundlePath"] for bundle in result["bundles"]], sorted(registered))
        self.assertEqual([call.args[1]["bundlePath"] for call in decoder.call_args_list], sorted(registered))
        unregistered = [entry for entry in result["archiveEntries"] if entry["kind"] == "unregisteredUnityBundle"]
        self.assertEqual({entry["sourcePath"] for entry in unregistered}, {name for name, _ in entries[3:7]})
        self.assertTrue(all(entry["status"] == "preserved" for entry in unregistered))
        self.assertEqual(sum(d["code"] == "bundle_not_registered" for d in result["diagnostics"]), 4)
        self.assertEqual(result["resources"], [])

    def test_directory_entries_preserve_original_paths(self):
        result = zipmod.import_archive(self.archive([("abdata/", b""), ("abdata/chara/", b"")]), self.root / "out")
        self.assertEqual(result["archiveEntries"][0], {"sourcePath": "abdata/", "kind": "directory", "status": "preserved"})

    def test_unsafe_paths_are_rejected_without_partial_output(self):
        for name in ("../escape", "/absolute", "C:/windows", "C:relative", "a/../../b", "a\\..\\b",
                     "//server/share", "a//b", "a/./b", "a./x", "a /x", "a:stream", "control\x01"):
            with self.subTest(name=name):
                self.reject(self.archive([(name, b"bad")]))

    def test_nul_path_rejected_before_zipinfo_truncation(self):
        info = zipfile.ZipInfo("safe")
        info.orig_filename = "safe\0hidden"
        with mock.patch.object(zipfile.ZipFile, "infolist", return_value=[info]):
            with zipfile.ZipFile(io.BytesIO(self.archive().read_bytes())) as archive:
                with self.assertRaises(zipmod.ImportFailure):
                    zipmod.checked_entries(archive, zipmod.Limits())

    def test_duplicate_casefold_unicode_and_ancestor_collisions_rejected(self):
        for names in (("a", "a"), ("A", "a"), ("é", "e\u0301"), ("a", "a/"), ("a", "a/b"), ("A/x", "a/y")):
            with self.subTest(names=names):
                self.reject(self.archive([(n, b"") for n in names]))

    def test_symlinks_and_devices_are_rejected(self):
        for mode in (stat.S_IFLNK, stat.S_IFCHR, stat.S_IFIFO):
            info = zipfile.ZipInfo("link")
            info.create_system = 3
            info.external_attr = (mode | 0o777) << 16
            self.reject(self.archive([(info, b"/outside")]))

    def test_inconsistent_directory_modes_and_payloads_rejected(self):
        info = zipfile.ZipInfo("not-a-directory")
        info.external_attr = (stat.S_IFDIR | 0o755) << 16
        self.reject(self.archive([(info, b"")]))
        self.reject(self.archive([("directory/", b"payload")]))

    def test_missing_wrong_duplicate_manifest_and_blank_guid_rejected(self):
        cases = [None, b'<manifest schema-ver="2"><guid>x</guid></manifest>', b'<wrong schema-ver="1"><guid>x</guid></wrong>',
                 b'<manifest schema-ver="1"><guid> </guid></manifest>', b'<manifest schema-ver="1"><guid>a</guid><guid>b</guid></manifest>']
        for xml in cases:
            self.reject(self.archive(manifest=xml))
        self.reject(self.archive([("Manifest.xml", MANIFEST)]))
        self.reject(self.archive([("sub/manifest.xml", MANIFEST)], manifest=None))

    def test_manifest_entities_are_rejected(self):
        self.reject(self.archive(manifest=b'<!DOCTYPE manifest [<!ENTITY e "expanded">]><manifest schema-ver="1"><guid>&e;</guid></manifest>'))

    def test_missing_optional_manifest_fields_use_empty_strings(self):
        result = zipmod.import_archive(self.archive(manifest=b'<manifest schema-ver="1"><guid>x</guid></manifest>'), self.root / "out")
        self.assertEqual((result["source"]["name"], result["source"]["version"], result["source"]["games"]), ("", "", []))

    def test_size_count_total_and_ratio_limits(self):
        source = self.archive([("data", b"x" * 1000)])
        for changes in ({"archive_bytes": 100}, {"file_bytes": 500}, {"total_bytes": 500}, {"entry_count": 1}, {"manifest_bytes": 10}, {"package_manifest_bytes": 10}):
            with self.subTest(changes=changes):
                self.reject(source, limits=dataclasses.replace(zipmod.Limits(), **changes))
        compressed = self.archive([("bomb", b"x" * 100000)], compression=zipfile.ZIP_DEFLATED)
        self.reject(compressed)

    def test_unsupported_compression_rejected(self):
        self.reject(self.archive([("a", b"test")], compression=zipfile.ZIP_BZIP2))

    def test_encrypted_flag_and_bad_crc_are_rejected(self):
        encrypted = self.archive([("data", b"payload")])
        content = bytearray(encrypted.read_bytes())
        central = content.index(b"PK\x01\x02")
        flags = struct.unpack_from("<H", content, central + 8)[0]
        struct.pack_into("<H", content, central + 8, flags | 1)
        encrypted.write_bytes(content)
        self.reject(encrypted)
        broken = self.archive([("data", b"unique payload")])
        content = bytearray(broken.read_bytes())
        content[content.index(b"unique payload")] ^= 1
        broken.write_bytes(content)
        self.reject(broken)

    def test_catalog_parse_failure_preserves_raw_bytes(self):
        result = zipmod.import_archive(self.archive([("abdata/list/bad.csv", b"not a catalog")]), self.root / "out")
        self.assertEqual(result["catalogs"][0]["parseStatus"], "unsupported")
        self.assertEqual((self.root / "out" / result["catalogs"][0]["path"]).read_bytes(), b"not a catalog")

    def test_cp932_catalog_names_are_decoded_losslessly(self):
        data = '122\n0\npath\nID,Name\n7,名前\n'.encode("cp932")
        parsed = zipmod.parse_catalog(data)
        self.assertEqual((parsed["encoding"], parsed["rows"]), ("cp932", [["7", "名前"]]))

    def test_managed_plugin_and_unknown_bundle_are_preserved_as_unsupported(self):
        source = self.archive([("plugin.dll", b"MZ-not-executed"), ("abdata/x.unity3d", b"not a bundle")])
        result = zipmod.import_archive(source, self.root / "out", textures=True)
        plugin = next(e for e in result["archiveEntries"] if e["sourcePath"] == "plugin.dll")
        self.assertEqual(plugin["status"], "unsupported")
        self.assertEqual(result["resources"], [])
        self.assertEqual(result["bundleRegistrationOrder"], ["abdata/x.unity3d"])
        self.assertIn("plugin_behavior_unsupported", {d["code"] for d in result["diagnostics"]})
        self.assertEqual(result["bundles"][0]["objectInspection"], "unsupported")

    def test_atomic_failure_cleans_staging_and_does_not_replace_output(self):
        source = self.archive()
        with mock.patch.object(zipmod, "write_blob", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                zipmod.import_archive(source, self.root / "out")
        self.assertFalse((self.root / "out").exists())
        self.assertFalse(list(self.root.glob(".zipmod-*")))
        (self.root / "out").mkdir()
        (self.root / "out" / "user-file").write_text("keep")
        with self.assertRaises(zipmod.ImportFailure):
            zipmod.import_archive(source, self.root / "out")
        self.assertEqual((self.root / "out" / "user-file").read_text(), "keep")

    def test_output_symlink_is_not_followed(self):
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(zipmod.ImportFailure):
            zipmod.import_archive(self.archive(), link)
        self.assertEqual(list(target.iterdir()), [])

    def test_unityfs_preflight_rejects_internal_expansion_before_parser(self):
        metadata = bytes(16) + struct.pack(">iIIHi", 1, 2**31, 1, 0, 0)
        prefix = b"UnityFS\0" + struct.pack(">I", 6) + b"5.x.x\0" + b"5.6.2f1\0"
        length = len(prefix) + 20 + len(metadata) + 1
        data = prefix + struct.pack(">QIII", length, len(metadata), len(metadata), 0x40) + metadata + b"x"
        with self.assertRaisesRegex(ValueError, "decoded payload"):
            zipmod.validate_unityfs(data, zipmod.Limits())

    def converted_fixture(self, objects):
        stage = self.root / "stage"
        stage.mkdir()
        package = {"source": {"guid": "example.mod"}, "resources": [], "diagnostics": []}
        bundle = {"bundlePath": "abdata/chara/example.unity3d", "sha256": "a" * 64, "objects": []}
        fake_unity = SimpleNamespace(load=lambda _: SimpleNamespace(objects=objects))
        with mock.patch.dict("sys.modules", {"UnityPy": fake_unity}), mock.patch.object(zipmod, "validate_unityfs", return_value={}):
            zipmod.extract_textures(b"mock serializer payload", bundle, package, stage, zipmod.Limits())
        return package, bundle

    @staticmethod
    def texture_object(name, path_id, width=1):
        # Tests importer identity/deduplication, independently of the decoder.
        texture = SimpleNamespace(m_Name=name, m_Width=width, m_Height=1,
                    image=SimpleNamespace(save=lambda target, **_: target.write(b"same encoded image")))
        return SimpleNamespace(path_id=path_id, assets_file=SimpleNamespace(name="CAB-test"),
                               type=SimpleNamespace(name="Texture2D"), read=lambda: texture)

    def test_equal_texture_payloads_share_path_but_keep_distinct_asset_ids(self):
        package, bundle = self.converted_fixture([self.texture_object("Eye", 17), self.texture_object("Eye_low", 20)])
        resources = package["resources"]
        self.assertEqual(len(resources), 2)
        self.assertEqual(resources[0]["path"], resources[1]["path"])
        self.assertNotEqual(resources[0]["id"], resources[1]["id"])
        self.assertEqual(resources[0]["bundlePath"], "abdata/chara/example.unity3d")
        self.assertEqual([o["status"] for o in bundle["objects"]], ["converted", "converted"])

    def test_duplicate_texture_names_are_unsupported_instead_of_order_selected(self):
        package, bundle = self.converted_fixture([self.texture_object("Eye", 17), self.texture_object("Eye", 20)])
        self.assertEqual(package["resources"], [])
        self.assertEqual([o["status"] for o in bundle["objects"]], ["unsupported", "unsupported"])
        self.assertIn("ambiguous_asset_identity", {d["code"] for d in package["diagnostics"]})

    def test_native_dimension_limit_is_enforced_before_image_decode(self):
        package, _ = self.converted_fixture([self.texture_object("Eye", 17, 16385)])
        self.assertEqual(package["resources"], [])
        self.assertIn("texture_unsupported", {d["code"] for d in package["diagnostics"]})


if __name__ == "__main__":
    unittest.main()
