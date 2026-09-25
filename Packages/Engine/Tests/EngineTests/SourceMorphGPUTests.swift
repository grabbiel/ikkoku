import Foundation
import Testing
import Metal
import simd
import CoreMath
import Scene
import ShaderTypes
import Renderer

private func sourceMorphGPUFixture() throws -> SourceRig {
    let identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    func node(_ name: String, id: Int) -> [String: Any] {
        ["name": name, "sourceID": String(id), "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]]
    }
    func channel(_ name: String, indices: [Int], positions: [[Float]], normals: [[Float]]) -> [String: Any] {
        ["name": name, "frames": [["weight": 100, "indices": indices, "positionDeltas": positions,
            "normalDeltas": normals, "tangentDeltas": [] as [[Float]]]]]
    }
    let document: [String: Any] = [
        "schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up", "matrixLayout": "column-major",
        "uvConvention": "unity-source", "sourcePrefab": "synthetic-morph-gpu",
        "nodes": [node("mesh", id: 0), node("joint-a", id: 1), node("joint-b", id: 2)],
        "skins": [["name": "face", "meshNode": 0, "joints": [1, 2], "inverseBindMatrices": [identity, identity]]],
        "meshes": [["name": "face", "node": 0, "skin": 0,
            "positions": [[1, 2, 3], [-1, 1, 2], [0, -1, 1]],
            "normals": Array(repeating: [0, 0, 1], count: 3),
            "tangents": Array(repeating: [1, 0, 0, 1], count: 3), "uv0": [] as [[Float]],
            "joints": Array(repeating: [0, 1, 0, 0], count: 3),
            "weights": Array(repeating: [0.25, 0.75, 0, 0], count: 3),
            "submeshes": [["indices": [0, 1, 2]]], "initialMorphWeights": [0, 0, 0],
            "morphChannels": [
                channel("close", indices: [0, 2], positions: [[2, 0, 2], [0, 4, 0]], normals: [[1, 0, 0], [0, 2, 0]]),
                channel("inactive", indices: [0, 1, 2], positions: Array(repeating: [100, 100, 100], count: 3),
                    normals: Array(repeating: [20, 20, 20], count: 3)),
                channel("open", indices: [1, 0], positions: [[0, 2, -2], [-2, 2, 0]], normals: [[0, 1, 1], [0, 1, 0]])]]]]
    return try SourceRig.decode(JSONSerialization.data(withJSONObject: document))
}

/// Checks the source sparse-frame -> dense packed GPU buffer -> production kernel boundary.
/// Expected results are calculated explicitly, independently of the CPU deformation helper.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMorphGPUCombinesIndexedFramesBeforeSkinningAndTransformsMorphedNormals() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = try sourceMorphGPUFixture()
    let part = try #require(source.parts.first)
    #expect(part.mesh.morphTargets.map(\.name) == ["close", "inactive", "open"])
    #expect(part.mesh.morphTargets[0].positionDeltas[1] == .zero)
    #expect(part.mesh.morphTargets[2].positionDeltas[2] == .zero)
    #expect(part.mesh.morphTargets[2].normalDeltas[1] == Float3(0, 1, -1))
    let resources = ResourceStore(device: device)
    let mesh = try #require(resources.mesh(try resources.register(mesh: part.mesh)))
    let skin = try #require(mesh.skin), deltas = try #require(mesh.morphDeltas), normals = try #require(mesh.morphNormals)
    // packed_float3 is a 12-byte target-major element; SIMD3's CPU stride is 16.
    #expect(MemoryLayout<PackedFloat3>.stride == 12)
    #expect(deltas.length == 3 * 3 * 12 && normals.length == 3 * 3 * 12)
    let weights: [(index: Int, weight: Float)] = [(2, 0.5), (0, 0.25)]
    try SourceRig.validateMorphWeights(weights, mesh: part.mesh)
    let entries = weights.map { MorphWeightEntry(index: UInt32($0.index), weight: $0.weight) }

    // Blended palette maps (x,y,z) to (10 - 3y, -4 + 2x, 2 + 4z).
    // Its inverse-transpose maps normals to (-ny/3, nx/2, nz/4), before normalization.
    func joint(_ translation: Float4) -> float4x4 {
        float4x4(columns: (Float4(0, 2, 0, 0), Float4(-3, 0, 0, 0), Float4(0, 0, 4, 0), translation))
    }
    var pose = source.rig.restPose
    pose.localMatrices[1] = joint(Float4(7, -1, 5, 1))
    pose.localMatrices[2] = joint(Float4(11, -5, 1, 1))
    let evaluation = try source.rig.evaluate(pose)
    let palette = evaluation.palettes[part.skin]
    let bones = try #require(device.makeBuffer(bytes: palette, length: MemoryLayout<float4x4>.stride * palette.count, options: .storageModeShared))
    let morphs = try #require(device.makeBuffer(bytes: entries, length: MemoryLayout<MorphWeightEntry>.stride * entries.count, options: .storageModeShared))

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let header = try String(contentsOf: root.appendingPathComponent("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h"), encoding: .utf8)
    let kernel = try String(contentsOf: root.appendingPathComponent("Shaders/Deform.metal"), encoding: .utf8)
    let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header
        + kernel.replacingOccurrences(of: "#include \"Common.h\"", with: ""), options: nil)
    let function = try #require(library.makeFunction(name: "deform_vertices"))
    let pipeline = try device.makeComputePipelineState(function: function)
    let queue = try #require(device.makeCommandQueue())

    func run(activeCount: UInt32 = 2, hasNormals: Bool = true, hasSkin: Bool = true) throws -> [DeformedVertex] {
        let output = try #require(device.makeBuffer(length: MemoryLayout<DeformedVertex>.stride * mesh.vertexCount, options: .storageModeShared))
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (buffer, index) in [(mesh.baseVertices, BufferIndexBaseVertices), (output, BufferIndexVertices),
            (skin, BufferIndexSkinData), (bones, BufferIndexSkinMatrices), (morphs, BufferIndexMorphWeights),
            (deltas, BufferIndexMorphDeltas), (normals, BufferIndexMorphNormals)] {
            encoder.setBuffer(buffer, offset: 0, index: Int(index.rawValue))
        }
        var params = DeformParams(vertexCount: UInt32(mesh.vertexCount), activeMorphCount: activeCount,
            hasSkin: hasSkin ? 1 : 0, hasMorphNormals: hasNormals ? 1 : 0, boneCount: UInt32(palette.count))
        encoder.setBytes(&params, length: MemoryLayout<DeformParams>.stride, index: Int(BufferIndexDeformParams.rawValue))
        encoder.dispatchThreads(MTLSize(width: mesh.vertexCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed, "Source morph Metal dispatch failed: \(String(describing: command.error))")
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: DeformedVertex.self), count: mesh.vertexCount))
    }
    func xyz(_ value: Float4) -> Float3 { Float3(value.x, value.y, value.z) }
    func expect(_ actual: Float3, _ expected: Float3, _ label: String) {
        #expect(length(actual - expected) < 1e-5, "\(label): \(actual) != \(expected)")
    }
    let expectedPositions = [Float3(1, -3, -12), Float3(4, -6, -2), Float3(10, -4, -2)]
    let expectedNormals = [normalize(Float3(-1.0 / 6, 1.0 / 8, -1.0 / 4)),
        normalize(Float3(-1.0 / 6, 0, -3.0 / 8)), normalize(Float3(-1.0 / 6, 0, -1.0 / 4))]
    let morphed = try run()
    for vertex in 0..<3 {
        expect(xyz(morphed[vertex].position), expectedPositions[vertex], "morph before skin / vertex \(vertex)")
        expect(xyz(morphed[vertex].normal), expectedNormals[vertex], "inverse-transpose morphed normal / vertex \(vertex)")
        #expect(abs(length(xyz(morphed[vertex].normal)) - 1) < 1e-5)
        #expect(morphed[vertex].position.w == 0 && morphed[vertex].normal.w == 1)
        expect(xyz(morphed[vertex].tangent), Float3(0, 1, 0), "unchanged source tangent transformed by skin")
        #expect(morphed[vertex].tangent.w == 1)
    }
    // These wrong-order alternatives deliberately produce visibly different results.
    #expect(length(xyz(morphed[0].position) - Float3(3.5, -1, -10.5)) > 1)
    #expect(length(xyz(morphed[0].normal) - normalize(Float3(-1.5, 0.5, -4))) > 0.1)

    let noNormalMorphs = try run(hasNormals: false)
    let noSkin = try run(hasSkin: false)
    let reset = try run(activeCount: 0)
    let preSkinPositions = [Float3(0.5, 3, -3.5), Float3(-1, 2, -1), Float3(0, 0, -1)]
    let preSkinNormals = [normalize(Float3(0.25, 0.5, -1)), normalize(Float3(0, 0.5, -1.5)), normalize(Float3(0, 0.5, -1))]
    let neutralPositions = [Float3(4, -2, -10), Float3(7, -6, -6), Float3(13, -4, -2)]
    for vertex in 0..<3 {
        expect(xyz(noNormalMorphs[vertex].position), expectedPositions[vertex], "normal toggle preserves position")
        expect(xyz(noNormalMorphs[vertex].normal), Float3(0, 0, -1), "absent normal deltas")
        expect(xyz(noSkin[vertex].position), preSkinPositions[vertex], "unskinned morph accumulation")
        expect(xyz(noSkin[vertex].normal), preSkinNormals[vertex], "unskinned morphed normal")
        expect(xyz(reset[vertex].position), neutralPositions[vertex], "neutral draw starts from immutable base")
        expect(xyz(reset[vertex].normal), Float3(0, 0, -1), "neutral normal restored")
    }
}
