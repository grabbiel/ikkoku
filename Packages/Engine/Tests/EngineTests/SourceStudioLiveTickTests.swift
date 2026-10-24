import Foundation
import CryptoKit
import Testing
import Metal
import simd
import Assets
import CoreMath
import Scene
import Studio
import Character
@testable import Renderer

// R7 phase 2, item 3: the Studio live tick's per-character output, hashed over
// many ticks of the scenario scene. The digest is the before/after proof that
// the per-character caches (C2 dynamics topology, C3 bound pose, C5
// expression weights) and the parallel tick leave every float bit-identical.
// `IKKOKU_LIVE_TICK_DIGEST` pins the expected digest; without it the test
// prints the digest it computed. Run it in Release:
// `swift test -c release --package-path Packages/Engine --filter SourceStudioLiveTick`.

/// The three fixture tests each load the 7 characters of the scenario scene
/// and step them for seconds. They run one at a time, each on a thread of its
/// own (`liveTickOffPool`).
@Suite(.serialized) struct SourceStudioLiveTickFixtureTests {}

/// A fixture test's failure on its own thread, reported by the test.
struct LiveTickFailure: Error, CustomStringConvertible {
    let description: String
}

/// Runs `body` on a thread of its own and suspends the calling test until it
/// returns. Building a preview blocks its thread in MetalKit's synchronous
/// texture load (`ResourceStore.texture`). A parallel `swift test` hung twice
/// with every thread of its test pool blocked there, with these tests running
/// on that pool. Without these tests, the suite passed. Here they hold no
/// pool thread while they load or step. Their checks stay in the test's own
/// task: `body` returns what they compare.
func liveTickOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Result { try body() }) }
        thread.stackSize = 8 << 20
        thread.start()
    }
}

private let liveTickVariables = ["IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT",
                                 "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_ANIMATION_CATALOG", "IKKOKU_STUDIO_LOOK_SETTINGS",
                                 "IKKOKU_STUDIO_HAND_PATTERNS"]

/// Every source character of the scenario scene, built the way the Studio
/// import builds it, in source key order.
func liveTickFixturePreviews(resources: ResourceStore) throws -> [SourceStudioCharacterPreview] {
    let environment = ProcessInfo.processInfo.environment
    let scene = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_SCENARIO_SCENE"))
    let data = try Data(contentsOf: scene)
    let decoded = try KoikatsuSceneReader.decodeDocument(data)
    var stack = decoded.snapshot.roots, characters: [(key: Int32, sex: Int32)] = []
    while let object = stack.popLast() {
        stack += object.children
        if let character = object.character {
            characters.append((object.sourceKey, character.sex))
            stack += character.accessoryChildren.values.flatMap { $0 }
        }
    }
    let catalog = try SourceFixtureSupport.require("IKKOKU_STUDIO_POSE_CONTRACT")
    let attachments = URL(fileURLWithPath: catalog).deletingLastPathComponent().appendingPathComponent("attachments.json")
    return try characters.sorted { $0.key < $1.key }.map { character in
        let rig = character.sex == 0 ? (environment["IKKOKU_SOURCE_MALE_AVATAR"] ?? "") : ""
        let reference = SourceStudioCharacterReference(sceneFile: scene.path, sceneSHA256: OriginalCardFixture.hash(data),
            rigFile: rig.isEmpty ? try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR") : rig,
            boneCatalogFile: catalog, objectKey: character.key,
            makerLibraryFile: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY"),
            attachmentCatalogFile: FileManager.default.fileExists(atPath: attachments.path) ? attachments.path : nil,
            animationCatalogFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CATALOG"),
            handPatternsFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_HAND_PATTERNS"),
            lookSettingsFile: try SourceFixtureSupport.require("IKKOKU_STUDIO_LOOK_SETTINGS"))
        return try SourceStudioCharacterPreview(reference: reference, resources: resources)
    }
}

/// SplitMix64, so the blink clocks draw the same numbers in every run.
struct LiveTickRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func integer(_ lower: Int, _ upper: Int) -> Int { lower == upper ? lower : lower + Int(next() % UInt64(upper - lower)) }
    mutating func float(_ lower: Float, _ upper: Float) -> Float { lower + (upper - lower) * Float(next() >> 40) / Float(1 << 24) }
}

