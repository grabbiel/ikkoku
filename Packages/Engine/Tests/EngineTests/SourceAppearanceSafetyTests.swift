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

@Test func sourcePreparedAppearanceInputsValidateBoundsHashesAndContainmentBeforeRealization() throws {
    let directory = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let card = try SourceCardAppearance(card: AppearanceTestFixture.card())
    let valid = try AppearanceTestFixture.texture([128,64,255,255], directory: directory)
    var entry = AppearanceTestFixture.entry(kind: "head", colors: ["body.skinMainColor", "body.skinSubColor"])
    entry["main"] = valid; entry["mask"] = valid
    let bindings = try AppearanceTestFixture.bindings([entry], directory: directory)
    let prepared = try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, maximumBytes: 4)
    #expect(prepared.byteCount == 4) // the repeated path shares one retained array
    #expect(throws: (any Error).self) { try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, maximumBytes: 3) }
    #expect(throws: (any Error).self) { try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, maximumBytes: -1) }
    for replacement in [
        ["sha256": String(repeating: "0", count: 64)] as [String: Any],
        ["width": 2], ["width": 0], ["height": 4097], ["file": "../escape.rgba"], ["file": "/absolute.rgba"]
    ] {
        var bad = entry; bad["mask"] = valid.merging(replacement) { _, value in value }
        let invalid = try AppearanceTestFixture.bindings([bad], directory: directory)
        #expect(throws: (any Error).self) { try SourceAppearanceInputs.prepare(card: card, bindings: invalid, directory: directory) }
    }
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data([128,64,255,255]).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.rgba"), withDestinationURL: outside)
    var escaped = entry; escaped["main"] = valid.merging(["file": "escape.rgba"]) { _, value in value }
    #expect(throws: (any Error).self) {
        try SourceAppearanceInputs.prepare(card: card, bindings: AppearanceTestFixture.bindings([escaped], directory: directory), directory: directory)
    }
    var oversized = entry
    oversized["main"] = ["file": "missing.rgba", "sha256": String(repeating: "0", count: 64), "width": 2048, "height": 2048]
    do {
        _ = try SourceAppearanceInputs.prepare(card: card, bindings: AppearanceTestFixture.bindings(Array(repeating: oversized, count: 9), directory: directory), directory: directory)
        Issue.record("Repeated output budget was not checked before input reads.")
    } catch { #expect(String(describing: error).contains("outputs exceed 128 MiB")) }
}

