"""#401 ABMX probe driver: the case list, run.ps1's plug-in copies and clean-up, the one-exec framing and the dry run.
VM calls and the endpoint are mocked, and the scene records are synthetic: no VM or private data."""
import hashlib, io, json, tempfile, unittest, zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import original_abmx_probe as probe

PLAYER_ROOT = r'C:\Temp\IkkokuShaderProbe-' + 'b' * 32
BASE = 'http://10.211.55.2:1/' + 'c' * 32 + '/'


def sha(data): return hashlib.sha256(data).hexdigest()


def archive(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as z:
        for name, data in entries.items(): z.writestr(name, data)
    return buffer.getvalue()


class FakeEndpoint:
    """Endpoint's context-manager surface; `upload` is what the guest PUTs."""
    instances = []

    def __init__(self, address, files, upload='character.zip'):
        self.address, self.files, self.upload_name, self.upload = address, files, upload, None
        self.base = BASE
        FakeEndpoint.instances.append(self)

    def __enter__(self):
        self.upload = FakeEndpoint.next_upload; return self

    def __exit__(self, *exc): return False


class ABMXProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.scene = self.dir / 'scene.png'; self.scene.write_bytes(b'\x89PNG\r\n\x1a\n' + b'synthetic scene')
        self.sha = sha(self.scene.read_bytes()); self.label = self.sha[:12] + '-3012'
        self.cases = self.dir / 'cases.tsv'; self.write_cases()
        FakeEndpoint.instances = []

    def tearDown(self):
        self.tmp.cleanup()

    def write_cases(self, *rows):
        rows = rows or ([self.label, str(self.scene), self.sha, '3012', '0'],)
        self.cases.write_text(''.join('\t'.join(r) + '\n' for r in rows))

    def args(self, **change):
        values = dict(vm='vm', cases=self.cases, output=self.dir / 'out', errno_baseline=0, host_address='10.211.55.2', wait_seconds=60, inventory=None)
        values.update(change); return SimpleNamespace(**values)

    def run_probe(self, guest_change=None):
        upload = archive({'status.json': b'{"error":null,"written":["abmx-x.json"]}', f'abmx-{self.label}.json': b'{}', 'LogOutput.log': b''})
        uploads, cases_tsv, _ = probe.cases_from(self.cases)
        guest = dict(processID=81, exited=True, source=sha(probe.PROBE.read_bytes()), cases=sha(cases_tsv),
                     scenes={n: sha(d) for n, d in uploads.items()}, zipSHA256=sha(upload), zipBytes=len(upload), removed=True,
                     remainingGameProcesses=[], pending=[], reparsePoints=[], scanBefore={'abdata': {'files': 1}}, scanAfter={'abdata': {'files': 1}},
                     targetsChanged=False, plugins=[], configs={})
        guest.update(guest_change or {})
        FakeEndpoint.next_upload = upload
        completed = SimpleNamespace(returncode=0, stdout=json.dumps(guest), stderr='')
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), \
             patch.object(probe, 'fresh_root', return_value=PLAYER_ROOT), \
             patch.object(probe, 'guarded', return_value=0), \
             patch.object(probe, 'errno_count', return_value=0), \
             patch.object(probe, 'Endpoint', FakeEndpoint), \
             patch.object(probe, 'log'), \
             patch.object(probe.subprocess, 'run', return_value=completed) as vm:
            try:
                return probe.run(self.args())
            finally:
                self.vm = vm

    def test_cases_name_the_scene_by_its_hash_and_key_only(self):
        uploads, cases_tsv, records = probe.cases_from(self.cases)
        self.assertEqual(list(uploads), [f'abmx-{self.label}.png'])
        self.assertEqual(cases_tsv.decode(), f'{self.label}\t3012\t0\n')
        self.assertEqual(records, [dict(label=self.label, sceneSHA256=self.sha, key=3012, sex=0)])
        self.assertNotIn(b'scene.png', cases_tsv)

    def test_bad_cases_are_refused(self):
        other = self.dir / 'other.txt'; other.write_bytes(b'not a png')
        for row in ([self.label, str(self.scene), self.sha, '3012'],
                    ['scene-3012', str(self.scene), self.sha, '3012', '0'],
                    [self.label, str(self.scene), 'f' * 64, '3012', '0'],
                    [self.label, str(self.scene), self.sha, '3013', '0'],
                    [self.label, str(self.scene), self.sha, '3012', '2'],
                    [sha(b'not a png')[:12] + '-3012', str(other), sha(b'not a png'), '3012', '0']):
            with self.subTest(row):
                self.write_cases(row)
                with self.assertRaises(ValueError): probe.cases_from(self.cases)
        self.write_cases([self.label, str(self.scene), self.sha, '3012', '0'], [self.label, str(self.scene), self.sha, '3012', '0'])
        with self.assertRaisesRegex(ValueError, 'duplicate'): probe.cases_from(self.cases)

    def test_the_script_copies_the_plugins_read_only_and_keeps_the_root_guard(self):
        script = probe.phase_script(PLAYER_ROOT, BASE, 60, {f'abmx-{self.label}.png': b''})
        for path, digest, size in probe.PLUGINS:
            self.assertEqual(script.count(f"@('{path}','{digest}',{size})"), 1, path)
        self.assertIn('Copy-Item -LiteralPath $src -Destination $dst', script)
        self.assertEqual(script.count('New-Item -ItemType Junction'), 1)  # PLAYER_SETUP's two junctions, abdata and CharaStudio_Data
        for piece in ('$r.scanBefore=Scan', '$r.scanAfter=Scan', '$t0=[DateTime]::Now', 'function Pending',
                      'reparse points remain under the root: root kept', '$r.targetsChanged=', "-Uri ($base+'abmx.zip')",
                      '/out:"$p\\IkkokuABMXProbe.dll"', "Fetch 'ABMXProbe.cs'", "Fetch 'abmx-cases.tsv'", 'WaitForExit(60000)'):
            self.assertEqual(script.count(piece), 1, piece)
        self.assertNotIn('elseif(Test-Path -LiteralPath $root){Remove-Item', script)
        self.assertNotIn('Remove-Item -LiteralPath $src', script)
        self.assertLess(script.index('$r.scanBefore=Scan'), script.index('try{'))
        with self.assertRaises(ValueError): probe.phase_script(r'C:\Illusion\Koikatsu', BASE, 60, {f'abmx-{self.label}.png': b''})
        with self.assertRaises(ValueError): probe.phase_script(PLAYER_ROOT, BASE, 60, {'scene.png': b''})

    def test_one_exec_serves_the_probe_and_lists_what_arrived(self):
        result = self.run_probe()
        out = self.dir / 'out'
        endpoint = FakeEndpoint.instances[0]
        self.assertEqual(endpoint.upload_name, 'abmx.zip')
        self.assertEqual(sorted(endpoint.files), sorted(['ABMXProbe.cs', 'abmx-cases.tsv', f'abmx-{self.label}.png', 'run.ps1']))
        self.assertEqual(self.vm.call_count, 1)
        command = self.vm.call_args.args[0]
        self.assertEqual(command[:4], ['prlctl', 'exec', 'vm', '--current-user']); self.assertIn(BASE + 'run.ps1', command[-1])
        run = json.loads((out / 'run.json').read_text())
        self.assertLess(run['execCommandChars'], probe.EXEC_LIMIT)
        self.assertNotIn(BASE, (out / 'run.ps1').read_text())
        files = {f['file'] for f in json.loads((out / 'manifest.json').read_text())['files']}
        self.assertTrue({'run.json', 'run.ps1', 'probe-source.cs', 'abmx-cases.tsv', 'status.json', f'abmx-{self.label}.json'} <= files)
        self.assertEqual((result['removed'], result['scansEqual'], result['targetsChanged'], result['errno']), (True, True, False, [0, 0]))
        with self.assertRaisesRegex(RuntimeError, 'new output folder'):
            self.run_probe()

    def test_guest_hash_mismatches_are_refused(self):
        for change in (dict(source='0' * 64), dict(cases='0' * 64), dict(scenes={f'abmx-{self.label}.png': '0' * 64}), dict(zipBytes=1)):
            with self.subTest(change), self.assertRaises(ValueError):
                self.tearDown(); self.setUp(); self.run_probe(change)

    def test_the_dry_run_makes_the_checks_without_the_vm(self):
        manifest = self.dir / 'manifest.json'
        manifest.write_text(json.dumps({'entries': [dict(relativePath=p.replace('\\', '/'), length=b, sha256=s) for p, s, b in probe.PLUGINS]}))
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), patch.object(probe, 'errno_count', return_value=0), \
             patch.object(probe, 'Endpoint', FakeEndpoint), patch.object(probe.subprocess, 'run') as vm:
            result = probe.dry_run(self.args(inventory=manifest))
            vm.assert_not_called()
            self.assertEqual(FakeEndpoint.instances, [])
            self.assertTrue(result['dryRun']); self.assertLess(result['execCommandChars'], probe.EXEC_LIMIT)
            self.assertTrue(all(p['match'] for p in result['plugins']))
            self.assertIn("$base='<endpoint>/'", (self.dir / 'out' / 'run.ps1').read_text())
            with self.assertRaisesRegex(RuntimeError, 'new output folder'): probe.dry_run(self.args(inventory=manifest))
            manifest.write_text(json.dumps({'entries': [dict(relativePath='KKABMX.dll', length=1, sha256='0' * 64)]}))
            with self.assertRaisesRegex(ValueError, 'differ from the inventory'): probe.dry_run(self.args(inventory=manifest, output=self.dir / 'out2'))

    def test_the_probe_source_reads_abmx_by_its_own_reader_and_frames_the_character(self):
        source = probe.PROBE.read_text()
        for piece in ('[BepInPlugin("org.ikkoku.validation.abmxprobe"', 'AbmxGuid="KKABMX.Core"', 'AbmxData="KKABMPlugin.ABMData"',
                      '"marco.kkapi"', '"com.bepis.bepinex.extendedsave"', 'abmx.Major!=5||abmx.Minor!=4', '"GetExtendedDataById"',
                      '"KKABMX.Core.BoneController"', '"ReadModifiers"', '"GetAllModifiers"', '"BoneLocation"', '"CoordinateModifiers"',
                      '"ScaleModifier"', '"LengthModifier"', '"PositionModifier"', '"RotationModifier"', '"_sclBaseline"', '"_posBaseline"', '"_rotBaseline"',
                      'Quaternion.LookRotation(-forward,up)', '"boneRootToCharacter"', '"whitePixels"',
                      '-color.png"', '-character.png"', '-skin.png"', 'Path.Combine(dir,"abmx-cases.tsv")', 'RenderSettings.fog=false'):
            self.assertIn(piece, source)


if __name__ == '__main__':
    unittest.main()
