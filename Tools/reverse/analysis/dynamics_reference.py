#!/usr/bin/env python3
"""Independent float32 DynamicBone particle/collision oracle; never executes DLLs.

This is a method-by-method numerical reference from the recovered managed
implementation, separate from the Swift solver and the prefab converter. It
retains the source sphere/endcap/interior branches and skip-update loop. The
reference verifies particle state and applied world positions, not Unity's
unavailable native quaternion/Transform implementation. `signed_document`
(#406) adds signed and zero local scales: it models the Transform semantics the
source relies on (rotation is the product of local rotations, TransformDirection
is rotation only, the position setter undoes each ancestor TRS with InverseSafe)
and Illusion's mirror compensation in ApplyParticlesToTransforms, and records
the applied world matrices.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
F = np.float32


def v(value):
    return np.asarray(value, dtype=np.float32)


def dot(a, b):
    return F(F(F(a[0] * b[0]) + F(a[1] * b[1])) + F(a[2] * b[2]))


def length(a):
    return F(np.sqrt(dot(a, a)))


def unit(a):
    size = length(a)
    return a / size if size > F(1e-5) else v([0, 0, 0])


def rotation(q):
    q = v(q) / F(np.sqrt(np.sum(v(q) * v(q), dtype=np.float32)))
    x, y, z, w = q
    return v([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
              [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
              [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])


def axis_rotation(axis, angle):
    q = [0., 0., 0., float(F(np.cos(F(angle / 2))))]
    q[axis] = float(F(np.sin(F(angle / 2))))
    return q


def trs(node):
    result = np.eye(4, dtype=np.float32)
    result[:3, :3] = rotation(node['rotation']) * v(node['scale'])
    result[:3, 3] = v(node['translation'])
    return result


def hierarchy(nodes):
    worlds, rotations = [], []
    for node in nodes:
        matrix, r = trs(node), rotation(node['rotation'])
        if node['parent'] is not None:
            matrix = worlds[node['parent']] @ matrix
            r = rotations[node['parent']] @ r
        worlds.append(matrix)
        rotations.append(r)
    return worlds, rotations


def point(matrix, p):
    return matrix[:3, :3] @ p + matrix[:3, 3]


def collide(position, particle_radius, collider, matrix):
    """Preserve the original four methods, including += for capsule interiors."""
    position = v(position).copy()
    radius = F(F(collider['radius']) * length(matrix[:3, 2]))
    half = F(F(F(collider['height']) - F(collider['radius'])) * F(.5))
    combined = F(radius + F(particle_radius))
    radius2 = F(combined * combined)

    def changes(d2):
        return d2 > radius2 if collider['bound'] else F(0) < d2 < radius2

    def sphere(center):
        delta = position - center
        size2 = dot(delta, delta)
        return center + delta * F(combined / F(np.sqrt(size2))) if changes(size2) else position

    center = v(collider['center'])
    if half <= F(0):
        return sphere(point(matrix, center))
    a, b = center.copy(), center.copy()
    a[collider['direction']] -= half
    b[collider['direction']] += half
    a, b = point(matrix, a), point(matrix, b)
    segment, offset = b - a, position - a
    along = dot(offset, segment)
    if along <= F(0):
        return sphere(a)
    size2 = dot(segment, segment)
    if along >= size2:
        return sphere(b)
    if size2 > F(0):
        along = F(along / size2)
        offset -= segment * along
        distance2 = dot(offset, offset)
        if changes(distance2):
            distance = F(np.sqrt(distance2))
            position += offset * F(F(combined - distance) / distance)
    return position


class ParticleReference:
    def __init__(self, nodes, definition):
        self.definition = definition
        self.indices = {node['sourceID']: i for i, node in enumerate(nodes)}
        self.node_indices = [self.indices[p['nodeID']] for p in definition['particles']]
        world, rotations = hierarchy(nodes)
        self.positions = v([world[i][:3, 3] for i in self.node_indices])
        self.previous = self.positions.copy()
        self.owner_position = world[self.indices[definition['ownerID']]][:3, 3].copy()
        self.local_gravity = rotations[self.node_indices[0]].T @ v(definition['gravity'])
        self.time = F(0)
        self.weight = F(1)

    def advance(self, nodes, dt, weight=None):
        if weight is not None:
            if not F(0) < F(weight) <= F(1):
                raise ValueError('Oracle scenarios use nonzero weights; reset is tested separately')
            self.weight = F(weight)
        d = self.definition
        world, rotations = hierarchy(nodes)
        owner = world[self.indices[d['ownerID']]]
        scale = length(owner[:3, 0])
        movement = owner[:3, 3] - self.owner_position
        self.owner_position = owner[:3, 3].copy()
        count = 1
        if d['updateRate'] > 0:
            interval = F(F(1) / F(d['updateRate']))
            self.time = F(self.time + F(dt))
            count = 0
            while self.time >= interval:
                self.time = F(self.time - interval)
                count += 1
                if count >= 3:
                    self.time = F(0)
                    break

        def constrain(i, simulate):
            p = d['particles'][i]
            parent = p['parent']
            ni, pn = self.node_indices[i], self.node_indices[parent]
            bone_length = length(world[pn][:3, 3] - world[ni][:3, 3])
            stiffness = F(F(1) + F(F(F(p['stiffness']) - F(1)) * self.weight))
            if stiffness > 0 or (simulate and p['elasticity'] > 0):
                # Source substitutes the particle position into matrix column 3.
                target_matrix = world[pn].copy()
                target_matrix[:3, 3] = self.positions[parent]
                desired = point(target_matrix, v(nodes[ni]['translation']))
                if simulate:
                    self.positions[i] += (desired - self.positions[i]) * F(p['elasticity'])
                if stiffness > 0:
                    delta = desired - self.positions[i]
                    distance = length(delta)
                    limit = F(F(bone_length * F(F(1) - stiffness)) * F(2))
                    if distance > limit:
                        self.positions[i] += delta * F(F(distance - limit) / distance)
            if simulate:
                for c in d['colliders']:
                    if c['enabled']:
                        self.positions[i] = collide(self.positions[i], F(F(p['radius']) * scale), c,
                                                    world[self.indices[c['nodeID']]])
                if d['freezeAxis']:
                    normal = unit(rotations[pn][:, d['freezeAxis'] - 1])
                    # Plane.SetNormalAndPosition normalizes and stores distance;
                    # GetDistanceToPoint performs the dot and addition separately.
                    plane_distance = F(-dot(normal, self.positions[parent]))
                    signed_distance = F(dot(normal, self.positions[i]) + plane_distance)
                    self.positions[i] -= normal * signed_distance
            delta = self.positions[parent] - self.positions[i]
            distance = length(delta)
            if distance > 0:
                self.positions[i] += delta * F(F(distance - bone_length) / distance)

        for _ in range(count):
            gravity = v(d['gravity'])
            normal = unit(gravity)
            transformed = rotations[self.node_indices[0]] @ self.local_gravity
            gravity -= normal * max(dot(transformed, normal), F(0))
            gravity = (gravity + v(d['force'])) * scale
            for i, p in enumerate(d['particles']):
                if p['parent'] is None:
                    self.previous[i] = self.positions[i].copy()
                    self.positions[i] = world[self.node_indices[i]][:3, 3]
                else:
                    velocity = self.positions[i] - self.previous[i]
                    inert_movement = movement * F(p['inert'])
                    self.previous[i] = self.positions[i] + inert_movement
                    self.positions[i] += velocity * F(F(1) - F(p['damping'])) + gravity + inert_movement
            for i in range(1, len(d['particles'])):
                constrain(i, True)
            movement = v([0, 0, 0])
        if count == 0:
            for i, p in enumerate(d['particles']):
                if p['parent'] is None:
                    self.previous[i] = self.positions[i].copy()
                    self.positions[i] = world[self.node_indices[i]][:3, 3]
                else:
                    self.previous[i] += movement
                    self.positions[i] += movement
                    constrain(i, False)
        return {'positions': self.positions.tolist(), 'previousPositions': self.previous.tolist(),
                'remainder': float(self.time), 'lastStepCount': count}


def node(name, parent=None, translation=(0, 0, 0), scale=(1, 1, 1), rotation=(0, 0, 0, 1)):
    return dict(sourceID=name, parent=parent, translation=list(translation), scale=list(scale), rotation=list(rotation))


def collider(direction=0, bound=0, height=0):
    return dict(nodeID='collider', center=[.05, -.08, .11], radius=.35,
                height=height, direction=direction, bound=bound, enabled=True)


def frame_inputs(count=20):
    dt = [0, 1/120, 1/120, .047, .002, .1, 0, 1/60, .008, .009]
    return [dict(deltaTime=float(F(dt[i % len(dt)])), overrides=[
        {'sourceID': 'owner', 'translation': [float(F(i*.027)), float(F(np.sin(i*.23)*.04)), float(F(i*-.013))]},
        {'sourceID': 'root', 'rotation': axis_rotation(2, i*.037)}],
        weight=.35 if i == 9 else None) for i in range(count)]


def make_scenario(name, nodes, definition, frames):
    solver = ParticleReference(nodes, definition)
    for frame in frames:
        current = copy.deepcopy(nodes)
        indices = {n['sourceID']: i for i, n in enumerate(current)}
        for override in frame['overrides']:
            current[indices[override['sourceID']]].update(override)
        frame['expected'] = solver.advance(current, frame['deltaTime'], frame.get('weight'))
    return dict(name=name, nodes=nodes, definition=definition, frames=frames)


def synthetic_document():
    nodes = [node('owner'), node('root', 0, (.1, .2, -.1)), node('middle', 1, (.1, -.45, .05)),
             node('tip', 2, (-.08, -.4, .06)), node('branch', 1, (-.3, -.2, -.08)),
             node('collider', 0, (0, -.25, .1), (1.1, .9, 1.3), axis_rotation(1, .35))]
    particles = [dict(nodeID=nodes[i]['sourceID'], parent=p, damping=.12+i*.03, elasticity=.15+i*.02,
                      stiffness=.32, inert=.2+i*.1, radius=.04) for i, p in [(1, None), (2, 0), (3, 1), (4, 0)]]
    definition = dict(sourceID='synthetic', ownerID='owner', updateRate=60, gravity=[0, -.04, .01],
                      force=[.013, -.004, .009], freezeAxis=0, particles=particles, colliders=[])
    scenarios = []
    for name, rate, freeze, scales, collisions in [
        ('moving-branched-chain', 60, 0, (1,1,1), False),
        ('zero-rate-nonuniform-scale', 0, 0, (1.2,.8,1.4), False),
        ('freeze-x-rotated-root', 60, 1, (1,1,1), False),
        ('freeze-z-rotated-root', 60, 3, (1,1,1), False),
        ('collider-order-and-gravity', 60, 0, (1,1,1), True),
    ]:
        config, rig = copy.deepcopy(definition), copy.deepcopy(nodes)
        config['updateRate'], config['freezeAxis'] = rate, freeze
        rig[0]['scale'] = list(scales)
        if collisions:
            inside = collider(2, 1, 1.8); inside['radius'] = .7
            config['colliders'] = [collider(1, 0, 1.1), inside]
        scenarios.append(make_scenario(name, rig, config, frame_inputs()))
    cases = []
    transform = node('collider', translation=(.21,-.31,.14), scale=(1.2,.8,1.6), rotation=axis_rotation(2,.47))
    matrix = trs(transform)
    for height in [0, .35, 1.6]:
        for direction in range(3):
            for bound in [0, 1]:
                c = collider(direction, bound, height)
                # A rotated exact axis is numerically discontinuous: tiny
                # differences in native matrix multiplication can select any
                # radial direction. Test that source branch separately with
                # an identity matrix, and use a stable near-axis value here.
                for j, offset in enumerate([(-1.5,.04,.02), (-.65,.04,.02), (0,.04,.02), (.65,.04,.02), (1.5,.04,.02), (0,.05,0), (0,1.5,.2)]):
                    local_offset = np.roll(v(offset), direction)
                    position = point(matrix, v(c['center']) + local_offset)
                    for radius in [0, .13]:
                        cases.append(dict(name=f'{height}/{direction}/{bound}/{j}/{radius}', collider=c,
                            transform=transform, position=position.tolist(), particleRadius=radius,
                            expected=collide(position, radius, c, matrix).tolist()))
    return dict(schemaVersion=1, reference='independent recovered DynamicBone float32 particle/collision methods',
                scope='real positive-TRS particles; no virtual ends, signed scale, exclusions/notRolls, distance disable, or rotation parity',
                scenarios=scenarios, collisions=cases)


# --- #406: signed TRS, applied transforms ---------------------------------

def quat_mul(a, b):
    ax, ay, az, aw = (float(x) for x in a)
    bx, by, bz, bw = (float(x) for x in b)
    return [aw*bx + ax*bw + ay*bz - az*by, aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw, aw*bw - ax*bx - ay*by - az*bz]


def quat_normalized(q):
    size = float(np.sqrt(sum(float(x) * float(x) for x in q)))
    return [float(x) / size for x in q]


def quat_inverse(q):
    return [-float(q[0]), -float(q[1]), -float(q[2]), float(q[3])]


def from_to(a, b):
    """Shortest rotation taking a onto b (the source's Quaternion.FromToRotation)."""
    a = np.asarray(a, dtype=np.float64); b = np.asarray(b, dtype=np.float64)
    f, t = a / np.linalg.norm(a), b / np.linalg.norm(b)
    d = float(np.dot(f, t))
    if d > .999999:
        return [0., 0., 0., 1.]
    if d < -.999999:
        axis = np.cross([1., 0., 0.], f)
        if np.dot(axis, axis) < 1e-6:
            axis = np.cross([0., 1., 0.], f)
        axis /= np.linalg.norm(axis)
        return [float(axis[0]), float(axis[1]), float(axis[2]), 0.]
    axis = np.cross(f, t)
    return quat_normalized([axis[0], axis[1], axis[2], 1 + d])


class AppliedTransforms:
    """Local signed TRS per node, as Unity Transforms keep them."""
    def __init__(self, nodes):
        self.nodes = copy.deepcopy(nodes)
        self.children = [0] * len(nodes)
        for n in nodes:
            if n['parent'] is not None:
                self.children[n['parent']] += 1

    def world(self, i):
        n = self.nodes[i]
        local = trs(n).astype(np.float64)
        return local if n['parent'] is None else self.world(n['parent']) @ local

    def world_rotation(self, i):
        n = self.nodes[i]
        q = quat_normalized(n['rotation'])
        return q if n['parent'] is None else quat_normalized(quat_mul(self.world_rotation(n['parent']), q))

    def set_world_rotation(self, i, q):
        parent = self.nodes[i]['parent']
        local = q if parent is None else quat_mul(quat_inverse(self.world_rotation(parent)), q)
        self.nodes[i]['rotation'] = quat_normalized(local)

    def inverse_point(self, i, p):
        """Transform.InverseTransformPoint: each ancestor TRS undone from the root, scale through InverseSafe."""
        chain = []
        while i is not None:
            chain.append(i); i = self.nodes[i]['parent']
        p = np.asarray(p, dtype=np.float64)
        for j in reversed(chain):
            n = self.nodes[j]
            r = rotation(n['rotation']).astype(np.float64)
            p = r.T @ (p - np.asarray(n['translation'], dtype=np.float64))
            p = p * np.array([1 / s if abs(s) > 1e-5 else 0. for s in n['scale']])
        return p

    def set_position(self, i, p):
        parent = self.nodes[i]['parent']
        self.nodes[i]['translation'] = [float(x) for x in (np.asarray(p, dtype=np.float64) if parent is None else self.inverse_point(parent, p))]


def apply_particles(nodes, definition, indices, node_indices, positions):
    """ApplyParticlesToTransforms with Illusion's mirror compensation; returns the transforms."""
    t = AppliedTransforms(nodes)
    owner = indices[definition['ownerID']]
    owner_parent = nodes[owner]['parent']
    axes = []
    for k in range(3):
        unit_axis = [0., 0., 0.]; unit_axis[k] = 1.
        if nodes[owner]['scale'][k] < 0:
            axes.append(rotation(t.world_rotation(owner)).astype(np.float64) @ unit_axis)
        elif owner_parent is not None and nodes[owner_parent]['scale'][k] < 0:
            axes.append(rotation(t.world_rotation(owner_parent)).astype(np.float64) @ unit_axis)
    for i in range(1, len(definition['particles'])):
        parent = definition['particles'][i]['parent']
        ni, pn = node_indices[i], node_indices[parent]
        if t.children[pn] <= 1:
            direction = rotation(t.world_rotation(pn)).astype(np.float64) @ np.asarray(t.nodes[ni]['translation'], dtype=np.float64)
            vector = np.asarray(positions[i], dtype=np.float64) - np.asarray(positions[parent], dtype=np.float64)
            for axis in axes:
                vector = vector - axis * (np.dot(vector, axis) * 2)
            if np.dot(direction, direction) > 1e-12 and np.dot(vector, vector) > 1e-12:
                t.set_world_rotation(pn, quat_mul(from_to(direction, vector), t.world_rotation(pn)))
        t.set_position(ni, positions[i])
    return t


def compact(x):
    """A float32 value in 9 significant digits, which round-trip it (inputs)."""
    return float('%.9g' % float(F(x)))


def expected_value(x):
    """An expected value rounded to 1e-7, far inside the 1e-5 comparison."""
    return float('%.7f' % float(F(x))) + 0.


def signed_frames(count, owner_motion):
    dt = [0, 1/120, 1/120, .047, .002, .1, 0, 1/60, .008, .009]
    frames = []
    for i in range(count):
        x = .08 * np.sin(i * .05) if owner_motion else 0.
        frames.append(dict(deltaTime=compact(dt[i % len(dt)]), overrides=[
            {'sourceID': 'owner', 'translation': [compact(.05 + x), compact(.2 + np.sin(i * .23) * .04), compact(-.03 + np.cos(i * .07) * .05)]},
            {'sourceID': 'root', 'rotation': [compact(x) for x in axis_rotation(2, .3 * np.sin(i * .037))]}]))
    return frames


SIGNED_CHECKPOINTS = [0, *range(19, 200, 20)]


def make_signed_scenario(name, nodes, definition, frames):
    solver = ParticleReference(nodes, definition)
    checkpoints = []
    for index, frame in enumerate(frames):
        current = copy.deepcopy(nodes)
        indices = {n['sourceID']: i for i, n in enumerate(current)}
        for override in frame['overrides']:
            current[indices[override['sourceID']]].update(override)
        expected = solver.advance(current, frame['deltaTime'])
        if index not in SIGNED_CHECKPOINTS:
            continue
        applied = apply_particles(current, definition, indices, solver.node_indices, solver.positions)
        e = expected_value
        checkpoints.append(dict(frame=index, positions=[[e(x) for x in p] for p in expected['positions']],
            previousPositions=[[e(x) for x in p] for p in expected['previousPositions']],
            remainder=compact(expected['remainder']), lastStepCount=expected['lastStepCount'],
            applied=[[e(x) for x in applied.world(ni)[:3, :].T.reshape(-1)] for ni in solver.node_indices[1:]]))
    return dict(name=name, nodes=nodes, definition=definition, checkpoints=checkpoints)


def signed_document():
    """#406 synthetic scenarios: negative and zero local scales on the owner,
    its parent, a particle bone and a collider. Every non-positive scale is
    a rest scale, which the rest pose records."""
    def rig(owner_rotation=(0, 0, 0, 1)):
        return [node('base', None, (0, .1, 0)), node('owner', 0, (.05, .2, -.03), rotation=owner_rotation),
                node('root', 1, (.1, .2, -.1)), node('middle', 2, (.1, -.45, .05)), node('tip', 3, (-.08, -.4, .06)),
                node('branch', 2, (-.3, -.2, -.08)),
                node('collider', 1, (0, -.25, .1), (1.1, .9, 1.3), axis_rotation(1, .35)),
                node('outer', 0, (.2, -.6, .1), (1, 1, 1), axis_rotation(0, .2))]
    particles = [dict(nodeID=n, parent=p, damping=.12+i*.03, elasticity=.15+i*.02, stiffness=.32, inert=.2+i*.1, radius=.04)
                 for i, (n, p) in enumerate([('root', None), ('middle', 0), ('tip', 1), ('branch', 0)])]
    inside = collider(2, 1, 1.8); inside.update(nodeID='outer', radius=.9)
    definition = dict(sourceID='signed', ownerID='owner', updateRate=60, gravity=[0, -.04, 0],
                      force=[.013, -.004, .009], freezeAxis=0, particles=particles,
                      colliders=[collider(1, 0, 1.1), inside])
    turned = axis_rotation(1, .4)
    cases = []
    for target in ['owner', 'base', 'middle', 'collider']:
        for k, axis in enumerate('xyz'):
            scale = [1.1, .9, 1.2]; scale[k] = -scale[k]
            cases.append((f'{target}-negative-{axis}', {target: scale}, 0, turned, True))
    cases += [('base-zero-y', {'base': [1.1, 0, 1.2]}, 0, turned, True),
              ('middle-zero-z', {'middle': [1.1, .9, 0]}, 0, turned, True),
              ('collider-zero-x', {'collider': [0, .9, 1.3]}, 0, turned, True),
              ('owner-two-negative-xy', {'owner': [-1.1, -.9, 1.2]}, 0, turned, True),
              ('owner-x-and-base-y-negative', {'owner': [-1.1, .9, 1.2], 'base': [1, -1, 1]}, 0, turned, True),
              ('owner-negative-x-freeze-y', {'owner': [-1.1, .9, 1.2]}, 2, turned, True),
              # Mirror pairs: an owner or base reflection across world X (the
              # base reflection mirrors the owner's translation itself), owner
              # motion in the mirror plane, gravity in the plane, the root
              # turning about Z and the force mirrored: the source is exactly
              # symmetric there.
              ('mirror-pair-positive', {}, 0, (0, 0, 0, 1), False),
              ('mirror-pair-owner-x', {'owner': [-1, 1, 1]}, 0, (0, 0, 0, 1), False),
              ('mirror-pair-base-x', {'base': [-1, 1, 1]}, 0, (0, 0, 0, 1), False)]
    frame_sets = dict(moving=signed_frames(200, True), planar=signed_frames(200, False))
    scenarios = []
    for name, scales, freeze, owner_rotation, motion in cases:
        nodes, config = rig(owner_rotation), copy.deepcopy(definition)
        for target, scale in scales.items():
            next(n for n in nodes if n['sourceID'] == target)['scale'] = scale
        config['freezeAxis'] = freeze
        if name.startswith('mirror-pair'):
            # Colliders under the owner only; the mirrored pairs flip the force.
            config['colliders'] = [collider(1, 0, 1.1)]
            if name != 'mirror-pair-positive':
                config['force'] = [-.013, -.004, .009]
        frames = 'moving' if motion else 'planar'
        scenario = make_signed_scenario(name, nodes, config, frame_sets[frames])
        scenario['frames'] = frames
        scenarios.append(scenario)
    return dict(schemaVersion=1, reference='independent recovered DynamicBone float32 particle methods with Unity signed-TRS '
                'transform semantics and Illusion mirror compensation (#406)', checkpoints=SIGNED_CHECKPOINTS,
                frameSets=frame_sets, scenarios=scenarios)


def checkout_evidence(entries):
    """Evidence with absolute paths. Contract entries name `.local/...` files
    relative to this checkout; copying them verbatim made the reference depend
    on the directory a test later runs from."""
    return [dict(e, path=str((REPO / e['path']).resolve())) for e in entries]


def original_document(directory):
    """Assemble source body/head/hair hierarchies independently of native output."""
    def read(name):
        return json.loads((directory / name).read_text())
    manifest = read('source-avatar.json')
    nodes = [node('avatar:root')]
    by_name = {}

    def append(raw, prefix, attachment, copy_locals=None):
        offset = len(nodes)
        for original in raw['nodes']:
            source = (copy_locals or {}).get(original['name'], original)
            parent = original['parent']
            t = list(source['translation']); t[2] = -t[2]
            q = list(source['rotation']); q[0] = -q[0]; q[1] = -q[1]
            nodes.append(node(prefix + '/' + original['sourceID'], attachment if parent is None else offset + parent,
                              t, source['scale'], q))
            by_name[(prefix, original['name'])] = len(nodes) - 1

    append(read(manifest['bodySkeleton']), 'body-master', 0)
    source_locals = {n['name']: n for n in read(manifest['head']['file'])['nodes']}
    append(read(manifest['headSkeleton']), 'head-master', by_name['body-master', 'cf_s_head'], source_locals)
    for i, hair in enumerate(manifest['hair']):
        append(read(hair['file']), f'hair-{i}', by_name['head-master', 'cf_J_FaceUp_ty'])
    source = read('source-dynamics.json')
    scenarios = []
    for i, component in enumerate(source['components']):
        frames = [dict(deltaTime=float(F(1/30 if step % 7 else 1/120)), overrides=[
            dict(sourceID='avatar:root', translation=[float(F(np.sin(step*.1)*.03)), 0, 0])]) for step in range(20)]
        scenarios.append(make_scenario(f'original-hair-{i}', nodes, component, frames))
    paths = ['source-avatar.json', 'source-dynamics.json', manifest['bodySkeleton'], manifest['headSkeleton'],
             manifest['head']['file'], *[h['file'] for h in manifest['hair']]]
    return dict(schemaVersion=1, reference='independent source hierarchy assembly and recovered float32 DynamicBone methods',
                sourceAvatar=str((directory / 'source-avatar.json').resolve()),
                evidence=[dict(path=str((directory / name).resolve()), sha256=hashlib.sha256((directory / name).read_bytes()).hexdigest()) for name in paths],
                managedAndBundleEvidence=checkout_evidence(source['evidence']),
                scenarios=scenarios, collisions=[])


def skirt_document(directory, contract_path, library_path, bottom=4):
    """Independent body + garment-root assembly, scripted leg motion, collider ablation.

    No native poses or particles seed this oracle. The exporter supplies only
    recovered parameters/identities; raw rig locals cross the Z reflection once.
    """
    contract = json.loads(contract_path.read_text())
    library = json.loads(library_path.read_text())
    entry = next(e for e in library['entries'] if (e['category'], e['id']) == (106, bottom))
    garment_path = library_path.parent / entry['rig']['file']
    body_path = directory / 'body-skeleton.json'
    raw_body, raw_garment = (json.loads(p.read_text()) for p in [body_path, garment_path])
    nodes = [node('avatar:root')]
    names = {}
    for original in raw_body['nodes']:
        t, q = list(original['translation']), list(original['rotation'])
        t[2] = -t[2]; q[0] = -q[0]; q[1] = -q[1]
        names[original['name']] = len(nodes)
        nodes.append(node('body-master/' + original['sourceID'], 0 if original['parent'] is None else original['parent'] + 1,
                          t, original['scale'], q))
    root = next(n for n in raw_garment['nodes'] if n['parent'] is None)
    t, q = list(root['translation']), list(root['rotation'])
    t[2] = -t[2]; q[0] = -q[0]; q[1] = -q[1]
    nodes.append(node('clothes-1/' + root['sourceID'], 0, t, root['scale'], q))
    definitions = [c for c in contract['components'] if c.get('sourceAsset') == dict(category=106, id=bottom, modGUID=None)]
    if not definitions or any(c['group'] != 'skirt' for c in definitions):
        raise ValueError('Requested bottom has no supported skirt components')
    frames = [dict(deltaTime=float(F(1/60)), overrides=[dict(sourceID=nodes[names['cf_j_thigh00_L']]['sourceID'],
              rotation=axis_rotation(0, .45 * np.sin(step * .08)))]) for step in range(60)]
    scenarios, clearances = [], {}
    def clearance(position, particle_radius, collider, world, scale):
        center = v(collider['center']); half = max(0., (collider['height'] - collider['radius']) * .5)
        a, b = center.copy(), center.copy(); a[collider['direction']] -= half; b[collider['direction']] += half
        a, b = point(world, a), point(world, b); edge = b - a
        fraction = np.clip(np.dot(position-a, edge) / np.dot(edge, edge), 0, 1) if np.dot(edge, edge) > 0 else 0
        return float(np.linalg.norm(position - a - fraction * edge) - collider['radius'] * length(world[:3, 2]) - particle_radius * scale)
    ids = {n['sourceID']: i for i, n in enumerate(nodes)}
    for enabled in [True, False]:
        minimum = float('inf')
        for index, definition in enumerate(definitions):
            config = copy.deepcopy(definition)
            if not enabled: config['colliders'] = []
            scenario = make_scenario(f'skirt-{bottom}-{index}-colliders-{enabled}', nodes, config, copy.deepcopy(frames))
            scenarios.append(scenario)
            for frame in scenario['frames']:
                current = copy.deepcopy(nodes)
                for override in frame['overrides']: current[ids[override['sourceID']]].update(override)
                worlds, _ = hierarchy(current); scale = length(worlds[ids[definition['ownerID']]][:3, 0])
                for particle, position in zip(definition['particles'][1:], frame['expected']['positions'][1:]):
                    for collider in definition['colliders']:
                        if collider['enabled'] and collider['bound'] == 0:
                            minimum = min(minimum, clearance(v(position), particle['radius'], collider, worlds[ids[collider['nodeID']]], scale))
        clearances['collidersOn' if enabled else 'collidersOff'] = minimum
    paths = [body_path, garment_path, contract_path, library_path]
    return dict(schemaVersion=1, reference='independent recovered float32 skirt dynamics; raw body hierarchy and scripted leg motion',
                evidence=[dict(path=str(p.resolve()), sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths],
                managedAndBundleEvidence=checkout_evidence(contract['evidence']),
                colliderControl=dict(minimumSignedDistance=clearances, excludes='root particles; includes particle radius and source final length projection'),
                scenarios=scenarios, collisions=[])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--original-rigs', type=Path)
    parser.add_argument('--skirt-contract', type=Path)
    parser.add_argument('--maker-library', type=Path)
    parser.add_argument('--bottom', type=int, default=4)
    parser.add_argument('--signed', action='store_true', help='the #406 signed-scale synthetic document')
    args = parser.parse_args()
    if args.skirt_contract and (not args.original_rigs or not args.maker_library):
        parser.error('--skirt-contract needs --original-rigs and --maker-library')
    if args.original_rigs and not args.output.resolve().is_relative_to((REPO / '.local').resolve()):
        parser.error('Original data must remain under .local')
    if args.signed:
        result = signed_document()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, separators=(',', ':'), allow_nan=False) + '\n')
        print(json.dumps(dict(scenarios=len(result['scenarios']), frames=sum(len(result['frameSets'][s['frames']]) for s in result['scenarios']),
                              checkpoints=sum(len(s['checkpoints']) for s in result['scenarios']), output=str(args.output))))
        return
    result = (skirt_document(args.original_rigs, args.skirt_contract, args.maker_library, args.bottom) if args.skirt_contract
              else original_document(args.original_rigs) if args.original_rigs else synthetic_document())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, separators=(',', ':'), allow_nan=False) + '\n')
    print(json.dumps(dict(scenarios=len(result['scenarios']), frames=sum(len(s['frames']) for s in result['scenarios']),
                         collisions=len(result['collisions']), output=str(args.output))))


if __name__ == '__main__':
    main()
