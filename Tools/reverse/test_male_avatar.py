"""Bounds and identity checks for the original male assembly extraction."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import msgpack
from male_avatar import custom_card, selection, source_bundle, evidence
from types import SimpleNamespace


class MaleAvatarTests(unittest.TestCase):
    def card(self, sex=0, ex_type=0, head=0):
        data = []
        for item in ({'headId': head}, {}, {}):
            raw = msgpack.packb(item)
            data.append(struct.pack('<i', len(raw)) + raw)
        return SimpleNamespace(blocks=[{'name':'Parameter','raw':msgpack.packb({'sex':sex,'exType':ex_type})},
                                      {'name':'Custom','raw':b''.join(data)}], report={'test':True})

    def test_normal_male_uses_shared_head00(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'card';path.write_bytes(b'unrendered')
            with patch('male_avatar.parse_card',return_value=self.card()):
                custom, report=custom_card(path)
                self.assertEqual(custom['face']['headId'],0)
                self.assertEqual(report,{'test':True})

    def test_special_male_and_wrong_sex_or_head_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'card';path.write_bytes(b'unrendered')
            for parsed in [self.card(sex=1),self.card(ex_type=1),self.card(head=1)]:
                with self.subTest(parsed=parsed),patch('male_avatar.parse_card',return_value=parsed):
                    with self.assertRaises(ValueError):custom_card(path)

    def test_catalog_exact_id_rejects_missing_duplicate_and_bad_columns(self):
        table={'lstKey':['ID','MainData'],'dictList':{'x':['9','p_cf_hair_b_33']}}
        self.assertEqual(selection(table,9)['MainData'],'p_cf_hair_b_33')
        with self.assertRaises(ValueError):selection(table,8)
        table['dictList']['y']=['9','different']
        with self.assertRaises(ValueError):selection(table,9)
        del table['dictList']['y'];table['dictList']['x'].append('extra')
        with self.assertRaises(ValueError):selection(table,9)

    def test_source_bundle_is_hash_verified_before_decode(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);path=root/'source/abdata/chara/oo_base.unity3d'
            path.parent.mkdir(parents=True);path.write_bytes(b'original')
            path.with_name(path.name+'.provenance.json').write_text(json.dumps(evidence(path)))
            self.assertEqual(source_bundle(root,'oo_base'),path)
            path.write_bytes(b'changed')
            with self.assertRaises(ValueError):source_bundle(root,'oo_base')


if __name__=='__main__':unittest.main()
