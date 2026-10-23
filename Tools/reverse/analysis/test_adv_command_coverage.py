"""Synthetic tests for adv_command_coverage.py (no original scenario data)."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import adv_command_coverage as coverage
import adv_host_requests as host
from gameplay_execution_contract import command_enum

# Ordinals follow the recovered enum for the implemented subset; the rest are
# synthetic names chosen for these tests.
NAMES = ["None", "VAR", "RandomVar", "Calc", "Clamp", "Min", "Max", "Lerp", "LerpAngle", "InverseLerp", "LerpV3",
         "LerpAngleV3", "Tag", "Format", "IF", "Switch", "Text", "Voice", "Motion", "Expression", "ExpressionIcon",
         "Open", "Close", "Jump", "Choice", "Wait", "Look"]
HANDLERS = {"VAR": "ADV.Commands.Base.VAR", "Calc": "ADV.Commands.Base.Calc", "Clamp": "ADV.Commands.Base.Clamp",
            "Tag": "ADV.Commands.Base.Tag", "IF": "ADV.Commands.Base.IF", "Switch": "ADV.Commands.Base.Switch",
            "Text": "ADV.Commands.Base.Text", "Voice": "ADV.Commands.Base.Voice", "Close": "ADV.Commands.Base.Close",
            "Jump": "ADV.Commands.Base.Jump", "Wait": "ADV.Commands.Base.Wait", "Look": "ADV.Commands.Chara.Look",
            "ExpressionIcon": "ADV.Commands.Base.ExpressionIcon", "Open": "ADV.Commands.Base.Open"}
ICON, OPEN, LOOK = 20, 21, 26  # Unsupported ordinals (Text and Voice are implemented since G-T03b).


def cmd(cid, *args, multi=False):
    return dict(hash=0, version=0, multi=multi, id=cid, args=list(args))


def bundle(path, *assets):
    return dict(path=path, sha256=hashlib.sha256(path.encode()).hexdigest(), bytes=len(path),
                assets=[dict(name=str(i), pathID=i + 1, commands=commands) for i, commands in enumerate(assets)])


def snapshot(pc, status, fault=None, batch=1, requests=()):
    return dict(pc=pc, status=status, fault=fault, variables={}, waits=[], closed=status == "closed", executedInstructions=0,
                batch=batch, requests=list(requests))


class CommandTableTests(unittest.TestCase):
    LIST = """using ADV.Commands.Base;
