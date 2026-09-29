#!/usr/bin/env python3
"""Pure Python reference of the original iris-material writes, in float32.

Port of the two recovered write paths the ST-T07x probe compares against a
VM capture:

* `ChaControl.ChangeSettingEye*` / `ChangeSettingEyeTilt` — the load-time
  card reads (pupilX/pupilY/pupilWidth/pupilHeight/hlUpY/hlDownY and shape
  value 33) that `card_values` and `iris_rotations` replay, including the
  EYE_R negation SetEyeTexOffsetX applies;
* `EyeLookMaterialControll.Update` — the per-frame iris texture writes that
  `iris_texture_transforms` replays from a frame's angleHRate/angleVRate
  pair, the controller's offset/scale/highlight fields and the bo_head_00
  eyeMaterial waits/limits/power (script.GetAngleHRate(eyeLR) /
  GetAngleVRate() feed the sum whose magnitude gate renormalizes only
  outside the unit circle).

Unlike the Swift formulas under test (which replay the same math in Double),
every arithmetic step here round-trips through float32 with the operand
order the decompiled game code shows, so predictions can be compared against
captured Material values tighter than the Swift doubles alone would allow.
The Unity Mathf semantics match the Swift helpers: Lerp clamps t to 0...1,
InverseLerp clamps and reports 1 for a degenerate range (unreached by the
prefab's -1...1), and the texture clamp throws on an inverted limit range
instead of picking an endpoint.  `nativeST` — our own renderer-space
conversion — is deliberately not part of this module.
"""
from __future__ import annotations

import math
import struct

# The three texture slots EyeLookMaterialControll.Initialize builds, in index
# order; slot 1 gets hlUpOffsetY and slot 2 hlDownOffsetY added to its offset.
TEX_SLOTS = ('_MainTex', '_overtex1', '_overtex2')


def f32(value: float) -> float:
    """Nearest float32, the precision the game's Mathf and Material run in."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f'{value!r} is not a number')
    value = float(value)
    if not math.isfinite(value):
        raise ValueError(f'{value!r} is not finite')
    return struct.unpack('<f', struct.pack('<f', value))[0]


def _number(value, what: str) -> float:
    """A recorded/hand value narrowed to the float32 the game would hold."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f'{what} is not a number: {value!r}')
    return f32(value)


def _pair(value, what: str) -> list[float]:
    if isinstance(value, (str, bytes)) or len(value) != 2:
        raise ValueError(f'{what} is not an xy pair: {value!r}')
    return [_number(value[0], f'{what}.x'), _number(value[1], f'{what}.y')]


def _clamp01(t: float) -> float:
    # Mathf.Clamp01 without the f32 round-trip: 0.0 and 1.0 are exact.
    return 1.0 if t > 1.0 else (0.0 if t < 0.0 else t)


def _lerp(a: float, b: float, t: float) -> float:
    """Mathf.Lerp(a, b, t) = a + (b - a) * clamp01(t), each step in float32.

    The endpoints are narrowed first: every call site in the game is either
    a float literal (0.1f, 1.8f, 0.02f ...) held as float32 or a value that
    already came from a float32 field, so a raw double literal here would
    land the add a ulp away from what the game actually holds — enough for
    Mathf.Lerp(0.1f, -0.1f, 0.5f) to be exactly 0 in the game and −1.49e-9
    against a double 0.1.
    """
    a, b = f32(a), f32(b)
    return f32(f32(a + f32(f32(b - a) * _clamp01(t))))


def _inverse_lerp(a: float, b: float, value: float) -> float:
    """Mathf.InverseLerp; the Swift helper's degenerate-range answer is 1.

    The prefab always drives this with a = -1, b = 1, so the branch below is
    the Swift contract carried over, not an observed Unity behaviour.
    """
    if a == b:
        return 1.0
    return _clamp(f32(f32(value - a) / f32(b - a)), 0.0, 1.0)


def _clamp(value: float, low: float, high: float) -> float:
    """Mathf.Clamp, with the Swift textureTransforms' inverted-range failure."""
    if low > high:
        raise ValueError(f'clamp range {low}..{high} is inverted')
    return f32(min(max(value, low), high))


