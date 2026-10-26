"""ST-A11 map probe driver: path checks, the read-only batched fetch, placing fetched files per set, and
the one-exec capture framing. VM calls and the endpoint are mocked: no VM or private data."""
import gzip, hashlib, io, json, os, shutil, tempfile, unittest, urllib.error, urllib.request, zipfile
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
        self.assertNotIn('Copy-Item', script)  # one copy, from the game into the private root
        self.assertEqual(script.count('[IO.File]::Copy('), 1)
        self.assertIn('[IO.File]::Copy($full,"$dir\\$name")', script)
        # Hidden files (a user's tree can hold them) need -Force for Get-Item; .NET ignores the attribute.
        self.assertIn('Get-Item -LiteralPath $full -Force', script)
        self.assertNotIn('Get-FileHash', script)
        for write in ('Set-Content', 'Out-File', 'Junction', 'mklink', 'Move-Item', 'Rename-Item'):
            self.assertNotIn(write, script)
        self.assertIn("player='none: no player run, no player root, no junctions'", script)
        cleanup = script[script.index('finally{'):]
        self.assertIn('Remove-Item -LiteralPath $root -Recurse -Force', cleanup)
        self.assertIn('remainingGameProcesses', cleanup)
        self.assertIn('$r.scanAfter=Scan', cleanup)
        self.assertLess(script.index('$r.scanBefore=Scan'), script.index('[IO.File]::Copy('))

    def test_powershell_rows_keep_every_row_an_array(self):
        self.assertEqual(probe.powershell_rows([]), '@()')
        self.assertEqual(probe.powershell_rows([('a', 'b')]), "@(,@('a','b'))")
        self.assertEqual(probe.powershell_rows([('a', 'b'), ('c', 'd')]), "@(@('a','b'),@('c','d'))")
        with self.assertRaises(ValueError):
            probe.powershell_rows([('a', "b'c")])

    def test_the_listing_comes_first_and_any_bound_stops_every_copy(self):
        script = probe.fetch_script(FETCH_ROOT, 'http://h/t/', [], ['abdata/map/scene/*.unity3d'],
                                    [('scenes', 'UserData/studio/scene', '*.png')], tree_max=4 * 1024 ** 3)
        # One row needs the unary comma, or PowerShell flattens it into three strings.
        self.assertIn(r"$trees=@(,@('scenes','UserData\studio\scene','*.png'))", script)
        self.assertIn("throw 'A tree row is malformed'", script)
        self.assertIn('$treeMax=4294967296', script)
        self.assertIn('-File -Recurse -Force', script)
        for reason in ('exceed the per-file bound', 'exceeds the total bound', 'exceeds $treeMax'):
            self.assertIn(reason, script)
        listing, copying = script.index('$r.listedFiles='), script.index('[IO.File]::Copy(')
        self.assertLess(listing, copying)
        self.assertIn('while(-not $r.stopped', script[listing:copying])
        # Paths travel in the UTF-8 record, never as zip entry names: entries are index names.
        self.assertIn("$name='f{0:d5}' -f $i", script)
        self.assertIn('New-Object Text.UTF8Encoding $false', script)
        self.assertIn('NoCompression', script)
        self.assertIn('AllowWriteStreamBuffering=$false', script)
        self.assertIn('listingSHA256', script)
        self.assertIn(r"@('scenes','UserData\studio\scene')", script)

    def test_script_refuses_unknown_roots_unsafe_paths_and_batches_beyond_one_upload(self):
        with self.assertRaisesRegex(ValueError, 'Unknown private fetch root'):
            probe.fetch_script(r'C:\Illusion\Koikatsu', 'http://h/t/', [], [])
        with self.assertRaisesRegex(ValueError, 'game-relative'):
            probe.fetch_script(FETCH_ROOT, 'http://h/t/', ["abdata/x';rm"], [])
        with self.assertRaisesRegex(ValueError, 'game-relative'):
            probe.fetch_script(FETCH_ROOT, 'http://h/t/', [], ['../*.unity3d'])
        with self.assertRaisesRegex(ValueError, '--tree wants'):
            probe.fetch_script(FETCH_ROOT, 'http://h/t/', [], [], [('scenes', 'UserData', "*.png';rm")])
        with self.assertRaisesRegex(ValueError, 'fit one upload'):
            probe.fetch_script(FETCH_ROOT, 'http://h/t/', [], [], batch=probe.UPLOAD_BOUND)
        with self.assertRaisesRegex(ValueError, 'fit one upload'):
            probe.fetch_script(FETCH_ROOT, 'http://h/t/', [], [], batch=probe.MAX_FETCH_BYTES - 1)

    def test_tree_arguments_and_found_paths(self):
        self.assertEqual(probe.checked_tree('scenes:UserData/studio/scene/*.png'), ('scenes', 'UserData/studio/scene', '*.png'))
        for bad in ('UserData/studio/scene/*.png', 'Scenes:UserData/*.png', 'source:UserData/*.png', 'scenes:../x/*.png',
                    'scenes:UserData/a b/*.png;x', 'scenes:*.png'):
            with self.subTest(bad), self.assertRaises(ValueError):
                probe.checked_tree(bad)
        found = 'UserData/studio/scene/Pack 1/\u30b7\u30fc\u30f3/a (2).PNG'
        self.assertEqual(probe.checked_found(found, 'UserData/studio/scene', '*.png', recursive=True),
                         found[len('UserData/studio/scene/'):])
        for bad in ('UserData/studio/scene/../x.png', 'UserData/studio/scene//x.png', 'UserData/studio/scene/x.txt',
                    'UserData/studio/sceneX/x.png', 'UserData/studio/scene/a\\b.png', 'UserData/studio/scene/C:x.png',
                    'UserData/studio/scene/a\nb.png', 'UserData/studio/scene/'):
            with self.subTest(bad), self.assertRaisesRegex(ValueError, 'Unexpected fetched path'):
                probe.checked_found(bad, 'UserData/studio/scene', '*.png', recursive=True)
        with self.assertRaisesRegex(ValueError, 'Unexpected fetched path'):
            probe.checked_found('abdata/map/scene/sub/x.unity3d', 'abdata/map/scene', '*.unity3d', recursive=False)


