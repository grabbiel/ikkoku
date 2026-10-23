#!/usr/bin/env python3
"""G-T02: run heroine ADV parameter programs in the original main-game player and compare the
native interpreter with what it records.

run: writes cases.json/cases.tsv (named HeroineParam/ParameterFile programs, plus the leading
[VAR, ParameterFile] commands of every scenario asset whose first presentation command comes
after a ParameterFile). It then makes five `prlctl exec` calls, each one script and each after
an errno-24 check against --errno-baseline:
1-2. setup: a private player root, C:\\Temp\\IkkokuADVBindingProbe-<hex>, with copies of
   Koikatu.exe, the loader and BepInEx core and a junction to Koikatu_Data. It has no UserData
   and no installed plug-ins. The probe source is appended in two parts, because each exec
   argument stays under COMMAND_LIMIT.
3. mirror: abdata without the install's AppleDouble files (see mirror_script).
4. compile: cases.tsv, and the source after a hash check.
5. run, as the signed-in user: start the player and wait a bounded time for it to exit. If it
   is still running, stop it by PID. Then return the TSV, status and logs.
Nothing in C:\\Illusion\\Koikatsu is written. The root stays in C:\\Temp, as the earlier
probes' roots do. A rerun with the same output folder resumes after a completed setup.

compare: runs the same cases through `ikkoku-inspect adv-trace` with the new-game heroine and
player and the coverage scan's tables and library. Per case it compares Vars (type and value;
Single numerically), Replaces, the heroine's int/bool/string fields, the final command list and
the exception line. It also checks the key reflection order, the scenarioParameterDic programs
and the table metadata against the extracted inputs. Outputs stay under .local; only the
printed summary (counts and hashes) is for docs.
"""
from __future__ import annotations
import argparse, base64, gzip, hashlib, json, re, struct, subprocess, time, uuid
from pathlib import Path
from vm_source import ps_quote

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name("fixtures") / "OriginalADVBindingProbe.cs"
ROOT_PATTERN = r"C:\\Temp\\IkkokuADVBindingProbe-[0-9a-f]{32}"
SCALAR = {0, 1, 3, 4, 12, 22, 25, 165, 201}  # No control flow: the prefix runs straight through.
MODELLED = {1, 3, 4, 165}  # VAR, Calc, Clamp, HeroineParam: the probe's library cases.
WAIT_SECONDS = 600
COMMAND_LIMIT = 2400  # The longest exec argument the earlier probes send (write_small chunks); a 2995-character one failed.


def digest(data): return hashlib.sha256(data).hexdigest()
def dump(path, value): path.write_text(json.dumps(value, indent=1, ensure_ascii=False, allow_nan=False) + "\n")


def program_digest(commands):
    """The probe's Digest: id \\x1f multi \\x1f args joined by \\x1e, commands joined by \\x1d."""
    text = "\x1d".join(f"{c['id']}\x1f{1 if c['multi'] else 0}\x1f" + "\x1e".join(c["args"]) for c in commands)
    return digest(text.encode())


def command(cid, *args, multi=False): return dict(hash=0, version=0, multi=multi, id=cid, args=list(args))


def named_cases(library, tables):
    """Programs that reach each HeroineParam/ParameterFile path from the new-game heroine."""
    key = next(c["args"][0] for c in library["301"] if c["id"] == 165)
    names = tables["callNames"]["c00"]  # `new SaveData.Heroine(false)`: personality 0.
    normal = next(e["id"] for e in names if e["category"] != 0 and e["id"] != tables["callDefaultID"])
    special = next(e["id"] for e in names if e["category"] == 0)
    pf = lambda asset: command(201, asset)
    hp = lambda name, value: command(165, name, value)
    return {
        "seed": [],
        "pf-order": [pf("301"), pf("ikkoku-missing"), pf("301")],
        "pf-clamp": [hp(key, "99"), pf("301")],
        "call-normal": [hp("H_callID", str(normal))],
        "call-special": [hp("H_callID", str(special))],
        "call-reset": [hp("H_callID", "-1")],
        "unknown-key": [hp("H_ikkokuUnknown", "1")],
        "property-key": [hp("H_callMyID", "77")],
        "bool-field": [hp("H_isGirlfriend", "True")],
        "string-field": [hp("H_callName", "ikkoku")],
        "int-styles": [hp("H_favor", " +12 ")],
        "bad-int": [hp("H_favor", "6.5")],
        "replaced-value": [command(1, "System.Int32", "ikkokuValue", "5"), hp("H_favor", "ikkokuValue")],
        "captured-key": [command(1, "System.String", "ikkokuKey", "H_favor"), hp("ikkokuKey", "3")],
    }


