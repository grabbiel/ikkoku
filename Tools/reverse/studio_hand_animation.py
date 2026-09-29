#!/usr/bin/env python3
"""Convert the default state or every saved pattern state of both hand controllers.

Only serialized assets are decoded: each requested controller state owns one
flat motion node, so exactly one clip is converted per state. Generic
Transform bindings resolve their path hashes through the controller's avatar
(`m_TOS`), which keeps the bind on the `cf_s_hand_L`/`cf_s_hand_R` subtree.
The default mode applies one frozen pose, so every curve is sampled once at
the requested clip time; each clip loops, so times wrap into its interval.
`--all-patterns` instead walks the Studio `HandAnime_00_00`/`HandAnime_01_00`
tables and emits every clip frame of each pattern at its native frame times.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import re
from pathlib import Path

from animation_assets import DIMENSIONS, convert_clip, f32, project_states, sample_curve

REPO = Path(__file__).resolve().parents[2]
PATTERN_TABLES = {'L': 'HandAnime_00_00', 'R': 'HandAnime_01_00'}


def wrapped_time(clip: dict, time: float) -> float:
    """Wrap a playhead into a looping clip, or clamp it to a non-looping one."""
    start, stop = clip['startTime'], clip['stopTime']
    if not math.isfinite(time):
        raise ValueError(f"{clip['name']}: clip time must be finite")
    if not clip['loop']:
        return min(max(time, start), stop)
    return start + (time - start) % (stop - start)


def curve_values(clip: dict, time: float) -> dict[str, dict[str, list[float]]]:
    """Sample every bound generic-Transform curve once and key results by bone."""
    if clip['unboundPathHashes']:
        raise ValueError(f"{clip['name']}: {len(clip['unboundPathHashes'])} path hashes have no TOS entry")
    time = wrapped_time(clip, time)
    values: dict[str, dict[str, list[float]]] = {}
    for binding in clip['bindings']:
        size = DIMENSIONS[binding['attribute']]
        sampled = [sample_curve(curve, time) for curve in clip['curves'][binding['curveOffset']:binding['curveOffset'] + size]]
        bone = values.setdefault(binding['targetName'], {})
        kind = {1: 'position', 2: 'rotation', 3: 'scale'}[binding['attribute']]
        if kind in bone and bone[kind] != sampled:
            raise ValueError(f"{binding['targetName']}: conflicting {kind} curves")
        bone[kind] = sampled
    return values


def avatar_targets(avatar: dict, avatar_name: str) -> dict[int, dict]:
    """Map avatar path hashes onto the hand controller's bone subtree."""
    return {hash: {'sourcePath': path, 'targetSourceID': f'{avatar_name}/{path}',
                   'targetName': path.rsplit('/', 1)[-1]}
            for hash, path in dict(avatar['m_TOS']).items()}


def default_clip(controller: dict, controller_name: str, avatar: dict, avatar_name: str,
                 objects: dict[int, object], pointers: dict[int, str]) -> tuple[int, str, dict]:
    """Convert the default state's single clip with paths resolved through the avatar TOS."""
    if len(controller['m_Controller']['m_LayerArray']) != 1:
        raise ValueError('Multiple Animator layers require a layer adapter')
    state_machine = controller['m_Controller']['m_StateMachineArray'][0]['data']
    state_index = state_machine['m_DefaultState']
    if not isinstance(state_index, int) or not 0 <= state_index < len(state_machine['m_StateConstantArray']):
        raise ValueError('Default state index out of range')
    state_name = dict(controller['m_TOS'])[state_machine['m_StateConstantArray'][state_index]['data']['m_NameID']]
    states, _parameters = project_states(controller, [state_name], pointers)
    motions = states[0]['motions']
    if len(motions) != 1:
        raise ValueError(f"{controller_name}: default state binds {len(motions)} clips; native shape patterns are single-clip")
    clip_id = motions[0]['clipID']
    clip = convert_clip(objects[int(clip_id.split(':')[-1])].read_typetree(), clip_id, avatar_targets(avatar, avatar_name))
    if clip['unboundPathHashes']:
        raise ValueError(f"{clip_id}: {len(clip['unboundPathHashes'])} unbound path hashes; wiring requires full binding coverage")
    return state_index, state_name, clip


