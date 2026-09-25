"""Independent framing, pixel origin, integrity and identity checks for recipes."""
import json
from pathlib import Path
import tempfile
import unittest

import msgpack
from PIL import Image

from card_appearance_bindings import (digest,fixture_records,get_path,raw_texture,synthetic_card,
                                     verify_programs)
from card_contract import Cursor,parse_card


class CardAppearanceBindingTests(unittest.TestCase):
    def records(self,hair=(2,1)):
        contract={'domains':[{'id':'body','defaultValues':[.5]*44},{'id':'face','defaultValues':[.5]*52}]}
        return fixture_records(contract,list(hair))

    def test_raw_pixels_preserve_upright_rgba_order_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);path=root/'test.png'
            image=Image.new('RGBA',(2,2));pixels=[(255,0,0,255),(0,255,0,128),(0,0,255,64),(5,6,7,0)]
            image.putdata(pixels);image.save(path)
            output=raw_texture(path,digest(path.read_bytes()),root)
            raw=(root/output['file']).read_bytes()
            self.assertEqual(raw,bytes(c for pixel in pixels for c in pixel))
            self.assertEqual(output['sha256'],digest(raw))
            self.assertEqual((output['width'],output['height']),(2,2))

    def test_changed_png_and_oversized_texture_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);path=root/'test.png';Image.new('RGBA',(1,1)).save(path)
            with self.assertRaises(ValueError):raw_texture(path,'0'*64,root)
            Image.new('RGBA',(4097,1)).save(path)
            with self.assertRaises(ValueError):raw_texture(path,digest(path.read_bytes()),root)

    def test_bytecode_hash_and_revision_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);path=root/'shader.dxbc';path.write_bytes(b'verified-source-bytecode')
            sha=digest(path.read_bytes());rows=[{'shader':'source','file':path.name,'programSHA256':sha}]
            verify_programs(rows,root,{'source':sha})
            with self.assertRaises(ValueError):verify_programs(rows,root,{'source':'different-revision'})
            path.write_bytes(b'changed')
            with self.assertRaises(ValueError):verify_programs(rows,root,{'source':sha})

    def test_synthetic_source_cards_keep_framing_sex_shapes_and_explicit_clothes(self):
        for sex,hair in [(1,(2,1)),(0,(9,5))]:
            records=self.records(hair)
            parsed=parse_card(synthetic_card(records,records['clothes'],sex))
            self.assertEqual(parsed.report['parameter']['sex'],sex)
            self.assertEqual(parsed.report['custom']['shapeValueBody'],[.5]*44)
            self.assertEqual(parsed.report['custom']['shapeValueFace'],[.5]*52)
            self.assertEqual(parsed.report['facePngBytes'],0)
            blocks={b['name']:b for b in parsed.blocks}
            self.assertEqual(blocks['FixtureUnknown']['raw'],b'preserve-opaque-fixture-appearance\x00\xff')
            coordinates=msgpack.unpackb(blocks['Coordinate']['raw'],raw=False)
            self.assertEqual(len(coordinates),7)
            r=Cursor(coordinates[0]);clothes=msgpack.unpackb(r.take(r.number('<i')),raw=False)
            self.assertEqual([clothes['parts'][i]['id'] for i in [0,1,8]],[38,3,3])
            self.assertTrue(all(c['pattern']==0 for p in clothes['parts'] for c in p['colorInfo']))
            self.assertEqual(get_path(records,'hair.parts.0.id'),hair[0])
            self.assertEqual(get_path(records,'face.baseMakeup.paintId.1'),0)


if __name__=='__main__':unittest.main()
