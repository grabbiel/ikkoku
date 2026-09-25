import Foundation
import Character

/// Raw Unity values recovered from CharaStudio's `Studio.ChangeAmount` stream.
/// Convert the coordinate basis and Unity Euler order before rendering these values.
public struct KoikatsuChangeAmount: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let rotationDegrees: SIMD3<Float>
    public let scale: SIMD3<Float>
}

public enum KoikatsuObjectKind: Int32, Sendable {
    case character = 0, item = 1, light = 2, folder = 3, route = 4, camera = 5
}

public struct KoikatsuPatternRecord: Sendable, Equatable {
    public let key: Int32
    public let filePath: String
    public let clamp: Bool
    public let uv: SIMD4<Float>
    public let rotation: Float
}

public struct KoikatsuBoneRecord: Sendable, Equatable {
    public let sourceKey: Int32
    public let transform: KoikatsuChangeAmount
}

public struct KoikatsuItemRecord: Sendable, Equatable {
    public let group: Int32
    public let category: Int32
    public let no: Int32
    public let animationSpeed: Float
    public let colors: [SIMD4<Float>]
    public let patterns: [KoikatsuPatternRecord]
    public let alpha: Float
    public let lineColor: SIMD4<Float>
    public let lineWidth: Float
    public let emissionColor: SIMD4<Float>
    public let emissionPower: Float
    public let lightCancel: Float
    public let panel: KoikatsuPatternRecord
    public let enableFK: Bool
    public let bones: [String: KoikatsuBoneRecord]
    public let enableDynamicBone: Bool
    public let animationNormalizedTime: Float
}

public struct KoikatsuLightRecord: Sendable, Equatable {
    /// A source catalog identifier, not Unity's LightType enum.
    public let no: Int32
    public let color: SIMD4<Float>
    public let intensity: Float
    public let range: Float
    public let spotAngle: Float
    public let shadow: Bool
    public let enable: Bool
    public let drawTarget: Bool
}

/// Immutable reference nodes keep recursive decoding frames small even when a
/// record contains the complete character state. Identity remains sourceKey.
public final class KoikatsuObjectRecord: Sendable, Equatable {
    public let kind: KoikatsuObjectKind
    /// Only root records have the dictionary key preceding their object record.
    public let rootDictionaryKey: Int32?
    public let sourceKey: Int32
    public let transform: KoikatsuChangeAmount
    public let treeState: Int32
    public let visible: Bool
    public let name: String?
    public let cameraActive: Bool?
    public let item: KoikatsuItemRecord?
    public let light: KoikatsuLightRecord?
    public let children: [KoikatsuObjectRecord]
    public let character: KoikatsuCharacterRecord?
    public let route: KoikatsuRouteRecord?

    init(kind: KoikatsuObjectKind, rootDictionaryKey: Int32?, sourceKey: Int32,
         transform: KoikatsuChangeAmount, treeState: Int32, visible: Bool, name: String?, cameraActive: Bool?,
         item: KoikatsuItemRecord?, light: KoikatsuLightRecord?, children: [KoikatsuObjectRecord],
         character: KoikatsuCharacterRecord? = nil, route: KoikatsuRouteRecord? = nil) {
        self.kind = kind; self.rootDictionaryKey = rootDictionaryKey; self.sourceKey = sourceKey
        self.transform = transform; self.treeState = treeState; self.visible = visible; self.name = name
        self.cameraActive = cameraActive; self.item = item; self.light = light; self.children = children
        self.character = character; self.route = route
    }

    public static func == (lhs: KoikatsuObjectRecord, rhs: KoikatsuObjectRecord) -> Bool {
        lhs === rhs || (lhs.kind == rhs.kind && lhs.rootDictionaryKey == rhs.rootDictionaryKey
            && lhs.sourceKey == rhs.sourceKey && lhs.transform == rhs.transform && lhs.treeState == rhs.treeState
            && lhs.visible == rhs.visible && lhs.name == rhs.name && lhs.cameraActive == rhs.cameraActive
            && lhs.item == rhs.item && lhs.light == rhs.light && lhs.children == rhs.children
            && lhs.character == rhs.character && lhs.route == rhs.route)
    }
}

