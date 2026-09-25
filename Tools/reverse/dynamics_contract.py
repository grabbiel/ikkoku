#!/usr/bin/env python3
"""Export the selected original hair DynamicBone setup, without rendering assets.

Supports the observed real-node, empty exclusion/notRoll and finite Hermite-distribution
configuration. Rejects other variants rather than approximating their topology.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def vector(v):
    return [v['x'], v['y'], -v['z']]


def distribution(curve, time=0):
    import numpy as np
    if not math.isfinite(time): raise ValueError('Nonfinite curve sample time')
    keys = curve.get('m_Curve', [])
    if not keys:
        return 1.0
    if any(not math.isfinite(k[field]) for k in keys for field in ['time', 'value', 'inSlope', 'outSlope']):
        raise ValueError('Nonfinite distribution')
    if not math.isfinite(time) or any(k.get('weightedMode', 0) != 0 for k in keys):
        raise ValueError('Nonfinite sample time or weighted curve is unsupported')
    if any(a['time'] >= b['time'] for a, b in zip(keys, keys[1:])):
        raise ValueError('Curve keys must be strictly ordered')
    if time <= keys[0]['time']: return keys[0]['value']
    if time >= keys[-1]['time']: return keys[-1]['value']
    a, b = next((a, b) for a, b in zip(keys, keys[1:]) if a['time'] <= time <= b['time'])
    f = np.float32
    u = f(f(time - f(a['time'])) / f(f(b['time']) - f(a['time'])))
    smooth = f(f(u * u) * f(f(3) - f(f(2) * u)))
    base = f(f(a['value']) + f(f(f(b['value']) - f(a['value'])) * smooth))
    if a['outSlope'] == 0 and b['inSlope'] == 0: return float(base)
    duration = f(f(b['time']) - f(a['time']))
    h10 = f(f(f(u*u)*u) - f(f(2)*f(u*u)) + u)
    h11 = f(f(f(u*u)*u) - f(u*u))
    return float(f(f(base + f(f(h10 * f(a['outSlope'])) * duration)) + f(f(h11 * f(b['inSlope'])) * duration)))


def validate_topology(tree):
    if tree.get('m_Exclusions') or tree.get('m_notRolls'):
        raise ValueError('Exclusion/notRoll topology is not supported by this exporter')
    if tree['m_EndLength'] != 0 or any(tree['m_EndOffset'][k] != 0 for k in 'xyz'):
        raise ValueError('Virtual end particles are not implemented')
    if tree.get('m_DistantDisable'):
        raise ValueError('Distance-dependent disable is not implemented')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract(rigs: Path, maker_library: Path | None = None) -> dict:
    import UnityPy
    import numpy as np
    rigs = rigs.resolve()
    maker_library = maker_library.resolve() if maker_library is not None else None
    evidence = []
    def read(path):
        evidence.append({'path': str(path.relative_to(REPO)), 'sha256': digest(path)})
        return json.loads(path.read_text())
    bundle_cache = {}
    def bundle(name):
        if name in bundle_cache: return bundle_cache[name]
        path = rigs / 'source/abdata/chara' / (name + '.unity3d')
        proof = json.loads(path.with_suffix(path.suffix + '.provenance.json').read_text())
        hashed = digest(path)
        # Existing rig bundles use the same source-copy SHA-256 sidecar contract.
        expected = proof.get('sha256') or proof.get('source', {}).get('sha256')
        if expected != hashed:
            raise ValueError(f'Bundle provenance hash mismatch: {path}')
        evidence.append({'path': str(path.relative_to(REPO)), 'sha256': hashed})
        bundle_cache[name] = UnityPy.load(str(path))
        return bundle_cache[name]
    def identity(obj):
        return f'{obj.assets_file.name}:{obj.path_id}'
    def components(env, nodes):
        indices = {n['sourceID']: i for i, n in enumerate(nodes)}
        found = []
        for obj in env.objects:
            if obj.type.name != 'MonoBehaviour':
                continue
            behavior = obj.read()
            if not behavior.m_GameObject.path_id:
                continue
            go = behavior.m_GameObject.read()
            transform = next(c.component.deref() for c in go.m_Component if c.component.type.name == 'Transform')
            if identity(transform) not in indices:
                continue
            order = next(i for i, c in enumerate(go.m_Component) if c.component.path_id == obj.path_id)
            found.append((indices[identity(transform)], order, obj, behavior, obj.read_typetree()))
        return sorted(found, key=lambda x: (x[0], x[1]))
    body = read(rigs / 'body-skeleton.json')
    colliders = []
    for ni, _, obj, behavior, data in components(bundle('oo_base'), body['nodes']):
        if 'm_Bound' not in data or 'm_Radius' not in data:
            continue
        if behavior.m_Script.read().m_ClassName != 'DynamicBoneCollider':
            raise ValueError('Unrecognized collider variant')
        colliders.append({'nodeID': 'body-master/' + body['nodes'][ni]['sourceID'],
            'center': vector(data['m_Center']), 'radius': data['m_Radius'], 'height': data['m_Height'],
            'direction': data['m_Direction'], 'bound': data['m_Bound'], 'enabled': bool(data['m_Enabled'])})
    result = []
    hair_inputs = [(rigs / (name + '.json'), bundle_name, prefix, None) for name, bundle_name, prefix in
                   [('hair-back-rig', 'bo_hair_b_00', 'hair-0/'), ('hair-front-rig', 'bo_hair_f_00', 'hair-1/')]]
    if maker_library is not None:
        library = read(maker_library)
        hair_inputs = []
        for entry in library['entries']:
            if entry['category'] not in range(101, 105) or entry.get('empty'): continue
            if entry.get('modGUID') is not None: raise ValueError('This exporter requires original catalog hair entries; mod component contracts are separate')
            source = entry.get('source', {})
            asset = (maker_library.parent / entry['rig']['file']).resolve()
            if not asset.is_relative_to(maker_library.parent.resolve()) or digest(asset) != entry['rig']['sha256']:
                raise ValueError('Maker hair rig identity/hash mismatch')
            source_bundle = Path(source['bundle'])
            if source_bundle.parent != Path('chara') or source_bundle.suffix != '.unity3d':
                raise ValueError('This extractor requires an available original chara bundle')
            source_file = rigs / 'source/abdata' / source_bundle
            if source.get('bundleSHA256') != digest(source_file): raise ValueError('Maker library/source bundle identity mismatch')
            hair_inputs.append((asset, source_bundle.stem, f"hair-{entry['category'] - 101}/",
                                dict(category=entry['category'], id=entry['id'], modGUID=entry.get('modGUID'))))
    coverage = []
    for rig_path, bundle_name, prefix, asset_identity in hair_inputs:
        model = read(rig_path); nodes = model['nodes']
        component_start = len(result)
        children = [[] for _ in nodes]
        for i, node in enumerate(nodes):
            if node['parent'] is not None:
                children[node['parent']].append(i)
        worlds = []
        for node in nodes:
            x, y, z, w = map(np.float32, node['rotation'])
            r = np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                          [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                          [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]], dtype=np.float32)
            local = np.eye(4, dtype=np.float32); local[:3,:3] = r @ np.diag(np.array(node['scale'], dtype=np.float32))
            local[:3,3] = node['translation']
            worlds.append(local if node['parent'] is None else worlds[node['parent']] @ local)
        for ni, _, obj, behavior, data in components(bundle(bundle_name), nodes):
            if 'm_Root' not in data or 'm_Damping' not in data:
                continue
            if behavior.m_Script.read().m_ClassName != 'DynamicBone':
                raise ValueError('Unrecognized dynamics variant')
            if not data['m_Enabled']:
                continue
            validate_topology(data)
            root_ref = data['m_Root']
            if root_ref['m_FileID'] != 0:
                raise ValueError('External dynamic root is unsupported')
            root_id = f'{obj.assets_file.name}:{root_ref["m_PathID"]}'
            root = next(i for i, node in enumerate(nodes) if node['sourceID'] == root_id)
            particles = []
            lengths = []
            def visit(index, parent, distance=0):
                current = len(particles)
                particles.append({'nodeID': prefix + nodes[index]['sourceID'], 'nodeName': nodes[index]['name'], 'parent': parent})
                lengths.append(distance)
                for child in children[index]:
                    edge = np.linalg.norm(worlds[index][:3,3] - worlds[child][:3,3])
                    visit(child, current, float(np.float32(np.float32(distance) + edge)))
            visit(root, None)
            maximum = max(lengths)
            for particle, distance in zip(particles, lengths):
                rate = float(np.float32(distance) / np.float32(maximum)) if maximum > 0 else 0
                particle['lengthRate'] = rate
                for field in ['Damping', 'Elasticity', 'Stiffness', 'Inert', 'Radius']:
                    factor = distribution(data['m_' + field + 'Distrib'], rate) if maximum > 0 else 1
                    v = float(np.float32(data['m_' + field]) * np.float32(factor))
                    particle[field.lower()] = max(0.0, v) if field == 'Radius' else max(0.0, min(1.0, v))
            result.append({'sourceAsset': asset_identity, 'sourceID': identity(obj), 'rootName': nodes[root]['name'], 'ownerName': nodes[ni]['name'], 'ownerID': prefix + nodes[ni]['sourceID'],
                'updateRate': data['m_UpdateRate'], 'gravity': vector(data['m_Gravity']), 'force': vector(data['m_Force']),
                'freezeAxis': data['m_FreezeAxis'], 'particles': particles,
                'colliders': colliders if data['m_Colliders'] is not None else []})
        coverage.append({'rig': str(rig_path.relative_to(REPO)), 'sourceAsset': asset_identity, 'components': len(result) - component_start})
    index = read(REPO / '.local/reverse/managed-recovery/index.json')
    project = Path(index['assemblies'][0]['directory']) / 'project'
    for name in ['DynamicBone.cs', 'DynamicBoneCollider.cs', 'ChaControl.cs']:
        path = project / name
        evidence.append({'path': str(path.relative_to(REPO)), 'sha256': digest(path)})
    return {'schemaVersion': 1, 'coordinateSpace': 'native-right-handed-y-up', 'components': result,
            'evidence': evidence, 'assetCoverage': coverage,
            'scope': 'Selected/converted original hair real-node DynamicBone setup. Source replaces prefab collider slots with body colliders. Other variants, virtual ends, exclusions/notRolls and distance disabling are unsupported.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rigs', type=Path, default=REPO / '.local/reverse/rigs')
    parser.add_argument('--maker-library', type=Path, help='Export exact DynamicBone components for all converted original hair assets in this verified library')
    parser.add_argument('--output', type=Path, default=REPO / '.local/reverse/rigs/source-dynamics.json')
    args = parser.parse_args()
    if not args.output.resolve().is_relative_to((REPO / '.local').resolve()):
        parser.error('Original data must remain under .local')
    value = extract(args.rigs, args.maker_library)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(value, indent=2) + '\n')
    print(json.dumps({'components': len(value['components']), 'particles': sum(len(c['particles']) for c in value['components']),
                      'bodyColliders': len(value['components'][0]['colliders']) if value['components'] else 0}))


if __name__ == '__main__':
    main()
