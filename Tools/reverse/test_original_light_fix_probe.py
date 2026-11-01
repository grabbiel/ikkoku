"""Light-fix probe driver framing (phase E); VM calls are mocked, so no VM or private data is needed."""
import hashlib, json, re, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import original_light_fix_probe as probe
from original_character_probe import PLAYER_SETUP

ROOT_A = r'C:\Temp\IkkokuShaderProbe-' + ('a' * 32)
SCENES = [('1' * 64, 1000), ('2' * 64, 2000)]
INPUTS = ['guids.txt', 'resave.txt', 'corpus.txt']


def script(**changes):
    args = dict(root=ROOT_A, base='http://10.211.55.2:1/token/', scenes=SCENES, wait_fix=2700, wait_nofix=1200,
                survey_seconds=900, survey_file_bytes=1024, mods_max_bytes=4096, scan_seconds=600, inputs=INPUTS)
    args.update(changes)
    return probe.phase_script(**args)


def report(rows=None):
    rows = rows if rows is not None else [
        dict(sha256='1' * 64, bytes=1000, recordsNamingNestedLights=3, recordsNamingVanillaDroppedLights=2, sideloaderGUIDs=['b.mod', 'a.mod']),
        dict(sha256='1' * 64, bytes=1000, recordsNamingNestedLights=3, recordsNamingVanillaDroppedLights=2, sideloaderGUIDs=['b.mod']),
        dict(sha256='2' * 64, bytes=500, recordsNamingNestedLights=1, recordsNamingVanillaDroppedLights=1, sideloaderGUIDs=['c.mod']),
        dict(sha256='3' * 64, bytes=100, recordsNamingNestedLights=0, sideloaderGUIDs=['d.mod'])]
    return dict(schemaVersion=1, counts={}, rows=rows)


class PhaseScriptTests(unittest.TestCase):
    def test_rejects_unknown_roots_bounds_scenes_and_input_names(self):
        for changes in ({'root': r'C:\Illusion\Koikatsu'}, {'wait_fix': 0}, {'mods_max_bytes': -1}, {'scenes': []},
                        {'scenes': [('X' * 64, 1)]}, {'scenes': [('1' * 64, 0)]}, {'inputs': ['../run.ps1']}):
            with self.subTest(changes=changes), self.assertRaises(ValueError): script(**changes)

    def test_reads_the_install_only_where_expected(self):
        body = script().replace(PLAYER_SETUP, '')
        uses = re.findall(r'[^;\n]*\$original[^;\n]*', body)
        allowed = (r"^\$original='C:\\Illusion\\Koikatsu'$",
                   r'^function Targets\{try\{\[ordered\]@\{abdata=\(Tree "\$original\\abdata"\)$',
                   r'^CharaStudio_Data=\(Tree "\$original\\CharaStudio_Data"\)\}\}catch\{.*$',
                   r'^\$src=Join-Path "\$original\\BepInEx\\plugins" \$e\[0\]$',
                   r'^foreach\(\$f in @\(Get-ChildItem -LiteralPath "\$original\\UserData\\studio\\scene" -Recurse -File .*$',
                   r'^foreach\(\$m in @\(Get-ChildItem -LiteralPath "\$original\\mods" -Recurse -File .*$',
                   r'^\[IO\.File\]::WriteAllText\("\$in\\survey\.txt","\$original\\UserData\\studio\\scene`n.*$')
        for use in uses:
            with self.subTest(use=use): self.assertTrue(any(re.match(p, use.strip()) for p in allowed), use)
        # Scenes and zipmods are only hashed, opened read-only and copied.
        self.assertIn('[IO.Compression.ZipFile]::OpenRead($m.FullName)', body)
        self.assertEqual(re.findall(r'Copy-Item -LiteralPath (\$\w+\.FullName)', body), ['$f.FullName', '$m.FullName'])

    def test_writes_only_into_the_private_root(self):
        body = script()
        self.assertEqual(re.findall(r'-Destination ([^\s;]+)', body), ['$dst', '$copy', '$copy'])
        self.assertIn(r'$dst=Join-Path $p $e[0]', body)
        self.assertIn(r'$copy="$in\scene-$($h.Substring(0,12)).png"', body)
        self.assertIn(r'$copy="$root\mods\m$($r.mods.copied).zipmod"', body)
        self.assertIn(r'$p="$root\BepInEx\plugins";$out="$p\reload";$in="$p\reload-input"', body)
        self.assertEqual(re.findall(r'Fetch \$n "([^"]+)"', body), [r'$in\$n', r'$root\$n'])
        self.assertEqual(re.findall(r'Remove-Item -LiteralPath (\S+)', body), ['$fix', '$root'])
        self.assertIn(r"$fix=Join-Path $p 'IllusionFixes\KK_Fix_UnlimitedMapLights.dll'", body)
        own = body.replace(PLAYER_SETUP, '')
        self.assertEqual(re.findall(r'WriteAllText\("([^"]+)"', own), [r'$in\survey.txt', r'$in\phase.txt', r'$in\phase.txt'])
        self.assertEqual(re.findall(r"""'-logFile',"([^"]+)"\)""", own), [r'$root\unity-fix.log', r'$root\unity-nofix.log'])
        self.assertIn(r'$z="$root\reload.zip"', own)

    def test_launches_with_the_fix_then_without_it(self):
        body = script()
        order = [body.index(s) for s in ('$r.junctionTargetsBefore=Targets', PLAYER_SETUP, "KK_Fix_UnlimitedMapLights.dll','" + probe.LIGHT_FIX[1],
                                         r"""WriteAllText("$in\phase.txt",'fix')""", 'Start-Process -FilePath "$root\\CharaStudio.exe"',
                                         "$r.launches['fix']=$run", 'Remove-Item -LiteralPath $fix', r"""WriteAllText("$in\phase.txt",'nofix')""",
                                         "$r.launches['nofix']=$run", '}catch{$r.error=$_.ToString()}\nfinally{', 'cmd /c rmdir', 'Remove-Item -LiteralPath $root',
                                         '$r.junctionTargetsAfter=Targets', '$r.junctionTargetsChanged=')]
        self.assertEqual(order, sorted(order))
        self.assertEqual(body.count('Start-Process -FilePath "$root\\CharaStudio.exe"'), 2)
        self.assertIn("if(-not $r.lightFixRemoved){throw", body)
        self.assertIn("if($kept.Count){$r.cleanupError='junctions not removed: '", body)

    def test_finds_every_scene_and_bounds_the_mods(self):
        body = script()
        self.assertIn("foreach($e in '" + '1' * 64 + ":1000;" + '2' * 64 + ":2000'.Split(';'))", body)
        self.assertIn("foreach($e in '" + '1' * 64 + ":1000'.Split(';'))", script(scenes=SCENES[:1]))
        self.assertIn('if($r.scenes.found -ne $want.Count){throw', body)
        self.assertIn("if($f.Name.StartsWith('._')", body)
        self.assertIn('if($r.mods.copiedBytes+$m.Length -gt 4096){$r.mods.overBound++;continue}', body)
        self.assertIn('if($w.Elapsed.TotalSeconds -gt 600){$r.mods.truncated=$true;break}', body)


