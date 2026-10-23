"""Unit tests for the release-bundle inspector (T-T02).

Stdlib only. Every bundle here is synthetic: a directory tree shaped like
Ikkoku.app with fake Mach-O, metallib and asset files. Run from the
repository root with:
    python3 -m unittest discover -s Tools/verification -p 'test_*.py'
"""
import copy
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib
from contextlib import redirect_stderr, redirect_stdout

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))

_spec = importlib.util.spec_from_file_location(
    "ikkoku_inspect_app_bundle", os.path.join(_HERE, "inspect_app_bundle.py"))
iab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(iab)

RULES = iab.load_rules(iab.DEFAULT_RULES)
CPU_ARM64 = 0x0100000C
CPU_X86_64 = 0x01000007


def thin_macho(cputype, subtype=0, payload=b""):
    """A little-endian 64-bit Mach-O executable header plus `payload`."""
    return b"\xcf\xfa\xed\xfe" + struct.pack("<iiI", cputype, subtype, 2) + b"\0" * 64 + payload


def fat_macho(cputypes, wide=False):
    magic = iab.FAT_MAGIC_64 if wide else iab.FAT_MAGIC
    data = magic + struct.pack(">I", len(cputypes))
    for cputype in cputypes:
        data += struct.pack(">ii", cputype, 0)
        data += struct.pack(">QQII", 4096, 64, 12, 0) if wide else struct.pack(">III", 4096, 64, 12)
    return data


def png(chunks=(), trailing=b""):
    """A structurally valid PNG with extra chunks before IEND."""
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    data = iab.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
    for kind, payload in chunks:
        data += chunk(kind, payload)
    data += chunk(b"IDAT", zlib.compress(b"\0\0\0\0\0")) + chunk(b"IEND", b"")
    return data + trailing


def glb(document):
    body = json.dumps(document).encode()
    body += b" " * (-len(body) % 4)
    return b"glTF" + struct.pack("<II", 2, 20 + len(body)) + struct.pack("<II", len(body), iab.GLB_JSON_CHUNK) + body


CATALOG = {
    "version": 1,
    "bodies": [{"id": "body_f", "file": "Characters/body_f.glb",
                "regionsFile": "Characters/body_f.regions.bin",
                "textures": {"skinBase": "skin_f_base.png"}}],
    "clothes": [{"id": "top", "file": "Clothes/top.glb", "colorMask": "Clothes/top_cm.png"}],
    "textures": {"iris": ["eye_iris_0.png"], "tinted": ["skin_*_base (skin tint)"]},
    "notes": ["Characters/notes_only.png is free text"],
}


class Fixture:
    """A synthetic checkout (tracked Assets/) and the bundle Xcode would build from it."""

    def __init__(self, root):
        self.root = root
        self.checkout = os.path.join(root, "checkout")
        self.app = os.path.join(root, "build", "Ikkoku.app")
        self.assets = {
            "catalog.json": json.dumps(CATALOG).encode(),
            "Characters/body_f.glb": glb({"asset": {"version": "2.0"}}),
            "Clothes/top.glb": glb({"asset": {"version": "2.0"}}),
            "Clothes/top_cm.png": png(),
            "Textures/skin_f_base.png": png(),
            "Textures/eye_iris_0.png": png([(b"tEXt", b"Software\0generator")]),
            "Thumbs/cloth_top.png": png(),
            "fixtures/rig_fixture.gltf": b"{}",
        }
        for rel, data in self.assets.items():
            self.write(os.path.join(self.checkout, "Assets", rel), data)
        self.tracked = sorted(self.assets)
        for rel, data in self.assets.items():
            if rel not in RULES["assets"]["excluded"]:
                self.bundle(iab.asset_destination(rel, RULES), data)
        self.info = {"CFBundleExecutable": "Ikkoku", "CFBundleIdentifier": "com.grabbiel.IkkokuCreator",
                     "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.6"}
        self.write_info()
        self.bundle("Contents/PkgInfo", b"APPL????")
        self.bundle("Contents/MacOS/Ikkoku", thin_macho(CPU_ARM64))
        self.bundle("Contents/Resources/IkkokuShaders.metallib", b"MTLB" + b"\0" * 60)
        self.bundle("Contents/Resources/Assets.car", b"BOMStore" + b"\0" * 60)
        self.bundle("Contents/Resources/AppIcon.icns", b"icns\0\0\0\x08")

    @staticmethod
    def write(path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)

    def bundle(self, rel, data):
        self.write(os.path.join(self.app, rel), data)

    def remove(self, rel):
        os.unlink(os.path.join(self.app, rel))

    def write_info(self, fmt=plistlib.FMT_BINARY):
        with open(os.path.join(self.app, "Contents/Info.plist"), "wb") as handle:
            plistlib.dump(self.info, handle, fmt=fmt)

    def inspect(self, rules=RULES, tracked="default"):
        return iab.inspect(self.app, rules, self.checkout, self.tracked if tracked == "default" else tracked)


class InspectorTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.mkdtemp(prefix="ikkoku-bundle-test-")
        self.addCleanup(shutil.rmtree, self.temp)
        self.fixture = Fixture(self.temp)

    def findings(self, report, rule=None, severity="error"):
        return [f for f in report["findings"] if f["severity"] == severity and (rule is None or f["rule"] == rule)]

    def assertFinding(self, report, rule, path=None, severity="error"):
        found = [f for f in self.findings(report, rule, severity) if path is None or f["path"] == path]
        self.assertTrue(found, "no %s %s finding%s in %s" % (
            severity, rule, " for " + path if path else "", json.dumps(report["findings"], indent=1)))
        return found


class CleanBundleTests(InspectorTestCase):
    def test_conforming_bundle_passes(self):
        report = self.fixture.inspect()
        self.assertEqual(report["findings"], [])
        self.assertTrue(report["passed"])
        self.assertEqual(report["executable"]["architectures"], ["arm64"])
        self.assertEqual(report["summary"]["byClass"], {"build-product": 6, "tracked-asset": 7})
        self.assertEqual(report["infoPlist"]["LSMinimumSystemVersion"], "14.6")
        self.assertTrue(all(item["present"] for item in report["required"]))

    def test_catalog_references_resolve_against_the_assets_root(self):
        report = self.fixture.inspect()
        # body glb, skin texture, clothes glb + mask, iris; regionsFile, notes
        # and the wildcard description are not references.
        self.assertEqual(report["catalog"]["references"], 5)
        self.assertEqual(report["catalog"]["missing"], [])
        self.assertEqual(report["catalog"]["version"], 1)

    def test_tree_hash_is_stable_and_content_sensitive(self):
        first = self.fixture.inspect()["bundle"]["treeSha256"]
        self.assertEqual(first, self.fixture.inspect()["bundle"]["treeSha256"])
        self.fixture.bundle("Contents/Resources/Thumbs/cloth_top.png", png([(b"tEXt", b"Comment\0x")]))
        self.assertNotEqual(first, self.fixture.inspect()["bundle"]["treeSha256"])

    def test_xml_info_plist_is_read(self):
        self.fixture.write_info(fmt=plistlib.FMT_XML)
        self.assertTrue(self.fixture.inspect()["passed"])


