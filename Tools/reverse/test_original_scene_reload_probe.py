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

class ExpressionStartTests(unittest.TestCase):
    def test_expression_pair_keeps_both_labels_and_input_bytes(self):
        events=[]
        with tempfile.TemporaryDirectory() as tmp, \
             patch('original_scene_reload_probe.player_root',return_value=ROOT_A), \
             patch('original_scene_reload_probe.write_small',side_effect=lambda vm,path,data:events.append((path,data))), \
             patch('original_scene_reload_probe.retry',side_effect=lambda vm,script,user=False:'4321' if user else ''):
            inputs={}
            for label in probe.EXPRESSION_LABELS:
                inputs[label]=Path(tmp)/(label+'.png');inputs[label].write_bytes(label.encode())
            run=probe.start('vm',Path(tmp),scenes=inputs)
        self.assertEqual([path for path,_ in events[1:]], [ROOT_A+r'\BepInEx\plugins\reload-'+label+'.png' for label in probe.EXPRESSION_LABELS])
        self.assertEqual(run['sceneSHA256'],{label:hashlib.sha256(label.encode()).hexdigest() for label in probe.EXPRESSION_LABELS})

class AuthorStartTests(unittest.TestCase):
    def test_author_run_uploads_card_and_records_then_launches(self):
        events=[]
        with tempfile.TemporaryDirectory() as tmp,\
             patch('original_scene_reload_probe.player_root',return_value=ROOT_A),\
             patch('original_scene_reload_probe.write_small',side_effect=lambda vm,path,data:events.append(('upload',path,data))),\
             patch('original_scene_reload_probe.retry',side_effect=lambda vm,script,user=False:events.append(('launch' if user else 'compile',script)) or ('4321' if user else '')):
            card=Path(tmp)/'fixture-card.png';card.write_bytes(b'card')
            inputs={}
            for label in probe.FK_LABELS:
                path=Path(tmp)/(label+'.png');path.write_bytes(b'png-'+label.encode());inputs[label]=path
            run=probe.start('vm',Path(tmp),scenes=inputs,card=card)
        self.assertEqual([e[0] for e in events],['upload','compile','upload','upload','upload','launch'])
        self.assertEqual(events[2][1],ROOT_A+r'\BepInEx\plugins\author-card.png') # the author-mode trigger
        self.assertEqual([e[1] for e in events[3:5]],
                         [ROOT_A+r'\BepInEx\plugins\reload-'+label+'.png' for label in probe.FK_LABELS])
        self.assertEqual(run['authorCard'],hashlib.sha256(b'card').hexdigest())
        self.assertEqual(set(run['sceneSHA256']),set(probe.FK_LABELS))

    def test_author_run_without_records_uploads_only_the_card(self):
        events=[]
        with tempfile.TemporaryDirectory() as tmp,\
             patch('original_scene_reload_probe.player_root',return_value=ROOT_A),\
             patch('original_scene_reload_probe.write_small',side_effect=lambda vm,path,data:events.append(('upload',path,data))),\
             patch('original_scene_reload_probe.retry',side_effect=lambda vm,script,user=False:events.append(('launch' if user else 'compile',script)) or ('4321' if user else '')):
            card=Path(tmp)/'fixture-card.png';card.write_bytes(b'card')
            run=probe.start('vm',Path(tmp),scenes={},card=card)
        self.assertEqual([e[0] for e in events],['upload','compile','upload','launch'])
        self.assertEqual(run['sceneSHA256'],{})

    def test_author_scenes_upload_their_list_after_the_card(self):
        events=[]
        with tempfile.TemporaryDirectory() as tmp,\
             patch('original_scene_reload_probe.player_root',return_value=ROOT_A),\
             patch('original_scene_reload_probe.write_small',side_effect=lambda vm,path,data:events.append(('upload',path,data))),\
             patch('original_scene_reload_probe.retry',side_effect=lambda vm,script,user=False:events.append(('launch' if user else 'compile',script)) or ('4321' if user else '')):
            card=Path(tmp)/'fixture-card.png';card.write_bytes(b'card')
            run=probe.start('vm',Path(tmp),scenes={},card=card,author_scenes=['route-children','neck-target'])
            recorded=json.loads((Path(tmp)/'run.json').read_text())
        self.assertEqual([e[0] for e in events],['upload','compile','upload','upload','launch'])
        self.assertEqual(events[2][1],ROOT_A+r'\BepInEx\plugins\author-card.png')
        self.assertEqual(events[3][1],ROOT_A+r'\BepInEx\plugins\author-scenes.txt')
        self.assertEqual(events[3][2],b'route-children\nneck-target\n')
        self.assertEqual(run['authorScenes'],['route-children','neck-target']);self.assertEqual(recorded,run)

    def test_card_free_author_scenes_upload_only_their_list(self):
        events=[]
        with tempfile.TemporaryDirectory() as tmp,\
             patch('original_scene_reload_probe.player_root',return_value=ROOT_A),\
             patch('original_scene_reload_probe.write_small',side_effect=lambda vm,path,data:events.append(('upload',path,data))),\
             patch('original_scene_reload_probe.retry',side_effect=lambda vm,script,user=False:events.append(('launch' if user else 'compile',script)) or ('4321' if user else '')):
            run=probe.start('vm',Path(tmp),scenes={},author_scenes=['mirrored-camera'])
        self.assertEqual([e[0] for e in events],['upload','compile','upload','launch'])
        self.assertEqual(events[2][1],ROOT_A+r'\BepInEx\plugins\author-scenes.txt') # the list alone starts author mode
        self.assertEqual(events[2][2],b'mirrored-camera\n')
        self.assertNotIn(ROOT_A+r'\BepInEx\plugins\author-card.png',[e[1] for e in events if e[0]=='upload'])
        self.assertIsNone(run['authorCard']);self.assertEqual(run['authorScenes'],['mirrored-camera'])

    def test_plain_author_run_records_the_default_scene(self):
        with tempfile.TemporaryDirectory() as tmp,\
             patch('original_scene_reload_probe.player_root',return_value=ROOT_A),\
             patch('original_scene_reload_probe.write_small') as upload,\
             patch('original_scene_reload_probe.retry',side_effect=lambda vm,script,user=False:'4321' if user else ''):
            card=Path(tmp)/'fixture-card.png';card.write_bytes(b'card')
            run=probe.start('vm',Path(tmp),scenes={},card=card)
        self.assertEqual(run['authorScenes'],['char'])
        self.assertNotIn(ROOT_A+r'\BepInEx\plugins\author-scenes.txt',[c.args[1] for c in upload.call_args_list]) # no list keeps the plugin's scene-char.png default

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

    def test_author_run_fetches_the_scene_the_probe_authored_from_its_folder(self):
        (self.output/'run.json').write_text(json.dumps(dict(vm='vm',root=ROOT_A,processID=77,stopped=False,
            authorCard='c',sceneSHA256={label:'h' for label in probe.FK_LABELS})))
        paths=[]
        files={'status.json':json.dumps(dict(error=None)).encode(),'reload-trace.json':b'{}',
               'scene-char.png':b'scene','reload-charastudio-fk-edit.png':b'e',
               'reload-charastudio-fk-source.png':b's','unity.log':b'log'}
        def fetch(vm,path,limit=None):
            name=path.rsplit('\\',1)[1];paths.append(path)
            if name not in files:raise RuntimeError('missing '+name)
            return files[name]
        with patch('original_scene_reload_probe.fetch',side_effect=fetch),patch('original_scene_reload_probe.stop_probe'):
            result=probe.collect('vm',self.output)
        self.assertIn([p for p in paths if p.endswith('scene-char.png')][0],
                      [ROOT_A+r'\BepInEx\plugins\reload\scene-char.png']) # authored into the probe's folder
        listed={f['file'] for f in json.loads((self.output/'manifest.json').read_text())['files']}
        self.assertIn('scene-char.png',listed);self.assertEqual(result['files'],len(listed))
        self.assertEqual((self.output/'scene-char.png').read_bytes(),b'scene')

    def test_author_scenes_run_fetches_each_authored_scene_from_its_folder(self):
        (self.output/'run.json').write_text(json.dumps(dict(vm='vm',root=ROOT_A,processID=77,stopped=False,
            authorCard='c',authorScenes=['route-children','neck-target'],sceneSHA256={})))
        paths=[]
        files={'status.json':json.dumps(dict(error=None)).encode(),'reload-trace.json':b'{}',
               'scene-route-children.png':b'route','scene-neck-target.png':b'neck','unity.log':b'log'}
        def fetch(vm,path,limit=None):
            name=path.rsplit('\\',1)[1];paths.append(path)
            if name not in files:raise RuntimeError('missing '+name)
            return files[name]
        with patch('original_scene_reload_probe.fetch',side_effect=fetch),patch('original_scene_reload_probe.stop_probe'):
            probe.collect('vm',self.output)
        for name in ('scene-route-children.png','scene-neck-target.png'):
            self.assertIn(ROOT_A+'\\BepInEx\\plugins\\reload\\'+name,paths) # authored into the probe's folder
            self.assertEqual((self.output/name).read_bytes(),files[name])
        self.assertFalse(any(p.endswith('scene-char.png') for p in paths)) # only the listed scenes were authored
        listed={f['file'] for f in json.loads((self.output/'manifest.json').read_text())['files']}
        self.assertTrue({'scene-route-children.png','scene-neck-target.png'}<=listed)

    def test_card_free_author_run_fetches_its_scene_without_a_card(self):
        (self.output/'run.json').write_text(json.dumps(dict(vm='vm',root=ROOT_A,processID=77,stopped=False,
            authorCard=None,authorScenes=['mirrored-camera'],sceneSHA256={})))
        paths=[]
        files={'status.json':json.dumps(dict(error=None)).encode(),'reload-trace.json':b'{}',
               'scene-mirrored-camera.png':b'mirror','unity.log':b'log'}
        def fetch(vm,path,limit=None):
            name=path.rsplit('\\',1)[1];paths.append(path)
            if name not in files:raise RuntimeError('missing '+name)
            return files[name]
        with patch('original_scene_reload_probe.fetch',side_effect=fetch),patch('original_scene_reload_probe.stop_probe'):
            probe.collect('vm',self.output)
        self.assertIn(ROOT_A+r'\BepInEx\plugins\reload\scene-mirrored-camera.png',paths)
        self.assertEqual((self.output/'scene-mirrored-camera.png').read_bytes(),b'mirror')
        self.assertFalse(any(p.endswith('scene-char.png') for p in paths))
        listed={f['file'] for f in json.loads((self.output/'manifest.json').read_text())['files']}
        self.assertIn('scene-mirrored-camera.png',listed)

    def test_failed_probe_status_is_saved_before_raising(self):
        def fetch(vm,path,limit=None):
            if path.endswith('status.json'):return json.dumps(dict(error='hide-rename: boom')).encode()
            raise RuntimeError('missing')
        with patch('original_scene_reload_probe.fetch',side_effect=fetch),patch('original_scene_reload_probe.stop_probe'):
            with self.assertRaisesRegex(RuntimeError,'hide-rename: boom'):probe.collect('vm',self.output)
        self.assertEqual(json.loads((self.output/'status.json').read_text())['error'],'hide-rename: boom')

