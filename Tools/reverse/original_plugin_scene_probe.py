#!/usr/bin/env python3
"""Original-player references for plug-in (KKEx) data in edited scenes (ST-T03/ST-S09, phase A).

One `prlctl exec` (the original_wear_probe.py transport: run.ps1 served from a host-only HTTP endpoint)
sets up a fresh private player root (original_character_probe.PLAYER_SETUP) and then:

1. Copies the plug-ins the fixture needs from the install's BepInEx\\plugins into the root's own
   BepInEx\\plugins: ExtensibleSaveFormat, Sideloader (with SharpZipLib and XUnity.ResourceRedirector,
   its hard dependency), KKAPI (with KKAPI.NativeHelper) and KK_StudioSceneSettings. Each copy must
   match the SHA-256 and size in PLUGINS, which come from the installed-plug-in inventory, or the
   run stops. This is a policy change from the earlier probes, whose plug-ins folder holds only the
   probe: these plug-ins are COPIED, never junctioned, because a junction is writable and anything
   written through it would land in C:\\Illusion\\Koikatsu.
2. Picks the smallest .zipmod (at most --zipmod-max-bytes) under the install's mods folder whose
   manifest names a GUID and allows Koikatsu, and whose abdata/studio/info/*/ItemList_*.csv names a
   .unity3d bundle the archive itself carries. Archives are opened read-only, and only the pick is
   copied into the root's own mods folder (Sideloader's ModsDirectory is <game root>\\mods; its
   additional-directory setting defaults to empty). The copy must hash like the original.
3. Compiles fixtures/KKExSceneSurvey.cs and runs it over the install's UserData\\studio\\scene,
   read-only and bounded by --survey-seconds. It writes survey.json with counts only: per KKEx entry
   ID the scenes, PluginData versions and entry sizes, and the scenes per combination of IDs. No
   scene is copied, named or hashed.
4. Compiles fixtures/OriginalPluginSceneProbe.cs and runs the player until the probe quits it: the
   player authors the fixture (fixture.png: mod items from the copied zipmod, vanilla items, a
   folder, a route, a camera, a light and StudioSceneSettings values), saves CharaStudio's own edit
   of it for each edit our writer supports (edit-*.png), loads and saves every one again
   (resave-*.png), and records ExtendedSave's carry-over of an entry no plug-in owns
   (passthrough*.png). See the probe source for the edits.
5. Zips the probe folder with unity.log and LogOutput.log, PUTs it back, stops any process left in
   the root, removes the abdata and CharaStudio_Data junctions, and then removes the root with the
   copied plug-ins and zipmod.

Nothing in C:\\Illusion\\Koikatsu is written. The Parallels errno-24 count must equal
--errno-baseline before the exec. Outputs stay under .local.
"""
from __future__ import annotations
import argparse, json, re, subprocess
from pathlib import Path
from original_character_probe import PLAYER_SETUP, PLAYER_ROOT
from original_wear_probe import Endpoint, bootstrap, extract, errno_count, guarded, fresh_root, digest, dump

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name('fixtures')
PROBE = FIXTURES / 'OriginalPluginSceneProbe.cs'
SURVEY = FIXTURES / 'KKExSceneSurvey.cs'
# BepInEx\plugins-relative path, SHA-256 and size from the installed-plug-in inventory
# (.local/codex-continue-2026-10-24/wave-three/plugins/installed-inventory/coverage-index.json).
PLUGINS = (
    ('KK_BepisPlugins\\ExtensibleSaveFormat.dll', '7b1c7f0405ebb5dad84e6fca85d9f5594f9423dbb6e9135a3cce6e60765143be', 65024),
    ('KK_BepisPlugins\\Sideloader.dll', 'dc3b1c3d4e63941a6bbf83fde9783fc46fcdbd7715f2f7602067a5fed80a7a9b', 172032),
    ('KK_BepisPlugins\\ICSharpCode.SharpZipLib.dll', '40b3d590f95191f3e33e5d00e534fa40f823d9b1bb2a9afe05f139c4e0a3af8d', 200704),
    ('XUnity.ResourceRedirector\\XUnity.ResourceRedirector.BepInEx.dll', '4a68c868bf87ea822df6b0ec17ebab0026137b9b47e0e0f80501c06f31ab5fe4', 6144),
    ('XUnity.ResourceRedirector\\XUnity.ResourceRedirector.dll', '7349007c25ff2813736a850301c26750fdb99acead64316de6f59289865ce6be', 72704),
    ('KKAPI.dll', '7f4f50e1e3306ded40ea0676ea891d1264964dd2821caa8e111b9002a3f69a18', 444416),
    ('KKAPI.NativeHelper.dll', '09ab8d27b7e0acfbbed61a300f6b676834d086c0843c504b716e595b30bfc098', 31744),
    ('KK_Plugins\\KK_StudioSceneSettings.dll', '5ae7cd405d9dc47c12afcf708415b0d6962fbffe9f043f8972fcff78437bae99', 21504),
)


