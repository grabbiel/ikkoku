#!/usr/bin/env python3
"""Replay a running-Unity motion capture through the independent float32 oracle.

The original capture (OriginalDynamicsProbe.cs motion mode) seeds the
integrator from the reset state written by OnEnable, drives a scripted
character root path for a fixed frame count at a locked 1/60 step and records
every particle world position after LateUpdate. Because the original Update()
restores bind locals on every frame while m_Weight > 0, the LateUpdate
hierarchy is exactly the bind chain under the animated avatar root: replaying
therefore only overrides 'avatar:root' with the recorded avatar world
transform (the same input model as the dynamics_reference original_document
scenarios). The recorded per-frame root/owner/collider world positions are not
replay inputs; the replay predicts them from the same hierarchy and reports
the largest deviation, so a hidden body animation, shared root or extra
collider refutes the model instead of silently perturbing the comparison.

Particle world positions are the compared quantity. Applied rotations are
recorded context only: the original ApplyParticlesToTransforms mixes parent
up/right directions in a context-dependent branch that the oracle does not
model.
"""
from __future__ import annotations
import copy
import hashlib
import json
from pathlib import Path

import numpy as np

from dynamics_reference import ParticleReference, axis_rotation, collider, hierarchy, node

F = np.float32


def frame(value):
    """Unity-space world position/translation <-> oracle space (z mirror)."""
    return [float(F(value[0])), float(F(value[1])), float(F(-value[2]))]


def orientation(value):
    """Unity-space world quaternion <-> oracle space (x,y negated; involution)."""
    return [float(F(-value[0])), float(F(-value[1])), float(value[2]), float(value[3])]


def distance(a, b):
    return float(np.linalg.norm(np.asarray(a, dtype=np.float32) - np.asarray(b, dtype=np.float32)))


def matrix_orientation(matrix):
    """Serialize an oracle 3x3 world rotation as a Unity-space world quaternion.

    Used only by the synthetic capture to record the world rotations a real
    capture reads straight from Transform.rotation; the replay reconstructs
    them through the involutive orientation conversion.
    """
    m = np.asarray(matrix, dtype=np.float32)
    trace = float(m[0, 0] + m[1, 1] + m[2, 2])
    if trace > 0:
        s = np.float32(np.sqrt(trace + 1.0)) * 2
        q = [float((m[2, 1] - m[1, 2]) / s), float((m[0, 2] - m[2, 0]) / s), float((m[1, 0] - m[0, 1]) / s),
             float(np.float32(0.25) * s)]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.float32(np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2])) * 2
        q = [float(np.float32(0.25) * s), float((m[0, 1] + m[1, 0]) / s), float((m[0, 2] + m[2, 0]) / s),
             float((m[2, 1] - m[1, 2]) / s)]
    elif m[1, 1] > m[2, 2]:
        s = np.float32(np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2])) * 2
        q = [float((m[0, 1] + m[1, 0]) / s), float(np.float32(0.25) * s), float((m[1, 2] + m[2, 1]) / s),
             float((m[0, 2] - m[2, 0]) / s)]
    else:
        s = np.float32(np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1])) * 2
        q = [float((m[0, 2] + m[2, 0]) / s), float((m[1, 2] + m[2, 1]) / s), float(np.float32(0.25) * s),
             float((m[1, 0] - m[0, 1]) / s)]
    return orientation(q)


def identity_matches(definition, seed, frame_row, index):
    # The scene component identity is its root transform name. The owner
    # GameObject is renamed when the prefab is assembled into the character
    # (for example p_cf_hair_b_01 becomes ct_hairB), exactly as the verified
    # numeric comparison keys components by root name only.
    if definition['rootName'] != seed['rootName'] or definition['rootName'] != frame_row['rootName']:
        raise ValueError(f'Motion component {index} root does not match the contract')
    if len(seed['particles']) != len(definition['particles']) or len(frame_row['particles']) != len(definition['particles']):
        raise ValueError(f'Motion component {index} particle count does not match the contract')
    if len(frame_row['colliders']) != len(definition['colliders']):
        raise ValueError(f'Motion component {index} collider count does not match the contract')
    for row, contract in zip(seed['particles'], definition['particles']):
        if row['name'] != contract['nodeName']:
            raise ValueError(f'Motion component {index} seed particle order does not match the contract')
    for row, contract in zip(frame_row['particles'], definition['particles']):
        if row['name'] != contract['nodeName']:
            raise ValueError(f'Motion component {index} frame particle order does not match the contract')


