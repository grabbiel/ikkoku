#!/usr/bin/env python3
"""Compare original Studio hand-pattern captures with the converted library.

Reads one capture directory made by `original_character_probe.py
--hand-patterns` (`hand-anime.json`, whose frames mirror `RecordFingers`, plus
the pattern IDs recorded in `fingers.json`) and the library written by
`studio_hand_animation.py --all-patterns`. For every recorded frame the clip
time is the hand Animator's own loop phase — the fractional part of
`normalizedTime` scaled by the converted clip's stopTime, which avoids the
f32 length rounding at loop seams; that instant is replayed exactly like
`SourceStudioHandPatterns.pose` (loop wrap into [startTime, stopTime),
per-component interpolation between adjacent dense frames, quaternion
normalize) and compared bone-by-bone with the captured local rotations. The
maximum rotation angle is reported per pattern and hand, so the recorded
playhead replaces the phase earlier slices had to fit. When frame.json is
present, its hand finger bones are also checked at frameJsonCapture's phase.
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ROTATION_TOLERANCE_DEGREES = 0.01


def wrapped_time(pattern: dict, time: float) -> float:
    """Fold a playhead into the looping clip, as the native evaluator does."""
    start, stop = pattern['clip']['startTime'], pattern['clip']['stopTime']
    duration = stop - start
    if duration <= 0:
        raise ValueError(f"pattern {pattern['id']}: clip does not span a positive interval")
    if not math.isfinite(time):
        raise ValueError(f"pattern {pattern['id']}: clip time must be finite")
    return start + (time - start) % duration


def sample_frames(frames: list[list[float]], times: list[float], rate: float, at: float) -> list[float]:
    """Componentwise sampling between adjacent dense frames, mirroring the engine."""
    if len(times) == 1:
        return list(frames[0])
    position = min(max((at - times[0]) * rate, 0.0), float(len(frames) - 1))
    lower = int(position)
    upper = min(lower + 1, len(frames) - 1)
    fraction = position - lower
    return [a * (1 - fraction) + b * fraction for a, b in zip(frames[lower], frames[upper])]


def angle_degrees(a: list[float], b: list[float]) -> float:
    """Smallest rotation angle between two quaternions.

    Both inputs are normalized first: the probe records Unity's f32
    localRotation, whose norm can sit 1e-8 off one, and acos turns that
    storage deficit into a phantom 0.02° between identical rotations. The
    angle between the two rotations is a property of their direction only.
    """
    def unit(q):
        length = math.sqrt(sum(component * component for component in q))
        if length <= 0 or not all(math.isfinite(component) for component in q):
            raise ValueError('cannot measure an angle against a zero-length quaternion')
        return [component / length for component in q]
    a, b = unit(a), unit(b)
    dot = sum(x * y for x, y in zip(a, b))
    return 2 * math.degrees(math.acos(min(1.0, abs(dot))))


def validate_library(library: dict) -> None:
    """Boundary checks mirroring the fields the replay depends on."""
    if library.get('schemaVersion') != 1 or library.get('converterVersion') != '1.0.0' \
            or library.get('kind') != 'ikkoku-studio-hand-patterns' \
            or library.get('scope') != 'hand-anime-table-states-generic-transforms':
        raise ValueError('Unsupported studio hand pattern library')
    if set(library['hands']) != {'L', 'R'}:
        raise ValueError('The hand pattern library needs both hands')
    for hand, entry in library['hands'].items():
        ids = [pattern['id'] for pattern in entry['patterns']]
        if not ids or sorted(ids) != list(range(1, len(ids) + 1)):
            raise ValueError(f'{hand} hand pattern IDs must run from 1 without gaps')
        for pattern in entry['patterns']:
            clip = pattern['clip']
            if not clip['loop'] or clip['startTime'] != 0 or clip['stopTime'] <= 0 or clip['sampleRate'] <= 0 \
                    or not pattern['frameTimes']:
                raise ValueError(f"{hand} hand pattern {pattern['id']} is outside the converted limits")
            if pattern['frameTimes'][0] != clip['startTime']:
                raise ValueError(f"{hand} hand pattern {pattern['id']} frame times start outside the clip")
            if any(bone['frames'] and len(component) != 4 for bone in pattern['bones'].values() for component in bone['frames']):
                raise ValueError(f"{hand} hand pattern {pattern['id']} carries a non-quaternion rotation frame")


def library_pattern(library: dict, hand: str, pattern_id: int) -> dict:
    if pattern_id == 0:
        raise ValueError(f'{hand} hand pattern 0 disables the Animator; there is no pose to compare')
    for pattern in library['hands'][hand]['patterns']:
        if pattern['id'] == pattern_id:
            return pattern
    raise ValueError(f'{hand} hand pattern {pattern_id} has no converted clip in the library')


def pattern_rotation(pattern: dict, bone: str, clip_time: float) -> list[float]:
    """Evaluate one bone's rotation exactly like SourceStudioHandPatterns.pose."""
    frames = pattern['bones'][bone]['frames']
    sampled = sample_frames(frames, pattern['frameTimes'], pattern['clip']['sampleRate'], wrapped_time(pattern, clip_time))
    length = math.sqrt(sum(component * component for component in sampled))
    if not all(math.isfinite(component) for component in sampled) or length <= 0:
        raise ValueError(f"pattern {pattern['id']}: interpolation left {bone} without a rotation")
    return [component / length for component in sampled]


