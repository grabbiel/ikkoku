import Foundation
import Testing
import Metal
import simd
import CoreMath
import ShaderTypes
import Character
@testable import Renderer

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceAppearanceBudgetCountsRepeatedOutputsBeforeInputReadsOrAllocations() throws {
    let directory = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let appearance = try AppearanceTestFixture.preview(directory: directory, resources: resources)
    let card = try SourceCardAppearance(card: AppearanceTestFixture.card())
    var entry = AppearanceTestFixture.entry(kind: "head", colors: ["body.skinMainColor", "body.skinSubColor"])
    // One repeatedly referenced 16 MiB input would defeat an input-cache-only limit.
    // No input file exists: the output budget must fail during metadata preflight.
    entry["main"] = ["file": "missing.rgba", "sha256": String(repeating: "0", count: 64), "width": 2048, "height": 2048]
    let bindings = try AppearanceTestFixture.bindings(Array(repeating: entry, count: 9), directory: directory)
    do {
        _ = try appearance.applying(card, bindings: bindings, directory: directory, resources: resources)
        Issue.record("Oversized repeated appearance outputs were accepted.")
    } catch {
        #expect(String(describing: error).contains("outputs exceed 128 MiB"))
    }
    // One legal output reaches its input read. This distinguishes a global cap
    // from an accidental rejection of all texture recipes or the dimensions.
    let small = try AppearanceTestFixture.bindings([entry], directory: directory)
    do {
        _ = try appearance.applying(card, bindings: small, directory: directory, resources: resources)
        Issue.record("Missing input should still be rejected.")
    } catch {
        #expect(!String(describing: error).contains("outputs exceed 128 MiB"))
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceAppearanceFrameKeepsEveryTextureSlotAfterOwnerUnregistersAndPrunesCopiesIndependently() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    var handles: [TextureHandle] = []
    for index in 0..<11 {
        let texture = try #require(resources.device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [UInt8(index * 21), 87, 193, 255]
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        handles.append(resources.register(texture: texture))
    }
    var material = MaterialState(uniforms: .make(kind: MaterialKindUnlit))
    material.base = handles[0]; material.colorMask = handles[1]; material.detail = handles[2]
    material.line = handles[3]; material.normal = handles[4]; material.overlay0 = handles[5]
    material.overlay1 = handles[6]; material.overlay2 = handles[7]; material.pattern = handles[8]
    material.hairGloss = handles[9]; material.bodyMask = handles[10]
    var frame = RenderFrame(items: [RenderItem(mesh: MeshHandle(id: 1), material: material, model: matrix_identity_float4x4, objectID: 1)])
    frame.retainTextures(from: resources)
    var queued = frame
    for handle in handles { resources.unregister(texture: handle); #expect(resources.texture(handle) == nil) }
    // Re-prepare after the appearance owner disappeared. Retained references must
    // survive rather than being overwritten by failed ResourceStore lookups.
    queued.retainTextures(from: resources)
    frame.items = []; frame.retainTextures(from: resources)
    for (index, handle) in handles.enumerated() {
        #expect(frame.texture(handle, resources: resources) == nil)
        let texture = try #require(queued.texture(handle, resources: resources))
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        #expect(bytes == [UInt8(index * 21), 87, 193, 255])
    }
    queued.items = []; queued.retainTextures(from: resources)
    #expect(handles.allSatisfy { queued.texture($0, resources: resources) == nil })
}
