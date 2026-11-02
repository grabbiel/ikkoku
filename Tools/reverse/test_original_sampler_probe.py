"""Sampler probe (#348): the one-exec framing, the rule restatement, the frame metrics, analyse and the survey summary.
VM calls are mocked and every image is synthetic, so no VM or private data is needed."""
import io, json, subprocess, tempfile, types, unittest, zipfile
from pathlib import Path
from unittest.mock import patch
import numpy as np
from PIL import Image
import original_sampler_probe as probe
import original_scene_reload_probe as reload_probe

ROOT_A = r'C:\Temp\IkkokuShaderProbe-' + ('a' * 32)
SIZE = 16


class FakeEndpoint:
    upload = None
    def __init__(self, address, files, upload): self.files = files; self.base = 'http://host/token/'; self.upload_name = upload
    def __enter__(self): return self
    def __exit__(self, *exc): return False


def zipped(entries):
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w') as z:
        for name, data in entries.items(): z.writestr(name, data)
    return archive.getvalue()


class RunTests(unittest.TestCase):
    def run_phase(self, tmp, guest, upload=None, returncode=0):
        done = subprocess.CompletedProcess([], returncode, stdout=json.dumps(guest), stderr='exec failed')
        FakeEndpoint.upload = upload
        args = types.SimpleNamespace(output=Path(tmp) / '.local' / 'phase', vm='vm', errno_baseline=0, host_address='10.211.55.2', wait_seconds=2400)
        with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), patch.object(probe, 'Endpoint', FakeEndpoint),\
             patch.object(probe, 'guarded', return_value=0) as guard, patch.object(probe, 'errno_count', return_value=0),\
             patch.object(probe, 'fresh_root', return_value=ROOT_A), patch.object(probe.subprocess, 'run', return_value=done) as run:
            result = probe.run(args)
        return args.output, result, run, guard

    def test_one_exec_compiles_the_probe_with_no_upload_and_scans_the_junctions(self):
        data = zipped({'status.json': json.dumps({'cells': 90, 'scope': 'private'}), 'sampler-trace.json': '{}'})
        with tempfile.TemporaryDirectory() as tmp:
            guest = {'processID': 7, 'exited': True, 'removed': True, 'remainingGameProcesses': [], 'scanBefore': {'a': 1}, 'scanAfter': {'a': 1},
                     'source': probe.digest(probe.PROBE.read_bytes()), 'zipSHA256': probe.digest(data), 'zipBytes': len(data)}
            output, result, run, guard = self.run_phase(tmp, guest, upload=data)
            guard.assert_called_once_with(0)
            self.assertEqual(run.call_count, 1); self.assertEqual(run.call_args.args[0][:3], ['prlctl', 'exec', 'vm'])
            script = (output / 'run.ps1').read_text()
            self.assertNotIn('http://host/token/', script)
            self.assertIn("Fetch 'SamplerProbe.cs'", script); self.assertIn('IkkokuSamplerProbe.dll', script)
            self.assertIn('foreach($n in @())', script)  # no scene record goes with this probe
            self.assertIn("'-logFile',\"$root\\unity.log\"", script)
            self.assertIn('$r.scanBefore=Scan', script); self.assertIn('$r.scanAfter=Scan', script)
            self.assertIn('remainingGameProcesses', script[script.index('finally{'):])
            record = json.loads((output / 'run.json').read_text())
            self.assertEqual(record['root'], ROOT_A); self.assertEqual([record['errnoBefore'], record['errnoAfter']], [0, 0])
            self.assertEqual(result['errno'], [0, 0]); self.assertIs(result['scansEqual'], True); self.assertEqual(result['remainingGameProcesses'], [])
            self.assertEqual(result['status'], {'cells': 90})
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(sorted(f['file'] for f in manifest['files']), ['probe-source.cs', 'run.json', 'sampler-trace.json', 'status.json'])

    def test_refuses_a_guest_source_or_zip_that_differs(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Guest probe source hash differs'):
            self.run_phase(tmp, {'source': '0' * 64})
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'Upload differs'):
            self.run_phase(tmp, {'zipSHA256': '0' * 64, 'zipBytes': 1}, upload=b'zip')

    def test_a_failed_exec_is_recorded_and_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, 'VM exec failed'): self.run_phase(tmp, {}, returncode=1)
            record = json.loads((Path(tmp) / '.local' / 'phase' / 'run.json').read_text())
            self.assertIn('exec failed', record['execError']); self.assertEqual(record['errnoAfter'], 0)

    def test_refuses_a_used_output_folder_and_outputs_outside_local(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / '.local' / 'phase'; output.mkdir(parents=True); (output / 'run.json').write_text('{}')
            args = types.SimpleNamespace(output=output, vm='vm', errno_baseline=0, host_address='h', wait_seconds=1)
            with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()), patch.object(probe, 'guarded') as guard:
                with self.assertRaisesRegex(RuntimeError, 'new output folder'): probe.run(args)
                guard.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(ValueError, 'under .local'):
            probe.run(types.SimpleNamespace(output=Path(tmp) / 'elsewhere', vm='vm', errno_baseline=0, host_address='h', wait_seconds=1))

    def test_once_script_takes_no_upload_only_when_asked(self):
        with self.assertRaisesRegex(ValueError, 'Unexpected scene upload names'): reload_probe.once_script(ROOT_A, 'http://h/t/', 60, [])
        script = reload_probe.once_script(ROOT_A, 'http://h/t/', 60, [], *probe.PROBE_NAMES, allow_no_uploads=True)
        self.assertIn('foreach($n in @())', script)
        with self.assertRaisesRegex(ValueError, 'Unexpected scene upload names'):
            reload_probe.once_script(ROOT_A, 'http://h/t/', 60, ['reload-../x.png'], allow_no_uploads=True)


