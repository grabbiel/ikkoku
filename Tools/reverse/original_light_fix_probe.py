#!/usr/bin/env python3
"""Original-player check of survey 3's stale Sideloader records (ST-T03k, phase E).

Survey 3 counted 8 installed scenes with a Sideloader record naming an object the scene does not have. The records
name nested lights the survey itself dropped (docs/reference/studio/scene-editing.md, "Survey 3's stale Sideloader
records"): CharaStudio reads a nested light only while fewer than two lights are counted, the survey never reset
that count between scenes, and its player root lacked KK_Fix_UnlimitedMapLights, which the install has. This phase
confirms that on the player, and runs survey 4.

One `prlctl exec` (original_wear_probe.py's transport: run.ps1 served from a host-only HTTP endpoint) sets up a
fresh private player root (original_character_probe.PLAYER_SETUP) and then:

1. Copies phase D's plug-in set (original_plugin_scene_probe.PLUGINS and PLUGINS_B) and KK_Fix_UnlimitedMapLights
   (LIGHT_FIX) from the install's BepInEx\\plugins into the root's own, each checked against its SHA-256 and size
   from the installed-plug-in inventory. They are copied, never junctioned.
2. Copies the scenes to load: the files under the install's UserData\\studio\\scene with the SHA-256 values the host
   names (the tally report's scenes whose Sideloader records name nested lights), read-only, into the root's
   reload-input as scene-<12 hex>.png. Every one must be found.
3. Copies the zipmods those scenes' records name: each .zipmod under the install's mods whose manifest GUID is in
   guids.txt, read-only, into the root's own mods folder, within --mods-max-bytes in all and --scan-seconds of
   scanning. Copies are named m<N>.zipmod and hash like their originals; only counts are recorded.
4. Compiles fixtures/OriginalLightFixProbe.cs with original_plugin_scene_probe.SOURCES_B and runs the player twice:
   - "fix": with the light fix. The probe loads every scene and records what Sideloader's load reached and
     resolved, then repeats the rule parity check on corpus.txt and runs survey 4 over the install's scene folder.
   - "nofix": after run.ps1 removes the light fix from the root. The same loads, CharaStudio's load-then-save of the
     scene resave.txt names (inside the root), and the survey's model of each scene (the light counts).
   Each launch writes -logFile into the root; its unity.log and LogOutput.log are kept per launch.
5. Zips the probe folder, PUTs it back, stops any process left in the root, removes the junctions and then the root.

Before PLAYER_SETUP and after the cleanup, run.ps1 records the file count, directory count and newest write time
under both junction targets (junctionTargetsChanged must be false). Nothing in C:\\Illusion\\Koikatsu is written.
The Parallels errno-24 count must equal --errno-baseline before the exec. Outputs stay under .local; no scene name,
mod name or GUID leaves the guest except guids.txt, which the host sent.
"""
from __future__ import annotations
import argparse, json, re, subprocess
from pathlib import Path
from original_character_probe import PLAYER_SETUP, PLAYER_ROOT
from original_wear_probe import Endpoint, bootstrap, extract, errno_count, guarded, fresh_root, digest, dump
from original_plugin_scene_probe import PLUGINS, PLUGINS_B, SOURCES_B, TREE, local_roots

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name('fixtures')
PROBE = FIXTURES / 'OriginalLightFixProbe.cs'
# From the installed-plug-in inventory (coverage-index.json, snapshot 0068.dll): KK_Fix_UnlimitedMapLights 22.1.
LIGHT_FIX = ('IllusionFixes\\KK_Fix_UnlimitedMapLights.dll', '23051ec9d3e6779b0dd612208dd381beb3c8855ecad5caada6075a7a0272e40e', 13312)
# Survey 4 as predicted from the Swift writer (scene-editing.md, "Survey 4 (prediction)"): all/some/none of 61.
PREDICTION = {'delete': (36, 21, 4), 'duplicate': (35, 22, 4), 'addFolder': (58, 0, 3), 'addLight': (55, 0, 6),
              'addCamera': (58, 0, 3)}
SHA = re.compile(r'[0-9a-f]{64}')
GUID = re.compile(r'[^\r\n\x00]{1,200}')


def scenes_from_report(report):
    """The tally report's scenes whose Sideloader records name nested lights: [(sha256, bytes, row)], distinct."""
    seen, result = set(), []
    for row in report['rows']:
        if row.get('recordsNamingNestedLights', 0) > 0 and row['sha256'] not in seen:
            seen.add(row['sha256']); result.append((row['sha256'], row['bytes'], row))
    return result