def replay_component(scenario, seed, frames, tolerance):
    """Diagnostic model: the bind hierarchy under the recorded avatar root.

    Rebuilding the body hierarchy from the bind rig under the recorded avatar
    world transform is refuted by the capture: the predicted root deviates by
    ~0.13 m, constant in the character frame, and colliders by ~0.11 m (the
    live scene reposes/re-scales bones the rig mirror does not carry). Keep it
    as a rigidity diagnostic only; the parity gate is the recorded-input mode.
    """
    nodes, definition = scenario['nodes'], scenario['definition']
    if definition['colliders'] and not all(c['enabled'] for c in definition['colliders']):
        raise ValueError('Contract has a disabled collider while the motion capture enables every hair collider')
    solver = ParticleReference(nodes, definition)
    solver.positions = np.array([frame(p['position']) for p in seed['particles']], dtype=np.float32)
    solver.previous = np.array([frame(p['previousPosition']) for p in seed['particles']], dtype=np.float32)
    solver.owner_position = np.array(frame(seed['owner']), dtype=np.float32)
    solver.time = F(seed['time'])
    solver.weight = F(seed['weight'])
    avatar = solver.indices['avatar:root']
    owner_node = solver.indices[definition['ownerID']]
    root_node = solver.node_indices[0]
    collider_nodes = [solver.indices[c['nodeID']] for c in definition['colliders']]
    maximum, worst_frame = 0.0, 0.0
    step_counts = set()
    maxima = dict(rootPosition=0.0, ownerPosition=0.0, colliderRigidity=0.0)
    for index, row in enumerate(frames):
        current = copy.deepcopy(nodes)
        current[avatar]['translation'] = frame(row['avatar']['position'])
        current[avatar]['rotation'] = orientation(row['avatar']['rotation'])
        advanced = solver.advance(current, float(F(row['deltaTime'])))
        step_counts.add(advanced['lastStepCount'])
        worlds, _ = hierarchy(current)
        component = row['components'][0]
        for particle, predicted in zip(component['particles'], advanced['positions']):
            error = distance(frame(particle['position']), predicted)
            if error > maximum:
                maximum, worst_frame = error, float(index)
        maxima['rootPosition'] = max(maxima['rootPosition'],
            distance(frame(component['root']['position']), worlds[root_node][:3, 3]))
        maxima['ownerPosition'] = max(maxima['ownerPosition'],
            distance(frame(component['owner']), worlds[owner_node][:3, 3]))
        predicted_colliders = [worlds[i][:3, 3] for i in collider_nodes]
        for recorded in component['colliders']:
            target = frame(recorded['position'])
            maxima['colliderRigidity'] = max(maxima['colliderRigidity'],
                min(distance(target, predicted) for predicted in predicted_colliders))
    return dict(model='bind-hierarchy diagnostic', rootName=definition['rootName'], ownerName=definition['ownerName'],
        particles=len(definition['particles']), colliders=len(definition['colliders']),
        maxParticleError=maximum, worstFrame=worst_frame,
        stepCounts=dict(min=min(step_counts), max=max(step_counts)),
        withinTolerance=maximum <= tolerance,
        **{'max' + key[0].upper() + key[1:]: value for key, value in maxima.items()})