def capture_patterns(fingers: list) -> dict[str, int]:
    """Read the L/R pattern IDs the probe recorded into its finger snapshots."""
    for record in fingers:
        recorded = record.get('handPatterns')
        if recorded is not None:
            if set(recorded) != {'L', 'R'}:
                raise ValueError('The capture recorded hand patterns without both sides')
            return {side: int(recorded[side]) for side in ('L', 'R')}
    raise ValueError('fingers.json records no hand-pattern mode; this capture predates the pattern probe')


def compare_frame(library: dict, side: str, pattern_id: int, frame: dict) -> dict:
    """Replay one recorded snapshot at its own playhead and measure every bone."""
    animator = frame['hands'][side]
    if not animator.get('exists'):
        raise ValueError(f'{side} hand animator is missing from the capture')
    pattern = library_pattern(library, side, pattern_id)
    # Unity's state length is an f32 of the clip duration, a hair off the
    # library's f64 stopTime; folding `normalizedTime * length` by stopTime
    # would land whole loops at the very last frame instead of the first
    # (0.34° at pattern 3's seam while the library's first frame matched the
    # capture to 0.0000°). The loop count is therefore folded out first and
    # the phase is scaled by the library's own clip length.
    normalized = animator['normalizedTime']
    clip_time = (normalized - math.floor(normalized)) * pattern['clip']['stopTime']
    bones = []
    for bone_name, samples in sorted(frame['bones'].items()):
        # The probe samples three finger bones per snapshot (middle01_L,
        # middle02_L, thumb01_R); each side is judged only by its own bones.
        if not bone_name.startswith('cf_j_') or not bone_name.endswith('_' + side):
            continue
        if len(samples) != 1:
            raise ValueError(f'{bone_name}: the capture expected one sample list, found {len(samples)}')
        if bone_name not in pattern['bones']:
            raise ValueError(f'{bone_name}: the converted {side} pattern {pattern_id} has no rotation for this bone')
        bones.append({'bone': bone_name, 'angleDegrees': angle_degrees(
            pattern_rotation(pattern, bone_name, clip_time), samples[0]['localRotation'])})
    if not bones:
        raise ValueError(f'{side} hand snapshot {frame["moment"]} recorded no finger bones')
    return {'moment': frame['moment'], 'clipTime': clip_time, 'stateLength': animator['length'],
            'stateShortNameHash': animator['shortNameHash'], 'clipStopTime': pattern['clip']['stopTime'],
            'bones': bones, 'maxAngleDegrees': max(bone['angleDegrees'] for bone in bones)}


def compare_all_bones(pattern: dict, side: str, clip_time: float, frame_json: dict) -> dict:
    """Measure every library finger bone under this hand in frame.json."""
    angles = []
    hand_path = f'/cf_s_hand_{side}/'
    for record in frame_json['bones']:
        path = record['path']
        bone = path.rsplit('/', 1)[-1]
        if hand_path in path and bone in pattern['bones']:
            angles.append((bone, angle_degrees(
                pattern_rotation(pattern, bone, clip_time), record['rotation'])))
    if not angles:
        raise ValueError(f'frame.json contains no {side} hand finger bones from the library')
    worst_bone, maximum = max(angles, key=lambda entry: entry[1])
    return {'count': len(angles), 'maxDegrees': maximum, 'worstBone': worst_bone}


