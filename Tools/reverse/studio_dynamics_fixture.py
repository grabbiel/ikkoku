#!/usr/bin/env python3
"""Create a clothed, authored Studio fixture using the converted hair-00 springs.

No original thumbnail is read. This fixture is separate from user scene/card data.
"""
import argparse
import hashlib
import json
from pathlib import Path
from maker_selection_fixture import card_bytes, ROOT
from card_appearance_bindings import fixture_records
from analysis import studio_scene_contract as scenes
from analysis.card_contract import png_end, Limits


def build(output, front=1):
    if not output.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Derived fixtures must stay below .local')
    output.mkdir(parents=True, exist_ok=True)
    contract = json.loads((ROOT / '.local/reverse/rigs/character-shape-contract.json').read_text())
    records = fixture_records(contract, [0, front])
    records['face']['headId'] = 200
    records['body']['typeBone'] = 1
    for part, item in zip(records['clothes']['parts'], [39,25,0,0,0,0,0,1,1]):
        part['id'] = item
    card = card_bytes(records, 1)
    raw = card[png_end(card, Limits()):]
    original = scenes.fixture_bytes
    try:
        scenes.fixture_bytes = lambda *a, **kw: raw
        data, _ = scenes.scene_fixture()
    finally:
        scenes.fixture_bytes = original
    path = output / ('clothed-source.png' if front == 1 else f'clothed-source-front{front}.png')
    path.write_bytes(data)
    (output / f'fixture-{front}.json').write_text(json.dumps(dict(file=str(path),sha256=hashlib.sha256(data).hexdigest(),
        hairIDs=[0,front],headID=200,boneType=1,kind='authored-nonsexual-clothed-fixture'),indent=2)+'\n')
    return path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--front-hair',type=int,choices=[1,2,5],default=1)
    args=parser.parse_args()
    print(build(args.output,args.front_hair))
