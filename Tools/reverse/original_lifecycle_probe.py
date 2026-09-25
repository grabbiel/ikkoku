#!/usr/bin/env python3
"""Run inert lifecycle fixtures in an isolated copy of the original Unity player."""
import argparse, json, uuid, re
from pathlib import Path
from original_character_probe import retry
from original_shader_probe import write_small, fetch, dump, digest
from vm_source import ps_quote
ROOT=Path(__file__).resolve().parents[2]

def stop_probe(vm, run):
 root=run['root']
 if not re.fullmatch(r'C:\\Temp\\IkkokuLifecycleProbe-[0-9a-f]{32}',root):raise ValueError('Unknown lifecycle probe directory')
 retry(vm,"$root="+ps_quote(root)+r''';Get-Process CharaStudio -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq "$root\CharaStudio.exe"}|Stop-Process -Force''',True)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/reverse/plugin-execution/lifecycle');p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');a=p.parse_args()
 output=a.output.resolve()
 if not output.is_relative_to((ROOT/'.local').resolve()):raise ValueError('Evidence must stay under .local')
 output.mkdir(parents=True,exist_ok=True);run_file=output/'run.json'
 if a.collect or a.stop:
  run=json.loads(run_file.read_text());root=run['root']
  if a.collect:
   version=fetch(a.vm,root+r'\BepInEx\plugins\complete.txt').decode('utf-8-sig')
   evidence=fetch(a.vm,root+r'\BepInEx\plugins\lifecycle.tsv');(output/'lifecycle.tsv').write_bytes(evidence)
   dump(output/'evidence.json',dict(unityVersion=version,traceSHA256=digest(evidence),sourceSHA256=run['sourceSHA256']))
  stop_probe(a.vm,run);run['stopped']=True;dump(run_file,run);print(json.dumps(run));return
 root=r'C:\Temp\IkkokuLifecycleProbe-'+uuid.uuid4().hex
 retry(a.vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$original='C:\Illusion\Koikatsu';New-Item -ItemType Directory "$root\BepInEx\plugins" -Force|Out-Null;New-Item -ItemType Directory "$root\BepInEx\config" -Force|Out-Null;foreach($name in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$original\$name" "$root\$name"};Copy-Item "$original\BepInEx\core" "$root\BepInEx\core" -Recurse;foreach($name in @('abdata','CharaStudio_Data')){New-Item -ItemType Junction -Path "$root\$name" -Value "$original\$name"|Out-Null};[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n")''')
 source=Path(__file__).with_name('fixtures')/'OriginalLifecycleProbe.cs'
 write_small(a.vm,root+r'\Probe.cs',source.read_bytes())
 result=retry(a.vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\Probe.dll" /reference:$($refs -join ',') "$root\Probe.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'}''')
 if result:print(result)
 pid=int(retry(a.vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id''',True))
 run=dict(root=root,vm=a.vm,processID=pid,currentUser=True,stopped=False,sourceSHA256=digest(source.read_bytes()));dump(run_file,run);print(json.dumps(run))
if __name__=='__main__':main()
