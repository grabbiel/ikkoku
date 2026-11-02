import Foundation
import Testing
import Metal
import simd
import Assets
import CoreMath
import Scene
import Character
@testable import Studio
@testable import Renderer

// R7 item 3, FK drag: a Studio character gives its last frame back while
// nothing it reads changed (`SourceStudioCharacterPreview.frame`). The twin
// test drives two sets of the scenario scene's characters, each in a store of
// its own, through the same calls: one set reuses frames, the other builds
// every frame afresh. Every frame must match its twin bit for bit, and the
// reusing set must report a reuse exactly when nothing changed.

private let frameReuseVariables = ["IKKOKU_STUDIO_SCENARIO_SCENE", "IKKOKU_SOURCE_AVATAR", "IKKOKU_STUDIO_POSE_CONTRACT",
                                   "IKKOKU_MAKER_LIBRARY", "IKKOKU_STUDIO_ANIMATION_CATALOG", "IKKOKU_STUDIO_LOOK_SETTINGS",
                                   "IKKOKU_STUDIO_HAND_PATTERNS"]

/// The live-tick digest of a frame, plus what it leaves out: texture handles,
/// gizmo vertices and the camera, light and effects a reuse swaps in.
func frameReuseDigest(_ frame: RenderFrame) -> String {
    var digest = LiveTickDigest()
    digest.add(frame: frame)
    for item in frame.items {
        digest.add(item.material.textureHandles.count)
        for handle in item.material.textureHandles { digest.add(handle.id) }
    }
    digest.add(frame.gizmos.count)
    for batch in frame.gizmos {
        digest.add(batch.vertices.count)
        for vertex in batch.vertices { digest.add(vertex.position); digest.add(vertex.color) }
    }
    digest.add(frame.camera.position); digest.add(frame.camera.target); digest.add(frame.camera.distance.bitPattern)
    digest.add(frame.mainLight.rotation); digest.add(frame.mainLight.color); digest.add(frame.mainLight.intensity.bitPattern)
    digest.add(frame.effects.bloomThreshold.bitPattern); digest.add(frame.effects.bloomIntensity.bitPattern)
    return digest.finish()
}

/// One character of each set with what its calls reported.
private struct FrameReuseTwin {
    let reusing: SourceStudioCharacterPreview, fresh: SourceStudioCharacterPreview
    var failures: [String] = []
    var reused = 0, built = 0

    /// Runs `call` on both twins, compares the frames and, when `reuse` is
    /// given, checks that the reusing twin reported it.
    @discardableResult
    mutating func step(_ label: String, reuse: Bool?, _ call: (SourceStudioCharacterPreview) throws -> RenderFrame) throws -> RenderFrame {
        let a = try call(reusing), b = try call(fresh)
        if reusing.lastFrameReused { reused += 1 } else { built += 1 }
        if fresh.lastFrameReused { failures.append("\(label): the twin without reuse reported a reuse") }
        if let reuse, reusing.lastFrameReused != reuse {
            failures.append("\(label): expected \(reuse ? "a reuse" : "a fresh frame"), got \(reusing.lastFrameReused ? "a reuse" : "a fresh frame")")
        }
        if frameReuseDigest(a) != frameReuseDigest(b) { failures.append("\(label): the frames differ") }
        return a
    }
}

/// The frame call a Studio refresh makes for one character.
private struct FrameReuseRequest {
    var camera = OrbitCamera(), mainLight = MainLight(), effects = SceneEffects()
    var world = matrix_identity_float4x4, objectID: UInt32 = 1
    var fk: [Int: Float3] = [:], face: [Float]? = nil, ik: [Int32: SourceStudioIKEdit] = [:], elapsed: Float = 0
    func frame(_ preview: SourceStudioCharacterPreview) throws -> RenderFrame {
        try preview.frame(camera: camera, mainLight: mainLight, effects: effects, world: world, objectID: objectID,
                          fkRotations: fk, faceValues: face, ikTargets: ik, animationElapsed: elapsed)
    }
}

