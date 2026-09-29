#!/usr/bin/env python3
"""Replay a look-at capture's phases with the pure EyeLookCalc reference.

Reads one `look-trace.json` made by `original_character_probe.py
--look-patterns` plus the exported studio look settings and steps
`analysis.eye_look_reference.eye_update` over every recorded frame.  Each
frame replays from the recorded state of the frame before it: angleH/angleV
from that frame's `eyes.eyes[i]` (the solver's own smoothed state as the
original left it) and dirUp from its `geometry.eyes[i].dirUp`, while the
geometry (rootNode, trfCenter, per-eye internals), the target and the
deltaTime are the replayed frame's own.  Frame 0 has no frame before it — the
capture starts with the solver already warm — so it seeds from its own
recorded values and is reported as seed-only, not measured.

Per frame the predicted angleH/angleV pair, the eye localRotation and dirUp
are compared with the recorded ones and the maxima reported per phase and
eye.  The predicted frame-end angle rates (the values
EyeLookMaterialControll shifts the iris textures by) are compared with the
frame's calculators[0].angleHRate / angleVRate pair and their maxima reported
per phase too.  A phase whose angle error exceeds the target prints its first
five frames' predicted vs recorded values so the suspected rule can be traced
before any further tuning.
"""
from __future__ import annotations
import argparse
import json
import math
import sys
from pathlib import Path

# analysis.eye_look_reference pulls its vector helpers from its own directory
# (the style every module under analysis/ uses), so the sibling import needs
# that directory on the path regardless of the working directory.
sys.path.insert(0, str(Path(__file__).resolve().parent / 'analysis'))

from eye_look_reference import (angle_between_quaternions, eye_update)

EYE_NAMES = ['EyeTargetL', 'EyeTargetR']
# The type states the reference implements; NO_LOOK and the fixAngle it would
# write are not exercised by the run1 capture.
KNOWN_LOOK_TYPES = ('TARGET', 'AWAY', 'FORWARD', 'CONTROL')
STATE_KEYS = ('thresholdAngleDifference', 'bendingMultiplier', 'maxAngleDifference',
              'upBendingAngle', 'downBendingAngle', 'minBendingAngle', 'maxBendingAngle',
              'leapSpeed', 'forntTagDis', 'nearDis', 'hAngleLimit', 'vAngleLimit')
ANGLE_TARGET_DEGREES = 1e-3
ROTATION_CEILING_DEGREES = 1e-3
DIRUP_CEILING_DEGREES = 0.05


def load_inputs(trace_path: Path, settings_path: Path):
    """Boundary-checked loads of the trace and the eyes settings the replay uses."""
    trace = json.loads(trace_path.read_text())
    settings = json.loads(settings_path.read_text())
    if trace.get('error') not in (None, ''):
        raise ValueError(f"capture recorded an error: {trace['error']}")
    frames, phases = trace.get('frames', []), trace.get('phases', [])
    if not frames or not phases:
        raise ValueError('the trace needs both frames and phases')
    eyes = settings.get('eyes')
    if not isinstance(eyes, dict):
        raise ValueError('the settings need an eyes block')
    if eyes.get('className') != 'EyeLookCalc':
        raise ValueError(f'settings eyes className must be EyeLookCalc, found {eyes.get("className")!r}')
    if eyes.get('correct') != 1:
        raise ValueError('the replay only models correct == 1 (the trfCenter eye target frame)')
    for key in ('centerEyeLength', 'sorasiRate'):
        if not is_finite(eyes.get(key)):
            raise ValueError(f'the settings need a finite eyes {key}')
    type_states = eyes.get('eyeTypeStates', [])
    if len(type_states) <= max(phase['eyesPattern'] for phase in phases):
        raise ValueError('the settings need an eyeTypeStates entry per phase eyesPattern')
    for entry in type_states:
        name = look_type_name(entry)
        if name not in KNOWN_LOOK_TYPES:
            raise ValueError(f'unexpected eye type state lookType {name!r}')
        if not all(is_finite(entry.get(key)) for key in STATE_KEYS):
            raise ValueError(f'eye type state {name} needs finite ' + ', '.join(STATE_KEYS))
    for index, frame in enumerate(frames):
        geometry = frame.get('geometry') or {}
        if 'eyeCalc' not in geometry or len(geometry.get('eyes', [])) != 2:
            raise ValueError(f'frame {index} needs the ST-T07m eyeCalc geometry')
        eyes_state = frame.get('eyes') or {}
        if len(eyes_state.get('eyes', [])) != 2:
            raise ValueError(f'frame {index} needs recorded per-eye solver state')
        if len(eyes_state.get('calculators', [])) != 1:
            raise ValueError(f'frame {index} needs exactly one recorded calculator')
        calculator = eyes_state['calculators'][0]
        if len(calculator.get('angleHRate', [])) != 2 or not is_finite(calculator.get('angleVRate')):
            raise ValueError(f'frame {index} needs a two-entry angleHRate and a finite angleVRate')
    return frames, phases, type_states, eyes


