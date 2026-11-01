import Foundation

/// #278: one structural operation on an imported original scene, in the order
/// the user made it. An export that both deletes source records and adds
/// records replays these to give each added record CharaStudio's key and root
/// position (docs/reference/studio/scene-editing.md, "Operation order").
public enum SourceSceneStructuralEdit: Codable, Sendable, Equatable {
    /// `TreeNodeCtrl.DeleteNode` of a source record with its subtree, by the
    /// record's key; nil when the subtree held an object added in this
    /// session (the replay does not follow it).
    case delete(sourceKey: Int32?)
    /// One Duplicate or Add: the objects it added, each before its children.
    case insert([UUID])
    /// An operation the replay does not follow.
    case unordered(SourceSceneOrderFallback)
}

/// Why an export with deletes and additions keeps the set-based keys
/// (`SourceSceneExportValidation.order`). The scene is still valid; the keys
/// and root order of its added records may differ from CharaStudio's for the
/// same operations.
public enum SourceSceneOrderFallback: String, Codable, Sendable, Equatable {
    case noLog, move, routePoints, addThenDelete, light, overflow, mismatch, legacyBones

    public var reason: String {
        switch self {
        case .noLog: return "the order of its deletes and additions was not recorded (a document saved before this was tracked)"
        case .move: return "an object was moved to another parent, which also changes CharaStudio's root order"
        case .routePoints: return "route points were added or deleted, which also take and free keys"
        case .addThenDelete: return "an added or copied object was deleted again"
        case .light: return "a light was added or copied (CharaStudio drops a light while two exist)"
        case .overflow: return "more than \(SourceSceneEditLog.capacity) structural edits were recorded"
        case .mismatch: return "objects were added or removed by an operation that is not recorded (a plug-in or a merged scene)"
        case .legacyBones: return "a character from an older CharaStudio scene gains FK bones when CharaStudio loads it, under keys this export cannot know"
        }
    }
}

/// The ordered structural edits of an imported scene. It travels with the
/// document, so undo and redo snapshots restore it with the objects. At most
/// `capacity` entries: the last one marks an overflow, and later edits are not
/// kept (the export then falls back). A native save holds it as a plain array;
/// an entry this version cannot read loads as a mismatch, never as an error.
public struct SourceSceneEditLog: Codable, Sendable, Equatable {
    public static let capacity = 4096
    public private(set) var edits: [SourceSceneStructuralEdit]

    public init(_ edits: [SourceSceneStructuralEdit] = []) {
        self.edits = edits.count <= Self.capacity ? edits : Array(edits.prefix(Self.capacity - 1)) + [.unordered(.overflow)]
    }

    public mutating func append(_ edit: SourceSceneStructuralEdit) {
        guard edits.count < Self.capacity else { return }
        edits.append(edits.count == Self.capacity - 1 ? .unordered(.overflow) : edit)
    }

    private struct Lenient: Decodable {
        let edit: SourceSceneStructuralEdit
        init(from decoder: Decoder) throws {
            edit = (try? SourceSceneStructuralEdit(from: decoder)) ?? .unordered(.mismatch)
        }
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer(), edits: [SourceSceneStructuralEdit] = []
        while !container.isAtEnd {
            guard edits.count < Self.capacity else { edits[Self.capacity - 1] = .unordered(.overflow); break }
            edits.append(try container.decode(Lenient.self).edit)
        }
        self.edits = edits
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(edits)
    }
}

public extension StudioDocument {
    /// Appends `edit` to an imported scene's log; documents without one keep none.
    mutating func recordSourceEdit(_ edit: SourceSceneStructuralEdit) {
        guard sourceSceneSHA256 != nil, sourceStructuralEdits != nil else { return }
        sourceStructuralEdits!.append(edit)
    }

    /// `change`, then `edit` appended to the log, as one mutation: the app
    /// refreshes once per document write.
    mutating func recordingSourceEdit(_ edit: SourceSceneStructuralEdit, _ change: (inout StudioDocument) throws -> Void) rethrows {
        try change(&self)
        recordSourceEdit(edit)
    }

