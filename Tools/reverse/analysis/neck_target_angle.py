#!/usr/bin/env python3
"""Re-computation of the original NeckLookCalcVer2.GetAngleToTarget angle.

Pure reconstruction of the recovered TARGET / AWAY target-angle formula and
its limit check, run against the end-of-frame world geometry the ST-T07m
probe records (look-trace.json `geometry` entries).  The recorded nowAngle of
a TARGET frame is compared with the prediction under both head-rotation
assumptions the recovered NeckUpdateCalc could plausibly read — the previous
recorded frame's end-of-frame head rotation and the frame's own — and the
capture answers which: the previous-frame assumption is decisively refuted
(max 4.09 deg over 300 TARGET frames) while the frame's own head rotation
reproduces every TARGET frame within 0.082 deg on x and 0.017 deg on y.  The
x maximum is one unexplained recorded-nowAngle step at frame 328 (2.174659 to
2.092841 while the end-of-frame geometry predicts 2.1747 on both sides of the
step); every other changed frame of the capture matches within 0.0033 deg on
x, and a TARGET frame whose recorded nowAngle is byte-identical to the
previous frame of its phase is counted as held (the solver did not recompute
it).  AWAY frames report the raw formula output next to the adjusted recorded
value instead of asserting equality.  Vectors are plain x,y,z lists and
quaternions Unity x,y,z,w lists; every vector read is re-derived from the
recorded rotation instead of trusting Unity-axis fields.
"""
from __future__ import annotations

import math

FORWARD = [0.0, 0.0, 1.0]
UP = [0.0, 1.0, 0.0]
RIGHT = [1.0, 0.0, 0.0]


def _vector(value: list[float], what: str) -> list[float]:
    if len(value) != 3 or not all(math.isfinite(component) for component in value):
        raise ValueError(f'{what} is not a finite xyz vector: {value!r}')
    return [float(component) for component in value]


def _quaternion(value: list[float], what: str) -> list[float]:
    if len(value) != 4 or not all(math.isfinite(component) for component in value):
        raise ValueError(f'{what} is not a finite xyzw quaternion: {value!r}')
    return [float(component) for component in value]


def sub(a: list[float], b: list[float]) -> list[float]:
    a, b = _vector(a, 'sub left'), _vector(b, 'sub right')
    return [left - right for left, right in zip(a, b)]


def dot(a: list[float], b: list[float]) -> float:
    a, b = _vector(a, 'dot left'), _vector(b, 'dot right')
    return sum(left * right for left, right in zip(a, b))


def cross(a: list[float], b: list[float]) -> list[float]:
    a, b = _vector(a, 'cross left'), _vector(b, 'cross right')
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def length(a: list[float]) -> float:
    return math.sqrt(dot(a, a))


def normalize(a: list[float]) -> list[float]:
    a = _vector(a, 'normalize input')
    size = length(a)
    if size <= 0.0:
        raise ValueError('cannot normalize a zero-length vector')
    return [component / size for component in a]


def project(a: list[float], normal: list[float]) -> list[float]:
    """Unity Vector3.Project(a, normal) = normal * Dot(a, normal) / Dot(normal, normal)."""
    a, normal = _vector(a, 'project vector'), _vector(normal, 'project normal')
    squared = dot(normal, normal)
    if squared <= 0.0:
        raise ValueError('cannot project onto a zero-length normal')
    factor = dot(a, normal) / squared
    return [factor * component for component in normal]


def angle_degrees(a: list[float], b: list[float]) -> float:
    """Unity Vector3.Angle: unsigned angle in degrees, 0 for a zero operand."""
    a, b = _vector(a, 'angle left'), _vector(b, 'angle right')
    if length(a) <= 1e-5 or length(b) <= 1e-5:
        return 0.0
    cosine = dot(a, b) / (length(a) * length(b))
    return math.degrees(math.acos(min(1.0, max(-1.0, cosine))))


def angle_around_axis(a: list[float], b: list[float], axis: list[float]) -> float:
    """The recovered AngleAroundAxis: the projected vectors' unsigned angle,

    negated when Dot(axis, Cross(a, b)) is negative (Unity Vector3.SignedAngle
    handedness, left-handed Unity space).
    """
    a = sub(_vector(a, 'angle-around left'), project(_vector(a, 'angle-around left'), _vector(axis, 'angle-around axis')))
    b = sub(_vector(b, 'angle-around right'), project(_vector(b, 'angle-around right'), _vector(axis, 'angle-around axis')))
    signed = -1.0 if dot(axis, cross(a, b)) < 0.0 else 1.0
    return angle_degrees(a, b) * signed


