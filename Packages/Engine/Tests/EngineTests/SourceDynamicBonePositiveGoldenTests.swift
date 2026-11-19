import CryptoKit
import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character

// #406: the positive-scale golden. Signed TRS support must leave every chain
// whose scales are all positive bit-identical to the solver before it. This
// file generates seeded synthetic chains (random rotations, positive
// nonuniform scales, branches, colliders, freeze axes, update rates, weights,
// a moving owner and an animated ancestor scale), steps them, and hashes the
// bit patterns of everything the solver exposes: each frame's output local
// matrices, the particle state, the clock and the step count, and any error.
// Fixtures/dynamics-positive-golden.json holds the hashes recorded at main
// da7da61a, before the change. All data is synthetic.
//
// The generator uses no libm call (no sin, cos or angle-axis quaternion), so
// the inputs are the same bits on every macOS version; the solver itself only
// reaches libm in rotation(from:to:)'s opposite-vector case.
//
// Record (only on the base commit): IKKOKU_RECORD_DYNAMICS_GOLDEN=1 swift test
// --filter positiveScaleDynamicsMatchTheRecordedGoldenBitForBit.

private let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/dynamics-positive-golden.json")
private let scenarioCount = 48, frameCount = 60, queryCount = 256

/// SplitMix64: a fixed, platform-independent sequence.
private struct GoldenRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// A float in lo..<hi from the top 24 bits.
    mutating func float(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * Float(next() >> 40) / Float(1 << 24) }
    mutating func int(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    mutating func vector(_ lo: Float, _ hi: Float) -> Float3 { Float3(float(lo, hi), float(lo, hi), float(lo, hi)) }
    /// A unit quaternion from a normalized random 4-vector (sqrt only).
    mutating func rotation() -> simd_quatf {
        simd_quatf(vector: normalize(Float4(vector(-1, 1), float(-1, 1)) + Float4(0, 0, 0, 1e-3)))
    }
    mutating func scale() -> Float3 { vector(0.3, 3) }
}

/// Bit patterns of everything a frame exposes, fed to one running hash.
private struct GoldenHasher {
    var hash = SHA256()
    mutating func add(_ value: Float) { withUnsafeBytes(of: value.bitPattern.littleEndian) { hash.update(bufferPointer: $0) } }
    mutating func add(_ value: Int) { withUnsafeBytes(of: Int64(value).littleEndian) { hash.update(bufferPointer: $0) } }
    mutating func add(_ value: Float3) { add(value.x); add(value.y); add(value.z) }
    mutating func add(_ value: float4x4) { for c in 0..<4 { for r in 0..<4 { add(value[c][r]) } } }
    mutating func add(_ text: String) { hash.update(data: Data(text.utf8)) }
    mutating func finish() -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
}

private struct GoldenScenario {
    let rig: RigDefinition
    let definition: SourceDynamicsDocument.Component
    let validated: Bool
}

