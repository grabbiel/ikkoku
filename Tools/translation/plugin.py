#!/usr/bin/env python3
"""Recover/translate one component and publish a native executable IR package.

DLL input is statically decompiled with ILSpy, never loaded or executed here.
An unsupported source produces diagnostics without a loadable manifest. Runtime
packages preserve the original BepInPlugin GUID/version and declared dependencies.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import translate
import native_adapters

ROOT = Path(__file__).resolve().parents[2]


def package(source: Path, type_name: str, output: Path, *, guid: str | None = None,
            version: str | None = None, name: str | None = None, references: Path | None = None,
            tool: Path | None = None, build_dir: Path | None = None, config: Path | None = None) -> dict:
    source, output = source.resolve(), output.resolve()
    if output.exists():
        raise ValueError('Choose a new output directory; installed package identities are immutable')
    if source.suffix.lower() not in ('.cs', '.dll') or not source.is_file() or source.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('Expected a bounded C# source or managed assembly')
    if (source.suffix.lower() == '.dll' or source.is_relative_to(ROOT / '.local')) and not output.is_relative_to(ROOT / '.local'):
        raise ValueError('Recovered original source and translations must remain under ignored .local')
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.plugin-stage-', dir=output.parent))
    try:
        adapter = native_adapters.identify(source)
        if adapter:
            row = adapter[1]
            if type_name != row['type'] or any(value is not None and value != row['identity'][key] for key,value in [('guid',guid),('name',name),('version',version)]):
                raise ValueError('Requested identity differs from the verified original adapter assembly')
            report = native_adapters.publish(source, stage, adapter, config)
            (stage/'conversion.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
            stage.rename(output)
            return report
        if config is not None:raise ValueError('Configuration requires a verified installed behavior adapter')
        assembly = source if source.suffix.lower() == '.dll' else None
        if assembly:
            executable = tool or ROOT / '.local/reverse/tools/ilspycmd'
            command = [str(executable), '--disable-updatecheck', '-r', str(references or source.parent), '-t', type_name, str(source)]
            result = subprocess.run(command, capture_output=True, timeout=180)
            if result.returncode or b'DecompilerException' in result.stdout or b'Error decompiling' in result.stderr:
                raise ValueError('ILSpy did not recover a complete selected type: ' + result.stderr.decode(errors='replace')[-2000:])
            source = stage / 'Recovered.cs'
            source.write_bytes(result.stdout)
        ir = translate.translate(source, type_name, stage / 'program', component=True, assembly=assembly,
                                 plugin_guid=guid, build_dir=build_dir)
        if assembly:
            ir['source']['path'] = str(output / 'Recovered.cs')
            (stage / 'program/translation.json').write_text(json.dumps(ir, indent=2, ensure_ascii=False) + '\n')
        declared = ir.get('plugin') or {}
        identity = {'guid': declared.get('guid', guid), 'version': declared.get('version', version), 'name': declared.get('name', name)}
        if ir['status'] != 'ready':
            report = {'status':'rejected', 'identity':identity, 'diagnostics':ir['diagnostics'], 'type':type_name}
        else:
            if any(not isinstance(value, str) or not value or len(value.encode()) > 1024 for value in identity.values()):
                raise ValueError('Plain MonoBehaviour components require explicit --guid, --version and --name')
            if (guid is not None and guid != identity['guid']) or (version is not None and version != identity['version']) or (name is not None and name != identity['name']):
                raise ValueError('Supplied metadata differs from original BepInPlugin metadata')
            program = stage / 'program/translation.json'
            manifest = {'schemaVersion':1, 'kind':'ikkoku-translated-plugin', 'identity':identity,
                        'processes':declared.get('processes', []), 'dependencies':declared.get('dependencies', []),
                        'incompatibilities':declared.get('incompatibilities', []),
                        'components':[{'type':type_name, 'program':{'file':'program/translation.json', 'sha256':hashlib.sha256(program.read_bytes()).hexdigest()}}]}
            (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
            report = {'status':'ready', 'identity':identity, 'type':type_name, 'sourceIdentity':ir['identity'],
                      'operations':sorted({row['operation'] for row in ir['substitutions']}),
                      'lifecycle':[method['lifecycle'] for method in ir['methods'] if method['lifecycle']]}
        (stage / 'conversion.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
        stage.rename(output)
        return report
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--type', required=True, dest='type_name')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--guid'); parser.add_argument('--name'); parser.add_argument('--version')
    parser.add_argument('--references', type=Path); parser.add_argument('--tool', type=Path)
    parser.add_argument('--config', type=Path, help='Original configuration for a verified native adapter')
    args = parser.parse_args()
    report = package(args.source, args.type_name, args.output, guid=args.guid, name=args.name, version=args.version,
                     references=args.references, tool=args.tool, config=args.config)
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if report['status'] == 'ready' else 2


if __name__ == '__main__':
    raise SystemExit(main())
