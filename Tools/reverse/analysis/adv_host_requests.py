"""Independent model of the ADV presentation commands that become typed host requests.

Written from the recovered handlers (`ADV.Commands.*.Do`, `CommandBase.Initialize`,
`CommandList.Add`, `TextScenario.MessageWindowProc`) and Unity Mono's decompiled
`mscorlib` parsers (`Int32.Parse`, `Double.Parse`, `Single.Parse`,
`Boolean.Parse`), not from the Swift interpreter. `evaluate` returns what one
command does to the request queue, or the `Fault` the native kernel must raise
at that command.

Conservative boundaries (shared with the native kernel by design): a parse
whose outcome depends on culture symbols, Unicode table versions, collation of
punctuation or the native `Double.ParseImpl` on non-canonical digit strings is
`Unmodelled` and faults even where the source swallows exceptions. The current
culture is assumed to be non-Turkic with `.` as decimal separator.

Payloads use the native JSON shape (`SourceADVHostRequest.Command` arguments,
nil fields omitted) so `same` can compare them with float32 rounding.
"""
from __future__ import annotations

import math
import re
import struct

INT_MAX = 2147483647
CURRENT = str(INT_MAX)  # CommandBase.currentCharaDefaultIndex.ToString()

# CommandBase.ArgsDefault per handler (null for Text).
DEFAULTS = {16: None, 17: [CURRENT], 18: [CURRENT], 19: [CURRENT], 35: ["0", ""], 37: ["", "Base"],
            44: ["in", "", "", "", "none"], 45: ["True"], 88: ["", "", "0", "", "True", "", "", "", ""],
            106: [CURRENT], 112: [CURRENT], 125: [CURRENT, "0"], 128: [CURRENT, "0", "1"], 169: ["0", "1"]}
PRESENTATION = frozenset(DEFAULTS)
HANDLERS = {16: "ADV.Commands.Base.Text", 17: "ADV.Commands.Base.Voice", 18: "ADV.Commands.Base.Motion",
            19: "ADV.Commands.Base.Expression", 35: "ADV.Commands.Base.NullLoad", 37: "ADV.Commands.Base.NullSet",
            44: "ADV.Commands.Effect.SceneFade", 45: "ADV.Commands.Effect.SceneFadeRegulate",
            88: "ADV.Commands.Sound.BGM.Play", 106: "ADV.Commands.Chara.Motion", 112: "ADV.Commands.Chara.Expression",
            125: "ADV.Commands.Chara.LookEyes", 128: "ADV.Commands.Chara.LookNeck", 169: "ADV.Commands.Game.MapChange"}
KINDS = {16: "text", 35: "nullLoad", 37: "nullSet", 44: "sceneFade", 88: "bgmPlay", 106: "charaMotion",
         112: "charaExpression", 125: "charaLookEyes", 128: "charaLookNeck", 169: "mapChange"}
# Process() is the base `true` except Text (textHash: waits for Next), SceneFade
# (fade.IsEnd) and MapChange (UpdateRegulate while advScene.Map.isMapLoading).
BLOCKING = {16: "next", 44: "acknowledge", 169: "acknowledge"}
BINDINGS = {17: "voices", 18: "motions", 19: "expressions"}  # CurrentCharaData lists, consumed by Text.

BGM_NAMES = ["Title", "MapMoveDay", "MapMoveEve", "Custom", "Communication", "Encounter", "Lover", "Anger",
             "HSceneGentle", "HScene", "HScenePeep", "Sad", "Reminiscence", "Date", "MorningMenu", "NightMenu",
             "SystemMenu", "StaffRoom", "Daytime", "Evening", "Memories", "StaffRoom_01", "NightMenu_01", "Cool",
             "Lively", "Park", "Caffe", "Config"]  # Illusion.Game.BGM, implicit values.
FADE_TYPES = ["None", "InOut", "In", "Out"]  # Scene.Data.FadeType
NULL_TARGETS = ["Base", "Camera", "Chara"]  # ADV.Commands.Base.NullSet.Type


class SourceException(Exception):
    """The recovered code definitely throws here."""


