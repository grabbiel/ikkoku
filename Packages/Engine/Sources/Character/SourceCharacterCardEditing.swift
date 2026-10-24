import Foundation
import Assets

extension SourceCharacterCard {
    public enum Field: Hashable, Sendable {
        case key(String), index(Int)
    }
    public enum Record: Hashable, Sendable {
        case face, body, hair
        case clothes(coordinate: Int), accessory(coordinate: Int), makeup(coordinate: Int)
        /// The saved outfit (ChaFile.coordinate index) this record belongs to;
        /// nil for the outfit-independent Custom records.
        public var coordinate: Int? {
            switch self {
            case .clothes(let index), .accessory(let index), .makeup(let index): index
            case .face, .body, .hair: nil
            }
        }
    }
    /// A Unity Color is four numeric MessagePack array members in RGBA order.
    /// Asset identities cannot be changed here: their saved resolver metadata
    /// would also need a source-compatible rewrite.
    public struct ColorEdit: Sendable {
        public let record: Record, path: [Field], rgba: [Float]
        public init(record: Record, path: [Field], rgba: [Float]) {
            self.record = record; self.path = path; self.rgba = rgba
        }
    }
    public struct Edits: Sendable {
        public var faceValues: [Float]?, bodyValues: [Float]?
        public var colors: [ColorEdit]
        /// The worn outfit (Status.coordinateType, 0...6); nil keeps the saved
        /// one. The card must carry that outfit in its Coordinate list. See
        /// `editedStatus(coordinate:)` for the exact Status fields written.
        public var coordinateType: Int?
        /// The nine Status.clothesState bytes (ChaFileDefine.ClothesKind
        /// order, each 0 on, 1 half, 2 half 2, 3 off); nil keeps the saved
        /// bytes. Only the bin payload bytes of the existing field change.
        public var clothesState: [UInt8]?
        /// The twenty Status.showAccessory flags; nil keeps the saved flags.
        /// Only the changed bool tokens of the existing array change.
        public var showAccessory: [Bool]?
        /// Status.shoesType (0 indoor, 1 outdoor); nil keeps the saved value.
        /// The existing token is replaced by its compact form, or the field
        /// is appended when the card does not save it and the value is not
        /// the MemberInit default 0.
        public var shoesType: Int?
        /// The CharaStudio State panel's face-state Status fields (ST-C04);
        /// each nil member keeps the saved token. See `StatusFaceEdit`.
        public var faceState: StatusFaceEdit
        /// nil preserves the old image; empty Data removes it; nonempty data
        /// must contain exactly one CRC-valid PNG, without an appended card.
        public var thumbnailData: Data?, faceThumbnailData: Data?
        public init(faceValues: [Float]? = nil, bodyValues: [Float]? = nil,
                    colors: [ColorEdit] = [], coordinateType: Int? = nil,
                    clothesState: [UInt8]? = nil, showAccessory: [Bool]? = nil, shoesType: Int? = nil,
                    faceState: StatusFaceEdit = StatusFaceEdit(), thumbnailData: Data? = nil,
                    faceThumbnailData: Data? = nil) {
            self.faceValues = faceValues; self.bodyValues = bodyValues; self.colors = colors
            self.coordinateType = coordinateType
            self.clothesState = clothesState; self.showAccessory = showAccessory; self.shoesType = shoesType
            self.faceState = faceState
            self.thumbnailData = thumbnailData; self.faceThumbnailData = faceThumbnailData
        }
    }

    /// The ChaFileStatus face-state fields the CharaStudio State panel edits
    /// (MPCharCtrl.EtcInfo, LookAtInfo, NeckInfo and OtherInfo): eyebrow,
    /// eyes and mouth pattern (`eyesPtn` is the cha_eyeset row ID, not the
    /// FBS pattern), eye openness (`eyesOpenMax`), the blink flag, eye and
    /// neck look pattern, tears level and cheek rate. A field the Status map
    /// does not carry is the ChaFileStatus.MemberInit default; a field of
    /// another MessagePack type is rejected, never guessed. Values are read
    /// as saved, without the State panel's ranges (a load clamps or remaps
    /// some of them; the Studio preview reports that).
    public struct StatusFace: Equatable, Sendable {
        public var eyebrowPtn: Int, eyesPtn: Int, mouthPtn: Int
        public var eyesOpenMax: Float
        public var eyesBlink: Bool
        public var eyesLookPtn: Int, neckLookPtn: Int
        public var tearsLv: Int
        public var hohoAkaRate: Float
        public static let memberInit = StatusFace(eyebrowPtn: 0, eyesPtn: 0, mouthPtn: 0, eyesOpenMax: 1, eyesBlink: true,
                                                  eyesLookPtn: 0, neckLookPtn: 0, tearsLv: 0, hohoAkaRate: 0)
        public init(eyebrowPtn: Int, eyesPtn: Int, mouthPtn: Int, eyesOpenMax: Float, eyesBlink: Bool,
                    eyesLookPtn: Int, neckLookPtn: Int, tearsLv: Int, hohoAkaRate: Float) {
            self.eyebrowPtn = eyebrowPtn; self.eyesPtn = eyesPtn; self.mouthPtn = mouthPtn
            self.eyesOpenMax = eyesOpenMax; self.eyesBlink = eyesBlink
            self.eyesLookPtn = eyesLookPtn; self.neckLookPtn = neckLookPtn
            self.tearsLv = tearsLv; self.hohoAkaRate = hohoAkaRate
        }
        public init(status: [String: SourceMessagePackValue]) throws {
            self = .memberInit
            func integer(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
                guard let value = status[key] else { return nil }
                guard let number = value.integerValue, range.contains(number) else { throw cardEditError("Saved Status.\(key) is not an integer in \(range).") }
                return number
            }
            func float(_ key: String) throws -> Float? {
                guard let value = status[key] else { return nil }
                switch value {
                case .float(let number) where number.isFinite && abs(number) <= Double(Float.greatestFiniteMagnitude): return Float(number)
                case .integer(let number): return Float(number)
                case .unsigned(let number): return Float(number)
                default: throw cardEditError("Saved Status.\(key) is not a finite number.")
                }
            }
            let int32 = Int(Int32.min)...Int(Int32.max)
            eyebrowPtn = try integer("eyebrowPtn", int32) ?? eyebrowPtn
            eyesPtn = try integer("eyesPtn", int32) ?? eyesPtn
            mouthPtn = try integer("mouthPtn", int32) ?? mouthPtn
            eyesOpenMax = try float("eyesOpenMax") ?? eyesOpenMax
            if let value = status["eyesBlink"] {
                guard case .bool(let flag) = value else { throw cardEditError("Saved Status.eyesBlink is not a bool.") }
                eyesBlink = flag
            }
            eyesLookPtn = try integer("eyesLookPtn", int32) ?? eyesLookPtn
            neckLookPtn = try integer("neckLookPtn", int32) ?? neckLookPtn
            tearsLv = try integer("tearsLv", 0...255) ?? tearsLv
            hohoAkaRate = try float("hohoAkaRate") ?? hohoAkaRate
        }
    }