def rotate(quaternion: list[float], v: list[float]) -> list[float]:
    """Rotate a vector by a unit-normalized Unity quaternion (q * v)."""
    q = _quaternion(quaternion, 'rotate quaternion')
    v = _vector(v, 'rotate vector')
    size = math.sqrt(sum(component * component for component in q))
    x, y, z, w = [component / size for component in q]
    # Unity Quaternion.RotateVector: v + w * t + Cross(q.xyz, t), t = 2 * Cross(q.xyz, v).
    t = [2.0 * (y * v[2] - z * v[1]),
         2.0 * (z * v[0] - x * v[2]),
         2.0 * (x * v[1] - y * v[0])]
    return [v[0] + w * t[0] + y * t[2] - z * t[1],
            v[1] + w * t[1] + z * t[0] - x * t[2],
            v[2] + w * t[2] + x * t[1] - y * t[0]]


def multiply_quaternions(a: list[float], b: list[float]) -> list[float]:
    """Unity Quaternion operator * (a * b): apply b first, then a."""
    a, b = _quaternion(a, 'quaternion left'), _quaternion(b, 'quaternion right')
    return [a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
            a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
            a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
            a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]]


def from_to_rotation(from_direction: list[float], to_direction: list[float]) -> list[float]:
    """Unity Quaternion.FromToRotation: shortest arc taking one direction to another."""
    a = normalize(_vector(from_direction, 'from-to source'))
    b = normalize(_vector(to_direction, 'from-to target'))
    alignment = dot(a, b)
    if alignment > 1.0 - 1e-6:
        return [0.0, 0.0, 0.0, 1.0]
    if alignment < -1.0 + 1e-6:
        axis = cross(RIGHT, a)
        if length(axis) <= 1e-5:
            axis = cross(UP, a)
        return angle_axis(180.0, normalize(axis))
    perpendicular = cross(a, b)
    quaternion = [perpendicular[0], perpendicular[1], perpendicular[2], 1.0 + alignment]
    size = math.sqrt(sum(component * component for component in quaternion))
    return [component / size for component in quaternion]


def angle_axis(angle: float, axis: list[float]) -> list[float]:
    """Unity Quaternion.AngleAxis: right-hand rule about the axis, in degrees."""
    unit = normalize(_vector(axis, 'angle-axis axis'))
    half = math.radians(angle) * 0.5
    scale = math.sin(half)
    return [unit[0] * scale, unit[1] * scale, unit[2] * scale, math.cos(half)]


def _axis_of(rotation: list[float], direction: list[float]) -> list[float]:
    return rotate(rotation, direction)


def limit_check(*, target: list[float], reference_position: list[float], reference_rotation: list[float],
                horizontal_limit: float, vertical_limit: float, correction: float) -> tuple[bool, float, float]:
    """The recovered limit check before GetAngleToTarget's angle is kept.

    Returns (broken, f, f2) with f the up-referenced and f2 the right-referenced
    signed target angle about NeckRef; broken is true when |f| or |f2| exceeds
    its limit plus the correction (0 while the state is limit-break backup).
    """
    target = _vector(target, 'limit target')
    offset = sub(target, _vector(reference_position, 'limit reference position'))
    up = _axis_of(_quaternion(reference_rotation, 'limit reference rotation'), UP)
    right = _axis_of(_quaternion(reference_rotation, 'limit reference rotation'), RIGHT)
    forward = _axis_of(_quaternion(reference_rotation, 'limit reference rotation'), FORWARD)
    horizontal = angle_around_axis(forward, offset, up)
    vertical = angle_around_axis(forward, offset, right)
    broken = abs(horizontal) > horizontal_limit + correction or abs(vertical) > vertical_limit + correction
    return broken, horizontal, vertical