/// The document-side inputs one tick passes for one character: an FK edit on
/// the first character for part of the run (held, then moving), so the bound
/// pose and solved pose caches see both a repeated and a changing key, and
/// nil everywhere else, like an unedited imported scene.
struct LiveTickEdit {
    var fk: [Int: Float3] = [:]
    var kinematics: SourceStudioKinematicState?
    static func at(tick: Int, character: Int, preview: SourceStudioCharacterPreview) -> LiveTickEdit {
        guard character == 0, (40..<100).contains(tick),
              let bone = preview.controller.targets.first(where: { $0.hasGuide && $0.bone.fkGroup == .body })?.bone.id else { return LiveTickEdit() }
        let angle: Float = tick < 70 ? 12 : 12 + Float(tick - 70) * 0.75
        return LiveTickEdit(fk: [bone: Float3(angle, -angle * 0.5, 3)])
    }
}

/// A camera position in rig model space that circles the character slowly,
/// so the neck and eye gaze keep moving.
func liveTickCamera(tick: Int, character: Int) -> Float3 {
    let phase = Float(tick) * 0.05 + Float(character)
    return Float3(sin(phase) * 0.8, 1.3 + 0.2 * cos(phase * 0.7), 1.6)
}

struct LiveTickDigest {
    private var hasher = SHA256()
    mutating func add<T>(_ value: T) { withUnsafeBytes(of: value) { hasher.update(bufferPointer: $0) } }
    mutating func add(_ matrix: float4x4) { for column in 0..<4 { add(matrix[column]) } }
    mutating func add(_ text: String) { hasher.update(data: Data(text.utf8)) }
    mutating func add(frame: RenderFrame) {
        add(frame.items.count)
        for item in frame.items {
            add(item.mesh.id); add(item.model); add(item.objectID); add(item.deformKey ?? 0); add(item.skinSet ?? 0); add(item.order)
            add(item.morphWeights.count)
            for weight in item.morphWeights { add(weight.index); add(weight.weight.bitPattern) }
            let u = item.material.uniforms
            for value in [u.baseColor, u.shadowColor, u.specular, u.rim, u.outline, u.tint1, u.tint2, u.tint3,
                          u.overlayColor0, u.overlayColor1, u.overlayColor2, u.patternColor, u.hairGloss, u.params,
                          u.eye, u.emissive, u.uvTransform, u.irisST0, u.irisST1, u.irisST2] { add(value) }
            add(u.kind); add(u.flags); add(u.sourceAlphaA.bitPattern); add(u.sourceAlphaB.bitPattern); add(u.irisRotation.bitPattern)
        }
        for key in frame.skinSets.keys.sorted() {
            add(key)
            for matrix in frame.skinSets[key]! { add(matrix) }
        }
        add(frame.sceneBounds.min); add(frame.sceneBounds.max)
    }
    mutating func add(pose: RigPose) { for matrix in pose.localMatrices { add(matrix) } }
    func finish() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}

/// One live tick of one character, in the order `StudioModel.advanceLiveFrame`
/// and its refresh call the preview: blink, neck gaze, eye gaze, the dynamics
/// step, the document's wear and face state, then the frame.
@discardableResult
func liveTickStep(_ preview: SourceStudioCharacterPreview, character: Int, tick: Int, expression: SourceStudioExpressionState?,
                  random: inout LiveTickRandom, digest: inout LiveTickDigest) throws -> RenderFrame {
    let elapsed = Float(tick) / 30, delta: Float = 1 / 30
    let edit = LiveTickEdit.at(tick: tick, character: character, preview: preview)
    _ = try preview.updateBlink(elapsed: elapsed, randomInteger: { random.integer($0, $1) }, randomFloat: { random.float($0, $1) })
    let camera = liveTickCamera(tick: tick, character: character)
    if preview.hasLiveNeckLook {
        _ = try preview.updateNeckLook(deltaTime: delta, cameraModelPosition: camera, fkRotations: edit.fk,
                                       kinematics: edit.kinematics, animationElapsed: elapsed)
    }
    if preview.hasLiveEyeLook {
        _ = try preview.updateEyeLook(deltaTime: delta, cameraModelPosition: camera, fkRotations: edit.fk,
                                      kinematics: edit.kinematics, animationElapsed: elapsed)
    }
    try preview.setDynamicsStep(elapsed: elapsed, deltaTime: delta)
    try preview.setWear(clothesState: nil, showAccessory: nil, shoesType: nil)
    try preview.setExpressionState(expression)
    let frame = try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(), world: liveTickWorld(character: character),
                                  objectID: UInt32(character + 1), fkRotations: edit.fk, kinematics: edit.kinematics, animationElapsed: elapsed)
    digest.add(frame: frame)
    digest.add(pose: try preview.editedPose(fkRotations: edit.fk, kinematics: edit.kinematics, animationElapsed: elapsed))
    if let rates = preview.eyeLookRates { for rate in rates.horizontal { digest.add(rate.bitPattern) }; digest.add(rates.vertical.bitPattern) }
    digest.add(preview.didBlink)
    return frame
}

