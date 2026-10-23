#!/usr/bin/env python3
"""Measure original ADV ScenarioData command coverage against the native kernel.

`scan` reads every ScenarioData MonoBehaviour in the given scenario bundles,
names command ordinals with the recovered ADV.Command enum and the handler
classes constructed by CommandList.CommandGet, and writes:

* coverage.json: bundle hashes, per-asset ordered command IDs, the static first
  unsupported command, per-command and per-handler-namespace usage, first-blocker
  ranking and a greedy implementation order;
* traces/trace-NNN.json: `ikkoku-inspect adv-trace` inputs carrying the original
  arguments and default inputs (no preset variables, fixed frame steps) with a
  scripted host that acknowledges every blocking request and presses Next
  whenever a Text batch waits for it;
* sample.json: a deterministic stratified sample with static predictions for
  the gated Engine halting test.

Presentation commands are modelled independently in `adv_host_requests.py`:
an argument form that definitely throws (or is not modelled) under default
inputs is a certain static halt, like an unsupported command.

`compare` joins `adv-trace` reports with the static predictions, classifies
every observed halt and checks every observed host request (kind, blocking
policy and arguments) against the independent model. The static prediction
ignores runtime values: control flow and value-dependent faults can make the
dynamic first halt differ.

All outputs contain original scenario data and belong in ignored `.local/`.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re

try:  # Run as a script or from Tools/reverse/analysis.
    from gameplay_execution_contract import SUPPORTED, MissingRecoveredSource, RecoveredErrorStub, command_enum, digest, mono_records, recovered_project, selected_source
    import adv_host_requests as host
except ImportError:  # Imported as analysis.adv_command_coverage from Tools/reverse.
    from analysis.gameplay_execution_contract import SUPPORTED, MissingRecoveredSource, RecoveredErrorStub, command_enum, digest, mono_records, recovered_project, selected_source
    from analysis import adv_host_requests as host

CONTROL_FLOW = {14, 15, 22, 23}  # IF, Switch, Close, Jump
VAR_TYPES = {"System.Int32", "System.Single", "System.Boolean", "System.String"}
FRAME_SECONDS = 1000.0  # One default frame completes any finite source Wait.
TICK_SLACK = 4
HANDLER = re.compile(r"Command\.(\w+)\s*=>\s*(?:\(CommandBase\)\s*)?new\s+([\w.]+)\s*\(\s*\)")
FAULT_REASONS = {"unsupported-command": "ADV command ID {id} at pc {index}",
                 "var-random-alternatives": "VAR random alternatives",
                 "external-file-jump": "External ADV file jump"} | {kind: text.replace("{site}", "<site>")
                                                                     for kind, text in host.Fault.REASONS.items()}
TERMINAL = {"faulted", "closed", "exhausted"}
SCRIPTED_HOST = dict(autoAcknowledge=True, autoNext=True, mapVariables={}, sceneFadeRegulate=True)


def command_handlers(text, exists):
    """Map Command member names to fully qualified CommandGet handler classes.

    Unqualified names resolve as C# does for this file: a member of the
    enclosing `ADV` namespace wins, otherwise exactly one `using` namespace.
    """
    switch = text[text.index("CommandGet"):]
    usings = re.findall(r"^using\s+(ADV(?:\.\w+)+)\s*;", text, re.M)
    handlers = {}
    for member, cls in HANDLER.findall(switch):
        if "." in cls:
            handlers[member] = cls
            continue
        if exists("ADV." + cls):
            handlers[member] = "ADV." + cls
            continue
        found = [ns + "." + cls for ns in usings if exists(ns + "." + cls)]
        if len(found) != 1:
            raise ValueError(f"Cannot resolve handler {cls} for Command.{member}: {found}")
        handlers[member] = found[0]
    return handlers


def command_tables(index_path):
    project = recovered_project(index_path)

    def exists(type_name):
        # A stubbed type still exists for C# name lookup; it is never read as
        # input. Hash, ambiguity and manifest failures propagate.
        try:
            selected_source(index_path, type_name, project)
            return True
        except RecoveredErrorStub:
            return True
        except MissingRecoveredSource:
            return False

    enum_path, enum_text = selected_source(index_path, "ADV.Command", project)
    list_path, list_text = selected_source(index_path, "ADV.CommandList", project)
    names = command_enum(enum_text)
    handlers = command_handlers(list_text, exists)
    unknown = sorted(set(handlers) - set(names))
    if unknown:
        raise ValueError("CommandGet names absent from ADV.Command: " + ", ".join(unknown))
    evidence = [dict(type="ADV.Command", path=str(enum_path), sha256=digest(enum_path)),
                dict(type="ADV.CommandList", path=str(list_path), sha256=digest(list_path))]
    evidence += model_source_checks(index_path, project, names, handlers)
    return names, handlers, evidence


def enum_members(text, name):
    body = re.search(r"enum " + name + r"\s*\{(.*?)\}", text, re.S).group(1)
    members = [m.strip() for m in body.split(",") if m.strip()]
    if any(not re.fullmatch(r"\w+", m) for m in members):
        raise ValueError(f"enum {name} has explicit values or unexpected members")
    return members


def model_source_checks(index_path, project, names, handlers):
    """The presentation model's handler classes and enum name tables match the recovered source."""
    for cid, handler in host.HANDLERS.items():
        if handlers.get(command_name(cid, names)) != handler:
            raise ValueError(f"CommandGet maps {command_name(cid, names)} to {handlers.get(command_name(cid, names))}, model says {handler}")
    evidence = []
    for type_name, enum, expected in (("Illusion.Game.BGM", "BGM", host.BGM_NAMES), ("Manager.Scene", "FadeType", host.FADE_TYPES),
                                      ("ADV.Commands.Base.NullSet", "Type", host.NULL_TARGETS)):
        path, text = selected_source(index_path, type_name, project)
        if enum_members(text, enum) != expected:
            raise ValueError(f"{type_name}.{enum} names differ from the presentation model")
        evidence.append(dict(type=type_name, path=str(path), sha256=digest(path)))
    for cid, handler in sorted(host.HANDLERS.items()):
        path, _ = selected_source(index_path, handler, project)
        evidence.append(dict(type=handler, path=str(path), sha256=digest(path)))
    return evidence