    /// Face-state Status edits: nil members keep the saved tokens. A changed
    /// member must be a valid State-panel value for its field type (patterns
    /// nonnegative Int32, `tearsLv` 0...3 — ChaControl's tears table has four
    /// rows — and finite rates in 0...1); the Studio preview validates the
    /// catalog ranges before it reaches the card.
    public struct StatusFaceEdit: Equatable, Sendable {
        public var eyebrowPtn: Int?, eyesPtn: Int?, mouthPtn: Int?
        public var eyesOpenMax: Float?
        public var eyesBlink: Bool?
        public var eyesLookPtn: Int?, neckLookPtn: Int?
        public var tearsLv: Int?
        public var hohoAkaRate: Float?
        public init(eyebrowPtn: Int? = nil, eyesPtn: Int? = nil, mouthPtn: Int? = nil, eyesOpenMax: Float? = nil,
                    eyesBlink: Bool? = nil, eyesLookPtn: Int? = nil, neckLookPtn: Int? = nil,
                    tearsLv: Int? = nil, hohoAkaRate: Float? = nil) {
            self.eyebrowPtn = eyebrowPtn; self.eyesPtn = eyesPtn; self.mouthPtn = mouthPtn
            self.eyesOpenMax = eyesOpenMax; self.eyesBlink = eyesBlink
            self.eyesLookPtn = eyesLookPtn; self.neckLookPtn = neckLookPtn
            self.tearsLv = tearsLv; self.hohoAkaRate = hohoAkaRate
        }
        public var isEmpty: Bool { self == StatusFaceEdit() }
        /// The Status keys this edit names (non-nil members).
        public var editedKeys: [String] {
            [("eyebrowPtn", eyebrowPtn != nil), ("eyesPtn", eyesPtn != nil), ("mouthPtn", mouthPtn != nil),
             ("eyesOpenMax", eyesOpenMax != nil), ("eyesBlink", eyesBlink != nil), ("eyesLookPtn", eyesLookPtn != nil),
             ("neckLookPtn", neckLookPtn != nil), ("tearsLv", tearsLv != nil), ("hohoAkaRate", hohoAkaRate != nil)]
                .filter(\.1).map(\.0)
        }
    }

    /// The embedded card's saved face-state fields (MemberInit defaults when
    /// the card has no Status block).
    public func savedStatusFace() throws -> StatusFace {
        guard let status = block(named: "Status") else { return .memberInit }
        return try StatusFace(status: SourceMessagePack.decode(status.data).stringKeyedMap())
    }

    /// The ChaFileStatus wear fields as the card saves them: `clothesState`
    /// holds one byte per ChaFileDefine.ClothesKind (top, bot, bra, shorts,
    /// gloves, panst, socks, shoes_inner, shoes_outer; 0 on, 1 half, 2 half 2,
    /// 3 off), `shoesType` selects the inner (0) or outer (1) shoes, and
    /// `showAccessory` is one flag per accessory slot. A field the Status map
    /// does not carry is the ChaFileStatus.MemberInit default (all on, inner
    /// shoes, every accessory shown); a field of another shape is rejected,
    /// never guessed. MessagePack-CSharp writes the byte[] as bin; a card
    /// that spells it as an array of nine small integers (written by other
    /// tools) is read by value.
    public struct StatusWear: Equatable, Sendable {
        public var clothesState: [UInt8]
        public var shoesType: Int
        public var showAccessory: [Bool]
        public static let memberInit = StatusWear(clothesState: Array(repeating: 0, count: 9), shoesType: 0,
                                                  showAccessory: Array(repeating: true, count: 20))
        public init(clothesState: [UInt8], shoesType: Int, showAccessory: [Bool]) {
            self.clothesState = clothesState; self.shoesType = shoesType; self.showAccessory = showAccessory
        }
        public init(status: [String: SourceMessagePackValue]) throws {
            self = .memberInit
            if let value = status["clothesState"] {
                let bytes: [Int]
                if case .binary(let data) = value { bytes = data.map(Int.init) }
                else if let members = value.arrayValue, members.allSatisfy({ $0.integerValue != nil }) {
                    bytes = members.compactMap(\.integerValue)
                } else { bytes = [] }
                guard bytes.count == 9 else { throw cardEditError("Saved Status.clothesState is not the 9-byte ClothesKind array.") }
                guard bytes.allSatisfy({ (0...3).contains($0) }) else { throw cardEditError("Saved Status.clothesState has a value outside 0...3.") }
                clothesState = bytes.map(UInt8.init)
            }
            if let value = status["shoesType"] {
                guard let type = value.integerValue, (0...255).contains(type) else { throw cardEditError("Saved Status.shoesType is not a byte.") }
                shoesType = type
            }
            if let value = status["showAccessory"] {
                guard let flags = value.arrayValue, flags.count == 20 else {
                    throw cardEditError("Saved Status.showAccessory is not the 20-slot bool array.")
                }
                showAccessory = try flags.map {
                    guard case .bool(let flag) = $0 else { throw cardEditError("Saved Status.showAccessory has a non-bool member.") }
                    return flag
                }
            }
        }
    }

