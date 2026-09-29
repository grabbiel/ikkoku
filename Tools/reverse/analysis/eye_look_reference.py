#!/usr/bin/env python3
"""Pure Python reference of the original EyeLookCalc.EyeUpdateCalc.

Reconstruction of the recovered per-frame eye look solver: target resolution
(the nearDis push-out for non-TARGET types, the two limit checks that fall
over to FORWARD, the frontCorrect FORWARD target), the trfCenter
correct-frame eye target pair, and the per-eye threshold /
bendingMultiplier / maxAngleDifference chain with the L/R bending clamp
mirroring and the AWAY sorasi branch.  It runs on the end-of-frame world
geometry the ST-T07m probe records (look-trace.json `geometry.eyeCalc`
rootNode / trfCenter and `geometry.eyes` per-eye internals plus the solver's
own `eyes` fields).

Everything the recovered math consumes is parent space: `eye.parent.rotation`
is the recorded rootNode rotation (its `v2 = parent^-1 * dir` is the only
place the parent enters), refLook / refUp / origRotation / dirUp come from the
per-eye internals, and because the writeback is
`eye.rotation = q2 * eye.rotation` with
`q2 = parent * A * inverse(parent * B)` the predicted *local* rotation is
`A * inverse(B) * origRotation` — the parent cancels and only selects v2.
Unity semantics (Mathf.Lerp / InverseLerp clamping, Vector3.Slerp magnitude
behavior and zero-operand result, left-handed Quaternion.LookRotation,
Math.Sign, TransformPoint / InverseTransformPoint lossyScale) are explicit
here.  The vector helpers are the ST-T07n `neck_target_angle` ones.
"""
from __future__ import annotations

import math

from neck_target_angle import (FORWARD, RIGHT, UP, angle_around_axis,
                               angle_degrees, angle_axis, cross, dot, length,
                               multiply_quaternions, normalize, project,
                               rotate, sub)

IDENTITY = [0.0, 0.0, 0.0, 1.0]
LOOK_TYPES = ('NO_LOOK', 'TARGET', 'AWAY', 'FORWARD', 'CONTROL')


def _vector(value: list[float], what: str) -> list[float]:
    if len(value) != 3 or not all(math.isfinite(component) for component in value):
        raise ValueError(f'{what} is not a finite xyz vector: {value!r}')
    return [float(component) for component in value]


def _quaternion(value: list[float], what: str) -> list[float]:
    if len(value) != 4 or not all(math.isfinite(component) for component in value):
        raise ValueError(f'{what} is not a finite xyzw quaternion: {value!r}')
    return [float(component) for component in value]


def _finite(value, what: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f'{what} is not a finite number: {value!r}')
    return float(value)


def _sign(value: float) -> float:
    """C# Math.Sign: 0 for exactly 0, +-1 otherwise."""
    return 1.0 if value > 0.0 else (-1.0 if value < 0.0 else 0.0)


def _clamp(value: float, low: float, high: float) -> float:
    if low > high:
        raise ValueError(f'clamp range {low}..{high} is inverted')
    return min(max(value, low), high)


def add(a: list[float], b: list[float]) -> list[float]:
    a, b = _vector(a, 'add left'), _vector(b, 'add right')
    return [left + right for left, right in zip(a, b)]


def scale(a: list[float], factor: float) -> list[float]:
    a, factor = _vector(a, 'scale vector'), _finite(factor, 'scale factor')
    return [factor * component for component in a]


def normalize_or_zero(value: list[float]) -> list[float]:
    """Unity Vector3.normalized: the zero vector maps to zero, not an error."""
    size = length(value)
    if size <= 0.0:
        return [0.0, 0.0, 0.0]
    return [component / size for component in value]


def _normalize_strict(value: list[float], what: str) -> list[float]:
    unit = normalize_or_zero(value)
    if length(unit) <= 0.0:
        raise ValueError(f'{what} is zero-length: {value!r}')
    return unit


def lerp(a: float, b: float, t: float) -> float:
    """Mathf.Lerp: clamps t to [0, 1]."""
    return a + (b - a) * _clamp(_finite(t, 'lerp t'), 0.0, 1.0)


