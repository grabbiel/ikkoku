import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character

/// `RigDefinition.isFiniteAffine` became four-lane on 2026-11-17 (r7l2: during
/// a Studio FK drag it took 28.6 ms/s of the main thread, more than the rest of
/// `rig.evaluate`). This is the element loop it replaced, verbatim, as the
/// reference: the new form must return the same Bool for every input.
private func referenceIsFiniteAffine(_ matrix: float4x4) -> Bool {
    for column in 0..<4 { for row in 0..<4 where !matrix[column][row].isFinite { return false } }
    return abs(matrix[0].w) < 1e-5 && abs(matrix[1].w) < 1e-5 && abs(matrix[2].w) < 1e-5 && abs(matrix[3].w - 1) < 1e-5
}

/// SplitMix64, so every run draws the same matrices.
private struct FiniteAffineSeed: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Values that sit on each edge of the predicate: non-finite ones, the finite
/// extremes, signed zeros, subnormals and both sides of the 1e-5 thresholds of
/// the w lanes (around 0 and around 1).
private let finiteAffineEdgeValues: [Float] = {
    let threshold: Float = 1e-5
    var values: [Float] = [.nan, -.nan, .signalingNaN, Float(bitPattern: 0x7FC0_1234), Float(bitPattern: 0xFF80_0001),
                           .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                           .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .leastNormalMagnitude, -.leastNormalMagnitude,
                           0, -0.0, 1, -1, 2, 0.5, 1e30, -1e30]
    for edge in [threshold, -threshold, 1 + threshold, 1 - threshold] {
        values += [edge, edge.nextUp, edge.nextDown, edge.nextUp.nextUp, edge.nextDown.nextDown]
    }
    return values
}()

private let finiteAffineBases: [float4x4] = [
    matrix_identity_float4x4,
    Transform.trs(Float3(1.25, -2.5, 3.75), simd_quatf(angle: 0.7, axis: simd_normalize(Float3(1, 2, 3))), Float3(0.5, 2, 3)),
    float4x4(columns: (Float4(3e38, -3e38, .leastNormalMagnitude / 4, 0), Float4(0, 1, 0, 0),
                       Float4(-.leastNonzeroMagnitude, 0, 1, 0), Float4(1e38, 2, -3, 1))),
    float4x4(columns: (Float4(1, 0, 0, 0.5), Float4(0, 1, 0, 0), Float4(0, 0, 1, 0), Float4(0, 0, 0, 1)))
]

@Test func finiteAffineMatchesTheElementLoopOnEveryEdgeValueInEveryPosition() {
    var checked = 0, accepted = 0, rejected = 0
    for (baseIndex, base) in finiteAffineBases.enumerated() {
        for column in 0..<4 {
            for row in 0..<4 {
                for value in finiteAffineEdgeValues {
                    var matrix = base
                    matrix[column][row] = value
                    let expected = referenceIsFiniteAffine(matrix)
                    #expect(RigDefinition.isFiniteAffine(matrix) == expected,
                            "base \(baseIndex), [\(column)][\(row)] = \(value) (bits \(String(value.bitPattern, radix: 16)))")
                    checked += 1; if expected { accepted += 1 } else { rejected += 1 }
                }
            }
        }
    }
    // The four w lanes together, each on either side of its threshold.
    let w: [Float] = [0, 1e-5, (1e-5 as Float).nextDown, -(1e-5 as Float).nextDown, .nan]
    let w3: [Float] = [1, 1 + 1e-5, (1 + 1e-5 as Float).nextDown, (1 - 1e-5 as Float).nextUp, 1 - 1e-5, .infinity]
    for a in w { for b in w { for c in w { for d in w3 {
        var matrix = matrix_identity_float4x4
        matrix[0].w = a; matrix[1].w = b; matrix[2].w = c; matrix[3].w = d
        let expected = referenceIsFiniteAffine(matrix)
        #expect(RigDefinition.isFiniteAffine(matrix) == expected, "w lanes \(a) \(b) \(c) \(d)")
        checked += 1; if expected { accepted += 1 } else { rejected += 1 }
    } } } }
    #expect(accepted > 500 && rejected > 1000)
    print("[finite-affine] edge values: \(checked) matrices agree (\(accepted) accepted, \(rejected) rejected)")
}