def local_roots():
    """The checkout's .local and, from a linked worktree, the main checkout's .local (git's common dir)."""
    roots = [(ROOT / '.local').resolve()]
    common = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True).stdout.strip()
    if common: roots.append((Path(common).parent / '.local').resolve())
    return roots


def once_script(root, base, wait_seconds, survey_seconds, survey_file_bytes, zipmod_max_bytes):
    """The whole phase as run.ps1. `base` is the endpoint URL ending in the token and '/'."""
    if not re.fullmatch(PLAYER_ROOT, root): raise ValueError('Unknown private player root')
    for value in (wait_seconds, survey_seconds, survey_file_bytes, zipmod_max_bytes):
        if not isinstance(value, int) or value <= 0: raise ValueError('Bounds must be positive integers')
    plugins = ','.join("@('%s','%s',%d)" % entry for entry in PLUGINS)
    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$r=[ordered]@{root=$root}\n"
            + r"""if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
function Fetch($name,$path){Invoke-WebRequest -UseBasicParsing -Uri ($base+$name) -OutFile $path;(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Sha($path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Own{@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root+'\')})}
try{
""" + PLAYER_SETUP + r"""
$p="$root\BepInEx\plugins";$out="$p\reload";New-Item -ItemType Directory $out -Force|Out-Null
$r.plugins=@()
foreach($e in @(""" + plugins + r""")){
$src=Join-Path "$original\BepInEx\plugins" $e[0];$dst=Join-Path $p $e[0];New-Item -ItemType Directory (Split-Path $dst) -Force|Out-Null
Copy-Item -LiteralPath $src -Destination $dst;$h=Sha $dst;$n=(Get-Item -LiteralPath $dst).Length
if($h -ne $e[1] -or $n -ne $e[2]){throw "Plug-in copy differs from the inventory: $($e[0]) $h $n"}
$r.plugins+=[ordered]@{path=$e[0];sha256=$h;bytes=$n}}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$mods=@(Get-ChildItem -LiteralPath "$original\mods" -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -ieq '.zipmod' -and $_.Length -le """ + str(zipmod_max_bytes) + r"""}|Sort-Object Length,FullName)
$r.zipmodCandidates=$mods.Count;$games=@('koikatsu','koikatu',[string][char]0x30b3+[char]0x30a4+[char]0x30ab+[char]0x30c4)
$why=[ordered]@{noManifest=0;noGuid=0;otherGame=0;noItemList=0;noUsableItem=0;foreignBundle=0;ownBundle=0;error=0};$lists=@{};$pick=$null;$fallback=$null;$w=[Diagnostics.Stopwatch]::StartNew()
foreach($m in $mods){
if($w.Elapsed.TotalSeconds -gt 240){$r.zipmodScanTruncated=$true;break}
$z=$null
try{
$z=[IO.Compression.ZipFile]::OpenRead($m.FullName);$names=@{}
foreach($x in $z.Entries){$names[$x.FullName.Replace('\','/').ToLowerInvariant()]=$x}
foreach($k in $names.Keys){if($k -match '^abdata/studio/info/.*?([a-z]+)_[^/]*\.csv$'){$lists[$matches[1]]=1+[int]$lists[$matches[1]]}}
if(-not $names.ContainsKey('manifest.xml')){$why.noManifest++;continue}
$sr=New-Object IO.StreamReader($names['manifest.xml'].Open());$text=$sr.ReadToEnd();$sr.Close();$xml=[xml]$text
$guid=[string]$xml.manifest.guid;if(-not $guid.Trim()){$why.noGuid++;continue}
$tags=@($xml.manifest.SelectNodes('game')|ForEach-Object{$_.InnerText.Trim().ToLowerInvariant()})
if($tags.Count -and -not @($tags|Where-Object{$games -contains $_}).Count){$why.otherGame++;continue}
$items=@($names.Keys|Where-Object{$_ -match '^abdata/studio/info/(.+/)?itemlist_[^/]*\.csv$'})
if(-not $items.Count){$why.noItemList++;continue}
$own=$false;$usable=$false
foreach($l in $items){$sr=New-Object IO.StreamReader($names[$l].Open());$text=$sr.ReadToEnd();$sr.Close()
foreach($line in ($text -split "`r?`n")){$c=$line.Split(',');if($c.Count -lt 16 -or $c[0].Trim() -notmatch '^\d+$'){continue}
$man=$c[4].Trim().ToLowerInvariant();if(($man -ne '' -and $man -ne 'abdata') -or $c[7].Trim() -ne '' -or $c[8].Trim() -ine 'false'){continue}
$usable=$true;if($names.ContainsKey('abdata/'+$c[5].Trim().Replace('\','/').ToLowerInvariant())){$own=$true;break}}
if($own){break}}
if(-not $usable){$why.noUsableItem++;continue}
$info=[ordered]@{name=$m.Name;bytes=$m.Length;guid=$guid.Trim();itemLists=$items.Count;ownBundle=$own}
if($own){$why.ownBundle++;if(-not $pick){$pick=$m;$r.zipmod=$info}}else{$why.foreignBundle++;if(-not $fallback){$fallback=$m;$fallbackInfo=$info}}
if($pick){break}
}catch{$why.error++}finally{if($z){$z.Dispose()}}}
$r.zipmodReasons=$why;$r.studioListKinds=$lists;$r.zipmodScanSeconds=[math]::Round($w.Elapsed.TotalSeconds,1)
if(-not $pick -and $fallback){$pick=$fallback;$r.zipmod=$fallbackInfo}
if(-not $pick){throw 'No zipmod carries a Koikatsu studio item list'}
New-Item -ItemType Directory "$root\mods" -Force|Out-Null;$copy="$root\mods\$($pick.Name)"
Copy-Item -LiteralPath $pick.FullName -Destination $copy;$r.zipmod.sha256=Sha $copy
if($r.zipmod.sha256 -ne (Sha $pick.FullName)){throw 'Zipmod copy differs from its original'}
$r.survey=Fetch 'KKExSceneSurvey.cs' "$root\KKExSceneSurvey.cs"
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:exe /out:"$root\KKExSceneSurvey.exe" "$root\KKExSceneSurvey.cs" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Survey compile failed:$c"}
$w=[Diagnostics.Stopwatch]::StartNew()
$c=& "$root\KKExSceneSurvey.exe" "$original\UserData\studio\scene" "$out\survey.json" """ + str(survey_seconds) + ' ' + str(survey_file_bytes) + r""" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Survey failed:$c"};$r.surveySeconds=[math]::Round($w.Elapsed.TotalSeconds,1)
$r.source=Fetch 'PluginSceneProbe.cs' "$root\PluginSceneProbe.cs"
$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuPluginSceneProbe.dll" /reference:$($refs -join ',') "$root\PluginSceneProbe.cs" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"}
$x=Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru
$r.processID=$x.Id;$r.exited=$x.WaitForExit(""" + str(wait_seconds * 1000) + r""")
$left=Own;$left|Stop-Process -Force;$r.stopped=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 2
foreach($n in @('unity.log','BepInEx\LogOutput.log')){if(Test-Path -LiteralPath "$root\$n"){Copy-Item -LiteralPath "$root\$n" "$out\$(Split-Path $n -Leaf)"}}
$z="$root\reload.zip";[IO.Compression.ZipFile]::CreateFromDirectory($out,$z);$r.zipSHA256=Sha $z;$r.zipBytes=(Get-Item -LiteralPath $z).Length
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $z -ContentType 'application/zip' -Uri ($base+'reload.zip')|Out-Null
}catch{$r.error=$_.ToString()}
finally{
$left=Own;$left|Stop-Process -Force -ErrorAction SilentlyContinue;$r.stoppedAtCleanup=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 1
$kept=@()
foreach($j in @("$root\abdata","$root\CharaStudio_Data")){if(Test-Path -LiteralPath $j){if((Get-Item -LiteralPath $j -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){cmd /c rmdir "$j"|Out-Null}if(Test-Path -LiteralPath $j){$kept+=$j}}}
if($kept.Count){$r.cleanupError='junctions not removed: '+($kept -join ', ')}elseif(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
$r.removed=-not(Test-Path -LiteralPath $root);$r.remainingGameProcesses=@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 5
""")