class RequiredResourceTests(InspectorTestCase):
    def test_missing_metallib_fails(self):
        self.fixture.remove("Contents/Resources/IkkokuShaders.metallib")
        report = self.fixture.inspect()
        self.assertFalse(report["passed"])
        self.assertFinding(report, "required", "Contents/Resources/IkkokuShaders.metallib")

    def test_metallib_signature_is_checked(self):
        self.fixture.bundle("Contents/Resources/IkkokuShaders.metallib", b"not a metal library")
        self.assertFinding(self.fixture.inspect(), "required", "Contents/Resources/IkkokuShaders.metallib")

    def test_empty_required_file_fails(self):
        self.fixture.bundle("Contents/Resources/Assets.car", b"")
        self.assertFinding(self.fixture.inspect(), "required", "Contents/Resources/Assets.car")

    def test_missing_catalog_reference_fails(self):
        self.fixture.remove("Contents/Resources/Clothes/top_cm.png")
        report = self.fixture.inspect()
        self.assertEqual(report["catalog"]["missing"], ["Clothes/top_cm.png"])
        self.assertFinding(report, "catalog", "Contents/Resources/Clothes/top_cm.png")

    def test_bare_texture_names_resolve_under_textures(self):
        self.fixture.remove("Contents/Resources/Textures/eye_iris_0.png")
        report = self.fixture.inspect()
        self.assertEqual(report["catalog"]["missing"], ["Textures/eye_iris_0.png"])

    def test_catalog_reference_escaping_the_root_fails(self):
        catalog = dict(CATALOG, items=[{"id": "x", "file": "../outside.glb"}])
        self.fixture.bundle("Contents/Resources/catalog.json", json.dumps(catalog).encode())
        self.assertFinding(self.fixture.inspect(), "catalog")

    def test_unreadable_catalog_fails(self):
        self.fixture.bundle("Contents/Resources/catalog.json", b"{not json")
        self.assertFinding(self.fixture.inspect(), "catalog", "Contents/Resources/catalog.json")

    def test_tracked_asset_missing_from_bundle_fails(self):
        self.fixture.remove("Contents/Resources/Thumbs/cloth_top.png")
        self.assertFinding(self.fixture.inspect(), "asset-missing", "Contents/Resources/Thumbs/cloth_top.png")

    def test_info_plist_identity_is_checked(self):
        self.fixture.info["CFBundleIdentifier"] = "com.example.Other"
        self.fixture.write_info()
        self.assertFinding(self.fixture.inspect(), "info-plist", "Contents/Info.plist")

    def test_info_plist_executable_must_match_rules(self):
        self.fixture.info["CFBundleExecutable"] = "Other"
        self.fixture.write_info()
        details = [f["detail"] for f in self.assertFinding(self.fixture.inspect(), "info-plist")]
        self.assertTrue(any("Contents/MacOS/Other" in d for d in details), details)


class ArchitectureTests(InspectorTestCase):
    def test_x86_64_only_executable_fails(self):
        self.fixture.bundle("Contents/MacOS/Ikkoku", thin_macho(CPU_X86_64))
        report = self.fixture.inspect()
        self.assertEqual(report["executable"]["architectures"], ["x86_64"])
        self.assertFinding(report, "architecture", "Contents/MacOS/Ikkoku")

    def test_universal_executable_with_arm64_passes(self):
        for wide in (False, True):
            with self.subTest(fat64=wide):
                self.fixture.bundle("Contents/MacOS/Ikkoku", fat_macho([CPU_X86_64, CPU_ARM64], wide))
                report = self.fixture.inspect()
                self.assertEqual(report["executable"]["architectures"], ["x86_64", "arm64"])
                self.assertTrue(report["passed"], report["findings"])

    def test_arm64e_is_named_and_does_not_satisfy_arm64(self):
        self.assertEqual(iab.macho_architectures(thin_macho(CPU_ARM64, 2)), ["arm64e"])
        self.fixture.bundle("Contents/MacOS/Ikkoku", thin_macho(CPU_ARM64, 2))
        self.assertFinding(self.fixture.inspect(), "architecture")

    def test_non_macho_executable_fails(self):
        self.fixture.bundle("Contents/MacOS/Ikkoku", b"#!/bin/sh\necho hi\n")
        self.assertFinding(self.fixture.inspect(), "architecture", "Contents/MacOS/Ikkoku")

    def test_every_macho_needs_arm64(self):
        self.fixture.bundle("Contents/Frameworks/libswiftCompatibilitySpan.dylib", thin_macho(CPU_X86_64))
        report = self.fixture.inspect()
        self.assertFinding(report, "architecture", "Contents/Frameworks/libswiftCompatibilitySpan.dylib")
        self.assertEqual(self.findings(report, "unexpected-file"), [])

    def test_java_class_magic_is_not_a_fat_binary(self):
        self.assertIsNone(iab.macho_architectures(b"\xca\xfe\xba\xbe\x00\x00\x00\x34" + b"\0" * 64))

    def test_executable_path_strings_are_counted_not_failed(self):
        payload = (self.fixture.checkout + "/Apps/IkkokuCreator/EngineHost.swift\0.local/reverse/x.json").encode()
        self.fixture.bundle("Contents/MacOS/Ikkoku", thin_macho(CPU_ARM64, payload=payload))
        report = self.fixture.inspect()
        self.assertTrue(report["passed"], report["findings"])
        references = report["executable"]["pathReferences"]
        self.assertEqual(references[".local/"], 1)
        self.assertEqual(references[self.fixture.checkout + "/"], 1)