class Unmodelled(Exception):
    """The recovered result depends on behaviour this model does not reproduce."""


class Fault(Exception):
    """The native kernel faults at this command."""

    REASONS = {"invalid-argument": "argument parse throws in {site}:", "unsupported-argument": "ADV argument form at {site}:",
               "mapchange-multi": "MapChange inside a Multi batch"}

    def __init__(self, kind, site):
        super().__init__(f"{kind} at {site}")
        self.kind, self.site = kind, site
        self.reason = self.REASONS[kind].format(site=site)


# ------------------------------------------------------------ Mono mscorlib

_WHITE = set(range(0x09, 0x0E)) | {0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000} | set(range(0x2000, 0x200B))
_TABLE_DEPENDENT = {0x180E, 0x200B, 0xFEFF}  # White space in some Unicode versions only.
_ASCII_WHITE = "\t\n\v\f\r "


def is_white(ch):
    """`char.IsWhiteSpace`."""
    if ord(ch) in _TABLE_DEPENDENT:
        raise Unmodelled("char.IsWhiteSpace table version")
    return ord(ch) in _WHITE


def _trailing(s, start):
    """`Int32.ProcessTrailingWhitespace`: NUL and white space only."""
    for ch in s[start:]:
        if ch != "\0" and not is_white(ch):
            raise SourceException("Int32.Parse: format")


def int32(s):
    """`Int32.Parse(string, bool tryParse, out int, out Exception)` fast path (culture invariant)."""
    i, n = 0, len(s)
    while i < n and is_white(s[i]):
        i += 1
    if i == n:
        raise SourceException("Int32.Parse: empty")
    sign = 1
    if s[i] == "+":
        i += 1
    elif s[i] == "-":
        sign, i = -1, i + 1
    number, digits = 0, False
    while i < n:
        ch = s[i]
        if ch == "\0":
            break  # `i = length`: the rest is never inspected.
        if "0" <= ch <= "9":
            digit = ord(ch) - 48
            if number < 214748364:
                number, digits, i = number * 10 + digit, True, i + 1
                continue
            if number == 214748364 and (digit <= 7 or (sign == -1 and digit <= 8)):
                _trailing(s, i + 1)
                return number * 10 + digit if sign == 1 else -number * 10 - digit
            raise SourceException("Int32.Parse: overflow")
        _trailing(s, i)
        break
    if not digits:
        raise SourceException("Int32.Parse: no digits")
    return sign * number


_CANONICAL = re.compile(r"-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE]-?[0-9]+)?")


def float32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def single(s):
    """`float.Parse(s)` = `(float)double.Parse(s, Float | AllowThousands, null)` plus Mono's overflow check."""
    if s == "":
        raise SourceException("Double.Parse: empty")
    i, n = 0, len(s)
    while i < n and is_white(s[i]):
        i += 1
    if i == n:
        raise SourceException("Double.Parse: white space")
    if any(ord(ch) > 0x7F for ch in s):
        raise Unmodelled("Double.Parse culture digits/white space")
    if "," in s:
        raise Unmodelled("Double.Parse culture group separator")
    end = n - 1
    while is_white(s[end]):
        end -= 1
    if s[i:end + 1] in ("NaN", "Infinity", "-Infinity"):
        raise Unmodelled("Double.Parse culture NaN/Infinity symbol")
    out, state = [], 1
    while i < n:
        ch = s[i]
        i += 1
        if ch == "\0":
            break
        digit, white = "0" <= ch <= "9", is_white(ch)
        if state == 1:
            state = 2
            if ch == "+":
                continue
            if ch == "-":
                out.append("-")
                continue
        if state == 2:
            if digit:
                out.append(ch)
            elif ch in "eE":
                out.append(ch)
                state = 4
            elif ch == ".":
                out.append(".")
                state = 3
            elif white:
                state = 6
            else:
                raise SourceException("Double.Parse: unknown char")
        elif state == 3:
            if digit:
                out.append(ch)
            elif ch in "eE":
                out.append(ch)
                state = 4
            elif white:
                state = 6
            else:
                raise SourceException("Double.Parse: unknown char")
        elif state == 4:
            if digit:
                out.append(ch)
                state = 5
            elif ch == "+":
                state = 2
            elif ch == "-":
                out.append("-")
                state = 2
            elif white:
                state = 6
            else:
                raise SourceException("Double.Parse: unknown char")
        elif state == 5:
            if digit:
                out.append(ch)
            elif white:
                state = 6
            else:
                raise SourceException("Double.Parse: unknown char")
        elif not white:
            raise SourceException("Double.Parse: trailing char")
    text = "".join(out)
    if not _CANONICAL.fullmatch(text):
        raise Unmodelled("Double.ParseImpl on non-canonical digits")
    number = float(text)
    if math.isinf(number):
        raise SourceException("Double.Parse: overflow")
    if number - 3.4028234663852886e38 > 3.6147112457961776e29:
        raise SourceException("Single.Parse: overflow")
    try:
        return float32(number)
    except OverflowError:
        raise Unmodelled("Single.Parse narrows to infinity") from None