def look_type_name(entry: dict):
    """The lookType name of a type-state entry, which stores a name or a record."""
    look_type = entry.get('lookType')
    return look_type.get('name') if isinstance(look_type, dict) else look_type


def is_finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


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
        raise ValueError('the phases list disagrees with the frames phase field')
    for phase, (first, last) in bounds.items():
        patterns = {frames[index]['eyes']['ptnNo'] for index in range(first, last)}
        if patterns != {phases[phase]['eyesPattern']}:
            raise ValueError(f'phase {phase} eyes frames carry ptnNo {sorted(patterns)}, '
                             f'the phases field says {phases[phase]["eyesPattern"]}')
    return bounds


def seed_state(frames: list, index: int) -> dict:
    """The solver state frame `index` replays from: the recorded angleH/angleV
    and dirUp of the frame before it, or its own recorded values for frame 0
    (the capture starts with the solver warm, so there is nothing earlier)."""
    source = frames[index] if index == 0 else frames[index - 1]
    return {'eyes': [{'angleH': eye['angleH'], 'angleV': eye['angleV'],
                      'dirUp': source['geometry']['eyes'][position]['dirUp']}
                     for position, eye in enumerate(source['eyes']['eyes'])]}


def replay(frames: list, phases: list, type_states: list, eyes: list):
    """Step the reference over every frame; returns (per-phase maxima, misses, frame 0)."""
    bounds = phase_bounds(frames, phases)
    errors: dict[int, list[dict]] = {phase: [{'angleH': 0.0, 'angleV': 0.0, 'rotation': 0.0,
                                              'dirUp': 0.0, 'angleHRate': 0.0, 'at': {}}
                                             for _ in EYE_NAMES]
                                     for phase in bounds}
    # angleVRate is one frame-level value (from eye 0's angleV), so its max
    # sits per phase rather than per eye.
    v_rates: dict[int, dict] = {phase: {'angleVRate': 0.0, 'at': None} for phase in bounds}
    misses: list[tuple[int, list]] = []
    first_frame: list = []
    for index in range(len(frames)):
        frame = frames[index]
        state = seed_state(frames, index)
        predicted = eye_update(state=state,
                               geometry={'eyeCalc': frame['geometry']['eyeCalc'],
                                         'eyes': frame['geometry']['eyes']},
                               target=frame['eyes']['target'], dt=frame['deltaTime'],
                               st=type_states[frame['eyes']['ptnNo']], settings=eyes)
        recorded = frame['eyes']['eyes']
        if index == 0:
            first_frame = [state, predicted, recorded]
            continue
        calculator = frame['eyes']['calculators'][0]
        for eye_index in range(len(EYE_NAMES)):
            measurements = {
                'angleH': abs(predicted[eye_index]['angleH'] - recorded[eye_index]['angleH']),
                'angleV': abs(predicted[eye_index]['angleV'] - recorded[eye_index]['angleV']),
                'rotation': angle_between_quaternions(predicted[eye_index]['localRotation'],
                                                      recorded[eye_index]['localRotation']),
                'dirUp': angle_between_vectors(predicted[eye_index]['dirUp'],
                                               frame['geometry']['eyes'][eye_index]['dirUp']),
                'angleHRate': abs(predicted[eye_index]['angleHRate']
                                  - calculator['angleHRate'][eye_index]),
            }
            entry = errors[frame['phase']][eye_index]
            for name, value in measurements.items():
                if value > entry[name]:
                    entry[name] = value
                    entry['at'][name] = index
        v_error = abs(predicted[0]['angleVRate'] - calculator['angleVRate'])
        if v_error > v_rates[frame['phase']]['angleVRate']:
            v_rates[frame['phase']] = {'angleVRate': v_error, 'at': index}
    for phase in sorted(bounds):
        if max(max(entry['angleH'], entry['angleV']) for entry in errors[phase]) > ANGLE_TARGET_DEGREES:
            misses.append(phase)
    return bounds, errors, v_rates, misses, first_frame


def angle_between_vectors(a: list[float], b: list[float]) -> float:
    """Angle in degrees between two vectors (the dirUp check)."""
    cosine = sum(x * y for x, y in zip(a, b)) / (math.sqrt(sum(x * x for x in a))
                                                 * math.sqrt(sum(x * x for x in b)))
    return math.degrees(math.acos(max(-1.0, min(1.0, cosine))))