    /// The embedded card's saved wear fields (MemberInit defaults when the
    /// card has no Status block).
    public func savedStatusWear() throws -> StatusWear {
        guard let status = block(named: "Status") else { return .memberInit }
        return try StatusWear(status: SourceMessagePack.decode(status.data).stringKeyedMap())
    }

    /// Number of saved outfits in the Coordinate block (ChaFile.coordinate);
    /// an original card always carries seven.
    public func coordinateCount() throws -> Int {
        guard let block = block(named: "Coordinate"), block.version == "0.0.0",
              let entries = try SourceMessagePack.decode(block.data).arrayValue, entries.count <= 64 else {
            throw cardEditError("Coordinate list is unavailable or unsupported.")
        }
        return entries.count
    }

    /// The saved worn outfit, ChaFileStatus.coordinateType (0 when the card
    /// has no Status block, the ChaFileStatus.MemberInit default).
    public func savedCoordinateType() throws -> Int {
        guard let status = block(named: "Status") else { return 0 }
        guard let value = try SourceMessagePack.decode(status.data).stringKeyedMap()["coordinateType"] else { return 0 }
        guard let index = value.integerValue, (0..<7).contains(index) else { throw cardEditError("Saved Status.coordinateType is not an outfit index in 0...6.") }
        return index
    }

    /// Original bytes for one current-version appearance record. This does not
    /// load textures or execute extension callbacks; callers decode known fields.
    public func recordData(_ record: Record) throws -> Data {
        let bytes: Data, expected: String
        switch record {
        case .face, .body, .hair:
            guard let block = block(named: "Custom"), block.version == "0.0.0" else { throw cardEditError("Unsupported Custom block.") }
            var reader = try CardReader(block.data)
            let records = try (0..<3).map { _ in try reader.lengthPrefixedData() }
            guard reader.remaining == 0 else { throw cardEditError("Unexpected Custom record trailer.") }
            bytes = records[record == .face ? 0 : record == .body ? 1 : 2]
            expected = record == .hair ? "0.0.4" : "0.0.2"
        case .clothes(let index), .accessory(let index), .makeup(let index):
            guard let block = block(named: "Coordinate"), block.version == "0.0.0",
                  let entries = try SourceMessagePack.decode(block.data).arrayValue, entries.count <= 64,
                  entries.indices.contains(index), let data = entries[index].binaryValue else { throw cardEditError("Coordinate record is unavailable or unsupported.") }
            var reader = try CardReader(data)
            let clothes = try reader.lengthPrefixedData(), accessory = try reader.lengthPrefixedData()
            _ = try reader.take(1)
            let makeup = try reader.lengthPrefixedData()
            guard reader.remaining == 0 else { throw cardEditError("Unexpected Coordinate record trailer.") }
            switch record {
            case .clothes: bytes = clothes; expected = "0.0.1"
            case .accessory: bytes = accessory; expected = "0.0.2"
            default: bytes = makeup; expected = "0.0.0"
            }
        }
        guard try SourceMessagePack.decode(bytes).stringKeyedMap()["version"]?.stringValue == expected else { throw cardEditError("Unsupported appearance record version.") }
        return bytes
    }

    public func recordFields(_ record: Record) throws -> [String: SourceMessagePackValue] {
        try SourceMessagePack.decode(recordData(record)).stringKeyedMap()
    }

