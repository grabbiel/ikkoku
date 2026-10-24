"""Public oracle-contract tests use synthetic observations, never Unity assets."""
import copy
import unittest
from unittest import mock

import original_hide_studio_ui_probe as probe


def trace():
    keys = ['original-canvas-1', 'captured-disabled-canvas', 'inactive-at-capture',
            'captured-renamed-later', 'dynamic-plugin-before', 'dynamic-plugin-inactive',
            'owned-gizmo', 'late-game', 'dynamic-plugin-late']
    def row(key):
        index = keys.index(key) + 1
        return dict(key=key, name=key, existence='alive', instanceID=index,
                    canvasInstanceID=index + 100 if key != 'owned-gizmo' else 0,
                    activeSelf=True, activeInHierarchy=True, hasCanvas=key != 'owned-gizmo', canvasEnabled=True)
    current = {key: row(key) for key in keys[:7]}
    for key in ('captured-disabled-canvas', 'dynamic-plugin-before'):
        current[key]['canvasEnabled'] = False
    for key in ('inactive-at-capture', 'dynamic-plugin-inactive'):
        current[key]['activeSelf'] = current[key]['activeInHierarchy'] = False
    phases = []
    def record(name, visible, captured=(101, 102), error=None):
        phases.append(dict(name=name, handlerVisible=visible, capturedCanvasIDs=list(captured) if captured else None,
                           invocationError=error if name == 'toggle-after-destroy' else None,
                           capturedEnumerationError=error,
                           targets=copy.deepcopy(list(current.values()))))
    saved = current
    current = {'original-canvas-1': current['original-canvas-1']}
    record('original-startup', True, (101,))
    current = saved
    record('controlled-init', True)
    def toggle(value, late=False):
        for key in ('original-canvas-1', 'captured-disabled-canvas', 'owned-gizmo'):
            current[key]['activeSelf'] = current[key]['activeInHierarchy'] = value
        current['dynamic-plugin-before']['canvasEnabled'] = value
        if late:
            current['captured-renamed-later']['activeSelf'] = current['captured-renamed-later']['activeInHierarchy'] = value
            current['dynamic-plugin-late']['canvasEnabled'] = value
    toggle(False); record('toggle-1', False)
    for key in keys[7:]:
        current[key] = row(key)
    current['dynamic-plugin-late']['canvasEnabled'] = False
    current['captured-renamed-later']['name'] = 'CvsColor'
    record('late-targets', False, (101, 102, 104))
    toggle(True, True); record('toggle-2', True, (101, 102, 104))
    toggle(False, True)
    current['dynamic-plugin-inactive'].update(activeSelf=True, activeInHierarchy=True, canvasEnabled=False)
    record('toggle-3', False, (101, 102, 104))
    for key in ('captured-disabled-canvas', 'dynamic-plugin-before', 'owned-gizmo'):
        current[key].update(existence='destroyed', activeSelf=False, activeInHierarchy=False, hasCanvas=False, canvasEnabled=False)
    error = 'System.NullReferenceException: captured Canvas destroyed'
    record('destroyed-targets', False, (), error)
    record('toggle-after-destroy', True, (), error)
    record('controlled-reinit', True, (108,))
    current['late-game']['activeSelf'] = current['late-game']['activeInHierarchy'] = False
    record('toggle-after-reinit', False, (108,))
    return dict(schemaVersion=1, kind='original-unity-hide-studio-ui', productName='CharaStudio',
                unityVersion='5.6.2f1', originalStartupHandlerObserved=True, error=None, phases=phases)


class HideStudioUIOracleTests(unittest.TestCase):
    def test_expected_trace_preserves_distinct_active_and_enabled_semantics(self):
        self.assertTrue(probe.validate_report(trace())['passed'])

    def test_changed_identity_duplicate_missing_or_error_fails(self):
        for mutation in (
            lambda r: r['phases'].pop(),
            lambda r: r['phases'][1]['targets'].append(r['phases'][1]['targets'][0]),
            lambda r: r['phases'][2]['targets'][1].update(instanceID=999),
            lambda r: r.update(originalStartupHandlerObserved=False),
            lambda r: r['phases'][7].update(invocationError=None),
            lambda r: r['phases'][7].update(invocationError='UnityEngine.MissingReferenceException: guessed'),
            lambda r: r.update(unityVersion='different'),
            lambda r: r['phases'][8]['targets'][1].update(existence='alive'),
        ):
            report = trace(); mutation(report)
            with self.assertRaises(ValueError):
                probe.validate_report(report)

    def test_wrong_canvas_or_late_capture_behavior_fails(self):
        for phase, key, field, value in (
            (2, 'captured-disabled-canvas', 'canvasEnabled', True),
            (4, 'inactive-at-capture', 'activeSelf', True),
            (4, 'dynamic-plugin-inactive', 'canvasEnabled', False),
            (5, 'late-game', 'activeSelf', False),
            (7, 'dynamic-plugin-late', 'canvasEnabled', True),
        ):
            report = trace()
            next(row for row in report['phases'][phase]['targets'] if row['key'] == key)[field] = value
            with self.assertRaises(ValueError):
                probe.validate_report(report)

    def test_cleanup_rejects_non_owned_root_before_vm_call(self):
        with mock.patch.object(probe, 'powershell') as call:
            with self.assertRaises(ValueError):
                probe.stop_owned('fixture', {'root': r'C:\Illusion\Koikatsu'})
            call.assert_not_called()


if __name__ == '__main__':
    unittest.main()
