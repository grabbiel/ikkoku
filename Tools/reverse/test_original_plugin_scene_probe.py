"""Plug-in scene probe driver framing (phase B); VM calls are mocked, so no VM or private data is needed."""
import hashlib, json, re, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import original_plugin_scene_probe as probe
from original_character_probe import PLAYER_SETUP

ROOT_A = r'C:\Temp\IkkokuShaderProbe-' + ('a' * 32)
ZIPMOD = {'name': '[E625] Example v1.zipmod', 'sha256': 'b' * 64}
INPUTS = ['fixture.png', 'fixture-nil.png', 'corpus.txt'] + ['ours-%s.png' % n for n in range(7)]


def script(**changes):
    args = dict(root=ROOT_A, base='http://10.211.55.2:1/token/', wait_seconds=1800, survey_seconds=900,
                survey_file_bytes=1024, zipmod=ZIPMOD, inputs=INPUTS)
    args.update(changes)
    return probe.reload_script(**args)


class ReloadScriptTests(unittest.TestCase):
    def test_rejects_unknown_roots_bounds_zipmods_and_input_names(self):
        for changes in ({'root': r'C:\Illusion\Koikatsu'}, {'wait_seconds': 0}, {'survey_file_bytes': -1},
                        {'zipmod': {'name': r'..\x.zipmod', 'sha256': 'b' * 64}}, {'zipmod': {'name': 'x.zipmod', 'sha256': 'B' * 64}},
                        {'inputs': ['../run.ps1']}):
            with self.subTest(changes=changes), self.assertRaises(ValueError): script(**changes)

    def test_reads_the_install_only_where_expected(self):
        body = script().replace(PLAYER_SETUP, '')
        uses = re.findall(r'[^;\n]*\$original[^;\n]*', body)
        allowed = (r"^\$original='C:\\Illusion\\Koikatsu'$",
                   r'^function Targets\{try\{\[ordered\]@\{abdata=\(Tree "\$original\\abdata"\)$',
                   r'^CharaStudio_Data=\(Tree "\$original\\CharaStudio_Data"\)\}\}catch\{.*$',
                   r'^\$src=Join-Path "\$original\\BepInEx\\plugins" \$e\[0\]$',
                   r'^\$mods=@\(Get-ChildItem -LiteralPath "\$original\\mods" -Recurse -File .*$',
                   r'^\[IO\.File\]::WriteAllText\("\$in\\survey\.txt","\$original\\UserData\\studio\\scene`n.*$',
                   r'^\$cfg="\$original\\BepInEx\\config\\com\.joan6694\.kkplugins\.kkpe\.cfg"$')
        for use in uses:
            with self.subTest(use=use): self.assertTrue(any(re.match(p, use.strip()) for p in allowed), use)
        # The KKPE config is probed, hashed and read, nothing else.
        self.assertEqual(sorted(re.findall(r'[\w-]+ (?:-LiteralPath )?\$cfg\b', body)),
                         ['Get-Content -LiteralPath $cfg', 'Sha $cfg', 'Test-Path -LiteralPath $cfg'])

    def test_writes_only_into_the_private_root(self):
        body = script()
        self.assertEqual(re.findall(r'-Destination ([^\s;]+)', body), ['$dst', '$copy'])
        self.assertIn(r'$dst=Join-Path $p $e[0]', body); self.assertIn(r'$copy="$root\mods\$($mods[0].Name)"', body)
        self.assertIn(r'$p="$root\BepInEx\plugins";$out="$p\reload";$in="$p\reload-input"', body)
        self.assertEqual(re.findall(r'Fetch \$n "([^"]+)"', body), [r'$in\$n', r'$root\$n'])
        self.assertEqual(re.findall(r'Remove-Item -LiteralPath (\S+)', body), ['$root'])
        own = body.replace(PLAYER_SETUP, '')
        self.assertEqual(re.findall(r'WriteAllText\("([^"]+)"', own), [r'$in\survey.txt'])
        self.assertEqual(re.findall(r'New-Item -ItemType Directory ([^\s|]+)', own), ['$out,$in', '(Split-Path', r'"$root\mods"'])
        self.assertIn(r'Copy-Item -LiteralPath "$root\$n" "$out\$(Split-Path $n -Leaf)"', own)
        self.assertIn(r'$z="$root\reload.zip"', own)
        self.assertIn(r"""'-logFile',"$root\unity.log")""", own)

    def test_scans_junction_targets_around_setup_and_cleanup(self):
        body = script()
        order = [body.index(s) for s in ('$r.junctionTargetsBefore=Targets', 'if($r.junctionTargetsBefore.error){throw', PLAYER_SETUP,
                                         'Start-Process -FilePath "$root\\CharaStudio.exe"', 'finally{', 'cmd /c rmdir',
                                         'Remove-Item -LiteralPath $root', '$r.junctionTargetsAfter=Targets', '$r.junctionTargetsChanged=')]
        self.assertEqual(order, sorted(order))
        # A junction that does not go away keeps the root, so nothing is deleted through it.
        self.assertIn("if($kept.Count){$r.cleanupError='junctions not removed: '", body)


