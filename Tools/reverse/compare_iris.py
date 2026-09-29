#!/usr/bin/env python3
"""Replay a look-at capture's iris material writes with the pure Python reference.

Reads one `look-trace.json` made by `original_character_probe.py --look-patterns`
plus the exported studio look settings and replays
`analysis.iris_reference.iris_texture_transforms` over every recorded frame.
The predicted per-texture offset/scale pair — from that frame's
calculators[0].angleHRate/angleVRate, the bo_head_00 exported waits/limits/power
and the card fields `card_values` derives from the trace's irisCard header — is
compared with the Material values the probe read off the live materials.

EyeLookMaterialControll.Update (the texture writes) runs in Update, while
EyeLookCalc refreshes the rates in LateUpdate, so the material recorded at
frame k may carry the rates LateUpdate left at frame k-1.  Which of the two it
is gets fitted empirically per eye (lag 0 vs lag 1, lower offset maximum
wins, reported) rather than assumed.  The `_rotation` the load-time
ChangeSettingEyeTilt wrote is compared with `iris_rotations` from the recorded
shape value 33, and the controller's own offset/scale/highlight fields are
reported against `eye_fields` — recorded values, not gated, so a card-vs-
formula drift stays visible instead of silently absorbed into the prediction.

Exit code 1 whenever any phase's per-texture offset/scale/rotation maximum
exceeds the 1e-6 tolerance.
"""
from __future__ import annotations
import argparse
import json
import math
import sys
from pathlib import Path

# analysis.iris_reference is a sibling of eye_look_reference and imports its
# helpers from its own directory, so the sibling import needs that directory
# on the path regardless of the working directory.
sys.path.insert(0, str(Path(__file__).resolve().parent / 'analysis'))

from iris_reference import (TEX_SLOTS, card_values, eye_fields, iris_rotations,
                            iris_texture_transforms, settings_from_exported)

EYE_GAME_OBJECTS = ['cf_Ohitomi_L02', 'cf_Ohitomi_R02']
CARD_KEYS = ('pupilX', 'pupilY', 'pupilWidth', 'pupilHeight', 'hlUpY', 'hlDownY')
IRIS_TOLERANCE = 1e-6
LAG_CANDIDATES = (0, 1)


def is_finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def load_inputs(trace_path: Path, settings_path: Path):
    """Boundary-checked loads of the trace and the eyeMaterial settings."""
    trace = json.loads(trace_path.read_text())
    settings = json.loads(settings_path.read_text())
    if trace.get('error') not in (None, ''):
        raise ValueError(f"capture recorded an error: {trace['error']}")
    frames, phases = trace.get('frames', []), trace.get('phases', [])
    if not frames or not phases:
        raise ValueError('the trace needs both frames and phases')
    eye_material = settings.get('eyeMaterial')
    if not isinstance(eye_material, list) or len(eye_material) != 2:
        raise ValueError('the settings need a two-entry eyeMaterial block')
    settings = [settings_from_exported(entry) for entry in eye_material]
    card_header = trace.get('irisCard')
    if not isinstance(card_header, dict):
        raise ValueError('the trace needs the irisCard header the probe records once per run')
    for key in CARD_KEYS + ('shapeValueFace33', 'sex', 'exType'):
        if not is_finite(card_header.get(key)):
            raise ValueError(f'the irisCard header needs a finite {key}')
    for index, frame in enumerate(frames):
        calculator = (frame.get('eyes') or {}).get('calculators') or []
        if len(calculator) != 1 or len(calculator[0].get('angleHRate', [])) != 2 \
                or not is_finite(calculator[0].get('angleVRate')):
            raise ValueError(f'frame {index} needs exactly one calculator with a two-entry '
                             'angleHRate and a finite angleVRate')
        iris = frame.get('iris')
        if not isinstance(iris, list) or len(iris) != 2:
            raise ValueError(f'frame {index} needs the two-entry per-frame iris block')
        for material_index, material in enumerate(iris):
            if material.get('gameObject') != EYE_GAME_OBJECTS[material_index]:
                raise ValueError(f'frame {index} iris entry {material_index} is for '
                                 f'{material.get("gameObject")!r}, not {EYE_GAME_OBJECTS[material_index]!r}')
            for key in ('rotation',):
                if not is_finite(material.get(key)):
                    raise ValueError(f'frame {index} iris entry {material_index} needs a finite {key}')
            textures = material.get('textures') or {}
            for slot in TEX_SLOTS:
                entry = textures.get(slot) or {}
                for key in ('offset', 'scale'):
                    pair = entry.get(key)
                    if not isinstance(pair, list) or len(pair) != 2 or not all(is_finite(v) for v in pair):
                        raise ValueError(f'frame {index} iris entry {material_index} needs a finite '
                                         f'{slot} {key} pair')
    return frames, phases, settings, card_values(*[card_header[key] for key in CARD_KEYS],
                                                 sex=card_header['sex'], ex_type=card_header['exType']), \
        card_header['shapeValueFace33']


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
    return bounds


