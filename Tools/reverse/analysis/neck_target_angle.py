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
it).  AWAY frames get the raw formula output through the recovered AWAY
adjustment, which collapses the vertical angle onto one of the aParam
bending-limit sums and negates the horizontal angle using the previous
recorded frame's bone angleH sum; across the 90 AWAY frames of the capture
the adjusted prediction matches the recorded nowAngle within 0.0037 deg on x
and exactly on y.  Vectors are plain x,y,z lists and quaternions Unity
x,y,z,w lists; every vector read is re-derived from the recorded rotation
instead of trusting Unity-axis fields.
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


def away_adjust(*, now_angle: list[float], bone_angle_h: list[float],
                a_param: list[dict], limit_away: float) -> list[float]:
    """The recovered AWAY adjustment applied to the raw (unlimited) nowAngle.

    Only a frame whose limit check is intact reaches it; `bone_angle_h` are
    the bones' angleH before this frame's smoothing (the previous recorded
    frame's end-of-frame values).  The vertical angle collapses onto one of
    the two sums of the aParam bending limits — the maximum-bending sum when
    the target is past it or the raw angle already bends the other way, the
    minimum-bending sum otherwise — and the horizontal angle is negated.
    """
    if len(now_angle) != 2 or not all(math.isfinite(value) for value in now_angle):
        raise ValueError(f'away-adjust nowAngle is not a finite xy pair: {now_angle!r}')
    if not bone_angle_h or not all(math.isfinite(value) for value in bone_angle_h):
        raise ValueError('away-adjust needs finite per-bone angleH values')
    if not a_param:
        raise ValueError('away-adjust needs the aParam bending limits')
    for entry in a_param:
        for key in ('minBendingAngle', 'maxBendingAngle'):
            if not math.isfinite(float(entry[key])):
                raise ValueError(f'away-adjust aParam {key} is not finite: {entry!r}')
    if not math.isfinite(float(limit_away)):
        raise ValueError('away-adjust limitAway is not finite')
    x, y = [float(value) for value in now_angle]
    limit_away = float(limit_away)
    horizontal_bones = sum(float(value) for value in bone_angle_h)
    maximum_bending = sum(float(entry['maxBendingAngle']) for entry in a_param)
    minimum_bending = sum(float(entry['minBendingAngle']) for entry in a_param)
    if y <= horizontal_bones:
        if y <= maximum_bending - limit_away or y < 0.0:
            y = maximum_bending
        else:
            y = minimum_bending
    else:
        if y >= minimum_bending + limit_away or y > 0.0:
            y = minimum_bending
        else:
            y = maximum_bending
    return [-x, y]


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
    frames get the raw (unlimited) formula output, the AWAY adjustment
    applied to it under the previous recorded frame's bone angleH sum, and
    the adjusted-vs-recorded maximum per phase.
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
    global_index = {id(frame): index for index, frame in enumerate(frames)}
    report: dict = {'phases': {}, 'targetFrames': 0, 'awayFrames': []}
    for phase in sorted(phases):
        phase_report = {'targetFrames': 0, 'previousMaxDegrees': [0.0, 0.0], 'sameFrameMaxDegrees': [0.0, 0.0],
                        'movedMaxDegrees': [0.0, 0.0], 'heldFrames': 0, 'awayFrames': 0,
                        'awayMaxDegrees': [0.0, 0.0]}
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
                # The adjustment reads the bones' angleH before this frame's
                # smoothing, i.e. the previous recorded frame's end-of-frame
                # values; the AWAY phase's first frame inherits them from the
                # frame before the type change.
                previous = frames[global_index[id(frame)] - 1] if global_index[id(frame)] > 0 else None
                if previous is None:
                    raise ValueError(f'AWAY frame {frame["frameCount"]} has no previous frame to read angleH from')
                if broken:
                    adjusted = [0.0, 0.0]
                else:
                    adjusted = away_adjust(now_angle=raw,
                                           bone_angle_h=[float(bone['angleH']) for bone in previous['neck']['bones']],
                                           a_param=state['aParam'], limit_away=float(state['limitAway']))
                maximum = phase_report['awayMaxDegrees']
                phase_report['awayMaxDegrees'] = [max(maximum[0], abs(adjusted[0] - float(recorded[0]))),
                                                  max(maximum[1], abs(adjusted[1] - float(recorded[1])))]
                report['awayFrames'].append({'phase': phase, 'frameCount': frame['frameCount'],
                                             'recorded': recorded, 'raw': raw, 'adjusted': adjusted,
                                             'limitBroken': broken, 'limitAngles': [horizontal, vertical]})
                phase_report['awayFrames'] += 1
    return report


