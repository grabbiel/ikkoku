import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character

private func dynamicsRig() throws -> RigDefinition {
    try RigDefinition(nodes: [
        .init(name: "owner", sourceID: "owner", parent: nil),
        .init(name: "root", sourceID: "root", parent: 0),
        .init(name: "tip", sourceID: "tip", parent: 1, translation: Float3(0, -1, 0))
    ], skins: [])
}
private func dynamicsConfig(rate: Float = 60, force: Float3 = .zero, gravity: Float3 = .zero,
                            damping: Float = 0, stiffness: Float = 0, inert: Float = 0,
                            freeze: Int = 0) -> SourceDynamicsDocument.Component {
    .init(sourceID: "synthetic", ownerID: "owner", updateRate: rate, gravity: gravity, force: force,
          freezeAxis: freeze, particles: [.init(nodeID: "root", parent: nil),
            .init(nodeID: "tip", parent: 0, damping: damping, elasticity: 0, stiffness: stiffness, inert: inert)])
}
private func close(_ a: Float3, _ b: Float3, _ epsilon: Float = 1e-5) -> Bool { length(a - b) < epsilon }

@Test func sourceDynamicsUsesPerStepForceAndPreservesLength() throws {
    let rig = try dynamicsRig(), config = dynamicsConfig(force: Float3(0.1, 0, 0))
    var state = try SourceDynamicBone(rig: rig, definition: config)
    let pose = try state.step(deltaTime: 1 / 60, rig: rig, pose: rig.restPose)
    let expected = normalize(Float3(0.1, -1, 0))
    #expect(close(state.positions[1], expected))
    #expect(close(try rig.evaluate(pose).worldMatrices[2].translation, expected))
    #expect(abs(length(state.positions[1] - state.positions[0]) - 1) < 1e-6)
    #expect(state.lastStepCount == 1)
}

@Test func sourceDynamicsCapsCatchUpAndClearsExcessTime() throws {
    let rig = try dynamicsRig(), config = dynamicsConfig(force: Float3(0.1, 0, 0))
    var big = try SourceDynamicBone(rig: rig, definition: config), three = big
    _ = try big.step(deltaTime: 10, rig: rig, pose: rig.restPose)
    for _ in 0..<3 { _ = try three.step(deltaTime: 1 / 60, rig: rig, pose: rig.restPose) }
    #expect(big.lastStepCount == 3 && big.remainder == 0)
    #expect(close(big.positions[1], three.positions[1]))
    _ = try big.step(deltaTime: 0, rig: rig, pose: rig.restPose)
    #expect(big.lastStepCount == 0)
}

@Test func sourceDynamicsZeroRateRunsOnceEvenWithZeroDelta() throws {
    let rig = try dynamicsRig()
    var state = try SourceDynamicBone(rig: rig, definition: dynamicsConfig(rate: 0, force: Float3(0.1, 0, 0)))
    _ = try state.step(deltaTime: 0, rig: rig, pose: rig.restPose)
    #expect(state.lastStepCount == 1)
    #expect(close(state.positions[1], normalize(Float3(0.1, -1, 0))))
}

@Test func sourceDynamicsSkipMovesPreviousPositionWithOwner() throws {
    let rig = try dynamicsRig()
    var state = try SourceDynamicBone(rig: rig, definition: dynamicsConfig(inert: 0))
    var pose = rig.restPose; pose.localMatrices[0][3].x = 0.25
    _ = try state.step(deltaTime: 0, rig: rig, pose: pose)
    #expect(close(state.positions[1], Float3(0.25, -1, 0)))
    #expect(close(state.previousPositions[1], Float3(0.25, -1, 0)))
    #expect(close(state.positions[0], Float3(0.25, 0, 0)))
}

@Test func sourceDynamicsGravityCancelsRestDirectionAndFreezeProjects() throws {
    let rig = try dynamicsRig()
    var gravity = try SourceDynamicBone(rig: rig, definition: dynamicsConfig(gravity: Float3(0, -0.1, 0)))
    _ = try gravity.step(deltaTime: 1 / 60, rig: rig, pose: rig.restPose)
    #expect(close(gravity.positions[1], Float3(0, -1, 0)))
    var frozen = try SourceDynamicBone(rig: rig, definition: dynamicsConfig(force: Float3(0.1, 0, 0), freeze: 1))
    _ = try frozen.step(deltaTime: 1 / 60, rig: rig, pose: rig.restPose)
    #expect(close(frozen.positions[1], Float3(0, -1, 0)))
}

@Test func sourceDynamicsWeightResetRetainsClockAndScale() throws {
    let rig = try dynamicsRig()
    var state = try SourceDynamicBone(rig: rig, definition: dynamicsConfig(force: Float3(0.1, 0, 0)))
    let moved = try state.step(deltaTime: 1 / 80, rig: rig, pose: rig.restPose)
    let remainder = state.remainder
    let reset = try state.setWeight(0, rig: rig, pose: moved)
    #expect(close(reset.localMatrices[2].translation, Float3(0, -1, 0)))
    _ = try state.setWeight(1, rig: rig, pose: reset)
    #expect(state.remainder == remainder)
    #expect(close(state.previousPositions[1], Float3(0, -1, 0)))
}