def pattern_rows(table: dict, controller_name: str, bundle_name: str) -> dict[int, str]:
    """Read (pattern ID, state) rows after one HandAnime table's header row."""
    rows: dict[int, str] = {}
    for entry in table['list'][1:]:
        row = entry['list']
        if not row or all(cell == '' for cell in row):
            continue
        if len(row) < 5 or not re.fullmatch(r'\d+', row[0]):
            raise ValueError(f"{table['m_Name']}: rows need ID, display name, bundle, controller and state columns")
        pattern = int(row[0])
        if pattern <= 0:
            raise ValueError(f"{table['m_Name']}: pattern 0 disables the Animator and has no table row")
        if row[3] != controller_name or row[2] != f'studio/base/{bundle_name}':
            raise ValueError(f"{table['m_Name']}: pattern {pattern} resolves outside {controller_name} in the selected bundle")
        if pattern in rows:
            raise ValueError(f"{table['m_Name']}: duplicate pattern ID {pattern}")
        if not row[4]:
            raise ValueError(f"{table['m_Name']}: pattern {pattern} has no state name")
        rows[pattern] = row[4]
    if not rows:
        raise ValueError(f"{table['m_Name']}: table has no pattern rows")
    return rows


def pattern_frames(clip: dict) -> list[float]:
    """Native frame times of the clip's dense sample slots, or its start if constant-only."""
    dense = [curve for curve in clip['curves'] if curve['kind'] == 'dense']
    if not dense:
        return [f32(clip['startTime'])]
    begins = {curve['beginTime'] for curve in dense}
    rates = {curve['sampleRate'] for curve in dense}
    counts = {len(curve['samples']) for curve in dense}
    if len(begins) != 1 or len(rates) != 1 or len(counts) != 1:
        raise ValueError(f"{clip['name']}: dense curves disagree on frame geometry")
    begin, rate, count = begins.pop(), rates.pop(), counts.pop()
    if rate <= 0 or count < 1:
        raise ValueError(f"{clip['name']}: invalid dense frame geometry")
    return [f32(begin + index / rate) for index in range(count)]


def pattern_bones(clip: dict, times: list[float]) -> dict[str, dict[str, list[list[float]]]]:
    """Sample every bound generic-Transform curve at each native frame time."""
    if clip['unboundPathHashes']:
        raise ValueError(f"{clip['name']}: {len(clip['unboundPathHashes'])} path hashes have no TOS entry")
    channels: dict[str, dict[str, list[list[float]]]] = {}
    for binding in clip['bindings']:
        size = DIMENSIONS[binding['attribute']]
        curves = clip['curves'][binding['curveOffset']:binding['curveOffset'] + size]
        sampled = [[f32(sample_curve(curve, time)) for curve in curves] for time in times]
        bone = channels.setdefault(binding['targetName'], {})
        kind = {1: 'position', 2: 'rotation', 3: 'scale'}[binding['attribute']]
        if kind in bone and bone[kind] != sampled:
            raise ValueError(f"{binding['targetName']}: conflicting {kind} curves")
        bone[kind] = sampled
    bones = {}
    for name, kinds in channels.items():
        if 'rotation' not in kinds:
            raise ValueError(f"{name}: hand patterns animate a rotation, only {sorted(kinds)} are recorded")
        entry = {'frames': kinds.pop('rotation')}
        entry.update(kinds)
        bones[name] = entry
    return bones