class ProbeSourceTests(unittest.TestCase):
    SOURCE = probe.PROBE.read_text()

    def test_restores_the_mode_and_fog_and_unloads_what_it_loads(self):
        finally_block = self.SOURCE[self.SOURCE.index('finally {\n                QualitySettings.anisotropicFiltering=originalMode'):]
        self.assertIn('RenderSettings.fog=originalFog', finally_block[:200])
        self.assertIn('bundle.Unload(true)', self.SOURCE); self.assertIn('if(bundle!=null&&!held)bundle.Unload(true)', self.SOURCE)
        self.assertIn('"qualityRestored"', self.SOURCE)

    def test_reads_settings_only_and_writes_only_its_folder(self):
        for forbidden in ('GetPixels', 'GetRawTextureData', 'LoadAllAssets()', 'File.Delete', 'Directory.Delete', 'PlayerPrefs', 'SetQualityLevel'):
            self.assertNotIn(forbidden, self.SOURCE)
        writes = [line for line in self.SOURCE.splitlines() if 'File.Write' in line]
        self.assertTrue(writes); self.assertTrue(all('Path.Combine(folder,' in line for line in writes))

    def test_matrix_matches_the_driver(self):
        self.assertIn('Filters={"Point","Bilinear","Trilinear"}', self.SOURCE); self.assertIn('Anisos={0,1,2,8,16}', self.SOURCE)
        self.assertIn('SurveyRoots={"chara","studio","map"}', self.SOURCE)
        self.assertEqual(probe.LEVEL_VALUES, [0, 32, 64, 96, 128, 159, 191, 223, 255])