def get_angle_to_target(*, target: list[float], aim_position: list[float], aim_rotation: list[float],
                        reference_position: list[float], reference_rotation: list[float],
                        head_rotation: list[float]) -> list[float]:
    """The recovered GetAngleToTarget, as (x, y) degrees."""
    aim_position = _vector(aim_position, 'aim position')
    aim_rotation = _quaternion(aim_rotation, 'aim rotation')
    head_rotation = _quaternion(head_rotation, 'head rotation')
    reference_rotation = _quaternion(reference_rotation, 'reference rotation')
    offset = sub(_vector(target, 'target position'), aim_position)
    if length(offset) <= 1e-5:
        raise ValueError('the target sits on the aim origin, the angle is undefined')
    swing = from_to_rotation(rotate(aim_rotation, FORWARD), offset)
    swung_head = multiply_quaternions(swing, head_rotation)
    up = _axis_of(reference_rotation, UP)
    forward = _axis_of(reference_rotation, FORWARD)
    _ = _vector(reference_position, 'reference position')  # validated, the angle itself reads only axes
    y = angle_around_axis(forward, rotate(swung_head, FORWARD), up)
    rolled = multiply_quaternions(angle_axis(y, up), reference_rotation)
    axis = cross(up, rotate(rolled, FORWARD))
    x = angle_around_axis(rotate(rolled, FORWARD), rotate(swung_head, FORWARD), axis)
    return [x, y]


def predict_now_angle(*, frame: dict, head_rotation: list[float], state: dict) -> list[float]:
    """Predict one recorded frame's nowAngle from its geometry.

    `frame` is a look-trace.json frame record, `head_rotation` the world
    rotation assumed for the head bone at the start of that frame's
    NeckUpdateCalc, and `state` the frame's neckTypeStates settings
    (hAngleLimit, vAngleLimit, limitBreakCorrectionValue).
    """
    geometry = frame['geometry']
    reference = geometry['neckRef']
    target = _vector(frame['neck']['target'], 'recorded target position')
    correction = 0.0 if geometry['isLimitBreakBackup'] else float(state['limitBreakCorrectionValue'])
    broken, _, _ = limit_check(target=target, reference_position=reference['position'],
                               reference_rotation=reference['rotation'],
                               horizontal_limit=float(state['hAngleLimit']),
                               vertical_limit=float(state['vAngleLimit']), correction=correction)
    if broken:
        return [0.0, 0.0]
    return get_angle_to_target(target=target, aim_position=geometry['aim']['position'],
                               aim_rotation=geometry['aim']['rotation'],
                               reference_position=reference['position'], reference_rotation=reference['rotation'],
                               head_rotation=head_rotation)


def _states(settings: dict) -> list[dict]:
    try:
        states = settings['neck']['neckTypeStates']
    except (KeyError, TypeError) as error:
        raise ValueError('the settings file holds no neck.neckTypeStates list') from error
    if not isinstance(states, list) or not states:
        raise ValueError('the settings file holds no neck.neckTypeStates list')
    return states


def _state_for(states: list[dict], frame: dict) -> dict:
    ptn_no = frame['neck']['ptnNo']
    if not isinstance(ptn_no, int) or not 0 <= ptn_no < len(states):
        raise ValueError(f'frame has ptnNo {ptn_no}, outside the {len(states)} recorded neckTypeStates')
    return states[ptn_no]