/// The document face state of each character: the TARGET neck pattern (1) on
/// the second and third, so the live neck gaze runs too; the saved state
/// (nil) elsewhere. Applied once before the run, as an edit is.
func liveTickExpressions(_ previews: [SourceStudioCharacterPreview]) throws -> [SourceStudioExpressionState?] {
    try previews.enumerated().map { index, preview in
        guard index == 1 || index == 2 else { return nil }
        var state = preview.savedExpression; state.neckLookPattern = 1
        let settled = state.settled(from: preview.savedExpression)
        try preview.setExpressionState(settled)
        return settled
    }
}

/// A seek in the middle of the run (the inspector's clock scrub): dynamics and
/// animation playback restart, as `StudioModel.setSourceAnimationTime` does.
let liveTickSeek = 120
let liveTickCount = 180

extension SourceStudioLiveTickFixtureTests {
    @Test(.enabled(if: SourceFixtureSupport.shouldRun(liveTickVariables) && MTLCreateSystemDefaultDevice() != nil,
                   "Requires the Studio scenario scene and its import fixtures (\(liveTickVariables.joined(separator: ", "))) and a Metal device"))
    func sourceStudioLiveTickDigestIsReproducibleWhenSupplied() async throws {
        let run = try await liveTickOffPool { () throws -> (digest: String, characters: Int, neck: Int, line: String) in
            guard let device = MTLCreateSystemDefaultDevice() else { throw LiveTickFailure(description: "no Metal device") }
            let previews = try liveTickFixturePreviews(resources: ResourceStore(device: device))
            let expressions = try liveTickExpressions(previews)
            let neck = previews.filter(\.hasLiveNeckLook).count
            var randoms = previews.indices.map { LiveTickRandom(state: UInt64($0) &* 7919 &+ 17) }
            var digest = LiveTickDigest()
            let clock = ContinuousClock(), start = clock.now
            for tick in 1...liveTickCount {
                if tick == liveTickSeek { for preview in previews { preview.clearDynamicsStep(); preview.resetAnimationPlayback() } }
                for (character, preview) in previews.enumerated() {
                    try liveTickStep(preview, character: character, tick: tick, expression: expressions[character],
                                     random: &randoms[character], digest: &digest)
                }
            }
            let elapsed = clock.now - start
            let value = digest.finish()
            let milliseconds = Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) * 1e-15
            let line = "[live-tick-digest] \(value) characters=\(previews.count) ticks=\(liveTickCount)"
                + " ms/tick=\(String(format: "%.3f", milliseconds / Double(liveTickCount)))"
                + " neck=\(neck) eye=\(previews.filter(\.hasLiveEyeLook).count)"
                + " dynamics=\(previews.map(\.dynamicsComponentCount))"
            return (value, previews.count, neck, line)
        }
        print(run.line)
        #expect(run.characters >= 2)
        #expect(run.neck >= 1)
        if let expected = ProcessInfo.processInfo.environment["IKKOKU_LIVE_TICK_DIGEST"], !expected.isEmpty {
            #expect(run.digest == expected)
        }
    }
}

extension LiveTickRandom: SourceStudioBlinkRandom {}

/// The world matrix the digest places each character at.
func liveTickWorld(character: Int) -> float4x4 {
    Transform.trs(Float3(Float(character) * 0.7, 0, 0), simd_quatf(angle: Float(character) * 0.3, axis: Float3(0, 1, 0)), .one)
}

/// `liveTickStep`'s inputs as one lease: the same blink, gaze, dynamics clock,
/// wear, face state and frame, for `SourceStudioLiveTickJob`.
func liveTickLease(_ preview: SourceStudioCharacterPreview, character: Int, tick: Int, expression: SourceStudioExpressionState?,
                   random: LiveTickRandom) -> SourceStudioLiveTickLease {
    let elapsed = Float(tick) / 30
    let edit = LiveTickEdit.at(tick: tick, character: character, preview: preview)
    let edits = SourceStudioLiveTick.Edits(fkRotations: edit.fk, kinematics: edit.kinematics)
    let gaze = SourceStudioLiveTick.Gaze(cameraModelPosition: liveTickCamera(tick: tick, character: character), edits: edits)
    let request = SourceStudioLiveTick.FrameRequest(world: liveTickWorld(character: character), objectID: UInt32(character + 1),
        edits: edits, clothesState: nil, showAccessory: nil, expression: expression)
    let input = SourceStudioLiveTick.Input(elapsed: elapsed, deltaTime: 1 / 30, blink: true,
        neck: preview.hasLiveNeckLook ? gaze : nil, eye: preview.hasLiveEyeLook ? gaze : nil, frame: request)
    return SourceStudioLiveTickLease(preview: preview, input: input, random: random)
}