class InputTests(unittest.TestCase):
    def test_picks_distinct_nested_light_scenes_their_guids_and_the_smallest_dropping_scene(self):
        files, scenes, resave = probe.inputs_for(report(), b'corpus')
        self.assertEqual(scenes, [('1' * 64, 1000), ('2' * 64, 500)])
        self.assertEqual(files['guids.txt'], b'a.mod\nb.mod\nc.mod\n')
        self.assertEqual(resave, '2' * 64); self.assertEqual(files['resave.txt'], ('2' * 64 + '\n').encode())
        self.assertEqual(files['corpus.txt'], b'corpus')

    def test_refuses_reports_without_scenes_and_unknown_resaves(self):
        with self.assertRaisesRegex(ValueError, 'nested lights'): probe.inputs_for(report([]), b'')
        with self.assertRaisesRegex(ValueError, 'not among'): probe.inputs_for(report(), b'', resave='3' * 64)
        with self.assertRaisesRegex(ValueError, 'GUID'):
            probe.inputs_for(report([dict(sha256='1' * 64, bytes=1, recordsNamingNestedLights=1,
                                          recordsNamingVanillaDroppedLights=1, sideloaderGUIDs=['a\nb'])]), b'')


class FakeEndpoint:
    def __init__(self, address, files, upload): self.files = files; self.base = 'http://host/token/'; self.upload = None
    def __enter__(self): return self
    def __exit__(self, *exc): return False


