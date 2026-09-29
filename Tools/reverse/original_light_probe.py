#!/usr/bin/env python3
"""CharaStudio character-light capture: charaLight rot pairs through CameraLightCtrl.Reflect under two camera poses.

Runs OriginalLightProbe.cs in an isolated player copy and collects light-trace.json
and status.json into a private .local folder. The probe only mutates the scene
record's charaLight and Studio's own light rig. No characters, cards, saves or
third-party plug-ins are read or copied.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path
from original_character_probe import retry, player_root
from original_shader_probe import write_small, stop_probe, fetch, dump, digest
from vm_source import powershell, ps_quote
ROOT=Path(__file__).resolve().parents[2]


def start(vm,output,source=None):
    run_file=output/'run.json'
    root=player_root(vm,output)
    source=source or Path(__file__).with_name('fixtures')/'OriginalLightProbe.cs'
    (output/'probe-source.cs').write_bytes(source.read_bytes())
    write_small(vm,root+r'\LightProbe.cs',source.read_bytes())
    result=retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuLightProbe.dll" /reference:$($refs -join ',') "$root\LightProbe.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'};if(Test-Path "$root\BepInEx\plugins\light"){Remove-Item "$root\BepInEx\plugins\light" -Recurse -Force}''')
    if result: print(result)
    pid=int(retry(vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id''',True))
    run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False)
    dump(run_file,run);return run


def collect(vm,output):
 run=json.loads((output/'run.json').read_text());root=run['root'];folder=root+r'\BepInEx\plugins\light'
 names=['status.json','light-trace.json']
 for name in names:(output/name).write_bytes(fetch(vm,folder+'\\'+name))
 stop_probe(vm,run);run['stopped']=True;dump(output/'run.json',run)
 for name in ['unity.log',r'BepInEx\LogOutput.log']:
  try:(output/Path(name.replace('\\','/')).name).write_bytes(fetch(vm,root+'\\'+name))
  except RuntimeError:pass
 status=json.loads((output/'status.json').read_text())
 if status.get('error'):raise RuntimeError(status['error'])
 provenance=[dict(file=p.name,sha256=digest(p.read_bytes()),bytes=p.stat().st_size) for p in sorted(output/name for name in set(names+['run.json','unity.log','LogOutput.log'])) if p.is_file()]
 dump(output/'manifest.json',dict(schemaVersion=1,files=provenance))
 return dict(status=status,files=len(provenance))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/stt11k/probe');p.add_argument('--source',type=Path);p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');a=p.parse_args()
    if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must remain in .local')
    a.output.mkdir(parents=True,exist_ok=True)
    if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
    if a.collect:print(json.dumps(collect(a.vm,a.output),indent=2));return
    print(json.dumps(start(a.vm,a.output,a.source),indent=2))


if __name__=='__main__':main()
