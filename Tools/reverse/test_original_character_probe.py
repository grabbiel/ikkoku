"""Private player root reuse and capture-argument checks; no VM access required."""
import io, json, re, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import original_character_probe as probe
import original_animation_probe, original_dynamics_probe, original_light_probe, original_route_probe

ROOT_A=r'C:\Temp\IkkokuShaderProbe-'+('a'*32)

class PlayerRootTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.output=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()
    def record(self,root=ROOT_A,pid=123):
        (self.output/'run.json').write_text(json.dumps(dict(vm='vm',root=root,processID=pid,stopped=True)))
        return (self.output/'run.json').read_text()

    def test_new_root_runs_the_player_setup_and_is_recorded_before_compile(self):
        with patch('original_character_probe.powershell',return_value='') as guest,patch('original_character_probe.stop_probe') as stop:
            root=probe.player_root('vm',self.output)
        self.assertTrue(re.fullmatch(probe.PLAYER_ROOT,root))
        guest.assert_called_once_with('vm',probe.player_script(root,probe.PLAYER_SETUP))
        stop.assert_not_called()
        self.assertEqual(json.loads((self.output/'run.json').read_text()),dict(vm='vm',root=root,processID=0,stopped=True))

    def test_missing_recorded_root_is_recreated_with_the_same_setup_as_a_new_root(self):
        before=self.record()
        with patch('original_character_probe.powershell',side_effect=['missing','']) as guest,patch('original_character_probe.stop_probe') as stop,patch('sys.stderr',new_callable=io.StringIO) as err:
            self.assertEqual(probe.player_root('vm',self.output),ROOT_A)
        self.assertEqual([c.args for c in guest.call_args_list],[('vm',probe.player_script(ROOT_A,probe.PLAYER_STATE)),('vm',probe.player_script(ROOT_A,probe.PLAYER_SETUP))])
        stop.assert_not_called() # no player can run from a deleted root
        self.assertIn('Recreated missing private player root '+ROOT_A,err.getvalue())
        self.assertEqual((self.output/'run.json').read_text(),before)

    def test_present_recorded_root_is_reused_after_stopping_its_recorded_player(self):
        self.record(pid=123)
        with patch('original_character_probe.powershell',return_value='present') as guest,patch('original_character_probe.stop_probe') as stop:
            self.assertEqual(probe.player_root('vm',self.output),ROOT_A)
        guest.assert_called_once_with('vm',probe.player_script(ROOT_A,probe.PLAYER_STATE))
        stop.assert_called_once();self.assertEqual(stop.call_args.args[1]['processID'],123)

    def test_present_root_without_a_recorded_process_is_not_stopped(self):
        self.record(pid=0)
        with patch('original_character_probe.powershell',return_value='present'),patch('original_character_probe.stop_probe') as stop:
            probe.player_root('vm',self.output)
        stop.assert_not_called()

    def test_incomplete_root_fails_without_setup_or_stop(self):
        self.record()
        failure=RuntimeError('VM read failed (1): Private player root is incomplete: '+ROOT_A)
        with patch('original_character_probe.powershell',side_effect=failure) as guest,patch('original_character_probe.stop_probe') as stop:
            with self.assertRaisesRegex(RuntimeError,'incomplete'):probe.player_root('vm',self.output)
        guest.assert_called_once();stop.assert_not_called()

    def test_foreign_recorded_root_is_rejected_before_calling_the_guest(self):
        for root in [r'C:\Illusion\Koikatsu',ROOT_A+r'\..\elsewhere',r'C:\Temp\IkkokuLifecycleProbe-'+('a'*32)]:
            self.record(root=root)
            with self.subTest(root=root),patch('original_character_probe.powershell') as guest:
                with self.assertRaises(ValueError):probe.player_root('vm',self.output)
                guest.assert_not_called()

    def test_state_check_distinguishes_missing_present_and_incomplete(self):
        state=probe.PLAYER_STATE
        self.assertTrue(state.startswith("if(-not(Test-Path -LiteralPath $root)){'missing'}"))
        for part in [r'$root\CharaStudio.exe',r'$root\BepInEx\core\BepInEx.dll',r'$root\CharaStudio_Data\Managed',r'$root\abdata']:self.assertIn(part,state)
        self.assertIn('throw "Private player root is incomplete: $root"',state)
        self.assertIn("New-Item -ItemType Junction",probe.PLAYER_SETUP)

