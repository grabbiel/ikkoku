#!/usr/bin/env python3
"""Record which hair and clothes IDs the installed list catalogs have (#346).

The original reads each category as one dictionary merged from every installed
list/characustom bundle (LoadCharaFbxDataAsync, recovered ChaControl.Koikatu.cs
:8675-8700). An ID absent from all of them draws the category's default.
"Absent" is only true against the complete installed set. This tool therefore
refuses to write unless the transferred list bundles are exactly the bundles a
fresh VM listing names, with the same sizes and verified provenance.

It writes `catalog-presence.json` into a Maker library and records it in that
library's `library.json` as `catalogPresence`. Every other key and entry is
written back as read. Catalog metadata only: no asset or card is decoded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

from maker_asset_library import source_file

ROOT = Path(__file__).resolve().parents[2]
LIST_DIRECTORY = 'list/characustom'
# ChaListDefine.CategoryNo of the hair and clothes kinds whose loads fall back
# to a default ID (SourceMakerLibrary.catalogDefaultIDs).
CATEGORIES = tuple(range(101, 113))
KIND = 'koikatsu-catalog-presence'


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def installed_bundles(listing: dict) -> dict[str, int]:
    """The listing's list/characustom bundles as {name: bytes}.

    The listing is `{"bundles": [{"path": "abdata/list/characustom/00.unity3d", "bytes": N}, ...]}`.
    """
    result = {}
    for row in listing['bundles']:
        path = PurePosixPath(row['path'].replace('\\', '/'))
        if path.parent != PurePosixPath('abdata') / LIST_DIRECTORY or path.suffix != '.unity3d':
            continue
        if path.name in result:
            raise ValueError('Duplicate installed list bundle: ' + path.name)
        result[path.name] = int(row['bytes'])
    if not result:
        raise ValueError('The listing names no list/characustom bundle')
    return result


def require_complete(installed: dict[str, int], transferred: dict[str, int]):
    """Absence needs every installed list bundle: the same names and sizes, no more, no fewer."""
    missing = sorted(set(installed) - set(transferred))
    extra = sorted(set(transferred) - set(installed))
    resized = sorted(n for n in set(installed) & set(transferred) if installed[n] != transferred[n])
    if missing or extra or resized:
        raise ValueError(f'Transferred list bundles differ from the installed set: missing {missing}, '
                         f'not installed {extra}, size differs {resized}')


def presence(tables) -> dict[str, list[int]]:
    """Sorted IDs per supported category over every table, keyed by the category as text."""
    ids: dict[int, set[int]] = {}
    for table in tables:
        if table['category'] in CATEGORIES:
            ids.setdefault(table['category'], set()).update(int(row['ID']) for row in table['rows'])
    return {str(category): sorted(ids[category]) for category in sorted(ids)}


def document(tables, sources, listing_sha256: str, installed: int) -> dict:
    return dict(schemaVersion=1, kind=KIND, installedListBundles=installed, listingSHA256=listing_sha256,
                sources=sources, categories=presence(tables),
                scope='Vanilla list/characustom catalogs of one installation; zipmod rows (Sideloader) are not included.')


def attach(library_path: Path, presence_path: Path, data: bytes):
    """Write the presence file and record it in library.json; the rest of the index is unchanged."""
    if presence_path.parent.resolve() != library_path.parent.resolve():
        raise ValueError('The presence file must sit beside library.json')
    index = json.loads(library_path.read_text())
    presence_path.write_bytes(data)
    index['catalogPresence'] = dict(file=presence_path.name, sha256=digest(data))
    library_path.write_text(json.dumps(index, indent=2, allow_nan=False) + '\n')


def main():
    from maker_coverage import tables as list_tables  # UnityPy; only for a real run
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared', type=Path, default=ROOT / '.local/reverse/rigs')
    parser.add_argument('--library', type=Path, required=True, help='The Maker library.json to record the presence in')
    parser.add_argument('--listing', type=Path, required=True, help='Fresh VM listing of the installed list bundles (JSON)')
    args = parser.parse_args()
    if not args.library.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Derived game data must remain under ignored .local/')
    listing_bytes = args.listing.read_bytes()
    installed = installed_bundles(json.loads(listing_bytes))
    directory = args.shared / 'source/abdata' / LIST_DIRECTORY
    transferred = {p.name: p.stat().st_size for p in directory.glob('*.unity3d')}
    require_complete(installed, transferred)
    paths = [source_file(args.shared, f'{LIST_DIRECTORY}/{name}') for name in sorted(installed)]
    sources = [dict(path=f'{LIST_DIRECTORY}/{p.name}', sha256=digest(p.read_bytes()), bytes=p.stat().st_size) for p in paths]
    all_tables = [table for path in paths for table in list_tables(path)]
    data = (json.dumps(document(all_tables, sources, digest(listing_bytes), len(installed)), sort_keys=True,
                       separators=(',', ':')) + '\n').encode()
    attach(args.library, args.library.parent / 'catalog-presence.json', data)
    counts = {k: len(v) for k, v in json.loads(data)['categories'].items()}
    print(json.dumps(dict(library=str(args.library), installedListBundles=len(installed), ids=counts, sha256=digest(data))))


if __name__ == '__main__':
    main()
