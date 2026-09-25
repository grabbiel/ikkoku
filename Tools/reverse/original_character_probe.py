#!/usr/bin/env python3
"""Capture a freshly generated clothed source character in an isolated player.

Outputs geometry, pose, camera, materials and source frame to private .local
artifacts. Does not copy/read installed cards, saves or third-party plug-ins.
"""
from __future__ import annotations
import argparse, json, time, uuid, zipfile, io, re
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

def start(vm,output):
 run_path=output/'run.json'
 if run_path.exists():
  run=json.loads(run_path.read_text());root=run['root']
  if not re.fullmatch(r'C:\\Temp\\IkkokuShaderProbe-[0-9a-f]{32}',root):raise ValueError('Unknown private player directory')
  if int(run['processID'])>0:stop_probe(vm,run)
 else:
  root=r'C:\Temp\IkkokuShaderProbe-'+uuid.uuid4().hex
  retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$original='C:\Illusion\Koikatsu';New-Item -ItemType Directory "$root\BepInEx\plugins" -Force|Out-Null;New-Item -ItemType Directory "$root\BepInEx\config" -Force|Out-Null;foreach($name in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$original\$name" "$root\$name"};Copy-Item "$original\BepInEx\core" "$root\BepInEx\core" -Recurse;foreach($name in @('abdata','CharaStudio_Data')){New-Item -ItemType Junction -Path "$root\$name" -Value "$original\$name"|Out-Null};[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n")''')
  # Save before compile so a failed build can reuse this private directory.
  dump(run_path,dict(vm=vm,root=root,processID=0,stopped=True))
 properties=[]
 for path in sorted((output/'shaders').glob('*/program.json')):
  program=json.loads(path.read_text())
  properties.extend(program['name']+'\t'+p['m_Name']+'\t'+str(p['m_Type']) for p in program['properties'])
 write_small(vm,root+r'\BepInEx\plugins\shader-properties.tsv',('\n'.join(properties)+'\n').encode())
 source=Path(__file__).with_name('fixtures')/'OriginalCharacterProbe.cs'
 write_small(vm,root+r'\CharacterProbe.cs',source.read_bytes())
 result=retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuCharacterProbe.dll" /reference:$($refs -join ',') "$root\CharacterProbe.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'};if(Test-Path "$root\BepInEx\plugins\character"){Remove-Item "$root\BepInEx\plugins\character" -Recurse -Force}''')
 if result:print(result)
 pid=int(retry(vm,"$root="+ps_quote(root)+r''';$p=Get-Process CharaStudio -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq "$root\CharaStudio.exe"}|Select-Object -First 1;if($p){$p.Id}else{(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','768','-screen-height','1024','-logFile',"$root\unity.log") -PassThru).Id}''',True))
 run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False);dump(run_path,run);return run

def collect(vm,output):
 run=json.loads((output/'run.json').read_text());root=run['root'];folder=root+r'\BepInEx\plugins\character'
 status=json.loads(fetch(vm,folder+r'\status.json'))
 stop_probe(vm,run);run['stopped']=True;dump(output/'run.json',run)
 for name in ['unity.log',r'BepInEx\LogOutput.log']:
  try:(output/Path(name.replace('\\','/')).name).write_bytes(fetch(vm,root+'\\'+name))
  except RuntimeError:pass
 dump(output/'status.json',status)
 if status.get('error'):raise RuntimeError(status['error'])
 retry(vm,"$ErrorActionPreference='Stop';Add-Type -AssemblyName System.IO.Compression.FileSystem;$folder="+ps_quote(folder)+";$zip="+ps_quote(root+r'\character.zip')+";if(Test-Path $zip){Remove-Item $zip};[IO.Compression.ZipFile]::CreateFromDirectory($folder,$zip)")
 data=fetch(vm,root+r'\character.zip',128*1024*1024)
 with zipfile.ZipFile(io.BytesIO(data)) as archive:
  if any(Path(n).name!=n or n.startswith('.') for n in archive.namelist()):raise ValueError('Unexpected archive paths')
  if sum(i.file_size for i in archive.infolist())>512*1024*1024:raise ValueError('Capture exceeds extraction bound')
  names=archive.namelist()
  archive.extractall(output)
 provenance=[dict(file=p.name,sha256=digest(p.read_bytes()),bytes=p.stat().st_size) for p in sorted(output/name for name in set(names+['run.json','unity.log','LogOutput.log'])) if p.is_file()]
 dump(output/'manifest.json',dict(schemaVersion=1,files=provenance))
 return dict(status=status,files=len(provenance),archiveBytes=len(data))

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/reverse/original-character-probe');p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');a=p.parse_args()
 if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must stay under .local')
 a.output.mkdir(parents=True,exist_ok=True)
 if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
 print(json.dumps(collect(a.vm,a.output) if a.collect else start(a.vm,a.output),indent=2))
if __name__=='__main__':main()
