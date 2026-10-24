"""Public synthetic assemblies exercise the real metadata reader without loading them."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import plugin_inventory as inventory
from translate import build_frontend

STUB = '''
using System;
namespace BepInEx {
[AttributeUsage(AttributeTargets.Class, AllowMultiple=true)]
public class BepInPlugin : Attribute {
 public BepInPlugin(string guid,string name,string version) {}
 public BepInPlugin(int unsupported) {}
 public string Extra {get;set;} = "";
}
[AttributeUsage(AttributeTargets.Class, AllowMultiple=true)]
public class BepInProcess : Attribute { public BepInProcess(string process) {} }
[AttributeUsage(AttributeTargets.Class, AllowMultiple=true)]
public class BepInDependency : Attribute {
 public enum DependencyFlags { HardDependency=1, SoftDependency=2 }
 public BepInDependency(string guid,DependencyFlags flags=DependencyFlags.HardDependency) {}
 public BepInDependency(string guid,string minimumVersion) {}
}
[AttributeUsage(AttributeTargets.Class, AllowMultiple=true)]
public class BepInIncompatibility : Attribute { public BepInIncompatibility(string guid) {} }
}
'''
RICH = '''
using BepInEx;
using System.Runtime.CompilerServices;
public static class NeverExecute {
 [ModuleInitializer] public static void Initialize() {
  System.IO.File.WriteAllText(System.Environment.GetEnvironmentVariable("IKKOKU_INVENTORY_SENTINEL")!, "executed");
  throw new System.Exception("Inventory must never load this assembly");
 }
}
namespace Fixtures {
 [BepInPlugin("dup", "First", "1.2.3")]
 [BepInPlugin("dup", "Second", "2.3.4")]
 [BepInProcess("Game.exe")][BepInProcess("game.exe")]
 [BepInDependency("hard")]
 [BepInDependency("soft", BepInDependency.DependencyFlags.SoftDependency)]
 [BepInDependency("versioned", "1.34")]
 [BepInIncompatibility("bad.mod")]
 public class First {}
 public class Outer {
  [BepInPlugin("é", "Nested Unicode", "5.4")]
  public class Inner {}
 }
 [BepInPlugin("e\\u0301", "Ordinal Unicode", "5.4")]
 public class Ordinal {}
 [BepInPlugin("unsupported-flags", "Flags", "1.0")]
 [BepInDependency("future", (BepInDependency.DependencyFlags)99)]
 public class FutureFlags {}
 [BepInPlugin(9)] public class UnsupportedOverload {}
 [BepInPlugin("named", "Named", "1.0", Extra="unsupported")]
 public class Named {}
}
'''


def native_pe() -> bytes:
    data = bytearray(512)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 0x80)
    data[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', data, 0x84, 0x8664, 0, 0, 0, 0, 240, 0x2022)
    struct.pack_into('<H', data, 0x98, 0x20b)
    struct.pack_into('<I', data, 0x98 + 60, 512)
    struct.pack_into('<I', data, 0x98 + 108, 16)
    return bytes(data)


class PluginInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # No skip fallback: these gates require the same installed SDK as translation.
        cache = inventory.ROOT / '.local/plugin-inventory-tests'
        cls.helper = build_frontend(cache / 'frontend')
        cache.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(dir=cache)
        cls.root = Path(cls.temporary.name)
        cls.sentinel = cls.root / 'EXECUTED'
        cls.stub = cls.build('BepInEx', STUB)
        cls.rich = cls.build('Rich', RICH, cls.stub)
        cls.plain = cls.build('Plain', 'public class Plain { public static int Add(int a,int b) => a+b; }')
        cls.fake = cls.build('FakeBepInEx', STUB + '\n[BepInEx.BepInPlugin("spoof", "Fake", "1.0")] public class Fake {}')
        # Resolving attribute metadata must not require dependencies on disk.
        (cls.rich.parent / 'BepInEx.dll').unlink()
        with patch.dict(os.environ, {'IKKOKU_INVENTORY_SENTINEL': str(cls.sentinel)}):
            cls.rich_report = inventory.inspect_file(cls.rich, cls.helper, 32 << 20)

    @classmethod
    def build(cls, name, source, reference=None):
        root = cls.root / name
        root.mkdir()
        references = '' if reference is None else f'<ItemGroup><Reference Include="BepInEx"><HintPath>{reference}</HintPath></Reference></ItemGroup>'
        (root / 'Fixture.csproj').write_text(f'<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><AssemblyName>{name}</AssemblyName><Nullable>enable</Nullable></PropertyGroup>{references}</Project>')
        (root / 'Fixture.cs').write_text(source)
        result = subprocess.run(['dotnet', 'build', str(root / 'Fixture.csproj'), '--nologo', '-v:q', '-o', str(root / 'out')], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return root / 'out' / (name + '.dll')

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_multiple_entries_duplicate_attributes_and_exact_identity(self):
        report = self.rich_report
        self.assertEqual(report['classification'], 'plugin-entries')
        self.assertEqual(report['diagnostics'], [])
        self.assertEqual(report['sourceSha256'], hashlib.sha256(self.rich.read_bytes()).hexdigest())
        self.assertEqual(report['byteLength'], self.rich.stat().st_size)
        self.assertEqual(report['assemblyIdentity']['name'], 'Rich')
        entries = report['entries']
        self.assertEqual(len(entries), 7)
        first = [e for e in entries if e['type'] == 'Fixtures.First']
        self.assertEqual([e['declaration']['identity'] for e in first], [
            {'guid': 'dup', 'name': 'First', 'version': '1.2.3'}, {'guid': 'dup', 'name': 'Second', 'version': '2.3.4'}])
        self.assertNotEqual(first[0]['declaration']['attributeToken'], first[1]['declaration']['attributeToken'])
        self.assertEqual(first[0]['processes'], ['Game.exe', 'game.exe'])
        self.assertEqual(first[0]['dependencies'], [{'guid': 'hard', 'flags': 1}, {'guid': 'soft', 'flags': 2}, {'guid': 'versioned', 'minimumVersion': '1.34', 'flags': 1}])
        self.assertEqual(first[0]['incompatibilities'], ['bad.mod'])
        self.assertEqual(first[0]['diagnostics'], [])
        identities = {e['type']: e['declaration']['identity'] for e in entries}
        self.assertEqual(identities['Fixtures.Outer+Inner']['guid'], 'é')
        self.assertEqual(identities['Fixtures.Ordinal']['guid'], 'e\u0301')
        self.assertNotEqual(identities['Fixtures.Outer+Inner']['guid'], identities['Fixtures.Ordinal']['guid'])

    def test_never_loads_assembly_or_requires_dependency(self):
        self.assertFalse(self.sentinel.exists())
        self.assertFalse((self.rich.parent / 'BepInEx.dll').exists())
        self.assertTrue(any(a['name'] == 'BepInEx' for a in self.rich_report['assemblyReferences']))
        self.assertTrue(any(m['owner'] == 'System.IO.File' and m['name'] == 'WriteAllText' for m in self.rich_report['memberReferences']))

    def test_unsupported_declarations_remain_visible(self):
        entries = {e['type']: e for e in self.rich_report['entries']}
        self.assertIn('Unsupported dependency flags 99', ' '.join(entries['Fixtures.FutureFlags']['diagnostics']))
        self.assertEqual(entries['Fixtures.FutureFlags']['dependencies'], [{'guid': 'future', 'flags': 99}])
        self.assertIsNone(entries['Fixtures.UnsupportedOverload']['declaration']['identity'])
        self.assertTrue(entries['Fixtures.UnsupportedOverload']['diagnostics'])
        self.assertIn('Named attribute arguments', ' '.join(entries['Fixtures.Named']['diagnostics']))

    def test_wrong_assembly_scope_is_not_plugin_identity(self):
        report = inventory.inspect_file(self.fake, self.helper, 32 << 20)
        self.assertEqual(report['entries'], [])
        self.assertIn('not BepInEx', ' '.join(report['diagnostics']))

    def test_plain_native_and_malformed_are_distinct(self):
        report = inventory.inspect_file(self.plain, self.helper, 32 << 20)
        self.assertEqual(report['classification'], 'managed-library')
        self.assertEqual(report['entries'], [])
        native = self.root / 'native.dll'
        native.write_bytes(native_pe())
        self.assertEqual(inventory.inspect_file(native, self.helper, 32 << 20)['classification'], 'native-or-no-metadata')
        broken = self.root / 'broken.dll'
        broken.write_bytes(self.rich.read_bytes()[:128])
        report = inventory.inspect_file(broken, self.helper, 32 << 20)
        self.assertEqual(report['classification'], 'invalid-metadata')
        self.assertTrue(report['diagnostics'])

    def test_helper_file_bound_precedes_snapshot(self):
        report = inventory.inspect_file(self.rich, self.helper, self.rich.stat().st_size - 1)
        self.assertEqual(report['classification'], 'unreadable')
        self.assertNotIn('sourceSha256', report)
        self.assertIn('byte limit', report['diagnostics'][0])

    def test_duplicate_files_stable_order_and_repeat(self):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            root = Path(temporary)
            shutil.copyfile(self.rich, root / 'z.dll')
            shutil.copyfile(self.rich, root / 'A.DLL')
            report = inventory.inventory(root, self.helper)
            self.assertEqual([a['path'] for a in report['assemblies']], ['A.DLL', 'z.dll'])
            self.assertEqual(report['summary']['pluginDeclarations'], 14)
            self.assertEqual(inventory.encoded(report), inventory.encoded(inventory.inventory(root, self.helper)))
            self.assertTrue(all(a['registeredAdapter'] is None for a in report['assemblies']))
            self.assertEqual(report['assessment']['hostIntegration'], 'not-assessed')

    def test_scanner_bounds_symlinks_and_no_helper_for_rejected_files(self):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            root = Path(temporary)
            (root / 'a.dll').write_bytes(b'12345')
            (root / 'b.dll').write_bytes(b'12345')
            (root / 'link.dll').symlink_to(self.rich)
            (root / 'directory-link').symlink_to(self.root, target_is_directory=True)
            (root / 'nested').mkdir()
            (root / 'nested' / 'deeper').mkdir()
            with patch.object(inventory, 'inspect_file') as inspect:
                report = inventory.inventory(root, self.helper, inventory.Limits(file_bytes=4, depth=1))
                inspect.assert_not_called()
            self.assertEqual([d['code'] for d in report['diagnostics']].count('file-byte-limit'), 2)
            self.assertEqual([d['code'] for d in report['diagnostics']].count('symlink-skipped'), 2)
            self.assertIn('depth-limit', [d['code'] for d in report['diagnostics']])
            with self.assertRaisesRegex(ValueError, 'DLL file limit'):
                inventory.inventory(root, self.helper, inventory.Limits(files=1))
            with self.assertRaisesRegex(ValueError, 'Directory entry limit'):
                inventory.inventory(root, self.helper, inventory.Limits(entries=1))
            with patch.object(inventory, 'inspect_file', return_value={'byteLength': 5, 'entries': []}) as inspect:
                report = inventory.inventory(root, self.helper, inventory.Limits(total_bytes=5))
                self.assertEqual(inspect.call_count, 1)
                self.assertEqual(report['summary']['snapshotBytes'], 5)
                self.assertIn('total-byte-limit', [d['code'] for d in report['diagnostics']])

    def test_malformed_attribute_preserves_other_entries_and_reports_error(self):
        data = self.rich.read_bytes()
        prefix = b'\x01\x00' + bytes([len('unsupported-flags')]) + b'unsupported-flags'
        self.assertEqual(data.count(prefix), 1)
        for label, replacement in [('prolog', b'\x02\x00' + prefix[2:]),
                                   ('utf8', prefix[:3] + b'\xff' + prefix[4:])]:
            path = self.root / (label + '.dll')
            path.write_bytes(data.replace(prefix, replacement))
            report = inventory.inspect_file(path, self.helper, 32 << 20)
            self.assertEqual(len(report['entries']), 7)
            entries = {e['type']: e for e in report['entries']}
            self.assertTrue(entries['Fixtures.FutureFlags']['diagnostics'])
            self.assertIsNone(entries['Fixtures.FutureFlags']['declaration']['identity'])
            self.assertEqual(entries['Fixtures.Outer+Inner']['declaration']['identity']['guid'], 'é')

    def test_existing_translation_dispatch_remains_functional(self):
        source = self.root / 'TranslationInput.cs'
        source.write_text('using UnityEngine; namespace Fixture; public class Component : MonoBehaviour { void Update() { transform.Translate(Vector3.one); } }')
        result = subprocess.run(['dotnet', str(self.helper), str(source), 'Fixture.Component', 'component', ''], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['status'], 'ready', report['diagnostics'])
        self.assertEqual(len(report['methods']), 1)
        self.assertEqual(report['methods'][0]['lifecycle'], 'Update')

    def test_failed_inspection_still_consumes_aggregate_budget(self):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            root = Path(temporary)
            for name in ['a.dll', 'b.dll']:
                (root / name).write_bytes(b'12345')
            with patch.object(inventory, 'inspect_file', return_value={'classification': 'unreadable', 'entries': []}) as inspect:
                report = inventory.inventory(root, self.helper, inventory.Limits(total_bytes=5))
                inspect.assert_called_once()
            self.assertEqual(report['summary']['snapshotBytes'], 0)
            self.assertEqual(report['summary']['chargedBytes'], 5)
            self.assertEqual(report['diagnostics'], [{'path': 'b.dll', 'code': 'total-byte-limit'}])

    def test_failed_scan_does_not_replace_previous_report(self):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            root = Path(temporary)
            (root / 'a.dll').write_bytes(b'x')
            (root / 'b.dll').write_bytes(b'x')
            output = root / 'report.json'
            output.write_bytes(b'previous report')
            argv = ['plugin_inventory.py', str(root), '--output', str(output), '--max-files', '1']
            with patch.object(sys, 'argv', argv), patch.object(inventory, 'build_frontend', return_value=self.helper):
                with self.assertRaisesRegex(ValueError, 'DLL file limit'):
                    inventory.main()
            self.assertEqual(output.read_bytes(), b'previous report')

    def test_registry_match_requires_exact_hash(self):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            root = Path(temporary)
            (root / 'a.dll').write_bytes(b'x')
            digest = next(iter(inventory.native_adapters.REGISTRY))
            def fake(*args): return {'byteLength': 1, 'sourceSha256': digest, 'entries': []}
            with patch.object(inventory, 'inspect_file', side_effect=fake):
                report = inventory.inventory(root, self.helper)
            self.assertEqual(report['assemblies'][0]['registeredAdapter']['match'], 'exact-source-sha256')
            digest = digest.upper()
            with patch.object(inventory, 'inspect_file', side_effect=fake):
                report = inventory.inventory(root, self.helper)
            self.assertIsNone(report['assemblies'][0]['registeredAdapter'])


if __name__ == '__main__':
    unittest.main()
