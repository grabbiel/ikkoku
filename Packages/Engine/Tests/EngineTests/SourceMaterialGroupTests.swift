import Foundation
import Testing
import Metal
import CoreMath
import Renderer
import Scene
@testable import Character

@Test func sourceMaterialClothesCapacitySplitsWithoutRejectingSingletons() {
    let cap = SourceMaterialGroupCapacity(inputBytes: 20, outputBytes: 12)
    #expect(cap.action(pending: .zero, next: .init(inputBytes: 20, outputBytes: 12)) == .append)
    #expect(cap.action(pending: .init(inputBytes: 16, outputBytes: 4), next: .init(inputBytes: 8, outputBytes: 4)) == .flushThenAppend)
    #expect(cap.action(pending: .init(inputBytes: 4, outputBytes: 12), next: .init(inputBytes: 4, outputBytes: 4)) == .flushThenAppend)
    #expect(cap.action(pending: .zero, next: .init(inputBytes: 21, outputBytes: 4)) == .standalone)
    #expect(cap.action(pending: .zero, next: .init(inputBytes: 4, outputBytes: 13)) == .standalone)
    #expect(cap.action(pending: .zero, next: nil) == .standalone)
    #expect(cap.action(pending: .zero, next: .init(inputBytes: -1, outputBytes: 4)) == .standalone)
    let wide = SourceMaterialGroupCapacity(inputBytes: Int.max, outputBytes: Int.max)
    #expect(wide.action(pending: .init(inputBytes: Int.max, outputBytes: 0), next: .init(inputBytes: 1, outputBytes: 0)) == .flushThenAppend)
    #expect(wide.action(pending: .init(inputBytes: 0, outputBytes: Int.max), next: .init(inputBytes: 0, outputBytes: 1)) == .flushThenAppend)
    #expect(SourceMaterialGroupCapacity.clothes.inputBytes == 32 * 1024 * 1024)
    #expect(SourceMaterialGroupCapacity.clothes.outputBytes == 32 * 1024 * 1024)
}

@Test func sourceMaterialClothesChargeCountsRepeatedUploadsAndPerCallFallbacks() {
    let image = SourceMaterialImage(width: 2, height: 1, repeating: false, bytes: Array(repeating: 127, count: 8))
    let recipe = SourceMaterialCompositionRecipe(kind: .head, width: 2, height: 1, main: image, mask: image,
        colors: [.one, .one], blend: 0, encodeSRGB: false, patterns: [], layers: [])
    // Same raw array is uploaded twice per recipe. Zero fallback is one texel
    // per compositor/call, not one texel for every absent binding.
    #expect(SourceMaterialGroupCharge(recipes: [recipe, recipe]) == .init(inputBytes: 36, outputBytes: 16))
    let maskOnly = SourceMaterialCompositionRecipe(kind: .head, width: 2, height: 1, main: nil, mask: image,
        colors: [.one, .one], blend: 0, encodeSRGB: false, patterns: [], layers: [])
    #expect(SourceMaterialGroupCharge(recipes: [maskOnly, maskOnly]) == .init(inputBytes: 24, outputBytes: 16))
    let malformed = SourceMaterialCompositionRecipe(kind: .head, width: 2, height: 1,
        main: .init(width: 2, height: 1, repeating: false, bytes: []), mask: nil,
        colors: [.one, .one], blend: 0, encodeSRGB: false, patterns: [], layers: [])
    #expect(SourceMaterialGroupCharge(recipes: [malformed]) == nil) // advisory, never an early thrown error
}

private func groupPixels(_ handle: TextureHandle?, resources: ResourceStore) throws -> [UInt8] {
    let texture = try #require(resources.texture(handle))
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    bytes.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }
    return bytes
}