using ADV.Commands.Chara;
namespace ADV;
public class CommandList {
    public static CommandBase CommandGet(Command command) {
        return command switch {
            Command.Tag => (CommandBase)new Tag(),
            Command.Motion => new ADV.Commands.Base.Motion(),
            Command.Regulate => new Regulate(),
            Command.Look => new Look(),
            _ => null,
        };
    }
}"""

    def test_handlers_follow_csharp_lookup(self):
        known = {"ADV.Commands.Base.Tag", "ADV.Regulate", "ADV.Commands.Base.Regulate", "ADV.Commands.Chara.Look"}
        handlers = coverage.command_handlers(self.LIST, known.__contains__)
        self.assertEqual(handlers["Tag"], "ADV.Commands.Base.Tag")
        self.assertEqual(handlers["Motion"], "ADV.Commands.Base.Motion")  # Qualified by the decompiler.
        self.assertEqual(handlers["Regulate"], "ADV.Regulate")  # The enclosing namespace wins.
        self.assertEqual(handlers["Look"], "ADV.Commands.Chara.Look")
        self.assertNotIn("None", handlers)

    def test_ambiguous_or_missing_handler_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Cannot resolve"):
            coverage.command_handlers(self.LIST, {"ADV.Commands.Base.Tag", "ADV.Commands.Base.Look", "ADV.Commands.Chara.Look"}.__contains__)
        with self.assertRaisesRegex(ValueError, "Cannot resolve"):
            coverage.command_handlers(self.LIST, {"ADV.Commands.Base.Tag"}.__contains__)

    def test_enum_with_explicit_values_is_rejected(self):
        self.assertEqual(command_enum("enum Command { None, VAR, Tag }"), ["None", "VAR", "Tag"])
        with self.assertRaisesRegex(ValueError, "explicit"):
            command_enum("enum Command { None, VAR = 4 }")

    def test_native_status_distinguishes_missing_original_handler(self):
        self.assertEqual(coverage.native_status(1, NAMES, HANDLERS), "implemented")
        self.assertEqual(coverage.native_status(ICON, NAMES, HANDLERS), "unsupported")
        self.assertEqual(coverage.native_status(24, NAMES, HANDLERS), "no-original-handler")
        self.assertEqual(coverage.native_status(400, NAMES, HANDLERS), "unknown-ordinal")


class StaticPredictionTests(unittest.TestCase):
    def test_first_unsupported_and_certain_argument_limits(self):
        program = [cmd(1, "System.Int32", "a", "1", multi=True), cmd(1, "System.Int32", "b", "1", "2"), cmd(ICON)]
        unsupported, halt = coverage.first_static_halt(program, NAMES)
        self.assertEqual((unsupported["index"], unsupported["id"], unsupported["name"]), (2, ICON, "ExpressionIcon"))
        self.assertEqual((halt["index"], halt["id"], halt["kind"]), (1, 1, "var-random-alternatives"))
        jump = [cmd(23, "bundle:asset"), cmd(ICON)]
        self.assertEqual(coverage.first_static_halt(jump, NAMES)[1]["kind"], "external-file-jump")
        branch = [cmd(14, "a", "0", "b", "file:tag", "local"), cmd(ICON)]
        self.assertEqual(coverage.first_static_halt(branch, NAMES)[1]["index"], 1)  # A branch is not certain.
        self.assertEqual(coverage.argument_limits(branch)[0]["kind"], "if-external-branch")
        self.assertEqual(coverage.first_static_halt([cmd(22)], NAMES), (None, None))

    def test_analysis_counts_blockers_families_and_greedy_order(self):
        bundles = [bundle("c00/00.unity3d", [cmd(LOOK), cmd(ICON)], [cmd(LOOK), cmd(OPEN), cmd(ICON)], []),
                   bundle("op/00.unity3d", [cmd(1, "System.Int32", "x", "1", multi=True), cmd(ICON), cmd(22)], [cmd(22)])]
        result = coverage.analyse(bundles, NAMES, HANDLERS, greedy_steps=5)
        totals = result["totals"]
        self.assertEqual((totals["bundles"], totals["assets"], totals["emptyAssets"], totals["commands"]), (2, 5, 1, 9))
        self.assertEqual((totals["executableByIDAssets"], totals["executableByIDNonEmptyAssets"]), (2, 1))
        self.assertEqual(totals["staticPrefixCommands"], 0 + 0 + 0 + 1 + 1)
        self.assertEqual(totals["firstUnsupportedIndexHistogram"], {"0": 2, "none": 2, "1": 1})
        lines = "".join(f"{b['path']} {b['sha256']}\n" for b in sorted(bundles, key=lambda b: b["path"]))
        self.assertEqual(totals["corpusSHA256"], hashlib.sha256(lines.encode()).hexdigest())
        rows = {row["id"]: row for row in result["commands"]}
        self.assertEqual((rows[LOOK]["uses"], rows[LOOK]["assets"], rows[LOOK]["firstBlockerAssets"]), (2, 2, 2))
        self.assertEqual((rows[ICON]["firstBlockerAssets"], rows[ICON]["soleBlockerAssets"]), (1, 1))
        self.assertEqual((rows[ICON]["family"], rows[LOOK]["family"], rows[1]["native"]), ("Base", "Chara", "implemented"))
        self.assertEqual([row["id"] for row in result["firstBlockerRanking"]], [LOOK, ICON])
        families = {row["family"]: row for row in result["families"]}
        self.assertEqual((families["Chara"]["firstBlockerAssets"], families["Base"]["assets"]), (2, 4))
        steps = result["greedyImplementationOrder"]
        self.assertEqual([(s["id"], s["firstBlockerAssets"], s["executableByIDAfter"]) for s in steps],
                         [(LOOK, 2, 2), (ICON, 2, 4), (OPEN, 1, 5)])
        directory = {row["directory"]: row for row in result["directories"]}
        self.assertEqual(directory["c00"]["topFirstBlocker"]["id"], LOOK)

    def test_trace_chunks_respect_inspector_bounds(self):
        cases = [coverage.trace_case("b", dict(name=str(i), pathID=i, commands=[cmd(22)] * 3)) for i in range(5)]
        self.assertEqual(len(cases[0]["ticks"]), 3 + coverage.TICK_SLACK)
        self.assertEqual([len(c) for c in coverage.chunk_cases(cases, max_cases=2)], [2, 2, 1])
        self.assertEqual([len(c) for c in coverage.chunk_cases(cases, max_ticks=14)], [2, 2, 1])
        with self.assertRaisesRegex(ValueError, "bounds"):
            list(coverage.chunk_cases(cases, max_ticks=6))


class ReachabilityTests(unittest.TestCase):
    def test_if_forks_both_local_branches(self):
        program = [cmd(14, "a", "0", "b", "yes", "no"), cmd(12, "yes", multi=True), cmd(ICON),
                   cmd(12, "no", multi=True), cmd(OPEN)]
        outcomes, loop, transfers = coverage.reachable_outcomes(program)
        self.assertIn(dict(status="faulted", pc=2, id=ICON), outcomes)
        self.assertIn(dict(status="faulted", pc=4, id=OPEN), outcomes)
        self.assertIn(dict(status="faulted", pc=0, id=14), outcomes)  # Value-dependent IF fault.
        self.assertFalse(loop)
        self.assertEqual(transfers, [0])

    def test_missing_tag_continues_and_close_terminates(self):
        program = [cmd(23, "absent"), cmd(22), cmd(ICON)]
        outcomes, _, transfers = coverage.reachable_outcomes(program)
        self.assertEqual(outcomes, [dict(status="closed", pc=None, id=None)])
        self.assertEqual(transfers, [])

    def test_backward_jump_is_a_loop_and_end_is_exhaustion(self):
        outcomes, loop, _ = coverage.reachable_outcomes([cmd(12, "top", multi=True), cmd(25, "1"), cmd(23, "top")])
        self.assertTrue(loop)
        self.assertEqual(outcomes, [])
        self.assertEqual(coverage.reachable_outcomes([cmd(25, "1")])[0], [dict(status="exhausted", pc=None, id=None)])

    def test_variable_named_target_may_reach_any_tag(self):
        program = [cmd(1, "System.String", "next", "later", multi=True), cmd(23, "next"), cmd(ICON),
                   cmd(12, "later", multi=True), cmd(OPEN)]
        outcomes, _, _ = coverage.reachable_outcomes(program)
        self.assertIn(dict(status="faulted", pc=1, id=23), outcomes)
        self.assertIn(dict(status="faulted", pc=2, id=ICON), outcomes)
        self.assertIn(dict(status="faulted", pc=4, id=OPEN), outcomes)

    def test_straight_line_and_strata(self):
        straight = [cmd(1, "System.Int32", "a", "1", multi=True), cmd(25, "1"), cmd(ICON)]
        _, halt = coverage.first_static_halt(straight, NAMES)
        self.assertTrue(coverage.straight_line(straight, halt))
        record = dict(firstStaticHalt=halt)
        self.assertEqual(coverage.stratum(record, straight), "wait-prefix")
        reference = [cmd(1, "System.Int32", "a", "*b", multi=True), cmd(ICON)]
        self.assertFalse(coverage.straight_line(reference, coverage.first_static_halt(reference, NAMES)[1]))
        branch = [cmd(23, "t"), cmd(ICON), cmd(12, "t", multi=True), cmd(OPEN)]
        self.assertEqual(coverage.stratum(dict(firstStaticHalt=coverage.first_static_halt(branch, NAMES)[1]), branch), "branch-before")
        sequential = [cmd(23, "t"), cmd(12, "t", multi=True), cmd(ICON)]  # The tag follows the jump.
        self.assertEqual(coverage.stratum(dict(firstStaticHalt=coverage.first_static_halt(sequential, NAMES)[1]), sequential),
                         "control-flow-before")
        self.assertEqual(coverage.stratum(dict(firstStaticHalt=None), []), "empty")

    def test_mutation_moves_expected_halt(self):
        program = [cmd(ICON, "x"), cmd(1, "System.Int32", "a", "1", multi=True), cmd(OPEN)]
        mutated = coverage.mutate_halt(program, 0)
        self.assertEqual((mutated[0]["id"], mutated[0]["args"], program[0]["id"]), (0, [], ICON))
        self.assertEqual(coverage.first_static_halt(mutated, NAMES)[1]["index"], 2)


class SampleTests(unittest.TestCase):
    def test_sample_is_deterministic_and_spread(self):
        assets = [[cmd(ICON)], [cmd(OPEN)], [cmd(1, "System.Int32", "a", "1", multi=True), cmd(ICON)], [cmd(22)], []]
        bundles = [bundle(f"c0{i}/00.unity3d", *assets) for i in range(3)]
        result = coverage.analyse(bundles, NAMES, HANDLERS)
        strata = {"first-command": 3, "scalar-prefix": 1, "executable": 1, "empty": 1}
        first = coverage.select_sample(bundles, result, NAMES, strata)
        again = coverage.select_sample(bundles, result, NAMES, strata)
        self.assertEqual(first, again)
        self.assertEqual(first["caseCount"], 6)
        picked = [c for c in first["cases"] if c["stratum"] == "first-command"]
        self.assertEqual(len({c["bundle"].split("/")[0] for c in picked}), 3)
        self.assertEqual(first["strataPopulation"]["first-command"], 6)
        scalar = next(c for c in first["cases"] if c["stratum"] == "scalar-prefix")
        self.assertTrue(scalar["exactPrediction"])
        self.assertEqual(scalar["mutation"]["expectedHalt"], None)


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.program = [cmd(14, "a", "0", "b", "yes", "no"), cmd(12, "yes", multi=True), cmd(ICON),
                        cmd(12, "no", multi=True), cmd(OPEN)]
        self.result = coverage.analyse([bundle("c00/00.unity3d", self.program)], NAMES, HANDLERS)
        self.record = self.result["assets"][0]

    def test_observe_detects_non_sequential_batches(self):
        fault = dict(pc=4, commandID=OPEN, reason="Unsupported source gameplay operation: ADV command ID 21 at pc 4")
        observed, _ = coverage.observe(self.program, [snapshot(5, "faulted", fault)])
        self.assertEqual((observed["faultPC"], observed["observedJumpBatchStarts"]), (4, [0]))
        sequential = [cmd(1, "System.Int32", "a", "1"), cmd(25, "1"), cmd(ICON)]
        observed, _ = coverage.observe(sequential, [snapshot(1, "frameBoundary"), snapshot(2, "waiting", batch=2),
                                                    snapshot(2, "waiting", batch=2),
                                                    snapshot(3, "faulted", dict(pc=2, commandID=ICON, reason="r"), batch=3)])
        self.assertEqual(observed["observedJumpBatchStarts"], [])

    def test_classify_match_value_fault_and_control_flow(self):
        reason = "Unsupported source gameplay operation: ADV command ID 20 at pc 2"
        match, _ = coverage.observe(self.program, [snapshot(3, "faulted", dict(pc=2, commandID=ICON, reason=reason))])
        self.assertEqual(coverage.classify(self.record, match)[0], "match")
        jumped, _ = coverage.observe(self.program, [snapshot(5, "faulted", dict(pc=4, commandID=OPEN, reason="ADV command ID 21 at pc 4"))])
        self.assertEqual(coverage.classify(self.record, jumped)[0], "control-flow-different-halt")
        value, _ = coverage.observe(self.program, [snapshot(1, "faulted", dict(pc=0, commandID=14, reason="Extended/scientific IF literal"))])
        self.assertEqual(coverage.classify(self.record, value), ("value-dependent-fault",
                         "extended-literal at implemented command 14 (pc 0) under default inputs"))
        wrong, _ = coverage.observe(self.program, [snapshot(3, "faulted", dict(pc=2, commandID=ICON, reason="other"))])
        self.assertEqual(coverage.classify(self.record, wrong)[0], "match-position-reason-differs")

    def test_compare_joins_reports_and_checks_reachability(self):
        trace = dict(cases=[coverage.trace_case("c00/00.unity3d", dict(name="0", pathID=1, commands=self.program))])
        reason = "Unsupported source gameplay operation: ADV command ID 20 at pc 2"
        report = dict(cases=[dict(name="c00/00.unity3d#1", snapshots=[snapshot(3, "faulted", dict(pc=2, commandID=ICON, reason=reason))])])
        result = coverage.compare(self.result, [(trace, report)])
        self.assertEqual(result["summary"]["categories"], {"match": 1})
        self.assertEqual(result["summary"]["observedOutsideReachableOutcomes"], 0)
        bad = dict(cases=[dict(name="c00/00.unity3d#1", snapshots=[snapshot(2, "faulted", dict(pc=1, commandID=12, reason="x"))])])
        self.assertEqual(coverage.compare(self.result, [(trace, bad)])["summary"]["observedOutsideReachableOutcomes"], 1)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            coverage.compare(self.result, [(trace, report), (trace, report)])


class PresentationTests(unittest.TestCase):
    """Presentation commands (G-T03b): argument halts, value dependence and request checks."""

    def test_definite_argument_fault_is_a_certain_halt(self):
        program = [cmd(128, "0", "1", "1", multi=True), cmd(125, "mobNo", "1"), cmd(ICON)]
        unsupported, halt = coverage.first_static_halt(program, NAMES)
        self.assertEqual(unsupported["index"], 2)
        self.assertEqual((halt["index"], halt["id"], halt["kind"], halt["site"]), (1, 125, "invalid-argument", "Chara.LookEyes.Do No"))
        self.assertEqual(halt["reason"], "argument parse throws in Chara.LookEyes.Do No:")
        multi = [cmd(169, "1", "None", multi=True), cmd(22)]
        self.assertEqual(coverage.first_static_halt(multi, NAMES)[1]["kind"], "mapchange-multi")
        colour = [cmd(44, "in", "", "1,0,0"), cmd(22)]
        self.assertEqual(coverage.first_static_halt(colour, NAMES)[1]["reason"], "ADV argument form at Effect.SceneFade.Do Color:")

    def test_assigned_variable_makes_the_argument_value_dependent(self):
        program = [cmd(1, "System.Int32", "mobNo", "2", multi=True), cmd(128, "mobNo", "1", "1"), cmd(22)]
        self.assertEqual(coverage.first_static_halt(program, NAMES), (None, None))
        limit = coverage.argument_limits(program)[0]
        self.assertEqual((limit["index"], limit["kind"], limit["certain"]), (1, "invalid-argument", False))
        self.assertEqual(coverage.value_dependent(program), {1})
        self.assertFalse(coverage.straight_line(program, None))
        outcomes, _, _ = coverage.reachable_outcomes(program)
        self.assertEqual(outcomes, [dict(status="closed", pc=None, id=None), dict(status="faulted", pc=1, id=128)])
        clean = [cmd(1, "System.Int32", "1", "2", multi=True), cmd(128, "0", "1", "1"), cmd(22)]  # A variable named "1".
        self.assertEqual(coverage.argument_limits(clean)[0]["kind"], "value-dependent-argument")

    def rich(self):
        lines = [cmd(44, "out"), cmd(88, "Date", multi=True)] + [cmd(128, "0", str(i), "1", multi=True) for i in range(8)]
        return lines + [cmd(17, "0", "", "v", multi=True), cmd(16, "n", "t"), cmd(169, "1", "None"), cmd(22)]

    def test_request_sequence_stratum_and_sample_prediction(self):
        program = self.rich()
        record = dict(firstStaticHalt=None)
        self.assertEqual(coverage.stratum(record, program), "request-sequence")
        self.assertEqual(coverage.stratum(record, [cmd(16, "n", "t"), cmd(22)]), "executable")
        result = coverage.analyse([bundle("c00/00.unity3d", program)], NAMES, HANDLERS)
        sample = coverage.select_sample([bundle("c00/00.unity3d", program)], result, NAMES, {"request-sequence": 1})
        case = sample["cases"][0]
        self.assertTrue(case["exactPrediction"])
        self.assertEqual([r["command"]["kind"] for r in case["predictedRequests"]],
                         ["sceneFade", "bgmPlay"] + ["charaLookNeck"] * 8 + ["text", "mapChange"])
        self.assertEqual(sample["scriptedHost"]["autoNext"], True)

    def test_trace_case_uses_the_scripted_host(self):
        case = coverage.trace_case("b", dict(name="x", pathID=1, commands=[cmd(22)]))
        self.assertEqual((case["autoAcknowledge"], case["autoNext"], case["mapVariables"], case["requestDetail"]), (True, True, {}, "full"))

    def native(self, program):
        """Requests as the native kernel reports them, built from the model for a straight-line program."""
        return host.predict_requests(program, len(program))

    def test_check_requests_accepts_the_model_and_flags_differences(self):
        program = self.rich()
        requests = [dict(r, frameStart=0 if r["batch"] == 1 else 1, frameBatches=1) for r in self.native(program)]
        stats, mismatches = coverage.check_requests(program, requests, len(program))
        self.assertEqual((stats["requests"], stats["argumentMatches"], stats["sequenceMatches"], stats["mismatches"]), (12, 12, 1, 0))
        self.assertEqual((stats["sequenceRequests"], stats["sequenceNonEmpty"]), (12, 1))
        self.assertEqual(mismatches, [])
        wrong = [dict(r) for r in requests]
        wrong[0] = dict(wrong[0], blocking="none")
        wrong[2] = dict(wrong[2], command=dict(kind="charaLookNeck", arguments=dict(chara=0, pattern=9, rate=1.0)))
        stats, mismatches = coverage.check_requests(program, wrong, len(program))
        self.assertEqual((stats["mismatch:policy"], stats["mismatch:arguments"], stats["mismatch:sequence"]), (1, 1, 1))
        self.assertEqual(mismatches[0]["kind"], "policy")

    def test_check_requests_skips_value_dependent_and_jumped_bindings(self):
        program = [cmd(1, "System.String", "who", "0", multi=True), cmd(128, "who", "1", "1", multi=True),
                   cmd(17, "0", "", "v", multi=True), cmd(16, "n", "t"), cmd(22)]
        observed = [dict(requestID=0, pc=1, commandID=128, batch=1, blocking="none", frameStart=0, frameBatches=1,
                         command=dict(kind="charaLookNeck", arguments=dict(chara=0, pattern=1, rate=1.0))),
                    dict(requestID=1, pc=3, commandID=16, batch=2, blocking="next", frameStart=0, frameBatches=2,
                         command=dict(kind="text", arguments=dict(name="n", text="t", voices=[[dict(chara=5)]])))]
        stats, _ = coverage.check_requests(program, observed)
        self.assertEqual((stats["valueDependentUnchecked"], stats["textBindingsUnchecked"], stats["argumentMatches"]), (1, 1, 1))
        observed[1] = dict(observed[1], frameBatches=1, frameStart=2)
        stats, _ = coverage.check_requests(program, observed)
        self.assertEqual(stats["mismatch:arguments"], 1)  # voices must be the Voice at pc 2.

    def test_observe_annotates_requests_and_detects_reentered_batches(self):
        program = [cmd(23, "t", multi=True), cmd(12, "t", multi=True), cmd(16, "n", "t"), cmd(22)]
        text = dict(requestID=0, pc=2, commandID=16, batch=2, blocking="next", command=dict(kind="text", arguments={}))
        outcome, requests = coverage.observe(program, [snapshot(3, "awaitingNext", batch=2, requests=[text]),
                                                       snapshot(4, "closed", batch=3)])
        self.assertEqual(outcome["observedJumpBatchStarts"], [0])
        self.assertEqual((outcome["status"], outcome["batches"]), ("closed", 3))
        self.assertEqual((requests[0]["frameStart"], requests[0]["frameBatches"]), (0, 2))

    def test_argument_halt_matches_by_site(self):
        program = [cmd(128, "mobNo", "1", "1"), cmd(22)]
        record = coverage.analyse([bundle("c00/00.unity3d", program)], NAMES, HANDLERS)["assets"][0]
        reason = "Source ADV argument parse throws in Chara.LookNeck.Do No: Int32.Parse: no digits"
        outcome, _ = coverage.observe(program, [snapshot(1, "faulted", dict(pc=0, commandID=128, reason=reason))])
        self.assertEqual(coverage.classify(record, outcome), ("match", None))
        other = "Source ADV argument parse throws in Chara.LookNeck.Do Ptn: Int32.Parse: no digits"
        outcome, _ = coverage.observe(program, [snapshot(1, "faulted", dict(pc=0, commandID=128, reason=other))])
        self.assertEqual(coverage.classify(record, outcome)[0], "match-position-reason-differs")
        clean = coverage.analyse([bundle("c00/00.unity3d", [cmd(128, "0", "1", "1"), cmd(22)])], NAMES, HANDLERS)["assets"][0]
        outcome, _ = coverage.observe(program, [snapshot(1, "faulted", dict(pc=0, commandID=128, reason=reason))])
        self.assertEqual(coverage.classify(clean, outcome, reachable=False)[0], "unexplained")

    def test_enum_members_reject_explicit_values(self):
        self.assertEqual(coverage.enum_members("public enum FadeType { None, InOut }", "FadeType"), ["None", "InOut"])
        with self.assertRaisesRegex(ValueError, "explicit"):
            coverage.enum_members("enum Type { Base = 2 }", "Type")


class ScanTests(unittest.TestCase):
    def test_scan_checks_provenance_and_orders_assets(self):
        rows = [dict(_hash=1, _version=0, _multi=0, _command=ICON, _args=["x"])]
        records = [(9, dict(m_Name="late", list=rows)), (3, dict(m_Name="early", list=[]))]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "c00").mkdir()
            path = root / "c00/00.unity3d"
            path.write_bytes(b"bundle")
            digest = hashlib.sha256(b"bundle").hexdigest()
            (root / "c00/00.unity3d.provenance.json").write_text(json.dumps(dict(sha256=digest, length=6, source="C:\\x")))
            with patch.object(coverage, "mono_records", return_value=records):
                scanned = coverage.scan_bundle(path, root)
            self.assertEqual((scanned["path"], scanned["sha256"]), ("c00/00.unity3d", digest))
            self.assertEqual([a["name"] for a in scanned["assets"]], ["early", "late"])
            self.assertEqual(scanned["assets"][1]["commands"], [dict(hash=1, version=0, multi=False, id=ICON, args=["x"])])
            (root / "c00/00.unity3d.provenance.json").write_text(json.dumps(dict(sha256="0" * 64, length=6)))
            with patch.object(coverage, "mono_records", return_value=records), self.assertRaisesRegex(ValueError, "provenance"):
                coverage.scan_bundle(path, root)



# G-T02 bindings: synthetic heroine keys, call-name tables and parameter library.
KEYS = [dict(key="H_intimacy", command="Int", writable=True, default=0), dict(key="H_callID", command="Int", writable=True, default=-1),
        dict(key="H_isKiss", command="BOOL", writable=True, default=False), dict(key="H_Name", command="String", writable=False),
        dict(key="H", command="Replace", writable=False)]
TABLES = dict(schemaVersion=1, callDefaultID=7, voiceNumbers=[0],
              callNames={"c00": [dict(name="A", id=1, category=2, bundle="b"), dict(name="S", id=5, category=0, bundle="b"),
                                 dict(name="D", id=7, category=2, bundle="b")],
                         "player": [dict(name="D", id=7, category=2, bundle="b")]})
TRIPLE = [cmd(3, "H_intimacy", "1", "4", multi=True), cmd(4, "H_intimacy", "H_intimacy", "0", "100"), cmd(165, "H_intimacy", "H_intimacy")]
LIBRARY = {"lib": TRIPLE, "empty": [], "nest": [cmd(201, "lib")], "bad": [cmd(ICON)]}


def bound():
    return patch.object(coverage, "BINDING", coverage.Binding(KEYS, LIBRARY, TABLES))


def strip(commands):
    return [{k: v for k, v in c.items() if k != "inserted"} for c in commands]


class BindingTests(unittest.TestCase):
    def test_parameter_file_expands_after_its_line_in_execution_order(self):
        program = [cmd(201, "nest"), cmd(201, "missing"), cmd(201, "empty"), cmd(16, "n", "t"), cmd(22)]
        with bound():
            expanded, insertions, origins = coverage.expand(program)
        self.assertEqual([c["id"] for c in expanded], [201, 201, 3, 4, 165, 201, 201, 16, 22])
        self.assertEqual(insertions, [dict(pc=0, asset="nest", count=1), dict(pc=1, asset="lib", count=3), dict(pc=6, asset="empty", count=0)])
        self.assertEqual(origins[:3], [(0,), (0, "nest", 0), (0, "nest", 0, "lib", 0)])
        self.assertEqual(origins[5:], [(1,), (2,), (3,), (4,)])
        self.assertEqual(strip(expanded[2:5]), TRIPLE)
        self.assertEqual(coverage.expand(program)[1], [])  # No binding: nothing is inserted.

    def test_unbound_commands_are_certain_halts(self):
        unsupported, halt = coverage.first_static_halt([cmd(1, "System.Int32", "a", "1", multi=True), cmd(165, "H_intimacy", "1")], NAMES)
        self.assertIsNone(unsupported)
        self.assertEqual((halt["index"], halt["kind"], halt["reason"]), (1, "unbound-character", "ADV command ID 165 at pc 1"))
        self.assertEqual(coverage.first_static_halt([cmd(201, "lib")], NAMES)[1]["reason"], "ADV command ID 201 at pc 0")

    def test_heroine_param_forms(self):
        def limit(*args):
            with bound():
                limits = coverage.argument_limits([cmd(165, *args)])
            return (limits[0]["kind"], limits[0]["certain"], limits[0].get("reason")) if limits else None
        self.assertEqual(limit(), ("character-source-exception", True, "HeroineParam args[0] (IndexOutOfRangeException)"))
        self.assertEqual(limit("H_intimacy"), ("character-source-exception", True, "HeroineParam args[1] (IndexOutOfRangeException)"))
        self.assertIsNone(limit("H_unknown", "x"))  # SetADVParam ignores an unknown key.
        self.assertIsNone(limit("H_intimacy", " -3 "))
        self.assertEqual(limit("H_intimacy", "6.5"), ("invalid-argument", True, "SaveData.Heroine.SetADVParam(H_intimacy) Convert.ChangeType Int32"))
        self.assertIsNone(limit("H_isKiss", " TRUE "))
        self.assertEqual(limit("H_isKiss", "1")[0], "invalid-argument")
        self.assertIsNone(limit("H_Name", "anything"))
        self.assertIsNone(limit("H_callID", "5"))
        self.assertIsNone(limit("H_callID", "-1"))  # The player's ID 7 is in the list.
        self.assertEqual(limit("H_callID", "4"), ("character-source-exception", True, "SaveData.FindCallFileData: no call name 4"))
        self.assertEqual(limit("H_intimacy", "H_callID"), ("value-dependent-argument", False, None))  # A seeded key.

    def test_seeded_and_call_variables_make_arguments_value_dependent(self):
        voice = cmd(17, "0", "callBundle", "callName0", multi=True)
        with bound():
            self.assertNotIn("callBundle", coverage.assigned_names([voice, cmd(22)]))
            self.assertIn("callBundle", coverage.assigned_names([cmd(165, "H_callID", "5"), voice, cmd(22)]))
            self.assertIn("H_isKiss", coverage.assigned_names([cmd(22)]))
            program = [cmd(1, "System.String", "which", "lib", multi=True), cmd(201, "which"), cmd(22)]
            self.assertEqual(coverage.expand(program)[1], [])
            self.assertEqual([(l["index"], l["kind"], l["certain"]) for l in coverage.argument_limits(program)],
                             [(1, "value-dependent-argument", False)])
            jump = [cmd(23, "H_Name"), cmd(12, "x", multi=True), cmd(22)]
            outcomes, _, _ = coverage.reachable_outcomes(jump)
            self.assertIn(dict(status="faulted", pc=0, id=23), outcomes)

    def test_modelled_library_is_straight_line_and_predicts_the_heroine(self):
        program = [cmd(201, "lib"), cmd(201, "lib"), cmd(16, "n", "t"), cmd(22)]
        with bound():
            expanded = coverage.expand(program)[0]
            self.assertEqual(coverage.modelled(expanded), {1, 2, 3, 5, 6, 7})
            self.assertTrue(coverage.straight_line(expanded, None))
            self.assertEqual(coverage.expected_heroine(expanded, len(expanded)), {"intimacy": 8})
            self.assertEqual(coverage.expected_heroine(expanded, 4), {"intimacy": 4})
            self.assertIsNone(coverage.expected_heroine(expanded, 3))  # Ends inside an inserted program.
            # A program write to the same key: the inserted Calc is value-dependent again.
            mixed = coverage.expand([cmd(1, "System.String", "H_intimacy", "x", multi=True), cmd(201, "lib"), cmd(22)])[0]
            self.assertEqual(coverage.modelled(mixed), set())
            self.assertFalse(coverage.straight_line(mixed, None))
            self.assertIsNone(coverage.expected_heroine([cmd(165, "H_intimacy", "4"), cmd(22)], 2))
            halt = coverage.first_static_halt(coverage.expand([cmd(201, "bad"), cmd(22)])[0], NAMES)[1]
            self.assertEqual((halt["index"], halt["id"]), (1, ICON))

    def test_replay_maps_indexes_through_later_insertions(self):
        program = [cmd(12, "t", multi=True), cmd(201, "lib"), cmd(16, "n", "x"), cmd(23, "t")]
        first = dict(pc=1, asset="lib", count=3, nextRequestID=0, batch=1)
        text = dict(requestID=0, pc=5, commandID=16, batch=3, blocking="next", command=dict(kind="text", arguments={}))
        snapshots = [dict(snapshot(2, "frameBoundary"), insertions=[first]),
                     dict(snapshot(6, "awaitingNext", batch=3, requests=[text]), insertions=[]),
                     dict(snapshot(2, "frameBoundary", batch=4), insertions=[dict(first, nextRequestID=1, batch=4)])]
        with bound():
            final, keys, mapped, insertions, failures = coverage.replay_observed(program, snapshots)
            self.assertEqual(failures, 0)
            self.assertEqual([c["id"] for c in final], [12, 201, 3, 4, 165, 3, 4, 165, 16, 23])
            self.assertEqual([s["pc"] for s in mapped], [5, 9, 2])  # Later insertions at pc 1 shift these.
            self.assertEqual(mapped[1]["requests"][0]["pc"], 8)
            self.assertEqual(final[8]["id"], 16)
            self.assertEqual(keys[2], keys[5])  # Both copies have the static origin.
            tampered = [dict(snapshots[0], insertions=[dict(first, count=2)])] + snapshots[1:]
            self.assertEqual(coverage.replay_observed(program, tampered)[4], 1)
            renamed = [dict(snapshots[0], insertions=[dict(first, asset="empty", count=0)])]
            self.assertEqual(coverage.replay_observed(program, renamed)[4], 1)  # Not the literal asset.

    def native_run(self):
        return [dict(snapshot(1, "frameBoundary"), insertions=[dict(pc=0, asset="lib", count=3, nextRequestID=0, batch=1)]),
                dict(snapshot(3, "frameBoundary", batch=2), insertions=[]), dict(snapshot(4, "frameBoundary", batch=3), insertions=[]),
                dict(snapshot(5, "closed", batch=4), insertions=[])]

    def test_compare_checks_insertions_and_the_heroine(self):
        program = [cmd(201, "lib"), cmd(22)]
        with bound():
            result = coverage.analyse([bundle("c00/00.unity3d", program)], NAMES, HANDLERS)
            self.assertEqual((result["totals"]["commands"], result["totals"]["expandedCommands"]), (2, 5))
            case = coverage.trace_case("c00/00.unity3d", dict(name="0", pathID=1, commands=program))
            self.assertEqual((case["variableDetail"], case["character"]["player"], len(case["ticks"])), ("changes", dict(callID=7), 9))
            trace = dict(cases=[case])
            def run(snapshots, intimacy):
                report = dict(cases=[dict(name="c00/00.unity3d#1", snapshots=snapshots, heroine=dict(intimacy=intimacy, callID=-1))])
                return coverage.compare(result, [(trace, report)])["summary"]
            summary = run(self.native_run(), 4)
            self.assertEqual(summary["categories"], {"match-no-halt": 1})
            self.assertEqual({k: summary["insertions"][k] for k in ("sequenceMatches", "heroineMatches", "heroineChanged")},
                             dict(sequenceMatches=1, heroineMatches=1, heroineChanged=1))
            self.assertEqual(summary["requestMismatchCases"], 0)
            self.assertEqual(run(self.native_run(), 5)["requests"]["mismatch:heroine"], 1)
            tampered = self.native_run()
            tampered[0] = dict(tampered[0], insertions=[dict(tampered[0]["insertions"][0], count=4)])
            self.assertEqual(run(tampered, 4)["categories"], {"unexplained": 1})

    def test_sample_carries_the_binding_and_library_checks(self):
        program = [cmd(201, "lib"), cmd(16, "n", "t"), cmd(22)]
        with bound():
            result = coverage.analyse([bundle("c00/00.unity3d", program)], NAMES, HANDLERS)
            sample = coverage.select_sample([bundle("c00/00.unity3d", program)], result, NAMES, {"parameter-file": 1})
        self.assertEqual((sample["schemaVersion"], sample["parameterLibraryPath"], sample["characterTablesPath"]),
                         (3, "parameter-library.json", "character-tables.json"))
        case = sample["cases"][0]
        self.assertEqual((case["stratum"], case["exactPrediction"], case["expectedHeroine"]), ("parameter-file", True, {"intimacy": 4}))
        self.assertEqual(case["predictedInsertions"], [dict(pc=0, asset="lib", count=3)])
        self.assertEqual(case["program"]["commands"], program)  # The native run inserts the library itself.
        self.assertEqual(sample["libraryChecks"], [dict(asset="lib", expectedHeroine={"intimacy": 4})])

if __name__ == "__main__":
    unittest.main()
