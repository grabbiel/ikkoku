#!/usr/bin/env python3
"""Independent float32 DynamicBone particle/collision oracle; never executes DLLs.

This is a method-by-method numerical reference from the recovered managed
implementation, separate from the Swift solver and the prefab converter. It
retains the source sphere/endcap/interior branches and skip-update loop. The
reference verifies particle state and applied world positions, not Unity's
unavailable native quaternion/Transform implementation or signed-scale paths.
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
                managedAndBundleEvidence=source['evidence'],
                scenarios=scenarios, collisions=[])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--original-rigs', type=Path)
    args = parser.parse_args()
    if args.original_rigs and not args.output.resolve().is_relative_to((REPO / '.local').resolve()):
        parser.error('Original data must remain under .local')
    result = original_document(args.original_rigs) if args.original_rigs else synthetic_document()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, separators=(',', ':'), allow_nan=False) + '\n')
    print(json.dumps(dict(scenarios=len(result['scenarios']), frames=sum(len(s['frames']) for s in result['scenarios']),
                         collisions=len(result['collisions']), output=str(args.output))))


if __name__ == '__main__':
    main()
