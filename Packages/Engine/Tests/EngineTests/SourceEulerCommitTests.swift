import Foundation
import Testing
import simd
import CoreMath
@testable import Studio

// #391: a source object's Transform rows show CharaStudio's numbers (its Z-X-Y
// Euler angles, three decimals), and committing a field's unedited text changes
// the export only as CharaStudio's end-of-edit does: that one component becomes
// the float of its text, and everything else keeps its exact bytes.

/// Off-grid values: more decimals than the fields show, a rotation shown as
/// "360.000", and a negative angle.
private let offGrid = KoikatsuChangeAmount(
    position: SIMD3(0.13868962, -1.1538360, 0.50946385),
    rotationDegrees: SIMD3(10.1234, 359.99972, -30.9012),
    scale: SIMD3(1.12, 0.98765, 1))

/// The float a 3-decimal field shows for `value`, read back.
private func shown(_ value: Float) -> Float { Float(String(format: "%.3f", Double(value)))! }

private func bits(_ value: SIMD3<Float>) -> [UInt32] { [value.x.bitPattern, value.y.bitPattern, value.z.bitPattern] }

private typealias SourceScene = (document: KoikatsuSceneDocument, record: KoikatsuObjectRecord)

/// The synthetic scene with route 20 saved at `transform`, and that record.
private func sourceScene(_ transform: KoikatsuChangeAmount = offGrid) throws -> SourceScene {
    let base = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    let data = try base.editedData(.init(transforms: [.init(.object(20), transform: transform)]))
    let document = try KoikatsuSceneReader.decodeDocument(data)
    return (document, try #require(document.snapshot.roots.first { $0.sourceKey == 20 }))
}

/// Exports route 20 with `transform` as the editor does, and reads its record back.
private func exported(_ transform: StudioTransform, from scene: SourceScene) throws -> KoikatsuChangeAmount {
    let edits = transform.sourceChangeAmount(original: scene.record.transform).map {
        [SourceSceneEdits.TransformEdit(.object(20), transform: $0)]
    } ?? []
    let data = try scene.document.editedData(.init(transforms: edits))
    return try #require(try KoikatsuSceneReader.decodeDocument(data).snapshot.roots.first { $0.sourceKey == 20 }).transform
}

@Test func committingAnUneditedSourceRotationFieldExportsOnlyThatComponentRounded() throws {
    let scene = try sourceScene()
    #expect(bits(scene.record.transform.rotationDegrees) == bits(offGrid.rotationDegrees))
    let imported = StudioTransform(source: scene.record.transform)
    #expect(bits(imported.sourceRotationDegrees) == bits(offGrid.rotationDegrees))
    #expect(imported.sourceChangeAmount(original: scene.record.transform) == nil)

    for component in 0..<3 {
        var transform = imported
        transform.set(.sourceRotation, component, to: shown(transform.sourceRotationDegrees[component]))
        var expected = offGrid.rotationDegrees
        expected[component] = shown(expected[component]).truncatingRemainder(dividingBy: 360)
        #expect(bits(transform.sourceRotationDegrees) == bits(expected))
        #expect(transform.quaternion.vector == UnityCoordinates.eulerDegrees(expected).vector)
        let record = try exported(transform, from: scene)
        // Field by field: the committed angle is its text's float (modulo 360,
        // sign kept); the other two angles, position and scale are the saved bytes.
        #expect(bits(record.rotationDegrees) == bits(expected), "Rot \(["X", "Y", "Z"][component])")
        #expect(bits(record.position) == bits(offGrid.position) && bits(record.scale) == bits(offGrid.scale))
    }
    // Spelled out: 10.1234 -> 10.123, 359.99972 -> "360.000" -> 0, -30.9012 -> -30.901.
    #expect(shown(10.1234) == 10.123 && shown(359.99972).truncatingRemainder(dividingBy: 360) == 0 && shown(-30.9012) == -30.901)
}

@Test func anUneditedTabWalkRoundsPositionAndScaleOnlyAndASecondWalkChangesNothing() throws {
    let scene = try sourceScene()
    let imported = StudioTransform(source: scene.record.transform)
    var transform = imported
    for component in 0..<3 {
        transform.set(.position, component, to: shown(transform.position[component]))
        transform.set(.scale, component, to: shown(transform.scale[component]))
    }
    #expect(transform.rotationOverride == imported.rotationOverride && transform.currentSourceEuler == offGrid.rotationDegrees)
    let record = try exported(transform, from: scene)
    #expect(bits(record.rotationDegrees) == bits(offGrid.rotationDegrees))
    #expect(record.position == SIMD3(shown(offGrid.position.x), shown(offGrid.position.y), shown(offGrid.position.z)))
    #expect(record.scale == SIMD3(shown(offGrid.scale.x), shown(offGrid.scale.y), shown(offGrid.scale.z)))

    // A full walk, then another: the second commits the values it shows, which
    // writes nothing, so it takes no undo step (#390).
    for component in 0..<3 { transform.set(.sourceRotation, component, to: shown(transform.sourceRotationDegrees[component])) }
    let walked = transform
    for vector in [StudioTransform.Vector.position, .sourceRotation, .scale] {
        for component in 0..<3 {
            let value = vector == .position ? transform.position[component]
                : vector == .scale ? transform.scale[component] : transform.sourceRotationDegrees[component]
            transform.set(vector, component, to: shown(value))
        }
    }
    #expect(transform == walked)
}

@Test func aGizmoRotateAfterACommitRetiresTheSourceAngles() throws {
    let scene = try sourceScene()
    var transform = StudioTransform(source: scene.record.transform)
    transform.set(.sourceRotation, 1, to: 45)
    #expect(transform.currentSourceEuler == SIMD3(offGrid.rotationDegrees.x, 45, offGrid.rotationDegrees.z))

    // The gizmo's rotate drag writes engine Euler angles (StudioModel, `.gizmo` `.rotate`).
    var dragged = transform
    let turned = (simd_quatf(angle: 0.3, axis: normalize(SIMD3<Float>(1, 2, 3))) * transform.quaternion).normalized
    dragged.rotation = turned.eulerXYZ.radiansToDegrees
    #expect(dragged.currentSourceEuler == nil && dragged.sourceEuler == nil)
    #expect(dragged.sourceRotationDegrees == UnityCoordinates.sourceEulerDegrees(dragged.quaternion))
    #expect(try exported(dragged, from: scene).rotationDegrees == UnityCoordinates.sourceEulerDegrees(dragged.quaternion))

    // Reparenting writes an exact quaternion of its own.
    var object = StudioObject(name: "Route", kind: .folder)
    object.transform = transform
    let moved = try SourceStudioWorldTransform.reparented(object, world: float4x4(turned), parentFrame: matrix_identity_float4x4)
    #expect(moved.transform.currentSourceEuler == nil)

    // Self-validating: angles that a write path left behind for another
    // override are not used, whatever path wrote it.
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(transform)) as? [String: Any])
    #expect(json["sourceEuler"] != nil)
    json["rotationOverride"] = [turned.vector.x, turned.vector.y, turned.vector.z, turned.vector.w]
    let stale = try JSONDecoder().decode(StudioTransform.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(stale.sourceEuler != nil && stale.currentSourceEuler == nil)
    #expect(stale.sourceRotationDegrees == UnityCoordinates.sourceEulerDegrees(stale.quaternion))
    #expect(try exported(stale, from: scene).rotationDegrees == UnityCoordinates.sourceEulerDegrees(stale.quaternion))
}