def write_fixture(path, seed: int = 20260928) -> int:
    """Write seeded SYNTHETIC target-angle cases (with Python outputs) to `path`.

    The geometry is random but fully determined by `seed`: NeckRef and aim
    transforms, a head yaw, and targets ahead / to the side / behind, spread
    over TARGET and AWAY look types, over both AWAY branches (the previous
    bone angleH sum picked from the raw y so each case exercises its branch),
    and over limit breaks with and without isLimitBreakBackup (a backup frame
    reads correction 0, so a target just past the limit still breaks).  The
    outputs are the Python formulas themselves, not original-game data: the
    Swift port is expected to reproduce them to 1e-6 deg.  Returns the case
    count.
    """
    import json
    import random

    rng = random.Random(seed)

    def yaw_radians(degrees: float) -> list[float]:
        half = math.radians(degrees) / 2.0
        return [0.0, math.sin(half), 0.0, math.cos(half)]

    def unit_quaternion() -> list[float]:
        while True:
            components = [rng.uniform(-1.0, 1.0) for _ in range(4)]
            size = math.sqrt(sum(component * component for component in components))
            if size > 0.5:
                return [component / size for component in components]

    targets = ([0.0, 12.0], [35.0, 0.0], [-35.0, 0.0], [85.0, 0.0], [95.0, -8.0], [150.0, 6.0], [178.0, 0.0])
    cases: list[dict] = []
    for transform_index in range(4):
        reference = {'position': [rng.uniform(-0.6, 0.6), rng.uniform(1.2, 1.6), rng.uniform(-0.3, 0.3)],
                     'rotation': unit_quaternion()}
        aim = {'position': [reference['position'][0] + rng.uniform(-0.1, 0.1),
                            reference['position'][1] + rng.uniform(-0.15, 0.05),
                            reference['position'][2] + rng.uniform(-0.1, 0.1)],
               'rotation': multiply_quaternions(reference['rotation'], yaw_radians(rng.uniform(-30.0, 30.0)))}
        head_rotation = multiply_quaternions(yaw_radians(rng.uniform(-60.0, 60.0)), unit_quaternion())
        for target_index, (azimuth, elevation) in enumerate(targets):
            look_type = 'TARGET' if (transform_index + target_index) % 3 == 0 else 'AWAY'
            # A backup frame has no state and reads correction 0, so a target
            # at the 85 deg azimuth against the 80 deg limit still breaks.
            backup = transform_index % 2 == 1 and target_index % 3 == 1
            limits = ({'hAngleLimit': 0.0, 'vAngleLimit': 0.0, 'correction': 0.0, 'isLimitBreakBackup': True}
                      if backup else
                      {'hAngleLimit': 90.0, 'vAngleLimit': 90.0, 'correction': 10.0, 'isLimitBreakBackup': False})
            radius = rng.uniform(1.5, 3.0)
            direction = rotate(aim['rotation'],
                               rotate(yaw_radians(azimuth), rotate(angle_axis(elevation, RIGHT), FORWARD)))
            target = [aim['position'][0] + radius * direction[0],
                      aim['position'][1] + radius * direction[1],
                      aim['position'][2] + radius * direction[2]]
            broken, horizontal, vertical = limit_check(
                target=target, reference_position=reference['position'], reference_rotation=reference['rotation'],
                horizontal_limit=limits['hAngleLimit'], vertical_limit=limits['vAngleLimit'],
                correction=limits['correction'])
            raw = get_angle_to_target(target=target, aim_position=aim['position'], aim_rotation=aim['rotation'],
                                      reference_position=reference['position'], reference_rotation=reference['rotation'],
                                      head_rotation=head_rotation)
            case: dict = {'lookType': look_type, 'target': target, 'aim': aim, 'neckRef': reference,
                          'headRotation': head_rotation, 'limits': limits,
                          'limit': {'broken': broken, 'horizontal': horizontal, 'vertical': vertical},
                          'raw': raw}
            if look_type == 'AWAY':
                a_param = [{'minBendingAngle': -rng.choice([20.0, 25.0, 30.0, 40.0]),
                            'maxBendingAngle': rng.choice([20.0, 25.0, 30.0, 40.0])},
                           {'minBendingAngle': -rng.choice([15.0, 20.0]),
                            'maxBendingAngle': rng.choice([15.0, 20.0])}]
                limit_away = rng.choice([5.0, 10.0, 15.0])
                maximum_bending = sum(entry['maxBendingAngle'] for entry in a_param)
                if broken:
                    bone_angle_h = [rng.uniform(-30.0, 30.0), rng.uniform(-30.0, 30.0)]
                elif target_index % 2 == 0:  # raw y above the bone sum: the y > num4 branch
                    bone_angle_h = [raw[1] / 2.0 - rng.uniform(2.0, 6.0), rng.uniform(-2.0, 2.0)]
                elif raw[1] <= maximum_bending - limit_away:  # y <= num4 inside the band: max-bending
                    bone_angle_h = [raw[1] + rng.uniform(3.0, 8.0), rng.uniform(0.5, 5.0)]
                else:  # y <= num4 past the band edge (maxSum - limitAway)
                    bone_angle_h = [raw[1] + rng.uniform(3.0, 8.0), rng.uniform(-2.0, 2.0)]
                case['away'] = {'boneAngleH': bone_angle_h, 'aParam': a_param, 'limitAway': limit_away}
                case['adjusted'] = [0.0, 0.0] if broken else away_adjust(
                    now_angle=raw, bone_angle_h=bone_angle_h, a_param=a_param, limit_away=limit_away)
            else:
                case['adjusted'] = [0.0, 0.0] if broken else raw
            case['id'] = f'{transform_index}-{target_index}-{look_type.lower()}'
            cases.append(case)
    document = {'kind': 'neck-target-angle', 'schemaVersion': 1,
                'source': 'SYNTHETIC seeded geometry from Tools/reverse/analysis/neck_target_angle.py, '
                          'not original-game data',
                'cases': cases}
    path = path if path.suffix == '.json' else path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=1) + '\n')
    return len(cases)