def culture_equals(a, b, ignore_case):
    """`string.Compare(a, b, ignoreCase) == 0`; None when the culture's collation decides."""
    def printable(s):
        return all(0x20 <= ord(ch) <= 0x7E for ch in s)
    if not (printable(a) and printable(b)):
        return True if a == b else None
    fa, fb = (a.lower(), b.lower()) if ignore_case else (a, b)
    if fa == fb:
        return True
    def letters(s):
        return "".join(ch for ch in s if ch.isalnum())
    return None if letters(fa) == letters(fb) else False


def boolean(s):
    """`bool.Parse`: `Trim()` then invariant ignore-case comparison with True/False."""
    value = s.strip(_ASCII_WHITE)
    for name, result in (("True", True), ("False", False)):
        equal = culture_equals(value, name, True)
        if equal is None:
            raise Unmodelled("Boolean.Parse culture comparison")
        if equal:
            return result
    raise SourceException("Boolean.Parse: format")


def check(value, names, ignore_case=True):
    """Illusion `string.Check` / `Utils.Enum<T>.FindIndex`: first equal name or -1."""
    for index, name in enumerate(names):
        equal = culture_equals(value, name, ignore_case)
        if equal is None:
            raise Unmodelled("culture comparison")
        if equal:
            return index
    return -1


# ------------------------------------------------------------ NullCheck helpers

def null_or_empty(a, i):
    return not 0 <= i < len(a) or a[i] == ""


def safe_get(a, i):
    return a[i] if 0 <= i < len(a) else None


def safe_proc(a, i):
    return None if null_or_empty(a, i) else a[i]


def initialize(raw, defaults):
    """`CommandBase.Initialize`: non-empty arguments override defaults; extras append."""
    if defaults is None:
        return list(raw)
    result = list(defaults)
    for index, text in enumerate(raw):
        if index >= len(result):
            result.append(text)
        elif text != "":
            result[index] = text
    return result


def final_args(command, replace=lambda text: text):
    """`CommandList.Add`: Initialize, then `TextScenario.ReplaceVars` on every argument."""
    return [replace(text) for text in initialize(command["args"], DEFAULTS[command["id"]])]


def value(parse, text, site):
    try:
        return parse(text)
    except SourceException:
        raise Fault("invalid-argument", site) from None
    except Unmodelled:
        raise Fault("unsupported-argument", site) from None


def swallowed(parse, text, site):
    """Inside a source try/catch: a definite exception yields None."""
    try:
        return parse(text)
    except SourceException:
        return None
    except Unmodelled:
        raise Fault("unsupported-argument", site) from None


def _put(target, key, item):
    if item is not None:
        target[key] = item
    return target


# ------------------------------------------------------------ handlers

def look_neck(a):  # ADV.Commands.Chara.LookNeck.Do
    return dict(chara=value(int32, a[0], "Chara.LookNeck.Do No"), pattern=value(int32, a[1], "Chara.LookNeck.Do Ptn"),
                rate=value(single, a[2], "Chara.LookNeck.Do Rate"))