def convert_pattern(controller: dict, controller_name: str, pattern: int, state: str,
                    avatar: dict, avatar_name: str, objects: dict[int, object], pointers: dict[int, str]) -> dict:
    """Project one HandAnime state and emit every clip frame at its native frame times."""
    states, _parameters = project_states(controller, [state], pointers)
    motions = states[0]['motions']
    if len(motions) != 1:
        raise ValueError(f"{controller_name}/{state}: state binds {len(motions)} clips; hand patterns are single-clip")
    clip_id = motions[0]['clipID']
    clip = convert_clip(objects[int(clip_id.split(':')[-1])].read_typetree(), clip_id, avatar_targets(avatar, avatar_name))
    times = pattern_frames(clip)
    return {'id': pattern, 'name': clip['name'], 'state': states[0]['name'],
            'clip': {'startTime': clip['startTime'], 'stopTime': clip['stopTime'],
                     'sampleRate': clip['sampleRate'], 'loop': clip['loop']},
            'frameTimes': times, 'bones': pattern_bones(clip, times)}


def convert_hand(controller: dict, controller_name: str, avatar: dict, avatar_name: str,
                 objects: dict[int, object], pointers: dict[int, str], time: float) -> dict:
    """Project each hand's default state, convert its clip, and sample it once."""
    state_index, state_name, clip = default_clip(controller, controller_name, avatar, avatar_name, objects, pointers)
    return {'state': state_name, 'stateIndex': state_index,
            'clip': {'id': clip['id'], 'name': clip['name'], 'loop': clip['loop'],
                     'startTime': clip['startTime'], 'stopTime': clip['stopTime']},
            'sampleTime': {'requested': time, 'clipTime': f32(wrapped_time(clip, time))},
            'bones': curve_values(clip, time)}


def convert_all_patterns(tables: dict[str, dict], controllers: dict[str, object], avatars: dict[str, object],
                         objects: dict[int, object], pointers: dict[int, str], bundle_name: str) -> dict:
    """Emit every table pattern of both hands as one full-clip entry per pattern."""
    if set(tables) != set(PATTERN_TABLES.values()):
        raise ValueError('Both HandAnime tables are required to resolve pattern IDs')
    hands = {}
    for hand, table in PATTERN_TABLES.items():
        controller, avatar = f'cf_hand_{hand}_00', f'cf_hand_{hand}_00Avatar'
        if controller not in controllers or avatar not in avatars:
            raise ValueError(f"Missing controller {controller} or avatar {avatar}")
        raw = controllers[controller].read_typetree()
        if len(raw['m_Controller']['m_LayerArray']) != 1:
            raise ValueError('Multiple Animator layers require a layer adapter')
        rows = pattern_rows(tables[table], controller, bundle_name)
        hands[hand] = {'patterns': [convert_pattern(raw, controller, pattern, state,
                                                    avatars[avatar].read_typetree(), avatar,
                                                    objects, pointers) for pattern, state in sorted(rows.items())]}
    return hands


