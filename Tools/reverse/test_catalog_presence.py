#!/usr/bin/env python3
"""Synthetic tests of the installed catalog presence writer (#346)."""
import json
from pathlib import Path
import tempfile
import unittest

from catalog_presence import KIND, attach, document, installed_bundles, presence, require_complete


H1, H2 = 'a' * 64, 'b' * 64


def table(category, *ids):
    return dict(name=f't{category}', category=category, rows=[dict(ID=str(i), MainData='p') for i in ids])


class CatalogPresenceTests(unittest.TestCase):
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
