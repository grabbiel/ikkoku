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
    /// Each object's own saved `visible` flag (a one-byte patch; parents are
    /// never propagated). Keys are source object IDs, including nested
    /// accessory children.
    public var visibility: [Int32: Bool]
    /// Renames keyed by source object ID, folder, camera and route records
    /// only — other record kinds serialize no name (a character's name lives
    /// in its card). The replacement may resize the stored string.
    public var names: [Int32: String]
    /// Camera records' own `active` bool byte (a one-byte patch): the saved
    /// look-through state. CharaStudio saves the current view — the camera
    /// being looked through is true and every other camera false — so a
    /// switched camera means rewriting every camera record's flag, not one.
    /// Keys are camera record source IDs.
    public var cameraActive: [Int32: Bool]
    /// Route records' own `active` bool byte (a one-byte patch): the saved
    /// play state, true when the route was playing at save time; loading a
    /// true record resumes playback. Keys are route record source IDs.
    public var routeActive: [Int32: Bool]
    /// Keys are source object IDs, including nested accessory children.
    /// The existing card editor preserves asset and saved resolver identities.
    public var cards: [Int32: SourceCharacterCard.Edits]
    public var kinematics: [Int32: KinematicEdit]
    public var animations: [Int32: SourceStudioAnimationState]
    public var voices: [Int32: SourceStudioVoiceState]
    /// A character record's own OICharInfo.mouthOpen float (CharaStudio's
    /// mouth openness slider, OCIChar.ChangeMouthOpen) and lipSync bool
    /// (OCIChar.ChangeLipSync): 4- and 1-byte in-place patches. Keys are
    /// character source IDs, including nested accessory children.
    public var mouth: [Int32: MouthEdit]
    public struct MouthEdit: Sendable, Equatable {
        public var mouthOpen: Float?, lipSync: Bool?
        public init(mouthOpen: Float? = nil, lipSync: Bool? = nil) { self.mouthOpen = mouthOpen; self.lipSync = lipSync }
    }
    public var currentCamera: KoikatsuCameraRecord?
    public var cameraSlots: [Int: KoikatsuCameraRecord]
    /// nil keeps the original PNG verbatim. Replacement must be one CRC-valid
    /// PNG; unlike embedded card thumbnails, a scene PNG cannot be removed.
    public var thumbnailData: Data?
    /// ST-T03: source records to delete with their whole subtree
    /// (`TreeNodeCtrl.DeleteNode`), listed by the top of each subtree. The
    /// writer drops their bytes, rewrites the owning list's count, writes
    /// `sunCaster = -1` when it pointed into a deleted subtree, and keeps
    /// every other record's key (no renumbering; see `SourceSceneTopology`).
    public var deletions: Set<Int32>
    /// ST-T03: moves applied in order. Each record leaves its current list
    /// and is appended to `parent`'s child list (a folder) or, for `nil`, to
    /// the root dictionary under its own key, carrying its subtree bytes
    /// unchanged. Pair a move with a `.object` transform edit holding the
    /// re-authored local placement (`SourceStudioWorldTransform.reparented`).
    public var reparents: [Reparent]
    public struct Reparent: Sendable, Equatable {
        public var object: Int32, parent: Int32?
        public init(object: Int32, parent: Int32?) { self.object = object; self.parent = parent }
    }
    public init(transforms: [TransformEdit] = [], cards: [Int32: SourceCharacterCard.Edits] = [:],
                kinematics: [Int32: KinematicEdit] = [:], animations: [Int32: SourceStudioAnimationState] = [:],
                voices: [Int32: SourceStudioVoiceState] = [:], currentCamera: KoikatsuCameraRecord? = nil,
                cameraSlots: [Int: KoikatsuCameraRecord] = [:], thumbnailData: Data? = nil,
                visibility: [Int32: Bool] = [:], names: [Int32: String] = [:],
                cameraActive: [Int32: Bool] = [:], routeActive: [Int32: Bool] = [:],
                mouth: [Int32: MouthEdit] = [:], deletions: Set<Int32> = [], reparents: [Reparent] = []) {
        self.deletions = deletions; self.reparents = reparents
        self.transforms = transforms; self.cards = cards; self.kinematics = kinematics; self.thumbnailData = thumbnailData
        self.visibility = visibility; self.names = names
        self.cameraActive = cameraActive; self.routeActive = routeActive
        self.currentCamera = currentCamera; self.cameraSlots = cameraSlots
        self.animations = animations
        self.voices = voices
        self.mouth = mouth
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
    var visibility: [Int32: Range<Int>] = [:]
    var names: [Int32: Range<Int>] = [:]
    var cameraActive: [Int32: Range<Int>] = [:]
    var routeActive: [Int32: Range<Int>] = [:]
    var cards: [Int32: Range<Int>] = [:]
    var kinematics: [Int32: Kinematics] = [:]
    var animations: [Int32: Animation] = [:]
    var voices: [Int32: Range<Int>] = [:]
    struct Mouth { let mouthOpen: Range<Int>, lipSync: Range<Int> }
    var mouth: [Int32: Mouth] = [:]
    var currentCamera: Range<Int>?, cameraSlots: [Int: Range<Int>] = [:]
    /// The `sceneInfo.sunCaster` Int32 in the settings tail.
    var sunCaster: Range<Int>?
    /// Byte layout of the object tree for deletion and reparenting.
    struct Topology {
        /// One child list inside a record: the Int32 count at `count`, the
        /// children's bytes up to `end`, and the accessory point key for a
        /// character's accessory group (`nil` for folder, item and route lists).
        struct Slot { let count: Int, end: Int, children: [Int32], point: Int32? }
        /// Each record from its kind Int32 to its last byte (a root's
        /// dictionary key precedes it).
        var records: [Int32: Range<Int>] = [:]
        /// Each record's child lists in byte order.
        var slots: [Int32: [Slot]] = [:]
    }
    var topology = Topology()
}

