"""Slider Unlocker oracle probe: case parsing, the read-only run.ps1 and the one-exec framing; VM calls are mocked, so no VM or private data is needed."""
import hashlib, io, json, re, subprocess, tempfile, types, unittest, zipfile
from pathlib import Path
from unittest.mock import patch
import original_slider_probe as probe
from original_map_probe import with_junction_scans

ROOT_A = r'C:\Temp\IkkokuShaderProbe-' + ('a' * 32)
SCENE = b'\x89PNG\r\n\x1a\n' + b'synthetic scene record'
SHA = hashlib.sha256(SCENE).hexdigest()
LABEL = SHA[:12] + '-167'


def write_cases(folder, *lines):
    scene = Path(folder) / 'scene.png'; scene.write_bytes(SCENE)
    cases = Path(folder) / 'cases.tsv'
    cases.write_text(''.join(line.replace('<scene>', str(scene)) + '\n' for line in lines))
    return cases


class FakeEndpoint:
    upload = None
    def __init__(self, address, files, upload): self.files = files; self.base = 'http://host/token/'; self.name = upload
    def __enter__(self): return self
    def __exit__(self, *exc): return False


class CaseTests(unittest.TestCase):
    def test_cases_become_uploads_and_the_probe_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            uploads, cards, records = probe.cases_from(write_cases(tmp, f'{LABEL}\t<scene>\t{SHA}\t167\t1\tunlocked,vanilla'))
        self.assertEqual(uploads, {f'slider-{LABEL}.png': SCENE})
        self.assertEqual(cards, f'{LABEL}\t167\t1\tunlocked,vanilla\n'.encode())
        self.assertEqual(records, [dict(label=LABEL, sceneSHA256=SHA, key=167, sex=1, modes=['unlocked', 'vanilla'])])

    def test_refuses_bad_cases(self):
        bad = {
            'label must be': f'scene-167\t<scene>\t{SHA}\t167\t1\tunlocked,vanilla',
            'must start with the label': f'{"0" * 12}-167\t<scene>\t{SHA}\t167\t1\tunlocked,vanilla',
            'must end with the object key': f'{LABEL}\t<scene>\t{SHA}\t168\t1\tunlocked,vanilla',
            'sex must be': f'{LABEL}\t<scene>\t{SHA}\t167\t2\tunlocked,vanilla',
            'modes must name': f'{LABEL}\t<scene>\t{SHA}\t167\t1\tunlocked,maker',
            'expected 6': f'{LABEL}\t<scene>\t{SHA}\t167\t1',
            'no case for the vanilla run': f'{LABEL}\t<scene>\t{SHA}\t167\t1\tunlocked',
        }
        for message, line in bad.items():
            with self.subTest(message), tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, message):
                probe.cases_from(write_cases(tmp, line))

    def test_refuses_a_scene_record_that_does_not_hash_as_listed(self):
        with tempfile.TemporaryDirectory() as tmp:
            cases = write_cases(tmp, f'{LABEL}\t<scene>\t{SHA}\t167\t1\tunlocked,vanilla')
            (Path(tmp) / 'scene.png').write_bytes(SCENE + b'!')
            with self.assertRaisesRegex(ValueError, 'SHA-256 differs'): probe.cases_from(cases)


class ScriptTests(unittest.TestCase):
    def script(self):
        return with_junction_scans(probe.run_script(ROOT_A, 'http://host/token/', 600, [f'slider-{LABEL}.png']))

    def test_the_install_is_only_read(self):
        script = self.script()
        # Every write names the private root or a path inside it; the install only appears as a source.
        copies = re.findall(r'-Destination (\S+?)[;}]', script)
        removals = re.findall(r'Remove-Item -LiteralPath (\S+?)[;} ]', script)
        moves = re.findall(r'Move-Item -LiteralPath \S+ ("[^"]*")', script)
        self.assertEqual(copies, ['$dst', '$cfgCopy']); self.assertEqual(removals, ['$dst', '$cfgCopy', '$root'])
        self.assertEqual(moves, ['"$out\\$mode-$(Split-Path $n -Leaf)"'])
        self.assertNotRegex(script, r'(Set-Content|Out-File|New-Item -ItemType Directory "\$original)')
        self.assertIn("$src=Join-Path \"$original\\BepInEx\\plugins\" 'KK_BepisPlugins\\SliderUnlocker.dll'", script)
        self.assertIn('$cfg="$original\\BepInEx\\config\\' + probe.SLIDER_CONFIG + '"', script)
        self.assertIn('$r.scanBefore=Scan', script); self.assertIn('$r.scanAfter=Scan', script)

    def test_the_plugin_is_checked_copied_and_removed_before_the_vanilla_run(self):
        script = self.script()
        self.assertIn(f"-ne '{probe.SLIDER[1]}' -or $r.installed.bytes -ne {probe.SLIDER[2]}", script)
        self.assertIn('fileVersion=$v.FileVersion', script)
        unlocked, removal, vanilla = (script.index(s) for s in ("$r.unlocked=Play 'unlocked'", 'Remove-Item -LiteralPath $dst', "$r.vanilla=Play 'vanilla'"))
        self.assertLess(unlocked, removal); self.assertLess(removal, vanilla)
        self.assertIn('WaitForExit(600000)', script)

    def test_cleanup_keeps_a_root_that_still_holds_a_link(self):
        script = self.script()
        cleanup = script[script.index('finally{'):]
        self.assertLess(cleanup.index('cmd /c rmdir'), cleanup.index('Remove-Item -LiteralPath $root -Recurse -Force'))
        self.assertIn("reparse points left in the root", cleanup)

    def test_refuses_unexpected_names(self):
        with self.assertRaisesRegex(ValueError, 'upload names'): probe.run_script(ROOT_A, 'http://h/t/', 600, ['scene.png'])
        with self.assertRaisesRegex(ValueError, 'player root'): probe.run_script(r'C:\Temp\other', 'http://h/t/', 600, [f'slider-{LABEL}.png'])

    def test_the_exec_command_stays_short(self):
        command = probe.exec_command('Windows 11', 'http://10.211.55.2:65535/' + 'f' * 32 + '/')
        self.assertLess(len(' '.join(command)), probe.MAX_COMMAND_CHARS)
        self.assertEqual(command[:5], ['prlctl', 'exec', 'Windows 11', '--current-user', 'powershell.exe'])


