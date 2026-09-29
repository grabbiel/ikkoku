import Foundation
import simd
import Assets

/// Decoded saved look-at data: the neck/eyes record payloads and the card
/// Status look fields. This is data extraction only; the per-frame gaze
/// solvers (NeckLookCalcVer2/EyeLookCalc evaluation) are a separate slice.
public enum SourceStudioLookData {
    /// Studio's AddObjectAssist.UpdateState order is ChangeLookEyesPtn ->
    /// eyes LoadAngle -> neck LoadNeckLookCtrl -> ChangeLookNeckPtn.
    /// ChangeLookNeckPtn runs last and overwrites the ptnNo that
    /// LoadNeckLookCtrl just restored from the saved neck bytes, so the card
    /// Status pattern wins whenever it is present.
    public static func effectiveNeckPattern(status: SourceStudioLookStatus, savedNeckPatternNumber: Int32) -> Int32 {
        status.neckLookPtn ?? savedNeckPatternNumber
    }

    /// EyeLookCalc.LoadAngle reads the four angle floats only when the scene
    /// data version is at least 0.0.8; short versions are padded with zeros.
    static func readsSavedEyeAngles(sceneVersion: String) throws -> Bool {
        let parts = sceneVersion.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        guard !parts.isEmpty, parts.count <= 4 else {
            throw KoikatsuReadError.invalidValue(offset: 0, description: "unparsable scene data version '\(sceneVersion)'")
        }
        for part in parts {
            guard let number = Int(part) else {
                throw KoikatsuReadError.invalidValue(offset: 0, description: "unparsable scene data version '\(sceneVersion)'")
            }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        return numbers[0] > 0 || numbers[1] > 0 || numbers[2] >= 8
    }
}

/// Payload of NeckLookControllerVer2.SaveNeckLookCtrl: Int32 ptnNo, Int32
/// count, then count x (x, y, z, w) floats. The quaternions keep the Unity
/// source component order (x, y, z, w) exactly as saved, matching
/// simd_quatf's own layout; no coordinate translation is applied.
public struct SourceStudioNeckLookData: Sendable, Equatable {
    public let patternNumber: Int32
    /// One aBones[i].fixAngle per saved bone, in saved order.
    public let fixAngles: [simd_quatf]

    public init(bytes: Data) throws {
        var reader = try KoikatsuBinaryReader(bytes)
        patternNumber = try reader.int32()
        let count = try reader.count()
        var angles: [simd_quatf] = []
        for _ in 0..<count { angles.append(try SourceStudioLookQuaternion.read(&reader)) }
        guard reader.offset == bytes.count else { throw reader.invalid("trailing neck look bytes") }
        fixAngles = angles
    }
}

/// Payload of EyeLookCalc.SaveAngle: fixAngle[0] (x, y, z, w), fixAngle[1]
/// (x, y, z, w) in Unity source component order, then angleH[0], angleH[1],
/// angleV[0], angleV[1]. The four angle floats exist only from scene data
/// version 0.0.8 on; before that they stay nil like the source reader skips
/// them.
public struct SourceStudioEyeLookData: Sendable, Equatable {
    public let fixAngles: [simd_quatf]
    public let angleH: [Float]?
    public let angleV: [Float]?

    public init(bytes: Data, sceneVersion: String) throws {
        let readsAngles = try SourceStudioLookData.readsSavedEyeAngles(sceneVersion: sceneVersion)
        var reader = try KoikatsuBinaryReader(bytes)
        fixAngles = [try SourceStudioLookQuaternion.read(&reader), try SourceStudioLookQuaternion.read(&reader)]
        if readsAngles {
            angleH = [try reader.float(), try reader.float()]
            angleV = [try reader.float(), try reader.float()]
        } else {
            angleH = nil
            angleV = nil
        }
        guard reader.offset == bytes.count else { throw reader.invalid("trailing eye look bytes") }
    }
}

/// ChaFileStatus look fields as the Studio card loader reads them. A missing
/// field stays nil instead of inventing a card default; a wrong type is
/// reported and also stays nil.
public struct SourceStudioLookStatus: Sendable, Equatable {
    public let eyesLookPtn: Int32?
    public let neckLookPtn: Int32?
    public let eyesTargetType: Int32?
    public let neckTargetType: Int32?
    public let eyesTargetRate: Float?
    public let neckTargetRate: Float?
    public let eyesTargetAngle: Float?
    public let neckTargetAngle: Float?
    public let eyesTargetRange: Float?
    public let neckTargetRange: Float?
    public let diagnostics: [String]

    public init(status: [String: SourceMessagePackValue]) {
        var diagnostics: [String] = []
        eyesLookPtn = Self.integer("eyesLookPtn", status, &diagnostics)
        neckLookPtn = Self.integer("neckLookPtn", status, &diagnostics)
        eyesTargetType = Self.integer("eyesTargetType", status, &diagnostics)
        neckTargetType = Self.integer("neckTargetType", status, &diagnostics)
        eyesTargetRate = Self.float("eyesTargetRate", status, &diagnostics)
        neckTargetRate = Self.float("neckTargetRate", status, &diagnostics)
        eyesTargetAngle = Self.float("eyesTargetAngle", status, &diagnostics)
        neckTargetAngle = Self.float("neckTargetAngle", status, &diagnostics)
        eyesTargetRange = Self.float("eyesTargetRange", status, &diagnostics)
        neckTargetRange = Self.float("neckTargetRange", status, &diagnostics)
        self.diagnostics = diagnostics
    }

    private static func integer(_ key: String, _ status: [String: SourceMessagePackValue],
                                _ diagnostics: inout [String]) -> Int32? {
        guard let value = status[key] else { return nil }
        guard let wide = value.integerValue, let saved = Int32(exactly: wide) else {
            diagnostics.append("Saved Studio Status \(key) is not a saved integer; it is left unread instead of a guessed default.")
            return nil
        }
        return saved
    }

    private static func float(_ key: String, _ status: [String: SourceMessagePackValue],
                              _ diagnostics: inout [String]) -> Float? {
        guard let value = status[key] else { return nil }
        // The source field is a System.Single; a MessagePack double narrows
        // back to it exactly for values a Single writer produced.
        if case .float(let saved) = value, saved.isFinite { return Float(saved) }
        if let wide = value.integerValue, let exact = Float(exactly: wide) { return exact }
        diagnostics.append("Saved Studio Status \(key) is not a finite saved number; it is left unread instead of a guessed default.")
        return nil
    }
}

enum SourceStudioLookQuaternion {
    /// Reads one Unity-ordered (x, y, z, w) quaternion; the reader rejects
    /// non-finite components.
    static func read(_ reader: inout KoikatsuBinaryReader) throws -> simd_quatf {
        // simd_quatf's SIMD4 layout is (ix, iy, iz, r), which matches the
        // saved Unity (x, y, z, w) order component-for-component.
        simd_quatf(vector: SIMD4(try reader.float(), try reader.float(), try reader.float(), try reader.float()))
    }
}