class ProvenanceTests(InspectorTestCase):
    def test_untracked_resource_fails(self):
        self.fixture.bundle("Contents/Resources/Characters/body_f.regions.bin", b"\0\1\2")
        self.assertFinding(self.fixture.inspect(), "unexpected-file",
                           "Contents/Resources/Characters/body_f.regions.bin")

    def test_unexpected_severity_comes_from_rules(self):
        rules = copy.deepcopy(RULES)
        rules["unexpectedFiles"] = "warning"
        self.fixture.bundle("Contents/Resources/notes.txt", b"hello")
        report = self.fixture.inspect(rules)
        self.assertTrue(report["passed"])
        self.assertFinding(report, "unexpected-file", "Contents/Resources/notes.txt", severity="warning")

    def test_debug_dylibs_are_not_release_products(self):
        self.fixture.bundle("Contents/MacOS/Ikkoku.debug.dylib", thin_macho(CPU_ARM64))
        self.assertFinding(self.fixture.inspect(), "unexpected-file", "Contents/MacOS/Ikkoku.debug.dylib")

    def test_engine_test_fixture_is_unexpected(self):
        self.fixture.bundle("Contents/Resources/camera-object-reference.json", b"{}")
        self.assertFinding(self.fixture.inspect(), "unexpected-file",
                           "Contents/Resources/camera-object-reference.json")

    def test_excluded_fixture_lands_flat_and_fails(self):
        self.fixture.bundle("Contents/Resources/rig_fixture.gltf", b"{}")
        self.assertFinding(self.fixture.inspect(), "excluded-asset", "Contents/Resources/rig_fixture.gltf")

    def test_changed_tracked_asset_is_a_warning(self):
        self.fixture.bundle("Contents/Resources/Thumbs/cloth_top.png", png([(b"tEXt", b"Comment\0x")]))
        report = self.fixture.inspect()
        self.assertTrue(report["passed"])
        self.assertFinding(report, "asset-content", "Contents/Resources/Thumbs/cloth_top.png", severity="warning")

    def test_unavailable_tracked_list_fails(self):
        report = self.fixture.inspect(tracked=None)
        self.assertFinding(report, "provenance")
        self.assertEqual(report["summary"]["byClass"].get("unverified"), 7)

    def test_asset_destinations_follow_the_explicit_folders(self):
        self.assertEqual(iab.asset_destination("catalog.json", RULES), "Contents/Resources/catalog.json")
        self.assertEqual(iab.asset_destination("Clothes/a/b.glb", RULES), "Contents/Resources/Clothes/a/b.glb")
        self.assertEqual(iab.asset_destination("fixtures/x.gltf", RULES), "Contents/Resources/x.gltf")

    def test_colliding_tracked_destinations_fail(self):
        self.fixture.tracked = self.fixture.tracked + ["other/catalog.json"]
        self.assertFinding(self.fixture.inspect(), "asset-collision", "Contents/Resources/catalog.json")

    def test_symlink_out_of_the_bundle_fails(self):
        outside = os.path.join(self.temp, "outside.json")
        Fixture.write(outside, b"{}")
        os.symlink(outside, os.path.join(self.fixture.app, "Contents/Resources/link.json"))
        self.assertFinding(self.fixture.inspect(), "symlink-escape", "Contents/Resources/link.json")


