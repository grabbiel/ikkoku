"""Unit tests for the manifest-driven verification runner (T-T04/E-T03).

Stdlib only. Run from the repository root with:
    python3 -m unittest discover -s Tools/verification -p 'test_*.py'
"""
import importlib.util
import json
import os
import re
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

    def test_multiple_executables_sum_totals_and_preserve_results(self):
        # SwiftPM emits one summary per test executable. Keep fixture skips
        # and failures visible when aggregating the combined process log.
        parsed = run.parse_swift_testing(
            "✔ Test geometry() passed after 0.001 seconds.\n"
            '➜ Test sourceFixture() skipped: "Requires IKKOKU_FIXTURE"\n'
            "✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.\n"
            "✘ Test application() recorded an issue at App.swift:12:3:\n"
            "✘ Test application() failed after 0.001 seconds.\n"
            "✘ Test run with 1 test in 1 suite failed after 0.002 seconds with 1 issue.\n")
        self.assertEqual(parsed["total"], 3)
        self.assertEqual(parsed["executed"], 2)
        self.assertEqual(parsed["counts"], {"passed": 1, "failed": 1, "skipped": 1})
        by_name = {test["name"]: test for test in parsed["tests"]}
        self.assertEqual(by_name["sourceFixture()"]["reason"], "Requires IKKOKU_FIXTURE")
        self.assertEqual(by_name["application()"]["status"], "failed")

    def test_multiple_executable_summary_only_totals(self):
        parsed = run.parse_swift_testing(
            "✔ Test run with 511 tests in 0 suites passed after 1.0 seconds.\n"
            "✔ Test run with 12 tests in 0 suites passed after 0.1 seconds.\n")
        self.assertEqual(parsed["total"], 523)
        self.assertEqual(parsed["executed"], 523)
        self.assertEqual(parsed["counts"], {"passed": 523, "failed": 0, "skipped": 0})
        self.assertEqual(parsed["tests"], [])

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

    def test_fixture_from_accepted(self):
        good = self.good_manifest()
        good["checks"][0]["fixtures"] = [
            {"env": "IKKOKU_SOURCE_SCENE", "kind": "file",
             "from": "IKKOKU_CAMERA_PROBE_SCENE"}]
        checks = run.validate_manifest(good)
        self.assertEqual(checks[0]["fixtures"][0]["from"],
                         "IKKOKU_CAMERA_PROBE_SCENE")

    def test_reject_fixture_from_wrong_prefix(self):
        bad = self.good_manifest()
        bad["checks"][0]["fixtures"] = [
            {"env": "IKKOKU_SOURCE_SCENE", "kind": "file", "from": "HOME"}]
        with self.assertRaises(run.RunnerError):
            run.validate_manifest(bad)

    def test_reject_dangerous_fixture_from_name(self):
        bad = self.good_manifest()
        bad["checks"][0]["fixtures"] = [
            {"env": "IKKOKU_SOURCE_SCENE", "kind": "file", "from": "PYTHONPATH"}]
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

    def test_fixture_from_fills_env_from_another_environment_key(self):
        aliased = os.path.join(self.tmp, "scene-x.json")
        with open(aliased, "w") as handle:
            handle.write("{}")
        record, observed = self.probe_environment(
            self.check(fixtures=[{"env": "IKKOKU_SOURCE_SCENE", "kind": "file",
                                  "from": "IKKOKU_CAMERA_PROBE_SCENE"}]),
            {"IKKOKU_CAMERA_PROBE_SCENE": aliased,
             "IKKOKU_SOURCE_SCENE": os.path.join(self.tmp, "direct.json")})
        self.assertEqual(observed, {"IKKOKU_SOURCE_SCENE": aliased})
        self.assertEqual(record["suppliedFixtures"][0]["path"], aliased)
        self.assertEqual(record["suppliedFixtures"][0]["from"],
                         "IKKOKU_CAMERA_PROBE_SCENE")

    def test_missing_aliased_fixture_skips_naming_the_fixture(self):
        record = self.run_check(
            fixtures=[{"env": "IKKOKU_SOURCE_SCENE", "kind": "file",
                       "from": "IKKOKU_CAMERA_PROBE_SCENE"}])
        self.assertEqual(record["status"], "skipped")
        self.assertIn("missing fixture: IKKOKU_SOURCE_SCENE", record["error"])

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

    def test_empty_artifact_fails_even_after_exit_zero(self):
        # A-T05: a capture that exits 0 and claims "written" but leaves a
        # zero-byte file has not produced its output.
        with tempfile.TemporaryDirectory(dir=run.REPO_ROOT) as artifact_dir:
            artifact = os.path.join(artifact_dir, "captures", "ui.png")
            record = self.run_check(
                argv=[sys.executable, "-c",
                      "open(%r, 'wb').close(); print('[ikkoku] ui snapshot written to %s')"
                      % (artifact, artifact)],
                artifacts=[{"path": os.path.relpath(artifact, run.REPO_ROOT),
                            "kind": "ui-capture"}])
            self.assertEqual(record["exitCode"], 0)
            self.assertEqual(record["status"], "failed")
            self.assertIn("artifact is empty", record["error"])
            self.assertIsNone(record["artifacts"][0]["sha256"])

    def test_nonzero_capture_exit_fails_without_hashing_outputs(self):
        # A-T05: the app exits nonzero when a required output is missing
        # (here the PNG) even though another output (the report) was
        # written; the runner must not accept or hash that run's artifacts.
        with tempfile.TemporaryDirectory(dir=run.REPO_ROOT) as artifact_dir:
            report = os.path.join(artifact_dir, "captures", "ui.json")
            png = os.path.join(artifact_dir, "captures", "ui.png")
            record = self.run_check(
                argv=[sys.executable, "-c",
                      "import sys; open(%r, 'w').write('{}');"
                      "print('[ikkoku] ui snapshot failed: %s: could not be written');"
                      "sys.exit(1)" % (report, png)],
                artifacts=[{"path": os.path.relpath(png, run.REPO_ROOT), "kind": "ui-capture"},
                           {"path": os.path.relpath(report, run.REPO_ROOT),
                            "kind": "capture-report"}])
            self.assertEqual(record["status"], "failed")
            self.assertEqual(record["error"], "command exited 1")
            self.assertEqual(record["artifacts"], [])

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


