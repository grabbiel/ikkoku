#!/usr/bin/env python3
"""Synthetic incremental library/profile tests; no game files or UnityPy required."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import library
import zipmod


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.mods = self.root / "mods"; self.mods.mkdir()
        self.output = self.root / "library"

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, relative, guid, version="1", payload=b"payload"):
        path = self.mods / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        xml = f'<manifest schema-ver="1"><guid>{guid}</guid><name>Test</name><version>{version}</version></manifest>'.encode()
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as output:
            for name, value in [("manifest.xml", xml), ("notes.txt", payload)]:
                output.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), value)
        return path

    def scan(self, **kwargs):
        return library.scan(self.output, [self.mods], **kwargs)

    def test_add_change_remove_and_hashes_ignore_unchanged_size_and_mtime(self):
        b = self.archive("sub/b.ZIPMOD", "b", payload=b"AAAA")
        self.archive("a.zipmod", "a")
        first = self.scan()
        self.assertEqual([a["relativePath"] for a in first["library"]["archives"]], ["a.zipmod", "sub/b.ZIPMOD"])
        self.assertEqual(first["summary"]["imported"], 2)
        self.assertEqual(first["profile"]["mountOrder"], ["a", "b"])
        old_b = first["profile"]["mounts"][1]
        old_manifest = self.output / old_b["packageManifest"]
        old_bytes = old_manifest.read_bytes()
        before = b.stat()
        self.archive("sub/b.ZIPMOD", "b", payload=b"BBBB")
        os.utime(b, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(b.stat().st_size, before.st_size)
        self.archive("c.zipmod", "c")
        (self.mods / "a.zipmod").unlink()
        second = self.scan()
        self.assertEqual(second["summary"]["imported"], 2)
        self.assertEqual(second["profile"]["mountOrder"], ["b", "c"])
        new_b = second["profile"]["mounts"][0]
        self.assertNotEqual(old_b["archiveSHA256"], new_b["archiveSHA256"])
        self.assertNotEqual(old_b["packageManifest"], new_b["packageManifest"])
        self.assertEqual(old_manifest.read_bytes(), old_bytes)
        self.assertEqual(len(second["library"]["generations"]), 4)
        self.assertNotIn("a", [m["guid"] for m in second["profile"]["mounts"]])

    def test_cache_reuse_rechecks_bytes_and_tampering_cannot_silently_refresh(self):
        self.archive("a.zipmod", "a"); self.archive("b.zipmod", "b")
        first = self.scan()
        with mock.patch.object(zipmod, "import_archive", side_effect=AssertionError("Cache should be reused")):
            second = self.scan()
        self.assertEqual(second["summary"]["reused"], 2)
        self.assertEqual(first["library"], second["library"])
        manifest_path = self.output / first["profile"]["mounts"][0]["packageManifest"]
        package = json.loads(manifest_path.read_bytes())
        blob = manifest_path.parent / package["sourceManifest"]["path"]
        blob.write_bytes(b"tampered")
        with mock.patch.object(zipmod, "import_archive", side_effect=AssertionError("Invalid immutable cache is not overwritten")):
            third = self.scan()
        self.assertEqual(third["summary"]["invalid"], 1)
        self.assertEqual(third["profile"]["mountOrder"], ["b"])
        self.assertEqual(blob.read_bytes(), b"tampered")
        self.assertIn("hash changed", third["library"]["archives"][0]["diagnostics"][0]["message"])

    def test_tampered_manifest_and_missing_generation_are_invalid(self):
        self.archive("a.zipmod", "a")
        first = self.scan()
        path = self.output / first["profile"]["mounts"][0]["packageManifest"]
        original = path.read_bytes(); path.write_bytes(original + b" ")
        self.assertEqual(self.scan()["summary"]["invalid"], 1)
        path.unlink()
        self.assertEqual(self.scan()["summary"]["invalid"], 1)

    def test_duplicate_guids_need_explicit_hash_choice_and_never_guess_versions(self):
        one = self.archive("a.zipmod", "duplicate", version="1")
        two = self.archive("b.zipmod", "duplicate", version="99")
        self.archive("safe.zipmod", "safe")
        first = self.scan()
        one_sha, two_sha = zipmod.digest(one.read_bytes()), zipmod.digest(two.read_bytes())
        self.assertEqual(first["profile"]["mountOrder"], ["safe"])
        self.assertEqual(first["library"]["conflicts"], [{"guid": "duplicate", "archiveSHA256s": sorted([one_sha, two_sha])}])
        self.assertEqual(len(first["profile"]["unresolvedConflicts"]), 1)
        chosen = self.scan(choices={"duplicate": one_sha})
        self.assertEqual(chosen["profile"]["mountOrder"], ["safe", "duplicate"])
        self.assertEqual(chosen["profile"]["mounts"][1]["version"], "1")
        self.assertEqual(chosen["profile"]["unresolvedConflicts"], [])
        self.archive("a.zipmod", "duplicate", version="2")
        changed = self.scan()
        self.assertEqual(changed["profile"]["choices"]["duplicate"], one_sha)
        self.assertEqual(changed["profile"]["mountOrder"], ["safe"])
        self.assertIn("choice_unavailable", [d["code"] for d in changed["profile"]["diagnostics"]])
        cleared = self.scan(clear_choices=["duplicate"])
        self.assertEqual(cleared["profile"]["mountOrder"], ["safe"])
        two.unlink()
        self.assertEqual(self.scan()["profile"]["mountOrder"], ["safe", "duplicate"])

    def test_identical_archive_copies_have_one_identity_and_one_mount(self):
        source = self.archive("a.zipmod", "same")
        (self.mods / "b.zipmod").write_bytes(source.read_bytes())
        result = self.scan()
        self.assertEqual(result["summary"]["imported"], 1)
        self.assertEqual(result["summary"]["reused"], 1)
        self.assertEqual(result["library"]["conflicts"], [])
        self.assertEqual(result["profile"]["mountOrder"], ["same"])
        self.assertEqual(len(result["library"]["archives"]), 2)

    def test_conversion_settings_and_dependency_versions_create_distinct_generations(self):
        self.archive("a.zipmod", "a")
        raw = self.scan(textures=False)
        with mock.patch.object(library.importlib.metadata, "version", return_value="1.23.0"):
            textures = self.scan(textures=True)
        with mock.patch.object(library.importlib.metadata, "version", return_value="1.24.0"):
            newer = self.scan(textures=True)
        generations = [r["profile"]["mounts"][0]["generationID"] for r in (raw, textures, newer)]
        self.assertEqual(len(set(generations)), 3)
        again = self.scan(textures=False)
        self.assertEqual(again["summary"]["imported"], 0)
        self.assertEqual(again["profile"]["mounts"][0]["generationID"], generations[0])

    def test_invalid_archive_and_import_failure_leave_other_imports_ready_and_no_partial_package(self):
        self.archive("a.zipmod", "broken")
        self.archive("b.zipmod", "working")
        (self.mods / "bad.zipmod").write_bytes(b"not a zip")
        original = zipmod.import_archive
        def fail_after_writing(source, output, **kwargs):
            if b"broken" in source.read_bytes():
                output.mkdir(); (output / "partial").write_bytes(b"partial")
                raise OSError("simulated full disk")
            return original(source, output, **kwargs)
        result = self.scan(importer=fail_after_writing)
        self.assertEqual((result["summary"]["invalid"], result["profile"]["mountOrder"]), (2, ["working"]))
        self.assertEqual(len(result["library"]["generations"]), 1)
        self.assertEqual(list((self.output / ".staging").iterdir()), [])
        self.assertFalse(list(self.output.rglob("partial")))
        self.assertFalse(list(self.output.rglob(".zipmod-*")))

    def test_profile_order_persists_and_identical_rescans_are_byte_deterministic(self):
        self.archive("z.zipmod", "z"); self.archive("a.zipmod", "a")
        self.scan(order=["z", "a"])
        before = {name: (self.output / name).read_bytes() for name in ["library.json", "profiles/default.json"]}
        result = library.scan(self.output)
        for name, value in before.items():
            self.assertEqual((self.output / name).read_bytes(), value)
        self.assertEqual(result["profile"]["mountOrder"], ["z", "a"])
        self.archive("b.zipmod", "b")
        self.assertEqual(self.scan()["profile"]["mountOrder"], ["z", "a", "b"])
        with self.assertRaisesRegex(library.LibraryFailure, "every currently selectable"):
            self.scan(order=["a"])

    def test_discovery_does_not_follow_symlinks_and_outputs_cannot_escape(self):
        external = self.root / "outside"; external.mkdir()
        real = self.archive("a.zipmod", "a")
        (external / "outside.zipmod").write_bytes(real.read_bytes())
        (self.mods / "linked.zipmod").symlink_to(external / "outside.zipmod")
        (self.mods / "directory-link").symlink_to(external, target_is_directory=True)
        result = self.scan()
        self.assertEqual(result["summary"]["invalid"], 1)
        self.assertEqual(len(result["library"]["archives"]), 2)
        self.assertIn("symlink_skipped", [d["code"] for d in result["library"]["diagnostics"]])
        second = self.root / "second-library"; second.mkdir()
        (second / "generations").symlink_to(external, target_is_directory=True)
        result = library.scan(second, [self.mods])
        self.assertEqual(result["profile"]["mounts"], [])
        self.assertEqual(sorted(p.name for p in external.iterdir()), ["outside.zipmod"])
        with self.assertRaises(library.LibraryFailure):
            library.scan(self.output, [self.mods], profile="../escape")

    def test_unavailable_root_is_reported_without_reusing_removed_mounts(self):
        self.archive("a.zipmod", "a")
        self.scan()
        moved = self.root / "moved"; self.mods.rename(moved)
        result = self.scan()
        self.assertEqual(result["profile"]["mounts"], [])
        self.assertEqual(result["library"]["diagnostics"][0]["code"], "root_unavailable")

    def test_invalid_profile_edit_does_not_strand_successfully_imported_generations(self):
        self.archive("a.zipmod", "a")
        with self.assertRaises(library.LibraryFailure):
            self.scan(order=["unknown"])
        self.assertFalse((self.output / "profiles/default.json").exists())
        with mock.patch.object(zipmod, "import_archive", side_effect=AssertionError("Completed import must remain indexed")):
            repaired = self.scan(order=["a"])
        self.assertEqual(repaired["summary"]["reused"], 1)
        self.assertEqual(repaired["profile"]["mountOrder"], ["a"])

    def test_optional_texture_dependency_is_reported_without_losing_raw_data(self):
        self.archive("a.zipmod", "a")
        with mock.patch.object(library.importlib.metadata, "version", side_effect=library.importlib.metadata.PackageNotFoundError):
            result = self.scan(textures=True)
        self.assertEqual(result["profile"]["mountOrder"], ["a"])
        self.assertEqual(result["library"]["options"]["dependencies"], {"UnityPy": None})
        self.assertIn("dependency_missing", [d["code"] for d in result["library"]["diagnostics"]])

    def test_multiple_roots_have_stable_ids_and_order_independent_of_argument_order(self):
        self.archive("a.zipmod", "a")
        other = self.root / "other"; other.mkdir()
        source = self.archive("z.zipmod", "z")
        source.rename(other / "z.zipmod")
        first = library.scan(self.output, [other, self.mods])
        second = library.scan(self.output, [self.mods, other])
        self.assertEqual(first["library"], second["library"])
        self.assertEqual(first["profile"], second["profile"])
        self.assertEqual(len({r["id"] for r in first["library"]["roots"]}), 2)

    def test_cli_rescan_uses_saved_roots_and_imports_new_archives(self):
        self.archive("a.zipmod", "a")
        command = [sys.executable, str(Path(library.__file__)), "scan", "--library", str(self.output)]
        first = subprocess.run(command + ["--root", str(self.mods)], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(first.stdout)["imported"], 1)
        self.archive("b.zipmod", "b")
        second = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(second.stdout)["imported"], 1)
        self.assertEqual(json.loads(second.stdout)["mounted"], 2)


if __name__ == "__main__":
    unittest.main()
