#!/usr/bin/env python3
"""Audit native original-scene edits with the independent recovered Python reader.

Reads byte containers only; never decodes or displays embedded scene/card images.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import msgpack
from studio_scene_contract import Reader, inspect_scene
from card_contract import Limits, png_end, parse_card

ROOT = Path(__file__).resolve().parents[3]


def f32(value): return struct.unpack('<f', struct.pack('<f', value))[0]
def sha(data): return hashlib.sha256(data).hexdigest()


class CardCollector(Reader):
    def __init__(self, data): super().__init__(data); self.cards = {}
    def card(self):
        start = self.pos; result = super().card()
        self.cards[result['sha256']] = self.data[start:self.pos]
        return result


def collect(data):
    reader = CardCollector(data); reader.pos = png_end(data, Limits())
    assert reader.s() == '1.0.4.2'
    reader.map(reader.obj)
    return reader.cards


def objects(roots):
    result = {}
    def visit(value):
        result[value['key']] = value
        for child in value.get('children', []): visit(child)
        for children in value.get('accessories', {}).values():
            for child in children: visit(child)
    for root in roots.values(): visit(root)
    return result


def custom_records(block):
    records = []; pos = 0
    for _ in range(3):
        length = struct.unpack_from('<i', block, pos)[0]; pos += 4
        records.append(block[pos:pos+length]); pos += length
    assert pos == len(block)
    return records


def verify(directory):
    cases = []
    for metadata in sorted(directory.glob('*.roundtrip.json')):
        row = json.loads(metadata.read_text())
        original = Path(row['input']).read_bytes(); edited = Path(row['output']).read_bytes()
        assert sha(original) == row['sourceSHA256'] and sha(edited) == row['editedSHA256']
        before = inspect_scene(original); after = inspect_scene(edited)
        assert before['trailingSHA256'] == after['trailingSHA256']
        assert original[:png_end(original, Limits())] == edited[:png_end(edited, Limits())]
        expected = copy.deepcopy(before); expected_objects = objects(expected['roots']); actual_objects = objects(after['roots'])
        expected_objects[row['objectKey']]['transform'] = dict(position=[1,2,-3], rotation=[11,-22,33], scale=list(map(f32, [.9,1.1,-1])))
        camera = list(map(f32,[1.5,2.5,-3.5,10,20,30,.2,-.3,-4.5,42.5]))
        for index in [0,1,10]: expected['settings']['cameras'][index] = camera
        card_key = row['cardObject']; preserved_blocks = 0
        if card_key is not None:
            old = expected_objects[card_key]; new = actual_objects[card_key]
            cards_before = collect(original); cards_after = collect(edited)
            a = parse_card(cards_before[old['card']['sha256']]); b = parse_card(cards_after[new['card']['sha256']])
            assert a.footer == b.footer
            assert a.report['facePngSHA256'] == b.report['facePngSHA256']
            assert [(v['name'],v['version']) for v in a.blocks] == [(v['name'],v['version']) for v in b.blocks]
            for x,y in zip(a.blocks,b.blocks):
                if x['name'] != 'Custom':
                    assert x['raw'] == y['raw']; preserved_blocks += 1
                else:
                    xx,yy = custom_records(x['raw']),custom_records(y['raw'])
                    assert xx[0] == yy[0] and xx[2] == yy[2]
                    body_a = msgpack.unpackb(xx[1],raw=False,strict_map_key=False)
                    body_b = msgpack.unpackb(yy[1],raw=False,strict_map_key=False)
                    body_a['shapeValueBody'] = list(map(f32,row['expectedBody']))
                    assert body_a == body_b
            old['card'] = new['card']
            old.update(enableFK=True,enableIK=False,activeFK=[True]*7,activeIK=[False]*5)
        assert expected['roots'] == after['roots']
        assert expected['settings'] == after['settings']
        cases.append(dict(file=Path(row['input']).name, sourceSHA256=sha(original), editedSHA256=sha(edited),
                          objectTransform=True, currentCameraAndTwoSlots=True, cardAndKinematicEdit=card_key is not None,
                          exactOtherCardBlocks=preserved_blocks, exactSceneTrailer=True, exactThumbnail=True))
    assert cases, 'No native roundtrip evidence found'
    report = dict(schemaVersion=1, cases=cases, passed=True, scenes=len(cases),
                  cards=sum(c['cardAndKinematicEdit'] for c in cases), originalImagePixelsDecoded=False)
    (directory/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,default=ROOT/'.local/reverse/studio-edited')
    result = verify(parser.parse_args().directory)
    print(json.dumps({k:v for k,v in result.items() if k!='cases'}))