def scan_bundle(path, root):
    """Read one bundle's ScenarioData records (with arguments) and its hashes."""
    path = Path(path)
    data = path.read_bytes()
    sha256 = hashlib.sha256(data).hexdigest()
    provenance_path = path.with_name(path.name + ".provenance.json")
    provenance = None
    if provenance_path.is_file():
        record = json.loads(provenance_path.read_text())
        if record.get("sha256") != sha256 or record.get("length") != len(data):
            raise ValueError("Bundle differs from its transfer provenance: " + str(path))
        provenance = dict(source=record.get("source"), vm=record.get("vm"))
    assets = []
    for path_id, tree in mono_records(path, "ScenarioData"):
        commands = [dict(hash=int(row["_hash"]), version=int(row["_version"]), multi=bool(row["_multi"]),
                         id=int(row["_command"]), args=[str(arg) for arg in row["_args"]]) for row in tree["list"]]
        assets.append(dict(name=tree["m_Name"], pathID=int(path_id), commands=commands))
    assets.sort(key=lambda asset: asset["pathID"])
    return dict(path=path.relative_to(root).as_posix(), sha256=sha256, bytes=len(data), provenance=provenance, assets=assets)


def native_status(command_id, names, handlers, supported=SUPPORTED):
    if command_id in supported:
        return "implemented"
    if not 0 <= command_id < len(names):
        return "unknown-ordinal"
    if names[command_id] not in handlers:
        return "no-original-handler"  # CommandGet returns null; the original skips it.
    return "unsupported"


def argument_limits(commands, supported=SUPPORTED):
    """Native argument-level limits inside implemented commands, from raw arguments.

    `certain` limits fault whenever executed; branch targets only on that
    branch. A presentation command whose arguments name a scenario-assigned
    variable has a value-dependent (uncertain) limit: ReplaceVars may change
    its arguments at run time.
    """
    limits, assigned = [], host.assigned_names(commands)
    for index, command in enumerate(commands):
        cid, args = command["id"], command["args"]
        if cid == 1 and len(args) > 3:
            limits.append(dict(index=index, id=cid, kind="var-random-alternatives", certain=True))
        elif cid == 23 and args and ":" in args[0]:
            limits.append(dict(index=index, id=cid, kind="external-file-jump", certain=True))
        elif cid == 14 and any(":" in target for target in args[3:5]):
            limits.append(dict(index=index, id=cid, kind="if-external-branch", certain=False))
        elif cid == 15 and any(":" in item.split(",")[-1] for item in args[1:]):
            limits.append(dict(index=index, id=cid, kind="switch-external-branch", certain=False))
        elif cid in host.PRESENTATION and cid in supported:
            dependent = host.touches(command, assigned)
            try:
                host.evaluate(command)
            except host.Fault as fault:
                limits.append(dict(index=index, id=cid, kind=fault.kind, site=fault.site, reason=fault.reason, certain=not dependent))
                continue
            if dependent:
                limits.append(dict(index=index, id=cid, kind="value-dependent-argument", certain=False))
    return limits


def halt_reason(halt):
    return halt.get("reason") or FAULT_REASONS[halt["kind"]].format(**halt)


def first_static_halt(commands, names, supported=SUPPORTED):
    """First command, in program order, that the native kernel cannot execute.

    This ignores control flow and runtime values by design.
    """
    unsupported = next((dict(index=i, id=c["id"], name=command_name(c["id"], names), kind="unsupported-command")
                        for i, c in enumerate(commands) if c["id"] not in supported), None)
    certain = next((dict(index=l["index"], id=l["id"], name=command_name(l["id"], names), kind=l["kind"])
                    | ({"site": l["site"], "reason": l["reason"]} if "site" in l else {})
                    for l in argument_limits(commands, supported) if l["certain"]), None)
    for halt in (unsupported, certain):
        if halt:
            halt["reason"] = halt_reason(halt)
    candidates = [halt for halt in (unsupported, certain) if halt]
    return unsupported, (min(candidates, key=lambda halt: halt["index"]) if candidates else None)


def command_name(command_id, names):
    return names[command_id] if 0 <= command_id < len(names) else f"#{command_id}"


def family_of(command_id, names, handlers):
    handler = handlers.get(command_name(command_id, names))
    if handler is None:
        return "(no handler)"
    namespace = handler.rpartition(".")[0]
    return namespace.removeprefix("ADV.Commands.") if namespace != "ADV" else "ADV"


def asset_record(bundle, asset, names, supported=SUPPORTED):
    commands = asset["commands"]
    ids = [c["id"] for c in commands]
    unsupported, halt = first_static_halt(commands, names, supported)
    halt_index = halt["index"] if halt else len(ids)
    unsupported_index = unsupported["index"] if unsupported else len(ids)
    return dict(bundle=bundle["path"], bundleSHA256=bundle["sha256"], name=asset["name"], pathID=asset["pathID"],
                commandCount=len(ids), commandIDs=ids, unsupportedIDs=sorted({i for i in ids if i not in supported}),
                firstUnsupported=unsupported, firstStaticHalt=halt, argumentLimits=argument_limits(commands, supported),
                executableByID=unsupported is None, staticExecutable=halt is None,
                controlFlowBeforeFirstUnsupported=any(i in CONTROL_FLOW for i in ids[:unsupported_index]),
                controlFlowBeforeFirstStaticHalt=any(i in CONTROL_FLOW for i in ids[:halt_index]))


def first_blocker(ids, implemented):
    return next((cid for cid in ids if cid not in implemented), None)