def settings_from_exported(entry: dict, script_defaults: bool = True) -> dict:
    """One exported eyeMaterial entry (studio-look-settings.json) to the
    snake_case settings this module consumes.

    `script_defaults` keeps the values EyeLookMaterialControll.Initialize
    ships with — the values ReSetupMaterial keeps unless the prefab overrode
    them — and is only a guard: the exported bo_head_00 block matches them
    on both eyes, so the capture compares against the exported numbers.
    """
    waits = {'insideWait': -100, 'outsideWait': 100, 'upWait': -100, 'downWait': 100,
             'insideLimit': -100.0, 'outsideLimit': 100.0, 'upLimit': -80.0, 'downLimit': 80.0,
             'power': 0.001}
    snake = {
        'eyeLR': int(entry['eyeLR']),
        'gameObject': entry.get('gameObject'),
        'insideWait': _number(entry['InsideWait'], 'InsideWait'),
        'outsideWait': _number(entry['OutsideWait'], 'OutsideWait'),
        'upWait': _number(entry['UpWait'], 'UpWait'),
        'downWait': _number(entry['DownWait'], 'DownWait'),
        'insideLimit': _number(entry['InsideLimit'], 'InsideLimit'),
        'outsideLimit': _number(entry['OutsideLimit'], 'OutsideLimit'),
        'upLimit': _number(entry['UpLimit'], 'UpLimit'),
        'downLimit': _number(entry['DownLimit'], 'DownLimit'),
        'power': _number(entry['power'], 'power'),
        'offset': _pair(entry['offset'], 'offset'),
        'scale': _pair(entry['scale'], 'scale'),
        'hlUpOffsetY': _number(entry['hlUpOffsetY'], 'hlUpOffsetY'),
        'hlDownOffsetY': _number(entry['hlDownOffsetY'], 'hlDownOffsetY'),
        'texStates': [],
    }
    if script_defaults:
        for key, default in waits.items():
            if snake[key] != _number(default, key):
                raise ValueError(f'exported {key} {snake[key]} differs from the Initialize default '
                                 f'{default}; this reference only replays the default waits/limits')
    for state in entry.get('texStates', []):
        name = state.get('texName')
        if not isinstance(name, str) or not name:
            raise ValueError(f'texStates entry has no texName: {state!r}')
        snake['texStates'].append({'texName': name, 'isYure': bool(int(state.get('isYure', 0)))})
    if not snake['texStates']:
        raise ValueError('the eyeMaterial entry needs a texStates list')
    return snake


def card_values(pupil_x, pupil_y, pupil_width, pupil_height, hl_up_y, hl_down_y,
                sex: int, ex_type: int):
    """The ChangeSettingEye* Lerps, shared between both eyes.

    Returns None when the methods return early (sex == 0 with exType == 1,
    the female-only body) so the caller keeps the prefab snapshot, exactly
    like the Swift cardOverrides.  The offset x is the value
    SetEyeTexOffsetX receives; the EYE_R negation happens per eye in
    `eye_fields`, mirroring the setter rather than the card.
    """
    if int(sex) == 0 and int(ex_type) == 1:
        return None
    return {'offsetX': _lerp(0.2, -0.6, _number(pupil_x, 'pupilX')),
            'offsetY': _lerp(-0.5, 0.5, _number(pupil_y, 'pupilY')),
            'scale': [_lerp(1.8, -0.2, _number(pupil_width, 'pupilWidth')),
                      _lerp(1.8, -0.2, _number(pupil_height, 'pupilHeight'))],
            'hlUp': _lerp(0.1, -0.1, _number(hl_up_y, 'hlUpY')),
            'hlDown': _lerp(0.1, -0.1, _number(hl_down_y, 'hlDownY'))}


def iris_rotations(shape_value_face_33):
    """The ChangeSettingEyeTilt write: L = Lerp(0.02, -0.02, v33), R =
    Lerp(-0.02, 0.02, v33), set straight onto rendEye[i].material."""
    t = _number(shape_value_face_33, 'shapeValueFace[33]')
    return [_lerp(0.02, -0.02, t), _lerp(-0.02, 0.02, t)]