def prefix_cases(coverage_dir):
    """The leading straight-line scalar/binding commands of each asset that holds a ParameterFile."""
    coverage = json.loads((coverage_dir / "coverage.json").read_text())
    programs = {}
    for path in sorted((coverage_dir / "traces").glob("trace-[0-9][0-9][0-9].json")):
        for case in json.loads(path.read_text())["cases"]:
            programs[case["name"]] = case["program"]["commands"]
    cases = []
    for asset in coverage["assets"]:
        ids = asset["commandIDs"]
        count = next((i for i, cid in enumerate(ids) if cid not in SCALAR), len(ids))
        if 201 in ids[:count]:
            commands = programs[f"{asset['bundle']}#{asset['pathID']}"][:count]
            if [c["id"] for c in commands] != ids[:count]:
                raise ValueError("Trace program differs from the coverage record: " + asset["bundle"])
            cases.append(dict(label=f"prefix:{len(cases)}", bundle="adv/scenario/" + asset["bundle"], asset=asset["name"],
                              count=count, commands=commands))
    return cases


def case_rows(named, prefixes):
    """cases.tsv: `program<TAB>label<TAB>id|multi|arg|...` per named program, and
    `asset<TAB>label<TAB>bundle<TAB>asset<TAB>count` per prefix."""
    def encode(c):
        if any(re.search(r"[|\t\r\n']", a) for a in c["args"]):
            raise ValueError("Case argument holds a separator or quote")
        return "|".join([str(c["id"]), "1" if c["multi"] else "0"] + c["args"])
    rows = ["\t".join(["program", label] + [encode(c) for c in commands]) for label, commands in named.items()]
    rows += ["\t".join(["asset", p["label"], p["bundle"], p["asset"], str(p["count"])]) for p in prefixes]
    text = "\n".join(rows) + "\n"
    if not text.isascii() or "'" in text:
        raise ValueError("cases.tsv must be ASCII without quotes")
    return text.encode()


def errno_count():
    return int(subprocess.run(["grep", "-c", "errno: 24", "/Library/Logs/parallels.log"], capture_output=True, text=True).stdout.strip() or 0)


def guarded(baseline, phase):
    count = errno_count()
    if count != baseline:
        raise RuntimeError(f"Parallels errno-24 count is {count} before {phase} (baseline {baseline}); VM work stopped")
    return count


SETUP = r"""$o='C:\Illusion\Koikatsu'
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
foreach($d in @('BepInEx\plugins','BepInEx\config')){New-Item -ItemType Directory "$root\$d" -Force|Out-Null}
foreach($n in @('Koikatu.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$o\$n" "$root\$n"}
Copy-Item "$o\BepInEx\core" "$root\BepInEx\core" -Recurse
New-Item -ItemType Junction -Path "$root\Koikatu_Data" -Value "$o\Koikatu_Data"|Out-Null
[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n")
"""


def here(text):
    """A PowerShell single-quoted here-string holding text verbatim."""
    if "\n'@" in "\n" + text or "\r" in text:
        raise ValueError("Text cannot travel as a here-string")
    return "@'\n" + text.rstrip("\n") + "\n'@"


def setup_scripts(root, source):
    """The player-root setup plus the probe source, appended in as few execs as fit the
    command limit (the source is too long for one)."""
    head = "$ErrorActionPreference='Stop';$root=" + ps_quote(root) + "\n"
    lines, scripts, part = source.splitlines(), [], []
    def script(part, first):
        return head + (SETUP if first else "") + "[IO.File]::AppendAllText(\"$root\\ADVBindingProbe.cs\"," + here("\n".join(part) + "\n") + "+\"`n\");'appended'"
    for line in lines:
        if part and len(wrapped(script(part + [line], not scripts))) > COMMAND_LIMIT:
            scripts.append(script(part, not scripts)); part = []
        part.append(line)
    scripts.append(script(part, not scripts))
    return scripts


