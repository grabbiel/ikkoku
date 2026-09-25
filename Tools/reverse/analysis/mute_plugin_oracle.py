#!/usr/bin/env python3
"""Run unchanged recovered MuteInBackground C# and the installed config reader.

Original source, DLLs and results remain in ignored .local output. The host only
substitutes BaseUnityPlugin construction and AudioListener.volume, not config
parsing or the focus callbacks. No VM/game files are mutated by this command.
"""
from __future__ import annotations
import argparse, base64, hashlib, json, subprocess
from pathlib import Path
from xml.sax.saxutils import escape


def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--bepinex', type=Path, required=True)
    p.add_argument('--plugin', type=Path, required=True)
    p.add_argument('--installed-config', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    repo = Path(__file__).resolve().parents[3]; out = args.output.resolve()
    if '.local' not in out.parts: raise ValueError('Recovered evidence must remain in ignored .local output')
    out.mkdir(parents=True, exist_ok=True)
    host = repo / 'Tools/reverse/fixtures/MutePluginOracle'
    (out/'MuteInBackground.cs').write_bytes(args.source.read_bytes())
    paths = [args.source, args.bepinex, args.plugin, args.installed_config]
    (out/'Oracle.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType><EnableDefaultCompileItems>false</EnableDefaultCompileItems><NoWarn>0436;0108</NoWarn></PropertyGroup><ItemGroup>' + ''.join(f'<Compile Include="{escape(str(x))}"/>' for x in [host/'Host.cs',host/'Program.cs',out/'MuteInBackground.cs']) + f'<Reference Include="BepInEx"><HintPath>{escape(str(args.bepinex.resolve()))}</HintPath></Reference></ItemGroup></Project>')
    config = []
    def add(name, text, encoding='utf-8'):
        data = text if isinstance(text,bytes) else text.encode(encoding)
        config.append(dict(name=name,data=base64.b64encode(data).decode()))
    add('installed',args.installed_config.read_bytes())
    for name,text in [
        ('empty',''),('true','[Config]\nMute In Background=true'),('false','[Config]\nMute In Background=false'),
        ('case-bool','[Config]\r\nMute In Background = TrUe \r\n'),
        ('wrong-section','[config]\nMute In Background=true'),('wrong-key','[Config]\nmute in background=true'),
        ('duplicates','[Config]\nMute In Background=true\nMute In Background=false'),
        ('invalid-last','[Config]\nMute In Background=true\nMute In Background=wrong'),
        ('valid-last','[Config]\nMute In Background=wrong\nMute In Background=true'),
        ('inline-comment','[Config]\nMute In Background=true # comment'),('numeric','[Config]\nMute In Background=1'),
        ('quoted','[Config]\nMute In Background="true"'),('whitespace',' [Config] \n  Mute In Background  =  true\t'),
        ('section-padding','[ Config ]\nMute In Background=true'),('bad-key','[Config]\nBad[Key]=1'),
        ('hash-comment','# ignored = any\n[Config]\nMute In Background=true'),
        ('semicolon','[Config]\n;Mute In Background=false\nMute In Background=true'),
        ('empty-value','[Config]\nMute In Background='),
        ('null-padding','[Config]\nMute In Background=\0 true \0'),
    ]: add(name,text)
    for encoding in ['utf-8-sig','utf-16','utf-32']: add(encoding,'[Config]\nMute In Background=true',encoding)
    cases = [
        dict(name='disabled',volume=.7,steps=[dict(focus=False),dict(focus=True)]),
        dict(name='enabled',volume=.73,steps=[dict(enabled=True),dict(focus=False),dict(focus=True),dict(focus=True)]),
        dict(name='repeated-loss',volume=.42,steps=[dict(enabled=True),dict(focus=False),dict(focus=False),dict(focus=True)]),
        dict(name='disable-muted',volume=.31,steps=[dict(enabled=True),dict(focus=False),dict(enabled=False),dict(focus=False),dict(focus=True)]),
        dict(name='external-volume',volume=.61,steps=[dict(enabled=True),dict(focus=False),dict(volume=.22),dict(focus=True)]),
        dict(name='unfocused-enable',volume=.81,steps=[dict(focus=False),dict(enabled=True),dict(focus=True),dict(focus=False),dict(focus=True)]),
        dict(name='already-muted',volume=0,steps=[dict(enabled=True),dict(focus=False),dict(focus=True)]),
    ]
    inputs=dict(configurations=config,cases=cases); (out/'input.json').write_text(json.dumps(inputs,indent=2)+'\n')
    subprocess.run(['dotnet','build',str(out/'Oracle.csproj'),'--nologo','-v:q'],check=True)
    subprocess.run(['dotnet',str(out/'bin/Debug/net10.0/Oracle.dll'),str(out/'input.json'),str(out/'output.json')],check=True)
    results=json.loads((out/'output.json').read_text())
    evidence=dict(schemaVersion=1,kind='recovered-mute-plugin-csharp-oracle',sources=[dict(path=str(x.resolve()),sha256=digest(x)) for x in paths],host=[dict(path=str(x.relative_to(repo)),sha256=digest(x)) for x in sorted(host.glob('*.cs'))],inputs=inputs,results=results,limitations=['Focus callbacks execute unchanged recovered C# against a scalar AudioListener host. Config parsing executes the installed BepInEx DLL. Native AVAudioEngine verification is separate; this is not original Unity player audio execution.'])
    (out/'reference.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps(dict(reference=str(out/'reference.json'),configurations=len(config),cases=len(cases))))


if __name__ == '__main__': main()
