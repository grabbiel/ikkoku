#!/usr/bin/env python3
"""Synthetic tests of the installed catalog presence writer (#346)."""
import json
from pathlib import Path
import tempfile
import unittest

from catalog_presence import (CATEGORY_NAMES, KIND, attach, document, encode, info_int, installed_bundles, installed_mods,
                              non_numeric_main_ab, numbered_bundle, presence, require_complete, sex_limited)


H1, H2 = 'a' * 64, 'b' * 64


def table(category, *ids, sex=None, bundles=None):
    """Rows with a numbered MainAB (or `bundles[id]`, None for no MainAB) and without a Sex column (or with
    `sex[id]` as its text)."""
    rows = []
    for i in ids:
        row = dict(ID=str(i), MainData='p', MainAB=f'chara/{CATEGORY_NAMES.get(category, "x")}_{i:02d}.unity3d')
        if bundles and i in bundles:
            if bundles[i] is None:
                del row['MainAB']
            else:
                row['MainAB'] = bundles[i]
        if sex and i in sex:
            row['Sex'] = sex[i]
        rows.append(row)
    return dict(name=f't{category}', category=category, rows=rows)


# The bytes the #346 writer (before #351) wrote for the byte-identity test's tables and V1_SOURCES.
V1_BYTES = (b'{"categories":{"101":[0,2],"102":[],"103":[],"104":[],"105":[0,3],"106":[],"107":[0],"108":[],"109":[],'
            b'"110":[],"111":[],"112":[]},"installedListBundles":1,"kind":"koikatsu-catalog-presence","listingSHA256":"'
            + b'c' * 64 + b'","schemaVersion":1,"scope":"Vanilla list/characustom catalogs of one installation; zipmod rows '
            b'(Sideloader) are not included.","sources":[{"bytes":35000,"path":"list/characustom/00.unity3d","sha256":"'
            + b'a' * 64 + b'"}]}\n')
V1_SOURCES = [dict(path='list/characustom/00.unity3d', sha256='a' * 64, bytes=35000)]