SCENARIO_OPS = {"select", "setVisible", "rename", "toggleCamera", "toggleRoute",
                "undo", "redo", "newScene", "saveDocument", "loadDocument",
                "setFace", "setBody", "setColor", "resetShape", "resetColors", "setOutfit",
                "setClothesState", "setAccessoryVisible", "setAnimation", "setAnimationSpeed",
                "setForceLoop", "setFKEnabled", "setFK", "setPoseMode", "selectBone",
                "dragGizmo", "captureBone", "captureObject", "captureRender",
                "advance", "orbit", "setAutomaticBlink",
                "export", "reimport", "assert", "assertRejected"}

MAKER_SCENARIO_OPS = {"customization", "selectCoordinate", "setFace", "setBody",
                      "setColor", "resetShapes", "export", "reimport", "assert"}

# App settings that name a file the app is asked to write (A-T05).
APP_OUTPUT_VARIABLES = ("IKKOKU_AUTOCAPTURE", "IKKOKU_CAPTURE_UI", "IKKOKU_CAPTURE_UI_REPORT",
                        "IKKOKU_NATIVE_PLUGIN_REPORT", "IKKOKU_BENCHMARK_OUTPUT",
                        "IKKOKU_STUDIO_SCENARIO_REPORT", "IKKOKU_MAKER_SCENARIO_REPORT",
                        "IKKOKU_GAMEPLAY_SCENARIO_REPORT",
                        "IKKOKU_SAVE_CARD", "IKKOKU_SAVE_SCENE", "IKKOKU_EXPORT_SOURCE_CARD",
                        "IKKOKU_EXPORT_SOURCE_SCENE")