def inverse_lerp(a: float, b: float, value: float) -> float:
    """Mathf.InverseLerp: clamps to [0, 1], returns 1 when a == b."""
    a, b, value = _finite(a, 'inverse-lerp a'), _finite(b, 'inverse-lerp b'), _finite(value, 'inverse-lerp value')
    if a == b:
        return 1.0
    return _clamp((value - a) / (b - a), 0.0, 1.0)


def slerp_vector(a: list[float], b: list[float], t: float) -> list[float]:
    """Vector3.Slerp (two-vector overload): the normalized arc scaled by
    t*theta with the magnitude lerped; a zero operand collapses to
    (1-t)*a; an exact antiparallel pair rotates about a perpendicular basis
    axis the way Unity's implementation does."""
    a, b = _vector(a, 'slerp left'), _vector(b, 'slerp right')
    t = _clamp(_finite(t, 'slerp t'), 0.0, 1.0)
    magnitude, magnitude_b = length(a), length(b)
    if magnitude <= 0.0 or magnitude_b <= 0.0:
        return [(1.0 - t) * component for component in a]
    unit_a = [component / magnitude for component in a]
    unit_b = [component / magnitude_b for component in b]
    cosine = _clamp(dot(unit_a, unit_b), -1.0, 1.0)
    sine = math.sqrt(max(0.0, 1.0 - cosine * cosine))
    theta = math.acos(cosine)
    if sine < 1e-7:
        if cosine > 0.0:
            unit = normalize_or_zero([unit_a[i] + t * (unit_b[i] - unit_a[i]) for i in range(3)])
        else:
            axis = cross(RIGHT, unit_a)
            if length(axis) <= 1e-5:
                axis = cross(UP, unit_a)
            unit = rotate(angle_axis(math.degrees(theta) * t, normalize(axis)), unit_a)
            unit = normalize_or_zero(unit)
    else:
        scale_a, scale_b = math.sin((1.0 - t) * theta) / sine, math.sin(t * theta) / sine
        unit = normalize_or_zero([scale_a * unit_a[i] + scale_b * unit_b[i] for i in range(3)])
    magnitude_t = magnitude + t * (magnitude_b - magnitude)
    return [magnitude_t * component for component in unit]


def ortho_normalize(normal: list[float], tangent: list[float]) -> tuple[list[float], list[float]]:
    """Vector3.OrthoNormalize (two-vector form): the normal normalized, the
    tangent orthogonalized against it and normalized; a parallel tangent
    falls back to the least-aligned unit basis vector like Unity."""
    normal, tangent = _vector(normal, 'ortho-normalize normal'), _vector(tangent, 'ortho-normalize tangent')
    unit = _normalize_strict(normal, 'ortho-normalize normal')
    perpendicular = normalize_or_zero(sub(tangent, project(tangent, unit)))
    if length(perpendicular) <= 0.0:
        basis = min((RIGHT, UP, FORWARD), key=lambda axis: abs(dot(unit, axis)))
        perpendicular = _normalize_strict(sub(basis, scale(unit, dot(basis, unit))), 'ortho-normalize fallback')
    return unit, perpendicular


def inverse_quaternion(quaternion: list[float]) -> list[float]:
    q = _quaternion(quaternion, 'inverse quaternion')
    squared = sum(component * component for component in q)
    if squared <= 0.0:
        raise ValueError('cannot invert a zero quaternion')
    return [-q[0] / squared, -q[1] / squared, -q[2] / squared, q[3] / squared]