public extension KoikatsuSceneDocument {
    /// Pure byte transformation. The caller chooses a separate output URL.
    /// Any unsupported/missing destination or invalid input rejects the whole
    /// edit before bytes are returned; source data is never mutated.
    func editedData(_ edits: SourceSceneEdits) throws -> Data {
        guard !edits.transforms.isEmpty || !edits.cards.isEmpty || !edits.kinematics.isEmpty || !edits.animations.isEmpty || !edits.voices.isEmpty || edits.currentCamera != nil || !edits.cameraSlots.isEmpty || edits.thumbnailData != nil || !edits.visibility.isEmpty || !edits.names.isEmpty || !edits.cameraActive.isEmpty || !edits.routeActive.isEmpty || !edits.mouth.isEmpty || !edits.deletions.isEmpty || !edits.reparents.isEmpty else { return preservedData }
        guard edits.transforms.count <= 100_000, edits.cards.count <= 10_000, edits.kinematics.count <= 10_000, edits.animations.count <= 10_000, edits.voices.count <= 10_000, edits.visibility.count <= 100_000, edits.names.count <= 100_000, edits.cameraActive.count <= 100_000, edits.routeActive.count <= 100_000, edits.mouth.count <= 10_000, edits.deletions.count <= 100_000, edits.reparents.count <= 100_000 else { throw KoikatsuReadError.limitExceeded("too many scene edits") }
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
        let rootCountOffset = reader.offset
        for _ in 0..<(try reader.count()) {
            let rootKey = try reader.int32()
            index(try reader.object(depth: 0, rootKey: rootKey))
        }
        guard reader.offset == snapshot.objectSectionEndOffset else { throw reader.invalid("scene object byte spans differ from the decoded document") }
        _ = try reader.sceneSettings()
        guard try reader.string() == "【KStudio】", reader.offset == baseSceneEndOffset else { throw reader.invalid("scene settings byte spans differ from the decoded document") }
        let topology = edits.deletions.isEmpty && edits.reparents.isEmpty ? nil
            : try SourceSceneTopology.plan(snapshot, deletions: edits.deletions, reparents: edits.reparents)
        if let topology {
            if !edits.deletions.isEmpty { try refuseObjectKeyedExtensions() }
            // An edit of a deleted record has no destination left; refuse it
            // even when it would not change a byte.
            var targets = edits.transforms.map { edit -> Int32 in
                switch edit.destination {
                case .object(let key), .lookAt(let key): return key
                case .characterFK(let key, _), .characterIK(let key, _), .itemFK(let key, _): return key
                }
            }
            targets += Array(edits.visibility.keys) + Array(edits.names.keys) + Array(edits.cameraActive.keys)
            targets += Array(edits.routeActive.keys) + Array(edits.cards.keys) + Array(edits.kinematics.keys)
            targets += Array(edits.animations.keys) + Array(edits.voices.keys) + Array(edits.mouth.keys)
            if let key = targets.filter(topology.deleted.contains).min() {
                throw SourceSceneTopologyError.unsupported("A scene edit targets deleted source object \(key).")
            }
        }
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
        for key in edits.visibility.keys.sorted() {
            guard let range = reader.editSpans.visibility[key],
                  range.count == 1, (0...1).contains(preservedData[preservedData.startIndex + range.lowerBound]) else {
                throw reader.invalid("unavailable scene visibility destination")
            }
            add(range, Data([edits.visibility[key]! ? 1 : 0]))
        }
        for key in edits.cameraActive.keys.sorted() {
            guard let range = reader.editSpans.cameraActive[key],
                  range.count == 1, (0...1).contains(preservedData[preservedData.startIndex + range.lowerBound]) else {
                throw reader.invalid("unavailable scene camera active destination")
            }
            add(range, Data([edits.cameraActive[key]! ? 1 : 0]))
        }
        for key in edits.routeActive.keys.sorted() {
            guard let range = reader.editSpans.routeActive[key],
                  range.count == 1, (0...1).contains(preservedData[preservedData.startIndex + range.lowerBound]) else {
                throw reader.invalid("unavailable scene route active destination")
            }
            add(range, Data([edits.routeActive[key]! ? 1 : 0]))
        }
        for key in edits.names.keys.sorted() {
            guard let span = reader.editSpans.names[key] else { throw reader.invalid("unavailable scene name destination") }
            add(span, try KoikatsuBinaryReader.dotNetString(edits.names[key]!))
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
        for key in edits.mouth.keys.sorted() {
            let edit = edits.mouth[key]!
            guard objects[key]?.character != nil, let spans = reader.editSpans.mouth[key], spans.mouthOpen.count == 4,
                  spans.lipSync.count == 1, (0...1).contains(preservedData[preservedData.startIndex + spans.lipSync.lowerBound]) else {
                throw reader.invalid("unavailable character mouth destination")
            }
            if let open = edit.mouthOpen {
                // The State panel slider's range; ChangeMouthOpen stores it
                // unclamped as FBS FixedRate, so the native edit keeps 0...1.
                guard open.isFinite, (0...1).contains(open) else { throw reader.invalid("mouth openness must be finite and in 0...1") }
                var bits = open.bitPattern.littleEndian
                add(spans.mouthOpen, withUnsafeBytes(of: &bits) { Data($0) })
            }
            if let lipSync = edit.lipSync { add(spans.lipSync, Data([lipSync ? 1 : 0])) }
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
        if let topology {
            // Camera look-through state after a reload (ChangeCamera in load
            // order; the last true record wins). Without an explicit camera
            // edit the saved winner must stay the camera active at import
            // when it survives, and none when it was deleted
            // (Studio.DeleteCamera), as a CharaStudio save would write it.
            if edits.cameraActive.isEmpty {
                let cameras = topology.loadOrder(slots: reader.editSpans.topology.slots).filter { objects[$0]?.kind == .camera }
                let intended = SourceStudioCameraObjects.activeAtLoad(snapshot).flatMap { topology.deleted.contains($0) ? nil : $0 }
                if cameras.last(where: { objects[$0]?.cameraActive == true }) != intended {
                    for key in cameras where (objects[key]?.cameraActive == true) != (key == intended) {
                        guard let range = reader.editSpans.cameraActive[key], range.count == 1 else {
                            throw reader.invalid("unavailable scene camera active destination")
                        }
                        add(range, Data([key == intended ? 1 : 0]))
                    }
                }
            }
            // Studio.DeleteInfo: deleting the sun caster resets it to -1.
            if topology.deleted.contains(settings.sunCaster) {
                guard let range = reader.editSpans.sunCaster, range.count == 4 else { throw reader.invalid("sun caster byte span is unavailable") }
                var bits = Int32(-1).littleEndian
                add(range, withUnsafeBytes(of: &bits) { Data($0) })
            }
            let result = try topology.emit(preservedData, spans: reader.editSpans.topology, rootCount: rootCountOffset,
                                           objectEnd: snapshot.objectSectionEndOffset, patches: patches)
            try topology.verify(KoikatsuSceneReader.decodeDocument(result).snapshot)
            return result
        }
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

private extension KoikatsuSceneDocument {
    /// Plug-ins key their scene data by object `dicKey` and rewrite it from
    /// live objects when CharaStudio saves, which this writer cannot run.
    /// Deleting is therefore limited to scenes whose trailer carries no
    /// plug-in entries: no trailer, or one KKEx block with a nil or empty map.
    func refuseObjectKeyedExtensions() throws {
        guard !trailingData.isEmpty else { return }
        let extensions = extensions()
        let empty: Bool
        switch extensions.payload {
        case .some(.null): empty = true
        case .some(let payload): empty = (try? payload.stringKeyedMap())?.isEmpty == true
        case .none: empty = false
        }
        guard extensions.version != nil, empty, extensions.diagnostics.count == 1 else {
            throw SourceSceneTopologyError.unsupported("Original-scene export does not delete objects from a scene that carries plug-in (ExtendedSave) data: plug-ins key that data by object and rewrite it when CharaStudio saves. Save in native format instead.")
        }
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
