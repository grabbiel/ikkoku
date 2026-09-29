#!/usr/bin/env python3
"""Capture a freshly generated clothed source character in an isolated player.

Outputs geometry, pose, camera, materials and source frame to private .local
artifacts. Does not copy/read installed cards, saves or third-party plug-ins.
"""
from __future__ import annotations
import argparse, json, sys, time, uuid, zipfile, io, re
from pathlib import Path
from original_shader_probe import write_small, user_powershell, fetch, stop_probe, dump, digest
from vm_source import powershell, ps_quote
ROOT=Path(__file__).resolve().parents[2]

def retry(vm,script,user=False):
 for attempt in range(3):
  try:return (user_powershell if user else powershell)(vm,script)
  except RuntimeError as e:
   if 'Invalid argument' not in str(e) or attempt==2:raise
   time.sleep(.25)

def retry_call(operation,*args):
 for attempt in range(3):
  try:return operation(*args)
  except RuntimeError as e:
   if 'Invalid argument' not in str(e) or attempt==2:raise
   time.sleep(.25)

def hand_patterns_bytes(path):
 rows={}
 for line in path.read_text().splitlines():
  if not line:continue
  fields=line.split('\t')
  if len(fields)!=2 or fields[0] not in ('L','R'):raise ValueError('hand-patterns rows need L or R and one pattern number')
  try:pattern=int(fields[1])
  except ValueError:raise ValueError('hand-patterns rows need L or R and one pattern number')
  if not 0<=pattern<=21 or fields[0] in rows:raise ValueError('hand-patterns repeats a side or holds a pattern outside the converted 0-21 range')
  rows[fields[0]]=pattern
 if set(rows)!={'L','R'}:raise ValueError('hand-patterns needs one L and one R row')
 return path.read_bytes()

def look_patterns_bytes(path):
 rows=[]
 for line in path.read_text().splitlines():
  if not line:continue
  fields=line.split('\t')
  if len(fields)!=4:raise ValueError('look-patterns rows need neckPtn, eyesPtn, frames and x,y,z camera position')
  try:neck,eyes,frames=int(fields[0]),int(fields[1]),int(fields[2])
  except ValueError:raise ValueError('look-patterns pattern and frame fields must be integers')
  if not 0<=neck<=4 or not 0<=eyes<=3 or not 1<=frames<=600:raise ValueError('look-patterns holds a pattern outside neck 0-4 / eyes 0-3 or a frame count outside 1-600')
  parts=fields[3].split(',')
  if len(parts)!=3:raise ValueError('look-patterns camera position needs x,y,z')
  try:[float(p)for p in parts]
  except ValueError:raise ValueError('look-patterns camera position needs x,y,z')
  rows.append(line)
 if not rows:raise ValueError('look-patterns has no phase rows')
 return path.read_bytes()

PLAYER_ROOT=r'C:\\Temp\\IkkokuShaderProbe-[0-9a-f]{32}'
# Isolated player copy shared by every driver that records its root in run.json:
# copied executable/loader/BepInEx core plus junctions to the original game data.
PLAYER_SETUP=r'''$original='C:\Illusion\Koikatsu';New-Item -ItemType Directory "$root\BepInEx\plugins" -Force|Out-Null;New-Item -ItemType Directory "$root\BepInEx\config" -Force|Out-Null;foreach($name in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$original\$name" "$root\$name"};Copy-Item "$original\BepInEx\core" "$root\BepInEx\core" -Recurse;foreach($name in @('abdata','CharaStudio_Data')){New-Item -ItemType Junction -Path "$root\$name" -Value "$original\$name"|Out-Null};[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n")'''
# 'missing' when the root is gone, 'present' when it still holds a usable player;
# a partly deleted root throws instead of being written into.
PLAYER_STATE=r'''if(-not(Test-Path -LiteralPath $root)){'missing'}elseif((Test-Path -LiteralPath "$root\CharaStudio.exe") -and (Test-Path -LiteralPath "$root\BepInEx\core\BepInEx.dll") -and (Test-Path -LiteralPath "$root\CharaStudio_Data\Managed") -and (Test-Path -LiteralPath "$root\abdata")){'present'}else{throw "Private player root is incomplete: $root"}'''

def player_script(root,body):return "$ErrorActionPreference='Stop';$root="+ps_quote(root)+';'+body

def player_root(vm,output):
 """Return the private player root recorded in output/run.json, or set up a new one.

 A recorded root that no longer exists on the VM (for example after a cleanup)
 is recreated with the same player-copy setup as a new root. No player can run
 from a deleted root, because Windows locks a running executable, so the
 recorded process is only stopped when the root is still present."""
 run_path=output/'run.json'
 if run_path.exists():
  run=json.loads(run_path.read_text());root=run['root']
  if not re.fullmatch(PLAYER_ROOT,root):raise ValueError('Unknown private player root')
  if retry(vm,player_script(root,PLAYER_STATE))=='missing':
   retry(vm,player_script(root,PLAYER_SETUP))
   print('Recreated missing private player root '+root,file=sys.stderr)
  elif int(run['processID'])>0:stop_probe(vm,run)
 else:
  root=r'C:\Temp\IkkokuShaderProbe-'+uuid.uuid4().hex
  retry(vm,player_script(root,PLAYER_SETUP))
  # Save before compile so a failed build can reuse this private directory.
  dump(run_path,dict(vm=vm,root=root,processID=0,stopped=True))
 return root