def look_rotation(forward: list[float], up: list[float]) -> list[float]:
    """Quaternion.LookRotation (Unity left-handed): +z maps to the normalized
    forward, +y to the up orthogonalized against it, +x = Cross(y, z)."""
    forward, up = _vector(forward, 'look-rotation forward'), _vector(up, 'look-rotation up')
    z = _normalize_strict(forward, 'look-rotation forward')
    y = _normalize_strict(sub(up, scale(z, dot(up, z))), 'look-rotation up')
    x = _normalize_strict(cross(y, z), 'look-rotation basis')
    y = cross(z, x)
    # Column-major rotation matrix (x, y, z are its axes), matrix element
    # m[row][col] = axis_col[row]; standard trace-based quaternion extraction.
    trace = x[0] + y[1] + z[2]
    if trace > 0.0:
        s = math.sqrt(trace + 1.0) * 2.0
        w, xq, yq, zq = 0.25 * s, (y[2] - z[1]) / s, (z[0] - x[2]) / s, (x[1] - y[0]) / s
    elif x[0] > y[1] and x[0] > z[2]:
        s = math.sqrt(1.0 + x[0] - y[1] - z[2]) * 2.0
        w, xq, yq, zq = (y[2] - z[1]) / s, 0.25 * s, (x[1] + y[0]) / s, (z[0] + x[2]) / s
    elif y[1] > z[2]:
        s = math.sqrt(1.0 + y[1] - x[0] - z[2]) * 2.0
        w, xq, yq, zq = (z[0] - x[2]) / s, (x[1] + y[0]) / s, 0.25 * s, (y[2] + z[1]) / s
    else:
        s = math.sqrt(1.0 + z[2] - x[0] - y[1]) * 2.0
        w, xq, yq, zq = (x[1] - y[0]) / s, (z[0] + x[2]) / s, (y[2] + z[1]) / s, 0.25 * s
    quaternion = [xq, yq, zq, w]
    size = math.sqrt(sum(component * component for component in quaternion))
    if size <= 0.0:
        raise ValueError('look-rotation produced a zero quaternion')
    return [component / size for component in quaternion]


def angle_between_quaternions(a: list[float], b: list[float]) -> float:
    """Unsigned rotation angle in degrees between two orientations."""
    def unit(quaternion: list[float]) -> list[float]:
        size = math.sqrt(sum(component * component for component in quaternion))
        return [component / size for component in quaternion]

    cosine = _clamp(abs(sum(x * y for x, y in zip(unit(_quaternion(a, 'quaternion angle left')),
                                                 unit(_quaternion(b, 'quaternion angle right'))))), -1.0, 1.0)
    return 2.0 * math.degrees(math.acos(cosine))


def _lossy_scale(node: dict) -> list[float]:
    scales = node['lossyScale']
    if len(scales) != 3:
        raise ValueError(f'the node needs a lossyScale triple: {node!r}')
    return [_finite(component, 'node lossyScale') for component in scales]


def world_to_local(point: list[float], node: dict) -> list[float]:
    """Transform.InverseTransformPoint: inverse-rotate the offset, then
    divide it by the node's recorded lossyScale."""
    offset = sub(_vector(point, 'world-to-local point'), _vector(node['position'], 'world-to-local origin'))
    offset = rotate(inverse_quaternion(_quaternion(node['rotation'], 'world-to-local rotation')), offset)
    return [component / scale_component
            for component, scale_component in zip(offset, _lossy_scale(node))]


def local_to_world(point: list[float], position: list[float], rotation: list[float],
                   lossy_scale: list[float]) -> list[float]:
    """Transform.TransformPoint: scale the local offset, rotate it, add the
    position."""
    point = _vector(point, 'local-to-world point')
    factors = [_finite(component, 'local-to-world scale') for component in lossy_scale]
    return add(rotate(_quaternion(rotation, 'local-to-world rotation'),
                      [p * s for p, s in zip(point, factors)]),
               _vector(position, 'local-to-world origin'))