def greedy_order(records, names, supported=SUPPORTED, steps=15):
    """Repeatedly implement the command that is the first blocker of most assets."""
    implemented, order = set(supported), []
    for _ in range(steps):
        counts = Counter(first_blocker(r["commandIDs"], implemented) for r in records)
        counts.pop(None, None)
        if not counts:
            break
        cid, count = max(counts.items(), key=lambda item: (item[1], -item[0]))
        implemented.add(cid)
        order.append(dict(step=len(order) + 1, id=cid, name=command_name(cid, names), firstBlockerAssets=count,
                          executableByIDAfter=sum(all(i in implemented for i in r["commandIDs"]) for r in records),
                          staticPrefixCommandsAfter=sum(next((n for n, i in enumerate(r["commandIDs"]) if i not in implemented),
                                                             r["commandCount"]) for r in records)))
    return order


def prefix_bucket(record):
    halt = record["firstUnsupported"]
    if halt is None:
        return "none"
    index = halt["index"]
    for low, high in ((0, 0), (1, 1), (2, 4), (5, 9), (10, 19)):
        if low <= index <= high:
            return str(low) if low == high else f"{low}-{high}"
    return "20+"


def corpus_digest(bundles):
    """SHA-256 over sorted `relative-path sha256` lines identifying the bundle set."""
    lines = "".join(f"{b['path']} {b['sha256']}\n" for b in sorted(bundles, key=lambda b: b["path"]))
    return hashlib.sha256(lines.encode()).hexdigest()


def analyse(bundles, names, handlers, supported=SUPPORTED, greedy_steps=15):
    records = [asset_record(bundle, asset, names, supported) for bundle in bundles for asset in bundle["assets"]]
    uses, assets, first, sole = Counter(), Counter(), Counter(), Counter()
    for r in records:
        uses.update(r["commandIDs"])
        assets.update(set(r["commandIDs"]))
        if r["firstUnsupported"]:
            first[r["firstUnsupported"]["id"]] += 1
        if len(r["unsupportedIDs"]) == 1:
            sole[r["unsupportedIDs"][0]] += 1
    commands = []
    for cid in sorted(uses):
        name = command_name(cid, names)
        commands.append(dict(id=cid, name=name, handler=handlers.get(name), family=family_of(cid, names, handlers),
                             native=native_status(cid, names, handlers, supported), uses=uses[cid], assets=assets[cid],
                             firstBlockerAssets=first[cid], soleBlockerAssets=sole[cid]))
    family_uses, family_assets, family_first = Counter(), Counter(), Counter()
    for r in records:
        family_uses.update(family_of(cid, names, handlers) for cid in r["commandIDs"])
        family_assets.update({family_of(cid, names, handlers) for cid in r["commandIDs"]})
        if r["firstUnsupported"]:
            family_first[family_of(r["firstUnsupported"]["id"], names, handlers)] += 1
    families = [dict(family=f, uses=family_uses[f], assets=family_assets[f], firstBlockerAssets=family_first[f],
                     commandIDs=sorted(c["id"] for c in commands if c["family"] == f),
                     unsupportedCommandIDs=sorted(c["id"] for c in commands if c["family"] == f and c["native"] != "implemented"))
                for f in sorted(family_uses, key=lambda f: (-family_first[f], -family_uses[f], f))]
    directories = defaultdict(lambda: dict(bundles=set(), assets=0, commands=0, executableByID=0, staticExecutable=0, firstBlockers=Counter()))
    for r in records:
        d = directories[r["bundle"].split("/")[0]]
        d["bundles"].add(r["bundle"])
        d["assets"] += 1
        d["commands"] += r["commandCount"]
        d["executableByID"] += r["executableByID"]
        d["staticExecutable"] += r["staticExecutable"]
        if r["firstUnsupported"]:
            d["firstBlockers"][r["firstUnsupported"]["id"]] += 1
    directory_rows = [dict(directory=k, bundles=len(v["bundles"]), assets=v["assets"], commands=v["commands"],
                           executableByID=v["executableByID"], staticExecutable=v["staticExecutable"],
                           topFirstBlocker=(dict(id=v["firstBlockers"].most_common(1)[0][0],
                                                 name=command_name(v["firstBlockers"].most_common(1)[0][0], names),
                                                 assets=v["firstBlockers"].most_common(1)[0][1]) if v["firstBlockers"] else None))
                      for k, v in sorted(directories.items())]
    total_commands = sum(r["commandCount"] for r in records)
    limit_kinds = Counter(l["kind"] for r in records for l in r["argumentLimits"])
    totals = dict(bundles=len(bundles), bundleBytes=sum(b["bytes"] for b in bundles), corpusSHA256=corpus_digest(bundles), assets=len(records),
                  emptyAssets=sum(r["commandCount"] == 0 for r in records), commands=total_commands,
                  distinctCommandIDs=len(uses),
                  distinctImplementedIDsUsed=sum(c["native"] == "implemented" for c in commands),
                  distinctUnsupportedIDsUsed=sum(c["native"] != "implemented" for c in commands),
                  implementedCommandUses=sum(c["uses"] for c in commands if c["native"] == "implemented"),
                  executableByIDAssets=sum(r["executableByID"] for r in records),
                  executableByIDNonEmptyAssets=sum(r["executableByID"] and r["commandCount"] > 0 for r in records),
                  staticExecutableAssets=sum(r["staticExecutable"] for r in records),
                  staticExecutableNonEmptyAssets=sum(r["staticExecutable"] and r["commandCount"] > 0 for r in records),
                  staticPrefixCommands=sum(r["firstUnsupported"]["index"] if r["firstUnsupported"] else r["commandCount"] for r in records),
                  staticHaltPrefixCommands=sum(r["firstStaticHalt"]["index"] if r["firstStaticHalt"] else r["commandCount"] for r in records),
                  firstStaticHaltKinds=dict(sorted(Counter(r["firstStaticHalt"]["kind"] for r in records if r["firstStaticHalt"]).items())),
                  argumentHaltSites=dict(Counter(f"{r['firstStaticHalt']['id']} {r['firstStaticHalt']['site']}" for r in records
                                                 if r["firstStaticHalt"] and "site" in r["firstStaticHalt"]).most_common()),
                  controlFlowBeforeFirstUnsupportedAssets=sum(r["controlFlowBeforeFirstUnsupported"] and r["firstUnsupported"] is not None for r in records),
                  argumentLimitUses=dict(sorted(limit_kinds.items())),
                  firstUnsupportedIndexHistogram=dict(Counter(prefix_bucket(r) for r in records)))
    return dict(schemaVersion=2, supportedCommandIDs=sorted(supported), totals=totals, commands=commands, families=families,
                firstBlockerRanking=sorted((c for c in commands if c["firstBlockerAssets"]), key=lambda c: (-c["firstBlockerAssets"], c["id"])),
                greedyImplementationOrder=greedy_order(records, names, supported, greedy_steps),
                directories=directory_rows, assets=records)