def look_eyes(a):  # ADV.Commands.Chara.LookEyes.Do
    return dict(chara=value(int32, a[0], "Chara.LookEyes.Do No"), pattern=value(int32, a[1], "Chara.LookEyes.Do Ptn"))


def bgm_play(a):  # ADV.Commands.Sound.BGM.Play.Do
    play = {}
    try:
        play["number"] = int32(a[0])  # int.TryParse
    except SourceException:
        index = value(lambda text: check(text, BGM_NAMES), a[0], "Sound.BGM.Play.Do Enum<BGM>.FindIndex")
        if index >= 0:
            play.update(number=index, enumName=BGM_NAMES[index])
        else:
            play["bundle"] = a[0]
    except Unmodelled:
        raise Fault("unsupported-argument", "Sound.BGM.Play.Do Bundle") from None
    _put(play, "asset", safe_proc(a, 1))
    play["delay"] = value(single, a[2], "Sound.BGM.Play.Do Delay")
    if safe_proc(a, 3) is not None:
        play["fade"] = value(single, a[3], "Sound.BGM.Play.Do Fade")
    play["isAsync"] = value(boolean, a[4], "Sound.BGM.Play.Do isAsync")
    for index, key, label in ((5, "pitch", "Pitch"), (6, "panStereo", "PanStereo"), (7, "time", "Time"), (8, "volume", "Volume")):
        if safe_proc(a, index) is not None:
            play[key] = value(single, a[index], "Sound.BGM.Play.Do " + label)
    return play


def pattern(text, site):
    """`Manager.Game.Expression.Pattern(arg, isThrow: true)`; None when it throws."""
    parts = text.split(",")
    result = dict(pattern=0, blend=True)
    if safe_proc(parts, 0) is not None:
        number = swallowed(int32, parts[0], site)
        if number is None:
            return None
        result["pattern"] = number
    if safe_proc(parts, 1) is not None:
        blend = swallowed(boolean, parts[1], site)
        if blend is None:
            return None
        result["blend"] = blend
    return result


_FIELDS = [("eyebrow", "pattern"), ("eyes", "pattern"), ("mouth", "pattern"), ("eyebrowOpen", single), ("eyesOpen", single),
           ("mouthOpen", single), ("eyesLook", int32), ("cheekRedRate", single), ("highlight", boolean), ("tearsLevel", int32),
           ("blink", boolean)]  # Manager.Game.Expression.Initialize order.


def expression_data(a, cnt):
    """`Base.Expression.Data(args, ref cnt)`: exceptions swallowed. Returns (chara, fields, cnt)."""
    site = "Base.Expression.Data.Initialize"
    fields = {}
    start, cnt = cnt, cnt + 1
    chara = swallowed(int32, a[start], site + " No")
    if chara is None:
        return 0, fields, cnt
    for key, parse in _FIELDS:
        index, cnt = cnt, cnt + 1
        text = safe_proc(a, index)
        if text is None:
            continue
        parsed = pattern(text, site + " Pattern") if parse == "pattern" else swallowed(parse, text, site)
        if parsed is None:
            break
        fields[key] = parsed
    return chara, fields, cnt


def expressions(a):
    """`ADV.Commands.Base.Expression.Convert` with an empty ExpLoad table."""
    entries, cnt = [], 0
    if len(a) <= 1:
        return entries
    while not null_or_empty(a, cnt):
        key = safe_proc(a, cnt + 1)
        if key is not None:
            chara = value(int32, a[cnt], "Base.Expression.Convert No")  # Outside any try block.
            if pattern(key, "Base.Expression.Convert lookup key") is None:
                # A personality-table hit or the fallback parse: both consume two
                # arguments; the fallback fails at the eyebrow and changes nothing.
                entries.append(dict(chara=chara, lookupKey=key))
                cnt += 2
                continue
        chara, fields, cnt = expression_data(a, cnt)
        entries.append(_put(_put(dict(chara=chara), "lookupKey", key), "expression", fields))
    return entries


