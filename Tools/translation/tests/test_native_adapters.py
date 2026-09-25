"""Exercise exact original-assembly routing without executing installed plugins."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import native_adapters
import plugin


class NativeAdapterTests(unittest.TestCase):
    def test_installed_packages_preserve_original_identity_and_configuration(self):
        fixture = os.environ.get('IKKOKU_NATIVE_PLUGIN_PACKAGES')
        if not fixture:
            self.skipTest('Set IKKOKU_NATIVE_PLUGIN_PACKAGES for original assembly evidence')
        evidence = ROOT / '.local/reverse/plugin-execution'
        evidence.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='adapter-packaging-', dir=evidence) as temporary:
            work = Path(temporary)
            for name in ('mute-original-v1', 'accessory-names-original-v1'):
                original = Path(fixture) / name
                manifest = json.loads((original / 'manifest.json').read_text())
                source = original / manifest['source']['file']
                config = original / manifest['configuration']['file'] if 'configuration' in manifest else None
                output = work / name
                report = plugin.package(source, manifest['type'], output, config=config,
                                        tool=work / 'must-not-run-decompiler')
                self.assertEqual(report['execution'], 'verified-native-adapter')
                actual = json.loads((output / 'manifest.json').read_text())
                self.assertEqual(actual, manifest)
                for key in ('source', 'configuration'):
                    if key in actual:
                        data = (output / actual[key]['file']).read_bytes()
                        self.assertEqual(hashlib.sha256(data).hexdigest(), actual[key]['sha256'])
                self.assertFalse((output / 'program').exists())
                with self.assertRaises(ValueError):
                    plugin.package(source, manifest['type'], work / (name + '-bad-version'), version='9.0')
                with self.assertRaises(ValueError):
                    plugin.package(source, 'Different.Type', work / (name + '-bad-type'))
                changed = work / (name + '.dll')
                changed.write_bytes(source.read_bytes() + b'changed')
                self.assertIsNone(native_adapters.identify(changed))
            self.assertFalse(list(work.glob('.plugin-stage-*')))


if __name__ == '__main__':
    unittest.main()
