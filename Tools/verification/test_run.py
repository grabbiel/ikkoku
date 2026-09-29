"""Unit tests for the manifest-driven verification runner (T-T04/E-T03).

Stdlib only. Run from the repository root with:
    python3 -m unittest discover -s Tools/verification -p 'test_*.py'
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "ikkoku_verification_run", os.path.join(_HERE, "run.py"))
run = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(run)

# Expected swift-testing counts, keyed on the per-test samples the runner
# must parse per name and reason (source: the trace files in `.local`).
SWIFT_SAMPLES = [
    # All pass: summary total equals executed because nothing was skipped.
    """
✔ Test drawUniformsStride() passed after 0.003 seconds.
✔ Test otherKernel() passed after 0.001 seconds.
✔ Test run with 2 tests in 0 suites passed after 0.593 seconds.
""",
    # Skips, one with a quoted reason, and a failed test.
    """
✘ Test sourceCharacterCardMatchesIndependentPythonOriginalFormatOracle() failed after 0.004 seconds.
➜ Test sourceModCatalogMatchesIndependentRecoveredCSVAndResolverFixtures() skipped.
➜ Test sourceBoneModifierMatchesIndependentLocalNumPyMatrices() skipped: "Requires IKKOKU_ABMX_REFERENCE"
✘ Test issueRaised() recorded an issue at SomeFile.swift:12:3:
✘ Test issueRaised() recorded an issue at SomeFile.swift:20:9:
✔ Test run with 4 tests in 0 suites failed after 0.206 seconds with 3 issues.
""",
]

SWIFT_EXPECTED = [
    {"total": 2, "executed": 2,
     "counts": {"passed": 2, "failed": 0, "skipped": 0},
     "tests": [{"name": "drawUniformsStride()", "status": "passed", "reason": None},
               {"name": "otherKernel()", "status": "passed", "reason": None}]},
    {"total": 4, "executed": 2,
     "counts": {"passed": 0, "failed": 2, "skipped": 2},
     "tests": [
         {"name": "issueRaised()", "status": "failed", "reason": None},
         {"name": "sourceBoneModifierMatchesIndependentLocalNumPyMatrices()",
          "status": "skipped", "reason": "Requires IKKOKU_ABMX_REFERENCE"},
         {"name": "sourceCharacterCardMatchesIndependentPythonOriginalFormatOracle()",
          "status": "failed", "reason": None},
         {"name": "sourceModCatalogMatchesIndependentRecoveredCSVAndResolverFixtures()",
          "status": "skipped", "reason": None}]},
]


class SwiftTestingParserTests(unittest.TestCase):
    """The swift-testing parser on the exact observed sample lines."""

    def test_sample_outputs(self):
        for sample, expected in zip(SWIFT_SAMPLES, SWIFT_EXPECTED):
            with self.subTest(sample=sample[:40]):
                parsed = run.parse_swift_testing(sample)
                self.assertIsNotNone(parsed)
                self.assertEqual(parsed["total"], expected["total"])
                self.assertEqual(parsed["executed"], expected["executed"])
                self.assertEqual(parsed["counts"], expected["counts"])
                self.assertEqual(parsed["tests"], expected["tests"])

    def test_per_test_totals_override_missing_summary(self):
        parsed = run.parse_swift_testing(
            "✘ Test t() failed after 0.100 seconds.\n")
        self.assertEqual(parsed["total"], None)
        self.assertEqual(parsed["executed"], 1)
        self.assertEqual(parsed["counts"], {"passed": 0, "failed": 1, "skipped": 0})

    def test_worst_status_wins_per_test(self):
        parsed = run.parse_swift_testing(
            "✔ Test flaky() passed after 0.100 seconds.\n"
            "✘ Test flaky() failed after 0.100 seconds.\n")
        self.assertEqual(parsed["tests"][0]["status"], "failed")
        self.assertEqual(parsed["executed"], 1)

    def test_unrelated_output_not_parsed(self):
        self.assertIsNone(run.parse_swift_testing("hello world\n"))


class UnittestParserTests(unittest.TestCase):
    """The Python unittest parser on the documented summary shapes."""

    def test_ok(self):
        parsed = run.parse_unittest("Ran 12 tests in 0.123s\n\nOK\n")
        self.assertEqual(parsed["total"], 12)
        self.assertEqual(parsed["executed"], 12)
        self.assertEqual(parsed["counts"], {"passed": 12, "failed": 0, "skipped": 0})

    def test_ok_with_skips(self):
        parsed = run.parse_unittest("Ran 5 tests in 0.1s\n\nOK (skipped=2)\n")
        self.assertEqual(parsed["total"], 5)
        self.assertEqual(parsed["executed"], 3)
        self.assertEqual(parsed["counts"], {"passed": 3, "failed": 0, "skipped": 2})

    def test_failed_summary(self):
        parsed = run.parse_unittest(
            "Ran 8 tests in 0.5s\n\nFAILED (failures=1, errors=1, skipped=2)\n")
        self.assertEqual(parsed["total"], 8)
        self.assertEqual(parsed["executed"], 6)
        self.assertEqual(parsed["counts"], {"passed": 4, "failed": 2, "skipped": 2})

    def test_partial_failure_summaries(self):
        # Real unittest prints only the nonzero fields, in any subset.
        parsed = run.parse_unittest(
            "Ran 3 tests in 0.1s\n\nFAILED (failures=1)\n")
        self.assertEqual(parsed["total"], 3)
        self.assertEqual(parsed["executed"], 3)
        self.assertEqual(parsed["counts"], {"passed": 2, "failed": 1, "skipped": 0})

        parsed = run.parse_unittest(
            "Ran 4 tests in 0.1s\n\nFAILED (errors=1, skipped=1)\n")
        self.assertEqual(parsed["total"], 4)
        self.assertEqual(parsed["executed"], 3)
        self.assertEqual(parsed["counts"], {"passed": 2, "failed": 1, "skipped": 1})

    def test_expected_failure_counts_as_passed(self):
        parsed = run.parse_unittest(
            "Ran 3 tests in 0.1s\n\nOK (expected failures=1)\n")
        self.assertEqual(parsed["counts"],
                         {"passed": 3, "failed": 0, "skipped": 0})
        self.assertEqual(parsed["executed"], 3)

    def test_expected_failure_with_skips(self):
        parsed = run.parse_unittest(
            "Ran 6 tests in 0.1s\n\nOK (skipped=2, expected failures=1)\n")
        self.assertEqual(parsed["counts"],
                         {"passed": 4, "failed": 0, "skipped": 2})
        self.assertEqual(parsed["executed"], 4)

    def test_unexpected_success_counts_as_failed(self):
        parsed = run.parse_unittest(
            "Ran 3 tests in 0.1s\n\nFAILED (unexpected successes=1)\n")
        self.assertEqual(parsed["counts"],
                         {"passed": 2, "failed": 1, "skipped": 0})
        self.assertEqual(parsed["executed"], 3)

    def test_unexpected_success_with_skips(self):
        parsed = run.parse_unittest(
            "Ran 5 tests in 0.1s\n\nFAILED (unexpectedsuccesses=1, skipped=2)\n")
        self.assertEqual(parsed["counts"],
                         {"passed": 2, "failed": 1, "skipped": 2})

    def test_unknown_summary_key_not_guessed(self):
        parsed = run.parse_unittest("Ran 3 tests in 0.1s\n\nOK (frobnicated=2)\n")
        # "frobnicated" is not a failure or skip key → all executed/passed.
        self.assertEqual(parsed["counts"], {"passed": 3, "failed": 0, "skipped": 0})

    def test_per_test_records(self):
        parsed = run.parse_unittest(
            "test_x (test_mod.Case.test_x) ... skipped 'Requires IKKOKU_X'\n"
            "test_y (test_mod.Case.test_y) ... ERROR\n"
            "Ran 2 tests in 0.1s\n\nFAILED (failures=0, errors=1, skipped=1)\n")
        by_name = {t["name"]: t for t in parsed["tests"]}
        self.assertEqual(by_name["test_x"]["reason"], "Requires IKKOKU_X")
        self.assertEqual(by_name["test_x"]["status"], "skipped")
        self.assertEqual(by_name["test_y"]["status"], "failed")
        self.assertEqual(parsed["executed"], 1)

    def test_unrelated_output_not_parsed(self):
        self.assertIsNone(run.parse_unittest("no results here\n"))


class ManifestValidationTests(unittest.TestCase):
    """schemaVersion 2, tier, bounds and env allow-list validation."""

    def good_manifest(self):
        return {
            "schemaVersion": 2,
            "checks": [{
                "id": "engine", "argv": ["swift", "test", "--package-path",
                                          "Packages/Engine"],
                "fixtures": [{"env": "IKKOKU_SOURCE_SCENE", "kind": "file"}],
                "env": {"IKKOKU_CAPTURE_UI_MODE": "studio"},
                "minimumTests": 3, "maximumSkipped": 0,
                "referenceTier": "synthetic",
            }],
        }

    def test_good_manifest_accepted(self):
        checks = run.validate_manifest(self.good_manifest())
        self.assertEqual(checks[0]["id"], "engine")

    def test_reject_wrong_schema_version(self):
        bad = self.good_manifest()
        bad["schemaVersion"] = 1
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)

    def test_reject_unknown_tier(self):
        bad = self.good_manifest()
        bad["checks"][0]["referenceTier"] = "guess"
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)

    def test_reject_negative_bounds(self):
        for key in ("minimumTests", "maximumSkipped"):
            bad = self.good_manifest()
            bad["checks"][0][key] = -1
            with self.subTest(key=key), self.assertRaises(run.RunnerError):
                run.validate_manifest(bad)

    def test_reject_non_string_env_value(self):
        bad = self.good_manifest()
        bad["checks"][0]["env"]["IKKOKU_X"] = 3
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)

    def test_reject_non_ikkoku_env_name(self):
        bad = self.good_manifest()
        bad["checks"][0]["env"]["HOME"] = "/tmp"
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)

    def test_reject_dangerous_env_names(self):
        bad = self.good_manifest()
        bad["checks"][0]["env"]["PYTHONPATH"] = "/evil"
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)

    def test_reject_out_of_root_artifacts(self):
        bad = self.good_manifest()
        bad["checks"][0]["artifacts"] = [{"path": "../outside", "kind": "x"}]
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)

    def test_reject_non_bool_optional(self):
        bad = self.good_manifest()
        bad["checks"][0]["fixtures"] = [
            {"env": "IKKOKU_SOURCE_SCENE", "kind": "file", "optional": "yes"}]
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)


class EnvironmentValidationTests(unittest.TestCase):
    """Only IKKOKU_* names are accepted from an environment file."""

    def test_reject_non_string(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env.json")
            with open(path, "w") as handle:
                handle.write('{"IKKOKU_X": 5}')
            with self.assertRaises(run.RunnerError):
                run.load_environment(path)

    def test_reject_wrong_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env.json")
            with open(path, "w") as handle:
                handle.write('{"PATH": "/evil"}')
            with self.assertRaises(run.RunnerError):
                run.load_environment(path)


class CheckExecutionTests(unittest.TestCase):
    """Fixture gating, test-count bounds and report handling."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ikkoku-runner-tests")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.log_dir = os.path.join(self.tmp, "logs")
        os.makedirs(self.log_dir, exist_ok=True)

    def check(self, **overrides):
        base = {
            "id": "probe",
            "argv": [sys.executable, "-c",
                     "print('Ran 3 tests in 0.1s');print();print('OK');import sys;sys.exit(0)"],
            "referenceTier": "synthetic",
        }
        base.update(overrides)
        return base

    def run_check(self, **overrides):
        check = self.check(**overrides)
        return run.run_check(check, {}, False, 60.0, self.log_dir)

    def probe_environment(self, check, env_map=None, strict=False):
        check["argv"] = [sys.executable, "-c",
                         "import json, os; print(json.dumps({k: v for k, v in "
                         "os.environ.items() if k.startswith('IKKOKU_')}))"]
        record = run.run_check(check, env_map or {}, strict, 60.0, self.log_dir)
        self.assertEqual(record["status"], "passed")
        with open(os.path.join(self.log_dir, check["id"] + ".log")) as handle:
            observed = json.load(handle)
        self.assertEqual(record["passedEnvironment"], sorted(observed))
        return record, observed

    def test_undeclared_environment_file_setting_is_not_passed(self):
        record, observed = self.probe_environment(
            self.check(), {"IKKOKU_CAPTURE_UI_MODE": "studio"})
        self.assertEqual(observed, {})
        self.assertEqual(record["passedEnvironment"], [])

    def test_ambient_ikkoku_setting_is_not_passed(self):
        with mock.patch.dict(os.environ, {"IKKOKU_MOD_LIBRARY": "ambient"}):
            _record, observed = self.probe_environment(self.check(
                fixtures=[{"env": "IKKOKU_MOD_LIBRARY", "kind": "file",
                           "optional": True}]))
        self.assertNotIn("IKKOKU_MOD_LIBRARY", observed)

    def test_declared_supplied_fixture_is_passed(self):
        fixture_path = os.path.join(self.tmp, "fixture.json")
        with open(fixture_path, "w") as handle:
            handle.write("{}")
        record, observed = self.probe_environment(
            self.check(fixtures=[{"env": "IKKOKU_SOURCE_SCENE", "kind": "file"}]),
            {"IKKOKU_SOURCE_SCENE": fixture_path, "IKKOKU_MOD_LIBRARY": "unrelated"})
        self.assertEqual(observed, {"IKKOKU_SOURCE_SCENE": fixture_path})
        self.assertEqual(record["suppliedFixtures"][0]["path"], fixture_path)
        self.assertEqual(record["env"], {})

    def test_check_env_overrides_fixture_and_environment_map(self):
        fixture_path = os.path.join(self.tmp, "fixture.json")
        with open(fixture_path, "w") as handle:
            handle.write("{}")
        check = self.check(
            fixtures=[{"env": "IKKOKU_SOURCE_SCENE", "kind": "file"}],
            env={"IKKOKU_SOURCE_SCENE": "override", "IKKOKU_CAPTURE_UI_MODE": "studio"})
        record, observed = self.probe_environment(
            check, {"IKKOKU_SOURCE_SCENE": fixture_path,
                    "IKKOKU_CAPTURE_UI_MODE": "wrong"})
        self.assertEqual(observed, {"IKKOKU_SOURCE_SCENE": "override",
                                    "IKKOKU_CAPTURE_UI_MODE": "studio"})
        self.assertEqual(record["env"], check["env"])
        self.assertEqual(record["suppliedFixtures"][0]["path"], fixture_path)

    def test_strict_flag_only_passed_in_strict_mode(self):
        check = self.check()
        with mock.patch.dict(os.environ, {"IKKOKU_REQUIRE_SOURCE_FIXTURES": "ambient"}):
            _record, observed = self.probe_environment(check)
            self.assertNotIn("IKKOKU_REQUIRE_SOURCE_FIXTURES", observed)
            record, observed = self.probe_environment(check, strict=True)
        self.assertEqual(observed, {"IKKOKU_REQUIRE_SOURCE_FIXTURES": "1"})
        self.assertEqual(record["passedEnvironment"], ["IKKOKU_REQUIRE_SOURCE_FIXTURES"])

    def test_missing_fixture_skips(self):
        record = self.run_check(
            fixtures=[{"env": "IKKOKU_NOT_SUPPLIED", "kind": "file"}])
        self.assertEqual(record["status"], "skipped")
        self.assertIn("missing fixture", record["error"])
        self.assertIn("IKKOKU_NOT_SUPPLIED", record["error"])  # named
        self.assertIsNone(record["logPath"])  # never executed

    def test_missing_fixture_fails_under_strict(self):
        check = self.check(fixtures=[{"env": "IKKOKU_NOT_SUPPLIED", "kind": "file"}])
        record = run.run_check(check, {}, True, 60.0, self.log_dir)
        self.assertEqual(record["status"], "failed")
        self.assertIn("(strict)", record["error"])

    def test_missing_optional_fixture_still_runs(self):
        # An optional fixture that is not supplied is recorded as missing
        # but does not skip the check.
        record = self.run_check(
            fixtures=[{"env": "IKKOKU_OPTIONAL_MISSING", "kind": "file",
                       "optional": True}])
        self.assertEqual(record["status"], "passed")
        self.assertEqual([f["env"] for f in record["missingFixtures"]],
                         ["IKKOKU_OPTIONAL_MISSING"])
        self.assertTrue(record["missingFixtures"][0]["optional"])
        self.assertEqual(record["tests"]["executed"], 3)
        self.assertIsNotNone(record["logPath"])  # the check really ran

    def test_missing_optional_fixture_fails_under_strict(self):
        check = self.check(
            fixtures=[{"env": "IKKOKU_OPTIONAL_MISSING", "kind": "file",
                       "optional": True}])
        record = run.run_check(check, {}, True, 60.0, self.log_dir)
        self.assertEqual(record["status"], "failed")
        self.assertIn("IKKOKU_OPTIONAL_MISSING", record["error"])
        self.assertIn("(strict)", record["error"])

    def test_required_and_optional_mix_skips_for_required(self):
        # A missing required fixture skips the check even if the optional
        # one is supplied.
        record = self.run_check(
            fixtures=[{"env": "IKKOKU_MUST_EXIST", "kind": "file"},
                      {"env": "IKKOKU_OPTIONAL", "kind": "file",
                       "optional": True}])
        self.assertEqual(record["status"], "skipped")
        self.assertEqual({f["env"] for f in record["missingFixtures"]},
                         {"IKKOKU_MUST_EXIST", "IKKOKU_OPTIONAL"})

    def test_supplied_but_absent_fixture_path_fails(self):
        # A declared fixture whose environment value points at a
        # nonexistent path is malformed → always failed, even without --strict.
        record = run.run_check(
            self.check(fixtures=[{"env": "IKKOKU_BAD_PATH", "kind": "file"}]),
            {"IKKOKU_BAD_PATH": os.path.join(self.tmp, "does-not-exist.bin")},
            False, 60.0, self.log_dir)
        self.assertEqual(record["status"], "failed")
        self.assertIn("malformed", record["error"])

    def test_minimum_tests_applies_to_executed_count(self):
        # 3 executed of which all are executed/passed → below 4 fails.
        record = self.run_check(minimumTests=4)
        self.assertEqual(record["status"], "failed")
        self.assertIn("below minimumTests", record["error"])

        # Same run at the exact executed count passes.
        record = self.run_check(minimumTests=3)
        self.assertEqual(record["status"], "passed")
        self.assertEqual(record["tests"]["executed"], 3)

    def test_minimum_tests_unparseable_output_fails(self):
        record = self.run_check(
            argv=[sys.executable, "-c", "print('nonsense')"], minimumTests=1)
        self.assertEqual(record["status"], "failed")
        self.assertIn("could not parse", record["error"])

    def test_maximum_skipped(self):
        record = self.run_check(
            argv=[sys.executable, "-c",
                  "print('Ran 4 tests');print();print('OK (skipped=2)')"],
            maximumSkipped=1)
        self.assertEqual(record["status"], "failed")
        self.assertIn("above maximumSkipped", record["error"])

        record = self.run_check(
            argv=[sys.executable, "-c",
                  "print('Ran 4 tests');print();print('OK (skipped=2)')"],
            maximumSkipped=2)
        self.assertEqual(record["status"], "passed")

    def test_artifact_hashing_after_run(self):
        # Create an artifact during the run and hash it.
        with tempfile.TemporaryDirectory(dir=run.REPO_ROOT) as artifact_dir:
            artifact = os.path.join(artifact_dir, "out.txt")
            record = self.run_check(
                argv=[sys.executable, "-c",
                      "open(%r,'w').write('evidence');print('Ran 1 test');print();"
                      "print('OK')" % artifact],
                artifacts=[{"path": os.path.relpath(artifact, run.REPO_ROOT),
                            "kind": "report"}])
            self.assertEqual(record["status"], "passed")
            entry = record["artifacts"][0]
            self.assertEqual(len(entry["sha256"]), 64)

        # A missing artifact fails the check.
        with tempfile.TemporaryDirectory(dir=run.REPO_ROOT) as artifact_dir:
            missing = os.path.join(artifact_dir, "does", "not", "exist.bin")
            record = self.run_check(
                artifacts=[{"path": os.path.relpath(missing, run.REPO_ROOT),
                            "kind": "report"}])
            self.assertEqual(record["status"], "failed")
            self.assertIn("not hashed", record["error"])

    def test_artifact_parent_created_before_command(self):
        with tempfile.TemporaryDirectory(dir=run.REPO_ROOT) as artifact_dir:
            artifact = os.path.join(artifact_dir, "nested", "captures", "pose.json")
            record = self.run_check(
                argv=[sys.executable, "-c",
                      "from pathlib import Path; Path(%r).write_text('evidence');"
                      "print('Ran 1 test');print();print('OK')" % artifact],
                artifacts=[{"path": os.path.relpath(artifact, run.REPO_ROOT),
                            "kind": "report"}])
            self.assertEqual(record["status"], "passed")
            self.assertTrue(os.path.isdir(os.path.dirname(artifact)))
            self.assertEqual(len(record["artifacts"][0]["sha256"]), 64)

    def test_artifact_symlink_escape_rejected_before_command(self):
        with tempfile.TemporaryDirectory(dir=run.REPO_ROOT) as artifact_dir:
            outside = os.path.join(self.tmp, "outside")
            os.symlink(outside, os.path.join(artifact_dir, "escape"))
            marker = os.path.join(self.tmp, "command-ran")
            record = self.run_check(
                argv=[sys.executable, "-c",
                      "from pathlib import Path; Path(%r).touch()" % marker],
                artifacts=[{"path": os.path.relpath(
                    os.path.join(artifact_dir, "escape", "pose.json"), run.REPO_ROOT),
                    "kind": "report"}])
            self.assertEqual(record["status"], "failed")
            self.assertIn("artifact path must stay inside the repository", record["error"])
            self.assertFalse(os.path.exists(marker))
            self.assertFalse(os.path.exists(outside))

    def test_artifact_hash_recorded_not_file_contents(self):
        src = os.path.join(self.tmp, "fixture.json")
        with open(src, "w") as handle:
            handle.write("private contents")
        record = self.run_check(
            fixtures=[{"env": "IKKOKU_FIXTURE", "kind": "file"}])
        # No environment supplied → skipped; with a supplied path the
        # report stores the path and hash, never the bytes.
        self.assertEqual(record["status"], "skipped")
        record = run.run_check(
            self.check(fixtures=[{"env": "IKKOKU_FIXTURE", "kind": "file"}]),
            {"IKKOKU_FIXTURE": src}, False, 60.0, self.log_dir)
        self.assertEqual(record["status"], "passed")
        fixture = record["suppliedFixtures"][0]
        self.assertEqual(len(fixture["sha256"]), 64)

    def test_check_exit_code_recorded(self):
        record = self.run_check(argv=[sys.executable, "-c", "import sys; sys.exit(3)"])
        self.assertEqual(record["exitCode"], 3)
        self.assertEqual(record["status"], "failed")

    def test_report_refuses_overwrite(self):
        local_dir = os.path.join(self.tmp, "reports")
        os.makedirs(local_dir)
        report = os.path.join(local_dir, "report-unit-test.json")
        with mock.patch.object(run, "LOCAL_DIR", local_dir):
            self.assertEqual(run.resolve_report_path(report), os.path.abspath(report))
            with open(report, "w") as handle:
                handle.write("{}")
            with self.assertRaises(run.RunnerError):
                run.resolve_report_path(report)

    def test_report_outside_local_dir_rejected(self):
        with self.assertRaises(run.RunnerError):
            run.resolve_report_path(os.path.join(self.tmp, "report.json"))


if __name__ == "__main__":
    unittest.main()