    /// Produces a new original-format card. This function performs no file I/O.
    /// Only changed numeric tokens and their enclosing length/offset fields are
    /// rewritten; all unrelated bytes, including opaque plug-ins, survive.
    public func editedData(_ edits: Edits) throws -> Data {
        guard edits.colors.count <= 4096 else { throw cardEditError("Too many color edits.") }
        var replacements: [String: Data] = [:]
        var recordEdits: [Record: [CardNumericEdit]] = [:]
        if let values = edits.faceValues {
            try Self.validateNumbers(values, count: 52)
            recordEdits[.face, default: []].append(.init(path: [.key("shapeValueFace")], values: values))
        }
        if let values = edits.bodyValues {
            try Self.validateNumbers(values, count: 44)
            recordEdits[.body, default: []].append(.init(path: [.key("shapeValueBody")], values: values))
        }
        for color in edits.colors {
            try Self.validateNumbers(color.rgba, count: 4)
            guard !color.path.isEmpty, color.path.count <= 32 else { throw cardEditError("Invalid color field path.") }
            // A caller may select a recovered Color field, but cannot use this
            // API to rewrite arbitrary float4 transforms or shape arrays.
            guard color.path.contains(where: { if case .key(let key) = $0 { return key.lowercased().contains("color") }; return false }) else {
                throw cardEditError("Color edit must address a named color field.")
            }
            recordEdits[color.record, default: []].append(.init(path: color.path, values: color.rgba))
        }
        if !recordEdits.isEmpty { _ = try customization() }
        let customKinds: [Record] = [.face, .body, .hair]
        if customKinds.contains(where: { recordEdits[$0] != nil }) {
            guard let custom = block(named: "Custom"), custom.version == "0.0.0" else { throw cardEditError("Unsupported Custom block.") }
            var reader = try CardReader(custom.data), result = Data()
            for record in customKinds {
                let old = try reader.lengthPrefixedData()
                let new = try recordEdits[record].map { try Self.editRecord(old, version: record == .hair ? "0.0.4" : "0.0.2", edits: $0) } ?? old
                result += cardLengthData(new)
            }
            guard reader.remaining == 0 else { throw cardEditError("Unexpected Custom record trailer.") }
            if result != custom.data { replacements["Custom"] = result }
        }
        let coordinateIndices = Set(recordEdits.keys.compactMap { record -> Int? in
            switch record { case .clothes(let index), .accessory(let index), .makeup(let index): return index; default: return nil }
        })
        if !coordinateIndices.isEmpty {
            guard let block = block(named: "Coordinate"), block.version == "0.0.0" else { throw cardEditError("Unsupported Coordinate block.") }
            let tokens = try CardTokenDocument(block.data)
            guard tokens.root.kind == .array, tokens.root.children.count <= 64 else { throw cardEditError("Coordinate list is not a bounded array.") }
            var patches: [CardBytePatch] = []
            for index in coordinateIndices.sorted() {
                guard tokens.root.children.indices.contains(index) else { throw cardEditError("Coordinate index is unavailable.") }
                let token = tokens.root.children[index]
                guard case .binary(let bytes) = try tokens.value(token) else { throw cardEditError("Coordinate entry is not binary.") }
                var reader = try CardReader(bytes), new = Data()
                let clothes = try reader.lengthPrefixedData(), accessory = try reader.lengthPrefixedData()
                let enabled = try reader.take(1), makeup = try reader.lengthPrefixedData()
                guard reader.remaining == 0 else { throw cardEditError("Unexpected Coordinate record trailer.") }
                for (record, original, version) in [(Record.clothes(coordinate: index), clothes, "0.0.1"), (.accessory(coordinate: index), accessory, "0.0.2")] {
                    new += cardLengthData(try recordEdits[record].map { try Self.editRecord(original, version: version, edits: $0) } ?? original)
                }
                new += enabled
                new += cardLengthData(try recordEdits[.makeup(coordinate: index)].map { try Self.editRecord(makeup, version: "0.0.0", edits: $0) } ?? makeup)
                if new != bytes { patches.append(.init(range: token.range, replacement: cardBinary(new))) }
            }
            let updated = try tokens.applying(patches)
            if updated != block.data { replacements["Coordinate"] = updated }
        }
        if edits.coordinateType != nil || edits.clothesState != nil || edits.showAccessory != nil || edits.shoesType != nil || !edits.faceState.isEmpty,
           let status = try editedStatus(coordinate: edits.coordinateType, clothesState: edits.clothesState, showAccessory: edits.showAccessory,
                                         shoesType: edits.shoesType, face: edits.faceState) {
            replacements["Status"] = status
        }
        let thumbnail = try Self.editedPNG(edits.thumbnailData, original: thumbnailData)
        let faceThumbnail = try Self.editedPNG(edits.faceThumbnailData, original: faceThumbnailData)
        if replacements.isEmpty && thumbnail == thumbnailData && faceThumbnail == faceThumbnailData { return preservedData }
        let verified = try replacingBlocks(replacements, thumbnail: thumbnail, faceThumbnail: faceThumbnail)
        let result = verified.preservedData
        if let face = edits.faceValues, try verified.customization().faceValues != face { throw cardEditError("Face edit verification failed.") }
        if let body = edits.bodyValues, try verified.customization().bodyValues != body { throw cardEditError("Body edit verification failed.") }
        if let coordinate = edits.coordinateType, try verified.savedCoordinateType() != coordinate { throw cardEditError("Outfit edit verification failed.") }
        if edits.clothesState != nil || edits.showAccessory != nil || edits.shoesType != nil {
            let before = try savedStatusWear(), after = try verified.savedStatusWear()
            guard after.clothesState == (edits.clothesState ?? before.clothesState), after.shoesType == (edits.shoesType ?? before.shoesType),
                  after.showAccessory == (edits.showAccessory ?? before.showAccessory) else {
                throw cardEditError("Clothes state, accessory visibility or shoes type edit verification failed.")
            }
        }
        if !edits.faceState.isEmpty {
            let before = try savedStatusFace(), after = try verified.savedStatusFace(), face = edits.faceState
            let expected = StatusFace(eyebrowPtn: face.eyebrowPtn ?? before.eyebrowPtn, eyesPtn: face.eyesPtn ?? before.eyesPtn,
                mouthPtn: face.mouthPtn ?? before.mouthPtn, eyesOpenMax: face.eyesOpenMax ?? before.eyesOpenMax,
                eyesBlink: face.eyesBlink ?? before.eyesBlink, eyesLookPtn: face.eyesLookPtn ?? before.eyesLookPtn,
                neckLookPtn: face.neckLookPtn ?? before.neckLookPtn, tearsLv: face.tearsLv ?? before.tearsLv,
                hohoAkaRate: face.hohoAkaRate ?? before.hohoAkaRate)
            guard after.eyebrowPtn == expected.eyebrowPtn, after.eyesPtn == expected.eyesPtn, after.mouthPtn == expected.mouthPtn,
                  after.eyesOpenMax.bitPattern == expected.eyesOpenMax.bitPattern, after.eyesBlink == expected.eyesBlink,
                  after.eyesLookPtn == expected.eyesLookPtn, after.neckLookPtn == expected.neckLookPtn,
                  after.tearsLv == expected.tearsLv, after.hohoAkaRate.bitPattern == expected.hohoAkaRate.bitPattern else {
                throw cardEditError("Face-state edit verification failed.")
            }
        }
        if let original = block(named: "Status"), let edited = verified.block(named: "Status"), original.data != edited.data {
            // Every Status field other than the edited ones must decode
            // exactly as saved (the byte patches cannot reach them).
            var old = try SourceMessagePack.decode(original.data).stringKeyedMap(), new = try SourceMessagePack.decode(edited.data).stringKeyedMap()
            for key in ["coordinateType", "backCoordinateType", "clothesState", "showAccessory"] + (edits.shoesType != nil ? ["shoesType"] : []) + edits.faceState.editedKeys { old[key] = nil; new[key] = nil }
            guard old == new else { throw cardEditError("Unedited Status field preservation verification failed.") }
        }
        guard verified.trailingData == trailingData else { throw cardEditError("Trailer preservation verification failed.") }
        for block in blocks where replacements[block.name] == nil {
            guard verified.block(named: block.name)?.data == block.data else { throw cardEditError("Unedited block preservation verification failed.") }
        }
        return result
    }