def resolve_target(*, target: list[float], root: dict, state: dict, look_type: str) -> tuple[str, list[float]]:
    """The recovered target resolution.  Non-TARGET types push a closer than
    nearDis target out to nearDis along its direction (a target sitting on
    the root stays there, Unity's zero-normalized).  The horizontal check
    Angle((v.x, root.forward.y, v.z), forward) and the vertical check
    Angle((forward.x, v.y, v.z), forward) over hAngleLimit / vAngleLimit
    select FORWARD, whose target is then forntTagDis along frontCorrect's
    forward axis (frontCorrect: rootNode child, local position 0, local
    euler (5, 0, 0)).  Returns (effective type, target)."""
    root_position = _vector(root['position'], 'eye root position')
    root_rotation = _quaternion(root['rotation'], 'eye root rotation')
    resolved = _vector(target, 'eye target')
    near_dis = _finite(state['nearDis'], 'nearDis')
    if look_type != 'TARGET':
        offset = sub(resolved, root_position)
        if length(offset) < near_dis:
            resolved = add(root_position, scale(normalize_or_zero(offset), near_dis))
    offset = sub(resolved, root_position)
    forward = rotate(root_rotation, FORWARD)
    horizontal = angle_degrees([offset[0], forward[1], offset[2]], forward)
    vertical = angle_degrees([forward[0], offset[1], offset[2]], forward)
    effective = look_type
    if horizontal > _finite(state['hAngleLimit'], 'hAngleLimit') \
            or vertical > _finite(state['vAngleLimit'], 'vAngleLimit'):
        effective = 'FORWARD'
    if effective == 'FORWARD':
        front_rotation = multiply_quaternions(root_rotation, angle_axis(5.0, RIGHT))
        resolved = add(root_position,
                       scale(rotate(front_rotation, FORWARD), _finite(state['forntTagDis'], 'forntTagDis')))
    return effective, resolved


def correct_eye_targets(*, target: list[float], trf_center: dict, center_eye_length: float) -> tuple[list[float], list[float]]:
    """The trfCenter correct frame: the target with its center-space z
    clamped to >= 0.5, the front node at that point with rotation
    LookRotation(n3, up) for n = normalize(p - center), n2 = normalize
    (Cross(up, n)), n3 = normalize(Cross(n2, up)), and its
    +-centerEyeLength eye target pair as unscaled localPosition offsets."""
    center_eye_length = _finite(center_eye_length, 'centerEyeLength')
    position = _vector(trf_center['position'], 'correct center position')
    local = world_to_local(target, trf_center)
    local[2] = max(local[2], 0.5)
    point = local_to_world(local, position, _quaternion(trf_center['rotation'], 'correct rotation'),
                           _lossy_scale(trf_center))
    normal = normalize_or_zero(sub(point, position))
    side = normalize_or_zero(cross(UP, normal))
    if length(side) <= 0.0:
        raise ValueError('the correct target is parallel to the up axis')
    plane = normalize_or_zero(cross(side, UP))
    frame_rotation = look_rotation(plane, UP)
    # Unity TransformPoint scales the local offset by the node's own
    # lossyScale; the front node lives under trfCenter, so the recorded
    # 0.868 eye scale shrinks the +-centerEyeLength offsets to +-0.0434.
    frame_scale = _lossy_scale(trf_center)
    left = local_to_world([-center_eye_length, 0.0, 0.0], point, frame_rotation, frame_scale)
    right = local_to_world([center_eye_length, 0.0, 0.0], point, frame_rotation, frame_scale)
    return left, right


def _bend(angle: float, threshold: float, multiplier: float, maximum_difference: float) -> float:
    """One axis of the recovered chain: the dead-band excess past the
    threshold, then max(|excess| * |multiplier|, |angle| -
    maxAngleDifference), carrying sign(angle) * sign(multiplier)."""
    excess = max(abs(angle) - threshold, 0.0)
    return max(excess * abs(multiplier), abs(angle) - maximum_difference) * _sign(angle) * _sign(multiplier)


def eye_bending(*, horizontal: float, vertical: float, state: dict, left_eye: bool) -> tuple[float, float]:
    """The recovered per-eye chain: threshold dead-band and bending /
    maxAngleDifference on both angles, then the bending clamps — the L eye
    uses (minBending, maxBending) directly, the R eye mirrors the horizontal
    range to (-maxBending, -minBending); both use (upBending, downBending)
    vertically."""
    horizontal = _bend(horizontal, _finite(state['thresholdAngleDifference'], 'thresholdAngleDifference'),
                       _finite(state['bendingMultiplier'], 'bendingMultiplier'),
                       _finite(state['maxAngleDifference'], 'maxAngleDifference'))
    vertical = _bend(vertical, _finite(state['thresholdAngleDifference'], 'thresholdAngleDifference'),
                     _finite(state['bendingMultiplier'], 'bendingMultiplier'),
                     _finite(state['maxAngleDifference'], 'maxAngleDifference'))
    min_bending = _finite(state['minBendingAngle'], 'minBendingAngle')
    max_bending = _finite(state['maxBendingAngle'], 'maxBendingAngle')
    if left_eye:
        horizontal = _clamp(horizontal, min_bending, max_bending)
    else:
        horizontal = _clamp(horizontal, -max_bending, -min_bending)
    vertical = _clamp(vertical, _finite(state['upBendingAngle'], 'upBendingAngle'),
                      _finite(state['downBendingAngle'], 'downBendingAngle'))
    return horizontal, vertical


