#!/usr/bin/env python3
"""Extended shape rates (Slider Unlocker): original-player references for scene characters with rates outside 0...1.

`run` is one VM phase in ONE `prlctl exec` (the original_wear_probe.py transport: run.ps1 served from a host-only HTTP
endpoint). run.ps1:

1. sets up a fresh private player root (original_character_probe.PLAYER_SETUP: copies of CharaStudio.exe, the loader
   and BepInEx core; junctions to abdata and CharaStudio_Data);
2. reads the installed BepInEx\\plugins\\KK_BepisPlugins\\SliderUnlocker.dll, read-only: its SHA-256 and size (which
   must match SLIDER, from the installed-plug-in inventory) and its version resource (FileVersion, ProductVersion and
   the other VersionInfo strings). It then COPIES the DLL into the root's own BepInEx\\plugins and checks the copy's
   hash; never a junction, because a junction is writable. The plug-in's config file is copied too when the install
   has one (read-only, hash recorded);
3. downloads fixtures/OriginalSliderProbe.cs, slider-cards.tsv and the scene records (slider-<label>.png), and
   compiles the probe;
4. runs the player twice, each bounded by --wait-seconds: the "unlocked" run with the Slider Unlocker copy, then the
   "vanilla" run after deleting that copy (and the config copy) from the root. The probe checks that the plug-in is
   loaded exactly in the unlocked run;
5. zips the probe's slider folder with each run's unity.log and LogOutput.log, PUTs it back, stops anything left in
   the root by path and by process ID, removes the two junctions (link only, after checking they are reparse
   points), refuses to delete a root that still holds any reparse point, and then removes the root.

The cases come from --cases, a host TSV: <label> TAB <scene record> TAB <scene SHA-256> TAB <object key> TAB <sex>
TAB <modes>. The label is the scene's SHA-256 prefix (12 hex) and the object key, e.g. df4c970a9e56-11395, so no scene
name reaches the VM or the evidence. Each scene record must hash as listed. Nothing in C:\\Illusion\\Koikatsu is
written; abdata and CharaStudio_Data are scanned before and after (original_map_probe.with_junction_scans). The
Parallels errno-24 count must equal --errno-baseline before the exec; it is recorded before and after. Outputs stay
under .local.
"""
from __future__ import annotations
import argparse, json, re, subprocess
from pathlib import Path
from original_character_probe import PLAYER_ROOT, PLAYER_SETUP
from original_map_probe import digest, dump, private, with_junction_scans
from original_wear_probe import Endpoint, bootstrap, errno_count, extract, fresh_root, guarded

PROBE = Path(__file__).with_name('fixtures') / 'OriginalSliderProbe.cs'
PROBE_NAMES = ('SliderProbe.cs', 'IkkokuSliderProbe.dll')
# BepInEx\plugins-relative path, SHA-256 and size from the installed-plug-in inventory
# (.local/codex-continue-2026-10-24/wave-three/plugins/installed-inventory/declared-entries.json):
# com.bepis.bepinex.sliderunlocker 21.1.2.1, no BepInDependency (it references only BepInEx core and 0Harmony).
SLIDER = ('KK_BepisPlugins\\SliderUnlocker.dll', '4a2e0e602cd98ed443acc11eddada4a987bd1afcb3658486e1ff6dd565463523', 42496)
SLIDER_CONFIG = 'com.bepis.bepinex.sliderunlocker.cfg'
LABEL = re.compile(r'[0-9a-f]{12}-[0-9]+')
MODES = ('unlocked', 'vanilla')
MAX_SCENE_BYTES = 64 * 1024 * 1024
MAX_COMMAND_CHARS = 3500


