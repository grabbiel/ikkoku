import Foundation
import Character

/// Bounded edits to the observed original Studio stream. IDs, catalog choices,
/// object ordering, unedited records and plug-in payloads remain source bytes.
public struct SourceSceneEdits: Sendable {
    public enum Destination: Hashable, Sendable {
        case object(Int32)
        case characterFK(object: Int32, bone: Int32)
        case characterIK(object: Int32, target: Int32)
        case itemFK(object: Int32, bone: String)
        case lookAt(object: Int32)
        public static func == (a: Self, b: Self) -> Bool {
            switch (a, b) {
            case let (.object(x), .object(y)), let (.lookAt(x), .lookAt(y)): return x == y
            case let (.characterFK(a, x), .characterFK(b, y)), let (.characterIK(a, x), .characterIK(b, y)): return a == b && x == y
            case let (.itemFK(a, x), .itemFK(b, y)): return a == b && x.utf8.elementsEqual(y.utf8)
            default: return false
            }
        }
        public func hash(into hasher: inout Hasher) {
            switch self {
            case .object(let key): hasher.combine(0); hasher.combine(key)
            case .characterFK(let object, let key): hasher.combine(1); hasher.combine(object); hasher.combine(key)
            case .characterIK(let object, let key): hasher.combine(2); hasher.combine(object); hasher.combine(key)
            case .itemFK(let object, let name): hasher.combine(3); hasher.combine(object); hasher.combine(Data(name.utf8))
            case .lookAt(let key): hasher.combine(4); hasher.combine(key)
            }
        }
    }
    public struct TransformEdit: Sendable {
        public let destination: Destination, transform: KoikatsuChangeAmount
        /// Values use original Unity coordinates and Euler degrees.
        public init(_ destination: Destination, transform: KoikatsuChangeAmount) {
            self.destination = destination; self.transform = transform
        }
    }
    public struct KinematicEdit: Sendable {
        public var enableFK: Bool?, enableIK: Bool?, activeFK: [Bool]?, activeIK: [Bool]?
        /// Arrays retain original group order: exactly seven FK and five IK flags.
        /// Both enabled values are written literally; original load order gives
        /// IK precedence when both are true. Set enableIK=false to activate FK.
        public init(enableFK: Bool? = nil, enableIK: Bool? = nil, activeFK: [Bool]? = nil, activeIK: [Bool]? = nil) {
            self.enableFK = enableFK; self.enableIK = enableIK; self.activeFK = activeFK; self.activeIK = activeIK
        }
    }
    public var transforms: [TransformEdit]
    /// Keys are source object IDs, including nested accessory children.
    /// The existing card editor preserves asset and saved resolver identities.
    public var cards: [Int32: SourceCharacterCard.Edits]
    public var kinematics: [Int32: KinematicEdit]
    public var animations: [Int32: SourceStudioAnimationState]
    public var voices: [Int32: SourceStudioVoiceState]
    public var currentCamera: KoikatsuCameraRecord?
    public var cameraSlots: [Int: KoikatsuCameraRecord]
    /// nil keeps the original PNG verbatim. Replacement must be one CRC-valid
    /// PNG; unlike embedded card thumbnails, a scene PNG cannot be removed.
    public var thumbnailData: Data?
    public init(transforms: [TransformEdit] = [], cards: [Int32: SourceCharacterCard.Edits] = [:],
                kinematics: [Int32: KinematicEdit] = [:], animations: [Int32: SourceStudioAnimationState] = [:],
                voices: [Int32: SourceStudioVoiceState] = [:], currentCamera: KoikatsuCameraRecord? = nil,
                cameraSlots: [Int: KoikatsuCameraRecord] = [:], thumbnailData: Data? = nil) {
        self.transforms = transforms; self.cards = cards; self.kinematics = kinematics; self.thumbnailData = thumbnailData
        self.currentCamera = currentCamera; self.cameraSlots = cameraSlots
        self.animations = animations
        self.voices = voices
    }
}

struct SourceSceneEditSpans {
    struct Animation {
        let identity: Range<Int>, speedPattern: Range<Int>, forceLoop: Range<Int>, options: Range<Int>, normalizedTime: Range<Int>
    }
    struct Kinematics {
        let enableIK: Range<Int>, activeIK: Range<Int>, enableFK: Range<Int>, activeFK: Range<Int>
    }
    var transforms: [SourceSceneEdits.Destination: Range<Int>] = [:]
    var cards: [Int32: Range<Int>] = [:]
    var kinematics: [Int32: Kinematics] = [:]
    var animations: [Int32: Animation] = [:]
    var voices: [Int32: Range<Int>] = [:]
    var currentCamera: Range<Int>?, cameraSlots: [Int: Range<Int>] = [:]
}