/// An object-section snapshot, not a complete interpretation of the scene file.
/// Scene effects, camera slots, map, sound, and plugin trailers remain after the offset.
public struct KoikatsuSceneSnapshot: Sendable, Equatable {
    public let version: String
    public let roots: [KoikatsuObjectRecord]
    public let objectSectionEndOffset: Int
}

public struct KoikatsuCameraRecord: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let rotationDegrees: SIMD3<Float>
    public let distance: SIMD3<Float>
    public let fieldOfView: Float
}

public enum KoikatsuReadError: Error, LocalizedError, Sendable, Equatable {
    case invalidPNG
    case truncated(offset: Int, expectedBytes: Int)
    case invalidValue(offset: Int, description: String)
    case unsupportedVersion(String)
    case unsupportedObjectKind(Int32)
    case limitExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPNG: return "The file has no valid PNG container."
        case let .truncated(offset, count): return "CharaStudio data is truncated at byte \(offset) (needs \(count) bytes)."
        case let .invalidValue(offset, description): return "Invalid CharaStudio data at byte \(offset): \(description)."
        case let .unsupportedVersion(version): return "CharaStudio data version \(version) is not supported; this reader supports 1.0.4.2 scenes and version 2 camera records."
        case let .unsupportedObjectKind(kind): return "CharaStudio object kind \(kind) is not supported; records cannot be safely skipped."
        case let .limitExceeded(description): return "CharaStudio import limit exceeded: \(description)."
        }
    }
}

/// Read-only interoperability with the observed CharaStudio 1.0.4.2 writer.
/// Records are variable-length; unknown kinds fail rather than attempting unsafe skipping.
public enum KoikatsuSceneReader {
    public static func decode(_ data: Data) throws -> KoikatsuSceneSnapshot {
        var reader = try KoikatsuBinaryReader(data)
        try reader.skipPNG()
        let version = try reader.string()
        guard version == "1.0.4.2" else { throw KoikatsuReadError.unsupportedVersion(version) }
        let count = try reader.count()
        var roots: [KoikatsuObjectRecord] = []
        var rootKeys = Set<Int32>()
        for _ in 0..<count {
            let key = try reader.int32()
            guard rootKeys.insert(key).inserted else { throw reader.invalid("duplicate root dictionary key") }
            roots.append(try reader.object(depth: 0, rootKey: key))
        }
        return KoikatsuSceneSnapshot(version: version, roots: roots, objectSectionEndOffset: reader.offset)
    }

    /// Decode an isolated 36-byte ChangeAmount. Input must contain exactly this record.
    public static func decodeChangeAmount(_ data: Data) throws -> KoikatsuChangeAmount {
        var reader = try KoikatsuBinaryReader(data)
        let result = try reader.changeAmount()
        try reader.requireEnd()
        return result
    }

    /// Decode an isolated CameraData version 2 record (44 bytes).
    /// The three-component distance vector and roll are deliberately preserved.
    public static func decodeCamera(_ data: Data) throws -> KoikatsuCameraRecord {
        var reader = try KoikatsuBinaryReader(data)
        let version = try reader.int32()
        guard version == 2 else { throw KoikatsuReadError.unsupportedVersion("camera:\(version)") }
        let camera = KoikatsuCameraRecord(position: try reader.vector3(), rotationDegrees: try reader.vector3(),
                                         distance: try reader.vector3(), fieldOfView: try reader.float())
        try reader.requireEnd()
        return camera
    }
}

struct KoikatsuBinaryReader {
    let data: Data
    var offset = 0
    var objectCount = 0
    var sourceKeys = Set<Int32>()
    static let maximumCount = 100_000
    static let maximumStringBytes = 1_048_576