class FakeFetchEndpoint:
    """FetchEndpoint's surface: on entry, `next_uploads` arrive in `incoming` as the guest would PUT them."""
    instances, next_uploads = [], {}

    def __init__(self, address, files, incoming, total):
        self.files, self.incoming, self.uploads = files, incoming, {}
        self.base = 'http://10.211.55.2:1/' + 'c' * 32 + '/'
        FakeFetchEndpoint.instances.append(self)

    def __enter__(self):
        for name, data in FakeFetchEndpoint.next_uploads.items():
            path = self.incoming / name
            path.write_bytes(data)
            self.uploads[name] = dict(path=path, bytes=len(data), sha256=sha(data))
        return self

    def __exit__(self, *exc): return False


class FetchEndpointTests(unittest.TestCase):
    """The real endpoint on the loopback: each allowed upload once, streamed to disk with its hash; anything else refused."""
    def put(self, endpoint, name, data):
        request = urllib.request.Request(endpoint.base + name, data=data, method='PUT', headers={'Content-Length': str(len(data))})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    def test_uploads_are_streamed_once_each_within_the_bounds(self):
        with tempfile.TemporaryDirectory() as tmp:
            incoming = Path(tmp)
            with probe.FetchEndpoint('127.0.0.1', {'run.ps1': b'script'}, incoming, total=64) as endpoint:
                with urllib.request.urlopen(endpoint.base + 'run.ps1', timeout=10) as response:
                    self.assertEqual(response.read(), b'script')
                self.assertEqual(self.put(endpoint, 'fetch-1.zip', b'zip-one'), 200)
                self.assertEqual(self.put(endpoint, 'fetch-1.zip', b'again'), 403)
                self.assertEqual(self.put(endpoint, 'fetch-record.json', b'{}'), 200)
                for name in ('fetch-0.zip', 'other.zip', '../fetch-2.zip', 'fetch-2.zip/x'):
                    self.assertEqual(self.put(endpoint, name, b'x'), 403, name)
                self.assertEqual(self.put(endpoint, 'fetch-2.zip', b'x' * 64), 403)  # over the total bound
                uploads = dict(endpoint.uploads)
            self.assertEqual(sorted(uploads), ['fetch-1.zip', 'fetch-record.json'])
            self.assertEqual(uploads['fetch-1.zip']['sha256'], sha(b'zip-one'))
            self.assertEqual((incoming / 'fetch-1.zip').read_bytes(), b'zip-one')
            self.assertEqual(sorted(p.name for p in incoming.iterdir()), ['fetch-1.zip', 'fetch-record.json'])