extension SourceStudioLiveTickFixtureTests {
    /// The same run as `sourceStudioLiveTickDigestIsReproducibleWhenSupplied`, with
    /// each tick's characters stepped in parallel by `SourceStudioLiveTickJob`
    /// and joined in character order: the digest must be the serial one. Under
    /// `swift test --sanitize=thread` this is the ThreadSanitizer run over
    /// previews driven in parallel.
    @Test(.enabled(if: SourceFixtureSupport.shouldRun(liveTickVariables) && MTLCreateSystemDefaultDevice() != nil,
                   "Requires the Studio scenario scene and its import fixtures (\(liveTickVariables.joined(separator: ", "))) and a Metal device"))
    func sourceStudioParallelLiveTickMatchesTheSerialDigest() async throws {
        let run = try await liveTickOffPool { () throws -> (digest: String, duplicateRefused: Bool, errors: [String], line: String) in
            guard let device = MTLCreateSystemDefaultDevice() else { throw LiveTickFailure(description: "no Metal device") }
            let previews = try liveTickFixturePreviews(resources: ResourceStore(device: device))
            let expressions = try liveTickExpressions(previews)
            var randoms = previews.indices.map { LiveTickRandom(state: UInt64($0) &* 7919 &+ 17) }
            var digest = LiveTickDigest()
            var wall = 0.0, cpu = 0.0, duplicateRefused = false, errors: [String] = []
            let clock = ContinuousClock(), start = clock.now
            for tick in 1...liveTickCount {
                if tick == liveTickSeek { for preview in previews { preview.clearDynamicsStep(); preview.resetAnimationPlayback() } }
                let leases = previews.enumerated().map { character, preview in
                    liveTickLease(preview, character: character, tick: tick, expression: expressions[character], random: randoms[character])
                }
                // One owner per preview per tick: a second lease of a preview is refused.
                if tick == 1 { duplicateRefused = SourceStudioLiveTickJob(leases: leases + [leases[0]]) == nil }
                guard let job = SourceStudioLiveTickJob(leases: leases) else {
                    throw LiveTickFailure(description: "tick \(tick): the job refused leases of distinct previews")
                }
                job.start(completion: nil)
                let result = job.wait()
                wall += result.wallSeconds; cpu += result.cpuSeconds
                for (character, preview) in previews.enumerated() {
                    let output = result.outputs[character]
                    for case let error? in [output.neckError, output.eyeError, output.wearError, output.faceError] {
                        errors.append("tick \(tick), character \(character): \(error)")
                    }
                    guard let random = output.random as? LiveTickRandom, let frame = output.frame else {
                        throw LiveTickFailure(description: "tick \(tick), character \(character): no blink draws or no frame")
                    }
                    randoms[character] = random
                    digest.add(frame: try frame.get())
                    let edit = LiveTickEdit.at(tick: tick, character: character, preview: preview)
                    digest.add(pose: try preview.editedPose(fkRotations: edit.fk, kinematics: edit.kinematics, animationElapsed: Float(tick) / 30))
                    if let rates = preview.eyeLookRates { for rate in rates.horizontal { digest.add(rate.bitPattern) }; digest.add(rates.vertical.bitPattern) }
                    digest.add(preview.didBlink)
                }
            }
            let elapsed = clock.now - start
            let value = digest.finish()
            let milliseconds = Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) * 1e-15
            let line = "[live-tick-parallel] \(value) characters=\(previews.count) ticks=\(liveTickCount)"
                + " ms/tick=\(String(format: "%.3f", milliseconds / Double(liveTickCount)))"
                + " job wall ms/tick=\(String(format: "%.3f", wall * 1e3 / Double(liveTickCount)))"
                + " worker cpu ms/tick=\(String(format: "%.3f", cpu * 1e3 / Double(liveTickCount)))"
            return (value, duplicateRefused, errors, line)
        }
        print(run.line)
        #expect(run.duplicateRefused)
        #expect(run.errors.isEmpty, "\(run.errors)")
        if let expected = ProcessInfo.processInfo.environment["IKKOKU_LIVE_TICK_DIGEST"], !expected.isEmpty {
            #expect(run.digest == expected)
        }
    }
}

