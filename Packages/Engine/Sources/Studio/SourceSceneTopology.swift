import Foundation

/// A topology edit the original-scene writer refuses, with the reason the UI shows.
public enum SourceSceneTopologyError: Error, LocalizedError, Equatable, Sendable {
    case unsupported(String)
    public var errorDescription: String? {
        switch self { case .unsupported(let reason): return reason }
    }
}

/// ST-T03 / ST-S09: object deletion and reparenting in an exported original
/// CharaStudio 1.0.4.2 scene, following the recovered tree operations
/// (docs/reference/studio/scene-editing.md, "Topology"):
///
/// - Delete (`TreeNodeCtrl.DeleteNode` -> `OCI*.OnDelete`): the record and its
///   whole subtree leave their parent's child list (`OnDetachChild`, a
///   `List.Remove`) or the root dictionary (`Studio.DeleteInfo`, a
///   `Dictionary.Remove`). Every other record keeps its key; `SceneInfo`
///   keys are a `HashSet` (`SetNewIndex` only replaces a duplicate), so the
///   gaps need no renumbering.
/// - Reparent (`TreeNodeCtrl.SetParent` -> `OCIFolder.OnAttach` /
///   `OCI*.OnDetach`): the record leaves its old list and is appended to the
///   end of the folder's child list (`List.Add`) or the root dictionary
///   (`Studio.AddInfo`, keyed by its own `dicKey`). Its subtree moves with it
///   unchanged. The caller re-authors the moved record's own local transform
///   (world position and rotation kept, `changeAmount.scale` untouched) with
///   an ordinary `.object` transform edit.
///
/// Supported: deleting any record that is not attached to a character's
/// accessory point; moving any non-route record between the root and
/// folders. Everything else is refused before bytes are written.
public enum SourceSceneTopology {
    /// One surviving source record of the document's final tree: its own key,
    /// its parent's key (`nil` for the root dictionary) and, for a character
    /// child, the accessory point it is attached to.
    public struct Placement: Sendable, Equatable {
        public let key: Int32, parent: Int32?, attachment: Int32?
        public init(key: Int32, parent: Int32?, attachment: Int32? = nil) {
            self.key = key; self.parent = parent; self.attachment = attachment
        }
    }

