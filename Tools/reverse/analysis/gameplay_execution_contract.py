"""Recover local gameplay tables and source ADV records; emit independent fixtures.

All source output belongs in ignored .local. The selected managed-recovery index
and per-type compatibility overrides are authoritative, not older decompilations.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

PERIODS = ["起床", "朝", "登校", "朝ホームルーム", "授業1", "昼休み", "授業2", "帰りホームルーム", "部活時間", "放課後", "帰宅", "自宅"]
WEEKS = ["月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日", "休日"]
WEEK_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Holiday"]
CLASSES = {"1-1": 0, "2-1": 1, "2-2": 2, "3-1": 3}
SUPPORTED = {0, 1, 3, 4, 12, 14, 15, 22, 23, 25}


def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def selected_source(index_path, type_name):
    index = json.loads(Path(index_path).read_text())
    assembly = next(a for a in index["assemblies"] if "Koikatu_Data/Managed/Assembly-CSharp.dll" in a["sourcePaths"])
    directory = Path(assembly["directory"])
    manifest = json.loads((directory / "manifest.json").read_text())
    overrides = {item["type"]: item for item in manifest.get("typeOverrides", [])}
    if type_name in overrides:
        selected = directory / overrides[type_name]["file"]
    else:
        namespace, _, name = type_name.rpartition(".")
        roots = [directory / assembly["selectedProject"] / namespace, directory / assembly["selectedProject"] / namespace.replace(".", "/")]
        selected = next((root / (name + ".cs") for root in roots if (root / (name + ".cs")).is_file()), None)
        if selected is None:
            raise ValueError("Missing selected recovered type: " + type_name)
    text = selected.read_text()
    if "Error decompiling" in text or "throw new NotImplementedException" in text:
        raise ValueError("Selected recovered source contains a decompiler stub: " + type_name)
    return selected, text


def source_evidence(index_path):
    types = ["ActionGame.FixEventScheduler", "ActionGame.FixEventSchedule", "ActionGame.Cycle", "ActionGame.CycleExtensions",
             "ClassSchedule", "Manager.Game", "ADV.ScenarioData", "ADV.Command", "ADV.CommandBase", "ADV.CommandList",
             "ADV.TextScenario", "ADV.ValData", "Illusion.Utils"]
    types += ["ADV.Commands.Base." + name for name in ["VAR", "Calc", "Clamp", "IF", "Switch", "Jump", "Tag", "Wait", "Close"]]
    result = []
    for name in types:
        path, _ = selected_source(index_path, name)
        result.append(dict(type=name, path=str(path), sha256=digest(path)))
    _, text = selected_source(index_path, "ADV.Command")
    commands = [s.strip() for s in re.search(r"enum Command\s*\{(.*?)\}", text, re.S).group(1).split(",") if s.strip()]
    expected = {0: "None", 1: "VAR", 3: "Calc", 4: "Clamp", 12: "Tag", 14: "IF", 15: "Switch", 22: "Close", 23: "Jump", 25: "Wait"}
    if any(commands[index] != name for index, name in expected.items()):
        raise ValueError("Command ordinals differ from translated source contract")
    return result, commands


def mono_records(path, expected_class):
    import UnityPy
    for reader in UnityPy.load(str(path)).objects:
        if reader.type.name != "MonoBehaviour": continue
        tree = reader.read_typetree()
        obj = reader.read()
        script = obj.m_Script.read()
        if script.m_ClassName != expected_class: continue
        yield reader.path_id, tree


def convert_fixed(raw):
    return dict(asset=raw["Asset"], bundle=raw["Bundle"], isVisible=bool(raw["isVisible"]), cycles=raw["Cycle"],
                map=raw["Map"], weeks=raw["Week"], layerName=raw["LayerName"], coordinate=raw["Coordinate"], afterDay=raw["AfterDay"])


def evaluate_fixed(rows, context):
    """Evaluate original uppercase-field records directly, not converted rows."""
    if context["isTaked"]: return None
    for index, row in enumerate(rows):
        event = int(row["Asset"])
        if event in context["completedEvents"]: continue
        if context["eventAfterDay"] < row["AfterDay"]: return None
        weeks = row["Week"]
        if weeks:
            if "平日" in weeks:
                if context["week"] > 4: return None
            elif WEEKS[context["week"]] not in weeks: return None
        if PERIODS[context["period"]] not in row["Cycle"]: return None
        map_no = context["mapNumbers"].get(row["Map"], -1)
        if row["LayerName"] and context["period"] in (5, 8, 9):
            for point in context["waitPoints"]:
                if point["mapNo"] != map_no: continue
                for layer_index, layer in enumerate(point["layers"]):
                    if layer == row["LayerName"]:
                        return dict(entryIndex=index, assetID=event, mapNo=point["mapNo"], waitPointID=point["id"], layerIndex=layer_index)
            return None
        if context["period"] in (4, 6):
            lesson = context["lessons"][0 if context["period"] == 4 else 1]
            if lesson not in row["Map"]: return None
        return dict(entryIndex=index, assetID=event, mapNo=map_no, waitPointID=None, layerIndex=-1)
    return None


def extract_tables(class_bundle, fixed_bundles):
    classes, schedules, originals, evidence = [], [], [], []
    for path_id, raw in mono_records(class_bundle, "ClassSchedule"):
        days = []
        for row in raw["param"]:
            lessons = [row["Lesson1"], row["Lesson2"]]
            days.append(dict(week=WEEK_NAMES.index(row["Week"]), lessons=[s if s.strip() else "教室" for s in lessons]))
        classes.append(dict(classIndex=CLASSES[raw["m_Name"]], days=days, sourcePathID=path_id))
    evidence.append(dict(path=str(class_bundle), sha256=digest(class_bundle)))
    for path in fixed_bundles:
        for path_id, raw in mono_records(path, "FixEventSchedule"):
            schedules.append(dict(heroineID=int(raw["m_Name"]), entries=[convert_fixed(row) for row in raw["param"]], sourcePathID=path_id))
            originals.append((int(raw["m_Name"]), raw["param"]))
        evidence.append(dict(path=str(path), sha256=digest(path)))
    return dict(schemaVersion=1, schedules=schedules, classSchedules=classes, sourceEvidence=evidence), originals


def scheduler_reference(originals):
    maps = sorted({row["Map"] for _, rows in originals for row in rows})
    map_numbers = {name: index for index, name in enumerate(maps)}
    cases = []
    for heroine, rows in originals:
        for row_index, row in enumerate(rows):
            for week in range(7):
                for period in range(12):
                    context = dict(isTaked=False, eventAfterDay=row["AfterDay"], completedEvents=[int(r["Asset"]) for r in rows[:row_index]],
                                   week=week, period=period, mapNumbers=map_numbers,
                                   waitPoints=[dict(id="fixture-point", mapNo=map_numbers[row["Map"]], layers=["other", row["LayerName"], row["LayerName"]])],
                                   lessons=[row["Map"], row["Map"]])
                    cases.append(dict(name=f"{heroine}-{row_index}-{week}-{period}", heroineID=heroine, context=context, expected=evaluate_fixed(rows, context)))
    return dict(schemaVersion=1, contextProvenance="Synthetic contexts evaluated against original extracted records", cases=cases)


def extract_scenario(path, name, command_names):
    records = list(mono_records(path, "ScenarioData"))
    matching = [(path_id, raw) for path_id, raw in records if raw["m_Name"] == name]
    if len(matching) != 1: raise ValueError("Expected exactly one requested ScenarioData asset")
    path_id, raw = matching[0]
    commands = [dict(hash=row["_hash"], version=row["_version"], multi=bool(row["_multi"]), id=row["_command"], args=row["_args"]) for row in raw["list"]]
    metadata = [dict(name=tree["m_Name"], pathID=pid, commandCount=len(tree["list"]),
                     commandIDs=sorted(set(row["_command"] for row in tree["list"]))) for pid, tree in records]
    return dict(schemaVersion=1, name=name, commands=commands,
                source=dict(bundle=str(path), sha256=digest(path), pathID=path_id),
                unsupportedCommands=[dict(pc=i, id=c["id"], name=command_names[c["id"]]) for i,c in enumerate(commands) if c["id"] not in SUPPORTED]), metadata


def command(id, args=(), multi=False): return dict(hash=0, version=0, multi=multi, id=id, args=list(args))


def adv_fixtures():
    """Hand-derived source outcomes, independent of the Swift interpreter."""
    def value(type, text): return dict(type="System." + type, value=str(float(text)) if type == "Single" else text)
    def case(name, commands, ticks, expected, variables=None):
        return dict(name=name, program=dict(schemaVersion=1, name=name, commands=commands), variables=variables or {}, ticks=ticks, expected=expected)
    def state(pc, variables, status, waits=(), fault_pc=None):
        return dict(pc=pc, variables=variables, status=status, waitElapsed=list(waits), faultPC=fault_pc)
    counter = {"counter": value("Int32", "3")}
    cases = [case("loop-branch-wait", [command(1,["System.Int32","counter","0"],True), command(12,["loop"],True),
             command(3,["counter","1","1"],True), command(14,["counter","5","3","loop","done"]),
             command(12,["done"],True), command(25,["0.5"]), command(1,["System.Boolean","finished","True"],True),command(22)],
             [dict(deltaTime=.25),dict(deltaTime=.25)],
             [state(6,counter,"waiting",[0]),state(6,counter,"waiting",[.25]),state(8,{**counter,"finished":value("Boolean","True")},"closed")]),
        case("cancel-multi-wait", [command(25,["2"],True),command(25,["1"]),command(22)],
             [dict(deltaTime=1),dict(deltaTime=0,requestNext=True)],
             [state(2,{},"waiting",[0,0]),state(2,{},"waiting",[1]),state(3,{},"closed")]),
        case("calc-left-to-right", [command(3,["result","0","2","0","3","2","4"]),command(22)], [dict(deltaTime=0)],
             [state(1,{"result":value("Int32","20")},"frameBoundary"),state(2,{"result":value("Int32","20")},"closed")]),
        case("var-captures-before-replace", [command(1,["System.Int32","destination","source"]),command(22)], [],
             [state(1,{"destination":value("Int32","0"),"source":value("Int32","7")},"frameBoundary")],
             {"destination":value("String","renamed"),"source":value("Int32","7")}),
        case("var-double-reference", [command(1,["System.Int32","copy","**indirect"]),command(22)], [],
             [state(1,{"indirect":value("String","number"),"number":value("Int32","12"),"copy":value("Int32","12")},"frameBoundary")],
             {"indirect":value("String","number"),"number":value("Int32","12")}),
        case("switch-raw-target", [command(15,["route","2,found","fallback"]),command(12,["found"],True),command(22)], [],
             [state(3,{"route":value("Int32","2"),"found":value("String","missing")},"closed")],
             {"route":value("Int32","2"),"found":value("String","missing")}),
        case("missing-tag-continues", [command(23,["absent"]),command(22)], [dict(deltaTime=0)],
             [state(1,{},"frameBoundary"),state(2,{},"closed")]),
        case("unsupported-command", [command(165,["field","value"])], [], [state(1,{},"faulted",fault_pc=0)]),
        case("external-jump", [command(23,["bundle:file"])], [], [state(1,{},"faulted",fault_pc=0)]),
        case("bool-multiply-is-or", [command(3,["flag","3","True"]),command(22)], [],
             [state(1,{"flag":value("Boolean","True")},"frameBoundary")], {"flag":value("Boolean","False")}),
        case("clamp-replaces-values-not-answer", [command(4,["answer","input","0","100"]),command(22)], [],
             [state(1,{"answer":value("Single","100"),"input":value("Int32","150")},"frameBoundary")],
             {"answer":value("String","renamed"),"input":value("Int32","150")}),
        case("boxed-single-int-cast-fails", [command(1,["System.Int32","output","*input"])], [],
             [state(1,{"input":value("Single","1.5")},"faulted",fault_pc=0)], {"input":value("Single","1.5")}),
    ]
    # A tag's label is replaced too; for the Switch test use a separate variable
    # to demonstrate captured destination behavior without rewriting the label.
    cases[5] = case("switch-default", [command(15,["route","1,absent","fallback"]),command(12,["fallback"],True),command(22)], [],
                   [state(3,{"route":value("Int32","2")},"closed")], {"route":value("Int32","2")})
    return dict(schemaVersion=1, cases=cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recovery-index", type=Path, required=True)
    parser.add_argument("--class-bundle", type=Path, required=True)
    parser.add_argument("--fixed-bundle", type=Path, action="append", required=True)
    parser.add_argument("--scenario-bundle", type=Path)
    parser.add_argument("--scenario-name", default="301")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    evidence, commands = source_evidence(args.recovery_index)
    table, originals = extract_tables(args.class_bundle, args.fixed_bundle)
    reference = scheduler_reference(originals)
    outputs = {"fixed-events.json": table, "scheduler-reference.json": reference, "adv-reference.json": adv_fixtures()}
    outputs["fixed-event-trace.json"] = dict(tablePath="fixed-events.json", cases=reference["cases"])
    if args.scenario_bundle:
        program, metadata = extract_scenario(args.scenario_bundle, args.scenario_name, commands)
        outputs["original-parameter-" + args.scenario_name + ".json"] = program
        outputs["original-parameter-trace.json"] = dict(cases=[dict(name="original-parameter-" + args.scenario_name,
            program=program,variables={},ticks=[dict(deltaTime=0)])])
        outputs["scenario-inventory.json"] = metadata
    contract = dict(schemaVersion=1, sourceEvidence=evidence, commandNames=commands,
                    supportedCommandIDs=sorted(SUPPORTED), fixedScheduleCount=len(table["schedules"]),
                    fixedEventCount=sum(len(s["entries"]) for s in table["schedules"]),
                    classScheduleCount=len(table["classSchedules"]), schedulerCaseCount=len(reference["cases"]),
                    advCaseCount=len(outputs["adv-reference.json"]["cases"]))
    outputs["contract.json"] = contract
    args.output.mkdir(parents=True, exist_ok=True)
    for name, value in outputs.items():
        (args.output/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({key: value for key,value in contract.items() if key not in ("sourceEvidence","commandNames")}, indent=2))


if __name__ == "__main__": main()
