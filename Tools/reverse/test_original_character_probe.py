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
    FRESH_ONLY={'original_shader_probe.py','original_lifecycle_probe.py'}

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
        for flag in ['--settings','--hand-patterns','--look-patterns']:
            with self.subTest(flag=flag),tempfile.TemporaryDirectory() as tmp:
                output=Path(tmp)/'never-created'
                with patch.object(sys,'argv',['original_character_probe.py','--output',str(output),'--collect',flag,'input.tsv']),patch('original_character_probe.collect') as collect:
                    with self.assertRaisesRegex(ValueError,'belong to the capture step'):probe.main()
                collect.assert_not_called();self.assertFalse(output.exists())

    def test_settings_help_points_at_the_documented_keys(self):
        with patch.object(sys,'argv',['original_character_probe.py','--help']),patch('sys.stdout',new_callable=io.StringIO) as out:
            with self.assertRaises(SystemExit):probe.main()
        text=re.sub(r'-\n\s+','-',out.getvalue()) # argparse may wrap the path at its hyphen
        self.assertIn('character-settings.tsv',text);self.assertIn('docs/reference/character/material-expansion.md',text)

if __name__=='__main__':unittest.main()
