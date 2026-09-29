#!/usr/bin/env python3
"""Replay a look-at capture's FORWARD / FIX / ANIMATION phases with the reference.

Reads one `look-trace.json` made by `original_character_probe.py
--look-patterns` plus the exported studio look settings, and replays every
frame of the phases whose neck pattern drives one of the two simulated look
modes (phases 3 = FORWARD, 4 = FIX, 5 = ANIMATION for the run1 capture,
0-based) through `analysis.neck_look_reference.neck_step`.  Each phase's
state is seeded from the frame before it: the previous phase's recorded
lookType, changeTypeTimer left at 0 (the reference resets it on the type
change anyway) and fixAngle = the recorded fixAngle of the phase's last
frame, which is exactly the value UpdateCall copies into fixAngleBackup.
FORWARD and FIX make calcLerp return fixAngle without reading the entry
pose, so the capture's post-override localRotation is a sound animated
input there; ANIMATION writes that pose through directly, and the run1
capture never moves the neck while ANIMATION is active, so this comparator
feeds ANIMATION the same frame's recorded pose and only checks the "no
change" consequence (Slerp over a zero arc), not the animated pose itself.
TARGET / AWAY frames are only read for seeding and are never simulated.
Reports the maximum angle error in degrees per phase and bone; with
`--fixture` it also writes a small synthetic sequence (hand-picked input
quaternions, outputs computed by the reference) for the Swift engine tests.
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path

from analysis.neck_look_reference import (DEFAULT_CALC_LERP,
                                          DEFAULT_CHANGE_TYPE_LEAP_TIME,
                                          DEFAULT_CHANGE_TYPE_LERP_CURVE,
                                          evaluate_curve, initial_state, neck_step)
from compare_hand_patterns import angle_degrees

BONE_NAMES = ['cf_j_neck', 'cf_j_head']
SIMULATED_PHASES = {3: 'FORWARD', 4: 'FIX', 5: 'ANIMATION'}
TOLERANCE_DEGREES = 0.01


def load_inputs(trace_path: Path, settings_path: Path) -> tuple[list, dict, float, float, list]:
    """Boundary-checked loads of the trace and the settings the replay uses."""
    trace = json.loads(trace_path.read_text())
    settings = json.loads(settings_path.read_text())
    if trace.get('error') not in (None, ''):
        raise ValueError(f"capture recorded an error: {trace['error']}")
    frames, phases = trace.get('frames', []), trace.get('phases', [])
    if not frames or not phases:
        raise ValueError('the trace needs both frames and phases')
    neck = settings['neck']
    leap_time = neck.get('changeTypeLeapTime', DEFAULT_CHANGE_TYPE_LEAP_TIME)
    curve = neck.get('changeTypeLerpCurve', DEFAULT_CHANGE_TYPE_LERP_CURVE)
    calc_lerp = neck.get('calcLerp', DEFAULT_CALC_LERP)
    if curve.get('preInfinity') != 2 or curve.get('postInfinity') != 2:
        raise ValueError('the reference only models clamp-to-ends transition curves')
    if calc_lerp != 1:
        raise ValueError('the replay feeds the entry pose as the animated input, which only holds at calcLerp 1')
    for bone, entry in zip(BONE_NAMES, neck.get('aBones', [])):
        if entry.get('neckBone') != bone:
            raise ValueError(f'settings bone order must start {BONE_NAMES}, found {entry.get("neckBone")}')
    return frames, curve, calc_lerp, leap_time, phases


def phase_bounds(frames: list, phases: list) -> dict[int, tuple[int, int]]:
    """Start/end frame indexes of every phase, from the frames' phase field."""
    bounds: dict[int, tuple[int, int]] = {}
    seen: dict[int, int] = {}
    for index, frame in enumerate(frames):
        phase = frame['phase']
        if phase in seen and index != seen[phase] + 1:
            raise ValueError(f'phase {phase} frames are not contiguous')
        first = bounds.get(phase, (index, index + 1))[0]
        bounds[phase] = (first, index + 1)
        seen[phase] = index
    if set(bounds) != set(range(len(phases))):
        raise ValueError('every phase index must appear in the frames')
    return bounds


def seed_state(frames: list, first: int) -> dict:
    """State entering a simulated phase, read off the frame before it."""
    previous = frames[first - 1]
    calculator = previous['neck']['calculators'][0]
    return initial_state(calculator['lookType'],
                         [bone['fixAngle'] for bone in previous['neck']['bones']])