def phase_script(root, base, scenes, wait_fix, wait_nofix, survey_seconds, survey_file_bytes, mods_max_bytes,
                 scan_seconds, inputs):
    """Phase E as run.ps1. `scenes` is [(sha256, bytes)]; `inputs` the names the endpoint serves for reload-input."""
    if not re.fullmatch(PLAYER_ROOT, root): raise ValueError('Unknown private player root')
    for value in (wait_fix, wait_nofix, survey_seconds, survey_file_bytes, mods_max_bytes, scan_seconds):
        if not isinstance(value, int) or value <= 0: raise ValueError('Bounds must be positive integers')
    if not scenes or not all(SHA.fullmatch(sha) and isinstance(size, int) and size > 0 for sha, size in scenes):
        raise ValueError('Unexpected scene list')
    if not all(re.fullmatch(r'[A-Za-z0-9.-]+', name) for name in inputs): raise ValueError('Unexpected input name')
    plugins = ','.join("@('%s','%s',%d)" % entry for entry in PLUGINS + PLUGINS_B + (LIGHT_FIX,))
    # "sha:bytes;sha:bytes", split in the guest: a one-scene @(@(a,b)) would flatten to @(a,b).
    wanted = ';'.join('%s:%d' % (sha, size) for sha, size in scenes)
    names = ','.join("'%s'" % name for name in inputs)
    sources = ('OriginalLightFixProbe.cs',) + SOURCES_B

    def launch(phase, seconds):
        # PHASE and MILLISECONDS are filled in after the raw text, which keeps its backslashes as PowerShell reads them.
        return r"""[IO.File]::WriteAllText("$in\phase.txt",'PHASE')
$launchArgs=@('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity-PHASE.log")
$x=Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList $launchArgs -PassThru
$run=[ordered]@{arguments=$launchArgs;processID=$x.Id;exited=$x.WaitForExit(MILLISECONDS)}
$left=Own;$left|Stop-Process -Force;$run.stopped=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 2
New-Item -ItemType Directory "$out\PHASE" -Force|Out-Null
foreach($n in @('unity-PHASE.log','BepInEx\LogOutput.log')){if(Test-Path -LiteralPath "$root\$n"){Copy-Item -LiteralPath "$root\$n" "$out\PHASE\$(Split-Path $n -Leaf)"}}
$r.launches['PHASE']=$run
""".replace('PHASE', phase).replace('MILLISECONDS', str(seconds * 1000))

    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$r=[ordered]@{root=$root;phase='E';launches=[ordered]@{}}\n"
            + r"""if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
function Fetch($name,$path){Invoke-WebRequest -UseBasicParsing -Uri ($base+$name) -OutFile $path;(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Sha($path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Own{@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root+'\')})}
$original='C:\Illusion\Koikatsu'
""" + TREE + r"""$r.junctionTargetsBefore=Targets
if($r.junctionTargetsBefore.error){throw "Junction targets could not be scanned: $($r.junctionTargetsBefore.error)"}
try{
""" + PLAYER_SETUP + r"""
$p="$root\BepInEx\plugins";$out="$p\reload";$in="$p\reload-input";New-Item -ItemType Directory $out,$in,"$root\mods" -Force|Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$r.plugins=@()
foreach($e in @(""" + plugins + r""")){
$src=Join-Path "$original\BepInEx\plugins" $e[0];$dst=Join-Path $p $e[0];New-Item -ItemType Directory (Split-Path $dst) -Force|Out-Null
Copy-Item -LiteralPath $src -Destination $dst;$h=Sha $dst;$n=(Get-Item -LiteralPath $dst).Length
if($h -ne $e[1] -or $n -ne $e[2]){throw "Plug-in copy differs from the inventory: $($e[0]) $h $n"}
$r.plugins+=[ordered]@{path=$e[0];sha256=$h;bytes=$n}}
$r.inputs=[ordered]@{};foreach($n in @(""" + names + r""")){$r.inputs[$n]=Fetch $n "$in\$n"}
$want=@{};foreach($e in '""" + wanted + r"""'.Split(';')){$pair=$e.Split(':');$want[$pair[0]]=[long]$pair[1]};$sizes=@{};foreach($v in $want.Values){$sizes[$v]=1}
$r.scenes=[ordered]@{wanted=$want.Count;hashed=0;found=0}
foreach($f in @(Get-ChildItem -LiteralPath "$original\UserData\studio\scene" -Recurse -File -Filter '*.png' -ErrorAction SilentlyContinue|Sort-Object FullName)){
if($f.Name.StartsWith('._') -or -not $sizes.ContainsKey([long]$f.Length)){continue}
$r.scenes.hashed++;$h=Sha $f.FullName
if($want.ContainsKey($h)){$copy="$in\scene-$($h.Substring(0,12)).png"
if(-not(Test-Path -LiteralPath $copy)){Copy-Item -LiteralPath $f.FullName -Destination $copy;if((Sha $copy) -ne $h){throw 'A scene copy differs from its original'};$r.scenes.found++}}}
if($r.scenes.found -ne $want.Count){throw "Found $($r.scenes.found) of $($want.Count) scenes"}
$guids=New-Object 'Collections.Generic.HashSet[string]';foreach($g in [IO.File]::ReadAllLines("$in\guids.txt")){if($g.Trim()){[void]$guids.Add($g.Trim())}}
$r.mods=[ordered]@{guids=$guids.Count;scanned=0;matched=0;copied=0;copiedBytes=0;overBound=0;errors=0;truncated=$false};$have=New-Object 'Collections.Generic.HashSet[string]'
$w=[Diagnostics.Stopwatch]::StartNew()
foreach($m in @(Get-ChildItem -LiteralPath "$original\mods" -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -ieq '.zipmod'}|Sort-Object FullName)){
if($w.Elapsed.TotalSeconds -gt """ + str(scan_seconds) + r"""){$r.mods.truncated=$true;break}
$r.mods.scanned++;$z=$null;$guid=$null
try{$z=[IO.Compression.ZipFile]::OpenRead($m.FullName);$entry=$z.Entries|Where-Object{$_.FullName -ieq 'manifest.xml'}|Select-Object -First 1
if($entry){$sr=New-Object IO.StreamReader($entry.Open());$xml=[xml]$sr.ReadToEnd();$sr.Close();$guid=([string]$xml.manifest.guid).Trim()}
}catch{$r.mods.errors++}finally{if($z){$z.Dispose()}}
if(-not $guid -or -not $guids.Contains($guid)){continue}
$r.mods.matched++
if($r.mods.copiedBytes+$m.Length -gt """ + str(mods_max_bytes) + r"""){$r.mods.overBound++;continue}
$copy="$root\mods\m$($r.mods.copied).zipmod";Copy-Item -LiteralPath $m.FullName -Destination $copy
if((Sha $copy) -ne (Sha $m.FullName)){throw 'A zipmod copy differs from its original'}
$r.mods.copied++;$r.mods.copiedBytes+=$m.Length;[void]$have.Add($guid)}
$r.mods.guidsCopied=$have.Count;$r.mods.scanSeconds=[math]::Round($w.Elapsed.TotalSeconds,1)
[IO.File]::WriteAllText("$in\survey.txt","$original\UserData\studio\scene`n""" + str(survey_seconds) + '`n' + str(survey_file_bytes) + r"""`n")
$r.sources=[ordered]@{};foreach($n in @(""" + ','.join("'%s'" % n for n in sources) + r""")){$r.sources[$n]=Fetch $n "$root\$n"}
$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuLightFixProbe.dll" /reference:$($refs -join ',') """
            + ' '.join('"$root\\%s"' % n for n in sources) + r""" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"}
""" + launch('fix', wait_fix) + r"""$fix=Join-Path $p '""" + LIGHT_FIX[0] + r"""'
Remove-Item -LiteralPath $fix
$r.lightFixRemoved=-not(Test-Path -LiteralPath $fix)
if(-not $r.lightFixRemoved){throw 'The light fix is still in the root'}
""" + launch('nofix', wait_nofix) + r"""$z="$root\reload.zip";[IO.Compression.ZipFile]::CreateFromDirectory($out,$z);$r.zipSHA256=Sha $z;$r.zipBytes=(Get-Item -LiteralPath $z).Length
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $z -ContentType 'application/zip' -Uri ($base+'reload.zip')|Out-Null
}catch{$r.error=$_.ToString()}
finally{
$left=Own;$left|Stop-Process -Force -ErrorAction SilentlyContinue;$r.stoppedAtCleanup=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 1
$kept=@()
foreach($j in @("$root\abdata","$root\CharaStudio_Data")){if(Test-Path -LiteralPath $j){if((Get-Item -LiteralPath $j -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){cmd /c rmdir "$j"|Out-Null}if(Test-Path -LiteralPath $j){$kept+=$j}}}
if($kept.Count){$r.cleanupError='junctions not removed: '+($kept -join ', ')}elseif(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
$r.removed=-not(Test-Path -LiteralPath $root);$r.remainingGameProcesses=@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
$r.junctionTargetsAfter=Targets
$r.junctionTargetsChanged=(($r.junctionTargetsBefore|ConvertTo-Json -Compress) -ne ($r.junctionTargetsAfter|ConvertTo-Json -Compress))
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 6
""")


