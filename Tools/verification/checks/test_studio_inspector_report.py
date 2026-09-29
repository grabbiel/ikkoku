"""Unit tests for the Studio-inspector report validator (T-T04).

Stdlib only. Run from the repository root with:
    python3 -m unittest discover -s Tools/verification/checks -p 'test_*.py'
"""
import importlib.util
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "ikkoku_studio_inspector_report",
    os.path.join(_HERE, "studio_inspector_report.py"))
validator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validator)


class ValidateReportTests(unittest.TestCase):
    """`validate_report` on sample report JSON from the app."""

    def test_reaching_the_source_pose_inspector_passes(self):
        report = {
            "mode": "studio",
            "inspectorTab": "pose",
            "selectedObjectKind": "sourceCharacter",
            "selectedIsSourceCharacter": True,
            "inspectorView": "SourcePoseInspector",
            "sourceIKAvailable": True,
            "sourceAccessoryLabelCount": 3,
        }
        passed, reasons = validator.validate_report(report)
        self.assertTrue(passed, reasons)
        self.assertEqual(reasons, [])

    def test_wrong_inspector_view_fails(self):
        report = {
            "mode": "studio",
            "inspectorTab": "pose",
            "selectedObjectKind": "sourceCharacter",
            "selectedIsSourceCharacter": True,
            "inspectorView": "RigPoseInspector",
            "sourceIKAvailable": True,
            "sourceAccessoryLabelCount": 3,
        }
        passed, reasons = validator.validate_report(report)
        self.assertFalse(passed)
        self.assertTrue(any("SourcePoseInspector" in r for r in reasons))

    def test_missing_keys_fail(self):
        passed, reasons = validator.validate_report(
            {"mode": "studio", "inspectorView": "SourcePoseInspector"})
        self.assertFalse(passed)
        self.assertTrue(
            any("selectedIsSourceCharacter" in r for r in reasons))

    def test_string_true_is_not_true(self):
        # JSON booleans must be real booleans, never strings.
        passed, reasons = validator.validate_report(
            {"selectedIsSourceCharacter": "true",
             "inspectorView": "SourcePoseInspector"})
        self.assertFalse(passed)
        self.assertTrue(any("selectedIsSourceCharacter" in r for r in reasons))

    def test_expected_view_matching_passes(self):
        report = {
            "mode": "studio",
            "inspectorTab": "pose",
            "selectedObjectKind": "sourceCharacter",
            "selectedIsSourceCharacter": True,
            "inspectorView": "SourcePoseInspector",
            "expectedInspectorView": "SourcePoseInspector",
            "sourceIKAvailable": True,
            "sourceAccessoryLabelCount": 3,
        }
        passed, reasons = validator.validate_report(report)
        self.assertTrue(passed, reasons)

    def test_expected_view_mismatch_fails_and_names_both_views(self):
        report = {
            "selectedIsSourceCharacter": True,
            "inspectorView": "RigPoseInspector",
            "expectedInspectorView": "SourcePoseInspector",
        }
        passed, reasons = validator.validate_report(report)
        self.assertFalse(passed)
        self.assertTrue(any("SourcePoseInspector" in r and "RigPoseInspector" in r
                            for r in reasons))

    def test_missing_expected_view_key_is_still_validated(self):
        # No expectedInspectorView key: the original rules still apply —
        # a passing report needs selectedIsSourceCharacter=true and the
        # SourcePoseInspector view.
        passed, reasons = validator.validate_report(
            {"selectedIsSourceCharacter": True,
             "inspectorView": "SourcePoseInspector"})
        self.assertTrue(passed, reasons)
        passed, reasons = validator.validate_report(
            {"selectedIsSourceCharacter": True})
        self.assertFalse(passed)
        self.assertTrue(any("inspectorView" in r for r in reasons))


class MainTests(unittest.TestCase):
    """The CLI entry point: unreadable or malformed input must fail."""

    def test_missing_file_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "no-such-report.json")
            self.assertEqual(validator.main(["prog", missing]), 1)

    def test_bad_usage_fails(self):
        self.assertEqual(validator.main(["prog"]), 2)

    def test_good_report_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "report.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write('{"selectedIsSourceCharacter": true,'
                             ' "inspectorView": "SourcePoseInspector"}')
            self.assertEqual(validator.main(["prog", path]), 0)

    def test_malformed_json_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "report.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{not json")
            self.assertEqual(validator.main(["prog", path]), 1)


if __name__ == "__main__":
    unittest.main()
