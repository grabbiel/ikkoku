import Foundation
import Testing
import Metal
import simd
import Assets
import CoreMath
@testable import Scene
import Character
@testable import Renderer

private func previewRigFixture(malformedSecondPart: Bool = false) throws -> SourceRig {
    let rig = try RigDefinition(nodes: [
        .init(name: "mesh", sourceID: "mesh", parent: nil),
        .init(name: "joint", sourceID: "joint", parent: nil)], skins: [
            .init(name: "skin", meshNode: 0, joints: [1], inverseBindMatrices: [matrix_identity_float4x4])])
    let mesh = MeshData(name: "preview triangle", positions: [.zero, Float3(1, 0, 0), Float3(0, 1, 0)],
                        normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
                        joints: [SIMD4<UInt16>](repeating: .zero, count: 3),
                        weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3), indices: [0, 1, 2])
    var parts = [SourceRig.Part(mesh: mesh, node: 0, skin: 0, rendererEnabled: true)]
    if malformedSecondPart {
        var invalid = mesh
        invalid.weights = [Float4](repeating: .zero, count: 3)
        parts.append(SourceRig.Part(mesh: invalid, node: 0, skin: 0, rendererEnabled: true))
    }
    return SourceRig(sourcePrefab: "test", rig: rig, parts: parts, morphChannelCount: 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewReleasesMeshesAndDeformationBuffers() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    var preview: SourceRigPreview? = try SourceRigPreview(source: previewRigFixture(), contract: nil, resources: resources)
    weak var weakPreview = preview
    let frame = try #require(preview).frame(camera: OrbitCamera())
    let item = try #require(frame.items.first)
    let retainedMesh = try #require(resources.mesh(item.mesh))
    let key = try #require(item.deformKey)
    let oldDeform = try #require(resources.deformBuffer(for: key, vertexCount: 3))
    preview = nil
    #expect(weakPreview == nil)
    #expect(resources.mesh(item.mesh) == nil)
    #expect(retainedMesh.vertexCount == 3) // A prepared frame can still retain its mesh.
    let replacement = try #require(resources.deformBuffer(for: key, vertexCount: 3))
    #expect(oldDeform !== replacement)
    resources.releaseDeformBuffers(keys: [key])
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewRollsBackMeshesWhenLaterRegistrationFails() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let source = try previewRigFixture(malformedSecondPart: true)
    #expect(throws: ResourceError.self) {
        try SourceRigPreview(source: source, contract: nil, resources: resources)
    }
    // A fresh store assigns handle one to the valid first part before the second fails.
    #expect(resources.mesh(MeshHandle(id: 1)) == nil)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewRejectsInactiveBoundsAndAcceptsSkeletonOnly() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for active in [false, true] {
        let rig = try RigDefinition(nodes: [.init(name: "root", sourceID: "root", parent: nil, active: active)], skins: [])
        let source = SourceRig(sourcePrefab: "skeleton", rig: rig, parts: [], morphChannelCount: 0)
        if active {
            let preview = try SourceRigPreview(source: source, contract: nil, resources: resources)
            #expect(try preview.bounds().center == .zero)
        } else {
            #expect(throws: RigError.self) { try SourceRigPreview(source: source, contract: nil, resources: resources) }
        }
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewRepeatsMaterialSlotsWithoutDuplicatingGeometry() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("appearance.json")
    try Data(#"{"schemaVersion":1,"parts":[{"part":"preview triangle","kind":"unlit","color":[1,1,1,1],"alphaMode":"BLEND"},{"part":"preview triangle","pass":1,"kind":"unlit","color":[1,0,0,1],"alphaMode":"BLEND"}]}"#.utf8).write(to: url)
    let appearance = try SourcePreviewAppearance.load(url: url, resources: resources)
    let preview = try SourceRigPreview(source: previewRigFixture(), contract: nil, resources: resources, appearance: appearance)
    let frame = try preview.frame(camera: OrbitCamera())
    #expect(frame.items.count == 2)
    #expect(frame.items[0].mesh == frame.items[1].mesh)
    #expect(frame.items[0].deformKey == frame.items[1].deformKey)
    #expect(frame.items.map(\.order) == [0, 1])
    #expect(frame.items[0].material.uniforms.baseColor != frame.items[1].material.uniforms.baseColor)
    #expect(frame.skinSets.count == 1)
}

private func canineCard(_ value: SourceMessagePackValue?) throws -> SourceCharacterCard {
    typealias F = OriginalCardFixture
    var fields: [(String, F.Value)] = [("version", .string("0.0.2"))]
    if let value { fields.append(("doubleTooth", value)) }
    let custom = F.lengthData(F.pack(F.map(fields))) + F.lengthData(Data()) + F.lengthData(Data())
    return try .decode(F.card(blocks: F.blocks(custom: custom)))
}

@Test func sourceRigPreviewReadsOnlyBooleanDoubleToothWithoutChangingCardBytes() throws {
    for flag: Bool? in [false, true, nil] {
        let card = try canineCard(flag.map { .bool($0) }), original = card.preservedData
        #expect(try SourceRigPreview.savedDoubleTooth(in: card) == flag)
        #expect(card.preservedData == original)
    }
    for value: SourceMessagePackValue in [.integer(1), .string("true"), .null] {
        #expect(throws: RigError.self) { try SourceRigPreview.savedDoubleTooth(in: canineCard(value)) }
    }
}