class ForbiddenContentTests(InspectorTestCase):
    def test_local_tree_component(self):
        self.fixture.bundle("Contents/Resources/.local/reverse/rigs/source-avatar.json", b"{}")
        report = self.fixture.inspect()
        self.assertFinding(report, "private-local-tree")
        self.assertFinding(report, "original-game-tree")

    def test_original_installation_directories(self):
        self.fixture.bundle("Contents/Resources/abdata/chara/mt_ramp_00.unity3d", b"UnityFS\0 5.x.x")
        report = self.fixture.inspect()
        self.assertFinding(report, "original-game-tree")
        details = [f["detail"] for f in self.assertFinding(report, "unity-asset-bundle")]
        self.assertTrue(any("extension" in d for d in details) and any("signature" in d for d in details), details)

    def test_unity_bundle_signature_under_an_asset_name(self):
        self.fixture.bundle("Contents/Resources/Clothes/top.glb", b"UnityFS\0\0\0\0\x06" + b"\0" * 32)
        report = self.fixture.inspect()
        self.assertFinding(report, "unity-asset-bundle", "Contents/Resources/Clothes/top.glb")
        self.assertFinding(report, "resource-format", "Contents/Resources/Clothes/top.glb")

    def test_managed_assembly_by_name_and_by_header(self):
        pe = bytearray(b"MZ" + b"\0" * 0x7E)
        pe[0x3C:0x40] = struct.pack("<I", 0x40)
        pe[0x40:0x44] = b"PE\0\0"
        self.fixture.bundle("Contents/Resources/Assembly-CSharp.dll", bytes(pe))
        self.fixture.bundle("Contents/Resources/Items/payload.bin", bytes(pe))
        report = self.fixture.inspect()
        paths = {f["path"] for f in self.findings(report, "managed-assembly")}
        self.assertEqual(paths, {"Contents/Resources/Assembly-CSharp.dll", "Contents/Resources/Items/payload.bin"})

    def test_mz_without_pe_signature_is_not_an_assembly(self):
        self.assertFalse(iab.is_pe(b"MZ" + b"\0" * 100))

    def test_engine_package_sources_are_named(self):
        # The leak the first CI Release build found: Packages/ copied as a resource folder.
        for rel in ("Contents/Resources/Engine/Package.swift",
                    "Contents/Resources/Engine/Sources/ShaderTypes/include/ShaderTypes.h",
                    "Contents/Resources/Engine/Sources/ShaderTypes/shim.c"):
            self.fixture.bundle(rel, b"// source")
        fixture = "Contents/Resources/Engine/Tests/EngineTests/Fixtures/route-reference.json"
        self.fixture.bundle(fixture, b"{}")
        report = self.fixture.inspect()
        self.assertEqual(len(self.findings(report, "source-code")), 3)
        self.assertEqual(len(self.findings(report, "unexpected-file")), 4)
        self.assertFinding(report, "unexpected-file", fixture)

    def test_recovered_source_and_archives(self):
        for rel, rule in (("Contents/Resources/ChaControl.cs", "recovered-source"),
                          ("Contents/Resources/Toon.shader", "recovered-source"),
                          ("Contents/Resources/mods/Pack.zipmod", "mod-archive"),
                          ("Contents/Resources/x.cpython-312.pyc", "python-bytecode"),
                          ("Contents/Resources/Ikkoku.app.dSYM/Contents/Info.plist", "build-or-cache-tree")):
            with self.subTest(rel=rel):
                self.fixture.bundle(rel, b"x")
                self.assertFinding(self.fixture.inspect(), rule, rel)

    def test_card_payload_after_iend(self):
        self.fixture.bundle("Contents/Resources/Thumbs/cloth_top.png",
                            png(trailing=b"\x64\0\0\0\x12\xe3\x80\x90KoiKatuChara\xe3\x80\x91"))
        details = [f["detail"] for f in self.assertFinding(self.fixture.inspect(), "source-card-payload")]
        self.assertTrue(any("after IEND" in d and "KoiKatuChara" in d for d in details), details)

    def test_scene_keyword_in_png_text_chunk(self):
        compressed = b"note\0\0" + zlib.compress("【KStudio】".encode())
        self.fixture.bundle("Contents/Resources/Thumbs/cloth_top.png", png([(b"zTXt", compressed)]))
        self.assertFinding(self.fixture.inspect(), "source-card-payload", "Contents/Resources/Thumbs/cloth_top.png")

    def test_truncated_png_fails(self):
        self.fixture.bundle("Contents/Resources/Thumbs/cloth_top.png", png()[:-8])
        self.assertFinding(self.fixture.inspect(), "resource-format", "Contents/Resources/Thumbs/cloth_top.png")


