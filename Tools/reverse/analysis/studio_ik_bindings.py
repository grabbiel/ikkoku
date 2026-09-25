#!/usr/bin/env python3
"""Extract original FinalIK references and Studio target identities, without images."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path


def extract(bundle: Path) -> dict:
    import UnityPy
    env = UnityPy.load(str(bundle))
    candidates = []
    for obj in env.objects:
        if obj.type.name != 'MonoBehaviour':
            continue
        tree = obj.read_typetree()
        if 'references' in tree and 'solver' in tree and 'rootNode' in tree['solver']:
            candidates.append((obj, tree))
    if len(candidates) != 1:
        raise ValueError('Expected exactly one original FullBodyBipedIK component')
    obj, data = candidates[0]
    objects = {o.path_id: o for o in env.objects if o.assets_file is obj.assets_file}
    def reference(pointer):
        if pointer['m_FileID'] != 0 or pointer['m_PathID'] not in objects:
            raise ValueError('IK binding requires a local, non-null original transform')
        transform = objects[pointer['m_PathID']]
        if transform.type.name != 'Transform':
            raise ValueError('IK reference is not a Transform')
        game_object = objects[transform.read_typetree()['m_GameObject']['m_PathID']]
        return {'sourceID': f'{obj.assets_file.name}:{transform.path_id}', 'name': game_object.read_typetree()['m_Name']}
    refs, solver = data['references'], data['solver']
    if len(solver['chain']) != 5 or len(solver['effectors']) != 9:
        raise ValueError('Unexpected source FBBIK topology')
    # Source AddObjectAssist.InitIKTarget order, not the FinalIK effector enum order.
    target_specs = [(0, 'body', 0, None), (1, 'leftArm', 1, None), (2, 'leftArm', None, 1), (3, 'leftArm', 5, None),
                    (4, 'rightArm', 2, None), (5, 'rightArm', None, 2), (6, 'rightArm', 6, None),
                    (7, 'leftLeg', 3, None), (8, 'leftLeg', None, 3), (9, 'leftLeg', 7, None),
                    (10, 'rightLeg', 4, None), (11, 'rightLeg', None, 4), (12, 'rightLeg', 8, None)]
    targets = []
    for number, group, effector, chain in target_specs:
        pointer = solver['effectors'][effector]['target'] if effector is not None else solver['chain'][chain]['bendConstraint']['bendGoal']
        targets.append({'id': number, 'group': group, 'rotationEnabled': number in (3, 6, 9, 12), 'prefabTarget': reference(pointer)})
    limbs = []
    for chain, name, ids, fields in [(1, 'leftArm', [1,2,3], ['leftUpperArm','leftForearm','leftHand']),
                                   (2, 'rightArm', [4,5,6], ['rightUpperArm','rightForearm','rightHand']),
                                   (3, 'leftLeg', [7,8,9], ['leftThigh','leftCalf','leftFoot']),
                                   (4, 'rightLeg', [10,11,12], ['rightThigh','rightCalf','rightFoot'])]:
        nodes = [reference(refs[field]) for field in fields]
        if nodes != [reference(n['transform']) for n in solver['chain'][chain]['nodes']]:
            raise ValueError('Reference bones and serialized solver chain disagree')
        limbs.append({'group': name, 'targetIDs': ids, 'nodes': nodes})
    def optional(pointer):
        return None if pointer['m_PathID'] == 0 else reference(pointer)
    full = {
        'weight': solver['IKPositionWeight'], 'spineStiffness': solver['spineStiffness'],
        'chains': [{**{key: c[key] for key in ('pin', 'pull', 'push', 'pushParent', 'reach', 'reachSmoothing', 'pushSmoothing', 'children')},
                    'nodes': [reference(n['transform']) for n in c['nodes']],
                    'constraints': [{**{k: q[k] for k in ('pushElasticity', 'pullElasticity')}, 'bone1': reference(q['bone1']), 'bone2': reference(q['bone2'])} for q in c['childConstraints']],
                    'bendWeight': c['bendConstraint']['weight']} for c in solver['chain']],
        'effectors': [{**{k: c[k] for k in ('positionWeight', 'rotationWeight', 'maintainRelativePositionWeight')},
                       'effectChildNodes': bool(c['effectChildNodes']), 'bone': reference(c['bone']), 'children': [reference(p) for p in c['childBones']],
                       'plane': [reference(c[k]) for k in ('planeBone1', 'planeBone2', 'planeBone3') if c[k]['m_PathID'] != 0]} for c in solver['effectors']],
        'spine': {'bones': [reference(p) for p in solver['spineMapping']['spineBones']], 'iterations': solver['spineMapping']['iterations'], 'twistWeight': solver['spineMapping']['twistWeight']},
        'bones': [{'bone': reference(c['bone']), 'maintainRotationWeight': c['maintainRotationWeight']} for c in solver['boneMappings']],
        'limbs': [{'parent': optional(c['parentBone']), 'bones': [reference(c[k]) for k in ('bone1', 'bone2', 'bone3')], 'maintainRotationWeight': c['maintainRotationWeight'], 'weight': c['weight']} for c in solver['limbMappings']]
    }
    return {'schemaVersion': 2, 'source': {'path': str(bundle), 'sha256': hashlib.sha256(bundle.read_bytes()).hexdigest(), 'componentPathID': obj.path_id},
            'root': reference(refs['root']), 'pelvis': reference(refs['pelvis']), 'body': reference(solver['rootNode']),
            'iterations': solver['iterations'], 'spineStiffness': solver['spineStiffness'], 'pullBodyVertical': solver['pullBodyVertical'], 'pullBodyHorizontal': solver['pullBodyHorizontal'],
            'targets': targets, 'limbs': limbs, 'fullBody': full,
            'limitations': ['Recovered FinalIK bindings; numerical validation uses recovered C# with an independent Unity math/Transform host, not the Unity player.']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('bundle', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    result = extract(args.bundle)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'targets': len(result['targets']), 'limbs': len(result['limbs']), 'output': str(args.output)}))


if __name__ == '__main__':
    main()
