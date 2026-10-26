"""ST-A11 map probe driver: path checks, the read-only fetch script, placing fetched files, and
the one-exec capture framing. VM calls and the endpoint are mocked: no VM or private data."""
import gzip, hashlib, io, json, os, tempfile, unittest, zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import original_map_probe as probe

FETCH_ROOT = r'C:\Temp\IkkokuMapFetch-' + 'a' * 32
PLAYER_ROOT = r'C:\Temp\IkkokuShaderProbe-' + 'b' * 32


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
        self.base = 'http://10.211.55.2:1/' + 'c' * 32 + '/'
        FakeEndpoint.instances.append(self)

    def __enter__(self):
        self.upload = FakeEndpoint.next_upload; return self

    def __exit__(self, *exc): return False


class PathTests(unittest.TestCase):
    def test_relative_paths_are_plain_forward_slash_game_paths(self):
        self.assertEqual(probe.checked_relative('abdata/studio/map/bushitu.unity3d'), 'abdata/studio/map/bushitu.unity3d')
        for bad in ('', '/abs', 'C:/x', r'abdata\x', '../x', 'a/../b', 'a//b', './a', "abdata/x';rm", 'a/b/'):
            with self.assertRaisesRegex(ValueError, 'game-relative'):
                probe.checked_relative(bad)

    def test_outputs_must_stay_under_local_or_a_link_placed_in_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, linked = Path(tmp) / 'repo', Path(tmp) / 'main' / 'sta11a-maps'
            (repo / '.local').mkdir(parents=True); linked.mkdir(parents=True)
            os.symlink(linked, repo / '.local' / 'sta11a-maps')
            with patch.object(probe, 'ROOT', repo):
                self.assertEqual(probe.private(repo / '.local' / 'sta11a-maps' / 'phase-b'), (linked / 'phase-b').resolve())
                with self.assertRaisesRegex(ValueError, 'under .local'):
                    probe.private(Path(tmp) / 'main' / 'other')


class FetchScriptTests(unittest.TestCase):
    def test_script_only_reads_the_game_and_always_removes_its_root(self):
        script = probe.fetch_script(FETCH_ROOT, 'http://h/t/', probe.DEFAULT_FILES, probe.DEFAULT_GLOBS)
        self.assertIn("$root='" + FETCH_ROOT + "'", script)
        self.assertIn(r"'abdata\studio\map\bushitu.unity3d'", script)
        self.assertIn(r"$globs=@('abdata\studio\info\*.unity3d')", script)
        self.assertIn("throw 'A game process already runs'", script)
        self.assertIn('Copy hash differs', script)
        self.assertNotIn('Remove-Item -LiteralPath $full', script)
        self.assertNotIn('Copy-Item -LiteralPath $root', script)  # nothing is copied back into the game
        cleanup = script[script.index('finally{'):]
        self.assertIn('Remove-Item -LiteralPath $p -Recurse -Force', cleanup)
        self.assertIn('remainingGameProcesses', cleanup)

    def test_script_refuses_unknown_roots_and_unsafe_paths(self):
        with self.assertRaisesRegex(ValueError, 'Unknown private fetch root'):
            probe.fetch_script(r'C:\Illusion\Koikatsu', 'http://h/t/', [], [])
        with self.assertRaisesRegex(ValueError, 'game-relative'):
            probe.fetch_script(FETCH_ROOT, 'http://h/t/', ["abdata/x';rm"], [])
        with self.assertRaisesRegex(ValueError, 'game-relative'):
            probe.fetch_script(FETCH_ROOT, 'http://h/t/', [], ['../*.unity3d'])


class PlaceTests(unittest.TestCase):
    def guest(self, files):
        return dict(files=[dict(path=path, name=path.replace('/', '__'), bytes=len(data), sha256=sha(data)) for path, data in files.items()])

    def test_files_land_under_source_with_both_hashes(self):
        files = {'abdata/abdata': b'manifest', 'abdata/studio/info/00.unity3d': b'info'}
        upload = archive({p.replace('/', '__'): d for p, d in files.items()})
        with tempfile.TemporaryDirectory() as tmp:
            placed = probe.place(upload, self.guest(files), Path(tmp))
            self.assertEqual((Path(tmp) / 'source/abdata/studio/info/00.unity3d').read_bytes(), b'info')
        self.assertEqual([r['path'] for r in placed], sorted(files))
        self.assertTrue(all(r['localSHA256'] == r['sha256'] for r in placed))

    def test_a_changed_missing_or_extra_file_is_refused(self):
        files = {'abdata/abdata': b'manifest'}
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'differs from the guest record'):
                probe.place(archive({'abdata__abdata': b'changed!'}), self.guest(files), Path(tmp))
            with self.assertRaisesRegex(ValueError, 'exactly the recorded files'):
                probe.place(archive({'abdata__abdata': b'manifest', 'extra': b''}), self.guest(files), Path(tmp))
            guest = self.guest(files); guest['files'][0]['path'] = '../escape'
            with self.assertRaisesRegex(ValueError, 'game-relative'):
                probe.place(archive({'abdata__abdata': b'manifest'}), guest, Path(tmp))


