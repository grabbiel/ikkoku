"""Legacy scene probe (ST-T05a): synthetic records and the one-exec framing; VM calls are mocked, so no VM or private data is needed."""
import io, json, subprocess, tempfile, types, unittest, zipfile
from pathlib import Path
from unittest.mock import patch
import original_legacy_scene_probe as probe

ROOT_A = r'C:\Temp\IkkokuShaderProbe-' + ('a' * 32)


def after_png(data):
    """The bytes after the PNG's IEND chunk, as SceneInfo.Load starts reading."""
    end = data.index(b'IEND') + 8
    return data[end:]


def read_text(data, offset):
    """A .NET seven-bit length-prefixed UTF-8 string at `offset`: (text, next offset)."""
    n = shift = 0
    while True:
        byte = data[offset]; offset += 1
        n |= (byte & 0x7f) << shift; shift += 7
        if not byte & 0x80: break
    return data[offset:offset + n].decode('utf-8'), offset + n


class EncodingTests(unittest.TestCase):
    def test_versions_order_as_system_version(self):
        v = probe.version_tuple
        self.assertLess(v('1.0.4'), v('1.0.4.1')); self.assertLess(v('1.0'), v('1.0.0'))
        self.assertTrue(probe.Layout('1.0.3').exactly('1.0.3'))
        self.assertFalse(probe.Layout('1.0.3.0').exactly('1.0.3')); self.assertTrue(probe.Layout('1.0.3.0').at_least('1.0.3'))

    def test_strings_and_json_floats(self):
        self.assertEqual(probe.text('ab'), b'\x02ab'); self.assertEqual(probe.text('x' * 200)[:2], b'\xc8\x01')
        self.assertEqual(probe.text('【KStudio】')[0], len('【KStudio】'.encode()))
        self.assertEqual(probe.unity_float(1), '1.0'); self.assertEqual(probe.unity_float(0.25), '0.25')
        with self.assertRaises(ValueError): probe.unity_float(0.1)

    def test_item_fields_follow_the_version_branches(self):
        size = {version: len(probe.item(probe.Layout(version), 1)) for version in ('0.0.5', '0.0.6', '0.0.7', '1.0.0', '1.0.1')}
        panel, emission = len(probe.pattern()), len(probe.color(1, 1, 1)) + 8
        self.assertEqual(size['0.0.6'] - size['0.0.5'], panel)
        self.assertEqual(size['0.0.7'] - size['0.0.6'], emission)
        self.assertEqual(size['1.0.0'], size['0.0.7']); self.assertEqual(size['1.0.1'] - size['1.0.0'], 1)

    def test_route_and_point_fields_follow_the_version_branches(self):
        def point(version, **kw): return len(probe.point(probe.Layout(version), 1, (0, 0, 0), **kw))
        base = point('1.0.0')
        self.assertEqual(point('1.0.3') - base, 1)  # the bool only 1.0.3 wrote
        self.assertEqual(point('1.0.3.0'), base); self.assertEqual(point('1.0.4'), base)
        aid = dict(aid=(2, (1, 1, 1), True))
        self.assertEqual(point('1.0.4.1', **aid) - base, 4 + 40 + 1)  # connection, the aid record, isInit
        self.assertEqual(point('1.0.4.2', **aid) - point('1.0.4.1', **aid), 1)  # link
        def route(version): return len(probe.route(probe.Layout(version), 0, 'R', [], []))
        self.assertEqual(route('1.0.3') - route('1.0.0'), 3); self.assertEqual(route('1.0.4') - route('1.0.3'), 4)
        self.assertEqual(route('1.0.4.1') - route('1.0.4'), len(probe.color(0, 0, 1)))

    def test_camera_records(self):
        # Version 1: position, rotation, one float, field of view; version 2 holds the distance's three floats.
        self.assertEqual(len(probe.camera(1, (0, 0, 0), (0, 0, 0), -3, 23)), 4 + 8 * 4)
        self.assertEqual(len(probe.camera(2, (0, 0, 0), (0, 0, 0), -3, 23)), 4 + 10 * 4)
        self.assertEqual(len(probe.settings(2)) - len(probe.settings(1)), 11 * 8)


class FixtureTests(unittest.TestCase):
    def test_synthetic_records_are_deterministic_and_carry_their_versions(self):
        first, second = probe.synthetic(), probe.synthetic()
        self.assertEqual(first, second)
        versions = {'s005-items': '0.0.5', 's006-items': '0.0.6', 's100-route': '1.0.0', 's103-route': '1.0.3',
                    's104-route': '1.0.4', 's1041-route': '1.0.4.1'}
        self.assertEqual(sorted(first), sorted(versions))
        for label, data in first.items():
            with self.subTest(label=label):
                self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n'))
                version, _ = read_text(after_png(data), 0)
                self.assertEqual(version, versions[label])
                self.assertTrue(data.endswith(probe.text('【KStudio】')))
                self.assertNotIn(b'KKEx', data)

    def test_fixtures_writes_once_and_refuses_other_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = types.SimpleNamespace(output=Path(tmp) / 'synthetic')
            written = probe.fixtures(args)
            self.assertEqual(sorted(p.name for p in args.output.iterdir()), sorted(f'{label}.png' for label in written))
            self.assertEqual(probe.fixtures(args), written)
            (args.output / 's005-items.png').write_bytes(b'other')
            with self.assertRaisesRegex(RuntimeError, 'exists with other bytes'): probe.fixtures(args)


