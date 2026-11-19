import Assets
import Foundation

/// Result of one recovered Unity Mono parse or culture-sensitive comparison.
///
/// `exception` means the recovered code path definitely throws, `unsupported`
/// means its result depends on behaviour this kernel does not model
/// (`char.IsDigit` beyond ASCII, culture symbols, collation of punctuation, the
/// native `Double.ParseImpl` on non-canonical digit strings). Callers fault on
/// `unsupported` even where the original swallows exceptions.
enum SourceCLRResult<Value> {
    case value(Value)
    case exception(String)
    case unsupported(String)
}

/// Unity Mono `mscorlib` parsing semantics used by ADV command handlers.
/// Source: the installed `Koikatu_Data/Managed/mscorlib.dll` decompiled with
/// the repository's pinned ILSpy (`Int32.Parse(string, bool, out int, out Exception)`,
/// `Double.Parse(string, NumberStyles, IFormatProvider, bool, out double, out Exception)`,
/// `Single.Parse(string)`, `Boolean.Parse(string)`).
enum SourceCLR {
    /// `char.IsWhiteSpace` for one UTF-16 code unit: the shared
    /// `SourceMonoInt32.isWhiteSpace` (Assets, #427).
    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool { SourceMonoInt32.isWhiteSpace(scalar) }

    /// `int.Parse(string)` / `int.TryParse(string, out int)`: the shared
    /// `SourceMonoInt32.parse` (Assets, #427). It is culture invariant: leading
    /// and trailing white space, one sign, ASCII digits, a NUL ends the number,
    /// and overflow throws.
    static func int32(_ text: String) -> SourceCLRResult<Int32> {
        switch SourceMonoInt32.parse(text) {
        case .success(let value): return .value(value)
        case .failure(let failure): return .exception(failure.description)
        }
    }

    /// `Convert.ChangeType(string, typeof(int))`: `String.ToInt32(provider)` →
    /// `Int32.Parse(s, NumberStyles.Integer, CurrentCulture)`, Mono's styled
    /// parser (not the `int.Parse(string)` fast path): leading white space, a
    /// culture sign (`-`/`+`; `+` only when a character follows it), white
    /// space again, digits, trailing white space, then end or NUL. Overflow
    /// throws. `char.IsDigit` beyond ASCII (and the digit value Mono then
    /// computes) is not modelled, so any non-ASCII input is unsupported.
    static func int32Integer(_ text: String) -> SourceCLRResult<Int32> {
        let s = Array(text.utf16)
        if s.isEmpty { return .exception("Int32.Parse: empty string") }
        guard s.allSatisfy({ $0 < 0x80 }) else { return .unsupported("Int32.Parse(NumberStyles.Integer) of non-ASCII text") }
        func white(_ c: UInt16) -> Bool { (0x09...0x0D).contains(c) || c == 0x20 }
        func jump(_ pos: inout Int) { while pos < s.count && white(s[pos]) { pos += 1 } }
        var pos = 0, negative = false, foundSign = false
        jump(&pos)
        if pos >= s.count { return .exception("Int32.Parse: format") }
        // FindSign: NegativeSign when it fits, PositiveSign only before another character.
        if s[pos] == 0x2D { negative = true; foundSign = true; pos += 1 }
        else if s[pos] == 0x2B, pos + 1 < s.count { foundSign = true; pos += 1 }
        if foundSign {
            jump(&pos)
            if pos >= s.count { return .exception("Int32.Parse: format") }
        }
        // Mono accumulates the negated value, then negates it unless negative.
        var number: Int32 = 0, digits = 0
        repeat {
            let c = s[pos]
            guard (0x30...0x39).contains(c) else { break }
            digits += 1; pos += 1
            let (scaled, o1) = number.multipliedReportingOverflow(by: 10)
            let (next, o2) = scaled.subtractingReportingOverflow(Int32(c - 0x30))
            if o1 || o2 { return .exception("Int32.Parse: overflow") }
            number = next
        } while pos < s.count
        if digits == 0 { return .exception("Int32.Parse: format") }
        jump(&pos)
        if pos < s.count && s[pos] != 0 { return .exception("Int32.Parse: format") }
        if !negative {
            guard number != .min else { return .exception("Int32.Parse: overflow") }
            number = -number
        }
        return .value(number)
    }