/// An orbit camera turned `step` times around the default target.
private func frameReuseOrbit(_ step: Int) -> OrbitCamera {
    var camera = OrbitCamera()
    camera.yaw = Float(step) * 0.35; camera.pitch = 0.05 + Float(step % 5) * 0.04; camera.distance = 2.4 + Float(step % 3) * 0.2
    return camera
}

/// A weak reference, to see whether a preview or a texture was freed.
private final class Weak { weak var object: AnyObject?; init(_ object: AnyObject?) { self.object = object } }

private typealias Counts = [String: Int]
private func counts(_ store: ResourceStore) -> Counts {
    let s = store.statistics()
    return ["meshes": s.meshes, "textures": s.textures, "deformBuffers": s.deformBuffers, "hiddenBuffers": s.hiddenBuffers,
            "meshBufferBytes": s.meshBufferBytes, "deformBufferBytes": s.deformBufferBytes,
            "hiddenBufferBytes": s.hiddenBufferBytes, "retiring": s.retiring]
}

extension SourceStudioLiveTickFixtureTests {
    @Test(.enabled(if: SourceFixtureSupport.shouldRun(frameReuseVariables) && MTLCreateSystemDefaultDevice() != nil,
                   "Requires the Studio scenario scene and its import fixtures (\(frameReuseVariables.joined(separator: ", "))) and a Metal device"))
    func sourceStudioCharacterFramesReusedMatchFreshFrames() async throws {
        let run = try await liveTickOffPool { () throws -> (failures: [String], line: String, memory: String) in
            guard let device = MTLCreateSystemDefaultDevice() else { throw LiveTickFailure(description: "no Metal device") }
            let storeA = ResourceStore(device: device), storeB = ResourceStore(device: device)
            let reusing = try liveTickFixturePreviews(resources: storeA), fresh = try liveTickFixturePreviews(resources: storeB)
            for preview in fresh { preview.reusesFrames = false }
            var twins = zip(reusing, fresh).map { FrameReuseTwin(reusing: $0, fresh: $1) }
            var notes: [String] = []

            // 1. Live ticks: blink, neck and eye gaze on a circling camera,
            // dynamics, a held then moving FK edit and a seek, as the digest
            // test runs them. After each tick the refresh asks again with the
            // view orbited: the same frame, with the new camera.
            let expressionsA = try liveTickExpressions(reusing), expressionsB = try liveTickExpressions(fresh)
            var randomsA = reusing.indices.map { LiveTickRandom(state: UInt64($0) &* 7919 &+ 17) }, randomsB = randomsA
            var digestA = LiveTickDigest(), digestB = LiveTickDigest()
            for tick in 1...90 {
                if tick == 60 { for preview in reusing + fresh { preview.clearDynamicsStep(); preview.resetAnimationPlayback() } }
                for character in twins.indices {
                    try twins[character].step("tick \(tick), character \(character)", reuse: nil) { preview in
                        preview.reusesFrames
                            ? try liveTickStep(preview, character: character, tick: tick, expression: expressionsA[character], random: &randomsA[character], digest: &digestA)
                            : try liveTickStep(preview, character: character, tick: tick, expression: expressionsB[character], random: &randomsB[character], digest: &digestB)
                    }
                    let edit = LiveTickEdit.at(tick: tick, character: character, preview: twins[character].reusing)
                    let request = FrameReuseRequest(camera: frameReuseOrbit(tick), world: liveTickWorld(character: character),
                                                    objectID: UInt32(character + 1), fk: edit.fk, elapsed: Float(tick) / 30)
                    let frame = try twins[character].step("tick \(tick), character \(character), orbited refresh", reuse: true, request.frame)
                    if frame.camera != request.camera { twins[character].failures.append("tick \(tick), character \(character): the reused frame kept the old camera") }
                }
            }
            if digestA.finish() != digestB.finish() { notes.append("FAIL the live-tick digests differ") }

            // 2. One character's edits, each a fresh frame and then a reuse:
            // the FK drag, an IK edit, a face slider, the expression, wear,
            // world, object ID, a color edit, the double tooth and a resource
            // retirement. The look runtimes stay still: nothing else steps.
            var twin = twins[0]
            let body = try #require(twin.reusing.controller.targets.first(where: { $0.hasGuide && $0.bone.fkGroup == .body })?.bone.id)
            var request = FrameReuseRequest(world: liveTickWorld(character: 0), objectID: 1, elapsed: 3)
            try twin.step("settle", reuse: nil, request.frame)
            try twin.step("unchanged", reuse: true, request.frame)
            for (index, angle) in ([8, 9.5, 11, 11] as [Float]).enumerated() {
                request.fk = [body: Float3(angle, -angle * 0.5, 2)]
                try twin.step("FK drag \(index)", reuse: index == 3, request.frame)
            }
            request.camera = frameReuseOrbit(7)
            try twin.step("FK held, view orbited", reuse: true, request.frame)
            request.fk = [:]; request.ik = [3: SourceStudioIKEdit(position: Float3(0.05, 1.1, 0.12), rotationDegrees: Float3(10, 20, 30))]
            try twin.step("IK edit", reuse: false, request.frame)
            try twin.step("IK edit repeated", reuse: true, request.frame)
            request.ik = [:]
            var face = twin.reusing.savedFaceValues
            if !face.isEmpty {
                face[0] = min(1, face[0] + 0.1); request.face = face
                try twin.step("face slider", reuse: false, request.frame)
                try twin.step("face slider repeated", reuse: true, request.frame)
            } else { notes.append("no face values on character 0") }
            for preview in [twin.reusing, twin.fresh] {
                var state = preview.savedExpression; state.eyesPattern = state.eyesPattern == 0 ? 1 : 0; state.mouthPattern = 2
                try preview.setExpressionState(state.settled(from: preview.savedExpression))
            }
            try twin.step("expression", reuse: false, request.frame)
            try twin.step("expression repeated", reuse: true, request.frame)
            for preview in [twin.reusing, twin.fresh] {
                var clothes = preview.clothesState; clothes[0] = clothes[0] == 0 ? 3 : 0
                try preview.setWear(clothesState: clothes, showAccessory: nil, shoesType: nil)
            }
            try twin.step("wear", reuse: false, request.frame)
            try twin.step("wear repeated", reuse: true, request.frame)
            request.world = liveTickWorld(character: 3)
            try twin.step("world", reuse: false, request.frame)
            request.objectID = 9
            try twin.step("object ID", reuse: false, request.frame)
            try twin.step("object ID repeated", reuse: true, request.frame)
            if let field = twin.reusing.appliedColorFields.sorted().first {
                for preview in [twin.reusing, twin.fresh] { try preview.setColorEdits([field: Float4(0.2, 0.6, 0.3, 1)]) }
                try twin.step("color edit \(field)", reuse: false, request.frame)
                try twin.step("color edit repeated", reuse: true, request.frame)
            } else { notes.append("no bound color fields on character 0") }
            let tooth = !(twin.reusing.preview.doubleTooth ?? false)
            for preview in [twin.reusing, twin.fresh] { preview.preview.doubleTooth = tooth }
            try twin.step("double tooth \(tooth)", reuse: false, request.frame)
            try twin.step("double tooth repeated", reuse: true, request.frame)
            storeA.retire(deformKeys: [0xF0F0_0000_0000]); storeB.retire(deformKeys: [0xF0F0_0000_0000])
            try twin.step("resource retirement", reuse: false, request.frame)
            try twin.step("after the retirement", reuse: true, request.frame)
            twins[0] = twin

            // 3. Eyes on the camera while the view orbits: each step moves the
            // camera, the eye gaze follows its position in the character's
            // model space, and the frame is drawn with that camera.
            // Both twins of each character get the same face state until one
            // runs the eye look on the camera (eye pattern 1).
            var foundLook: Int?
            for index in twins.indices where foundLook == nil {
                for preview in [twins[index].reusing, twins[index].fresh] {
                    var state = preview.savedExpression; state.eyesLookPattern = 1
                    try preview.setExpressionState(state.settled(from: preview.savedExpression))
                }
                if twins[index].reusing.hasLiveEyeLook { foundLook = index }
            }
            let lookIndex = try #require(foundLook, "no character runs a live eye look on the camera")
            var look = twins[lookIndex]
            var lookRequest = FrameReuseRequest(world: liveTickWorld(character: lookIndex), objectID: UInt32(lookIndex + 1), elapsed: 3)
            try look.step("eyes on camera, settle", reuse: nil, lookRequest.frame)
            let inverseWorld = lookRequest.world.inverse
            var gazeMoves = 0
            for step in 0..<24 {
                lookRequest.camera = frameReuseOrbit(step)
                let eye = inverseWorld * SIMD4<Float>(lookRequest.camera.position, 1)
                let before = look.reusing.eyeLookRates.map { $0.horizontal.map(\.bitPattern) + [$0.vertical.bitPattern] }
                for preview in [look.reusing, look.fresh] {
                    _ = try preview.updateEyeLook(deltaTime: 1 / 30, cameraModelPosition: Float3(eye.x, eye.y, eye.z), animationElapsed: 3)
                }
                let after = look.reusing.eyeLookRates.map { $0.horizontal.map(\.bitPattern) + [$0.vertical.bitPattern] }
                if before != after { gazeMoves += 1 }
                let frame = try look.step("eyes on camera, orbit \(step)", reuse: before == after, lookRequest.frame)
                if frame.camera != lookRequest.camera { look.failures.append("eyes on camera, orbit \(step): the frame kept the old camera") }
            }
            if gazeMoves == 0 { notes.append("FAIL the eye gaze never moved during the orbit") }
            let lookType = look.reusing.eyeLookRates?.lookType.rawValue ?? "none"
            twins[lookIndex] = look

            // 4. Time alone: the automatic blink advances on its clock with
            // nothing else changed. A frame is fresh exactly when the rendered
            // blink rate changed. Blinking is turned on first, since a card or
            // face state may keep the eyes still.
            var blinkTwin = twins[1]
            for preview in [blinkTwin.reusing, blinkTwin.fresh] {
                var state = preview.savedExpression; state.blink = true
                try preview.setExpressionState(state.settled(from: preview.savedExpression))
            }
            let blinkRequest = FrameReuseRequest(world: liveTickWorld(character: 1), objectID: 2, elapsed: 3)
            try blinkTwin.step("blink settle", reuse: nil, blinkRequest.frame)
            var randomA = LiveTickRandom(state: 99), randomB = randomA, blinkChanges = 0
            for step in 1...240 {
                let elapsed = 3 + Float(step) / 30
                let changed = try blinkTwin.reusing.updateBlink(elapsed: elapsed, randomInteger: { randomA.integer($0, $1) }, randomFloat: { randomA.float($0, $1) })
                _ = try blinkTwin.fresh.updateBlink(elapsed: elapsed, randomInteger: { randomB.integer($0, $1) }, randomFloat: { randomB.float($0, $1) })
                if changed { blinkChanges += 1 }
                try blinkTwin.step("blink \(step)", reuse: !changed, blinkRequest.frame)
            }
            if blinkChanges == 0 { notes.append("FAIL the blink never changed in 8 s") }
            twins[1] = blinkTwin

            // The memory the cache holds: each reusing character's last frame.
            var itemCount = 0, morphWeights = 0, matrices = 0
            for (character, preview) in reusing.enumerated() {
                let frame = try FrameReuseRequest(world: liveTickWorld(character: character), objectID: UInt32(character + 1), elapsed: 3).frame(preview)
                itemCount += frame.items.count; morphWeights += frame.items.reduce(0) { $0 + $1.morphWeights.count }
                matrices += frame.skinSets.values.reduce(0) { $0 + $1.count }
            }
            let itemBytes = itemCount * MemoryLayout<RenderItem>.stride
            let morphBytes = morphWeights * MemoryLayout<(index: Int, weight: Float)>.stride
            let paletteBytes = matrices * MemoryLayout<float4x4>.stride
            let memory = "[frame-reuse-memory] characters=\(reusing.count) items=\(itemCount) itemBytes=\(itemBytes)"
                + " morphWeights=\(morphWeights) morphBytes=\(morphBytes) paletteMatrices=\(matrices) paletteBytes=\(paletteBytes)"
                + " totalKiB=\(String(format: "%.1f", Double(itemBytes + morphBytes + paletteBytes) / 1024))"

            let failures = twins.flatMap(\.failures) + notes.filter { $0.hasPrefix("FAIL") }
            let line = "[frame-reuse] reused=\(twins.reduce(0) { $0 + $1.reused }) built=\(twins.reduce(0) { $0 + $1.built })"
                + " eyeLook=character \(lookIndex) \(lookType) gazeMoves=\(gazeMoves) blinkChanges=\(blinkChanges)"
                + (notes.isEmpty ? "" : " notes=\(notes)")
            return (failures, line, memory)
        }
        print(run.line); print(run.memory)
        #expect(run.failures.isEmpty, "\(run.failures.prefix(20))")
    }

