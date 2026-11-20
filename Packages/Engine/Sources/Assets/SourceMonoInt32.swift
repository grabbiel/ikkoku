/// `char.IsWhiteSpace` and `int.Parse(string)` in the game's Mono corlib (#427),
/// shared by Sideloader's list loading (`SourceModCatalog`) and the ADV
/// handlers (`SourceCLR` in Gameplay).
///
/// `char.IsWhiteSpace` (Unity-Technologies/mono, branch unity-5.6,
/// `mcs/class/corlib/System/Char.cs`, `IsWhiteSpace` with its NET_2_0 block;
/// the game's mscorlib.dll, sha256 37e0d42a…, has the same rule) is true for
/// three categories in the runtime's `CategoryData` table: SpaceSeparator,
/// LineSeparator and ParagraphSeparator. It is also true for U+0009–U+000D,
/// U+0085 and U+205F.
///
/// That table is `mono/metadata/char-conversions.h` on the same branch:
/// 65536 entries indexed by UTF-16 code unit. It predates Unicode 3.2, where
/// U+205F is unassigned. So U+200B is a SpaceSeparator, and U+180E and U+FEFF
/// are Format.
///
/// The white set is 26 code units: U+0009–U+000D, U+0020, U+0085, U+00A0,
/// U+1680, U+2000–U+200B, U+2028, U+2029, U+202F, U+205F and U+3000. It is
/// not `String.WhiteChars` (`SourceMonoWhiteChars`), which adds U+FEFF.
/// `CategoryData` is compiled into mono.dll, not mscorlib. This set was checked
/// against the branch source, not the installed binary.
///
/// `int.Parse(string)` and `int.TryParse(string, out int)` use `Int32.cs`
/// `Parse(string, bool, out int, out Exception)` and
/// `ProcessTrailingWhitespace`. They are culture invariant and take no
/// `NumberStyles`:
/// - leading white space;
/// - one `+` or `-`;
/// - ASCII digits;
/// - then only white space or NUL to the end.
/// A NUL among the digits ends the number, and the rest is never read. At the
/// digit that reaches the Int32 limit, the whole remainder is checked as white
/// space or NUL instead.
public enum SourceMonoInt32 {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// `char.IsWhiteSpace` for one UTF-16 code unit. Scalars above U+FFFF are
    /// surrogate pairs there, and surrogates are not white space.
    public static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// `int.Parse(string)`; a failure is the source's FormatException or OverflowException.
    public static func parse(_ text: String) -> Result<Int32, Failure> {
        let s = Array(text.unicodeScalars)
        func fail(_ reason: String) -> Result<Int32, Failure> { .failure(Failure(description: "Int32.Parse: " + reason)) }
        func trailing(from start: Int) -> Bool { s[min(start, s.count)...].allSatisfy { $0 == "\0" || isWhiteSpace($0) } }
        var i = 0
        while i < s.count, isWhiteSpace(s[i]) { i += 1 }
        if i == s.count { return fail("no digits") }
        var negative = false
        if s[i] == "+" { i += 1 } else if s[i] == "-" { negative = true; i += 1 }
        var number: Int32 = 0, digits = false
        while i < s.count {
            let c = s[i]
            if c == "\0" { break }
            if ("0"..."9").contains(c) {
                let digit = Int32(c.value - 48)
                if number < 214748364 { number = number * 10 + digit; digits = true; i += 1; continue }
                if number == 214748364, digit <= 7 || (negative && digit <= 8) {
                    guard trailing(from: i + 1) else { return fail("trailing characters") }
                    return .success(negative ? -number * 10 - digit : number * 10 + digit)
                }
                return fail("overflow")
            }
            guard trailing(from: i) else { return fail("format") }
            break
        }
        guard digits else { return fail("no digits") }
        return .success(negative ? -number : number)
    }
}
