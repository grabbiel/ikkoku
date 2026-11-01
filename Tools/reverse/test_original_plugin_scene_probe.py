"""Plug-in scene probe driver framing (phase B); VM calls are mocked, so no VM or private data is needed."""
import hashlib, io, json, re, subprocess, tempfile, unittest, zipfile
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
INPUTS_C = ['fixture.png', 'phase.txt']
INPUTS_D = ['fixture.png', 'card-link.png', 'edit-delete.png', 'ours-delete.png', 'card-link-fixint.png', 'corpus.txt', 'phase.txt']


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
                   r'^if\(\$mf -match .*\)\{\$r\.collider\.list\.manifestInAbdata=\(Test-Path -LiteralPath "\$original\\abdata\\\$mf"\)\}$',
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

    def test_phase_c_records_the_collider_row_read_only(self):
        body = rewrite('C')
        self.assertIn("$r.collider.list=[ordered]@{entry=$x.FullName;row=@($c|ForEach-Object{$_.Trim()})};$mf=$c[4].Trim()", body)
        # The manifest name comes from a mod's list: it is only tested for existence, and only when it is a plain
        # relative name without '..'.
        self.assertEqual(re.findall(r'([\w-]+) -LiteralPath "\$original\\abdata\\\$mf"', body), ['Test-Path'])
        self.assertIn("if($mf -match '^[A-Za-z0-9_][A-Za-z0-9_./-]*$' -and $mf -notmatch '\\.\\.')", body)
        self.assertNotIn('manifestInAbdata', rewrite('D'))


class RunCDTests(unittest.TestCase):
    def guest(self, record_inputs):
        return {'junctionTargetsChanged': False, 'removed': True, 'collider': {'zipmod': COLLIDER},
                'sources': None, 'inputs': record_inputs}

    def run_phase(self, tmp, phase, lone_collider=True):
        local = Path(tmp) / '.local'; phase_a = local / 'phase-a'; phase_c = local / 'phase-c'; inputs = local / 'inputs'
        for folder in (phase_a, phase_c, inputs): folder.mkdir(parents=True)
        (phase_a / 'run.json').write_text(json.dumps({'guest': {'zipmod': ZIPMOD}}))
        (phase_a / 'fixture.png').write_bytes(b'fixture-a')
        (phase_c / 'run.json').write_text(json.dumps({'zipmod': ZIPMOD, 'guest': {'collider': {'zipmod': COLLIDER}}}))
        for name in ('fixture.png', 'card-link.png', 'edit-delete.png', 'edit-duplicate.png') + (('fixture-lc.png',) if lone_collider else ()):
            (phase_c / name).write_bytes(name.encode())
        for name in ('ours-delete.png', 'card-link-fixint.png'): (inputs / name).write_bytes(name.encode())
        corpus = local / 'corpus.txt'; corpus.write_bytes(b'corpus')
        done = subprocess.CompletedProcess([], 0, stdout=json.dumps(self.guest({})), stderr='')
        with patch('original_plugin_scene_probe.local_roots', return_value=[local.resolve()]),\
             patch('original_plugin_scene_probe.Endpoint', FakeEndpoint),\
             patch('original_plugin_scene_probe.guarded', return_value=0),\
             patch('original_plugin_scene_probe.errno_count', return_value=0),\
             patch('original_plugin_scene_probe.fresh_root', return_value=ROOT_A),\
             patch('original_plugin_scene_probe.subprocess.run', return_value=done):
            if phase == 'C': result = probe.run_c('vm', local / 'out', 0, phase_a)
            else: result = probe.run_d('vm', local / 'out', 0, phase_c, inputs, corpus)
        return json.loads((local / 'out' / 'run.json').read_text()), result

    def test_phase_c_sends_the_fixture_and_phase(self):
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
                                                               'fixture-lc.png', 'ours-delete.png', 'card-link-fixint.png', 'corpus.txt', 'phase.txt']))
            self.assertEqual(record['collider'], COLLIDER)
            self.assertEqual(record['inputs']['phase.txt'], hashlib.sha256(b'D').hexdigest())

    def test_phase_d_sends_no_collider_without_the_lone_collider_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            record, _ = self.run_phase(tmp, 'D', lone_collider=False)
            self.assertIsNone(record['collider']); self.assertNotIn('fixture-lc.png', record['inputs'])


