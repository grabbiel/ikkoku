import Foundation
import Assets
import CryptoKit
import Scene

/// ABMX card PluginData version 1: the legacy text `boneData` that KKABMX 5.4
/// reads through `OldDataConverter.MigrateOldExtData` (#403). The rules follow
/// the recovered source line by line. Where they depend on Mono's corlib
/// (`string.Split()`, `float.Parse`), `docs/reference/mods/abmx.md` lists the
/// rule used and what the original player showed.
extension SourceBoneModifiers {
    /// The token separators of `text.Split()`: Mono's `String.WhiteChars`
    /// (`SourceMonoWhiteChars`), not `char.IsWhiteSpace`. `Trim()` uses the same
    /// set, so it never changes a token.
    static let legacyWhitespace: Set<UInt32> = SourceMonoWhiteChars.scalars

    /// The character loads without ABMX: version 1 data whose `boneData` is
    /// not a string reads as no modifiers in the original.
    public static func legacyNotText(
        assemblySHA256: String = "f3e2d9877b08b2b25187cbc101478ea0d484bcfe4856244050ba3119578e9f68"
    ) throws -> Self {
        try legacyDocument(text: "", modifiers: [], diagnostics: [Diagnostic(code: "legacy-bone-data-not-text", severity: "warning",
            message: "ABMX card v1 boneData is not text; the original's legacy reader returns no modifiers, so the character loads without ABMX.")],
            assemblySHA256: assemblySHA256)
    }

    /// Migrate card v1 text, as `OldDataConverter.DeserializeToModifiers`:
    /// whitespace-separated lines of comma-separated fields, grouped by bone
    /// name with the `__<coordinate>` suffix trimmed, Scale from fields 3–5 and
    /// Length from field 6 (1 when absent), at location 0 (Unknown).
    public static func decodeLegacyText(
        _ text: String,
        assemblySHA256: String = "f3e2d9877b08b2b25187cbc101478ea0d484bcfe4856244050ba3119578e9f68"
    ) throws -> Self {
        guard !text.isEmpty, text.utf8.count <= 16 * 1024 * 1024 else {
            throw RigError.invalid("ABMX card v1 boneData must contain 1 byte through 16 MiB of text.")
        }
        // text.Split(), then Trim() and IsNullOrEmpty: whitespace-free tokens.
        let tokens = text.unicodeScalars.split(whereSeparator: { legacyWhitespace.contains($0.value) })
            .map { String(String.UnicodeScalarView($0)) }
        // Split(',') keeps empty fields; tokens with fewer than 6 fields are dropped.
        struct Line { let number: Int; let fields: [String]; let name: [UInt16] }
        var lines: [Line] = []
        for (index, token) in tokens.enumerated() {
            let fields = token.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 6 { lines.append(Line(number: index + 1, fields: fields, name: Array(fields[1].utf16))) }
        }
        // GroupBy(GetTrimmedName) runs over every line before the first group is
        // read, in UTF-16 indices: name[len-2] is read first, and name[len-3] only
        // when it is '_'. A name too short for those reads throws, and
        // ReadModifiers' catch then returns no modifiers for the whole card.
        let underscore = UInt16(UInt8(ascii: "_"))
        var order: [[UInt16]] = [], groups: [[UInt16]: [Line]] = [:]
        for line in lines {
            let name = line.name
            guard name.count >= 2, name.count >= 3 || name[0] != underscore else {
                return try dropped(text, line: line.number, assemblySHA256: assemblySHA256)
            }
            let key = name[name.count - 2] == underscore && name[name.count - 3] == underscore ? Array(name.dropLast(3)) : name
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(line)
        }
        guard order.count <= 10_000 else {
            throw RigError.invalid("ABMX boneData requires at most 10000 BoneModifier records.")
        }

        var modifiers: [Modifier] = [], diagnostics: [Diagnostic] = []
        var nonFinite: (line: Int, name: String, field: Int)?
        for key in order {
            // OrderBy(fields[1]), stable. The original's comparer is culture-
            // sensitive; ordinal UTF-16 order is used (they differ only for
            // suffix characters other than digits).
            let entries = groups[key]!.enumerated().sorted {
                $0.element.name.lexicographicallyPrecedes($1.element.name) ||
                    ($0.element.name == $1.element.name && $0.offset < $1.offset)
            }.map(\.element)
            let name = String(decoding: key, as: UTF16.self)
            // Fields 3, 4, 5 and then 6 parse in order; a failure skips the line.
            var kept: [(line: Int, values: Values)] = []
            for line in entries {
                var parsed: [Float] = []
                var failed: Int?
                for field in 3..<min(line.fields.count, 7) {
                    guard case .value(let number) = legacyNumber(line.fields[field]) else { failed = field; break }
                    parsed.append(number)
                }
                if let field = failed {
                    diagnostics.append(Diagnostic(code: "skipped-legacy-line", severity: "warning",
                        message: "ABMX legacy line \(line.number) for '\(name)' has an unparsable value in field \(field); it is skipped, as the original skips lines that fail to parse."))
                    continue
                }
                kept.append((line.number, Values(scaleModifier: Array(parsed[0..<3]), lengthModifier: parsed.count > 3 ? parsed[3] : 1,
                                                 positionModifier: [0, 0, 0], rotationModifier: [0, 0, 0])))
            }
            guard !kept.isEmpty else { continue }
            // new BoneModifier(key, ...) throws for an empty name; that also
            // reaches ReadModifiers' catch and drops every modifier.
            guard !key.isEmpty else { return try dropped(text, line: kept[0].line, assemblySHA256: assemblySHA256) }
            let parsedCount = kept.count
            if kept.count > 7 { kept.removeFirst(kept.count - 7) }
            if kept.count > 1 && kept.count < 7 { kept.removeFirst(kept.count - 1) }
            // Only the kept entries reach the character.
            for entry in kept where nonFinite == nil {
                let numbers = entry.values.scaleModifier + [entry.values.lengthModifier]
                if let index = numbers.firstIndex(where: { !$0.isFinite }) { nonFinite = (entry.line, name, index + 3) }
            }
            let values = kept.map(\.values)
            if values.count != parsedCount {
                diagnostics.append(Diagnostic(code: "legacy-coordinates-truncated", severity: "warning",
                    message: "ABMX legacy bone '\(name)' has \(parsedCount) parsed lines; the original keeps the last \(values.count)."))
            }
            guard name.unicodeScalars.count <= 1024, !name.contains("\0") else {
                throw RigError.invalid("ABMX BoneName must contain 1 through 1024 source characters and no NUL.")
            }
            modifiers.append(Modifier(boneName: name, boneLocation: 0, coordinateModifiers: values))
            if dynamicInfluencePrefixes.contains(where: { name.hasPrefix($0) }) {
                diagnostics.append(Diagnostic(code: "unsupported-dynamic-bone", severity: "warning",
                    message: "ABMX bone '\(name)' uses the source dynamic-baseline/gravity path; the native static evaluator rejects active modifiers on this target."))
            }
        }
        if let nonFinite {
            throw RigError.invalid("ABMX legacy line \(nonFinite.line) for '\(nonFinite.name)' has a non-finite or out-of-range value in field \(nonFinite.field); ABMX modifier values must be finite float32 numbers.")
        }
        return try legacyDocument(text: text, modifiers: modifiers, diagnostics: diagnostics, assemblySHA256: assemblySHA256)
    }