def case_name(bundle_path, asset):
    return f"{bundle_path}#{asset['pathID']}"


def trace_case(bundle_path, asset, frame=FRAME_SECONDS, slack=TICK_SLACK):
    """Default inputs: no host variables, one fixed frame per batch and a scripted
    host that acknowledges each blocking request after the frame that issued it
    (MapChange with no ADV variables) and presses Next for every Text batch."""
    return dict(name=case_name(bundle_path, asset),
                program=dict(schemaVersion=1, name=asset["name"], commands=asset["commands"]),
                variables={}, ticks=[dict(deltaTime=frame)] * (len(asset["commands"]) + slack),
                autoAcknowledge=True, autoNext=True, mapVariables={}, requestDetail="full")


def chunk_cases(cases, max_cases=1000, max_ticks=100_000, max_bytes=12 * 1024 * 1024):
    """Split cases under the adv-trace input bounds (cases, frames, bytes)."""
    chunk, ticks, size = [], 0, 0
    for case in cases:
        case_size = len(json.dumps(case, ensure_ascii=False).encode())
        if case_size > max_bytes or len(case["ticks"]) > max_ticks:
            raise ValueError("Single ADV trace case exceeds the inspector input bounds: " + case["name"])
        if chunk and (len(chunk) == max_cases or ticks + len(case["ticks"]) > max_ticks or size + case_size > max_bytes):
            yield chunk
            chunk, ticks, size = [], 0, 0
        chunk.append(case)
        ticks += len(case["ticks"])
        size += case_size
    if chunk:
        yield chunk


def may_fault(command):
    """Scalar commands whose native result depends on runtime values."""
    cid, args = command["id"], command["args"]
    if cid in (3, 4, 14, 15):  # Calc, Clamp, IF, Switch: casts, parsing, comparisons
        return True
    return cid == 1 and (not args or args[0] not in VAR_TYPES or len(args) > 2 and args[2].startswith("*"))


def value_dependent(commands, supported=SUPPORTED):
    """Indexes whose native outcome depends on runtime values (scalar casts or
    presentation arguments that name a scenario-assigned variable)."""
    found = {i for i, c in enumerate(commands) if may_fault(c)}
    return found | {l["index"] for l in argument_limits(commands, supported) if l["kind"] == "value-dependent-argument" or
                    (l["id"] in host.PRESENTATION and not l["certain"])}


def reachable_outcomes(commands, supported=SUPPORTED):
    """Static outcomes reachable from pc 0 when every IF branch is taken.

    Runtime values are not modelled: a reachable value-dependent command may
    halt, and labels/targets naming a scenario-assigned variable may resolve to
    any tag. Returns sorted outcome dicts, a loop flag and the reachable pcs
    with a non-sequential successor (statically possible control transfers).
    """
    assigned = {c["args"][1] for c in commands if c["id"] == 1 and len(c["args"]) > 1}
    assigned |= {c["args"][0] for c in commands if c["id"] in (3, 4) and c["args"]}
    tags, dynamic_tags = {}, []
    for index, command in enumerate(commands):
        if command["id"] == 12 and command["args"]:
            tags.setdefault(command["args"][0], index)  # The first matching tag wins.
            if command["args"][0] in assigned:
                dynamic_tags.append(index)
    all_tags = sorted(set(tags.values()) | set(dynamic_tags))

    def targets(pc, target):
        if target in assigned:
            return all_tags + [pc + 1], True
        found = tags.get(target)
        return sorted({found if found is not None else pc + 1} | set(dynamic_tags)), False

    limits = {l["index"]: l for l in argument_limits(commands, supported) if l["id"] in host.PRESENTATION}
    outcomes, successors = set(), {}
    stack, seen = [0], set()
    while stack:
        pc = stack.pop()
        if pc in seen:
            continue
        seen.add(pc)
        if pc >= len(commands):
            outcomes.add(("exhausted", None, None))
            successors[pc] = []
            continue
        command = commands[pc]
        cid, args, nexts = command["id"], command["args"], [pc + 1]
        if may_fault(command) or pc in limits:
            outcomes.add(("faulted", pc, cid))
        if cid not in supported or (cid == 1 and len(args) > 3) or (pc in limits and limits[pc]["certain"]):
            outcomes.add(("faulted", pc, cid))
            nexts = []
        elif cid == 22:
            outcomes.add(("closed", None, None))
            nexts = []
        elif cid == 23:
            target = args[0] if args else ""
            nexts, dynamic = targets(pc, target)
            if not args or ":" in target or dynamic:
                outcomes.add(("faulted", pc, cid))
            if not args or ":" in target:
                nexts = []
        elif cid in (14, 15):
            branch_targets = ([(args[3:4] or ["tagA"])[0] or "tagA", (args[4:5] or ["tagB"])[0] or "tagB"] if cid == 14
                              else [item.split(",")[-1] for item in args[1:]] or ["Tag"])
            nexts = []
            for target in branch_targets:
                if ":" in target:
                    outcomes.add(("faulted", pc, cid))
                    continue
                found, _ = targets(pc, target)
                nexts += found
        successors[pc] = sorted(set(nexts))
        stack.extend(successors[pc])
    colour, loop = {}, False
    for root in successors:  # Iterative cycle detection over the reachable pc graph.
        if colour.get(root):
            continue
        path = [(root, iter(successors.get(root, [])))]
        colour[root] = 1
        while path:
            node, children = path[-1]
            child = next(children, None)
            if child is None:
                colour[node] = 2
                path.pop()
            elif colour.get(child) == 1:
                loop = True
            elif not colour.get(child):
                colour[child] = 1
                path.append((child, iter(successors.get(child, []))))
    result = [dict(status=s, pc=pc, id=cid) for s, pc, cid in sorted(outcomes, key=lambda o: (o[0], o[1] if o[1] is not None else -1))]
    transfers = sorted(pc for pc, nexts in successors.items() if pc < len(commands) and commands[pc]["id"] in (14, 15, 23)
                       and any(n != pc + 1 for n in nexts))
    return result, loop, transfers


