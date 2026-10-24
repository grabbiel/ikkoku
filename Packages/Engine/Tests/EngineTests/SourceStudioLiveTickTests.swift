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
func liveTickStep(_ preview: SourceStudioCharacterPreview, character: Int, tick: Int, expression: SourceStudioExpressionState?,
                  random: inout LiveTickRandom, digest: inout LiveTickDigest) throws {
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
    try preview.setWear(clothesState: nil, showAccessory: nil)
    try preview.setExpressionState(expression)
    let world = Transform.trs(Float3(Float(character) * 0.7, 0, 0), simd_quatf(angle: Float(character) * 0.3, axis: Float3(0, 1, 0)), .one)
    let frame = try preview.frame(camera: OrbitCamera(), mainLight: MainLight(), effects: SceneEffects(), world: world,
                                  objectID: UInt32(character + 1), fkRotations: edit.fk, kinematics: edit.kinematics, animationElapsed: elapsed)
    digest.add(frame: frame)
    digest.add(pose: try preview.editedPose(fkRotations: edit.fk, kinematics: edit.kinematics, animationElapsed: elapsed))
    if let rates = preview.eyeLookRates { for rate in rates.horizontal { digest.add(rate.bitPattern) }; digest.add(rates.vertical.bitPattern) }
    digest.add(preview.didBlink)
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

@Test(.enabled(if: SourceFixtureSupport.shouldRun(liveTickVariables) && MTLCreateSystemDefaultDevice() != nil,
               "Requires the Studio scenario scene and its import fixtures (\(liveTickVariables.joined(separator: ", "))) and a Metal device"))
func sourceStudioLiveTickDigestIsReproducibleWhenSupplied() throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let previews = try liveTickFixturePreviews(resources: resources)
    #expect(previews.count >= 2)
    let expressions = try liveTickExpressions(previews)
    #expect(previews.filter(\.hasLiveNeckLook).count >= 1)
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
    print("[live-tick-digest] \(value) characters=\(previews.count) ticks=\(liveTickCount)"
        + " ms/tick=\(String(format: "%.3f", milliseconds / Double(liveTickCount)))"
        + " neck=\(previews.filter(\.hasLiveNeckLook).count) eye=\(previews.filter(\.hasLiveEyeLook).count)"
        + " dynamics=\(previews.map(\.dynamicsComponentCount))")
    if let expected = ProcessInfo.processInfo.environment["IKKOKU_LIVE_TICK_DIGEST"], !expected.isEmpty {
        #expect(value == expected)
    }
}
