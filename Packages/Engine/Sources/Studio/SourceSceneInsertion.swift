import Foundation

/// ST-T03 / ST-S09 / ST-D03: one record added to an exported original
/// CharaStudio 1.0.4.2 scene, following the recovered operations
/// (docs/reference/studio/scene-editing.md, "Duplicates and added records"):
///
/// - `Studio.Duplicate` saves the selected record with `SceneInfo.Save` and
///   reads it back with `SceneInfo.Import`, so the copy has the original's
///   record bytes under new keys (`GetNewIndex`, the smallest free key, for
///   the record and every sub-info: FK bones, IK targets, the look-at
///   target). `OnLoadAttach` appends the copy to its original's parent list
///   (the same accessory group for a character's child) with the same local
///   `ChangeAmount` and name. A camera copy is written inactive here; the
///   caller sets the look-through flags explicitly (`cameraActive`).
/// - `AddObjectFolder/Camera/Light.Add` create a record at the root with
///   `GetNewIndex` and the constructor defaults (`Record`, `Header`).
///
/// - A route copy (ST-T11) is the route's bytes too: `OIRouteInfo.Load`
///   reads its points with `_import: false`, so `SetNewIndex` finds each
///   point and aid key taken by the original and allocates a new one after
///   the copy's children (point, aid, point, aid, ...). `OCIRoute.
///   OnLoadAttach` parents a copied route child under `childRoot` with
///   `worldPositionStays: false`, keeping its saved local placement, and the
///   copy keeps the route's saved `active` (the caller writes the play
///   state with `routeActive`). A copy inside a route's subtree stays in its
///   template's list or the copy of it.
///
/// A duplicate carries only its template's own bytes: the template's
/// children are not copied with it. A copied subtree is one insertion per
/// copied record, each under the copy of its parent, so a copy whose child
/// was deleted, or whose children were rearranged, is written as the
/// document shows it.
public struct SourceSceneInsertion: Sendable, Equatable {
    /// The header every new record starts with: `ObjectInfo` defaults
    /// (zero position and rotation, unit scale, `TreeState.Close`, visible)
    /// unless the caller places it.
    public struct Header: Sendable, Equatable {
        public var transform: KoikatsuChangeAmount
        public var treeState: Int32
        public var visible: Bool
        public init(transform: KoikatsuChangeAmount = .init(position: .zero, rotationDegrees: .zero, scale: .one),
                    treeState: Int32 = 1, visible: Bool = true) {
            self.transform = transform; self.treeState = treeState; self.visible = visible
        }
    }
    public enum Record: Sendable, Equatable {
        /// A copy of source record `of`'s own bytes (header, name, card,
        /// pose, item and light data) under new keys. Its children are the
        /// insertions placed under it.
        case duplicate(of: Int32)
        /// `OIFolderInfo`: CharaStudio names a new folder "フォルダー".
        case folder(name: String, header: Header = .init())
        /// `OICameraInfo`: CharaStudio names a new camera "カメラ" followed
        /// by its session camera count; it is written inactive.
        case camera(name: String, header: Header = .init())
        /// `OILightInfo` with the light's own fields.
        case light(SourceSceneNewLight, header: Header = .init())
    }
    public enum Parent: Sendable, Equatable {
        /// The root dictionary, keyed by the record's own key (`Studio.AddInfo`).
        case root
        /// A source record's child list.
        case source(Int32)
        /// An earlier insertion's child list, by its index.
        case inserted(Int)
    }
    public var record: Record
    public var parent: Parent
    /// The accessory point for a character parent's child, else nil.
    public var attachment: Int32?
    public init(_ record: Record, parent: Parent = .root, attachment: Int32? = nil) {
        self.record = record; self.parent = parent; self.attachment = attachment
    }
}

