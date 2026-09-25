"""Local recovery integrity and failure routing, without a decompiler or game data."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from analysis import recover_managed as recovery


class ManagedRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def generation(self):
        target = self.root / 'generation'
        target.mkdir()
        source = target / 'project' / 'Example.cs'
        source.parent.mkdir()
        source.write_bytes(b'public class Example {}\n')
        identity = {'schemaVersion': 3, 'assemblySHA256': 'source-hash'}
        files = [{'path': 'project/Example.cs', 'bytes': source.stat().st_size,
                  'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}]
        manifest = {'identity': identity, 'files': files}
        (target / 'manifest.json').write_text(json.dumps(manifest))
        return target, source, identity, manifest

    def test_generation_checks_content_not_only_size_or_identity(self):
        target, source, identity, _ = self.generation()
        self.assertTrue(recovery.valid_generation(target, identity))
        self.assertFalse(recovery.valid_generation(target, {'schemaVersion': 4}))
        source.write_bytes(b'x' * source.stat().st_size)
        self.assertFalse(recovery.valid_generation(target, identity))

    def test_generation_rejects_missing_and_unlisted_files(self):
        target, source, identity, _ = self.generation()
        extra = target / 'unlisted.txt'
        extra.write_text('unexpected')
        self.assertFalse(recovery.valid_generation(target, identity))
        extra.unlink()
        self.assertTrue(recovery.valid_generation(target, identity))
        source.unlink()
        self.assertFalse(recovery.valid_generation(target, identity))

    def test_generation_rejects_path_traversal_and_symlink_escape(self):
        target, source, identity, manifest = self.generation()
        outside = self.root / 'outside.cs'
        outside.write_bytes(source.read_bytes())
        traversal = copy.deepcopy(manifest)
        traversal['files'][0]['path'] = '../outside.cs'
        (target / 'manifest.json').write_text(json.dumps(traversal))
        self.assertFalse(recovery.valid_generation(target, identity))
        (target / 'manifest.json').write_text(json.dumps(manifest))
        source.unlink()
        source.symlink_to(outside)
        self.assertFalse(recovery.valid_generation(target, identity))

    def test_generation_rejects_malformed_manifest(self):
        target, _, identity, manifest = self.generation()
        for content in ['{', '[]', '{}', json.dumps({'identity': identity, 'files': []}),
                        json.dumps({**manifest, 'files': [{'path': None}]})]:
            with self.subTest(content=content):
                (target / 'manifest.json').write_text(content)
                self.assertFalse(recovery.valid_generation(target, identity))

    def test_local_output_resolves_containment_and_symlinks(self):
        local = self.root / '.local'
        local.mkdir()
        outside = self.root / 'elsewhere'
        outside.mkdir()
        (local / 'escape').symlink_to(outside, target_is_directory=True)
        with patch.object(recovery, 'REPO', self.root):
            self.assertEqual(recovery.local_output(local / 'new' / 'generation'), local / 'new' / 'generation')
            for value in [outside, local / '..' / 'outside', local / 'escape' / 'generation', self.root / '.local-other']:
                with self.subTest(path=value), self.assertRaises(ValueError):
                    recovery.local_output(value)

    def test_inventory_hashes_binary_and_records_bounded_source_diagnostics(self):
        (self.root / 'a.bin').write_bytes(b'\x00\xff')
        (self.root / 'b.cs').write_text('class Good {}\n // System.InvalidOperationException: bad\n' +
                                      '// Error decompiling ' + 'z' * 600 + '\n')
        files, diagnostics = recovery.inventory_tree(self.root)
        self.assertEqual([f['path'] for f in files], ['a.bin', 'b.cs'])
        self.assertEqual(files[0]['sha256'], hashlib.sha256(b'\x00\xff').hexdigest())
        self.assertEqual([d['line'] for d in diagnostics], [2, 3])
        self.assertEqual(len(diagnostics[1]['message']), 512)

    def test_error_log_extracts_metadata_tokens_without_unrelated_messages(self):
        log = self.root / 'stderr.txt'
        log.write_text('unrelated warning\nError decompiling @06000a1F Example.Widget.Run: internal failure\n'
                       'Error decompiling @06000002 Example.Widget..ctor: constructor failure\n')
        self.assertEqual(recovery.decompilation_errors(log), [
            {'token': '0x06000a1F', 'member': 'Example.Widget.Run', 'error': 'internal failure'},
            {'token': '0x06000002', 'member': 'Example.Widget..ctor', 'error': 'constructor failure'}])

    def test_fallback_metadata_name_prefers_exact_and_unique_generic_arity(self):
        definitions = [{'Namespace': 'Example', 'Name': 'Widget`1'}, {'Namespace': '', 'Name': 'Global'}]
        self.assertEqual(recovery.metadata_type_name('Example.Widget', definitions), 'Example.Widget`1')
        self.assertEqual(recovery.metadata_type_name('Example.Widget`1', definitions), 'Example.Widget`1')
        self.assertEqual(recovery.metadata_type_name('Global', definitions), 'Global')
        with self.assertRaises(ValueError): recovery.metadata_type_name('Absent', definitions)
        definitions.append({'Namespace': 'Example', 'Name': 'Widget`2'})
        with self.assertRaises(ValueError): recovery.metadata_type_name('Example.Widget', definitions)
        definitions.append({'Namespace': 'Example', 'Name': 'Widget'})
        self.assertEqual(recovery.metadata_type_name('Example.Widget', definitions), 'Example.Widget')

    def test_run_records_exit_and_timeout_without_interpreting_game_code(self):
        log = self.root / 'project.log'
        with patch.object(recovery.subprocess, 'run', return_value=subprocess.CompletedProcess([], 7)) as execute:
            result = recovery.run(Path('/fake/decompiler'), Path('/fake/game.dll'), ['-il'], log, 5)
        self.assertEqual(result, {'exitCode': 7, 'timedOut': False})
        self.assertEqual(execute.call_args.args[0], ['/fake/decompiler', '--disable-updatecheck', '-il', '/fake/game.dll'])
        self.assertEqual(execute.call_args.kwargs['timeout'], 5)
        self.assertTrue(log.exists() and log.with_suffix('.stderr.txt').exists())
        with patch.object(recovery.subprocess, 'run', side_effect=subprocess.TimeoutExpired('fake', 5)):
            self.assertEqual(recovery.run(Path('fake'), Path('game.dll'), [], log, 5),
                             {'exitCode': None, 'timedOut': True})

    def setup_recovery(self):
        assembly = self.root / 'Game.dll'
        assembly.write_bytes(b'synthetic assembly identity, never executable')
        references = self.root / 'references'
        references.mkdir()
        (references / 'Present.dll').write_bytes(b'synthetic dependency')
        known = [{'path': 'C:/Game/Game.dll', 'sha256': hashlib.sha256(assembly.read_bytes()).hexdigest()}]
        return assembly, references, known, self.root / 'output'

    def fake_decompiler(self, project_failure=False, fallback_stub=False, core_failure=False,
                        primary_stub=False, unrelated_stub=False, project_error_exit=70):
        def invoke(tool, assembly, args, log, timeout):
            log.write_text('')
            log.with_suffix('.stderr.txt').write_text('')
            result = {'exitCode': 0, 'timedOut': False}
            if '--dump-table' in args:
                table = args[args.index('--dump-table') + 1]
                rows = {'TypeDef': [{'Namespace': 'Example', 'Name': 'Widget`1'}], 'MethodDef': [{'Name': 'Run'}],
                        'AssemblyRef': [{'Name': 'Present', 'Version': '1.0'}, {'Name': 'Missing', 'Version': '2.0'}],
                        'TypeRef': [{'Namespace': 'UnityEngine', 'Name': 'Object'}]}[table]
                log.write_text(json.dumps({'rowCount': len(rows), 'rows': rows}))
                if core_failure and table == 'MethodDef': result['exitCode'] = 1
            elif '-p' in args:
                directory = Path(args[args.index('-o') + 1]); directory.mkdir()
                (directory / 'Example').mkdir()
                (directory / 'Example' / 'Widget.cs').write_text(
                    '// System.InvalidOperationException: primary failed method' if primary_stub else 'public class Widget {}')
                if unrelated_stub:
                    (directory / 'Unrelated.cs').write_text('// Error decompiling unrelated method')
                if project_failure:
                    result['exitCode'] = project_error_exit
                    log.with_suffix('.stderr.txt').write_text('Error decompiling @06000001 Example.Widget.Run: failed\n'
                                                              'Error decompiling @06000002 Example.Widget..ctor: failed\n')
            elif '-t' in args:
                self.assertEqual(args[args.index('-t') + 1], 'Example.Widget`1')
                log.write_text('// System.InvalidOperationException: stub' if fallback_stub else 'public class Widget<T> {}')
            elif '-il' in args:
                directory = Path(args[args.index('-o') + 1]); directory.mkdir()
                (directory / 'Game.il').write_text('.assembly Game {}')
            else: self.fail(f'Unexpected decompiler invocation: {args}')
            return result
        return invoke

    def test_recover_requires_inventoried_source_hash_before_running_tools(self):
        assembly, references, _, output = self.setup_recovery()
        with patch.object(recovery, 'run') as invoke, self.assertRaisesRegex(ValueError, 'inventoried source hash'):
            recovery.recover(assembly, references, Path('tool'), output, 'v1', [], 10)
        invoke.assert_not_called()
        self.assertFalse(output.exists())

    def test_recovery_cache_reuses_valid_generation_and_refuses_tampering(self):
        assembly, references, known, output = self.setup_recovery()
        with patch.object(recovery, 'run', side_effect=self.fake_decompiler()) as invoke:
            first = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10)
            self.assertEqual(first['status'], 'recovered')
            self.assertEqual(first['missingReferences'], ['Missing'])
            self.assertEqual(first['sourceFiles'], 1)
            calls = invoke.call_count
            second = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10)
            self.assertTrue(second['reused'])
            self.assertEqual(invoke.call_count, calls)
            (Path(first['directory']) / 'project' / 'Example' / 'Widget.cs').write_text('tampered')
            with self.assertRaisesRegex(ValueError, 'integrity checks'):
                recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10)
            self.assertEqual(invoke.call_count, calls)

    def test_failed_project_uses_unique_type_override_and_preserves_failed_tokens(self):
        assembly, references, known, output = self.setup_recovery()
        with patch.object(recovery, 'run', side_effect=self.fake_decompiler(project_failure=True)):
            report = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10,
                                      Path('fallback'), 'v0')
        manifest = json.loads((Path(report['directory']) / 'manifest.json').read_text())
        self.assertEqual((report['status'], report['primaryDecompilerErrors'], report['typeOverrideCount']), ('recovered', 2, 1))
        override = manifest['typeOverrides'][0]
        self.assertEqual(override['type'], 'Example.Widget`1')
        self.assertEqual(override['failedTokens'], ['0x06000001', '0x06000002'])
        self.assertEqual(manifest['commands']['project']['exitCode'], 70)
        self.assertFalse(override['hasErrorStub'])

    def test_failed_core_table_and_error_stub_cannot_report_recovered(self):
        for name, options in [('core', {'core_failure': True}),
                              ('fallback', {'project_failure': True, 'fallback_stub': True}),
                              ('project', {'project_failure': True})]:
            with self.subTest(case=name):
                case = self.root / name; case.mkdir()
                old_root, self.root = self.root, case
                try:
                    assembly, references, known, output = self.setup_recovery()
                    with patch.object(recovery, 'run', side_effect=self.fake_decompiler(**options)):
                        report = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10,
                                                  Path('fallback') if name == 'fallback' else None, 'v0')
                    self.assertEqual(report['status'], 'partial')
                finally: self.root = old_root

    def test_exit_zero_with_silent_primary_stub_is_partial(self):
        assembly, references, known, output = self.setup_recovery()
        with patch.object(recovery, 'run', side_effect=self.fake_decompiler(primary_stub=True)):
            report = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10)
        manifest = json.loads((Path(report['directory']) / 'manifest.json').read_text())
        self.assertEqual(manifest['commands']['project']['exitCode'], 0)
        self.assertEqual(report['status'], 'partial')
        self.assertEqual(report['primaryDecompilerErrors'], 0)
        self.assertEqual(report['typeOverrideCount'], 0)
        self.assertEqual(report['decompilerDiagnosticCount'], 1)
        self.assertEqual(report['unresolvedDecompilerDiagnosticCount'], 1)
        self.assertEqual([d['file'] for d in manifest['unresolvedDecompilerDiagnostics']], ['project/Example/Widget.cs'])

    def test_clean_whole_type_override_supersedes_only_its_primary_stub(self):
        assembly, references, known, output = self.setup_recovery()
        with patch.object(recovery, 'run', side_effect=self.fake_decompiler(project_failure=True, primary_stub=True)):
            report = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10, Path('fallback'), 'v0')
        manifest = json.loads((Path(report['directory']) / 'manifest.json').read_text())
        self.assertEqual(report['status'], 'recovered')
        self.assertEqual(report['decompilerDiagnosticCount'], 1)
        self.assertEqual(report['unresolvedDecompilerDiagnosticCount'], 0)
        self.assertEqual(manifest['unresolvedDecompilerDiagnostics'], [])
        self.assertEqual(manifest['typeOverrides'][0]['type'], 'Example.Widget`1')
        self.assertEqual([d['file'] for d in manifest['decompilerDiagnostics']], ['project/Example/Widget.cs'])
        # Primary failed text remains intact as evidence; only the clean override is authoritative.
        self.assertIn('primary failed method', (Path(report['directory']) / 'project' / 'Example' / 'Widget.cs').read_text())

    def test_clean_override_does_not_hide_unrelated_primary_stub(self):
        assembly, references, known, output = self.setup_recovery()
        with patch.object(recovery, 'run', side_effect=self.fake_decompiler(
                project_failure=True, primary_stub=True, unrelated_stub=True)):
            report = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10, Path('fallback'), 'v0')
        manifest = json.loads((Path(report['directory']) / 'manifest.json').read_text())
        self.assertEqual(report['status'], 'partial')
        self.assertEqual(report['typeOverrideCount'], 1)
        self.assertEqual(report['decompilerDiagnosticCount'], 2)
        self.assertEqual(report['unresolvedDecompilerDiagnosticCount'], 1)
        self.assertEqual([d['file'] for d in manifest['unresolvedDecompilerDiagnostics']], ['project/Unrelated.cs'])

    def test_exit_zero_with_reported_errors_still_requires_fallback(self):
        assembly, references, known, output = self.setup_recovery()
        with patch.object(recovery, 'run', side_effect=self.fake_decompiler(project_failure=True, project_error_exit=0)):
            without = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10)
            with_fallback = recovery.recover(assembly, references, Path('tool'), output, 'v1', known, 10,
                                             Path('fallback'), 'v0')
        self.assertEqual((without['status'], without['primaryDecompilerErrors']), ('partial', 2))
        self.assertEqual((with_fallback['status'], with_fallback['typeOverrideCount']), ('recovered', 1))


if __name__ == '__main__': unittest.main()
