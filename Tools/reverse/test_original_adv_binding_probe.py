"""ADV binding probe driver: case encoding, exec splitting and TSV comparison helpers.
Synthetic data only; no VM call is made."""
import base64, gzip, hashlib, re, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import original_adv_binding_probe as probe

ROOT = r"C:\Temp\IkkokuADVBindingProbe-" + "a" * 32
cmd = probe.command
TABLES = dict(callDefaultID=7, voiceNumbers=[0], callNames=dict(c00=[
    dict(name="A", id=7, category=2, bundle="b"), dict(name="B", id=1, category=2, bundle="b"), dict(name="C", id=3, category=0, bundle="b")]))
LIBRARY = {"301": [cmd(3, "H_intimacy", "1", "4", multi=True), cmd(4, "H_intimacy", "H_intimacy", "0", "100"),
                   cmd(165, "H_intimacy", "H_intimacy")]}


def unwrap(wrapper):
    encoded = re.search(r"FromBase64String\('([^']+)'\)", wrapper).group(1)
    return gzip.decompress(base64.b64decode(encoded)).decode()


class CaseTests(unittest.TestCase):
    def test_named_cases_take_the_library_key_and_call_ids_from_the_inputs(self):
        named = probe.named_cases(LIBRARY, TABLES)
        self.assertEqual(named["pf-clamp"], [cmd(165, "H_intimacy", "99"), cmd(201, "301")])
        self.assertEqual(named["call-normal"], [cmd(165, "H_callID", "1")])  # Not the default ID 7.
        self.assertEqual(named["call-special"], [cmd(165, "H_callID", "3")])  # Category 0.
        self.assertEqual(named["seed"], [])

    def test_case_rows_encode_programs_and_assets_and_reject_separators(self):
        rows = probe.case_rows({"x": [cmd(165, "H_favor", " +12 "), cmd(201, "301")]},
                               [dict(label="prefix:0", bundle="adv/scenario/c00/20.unity3d", asset="100", count=2)]).decode()
        self.assertEqual(rows, "program\tx\t165|0|H_favor| +12 \t201|0|301\nasset\tprefix:0\tadv/scenario/c00/20.unity3d\t100\t2\n")
        for bad in ("a|b", "a\tb", "it's"):
            with self.assertRaises(ValueError):
                probe.case_rows({"x": [cmd(165, "H_favor", bad)]}, [])

    def test_program_digest_matches_the_probe_text(self):
        text = "3\x1f1\x1fH_intimacy\x1e1\x1e4\x1d4\x1f0\x1fH_intimacy\x1eH_intimacy\x1e0\x1e100\x1d165\x1f0\x1fH_intimacy\x1eH_intimacy"
        self.assertEqual(probe.program_digest(LIBRARY["301"]), hashlib.sha256(text.encode()).hexdigest())
        self.assertEqual(probe.program_digest([]), hashlib.sha256(b"").hexdigest())