class RunTests(unittest.TestCase):
    def run_e(self, tmp, guest):
        local = Path(tmp) / '.local'; local.mkdir()
        (local / 'report.json').write_text(json.dumps(report())); (local / 'corpus.txt').write_bytes(b'corpus')
        done = subprocess.CompletedProcess([], 0, stdout=json.dumps(guest), stderr='')
        with patch('original_light_fix_probe.local_roots', return_value=[local.resolve()]),\
             patch('original_light_fix_probe.Endpoint', FakeEndpoint),\
             patch('original_light_fix_probe.guarded', return_value=0),\
             patch('original_light_fix_probe.errno_count', return_value=0),\
             patch('original_light_fix_probe.fresh_root', return_value=ROOT_A),\
             patch('original_light_fix_probe.subprocess.run', return_value=done) as run:
            result = probe.run('vm', local / 'phase-e', 0, local / 'report.json', local / 'corpus.txt')
        return local / 'phase-e', result, run

    def test_records_inputs_sources_scenes_and_plugins(self):
        with tempfile.TemporaryDirectory() as tmp:
            output, result, run = self.run_e(tmp, {'junctionTargetsChanged': False, 'removed': True})
            record = json.loads((output / 'run.json').read_text())
            self.assertEqual(sorted(record['inputs']), sorted(INPUTS))
            self.assertEqual(record['inputs']['corpus.txt'], hashlib.sha256(b'corpus').hexdigest())
            self.assertEqual(sorted(record['sources']), sorted(('OriginalLightFixProbe.cs',) + probe.SOURCES_B))
            self.assertEqual(record['scenes'], [dict(sha256='1' * 64, bytes=1000), dict(sha256='2' * 64, bytes=500)])
            self.assertEqual(record['plugins'][-1]['path'], probe.LIGHT_FIX[0])
            self.assertNotIn('http://host/token/', (output / 'run.ps1').read_text())
            self.assertNotIn('a.mod', (output / 'run.json').read_text())
            self.assertIs(result['junctionTargetsChanged'], False)
            self.assertEqual(run.call_args.args[0][:3], ['prlctl', 'exec', 'vm'])

    def test_refuses_a_guest_input_that_differs_and_reused_folders(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Guest input hash differs: corpus.txt'):
            self.run_e(tmp, {'inputs': {'corpus.txt': '0' * 64}})
        with tempfile.TemporaryDirectory() as tmp:
            local = Path(tmp) / '.local'; (local / 'phase-e').mkdir(parents=True); (local / 'phase-e' / 'run.json').write_text('{}')
            with patch('original_light_fix_probe.local_roots', return_value=[local.resolve()]):
                with self.assertRaisesRegex(ValueError, 'under .local'):
                    probe.run('vm', Path(tmp) / 'elsewhere', 0, local / 'report.json', local / 'corpus.txt')
                with self.assertRaisesRegex(RuntimeError, 'new output folder'):
                    probe.run('vm', local / 'phase-e', 0, local / 'report.json', local / 'corpus.txt')


class SummaryTests(unittest.TestCase):
    def test_compares_survey_four_with_the_prediction(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            for phase in ('fix', 'nofix'): (output / phase).mkdir()
            after = {kind: dict(zip(('all', 'some', 'none'), counts)) for kind, counts in probe.PREDICTION.items()}
            (output / 'fix' / 'survey4.json').write_text(json.dumps(dict(parityMismatches=0, unlimitedLights=True, scenesByEditKindAfter=after,
                                                                       counts=dict(nestedLightsKept=40, nestedLightsDropped=0))))
            rows = [dict(nestedLightsKept=3, itemInfoRecords=5, recordsReached=5, recordsResolved=4, objectsException='none', mapStepReached=1)]
            (output / 'fix' / 'light-fix-trace.json').write_text(json.dumps(dict(cases=dict(loads=rows))))
            stopped = [dict(nestedLightsKept=2, itemInfoRecords=5, recordsReached=2, objectsException='System.Collections.Generic.KeyNotFoundException', mapStepReached=0)]
            (output / 'nofix' / 'light-fix-trace.json').write_text(json.dumps(dict(cases=dict(loads=stopped))))
            summary = probe.summarize(output)
            self.assertTrue(summary['survey4']['matchesPrediction'])
            self.assertEqual(summary['fix']['recordsReached'], 5); self.assertEqual(summary['fix']['scenesStopped'], 0)
            self.assertEqual(summary['nofix']['scenesStopped'], 1); self.assertEqual(summary['nofix']['scenesWithoutMapStep'], 1)
            after['delete'] = dict(all=36, some=20, none=5)
            (output / 'fix' / 'survey4.json').write_text(json.dumps(dict(scenesByEditKindAfter=after)))
            self.assertFalse(probe.summarize(output)['survey4']['matchesPrediction'])


if __name__ == '__main__':
    unittest.main()
