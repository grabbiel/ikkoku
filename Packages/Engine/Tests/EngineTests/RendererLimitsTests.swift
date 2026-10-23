import Testing
import Foundation
import Metal
import simd
import CoreGraphics
import Assets
import CoreMath
import Scene
import ShaderTypes
import GPU
@testable import Renderer

// R6: renderer limits and resource lifetime are recoverable and observable.

/// Completed handlers can run after `waitUntilCompleted` returns; poll briefly.
private func eventually(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return true
}

/// The production pass graph built from `Shaders/`; the test bundle has no metallib.
private func makeSourceShaderRenderer() throws -> Renderer {
    let gpu = try #require(GPUContext())
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    let header = try read("Packages/Engine/Sources/ShaderTypes/include/ShaderTypes.h")
    let common = try read("Shaders/Common.h").replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
    let shaders = try ["Deform", "Toon", "Shadow", "Outline", "Overlay", "Post"].map {
        try read("Shaders/\($0).metal").replacingOccurrences(of: "#include \"Common.h\"", with: "")
    }.joined(separator: "\n")
    let library = try gpu.device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + header + common + shaders,
                                             options: nil)
    return try Renderer(gpu: gpu, shaderLibrary: library)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func frameRingSpillsPastItsRegionWithIntactDataAndTypedErrors() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let ring = try #require(FrameRing(device: device, regionSize: 1024, regionCount: 2))
    #expect(throws: FrameRingError.noOpenFrame) { _ = try ring.allocate(UInt32(1)) }

    ring.beginFrame(0)
    var small: [(allocation: FrameAllocation, value: UInt32)] = []
    for i in 0..<12 {
        let value = UInt32(0xA000 + i)
        let allocation = try ring.allocate(value)
        small.append((allocation: allocation, value: value))
    }
    let large: [Float] = (0..<1000).map { Float($0) * 0.5 }
    let largeAllocation = try ring.allocate(array: large)

    // Twelve 256-byte slots: four fill the 1 KiB region and eight take two 1 KiB
    // overflow buffers. The 4000-byte array exceeds that chunk size and gets its own.
    let statistics = ring.frameStatistics
    #expect(statistics.region == 0)
    #expect(statistics.regionBytes == 1024)
    #expect(statistics.overflowBuffers == 3)
    #expect(statistics.overflowBytes == 8 * 256 + 4096)
    let ringID = ObjectIdentifier(ring.buffer)
    let firstFourInRegion = small.prefix(4).allSatisfy { ObjectIdentifier($0.allocation.buffer) == ringID }
    let restOverflow = small.dropFirst(4).allSatisfy { ObjectIdentifier($0.allocation.buffer) != ringID }
    #expect(firstFourInRegion)
    #expect(restOverflow)
    for entry in small {
        #expect(entry.allocation.offset % FrameRing.alignment == 0)
        #expect(entry.allocation.offset + 4 <= entry.allocation.buffer.length)
        #expect(entry.allocation.buffer.contents().load(fromByteOffset: entry.allocation.offset, as: UInt32.self) == entry.value)
    }
    let readBack = Array(UnsafeBufferPointer(
        start: largeAllocation.buffer.contents().advanced(by: largeAllocation.offset).assumingMemoryBound(to: Float.self),
        count: large.count))
    #expect(readBack == large)
    ring.abandonFrame()
    #expect(throws: FrameRingError.noOpenFrame) { _ = try ring.allocate(UInt32(1)) }

    // A request Metal cannot satisfy is a typed error, not a precondition trap.
    ring.beginFrame(1)
    #expect(throws: FrameRingError.invalidByteCount(-1)) { _ = try ring.allocate(byteCount: -1) }
    let refused = device.maxBufferLength + 1
    let refusedAligned = (refused + FrameRing.alignment - 1) / FrameRing.alignment * FrameRing.alignment
    #expect(throws: FrameRingError.allocationFailed(bytes: refusedAligned)) { _ = try ring.allocate(byteCount: refused) }
    ring.abandonFrame()
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func frameRingNeverReusesARegionStillInFlight() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let ring = try #require(FrameRing(device: device, regionSize: 1024, regionCount: 2))

    ring.beginFrame(0)
    let first = try ring.allocate(UInt32(11))
    let pendingFirst = try #require(queue.makeCommandBuffer())
    ring.endFrame(retainedUntilCompletionOf: pendingFirst)
    #expect(ring.isRegionInFlight(0))

    // Frame 2 prefers region 0, which an uncommitted command buffer still holds.
    ring.beginFrame(2)
    #expect(ring.frameStatistics.region == 1)
    let second = try ring.allocate(UInt32(22))
    #expect(second.offset == 1024)
    let pendingSecond = try #require(queue.makeCommandBuffer())
    ring.endFrame(retainedUntilCompletionOf: pendingSecond)

    // With every region in flight, the whole frame goes to overflow storage.
    ring.beginFrame(4)
    let overflowOnly = ring.frameStatistics.region == nil
    #expect(overflowOnly)
    let third = try ring.allocate(UInt32(33))
    let thirdInRing = ObjectIdentifier(third.buffer) == ObjectIdentifier(ring.buffer)
    #expect(!thirdInRing)
    ring.abandonFrame()
    #expect(first.buffer.contents().load(fromByteOffset: first.offset, as: UInt32.self) == 11)
    #expect(second.buffer.contents().load(fromByteOffset: second.offset, as: UInt32.self) == 22)

    pendingFirst.commit()
    pendingSecond.commit()
    pendingFirst.waitUntilCompleted()
    pendingSecond.waitUntilCompleted()
    let retired = eventually { !ring.isRegionInFlight(0) && !ring.isRegionInFlight(1) }
    #expect(retired)
    ring.beginFrame(0)
    #expect(ring.frameStatistics.region == 0)
    ring.abandonFrame()
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func frameRingRecyclesOverflowBuffersOnlyAfterCompletion() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let ring = try #require(FrameRing(device: device, regionSize: 1024, regionCount: 1))
    for frame in 0..<24 {
        ring.beginFrame(frame)
        #expect(ring.frameStatistics.region == 0)
        for lane in 0..<8 { _ = try ring.allocate(Float4(repeating: Float(frame * 8 + lane))) }
        #expect(ring.frameStatistics.overflowBuffers == 1)
        let command = try #require(queue.makeCommandBuffer())
        ring.endFrame(retainedUntilCompletionOf: command)
        #expect(ring.pooledOverflowBuffers == 0)
        command.commit()
        command.waitUntilCompleted()
        let recycled = eventually { !ring.isRegionInFlight(0) && ring.pooledOverflowBuffers == 1 }
        #expect(recycled)
    }
    // One overflow buffer serves every frame once its command buffer has completed.
    #expect(ring.overflowBuffersCreated == 1)
}