/// A new `OILightInfo` record. `no` is the `Light_00` catalog entry
/// (abdata/studio/info/00.unity3d): 0 directional, 1 point, 2 spot. The
/// defaults are the constructor's (`OILightInfo(int, int)`).
public struct SourceSceneNewLight: Sendable, Equatable {
    public var no: Int32
    public var color: SIMD4<Float>
    public var intensity: Float, range: Float, spotAngle: Float
    public var shadow: Bool, enable: Bool, drawTarget: Bool
    public init(no: Int32, color: SIMD4<Float> = .one, intensity: Float = 1, range: Float = 10, spotAngle: Float = 30,
                shadow: Bool = true, enable: Bool = true, drawTarget: Bool = true) {
        self.no = no; self.color = color; self.intensity = intensity; self.range = range; self.spotAngle = spotAngle
        self.shadow = shadow; self.enable = enable; self.drawTarget = drawTarget
    }
}

/// The scene with every insertion written and verified, before the leaf and
/// topology edits that `editedData` applies to it. `keys[i]` is the key
/// allocated to insertion `i`; edits address inserted records by it.
public struct SourceSceneStage: Sendable {
    public let document: KoikatsuSceneDocument
    public let keys: [Int32]
    /// Whether an insertion adds a light record.
    let addsLights: Bool
    /// The scene before the insertions, and each copy's key mapped to its
    /// template's: the plug-in data rewrite follows copies from them
    /// (`SourceScenePluginData`).
    let source: KoikatsuSceneDocument
    let copies: [Int32: Int32]

    /// The final scene: `edits` (leaf edits keyed by stage keys, deletions
    /// and moves) applied to the staged document. Inserted lights must leave
    /// at most two lights: CharaStudio drops a nested light once two exist
    /// (`SceneInfo.isLightCheck`), so a third would not reload.
    public func editedData(_ edits: SourceSceneEdits) throws -> Data {
        guard edits.insertions.isEmpty else {
            throw SourceSceneTopologyError.unsupported("The staged scene already carries its insertions.")
        }
        if addsLights {
            let deleted = edits.deletions.isEmpty && edits.reparents.isEmpty ? []
                : try SourceSceneTopology.plan(document.snapshot, deletions: edits.deletions, reparents: edits.reparents).deleted
            let lights = SourceSceneInsertionPlan.records(document.snapshot).filter { $0.kind == .light && !deleted.contains($0.sourceKey) }
            guard lights.count <= 2 else {
                throw SourceSceneTopologyError.unsupported("CharaStudio keeps at most two lights (SceneInfo.isLightCheck); the edited scene would have \(lights.count).")
            }
        }
        return try document.editedData(edits, source: source, copies: copies)
    }
}

public extension KoikatsuSceneDocument {
    /// Writes `insertions` (parents before children) into a copy of this
    /// scene and decodes it. Every original record keeps its bytes and key;
    /// each changed child list gets its new count. Refuses, with the reason,
    /// anything it cannot place exactly as CharaStudio would.
    func inserting(_ insertions: [SourceSceneInsertion]) throws -> SourceSceneStage {
        guard !insertions.isEmpty else { return SourceSceneStage(document: self, keys: [], addsLights: false, source: self, copies: [:]) }
        guard insertions.count <= 100_000 else { throw KoikatsuReadError.limitExceeded("too many scene insertions") }
        let plan = try SourceSceneInsertionPlan(self, insertions)
        let data = try plan.emit()
        let staged = try KoikatsuSceneReader.decodeDocument(data)
        try plan.verify(staged)
        var copies: [Int32: Int32] = [:]
        for (index, insertion) in insertions.enumerated() {
            if case .duplicate(let template) = insertion.record { copies[plan.keys[index]] = template }
        }
        // Plug-in data follows the copies when the final scene is written
        // (`SourceSceneStage.editedData`); the stage keeps the source trailer.
        return SourceSceneStage(document: staged, keys: plan.keys, addsLights: plan.addsLights, source: self, copies: copies)
    }
}

