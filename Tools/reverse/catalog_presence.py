#!/usr/bin/env python3
"""Record which hair and clothes IDs the installed list catalogs have (#346).

The original reads each category as one dictionary merged from every installed
list/characustom bundle (LoadCharaFbxDataAsync, recovered ChaControl.Koikatu.cs
:8675-8700). An ID absent from all of them draws the category's default.
"Absent" is only true against the complete installed set. This tool therefore
refuses to write unless the transferred list bundles are exactly the bundles a
fresh VM listing names, with the same names, sizes and SHA-256s (the listing's
Get-FileHash values, taken in the same VM exec as the fetch).

Every hair and clothes category is written, an empty one as `[]`: the original
loads nothing for an empty category (work.Count == 0, :8679-8683).

#351: a top (105) or bra (107) row whose Sex column excludes one sex (:8702-8726:
Sex 3 is not drawn for a male, Sex 2 not for a female) is recorded under the
optional `sexLimited` key, written only when such a row exists, so a file from
tables without one keeps its v1 bytes.

#351 item 3: Sideloader keeps a card's ID when the mod its resolver record names
is missing but a vanilla row has that ID and the row's MainAB, with "chara/",
".unity3d", "<CategoryNo name>_" and "/" removed, is not an integer
(UniversalAutoResolver.ResolveStructure; otherwise the ID becomes 99999999).
Those IDs are recorded under the optional `nonNumericMainAB` key. With
--zipmods (the VM exec's zipmod listing), the installed mods' GUIDs are recorded
under the optional `installedMods` key. That listing names mods: it and the
library stay in .local.

It writes `catalog-presence.json` into a Maker library and records it in that
library's `library.json` as `catalogPresence`. Every other key and entry is
written back as read. Catalog metadata only: no asset or card is decoded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath

from maker_asset_library import source_file

ROOT = Path(__file__).resolve().parents[2]
LIST_DIRECTORY = 'list/characustom'
# ChaListDefine.CategoryNo of the hair and clothes kinds whose loads fall back
# to a default ID (SourceMakerLibrary.catalogDefaultIDs).
CATEGORIES = tuple(range(101, 113))
KIND = 'koikatsu-catalog-presence'
# LoadCharaFbxDataAsync checks the Sex column of these categories only (:8702),
# and excludes these values: 3 for a male (:8706), 2 for a female (:8710).
SEX_CHECKED = (105, 107)
SEX_LIMITING = (2, 3)
# ChaListDefine.CategoryNo names, which ResolveStructure strips as "<name>_".
CATEGORY_NAMES = {101: 'bo_hair_b', 102: 'bo_hair_f', 103: 'bo_hair_s', 104: 'bo_hair_o', 105: 'co_top', 106: 'co_bot',
                  107: 'co_bra', 108: 'co_shorts', 109: 'co_gloves', 110: 'co_panst', 111: 'co_socks', 112: 'co_shoes'}
INTEGER_TEXT = r'\s*[+-]?[0-9]+\s*'


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def installed_bundles(listing: dict) -> dict[str, tuple[int, str]]:
    """The listing's list/characustom bundles as {name: (bytes, sha256)}.

    The listing is `{"bundles": [{"path": "abdata/list/characustom/00.unity3d",
    "bytes": N, "sha256": "<hex>"}, ...]}`; the hash may be upper case (Get-FileHash).
    """
    result = {}
    for row in listing['bundles']:
        path = PurePosixPath(row['path'].replace('\\', '/'))
        if path.parent != PurePosixPath('abdata') / LIST_DIRECTORY or path.suffix != '.unity3d':
            continue
        if path.name in result:
            raise ValueError('Duplicate installed list bundle: ' + path.name)
        sha256 = str(row.get('sha256', '')).lower()
        if len(sha256) != 64 or any(c not in '0123456789abcdef' for c in sha256):
            raise ValueError('The listing has no SHA-256 for ' + path.name)
        result[path.name] = (int(row['bytes']), sha256)
    if not result:
        raise ValueError('The listing names no list/characustom bundle')
    return result


def require_complete(installed: dict[str, tuple[int, str]], transferred: dict[str, tuple[int, str]]):
    """Absence needs every installed list bundle: the same names, sizes and SHA-256s, no more, no fewer."""
    missing = sorted(set(installed) - set(transferred))
    extra = sorted(set(transferred) - set(installed))
    shared = set(installed) & set(transferred)
    resized = sorted(n for n in shared if installed[n][0] != transferred[n][0])
    rehashed = sorted(n for n in shared if installed[n][0] == transferred[n][0] and installed[n][1] != transferred[n][1])
    if missing or extra or resized or rehashed:
        raise ValueError(f'Transferred list bundles differ from the installed set: missing {missing}, '
                         f'not installed {extra}, size differs {resized}, sha256 differs {rehashed}')


def presence(tables) -> dict[str, list[int]]:
    """Sorted IDs of every supported category over every table, keyed by the
    category as text; a category no table has is `[]` (it loads nothing)."""
    ids: dict[int, set[int]] = {category: set() for category in CATEGORIES}
    for table in tables:
        if table['category'] in CATEGORIES:
            ids[table['category']].update(int(row['ID']) for row in table['rows'])
    return {str(category): sorted(ids[category]) for category in CATEGORIES}


def info_int(value) -> int:
    """ListInfoBase.GetInfoInt: int.TryParse of the text, else -1 (a missing key reads as text that fails)."""
    text = value if isinstance(value, str) else ''
    return int(text) if re.fullmatch(INTEGER_TEXT, text, flags=re.ASCII) else -1


def numbered_bundle(category: int, main_ab) -> bool:
    """ResolveStructure's test: MainAB (null when the row has none) with "chara/", ".unity3d", the category's
    "<name>_" and "/" removed, then int.TryParse."""
    if not isinstance(main_ab, str):
        return False
    text = main_ab.replace('chara/', '').replace('.unity3d', '').replace(CATEGORY_NAMES[category] + '_', '').replace('/', '')
    return re.fullmatch(INTEGER_TEXT, text, flags=re.ASCII) is not None and -2**31 <= int(text) < 2**31


def non_numeric_main_ab(tables) -> dict[str, list[int]]:
    """IDs per category whose row Sideloader keeps for a missing mod (branch "matching ID found"); a category
    without one is left out."""
    ids: dict[int, set[int]] = {}
    for table in tables:
        if table['category'] in CATEGORIES:
            for row in table['rows']:
                if not numbered_bundle(table['category'], row.get('MainAB')):
                    ids.setdefault(table['category'], set()).add(int(row['ID']))
    return {str(category): sorted(ids[category]) for category in sorted(ids)}


def installed_mods(listing: dict, listing_sha256: str) -> dict:
    """The installed zipmods' manifest GUIDs from the VM listing. Refused when the listing is incomplete: a
    traversal error, or an additional mods directory it did not read. A zipmod without a readable GUID is
    counted: Sideloader skips it too."""
    if listing.get('error'):
        raise ValueError('The zipmod listing is incomplete: ' + str(listing['error']))
    for line in listing.get('sideloaderAdditionalModsDirectory') or []:
        if line.split('=', 1)[1].strip():
            raise ValueError('Sideloader reads an additional mods directory the listing did not cover')
    rows = listing['zipmods']
    if isinstance(rows, dict) and set(rows) == {'value', 'Count'}:  # Windows PowerShell 5.1's wrapped array
        rows = rows['value']
    guids = sorted({row['guid'] for row in rows if isinstance(row.get('guid'), str) and row['guid']})
    return dict(listingSHA256=listing_sha256, zipmods=len(rows), guids=guids,
                withoutGUID=sum(1 for row in rows if not (isinstance(row.get('guid'), str) and row['guid'])))


def sex_limited(tables) -> dict[str, dict[str, list[int]]]:
    """The sex-limited rows of the checked categories, {"105": {"3": [ids]}}; a category or value without a
    row is left out. The original keeps one row per ID; an ID whose tables disagree on the limit is refused,
    since ChaListControl's rule for an ID that two tables share is not recovered."""
    limit: dict[int, dict[int, int]] = {category: {} for category in SEX_CHECKED}
    for table in tables:
        if table['category'] not in limit:
            continue
        for row in table['rows']:
            item, value = int(row['ID']), info_int(row.get('Sex'))
            value = value if value in SEX_LIMITING else -1
            if limit[table['category']].setdefault(item, value) != value:
                raise ValueError(f"Tables disagree on the Sex limit of {table['category']}:{item}")
    result = {}
    for category, rows in limit.items():
        values = {str(v): sorted(i for i, w in rows.items() if w == v) for v in SEX_LIMITING}
        values = {k: v for k, v in values.items() if v}
        if values:
            result[str(category)] = values
    return result