def cases_from(path):
    """The --cases TSV as (uploads {slider-<label>.png: bytes}, slider-cards.tsv bytes for the probe, case records)."""
    uploads, rows, records = {}, [], []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip(): continue
        fields = line.split('\t')
        if len(fields) != 6: raise ValueError(f'case line {number}: expected 6 tab-separated fields')
        label, scene, sha, key, sex, modes = fields
        if not LABEL.fullmatch(label): raise ValueError(f'case line {number}: label must be <12 hex>-<key>')
        if not sha.startswith(label[:12]) or not re.fullmatch(r'[0-9a-f]{64}', sha): raise ValueError(f'case line {number}: SHA-256 must start with the label')
        if label.split('-')[1] != key or not key.isdigit(): raise ValueError(f'case line {number}: the label must end with the object key')
        if sex not in ('0', '1'): raise ValueError(f'case line {number}: sex must be 0 or 1')
        wanted = modes.split(',')
        if not wanted or any(m not in MODES for m in wanted) or len(set(wanted)) != len(wanted): raise ValueError(f'case line {number}: modes must name unlocked and/or vanilla')
        name = f'slider-{label}.png'
        if name in uploads: raise ValueError(f'case line {number}: duplicate label')
        data = Path(scene).read_bytes()
        if len(data) > MAX_SCENE_BYTES or not data.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError(f'case line {number}: not a PNG scene record within the size bound')
        if digest(data) != sha: raise ValueError(f'case line {number}: scene record SHA-256 differs')
        uploads[name] = data
        rows.append('\t'.join((label, key, sex, ','.join(wanted))))
        records.append(dict(label=label, sceneSHA256=sha, key=int(key), sex=int(sex), modes=wanted))
    if not records: raise ValueError('no cases')
    for mode in MODES:
        if not any(mode in r['modes'] for r in records): raise ValueError(f'no case for the {mode} run')
    return uploads, ('\n'.join(rows) + '\n').encode(), records