class AppOutputArtifactTests(unittest.TestCase):
    """A-T05: every output an app-smoke check requests is a hashed artifact.

    The app now exits nonzero when a required output is missing, but a lane
    check only fails on an absent (or empty) file it declares; an undeclared
    output could silently go missing behind a zero exit.
    """

    def app_smoke_checks(self):
        lanes = sorted(os.path.join(_HERE, "lanes", name)
                       for name in os.listdir(os.path.join(_HERE, "lanes"))
                       if name.endswith(".json"))
        for lane in lanes:
            for check in run.load_manifest(lane):
                if check["referenceTier"] == "app-smoke":
                    yield os.path.basename(lane), check

    def test_every_requested_app_output_is_a_declared_artifact(self):
        requested = 0
        for lane, check in self.app_smoke_checks():
            artifacts = [artifact["path"] for artifact in check.get("artifacts", [])]
            for name in APP_OUTPUT_VARIABLES:
                value = check.get("env", {}).get(name)
                if value is None:
                    continue
                requested += 1
                self.assertIn(value, artifacts, "%s/%s: %s=%s must be a declared artifact"
                              % (lane, check["id"], name, value))
        self.assertGreater(requested, 0)

    def test_ui_capture_hashes_both_png_and_report(self):
        checks = {check["id"]: check for lane, check in self.app_smoke_checks()
                  if lane == "app-smoke.json"}
        capture = checks["studio-inspector-capture"]
        artifacts = [artifact["path"] for artifact in capture["artifacts"]]
        self.assertTrue(capture["env"]["IKKOKU_CAPTURE_UI"].endswith(".png"))
        self.assertIn(capture["env"]["IKKOKU_CAPTURE_UI"], artifacts)
        self.assertIn(capture["env"]["IKKOKU_CAPTURE_UI_REPORT"], artifacts)

    def test_ui_capture_does_not_discover_a_maker_library(self):
        # The synthetic scene's minimal card exercises the source-pose inspector,
        # not assembled hair/clothes. A developer's optional library, found through
        # the source-tree fallback, made it import as no source character.
        checks = {check["id"]: check for lane, check in self.app_smoke_checks()
                  if lane == "app-smoke.json"}
        self.assertEqual(checks["studio-inspector-capture"]["env"].get("IKKOKU_MAKER_LIBRARY"), "none")

    def test_release_smoke_renders_with_the_optimized_app(self):
        # R6 (2026-10-23): every Release render crashed while the Debug lanes
        # passed, so app-smoke builds Release and renders one frame with it.
        order = [check["id"] for lane, check in self.app_smoke_checks() if lane == "app-smoke.json"]
        self.assertLess(order.index("build-release-app"), order.index("release-startup-capture"))
        checks = {check["id"]: check for lane, check in self.app_smoke_checks()
                  if lane == "app-smoke.json"}
        build = checks["build-release-app"]["argv"]
        self.assertEqual(build[build.index("-configuration") + 1], "Release")
        smoke = checks["release-startup-capture"]
        self.assertIn("/Release/Ikkoku.app/", smoke["argv"][0])
        self.assertEqual(smoke["env"].get("IKKOKU_SOURCE_TREE_FALLBACKS"), "0")
        self.assertTrue(smoke["env"]["IKKOKU_AUTOCAPTURE"].endswith(".png"))

    def test_capture_only_plugin_evidence_runs_inside_a_capture(self):
        # A06: the app rejects IKKOKU_NATIVE_PLUGIN_REPORT and IKKOKU_APPLICATION_FOCUS
        # without IKKOKU_AUTOCAPTURE, the capture that ends the headless run; before,
        # such a launch stayed open and the check could only time out.
        checked = 0
        for lane, check in self.app_smoke_checks():
            env = check.get("env", {})
            if "IKKOKU_NATIVE_PLUGIN_REPORT" in env or "IKKOKU_APPLICATION_FOCUS" in env:
                checked += 1
                self.assertIn("IKKOKU_AUTOCAPTURE", env, "%s/%s" % (lane, check["id"]))
        self.assertGreater(checked, 0)

    def test_each_app_check_selects_at_most_one_capture_mode(self):
        with open(CAPTURE_REQUEST_SOURCE, encoding="utf-8") as handle:
            selectors = re.findall(r'ModeSelector\("(IKKOKU_[A-Z0-9_]+)",', handle.read())
        self.assertIn("IKKOKU_CAPTURE_RIG", selectors)
        for lane, check in self.app_smoke_checks():
            names = set(check.get("env", {})) | {fixture["env"] for fixture in check.get("fixtures", [])}
            chosen = sorted(names.intersection(selectors))
            self.assertLessEqual(len(chosen), 1, "%s/%s selects %s" % (lane, check["id"], chosen))


CAPTURE_REQUEST_SOURCE = os.path.join(run.REPO_ROOT, "Packages", "Engine", "Sources", "Renderer",
                                      "CaptureRequest.swift")
CAPTURE_OUTPUT_SOURCE = os.path.join(run.REPO_ROOT, "Packages", "Engine", "Sources", "Renderer",
                                     "CaptureOutput.swift")
# Whole variable names; the capture prefixes such as "IKKOKU_CAPTURE_" end in "_".
IKKOKU_LITERAL = re.compile(r'"(IKKOKU_[A-Z0-9_]*[A-Z0-9])"')


def _ikkoku_literals(*paths):
    names = set()
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            names.update(IKKOKU_LITERAL.findall(handle.read()))
    return names


class CaptureRequestInventoryTests(unittest.TestCase):
    """A06: the startup capture check classifies every variable the app reads.

    `CaptureRequest.validate` rejects a capture option outside the modes that
    read it and an unknown `IKKOKU_CAPTURE_*` name, so an app variable missing
    from its inventory would be rejected or go unchecked. The Swift tests cover
    the rules; this keeps the inventory and the app's reads in step.
    """

    def app_variables(self):
        sources = []
        for root, _, files in os.walk(os.path.join(run.REPO_ROOT, "Apps", "IkkokuCreator")):
            sources.extend(os.path.join(root, name) for name in files if name.endswith(".swift"))
        self.assertTrue(sources)
        return _ikkoku_literals(*sources)

    def test_every_variable_the_app_reads_is_classified(self):
        # IKKOKU_CAPTURE_UI_TIMEOUT is the UICaptureReadiness constant in CaptureOutput.swift.
        inventory = _ikkoku_literals(CAPTURE_REQUEST_SOURCE, CAPTURE_OUTPUT_SOURCE)
        missing = sorted(self.app_variables() - inventory)
        self.assertEqual(missing, [], "add these to CaptureRequest's inventory: %s" % missing)

    def test_inventory_names_only_variables_the_app_reads(self):
        read = self.app_variables() | _ikkoku_literals(CAPTURE_OUTPUT_SOURCE)
        stale = sorted(_ikkoku_literals(CAPTURE_REQUEST_SOURCE) - read)
        self.assertEqual(stale, [], "the app no longer reads: %s" % stale)


