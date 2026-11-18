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

/// Deterministic structure per seed for the lookup equivalence test.
private struct LookupSeed: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// #383: `StudioDocument.Lookup` answers exactly what the document's linear
/// functions answer, over hierarchies with repeated ids, missing parents,
/// self-parents, cycles and ids that are not in the document; the
/// inspector's parent list built through it is the same list.
@Test func studioLookupMatchesTheDocumentFunctionsOnMalformedHierarchies() {
    var malformed: [String: Int] = [:]
    for seed in UInt64(1)...64 {
        var rng = LookupSeed(state: seed)
        let count = Int.random(in: 1...24, using: &rng)
        let pool = (0..<count).map { _ in UUID() }
        let missing = (0..<3).map { _ in UUID() }
        var document = StudioDocument()
        for index in 0..<count {
            // About one in six objects repeats an earlier object's id.
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