def run_script(root, base, wait_seconds, uploads):
    """The whole phase as run.ps1 (before with_junction_scans). `base` is the endpoint URL ending in the token and '/'."""
    if not re.fullmatch(PLAYER_ROOT, root): raise ValueError('Unknown private player root')
    if not isinstance(wait_seconds, int) or wait_seconds <= 0: raise ValueError('wait_seconds must be a positive integer')
    if not uploads or any(not re.fullmatch(r'slider-[0-9a-f]{12}-[0-9]+\.png', n) for n in uploads): raise ValueError('Unexpected scene upload names')
    names = ','.join("'" + n + "'" for n in uploads)
    path, sha, size = SLIDER
    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$r=[ordered]@{root=$root}\n"
            + r"""if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
function Fetch($name,$path){Invoke-WebRequest -UseBasicParsing -Uri ($base+$name) -OutFile $path;(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Sha($path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Own{@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root+'\')})}
function Play($mode){[IO.File]::WriteAllText("$p\slider-mode.txt",$mode);$w=[Diagnostics.Stopwatch]::StartNew()
$x=Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru;$null=$x.Handle
$o=[ordered]@{processID=$x.Id;exited=$x.WaitForExit(""" + str(wait_seconds * 1000) + r""")};if($o.exited){$o.exitCode=$x.ExitCode}
$left=Own;$left|Stop-Process -Force;$o.stopped=@($left|ForEach-Object{$_.Id})
if(-not $x.HasExited){Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue;$o.stoppedByID=$x.WaitForExit(30000)}
Start-Sleep -Seconds 2;$o.seconds=[math]::Round($w.Elapsed.TotalSeconds,1)
foreach($n in @('unity.log','BepInEx\LogOutput.log')){if(Test-Path -LiteralPath "$root\$n"){Move-Item -LiteralPath "$root\$n" "$out\$mode-$(Split-Path $n -Leaf)"}}
$o}
try{
""" + PLAYER_SETUP + r"""
$p="$root\BepInEx\plugins";$out="$p\slider";New-Item -ItemType Directory $out -Force|Out-Null
$src=Join-Path "$original\BepInEx\plugins" '""" + path + r"""';$f=Get-Item -LiteralPath $src;$v=$f.VersionInfo
$r.installed=[ordered]@{path='""" + path + r"""';sha256=Sha $src;bytes=$f.Length;lastWriteUtc=$f.LastWriteTimeUtc.ToString('o');fileVersion=$v.FileVersion;productVersion=$v.ProductVersion;fileVersionParts=@($v.FileMajorPart,$v.FileMinorPart,$v.FileBuildPart,$v.FilePrivatePart);productVersionParts=@($v.ProductMajorPart,$v.ProductMinorPart,$v.ProductBuildPart,$v.ProductPrivatePart);fileDescription=$v.FileDescription;productName=$v.ProductName;internalName=$v.InternalName;originalFilename=$v.OriginalFilename;companyName=$v.CompanyName;legalCopyright=$v.LegalCopyright;comments=$v.Comments;isDebug=$v.IsDebug;language=$v.Language}
if($r.installed.sha256 -ne '""" + sha + r"""' -or $r.installed.bytes -ne """ + str(size) + r"""){throw "Installed Slider Unlocker differs from the inventory: $($r.installed.sha256) $($r.installed.bytes)"}
$dst="$p\SliderUnlocker.dll";Copy-Item -LiteralPath $src -Destination $dst;$r.copy=[ordered]@{sha256=Sha $dst;bytes=(Get-Item -LiteralPath $dst).Length}
if($r.copy.sha256 -ne $r.installed.sha256 -or $r.copy.bytes -ne $r.installed.bytes){throw 'Slider Unlocker copy differs from the installed file'}
$cfg="$original\BepInEx\config\com.bepis.bepinex.sliderunlocker.cfg";$cfgCopy="$root\BepInEx\config\com.bepis.bepinex.sliderunlocker.cfg";$r.config=$null
if(Test-Path -LiteralPath $cfg){Copy-Item -LiteralPath $cfg -Destination $cfgCopy;$r.config=[ordered]@{sha256=Sha $cfgCopy;bytes=(Get-Item -LiteralPath $cfgCopy).Length;sourceSHA256=Sha $cfg}}
$r.source=Fetch 'SliderProbe.cs' "$root\SliderProbe.cs"
$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuSliderProbe.dll" /reference:$($refs -join ',') "$root\SliderProbe.cs" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"}
$r.cards=Fetch 'slider-cards.tsv' "$p\slider-cards.tsv"
$r.scenes=[ordered]@{};foreach($n in @(""" + names + r""")){$r.scenes[$n]=Fetch $n "$p\$n"}
$r.unlocked=Play 'unlocked'
Remove-Item -LiteralPath $dst;if(Test-Path -LiteralPath $cfgCopy){Remove-Item -LiteralPath $cfgCopy}
$r.vanillaWithoutPlugin=-not(Test-Path -LiteralPath $dst) -and -not(Test-Path -LiteralPath $cfgCopy)
if(-not $r.vanillaWithoutPlugin){throw 'Slider Unlocker copy not removed before the vanilla run'}
$r.vanilla=Play 'vanilla'
Add-Type -AssemblyName System.IO.Compression.FileSystem;$z="$root\slider.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($out,$z);$r.zipSHA256=Sha $z;$r.zipBytes=(Get-Item -LiteralPath $z).Length
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $z -ContentType 'application/zip' -Uri ($base+'slider.zip')|Out-Null
}catch{$r.error=$_.ToString()}
finally{
$left=Own;$left|Stop-Process -Force -ErrorAction SilentlyContinue;$r.stoppedAtCleanup=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 1
$kept=@()
foreach($j in @("$root\abdata","$root\CharaStudio_Data")){if(Test-Path -LiteralPath $j){if((Get-Item -LiteralPath $j -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){cmd /c rmdir "$j"|Out-Null}if(Test-Path -LiteralPath $j){$kept+=$j}}}
$links=@();if(Test-Path -LiteralPath $root){$links=@(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}|ForEach-Object{$_.FullName})}
if($kept.Count){$r.cleanupError='junctions not removed: '+($kept -join ', ')}elseif($links.Count){$r.cleanupError='reparse points left in the root: '+($links -join ', ')}elseif(Test-Path -LiteralPath $root){try{Remove-Item -LiteralPath $root -Recurse -Force}catch{$r.cleanupError='root removal: '+$_.ToString()}}
$r.removed=-not(Test-Path -LiteralPath $root);$r.remainingGameProcesses=@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 4
""")


def exec_command(vm, base):
    """The prlctl command line; it only fetches and runs run.ps1, so it stays far below Parallels' limit."""
    command = ['prlctl', 'exec', vm, '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', bootstrap(base)]
    if len(' '.join(command)) > MAX_COMMAND_CHARS: raise ValueError('prlctl command exceeds the length bound')
    return command