    init(_ data: Data) throws {
        guard data.count <= 256 * 1_048_576 else { throw KoikatsuReadError.limitExceeded("file size exceeds 256 MiB") }
        self.data = data
    }

    func invalid(_ description: String) -> KoikatsuReadError { .invalidValue(offset: offset, description: description) }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw KoikatsuReadError.truncated(offset: offset, expectedBytes: count) }
        defer { offset += count }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + count))
    }

    mutating func byte() throws -> UInt8 { try take(1).first! }
    mutating func uint32() throws -> UInt32 {
        let bytes = Array(try take(4))
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }
    mutating func float() throws -> Float {
        let value = Float(bitPattern: try uint32())
        guard value.isFinite else { throw invalid("nonfinite floating-point value") }
        return value
    }
    mutating func bool() throws -> Bool {
        let value = try byte()
        guard value < 2 else { throw invalid("boolean must be 0 or 1") }
        return value == 1
    }
    mutating func count() throws -> Int {
        let count = try int32()
        guard count >= 0 else { throw invalid("negative collection count") }
        guard count <= Self.maximumCount else { throw KoikatsuReadError.limitExceeded("collection exceeds \(Self.maximumCount) records") }
        return Int(count)
    }
    mutating func byteCount(maximum: Int = 64 * 1024 * 1024) throws -> Int {
        let value = try int32()
        guard value >= 0, value <= maximum else { throw invalid("invalid or oversized byte count") }
        return Int(value)
    }
    mutating func uint64() throws -> UInt64 { let low = try uint32(); return UInt64(low) | UInt64(try uint32()) << 32 }
    mutating func vector3() throws -> SIMD3<Float> { SIMD3(try float(), try float(), try float()) }
    mutating func vector4() throws -> SIMD4<Float> { SIMD4(try float(), try float(), try float(), try float()) }
    mutating func changeAmount() throws -> KoikatsuChangeAmount {
        KoikatsuChangeAmount(position: try vector3(), rotationDegrees: try vector3(), scale: try vector3())
    }
    mutating func string() throws -> String {
        // BinaryWriter.Write(string): seven-bit encoded UTF-8 byte length, not character count.
        var length: UInt32 = 0
        for index in 0..<5 {
            let value = try byte()
            if index == 4 && value > 7 { throw invalid("invalid .NET string length") }
            length |= UInt32(value & 0x7f) << (index * 7)
            if value & 0x80 == 0 {
                guard length <= Self.maximumStringBytes else { throw KoikatsuReadError.limitExceeded("string exceeds 1 MiB") }
                guard let string = String(data: try take(Int(length)), encoding: .utf8) else { throw invalid("invalid UTF-8") }
                return string
            }
        }
        throw invalid("unterminated .NET string length")
    }

    mutating func skipPNG() throws {
        guard try take(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw KoikatsuReadError.invalidPNG }
        var first = true
        while offset < data.count {
            let lengthBytes = Array(try take(4))
            let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let type = try take(4)
            if first {
                guard type == Data("IHDR".utf8), length == 13 else { throw KoikatsuReadError.invalidPNG }
                first = false
            }
            guard Int(length) <= data.count - offset - 4 else { throw KoikatsuReadError.invalidPNG }
            offset += Int(length) + 4 // Skip payload and CRC. Image decoding belongs to ImageIO.
            if type == Data("IEND".utf8) {
                guard length == 0 else { throw KoikatsuReadError.invalidPNG }
                return
            }
        }
        throw KoikatsuReadError.invalidPNG
    }

    mutating func jsonVector(_ names: [String]) throws -> SIMD4<Float> {
        let json = try string()
        guard let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw invalid("invalid vector JSON") }
        var values: [Float] = []
        for name in names {
            guard let number = object[name] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.floatValue.isFinite else {
                throw invalid("missing or invalid JSON component \(name)")
            }
            values.append(number.floatValue)
        }
        return SIMD4(values[0], values[1], values[2], values[3])
    }

    mutating func pattern() throws -> KoikatsuPatternRecord {
        KoikatsuPatternRecord(key: try int32(), filePath: try string(), clamp: try bool(),
                              uv: try jsonVector(["x", "y", "z", "w"]), rotation: try float())
    }

    mutating func item() throws -> KoikatsuItemRecord {
        let group = try int32(), category = try int32(), no = try int32(), speed = try float()
        var colors: [SIMD4<Float>] = [], patterns: [KoikatsuPatternRecord] = []
        for _ in 0..<8 { colors.append(try jsonVector(["r", "g", "b", "a"])) }
        for _ in 0..<3 { patterns.append(try pattern()) }
        let alpha = try float(), lineColor = try jsonVector(["r", "g", "b", "a"]), lineWidth = try float()
        let emissionColor = try jsonVector(["r", "g", "b", "a"]), emissionPower = try float(), lightCancel = try float()
        let panel = try pattern(), enableFK = try bool(), boneCount = try count()
        var bones: [String: KoikatsuBoneRecord] = [:]
        for _ in 0..<boneCount {
            let name = try string()
            guard bones[name] == nil else { throw invalid("duplicate bone name") }
            bones[name] = KoikatsuBoneRecord(sourceKey: try int32(), transform: try changeAmount())
        }
        return KoikatsuItemRecord(group: group, category: category, no: no, animationSpeed: speed,
                                 colors: colors, patterns: patterns, alpha: alpha, lineColor: lineColor,
                                 lineWidth: lineWidth, emissionColor: emissionColor, emissionPower: emissionPower,
                                 lightCancel: lightCancel, panel: panel, enableFK: enableFK, bones: bones,
                                 enableDynamicBone: try bool(), animationNormalizedTime: try float())
    }

    mutating func object(depth: Int, rootKey: Int32?) throws -> KoikatsuObjectRecord {
        guard depth <= 64 else { throw KoikatsuReadError.limitExceeded("hierarchy depth exceeds 64") }
        objectCount += 1
        guard objectCount <= Self.maximumCount else { throw KoikatsuReadError.limitExceeded("scene exceeds \(Self.maximumCount) objects") }
        let rawKind = try int32()
        guard let kind = KoikatsuObjectKind(rawValue: rawKind) else { throw KoikatsuReadError.unsupportedObjectKind(rawKind) }
        let key = try int32()
        guard sourceKeys.insert(key).inserted else { throw invalid("duplicate object key") }
        let transform = try changeAmount(), treeState = try int32(), visible = try bool()
        var name: String?, active: Bool?, itemRecord: KoikatsuItemRecord?, lightRecord: KoikatsuLightRecord?
        var children: [KoikatsuObjectRecord] = []
        var characterRecord: KoikatsuCharacterRecord?, routeRecord: KoikatsuRouteRecord?
        switch kind {
        case .folder: name = try string()
        case .camera: name = try string(); active = try bool()
        case .character: characterRecord = try character(depth: depth)
        case .route:
            name = try string()
            for _ in 0..<(try count()) { children.append(try object(depth: depth + 1, rootKey: nil)) }
            routeRecord = try route()
        case .item: itemRecord = try item()
        case .light:
            lightRecord = KoikatsuLightRecord(no: try int32(), color: try vector4(), intensity: try float(),
                                               range: try float(), spotAngle: try float(), shadow: try bool(),
                                               enable: try bool(), drawTarget: try bool())
        }
        if kind == .folder || kind == .item {
            let count = try count()
            for _ in 0..<count { children.append(try object(depth: depth + 1, rootKey: nil)) }
        }
        return KoikatsuObjectRecord(kind: kind, rootDictionaryKey: rootKey, sourceKey: key,
                                    transform: transform, treeState: treeState, visible: visible,
                                    name: name, cameraActive: active, item: itemRecord, light: lightRecord, children: children,
                                    character: characterRecord, route: routeRecord)
    }

    func requireEnd() throws {
        guard offset == data.count else { throw invalid("unexpected trailing bytes in isolated record") }
    }
}
