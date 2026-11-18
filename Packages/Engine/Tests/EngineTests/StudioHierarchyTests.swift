import Testing
import Foundation
import Studio
import CoreMath

@Test func studioDeepHierarchyRetainsAllAncestorTransformsAndVisibility() throws {
    var document = StudioDocument()
    var parent: UUID?
    for i in 0..<130 {
        var object = StudioObject(name: "Folder \(i)", kind: .folder)
        object.parent = parent
        object.transform.position = Float3(1, 0, 0)
        document.objects.append(object)
        parent = object.id
    }
    try document.validateHierarchy()
    let last = try #require(parent)
    #expect(abs(document.worldMatrix(of: last).translation.x - 130) < 0.001)
    #expect(document.flattened().last?.depth == 129)
    #expect(document.isDescendant(last, of: document.objects[0].id))
    document.objects[0].visible = false
    #expect(!document.isVisible(last))
}

@Test func studioRejectsCyclesDuplicateIDsAndMissingParents() {
    var document = StudioDocument()
    var a = StudioObject(name: "A", kind: .folder)
    var b = StudioObject(name: "B", kind: .folder)
    a.parent = b.id
    b.parent = a.id
    document.objects = [a, b]
    #expect(throws: StudioHierarchyError.self) { try document.validateHierarchy() }
    #expect(document.flattened().isEmpty)
    #expect(!document.isVisible(a.id))
    a.parent = nil
    document.objects = [a, a]
    #expect(throws: StudioHierarchyError.self) { try document.validateHierarchy() }
    document.objects = [b]
    #expect(throws: StudioHierarchyError.self) { try document.validateHierarchy() }
}

@Test func removingStudioSubtreeAlsoRemovesItsAnimation() {
    var document = StudioDocument()
    let folder = StudioObject(name: "Group", kind: .folder)
    var child = StudioObject(name: "Prop", kind: .item)
    child.parent = folder.id
    let other = StudioObject(name: "Retained", kind: .item)
    document.objects = [folder, child, other]
    document.timeline.insert(Keyframe(time: 1, object: child))
    document.timeline.insert(Keyframe(time: 2, object: other))
    document.remove(folder.id)
    #expect(document.objects.map(\.id) == [other.id])
    #expect(document.timeline.keyframes.map(\.object) == [other.id])
}

@Test func importedAssetReferenceRoundTripsAndOldScenesRemainCompatible() throws {
    var object = StudioObject(name: "Source prop", kind: .item)
    object.assetFile = "/local/converted/chair.gltf"
    let encoder = JSONEncoder()
    let data = try encoder.encode(object)
    #expect(try JSONDecoder().decode(StudioObject.self, from: data).assetFile == object.assetFile)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "assetFile")
    let oldData = try JSONSerialization.data(withJSONObject: json)
    #expect(try JSONDecoder().decode(StudioObject.self, from: oldData).assetFile == nil)
}

/// Deterministic structure per seed for the lookup and walk equivalence tests.
struct LookupSeed: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A random hierarchy of up to `maxCount` folders: about one in six objects
/// repeats an earlier object's id, one in seven is hidden, and a parent is
/// none, one of three ids not in the document, or any id of `pool`, which
/// may be the object itself, a later object or an id no object took (so
/// self-parents, cycles and missing parents all occur). `missing` are the
/// three absent ids.
func malformedStudioDocument(_ rng: inout LookupSeed, maxCount: Int = 24) -> (document: StudioDocument, pool: [UUID], missing: [UUID]) {
    let count = Int.random(in: 1...maxCount, using: &rng)
    let pool = (0..<count).map { _ in UUID() }
    let missing = (0..<3).map { _ in UUID() }
    var document = StudioDocument()
    for index in 0..<count {
        let id = index > 0 && Int.random(in: 0..<6, using: &rng) == 0
            ? document.objects[Int.random(in: 0..<index, using: &rng)].id : pool[index]
        var object = StudioObject(name: "Object \(index)", kind: .folder)
        object.id = id
        object.visible = Int.random(in: 0..<7, using: &rng) != 0
        switch Int.random(in: 0..<8, using: &rng) {
        case 0, 1: object.parent = nil
        case 2: object.parent = missing[Int.random(in: 0..<missing.count, using: &rng)]
        default: object.parent = pool[Int.random(in: 0..<count, using: &rng)] // may be later, itself or unused
        }
        document.objects.append(object)
    }
    return (document, pool, missing)
}