def main():
    import UnityPy
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path,
                        default=Path('/Users/rumpology/code/repo/ikkoku/.local/reverse/source/abdata/studio/base/00.unity3d'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--time', type=float, default=0.0,
                        help='clip time in seconds to sample; wrapped into the looping clip')
    parser.add_argument('--all-patterns', action='store_true',
                        help='convert every saved Studio hand pattern instead of the default-state sample')
    parser.add_argument('--info-bundle', type=Path,
                        default=Path('/Users/rumpology/code/repo/ikkoku/.local/reverse/source/abdata/studio/info/00.unity3d'),
                        help='Studio info bundle holding the HandAnime pattern tables')
    args = parser.parse_args()
    if args.output is None:
        args.output = REPO / ('.local/stt07e/studio-hand-patterns.json' if args.all_patterns else '.local/stt07d/studio-hand-default.json')
    output = args.output.resolve()
    if not output.is_relative_to(REPO / '.local'):
        raise ValueError('Original assets must remain inside .local')
    source_bytes = args.bundle.read_bytes()
    env = UnityPy.load(source_bytes)
    objects = {obj.path_id: obj for obj in env.objects}
    if len(objects) != len(env.objects):
        raise ValueError('Multiple serialized files have colliding object IDs; explicit external-file resolution is required')
    pointers = {obj.path_id: f'{obj.assets_file.name}:{obj.path_id}' for obj in env.objects if obj.type.name == 'AnimationClip'}
    controllers = {obj.peek_name(): obj for obj in env.objects if obj.type.name == 'AnimatorController'}
    avatars = {obj.peek_name(): obj for obj in env.objects if obj.type.name == 'Avatar'}
    if args.all_patterns:
        info_bytes = args.info_bundle.read_bytes()
        tables: dict[str, dict] = {}
        for obj in UnityPy.load(info_bytes).objects:
            if obj.type.name != 'MonoBehaviour':
                continue
            tree = obj.read_typetree()
            table = tree.get('m_Name')
            if table not in PATTERN_TABLES.values():
                continue
            if table in tables:
                raise ValueError(f'Duplicate {table} table in the Studio info bundle')
            tables[table] = tree
        diagnostics = ['Pattern IDs come from the Studio HandAnime tables; pattern 0 and any ID without a row disable the hand Animator, so they have no pose to convert.',
                       'Each pattern clip loops at its own native sample rate; a saved scene does not record the Studio clock phase it starts from.',
                       'Cross-fades between patterns and the Studio Preparation Animator enable/disable toggling are not executed.']
        hands = convert_all_patterns(tables, controllers, avatars, objects, pointers, args.bundle.name)
        document = {'schemaVersion': 1, 'converterVersion': '1.0.0', 'kind': 'ikkoku-studio-hand-patterns',
                    'coordinateSpace': 'unity-left-handed-y-up', 'scope': 'hand-anime-table-states-generic-transforms',
                    'source': {'bundleSHA256': hashlib.sha256(source_bytes).hexdigest(), 'bundle': str(args.bundle),
                               'infoBundleSHA256': hashlib.sha256(info_bytes).hexdigest(), 'infoBundle': str(args.info_bundle)},
                    'hands': hands, 'diagnostics': diagnostics}
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(document, separators=(',', ':'), allow_nan=False) + '\n')
        print(json.dumps({'output': str(output), 'hands': {hand: {'patterns': len(hand_data['patterns']),
                'frames': [len(pattern['frameTimes']) for pattern in hand_data['patterns']]} for hand, hand_data in hands.items()}}))
        return
    hands = {}
    for hand, controller, avatar in [('L', 'cf_hand_L_00', 'cf_hand_L_00Avatar'), ('R', 'cf_hand_R_00', 'cf_hand_R_00Avatar')]:
        if controller not in controllers or avatar not in avatars:
            raise ValueError(f"Missing controller {controller} or avatar {avatar}")
        hands[hand] = convert_hand(controllers[controller].read_typetree(), controller,
                                   avatars[avatar].read_typetree(), avatar, objects, pointers, args.time)
    diagnostics = ['Only the default-state clip of each hand controller is projected; the 20 remaining states per hand and any cross-fade behaviour are not executed.']
    if args.time != 0:
        diagnostics.append(f'Sampling time {args.time} s is a fitted capture phase: the clip loops within [{hands["L"]["clip"]["startTime"]}, {hands["L"]["clip"]["stopTime"]}) s and the original capture does not record which loop phase it used.')
    document = {'schemaVersion': 1, 'converterVersion': '1.0.0', 'kind': 'ikkoku-studio-hands',
                'coordinateSpace': 'unity-left-handed-y-up', 'scope': 'default-state-single-clip-generic-transforms',
                'source': {'bundleSHA256': hashlib.sha256(source_bytes).hexdigest(),
                           'bundle': str(args.bundle)},
                'hands': hands,
                'diagnostics': diagnostics}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, separators=(',', ':'), allow_nan=False) + '\n')
    print(json.dumps({'output': str(output), 'hands': {hand: {'state': hand_data['state'],
            'clip': hand_data['clip']['name'], 'time': hand_data['sampleTime']['clipTime'],
            'bones': len(hand_data['bones'])} for hand, hand_data in hands.items()}}))


if __name__ == '__main__':
    main()
