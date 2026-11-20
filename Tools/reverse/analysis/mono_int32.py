"""`char.IsWhiteSpace` and `int.Parse(string)` in the game's Mono corlib (#427).

Mirrors Packages/Engine/Sources/Assets/SourceMonoInt32.swift rule for rule, with the same messages. Two mirrors use it:
mod_catalog_contract (Sideloader's list loading) and adv_host_requests (the ADV handlers).
"""
from __future__ import annotations

# char.IsWhiteSpace (Unity-Technologies/mono branch unity-5.6, mcs/class/corlib/System/Char.cs, NET_2_0; the game's
# mscorlib.dll, sha256 37e0d42a..., has the same rule). True for:
# - SpaceSeparator, LineSeparator and ParagraphSeparator in the runtime's CategoryData table
#   (mono/metadata/char-conversions.h, 65536 entries by UTF-16 code unit);
# - U+0009-U+000D, U+0085 and U+205F.
# The table predates Unicode 3.2, so U+200B is a SpaceSeparator, and U+180E and U+FEFF are Format. That gives 26 code
# units. This is not String.WhiteChars, which adds U+FEFF. CategoryData is compiled into mono.dll: this set was checked
# against the branch source, not the installed binary.
WHITE_SPACE = frozenset([*range(0x09, 0x0E), 0x20, 0x85, 0xA0, 0x1680, *range(0x2000, 0x200C), 0x2028, 0x2029,
                         0x202F, 0x205F, 0x3000])


class ParseError(ValueError):
    """The source throws a FormatException or an OverflowException."""


def is_white_space(ch: str) -> bool:
    """`char.IsWhiteSpace` for one UTF-16 code unit; code points above U+FFFF are surrogate pairs, not white space."""
    return ord(ch) in WHITE_SPACE


def _trailing(s: str, start: int) -> bool:
    """`Int32.ProcessTrailingWhitespace`: NUL and white space only."""
    return all(ch == "\0" or is_white_space(ch) for ch in s[start:])


def int32(s: str) -> int:
    """`int.Parse(string)` / `int.TryParse`: Int32.cs `Parse(string, bool, out int, out Exception)`, culture invariant.

    These steps:
    - skip leading white space;
    - take one sign;
    - read ASCII digits;
    - allow only white space or NUL after them.
    A NUL among the digits ends the number, and the rest is never read. At the digit that reaches the Int32 limit,
    the whole remainder is checked instead.
    """
    i, n = 0, len(s)
    while i < n and is_white_space(s[i]):
        i += 1
    if i == n:
        raise ParseError("Int32.Parse: no digits")
    negative = False
    if s[i] == "+":
        i += 1
    elif s[i] == "-":
        negative, i = True, i + 1
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
            if number == 214748364 and (digit <= 7 or (negative and digit <= 8)):
                if not _trailing(s, i + 1):
                    raise ParseError("Int32.Parse: trailing characters")
                return -number * 10 - digit if negative else number * 10 + digit
            raise ParseError("Int32.Parse: overflow")
        if not _trailing(s, i):
            raise ParseError("Int32.Parse: format")
        break
    if not digits:
        raise ParseError("Int32.Parse: no digits")
    return -number if negative else number