def verify_trace(trace: dict, settings: dict) -> dict:
    """Compare the recorded nowAngle with the formula for every TARGET/AWAY frame.

    TARGET frames are checked under the frame-k-1 head assumption (the head
    rotation the recovered NeckUpdateCalc reads after UpdateCall wrote the
    previous frame's fixAngle back) and, for comparison, under the frame-k one.
    A TARGET frame whose recorded nowAngle is byte-identical to the previous
    recorded frame of its phase is held (the solver did not recompute it) and
    counted per phase; the moved-frame maximum excludes held frames.  AWAY
    frames get the raw (unlimited) formula output next to the recorded
    adjusted nowAngle, without an equality claim.
    """
    if trace.get('error'):
        raise ValueError(f'the capture reported an error: {trace["error"]}')
    states = _states(settings)
    frames = trace.get('frames') or []
    phases: dict[int, list[dict]] = {}
    for index, frame in enumerate(frames):
        phase = frame.get('phase')
        if phase is None:
            raise ValueError(f'frame {index} has no phase')
        phases.setdefault(phase, []).append(frame)
    for phase, phase_frames in phases.items():
        if any(frame.get('geometry') is None for frame in phase_frames):
            raise ValueError(f'phase {phase} has frames without recorded geometry (needs the ST-T07m probe)')
    report: dict = {'phases': {}, 'targetFrames': 0, 'awayFrames': []}
    for phase in sorted(phases):
        phase_report = {'targetFrames': 0, 'previousMaxDegrees': [0.0, 0.0], 'sameFrameMaxDegrees': [0.0, 0.0],
                        'movedMaxDegrees': [0.0, 0.0], 'heldFrames': 0, 'awayFrames': 0}
        report['phases'][phase] = phase_report
        for index, frame in enumerate(phases[phase]):
            look_type = frame['neck']['calculators'][0]['lookType']
            state = _state_for(states, frame)
            recorded = frame['neck']['calculators'][0]['nowAngle']
            current_head = frame['geometry']['headBone']['rotation']
            if look_type == 'TARGET':
                previous_frame = phases[phase][index - 1] if index > 0 else None
                previous_head = previous_frame['geometry']['headBone']['rotation'] if previous_frame else None
                held = previous_frame is not None and previous_frame['neck']['calculators'][0]['nowAngle'] == recorded
                assumptions = (('sameFrameMaxDegrees', current_head),)
                if previous_head is not None:
                    assumptions = (('previousMaxDegrees', previous_head),) + assumptions
                for assumption, head_rotation in assumptions:
                    predicted = predict_now_angle(frame=frame, head_rotation=head_rotation, state=state)
                    maximum = phase_report[assumption]
                    phase_report[assumption] = [max(maximum[0], abs(predicted[0] - recorded[0])),
                                                max(maximum[1], abs(predicted[1] - recorded[1]))]
                    if assumption == 'sameFrameMaxDegrees' and not held:
                        moved = phase_report['movedMaxDegrees']
                        phase_report['movedMaxDegrees'] = [max(moved[0], abs(predicted[0] - recorded[0])),
                                                           max(moved[1], abs(predicted[1] - recorded[1]))]
                if held:
                    phase_report['heldFrames'] += 1
                phase_report['targetFrames'] += 1
                report['targetFrames'] += 1
            elif look_type == 'AWAY':
                broken, horizontal, vertical = limit_check(
                    target=_vector(frame['neck']['target'], 'recorded target position'),
                    reference_position=frame['geometry']['neckRef']['position'],
                    reference_rotation=frame['geometry']['neckRef']['rotation'],
                    horizontal_limit=float(state['hAngleLimit']), vertical_limit=float(state['vAngleLimit']),
                    correction=0.0 if frame['geometry']['isLimitBreakBackup'] else float(state['limitBreakCorrectionValue']))
                raw = get_angle_to_target(target=_vector(frame['neck']['target'], 'recorded target position'),
                                         aim_position=frame['geometry']['aim']['position'],
                                         aim_rotation=frame['geometry']['aim']['rotation'],
                                         reference_position=frame['geometry']['neckRef']['position'],
                                         reference_rotation=frame['geometry']['neckRef']['rotation'],
                                         head_rotation=current_head)
                report['awayFrames'].append({'phase': phase, 'frameCount': frame['frameCount'],
                                             'recorded': recorded, 'raw': raw, 'limitBroken': broken,
                                             'limitAngles': [horizontal, vertical]})
                phase_report['awayFrames'] += 1
    return report


def main():
    import argparse
    import json
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('capture', type=Path, help='capture directory or look-trace.json')
    parser.add_argument('--settings', type=Path, required=True,
                        help='studio look settings json holding neck.neckTypeStates (limits)')
    args = parser.parse_args()
    path = args.capture if args.capture.suffix == '.json' else args.capture / 'look-trace.json'
    report = verify_trace(json.loads(path.read_text()), json.loads(args.settings.read_text()))
    print('| phase | TARGET frames | held | x ° (k-1 head) | y ° (k-1 head) | x ° (k head) | y ° (k head) '
          '| x ° (k head, changed) | y ° (k head, changed) | AWAY frames |')
    print('|---|---|---|---|---|---|---|---|---|---|')
    for phase in sorted(report['phases']):
        entry = report['phases'][phase]
        print('| {} | {} | {} | {:.6f} | {:.6f} | {:.6f} | {:.6f} | {:.6f} | {:.6f} | {} |'.format(
            phase, entry['targetFrames'], entry['heldFrames'],
            entry['previousMaxDegrees'][0], entry['previousMaxDegrees'][1],
            entry['sameFrameMaxDegrees'][0], entry['sameFrameMaxDegrees'][1],
            entry['movedMaxDegrees'][0], entry['movedMaxDegrees'][1],
            entry['awayFrames']))
    print(f'TARGET frames checked: {report["targetFrames"]}')
    for entry in report['awayFrames']:
        print(f'AWAY phase {entry["phase"]} frame {entry["frameCount"]}: recorded {entry["recorded"]} '
              f'raw {entry["raw"]} limitBroken={entry["limitBroken"]} limitAngles={entry["limitAngles"]}')


if __name__ == '__main__':
    main()