def straight_line(commands, halt, supported=SUPPORTED):
    """True when no control flow or value-dependent command precedes the halt."""
    end = halt["index"] if halt else len(commands)
    prefix, dependent = commands[:end], value_dependent(commands, supported)
    return (not any(c["id"] in (14, 15, 23) for c in prefix) and not any(i < end for i in dependent)
            and not (halt and any(c["id"] == 22 for c in prefix)))


def mutate_halt(commands, index):
    """Negative control: replace the halting record with None (ordinal 0)."""
    mutated = [dict(c) for c in commands]
    mutated[index] = dict(mutated[index], id=0, args=[])
    return mutated


def request_rich(commands, halt, supported=SUPPORTED):
    """A fully executed straight-line asset with a non-trivial request sequence:
    Text, an acknowledged request and at least ten requests."""
    if halt is not None or not straight_line(commands, None, supported):
        return False
    try:
        requests = host.predict_requests(commands, len(commands))
    except host.Fault:
        return False
    kinds = {r["command"]["kind"] for r in requests}
    return len(requests) >= 10 and "text" in kinds and any(r["blocking"] == "acknowledge" for r in requests)


def stratum(record, commands, supported=SUPPORTED):
    halt = record["firstStaticHalt"]
    if not commands:
        return "empty"
    if halt is None:
        return "request-sequence" if request_rich(commands, halt, supported) else "executable"
    if halt["kind"] != "unsupported-command":
        return "argument-limit"
    if halt["index"] == 0:
        return "first-command"
    prefix = commands[:halt["index"]]
    if any(c["id"] == 22 for c in prefix):
        return "close-before"
    if any(pc < halt["index"] for pc in reachable_outcomes(commands, supported)[2]):
        return "branch-before"
    if any(c["id"] in CONTROL_FLOW for c in prefix):
        return "control-flow-before"
    if any(i < halt["index"] for i in value_dependent(commands, supported)):
        return "value-dependent-prefix"
    if any(c["id"] == 25 for c in prefix):
        return "wait-prefix"
    return "scalar-prefix"


STRATA = {"first-command": 6, "scalar-prefix": 5, "wait-prefix": 3, "value-dependent-prefix": 3,
          "branch-before": 6, "control-flow-before": 4, "close-before": 3, "argument-limit": 5, "executable": 4,
          "request-sequence": 3, "empty": 1}


def sample_case(key, name, record, asset, names, supported=SUPPORTED):
    commands, halt = asset["commands"], record["firstStaticHalt"]
    outcomes, loop, transfers = reachable_outcomes(commands, supported)
    mutation = None
    if halt is not None:
        mutated = mutate_halt(commands, halt["index"])
        _, next_halt = first_static_halt(mutated, names, supported)
        mutation = dict(replacedIndex=halt["index"], expectedHalt=next_halt, exactPrediction=straight_line(mutated, next_halt, supported))
    exact = straight_line(commands, halt, supported)
    requests = host.predict_requests(commands, halt["index"] if halt else len(commands)) if exact else None
    return dict(name=key, stratum=name, bundle=record["bundle"], bundleSHA256=record["bundleSHA256"],
                pathID=record["pathID"], commandCount=record["commandCount"],
                program=dict(schemaVersion=1, name=asset["name"], commands=commands),
                firstUnsupported=record["firstUnsupported"], firstStaticHalt=halt,
                controlFlowBeforeFirstStaticHalt=record["controlFlowBeforeFirstStaticHalt"],
                exactPrediction=exact, predictedRequests=requests, reachableOutcomes=outcomes, mayLoop=loop,
                staticTransferPCs=transfers, mutation=mutation)


def select_sample(bundles, coverage, names, strata=STRATA, supported=SUPPORTED):
    """Deterministic stratified sample spread over directories and halting commands.

    Selection uses only static properties (never observed native outcomes).
    """
    programs = {case_name(b["path"], a): a for b in bundles for a in b["assets"]}
    by_stratum = defaultdict(list)
    for record in coverage["assets"]:
        key = f"{record['bundle']}#{record['pathID']}"
        by_stratum[stratum(record, programs[key]["commands"], supported)].append((hashlib.sha256(key.encode()).hexdigest(), key, record))
    cases = []
    for name, count in strata.items():
        candidates = sorted(by_stratum.get(name, []))
        picked, seen_directories, seen_halts = [], set(), set()
        for pass_number in range(3):  # Prefer new directories and new halting commands.
            for _, key, record in candidates:
                if len(picked) == count:
                    break
                if key in {k for k, _ in picked}:
                    continue
                directory = record["bundle"].split("/")[0]
                halt_id = (record["firstStaticHalt"] or {}).get("id")
                if pass_number == 0 and (directory in seen_directories or halt_id in seen_halts):
                    continue
                if pass_number == 1 and directory in seen_directories:
                    continue
                picked.append((key, record))
                seen_directories.add(directory)
                seen_halts.add(halt_id)
        cases += [sample_case(key, name, record, programs[key], names, supported) for key, record in picked]
    return dict(schemaVersion=2, frameSeconds=FRAME_SECONDS, tickSlack=TICK_SLACK, scriptedHost=SCRIPTED_HOST, strata=strata,
                strataPopulation={k: len(v) for k, v in sorted(by_stratum.items())}, caseCount=len(cases),
                faultReasonPatterns=FAULT_REASONS, cases=cases)


