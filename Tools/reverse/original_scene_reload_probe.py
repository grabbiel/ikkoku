#!/usr/bin/env python3
"""Reload our exported scenes in the original CharaStudio player and record what it shows.

Uploads the given scene records beside the compiled probe as reload-<label>.png (the route
probe's upload pattern), loads each into an emptied scene, and collects reload-trace.json and
status.json from the probe's private folder. The collected PNGs are the uploaded files
themselves, so the comparison reads the exact bytes the player loaded. No characters, cards,
saves or third-party plug-ins are read or copied.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path
from original_character_probe import retry, player_root
from original_shader_probe import write_small, stop_probe, fetch, dump, digest
from vm_source import powershell, ps_quote
ROOT=Path(__file__).resolve().parents[2]
LABELS=('hide-rename','camera-switch','route-stop','route-rename')
SOURCE=Path(__file__).with_name('fixtures')/'OriginalSceneReloadProbe.cs'


def start(vm,output,source=None,scenes=None):
    run_file=output/'run.json'
    root=player_root(vm,output)
    source=source or SOURCE
    (output/'probe-source.cs').write_bytes(source.read_bytes())
    write_small(vm,root+r'\SceneReloadProbe.cs',source.read_bytes())
    result=retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuSceneReloadProbe.dll" /reference:$($refs -join ',') "$root\SceneReloadProbe.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'};if(Test-Path "$root\BepInEx\plugins\reload"){Remove-Item "$root\BepInEx\plugins\reload" -Recurse -Force}''')
    if result: print(result)
    hashes={}
    for label in LABELS: # beside the plugin, the same spot the route probe uploads its record to
        path=scenes[label]
        write_small(vm,root+'\\BepInEx\\plugins\\reload-'+label+'.png',path.read_bytes())
        hashes[label]=digest(path.read_bytes())
    pid=int(retry(vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id''',True))
    run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False,sceneSHA256=hashes)
    dump(run_file,run);return run


def collect(vm,output):
 run=json.loads((output/'run.json').read_text());root=run['root'];folder=root+r'\BepInEx\plugins\reload'
 # status.json is written last, so fetching it first makes polling --collect safe: until the probe
 # finishes the fetch fails and the player keeps running.
 status=json.loads(fetch(vm,folder+r'\status.json'))
 stop_probe(vm,run);run['stopped']=True;dump(output/'run.json',run)
 # The trace lives in the probe's folder; the records under comparison are the uploaded ones
 # beside the plugin, fetched back so the provenance lists the bytes the player loaded.
 for name in ['reload-trace.json']+['reload-'+label+'.png' for label in sorted(run['sceneSHA256'])]:
  try:(output/name).write_bytes(fetch(vm,(folder if name.endswith('.json') else root+r'\BepInEx\plugins')+'\\'+name))
  except RuntimeError:pass # a failed run can end before writing every result
 for name in ['unity.log',r'BepInEx\LogOutput.log']:
  try:(output/Path(name.replace('\\','/')).name).write_bytes(fetch(vm,root+'\\'+name))
  except RuntimeError:pass
 dump(output/'status.json',status)
 files=['reload-trace.json','status.json','run.json','unity.log','LogOutput.log']+['reload-'+label+'.png' for label in sorted(run['sceneSHA256'])]
 provenance=[dict(file=p.name,sha256=digest(p.read_bytes()),bytes=p.stat().st_size) for p in sorted(output/n for n in files) if p.is_file()]
 dump(output/'manifest.json',dict(schemaVersion=1,files=provenance))
 if status.get('error'):raise RuntimeError(status['error'])
 return dict(status=status,files=len(provenance))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/stt03e/probe');p.add_argument('--source',type=Path)
    for label in LABELS:p.add_argument('--'+label,type=Path,help='Scene record exported by our app for the "%s" acceptance case'%label)
    p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');a=p.parse_args()
    if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must remain in .local')
    a.output.mkdir(parents=True,exist_ok=True)
    if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
    if a.collect:
        for label in LABELS:
            if getattr(a,label.replace('-','_'))is not None:raise ValueError('--collect does not take scene inputs')
        print(json.dumps(collect(a.vm,a.output),indent=2));return
    scenes={label:getattr(a,label.replace('-','_'))for label in LABELS}
    for label,path in scenes.items():
        if path is None or not path.is_file():raise ValueError('--'+label+' requires an existing exported scene record: '+str(path))
    print(json.dumps(start(a.vm,a.output,a.source,scenes),indent=2))


if __name__=='__main__':main()
