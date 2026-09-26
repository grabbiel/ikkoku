import Foundation
import CryptoKit
import Testing
import simd
import CoreMath
import Scene
import Character
import Studio

private struct DynamicsReferenceFixture: Decodable {
    struct Evidence: Decodable { let path: String, sha256: String }
    struct Node: Decodable {
        let sourceID: String
        let parent: Int?
        let translation: Float3, scale: Float3
        let rotation: Float4
        var matrix: float4x4 { Transform.trs(translation, simd_quatf(vector: rotation), scale) }
        var rigNode: RigDefinition.Node {
            .init(name: sourceID, sourceID: sourceID, parent: parent, translation: translation,
                  rotation: simd_quatf(vector: rotation), scale: scale)
        }
    }
    struct Override: Decodable {
        let sourceID: String
        let translation: Float3?
        let rotation: Float4?
        let scale: Float3?
    }
    struct Snapshot: Decodable {
        let positions: [Float3], previousPositions: [Float3]
        let remainder: Float
        let lastStepCount: Int
    }
    struct Frame: Decodable {
        let deltaTime: Float
        let overrides: [Override]
        let weight: Float?
        let expected: Snapshot
    }
    struct Scenario: Decodable {
        let name: String
        let nodes: [Node]
        let definition: SourceDynamicsDocument.Component
        let frames: [Frame]
    }
    struct Collision: Decodable {
        let name: String
        let collider: SourceDynamicsDocument.Collider
        let transform: Node
        let position: Float3, expected: Float3
        let particleRadius: Float
    }
    let schemaVersion: Int
    let scenarios: [Scenario]
    let collisions: [Collision]
    let sourceAvatar: String?
    let evidence: [Evidence]?
    let managedAndBundleEvidence: [Evidence]?
}

private var dynamicsRepositoryURL: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func checkDynamicsReference(_ fixture: DynamicsReferenceFixture, original: Bool) throws {
    #expect(fixture.schemaVersion == 1)
    if original {
        let evidence = try #require(fixture.evidence)
        let sourceEvidence = try #require(fixture.managedAndBundleEvidence)
        for entry in evidence + sourceEvidence {
            let url = entry.path.hasPrefix("/") ? URL(fileURLWithPath: entry.path) : dynamicsRepositoryURL.appendingPathComponent(entry.path)
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            try #require(hash == entry.sha256, "Stale dynamics reference input: \(entry.path)")
        }
    }
    let sourceRig = try original ? fixture.sourceAvatar.map { try SourceRig.loadModel(url: URL(fileURLWithPath: $0)).rig } : nil
    let tolerance: Float = original ? 4e-5 : 1e-5
    var maximumStateError: Float = 0, maximumWorldError: Float = 0, maximumCollisionError: Float = 0
    for scenario in fixture.scenarios {
        let rig = try sourceRig ?? RigDefinition(nodes: scenario.nodes.map(\.rigNode), skins: [])
        let ids = Dictionary(uniqueKeysWithValues: rig.nodes.enumerated().map { ($0.element.sourceID, $0.offset) })
        var state = try SourceDynamicBone(rig: rig, definition: scenario.definition)
        for (frameIndex, frame) in scenario.frames.enumerated() {
            var pose = rig.restPose
            for change in frame.overrides {
                let i = try #require(ids[change.sourceID])
                let node = rig.nodes[i]
                pose.localMatrices[i] = Transform.trs(change.translation ?? node.translation,
                    change.rotation.map { simd_quatf(vector: $0) } ?? node.rotation, change.scale ?? node.scale)
            }
            if let weight = frame.weight { pose = try state.setWeight(weight, rig: rig, pose: pose) }
            let output = try state.step(deltaTime: frame.deltaTime, rig: rig, pose: pose)
            let world = try rig.evaluate(output).worldMatrices
            #expect(state.lastStepCount == frame.expected.lastStepCount, "\(scenario.name) frame \(frameIndex)")
            #expect(abs(state.remainder - frame.expected.remainder) < 1e-7, "\(scenario.name) frame \(frameIndex)")
            #expect(state.positions.count == frame.expected.positions.count)
            for i in state.positions.indices {
                let actualWorld = world[try #require(ids[scenario.definition.particles[i].nodeID])].translation
                for axis in 0..<3 {
                    maximumStateError = max(maximumStateError,
                        abs(state.positions[i][axis] - frame.expected.positions[i][axis]),
                        abs(state.previousPositions[i][axis] - frame.expected.previousPositions[i][axis]))
                    maximumWorldError = max(maximumWorldError, abs(actualWorld[axis] - frame.expected.positions[i][axis]))
                    #expect(abs(state.positions[i][axis] - frame.expected.positions[i][axis]) < tolerance,
                            "\(scenario.name) frame \(frameIndex) particle \(i) axis \(axis) position")
                    #expect(abs(state.previousPositions[i][axis] - frame.expected.previousPositions[i][axis]) < tolerance,
                            "\(scenario.name) frame \(frameIndex) particle \(i) axis \(axis) previous")
                    #expect(abs(actualWorld[axis] - frame.expected.positions[i][axis]) < tolerance,
                            "\(scenario.name) frame \(frameIndex) particle \(i) axis \(axis) applied world position")
                }
            }
        }
    }
    for test in fixture.collisions {
        let result = try SourceDynamicBone.collide(position: test.position, particleRadius: test.particleRadius,
            collider: test.collider, matrix: test.transform.matrix)
        maximumCollisionError = max(maximumCollisionError, simd_length(result - test.expected))
        #expect(simd_length(result - test.expected) < 2e-6, "Collider branch \(test.name)")
    }
    print("Dynamics oracle \(original ? "original" : "synthetic"): max state \(maximumStateError), world \(maximumWorldError), collision \(maximumCollisionError)")
}