# ---------------------------------------------------------------- comparison

def batch_end(commands, start):
    """Last index of the batch that starts at `start` without control transfer."""
    for index in range(start, len(commands)):
        command = commands[index]
        if command["id"] == 22 or (not command["multi"] and command["id"] != 0):
            return index
    return len(commands) - 1


def observe(commands, snapshots):
    """Final outcome, batches whose observed pc cannot be sequential, and the
    observed host requests.

    `batch` counts RequestNextLine calls: a frame that adds none ran no batch,
    a frame that adds more than one re-entered it through a local jump. Each
    request records the pc where its frame's batch started and the number of
    RequestNextLine calls in that frame.
    """
    jumps, start, previous_batch, requests = [], 0, 0, []
    final = snapshots[-1] if snapshots else None

    def jumped(at):
        if at not in jumps:
            jumps.append(at)

    for snapshot in snapshots:
        status, batch = snapshot["status"], snapshot["batch"]
        ran, previous_batch = batch - previous_batch, batch
        requests += [dict(request, frameStart=start, frameBatches=ran) for request in snapshot.get("requests", [])]
        if ran == 0 and status not in TERMINAL:
            continue  # No batch ran in this frame (a Wait, a pending request or a Text awaiting Next).
        end = batch_end(commands, start)
        if ran > 1:
            jumped(start)
        if status == "faulted":
            fault_pc = snapshot["fault"]["pc"]
            if not start <= fault_pc <= max(end, start):
                jumped(start)
            final = snapshot
            break
        if status == "closed":
            if snapshot["pc"] - 1 != end or commands[end]["id"] != 22:
                jumped(start)
            final = snapshot
            break
        if status == "exhausted":
            if commands and end != len(commands) - 1 and not (start >= len(commands) and ran == 1):
                jumped(start)
            final = snapshot
            break
        if snapshot["pc"] != end + 1:
            jumped(start)
        start = snapshot["pc"]
    fault = (final or {}).get("fault") or None
    return dict(status=(final or {}).get("status"), pc=(final or {}).get("pc"),
                faultPC=fault["pc"] if fault else None, faultCommandID=fault["commandID"] if fault else None,
                reason=fault["reason"] if fault else None, executedInstructions=(final or {}).get("executedInstructions"),
                batches=(final or {}).get("batch"), observedJumpBatchStarts=jumps), requests


def reason_kind(reason):
    if reason is None:
        return None
    for needle, kind in (("ADV command ID", "unsupported-command"), ("argument parse throws", "invalid-argument"),
                         ("ADV argument form", "unsupported-argument"), ("inside a Multi batch", "mapchange-multi"),
                         ("host request", "host-request"), ("VAR random alternatives", "var-random-alternatives"),
                         ("External ADV file jump", "external-file-jump"), ("Culture-sensitive", "string-ordering"),
                         ("Clamp Single", "clamp-single-parse"), ("IComparable", "comparison-type-mismatch"),
                         ("Convert.ChangeType", "literal-conversion"), ("budget", "instruction-budget"),
                         ("ValData.Cast", "boxed-cast"), ("unboxes", "boxed-cast"), ("missing", "missing-variable"),
                         ("Missing", "missing-variable"), ("Calc", "calc"), ("IF literal", "extended-literal")):
        if needle in reason:
            return kind
    return "other"


def classify(record, outcome, supported=SUPPORTED, reachable=True):
    """Compare one observed native halt with the static prediction.

    A fault at an implemented command before the predicted halt is explained
    only when the static model lists it as a possible outcome (`reachable`).
    """
    halt, status = record["firstStaticHalt"], outcome["status"]
    fault_pc, fault_id, kind = outcome["faultPC"], outcome["faultCommandID"], reason_kind(outcome["reason"])
    jumped = bool(outcome["observedJumpBatchStarts"])
    if halt and status == "faulted" and fault_pc == halt["index"] and fault_id == halt["id"]:
        return ("match" if halt_reason(halt) in (outcome["reason"] or "") else "match-position-reason-differs"), None
    if halt is None and status in ("closed", "exhausted"):
        return "match-no-halt", None
    if status == "faulted" and kind == "instruction-budget":
        return "loop-budget", "instruction budget exhausted by a local loop"
    if status == "faulted" and kind == "external-file-jump" and fault_id in (14, 15):
        return "external-branch-taken", f"branch at pc {fault_pc} selected an external file:tag target"
    if status == "faulted" and fault_id in supported:
        if (halt is None or fault_pc < halt["index"] or jumped) and reachable:
            return "value-dependent-fault", f"{kind} at implemented command {fault_id} (pc {fault_pc}) under default inputs"
        return "unexplained", "implemented-command fault that is not a statically possible outcome"
    if status == "faulted":
        if jumped:
            return "control-flow-different-halt", f"observed jump(s) at batch pc {outcome['observedJumpBatchStarts']}"
        return "unexplained", "different unsupported halt without an observed jump"
    if status == "closed":
        before = halt is not None and 22 in record["commandIDs"][:halt["index"]]
        if before or jumped:
            return "closed-before-halt", ("Close precedes the predicted halt" if before and not jumped
                                          else f"observed jump(s) at batch pc {outcome['observedJumpBatchStarts']}")
        return "unexplained", "closed without a Close before the prediction or an observed jump"
    if status == "exhausted":
        return ("exhausted-after-jump", "observed jump past the predicted halt") if jumped else ("unexplained", "exhausted")
    return "unterminated", f"status {status} after the frame bound"