public extension KoikatsuSceneDocument {
    /// Pure byte transformation. The caller chooses a separate output URL.
    /// Any unsupported/missing destination or invalid input rejects the whole
    /// edit before bytes are returned; source data is never mutated.
    func editedData(_ edits: SourceSceneEdits) throws -> Data {
        guard !edits.transforms.isEmpty || !edits.cards.isEmpty || !edits.kinematics.isEmpty || !edits.animations.isEmpty || !edits.voices.isEmpty || edits.currentCamera != nil || !edits.cameraSlots.isEmpty || edits.thumbnailData != nil else { return preservedData }
        guard edits.transforms.count <= 100_000, edits.cards.count <= 10_000, edits.kinematics.count <= 10_000, edits.animations.count <= 10_000, edits.voices.count <= 10_000 else { throw KoikatsuReadError.limitExceeded("too many scene edits") }
        var reader = try KoikatsuBinaryReader(preservedData)
        try reader.skipPNG()
        let thumbnailRange = 0..<reader.offset
        guard try reader.string() == snapshot.version else { throw reader.invalid("scene version differs from its decoded document") }
        var objects: [Int32: KoikatsuObjectRecord] = [:]
        func index(_ object: KoikatsuObjectRecord) {
            objects[object.sourceKey] = object
            for child in object.children { index(child) }
            if let character = object.character {
                for children in character.accessoryChildren.values { for child in children { index(child) } }
            }
        }
        for _ in 0..<(try reader.count()) {
            let rootKey = try reader.int32()
            index(try reader.object(depth: 0, rootKey: rootKey))
        }
        guard reader.offset == snapshot.objectSectionEndOffset else { throw reader.invalid("scene object byte spans differ from the decoded document") }
        _ = try reader.sceneSettings()
        guard try reader.string() == "【KStudio】", reader.offset == baseSceneEndOffset else { throw reader.invalid("scene settings byte spans differ from the decoded document") }
        var patches: [(Range<Int>, Data)] = [], destinations = Set<SourceSceneEdits.Destination>()
        func add(_ range: Range<Int>, _ replacement: Data) {
            if preservedData.subdata(in: (preservedData.startIndex + range.lowerBound)..<(preservedData.startIndex + range.upperBound)) != replacement {
                patches.append((range, replacement))
            }
        }
        for edit in edits.transforms {
            guard destinations.insert(edit.destination).inserted,
                  let range = reader.editSpans.transforms[edit.destination] else { throw reader.invalid("duplicate or unavailable scene transform destination") }
            let vectors = [edit.transform.position, edit.transform.rotationDegrees, edit.transform.scale]
            var bytes = Data()
            for vector in vectors { for index in 0..<3 {
                let value = vector[index]
                guard value.isFinite else { throw reader.invalid("scene transform contains a nonfinite component") }
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            } }
            guard range.count == 36 else { throw reader.invalid("scene transform span is not 36 bytes") }
            add(range, bytes)
        }
        for (key, edit) in edits.cards {
            guard let character = objects[key]?.character, let range = reader.editSpans.cards[key] else { throw reader.invalid("embedded card object is unavailable") }
            guard edit.thumbnailData?.isEmpty != false else { throw reader.invalid("embedded scene cards cannot contain a PNG prefix") }
            let card = try character.card(), identity = try card.customization()
            guard identity.sex == character.sex else { throw reader.invalid("embedded card sex differs from its character record") }
            let changed = try card.editedData(edit), updated = try SourceCharacterCard.decode(changed)
            let after = try updated.customization()
            guard updated.thumbnailData.isEmpty, after.sex == identity.sex, after.exType == identity.exType,
                  after.headID == identity.headID, after.boneType == identity.boneType else {
                throw reader.invalid("embedded card edit changed assembly identity")
            }
            add(range, changed)
        }
        for (key, edit) in edits.kinematics {
            guard objects[key]?.character != nil, let spans = reader.editSpans.kinematics[key],
                  edit.activeFK.map({ $0.count == 7 }) ?? true,
                  edit.activeIK.map({ $0.count == 5 }) ?? true else { throw reader.invalid("unavailable character or invalid kinematic group count") }
            if let flag = edit.enableFK { add(spans.enableFK, Data([flag ? 1 : 0])) }
            if let flag = edit.enableIK { add(spans.enableIK, Data([flag ? 1 : 0])) }
            if let flags = edit.activeFK { add(spans.activeFK, Data(flags.map { $0 ? 1 : 0 })) }
            if let flags = edit.activeIK { add(spans.activeIK, Data(flags.map { $0 ? 1 : 0 })) }
        }
        for (key, edit) in edits.animations {
            guard objects[key]?.character != nil, let spans = reader.editSpans.animations[key],
                  edit.speed >= 0, edit.normalizedTime >= 0 else { throw reader.invalid("unavailable character or invalid animation clock") }
            func floats(_ values: [Float]) throws -> Data {
                var bytes = Data()
                for value in values {
                    guard value.isFinite else { throw reader.invalid("nonfinite animation edit") }
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                }
                return bytes
            }
            var identity = Data()
            for value in [edit.group, edit.category, edit.no] {
                var bits = value.littleEndian; withUnsafeBytes(of: &bits) { identity.append(contentsOf: $0) }
            }
            add(spans.identity, identity); add(spans.speedPattern, try floats([edit.speed, edit.pattern]))
            add(spans.forceLoop, Data([edit.forceLoop ? 1 : 0])); add(spans.options, try floats([edit.optionParameters.x, edit.optionParameters.y]))
            add(spans.normalizedTime, try floats([edit.normalizedTime]))
        }
        for (key, edit) in edits.voices {
            guard objects[key]?.character != nil, let span = reader.editSpans.voices[key], edit.playlist.count <= 10_000 else {
                throw reader.invalid("unavailable character or oversized voice playlist")
            }
            var bytes = Data()
            func integer(_ value: Int32) { var bits = value.littleEndian; withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) } }
            integer(Int32(edit.playlist.count))
            for selection in edit.playlist { integer(selection.group); integer(selection.category); integer(selection.no) }
            integer(edit.repeatMode); add(span, bytes)
        }
        func cameraBytes(_ value: KoikatsuCameraRecord) throws -> Data {
            guard value.fieldOfView > 0, value.fieldOfView < 180 else { throw reader.invalid("edited camera field of view must be between 0 and 180 degrees") }
            let numbers = [value.position.x, value.position.y, value.position.z,
                value.rotationDegrees.x, value.rotationDegrees.y, value.rotationDegrees.z,
                value.distance.x, value.distance.y, value.distance.z, value.fieldOfView]
            var bytes = Data()
            for number in numbers {
                guard number.isFinite else { throw reader.invalid("edited camera contains a nonfinite component") }
                var bits = number.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            return bytes
        }
        if let camera = edits.currentCamera {
            guard let span = reader.editSpans.currentCamera, span.count == 40 else { throw reader.invalid("current camera byte span is unavailable") }
            add(span, try cameraBytes(camera))
        }
        for (slot, camera) in edits.cameraSlots {
            guard (0..<10).contains(slot), let span = reader.editSpans.cameraSlots[slot], span.count == 40 else { throw reader.invalid("camera slot must be between 0 and 9") }
            add(span, try cameraBytes(camera))
        }
        if let png = edits.thumbnailData { try SourceScenePNG.validate(png); add(thumbnailRange, png) }
        patches.sort { $0.0.lowerBound < $1.0.lowerBound }
        var result = Data(), cursor = 0
        for (range, bytes) in patches {
            guard cursor <= range.lowerBound, range.upperBound <= preservedData.count else { throw reader.invalid("overlapping or invalid scene edits") }
            result.append(preservedData.subdata(in: (preservedData.startIndex + cursor)..<(preservedData.startIndex + range.lowerBound)))
            result.append(bytes); cursor = range.upperBound
            guard result.count <= 256 * 1024 * 1024 else { throw KoikatsuReadError.limitExceeded("edited scene exceeds 256 MiB") }
        }
        result.append(preservedData.subdata(in: (preservedData.startIndex + cursor)..<preservedData.endIndex))
        guard result.count <= 256 * 1024 * 1024 else { throw KoikatsuReadError.limitExceeded("edited scene exceeds 256 MiB") }
        // Parsing the complete result catches any shifted embedded-card boundary
        // before an invalid export can leave this pure writer.
        _ = try KoikatsuSceneReader.decodeDocument(result)
        return result
    }
}

private enum SourceScenePNG {
    static func validate(_ data: Data) throws {
        guard data.count <= 16 * 1024 * 1024, data.count >= 20,
              data.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw KoikatsuReadError.invalidPNG }
        let bytes = [UInt8](data); var offset = 8, count = 0
        func u32(_ i: Int) -> UInt32 { bytes[i..<(i+4)].reduce(0) { ($0 << 8) | UInt32($1) } }
        while offset <= bytes.count - 12 {
            let length = Int(u32(offset)), type = Array(bytes[(offset+4)..<(offset+8)])
            guard length <= bytes.count - offset - 12, count < 100_000,
                  count != 0 || (type == [73,72,68,82] && length == 13),
                  count == 0 || type != [73,72,68,82] else { throw KoikatsuReadError.invalidPNG }
            let end = offset + 8 + length
            var crc = UInt32.max
            for byte in bytes[(offset+4)..<end] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            guard ~crc == u32(end) else { throw KoikatsuReadError.invalidPNG }
            offset = end + 4; count += 1
            if type == [73,69,78,68] {
                guard length == 0, offset == bytes.count else { throw KoikatsuReadError.invalidPNG }
                return
            }
        }
        throw KoikatsuReadError.invalidPNG
    }
}