class PathScanTests(InspectorTestCase):
    def test_absolute_path_in_text_resource(self):
        catalog = dict(CATALOG, notes=["exported from /Users/someone/ikkoku/Assets"])
        self.fixture.bundle("Contents/Resources/catalog.json", json.dumps(catalog).encode())
        self.assertFinding(self.fixture.inspect(), "absolute-build-path", "Contents/Resources/catalog.json")

    def test_checkout_root_in_glb_json_chunk(self):
        document = {"asset": {"version": "2.0"}, "extras": {"source": self.fixture.checkout + "/Tools/assets/x.blend"}}
        self.fixture.bundle("Contents/Resources/Clothes/top.glb", glb(document))
        details = [f["detail"] for f in self.assertFinding(self.fixture.inspect(), "absolute-build-path",
                                                           "Contents/Resources/Clothes/top.glb")]
        self.assertTrue(any(self.fixture.checkout in d for d in details), details)

    def test_local_reference_in_png_international_text(self):
        itxt = b"Source\0\0\0\0\0" + b"/tmp/x/.local/reverse/card.png"
        self.fixture.bundle("Contents/Resources/Thumbs/cloth_top.png", png([(b"iTXt", itxt)]))
        self.assertFinding(self.fixture.inspect(), "absolute-build-path", "Contents/Resources/Thumbs/cloth_top.png")

    def test_absolute_path_in_info_plist(self):
        self.fixture.info["IkkokuBuildRoot"] = "/home/builder/ikkoku"
        self.fixture.write_info()
        self.assertFinding(self.fixture.inspect(), "absolute-build-path", "Contents/Info.plist")

    def test_image_data_is_not_scanned(self):
        # Random-looking IDAT bytes may contain any short sequence; only text chunks count.
        data = png()
        index = data.index(b"IDAT")
        noisy = data[:index - 4] + struct.pack(">I", 8) + b"IDAT" + b"/Users/x" + b"\0\0\0\0" + data[data.index(b"IEND") - 4:]
        self.fixture.bundle("Contents/Resources/Thumbs/cloth_top.png", noisy)
        report = self.fixture.inspect()
        self.assertEqual(self.findings(report, "absolute-build-path"), [])

    def test_compiled_products_are_counted_not_failed(self):
        self.fixture.bundle("Contents/Resources/IkkokuShaders.metallib", b"MTLB" + b"/Users/runner/work/x.metal")
        report = self.fixture.inspect()
        self.assertTrue(report["passed"], report["findings"])
        entry = [f for f in report["files"] if f["path"] == "Contents/Resources/IkkokuShaders.metallib"][0]
        self.assertEqual(entry["pathReferences"], {"/Users/": 1})