def recorded_inputs(scenario, seed, row):
    """Per-frame hierarchy fed to the integrator in the recorded-input model.

    Only the transforms the integrator reads are replaced by the original's
    recorded world values: the root node carries the recorded root world
    transform (world-level, unit scale); every particle below the root keeps
    the bind local translation that InitTransforms restores, scaled uniformly
    by the seed objectScale (the capture records no per-transform lossy
    scale); the owner node carries the recorded owner world position with
    objectScale as its scale (it drives owner-move inertia and the gravity,
    force and particle-radius scale); every collider node carries its recorded
    world transform with objectScale as its scale, because the collider
    radius is multiplied by the collider's own lossy scale, which the capture
    does not record. Documented assumption, not a measured input.
    """
    nodes = copy.deepcopy(scenario['nodes'])
    indices = {n['sourceID']: i for i, n in enumerate(nodes)}
    definition = scenario['definition']
    scale = F(seed['objectScale'])
    root = indices[definition['particles'][0]['nodeID']]
    nodes[root].update(parent=None, translation=frame(row['root']['position']),
                       rotation=orientation(row['root']['rotation']), scale=[1., 1., 1.])
    for particle in definition['particles'][1:]:
        entry = nodes[indices[particle['nodeID']]]
        entry['translation'] = [float(F(F(c) * scale)) for c in entry['translation']]
    owner = indices[definition['ownerID']]
    nodes[owner].update(parent=None, translation=frame(row['owner']), rotation=[0., 0., 0., 1.],
                        scale=[float(scale)] * 3)
    for entry, recorded in zip(definition['colliders'], row['colliders']):
        node = nodes[indices[entry['nodeID']]]
        node.update(parent=None, translation=frame(recorded['position']),
                    rotation=orientation(recorded['rotation']), scale=[float(scale)] * 3)
    return nodes


def replay_recorded(scenario, seed, frames, tolerance):
    """Parity model: the integrator receives only recorded world transforms.

    The root is particle 0 and every step re-reads its world position, so the
    integrator sees exactly the recorded root path; below it the bind-locals
    times objectScale mirror InitTransforms under the live scaled hierarchy,
    and colliders are driven at their recorded transforms.
    """
    definition = scenario['definition']
    solver = ParticleReference(scenario['nodes'], definition)
    solver.positions = np.array([frame(p['position']) for p in seed['particles']], dtype=np.float32)
    solver.previous = np.array([frame(p['previousPosition']) for p in seed['particles']], dtype=np.float32)
    solver.owner_position = np.array(frame(seed['owner']), dtype=np.float32)
    solver.time = F(seed['time'])
    solver.weight = F(seed['weight'])
    maximum, worst_frame, first_exceeded, worst_particle = 0.0, 0.0, None, None
    step_counts = set()
    rest_offset_ratio = None
    if len(definition['particles']) > 1:
        # Scale check: the OnEnable seed holds the live bind rest world
        # positions, so the recorded rest offset of particle 1 from the root
        # (particle 0) is seed[1]-seed[0]; a uniform live scale factor makes it
        # k * (bind local translation norm). Norms are rotation-invariant.
        rest = np.subtract(frame(seed['particles'][1]['position']), frame(seed['particles'][0]['position']))
        bind = np.linalg.norm(np.asarray(scenario['nodes'][solver.node_indices[1]]['translation'], dtype=np.float32))
        if bind > 1e-5:
            rest_offset_ratio = float(np.linalg.norm(rest) / (float(F(seed['objectScale'])) * bind))
    for index, row in enumerate(frames):
        current = recorded_inputs(scenario, seed, row)
        advanced = solver.advance(current, float(F(row['deltaTime'])))
        step_counts.add(advanced['lastStepCount'])
        for i, (particle, predicted) in enumerate(zip(row['particles'], advanced['positions'])):
            error = distance(frame(particle['position']), predicted)
            if error > maximum:
                maximum, worst_frame, worst_particle = error, float(index), particle['name']
            if first_exceeded is None and error > tolerance:
                first_exceeded = dict(frame=float(index), particle=particle['name'], error=error)
    return dict(model='recorded inputs', rootName=definition['rootName'], ownerName=definition['ownerName'],
        particles=len(definition['particles']), colliders=len(definition['colliders']),
        objectScale=float(F(seed['objectScale'])),
        restOffsetBindRatio=rest_offset_ratio,
        maxParticleError=maximum, worstFrame=worst_frame, worstParticle=worst_particle,
        firstExceeded=first_exceeded,
        stepCounts=dict(min=min(step_counts), max=max(step_counts)),
        withinTolerance=maximum <= tolerance)