    /// Shared original framing writer. Callers supply only surgically edited
    /// blocks; unedited payloads and their raw tokens are never re-encoded.
    func replacingBlocks(_ replacements: [String: Data], thumbnail: Data? = nil,
                         faceThumbnail: Data? = nil, trailer: Data? = nil) throws -> Self {
        let thumbnail = thumbnail ?? thumbnailData, faceThumbnail = faceThumbnail ?? faceThumbnailData
        let trailer = trailer ?? trailingData
        guard replacements.keys.allSatisfy({ block(named: $0) != nil }) else {
            throw cardEditError("Cannot replace an absent card block.")
        }
        if replacements.isEmpty && thumbnail == thumbnailData && faceThumbnail == faceThumbnailData && trailer == trailingData { return self }

        // For non-contiguous payloads the installed Extended Save hook seeks
        // from payloadEnd - sum(sizes). Its target can overlap other blocks.
        // Changing such a layout could alter which plug-in bytes are selected.
        if !replacements.isEmpty, block(named: "KKEx") != nil,
           blocks.reduce(0, { $0 + $1.data.count }) != payloadSize {
            throw cardEditError("Cannot edit a gapped payload with Extended Save; its source hook uses ambiguous offsets.")
        }
        let originalPayload = preservedData.subdata(in: payloadOffset..<(payloadOffset + payloadSize))
        let ordered = blocks.sorted { $0.position < $1.position }
        var cursor = 0, payload = Data(), newPositions: [String: Int] = [:]
        for block in ordered where !block.data.isEmpty {
            guard block.position >= cursor else { throw cardEditError("Overlapping payload records.") }
            payload += originalPayload.subdata(in: cursor..<block.position)
            newPositions[block.name] = payload.count
            payload += replacements[block.name] ?? block.data
            cursor = block.position + block.data.count
        }
        payload += originalPayload.subdata(in: cursor..<originalPayload.count)
        for block in ordered where block.data.isEmpty {
            guard !ordered.contains(where: { replacements[$0.name] != nil && $0.position < block.position && block.position < $0.position + $0.data.count }) else {
                throw cardEditError("An empty block points inside a modified block.")
            }
            let shift = ordered.filter { !$0.data.isEmpty && $0.position + $0.data.count <= block.position }
                .reduce(0) { $0 + (replacements[$1.name]?.count ?? $1.data.count) - $1.data.count }
            newPositions[block.name] = block.position + shift
        }
        let header = try CardTokenDocument(headerData)
        let info = try header.node(at: [.key("lstInfo")])
        guard info.kind == .array, info.children.count == blocks.count else { throw cardEditError("Block header changed unexpectedly.") }
        var patches: [CardBytePatch] = []
        for (index, block) in blocks.enumerated() {
            for (key, next, old) in [("pos", newPositions[block.name]!, block.position), ("size", replacements[block.name]?.count ?? block.data.count, block.data.count)] where next != old {
                patches.append(.init(range: try header.node(at: [.key("lstInfo"), .index(index), .key(key)]).range, replacement: cardInteger(next)))
            }
        }
        let newHeader = try header.applying(patches)
        guard newHeader.count <= 1024 * 1024 else { throw cardEditError("Edited header exceeds 1 MiB.") }
        let headerLengthOffset = payloadOffset - 8 - headerData.count - 4
        let faceLengthOffset = headerLengthOffset - faceThumbnailData.count - 4
        var result = thumbnail + preservedData.subdata(in: thumbnailData.count..<faceLengthOffset)
        result += cardLengthData(faceThumbnail) + cardLengthData(newHeader) + cardLittle(UInt64(payload.count), count: 8) + payload + trailer
        let verified = try Self.decode(result)
        guard verified.trailingData == trailer else { throw cardEditError("Trailer replacement verification failed.") }
        for block in blocks where replacements[block.name] == nil {
            guard verified.block(named: block.name)?.data == block.data else { throw cardEditError("Unedited block preservation verification failed.") }
        }
        return verified
    }

