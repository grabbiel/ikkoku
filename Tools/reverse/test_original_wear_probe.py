"""original_wear_probe: the one-exec script, the endpoint and the guards; no VM access."""
import io, re, tempfile, unittest, urllib.error, urllib.request, zipfile
from pathlib import Path
from unittest.mock import patch
import original_wear_probe as probe

ROOT_A = r'C:\Temp\IkkokuShaderProbe-' + 'a' * 32
BASE = 'http://10.211.55.2:1234/' + 'b' * 32 + '/'


class ScriptTests(unittest.TestCase):
    def test_script_reads_the_install_and_removes_junctions_as_links(self):
        script = probe.run_script(ROOT_A, BASE, 600)
        # The install path appears once, as the read-only source of the player copy.
        self.assertEqual(script.count(r'C:\Illusion\Koikatsu'), 1)
        self.assertIn(probe.PLAYER_SETUP, script)
        for line in script.splitlines():
            if 'Remove-Item' in line: self.assertNotIn('$original', line)
        self.assertIn('[IO.FileAttributes]::ReparsePoint){cmd /c rmdir', script)
        # The root is deleted only when both junctions are gone.
        self.assertIn("if($kept.Count){$r.cleanupError=", script)
        self.assertLess(script.index('finally{'), script.index('Remove-Item -LiteralPath $root -Recurse'))
        self.assertIn("throw 'A game process already runs'", script)
        self.assertIn('WaitForExit(600000)', script)

    def test_unknown_root_is_refused(self):
        for root in [r'C:\Illusion\Koikatsu', ROOT_A + r'\..', r'C:\Temp\IkkokuShaderProbe-xyz']:
            with self.subTest(root=root), self.assertRaises(ValueError): probe.run_script(root, BASE, 600)

    def test_bootstrap_stays_far_below_the_command_limit(self):
        self.assertLess(len(probe.bootstrap(BASE)), 400)
        self.assertIn(BASE + 'run.ps1', probe.bootstrap(BASE))


class GuardTests(unittest.TestCase):
    def test_errno_change_stops_before_any_exec(self):
        with patch('original_wear_probe.errno_count', return_value=6), self.assertRaisesRegex(RuntimeError, 'errno-24 count is 6'):
            probe.guarded(5)
        with patch('original_wear_probe.errno_count', return_value=5): self.assertEqual(probe.guarded(5), 5)

    def test_output_outside_local_or_reused_is_refused_without_vm_access(self):
        class Args: vm = 'vm'; settings = None; model_variant = 'female00'; errno_baseline = 5; host_address = '127.0.0.1'; wait_seconds = 1
        with tempfile.TemporaryDirectory() as tmp, patch('subprocess.run') as run:
            Args.output = Path(tmp)
            with self.assertRaisesRegex(ValueError, 'under .local'): probe.run(Args)
            local = probe.ROOT / '.local' / ('wear-probe-test-' + 'c' * 8)
            try:
                local.mkdir(parents=True); (local / 'run.json').write_text('{}'); Args.output = local
                with self.assertRaisesRegex(RuntimeError, 'new output folder'): probe.run(Args)
            finally:
                (local / 'run.json').unlink(); local.rmdir()
            run.assert_not_called()

    def test_archive_paths_must_be_plain_names(self):
        for name in ['../x', 'a/b', '.hidden']:
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w') as archive: archive.writestr(name, b'x')
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
                probe.extract(data.getvalue(), Path(tmp))


class EndpointTests(unittest.TestCase):
    def test_serves_named_inputs_and_takes_one_upload(self):
        with probe.Endpoint('127.0.0.1', {'a.txt': b'hello'}) as endpoint:
            self.assertTrue(re.fullmatch(r'http://127\.0\.0\.1:\d+/[0-9a-f]{32}/', endpoint.base))
            self.assertEqual(urllib.request.urlopen(endpoint.base + 'a.txt').read(), b'hello')
            for path in ['b.txt', '../a.txt']:
                with self.subTest(path=path), self.assertRaises(urllib.error.HTTPError): urllib.request.urlopen(endpoint.base + path)
            with self.assertRaises(urllib.error.HTTPError): urllib.request.urlopen(endpoint.base.replace(endpoint.token, 'f' * 32) + 'a.txt')
            put = lambda: urllib.request.urlopen(urllib.request.Request(endpoint.base + 'character.zip', data=b'zip', method='PUT'))
            put()
            with self.assertRaises(urllib.error.HTTPError): put()
            self.assertEqual(endpoint.upload, b'zip')


if __name__ == '__main__': unittest.main()