@Test func documentsSavedWithoutSourceAnglesLoadAndExportAsBefore() throws {
    let scene = try sourceScene()
    var object = StudioObject(name: "Route", kind: .folder)
    object.sourceObjectKey = 20
    object.transform = StudioTransform(source: scene.record.transform)
    var document = StudioDocument()
    document.objects = [object]
    let data = try JSONEncoder().encode(document)

    // Saved with the angles, a document reloads with them still current.
    let reloaded = try JSONDecoder().decode(StudioDocument.self, from: data)
    #expect(reloaded == document && reloaded.objects[0].transform.currentSourceEuler == offGrid.rotationDegrees)

    // A document saved before #391 has no `sourceEuler`: it loads with its
    // exact quaternion, its Rotation row shows that quaternion's angles, and an
    // unedited object still exports nothing.
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var objects = try #require(json["objects"] as? [[String: Any]])
    var transform = try #require(objects[0]["transform"] as? [String: Any])
    #expect(transform.removeValue(forKey: "sourceEuler") != nil)
    objects[0]["transform"] = transform
    json["objects"] = objects
    let old = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: json)).objects[0].transform
    #expect(old.sourceEuler == nil && old.rotationOverride == object.transform.rotationOverride)
    #expect(old.sourceRotationDegrees == UnityCoordinates.sourceEulerDegrees(old.quaternion))
    #expect(old.sourceChangeAmount(original: scene.record.transform) == nil)
}