@Test func finiteAffineMatchesTheElementLoopOnSeededRandomMatrices() {
    var random = FiniteAffineSeed(state: 0x5EED_F1A1_7E00_0001)
    var accepted = 0, rejected = 0, mismatches = 0
    for index in 0..<100_000 {
        var matrix = matrix_identity_float4x4
        if index % 2 == 0 {
            // Raw bit patterns: NaN, infinity, subnormals and every exponent.
            for column in 0..<4 { for row in 0..<4 { matrix[column][row] = Float(bitPattern: UInt32(truncatingIfNeeded: random.next())) } }
        } else {
            // Near-affine: any finite x, y, z, and w lanes a few ulps-to-steps
            // from the thresholds, sometimes with one element replaced by an
            // edge value.
            for column in 0..<4 {
                for row in 0..<3 {
                    let exponent = Float(Int(random.next() % 77) - 38)
                    let sign: Float = random.next() % 2 == 0 ? 1 : -1
                    let mantissa = Float.random(in: 1..<10, using: &random)
                    matrix[column][row] = sign * mantissa * pow(10, exponent)
                }
                // Seven in eight lanes exact, the rest up to 2e-5 away.
                var step: Float = 0
                if random.next() % 8 == 0 { step = Float(Int(random.next() % 41) - 20) * 1e-6 }
                matrix[column].w = (column == 3 ? 1 : 0) + step
            }
            if random.next() % 4 == 0 {
                let value = finiteAffineEdgeValues[Int(random.next() % UInt64(finiteAffineEdgeValues.count))]
                matrix[Int(random.next() % 4)][Int(random.next() % 4)] = value
            }
        }
        let expected = referenceIsFiniteAffine(matrix)
        if RigDefinition.isFiniteAffine(matrix) != expected {
            mismatches += 1
            Issue.record("matrix \(index): \(matrix) reference \(expected)")
        }
        if expected { accepted += 1 } else { rejected += 1 }
    }
    #expect(mismatches == 0)
    #expect(accepted > 10_000 && rejected > 50_000)
    print("[finite-affine] random: 100000 matrices, \(mismatches) mismatches (\(accepted) accepted, \(rejected) rejected)")
}

private func rejection(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch { return "\(error)" }
}

private func setting(_ matrix: float4x4, _ column: Int, _ row: Int, _ value: Float) -> float4x4 {
    var result = matrix; result[column][row] = value; return result
}

