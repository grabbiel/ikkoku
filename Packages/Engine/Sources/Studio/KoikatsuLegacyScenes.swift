import Foundation

/// A CharaStudio scene data version, compared the way `SceneInfo.Load`
/// compares it: `new Version(ReadString())`, the .NET `System.Version`.
/// Two to four parts; an absent build or revision is -1, so 1.0.4 < 1.0.4.1
/// and 1.0.3.0 != 1.0.3 (the 1.0.3 route point branch is an equality test).
public struct KoikatsuSceneVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int32, minor: Int32, build: Int32, revision: Int32

    public init(_ major: Int32, _ minor: Int32, _ build: Int32 = -1, _ revision: Int32 = -1) {
        self.major = major; self.minor = minor; self.build = build; self.revision = revision
    }

    /// The version a scene string names, or nil unless it is canonical:
    /// two to four parts of ASCII digits without leading zeros, each fitting
    /// an Int32. .NET also accepts signs, spaces and leading zeros; a scene
    /// written that way is refused by name instead of guessed at.
    public init?(parsing text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        var values: [Int32] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part == "0" || part.first != "0", let value = Int32(part) else { return nil }
            values.append(value)
        }
        while values.count < 4 { values.append(-1) }
        self.init(values[0], values[1], values[2], values[3])
    }

    /// The writer's own version (`SceneInfo.m_Version`, SceneInfo.cs:11).
    public static let current = KoikatsuSceneVersion(1, 0, 4, 2)
    /// The oldest version read. Below it `SceneInfo.Load` leaves the line
    /// width, ramp and shadow depth (0.0.5, :422) and more to
    /// `SceneInfo.Init`, which takes them from the player's own
    /// `Manager.Config.EtcData` (:162–166).
    public static let oldestSupported = KoikatsuSceneVersion(0, 0, 5)

    public var description: String {
        [major, minor, build, revision].filter { $0 >= 0 }.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.build, lhs.revision) < (rhs.major, rhs.minor, rhs.build, rhs.revision)
    }

    /// Why `text` is not read, or nil when it is.
    static func refusal(_ text: String) -> String? {
        guard let version = KoikatsuSceneVersion(parsing: text) else {
            return "'\(text)' is not a canonical version (two to four decimal parts)"
        }
        if version > .current { return "it is newer than \(Self.current), the scene version this reader knows" }
        if version < .oldestSupported {
            return "it predates \(Self.oldestSupported): CharaStudio takes its missing scene settings from the player's own Config (SceneInfo.Init), which this reader does not know"
        }
        return nil
    }
}

/// The load branches one scene version takes (decompiled `Studio.*.Load`).
/// Everything is decided once per scene; a record read tests one flag.
struct KoikatsuSceneLayout: Sendable, Equatable {
    /// Older than 1.0.4.2: fields it lacks keep CharaStudio's constructor
    /// values, and export rewrites it as 1.0.4.2 (`upgraded`).
    let legacy: Bool
    /// OIItemInfo.Load :156 (`>= 0.0.6`): the panel pattern.
    let itemPanel: Bool
    /// :150 (`>= 0.0.7`): emission colour, power and light cancel.
    let itemEmission: Bool
    /// :168 (`>= 1.0.1`): enableDynamicBone.
    let itemDynamicBone: Bool
    /// OICharInfo.Load :299: 4 expression flags below 0.0.9, else 8.
    let characterExpressions: Int
    /// EyeLookCalc.LoadAngle (`>= 0.0.8`): the eye data's four angles.
    let eyeAngles: Bool
    /// OIRouteInfo.Load :85 (`>= 1.0.3`): active, loop, visibleLine.
    let routeFlags: Bool
    /// :91 (`>= 1.0.4`): orient.
    let routeOrientation: Bool
    /// :95 (`>= 1.0.4.1`): the line colour.
    let routeColor: Bool
    /// OIRoutePointInfo.Load :62 (`== 1.0.3`): one bool it reads and drops.
    let pointDiscardedFlag: Bool
    /// :66–77 (`>= 1.0.4.1`): connection and the aid record.
    let pointAid: Bool
    /// :78 (`>= 1.0.4.2`): link.
    let pointLink: Bool