struct SourceSceneInsertionPlan {
    typealias ListID = SourceSceneTopology.Tree.ListID
    let source: KoikatsuSceneDocument
    let insertions: [SourceSceneInsertion]
    let tree: SourceSceneTopology.Tree
    let spans: SourceSceneEditSpans
    let rootCount: Int
    /// Insertions appended to each source list, in order.
    var appended: [ListID: [Int]] = [:]
    /// Each insertion's children: by accessory point for a character copy.
    var children: [[Int]]
    var keys: [Int32] = []
    var addsLights = false
    /// Source records with an insertion somewhere below them.
    var touched = Set<Int32>()
    /// Whether each insertion is a route or lies inside a route's subtree.
    private var routeScope: [Bool] = []

    /// Every record of a snapshot, depth first.
    static func records(_ snapshot: KoikatsuSceneSnapshot) -> [KoikatsuObjectRecord] {
        var result: [KoikatsuObjectRecord] = []
        func visit(_ record: KoikatsuObjectRecord) {
            result.append(record)
            for child in record.children { visit(child) }
            for point in (record.character?.accessoryChildren ?? [:]).keys.sorted() {
                for child in record.character!.accessoryChildren[point]! { visit(child) }
            }
        }
        for root in snapshot.roots { visit(root) }
        return result
    }

    /// Every key CharaStudio's `SceneInfo.hashIndex` holds after loading the
    /// scene: object records and every sub-info (`ObjectInfo.Load` and the
    /// sub-info loads call `SetNewIndex` with each).
    static func usedKeys(_ snapshot: KoikatsuSceneSnapshot) -> [Int32] {
        var keys: [Int32] = []
        for record in records(snapshot) {
            keys.append(record.sourceKey)
            if let character = record.character {
                keys += character.bones.values.map(\.sourceKey) + character.ikTargets.values.map(\.sourceKey)
                keys.append(character.lookAtTarget.sourceKey)
            }
            keys += (record.item?.bones.values.map(\.sourceKey) ?? [])
            for point in record.route?.points ?? [] { keys += [point.bone.sourceKey, point.aid.sourceKey] }
        }
        return keys
    }

    init(_ source: KoikatsuSceneDocument, _ insertions: [SourceSceneInsertion]) throws {
        self.source = source; self.insertions = insertions
        tree = SourceSceneTopology.Tree(source.snapshot)
        var reader = try KoikatsuBinaryReader(source.preservedData)
        try reader.skipPNG()
        guard try reader.string() == source.snapshot.version else { throw reader.invalid("scene version differs from its decoded document") }
        rootCount = reader.offset
        for _ in 0..<(try reader.count()) { _ = try reader.object(depth: 0, rootKey: try reader.int32()) }
        guard reader.offset == source.snapshot.objectSectionEndOffset else { throw reader.invalid("scene object byte spans differ from the decoded document") }
        spans = reader.editSpans
        children = Array(repeating: [], count: insertions.count)
        try place()
        allocate()
    }

    private func fail(_ reason: String) -> SourceSceneTopologyError { .unsupported(reason) }

    /// Whether `key` is a route or lies inside a route's subtree.
    private func inRoute(_ key: Int32) -> Bool {
        var current: Int32? = key
        while let next = current {
            if tree.records[next]?.kind == .route { return true }
            current = tree.parent[next] ?? nil
        }
        return false
    }

    /// The record kind an insertion writes.
    private func kind(_ index: Int) -> KoikatsuObjectKind {
        switch insertions[index].record {
        case .duplicate(let key): return tree.records[key]?.kind ?? .folder
        case .folder: return .folder
        case .camera: return .camera
        case .light: return .light
        }
    }