def predict(frame: dict, settings: list, card):
    """The three predicted texture transforms per eye for one frame's rates."""
    calculator = frame['eyes']['calculators'][0]
    prediction = []
    for eye_index in range(2):
        transforms = iris_texture_transforms(calculator['angleHRate'][eye_index],
                                             calculator['angleVRate'],
                                             settings[eye_index], card)
        prediction.append({entry['texName']: entry for entry in transforms})
    return prediction


def differences(predicted: dict, recorded: dict) -> dict:
    """Per-texture |offset| / |scale| differences between prediction and capture."""
    out = {}
    for slot in TEX_SLOTS:
        prediction, recording = predicted[slot], recorded['textures'][slot]
        out[slot] = [max(abs(a - b) for a, b in zip(prediction['offset'], recording['offset'])),
                     max(abs(a - b) for a, b in zip(prediction['scale'], recording['scale']))]
    return out


def fit_lags(frames: list, settings: list, card) -> dict[int, int]:
    """Per eye, the lag candidate whose prediction matches the recorded materials best."""
    maxima = {lag: [0.0, 0.0] for lag in LAG_CANDIDATES}
    for index in range(len(frames)):
        for lag in LAG_CANDIDATES:
            if index < lag:
                continue
            predicted = predict(frames[index - lag], settings, card)
            for eye_index in range(2):
                diffs = differences(predicted[eye_index], frames[index]['iris'][eye_index])
                worst = max(max(diffs[slot]) for slot in TEX_SLOTS)
                if worst > maxima[lag][eye_index]:
                    maxima[lag][eye_index] = worst
    lags = {}
    for eye_index in range(2):
        winner = min(LAG_CANDIDATES, key=lambda lag: maxima[lag][eye_index])
        print(f'{EYE_GAME_OBJECTS[eye_index]} lag fit: worst offset/scale difference lag 0 '
              f'{maxima[0][eye_index]:.9f}, lag 1 {maxima[1][eye_index]:.9f} -> fitted lag '
              f'{winner} over {len(frames) - winner} frames')
        lags[eye_index] = winner
    return lags


