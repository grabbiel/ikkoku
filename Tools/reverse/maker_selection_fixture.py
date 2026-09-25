#!/usr/bin/env python3
"""Generate fully clothed, source-format Maker selection fixtures without thumbnails.

The only image prefix is a generated blank PNG. Original card images are never
decoded. Recovered geometry and all generated artifacts remain in ignored .local.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import msgpack
from card_appearance_bindings import fixture_records, pack, length
from analysis.card_contract import blank_png, dotnet_string, MAGIC, VERSIONS, parse_card

ROOT = Path(__file__).resolve().parents[2]


def card_bytes(records, sex, *, moved=False, coordinate_makeup=False):
    records = copy.deepcopy(records)
    records['body']['fixtureOpaque99'] = {f'future{i}': msgpack.ExtType(42, bytes([i, 255-i])) for i in range(99)}
    moves = [[1.5, -2.25, 3.75], [12, 23, 34], [1.1, .9, 1.2]] if moved else [[0, 0, 0], [0, 0, 0], [1, 1, 1]]
    accessory = dict(version='0.0.2', parts=[dict(type=123, id=0, parentKey='',
        addMove=[2, 3, [*moves, *([[9, 8, 7], [10, 20, 30], [2, 3, 4]] if moved else [[0, 0, 0], [0, 0, 0], [1, 1, 1]])]],
        color=[[.25, .12, .08, 1], [.6, .7, .8, .45], [1, 1, 1, 1], [1, 1, 1, 1]])])
    makeup = copy.deepcopy(records['face']['baseMakeup'])
    coord = length(pack(records['clothes'])) + length(pack(accessory)) + bytes([coordinate_makeup]) + length(pack(makeup))
    info = dict(ModID='fixture.unrelated', Property='future.UnknownIdentity', Slot=99, LocalSlot=900001,
                CategoryNo=777, Opaque=msgpack.ExtType(77, b'identity-preserved'))
    plugins = {'com.bepis.sideloader.universalautoresolver': [0, {'info': [pack(info)]}],
               'fixture.future.plugin': [99, {'opaque': bytes(range(99)), 'identity': 'Do.Not.Normalize'}]}
    blocks = [('Custom', '0.0.0', b''.join(length(pack(records[k])) for k in ['face', 'body', 'hair'])),
              ('Coordinate', '0.0.0', pack([coord] * 7)),
              ('Parameter', '0.0.5', pack(dict(version='0.0.5', sex=sex, exType=0, firstname='Maker', lastname='Synthetic'))),
              ('Status', '0.0.0', pack(dict(version='0.0.0', coordinateType=0, clothesState=[0] * 9))),
              ('FixtureUnknown', '99', bytes(range(99))), ('KKEx', '3', pack(plugins))]
    payload = b''; infos = []
    for name, version, raw in blocks:
        infos.append(dict(name=name, version=version, pos=len(payload), size=len(raw))); payload += raw
    header = pack(dict(lstInfo=infos, fixtureHeader=msgpack.ExtType(19, b'opaque-header')))
    return (blank_png() + struct.pack('<i', 100) + dotnet_string(MAGIC) + dotnet_string(VERSIONS['card'])
            + length(b'') + length(header) + struct.pack('<q', len(payload)) + payload)


def material_values(records):
    for i, (pattern, color, tiling) in enumerate(zip([1, 2, 3], [[.9,.2,.3,.8],[.3,.8,.2,.5],[.1,.4,.9,1]], [[1,.9],[.95,1],[.8,.85]])):
        records['clothes']['parts'][0]['colorInfo'][i].update(pattern=pattern, patternColor=color, tiling=tiling)
    records['face']['baseMakeup'].update(cheekId=2, cheekColor=[.95,.15,.22,.6], paintId=[1,3],
        paintColor=[[.2,.5,.9,.65],[.85,.35,.1,.7]], paintLayout=[[.7,.4,.3,.8],[.2,.6,.8,.9]])
    records['face'].update(moleId=1, moleColor=[.2,.1,.05,.8], moleLayout=[.25,.7,.5,.85], lipLineId=2, lipLineColor=[.35,.1,.15,.5])


def build(output):
    if not output.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Fixture output must stay in ignored .local/')
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    for sex, head, bone, moved, materials in [(1,0,0,False,False), (0,0,0,False,False),
            (1,200,1,False,False), (0,200,1,False,False), (1,201,0,False,False),
            (0,201,1,False,False), (1,0,0,True,False), (1,0,0,False,True),
            (1,200,1,False,True), (0,201,1,False,True)]:
        source = ROOT / '.local/reverse' / ('rigs' if sex else 'male')
        contract = json.loads((source / 'character-shape-contract.json').read_text())
        records = fixture_records(contract, [0, 2])
        records['face']['headId'] = head; records['body']['typeBone'] = bone
        for part, item in zip(records['clothes']['parts'], [39,25,0,0,0,0,0,1,1]): part['id'] = item
        if materials: material_values(records)
        data = card_bytes(records, sex, moved=moved, coordinate_makeup=materials)
        name = f"{'female' if sex else 'male'}-head{head}-bone{bone}" + ('-moved' if moved else '-materials' if materials else '') + '.png'
        (output / name).write_bytes(data)
        parsed = parse_card(data)
        rows.append(dict(file=name, sex=sex, headID=head, boneType=bone, moved=moved, materials=materials,
            sha256=hashlib.sha256(data).hexdigest(), selectionCount=13,
            expectedHair=[0,2,0,0], expectedClothes=[39,25,0,0,0,0,0,1,1],
            preservedBlockHashes={b['name']: hashlib.sha256(b['raw']).hexdigest() for b in parsed.blocks if b['name'] not in ['Custom','Coordinate']},
            opaqueTokenCount=99))
    document = dict(schemaVersion=1, library=str(ROOT / '.local/reverse/maker-library/library.json'),
                    femaleBase=str(ROOT / '.local/reverse/rigs/source-avatar.json'), maleBase=str(ROOT / '.local/reverse/male/source-male-avatar.json'), fixtures=rows)
    (output / 'selection-fixtures.json').write_text(json.dumps(document, indent=2) + '\n')
    print(json.dumps(dict(fixtures=len(rows), manifest=str(output / 'selection-fixtures.json'))))
    return document


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.local/reverse/maker-expansion')
    build(parser.parse_args().output)