def sorasi_horizontal(*, previous_angle: float, measured: float, state: dict,
                      sorasi_rate: float, num5: float) -> tuple[float, float]:
    """The recovered AWAY sorasi branch.  Returns (f, num5).  While num5 is
    the initial -1 the measured angle's -1..1 sorasi coordinate a7 is
    compared with the previous angleH's coordinate a6: within sorasiRate of
    each other f is mapped back from a coordinate pushed sorasiRate off a7
    (away from it by the sign of their difference, +sorasiRate when equal),
    farther apart f keeps the previous angleH; either way num5 arms to a6's
    clamped -1..1 coordinate.  Once armed num5 alone determines f through
    the (-maxBending, -minBending) remap."""
    max_bending = _finite(state['maxBendingAngle'], 'maxBendingAngle')
    min_bending = _finite(state['minBendingAngle'], 'minBendingAngle')
    sorasi_rate = _finite(sorasi_rate, 'sorasiRate')
    previous_angle = _finite(previous_angle, 'sorasi angleH')
    measured, num5 = _finite(measured, 'sorasi f'), _finite(num5, 'sorasi num5')
    if num5 != -1.0:
        return lerp(-max_bending, -min_bending, num5), num5
    a6 = lerp(-1.0, 1.0, inverse_lerp(-max_bending, -min_bending, previous_angle))
    a7 = lerp(-1.0, 1.0, inverse_lerp(-max_bending, -min_bending, measured))
    difference = a6 - a7
    if abs(difference) < sorasi_rate:
        if difference < 0.0:
            a6 = a7 + sorasi_rate if a7 < -sorasi_rate else a7 - sorasi_rate
        elif difference > 0.0:
            a6 = a7 - sorasi_rate if a7 > sorasi_rate else a7 + sorasi_rate
        else:
            a6 = a7 + sorasi_rate
        num5 = inverse_lerp(-1.0, 1.0, a6)
        return lerp(-max_bending, -min_bending, num5), num5
    num5 = inverse_lerp(-1.0, 1.0, a6)
    return previous_angle, num5


def state_values(state: dict) -> list[dict]:
    """Validate the per-eye state the solver carries between frames."""
    eyes = state.get('eyes') if isinstance(state, dict) else None
    if not isinstance(eyes, list) or len(eyes) != 2:
        raise ValueError('the solver state needs a two-eye eyes list')
    return [{'angleH': _finite(entry.get('angleH'), f'eye {index} angleH'),
             'angleV': _finite(entry.get('angleV'), f'eye {index} angleV'),
             'dirUp': _vector(entry.get('dirUp'), f'eye {index} dirUp')}
            for index, entry in enumerate(eyes)]


