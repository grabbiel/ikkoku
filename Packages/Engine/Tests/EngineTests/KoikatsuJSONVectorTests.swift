import Foundation
import Testing
@testable import Studio

/// Scenes store each colour and UV vector as Unity JsonUtility
/// text. `KoikatsuBinaryReader.jsonVector` reads the form JsonUtility writes
/// directly (`unityJSONVector`) and gives every other form to
/// JSONSerialization (`serializedJSONVector`), the only reading before.
/// These tests hold the two to the same result: the same Float bits, or the
/// same error.
private enum Reading: Equatable {
    case vector(SIMD4<UInt32>), error(KoikatsuReadError), other(String)
    init(_ body: () throws -> SIMD4<Float>) {
        do {
            let v = try body()
            self = .vector(SIMD4(v.x.bitPattern, v.y.bitPattern, v.z.bitPattern, v.w.bitPattern))
        } catch let error as KoikatsuReadError { self = .error(error) } catch { self = .other("\(error)") }
    }
}

private let vectorNames = [["r", "g", "b", "a"], ["x", "y", "z", "w"]]

/// Compares both readings of `json` for both name sets; returns how many
/// took the direct reading.
@discardableResult
private func compareReadings(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) -> Int {
    var direct = 0
    for names in vectorNames {
        let new = Reading { try KoikatsuBinaryReader.jsonVector(json, names, offset: 7) }
        let old = Reading { try KoikatsuBinaryReader.serializedJSONVector(json, names, offset: 7) }
        #expect(new == old, "\(String(reflecting: json)) \(names): \(new) vs JSONSerialization \(old)", sourceLocation: sourceLocation)
        if let fast = KoikatsuBinaryReader.unityJSONVector(json, names) {
            direct += 1
            #expect(Reading { fast } == old, sourceLocation: sourceLocation)
        }
    }
    return direct
}

/// A deterministic generator, so a failure names a reproducible case.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func vector(_ names: [String], _ numbers: [String]) -> String {
    "{" + zip(names, numbers).map { "\"\($0)\":\($1)" }.joined(separator: ",") + "}"
}

@Test func unityJSONVectorNumbersReadAsJSONSerialization() {
    var random = SplitMix64(state: 0x5354_5430_3562)
    func digits(_ count: Int) -> String { String((0..<count).map { _ in Character(String(Int.random(in: 0...9, using: &random))) }) }
    var numbers = [
        "0", "1", "-1", "0.0", "1.0", "-1.0", "0.5", "-0", "-0.0", "-0.000", "00", "01", "-01", "1.", ".5", "+1", "1.0.0",
        "1e5", "1E5", "1e-5", "1E-05", "1.5e+3", "-2.5E-3", "1e400", "-1e400", "1e-400", "3.4028236e38", "340282360000000000000000000000000000000.0",
        "0.000000000000000000001", "123456789012345678", "1234567890123456789", "12345678901234567890", "-123456789012345678",
        "9007199254740993", "9007199254740993.0", "0.1", "0.2", "0.3", "0.30000001", "0.300000012", "0.3000000119",
        "1.00000005960464477539", "1.0000000596046448", "16777217", "16777217.0", "0.99999997", "1.17549435e-38", "NaN", "Infinity",
        "true", "false", "null", "\"1\"", "[1]", "{}", "", "1 ", " 1", "0x10", "١",
    ]
    // Unity writes each Float with up to 9 significant digits; Swift's
    // shortest form and other precisions round-trip other ways.
    for _ in 0..<4000 {
        var bits = UInt32.random(in: 0...UInt32.max, using: &random)
        if Bool.random(using: &random) { bits = (bits & 0x807F_FFFF) | (UInt32.random(in: 100...140, using: &random) << 23) }
        let float = Float(bitPattern: bits)
        guard float.isFinite else { continue }
        numbers += ["\(float)", String(format: "%.9g", Double(float)), String(format: "%.17g", Double(float)),
                    String(format: "%.6f", Double(float)), String(format: "%.3f", Double(float))]
    }
    for _ in 0..<4000 {
        let integer = Int.random(in: 0...3, using: &random), fraction = Int.random(in: 1...26, using: &random)
        let sign = Bool.random(using: &random) ? "-" : ""
        numbers.append(sign + (integer == 0 ? "0" : String(Int.random(in: 1...9, using: &random)) + digits(integer - 1)) + "." + digits(fraction))
        numbers.append(sign + String(Int.random(in: 1...9, using: &random)) + digits(Int.random(in: 0...20, using: &random)))
    }
    var direct = 0, cases = 0
    for (index, number) in numbers.enumerated() {
        for names in vectorNames {
            // The number in each position, the others plain.
            var parts = ["0.5", "1", "0.25", "1.0"]
            parts[index % 4] = number
            direct += compareReadings(vector(names, parts)); cases += 2
        }
    }
    print("[json-vector] \(numbers.count) numbers, \(cases) readings, \(direct) direct")
    // Half the readings use the other name set, which only JSONSerialization
    // reads (and refuses); of the rest, exponents and long numbers go there too.
    #expect(direct > cases / 4)
}