    /// The writer edits that turn the imported tree into `survivors`, given in
    /// the document's sibling order (each parent's children appear in the
    /// order the tree shows them). Records missing from `survivors` are
    /// deleted; only the top of each deleted subtree is listed. A record whose
    /// parent changed, or that sits after a sibling it originally preceded,
    /// is moved: CharaStudio can only append, so each parent's children are
    /// its longest prefix still in original order followed by the moved
    /// records in the document's order. The result is validated.
    public static func edits(from snapshot: KoikatsuSceneSnapshot, survivors: [Placement]) throws
        -> (deletions: Set<Int32>, reparents: [SourceSceneEdits.Reparent]) {
        let tree = Tree(snapshot)
        var seen = Set<Int32>()
        for placement in survivors {
            guard tree.records[placement.key] != nil else {
                throw SourceSceneTopologyError.unsupported("Original-scene export contains an unknown source object \(placement.key).")
            }
            guard seen.insert(placement.key).inserted else {
                throw SourceSceneTopologyError.unsupported("Original-scene export contains source object \(placement.key) twice.")
            }
        }
        // Only the top of each deleted subtree: a missing record whose
        // original parent survives (or that was a root).
        let missing = Set(tree.records.keys).subtracting(seen)
        let deletions = missing.filter { key in tree.parent[key].flatMap { $0 }.map { !missing.contains($0) } ?? true }
        var reparents: [SourceSceneEdits.Reparent] = []
        var lists: [Tree.ListID: [Placement]] = [:], order: [Tree.ListID] = []
        for placement in survivors {
            let id = Tree.ListID(owner: placement.parent, point: placement.attachment)
            if lists[id] == nil { order.append(id) }
            lists[id, default: []].append(placement)
        }
        for id in order {
            let placed = lists[id]!
            let original = tree.lists[id] ?? []
            let position = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($0.element, $0.offset) })
            var split = 0, last = -1
            while split < placed.count, let index = position[placed[split].key], index > last {
                last = index; split += 1
            }
            for placement in placed[split...] {
                guard placement.attachment == nil else {
                    throw SourceSceneTopologyError.unsupported("Original-scene export does not move objects onto a character's accessory points (source object \(placement.key)).")
                }
                reparents.append(.init(object: placement.key, parent: placement.parent))
            }
        }
        _ = try plan(snapshot, deletions: deletions, reparents: reparents)
        return (deletions, reparents)
    }

    /// Validates topology edits against the imported records without bytes.
    public static func validate(_ snapshot: KoikatsuSceneSnapshot, deletions: Set<Int32>,
                                reparents: [SourceSceneEdits.Reparent]) throws {
        _ = try plan(snapshot, deletions: deletions, reparents: reparents)
    }

    static func plan(_ snapshot: KoikatsuSceneSnapshot, deletions: Set<Int32>,
                     reparents: [SourceSceneEdits.Reparent]) throws -> Plan {
        let tree = Tree(snapshot)
        func fail(_ reason: String) -> SourceSceneTopologyError { .unsupported(reason) }
        func kind(_ key: Int32) -> KoikatsuObjectKind { tree.records[key]!.kind }
        // Reparenting: non-route records between the root and folders. A
        // moved record leaves with its subtree, so it survives the deletion
        // of its old parent (CharaStudio: move it out, then delete).
        let movedKeys = Set(reparents.map(\.object))
        /// The original ancestors a record still has after the moves: the
        /// walk stops at the first moved ancestor, which takes the record
        /// with it (move B out of folder A, delete B's child C, delete A:
        /// C is not deleted with A).
        func ancestors(_ key: Int32) -> [Int32] {
            var result: [Int32] = [], current = tree.parent[key] ?? nil
            while let parent = current {
                result.append(parent)
                if movedKeys.contains(parent) { break }
                current = tree.parent[parent] ?? nil
            }
            return result
        }
        // Deletion: the top of each subtree, never an accessory child alone.
        var deleted = Set<Int32>()
        for key in deletions.sorted() {
            guard let record = tree.records[key] else { throw fail("Original-scene export cannot delete unknown source object \(key).") }
            guard tree.point[key] == nil else {
                throw fail("Original-scene export does not delete an object attached to a character's accessory point on its own (source object \(key)); deleting the character removes it with its subtree.")
            }
            guard !ancestors(key).contains(where: deletions.contains) else {
                throw fail("Source object \(key) is already deleted with its parent; list only the top of a deleted subtree.")
            }
            guard !movedKeys.contains(key) else { throw fail("Source object \(key) is both deleted and moved.") }
            if tree.parent[key] == .some(nil), record.rootDictionaryKey != record.sourceKey {
                throw fail("Root dictionary key \(record.rootDictionaryKey.map(String.init) ?? "none") differs from object key \(key); CharaStudio removes roots by their own key.")
            }
            func collect(_ record: KoikatsuObjectRecord) {
                guard !movedKeys.contains(record.sourceKey) else { return }
                deleted.insert(record.sourceKey)
                for child in record.children { collect(child) }
                for children in (record.character?.accessoryChildren ?? [:]).values { for child in children { collect(child) } }
            }
            collect(record)
        }
        var moved: [Int32: Int32?] = [:], movedOrder: [Int32] = []
        let rootKeys = Set(snapshot.roots.compactMap(\.rootDictionaryKey))
        for move in reparents {
            let key = move.object
            guard let record = tree.records[key] else { throw fail("Original-scene export cannot move unknown source object \(key).") }
            guard moved[key] == nil else { throw fail("Source object \(key) is moved twice; list each move once.") }
            guard record.kind != .route else {
                throw fail("CharaStudio does not reparent routes (a route's tree node has enableChangeParent = false); source route \(key) stays where it is.")
            }
            let oldParent = tree.parent[key] ?? nil
            if tree.point[key] != nil {
                throw fail("Original-scene export does not move objects attached to a character's accessory points (source object \(key)).")
            }
            if let oldParent, kind(oldParent) == .route {
                throw fail("Original-scene export does not move route children (source object \(key)): their saved local placement follows the route's playback position at the moment of the move.")
            }
            if let oldParent, kind(oldParent) == .item {
                throw fail("Original-scene export does not move item children (source object \(key)): an item's child root may be a named transform inside its prefab (ItemLoadInfo.childRoot) that the converted catalog does not record.")
            }
            if oldParent == nil, record.rootDictionaryKey != record.sourceKey {
                throw fail("Root dictionary key \(record.rootDictionaryKey.map(String.init) ?? "none") differs from object key \(key); CharaStudio removes roots by their own key.")
            }
            if let parent = move.parent {
                guard tree.records[parent] != nil else { throw fail("Source object \(key) is moved under unknown source object \(parent).") }
                guard !deleted.contains(parent) else { throw fail("Source object \(key) is moved under deleted source object \(parent).") }
                switch kind(parent) {
                case .folder: break
                case .character:
                    throw fail("Original-scene export does not move objects onto a character's accessory points (source object \(key) under character \(parent)).")
                case .route:
                    throw fail("Original-scene export does not move objects under routes (source object \(key) under route \(parent)).")
                case .item:
                    throw fail("Original-scene export does not move objects under items (source object \(key) under item \(parent)): an item's child root may be a named transform inside its prefab (ItemLoadInfo.childRoot) that the converted catalog does not record.")
                case .camera, .light:
                    throw fail("CharaStudio cameras and lights cannot hold children (enableAddChild = false); source object \(key) cannot move under \(parent).")
                }
            } else if oldParent != nil, rootKeys.contains(key) {
                throw fail("Source object \(key) cannot join the root dictionary: another root already uses key \(key).")
            }
            moved[key] = move.parent; movedOrder.append(key)
        }
        // The final lists: originals minus deleted and moved records, then the
        // moved records appended in move order.
        var lists: [Tree.ListID: [Int32]] = [:]
        for (id, keys) in tree.lists { lists[id] = keys.filter { !deleted.contains($0) && moved[$0] == nil } }
        for key in movedOrder { lists[Tree.ListID(owner: moved[key]!, point: nil), default: []].append(key) }
        var parent: [Int32: Int32?] = [:]
        for (id, keys) in lists { for key in keys { parent[key] = id.owner } }
        for key in movedOrder {
            var current = parent[key] ?? nil, steps = 0
            while let next = current {
                guard next != key, steps <= tree.records.count else {
                    throw fail("Moving source object \(key) would make it its own ancestor.")
                }
                current = parent[next] ?? nil; steps += 1
            }
        }
        return Plan(lists: lists, deleted: deleted, moved: Set(movedOrder),
                    rootKeys: Dictionary(uniqueKeysWithValues: snapshot.roots.map { ($0.sourceKey, $0.rootDictionaryKey ?? $0.sourceKey) }),
                    records: tree.records)
    }

    /// The imported tree: every record, the list that holds it and the
    /// original order of every list (the root dictionary, each folder, item
    /// and route child list, and each character accessory group).
    struct Tree {
        struct ListID: Hashable { let owner: Int32?; let point: Int32? }
        var records: [Int32: KoikatsuObjectRecord] = [:]
        var parent: [Int32: Int32?] = [:]
        var point: [Int32: Int32] = [:]
        var lists: [ListID: [Int32]] = [:]
        init(_ snapshot: KoikatsuSceneSnapshot) {
            lists[ListID(owner: nil, point: nil)] = snapshot.roots.map(\.sourceKey)
            func visit(_ record: KoikatsuObjectRecord, parent: Int32?, point: Int32?) {
                records[record.sourceKey] = record
                self.parent[record.sourceKey] = .some(parent)
                if let point { self.point[record.sourceKey] = point }
                if record.kind == .folder || record.kind == .item || record.kind == .route {
                    lists[ListID(owner: record.sourceKey, point: nil)] = record.children.map(\.sourceKey)
                }
                for child in record.children { visit(child, parent: record.sourceKey, point: nil) }
                for (key, children) in record.character?.accessoryChildren ?? [:] {
                    lists[ListID(owner: record.sourceKey, point: key)] = children.map(\.sourceKey)
                    for child in children { visit(child, parent: record.sourceKey, point: key) }
                }
            }
            for root in snapshot.roots { visit(root, parent: nil, point: nil) }
        }
    }

    /// The validated final tree.
    struct Plan {
        let lists: [Tree.ListID: [Int32]]
        let deleted: Set<Int32>, moved: Set<Int32>
        let rootKeys: [Int32: Int32]
        let records: [Int32: KoikatsuObjectRecord]

        /// The surviving records in CharaStudio's load order: the root
        /// dictionary in order, each record before its children (child lists
        /// and accessory groups in `slots` byte order when given, else in
        /// ascending accessory point order like `activeAtLoad`).
        func loadOrder(slots: [Int32: [SourceSceneEditSpans.Topology.Slot]] = [:]) -> [Int32] {
            var order: [Int32] = []
            func visit(_ key: Int32) {
                order.append(key)
                let points: [Int32?]
                if let recordSlots = slots[key] { points = recordSlots.map(\.point) }
                else if let character = records[key]?.character { points = character.accessoryChildren.keys.sorted() }
                else { points = [nil] }
                for point in points { for child in lists[Tree.ListID(owner: key, point: point)] ?? [] { visit(child) } }
            }
            for root in lists[Tree.ListID(owner: nil, point: nil)] ?? [] { visit(root) }
            return order
        }

        /// The decoded result must have exactly the planned tree: every
        /// surviving list in the planned order and no other record.
        func verify(_ result: KoikatsuSceneSnapshot) throws {
            let tree = Tree(result)
            guard tree.records.count == records.count - deleted.count,
                  tree.records.keys.allSatisfy({ records[$0] != nil && !deleted.contains($0) }) else {
                throw SourceSceneTopologyError.unsupported("The edited scene's records differ from the planned tree.")
            }
            for (id, keys) in lists where id.owner.map({ !deleted.contains($0) }) ?? true {
                guard (tree.lists[id] ?? []) == keys else {
                    throw SourceSceneTopologyError.unsupported("The edited scene's child order differs from the planned tree.")
                }
            }
        }

        /// The edited stream: `data` with every leaf patch applied inside the
        /// record it belongs to, deleted records dropped, moved records
        /// re-emitted under their new parent, and each changed list count
        /// rewritten. `rootCount` is the offset of the root dictionary count,
        /// `objectEnd` the end of the root dictionary.
        func emit(_ data: Data, spans: SourceSceneEditSpans.Topology, rootCount: Int, objectEnd: Int,
                  patches: [(Range<Int>, Data)]) throws -> Data {
            let base = data.startIndex
            let patches = patches.sorted { $0.0.lowerBound < $1.0.lowerBound }
            for index in patches.indices.dropFirst() where patches[index - 1].0.upperBound > patches[index].0.lowerBound {
                throw SourceSceneTopologyError.unsupported("Overlapping scene edits.")
            }
            var applied = 0, result = Data()
            func segment(_ range: Range<Int>) throws {
                guard range.lowerBound <= range.upperBound, range.upperBound <= data.count else {
                    throw SourceSceneTopologyError.unsupported("Invalid scene record span.")
                }
                // The first patch that does not end before this range.
                var low = 0, high = patches.count
                while low < high { let mid = (low + high) / 2; if patches[mid].0.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid } }
                var cursor = range.lowerBound, index = low
                while index < patches.count, patches[index].0.lowerBound < range.upperBound {
                    let (span, bytes) = patches[index]
                    guard span.lowerBound >= range.lowerBound, span.upperBound <= range.upperBound else {
                        throw SourceSceneTopologyError.unsupported("A scene edit straddles a moved or deleted record boundary.")
                    }
                    result.append(data.subdata(in: (base + cursor)..<(base + span.lowerBound)))
                    result.append(bytes); cursor = span.upperBound; applied += 1; index += 1
                }
                result.append(data.subdata(in: (base + cursor)..<(base + range.upperBound)))
                guard result.count <= 256 * 1024 * 1024 else { throw KoikatsuReadError.limitExceeded("edited scene exceeds 256 MiB") }
            }
            func count(_ value: Int) {
                var bits = Int32(value).littleEndian
                withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
            }
            func record(_ key: Int32, depth: Int) throws {
                guard depth <= 64 else { throw KoikatsuReadError.limitExceeded("hierarchy depth exceeds 64") }
                guard let span = spans.records[key] else { throw SourceSceneTopologyError.unsupported("Scene record \(key) has no byte span.") }
                var cursor = span.lowerBound
                for slot in spans.slots[key] ?? [] {
                    try segment(cursor..<slot.count)
                    let children = lists[Tree.ListID(owner: key, point: slot.point)] ?? []
                    count(children.count)
                    for child in children { try record(child, depth: depth + 1) }
                    cursor = slot.end
                }
                try segment(cursor..<span.upperBound)
            }
            try segment(0..<rootCount)
            let roots = lists[Tree.ListID(owner: nil, point: nil)] ?? []
            count(roots.count)
            for key in roots {
                // An original root keeps its dictionary key bytes; a record
                // moved to the root is keyed by its own dicKey (`AddInfo`).
                var bits = (rootKeys[key] ?? key).littleEndian
                withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
                try record(key, depth: 0)
            }
            try segment(objectEnd..<data.count)
            guard applied == patches.count else {
                throw SourceSceneTopologyError.unsupported("A scene edit targets a deleted object.")
            }
            return result
        }
    }
}
