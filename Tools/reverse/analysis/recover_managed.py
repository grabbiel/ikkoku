#!/usr/bin/env python3
"""Recover complete local managed projects, metadata and IL without running them.

Generated source stays in ignored .local. Decompilation is an evidence stage,
not a claim that the resulting C# compiles or its behavior has been ported.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[3]
VERSION = 4


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local_output(path: Path) -> Path:
    value = path.resolve()
    if not value.is_relative_to((REPO / '.local').resolve()):
        raise ValueError('Recovered source must remain under repository .local')
    return value


def valid_generation(path: Path, identity: dict) -> bool:
    try:
        manifest = json.loads((path / 'manifest.json').read_text())
        if manifest['identity'] != identity or not manifest['files']:
            return False
        for entry in manifest['files']:
            file = (path / entry['path']).resolve()
            if not file.is_relative_to(path.resolve()) or not file.is_file():
                return False
            if file.stat().st_size != entry['bytes'] or sha(file) != entry['sha256']:
                return False
        actual = {p.relative_to(path).as_posix() for p in path.rglob('*') if p.is_file() and p != path / 'manifest.json'}
        return actual == {entry['path'] for entry in manifest['files']}
    except (OSError, ValueError, KeyError, TypeError):
        return False


def run(tool: Path, assembly: Path, args: list[str], log: Path, timeout: int) -> dict:
    command = [str(tool), '--disable-updatecheck', *args, str(assembly)]
    with log.open('wb') as output, log.with_suffix('.stderr.txt').open('wb') as error:
        try:
            process = subprocess.run(command, stdout=output, stderr=error, timeout=timeout)
            return {'exitCode': process.returncode, 'timedOut': False}
        except subprocess.TimeoutExpired:
            return {'exitCode': None, 'timedOut': True}


def inventory_tree(stage: Path) -> tuple[list[dict], list[dict]]:
    files, diagnostics = [], []
    for path in sorted(stage.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(stage).as_posix()
        files.append({'path': relative, 'bytes': path.stat().st_size, 'sha256': sha(path)})
        if path.suffix == '.cs':
            text = path.read_text(errors='replace')
            for number, line in enumerate(text.splitlines(), 1):
                if 'DecompilerException' in line or 'Error decompiling' in line or re.search(r'//\s*System\.\w+Exception:', line):
                    diagnostics.append({'file': relative, 'line': number, 'message': line.strip()[:512]})
    return files, diagnostics


def decompilation_errors(log: Path) -> list[dict]:
    errors = []
    for line in log.read_text(errors='replace').splitlines():
        match = re.search(r'Error decompiling @([0-9A-Fa-f]+) (.*?): (.*)', line)
        if match:
            errors.append({'token': '0x' + match[1], 'member': match[2], 'error': match[3]})
    return errors


def metadata_type_name(display_name: str, definitions: list[dict]) -> str:
    names = [(row['Namespace'] + '.' if row['Namespace'] else '') + row['Name'] for row in definitions]
    if display_name in names:
        return display_name
    matches = [name for name in names if re.sub(r'`\d+', '', name) == display_name]
    if len(matches) != 1:
        raise ValueError(f'Cannot identify failed metadata type uniquely: {display_name}')
    return matches[0]


def recover(assembly: Path, references: Path, tool: Path, output: Path, tool_version: str,
            known: list[dict], timeout: int, fallback_tool: Path | None = None,
            fallback_version: str | None = None) -> dict:
    assembly_hash = sha(assembly)
    matches = [entry['path'] for entry in known if entry['sha256'] == assembly_hash]
    if not matches:
        raise ValueError(f'Assembly does not match an inventoried source hash: {assembly}')
    reference_files = [{'name': path.name, 'sha256': sha(path)} for path in sorted(references.glob('*.dll'))]
    identity = {'schemaVersion': VERSION, 'assemblySHA256': assembly_hash, 'toolVersion': tool_version,
                'fallbackToolVersion': fallback_version, 'timeoutSeconds': timeout,
                'referenceFiles': reference_files, 'modes': ['project', 'il', 'TypeDef', 'MethodDef', 'AssemblyRef', 'TypeRef']}
    config = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    target = output / assembly_hash / config
    if target.exists():
        if not valid_generation(target, identity):
            raise ValueError(f'Existing recovery generation failed integrity checks: {target}')
        manifest = json.loads((target / 'manifest.json').read_text())
        return {'directory': str(target), 'reused': True, **manifest['summary']}
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.recovery-', dir=target.parent))
    commands = {}
    for table in ['TypeDef', 'MethodDef', 'AssemblyRef', 'TypeRef']:
        commands[table] = run(tool, assembly, ['--dump-table', table, '--json'], stage / f'{table}.json', timeout)
    commands['project'] = run(tool, assembly, ['-p', '-r', str(references), '-o', str(stage / 'project')],
                              stage / 'project.log', timeout)
    primary_errors = decompilation_errors(stage / 'project.stderr.txt')
    selected = 'project' if commands['project']['exitCode'] == 0 and not primary_errors else None
    overrides = []
    # An older compiler recovers the v11 method-group failures but can overflow
    # on unrelated types during whole-project output. Recover only named failures.
    if selected is None and primary_errors and fallback_tool is not None:
        directory = stage / 'type-fallback'
        directory.mkdir()
        types = sorted({error['member'].rsplit('.', 1)[0].rstrip('.') for error in primary_errors})
        definitions = json.loads((stage / 'TypeDef.json').read_text())['rows']
        for index, name in enumerate(types):
            file = directory / f'{index:04}.cs'
            metadata_name = metadata_type_name(name, definitions)
            result = run(fallback_tool, assembly, ['-r', str(references), '-t', metadata_name], file, timeout)
            has_stub = bool(re.search(r'DecompilerException|Error decompiling|//\s*System\.\w+Exception:', file.read_text(errors='replace')))
            overrides.append({'type': metadata_name, 'file': file.relative_to(stage).as_posix(), **result, 'hasErrorStub': has_stub,
                'failedTokens': sorted({e['token'] for e in primary_errors if e['member'].rsplit('.', 1)[0].rstrip('.') == name})})
        if all(entry['exitCode'] == 0 and not entry['hasErrorStub'] and (stage / entry['file']).stat().st_size > 0 for entry in overrides):
            selected = 'project'
    # IL retains method bodies whose high-level decompilation is incomplete.
    commands['il'] = run(tool, assembly, ['-il', '-o', str(stage / 'il')], stage / 'il.log', timeout)
    counts, namespaces, assembly_refs, type_refs = {}, {}, [], {}
    for table in ['TypeDef', 'MethodDef', 'AssemblyRef', 'TypeRef']:
        if commands[table]['exitCode'] == 0:
            value = json.loads((stage / f'{table}.json').read_text())
            counts[table] = value['rowCount']
            if table == 'TypeDef':
                namespaces = dict(sorted(Counter(row.get('Namespace') or '<global/nested>' for row in value['rows']).items()))
            elif table == 'AssemblyRef':
                assembly_refs = [{'name': row['Name'], 'version': row['Version'],
                                  'available': (references / (row['Name'] + '.dll')).is_file()} for row in value['rows']]
            elif table == 'TypeRef':
                type_refs = dict(sorted(Counter(row.get('Namespace') or '<global/nested>' for row in value['rows']).items()))
    files, diagnostics = inventory_tree(stage)
    # A successful process exit does not guarantee usable C#. ILSpy's project
    # layout uses one namespace directory and an arity-free type filename.
    # Only diagnostics in a whole type explicitly replaced by a clean fallback
    # are superseded. Unknown layouts/nested types fail conservatively.
    superseded_files = set()
    for override in overrides:
        if override['exitCode'] != 0 or override['hasErrorStub'] or not (stage / override['file']).stat().st_size:
            continue
        namespace, _, name = override['type'].rpartition('.')
        filename = re.sub(r'`\d+', '', name) + '.cs'
        superseded_files.add((Path('project') / namespace / filename).as_posix())
    unresolved_diagnostics = [d for d in diagnostics if d['file'] not in superseded_files]
    core_ok = all(commands[name]['exitCode'] == 0 for name in ['il', 'TypeDef', 'MethodDef', 'AssemblyRef', 'TypeRef'])
    # Primary error stubs remain preserved as evidence; every reported failed
    # type must have a successful, non-stub override before recovery is ready.
    status = 'recovered' if selected and core_ok and not unresolved_diagnostics else 'partial'
    summary = {'assembly': str(assembly), 'sourcePaths': matches, 'assemblySHA256': assembly_hash,
               'status': status, 'selectedProject': selected, 'metadataRows': counts,
               'sourceFiles': sum(f['path'].startswith((selected or 'project') + '/') and f['path'].endswith('.cs') for f in files),
               'primaryDecompilerErrors': len(primary_errors), 'decompilerDiagnosticCount': len(diagnostics),
               'unresolvedDecompilerDiagnosticCount': len(unresolved_diagnostics),
               'typeOverrideCount': sum(o['exitCode'] == 0 for o in overrides),
               'missingReferences': [r['name'] for r in assembly_refs if not r['available']]}
    manifest = {'identity': identity, 'capturedAtUTC': datetime.now(timezone.utc).isoformat(),
                'summary': summary, 'commands': commands, 'namespaces': namespaces,
                'referencedNamespaces': type_refs, 'assemblyReferences': assembly_refs,
                'decompilerDiagnostics': diagnostics, 'primaryDecompilerErrors': primary_errors,
                'unresolvedDecompilerDiagnostics': unresolved_diagnostics,
                'typeOverrides': overrides, 'files': files,
                'scope': 'Managed source/IL recovery only; not compilation, behavior verification, asset recovery or native translation.'}
    (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    stage.rename(target)
    return {'directory': str(target), 'reused': False, **summary}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assembly', type=Path, action='append', required=True)
    parser.add_argument('--references', type=Path, default=REPO / '.local/reverse/source/Koikatu_Data/Managed')
    parser.add_argument('--tool', type=Path, default=REPO / '.local/reverse/tools/ilspycmd')
    parser.add_argument('--fallback-tool', type=Path)
    parser.add_argument('--inventory', type=Path, default=REPO / '.local/reverse/inventory.json')
    parser.add_argument('--output', type=Path, default=REPO / '.local/reverse/managed-recovery')
    parser.add_argument('--timeout', type=int, default=1200)
    args = parser.parse_args()
    output = local_output(args.output)
    if args.timeout < 1 or not args.references.is_dir():
        parser.error('A positive timeout and existing reference directory are required')
    tool = args.tool.resolve()
    version = subprocess.run([str(tool), '--version'], check=True, capture_output=True, text=True).stdout.strip()
    fallback = args.fallback_tool.resolve() if args.fallback_tool else None
    fallback_version = subprocess.run([str(fallback), '--version'], check=True, capture_output=True, text=True).stdout.strip() if fallback else None
    known = json.loads(args.inventory.read_text())['assemblies']
    results = []
    for assembly in args.assembly:
        result = recover(assembly.resolve(), args.references.resolve(), tool, output, version, known, args.timeout,
                         fallback, fallback_version)
        results.append(result)
        print(json.dumps(result), flush=True)
        (output / 'index.json').write_text(json.dumps({'schemaVersion': VERSION, 'assemblies': results}, indent=2) + '\n')
    raise SystemExit(0 if all(r['status'] == 'recovered' for r in results) else 1)


if __name__ == '__main__':
    main()