    enum LegacyNumber: Equatable { case value(Float), failure }

    /// `float.Parse` with the invariant culture and NumberStyles.Float |
    /// AllowThousands, on a token that has no whitespace or commas left: a
    /// decimal with an optional sign and exponent, or the symbols `Infinity`,
    /// `-Infinity` and `NaN`. The value is parsed as a double and rounded to
    /// float32, as Mono does. A value whose double is beyond float32 range
    /// (|x| > Float.greatestFiniteMagnitude, even when it would round to it)
    /// becomes infinite here, which the caller refuses (#403 decision 5).
    static func legacyNumber(_ text: String) -> LegacyNumber {
        switch text {
        case "Infinity": return .value(.infinity)
        case "-Infinity": return .value(-.infinity)
        case "NaN": return .value(.nan)
        default: break
        }
        var scalars = Array(text.utf8)[...]
        if let first = scalars.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") { scalars = scalars.dropFirst() }
        let digit = { (c: UInt8) in (48...57).contains(c) }
        let integer = scalars.prefix(while: digit); scalars = scalars.dropFirst(integer.count)
        var fraction = 0
        if scalars.first == UInt8(ascii: ".") {
            scalars = scalars.dropFirst(); fraction = scalars.prefix(while: digit).count; scalars = scalars.dropFirst(fraction)
        }
        guard integer.count + fraction > 0 else { return .failure }
        if let e = scalars.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            scalars = scalars.dropFirst()
            if let sign = scalars.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { scalars = scalars.dropFirst() }
            let exponent = scalars.prefix(while: digit).count
            guard exponent > 0 else { return .failure }
            scalars = scalars.dropFirst(exponent)
        }
        guard scalars.isEmpty, let double = Double(text) else { return .failure }
        guard abs(double) <= Double(Float.greatestFiniteMagnitude) else { return .value(double < 0 ? -.infinity : .infinity) }
        return .value(Float(double))
    }

    private static func dropped(_ text: String, line: Int, assemblySHA256: String) throws -> Self {
        try legacyDocument(text: text, modifiers: [], diagnostics: [Diagnostic(code: "legacy-data-dropped", severity: "warning",
            message: "ABMX legacy line \(line) has a bone name the original cannot read; the original drops all ABMX data for this card.")],
            assemblySHA256: assemblySHA256)
    }

    private static func legacyDocument(text: String, modifiers: [Modifier], diagnostics: [Diagnostic],
                                       assemblySHA256: String) throws -> Self {
        guard isHash(assemblySHA256) else {
            throw RigError.invalid("Supported ABMX versions are card v1, card v2 and coordinate v3 with valid assembly provenance.")
        }
        let result = Self(schemaVersion: 1, kind: "ikkoku-source-bone-modifiers",
                          coordinateSpace: "unity-left-handed-y-up", angleUnit: "degrees", mode: "staticBaseline",
                          source: Source(pluginGUID: "KKABMX.Core", dataGUID: "KKABMPlugin.ABMData", pluginVersion: "5.4",
                              dataKind: "card", dataVersion: 1, assemblySHA256: assemblySHA256,
                              payloadSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()),
                          modifiers: modifiers, diagnostics: diagnostics)
        try result.validate()
        return result
    }
}
