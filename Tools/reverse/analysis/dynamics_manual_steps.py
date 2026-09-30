#!/usr/bin/env python3
"""Analyse the manual-step intermediates recorded inside the running original.

The motion fixture's manual-step sub-mode rolls one frame back to its
frame-start snapshot, re-runs the private chain by reflection (InitTransforms
-> UpdateDynamicBones prologue -> UpdateParticles1 -> UpdateParticles2 ->
ApplyParticlesToTransforms) and records every intermediate m_Position, each
bone's live localToWorldMatrix (whose column 3 UpdateParticles2 replaces with
the parent particle's current m_Position), the child localPosition and live
bone length, and the RUNTIME m_Damping/m_Elasticity/m_Stiffness/m_Inert/
m_Radius plus m_Weight. This module re-predicts UpdateParticles2 from exactly
those recorded inputs -- the elasticity pull, the double-rounded stiffness
limit, every collider at particle radius m_Radius * m_ObjectScale through the
oracle's collide(), and the final bone-length projection -- and reports the
residual against the recorded post-UpdateParticles2 m_Position, so the
remaining one-step gate error can be attributed to inputs rather than formula.

Everything runs in the capture's own coordinate space: the predictor consumes
rows exactly as serialized (column-major matrix, Unity quaternion/lossyScale)
and the oracle's collide()/projection arithmetic is space-agnostic, so no
z-mirroring is applied anywhere here.

synthetic_manual_capture produces the same row schema from the oracle alone
(no original data), so the tests prove the predictor's matrix, chain-order and
collider plumbing is exact and that deleting the collider rows changes the
prediction.
"""
from __future__ import annotations

import copy

import numpy as np

from dynamics_reference import F, ParticleReference, collide, hierarchy, length, rotation, v
from dynamics_motion_replay import distance, synthetic_rig

PARAMETERS = ('damping', 'elasticity', 'stiffness', 'inert', 'radius')


def unity_matrix(flat):
    """Column-major 16-float localToWorldMatrix (as recorded) -> 4x4 float32."""
    return np.asarray(flat, dtype=np.float32).reshape(4, 4).T.copy()


def collider_matrix(row):
    """World 4x4 of a recorded collider from its position, rotation and lossyScale."""
    matrix = np.eye(4, dtype=np.float32)
    matrix[:3, :3] = (rotation(row['rotation']) * v(row['lossyScale'])).astype(np.float32)
    matrix[:3, 3] = v(row['position'])
    return matrix


def predict_particles2(step, collider_rows, parameters, weight, object_scale, colliders=True):
    """Re-run UpdateParticles2 from the recorded post-UpdateParticles1 positions.

    The loop mirrors DynamicBone.UpdateParticles2 per particle in chain order:
    the recorded parent localToWorldMatrix with column 3 replaced by the
    parent particle's CURRENT m_Position (already updated by this very method
    for earlier particles -- the positions dict is mutated chain-wise, which
    is what makes deep chains reproduce), the elasticity pull toward the
    recorded localPosition, the stiffness limit, every collider, and the final
    bone-length projection. Returns name -> predicted position.
    """
    predicted = {row['name']: v(row['position']) for row in step['afterParticles1']}
    for row in step['beforeParticles2']:
        name, parent = row['name'], row['parentName']
        parameter = parameters[name]
        rest = F(row['restLength'])
        stiffness = F(F(1) + F(F(parameter['stiffness']) - F(1)) * F(weight))
        position = predicted[name]
        if stiffness > 0 or parameter['elasticity'] > 0:
            matrix = unity_matrix(row['parentMatrix'])
            matrix[:3, 3] = predicted[parent]
            desired = matrix[:3, :3] @ v(row['localPosition']) + matrix[:3, 3]
            position = position + (desired - position) * F(parameter['elasticity'])
            if stiffness > 0:
                delta = desired - position
                span = length(delta)
                limit = F(F(rest * F(F(1) - stiffness)) * F(2))
                if span > limit:
                    position = position + delta * F(F(span - limit) / span)
        if colliders:
            radius = F(F(parameter['radius']) * F(object_scale))
            for entry in collider_rows:
                position = collide(position, radius, dict(radius=F(entry['radius']), height=F(entry['height']),
                    center=v(entry['center']), direction=int(entry['direction']),
                    bound=int(entry['bound']), enabled=True), collider_matrix(entry))
        delta = predicted[parent] - position
        span = length(delta)
        if span > 0:
            position = position + delta * F(F(span - rest) / span)
        predicted[name] = position
    return predicted


