#!/usr/bin/env python3
"""Parity gate for the scene survey's C# port of the plug-in data rules (ST-T03i).

1. Runs the Swift test sourceScenePluginDataWritesTheRuleParityCorpus, which judges every single-target edit
   (delete, duplicate, add a folder, light or camera, add or delete a route point) of synthetic scenes covering
   every rule, and writes the scenes and verdicts as JSON.
2. Converts it to the line format of fixtures/PluginSceneRuleParity.cs (corpus.txt), which the phase-B player run
   also reads to repeat this check with the player's own compiler before the survey counts anything.
3. Compiles fixtures/PluginSceneRules.cs and fixtures/PluginSceneRuleParity.cs with `dotnet` in a scratch project
   and requires every case to agree: the same verdict (accepted or refused) and the same refused entry IDs.

With --mutations it then compiles each mutant of PluginSceneRules.cs in MUTATIONS (one rule check broken) and
requires every mutant to disagree with the Swift corpus somewhere: a control that the corpus exercises each rewrite
rule's refusals. Refusals only an edit that both deletes and copies reaches (#278) are outside the corpus's
single-target edits; the Engine tests cover them.

Only synthetic scenes are involved.
Usage: plugin_rule_parity.py <work dir> [--build-path <swift build path>] [--mutations]
"""
from __future__ import annotations
import argparse, json, os, subprocess, sys
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


# (name, text in PluginSceneRules.cs, replacement): each breaks one check of the rewrite rules.
MUTATIONS = [
    ('kkpe-gate', 'if(edit.Unchanged(Item)&&!edit.Touches(new HashSet<int>(edit.SourceSorted(new[]{Character})),true))return null;',
     'if(edit.Unchanged(Item))return null;'),
    ('kkpe-root-version', 'if(doc.Elements[0].Name!="root"||doc.Attribute(0,"version")<0)', 'if(doc.Elements[0].Name!="root")'),
    ('kkpe-count', 'if(elements.Count!=sourceItems.Count)throw', 'if(false)throw'),
    ('kkpe-index', '||index!=sourceItems[i])throw', ')throw'),
    ('kkpe-referenced', 'if(referenced.Contains(template))throw', 'if(false)throw'),
    ('kkpe-fresh-id', 'int fresh;if(!FreshId(template,used,out fresh))throw', 'int fresh;FreshId(template,used,out fresh);if(false)throw'),
    ('kkpe-current-block', 'if(card[1]==0)throw', 'if(false)throw'),
    ('kkpe-card-error', 'if(card==null)throw new RuleFailure("cannot read character', 'if(false)throw new RuleFailure("cannot read character'),
    ('kkpe-shared-id', 'if(owners[id]>1)throw', 'if(owners[id]>2)throw'),
    ('me-version', 'if(version!=1)throw', 'if(false)throw'),
    ('me-stale', '(stale&&copies.Count>0)', 'false'),
    ('me-record-key', 'if(!keys.Contains(f.Key))throw new RuleFailure(', 'if(false)throw new RuleFailure('),
    ('me-purge-timeline', 'if(purge&&TimelineMentions(trailer,"textureProperty"))throw', 'if(false)throw'),
    ('nc-copied-ends', 'if(edit.Copied.Contains(parents[i])&&edit.Copied.Contains(children[i]))throw', 'if(false)throw'),
    ('nc-camera-stop', 'if(parents[i]==int.MinValue)break;', 'if(parents[i]==int.MinValue)continue;'),
    ('nc-pairs', 'if(pairs.Contains(childEnd+"\\u0001"+parentEnd)||!pairs.Add(parentEnd+"\\u0001"+childEnd))throw', 'if(false)throw'),
    ('nc-load-id', 'if(!hasParent||!hasChild||!hasLoad)throw', 'if(!hasParent||!hasChild)throw'),
    ('nc-timeline', 'if(renumbered&&TimelineMentions(trailer,"NodesConstraints"))throw', 'if(false)throw'),
    ('xml-self-closing', 'if(b.Length-offset>=3&&b[offset]==0x20&&b[offset+1]==0x2f&&b[offset+2]==0x3e){e.SelfClosing=true;offset+=3;}',
     'if(b.Length-offset>=2&&b[offset]==0x2f&&b[offset+1]==0x3e){e.SelfClosing=true;offset+=2;}else if(b.Length-offset>=3&&b[offset]==0x20&&b[offset+1]==0x2f&&b[offset+2]==0x3e){e.SelfClosing=true;offset+=3;}'),
]


