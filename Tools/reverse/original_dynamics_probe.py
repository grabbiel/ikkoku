#!/usr/bin/env python3
"""Numerical DynamicBone parameters and curves from a fresh clothed isolated Unity player."""
from __future__ import annotations
import argparse, json
from pathlib import Path
from original_character_probe import retry, collect, player_root
from original_shader_probe import write_small, stop_probe, dump, digest
from vm_source import ps_quote
ROOT=Path(__file__).resolve().parents[2]
# Motion request read by the plugin from the capture folder: 90 scripted frames
# at the locked 60 Hz step; the fixture refuses any other request instead of
# silently integrating for a different duration.
MOTION_REQUEST='90\n60.0\n'


def start(vm,output,motion=False):
    run_file=output/'run.json'
    root=player_root(vm,output)
    source=Path(__file__).with_name('fixtures')/'OriginalDynamicsProbe.cs'
    write_small(vm,root+r'\DynamicsProbe.cs',source.read_bytes())
    result=retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuDynamicsProbe.dll" /reference:$($refs -join ',') "$root\DynamicsProbe.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'};if(Test-Path "$root\BepInEx\plugins\character"){Remove-Item "$root\BepInEx\plugins\character" -Recurse -Force}''')
    if result: print(result)
    if motion:
        # The compile step deletes the capture folder, so recreate it and upload
        # the motion request after compiling but before the player starts; an
        # absent file leaves every capture output byte-identical.
        retry(vm,"$ErrorActionPreference='Stop';New-Item -ItemType Directory "+ps_quote(root+r'\BepInEx\plugins\character')+" -Force|Out-Null")
        write_small(vm,root+r'\BepInEx\plugins\character\motion.tsv',MOTION_REQUEST.encode())
    pid=int(retry(vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id''',True))
    run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False);dump(run_file,run);return run


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/reverse/original-dynamics-probe');p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');p.add_argument('--motion',action='store_true',help='upload the fixed 90-frame 60 Hz motion request so the plugin also records scripted particle motion');a=p.parse_args()
    # Checked before any output folder is touched: the motion request is uploaded only by the capture step.
    if a.collect and a.motion:raise ValueError('--motion belongs to the capture step, not --collect')
    if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must remain in .local')
    a.output.mkdir(parents=True,exist_ok=True)
    if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
    print(json.dumps(collect(a.vm,a.output) if a.collect else start(a.vm,a.output,a.motion),indent=2))


if __name__=='__main__':main()
