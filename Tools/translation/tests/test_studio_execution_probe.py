"""Check the adapter-report acceptance rules without launching the app."""
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import studio_execution_probe as probe

ACCESSORY = 'kk-studio-accessory-names-v1'


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

    def reports(self, enabled=False, events=(False, True), created=False, mute=True):
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
        awaiting = not created
        mount = dict(mounted=mute, awaitingInitialFocus=awaiting and mute, focusObservers=2 if mute else 0,
                     launchObserver=awaiting and mute)
        final = dict(mount, awaitingInitialFocus=mount['awaitingInitialFocus'] and not events,
                     launchObserver=mount['launchObserver'] and not events)
        if mute:
            mount['enabled'] = final['enabled'] = enabled
        report = dict(schemaVersion=1, applicationCreated=created, nativePlugins=refs, accessoryNamesEnabled=True,
                      mount=mount, focusTrace=trace, final=final)
        return {mode: copy.deepcopy(report) for mode in ('run', 'reload', 'continue')}

    def check(self, reports, events=(False, True)):
        probe.check_adapter_reports(reports, self.manifests, list(events))

    def test_installed_disabled_configuration_keeps_gain_through_focus_loss(self):
        self.check(self.reports())
        muted = self.reports()
        muted['reload']['focusTrace'][1].update(masterVolume=0., toneRMS=0.)
        with self.assertRaisesRegex(ValueError, 'reload: master or voice gain'):
            self.check(muted)

    def test_enabled_configuration_mutes_restores_and_keeps_repeated_loss_quirk(self):
        self.check(self.reports(enabled=True))
        events = (False, False, True)
        self.assertEqual(probe.mute_volumes(True, .73, events), [0., 0., 0.])
        self.check(self.reports(enabled=True, events=events), events)
        restored = self.reports(enabled=True, events=events)
        restored['continue']['focusTrace'][3].update(masterVolume=1., toneRMS=.17)
        with self.assertRaisesRegex(ValueError, 'continue: master or voice gain'):
            self.check(restored, events)

    def test_generated_tone_must_follow_master_gain(self):
        reports = self.reports(enabled=True)
        reports['run']['focusTrace'][1]['toneRMS'] = .01
        with self.assertRaisesRegex(ValueError, 'run: generated-tone gain'):
            self.check(reports)
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
        with self.assertRaisesRegex(ValueError, 'before NSApplication existed'):
            self.check(premature)
        stale = self.reports()
        stale['reload']['final']['launchObserver'] = True
        with self.assertRaisesRegex(ValueError, 'deferred initial focus observer'):
            self.check(stale)
        self.check(self.reports(created=True))

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
        self.check(self.reports(mute=False, events=()), ())
        mounted = self.reports(mute=False, events=())
        mounted['run']['mount']['mounted'] = True
        with self.assertRaisesRegex(ValueError, 'unexpected Mute adapter state'):
            self.check(mounted, ())


if __name__ == '__main__':
    unittest.main()
