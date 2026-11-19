import Testing
import Foundation
import CoreMath
import Assets
import Scene
import Character
@testable import Studio

/// #409: the `objects` buffer census the `studio-edit-steps` workload records
/// (`StudioObjectStorageCensus`), and `StudioObject`'s inline layout, which
/// sets how many bytes each kept copy of the array costs.

private func census(_ documents: [StudioDocument]) -> StudioObjectStorageCensus.Count {
    StudioObjectStorageCensus.count(documents)
}

private func document(objects: Int) -> StudioDocument {
    var document = StudioDocument()
    document.objects = (0..<objects).map { StudioObject(name: "Prop \($0)", kind: .item) }
    return document
}

@Test func storageCensusCountsASharedBufferOnce() {
    let current = document(objects: 10)
    let snapshot = current
    let shared = census([current, snapshot, current])
    #expect(shared.buffers == 1)
    #expect(shared.capacity >= 10)
    #expect(shared.bytes >= StudioObjectStorageCensus.headerBytes + 10 * MemoryLayout<StudioObject>.stride)

    var edited = snapshot
    edited.objects[0].name = "Moved"
    let afterEdit = census([current, snapshot, edited])
    #expect(afterEdit.buffers == 2)
    #expect(afterEdit.bytes >= 2 * shared.bytes - 64)
}

@Test func storageCensusFollowsTheUndoHistory() {
    var history = StudioUndoHistory<StudioDocument>()
    var current = document(objects: 4)
    func live() -> StudioObjectStorageCensus.Count { census([current] + history.undoStack + history.redoStack) }
    history.record(current)
    #expect(live().buffers == 1)
    current.objects[1].visible = false
    #expect(live().buffers == 2)
    history.record(current)
    #expect(live().buffers == 2)
    // Undo and redo move documents between the stacks; they copy nothing.
    if let step = history.stepBack(leaving: current) { current = step }
    #expect(live().buffers == 2)
    if let step = history.stepForward(leaving: current) { current = step }
    #expect(live().buffers == 2)
}

@Test func storageCensusSkipsEmptyObjects() {
    #expect(census([StudioDocument(), StudioDocument()]) == StudioObjectStorageCensus.Count())
}

/// Records `StudioObject`'s size, stride and each stored field's offset and
/// inline size. #409 scoping found stride 1,584 B at df0077c0, `card` the
/// largest field; the ten large, seldom-edited fields now share one box
/// (`cold`, one reference), which leaves 432 B. A new stored field changes
/// the stride: box it with the others if it is large and seldom edited.
@Test func studioObjectLayout() {
    typealias O = StudioObject
    let fields: [(String, PartialKeyPath<O>, Int)] = [
        ("id", \O.id, MemoryLayout<UUID>.size), ("name", \O.name, MemoryLayout<String>.size),
        ("kind", \O.kind, MemoryLayout<StudioObjectKind>.size), ("parent", \O.parent, MemoryLayout<UUID?>.size),
        ("visible", \O.visible, 1), ("locked", \O.locked, 1),
        ("transform", \O.transform, MemoryLayout<StudioTransform>.size), ("cold", \O.cold, MemoryLayout<StudioObjectColdFields>.size),
        ("sourcePreviewName", \O.sourcePreviewName, MemoryLayout<String?>.size),
        ("sourcePreviewKind", \O.sourcePreviewKind, MemoryLayout<StudioObjectKind?>.size),
        ("sourceAttachmentPoint", \O.sourceAttachmentPoint, MemoryLayout<Int32?>.size),
        ("sourceFKRotations", \O.sourceFKRotations, MemoryLayout<[Int: Float3]?>.size),
        ("sourceIKOverrides", \O.sourceIKOverrides, MemoryLayout<[Int32: SourceStudioIKEdit]?>.size),
        ("sourceFaceValues", \O.sourceFaceValues, MemoryLayout<[Float]?>.size),
        ("sourceBodyValues", \O.sourceBodyValues, MemoryLayout<[Float]?>.size),
        ("sourceColorEdits", \O.sourceColorEdits, MemoryLayout<[String: Float4]?>.size),
        ("sourceOutfit", \O.sourceOutfit, MemoryLayout<Int?>.size),
        ("sourceClothesState", \O.sourceClothesState, MemoryLayout<[UInt8]?>.size),
        ("sourceShowAccessory", \O.sourceShowAccessory, MemoryLayout<[Bool]?>.size),
        ("sourceShoesType", \O.sourceShoesType, MemoryLayout<Int?>.size),
        ("ikTargets", \O.ikTargets, MemoryLayout<[IKChain: IKTarget]>.size),
        ("animationPreset", \O.animationPreset, MemoryLayout<String?>.size),
        ("clothingVisible", \O.clothingVisible, 1), ("accessoriesVisible", \O.accessoriesVisible, 1),
        ("handGestureL", \O.handGestureL, 8), ("handGestureR", \O.handGestureR, 8),
        ("itemID", \O.itemID, MemoryLayout<String?>.size), ("assetFile", \O.assetFile, MemoryLayout<String?>.size),
        ("sourceObjectKey", \O.sourceObjectKey, MemoryLayout<Int32?>.size),
        ("sourceDuplicateOf", \O.sourceDuplicateOf, MemoryLayout<Int32?>.size),
        ("sourceRecordKind", \O.sourceRecordKind, MemoryLayout<KoikatsuObjectKind?>.size),
        ("tint", \O.tint, MemoryLayout<RGB?>.size), ("emissive", \O.emissive, 4), ("fov", \O.fov, 4),
    ]
    let stride = MemoryLayout<O>.stride
    print("[layout] StudioObject size \(MemoryLayout<O>.size) stride \(stride) alignment \(MemoryLayout<O>.alignment)")
    let placed = fields.compactMap { name, path, size in MemoryLayout<O>.offset(of: path).map { (name, $0, size) } }
        .sorted { $0.1 < $1.1 }
    #expect(placed.count == fields.count)
    for (index, field) in placed.enumerated() {
        let span = (index + 1 < placed.count ? placed[index + 1].1 : stride) - field.1
        print("[layout] \(field.0) offset \(field.1) size \(field.2) span \(span)")
        #expect(field.2 <= span)
    }
    #expect(stride % MemoryLayout<O>.alignment == 0)
    #expect(stride == 432)
}