def runtime_pins():
    return {name: {'sha256': 'a' * 64, 'bytes': 1} for name in (
        'CharaStudio.exe', 'winhttp.dll', 'doorstop_config.ini', 'BepInEx/core/BepInEx.dll',
        'CharaStudio_Data/Managed/Assembly-CSharp.dll', 'CharaStudio_Data/Managed/UnityEngine.dll',
        'CharaStudio_Data/Managed/mscorlib.dll', '@compiler')}


ORDERED_INPUTS = ['fixture.png', 'fixture.sha256', 'fixture-c.png', 'fixture-c.sha256', 'phase.txt']
PROBE_SOURCE = Path(probe.__file__).with_name('fixtures') / 'OriginalPluginRewriteProbe.cs'


def ordered(**changes):
    return rewrite('OA', **dict(dict(wait_seconds=300, collider=None, inputs=ORDERED_INPUTS, control_seconds=180), **changes))


class OrderedOracleTests(unittest.TestCase):
    def test_cases_match_the_probe(self):
        source = PROBE_SOURCE.read_text()
        table = source.split('OrderedCases={', 1)[1].split('};', 1)[0]
        rows = [re.findall(r'"([^"]*)"', row) for row in re.findall(r'new\[\]\{([^}]*)\}', table)]
        self.assertEqual(tuple(row[0] for row in rows), probe.ORDERED_CASES)
        for row in rows:
            with self.subTest(row=row[0]):
                self.assertIn(row[1], ('a', 'c'))
                self.assertTrue(all(re.fullmatch(r'(delete|duplicate):[A-Z][A-Z0-9]*|add-folder:', op) for op in row[2:]), row)
        # Both of #278's orders, a delete after a duplicate, and a case on each fixture.
        self.assertEqual(rows[0][2:], ['delete:V1', 'duplicate:M3']); self.assertEqual(rows[1][2:], ['duplicate:M3', 'delete:V1'])
        self.assertEqual({row[1] for row in rows}, {'a', 'c'})
        self.assertEqual(tuple(row[0] for row in rows if row[1] == 'c'), probe.ORDERED_FIXTURE_C)

    def test_one_profile_keeps_the_core_plugin_set_and_no_survey(self):
        body = ordered()
        self.assertIn('OriginalPluginRewriteProbe.cs', body)
        self.assertNotIn('survey.txt', body); self.assertNotIn('largestKKPE', body)
        self.assertNotIn('$r.collider', body); self.assertNotIn('$r.configs', body)
        for path, _, _ in probe.PLUGINS_B:
            self.assertNotIn(path, body)
        self.assertIn('$c.WaitForExit(60000)', body)
        self.assertIn('$process.StartTime.ToUniversalTime().Ticks -ne $identity.startTicks', body)
        self.assertIn('$process.Path -cne $identity.path', body)
        self.assertIn('$script:orderedCompiler=$c;$r.compiler=', body)
        self.assertIn('$script:orderedCompilerIdentity=ProcessIdentity $c', body)
        self.assertNotIn('function Own{', body); self.assertNotIn('$left=Own', body)
        self.assertEqual(body.count('ObservePlayerChildren;[void]$x.WaitForExit(250)'), 2)
        self.assertIn("try{OrderedStamp 'cleanup-compiler';StopOwnedCompiler}catch", body)
        self.assertIn("try{OrderedStamp 'cleanup-player';$r.stoppedAtCleanup=StopPlayerOwners}catch", body)
        self.assertIn('$r.compiler.exitCode', body); self.assertIn('$r.playerStartUTC', body)
        self.assertIn('200000', body); self.assertIn('20000', body)
        self.assertNotIn('KKPE.dll', body)

    def test_the_control_player_runs_first_with_its_own_bound_and_hands_over(self):
        body = ordered()
        self.assertEqual(body.count('$x=Start-Process -FilePath "$root\\CharaStudio.exe"'), 2)
        order = [body.index(text) for text in (
            "OrderedStamp 'control-player-start'", '$playerWatch.Elapsed.TotalSeconds -lt 180){', "OrderedStamp 'control-player-drain'",
            "if(-not $r.exited){throw 'Control player did not exit within its bound'}", '$r.control=[ordered]@{phase=\'OB\'',
            "[IO.File]::WriteAllText(\"$in\\phase.txt\",'OA')", "OrderedStamp 'control-complete'", "OrderedStamp 'player-start'",
            '$playerWatch.Elapsed.TotalSeconds -lt 300){', "OrderedStamp 'player-drain'", "OrderedStamp 'capture-logs'",
            "OrderedStamp 'capture-archive'")]
        self.assertEqual(order, sorted(order))
        handoff = body[body.index("OrderedStamp 'control-capture'"):body.index("OrderedStamp 'control-complete'")]
        # The control's outputs and logs move into the upload under control-* flat names, and only there.
        self.assertEqual(re.findall(r'-Destination "([^"]+)"', handoff), [r'$out\control-$(Split-Path $log -Leaf)'])
        self.assertIn("-notlike 'compile.*' -and $f.Name -notlike 'control-*'", handoff)
        self.assertIn("Rename-Item -LiteralPath $f.FullName -NewName ('control-'+$f.Name)", handoff)
        for name in ('processID', 'playerStartUTC', 'playerIdentity', 'exited', 'playerExitCode', 'stopped'):
            self.assertIn('$r.%s=$null' % name, handoff)
        own = body.replace(PLAYER_SETUP, '')
        self.assertEqual(re.findall(r'WriteAllText\("([^"]+)"', own), [r'$in\phase.txt'])
        self.assertEqual(re.findall(r'Remove-Item -LiteralPath (\S+)', body), ['$root'])

    def test_ordered_compiler_keeps_references_separate_and_retains_exit_handles(self):
        body = ordered()
        # csc treats a quote around an entire comma list as one metadata
        # filename (the retained CS0006). Each DLL needs its own option.
        self.assertIn("$referenceArguments=@($refs|ForEach-Object{('/reference:\"'+$_+'\"')})", body)
        self.assertIn('+$referenceArguments+@(', body)
        self.assertNotIn("('/reference:\"'+($refs -join ',')+'\"')", body)
        self.assertLess(body.index('[void]$c.Handle'), body.index('$c.WaitForExit(60000)'))
        self.assertNotIn('$c.Refresh()', body)
        self.assertIn("if($null -eq $c.ExitCode){throw 'Owned compiler exit code is unavailable'}", body)
        self.assertLess(body.index('[void]$x.Handle'), body.index('$x.WaitForExit(250)'))
        self.assertEqual(body.count("if($null -eq $x.ExitCode){throw 'Owned player exit code is unavailable'}"), 2)

    def test_ordered_lifecycle_stamps_survive_cleanup_and_unknown_owners_retain_root(self):
        body = ordered()
        for start, pid, identity, wait in [
            ('$c=Start-Process', "OrderedStamp 'compiler-pid'", "OrderedStamp 'compiler-identity-read'", '$c.WaitForExit(60000)'),
            ('$x=Start-Process', "OrderedStamp 'control-player-pid'", "OrderedStamp 'control-player-identity-read'", '$x.WaitForExit(250)'),
            ("OrderedStamp 'player-start'", "OrderedStamp 'player-pid'", "OrderedStamp 'player-identity-read'", 'Elapsed.TotalSeconds -lt 300')]:
            offsets = [body.index(text) for text in [start, pid, identity, wait]]
            self.assertEqual(offsets, sorted(offsets))
        # The primary failure is recorded before cleanup and cannot be
        # overwritten by a root-removal/late verification exception.
        primary = body.index('$r.errorStage=$r.stage;$r.error=$_.ToString()')
        cleanup = body.index("OrderedStamp 'cleanup-compiler'", primary)
        proof = body.index('$r.rootRemovalReady=RootRemovalReady', cleanup)
        refusal = body.index("throw 'Root retained: exact owner exit or detached-child drain is unproven'", proof)
        removal = body.index('Remove-Item -LiteralPath $root', refusal)
        final = body.index("[Console]::Error.WriteLine('ORDERED_FINAL:'", removal)
        self.assertEqual([primary, cleanup, proof, refusal, removal, final], sorted([primary, cleanup, proof, refusal, removal, final]))
        self.assertNotIn('$r.error=', body[cleanup:])
        self.assertIn('}catch{OrderedCleanupFailure $_}finally{', body)
        self.assertIn('$script:orderedOwners.ContainsKey([int]$_.ParentProcessId)', body)
        self.assertIn('$r.unresolvedPlayerOwners.Count', body)
        self.assertNotIn('ORDERED_FINAL:', rewrite('C'))
        self.assertNotIn('ORDERED_FINAL:', rewrite('D'))

    def test_ordered_transport_failure_retains_upload_without_accepting_or_extracting_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            local = Path(tmp) / '.local'; local.mkdir(); output = local / 'output'
            # Retention must also work without valid ZIP/JSON. No unverified
            # bytes may reach extraction after an incomplete guest envelope.
            payload = b'partial uploaded evidence'
            class UploadedEndpoint(FakeEndpoint):
                def __init__(self, *args, **kwargs): super().__init__(*args, **kwargs); self.upload = payload
            done = subprocess.CompletedProcess([], 1, '', 'late cleanup failed')
            with patch.object(probe, 'local_roots', return_value=[local.resolve()]), patch.object(probe, 'Endpoint', UploadedEndpoint),\
                 patch.object(probe, 'guarded', return_value=0), patch.object(probe, 'errno_count', return_value=0),\
                 patch.object(probe, 'fresh_root', return_value=ROOT_A), patch.object(probe, 'ordered_transport', return_value=done),\
                 patch.object(probe, 'extract') as extract:
                with self.assertRaisesRegex(RuntimeError, 'VM exec failed: late cleanup failed'):
                    probe.run_rewrite('vm', output, 0, 'OA', {'fixture.png': b'original', 'fixture-c.png': b'original c'}, ZIPMOD,
                                      None, 'host', 300, runtime_pins=runtime_pins(), control_seconds=180)
            self.assertEqual((output / 'transport-upload.zip').read_bytes(), payload)
            record = json.loads((output / 'run.json').read_text())
            self.assertEqual(record['unverifiedUpload'], {'file': 'transport-upload.zip', 'bytes': len(payload),
                                                         'sha256': hashlib.sha256(payload).hexdigest()})
            self.assertEqual(record['execError'], 'late cleanup failed')
            self.assertEqual((record['controlSeconds'], record['waitSeconds']), (180, 300))
            self.assertNotIn('guest', record); self.assertFalse((output / 'summary.json').exists())
            extract.assert_not_called()

    def test_ordered_null_child_fields_and_reparented_unresolved_instances_fail_closed(self):
        body = ordered()
        observer = body.split('function ObservePlayerChildren{', 1)[1].split('function StopPlayerOwners{', 1)[0]
        guard = observer.index("-not ($childStart -is [DateTime]) -or -not $rowBirth")
        self.assertLess(guard, observer.index('$childStart.ToUniversalTime()'))
        self.assertNotIn('$row.CreationDate.ToUniversalTime()', observer)
        self.assertNotIn('$child.StartTime.ToUniversalTime()', observer)
        self.assertIn("'Live child identity read failed'", observer)
        self.assertIn("'Missing child path or birth'", observer)
        self.assertIn("'Child live/CIM identity differs'", observer)
        self.assertNotIn('RememberPlayer $child', observer)  # No second, racy identity read after validation.
        self.assertIn('$script:orderedUnresolved.ContainsKey($key)', body)
        self.assertIn('$script:orderedUnresolved.Count -ge 32', body)
        self.assertIn('unresolvedChildren=$r.unresolvedChildObservations', body)
        veto = body.split('$r.unresolvedRecordedInstances=@(', 1)[1].split('$r.unresolvedPlayerOwners=', 1)[0]
        self.assertIn('[int]$row.ProcessId -ne $observation.pid', veto)
        self.assertIn('-not $observation.birth -or -not $birth -or $birth -ceq $observation.birth', veto)
        for forbidden in ('ParentProcessId', 'ExecutablePath', 'Stop-Process', 'RememberPlayer'):
            self.assertNotIn(forbidden, veto)
        self.assertIn('$r.unresolvedRecordedInstances.Count -or $r.childObservationOverflow', body)

    def test_ordered_runtime_requires_complete_exact_bounded_pins(self):
        pins = runtime_pins(); body = probe.ordered_runtime_check(pins)
        self.assertIn('Compare-Object -CaseSensitive', body)
        self.assertIn('Runtime contains a reparse point', body)
        self.assertIn('Get-Item -Force -LiteralPath $path', body)
        for bad in (None, {}, {k:v for k,v in pins.items() if k != '@compiler'},
                    dict(pins, **{'CharaStudio_Data/../outside.dll': {'sha256':'a'*64,'bytes':1}}),
                    dict(pins, **{'charastudio.exe': {'sha256':'a'*64,'bytes':1}}),
                    dict(pins, **{'CharaStudio_Data/too-big': {'sha256':'a'*64,'bytes':512*1024*1024+1}})):
            with self.subTest(bad=bad), self.assertRaises(ValueError): probe.ordered_runtime_check(bad)
        # Complete inventories can contain empty/hidden files; neither is omitted.
        pins['CharaStudio_Data/._app.info'] = {'sha256':'b'*64,'bytes':0}
        self.assertIn('._app.info', probe.ordered_runtime_check(pins))

    def fixtures(self, root):
        fixture = root / 'fixture.png'; fixture.write_bytes(b'exact fixture')
        fixture_c = root / 'fixture-c.png'; fixture_c.write_bytes(b'exact fixture c')
        run = root / 'run.json'; run.write_text(json.dumps({'guest': {'zipmod': ZIPMOD}}))
        return ['vm', root / 'output', 0, fixture, hashlib.sha256(b'exact fixture').hexdigest(),
                fixture_c, hashlib.sha256(b'exact fixture c').hexdigest(), run, runtime_pins()]

    def test_ordered_bounds_reject_before_any_transport(self):
        for kwargs in ({'wait_seconds': 601}, {'control_seconds': 181}, {'control_seconds': 0}, {'control_seconds': None},
                       {'collider': COLLIDER}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError): ordered(**kwargs)
        with self.assertRaises(ValueError): rewrite('C', control_seconds=180)
        with self.assertRaises(ValueError): rewrite('OC', wait_seconds=180, collider=None, inputs=ORDERED_INPUTS)
        with tempfile.TemporaryDirectory() as tmp, patch.object(probe, 'run_rewrite') as transport:
            root = Path(tmp); args = self.fixtures(root)
            for index, value in ((4, '0' * 64), (6, '0' * 64), (6, None), (8, {})):
                changed = list(args); changed[index] = value
                with self.subTest(index=index), self.assertRaises(ValueError): probe.run_ordered(*changed)
            for kwargs in ({'wait_seconds': 601}, {'wait_seconds': 0}, {'control_seconds': 181}):
                with self.subTest(kwargs=kwargs), self.assertRaises(ValueError): probe.run_ordered(*args, **kwargs)
            (root / 'output').mkdir(); (root / 'output' / 'partial.log').write_text('retain failed start')
            with self.assertRaisesRegex(RuntimeError, 'new directory'): probe.run_ordered(*args)
            self.assertEqual((root / 'output' / 'partial.log').read_text(), 'retain failed start')
            transport.assert_not_called()

    def test_ordered_sends_original_input_identity_without_reauthoring(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(probe, 'run_rewrite', return_value={'accepted': True}) as transport:
            args = self.fixtures(Path(tmp))
            probe.run_ordered(*args)
            sent = transport.call_args.args
            self.assertEqual(sent[3], 'OA')
            self.assertEqual(sent[4], {'fixture.png': b'exact fixture', 'fixture.sha256': args[4].encode(),
                                       'fixture-c.png': b'exact fixture c', 'fixture-c.sha256': args[6].encode(),
                                       'phase.txt': b'OB'})
            self.assertEqual(sorted(sent[4]), sorted(ORDERED_INPUTS))
            self.assertIsNone(sent[6]); self.assertEqual(sent[8], 300)
            self.assertEqual(transport.call_args.kwargs, {'runtime_pins': runtime_pins(), 'control_seconds': 180})

    def accept(self, tmp, drop=None, differ=None, control_code=probe.SHUTDOWN_FAULT, code=probe.SHUTDOWN_FAULT,
               wrong_runtime=False, control_error=None, phases=('OB', 'OA'), replace=None):
        local = Path(tmp) / '.local'; local.mkdir(); output = local / 'output'
        files = {'fixture.png': b'original', 'fixture.sha256': b'expected', 'fixture-c.png': b'original c',
                 'fixture-c.sha256': b'expected c', 'phase.txt': b'OB'}
        saves = ['fixture', 'fixture-c'] + ['edit-' + label for label in probe.ORDERED_CASES]
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as z:
            members = {'status.json': json.dumps({'phase': 'OA', 'error': None}), 'plugin-scene-trace.json': '{}',
                       'control-status.json': json.dumps({'phase': 'OB', 'error': control_error}),
                       'control-plugin-scene-trace.json': '{}', 'control-fixture.png': b'saved fixture',
                       'control-resave-fixture.png': b'saved fixture'}
            for save in saves:
                members[save + '.png'] = members['resave-' + save + '.png'] = b'saved ' + save.encode()
            if differ: members[differ] = b'different bytes'
            members.update(replace or {})
            for name, data in members.items():
                if name != drop: z.writestr(name, data)
        payload = archive.getvalue()
        class UploadedEndpoint(FakeEndpoint):
            def __init__(self, *args, **kwargs): super().__init__(*args, **kwargs); self.upload = payload
        def execute(command, out, record, seconds):
            record['hostGroupReleased'] = True
            (out / 'exec.stdout').write_text('mock'); (out / 'exec.stderr').write_text('')
            guest = {'exited': True, 'playerExitCode': code, 'phases': list(phases),
                     'control': {'phase': 'OB', 'exited': True, 'playerExitCode': control_code}, 'removed': True,
                     'remainingGameProcesses': [], 'junctionTargetsChanged': False, 'runtimeBefore': runtime_pins(),
                     'runtimeAfter': {} if wrong_runtime else runtime_pins(), 'sources': record['sources'],
                     'inputs': record['inputs'], 'zipSHA256': hashlib.sha256(payload).hexdigest(), 'zipBytes': len(payload)}
            return subprocess.CompletedProcess(command, 0, json.dumps(guest), '')
        with patch.object(probe, 'local_roots', return_value=[local.resolve()]), patch.object(probe, 'Endpoint', UploadedEndpoint),\
             patch.object(probe, 'guarded', return_value=0), patch.object(probe, 'errno_count', return_value=0),\
             patch.object(probe, 'fresh_root', return_value=ROOT_A), patch.object(probe, 'ordered_transport', side_effect=execute):
            result = probe.run_rewrite('vm', output, 0, 'OA', files, ZIPMOD, None, 'host', 300, runtime_pins=runtime_pins(),
                                       control_seconds=180)
        return output, result

    def test_ordered_acceptance_requires_the_control_fixed_points_outputs_and_runtime_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            output, result = self.accept(tmp)
            self.assertTrue(result['accepted']); self.assertTrue(result['shutdownFault'])
            self.assertEqual(result['playerExitCodes'], [probe.SHUTDOWN_FAULT, probe.SHUTDOWN_FAULT])
            self.assertEqual(len(result['fixedPoints']), 3 + len(probe.ORDERED_CASES)); self.assertTrue(all(result['fixedPoints'].values()))
            self.assertEqual(result['missingOutputs'], [])
            self.assertEqual((output / 'source-fixture.png').read_bytes(), b'original')
            self.assertEqual((output / 'source-fixture-c.png').read_bytes(), b'original c')
            manifest = {row['file'] for row in json.loads((output / 'manifest.json').read_text())['files']}
            self.assertLessEqual({'source-fixture.png', 'source-fixture-c.png', 'control-status.json', 'control-fixture.png'}, manifest)
            body = (output / 'run.ps1').read_text()
            self.assertLess(body.index('$r.runtimeBefore=VerifyRuntime'), body.index(PLAYER_SETUP))
            self.assertLess(body.index('Input digest mismatch:'), body.index('$c=Start-Process'))
            self.assertLess(body.index('Remove-Item -LiteralPath $root'), body.index('$r.runtimeAfter=VerifyRuntime'))
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(self.accept(tmp, control_code=0, code=0)[1]['accepted'])
        # Sideloader's per-session LocalSlot is the only difference the control may show.
        slot = probe.LOCAL_SLOT
        saved = b'scene ' + slot + b'\x05\xf5\xe1\x84 tail ' + slot + b'\x05\xf5\xe1\x85'
        session = dict(zip(('control-fixture.png', 'control-resave-fixture.png'), 2 * [saved.replace(b'\xe1\x84', b'\xe2\xaa')]))
        session.update({'fixture.png': saved, 'resave-fixture.png': saved})
        with tempfile.TemporaryDirectory() as tmp:
            _, result = self.accept(tmp, replace=session)
            self.assertTrue(result['accepted']); self.assertTrue(result['fixedPoints']['control-fixture'])
            self.assertEqual(result['controlBaselineDifferences'], [saved.index(slot) + len(slot) + 2, saved.index(slot) + len(slot) + 3])
            self.assertEqual(len(result['controlLocalSlotOffsets']), 8)
        elsewhere = dict(session, **{'control-fixture.png': saved.replace(b'scene', b'scenE'), 'control-resave-fixture.png': saved.replace(b'scene', b'scenE')})
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(self.accept(tmp, replace=elsewhere)[1]['controlMatchesBaseline'])
        # Phase C's rows (character live state) are recorded with their offsets and left to the Engine parity test.
        for row in ('fixture-c',) + tuple('edit-' + label for label in probe.ORDERED_FIXTURE_C):
            with self.subTest(row=row), tempfile.TemporaryDirectory() as tmp:
                _, result = self.accept(tmp, replace={'resave-' + row + '.png': b'saved ' + row[:-1].encode() + b'X'})
                self.assertTrue(result['accepted']); self.assertFalse(result['fixedPoints'][row])
                self.assertEqual(result['saveResaveDifferences'], {row: [len(b'saved ' + row.encode()) - 1]})
                self.assertIn(row, result['liveStateRows'])
        rejected = (dict(drop='edit-duplicate-delete.png'), dict(drop='control-status.json'), dict(drop='resave-fixture-c.png'),
                    dict(differ='resave-edit-delete-add-folder.png'), dict(differ='control-resave-fixture.png'),
                    dict(differ='control-fixture.png'), dict(control_code=0), dict(code=0),
                    dict(control_code=1, code=1), dict(wrong_runtime=True), dict(control_error='baseline: failed'),
                    dict(phases=('OA',)))
        for changes in rejected:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as tmp:
                self.assertFalse(self.accept(tmp, **changes)[1]['accepted'])


if __name__ == '__main__':
    unittest.main()