def runtime_parameters(seed_component):
    """Seed row -> ({name: {damping, elasticity, stiffness, inert, radius}}, m_Weight)."""
    rows = seed_component['runtime']
    return ({row['name']: {key: F(row[key]) for key in PARAMETERS} for row in rows[1:]}, F(rows[0]['weight']))


def relative_delta(a, b):
    return abs(float(a) - float(b)) / max(abs(float(b)), 1e-8)


def runtime_parameter_report(capture, contract):
    """Hypotheses (1)+(2): recorded runtime values vs the maker contract.

    The fixture serializes floats through C# InvariantCulture, so an identical
    float32 round-trips within a relative 1e-6; a larger delta would mean the
    runtime values really differ from the contract. Also reports the largest
    runtime m_Stiffness (hypothesis (2) predicted a constant 1) and whether
    the values stay constant across the frames that re-record them. The
    contract lists every hair variant, so only the components for the
    fixture-selected hair ids are kept, mirroring the asset-rig selection of
    dynamics_motion_replay.original_scene_document.
    """
    def selected(component):
        asset = component.get('sourceAsset')
        if asset is None or 'hairIDs' not in capture:
            return True
        return (asset['category'] in (101, 102) and asset.get('modGUID') is None
            and asset['id'] == capture['hairIDs'][asset['category'] - 101])
    components = {}
    for component in contract['components']:
        if selected(component):
            if component['rootName'] in components:
                raise ValueError('contract repeats a selected component root ' + component['rootName'])
            components[component['rootName']] = component
    maximum, by_key, off, stiffness_values, stable = 0.0, {key: 0.0 for key in PARAMETERS}, [], [], True
    for seed_component in capture['components']:
        runtime, _ = runtime_parameters(seed_component)
        contract_particles = {particle['nodeName']: particle for particle in components[seed_component['rootName']]['particles']}
        for name, values in runtime.items():
            for key in PARAMETERS:
                delta = relative_delta(values[key], contract_particles[name][key])
                maximum = max(maximum, delta)
                by_key[key] = max(by_key[key], delta)
                if delta > 1e-6:
                    off.append(dict(component=seed_component['rootName'], particle=name, key=key))
            stiffness_values.append(float(values['stiffness']))
    for frame_row in capture['frames']:
        for component in frame_row.get('components', []):
            if 'runtime' not in component:
                continue
            runtime, weight = runtime_parameters(component)
            seed, seed_weight = runtime_parameters(next(s for s in capture['components']
                if s['rootName'] == component['rootName']))
            stable = stable and weight == seed_weight and all(relative_delta(value, seed[name][key]) <= 1e-6
                for name, values in runtime.items() for key, value in values.items())
    return dict(maxRuntimeContractDelta=maximum, maxRuntimeContractDeltaByKey=by_key,
        runtimeOffContract=off, maxRuntimeStiffness=max(stiffness_values) if stiffness_values else None,
        runtimeStableAcrossFrames=stable)


def collider_pushes(collider_rows, parameters, object_scale, step):
    """(collider, particle, push) for every single-collider overlap of the
    post-UpdateParticles1 positions (diagnostic only; the prediction applies
    the colliders cumulatively in the source's order)."""
    pushes = []
    for entry in collider_rows:
        matrix = collider_matrix(entry)
        for row in step['afterParticles1']:
            parameter = parameters[row['name']]
            pushed = collide(v(row['position']), F(F(parameter['radius']) * F(object_scale)),
                dict(radius=F(entry['radius']), height=F(entry['height']), center=v(entry['center']),
                    direction=int(entry['direction']), bound=int(entry['bound']), enabled=True), matrix)
            delta = distance(pushed, row['position'])
            if delta > 1e-4:
                pushes.append(dict(collider=entry['name'], particle=row['name'], push=delta))
    return pushes


