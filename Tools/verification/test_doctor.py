"""Unit tests for the developer prerequisite checker (T-T01).

Stdlib only. Version parsing is checked against the sample outputs in
doctor-samples.json; environment checks use injected resolvers/runners, so
the only real processes started are the running interpreter and a lookup
of a nonexistent path. Run from the repository root with:
    python3 -m unittest discover -s Tools/verification -p 'test_*.py'
"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))

_spec = importlib.util.spec_from_file_location(
    "ikkoku_verification_doctor", os.path.join(_HERE, "doctor.py"))
doctor = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(doctor)

with open(os.path.join(_HERE, "doctor-samples.json"), encoding="utf-8") as _handle:
    SAMPLES = {sample["id"]: sample for sample in json.load(_handle)["samples"]}

PREREQUISITES = doctor.load_prerequisites()
PUBLIC = ["app-build", "metal-shaders", "engine-tests", "python-tests", "translation-frontend"]
APPLE_SILICON = SAMPLES["host-apple-silicon"]["host"]
LINUX = SAMPLES["host-linux-container"]["host"]


def sample_probe(sample):
    if sample.get("absent"):
        return {"path": None, "argv": None, "returncode": None, "output": None, "error": sample["error"]}
    return {"path": "/fake/" + sample["tool"], "argv": ["/fake/" + sample["tool"], "--version"],
            "returncode": sample["returncode"], "output": sample["output"], "error": None}


def fake_resolver(candidate):
    """Every candidate resolves to a distinct fake path."""
    return "/fake/" + candidate.strip("$/").replace("/", "_")


def runner_from_samples(choices, packages):
    """A runner answering each fake executable with a recorded sample."""
    def run(argv):
        if "-c" in argv:
            version = packages.get(argv[-1])
            return (0, version + "\n") if version else (doctor.PACKAGE_MISSING_EXIT, "")
        sample = SAMPLES[choices[argv[0]]]
        return sample["returncode"], sample["output"]
    return run


GOOD_RUNNER = runner_from_samples({
    "/fake/xcodebuild": "xcodebuild-ci-26.6",
    "/fake/xcrun": "metal-installed",
    "/fake/swift": "swift-ci-6.3.3",
    "/fake/python3": "python3-ci-3.15.0",
    "/fake/dotnet": "dotnet-sdks-8-9-10",
    "/fake/.local_reverse_unitypy-venv_bin_python": "reverse-python-3.12",
    "/fake/opt_homebrew_bin_python3": "python3-ci-3.15.0",
    "/fake/Applications_Blender.app_Contents_MacOS_Blender": "blender-5.1",
    "/fake/.local_reverse_tools_ilspycmd": "ilspycmd-11.1",
    "/fake/.local_reverse_tools-compat_ilspycmd": "ilspycmd-compat-9.1",
    "/fake/prlctl": "prlctl",
}, {"UnityPy": "1.23.0", "numpy": "2.2.6", "msgpack": "1.1.2", "Pillow": "11.3.0"})


def run_main(argv, **options):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stderr(err):
        code = doctor.main(argv, out=out, **options)
    return code, out.getvalue() + err.getvalue()


class SampleOutputTests(unittest.TestCase):
    def test_every_sample_evaluates_as_expected(self):
        for sample_id, sample in SAMPLES.items():
            with self.subTest(sample_id):
                tool = PREREQUISITES["tools"][sample["tool"]]
                if tool["probe"] == "host":
                    record = doctor.evaluate_host(tool, sample["host"])
                else:
                    record = doctor.evaluate(tool, sample_probe(sample))
                for key, value in sample["expect"].items():
                    self.assertEqual(record[key], value, key)

    def test_samples_cover_each_probe_and_absent_tools(self):
        parsers = {PREREQUISITES["tools"][s["tool"]].get("parser") for s in SAMPLES.values()}
        for parser in doctor.PARSERS:
            self.assertIn(parser, parsers)
        for tool_id in ("xcode", "swift", "metal", "dotnet-sdk", "python3", "blender"):
            self.assertTrue(any(s["tool"] == tool_id for s in SAMPLES.values()), tool_id)
        self.assertTrue(any(s.get("absent") for s in SAMPLES.values()))

    def test_samples_state_their_provenance(self):
        for sample_id, sample in SAMPLES.items():
            with self.subTest(sample_id):
                self.assertRegex(sample["provenance"], r"^(recorded|format sample): \S")

    def test_recorded_ci_versions_match_observed_entries(self):
        tools = PREREQUISITES["tools"]
        self.assertIn("26.6 (17F113)", " ".join(tools["xcode"]["observed"]))
        self.assertIn("6.3.3", " ".join(tools["swift"]["observed"]))
        self.assertIn("3.15.0", " ".join(tools["python3"]["observed"]))
        self.assertIn("32023.883", " ".join(tools["metal"]["observed"]))
        self.assertIn("newest 10.0.401", " ".join(tools["dotnet-sdk"]["observed"]))
        self.assertIn("macOS 26.6.2 arm64", " ".join(tools["host"]["observed"]))


class VersionTests(unittest.TestCase):
    def check(self, version, requirement, expected):
        self.assertEqual(doctor.satisfies(version, doctor.parse_requirement(requirement)), expected,
                         "%s %s" % (version, requirement))

    def test_minimum(self):
        self.check("26.0", ">=26", True)
        self.check("26.6", ">=26", True)
        self.check("27.0.1", ">=26", True)
        self.check("16.4", ">=26", False)
        self.check("6.0", ">=6.0", True)
        self.check("5.10", ">=6.0", False)
        self.check("10.0.100-rc.2.25502.107", ">=10.0", True)
        self.check("10.0.0-preview.1", ">=10.0", False)

    def test_series(self):
        self.check("3.12", "3.12.*", True)
        self.check("3.12.11", "3.12.*", True)
        self.check("3.13.0", "3.12.*", False)
        self.check("3.1.2", "3.12.*", False)
        self.check("5.1.0", "5.1.*", True)
        self.check("5.10.0", "5.1.*", False)

    def test_exact(self):
        self.check("11.1.0.9782", "==11.1.0.9782", True)
        self.check("1.23", "==1.23.0", True)
        self.check("1.23.0rc1", "==1.23.0", False)
        self.check("11.1.0.9783", "==11.1.0.9782", False)

    def test_requirement_grammar(self):
        self.assertEqual(doctor.parse_requirement("unrecorded")["kind"], "unrecorded")
        for bad in ("", ">26", "~=1.0", "==x", "3.*.*", None):
            with self.subTest(bad):
                with self.assertRaises(doctor.PrerequisiteError):
                    doctor.parse_requirement(bad)

    def test_dotnet_reports_the_highest_satisfying_sdk(self):
        tool = PREREQUISITES["tools"]["dotnet-sdk"]
        record = doctor.evaluate(tool, {"path": "/fake/dotnet", "argv": [], "returncode": 0, "error": None,
                                        "output": "10.0.100 [/a]\n9.0.101 [/a]\n"})
        self.assertEqual((record["status"], record["version"]), ("ok", "10.0.100"))
        record = doctor.evaluate(tool, {"path": "/fake/dotnet", "argv": [], "returncode": 0, "error": None,
                                        "output": "10.0.100 [/a]\n10.0.100-rc.2.1 [/a]\n"})
        self.assertEqual(record["version"], "10.0.100")


class PrerequisitesFileTests(unittest.TestCase):
    def test_public_tier_is_what_ci_builds_and_tests(self):
        public = [c["id"] for c in PREREQUISITES["capabilities"] if c["tier"] == "public"]
        self.assertEqual(public, PUBLIC)

    def test_every_public_lane_program_belongs_to_a_public_tool(self):
        with open(os.path.join(_HERE, "lanes", "public.json"), encoding="utf-8") as handle:
            programs = {check["argv"][0] for check in json.load(handle)["checks"]}
        public_tools = {tid for c in PREREQUISITES["capabilities"] if c["tier"] == "public" for tid in c["toolIds"]}
        candidates = {cand for tid in public_tools for cand in PREREQUISITES["tools"][tid].get("candidates", [])}
        self.assertEqual(programs - candidates, set())

    def test_stated_versions_match_the_prerequisites_file(self):
        for tool in PREREQUISITES["tools"].values():
            for stated in tool["statedIn"]:
                phrase = doctor.stated_phrase(tool, stated)
                with self.subTest(tool=tool["id"], path=stated["path"]):
                    with open(os.path.join(_REPO, stated["path"]), encoding="utf-8") as handle:
                        self.assertIn(phrase, handle.read())

    def test_build_guide_table_is_generated_from_the_file(self):
        with open(os.path.join(_REPO, doctor.DOC_PATH), encoding="utf-8") as handle:
            block = doctor.extract_doc_block(handle.read())
        self.assertIsNotNone(block, "generated block missing from %s" % doctor.DOC_PATH)
        self.assertEqual(block, doctor.render_markdown(PREREQUISITES),
                         "regenerate with: python3 Tools/verification/doctor.py --markdown")

    def test_reverse_packages_come_from_requirements_txt(self):
        pins = doctor.read_requirements_file("Tools/reverse/requirements.txt")
        tools = PREREQUISITES["tools"]
        self.assertTrue(pins)
        for name, version in pins:
            tool = tools["reverse-packages:" + name.lower()]
            self.assertEqual((tool["distribution"], tool["requirement"]), (name, "==" + version))
        reverse = next(c for c in PREREQUISITES["capabilities"] if c["id"] == "reverse-tools")
        self.assertEqual(reverse["toolIds"][1:], ["reverse-packages:" + name.lower() for name, _ in pins])

    def test_probes_pass_no_data_paths(self):
        # The checker must never read private data: probes run only version
        # flags, and repository-relative executables are the documented
        # tool locations, not data inputs.
        tool_dirs = (".local/reverse/unitypy-venv/bin/", ".local/reverse/tools/", ".local/reverse/tools-compat/")
        for tool in PREREQUISITES["tools"].values():
            with self.subTest(tool["id"]):
                for argument in tool.get("argv", [])[1:]:
                    self.assertTrue(argument.startswith("-") or argument.isalpha(), argument)
                for candidate in tool.get("candidates", []):
                    if candidate.startswith(".") or (not candidate.startswith(("/", "$")) and "/" in candidate):
                        self.assertTrue(candidate.startswith(tool_dirs), candidate)

    def write(self, data):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        with handle:
            json.dump(data, handle)
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def base(self):
        with open(doctor.PREREQUISITES, encoding="utf-8") as handle:
            return json.load(handle)

    def test_invalid_files_are_rejected(self):
        cases = {}
        data = self.base(); data["schemaVersion"] = 2; cases["schema"] = data
        data = self.base(); data["capabilities"][0]["tools"].append("nope"); cases["unknown tool"] = data
        data = self.base(); data["capabilities"][0]["tier"] = "private"; cases["tier"] = data
        data = self.base(); data["tools"][1]["requirement"] = "~=26"; cases["requirement"] = data
        data = self.base(); data["tools"][1]["parser"] = "guess"; cases["parser"] = data
        data = self.base(); data["tools"][2]["id"] = "xcode"; cases["duplicate"] = data
        data = self.base(); data["tools"][1]["statedIn"].append({"path": "missing.md", "phrase": "x"}); cases["path"] = data
        data = self.base(); data["tools"][2]["statedIn"] = [{"path": "README.md", "phrase": "metal {version}"}]
        cases["unrecorded stated"] = data
        for name, data in cases.items():
            with self.subTest(name):
                with self.assertRaises(doctor.PrerequisiteError):
                    doctor.load_prerequisites(self.write(data))
                code, _ = run_main(["--prerequisites", self.write(data)])
                self.assertEqual(code, 2)


class CheckEnvironmentTests(unittest.TestCase):
    def test_complete_environment_meets_every_capability(self):
        code, text = run_main(["--require", "all"], resolver=fake_resolver, runner=GOOD_RUNNER,
                              host=APPLE_SILICON, environ={})
        self.assertEqual(code, 0, text)
        self.assertIn("all 9 selected capabilities met", text)

    def test_absent_tools_exit_zero_without_require(self):
        code, text = run_main([], resolver=lambda candidate: None, host=LINUX, environ={})
        self.assertEqual(code, 0)
        self.assertIn("public: 0/5 capabilities met", text)
        self.assertIn("fix: Install Xcode 26", text)

    def test_require_public_fails_only_for_public_gaps(self):
        def resolver(candidate):
            return None if candidate in ("dotnet",) or candidate.startswith(".local") else fake_resolver(candidate)
        code, text = run_main(["--require", "public", "--json"], resolver=resolver, runner=GOOD_RUNNER,
                              host=APPLE_SILICON, environ={})
        report = json.loads(text)
        self.assertEqual(code, 1)
        self.assertEqual(report["required"], PUBLIC)
        self.assertEqual(report["unmetRequired"], ["translation-frontend"])
        code, _ = run_main(["--require", "app-build,engine-tests", "--require", "python-tests"],
                           resolver=resolver, runner=GOOD_RUNNER, host=APPLE_SILICON, environ={})
        self.assertEqual(code, 0)

    def test_unknown_selection_or_override_exits_two(self):
        self.assertEqual(run_main(["--require", "everything"], resolver=lambda c: None, host=LINUX)[0], 2)
        self.assertEqual(run_main(["--tool", "nope=/x"], resolver=lambda c: None, host=LINUX)[0], 2)
        self.assertEqual(run_main(["--tool", "assets-numpy=/x"], resolver=lambda c: None, host=LINUX)[0], 2)
        self.assertEqual(run_main(["--tool", "xcode"], resolver=lambda c: None, host=LINUX)[0], 2)

    def test_environment_variable_candidate_is_used_exclusively_when_set(self):
        def resolver(candidate):
            return None if candidate == "/custom/blender" else fake_resolver(candidate)
        results = doctor.check_environment(PREREQUISITES, environ={"BLENDER": "/custom/blender"},
                                           resolver=resolver, runner=GOOD_RUNNER, host=APPLE_SILICON)
        record = results["tools"]["blender"]
        self.assertEqual(record["status"], "absent")
        self.assertEqual(record["detail"], "BLENDER=/custom/blender is not an executable")
        results = doctor.check_environment(PREREQUISITES, environ={}, resolver=fake_resolver,
                                           runner=GOOD_RUNNER, host=APPLE_SILICON)
        self.assertEqual(results["tools"]["blender"]["status"], "ok")
        self.assertEqual(results["tools"]["blender"]["path"], "/fake/Applications_Blender.app_Contents_MacOS_Blender")

    def test_tool_override_replaces_candidates(self):
        seen = []

        def runner(argv):
            seen.append(argv)
            return GOOD_RUNNER(argv) if argv[0] != "/fake/python3.12" else (0, "Python 3.12.4\n")
        results = doctor.check_environment(PREREQUISITES, overrides={"reverse-python": "python3.12"},
                                           environ={}, resolver=fake_resolver, runner=runner, host=APPLE_SILICON)
        self.assertEqual(results["tools"]["reverse-python"]["version"], "3.12.4")
        package_runs = [argv for argv in seen if "-c" in argv and argv[-1] == "UnityPy"]
        self.assertEqual([argv[0] for argv in package_runs], ["/fake/python3.12"])

    def test_package_probe_skips_an_absent_interpreter(self):
        def resolver(candidate):
            return None if candidate.startswith(".local/reverse/unitypy") else fake_resolver(candidate)
        results = doctor.check_environment(PREREQUISITES, environ={}, resolver=resolver,
                                           runner=GOOD_RUNNER, host=APPLE_SILICON)
        record = results["tools"]["reverse-packages:unitypy"]
        self.assertEqual((record["status"], record["detail"]), ("absent", "interpreter reverse-python is absent"))

    def test_runner_failures_are_reported(self):
        def runner(argv):
            if argv[0] == "/fake/xcodebuild":
                raise subprocess.TimeoutExpired(argv, doctor.PROBE_TIMEOUT)
            if argv[0] == "/fake/swift":
                raise FileNotFoundError(argv[0])
            if argv[0] == "/fake/xcrun":
                raise PermissionError("denied")
            return GOOD_RUNNER(argv)
        results = doctor.check_environment(PREREQUISITES, environ={}, resolver=fake_resolver,
                                           runner=runner, host=APPLE_SILICON)
        self.assertEqual(results["tools"]["xcode"]["status"], "error")
        self.assertIn("timed out", results["tools"]["xcode"]["detail"])
        self.assertEqual(results["tools"]["swift"]["status"], "absent")
        self.assertEqual(results["tools"]["metal"]["status"], "error")

    def test_verbose_text_shows_probe_output(self):
        code, text = run_main(["--verbose"], resolver=fake_resolver, runner=GOOD_RUNNER,
                              host=APPLE_SILICON, environ={})
        self.assertEqual(code, 0)
        self.assertIn("ran: /fake/xcodebuild -version", text)
        self.assertIn("| Build version 17F113", text)
        # Swift serves two capabilities; its raw output is printed once.
        self.assertEqual(text.count("| Target: arm64-apple-macosx26.0"), 1)
        self.assertIn("ran: (output shown above)", text)
        self.assertIn('-c "importlib.metadata.version(\'UnityPy\')"', text)

    def test_markdown_probes_nothing(self):
        def runner(argv):
            raise AssertionError("--markdown must not probe: %s" % argv)
        code, text = run_main(["--markdown"], resolver=fake_resolver, runner=runner, host=APPLE_SILICON)
        self.assertEqual(code, 0)
        self.assertEqual(text, doctor.render_markdown(PREREQUISITES))


class RealProcessTests(unittest.TestCase):
    """The default resolver/runner against the running interpreter only."""

    def test_running_interpreter_version_is_parsed(self):
        code, output = doctor.default_runner([sys.executable, "--version"])
        versions, _ = doctor.parse_python(output)
        self.assertEqual(code, 0)
        self.assertEqual(len(versions), 1, output)
        self.assertTrue(versions[0].startswith("%d.%d." % sys.version_info[:2]), output)

    def test_package_script_reports_missing_distribution(self):
        code, _ = doctor.default_runner([sys.executable, "-c", doctor.PACKAGE_SCRIPT, "ikkoku-no-such-dist"])
        self.assertEqual(code, doctor.PACKAGE_MISSING_EXIT)

    def test_nonexistent_executable_is_absent(self):
        self.assertIsNone(doctor.default_resolver("/nonexistent/ikkoku-doctor-tool"))
        self.assertIsNone(doctor.default_resolver(".local/reverse/tools/ikkoku-no-such-tool"))
        self.assertIsNone(doctor.default_resolver("ikkoku-doctor-no-such-command"))
        probe = doctor.probe_command(["/nonexistent/ikkoku-doctor-tool", "--version"],
                                     "/nonexistent/ikkoku-doctor-tool", doctor.default_runner)
        record = doctor.evaluate(PREREQUISITES["tools"]["xcode"], probe)
        self.assertEqual(record["status"], "absent")


if __name__ == "__main__":
    unittest.main()