def mirror_script(root):
    """abdata without the install's AppleDouble (`._*`) files, which the game lists as bundles
    (`CommonLib.GetAssetBundleNameListFromPath`) and fails to open, aborting `Manager.Game.Awake`.
    Directories with no AppleDouble file below them become junctions; in the others each file
    becomes a symbolic link. Nothing in the install is written."""
    return ("$ErrorActionPreference='Stop';$root=" + ps_quote(root) + r"""
$src='C:\Illusion\Koikatsu\abdata';if(Test-Path -LiteralPath "$root\abdata"){throw 'abdata exists'}
$ad=@(Get-ChildItem -LiteralPath $src -Recurse -Force -File -Filter '._*')
$dirs=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);[void]$dirs.Add($src)
foreach($f in $ad){$d=$f.DirectoryName;while($dirs.Add($d)){$d=Split-Path $d}}
$n=@{links=0;junctions=0;skipped=0;directories=0}
function M($s,$d){[void](New-Item -ItemType Directory $d);$n.directories++
foreach($c in Get-ChildItem -LiteralPath $s -Force){$t=Join-Path $d $c.Name
if($c.PSIsContainer){if($dirs.Contains($c.FullName)){M $c.FullName $t}else{[void](New-Item -ItemType Junction -Path $t -Value $c.FullName);$n.junctions++}}
elseif($c.Name.StartsWith('._')){$n.skipped++}else{[void](New-Item -ItemType SymbolicLink -Path $t -Value $c.FullName);$n.links++}}}
M $src "$root\abdata";$n.appleDouble=$ad.Count;[PSCustomObject]$n|ConvertTo-Json -Compress""")


def compile_script(root, cases, source_sha256):
    """Checks the uploaded source's hash, writes cases.tsv beside the plugin and compiles it."""
    return ("$ErrorActionPreference='Stop';$root=" + ps_quote(root) + ";$p=\"$root\\BepInEx\\plugins\"\n"
            "if((Get-FileHash \"$root\\ADVBindingProbe.cs\" -Algorithm SHA256).Hash.ToLower() -ne '" + source_sha256 + "'){throw 'Uploaded source hash differs'}\n"
            "[IO.File]::WriteAllText(\"$p\\cases.tsv\"," + here(cases.decode("ascii")) + "+\"`n\")\n"
            + r"""$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\Koikatu_Data\Managed" -Filter '*.dll'|%{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuADVBindingProbe.dll" /reference:$($refs -join ',') "$root\ADVBindingProbe.cs" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"};'compiled'""")


def run_script(root):
    """Starts the player in the user's session, waits for it to exit (bounded), stops what is
    left of this root by PID, and returns the results gzipped."""
    return ("$ErrorActionPreference='Stop';$root=" + ps_quote(root) + ";$p=\"$root\\BepInEx\\plugins\"\n"
            + r"""$x=Start-Process -FilePath "$root\Koikatu.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru
$exited=$x.WaitForExit(""" + str(WAIT_SECONDS * 1000) + r""")
$left=@(Get-Process -ErrorAction SilentlyContinue|?{$_.Path -and $_.Path.StartsWith($root+'\')})
$left|Stop-Process -Force
function Z($f){if(Test-Path -LiteralPath $f){$b=[IO.File]::ReadAllBytes($f);$m=New-Object IO.MemoryStream;$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Compress);$g.Write($b,0,$b.Length);$g.Dispose();[Convert]::ToBase64String($m.ToArray())}else{$null}}
[PSCustomObject]@{processID=$x.Id;exited=$exited;exitCode=$(if($exited){$x.ExitCode}else{$null});stopped=@($left|%{$_.Id});tsv=(Z "$p\adv-binding.tsv");status=(Z "$p\status.txt");bepinex=(Z "$root\BepInEx\LogOutput.log");unity=(Z "$root\unity.log")}|ConvertTo-Json -Compress""")


def wrapped(script):
    """vm_source.powershell's gzip wrapper: ASCII, so Parallels takes it whole."""
    compressed = base64.b64encode(gzip.compress(script.encode("utf-8"))).decode("ascii")
    return ("$m=New-Object IO.MemoryStream(,[Convert]::FromBase64String('" + compressed + "'));"
            "$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);"
            "$r=New-Object IO.StreamReader($g);Invoke-Expression $r.ReadToEnd()")