class StudioScenarioLaneTests(unittest.TestCase):
    """The shipped studio-scenarios lane and its scenario files are well-formed.

    Only the manifest/scenario shape is checked here: the app run itself is
    the evidence, this test keeps the lane from shipping a scenario the hook
    cannot decode or an export path that escapes `.local/`.
    """

    LANE = os.path.join(_HERE, "lanes", "studio-scenarios.json")
    SCENARIO_DIR = os.path.join(_HERE, "scenarios")

    def setUp(self):
        with open(self.LANE, encoding="utf-8") as handle:
            self.checks = run.validate_manifest(json.load(handle))

    def scenario_files(self):
        # maker-*.json and gameplay-*.json belong to their own lanes, not this one.
        return sorted(name for name in os.listdir(self.SCENARIO_DIR)
                      if name.endswith(".json")
                      and not name.startswith(("maker-", "gameplay-")))

    def test_lane_validates_and_covers_every_scenario(self):
        self.assertEqual(len(self.checks), 45)
        referenced = set()
        for check in self.checks:
            scenario = check["env"]["IKKOKU_STUDIO_SCENARIO"]
            referenced.add(os.path.join(run.REPO_ROOT, scenario))
            self.assertTrue(os.path.isfile(os.path.join(run.REPO_ROOT, scenario)),
                            "lane names a missing scenario: %s" % scenario)
        self.assertEqual(sorted(os.path.basename(p) for p in referenced),
                         self.scenario_files(),
                         "a scenario file is not run by the lane, or the lane "
                         "names a scenario that is not in Tools/verification/scenarios")

    def test_scenario_reports_are_artifacts(self):
        for check in self.checks:
            report = check["env"]["IKKOKU_STUDIO_SCENARIO_REPORT"]
            self.assertTrue(report.startswith(".local/verification/"),
                            "report must stay under .local/verification: %s" % report)
            self.assertIn(report, [a["path"] for a in check.get("artifacts", [])],
                          "the scenario report must be a hashed artifact: %s" % check["id"])

    def test_each_check_declares_import_fixtures(self):
        for check in self.checks:
            with open(os.path.join(run.REPO_ROOT,
                                   check["env"]["IKKOKU_STUDIO_SCENARIO"]),
                      encoding="utf-8") as handle:
                steps = json.load(handle)["steps"]
            fixtures = {f["env"] for f in check.get("fixtures", [])}
            # A scenario whose first step is loadDocument runs in a process
            # that must never import (that is the point of the reload-load
            # half of a save/load pair): giving it IKKOKU_SOURCE_SCENE would
            # import the scene at startup and assert the import, not the
            # load. Every other scenario starts from an import.
            if steps[0]["op"] == "loadDocument":
                self.assertNotIn("IKKOKU_SOURCE_SCENE", fixtures,
                                 "a load-first scenario must start on an empty "
                                 "document, without an import fixture: %s" % check["id"])
            else:
                self.assertIn("IKKOKU_SOURCE_SCENE", fixtures)
            self.assertIn("IKKOKU_SOURCE_AVATAR", fixtures)

    def test_step_shape(self):
        for check in self.checks:
            path = os.path.join(run.REPO_ROOT, check["env"]["IKKOKU_STUDIO_SCENARIO"])
            with open(path, encoding="utf-8") as handle:
                steps = json.load(handle)["steps"]
            self.assertTrue(steps)
            for step in steps:
                op = step["op"]
                self.assertIn(op, SCENARIO_OPS, "unknown op in %s" % path)
                if op in ("setVisible",):
                    self.assertIsInstance(step["visible"], bool)
                if op == "rename":
                    self.assertTrue(step["name"])
                if op in ("setFace", "setBody"):
                    self.assertIsInstance(step["index"], int)
                    self.assertIsInstance(step["value"], float)
                if op == "setColor":
                    self.assertIsInstance(step["id"], str)
                    rgba = step["rgba"]
                    self.assertEqual(len(rgba), 4)
                    self.assertTrue(all(0 <= c <= 1 for c in rgba))
                if op == "resetShape":
                    self.assertIsInstance(step["key"], int)
                    self.assertIsInstance(step["face"], bool)
                if op == "resetColors":
                    self.assertIsInstance(step["key"], int)
                if op == "setOutfit":
                    self.assertIsInstance(step["key"], int)
                    self.assertIs(type(step["index"]), int)
                    if "errorContains" in step:
                        self.assertTrue(step["errorContains"], "a refused outfit needs a specific diagnostic")
                if op in ("setClothesState", "setAccessoryVisible"):
                    self.assertIsInstance(step["key"], int)
                    self.assertIs(type(step["index"]), int)
                    if op == "setClothesState":
                        self.assertIs(type(step["state"]), int)
                    else:
                        self.assertIsInstance(step["on"], bool)
                    if "errorContains" in step:
                        self.assertTrue(step["errorContains"], "a refused wear edit needs a specific diagnostic")
                    else:
                        self.assertIn(step["index"], range(8) if op == "setClothesState" else range(20))
                        if op == "setClothesState":
                            self.assertIn(step["state"], range(4))
                if op == "captureRender":
                    self.assertTrue(step["name"])
                    if "path" in step:
                        self.assertTrue(step["path"].startswith(".local/"))
                if op == "setAnimation":
                    for slot in ("group", "category", "no"):
                        self.assertIsInstance(step[slot], int)
                if op == "setAnimationSpeed":
                    self.assertIsInstance(step["speed"], float)
                if op == "setForceLoop":
                    self.assertIsInstance(step["on"], bool)
                if op in ("setFK", "captureBone"):
                    self.assertIsInstance(step["bone"], int)
                if op == "setFK":
                    self.assertEqual(len(step["rotation"]), 3)
                if op == "setPoseMode":
                    self.assertIn(step["mode"], ("object", "fk", "ik"))
                if op == "selectBone":
                    self.assertIsInstance(step["bone"], int)
                if op == "dragGizmo":
                    self.assertIsInstance(step["bone"], int)
                    self.assertIn(step["axis"], ("x", "y", "z"))
                    self.assertEqual(len(step["pixels"]), 2)
                    self.assertTrue(all(isinstance(c, (int, float)) for c in step["pixels"]))
                if op == "captureBone":
                    self.assertTrue(step["name"],
                                    "a captured bone needs a label to compare against: %s" % path)
                if op == "captureObject":
                    self.assertIsInstance(step["key"], int)
                    self.assertTrue(step["name"],
                                    "a captured object needs a label to compare against: %s" % path)
                if op in ("export", "reimport", "saveDocument", "loadDocument"):
                    self.assertTrue(step["path"].startswith(".local/"),
                                    "scene writes must stay under .local/: %s" % step["path"])
                if op in ("assert", "assertRejected"):
                    declared = [k for k in ("name", "visible", "face", "body", "color",
                                            "activeCamera", "routePlaying",
                                            "sourceRuntime", "animation", "fk", "position",
                                            "eyeLook", "blink", "handPattern",
                                            "diagnosticContains", "statusContains", "view", "render",
                                            "exportIdenticalToSource", "outfit", "clothes") if k in step]
                    self.assertTrue(declared, "assert declares nothing: %s" % path)
                    if op == "assertRejected":
                        self.assertTrue(step["errorContains"], "negative control needs a specific diagnostic")
                        self.assertEqual(len(declared), 1, "negative control must isolate one assertion")
                    if "exportIdenticalToSource" in step:
                        self.assertTrue(step["exportIdenticalToSource"].startswith(".local/"))
                    if "render" in step:
                        render = step["render"]
                        self.assertTrue(render["from"])
                        for bound in ("changedPixelsAtLeast", "changedPixelsAtMost", "maxChannelDeltaAtMost"):
                            if bound in render:
                                self.assertIs(type(render[bound]), int)
                        if op != "assertRejected":
                            self.assertTrue("changedPixelsAtLeast" in render or "changedPixelsAtMost" in render)
                            self.assertLessEqual(0, render.get("changedPixelsAtLeast", 0))
                            self.assertLessEqual(render.get("changedPixelsAtLeast", 0), render.get("changedPixelsAtMost", 512 * 512))
                            self.assertLessEqual(render.get("changedPixelsAtMost", 512 * 512), 512 * 512)
                            self.assertLessEqual(0, render.get("maxChannelDeltaAtMost", 255))
                            self.assertLessEqual(render.get("maxChannelDeltaAtMost", 255), 255)
                    if any(k in step for k in ("name", "visible", "face", "body", "color")):
                        self.assertIsInstance(step.get("key"), int,
                                              "object asserts need a source key")
                    if "color" in step:
                        self.assertEqual(len(step["color"]["rgba"]), 4)
                    if "outfit" in step:
                        outfit = step["outfit"]
                        self.assertIsInstance(outfit["key"], int)
                        self.assertTrue({"coordinate", "saved", "resolved", "missing"} & set(outfit),
                                        "an outfit assert must name what it checks: %s" % path)
                        for index in ("coordinate", "saved"):
                            if index in outfit:
                                self.assertIn(outfit[index], range(7))
                    if "position" in step:
                        self.assertIsInstance(step["position"]["key"], int)
                        self.assertTrue(step["position"]["from"])
                    if "view" in step:
                        # exactly one target: the saved camera or one camera object
                        view = step["view"]
                        self.assertEqual(len(view), 1, "a view assert names saved or key: %s" % path)
                        if "saved" in view:
                            self.assertIs(view["saved"], True)
                        else:
                            self.assertIsInstance(view["key"], int)
                    if "statusContains" in step:
                        self.assertTrue(step["statusContains"])
                    if "clothes" in step:
                        clothes = step["clothes"]
                        self.assertIsInstance(clothes["key"], int)
                        self.assertTrue({"state", "saved", "rendered", "accessories", "accessoriesOff",
                                         "edited", "fallbacks", "diagnosticContains"} & set(clothes),
                                        "a clothes assert must name what it checks: %s" % path)
                        for name in ("state", "saved"):
                            if name in clothes:
                                self.assertEqual(len(clothes[name]), 9)
                                self.assertTrue(all(v in range(4) for v in clothes[name]))
                        if "rendered" in clothes:
                            self.assertTrue(all(v in range(9) for v in clothes["rendered"]))
                        for name in ("accessories", "accessoriesOff"):
                            if name in clothes:
                                self.assertTrue(all(v in range(20) for v in clothes[name]))
                    for slot in ("face", "body"):
                        if slot in step:
                            self.assertIsInstance(step[slot]["index"], int)

    def test_every_scenario_round_trips_through_export_and_reimport(self):
        for check in self.checks:
            path = os.path.join(run.REPO_ROOT, check["env"]["IKKOKU_STUDIO_SCENARIO"])
            with open(path, encoding="utf-8") as handle:
                steps = json.load(handle)["steps"]
            ops = [step["op"] for step in steps]
            # Every checklist must round-trip its state through a file and
            # verify it again: the original-format pair (export → reimport)
            # for all ST-T03/T04/T15 scenarios, or the native document-card
            # pair (saveDocument → loadDocument) for the ST-T01 reload
            # scenarios, whose load side is a SEPARATE load-first check.
            if "saveDocument" in ops or "loadDocument" in ops:
                self.assertNotIn("export", ops,
                                 "a save/load scenario must not mix in the "
                                 "original-format round trip: %s" % path)
                if "loadDocument" in ops:
                    self.assertEqual(ops[0], "loadDocument",
                                     "a load scenario must start on an empty "
                                     "document: %s" % path)
                if "saveDocument" in ops:
                    # The companion check must exist and be the lane's NEXT
                    # check after this one (lane order is the run order).
                    saved = check["id"]
                    self.assertTrue(saved.startswith("studio-scenario-reload-save-")
                                    and saved.endswith(("props", "camera", "route", "outfit", "clothes")),
                                    "save scenarios are the reload pairs: %s" % saved)
                    index = [c["id"] for c in self.checks].index(saved)
                    partner = self.checks[index + 1]["env"]["IKKOKU_STUDIO_SCENARIO"]
                    with open(os.path.join(run.REPO_ROOT, partner), encoding="utf-8") as handle:
                        partner_ops = [s["op"] for s in json.load(handle)["steps"]]
                    self.assertIn("loadDocument", partner_ops,
                                  "the check after %s must load what it saved: %s"
                                  % (saved, partner))
            else:
                self.assertIn("export", ops, "export is the point of the checklist: %s" % path)
                self.assertIn("reimport", ops)
                self.assertGreater(ops.index("reimport"), ops.index("export"))
            self.assertEqual(ops[-1], "assert",
                             "the last step must verify the reloaded state: %s" % path)

    def test_synthetic_motion_checks_do_not_discover_a_maker_library(self):
        # These minimal cards exercise blink/hand playback, not assembled
        # hair/clothes. A developer's optional library must not change import.
        checks = {check["id"]: check for check in self.checks}
        for name in ("blink-toggle", "hand-patterns", "hand-patterns-kept"):
            self.assertEqual(checks["studio-scenario-" + name]["env"].get("IKKOKU_MAKER_LIBRARY"),
                             "none")

    def test_visual_reset_controls_keep_clock_and_camera_fixed(self):
        checks = {check["id"]: check for check in self.checks}
        for name in ("shape-visual-reset", "color-visual-reset", "outfit-select",
                     "clothes-saved-off", "clothes-toggle", "accessory-toggle"):
            self.assertIn({"env": "IKKOKU_MAKER_LIBRARY", "kind": "file"},
                          checks["studio-scenario-" + name]["fixtures"],
                          "visual evidence must hash its selected assembly catalog")
            with open(os.path.join(self.SCENARIO_DIR, name + ".json"), encoding="utf-8") as handle:
                steps = json.load(handle)["steps"]
            self.assertFalse({"advance", "orbit", "toggleCamera", "setAnimation"} &
                             {step["op"] for step in steps},
                             "visual differences and export identity must isolate edits at a fixed time/camera")
            self.assertTrue(any(step["op"] == "assert" and "exportIdenticalToSource" in step
                                for step in steps), "restored export needs a positive identity control")
            rejected = next(i for i, step in enumerate(steps)
                            if step["op"] == "assertRejected" and "exportIdenticalToSource" in step)
            output = steps[rejected]["exportIdenticalToSource"]
            self.assertTrue(any(step["op"] == "reimport" and step["path"] == output
                                for step in steps[:rejected]),
                            "changed-export control must run after reimport to catch self-comparison")


