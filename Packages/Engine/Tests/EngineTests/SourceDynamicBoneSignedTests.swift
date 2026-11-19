import Foundation
import Testing
import Metal
import simd
import Assets
import CoreMath
@testable import Scene
import Character
import Renderer
import Studio

// #406: DynamicBone over signed and zero local scales. The oracle
// (Tools/reverse/analysis/dynamics_reference.py --signed) is the independent
// reference; its fixture is synthetic.

private struct SignedDynamicsReference: Decodable {
    struct Node: Decodable {
        let sourceID: String
        let parent: Int?
        let translation: Float3, scale: Float3
        let rotation: Float4
        var rigNode: RigDefinition.Node {
            .init(name: sourceID, sourceID: sourceID, parent: parent, translation: translation,
                  rotation: simd_quatf(vector: rotation), scale: scale)
        }
    }
    struct Override: Decodable { let sourceID: String; let translation: Float3?; let rotation: Float4? }
    struct Frame: Decodable { let deltaTime: Float; let overrides: [Override] }
    struct Checkpoint: Decodable {
        let frame: Int
        let positions: [Float3], previousPositions: [Float3]
        let remainder: Float
        let lastStepCount: Int
        /// World matrices of particles 1..., column-major 3×4.
        let applied: [[Float]]
    }
    struct Scenario: Decodable {
        let name: String
        let nodes: [Node]
        let definition: SourceDynamicsDocument.Component
        let checkpoints: [Checkpoint]
        let frames: String
    }
    let schemaVersion: Int
    let checkpoints: [Int]
    let frameSets: [String: [Frame]]
    let scenarios: [Scenario]