def vm_exec(vm, script, user=False):
    """One `prlctl exec` of a wrapped script, optionally in the signed-in user's session,
    bounded by the player wait. Only the setup execs retry: a retried run could start a
    second player."""
    wrapper = wrapped(script)
    if len(wrapper) > COMMAND_LIMIT:
        raise ValueError(f"Script exceeds the command limit ({len(wrapper)} characters)")
    command = ["prlctl", "exec", vm] + (["--current-user"] if user else []) + ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", wrapper]
    for attempt in range(1 if user else 3):  # Parallels' transient "Invalid argument", retried as write_small does.
        result = subprocess.run(command, text=True, capture_output=True, timeout=WAIT_SECONDS + 300)
        if not result.returncode:
            return result.stdout.lstrip("\ufeff").strip()
        if "Invalid argument" not in (result.stderr or result.stdout) or user or attempt == 2:
            raise RuntimeError(f"VM exec failed ({result.returncode}): {result.stderr or result.stdout}")
        time.sleep(.25)


def stripped_source():
    """Comment-only lines and indentation removed: the uploaded text (hash recorded in run.json)."""
    lines = (line.strip() for line in SOURCE.read_text().splitlines())
    return "\n".join(line for line in lines if line and not line.startswith("//")) + "\n"


def run(args):
    """Setup (resumed when run.json records a complete setup of the same source), compile,
    then the player run. An errno-24 check precedes every exec."""
    output = args.output
    coverage_dir = args.coverage
    library = json.loads((coverage_dir / "parameter-library.json").read_text())["programs"]
    tables = json.loads((coverage_dir / "character-tables.json").read_text())
    named = named_cases(library, tables)
    prefixes = prefix_cases(coverage_dir)
    cases = case_rows(named, prefixes)
    source = stripped_source()
    record_path = output / "run.json"
    previous = json.loads(record_path.read_text()) if record_path.is_file() else None
    scripts = None
    if previous and re.fullmatch(ROOT_PATTERN, previous["root"]) and previous.get("uploadedSourceSHA256") == digest(source.encode()) \
            and "processID" not in previous:
        root, record = previous["root"], previous
        if len(record["setup"]) != len(setup_scripts(root, source)):
            raise RuntimeError("run.json records an incomplete setup; start with a new output folder")
    else:
        root = r"C:\Temp\IkkokuADVBindingProbe-" + uuid.uuid4().hex
        record = dict(vm=args.vm, root=root, sourceSHA256=digest(SOURCE.read_bytes()), uploadedSourceSHA256=digest(source.encode()),
                      errnoBaseline=args.errno_baseline, errno=[], setup=[])
        scripts = setup_scripts(root, source)
    dump(output / "cases.json", dict(schemaVersion=1, named=named, prefixes=prefixes))
    (output / "cases.tsv").write_bytes(cases)
    record["casesSHA256"] = digest(cases)
    def exec_phase(name, script, user=False):
        record["errno"].append(guarded(args.errno_baseline, name))
        dump(record_path, record)
        result = vm_exec(args.vm, script, user)
        dump(record_path, record)
        return result
    for index, script in enumerate(scripts or []):
        record["setup"].append(exec_phase(f"setup {index + 1}", script))
    if "mirror" not in record:
        record["mirror"] = json.loads(exec_phase("mirror", mirror_script(root)))
        dump(record_path, record)
    record["compile"] = exec_phase("compile", compile_script(root, cases, record["uploadedSourceSHA256"]))
    result = json.loads(exec_phase("run", run_script(root), user=True))
    files = {}
    for name, key in (("adv-binding.tsv", "tsv"), ("status.txt", "status"), ("LogOutput.log", "bepinex"), ("unity.log", "unity")):
        if result.get(key):
            data = gzip.decompress(base64.b64decode(result[key], validate=True))
            (output / name).write_bytes(data)
            files[name] = dict(sha256=digest(data), bytes=len(data))
    record.update(processID=result["processID"], exited=result["exited"], exitCode=result["exitCode"],
                  stoppedProcesses=result["stopped"], files=files)
    record["errno"].append(errno_count())
    dump(record_path, record)
    return dict(root=root, exited=result["exited"], stopped=result["stopped"], files=files, errno=record["errno"],
                status=(output / "status.txt").read_text()[:200] if (output / "status.txt").is_file() else None)