    /// `remove(id)`, recorded as the delete of a source subtree.
    mutating func removeRecordingSourceEdit(_ id: UUID) {
        if sourceSceneSHA256 != nil, sourceStructuralEdits != nil, let top = object(id) {
            let added = objects.contains { $0.sourceObjectKey == nil && ($0.id == id || isDescendant($0.id, of: id)) }
            recordSourceEdit(.delete(sourceKey: added ? nil : top.sourceObjectKey))
        }
        remove(id)
    }
}

public extension SourceSceneInsertion {
    /// One operation of an ordered export (`SourceSceneEdits.order`).
    enum Step: Sendable, Equatable {
        /// The delete of a source record with its subtree (`TreeNodeCtrl.DeleteNode`).
        case delete(Int32)
        /// One Duplicate or Add: these insertions, each after its parent.
        case insert([Int])
    }
}

extension SourceSceneStage {
    /// What the ordered replay needs of each insertion, from the plan.
    struct Layout: Sendable {
        var insertions: [SourceSceneInsertion] = []
        /// Each insertion's children in load order (`SourceSceneInsertionPlan.ordered`).
        var children: [[Int]] = []
        /// The sub-info keys the import takes before and after the record's
        /// children (`SourceSceneEditSpans.Topology.SubKeys`).
        var before: [Int] = [], after: [Int] = []
        /// The sub-info keys the stage gave each insertion, before then after.
        var subKeys: [[Int32]] = []
        var lights: [Bool] = []
    }

    /// The keys and root order the ordered operations give the insertions.
    struct Replay {
        var keys: [Int32], subKeys: [[Int32]]
        /// The root dictionary in enumeration order (`SceneInfo.Save`).
        var roots: [Int32]
        /// Every source record the deletes removed.
        var deleted: Set<Int32>
    }

