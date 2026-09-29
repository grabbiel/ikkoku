#!/usr/bin/env python3
"""Studio camera objects on the original player: activation, nesting, load rule and toggle-off.

Runs OriginalCameraObjectProbe.cs in the isolated player copy recorded in run.json (shared
player_root), then --collect fetches status.json, camera-trace.json and the three hand-authored
scene records into a private .local folder. Only synthetic objects are authored; no installed
cards, saves or third-party plug-ins are read or copied.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path
from original_character_probe import retry, retry_call, player_root
from original_shader_probe import write_small, stop_probe, fetch, dump, digest
from vm_source import ps_quote
ROOT=Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT=ROOT/'.local/reverse/original-camera-object-probe'
SOURCE=Path(__file__).with_name('fixtures')/'OriginalCameraObjectProbe.cs'
DATA='camera' # plugin sub-folder the probe writes into
RESULTS=['camera-trace.json','scene-x.png','scene-y.png','scene-none.png']


def compile_script(root):
    """Compile the uploaded probe against the player's own assemblies; csc output is kept for a failed build."""
    return "$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});$csc=& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuCameraObjectProbe.dll" /reference:$($refs -join ',') "$root\CameraObjectProbe.cs" 2>&1|Out-String;if($LASTEXITCODE -ne 0){throw "Compile failed:$csc"};if(Test-Path "$root\BepInEx\plugins\camera"){Remove-Item "$root\BepInEx\plugins\camera" -Recurse -Force}'''


def start(vm,output,source=None):
    run_file=output/'run.json'
    root=player_root(vm,output)
    source=source or SOURCE
    (output/'probe-source.cs').write_bytes(source.read_bytes())
    write_small(vm,root+r'\CameraObjectProbe.cs',source.read_bytes())
    result=retry(vm,compile_script(root))
    if result:print(result)
    pid=int(retry(vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id''',True))
    run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False)
    dump(run_file,run);return run


def collect(vm,output):
    run=json.loads((output/'run.json').read_text());root=run['root'];folder=root+'\\BepInEx\\plugins\\'+DATA
    # status.json is written last, so fetching it first makes polling --collect safe: until the probe
    # finishes the fetch fails and the player keeps running.
    status=json.loads(retry_call(fetch,vm,folder+r'\status.json'))
    stop_probe(vm,run);run['stopped']=True;dump(output/'run.json',run)
    for name in RESULTS:
        try:(output/name).write_bytes(retry_call(fetch,vm,folder+'\\'+name))
        except RuntimeError:pass # a failed run can end before writing every result
    for name in ['unity.log',r'BepInEx\LogOutput.log']:
        try:(output/Path(name.replace('\\','/')).name).write_bytes(retry_call(fetch,vm,root+'\\'+name))
        except RuntimeError:pass
    dump(output/'status.json',status)
    names=RESULTS+['status.json','run.json','probe-source.cs','unity.log','LogOutput.log']
    provenance=[dict(file=p.name,sha256=digest(p.read_bytes()),bytes=p.stat().st_size) for p in sorted(output/n for n in names) if p.is_file()]
    dump(output/'manifest.json',dict(schemaVersion=1,files=provenance))
    if status.get('error'):raise RuntimeError(status['error'])
    return dict(status=status,files=len(provenance))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=DEFAULT_OUTPUT)
    p.add_argument('--source',type=Path,help='probe source to compile instead of fixtures/OriginalCameraObjectProbe.cs')
    p.add_argument('--collect',action='store_true',help='fetch the results once status.json exists, then stop the player')
    p.add_argument('--stop',action='store_true',help='stop the recorded player without collecting')
    a=p.parse_args()
    if a.collect and a.source is not None:raise ValueError('--source belongs to the capture step, not --collect')
    if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must remain in .local')
    a.output.mkdir(parents=True,exist_ok=True)
    if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
    print(json.dumps(collect(a.vm,a.output) if a.collect else start(a.vm,a.output,a.source),indent=2))


if __name__=='__main__':main()