class DriverWiringTests(unittest.TestCase):
    DRIVERS=[probe,original_animation_probe,original_dynamics_probe,original_light_probe,original_route_probe]
    # These create a fresh root on every start and never reuse the one in run.json.
    FRESH_ONLY={'original_shader_probe.py','original_lifecycle_probe.py','original_adv_binding_probe.py',
                'original_hide_studio_ui_probe.py'}

    def test_every_reusing_driver_takes_its_root_from_player_root(self):
        class Reached(Exception):pass
        guest=AssertionError('no VM access expected')
        for module in self.DRIVERS:
            with self.subTest(driver=module.__name__),tempfile.TemporaryDirectory() as tmp,\
                 patch.object(module,'player_root',side_effect=Reached) as helper,\
                 patch('original_character_probe.powershell',side_effect=guest),patch('original_character_probe.user_powershell',side_effect=guest),\
                 patch('original_shader_probe.powershell',side_effect=guest):
                with self.assertRaises(Reached):module.start('vm',Path(tmp))
                helper.assert_called_once_with('vm',Path(tmp))

    def test_no_other_driver_sets_up_a_reusable_player_root_on_its_own(self):
        for path in sorted(Path(probe.__file__).parent.glob('original_*_probe.py')):
            text=path.read_text()
            if path.name in self.FRESH_ONLY or path.name=='original_character_probe.py' or 'run.json' not in text:continue
            with self.subTest(driver=path.name):
                self.assertNotIn('New-Item -ItemType Junction',text)
                self.assertNotIn("IkkokuShaderProbe-'+uuid",text)