/// #383: `StudioDocument.Lookup` answers exactly what the document's linear
/// functions answer, over hierarchies with repeated ids, missing parents,
/// self-parents, cycles and ids that are not in the document; the
/// inspector's parent list built through it is the same list.
@Test func studioLookupMatchesTheDocumentFunctionsOnMalformedHierarchies() {
    var malformed: [String: Int] = [:]
    for seed in UInt64(1)...64 {
        var rng = LookupSeed(state: seed)
        let (document, pool, missing) = malformedStudioDocument(&rng)
        do { try document.validateHierarchy() } catch let error as StudioHierarchyError {
            switch error {
            case .duplicate: malformed["duplicate", default: 0] += 1
            case .missingParent: malformed["missingParent", default: 0] += 1
            case .cycle: malformed["cycle", default: 0] += 1
            }
        } catch {}
        let lookup = StudioDocument.Lookup(document.objects)
        #expect(lookup.objects == document.objects)
        let ids = pool + missing
        for id in ids {
            #expect(lookup.object(id) == document.object(id), "seed \(seed)")
            #expect(lookup.index(of: id) == document.index(of: id), "seed \(seed)")
            #expect(lookup.isVisible(id) == document.isVisible(id), "seed \(seed)")
            for ancestor in ids {
                #expect(lookup.isDescendant(id, of: ancestor) == document.isDescendant(id, of: ancestor), "seed \(seed)")
            }
        }
        for o in document.objects {
            let linear = document.objects.filter { $0.id != o.id && !document.isDescendant($0.id, of: o.id) }.map(\.id)
            let hashed = document.objects.filter { $0.id != o.id && !lookup.isDescendant($0.id, of: o.id) }.map(\.id)
            #expect(hashed == linear, "seed \(seed)")
        }
    }
    // The generator reaches every malformed shape (the first one validation finds per document).
    #expect(malformed.keys.sorted() == ["cycle", "duplicate", "missingParent"], "\(malformed)")
}

@Test func studioLookupKeepsTheFirstObjectOfARepeatedID() {
    var first = StudioObject(name: "First", kind: .folder)
    var second = StudioObject(name: "Second", kind: .item)
    second.id = first.id
    second.visible = false
    first.parent = nil
    let parent = StudioObject(name: "Parent", kind: .folder)
    second.parent = parent.id
    let lookup = StudioDocument.Lookup([parent, first, second])
    #expect(lookup.object(first.id)?.name == "First")
    #expect(lookup.index(of: first.id) == 1)
    #expect(lookup.isVisible(first.id))
    #expect(!lookup.isDescendant(first.id, of: parent.id))
    #expect(lookup.object(UUID()) == nil && lookup.index(of: UUID()) == nil && !lookup.isVisible(UUID()))
}

/// #387: `Lookup.visibleFlags()` gives every object `isVisible`'s answer for
/// its id, in one pass, on the same malformed hierarchies: repeated ids,
/// hidden ancestors, missing parents, self-parents and cycles.
@Test func studioLookupVisibleFlagsMatchIsVisibleOnMalformedHierarchies() {
    var reached: Set<String> = []
    for seed in UInt64(1)...256 {
        var rng = LookupSeed(state: seed)
        let (document, _, _) = malformedStudioDocument(&rng, maxCount: seed % 4 == 0 ? 60 : 24)
        let lookup = StudioDocument.Lookup(document.objects)
        let flags = lookup.visibleFlags()
        #expect(flags.count == document.objects.count, "seed \(seed)")
        for (index, object) in document.objects.enumerated() {
            #expect(flags[index] == document.isVisible(object.id), "seed \(seed) object \(index)")
            reached.insert(flags[index] ? "visible" : "hidden")
        }
        // Some object's parent chain comes back to an id it already passed.
        let cycle = document.objects.contains { object in
            var seen: Set<UUID> = [], current: UUID? = object.id
            while let id = current, let index = lookup.index(of: id) {
                guard seen.insert(id).inserted else { return true }
                current = document.objects[index].parent
            }
            return false
        }
        if cycle { reached.insert("cycle") }
    }
    #expect(reached == ["visible", "hidden", "cycle"], "\(reached)")
}