/// Nodes: 0 base, 1 owner, 2 ancestor, 3... particle chain (with an optional
/// branch off particle 1), then two collider nodes. Every scale is positive.
private func goldenScenario(_ random: inout GoldenRandom) throws -> GoldenScenario {
    var nodes: [RigDefinition.Node] = [
        .init(name: "base", sourceID: "base", parent: nil, translation: random.vector(-1, 1), rotation: random.rotation(), scale: random.scale()),
        .init(name: "owner", sourceID: "owner", parent: 0, translation: random.vector(-0.5, 0.5), rotation: random.rotation(), scale: random.scale()),
        .init(name: "ancestor", sourceID: "ancestor", parent: 1, translation: random.vector(-0.5, 0.5), rotation: random.rotation(), scale: random.scale())
    ]
    let chain = 2 + random.int(4)
    var particles: [SourceDynamicsDocument.Particle] = []
    for i in 0..<chain {
        let id = "p\(i)"
        nodes.append(.init(name: id, sourceID: id, parent: nodes.count - 1, translation: i == 0 ? random.vector(-0.2, 0.2)
                           : Float3(random.float(-0.2, 0.2), random.float(-1, -0.2), random.float(-0.2, 0.2)),
                           rotation: random.rotation(), scale: random.scale()))
        particles.append(.init(nodeID: id, parent: i == 0 ? nil : i - 1, damping: random.float(0, 1), elasticity: random.float(0, 1),
                               stiffness: random.float(0, 1), inert: random.float(0, 1), radius: random.float(0, 0.2)))
    }
    if random.int(2) == 1 {
        // A second child of particle 1: its parent keeps its rotation (more than one child).
        nodes.append(.init(name: "branch", sourceID: "branch", parent: 4, translation: Float3(random.float(-0.5, 0.5), -0.5, 0),
                           rotation: random.rotation(), scale: random.scale()))
        particles.append(.init(nodeID: "branch", parent: 1, damping: random.float(0, 1), elasticity: random.float(0, 1),
                               stiffness: random.float(0, 1), inert: random.float(0, 1), radius: random.float(0, 0.2)))
    }
    nodes.append(.init(name: "c0", sourceID: "c0", parent: 2, translation: random.vector(-1, 1), rotation: random.rotation(), scale: random.scale()))
    nodes.append(.init(name: "c1", sourceID: "c1", parent: 0, translation: random.vector(-1, 1), rotation: random.rotation(), scale: random.scale()))
    let colliders = ["c0", "c1"].map { id in
        SourceDynamicsDocument.Collider(nodeID: id, center: random.vector(-0.2, 0.2), radius: random.float(0, 0.6),
                                        height: random.int(2) == 0 ? 0 : random.float(0, 2), direction: random.int(3), bound: random.int(2))
    }
    let rates: [Float] = [0, 30, 60, 120]
    let definition = SourceDynamicsDocument.Component(
        sourceID: "golden", ownerID: "owner", updateRate: rates[random.int(rates.count)],
        gravity: random.vector(-0.02, 0.02), force: random.vector(-0.01, 0.01), freezeAxis: random.int(4),
        particles: particles, colliders: colliders)
    return GoldenScenario(rig: try RigDefinition(nodes: nodes, skins: []), definition: definition, validated: random.int(2) == 1)
}

/// The owner moves and turns, and the ancestor's scale changes, every frame.
/// The owner follows a triangle wave u in [-1, 1) with a period of 20 frames.
private func goldenPose(_ scenario: GoldenScenario, frame: Int, random: inout GoldenRandom) -> RigPose {
    var pose = scenario.rig.restPose
    let owner = scenario.rig.nodes[1], ancestor = scenario.rig.nodes[2]
    let u = Float(frame % 20) / 10 - 1, turn = simd_quatf(vector: normalize(Float4(0, 0.15 * u, 0, 1)))
    pose.localMatrices[1] = Transform.trs(owner.translation + Float3(u, 0.3 * (1 - u * u), 0.2 * u * u * u) * 0.2,
                                          turn * owner.rotation, owner.scale)
    pose.localMatrices[2] = Transform.trs(ancestor.translation, ancestor.rotation,
                                          ancestor.scale * (1 + 0.25 * random.vector(-1, 1)))
    return pose
}

private struct GoldenRun { var hash: String, bound: Bool, failedFrames: Int, inverseSafe = 0 }