    /// The cache lives on the preview: dropping the characters frees their
    /// cached frames with them. The store ends where the twin store without
    /// reuse ends, and every texture a cached frame held whose owner gave it
    /// back is freed.
    @Test(.enabled(if: SourceFixtureSupport.shouldRun(frameReuseVariables) && MTLCreateSystemDefaultDevice() != nil,
                   "Requires the Studio scenario scene and its import fixtures (\(frameReuseVariables.joined(separator: ", "))) and a Metal device"))
    func sourceStudioCharacterFrameCacheIsFreedWithItsCharacter() async throws {
        let run = try await liveTickOffPool { () throws -> (failures: [String], line: String) in
            guard let device = MTLCreateSystemDefaultDevice() else { throw LiveTickFailure(description: "no Metal device") }
            var failures: [String] = [], reuses = 0, held = 0
            var results: [(base: Counts, loaded: Counts, after: Counts)] = []
            var weakPreviews: [Weak] = [], weakTextures: [(Weak, TextureHandle, ResourceStore)] = []
            for reuse in [true, false] {
                let store = ResourceStore(device: device)
                let base = counts(store)
                var loaded: Counts = [:]
                try autoreleasepool {
                    let previews = try liveTickFixturePreviews(resources: store)
                    for (character, preview) in previews.enumerated() {
                        preview.reusesFrames = reuse
                        let request = FrameReuseRequest(world: liveTickWorld(character: character), objectID: UInt32(character + 1), elapsed: 3)
                        let frame = try request.frame(preview)
                        _ = try request.frame(preview)
                        if preview.lastFrameReused { reuses += 1 }
                        if preview.lastFrameReused != reuse { failures.append("character \(character): reuse \(preview.lastFrameReused), expected \(reuse)") }
                        weakPreviews.append(Weak(preview))
                        if reuse {
                            for handle in Set(frame.items.flatMap(\.material.textureHandles)) {
                                if let texture = store.texture(handle) { weakTextures.append((Weak(texture as AnyObject), handle, store)); held += 1 }
                            }
                        }
                    }
                    loaded = counts(store)
                }
                results.append((base, loaded, counts(store)))
            }
            let alive = weakPreviews.filter { $0.object != nil }.count
            if alive != 0 { failures.append("\(alive) previews outlived their last reference") }
            // A texture the store no longer owns must be gone: only a cached frame could still hold it.
            let leaked = weakTextures.filter { $0.0.object != nil && $0.2.texture($0.1) == nil }.count
            if leaked != 0 { failures.append("\(leaked) released textures are still alive") }
            let storeOwned = weakTextures.filter { $0.2.texture($0.1) != nil }.count
            if results[0].after != results[1].after {
                failures.append("the store with reuse ends at \(results[0].after), without at \(results[1].after)")
            }
            if results[0].loaded != results[1].loaded {
                failures.append("the stores differ while loaded: \(results[0].loaded) vs \(results[1].loaded)")
            }
            for (index, result) in results.enumerated() where result.after["meshes"] != result.base["meshes"] || result.after["deformBuffers"] != result.base["deformBuffers"] {
                failures.append("store \(index): meshes or deform buffers not back to base: \(result.base) → \(result.after)")
            }
            let line = "[frame-reuse-lifetime] reuses=\(reuses) heldTextures=\(held) storeOwnedAfter=\(storeOwned)"
                + " base=\(results[0].base) loaded=\(results[0].loaded) after=\(results[0].after)"
            return (failures, line)
        }
        print(run.line)
        #expect(run.failures.isEmpty, "\(run.failures)")
    }
}