/// `Lookup.Indices` as the document's linear functions define it: each
/// object's `index(of:)` and its parent's (`noParent`, `missingParent`).
private func expectedLookupIndices(_ document: StudioDocument) -> StudioDocument.Lookup.Indices {
    let first = document.objects.map { document.index(of: $0.id)! }
    let parent = document.objects.map { object in
        object.parent.map { document.index(of: $0) ?? StudioDocument.Lookup.Indices.missingParent }
            ?? StudioDocument.Lookup.Indices.noParent
    }
    return .init(first: first, parent: parent)
}

/// #387 round 3: the walk-by-index arrays answer exactly `index(of:)` for
/// every object and its parent on the malformed hierarchies (repeated ids,
/// missing parents, self-parents, cycles), and `visibleFlags` from them is
/// the same as without them.
@Test func studioLookupIndicesMatchIndexOfOnMalformedHierarchies() {
    var reached: Set<String> = []
    for seed in UInt64(1)...256 {
        var rng = LookupSeed(state: seed)
        let (document, _, _) = malformedStudioDocument(&rng, maxCount: seed % 4 == 0 ? 60 : 24)
        let lookup = StudioDocument.Lookup(document.objects)
        let indices = lookup.indices()
        #expect(indices == expectedLookupIndices(document), "seed \(seed)")
        #expect(lookup.visibleFlags(indices) == lookup.visibleFlags(), "seed \(seed)")
        for (index, first) in indices.first.enumerated() where first != index { reached.insert("repeated id") }
        for parent in indices.parent {
            switch parent {
            case StudioDocument.Lookup.Indices.noParent: reached.insert("root")
            case StudioDocument.Lookup.Indices.missingParent: reached.insert("missing parent")
            default: reached.insert("parent")
            }
        }
    }
    #expect(reached == ["repeated id", "root", "missing parent", "parent"], "\(reached)")
}

/// #387 round 3: the arrays answer for the list they were built from, so a
/// lookup built after an in-place edit (reparent, delete, duplicate, move to
/// the end) or after an undo (the earlier list back) gives that list's
/// answers. The frame walk builds them every refresh, from that refresh's
/// list; they are never carried over.
@Test func studioLookupIndicesFollowEditsAndUndo() {
    for seed in UInt64(1)...64 {
        var rng = LookupSeed(state: seed)
        var (document, _, _) = malformedStudioDocument(&rng, maxCount: 30)
        let saved = document
        let before = StudioDocument.Lookup(saved.objects).indices()
        #expect(before == expectedLookupIndices(saved), "seed \(seed)")
        var edits = 0
        for step in 0..<6 {
            let count = document.objects.count
            switch (step + Int(seed)) % 4 {
            case 0 where count > 1: // reparent in place
                let k = Int.random(in: 0..<count, using: &rng)
                document.objects[k].parent = document.objects[Int.random(in: 0..<count, using: &rng)].id
            case 1 where count > 1: // delete
                document.objects.remove(at: Int.random(in: 0..<count, using: &rng))
            case 2: // duplicate under a new id, appended
                var copy = document.objects[Int.random(in: 0..<count, using: &rng)]
                copy.id = UUID()
                document.objects.append(copy)
            default: // move an object to the end, as setParent does
                let moved = document.objects.remove(at: Int.random(in: 0..<count, using: &rng))
                document.objects.append(moved)
            }
            edits += 1
            let after = StudioDocument.Lookup(document.objects).indices()
            #expect(after == expectedLookupIndices(document), "seed \(seed) edit \(step)")
            #expect(StudioDocument.Lookup(document.objects).visibleFlags(after) == document.objects.map { document.isVisible($0.id) },
                    "seed \(seed) edit \(step)")
        }
        #expect(edits == 6)
        // Undo: the saved list again, and its answers again.
        document = saved
        #expect(StudioDocument.Lookup(document.objects).indices() == before, "seed \(seed)")
    }
}