    /// #278: CharaStudio's allocation for `steps`, made in order on the
    /// loaded source scene (docs/reference/studio/scene-editing.md,
    /// "Operation order"):
    ///
    /// - `SceneInfo.hashIndex` starts as every key the scene holds, and
    ///   `GetNewIndex` (SceneInfo.cs:194) takes the smallest free one.
    /// - A delete frees the keys `DeleteKey` releases: the record's own and
    ///   its children's, a character's bones, IK targets and look-at target,
    ///   a route's point keys. An item's FK bones (OIItemInfo.cs:176) and a
    ///   point's aid (OIRoutePointInfo.cs:84) stay taken.
    /// - The root dictionary is a Mono `Dictionary`: slot i holds the i-th
    ///   root after a load (`LoadScene` builds a new `SceneInfo`, Studio.cs:507).
    ///   `Remove` pushes a root's slot onto a last-in-first-out free list,
    ///   `Add` pops it or appends, and `Save` enumerates by slot. A child copy
    ///   is added by `Import` and removed again by `OnLoadAttach`, which leaves
    ///   the order unchanged. `Resize` only runs with no free slot (the
    ///   touched slots never exceed its threshold), so the free list survives it.
    func replay(_ steps: [SourceSceneInsertion.Step]) throws -> Replay {
        func fail(_ reason: String) -> SourceSceneTopologyError { .unsupported("Ordered export: " + reason) }
        guard !layout.lights.contains(true) else { throw fail("lights are not replayed (SceneInfo.isLightCheck).") }
        let tree = SourceSceneTopology.Tree(source.snapshot)
        var free = FreeKeys(Set(SourceSceneInsertionPlan.usedKeys(source.snapshot)))
        var alive = Set(tree.records.keys), deleted = Set<Int32>()
        var slots: [Int32?] = source.snapshot.roots.map(\.sourceKey), freeSlots: [Int] = []
        var slotOf = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($0.element!, $0.offset) })
        let count = layout.insertions.count
        var keys = Array(repeating: Int32(-1), count: count), subKeys = Array(repeating: [Int32](), count: count)
        func release(_ record: KoikatsuObjectRecord) {
            guard alive.remove(record.sourceKey) != nil else { return }
            deleted.insert(record.sourceKey); free.release(record.sourceKey)
            if let character = record.character {
                for bone in character.bones.values { free.release(bone.sourceKey) }
                for target in character.ikTargets.values { free.release(target.sourceKey) }
                free.release(character.lookAtTarget.sourceKey)
                for children in character.accessoryChildren.values { children.forEach(release) }
            }
            for point in record.route?.points ?? [] { free.release(point.bone.sourceKey) }
            record.children.forEach(release)
        }
        for step in steps {
            switch step {
            case .delete(let key):
                guard alive.contains(key), let record = tree.records[key] else { throw fail("source object \(key) is not there to delete.") }
                release(record)
                if let slot = slotOf.removeValue(forKey: key) { slots[slot] = nil; freeSlots.append(slot) }
            case .insert(let members):
                let set = Set(members)
                guard !members.isEmpty, set.count == members.count,
                      members.allSatisfy({ (0..<count).contains($0) && keys[$0] < 0 }) else { throw fail("an insertion is listed twice or not at all.") }
                func visit(_ index: Int) throws {
                    keys[index] = try free.take()
                    for _ in 0..<layout.before[index] { subKeys[index].append(try free.take()) }
                    for child in layout.children[index] where set.contains(child) { try visit(child) }
                    for _ in 0..<layout.after[index] { subKeys[index].append(try free.take()) }
                }
                for index in members {
                    switch layout.insertions[index].parent {
                    case .inserted(let parent) where set.contains(parent): continue
                    case .inserted(let parent): guard keys[parent] >= 0 else { throw fail("insertion \(index) comes before its parent.") }
                    case .source(let key): guard alive.contains(key) else { throw fail("insertion \(index) goes under deleted source object \(key).") }
                    case .root: break
                    }
                    try visit(index)
                    if case .root = layout.insertions[index].parent {
                        let key = keys[index]
                        if let slot = freeSlots.popLast() { slots[slot] = key; slotOf[key] = slot }
                        else { slotOf[key] = slots.count; slots.append(key) }
                    }
                }
                guard members.allSatisfy({ keys[$0] >= 0 }) else { throw fail("a step lists an insertion without its parent.") }
            }
        }
        guard keys.allSatisfy({ $0 >= 0 }) else { throw fail("an insertion is in no step.") }
        for index in 0..<count where subKeys[index].count != layout.subKeys[index].count {
            throw fail("insertion \(index)'s sub-info keys differ from its stage.")
        }
        return Replay(keys: keys, subKeys: subKeys, roots: slots.compactMap { $0 }, deleted: deleted)
    }

    /// `body` (the edited stage, with its stage keys and root order) with each
    /// insertion under its replayed key and sub-info keys and the roots in the
    /// replayed order; every other byte unchanged. Returns the scene and its
    /// decoded document, verified against `final`.
    func reordered(_ body: Data, final: KoikatsuSceneDocument, replay: Replay) throws -> (Data, KoikatsuSceneDocument) {
        func fail(_ what: String) -> SourceSceneTopologyError { .unsupported("Ordered export: the reordered scene's \(what) differs from the plan.") }
        var reader = try KoikatsuBinaryReader(body)
        try reader.skipPNG()
        guard try reader.string() == final.snapshot.version else { throw fail("version") }
        let rootCount = reader.offset
        var entries: [(key: Int32, range: Range<Int>)] = []
        for _ in 0..<(try reader.count()) {
            let start = reader.offset, rootKey = try reader.int32()
            let record = try reader.object(depth: 0, rootKey: rootKey)
            entries.append((record.sourceKey, start..<reader.offset))
        }
        guard reader.offset == final.snapshot.objectSectionEndOffset else { throw fail("object section") }
        let spans = reader.editSpans.topology
        var map: [Int32: Int32] = [:], patches: [Int: Int32] = [:], subMap: [Int32: Int32] = [:]
        for (index, stageKey) in keys.enumerated() {
            let key = replay.keys[index]
            map[stageKey] = key
            guard let span = spans.records[stageKey] else { throw fail("record of insertion \(index)") }
            patches[span.lowerBound + 4] = key
            let offsets = (spans.subKeys[stageKey]?.before ?? []) + (spans.subKeys[stageKey]?.after ?? [])
            guard offsets.count == replay.subKeys[index].count, layout.subKeys[index].count == offsets.count else { throw fail("sub-info keys of insertion \(index)") }
            for (offset, (old, new)) in zip(offsets, zip(layout.subKeys[index], replay.subKeys[index])) {
                patches[offset] = new; subMap[old] = new
            }
        }
        // A root's dictionary key precedes its record; an inserted root's is its own key.
        for entry in entries where map[entry.key] != nil { patches[entry.range.lowerBound] = map[entry.key]! }
        let position = Dictionary(uniqueKeysWithValues: replay.roots.enumerated().map { ($0.element, $0.offset) })
        let mapped = entries.map { (key: map[$0.key] ?? $0.key, range: $0.range) }
        guard mapped.count == replay.roots.count, mapped.allSatisfy({ position[$0.key] != nil }) else { throw fail("root set") }
        let base = body.startIndex, offsets = patches.keys.sorted()
        var result = Data(); result.reserveCapacity(body.count)
        result.append(body.subdata(in: base..<(base + rootCount + 4)))
        for entry in mapped.sorted(by: { position[$0.key]! < position[$1.key]! }) {
            var cursor = entry.range.lowerBound, low = 0, high = offsets.count
            while low < high { let mid = (low + high) / 2; if offsets[mid] < entry.range.lowerBound { low = mid + 1 } else { high = mid } }
            for offset in offsets[low...].prefix(while: { $0 < entry.range.upperBound }) {
                result.append(body.subdata(in: (base + cursor)..<(base + offset)))
                var bits = patches[offset]!.littleEndian
                withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
                cursor = offset + 4
            }
            result.append(body.subdata(in: (base + cursor)..<(base + entry.range.upperBound)))
        }
        result.append(body.subdata(in: (base + final.snapshot.objectSectionEndOffset)..<body.endIndex))
        guard result.count == body.count else { throw fail("length") }
        let decoded = try KoikatsuSceneReader.decodeDocument(result)
        // The same tree under the mapped keys, the roots in the replayed
        // order, and every key the stage used moved as planned.
        guard decoded.settings == final.settings, decoded.trailingData == final.trailingData else { throw fail("settings or trailer") }
        let before = SourceSceneTopology.Tree(final.snapshot), after = SourceSceneTopology.Tree(decoded.snapshot)
        guard after.records.count == before.records.count else { throw fail("record count") }
        for (key, record) in before.records {
            let moved = map[key] ?? key
            guard let found = after.records[moved], found.kind == record.kind, found.transform == record.transform,
                  found.name == record.name, found.visible == record.visible, found.treeState == record.treeState,
                  (after.parent[moved] ?? nil) == (before.parent[key] ?? nil).map({ map[$0] ?? $0 }),
                  after.point[moved] == before.point[key] else { throw fail("record \(moved)") }
        }
        for (id, list) in before.lists where id.owner != nil {
            let owner = id.owner.map { map[$0] ?? $0 }
            guard (after.lists[.init(owner: owner, point: id.point)] ?? []) == list.map({ map[$0] ?? $0 }) else { throw fail("child order") }
        }
        // Source roots keep their dictionary keys; an inserted root is keyed by its own (`Studio.AddInfo`).
        let inserted = Set(replay.keys), dictionary = Dictionary(uniqueKeysWithValues: final.snapshot.roots.map { ($0.sourceKey, $0.rootDictionaryKey) })
        guard decoded.snapshot.roots.map(\.sourceKey) == replay.roots, decoded.snapshot.roots.allSatisfy({ root in
            inserted.contains(root.sourceKey) ? root.rootDictionaryKey == root.sourceKey : root.rootDictionaryKey == dictionary[root.sourceKey] ?? nil
        }) else { throw fail("root order") }
        let used = SourceSceneInsertionPlan.usedKeys(decoded.snapshot)
        guard Set(used).count == used.count,
              Set(used) == Set(SourceSceneInsertionPlan.usedKeys(final.snapshot).map { map[$0] ?? subMap[$0] ?? $0 }) else { throw fail("keys") }
        return (result, decoded)
    }
}

