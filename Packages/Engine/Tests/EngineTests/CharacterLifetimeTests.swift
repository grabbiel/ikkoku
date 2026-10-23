import Testing
import Foundation
import Metal
import simd
import Assets
import CoreMath
import Scene
import ShaderTypes
import Character
@testable import Renderer

// R6 second slice: characters and repeated static imports hand their GPU
// resources back, and frames submitted before a removal keep drawing them.
// Uses only the bundled prototype assets in `Assets/`.

private let bundledAssets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets")

/// A copy of the bundled female body and the bundled garments that embed no
/// image, with the bundled catalog and without `Textures/`. Building these
/// characters therefore never calls `MTKTextureLoader`: on CI, two tests making
/// synchronous texture loads at once stalled the whole parallel Engine suite.
private struct UntexturedCharacterAssets {
    static var garments: [(slot: ClothSlot, id: String)] {
        [(.bottom, "bottom_skirt_pleated"), (.socks, "socks_knee"), (.shoesIn, "shoes_in_loafers"),
         (.bra, "bra_plain"), (.underwear, "underwear_plain")]
    }
    let root: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("ikkoku-r6-lifetime-\(UUID().uuidString)", isDirectory: true)
        let catalogData = try Data(contentsOf: bundledAssets.appendingPathComponent("catalog.json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: catalogData)
        var files = [try #require(catalog.body("body_f")).file]
        for garment in Self.garments { files.append(try #require(catalog.cloth(garment.id)).file) }
        for file in files {
            let destination = root.appendingPathComponent(file)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: bundledAssets.appendingPathComponent(file), to: destination)
        }
        try catalogData.write(to: root.appendingPathComponent("catalog.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// The bundled female card without hair or accessories, wearing the first
    /// `garmentCount` image-free garments.
    static func card(garmentCount: Int) -> CharacterCard {
        var card = CharacterCard.defaultFemale()
        card.hair.parts = [:]
        card.accessories = card.accessories.map { _ in AccessoryDefinition() }
        card.currentOutfit = 0
        card.outfits[0].items = [:]
        for garment in garments.prefix(garmentCount) { card.outfits[0].items[garment.slot] = ClothItem(itemID: garment.id) }
        return card
    }
}

/// One character's frame, built the way `MakerModel.refresh` builds it.
private func characterFrame(_ character: CharacterInstance) -> RenderFrame {
    let built = character.build(objectID: 1)
    var frame = RenderFrame(items: built.items, sceneBounds: built.bounds)
    frame.skinSets = [character.instanceID: built.skinSet]
    return frame
}

/// A small offscreen capture of `frame`; it must encode without deformation errors.
private func render(_ renderer: Renderer, _ frame: RenderFrame, _ context: String) {
    let image = renderer.capture(frame: frame, width: 32, height: 32)
    let rendered = image != nil
    #expect(rendered, "\(context): \(String(describing: renderer.lastFrameError)) \(renderer.lastDeformationErrors)")
}

private func sameResources(_ a: ResourceStore.Statistics, _ b: ResourceStore.Statistics) -> Bool {
    a.meshes == b.meshes && a.textures == b.textures && a.deformBuffers == b.deformBuffers && a.hiddenBuffers == b.hiddenBuffers
        && a.meshBufferBytes == b.meshBufferBytes && a.deformBufferBytes == b.deformBufferBytes
        && a.hiddenBufferBytes == b.hiddenBufferBytes && a.retiring == b.retiring
}

private func itemFrame(_ asset: LoadedAsset) -> RenderFrame {
    RenderFrame(items: asset.parts.map {
        RenderItem(mesh: $0.mesh, material: MaterialState(uniforms: .make(kind: MaterialKindItem)), model: $0.worldMatrix, objectID: 1)
    })
}

/// GPU lifetime tests, one at a time: each compiles the production shaders and
/// captures many frames.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct CharacterLifetimeTests {
    @Test func characterCreateRemoveCyclesReturnTheResourceStoreToBaseline() throws {
        let assets = try UntexturedCharacterAssets()
        defer { assets.remove() }
        let renderer = try makeSourceShaderRenderer()
        let resources = renderer.resources
        let library = AssetLibrary(resources: resources, root: assets.root)
        let cards: [CharacterCard] = [UntexturedCharacterAssets.card(garmentCount: 5), UntexturedCharacterAssets.card(garmentCount: 2)]

        // Meshes stay in the shared library cache by design; draw the full card
        // once so the baseline already holds every mesh both cards use.
        let warm = CharacterInstance(instanceID: 10, library: library, card: cards[0])
        renderer.submit(characterFrame(warm))
        render(renderer, renderer.currentFrame(), "warm-up")
        warm.releaseGPUResources()
        renderer.submit(RenderFrame())
        render(renderer, renderer.currentFrame(), "warm-up release")
        let baseline = resources.statistics()
        #expect(baseline.meshes > 0 && baseline.textures == 0, "\(baseline)")
        #expect(baseline.deformBuffers == 0 && baseline.hiddenBuffers == 0 && baseline.retiring == 0, "\(baseline)")

        for cycle in 0..<4 {
            var character: CharacterInstance? = CharacterInstance(instanceID: 100 + UInt64(cycle), library: library,
                                                                  card: cards[cycle % 2])
            renderer.submit(characterFrame(try #require(character)))
            let submitted = renderer.currentFrame()
            render(renderer, submitted, "cycle \(cycle) live")
            let live = resources.statistics()
            #expect(live.meshes == baseline.meshes && live.textures == baseline.textures, "cycle \(cycle): \(live)")
            #expect(live.deformBuffers > 0 && live.hiddenBuffers == 1, "cycle \(cycle): \(live)")

            // Removal: the owner's explicit release (Studio delete, scene replacement)
            // on even cycles, the deinit safety net on odd ones.
            if cycle.isMultiple(of: 2) { character?.releaseGPUResources() } else { character = nil }
            let retired = resources.statistics()
            #expect(retired.retiring > 0, "cycle \(cycle): \(retired)")
            #expect(retired.deformBuffers == live.deformBuffers && retired.hiddenBuffers == live.hiddenBuffers)

            // The frame submitted before the removal still draws with its buffers;
            // preparing it neither completes the retirement nor allocates more.
            render(renderer, renderer.currentFrame(), "cycle \(cycle) pending")
            let pending = resources.statistics()
            #expect(sameResources(pending, retired), "cycle \(cycle): \(pending) != \(retired)")

            // The next submitted frame is built without the character and completes it.
            renderer.submit(RenderFrame())
            render(renderer, renderer.currentFrame(), "cycle \(cycle) after removal")
            let released = resources.statistics()
            #expect(sameResources(released, baseline), "cycle \(cycle): \(released) != baseline \(baseline)")

            // A copy of the old submitted frame prepared later still renders, with
            // transient deformation buffers: the released keys are not re-created.
            render(renderer, submitted, "cycle \(cycle) late copy")
            let late = resources.statistics()
            #expect(sameResources(late, baseline), "cycle \(cycle): \(late) != baseline \(baseline)")
            _ = character
        }
    }

    @Test func characterDrawnAgainAfterAReleaseOwnsItsBuffersAgain() throws {
        let assets = try UntexturedCharacterAssets()
        defer { assets.remove() }
        let renderer = try makeSourceShaderRenderer()
        let resources = renderer.resources
        let library = AssetLibrary(resources: resources, root: assets.root)
        let character = CharacterInstance(instanceID: 1, library: library, card: UntexturedCharacterAssets.card(garmentCount: 5))
        renderer.submit(characterFrame(character))
        render(renderer, renderer.currentFrame(), "first")
        let live = resources.statistics()
        #expect(live.deformBuffers > 0 && live.hiddenBuffers == 1, "\(live)")

        // The Maker releases its bundled character while an original rig preview is
        // shown and keeps the instance, which is drawn again when the preview closes.
        character.releaseGPUResources()
        renderer.submit(characterFrame(character))
        render(renderer, renderer.currentFrame(), "drawn again")
        let again = resources.statistics()
        #expect(again.retiring == 0, "\(again)")
        #expect(again.deformBuffers == live.deformBuffers && again.deformBufferBytes == live.deformBufferBytes, "\(again) vs \(live)")
        // The re-uploaded coverage mask cancelled its retirement, so later frames keep it.
        #expect(again.hiddenBuffers == 1 && again.hiddenBufferBytes == live.hiddenBufferBytes, "\(again) vs \(live)")
        renderer.submit(characterFrame(character))
        render(renderer, renderer.currentFrame(), "kept")
        let kept = resources.statistics()
        #expect(sameResources(kept, again), "\(kept) != \(again)")

        character.releaseGPUResources()
        renderer.submit(RenderFrame())
        render(renderer, renderer.currentFrame(), "released")
        let released = resources.statistics()
        #expect(released.deformBuffers == 0 && released.hiddenBuffers == 0 && released.retiring == 0, "\(released)")
    }

    @Test func repeatedStaticImportsKeepOneCopyOfTheItemMeshes() throws {
        let renderer = try makeSourceShaderRenderer()
        let resources = renderer.resources
        let library = AssetLibrary(resources: resources, root: bundledAssets)
        let url = bundledAssets.appendingPathComponent("Items/item_chair.glb")
        let baseline = resources.statistics()
        var current = try library.importTrustedStaticAsset(url: url)
        let imported = resources.statistics()
        #expect(imported.meshes == baseline.meshes + current.parts.count, "\(imported)")

        for cycle in 0..<8 {
            // The Studio draws the imported item, then the same file is imported again.
            renderer.submit(itemFrame(current))
            let replacement = try library.importTrustedStaticAsset(url: url)
            let replacedHandles = current.parts.map(\.mesh)
            #expect(resources.statistics().retiring == replacedHandles.count)
            // The pending frame still draws the replaced copy.
            render(renderer, renderer.currentFrame(), "cycle \(cycle) pending")
            let replacedStillRegistered = replacedHandles.allSatisfy { resources.mesh($0) != nil }
            #expect(replacedStillRegistered)

            renderer.submit(itemFrame(replacement))
            render(renderer, renderer.currentFrame(), "cycle \(cycle) replacement")
            let replacedReleased = replacedHandles.allSatisfy { resources.mesh($0) == nil }
            #expect(replacedReleased)
            let statistics = resources.statistics()
            #expect(statistics.meshes == imported.meshes && statistics.meshBufferBytes == imported.meshBufferBytes
                    && statistics.textures == imported.textures && statistics.retiring == 0, "cycle \(cycle): \(statistics)")
            current = replacement
        }
    }

    @Test func onlyASubmittedFrameCreatedAfterARetirementCompletesIt() throws {
        let renderer = try makeSourceShaderRenderer()
        let resources = renderer.resources
        let positions: [Float3] = [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)]
        let normals = [Float3](repeating: Float3(0, 0, 1), count: 3)
        let morph = MeshData.MorphTarget(name: "m", positionDeltas: [Float3](repeating: Float3(0, 0, 0.1), count: 3), normalDeltas: [])
        let mesh = try resources.register(mesh: MeshData(name: "retire", positions: positions, normals: normals,
                                                         indices: [0, 1, 2], morphTargets: [morph]))
        let deformKey: UInt64 = 0x7100, hiddenKey: UInt64 = 0x7177
        var item = RenderItem(mesh: mesh, material: MaterialState(uniforms: .make(kind: MaterialKindItem)),
                              model: matrix_identity_float4x4, objectID: 1, deformKey: deformKey, morphWeights: [(index: 0, weight: 1)])
        item.hiddenKey = hiddenKey
        #expect(resources.setHiddenBuffer(key: hiddenKey, bytes: [0, 0, 0]))
        renderer.submit(RenderFrame(items: [item]))
        render(renderer, renderer.currentFrame(), "live")
        let live = resources.statistics()
        #expect(live.meshes == 1 && live.deformBuffers == 1 && live.hiddenBuffers == 1, "\(live)")

        resources.retire(meshes: [mesh], deformKeys: [deformKey], hiddenKeys: [hiddenKey])
        #expect(resources.statistics().retiring == 3)
        // A frame created afterward but captured directly, never submitted, leaves
        // the pending frame in place, so it completes nothing.
        render(renderer, RenderFrame(), "direct")
        #expect(resources.statistics().retiring == 3)
        // The pending frame, created before the retirement, still draws everything.
        render(renderer, renderer.currentFrame(), "pending")
        let pending = resources.statistics()
        #expect(pending.retiring == 3 && pending.meshes == 1 && pending.deformBuffers == 1 && pending.hiddenBuffers == 1, "\(pending)")
        #expect(renderer.lastFrameStatistics.deformDispatches == 1)

        renderer.submit(RenderFrame())
        render(renderer, renderer.currentFrame(), "completed")
        let completed = resources.statistics()
        #expect(completed.retiring == 0 && completed.meshes == 0 && completed.deformBuffers == 0 && completed.hiddenBuffers == 0,
                "\(completed)")
    }
}

@Test func renderStatusReporterShowsAProblemOnceAndRestoresTheStatusAfterRecovery() {
    let healthy = RenderFrameStatistics()
    var dropped = RenderFrameStatistics()
    dropped.enabledLights = 10
    dropped.shadedLights = Int(IK_MAX_LIGHTS)
    let failure = RenderFrameError.commandBufferUnavailable
    let skipped = "Renderer skipped a frame: Metal did not provide a command buffer."
    let unshaded = "2 enabled lights are not shaded: frames shade at most \(IK_MAX_LIGHTS) lights."
    #expect(RenderStatusReporter.message(error: nil, statistics: dropped) == unshaded)
    #expect(RenderStatusReporter.message(error: failure, statistics: dropped) == skipped)
    #expect(RenderStatusReporter.message(error: nil, statistics: healthy) == nil)
    #expect(RenderStatusReporter.clearDelay == 1)

    // One editor-timer poll per step. `overwrite` is a status other code writes
    // first; `written` is what the reporter returns; `line` is the status after.
    // Times are exact binary fractions so the one-second comparisons are exact.
    typealias Step = (overwrite: String?, error: RenderFrameError?, statistics: RenderFrameStatistics, time: Double,
                      written: String?, line: String)
    let steps: [Step] = [
        (nil, nil, healthy, 0, nil, "Ready"),
        (nil, failure, healthy, 0.25, skipped, skipped),
        // Polling the same problem never rewrites the line.
        (nil, failure, healthy, 0.5, nil, skipped),
        // A frame that succeeds in between does not clear it at once (no flicker).
        (nil, nil, healthy, 0.75, nil, skipped),
        (nil, failure, healthy, 1, nil, skipped),
        (nil, nil, healthy, 1.25, nil, skipped),
        (nil, nil, healthy, 2, nil, skipped),
        // After a second of healthy frames the replaced status returns.
        (nil, nil, healthy, 2.25, "Ready", "Ready"),
        (nil, nil, healthy, 3, nil, "Ready"),
        (nil, nil, dropped, 4, unshaded, unshaded),
        // A status other code wrote meanwhile is kept; the same problem is not written over it.
        ("Saved scene", nil, dropped, 4.25, nil, "Saved scene"),
        // A different problem is shown, and recovery restores the status it replaced.
        (nil, failure, dropped, 4.5, skipped, skipped),
        (nil, nil, healthy, 5, nil, skipped),
        (nil, nil, healthy, 6, "Saved scene", "Saved scene"),
    ]
    var reporter = RenderStatusReporter()
    var status = "Ready"
    for (index, step) in steps.enumerated() {
        if let overwrite = step.overwrite { status = overwrite }
        let written = reporter.status(current: status, error: step.error, statistics: step.statistics, now: step.time)
        if let written { status = written }
        #expect(written == step.written, "step \(index) at \(step.time)s")
        #expect(status == step.line, "step \(index) at \(step.time)s")
    }
}
