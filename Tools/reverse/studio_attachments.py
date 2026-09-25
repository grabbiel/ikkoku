#!/usr/bin/env python3
"""Export original Studio attachment IDs; proprietary table output stays local."""
import argparse
import hashlib
import json
from pathlib import Path


def extract(bundle):
    import UnityPy
    if not bundle.is_file() or bundle.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('Expected a bounded Studio info bundle')
    tables = [o.read_typetree() for o in UnityPy.load(str(bundle)).objects if o.type.name == 'MonoBehaviour']
    matches = [t for t in tables if t.get('m_Name') == 'AccessoryPoint_' + bundle.stem]
    if len(matches) != 1:
        raise ValueError('Expected one matching AccessoryPoint table')
    points = []
    for row in matches[0]['list'][1:]:
        values = row['list']
        if len(values) < 4 or not values[2].startswith('a_n_') or not values[2].isascii():
            raise ValueError('Unsupported attachment reference key')
        points.append(dict(id=int(values[0]), group=int(values[1]), nodeName=values[2]))
    if len({p['id'] for p in points}) != len(points):
        raise ValueError('Duplicate attachment IDs')
    return dict(schemaVersion=1, sourceSHA256=hashlib.sha256(bundle.read_bytes()).hexdigest(), points=points)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(extract(args.bundle), indent=2) + '\n')


if __name__ == '__main__':
    main()