_MOTION_STRINGS = ["bundle", "asset", "ikBundle", "ikAsset", "shakeBundle", "shakeAsset", "overrideBundle", "overrideAsset"]


def motions(a):
    """`Base.Motion.Convert` (empty MotionLoad table) and `Motion.Data(args, ref cnt)`, exceptions swallowed."""
    site = "Base.Motion.Data"
    entries, cnt = [], 0
    if len(a) <= 1:
        return entries
    while not null_or_empty(a, cnt):
        motion = dict(chara=0)
        entries.append(motion)
        start, cnt = cnt, cnt + 1
        chara = swallowed(int32, a[start], site + " No")
        if chara is None:
            continue
        motion["chara"] = chara
        state, cnt = cnt, cnt + 1
        if not 0 <= state < len(a):
            continue  # args[cnt++] throws IndexOutOfRange inside the try.
        motion["state"] = a[state]
        for key in _MOTION_STRINGS:
            _put(motion, key, safe_get(a, cnt))
            cnt += 1
        layer, cnt = cnt, cnt + 1
        text = safe_proc(a, layer)
        if text is not None:
            numbers = []
            for part in text.split(","):
                number = swallowed(int32, part, site + " LayerNo")
                if number is None:
                    numbers = None
                    break
                numbers.append(number)
            _put(motion, "layers", numbers)
    return entries


def voices(a):
    """`Base.Voice.Do` loop over `Voice.Data(args, ref cnt)`, exceptions swallowed."""
    site = "Base.Voice.Data"
    entries, cnt = [], 0
    if len(a) <= 1:
        return entries
    while not null_or_empty(a, cnt):
        voice = dict(chara=0)
        entries.append(voice)
        start, cnt = cnt, cnt + 1
        chara = swallowed(int32, a[start], site + " No")
        if chara is None:
            continue
        voice["chara"] = chara
        _put(voice, "bundle", safe_get(a, cnt))
        _put(voice, "asset", safe_get(a, cnt + 1))
        cnt += 2
        for key, parse, label in (("personality", int32, "Personality"), ("pitch", single, "Pitch")):
            index, cnt = cnt, cnt + 1
            text = safe_proc(a, index)
            if text is None:
                continue
            parsed = swallowed(parse, text, site + " " + label)
            if parsed is None:
                break
            voice[key] = parsed
    return entries


def map_change(a):  # ADV.Commands.Game.MapChange.Do
    change = {}
    try:
        change["mapNumber"] = int32(a[0])  # int.TryParse, else Map.ConvertMapNo(name)
    except SourceException:
        change["mapName"] = a[0]
    except Unmodelled:
        raise Fault("unsupported-argument", "Game.MapChange.Do No") from None
    fade, text = 1, a[1]
    if text != "":
        index = value(lambda t: check(t, FADE_TYPES), text, "Game.MapChange.Do Fade Check")
        if index >= 0:
            fade = index
        else:
            flag = swallowed(boolean, text, "Game.MapChange.Do Fade bool.TryParse")
            if flag is False:
                fade = 0
            elif flag is None:
                swallowed(int32, text, "Game.MapChange.Do Fade int.TryParse")  # Success clamps the default: no change.
    change["fade"] = FADE_TYPES[fade]
    return change


def null_load(a):  # ADV.Commands.Base.NullLoad.Do
    return _put(dict(version=value(int32, a[0], "Base.NullLoad.Do Version")), "map", None if a[1] == "デフォルト" else a[1])


def null_set(a):  # ADV.Commands.Base.NullSet.Do
    index = value(lambda t: check(t, NULL_TARGETS), a[1], "Base.NullSet.Do Type Check")
    return _put(dict(name=a[0]), "target", NULL_TARGETS[index] if index >= 0 else None)