private func caninePreviewFixture(canineActive: Bool, parentActive: Bool = true, duplicate: Bool = false) throws -> SourceRig {
    var nodes: [RigDefinition.Node] = [
        .init(name: "root", sourceID: "root", parent: nil),
        .init(name: "head", sourceID: "head", parent: 0, active: parentActive),
        .init(name: "cf_O_canine", sourceID: "canine", parent: 1, active: canineActive),
        .init(name: "canine child", sourceID: "canine-child", parent: 2),
        .init(name: "inactive child", sourceID: "inactive-child", parent: 2, active: false),
        .init(name: "other", sourceID: "other", parent: 0)]
    if duplicate { nodes.append(.init(name: "cf_O_canine", sourceID: "ambiguous", parent: 0)) }
    let skins = (2...5).map { RigDefinition.Skin(name: "skin-\($0)", meshNode: $0, joints: [0], inverseBindMatrices: [matrix_identity_float4x4]) }
    let rig = try RigDefinition(nodes: nodes, skins: skins)
    let parts = (2...5).map { index -> SourceRig.Part in
        // A similarly named unrelated mesh must not follow the canine object.
        let name = index == 5 ? "cf_O_canine_similar/0" : "part-\(index)"
        let mesh = MeshData(name: name, positions: [Float3(Float(index), 0, 0), Float3(Float(index) + 0.5, 0, 0), Float3(Float(index), 1, 0)],
            normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
            joints: [SIMD4<UInt16>](repeating: .zero, count: 3),
            weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3), indices: [0, 1, 2])
        return .init(mesh: mesh, node: index, skin: index - 2, rendererEnabled: true)
    }
    let disabled = SourceRig.Part(mesh: parts[0].mesh, node: 2, skin: 0, rendererEnabled: false)
    return SourceRig(sourcePrefab: "canine-test", rig: rig, parts: parts + [disabled], morphChannelCount: 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewCanineToggleUsesGameObjectActivityAndRetainsResources() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for authored in [false, true] {
        let source = try caninePreviewFixture(canineActive: authored)
        let preview = try SourceRigPreview(source: source, contract: nil, resources: resources,
            doubleTooth: SourceRigPreview.savedDoubleTooth(in: canineCard(.bool(false))))
        let off = try preview.frame(camera: OrbitCamera()), generation = resources.generation
        #expect(off.items.count == 1)
        preview.doubleTooth = true
        let on = try preview.frame(camera: OrbitCamera())
        #expect(on.items.count == 3) // Object + active descendant; no inactive child/disabled renderer.
        #expect(on.items.last?.mesh == off.items.first?.mesh)
        #expect(on.sceneBounds.min.x <= 2 && on.sceneBounds.max.x >= 5.5)
        #expect(on.sceneBounds.min == off.sceneBounds.min && on.sceneBounds.max == off.sceneBounds.max)
        let retained = try #require(resources.mesh(on.items[0].mesh))
        for _ in 0..<20 {
            preview.doubleTooth = false
            #expect(try preview.frame(camera: OrbitCamera()).items.map(\.mesh) == off.items.map(\.mesh))
            preview.doubleTooth = true
            #expect(try preview.frame(camera: OrbitCamera()).items.map(\.mesh) == on.items.map(\.mesh))
        }
        #expect(resources.generation == generation)
        #expect(resources.mesh(on.items[0].mesh) === retained)
        #expect(try preview.frame(camera: OrbitCamera(), hiddenParts: [0, 1]).items.map(\.mesh) == off.items.map(\.mesh))
        preview.doubleTooth = nil
        #expect(try preview.frame(camera: OrbitCamera()).items.count == (authored ? 3 : 1))
    }
    let parentOff = try SourceRigPreview(source: caninePreviewFixture(canineActive: true, parentActive: false),
        contract: nil, resources: resources, doubleTooth: true)
    #expect(try parentOff.frame(camera: OrbitCamera()).items.count == 1)
    #expect(throws: RigError.self) {
        try SourceRigPreview(source: caninePreviewFixture(canineActive: true, duplicate: true), contract: nil, resources: resources)
    }
    let noCanines = try SourceRigPreview(source: previewRigFixture(), contract: nil, resources: resources, doubleTooth: false)
    #expect(try noCanines.frame(camera: OrbitCamera()).items.count == 1)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceRigPreviewCaninesHideEveryMaterialPass() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("appearance.json")
    try Data(#"{"schemaVersion":1,"parts":[{"part":"part-2","kind":"unlit","color":[1,1,1,1],"alphaMode":"OPAQUE"},{"part":"part-2","pass":1,"kind":"unlit","color":[1,0,0,1],"alphaMode":"BLEND"}]}"#.utf8).write(to: url)
    let appearance = try SourcePreviewAppearance.load(url: url, resources: resources)
    let preview = try SourceRigPreview(source: caninePreviewFixture(canineActive: true), contract: nil, resources: resources,
        appearance: appearance, doubleTooth: true)
    let on = try preview.frame(camera: OrbitCamera())
    #expect(on.items.count == 4 && on.items[0].mesh == on.items[1].mesh)
    #expect(on.items[0].material.uniforms.baseColor != on.items[1].material.uniforms.baseColor)
    preview.doubleTooth = false
    let off = try preview.frame(camera: OrbitCamera())
    #expect(off.items.count == 1 && off.items[0].mesh == on.items[3].mesh)
    preview.doubleTooth = true
    let restored = try preview.frame(camera: OrbitCamera())
    #expect(restored.items.map(\.mesh) == on.items.map(\.mesh))
    #expect(restored.items.map(\.material.uniforms.baseColor) == on.items.map(\.material.uniforms.baseColor))
}
