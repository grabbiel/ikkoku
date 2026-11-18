#!/usr/bin/env python3
"""#401 ABMX oracle: what the original CharaStudio player with KKABMX 5.4 reads from, and draws for, a scene character
whose boneData uses the older layout ([BoneName, CoordinateModifiers] records, [Scale, Length] entries).

`run` is one VM phase in ONE `prlctl exec` (the original_wear_probe.py transport: run.ps1 served from a host-only HTTP
endpoint; original_map_probe.exec_command, refused at EXEC_LIMIT characters). run.ps1:

1. sets up a fresh private player root (original_character_probe.PLAYER_SETUP: copies of CharaStudio.exe, the loader
   and BepInEx core; junctions to abdata and CharaStudio_Data);
2. reads the four installed plug-ins in PLUGINS (Extended Save, KKAPI, KKAPI.NativeHelper, KKABMX), read-only: each
   one's SHA-256 and size must match the installed-plug-in inventory. Each is COPIED into the root's own
   BepInEx\\plugins at the same relative path and the copy's hash checked; never a junction, because a junction is
   writable. Their config files are copied too when the install has them (read-only, hashes recorded);
3. downloads fixtures/OriginalABMXProbe.cs, abmx-cases.tsv and the scene records (abmx-<label>.png), and compiles the
   probe;
4. runs the player once, bounded by --wait-seconds; the probe refuses to run unless KKABMX.Core 5.4, KKAPI and Extended
   Save are loaded;
5. zips the probe's abmx folder with unity.log and LogOutput.log and PUTs it back. Clean-up is
   original_map_probe.with_root_guard's: anything left in the root is stopped and drained, the two junctions are
   removed (link only, after checking they are reparse points), and the root is removed only when no process remains
   and no reparse point is under it.

The cases come from --cases, a host TSV: <label> TAB <scene record> TAB <scene SHA-256> TAB <object key> TAB <sex>
[TAB <mode>]. The mode is card (the default) or synthetic: a synthetic case also adds the probe's constant modifiers
in memory with ABMX's own API, records the character again after them and serializes them with ABMX's own writer
(see the probe's header). The label is the scene's SHA-256 prefix (12 hex) and the object key, e.g. 0123456789ab-1000, so no scene name
reaches the VM or the evidence. Each scene record must hash as listed. Nothing in C:\\Illusion\\Koikatsu is written;
abdata and CharaStudio_Data are scanned before and after (original_map_probe.with_junction_scans) and targetsChanged
says whether the scans differ. The Parallels errno-24 count must equal --errno-baseline before the exec; it is
recorded before and after. Outputs stay under .local. `dry-run` makes every host-side check and writes run.ps1 (the
endpoint replaced by a placeholder) without the VM or an endpoint.
"""
from __future__ import annotations
import argparse, json, re, shlex, subprocess, uuid
from pathlib import Path
from original_character_probe import PLAYER_ROOT, PLAYER_SETUP
from original_map_probe import EXEC_LIMIT, digest, dump, exec_command, log, private, with_junction_scans, with_root_guard
from original_wear_probe import Endpoint, errno_count, extract, fresh_root, guarded

PROBE = Path(__file__).with_name('fixtures') / 'OriginalABMXProbe.cs'
PROBE_NAMES = ('ABMXProbe.cs', 'IkkokuABMXProbe.dll')  # as written in run_script
# BepInEx\plugins-relative path, SHA-256 and size of each installed plug-in the probe needs, from the installed-plug-in
# inventory (.local/codex-continue-2026-10-24/wave-three/plugins/installed-inventory: declared-entries.json and
# source-manifest-before.json). KKABMX.Core 5.4 depends on com.bepis.bepinex.extendedsave and marco.kkapi >= 1.34;
# KKAPI 1.46.1 on com.bepis.bepinex.extendedsave >= 19.4 (its MoreAccessories dependency is soft); Extended Save
# 21.1.2.1 on nothing. KKAPI.NativeHelper ships beside KKAPI.
PLUGINS = (
    ('KK_BepisPlugins\\ExtensibleSaveFormat.dll', '7b1c7f0405ebb5dad84e6fca85d9f5594f9423dbb6e9135a3cce6e60765143be', 65024),
    ('KKAPI.dll', '7f4f50e1e3306ded40ea0676ea891d1264964dd2821caa8e111b9002a3f69a18', 444416),
    ('KKAPI.NativeHelper.dll', '09ab8d27b7e0acfbbed61a300f6b676834d086c0843c504b716e595b30bfc098', 31744),
    ('KKABMX.dll', 'f3e2d9877b08b2b25187cbc101478ea0d484bcfe4856244050ba3119578e9f68', 153088),
)
CONFIGS = ('KKABMX.Core.cfg', 'marco.kkapi.cfg', 'com.bepis.bepinex.extendedsave.cfg')
LABEL = re.compile(r'[0-9a-f]{12}-[0-9]+')
UPLOAD = 'abmx.zip'  # as written in run_script
MAX_SCENE_BYTES = 64 * 1024 * 1024