@Test func unityJSONVectorOtherFormsReadAsJSONSerialization() {
    let plain = #"{"r":0.5,"g":1,"b":0.25,"a":1.0}"#
    var forms = [
        plain, #"{"x":0.5,"y":1,"z":0.25,"w":1.0}"#,
        " " + plain, plain + " ", plain + "\n", #"{ "r":0.5,"g":1,"b":0.25,"a":1.0}"#, #"{"r" :0.5,"g":1,"b":0.25,"a":1.0}"#,
        #"{"r": 0.5,"g":1,"b":0.25,"a":1.0}"#, #"{"r":0.5 ,"g":1,"b":0.25,"a":1.0}"#, #"{"r":0.5, "g":1,"b":0.25,"a":1.0}"#,
        #"{"r":0.5,"g":1,"b":0.25,"a":1.0 }"#, "{\t\"r\":0.5,\"g\":1,\"b\":0.25,\"a\":1.0}", "\u{FEFF}" + plain,
        #"{"g":1,"r":0.5,"b":0.25,"a":1.0}"#, #"{"r":0.5,"g":1,"b":0.25}"#, #"{"r":0.5,"g":1,"b":0.25,"a":1.0,"e":2}"#,
        #"{"r":0.5,"g":1,"b":0.25,"a":1.0,"a":2}"#, #"{"r":0.5,"r":0.75,"g":1,"b":0.25,"a":1.0}"#, #"{"r":0.5,"g":1,"b":0.25,"a":1.0}"#,
        #"{"R":0.5,"g":1,"b":0.25,"a":1.0}"#, #"{"r":true,"g":1,"b":0.25,"a":1.0}"#, #"{"r":null,"g":1,"b":0.25,"a":1.0}"#,
        #"{"r":"0.5","g":1,"b":0.25,"a":1.0}"#, #"{"r":[0.5],"g":1,"b":0.25,"a":1.0}"#, #"{"r":{},"g":1,"b":0.25,"a":1.0}"#,
        #"{"r":0.5,"g":1,"b":0.25,"a":1.0}}"#, #"{"r":0.5,"g":1,"b":0.25,"a":1.0}x"#, #"{"r":0.5,"g":1,"b":0.25,"a":1.0"#,
        #"{"r":0.5,"g":1,"b":0.25,"a":}"#, #"{"r":0.5,"g":1,"b":0.25,"a"}"#, #"{"r":0.5,,"g":1,"b":0.25,"a":1.0}"#,
        #"{"r":0.5,"g":1,"b":0.25,"a":1.0,}"#, #"["r",0.5]"#, "{}", "", "null", "0.5", #"{"r":0.5;"g":1,"b":0.25,"a":1.0}"#,
        #"{'r':0.5,'g':1,'b':0.25,'a':1.0}"#, #"{r:0.5,g:1,b:0.25,a:1.0}"#, #"{"r":0.5,"g":1,"b":0.25,"a":1.0}{"#,
        #"{"r":-0,"g":-0.0,"b":0.25,"a":1.0}"#, #"{"r":1e2,"g":1,"b":0.25,"a":1.0}"#, #"{"r":0.5,"g":1,"b":0.25,"a":1.0}\u0000"#,
    ]
    // Each prefix of the plain form, and the plain form with one byte
    // changed to each of a few characters.
    forms += (0..<plain.utf8.count).map { String(decoding: plain.utf8.prefix($0), as: UTF8.self) }
    let bytes = Array(plain.utf8)
    for index in bytes.indices {
        for replacement in Array(" ,:{}\"-.0e1x".utf8) where bytes[index] != replacement {
            var changed = bytes; changed[index] = replacement
            forms.append(String(decoding: changed, as: UTF8.self))
        }
    }
    var direct = 0
    for form in forms { direct += compareReadings(form) }
    print("[json-vector] \(forms.count) other forms, \(direct) direct")
    #expect(direct >= 2)
}

/// The user's corpus (opt-in: IKKOKU_SCENE_CORPUS, read in place): every
/// vector string in every scene reads the same both ways. Strings are found
/// by their framing (a one-byte length, then `{"`, ending in `}`), so this
/// also covers vectors no record field reaches.
@Test(.enabled(if: !(ProcessInfo.processInfo.environment["IKKOKU_SCENE_CORPUS"] ?? "").isEmpty,
               "Opt-in corpus check: IKKOKU_SCENE_CORPUS names a folder of scenes"))
func unityJSONVectorReadsTheCorpusAsJSONSerialization() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IKKOKU_SCENE_CORPUS"]!)
    let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "png" && !$0.lastPathComponent.hasPrefix("._") }
    var scenes = 0, vectors = 0, direct = 0, differ = 0
    for url in files {
        let data = [UInt8](try Data(contentsOf: url))
        scenes += 1
        var p = 0
        while p + 3 < data.count {
            let length = Int(data[p])
            if length >= 2, length < 128, data[p + 1] == UInt8(ascii: "{"), data[p + 2] == UInt8(ascii: "\""),
               p + length < data.count, data[p + length] == UInt8(ascii: "}"),
               let json = String(bytes: data[(p + 1)...(p + length)], encoding: .utf8) {
                for names in vectorNames {
                    let old = Reading { try KoikatsuBinaryReader.serializedJSONVector(json, names, offset: 0) }
                    guard case .vector = old else { continue }
                    vectors += 1
                    if KoikatsuBinaryReader.unityJSONVector(json, names) != nil { direct += 1 }
                    if Reading({ try KoikatsuBinaryReader.jsonVector(json, names, offset: 0) }) != old { differ += 1 }
                }
            }
            p += 1
        }
    }
    print("[json-vector] corpus: \(scenes) scenes, \(vectors) vectors, \(direct) direct, \(differ) differ")
    #expect(scenes > 0 && vectors > 0 && differ == 0)
}
