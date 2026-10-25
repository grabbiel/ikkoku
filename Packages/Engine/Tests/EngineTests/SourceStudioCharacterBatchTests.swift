import Foundation
import CoreGraphics
import Metal
import simd
import Testing
import Assets
import CoreMath
import Scene
import Studio
@testable import Character
@testable import Renderer

// R7 phase 2 item 6: the shared rig decode, the two-half character build and
// the Studio's concurrent batch must produce what the sequential import does.

private func batchEncodedRig(_ name: String, offset: Float = 0) throws -> Data {
    let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    return try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up", "matrixLayout": "column-major",
        "uvConvention": "unity-source", "sourcePrefab": name,
        "nodes": [["name": "root", "sourceID": "root", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]]],
        "skins": [["name": "skin", "meshNode": 0, "joints": [0], "inverseBindMatrices": [identity]]],
        "meshes": [["name": "part", "node": 0, "skin": 0,
            "positions": [[offset, 0, 1], [1, 0, 1], [0, 1, 1]], "normals": [[0, 0, 1], [0, 0, 1], [0, 0, 1]],
            "tangents": [], "uv0": [], "joints": [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]],
            "weights": [[1, 0, 0, 0], [1, 0, 0, 0], [1, 0, 0, 0]],
            "submeshes": [["indices": [0, 1, 2]]], "morphChannels": []]]
    ] as [String: Any], options: .sortedKeys)
}

/// The decoded values a build reads, compared field by field (`SourceRig`
/// and `MeshData` are not `Equatable`).
private func sameRig(_ a: SourceRig, _ b: SourceRig) -> Bool {
    guard a.sourcePrefab == b.sourcePrefab, a.morphChannelCount == b.morphChannelCount,
          a.rig.nodes.map(\.name) == b.rig.nodes.map(\.name), a.rig.nodes.map(\.parent) == b.rig.nodes.map(\.parent),
          a.rig.order == b.rig.order, a.parts.count == b.parts.count else { return false }
    return zip(a.parts, b.parts).allSatisfy { p, q in
        p.node == q.node && p.skin == q.skin && p.rendererEnabled == q.rendererEnabled
            && p.mesh.name == q.mesh.name && p.mesh.positions == q.mesh.positions && p.mesh.normals == q.mesh.normals
            && p.mesh.tangents == q.mesh.tangents && p.mesh.uvs == q.mesh.uvs && p.mesh.indices == q.mesh.indices
            && p.mesh.joints == q.mesh.joints && p.mesh.weights == q.mesh.weights
            && p.mesh.morphTargets.map(\.name) == q.mesh.morphTargets.map(\.name)
            && p.mesh.morphTargets.map(\.positionDeltas) == q.mesh.morphTargets.map(\.positionDeltas)
            && p.mesh.morphTargets.map(\.normalDeltas) == q.mesh.morphTargets.map(\.normalDeltas)
    }
}

@Test func sourceRigDecodeShareDecodesEachDistinctFileOnceAndEqualsAPlainDecode() throws {
    let a = try batchEncodedRig("a"), b = try batchEncodedRig("b", offset: 0.5)
    let share = SourceRigDecodeShare()
    let first = try share.decode(a), again = try share.decode(a), other = try share.decode(b)
    #expect(share.counts == .init(decodes: 2, hits: 1))
    #expect(share.retained == 2)
    #expect(sameRig(first, try SourceRig.decode(a)) && sameRig(again, first))
    #expect(sameRig(other, try SourceRig.decode(b)) && !sameRig(other, first))
    // Equal bytes under another name are the same content; the key is the
    // SHA-256 and byte count of the bytes, never a path.
    _ = try share.decode(Data(a))
    #expect(share.counts.decodes == 2 && share.counts.hits == 2)
}