def is_reachable(outcome, outcomes, may_loop, _transfers=()):
    """Whether an observed outcome is one of the statically reachable outcomes."""
    if may_loop and (outcome["status"] in ("waiting", "frameBoundary", "awaitingNext", "awaitingHost")
                     or reason_kind(outcome["reason"]) == "instruction-budget"):
        return True
    observed = dict(status=outcome["status"], pc=outcome["faultPC"], id=outcome["faultCommandID"])
    return observed in outcomes


def check_requests(commands, requests, exact_halt=None):
    """Check observed requests against the independent model.

    Every request must name the command at its pc, the model's kind and
    blocking policy, and consecutive IDs. Arguments are compared unless
    ReplaceVars may substitute a scenario-assigned variable; Text bindings are
    compared when the issuing frame ran one batch from a known start. With
    `exact_halt` (a straight-line prefix end), the whole sequence must equal
    `adv_host_requests.predict_requests`.
    """
    stats, mismatches, assigned = Counter(), [], host.assigned_names(commands)

    def mismatch(kind, request, detail=""):
        stats["mismatches"] += 1
        stats["mismatch:" + kind] += 1
        if len(mismatches) < 5:
            mismatches.append(dict(kind=kind, requestID=request.get("requestID"), pc=request.get("pc"), detail=detail))

    for number, request in enumerate(requests):
        stats["requests"] += 1
        pc, cid = request["pc"], request["commandID"]
        command = commands[pc] if 0 <= pc < len(commands) else None
        if request["requestID"] != number or command is None or command["id"] != cid or cid not in host.KINDS:
            mismatch("identity", request)
            continue
        if request["command"]["kind"] != host.KINDS[cid] or request["blocking"] != host.BLOCKING.get(cid, "none"):
            mismatch("policy", request)
            continue
        if host.touches(command, assigned):
            stats["valueDependentUnchecked"] += 1
            continue
        try:
            expected = host.evaluate(command)[3]
        except host.Fault as fault:
            mismatch("model-faults", request, fault.reason)
            continue
        if cid == 16:
            if request["frameBatches"] == 1:
                bindings = {}
                for line in range(request["frameStart"], pc):
                    other = commands[line]
                    if other["id"] in host.BINDINGS:
                        if host.touches(other, assigned):
                            bindings = None
                            break
                        _, key, entries = host.evaluate(other)
                        bindings[key] = bindings.get(key, []) + [entries]
                if bindings is None:
                    stats["textBindingsUnchecked"] += 1
                    expected = dict(expected, **{k: v for k, v in request["command"]["arguments"].items() if k in host.BINDINGS.values()})
                else:
                    expected = dict(expected, **bindings)
            else:
                stats["textBindingsUnchecked"] += 1
                expected = dict(expected, **{k: v for k, v in request["command"]["arguments"].items() if k in host.BINDINGS.values()})
        if host.same(request["command"]["arguments"], expected):
            stats["argumentMatches"] += 1
        else:
            mismatch("arguments", request)
    if exact_halt is not None:
        predicted = host.predict_requests(commands, exact_halt)
        observed = [{k: v for k, v in r.items() if k not in ("frameStart", "frameBatches")} for r in requests]
        stats["sequenceChecked"] += 1
        stats["sequenceRequests"] += len(predicted)
        stats["sequenceNonEmpty"] += bool(predicted)
        if host.same(observed, predicted):
            stats["sequenceMatches"] += 1
        else:
            mismatch("sequence", dict(requestID=None, pc=None), f"{len(observed)} observed, {len(predicted)} predicted")
    return stats, mismatches


def sample_results(sample, comparison):
    """Join the stratified sample with the corpus-wide observed halts."""
    by_name = {r["name"]: r for r in comparison["results"]}
    rows = []
    for case in sample["cases"]:
        result = by_name[case["name"]]
        rows.append(dict(name=case["name"], stratum=case["stratum"], commandCount=case["commandCount"],
                         firstStaticHalt=case["firstStaticHalt"], exactPrediction=case["exactPrediction"],
                         controlFlowBeforeFirstStaticHalt=case["controlFlowBeforeFirstStaticHalt"],
                         predictedRequestCount=len(case["predictedRequests"]) if case.get("predictedRequests") is not None else None,
                         observed=result["observed"], category=result["category"], explanation=result["explanation"],
                         observedReachable=result["observedReachable"], requests=result["requests"]))
    return dict(schemaVersion=2, caseCount=len(rows), categories=dict(Counter(r["category"] for r in rows)),
                strata=dict(Counter(r["stratum"] for r in rows)), cases=rows)