    /// CharaStudio's outfit buttons (MPCharCtrl.StateInfo.OnClickCosType ->
    /// OCIChar.SetCoordinateInfo) call ChaControl.ChangeCoordinateType(type,
    /// changeBackCoordinateType: true): it copies chaFile.coordinate[type]
    /// into the runtime nowCoordinate (returning false, changing nothing, when
    /// the card has no such entry), then writes backCoordinateType = the old
    /// coordinateType and coordinateType = type. The scene save serializes
    /// ChaFile.status as this block; no Coordinate record changes. Loading a
    /// scene forces the same call with the saved index (AddObjectAssist.
    /// UpdateState), so after one change from the loaded outfit the original
    /// holds backCoordinateType = the saved coordinateType; that is what is
    /// written here. A chain of changes (A -> B -> C stores back = B) is not
    /// reproduced, and nothing in the recovered Studio/ChaControl code reads
    /// backCoordinateType. A changed integer is written in the compact
    /// positive-fixint form MessagePack-CSharp uses for 0...6.
    ///
    /// The clothes-state buttons (MPCharCtrl.StateInfo.OnClickClothingDetails
    /// -> OCIChar.SetClothesState -> ChaControl.SetClothesState) and the
    /// accessory toggles (OnClickAccessories -> OCIChar.ShowAccessory) write
    /// ChaFileStatus.clothesState[kind] / showAccessory[slot], which the
    /// scene save serializes in the same block: the 9-byte bin payload (or,
    /// for a card that spells it as an array, the nine fixint members) and
    /// the 20 bool tokens are patched in place (same header, same length), so
    /// no other byte of the block moves. A wear field the card does not save
    /// is appended after the last entry (bin 9 / array16 of 20 bools, the
    /// MessagePack-CSharp forms) and only the map count changes. Returns nil
    /// (no bytes change) when every requested field already holds the saved
    /// value.
    ///
    /// The State panel's face-state controls (`StatusFaceEdit`, ST-C04) write
    /// ChaFileStatus scalars the scene save serializes in the same block: a
    /// changed field's existing token is replaced by the compact
    /// MessagePack-CSharp form (positive fixint/uint for the ints and the
    /// byte, float32 0xca for the rates, c2/c3 for the bool); every other
    /// byte stays. A face field the card does not save is appended only when
    /// the edit moves it off its ChaFileStatus.MemberInit default.
    private func editedStatus(coordinate: Int?, clothesState: [UInt8]?, showAccessory: [Bool]?, shoesType: Int? = nil,
                              face: StatusFaceEdit = StatusFaceEdit()) throws -> Data? {
        if let coordinate {
            guard (0..<7).contains(coordinate) else { throw cardEditError("Outfit index must be in 0...6.") }
        }
        if let clothesState {
            guard clothesState.count == 9, clothesState.allSatisfy({ $0 <= 3 }) else {
                throw cardEditError("Clothes state must be nine ClothesKind values, each in 0...3.")
            }
        }
        if let showAccessory, showAccessory.count != 20 { throw cardEditError("Accessory visibility must contain exactly 20 slot flags.") }
        if let shoesType, !(0...1).contains(shoesType) { throw cardEditError("Status.shoesType must be 0 (indoor) or 1 (outdoor).") }
        try Self.validate(face)
        let scalars = Self.faceTokens(face) + (shoesType.map { [(key: "shoesType", value: StatusScalar.integer($0), memberInit: StatusScalar.integer(StatusWear.memberInit.shoesType))] } ?? [])
        let changeCoordinate = try coordinate.map { try savedCoordinateType() != $0 } ?? false
        if changeCoordinate, let coordinate, try coordinateCount() <= coordinate { throw cardEditError("The card has no saved outfit \(coordinate).") }
        guard let status = block(named: "Status"), status.version == "0.0.0" else {
            if !changeCoordinate, clothesState.map({ $0 == StatusWear.memberInit.clothesState }) ?? true,
               showAccessory.map({ $0 == StatusWear.memberInit.showAccessory }) ?? true,
               scalars.allSatisfy({ $0.value == $0.memberInit }) { return nil }
            throw cardEditError("Unsupported or missing Status block.")
        }
        let tokens = try CardTokenDocument(status.data)
        let fields = try SourceMessagePack.decode(status.data).stringKeyedMap()
        var patches: [CardBytePatch] = []
        if changeCoordinate, let coordinate {
            let current = try tokens.node(at: [.key("coordinateType")])
            guard current.kind == .scalar, let saved = try tokens.value(current).integerValue, (0..<7).contains(saved) else {
                throw cardEditError("Saved Status.coordinateType is not an outfit index in 0...6.")
            }
            patches.append(CardBytePatch(range: current.range, replacement: Data([UInt8(coordinate)])))
            if fields["backCoordinateType"] != nil {
                let back = try tokens.node(at: [.key("backCoordinateType")])
                guard back.kind == .scalar, let previous = try tokens.value(back).integerValue else {
                    throw cardEditError("Saved Status.backCoordinateType is not an integer.")
                }
                if previous != saved { patches.append(.init(range: back.range, replacement: Data([UInt8(saved)]))) }
            }
        }
        let saved = try StatusWear(status: fields)
        // A field the card does not save (its MemberInit default applies) is
        // appended to the root map in the form MessagePack-CSharp writes, the
        // map count is raised, and no existing byte changes.
        var appended = Data(), appendedCount = 0
        if let clothesState, clothesState != saved.clothesState {
            if fields["clothesState"] == nil {
                appended += Data([0xac]) + Data("clothesState".utf8) + Data([0xc4, 0x09]) + Data(clothesState); appendedCount += 1
            } else {
                let node = try tokens.node(at: [.key("clothesState")])
                if node.kind == .array {
                    guard node.children.count == 9 else { throw cardEditError("Saved Status.clothesState is not the 9-byte ClothesKind array.") }
                    for (child, value) in zip(node.children, clothesState) {
                        guard child.kind == .scalar, child.range.count == 1, let old = try tokens.value(child).integerValue, (0...3).contains(old) else {
                            throw cardEditError("Saved Status.clothesState array members must be positive fixints 0...3.")
                        }
                        if old != Int(value) { patches.append(.init(range: child.range, replacement: Data([value]))) }
                    }
                } else {
                    guard node.kind == .scalar, case .binary(let bytes) = try tokens.value(node), bytes.count == 9, node.range.count > 9 else {
                        throw cardEditError("Saved Status.clothesState is not the 9-byte ClothesKind array.")
                    }
                    patches.append(.init(range: (node.range.upperBound - 9)..<node.range.upperBound, replacement: Data(clothesState)))
                }
            }
        }
        if let showAccessory, showAccessory != saved.showAccessory, fields["showAccessory"] == nil {
            appended += Data([0xad]) + Data("showAccessory".utf8) + Data([0xdc, 0x00, 0x14]) + Data(showAccessory.map { $0 ? 0xc3 : 0xc2 })
            appendedCount += 1
        } else if let showAccessory, showAccessory != saved.showAccessory {
            let node = try tokens.node(at: [.key("showAccessory")])
            guard node.kind == .array, node.children.count == 20 else {
                throw cardEditError("Saved Status.showAccessory is not the 20-slot bool array.")
            }
            for (child, flag) in zip(node.children, showAccessory) {
                guard child.kind == .scalar, child.range.count == 1, case .bool(let old) = try tokens.value(child) else {
                    throw cardEditError("Saved Status.showAccessory has a non-bool member.")
                }
                if old != flag { patches.append(.init(range: child.range, replacement: Data([flag ? 0xc3 : 0xc2]))) }
            }
        }
        // The face-state scalars and shoesType share the scalar token path.
        for token in scalars {
            guard fields[token.key] != nil else {
                // Absent: the MemberInit default applies, so only a value off
                // that default needs the field.
                if token.value != token.memberInit {
                    appended += Data([0xa0 | UInt8(token.key.utf8.count)]) + Data(token.key.utf8) + token.value.encoded
                    appendedCount += 1
                }
                continue
            }
            let node = try tokens.node(at: [.key(token.key)])
            guard node.kind == .scalar else { throw cardEditError("Saved Status.\(token.key) is not a scalar.") }
            let saved = try tokens.value(node)
            if try token.value.matches(saved, key: token.key) { continue }
            patches.append(.init(range: node.range, replacement: token.value.encoded))
        }
        if appendedCount > 0 {
            guard tokens.root.kind == .map, tokens.root.range == 0..<status.data.count else { throw cardEditError("Status block is not one MessagePack map.") }
            let count = tokens.root.children.count / 2, header = status.data[status.data.startIndex]
            let next = count + appendedCount
            switch header {
            case 0x80...0x8f:
                patches.append(.init(range: 0..<1, replacement: next <= 15 ? Data([0x80 | UInt8(next)]) : Data([0xde]) + cardBig(UInt64(next), count: 2)))
            case 0xde:
                guard next <= 0xffff else { throw cardEditError("Status map is too large.") }
                patches.append(.init(range: 0..<3, replacement: Data([0xde]) + cardBig(UInt64(next), count: 2)))
            case 0xdf:
                patches.append(.init(range: 0..<5, replacement: Data([0xdf]) + cardBig(UInt64(next), count: 4)))
            default: throw cardEditError("Status block is not one MessagePack map.")
            }
            patches.append(.init(range: status.data.count..<status.data.count, replacement: appended))
        }
        guard !patches.isEmpty else { return nil }
        let result = try tokens.applying(patches)
        _ = try SourceMessagePack.decode(result)
        return result
    }

