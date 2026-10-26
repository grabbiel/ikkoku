import Foundation
import Character

/// Raw Unity values recovered from CharaStudio's `Studio.ChangeAmount` stream.
/// Convert the coordinate basis and Unity Euler order before rendering these values.
public struct KoikatsuChangeAmount: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let rotationDegrees: SIMD3<Float>
    public let scale: SIMD3<Float>
    public init(position: SIMD3<Float>, rotationDegrees: SIMD3<Float>, scale: SIMD3<Float>) {
        self.position = position; self.rotationDegrees = rotationDegrees; self.scale = scale
    }
}

public enum KoikatsuObjectKind: Int32, Sendable, Codable {
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
    public init(position: SIMD3<Float>, rotationDegrees: SIMD3<Float>, distance: SIMD3<Float>, fieldOfView: Float) {
        self.position = position; self.rotationDegrees = rotationDegrees; self.distance = distance; self.fieldOfView = fieldOfView
    }
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
        case let .unsupportedVersion(version):
            if version.hasPrefix("camera:") {
                return "CharaStudio camera data version \(version.dropFirst(7)) is not supported; this reader supports camera records of versions 2 and, in scenes older than 1.0.4.2, 1."
            }
            let reason = KoikatsuSceneVersion.refusal(version) ?? "it is not supported"
            return "CharaStudio scene data version \(version) is not read: \(reason). This reader reads scene versions \(KoikatsuSceneVersion.oldestSupported) through \(KoikatsuSceneVersion.current) with CharaStudio 1.0.4.2's load rules."
        case let .unsupportedObjectKind(kind): return "CharaStudio object kind \(kind) is not supported; records cannot be safely skipped."
        case let .limitExceeded(description): return "CharaStudio import limit exceeded: \(description)."
        }
    }
}