def report_miss(frames: list, phases: list, type_states: list, eyes: list, phase: int,
                first: int, last: int) -> None:
    """First five frames of a missing phase, predicted vs recorded angleH/angleV."""
    print(f'phase {phase} {look_type_name(type_states[phases[phase]["eyesPattern"]])} '
          f'misses the {ANGLE_TARGET_DEGREES} deg angle target; first 5 frames:')
    for index in range(first, min(first + 5, last)):
        predicted = eye_update(state=seed_state(frames, index),
                               geometry={'eyeCalc': frames[index]['geometry']['eyeCalc'],
                                         'eyes': frames[index]['geometry']['eyes']},
                               target=frames[index]['eyes']['target'],
                               dt=frames[index]['deltaTime'],
                               st=type_states[frames[index]['eyes']['ptnNo']], settings=eyes)
        for eye_index, name in enumerate(EYE_NAMES):
            recorded = frames[index]['eyes']['eyes'][eye_index]
            print(f'  frame {index} {name}: predicted '
                  f'{predicted[eye_index]["angleH"]:.7f} / {predicted[eye_index]["angleV"]:.7f}, '
                  f'recorded {recorded["angleH"]:.7f} / {recorded["angleV"]:.7f} '
                  f'(lookType frame {frames[index - 1]["eyes"]["ptnNo"]} -> '
                  f'{frames[index]["eyes"]["ptnNo"]}, dt {frames[index]["deltaTime"]})')


def summarise(first_frame: list) -> str:
    """How far the seed-only frame 0 prediction sits from its own recording."""
    if not first_frame:
        return 'frame 0: no prediction'
    state, predicted, recorded = first_frame
    worst = max(max(abs(predicted[index]['angleH'] - eye['angleH']),
                    abs(predicted[index]['angleV'] - eye['angleV']))
                for index, eye in enumerate(recorded))
    return f'frame 0 (seed-only, no frame before it): worst angle difference {worst:.6f} deg'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--trace', required=True, type=Path)
    parser.add_argument('--settings', required=True, type=Path)
    args = parser.parse_args()
    frames, phases, type_states, eyes = load_inputs(args.trace, args.settings)
    bounds, errors, v_rates, misses, first_frame = replay(frames, phases, type_states, eyes)
    for phase, (first, last) in sorted(bounds.items()):
        look_type = look_type_name(type_states[phases[phase]['eyesPattern']])
        for eye_index, name in enumerate(EYE_NAMES):
            entry = errors[phase][eye_index]
            where = entry['at'] or {}
            print(f'phase {phase} {look_type} {name}: max |dH| {entry["angleH"]:.6f} deg '
                  f'(frame {where.get("angleH")}), max |dV| {entry["angleV"]:.6f} deg '
                  f'(frame {where.get("angleV")}), max localRotation {entry["rotation"]:.6f} deg '
                  f'(frame {where.get("rotation")}), max dirUp {entry["dirUp"]:.6f} deg '
                  f'(frame {where.get("dirUp")}), max |dAngleHRate| {entry["angleHRate"]:.6f} '
                  f'(frame {where.get("angleHRate")}) over {last - first} frames')
        v_entry = v_rates[phase]
        print(f'phase {phase} {look_type} angleVRate: max |dVRate| {v_entry["angleVRate"]:.6f} '
              f'(frame {v_entry["at"]}) over {last - first} frames')
    worst_angle = max(max(entry['angleH'], entry['angleV'])
                      for phase_errors in errors.values() for entry in phase_errors)
    worst_rotation = max(entry['rotation'] for phase_errors in errors.values() for entry in phase_errors)
    worst_dir_up = max(entry['dirUp'] for phase_errors in errors.values() for entry in phase_errors)
    # The rates inherit the known AWAY/CONTROL angle misses (they are computed
    # from the same angles), so they are reported, not gated here.
    worst_h_rate = max(entry['angleHRate'] for phase_errors in errors.values() for entry in phase_errors)
    worst_v_rate = max(entry['angleVRate'] for entry in v_rates.values())
    print(summarise(first_frame))
    print(f'worst angle error: {worst_angle:.6f} deg (target {ANGLE_TARGET_DEGREES})')
    print(f'worst localRotation error: {worst_rotation:.6f} deg (ceiling {ROTATION_CEILING_DEGREES})')
    print(f'worst dirUp error: {worst_dir_up:.6f} deg (ceiling {DIRUP_CEILING_DEGREES})')
    print(f'worst angleHRate error: {worst_h_rate:.6f} (from the angles, reported not gated)')
    print(f'worst angleVRate error: {worst_v_rate:.6f} (from the angles, reported not gated)')
    for phase in misses:
        report_miss(frames, phases, type_states, eyes, phase, *bounds[phase])
    if worst_angle > ANGLE_TARGET_DEGREES:
        return 1
    if worst_rotation > ROTATION_CEILING_DEGREES or worst_dir_up > DIRUP_CEILING_DEGREES:
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
