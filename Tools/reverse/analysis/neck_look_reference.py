#!/usr/bin/env python3
"""Pure reference model for the original NeckLookCalcVer2 look modes.

Covers the FORWARD / FIX / ANIMATION transitions and the TARGET / AWAY
smoothing given the frame's solver angle: the geometric GetAngleToTarget
itself, AWAY's nowAngle adjustment and ANIMATION's MaxRotateToAngle clamp
stay out of scope (TARGET / AWAY take nowAngle as an input here).  Every
LateUpdate runs
`UpdateCall(ptnNo)` and then `NeckUpdateCalc`; this module reproduces the
state they keep (lookType, changeTypeTimer, angleH/angleV, fixAngle and
fixAngleBackup per bone) and the local rotations NeckUpdateCalc writes back.  Quaternions are
Unity x,y,z,w and the animated input is the pose the Animator (and Studio FK)
left on the bone for that frame, which is what the capture's localRotation
holds only after the override.  The curve follows Unity's AnimationCurve:
cubic Hermite on the normalized key segment with tangents outSlope*dt and
inSlope*dt, and pre/post infinity 2 clamps to the end key values.
"""
from __future__ import annotations

import math

IDENTITY = [0.0, 0.0, 0.0, 1.0]

# The captured studio settings: changeTypeLeapTime 1.0 and the serialized
# changeTypeLerpCurve (both keys, slopes included).
DEFAULT_CHANGE_TYPE_LEAP_TIME = 1.0
DEFAULT_CHANGE_TYPE_LERP_CURVE = {
    "keys": [
        {"time": 0.0, "value": 0.002166748046875,
         "inSlope": 2.2096142768859863, "outSlope": 2.2096142768859863},
        {"time": 1.0, "value": 1.0, "inSlope": 0.0, "outSlope": 0.0},
    ],
    "preInfinity": 2,
    "postInfinity": 2,
}
# The recovered NeckLookCalcVer2 settings keep calcLerp at 1.0, which makes
# Slerp(localRotation, fixAngle, calcLerp) return fixAngle exactly.
DEFAULT_CALC_LERP = 1.0


def _unit(quaternion: list[float]) -> list[float]:
    """Normalize a Unity x,y,z,w quaternion, rejecting degenerate input."""
    if len(quaternion) != 4 or not all(math.isfinite(component) for component in quaternion):
        raise ValueError(f'not a finite xyzw quaternion: {quaternion!r}')
    length = math.sqrt(sum(component * component for component in quaternion))
    if length <= 0.0:
        raise ValueError('cannot normalize a zero-length quaternion')
    return [component / length for component in quaternion]


def clamp(value: float, lower: float, upper: float) -> float:
    """Clamp to a closed range, Unity Mathf.Clamp semantics."""
    return min(max(value, lower), upper)


def slerp(a: list[float], b: list[float], t: float) -> list[float]:
    """Spherical linear interpolation between two rotations.

    Unity Quaternion.Slerp semantics: both inputs are normalized, the
    shortest arc is taken (a negative dot negates one operand, so q and -q
    interpolate the same way) and t is clamped to [0, 1].  When the arc is
    too small for sin(theta) to be numerically meaningful Unity falls back
    to the componentwise path, which this mirrors.
    """
    if not math.isfinite(t):
        raise ValueError('slerp parameter must be finite')
    a, b = _unit(a), _unit(b)
    t = min(max(t, 0.0), 1.0)
    dot = sum(x * y for x, y in zip(a, b))
    if dot < 0.0:
        dot, b = -dot, [-component for component in b]
    if dot > 1.0 - 1e-8:  # indistinguishable rotations: linear then normalize
        result = [(1.0 - t) * x + t * y for x, y in zip(a, b)]
        return _unit(result)
    dot = min(dot, 1.0)
    theta_0 = math.acos(dot)
    sin_theta_0 = math.sin(theta_0)
    theta = theta_0 * t
    sin_theta = math.sin(theta)
    s0 = math.cos(theta) - dot * sin_theta / sin_theta_0
    s1 = sin_theta / sin_theta_0
    return _unit([s0 * x + s1 * y for x, y in zip(a, b)])


def evaluate_curve(keys: list[dict], t: float) -> float:
    """Unity AnimationCurve.Evaluate on a clamp-to-ends curve.

    Between two adjacent keys the value is the cubic Hermite of the
    normalized segment with tangent outSlope*dt for the left key and
    inSlope*dt for the right one (dt the key interval).  Outside the key
    range a pre/post infinity of 2 (the serialized "Clamp" constant mode)
    returns the end key's value.
    """
    if not keys:
        raise ValueError('curve evaluation needs at least one key')
    keys = sorted(keys, key=lambda key: key['time'])
    if not math.isfinite(t):
        raise ValueError('curve evaluation time must be finite')
    if len(keys) == 1 or t <= keys[0]['time']:
        return keys[0]['value']
    if t >= keys[-1]['time']:
        return keys[-1]['value']
    for left, right in zip(keys, keys[1:]):
        if left['time'] <= t <= right['time']:
            dt = right['time'] - left['time']
            if dt <= 0.0:
                return right['value']
            u = (t - left['time']) / dt
            uu, uuu = u * u, u * u * u
            h00 = 2.0 * uuu - 3.0 * uu + 1.0
            h10 = uuu - 2.0 * uu + u
            h01 = -2.0 * uuu + 3.0 * uu
            h11 = uuu - uu
            return (h00 * left['value'] + h10 * left['outSlope'] * dt
                    + h01 * right['value'] + h11 * right['inSlope'] * dt)
    raise ValueError(f'time {t} fell outside the sorted key range')


