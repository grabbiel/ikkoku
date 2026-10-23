"""Synthetic recovery trees for recovered_source.py and its consumers (no game code).

Each generation is produced by the real recover_managed.recover() with a fake
ILSpy, so the resolver reads exactly the manifest/index layout recovery writes.
"""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import card_roundtrip
import recover_managed as recovery
import recovered_source as resolver
from recovered_source import (AmbiguousRecoveredSource, MissingRecoveredSource, RecoveredAssembly, RecoveredErrorStub,
                              RecoveredHashMismatch, RecoveryManifestError)
import studio_animation_contract
import studio_fullbody_oracle
import trigonometric_ik_contract

MAIN = resolver.MAIN_GAME
STUB = '// System.InvalidOperationException: primary failed method\n'


def sha(data):
    return hashlib.sha256(data).hexdigest()


class RecoveryTree(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.index = self.root / 'index.json'

    def recover(self, project, failures=(), fallbacks=None, typedefs=(), source_path=MAIN, name='Game.dll', tool='v1'):
        """Recover one synthetic assembly and index only that generation."""
        assembly = self.root / name
        if not assembly.exists():
            assembly.write_bytes(b'synthetic assembly identity, never executable: ' + name.encode())
        references = self.root / 'references'
        references.mkdir(exist_ok=True)

        def invoke(_tool, _assembly, args, log, _timeout):
            log.write_text('')
            log.with_suffix('.stderr.txt').write_text('')
            result = {'exitCode': 0, 'timedOut': False}
            if '--dump-table' in args:
                rows = list(typedefs) if args[args.index('--dump-table') + 1] == 'TypeDef' else []
                log.write_text(json.dumps({'rowCount': len(rows), 'rows': rows}))
            elif '-p' in args:
                directory = Path(args[args.index('-o') + 1])
                directory.mkdir()
                for relative, text in project.items():
                    (directory / relative).parent.mkdir(parents=True, exist_ok=True)
                    (directory / relative).write_text(text)
                if failures:
                    result['exitCode'] = 70
                    log.with_suffix('.stderr.txt').write_text(''.join(
                        f'Error decompiling @{0x06000001 + i:08X} {member}: failed\n' for i, member in enumerate(failures)))
            elif '-t' in args:
                log.write_text(fallbacks[args[args.index('-t') + 1]])
            elif '-il' in args:
                directory = Path(args[args.index('-o') + 1])
                directory.mkdir()
                (directory / 'Game.il').write_text('.assembly Game {}')
            else:
                self.fail(f'Unexpected decompiler invocation: {args}')
            return result
        known = [{'path': source_path, 'sha256': sha(assembly.read_bytes())}]
        with patch.object(recovery, 'run', side_effect=invoke):
            report = recovery.recover(assembly, references, Path('tool'), self.root / 'output', tool, known, 10,
                                      Path('fallback') if fallbacks is not None else None, 'v0')
        self.write_index([report])
        return report

    def write_index(self, reports):
        self.index.write_text(json.dumps({'schemaVersion': recovery.VERSION, 'assemblies': reports}, indent=2))

    def edit_manifest(self, report, change):
        path = Path(report['directory']) / 'manifest.json'
        manifest = json.loads(path.read_text())
        change(manifest)
        path.write_text(json.dumps(manifest))

    def rewrite(self, report, relative, text):
        """Change a recorded file and its manifest hash together."""
        path = Path(report['directory']) / relative
        path.write_text(text)

        def change(manifest):
            entry = next(item for item in manifest['files'] if item['path'] == relative)
            entry.update(bytes=path.stat().st_size, sha256=sha(path.read_bytes()))
        self.edit_manifest(report, change)


class ResolverTests(RecoveryTree):
    def failed_widget(self, fallback='public class Widget<T> {}\n', primary=STUB):
        return self.recover({'Example/Widget.cs': primary, 'Example/Other.cs': 'public class Other {}\n'},
                            failures=['Example.Widget.Run', 'Example.Widget..ctor'],
                            typedefs=[{'Namespace': 'Example', 'Name': 'Widget`1'}, {'Namespace': 'Example', 'Name': 'Other'}],
                            fallbacks={'Example.Widget`1': fallback})

    def test_selected_project_types_resolve_with_their_recorded_hash(self):
        report = self.recover({'Example/Widget.cs': 'public class Widget {}\r\n', 'Example.Sub/Thing.cs': 'class Thing {}\n',
                               'Global.cs': 'class Global {}\n'})
        self.assertEqual(report['status'], 'recovered')
        assembly = RecoveredAssembly(self.index, source_path=MAIN)
        assembly.verify_assembly()
        directory = Path(report['directory'])
        for name, relative in [('Example.Widget', 'project/Example/Widget.cs'), ('Example.Sub.Thing', 'project/Example.Sub/Thing.cs'),
                               ('Global', 'project/Global.cs')]:
            with self.subTest(type=name):
                source = assembly.source(name)
                self.assertEqual((source.path, source.origin), (directory / relative, 'project'))
                self.assertEqual(source.sha256, sha((directory / relative).read_bytes()))
                self.assertEqual(source.text, (directory / relative).read_text())
        self.assertEqual(RecoveredAssembly(self.index, sha256=report['assemblySHA256']).directory, directory)

    def test_indexed_generation_wins_over_other_generations_of_the_assembly(self):
        stale = self.recover({'Example/Widget.cs': STUB}, tool='v0')
        current = self.recover({'Example/Widget.cs': 'public class Widget {}\n'}, tool='v1')
        self.assertEqual((stale['status'], current['status']), ('partial', 'recovered'))
        self.assertEqual(Path(stale['directory']).parent, Path(current['directory']).parent)
        source = RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')
        self.assertEqual(source.path, Path(current['directory']) / 'project/Example/Widget.cs')
        self.assertNotIn('Exception', source.text)

    def test_clean_type_fallback_replaces_only_the_failed_primary_type(self):
        report = self.failed_widget()
        self.assertEqual((report['status'], report['typeOverrideCount']), ('recovered', 1))
        assembly = RecoveredAssembly(self.index, source_path=MAIN)
        for name in ['Example.Widget', 'Example.Widget`1']:
            with self.subTest(type=name):
                source = assembly.source(name)
                self.assertEqual((source.path, source.origin), (Path(report['directory']) / 'type-fallback/0000.cs', 'type-fallback'))
                self.assertEqual(source.text, 'public class Widget<T> {}\n')
        self.assertEqual(assembly.source('Example.Other').origin, 'project')
        # The primary stub stays preserved as evidence and is never returned.
        self.assertIn('primary failed method', (Path(report['directory']) / 'project/Example/Widget.cs').read_text())

    def test_primary_error_stub_without_a_fallback_is_refused(self):
        for marker in [STUB, '// Error decompiling Example.Widget.Run\n', 'throw new ICSharpCode.Decompiler.DecompilerException();\n']:
            with self.subTest(marker=marker):
                report = self.recover({'Example/Widget.cs': 'public class Widget {\n' + marker + '}\n',
                                       'Example/Other.cs': 'public class Other {}\n'}, tool=sha(marker.encode()))
                # Exit zero and no failure log: the project is selected but partial.
                self.assertEqual((report['selectedProject'], report['status']), ('project', 'partial'))
                assembly = RecoveredAssembly(self.index, source_path=MAIN)
                with self.assertRaisesRegex(RecoveredErrorStub, 'error stub'):
                    assembly.source('Example.Widget')
                self.assertEqual(assembly.source('Example.Other').origin, 'project')

    def test_failed_primary_type_without_a_clean_fallback_selects_nothing(self):
        typedefs = [{'Namespace': 'Example', 'Name': 'Widget'}]
        for name, fallbacks in [('no fallback tool', None), ('stub fallback', {'Example.Widget': STUB})]:
            with self.subTest(case=name):
                report = self.recover({'Example/Widget.cs': 'public class Widget {}\n'}, failures=['Example.Widget.Run'],
                                      fallbacks=fallbacks, typedefs=typedefs, tool=name)
                self.assertIsNone(report['selectedProject'])
                with self.assertRaisesRegex(RecoveryManifestError, 'no usable project'):
                    RecoveredAssembly(self.index, source_path=MAIN)

    def test_unclean_recorded_fallback_never_falls_back_to_the_primary(self):
        # A clean-looking primary must not be used for a type the failure log named.
        report = self.failed_widget(primary='public class Widget<T> {}\n')
        for field, value in [('hasErrorStub', True), ('exitCode', 1), ('timedOut', True)]:
            with self.subTest(field=field):
                self.edit_manifest(report, lambda manifest: manifest['typeOverrides'][0].update({field: value}))
                with self.assertRaisesRegex(RecoveredErrorStub, 'did not complete cleanly'):
                    RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')
                self.edit_manifest(report, lambda manifest: manifest['typeOverrides'][0].update(
                    {'hasErrorStub': False, 'exitCode': 0, 'timedOut': False}))
        self.edit_manifest(report, lambda manifest: manifest.update(typeOverrides=[]))
        with self.assertRaisesRegex(RecoveredErrorStub, 'no clean fallback'):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')

    def test_fallback_text_is_scanned_for_stub_markers(self):
        report = self.failed_widget()
        self.rewrite(report, 'type-fallback/0000.cs', 'public class Widget<T> {\n' + STUB + '}\n')
        with self.assertRaises(RecoveredErrorStub):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')
        self.rewrite(report, 'type-fallback/0000.cs', '')
        with self.assertRaises(RecoveredErrorStub):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')

    def test_recorded_diagnostic_is_refused_without_a_current_marker(self):
        report = self.recover({'Example/Widget.cs': 'public class Widget {}\n'})
        self.edit_manifest(report, lambda manifest: manifest['decompilerDiagnostics'].append(
            {'file': 'project/Example/Widget.cs', 'line': 1, 'message': 'recorded by an earlier marker definition'}))
        with self.assertRaises(RecoveredErrorStub):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')

    def test_changed_files_and_identities_are_hash_mismatches(self):
        report = self.recover({'Example/Widget.cs': 'public class Widget {}\n', 'Example/Other.cs': 'public class Other {}\n'})
        directory = Path(report['directory'])
        widget = directory / 'project/Example/Widget.cs'
        widget.write_text('public class Widget { int changed; }\n')
        with self.assertRaisesRegex(RecoveredHashMismatch, 'manifest hash'):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')
        widget.unlink()
        with self.assertRaisesRegex(RecoveredHashMismatch, 'unavailable'):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Widget')
        other = directory / 'project/Example/Other.cs'
        outside = self.root / 'Other.cs'
        outside.write_bytes(other.read_bytes())
        other.unlink()
        other.symlink_to(outside)
        with self.assertRaisesRegex(RecoveredHashMismatch, 'unavailable'):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Other')
        other.unlink()
        outside.rename(other)
        self.edit_manifest(report, lambda manifest: manifest.update(
            files=[item for item in manifest['files'] if item['path'] != 'project/Example/Other.cs']))
        with self.assertRaisesRegex(RecoveredHashMismatch, 'not recorded'):
            RecoveredAssembly(self.index, source_path=MAIN).source('Example.Other')
        (self.root / 'Game.dll').write_bytes(b'changed assembly')
        with self.assertRaisesRegex(RecoveredHashMismatch, 'provenance'):
            RecoveredAssembly(self.index, source_path=MAIN).verify_assembly()
        self.write_index([{**report, 'assemblySHA256': '0' * 64}])
        with self.assertRaisesRegex(RecoveredHashMismatch, 'identity'):
            RecoveredAssembly(self.index, source_path=MAIN)

    def test_missing_assemblies_and_types_are_missing(self):
        report = self.recover({'Example/Widget.cs': 'public class Widget {}\n'})
        assembly = RecoveredAssembly(self.index, source_path=MAIN)
        for name in ['Example.Absent', 'Widget', 'Other.Widget']:
            with self.subTest(type=name), self.assertRaises(MissingRecoveredSource):
                assembly.source(name)
        with self.assertRaises(MissingRecoveredSource):
            RecoveredAssembly(self.index, source_path='CharaStudio_Data/Managed/Assembly-CSharp.dll')
        with self.assertRaises(MissingRecoveredSource):
            RecoveredAssembly(self.index, sha256='0' * 64)
        self.assertEqual(assembly.directory, Path(report['directory']))

    def test_ambiguous_files_fallbacks_and_generations_are_refused(self):
        report = self.recover({'A.B/C.cs': 'class C {}\n', 'A/B/C.cs': 'class C {}\n'})
        with self.assertRaisesRegex(AmbiguousRecoveredSource, 'selected-project files'):
            RecoveredAssembly(self.index, source_path=MAIN).source('A.B.C')
        other = self.recover({'A/B/C.cs': 'class C {}\n'}, tool='v2')
        self.write_index([report, other])
        with self.assertRaisesRegex(AmbiguousRecoveredSource, 'several generations'):
            RecoveredAssembly(self.index, source_path=MAIN)
        self.write_index([report, report])
        self.assertEqual(RecoveredAssembly(self.index, source_path=MAIN).directory, Path(report['directory']))
        arity = self.recover({'Example/Widget.cs': STUB}, failures=['Example.Widget`1.Run', 'Example.Widget`2.Run'],
                             typedefs=[{'Namespace': 'Example', 'Name': 'Widget`1'}, {'Namespace': 'Example', 'Name': 'Widget`2'}],
                             fallbacks={'Example.Widget`1': 'class Widget<T> {}\n', 'Example.Widget`2': 'class Widget<T, U> {}\n'},
                             tool='v3')
        self.assertEqual(arity['status'], 'recovered')
        assembly = RecoveredAssembly(self.index, source_path=MAIN)
        with self.assertRaisesRegex(AmbiguousRecoveredSource, 'type fallbacks'):
            assembly.source('Example.Widget')
        self.assertEqual(assembly.source('Example.Widget`2').text, 'class Widget<T, U> {}\n')

    def test_unreadable_or_inconsistent_index_is_a_manifest_error(self):
        report = self.recover({'Example/Widget.cs': 'public class Widget {}\n'})
        for content in ['{', '[]', '{}', json.dumps({'assemblies': [{'sourcePaths': MAIN}]})]:
            with self.subTest(content=content):
                self.index.write_text(content)
                with self.assertRaises(RecoveryManifestError):
                    RecoveredAssembly(self.index, source_path=MAIN)
        self.write_index([{**report, 'selectedProject': '../project'}])
        with self.assertRaisesRegex(RecoveryManifestError, 'different projects'):
            RecoveredAssembly(self.index, source_path=MAIN)
        with self.assertRaises(TypeError):
            RecoveredAssembly(self.index, source_path=MAIN, sha256=report['assemblySHA256'])


class ConsumerTests(RecoveryTree):
    """Real generators read only manifest-selected source and refuse stubs."""

    def firstpass(self, project, **options):
        return self.recover(project, source_path=resolver.FIRSTPASS, name='Firstpass.dll', **options)

    def test_trigonometric_ik_evidence_refuses_a_primary_stub_the_old_check_missed(self):
        quatools = 'namespace RootMotion { public static class QuaTools {} }\n'
        # The earlier consumer only looked for "Error decompiling".
        self.firstpass({'RootMotion.FinalIK/IKSolverTrigonometric.cs': 'class IKSolverTrigonometric {\n' + STUB + '}\n',
                        'RootMotion/QuaTools.cs': quatools})
        with self.assertRaises(RecoveredErrorStub):
            trigonometric_ik_contract.evidence(self.index)
        report = self.firstpass({'RootMotion.FinalIK/IKSolverTrigonometric.cs': STUB, 'RootMotion/QuaTools.cs': quatools},
                                failures=['RootMotion.FinalIK.IKSolverTrigonometric.Solve'], tool='v2',
                                typedefs=[{'Namespace': 'RootMotion.FinalIK', 'Name': 'IKSolverTrigonometric'}],
                                fallbacks={'RootMotion.FinalIK.IKSolverTrigonometric': 'class IKSolverTrigonometric {}\n'})
        evidence = trigonometric_ik_contract.evidence(self.index)
        directory = Path(report['directory'])
        self.assertEqual(evidence, {'assemblySHA256': report['assemblySHA256'], 'files': [
            {'type': 'RootMotion.FinalIK.IKSolverTrigonometric', 'path': str(directory / 'type-fallback/0000.cs'),
             'sha256': sha(b'class IKSolverTrigonometric {}\n')},
            {'type': 'RootMotion.QuaTools', 'path': str(directory / 'project/RootMotion/QuaTools.cs'), 'sha256': sha(quatools.encode())}]})

    def handmade(self, sha256, files, config):
        """Generation keyed by a pinned assembly hash, recorded as recover_managed.py records it."""
        directory = self.root / 'output' / sha256 / config
        for relative, text in files.items():
            (directory / relative).parent.mkdir(parents=True, exist_ok=True)
            (directory / relative).write_text(text)
        inventory, diagnostics = recovery.inventory_tree(directory)
        summary = {'assemblySHA256': sha256, 'status': 'partial' if diagnostics else 'recovered', 'selectedProject': 'project',
                   'sourcePaths': []}
        (directory / 'manifest.json').write_text(json.dumps({
            'identity': {'assemblySHA256': sha256}, 'summary': summary, 'files': inventory, 'decompilerDiagnostics': diagnostics,
            'primaryDecompilerErrors': [], 'typeOverrides': []}))
        return {'directory': str(directory), **summary}

    def test_card_roundtrip_evidence_uses_the_indexed_generation_not_a_directory_glob(self):
        main, firstpass = '0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5', \
            'ca572fff8740bbcd58d549723c80b0088d6676611eae2ab91624f460739aea10'
        names = ['ChaFileCoordinate', 'ChaFileFace', 'ChaFileBody', 'ChaFileHair', 'ChaFileClothes', 'ChaFileAccessory', 'ChaFileMakeup']
        clean = {f'project/{name}.cs': f'public class {name} {{}}\n' for name in names}
        # The earlier consumer took the first sorted generation directory.
        stale = self.handmade(main, {**clean, 'project/ChaFileFace.cs': STUB}, 'a' * 64)
        current = self.handmade(main, clean, 'b' * 64)
        color = self.handmade(firstpass, {'project/MessagePack.Unity/ColorFormatter.cs': 'class ColorFormatter {}\n'}, 'c' * 64)
        self.write_index([current, color])
        with patch.object(card_roundtrip, 'ROOT', self.root):
            evidence = card_roundtrip.managed_evidence(self.index)
            self.assertEqual([item['path'] for item in evidence],
                             [f'output/{main}/{"b" * 64}/project/{name}.cs' for name in names] +
                             [f'output/{firstpass}/{"c" * 64}/project/MessagePack.Unity/ColorFormatter.cs'])
            self.assertEqual({item['assemblySHA256'] for item in evidence}, {main, firstpass})
            self.write_index([stale, color])
            with self.assertRaises(RecoveredErrorStub):
                card_roundtrip.managed_evidence(self.index)

    def test_full_body_oracle_copies_nothing_when_one_source_is_a_stub(self):
        names = [('RootMotion.FinalIK', name) for name in studio_fullbody_oracle.SOLVER_FILES] + \
                [('RootMotion', 'V3Tools'), ('RootMotion', 'QuaTools')]
        project = {f'{folder}/{name}.cs': f'namespace {folder} {{ class {name} {{}} }}\r\n' for folder, name in names}
        destination = self.root / 'recovered'
        destination.mkdir()
        self.firstpass({**project, 'RootMotion.FinalIK/IKMapping.cs': STUB})
        with self.assertRaises(RecoveredErrorStub):
            studio_fullbody_oracle.copy_sources(self.index, destination)
        self.assertEqual(os.listdir(destination), [])
        report = self.firstpass(project, tool='v2')
        evidence = studio_fullbody_oracle.copy_sources(self.index, destination)
        self.assertEqual(len(evidence), 14)
        for folder, name in names:
            source = Path(report['directory']) / 'project' / folder / (name + '.cs')
            # Copied byte for byte, including CRLF line ends.
            self.assertEqual((destination / (name + '.cs')).read_bytes(), source.read_bytes())
            self.assertIn({'path': str(source), 'sha256': sha(source.read_bytes())}, evidence)


    def test_studio_animation_contract_hashes_the_indexed_studio_types_and_refuses_a_stub(self):
        oci = ('namespace Studio { class OCIChar { void Apply() { charInfo.animBody.speed = value; '
               'charInfo.setAnimatorParamFloat("motion", oiCharInfo.animePattern); charAnimeCtrl.Play(value3.clip, _normalizedTime); '
               'charInfo.AnimPlay(value3.clip); oiCharInfo.animeNormalizedTime = currentAnimatorStateInfo.normalizedTime; } } }\r\n')
        loop = ('namespace Studio { class CharAnimeCtrl { void LateUpdate() { if (!currentAnimatorStateInfo.loop && '
                'currentAnimatorStateInfo.normalizedTime >= 1f) animator.Play(nameHadh, 0, 0f); } } }\n')
        project = {'Studio/OCIChar.cs': oci, 'Studio/CharAnimeCtrl.cs': loop,
                   'Studio/AddObjectFemale.cs': 'namespace Studio { class AddObjectFemale {} }\n',
                   'Studio/AddObjectMale.cs': 'namespace Studio { class AddObjectMale {} }\n'}
        studio = {'source_path': resolver.CHARA_STUDIO, 'name': 'Studio.dll'}
        # The earlier generator hashed whatever files a --source directory held.
        self.recover({**project, 'Studio/AddObjectMale.cs': 'namespace Studio { class AddObjectMale {\n' + STUB + '} }\n'}, **studio)
        with self.assertRaises(RecoveredErrorStub):
            studio_animation_contract.contract(self.index)
        self.recover(project, tool='v2', **studio)
        # Same keys as before the move, hashed over the recorded bytes (CRLF kept).
        self.assertEqual(studio_animation_contract.contract(self.index)['sourceHashes'],
                         {f'{name}.cs': sha(project[name.replace('.', '/') + '.cs'].encode())
                          for name in studio_animation_contract.SOURCES})


if __name__ == '__main__':
    unittest.main()