@Test func sourceDynamicsCollidersPreserveSourceRadiusAndHeightRules() throws {
    let sphere = SourceDynamicsDocument.Collider(nodeID: "unused", radius: 1)
    #expect(close(try SourceDynamicBone.collide(position: Float3(0.5, 0, 0), particleRadius: 0.2,
        collider: sphere, matrix: matrix_identity_float4x4), Float3(1.2, 0, 0)))
    var inside = sphere; inside.bound = 1
    #expect(close(try SourceDynamicBone.collide(position: Float3(2, 0, 0), particleRadius: 0.2,
        collider: inside, matrix: matrix_identity_float4x4), Float3(1.2, 0, 0)))
    #expect(close(try SourceDynamicBone.collide(position: .zero, particleRadius: 0,
        collider: sphere, matrix: matrix_identity_float4x4), .zero))
    let capsule = SourceDynamicsDocument.Collider(nodeID: "unused", radius: 0.5, height: 2, direction: 1)
    // Source endpoints are +/- .75, not +/- .5.
    #expect(close(try SourceDynamicBone.collide(position: Float3(0, 1, 0), particleRadius: 0,
        collider: capsule, matrix: matrix_identity_float4x4), Float3(0, 1.25, 0)))
    let scaled = Transform.trs(.zero, .identity, Float3(2, 3, 4))
    #expect(close(try SourceDynamicBone.collide(position: Float3(0.5, 0, 0), particleRadius: 0,
        collider: sphere, matrix: scaled), Float3(4, 0, 0)))
}

@Test func sourceDynamicsFailureDoesNotCommitParticlesOrTime() throws {
    let rig = try dynamicsRig()
    var state = try SourceDynamicBone(rig: rig, definition: dynamicsConfig())
    let positions = state.positions
    #expect(throws: (any Error).self) { try state.step(deltaTime: -.infinity, rig: rig, pose: rig.restPose) }
    var bad = rig.restPose; bad.localMatrices[2][0].y = 0.2
    #expect(throws: (any Error).self) { try state.step(deltaTime: 1, rig: rig, pose: bad) }
    #expect(state.positions == positions && state.remainder == 0)
    var config = dynamicsConfig(); config.particles[1].parent = 1
    #expect(throws: (any Error).self) { try SourceDynamicBone(rig: rig, definition: config) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_DYNAMICS", "IKKOKU_SOURCE_AVATAR"]),
               "Requires IKKOKU_SOURCE_DYNAMICS, IKKOKU_SOURCE_AVATAR"))
func sourceDynamicsLocalOriginalHairRigWhenRequested() throws {
    let file = try SourceFixtureSupport.require("IKKOKU_SOURCE_DYNAMICS")
    let avatar = try SourceFixtureSupport.require("IKKOKU_SOURCE_AVATAR")
    let source = try SourceRig.loadModel(url: URL(fileURLWithPath: avatar))
    let document = try SourceDynamicsDocument.load(url: URL(fileURLWithPath: file))
    #expect(document.components.count == 5)
    var states = try document.components.map { try SourceDynamicBone(rig: source.rig, definition: $0) }
    for step in 0..<20 {
        var pose = source.rig.restPose
        pose.localMatrices[0][3].x = sin(Float(step) * 0.1) * 0.03
        for i in states.indices { pose = try states[i].step(deltaTime: 1 / 30, rig: source.rig, pose: pose) }
        let evaluated = try source.rig.evaluate(pose)
        #expect(evaluated.worldMatrices.count == 774)
    }
    #expect(states.allSatisfy { $0.lastStepCount == 2 })
}

@Test func sourceDynamicsIgnoresUnrelatedMirroredAccessoryButRejectsReflectedAncestors() throws {
    let original = try dynamicsRig()
    let rig = try RigDefinition(nodes:original.nodes + [.init(name:"mirrored accessory",sourceID:"accessory",parent:0,scale:Float3(-1,-1,1))],skins:[])
    var solver = try SourceDynamicBone(rig:rig,definition:dynamicsConfig(force:Float3(0.1,0,0)))
    let pose = try solver.step(deltaTime:1/60,rig:rig,pose:rig.restPose)
    #expect(pose.localMatrices[3] == rig.restPose.localMatrices[3])
    var invalid = rig.restPose; invalid.localMatrices[0] = Transform.trs(.zero,.identity,Float3(-1,1,1))
    #expect(throws:(any Error).self) { try SourceDynamicBone(rig:rig,pose:invalid,definition:dynamicsConfig()) }
}
