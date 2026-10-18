"""Synthetic tests for adv_command_coverage.py (no original scenario data)."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import adv_command_coverage as coverage
from gameplay_execution_contract import command_enum

# Ordinals follow the recovered enum for the implemented subset; the rest are
# synthetic names chosen for these tests.
NAMES = ["None", "VAR", "RandomVar", "Calc", "Clamp", "Min", "Max", "Lerp", "LerpAngle", "InverseLerp", "LerpV3",
         "LerpAngleV3", "Tag", "Format", "IF", "Switch", "Text", "Voice", "Motion", "Expression", "ExpressionIcon",
         "Open", "Close", "Jump", "Choice", "Wait", "Look"]
HANDLERS = {"VAR": "ADV.Commands.Base.VAR", "Calc": "ADV.Commands.Base.Calc", "Clamp": "ADV.Commands.Base.Clamp",
            "Tag": "ADV.Commands.Base.Tag", "IF": "ADV.Commands.Base.IF", "Switch": "ADV.Commands.Base.Switch",
            "Text": "ADV.Commands.Base.Text", "Voice": "ADV.Commands.Base.Voice", "Close": "ADV.Commands.Base.Close",
            "Jump": "ADV.Commands.Base.Jump", "Wait": "ADV.Commands.Base.Wait", "Look": "ADV.Commands.Chara.Look"}
TEXT, VOICE, LOOK = 16, 17, 26


def cmd(cid, *args, multi=False):
    return dict(hash=0, version=0, multi=multi, id=cid, args=list(args))


def bundle(path, *assets):
    return dict(path=path, sha256=hashlib.sha256(path.encode()).hexdigest(), bytes=len(path),
                assets=[dict(name=str(i), pathID=i + 1, commands=commands) for i, commands in enumerate(assets)])


def snapshot(pc, status, fault=None):
    return dict(pc=pc, status=status, fault=fault, variables={}, waits=[], closed=status == "closed", executedInstructions=0)


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
        self.assertEqual(coverage.native_status(TEXT, NAMES, HANDLERS), "unsupported")
        self.assertEqual(coverage.native_status(24, NAMES, HANDLERS), "no-original-handler")
        self.assertEqual(coverage.native_status(400, NAMES, HANDLERS), "unknown-ordinal")


class StaticPredictionTests(unittest.TestCase):
    def test_first_unsupported_and_certain_argument_limits(self):
        program = [cmd(1, "System.Int32", "a", "1", multi=True), cmd(1, "System.Int32", "b", "1", "2"), cmd(TEXT)]
        unsupported, halt = coverage.first_static_halt(program, NAMES)
        self.assertEqual((unsupported["index"], unsupported["id"], unsupported["name"]), (2, TEXT, "Text"))
        self.assertEqual((halt["index"], halt["id"], halt["kind"]), (1, 1, "var-random-alternatives"))
        jump = [cmd(23, "bundle:asset"), cmd(TEXT)]
        self.assertEqual(coverage.first_static_halt(jump, NAMES)[1]["kind"], "external-file-jump")
        branch = [cmd(14, "a", "0", "b", "file:tag", "local"), cmd(TEXT)]
        self.assertEqual(coverage.first_static_halt(branch, NAMES)[1]["index"], 1)  # A branch is not certain.
        self.assertEqual(coverage.argument_limits(branch)[0]["kind"], "if-external-branch")
        self.assertEqual(coverage.first_static_halt([cmd(22)], NAMES), (None, None))

    def test_analysis_counts_blockers_families_and_greedy_order(self):
        bundles = [bundle("c00/00.unity3d", [cmd(LOOK), cmd(TEXT)], [cmd(LOOK), cmd(VOICE), cmd(TEXT)], []),
                   bundle("op/00.unity3d", [cmd(1, "System.Int32", "x", "1", multi=True), cmd(TEXT), cmd(22)], [cmd(22)])]
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
        self.assertEqual((rows[TEXT]["firstBlockerAssets"], rows[TEXT]["soleBlockerAssets"]), (1, 1))
        self.assertEqual((rows[TEXT]["family"], rows[LOOK]["family"], rows[1]["native"]), ("Base", "Chara", "implemented"))
        self.assertEqual([row["id"] for row in result["firstBlockerRanking"]], [LOOK, TEXT])
        families = {row["family"]: row for row in result["families"]}
        self.assertEqual((families["Chara"]["firstBlockerAssets"], families["Base"]["assets"]), (2, 4))
        steps = result["greedyImplementationOrder"]
        self.assertEqual([(s["id"], s["firstBlockerAssets"], s["executableByIDAfter"]) for s in steps],
                         [(LOOK, 2, 2), (TEXT, 2, 4), (VOICE, 1, 5)])
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
        program = [cmd(14, "a", "0", "b", "yes", "no"), cmd(12, "yes", multi=True), cmd(TEXT),
                   cmd(12, "no", multi=True), cmd(VOICE)]
        outcomes, loop, transfers = coverage.reachable_outcomes(program)
        self.assertIn(dict(status="faulted", pc=2, id=TEXT), outcomes)
        self.assertIn(dict(status="faulted", pc=4, id=VOICE), outcomes)
        self.assertIn(dict(status="faulted", pc=0, id=14), outcomes)  # Value-dependent IF fault.
        self.assertFalse(loop)
        self.assertEqual(transfers, [0])

    def test_missing_tag_continues_and_close_terminates(self):
        program = [cmd(23, "absent"), cmd(22), cmd(TEXT)]
        outcomes, _, transfers = coverage.reachable_outcomes(program)
        self.assertEqual(outcomes, [dict(status="closed", pc=None, id=None)])
        self.assertEqual(transfers, [])

    def test_backward_jump_is_a_loop_and_end_is_exhaustion(self):
        outcomes, loop, _ = coverage.reachable_outcomes([cmd(12, "top", multi=True), cmd(25, "1"), cmd(23, "top")])
        self.assertTrue(loop)
        self.assertEqual(outcomes, [])
        self.assertEqual(coverage.reachable_outcomes([cmd(25, "1")])[0], [dict(status="exhausted", pc=None, id=None)])

    def test_variable_named_target_may_reach_any_tag(self):
        program = [cmd(1, "System.String", "next", "later", multi=True), cmd(23, "next"), cmd(TEXT),
                   cmd(12, "later", multi=True), cmd(VOICE)]
        outcomes, _, _ = coverage.reachable_outcomes(program)
        self.assertIn(dict(status="faulted", pc=1, id=23), outcomes)
        self.assertIn(dict(status="faulted", pc=2, id=TEXT), outcomes)
        self.assertIn(dict(status="faulted", pc=4, id=VOICE), outcomes)

    def test_straight_line_and_strata(self):
        straight = [cmd(1, "System.Int32", "a", "1", multi=True), cmd(25, "1"), cmd(TEXT)]
        _, halt = coverage.first_static_halt(straight, NAMES)
        self.assertTrue(coverage.straight_line(straight, halt))
        record = dict(firstStaticHalt=halt)
        self.assertEqual(coverage.stratum(record, straight), "wait-prefix")
        reference = [cmd(1, "System.Int32", "a", "*b", multi=True), cmd(TEXT)]
        self.assertFalse(coverage.straight_line(reference, coverage.first_static_halt(reference, NAMES)[1]))
        branch = [cmd(23, "t"), cmd(TEXT), cmd(12, "t", multi=True), cmd(VOICE)]
        self.assertEqual(coverage.stratum(dict(firstStaticHalt=coverage.first_static_halt(branch, NAMES)[1]), branch), "branch-before")
        sequential = [cmd(23, "t"), cmd(12, "t", multi=True), cmd(TEXT)]  # The tag follows the jump.
        self.assertEqual(coverage.stratum(dict(firstStaticHalt=coverage.first_static_halt(sequential, NAMES)[1]), sequential),
                         "control-flow-before")
        self.assertEqual(coverage.stratum(dict(firstStaticHalt=None), []), "empty")

    def test_mutation_moves_expected_halt(self):
        program = [cmd(TEXT, "x"), cmd(1, "System.Int32", "a", "1", multi=True), cmd(VOICE)]
        mutated = coverage.mutate_halt(program, 0)
        self.assertEqual((mutated[0]["id"], mutated[0]["args"], program[0]["id"]), (0, [], TEXT))
        self.assertEqual(coverage.first_static_halt(mutated, NAMES)[1]["index"], 2)


class SampleTests(unittest.TestCase):
    def test_sample_is_deterministic_and_spread(self):
        assets = [[cmd(TEXT)], [cmd(VOICE)], [cmd(1, "System.Int32", "a", "1", multi=True), cmd(TEXT)], [cmd(22)], []]
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
        self.program = [cmd(14, "a", "0", "b", "yes", "no"), cmd(12, "yes", multi=True), cmd(TEXT),
                        cmd(12, "no", multi=True), cmd(VOICE)]
        self.result = coverage.analyse([bundle("c00/00.unity3d", self.program)], NAMES, HANDLERS)
        self.record = self.result["assets"][0]

    def test_observe_detects_non_sequential_batches(self):
        fault = dict(pc=4, commandID=VOICE, reason="Unsupported source gameplay operation: ADV command ID 17 at pc 4")
        observed = coverage.observe(self.program, [snapshot(5, "faulted", fault)])
        self.assertEqual((observed["faultPC"], observed["observedJumpBatchStarts"]), (4, [0]))
        sequential = [cmd(1, "System.Int32", "a", "1"), cmd(25, "1"), cmd(TEXT)]
        observed = coverage.observe(sequential, [snapshot(1, "frameBoundary"), snapshot(2, "waiting"),
                                                 snapshot(3, "faulted", dict(pc=2, commandID=TEXT, reason="r"))])
        self.assertEqual(observed["observedJumpBatchStarts"], [])

    def test_classify_match_value_fault_and_control_flow(self):
        reason = "Unsupported source gameplay operation: ADV command ID 16 at pc 2"
        match = coverage.observe(self.program, [snapshot(3, "faulted", dict(pc=2, commandID=TEXT, reason=reason))])
        self.assertEqual(coverage.classify(self.record, match)[0], "match")
        jumped = coverage.observe(self.program, [snapshot(5, "faulted", dict(pc=4, commandID=VOICE, reason="ADV command ID 17 at pc 4"))])
        self.assertEqual(coverage.classify(self.record, jumped)[0], "control-flow-different-halt")
        value = coverage.observe(self.program, [snapshot(1, "faulted", dict(pc=0, commandID=14, reason="Extended/scientific IF literal"))])
        self.assertEqual(coverage.classify(self.record, value), ("value-dependent-fault",
                         "extended-literal at implemented command 14 (pc 0) under default inputs"))
        wrong = coverage.observe(self.program, [snapshot(3, "faulted", dict(pc=2, commandID=TEXT, reason="other"))])
        self.assertEqual(coverage.classify(self.record, wrong)[0], "match-position-reason-differs")

    def test_compare_joins_reports_and_checks_reachability(self):
        trace = dict(cases=[coverage.trace_case("c00/00.unity3d", dict(name="0", pathID=1, commands=self.program))])
        reason = "Unsupported source gameplay operation: ADV command ID 16 at pc 2"
        report = dict(cases=[dict(name="c00/00.unity3d#1", snapshots=[snapshot(3, "faulted", dict(pc=2, commandID=TEXT, reason=reason))])])
        result = coverage.compare(self.result, [(trace, report)])
        self.assertEqual(result["summary"]["categories"], {"match": 1})
        self.assertEqual(result["summary"]["observedOutsideReachableOutcomes"], 0)
        bad = dict(cases=[dict(name="c00/00.unity3d#1", snapshots=[snapshot(2, "faulted", dict(pc=1, commandID=12, reason="x"))])])
        self.assertEqual(coverage.compare(self.result, [(trace, bad)])["summary"]["observedOutsideReachableOutcomes"], 1)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            coverage.compare(self.result, [(trace, report), (trace, report)])


class ScanTests(unittest.TestCase):
    def test_scan_checks_provenance_and_orders_assets(self):
        rows = [dict(_hash=1, _version=0, _multi=0, _command=TEXT, _args=["x"])]
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
            self.assertEqual(scanned["assets"][1]["commands"], [dict(hash=1, version=0, multi=False, id=TEXT, args=["x"])])
            (root / "c00/00.unity3d.provenance.json").write_text(json.dumps(dict(sha256="0" * 64, length=6)))
            with patch.object(coverage, "mono_records", return_value=records), self.assertRaisesRegex(ValueError, "provenance"):
                coverage.scan_bundle(path, root)


if __name__ == "__main__":
    unittest.main()