    /// Validates every insertion and records where it goes.
    private mutating func place() throws {
        for (index, insertion) in insertions.enumerated() {
            let what: String
            var template: Int32?
            switch insertion.record {
            case .duplicate(let key):
                guard let record = tree.records[key] else { throw fail("Original-scene export cannot duplicate unknown source object \(key).") }
                guard record.kind != .route || record.route?.points.isEmpty == false else {
                    throw fail("Original-scene export does not duplicate route \(key): it has no points, and CharaStudio adds a start point when it loads one.")
                }
                if record.kind == .light { addsLights = true }
                what = "the copy of source object \(key)"; template = key
            case .folder(let name, let header):
                try Self.check(header); _ = try KoikatsuBinaryReader.dotNetString(name); what = "a new folder"
            case .camera(let name, let header):
                try Self.check(header); _ = try KoikatsuBinaryReader.dotNetString(name); what = "a new camera"
            case .light(let light, let header):
                try Self.check(header)
                guard (0...2).contains(light.no) else {
                    throw fail("A new light's catalog number must be 0 (directional), 1 (point) or 2 (spot) (Light_00); got \(light.no).")
                }
                guard (0..<4).allSatisfy({ light.color[$0].isFinite }), light.intensity.isFinite, light.intensity >= 0,
                      light.range.isFinite, light.range > 0, light.spotAngle.isFinite, light.spotAngle > 0, light.spotAngle < 180 else {
                    throw fail("A new light needs a finite color, a nonnegative intensity, a positive range and a spot angle between 0 and 180 degrees.")
                }
                addsLights = true; what = "a new light"
            }
            // The parent list and the kind of record that owns it.
            let ownerKind: KoikatsuObjectKind?, owner: String
            var copyOf: Int32?
            switch insertion.parent {
            case .root:
                ownerKind = nil; owner = "the root"
            case .source(let key):
                guard let record = tree.records[key] else { throw fail("Original-scene export cannot add \(what) under unknown source object \(key).") }
                ownerKind = record.kind; owner = "source object \(key)"
            case .inserted(let parent):
                guard parent >= 0, parent < index else {
                    throw fail("Insertion \(index) names insertion \(parent) as its parent; list parents before their children.")
                }
                ownerKind = kind(parent); owner = "insertion \(parent)"
                if case .duplicate(let key) = insertions[parent].record { copyOf = key }
            }
            // Whether the new record lands inside a route's subtree (a source
            // route's or a copied route's).
            let parentInRoute: Bool
            switch insertion.parent {
            case .root: parentInRoute = false
            case .source(let key): parentInRoute = inRoute(key)
            case .inserted(let parent): parentInRoute = routeScope[parent]
            }
            routeScope.append(parentInRoute || kind(index) == .route)
            guard template != nil || !parentInRoute else {
                throw fail("Original-scene export does not add objects inside a route's subtree (\(what) under \(owner)).")
            }
            if let ownerKind, ownerKind == .camera || ownerKind == .light {
                throw fail("CharaStudio cameras and lights cannot hold children (enableAddChild = false); \(what) cannot go under \(owner).")
            }
            // A duplicate may also stay in its template's own list (an item's
            // child list or a character's accessory group), or the copy of
            // that list's owner: `OnLoadAttach` appends it there.
            let templateParent = template.flatMap { tree.parent[$0] ?? nil }
            let ownList: Bool = {
                guard let template, let templateParent, insertion.attachment == tree.point[template] else { return false }
                switch insertion.parent {
                case .source(let key): return key == templateParent
                case .inserted: return copyOf == templateParent
                case .root: return false
                }
            }()
            switch ownerKind {
            case nil, .folder?:
                guard insertion.attachment == nil else { throw fail("Only a character's children name an accessory point (\(what) under \(owner)).") }
            case .item?:
                guard ownList else {
                    throw fail("Original-scene export does not add objects under items (\(what) under \(owner)) except a duplicate beside its original: an item's child root may be a named transform inside its prefab (ItemLoadInfo.childRoot) that the converted catalog does not record.")
                }
            case .character?:
                guard ownList else {
                    throw fail("Original-scene export does not add objects onto a character's accessory points (\(what) under \(owner)) except a duplicate beside its original.")
                }
            case .route?:
                guard ownList else {
                    throw fail("Original-scene export does not add objects under routes (\(what) under \(owner)) except a duplicate beside its original or in the copy of its route.")
                }
            case .camera?, .light?: break
            }
            // A copy of a record inside a route's subtree keeps its saved
            // local placement under the moving `childRoot` only in its own
            // list (or the copy of it); anywhere else that placement would
            // follow the route's playback position at the moment of the move.
            if let template, templateParent.map(inRoute) == true, !ownList {
                throw fail("Original-scene export keeps a copy of a route child (source object \(template)) in its route: its saved local placement follows the route's playback position.")
            }
            if case .inserted(let parent) = insertion.parent, case .duplicate(let key) = insertions[parent].record,
               let point = insertion.attachment, !(spans.topology.slots[key] ?? []).contains(where: { $0.point == point }) {
                throw fail("The copy of character \(key) has no accessory group \(point).")
            }
            switch insertion.parent {
            case .root: appended[ListID(owner: nil, point: nil), default: []].append(index)
            case .source(let key):
                appended[ListID(owner: key, point: insertion.attachment), default: []].append(index)
                var current: Int32? = key
                while let next = current, touched.insert(next).inserted { current = tree.parent[next] ?? nil }
            case .inserted(let parent): children[parent].append(index)
            }
        }
    }