class UploadTests(unittest.TestCase):
    def folder(self, tmp, files):
        folder = Path(tmp) / 'uploads'; folder.mkdir()
        for name, data in files.items(): (folder / name).write_bytes(data)
        return folder

    def test_accepts_only_reload_pngs(self):
        scene = probe.synthetic()['s005-items']
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(sorted(probe.uploads_from(self.folder(tmp, {'reload-s005-items.png': scene, 'reload-u005-items.png': scene}))),
                             ['reload-s005-items.png', 'reload-u005-items.png'])
        for files in ({}, {'scene.png': scene}, {'reload-S005.png': scene}, {'reload-a.png': scene, '.DS_Store': b''},
                      {'reload-a.png': b'not a png'}):
            with self.subTest(files=sorted(files)), tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
                probe.uploads_from(self.folder(tmp, files))

    def test_bounds_the_upload_size(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(probe, 'MAX_UPLOAD_BYTES', 10), self.assertRaisesRegex(ValueError, 'bound'):
            probe.uploads_from(self.folder(tmp, {'reload-a.png': probe.png()}))


class FakeEndpoint:
    upload = None
    def __init__(self, address, files, upload): self.files = files; self.base = 'http://host/token/'
    def __enter__(self): return self
    def __exit__(self, *exc): return False


class RunTests(unittest.TestCase):
    def run_phase(self, tmp, guest, upload=None, returncode=0):
        local = Path(tmp) / '.local'; uploads = local / 'uploads'; uploads.mkdir(parents=True)
        scene = probe.synthetic()['s005-items']; (uploads / 'reload-s005-items.png').write_bytes(scene)
        done = subprocess.CompletedProcess([], returncode, stdout=json.dumps(guest), stderr='exec failed')
        FakeEndpoint.upload = upload
        args = types.SimpleNamespace(output=local / 'phase', uploads=uploads, vm='vm', errno_baseline=0,
                                     host_address='10.211.55.2', wait_seconds=1800)
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()),\
             patch.object(probe, 'Endpoint', FakeEndpoint), patch.object(probe, 'guarded', return_value=0),\
             patch.object(probe, 'errno_count', return_value=0), patch.object(probe, 'fresh_root', return_value=ROOT_A),\
             patch.object(probe.subprocess, 'run', return_value=done) as run:
            result = probe.run(args)
        return args.output, result, run, scene

    def test_one_exec_records_inputs_and_hides_the_endpoint(self):
        status = {'cases': ['s005-items'], 'scope': 'private'}
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as z: z.writestr('status.json', json.dumps(status)); z.writestr('legacy-trace.json', '{}')
        data = archive.getvalue()
        with tempfile.TemporaryDirectory() as tmp:
            guest = {'processID': 7, 'exited': True, 'removed': True, 'remainingGameProcesses': [], 'scanBefore': {'a': 1}, 'scanAfter': {'a': 1},
                     'zipSHA256': probe.digest(data), 'zipBytes': len(data)}
            output, result, run, scene = self.run_phase(tmp, guest, upload=data)
            self.assertEqual(run.call_count, 1); self.assertEqual(run.call_args.args[0][:3], ['prlctl', 'exec', 'vm'])
            record = json.loads((output / 'run.json').read_text())
            self.assertEqual(record['uploads'], {'reload-s005-items.png': probe.digest(scene)})
            self.assertEqual(record['root'], ROOT_A); self.assertEqual([record['errnoBefore'], record['errnoAfter']], [0, 0])
            script = (output / 'run.ps1').read_text()
            self.assertNotIn('http://host/token/', script); self.assertIn('LegacySceneProbe.cs', script)
            self.assertIn('reload-s005-items.png', script)
            self.assertEqual(result['errno'], [0, 0]); self.assertIs(result['scansEqual'], True); self.assertIs(result['removed'], True)
            self.assertEqual(result['status'], {'cases': ['s005-items']})
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(sorted(f['file'] for f in manifest['files']),
                             ['legacy-trace.json', 'probe-source.cs', 'run.json', 'status.json'])

    def test_refuses_a_guest_hash_that_differs(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Guest scene hash differs'):
            self.run_phase(tmp, {'scenes': {'reload-s005-items.png': '0' * 64}})
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Upload differs'):
            self.run_phase(tmp, {'zipSHA256': '0' * 64, 'zipBytes': 1}, upload=b'zip')

    def test_a_failed_exec_is_recorded_and_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, 'VM exec failed'): self.run_phase(tmp, {}, returncode=1)
            record = json.loads((Path(tmp) / '.local' / 'phase' / 'run.json').read_text())
            self.assertIn('exec failed', record['execError']); self.assertEqual(record['errnoAfter'], 0)

    def test_refuses_a_used_output_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / '.local' / 'phase'; output.mkdir(parents=True); (output / 'run.json').write_text('{}')
            args = types.SimpleNamespace(output=output, uploads=Path(tmp), vm='vm', errno_baseline=0, host_address='h', wait_seconds=1)
            with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), self.assertRaisesRegex(RuntimeError, 'new output folder'):
                probe.run(args)

    def test_outputs_stay_under_local(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'under .local'):
            probe.run(types.SimpleNamespace(output=Path(tmp) / 'elsewhere', uploads=Path(tmp), vm='vm', errno_baseline=0,
                                            host_address='h', wait_seconds=1))


if __name__ == '__main__': unittest.main()