extension SourceStudioLiveTickFixtureTests {
    /// An edit that lands while a tick runs (R7 phase 2, item 3): the Studio
    /// settles the tick first, so the preview sees the tick's calls and then the
    /// edit's refresh, exactly as when the edit arrived after a serial tick. Here
    /// the parallel tick followed by an edited frame must match the serial tick
    /// followed by the same edited frame, and a frame request that did not change
    /// must give back the tick's own frame (the reuse the refresh makes).
    @Test(.enabled(if: SourceFixtureSupport.shouldRun(liveTickVariables) && MTLCreateSystemDefaultDevice() != nil,
                   "Requires the Studio scenario scene and its import fixtures (\(liveTickVariables.joined(separator: ", "))) and a Metal device"))
    func sourceStudioEditDuringAParallelTickMatchesTheSerialOrder() async throws {
        let run = try await liveTickOffPool { () throws -> (serial: (digest: String, reuse: Bool), parallel: (digest: String, reuse: Bool)) in
            guard let device = MTLCreateSystemDefaultDevice() else { throw LiveTickFailure(description: "no Metal device") }
            return (serial: try liveTickEditRun(device: device, parallel: false), parallel: try liveTickEditRun(device: device, parallel: true))
        }
        print("[live-tick-edit] serial=\(run.serial.digest) parallel=\(run.parallel.digest) reuse=\(run.serial.reuse)/\(run.parallel.reuse)")
        #expect(run.serial.digest == run.parallel.digest)
        #expect(run.serial.reuse && run.parallel.reuse)
    }
}

/// One run of `sourceStudioEditDuringAParallelTickMatchesTheSerialOrder`:
/// 45 ticks, serial or through the job, with an FK edit after every third.
func liveTickEditRun(device: any MTLDevice, parallel: Bool) throws -> (digest: String, reuse: Bool) {
    let previews = try liveTickFixturePreviews(resources: ResourceStore(device: device))
    let expressions = try liveTickExpressions(previews)
    var randoms = previews.indices.map { LiveTickRandom(state: UInt64($0) &* 7919 &+ 17) }
    var digest = LiveTickDigest(), reuse = true
    for tick in 1...45 {
        var frames: [RenderFrame] = []
        if parallel {
            let leases = previews.enumerated().map { character, preview in
                liveTickLease(preview, character: character, tick: tick, expression: expressions[character], random: randoms[character])
            }
            guard let job = SourceStudioLiveTickJob(leases: leases) else {
                throw LiveTickFailure(description: "tick \(tick): the job refused leases of distinct previews")
            }
            job.start()
            let result = job.wait()
            for character in previews.indices {
                guard let random = result.outputs[character].random as? LiveTickRandom, let frame = result.outputs[character].frame else {
                    throw LiveTickFailure(description: "tick \(tick), character \(character): no blink draws or no frame")
                }
                randoms[character] = random
                frames.append(try frame.get())
            }
        } else {
            for (character, preview) in previews.enumerated() {
                var scratch = LiveTickDigest()
                frames.append(try liveTickStep(preview, character: character, tick: tick, expression: expressions[character],
                                               random: &randoms[character], digest: &scratch))
            }
        }
        for frame in frames { digest.add(frame: frame) }
        // Every third tick an FK edit lands on character 1 "mid-tick": its
        // refresh asks for an edited frame after the tick's own.
        guard tick % 3 == 0 else { continue }
        let preview = previews[1], elapsed = Float(tick) / 30
        guard let bone = preview.controller.targets.first(where: { $0.hasGuide && $0.bone.fkGroup == .body })?.bone.id else { continue }
        let edited = try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(),
            world: liveTickWorld(character: 1), objectID: 2, fkRotations: [bone: Float3(Float(tick), 4, -2)], animationElapsed: elapsed)
        digest.add(frame: edited)
        // The unchanged request of character 2 returns its tick frame.
        let again = try previews[2].frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(),
            world: liveTickWorld(character: 2), objectID: 3, animationElapsed: elapsed)
        var first = LiveTickDigest(), second = LiveTickDigest()
        first.add(frame: frames[2]); second.add(frame: again)
        reuse = reuse && first.finish() == second.finish()
    }
    return (digest.finish(), reuse)
}

@Test func sourceStudioEmptyLiveTickJobJoinsAtOnce() throws {
    let empty = try #require(SourceStudioLiveTickJob(leases: []))
    empty.start()
    #expect(empty.wait().outputs.isEmpty)
    #expect(empty.isFinished)
}