def initial_state(look_type: str, fix_angle: list[list[float]],
                  fix_angle_backup: list[list[float]] | None = None,
                  timer: float = 0.0,
                  angles: list[list[float]] | None = None) -> dict:
    """Build a NeckLookCalcVer2 state, the two bones in cf_j_neck order.

    `angles` seeds the smoothed angleH/angleV a TARGET/AWAY calculator
    carries (one [angleH, angleV] pair per bone, degrees); TARGET/AWAY
    frames otherwise start from zero.
    """
    if len(fix_angle) != 2:
        raise ValueError('the neck calculator keeps exactly two bones')
    angles = angles if angles is not None else [[0.0, 0.0], [0.0, 0.0]]
    if len(angles) != 2:
        raise ValueError('the neck calculator keeps exactly two bones')
    return {
        'lookType': look_type,
        'timer': timer,
        'fixAngle': [list(quaternion) for quaternion in fix_angle],
        'fixAngleBackup': ([list(quaternion) for quaternion in fix_angle_backup]
                           if fix_angle_backup is not None
                           else [list(quaternion) for quaternion in fix_angle]),
        'angleH': [angles[0][0], angles[1][0]],
        'angleV': [angles[0][1], angles[1][1]],
    }


def neck_step(state: dict, look_type: str, dt: float,
              animated_local_rotations: list[list[float]],
              curve: dict | None = None, leap_time: float = DEFAULT_CHANGE_TYPE_LEAP_TIME,
              calc_lerp: float = DEFAULT_CALC_LERP) -> tuple[dict, list[list[float]]]:
    """Advance one LateUpdate, returning (new state, local rotations).

    Reproduces `UpdateCall(ptnNo)` followed by `NeckUpdateCalc`: a lookType
    change resets the transition timer and backs up fixAngle (FORWARD also
    clears the calculator angles, which only the TARGET/AWAY solver reads,
    so it is not modelled).  NeckUpdateCalc is skipped entirely when
    deltaTime is 0, leaving the animated pose and the timer untouched.  In
    ANIMATION the animated pose is assumed already inside MaxRotateToAngle,
    whose geometric clamp is out of scope here.  TARGET and AWAY are stepped
    by `neck_target_step`, which additionally takes the solver angle.
    """
    if look_type in ('TARGET', 'AWAY'):
        raise ValueError(f'{look_type} uses the geometric solver and is not simulated here; '
                         'it steps through neck_target_step, which takes the solver angle')
    if leap_time <= 0.0:
        raise ValueError('changeTypeLeapTime must be positive')
    if len(animated_local_rotations) != 2:
        raise ValueError('the neck calculator reads exactly two bones')
    curve = curve or DEFAULT_CHANGE_TYPE_LERP_CURVE
    state = {**state,
             'fixAngle': [list(quaternion) for quaternion in state['fixAngle']],
             'fixAngleBackup': [list(quaternion) for quaternion in state['fixAngleBackup']]}
    if state['lookType'] != look_type:  # UpdateCall type-change branch
        state['lookType'] = look_type
        state['timer'] = 0.0
        state['fixAngleBackup'] = [list(quaternion) for quaternion in state['fixAngle']]
    if dt == 0.0:  # NeckUpdateCalc returns before touching anything
        return state, [list(quaternion) for quaternion in animated_local_rotations]
    state['timer'] = min(max(state['timer'] + dt, 0.0), leap_time)
    num = evaluate_curve(curve['keys'], state['timer'] / leap_time)
    rotations = []
    for index, animated in enumerate(animated_local_rotations):
        backup = state['fixAngleBackup'][index]
        if look_type == 'FORWARD':
            state['fixAngle'][index] = list(IDENTITY)
            blended = slerp(animated, state['fixAngle'][index], calc_lerp)
            rotations.append(slerp(backup, blended, num))
        elif look_type == 'FIX':
            blended = slerp(animated, state['fixAngle'][index], calc_lerp)
            rotations.append(slerp(backup, blended, num))
        elif look_type == 'ANIMATION':
            state['fixAngle'][index] = _unit(animated)
            rotations.append(slerp(backup, state['fixAngle'][index], num))
        else:
            raise ValueError(f'{look_type} uses the geometric solver and is not simulated')
    return state, rotations