@Test func sourceRigDecodeShareRetainsNoFailureAndRetriesIt() throws {
    let share = SourceRigDecodeShare(), broken = Data("{\"schemaVersion\": 1}".utf8)
    var errors: [String] = []
    for _ in 0..<2 {
        do { _ = try share.decode(broken) } catch { errors.append(String(describing: error)) }
    }
    var plain = ""
    do { _ = try SourceRig.decode(broken) } catch { plain = String(describing: error) }
    #expect(errors == [plain, plain] && !plain.isEmpty)
    #expect(share.counts == .init(decodes: 2, failures: 2))
    #expect(share.retained == 0)
}

@Test func sourceRigDecodeShareRunsOneDecodeForConcurrentRequests() throws {
    let data = try batchEncodedRig("concurrent"), share = SourceRigDecodeShare()
    let results = OSAllocatedResults(count: 16)
    DispatchQueue.concurrentPerform(iterations: 16) { index in
        results.set(index, Result { try share.decode(data) })
    }
    let expected = try SourceRig.decode(data)
    #expect(try results.values().allSatisfy { sameRig(try $0.get(), expected) })
    let counts = share.counts
    #expect(counts.decodes == 1 && counts.hits + counts.waits == 15 && counts.failures == 0)
}

/// Results written from concurrent iterations.
private final class OSAllocatedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<SourceRig, Error>?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: Result<SourceRig, Error>) { lock.lock(); storage[index] = value; lock.unlock() }
    func values() throws -> [Result<SourceRig, Error>] {
        lock.lock(); defer { lock.unlock() }
        return try storage.map { try #require($0) }
    }
}

// MARK: - Fixture builds

private let batchVariables = ["IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT",
                              "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_ANIMATION_CATALOG", "IKKOKU_STUDIO_LOOK_SETTINGS",
                              "IKKOKU_STUDIO_HAND_PATTERNS"]

/// The scenario scene's characters in the Studio import's walk order, with
/// the references the import gives them.
private func batchFixtureReferences() throws -> [SourceStudioCharacterReference] {
    let environment = ProcessInfo.processInfo.environment
    let scene = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_SCENARIO_SCENE"))
    let data = try Data(contentsOf: scene)
    let decoded = try KoikatsuSceneReader.decodeDocument(data)
    var stack = Array(decoded.snapshot.roots.reversed()), characters: [(key: Int32, sex: Int32)] = []
    while let object = stack.popLast() {
        if let character = object.character { characters.append((object.sourceKey, character.sex)) }
        stack += object.children.reversed()
        if let character = object.character {
            for key in character.accessoryChildren.keys.sorted().reversed() { stack += (character.accessoryChildren[key] ?? []).reversed() }
        }
    }
    let catalog = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    let attachments = URL(fileURLWithPath: catalog).deletingLastPathComponent().appendingPathComponent("attachments.json")
    return try characters.map { character in
        let rig = character.sex == 0 ? (environment["IKKOKU_SOURCE_MALE_AVATAR"] ?? "") : ""
        return SourceStudioCharacterReference(sceneFile: scene.path, sceneSHA256: OriginalCardFixture.hash(data),
            rigFile: rig.isEmpty ? try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR") : rig,
            boneCatalogFile: catalog, objectKey: character.key,
            makerLibraryFile: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY"),
            attachmentCatalogFile: FileManager.default.fileExists(atPath: attachments.path) ? attachments.path : nil,
            animationCatalogFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CATALOG"),
            handPatternsFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_HAND_PATTERNS"),
            lookSettingsFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_LOOK_SETTINGS"))
    }
}

/// Raw 8-bit, four-channel bytes without row padding.
private func batchPixels(_ image: CGImage) throws -> [UInt8] {
    try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
    let data = try #require(image.dataProvider?.data) as Data
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for row in 0..<image.height {
            for column in 0..<(image.width * 4) { bytes[row * image.width * 4 + column] = raw[row * image.bytesPerRow + column] }
        }
    }
    return bytes
}

