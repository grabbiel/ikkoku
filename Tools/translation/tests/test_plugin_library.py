"""Synthetic plugin library tests (P-T02): no .NET, decompiler, game files or installed DLLs."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import native_adapters
import plugin
import plugin_library

H = "a" * 64


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_ir(directory: Path, guid: str, version: str = "1.0", *, salt: str = "", type_name: str = "Fixture.Component",
             processes=(), dependencies=(), incompatibilities=(), evidence: str = "ready", emitter: str = H) -> dict:
    """A package laid out as plugin.py publishes it (manifest, program, generated Swift, report)."""
    (directory / "program").mkdir(parents=True)
    source = sha(("source:" + salt).encode())
    program = {"schemaVersion": 1, "status": "ready", "mode": "component", "type": type_name, "source": {"sha256": source},
               "identity": {"sourceSHA256": source, "type": type_name, "symbols": ["M:Fixture.Update"], "pluginGUID": guid},
               "fields": [], "methods": [{"name": "Update", "symbol": "M:Fixture.Update", "static": False, "returnType": "Void",
                                          "parameters": [], "body": {"kind": "block", "children": []}, "lifecycle": "Update"}],
               "semanticSurfaceSHA256": H, "bridgeSHA256": H, "emitterSHA256": emitter}
    data = json.dumps(program, ensure_ascii=False).encode()
    (directory / "program/translation.json").write_bytes(data)
    (directory / "program/Translated.swift").write_text("// generated\n")
    manifest = {"schemaVersion": 1, "kind": plugin_library.TRANSLATED, "identity": {"guid": guid, "version": version, "name": guid},
                "processes": list(processes), "dependencies": list(dependencies), "incompatibilities": list(incompatibilities),
                "components": [{"type": type_name, "program": {"file": "program/translation.json", "sha256": sha(data)}}]}
    (directory / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (directory / "conversion.json").write_text(json.dumps({"status": "ready", "evidence": evidence}) + "\n")
    return manifest


MUTE = {"adapterID": "bepinex-mute-in-background-v1", "type": "BepInEx.MuteInBackground",
        "identity": {"guid": "BepInEx.MuteInBackground", "name": "Mute In Background", "version": "1.1"}, "processes": []}


def write_native(directory: Path, dll: bytes = b"MZ synthetic stand-in", row: dict = MUTE, config: bytes | None = None) -> dict:
    """A synthetic adapter package and the registry that verifies its stand-in assembly bytes."""
    directory.mkdir(parents=True)
    (directory / "Original.dll").write_bytes(dll)
    manifest = {"schemaVersion": 1, "kind": plugin_library.NATIVE, **row, "source": {"file": "Original.dll", "sha256": sha(dll)}}
    if config is not None:
        (directory / "Original.cfg").write_bytes(config)
        manifest["configuration"] = {"file": "Original.cfg", "sha256": sha(config)}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {sha(dll): row}


class PluginLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.packages = self.root / "packages"; self.packages.mkdir()
        self.library = self.root / "library"

    def tearDown(self):
        self.temporary.cleanup()

    def scan(self, **kwargs):
        return plugin_library.scan(self.library, [self.packages], **kwargs)

    def generation_bytes(self):
        return {path.name: path.read_bytes() for path in (self.library / "generations").glob("*.json")}

    def revision(self, document, guid):
        rows = [row for row in document["revisions"] if row["guid"] == guid]
        self.assertEqual(len(rows), 1, rows)
        return rows[0]

    def test_first_scan_records_exact_identities_and_package_digest(self):
        manifest = write_ir(self.packages / "author/plugin", "Creator.Mixed_é", "1.2.3", processes=["CharaStudio"],
                            dependencies=[{"guid": "Hard.ID", "minimumVersion": "1.2", "required": True},
                                          {"guid": "Soft.ID", "minimumVersion": None, "required": False}],
                            incompatibilities=["Other.ID"])
        result = self.scan()
        self.assertEqual(result["summary"]["generation"], 1)
        self.assertTrue(result["summary"]["published"])
        document = plugin_library.load(self.library)
        self.assertEqual(document, result["generation"])
        self.assertIsNone(document["previous"])
        row = self.revision(document, "Creator.Mixed_é")
        manifest_bytes = (self.packages / "author/plugin/manifest.json").read_bytes()
        self.assertEqual(row["manifestSHA256"], sha(manifest_bytes))
        self.assertEqual(row["manifest"], f"revisions/{sha(manifest_bytes)}/manifest.json")
        self.assertEqual((row["kind"], row["version"], row["name"], row["types"]),
                         (plugin_library.TRANSLATED, "1.2.3", "Creator.Mixed_é", ["Fixture.Component"]))
        self.assertEqual(row["dependencies"], manifest["dependencies"])
        self.assertEqual((row["processes"], row["incompatibilities"]), (["CharaStudio"], ["Other.ID"]))
        self.assertEqual(row["converter"], {"id": "ikkoku.translation", "irSchemaVersion": "1",
                                            "emitterSHA256": H, "bridgeSHA256": H, "semanticSurfaceSHA256": H})
        self.assertEqual(row["sources"], [{"rootID": document["roots"][0]["id"], "relativePath": "author/plugin"}])
        # Independent package digest: every file, sorted by UTF-8 path, compact sorted-key JSON.
        source = self.packages / "author/plugin"
        files = sorted((path.relative_to(source).as_posix() for path in source.rglob("*") if path.is_file()), key=str.encode)
        listing = [{"bytes": (source / name).stat().st_size, "path": name, "sha256": sha((source / name).read_bytes())} for name in files]
        self.assertEqual(row["packageSHA256"], sha(json.dumps(listing, separators=(",", ":"), ensure_ascii=False).encode()))
        copy = self.library / "revisions" / row["manifestSHA256"]
        self.assertEqual({p.relative_to(copy).as_posix() for p in copy.rglob("*") if p.is_file()}, set(files))
        self.assertEqual((copy / "manifest.json").read_bytes(), manifest_bytes)
        pointer = json.loads((self.library / "library.json").read_text())
        # The documented schema that SourcePluginLibraryIndex decodes.
        self.assertEqual(set(pointer), {"schemaVersion", "kind", "scanner", "roots", "current", "generations"})
        self.assertEqual(set(document), {"schemaVersion", "kind", "number", "previous", "scanner", "roots", "revisions",
                                         "conflicts", "packages", "diagnostics"})
        self.assertEqual(set(row), {"kind", "guid", "version", "name", "manifest", "manifestSHA256", "packageSHA256", "processes",
                                    "dependencies", "incompatibilities", "types", "converter", "sources"})
        self.assertEqual(set(document["packages"][0]), {"rootID", "relativePath", "status", "diagnostics", "manifestSHA256",
                                                        "packageSHA256", "kind", "guid", "version"})
        self.assertEqual((pointer["kind"], pointer["current"]), ("ikkoku-plugin-library", 1))
        self.assertEqual(pointer["generations"], [{"number": 1, "index": "generations/000001.json",
                                                   "indexSHA256": sha((self.library / "generations/000001.json").read_bytes())}])
        self.assertEqual(document["diagnostics"][0]["code"], "dependency_missing")  # Hard.ID absent; Soft.ID is optional.
        self.assertEqual(len(document["diagnostics"]), 1)

    def test_unchanged_rescan_reuses_generation_and_changed_source_publishes_next(self):
        write_ir(self.packages / "a", "A", salt="one")
        write_ir(self.packages / "b", "B")
        first = self.scan()
        old_generation = self.generation_bytes()
        old_a = self.revision(first["generation"], "A")
        old_copy = self.library / "revisions" / old_a["manifestSHA256"]
        old_files = {p: p.read_bytes() for p in old_copy.rglob("*") if p.is_file()}
        again = self.scan()
        self.assertFalse(again["summary"]["published"])
        self.assertEqual((again["summary"]["generation"], again["summary"]["reused"], again["summary"]["imported"]), (1, 2, 0))
        self.assertEqual(self.generation_bytes(), old_generation)
        # Changed source at the same path: same GUID/version, new program and manifest hashes.
        shutil.rmtree(self.packages / "a")
        write_ir(self.packages / "a", "A", salt="two")
        second = self.scan()
        self.assertEqual((second["summary"]["generation"], second["summary"]["imported"]), (2, 1))
        new_a = self.revision(second["generation"], "A")
        self.assertEqual(new_a["version"], old_a["version"])
        self.assertNotEqual(new_a["manifestSHA256"], old_a["manifestSHA256"])
        self.assertEqual(second["generation"]["previous"], {"number": 1, "indexSHA256": sha(old_generation["000001.json"])})
        # Generation 1 and its revision bytes are untouched and still readable.
        self.assertEqual(self.generation_bytes()["000001.json"], old_generation["000001.json"])
        self.assertEqual({p: p.read_bytes() for p in old_copy.rglob("*") if p.is_file()}, old_files)
        self.assertEqual(self.revision(plugin_library.load(self.library, 1), "A")["manifestSHA256"], old_a["manifestSHA256"])
        self.assertEqual(self.revision(plugin_library.load(self.library), "A")["manifestSHA256"], new_a["manifestSHA256"])
        self.assertEqual(self.revision(second["generation"], "B"), self.revision(first["generation"], "B"))
        # A later rescan without roots reuses the saved roots.
        self.assertFalse(plugin_library.scan(self.library)["summary"]["published"])

    def test_duplicate_guid_revisions_are_conflicts_and_unicode_guids_stay_distinct(self):
        write_ir(self.packages / "v1", "Shared.GUID", "1.0")
        write_ir(self.packages / "v2", "Shared.GUID", "1.1")
        write_ir(self.packages / "same-version", "Shared.GUID", "1.1", salt="other")
        write_ir(self.packages / "composed", "Creator.é")
        write_ir(self.packages / "decomposed", "Creator.é")
        document = self.scan()["generation"]
        shared = sorted(row["manifestSHA256"] for row in document["revisions"] if row["guid"] == "Shared.GUID")
        self.assertEqual(len(shared), 3)
        self.assertEqual(document["conflicts"], [{"guid": "Shared.GUID", "manifestSHA256s": shared}])
        self.assertEqual(len([row for row in document["revisions"] if row["guid"].startswith("Creator.")]), 2)

    def test_identical_copies_share_one_revision_and_reused_manifest_with_other_files_is_rejected(self):
        write_ir(self.packages / "one", "A")
        write_ir(self.packages / "two", "A")
        write_ir(self.packages / "three", "A", evidence="different conversion report")
        result = self.scan()
        document = result["generation"]
        row = self.revision(document, "A")
        self.assertEqual([source["relativePath"] for source in row["sources"]], ["one", "two"])
        self.assertEqual(document["conflicts"], [])
        statuses = {p["relativePath"]: (p["status"], [d["code"] for d in p["diagnostics"]]) for p in document["packages"]}
        self.assertEqual(statuses["three"], ("invalid", ["manifest_reused"]))
        self.assertEqual(statuses["one"], ("ready", []))

    def test_tampered_or_missing_revisions_are_never_overwritten_or_recreated(self):
        write_ir(self.packages / "a", "A")
        write_ir(self.packages / "b", "B")
        first = self.scan()
        copy = self.library / "revisions" / self.revision(first["generation"], "A")["manifestSHA256"]
        (copy / "program/Translated.swift").write_text("// tampered\n")
        removed = self.library / "revisions" / self.revision(first["generation"], "B")["manifestSHA256"]
        shutil.rmtree(removed)
        second = self.scan()
        self.assertEqual(second["summary"]["generation"], 2)
        self.assertEqual(second["generation"]["revisions"], [])
        codes = {p["relativePath"]: p["diagnostics"][0]["code"] for p in second["generation"]["packages"]}
        self.assertEqual(codes, {"a": "revision_changed", "b": "revision_missing"})
        self.assertEqual((copy / "program/Translated.swift").read_text(), "// tampered\n")
        self.assertFalse(removed.exists())
        # Generation 1 is not rewritten even though its revisions are now damaged.
        self.assertEqual(len(plugin_library.load(self.library, 1)["revisions"]), 2)

    def test_damaged_published_generation_blocks_extension(self):
        write_ir(self.packages / "a", "A")
        self.scan()
        path = self.library / "generations/000001.json"
        path.write_bytes(path.read_bytes().replace(b'"A"', b'"Z"'))
        with self.assertRaisesRegex(plugin_library.LibraryFailure, "generation 1 changed"):
            self.scan()
        with self.assertRaises(plugin_library.LibraryFailure):
            plugin_library.load(self.library)

    def test_interrupted_publication_is_not_presented_and_completes_on_rescan(self):
        write_ir(self.packages / "a", "A")
        self.scan()
        pointer = (self.library / "library.json").read_bytes()
        write_ir(self.packages / "b", "B")
        with mock.patch.object(plugin_library, "atomic_json", side_effect=OSError("power loss before commit")):
            with self.assertRaises(OSError):
                self.scan()
        # The new generation file and revision exist, but readers still see generation 1.
        self.assertTrue((self.library / "generations/000002.json").exists())
        self.assertEqual((self.library / "library.json").read_bytes(), pointer)
        self.assertEqual([row["guid"] for row in plugin_library.load(self.library)["revisions"]], ["A"])
        with self.assertRaises(plugin_library.LibraryFailure):
            plugin_library.load(self.library, 2)
        result = self.scan()
        self.assertEqual(result["summary"]["generation"], 2)
        self.assertEqual({d["code"] for d in result["diagnostics"]}, {"revision_adopted", "generation_adopted"})
        self.assertEqual([row["guid"] for row in plugin_library.load(self.library)["revisions"]], ["A", "B"])
        self.assertFalse(list((self.library / ".staging").iterdir()))

    def test_interrupted_staging_cleans_up_and_differing_orphan_generation_is_skipped(self):
        write_ir(self.packages / "a", "A")
        write_ir(self.packages / "b", "B")
        original = plugin_library.inspect_package
        calls = []
        def interrupt(*args):
            calls.append(1)
            if len(calls) == 2:
                raise KeyboardInterrupt
            return original(*args)
        with mock.patch.object(plugin_library, "inspect_package", side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.scan()
        self.assertFalse((self.library / "library.json").exists())
        self.assertFalse(list((self.library / ".staging").iterdir()))
        with self.assertRaises(plugin_library.LibraryFailure):
            plugin_library.load(self.library)
        orphan = self.library / "generations/000001.json"
        orphan.parent.mkdir()
        orphan.write_bytes(b'{"partial": true}')
        result = self.scan()
        self.assertEqual(result["summary"]["generation"], 2)
        self.assertEqual({d["code"] for d in result["diagnostics"]}, {"revision_adopted", "generation_orphaned"})
        self.assertEqual(orphan.read_bytes(), b'{"partial": true}')
        pointer = json.loads((self.library / "library.json").read_text())
        self.assertEqual([record["number"] for record in pointer["generations"]], [2])

    def test_standalone_versions_and_manifest_shapes_are_validated(self):
        for name, version in [("dash", "1.0-beta"), ("one", "1"), ("five", "1.2.3.4.5"), ("space", " 1.0"),
                              ("sign", "+1.0"), ("overflow", "2147483648.0"), ("fullwidth", "１.0"), ("empty-part", "1..2")]:
            write_ir(self.packages / name, "Version." + name, version)
        write_ir(self.packages / "min", "Version.min", dependencies=[{"guid": "X", "minimumVersion": "v2", "required": False}])
        for name, version in [("leading-zero", "01.2"), ("four", "1.2.3.4"), ("largest", "2147483647.0")]:
            write_ir(self.packages / name, "Version." + name, version)
        broken = self.packages / "unknown-field"
        manifest = write_ir(broken, "Unknown.Field")
        manifest["entryPoint"] = "Arbitrary"
        (broken / "manifest.json").write_text(json.dumps(manifest))
        duplicate = self.packages / "duplicate-key"
        write_ir(duplicate, "Duplicate.Key")
        text = (duplicate / "manifest.json").read_text()
        (duplicate / "manifest.json").write_text(text.replace('"kind"', '"kind": "other", "kind"', 1))
        document = self.scan()["generation"]
        statuses = {p["relativePath"]: (p["status"], [d["code"] for d in p["diagnostics"]]) for p in document["packages"]}
        for name in ("dash", "one", "five", "space", "sign", "overflow", "fullwidth", "empty-part", "min"):
            self.assertEqual(statuses[name], ("invalid", ["version_invalid"]), name)
        for name in ("leading-zero", "four", "largest"):
            self.assertEqual(statuses[name][0], "ready", name)
        self.assertEqual(statuses["unknown-field"], ("invalid", ["manifest_unsupported"]))
        self.assertEqual(statuses["duplicate-key"], ("invalid", ["manifest_invalid"]))
        self.assertTrue(plugin_library.version_at_least("1.0.0", "1.0"))
        self.assertFalse(plugin_library.version_at_least("1.0", "1.0.0"))
        self.assertTrue(plugin_library.version_at_least("1.10", "1.9"))
        self.assertTrue(plugin_library.version_at_least("01.2", "1.2"))

    def test_program_identity_and_converter_are_checked_against_the_manifest(self):
        changed = self.packages / "changed"
        write_ir(changed, "Changed")
        (changed / "program/translation.json").write_bytes((changed / "program/translation.json").read_bytes() + b" ")
        other = self.packages / "other-guid"
        manifest = write_ir(other, "Declared")
        program = json.loads((other / "program/translation.json").read_text())
        program["identity"]["pluginGUID"] = "Different"
        data = json.dumps(program).encode()
        (other / "program/translation.json").write_bytes(data)
        manifest["components"][0]["program"]["sha256"] = sha(data)
        (other / "manifest.json").write_text(json.dumps(manifest))
        escaping = self.packages / "escaping"
        manifest = write_ir(escaping, "Escaping")
        manifest["components"][0]["program"]["file"] = "../other-guid/program/translation.json"
        (escaping / "manifest.json").write_text(json.dumps(manifest))
        document = self.scan()["generation"]
        codes = {p["relativePath"]: p["diagnostics"][0]["code"] for p in document["packages"]}
        self.assertEqual(codes, {"changed": "program_changed", "other-guid": "program_invalid", "escaping": "manifest_invalid"})

    def test_native_adapters_require_registered_assembly_bytes_and_share_the_graph_report(self):
        registry = write_native(self.packages / "mute", config=b"[Config]\nMute In Background = false\n")
        write_ir(self.packages / "consumer", "Consumer", dependencies=[{"guid": "BepInEx.MuteInBackground", "minimumVersion": "1.1", "required": True}])
        write_ir(self.packages / "newer", "Newer", dependencies=[{"guid": "BepInEx.MuteInBackground", "minimumVersion": "1.2", "required": True}])
        write_native(self.packages / "unregistered", dll=b"MZ other bytes")
        accessory = {**MUTE, "adapterID": "kk-studio-accessory-names-v1", "identity": {**MUTE["identity"], "guid": "Accessory"}}
        registry.update(write_native(self.packages / "config-not-allowed", dll=b"MZ accessory", row=accessory, config=b"x"))
        changed = self.packages / "changed-dll"
        registry.update(write_native(changed, dll=b"MZ changed"))
        (changed / "Original.dll").write_bytes(b"MZ changed!")
        document = self.scan(registry=registry)["generation"]
        row = self.revision(document, "BepInEx.MuteInBackground")
        self.assertEqual((row["kind"], row["version"], row["types"], row["dependencies"]),
                         (plugin_library.NATIVE, "1.1", ["BepInEx.MuteInBackground"], []))
        self.assertEqual(row["converter"], {"id": "ikkoku.native-adapter", "adapterID": "bepinex-mute-in-background-v1",
                                            "sourceSHA256": sha(b"MZ synthetic stand-in")})
        codes = {p["relativePath"]: [d["code"] for d in p["diagnostics"]] for p in document["packages"] if p["status"] != "ready"}
        self.assertEqual(codes, {"unregistered": ["adapter_unverified"], "config-not-allowed": ["configuration_unsupported"],
                                 "changed-dll": ["source_changed"]})
        self.assertEqual([(d["code"], d["message"].split(" ")[0]) for d in document["diagnostics"]], [("dependency_version", "Newer")])
        # Without the stand-in registry, the default exact-hash registry rejects the bytes.
        library = self.root / "default-registry"
        result = plugin_library.scan(library, [self.packages / "mute"])
        self.assertEqual(result["generation"]["packages"][0]["diagnostics"][0]["code"], "adapter_unverified")

    def test_plugin_py_native_route_output_is_indexed_without_running_a_decompiler(self):
        evidence = ROOT / ".local/reverse/plugin-execution"
        evidence.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="plugin-library-", dir=evidence) as temporary:
            work = Path(temporary)
            dll, config = work / "BepInEx.MuteInBackground.dll", work / "Mute.cfg"
            dll.write_bytes(b"MZ stand-in for the registered assembly")
            config.write_bytes(b"[Config]\n")
            registry = {sha(dll.read_bytes()): MUTE}
            with mock.patch.dict(native_adapters.REGISTRY, registry, clear=True):
                report = plugin.package(dll, MUTE["type"], work / "packages/mute", config=config, tool=work / "must-not-run")
                self.assertEqual(report["execution"], "verified-native-adapter")
                result = plugin_library.scan(work / "library", [work / "packages"])
            row = self.revision(result["generation"], "BepInEx.MuteInBackground")
            self.assertEqual(row["manifestSHA256"], sha((work / "packages/mute/manifest.json").read_bytes()))
            self.assertTrue((work / "library" / "revisions" / row["manifestSHA256"] / "Original.cfg").is_file())

    def test_discovery_triage_reports_rejections_and_skips_staging_and_symlinks(self):
        rejected = self.packages / "rejected"; rejected.mkdir()
        (rejected / "conversion.json").write_text(json.dumps({"status": "rejected", "type": "Bad.Component",
            "identity": {"guid": "Bad.GUID", "version": "1.0", "name": None},
            "diagnostics": [{"code": "UNSUPPORTED", "message": "while loops are unsupported", "line": 3, "column": 5}]}))
        write_ir(self.packages / ".plugin-stage-abc123", "Incomplete")
        write_ir(self.root / "outside", "Outside")
        (self.packages / "linked").symlink_to(self.root / "outside", target_is_directory=True)
        linked_file = self.packages / "linked-file"
        write_ir(linked_file, "LinkedFile")
        (linked_file / "conversion.json").unlink()
        (linked_file / "conversion.json").symlink_to(self.root / "outside/conversion.json")
        document = self.scan()["generation"]
        self.assertEqual(document["revisions"], [])
        packages = {p["relativePath"]: p for p in document["packages"]}
        self.assertEqual(set(packages), {"rejected", "linked-file"})
        self.assertEqual(packages["rejected"]["status"], "rejected")
        self.assertEqual(packages["rejected"]["identity"], {"guid": "Bad.GUID", "version": "1.0"})
        self.assertEqual(packages["rejected"]["diagnostics"][0]["code"], "source_UNSUPPORTED")
        self.assertIn("line 3, column 5", packages["rejected"]["diagnostics"][0]["message"])
        self.assertEqual(packages["linked-file"]["diagnostics"][0]["code"], "package_symlink")
        self.assertEqual(sorted(d["code"] for d in document["diagnostics"]), ["staging_skipped", "symlink_skipped"])

    def test_library_location_roots_and_lock_are_guarded(self):
        with self.assertRaisesRegex(plugin_library.LibraryFailure, ".local"):
            plugin_library.scan(ROOT / "Tools/translation/not-a-library", [self.packages])
        self.assertFalse((ROOT / "Tools/translation/not-a-library").exists())
        with self.assertRaises(plugin_library.LibraryFailure):
            plugin_library.scan(self.library, [self.library / "inside"])
        with self.assertRaises(plugin_library.LibraryFailure):
            plugin_library.scan(self.library)
        write_ir(self.packages / "a", "A")
        with plugin_library.locked(self.library.resolve()):
            with self.assertRaisesRegex(plugin_library.LibraryFailure, "Another scan"):
                self.scan()

    def test_command_line_scan_and_show(self):
        write_ir(self.packages / "a", "A")
        command = [sys.executable, str(HERE / "plugin_library.py")]
        scanned = subprocess.run(command + ["scan", "--library", str(self.library), "--root", str(self.packages)],
                                 capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(scanned.stdout)["generation"], 1)
        shown = subprocess.run(command + ["show", "--library", str(self.library)], capture_output=True, text=True, check=True)
        self.assertEqual([row["guid"] for row in json.loads(shown.stdout)["revisions"]], ["A"])
        failed = subprocess.run(command + ["show", "--library", str(self.library), "--generation", "7"], capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("generation 7 is not published", failed.stderr)


if __name__ == "__main__":
    unittest.main()