def _yx_basis(angle_h: float, angle_v: float) -> list[float]:
    """Quaternion.AngleAxis(angleH, Y) * Quaternion.AngleAxis(angleV, X).

    The parent-frame rotation CalcNeckBone's `ref.up`/`ref.right` formula
    reduces to in the captured rest setup (up = +Y, right = +X): yaw about Y
    composed with pitch about X, written out so no basis vectors are needed.
    """
    half_h, half_v = math.radians(angle_h) / 2.0, math.radians(angle_v) / 2.0
    sine_h, cos_h = math.sin(half_h), math.cos(half_h)
    sine_v, cos_v = math.sin(half_v), math.cos(half_v)
    return [cos_h * sine_v, sine_h * cos_v, -sine_h * sine_v, cos_h * cos_v]


def neck_target_step(state: dict, now_angle: list[float], dt: float,
                     a_param: list[dict], leap_speed: float = 2.0,
                     curve: dict | None = None,
                     leap_time: float = DEFAULT_CHANGE_TYPE_LEAP_TIME,
                     look_type: str | None = None) -> tuple[dict, list[list[float]]]:
    """Advance one TARGET / AWAY LateUpdate, returning (new state, rotations).

    The frame's solver angle `now_angle` is the serialized nowAngle pair
    [x, y] in degrees: y (index 1) feeds the horizontal bending share
    (min/maxBendingAngle) and x (index 0) the vertical share
    (up/downBendingAngle).  Producing that angle -- GetAngleToTarget's
    geometry and AWAY's own horizontal adjustment -- stays out of scope,
    and this step consumes it as given.  Reproduces `UpdateCall(look_type)` (a type change
    resets the transition timer and backs up fixAngle, exactly as in
    `neck_step`; pass `look_type` on the frame the mode switches) followed by
    the TARGET / AWAY branch of `NeckUpdateCalc`.  deltaTime 0 leaves the
    state untouched and writes nothing back (the rotations returned are
    None entries telling the caller the override did not run); the original
    simply keeps whatever the Animator left on the bones.  The distribution
    runs over the bones LAST to FIRST (head, then neck): each bone clamps the
    remaining angle into its own aParam limits (horizontal into
    min/maxBendingAngle, vertical into up/downBendingAngle) and subtracts
    what it took, so a demand beyond the head's limits spills over to the
    neck.  The leftover after both bones is observed to stay 0 in the
    capture.  Each bone then smooths its carried angleH/angleV toward the
    clamped share with Unity Lerp's clamped factor deltaTime * leapSpeed,
    rebuilds fixAngle as `angleH` about Y composed with `angleV` about X and
    leaves localRotation = Slerp(fixAngleBackup, fixAngle, num), the same
    transition blend the other modes use.
    """
    look_type = look_type or state['lookType']
    if look_type not in ('TARGET', 'AWAY'):
        raise ValueError(f'neck_target_step only drives TARGET and AWAY, not {look_type}')
    if leap_time <= 0.0:
        raise ValueError('changeTypeLeapTime must be positive')
    if len(a_param) != 2:
        raise ValueError('the neck calculator reads exactly two bones')
    if len(now_angle) != 2 or not all(math.isfinite(component) for component in now_angle):
        raise ValueError('nowAngle needs two finite degrees')
    curve = curve or DEFAULT_CHANGE_TYPE_LERP_CURVE
    state = {**state,
             'fixAngle': [list(quaternion) for quaternion in state['fixAngle']],
             'fixAngleBackup': [list(quaternion) for quaternion in state['fixAngleBackup']]}
    if state['lookType'] != look_type:  # UpdateCall type-change branch
        state['lookType'] = look_type
        state['timer'] = 0.0
        state['fixAngleBackup'] = [list(quaternion) for quaternion in state['fixAngle']]
    if dt == 0.0:  # NeckUpdateCalc returns before touching anything
        return state, [None, None]
    state['timer'] = min(max(state['timer'] + dt, 0.0), leap_time)
    num = evaluate_curve(curve['keys'], state['timer'] / leap_time)
    residual = list(now_angle)
    horizontal, vertical = [0.0, 0.0], [0.0, 0.0]
    for index in (1, 0):  # the distribution loop runs bone 1 (head) first
        limits = a_param[index]
        horizontal[index] = clamp(residual[1], limits['minBendingAngle'],
                                  limits['maxBendingAngle'])
        vertical[index] = clamp(residual[0], limits['upBendingAngle'],
                                limits['downBendingAngle'])
        residual = [residual[0] - vertical[index], residual[1] - horizontal[index]]
    factor = min(max(dt * leap_speed, 0.0), 1.0)
    rotations = []
    for index in range(2):
        state['angleH'][index] += (horizontal[index] - state['angleH'][index]) * factor
        state['angleV'][index] += (vertical[index] - state['angleV'][index]) * factor
        state['fixAngle'][index] = _yx_basis(state['angleH'][index], state['angleV'][index])
        rotations.append(slerp(state['fixAngleBackup'][index], state['fixAngle'][index], num))
    return state, rotations