def cases_from(path):
    """The --cases TSV as (uploads {abmx-<label>.png: bytes}, abmx-cases.tsv bytes for the probe, case records)."""
    uploads, rows, records = {}, [], []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip(): continue
        fields = line.split('\t')
        if len(fields) not in (5, 6): raise ValueError(f'case line {number}: expected 5 or 6 tab-separated fields')
        label, scene, sha, key, sex = fields[:5]
        mode = fields[5] if len(fields) == 6 else 'card'
        if mode not in ('card', 'synthetic'): raise ValueError(f'case line {number}: mode must be card or synthetic')
        if not LABEL.fullmatch(label): raise ValueError(f'case line {number}: label must be <12 hex>-<key>')
        if not re.fullmatch(r'[0-9a-f]{64}', sha) or not sha.startswith(label[:12]): raise ValueError(f'case line {number}: SHA-256 must start with the label')
        if not key.isdigit() or label.split('-')[1] != key: raise ValueError(f'case line {number}: the label must end with the object key')
        if sex not in ('0', '1'): raise ValueError(f'case line {number}: sex must be 0 or 1')
        name = f'abmx-{label}.png'
        if name in uploads: raise ValueError(f'case line {number}: duplicate label')
        data = Path(scene).read_bytes()
        if len(data) > MAX_SCENE_BYTES or not data.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError(f'case line {number}: not a PNG scene record within the size bound')
        if digest(data) != sha: raise ValueError(f'case line {number}: scene record SHA-256 differs')
        uploads[name] = data
        rows.append('\t'.join((label, key, sex, mode)))
        records.append(dict(label=label, sceneSHA256=sha, key=int(key), sex=int(sex), mode=mode))
    if not records: raise ValueError('no cases')
    return uploads, ('\n'.join(rows) + '\n').encode(), records


def run_script(root, base, wait_seconds, uploads):
    """The phase as run.ps1, before with_junction_scans and with_root_guard. `base` is the endpoint URL ending in the
    token and '/'."""
    if not re.fullmatch(PLAYER_ROOT, root): raise ValueError('Unknown private player root')
    if not isinstance(wait_seconds, int) or wait_seconds <= 0: raise ValueError('wait_seconds must be a positive integer')
    if not uploads or any(not re.fullmatch(r'abmx-[0-9a-f]{12}-[0-9]+\.png', n) for n in uploads): raise ValueError('Unexpected scene upload names')
    names = ','.join("'" + n + "'" for n in uploads)
    plugins = ','.join("@('" + path + "','" + sha + "'," + str(size) + ')' for path, sha, size in PLUGINS)
    configs = ','.join("'" + n + "'" for n in CONFIGS)
    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$r=[ordered]@{root=$root}\n"
            + r"""if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
function Fetch($name,$path){Invoke-WebRequest -UseBasicParsing -Uri ($base+$name) -OutFile $path;(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Sha($path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Own{@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root+'\')})}
try{
""" + PLAYER_SETUP + r"""
$p="$root\BepInEx\plugins";$out="$p\abmx";New-Item -ItemType Directory $out -Force|Out-Null
$r.plugins=@()
foreach($e in @(""" + plugins + r""")){$src=Join-Path "$original\BepInEx\plugins" $e[0];$f=Get-Item -LiteralPath $src
$i=[ordered]@{path=$e[0];sha256=Sha $src;bytes=$f.Length;fileVersion=$f.VersionInfo.FileVersion;productVersion=$f.VersionInfo.ProductVersion}
if($i.sha256 -ne $e[1] -or $i.bytes -ne $e[2]){throw "Installed plug-in differs from the inventory: $($e[0]) $($i.sha256) $($i.bytes)"}
$dst=Join-Path $p $e[0];New-Item -ItemType Directory (Split-Path $dst) -Force|Out-Null;Copy-Item -LiteralPath $src -Destination $dst
$i.copySHA256=Sha $dst;if($i.copySHA256 -ne $i.sha256){throw "Plug-in copy differs from the installed file: $($e[0])"}
$r.plugins+=,$i}
$r.configs=[ordered]@{}
foreach($n in @(""" + configs + r""")){$c="$original\BepInEx\config\$n";$d="$root\BepInEx\config\$n";$r.configs[$n]=$null
if(Test-Path -LiteralPath $c){Copy-Item -LiteralPath $c -Destination $d;$r.configs[$n]=[ordered]@{sourceSHA256=Sha $c;sha256=Sha $d;bytes=(Get-Item -LiteralPath $d).Length}}}
$r.source=Fetch 'ABMXProbe.cs' "$root\ABMXProbe.cs"
$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuABMXProbe.dll" /reference:$($refs -join ',') "$root\ABMXProbe.cs" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"}
$r.cases=Fetch 'abmx-cases.tsv' "$p\abmx-cases.tsv"
$r.scenes=[ordered]@{};foreach($n in @(""" + names + r""")){$r.scenes[$n]=Fetch $n "$p\$n"}
$x=Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru;$null=$x.Handle
$r.processID=$x.Id;$r.exited=$x.WaitForExit(""" + str(wait_seconds * 1000) + r""");if($r.exited){$r.exitCode=$x.ExitCode}
$left=Own;$left|Stop-Process -Force;$r.stopped=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 2
foreach($n in @('unity.log','BepInEx\LogOutput.log')){if(Test-Path -LiteralPath "$root\$n"){Copy-Item -LiteralPath "$root\$n" "$out\$(Split-Path $n -Leaf)"}}
Add-Type -AssemblyName System.IO.Compression.FileSystem;$z="$root\abmx.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($out,$z);$r.zipSHA256=Sha $z;$r.zipBytes=(Get-Item -LiteralPath $z).Length
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $z -ContentType 'application/zip' -Uri ($base+'abmx.zip')|Out-Null
}catch{$r.error=$_.ToString()}
finally{
$left=Own;$left|Stop-Process -Force -ErrorAction SilentlyContinue;$r.stoppedAtCleanup=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 1
$kept=@()
foreach($j in @("$root\abdata","$root\CharaStudio_Data")){if(Test-Path -LiteralPath $j){if((Get-Item -LiteralPath $j -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){cmd /c rmdir "$j"|Out-Null}if(Test-Path -LiteralPath $j){$kept+=$j}}}
if($kept.Count){$r.cleanupError='junctions not removed: '+($kept -join ', ')}elseif(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
$r.removed=-not(Test-Path -LiteralPath $root);$r.remainingGameProcesses=@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 4
""")