    /// `float.Parse(string)`: `(float)double.Parse(s, Float | AllowThousands, null)`
    /// plus Mono's positive-overflow check. The decimal point is `.`; group
    /// separators, culture NaN/Infinity symbols and non-ASCII digits are
    /// culture-dependent and unsupported. Only canonical digit strings reach
    /// the native `ParseImpl`, where any correctly rounded `strtod` agrees.
    static func single(_ text: String) -> SourceCLRResult<Float> {
        let s = Array(text.unicodeScalars)
        if s.isEmpty { return .exception("Double.Parse: empty") }
        var i = 0
        while i < s.count, isWhiteSpace(s[i]) { i += 1 }
        if i == s.count { return .exception("Double.Parse: white space only") }
        if s.contains(where: { !$0.isASCII }) { return .unsupported("Double.Parse non-ASCII character") }
        if s.contains(",") { return .unsupported("Double.Parse culture group/decimal separator ','") }
        let trimmed = String(String.UnicodeScalarView(s[i...])).trimmingCharacters(in: CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r "))
        if ["NaN", "Infinity", "-Infinity"].contains(trimmed) { return .unsupported("Double.Parse culture NaN/Infinity symbol") }
        var built = "", state = 1
        scan: while i < s.count {
            let c = s[i]
            if c == "\0" { break }
            let digit = ("0"..."9").contains(c), white = isWhiteSpace(c)
            switch state {
            case 1, 2:
                if state == 1 {
                    state = 2
                    if c == "+" { i += 1; continue scan }
                    if c == "-" { built.append("-"); i += 1; continue scan }
                }
                if digit { built.unicodeScalars.append(c) }
                else if c == "e" || c == "E" { built.unicodeScalars.append(c); state = 4 }
                else if c == "." { built.append("."); state = 3 }
                else if white { state = 6 }
                else { return .exception("Double.Parse: unknown character") }
            case 3:
                if digit { built.unicodeScalars.append(c) }
                else if c == "e" || c == "E" { built.unicodeScalars.append(c); state = 4 }
                else if white { state = 6 }
                else { return .exception("Double.Parse: unknown character") }
            case 4:
                if digit { built.unicodeScalars.append(c); state = 5 }
                else if c == "+" { state = 2 }
                else if c == "-" { built.append("-"); state = 2 }
                else if white { state = 6 }
                else { return .exception("Double.Parse: unknown character") }
            case 5:
                if digit { built.unicodeScalars.append(c) }
                else if white { state = 6 }
                else { return .exception("Double.Parse: unknown character") }
            default:
                if !white { return .exception("Double.Parse: trailing character") }
            }
            i += 1
        }
        guard built.range(of: #"^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE]-?[0-9]+)?$"#, options: .regularExpression) != nil,
              let number = Double(built) else {
            return .unsupported("Double.ParseImpl on non-canonical digits")
        }
        if number.isInfinite { return .exception("Double.Parse: overflow") }
        if number - 3.4028234663852886E+38 > 3.6147112457961776E+29 { return .exception("Single.Parse: overflow") }
        let value = Float(number)
        guard value.isFinite else { return .unsupported("Single.Parse narrows to a nonfinite value") }
        return .value(value)
    }

    /// `bool.Parse(string)` / `bool.TryParse`: `Trim()` then an invariant-culture,
    /// case-insensitive comparison with "True" and "False".
    static func boolean(_ text: String) -> SourceCLRResult<Bool> {
        // ASCII white space only: a remaining non-ASCII character makes the
        // comparison below unsupported, so Trim()'s Unicode table never matters.
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r "))
        for (name, result) in [("True", true), ("False", false)] {
            switch cultureEquals(value, name, ignoreCase: true) {
            case true?: return .value(result)
            case false?: continue
            case nil: return .unsupported("Boolean.Parse culture comparison")
            }
        }
        return .exception("Boolean.Parse: format")
    }

    /// `string.Compare(a, b, ignoreCase) == 0` under a culture. Exact for
    /// printable-ASCII operands whose letters and digits differ, or that are
    /// identical; nil when equality would depend on how the culture weighs
    /// punctuation, spaces, control or non-ASCII characters.
    static func cultureEquals(_ a: String, _ b: String, ignoreCase: Bool) -> Bool? {
        func printable(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) } }
        guard printable(a), printable(b) else { return a == b ? true : nil }
        func fold(_ s: String) -> String { ignoreCase ? s.lowercased() : s }
        if fold(a) == fold(b) { return true }
        func alphanumerics(_ s: String) -> String { String(fold(s).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        return alphanumerics(a) == alphanumerics(b) ? nil : false
    }

    /// Illusion `string.Check(ignoreCase, names)` and `Utils.Enum<T>.FindIndex`:
    /// the first name the culture comparison equals, or -1.
    static func check(_ value: String, ignoreCase: Bool, names: [String]) -> SourceCLRResult<Int> {
        for (index, name) in names.enumerated() {
            switch cultureEquals(value, name, ignoreCase: ignoreCase) {
            case true?: return .value(index)
            case false?: continue
            case nil: return .unsupported("culture comparison of \(name)")
            }
        }
        return .value(-1)
    }
}

/// CommandBase helpers from the recovered `NullCheck` extensions.
enum SourceADVArgs {
    /// `string[].IsNullOrEmpty(index)`.
    static func isNullOrEmpty(_ args: [String], _ index: Int) -> Bool { !args.indices.contains(index) || args[index].isEmpty }
    /// `string[].SafeGet(index)`.
    static func safeGet(_ args: [String], _ index: Int) -> String? { args.indices.contains(index) ? args[index] : nil }
    /// The value `string[].SafeProc(index, act)` passes to `act`, if it runs.
    static func safeProc(_ args: [String], _ index: Int) -> String? { isNullOrEmpty(args, index) ? nil : args[index] }
    /// `CommandBase.Initialize`: non-empty arguments override defaults; extra arguments are appended.
    static func initialize(_ raw: [String], defaults: [String]?) -> [String] {
        guard var result = defaults else { return raw }
        for (index, text) in raw.enumerated() {
            if index >= result.count { result.append(text) } else if !text.isEmpty { result[index] = text }
        }
        return result
    }
}
