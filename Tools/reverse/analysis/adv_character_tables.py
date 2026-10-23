#!/usr/bin/env python3
"""Extract the G-T02 character tables and parameter library, and model the bindings.

`extract` reads the installed bundles the original loads at start-up and writes
private JSON inputs for the native interpreter (`ikkoku-inspect adv-trace`
`characterTablesPath` / `parameterLibraryPath`, the host catalog):

* character-tables.json: `SaveData.nicNameDic` (every `NickName` asset under
  `etcetra/list/nickname/`, params with a non-empty Name and an ID other than
  -1, in load order), `SaveData.callDefaultID` (the player-list ID whose Name is
  the literal `SaveData.InitializeCall` searches for, read from the recovered
  source at run time) and the `Manager.Voice.voiceInfoDic` keys (every
  `VoiceInfo.Param.No` under `etcetra/list/config/`);
* parameter-library.json: `Manager.Game.scenarioParameterDic` (every
  `ScenarioData` under `adv/scenario/common_param/`, bundle names sorted, a
  later asset replacing an earlier one with the same name);
* source-keys.json: the model's `Params` key table (below);
* tables-summary.json: bundle hashes, counts and source evidence (no names).

The model half is independent of the native code: it derives the
`SaveData.CharaData.Params` key table (names, command types, field or
property, declaration order, field initializers) from the recovered
`SaveData` source, and evaluates the parameter-library programs' effect on a
heroine field (Calc, Clamp, HeroineParam) with the source conversions.

All outputs contain original data and belong in ignored `.local/`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import struct
from pathlib import Path

try:  # Run as a script or from Tools/reverse/analysis.
    from gameplay_execution_contract import digest, mono_records, recovered_project, selected_source
except ImportError:  # Imported as analysis.adv_character_tables from Tools/reverse.
    from analysis.gameplay_execution_contract import digest, mono_records, recovered_project, selected_source

NICKNAME_DIR = "etcetra/list/nickname"
CONFIG_DIR = "etcetra/list/config"
LIBRARY_DIR = "adv/scenario/common_param"
TYPES = {"int": "Int", "bool": "BOOL", "string": "String"}  # Params.Data.Cast; every other type is Command.None.
DEFAULTS = {"Int": 0, "BOOL": False, "String": None}  # CLR zero values (a string field without initializer is null).


# ---------------------------------------------------------------- tables

def bundles(root, directory):
    """`CommonLib.GetAssetBundleNameListFromPath(directory, subdirCheck: true)` under `root`.

    `Directory.GetFiles` order is not specified; the sorted relative path is
    used (NTFS enumerates these all-ASCII names in that order)."""
    base = Path(root) / directory
    return sorted((p for p in base.rglob("*.unity3d") if not p.name.startswith("._")), key=lambda p: p.relative_to(root).as_posix())


def bundle_record(path, root):
    data = Path(path).read_bytes()
    return dict(path=Path(path).relative_to(root).as_posix(), sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))


def records(path, class_name):
    """MonoBehaviours of one script class, in path-ID order (the scan's asset order)."""
    return sorted(mono_records(path, class_name), key=lambda item: item[0])


def call_names(root):
    tables, files = {}, []
    for path in bundles(root, NICKNAME_DIR):
        files.append(bundle_record(path, root))
        for _, tree in records(path, "NickName"):
            entries = tables.setdefault(tree["m_Name"], [])
            for param in tree["param"]:
                if param["Name"] and int(param["ID"]) != -1:
                    entries.append(dict(name=param["Name"], id=int(param["ID"]), category=int(param["Category"]), bundle=param["Bundle"]))
    return tables, files


def voice_numbers(root):
    numbers, files = set(), []
    for path in bundles(root, CONFIG_DIR):
        files.append(bundle_record(path, root))
        for _, tree in records(path, "VoiceInfo"):
            numbers.update(int(param["No"]) for param in tree["param"])
    return sorted(numbers), files


def default_call_name(savedata_text):
    """The Name literal `SaveData.InitializeCall` finds in the player list."""
    body = re.search(r"static void InitializeCall\(\)\s*\{(.*?)\n\t\}", savedata_text, re.S).group(1)
    found = re.findall(r'GetCallNameList\(-1\)\.Find\(\(NickName\.Param p\) => p\.Name == "([^"]+)"\)', body)
    if len(found) != 1 or "callDefaultID = param.ID" not in body:
        raise ValueError("SaveData.InitializeCall differs from the modelled form")
    return found[0]


def library(root):
    """`Manager.Game.Awake`: sorted common_param bundles; the last asset of a name wins."""
    programs, files, duplicates = {}, [], 0
    paths = bundles(root, LIBRARY_DIR)
    names = [p.relative_to(root).as_posix() for p in paths]
    if any(not re.fullmatch(r"[0-9a-z_/.]+", name) for name in names):
        raise ValueError("common_param bundle names need culture-aware ordering")  # List.Sort() uses the current culture.
    for path in paths:
        files.append(bundle_record(path, root))
        for _, tree in records(path, "ScenarioData"):
            duplicates += tree["m_Name"] in programs
            programs[tree["m_Name"]] = [dict(hash=int(row["_hash"]), version=int(row["_version"]), multi=bool(row["_multi"]),
                                             id=int(row["_command"]), args=[str(arg) for arg in row["_args"]]) for row in tree["list"]]
    return programs, files, duplicates


def extract(index_path, source_root, output):
    project = recovered_project(index_path)
    savedata_path, savedata_text = selected_source(index_path, "SaveData", project)
    evidence = [dict(type="SaveData", path=str(savedata_path), sha256=digest(savedata_path))]
    for type_name in ("NickName", "VoiceInfo", "Manager.Voice", "Manager.Game", "CommonLib"):
        path, _ = selected_source(index_path, type_name, project)
        evidence.append(dict(type=type_name, path=str(path), sha256=digest(path)))
    names, name_files = call_names(source_root)
    if "player" not in names:
        raise ValueError("No player call-name list")
    wanted = default_call_name(savedata_text)
    match = next((entry for entry in names["player"] if entry["name"] == wanted), None)  # List.Find: the first match.
    if match is None:
        raise ValueError("SaveData.InitializeCall finds no player call name (the source throws NullReferenceException)")
    numbers, voice_files = voice_numbers(source_root)
    programs, library_files, duplicates = library(source_root)
    tables = dict(schemaVersion=1, callNames=names, callDefaultID=match["id"], voiceNumbers=numbers)
    parameter_library = dict(schemaVersion=1, programs=programs)
    output.mkdir(parents=True, exist_ok=True)
    tables_bytes = (json.dumps(tables, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode()
    library_bytes = (json.dumps(parameter_library, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode()
    (output / "character-tables.json").write_bytes(tables_bytes)
    (output / "parameter-library.json").write_bytes(library_bytes)
    keys = source_keys(savedata_text)
    (output / "source-keys.json").write_text(json.dumps(dict(schemaVersion=1, source=str(savedata_path), **keys), ensure_ascii=False, indent=1) + "\n")
    shapes = {}
    for commands in programs.values():
        shape = " ".join(str(c["id"]) for c in commands) or "(empty)"
        shapes[shape] = shapes.get(shape, 0) + 1
    summary = dict(schemaVersion=1, sourceEvidence=evidence, nicknameBundles=name_files, configBundles=voice_files,
                   libraryBundles=library_files, callNameLists=len(names), callNames=sum(len(v) for v in names.values()),
                   specialCallNames=sum(e["category"] == 0 for v in names.values() for e in v),
                   callDefaultID=match["id"], voiceNumbers=len(numbers), libraryPrograms=len(programs),
                   libraryCommands=sum(len(v) for v in programs.values()), libraryDuplicateNames=duplicates,
                   libraryShapes=dict(sorted(shapes.items(), key=lambda kv: (-kv[1], kv[0]))),
                   heroineKeys=len(keys["heroine"]), playerKeys=len(keys["player"]),
                   characterTablesSHA256=hashlib.sha256(tables_bytes).hexdigest(),
                   parameterLibrarySHA256=hashlib.sha256(library_bytes).hexdigest())
    (output / "tables-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n")
    return summary


# ---------------------------------------------------------------- independent model

def class_body(text, declaration):
    """The text of one class nested directly in `SaveData` (members at two tabs)."""
    start = text.index("\n\t" + declaration)
    end = text.index("\n\t}\n", start)
    return text[start:end]


def members(body):
    """Public instance fields and properties of a Params type, in declaration order.

    Static, const and abstract members are skipped (an abstract property is
    reported once, where its override is declared)."""
    fields, properties = [], []
    for line in body.split("\n"):
        found = re.match(r"\t\tpublic (?:(override|virtual|new) )?(int|bool|string|[\w.<>\[\], ]+?) (\w+)(.*)$", line)
        if not found or line.startswith("\t\tpublic static") or line.startswith("\t\tpublic const") or " class " in line:
            continue
        modifier, type_name, name, rest = found.groups()
        if type_name in ("abstract", "readonly") or rest.startswith("("):
            continue  # Abstract members and methods.
        if rest.startswith(";") or rest.startswith(" = "):
            initializer = re.match(r" = (.*);$", rest)
            fields.append(dict(name=name, type=type_name, initializer=initializer.group(1) if initializer else None))
        elif rest == "" or rest.startswith(" =>") or rest.startswith(" {"):
            settable = bool(re.search(r"\bset;", rest))
            properties.append(dict(name=name, type=type_name, settable=settable))
    return fields, properties


def field_default(type_name, initializer):
    if initializer is None:
        return DEFAULTS[TYPES[type_name]]
    if type_name == "int":
        return int(initializer)
    if type_name == "bool":
        return dict(true=True, false=False)[initializer]
    if initializer == "string.Empty":
        return ""
    raise ValueError("Unmodelled initializer " + initializer)


def params_extras(body, header, names):
    """The Params subclass's added Data rows (`Replace` names and HExperience keys)."""
    params = re.search(r"public new class Params : CharaData\.Params\s*\{(.*?)\n\t\t\}", body, re.S).group(1)
    rows = []
    for command, key in re.findall(r'new Data\(Data\.Command\.(\w+), ("[^"]*"(?: \+ CharaData\.Names\[\d\])?|text(?: \+ "\w+")?)', params):
        if key.startswith("text"):
            prefix = header + re.search(r'GetPropertyName\(\(\) => \w+\.(\w+)\)', params).group(1)
            name = prefix + (re.search(r'"(\w+)"', key).group(1) if "+" in key else "")
        else:
            literal = re.match(r'"([^"]*)"', key).group(1)
            index = re.search(r"Names\[(\d)\]", key)
            name = literal + (names[int(index.group(1))] if index else "")
        rows.append(dict(key=name, command=command, member=None, writable=False))
    return rows


def source_keys(savedata_text):
    """`param.datas` for a Heroine and a Player: the class's own public fields,
    then the base `CharaData` fields, then the same for properties (Mono
    reflection order), keeping int/bool/string members, then the Params
    subclass's extra rows. Fields have setters; properties never do."""
    base = class_body(savedata_text, "public abstract class CharaData")
    names_text = re.search(r"static readonly string\[\] Names = new string\[4\] \{ (.*?) \};", base).group(1)
    names = [item.strip().strip('"') for item in names_text.split(",")]
    base_fields, base_properties = members(base)
    result = {}
    for kind, declaration, header in (("heroine", "public class Heroine : CharaData", "H_"), ("player", "public class Player : CharaData", "P_")):
        body = class_body(savedata_text, declaration)
        own_fields, own_properties = members(body)
        own_names = {p["name"] for p in own_properties}
        rows = []
        for field in own_fields + base_fields:
            if field["type"] in TYPES:
                rows.append(dict(key=header + field["name"], command=TYPES[field["type"]], member=field["name"], writable=True,
                                 default=field_default(field["type"], field["initializer"])))
        for prop in own_properties + [p for p in base_properties if p["name"] not in own_names]:
            if prop["type"] in TYPES:
                rows.append(dict(key=header + prop["name"], command=TYPES[prop["type"]], member=prop["name"], writable=False))
        result[kind] = rows + params_extras(body, header, names)
    return result


def single(value):
    """Round to IEEE float32 (Mono `float`)."""
    return struct.unpack("<f", struct.pack("<f", value))[0]


def single_to_string(value):
    """`float.ToString()` for the values a Clamp of small integers produces (Mono "R"-free G7 formatting)."""
    if value == int(value) and abs(value) < 1e7:
        return str(int(value))
    text = f"{value:.7g}"
    return text


def int32_parse(text):
    """`Convert.ChangeType(string, Int32)` = `Int32.Parse(text, CurrentCulture)` with NumberStyles.Integer.

    Returns None when the source throws (format or overflow)."""
    match = re.fullmatch(r"[ \t\n\v\f\r]*([+-]?)[ \t\n\v\f\r]*([0-9]+)[ \t\n\v\f\r]*(?:\x00.*)?", text, re.S)
    if not match:
        return None
    value = int(match.group(2)) * (-1 if match.group(1) == "-" else 1)
    return value if -2**31 <= value < 2**31 else None


def library_effect(commands, fields):
    """Run a parameter-library program (Calc, Clamp, HeroineParam only) over heroine Int fields.

    `fields` maps `H_` keys to the heroine's current Int values; the bound
    variables start equal to them (`SetADVParam(scenario)`). Returns the new
    field values, or raises ValueError for any other command or form."""
    variables = {key: ("Int", value) for key, value in fields.items()}
    fields = dict(fields)
    for command in commands:
        cid, args = command["id"], command["args"]
        if cid == 3 and len(args) == 3 and args[1] in ("0", "1", "2") and re.fullmatch(r"-?[0-9]+", args[2]):
            kind, current = variables.get(args[0], ("Int", 0))  # A missing answer variable starts as the literal's type.
            if kind != "Int":
                raise ValueError("Calc on a non-Int variable is not modelled")
            operand = int(args[2])
            value = (operand, current + operand, current - operand)[int(args[1])]
            if not -2**31 <= value < 2**31:
                raise ValueError("Int32 overflow is not modelled")
            variables[args[0]] = ("Int", value)
        elif cid == 4 and len(args) == 4:
            def number(text):
                kind_value = variables.get(text)
                return float(kind_value[1]) if kind_value else float(text)
            value, low, high = (single(number(a)) for a in args[1:])
            variables[args[0]] = ("Single", low if value < low else (high if value > high else value))
        elif cid == 165 and len(args) == 2:
            if args[0] not in fields:
                continue  # Unknown keys are a no-op; only Int fields are modelled.
            kind, value = variables.get(args[1], ("String", args[1]))
            text = single_to_string(value) if kind == "Single" else str(value)
            parsed = int32_parse(text)
            if parsed is None or (kind == "Single" and not math.isfinite(value)):
                raise ValueError("HeroineParam conversion throws")
            fields[args[0]] = parsed
            variables[args[0]] = ("Int", parsed)
        else:
            raise ValueError(f"Command {cid} is not modelled")
    return fields


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--recovery-index", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True, help="The fetched abdata directory")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    summary = extract(args.recovery_index, args.source_root.resolve(), args.output)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("sourceEvidence", "libraryShapes")}, indent=1))


if __name__ == "__main__":
    main()