def replay(frames: list, phases: list, settings: list, card, lag: dict[int, int],
           rotation_expected: list[float]):
    """Per-phase, per-eye, per-texture offset/scale maxima under the fitted lags."""
    bounds = phase_bounds(frames, phases)
    errors: dict[int, list[list[dict]]] = {
        phase: [[{'offset': 0.0, 'scale': 0.0, 'rotation': 0.0, 'at': {}}
                 for _ in TEX_SLOTS] for _ in EYE_GAME_OBJECTS] for phase in bounds}
    # The controller's own offset/scale/highlight fields the probe read by
    # reflection, reported against eye_fields; never gates the run.
    fields = [[0.0] * 5 for _ in EYE_GAME_OBJECTS]
    field_names = ['offset.x', 'offset.y', 'scale.x', 'scale.y', 'hl']
    # The first `lag` frames' materials were written from rates the trace
    # never captured (the probe starts with the controller already running),
    # so they are seed-only, like compare_eye_look's frame 0, not measured.
    seed = [[0.0, None] for _ in EYE_GAME_OBJECTS]
    for index in range(len(frames)):
        frame = frames[index]
        for eye_index in range(2):
            material = frame['iris'][eye_index]
            if index < lag[eye_index]:
                # The material still holds the write of a frame before the
                # trace started; predict from this frame's own rates only to
                # size how far that seed sits, never as a measurement.
                predicted = predict(frame, settings, card)
                worst = max(max(differences(predicted[eye_index], material)[slot])
                            for slot in TEX_SLOTS)
                if worst > seed[eye_index][0]:
                    seed[eye_index] = [worst, index]
                continue
            expected = predict(frames[index - lag[eye_index]], settings, card)[eye_index]
            for slot in TEX_SLOTS:
                slot_diff = differences(expected, material)[slot]
                entry = errors[frame['phase']][eye_index][TEX_SLOTS.index(slot)]
                if slot_diff[0] > entry['offset']:
                    entry['offset'] = slot_diff[0]
                    entry['at']['offset'] = index
                if slot_diff[1] > entry['scale']:
                    entry['scale'] = slot_diff[1]
                    entry['at']['scale'] = index
            rotation = abs(material['rotation'] - rotation_expected[eye_index])
            entry = errors[frame['phase']][eye_index][0]
            if rotation > entry['rotation']:
                entry['rotation'] = rotation
                entry['at']['rotation'] = index
        # Field drift: what the controller actually held vs what the card
        # formulas compute from the irisCard header (constant per run).
        for eye_index in range(2):
            expected = eye_fields(settings[eye_index], card)
            held = frame['iris'][eye_index]
            drift = [abs(held['offset'][0] - expected['offset'][0]),
                     abs(held['offset'][1] - expected['offset'][1]),
                     abs(held['scale'][0] - expected['scale'][0]),
                     abs(held['scale'][1] - expected['scale'][1]),
                     max(abs(held['hlUpOffsetY'] - expected['hlUpOffsetY']),
                         abs(held['hlDownOffsetY'] - expected['hlDownOffsetY']))]
            for position, value in enumerate(drift):
                if value > fields[eye_index][position]:
                    fields[eye_index][position] = value
    return bounds, errors, fields, field_names, seed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--trace', required=True, type=Path)
    parser.add_argument('--settings', required=True, type=Path)
    args = parser.parse_args()
    frames, phases, settings, card, shape_value = load_inputs(args.trace, args.settings)
    if card is None:
        print('the irisCard header says the special-male body skips the eye setters; '
              'the prefab snapshot stays (nothing to predict)')
        return 0
    print(f'card fields: offset {card["offsetX"]} / {card["offsetY"]}, scale {card["scale"]}, '
          f'hl {card["hlUp"]} / {card["hlDown"]}')
    rotation_expected = iris_rotations(shape_value)
    print(f'expected _rotation from shapeValueFace33 {shape_value}: '
          f'{rotation_expected[0]} / {rotation_expected[1]}')
    lag = fit_lags(frames, settings, card)
    bounds, errors, fields, field_names, seed = replay(frames, phases, settings, card, lag,
                                                       rotation_expected)
    for phase, (first, last) in sorted(bounds.items()):
        for eye_index, game_object in enumerate(EYE_GAME_OBJECTS):
            for slot_index, slot in enumerate(TEX_SLOTS):
                entry = errors[phase][eye_index][slot_index]
                where = entry['at']
                suffix = f'; max rotation {entry["rotation"]:.9f} (frame {where.get("rotation")})' \
                    if slot_index == 0 else ''
                print(f'phase {phase} {game_object} {slot}: max |offset| '
                      f'{entry["offset"]:.9f} (frame {where.get("offset")}), max |scale| '
                      f'{entry["scale"]:.9f} (frame {where.get("scale")}) over {last - first} '
                      f'frames{suffix}')
    worst = max(max(entry['offset'], entry['scale'], entry['rotation'])
                for phase_errors in errors.values() for eye_errors in phase_errors
                for entry in eye_errors)
    for eye_index, game_object in enumerate(EYE_GAME_OBJECTS):
        if seed[eye_index][1] is not None:
            print(f'{game_object} seed-only frame {seed[eye_index][1]} (before lag {lag[eye_index]}, '
                  f'the material holds a write from before the trace): worst offset/scale '
                  f'difference {seed[eye_index][0]:.9f} (reported, not measured)')
    for eye_index, game_object in enumerate(EYE_GAME_OBJECTS):
        print(f'{game_object} recorded controller fields drift vs eye_fields: ' +
              ', '.join(f'{name} {value:.9f}' for name, value in zip(field_names, fields[eye_index])) +
              ' (reported, not gated)')
    print(f'worst iris texture transform difference: {worst:.9f} (tolerance {IRIS_TOLERANCE})')
    return 1 if worst > IRIS_TOLERANCE else 0


if __name__ == '__main__':
    raise SystemExit(main())