def compare(capture, document, tolerance=1e-4):
    """Compare recorded original particle motion with the oracle replay."""
    if capture.get('schemaVersion') != 1:
        raise ValueError('Unsupported motion capture schema')
    frames = capture['frames']
    if not frames or len(frames) != capture['frameCount']:
        raise ValueError('Motion frame count does not match the recorded frames')
    if len(capture['components']) != len(document['scenarios']):
        raise ValueError('Motion capture and oracle component counts differ')
    for frame_row in frames:
        if len(frame_row['components']) != len(capture['components']):
            raise ValueError('Motion frame component count differs from the capture seed')
    scenarios = {}
    for scenario in document['scenarios']:
        key = scenario['definition']['rootName']
        if key in scenarios:
            raise ValueError('Oracle contract has duplicate component root identity')
        scenarios[key] = scenario
    results = []
    for index, seed in enumerate(capture['components']):
        key = seed['rootName']
        if key not in scenarios:
            raise ValueError(f'Motion component {index} identity is not in the oracle contract')
        scenario = scenarios[key]
        for frame_row in frames:
            identity_matches(scenario['definition'], seed, frame_row['components'][index], index)
        bind_frames = [dict(deltaTime=f['deltaTime'], avatar=f['avatar'], components=[f['components'][index]])
                       for f in frames]
        results.append(replay_component(scenario, seed, bind_frames, tolerance))
        results.append(replay_recorded(scenario, seed,
            [dict(deltaTime=f['deltaTime'], **f['components'][index]) for f in frames], tolerance))
    gate = [row for row in results if row['model'] == 'recorded inputs']
    worst = max(gate, key=lambda row: row['maxParticleError'])
    return dict(schemaVersion=1, tolerance=tolerance, frameCount=len(frames),
        scope='Recorded original DynamicBone particle positions compared with the independent float32 replay seeded from the same reset state: the parity gate replays only recorded world inputs (root, owner, colliders, deltaTime) with bind locals scaled by objectScale; the bind-hierarchy-under-recorded-avatar model is kept as a rigidity diagnostic; particle world positions compared, applied rotations recorded as context only',
        components=results, maxParticleError=worst['maxParticleError'],
        worstComponent=worst['rootName'], worstFrame=worst['worstFrame'],
        passed=all(row['withinTolerance'] for row in gate))