class RunTests(unittest.TestCase):
    def run_phase(self, tmp, guest, upload=None, returncode=0):
        local = Path(tmp) / '.local'; local.mkdir()
        cases = write_cases(tmp, f'{LABEL}\t<scene>\t{SHA}\t167\t1\tunlocked,vanilla')
        done = subprocess.CompletedProcess([], returncode, stdout=json.dumps(guest), stderr='exec failed')
        FakeEndpoint.upload = upload
        args = types.SimpleNamespace(output=local / 'phase', cases=cases, vm='vm', errno_baseline=0, host_address='10.211.55.2', wait_seconds=600)
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()),\
             patch.object(probe, 'Endpoint', FakeEndpoint), patch.object(probe, 'guarded', return_value=0),\
             patch.object(probe, 'errno_count', return_value=0), patch.object(probe, 'fresh_root', return_value=ROOT_A),\
             patch.object(probe.subprocess, 'run', return_value=done) as run:
            result = probe.run(args)
        return args.output, result, run

    def test_one_exec_collects_both_runs(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as z:
            for mode in probe.MODES:
                z.writestr(f'{mode}-status.json', json.dumps({'error': None, 'written': [f'{mode}-{LABEL}.json']}))
                z.writestr(f'{mode}-{LABEL}.json', '{}')
        data = archive.getvalue()
        with tempfile.TemporaryDirectory() as tmp:
            guest = {'removed': True, 'remainingGameProcesses': [], 'scanBefore': {'a': 1}, 'scanAfter': {'a': 1},
                     'installed': {'fileVersion': '21.1.2.1', 'productVersion': '21.1.2.1'}, 'config': None,
                     'unlocked': {'exited': True}, 'vanilla': {'exited': True}, 'zipSHA256': probe.digest(data), 'zipBytes': len(data)}
            output, result, run = self.run_phase(tmp, guest, upload=data)
            self.assertEqual(run.call_count, 1); self.assertEqual(run.call_args.args[0][:3], ['prlctl', 'exec', 'vm'])
            record = json.loads((output / 'run.json').read_text())
            self.assertEqual(record['uploads'], {f'slider-{LABEL}.png': SHA}); self.assertLess(record['commandChars'], probe.MAX_COMMAND_CHARS)
            self.assertNotIn('http://host/token/', (output / 'run.ps1').read_text())
            self.assertEqual(result['fileVersion'], '21.1.2.1'); self.assertIs(result['scansEqual'], True)
            self.assertEqual(result['written'], {m: [f'{m}-{LABEL}.json'] for m in probe.MODES})
            self.assertEqual(result['statusErrors'], {m: None for m in probe.MODES})

    def test_refuses_guest_hashes_that_differ(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Guest scene hash differs'):
            self.run_phase(tmp, {'scenes': {f'slider-{LABEL}.png': '0' * 64}})
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Upload differs'):
            self.run_phase(tmp, {'zipSHA256': '0' * 64, 'zipBytes': 1}, upload=b'zip')

    def test_a_failed_exec_is_recorded_and_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, 'VM exec failed'): self.run_phase(tmp, {}, returncode=1)
            record = json.loads((Path(tmp) / '.local' / 'phase' / 'run.json').read_text())
            self.assertIn('exec failed', record['execError']); self.assertEqual(record['errnoAfter'], 0)


if __name__ == '__main__':
    unittest.main()
