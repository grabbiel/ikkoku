import Foundation
import Testing
import Metal
import simd
import CoreMath
import Character
import Scene
import Studio
import Renderer

@Test func sourceStudioAnimationClockResumesSpeedAndSourceForceLoopBoundary() throws {
    var clock = try SourceStudioAnimation.Clock(normalizedTime: 0.625)
    try clock.advance(deltaTime: 0.5, speed: 1.25, stateSpeed: 0.5, duration: 2, loops: true, forceLoop: false)
    #expect(clock.normalizedTime == 0.78125)
    try clock.advance(deltaTime: 4, speed: 1, stateSpeed: 1, duration: 1, loops: true, forceLoop: true)
    #expect(clock.normalizedTime == 4.78125) // Loop counters are saved, not reduced modulo one.
    try clock.advance(deltaTime: 0, speed: 0, stateSpeed: 1, duration: 1, loops: false, forceLoop: true)
    #expect(clock.normalizedTime == 0) // Original LateUpdate also runs at zero speed.
    try clock.advance(deltaTime: 1.5, speed: 1, stateSpeed: 1, duration: 1, loops: false, forceLoop: true)
    #expect(clock.normalizedTime == 0) // Overshoot is discarded, not 0.5.
    #expect(throws: (any Error).self) { try clock.advance(deltaTime: .nan, speed: 1, stateSpeed: 1, duration: 1, loops: false, forceLoop: false) }
    #expect(throws: (any Error).self) { try clock.advance(deltaTime: 1, speed: -1, stateSpeed: 1, duration: 1, loops: false, forceLoop: false) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_ANIMATION_CONTRACT"]),
               "Requires IKKOKU_STUDIO_ANIMATION_CONTRACT"))
func sourceStudioAnimationClockMatchesRecoveredBinary32TraceWhenSupplied() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CONTRACT")
    struct Contract: Decodable {
        struct Scenario: Decodable {
            struct Frame: Decodable { let deltaTime: Float, normalizedTime: Float }
            let initial: Float, speed: Float, stateSpeed: Float, duration: Float
            let loops: Bool, forceLoop: Bool, frames: [Frame]
        }
        let schemaVersion: Int, scenarios: [Scenario]
    }
    let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(contract.schemaVersion == 1 && contract.scenarios.count == 5)
    for scenario in contract.scenarios {
        var clock = try SourceStudioAnimation.Clock(normalizedTime: scenario.initial)
        for frame in scenario.frames {
            try clock.advance(deltaTime: frame.deltaTime, speed: scenario.speed, stateSpeed: scenario.stateSpeed,
                duration: scenario.duration, loops: scenario.loops, forceLoop: scenario.forceLoop)
            #expect(clock.normalizedTime == frame.normalizedTime)
        }
    }
}

@Test func sourceStudioAnimationEditsPreserveOtherRecordsAndReverseToExactBytes() throws {
    let bytes = SceneDocumentBytes.scene().data, source = try KoikatsuSceneReader.decodeDocument(bytes)
    let original = try #require(source.snapshot.roots[0].character)
    var edit = SourceStudioAnimationState(record: original)
    edit.group = 0; edit.category = 4; edit.no = 0; edit.speed = 0.75; edit.pattern = 0.2
    edit.optionParameters = SIMD2(0.3, 0.8); edit.normalizedTime = 3.625; edit.forceLoop = true
    let data = try source.editedData(.init(animations: [10: edit])), after = try KoikatsuSceneReader.decodeDocument(data)
    let changed = try #require(after.snapshot.roots[0].character)
    #expect(SourceStudioAnimationState(record: changed) == edit)
    #expect(changed.cardData == original.cardData && changed.bones == original.bones && changed.ikTargets == original.ikTargets)
    #expect(changed.voices == original.voices && changed.handPatterns == original.handPatterns && changed.neckData == original.neckData)
    #expect(changed.animationOptionVisible == original.animationOptionVisible && changed.expressions == original.expressions)
    #expect(after.snapshot.roots[1] == source.snapshot.roots[1] && after.settings == source.settings && after.trailingData == source.trailingData)
    #expect(try after.editedData(.init(animations: [10: .init(record: original)])) == bytes)
    #expect(throws: (any Error).self) { try source.editedData(.init(animations: [20: edit])) }
    edit.pattern = .infinity
    #expect(throws: (any Error).self) { try source.editedData(.init(animations: [10: edit])) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_ANIMATION_CATALOG"]),
               "Requires IKKOKU_STUDIO_ANIMATION_CATALOG"))