def compare_capture(library: dict, frames: list, patterns: dict[str, int],
                    frame_json: dict | None = None) -> dict:
    """Compare every recorded frame of both hands and aggregate per side."""
    per_side = {}
    for side in ('L', 'R'):
        results = [compare_frame(library, side, patterns[side], frame) for frame in frames]
        bone_max: dict[str, float] = {}
        for result in results:
            for bone in result['bones']:
                bone_max[bone['bone']] = max(bone_max.get(bone['bone'], 0.0), bone['angleDegrees'])
        sampled_max = max(result['maxAngleDegrees'] for result in results)
        all_bones = None
        if frame_json is not None:
            captures = [result for result in results if result['moment'] == 'frameJsonCapture']
            if len(captures) != 1:
                raise ValueError('frame.json requires exactly one frameJsonCapture hand-anime entry')
            all_bones = compare_all_bones(library_pattern(library, side, patterns[side]),
                                          side, captures[0]['clipTime'], frame_json)
        side_max = max(sampled_max, all_bones['maxDegrees']) if all_bones else sampled_max
        per_side[side] = {'pattern': patterns[side], 'frames': len(results),
                          'clipTimeMin': min(result['clipTime'] for result in results),
                          'clipTimeMax': max(result['clipTime'] for result in results),
                          'maxAngleDegrees': side_max,
                          'boneMaxAngleDegrees': bone_max,
                          'frameResults': results}
        if all_bones is not None:
            per_side[side]['allBones'] = all_bones
    overall = max(side['maxAngleDegrees'] for side in per_side.values())
    return {'schemaVersion': 1, 'kind': 'ikkoku-hand-pattern-capture-comparison',
            'scope': 'recorded-animator-playhead-vs-converted-library-rotation',
            'patterns': dict(patterns), 'perSide': per_side, 'maxAngleDegrees': overall,
            'rotationToleranceDegrees': ROTATION_TOLERANCE_DEGREES,
            'passed': overall <= ROTATION_TOLERANCE_DEGREES,
            'diagnostics': ['Clip time is the recorded Animator loop phase (fractional part of normalizedTime scaled by the converted clip length), so no phase is fitted.',
                            'Only the rotation channel is compared; scale keys are converted but not captured by this probe.',
                            'Short name hashes are recorded verbatim; the library names each state and cannot recompute Unity state hashes.']}


def compare_capture_folder(library: dict, capture: Path) -> dict:
    frames = json.loads((capture / 'hand-anime.json').read_text())
    if not frames:
        raise ValueError('hand-anime.json recorded no frames')
    patterns = capture_patterns(json.loads((capture / 'fingers.json').read_text()))
    frame_path = capture / 'frame.json'
    frame_json = json.loads(frame_path.read_text()) if frame_path.is_file() else None
    return compare_capture(library, frames, patterns, frame_json)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True, help='capture directory holding hand-anime.json')
    parser.add_argument('--library', type=Path, default=REPO / '.local/stt07f/studio-hand-patterns.json')
    parser.add_argument('--output', type=Path, help='comparison JSON; defaults inside the capture directory')
    args = parser.parse_args()
    library = json.loads(args.library.read_text())
    validate_library(library)
    report = compare_capture_folder(library, args.capture)
    report['library'] = str(args.library)
    report['capture'] = str(args.capture)
    output = (args.output or args.capture / 'hand-pattern-comparison.json').resolve()
    if not output.is_relative_to(REPO / '.local'):
        raise ValueError('Comparison output must stay inside .local')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, separators=(',', ':'), allow_nan=False) + '\n')
    print(json.dumps({'output': str(output), 'patterns': report['patterns'],
                      'perSide': {side: {'pattern': data['pattern'], 'frames': data['frames'],
                                         'clipTimeMin': data['clipTimeMin'], 'clipTimeMax': data['clipTimeMax'],
                                         'maxAngleDegrees': data['maxAngleDegrees'],
                                         **({'allBones': data['allBones']} if 'allBones' in data else {})}
                                  for side, data in report['perSide'].items()},
                      'maxAngleDegrees': report['maxAngleDegrees'], 'passed': report['passed']}))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