@Test func sourcePreparedAppearanceInputsReadOnlySelectedUnmoddedPatterns() throws {
    let directory = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    typealias F = OriginalCardFixture
    let card = try SourceCardAppearance(card: AppearanceTestFixture.card(bodyOverrides: [
        ("skinId", .integer(1)), ("patternTiling", .array([F.Value.float(0.5), .float(0.5)]))]))
    var texture = try AppearanceTestFixture.texture([20,40,60,255], directory: directory); texture["wrap"] = "repeat"
    let absent: [String: Any] = ["file": "unselected.rgba", "sha256": "not-a-hash", "width": 1, "height": 1, "wrap": "repeat"]
    let pattern: [String: Any] = ["selection": "body.skinId", "color": "body.skinMainColor", "tiling": "body.patternTiling",
        "resolverProperties": [], "textures": ["1": texture, "2": absent]]
    var entry = AppearanceTestFixture.entry(kind: "clothes", colors: Array(repeating: "body.skinMainColor", count: 3))
    entry["main"] = texture; entry["patterns"] = Array(repeating: pattern, count: 3)
    let bindings = try AppearanceTestFixture.bindings([entry], directory: directory)
    #expect(try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory).byteCount == 4)
    entry["requirements"] = ["body.skinId": 2]; entry["main"] = absent
    #expect(try SourceAppearanceInputs.prepare(card: card, bindings: AppearanceTestFixture.bindings([entry], directory: directory), directory: directory).byteCount == 0)
    entry["requirements"] = [:]; entry["resolverProperties"] = ["ChaFileBody.skinId"]
    let modded = try SourceCardAppearance(card: AppearanceTestFixture.card(modProperty: "ChaFileBody.skinId"))
    #expect(try SourceAppearanceInputs.prepare(card: modded, bindings: AppearanceTestFixture.bindings([entry], directory: directory), directory: directory).byteCount == 0)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourcePreparedAppearanceSnapshotKeepsLatestColorsWithoutOwnerReadsAndRejectsMismatches() throws {
    let directory = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let preview = try AppearanceTestFixture.preview(directory: directory, resources: resources)
    let recipe = try AppearanceTestFixture.recipe(directory: directory)
    let bindings = try AppearanceTestFixture.bindings([recipe], directory: directory)
    var card = try SourceCardAppearance(card: AppearanceTestFixture.card())
    let inputs = try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory)
    try card.setColor("body.skinMainColor", rgba: Float4(0.8,0.2,0.4,1))
    func bytes(_ application: SourcePreviewAppearance.CardApplication) throws -> [UInt8] {
        let handle = try #require(application.appearance.materials["part"]?.first?.base)
        let texture = try #require(resources.texture(handle))
        var value = [UInt8](repeating: 0, count: 4)
        value.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0) }
        return value
    }
    let expected = try bytes(preview.applying(card, bindings: bindings, directory: directory, resources: resources, backend: .cpu))
    for key in ["main", "mask"] {
        let metadata = try #require(recipe[key] as? [String: Any])
        try FileManager.default.removeItem(at: directory.appendingPathComponent(try #require(metadata["file"] as? String)))
    }
    let before = resources.statistics().textures
    for backend: SourceAppearanceCompositionBackend in [.cpu, .metal] {
        let result = try preview.applying(card, bindings: bindings, directory: directory, resources: resources, backend: backend, preparedInputs: inputs)
        #expect(zip(try bytes(result), expected).allSatisfy { abs(Int($0)-Int($1)) <= 1 })
        #expect(result.appliedFields == ["body.skinMainColor", "body.skinSubColor"])
    }
    #expect(resources.statistics().textures == before) // prepared bytes never own GPU handles
    #expect(throws: (any Error).self) { try preview.applying(card, bindings: bindings, directory: directory, resources: resources) }
    let elsewhere = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    #expect(throws: (any Error).self) { try preview.applying(card, bindings: bindings, directory: elsewhere, resources: resources, preparedInputs: inputs) }
    var changed = recipe; changed["requirements"] = ["body.skinId": 0]
    let different = try AppearanceTestFixture.bindings([changed], directory: directory)
    #expect(throws: (any Error).self) { try preview.applying(card, bindings: different, directory: directory, resources: resources, preparedInputs: inputs) }
    // Same binding, newly active selection: no prepared pixels exist and no disk
    // fallback is allowed. This also rejects before allocating an output texture.
    var gated = recipe; gated["requirements"] = ["body.skinId": 1]
    let gatedBindings = try AppearanceTestFixture.bindings([gated], directory: directory)
    let empty = try SourceAppearanceInputs.prepare(card: card, bindings: gatedBindings, directory: directory)
    let newlySelected = try SourceCardAppearance(card: AppearanceTestFixture.card(bodyOverrides: [("skinId", .integer(1))]))
    #expect(throws: (any Error).self) { try preview.applying(newlySelected, bindings: gatedBindings, directory: directory, resources: resources, preparedInputs: empty) }
    #expect(resources.statistics().textures == before)
}

@Test func sourcePreparedAppearanceDiagnosticsCountReadsRechecksAndCopiesSeparately() throws {
    let directory = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let card = try SourceCardAppearance(card: AppearanceTestFixture.card())
    let texture = try AppearanceTestFixture.texture([128,64,255,255], directory: directory)
    var entry = AppearanceTestFixture.entry(kind: "head", colors: ["body.skinMainColor", "body.skinSubColor"])
    entry["main"] = texture; entry["mask"] = texture
    let bindings = try AppearanceTestFixture.bindings([entry], directory: directory)
    let timings = SourceMakerPreparationTimings()
    let plain = try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory)
    let measured = try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, timings: timings)
    #expect(measured.byteCount == plain.byteCount && measured.byteCount == 4)
    let sample = timings.sample
    #expect(sample.intervals["rgbaRead"]?.calls == 1 && sample.bytesRead["rgbaRead"] == 4)
    #expect(sample.intervals["rgbaSHA"]?.calls == 2 && sample.bytesHashed["rgbaSHA"] == 8)
    #expect(sample.intervals["rgbaCopy"]?.calls == 1 && sample.rgbaBytesCopied == 4)
    #expect(sample.rgbaCacheReuses == 1 && sample.hashMismatches == 0)
    #expect(sample.intervals.values.allSatisfy { $0.failures == 0 })
    // A later operation can update only the local collector, not the returned snapshot.
    _ = try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, timings: timings)
    #expect(sample.bytesRead["rgbaRead"] == 4 && timings.sample.bytesRead["rgbaRead"] == 8)
}