/// Every preview drawn into one frame at the origin, so the characters
/// overlap and the renderer's mesh-ID tie-breaks decide coincident draws.
private func batchScene(_ previews: [SourceStudioCharacterPreview], renderer: Renderer) throws -> (pixels: [UInt8], meshIDs: [[UInt32]]) {
    var combined: RenderFrame?, meshIDs: [[UInt32]] = []
    for (index, preview) in previews.enumerated() {
        let frame = try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(),
                                      world: matrix_identity_float4x4, objectID: UInt32(index + 1))
        meshIDs.append(frame.items.map(\.mesh.id))
        if combined == nil { combined = frame; continue }
        combined!.items += frame.items
        combined!.skinSets.merge(frame.skinSets) { _, new in new }
        combined!.sceneBounds.expand(frame.sceneBounds)
    }
    var frame = try #require(combined)
    frame.retainTextures(from: renderer.resources)
    return (try batchPixels(try #require(renderer.capture(frame: frame, width: 320, height: 320))), meshIDs)
}

/// The Studio import's path, concurrent first halves and ordered second
/// halves on a worker thread, against the sequential builds of the same
/// scene in a fresh store: the same diagnostics and selections, the same
/// mesh IDs in the same order, and a byte-identical render of every
/// character overlapping at the origin. Rig files shared across characters
/// decode once.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(batchVariables) && MTLCreateSystemDefaultDevice() != nil,
               "Requires the Studio scenario scene and its import fixtures (\(batchVariables.joined(separator: ", "))) and a Metal device"))
func sourceStudioCharacterBatchMatchesSequentialBuildsWhenSupplied() throws {
    let references = try batchFixtureReferences()
    try #require(references.count > 1)
    let sequentialRenderer = try makeSourceShaderRenderer(), batchRenderer = try makeSourceShaderRenderer()
    let sequential = try references.map { try SourceStudioCharacterPreview(reference: $0, resources: sequentialRenderer.resources) }
    let batch = SourceStudioCharacterBatch(requests: references.map { .init(reference: $0) }, resources: batchRenderer.resources)
    let built = try references.indices.map { try batch.build($0) }
    let counts = batch.rigs.counts
    print("[r7g-batch] \(references.count) characters, rig decodes \(counts.decodes), shared \(counts.hits + counts.waits)")
    #expect(counts.decodes > 0 && counts.hits + counts.waits > 0 && counts.failures == 0)
    for (a, b) in zip(sequential, built) {
        #expect(a.diagnostics == b.diagnostics)
        #expect(a.selections.count == b.selections.count && a.loadedClothesState == b.loadedClothesState)
        #expect(sameRig(a.preview.source, b.preview.source))
        #expect(!b.sharedAssembly)
    }
    let expected = try batchScene(sequential, renderer: sequentialRenderer)
    let actual = try batchScene(built, renderer: batchRenderer)
    #expect(actual.meshIDs == expected.meshIDs)
    #expect(actual.pixels == expected.pixels)
    let covered = stride(from: 0, to: expected.pixels.count, by: 4).filter { expected.pixels[$0 + 3] > 0 && expected.pixels[$0] > 8 }.count
    #expect(covered > 2_000, "the characters must cover the capture")
}

/// Cancelling a batch: queued and finished first halves are dropped, every
/// later build throws `CancellationError`, and the store holds exactly what
/// it held before once the previews built before the cancel are released.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(batchVariables) && MTLCreateSystemDefaultDevice() != nil,
               "Requires the Studio scenario scene and its import fixtures (\(batchVariables.joined(separator: ", "))) and a Metal device"))