class OnceTests(unittest.TestCase):
    UPLOADS=['reload-topology-delete.png','reload-topology-delete-source.png']

    def test_once_script_fetches_source_and_scenes_and_always_cleans_up(self):
        script=probe.once_script(ROOT_A,'http://10.211.55.2:1/t/',60,self.UPLOADS)
        self.assertIn("$root='"+ROOT_A+"'",script)
        self.assertIn("Fetch 'SceneReloadProbe.cs'",script)
        self.assertIn("@('reload-topology-delete.png','reload-topology-delete-source.png')",script)
        self.assertIn('WaitForExit(60000)',script)
        self.assertIn("throw 'A game process already runs'",script) # refuses to start beside a running game
        cleanup=script[script.index('finally{'):]
        self.assertIn('rmdir',cleanup);self.assertIn('Remove-Item -LiteralPath $root -Recurse -Force',cleanup)
        self.assertIn('remainingGameProcesses',cleanup)
        self.assertNotIn('Remove-Item -LiteralPath $original',script);self.assertNotIn('Copy-Item -LiteralPath $p',script)

    def test_once_script_refuses_unknown_roots_and_upload_names(self):
        with self.assertRaisesRegex(ValueError,'Unknown private player root'):
            probe.once_script(r'C:\Illusion\Koikatsu','http://h/t/',60,self.UPLOADS)
        for bad in ([],['reload-../x.png'],["reload-a.png';rm"]):
            with self.assertRaisesRegex(ValueError,'Unexpected scene upload names'):
                probe.once_script(ROOT_A,'http://h/t/',60,bad)

    def test_once_refuses_an_output_that_already_holds_a_run_before_any_vm_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            record=Path(tmp)/'delete.png';record.write_bytes(b'png');(Path(tmp)/'run.json').write_text('{}')
            with patch('original_scene_reload_probe.guarded') as guard,patch('original_scene_reload_probe.subprocess.run') as vm,\
                 self.assertRaisesRegex(RuntimeError,'run.json exists'):
                probe.run_once('vm',Path(tmp),{'topology-delete':record},0)
            guard.assert_not_called();vm.assert_not_called()

    def test_topology_labels_upload_under_their_own_names(self):
        items=probe.upload_items({label:Path(label) for label in probe.TOPOLOGY_LABELS})
        self.assertEqual(items,[(label,'reload-'+label+'.png') for label in probe.TOPOLOGY_LABELS])

    def test_topology_records_need_once_and_once_needs_a_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            record=Path(tmp)/'delete.png';record.write_bytes(b'png')
            with patch.object(sys,'argv',['original_scene_reload_probe.py','--topology-delete',str(record)]),\
                 self.assertRaisesRegex(ValueError,'topology records run with --once only'):probe.main()
            with patch.object(sys,'argv',['original_scene_reload_probe.py','--once','--topology-delete',str(record)]),\
                 self.assertRaisesRegex(ValueError,'--once needs --errno-baseline'):probe.main()
            with patch.object(sys,'argv',['original_scene_reload_probe.py','--once','--errno-baseline','0','--topology-delete',str(Path(tmp)/'absent.png')]),\
                 self.assertRaisesRegex(ValueError,'--topology-delete requires an existing'):probe.main()
            with patch.object(sys,'argv',['original_scene_reload_probe.py','--once','--errno-baseline','3','--topology-delete',str(record)]),\
                 patch('original_scene_reload_probe.run_once',return_value={}) as once,contextlib.redirect_stdout(io.StringIO()):probe.main()
            self.assertEqual(once.call_args.args[2],{'topology-delete':record});self.assertEqual(once.call_args.args[3],3)

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

    def test_author_run_requires_the_card_and_both_fk_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError,'author-character requires an existing'):
                self.run_main(['--author-character',str(Path(tmp)/'absent.png')])
            card=Path(tmp)/'fixture-card.png';card.write_bytes(b'card')
            inputs={}
            for label in probe.FK_LABELS:
                path=Path(tmp)/(label+'.png');path.write_bytes(b'png-'+label.encode());inputs[label]=path
            start,collect=self.run_main(['--author-character',str(card)])    # a plain author run needs no records
            self.assertEqual(start.call_args.args[3],{})
            for label in probe.LABELS: # with a card the run uploads only what was given, but an FK pair is all-or-nothing
                path=Path(tmp)/('plain-'+label+'.png');path.write_bytes(b'png');path.rename(path)
                start,collect=self.run_main(['--author-character',str(card),'--'+label,str(path)])
                self.assertEqual(set(start.call_args.args[3]),{label})
            with self.assertRaisesRegex(ValueError,'needs both --charastudio-fk-edit and --charastudio-fk-source'):
                self.run_main(['--charastudio-fk-edit',str(inputs['charastudio-fk-edit'])])
            start,collect=self.run_main(['--charastudio-fk-edit',str(inputs['charastudio-fk-edit']),
                                         '--charastudio-fk-source',str(inputs['charastudio-fk-source'])])
            self.assertEqual(set(start.call_args.args[3]),set(probe.FK_LABELS)) # a reload-only FK run uploads both records
            self.assertIsNone(start.call_args.args[4])

    def test_author_scenes_need_the_card_and_known_distinct_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            card=Path(tmp)/'fixture-card.png';card.write_bytes(b'card')
            with self.assertRaisesRegex(ValueError,'author-scenes needs --author-character'):
                self.run_main(['--author-scenes','route-children'])
            with self.assertRaisesRegex(ValueError,'author-scenes needs --author-character'): # one card scene in the list still needs the card
                self.run_main(['--author-scenes','mirrored-camera,neck-target'])
            start,collect=self.run_main(['--author-scenes','mirrored-camera']) # card-free: no card, no records
            self.assertEqual(start.call_args.args[3],{});self.assertIsNone(start.call_args.args[4])
            self.assertEqual(start.call_args.args[5],['mirrored-camera'])
            for bad in ('route-children,bogus','neck-target,neck-target',','):
                with self.assertRaisesRegex(ValueError,'author-scenes takes distinct names'):
                    self.run_main(['--author-character',str(card),'--author-scenes',bad])
            start,collect=self.run_main(['--author-character',str(card),'--author-scenes','route-children, neck-target'])
            self.assertEqual(start.call_args.args[5],['route-children','neck-target'])
            start,collect=self.run_main(['--author-character',str(card)])
            self.assertIsNone(start.call_args.args[5])
            with self.assertRaisesRegex(ValueError,'collect does not take scene'):
                self.run_main(['--collect','--author-scenes','char'])

    def test_collect_is_a_capture_step_without_scene_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            inputs=scenes(tmp)
            with self.assertRaisesRegex(ValueError,'collect does not take scene'):
                self.run_main(['--collect','--hide-rename',str(inputs['hide-rename'])])
            with self.assertRaisesRegex(ValueError,'collect does not take scene'):
                self.run_main(['--collect','--author-character',str(inputs['hide-rename'])])
            start,collect=self.run_main(['--collect'])
            collect.assert_called_once()

if __name__=='__main__':unittest.main()