private struct ClothesGroupFixture {
    let directory: URL, resources: ResourceStore, source: SourcePreviewAppearance
    let card: SourceCardAppearance, bindings: SourceAppearanceBindings
    init() throws {
        directory = try AppearanceTestFixture.directory()
        resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
        source = try AppearanceTestFixture.preview(directory: directory, resources: resources)
        card = try SourceCardAppearance(card: AppearanceTestFixture.card())
        let recipe = try AppearanceTestFixture.recipe(directory: directory)
        let tint = AppearanceTestFixture.entry()
        let highlight = AppearanceTestFixture.entry(kind: "highlightUpper")
        bindings = try AppearanceTestFixture.bindings([recipe, tint, highlight], directory: directory)
    }
    func plan(source override: SourcePreviewAppearance? = nil, maximum: Int = 128 * 1024 * 1024) throws -> SourcePreparedMetalCardApplication {
        try (override ?? source).prepareMetalApplication(card, bindings: bindings, directory: directory, maximumLogicalInputBytes: maximum)
    }
    func identity(_ index: Int) -> SourceClothesComponentIdentity { .init(index: index, slot: index, prefix: "clothes-\(index)/") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialClothesGroupPreservesIndependentPixelsReplayAndLeases() throws {
    let fixture = try ClothesGroupFixture(); defer { fixture.remove() }
    let resources = fixture.resources
    let expected = try fixture.source.applying(fixture.card, bindings: fixture.bindings, directory: fixture.directory,
        resources: resources, backend: .cpu)
    let expectedMaterial = try #require(expected.appearance.materials["part"]?.first)
    let expectedPixels = try groupPixels(expectedMaterial.base, resources: resources)
    let baseline = resources.statistics().textures
    let timings = SourceAppearanceTimings()
    let group = SourceClothesMaterialGroup(resources: resources, timings: timings)
    let plan = try fixture.plan()
    let first = try group.append(plan, identity: fixture.identity(0))
    let second = try group.append(plan, identity: fixture.identity(1))
    #expect(first.isEmpty && second.isEmpty)
    #expect(resources.statistics().textures == baseline && timings.sample.composition == nil)
    var completed = try group.finish()
    #expect(completed.map(\.identity) == [fixture.identity(0), fixture.identity(1)])
    let handles = try completed.map { try #require($0.application.appearance.materials["part"]?.first?.base) }
    #expect(Set(handles).count == 2)
    for item in completed {
        var material = try #require(item.application.appearance.materials["part"]?.first)
        let pixels = try groupPixels(material.base, resources: resources)
        let matches = zip(pixels, expectedPixels).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        #expect(matches)
        material.base = expectedMaterial.base
        #expect(material == expectedMaterial)
        #expect(item.application.appliedFields == expected.appliedFields && item.application.diagnostics == expected.diagnostics)
    }
    let counters = try #require(timings.sample.composition)
    #expect(counters.realInputAllocations == 4 && counters.fallbackAllocations == 2)
    #expect(counters.metalEncodeDispatches == 2 && counters.metalBatchCompletions == 1)
    #expect(timings.sample.scopes.map(\.identity.role) == [.clothesCompositionGroup])
    #expect(timings.sample.scopes.first?.identity.componentIndices == [0, 1])
    let groupedPixels = try groupPixels(handles[0], resources: resources)
    completed.removeAll()
    #expect(handles.allSatisfy { resources.texture($0) == nil })
    #expect(resources.statistics().textures == baseline)
    let withoutDiagnostics = SourceClothesMaterialGroup(resources: resources, timings: nil)
    _ = try withoutDiagnostics.append(plan, identity: fixture.identity(0))
    let plain = try withoutDiagnostics.finish()
    // A material handle alone does not retain the appearance's texture leases.
    let plainPixels = try withExtendedLifetime(plain) {
        try groupPixels(plain[0].application.appearance.materials["part"]?.first?.base, resources: resources)
    }
    #expect(plainPixels == groupedPixels)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialClothesGroupCapacityAndOversizeUseRealStandalonePath() throws {
    let fixture = try ClothesGroupFixture(); defer { fixture.remove() }
    let plan = try fixture.plan()
    #expect(plan.groupingCharge == .init(inputBytes: 12, outputBytes: 4))
    for capacity in [SourceMaterialGroupCapacity(inputBytes: 24, outputBytes: 8), .init(inputBytes: 11, outputBytes: 8), .init(inputBytes: 24, outputBytes: 3)] {
        let timings = SourceAppearanceTimings()
        let group = SourceClothesMaterialGroup(resources: fixture.resources, timings: timings, capacity: capacity)
        var completed: [SourceClothesMaterialGroup.Completed] = []
        for i in 0..<3 { completed += try group.append(plan, identity: fixture.identity(i)) }
        completed += try group.finish()
        #expect(completed.map(\.identity) == (0..<3).map(fixture.identity))
        #expect(timings.sample.composition?.metalEncodeDispatches == 3)
        #expect(timings.sample.composition?.metalBatchCompletions == (capacity.inputBytes == 24 && capacity.outputBytes == 8 ? 2 : 3))
        let sample = timings.sample, scopes = sample.scopes
        let aggregate = try #require(sample.composition)
        for (phase, count) in sample.calls {
            #expect(scopes.reduce(0) { $0 + $1.calls[phase, default: 0] } == count)
            let sum = scopes.reduce(0.0) { $0 + $1.milliseconds[phase, default: 0] }
            #expect(abs(sum - sample.milliseconds[phase, default: 0]) < 0.000001)
        }
        for (phase, count) in aggregate.calls {
            #expect(scopes.reduce(0) { $0 + ($1.composition?.calls[phase] ?? 0) } == count)
            let sum = scopes.reduce(0.0) { $0 + ($1.composition?.milliseconds[phase] ?? 0) }
            #expect(abs(sum - aggregate.milliseconds[phase, default: 0]) < 0.000001)
        }
        #expect(scopes.reduce(0) { $0 + ($1.composition?.realInputAllocations ?? 0) } == aggregate.realInputAllocations)
        #expect(scopes.reduce(0) { $0 + ($1.composition?.fallbackAllocations ?? 0) } == aggregate.fallbackAllocations)
        #expect(scopes.reduce(0) { $0 + ($1.composition?.fallbackBindings ?? 0) } == aggregate.fallbackBindings)
        #expect(scopes.reduce(0) { $0 + ($1.composition?.metalEncodeDispatches ?? 0) } == aggregate.metalEncodeDispatches)
        #expect(scopes.reduce(0) { $0 + ($1.composition?.metalBatchCompletions ?? 0) } == aggregate.metalBatchCompletions)
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialClothesLaterInvalidInputCompletesEarlierAndKeepsPriorAppearance() throws {
    let fixture = try ClothesGroupFixture(); defer { fixture.remove() }
    let prior = try fixture.source.applying(fixture.card, bindings: fixture.bindings, directory: fixture.directory, resources: fixture.resources)
    let oldHandle = try #require(prior.appearance.materials["part"]?.first?.base)
    let oldPixels = try groupPixels(oldHandle, resources: fixture.resources)
    let baseline = fixture.resources.statistics().textures
    let timings = SourceAppearanceTimings()
    let group = SourceClothesMaterialGroup(resources: fixture.resources, timings: timings)
    _ = try group.append(fixture.plan(source: prior.appearance), identity: fixture.identity(0))
    var bad = AppearanceTestFixture.entry(); bad["parts"] = ["absent"]
    let invalid = try AppearanceTestFixture.bindings([bad], directory: fixture.directory)
    do {
        _ = try group.preparing {
            try prior.appearance.prepareMetalApplication(fixture.card, bindings: invalid, directory: fixture.directory)
        }
        Issue.record("Later invalid target must still fail")
    } catch RigError.invalid(let reason) { #expect(reason == "Appearance binding targets an absent material: absent.") }
    #expect(timings.sample.composition?.metalBatchCompletions == 1)
    #expect(fixture.resources.statistics().textures == baseline)
    #expect(try groupPixels(oldHandle, resources: fixture.resources) == oldPixels)
    let remainder = try group.finish()
    #expect(remainder.isEmpty) // failed requests cannot retry a consumed group
}

private enum GroupTestError: Error { case dispatch }

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialClothesGroupFaultsAreAtomicAndKeepUnderlyingIdentity() throws {
    let fixture = try ClothesGroupFixture(); defer { fixture.remove() }
    let prior = try fixture.source.applying(fixture.card, bindings: fixture.bindings, directory: fixture.directory, resources: fixture.resources)
    let oldHandle = try #require(prior.appearance.materials["part"]?.first?.base)
    let oldPixels = try groupPixels(oldHandle, resources: fixture.resources)
    let baseline = fixture.resources.statistics().textures
    for phase in 0..<4 {
        var hooks = SourceMaterialMetalCompletionHooks()
        switch phase {
        case 0: hooks.commandBuffer = { _ in nil }
        case 1: hooks.encoder = { _ in nil }
        case 2: hooks.completionError = { _ in GroupTestError.dispatch }
        default: hooks.view = { texture, index in index == 1 ? nil : texture.makeTextureView(pixelFormat: .rgba8Unorm_srgb) }
        }
        let group = SourceClothesMaterialGroup(resources: fixture.resources, timings: nil, hooks: hooks)
        _ = try group.append(fixture.plan(source: prior.appearance), identity: fixture.identity(0))
        _ = try group.append(fixture.plan(source: prior.appearance), identity: fixture.identity(1))
        do { _ = try group.finish(); Issue.record("Injected Metal boundary must fail") }
        catch let error as SourceMaterialGroupExecutionError {
            #expect(error.components == [fixture.identity(0), fixture.identity(1)])
            if phase == 2 {
                let completion = try #require(error.underlying as? SourceMaterialMetalCompletionError)
                #expect(completion.underlying is GroupTestError)
            }
        }
        let remainder = try group.finish()
        #expect(remainder.isEmpty)
        #expect(fixture.resources.statistics().textures == baseline)
        #expect(try groupPixels(oldHandle, resources: fixture.resources) == oldPixels)
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialClothesLateAllocationValidationFlushesPriorAndPreservesFailurePriority() throws {
    let fixture = try ClothesGroupFixture(); defer { fixture.remove() }
    let before = fixture.resources.statistics().textures
    for priorFails in [false, true] {
        let timings = SourceAppearanceTimings()
        var hooks = SourceMaterialMetalCompletionHooks()
        if priorFails { hooks.completionError = { _ in GroupTestError.dispatch } }
        let group = SourceClothesMaterialGroup(resources: fixture.resources, timings: timings, hooks: hooks)
        _ = try group.append(fixture.plan(), identity: fixture.identity(0))
        // This bound is accepted by plan construction. Its original validation
        // runs after pipeline creation/input allocation, not during advisory charge.
        _ = try group.append(fixture.plan(maximum: 4), identity: fixture.identity(1))
        #expect(timings.sample.composition == nil)
        do { _ = try group.finish(); Issue.record("Second call's original input cap must reject it") }
        catch let error as SourceMaterialGroupExecutionError {
            #expect(priorFails && error.components == [fixture.identity(0)])
            let completion = try #require(error.underlying as? SourceMaterialMetalCompletionError)
            #expect(completion.underlying is GroupTestError)
        } catch RigError.invalid(let reason) {
            #expect(!priorFails && reason == "Composed appearance Metal inputs exceed 4 bytes.")
        }
        #expect(timings.sample.composition?.metalBatchCompletions == 1)
        #expect(fixture.resources.statistics().textures == before)
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialClothesDiscardedPlanKeepsBorrowedTexturesWithoutAllocation() throws {
    let fixture = try ClothesGroupFixture(); defer { fixture.remove() }
    let prior = try fixture.source.applying(fixture.card, bindings: fixture.bindings, directory: fixture.directory, resources: fixture.resources)
    let handle = try #require(prior.appearance.materials["part"]?.first?.base)
    let before = fixture.resources.statistics().textures
    let timings = SourceAppearanceTimings()
    var group: SourceClothesMaterialGroup? = .init(resources: fixture.resources, timings: timings)
    _ = try group!.append(fixture.plan(source: prior.appearance), identity: fixture.identity(0))
    group = nil
    #expect(timings.sample.composition == nil && fixture.resources.statistics().textures == before)
    #expect(fixture.resources.texture(handle) != nil)
}

private final class GroupWeakTexture {
    weak var value: (any MTLTexture)?
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialClothesFailedViewReleasesPrivateOutputAfterCompletion() throws {
    let fixture = try ClothesGroupFixture(); defer { fixture.remove() }
    let weakOutput = GroupWeakTexture()
    let baseline = fixture.resources.statistics().textures
    try autoreleasepool {
        var hooks = SourceMaterialMetalCompletionHooks()
        hooks.view = { texture, index in
            if index == 0 { weakOutput.value = texture; return texture.makeTextureView(pixelFormat: .rgba8Unorm_srgb) }
            return nil
        }
        let group = SourceClothesMaterialGroup(resources: fixture.resources, timings: nil, hooks: hooks)
        _ = try group.append(fixture.plan(), identity: fixture.identity(0))
        _ = try group.append(fixture.plan(), identity: fixture.identity(1))
        do { _ = try group.finish(); Issue.record("Second view must reject the atomic group") }
        catch is SourceMaterialGroupExecutionError {}
    }
    #expect(weakOutput.value == nil)
    #expect(fixture.resources.statistics().textures == baseline)
}

/// R7 phase 2 item 6 follow-up: compositors share one command queue per
/// device, and a composition through either gives the same bytes.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialCompositorsShareOneQueueAndComposeTheSameBytes() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let first = try SourceMaterialCompositor(device: device), second = try SourceMaterialCompositor(device: device)
    #expect(first.queue === second.queue)
    let width = 8, height = 4
    let main = SourceMaterialImage(width: width, height: height, repeating: false,
                                   bytes: (0..<(width * height * 4)).map { UInt8(($0 * 37) % 256) })
    let mask = SourceMaterialImage(width: width, height: height, repeating: false,
                                   bytes: (0..<(width * height * 4)).map { UInt8(($0 * 11 + 5) % 256) })
    func compose(_ compositor: SourceMaterialCompositor) throws -> [UInt8] {
        let batch = try compositor.makeBatch(maximumLogicalInputBytes: 1 << 20, timings: nil)
        try batch.prepare(kind: .clothes, width: width, height: height, main: main, mask: mask,
                          colors: [Float4(0.8, 0.2, 0.1, 1), Float4(0.1, 0.6, 0.3, 1), Float4(0.2, 0.3, 0.9, 1)],
                          blend: 0.5, encodeSRGB: true, patterns: [], layers: [])
        let output = try #require(try batch.complete().first)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }
    let a = try compose(first), b = try compose(second)
    #expect(a == b && a.contains { $0 != 0 })
}
