#!/usr/bin/env python3
"""Assemble the installed normal male using source shared bones and explicit clothes.

Never renders or decodes card PNG thumbnails. Original data stays in ignored .local.
Requires the already verified female shared head/clothes exports, and one installed
normal male card whose serialized shape and hair selection supply the base preset.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

import msgpack
import numpy as np
from PIL import Image
import UnityPy

from rig_inventory import Inspector
from clothed_material_contract import hair_base, shader_contract
sys.path.insert(0, str(Path(__file__).parent / 'analysis'))
from card_contract import Cursor, parse_card

ROOT = Path(__file__).resolve().parents[2]


def evidence(path):
    return {'path': str(path.resolve()), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def source_bundle(folder, name):
    path = folder / 'source/abdata/chara' / (name + '.unity3d')
    record = json.loads(path.with_name(path.name + '.provenance.json').read_text())
    if record['sha256'] != evidence(path)['sha256']:
        raise ValueError('Original source bundle hash mismatch: ' + str(path))
    return path


def custom_card(path):
    parsed = parse_card(path.read_bytes())
    blocks = {b['name']: b for b in reversed(parsed.blocks)}
    params = msgpack.unpackb(blocks['Parameter']['raw'], raw=False)
    if params['sex'] != 0 or params.get('exType', 0) != 0:
        raise ValueError('Only the normal male shared-skeleton character is supported')
    cursor = Cursor(blocks['Custom']['raw']); custom = {}
    for name in ('face', 'body', 'hair'):
        custom[name] = msgpack.unpackb(cursor.take(cursor.number('<i')), raw=False)
    if custom['face']['headId'] != 0:
        raise ValueError('This extraction requires recovered head00')
    return custom, parsed.report


def selection(table, item_id):
    matches = [row for row in table['dictList'].values() if int(row[0]) == item_id]
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous original catalog item')
    return dict(zip(table['lstKey'], matches[0], strict=True))


def save_json(path, value, compact=False):
    path.write_text(json.dumps(value, indent=None if compact else 2, allow_nan=False) + '\n')


def build(shared, output, card):
    if not output.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Recovered game data must remain in ignored .local/')
    output.mkdir(parents=True, exist_ok=True)
    custom, card_report = custom_card(card)
    manifest = json.loads((shared / 'source-avatar.json').read_text())
    appearance = json.loads((shared / 'source-avatar.appearance.json').read_text())
    inputs = [evidence(card), evidence(shared / 'source-avatar.json')]
    copied = set()

    def copy(name):
        if name in copied:
            return
        path = shared / name
        if not path.resolve().is_relative_to(shared.resolve()):
            raise ValueError('Shared asset path escapes its folder')
        dest = output / name; dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest); inputs.append(evidence(path)); copied.add(name)

    # The source ChaControl.LoadAsync selects these same masters for both sexes.
    for name in [manifest['bodySkeleton'], manifest['headSkeleton'], manifest['head']['file'],
                 *[p['file'] for p in manifest['clothes']], 'source-expression-contract.json', 'top-body-alpha-mask.png']:
        copy(name)
    for part in appearance['parts']:
        for key in ('texture', 'bodyMask'):
            if key in part:
                copy(part[key])
        if 'irisHighlights' in part:
            for key in ('upper', 'lower'):
                copy(part['irisHighlights'][key])
    contract = json.loads((shared / 'character-shape-contract.json').read_text())
    for domain in contract['domains']:
        domain['defaultValues'] = custom['body' if domain['id'] == 'body' else 'face']['shapeValueBody' if domain['id'] == 'body' else 'shapeValueFace']
    contract['malePresetEvidence'] = evidence(card)
    save_json(output / 'character-shape-contract.json', contract)

    def export(bundle, prefab, name):
        path = source_bundle(shared, bundle); inputs.append(evidence(path))
        environment = UnityPy.load(str(path)); inspector = Inspector(environment)
        matches = [key for key in environment.container if key.endswith('/' + prefab + '.prefab')]
        if len(matches) != 1:
            raise ValueError('Expected one exact source prefab ' + prefab)
        neutral = inspector.neutral(matches[0], False, True)
        neutral['sources'] = [evidence(path)]
        save_json(output / name, neutral, compact=True)
        return environment, inspector, matches[0], neutral

    _, _, _, body = export('oo_base', 'p_cm_body_00', 'male-body-rig.json')
    # Prevent accidentally making the alternate/private source renderers a preview.
    main = [m for m in body['meshes'] if m['name'] == 'o_body_a']
    if len(main) != 1:
        raise ValueError('Expected only one explicit main male body mesh')
    manifest.update(kind='koikatsu-male-avatar', name='Original clothed male base', sex=0,
                    headID=0, boneType=0, defaultCard='default-male-card.png', bodyCorrection='shapecorrect.bytes')
    shutil.copyfile(shared / 'textassets/shapecorrect.bytes', output / 'shapecorrect.bytes')
    manifest['body'] = {'file': 'male-body-rig.json', 'meshNames': ['o_body_a']}
    manifest['hair'] = []
    appearance['parts'] = [p for p in appearance['parts'] if p['kind'] != 'hair']
    catalog = json.loads((shared / 'clothed-catalog.json').read_text())
    hair_records = []
    for index, (role, table, filename) in enumerate([
        ('back', 'bo_hair_b_00', 'male-hair-back-rig.json'), ('front', 'bo_hair_f_00', 'male-hair-front-rig.json')]):
        selected = custom['hair']['parts'][index]
        row = selection(catalog[table], selected['id'])
        bundle = Path(row['MainAB']).stem
        env, inspector, key, rig = export(bundle, row['MainData'], filename)
        nodes, renderers = inspector.prefab_nodes(env.container[key].read())
        names = []
        for node_index, renderer in renderers:
            node_name = nodes[node_index]['name']
            if len(renderer.m_Materials) != 1:
                raise ValueError('Selected short hair needs one validated material')
            reader = renderer.m_Materials[0].deref(); material = reader.read()
            shader = shader_contract(reader, output, None)
            tex = dict(material.m_SavedProperties.m_TexEnvs)
            for field in ('_MainTex', '_AlphaMask'):
                if tex[field].m_Texture.path_id or shader['defaults'].get(field) != 'white':
                    raise ValueError('Selected hair needs verified white main/alpha default')
            mask = tex['_ColorMask']
            if (mask.m_Scale.x, mask.m_Scale.y, mask.m_Offset.x, mask.m_Offset.y) != (1, 1, 0, 0):
                raise ValueError('Selected hair mask requires UV resampling')
            texture = mask.m_Texture.read(); image = texture.image.convert('RGBA')
            raw_name = 'male-hair-' + role + '-mask.png'; image.save(output / raw_name)
            colors = np.asarray([selected['baseColor'], selected['startColor'], selected['endColor']], dtype=np.float32)
            pixels = hair_base(np.asarray(image, dtype=np.float32) / 255, colors)
            bake_name = 'male-hair-' + role + '-base.png'
            Image.fromarray(np.rint(np.clip(pixels, 0, 1) * 255).astype(np.uint8)).save(output / bake_name)
            appearance['parts'].append(dict(part=node_name+'/0',kind='hair',color=[1,1,1,1],alphaMode='OPAQUE',outline=True,texture=bake_name))
            names.append(node_name)
            hair_records.append(dict(role=role, catalog=row, nodeName=node_name, textureName=texture.m_Name,
                mask=raw_name, maskSHA256=evidence(output/raw_name)['sha256'], texture=bake_name,
                colors=colors.tolist(), shader=shader, material=material.object_reader.read_typetree()))
        manifest['hair'].append({'file': filename, 'meshNames': names})
    # Keep the known fully clothed T-shirt/long-pants/shoes selection. Card outfit
    # IDs are retained in the original card but deliberately not substituted here.
    appearance['provenance'].update(geometry='source-male-avatar.json', maleCard=evidence(card))
    appearance['provenance']['limitations'].append('Normal male mesh and original male card shape/hair preset; shared head base recipe and explicit reference outfit, not complete card appearance.')
    save_json(output/'source-male-avatar.json', manifest)
    save_json(output/'source-male-avatar.appearance.json', appearance)
    shutil.copyfile(card,output/'default-male-card.png')
    save_json(output/'male-hair-materials.json', hair_records)
    save_json(output/'original-male-card-oracle.json', card_report)
    save_json(output/'male-assembly-evidence.json', dict(schemaVersion=1,inputs=inputs,
        bodyMesh=main[0]['name'], bodyVertices=len(main[0]['positions']),
        assembly='Shared p_cf_body_bone / p_cf_head_bone; original p_cm_body_00 mesh; source head00; exact-name palette rebind; original inverse binds untouched',
        selectedHair=[r['catalog'] for r in hair_records],
        bodyPaletteAudit=body['skins'][main[0]['skin']].get('sourcePaletteAudit'),
        limits=['Normal sex=0, exType=0 only; special male models unimplemented.',
                'Selected shared shirt/trousers/shoes; original card outfit not loaded.',
                'Source hair albedo formula only; original lighting and dynamics are not reconstructed.']))
    print(json.dumps({'avatar':str(output/'source-male-avatar.json'),'bodyVertices':len(main[0]['positions']), 'hairParts':len(hair_records)},indent=2))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared',type=Path,default=ROOT/'.local/reverse/rigs')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/reverse/male')
    parser.add_argument('--card',type=Path,default=ROOT/'.local/reverse/male/source/UserData/chara/male/ill_male_01.png')
    args=parser.parse_args();build(args.shared,args.output,args.card)