@Test func lightPackingKeepsTheFirstEightEnabledLightsAndCountsTheRest() {
    var lights: [SceneLight] = []
    for i in 0..<12 {
        var light = SceneLight(kind: .point)
        light.position = Float3(Float(i), 1, 0)
        light.enabled = i != 3 && i != 7
        lights.append(light)
    }
    let packed = Renderer.packLights(lights)
    #expect(packed.enabled == 10)
    #expect(packed.uniforms.count == UInt32(IK_MAX_LIGHTS))
    let shadedX: [Float] = withUnsafeBytes(of: packed.uniforms.lights) { raw in
        (0..<Int(IK_MAX_LIGHTS)).map {
            raw.load(fromByteOffset: $0 * MemoryLayout<LightUniform>.stride, as: LightUniform.self).position.x
        }
    }
    // List order of enabled lights, unchanged from the previous selection rule.
    #expect(shadedX == [0, 1, 2, 4, 5, 6, 8, 9])
}

@Test func activeMorphEntriesKeepEveryMeaningfulTargetInCallerOrder() {
    var weights: [(index: Int, weight: Float)] = (0..<100).map { (index: $0, weight: 0.5 + Float($0) * 0.001) }
    weights.insert((index: 5, weight: 0.00001), at: 10)
    weights.append((index: 100, weight: 1))
    weights.append((index: -1, weight: 1))
    weights.append((index: 7, weight: .nan))
    let entries = Renderer.activeMorphEntries(weights, targetCount: 100)
    #expect(entries.count == 100)
    #expect(entries.count > Int(IK_MAX_ACTIVE_MORPHS))
    let indices: [UInt32] = entries.map { $0.index }
    let expected: [UInt32] = (0..<100).map { UInt32($0) }
    #expect(indices == expected)
}