    static func load() throws -> Self {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/reverse/fixtures/dynamics-signed-reference.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

/// One frame of a Swift run: the particle state and each particle's world.
private struct SignedFrame {
    let positions: [Float3], previousPositions: [Float3]
    let remainder: Float, lastStepCount: Int
    let worlds: [float4x4]
}

/// Steps `scenario` over its frame set. Every non-positive scale in the
/// fixture is a rest scale, so the rest pose records it; an override keeps
/// the node's rest scale and is written with its record, as a shape stage does.
private func runSigned(_ scenario: SignedDynamicsReference.Scenario, frames: [SignedDynamicsReference.Frame])
    throws -> (frames: [SignedFrame], inverseSafe: Int) {
    let rig = try RigDefinition(nodes: scenario.nodes.map(\.rigNode), skins: [])
    let ids = Dictionary(uniqueKeysWithValues: rig.nodes.enumerated().map { ($0.element.sourceID, $0.offset) })
    let particleNodes = try scenario.definition.particles.map { try #require(ids[$0.nodeID]) }
    var state = try SourceDynamicBone(rig: rig, definition: scenario.definition)
    var result: [SignedFrame] = []
    for frame in frames {
        var pose = rig.restPose
        for change in frame.overrides {
            let i = try #require(ids[change.sourceID]), node = rig.nodes[i]
            let t = change.translation ?? node.translation, r = change.rotation.map { simd_quatf(vector: $0) } ?? node.rotation
            pose.localMatrices[i] = Transform.trs(t, r, node.scale)
            pose.recordTRS(i, translation: t, rotation: r, scale: node.scale)
        }
        let output = try state.step(deltaTime: frame.deltaTime, rig: rig, pose: pose)
        let world = try rig.evaluate(output).worldMatrices
        result.append(SignedFrame(positions: state.positions, previousPositions: state.previousPositions,
                                  remainder: state.remainder, lastStepCount: state.lastStepCount,
                                  worlds: particleNodes.map { world[$0] }))
    }
    return (result, state.inverseSafePlacements)
}

private func finite(_ m: float4x4) -> Bool { (0..<4).allSatisfy { c in (0..<4).allSatisfy { m[c][$0].isFinite } } }

@Test func signedDynamicsMatchTheIndependentOracleOver200Frames() throws {
    let reference = try SignedDynamicsReference.load()
    #expect(reference.schemaVersion == 1 && reference.scenarios.count == 21)
    var maximumState: Float = 0, maximumWorld: Float = 0, collapsedPlacements = 0
    for scenario in reference.scenarios {
        let frames = try #require(reference.frameSets[scenario.frames])
        #expect(frames.count == 200)
        let run = try runSigned(scenario, frames: frames)
        for (index, frame) in run.frames.enumerated() {
            #expect(frame.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    && frame.worlds.allSatisfy(finite), "\(scenario.name) frame \(index) is not finite")
        }
        #expect(scenario.checkpoints.map(\.frame) == reference.checkpoints)
        for expected in scenario.checkpoints {
            let actual = run.frames[expected.frame], label = "\(scenario.name) frame \(expected.frame)"
            #expect(actual.lastStepCount == expected.lastStepCount, "\(label) steps")
            #expect(abs(actual.remainder - expected.remainder) < 1e-6, "\(label) remainder")
            for i in actual.positions.indices {
                let state = max(simd_reduce_max(abs(actual.positions[i] - expected.positions[i])),
                                simd_reduce_max(abs(actual.previousPositions[i] - expected.previousPositions[i])))
                maximumState = max(maximumState, state)
                #expect(state < 1e-5, "\(label) particle \(i) state differs by \(state)")
            }
            for (k, applied) in expected.applied.enumerated() {
                let world = actual.worlds[k + 1]
                var error: Float = 0
                for c in 0..<4 { for r in 0..<3 { error = max(error, abs(world[c][r] - applied[c * 3 + r])) } }
                maximumWorld = max(maximumWorld, error)
                #expect(error < 1e-5, "\(label) particle \(k + 1) applied world differs by \(error)")
            }
        }
        // A collapsed particle ancestor is the only way into InverseSafe.
        let collapsedAncestor = scenario.name == "base-zero-y" || scenario.name == "middle-zero-z"
        #expect((run.inverseSafe > 0) == collapsedAncestor, "\(scenario.name): \(run.inverseSafe) InverseSafe placements")
        collapsedPlacements += run.inverseSafe
    }
    print("[signed dynamics] oracle: max state \(maximumState), applied world \(maximumWorld), InverseSafe placements \(collapsedPlacements)")
}

/// A reflection at the owner or its parent, with the force mirrored, owner
/// motion in the mirror plane, gravity in the plane and the root turning
/// about the plane's normal, is exactly symmetric in the source (the
/// oracle's test asserts it there): every frame mirrors the positive run,
/// particle state and applied worlds alike. Illusion's compensation is what
/// keeps the applied rotations symmetric.
@Test func signedDynamicsMirrorAPositiveChainReflectedAtTheOwnerOrItsParent() throws {
    let reference = try SignedDynamicsReference.load()
    func scenario(_ name: String) throws -> SignedDynamicsReference.Scenario {
        try #require(reference.scenarios.first { $0.name == name })
    }
    let frames = try #require(reference.frameSets["planar"])
    let positive = try runSigned(scenario("mirror-pair-positive"), frames: frames).frames
    // The owner reflects across world x = 0.05 (its own origin), the base across x = 0.
    for (name, plane) in [("mirror-pair-owner-x", Float(0.05)), ("mirror-pair-base-x", Float(0))] {
        let mirrored = try runSigned(scenario(name), frames: frames).frames
        func mirror(_ p: Float3) -> Float3 { Float3(2 * plane - p.x, p.y, p.z) }
        var maximum: Float = 0
        for (a, b) in zip(positive, mirrored) {
            for i in a.positions.indices {
                maximum = max(maximum, simd_reduce_max(abs(mirror(a.positions[i]) - b.positions[i])),
                              simd_reduce_max(abs(mirror(a.previousPositions[i]) - b.previousPositions[i])))
            }
            for (w, m) in zip(a.worlds, b.worlds) {
                // Reflection · world: the basis rows' x flips, the origin mirrors.
                for c in 0..<3 { maximum = max(maximum, abs(-w[c].x - m[c].x), abs(w[c].y - m[c].y), abs(w[c].z - m[c].z)) }
                maximum = max(maximum, simd_reduce_max(abs(mirror(w.translation) - m.translation)))
            }
        }
        #expect(maximum < 1e-5, "\(name) departs from the mirrored positive run by \(maximum)")
        print("[signed dynamics] \(name): max mirror departure \(maximum)")
    }
}

/// One collapsed axis and no record: the rotation is rebuilt from the two
/// axes that remain, completed in the cyclic order that gives det +1.
@Test func signedDynamicsRebuildsARightHandedBasisForEachCollapsedAxis() throws {
    let rotation = simd_quatf(angle: 0.7, axis: normalize(Float3(0.3, -0.5, 0.8))), r = float3x3(rotation)
    for k in 0..<3 {
        var scale = Float3(1.3, 0.7, 2.1); scale[k] = 0
        let m = Transform.trs(Float3(0.1, -0.2, 0.3), rotation, scale)
        let basis = try #require(SourceDynamicBone.collapsedAxisBasis(m, scale: m.scaleFactors, axis: k))
        #expect(abs(simd_determinant(basis) - 1) < 1e-5, "axis \(k): det \(simd_determinant(basis))")
        for c in 0..<3 { #expect(simd_length(basis[c] - r[c]) < 1e-5, "axis \(k) column \(c)") }
        let rebuilt = Transform.trs(m.translation, simd_quatf(basis).normalized, m.scaleFactors)
        for c in 0..<4 { #expect(simd_length(rebuilt[c] - m[c]) < 1e-5, "axis \(k) rebuild column \(c)") }
        // Shear between the remaining axes is not a rotation.
        var sheared = m; sheared[(k + 1) % 3] += sheared[(k + 2) % 3] * 0.3
        #expect(SourceDynamicBone.collapsedAxisBasis(sheared, scale: sheared.scaleFactors, axis: k) == nil)
    }
}

/// The same collapsed bone with and without its record simulates alike: the
/// rebuilt rotation is the writer's when the remaining axes are positive.
@Test func signedDynamicsCollapsedBoneWithoutARecordMatchesTheRecordedOne() throws {
    let reference = try SignedDynamicsReference.load()
    let scenario = try #require(reference.scenarios.first { $0.name == "middle-zero-z" })
    let frames = try #require(reference.frameSets[scenario.frames])
    let recorded = try runSigned(scenario, frames: frames).frames
    // The rig's rest scale is positive; the pose carries the zero scale as a matrix only.
    var nodes = scenario.nodes.map(\.rigNode)
    let middle = try #require(nodes.firstIndex { $0.sourceID == "middle" })
    let zero = nodes[middle].scale
    nodes[middle] = .init(name: "middle", sourceID: "middle", parent: nodes[middle].parent, translation: nodes[middle].translation,
                          rotation: nodes[middle].rotation, scale: Float3(1.1, 0.9, 1.2))
    let rig = try RigDefinition(nodes: nodes, skins: [])
    #expect(rig.restSignedTRS == nil)
    let ids = Dictionary(uniqueKeysWithValues: rig.nodes.enumerated().map { ($0.element.sourceID, $0.offset) })
    func pose(_ frame: SignedDynamicsReference.Frame?) throws -> RigPose {
        var pose = rig.restPose
        pose.localMatrices[middle] = Transform.trs(rig.nodes[middle].translation, rig.nodes[middle].rotation, zero)
        for change in frame?.overrides ?? [] {
            let i = try #require(ids[change.sourceID]), node = rig.nodes[i]
            pose.localMatrices[i] = Transform.trs(change.translation ?? node.translation,
                change.rotation.map { simd_quatf(vector: $0) } ?? node.rotation, node.scale)
        }
        #expect(pose.signedTRS == nil)
        return pose
    }
    var state = try SourceDynamicBone(rig: rig, pose: pose(nil), definition: scenario.definition)
    var maximum: Float = 0
    for (frame, expected) in zip(frames, recorded) {
        _ = try state.step(deltaTime: frame.deltaTime, rig: rig, pose: pose(frame))
        for i in state.positions.indices { maximum = max(maximum, simd_reduce_max(abs(state.positions[i] - expected.positions[i]))) }
    }
    #expect(maximum < 1e-5, "unrecorded zero departs by \(maximum)")
    #expect(state.inverseSafePlacements > 0)
}

/// The table is nil, with nothing allocated, unless a non-positive scale is
/// written; a record counts only while it describes its node's matrix.
@Test func signedTRSTableIsNilForPositiveWritesAndTracksSignedOnes() throws {
    let rig = try RigDefinition(nodes: [.init(name: "a", sourceID: "a", parent: nil),
                                        .init(name: "b", sourceID: "b", parent: 0, translation: Float3(0, -1, 0))], skins: [])
    #expect(rig.restSignedTRS == nil && rig.restPose.signedTRS == nil)
    var pose = rig.restPose
    let t = Float3(0.1, 0.2, 0.3), r = simd_quatf(angle: 0.5, axis: Float3(0, 1, 0))
    pose.localMatrices[1] = Transform.trs(t, r, Float3(1, 2, 3)); pose.recordTRS(1, translation: t, rotation: r, scale: Float3(1, 2, 3))
    #expect(pose.signedTRS == nil)
    for scale in [Float3(-1, 2, 3), Float3(1, 0, 3), Float3(1, 2, -0.0)] {
        pose.localMatrices[1] = Transform.trs(t, r, scale); pose.recordTRS(1, translation: t, rotation: r, scale: scale)
        #expect(pose.validSignedTRS(1)?.scale == scale, "\(scale)")
    }
    // Another writer replaces the matrix: the record no longer counts.
    pose.localMatrices[1].columns.3.x += 0.25
    #expect(pose.signedTRS?[1] != nil && pose.validSignedTRS(1) == nil)
    // A positive write through the stage drops the record and the table.
    pose.localMatrices[1] = Transform.trs(t, r, .one); pose.recordTRS(1, translation: t, rotation: r, scale: .one)
    #expect(pose.signedTRS == nil)
    // A positive chain's step leaves the output without a table.
    let definition = SourceDynamicsDocument.Component(sourceID: "s", ownerID: "a", particles: [.init(nodeID: "a", parent: nil), .init(nodeID: "b", parent: 0)])
    var state = try SourceDynamicBone(rig: rig, definition: definition)
    #expect(try state.step(deltaTime: 1 / 60, rig: rig, pose: rig.restPose).signedTRS == nil)
    // A rest scale at or below zero is recorded by the rig itself.
    let signed = try RigDefinition(nodes: [.init(name: "a", sourceID: "a", parent: nil, scale: Float3(1, -1, 1))], skins: [])
    #expect(signed.restPose.validSignedTRS(0)?.scale == Float3(1, -1, 1))
}

/// The body stage records the scale it writes through the same Transform.trs.
@Test func signedTRSBodyShapeStageRecordsANegativeScale() throws {
    let names = Array(SourceBodyShapePose.destinationNames.prefix(5))
    let rig = try RigDefinition(nodes: names.enumerated().map { index, name in
        RigDefinition.Node(name: name, sourceID: String(index), parent: nil, translation: Float3(10, 20, 30),
                           rotation: simd_quatf(angle: 0.4, axis: Float3(0, 1, 0)), scale: Float3(2, 3, 4))
    }, skins: [])
    var state: [String: SourceShapeTransform] = [
        "cf_a_height": .init(scale: Float3(0.8, 0.9, 1)), "cf_a_height_aid": .init(scale: Float3(1.2, 1.1, 1.3)),
        "cf_a_head": .init(position: Float3(99, 0.03, 99), scale: Float3(0.7, 0.8, 0.9)),
        "cf_a_neck": .init(position: Float3(99, 99, 0.04), scale: Float3(0.6, 99, 0.5))]
    #expect(try SourceBodyShapePose.make(rig: rig, state: state).signedTRS == nil)
    state["cf_a_height"] = .init(scale: Float3(-0.8, 0.9, 1))
    let pose = try SourceBodyShapePose.make(rig: rig, state: state)
    let record = try #require(pose.validSignedTRS(0))
    #expect(record.scale.x < 0 && record.scale.y > 0 && record.scale.z > 0)
}

/// Studio: an extended face rate that reflects FaceUp_ty keeps the hair
/// DynamicBone bound and stepping. The face stage's record gives the hair's
/// ancestors their rotation; without it the same matrices are refused.
@Test func signedDynamicsStudioHairStaysBoundUnderANegativeFaceScale() throws {
    let fixture = try CollapsedHairFixture(faceUpScale: Float3(-0.8, 1, 1))
    #expect(fixture.pose.validSignedTRS(fixture.faceUp)?.scale.x == -0.8)
    let ids = fixture.rig.nodes.map(\.sourceID)
    let definition = SourceDynamicsDocument.Component(sourceID: "hair", ownerID: ids[fixture.mesh], updateRate: 60,
        gravity: Float3(0, -0.01, 0), force: Float3(0.002, 0, 0), particles: [
            .init(nodeID: ids[fixture.bones[0]], parent: nil),
            .init(nodeID: ids[fixture.bones[1]], parent: 0, damping: 0.1, elasticity: 0.1, stiffness: 0.2, inert: 0.3, radius: 0.01)])
    let binding = SourceStudioDynamics.Binding(definition: definition, group: .hair)
    var dynamics = try SourceStudioDynamics(rig: fixture.rig, initializationPose: fixture.pose, bindings: [binding])
    var moved = false
    for frame in 1...200 {
        let output = try dynamics.evaluate(time: Float(frame) / 60, rig: fixture.rig, upstream: fixture.pose,
                                           enableFK: false, activeFK: [Bool](repeating: false, count: 7))
        #expect(output.localMatrices.allSatisfy(finite), "frame \(frame)")
        moved = moved || output.localMatrices[fixture.bones[0]] != fixture.pose.localMatrices[fixture.bones[0]]
    }
    #expect(moved)
    var unrecorded = fixture.pose; unrecorded.signedTRS = nil
    do {
        _ = try SourceStudioDynamics(rig: fixture.rig, initializationPose: unrecorded, bindings: [binding])
        Issue.record("An unrecorded negative face scale must be refused.")
    } catch { #expect("\(error)".contains("#406"), "\(error)") }
}

/// ABMX runs last in SourceRigPreview.pose and writes a scale-only record as
/// a column multiply, with no signed record (decision B). A negative result
/// on a dynamics ancestor is refused naming ABMX and #406; a zero on one axis
/// is rebuilt and simulates.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func signedDynamicsABMXNonPositiveAncestorThroughThePreviewOrder() throws {
    let rig = try RigDefinition(nodes: [
        .init(name: "mesh", sourceID: "mesh", parent: nil),
        .init(name: "hair_root", sourceID: "hair-root", parent: nil, translation: Float3(0, 1.5, 0), scale: Float3(1.1, 0.9, 1.2)),
        .init(name: "hair_a", sourceID: "hair-a", parent: 1, translation: Float3(0.02, 0.05, 0),
              rotation: simd_quatf(angle: 0.3, axis: Float3(0, 0, 1))),
        .init(name: "hair_b", sourceID: "hair-b", parent: 2, translation: Float3(0, -0.2, 0.01))],
        skins: [.init(name: "skin", meshNode: 0, joints: [3], inverseBindMatrices: [matrix_identity_float4x4])])
    let mesh = MeshData(name: "hair", positions: [.zero, Float3(1, 0, 0), Float3(0, 1, 0)],
                        normals: [Float3](repeating: Float3(0, 0, 1), count: 3), joints: [SIMD4<UInt16>](repeating: .zero, count: 3),
                        weights: [Float4](repeating: Float4(1, 0, 0, 0), count: 3), indices: [0, 1, 2])
    let source = SourceRig(sourcePrefab: "abmx-dynamics", rig: rig, parts: [.init(mesh: mesh, node: 0, skin: 0, rendererEnabled: true)],
                           morphChannelCount: 0)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let preview = try SourceRigPreview(source: source, contract: nil, resources: resources)
    func abmx(_ scale: [Float]) throws -> SourceBoneModifiers {
        let document: [String: Any] = [
            "schemaVersion": 1, "kind": "ikkoku-source-bone-modifiers", "coordinateSpace": "unity-left-handed-y-up",
            "angleUnit": "degrees", "mode": "staticBaseline",
            "source": ["pluginGUID": "KKABMX.Core", "dataGUID": "KKABMPlugin.ABMData", "pluginVersion": "5.4",
                       "dataKind": "card", "dataVersion": 2, "assemblySHA256": String(repeating: "a", count: 64),
                       "payloadSHA256": String(repeating: "b", count: 64)],
            "modifiers": [["boneName": "hair_root", "boneLocation": 1, "coordinateModifiers": [
                ["scaleModifier": scale, "lengthModifier": 1, "positionModifier": [0, 0, 0], "rotationModifier": [0, 0, 0]]]]]]
        return try SourceBoneModifiers.decode(JSONSerialization.data(withJSONObject: document))
    }
    let definition = SourceDynamicsDocument.Component(sourceID: "hair", ownerID: "hair-root", gravity: Float3(0, -0.01, 0), particles: [
        .init(nodeID: "hair-a", parent: nil), .init(nodeID: "hair-b", parent: 0, damping: 0.1, stiffness: 0.2, inert: 0.3)])

    let negative = try preview.pose(boneModifiers: abmx([-1, 1, 1]))
    #expect(negative.signedTRS == nil)
    do {
        _ = try SourceDynamicBone(rig: rig, pose: negative, definition: definition)
        Issue.record("An ABMX-negative dynamics ancestor must be refused.")
    } catch { #expect("\(error)".contains("ABMX") && "\(error)".contains("#406"), "\(error)") }

    let zero = try preview.pose(boneModifiers: abmx([1, 0, 1]))
    var state = try SourceDynamicBone(rig: rig, pose: zero, definition: definition)
    for _ in 0..<200 {
        let output = try state.step(deltaTime: 1 / 60, rig: rig, pose: zero)
        #expect(output.localMatrices.allSatisfy(finite) && state.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
    #expect(state.lastStepCount == 1 && state.inverseSafePlacements > 0)
}