class MakerScenarioLaneTests(unittest.TestCase):
    """The shipped maker-scenarios lane and its scenario files are well-formed.

    Same contract as the studio lane: only the manifest/scenario shape is
    checked here; the app run is the evidence. This keeps the lane from
    shipping a scenario the Maker hook cannot decode or a card write that
    escapes `.local/`.
    """

    LANE = os.path.join(_HERE, "lanes", "maker-scenarios.json")
    SCENARIO_DIR = os.path.join(_HERE, "scenarios")

    def setUp(self):
        with open(self.LANE, encoding="utf-8") as handle:
            self.checks = run.validate_manifest(json.load(handle))

    def scenario_files(self):
        return sorted(name for name in os.listdir(self.SCENARIO_DIR)
                      if name.endswith(".json") and name.startswith("maker-"))

    def test_lane_validates_and_covers_every_maker_scenario(self):
        self.assertEqual(len(self.checks), 4)
        referenced = set()
        for check in self.checks:
            scenario = check["env"]["IKKOKU_MAKER_SCENARIO"]
            referenced.add(os.path.basename(scenario))
            self.assertTrue(os.path.isfile(os.path.join(run.REPO_ROOT, scenario)),
                            "lane names a missing scenario: %s" % scenario)
        self.assertEqual(sorted(referenced), self.scenario_files(),
                         "a maker-*.json scenario is not run by the lane, or "
                         "the lane names a scenario that is not in "
                         "Tools/verification/scenarios")

    def test_scenario_reports_are_artifacts(self):
        for check in self.checks:
            report = check["env"]["IKKOKU_MAKER_SCENARIO_REPORT"]
            self.assertTrue(report.startswith(".local/verification/"),
                            "report must stay under .local/verification: %s" % report)
            self.assertIn(report, [a["path"] for a in check.get("artifacts", [])],
                          "the scenario report must be a hashed artifact: %s" % check["id"])

    def test_each_check_declares_import_fixtures(self):
        for check in self.checks:
            fixtures = {f["env"] for f in check.get("fixtures", [])}
            self.assertIn("IKKOKU_SOURCE_CARD", fixtures)
            self.assertIn("IKKOKU_SOURCE_AVATAR", fixtures)

    def test_step_shape(self):
        for check in self.checks:
            path = os.path.join(run.REPO_ROOT, check["env"]["IKKOKU_MAKER_SCENARIO"])
            with open(path, encoding="utf-8") as handle:
                steps = json.load(handle)["steps"]
            self.assertTrue(steps)
            for step in steps:
                op = step["op"]
                self.assertIn(op, MAKER_SCENARIO_OPS, "unknown op in %s" % path)
                if op == "customization":
                    self.assertIsInstance(step["on"], bool)
                if op == "selectCoordinate":
                    self.assertIsInstance(step["index"], int)
                if op in ("setFace", "setBody"):
                    self.assertIsInstance(step["index"], int)
                    self.assertIsInstance(step["value"], float)
                if op == "setColor":
                    self.assertIsInstance(step["id"], str)
                    rgba = step["rgba"]
                    self.assertEqual(len(rgba), 4)
                    self.assertTrue(all(0 <= c <= 1 for c in rgba))
                if op in ("export", "reimport"):
                    self.assertTrue(step["path"].startswith(".local/"),
                                    "card writes must stay under .local/: %s" % step["path"])
                if op == "assert":
                    declared = [k for k in ("coordinate", "face", "body", "color",
                                            "colorApplied",
                                            "diagnosticContains") if k in step]
                    self.assertTrue(declared, "assert declares nothing: %s" % path)
                    if "coordinate" in step:
                        self.assertIsInstance(step["coordinate"], int)
                    if "color" in step:
                        self.assertEqual(len(step["color"]["rgba"]), 4)
                    for slot in ("face", "body"):
                        if slot in step:
                            self.assertIsInstance(step[slot]["index"], int)

    def test_every_scenario_round_trips_through_export_and_reimport(self):
        for check in self.checks:
            path = os.path.join(run.REPO_ROOT, check["env"]["IKKOKU_MAKER_SCENARIO"])
            with open(path, encoding="utf-8") as handle:
                steps = json.load(handle)["steps"]
            ops = [step["op"] for step in steps]
            self.assertIn("export", ops, "export is the point of the checklist: %s" % path)
            self.assertIn("reimport", ops)
            self.assertGreater(ops.index("reimport"), ops.index("export"))
            self.assertEqual(ops[-1], "assert",
                             "the last step must verify the reloaded card: %s" % path)