class RulesValidationTests(unittest.TestCase):
    def write(self, rules):
        handle, path = tempfile.mkstemp(suffix=".json")
        self.addCleanup(os.unlink, path)
        with os.fdopen(handle, "w") as stream:
            json.dump(rules, stream)
        return path

    def test_checked_in_rules_load(self):
        self.assertEqual(RULES["schemaVersion"], 1)

    def test_rejections(self):
        cases = {
            "schema": lambda r: r.update(schemaVersion=2),
            "unknown key": lambda r: r.update(extra=1),
            "absolute required path": lambda r: r["required"].append({"path": "/etc/passwd"}),
            "parent required path": lambda r: r["required"].append({"path": "Contents/../x"}),
            "severity": lambda r: r.update(unexpectedFiles="fatal"),
            "duplicate forbidden id": lambda r: r["forbidden"].append(dict(r["forbidden"][0])),
            "empty forbidden rule": lambda r: r["forbidden"].append({"id": "nothing", "why": ""}),
            "unknown forbidden key": lambda r: r["forbidden"][0].update(regex=".*"),
            "content kind": lambda r: r["forbidden"].append({"id": "elf", "content": "elf"}),
            "architectures": lambda r: r["executable"].update(requiredArchitectures="arm64"),
        }
        for name, mutate in cases.items():
            with self.subTest(case=name):
                rules = copy.deepcopy(RULES)
                mutate(rules)
                with self.assertRaises(iab.RulesError):
                    iab.load_rules(self.write(rules))

    def test_unreadable_rules(self):
        with self.assertRaises(iab.RulesError):
            iab.load_rules(os.path.join(tempfile.gettempdir(), "no-such-ikkoku-rules.json"))


class RepositoryConsistencyTests(unittest.TestCase):
    """The rules mirror the Xcode project and the repository's ignore rules."""

    def project(self):
        with open(os.path.join(_REPO, "Ikkoku.xcodeproj", "project.pbxproj"), encoding="utf-8") as handle:
            return handle.read()

    def block(self, text, name):
        match = re.search(name + r" = \((.*?)\);", text, re.S)
        self.assertIsNotNone(match, name)
        return sorted(item.strip().strip('"') for item in match.group(1).split(",") if item.strip())

    def test_explicit_folders_match_the_project(self):
        self.assertEqual(self.block(self.project(), "explicitFolders"), sorted(RULES["assets"]["explicitFolders"]))

    def test_excluded_assets_match_the_membership_exceptions(self):
        self.assertEqual(self.block(self.project(), "membershipExceptions"), sorted(RULES["assets"]["excluded"]))

    def test_app_target_synchronizes_only_apps_and_assets(self):
        # A synchronized group copies every non-source file as a resource: listing
        # Packages/ shipped the whole Engine package (sources, tests, fixtures).
        target = re.search(r"/\* IkkokuCreator \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};",
                           self.project(), re.S)
        self.assertIsNotNone(target)
        listing = re.search(r"fileSystemSynchronizedGroups = \((.*?)\);", target.group(1), re.S)
        self.assertIsNotNone(listing)
        self.assertEqual(sorted(re.findall(r"/\* (\w+) \*/", listing.group(1))), ["Apps", "Assets"])
        self.assertEqual(RULES["assets"]["source"], "Assets")

    def test_metallib_is_a_copied_resource(self):
        self.assertIn("IkkokuShaders.metallib in Resources", self.project())
        self.assertIn("Contents/Resources/IkkokuShaders.metallib", [r["path"] for r in RULES["required"]])

    def test_executable_and_identity_match_the_project(self):
        project = self.project()
        self.assertIn("PRODUCT_NAME = %s;" % RULES["infoPlist"]["expect"]["CFBundleExecutable"], project)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = %s;" % RULES["infoPlist"]["expect"]["CFBundleIdentifier"], project)

    def test_private_tree_is_git_ignored(self):
        with open(os.path.join(_REPO, ".gitignore"), encoding="utf-8") as handle:
            ignored = handle.read().split()
        self.assertIn(".local/", ignored)
        components = {c for rule in RULES["forbidden"] for c in rule.get("pathComponents", [])}
        self.assertIn(".local", components)

    def test_every_checked_in_catalog_reference_is_a_tracked_asset(self):
        # A CI "missing reference" must mean a packaging defect, not stale rules.
        with open(os.path.join(_REPO, "Assets", "catalog.json"), encoding="utf-8") as handle:
            catalog = json.load(handle)
        rules = RULES["catalog"]
        references = set()

        def walk(value, key):
            if key in rules["ignoredKeys"]:
                return
            if isinstance(value, dict):
                for child_key, child in value.items():
                    walk(child, child_key)
            elif isinstance(value, list):
                for child in value:
                    walk(child, key)
            elif isinstance(value, str) and value.lower().endswith(tuple(rules["referenceExtensions"])):
                references.add(value if "/" in value else rules["bareNameDirectory"] + "/" + value)

        walk(catalog, None)
        self.assertGreater(len(references), 100)
        missing = sorted(r for r in references if not os.path.isfile(os.path.join(_REPO, "Assets", r)))
        self.assertEqual(missing, [])