/// One scenario's hash over every frame, from a seed.
private func goldenRun(seed: UInt64) throws -> GoldenRun {
    var random = GoldenRandom(state: seed), hasher = GoldenHasher()
    let scenario = try goldenScenario(&random)
    let deltas: [Float] = [0, 1 / 120, 1 / 60, 1 / 30, 0.1]
    var state: SourceDynamicBone, failedFrames = 0
    do { state = try SourceDynamicBone(rig: scenario.rig, pose: goldenPose(scenario, frame: 0, random: &random), definition: scenario.definition) }
    catch { hasher.add("bind: \(error)"); return GoldenRun(hash: hasher.finish(), bound: false, failedFrames: 0) }
    for frame in 1...frameCount {
        let pose = goldenPose(scenario, frame: frame, random: &random)
        do {
            var output = pose
            switch frame {
            case 20: output = try state.setWeight(0.5, rig: scenario.rig, pose: pose)
            case 35: output = try state.setWeight(0, rig: scenario.rig, pose: pose)
            case 36: output = try state.setWeight(1, rig: scenario.rig, pose: pose)
            default: output = try state.step(deltaTime: deltas[random.int(deltas.count)], rig: scenario.rig, pose: pose,
                                             validatedInput: scenario.validated)
            }
            hasher.add(frame)
            for matrix in output.localMatrices { hasher.add(matrix) }
        } catch { hasher.add("frame \(frame): \(error)"); failedFrames += 1 }
        for p in state.positions { hasher.add(p) }
        for p in state.previousPositions { hasher.add(p) }
        hasher.add(state.remainder); hasher.add(state.lastStepCount); hasher.add(state.weight)
    }
    // Not hashed: the InverseSafe count arrived with #406 (it must stay 0 here).
    return GoldenRun(hash: hasher.finish(), bound: true, failedFrames: failedFrames, inverseSafe: state.inverseSafePlacements)
}

/// Static collider queries through positive matrices.
private func goldenQueries(seed: UInt64) -> String {
    var random = GoldenRandom(state: seed), hasher = GoldenHasher()
    for _ in 0..<queryCount {
        let matrix = Transform.trs(random.vector(-1, 1), random.rotation(), random.scale())
        let collider = SourceDynamicsDocument.Collider(nodeID: "c", center: random.vector(-0.3, 0.3), radius: random.float(0, 1),
                                                       height: random.int(2) == 0 ? 0 : random.float(0, 3),
                                                       direction: random.int(3), bound: random.int(2))
        do { hasher.add(try SourceDynamicBone.collide(position: random.vector(-2, 2), particleRadius: random.float(0, 0.3),
                                                      collider: collider, matrix: matrix)) }
        catch { hasher.add("query: \(error)") }
    }
    return hasher.finish()
}

private struct GoldenFile: Codable {
    var base: String
    var scenarios: [String]
    var queries: String
}

@Test func positiveScaleDynamicsMatchTheRecordedGoldenBitForBit() throws {
    let runs = try (0..<scenarioCount).map { try goldenRun(seed: 0x0406_0000 &+ UInt64($0)) }
    let scenarios = runs.map(\.hash), queries = goldenQueries(seed: 0x0406_FFFF)
    print("dynamics golden: \(runs.filter(\.bound).count)/\(scenarioCount) bound, \(runs.map(\.failedFrames).reduce(0, +)) failed frames")
    if ProcessInfo.processInfo.environment["IKKOKU_RECORD_DYNAMICS_GOLDEN"] == "1" {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(GoldenFile(base: "da7da61a", scenarios: scenarios, queries: queries)) + Data("\n".utf8)).write(to: goldenURL)
        return
    }
    // Every positive chain binds and steps without an error at the base, and
    // never reaches the InverseSafe placement of a singular parent (#406).
    #expect(runs.allSatisfy { $0.bound && $0.failedFrames == 0 })
    #expect(runs.allSatisfy { $0.inverseSafe == 0 })
    let golden = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: goldenURL))
    #expect(golden.scenarios.count == scenarioCount)
    for (i, (expected, actual)) in zip(golden.scenarios, scenarios).enumerated() {
        #expect(expected == actual, "scenario \(i) (seed 0x\(String(0x0406_0000 + i, radix: 16))) differs from the golden recorded at \(golden.base)")
    }
    #expect(golden.queries == queries, "collider queries differ from the golden recorded at \(golden.base)")
}
