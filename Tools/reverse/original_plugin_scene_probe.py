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

Phase B (--phase b) is the same kind of exec, with these differences:

- KKPE, NodesConstraints and KK_Plugins\\KK_MaterialEditor are copied as well (PLUGINS_B, same checks).
- The zipmod is phase A's: the file of that name under the install's mods folder, which must hash as
  phase A's run.json recorded.
- No survey 1. The probe is compiled together with fixtures/PluginSceneRules.cs, PluginSceneRuleParity.cs
  and PluginSceneSurvey.cs, and its plug-in folder gets reload-input: phase A's fixture.png, the
  ours-*.png and fixture-nil.png that sourceScenePluginDataWritesThePhaseBInputs wrote into --inputs,
  the rule corpus (plugin_rule_parity.py's corpus.txt) and survey.txt (the install's scene folder and
  the survey bounds). The probe then runs its phase B (see its source), with survey 2 last.
- Before PLAYER_SETUP creates the abdata and CharaStudio_Data junctions, and again after the cleanup
  has removed them, run.ps1 records the file count, directory count and newest LastWriteTimeUtc
  (entries and the folder itself) under both junction targets. Any difference is reported as
  junctionTargetsChanged and must be treated as an incident.
- The KKPE setting "Disable advanced mode on copied objects" is read from the install's
  BepInEx\\config\\com.joan6694.kkplugins.kkpe.cfg (read-only, with the file's SHA-256), for the
  KKPE rewrite that follows (PR 2). The player in the private root uses its own default config.

Phases C and D (--phase c, --phase d; ST-T03j) are the same kind of exec with phase B's plug-ins and zipmod, and
run fixtures/OriginalPluginRewriteProbe.cs (compiled with SOURCES_B) instead; reload-input\\phase.txt names the
phase. See the probe source for what each phase does.

- Phase C's input is phase A's fixture.png; the probe makes its females from a default ChaFileControl. Before the
  player starts, run.ps1 also:
  - looks, for at most --scan-seconds, through the install's mods for the smallest .zipmod whose
    abdata/studio/info item list names a prefab "Collider" (a KKPE lone collider), and copies it into the root's
    own mods folder when there is one (same hash check as phase A's zipmod);
  - reads the install's KKPE, NodesConstraints, MaterialEditor and KKAPI config files read-only: each file's
    SHA-256, size and "section/key = value" lines. The player keeps its own default config, so KKAPI's scene
    texture mode stays Bundled there whatever the install says;
  - copies the largest scene under UserData\\studio\\scene whose KKEx trailer has a "kkpe" entry, read-only, into
    the upload as largest-kkpe.png (for the export-time measurement), with its SHA-256 and size; no name is kept.
- Phase D's inputs are phase C's scenes, our exports (ours-*.png) and card-link-fixint.png from --inputs, the rule
  corpus, and survey.txt. Phase C's collider zipmod, when it had one, is copied in again by name and hash.
"""
from __future__ import annotations
import argparse, json, os, re, signal, subprocess
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
# Phase B's additions, from the same inventory: KKPE 2.21.4 (com.joan6694.kkplugins.kkpe; ExtendedSave, KKAPI >= 1.43),
# NodesConstraints 1.6.2.1 (com.joan6694.illusionplugins.nodesconstraints; KKAPI) and MaterialEditor 4.0.2
# (com.deathweasel.bepinex.materialeditor; KKAPI, ResourceRedirector, ExtendedSave, Sideloader). KKPE and
# NodesConstraints also reference Vectrosity, which ships in CharaStudio_Data\\Managed.
PLUGINS_B = (
    ('KKPE.dll', '72d1b7b5107e1f56a28482f7cfcaf845455d4a2b6504e858464bd1c94463377c', 574464),
    ('NodesConstraints.dll', '817fd940d001db9550e0f562e9f248ba601999a92e7ddc864f38a91cf28a4e03', 119296),
    ('KK_Plugins\\KK_MaterialEditor.dll', 'dde57f4f65161aa5374a283619791c77e89ce4a014c28d4b00e70cf9905ab596', 718848),
)
SOURCES_B = ('PluginSceneRules.cs', 'PluginSceneRuleParity.cs', 'PluginSceneSurvey.cs')


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


# File count, directory count and newest LastWriteTimeUtc under a folder (entries and the folder itself).
TREE = r"""function Tree($path){$i=New-Object IO.DirectoryInfo $path;$f=0;$d=0;$t=$i.LastWriteTimeUtc
foreach($e in $i.EnumerateFileSystemInfos('*',[IO.SearchOption]::AllDirectories)){if($e -is [IO.DirectoryInfo]){$d++}else{$f++};if($e.LastWriteTimeUtc -gt $t){$t=$e.LastWriteTimeUtc}}
[ordered]@{files=$f;directories=$d;newestUtc=$t.ToString('o')}}
function Targets{try{[ordered]@{abdata=(Tree "$original\abdata");CharaStudio_Data=(Tree "$original\CharaStudio_Data")}}catch{[ordered]@{error=$_.ToString()}}}
"""

# Used only by OA/OC. Paths describe recorded instances; they never select a
# process for termination by themselves. The independent compiler is also
# retained immediately so the outer finally can clean up after later errors.
ORDERED_OWNERS = r'''$script:orderedOwners=@{};$script:orderedCompiler=$null;$script:orderedCompilerIdentity=$null
function ProcessIdentity($process){
[ordered]@{pid=$process.Id;startTicks=$process.StartTime.ToUniversalTime().Ticks;path=$process.Path}}
function MatchingProcess($identity){
$process=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
if(-not $process){return $null}
if($process.StartTime.ToUniversalTime().Ticks -ne $identity.startTicks -or $process.Path -cne $identity.path){return $null}
return $process}
function RememberPlayer($process){
$identity=ProcessIdentity $process
if(-not $identity.path){throw 'Owned process executable path is unavailable'}
if($script:orderedOwners.Count -ge 32){throw 'Ordered process-owner bound exceeded'}
$script:orderedOwners[[int]$identity.pid]=$identity
$r.observedOwners=@($script:orderedOwners.Values)
return $identity}
function ObservePlayerChildren{
$table=@(Get-CimInstance Win32_Process -OperationTimeoutSec 5);$changed=$true
while($changed){$changed=$false
foreach($row in $table){
if($script:orderedOwners.ContainsKey([int]$row.ProcessId) -or -not $script:orderedOwners.ContainsKey([int]$row.ParentProcessId)){continue}
$parent=$script:orderedOwners[[int]$row.ParentProcessId];$liveParent=MatchingProcess $parent
if(-not $liveParent){continue}
$child=Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
if(-not $child){continue}
if($child.Path -ine $row.ExecutablePath -or $child.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffff') -cne $row.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffff')){continue}
if($child.StartTime.ToUniversalTime().Ticks -lt $parent.startTicks){throw 'Child predates recorded parent'}
[void](RememberPlayer $child);$changed=$true}}
}
function StopPlayerOwners{
$stopped=@();$errors=@()
foreach($identity in @($script:orderedOwners.Values)){
try{
$process=MatchingProcess $identity
if($process){$process|Stop-Process -Force;$stopped+=$identity.pid
if(-not $process.WaitForExit(5000)){throw 'Recorded player owner did not exit within cleanup bound'}}
}catch{$errors+=$_.ToString()}}
$r.ownerCleanupErrors=$errors
$r.ownersRemaining=@($script:orderedOwners.Values|Where-Object{MatchingProcess $_})
if($r.ownersRemaining.Count -or $errors.Count){throw 'Recorded player owner cleanup incomplete'}
return ,$stopped}
function StopOwnedCompiler{
if(-not $script:orderedCompiler){return}
if(-not $script:orderedCompilerIdentity){
if($script:orderedCompiler.HasExited){return}
$script:orderedCompilerIdentity=ProcessIdentity $script:orderedCompiler}
$identity=$script:orderedCompilerIdentity;$process=MatchingProcess $identity
if($process){$process|Stop-Process -Force
if(-not $process.WaitForExit(5000)){throw 'Recorded compiler did not exit within cleanup bound'}}
$r.compilerRemaining=[bool](MatchingProcess $identity)
if($r.compilerRemaining){throw 'Recorded compiler remains'}}
'''


def reload_script(root, base, wait_seconds, survey_seconds, survey_file_bytes, zipmod, inputs):
    """Phase B as run.ps1: the player with the full plug-in set, phase A's zipmod, the reload inputs and survey 2."""
    if not re.fullmatch(PLAYER_ROOT, root): raise ValueError('Unknown private player root')
    for value in (wait_seconds, survey_seconds, survey_file_bytes):
        if not isinstance(value, int) or value <= 0: raise ValueError('Bounds must be positive integers')
    if not re.fullmatch(r"[^'\\/:*?\"<>|]+\.zipmod", zipmod['name']) or not re.fullmatch(r'[0-9a-f]{64}', zipmod['sha256']):
        raise ValueError('Unexpected zipmod record')
    plugins = ','.join("@('%s','%s',%d)" % entry for entry in PLUGINS + PLUGINS_B)
    if not all(re.fullmatch(r'[A-Za-z0-9.-]+', name) for name in inputs): raise ValueError('Unexpected input name')
    names = ','.join("'%s'" % name for name in inputs)
    sources = ' '.join('"$root\\%s"' % name for name in ('PluginSceneProbe.cs',) + SOURCES_B)
    return ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$r=[ordered]@{root=$root;phase='B'}\n"
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
$p="$root\BepInEx\plugins";$out="$p\reload";$in="$p\reload-input";New-Item -ItemType Directory $out,$in -Force|Out-Null
$r.plugins=@()
foreach($e in @(""" + plugins + r""")){
$src=Join-Path "$original\BepInEx\plugins" $e[0];$dst=Join-Path $p $e[0];New-Item -ItemType Directory (Split-Path $dst) -Force|Out-Null
Copy-Item -LiteralPath $src -Destination $dst;$h=Sha $dst;$n=(Get-Item -LiteralPath $dst).Length
if($h -ne $e[1] -or $n -ne $e[2]){throw "Plug-in copy differs from the inventory: $($e[0]) $h $n"}
$r.plugins+=[ordered]@{path=$e[0];sha256=$h;bytes=$n}}
$mods=@(Get-ChildItem -LiteralPath "$original\mods" -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -ceq '""" + zipmod['name'] + r"""'})
if($mods.Count -ne 1){throw "Expected one zipmod named as phase A's, found $($mods.Count)"}
New-Item -ItemType Directory "$root\mods" -Force|Out-Null;$copy="$root\mods\$($mods[0].Name)"
Copy-Item -LiteralPath $mods[0].FullName -Destination $copy;$r.zipmod=[ordered]@{name=$mods[0].Name;bytes=$mods[0].Length;sha256=(Sha $copy)}
if($r.zipmod.sha256 -ne '""" + zipmod['sha256'] + r"""'){throw "Zipmod differs from phase A's: $($r.zipmod.sha256)"}
$r.inputs=[ordered]@{};foreach($n in @(""" + names + r""")){$r.inputs[$n]=Fetch $n "$in\$n"}
""" + r"""[IO.File]::WriteAllText("$in\survey.txt","$original\UserData\studio\scene`n""" + str(survey_seconds) + '`n' + str(survey_file_bytes) + r"""`n")
$cfg="$original\BepInEx\config\com.joan6694.kkplugins.kkpe.cfg";$r.kkpeConfig=[ordered]@{path=$cfg;exists=(Test-Path -LiteralPath $cfg)}
if($r.kkpeConfig.exists){$r.kkpeConfig.sha256=Sha $cfg;$m=@(Get-Content -LiteralPath $cfg|Where-Object{$_ -match '^\s*Disable advanced mode on copied objects\s*='});$r.kkpeConfig.lines=$m.Count;if($m.Count -eq 1){$r.kkpeConfig.value=($m[0] -split '=',2)[1].Trim()}}
$r.sources=[ordered]@{};foreach($n in @('PluginSceneProbe.cs',""" + ','.join("'%s'" % n for n in SOURCES_B) + r""")){$r.sources[$n]=Fetch $n "$root\$n"}
$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuPluginSceneProbe.dll" /reference:$($refs -join ',') """ + sources + r""" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"}
$r.playerArguments=@('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log")
$x=Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList $r.playerArguments -PassThru
$r.processID=$x.Id;$r.exited=$x.WaitForExit(""" + str(wait_seconds * 1000) + r""")
$left=Own;$left|Stop-Process -Force;$r.stopped=@($left|ForEach-Object{$_.Id});Start-Sleep -Seconds 2
foreach($n in @('unity.log','BepInEx\LogOutput.log')){if(Test-Path -LiteralPath "$root\$n"){Copy-Item -LiteralPath "$root\$n" "$out\$(Split-Path $n -Leaf)"}}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z="$root\reload.zip";[IO.Compression.ZipFile]::CreateFromDirectory($out,$z);$r.zipSHA256=Sha $z;$r.zipBytes=(Get-Item -LiteralPath $z).Length
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
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 5
""")


REWRITE_PROBE = FIXTURES / 'OriginalPluginRewriteProbe.cs'
# The install's config files phase C reads (read-only): KKPE, NodesConstraints, MaterialEditor and KKAPI.
CONFIGS = ('com.joan6694.kkplugins.kkpe.cfg', 'com.joan6694.illusionplugins.nodesconstraints.cfg',
           'com.deathweasel.bepinex.materialeditor.cfg', 'marco.kkapi.cfg')


def zipmod_record(record):
    if not re.fullmatch(r"[^'\\/:*?\"<>|]+\.zipmod", record['name']) or not re.fullmatch(r'[0-9a-f]{64}', record['sha256']):
        raise ValueError('Unexpected zipmod record')
    return record


def rewrite_script(root, base, phase, wait_seconds, zipmod, inputs, collider=None, survey_seconds=900,
                   survey_file_bytes=512 * 1024 * 1024, scan_seconds=180):
    """Phase C or D as run.ps1: the player with phase B's plug-ins and zipmod, the rewrite probe and its inputs."""
    if not re.fullmatch(PLAYER_ROOT, root): raise ValueError('Unknown private player root')
    if phase not in ('C', 'D', 'OA', 'OC'): raise ValueError('Unknown phase')
    for value in (wait_seconds, survey_seconds, survey_file_bytes, scan_seconds):
        if not isinstance(value, int) or value <= 0: raise ValueError('Bounds must be positive integers')
    zipmod_record(zipmod)
    if collider is not None and phase == 'C': raise ValueError('Phase C finds its own collider zipmod')
    if collider is not None: zipmod_record(collider)
    if not all(re.fullmatch(r'[A-Za-z0-9.-]+', name) for name in inputs): raise ValueError('Unexpected input name')
    ordered = phase in ('OA', 'OC')
    if ordered and (wait_seconds > 180 or collider is not None):
        raise ValueError('Ordered phases allow at most 180 player seconds and no collider scan/copy')
    plugins = ','.join("@('%s','%s',%d)" % entry for entry in PLUGINS + (() if phase == 'OA' else PLUGINS_B))
    names = ','.join("'%s'" % name for name in inputs)
    sources = ('OriginalPluginRewriteProbe.cs',) + SOURCES_B
    head = ("$ErrorActionPreference='Stop';$root='" + root + "';$base='" + base + "';$r=[ordered]@{root=$root;phase='" + phase + "'}\n"
            + r"""if(@(Get-Process CharaStudio,Koikatu -ErrorAction SilentlyContinue).Count){throw 'A game process already runs'}
if(Test-Path -LiteralPath $root){throw "Root exists: $root"}
[Net.ServicePointManager]::Expect100Continue=$false
function Fetch($name,$path){Invoke-WebRequest -UseBasicParsing -Uri ($base+$name) -OutFile $path;(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Sha($path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Own{@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root+'\')})}
function Mod($name,$sha){$m=@(Get-ChildItem -LiteralPath "$original\mods" -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -ceq $name})
if($m.Count -ne 1){throw "Expected one zipmod named $name, found $($m.Count)"}
$copy="$root\mods\$($m[0].Name)";Copy-Item -LiteralPath $m[0].FullName -Destination $copy;$h=Sha $copy
if($h -ne $sha){throw "Zipmod $name differs from the recorded one: $h"};[ordered]@{name=$m[0].Name;bytes=$m[0].Length;sha256=$h}}
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
$r.zipmod=Mod '""" + zipmod['name'] + "' '" + zipmod['sha256'] + r"""'
$r.inputs=[ordered]@{};foreach($n in @(""" + names + r""")){$r.inputs[$n]=Fetch $n "$in\$n"}
""")
    if phase == 'C':
        configs = ','.join("'%s'" % name for name in CONFIGS)
        middle = (r"""$w=[Diagnostics.Stopwatch]::StartNew();$r.collider=[ordered]@{scanned=0;truncated=$false;errors=0};$pick=$null
foreach($m in @(Get-ChildItem -LiteralPath "$original\mods" -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -ieq '.zipmod'}|Sort-Object Length,FullName)){
if($w.Elapsed.TotalSeconds -gt """ + str(scan_seconds) + r"""){$r.collider.truncated=$true;break}
$r.collider.scanned++;$z=$null
try{$z=[IO.Compression.ZipFile]::OpenRead($m.FullName)
foreach($x in $z.Entries){if($x.FullName.Replace('\','/').ToLowerInvariant() -notmatch '^abdata/studio/info/(.+/)?itemlist_[^/]*\.csv$'){continue}
$sr=New-Object IO.StreamReader($x.Open());$text=$sr.ReadToEnd();$sr.Close()
foreach($line in ($text -split "`r?`n")){$c=$line.Split(',');if($c.Count -ge 7 -and $c[0].Trim() -match '^\d+$' -and $c[6].Trim() -ceq 'Collider'){$pick=$m
$r.collider.list=[ordered]@{entry=$x.FullName;row=@($c|ForEach-Object{$_.Trim()})};$mf=$c[4].Trim()
if($mf -match '^[A-Za-z0-9_][A-Za-z0-9_./-]*$' -and $mf -notmatch '\.\.'){$r.collider.list.manifestInAbdata=(Test-Path -LiteralPath "$original\abdata\$mf")};break}}
if($pick){break}}
}catch{$r.collider.errors++}finally{if($z){$z.Dispose()}}
if($pick){break}}
$r.collider.seconds=[math]::Round($w.Elapsed.TotalSeconds,1)
if($pick){try{$r.collider.zipmod=Mod $pick.Name (Sha $pick.FullName)}catch{$r.collider.copyError=$_.ToString()}}
$r.configs=[ordered]@{}
foreach($n in @(""" + configs + r""")){$cfg="$original\BepInEx\config\$n";$e=[ordered]@{exists=(Test-Path -LiteralPath $cfg)}
if($e.exists){$e.sha256=Sha $cfg;$e.bytes=(Get-Item -LiteralPath $cfg).Length;$e.values=[ordered]@{};$section=''
foreach($line in @(Get-Content -LiteralPath $cfg)){if($line -match '^\s*\[(.+)\]\s*$'){$section=$matches[1]}elseif($line -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*?)\s*$'){$e.values["$section/$($matches[1])"]=$matches[2]}}}
$r.configs[$n]=$e}
$w=[Diagnostics.Stopwatch]::StartNew();$r.largestKKPE=[ordered]@{checked=0;oversize=0;truncated=$false};$latin=[Text.Encoding]::GetEncoding(28591)
$mark=$latin.GetString([byte[]](0x0D,0xE3,0x80,0x90,0x4B,0x53,0x74,0x75,0x64,0x69,0x6F,0xE3,0x80,0x91));$kkpe=$latin.GetString([byte[]](0xA4,0x6B,0x6B,0x70,0x65))
foreach($f in @(Get-ChildItem -LiteralPath "$original\UserData\studio\scene" -Recurse -File -Filter '*.png' -ErrorAction SilentlyContinue|Sort-Object Length -Descending)){
if($w.Elapsed.TotalSeconds -gt """ + str(scan_seconds) + r"""){$r.largestKKPE.truncated=$true;break}
if($f.Length -gt """ + str(min(survey_file_bytes, 256 * 1024 * 1024)) + r"""){$r.largestKKPE.oversize++;continue}
$r.largestKKPE.checked++;$s=$latin.GetString([IO.File]::ReadAllBytes($f.FullName));$i=$s.LastIndexOf($mark,[StringComparison]::Ordinal)
if($i -ge 0 -and $s.IndexOf('KKEx',$i,[StringComparison]::Ordinal) -ge 0 -and $s.IndexOf($kkpe,$i,[StringComparison]::Ordinal) -ge 0){
Copy-Item -LiteralPath $f.FullName -Destination "$out\largest-kkpe.png";$r.largestKKPE.sha256=Sha "$out\largest-kkpe.png";$r.largestKKPE.bytes=$f.Length
if($r.largestKKPE.sha256 -ne (Sha $f.FullName)){throw 'The largest KKPE scene copy differs from its original'}
break}}
$s=$null;$r.largestKKPE.seconds=[math]::Round($w.Elapsed.TotalSeconds,1)
""")
    elif ordered:
        middle = ''  # Exact retained input only: no authoring, config/corpus/installed-scene survey.
    else:
        middle = ((r"""$r.collider=Mod '""" + collider['name'] + "' '" + collider['sha256'] + "'\n") if collider else '') + (
            r"""[IO.File]::WriteAllText("$in\survey.txt","$original\UserData\studio\scene`n""" + str(survey_seconds) + '`n' + str(survey_file_bytes) + r"""`n")
""")
    tail = (r"""$r.sources=[ordered]@{};foreach($n in @(""" + ','.join("'%s'" % n for n in sources) + r""")){$r.sources[$n]=Fetch $n "$root\$n"}
$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object{$_.FullName})
$c=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$p\IkkokuPluginRewriteProbe.dll" /reference:$($refs -join ',') """
            + ' '.join('"$root\\%s"' % n for n in sources) + r""" 2>&1|Out-String
if($LASTEXITCODE -ne 0){throw "Compile failed:$c"}
$r.playerArguments=@('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log")
$x=Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList $r.playerArguments -PassThru
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
$r.junctionTargetsAfter=Targets
$r.junctionTargetsChanged=(($r.junctionTargetsBefore|ConvertTo-Json -Compress) -ne ($r.junctionTargetsAfter|ConvertTo-Json -Compress))
}
[PSCustomObject]$r|ConvertTo-Json -Compress -Depth 6
""")
    if ordered:
        old_owners = "function Own{@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root+'\\')})}"
        if old_owners not in head: raise AssertionError('Ordered owner insertion point changed')
        head = head.replace(old_owners, ORDERED_OWNERS, 1)
        head = head.replace('[Net.ServicePointManager]::Expect100Continue=$false', r'''$r.guestPID=$PID;$r.guestStartUTC=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
[Console]::Error.WriteLine('ORDERED_GUEST:'+(@{pid=$PID;startUTC=$r.guestStartUTC;root=$root}|ConvertTo-Json -Compress))
[Net.ServicePointManager]::Expect100Continue=$false''', 1)
        # The compiler is outside the private root. Retain its exact instance
        # and bound that process separately, before any original player starts.
        start = tail.index('$c=& '); end = tail.index('$r.playerArguments=')
        compile_args = ','.join("('\"'+$root+'\\%s\"')" % name for name in sources)
        tail = tail[:start] + (r'''$compiler='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$referenceArguments=@($refs|ForEach-Object{('/reference:"'+$_+'"')})
$arguments=@('/nologo','/noconfig','/nostdlib+','/target:library',('/out:"'+$p+'\IkkokuPluginRewriteProbe.dll"'))+$referenceArguments+@(''' + compile_args + r''')
$c=Start-Process -FilePath $compiler -ArgumentList $arguments -RedirectStandardOutput "$out\compile.stdout" -RedirectStandardError "$out\compile.stderr" -PassThru
$script:orderedCompiler=$c;[void]$c.Handle;$script:orderedCompilerIdentity=ProcessIdentity $c
$stamp=$script:orderedCompilerIdentity.startTicks;$r.compiler=[ordered]@{pid=$c.Id;startTicks=$stamp;path=$compiler;maximumSeconds=60}
if(-not $c.WaitForExit(60000)){
StopOwnedCompiler;$r.compiler.stopped=$true
throw 'Owned compiler exceeded 60 seconds'}
if($null -eq $c.ExitCode){throw 'Owned compiler exit code is unavailable'}
$r.compiler.exitCode=$c.ExitCode;$r.compiler.exited=$true
if($c.ExitCode -ne 0){throw 'Compile failed; see retained compiler logs'}
''') + tail[end:]
        old_wait = '$r.processID=$x.Id;$r.exited=$x.WaitForExit(' + str(wait_seconds * 1000) + ')'
        new_wait = r'''[void]$x.Handle;$r.playerIdentity=RememberPlayer $x;$r.processID=$x.Id;$r.playerStartUTC=$x.StartTime.ToUniversalTime().ToString('o')
$r.playerExecutableSHA256=Sha "$root\CharaStudio.exe";$playerWatch=[Diagnostics.Stopwatch]::StartNew()
while(-not $x.HasExited -and $playerWatch.Elapsed.TotalSeconds -lt ''' + str(wait_seconds) + r'''){
ObservePlayerChildren;[void]$x.WaitForExit(250)}
$r.exited=$x.HasExited;if($r.exited){if($null -eq $x.ExitCode){throw 'Owned player exit code is unavailable'};$r.playerExitCode=$x.ExitCode}'''
        if old_wait not in tail: raise AssertionError('Ordered wait insertion point changed')
        tail = tail.replace(old_wait, new_wait, 1)
        tail = tail.replace('$left=Own;$left|Stop-Process -Force;$r.stopped=@($left|ForEach-Object{$_.Id});', '$r.stopped=StopPlayerOwners;', 1)
        tail = tail.replace('$left=Own;$left|Stop-Process -Force -ErrorAction SilentlyContinue;$r.stoppedAtCleanup=@($left|ForEach-Object{$_.Id});',
                            "try{StopOwnedCompiler}catch{$r.cleanupError=$_.ToString()};try{$r.stoppedAtCleanup=StopPlayerOwners}catch{$r.cleanupError+='; '+$_.ToString()};", 1)
        tail = tail.replace('Invoke-WebRequest -UseBasicParsing -Method Put', 'Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Method Put')
        tail = tail.replace("Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Method Put", "if($r.zipBytes -gt 134217728){throw 'Ordered capture exceeds 128 MiB'}\nInvoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Method Put", 1)
        # Retain compiler/partial probe output even when no successful player
        # result reaches the normal upload. No second player/compile attempt.
        tail = tail.replace('$kept=@()', r'''if(-not $r.zipSHA256 -and $out -and (Test-Path -LiteralPath $out)){
try{$z="$root\partial.zip";[IO.Compression.ZipFile]::CreateFromDirectory($out,$z)
$r.zipSHA256=Sha $z;$r.zipBytes=(Get-Item -LiteralPath $z).Length
if($r.zipBytes -gt 134217728){throw 'Ordered partial capture exceeds 128 MiB'}
Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Method Put -InFile $z -ContentType 'application/zip' -Uri ($base+'reload.zip')|Out-Null
}catch{$r.partialUploadError=$_.ToString()}}
$kept=@()''', 1)
        head = head.replace('Invoke-WebRequest -UseBasicParsing -Uri', 'Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri')
        # Bound the inherited target-metadata and exact-zipmod traversal too.
        head = head.replace('$f=0;$d=0;$t=$i.LastWriteTimeUtc', '$f=0;$d=0;$t=$i.LastWriteTimeUtc;$watch=[Diagnostics.Stopwatch]::StartNew()')
        head = head.replace("foreach($e in $i.EnumerateFileSystemInfos('*',[IO.SearchOption]::AllDirectories)){", "foreach($e in $i.EnumerateFileSystemInfos('*',[IO.SearchOption]::AllDirectories)){if($f+$d -gt 200000 -or $watch.Elapsed.TotalSeconds -gt 30){throw 'Target metadata traversal exceeded its bound'};")
        old = '$m=@(Get-ChildItem -LiteralPath "$original\\mods" -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -ceq $name})'
        new = r'''$m=@();$watch=[Diagnostics.Stopwatch]::StartNew();$visited=0
foreach($path in [IO.Directory]::EnumerateFiles("$original\mods",'*',[IO.SearchOption]::AllDirectories)){
$visited++;if($visited -gt 20000 -or $watch.Elapsed.TotalSeconds -gt 30){throw 'Exact zipmod traversal exceeded its bound'}
if([IO.Path]::GetFileName($path) -ceq $name){$m+=Get-Item -LiteralPath $path}}'''
        if old not in head: raise AssertionError('Ordered mod traversal insertion point changed')
        head = head.replace(old, new, 1)
    return head + middle + tail


def run_rewrite(vm, output, errno_baseline, phase, files, zipmod, collider, host_address, wait_seconds,
                survey_seconds=900, survey_file_bytes=512 * 1024 * 1024, scan_seconds=180,
                runtime_pins=None):
    """One-exec phase C or D into a new output folder: run.json, run.ps1, the probe's outputs, source/ and manifest.json."""
    if not any(output.resolve().is_relative_to(root) for root in local_roots()): raise ValueError('Outputs must stay under .local')
    ordered = phase in ('OA', 'OC')
    if ordered:
        if output.exists(): raise RuntimeError('Ordered output must be a new directory, including failed starts')
        runtime_check = ordered_runtime_check(runtime_pins)
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    input_hashes = {name: digest(data) for name, data in files.items()}
    sources = {'OriginalPluginRewriteProbe.cs': REWRITE_PROBE.read_bytes()}
    for name in SOURCES_B: sources[name] = (FIXTURES / name).read_bytes()
    output.mkdir(parents=True, exist_ok=True)
    root = fresh_root()
    record = dict(vm=vm, root=root, phase=phase, sources={n: digest(b) for n, b in sources.items()}, inputs=input_hashes,
                  zipmod=dict(name=zipmod['name'], sha256=zipmod['sha256']),
                  collider=None if collider is None else dict(name=collider['name'], sha256=collider['sha256']),
                  plugins=[dict(path=p, sha256=h, bytes=n) for p, h, n in PLUGINS + (() if phase == 'OA' else PLUGINS_B)],
                  errnoBaseline=errno_baseline, errnoBefore=guarded(errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint')
    dump(output / 'run.json', record)
    if ordered:
        record['runtimePins'] = runtime_pins
        dump(output / 'run.json', record)
        (output / 'source-fixture.png').write_bytes(files['fixture.png'])
    served = dict(files); served.update(sources)
    timeout = wait_seconds + 420 if ordered else wait_seconds + survey_seconds + 2 * scan_seconds + 1800
    with Endpoint(host_address, served, upload='reload.zip') as endpoint:
        script = rewrite_script(root, endpoint.base, phase, wait_seconds, zipmod, list(files), collider, survey_seconds,
                                survey_file_bytes, scan_seconds)
        if ordered:
            # The existing private-player setup stays intact. Reject changed runtime,
            # producer or input bytes before the compiler/player starts. The original
            # runtime is verified again after cleanup, not modified by the probe.
            script = script.replace('$r.junctionTargetsBefore=Targets', runtime_check + '\n$r.runtimeBefore=VerifyRuntime\n$r.junctionTargetsBefore=Targets', 1)
            script = script.replace('$r.junctionTargetsAfter=Targets', 'try{$r.runtimeAfter=VerifyRuntime}catch{$r.runtimeError=$_.ToString()}\n$r.junctionTargetsAfter=Targets', 1)
            checks = []
            for name, sha in sorted(input_hashes.items()):
                checks.append("if($r.inputs['%s'] -cne '%s'){throw 'Input digest mismatch: %s'}" % (name, sha, name))
            for name, data in sorted(sources.items()):
                checks.append("if($r.sources['%s'] -cne '%s'){throw 'Producer digest mismatch: %s'}" % (name, digest(data), name))
            script = script.replace('$refs=@(', '\n'.join(checks) + '\n$refs=@(', 1)
        served['run.ps1'] = script.encode()
        (output / 'run.ps1').write_text(script.replace(endpoint.base, '<endpoint>/'))
        command = ['prlctl', 'exec', vm, '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive',
                   '-Command', bootstrap(endpoint.base)]
        result = (ordered_transport(command, output, record, timeout) if ordered else
                  subprocess.run(command, text=True, capture_output=True, timeout=timeout))
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
    retained = ['run.json', 'run.ps1'] + (['source-fixture.png', 'exec.stdout', 'exec.stderr'] if ordered else [])
    provenance = [dict(file=str(p.relative_to(output)), sha256=digest(p.read_bytes()), bytes=p.stat().st_size)
                  for p in sorted([output / n for n in set(names + retained)] + list((output / 'source').iterdir())) if p.is_file()]
    dump(output / 'manifest.json', dict(schemaVersion=1, inputs=input_hashes, files=provenance))
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    result = dict(root=root, exited=guest.get('exited'), error=guest.get('error'), cleanupError=guest.get('cleanupError'),
                removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                junctionTargetsChanged=guest.get('junctionTargetsChanged'), collider=guest.get('collider'),
                configs=guest.get('configs'), largestKKPE=guest.get('largestKKPE'),
                errno=[record['errnoBefore'], record['errnoAfter']], files=len(provenance), statusError=(status or {}).get('error'))
    if ordered:
        required_outputs = {'fixture.png', 'resave-fixture.png', 'plugin-scene-trace.json', 'status.json'}
        for label in ('delete-duplicate', 'duplicate-delete'):
            required_outputs.update(('edit-' + label + '.png', 'resave-edit-' + label + '.png'))
        result['accepted'] = bool(status and status.get('phase') == phase and 'error' in status and status['error'] is None
            and required_outputs <= set(names)
            and guest.get('exited') is True and guest.get('playerExitCode') == 0 and guest.get('removed') is True
            and guest.get('remainingGameProcesses') == [] and guest.get('junctionTargetsChanged') is False
            and not any(guest.get(k) for k in ('error', 'cleanupError', 'runtimeError', 'partialUploadError'))
            and guest.get('runtimeBefore') == runtime_pins == guest.get('runtimeAfter')
            and guest.get('sources') == record['sources'] and guest.get('inputs') == input_hashes
            and record.get('hostGroupReleased') is True and record['errnoBefore'] == record['errnoAfter'])
        dump(output / 'summary.json', result)
    return result


def ordered_transport(command, output, record, seconds):
    """One owned host group; guest timeout ambiguity is retained, never retried."""
    with (output / 'exec.stdout').open('xb') as out, (output / 'exec.stderr').open('xb') as err:
        child = subprocess.Popen(command, stdout=out, stderr=err, start_new_session=True)
        record['hostPID'] = child.pid; record['hostPGID'] = child.pid
        record['hostBirthAndCommand'] = subprocess.run(['ps', '-p', str(child.pid), '-o', 'lstart=,command='],
            text=True, capture_output=True, timeout=5).stdout.strip()
        dump(output / 'run.json', record)
        try: code = child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            record['hostTimedOut'] = True; record['guestCompletionUnresolved'] = True
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=5)
            code = 124
        try: os.killpg(child.pid, 0); record['hostGroupReleased'] = False
        except ProcessLookupError: record['hostGroupReleased'] = True
        record['hostExitCode'] = code; dump(output / 'run.json', record)
    return subprocess.CompletedProcess(command, code, (output / 'exec.stdout').read_text(), (output / 'exec.stderr').read_text())


def ordered_runtime_check(pins):
    """A complete, independently acquired runtime manifest; never learn pins at launch."""
    if not isinstance(pins, dict) or not 8 <= len(pins) <= 4096:
        raise ValueError('Ordered probes require 8..4096 exact runtime file pins')
    required = {'CharaStudio.exe', 'winhttp.dll', 'doorstop_config.ini', 'BepInEx/core/BepInEx.dll',
                'CharaStudio_Data/Managed/Assembly-CSharp.dll', 'CharaStudio_Data/Managed/UnityEngine.dll',
                'CharaStudio_Data/Managed/mscorlib.dll', '@compiler'}
    if not required <= pins.keys(): raise ValueError('Runtime manifest lacks required player/compiler files')
    if any(not isinstance(name, str) for name in pins) or len({name.lower() for name in pins}) != len(pins):
        raise ValueError('Runtime paths must be distinct Windows path strings')
    total = 0; rows = []
    for name, entry in sorted(pins.items()):
        if (not re.fullmatch(r'[A-Za-z0-9_. /-]+|@compiler', name) or
            any(part in ('', '.', '..') or part != part.strip() or part.endswith('.') for part in name.split('/')) or
            not (name in required or name.startswith(('CharaStudio_Data/', 'BepInEx/core/')))):
            raise ValueError('Unexpected runtime relative path')
        if (not isinstance(entry, dict) or set(entry) != {'sha256', 'bytes'} or
            not isinstance(entry['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', entry['sha256']) or
            type(entry['bytes']) is not int or not 0 <= entry['bytes'] <= 512 * 1024 * 1024):
            raise ValueError('Invalid runtime file pin')
        total += entry['bytes']; rows.append("@('%s','%s',%d)" % (name, entry['sha256'], entry['bytes']))
    if total > 1024 * 1024 * 1024: raise ValueError('Runtime pins exceed 1 GiB')
    return r'''function VerifyRuntime {
$expected=@(''' + ','.join(rows) + r''');$names=New-Object 'System.Collections.Generic.List[string]'
foreach($n in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini','@compiler')){$names.Add($n)}
$watch=[Diagnostics.Stopwatch]::StartNew();$stack=New-Object 'System.Collections.Generic.Stack[string]';$visited=0
foreach($dir in @('BepInEx\core','CharaStudio_Data')) {
$item=Get-Item -Force -LiteralPath "$original\$dir";if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Runtime root is a reparse point'};$stack.Push($item.FullName)}
while($stack.Count){foreach($path in [IO.Directory]::EnumerateFileSystemEntries($stack.Pop())){
$visited++;if($visited -gt 20000 -or $watch.Elapsed.TotalSeconds -gt 90){throw 'Runtime traversal bound exceeded'}
$attributes=[IO.File]::GetAttributes($path);if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Runtime contains a reparse point'}
if($attributes -band [IO.FileAttributes]::Directory){$stack.Push($path)}else{$names.Add($path.Substring($original.Length+1).Replace('\','/'))}
if($names.Count -gt 4096){throw 'Runtime file bound exceeded'}}}
if($names.Count -ne $expected.Count -or (Compare-Object -CaseSensitive @($names|Sort-Object -CaseSensitive) @($expected|ForEach-Object{$_[0]}|Sort-Object -CaseSensitive))){throw 'Runtime file inventory differs'}
$result=[ordered]@{}
foreach($entry in $expected){
if($watch.Elapsed.TotalSeconds -gt 90){throw 'Runtime hash check exceeded 90 seconds'}
$name=$entry[0];$path=if($name -ceq '@compiler'){'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'}else{Join-Path $original $name.Replace('/','\')}
$before=Get-Item -Force -LiteralPath $path;$size=$before.Length;$stamp=$before.LastWriteTimeUtc.Ticks
$stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$sha=[Security.Cryptography.SHA256]::Create()
try{$buffer=New-Object byte[] 1048576;while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
if($watch.Elapsed.TotalSeconds -gt 90){throw 'Runtime hash check exceeded 90 seconds'}
[void]$sha.TransformBlock($buffer,0,$n,$buffer,0)};[void]$sha.TransformFinalBlock($buffer,0,0)
$hash=[BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
$after=Get-Item -Force -LiteralPath $path
if($size -ne $entry[2] -or $hash -cne $entry[1] -or $after.Length -ne $size -or $after.LastWriteTimeUtc.Ticks -ne $stamp){throw "Runtime identity differs: $name"}
$result[$name]=[ordered]@{sha256=$hash;bytes=$size}}
return $result}
'''


def run_ordered(vm, output, errno_baseline, profile, fixture, fixture_sha256, retained_run,
                runtime_pins, host_address='10.211.55.2', wait_seconds=180):
    """#278: exact A/C input, matching isolated plug-ins, two real operation orders."""
    if profile not in ('a', 'c'): raise ValueError('Ordered profile must be a or c')
    if not re.fullmatch('[0-9a-f]{64}', fixture_sha256 or ''): raise ValueError('Expected fixture SHA256 is required')
    if type(wait_seconds) is not int or not 1 <= wait_seconds <= 180: raise ValueError('Ordered player bound must be 1..180 seconds')
    ordered_runtime_check(runtime_pins)  # Validate before reading or invoking any VM transport.
    if output.exists(): raise RuntimeError('Ordered output must be a new directory, including failed starts')
    data = fixture.read_bytes()
    if digest(data) != fixture_sha256: raise ValueError('Retained fixture digest differs')
    run = json.loads(retained_run.read_text()); zipmod = zipmod_record(run['guest']['zipmod'])
    files = {'fixture.png': data, 'fixture.sha256': fixture_sha256.encode(), 'phase.txt': ('O' + profile.upper()).encode()}
    return run_rewrite(vm, output, errno_baseline, 'O' + profile.upper(), files, zipmod, None,
                       host_address, wait_seconds, runtime_pins=runtime_pins)


def run_c(vm, output, errno_baseline, phase_a, host_address='10.211.55.2', wait_seconds=1800, scan_seconds=180,
          survey_file_bytes=512 * 1024 * 1024):
    """Phase C: phase A's fixture in, CharaStudio's authored fixture and edits out."""
    zipmod = json.loads((phase_a / 'run.json').read_text())['guest']['zipmod']
    files = {'fixture.png': (phase_a / 'fixture.png').read_bytes(), 'phase.txt': b'C'}
    return run_rewrite(vm, output, errno_baseline, 'C', files, zipmod, None, host_address, wait_seconds,
                       survey_file_bytes=survey_file_bytes, scan_seconds=scan_seconds)


def run_d(vm, output, errno_baseline, phase_c, inputs, corpus, host_address='10.211.55.2', wait_seconds=1800,
          survey_seconds=900, survey_file_bytes=512 * 1024 * 1024):
    """Phase D: phase C's scenes, our exports and the card-link variant in; per-object plug-in state and survey 3 out."""
    run = json.loads((phase_c / 'run.json').read_text())
    # The collider zipmod only when phase C saved the lone-collider fixture.
    collider = ((run.get('guest') or {}).get('collider') or {}).get('zipmod') if (phase_c / 'fixture-lc.png').is_file() else None
    names = ['fixture.png', 'card-link.png'] + sorted(p.name for p in phase_c.glob('edit-*.png'))
    if (phase_c / 'fixture-lc.png').is_file(): names.append('fixture-lc.png')
    files = {name: (phase_c / name).read_bytes() for name in names}
    ours = sorted(inputs.glob('ours-*.png'))
    if not ours: raise ValueError(f'no ours-*.png in {inputs}')
    for path in ours + [inputs / 'card-link-fixint.png']: files[path.name] = path.read_bytes()
    files['corpus.txt'] = corpus.read_bytes(); files['phase.txt'] = b'D'
    return run_rewrite(vm, output, errno_baseline, 'D', files, run['zipmod'], collider, host_address, wait_seconds,
                       survey_seconds, survey_file_bytes)


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


def run_b(vm, output, errno_baseline, inputs, corpus, phase_a, host_address='10.211.55.2', wait_seconds=1800,
          survey_seconds=900, survey_file_bytes=512 * 1024 * 1024):
    """One-exec phase B into a new output folder: run.json, run.ps1, the probe's scenes, plugin-scene-trace.json,
    status.json, survey2.json, unity.log, LogOutput.log, source/ and manifest.json."""
    if not any(output.resolve().is_relative_to(root) for root in local_roots()): raise ValueError('Outputs must stay under .local')
    if (output / 'run.json').exists(): raise RuntimeError(f'{output}/run.json exists: run the probe into a new output folder')
    phase_a_run = json.loads((phase_a / 'run.json').read_text())
    zipmod = phase_a_run['guest']['zipmod']
    files = {'fixture.png': (phase_a / 'fixture.png').read_bytes(), 'fixture-nil.png': (inputs / 'fixture-nil.png').read_bytes(),
             'corpus.txt': corpus.read_bytes()}
    ours = sorted(inputs.glob('ours-*.png'))
    if len(ours) != 7: raise ValueError(f'expected 7 ours-*.png in {inputs}, found {len(ours)}')
    for path in ours: files[path.name] = path.read_bytes()
    input_hashes = {name: digest(data) for name, data in files.items()}
    sources = {'PluginSceneProbe.cs': PROBE.read_bytes()}
    for name in SOURCES_B: sources[name] = (FIXTURES / name).read_bytes()
    output.mkdir(parents=True, exist_ok=True)
    root = fresh_root()
    record = dict(vm=vm, root=root, phase='B', sources={n: digest(b) for n, b in sources.items()}, inputs=input_hashes,
                  zipmod=dict(name=zipmod['name'], sha256=zipmod['sha256']),
                  plugins=[dict(path=p, sha256=h, bytes=n) for p, h, n in PLUGINS + PLUGINS_B],
                  errnoBaseline=errno_baseline, errnoBefore=guarded(errno_baseline),
                  transport='one prlctl exec; run.ps1 over a host-only HTTP endpoint')
    dump(output / 'run.json', record)
    served = dict(files); served.update(sources)
    timeout = wait_seconds + 1800
    with Endpoint(host_address, served, upload='reload.zip') as endpoint:
        script = reload_script(root, endpoint.base, wait_seconds, survey_seconds, survey_file_bytes, zipmod, list(files))
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
    status = json.loads((output / 'status.json').read_text()) if (output / 'status.json').is_file() else None
    return dict(root=root, exited=guest.get('exited'), error=guest.get('error'), cleanupError=guest.get('cleanupError'),
                removed=guest.get('removed'), remainingGameProcesses=guest.get('remainingGameProcesses'),
                junctionTargetsBefore=guest.get('junctionTargetsBefore'), junctionTargetsAfter=guest.get('junctionTargetsAfter'),
                junctionTargetsChanged=guest.get('junctionTargetsChanged'), kkpeConfig=guest.get('kkpeConfig'),
                zipmod=guest.get('zipmod'), errno=[record['errnoBefore'], record['errnoAfter']], files=len(provenance),
                statusError=(status or {}).get('error'))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--vm', default='Windows 11')
    p.add_argument('--phase', choices=('a', 'b', 'c', 'd', 'oa', 'oc'), default='a')
    p.add_argument('--fixture', type=Path, help='ordered phases: the exact retained source fixture')
    p.add_argument('--fixture-sha256', help='ordered phases: expected source fixture SHA256')
    p.add_argument('--retained-run', type=Path, help='ordered phases: original run.json pinning the copied zipmod')
    p.add_argument('--runtime-pins', type=Path, help='ordered phases: independently acquired complete runtime-pins.json')
    p.add_argument('--output', type=Path, help='new output folder (default .local/stt03i-plugin-data/phase-<a|b>, '
                                               '.local/stt03j-plugin-rewrites/phase-<c|d>)')
    p.add_argument('--phase-c', type=Path, default=ROOT / '.local/stt03j-plugin-rewrites/phase-c', help='phase D: the phase-C output folder')
    p.add_argument('--scan-seconds', type=int, default=180, help='phase C: bound on the collider zipmod and largest-scene scans')
    p.add_argument('--phase-a', type=Path, default=ROOT / '.local/stt03i-plugin-data/phase-a', help='phase B: the phase-A output folder')
    p.add_argument('--inputs', type=Path, help='phase B or D: the folder our exports were written to')
    p.add_argument('--corpus', type=Path, help="phase B or D: plugin_rule_parity.py's corpus.txt")
    p.add_argument('--errno-baseline', type=int, required=True, help='Parallels errno-24 count that must hold before the exec')
    p.add_argument('--host-address', default='10.211.55.2', help="the Mac's address on the VM's host-only network")
    p.add_argument('--wait-seconds', type=int, help='bound on the player run (default 900, phase B 1800)')
    p.add_argument('--survey-seconds', type=int, help='bound on the scene survey (default 600, phase B 900)')
    p.add_argument('--survey-file-bytes', type=int, default=512 * 1024 * 1024, help='scenes larger than this are counted, not read')
    p.add_argument('--zipmod-max-bytes', type=int, default=8 * 1024 * 1024, help='largest zipmod considered for the fixture')
    a = p.parse_args()
    output = a.output or ROOT / (f'.local/stt03i-plugin-data/phase-{a.phase}' if a.phase in 'ab' else f'.local/stt03j-plugin-rewrites/phase-{a.phase}')
    if a.phase in ('oa', 'oc'):
        if not all((a.output, a.fixture, a.fixture_sha256, a.retained_run, a.runtime_pins)):
            p.error('ordered phases require --output, --fixture, --fixture-sha256, --retained-run and --runtime-pins')
        result = run_ordered(a.vm, output, a.errno_baseline, a.phase[1], a.fixture, a.fixture_sha256,
                             a.retained_run, json.loads(a.runtime_pins.read_text()), a.host_address,
                             180 if a.wait_seconds is None else a.wait_seconds)
        print(json.dumps(result, indent=2))
        if not result['accepted']: raise SystemExit(1)
    elif a.phase == 'c':
        print(json.dumps(run_c(a.vm, output, a.errno_baseline, a.phase_a, a.host_address, a.wait_seconds or 1800,
                               a.scan_seconds, a.survey_file_bytes), indent=2))
    elif a.phase == 'd':
        if a.inputs is None or a.corpus is None: p.error('phase d needs --inputs and --corpus')
        print(json.dumps(run_d(a.vm, output, a.errno_baseline, a.phase_c, a.inputs, a.corpus, a.host_address,
                               a.wait_seconds or 1800, a.survey_seconds or 900, a.survey_file_bytes), indent=2))
    elif a.phase == 'b':
        if a.inputs is None or a.corpus is None: p.error('phase b needs --inputs and --corpus')
        print(json.dumps(run_b(a.vm, output, a.errno_baseline, a.inputs, a.corpus, a.phase_a, a.host_address,
                               a.wait_seconds or 1800, a.survey_seconds or 900, a.survey_file_bytes), indent=2))
    else:
        print(json.dumps(run(a.vm, output, a.errno_baseline, a.host_address, a.wait_seconds or 900, a.survey_seconds or 600,
                             a.survey_file_bytes, a.zipmod_max_bytes), indent=2))


if __name__ == '__main__':
    main()
