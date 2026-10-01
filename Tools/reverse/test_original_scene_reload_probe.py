"""Scene-reload probe driver framing; VM calls are mocked, so no VM or private data is needed."""
import contextlib, hashlib, io, json, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import original_scene_reload_probe as probe

ROOT_A=r'C:\Temp\IkkokuShaderProbe-'+('a'*32)

def scenes(tmp):
    out={}
    for label in probe.LABELS:
        path=Path(tmp)/(label+'.png');path.write_bytes(b'png-'+label.encode())
        out[label]=path
    return out

class StartTests(unittest.TestCase):
    def test_start_uploads_source_compiles_uploads_scenes_then_launches(self):
        events=[]
        with tempfile.TemporaryDirectory() as tmp,\
             patch('original_scene_reload_probe.player_root',return_value=ROOT_A) as root,\
             patch('original_scene_reload_probe.write_small',side_effect=lambda vm,path,data:events.append(('upload',path,data))),\
             patch('original_scene_reload_probe.retry',side_effect=lambda vm,script,user=False:events.append(('launch' if user else 'compile',script)) or ('4321' if user else '')):
            inputs=scenes(tmp)
            run=probe.start('vm',Path(tmp),scenes=inputs)
            recorded=json.loads((Path(tmp)/'run.json').read_text())
            self.assertEqual((Path(tmp)/'probe-source.cs').read_bytes(),probe.SOURCE.read_bytes())
            expected_stop=inputs['route-stop'].read_bytes()
            expected_hashes={label:hashlib.sha256(p.read_bytes()).hexdigest() for label,p in inputs.items()} # inputs live inside the temp dir
        root.assert_called_once_with('vm',Path(tmp))
        self.assertEqual([e[0] for e in events],['upload','compile','upload','upload','upload','upload','launch'])
        self.assertEqual(events[0][1],ROOT_A+r'\SceneReloadProbe.cs')
        self.assertEqual([e[1] for e in events[2:6]],
                         [ROOT_A+r'\BepInEx\plugins\reload-'+label+'.png' for label in probe.LABELS])
        self.assertEqual(events[4][2],expected_stop)
        self.assertIn(r'IkkokuSceneReloadProbe.dll',events[1][1]);self.assertIn(r'plugins\reload',events[1][1]);self.assertIn('Compile failed',events[1][1])
        self.assertIn(r"$root\CharaStudio.exe",events[6][1])
        self.assertEqual(run,recorded);self.assertEqual(recorded['processID'],4321);self.assertEqual(recorded['root'],ROOT_A)
        self.assertEqual(recorded['sceneSHA256'],expected_hashes)

class CollectTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.output=Path(self.tmp.name)
        (self.output/'run.json').write_text(json.dumps(dict(vm='vm',root=ROOT_A,processID=77,stopped=False,
            sceneSHA256={label:'h' for label in probe.LABELS})))
    def tearDown(self):self.tmp.cleanup()

    def test_unfinished_probe_is_left_running(self):
        with patch('original_scene_reload_probe.fetch',side_effect=RuntimeError('VM read failed (1): cannot find path')) as fetch,patch('original_scene_reload_probe.stop_probe') as stop:
            with self.assertRaises(RuntimeError):probe.collect('vm',self.output)
        self.assertTrue(fetch.call_args_list[0].args[1].endswith(r'\plugins\reload\status.json'))
        stop.assert_not_called();self.assertFalse((self.output/'status.json').exists())

    def test_finished_probe_is_stopped_then_every_result_is_fetched_and_listed(self):
        files={'status.json':json.dumps(dict(error=None)).encode(),'reload-trace.json':b'{}',
               'reload-camera-switch.png':b'c','reload-hide-rename.png':b'h','reload-route-stop.png':b'r',
               'reload-route-rename.png':b'n','unity.log':b'log'}
        def fetch(vm,path,limit=None):
            name=path.rsplit('\\',1)[1]
            if name not in files:raise RuntimeError('missing '+name)
            return files[name]
        with patch('original_scene_reload_probe.fetch',side_effect=fetch),patch('original_scene_reload_probe.stop_probe') as stop:
            result=probe.collect('vm',self.output)
        stop.assert_called_once();self.assertEqual(stop.call_args.args[1]['processID'],77)
        self.assertTrue(json.loads((self.output/'run.json').read_text())['stopped'])
        listed={f['file'] for f in json.loads((self.output/'manifest.json').read_text())['files']}
        self.assertEqual(listed,{'status.json','reload-trace.json','reload-camera-switch.png','reload-hide-rename.png','reload-route-stop.png','reload-route-rename.png','unity.log','run.json'})
        self.assertEqual(result['files'],8)

    def test_failed_probe_status_is_saved_before_raising(self):
        def fetch(vm,path,limit=None):
            if path.endswith('status.json'):return json.dumps(dict(error='hide-rename: boom')).encode()
            raise RuntimeError('missing')
        with patch('original_scene_reload_probe.fetch',side_effect=fetch),patch('original_scene_reload_probe.stop_probe'):
            with self.assertRaisesRegex(RuntimeError,'hide-rename: boom'):probe.collect('vm',self.output)
        self.assertEqual(json.loads((self.output/'status.json').read_text())['error'],'hide-rename: boom')

class ArgumentTests(unittest.TestCase):
    def run_main(self,argv):
        with patch.object(sys,'argv',['original_scene_reload_probe.py',*argv]),patch('original_scene_reload_probe.start') as start,patch('original_scene_reload_probe.collect') as collect:
            start.return_value=collect.return_value={}
            with contextlib.redirect_stdout(io.StringIO()):probe.main()
        return start,collect

    def test_outputs_outside_local_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError,'remain in .local'):self.run_main(['--output',tmp])

    def test_every_scene_record_is_required_to_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError,'--hide-rename requires an existing exported scene record'):
                self.run_main([])
            inputs=scenes(tmp)
            argv=['--hide-rename',str(inputs['hide-rename'])]
            with self.assertRaisesRegex(ValueError,'--camera-switch requires an existing exported scene record'):
                self.run_main(argv)
            argv+=['--camera-switch',str(inputs['camera-switch'])]
            with self.assertRaisesRegex(ValueError,'--route-stop requires an existing exported scene record'):
                self.run_main(argv)
            argv+=['--route-stop',str(inputs['route-stop'])]
            with self.assertRaisesRegex(ValueError,'--route-rename requires an existing exported scene record'):
                self.run_main(argv)
            argv+=['--route-rename',str(inputs['route-rename'])]
            start,collect=self.run_main(argv)
            start.assert_called_once();self.assertEqual(set(start.call_args.args[3]),set(probe.LABELS))

    def test_collect_is_a_capture_step_without_scene_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            inputs=scenes(tmp)
            with self.assertRaisesRegex(ValueError,'collect does not take scene'):
                self.run_main(['--collect','--hide-rename',str(inputs['hide-rename'])])
            start,collect=self.run_main(['--collect'])
            collect.assert_called_once()

if __name__=='__main__':unittest.main()