class FakeEndpoint:
    def __init__(self, address, files, upload): self.files = files; self.base = 'http://host/token/'; self.upload = None
    def __enter__(self): return self
    def __exit__(self, *exc): return False


class RunBTests(unittest.TestCase):
    def folders(self, tmp):
        local = Path(tmp) / '.local'; phase_a = local / 'phase-a'; inputs = local / 'inputs'
        for folder in (phase_a, inputs): folder.mkdir(parents=True)
        (phase_a / 'run.json').write_text(json.dumps({'guest': {'zipmod': ZIPMOD}}))
        (phase_a / 'fixture.png').write_bytes(b'fixture')
        (inputs / 'fixture-nil.png').write_bytes(b'nil')
        for n in range(7): (inputs / ('ours-%s.png' % n)).write_bytes(b'ours-%d' % n)
        corpus = local / 'corpus.txt'; corpus.write_bytes(b'corpus')
        return local, phase_a, inputs, corpus

    def run_b(self, tmp, guest):
        local, phase_a, inputs, corpus = self.folders(tmp)
        done = subprocess.CompletedProcess([], 0, stdout=json.dumps(guest), stderr='')
        with patch('original_plugin_scene_probe.local_roots', return_value=[local.resolve()]),\
             patch('original_plugin_scene_probe.Endpoint', FakeEndpoint),\
             patch('original_plugin_scene_probe.guarded', return_value=0),\
             patch('original_plugin_scene_probe.errno_count', return_value=0),\
             patch('original_plugin_scene_probe.fresh_root', return_value=ROOT_A),\
             patch('original_plugin_scene_probe.subprocess.run', return_value=done) as run:
            result = probe.run_b('vm', local / 'phase-b', 0, inputs, corpus, phase_a)
        return local / 'phase-b', result, run

    def test_records_inputs_sources_and_junction_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            guest = {'junctionTargetsChanged': False, 'junctionTargetsBefore': {'abdata': {'files': 1}}, 'removed': True,
                     'kkpeConfig': {'exists': True, 'value': 'true'}}
            output, result, run = self.run_b(tmp, guest)
            record = json.loads((output / 'run.json').read_text())
            self.assertEqual(sorted(record['inputs']), sorted(INPUTS))
            self.assertEqual(record['inputs']['fixture.png'], hashlib.sha256(b'fixture').hexdigest())
            self.assertEqual(sorted(record['sources']), sorted(('PluginSceneProbe.cs',) + probe.SOURCES_B))
            self.assertEqual(record['zipmod'], ZIPMOD)
            self.assertEqual(sorted(p.name for p in (output / 'source').iterdir()), sorted(record['sources']))
            self.assertNotIn('http://host/token/', (output / 'run.ps1').read_text())
            self.assertIs(result['junctionTargetsChanged'], False); self.assertEqual(result['kkpeConfig']['value'], 'true')
            self.assertEqual(run.call_args.args[0][:3], ['prlctl', 'exec', 'vm'])

    def test_refuses_a_guest_input_that_differs(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Guest input hash differs: corpus.txt'):
            self.run_b(tmp, {'inputs': {'corpus.txt': '0' * 64}})

    def test_refuses_outputs_outside_local_and_reused_folders(self):
        with tempfile.TemporaryDirectory() as tmp:
            local, phase_a, inputs, corpus = self.folders(tmp)
            with patch('original_plugin_scene_probe.local_roots', return_value=[local.resolve()]):
                with self.assertRaisesRegex(ValueError, 'under .local'):
                    probe.run_b('vm', Path(tmp) / 'elsewhere', 0, inputs, corpus, phase_a)
                (local / 'phase-b').mkdir(); (local / 'phase-b' / 'run.json').write_text('{}')
                with self.assertRaisesRegex(RuntimeError, 'new output folder'):
                    probe.run_b('vm', local / 'phase-b', 0, inputs, corpus, phase_a)


COLLIDER = {'name': '[KKPE] Collider.zipmod', 'sha256': 'c' * 64}
INPUTS_C = ['fixture.png', 'author-card.png', 'phase.txt']
INPUTS_D = ['fixture.png', 'card-link.png', 'edit-delete.png', 'ours-delete.png', 'card-link-int32.png', 'corpus.txt', 'phase.txt']


def rewrite(phase='C', **changes):
    args = dict(root=ROOT_A, base='http://10.211.55.2:1/token/', phase=phase, wait_seconds=1800, zipmod=ZIPMOD,
                inputs=INPUTS_C if phase == 'C' else INPUTS_D, collider=None if phase == 'C' else COLLIDER)
    args.update(changes)
    return probe.rewrite_script(**args)


class RewriteScriptTests(unittest.TestCase):
    def test_rejects_unknown_roots_phases_bounds_zipmods_and_input_names(self):
        for phase, changes in (('C', {'root': r'C:\Illusion\Koikatsu'}), ('E', {}), ('C', {'wait_seconds': 0}), ('C', {'scan_seconds': -1}),
                               ('D', {'survey_file_bytes': 0}), ('C', {'zipmod': {'name': r'..\x.zipmod', 'sha256': 'b' * 64}}),
                               ('D', {'collider': {'name': 'x.zipmod', 'sha256': 'C' * 64}}), ('C', {'collider': COLLIDER}),
                               ('D', {'inputs': ['../run.ps1']})):
            with self.subTest(phase=phase, changes=changes), self.assertRaises(ValueError): rewrite(phase, **changes)

    def test_reads_the_install_only_where_expected(self):
        allowed = (r"^\$original='C:\\Illusion\\Koikatsu'$",
                   r'^function Targets\{try\{\[ordered\]@\{abdata=\(Tree "\$original\\abdata"\)$',
                   r'^CharaStudio_Data=\(Tree "\$original\\CharaStudio_Data"\)\}\}catch\{.*$',
                   r'^function Mod\(\$name,\$sha\)\{\$m=@\(Get-ChildItem -LiteralPath "\$original\\mods" -Recurse -File .*$',
                   r'^\$src=Join-Path "\$original\\BepInEx\\plugins" \$e\[0\]$',
                   r'^foreach\(\$m in @\(Get-ChildItem -LiteralPath "\$original\\mods" -Recurse -File .*$',
                   r'^foreach\(\$n in @\(.*\)\)\{\$cfg="\$original\\BepInEx\\config\\\$n"$',
                   r'^foreach\(\$f in @\(Get-ChildItem -LiteralPath "\$original\\UserData\\studio\\scene" -Recurse -File .*$',
                   r'^\[IO\.File\]::WriteAllText\("\$in\\survey\.txt","\$original\\UserData\\studio\\scene`n.*$')
        for phase in ('C', 'D'):
            body = rewrite(phase).replace(PLAYER_SETUP, '')
            for use in re.findall(r'[^;\n]*\$original[^;\n]*', body):
                with self.subTest(phase=phase, use=use): self.assertTrue(any(re.match(p, use.strip()) for p in allowed), use)
        body = rewrite('C')
        # Config files are probed, hashed, sized and read; the scenes and zipmods are listed, opened read-only and hashed.
        self.assertEqual(sorted(re.findall(r'[\w-]+ (?:-LiteralPath )?\$cfg\b', body)),
                         ['Get-Content -LiteralPath $cfg', 'Get-Item -LiteralPath $cfg', 'Sha $cfg', 'Test-Path -LiteralPath $cfg'])
        self.assertEqual(re.findall(r'\[IO\.File\]::ReadAllBytes\(([^)]+)\)', body), ['$f.FullName'])
        self.assertEqual(re.findall(r'ZipFile\]::OpenRead\(([^)]+)\)', body), ['$m.FullName'])
        self.assertEqual(sorted(probe.CONFIGS), sorted(re.findall(r"'([\w.]+\.cfg)'", body)))

    def test_writes_only_into_the_private_root(self):
        for phase in ('C', 'D'):
            body = rewrite(phase); own = body.replace(PLAYER_SETUP, '')
            with self.subTest(phase=phase):
                self.assertEqual(re.findall(r'-Destination ([^\s;]+)', body), ['$copy', '$dst'] + (['"$out\\largest-kkpe.png"'] if phase == 'C' else []))
                self.assertIn(r'$copy="$root\mods\$($m[0].Name)"', body); self.assertIn(r'$dst=Join-Path $p $e[0]', body)
                self.assertIn(r'$p="$root\BepInEx\plugins";$out="$p\reload";$in="$p\reload-input"', body)
                self.assertEqual(re.findall(r'Fetch \$n "([^"]+)"', body), [r'$in\$n', r'$root\$n'])
                self.assertEqual(re.findall(r'Remove-Item -LiteralPath (\S+)', body), ['$root'])
                self.assertEqual(re.findall(r'WriteAllText\("([^"]+)"', own), [r'$in\survey.txt'] if phase == 'D' else [])
                self.assertEqual(re.findall(r'New-Item -ItemType Directory ([^\s|]+)', own), [r'$out,$in,"$root\mods"', '(Split-Path'])
                self.assertIn(r"""'-logFile',"$root\unity.log")""", own)
                order = [body.index(x) for x in ('$r.junctionTargetsBefore=Targets', PLAYER_SETUP, 'Start-Process -FilePath', 'finally{\n$left=Own',
                                                 'cmd /c rmdir', 'Remove-Item -LiteralPath $root', '$r.junctionTargetsAfter=Targets')]
                self.assertEqual(order, sorted(order))

    def test_phase_d_copies_phase_c_collider_and_phase_c_finds_its_own(self):
        self.assertIn("$r.collider=Mod '[KKPE] Collider.zipmod' '" + 'c' * 64 + "'", rewrite('D'))
        self.assertNotIn('$r.collider=Mod', rewrite('D', collider=None))
        self.assertIn("$c[6].Trim() -ceq 'Collider'", rewrite('C'))
        self.assertIn('OriginalPluginRewriteProbe.cs', rewrite('C'))


class RunCDTests(unittest.TestCase):
    def guest(self, record_inputs):
        return {'junctionTargetsChanged': False, 'removed': True, 'collider': {'zipmod': COLLIDER},
                'sources': None, 'inputs': record_inputs}

    def run_phase(self, tmp, phase):
        local = Path(tmp) / '.local'; phase_a = local / 'phase-a'; phase_c = local / 'phase-c'; inputs = local / 'inputs'
        for folder in (phase_a, phase_c, inputs): folder.mkdir(parents=True)
        (phase_a / 'run.json').write_text(json.dumps({'guest': {'zipmod': ZIPMOD}}))
        (phase_a / 'fixture.png').write_bytes(b'fixture-a')
        card = local / 'card.png'; card.write_bytes(b'card')
        (phase_c / 'run.json').write_text(json.dumps({'zipmod': ZIPMOD, 'guest': {'collider': {'zipmod': COLLIDER}}}))
        for name in ('fixture.png', 'card-link.png', 'edit-delete.png', 'edit-duplicate.png', 'fixture-lc.png'): (phase_c / name).write_bytes(name.encode())
        for name in ('ours-delete.png', 'card-link-int32.png'): (inputs / name).write_bytes(name.encode())
        corpus = local / 'corpus.txt'; corpus.write_bytes(b'corpus')
        done = subprocess.CompletedProcess([], 0, stdout=json.dumps(self.guest({})), stderr='')
        with patch('original_plugin_scene_probe.local_roots', return_value=[local.resolve()]),\
             patch('original_plugin_scene_probe.Endpoint', FakeEndpoint),\
             patch('original_plugin_scene_probe.guarded', return_value=0),\
             patch('original_plugin_scene_probe.errno_count', return_value=0),\
             patch('original_plugin_scene_probe.fresh_root', return_value=ROOT_A),\
             patch('original_plugin_scene_probe.subprocess.run', return_value=done):
            if phase == 'C': result = probe.run_c('vm', local / 'out', 0, phase_a, card)
            else: result = probe.run_d('vm', local / 'out', 0, phase_c, inputs, corpus)
        return json.loads((local / 'out' / 'run.json').read_text()), result

    def test_phase_c_sends_the_fixture_card_and_phase(self):
        with tempfile.TemporaryDirectory() as tmp:
            record, result = self.run_phase(tmp, 'C')
            self.assertEqual(sorted(record['inputs']), sorted(INPUTS_C))
            self.assertEqual(record['inputs']['phase.txt'], hashlib.sha256(b'C').hexdigest())
            self.assertEqual(record['zipmod'], ZIPMOD); self.assertIsNone(record['collider'])
            self.assertEqual(sorted(record['sources']), sorted(('OriginalPluginRewriteProbe.cs',) + probe.SOURCES_B))
            self.assertEqual(result['collider'], {'zipmod': COLLIDER})

    def test_phase_d_sends_phase_c_scenes_our_exports_and_the_collider(self):
        with tempfile.TemporaryDirectory() as tmp:
            record, _ = self.run_phase(tmp, 'D')
            self.assertEqual(sorted(record['inputs']), sorted(['fixture.png', 'card-link.png', 'edit-delete.png', 'edit-duplicate.png',
                                                               'fixture-lc.png', 'ours-delete.png', 'card-link-int32.png', 'corpus.txt', 'phase.txt']))
            self.assertEqual(record['collider'], COLLIDER)
            self.assertEqual(record['inputs']['phase.txt'], hashlib.sha256(b'D').hexdigest())


if __name__ == '__main__':
    unittest.main()