class ScriptTests(unittest.TestCase):
    def test_setup_splits_the_source_under_the_command_limit_and_appends_it_whole(self):
        source = "".join(f"// line {i} {hashlib.sha256(str(i).encode()).hexdigest()}\n" for i in range(120))
        scripts = probe.setup_scripts(ROOT, source)
        self.assertGreater(len(scripts), 1)
        self.assertTrue(all(len(probe.wrapped(s)) <= probe.COMMAND_LIMIT for s in scripts))
        self.assertIn("New-Item -ItemType Junction", scripts[0])
        self.assertTrue(all("Junction" not in s for s in scripts[1:]))  # Setup runs once.
        appended = "".join(re.search(r"@'\n(.*)\n'@", s, re.S).group(1) + "\n" for s in scripts)
        self.assertEqual(appended, source)
        self.assertIn("Koikatu_Data", scripts[0])
        self.assertNotIn("UserData", scripts[0])

    def test_abdata_is_mirrored_without_apple_double_files_and_without_writes_to_the_install(self):
        script = probe.mirror_script(ROOT)
        self.assertIn("StartsWith('._')", script)
        self.assertIn("-ItemType SymbolicLink", script)
        self.assertIn("-ItemType Junction", script)
        self.assertNotIn("Remove-Item", script)
        self.assertNotIn("abdata'", probe.SETUP.replace("$root\\abdata", ""))  # Setup junctions Koikatu_Data only.
        self.assertLessEqual(len(probe.wrapped(script)), probe.COMMAND_LIMIT)

    def test_here_strings_refuse_a_terminator(self):
        with self.assertRaises(ValueError):
            probe.here("a\n'@\nb")

    def test_compile_checks_the_source_hash_and_run_stops_only_its_root(self):
        compile_script = probe.compile_script(ROOT, b"program\tseed\n", "f" * 64)
        self.assertIn("'" + "f" * 64 + "'", compile_script)
        self.assertIn("IkkokuADVBindingProbe.dll", compile_script)
        run = probe.run_script(ROOT)
        self.assertIn(r"$root\Koikatu.exe", run)
        self.assertIn("WaitForExit(" + str(probe.WAIT_SECONDS * 1000) + ")", run)
        self.assertIn("StartsWith($root+'\\')", run)
        self.assertEqual(unwrap(probe.wrapped(run)), run)

    def test_vm_exec_retries_setup_but_never_the_player_run(self):
        class Result:
            def __init__(self, code, out=""): self.returncode, self.stdout, self.stderr = code, out, "PrlJob_GetRetCode: Invalid argument"
        with patch("original_adv_binding_probe.subprocess.run", side_effect=[Result(255), Result(0, "ok")]) as run, \
                patch("original_adv_binding_probe.time.sleep"):
            self.assertEqual(probe.vm_exec("vm", "'x'"), "ok")
            self.assertEqual(run.call_count, 2)
        with patch("original_adv_binding_probe.subprocess.run", side_effect=[Result(255)]) as run:
            with self.assertRaises(RuntimeError):
                probe.vm_exec("vm", "'x'", user=True)
            self.assertEqual(run.call_count, 1)
            self.assertIn("--current-user", run.call_args[0][0])

    def test_run_refuses_an_output_folder_that_already_holds_a_run(self):
        with tempfile.TemporaryDirectory() as tmp, patch("original_adv_binding_probe.vm_exec") as vm, \
                patch("original_adv_binding_probe.errno_count") as errno:
            (Path(tmp) / "run.json").write_text("{}")
            args = type("Args", (), dict(output=Path(tmp), coverage=Path(tmp) / "missing", vm="vm", errno_baseline=5))
            with self.assertRaisesRegex(RuntimeError, "new output folder"):
                probe.run(args)
            vm.assert_not_called(); errno.assert_not_called()

    def test_guarded_stops_when_the_errno_count_moves(self):
        with patch("original_adv_binding_probe.errno_count", return_value=6):
            with self.assertRaisesRegex(RuntimeError, "errno-24 count is 6"):
                probe.guarded(5, "run")


class CompareTests(unittest.TestCase):
    def test_probe_rows_parse_and_values_compare_by_type(self):
        tsv = "\n".join([
            "meta\tcallDefaultID\t7", "heroineKey\tH_favor\tInt", "library\t301\t3\tabc",
            "x\tprogram\t1\tdef", "x\tvar\tH_favor\tSystem.Int32\t5", "x\tvar\tv\tSystem.Single\t0.1",
            "x\treplace\tH\t", "x\tfield\tcallName\ta\\tb", "x\tcommands\t201,3,4,165", "x\texception\tSystem.FormatException\t0"]) + "\n"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "adv-binding.tsv"
            path.write_text(tsv)
            meta, keys, library, cases = probe.parse_probe(path)
        self.assertEqual((meta["callDefaultID"], keys["heroineKey"], library["301"]), (["7"], [("H_favor", "Int")], dict(count=3, sha256="abc")))
        case = cases["x"]
        self.assertEqual((case["fields"]["callName"], case["replaces"]["H"], case["commands"]), ("a\tb", "", [201, 3, 4, 165]))
        self.assertEqual(case["exception"], dict(type="System.FormatException", line=0))
        self.assertTrue(probe.same_value(case["vars"]["v"], dict(type="System.Single", value="0.1")))  # Float32 equality.
        self.assertFalse(probe.same_value(case["vars"]["H_favor"], dict(type="System.Single", value="5")))
        self.assertEqual((probe.field_text(True), probe.field_text(-1)), ("True", "-1"))

    def test_final_commands_replay_insertions_after_their_line(self):
        program = [cmd(201, "301"), cmd(201, "301")]
        insertions = [dict(pc=0, asset="301"), dict(pc=4, asset="301")]
        self.assertEqual(probe.final_commands(program, insertions, LIBRARY), [201, 3, 4, 165, 201, 3, 4, 165])


if __name__ == "__main__":
    unittest.main()
