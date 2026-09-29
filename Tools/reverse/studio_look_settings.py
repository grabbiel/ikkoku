#!/usr/bin/env python3
"""Extract the prefab look-at settings (neck/eyes) from oo_base.unity3d and
the EyeLookMaterialControll iris-shift settings from the head prefab bundles.

Only serialized MonoBehaviour typetrees are decoded. Every Transform pointer
is resolved to its GameObject name (path id 0 becomes null). The typetree ->
JSON conversion below is pure so it can be unit-tested with synthetic dicts;
UnityPy is only touched by extract().
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUNDLE = 'chara/oo_base.unity3d'
HEAD_BUNDLE_GLOB = 'bo_head_*.unity3d'
EYE_MATERIAL_CLASS = 'EyeLookMaterialControll'
NECK_ROOT = 'p_cf_body_bone'
HEAD_ROOT = 'p_cf_head_bone'
NECK_LOOK_TYPES = {0: 'ANIMATION', 1: 'TARGET', 2: 'AWAY', 3: 'FORWARD', 4: 'FIX', 5: 'CONTROL'}
EYE_LOOK_TYPES = {0: 'NO_LOOK', 1: 'TARGET', 2: 'AWAY', 3: 'FORWARD', 4: 'CONTROL'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evidence_path(path):
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def enum(value, table, label):
    if value not in table:
        raise ValueError(f'Unknown {label} lookType {value}')
    return {'value': int(value), 'name': table[value]}


def pointer_name(pointer, names):
    """Resolve one serialized Transform pointer to its GameObject name."""
    if pointer is None:
        return None
    path_id = pointer.get('m_PathID', 0)
    if not path_id:
        return None
    if path_id not in names:
        raise ValueError(f'Transform pointer {path_id} has no GameObject name')
    return names[path_id]


def vector2(value):
    return [value['x'], value['y']]


def vector3(value):
    return [value['x'], value['y'], value['z']]


def quaternion(value):
    return [value['x'], value['y'], value['z'], value['w']]


def neck_settings(tree, names):
    return {
        'isEnabled': tree['isEnabled'],
        'transformAim': pointer_name(tree.get('transformAim'), names),
        'boneCalcAngle': pointer_name(tree.get('boneCalcAngle'), names),
        'aBones': [{
            'name': bone['name'],
            'referenceCalc': pointer_name(bone.get('referenceCalc'), names),
            'neckBone': pointer_name(bone.get('neckBone'), names),
            'controlBone': pointer_name(bone.get('controlBone'), names),
            'fixAngle': quaternion(bone['fixAngle']),
            'angleHRate': bone['angleHRate'], 'angleVRate': bone['angleVRate'],
            'angleH': bone['angleH'], 'angleV': bone['angleV'],
        } for bone in tree['aBones']],
        'neckTypeStates': [{
            'name': state['name'],
            'aParam': [{
                'name': param['name'], 'upBendingAngle': param['upBendingAngle'],
                'downBendingAngle': param['downBendingAngle'], 'minBendingAngle': param['minBendingAngle'],
                'maxBendingAngle': param['maxBendingAngle'],
            } for param in state['aParam']],
            'leapSpeed': state['leapSpeed'], 'hAngleLimit': state['hAngleLimit'], 'vAngleLimit': state['vAngleLimit'],
            'limitBreakCorrectionValue': state['limitBreakCorrectionValue'], 'limitAway': state['limitAway'],
            'isLimitBreakBackup': state['isLimitBreakBackup'],
            'lookType': enum(state['lookType'], NECK_LOOK_TYPES, 'neck'),
        } for state in tree['neckTypeStates']],
        'changeTypeLeapTime': tree['changeTypeLeapTime'],
        'changeTypeLerpCurve': {
            'keys': [{'time': k['time'], 'value': k['value'], 'inSlope': k['inSlope'], 'outSlope': k['outSlope']}
                     for k in tree['changeTypeLerpCurve'].get('m_Curve', [])],
            'preInfinity': tree['changeTypeLerpCurve'].get('m_PreInfinity'),
            'postInfinity': tree['changeTypeLerpCurve'].get('m_PostInfinity'),
        },
        'calcLerp': tree['calcLerp'], 'skipCalc': tree['skipCalc'],
    }


def neck_controller_settings(tree, names=None):
    return {'ptnNo': tree['ptnNo'], 'rate': tree['rate']}


def eyes_settings(tree, names):
    return {
        'correct': tree['correct'],
        'rootNode': pointer_name(tree.get('rootNode'), names),
        'trfCenter': pointer_name(tree.get('trfCenter'), names),
        'closeEyeLength': tree['closeEyeLength'], 'centerEyeLength': tree['centerEyeLength'],
        'eyeObjs': [{'eyeTransform': pointer_name(obj['eyeTransform'], names), 'eyeLR': obj['eyeLR']}
                    for obj in tree['eyeObjs']],
        'headLookVector': vector3(tree['headLookVector']), 'headUpVector': vector3(tree['headUpVector']),
        'eyeTypeStates': [{
            'comment': state['comment'], 'thresholdAngleDifference': state['thresholdAngleDifference'],
            'bendingMultiplier': state['bendingMultiplier'], 'maxAngleDifference': state['maxAngleDifference'],
            'upBendingAngle': state['upBendingAngle'], 'downBendingAngle': state['downBendingAngle'],
            'minBendingAngle': state['minBendingAngle'], 'maxBendingAngle': state['maxBendingAngle'],
            'leapSpeed': state['leapSpeed'], 'forntTagDis': state['forntTagDis'], 'nearDis': state['nearDis'],
            'hAngleLimit': state['hAngleLimit'], 'vAngleLimit': state['vAngleLimit'],
            'lookType': enum(state['lookType'], EYE_LOOK_TYPES, 'eye'),
        } for state in tree['eyeTypeStates']],
        'angleHRate': list(tree['angleHRate']), 'angleVRate': tree['angleVRate'], 'sorasiRate': tree['sorasiRate'],
        'targetObjMaxDir': tree['targetObjMaxDir'],
    }


def eye_controller_settings(tree, names=None):
    return {'ptnNo': tree['ptnNo']}


def eye_material_settings(tree, game_object, renderer_materials):
    """One EyeLookMaterialControll record: the eyeLR discriminator, every
    serialized iris-shift field (the offsets and scale are private in the
    compiled script but serialized in the prefab, so they are exported and
    never assumed to be the script's Reset defaults), the texStates and the
    eye renderer's GameObject name and material names."""
    tex_states = [{'texID': state['texID'], 'texName': state['texName'], 'isYure': int(state['isYure'])}
                  for state in tree['texStates']]
    return {
        'eyeLR': tree['eyeLR'],
        'InsideWait': tree['InsideWait'], 'OutsideWait': tree['OutsideWait'],
        'UpWait': tree['UpWait'], 'DownWait': tree['DownWait'],
        'InsideLimit': tree['InsideLimit'], 'OutsideLimit': tree['OutsideLimit'],
        'UpLimit': tree['UpLimit'], 'DownLimit': tree['DownLimit'],
        'power': tree['power'],
        'offset': vector2(tree['offset']),
        'hlUpOffsetY': tree['hlUpOffsetY'], 'hlDownOffsetY': tree['hlDownOffsetY'],
        'scale': vector2(tree['scale']),
        'texStates': tex_states,
        'YureInside': tree['YureInside'], 'YureOutside': tree['YureOutside'],
        'YureUp': tree['YureUp'], 'YureDown': tree['YureDown'], 'YureTime': tree['YureTime'],
        'gameObject': game_object,
        'materials': list(renderer_materials),
    }


def game_object_name(reader_by_path, path_id):
    return reader_by_path[path_id].read().m_Name


def transform_root(tree, transform_trees, reader_by_path):
    """Walk a Transform typetree dict up m_Father and return the root name."""
    seen = 0
    while True:
        father = (tree.get('m_Father') or {}).get('m_PathID', 0)
        if not father:
            return game_object_name(reader_by_path, tree['m_GameObject']['m_PathID'])
        tree = transform_trees[father]
        seen += 1
        if seen > 64:
            raise ValueError('Transform parent cycle')


def extract(rigs: Path) -> dict:
    import UnityPy
    rigs = rigs.resolve()
    path = rigs / 'source/abdata' / BUNDLE
    provenance = json.loads(path.with_suffix(path.suffix + '.provenance.json').read_text())
    hashed = digest(path)
    # Same source-copy SHA-256 sidecar contract as the other rig bundles.
    expected = provenance.get('sha256') or provenance.get('source', {}).get('sha256')
    if expected != hashed:
        raise ValueError(f'Bundle provenance hash mismatch: {path}')
    env = UnityPy.load(str(path))
    readers = {obj.path_id: obj for obj in env.objects}
    transform_trees = {obj.path_id: obj.read_typetree() for obj in env.objects if obj.type.name == 'Transform'}
    # PPtrs reference Transforms, so resolve them by GameObject name per path id.
    names = {path_id: game_object_name(readers, tree['m_GameObject']['m_PathID'])
             for path_id, tree in transform_trees.items() if (tree.get('m_GameObject') or {}).get('m_PathID')}

    targets = {'NeckLookCalcVer2': (NECK_ROOT, neck_settings, 'neck'),
               'NeckLookControllerVer2': (NECK_ROOT, neck_controller_settings, 'neckController'),
               'EyeLookCalc': (HEAD_ROOT, eyes_settings, 'eyes'),
               'EyeLookController': (HEAD_ROOT, eye_controller_settings, 'eyeController')}
    result, excluded = {}, []
    for obj in env.objects:
        if obj.type.name != 'MonoBehaviour':
            continue
        behavior = obj.read()
        if not behavior.m_GameObject.path_id:
            continue
        class_name = behavior.m_Script.read().m_ClassName
        if class_name not in targets:
            continue
        tree = obj.read_typetree()
        go_tree = readers[behavior.m_GameObject.path_id].read_typetree()
        component = next(c for c in go_tree['m_Component']
                         if readers[c['component']['m_PathID']].type.name == 'Transform')
        root = transform_root(transform_trees[component['component']['m_PathID']], transform_trees, readers)
        wanted_root, convert, key = targets[class_name]
        if root != wanted_root:
            reason = f'Not under the CharaStudio prefab root {wanted_root}; found under {root}'
            if class_name == 'NeckLookCalcVer2':
                reason += (f"; this variant keeps only {len(tree['neckTypeStates'])} neckTypeStates "
                           'and CharaStudio loads the p_cf_body_bone prefab')
            excluded.append({'root': root, 'className': class_name, 'reason': reason})
            continue
        if key in result:
            raise ValueError(f'Duplicate {class_name} under {root}')
        result[key] = {'className': class_name, 'gameObject': go_tree['m_Name'], 'root': root,
                       **convert(tree, names)}
    if set(result) != {value[2] for value in targets.values()}:
        raise ValueError(f'Missing look settings: {sorted({value[2] for value in targets.values()} - set(result))}')

    # The EyeLookMaterialControll behaviours sit on the eye renderers of the
    # character head prefab bundles (bo_head_*.unity3d), not on oo_base.
    eye_material, eye_evidence = [], []
    for head_path in sorted((rigs / 'source/abdata/chara').glob(HEAD_BUNDLE_GLOB)):
        head_provenance = json.loads(head_path.with_suffix(head_path.suffix + '.provenance.json').read_text())
        head_hashed = digest(head_path)
        head_expected = head_provenance.get('sha256') or head_provenance.get('source', {}).get('sha256')
        if head_expected != head_hashed:
            raise ValueError(f'Bundle provenance hash mismatch: {head_path}')
        head_env = UnityPy.load(str(head_path))
        head_readers = {obj.path_id: obj for obj in head_env.objects}
        found = []
        for obj in head_env.objects:
            if obj.type.name != 'MonoBehaviour':
                continue
            behavior = obj.read()
            if not behavior.m_GameObject.path_id:
                continue
            if behavior.m_Script.read().m_ClassName != EYE_MATERIAL_CLASS:
                continue
            go_tree = head_readers[behavior.m_GameObject.path_id].read_typetree()
            # The serialized _renderer PPtr is null in the capture; the eye's
            # own SkinnedMeshRenderer component is the renderer the script
            # shifts, so its material names come from there.
            materials = []
            for component in go_tree['m_Component']:
                ref = head_readers[component['component']['m_PathID']]
                if not ref.type.name.endswith('Renderer'):
                    continue
                materials += [head_readers[m['m_PathID']].read().m_Name
                              for m in ref.read_typetree().get('m_Materials', []) if m['m_PathID']]
            found.append(eye_material_settings(obj.read_typetree(), go_tree['m_Name'], materials))
        if not found:
            continue
        eye_evidence.append({'path': evidence_path(head_path), 'sha256': head_hashed})
        eye_material += found
    eye_material.sort(key=lambda entry: entry['eyeLR'])
    if [entry['eyeLR'] for entry in eye_material] != [0, 1]:
        raise ValueError(f'Expected one EyeLookMaterialControll per eyeLR 0/1, found '
                         f'{[entry["eyeLR"] for entry in eye_material]}')
    return {'schema': 1, 'evidence': [{'path': evidence_path(path), 'sha256': hashed}] + eye_evidence,
            **result, 'eyeMaterial': eye_material, 'excluded': excluded}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rigs', type=Path, default=REPO / '.local/reverse/rigs')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = extract(args.rigs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
