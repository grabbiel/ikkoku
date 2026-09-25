import Testing
import Foundation
import Metal
import simd
import Assets
import CoreMath
import ShaderTypes
@testable import Renderer

@Test func skinInfluencesRejectMalformedWeightsAndCounts() throws {
    let joints = [SIMD4<UInt16>(0, 1, 2, 3)]
    for weights in [Float4.zero, Float4(-1, 2, 0, 0), Float4(.nan, 1, 0, 0), Float4(.infinity, 0, 0, 0)] {
        #expect(throws: ResourceError.self) {
            try ValidatedSkinInfluences(joints: joints, weights: [weights], vertexCount: 1)
        }
    }
    #expect(throws: ResourceError.self) {
        try ValidatedSkinInfluences(joints: joints, weights: [], vertexCount: 1)
    }
    #expect(throws: ResourceError.self) {
        try ValidatedSkinInfluences(joints: [], weights: [Float4(1, 0, 0, 0)], vertexCount: 1)
    }
    let quantized = try ValidatedSkinInfluences(joints: joints, weights: [Float4(128.0 / 255, 128.0 / 255, 0, 0)], vertexCount: 1)
    #expect(quantized.vertices[0].weights == Float4(0.5, 0.5, 0, 0))
    let large = try ValidatedSkinInfluences(joints: joints, weights: [Float4(repeating: .greatestFiniteMagnitude)], vertexCount: 1)
    #expect(large.vertices[0].weights == Float4(repeating: 0.25))
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func skinPaletteValidationIncludesZeroWeightLanesAbove256() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let mesh = MeshData(name: "palette-boundary", positions: [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)],
                        normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
                        joints: [SIMD4<UInt16>](repeating: SIMD4<UInt16>(0, 0, 0, 300), count: 3),
                        weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3), indices: [0, 1, 2])
    let handle = try resources.register(mesh: mesh)
    let loaded = try #require(resources.mesh(handle))
    #expect(loaded.requiredBoneCount == 301)
    #expect(throws: ResourceError.self) { try loaded.validateSkinPalette(boneCount: 300) }
    #expect(throws: ResourceError.self) { try loaded.validateSkinPalette(boneCount: 0) }
    try loaded.validateSkinPalette(boneCount: 301)
}

/// Executes the real Metal kernel, including its independent invalid-input guards.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func deformKernelPreservesNormalsReflectionsAndPaletteBounds() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let header = try String(contentsOf: root.appendingPathComponent("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h"), encoding: .utf8)
    let kernel = try String(contentsOf: root.appendingPathComponent("Shaders/Deform.metal"), encoding: .utf8)
    let source = "#include <metal_stdlib>\nusing namespace metal;\n" + header + "\n"
        + kernel.replacingOccurrences(of: "#include \"Common.h\"", with: "")
    let library = try device.makeLibrary(source: source, options: nil)
    let function = try #require(library.makeFunction(name: "deform_vertices"))
    let pipeline = try device.makeComputePipelineState(function: function)
    let queue = try #require(device.makeCommandQueue())
    let n = normalize(Float3(1, 1, 0))
    let t = normalize(Float3(1, -1, 0))
    let base = DeformedVertex(position: Float4(1, 2, 3, 0), normal: Float4(n.x, n.y, n.z, 1), tangent: Float4(t.x, t.y, t.z, 1))

    func run(matrix: float4x4, joints: SIMD4<UInt16> = SIMD4<UInt16>(300, 0, 0, 0),
             weights: Float4 = Float4(1, 0, 0, 0), count: UInt32 = 301) throws -> DeformedVertex {
        var palette = [float4x4](repeating: matrix_identity_float4x4, count: 301)
        palette[300] = matrix
        let input = try #require(device.makeBuffer(bytes: [base], length: MemoryLayout<DeformedVertex>.stride, options: .storageModeShared))
        let output = try #require(device.makeBuffer(length: MemoryLayout<DeformedVertex>.stride, options: .storageModeShared))
        let skin = try #require(device.makeBuffer(bytes: [SkinVertex(joints: joints, weights: weights)], length: MemoryLayout<SkinVertex>.stride, options: .storageModeShared))
        let bones = try #require(device.makeBuffer(bytes: palette, length: MemoryLayout<float4x4>.stride * palette.count, options: .storageModeShared))
        let dummy = try #require(device.makeBuffer(length: 16, options: .storageModeShared))
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (buffer, index) in [(input, BufferIndexBaseVertices), (output, BufferIndexVertices), (skin, BufferIndexSkinData),
                                 (bones, BufferIndexSkinMatrices), (dummy, BufferIndexMorphWeights), (dummy, BufferIndexMorphDeltas),
                                 (dummy, BufferIndexMorphNormals)] {
            encoder.setBuffer(buffer, offset: 0, index: Int(index.rawValue))
        }
        var params = DeformParams(vertexCount: 1, activeMorphCount: 0, hasSkin: 1, hasMorphNormals: 0, boneCount: count)
        encoder.setBytes(&params, length: MemoryLayout<DeformParams>.stride, index: Int(BufferIndexDeformParams.rawValue))
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        return output.contents().load(as: DeformedVertex.self)
    }
    func xyz(_ v: Float4) -> Float3 { Float3(v.x, v.y, v.z) }
    let matrix = Transform.translation(Float3(7, 0, 0)) * Transform.scale(Float3(2, 1, 0.5))
    let deformed = try run(matrix: matrix)
    #expect(length(xyz(deformed.position) - Float3(9, 2, 1.5)) < 1e-5)
    #expect(length(xyz(deformed.normal) - normalize(Float3(0.5, 1, 0))) < 1e-5)
    #expect(length(xyz(deformed.tangent) - normalize(Float3(2, -1, 0))) < 1e-5)
    #expect(abs(dot(xyz(deformed.normal), xyz(deformed.tangent))) < 1e-5)
    let reflected = try run(matrix: Transform.scale(Float3(-2, 1, 0.5)))
    #expect(length(xyz(reflected.normal) - normalize(Float3(-0.5, 1, 0))) < 1e-5)
    #expect(reflected.tangent.w == -1)
    let singular = try run(matrix: Transform.scale(Float3(0, 1, 1)))
    #expect(length(xyz(singular.normal) - n) < 1e-5)
    #expect(singular.tangent.w == 1)
    #expect(xyz(singular.position) == Float3(0, 2, 3))
    // Even a zero-weight out-of-bounds lane must disable the palette reads.
    let invalidJoint = try run(matrix: matrix, joints: SIMD4<UInt16>(300, 0, 0, 301))
    #expect(invalidJoint.position == base.position)
    let missingPalette = try run(matrix: matrix, count: 0)
    #expect(missingPalette.position == base.position)
    for bad in [Float4.zero, Float4(-1, 2, 0, 0), Float4(.nan, 1, 0, 0), Float4(.infinity, 0, 0, 0)] {
        let invalid = try run(matrix: matrix, weights: bad)
        #expect(invalid.position == base.position)
        #expect(length(xyz(invalid.normal) - n) < 1e-5)
    }
}
