#!/usr/bin/env python3
"""Parity gate for the scene survey's C# port of the plug-in data rules (ST-T03i).

1. Runs the Swift test sourceScenePluginDataWritesTheRuleParityCorpus, which judges every single-target edit
   (delete, duplicate, add a folder, light or camera, add or delete a route point) of synthetic scenes covering
   every rule, and writes the scenes and verdicts as JSON.
2. Converts it to the line format of fixtures/PluginSceneRuleParity.cs (corpus.txt), which the phase-B player run
   also reads to repeat this check with the player's own compiler before the survey counts anything.
3. Compiles fixtures/PluginSceneRules.cs and fixtures/PluginSceneRuleParity.cs with `dotnet` in a scratch project
   and requires every case to agree: the same verdict (accepted or refused) and the same refused entry IDs.

Only synthetic scenes are involved. Usage: plugin_rule_parity.py <work dir>
"""
from __future__ import annotations
import json, os, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name('fixtures')
PROJECT = """<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><LangVersion>5</LangVersion>
  <DefineConstants>PARITY_MAIN</DefineConstants><Nullable>disable</Nullable><ImplicitUsings>disable</ImplicitUsings>
  <EnableDefaultCompileItems>false</EnableDefaultCompileItems><RollForward>Major</RollForward></PropertyGroup>
  <ItemGroup><Compile Include="%s" /><Compile Include="%s" /></ItemGroup>
</Project>
"""


def corpus_text(corpus: dict) -> str:
    """The JSON corpus as PluginSceneRuleParity.cs reads it."""
    lines = []
    join = lambda values: ','.join(str(v) for v in values) or '-'
    for scene in corpus['scenes']:
        lines.append('scene ' + (scene['trailer'] or '-'))
        for o in scene['objects']: lines.append(f"object {o['key']} {o['kind']} {o['parent']}")
        lines.append('used ' + join(scene['used']))
        lines.append('linked ' + join(scene['linked']))
    for case in corpus['cases']:
        if case['verdict'] == 'other': continue   # a topology refusal, not plug-in data
        edit = case['edit']
        verdict = 'refused' if case['verdict'] == 'refused' else 'accepted'
        lines.append(f"case {case['scene']} {edit['kind']} {edit.get('key', -1)} {edit.get('object', -1)} {verdict} {join(case.get('ids', []))}")
    return '\n'.join(lines) + '\n'


def main():
    work = Path(sys.argv[1]).resolve(); work.mkdir(parents=True, exist_ok=True)
    corpus_json = work / 'corpus.json'
    env = dict(os.environ, IKKOKU_PLUGIN_RULE_CORPUS=str(corpus_json))
    subprocess.run(['swift', 'test', '--package-path', str(ROOT / 'Packages/Engine'), '--filter', 'RuleParityCorpus'],
                   env=env, check=True, capture_output=True)
    corpus = json.loads(corpus_json.read_text())
    (work / 'corpus.txt').write_text(corpus_text(corpus))
    project = work / 'harness'; project.mkdir(exist_ok=True)
    (project / 'Parity.csproj').write_text(PROJECT % (FIXTURES / 'PluginSceneRules.cs', FIXTURES / 'PluginSceneRuleParity.cs'))
    subprocess.run(['dotnet', 'build', '-nologo', '-v', 'q', '-o', str(project / 'bin')], cwd=project, check=True)
    result = subprocess.run(['dotnet', str(project / 'bin' / 'Parity.dll'), str(work / 'corpus.txt')], text=True, capture_output=True)
    print(result.stdout[-6000:], end='')
    sys.exit(result.returncode)


if __name__ == '__main__':
    main()