    /// One face-state Status scalar in MessagePack-CSharp form.
    private enum StatusScalar: Equatable {
        case integer(Int), rate(Float), flag(Bool)
        var encoded: Data {
            switch self {
            case .integer(let value):
                switch value {
                case 0...0x7f: return Data([UInt8(value)])
                case 0x80...0xff: return Data([0xcc, UInt8(value)])
                case 0x100...0xffff: return Data([0xcd]) + cardBig(UInt64(value), count: 2)
                default: return Data([0xce]) + cardBig(UInt64(value), count: 4)
                }
            case .rate(let value): return Data([0xca]) + cardBig(UInt64(value.bitPattern), count: 4)
            case .flag(let value): return Data([value ? 0xc3 : 0xc2])
            }
        }
        /// True when the saved token already holds this value (a float32
        /// compare for rates, so a float64 or integer spelling of the same
        /// float32 is kept); a token of the wrong type is rejected.
        func matches(_ saved: SourceMessagePackValue, key: String) throws -> Bool {
            switch self {
            case .integer(let value):
                guard let old = saved.integerValue else { throw cardEditError("Saved Status.\(key) is not an integer.") }
                return old == value
            case .rate(let value):
                let old: Double
                switch saved {
                case .float(let number): old = number
                case .integer(let number): old = Double(number)
                case .unsigned(let number): old = Double(number)
                default: throw cardEditError("Saved Status.\(key) is not a number.")
                }
                return old.isFinite && abs(old) <= Double(Float.greatestFiniteMagnitude) && Float(old).bitPattern == value.bitPattern
            case .flag(let value):
                guard case .bool(let old) = saved else { throw cardEditError("Saved Status.\(key) is not a bool.") }
                return old == value
            }
        }
    }