def phase_script(root, base, wait_seconds, uploads):
    """run.ps1 as served: run_script with the junction scans and the root guard."""
    return with_root_guard(with_junction_scans(run_script(root, base, wait_seconds, list(uploads))))


def inventory_check(manifest):
    """PLUGINS against the inventory's source manifest (relativePath, length, sha256 of every installed plug-in)."""
    rows, seen = [], {}
    def walk(x):
        if isinstance(x, dict):
            if isinstance(x.get('relativePath'), str) and 'sha256' in x: seen[x['relativePath'].replace('/', '\\')] = x
            for v in x.values(): walk(v)
        elif isinstance(x, list):
            for v in x: walk(v)
    walk(json.loads(Path(manifest).read_text()))
    for path, sha, size in PLUGINS:
        entry = seen.get(path)
        rows.append(dict(path=path, sha256=sha, bytes=size, inventory=None if entry is None else dict(sha256=entry['sha256'], bytes=entry['length']),
                         match=entry is not None and entry['sha256'] == sha and entry['length'] == size))
    return rows


def dry_run(args):
    """Every host-side check without the VM or an endpoint: the cases, the plug-in table against the inventory, run.ps1
    (written to --output with a placeholder endpoint) and the exec command's length."""
    output = private(args.output)
    if output.exists(): raise RuntimeError(f'{output} exists: dry-run into a new output folder')
    uploads, cases_tsv, cases = cases_from(args.cases)
    source = PROBE.read_bytes()
    base = f'http://{args.host_address}:65535/{uuid.uuid4().hex}/'
    script = phase_script(fresh_root(), base, args.wait_seconds, uploads)
    command = exec_command(args.vm, base)
    plugins = inventory_check(args.inventory) if args.inventory else None
    if plugins is not None and not all(p['match'] for p in plugins): raise ValueError('PLUGINS differ from the inventory: ' + json.dumps(plugins))
    output.mkdir(parents=True)
    (output / 'run.ps1').write_text(script.replace(base, '<endpoint>/'))
    (output / 'abmx-cases.tsv').write_bytes(cases_tsv)
    record = dict(dryRun=True, cases=cases, uploads={n: dict(bytes=len(d), sha256=digest(d)) for n, d in uploads.items()},
                  casesTSV=dict(bytes=len(cases_tsv), sha256=digest(cases_tsv)), source=dict(bytes=len(source), sha256=digest(source)),
                  plugins=plugins, runScriptChars=len(script), runScriptSHA256=digest((output / 'run.ps1').read_bytes()),
                  execCommandChars=len(shlex.join(command)), execLimit=EXEC_LIMIT, errnoNow=errno_count())
    dump(output / 'dry-run.json', record)
    return record


