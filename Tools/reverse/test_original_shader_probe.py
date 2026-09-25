"""Pure probe framing checks; no VM access, source assets or UI required."""
import unittest
from unittest.mock import patch
from original_shader_probe import input_source, stop_probe

class OriginalShaderProbeTests(unittest.TestCase):
    def test_generated_configuration_escapes_strings_and_does_not_change_identity(self):
        value={'bundle':'C:\\Temp\\quoted"file.unity3d','recipes':[{'name':'head','material':'cf_m_face_create','width':2,'height':2,'textures':[],'vectors':[{'property':'_Color','values':[.1,.2,.3,1.]}],'scalars':[]}]}
        source=input_source(value).decode()
        self.assertIn('C:\\\\Temp\\\\quoted\\"file.unity3d',source)
        self.assertIn('new OriginalShaderProbe.Input[] {  }',source)
        self.assertIn('new float[] { 0.1f, 0.2f, 0.3f, 1.0f }',source)
        self.assertEqual(value['recipes'][0]['material'],'cf_m_face_create')

    def test_stop_rejects_installation_and_non_probe_paths_before_calling_guest(self):
        for path in [r'C:\Illusion\Koikatsu',r'C:\Temp\IkkokuShaderProbe-user',r'C:\Temp\IkkokuShaderProbe-'+('0'*32)+r'\..\elsewhere']:
            with self.subTest(path=path),patch('original_shader_probe.powershell') as guest:
                with self.assertRaises(ValueError):stop_probe('vm',{'root':path,'processID':1})
                guest.assert_not_called()

    def test_stop_verifies_both_recorded_process_and_private_executable_path(self):
        root=r'C:\Temp\IkkokuShaderProbe-'+('a'*32)
        with patch('original_shader_probe.powershell',return_value='') as guest:
            stop_probe('vm',{'root':root,'processID':123})
            vm,script=guest.call_args.args
            self.assertEqual(vm,'vm');self.assertIn('Get-Process -Id 123 ',script)
            self.assertIn("$p.Path -ne '"+root+r"\CharaStudio.exe'",script)
            self.assertIn("throw 'Probe process identity changed'",script)
            self.assertTrue(script.endswith('exit 0'))

if __name__=='__main__':unittest.main()