def eye_update(*, state: dict, geometry: dict, target: list[float], dt: float,
               st: dict, settings: dict) -> list[dict]:
    """One frame of the recovered EyeUpdateCalc.

    `state` carries the previous frame's per-eye values,
    {'eyes': [{'angleH', 'angleV', 'dirUp'}, ...]}; `geometry` is the frame's
    recorded geometry, {'eyeCalc': {rootNode, trfCenter}, 'eyes': [{eye,
    target, origRotation, referenceLookDir, referenceUpDir, dirUp}, ...]};
    `target` the probe target position; `dt` the frame's deltaTime; `st` the
    frame's eyeTypeStates entry (lookType a name or a {name, value} record)
    and `settings` the exported eyes block (correct, centerEyeLength,
    sorasiRate).  Returns the new per-eye state, each entry extended with the
    predicted `localRotation`, world `rotation` and the frame's final sorasi
    `num5`.  `num5` is frame-local like the transcription (reset to -1 each
    frame; the AWAY branch arms it on the L eye and the R eye reads it).
    NO_LOOK would write the fixAngle the trace does not record and is a
    diagnostic error.
    """
    dt = _finite(dt, 'eye deltaTime')
    if dt == 0.0:
        return [dict(entry, localRotation=None, rotation=None, num5=None) for entry in state_values(state)]
    look_type = st['lookType']
    if isinstance(look_type, dict):
        look_type = look_type['name']
    if look_type not in LOOK_TYPES:
        raise ValueError(f'unknown eye lookType {look_type!r}')
    if look_type == 'NO_LOOK':
        raise ValueError('NO_LOOK writes the fixAngle the look trace does not record')
    eye_geometry = geometry['eyes']
    if len(eye_geometry) != 2:
        raise ValueError('the eye solver needs exactly two eyes')
    root = geometry['eyeCalc']['rootNode']
    previous = state_values(state)
    effective, resolved = resolve_target(target=target, root=root, state=st, look_type=look_type)
    if _finite(settings.get('correct', 0), 'eye correct') != 0.0 and effective in ('TARGET', 'FORWARD'):
        targets = list(correct_eye_targets(target=resolved, trf_center=geometry['eyeCalc']['trfCenter'],
                                           center_eye_length=settings['centerEyeLength']))
    else:
        targets = [resolved, resolved]
    parent = _quaternion(root['rotation'], 'eye parent rotation')
    parent_inverse = inverse_quaternion(parent)
    num5 = -1.0
    results: list[dict] = []
    for index, eye in enumerate(eye_geometry):
        look_dir = _vector(eye['referenceLookDir'], 'eye referenceLookDir')
        up_dir = _vector(eye['referenceUpDir'], 'eye referenceUpDir')
        orig = _quaternion(eye['origRotation'], 'eye origRotation')
        eye_position = _vector(eye['target']['position'], 'eye world position')
        aim = targets[index] if effective in ('TARGET', 'FORWARD') else resolved
        # Unity normalize of a zero difference stays zero and the angle
        # helpers map a zero operand to 0, exactly what the original does
        # when the correct frame places an eye target on the eye pivot.
        local_direction = rotate(parent_inverse, normalize_or_zero(sub(aim, eye_position)))
        horizontal = angle_around_axis(look_dir, local_direction, up_dir)
        # The vertical measurement is the elevation of the direction out of
        # the plane spanned by refLook and refUp, measured around the axis
        # perpendicular to the direction's own horizontal part (Cross(refUp,
        # dir)), so it reads the sign of the direction's refUp component
        # rather than its azimuth around refLook.
        vertical_measurement_axis = cross(up_dir, local_direction)
        vertical_axis = cross(up_dir, look_dir)
        horizontal, vertical = eye_bending(
            horizontal=horizontal,
            vertical=angle_around_axis(sub(local_direction, project(local_direction, up_dir)),
                                       local_direction, vertical_measurement_axis),
            state=st, left_eye=(index == 0))
        previous_angle = previous[index]['angleH']
        if effective == 'AWAY':
            horizontal, num5 = sorasi_horizontal(previous_angle=previous_angle, measured=horizontal,
                                                 state=st, sorasi_rate=settings['sorasiRate'], num5=num5)
            vertical = -vertical
        blend = dt * _finite(st['leapSpeed'], 'leapSpeed')
        angle_h = lerp(previous_angle, horizontal, blend)
        angle_v = lerp(previous[index]['angleV'], vertical, blend)
        look = rotate(multiply_quaternions(angle_axis(angle_h, up_dir), angle_axis(angle_v, vertical_axis)),
                      look_dir)
        _, tangent = ortho_normalize(look, up_dir)
        dir_up = slerp_vector(previous[index]['dirUp'], tangent, dt * 5.0)
        normal, dir_up = ortho_normalize(look, dir_up)
        local_rotation = multiply_quaternions(
            look_rotation(normal, dir_up),
            multiply_quaternions(inverse_quaternion(look_rotation(look_dir, up_dir)), orig))
        results.append({'angleH': angle_h, 'angleV': angle_v, 'dirUp': dir_up, 'num5': num5,
                        'localRotation': local_rotation,
                        'rotation': multiply_quaternions(parent, local_rotation)})
    return results
