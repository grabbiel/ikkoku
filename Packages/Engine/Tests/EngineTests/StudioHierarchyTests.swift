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
