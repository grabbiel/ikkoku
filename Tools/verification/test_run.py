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
                "setFace", "setBody", "setColor", "setAnimation", "setAnimationSpeed",
                "setForceLoop", "setFKEnabled", "setFK", "captureBone",
                "advance", "orbit", "setAutomaticBlink",
                "export", "reimport", "assert"}

MAKER_SCENARIO_OPS = {"customization", "selectCoordinate", "setFace", "setBody",
                      "setColor", "resetShapes", "export", "reimport", "assert"}


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
        # maker-*.json belongs to the maker-scenarios lane, not this one.
        return sorted(name for name in os.listdir(self.SCENARIO_DIR)
                      if name.endswith(".json") and not name.startswith("maker-"))

    def test_lane_validates_and_covers_every_scenario(self):
        self.assertEqual(len(self.checks), 29)
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
                if op == "captureBone":
                    self.assertTrue(step["name"],
                                    "a captured bone needs a label to compare against: %s" % path)
                if op in ("export", "reimport", "saveDocument", "loadDocument"):
                    self.assertTrue(step["path"].startswith(".local/"),
                                    "scene writes must stay under .local/: %s" % step["path"])
                if op == "assert":
                    declared = [k for k in ("name", "visible", "face", "body", "color",
                                            "activeCamera", "routePlaying",
                                            "sourceRuntime", "animation", "fk",
                                            "eyeLook", "blink", "handPattern",
                                            "diagnosticContains") if k in step]
                    self.assertTrue(declared, "assert declares nothing: %s" % path)
                    if any(k in step for k in ("name", "visible", "face", "body", "color")):
                        self.assertIsInstance(step.get("key"), int,
                                              "object asserts need a source key")
                    if "color" in step:
                        self.assertEqual(len(step["color"]["rgba"]), 4)
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
                                    and saved.endswith(("props", "camera", "route")),
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


if __name__ == "__main__":
    unittest.main()