def compare(coverage, trace_pairs, supported=SUPPORTED):
    records = {f"{r['bundle']}#{r['pathID']}": r for r in coverage["assets"]}
    results, seen, request_totals, kinds = [], set(), Counter(), Counter()
    for trace, report in trace_pairs:
        programs = {case["name"]: case["program"]["commands"] for case in trace["cases"]}
        for case in report["cases"]:
            name = case["name"]
            if name in seen:
                raise ValueError("Duplicate trace case " + name)
            seen.add(name)
            record, commands = records[name], programs[name]
            outcome, requests = observe(commands, case["snapshots"])
            reachable = is_reachable(outcome, *reachable_outcomes(commands, supported))
            category, explanation = classify(record, outcome, supported, reachable)
            halt = record["firstStaticHalt"]
            exact = straight_line(commands, halt, supported) and category in ("match", "match-no-halt")
            stats, mismatches = check_requests(commands, requests, (halt["index"] if halt else len(commands)) if exact else None)
            request_totals.update(stats)
            kinds.update(r["command"]["kind"] for r in requests)
            results.append(dict(name=name, bundle=record["bundle"], pathID=record["pathID"], commandCount=record["commandCount"],
                                predicted=halt, firstUnsupported=record["firstUnsupported"],
                                controlFlowBeforeFirstStaticHalt=record["controlFlowBeforeFirstStaticHalt"],
                                observed=outcome, category=category, explanation=explanation, observedReachable=reachable,
                                requests=dict(stats, kinds=dict(Counter(r["command"]["kind"] for r in requests))),
                                requestMismatches=mismatches))
    missing = sorted(set(records) - seen)
    categories = Counter(r["category"] for r in results)
    value_kinds = Counter(reason_kind(r["observed"]["reason"]) for r in results if r["category"] == "value-dependent-fault")
    value_ids = Counter(r["observed"]["faultCommandID"] for r in results if r["category"] == "value-dependent-fault")
    faulted = [r for r in results if r["observed"]["status"] == "faulted"]
    halt_ids = Counter(r["observed"]["faultCommandID"] for r in faulted if reason_kind(r["observed"]["reason"]) == "unsupported-command")
    halt_kinds = Counter(reason_kind(r["observed"]["reason"]) for r in faulted)
    argument_sites = Counter(f"{r['observed']['faultCommandID']} {r['predicted']['site']}" for r in faulted
                             if r["category"] == "match" and r["predicted"] and "site" in r["predicted"])
    summary = dict(cases=len(results), missingCases=len(missing), categories=dict(sorted(categories.items())),
                   valueDependentFaultKinds=dict(sorted(value_kinds.items(), key=lambda kv: str(kv[0]))),
                   valueDependentFaultCommandIDs={str(k): v for k, v in sorted(value_ids.items())},
                   observedFaulted=len(faulted),
                   observedClosed=sum(r["observed"]["status"] == "closed" for r in results),
                   observedExhausted=sum(r["observed"]["status"] == "exhausted" for r in results),
                   observedNonTerminal=sum(r["observed"]["status"] not in TERMINAL for r in results),
                   observedFaultedAtUnsupportedID=sum(r["observed"]["faultCommandID"] not in supported for r in faulted),
                   observedFaultKinds=dict(halt_kinds.most_common()),
                   observedUnsupportedHaltIDs={str(k): v for k, v in halt_ids.most_common(25)},
                   argumentHaltSites=dict(argument_sites.most_common()),
                   controlFlowCases=sum(r["controlFlowBeforeFirstStaticHalt"] for r in results),
                   controlFlowCaseMatches=sum(r["controlFlowBeforeFirstStaticHalt"] and r["category"] == "match" for r in results),
                   mismatchesWithoutExplanation=categories.get("unexplained", 0),
                   observedOutsideReachableOutcomes=sum(not r["observedReachable"] for r in results),
                   assetsWithRequests=sum(r["requests"].get("requests", 0) > 0 for r in results),
                   requests=dict(sorted(request_totals.items())), requestKinds=dict(kinds.most_common()),
                   requestMismatchCases=sum(bool(r["requestMismatches"]) for r in results))
    return dict(schemaVersion=2, scope="Native SourceADVInterpreter via ikkoku-inspect adv-trace; default inputs: no host variables, "
                f"{FRAME_SECONDS:g} s frames; scripted host acknowledges every blocking request (MapChange with no ADV variables) "
                "after the frame that issued it and presses Next whenever a Text batch waits.",
                summary=summary, missing=missing[:50], results=results)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    scan = commands.add_parser("scan", help="Inventory bundles and emit coverage, trace inputs and the sample")
    scan.add_argument("--recovery-index", type=Path, required=True)
    scan.add_argument("--scenario-root", type=Path, required=True, help="Directory searched recursively for *.unity3d")
    scan.add_argument("--output", type=Path, required=True)
    joined = commands.add_parser("compare", help="Classify adv-trace reports against coverage.json")
    joined.add_argument("--output", type=Path, required=True, help="Directory holding coverage.json and traces/")
    args = parser.parse_args()
    if args.command == "scan":
        names, handlers, evidence = command_tables(args.recovery_index)
        root = args.scenario_root.resolve()
        paths = sorted(p for p in root.rglob("*.unity3d") if not p.name.startswith("._"))
        bundles = [scan_bundle(path, root) for path in paths]
        coverage = analyse(bundles, names, handlers)
        coverage.update(sourceEvidence=evidence, scenarioRoot=str(root), commandNames=names,
                        bundles=[{k: v for k, v in b.items() if k != "assets"} | dict(assetCount=len(b["assets"])) for b in bundles])
        args.output.mkdir(parents=True, exist_ok=True)
        traces = args.output / "traces"
        traces.mkdir(exist_ok=True)
        for stale in traces.glob("trace-*.json"):
            stale.unlink()
        cases = (trace_case(b["path"], a) for b in bundles for a in b["assets"])
        chunks = 0
        for number, chunk in enumerate(chunk_cases(cases)):
            (traces / f"trace-{number:03d}.json").write_text(json.dumps(dict(cases=chunk), ensure_ascii=False) + "\n")
            chunks += 1
        sample = select_sample(bundles, coverage, names)
        (args.output / "coverage.json").write_text(json.dumps(coverage, ensure_ascii=False, indent=1) + "\n")
        (args.output / "sample.json").write_text(json.dumps(sample, ensure_ascii=False, indent=1) + "\n")
        print(json.dumps(dict(coverage.get("totals"), traceChunks=chunks, sampleCases=sample["caseCount"]), indent=2))
    else:
        coverage = json.loads((args.output / "coverage.json").read_text())
        pairs = []
        for trace_path in sorted((args.output / "traces").glob("trace-*.json")):
            if trace_path.name.endswith(".report.json"):
                continue
            report_path = trace_path.with_name(trace_path.stem + ".report.json")
            pairs.append((json.loads(trace_path.read_text()), json.loads(report_path.read_text())))
        result = compare(coverage, pairs)
        sample = sample_results(json.loads((args.output / "sample.json").read_text()), result)
        (args.output / "halts.json").write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n")
        (args.output / "sample-halts.json").write_text(json.dumps(sample, ensure_ascii=False, indent=1) + "\n")
        print(json.dumps(dict(result["summary"], sampleCategories=sample["categories"]), indent=2))


if __name__ == "__main__":
    main()