func sourceStudioAnimationConvertedNormalCatalogIdentityParametersAndSamplesWhenSupplied() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CATALOG")
    let url = URL(fileURLWithPath: path), catalog = try SourceStudioAnimationCatalog.load(url: url)
    let scene = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    var state = SourceStudioAnimationState(record: try #require(scene.snapshot.roots[0].character))
    state.group = 0; state.category = 4; state.no = 0; state.normalizedTime = 0.25; state.pattern = 0.375
    let animation = try catalog.resolve(state, directory: url.deletingLastPathComponent())
    #expect(animation.entry.controller == "tachi" && animation.entry.state == "f_stand_00_00")
    let parameters = try animation.parameters(height: 0.42)
    #expect(parameters["motion"] == nil && parameters["height1"] == nil && parameters["Breast"] == nil)
    if animation.library.parameters.contains(where: { $0.name == "height" }) { #expect(parameters["height"] == 0.42) }
    let clock = try animation.clock(state: state, elapsed: 0.5, height: 0.42)
    #expect(clock.normalizedTime > state.normalizedTime)
    #expect(try animation.clock(state: state, elapsed: 0.5, height: 0.42) == clock)
    state.no = 999_999
    #expect(throws: (any Error).self) { try catalog.resolve(state, directory: url.deletingLastPathComponent()) }
    struct Reference: Decodable {
        struct Sample: Decodable { let file: String, clipID: String, time: Float, values: [Float] }
        let samples: [Sample]
    }
    let oracle = try JSONDecoder().decode(Reference.self,
        from: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("sample-reference.json")))
    let samples = Dictionary(grouping: oracle.samples, by: \.file)
    // Every generated executable state must pass the native schema, hash and
    // exact controller/name checks, including the initialized streamed curves.
    for entry in catalog.entries where entry.file != nil {
        state.group = entry.group; state.category = entry.category; state.no = entry.no
        let converted = try catalog.resolve(state, directory: url.deletingLastPathComponent())
        #expect(converted.library.states.count == 1)
        for sample in samples[entry.file!] ?? [] {
            let actual = try converted.library.clip(id: sample.clipID).sample(time: sample.time)
            #expect(actual.count == sample.values.count)
            let mismatch = zip(actual, sample.values).filter { abs($0 - $1) > max(0.00002, abs($1) * 0.00002) }.count
            #expect(mismatch == 0)
        }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_ANIMATION_CATALOG"]),
               "Requires IKKOKU_STUDIO_ANIMATION_CATALOG"))
func sourceStudioAnimationIncrementalClockRetainsExactFixedStepBoundariesWhenSupplied() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CATALOG")
    let url = URL(fileURLWithPath: path), catalog = try SourceStudioAnimationCatalog.load(url: url)
    let scene = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    var state = SourceStudioAnimationState(record: try #require(scene.snapshot.roots[0].character))
    state.group = 0; state.category = 4; state.no = 0; state.normalizedTime = 0.375; state.speed = 0.7
    let animation = try catalog.resolve(state, directory: url.deletingLastPathComponent())
    var playback = SourceStudioAnimation.Playback()
    for i in 0..<91 {
        let time = Float(i) / 29 + 0.0023 // Repeated non-boundary tails must not accumulate.
        let incremental = try animation.clock(state: state, elapsed: time, height: 0.42, playback: &playback)
        #expect(incremental == (try animation.clock(state: state, elapsed: time, height: 0.42)))
        #expect(playback.lastAdvanceSteps <= 3)
    }
    for time: Float in [0.5,0.7,0.2] { // Backwards seek resets; subsequent playback still matches.
        #expect(try animation.clock(state: state, elapsed: time, height: 0.42, playback: &playback) == animation.clock(state: state, elapsed: time, height: 0.42))
    }
    state.speed = 1.25; state.normalizedTime = 0.9; state.forceLoop = true
    #expect(try animation.clock(state: state, elapsed: 5, height: 0.8, playback: &playback) == animation.clock(state: state, elapsed: 5, height: 0.8))
    #expect(playback.lastAdvanceSteps == 300)
    playback.reset()
    let hour = try animation.clock(state: state, elapsed: 3600, height: 0.8, playback: &playback)
    #expect(hour == (try animation.clock(state: state, elapsed: 3600, height: 0.8)))
    _ = try animation.clock(state: state, elapsed: 3600 + 1 / 30, height: 0.8, playback: &playback)
    #expect(playback.lastAdvanceSteps <= 3) // Live cost no longer scales with scene age.
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_STUDIO_EXPANSION", "IKKOKU_MAKER_LIBRARY", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT", "IKKOKU_STUDIO_ANIMATION_CATALOG"]) && MTLCreateSystemDefaultDevice() != nil,
               "Requires IKKOKU_STUDIO_EXPANSION, IKKOKU_MAKER_LIBRARY, IKKOKU_SOURCE_AVATAR, IKKOKU_STUDIO_POSE_CONTRACT, IKKOKU_STUDIO_ANIMATION_CATALOG and a Metal device"))