class ArgumentTests(unittest.TestCase):
    def test_capture_inputs_are_rejected_with_collect_before_the_output_is_touched(self):
        for flag in ['--settings','--hand-patterns','--look-patterns','--model-variant','--model-shapes']:
            with self.subTest(flag=flag),tempfile.TemporaryDirectory() as tmp:
                output=Path(tmp)/'never-created'
                with patch.object(sys,'argv',['original_character_probe.py','--output',str(output),'--collect',flag,'female00' if flag=='--model-variant' else 'input.tsv']),patch('original_character_probe.collect') as collect:
                    with self.assertRaisesRegex(ValueError,'belong to the capture step'):probe.main()
                collect.assert_not_called();self.assertFalse(output.exists())

    def test_neutral_model_conflicts_fail_before_guest_access(self):
        for inputs in [dict(model_variant='other'),dict(model_variant='female00',settings=Path('s')),
                       dict(model_variant='male200',hand_patterns=Path('h')),dict(model_variant='female200',look_patterns=Path('l')),
                       dict(model_variant='female201',settings=Path('s')),dict(model_variant='female201',hand_patterns=Path('h')),
                       dict(model_variant='female201',look_patterns=Path('l')),
                       dict(model_variant='male201',settings=Path('s')),dict(model_variant='male201',hand_patterns=Path('h')),
                       dict(model_variant='male201',look_patterns=Path('l')),
                       dict(model_variant='female00-bone1',settings=Path('s')),
                       dict(model_variant='female00-bone1',hand_patterns=Path('h')),
                       dict(model_variant='female00-bone1',look_patterns=Path('l')),
                       dict(model_variant='male00',settings=Path('s')),
                       dict(model_variant='male00',hand_patterns=Path('h')),
                       dict(model_variant='male00',look_patterns=Path('l')),
                       dict(model_variant='male00-bone1',settings=Path('s')),
                       dict(model_variant='male00-bone1',hand_patterns=Path('h')),
                       dict(model_variant='male00-bone1',look_patterns=Path('l'))]:
            with self.subTest(inputs=inputs),patch('original_character_probe.player_root') as root:
                with self.assertRaises(ValueError):probe.start('vm',Path('unused'),**inputs)
                root.assert_not_called()

    def test_reused_capture_clears_absent_optional_inputs_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp,patch('original_character_probe.player_root',return_value=ROOT_A),\
             patch('original_character_probe.write_small') as write,patch('original_character_probe.retry',side_effect=['','','','','123']) as guest:
            probe.start('vm',Path(tmp),model_variant='female00')
        scripts=[call.args[1] for call in guest.call_args_list]
        self.assertIn('hand-patterns.tsv',scripts[1]);self.assertIn('look-patterns.tsv',scripts[2]);self.assertIn('model-shapes.tsv',scripts[3])
        self.assertTrue(all('Remove-Item -LiteralPath' in s and 'Test-Path -LiteralPath' in s for s in scripts[1:4]))
        self.assertTrue(any(call.args[1].endswith('model-variant.txt') and call.args[2]==b'female00\n' for call in write.call_args_list))

    def test_model_shapes_validate_before_any_guest_access(self):
        for text in ['', 'body\t44\t.5\n', 'face\t-1\t.5\n', 'body\t0\tNaN\n',
                     'face\t0\tInf\n', 'body\t0\t1.1\n', 'body\t0\t.5\nbody\t0\t.6\n']:
            with self.subTest(text=text),tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/'input.tsv';path.write_text(text)
                with patch.object(probe,'player_root') as root:
                    with self.assertRaises(ValueError):probe.start('vm',Path(tmp),model_variant='female00',model_shapes=path)
                    root.assert_not_called()
        with patch.object(probe,'player_root') as root:
            with self.assertRaisesRegex(ValueError,'require'):probe.start('vm',Path('unused'),model_shapes=Path('unused'))
            root.assert_not_called()

    def test_model_shape_upload_and_run_provenance_bind_canonical_input(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(probe,'player_root',return_value=ROOT_A),\
             patch.object(probe,'write_small') as write,patch.object(probe,'retry',side_effect=['','','','123']):
            path=Path(tmp)/'input.tsv';path.write_text('face\t3\t.7500\nbody\t0\t.2500\n')
            run=probe.start('vm',Path(tmp),model_variant='female00',model_shapes=path)
        expected=b'body\t0\t0.25\nface\t3\t0.75\n'
        self.assertEqual(run['modelShapes'],dict(file='model-shapes.tsv',sha256=probe.digest(expected)))
        self.assertTrue(any(call.args[1].endswith('model-shapes.tsv') and call.args[2]==expected for call in write.call_args_list))

    def test_settings_help_points_at_the_documented_keys(self):
        with patch.object(sys,'argv',['original_character_probe.py','--help']),patch('sys.stdout',new_callable=io.StringIO) as out:
            with self.assertRaises(SystemExit):probe.main()
        text=re.sub(r'-\n\s+','-',out.getvalue()) # argparse may wrap the path at its hyphen
        self.assertIn('character-settings.tsv',text);self.assertIn('docs/reference/character/material-expansion.md',text)

    def test_head201_cli_uploads_variant_and_canonical_shapes_before_launch(self):
        for variant in ('female201','male201','female00-bone1','male00','male00-bone1'):
            events=[]
            def guest(vm, script, *args):
                events.append(('guest',script))
                return '123' if 'Start-Process' in script else ''
            def upload(vm, path, data): events.append(('write',path,data))
            with tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);output=root/'.local/capture';shapes=root/'shapes.tsv'
                shapes.write_text('face\t3\t.7500\nbody\t0\t.2500\n')
                with patch.object(probe,'ROOT',root),patch.object(probe,'player_root',return_value=ROOT_A),\
                     patch.object(probe,'write_small',side_effect=upload),patch.object(probe,'retry',side_effect=guest),\
                     patch.object(sys,'argv',['original_character_probe.py','--vm','vm','--output',str(output),
                                            '--model-variant',variant,'--model-shapes',str(shapes)]),\
                     patch('sys.stdout',new_callable=io.StringIO):
                    probe.main()
                run=json.loads((output/'run.json').read_text())
            expected=b'body\t0\t0.25\nface\t3\t0.75\n'
            self.assertEqual(run['modelShapes'],dict(file='model-shapes.tsv',sha256=probe.digest(expected)))
            launch=next(i for i,e in enumerate(events) if e[0]=='guest' and 'Start-Process' in e[1])
            for name,data in [('model-variant.txt',(variant+'\n').encode()),('model-shapes.tsv',expected)]:
                matches=[i for i,e in enumerate(events) if e[0]=='write' and e[1].endswith(name) and e[2]==data]
                self.assertEqual(len(matches),1);self.assertLess(matches[0],launch)

if __name__=='__main__':unittest.main()
