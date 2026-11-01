"""Phase OL of the plug-in scene probe (#316, #320) and the ordered phase it builds on; VM calls are mocked."""
import hashlib, io, json, re, subprocess, tempfile, unittest, zipfile
from pathlib import Path
from unittest.mock import patch
import original_plugin_scene_probe as probe
from original_character_probe import PLAYER_SETUP
from test_original_plugin_scene_probe import FakeEndpoint, ROOT_A, ZIPMOD, PROBE_SOURCE, ordered, rewrite, runtime_pins

LIGHT_INPUTS = ['fixture.png', 'fixture.sha256'] + list(probe.LIGHT_INPUTS) + ['phase.txt']
# The ordered phase as OA exec 3 runs it (#315 4d48d610): the OA run.ps1 rewrite_script makes from the test
# arguments, OriginalPluginRewriteProbe.cs without its "// OL begin" ... "// OL end" blocks, and the OrderedCases
# table. Re-pin only together with a new OA run.
OA_SCRIPT_SHA256 = '43ce1f07a235af882af8a2adf483c1936496304ef78ac4b96cbdad93776b21ae'
OA_PROBE_SHA256 = '9f2354f425e75ba81ce163353880d5dba0c5c81a3e81b0a570b558d77e90d492'
ORDERED_CASES_SHA256 = '50426eeb5b27a374fb6151e9359a3c6514bd2a004d5c7f638845b3461f3437e1'


def light(**changes):
    return rewrite('OL', **dict(dict(wait_seconds=300, collider=None, inputs=LIGHT_INPUTS, control_seconds=300), **changes))


def sha(text): return hashlib.sha256(text.encode() if isinstance(text, str) else text).hexdigest()


def without_light_blocks(source):
    """The probe source with every "// OL begin" ... "// OL end" line block removed."""
    kept, inside = [], False
    for line in source.splitlines(keepends=True):
        mark = line.strip()
        if mark.startswith('// OL begin'):
            if inside: raise AssertionError('nested OL block')
            inside = True
        elif mark == '// OL end':
            if not inside: raise AssertionError('unopened OL block')
            inside = False
        elif not inside: kept.append(line)
    if inside: raise AssertionError('unclosed OL block')
    return ''.join(kept)


class OrderedPhaseIdentityTests(unittest.TestCase):
    def test_the_ordered_phase_is_byte_identical(self):
        self.assertEqual(sha(ordered()), OA_SCRIPT_SHA256)
        source = PROBE_SOURCE.read_text()
        self.assertEqual(sha(without_light_blocks(source)), OA_PROBE_SHA256)
        self.assertEqual(sha(source.split('OrderedCases={', 1)[1].split('};', 1)[0]), ORDERED_CASES_SHA256)
        self.assertEqual(source.count('// OL begin'), 2); self.assertEqual(source.count('// OL end'), 2)

    def test_the_strip_finds_every_block(self):
        self.assertEqual(without_light_blocks('a\n  // OL begin (x)\nb\n  // OL end\nc\n'), 'a\nc\n')
        for broken in ('// OL begin\n', '// OL end\n', '// OL begin\n// OL begin\n// OL end\n'):
            with self.subTest(broken=broken), self.assertRaises(AssertionError): without_light_blocks(broken)