# ------------------------------------------------------------------ comparison

def unescape(text):
    return re.sub(r"\\(.)", lambda m: {"t": "\t", "n": "\n", "r": "\r", "\\": "\\"}[m.group(1)], text)


def parse_probe(path):
    cases, meta, library, keys = {}, {}, {}, dict(heroineKey=[], playerKey=[])
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        f = [unescape(x) for x in line.split("\t")]
        if f[0] == "meta": meta[f[1]] = f[2:]
        elif f[0] in keys: keys[f[0]].append((f[1], f[2]))
        elif f[0] == "library": library[f[1]] = dict(count=int(f[2]), sha256=f[3])
        else:
            case = cases.setdefault(f[0], dict(vars={}, replaces={}, fields={}, exception=None))
            if f[1] == "var": case["vars"][f[2]] = (f[3], f[4])
            elif f[1] == "replace": case["replaces"][f[2]] = f[3]
            elif f[1] == "field": case["fields"][f[2]] = f[3]
            elif f[1] == "commands": case["commands"] = [int(x) for x in f[2].split(",") if x]
            elif f[1] == "program": case["program"] = dict(count=int(f[2]), sha256=f[3])
            elif f[1] == "exception": case["exception"] = dict(type=f[2], line=int(f[3]))
            else: raise ValueError("Unknown probe row: " + f[1])
    return meta, keys, library, cases


def single(text): return struct.unpack("<f", struct.pack("<f", float(text)))[0]


def same_value(probe, native):
    ptype, pvalue = probe
    if ptype != native["type"]: return False
    if ptype == "System.Single": return single(pvalue) == single(native["value"])
    return pvalue == native["value"]


def field_text(value):
    if isinstance(value, bool): return "True" if value else "False"
    return str(value)


def final_commands(program, insertions, library):
    ids = [c["id"] for c in program]
    for insertion in insertions:
        ids[insertion["pc"] + 1:insertion["pc"] + 1] = [c["id"] for c in library[insertion["asset"]]]
    return ids