class FetchTests(unittest.TestCase):
    """The batched fetch: one exec, the record and the batch zips checked, files placed per set."""
    BUNDLE, LIST, SCENE = b'bundle-bytes', b'list', b'\x89PNG scene'
    SCENE_PATH = 'UserData/studio/scene/Pack/\u30b7\u30fc\u30f3.png'
    GLOBS = ['abdata/map/scene/*.unity3d', 'abdata/h/list/*.unity3d']

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        FakeFetchEndpoint.instances = []

    def tearDown(self):
        self.tmp.cleanup()

    def guest_files(self):
        return [dict(path='abdata/map/scene/1f.unity3d', set=self.GLOBS[0], name='f00000', batch=1,
                     bytes=len(self.BUNDLE), sha256=sha(self.BUNDLE)),
                dict(path='abdata/h/list/00.unity3d', set=self.GLOBS[1], name='f00001', batch=1, bytes=len(self.LIST), sha256=sha(self.LIST)),
                dict(path=self.SCENE_PATH, set='scenes', name='f00002', batch=2, bytes=len(self.SCENE), sha256=sha(self.SCENE))]

    def run_fetch(self, files=None, zips=None, guest_change=None, returncode=0, trees=None, stopped=None):
        files = self.guest_files() if files is None else files
        data = {'f00000': self.BUNDLE, 'f00001': self.LIST, 'f00002': self.SCENE}
        if zips is None:
            zips = {}
            for f in files:
                zips.setdefault(f['batch'], {})[f['name']] = data[f['name']]
        uploads = {f'fetch-{k}.zip': archive(v) for k, v in zips.items()}
        sets = {self.GLOBS[0]: dict(files=1, bytes=len(self.BUNDLE), largest=len(self.BUNDLE))}
        uploads['fetch-record.json'] = json.dumps(dict(files=files, missing=[], sets=sets), ensure_ascii=False).encode('utf-8')
        scan = {'abdata': dict(files=4565, dirs=443, bytes=1, listingSHA256='0' * 64)}
        guest = dict(root='r', sets=sets, listedFiles=len(files), missing=0, removed=True, remainingGameProcesses=[],
                     scanBefore=scan, scanAfter=scan, recordSHA256=sha(uploads['fetch-record.json']),
                     recordBytes=len(uploads['fetch-record.json']),
                     batches=[dict(batch=int(n[6:-4]), zipSHA256=sha(d), zipBytes=len(d)) for n, d in uploads.items() if n.endswith('.zip')])
        if stopped:
            guest['stopped'] = stopped
        guest.update(guest_change or {})
        FakeFetchEndpoint.next_uploads = uploads
        completed = SimpleNamespace(returncode=returncode, stdout='\ufeff' + json.dumps(guest), stderr='boom' if returncode else '')
        args = SimpleNamespace(vm='vm', output=self.dir / 'fetch', file=None, glob=list(self.GLOBS),
                               tree=trees or ['scenes:UserData/studio/scene/*.png'], batch_bytes=probe.BATCH_BYTES,
                               max_total_bytes=probe.MAX_TOTAL_BYTES, tree_max_bytes=probe.TREE_MAX_BYTES, errno_baseline=0,
                               host_address='10.211.55.2', timeout=60)
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), \
             patch.object(probe, 'guarded', return_value=0) as guard, \
             patch.object(probe, 'errno_count', return_value=0), \
             patch.object(probe, 'FetchEndpoint', FakeFetchEndpoint), \
             patch.object(probe.subprocess, 'run', return_value=completed) as vm:
            try:
                return probe.fetch(args)
            finally:
                self.guard, self.vm = guard, vm

    def test_one_exec_places_bundles_under_source_and_the_tree_under_its_label(self):
        result = self.run_fetch()
        out = self.dir / 'fetch'
        self.assertEqual(self.vm.call_count, 1); self.guard.assert_called_once_with(0)
        self.assertEqual((out / 'source/abdata/map/scene/1f.unity3d').read_bytes(), self.BUNDLE)
        self.assertEqual((out / 'source/abdata/h/list/00.unity3d').read_bytes(), self.LIST)
        self.assertEqual((out / 'scenes' / self.SCENE_PATH[len('UserData/studio/scene/'):]).read_bytes(), self.SCENE)
        self.assertFalse((out / 'incoming').exists())  # the zips and the record are deleted once placed
        endpoint = FakeFetchEndpoint.instances[0]
        self.assertIn(r"@('scenes','UserData\studio\scene','*.png')", endpoint.files['run.ps1'].decode())
        self.assertIn('<endpoint>/', (out / 'run.ps1').read_text())
        self.assertNotIn(endpoint.base, (out / 'run.ps1').read_text())
        record = json.loads((out / 'fetch.json').read_text())
        self.assertEqual(record['requestedFiles'], [])  # named sets replace the defaults
        self.assertEqual(record['listing']['sets'], {self.GLOBS[0]: dict(files=1, bytes=12, largest=12)})
        self.assertTrue(all(f['localSHA256'] == f['sha256'] for f in record['files']))
        self.assertEqual(record['player'], 'none (no player root, no junctions)')
        self.assertEqual((result['files'], result['batches'], result['errno'], result['scansEqual']), (3, 2, [0, 0], True))

    def test_a_stopped_listing_copies_nothing_and_keeps_the_numbers(self):
        result = self.run_fetch(files=[], zips={}, stopped='tree scenes (5 bytes) exceeds 4')
        self.assertEqual((result['files'], result['stopped']), (0, 'tree scenes (5 bytes) exceeds 4'))
        record = json.loads((self.dir / 'fetch' / 'fetch.json').read_text())
        self.assertEqual(record['guest']['stopped'], 'tree scenes (5 bytes) exceeds 4')
        self.assertIn(self.GLOBS[0], record['listing']['sets'])

    def test_changed_extra_or_misplaced_files_are_refused(self):
        def changed(index, **values):
            files = self.guest_files(); files[index].update(values); return files
        cases = [
            (dict(files=changed(0, sha256='0' * 64)), 'differs from the guest record'),
            (dict(zips={1: {'f00000': self.BUNDLE, 'f00001': self.LIST, 'extra': b''}, 2: {'f00002': self.SCENE}}),
             'exactly the recorded files'),
            (dict(guest_change={'batches': [dict(batch=1, zipSHA256='0' * 64, zipBytes=1), dict(batch=2, zipSHA256='0' * 64, zipBytes=1)]}),
             'different from the guest zip'),
            (dict(guest_change={'batches': []}), 'different batches'),
            (dict(guest_change={'recordSHA256': '0' * 64}), 'record differs'),
            (dict(guest_change={'error': 'boom'}), 'Guest fetch failed: boom'),
            (dict(files=changed(2, path='UserData/studio/scene/../../../x.png')), 'Unexpected fetched path'),
            (dict(files=changed(0, set='abdata/other/*.unity3d')), 'not requested'),
            (dict(files=changed(0, path='abdata/map/scene/sub/1f.unity3d')), 'Unexpected fetched path'),
        ]
        for kwargs, message in cases:
            with self.subTest(message), self.assertRaisesRegex((ValueError, RuntimeError), message):
                self.run_fetch(**kwargs)
            shutil.rmtree(self.dir / 'fetch')

    def test_a_failed_exec_is_recorded_and_an_existing_fetch_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'VM exec failed: boom'):
            self.run_fetch(returncode=1)
        self.assertEqual(json.loads((self.dir / 'fetch' / 'fetch.json').read_text())['execError'], 'boom')
        with self.assertRaisesRegex(RuntimeError, 'fetch.json exists'):
            self.run_fetch()
        self.vm.assert_not_called()

    def test_bad_trees_are_refused_before_any_vm_call(self):
        for trees, message in ((['scenes:UserData/studio/scene/*.png', 'scenes:UserData/x/*.png'], 'labels must differ'),
                               (['UserData/studio/scene/*.png'], '--tree wants')):
            with self.subTest(message), self.assertRaisesRegex(ValueError, message):
                self.run_fetch(trees=trees)
            self.vm.assert_not_called(); self.guard.assert_not_called()


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