class RuleTests(unittest.TestCase):
    def test_restates_the_swift_rule(self):
        """SourceShaderCompositeTests' Point/Bilinear cases (liveSourceSamplerConfigurationPreservesTheDescriptorContract)."""
        rule = probe.rule_candidate
        self.assertEqual(rule('Point', 1, 'Enable'), 'point'); self.assertEqual(rule('Point', 16, 'Enable'), 'ours-a16')
        self.assertEqual(rule('Point', 8, 'Disable'), 'point')
        self.assertEqual(rule('Point', 1, 'ForceEnable'), 'point'); self.assertEqual(rule('Point', 8, 'ForceEnable'), 'ours-a8')
        self.assertEqual(rule('Bilinear', 0, 'ForceEnable'), 'bilinear'); self.assertEqual(rule('Bilinear', 1, 'ForceEnable'), 'aniso-a9')
        self.assertEqual(rule('Bilinear', 8, 'ForceEnable'), 'aniso-a9'); self.assertEqual(rule('Bilinear', 16, 'ForceEnable'), 'aniso-a16')
        self.assertEqual(rule('Trilinear', 1, 'Enable'), 'trilinear'); self.assertEqual(rule('Bilinear', 2, 'Enable'), 'aniso-a2')

    def test_every_rule_prediction_has_a_host_candidate(self):
        for f in probe.FILTERS:
            for a in probe.ANISOS:
                for m in probe.MODES: self.assertIn(probe.rule_candidate(f, a, m), probe.CANDIDATES)


def grazing_frame(levels, blend=False):
    """Top row background, then one surface row per entry of `levels` (exact level values, or halfway to the next)."""
    frame = np.zeros((len(levels) + 1, SIZE, 4), dtype=np.int16); frame[0] = (0, 0, 255, 0)
    for y, level in enumerate(levels, 1):
        r = probe.LEVEL_VALUES[level] + (16 if blend else 0)
        frame[y] = (r, 0, 0, 255)
    return frame