def manual_step_report(capture, contract=None, tolerance=1e-4):
    """Residuals and hypothesis evidence for every recorded manual step.

    maxResidual compares the re-prediction from the recorded inputs;
    maxResidualWithoutColliders ablates the frame's collider rows;
    maxOfficialDelta compares the recorded post-UpdateParticles2 position with
    the official frame-end m_Position (0.0 proves the recording dry run left
    the integrator state bit-identical); maxParentBlockSpread is the largest
    entrywise difference between the localToWorldMatrix blocks read inside one
    frame, and maxAvatarBlockDelta compares that block with the recorded
    avatar rotation times the preamble m_ObjectScale (hypothesis (3): which
    transform's live world matrix UpdateParticles2 actually used).
    """
    frames = []
    for index, frame_row in enumerate(capture['frames']):
        stepped = [component for component in frame_row['components'] if component.get('manualSteps')]
        if not stepped:
            continue
        blocks, per_component = [], []
        for component in stepped:
            step = component['manualSteps'][0]
            seed_component = next(s for s in capture['components'] if s['rootName'] == component['rootName'])
            parameters, weight = runtime_parameters(seed_component)
            scale = step['preamble']['objectScale']
            predicted = predict_particles2(step, frame_row.get('colliders', []), parameters, weight, scale)
            without = predict_particles2(step, [], parameters, weight, scale)
            recorded = {row['name']: row['position'] for row in step['afterParticles2']}
            official = {row['name']: row['internalPosition'] for row in component['particles']}
            for row in step['beforeParticles2']:
                blocks.append(unity_matrix(row['parentMatrix'])[:3, :3])
            per_component.append(dict(rootName=component['rootName'],
                maxResidual=max(distance(predicted[name], recorded[name]) for name in recorded),
                maxResidualWithoutColliders=max(distance(without[name], recorded[name]) for name in recorded),
                maxOfficialDelta=max(distance(recorded[name], official[name]) for name in recorded),
                colliderPushes=collider_pushes(frame_row.get('colliders', []), parameters, scale, step)))
        spread = max(float(np.max(np.abs(block - blocks[0]))) for block in blocks)
        avatar_delta = None
        if 'avatar' in frame_row:
            expected = (rotation(frame_row['avatar']['rotation'])
                * F(stepped[0]['manualSteps'][0]['preamble']['objectScale'])).astype(np.float32)
            avatar_delta = float(max(np.max(np.abs(block - expected)) for block in blocks))
        frames.append(dict(frame=index, maxParentBlockSpread=spread, maxAvatarBlockDelta=avatar_delta,
            components=per_component))
    if not frames:
        raise ValueError('capture holds no manualSteps rows; use the fixture manual-step sub-mode capture')
    report = dict(schemaVersion=1, tolerance=float(tolerance),
        scope='UpdateParticles2 re-predicted from the manual-step recorded inputs (capture space)',
        frames=frames,
        maxResidual=max(row['maxResidual'] for f in frames for row in f['components']),
        maxResidualWithoutColliders=max(row['maxResidualWithoutColliders'] for f in frames for row in f['components']),
        maxOfficialDelta=max(row['maxOfficialDelta'] for f in frames for row in f['components']),
        passed=all(row['maxResidual'] <= tolerance for f in frames for row in f['components']))
    if contract is not None:
        report['runtimeParameters'] = runtime_parameter_report(capture, contract)
    return report