class Map34Tests(unittest.TestCase):
    """Slice 3: map 34's phases B and C in one exec, selected by the reload-map34-showoff.png upload."""
    STATUS = {'cases': ['map34-day', 'map34-evening', 'map34-night', 'map34-showoff']}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.showoff = self.dir / 'showoff.png'; self.showoff.write_bytes(b'\x89PNG\r\n\x1a\nscene')
        self.rgb, self.rgba = bytes(range(24)), bytes(range(32))  # two float32 RGB / RGBA pixels
        FakeEndpoint.instances = []

    def tearDown(self):
        self.tmp.cleanup()

    def run_map34(self, entries=None):
        entries = entries or {'status.json': json.dumps(self.STATUS).encode(), 'map-trace.json': b'{}',
                              'original-map34-day-color.png': b'png', 'oracle-map34-day-irradiance.f32': self.rgb,
                              'oracle-map34-day-sky.rgba.f32': self.rgba, 'oracle-map34-day-classes.png': b'png'}
        upload = archive(entries)
        guest = dict(processID=79, source=sha(probe.MAP_PROBE.read_bytes()), scenes={probe.MAP34_UPLOAD: sha(self.showoff.read_bytes())},
                     zipSHA256=sha(upload), zipBytes=len(upload), exited=True, removed=True, remainingGameProcesses=[])
        FakeEndpoint.next_upload = upload
        completed = SimpleNamespace(returncode=0, stdout=json.dumps(guest), stderr='')
        args = SimpleNamespace(vm='vm', output=self.dir / 'out', showoff=self.showoff, errno_baseline=0, host_address='10.211.55.2', wait_seconds=60)
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), \
             patch.object(probe, 'fresh_root', return_value=PLAYER_ROOT), \
             patch.object(probe, 'guarded', return_value=0) as guard, \
             patch.object(probe, 'errno_count', return_value=0), \
             patch.object(probe, 'Endpoint', FakeEndpoint), \
             patch.object(probe.subprocess, 'run', return_value=completed) as vm:
            try:
                return probe.map34(args)
            finally:
                self.guard, self.vm = guard, vm

    def test_one_exec_uploads_the_showoff_under_the_map34_name_and_gzips_rgb_and_rgba_floats(self):
        result = self.run_map34()
        out = self.dir / 'out'
        endpoint = FakeEndpoint.instances[0]
        self.assertEqual(endpoint.files['reload-map34-showoff.png'], self.showoff.read_bytes())
        self.assertNotIn('reload-showoff.png', endpoint.files)
        script = endpoint.files['run.ps1'].decode()
        self.assertIn("@('reload-map34-showoff.png')", script)
        # The junction scans: before the player setup, after the cleanup, read only.
        self.assertLess(script.index('$r.scanBefore=Scan'), script.index("Fetch 'MapProbe.cs'"))
        self.assertGreater(script.index('$r.scanAfter=Scan'), script.index('$r.removed='))
        self.assertTrue(script.endswith('try{$r.scanAfter=Scan}catch{$r.scanAfterError=$_.ToString()}\n[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 4\n'))
        scan = probe.JUNCTION_SCAN
        self.assertIn('Get-ChildItem', scan); self.assertNotRegex(scan, 'Remove-|Set-|New-|Copy-|Move-|Out-File')
        self.assertEqual(self.vm.call_count, 1); self.guard.assert_called_once_with(0)
        self.assertEqual(gzip.decompress((out / 'oracle-map34-day-sky.rgba.f32.gz').read_bytes()), self.rgba)
        self.assertEqual(gzip.decompress((out / 'oracle-map34-day-irradiance.f32.gz').read_bytes()), self.rgb)
        run = json.loads((out / 'run.json').read_text())
        self.assertEqual((run['mode'], run['showoffSHA256']), ('map34', sha(self.showoff.read_bytes())))
        self.assertEqual(run['floatImages']['oracle-map34-day-sky.rgba.f32'], dict(sha256=sha(self.rgba), bytes=32, file='oracle-map34-day-sky.rgba.f32.gz'))
        manifest = sorted(f['file'] for f in json.loads((out / 'manifest.json').read_text())['files'])
        self.assertEqual(manifest, ['map-trace.json', 'oracle-map34-day-classes.png', 'oracle-map34-day-irradiance.f32.gz',
                                    'oracle-map34-day-sky.rgba.f32.gz', 'original-map34-day-color.png', 'probe-source.cs', 'run.json', 'status.json'])
        self.assertEqual((result['errno'], result['status']), ([0, 0], self.STATUS))
        self.assertFalse(result['scansEqual'])  # the fake guest reports none

    def test_an_rgba_image_whose_size_is_not_whole_pixels_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'not float32 RGBA'):
            self.run_map34({'status.json': b'{}', 'oracle-map34-day-sky.rgba.f32': bytes(24)})

    def test_a_non_png_showoff_or_an_existing_run_is_refused_before_any_vm_call(self):
        self.showoff.write_bytes(b'not a png')
        with self.assertRaisesRegex(ValueError, 'not a PNG'):
            self.run_map34()
        self.vm.assert_not_called(); self.guard.assert_not_called()
        self.showoff.write_bytes(b'\x89PNG\r\n\x1a\nscene'); (self.dir / 'out').mkdir(); (self.dir / 'out' / 'run.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'run.json exists'):
            self.run_map34()
        self.vm.assert_not_called()

    def test_the_probe_source_selects_map34_by_that_upload_and_keeps_map33_names(self):
        source = probe.MAP_PROBE.read_text()
        self.assertIn('Map34Upload="reload-map34-showoff.png"', source)
        for label in ('map34-day', 'map34-evening', 'map34-night', 'map34-showoff', '"map33"', '"map33-showoff"'):
            self.assertIn(label, source)
        self.assertIn('DepthFar33=25f', source); self.assertIn('DepthFar34=1000f', source)


if __name__ == '__main__':
    unittest.main()