def run(args):
    """The VM phase in one `prlctl exec` (see the module docstring)."""
    output = private(args.output)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    uploads, cards, cases = cases_from(args.cases)
    source = PROBE.read_bytes()
    root = fresh_root()
    record = dict(vm=args.vm, root=root, sourceSHA256=digest(source), cardsSHA256=digest(cards), cases=cases,
                  uploads={n: digest(d) for n, d in uploads.items()}, slider=dict(path=SLIDER[0], sha256=SLIDER[1], bytes=SLIDER[2]),
                  waitSeconds=args.wait_seconds, errnoBaseline=args.errno_baseline, errnoBefore=guarded(args.errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint (original_wear_probe transport)')
    output.mkdir(parents=True, exist_ok=True); dump(output / 'run.json', record)
    files = {PROBE_NAMES[0]: source, 'slider-cards.tsv': cards, **uploads}
    with Endpoint(args.host_address, files, upload='slider.zip') as endpoint:
        script = with_junction_scans(run_script(root, endpoint.base, args.wait_seconds, list(uploads)))
        files['run.ps1'] = script.encode()
        (output / 'run.ps1').write_text(script.replace(endpoint.base, '<endpoint>/'))
        command = exec_command(args.vm, endpoint.base)
        record['commandChars'] = len(' '.join(command)); dump(output / 'run.json', record)
        result = subprocess.run(command, text=True, capture_output=True, timeout=2 * args.wait_seconds + 900)
        upload = endpoint.upload
    record['errnoAfter'] = errno_count()
    if result.returncode:
        record['execError'] = (result.stderr or result.stdout)[-4000:]; dump(output / 'run.json', record)
        raise RuntimeError('VM exec failed: ' + record['execError'])
    guest = json.loads(result.stdout.lstrip('\ufeff').strip())
    record['guest'] = guest; dump(output / 'run.json', record)
    if guest.get('source') not in (None, digest(source)): raise ValueError('Guest probe source hash differs')
    if guest.get('cards') not in (None, digest(cards)): raise ValueError('Guest case list hash differs')
    for name, data in uploads.items():
        if (guest.get('scenes') or {}).get(name) not in (None, digest(data)): raise ValueError('Guest scene hash differs: ' + name)
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    (output / 'probe-source.cs').write_bytes(source); (output / 'slider-cards.tsv').write_bytes(cards)
    provenance = [dict(file=p.name, sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted(output / n for n in set(names + ['run.json', 'run.ps1', 'probe-source.cs', 'slider-cards.tsv'])) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, files=provenance))
    status = {m: json.loads((output / f'{m}-status.json').read_text()) for m in MODES if (output / f'{m}-status.json').is_file()}
    installed = guest.get('installed') or {}
    return dict(root=root, error=guest.get('error'), cleanupError=guest.get('cleanupError'), removed=guest.get('removed'),
                remainingGameProcesses=guest.get('remainingGameProcesses'), errno=[record['errnoBefore'], record['errnoAfter']],
                scansEqual=guest.get('scanBefore') is not None and guest.get('scanBefore') == guest.get('scanAfter'),
                fileVersion=installed.get('fileVersion'), productVersion=installed.get('productVersion'), config=guest.get('config') is not None,
                runs={m: guest.get(m) for m in MODES}, written={m: s.get('written') for m, s in status.items()},
                statusErrors={m: s.get('error') for m, s in status.items()}, files=len(provenance))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = p.add_subparsers(dest='command', required=True)
    r = commands.add_parser('run', help='the one-exec VM phase')
    r.add_argument('--vm', default='Windows 11')
    r.add_argument('--cases', type=Path, required=True, help='host TSV: label, scene record, scene SHA-256, object key, sex, modes')
    r.add_argument('--output', type=Path, required=True, help='a new folder under .local')
    r.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    r.add_argument('--host-address', default='10.211.55.2')
    r.add_argument('--wait-seconds', type=int, default=600, help='bound for each of the two player runs')
    args = p.parse_args()
    print(json.dumps(run(args), indent=2))


if __name__ == '__main__':
    main()