    init(_ version: KoikatsuSceneVersion) {
        legacy = version != .current
        itemPanel = version >= KoikatsuSceneVersion(0, 0, 6)
        itemEmission = version >= KoikatsuSceneVersion(0, 0, 7)
        itemDynamicBone = version >= KoikatsuSceneVersion(1, 0, 1)
        characterExpressions = version < KoikatsuSceneVersion(0, 0, 9) ? 4 : 8
        eyeAngles = version >= KoikatsuSceneVersion(0, 0, 8)
        routeFlags = version >= KoikatsuSceneVersion(1, 0, 3)
        routeOrientation = version >= KoikatsuSceneVersion(1, 0, 4)
        routeColor = version >= KoikatsuSceneVersion(1, 0, 4, 1)
        pointDiscardedFlag = version == KoikatsuSceneVersion(1, 0, 3)
        pointAid = version >= KoikatsuSceneVersion(1, 0, 4, 1)
        pointLink = version >= KoikatsuSceneVersion(1, 0, 4, 2)
    }

    static let current = KoikatsuSceneLayout(.current)
}

/// The values CharaStudio's constructors give a field an older version does
/// not save, and the bytes its 1.0.4.2 `Save` writes for them. The JSON is
/// `JsonUtility.ToJson` as the installed writer formats it.
enum KoikatsuLegacyDefaults {
    /// `Utility.ConvertColor(255, 255, 255)` (OIItemInfo ctor :67).
    static let whiteJSON = #"{"r":1.0,"g":1.0,"b":1.0,"a":1.0}"#
    /// `Color.blue` (OIRouteInfo :33).
    static let blueJSON = #"{"r":0.0,"g":0.0,"b":1.0,"a":1.0}"#
    /// `new Vector4(0, 0, 1, 1)` (PatternInfo :17).
    static let patternUVJSON = #"{"x":0.0,"y":0.0,"z":1.0,"w":1.0}"#
    /// The `p_RoutePoint` prefab's objAid localPosition that
    /// AddObjectRoute.InitAid (:174–200) gives an aid the file lacks.
    static let aidTransform = KoikatsuChangeAmount(position: SIMD3(1, 1, 1), rotationDegrees: .zero, scale: .one)

    static func json(_ text: String, _ names: [String]) -> SIMD4<Float> {
        // The constants above are well formed; parsing them the reader's
        // own way keeps a defaulted value bit-equal to the upgraded read.
        try! KoikatsuBinaryReader.jsonVector(text, names, offset: 0)
    }
    static let white = json(whiteJSON, ["r", "g", "b", "a"])
    static let blue = json(blueJSON, ["r", "g", "b", "a"])
    /// `new PatternInfo()`: key 0, empty path, clamp, the default uv, rot 0.
    static let pattern = KoikatsuPatternRecord(key: 0, filePath: "", clamp: true,
                                               uv: json(patternUVJSON, ["x", "y", "z", "w"]), rotation: 0)

    static func int32(_ value: Int32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    static func float(_ value: Float) -> Data { int32(Int32(bitPattern: value.bitPattern)) }
    static func string(_ value: String) -> Data { try! KoikatsuBinaryReader.dotNetString(value) }
    static func patternBytes() -> Data {
        int32(0) + string("") + Data([1]) + string(patternUVJSON) + float(0)
    }
}

/// One splice of the 1.0.4.2 upgrade: `range` of the legacy bytes becomes
/// `bytes` (an insertion when the range is empty).
struct KoikatsuSceneUpgradePatch: Sendable, Equatable {
    let range: Range<Int>
    let bytes: Data
}

extension KoikatsuBinaryReader {
    /// Reads the scene's version string and takes its load branches;
    /// refuses a version outside 0.0.5–1.0.4.2 by name.
    mutating func sceneVersion() throws -> String {
        let start = offset, text = try string()
        if text == "1.0.4.2" { layout = .current; return text }
        if KoikatsuSceneVersion.refusal(text) != nil { throw KoikatsuReadError.unsupportedVersion(text) }
        layout = KoikatsuSceneLayout(KoikatsuSceneVersion(parsing: text)!)
        upgrade.append(.init(range: start..<offset, bytes: try Self.dotNetString("1.0.4.2")))
        return text
    }
    /// A legacy field CharaStudio 1.0.4.2 writes after this offset.
    mutating func upgradeInsert(_ bytes: Data) {
        upgrade.append(.init(range: offset..<offset, bytes: bytes))
    }
}

public extension KoikatsuSceneDocument {
    /// The scene's data version as CharaStudio compares it.
    var dataVersion: KoikatsuSceneVersion { KoikatsuSceneVersion(parsing: snapshot.version) ?? .current }
    /// Written by a CharaStudio older than 1.0.4.2. Its document holds what
    /// CharaStudio 1.0.4.2 loads from it; an export saves it as 1.0.4.2.
    var isLegacy: Bool { snapshot.version != "1.0.4.2" }