func sourceStudioCharacterBatchCancellationLeavesNoBuildAndNoResourcesWhenSupplied() throws {
    // Three characters cover a cancel before, between and after builds.
    let references = Array(try batchFixtureReferences().prefix(3))
    try #require(references.count > 2)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    // Warm the shared texture cache first: the import keeps base textures
    // cached across scenes, so only per-preview resources are compared.
    let warm = try references.map { try SourceStudioCharacterPreview(reference: $0, resources: resources) }
    #expect(warm.count == references.count)
    do {
        var checks: [(String, Bool)] = []
        let before = resources.statistics()
        for cancelAfter in [0, 1] {
            let batch = SourceStudioCharacterBatch(requests: references.map { .init(reference: $0) }, resources: resources, width: 2)
            var built: [SourceStudioCharacterPreview] = []
            for index in 0..<cancelAfter { built.append(try batch.build(index)) }
            batch.cancel()
            var cancelled = 0
            for index in cancelAfter..<references.count {
                do { _ = try batch.build(index) } catch is CancellationError { cancelled += 1 }
            }
            checks.append(("every build after cancel(\(cancelAfter)) throws CancellationError", cancelled == references.count - cancelAfter))
            checks.append(("the batch reports the cancel (\(cancelAfter))", batch.isCancelled))
            built.removeAll()
            // In-flight first halves finish on their own; nothing they hold is a store resource.
            let deadline = Date().addingTimeInterval(60)
            while batch.runningCount > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            checks.append(("no first half runs after cancel(\(cancelAfter))", batch.runningCount == 0))
            let after = resources.statistics()
            checks.append(("cancel(\(cancelAfter)) leaves the store as before", before.meshes == after.meshes && before.textures == after.textures
                && before.deformBuffers == after.deformBuffers && before.meshBufferBytes == after.meshBufferBytes
                && before.hiddenBuffers == after.hiddenBuffers && before.retiring == after.retiring))
        }
        // A batch after a cancelled one builds normally.
        let again = SourceStudioCharacterBatch(requests: [.init(reference: references[0])], resources: resources)
        let preview = try again.build(0)
        checks.append(("a later batch builds", preview.diagnostics == warm[0].diagnostics))
        for (name, passed) in checks { #expect(passed, "\(name)") }
    }
}

/// A copy of a loaded character (Duplicate, or the undo of a delete) takes
/// its original's converted assembly through `Donation` and renders
/// byte-identical to a fresh build. Only the same record, outfit and store
/// share; editing the copy leaves the original's render.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(batchVariables) && MTLCreateSystemDefaultDevice() != nil,
               "Requires the Studio scenario scene and its import fixtures (\(batchVariables.joined(separator: ", "))) and a Metal device"))
func sourceStudioCharacterDonationRendersLikeAFreshBuildWhenSupplied() throws {
    let reference = try #require(try batchFixtureReferences().first)
    let renderer = try makeSourceShaderRenderer(), resources = renderer.resources
    let original = try SourceStudioCharacterPreview(reference: reference, resources: resources)
    let copy = try SourceStudioCharacterPreview(reference: reference, resources: resources, sharing: original)
    let fresh = try SourceStudioCharacterPreview(reference: reference, resources: resources)
    let otherStore = try SourceStudioCharacterPreview(reference: reference, resources: ResourceStore(device: resources.device), sharing: original)
    #expect(!original.sharedAssembly && copy.sharedAssembly && !fresh.sharedAssembly && !otherStore.sharedAssembly)
    #expect(copy.diagnostics == fresh.diagnostics && copy.loadedClothesState == fresh.loadedClothesState)
    #expect(sameRig(copy.preview.source, fresh.preview.source))
    if original.outfitCount > 1 {
        let outfit = (original.coordinate + 1) % original.outfitCount
        let other = try SourceStudioCharacterPreview(reference: reference, resources: resources, coordinate: outfit, sharing: original)
        #expect(!other.sharedAssembly && other.coordinate == outfit)
    }
    func render(_ preview: SourceStudioCharacterPreview, fk: [Int: Float3] = [:]) throws -> [UInt8] {
        let frame = try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(),
                                      world: matrix_identity_float4x4, objectID: 1, fkRotations: fk)
        return try batchPixels(try #require(renderer.capture(frame: frame, width: 256, height: 256)))
    }
    let base = try render(original)
    #expect(try render(copy) == base)
    #expect(try render(fresh) == base)
    let bone = try #require(original.controller.targets.first { $0.hasGuide && $0.bone.fkGroup == .body }?.bone.id)
    let bent = try render(copy, fk: [bone: Float3(35, -20, 10)])
    #expect(bent != base, "the edit must change the copy's render")
    #expect(try render(fresh, fk: [bone: Float3(35, -20, 10)]) == bent)
    #expect(try render(original) == base)
}
