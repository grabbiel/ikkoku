"""Camera-object probe driver framing; VM calls are mocked, so no VM or private data is needed."""
import io, json, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch, call
import original_camera_object_probe as probe

ROOT_A=r'C:\Temp\IkkokuShaderProbe-'+('a'*32)

class StartTests(unittest.TestCase):
    def test_start_reuses_the_player_root_uploads_compiles_then_launches(self):
        events=[]
        with tempfile.TemporaryDirectory() as tmp,\
             patch('original_camera_object_probe.player_root',return_value=ROOT_A) as root,\
             patch('original_camera_object_probe.write_small',side_effect=lambda vm,path,data:events.append(('upload',path))),\
             patch('original_camera_object_probe.retry',side_effect=lambda vm,script,user=False:events.append(('launch' if user else 'compile',script)) or ('4321' if user else '')):
            run=probe.start('vm',Path(tmp))
            recorded=json.loads((Path(tmp)/'run.json').read_text())
            self.assertEqual((Path(tmp)/'probe-source.cs').read_bytes(),probe.SOURCE.read_bytes())
        root.assert_called_once_with('vm',Path(tmp))
        self.assertEqual([e[0] for e in events],['upload','compile','launch'])
        self.assertEqual(events[0][1],ROOT_A+r'\CameraObjectProbe.cs')
        self.assertIn(r'IkkokuCameraObjectProbe.dll',events[1][1]);self.assertIn(r'plugins\camera',events[1][1]);self.assertIn('Compile failed:$csc',events[1][1])
        self.assertIn(r"$root\CharaStudio.exe",events[2][1])
        self.assertEqual(run,recorded);self.assertEqual(recorded['processID'],4321);self.assertEqual(recorded['root'],ROOT_A)

class CollectTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.output=Path(self.tmp.name)
        (self.output/'run.json').write_text(json.dumps(dict(vm='vm',root=ROOT_A,processID=77,stopped=False)))
    def tearDown(self):self.tmp.cleanup()

    def test_unfinished_probe_is_left_running(self):
        with patch('original_camera_object_probe.fetch',side_effect=RuntimeError('VM read failed (1): cannot find path')) as fetch,patch('original_camera_object_probe.stop_probe') as stop:
            with self.assertRaises(RuntimeError):probe.collect('vm',self.output)
        self.assertTrue(fetch.call_args_list[0].args[1].endswith(r'\plugins\camera\status.json'))
        stop.assert_not_called();self.assertFalse((self.output/'status.json').exists())

    def test_finished_probe_is_stopped_then_every_result_is_fetched_and_listed(self):
        files={'status.json':json.dumps(dict(error=None)).encode(),'camera-trace.json':b'{}','scene-x.png':b'x','scene-y.png':b'y','scene-none.png':b'n','unity.log':b'log'}
        def fetch(vm,path,limit=None):
            name=path.rsplit('\\',1)[1]
            if name not in files:raise RuntimeError('missing '+name)
            return files[name]
        with patch('original_camera_object_probe.fetch',side_effect=fetch),patch('original_camera_object_probe.stop_probe') as stop:
            result=probe.collect('vm',self.output)
        stop.assert_called_once();self.assertEqual(stop.call_args.args[1]['processID'],77)
        self.assertTrue(json.loads((self.output/'run.json').read_text())['stopped'])
        listed={f['file'] for f in json.loads((self.output/'manifest.json').read_text())['files']}
        self.assertEqual(listed,{'status.json','camera-trace.json','scene-x.png','scene-y.png','scene-none.png','unity.log','run.json'})
        self.assertEqual(result['files'],7)

    def test_failed_probe_status_is_saved_before_raising(self):
        def fetch(vm,path,limit=None):
            if path.endswith('status.json'):return json.dumps(dict(error='root: boom')).encode()
            raise RuntimeError('missing')
        with patch('original_camera_object_probe.fetch',side_effect=fetch),patch('original_camera_object_probe.stop_probe'):
            with self.assertRaisesRegex(RuntimeError,'root: boom'):probe.collect('vm',self.output)
        self.assertEqual(json.loads((self.output/'status.json').read_text())['error'],'root: boom')

class ArgumentTests(unittest.TestCase):
    def run_main(self,argv):
        with patch.object(sys,'argv',['original_camera_object_probe.py',*argv]),patch('original_camera_object_probe.start') as start,patch('original_camera_object_probe.collect') as collect:
            probe.main()
        return start,collect

    def test_outputs_outside_local_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError,'remain in .local'):self.run_main(['--output',tmp])

    def test_source_is_a_capture_input_only(self):
        with self.assertRaisesRegex(ValueError,'capture step'):self.run_main(['--collect','--source','x.cs'])

if __name__=='__main__':unittest.main()
