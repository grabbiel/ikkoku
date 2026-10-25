"""Shareable request validation and independent card-token preservation controls."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
from model_shape_input import canonical, parse
from analysis.card_contract import fixture_bytes, parse_card, mapping, unpack, Limits
import compare_original_model as model
import test_compare_original_model as authored


def edited_shapes(data, rows):
    card = parse_card(data); block = next(b for b in card.blocks if b['name'] == 'Custom')
    output = bytearray(data); offset = 0
    for domain in ('face', 'body', 'hair'):
        size, = struct.unpack_from('<i', block['raw'], offset); offset += 4
        raw = block['raw'][offset:offset + size]
        for row in rows:
            if row['domain'] != domain: continue
            token = mapping(unpack(raw, Limits()))['shapeValue' + domain.title()].value[row['index']]
            at = block['offset'] + offset + token.start
            if output[at] != 0xca: raise AssertionError('Authored fixture expects float32 tokens')
            output[at + 1:at + 5] = struct.pack('>f', row['value'])
        offset += size
    return bytes(output)


class ShapeInputTests(unittest.TestCase):
    def test_canonical_float32_input_and_committed_case(self):
        self.assertEqual(canonical(b'face\t3\t.75000\nbody\t0\t.25\n'), b'body\t0\t0.25\nface\t3\t0.75\n')
        self.assertEqual(parse(canonical(b'body\t0\t0.1\n'))[0]['value'], struct.unpack('<f', struct.pack('<f', .1))[0])
        data = Path(__file__).with_name('fixtures').joinpath('model-shapes-coupled.tsv').read_bytes()
        self.assertEqual(data, canonical(data)); self.assertEqual(len(parse(data)), 11)
    def test_reject_invalid_input(self):
        for data in [b'', b'\n', b'\xff', b'body\t00\t0.5', b'body\t44\t0', b'face\t52\t0', b'body\t0\tNaN',
                     b'body\t0\t-inf', b'body\t0\t-0.1', b'body\t0\t1.1', b'head\t0\t0.5',
                     b'body\t0\t.5\nbody\t0\t.25\n', b'x' * 16385]:
            with self.subTest(data=data[:40]), self.assertRaises(ValueError): canonical(data)
    def test_readback_requires_full_arrays_and_only_male_height_coercion(self):
        mode = dict(sex=0, requestedBodyValues=[.25]*44, actualBodyValues=[.25]*44,
                    requestedFaceValues=[.75]*52, actualFaceValues=[.75]*52)
        mode['actualBodyValues'][0] = .6
        self.assertEqual(model.shape_readback(mode)[0]['index'], 0)
        for key, value in [('actualBodyValues', [.6]*44), ('requestedFaceValues', [.75]), ('sex', 1)]:
            other = copy.deepcopy(mode); other[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): model.shape_readback(other)
        mode['actualFaceValues'][10] = float('nan')
        with self.assertRaises(ValueError): model.shape_readback(mode)
    def test_recorded_rows_normalize_float32_and_reject_mistyped_metadata(self):
        data = canonical(b'body\t0\t.1\nface\t3\t.3333333\n')
        rows = [dict(domain='body', index=0, value=.1), dict(domain='face', index=3, value=.3333333)]
        self.assertEqual(model.recorded_shape_rows(rows), parse(data))
        for key, value in [('domain', []), ('index', True), ('index', 44), ('value', True), ('value', '.1'), ('value', float('nan'))]:
            bad = copy.deepcopy(rows); bad[0][key] = value
            with self.subTest(key=key,value=value), self.assertRaises(ValueError): model.recorded_shape_rows(bad)

    def test_card_gate_preserves_unknown_blocks_plugins_and_unedited_tokens(self):
        data = fixture_bytes(b'opaque ABMX', current=True, legacy=True, footer=b'unknown footer')
        rows = parse(b'body\t0\t.25\nface\t0\t.75\n')
        before, after = parse_card(data), parse_card(edited_shapes(data, rows))
        mode = {f'actual{domain}Values': after.report['custom']['shapeValue' + domain] for domain in ('Body', 'Face')}
        self.assertIn('FixtureUnknown', model.shape_card_payload(before, after, mode, rows)['uneditedBlocks'])
        for old, new in [(b'preserve-face-field', b'changed--face-field'), (b'opaque ABMX', b'edited ABMX'),
                         (b'unknown footer', b'changed footer'), (b'preserved', b'changed!!')]:
            damaged = after.raw.replace(old, new); self.assertNotEqual(damaged, after.raw)
            with self.subTest(old=old), self.assertRaises(ValueError): model.shape_card_payload(before, parse_card(damaged), mode, rows)
        mode['actualBodyValues'][1] = .9
        with self.assertRaises(ValueError): model.shape_card_payload(before, after, mode, rows)

    def test_unchanged_shape_value_must_keep_its_original_raw_token(self):
        data = fixture_bytes(b'opaque ABMX'); before = parse_card(data)
        rows = parse(b'body\t1\t.25\nface\t1\t.75\n')
        changed = edited_shapes(data, rows)
        after = parse_card(changed)
        mode = {f'actual{domain}Values': after.report['custom']['shapeValue' + domain] for domain in ('Body', 'Face')}
        self.assertTrue(model.shape_card_payload(before, after, mode, rows)['unrequestedShapeTokensUnchanged'])
        # +0 and -0 compare equal numerically but alter an unrequested raw token.
        damaged = parse_card(edited_shapes(changed, [dict(domain='body', index=0, value=-0.0)]))
        with self.assertRaisesRegex(ValueError, 'unrequested body shape token'):
            model.shape_card_payload(before, damaged, mode, rows)


class ShapeCaptureTests(unittest.TestCase):
    """Reuse the authored triangle source/native pair, adding real card framing."""
    def setUp(self):
        fixture = authored.ModelComparisonTests(); fixture.setUp()
        self.__dict__.update(fixture.__dict__)
        self.frame['schemaVersion'] = 1
        self.baseline = self.folder / 'baseline'; self.baseline.mkdir()
        self.shape_data = canonical(b'body\t0\t.1\nface\t0\t.3333333\n')
        self.rows = parse(self.shape_data)
        raw = fixture_bytes(b'opaque ABMX', current=True, footer=b'preserved footer'); card = parse_card(raw)
        base = copy.deepcopy(self.frame)
        for domain in ('Body', 'Face'):
            values = card.report['custom']['shapeValue' + domain]
            base['neutralModel']['requested' + domain + 'Values'] = list(values)
            base['neutralModel']['actual' + domain + 'Values'] = list(values)
        self.frame = copy.deepcopy(base)
        for row in self.rows:
            for prefix in ('requested', 'actual'):
                self.frame['neutralModel'][prefix + row['domain'].title() + 'Values'][row['index']] = row['value']
        request = dict(file='model-shapes.tsv',sha256=hashlib.sha256(self.shape_data).hexdigest(),rows=self.rows,stage='saved arrays before LoadAsync')
        # Unity Single JSON may use short decimals instead of promoted doubles.
        request['rows'] = copy.deepcopy(request['rows'])
        request['rows'][0]['value'] = .1; request['rows'][1]['value'] = .3333333
        self.frame['neutralModel']['shapeRequest'] = request
        self.frame['neutralModel']['assemblySHA256'] = base['neutralModel']['assemblySHA256'] = 'a'*64
        for path in self.folder.iterdir():
            if path.is_file(): (self.baseline / path.name).write_bytes(path.read_bytes())
        (self.baseline / 'frame.json').write_text(json.dumps(base)); (self.baseline / 'card.png').write_bytes(raw)
        self.base_run = copy.deepcopy(self.run)
        self.run['processID'] = 101; self.run['modelShapes'] = {key:request[key] for key in ('file', 'sha256')}
        (self.folder / 'run.json').write_text(json.dumps(self.run))
        (self.folder / 'model-shapes.tsv').write_bytes(self.shape_data)
        raw = edited_shapes(raw, self.rows); (self.folder / 'card.png').write_bytes(raw)
        self.native['inputs']['cardSHA256'] = hashlib.sha256(raw).hexdigest()
        for domain in ('body', 'face'): self.native[domain + 'Values'] = self.frame['neutralModel']['actual' + domain.title() + 'Values']
        for folder in (self.folder, self.baseline):
            (folder / 'status.json').write_text(json.dumps(dict(error=None, unity='5.6.2f1', graphicsAPI='authored test', colorSpace='Linear')))
        self.write()
    def tearDown(self): self.temp.cleanup()
    def write(self): (self.folder / 'frame.json').write_text(json.dumps(self.frame))
    def test_shape_request_card_and_independent_baseline_pass(self):
        result = model.compare(self.folder, self.native, shape_baseline=self.baseline)
        self.assertTrue(result['gatePassed']); self.assertEqual(result['shapeRequest']['overrides'], self.rows)
    def test_shape_baseline_binds_loaded_head_metadata_and_validates_new_head(self):
        path=self.baseline/'frame.json';base=json.loads(path.read_text())
        base['neutralModel']['loadedHeadCatalog']={'MainData':'changed'}
        path.write_text(json.dumps(base))
        with self.assertRaisesRegex(ValueError,'loaded head context'):
            model.compare(self.folder,self.native,shape_baseline=self.baseline)
        # Even matching forged metadata on two head201 captures is rejected by
        # the baseline gate itself, independently of compare's first-frame check.
        for mode in (base['neutralModel'],self.frame['neutralModel']):
            mode.update(variant='female201',headID=201,requestedHeadID=201,loadedHeadCatalogID=201,
                        loadedHeadName='ct_head',loadedHeadCatalog=dict(model.HEAD201_CATALOG,MainData='wrong'))
        path.write_text(json.dumps(base));self.write()
        with self.assertRaisesRegex(ValueError,'exact source prefab'):
            model.shape_request_gate(self.folder,self.frame,self.baseline)
    def test_head201_shape_baseline_rejects_other_sex_before_card_payload(self):
        path=self.baseline/'frame.json';base=json.loads(path.read_text())
        for baseline_sex,current_sex in ((1,0),(0,1)):
            for mode,sex in ((base['neutralModel'],baseline_sex),(self.frame['neutralModel'],current_sex)):
                mode.update(variant='female201' if sex else 'male201',sex=sex,requestedSex=sex,
                            headID=201,requestedHeadID=201,loadedHeadCatalogID=201,loadedHeadName='ct_head',
                            loadedHeadCatalog=copy.deepcopy(model.HEAD201_CATALOG),exType=0,requestedExType=0)
            path.write_text(json.dumps(base));self.write()
            with patch.object(model,'shape_card_payload') as payload:
                with self.subTest(baselineSex=baseline_sex),self.assertRaisesRegex(ValueError,'source identity/context differs: variant'):
                    model.shape_request_gate(self.folder,self.frame,self.baseline)
                payload.assert_not_called()

    def test_same_producer_and_changed_player_context_fail(self):
        repeated = copy.deepcopy(self.run); repeated.pop('modelShapes')
        (self.baseline / 'run.json').write_text(json.dumps(repeated))
        with self.assertRaisesRegex(ValueError, 'same producer'): model.compare(self.folder, self.native, shape_baseline=self.baseline)
        (self.baseline / 'run.json').write_text(json.dumps(self.base_run))
        status = dict(error=None, unity='different source version', graphicsAPI='authored test', colorSpace='Linear')
        (self.baseline / 'status.json').write_text(json.dumps(status))
        with self.assertRaisesRegex(ValueError, 'context differs'): model.compare(self.folder, self.native, shape_baseline=self.baseline)

    def test_male00_baseline_rejects_other_sex_and_head_before_card_payload(self):
        path=self.baseline/'frame.json';base=json.loads(path.read_text())
        male00=dict(variant='male00',sex=0,requestedSex=0,headID=0,requestedHeadID=0,
                    loadedHeadCatalogID=0,loadedHeadName='ct_head',loadedHeadCatalog=copy.deepcopy(model.HEAD00_CATALOG),
                    exType=0,requestedExType=0,boneType=0,requestedBoneType=0)
        for other in (dict(variant='female00',sex=1,requestedSex=1),
                      dict(variant='male201',headID=201,requestedHeadID=201,loadedHeadCatalogID=201,
                           loadedHeadCatalog=copy.deepcopy(model.HEAD201_CATALOG))):
            for changed_baseline in (True,False):
                base['neutralModel'].update(male00);self.frame['neutralModel'].update(male00)
                (base['neutralModel'] if changed_baseline else self.frame['neutralModel']).update(other)
                path.write_text(json.dumps(base));self.write()
                with patch.object(model,'shape_card_payload') as payload:
                    with self.subTest(other=other['variant'],baseline=changed_baseline),self.assertRaisesRegex(ValueError,'context differs'):
                        model.shape_request_gate(self.folder,self.frame,self.baseline)
                    payload.assert_not_called()

    def test_corrected_shape_baseline_binds_type_and_table_before_card_payload(self):
        authored.ModelComparisonTests.bone1(self)
        path=self.baseline/'frame.json';base=json.loads(path.read_text())
        base['neutralModel'].update(loadedHeadName='ct_head',loadedHeadCatalog=copy.deepcopy(model.HEAD00_CATALOG))
        path.write_text(json.dumps(base))
        with patch.object(model,'shape_card_payload') as payload:
            with self.assertRaisesRegex(ValueError,'source identity/context differs: variant'):
                model.shape_request_gate(self.folder,self.frame,self.baseline)
            payload.assert_not_called()
        for key in ('variant','boneType','requestedBoneType','exType','requestedExType','bodyCorrection'):
            base['neutralModel'][key]=copy.deepcopy(self.frame['neutralModel'][key])
        path.write_text(json.dumps(base))
        with patch.object(model,'shape_card_payload') as payload:
            with self.assertRaisesRegex(ValueError,'Missing corrected body table'):
                model.shape_request_gate(self.folder,self.frame,self.baseline)
            payload.assert_not_called()
        data=(self.folder/'body-correction.bytes').read_bytes()
        (self.baseline/'body-correction.bytes').write_bytes(data)
        self.assertTrue(model.compare(self.folder,self.native,shape_baseline=self.baseline)['gatePassed'])
        changed=bytearray(data);struct.pack_into('<f',changed,4,-.5)
        (self.baseline/'body-correction.bytes').write_bytes(changed)
        base['neutralModel']['bodyCorrection']['sha256']=hashlib.sha256(changed).hexdigest();path.write_text(json.dumps(base))
        with patch.object(model,'shape_card_payload') as payload:
            with self.assertRaisesRegex(ValueError,'Shape baseline corrected body table differs'):
                model.shape_request_gate(self.folder,self.frame,self.baseline)
            payload.assert_not_called()

    def test_corrected_head201_baseline_requires_same_head_type_and_table_before_card_payload(self):
        authored.ModelComparisonTests.bone1(self,head_id=201)
        path=self.baseline/'frame.json';base=json.loads(path.read_text())
        for key in ('variant','sex','requestedSex','headID','requestedHeadID','loadedHeadCatalogID',
                    'boneType','requestedBoneType','exType','requestedExType','loadedHeadName',
                    'loadedHeadCatalog','bodyCorrection'):
            base['neutralModel'][key]=copy.deepcopy(self.frame['neutralModel'][key])
        data=(self.folder/'body-correction.bytes').read_bytes()
        (self.baseline/'body-correction.bytes').write_bytes(data);path.write_text(json.dumps(base))
        result=model.compare(self.folder,self.native,shape_baseline=self.baseline)
        self.assertTrue(result['gatePassed']);self.assertEqual(result['shapeRequest']['overrides'],self.rows)
        # The valid shaped card still passes the independent full-token gate.
        for other in (dict(variant='female201',boneType=0,requestedBoneType=0),
                      dict(variant='female00-bone1',headID=0,requestedHeadID=0,loadedHeadCatalogID=0,
                           loadedHeadCatalog=copy.deepcopy(model.HEAD00_CATALOG))):
            changed=copy.deepcopy(base);changed['neutralModel'].update(other);path.write_text(json.dumps(changed))
            with patch.object(model,'shape_card_payload') as payload:
                with self.subTest(other=other['variant']),self.assertRaisesRegex(ValueError,'context differs'):
                    model.shape_request_gate(self.folder,self.frame,self.baseline)
                payload.assert_not_called()
        path.write_text(json.dumps(base));(self.baseline/'body-correction.bytes').unlink()
        with patch.object(model,'shape_card_payload') as payload:
            with self.assertRaisesRegex(ValueError,'Missing corrected body table'):
                model.shape_request_gate(self.folder,self.frame,self.baseline)
            payload.assert_not_called()
        changed=bytearray(data);struct.pack_into('<f',changed,4,-.5)
        (self.baseline/'body-correction.bytes').write_bytes(changed)
        base['neutralModel']['bodyCorrection']['sha256']=hashlib.sha256(changed).hexdigest();path.write_text(json.dumps(base))
        with patch.object(model,'shape_card_payload') as payload:
            with self.assertRaisesRegex(ValueError,'Shape baseline corrected body table differs'):
                model.shape_request_gate(self.folder,self.frame,self.baseline)
            payload.assert_not_called()

    def test_corrected_male_baseline_rejects_other_sex_type_or_table_before_card_payload(self):
        authored.ModelComparisonTests.bone1(self, sex=0)
        path=self.baseline/'frame.json';base=json.loads(path.read_text())
        for key in ('variant','sex','requestedSex','boneType','requestedBoneType','exType','requestedExType',
                    'loadedHeadName','loadedHeadCatalog','bodyCorrection'):
            base['neutralModel'][key]=copy.deepcopy(self.frame['neutralModel'][key])
        base['neutralModel']['actualBodyValues'][0]=.6
        data=(self.folder/'body-correction.bytes').read_bytes()
        (self.baseline/'body-correction.bytes').write_bytes(data)
        for other in (dict(variant='female00-bone1',sex=1,requestedSex=1),
                      dict(variant='male00',boneType=0,requestedBoneType=0)):
            changed=copy.deepcopy(base);changed['neutralModel'].update(other);path.write_text(json.dumps(changed))
            with patch.object(model,'shape_card_payload') as payload:
                with self.subTest(other=other['variant']),self.assertRaisesRegex(ValueError,'source identity/context differs: variant'):
                    model.shape_request_gate(self.folder,self.frame,self.baseline)
                payload.assert_not_called()
        path.write_text(json.dumps(base));(self.baseline/'body-correction.bytes').unlink()
        with patch.object(model,'shape_card_payload') as payload:
            with self.assertRaisesRegex(ValueError,'Missing corrected body table'):
                model.shape_request_gate(self.folder,self.frame,self.baseline)
            payload.assert_not_called()
        changed=bytearray(data);struct.pack_into('<f',changed,4,-.5)
        (self.baseline/'body-correction.bytes').write_bytes(changed)
        base['neutralModel']['bodyCorrection']['sha256']=hashlib.sha256(changed).hexdigest();path.write_text(json.dumps(base))
        with patch.object(model,'shape_card_payload') as payload:
            with self.assertRaisesRegex(ValueError,'Shape baseline corrected body table differs'):
                model.shape_request_gate(self.folder,self.frame,self.baseline)
            payload.assert_not_called()

    def test_baseline_without_shape_request_rejects_retained_producer_input(self):
        request = self.frame['neutralModel']['shapeRequest']
        for marker in [dict(file=request['file'], sha256=request['sha256']), None]:
            retained = copy.deepcopy(self.base_run); retained['modelShapes'] = marker
            (self.baseline / 'run.json').write_text(json.dumps(retained))
            with self.subTest(marker=marker), self.assertRaisesRegex(ValueError, 'retains producer shape input'):
                model.compare(self.folder, self.native, shape_baseline=self.baseline)
        (self.baseline / 'run.json').write_text(json.dumps(self.base_run))
        (self.baseline / 'model-shapes.tsv').write_bytes(self.shape_data)
        with self.assertRaisesRegex(ValueError, 'retains producer shape input'):
            model.compare(self.folder, self.native, shape_baseline=self.baseline)

    def test_missing_baseline_input_hash_context_and_payload_fail(self):
        with self.assertRaises(ValueError): model.compare(self.folder, self.native)
        with self.assertRaises(ValueError): model.compare(self.folder, self.native, shape_baseline=self.folder)
        original = copy.deepcopy(self.frame)
        for key,value in [('requestedBodyValues',[.25]*44),('assemblySHA256','b'*64),('animators',[dict(changed=True)])]:
            self.frame = copy.deepcopy(original); self.frame['neutralModel'][key] = value; self.write()
            with self.subTest(key=key), self.assertRaises(ValueError): model.compare(self.folder, self.native, shape_baseline=self.baseline)
        self.frame = original; self.write()
        (self.folder / 'model-shapes.tsv').write_bytes(b'body\t0\t.5\n')
        with self.assertRaises(ValueError): model.compare(self.folder, self.native, shape_baseline=self.baseline)

if __name__ == '__main__': unittest.main()