GAMEPLAY_SCENARIO_OPS = ("perform", "run", "reload", "assert")
GAMEPLAY_OPERATIONS = ("nextPeriod", "changePeriod", "changeWeek", "nextWeek",
                       "reloadNightMenuWeek", "completeNightMenu", "beginMapMove",
                       "finishMapMove")
GAMEPLAY_RUN_CONDITIONS = ("idle", "eventRunning", "mapLoading", "barrier")


class GameplayScenarioLaneTests(unittest.TestCase):
    """A-T01: the gameplay-scenarios lane and its scenario files are well-formed.

    The Engine test `sourceGameplayHostShippedScenarioPersistsReloadsAndResumesIdentically`
    runs the same scenario in CI; the lane runs it through the built app on the
    Mac. This keeps the lane from shipping a scenario the hook cannot decode, a
    snapshot or report outside `.local/`, or an undeclared output.
    """

    LANE = os.path.join(_HERE, "lanes", "gameplay-scenarios.json")
    SCENARIO_DIR = os.path.join(_HERE, "scenarios")

    def setUp(self):
        with open(self.LANE, encoding="utf-8") as handle:
            self.checks = run.validate_manifest(json.load(handle))

    def scenario(self, check):
        with open(os.path.join(run.REPO_ROOT, check["env"]["IKKOKU_GAMEPLAY_SCENARIO"]),
                  encoding="utf-8") as handle:
            return json.load(handle)

    def test_lane_validates_and_covers_every_gameplay_scenario(self):
        self.assertEqual(len(self.checks), 1)
        referenced = set()
        for check in self.checks:
            self.assertEqual(check["referenceTier"], "app-smoke")
            self.assertEqual(check.get("fixtures", []), [],
                             "the controlled catalog is synthetic: %s" % check["id"])
            scenario = check["env"]["IKKOKU_GAMEPLAY_SCENARIO"]
            referenced.add(os.path.basename(scenario))
            self.assertTrue(os.path.isfile(os.path.join(run.REPO_ROOT, scenario)),
                            "lane names a missing scenario: %s" % scenario)
        files = sorted(name for name in os.listdir(self.SCENARIO_DIR)
                       if name.endswith(".json") and name.startswith("gameplay-"))
        self.assertEqual(sorted(referenced), files)

    def test_report_and_snapshots_are_local_artifacts(self):
        for check in self.checks:
            artifacts = [a["path"] for a in check.get("artifacts", [])]
            report = check["env"]["IKKOKU_GAMEPLAY_SCENARIO_REPORT"]
            self.assertTrue(report.startswith(".local/verification/"))
            self.assertIn(report, artifacts)
            paths = [step["path"] for step in self.scenario(check)["steps"]
                     if step["op"] == "reload" and "path" in step]
            self.assertTrue(paths)
            for path in paths:
                self.assertTrue(path.startswith(".local/verification/"),
                                "snapshots must stay under .local/verification: %s" % path)
                self.assertIn(path, artifacts, "snapshot must be a hashed artifact: %s" % path)

    def test_step_shape(self):
        for check in self.checks:
            scenario = self.scenario(check)
            self.assertEqual(scenario["schemaVersion"], 1)
            catalog = scenario["catalog"]
            self.assertEqual(catalog["schemaVersion"], 1)
            self.assertIn(scenario["start"]["map"], catalog["mapNumbers"])
            maps = set(catalog["mapNumbers"])
            for step in scenario["steps"]:
                op = step["op"]
                self.assertIn(op, GAMEPLAY_SCENARIO_OPS)
                if op == "perform":
                    self.assertIn(step["operation"], GAMEPLAY_OPERATIONS)
                if op == "run":
                    self.assertIn(step.get("until", "idle"), GAMEPLAY_RUN_CONDITIONS)
                if op == "assert":
                    declared = [k for k in ("period", "week", "savedWeek", "activeMap",
                                            "completedEvents", "runningEvent", "idle")
                                if k in step]
                    self.assertTrue(declared, "assert declares nothing")
                    if "activeMap" in step:
                        self.assertIn(step["activeMap"], maps)

    def test_scenario_reloads_mid_event_and_ends_verified(self):
        for check in self.checks:
            steps = self.scenario(check)["steps"]
            ops = [step["op"] for step in steps]
            self.assertEqual(ops[-1], "assert")
            # A reload while the event's map loads and one while a barrier is held.
            stops = [steps[i - 1].get("until") for i, op in enumerate(ops)
                     if op == "reload" and i > 0]
            self.assertIn("mapLoading", stops)
            self.assertIn("barrier", stops)
            self.assertGreater(len(ops) - 1 - ops[::-1].index("reload"), ops.index("perform"))


if __name__ == "__main__":
    unittest.main()