def original_scene_document(rigs, contract, hair_ids, maker_library):
    """Oracle document for the hair actually assembled by the fresh fixture.

    The controlled clothed fixture selects Maker hair ids (back ``hair_ids[0]``
    and front ``hair_ids[1]``), which live in different asset bundles than the
    canonical ``source-avatar.json`` manifest that
    ``dynamics_reference.original_document`` assembles. This builder mirrors
    that function's hierarchy conversion exactly (translation z mirror,
    quaternion x,y negation, copy locals for the head file, hair attached at
    ``head-master/cf_J_FaceUp_ty``) but attaches the two asset rigs selected
    by the provenance-verified maker contract. Components are keyed by root
    transform name because assembly renames the prefab owner GameObject.
    """
    def read(path):
        return json.loads(Path(path).read_text())
    selected = []
    for component in contract['components']:
        asset = component.get('sourceAsset')
        if asset is None or asset['category'] not in (101, 102) or asset.get('modGUID') is not None:
            continue
        if asset['id'] != hair_ids[asset['category'] - 101]:
            continue
        selected.append(component)
    if not selected:
        raise ValueError('Maker contract has no components for the fixture-selected hair ids')
    manifest = read(Path(rigs) / 'source-avatar.json')
    nodes = [node('avatar:root')]
    by_name = {}

    def append(raw, prefix, attachment, copy_locals=None):
        offset = len(nodes)
        for original in raw['nodes']:
            source = (copy_locals or {}).get(original['name'], original)
            t = list(source['translation']); t[2] = -t[2]
            q = list(source['rotation']); q[0] = -q[0]; q[1] = -q[1]
            nodes.append(node(prefix + '/' + original['sourceID'], attachment if original['parent'] is None else offset + original['parent'],
                              t, source['scale'], q))
            by_name[(prefix, original['name'])] = len(nodes) - 1

    append(read(Path(rigs) / manifest['bodySkeleton']), 'body-master', 0)
    source_locals = {n['name']: n for n in read(Path(rigs) / manifest['head']['file'])['nodes']}
    append(read(Path(rigs) / manifest['headSkeleton']), 'head-master', by_name['body-master', 'cf_s_head'], source_locals)
    asset_paths = []
    for category, asset_id in sorted({(c['sourceAsset']['category'], c['sourceAsset']['id']) for c in selected}):
        prefix = f'hair-{category - 101}'
        rig_path = Path(maker_library) / 'assets' / f'{category}-{asset_id}' / 'rig.json'
        # The contract was emitted with a sha256 for every asset rig it read;
        # a rig file that no longer hashes to that value is a different model.
        suffix = f"maker-library/assets/{category}-{asset_id}/rig.json"
        expected = [e['sha256'] for e in contract['evidence'] if e['path'].endswith(suffix)]
        if len(expected) != 1 or hashlib.sha256(rig_path.read_bytes()).hexdigest() != expected[0]:
            raise ValueError(f'Asset rig identity differs from the maker contract evidence: {rig_path}')
        asset_paths.append(rig_path)
        append(read(rig_path), prefix, by_name['head-master', 'cf_J_FaceUp_ty'])
    indices = {entry['sourceID']: i for i, entry in enumerate(nodes)}
    for component in selected:
        for particle in component['particles']:
            if particle['nodeID'] not in indices:
                raise ValueError('Contract particle is outside the assembled scene hierarchy')
        if component['ownerID'] not in indices:
            raise ValueError('Contract owner is outside the assembled scene hierarchy')
        for entry in component['colliders']:
            if entry['nodeID'] not in indices:
                raise ValueError('Contract collider is outside the assembled scene hierarchy')
            if not entry['enabled']:
                raise ValueError('Contract has a disabled collider while the motion capture enables every hair collider')
    return dict(schemaVersion=1, scenarios=[dict(name=f"scene-hair-{c['sourceAsset']['category']}-{c['rootName']}",
        nodes=nodes, definition=c, frames=[]) for c in selected],
        hierarchyRigs=[str(path.resolve()) for path in asset_paths])


def synthetic_rig():
    """Branched chain plus capsule collider, shaped like the motion probe input."""
    # The collider node keeps a uniform scale: the recorded-input model drives
    # every collider with the seed objectScale because the capture records no
    # per-collider lossy scale, so a non-uniform synthetic scale could not be
    # replayed exactly. Non-uniform collider scale is covered by the
    # dynamics_reference scenarios, not the motion replay.
    nodes = [node('avatar:root'), node('owner', 0, (.02, .9, -.1)),
             node('root', 1, (.05, .12, .03)), node('middle', 2, (.04, -.3, .02)),
             node('tip', 3, (-.03, -.28, .05)), node('branch', 2, (-.2, -.15, -.06)),
             node('collider', 0, (.1, .5, .18), (1, 1, 1), axis_rotation(1, .4))]
    particles = [dict(nodeID=n, nodeName=n, parent=p, damping=.14 + i * .04, elasticity=.18 + i * .03,
                      stiffness=.3, inert=.25 + i * .12, radius=.05)
                 for i, (n, p) in enumerate([('root', None), ('middle', 0), ('tip', 1), ('branch', 0)])]
    capsule = collider(2, 0, .9)
    capsule.update(nodeID='collider', center=[.04, -.06, .09])
    definition = dict(rootName='root', ownerName='owner', ownerID='owner', sourceID='synthetic-motion',
        updateRate=60, gravity=[0, -.05, .012], force=[.011, 0, -.007], freezeAxis=0,
        particles=particles, colliders=[capsule])
    return nodes, definition