@Test func sourceDynamicsMatchesIndependentFloat32Oracle() throws {
    let url = dynamicsRepositoryURL.appendingPathComponent("Tools/reverse/fixtures/dynamics-reference.json")
    let fixture = try JSONDecoder().decode(DynamicsReferenceFixture.self, from: Data(contentsOf: url))
    #expect(fixture.scenarios.count == 5 && fixture.collisions.count == 252)
    try checkDynamicsReference(fixture, original: false)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_DYNAMICS_REFERENCE"]),
               "Requires IKKOKU_SOURCE_DYNAMICS_REFERENCE"))
func sourceDynamicsOriginalHairMatchesIndependentOracleWhenRequested() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_SOURCE_DYNAMICS_REFERENCE")
    let fixture = try JSONDecoder().decode(DynamicsReferenceFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(fixture.sourceAvatar != nil && fixture.scenarios.count == 5)
    #expect(fixture.scenarios.reduce(0) { $0 + $1.definition.particles.count } == 20)
    #expect(fixture.scenarios.allSatisfy { $0.definition.colliders.count == 24 && $0.frames.count == 20 })
    try checkDynamicsReference(fixture, original: true)
}

@Test func sourceDynamicsCapsuleAxisDoesNotAcquireReassociatedRadialOffset() throws {
    let collider = SourceDynamicsDocument.Collider(nodeID: "unused", center: Float3(0, 0.1, 0),
        radius: 0.35, height: 1.6, direction: 1)
    let position = collider.center
    let result = try SourceDynamicBone.collide(position: position, particleRadius: 0,
        collider: collider, matrix: matrix_identity_float4x4)
    // Source subtracts segment * projection from offset, producing exactly zero.
    // Rebuilding a closest point first introduces an epsilon; normalizing it
    // then moves the particle a full radius along the capsule's own axis.
    #expect(result == position)
}


@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SOURCE_DYNAMICS_REFERENCE"]),
               "Requires IKKOKU_SOURCE_DYNAMICS_REFERENCE"))
func sourceStudioDynamicsOriginalPostPoseMatchesIndependentOracleWhenRequested() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_SOURCE_DYNAMICS_REFERENCE")
    let fixture = try JSONDecoder().decode(DynamicsReferenceFixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
    let rig = try SourceRig.loadModel(url:URL(fileURLWithPath:try #require(fixture.sourceAvatar))).rig
    let ids = Dictionary(uniqueKeysWithValues:rig.nodes.enumerated().map { ($0.element.sourceID,$0.offset) })
    var frameCount = 0, maximum:Float = 0
    for scenario in fixture.scenarios where scenario.frames.allSatisfy({ $0.weight == nil }) {
        var session = try SourceStudioDynamics(rig:rig,initializationPose:rig.restPose,bindings:[.init(definition:scenario.definition,group:.hair)])
        var time:Float = 0
        for frame in scenario.frames {
            time += frame.deltaTime
            var pose = rig.restPose
            for change in frame.overrides {
                let index = try #require(ids[change.sourceID]),node = rig.nodes[index]
                pose.localMatrices[index] = Transform.trs(change.translation ?? node.translation,change.rotation.map {simd_quatf(vector:$0)} ?? node.rotation,change.scale ?? node.scale)
            }
            let output = try session.evaluate(time:time,rig:rig,upstream:pose,enableFK:false,activeFK:Array(repeating:false,count:7),deltaTime:frame.deltaTime)
            let world = try rig.evaluate(output).worldMatrices
            #expect(session.states[0].lastStepCount == frame.expected.lastStepCount)
            for (index,particle) in scenario.definition.particles.enumerated() {
                let error = simd_distance(world[try #require(ids[particle.nodeID])].translation,frame.expected.positions[index])
                maximum = max(maximum,error); #expect(error < 4e-5)
            }
            let repeated = try session.evaluate(time:time,rig:rig,upstream:pose,enableFK:false,activeFK:Array(repeating:false,count:7),deltaTime:frame.deltaTime)
            #expect(repeated.localMatrices == output.localMatrices)
            frameCount += 1
        }
    }
    #expect(frameCount > 0)
    print("Studio dynamics independent original reference: \(frameCount) frames, maximum world error \(maximum)")
}