/// `GetNewIndex` over a changing key set: the smallest free key, with keys
/// freed below the scan point kept in order.
struct FreeKeys {
    private var used: Set<Int32>, scan: Int32 = 0, holes: [Int32] = []
    init(_ used: Set<Int32>) { self.used = used }
    mutating func take() throws -> Int32 {
        if !holes.isEmpty { let key = holes.removeFirst(); used.insert(key); return key }
        while used.contains(scan) {
            guard scan < .max else { throw KoikatsuReadError.limitExceeded("no free scene key") }
            scan += 1
        }
        used.insert(scan)
        let key = scan
        if scan < .max { scan += 1 }
        return key
    }
    mutating func release(_ key: Int32) {
        guard used.remove(key) != nil, key < scan else { return }
        var low = 0, high = holes.count
        while low < high { let mid = (low + high) / 2; if holes[mid] < key { low = mid + 1 } else { high = mid } }
        holes.insert(key, at: low)
    }
}

public extension SourceSceneExportValidation {
    /// How an export orders its added records' keys.
    enum Order: Sendable, Equatable {
        /// No delete or no addition, or no key was freed before one was
        /// taken: the set-based keys are CharaStudio's.
        case unneeded
        /// The recorded operations, replayed (`SourceSceneEdits.order`).
        case replayed([SourceSceneInsertion.Step])
        /// The set-based keys, with the reason the order was not replayed.
        case fallback(SourceSceneOrderFallback)
    }