def inputs_for(report, corpus, resave=None):
    """The files the endpoint serves for reload-input, and the scene list: [(sha256, bytes)]."""
    chosen = scenes_from_report(report)
    if not chosen: raise ValueError('the report names no scene whose Sideloader records name nested lights')
    if resave is None:
        # The smallest scene a vanilla load would drop lights from.
        dropping = [entry for entry in chosen if entry[2].get('recordsNamingVanillaDroppedLights', 0) > 0]
        if not dropping: raise ValueError('the report names no scene a vanilla load drops lights from')
        resave = min(dropping, key=lambda entry: (entry[1], entry[0]))[0]
    if resave not in {sha for sha, _, _ in chosen}: raise ValueError('the resave scene is not among the loaded scenes')
    guids = sorted({guid for _, _, row in chosen for guid in row.get('sideloaderGUIDs', [])})
    if not all(GUID.fullmatch(guid) for guid in guids): raise ValueError('Unexpected GUID')
    files = {'guids.txt': ('\n'.join(guids) + '\n').encode(), 'resave.txt': (resave + '\n').encode(), 'corpus.txt': corpus}
    return files, [(sha, size) for sha, size, _ in chosen], resave


def run(vm, output, errno_baseline, report, corpus, host_address='10.211.55.2', wait_fix=2700, wait_nofix=1200,
        survey_seconds=900, survey_file_bytes=512 * 1024 * 1024, mods_max_bytes=4 << 30, scan_seconds=600, resave=None):
    """One-exec phase E into a new output folder: run.json, run.ps1, fix/ and nofix/ (traces, status, survey4.json,
    lights-control.json, the resave and the logs), source/ and manifest.json."""
    if not any(output.resolve().is_relative_to(root) for root in local_roots()): raise ValueError('Outputs must stay under .local')
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    files, scenes, resave = inputs_for(json.loads(report.read_text()), corpus.read_bytes(), resave)
    input_hashes = {name: digest(data) for name, data in files.items()}
    sources = {'OriginalLightFixProbe.cs': PROBE.read_bytes()}
    for name in SOURCES_B: sources[name] = (FIXTURES / name).read_bytes()
    output.mkdir(parents=True, exist_ok=True)
    root = fresh_root()
    record = dict(vm=vm, root=root, phase='E', sources={n: digest(b) for n, b in sources.items()}, inputs=input_hashes,
                  scenes=[dict(sha256=sha, bytes=size) for sha, size in scenes], resave=resave,
                  plugins=[dict(path=p, sha256=h, bytes=n) for p, h, n in PLUGINS + PLUGINS_B + (LIGHT_FIX,)],
                  bounds=dict(waitFix=wait_fix, waitNofix=wait_nofix, surveySeconds=survey_seconds,
                              surveyFileBytes=survey_file_bytes, modsMaxBytes=mods_max_bytes, scanSeconds=scan_seconds),
                  errnoBaseline=errno_baseline, errnoBefore=guarded(errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint')
    dump(output / 'run.json', record)
    served = dict(files); served.update(sources)
    timeout = wait_fix + wait_nofix + scan_seconds + 2400
    with Endpoint(host_address, served, upload='reload.zip') as endpoint:
        script = phase_script(root, endpoint.base, scenes, wait_fix, wait_nofix, survey_seconds, survey_file_bytes,
                              mods_max_bytes, scan_seconds, list(files))
        served['run.ps1'] = script.encode()
        (output / 'run.ps1').write_text(script.replace(endpoint.base, '<endpoint>/'))
        result = subprocess.run(['prlctl', 'exec', vm, '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive',
                                 '-Command', bootstrap(endpoint.base)], text=True, capture_output=True, timeout=timeout)
        upload = endpoint.upload
    record['errnoAfter'] = errno_count()
    if result.returncode:
        record['execError'] = (result.stderr or result.stdout)[-4000:]; dump(output / 'run.json', record)
        raise RuntimeError('VM exec failed: ' + record['execError'])
    guest = json.loads(result.stdout.lstrip('\ufeff').strip())
    record['guest'] = guest
    dump(output / 'run.json', record)
    for name, sha in (guest.get('sources') or {}).items():
        if sha != record['sources'].get(name): raise ValueError(f'Guest source hash differs: {name}')
    for name, sha in (guest.get('inputs') or {}).items():
        if sha != input_hashes.get(name): raise ValueError(f'Guest input hash differs: {name}')
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    (output / 'source').mkdir(exist_ok=True)
    for name, data in sources.items(): (output / 'source' / name).write_bytes(data)
    provenance = [dict(file=str(p.relative_to(output)), sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted([output / n for n in set(names + ['run.json', 'run.ps1'])] + list((output / 'source').iterdir())) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, inputs=input_hashes, files=provenance))
    return dict(root=root, error=guest.get('error'), cleanupError=guest.get('cleanupError'), removed=guest.get('removed'),
                remainingGameProcesses=guest.get('remainingGameProcesses'), junctionTargetsChanged=guest.get('junctionTargetsChanged'),
                launches=guest.get('launches'), scenes=guest.get('scenes'), mods=guest.get('mods'),
                errno=[record['errnoBefore'], record['errnoAfter']], files=len(provenance), summary=summarize(output))


def summarize(output):
    """Phase E against the prediction: counts only."""
    def load(path):
        path = output / path
        return json.loads(path.read_text()) if path.is_file() else None
    result = {}
    for phase in ('fix', 'nofix'):
        status, trace = load(f'{phase}/status.json'), load(f'{phase}/light-fix-trace.json')
        rows = ((trace or {}).get('cases') or {}).get('loads') or []
        total = lambda key: sum(row.get(key) or 0 for row in rows)
        result[phase] = dict(error=(status or {}).get('error'), lightCheckWithTwoLights=(status or {}).get('lightCheckWithTwoLights'),
                             scenes=len(rows), nestedLightsKept=total('nestedLightsKept'), itemInfoRecords=total('itemInfoRecords'),
                             recordsReached=total('recordsReached'), recordsResolved=total('recordsResolved'),
                             scenesStopped=sum(1 for row in rows if row.get('objectsException') not in (None, 'none')),
                             scenesWithoutMapStep=sum(1 for row in rows if not row.get('mapStepReached')))
    lights = load('nofix/lights-control.json')
    if lights: result['nofix']['lightsControl'] = {k: lights['counts'].get(k) for k in ('nestedLightsKept', 'nestedLightsDropped')}
    survey = load('fix/survey4.json')
    if survey:
        after = survey.get('scenesByEditKindAfter') or {}
        observed = {kind: tuple(after.get(kind, {}).get(o, 0) for o in ('all', 'some', 'none')) for kind in PREDICTION}
        counts = survey.get('counts') or {}
        result['survey4'] = dict(parityMismatches=survey.get('parityMismatches'), truncated=survey.get('truncated'),
                                 unlimitedLights=survey.get('unlimitedLights'), objects=(survey.get('objects') or {}).get('total'),
                                 nestedLightsKept=counts.get('nestedLightsKept'), nestedLightsDropped=counts.get('nestedLightsDropped'),
                                 observed={k: list(v) for k, v in observed.items()},
                                 matchesPrediction=observed == PREDICTION)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--vm', default='Windows 11')
    p.add_argument('--output', type=Path, default=ROOT / '.local/stt03k-sideloader-repair/phase-e', help='new output folder')
    p.add_argument('--report', type=Path, required=True, help="UserPluginSceneTallyTests' private report (IKKOKU_USER_PLUGIN_SCENES_REPORT)")
    p.add_argument('--corpus', type=Path, required=True, help="plugin_rule_parity.py's corpus.txt")
    p.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    p.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    p.add_argument('--wait-fix', type=int, default=2700, help='bound on the launch with the light fix, survey 4 included')
    p.add_argument('--wait-nofix', type=int, default=1200, help='bound on the launch without it')
    p.add_argument('--survey-seconds', type=int, default=900, help='bound on survey 4')
    p.add_argument('--survey-file-bytes', type=int, default=512 * 1024 * 1024, help='scenes larger than this are counted, not read')
    p.add_argument('--mods-max-bytes', type=int, default=4 << 30, help='bound on the zipmods copied into the root')
    p.add_argument('--scan-seconds', type=int, default=600, help='bound on the zipmod manifest scan')
    p.add_argument('--resave', help='SHA-256 of the scene to resave without the fix (default: the smallest that drops lights)')
    p.add_argument('--summarize', action='store_true', help='only summarize an existing output folder')
    a = p.parse_args()
    if a.summarize: print(json.dumps(summarize(a.output), indent=2)); return
    print(json.dumps(run(a.vm, a.output, a.errno_baseline, a.report, a.corpus, a.host_address, a.wait_fix, a.wait_nofix,
                         a.survey_seconds, a.survey_file_bytes, a.mods_max_bytes, a.scan_seconds, a.resave), indent=2))


if __name__ == '__main__':
    main()