def scene_fade(a):  # ADV.Commands.Effect.SceneFade.Do
    fade_in = culture_equals(a[0], "in", True)
    if fade_in is None:
        raise Fault("unsupported-argument", "Effect.SceneFade.Do Fade")
    fade = dict(fadeIn=fade_in)
    if safe_proc(a, 1) is not None:
        fade["time"] = value(single, a[1], "Effect.SceneFade.Do Time")
    if a[2] != "":
        raise Fault("unsupported-argument", "Effect.SceneFade.Do Color")  # string.GetColor is not modelled.
    if a[3] != "":
        fade["textureBundle"] = a[3]
        _put(fade, "textureAsset", safe_get(a, 4))
    return fade


def text_request(a):  # ADV.Commands.Base.Text.Do: Text.Data(args); ReplaceText is the host's.
    return dict(name=a[0] if a else "", text=a[1] if len(a) > 1 else "")


_PAYLOADS = {16: text_request, 35: null_load, 37: null_set, 44: scene_fade, 88: bgm_play, 106: motions, 112: expressions,
             125: look_eyes, 128: look_neck, 169: map_change}
_BINDING_PARSERS = {17: voices, 18: motions, 19: expressions}


def evaluate(command, replace=lambda text: text):
    """What one presentation command does. Raises `Fault` where the native kernel must fault.

    Returns ("request", kind, blocking, payload), ("binding", list name, entries)
    or ("state", "sceneFadeRegulate", bool).
    """
    cid = command["id"]
    if cid == 169 and command["multi"]:
        raise Fault("mapchange-multi", "Game.MapChange.Do")
    a = final_args(command, replace)
    if cid == 45:
        return "state", "sceneFadeRegulate", value(boolean, a[0], "Effect.SceneFadeRegulate.Do Flag")
    if cid in _BINDING_PARSERS:
        return "binding", BINDINGS[cid], _BINDING_PARSERS[cid](a)
    return "request", KINDS[cid], BLOCKING.get(cid, "none"), _PAYLOADS[cid](a)


def touches(command, assigned):
    """Whether ReplaceVars may substitute a scenario-assigned variable into this command."""
    return bool(assigned) and any(text in assigned for text in initialize(command["args"], DEFAULTS[command["id"]]))


def assigned_names(commands):
    """Variables the native kernel can assign under default inputs (VAR, Calc, Clamp targets)."""
    names = {c["args"][1] for c in commands if c["id"] == 1 and len(c["args"]) > 1}
    return names | {c["args"][0] for c in commands if c["id"] in (3, 4) and c["args"]}


def predict_requests(commands, end):
    """Request sequence of a straight-line prefix [0, end) under the scripted host.

    Each non-multi command (other than None) or Close ends a batch; every batch
    starts with empty CurrentCharaData (MessageWindowProc clears it before
    RequestNextLine). Returns request dicts in the native JSON shape.
    """
    requests, bindings, batch = [], {}, 1
    for pc in range(min(end, len(commands))):
        command = commands[pc]
        cid = command["id"]
        if cid in PRESENTATION:
            outcome = evaluate(command)
            if outcome[0] == "request":
                _, kind, blocking, payload = outcome
                if cid == 16:
                    payload = dict(payload, **bindings)
                requests.append(dict(requestID=len(requests), pc=pc, commandID=cid, batch=batch, blocking=blocking,
                                     command=dict(kind=kind, arguments=payload)))
            elif outcome[0] == "binding":
                bindings[outcome[1]] = bindings.get(outcome[1], []) + [outcome[2]]
        if cid == 22:
            break
        if not command["multi"] and cid != 0:
            batch, bindings = batch + 1, {}
    return requests


def same(observed, predicted):
    """Structural equality with numbers compared after float32 rounding."""
    if isinstance(observed, bool) or isinstance(predicted, bool):
        return type(observed) is type(predicted) and observed == predicted
    if isinstance(observed, (int, float)) and isinstance(predicted, (int, float)):
        return float32(float(observed)) == float32(float(predicted))
    if isinstance(observed, dict) and isinstance(predicted, dict):
        return observed.keys() == predicted.keys() and all(same(observed[k], predicted[k]) for k in observed)
    if isinstance(observed, list) and isinstance(predicted, list):
        return len(observed) == len(predicted) and all(same(o, p) for o, p in zip(observed, predicted))
    return observed == predicted