/// Runs a real capture whose uniforms cross the 8 MiB region, with twelve lights
/// and a 100-target morph, then reads back the production deformation output.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func rendererCaptureCrossesTheUniformRegionAndReportsItsLimits() throws {
    let renderer = try makeSourceShaderRenderer()
    let vertexCount = 3, targetCount = 100, morphKey: UInt64 = 0x5151
    let base: [Float3] = [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)]
    func delta(_ target: Int, _ vertex: Int) -> Float3 {
        let x = Float(target + 1) * 0.001
        let y = Float((target * 7 + vertex * 3) % 11) * 0.001 - 0.005
        let z = Float(vertex + 1) * Float(target % 5) * 0.0002
        return Float3(x, y, z)
    }
    let morphTargets: [MeshData.MorphTarget] = (0..<targetCount).map { target in
        MeshData.MorphTarget(name: "target\(target)", positionDeltas: (0..<vertexCount).map { delta(target, $0) }, normalDeltas: [])
    }
    let mesh = MeshData(name: "morph-budget", positions: base, normals: [Float3](repeating: Float3(0, 0, 1), count: vertexCount),
                        indices: [0, 1, 2], morphTargets: morphTargets)
    let handle = try renderer.resources.register(mesh: mesh)
    let weights: [(index: Int, weight: Float)] = (0..<targetCount).map { (index: $0, weight: 0.25 + Float($0 % 9) * 0.05) }
    let item = RenderItem(mesh: handle, material: MaterialState(uniforms: .make(kind: MaterialKindItem)),
                          model: matrix_identity_float4x4, objectID: 1, deformKey: morphKey, morphWeights: weights)

    var lights: [SceneLight] = []
    for i in 0..<12 {
        var light = SceneLight(kind: .point)
        light.position = Float3(Float(i) * 0.1, 1, 1)
        light.enabled = i != 3 && i != 7
        lights.append(light)
    }

    // One overlay batch of 300,000 vertices (9.6 MB, more than one 8 MiB region).
    // Every triangle is degenerate except the last, which covers the viewport in
    // red; a red pixel proves the spilled vertices were bound at the right offset.
    let width = 32, height = 32
    var frame = RenderFrame(lights: lights, items: [item])
    let viewProjection = frame.camera.projectionMatrix(aspect: Float(width) / Float(height)) * frame.camera.viewMatrix()
    let gizmoVertexCount = 300_000
    var vertices = [GizmoVertex](repeating: GizmoVertex(position: Float3(0, 0, 0), color: Float4(0, 0, 0, 0)), count: gizmoVertexCount)
    let cover: [Float3] = [Float3(-1, -1, 0.5), Float3(3, -1, 0.5), Float3(-1, 3, 0.5)]
    for (i, position) in cover.enumerated() {
        vertices[gizmoVertexCount - 3 + i] = GizmoVertex(position: position, color: Float4(1, 0, 0, 1))
    }
    frame.gizmos = [GizmoBatch(primitive: .triangles, vertices: vertices, model: viewProjection.inverse, depthTest: false)]
    #expect(gizmoVertexCount * MemoryLayout<GizmoVertex>.stride > FrameRing.defaultRegionSize)

    let image = try #require(renderer.capture(frame: frame, width: width, height: height))
    let frameError = renderer.lastFrameError
    let frameSucceeded = frameError == nil
    #expect(frameSucceeded, "\(String(describing: frameError))")
    let provider = try #require(image.dataProvider)
    let pixelData = try #require(provider.data)
    let pixels = pixelData as Data
    let center = (height / 2) * image.bytesPerRow + (width / 2) * 4
    let bgra: [UInt8] = [pixels[center], pixels[center + 1], pixels[center + 2], pixels[center + 3]]
    #expect(bgra[2] >= 250 && bgra[0] <= 5 && bgra[1] <= 5 && bgra[3] >= 250, "center BGRA \(bgra)")

    let statistics = renderer.lastFrameStatistics
    #expect(statistics.enabledLights == 10)
    #expect(statistics.shadedLights == Int(IK_MAX_LIGHTS))
    #expect(statistics.droppedLights == 2)
    #expect(statistics.deformDispatches == 1)
    #expect(statistics.largestActiveMorphSet == targetCount)
    #expect(statistics.uniforms.overflowBytes >= gizmoVertexCount * MemoryLayout<GizmoVertex>.stride)
    let usedRegion = statistics.uniforms.region != nil
    #expect(usedRegion)

    // Read the deformation buffer the capture wrote and compare with a CPU sum.
    let deformed = try #require(renderer.resources.deformBuffer(for: morphKey, vertexCount: vertexCount))
    let readback = try #require(renderer.gpu.device.makeBuffer(length: deformed.length, options: .storageModeShared))
    let command = try #require(renderer.gpu.commandQueue.makeCommandBuffer())
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(from: deformed, sourceOffset: 0, to: readback, destinationOffset: 0, size: deformed.length)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    #expect(command.status == .completed)
    let output = Array(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: DeformedVertex.self), count: vertexCount))
    func accumulate(_ count: Int) -> [Float3] {
        (0..<vertexCount).map { vertex in
            var position = base[vertex]
            for target in 0..<count { position += delta(target, vertex) * weights[target].weight }
            return position
        }
    }
    let reference = accumulate(targetCount)
    let truncated = accumulate(Int(IK_MAX_ACTIVE_MORPHS))
    for vertex in 0..<vertexCount {
        let gpu = Float3(output[vertex].position.x, output[vertex].position.y, output[vertex].position.z)
        #expect(length(gpu - reference[vertex]) < 1e-4, "vertex \(vertex): \(gpu) != \(reference[vertex])")
        #expect(length(gpu - truncated[vertex]) > 1e-2, "vertex \(vertex) still matches the 64-target truncation")
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func resourceStoreAddRemoveCyclesKeepResourceCountsBounded() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let baseline = resources.statistics()
    let positions: [Float3] = [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)]
    let morph = MeshData.MorphTarget(name: "m", positionDeltas: [Float3](repeating: Float3(0, 0, 0.1), count: 3), normalDeltas: [])
    for cycle in 0..<40 {
        let mesh = MeshData(name: "cycle-\(cycle)", positions: positions, normals: [Float3](repeating: Float3(0, 0, 1), count: 3),
                            indices: [0, 1, 2], morphTargets: [morph])
        let handle = try resources.register(mesh: mesh)
        let textureKey = "cycle-\(cycle)"
        let texture = try #require(resources.texture(r8: [UInt8](repeating: 128, count: 16), width: 4, height: 4, key: textureKey))
        let key = UInt64(cycle) << 16
        _ = try #require(resources.deformBuffer(for: key, vertexCount: 3))
        #expect(resources.setHiddenBuffer(key: key, bytes: [0, 1, 0]))
        let live = resources.statistics()
        #expect(live.meshes == baseline.meshes + 1 && live.textures == baseline.textures + 1)
        #expect(live.deformBuffers == baseline.deformBuffers + 1 && live.hiddenBuffers == baseline.hiddenBuffers + 1)

        resources.unregister(mesh: handle)
        resources.unregister(texture: texture)
        resources.releaseDeformBuffers(keys: [key])
        resources.releaseHiddenBuffers(keys: [key])
        let released = resources.statistics()
        #expect(released.meshes == baseline.meshes && released.textures == baseline.textures)
        #expect(released.deformBuffers == baseline.deformBuffers && released.hiddenBuffers == baseline.hiddenBuffers)
        #expect(released.meshBufferBytes == baseline.meshBufferBytes)
        #expect(released.deformBufferBytes == baseline.deformBufferBytes && released.hiddenBufferBytes == baseline.hiddenBufferBytes)
        let keyReleased = resources.lookup(key: textureKey) == nil
        #expect(keyReleased)
    }

    // Replacing a hidden mask allocates a new buffer instead of rewriting one a
    // submitted frame may still read.
    #expect(resources.setHiddenBuffer(key: 9, bytes: [1, 1, 1]))
    let firstMask = try #require(resources.hiddenBuffer(key: 9))
    #expect(resources.setHiddenBuffer(key: 9, bytes: [0, 0, 0]))
    let secondMask = try #require(resources.hiddenBuffer(key: 9))
    #expect(firstMask !== secondMask)
    #expect(firstMask.contents().load(as: UInt8.self) == 1)
    #expect(secondMask.contents().load(as: UInt8.self) == 0)
    #expect(resources.statistics().hiddenBuffers == baseline.hiddenBuffers + 1)
    resources.releaseHiddenBuffers(keys: [9])
    #expect(resources.statistics().hiddenBuffers == baseline.hiddenBuffers)
}