def _manual_step(nodes, definition, positions, weight, scale, colliders):
    """One oracle-truth UpdateParticles2 over the given node worlds (synthetic only).

    Mirrors the decompiled method with the reference float32 helpers: the
    particle loop follows the definition's chain order, reads each bone's live
    world matrix (column 3 replaced by the parent particle's predicted
    position) and mutates the shared positions between particles exactly like
    the source's in-place m_Position writes. Returns the before/after rows.
    """
    worlds, _ = hierarchy(nodes)
    indices = {node['sourceID']: i for i, node in enumerate(nodes)}
    predicted = {particle['nodeID']: v(positions[particle['nodeID']]) for particle in definition['particles']}
    before = []
    for index, particle in enumerate(definition['particles']):
        if particle['parent'] is None:
            continue
        parent_particle = definition['particles'][particle['parent']]
        node_i, parent_i = indices[particle['nodeID']], indices[parent_particle['nodeID']]
        rest = length(worlds[parent_i][:3, 3] - worlds[node_i][:3, 3])
        stiffness = F(F(1) + F(F(particle['stiffness']) - F(1)) * F(weight))
        position = predicted[particle['nodeID']]
        if stiffness > 0 or particle['elasticity'] > 0:
            matrix = worlds[parent_i].copy()
            matrix[:3, 3] = predicted[parent_particle['nodeID']]
            desired = matrix[:3, :3] @ v(nodes[node_i]['translation']) + matrix[:3, 3]
            position = position + (desired - position) * F(particle['elasticity'])
            if stiffness > 0:
                delta = desired - position
                span = length(delta)
                limit = F(F(rest * F(F(1) - stiffness)) * F(2))
                if span > limit:
                    position = position + delta * F(F(span - limit) / span)
        for entry in colliders:
            position = collide(position, F(F(particle['radius']) * F(scale)), entry, worlds[indices[entry['nodeID']]])
        delta = predicted[parent_particle['nodeID']] - position
        span = length(delta)
        if span > 0:
            position = position + delta * F(F(span - rest) / span)
        predicted[particle['nodeID']] = position
        before.append(dict(name=particle['nodeID'], parentName=parent_particle['nodeID'],
            parentPosition=[float(value) for value in worlds[parent_i][:3, 3]],
            parentMatrix=[float(value) for value in worlds[parent_i].flatten(order='F')],
            localPosition=[float(value) for value in nodes[node_i]['translation']], restLength=float(rest)))
    after = [dict(name=particle['nodeID'], position=[float(value) for value in predicted[particle['nodeID']]])
             for particle in definition['particles']]
    return before, after