class CaptureTests(unittest.TestCase):
    STATUS = {'cases': {'map33': {'ok': True}}}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.showoff = self.dir / 'showoff.png'; self.showoff.write_bytes(b'\x89PNG\r\n\x1a\nscene')
        FakeEndpoint.instances = []

    def tearDown(self):
        self.tmp.cleanup()

    def args(self, output='out'):
        return SimpleNamespace(vm='vm', output=self.dir / output, showoff=self.showoff, errno_baseline=0,
                               host_address='10.211.55.2', wait_seconds=60)

    def run_capture(self, guest_change=None, returncode=0, upload_entries=None):
        entries = upload_entries or {'status.json': json.dumps(self.STATUS).encode(), 'map-trace.json': b'{}',
                                     'original-map33-color.png': b'png'}
        upload = archive(entries)
        guest = dict(processID=77, source=sha(probe.MAP_PROBE.read_bytes()), scenes={'reload-showoff.png': sha(self.showoff.read_bytes())},
                     zipSHA256=sha(upload), zipBytes=len(upload), exited=True, removed=True, remainingGameProcesses=[])
        guest.update(guest_change or {})
        FakeEndpoint.next_upload = upload
        completed = SimpleNamespace(returncode=returncode, stdout='\ufeff' + json.dumps(guest), stderr='boom' if returncode else '')
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), \
             patch.object(probe, 'fresh_root', return_value=PLAYER_ROOT), \
             patch.object(probe, 'guarded', return_value=0) as guard, \
             patch.object(probe, 'errno_count', return_value=0), \
             patch.object(probe, 'Endpoint', FakeEndpoint), \
             patch.object(probe.subprocess, 'run', return_value=completed) as vm:
            try:
                return probe.capture(self.args())
            finally:
                self.guard, self.vm = guard, vm

    def test_one_exec_serves_the_map_probe_and_the_showoff_record_and_lists_every_file(self):
        result = self.run_capture()
        out = self.dir / 'out'
        endpoint = FakeEndpoint.instances[0]
        self.assertEqual(endpoint.upload_name, 'reload.zip')
        self.assertEqual(endpoint.files['MapProbe.cs'], probe.MAP_PROBE.read_bytes())
        self.assertEqual(endpoint.files['reload-showoff.png'], self.showoff.read_bytes())
        script = endpoint.files['run.ps1'].decode()
        self.assertIn("Fetch 'MapProbe.cs'", script); self.assertIn('IkkokuMapProbe.dll', script)
        self.assertNotIn('SceneReloadProbe.cs', script); self.assertNotIn('IkkokuSceneReloadProbe.dll', script)
        self.assertIn("@('reload-showoff.png')", script)
        self.assertIn('<endpoint>/', (out / 'run.ps1').read_text()); self.assertNotIn(endpoint.base, (out / 'run.ps1').read_text())
        self.assertEqual(self.vm.call_count, 1); self.guard.assert_called_once_with(0)
        command = self.vm.call_args.args[0]
        self.assertEqual(command[:4], ['prlctl', 'exec', 'vm', '--current-user']); self.assertIn(endpoint.base + 'run.ps1', command[-1])
        manifest = json.loads((out / 'manifest.json').read_text())
        self.assertEqual(sorted(f['file'] for f in manifest['files']),
                         ['map-trace.json', 'original-map33-color.png', 'probe-source.cs', 'run.json', 'status.json'])
        for f in manifest['files']:
            self.assertEqual(f['sha256'], sha((out / f['file']).read_bytes()))
        run = json.loads((out / 'run.json').read_text())
        self.assertEqual((run['processID'], run['root'], run['errnoBefore'], run['errnoAfter']), (77, PLAYER_ROOT, 0, 0))
        self.assertEqual(result['errno'], [0, 0]); self.assertEqual(result['status'], self.STATUS); self.assertEqual(result['files'], 5)

    def test_an_existing_run_or_a_non_png_record_is_refused_before_any_vm_call(self):
        (self.dir / 'out').mkdir(); (self.dir / 'out' / 'run.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'run.json exists'):
            self.run_capture()
        self.guard.assert_not_called(); self.vm.assert_not_called()
        (self.dir / 'out' / 'run.json').unlink(); self.showoff.write_bytes(b'not a png')
        with self.assertRaisesRegex(ValueError, 'not a PNG'):
            self.run_capture()
        self.guard.assert_not_called(); self.vm.assert_not_called()

    def test_guest_hash_mismatches_are_refused(self):
        for change, message in (({'source': '0' * 64}, 'source hash'), ({'scenes': {'reload-showoff.png': '0' * 64}}, 'showoff hash'),
                                ({'zipSHA256': '0' * 64}, 'Upload differs')):
            with self.subTest(message), self.assertRaisesRegex(ValueError, message):
                self.run_capture(change)
            (self.dir / 'out' / 'run.json').unlink()

    def test_a_failed_exec_is_recorded_then_raised(self):
        with self.assertRaisesRegex(RuntimeError, 'VM exec failed: boom'):
            self.run_capture(returncode=1)
        self.assertEqual(json.loads((self.dir / 'out' / 'run.json').read_text())['execError'], 'boom')



class OracleTests(unittest.TestCase):
    """Phase C: authored records uploaded as reload-oracle-<case>.png, float images gzipped on arrival."""
    STATUS = {'cases': ['map33']}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.scene = self.dir / 'scene-map33.png'; self.scene.write_bytes(b'\x89PNG\r\n\x1a\nmap33')
        self.floats = bytes(range(24))  # two float32 RGB pixels
        FakeEndpoint.instances = []

    def tearDown(self):
        self.tmp.cleanup()

    def run_oracle(self, scenes=None, guest_change=None):
        entries = {'status.json': json.dumps(self.STATUS).encode(), 'oracle-trace.json': b'{}',
                   'oracle-map33-clean-color.png': b'png', 'oracle-map33-irradiance.f32': self.floats}
        upload = archive(entries)
        guest = dict(processID=78, source=sha(probe.MAP_PROBE.read_bytes()), scenes={'reload-oracle-map33.png': sha(self.scene.read_bytes())},
                     zipSHA256=sha(upload), zipBytes=len(upload), exited=True, removed=True, remainingGameProcesses=[])
        guest.update(guest_change or {})
        FakeEndpoint.next_upload = upload
        completed = SimpleNamespace(returncode=0, stdout=json.dumps(guest), stderr='')
        args = SimpleNamespace(vm='vm', output=self.dir / 'out', scene=scenes or [f'map33={self.scene}'], errno_baseline=0,
                               host_address='10.211.55.2', wait_seconds=60)
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), \
             patch.object(probe, 'fresh_root', return_value=PLAYER_ROOT), \
             patch.object(probe, 'guarded', return_value=0) as guard, \
             patch.object(probe, 'errno_count', return_value=0), \
             patch.object(probe, 'Endpoint', FakeEndpoint), \
             patch.object(probe.subprocess, 'run', return_value=completed) as vm:
            try:
                return probe.oracle(args)
            finally:
                self.guard, self.vm = guard, vm

    def test_one_exec_uploads_the_records_and_gzips_the_float_images(self):
        result = self.run_oracle()
        out = self.dir / 'out'
        endpoint = FakeEndpoint.instances[0]
        self.assertEqual(endpoint.files['reload-oracle-map33.png'], self.scene.read_bytes())
        self.assertIn("@('reload-oracle-map33.png')", endpoint.files['run.ps1'].decode())
        self.assertEqual(self.vm.call_count, 1); self.guard.assert_called_once_with(0)
        self.assertFalse((out / 'oracle-map33-irradiance.f32').exists())
        self.assertEqual(gzip.decompress((out / 'oracle-map33-irradiance.f32.gz').read_bytes()), self.floats)
        run = json.loads((out / 'run.json').read_text())
        self.assertEqual(run['floatImages']['oracle-map33-irradiance.f32'],
                         dict(sha256=sha(self.floats), bytes=24, file='oracle-map33-irradiance.f32.gz'))
        self.assertEqual(run['scenes'], {'map33': sha(self.scene.read_bytes())})
        manifest = sorted(f['file'] for f in json.loads((out / 'manifest.json').read_text())['files'])
        self.assertEqual(manifest, ['oracle-map33-clean-color.png', 'oracle-map33-irradiance.f32.gz', 'oracle-trace.json',
                                    'probe-source.cs', 'run.json', 'status.json'])
        self.assertEqual((result['errno'], result['status']), ([0, 0], self.STATUS))

    def test_bad_scene_arguments_are_refused_before_any_vm_call(self):
        for scenes, message in (([f'Map33={self.scene}'], 'wants a new'), ([f'map33={self.scene}', f'map33={self.scene}'], 'wants a new'),
                                ([str(self.scene)], 'wants a new'), ([], 'at least one')):
            with self.subTest(scenes), self.assertRaisesRegex(ValueError, message):
                self.run_oracle(scenes=scenes or ['']) if scenes else probe.oracle_scenes([])
        self.scene.write_bytes(b'not a png')
        with self.assertRaisesRegex(ValueError, 'not a PNG'):
            self.run_oracle()
        self.vm.assert_not_called()

    def test_a_changed_record_on_the_guest_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'Guest scene hash differs'):
            self.run_oracle(guest_change={'scenes': {'reload-oracle-map33.png': '0' * 64}})

if __name__ == '__main__':
    unittest.main()