def start(vm,output,settings=None,hand_patterns=None,look_patterns=None):
 run_path=output/'run.json';root=player_root(vm,output)
 properties=[]
 for path in sorted((output/'shaders').glob('*/program.json')):
  program=json.loads(path.read_text())
  properties.extend(program['name']+'\t'+p['m_Name']+'\t'+str(p['m_Type']) for p in program['properties'])
 write_small(vm,root+r'\BepInEx\plugins\shader-properties.tsv',('\n'.join(properties)+'\n').encode())
 source=Path(__file__).with_name('fixtures')/'OriginalCharacterProbe.cs'
 write_small(vm,root+r'\CharacterProbe.cs',source.read_bytes())
 result=retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});$csc=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuCharacterProbe.dll" /reference:$($refs -join ',') "$root\CharacterProbe.cs" 2>&1|Out-String;if($LASTEXITCODE -ne 0){throw "Compile failed:$csc"};if(Test-Path "$root\BepInEx\plugins\character"){Remove-Item "$root\BepInEx\plugins\character" -Recurse -Force}''')
 if result:print(result)
 if settings:
  # The C# probe reads the tsv from the `character` folder under the plugin
  # directory; recreate it first because the compile step deletes it each run.
  retry(vm,"$ErrorActionPreference='Stop';New-Item -ItemType Directory "+ps_quote(root+r'\BepInEx\plugins\character')+" -Force|Out-Null")
  write_small(vm,root+r'\BepInEx\plugins\character\character-settings.tsv',settings.read_bytes())
 # Uploaded after the compile step and before the player starts, so the
 # plugin can read it at Start(); an absent file keeps outputs byte-identical.
 if hand_patterns is not None:write_small(vm,root+r'\BepInEx\plugins\hand-patterns.tsv',hand_patterns_bytes(hand_patterns))
 if look_patterns is not None:write_small(vm,root+r'\BepInEx\plugins\look-patterns.tsv',look_patterns_bytes(look_patterns))
 pid=int(retry(vm,"$root="+ps_quote(root)+r''';$p=Get-Process CharaStudio -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq "$root\CharaStudio.exe"}|Select-Object -First 1;if($p){$p.Id}else{(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','768','-screen-height','1024','-logFile',"$root\unity.log") -PassThru).Id}''',True))
 run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False);dump(run_path,run);return run

def collect(vm,output):
 run=json.loads((output/'run.json').read_text());root=run['root'];folder=root+r'\BepInEx\plugins\character'
 status=json.loads(retry_call(fetch,vm,folder+r'\status.json'))
 stop_probe(vm,run);run['stopped']=True;dump(output/'run.json',run)
 for name in ['unity.log',r'BepInEx\LogOutput.log']:
  try:(output/Path(name.replace('\\','/')).name).write_bytes(retry_call(fetch,vm,root+'\\'+name))
  except RuntimeError:pass
 dump(output/'status.json',status)
 if status.get('error'):raise RuntimeError(status['error'])
 retry(vm,"$ErrorActionPreference='Stop';Add-Type -AssemblyName System.IO.Compression.FileSystem;$folder="+ps_quote(folder)+";$zip="+ps_quote(root+r'\character.zip')+";if(Test-Path $zip){Remove-Item $zip};[IO.Compression.ZipFile]::CreateFromDirectory($folder,$zip)")
 data=retry_call(fetch,vm,root+r'\character.zip',128*1024*1024)
 with zipfile.ZipFile(io.BytesIO(data)) as archive:
  if any(Path(n).name!=n or n.startswith('.') for n in archive.namelist()):raise ValueError('Unexpected archive paths')
  if sum(i.file_size for i in archive.infolist())>512*1024*1024:raise ValueError('Capture exceeds extraction bound')
  names=archive.namelist()
  archive.extractall(output)
 provenance=[dict(file=p.name,sha256=digest(p.read_bytes()),bytes=p.stat().st_size) for p in sorted(output/name for name in set(names+['run.json','unity.log','LogOutput.log'])) if p.is_file()]
 dump(output/'manifest.json',dict(schemaVersion=1,files=provenance))
 return dict(status=status,files=len(provenance),archiveBytes=len(data))

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/reverse/original-character-probe');p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');p.add_argument('--settings',type=Path,help='optional "key<TAB>value" character-settings.tsv (makeup, blush, nip, underhair and iris-highlight IDs/colors); keys: docs/reference/character/material-expansion.md');p.add_argument('--hand-patterns',type=Path,help='optional "L<TAB>k"/"R<TAB>k" file driving Studio.HandAnimeCtrl patterns 1-21 (0 disables)');p.add_argument('--look-patterns',type=Path,help='optional "neckPtn<TAB>eyesPtn<TAB>frames<TAB>x,y,z" file driving the neck/eye look-at controllers one camera phase per row');a=p.parse_args()
 # Checked before any output folder is touched: these inputs are uploaded only by the capture step.
 if a.collect and (a.settings is not None or a.hand_patterns is not None or a.look_patterns is not None):raise ValueError('--settings/--hand-patterns/--look-patterns belong to the capture step, not --collect')
 if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must stay under .local')
 a.output.mkdir(parents=True,exist_ok=True)
 if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
 print(json.dumps(collect(a.vm,a.output) if a.collect else start(a.vm,a.output,a.settings,a.hand_patterns,a.look_patterns),indent=2))
if __name__=='__main__':main()