def run(args):
    """The VM phase in one `prlctl exec` (see the module docstring)."""
    output = private(args.output)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    uploads, cases_tsv, cases = cases_from(args.cases)
    source = PROBE.read_bytes()
    root = fresh_root()
    record = dict(vm=args.vm, root=root, sourceSHA256=digest(source), casesSHA256=digest(cases_tsv), cases=cases,
                  uploads={n: digest(d) for n, d in uploads.items()}, plugins=[dict(path=p, sha256=s, bytes=b) for p, s, b in PLUGINS],
                  waitSeconds=args.wait_seconds, errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint (original_wear_probe transport), junction scans and root guard')
    output.mkdir(parents=True, exist_ok=True); dump(output / 'run.json', record)
    files = {PROBE_NAMES[0]: source, 'abmx-cases.tsv': cases_tsv, **uploads}
    try:
        with Endpoint(args.host_address, files, upload=UPLOAD) as endpoint:
            log('endpoint-start ' + endpoint.base.rsplit('/', 2)[0] + '/')
            script = phase_script(root, endpoint.base, args.wait_seconds, uploads)
            files['run.ps1'] = script.encode()
            (output / 'run.ps1').write_text(script.replace(endpoint.base, '<endpoint>/'))
            command = exec_command(args.vm, endpoint.base)
            record['execCommandChars'] = len(shlex.join(command)); dump(output / 'run.json', record)
            result = subprocess.run(command, text=True, capture_output=True, timeout=args.wait_seconds + 900)
            upload = endpoint.upload
    finally:
        log('endpoint-stop')
    record['errnoAfter'] = errno_count()
    if result.returncode:
        record['execError'] = (result.stderr or result.stdout)[-4000:]; dump(output / 'run.json', record)
        raise RuntimeError('VM exec failed: ' + record['execError'])
    guest = json.loads(result.stdout.lstrip('\ufeff').strip())
    record['guest'] = guest; dump(output / 'run.json', record)
    if guest.get('source') not in (None, digest(source)): raise ValueError('Guest probe source hash differs')
    if guest.get('cases') not in (None, digest(cases_tsv)): raise ValueError('Guest case list hash differs')
    for name, data in uploads.items():
        if (guest.get('scenes') or {}).get(name) not in (None, digest(data)): raise ValueError('Guest scene hash differs: ' + name)
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    (output / 'probe-source.cs').write_bytes(source); (output / 'abmx-cases.tsv').write_bytes(cases_tsv)
    provenance = [dict(file=p.name, sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted(output / n for n in set(names + ['run.json', 'run.ps1', 'probe-source.cs', 'abmx-cases.tsv'])) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, files=provenance))
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    return dict(root=root, processID=guest.get('processID'), exited=guest.get('exited'), error=guest.get('error'), cleanupError=guest.get('cleanupError'),
                removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'), pending=guest.get('pending'),
                reparsePoints=guest.get('reparsePoints'), errno=[record['errnoBefore'], record['errnoAfter']],
                scansEqual=guest.get('scanBefore') is not None and guest.get('scanBefore') == guest.get('scanAfter'),
                targetsChanged=guest.get('targetsChanged'), plugins=guest.get('plugins'), configs=guest.get('configs'),
                statusError=None if status is None else status.get('error'), written=None if status is None else status.get('written'), files=len(provenance))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = p.add_subparsers(dest='command', required=True)
    for name, text in (('run', 'the one-exec VM phase'), ('dry-run', 'every host-side check and run.ps1, without the VM')):
        c = commands.add_parser(name, help=text)
        c.add_argument('--vm', default='Windows 11')
        c.add_argument('--cases', type=Path, required=True, help='host TSV: label, scene record, scene SHA-256, object key, sex[, mode card|synthetic]')
        c.add_argument('--output', type=Path, required=True, help='a new folder under .local')
        c.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
        c.add_argument('--wait-seconds', type=int, default=600, help='bound on the player run')
        if name == 'run': c.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
        else: c.add_argument('--inventory', type=Path, help="the installed-plug-in inventory's source-manifest-before.json, to check PLUGINS")
    args = p.parse_args()
    print(json.dumps((run if args.command == 'run' else dry_run)(args), indent=2))


if __name__ == '__main__':
    main()