    /// The scene as CharaStudio 1.0.4.2 saves a loaded legacy scene
    /// (SceneInfo.Save always writes `m_Version` and every current field):
    /// each field the old version lacks is written with the value its load
    /// gave it, pre-0.0.8 eye data gets the Init angles (zero), a version-1
    /// camera becomes version 2 with the zero distance its load keeps, and
    /// the 1.0.3 route point flag is dropped. Every other byte, the PNG and
    /// the plug-in trailer included, is kept. Returns `self` for a 1.0.4.2
    /// scene. Refuses, with the reason, a route point without a saved aid
    /// (CharaStudio allocates its key at load from runtime state) and
    /// pre-0.0.8 eye data that is not two quaternions.
    func upgraded() throws -> KoikatsuSceneDocument {
        guard isLegacy else { return self }
        var reader = try KoikatsuBinaryReader(preservedData)
        try reader.skipPNG()
        guard try reader.sceneVersion() == snapshot.version else { throw reader.invalid("scene version differs from its decoded document") }
        for _ in 0..<(try reader.count()) { _ = try reader.object(depth: 0, rootKey: try reader.int32()) }
        guard reader.offset == snapshot.objectSectionEndOffset else { throw reader.invalid("scene object byte spans differ from the decoded document") }
        _ = try reader.sceneSettings()
        guard try reader.string() == "【KStudio】", reader.offset == baseSceneEndOffset else {
            throw reader.invalid("scene settings byte spans differ from the decoded document")
        }
        if let refusal = reader.upgradeRefusals.first {
            throw SourceSceneTopologyError.unsupported("This CharaStudio \(snapshot.version) scene cannot be saved as 1.0.4.2: \(refusal)")
        }
        var output = Data(), position = 0
        output.reserveCapacity(preservedData.count + reader.upgrade.reduce(0) { $0 + $1.bytes.count })
        let base = preservedData.startIndex
        for patch in reader.upgrade {
            guard patch.range.lowerBound >= position else { throw reader.invalid("overlapping upgrade patches") }
            output.append(preservedData[(base + position)..<(base + patch.range.lowerBound)])
            output.append(patch.bytes)
            position = patch.range.upperBound
        }
        output.append(preservedData[(base + position)...])
        let upgraded = try KoikatsuSceneReader.decodeDocument(output)
        guard !upgraded.isLegacy, upgraded.settings == settings, upgraded.trailingData == trailingData,
              Self.shape(upgraded.snapshot.roots) == Self.shape(snapshot.roots) else {
            throw SourceSceneTopologyError.unsupported("The CharaStudio \(snapshot.version) scene's 1.0.4.2 upgrade does not read back as the same scene.")
        }
        return upgraded
    }

    private static func shape(_ records: [KoikatsuObjectRecord]) -> [String] {
        var result: [String] = []
        func visit(_ record: KoikatsuObjectRecord) {
            result.append("\(record.kind.rawValue):\(record.sourceKey):\(record.rootDictionaryKey.map(String.init) ?? "-"):\(record.children.count)")
            record.children.forEach(visit)
            for point in (record.character?.accessoryChildren.keys.sorted() ?? []) {
                result.append("point:\(point)")
                record.character?.accessoryChildren[point]?.forEach(visit)
            }
        }
        records.forEach(visit)
        return result
    }
}