    private static func check(_ header: SourceSceneInsertion.Header) throws {
        let t = header.transform
        guard (0..<3).allSatisfy({ t.position[$0].isFinite && t.rotationDegrees[$0].isFinite && t.scale[$0].isFinite }) else {
            throw SourceSceneTopologyError.unsupported("A new record's transform contains a nonfinite component.")
        }
        guard header.treeState == 0 || header.treeState == 1 else {
            throw SourceSceneTopologyError.unsupported("A new record's tree state must be 0 (open) or 1 (closed).")
        }
    }

    /// `SceneInfo.GetNewIndex` in `Import` order: the smallest key not yet
    /// used by the scene, for each record in a depth-first walk of the
    /// insertions (record, its FK bones and IK targets, its children by
    /// accessory group in byte order, then its look-at target).
    private mutating func allocate() {
        var used = Set(Self.usedKeys(source.snapshot)), cursor: Int32 = 0
        var keys = Array(repeating: Int32(-1), count: insertions.count)
        var subKeys: [Int: [Int32]] = [:]
        func next() -> Int32 {
            while used.contains(cursor) { cursor += 1 }
            used.insert(cursor); return cursor
        }
        func visit(_ index: Int) {
            keys[index] = next()
            var sub: [Int32] = []
            if case .duplicate(let key) = insertions[index].record, let template = spans.topology.subKeys[key] {
                for _ in template.before { sub.append(next()) }
                for child in ordered(index) { visit(child) }
                for _ in template.after { sub.append(next()) }
            } else {
                for child in ordered(index) { visit(child) }
            }
            subKeys[index] = sub
        }
        var roots: [Int] = []
        for (index, insertion) in insertions.enumerated() {
            if case .inserted = insertion.parent { continue }
            roots.append(index)
        }
        for root in roots { visit(root) }
        self.keys = keys
        self.allocatedSubKeys = subKeys
    }
    var allocatedSubKeys: [Int: [Int32]] = [:]

    /// An insertion's children in load order: a character copy's by
    /// accessory group in its template's byte order.
    func ordered(_ index: Int) -> [Int] {
        guard case .duplicate(let key) = insertions[index].record, let slots = spans.topology.slots[key],
              slots.contains(where: { $0.point != nil }) else { return children[index] }
        return slots.flatMap { slot in children[index].filter { insertions[$0].attachment == slot.point } }
    }

    // MARK: Bytes