class CatalogPresenceTests(unittest.TestCase):
    def test_a_file_without_sex_limited_rows_keeps_its_v1_bytes(self):
        # No Sex column, neutral values (0, 1, 99), text that is no integer, and
        # limiting values outside 105/107: none of them adds the optional key.
        for sex in [None, {0: '0', 3: '1'}, {0: '99', 3: ''}, {0: '3.0', 3: 'x'}]:
            tables = [table(101, 0, 2, sex={0: '3', 2: '2'}), table(105, 0, 3, sex=sex), table(107, 0, sex=sex)]
            with self.subTest(sex=sex):
                self.assertEqual(encode(document(tables, V1_SOURCES, 'c' * 64, 1)), V1_BYTES)

    def test_sex_limited_rows_of_tops_and_bras(self):
        tables = [table(105, 0, 3, 7, sex={3: '3', 7: ' 2 '}), table(105, 9, sex={9: '3'}), table(107, 0, 4, sex={4: '2'}),
                  table(106, 5, sex={5: '3'})]
        self.assertEqual(sex_limited(tables), {'105': {'2': [7], '3': [3, 9]}, '107': {'2': [4]}})
        written = json.loads(encode(document(tables, [], '0' * 64, 1)))
        self.assertEqual(written['sexLimited'], {'105': {'2': [7], '3': [3, 9]}, '107': {'2': [4]}})
        self.assertEqual(written['schemaVersion'], 1)
        # A category or value without a limited row is left out.
        self.assertEqual(sex_limited([table(107, 4, sex={4: '3'})]), {'107': {'3': [4]}})
        self.assertEqual(sex_limited([]), {})

    def test_sex_text_is_read_as_get_info_int_does(self):
        # int.TryParse: surrounding white space and a sign are accepted; anything else is -1.
        for text, value in [('3', 3), (' 2 ', 2), ('+3', 3), ('-1', -1), ('3.0', -1), ('1_0', -1), ('', -1), (None, -1),
                            ('\u0663', -1)]:
            with self.subTest(text=text):
                self.assertEqual(info_int(text), value)

    def test_bundle_numbers_are_tested_as_resolve_structure_does(self):
        for category, main_ab, numbered in [(101, 'chara/bo_hair_b_00.unity3d', True), (105, 'chara/co_top_13.unity3d', True),
                                            (105, 'chara/co_top_ 7 .unity3d', True), (105, 'chara/mm_base.unity3d', False),
                                            # Only the row's own category name is removed.
                                            (106, 'chara/co_top_00.unity3d', False), (105, 'chara/co_top_.unity3d', False),
                                            (105, 'chara/sub/co_top_05.unity3d', False), (105, 'chara/co_top_2147483648.unity3d', False),
                                            (105, None, False), (112, 'chara/co_shoes_01.unity3d', True)]:
            with self.subTest(category=category, main_ab=main_ab):
                self.assertEqual(numbered_bundle(category, main_ab), numbered)

    def test_rows_sideloader_keeps_for_a_missing_mod(self):
        tables = [table(101, 0, 5, bundles={5: 'chara/mm_base.unity3d'}), table(105, 0, 1, bundles={1: None}),
                  table(106, 0), table(121, 3, bundles={3: 'chara/x.unity3d'})]
        self.assertEqual(non_numeric_main_ab(tables), {'101': [5], '105': [1]})
        written = json.loads(encode(document(tables, [], '0' * 64, 1)))
        self.assertEqual(written['nonNumericMainAB'], {'101': [5], '105': [1]})
        self.assertNotIn('nonNumericMainAB', json.loads(encode(document([table(101, 0)], [], '0' * 64, 1))))

    def test_installed_mods_are_read_from_a_complete_listing(self):
        rows = [dict(path='mods/a.zipmod', guid='b.mod'), dict(path='mods/b.zipmod', guid='a.mod'),
                dict(path='mods/c.zipmod', guid='a.mod'), dict(path='mods/d.zip', guid=None, error='no manifest.xml'),
                dict(path='mods/e.zipmod', guid='')]
        expected = dict(listingSHA256='f' * 64, zipmods=5, guids=['a.mod', 'b.mod'], withoutGUID=2)
        self.assertEqual(installed_mods(dict(zipmods=rows), 'f' * 64), expected)
        self.assertEqual(installed_mods(dict(zipmods=dict(value=rows, Count=5)), 'f' * 64), expected)
        self.assertEqual(installed_mods(dict(zipmods=rows, sideloaderAdditionalModsDirectory=['AdditionalModsDirectory = ']),
                                        'f' * 64), expected)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            installed_mods(dict(zipmods=rows, error='zipmod listing exceeded its bound'), 'f' * 64)
        with self.assertRaisesRegex(ValueError, 'additional mods directory'):
            installed_mods(dict(zipmods=rows, sideloaderAdditionalModsDirectory=['AdditionalModsDirectory = D:\\mods']), 'f' * 64)
        written = json.loads(encode(document([table(101, 0)], [], '0' * 64, 1, expected)))
        self.assertEqual(written['installedMods'], expected)
        self.assertNotIn('installedMods', json.loads(encode(document([table(101, 0)], [], '0' * 64, 1))))

    def test_tables_that_disagree_on_a_limit_are_refused(self):
        self.assertEqual(sex_limited([table(105, 7, sex={7: '3'}), table(105, 7, sex={7: '3'})]), {'105': {'3': [7]}})
        with self.assertRaisesRegex(ValueError, '105:7'):
            sex_limited([table(105, 7, sex={7: '3'}), table(105, 7)])

    def test_ids_merge_across_tables_and_every_category_is_written(self):
        tables = [table(101, 0, 2, 9), table(101, 28, 2), table(102, 1), table(112, 0, 3), table(121, 5), table(100, 0)]
        expected = {str(c): [] for c in range(101, 113)}
        expected.update({'101': [0, 2, 9, 28], '102': [1], '112': [0, 3]})
        # A category no installed table has is [] (it loads nothing), never left out.
        self.assertEqual(presence(tables), expected)
        self.assertEqual(list(presence([])), [str(c) for c in range(101, 113)])

    def test_listing_reads_only_list_bundles(self):
        listing = dict(bundles=[dict(path='abdata/list/characustom/00.unity3d', bytes=35000, sha256=H1.upper()),
                                dict(path='abdata\\list\\characustom\\06.unity3d', bytes=5230, sha256=H2),
                                dict(path='abdata/list/characustom/sub/07.unity3d', bytes=1),
                                dict(path='abdata/chara/bo_hair_b_06.unity3d', bytes=2),
                                dict(path='abdata/list/characustom/00.manifest', bytes=3)])
        # Get-FileHash prints upper-case hex; it is compared in lower case.
        self.assertEqual(installed_bundles(listing), {'00.unity3d': (35000, H1), '06.unity3d': (5230, H2)})
        with self.assertRaisesRegex(ValueError, 'no list'):
            installed_bundles(dict(bundles=[dict(path='abdata/chara/x.unity3d', bytes=1)]))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            installed_bundles(dict(bundles=[dict(path='abdata/list/characustom/00.unity3d', bytes=1, sha256=H1)] * 2))
        for bad in [None, 'x' * 64, H1[:63]]:
            row = dict(path='abdata/list/characustom/00.unity3d', bytes=1)
            if bad is not None:
                row['sha256'] = bad
            with self.assertRaisesRegex(ValueError, 'no SHA-256'):
                installed_bundles(dict(bundles=[row]))

    def test_absence_needs_the_complete_installed_set(self):
        installed = {'00.unity3d': (35000, H1), '06.unity3d': (5230, H2)}
        require_complete(installed, dict(installed))
        for transferred, reason in [({'00.unity3d': (35000, H1)}, "missing \\['06.unity3d'\\]"),
                                    ({**installed, '99.unity3d': (1, H1)}, "not installed \\['99.unity3d'\\]"),
                                    ({'00.unity3d': (35000, H1), '06.unity3d': (1, H2)}, "size differs \\['06.unity3d'\\]"),
                                    # Same name and size, other bytes: a different bundle.
                                    ({'00.unity3d': (35000, H1), '06.unity3d': (5230, H1)}, "sha256 differs \\['06.unity3d'\\]")]:
            with self.assertRaisesRegex(ValueError, reason):
                require_complete(installed, transferred)

    def test_attach_records_the_file_and_keeps_the_index(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); library = root / 'library.json'
            index = dict(schemaVersion=1, entries=[dict(category=101, id=0, name='a')], assemblies=[dict(sex=1)])
            library.write_text(json.dumps(index, indent=2) + '\n')
            data = (json.dumps(document([table(101, 0)], [], '0' * 64, 1), sort_keys=True) + '\n').encode()
            attach(library, root / 'catalog-presence.json', data)
            updated = json.loads(library.read_text())
            self.assertEqual({k: v for k, v in updated.items() if k != 'catalogPresence'}, index)
            self.assertEqual(updated['catalogPresence']['file'], 'catalog-presence.json')
            written = json.loads((root / 'catalog-presence.json').read_bytes())
            self.assertEqual((written['schemaVersion'], written['kind']), (1, KIND))
            self.assertEqual(written['categories']['101'], [0])
            self.assertEqual(written['categories']['112'], [])
            with self.assertRaisesRegex(ValueError, 'beside'):
                attach(library, root / 'other' / 'catalog-presence.json', data)


if __name__ == '__main__':
    unittest.main()
