#!/usr/bin/env python3
"""Build a controlled Studio stream around explicit clothed selection test cards."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from analysis import studio_scene_contract as scenes
from analysis.card_contract import png_end, Limits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--maker-fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.maker_fixtures.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    original = scenes.fixture_bytes
    camera = scenes.Writer.camera
    def controlled_camera(self):
        self.i(2)
        for v in (1, 2.9, 3, 0, 180, 0, 0, 0, -3.8, 35): self.f(v)
    scenes.Writer.camera = controlled_camera
    outputs = []
    try:
        for fixture in manifest['fixtures']:
            if fixture['file'] not in ['female-head200-bone1.png', 'male-head201-bone1.png']: continue
            raw = (args.maker_fixtures.parent / fixture['file']).read_bytes()
            card = raw[png_end(raw, Limits()):]
            scenes.fixture_bytes = lambda *a, **kw: card
            data, _ = scenes.scene_fixture()
            index = data.index(card)
            data = data[:index-4] + struct.pack('<i', fixture['sex']) + data[index:]
            name = 'studio-' + fixture['file']
            (args.output/name).write_bytes(data)
            outputs.append(dict(file=name, sex=fixture['sex'], headID=fixture['headID'], boneType=fixture['boneType'],
                                sha256=hashlib.sha256(data).hexdigest(), cardSHA256=hashlib.sha256(card).hexdigest()))
    finally:
        scenes.fixture_bytes = original; scenes.Writer.camera = camera
    (args.output/'fixtures.json').write_text(json.dumps(dict(schemaVersion=1, fixtures=outputs), indent=2)+'\n')


if __name__ == '__main__': main()