def compare(args):
    output, coverage_dir = args.output, args.coverage
    cases_doc = json.loads((output / "cases.json").read_text())
    library = json.loads((coverage_dir / "parameter-library.json").read_text())["programs"]
    tables = json.loads((coverage_dir / "character-tables.json").read_text())
    source_keys = json.loads((coverage_dir / "source-keys.json").read_text())
    meta, keys, probe_library, probe = parse_probe(output / "adv-binding.tsv")
    issues = []
    # Runtime facts against the extracted inputs.
    checks = dict(
        callDefaultID=int(meta["callDefaultID"][0]) == tables["callDefaultID"],
        playerCallID=int(meta["playerCallID"][0]) == tables["callDefaultID"],
        voiceNumbers=int(meta["voiceNumbers"][0]) == len(set(tables["voiceNumbers"])),
        parameterPrograms=int(meta["parameterPrograms"][0]) == len(library),
        heroineKeys=[(k, c) for k, c in keys["heroineKey"]] == [(r["key"], r["command"]) for r in source_keys["heroine"]],
        playerKeys=[(k, c) for k, c in keys["playerKey"]] == [(r["key"], r["command"]) for r in source_keys["player"]],
        libraryPrograms=sorted(probe_library) == sorted(library) and all(
            probe_library[k] == dict(count=len(v), sha256=program_digest(v)) for k, v in library.items()))
    issues += [dict(case="meta", kind=name) for name, ok in checks.items() if not ok]
    # Native runs of every case the probe recorded.
    programs = dict(cases_doc["named"])
    programs.update({p["label"]: p["commands"] for p in cases_doc["prefixes"]})
    for label in probe:
        if label.startswith("library:"): programs[label] = library[label[8:]]
        elif label.startswith("library-pf:"): programs[label] = [command(201, label[11:])]
    missing = sorted(set(programs) - set(probe))
    issues += [dict(case=label, kind="not-run-by-probe") for label in missing]
    trace = dict(parameterLibraryPath=str((coverage_dir / "parameter-library.json").resolve()),
                 characterTablesPath=str((coverage_dir / "character-tables.json").resolve()),
                 cases=[dict(name=label, program=dict(schemaVersion=1, name=label, commands=programs[label]), variables={},
                             ticks=[dict(deltaTime=1000.0)] * 4, autoAcknowledge=True, autoNext=True, mapVariables={},
                             character=dict(heroine={}, player=dict(callID=tables["callDefaultID"])))
                        for label in sorted(probe) if label in programs])
    dump(output / "native-trace.json", trace)
    report = json.loads(subprocess.run([str(args.inspect), "adv-trace", str((output / "native-trace.json").resolve())],
                                       check=True, capture_output=True, text=True).stdout)
    dump(output / "native-trace.report.json", report)
    native = {case["name"]: case for case in report["cases"]}
    totals = dict(cases=0, vars=0, replaces=0, fields=0, exceptions=0, insertions=0, changedFields=0)
    seed_fields = probe["seed"]["fields"]
    for label in sorted(programs):
        if label not in probe: continue
        p, n = probe[label], native[label]
        last = n["snapshots"][-1]
        totals["cases"] += 1
        def issue(kind, detail=""): issues.append(dict(case=label, kind=kind, detail=detail))
        if p["program"] != dict(count=len(programs[label]), sha256=program_digest(programs[label])): issue("program")
        nvars = last["variables"]
        for key in sorted(set(p["vars"]) | set(nvars)):
            if key not in p["vars"] or key not in nvars or not same_value(p["vars"][key], nvars[key]): issue("var", key)
        totals["vars"] += len(p["vars"])
        if p["replaces"] != n.get("replaces"): issue("replaces")
        totals["replaces"] += len(p["replaces"])
        heroine = n["heroine"]
        compared = [name for name in p["fields"] if name in heroine]
        for name in compared:
            if p["fields"][name] != field_text(heroine[name]): issue("field", name)
        totals["fields"] += len(compared)
        totals["changedFields"] += sum(1 for name in compared if p["fields"][name] != seed_fields[name])
        inserted = [i for s in n["snapshots"] for i in s["insertions"]]
        totals["insertions"] += len(inserted)
        if p.get("commands") != final_commands(programs[label], inserted, library): issue("commands")
        fault = last["fault"]
        if (p["exception"] is None) != (fault is None) or fault is not None and fault["pc"] != p["exception"]["line"]:
            issue("exception", json.dumps([p["exception"], fault], ensure_ascii=False))
        totals["exceptions"] += p["exception"] is not None
        if fault is None and last["status"] != "finished": issue("status", last["status"])
    fields_only_in_probe = sorted(set(seed_fields) - set(native["seed"]["heroine"]))
    summary = dict(schemaVersion=1, probeTSVSHA256=digest((output / "adv-binding.tsv").read_bytes()),
                   casesSHA256=digest((output / "cases.tsv").read_bytes()),
                   nativeReportSHA256=digest((output / "native-trace.report.json").read_bytes()),
                   unity=meta["unity"][0], checks=checks, totals=totals,
                   caseKinds=dict(named=sum(1 for l in probe if l in cases_doc["named"]),
                                  prefixes=sum(1 for l in probe if l.startswith("prefix:")),
                                  library=sum(1 for l in probe if l.startswith("library:")),
                                  libraryParameterFile=sum(1 for l in probe if l.startswith("library-pf:"))),
                   probeFieldsWithoutNativeField=len(fields_only_in_probe), issues=len(issues))
    dump(output / "compare.json", dict(summary=summary, issues=issues, fieldsOnlyInProbe=fields_only_in_probe))
    return summary


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command", choices=["run", "compare"])
    p.add_argument("--vm", default="Windows 11")
    p.add_argument("--output", type=Path, default=ROOT / ".local/gt02-heroine-param/probe")
    p.add_argument("--coverage", type=Path, default=ROOT / ".local/gt02-heroine-param/coverage")
    p.add_argument("--errno-baseline", type=int, help="Parallels errno-24 count that must hold before each exec")
    p.add_argument("--inspect", type=Path, help="ikkoku-inspect binary (compare)")
    a = p.parse_args()
    if ".local" not in a.output.resolve().parts:
        raise ValueError("Outputs must stay under .local")
    a.output.mkdir(parents=True, exist_ok=True)
    if a.command == "run":
        if a.errno_baseline is None: p.error("run needs --errno-baseline")
        print(json.dumps(run(a), indent=2))
    else:
        if a.inspect is None: p.error("compare needs --inspect")
        print(json.dumps(compare(a), indent=2))


if __name__ == "__main__":
    main()