    func emit() throws -> Data {
        let data = source.preservedData, base = data.startIndex
        var result = Data()
        result.reserveCapacity(data.count + 4096)
        func copy(_ range: Range<Int>) throws {
            guard range.lowerBound <= range.upperBound, range.upperBound <= data.count else {
                throw SourceSceneTopologyError.unsupported("Invalid scene record span.")
            }
            result.append(data.subdata(in: (base + range.lowerBound)..<(base + range.upperBound)))
            guard result.count <= 256 * 1024 * 1024 else { throw KoikatsuReadError.limitExceeded("edited scene exceeds 256 MiB") }
        }
        func int32(_ value: Int32) { var bits = value.littleEndian; withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) } }
        func float(_ value: Float) { int32(Int32(bitPattern: value.bitPattern)) }
        func bool(_ value: Bool) { result.append(value ? 1 : 0) }
        func string(_ value: String) throws { result.append(try KoikatsuBinaryReader.dotNetString(value)) }
        func header(_ kind: KoikatsuObjectKind, _ key: Int32, _ header: SourceSceneInsertion.Header) {
            int32(kind.rawValue); int32(key)
            for vector in [header.transform.position, header.transform.rotationDegrees, header.transform.scale] {
                for index in 0..<3 { float(vector[index]) }
            }
            int32(header.treeState); bool(header.visible)
        }
        func original(_ key: Int32, depth: Int) throws {
            guard depth <= 64 else { throw KoikatsuReadError.limitExceeded("hierarchy depth exceeds 64") }
            guard let span = spans.topology.records[key] else { throw SourceSceneTopologyError.unsupported("Scene record \(key) has no byte span.") }
            guard touched.contains(key) else { return try copy(span) }
            var cursor = span.lowerBound
            for slot in spans.topology.slots[key] ?? [] {
                try copy(cursor..<slot.count)
                let extra = appended[ListID(owner: key, point: slot.point)] ?? []
                int32(Int32(slot.children.count + extra.count))
                for child in slot.children { try original(child, depth: depth + 1) }
                for index in extra { try inserted(index, depth: depth + 1) }
                cursor = slot.end
            }
            try copy(cursor..<span.upperBound)
        }
        func inserted(_ index: Int, depth: Int) throws {
            guard depth <= 64 else { throw KoikatsuReadError.limitExceeded("hierarchy depth exceeds 64") }
            let key = keys[index]
            switch insertions[index].record {
            case .duplicate(let template):
                guard let span = spans.topology.records[template] else { throw SourceSceneTopologyError.unsupported("Scene record \(template) has no byte span.") }
                // Patches inside the template's own bytes: its key, its
                // sub-info keys and a camera's look-through flag.
                var patches: [(Int, Data)] = [(span.lowerBound + 4, withUnsafeBytes(of: key.littleEndian) { Data($0) })]
                let sub = spans.topology.subKeys[template], allocated = allocatedSubKeys[index] ?? []
                for (offset, value) in zip((sub?.before ?? []) + (sub?.after ?? []), allocated) {
                    patches.append((offset, withUnsafeBytes(of: value.littleEndian) { Data($0) }))
                }
                if let active = spans.cameraActive[template] { patches.append((active.lowerBound, Data([0]))) }
                patches.sort { $0.0 < $1.0 }
                var cursor = span.lowerBound, next = 0
                func copyPatched(to end: Int) throws {
                    while next < patches.count, patches[next].0 < end {
                        try copy(cursor..<patches[next].0)
                        result.append(patches[next].1); cursor = patches[next].0 + patches[next].1.count; next += 1
                    }
                    try copy(cursor..<end); cursor = end
                }
                let own = children[index]
                for slot in spans.topology.slots[template] ?? [] {
                    try copyPatched(to: slot.count)
                    let placed = own.filter { insertions[$0].attachment == slot.point }
                    int32(Int32(placed.count))
                    for child in placed { try inserted(child, depth: depth + 1) }
                    // The template's own children are not part of the copy.
                    cursor = slot.end
                    if next < patches.count, patches[next].0 < cursor {
                        throw SourceSceneTopologyError.unsupported("A duplicate's key patch falls inside its template's children.")
                    }
                }
                try copyPatched(to: span.upperBound)
                guard next == patches.count else { throw SourceSceneTopologyError.unsupported("A duplicate's key patch was not applied.") }
            case .folder(let name, let values):
                header(.folder, key, values); try string(name)
                int32(Int32(children[index].count))
                for child in children[index] { try inserted(child, depth: depth + 1) }
            case .camera(let name, let values):
                header(.camera, key, values); try string(name); bool(false)
            case .light(let light, let values):
                // OILightInfo.Save: no, Utility.SaveColor (four floats),
                // intensity, range, spotAngle, shadow, enable, drawTarget.
                header(.light, key, values); int32(light.no)
                for index in 0..<4 { float(light.color[index]) }
                float(light.intensity); float(light.range); float(light.spotAngle)
                bool(light.shadow); bool(light.enable); bool(light.drawTarget)
            }
            guard result.count <= 256 * 1024 * 1024 else { throw KoikatsuReadError.limitExceeded("edited scene exceeds 256 MiB") }
        }
        try copy(0..<rootCount)
        let extra = appended[ListID(owner: nil, point: nil)] ?? []
        int32(Int32(source.snapshot.roots.count + extra.count))
        for root in source.snapshot.roots {
            int32(root.rootDictionaryKey ?? root.sourceKey)
            try original(root.sourceKey, depth: 0)
        }
        for index in extra { int32(keys[index]); try inserted(index, depth: 0) }
        try copy(source.snapshot.objectSectionEndOffset..<data.count)
        return result
    }

    // MARK: Verification

    /// The decoded stage must hold every source record unchanged in its
    /// place, each insertion at the end of its planned list under its key,
    /// with the values it was written with, and no key twice.
    func verify(_ staged: KoikatsuSceneDocument) throws {
        func mismatch(_ what: String) -> SourceSceneTopologyError { .unsupported("The staged scene's \(what) differs from the planned insertions.") }
        guard staged.settings == source.settings, staged.trailingData == source.trailingData else { throw mismatch("settings or trailer") }
        let result = SourceSceneTopology.Tree(staged.snapshot)
        guard result.records.count == tree.records.count + insertions.count else { throw mismatch("record count") }
        // Source records untouched by an insertion are deep-equal; every
        // list keeps its original children first.
        for (key, record) in tree.records {
            guard let after = result.records[key], (result.parent[key] ?? nil) == (tree.parent[key] ?? nil) else { throw mismatch("source record \(key)") }
            if !touched.contains(key), after != record { throw mismatch("source record \(key)") }
        }
        for (id, keys) in tree.lists {
            let extra = (appended[id] ?? []).map { self.keys[$0] }
            guard (result.lists[id] ?? []) == keys + extra else { throw mismatch("child order of \(id.owner.map { "source object \($0)" } ?? "the root")") }
        }
        let used = Self.usedKeys(staged.snapshot)
        guard Set(used).count == used.count else { throw mismatch("key uniqueness") }
        for (index, insertion) in insertions.enumerated() {
            let key = keys[index]
            guard let record = result.records[key], record.kind == kind(index) else { throw mismatch("record of insertion \(index)") }
            let parent: Int32?
            switch insertion.parent {
            case .root: parent = nil
            case .source(let owner): parent = owner
            case .inserted(let owner): parent = keys[owner]
            }
            guard (result.parent[key] ?? nil) == parent, result.point[key] == insertion.attachment else { throw mismatch("parent of insertion \(index)") }
            if parent == nil, record.rootDictionaryKey != key { throw mismatch("root dictionary key of insertion \(index)") }
            // An inserted record's own lists hold exactly its inserted
            // children, in order (by accessory group for a character copy).
            if record.kind == .folder || record.kind == .item || record.kind == .route {
                guard (result.lists[ListID(owner: key, point: nil)] ?? []) == children[index].map({ keys[$0] }) else {
                    throw mismatch("child order of insertion \(index)")
                }
            } else if let groups = record.character?.accessoryChildren {
                for (point, list) in groups where list.map(\.sourceKey) != children[index].filter({ insertions[$0].attachment == point }).map({ keys[$0] }) {
                    throw mismatch("accessory group \(point) of insertion \(index)")
                }
            }
            switch insertion.record {
            case .duplicate(let template):
                let original = tree.records[template]!
                guard record.transform == original.transform, record.treeState == original.treeState,
                      record.visible == original.visible, record.name == original.name,
                      record.cameraActive == original.cameraActive.map({ _ in false }),
                      record.item?.group == original.item?.group, record.item?.category == original.item?.category,
                      record.item?.no == original.item?.no, record.light == original.light,
                      record.character?.cardData == original.character?.cardData else { throw mismatch("copy of source object \(template)") }
                var sub: [Int32] = []
                if let character = record.character, let from = original.character {
                    guard character.bones.mapValues(\.transform) == from.bones.mapValues(\.transform),
                          character.ikTargets.mapValues(\.transform) == from.ikTargets.mapValues(\.transform),
                          character.lookAtTarget.transform == from.lookAtTarget.transform else { throw mismatch("copy of source object \(template)") }
                    sub = character.bones.values.map(\.sourceKey) + character.ikTargets.values.map(\.sourceKey) + [character.lookAtTarget.sourceKey]
                }
                if let item = record.item, let from = original.item {
                    guard item.bones.mapValues(\.transform) == from.bones.mapValues(\.transform) else { throw mismatch("copy of source object \(template)") }
                    sub = item.bones.values.map(\.sourceKey)
                }
                if original.kind == .route {
                    // Points and aids in order, each with its template's
                    // values under the keys allocated after the children.
                    guard let route = record.route, let from = original.route, route.points.count == from.points.count,
                          route.active == from.active, route.loop == from.loop, route.visibleLine == from.visibleLine,
                          route.orientation == from.orientation, route.color == from.color,
                          zip(route.points, from.points).allSatisfy({ a, b in
                              a.bone.transform == b.bone.transform && a.aid.transform == b.aid.transform && a.speed == b.speed
                                  && a.easeType == b.easeType && a.connection == b.connection
                                  && a.aidInitialized == b.aidInitialized && a.linked == b.linked
                          }) else { throw mismatch("copy of source object \(template)") }
                    guard route.points.flatMap({ [$0.bone.sourceKey, $0.aid.sourceKey] }) == (allocatedSubKeys[index] ?? []) else {
                        throw mismatch("sub-info keys of the copy of source object \(template)")
                    }
                    sub = route.points.flatMap { [$0.bone.sourceKey, $0.aid.sourceKey] }
                }
                guard Set(sub) == Set(allocatedSubKeys[index] ?? []) else { throw mismatch("sub-info keys of the copy of source object \(template)") }
            case let .folder(name, header), let .camera(name, header):
                guard record.name == name, record.transform == header.transform, record.treeState == header.treeState,
                      record.visible == header.visible, record.kind != .camera || record.cameraActive == false else { throw mismatch("new record \(index)") }
            case let .light(light, header):
                guard record.transform == header.transform, record.treeState == header.treeState, record.visible == header.visible,
                      record.light == KoikatsuLightRecord(no: light.no, color: light.color, intensity: light.intensity, range: light.range,
                                                          spotAngle: light.spotAngle, shadow: light.shadow, enable: light.enable,
                                                          drawTarget: light.drawTarget) else { throw mismatch("new light \(index)") }
            }
        }
    }
}