def harness(project: Path, rules: Path, corpus: Path) -> subprocess.CompletedProcess:
    """Compiles `rules` with the parity harness and runs it on `corpus`."""
    project.mkdir(parents=True, exist_ok=True)
    (project / 'Parity.csproj').write_text(PROJECT % (rules, FIXTURES / 'PluginSceneRuleParity.cs'))
    subprocess.run(['dotnet', 'build', '-nologo', '-v', 'q', '-o', str(project / 'bin')], cwd=project, check=True, capture_output=True)
    return subprocess.run(['dotnet', str(project / 'bin' / 'Parity.dll'), str(corpus)], text=True, capture_output=True)


def corpus_text(corpus: dict) -> str:
    """The JSON corpus as PluginSceneRuleParity.cs reads it."""
    lines = []
    join = lambda values: ','.join(str(v) for v in values) or '-'
    for scene in corpus['scenes']:
        lines.append('scene ' + (scene['trailer'] or '-'))
        for o in scene['objects']: lines.append(f"object {o['key']} {o['kind']} {o['parent']}")
        lines.append('used ' + join(scene['used']))
        for card in scene['cards']: lines.append(f"card {card['key']} {'!' if card.get('error') else join(card['steps'])}")
        lines.append('kkpeids ' + join(scene.get('kkpeIds', [])))
        for card in scene.get('kkpeCards', []):
            lines.append(f"kkpecard {card['key']} " + ('!' if card.get('error') else f"{card['id']} {1 if card['current'] else 0}"))
    for case in corpus['cases']:
        if case['verdict'] == 'other': continue   # a topology refusal, not plug-in data
        edit = case['edit']
        verdict = 'refused' if case['verdict'] == 'refused' else 'accepted'
        lines.append(f"case {case['scene']} {edit['kind']} {edit.get('key', -1)} {edit.get('object', -1)} {verdict} {join(case.get('ids', []))}")
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('work')
    parser.add_argument('--build-path', help='the swift build path to reuse (default: the package\'s own)')
    parser.add_argument('--mutations', action='store_true', help='also require every mutant in MUTATIONS to disagree')
    args = parser.parse_args()
    work = Path(args.work).resolve(); work.mkdir(parents=True, exist_ok=True)
    corpus_json = work / 'corpus.json'
    env = dict(os.environ, IKKOKU_PLUGIN_RULE_CORPUS=str(corpus_json))
    command = ['swift', 'test', '--package-path', str(ROOT / 'Packages/Engine'), '--filter', 'RuleParityCorpus']
    if args.build_path: command += ['--build-path', str(Path(args.build_path).resolve())]
    subprocess.run(command, env=env, check=True, capture_output=True)
    corpus = json.loads(corpus_json.read_text())
    (work / 'corpus.txt').write_text(corpus_text(corpus))
    result = harness(work / 'harness', FIXTURES / 'PluginSceneRules.cs', work / 'corpus.txt')
    print(result.stdout[-6000:], end='')
    if result.returncode != 0 or not args.mutations: sys.exit(result.returncode)
    source = (FIXTURES / 'PluginSceneRules.cs').read_text()
    survivors = []
    for name, text, replacement in MUTATIONS:
        if source.count(text) != 1: sys.exit(f'mutation {name}: its text occurs {source.count(text)} times')
        mutant = work / 'mutants' / f'{name}.cs'; mutant.parent.mkdir(exist_ok=True)
        mutant.write_text(source.replace(text, replacement))
        outcome = harness(work / 'mutants' / name, mutant, work / 'corpus.txt')
        summary = outcome.stdout.strip().splitlines()[-1] if outcome.stdout.strip() else outcome.stderr[-200:]
        print(f'mutant {name}: {summary}')
        if outcome.returncode == 0: survivors.append(name)
    print(f'mutants: {len(MUTATIONS)}, survived: {len(survivors)} {survivors}')
    sys.exit(1 if survivors else 0)


if __name__ == '__main__':
    main()
