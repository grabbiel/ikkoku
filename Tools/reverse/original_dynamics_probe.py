#!/usr/bin/env python3
"""Numerical DynamicBone parameters and curves from a fresh clothed isolated Unity player."""
from __future__ import annotations
import argparse, json, re, uuid
from pathlib import Path
from original_character_probe import retry, collect
from original_shader_probe import write_small, stop_probe, dump, digest
from vm_source import ps_quote
ROOT=Path(__file__).resolve().parents[2]


def start(vm,output):
    run_file=output/'run.json'
    if run_file.exists():
        run=json.loads(run_file.read_text());root=run['root']
        if not re.fullmatch(r'C:\\Temp\\IkkokuShaderProbe-[0-9a-f]{32}',root):raise ValueError('Unknown private player root')
        if int(run['processID'])>0:stop_probe(vm,run)
    else:
        root=r'C:\Temp\IkkokuShaderProbe-'+uuid.uuid4().hex
        retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$original='C:\Illusion\Koikatsu';New-Item -ItemType Directory "$root\BepInEx\plugins" -Force|Out-Null;New-Item -ItemType Directory "$root\BepInEx\config" -Force|Out-Null;foreach($name in @('CharaStudio.exe','winhttp.dll','doorstop_config.ini')){Copy-Item "$original\$name" "$root\$name"};Copy-Item "$original\BepInEx\core" "$root\BepInEx\core" -Recurse;foreach($name in @('abdata','CharaStudio_Data')){New-Item -ItemType Junction -Path "$root\$name" -Value "$original\$name"|Out-Null};[IO.File]::WriteAllText("$root\BepInEx\config\BepInEx.cfg","[Logging.Console]`nEnabled = false`n")''')
        dump(run_file,dict(vm=vm,root=root,processID=0,stopped=True))
    source=Path(__file__).with_name('fixtures')/'OriginalDynamicsProbe.cs'
    write_small(vm,root+r'\DynamicsProbe.cs',source.read_bytes())
    result=retry(vm,"$ErrorActionPreference='Stop';$root="+ps_quote(root)+r''';$refs=@("$root\BepInEx\core\BepInEx.dll")+(Get-ChildItem "$root\CharaStudio_Data\Managed" -Filter '*.dll'|ForEach-Object {$_.FullName});& C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /noconfig /nostdlib+ /target:library /out:"$root\BepInEx\plugins\IkkokuDynamicsProbe.dll" /reference:$($refs -join ',') "$root\DynamicsProbe.cs";if($LASTEXITCODE -ne 0){throw 'Compile failed'};if(Test-Path "$root\BepInEx\plugins\character"){Remove-Item "$root\BepInEx\plugins\character" -Recurse -Force}''')
    if result: print(result)
    pid=int(retry(vm,"$root="+ps_quote(root)+r''';(Start-Process -FilePath "$root\CharaStudio.exe" -WorkingDirectory $root -ArgumentList @('-force-d3d11','-screen-fullscreen','0','-screen-width','640','-screen-height','480','-logFile',"$root\unity.log") -PassThru).Id''',True))
    run=dict(vm=vm,root=root,processID=pid,sourceSHA256=digest(source.read_bytes()),currentUser=True,stopped=False);dump(run_file,run);return run


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--vm',default='Windows 11');p.add_argument('--output',type=Path,default=ROOT/'.local/reverse/original-dynamics-probe');p.add_argument('--collect',action='store_true');p.add_argument('--stop',action='store_true');a=p.parse_args()
    if not a.output.resolve().is_relative_to((ROOT/'.local').resolve()):raise ValueError('Outputs must remain in .local')
    a.output.mkdir(parents=True,exist_ok=True)
    if a.stop:stop_probe(a.vm,json.loads((a.output/'run.json').read_text()));return
    print(json.dumps(collect(a.vm,a.output) if a.collect else start(a.vm,a.output),indent=2))


if __name__=='__main__':main()