def run(vm, output, errno_baseline, host_address='10.211.55.2', wait_seconds=900, survey_seconds=600,
        survey_file_bytes=512 * 1024 * 1024, zipmod_max_bytes=8 * 1024 * 1024):
    """One-exec phase A into a new output folder: run.json, run.ps1, survey.json, plugin-scene-trace.json,
    status.json, the scenes the player saved, unity.log, LogOutput.log and manifest.json."""
    if not any(output.resolve().is_relative_to(root) for root in local_roots()): raise ValueError('Outputs must stay under .local')
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    output.mkdir(parents=True, exist_ok=True)
    probe, survey = PROBE.read_bytes(), SURVEY.read_bytes()
    root = fresh_root()
    record = dict(vm=vm, root=root, probeSHA256=digest(probe), surveySHA256=digest(survey), plugins=[dict(path=p, sha256=h, bytes=n) for p, h, n in PLUGINS],
                  errnoBaseline=errno_baseline, errnoBefore=guarded(errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint')
    dump(output / 'run.json', record)
    files = {'PluginSceneProbe.cs': probe, 'KKExSceneSurvey.cs': survey}
    timeout = wait_seconds + survey_seconds + 900
    with Endpoint(host_address, files, upload='reload.zip') as endpoint:
        script = once_script(root, endpoint.base, wait_seconds, survey_seconds, survey_file_bytes, zipmod_max_bytes)
        files['run.ps1'] = script.encode()
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
    if guest.get('source') not in (None, digest(probe)): raise ValueError('Guest probe source hash differs')
    if guest.get('survey') not in (None, digest(survey)): raise ValueError('Guest survey source hash differs')
    names = []
    if upload is not None:
        if digest(upload) != guest.get('zipSHA256') or len(upload) != guest.get('zipBytes'): raise ValueError('Upload differs from the guest zip')
        names = extract(upload, output)
    (output / 'probe-source.cs').write_bytes(probe); (output / 'survey-source.cs').write_bytes(survey)
    dump(output / 'run.json', record)
    provenance = [dict(file=p.name, sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted(output / n for n in set(names + ['run.json', 'run.ps1', 'probe-source.cs', 'survey-source.cs'])) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, files=provenance))
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    return dict(root=root, exited=guest.get('exited'), error=guest.get('error'), cleanupError=guest.get('cleanupError'),
                removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                zipmod=guest.get('zipmod'), zipmodExamined=guest.get('zipmodExamined'), surveySeconds=guest.get('surveySeconds'),
                errno=[record['errnoBefore'], record['errnoAfter']], files=len(provenance),
                statusError=(status or {}).get('error'))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--vm', default='Windows 11')
    p.add_argument('--output', type=Path, default=ROOT / '.local/stt03i-plugin-data/phase-a')
    p.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    p.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    p.add_argument('--wait-seconds', type=int, default=900, help='bound on the player run')
    p.add_argument('--survey-seconds', type=int, default=600, help='bound on the scene survey')
    p.add_argument('--survey-file-bytes', type=int, default=512 * 1024 * 1024, help='scenes larger than this are counted, not read')
    p.add_argument('--zipmod-max-bytes', type=int, default=8 * 1024 * 1024, help='largest zipmod considered for the fixture')
    a = p.parse_args()
    print(json.dumps(run(a.vm, a.output, a.errno_baseline, a.host_address, a.wait_seconds, a.survey_seconds,
                         a.survey_file_bytes, a.zipmod_max_bytes), indent=2))


if __name__ == '__main__':
    main()