def synthetic_capture(frames=12):
    """Generate a capture-shaped file from the oracle alone (no original data).

    The scripted frames mirror the original motion probe (locked 1/60 step,
    swaying plus yawing root). Values are serialized in Unity space through
    the same involutive conversion the replay applies, so an exact replay of
    this file must report zero error.
    """
    nodes, definition = synthetic_rig()
    solver = ParticleReference(nodes, definition)
    avatar = solver.indices['avatar:root']
    owner_node = solver.indices['owner']
    collider_node = solver.indices['collider']
    paths = [([float(F(np.sin(i * .11) * .34)), 0, float(F(np.sin(i * .165) * .55))],
              axis_rotation(2, float(F(np.sin(i * .14) * .5 + np.sin(i * .43) * .07)))) for i in range(frames)]
    seed_particles = [dict(name=p['nodeID'], position=frame(np.asarray(solver.positions[i], dtype=np.float32)),
                           previousPosition=frame(np.asarray(solver.previous[i], dtype=np.float32)))
                      for i, p in enumerate(definition['particles'])]
    seed = [dict(rootName=definition['rootName'],
        owner=frame(np.asarray(solver.owner_position, dtype=np.float32)),
        weight=float(solver.weight), time=float(solver.time), objectMove=[0, 0, 0], objectScale=1.0,
        particles=seed_particles)]
    recorded = []
    for index in range(frames):
        # paths holds oracle-space values; the capture file serializes them to
        # Unity space with the involutive conversion, and replay converts back.
        current = copy.deepcopy(nodes)
        current[avatar]['translation'] = list(paths[index][0])
        current[avatar]['rotation'] = list(paths[index][1])
        advanced = solver.advance(current, float(F(1 / 60)))
        worlds, rotations = hierarchy(current)
        # Root and collider world rotations are serialized through the same
        # involutive conversion the replay applies, so a recorded-input replay
        # reconstructs the exact inputs the original integrator saw.
        recorded.append(dict(deltaTime=float(F(1 / 60)),
            character=frame(paths[index][0]),
            avatar=dict(position=frame(paths[index][0]), rotation=orientation(paths[index][1])),
            components=[dict(ownerName=definition['ownerName'], rootName=definition['rootName'],
                owner=frame(worlds[owner_node][:3, 3]),
                root=dict(position=frame(worlds[solver.node_indices[0]][:3, 3]),
                          rotation=matrix_orientation(rotations[solver.node_indices[0]])),
                particles=[dict(name=p['nodeID'], position=frame(predicted), rotation=[0, 0, 0, 1])
                           for p, predicted in zip(definition['particles'], advanced['positions'])],
                colliders=[dict(name='collider', position=frame(worlds[collider_node][:3, 3]),
                                rotation=matrix_orientation(rotations[collider_node]))])]))
    return dict(schemaVersion=1, scope='synthetic motion capture generated by the float32 oracle for replay tests',
        components=seed, frameCount=frames, fixedRateHz=60,
        colliders=dict(count=1, uniqueCount=1, names=['collider'], enabled=[True]), frames=recorded)


def synthetic_document():
    """Matching oracle document (scenario layout) for synthetic_capture."""
    nodes, definition = synthetic_rig()
    return dict(scenarios=[dict(name='synthetic-motion', nodes=nodes, definition=definition, frames=[])])
