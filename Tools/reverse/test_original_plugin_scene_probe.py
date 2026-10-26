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


if __name__ == '__main__':
    unittest.main()