func sourceStudioAnimationEvaluatesClothedPoseAttachmentsAndExportReloadWhenSupplied() throws {
    let folder = try SourceFixtureSupport.require("IKKOKU_STUDIO_EXPANSION")
    let maker = try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")
    let female = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let bones = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    let animations = try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CATALOG")
    let input = URL(fileURLWithPath: folder).appendingPathComponent("studio-female-head200-bone1.png")
    let original = try KoikatsuSceneReader.decodeDocument(Data(contentsOf: input))
    let record = try #require(original.snapshot.roots[0].character)
    var selection = SourceStudioAnimationState(record: record)
    selection.group = 0; selection.category = 4; selection.no = 0; selection.normalizedTime = 0.25; selection.speed = 0.75
    let fixture = input.deletingLastPathComponent().appendingPathComponent("animation-fixture-" + UUID().uuidString + ".png")
    let saved = input.deletingLastPathComponent().appendingPathComponent("animation-reload-" + UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: fixture); try? FileManager.default.removeItem(at: saved) }
    let initialBytes = try original.editedData(.init(animations: [10: selection])); try initialBytes.write(to: fixture)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    func preview(_ file: URL, _ bytes: Data) throws -> SourceStudioCharacterPreview {
        try .init(reference: .init(sceneFile: file.path, sceneSHA256: OriginalCardFixture.hash(bytes), rigFile: female,
            boneCatalogFile: bones, objectKey: 10, makerLibraryFile: maker,
            attachmentCatalogFile: URL(fileURLWithPath: bones).deletingLastPathComponent().appendingPathComponent("attachments.json").path,
            animationCatalogFile: animations), resources: resources)
    }
    let before = try preview(fixture, initialBytes), rig = before.preview.source.rig
    let a = try before.editedPose(animationElapsed: 0), b = try before.editedPose(animationElapsed: 0.5)
    #expect(a.localMatrices != b.localMatrices)
    #expect(a.localMatrices.elementsEqual(before.pose.localMatrices))
    #expect(try before.editedPose(animationElapsed: 0.5).localMatrices.elementsEqual(b.localMatrices))
    let attachment = try before.attachmentMatrix(pointID: 7, animationElapsed: 0.5)
    #expect(attachment == (try rig.evaluate(b)).worldMatrices[try rig.uniqueNode(named: "a_n_head")])
    let frame = try before.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(), world: matrix_identity_float4x4,
        objectID: 10, animationElapsed: 0.5)
    #expect(frame.items.count >= 20 && frame.sceneBounds.radius.isFinite)
    let finalState = try before.savedAnimationState(animationElapsed: 0.5)
    let reloadBytes = try KoikatsuSceneReader.decodeDocument(initialBytes).editedData(.init(animations: [10: finalState]))
    try reloadBytes.write(to: saved)
    let after = try preview(saved, reloadBytes)
    #expect(after.pose.localMatrices.elementsEqual(b.localMatrices))
    #expect(after.record.cardData == before.record.cardData)
    if let output = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_ANIMATION_FIXTURE_OUTPUT"] {
        let path = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try initialBytes.write(to: path.appendingPathComponent("clothed-studio-animation.png"))
        try reloadBytes.write(to: path.appendingPathComponent("clothed-studio-animation-t05.png"))
        try JSONEncoder().encode(finalState).write(to: path.appendingPathComponent("expected-state-t05.json"))
    }
}
