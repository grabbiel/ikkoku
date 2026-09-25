#!/usr/bin/env python3
"""Recover installed additional heads and shared-skeleton body correction data.

Consumes hash-verified private bundles; emits only to ignored .local. Never reads
card thumbnails. Exported avatars retain the explicit clothed reference outfit.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent / 'analysis'))


def evidence(path):
    data = path.read_bytes()
    return dict(path=str(path.resolve()), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())


def checked(path):
    record = json.loads(path.with_name(path.name + '.provenance.json').read_text())
    if record['sha256'] != evidence(path)['sha256']:
        raise ValueError('Original bundle no longer matches acquisition hash')
    return path


def row(table, item):
    if table['categoryNo'] != 100:
        raise ValueError('Expected normal head catalog category 100')
    records = [dict(zip(table['lstKey'], values, strict=True)) for values in table['dictList'].values()
               if int(values[0]) == item]
    if len(records) != 1:
        raise ValueError('Missing or ambiguous source head identity')
    return records[0]


def replace_face_channels(contract, channels, record):
    result = copy.deepcopy(contract)
    face = next(d for d in result['domains'] if d['id'] == 'face')
    names = {c['name'] for c in channels}
    if len(names) != len(channels) or any(b['sourceName'] not in names for s in face['slots'] for b in s['bindings']):
        raise ValueError('Head-specific shape data cannot satisfy the 52 source slots')
    face['channels'] = channels
    face['provenance'] = [p for p in face['provenance'] if 'anmShapeHead_' not in p['path']] + [record]
    return result


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n')


def enable_base_corrections(directory, stem, correction):
    """Add the source table to an existing head00 assembly without changing IDs."""
    manifest_path = directory / (stem + '.json')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('headID', 0) != 0:
        raise ValueError('Expected an original head00 base assembly')
    destination = directory / 'shapecorrect.bytes'
    if correction.resolve() != destination.resolve():
        shutil.copyfile(correction, destination)
    manifest['bodyCorrection'] = 'shapecorrect.bytes'
    write(manifest_path, manifest)


def build(source, shared, male, output):
    import msgpack
    import numpy as np
    from PIL import Image
    import UnityPy
    from rig_inventory import Inspector
    from character_contracts import channels
    from expression_contract import extract_targets, evaluate_original, max_active_channels, source_id
    from head_material_contract import create_head_base
    from card_appearance_bindings import fixture_records, synthetic_card

    if not output.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Recovered data must stay under ignored .local/')
    bundle = checked(source / 'abdata/chara/bo_head_50.unity3d')
    catalog = checked(source / 'abdata/list/characustom/50.unity3d')
    base_bundle = checked(shared / 'source/abdata/chara/oo_base.unity3d')
    head00_bundle = checked(shared / 'source/abdata/chara/bo_head_00.unity3d')
    correction_bundle = checked(shared / 'source/abdata/list/shapecorrect/shapecorrect.unity3d')
    correction_environment = UnityPy.load(str(correction_bundle))
    correction_reader = next(o for o in correction_environment.objects if o.type.name == 'TextAsset' and o.peek_name() == 'shapecorrect')
    correction_bytes = correction_reader.read().m_Script.encode('utf8', 'surrogateescape')
    if correction_bytes != (shared / 'textassets/shapecorrect.bytes').read_bytes():
        raise ValueError('Correction table differs from the original bundle')
    eye_bundles = [checked(source / f'abdata/chara/mt_eyeline_{kind}_50.unity3d') for kind in ('up', 'down')]
    env = UnityPy.load(*map(str, [bundle, base_bundle, head00_bundle, *eye_bundles]))
    inspector = Inspector(env)
    cat_env = UnityPy.load(str(catalog))
    table_reader = next(o for o in cat_env.objects if o.type.name == 'TextAsset' and o.peek_name() == 'bo_head_50')
    table = msgpack.unpackb(table_reader.read().m_Script.encode('utf8', 'surrogateescape'), raw=False, strict_map_key=False)
    shader_evidence = json.loads((shared / 'head-materials/contract.json').read_text())
    for directory, stem in ((shared, 'source-avatar'), (male, 'source-male-avatar')):
        enable_base_corrections(directory, stem, shared / 'textassets/shapecorrect.bytes')
    texture_readers = {}
    for o in env.objects:
        if o.type.name == 'Texture2D':
            texture_readers.setdefault(o.peek_name(), []).append(o)

    def texture(name):
        readers = texture_readers.get(name, [])
        if len(readers) != 1:
            raise ValueError('Expected one exact texture ' + name)
        return readers[0].read().image.convert('RGBA')

    assemblies, reports = [], []
    for head_id in (200, 201):
        catalog_row = row(table, head_id)
        prefab_keys = [k for k in env.container if k.endswith('/' + catalog_row['MainData'] + '.prefab')]
        if len(prefab_keys) != 1:
            raise ValueError('Expected one exact catalog-selected head prefab')
        neutral = inspector.neutral(prefab_keys[0], False, True)
        neutral['sources'] = [evidence(bundle), evidence(base_bundle), evidence(head00_bundle)]
        prefab = env.container[prefab_keys[0]].read()
        fbs = [(c.component.deref(), c.component.deref().read_typetree()) for c in prefab.m_Component
               if c.component.deref().type.name == 'MonoBehaviour']
        fbs = [(r, v) for r, v in fbs if 'EyebrowCtrl' in v and 'MouthCtrl' in v]
        if len(fbs) != 1:
            raise ValueError('Expected one serialized expression controller per head')
        fbs_reader, fbs_data = fbs[0]
        controllers, originals, meshes = extract_targets(fbs_reader, fbs_data)
        shape_readers = [o for o in env.objects if o.type.name == 'TextAsset' and o.peek_name() == catalog_row['ShapeAnime']]
        if len(shape_readers) != 1:
            raise ValueError('Catalog shape animation is missing or ambiguous')
        shape_bytes = shape_readers[0].read().m_Script.encode('utf8', 'surrogateescape')

        for sex, directory, manifest_name in ((1, shared, 'source-avatar'), (0, male, 'source-male-avatar')):
            folder = output / str(head_id) / ('female' if sex else 'male')
            folder.mkdir(parents=True, exist_ok=True)
            manifest = json.loads((directory / (manifest_name + '.json')).read_text())
            appearance = json.loads((directory / (manifest_name + '.appearance.json')).read_text())
            bindings = json.loads((directory / (manifest_name + '.card-appearance.json')).read_text())
            contract = json.loads((directory / 'character-shape-contract.json').read_text())

            copied_files = set()
            def copy_file(name):
                if name in copied_files:
                    return
                copied_files.add(name)
                path = directory / name
                if not path.resolve().is_relative_to(directory.resolve()):
                    raise ValueError('Referenced input escapes the source assembly')
                destination = folder / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)

            for name in [manifest['bodySkeleton'], manifest['headSkeleton'], manifest['body']['file'],
                         *[p['file'] for p in manifest['clothes']], *[p['file'] for p in manifest['hair']]]:
                copy_file(name)
            for part in appearance['parts']:
                for key in ('texture', 'bodyMask'):
                    if key in part:
                        copy_file(part[key])
                if 'irisHighlights' in part:
                    for key in ('upper', 'lower'):
                        copy_file(part['irisHighlights'][key])
            def copy_binding_inputs(value):
                if isinstance(value, dict):
                    if {'file', 'sha256', 'width', 'height'}.issubset(value):
                        copy_file(value['file'])
                    for item in value.values():
                        copy_binding_inputs(item)
                elif isinstance(value, list):
                    for item in value:
                        copy_binding_inputs(item)
            for binding in bindings['entries']:
                copy_binding_inputs(binding)
                if 'face.headId' in binding['requirements']:
                    binding['requirements']['face.headId'] = head_id

            manifest.update(sex=sex, headID=head_id, boneType=0, bodyCorrection='shapecorrect.bytes',
                            name=f'Original clothed {"female" if sex else "male"}, head {head_id}')
            manifest.pop('defaultCard', None)  # Head-00 preset is not this assembly's card.
            manifest['head']['file'] = 'head-rig.json'
            write(folder / 'head-rig.json', neutral)
            shutil.copyfile(shared / 'textassets/shapecorrect.bytes', folder / 'shapecorrect.bytes')
            shape_path = folder / (catalog_row['ShapeAnime'] + '.bytes')
            shape_path.write_bytes(shape_bytes)
            contract = replace_face_channels(contract, channels(shape_path), evidence(shape_path))
            contract['headIdentity'] = dict(id=head_id, catalog=catalog_row, sources=[evidence(catalog), evidence(bundle)])
            write(folder / 'character-shape-contract.json', contract)

            expression = json.loads((shared / 'source-expression-contract.json').read_text())
            expression.update(controllers=controllers,
                sourcePatternPairCount=sum(len(p) for t in originals.values() for _, p in t),
                sourceTargetCount=sum(len(c['targets']) for c in controllers), sourceUniqueMeshCount=len(meshes),
                fbsEnabled=bool(fbs_data['m_Enabled']), maxActiveChannelsPerMesh=max_active_channels(originals, meshes))
            expression['provenance']['head'] = dict(**evidence(bundle), sourceID=source_id(fbs_reader), prefab=catalog_row['MainData'])
            expression['gazeCorrection'].update(up=fbs_data['EyeLookUpCorrect'], down=fbs_data['EyeLookDownCorrect'], side=fbs_data['EyeLookSideCorrect'])
            expression['eyesOpenMaxCap'] = float(np.float32(1) - np.float32(fbs_data['EyeLookUpCorrect']))
            expression['blink'].update(frequency=fbs_data['BlinkCtrl']['BlinkFrequency'], baseSpeedSeconds=fbs_data['BlinkCtrl']['BaseSpeed'])
            mouth = fbs_data['MouthCtrl']
            for key in ('randTimeMin', 'randTimeMax', 'randScaleMin', 'randScaleMax', 'openRefValue', 'useAjustWidthScale'):
                expression['mouthWidth'][key] = mouth[key]
            expression['mouthWidth']['objAdjustWidthScale'] = dict(fileID=mouth['objAdjustWidthScale']['m_FileID'], pathID=str(mouth['objAdjustWidthScale']['m_PathID']))
            expression['gazeCorrection']['eyeLookControllerPrefabPathID'] = str(fbs_data['EyeLookController']['m_PathID'])
            write(folder / 'source-expression-contract.json', expression)
            cases = []
            for preset in expression['presets']:
                cases.append(dict(id=preset['id'], inputs=preset['inputs'], **evaluate_original(fbs_data, originals, meshes, preset['inputs'])))
            write(folder / 'source-expression-reference.json', dict(cases=cases, provenance=expression['provenance']))

            # The head row selects distinct base/mask textures. Eyelines use
            # GetTexture's _headID suffix in the *50 bundle, not head00 UV art.
            main, mask = texture(catalog_row['MainTex']), texture(catalog_row['ColorMaskTex'])
            head_binding = next(b for b in bindings['entries'] if b['kind'] == 'head')
            for key, image in (('main', main), ('mask', mask)):
                name = f'card-appearance-inputs/head-{head_id}-{key}.rgba'
                target = folder / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(image.tobytes())
                head_binding[key] = dict(file=name, sha256=evidence(target)['sha256'], width=image.width, height=image.height)
            # Stable explicit neutral preview colors; card colors replace these.
            from card_appearance_bindings import linear_colors, encode_rgb
            pixels = create_head_base(np.asarray(main, dtype=np.float32) / 255, np.asarray(mask, dtype=np.float32) / 255,
                                      linear_colors([1, .87, .80, 1]), linear_colors([1, .77, .69, 1]))
            pixels = encode_rgb(pixels)
            base_name = f'head-materials/head-{head_id}-base.png'
            Image.fromarray(np.rint(np.clip(pixels, 0, 1) * 255).astype(np.uint8)).save(folder / base_name)
            for part in appearance['parts']:
                if part['part'] == 'cf_O_face/0':
                    part['texture'] = base_name
                suffix = None
                if part['part'] == 'cf_O_eyeline/0':
                    suffix = 'kage' if part.get('pass', 0) else 'up'
                elif part['part'] == 'cf_O_eyeline_low/0':
                    suffix = 'down'
                if suffix:
                    name = f'cw_t_eyeline_{suffix}_000_{head_id}'
                    relative = 'head-materials/' + name + '.png'
                    texture(name).save(folder / relative)
                    part['texture'] = relative
            appearance['provenance'].update(geometry=manifest_name+'.json', head=dict(catalog=catalog_row, bundle=evidence(bundle)), sourceAlbedoContract=shader_evidence.get('schemaVersion'))
            bindings['limitations'][0] = f'Original head {head_id} with its own shape, expression, face and eyeline textures; selected reference clothes/hair.'
            write(folder / (manifest_name + '.appearance.json'), appearance)
            write(folder / (manifest_name + '.card-appearance.json'), bindings)
            fixture = fixture_records(contract, [2, 1] if sex else [9, 5])
            fixture['face']['headId'] = head_id
            for bone_type in (0, 1):
                fixture['body']['typeBone'] = bone_type
                (folder / f'synthetic-head-{head_id}-bone-{bone_type}.png').write_bytes(synthetic_card(fixture, fixture['clothes'], sex))
            path = folder / (manifest_name + '.json'); write(path, manifest)
            assemblies.append(dict(sex=sex, headID=head_id, exType=0,
                manifest=dict(file=str(path.relative_to(output.parent)), sha256=evidence(path)['sha256'])))
            reports.append(dict(sex=sex, headID=head_id, headNodes=len(neutral['nodes']),
                headMeshes=len(neutral['meshes']), shapeChannels=len(channels(shape_path)),
                expressionPairs=expression['sourcePatternPairCount'], catalog=catalog_row))
    write(output / 'assemblies.json', dict(assemblies=assemblies))
    write(output / 'evidence.json', dict(schemaVersion=1, sources=[evidence(p) for p in [bundle, catalog, correction_bundle, *eye_bundles]],
        assemblies=reports, limits=['Normal exType0 only; special male excludes the normal face shape controller.',
        'Original alternate-head geometry/shape/expression/albedo; original complete lighting remains unported.',
        'Nonzero bone types use source additive corrections, not a different mesh or skeleton.']))
    print(json.dumps(dict(assemblies=len(assemblies), registry=str(output/'assemblies.json')), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT/'.local/reverse/maker-variants/source')
    parser.add_argument('--shared', type=Path, default=ROOT/'.local/reverse/rigs')
    parser.add_argument('--male', type=Path, default=ROOT/'.local/reverse/male')
    parser.add_argument('--output', type=Path, default=ROOT/'.local/reverse/maker-library/heads')
    args = parser.parse_args(); build(args.source, args.shared, args.male, args.output)
