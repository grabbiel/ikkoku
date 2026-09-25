#!/usr/bin/env python3
"""Compile untouched recovered accessory-label plugin against a small UI host."""
from __future__ import annotations
import argparse, hashlib, json, subprocess
from pathlib import Path
from xml.sax.saxutils import escape


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,required=True);p.add_argument('--plugin',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    out=a.output.resolve();repo=Path(__file__).resolve().parents[3];host=repo/'Tools/reverse/fixtures/AccessoryNamesOracle'
    if '.local' not in out.parts: raise ValueError('Recovered evidence must remain in .local')
    out.mkdir(parents=True,exist_ok=True);(out/'Recovered.cs').write_bytes(a.source.read_bytes())
    (out/'Oracle.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup>'+''.join(f'<Compile Include="{escape(str(x))}"/>' for x in [out/'Recovered.cs',host/'Host.cs',host/'Program.cs'])+'</ItemGroup></Project>')
    def row(text,active=True):return dict(text=text,active=active,buttonX=[100,130,70,160],offsetMaxX=42 if text is not None else None)
    cases=[dict(name='normal',rows=[row('スロット01'),row('スロット02'),row('スロット03',False)],names={'0':'Original glasses','1':'Custom name e\u0301'}),dict(name='mixed-widgets',rows=[row(None),row('Accessories'),row('Slot 9'),row('②'),row('Arabic ١'),row('Astral 𝟏')],names={'0':'First selected accessory','1':'Second selected accessory'}),dict(name='missing',rows=[row('01'),row('02')],names={})]
    (out/'input.json').write_text(json.dumps(dict(cases=cases),indent=2)+'\n')
    subprocess.run(['dotnet','build',str(out/'Oracle.csproj'),'--nologo','-v:q'],check=True)
    subprocess.run(['dotnet',str(out/'bin/Debug/net10.0/Oracle.dll'),str(out/'input.json'),str(out/'output.json')],check=True)
    def evidence(path):return dict(path=str(path.resolve()),sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    result=dict(schemaVersion=1,kind='recovered-accessory-names-csharp-oracle',sources=[evidence(a.source),evidence(a.plugin)],host=[evidence(x) for x in sorted(host.glob('*.cs'))],cases=cases,results=json.loads((out/'output.json').read_text()),limitations=['Unchanged recovered coroutine executes against queried UI component stubs; native layout uses SwiftUI. This does not execute Harmony in Unity.'])
    (out/'reference.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(dict(reference=str(out/'reference.json'),cases=len(cases))))


if __name__=='__main__':main()