def magnified_frame(linear):
    frame = np.zeros((SIZE, SIZE, 4), dtype=np.int16); frame[..., 3] = 255
    x = np.arange(SIZE)
    green = (np.clip(np.abs((x % 8) - 4) * 64, 0, 255) if linear else (x // 4 % 2) * 255)
    frame[..., 1] = green[None, :]
    return frame


class MetricTests(unittest.TestCase):
    def test_point_frames_show_no_linear_filtering(self):
        m = probe.frame_metrics(grazing_frame([8, 5, 2, 0]), magnified_frame(False), True)
        self.assertEqual(m['magnifiedLinearFraction'], 0.0); self.assertEqual(m['grazingBlendedFraction'], 0.0)
        self.assertEqual(m['magnifiedLevels'], [0]); self.assertEqual(m['rowLevels'][0], None); self.assertEqual(m['rowLevels'][1:], [8.0, 5.0, 2.0, 0.0])

    def test_linear_frames_show_linear_filtering(self):
        m = probe.frame_metrics(grazing_frame([5, 2, 0], blend=True), magnified_frame(True), True)
        self.assertGreater(m['magnifiedLinearFraction'], probe.LINEAR_G); self.assertGreater(m['grazingBlendedFraction'], probe.BLENDED_R)
        self.assertIsNone(probe.frame_metrics(grazing_frame([0]), magnified_frame(True), False)['grazingBlendedFraction'])

    def test_refuses_frames_without_a_surface_or_upside_down(self):
        empty = np.zeros((4, SIZE, 4), dtype=np.int16); empty[...] = (0, 0, 255, 0)
        with self.assertRaisesRegex(ValueError, 'no textured surface'): probe.frame_metrics(empty, magnified_frame(False), True)
        with self.assertRaisesRegex(ValueError, 'horizon-up'): probe.frame_metrics(grazing_frame([0, 3])[::-1], magnified_frame(False), True)

    def test_finer_levels_against_the_aniso0_rows(self):
        self.assertEqual(probe.finer_by([None, 2.0, 1.0], [None, 5.0, 3.0]), 2.5); self.assertIsNone(probe.finer_by([None], [None]))

    def test_contrast_share_against_the_aniso0_rows(self):
        self.assertEqual(probe.contrast_share([None, 20.0, 30.0], [None, 40.0, 60.0]), 0.5); self.assertIsNone(probe.contrast_share([None], [None]))


def png(path, frame): Image.fromarray(frame.astype(np.uint8), 'RGBA').save(path)


class AnalyseTests(unittest.TestCase):
    def test_names_the_nearest_candidate_and_the_rule_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture, reference = Path(tmp) / '.local' / 'capture', Path(tmp) / '.local' / 'reference'
            capture.mkdir(parents=True); reference.mkdir()
            iso, aniso = grazing_frame([8, 6, 4, 2]), grazing_frame([6, 3, 1, 0])
            frames = {'point-a0-mips-forceenable': (iso, magnified_frame(False)), 'point-a8-mips-forceenable': (aniso, magnified_frame(True))}
            cells = []
            for cid, (g, m) in frames.items():
                png(capture / f'cell-{cid}-grazing.png', g); png(capture / f'cell-{cid}-magnified.png', m)
                aniso_level = int(cid.split('-')[1][1:])
                cells.append(dict(id=cid, filter='Point', aniso=aniso_level, mipmapped=True, mode='ForceEnable', readBack={},
                                  grazing=dict(file=f'cell-{cid}-grazing.png'), magnified=dict(file=f'cell-{cid}-magnified.png')))
            quality = dict(anisotropicFiltering='ForceEnable')
            (capture / 'sampler-trace.json').write_text(json.dumps(dict(cells=cells, shader='Unlit/Texture', qualityBefore=quality, qualityAfter=quality,
                                                                         modes=['ForceEnable'], restoredCheck=dict(matches=True))))
            survey = dict(columns=['bundle', 'name', 'filter', 'aniso', 'mips', 'width', 'height', 'wrap'],
                          textures=[['chara/a.unity3d', 't', 'Point', 4, 1, 8, 8, 'Clamp'], ['chara/a.unity3d', 'u', 'Bilinear', 1, 9, 256, 256, 'Repeat']],
                          bundles=[dict(bundle='chara/a.unity3d', status='read', held=False, textures=2), dict(bundle='map/s.unity3d', status='scene', held=False)],
                          truncated=False)
            (capture / 'sampler-survey.json').write_text(json.dumps(survey))
            for name, (g, m) in {'point': (iso, magnified_frame(False)), 'aniso-a9': (aniso, magnified_frame(True)), 'aniso-a16': (aniso, magnified_frame(True)),
                                 'ours-a8': (aniso, magnified_frame(False))}.items():
                png(reference / f'{name}-mips-grazing.png', g); png(reference / f'{name}-mips-magnified.png', m)
            out = Path(tmp) / '.local' / 'analysis.json'
            with patch.object(probe, 'private', side_effect=lambda p: Path(p).resolve()):
                summary = probe.analyse(types.SimpleNamespace(capture=capture, reference=reference, output=out))
            report = json.loads(out.read_text())
            cell = {c['id']: c for c in report['cells']}['point-a8-mips-forceenable']
            self.assertEqual(cell['verdict']['minMag'], 'linear'); self.assertEqual(cell['verdict']['mips'], 'point')
            self.assertIs(cell['verdict']['anisotropic'], True); self.assertEqual(cell['verdict']['finerThanAniso0'], 2.5)
            self.assertEqual(cell['rule'], 'ours-a8'); self.assertEqual(cell['nearest'], ['aniso-a9', 'aniso-a16']); self.assertIs(cell['ruleMatches'], False)
            self.assertGreater(cell['margin'], 0)  # identical renders tie; the next candidate is further
            self.assertEqual(report['ruleMismatches'], ['point-a8-mips-forceenable'])
            self.assertIs(report['qualityRestored'], True); self.assertIs(report['restoredCellMatches'], True)
            self.assertEqual(summary['survey']['point'], {'aniso >1': 1}); self.assertEqual(report['survey']['pointAnisoAbove1'], ['chara/a.unity3d'])
            self.assertEqual(report['survey']['bundleStatus'], {'read': 1, 'scene': 1}); self.assertEqual(report['survey']['byTop'], {'chara': 2})


if __name__ == '__main__': unittest.main()