/// Each `isFiniteAffine` check of `RigDefinition` and `Skeleton` still rejects a
/// non-finite or projective matrix, with the message it gave before.
@Test func finiteAffineRejectionsKeepTheirMessagesOnEveryRigPath() throws {
    let bad: [(column: Int, row: Int, value: Float)] = [(2, 1, .nan), (3, 0, .infinity), (0, 0, -.infinity), (1, 3, 0.5), (3, 3, 1.001)]
    let local = Transform.trs(Float3(0, 1, 0), simd_quatf(angle: 0.3, axis: Float3(0, 0, 1)), Float3(1, 2, 1))
    for (column, row, value) in bad {
        let label = "[\(column)][\(row)] = \(value)"
        #expect(!referenceIsFiniteAffine(setting(local, column, row, value)), "\(label)")
        // RigDefinition.init: a node's local matrix, and a skin's inverse binds.
        #expect(rejection {
            _ = try RigDefinition(nodes: [.init(name: "root", sourceID: "root", parent: nil),
                                          .init(name: "joint", sourceID: "joint", parent: 0, authoredMatrix: setting(local, column, row, value))], skins: [])
        } == "Rig node 1 has an invalid local matrix.", "\(label)")
        #expect(rejection {
            _ = try RigDefinition(nodes: [.init(name: "mesh", sourceID: "mesh", parent: nil), .init(name: "joint", sourceID: "joint", parent: 0)],
                                  skins: [.init(name: "skin", meshNode: 0, joints: [1, 0],
                                                inverseBindMatrices: [matrix_identity_float4x4, setting(local, column, row, value)])])
        } == "Rig skin 0 has invalid joint references or inverse binds.", "\(label)")
        // RigDefinition.evaluate: a pose's local matrix.
        let rig = try RigDefinition(nodes: [.init(name: "mesh", sourceID: "mesh", parent: nil),
                                            .init(name: "joint", sourceID: "joint", parent: 0, translation: Float3(0, 1, 0)),
                                            .init(name: "tip", sourceID: "tip", parent: 1, translation: Float3(0, 1, 0))],
                                    skins: [.init(name: "skin", meshNode: 0, joints: [1, 2], inverseBindMatrices: [matrix_identity_float4x4, matrix_identity_float4x4])])
        _ = try rig.evaluate(rig.restPose)
        var pose = rig.restPose
        pose.localMatrices[2] = setting(local, column, row, value)
        #expect(rejection { _ = try rig.evaluate(pose) } == "Pose node 2 has an invalid matrix.", "\(label)")
        // Skeleton: a bone's inverse bind.
        var bone = Skeleton.Bone(name: "arm", parent: 0, restTranslation: Float3(0, 1, 0))
        bone.inverseBind = setting(local, column, row, value)
        #expect(throws: SkeletonError.invalidInverseBind(bone: "arm")) { try Skeleton(bones: [Skeleton.Bone(name: "root", parent: nil), bone]) }
    }
    // RigDefinition.evaluate: finite locals whose world product overflows, and a
    // finite world whose palette entry overflows.
    let chain = try RigDefinition(nodes: [.init(name: "root", sourceID: "root", parent: nil), .init(name: "child", sourceID: "child", parent: 0)], skins: [])
    var huge = chain.restPose
    huge.localMatrices[0] = Transform.scale(Float3(repeating: 1e20)); huge.localMatrices[1] = Transform.scale(Float3(repeating: 1e20))
    #expect(rejection { _ = try chain.evaluate(huge) } == "Pose hierarchy overflow at node 1.")
    let far = Transform.translation(Float3(3e38, 0, 0))
    let skinned = try RigDefinition(nodes: [.init(name: "mesh", sourceID: "mesh", parent: nil),
                                            .init(name: "joint", sourceID: "joint", parent: 0, translation: Float3(3e38, 0, 0))],
                                    skins: [.init(name: "skin", meshNode: 0, joints: [1], inverseBindMatrices: [far])])
    #expect(rejection { _ = try skinned.evaluate(skinned.restPose) } == "Skin 0 produced a nonfinite palette.")
}

/// #404 keeps a singular mesh world's palette in rig space. Every pose here
/// keeps its mesh worlds regular (face shapes at 0, 0.5, 1 and random rates
/// on the head rig; rest and randomly rotated and scaled poses, reflections
/// included, on both avatars), so `rig.evaluate` must return bit for bit what
/// `referenceEvaluate` (the pre-#404 form) returns, with no collapsed skin
/// and each skin drawn with its mesh node's world.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_HEAD_RIG", "IKKOKU_SHAPE_CONTRACT", "IKKOKU_SOURCE_AVATAR", "IKKOKU_SOURCE_MALE_AVATAR"]),
               "Requires IKKOKU_HEAD_RIG, IKKOKU_SHAPE_CONTRACT, IKKOKU_SOURCE_AVATAR, IKKOKU_SOURCE_MALE_AVATAR"))
