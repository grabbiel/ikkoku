"""Check the adapter-report acceptance rules without launching the app."""
import copy
import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import studio_execution_probe as probe

ACCESSORY = 'kk-studio-accessory-names-v1'


class SavedLibraryStateTests(unittest.TestCase):
    def test_explicit_animation_clock_is_identical_in_each_phase(self):
        for phase in ['run', 'reload', 'continue']:
            self.assertEqual(probe.animation_environment(0, phase), {'IKKOKU_STUDIO_ANIMATION_TIME': '0'})
        self.assertEqual(probe.animation_environment(None, 'run'), {'IKKOKU_STUDIO_ANIMATION_TIME': '0.5'})
        self.assertEqual(probe.animation_environment(None, 'reload'), {})
        for value in [-1, float('nan'), float('inf'), 86401]:
            with self.assertRaises(ValueError): probe.animation_environment(value, 'run')

    def test_uuid_dictionary_order_is_not_state_order(self):
        first = dict(objectIdentities=['A', 'source:scene/1', 'B', 'source:scene/2'], bindings=[{'field': 2}], clock={'elapsed': 1})
        reordered = dict(first, objectIdentities=['B', 'source:scene/2', 'A', 'source:scene/1'])
        self.assertEqual(probe.comparable_state(first), probe.comparable_state(reordered))
        for changed in [dict(first, objectIdentities=['A', 'source:scene/2', 'B', 'source:scene/1']),
                        dict(first, bindings=[{'field': 3}]), dict(first, clock={'elapsed': 2})]:
            self.assertNotEqual(probe.comparable_state(first), probe.comparable_state(changed))
        for invalid in [['A'], ['A', 'one', 'A', 'two'], ['A', 'same', 'B', 'same']]:
            with self.assertRaises(ValueError):
                probe.comparable_state(dict(first, objectIdentities=invalid))


class AdapterReportTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='adapter-report-')
        root = Path(self.scratch.name)
        self.manifests = []
        for name in ('mute', 'accessory-names'):
            path = root / name / 'manifest.json'
            path.parent.mkdir()
            path.write_text('{"name": "%s"}' % name)
            self.manifests.append(path)

    def tearDown(self):
        self.scratch.cleanup()

    def reports(self, enabled=False, events=(False, True), created=False, launched=False, mute=True):
        refs = [dict(manifestFile=str(path.resolve()), manifestSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                     guid=guid, version=version, adapterID=adapter, enabled=True)
                for path, guid, version, adapter in zip(self.manifests, ('BepInEx.MuteInBackground', 'KK_StudioAccessoryNames'),
                                                        ('1.1', '1.1.0'), (probe.MUTE, ACCESSORY))]
        if not mute:
            refs[0]['enabled'] = False
        volumes = probe.mute_volumes(enabled, 1., events) if mute else []
        trace = [dict(masterVolume=1., voiceVolume=1., toneRMS=.17)]
        trace += [dict(focus=focus, masterVolume=volume, voiceVolume=1., toneRMS=.17 * volume)
                  for focus, volume in zip(events, volumes)]
        awaiting = not launched
        mount = dict(mounted=mute, awaitingInitialFocus=awaiting and mute, focusObservers=2 if mute else 0,
                     launchObserver=awaiting and mute)
        final = dict(mount, awaitingInitialFocus=mount['awaitingInitialFocus'] and not events,
                     launchObserver=mount['launchObserver'] and not events)
        if mute:
            mount['enabled'] = final['enabled'] = enabled
        report = dict(schemaVersion=1, applicationCreated=created, launchFinished=launched, nativePlugins=refs,
                      accessoryNamesEnabled=True,
                      mount=mount, focusTrace=trace, final=final)
        return {mode: copy.deepcopy(report) for mode in ('run', 'reload', 'continue')}

    def check(self, reports, events=(False, True), expected=False):
        probe.check_adapter_reports(reports, self.manifests, list(events), None if expected is None else {'enabled': expected})

    def test_installed_disabled_configuration_keeps_gain_through_focus_loss(self):
        self.check(self.reports())
        muted = self.reports()
        muted['reload']['focusTrace'][1].update(masterVolume=0., toneRMS=0.)
        with self.assertRaisesRegex(ValueError, 'reload: master or voice gain'):
            self.check(muted)

    def test_enabled_configuration_mutes_restores_and_keeps_repeated_loss_quirk(self):
        self.check(self.reports(enabled=True), expected=True)
        events = (False, False, True)
        self.assertEqual(probe.mute_volumes(True, .73, events), [0., 0., 0.])
        self.check(self.reports(enabled=True, events=events), events, expected=True)
        restored = self.reports(enabled=True, events=events)
        restored['continue']['focusTrace'][3].update(masterVolume=1., toneRMS=.17)
        with self.assertRaisesRegex(ValueError, 'continue: master or voice gain'):
            self.check(restored, events, expected=True)

    def test_generated_tone_must_follow_master_gain(self):
        reports = self.reports(enabled=True)
        reports['run']['focusTrace'][1]['toneRMS'] = .01
        with self.assertRaisesRegex(ValueError, 'run: generated-tone gain'):
            self.check(reports, expected=True)
        silent = self.reports()
        silent['run']['focusTrace'][0]['toneRMS'] = 0.
        with self.assertRaisesRegex(ValueError, 'generated tone is silent'):
            self.check(silent)

    def test_rejects_duplicate_observers_and_premature_initial_focus(self):
        duplicate = self.reports()
        duplicate['continue']['final']['focusObservers'] = 4
        with self.assertRaisesRegex(ValueError, 'exactly one focus observer set'):
            self.check(duplicate)
        premature = self.reports()
        premature['run']['mount'].update(awaitingInitialFocus=False, launchObserver=False)
        with self.assertRaisesRegex(ValueError, 'before launching finished'):
            self.check(premature)
        # macOS 27: SwiftUI creates NSApplication before AppState, but launching has not
        # finished, so an immediate sample there is still premature (A-T04, 2026-10-23).
        early = self.reports(created=True)
        early['run']['mount'].update(awaitingInitialFocus=False, launchObserver=False)
        with self.assertRaisesRegex(ValueError, 'run: initial focus was sampled before launching finished'):
            self.check(early)
        stale = self.reports()
        stale['reload']['final']['launchObserver'] = True
        with self.assertRaisesRegex(ValueError, 'deferred initial focus observer'):
            self.check(stale)
        self.check(self.reports(created=True))
        self.check(self.reports(created=True, launched=True))

    def test_rejects_changed_package_identity_or_configuration(self):
        changed = self.reports()
        changed['reload']['nativePlugins'][1]['manifestSHA256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'reload: original adapter packages'):
            self.check(changed)
        renamed = self.reports()
        renamed['continue']['nativePlugins'][0]['version'] = '1.2'
        with self.assertRaisesRegex(ValueError, 'identities or settings changed'):
            self.check(renamed)
        reconfigured = self.reports()
        for mode in ('reload', 'continue'):
            reconfigured[mode] = self.reports(enabled=True)[mode]
        with self.assertRaisesRegex(ValueError, 'reload: Mute configuration changed'):
            self.check(reconfigured)

    def test_disabled_mute_mount_has_no_focus_consumer(self):
        self.check(self.reports(mute=False, events=()), (), expected=None)
        mounted = self.reports(mute=False, events=())
        mounted['run']['mount']['mounted'] = True
        with self.assertRaisesRegex(ValueError, 'unexpected Mute adapter state'):
            self.check(mounted, (), expected=None)
        probe.check_adapter_reports({'run': dict(nativePlugins=[], mount=dict(mounted=False),
            final=dict(mounted=False), focusTrace=[])}, [], [])

    def test_self_consistent_opposite_setting_cannot_supply_its_own_oracle(self):
        for requested in (False, True):
            opposite = self.reports(enabled=not requested)
            for phase in ('run', 'reload', 'continue'):
                with self.subTest(requested=requested, phase=phase):
                    with self.assertRaisesRegex(ValueError, phase + ': Mute configuration differs from requested oracle setting'):
                        self.check({phase: opposite[phase]}, expected=requested)
            # All phases agreeing is not independent configuration evidence.
            with self.assertRaisesRegex(ValueError, 'requested oracle setting'):
                self.check(opposite, expected=requested)

    def test_mounted_mute_requires_independent_strict_boolean(self):
        with self.assertRaisesRegex(ValueError, 'independent Mute configuration expectation'):
            self.check(self.reports(), expected=None)
        for invalid in (0, 1, 'false'):
            with self.assertRaisesRegex(ValueError, 'independent Mute configuration expectation'):
                self.check(self.reports(), expected=invalid)
        wrong_type = self.reports()
        for report in wrong_type.values():
            report['mount']['enabled'] = report['final']['enabled'] = 0
        with self.assertRaisesRegex(ValueError, 'requested oracle setting'):
            self.check(wrong_type)
        with self.assertRaisesRegex(ValueError, 'requested Mute adapter is not mounted'):
            self.check(self.reports(mute=False, events=()), ())


class MuteExpectationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='mute-expectation-')
        self.root = Path(self.scratch.name)
        self.manifest = self.root / 'manifest.json'
        self.config = self.root / 'original.cfg'
        self.config.write_bytes(b'[Config]\nMute In Background=false')
        self.manifest_value = dict(adapterID=probe.MUTE, source=dict(sha256=probe.MUTE_SOURCE),
                                   configuration=dict(file='original.cfg', sha256=probe.digest(self.config)))
        self.oracle = self.root / 'oracle.json'
        self.oracle_value = dict(schemaVersion=1, kind='recovered-mute-plugin-csharp-oracle',
            sources=[dict(path='original-mute.dll', sha256=probe.MUTE_SOURCE)],
            inputs=dict(configurations=[dict(name='disabled', data=base64.b64encode(self.config.read_bytes()).decode()),
                                         dict(name='enabled', data=base64.b64encode(b'EXACT ORIGINAL READER INPUT').decode()),
                                         dict(name='default', data='')]),
            results=dict(configurations=[dict(name='disabled', value=False, error=None),
                                          dict(name='enabled', value=True, error=None),
                                          dict(name='default', value=False, error=None)]))
        self.write()

    def tearDown(self):
        self.scratch.cleanup()

    def write(self):
        self.manifest.write_text(json.dumps(self.manifest_value))
        self.oracle.write_text(json.dumps(self.oracle_value))

    def prepare(self, override=None):
        return probe.prepare_mute_expectation([self.manifest], override, self.oracle, probe.digest(self.oracle))

    def test_exact_package_override_and_absent_default_use_reader_results(self):
        expected, pins = self.prepare()
        self.assertIs(expected['enabled'], False)
        self.assertEqual(expected['configurationOrigin'], 'package')
        self.assertEqual(expected['configurationSHA256'], probe.digest(self.config))
        probe.verify_input_pins(pins)
        override = self.root / 'override.cfg'
        # Deliberately not INI: this code must match oracle bytes, not parse them.
        override.write_bytes(b'EXACT ORIGINAL READER INPUT')
        expected, _ = self.prepare(override)
        self.assertIs(expected['enabled'], True)
        self.assertEqual(expected['configurationOrigin'], 'override')
        self.assertEqual(expected['oracleCase'], 'enabled')
        self.assertEqual(expected['oracleSHA256'], probe.digest(self.oracle))
        del self.manifest_value['configuration']; self.write()
        expected, _ = self.prepare()
        self.assertIs(expected['enabled'], False)
        self.assertEqual(expected['configurationOrigin'], 'absent-default')
        self.assertIsNone(expected['configurationFile'])

    def test_missing_unknown_ambiguous_and_reader_error_evidence_rejects(self):
        for path, digest in ((None, None), (self.oracle, None), (self.oracle, '0' * 64)):
            with self.subTest(path=path, digest=digest), self.assertRaises(ValueError):
                probe.prepare_mute_expectation([self.manifest], None, path, digest)
        self.config.write_bytes(b'unobserved input')
        self.manifest_value['configuration']['sha256'] = probe.digest(self.config); self.write()
        with self.assertRaisesRegex(ValueError, 'exactly one matching'):
            self.prepare()
        self.config.write_bytes(base64.b64decode(self.oracle_value['inputs']['configurations'][0]['data']))
        self.manifest_value['configuration']['sha256'] = probe.digest(self.config)
        self.oracle_value['inputs']['configurations'][1]['data'] = self.oracle_value['inputs']['configurations'][0]['data']
        self.write()
        with self.assertRaisesRegex(ValueError, 'exactly one matching'):
            self.prepare()
        self.oracle_value['inputs']['configurations'][1]['data'] = base64.b64encode(b'different').decode()
        self.oracle_value['results']['configurations'][0].update(value=None, error='ArgumentException'); self.write()
        with self.assertRaisesRegex(ValueError, 'Original config reader rejected.*ArgumentException'):
            self.prepare()

    def test_malformed_oracle_pairs_and_strict_boolean_reject(self):
        original = copy.deepcopy(self.oracle_value)
        mutations = [lambda x: x.update(schemaVersion=True), lambda x: x.update(inputs=[]),
                     lambda x: x['results']['configurations'].pop(),
                     lambda x: x['results']['configurations'][0].update(name='wrong'),
                     lambda x: x['inputs']['configurations'][0].update(data='!!'),
                     lambda x: x['results']['configurations'][0].update(value=0),
                     lambda x: x['results']['configurations'][0].update(value=None),
                     lambda x: x['sources'][0].update(sha256='0' * 64)]
        for index, mutate in enumerate(mutations):
            self.oracle_value = copy.deepcopy(original); mutate(self.oracle_value); self.write()
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.prepare()
        self.oracle.write_text('{"schemaVersion":1,"schemaVersion":1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            self.prepare()

    def test_configuration_hash_escape_and_changed_inputs_reject(self):
        self.config.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'configuration hash differs'):
            self.prepare()
        self.manifest_value['configuration']['file'] = '../outside.cfg'; self.write()
        with self.assertRaisesRegex(ValueError, 'escapes its package'):
            self.prepare()
        self.manifest_value['configuration']['file'] = '/absolute.cfg'; self.write()
        with self.assertRaisesRegex(ValueError, 'configuration path'):
            self.prepare()
        del self.manifest_value['configuration']; self.write()
        _, pins = self.prepare()
        self.oracle.write_text(self.oracle.read_text() + ' ')
        with self.assertRaisesRegex(ValueError, 'input changed'):
            probe.verify_input_pins(pins)

    def test_package_config_symlink_is_pinned_and_cannot_escape(self):
        original = self.config.read_bytes()
        first = self.root / 'first.cfg'; first.write_bytes(original)
        second = self.root / 'second.cfg'; second.write_bytes(b'different')
        self.config.unlink(); self.config.symlink_to(first)
        _, pins = self.prepare()
        self.config.unlink(); self.config.symlink_to(second)
        with self.assertRaisesRegex(ValueError, 'input changed'):
            probe.verify_input_pins(pins)
        self.config.unlink(); self.config.symlink_to(self.root.parent / 'outside.cfg')
        with self.assertRaisesRegex(ValueError, 'escapes its package'):
            self.prepare()

    def test_size_bounds_and_no_mute_contract(self):
        self.config.write_bytes(b'X' * (1024 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, 'byte bound'):
            self.prepare()
        self.manifest_value = dict(adapterID=ACCESSORY); self.write()
        expected, pins = probe.prepare_mute_expectation([self.manifest], None, None, None)
        self.assertIsNone(expected); probe.verify_input_pins(pins)
        with self.assertRaisesRegex(ValueError, 'requires a Mute manifest'):
            self.prepare()

    def test_oversized_oracle_and_duplicate_mute_mount_reject(self):
        with self.assertRaisesRegex(ValueError, 'exactly one requested Mute'):
            probe.prepare_mute_expectation([self.manifest, self.manifest], None, self.oracle, probe.digest(self.oracle))
        self.oracle.write_bytes(b' ' * (4 * 1024 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, 'byte bound'):
            self.prepare()

    def test_main_rejects_missing_or_hash_mismatched_evidence_before_spawn_or_output(self):
        output = self.root / 'must-not-exist'
        base = ['probe', '--executable', '/missing/app', '--scene', '/missing/scene',
                '--environment', '/missing/environment', '--manifest', '/missing/ir',
                '--native-manifest', str(self.manifest), '--output', str(output)]
        for extra in ([], ['--mute-oracle', str(self.oracle), '--mute-oracle-sha256', '0' * 64]):
            with self.subTest(extra=extra), mock.patch.object(sys, 'argv', base + extra), mock.patch.object(probe.subprocess, 'Popen') as spawn:
                with self.assertRaises(ValueError): probe.main()
                spawn.assert_not_called()
                self.assertFalse(output.exists())

    def test_hidden_environment_override_rejects_before_spawn(self):
        environment = self.root / 'environment.json'
        environment.write_text(json.dumps({'IKKOKU_MUTE_BACKGROUND_CONFIG': '/unverified/config'}))
        output = self.root / 'must-not-exist'
        args = ['probe', '--executable', '/missing/app', '--scene', '/missing/scene',
                '--environment', str(environment), '--manifest', '/missing/ir',
                '--native-manifest', str(self.manifest), '--output', str(output),
                '--mute-oracle', str(self.oracle), '--mute-oracle-sha256', probe.digest(self.oracle)]
        with mock.patch.object(sys, 'argv', args), mock.patch.object(probe.subprocess, 'Popen') as spawn:
            with self.assertRaisesRegex(ValueError, 'Use --mute-config'): probe.main()
            spawn.assert_not_called()
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