def eye_fields(settings: dict, card):
    """The offset/scale/hlUpOffsetY/hlDownOffsetY the controller holds.

    With a card the ChangeSettingEye* setters overwrote every field (the
    EYE_R eye stores the negated shared x); without one the prefab snapshot
    in `settings` still stands.
    """
    if card is None:
        return {'offset': _pair(settings['offset'], 'settings offset'),
                'scale': _pair(settings['scale'], 'settings scale'),
                'hlUpOffsetY': _number(settings['hlUpOffsetY'], 'hlUpOffsetY'),
                'hlDownOffsetY': _number(settings['hlDownOffsetY'], 'hlDownOffsetY')}
    offset_x = -card['offsetX'] if int(settings['eyeLR']) == 1 else card['offsetX']
    return {'offset': [f32(offset_x), f32(card['offsetY'])],
            'scale': _pair(card['scale'], 'card scale'),
            'hlUpOffsetY': f32(card['hlUp']),
            'hlDownOffsetY': f32(card['hlDown'])}


def iris_texture_transforms(rate_h, rate_v, settings: dict, card):
    """EyeLookMaterialControll.Update's three texture writes for one frame.

    `rate_h` / `rate_v` are script.GetAngleHRate(eyeLR) and
    GetAngleVRate() as the frame's EyeLookCalc left them; `card` is a
    `card_values` result or None for the prefab snapshot.  Each entry of the
    returned list is {'texName', 'offset': [u, v], 'scale': [su, sv],
    'yure'} — 'yure' set on a Yure-flagged slot, whose Random.Range jitter
    this reference does not model (the fixture card flags none of the three
    slots, so the captured materials are fully predicted).
    """
    fields = eye_fields(settings, card)
    x = f32(_number(rate_h, 'rateH') + fields['offset'][0])
    y = f32(_number(rate_v, 'rateV') + fields['offset'][1])
    magnitude = f32(math.sqrt(f32(f32(x * x) + f32(y * y))))
    if magnitude > 1.0:
        x = f32(x / magnitude)
        y = f32(y / magnitude)
    num = _lerp(settings['insideWait'], settings['outsideWait'],
                _inverse_lerp(-1.0, 1.0, x))
    num2 = _lerp(settings['downWait'], settings['upWait'],
                 _inverse_lerp(-1.0, 1.0, y))
    num3 = _lerp(1.0, 5.0, fields['scale'][0])
    num4 = _lerp(1.0, 5.0, fields['scale'][1])
    transforms = []
    for index, state in enumerate(settings['texStates']):
        power_x = f32(settings['power'] * 0.8) if state['isYure'] else settings['power']
        power_y = f32(settings['power'] * 0.5) if state['isYure'] else settings['power']
        out_x = _clamp(f32(num * f32(power_x * num3)),
                       settings['insideLimit'], settings['outsideLimit'])
        out_y = _clamp(f32(num2 * f32(power_y * num4)),
                       settings['upLimit'], settings['downLimit'])
        if index == 1:
            out_y = f32(out_y + fields['hlUpOffsetY'])
        elif index == 2:
            out_y = f32(out_y + fields['hlDownOffsetY'])
        if state['isYure']:
            # Swift's Yure modeling: the randomly re-rolled YureAddScale and
            # YureAddVec writes (the game re-rolls YureAddScale in
            # Random.Range(1, 2) / Random.Range(1, 1.5) every YureTime) are
            # left out entirely — the offset passes through the clamp and
            # highlight add untouched and the texture scale reports (1, 1),
            # with `yure` set so the caller knows the value is a placeholder.
            transforms.append({'texName': state['texName'], 'offset': [out_x, out_y],
                               'scale': [1.0, 1.0], 'yure': True})
            continue
        out_x = f32(out_x + f32(fields['scale'][0] * -0.5))
        out_y = f32(out_y + f32(fields['scale'][1] * -0.5))
        scale = [f32(1.0 + fields['scale'][0]), f32(1.0 + fields['scale'][1])]
        transforms.append({'texName': state['texName'], 'offset': [out_x, out_y],
                           'scale': scale, 'yure': False})
    return transforms