func rigEvaluationKeepsRegularFixturePosesBitIdentical() throws {
    let head = try SourceRig.load(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_HEAD_RIG")))
    let contract = try SourceShapeContract.decode(Data(contentsOf: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHAPE_CONTRACT"))))
    let face = try #require(contract.domain("face"))
    var random = FiniteAffineSeed(state: 404)
    var cases: [(rig: RigDefinition, pose: RigPose)] = []
    for rate: Float in [0, 0.5, 1] {
        cases.append((head.rig, try SourceFaceShapePose.make(rig: head.rig, domain: face, values: Array(repeating: rate, count: face.valueCount))))
    }
    for _ in 0..<4 {
        let values = (0..<face.valueCount).map { _ in Float.random(in: 0...1, using: &random) }
        cases.append((head.rig, try SourceFaceShapePose.make(rig: head.rig, domain: face, values: values)))
    }
    for variable in ["IKKOKU_SOURCE_AVATAR", "IKKOKU_SOURCE_MALE_AVATAR"] {
        let rig = try SourceRig.loadModel(url: URL(fileURLWithPath: try SourceFixtureSupport.require(variable))).rig
        cases.append((rig, rig.restPose))
        for reflect in [false, true] {
            var pose = rig.restPose
            for index in pose.localMatrices.indices where Int.random(in: 0..<4, using: &random) == 0 {
                let axis = simd_normalize(Float3(Float.random(in: -1...1, using: &random), Float.random(in: -1...1, using: &random), 1))
                var scale = Float3((0..<3).map { _ in Float.random(in: 0.8...1.25, using: &random) })
                if reflect, Int.random(in: 0..<3, using: &random) == 0 { scale.x = -scale.x }
                pose.localMatrices[index] = pose.localMatrices[index] * Transform.trs(.zero, simd_quatf(angle: Float.random(in: -0.5...0.5, using: &random), axis: axis), scale)
            }
            cases.append((rig, pose))
        }
    }
    for (rig, pose) in cases {
        let evaluation = try rig.evaluate(pose), reference = try referenceEvaluate(rig, pose)
        #expect(evaluation.collapsedSkins.isEmpty)
        #expect(finiteAffineBits(evaluation.worldMatrices) == finiteAffineBits(reference.world))
        #expect(finiteAffineBits(evaluation.palettes.flatMap { $0 }) == finiteAffineBits(reference.palettes.flatMap { $0 }))
        #expect(finiteAffineBits(rig.skins.indices.map { evaluation.model(skin: $0, meshNode: rig.skins[$0].meshNode) })
                == finiteAffineBits(rig.skins.map { reference.world[$0.meshNode] }))
    }
    #expect(cases.count == 13)
}

/// Opt-in Release timing probe (IKKOKU_FINITE_AFFINE_PERF=1 plus
/// IKKOKU_SOURCE_AVATAR). Run it with
/// `swift test -c release -Xswiftc -enable-testing --filter RigFiniteAffineTests`
/// (the target's other files need `@testable`). On the avatar rig's
/// own matrices (every rest local, world and palette matrix: what `evaluate`
/// checks) it times, in alternating rounds in one process:
/// - `RigDefinition.isFiniteAffine` against this file's copy of the element
///   loop, each behind one call that is not inlined;
/// - `rig.evaluate` against `referenceEvaluate`, this file's copy of
///   `evaluate` with the element loop, and checks that the two agree bit for
///   bit.
/// Built at a revision before 2026-11-17 (with this file added), both sides
/// run the element loop: the in-process baseline's control.
@Test(.enabled(if: (ProcessInfo.processInfo.environment["IKKOKU_FINITE_AFFINE_PERF"] ?? "") == "1"
               && (ProcessInfo.processInfo.environment["IKKOKU_SOURCE_AVATAR"] ?? "").isEmpty == false,
               "Opt-in timing probe: IKKOKU_FINITE_AFFINE_PERF=1 plus IKKOKU_SOURCE_AVATAR"))
func finiteAffinePerformanceProbe() throws {
    let source = try SourceRig.loadModel(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["IKKOKU_SOURCE_AVATAR"]!))
    let rig = source.rig, pose = rig.restPose
    let rest = try rig.evaluate(pose)
    let matrices = pose.localMatrices + rest.worldMatrices + rest.palettes.flatMap { $0 }
    let reference = try referenceEvaluate(rig, pose)
    #expect(finiteAffineBits(reference.world) == finiteAffineBits(rest.worldMatrices)
            && finiteAffineBits(reference.palettes.flatMap { $0 }) == finiteAffineBits(rest.palettes.flatMap { $0 }))
    func median(_ samples: [UInt64]) -> Double { Double(samples.sorted()[samples.count / 2]) }
    var loop: [UInt64] = [], current: [UInt64] = [], loopAccepted = 0, currentAccepted = 0
    for round in 0..<420 {
        for variant in round % 2 == 0 ? [0, 1] : [1, 0] {
            let start = DispatchTime.now().uptimeNanoseconds
            var count = 0
            if variant == 0 {
                for matrix in matrices where finiteAffineLoopCall(matrix) { count += 1 }
            } else {
                for matrix in matrices where RigDefinition.isFiniteAffine(matrix) { count += 1 }
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard round >= 20 else { continue }
            if variant == 0 { loop.append(elapsed); loopAccepted = count } else { current.append(elapsed); currentAccepted = count }
        }
    }
    #expect(loopAccepted == matrices.count && currentAccepted == matrices.count)
    var old: [UInt64] = [], new: [UInt64] = []
    for round in 0..<420 {
        for variant in round % 2 == 0 ? [0, 1] : [1, 0] {
            let start = DispatchTime.now().uptimeNanoseconds
            let count: Int
            if variant == 0 { count = try referenceEvaluate(rig, pose).world.count } else { count = try rig.evaluate(pose).worldMatrices.count }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            precondition(count == rig.nodes.count)
            guard round >= 20 else { continue }
            if variant == 0 { old.append(elapsed) } else { new.append(elapsed) }
        }
    }
    let count = Double(matrices.count)
    print("[finite-affine-perf] \(rig.nodes.count) nodes, \(rest.palettes.reduce(0) { $0 + $1.count }) palette matrices, \(matrices.count) checked matrices")
    print(String(format: "[finite-affine-perf] check per matrix: element loop %.2f ns, RigDefinition.isFiniteAffine %.2f ns (median of %ld rounds)",
                 median(loop) / count, median(current) / count, loop.count))
    print(String(format: "[finite-affine-perf] evaluate: referenceEvaluate %.1f us, rig.evaluate %.1f us (median of %ld rounds)",
                 median(old) / 1000, median(new) / 1000, old.count))
}

@inline(never) private func finiteAffineLoopCall(_ matrix: float4x4) -> Bool { referenceIsFiniteAffine(matrix) }

private func finiteAffineBits(_ matrices: [float4x4]) -> [UInt32] {
    matrices.flatMap { m in [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { c in (0..<4).map { c[$0].bitPattern } } }
}

/// `RigDefinition.evaluate` as of 2026-11-17, verbatim except that it calls
/// the element loop and returns a tuple: the probe's in-process baseline.
private func referenceEvaluate(_ rig: RigDefinition, _ pose: RigPose) throws -> (world: [float4x4], palettes: [[float4x4]]) {
    guard pose.localMatrices.count == rig.nodes.count else { throw RigError.invalid("Pose does not match rig node count.") }
    var world = [float4x4](repeating: matrix_identity_float4x4, count: rig.nodes.count)
    for index in rig.order {
        let local = pose.localMatrices[index]
        guard referenceIsFiniteAffine(local) else { throw RigError.invalid("Pose node \(index) has an invalid matrix.") }
        world[index] = rig.nodes[index].parent.map { world[$0] * local } ?? local
        guard referenceIsFiniteAffine(world[index]) else { throw RigError.invalid("Pose hierarchy overflow at node \(index).") }
    }
    let palettes = try rig.skins.enumerated().map { index, skin -> [float4x4] in
        let meshWorld = world[skin.meshNode]
        guard abs(simd_determinant(meshWorld)) > 1e-12 else { throw RigError.invalid("Skin \(index) has a singular mesh transform.") }
        let meshInverse = simd_inverse(meshWorld)
        let matrices = zip(skin.joints, skin.inverseBindMatrices).map { meshInverse * world[$0] * $1 }
        guard matrices.allSatisfy(referenceIsFiniteAffine) else { throw RigError.invalid("Skin \(index) produced a nonfinite palette.") }
        return matrices
    }
    return (world, palettes)
}