    private static func faceTokens(_ face: StatusFaceEdit) -> [(key: String, value: StatusScalar, memberInit: StatusScalar)] {
        let initial = StatusFace.memberInit
        var result: [(key: String, value: StatusScalar, memberInit: StatusScalar)] = []
        func int(_ key: String, _ value: Int?, _ standard: Int) { if let value { result.append((key, .integer(value), .integer(standard))) } }
        func rate(_ key: String, _ value: Float?, _ standard: Float) { if let value { result.append((key, .rate(value), .rate(standard))) } }
        int("eyebrowPtn", face.eyebrowPtn, initial.eyebrowPtn)
        int("eyesPtn", face.eyesPtn, initial.eyesPtn)
        rate("eyesOpenMax", face.eyesOpenMax, initial.eyesOpenMax)
        if let blink = face.eyesBlink { result.append(("eyesBlink", .flag(blink), .flag(initial.eyesBlink))) }
        int("mouthPtn", face.mouthPtn, initial.mouthPtn)
        int("eyesLookPtn", face.eyesLookPtn, initial.eyesLookPtn)
        int("neckLookPtn", face.neckLookPtn, initial.neckLookPtn)
        rate("hohoAkaRate", face.hohoAkaRate, initial.hohoAkaRate)
        int("tearsLv", face.tearsLv, initial.tearsLv)
        return result
    }

    private static func validate(_ face: StatusFaceEdit) throws {
        for (key, value) in [("eyebrowPtn", face.eyebrowPtn), ("eyesPtn", face.eyesPtn), ("mouthPtn", face.mouthPtn),
                             ("eyesLookPtn", face.eyesLookPtn), ("neckLookPtn", face.neckLookPtn)] {
            if let value, !(0...Int(Int32.max)).contains(value) { throw cardEditError("Status.\(key) must be a nonnegative pattern number.") }
        }
        if let level = face.tearsLv, !(0...3).contains(level) { throw cardEditError("Status.tearsLv must be in 0...3.") }
        for (key, value) in [("eyesOpenMax", face.eyesOpenMax), ("hohoAkaRate", face.hohoAkaRate)] {
            if let value, !(value.isFinite && (0...1).contains(value)) { throw cardEditError("Status.\(key) must be finite and in 0...1.") }
        }
    }

    private static func editRecord(_ data: Data, version: String, edits: [CardNumericEdit]) throws -> Data {
        let tokens = try CardTokenDocument(data)
        guard try tokens.value(tokens.node(at: [.key("version")])).stringValue == version else { throw cardEditError("Unsupported editable record version.") }
        var patches: [CardBytePatch] = [], targets = Set<Range<Int>>()
        for edit in edits {
            let array = try tokens.node(at: edit.path)
            guard array.kind == .array, array.children.count == edit.values.count else { throw cardEditError("Editable numeric array has an unexpected size.") }
            for (node, next) in zip(array.children, edit.values) {
                guard targets.insert(node.range).inserted else { throw cardEditError("Overlapping numeric edits.") }
                let value = try tokens.value(node), old: Double
                switch value {
                case .float(let number): old = number
                case .integer(let number): old = Double(number)
                case .unsigned(let number): old = Double(number)
                default: throw cardEditError("Editable array contains a nonnumeric member.")
                }
                guard old.isFinite, abs(old) <= Double(Float.greatestFiniteMagnitude) else { throw cardEditError("Editable array contains a nonfinite float32.") }
                // Existing float64/int tokens are retained when they represent
                // the same float32 source value, including signed zero.
                if Float(old).bitPattern != next.bitPattern {
                    patches.append(.init(range: node.range, replacement: Data([0xca]) + cardBig(UInt64(next.bitPattern), count: 4)))
                }
            }
        }
        let result = try tokens.applying(patches)
        _ = try SourceMessagePack.decode(result)
        return result
    }
    private static func validateNumbers(_ values: [Float], count: Int) throws {
        guard values.count == count, values.allSatisfy(\.isFinite) else { throw cardEditError("Edited values must contain exactly \(count) finite float32 numbers.") }
    }
    private static func editedPNG(_ candidate: Data?, original: Data) throws -> Data {
        guard let candidate else { return original }
        if candidate.isEmpty { return candidate }
        var reader = try CardReader(candidate)
        let png = try reader.pngIfPresent()
        guard !png.isEmpty, reader.remaining == 0 else { throw cardEditError("Replacement thumbnail must be exactly one PNG.") }
        return png
    }
}

private struct CardNumericEdit {
    let path: [SourceCharacterCard.Field], values: [Float]
}
func cardEditError(_ message: String) -> SourceCharacterCardError { .invalid(message) }
func cardLittle(_ bits: UInt64, count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }) }
func cardBig(_ bits: UInt64, count: Int) -> Data { Data(cardLittle(bits, count: count).reversed()) }
func cardLengthData(_ data: Data) -> Data { cardLittle(UInt64(data.count), count: 4) + data }
func cardInteger(_ number: Int) -> Data { Data([0xd3]) + cardBig(UInt64(number), count: 8) }
func cardBinary(_ data: Data) -> Data { Data([0xc6]) + cardBig(UInt64(data.count), count: 4) + data }