def document(tables, sources, listing_sha256: str, installed: int, mods: dict | None = None) -> dict:
    result = dict(schemaVersion=1, kind=KIND, installedListBundles=installed, listingSHA256=listing_sha256,
                  sources=sources, categories=presence(tables),
                  scope='Vanilla list/characustom catalogs of one installation; zipmod rows (Sideloader) are not included.')
    limited = sex_limited(tables)
    if limited:
        # Optional (#351): absent when no checked row is sex-limited, so such a file keeps its v1 bytes.
        result['sexLimited'] = limited
    kept = non_numeric_main_ab(tables)
    if kept:
        # Optional (#351 item 3), likewise absent when every row's bundle is numbered.
        result['nonNumericMainAB'] = kept
    if mods is not None:
        result['installedMods'] = mods
    return result


def encode(value: dict) -> bytes:
    """The presence file's bytes: sorted keys, no spaces, one newline."""
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


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
    parser.add_argument('--zipmods', type=Path, help="The same exec's zipmod listing (private: names mods)")
    args = parser.parse_args()
    if not args.library.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Derived game data must remain under ignored .local/')
    listing_bytes = args.listing.read_bytes()
    installed = installed_bundles(json.loads(listing_bytes))
    directory = args.shared / 'source/abdata' / LIST_DIRECTORY
    transferred = {p.name: (p.stat().st_size, digest(p.read_bytes())) for p in directory.glob('*.unity3d')}
    require_complete(installed, transferred)
    paths = [source_file(args.shared, f'{LIST_DIRECTORY}/{name}') for name in sorted(installed)]
    sources = [dict(path=f'{LIST_DIRECTORY}/{p.name}', sha256=digest(p.read_bytes()), bytes=p.stat().st_size) for p in paths]
    all_tables = [table for path in paths for table in list_tables(path)]
    mods = None
    if args.zipmods:
        zipmod_bytes = args.zipmods.read_bytes()
        mods = installed_mods(json.loads(zipmod_bytes), digest(zipmod_bytes))
    data = encode(document(all_tables, sources, digest(listing_bytes), len(installed), mods))
    attach(args.library, args.library.parent / 'catalog-presence.json', data)
    written = json.loads(data)
    counts = {k: len(v) for k, v in written['categories'].items()}
    limited = {f'{c}:{v}': len(ids) for c, values in written.get('sexLimited', {}).items() for v, ids in values.items()}
    kept = {k: len(v) for k, v in written.get('nonNumericMainAB', {}).items()}
    # Counts only: the GUIDs stay in the .local library.
    mods_written = written.get('installedMods') or {}
    mod_counts = {k: len(v) if k == 'guids' else v for k, v in mods_written.items() if k != 'listingSHA256'}
    print(json.dumps(dict(library=str(args.library), installedListBundles=len(installed), ids=counts, sexLimited=limited,
                          nonNumericMainAB=kept, installedMods=mod_counts, sha256=digest(data))))


if __name__ == '__main__':
    main()