class LightPhaseTests(unittest.TestCase):
    def test_cases_and_inputs_match_the_probe(self):
        source = PROBE_SOURCE.read_text()
        table = source.split('LightCases={', 1)[1].split('};', 1)[0]
        rows = [re.findall(r'"([^"]*)"', row) for row in re.findall(r'new\[\]\{([^}]*)\}', table)]
        self.assertEqual(tuple(row[0] for row in rows), probe.LIGHT_CASES)
        for row in rows:
            with self.subTest(row=row[0]):
                self.assertEqual(row[1], 'a')
                self.assertTrue(all(re.fullmatch(r'(delete|duplicate):[A-Z][A-Z0-9]*|add-light:[0-2]', op) for op in row[2:]), row)
        inputs = re.findall(r'"([^"]*)"', source.split('LightInputs={', 1)[1].split('};', 1)[0])
        self.assertEqual(tuple(inputs), probe.LIGHT_INPUTS)
        # A copy and two adds that vanilla builds, then a copy and an add past the second light.
        self.assertEqual([row[2:] for row in rows], [['delete:V1', 'duplicate:L'], ['delete:L', 'add-light:1', 'add-light:1'],
                                                    ['delete:V1', 'duplicate:L', 'duplicate:L'], ['add-light:1', 'add-light:1']])

    def test_the_vanilla_player_runs_first_then_the_fix_is_copied_into_the_root(self):
        body = light()
        for entry in probe.PLUGINS: self.assertIn("@('%s','%s',%d)" % entry, body)
        for path, _, _ in probe.PLUGINS_B: self.assertNotIn(path, body)
        path, digest, size = probe.LIGHT_FIX
        self.assertNotIn(path, ''.join(entry[0] for entry in probe.PLUGINS))
        self.assertEqual(body.count("OrderedStamp 'light-fix-copy'"), 1)
        copy = body.index("OrderedStamp 'light-fix-copy'")
        self.assertLess(body.index("OrderedStamp 'vanilla-player-complete'"), copy)
        self.assertLess(body.index("OrderedStamp 'vanilla-crash-drain'"), copy)
        self.assertLess(copy, body.index("OrderedStamp 'player-start'"))
        self.assertIn("$dst=Join-Path $root '%s'" % probe.LIGHT_FIX_IN_ROOT, body)
        self.assertEqual(probe.LIGHT_FIX_IN_ROOT, 'BepInEx\\plugins\\' + path)
        # The install's file is checked before anything is copied, and the copy again after.
        self.assertEqual(body.count("if($h -ne '%s' -or $n -ne %d){throw" % (digest, size)), 2)
        check, refuse = body.index("OrderedStamp 'light-fix-check'"), body.index("light fix differs from the inventory: $h $n; nothing copied")
        exists, fix_copy = body.index("if(Test-Path -LiteralPath $dst){throw"), body.rindex('Copy-Item -LiteralPath $src -Destination $dst;')
        self.assertLess(check, body.index('$h=Sha $src;$n=(Get-Item -LiteralPath $src).Length'))
        self.assertTrue(check < refuse < exists < copy < fix_copy, (check, refuse, exists, copy, fix_copy))
        self.assertLess(fix_copy, body.index('Light fix copy differs from the inventory'))
        self.assertIn("""[IO.File]::WriteAllText("$in\\phase.txt",'OU');$r.phases=@('OL','OU')""", body)
        self.assertIn("('vanilla-'+$f.Name)", body); self.assertIn("$r.vanilla=[ordered]@{phase='OL';", body)
        self.assertNotIn('control-', body); self.assertNotIn("'OA'", body); self.assertNotIn("'OB'", body)
        self.assertEqual(body.count('ObservePlayerChildren;[void]$x.WaitForExit(250)'), 2)
        self.assertIn('$playerWatch.Elapsed.TotalSeconds -lt 300){', body)

    def test_the_vanilla_player_needs_a_root_without_any_copy_of_the_fix_and_the_copy_leaves_with_it(self):
        body, sweep = light(), probe.LIGHT_FIX_SWEEP
        self.assertEqual(body.count('function LightFixCopies'), 1); self.assertIn(sweep, body)
        self.assertLess(body.index("OrderedStamp 'vanilla-fix-sweep';$r.vanillaFixSweep=LightFixCopies"), body.index("OrderedStamp 'vanilla-player-start'"))
        self.assertIn("if($r.vanillaFixSweep.matches.Count -or $r.vanillaFixSweep.files -lt 1){throw", body)
        # By size and hash, whatever the name: the sweep names no file, skips junctions (they lead into the install) and is bounded.
        self.assertNotIn('UnlimitedMapLights', sweep); self.assertNotIn('.dll', sweep)
        self.assertIn("-eq %d -and (Sha $path) -ceq '%s'" % (probe.LIGHT_FIX[2], probe.LIGHT_FIX[1]), sweep)
        self.assertIn('if($attributes -band [IO.FileAttributes]::ReparsePoint){continue}', sweep)
        self.assertIn("$seen -gt 8192 -or $watch.Elapsed.TotalSeconds -gt 60){throw", sweep)
        for verb in ('Copy-Item', 'Move-Item', 'Remove-Item', 'WriteAll', 'New-Item'): self.assertNotIn(verb, sweep)
        gone = body.index(";$r.lightFixGone=-not(Test-Path -LiteralPath (Join-Path $root '%s'))" % probe.LIGHT_FIX_IN_ROOT)
        self.assertLess(body.index("OrderedStamp 'root-removal'"), gone)
        self.assertLess(gone, body.index("OrderedStamp 'final-envelope'"))
        self.assertNotIn('LightFixCopies', ordered()); self.assertNotIn('lightFixGone', ordered())

    def test_writes_only_into_the_private_root(self):
        body = light(); own = body.replace(PLAYER_SETUP, '')
        self.assertEqual(re.findall(r'-Destination ([^\s;]+)', body), ['$copy', '$dst', '"$out\\vanilla-$(Split-Path', '$dst'])
        self.assertEqual(re.findall(r'Remove-Item -LiteralPath (\S+)', body), ['$root'])
        self.assertEqual(re.findall(r'WriteAllText\("([^"]+)"', own), [r'$in\phase.txt'])
        self.assertEqual(re.findall(r'Copy-Item -LiteralPath (\S+) -Destination (\S+?);', body),
                         [('$m[0].FullName', '$copy'), ('$src', '$dst'), ('$src', '$dst')])
        self.assertIn(r'$src=Join-Path "$original\BepInEx\plugins" ', body)

    def test_the_byte_scan_reads_only_and_records_counts(self):
        scan = probe.light_scan(probe.LIGHT_SCAN_SECONDS)
        for verb in ('Copy-Item', 'Move-Item', 'Remove-Item', 'Rename-Item', 'WriteAll', 'Set-Content', 'Out-File', 'New-Item', 'Start-Process'):
            self.assertNotIn(verb, scan)
        self.assertIn('[IO.File]::ReadAllBytes($path)', scan)
        self.assertIn(r"""EnumerateFiles("$original\BepInEx\plugins",'*.dll',[IO.SearchOption]::AllDirectories)""", scan)
        # No DLL path or name is recorded: no value written into $r.lightScan reads $path, the exception's message or $_.
        assigned = re.findall(r'\$r\.lightScan(?:\.\w+|\[[^\]]*\])*=([^;\n}]*)', scan)
        self.assertGreater(len(assigned), 5)
        for value in assigned: self.assertNotRegex(value, r'\$path|\$_\.ToString|Message')
        self.assertIn('enumerationError=$_.Exception.GetType().FullName}', scan)
        self.assertIn('if($path -ceq $fix){$own=[ordered]@{sha256=(Sha $path)', scan)
        for name in probe.LIGHT_NAMES: self.assertIn("'%s'" % name, scan)
        self.assertIn('-gt %d -or $r.lightScan.dlls -ge 4096' % probe.LIGHT_SCAN_SECONDS, scan)
        self.assertIn(str(probe.LIGHT_SCAN_FILE_BYTES), scan)
        body = light()
        self.assertIn(probe.light_scan(180), body)
        self.assertLess(body.index("OrderedStamp 'light-scan'"), body.index("OrderedStamp 'compiler-start'"))
        self.assertNotIn("OrderedStamp 'light-scan'", ordered())
        for bound in (0, probe.LIGHT_SCAN_SECONDS + 1, None):
            with self.subTest(bound=bound), self.assertRaises(ValueError): probe.light_scan(bound)

    def test_bounds(self):
        self.assertIn('$playerWatch.Elapsed.TotalSeconds -lt 600){', light(control_seconds=600))
        for kwargs in ({'wait_seconds': 601}, {'control_seconds': 601}, {'control_seconds': 0}, {'control_seconds': None},
                       {'collider': {'name': 'x.zipmod', 'sha256': 'c' * 64}}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError): light(**kwargs)
        with self.assertRaises(ValueError): ordered(control_seconds=181)  # OA's control keeps its own bound

    def fixtures(self, root):
        fixture = root / 'fixture.png'; fixture.write_bytes(b'exact fixture')
        inputs = root / 'inputs'; inputs.mkdir()
        for name in probe.LIGHT_INPUTS: (inputs / name).write_bytes(b'ours ' + name.encode())
        run = root / 'run.json'; run.write_text(json.dumps({'guest': {'zipmod': ZIPMOD}}))
        return ['vm', root / 'output', 0, fixture, hashlib.sha256(b'exact fixture').hexdigest(), inputs, run, runtime_pins()]

    def test_sends_the_exact_fixture_and_our_exports(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(probe, 'run_rewrite', return_value={'accepted': True}) as transport:
            args = self.fixtures(Path(tmp))
            probe.run_light(*args)
            sent = transport.call_args.args
            self.assertEqual(sent[3], 'OL')
            self.assertEqual(sent[4], {'fixture.png': b'exact fixture', 'fixture.sha256': args[4].encode(),
                                       'ours-light-roots.png': b'ours ours-light-roots.png',
                                       'ours-light-nested.png': b'ours ours-light-nested.png', 'phase.txt': b'OL'})
            self.assertEqual(list(sent[4]), LIGHT_INPUTS)
            self.assertIsNone(sent[6]); self.assertEqual(sent[8], 300)
            self.assertEqual(transport.call_args.kwargs, {'scan_seconds': probe.LIGHT_SCAN_SECONDS, 'runtime_pins': runtime_pins(),
                                                          'control_seconds': 300})

    def test_rejects_before_any_transport(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(probe, 'run_rewrite') as transport:
            root = Path(tmp); args = self.fixtures(root)
            for index, value in ((4, '0' * 64), (4, None), (7, {})):
                changed = list(args); changed[index] = value
                with self.subTest(index=index), self.assertRaises(ValueError): probe.run_light(*changed)
            for kwargs in ({'wait_seconds': 601}, {'vanilla_seconds': 0}, {'scan_seconds': 181}):
                with self.subTest(kwargs=kwargs), self.assertRaises(ValueError): probe.run_light(*args, **kwargs)
            (root / 'inputs' / 'ours-light-nested.png').unlink()
            with self.assertRaisesRegex(ValueError, 'sourceSceneLightProbeWritesItsInputs'): probe.run_light(*args)
            (root / 'output').mkdir()
            with self.assertRaisesRegex(RuntimeError, 'new directory'): probe.run_light(*args)
            transport.assert_not_called()

    def accept(self, tmp, drop=None, differ=None, vanilla_code=probe.SHUTDOWN_FAULT, code=probe.SHUTDOWN_FAULT,
               vanilla_error=None, phases=('OL', 'OU'), replace=None, fix=None, scan=None, sweep=None, gone=True):
        local = Path(tmp) / '.local'; local.mkdir(); output = local / 'output'
        files = {'fixture.png': b'original', 'fixture.sha256': b'expected', 'ours-light-roots.png': b'roots',
                 'ours-light-nested.png': b'nested', 'phase.txt': b'OL'}
        saves = ['fixture'] + ['edit-' + label for label in probe.LIGHT_CASES]
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as z:
            members = {'status.json': json.dumps({'phase': 'OU', 'error': None}), 'plugin-scene-trace.json': '{}',
                       'vanilla-status.json': json.dumps({'phase': 'OL', 'error': vanilla_error}),
                       'vanilla-plugin-scene-trace.json': '{}'}
            for prefix in ('vanilla-', ''):
                for save in saves:
                    members[prefix + save + '.png'] = members[prefix + 'resave-' + save + '.png'] = b'saved ' + save.encode()
                for name in probe.LIGHT_INPUTS: members[prefix + 'resave-' + name] = b'resaved ' + name.encode()
            if differ: members[differ] = b'different bytes'
            members.update(replace or {})
            for name, data in members.items():
                if name != drop: z.writestr(name, data)
        payload = archive.getvalue()
        class UploadedEndpoint(FakeEndpoint):
            def __init__(self, *args, **kwargs): super().__init__(*args, **kwargs); self.upload = payload
        path, digest, size = probe.LIGHT_FIX
        light_scan = scan if scan is not None else {'dlls': 243, 'bytes': 1, 'oversize': 0, 'errors': 0, 'truncated': False,
                                                    'utf8': {}, 'utf16': {}, 'fix': {'sha256': digest, 'bytes': size}}
        def execute(command, out, record, seconds):
            record['hostGroupReleased'] = True
            (out / 'exec.stdout').write_text('mock'); (out / 'exec.stderr').write_text('')
            guest = {'exited': True, 'playerExitCode': code, 'phases': list(phases),
                     'vanilla': {'phase': 'OL', 'exited': True, 'playerExitCode': vanilla_code}, 'removed': True,
                     'lightFix': fix if fix is not None else {'path': path, 'sha256': digest, 'bytes': size}, 'lightScan': light_scan,
                     'vanillaFixSweep': sweep if sweep is not None else {'files': 40, 'matches': []}, **({} if gone is None else {'lightFixGone': gone}),
                     'remainingGameProcesses': [], 'junctionTargetsChanged': False, 'runtimeBefore': runtime_pins(),
                     'runtimeAfter': runtime_pins(), 'sources': record['sources'],
                     'inputs': record['inputs'], 'zipSHA256': hashlib.sha256(payload).hexdigest(), 'zipBytes': len(payload)}
            return subprocess.CompletedProcess(command, 0, json.dumps(guest), '')
        with patch.object(probe, 'local_roots', return_value=[local.resolve()]), patch.object(probe, 'Endpoint', UploadedEndpoint),\
             patch.object(probe, 'guarded', return_value=0), patch.object(probe, 'errno_count', return_value=0),\
             patch.object(probe, 'fresh_root', return_value=ROOT_A), patch.object(probe, 'ordered_transport', side_effect=execute):
            result = probe.run_rewrite('vm', output, 0, 'OL', files, ZIPMOD, None, 'host', 300, scan_seconds=180,
                                       runtime_pins=runtime_pins(), control_seconds=300)
        return output, result

    def test_acceptance_requires_both_players_the_fix_copy_and_the_complete_scan(self):
        with tempfile.TemporaryDirectory() as tmp:
            output, result = self.accept(tmp)
            self.assertTrue(result['accepted']); self.assertTrue(result['shutdownFault'])
            self.assertEqual(len(result['fixedPoints']), 2 * (1 + len(probe.LIGHT_CASES))); self.assertTrue(all(result['fixedPoints'].values()))
            self.assertEqual(result['missingOutputs'], []); self.assertTrue(result['lightFixCopied']); self.assertTrue(result['lightScanComplete'])
            self.assertTrue(result['vanillaRootClean']); self.assertIs(result['lightFixGone'], True)
            self.assertEqual((output / 'source-fixture.png').read_bytes(), b'original')
            self.assertFalse((output / 'source-fixture-c.png').exists())
            manifest = {row['file'] for row in json.loads((output / 'manifest.json').read_text())['files']}
            self.assertLessEqual({'source-fixture.png', 'vanilla-status.json', 'vanilla-fixture.png', 'resave-ours-light-nested.png'}, manifest)
            body = (output / 'run.ps1').read_text()
            self.assertLess(body.index('$r.runtimeBefore=VerifyRuntime'), body.index(PLAYER_SETUP))
            self.assertLess(body.index('Input digest mismatch: ours-light-nested.png'), body.index('$c=Start-Process'))
            run = json.loads((output / 'run.json').read_text())
            self.assertEqual(run['lightFix'], dict(zip(('path', 'sha256', 'bytes'), probe.LIGHT_FIX))); self.assertEqual(run['scanSeconds'], 180)
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(self.accept(tmp, vanilla_code=0, code=0)[1]['accepted'])
        # The fix changes no byte of the baseline save apart from Sideloader's per-session LocalSlot values.
        slot = probe.LOCAL_SLOT
        saved = b'scene ' + slot + b'\x05\xf5\xe1\x84'
        session = {'vanilla-fixture.png': saved.replace(b'\xe1\x84', b'\xe2\xaa'), 'vanilla-resave-fixture.png': saved.replace(b'\xe1\x84', b'\xe2\xaa'),
                   'fixture.png': saved, 'resave-fixture.png': saved}
        with tempfile.TemporaryDirectory() as tmp:
            _, result = self.accept(tmp, replace=session)
            self.assertTrue(result['accepted']); self.assertEqual(len(result['localSlotOffsets']), 4)
        path, digest, size = probe.LIGHT_FIX
        full = {'dlls': 243, 'bytes': 1, 'oversize': 0, 'errors': 0, 'truncated': False, 'fix': {'sha256': digest, 'bytes': size}}
        rejected = (dict(drop='vanilla-edit-add-light-twice.png'), dict(drop='resave-ours-light-roots.png'),
                    dict(drop='vanilla-status.json'), dict(differ='resave-edit-delete-duplicate-light-twice.png'),
                    dict(differ='vanilla-fixture.png'), dict(vanilla_code=0), dict(code=0), dict(vanilla_code=1, code=1),
                    dict(vanilla_error='baseline: failed'), dict(phases=('OU',)), dict(phases=('OB', 'OA')),
                    dict(fix={'path': path, 'sha256': '0' * 64, 'bytes': size}), dict(fix={}),
                    dict(scan=dict(full, truncated=True)), dict(scan=dict(full, errors=1)), dict(scan=dict(full, oversize=1)),
                    dict(scan=dict(full, dlls=0)), dict(scan=dict(full, fix=None)),
                    dict(scan=dict(full, enumerationError='System.UnauthorizedAccessException')),
                    dict(scan={}), dict(sweep={'files': 40, 'matches': ['BepInEx\\plugins\\copy.dll']}), dict(sweep={'files': 0, 'matches': []}),
                    dict(sweep={}), dict(gone=False), dict(gone=None))
        for changes in rejected:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as tmp:
                self.assertFalse(self.accept(tmp, **changes)[1]['accepted'])


if __name__ == '__main__':
    unittest.main()
