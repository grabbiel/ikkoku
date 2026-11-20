"""Unit tests for the launch plug-in profile validator (#459).

Stdlib only. Run from the repository root with:
    python3 -m unittest discover -s Tools/verification/checks -p 'test_*.py'
"""
import importlib.util
import json
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "ikkoku_studio_launch_plugins",
    os.path.join(_HERE, "studio_launch_plugins.py"))
validator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validator)


def report(**launch_changes):
    launch = {"appliedAfterImport": True, "inputs": ["IKKOKU_SOURCE_PLUGIN_PROFILE"], "sourcePluginPackages": 2,
              "nativePlugins": 0, "sourcePluginsRunning": True, "charactersBuilt": 1}
    launch.update(launch_changes)
    return {"workload": "studio-idle", "details": {"launchStudioExecution": launch},
            "summary": {"startupMainThread": {"ready": True}}}


class ValidateReportTests(unittest.TestCase):
    """`validate_report` on performance-trace reports."""

    def test_a_profile_mounted_after_the_import_passes(self):
        self.assertEqual(validator.validate_report(report()), (True, []))

    def test_a_report_without_the_launch_record_fails(self):
        # Before #459: the inputs ran before the import committed and left no record.
        data = report()
        del data["details"]["launchStudioExecution"]
        passed, reasons = validator.validate_report(data)
        self.assertFalse(passed)
        self.assertIn("launchStudioExecution is missing", reasons[0])

    def test_inputs_applied_before_the_import_fail(self):
        passed, reasons = validator.validate_report(report(appliedAfterImport=False))
        self.assertFalse(passed)
        self.assertIn("appliedAfterImport", reasons[0])

    def test_no_profile_input_fails(self):
        passed, reasons = validator.validate_report(report(inputs=["IKKOKU_SOURCE_PLUGIN_STEPS"]))
        self.assertFalse(passed)
        self.assertIn("IKKOKU_SOURCE_PLUGIN_PROFILE", reasons[0])

    def test_nothing_mounted_or_built_fails(self):
        for key in ("sourcePluginPackages", "charactersBuilt"):
            for value in (0, None, True, "1"):
                passed, reasons = validator.validate_report(report(**{key: value}))
                self.assertFalse(passed, (key, value))
                self.assertIn(key, reasons[0])

    def test_a_startup_scene_that_was_not_ready_fails(self):
        data = report()
        data["summary"]["startupMainThread"] = {"ready": False}
        passed, reasons = validator.validate_report(data)
        self.assertFalse(passed)
        self.assertIn("startupMainThread.ready", reasons[0])

    def test_a_non_object_fails(self):
        self.assertFalse(validator.validate_report([])[0])


class MainTests(unittest.TestCase):
    """The command line: exit 0 only for a passing report file."""

    def run_main(self, content):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "trace.json")
            if content is not None:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            return validator.main(["studio_launch_plugins.py", path])

    def test_exit_codes(self):
        self.assertEqual(self.run_main(json.dumps(report())), 0)
        self.assertEqual(self.run_main(json.dumps(report(sourcePluginPackages=0))), 1)
        self.assertEqual(self.run_main("{not json"), 1)
        self.assertEqual(self.run_main(None), 1)
        self.assertEqual(validator.main(["studio_launch_plugins.py"]), 2)


if __name__ == "__main__":
    unittest.main()
