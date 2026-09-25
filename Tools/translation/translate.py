#!/usr/bin/env python3
"""Fail-closed Roslyn AST -> localized IR -> Swift translation.

Outputs contain local source identities and translated source. Keep recovered-game
outputs under .local/. No plug-in DLL is executed by this tool.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
TYPES = {"Void": "Void", "Float": "Float", "Double": "Double", "Int32": "Int32", "Bool": "Bool", "String": "String", "Vector3": "SIMD3<Float>", "Object": "any SourceAPIObject", "Transform": "any SourceAPITransform", "Space": "SourceAPISpace"}
LIFECYCLES = {name: "source" + name for name in ("Awake", "OnEnable", "Start", "Update", "FixedUpdate", "LateUpdate", "OnDisable", "OnDestroy")}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def swift_string(value: str) -> str:
    escapes = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\0": "\\0"}
    return '"' + ''.join(escapes.get(c, f"\\u{{{ord(c):x}}}" if ord(c) < 32 or ord(c) == 127 else c) for c in value) + '"'


def ident(name: str) -> str:
    # Roslyn already validated this as an identifier. Backticks preserve Swift keywords.
    if '`' in name or '\n' in name:
        raise ValueError("Invalid IR identifier")
    return f"`{name}`"


def build_frontend(build_dir: Path) -> Path:
    project = HERE / "frontend" / "Translation.csproj"
    build_dir = build_dir.resolve()
    build_dir.mkdir(parents=True, exist_ok=True)
    inputs = sorted((HERE / "frontend").iterdir())
    stamp = digest(b''.join(p.read_bytes() for p in inputs if p.is_file()))
    stamp_path = build_dir / "source.sha256"
    dll = build_dir / "bin" / "Translation.dll"
    if not dll.exists() or not stamp_path.exists() or stamp_path.read_text() != stamp:
        command = ["dotnet", "build", str(project), "--nologo", "-v:q", "-o", str(dll.parent), f"-p:BaseIntermediateOutputPath={build_dir / 'obj'}/"]
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        stamp_path.write_text(stamp)
    return dll


class Emitter:
    def __init__(self, ir: dict):
        self.ir = ir
        self.initializing = False
        self.callbacks = {m['name']: LIFECYCLES[m['lifecycle']] for m in ir['methods'] if m['lifecycle']}

    def expression(self, node: dict) -> str:
        k, name, value = node['kind'], node.get('name'), node.get('value')
        args = node.get('children') or []
        e = self.expression
        if k == 'literal':
            if isinstance(value, bool):
                return 'true' if value else 'false'
            if isinstance(value, str):
                return swift_string(value)
            if not isinstance(value, (float, int)) or not math.isfinite(value):
                raise ValueError("Invalid numeric IR literal")
            return f"{TYPES[node['type']]}({repr(value)})"
        if k == 'ref':
            return ident(name)
        if k == 'field':
            return 'self.' + ident(name)
        if k == 'member':
            return f"{e(args[0])}.{name}"
        if k == 'convert':
            return f"{TYPES[node['type']]}({e(args[0])})"
        if k == 'binary':
            return f"({e(args[0])} {name} {e(args[1])})"
        if k == 'unary':
            return f"({name}{e(args[0])})" if name != '+' else e(args[0])
        if k == 'conditional':
            return f"({e(args[0])} ? {e(args[1])} : {e(args[2])})"
        if k == 'space':
            return '.world' if name == 'World' else '.local'
        if k == 'call':
            target = 'Self.' if value else 'self.'
            return target + ident(self.callbacks.get(name, name)) + '(' + ', '.join(map(e, args)) + ')'
        if k == 'api':
            if name in ('transform', 'gameObject'):
                return f"{e(args[0])}.{name}" if args else name
            if name in ('position', 'localPosition', 'localScale'):
                return f"{e(args[0])}.{name}"
            if name in ('deltaTime', 'fixedDeltaTime'):
                return ("context." if self.initializing else "self.context.") + name
            if name in ('vector.zero', 'vector.one'):
                return f"SIMD3<Float>(repeating: {0 if name.endswith('zero') else 1})"
            if name == 'vector.init':
                return 'SIMD3<Float>(' + ', '.join(map(e, args)) + ')'
            if name.startswith('math.'):
                return 'SourceAPIMath.' + {'Lerp': 'lerp', 'Clamp01': 'clamp01', 'Sqrt': 'sqrt'}[name[5:]] + '(' + ', '.join(map(e, args)) + ')'
            if name.startswith('world.'):
                return ('context.world.' if self.initializing else 'self.context.world.') + {'Instantiate': 'instantiate', 'Destroy': 'destroy'}[name[6:]] + '(' + ', '.join(map(e, args)) + ')'
            if name == 'setActive':
                return f"{e(args[0])}.setActive({e(args[1])})"
            if name == 'translate':
                return f"{e(args[0])}.translate({e(args[1])}, relativeTo: {e(args[2])})"
        raise ValueError(f"Unsupported IR expression: {k}/{name}")

    def statement(self, node: dict, depth: int = 2) -> list[str]:
        args = node.get('children') or []
        kind = node['kind']
        line = lambda s: '    ' * depth + s
        if kind == 'empty':
            return []
        if kind == 'declarations':
            return [s for n in args for s in self.statement(n, depth)]
        if kind == 'block':
            return [line('do {')] + [s for n in args for s in self.statement(n, depth + 1)] + [line('}')]
        if kind == 'local':
            return [line(f"var {ident(node['name'])}: {TYPES[node['type']]} = {self.expression(args[0])}")]
        if kind == 'assign':
            return [line(f"{self.expression(args[0])} {node['name']} {self.expression(args[1])}")]
        if kind == 'expression':
            # C# permits ignoring a non-void call result.
            prefix = '' if args[0]['type'] == 'Void' else '_ = '
            return [line(prefix + self.expression(args[0]))]
        if kind == 'return':
            return [line('return' + (' ' + self.expression(args[0]) if args else ''))]
        if kind == 'if':
            lines = [line('if ' + self.expression(args[0]) + ' {')]
            lines += self.contents(args[1], depth + 1)
            if args[2]['kind'] != 'empty':
                lines += [line('} else {')] + self.contents(args[2], depth + 1)
            return lines + [line('}')]
        raise ValueError(f"Unsupported IR statement: {kind}")

    def contents(self, node: dict, depth: int) -> list[str]:
        children = node.get('children') or []
        return [line for child in children for line in self.statement(child, depth)] if node['kind'] == 'block' else self.statement(node, depth)

    def emit(self) -> str:
        component = self.ir['mode'] == 'component'
        out = ['// Generated from a reviewed bounded IR; unsupported input produces no Swift.', '// Source SHA-256: ' + self.ir['source']['sha256'], 'import Foundation', 'import Gameplay', '']
        out += ['public ' + ('final class ' if component else 'enum ') + self.ir['swiftName'] + (' : SourceTranslatedBehaviour {' if component else ' {')]
        out += ['    public static let sourceIdentityJSON = ' + swift_string(json.dumps(self.ir['identity'], ensure_ascii=False, sort_keys=True, separators=(',', ':')))]
        if component:
            for field in self.ir['fields']:
                out += [f"    public var {ident(field['name'])}: {TYPES[field['type']]}"]
            out += ['    public override init(context: SourceAPIContext, gameObject: any SourceAPIObject) {']
            self.initializing = True
            for field in self.ir['fields']:
                out += [f"        self.{ident(field['name'])} = {self.expression(field['initializer'])}"]
            self.initializing = False
            out += ['        super.init(context: context, gameObject: gameObject)', '    }']
        for method in self.ir['methods']:
            name = ident(self.callbacks.get(method['name'], method['name']))
            params = ', '.join(f"_ {ident(p['name'])}: {TYPES[p['type']]}" for p in method['parameters'])
            mods = 'override ' if method['lifecycle'] else 'static ' if method['static'] else ''
            returns = '' if method['returnType'] == 'Void' else ' -> ' + TYPES[method['returnType']]
            out += [f"    public {mods}func {name}({params}){returns} {{"]
            mutated = set()
            def find_mutations(node):
                children = node.get('children') or []
                if node['kind'] == 'assign' and children[0]['kind'] == 'ref':
                    mutated.add(children[0]['name'])
                elif node['kind'] == 'assign':
                    destination = children[0]
                    while destination['kind'] == 'member':
                        destination = destination['children'][0]
                    if destination['kind'] == 'ref':
                        mutated.add(destination['name'])
                for child in children:
                    find_mutations(child)
            find_mutations(method['body'])
            for parameter in method['parameters']:
                if parameter['name'] in mutated:
                    out += [f"        var {ident(parameter['name'])} = {ident(parameter['name'])}"]
            out += self.contents(method['body'], 2)
            out += ['    }']
        out += ['}', '']
        return '\n'.join(out)


def translate(source: Path, type_name: str, output: Path, *, methods: list[str] | None = None, component: bool = False, assembly: Path | None = None, plugin_guid: str | None = None, build_dir: Path | None = None) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    (output / 'Translated.swift').unlink(missing_ok=True)
    dll = build_frontend(build_dir or ROOT / '.local' / 'translation-tools')
    result = subprocess.run(['dotnet', str(dll), str(source.resolve()), type_name, 'component' if component else 'methods', ','.join(methods or [])], text=True, capture_output=True)
    if result.returncode not in (0, 2):
        raise RuntimeError(result.stderr or result.stdout)
    ir = json.loads(result.stdout)
    ir['bridgeSHA256'] = digest((ROOT / 'Packages/Engine/Sources/Gameplay/SourceTranslatedBehaviour.swift').read_bytes())
    ir['emitterSHA256'] = digest(Path(__file__).read_bytes())
    ir['identity'] = {'sourceSHA256': ir['source']['sha256'], 'type': type_name, 'symbols': [m['symbol'] for m in ir['methods']]}
    if assembly:
        ir['identity']['assemblyName'] = assembly.name
        ir['identity']['assemblySHA256'] = digest(assembly.read_bytes())
    declared_guid = (ir.get('plugin') or {}).get('guid')
    if declared_guid is not None:
        if plugin_guid is not None and plugin_guid != declared_guid:
            ir['status'] = 'rejected'
            ir['diagnostics'].append({'code':'PLUGIN_IDENTITY','message':'Supplied GUID differs from original BepInPlugin metadata.','line':0,'column':0,'syntax':'Metadata'})
        plugin_guid = declared_guid
    if plugin_guid is not None:
        ir['identity']['pluginGUID'] = plugin_guid  # Opaque; no case folding or rewriting.
    ir['swiftName'] += '_' + digest(json.dumps(ir['identity'], sort_keys=True, ensure_ascii=False).encode())[:8]
    swift_path = output / 'Translated.swift'
    if ir['status'] == 'ready':
        swift_path.write_text(Emitter(ir).emit())
        ir['swiftSHA256'] = digest(swift_path.read_bytes())
    else:
        swift_path.unlink(missing_ok=True)  # Never leave an older executable translation beside rejection evidence.
    (output / 'translation.json').write_text(json.dumps(ir, indent=2, ensure_ascii=False) + '\n')
    return ir


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('--type', required=True, dest='type_name')
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--component', action='store_true')
    mode.add_argument('--methods', nargs='+')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--assembly', type=Path)
    p.add_argument('--plugin-guid')
    args = p.parse_args()
    ir = translate(args.source, args.type_name, args.output, methods=args.methods, component=args.component, assembly=args.assembly, plugin_guid=args.plugin_guid)
    print(json.dumps({'status': ir['status'], 'methods': len(ir['methods']), 'substitutions': len(ir['substitutions']), 'diagnostics': ir['diagnostics'], 'output': str(args.output)}))
    return 0 if ir['status'] == 'ready' else 2


if __name__ == '__main__':
    sys.exit(main())
