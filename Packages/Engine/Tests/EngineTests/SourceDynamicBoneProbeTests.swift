import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character

// #406 information-only micro probe: SourceDynamicBone.step, which is
// DynamicsTransforms.init, advance and the write-back, over seeded synthetic
// positive chains in one process. It uses only API that predates #406, so the
// same file runs on a base and a head build. Not a bar.
//
// IKKOKU_DYNAMICS_PROBE=1 swift test -c release --filter dynamicsStepMicroProbe

private struct ProbeRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func float(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * Float(next() >> 40) / Float(1 << 24) }
    mutating func vector(_ lo: Float, _ hi: Float) -> Float3 { Float3(float(lo, hi), float(lo, hi), float(lo, hi)) }
    mutating func rotation() -> simd_quatf { simd_quatf(vector: normalize(Float4(vector(-1, 1), float(-1, 1)) + Float4(0, 0, 0, 1e-3))) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IKKOKU_DYNAMICS_PROBE"] == "1"))
func dynamicsStepMicroProbe() throws {
    var random = ProbeRandom(state: 0x0406_7777)
    var chains: [(rig: RigDefinition, state: SourceDynamicBone, poses: [RigPose])] = []
    for _ in 0..<32 {
        var nodes: [RigDefinition.Node] = [
            .init(name: "base", sourceID: "base", parent: nil, translation: random.vector(-1, 1), rotation: random.rotation(), scale: random.vector(0.5, 2)),
            .init(name: "owner", sourceID: "owner", parent: 0, translation: random.vector(-0.5, 0.5), rotation: random.rotation(), scale: random.vector(0.5, 2))]
        var particles: [SourceDynamicsDocument.Particle] = []
        for i in 0..<5 {
            nodes.append(.init(name: "p\(i)", sourceID: "p\(i)", parent: nodes.count - 1,
                               translation: Float3(random.float(-0.1, 0.1), -0.3, random.float(-0.1, 0.1)),
                               rotation: random.rotation(), scale: random.vector(0.5, 2)))
            particles.append(.init(nodeID: "p\(i)", parent: i == 0 ? nil : i - 1, damping: 0.1, elasticity: 0.1,
                                   stiffness: 0.2, inert: 0.3, radius: 0.05))
        }
        nodes.append(.init(name: "c", sourceID: "c", parent: 1, translation: random.vector(-0.5, 0.5), scale: random.vector(0.5, 2)))
        let rig = try RigDefinition(nodes: nodes, skins: [])
        let definition = SourceDynamicsDocument.Component(sourceID: "probe", ownerID: "owner", updateRate: 60,
            gravity: Float3(0, -0.01, 0), force: Float3(0.002, 0, 0), particles: particles,
            colliders: [.init(nodeID: "c", radius: 0.2, height: 0.6, direction: 1)])
        var poses: [RigPose] = []
        for frame in 0..<64 {
            var pose = rig.restPose
            let u = Float(frame % 16) / 8 - 1
            pose.localMatrices[1] = Transform.trs(nodes[1].translation + Float3(u, 0, 0) * 0.1, nodes[1].rotation, nodes[1].scale)
            poses.append(pose)
        }
        chains.append((rig, try SourceDynamicBone(rig: rig, pose: poses[0], definition: definition), poses))
    }
    var checksum: Float = 0, samples: [Double] = []
    let steps = chains.count * chains[0].poses.count
    for round in 0..<105 {
        var states = chains.map(\.state)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for c in chains.indices {
            for pose in chains[c].poses {
                _ = try states[c].step(deltaTime: 1 / 60, rig: chains[c].rig, pose: pose, validatedInput: true)
            }
        }
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
        for state in states { checksum += state.positions.last!.x }
        if round >= 5 { samples.append(Double(elapsed) / Double(steps)) }
    }
    samples.sort()
    func at(_ q: Double) -> Double { samples[min(samples.count - 1, Int(q * Double(samples.count)))] }
    print(String(format: "[dynamics-probe] RigPose size %d; ns/step median %.1f p10 %.1f p90 %.1f over %d rounds of %d steps; checksum %.6f",
                 MemoryLayout<RigPose>.size, at(0.5), at(0.1), at(0.9), samples.count, steps, Double(checksum)))
}
