#!/usr/bin/env python3
"""Two authored CharaStudio routes: serialized scene record plus per-frame childRoot placement.

Runs OriginalRouteProbe.cs in an isolated player copy, collects route-scene.png,
route-trace.json and status.json into a private .local folder. With --load-scene
the probe reloads and replays that uploaded record instead of authoring, and the
collected route-scene.png is the uploaded file itself. No characters,
cards, saves or third-party plug-ins are read or copied.
"""
from __future__ import annotations
import argparse, json, re, uuid
from pathlib import Path
from original_character_probe import retry
from original_shader_probe import write_small, stop_probe, fetch, dump, digest
from vm_source import powershell, ps_quote
ROOT=Path(__file__).resolve().parents[2]


def start(vm,output,source=None,load_scene=None):
    run_file=output/'run.json'
    if run_file.exists():
        run=json.loads(run_file.read_text());root=run['root']
        if not re.fullmatch(r'C:\\Temp\\IkkokuShaderProbe-[0-9a-f]{32}',root):raise ValueError('Unknown private player root')
        if int(run['processID'])>0:stop_probe(vm,run)
    else:
        root=r'C:\Temp\IkkokuShaderProbe-'+uuid.uuid4().hex
        retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$original='C:\Illusion\Koikatsu';New-Item -ItemType Directory "$root\BepInEx\plugins" -Force|Out-Null;New-Item -ItemType Directory "$root\BepInEx\config" -Force|Out-Null;foreach($name in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$original\$name" "$root\$name"};Copy-Item "$original\BepInEx\core" "$root\BepInEx\core" -Recurse;foreach($name in @('abdata','CharaStudio_Data')){New-Item -ItemType Junction -Path "$root\$name" -Value "$original\$name"|Out-Null};[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n")''')
        # Save before compile so a failed build can reuse this private directory.
        dump(run_file,dict(vm=vm,root=root,processID=0,stopped=True))
    source=source or Path(__file__).with_name('fixtures')/'OriginalRouteProbe.cs'
    (output/'probe-source.cs').write_bytes(source.read_bytes())
    write_small(vm,root+r'\RouteProbe.cs',source.read_bytes())
    result=retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuRouteProbe.dll" /reference:$($refs -join ',') "$root\RouteProbe.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'};if(Test-Path "$root\BepInEx\plugins\route"){Remove-Item "$root\BepInEx\plugins\route" -Recurse -Force}''')
    if result: print(result)
    if load_scene is not None:write_small(vm,root+r'\BepInEx\plugins\route-scene.png',load_scene.read_bytes()) # The probe reloads this instead of authoring, and compares against this exact file.
    pid=int(retry(vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id''',True))
    run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False)
    if load_scene is not None:run['loadSceneSHA256']=digest(load_scene.read_bytes())
    dump(run_file,run);return run


def collect(vm,output):
 run=json.loads((output/'run.json').read_text());root=run['root'];folder=root+r'\BepInEx\plugins\route'
 names=['status.json','route-trace.json','route-scene.png']
 for name in names[:2]:(output/name).write_bytes(fetch(vm,folder+'\\'+name))
 status=json.loads((output/'status.json').read_text())
 # In load mode the record under comparison is the uploaded one beside the plugin, not a fresh save.
 scene=root+r'\BepInEx\plugins\route-scene.png' if status.get('mode')=='load' else folder+r'\route-scene.png'
 (output/names[2]).write_bytes(fetch(vm,scene))
 stop_probe(vm,run);run['stopped']=True;dump(output/'run.json',run)
 for name in ['unity.log',r'BepInEx\LogOutput.log']:
  try:(output/Path(name.replace('\\','/')).name).write_bytes(fetch(vm,root+'\\'+name))
  except RuntimeError:pass
 if status.get('error'):raise RuntimeError(status['error'])
 provenance=[dict(file=p.name,sha256=digest(p.read_bytes()),bytes=p.stat().st_size) for p in sorted(output/name for name in set(names+['run.json','unity.log','LogOutput.log'])) if p.is_file()]
 dump(output/'manifest.json',dict(schemaVersion=1,files=provenance))
 return dict(status=status,files=len(provenance))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/stt11c/probe');p.add_argument('--source',type=Path);p.add_argument('--load-scene',type=Path,help='Scene record to upload beside the plugin so the probe reloads and replays it instead of authoring');p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');a=p.parse_args()
    if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must remain in .local')
    a.output.mkdir(parents=True,exist_ok=True)
    if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
    if a.collect:print(json.dumps(collect(a.vm,a.output),indent=2));return
    if a.load_scene is not None and not a.load_scene.is_file():raise ValueError('--load-scene requires an existing scene record: '+str(a.load_scene))
    print(json.dumps(start(a.vm,a.output,a.source,a.load_scene),indent=2))


if __name__=='__main__':main()
