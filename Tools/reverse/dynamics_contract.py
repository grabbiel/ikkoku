#!/usr/bin/env python3
"""Export the selected original hair and clothes DynamicBone setup, without rendering assets.

Hair supports the observed real-node, empty exclusion/notRoll and finite Hermite-distribution
configuration. Clothes (top/bottom) components follow ChaControl.LoadCharaFbxData's
copyDynamicBone remap onto the body bones and DynamicBone.AppendParticles exactly,
including notRoll chain truncation. Every other variant is rejected per component with a
named reason rather than approximated.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCHEMA_VERSION = 2
# ChaListDefine category -> ChaFileDefine.ClothesKind. AddObjectFemale.GetSkirtDynamic
# only inspects objClothes[0] (top) and objClothes[1] (bottom).
CLOTHES_KINDS = {105: 0, 106: 1}
# Studio Info.dicBoneInfo group whose names make a clothes component a "skirt" one.
SKIRT_BONE_GROUP = 13
REJECTION_REASONS = ('unsupported-version', 'prefab-disabled', 'inactive-object', 'owner-below-prefab-root',
                     'external-reference', 'root-not-in-body', 'exclusions', 'distant-disable', 'virtual-end',
                     'notroll-reparent', 'unsupported-curve', 'invalid-configuration')


class Rejected(ValueError):
    """A component variant this exporter refuses to approximate; `reason` is one of REJECTION_REASONS."""
    def __init__(self, reason, detail):
        if reason not in REJECTION_REASONS:
            raise ValueError('Unknown rejection reason: ' + reason)
        super().__init__(f'{reason}: {detail}')
        self.reason, self.detail = reason, detail


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


def migrate(document):
    """Upgrade a schema 1 (hair-only) document to schema 2 without changing any component data."""
    version = document.get('schemaVersion')
    if version == SCHEMA_VERSION:
        return document
    if version != 1:
        raise ValueError(f'Unsupported dynamics schema version: {version}')
    upgraded = dict(document, schemaVersion=SCHEMA_VERSION)
    upgraded['components'] = [dict(component, group='hair') for component in document['components']]
    upgraded['rejected'] = list(document.get('rejected', []))
    return upgraded


def append_particles(root, children, not_rolls=frozenset(), virtual_end=False):
    """DynamicBone.AppendParticles over a transform tree given as child index lists.

    Returns (node, parentParticle) pairs in source order. A child that is a notRoll is
    skipped; when one was skipped the source appends that notRoll's own children under
    the current particle. A transform with no children receives a virtual end particle
    when m_EndLength > 0 or m_EndOffset != 0. Exclusions are rejected by the caller.
    """
    particles = []

    def visit(node, parent):
        current = len(particles)
        particles.append((node, parent))
        skipped = None
        for index, child in enumerate(children[node]):
            if child in not_rolls:
                skipped = index
                continue
            visit(child, current)
        if skipped is not None:
            for grandchild in children[children[node][skipped]]:
                if grandchild in not_rolls:
                    continue
                raise Rejected('notroll-reparent', 'a notRoll child would re-parent its children under the grandparent particle')
        if not children[node] and virtual_end:
            raise Rejected('virtual-end', 'a leaf transform would receive a virtual end particle')

    visit(root, None)
    return particles


def subtree_contains(root, children, names, targets):
    """AddObjectFemale.CheckNameLoop: the root or any descendant carries a target name."""
    pending = [root]
    while pending:
        node = pending.pop()
        if names[node] in targets:
            return True
        pending.extend(children[node])
    return False


def particle_rates(particles, worlds):
    """Cumulative particle bone lengths normalized by m_BoneTotalLength, in float32."""
    import numpy as np
    lengths = []
    for node, parent in particles:
        if parent is None:
            lengths.append(0.0)
            continue
        edge = np.linalg.norm(worlds[particles[parent][0]][:3, 3] - worlds[node][:3, 3])
        lengths.append(float(np.float32(np.float32(lengths[parent]) + edge)))
    total = max(lengths)
    return [float(np.float32(length) / np.float32(total)) if total > 0 else 0 for length in lengths], total


def particle_parameters(data, rate, has_length):
    import numpy as np
    values = {}
    for field in ['Damping', 'Elasticity', 'Stiffness', 'Inert', 'Radius']:
        try:
            factor = distribution(data['m_' + field + 'Distrib'], rate) if has_length else 1
        except ValueError as error:
            raise Rejected('unsupported-curve', f'm_{field}Distrib: {error}') from error
        value = float(np.float32(data['m_' + field]) * np.float32(factor))
        values[field.lower()] = max(0.0, value) if field == 'Radius' else max(0.0, min(1.0, value))
    return values


def world_matrices(nodes):
    import numpy as np
    worlds = []
    for node in nodes:
        x, y, z, w = map(np.float32, node['rotation'])
        r = np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                      [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                      [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]], dtype=np.float32)
        local = np.eye(4, dtype=np.float32); local[:3,:3] = r @ np.diag(np.array(node['scale'], dtype=np.float32))
        local[:3,3] = node['translation']
        worlds.append(local if node['parent'] is None else worlds[node['parent']] @ local)
    return worlds


def child_lists(nodes):
    children = [[] for _ in nodes]
    for i, node in enumerate(nodes):
        if node['parent'] is not None:
            children[node['parent']].append(i)
    return children


def clothes_component(data, class_name, owner, clothes_nodes, body, skirt_names, cab):
    """One clothes DynamicBone after ChaControl's copyDynamicBone remap onto the body bones.

    `data` is the component typetree, `owner` the index of its GameObject in the clothes
    rig, `cab` the serialized file holding both, `body` a dict with nodes/children/worlds/
    byName. Returns the exported fields or
    raises Rejected. Particle transforms are body bones (m_Root/notRolls are re-bound by
    name to aaWeightsBody.dictBone); the owner stays the garment root.
    """
    if class_name != 'DynamicBone':
        raise Rejected('unsupported-version', class_name + ' is a separate DynamicBone system')
    scalars = [data['m_EndLength'], *data['m_EndOffset'].values(),
               *[data['m_' + field] for field in ['Damping', 'Elasticity', 'Stiffness', 'Inert', 'Radius']]]
    for field in ['m_UpdateRate']:
        if field in data: scalars.append(data[field])
    for field in ['m_Gravity', 'm_Force']:
        if field in data: scalars.extend(data[field].values())
    if not all(math.isfinite(value) for value in scalars):
        raise Rejected('invalid-configuration', 'nonfinite scalar/vector parameter')
    if not data['m_Enabled']:
        raise Rejected('prefab-disabled', 'Studio ActiveFKGroup would enable a disabled skirt component; not modelled')
    chain, cursor = [], owner
    while cursor is not None:
        chain.append(cursor); cursor = clothes_nodes[cursor]['parent']
    if any(not clothes_nodes[i].get('active', True) for i in chain):
        raise Rejected('inactive-object', 'GetSkirtDynamic skips components on inactive objects')
    if clothes_nodes[owner]['parent'] is not None:
        raise Rejected('owner-below-prefab-root', clothes_nodes[owner]['name'] + ' activity follows clothes-state switch nodes, which are not modelled')
    if data.get('m_Exclusions'):
        raise Rejected('exclusions', 'AppendParticles exclusion loop advances the child index, not the list index')
    if data.get('m_DistantDisable'):
        raise Rejected('distant-disable', 'distance-dependent disabling needs the main camera')
    by_source = {n['sourceID']: i for i, n in enumerate(clothes_nodes)}
    def local_name(ref, field):
        if ref['m_FileID'] != 0:
            raise Rejected('external-reference', field + ' references another serialized file')
        if not ref['m_PathID']:
            return None
        index = by_source.get(f"{cab}:{ref['m_PathID']}")
        if index is None:
            raise Rejected('external-reference', field + ' is not a transform of this prefab')
        return clothes_nodes[index]['name']
    root_name = local_name(data['m_Root'], 'm_Root')
    if root_name is None or root_name not in body['byName']:
        raise Rejected('root-not-in-body', f'm_Root {root_name!r} has no body bone of the same name')
    root = body['byName'][root_name]
    not_rolls = set()
    for ref in data.get('m_notRolls') or []:
        name = local_name(ref, 'm_notRolls')
        # Unmatched names keep the prefab transform, which never equals a body child.
        if name is not None and name in body['byName']:
            not_rolls.add(body['byName'][name])
    end = data['m_EndLength'] > 0 or any(data['m_EndOffset'][k] != 0 for k in 'xyz')
    particles = append_particles(root, body['children'], frozenset(not_rolls), end)
    rates, total = particle_rates(particles, body['worlds'])
    exported = []
    for (node, parent), rate in zip(particles, rates):
        exported.append(dict(nodeID='body-master/' + body['nodes'][node]['sourceID'], nodeName=body['nodes'][node]['name'],
                             parent=parent, lengthRate=rate, **particle_parameters(data, rate, total > 0)))
    group = 'skirt' if subtree_contains(root, body['children'], [n['name'] for n in body['nodes']], skirt_names) else 'clothes'
    return dict(group=group, rootName=root_name, notRolls=sorted(body['nodes'][i]['name'] for i in not_rolls),
                particles=exported, colliderSlots=data['m_Colliders'] is not None)


def extract(rigs: Path, maker_library: Path | None = None, pose_contract_path: Path | None = None) -> dict:
    import UnityPy
    import numpy as np
    from analysis.recovered_source import MAIN_GAME, RecoveredAssembly
    rigs = rigs.resolve()
    maker_library = maker_library.resolve() if maker_library is not None else None
    pose_contract_path = (pose_contract_path or REPO / '.local/reverse/studio-pose/contract.json').resolve()
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
        indices = {n['sourceID']: i for i, n in enumerate(nodes)}  # identity() == rig sourceID
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
    rejected = []
    hair_inputs = [(rigs / (name + '.json'), bundle_name, prefix, None) for name, bundle_name, prefix in
                   [('hair-back-rig', 'bo_hair_b_00', 'hair-0/'), ('hair-front-rig', 'bo_hair_f_00', 'hair-1/')]]
    clothes_inputs = []
    if maker_library is not None:
        library = read(maker_library)
        hair_inputs = []
        for entry in sorted(library['entries'], key=lambda e: (e['category'], e['id'])):
            if entry['category'] not in CLOTHES_KINDS or entry.get('empty'): continue
            if entry.get('modGUID') is not None: raise ValueError('This exporter requires original catalog clothes entries')
            source = entry.get('source', {})
            asset = (maker_library.parent / entry['rig']['file']).resolve()
            if not asset.is_relative_to(maker_library.parent.resolve()) or digest(asset) != entry['rig']['sha256']:
                raise ValueError('Maker clothes rig identity/hash mismatch')
            source_bundle = Path(source['bundle'])
            if source_bundle.parent != Path('chara') or source_bundle.suffix != '.unity3d':
                raise ValueError('This extractor requires an available original chara bundle')
            if source.get('bundleSHA256') != digest(rigs / 'source/abdata' / source_bundle):
                raise ValueError('Maker library/source bundle identity mismatch')
            clothes_inputs.append((asset, source_bundle.stem, CLOTHES_KINDS[entry['category']],
                                   dict(category=entry['category'], id=entry['id'], modGUID=None)))
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
            result.append({'sourceAsset': asset_identity, 'sourceID': identity(obj), 'group': 'hair', 'rootName': nodes[root]['name'], 'ownerName': nodes[ni]['name'], 'ownerID': prefix + nodes[ni]['sourceID'],
                'updateRate': data['m_UpdateRate'], 'gravity': vector(data['m_Gravity']), 'force': vector(data['m_Force']),
                'freezeAxis': data['m_FreezeAxis'], 'particles': particles,
                'colliders': colliders if data['m_Colliders'] is not None else []})
        coverage.append({'rig': str(rig_path.relative_to(REPO)), 'sourceAsset': asset_identity, 'components': len(result) - component_start})
    if clothes_inputs:
        pose_contract = read(pose_contract_path)
        skirt_names = frozenset(b['name'] for b in pose_contract['bones'] if b['group'] == SKIRT_BONE_GROUP)
        if len(skirt_names) != 48:
            raise ValueError('Studio bone catalog group 13 must list the 48 cf_j_sk bones')
        body_names = [n['name'] for n in body['nodes']]
        if len(set(body_names)) != len(body_names):
            raise ValueError('Body bone names must be unique for the copyDynamicBone name remap')
        body_rig = dict(nodes=body['nodes'], children=child_lists(body['nodes']), worlds=world_matrices(body['nodes']),
                        byName={name: i for i, name in enumerate(body_names)})
    clothes_behaviours = {}
    for rig_path, bundle_name, kind, asset_identity in clothes_inputs:
        model = read(rig_path); nodes = model['nodes']
        component_start, rejected_start = len(result), len(rejected)
        if bundle_name not in clothes_behaviours:
            # Every DynamicBone-family behaviour of the bundle, located by its GameObject transform.
            listed = []
            for obj in bundle(bundle_name).objects:
                if obj.type.name != 'MonoBehaviour':
                    continue
                behavior = obj.read()
                if not behavior.m_GameObject.path_id:
                    continue
                class_name = behavior.m_Script.read().m_ClassName
                if class_name not in ('DynamicBone', 'DynamicBone_Ver01', 'DynamicBone_Ver02'):
                    continue
                go = behavior.m_GameObject.read()
                transform = next(c.component.deref() for c in go.m_Component if c.component.type.name == 'Transform')
                order = next(i for i, c in enumerate(go.m_Component) if c.component.path_id == obj.path_id)
                listed.append((identity(transform), order, obj, class_name))
            clothes_behaviours[bundle_name] = listed
        indices = {n['sourceID']: i for i, n in enumerate(nodes)}
        found = [(indices[t], order, obj, class_name) for t, order, obj, class_name in clothes_behaviours[bundle_name] if t in indices]
        for ni, _, obj, class_name in sorted(found, key=lambda x: (x[0], x[1])):
            data = obj.read_typetree()
            try:
                fields = clothes_component(data, class_name, ni, nodes, body_rig, skirt_names, obj.assets_file.name)
            except Rejected as error:
                rejected.append({'sourceAsset': asset_identity, 'sourceID': identity(obj), 'class': class_name,
                                 'ownerName': nodes[ni]['name'], 'ownerID': f'clothes-{kind}/' + nodes[ni]['sourceID'],
                                 'reason': error.reason, 'detail': error.detail})
                continue
            result.append({'sourceAsset': asset_identity, 'sourceID': identity(obj), 'group': fields['group'], 'clothesKind': kind,
                'rootName': fields['rootName'], 'notRolls': fields['notRolls'], 'ownerName': nodes[ni]['name'],
                'ownerID': f'clothes-{kind}/' + nodes[ni]['sourceID'], 'updateRate': data['m_UpdateRate'],
                'gravity': vector(data['m_Gravity']), 'force': vector(data['m_Force']), 'freezeAxis': data['m_FreezeAxis'],
                'particles': fields['particles'], 'colliders': colliders if fields['colliderSlots'] else []})
        exported = result[component_start:]
        coverage.append({'rig': str(rig_path.relative_to(REPO)), 'sourceAsset': asset_identity, 'clothesKind': kind,
                         'components': len(exported), 'skirtComponents': sum(c['group'] == 'skirt' for c in exported),
                         'particles': sum(len(c['particles']) for c in exported),
                         'colliders': sum(len(c['colliders']) for c in exported),
                         'rejected': [r['reason'] for r in rejected[rejected_start:]]})
    index = REPO / '.local/reverse/managed-recovery/index.json'
    read(index)
    recovery = RecoveredAssembly(index, source_path=MAIN_GAME)
    for name in ['DynamicBone', 'DynamicBoneCollider', 'ChaControl']:
        source = recovery.source(name)
        evidence.append({'path': str(source.path.relative_to(REPO)), 'sha256': source.sha256})
    return {'schemaVersion': SCHEMA_VERSION, 'coordinateSpace': 'native-right-handed-y-up', 'components': result,
            'rejected': rejected, 'evidence': evidence, 'assetCoverage': coverage,
            'scope': 'Selected/converted original hair and top/bottom clothes real-node DynamicBone setup. Source replaces '
                     'prefab collider slots with body colliders and re-binds clothes roots/notRolls to body bones by name. '
                     'Groups: hair (FK group 0), skirt (Studio bone group 13 in the root subtree; FK group 6), clothes '
                     '(other garment components; never FK gated). Virtual end particles, exclusions, re-parenting notRolls, '
                     'distance disabling and the DynamicBone_Ver01/Ver02 systems are rejected per component.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rigs', type=Path, default=REPO / '.local/reverse/rigs')
    parser.add_argument('--maker-library', type=Path, help='Export exact DynamicBone components for all converted original hair, top and bottom assets in this verified library')
    parser.add_argument('--pose-contract', type=Path, help='Studio pose contract whose bone group 13 classifies skirt components (default .local/reverse/studio-pose/contract.json)')
    parser.add_argument('--output', type=Path, default=REPO / '.local/reverse/rigs/source-dynamics.json')
    args = parser.parse_args()
    if not args.output.resolve().is_relative_to((REPO / '.local').resolve()):
        parser.error('Original data must remain under .local')
    value = extract(args.rigs, args.maker_library, args.pose_contract)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(value, indent=2) + '\n')
    groups = {}
    for component in value['components']:
        groups[component['group']] = groups.get(component['group'], 0) + 1
    print(json.dumps({'components': len(value['components']), 'groups': groups,
                      'particles': sum(len(c['particles']) for c in value['components']),
                      'bodyColliders': len(value['components'][0]['colliders']) if value['components'] else 0,
                      'rejected': len(value['rejected']), 'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
