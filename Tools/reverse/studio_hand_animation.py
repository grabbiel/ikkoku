#!/usr/bin/env python3
"""Convert the default hand-animation state of both hand controllers locally.

Only serialized assets are decoded: each controller's default state owns one
flat motion node, so exactly one clip is converted per hand. Generic
Transform bindings resolve their path hashes through the controller's avatar
(`m_TOS`), which keeps the bind on the `cf_s_hand_L`/`cf_s_hand_R` subtree.
The native runtime applies one frozen pose, so every curve is sampled once at
the requested clip time; each clip loops, so times wrap into its interval.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path

from animation_assets import DIMENSIONS, convert_clip, f32, project_states, sample_curve

REPO = Path(__file__).resolve().parents[2]


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
    clip = convert_clip(objects[int(clip_id.split(':')[-1])].read_typetree(), clip_id,
                        {hash: {'sourcePath': path, 'targetSourceID': f'{avatar_name}/{path}',
                                'targetName': path.rsplit('/', 1)[-1]}
                         for hash, path in dict(avatar['m_TOS']).items()})
    if clip['unboundPathHashes']:
        raise ValueError(f"{clip_id}: {len(clip['unboundPathHashes'])} unbound path hashes; wiring requires full binding coverage")
    return state_index, state_name, clip


def convert_hand(controller: dict, controller_name: str, avatar: dict, avatar_name: str,
                 objects: dict[int, object], pointers: dict[int, str], time: float) -> dict:
    """Project each hand's default state, convert its clip, and sample it once."""
    state_index, state_name, clip = default_clip(controller, controller_name, avatar, avatar_name, objects, pointers)
    return {'state': state_name, 'stateIndex': state_index,
            'clip': {'id': clip['id'], 'name': clip['name'], 'loop': clip['loop'],
                     'startTime': clip['startTime'], 'stopTime': clip['stopTime']},
            'sampleTime': {'requested': time, 'clipTime': f32(wrapped_time(clip, time))},
            'bones': curve_values(clip, time)}


def main():
    import UnityPy
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path,
                        default=Path('/Users/rumpology/code/repo/ikkoku/.local/reverse/source/abdata/studio/base/00.unity3d'))
    parser.add_argument('--output', type=Path, default=REPO / '.local/stt07d/studio-hand-default.json')
    parser.add_argument('--time', type=float, default=0.0,
                        help='clip time in seconds to sample; wrapped into the looping clip')
    args = parser.parse_args()
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