@unittest.skipUnless(shutil.which("git"), "git is not installed")
class GitProvenanceTests(unittest.TestCase):
    def test_tracked_list_excludes_untracked_files(self):
        root = tempfile.mkdtemp(prefix="ikkoku-bundle-git-")
        self.addCleanup(shutil.rmtree, root)
        for rel in ("Assets/catalog.json", "Assets/Clothes/a.glb", "Assets/untracked.bin", "Other/x"):
            Fixture.write(os.path.join(root, rel), b"x")
        environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        for args in (["init", "-q"], ["add", "Assets/catalog.json", "Assets/Clothes/a.glb", "Other/x"]):
            subprocess.run(["git", "-C", root] + args, check=True, capture_output=True, env=environment)
        tracked, error = iab.git_tracked(root, "Assets")
        self.assertIsNone(error)
        self.assertEqual(tracked, ["Clothes/a.glb", "catalog.json"])

    def test_not_a_repository_reports_an_error(self):
        root = tempfile.mkdtemp(prefix="ikkoku-bundle-nogit-")
        self.addCleanup(shutil.rmtree, root)
        environment = {"GIT_CEILING_DIRECTORIES": os.path.dirname(root)}
        old = {k: os.environ.get(k) for k in environment}
        os.environ.update(environment)
        try:
            tracked, error = iab.git_tracked(root, "Assets")
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        self.assertIsNone(tracked)
        self.assertTrue(error)


class CommandLineTests(InspectorTestCase):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = iab.main(list(argv))
        return status, out.getvalue(), err.getvalue()

    def test_usage_errors_exit_2(self):
        status, _, err = self.run_main(self.temp)
        self.assertEqual(status, 2)
        self.assertIn("not an app bundle", err)
        status, _, err = self.run_main(self.fixture.app, "--report",
                                       os.path.join(self.fixture.app, "Contents", "report.json"))
        self.assertEqual(status, 2)
        broken = os.path.join(self.temp, "rules.json")
        Fixture.write(broken, b"{}")
        status, _, err = self.run_main(self.fixture.app, "--rules", broken)
        self.assertEqual(status, 2)

    def test_report_is_written_and_failure_exits_1(self):
        self.fixture.remove("Contents/Resources/IkkokuShaders.metallib")
        report_path = os.path.join(self.temp, "out", "bundle.json")
        # A checkout that is not a git repository: provenance is reported unavailable.
        status, out, err = self.run_main(self.fixture.app, "--checkout", self.fixture.checkout,
                                         "--report", report_path)
        self.assertEqual(status, 1)
        self.assertIn("FAILED", out)
        with open(report_path, encoding="utf-8") as handle:
            report = json.load(handle)
        self.assertFalse(report["passed"])
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(len(report["rules"]["sha256"]), 64)
        rules = {f["rule"] for f in report["findings"] if f["severity"] == "error"}
        self.assertIn("required", rules)


if __name__ == "__main__":
    unittest.main()