def synthetic_manual_capture(manual_frames=(2, 5)):
    """Capture-shaped file with manual-step intermediates generated by the oracle.

    The scenario is synthetic_rig evolved for a few scripted frames; the
    frames named in manual_frames additionally carry a manualSteps row whose
    afterParticles1/beforeParticles2/afterParticles2 are generated by the
    reference implementation _manual_step, so manual_step_report must
    reproduce afterParticles2 bit-exactly. The bone chain and the collider
    keep identity world rotations and the collider is detached from the avatar
    and placed at its recorded position, so rotation+lossyScale reconstruct
    the exact world matrix the predictor consumes; the collider is placed one
    particle radius below the middle particle with bound 0, so its capsule
    provably pushes that particle out.
    """
    nodes, definition = synthetic_rig()
    solver = ParticleReference(copy.deepcopy(nodes), definition)
    avatar, collider_index = solver.indices['avatar:root'], solver.indices['collider']
    capsule = definition['colliders'][0]
    frames = []
    positions = {particle['nodeID']: v(solver.positions[index]) for index, particle in enumerate(definition['particles'])}
    for index in range(max(manual_frames) + 1):
        current = copy.deepcopy(nodes)
        current[avatar]['translation'] = [float(F(np.sin(index * .11) * .34)), 0.0, float(F(np.sin(index * .165) * .55))]
        advanced = solver.advance(current, float(F(1 / 60)))
        positions = {particle['nodeID']: v(advanced['positions'][i]) for i, particle in enumerate(definition['particles'])}
        worlds, _ = hierarchy(current)
        frame_colliders, manual = [], None
        if index in manual_frames:
            end = float(F(F(F(capsule['height']) + F(capsule['radius'])) * F(.5)))
            # Center the capsule so its lower endcap sits one m_Radius *
            # m_ObjectScale above the middle particle: the sphere(a) branch
            # provably pushes that particle out by exactly its combined radius.
            entry = dict(name='collider', position=[float(value) for value in positions['middle']],
                rotation=[0.0, 0.0, 0.0, 1.0], lossyScale=[1.0, 1.0, 1.0], radius=float(F(capsule['radius'])),
                height=float(F(capsule['height'])), center=[0.0, 0.0, end],
                direction=int(capsule['direction']), bound=int(capsule['bound']))
            frame_colliders = [entry]
            # The synthetic collider node keeps an identity world rotation and
            # scale and is detached from the swaying avatar, so its world is
            # exactly the recorded position and the predictor's
            # rotation(q)*lossyScale reconstruction reproduces it bit-exactly.
            shifted = copy.deepcopy(current)
            shifted[collider_index]['parent'] = None
            shifted[collider_index]['rotation'] = [0.0, 0.0, 0.0, 1.0]
            shifted[collider_index]['scale'] = [1.0, 1.0, 1.0]
            shifted[collider_index]['translation'] = entry['position']
            truth = dict(capsule)
            truth['center'] = [0.0, 0.0, end]
            before, after = _manual_step(shifted, definition, positions, float(solver.weight), 1.0, [truth])
            rows = [dict(name=name, position=[float(value) for value in position]) for name, position in positions.items()]
            parameters = {particle['nodeID']: {key: F(particle[key]) for key in PARAMETERS}
                          for particle in definition['particles']}
            if not collider_pushes([entry], parameters, 1.0, dict(afterParticles1=rows)):
                raise ValueError('synthetic manual step needs a collider overlap to be a meaningful test')
            positions = {row['name']: v(row['position']) for row in after}
            manual = dict(preamble=dict(objectScale=1.0, objectMove=[0.0, 0.0, 0.0],
                objectPrevPosition=[0.0, 0.0, 0.0], timeAfter=0.0, steps=1),
                afterParticles1=rows, beforeParticles2=before, afterParticles2=after,
                afterApply=[dict(name=row['name'], position=row['position'], rotation=[0.0, 0.0, 0.0, 1.0])
                            for row in after])
        component = dict(rootName=definition['rootName'], weight=float(solver.weight),
            particles=[dict(name=particle['nodeID'],
                position=[float(value) for value in positions[particle['nodeID']]],
                internalPosition=[float(value) for value in positions[particle['nodeID']]])
                for particle in definition['particles']])
        if manual is not None:
            component['manualSteps'] = [manual]
        frames.append(dict(deltaTime=float(F(1 / 60)),
            avatar=dict(position=list(current[avatar]['translation']), rotation=[0.0, 0.0, 0.0, 1.0]),
            colliders=frame_colliders, components=[component]))
    seed = [dict(rootName=definition['rootName'], weight=float(solver.weight),
        runtime=[dict(component=True, weight=float(solver.weight))] + [dict(name=particle['nodeID'],
            parent=(None if particle['parent'] is None else int(particle['parent'])),
            **{key: float(particle[key]) for key in PARAMETERS}) for particle in definition['particles']])]
    return dict(schemaVersion=1, scope='synthetic manual-step capture generated by the float32 oracle',
        components=seed, frameCount=len(frames), fixedRateHz=60, frames=frames)


def synthetic_contract():
    """Maker-contract-shaped document for synthetic_manual_capture (identity values)."""
    _, definition = synthetic_rig()
    return dict(components=[dict(rootName=definition['rootName'],
        particles=[dict(nodeName=particle['nodeID'], **{key: float(particle[key]) for key in PARAMETERS})
                   for particle in definition['particles']])])
