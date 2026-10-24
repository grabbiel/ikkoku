#!/usr/bin/env python3
"""Bounded, metadata-only installed DLL inventory; never executes or packages DLLs.

The deterministic report separates discovered metadata and exact registered
adapter hashes from recovery, translation and runtime acceptance (not assessed).
Original metadata reports belong beneath the repository's ignored .local/.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, asdict
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

import native_adapters
from translate import build_frontend

ROOT = Path(__file__).resolve().parents[2]
MAX_REPORT_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class Limits:
    files: int = 1024
    file_bytes: int = 32 * 1024 * 1024
    total_bytes: int = 512 * 1024 * 1024
    entries: int = 20000
    depth: int = 16

    def validate(self):
        for name, maximum in [('files', 4096), ('file_bytes', 32 * 1024 * 1024),
                              ('total_bytes', 1024 * 1024 * 1024), ('entries', 100000), ('depth', 32)]:
            value = getattr(self, name)
            if type(value) is not int or not 1 <= value <= maximum:
                raise ValueError(f'{name} must be between 1 and {maximum}')


def encoded(report: dict) -> bytes:
    return (json.dumps(report, sort_keys=True, ensure_ascii=True, indent=2) + '\n').encode('utf-8')


def inspect_file(path: Path, helper: Path, byte_limit: int) -> dict:
    # Files, not captured pipes, keep a faulty helper from growing parent memory.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as error:
        result = subprocess.run(['dotnet', str(helper), '--inventory-assembly', str(path), str(byte_limit)],
                                stdout=output, stderr=error, timeout=30)
        if result.returncode:
            return {'classification': 'helper-error', 'entries': [],
                    'diagnostics': [f'Metadata helper exited {result.returncode}']}
        if output.tell() > MAX_REPORT_BYTES:
            return {'classification': 'helper-error', 'entries': [], 'diagnostics': ['Metadata report exceeds 16 MiB']}
        output.seek(0)
        return json.load(output)


def inventory(root: Path, helper: Path, limits: Limits = Limits()) -> dict:
    limits.validate()
    root = root.absolute()
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Input must be a directory, not a symbolic link')
    root = root.resolve()
    diagnostics = []
    paths = []
    visited = 0

    def diagnostic(path: str, code: str):
        diagnostics.append({'path': path, 'code': code})

    def walk(directory: Path, depth: int):
        nonlocal visited
        # Bound directory enumeration itself, before sorting or descending.
        children = []
        with os.scandir(directory) as iterator:
            for entry in iterator:
                visited += 1
                if visited > limits.entries:
                    raise ValueError(f'Directory entry limit exceeded ({limits.entries})')
                children.append(entry)
        for entry in sorted(children, key=lambda item: os.fsencode(item.name)):
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if entry.is_symlink():
                diagnostic(relative, 'symlink-skipped')
            elif entry.is_dir(follow_symlinks=False):
                if depth >= limits.depth:
                    diagnostic(relative, 'depth-limit')
                else:
                    walk(path, depth + 1)
            elif entry.is_file(follow_symlinks=False) and path.suffix.lower() == '.dll':
                if len(paths) >= limits.files:
                    raise ValueError(f'DLL file limit exceeded ({limits.files})')
                paths.append(path)

    walk(root, 0)
    assemblies = []
    total = 0
    charged = 0
    report_bytes = 0
    for path in sorted(paths, key=lambda p: os.fsencode(p.relative_to(root).as_posix())):
        relative = path.relative_to(root).as_posix()
        # Reject replacement with a symlink after traversal. Root containment is
        # checked again before the helper opens; this is an offline stable-tree
        # scanner, not a sandbox for a concurrently hostile filesystem.
        try:
            info = path.lstat()
        except OSError:
            diagnostic(relative, 'input-unreadable')
            continue
        if not stat.S_ISREG(info.st_mode) or not path.resolve().is_relative_to(root):
            diagnostic(relative, 'input-changed')
            continue
        allowed = min(limits.file_bytes, limits.total_bytes - charged)
        if info.st_size > allowed or allowed <= 0:
            diagnostic(relative, 'file-byte-limit' if info.st_size > limits.file_bytes else 'total-byte-limit')
            continue
        # Reserve even failed attempts so repeated malformed/time-out inputs
        # cannot bypass the aggregate I/O budget. A growing file is rejected by
        # the helper; at most one extra sentinel byte is read per attempted DLL.
        allowed = min(allowed, max(1, info.st_size))
        charged += allowed
        try:
            report = inspect_file(path, helper, allowed)
        except subprocess.TimeoutExpired:
            report = {'classification': 'helper-timeout', 'entries': [], 'diagnostics': ['Metadata helper exceeded 30 seconds']}
        except (ValueError, OSError) as error:
            report = {'classification': 'helper-error', 'entries': [], 'diagnostics': [type(error).__name__]}
        length = report.get('byteLength', 0)
        if type(length) is not int or not 0 <= length <= allowed:
            raise ValueError('Invalid helper byte count')
        total += length
        report['path'] = relative
        registered = native_adapters.REGISTRY.get(report.get('sourceSha256'))
        report['registeredAdapter'] = None if registered is None else {
            'adapterID': registered['adapterID'], 'type': registered['type'],
            'identity': registered['identity'], 'match': 'exact-source-sha256'}
        # No automatic recovery, translation, package publication or execution.
        report_bytes += len(encoded(report))
        if report_bytes > MAX_REPORT_BYTES:
            raise ValueError('Combined report exceeds 16 MiB')
        assemblies.append(report)
    return {'schemaVersion': 1, 'kind': 'ikkoku-plugin-dll-inventory',
            'scanner': {'id': 'ikkoku.plugin-dll-inventory', 'version': '1.0.0'},
            'limits': asdict(limits), 'assemblies': assemblies, 'diagnostics': diagnostics,
            'summary': {'dllFiles': len(paths), 'inspectedFiles': len(assemblies),
                        'snapshotBytes': total, 'chargedBytes': charged, 'pluginDeclarations': sum(len(a.get('entries', [])) for a in assemblies)},
            'assessment': {'metadataOnly': True, 'referencedAPIs': 'metadata references, not reachability or support',
                           'recovery': 'not-attempted', 'translation': 'not-attempted',
                           'hostIntegration': 'not-assessed', 'originalVerification': 'not-assessed'}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build-dir', type=Path, default=ROOT / '.local/plugin-inventory/frontend')
    for field in Limits.__dataclass_fields__:
        parser.add_argument('--max-' + field.replace('_', '-'), type=int, default=getattr(Limits(), field))
    args = parser.parse_args()
    # Like plugin.py's original DLL products, installed metadata stays private.
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / '.local').resolve()):
        parser.error('Inventory output must be beneath this checkout .local/')
    limits = Limits(**{field: getattr(args, 'max_' + field) for field in Limits.__dataclass_fields__})
    limits.validate()
    helper = build_frontend(args.build_dir)
    report = inventory(args.root, helper, limits)
    data = encoded(report)
    if len(data) > MAX_REPORT_BYTES:
        raise ValueError('Combined report exceeds 16 MiB')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        temporary.write(data)
        name = temporary.name
    try:
        os.replace(name, output)
    finally:
        Path(name).unlink(missing_ok=True)
    print(json.dumps(report['summary'], sort_keys=True))


if __name__ == '__main__':
    main()