    /// #278: the document's recorded operations as replay steps, checked
    /// against the staged scene and the topology edits. Only an export that
    /// adds records after an operation that freed a key or a root slot can
    /// need them: a source delete, a delete of an added object, a route
    /// point added or deleted (`AddPoint` takes keys, a delete frees them),
    /// or a move (`dicObject` loses or gains a root). Without one, the
    /// set-based keys and appended roots are CharaStudio's, and the export
    /// is unchanged. A document without a log falls back only when it
    /// deletes, since nothing else shows it needed the order.
    static func order(_ document: StudioDocument, staged: Staged, deletions: Set<Int32>,
                      reparents: [SourceSceneEdits.Reparent]) -> Order {
        guard !staged.objects.isEmpty else { return .unneeded }
        guard let log = document.sourceStructuralEdits else { return deletions.isEmpty ? .unneeded : .fallback(.noLog) }
        if log.edits.contains(.unordered(.overflow)) { return .fallback(.overflow) }
        // The replay does not model the keys an added object held before its
        // delete, so every later key can differ.
        if log.edits.contains(.delete(sourceKey: nil)) { return .fallback(.addThenDelete) }
        let index = Dictionary(staged.objects.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let tree = SourceSceneTopology.Tree(staged.stage.source.snapshot)
        var steps: [SourceSceneInsertion.Step] = [], covered = Set<Int>(), logged = Set<Int32>()
        var freed = false, needed = false, unordered: SourceSceneOrderFallback?
        for edit in log.edits {
            switch edit {
            case .delete(let key?):
                guard let record = tree.records[key] else { return .fallback(.mismatch) }
                func collect(_ record: KoikatsuObjectRecord) {
                    logged.insert(record.sourceKey)
                    record.children.forEach(collect)
                    for children in (record.character?.accessoryChildren ?? [:]).values { children.forEach(collect) }
                }
                collect(record)
                steps.append(.delete(key)); freed = true
            case .delete(nil): return .fallback(.addThenDelete)
            case .insert(let ids):
                var members: [Int] = []
                for id in ids {
                    guard let member = index[id], covered.insert(member).inserted else { return .fallback(.mismatch) }
                    members.append(member)
                }
                if members.isEmpty { continue }
                steps.append(.insert(members)); if freed { needed = true }
            case .unordered(let reason):
                unordered = unordered ?? reason
                // Route point edits take and free keys, and moves take and
                // free root slots, outside the replay.
                if reason == .routePoints || reason == .move { if freed { needed = true }; freed = true }
            }
        }
        // Every addition and every deleted source record must be in the log.
        let present = Set(document.objects.compactMap(\.sourceObjectKey))
        guard covered.count == staged.objects.count, logged == Set(tree.records.keys).subtracting(present) else { return .fallback(.mismatch) }
        if !reparents.isEmpty, unordered == nil { return .fallback(.mismatch) }
        guard needed else { return .unneeded }
        if let unordered { return .fallback(unordered) }
        if !reparents.isEmpty { return .fallback(.move) }
        if staged.stage.layout.lights.contains(true) { return .fallback(.light) }
        if staged.legacyCharacters, !legacyReplayIsExact(staged, steps) { return .fallback(.legacyBones) }
        return .replayed(steps)
    }

    /// ST-T05a with #278: a legacy character (`Staged.legacyCharacters`)
    /// gains, at CharaStudio's load, each catalog FK bone its record lacks,
    /// under a key `GetNewIndex` takes after every saved key is registered
    /// (`LoadScene` runs `AddObjectAssist.LoadChild` after `SceneInfo.Load`,
    /// Studio.cs:515–519; `InitBone` :42, `InitHairBone` :110). Those keys
    /// are the smallest that were free at load, and the upgrade does not hold
    /// them. The replay is still CharaStudio's while every key it takes is
    /// one an earlier delete freed: such a key is below every key free at
    /// load, so no hidden bone holds it, and CharaStudio takes it too. A copy
    /// of a legacy character takes more keys in CharaStudio (its hidden bones
    /// travel with it), so any copy of a character is not exact.
    private static func legacyReplayIsExact(_ staged: Staged, _ steps: [SourceSceneInsertion.Step]) -> Bool {
        let tree = SourceSceneTopology.Tree(staged.stage.source.snapshot)
        for insertion in staged.stage.layout.insertions {
            if case .duplicate(let template) = insertion.record, tree.records[template]?.character != nil { return false }
        }
        // A replay that fails refuses the export with its own reason.
        guard let replay = try? staged.stage.replay(steps) else { return true }
        let used = Set(SourceSceneInsertionPlan.usedKeys(staged.stage.source.snapshot))
        return (replay.keys + replay.subKeys.joined()).allSatisfy(used.contains)
    }

    /// The status after an original-scene export: ST-T05a's note for a scene
    /// from an older CharaStudio, ST-T03i's plug-in data no installed plug-in
    /// reads, then #278's reason when added objects kept the set-based keys.
    /// A replayed order adds nothing: its keys are CharaStudio's.
    static func exportStatus(fileName: String, source: KoikatsuSceneDocument, order: Order) -> String {
        // ST-T03i: entries no installed plug-in reads travel verbatim; that
        // is CharaStudio's behavior only while no installed plug-in owns them.
        let orphans = source.orphanPluginIDs
        // ST-T05a: a scene from an older CharaStudio is written the way
        // CharaStudio 1.0.4.2 saves it, so even an unedited export changes
        // its bytes.
        var status = "Exported edited original scene to \(fileName)"
            + (source.isLegacy ? ", saved as 1.0.4.2 from CharaStudio \(source.snapshot.version), as CharaStudio does" : "")
            + (orphans.isEmpty ? "" : ". It keeps plug-in data no installed plug-in reads, unchanged: \(orphans.joined(separator: ", "))")
        if case .fallback(let reason) = order {
            status += ". Added objects took keys after the scene's own, which can differ from CharaStudio's for these edits: \(reason.reason)"
        }
        return status
    }
}