def main():
    import argparse
    import json
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('capture', type=Path, nargs='?',
                        help='capture directory or look-trace.json')
    parser.add_argument('--settings', type=Path,
                        help='studio look settings json holding neck.neckTypeStates (limits)')
    parser.add_argument('--fixture', type=Path, metavar='PATH',
                        help='write SYNTHETIC seeded fixture cases (with Python outputs) to PATH and exit')
    args = parser.parse_args()
    if args.fixture is not None:
        print(f'Wrote {write_fixture(args.fixture)} fixture cases to {args.fixture}')
        return
    if args.capture is None or args.settings is None:
        parser.error('a capture and --settings are required unless --fixture is given')
    path = args.capture if args.capture.suffix == '.json' else args.capture / 'look-trace.json'
    report = verify_trace(json.loads(path.read_text()), json.loads(args.settings.read_text()))
    print('| phase | TARGET frames | held | x ° (k-1 head) | y ° (k-1 head) | x ° (k head) | y ° (k head) '
          '| x ° (k head, changed) | y ° (k head, changed) | AWAY frames | x ° (AWAY adjusted) | y ° (AWAY adjusted) |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|')
    for phase in sorted(report['phases']):
        entry = report['phases'][phase]
        print('| {} | {} | {} | {:.6f} | {:.6f} | {:.6f} | {:.6f} | {:.6f} | {:.6f} | {} | {:.6f} | {:.6f} |'.format(
            phase, entry['targetFrames'], entry['heldFrames'],
            entry['previousMaxDegrees'][0], entry['previousMaxDegrees'][1],
            entry['sameFrameMaxDegrees'][0], entry['sameFrameMaxDegrees'][1],
            entry['movedMaxDegrees'][0], entry['movedMaxDegrees'][1],
            entry['awayFrames'], entry['awayMaxDegrees'][0], entry['awayMaxDegrees'][1]))
    print(f'TARGET frames checked: {report["targetFrames"]}')
    for entry in report['awayFrames']:
        print(f'AWAY phase {entry["phase"]} frame {entry["frameCount"]}: recorded {entry["recorded"]} '
              f'raw {entry["raw"]} adjusted {entry["adjusted"]} '
              f'limitBroken={entry["limitBroken"]} limitAngles={entry["limitAngles"]}')


if __name__ == '__main__':
    main()