@Test func sourcePreparedAppearanceDiagnosticsKeepSizeBeforeHashAndFailureBoundaries() throws {
    let directory = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let card = try SourceCardAppearance(card: AppearanceTestFixture.card())
    let texture = try AppearanceTestFixture.texture([128,64,255,255], directory: directory)
    var entry = AppearanceTestFixture.entry(kind: "head", colors: ["body.skinMainColor", "body.skinSubColor"])
    entry["main"] = texture
    for (replacement, shaCalls, mismatch) in [
        (["width": 2] as [String: Any], 1, 0),
        (["sha256": String(repeating: "0", count: 64)] as [String: Any], 2, 1)
    ] {
        entry["mask"] = texture.merging(replacement) { _, value in value }
        let bindings = try AppearanceTestFixture.bindings([entry], directory: directory)
        let timings = SourceMakerPreparationTimings()
        do {
            _ = try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, timings: timings)
            Issue.record("Conflicting cached metadata was accepted")
        } catch { #expect(String(describing: error).contains("Conflicting appearance texture metadata")) }
        #expect(timings.sample.intervals["rgbaRead"]?.calls == 1)
        #expect(timings.sample.intervals["rgbaSHA"]?.calls == shaCalls)
        #expect(timings.sample.hashMismatches == mismatch && timings.sample.rgbaCacheReuses == 0)
        #expect(timings.sample.rgbaBytesCopied == 4) // first input only
    }
    entry.removeValue(forKey: "mask")
    let bindings = try AppearanceTestFixture.bindings([entry], directory: directory)
    let file = directory.appendingPathComponent(try #require(texture["file"] as? String))
    try Data([128,64,255]).write(to: file)
    let short = SourceMakerPreparationTimings()
    #expect(throws: (any Error).self) { try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, timings: short) }
    #expect(short.sample.bytesRead["rgbaRead"] == 3 && short.sample.intervals["rgbaRead"]?.failures == 0)
    #expect(short.sample.intervals["rgbaSHA"] == nil && short.sample.rgbaBytesCopied == 0)
    try FileManager.default.removeItem(at: file)
    let missing = SourceMakerPreparationTimings()
    #expect(throws: (any Error).self) { try SourceAppearanceInputs.prepare(card: card, bindings: bindings, directory: directory, timings: missing) }
    #expect(missing.sample.intervals["rgbaRead"]?.calls == 1 && missing.sample.intervals["rgbaRead"]?.failures == 1)
    #expect(missing.sample.bytesRead["rgbaRead"] == nil && missing.sample.intervals["rgbaSHA"] == nil)
}