/// Read-only interoperability with the observed CharaStudio 1.0.4.2 writer
/// and, through its load branches, the scene versions 0.0.5 through 1.0.4.1
/// it still loads (KoikatsuLegacyScenes.swift). Records are variable-length;
/// unknown kinds fail rather than attempting unsafe skipping.
public enum KoikatsuSceneReader {
    public static func decode(_ data: Data) throws -> KoikatsuSceneSnapshot {
        var reader = try KoikatsuBinaryReader(data)
        return try reader.snapshot()
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
    var editSpans = SourceSceneEditSpans()
    /// The offset of the `dicKey` Int32 the last `bone()` read.
    var lastBoneKeyOffset = 0
    static let maximumCount = 100_000
    static let maximumStringBytes = 1_048_576

    init(_ data: Data) throws {
        guard data.count <= 256 * 1_048_576 else { throw KoikatsuReadError.limitExceeded("file size exceeds 256 MiB") }
        self.data = data
    }

    /// The load branches of the scene being read (`sceneVersion()`).
    var layout = KoikatsuSceneLayout.current
    /// A legacy scene's 1.0.4.2 upgrade, in byte order, and why it cannot
    /// be written (`KoikatsuSceneDocument.upgraded`). Empty for 1.0.4.2.
    var upgrade: [KoikatsuSceneUpgradePatch] = []
    var upgradeRefusals: [String] = []

    func invalid(_ description: String) -> KoikatsuReadError { .invalidValue(offset: offset, description: description) }

    /// The PNG, the version and the object section (`SceneInfo.Load` up to
    /// the map settings).
    mutating func snapshot() throws -> KoikatsuSceneSnapshot {
        try skipPNG()
        let version = try sceneVersion()
        let count = try self.count()
        var roots: [KoikatsuObjectRecord] = []
        var rootKeys = Set<Int32>()
        for _ in 0..<count {
            let key = try int32()
            guard rootKeys.insert(key).inserted else { throw invalid("duplicate root dictionary key") }
            roots.append(try object(depth: 0, rootKey: key))
        }
        return KoikatsuSceneSnapshot(version: version, roots: roots, objectSectionEndOffset: offset)
    }

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
    static func dotNetString(_ value: String) throws -> Data {
        let bytes = Data(value.utf8)
        guard bytes.count <= maximumStringBytes else { throw KoikatsuReadError.limitExceeded("string exceeds 1 MiB") }
        var length = bytes.count, encoded = Data()
        while length >= 128 { encoded.append(UInt8(length & 127) | 128); length >>= 7 }
        encoded.append(UInt8(length)); encoded.append(bytes)
        return encoded
    }
    /// Folder, camera and route name: the full span (seven-bit length prefix plus
    /// UTF-8 bytes) is recorded so a rename can replace it even when it resizes.
    mutating func nameString(objectKey: Int32) throws -> String {
        let start = offset
        let value = try string()
        editSpans.names[objectKey] = start..<offset
        return value
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
        let start = offset
        return try Self.jsonVector(try string(), names, offset: start)
    }
    static func jsonVector(_ json: String, _ names: [String], offset: Int) throws -> SIMD4<Float> {
        if let vector = unityJSONVector(json, names) { return vector }
        return try serializedJSONVector(json, names, offset: offset)
    }
    /// The JSONSerialization reading every vector took before
    /// `unityJSONVector`, and the one any vector it does not take still gets.
    static func serializedJSONVector(_ json: String, _ names: [String], offset: Int) throws -> SIMD4<Float> {
        guard let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw KoikatsuReadError.invalidValue(offset: offset, description: "invalid vector JSON")
        }
        var values: [Float] = []
        for name in names {
            guard let number = object[name] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.floatValue.isFinite else {
                throw KoikatsuReadError.invalidValue(offset: offset, description: "missing or invalid JSON component \(name)")
            }
            values.append(number.floatValue)
        }
        return SIMD4(values[0], values[1], values[2], values[3])
    }
    /// Unity's JsonUtility writes a colour or a vector as
    /// `{"r":0.5,"g":1,"b":0.25,"a":1}`: the four names in order, no
    /// whitespace, plain numbers. JSONSerialization took about 3 µs per
    /// vector, 14 per item. This reads that form directly, to the value
    /// JSONSerialization gives it: a number with a fraction is the nearest
    /// Double (Swift's `Double(_:)`, correctly rounded like `strtod`), an
    /// integer is an Int64, and `NSNumber.floatValue` rounds either to Float.
    /// Any other form returns nil and takes `serializedJSONVector`, so it
    /// reads, or fails, exactly as before: other spacing, order or names,
    /// exponents, a negative zero, a number longer than 24 characters, and
    /// malformed input. `KoikatsuJSONVectorTests` fuzzes the two readings
    /// against each other.
    static func unityJSONVector(_ json: String, _ names: [String]) -> SIMD4<Float>? {
        guard names.count == 4 else { return nil }
        var json = json
        return json.withUTF8 { bytes -> SIMD4<Float>? in
            let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")
            var i = 0, values = SIMD4<Float>()
            func take(_ byte: UInt8) -> Bool {
                guard i < bytes.count, bytes[i] == byte else { return false }
                i += 1; return true
            }
            func digits() -> Int {
                let start = i
                while i < bytes.count, bytes[i] >= zero, bytes[i] <= nine { i += 1 }
                return i - start
            }
            guard take(UInt8(ascii: "{")) else { return nil }
            for (index, name) in names.enumerated() {
                guard index == 0 || take(UInt8(ascii: ",")), take(UInt8(ascii: "\"")) else { return nil }
                for byte in name.utf8 { guard take(byte) else { return nil } }
                guard take(UInt8(ascii: "\"")), take(UInt8(ascii: ":")) else { return nil }
                // A JSON number without an exponent: -?(0|[1-9][0-9]*)(\.[0-9]+)?
                let start = i, negative = take(UInt8(ascii: "-")), integerStart = i, integerDigits = digits()
                guard integerDigits > 0, integerDigits == 1 || bytes[integerStart] != zero else { return nil }
                var fractionDigits = 0
                if take(UInt8(ascii: ".")) {
                    fractionDigits = digits()
                    guard fractionDigits > 0 else { return nil }
                }
                guard i - start <= 24 else { return nil }
                let value: Float
                if fractionDigits == 0 {
                    // An integer NSNumber; JSONSerialization reads "-0" as 0.
                    guard integerDigits <= 18, !(negative && integerDigits == 1 && bytes[integerStart] == zero) else { return nil }
                    var integer: Int64 = 0
                    for index in integerStart..<i { integer = integer * 10 + Int64(bytes[index] - zero) }
                    value = Float(negative ? -integer : integer)
                } else {
                    guard let double = Double(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)),
                          double != 0 || !negative else { return nil }
                    value = Float(double)
                }
                guard value.isFinite else { return nil }
                values[index] = value
            }
            guard take(UInt8(ascii: "}")), i == bytes.count else { return nil }
            return values
        }
    }

    mutating func pattern() throws -> KoikatsuPatternRecord {
        KoikatsuPatternRecord(key: try int32(), filePath: try string(), clamp: try bool(),
                              uv: try jsonVector(["x", "y", "z", "w"]), rotation: try float())
    }

    mutating func item(objectKey: Int32) throws -> KoikatsuItemRecord {
        let group = try int32(), category = try int32(), no = try int32(), speed = try float()
        var colors: [SIMD4<Float>] = [], patterns: [KoikatsuPatternRecord] = []
        for _ in 0..<8 { colors.append(try jsonVector(["r", "g", "b", "a"])) }
        for _ in 0..<3 { patterns.append(try pattern()) }
        let alpha = try float(), lineColor = try jsonVector(["r", "g", "b", "a"]), lineWidth = try float()
        // OIItemInfo.Load: a version without emission (0.0.7, :150) or the
        // panel (0.0.6, :156) keeps the constructor's values (:67, :73).
        let emissionColor: SIMD4<Float>, emissionPower: Float, lightCancel: Float, panel: KoikatsuPatternRecord
        if layout.itemEmission {
            emissionColor = try jsonVector(["r", "g", "b", "a"]); emissionPower = try float(); lightCancel = try float()
        } else {
            emissionColor = KoikatsuLegacyDefaults.white; emissionPower = 0; lightCancel = 0
            upgradeInsert(KoikatsuLegacyDefaults.string(KoikatsuLegacyDefaults.whiteJSON) + KoikatsuLegacyDefaults.float(0) + KoikatsuLegacyDefaults.float(0))
        }
        if layout.itemPanel { panel = try pattern() } else {
            panel = KoikatsuLegacyDefaults.pattern; upgradeInsert(KoikatsuLegacyDefaults.patternBytes())
        }
        let enableFK = try bool(), boneCount = try count()
        var bones: [String: KoikatsuBoneRecord] = [:], subKeys: [Int] = []
        for _ in 0..<boneCount {
            let name = try string()
            guard bones[name] == nil else { throw invalid("duplicate bone name") }
            bones[name] = try bone(destination: .itemFK(object: objectKey, bone: name))
            subKeys.append(lastBoneKeyOffset)
        }
        // OIItemInfo.Load allocates the FK bones before the child list.
        editSpans.topology.subKeys[objectKey] = .init(before: subKeys, after: [])
        // Before 1.0.1 (:168) enableDynamicBone keeps its initializer, true (:34).
        let dynamicBone: Bool
        if layout.itemDynamicBone { dynamicBone = try bool() } else { dynamicBone = true; upgradeInsert(Data([1])) }
        return KoikatsuItemRecord(group: group, category: category, no: no, animationSpeed: speed,
                                 colors: colors, patterns: patterns, alpha: alpha, lineColor: lineColor,
                                 lineWidth: lineWidth, emissionColor: emissionColor, emissionPower: emissionPower,
                                 lightCancel: lightCancel, panel: panel, enableFK: enableFK, bones: bones,
                                 enableDynamicBone: dynamicBone, animationNormalizedTime: try float())
    }

    mutating func object(depth: Int, rootKey: Int32?) throws -> KoikatsuObjectRecord {
        guard depth <= 64 else { throw KoikatsuReadError.limitExceeded("hierarchy depth exceeds 64") }
        objectCount += 1
        guard objectCount <= Self.maximumCount else { throw KoikatsuReadError.limitExceeded("scene exceeds \(Self.maximumCount) objects") }
        let recordStart = offset, rawKind = try int32()
        guard let kind = KoikatsuObjectKind(rawValue: rawKind) else { throw KoikatsuReadError.unsupportedObjectKind(rawKind) }
        let key = try int32()
        guard sourceKeys.insert(key).inserted else { throw invalid("duplicate object key") }
        let transformStart = offset, transform = try changeAmount()
        editSpans.transforms[.object(key)] = transformStart..<offset
        let treeState = try int32()
        let visibleStart = offset, visible = try bool()
        editSpans.visibility[key] = visibleStart..<offset
        var name: String?, active: Bool?, itemRecord: KoikatsuItemRecord?, lightRecord: KoikatsuLightRecord?
        var children: [KoikatsuObjectRecord] = []
        var characterRecord: KoikatsuCharacterRecord?, routeRecord: KoikatsuRouteRecord?
        switch kind {
        case .folder: name = try nameString(objectKey: key)
        case .camera:
            name = try nameString(objectKey: key)
            let activeStart = offset; active = try bool(); editSpans.cameraActive[key] = activeStart..<offset
        case .character: characterRecord = try character(depth: depth, objectKey: key)
        case .route:
            name = try nameString(objectKey: key)
            let countStart = offset
            for _ in 0..<(try count()) { children.append(try object(depth: depth + 1, rootKey: nil)) }
            editSpans.topology.slots[key] = [.init(count: countStart, end: offset, children: children.map(\.sourceKey), point: nil)]
            routeRecord = try route(objectKey: key)
        case .item: itemRecord = try item(objectKey: key)
        case .light:
            lightRecord = KoikatsuLightRecord(no: try int32(), color: try vector4(), intensity: try float(),
                                               range: try float(), spotAngle: try float(), shadow: try bool(),
                                               enable: try bool(), drawTarget: try bool())
        }
        if kind == .folder || kind == .item {
            let countStart = offset, count = try count()
            for _ in 0..<count { children.append(try object(depth: depth + 1, rootKey: nil)) }
            editSpans.topology.slots[key] = [.init(count: countStart, end: offset, children: children.map(\.sourceKey), point: nil)]
        }
        editSpans.topology.records[key] = recordStart..<offset
        return KoikatsuObjectRecord(kind: kind, rootDictionaryKey: rootKey, sourceKey: key,
                                    transform: transform, treeState: treeState, visible: visible,
                                    name: name, cameraActive: active, item: itemRecord, light: lightRecord, children: children,
                                    character: characterRecord, route: routeRecord)
    }

    func requireEnd() throws {
        guard offset == data.count else { throw invalid("unexpected trailing bytes in isolated record") }
    }
}