def replay_phase(frames: list, first: int, last: int, look_type: str,
                 curve: dict, calc_lerp: float, leap_time: float):
    """Run the reference over one phase; returns (errors, predictions)."""
    state = seed_state(frames, first)
    errors = [[0.0, 0.0] for _ in BONE_NAMES]
    predictions = []
    for index in range(first, last):
        frame = frames[index]
        recorded = [bone['localRotation'] for bone in frame['neck']['bones']]
        recorded_fix = [bone['fixAngle'] for bone in frame['neck']['bones']]
        calculator = frame['neck']['calculators'][0]
        if calculator['lookType'] != look_type:
            raise ValueError(f'phase frame {index} is {calculator["lookType"]}, not {look_type}')
        # FORWARD/FIX read the entry pose not at all (calcLerp 1); ANIMATION
        # writes it through, so there the recorded pose only probes no change.
        animated = [list(quaternion) for quaternion in recorded]
        state, rotations = neck_step(state, look_type, frame['deltaTime'], animated,
                                     curve=curve, leap_time=leap_time, calc_lerp=calc_lerp)
        for bone in range(len(BONE_NAMES)):
            errors[bone][0] = max(errors[bone][0], angle_degrees(rotations[bone], recorded[bone]))
            errors[bone][1] = max(errors[bone][1], angle_degrees(state['fixAngle'][bone], recorded_fix[bone]))
        predictions.append((index, rotations, recorded))
    return errors, state, predictions


def write_fixture(path: Path, curve: dict, leap_time: float) -> int:
    """Emit the synthetic FORWARD/FIX sequence the Swift tests replay."""
    def yaw(angle):
        half = math.radians(angle) / 2.0
        return [0.0, math.sin(half), 0.0, math.cos(half)]

    head_start = [0.088910, -0.149518, 0.013501, 0.984661]
    start = initial_state('AWAY', [yaw(-38.0), head_start])
    state = initial_state('AWAY', [yaw(-38.0), head_start])
    steps = []
    schedule = [('FORWARD', 0.01631067), ('FORWARD', 0.01528172), ('FORWARD', 0.2),
                ('FORWARD', 0.5), ('FORWARD', 1.0),
                ('FIX', 0.01859789), ('FIX', 0.3)]
    for look_type, dt in schedule:
        animated = [yaw(-38.0 - 10.0 * dt), head_start]
        state, rotations = neck_step(state, look_type, dt, animated,
                                     curve=curve, leap_time=leap_time)
        steps.append({'lookType': look_type, 'deltaTime': dt, 'animated': animated,
                      'localRotations': rotations, 'fixAngle': state['fixAngle'],
                      'fixAngleBackup': state['fixAngleBackup'], 'timer': state['timer']})
    document = {
        'kind': 'ikkoku-neck-look-reference-fixture',
        'schemaVersion': 1,
        'changeTypeLeapTime': leap_time,
        'changeTypeLerpCurve': curve,
        'curveSamples': [{'t': t, 'value': value} for t, value in
                         ((0.0, 0.002166748046875), (0.25, None), (0.5, None), (1.0, 1.0))],
        'start': start,
        'sequence': steps,
        'savedFix': {'start': initial_state('FIX', [yaw(-20.0), yaw(15.0)]),
                     'lookType': 'FIX', 'deltaTime': 0.0166,
                     'animated': [yaw(0.0), yaw(0.0)]},
    }
    for sample in document['curveSamples']:
        if sample['value'] is None:
            sample['value'] = evaluate_curve(curve['keys'], sample['t'])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=1) + '\n')
    return len(steps)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--trace', required=True, type=Path)
    parser.add_argument('--settings', required=True, type=Path)
    parser.add_argument('--fixture', type=Path, default=None,
                        help='write the synthetic Swift fixture here')
    args = parser.parse_args()
    frames, curve, calc_lerp, leap_time, phases = load_inputs(args.trace, args.settings)
    if args.fixture:
        print(f'fixture steps: {write_fixture(args.fixture, curve, leap_time)}')
    bounds = phase_bounds(frames, phases)
    worst = 0.0
    for phase, look_type in sorted(SIMULATED_PHASES.items()):
        first, last = bounds[phase]
        errors, _, predictions = replay_phase(frames, first, last, look_type,
                                              curve, calc_lerp, leap_time)
        for bone, name in enumerate(BONE_NAMES):
            rotation_error, fix_error = errors[bone]
            worst = max(worst, rotation_error)
            print(f'phase {phase} {look_type} {name}: max rotation error '
                  f'{rotation_error:.6f} deg, max fixAngle error {fix_error:.6f} deg '
                  f'over {last - first} frames')
        if look_type == 'FORWARD' and errors[0][0] > TOLERANCE_DEGREES:
            print('FORWARD misses the target; first 10 frames neck predicted vs recorded:')
            for index, rotations, recorded in predictions[:10]:
                print(f'  frame {index}: predicted {["%.7f" % c for c in rotations[0]]} '
                      f'recorded {["%.7f" % c for c in recorded[0]]}')
    print(f'worst simulated rotation error: {worst:.6f} deg '
          f'(TARGET/AWAY not simulated, ANIMATION checked for no change only)')
    return 0 if worst <= TOLERANCE_DEGREES else 1


if __name__ == '__main__':
    raise SystemExit(main())
