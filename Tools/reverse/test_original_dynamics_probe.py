"""Motion request upload wiring for the dynamics driver; no VM access required."""
import sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import original_dynamics_probe as dynamics


ROOT_A=r'C:\Temp\IkkokuShaderProbe-'+('a'*32)


class MotionRequestTests(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.output=Path(self.tmp.name)
    def tearDown(self):self.tmp.cleanup()

    def run_start(self,motion):
        with tempfile.TemporaryDirectory() as run_tmp:
            run_dir=Path(run_tmp)
            with patch.object(dynamics,'player_root',return_value=ROOT_A),\
                 patch.object(dynamics,'write_small') as upload,\
                 patch.object(dynamics,'retry',side_effect=['','42'] if not motion else ['','','42']) as guest:
                run=dynamics.start('vm',run_dir,motion)
            return run,upload,guest

    def test_request_matches_the_fixture_script(self):
        self.assertEqual(dynamics.MOTION_REQUEST,'90\n60.0\n')
        # The fixture throws unless line 0 parses to its frame count and line 1 to 60.
        lines=dynamics.MOTION_REQUEST.splitlines()
        self.assertEqual(int(lines[0].split('\t')[0]),90)
        self.assertEqual(float(lines[1].split('\t')[0] if '\t' in lines[1] else lines[1]),60.0)

    def test_motion_request_uploads_after_compile_before_player_start(self):
        run,upload,guest=self.run_start(True)
        paths=[c.args[1] for c in upload.call_args_list]
        self.assertEqual(paths,[ROOT_A+r'\DynamicsProbe.cs',ROOT_A+r'\BepInEx\plugins\character\motion.tsv'])
        self.assertEqual(upload.call_args_list[1].args[2],dynamics.MOTION_REQUEST.encode())
        scripts=[c.args[1] for c in guest.call_args_list]
        self.assertIn('csc.exe',scripts[0])                    # compile first
        self.assertIn(r'New-Item -ItemType Directory',scripts[1])  # capture folder recreated for the request
        self.assertIn(r'BepInEx\plugins\character',scripts[1])
        self.assertIn('Start-Process',scripts[2])              # player starts last
        self.assertEqual(run['processID'],42);self.assertFalse(run['stopped'])

    def test_default_start_never_uploads_a_motion_request(self):
        run,upload,guest=self.run_start(False)
        self.assertEqual([c.args[1] for c in upload.call_args_list],[ROOT_A+r'\DynamicsProbe.cs'])
        self.assertEqual(len(guest.call_args_list),2)  # compile, then player start

    def test_motion_flag_is_rejected_with_collect_before_the_output_is_touched(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'never-created'
            with patch.object(sys,'argv',['original_dynamics_probe.py','--output',str(output),'--collect','--motion']),\
                 patch.object(dynamics,'collect') as collect:
                with self.assertRaisesRegex(ValueError,'belongs to the capture step'):dynamics.main()
            collect.assert_not_called();self.assertFalse(output.exists())


if __name__=='__main__':unittest.main()
