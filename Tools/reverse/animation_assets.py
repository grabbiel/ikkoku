#!/usr/bin/env python3
"""Convert explicitly selected generic Unity animation clips and controller states.

Only serialized transform curves are executable. Controller graphs are retained
as evidence; the native projection contains explicitly requested base-layer states.
"""
from __future__ import annotations
import argparse
import bisect
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib

REPO = Path(__file__).resolve().parents[2]
VERSION = "1.0.0"
DIMENSIONS = {1: 3, 2: 4, 3: 3}


def finite(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
        raise ValueError("Animation scalars must be finite")
    return value


def f32(value): return struct.unpack('<f', struct.pack('<f', value))[0]


def streamed_curves(data: list[int], count: int, start: float) -> list[dict]:
    if not 0 <= count <= 100000 or len(data) > 16000000:
        raise ValueError("Streamed curve limits exceeded")
    raw = struct.pack('<' + 'I' * len(data), *data)
    curves = [[] for _ in range(count)]
    initial = [None for _ in range(count)]
    position, previous, terminal = 0, -math.inf, False
    while position < len(raw):
        if position + 8 > len(raw): raise ValueError("Truncated streamed frame")
        time, length = struct.unpack_from('<fi', raw, position); position += 8
        if math.isnan(time) or time < previous or length < 0 or length > count or position + 20 * length > len(raw):
            raise ValueError("Invalid streamed frame header")
        if math.isinf(time):
            if time < 0 or length or position != len(raw): raise ValueError("Invalid streamed terminal sentinel")
            terminal = True
        seen = set()
        for _ in range(length):
            index, *coefficients = struct.unpack_from('<i4f', raw, position); position += 20
            if index < 0 or index >= count or index in seen: raise ValueError("Invalid or duplicate streamed curve index")
            seen.add(index)
            for value in coefficients: finite(value)
            if time < start:
                # Unity's first frame commonly uses -FLT_MAX and constant
                # coefficients. It seeds curves whose first timed key occurs
                # slightly after zero (e.g. one binary32 ULP after a cut).
                if time == -3.4028234663852886e38:
                    if coefficients[:3] != [0, 0, 0]: raise ValueError("Invalid streamed initialization sample")
                    initial[index] = [0.0, 0.0, 0.0, coefficients[3]]
                else:
                    dt = start - time
                    a, b, c, d = coefficients
                    initial[index] = [a, 3*a*dt+b, (3*a*dt+2*b)*dt+c, ((a*dt+b)*dt+c)*dt+d]
                    for value in initial[index]: finite(value)
            if time >= start:
                if curves[index] and time <= curves[index][-1]['time']: raise ValueError("Duplicate streamed key time")
                curves[index].append({'time': time, 'coefficients': coefficients})
        previous = time
    if count and not terminal: raise ValueError("Missing streamed terminal sentinel")
    for index, keys in enumerate(curves):
        if (not keys or keys[0]['time'] != start) and initial[index] is not None:
            keys.insert(0, {'time': start, 'coefficients': initial[index]})
    if any(not keys or keys[0]['time'] != start for keys in curves):
        raise ValueError("Every streamed curve needs an explicit start key")
    return [{'kind': 'streamed', 'keys': keys} for keys in curves]


def rig_paths(rig: dict, prefix: str) -> dict[int, dict]:
    nodes = rig['nodes']
    if not nodes or len(nodes) > 100000: raise ValueError("Invalid target rig size")
    roots = [i for i, node in enumerate(nodes) if node['parent'] is None]
    if len(roots) != 1: raise ValueError("Animation binding requires one explicit rig root")
    root = roots[0]
    result = {}
    for i, node in enumerate(nodes):
        names, visited, cursor = [], set(), i
        while cursor != root:
            if cursor in visited or not isinstance(cursor, int) or not 0 <= cursor < len(nodes):
                raise ValueError("Invalid rig parent hierarchy")
            visited.add(cursor)
            names.insert(0, nodes[cursor]['name'])
            cursor = nodes[cursor]['parent']
        path = '/'.join(names)
        key = zlib.crc32(path.encode('utf-8'))
        if key in result: raise ValueError("Animation path hash collision")
        result[key] = {'sourcePath': path, 'targetSourceID': prefix + node['sourceID'], 'targetName': node['name']}
    return result


def convert_clip(raw: dict, identity: str, targets: dict[int, dict]) -> dict:
    if raw['m_Legacy'] or raw['m_Compressed'] or raw['m_Events'] or raw['m_PPtrCurves']:
        raise ValueError("Legacy/compressed clips, events and object-reference curves require separate adapters")
    muscle = raw['m_MuscleClip']
    start, stop = finite(muscle['m_StartTime']), finite(muscle['m_StopTime'])
    if start < 0 or stop <= start: raise ValueError("Invalid animation interval")
    if muscle['m_Mirror']: raise ValueError("Clip mirroring is not implemented")
    if muscle['m_LoopBlend']: raise ValueError("Generic loop-pose correction is not implemented")
    source = muscle['m_Clip']['data']
    stream, dense, constant = source['m_StreamedClip'], source['m_DenseClip'], source['m_ConstantClip']['data']
    curves = streamed_curves(stream['data'], stream['curveCount'], start)
    frames, count, rate, begin = dense['m_FrameCount'], dense['m_CurveCount'], finite(dense['m_SampleRate']), finite(dense['m_BeginTime'])
    if count < 0 or frames < 0 or count > 100000 or frames > 1000000 or len(dense['m_SampleArray']) != frames * count:
        raise ValueError("Invalid dense sample dimensions")
    if count and (frames < 1 or rate <= 0 or begin < 0 or begin > stop): raise ValueError("Invalid dense interval")
    for value in dense['m_SampleArray']: finite(value)
    curves += [{'kind': 'dense', 'beginTime': begin, 'sampleRate': rate,
                'samples': dense['m_SampleArray'][index::count]} for index in range(count)]
    curves += [{'kind': 'constant', 'value': finite(value)} for value in constant]
    bindings, offset, unbound = [], 0, []
    for binding in raw['m_ClipBindingConstant']['genericBindings']:
        if binding['typeID'] != 4 or binding['attribute'] not in DIMENSIONS or binding['customType'] or binding['isPPtrCurve'] or binding['script']['m_PathID']:
            raise ValueError("Only generic Transform position/quaternion/scale bindings are supported")
        record = {'pathHash': binding['path'], 'attribute': binding['attribute'], 'curveOffset': offset}
        if binding['path'] in targets: record.update(targets[binding['path']])
        else: unbound.append(binding['path'])
        bindings.append(record)
        offset += DIMENSIONS[binding['attribute']]
    if offset != len(curves): raise ValueError("Generic binding dimensions differ from serialized scalar curves")
    return {'id': identity, 'name': raw['m_Name'], 'startTime': start, 'stopTime': stop,
            'sampleRate': finite(raw['m_SampleRate']), 'loop': muscle['m_LoopTime'],
            'bindings': bindings, 'curves': curves,
            'unboundPathHashes': sorted(set(unbound)),
            'sourceFlags': {key: value for key, value in muscle.items() if isinstance(value, bool)}}


def sample_curve(curve, time):
    if curve['kind'] == 'constant': return curve['value']
    if curve['kind'] == 'dense':
        frame = min(max((time - curve['beginTime']) * curve['sampleRate'], 0), len(curve['samples']) - 1)
        lower = int(frame); upper = min(lower + 1, len(curve['samples']) - 1)
        t = frame - lower
        return curve['samples'][lower] * (1 - t) + curve['samples'][upper] * t
    keys = curve['keys']; index = max(0, bisect.bisect_right([k['time'] for k in keys], time) - 1)
    key = keys[index]; dt = max(0, time - key['time']); a, b, c, d = key['coefficients']
    return ((a * dt + b) * dt + c) * dt + d


def project_states(controller: dict, requested: list[str], pointers: dict[int, str]) -> tuple[list, list]:
    tos = dict(controller['m_TOS']); source = controller['m_Controller']; states = []
    for state_index, entry in enumerate(source['m_StateMachineArray'][0]['data']['m_StateConstantArray']):
        state = entry['data']; name = tos.get(state['m_NameID'], '')
        if name not in requested: continue
        if state['m_Mirror'] or state['m_MirrorParamID'] or state['m_CycleOffsetParamID'] or state['m_IKOnFeet']:
            raise ValueError("Selected state uses unsupported mirror, cycle parameter or foot IK")
        if state['m_TransitionConstantArray']: raise ValueError("Selected state has automatic transitions; projection is explicit-state only")
        tree = state['m_BlendTreeConstantArray'][0]['data']['m_NodeArray']; root = tree[0]['data']
        if root['m_ChildIndices']:
            if root['m_BlendType'] != 0 or len(root['m_ChildIndices']) != len(root['m_Blend1dData']['data']['m_ChildThresholdArray']):
                raise ValueError("Only flat one-dimensional blend trees are supported")
            nodes = [(tree[i]['data'], threshold) for i, threshold in zip(root['m_ChildIndices'], root['m_Blend1dData']['data']['m_ChildThresholdArray'])]
            parameter = tos[root['m_BlendEventID']]
        else: nodes, parameter = [(root, 0)], None
        motions = []
        for node, threshold in nodes:
            if node['m_ChildIndices'] or node['m_Mirror'] or node['m_Duration'] != 1:
                raise ValueError("Nested, mirrored or time-scaled motion nodes are unsupported")
            clip = controller['m_AnimationClips'][node['m_ClipID']]
            if clip['m_FileID'] != 0 or clip['m_PathID'] not in pointers: raise ValueError("Unresolved state clip pointer")
            motions.append({'clipID': pointers[clip['m_PathID']], 'threshold': threshold, 'cycleOffset': node['m_CycleOffset']})
        states.append({'id': str(state['m_FullPathID']), 'name': name, 'sourceStateIndex': state_index,
            'sourceFullPath': tos[state['m_FullPathID']], 'speed': state['m_Speed'],
            'speedParameter': tos.get(state['m_SpeedParamID']) or None, 'cycleOffset': state['m_CycleOffset'],
            'loop': state['m_Loop'], 'blendParameter': parameter, 'motions': motions})
    if len(set(requested)) != len(requested) or len(states) != len(requested) or {s['name'] for s in states} != set(requested):
        raise ValueError("Requested controller states are missing or ambiguous")
    parameters = []
    defaults = source['m_DefaultValues']['data']
    for raw in source['m_Values']['data']['m_ValueArray']:
        kind = {1: 'float', 3: 'integer', 4: 'bool'}.get(raw['m_Type'])
        if kind is None: raise ValueError("Unsupported animator parameter type")
        key = {'float': 'm_FloatValues', 'integer': 'm_IntValues', 'bool': 'm_BoolValues'}[kind]
        parameters.append({'name': tos[raw['m_ID']], 'type': kind, 'defaultValue': defaults[key][raw['m_Index']]})
    return states, parameters


def main():
    import UnityPy
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--rig', type=Path, required=True)
    parser.add_argument('--controller', default='base')
    parser.add_argument('--state', action='append', default=[])
    parser.add_argument('--target-prefix', default='body-master/')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(REPO / '.local'): raise ValueError("Original assets must remain inside .local")
    output.mkdir(parents=True, exist_ok=True)
    source_bytes = args.bundle.read_bytes(); rig_bytes = args.rig.read_bytes()
    env = UnityPy.load(source_bytes)
    objects = {obj.path_id: obj for obj in env.objects}
    if len(objects) != len(env.objects): raise ValueError("Multiple serialized files have colliding object IDs; explicit external-file resolution is required")
    matches = [obj for obj in env.objects if obj.type.name == 'AnimatorController' and obj.peek_name() == args.controller]
    if len(matches) != 1: raise ValueError("Expected exactly one controller")
    controller = matches[0].read_typetree(); controller_id = f'{matches[0].assets_file.name}:{matches[0].path_id}'
    pointers = {obj.path_id: f'{obj.assets_file.name}:{obj.path_id}' for obj in env.objects if obj.type.name == 'AnimationClip'}
    states, parameters = project_states(controller, args.state or ['Idle'], pointers)
    used = {motion['clipID'] for state in states for motion in state['motions']}
    targets = rig_paths(json.loads(rig_bytes), args.target_prefix)
    clips = []
    for path_id, identity in pointers.items():
        if identity not in used: continue
        raw = objects[path_id].read_typetree()
        clips.append(convert_clip(raw, identity, targets))
        (output / f'clip-{path_id}-source.json').write_text(json.dumps(raw, indent=2) + '\n')
    (output / 'controller-source.json').write_text(json.dumps(controller, indent=2) + '\n')
    document = {'schemaVersion': 1, 'converterVersion': VERSION, 'kind': 'ikkoku-source-animation',
                'coordinateSpace': 'unity-left-handed-y-up', 'scope': 'explicit-state-base-layer-generic-transforms',
                'source': {'bundleSHA256': hashlib.sha256(source_bytes).hexdigest(), 'rigSHA256': hashlib.sha256(rig_bytes).hexdigest(),
                           'controllerID': controller_id, 'controllerName': args.controller},
                'parameters': parameters, 'states': states, 'clips': clips,
                'diagnostics': ['Only selected base-layer states are projected. Other layers, AnyState transitions, behaviours, root-motion extraction and override controllers are not executed.']}
    for clip in clips:
        if clip['unboundPathHashes']: document['diagnostics'].append(f"{clip['name']}: {len(clip['unboundPathHashes'])} path hashes have no target in the selected rig; explicit partial playback is required.")
    (output / 'animation.json').write_text(json.dumps(document, separators=(',', ':'), allow_nan=False) + '\n')
    reference = []
    for clip in clips:
        for fraction in [0, 0.125, 0.37, 0.5, 0.999, 1]:
            time = clip['startTime'] + (clip['stopTime'] - clip['startTime']) * fraction
            reference.append({'clipID': clip['id'], 'time': f32(time),
                'values': [sample_curve(c, f32(time)) for c in clip['curves']]})
    (output / 'sample-reference.json').write_text(json.dumps({'schemaVersion': 1, 'samples': reference}, allow_nan=False) + '\n')
    print(json.dumps({'output': str(output / 'animation.json'), 'clips': [{'id': c['id'], 'name': c['name'], 'bindings': len(c['bindings']),
        'curves': len(c['curves']), 'unboundPaths': len(c['unboundPathHashes'])} for c in clips], 'states': [s['name'] for s in states]}))


if __name__ == '__main__': main()
