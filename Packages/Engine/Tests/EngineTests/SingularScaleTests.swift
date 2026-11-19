import Foundation
import Testing
import simd
import CoreMath
import Scene
import Character
@testable import Studio
@testable import Renderer

// #404: an extended face slider can give a target a zero or negative scale.
// These tests hold the Unity-like fallbacks for a singular basis (normal
// matrix, world-to-object inverse, eye look, collapsed renderers) to their
// two contracts: every nonsingular input computes bit for bit what it did
// before, and a collapsed FaceUp_ty gives finite values everywhere.

/// The pre-#404 normal matrix, verbatim: the bit-equality reference.
private func referenceNormalMatrix(from m: float4x4) -> float4x4 {
    let n = m.upperLeft3x3.inverse.transpose
    return float4x4(Float4(n.columns.0, 0), Float4(n.columns.1, 0), Float4(n.columns.2, 0), Float4(0, 0, 0, 1))
}

private func referenceNormalMatrix3(from m: float4x4) -> float3x3 { m.upperLeft3x3.inverse.transpose }

/// The pre-#404 eye-look node of `updateEyeLook`, verbatim.
private func referenceEyeNode(_ matrix: float4x4) -> SourceStudioEyeLookGeometry.Node {
    let q = matrix.rotationQuaternion
    let scale = matrix.scaleFactors
    return .init(position: SIMD3(Double(matrix.translation.x), Double(matrix.translation.y), Double(matrix.translation.z)),
                 rotation: simd_quatd(ix: Double(q.imag.x), iy: Double(q.imag.y), iz: Double(q.imag.z), r: Double(q.real)),
                 lossyScale: SIMD3(Double(scale.x), Double(scale.y), Double(scale.z)))
}

private func bits(_ m: float4x4) -> [UInt32] { (0..<4).flatMap { c in (0..<4).map { m[c][$0].bitPattern } } }
private func bits(_ m: float3x3) -> [UInt32] { (0..<3).flatMap { c in (0..<3).map { m[c][$0].bitPattern } } }
private func bits(_ node: SourceStudioEyeLookGeometry.Node) -> [UInt64] {
    [node.position.x, node.position.y, node.position.z, node.rotation.imag.x, node.rotation.imag.y, node.rotation.imag.z,
     node.rotation.real, node.lossyScale.x, node.lossyScale.y, node.lossyScale.z].map(\.bitPattern)
}

private func isFinite(_ m: float4x4) -> Bool { (0..<4).allSatisfy { c in (0..<4).allSatisfy { m[c][$0].isFinite } } }
private func isFinite(_ m: float3x3) -> Bool { (0..<3).allSatisfy { c in (0..<3).allSatisfy { m[c][$0].isFinite } } }
private func isFinite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

/// SplitMix64, so every run draws the same matrices.
private struct SingularScaleSeed: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private var liveState: SourceShaderLiveEncoder.FrameState {
    .init(view: matrix_identity_float4x4, projection: matrix_identity_float4x4, cameraPosition: .zero,
          lightDirection: Float3(0, -1, 0), lightColor: .one, lightIntensity: 1, width: 1, height: 1, time: 0)
}

/// A face rig with the source's HairParent chain: every face target under
/// `head` except FaceUp_ty (under FaceBase) and the eye center (under
/// FaceUp_ty), plus a hair renderer and two hair bones under FaceUp_ty
/// (HairParent, ChaReference) skinned with their bind-time inverse binds.
/// `pose` writes `faceUpScale` through the face stage.
struct CollapsedHairFixture {
    let rig: RigDefinition, pose: RigPose
    let mesh: Int, faceUp: Int, eye: Int, bones: [Int]
    /// Mesh-local hair vertices with their weights on `bones`.
    let vertices: [(position: Float3, weights: SIMD2<Float>)] = [
        (Float3(0.01, -0.05, 0.02), SIMD2(1, 0)), (Float3(0.02, -0.12, 0), SIMD2(0.4, 0.6)), (Float3(-0.01, -0.2, 0.03), SIMD2(0, 1))]

    init(faceUpScale: Float3) throws {
        let names = SourceFaceShapePose.destinationNames
        let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset + 1) })
        let faceBase = try #require(index["cf_J_FaceBase"]), faceUp = try #require(index["cf_J_FaceUp_ty"])
        let eye = try #require(index["cf_J_Eye_tz"])
        var nodes = [RigDefinition.Node(name: "head", sourceID: "head", parent: nil, translation: Float3(0, 1.4, 0))]
        nodes += names.enumerated().map { offset, name in
            let parent = name == "cf_J_FaceUp_ty" ? faceBase : (name == "cf_J_Eye_tz" ? faceUp : 0)
            return RigDefinition.Node(name: name, sourceID: "face-\(offset)", parent: parent, translation: Float3(0, 0.05, 0.01))
        }
        let mesh = nodes.count, hairA = mesh + 1, hairB = mesh + 2
        nodes += [RigDefinition.Node(name: "hair_mesh", sourceID: "hair-mesh", parent: faceUp, translation: Float3(0, 0.1, 0.05)),
                  RigDefinition.Node(name: "hair_a", sourceID: "hair-a", parent: faceUp, translation: Float3(0.03, 0.12, -0.02),
                                     rotation: simd_quatf(angle: 0.4, axis: Float3(0, 0, 1))),
                  RigDefinition.Node(name: "hair_b", sourceID: "hair-b", parent: hairA, translation: Float3(0, -0.15, 0.01),
                                     rotation: simd_quatf(angle: 0.3, axis: Float3(1, 0, 0)), scale: Float3(1, 1.2, 1))]
        let unskinned = try RigDefinition(nodes: nodes, skins: [])
        let bind = try unskinned.evaluate(unskinned.restPose).worldMatrices
        let inverseBinds = [hairA, hairB].map { simd_inverse(bind[$0]) * bind[mesh] }
        let rig = try RigDefinition(nodes: nodes, skins: [.init(name: "hair", meshNode: mesh, joints: [hairA, hairB], inverseBindMatrices: inverseBinds)])
        var state = Dictionary(uniqueKeysWithValues: names.map {
            ($0, SourceShapeTransform(position: Float3(0, 0.05, -0.01), rotationDegrees: .zero, scale: .one))
        })
        state["cf_J_FaceUp_ty"]!.scale = faceUpScale
        pose = try SourceFaceShapePose.make(rig: rig, state: state)
        self.rig = rig; self.mesh = mesh; self.faceUp = faceUp; self.eye = eye; bones = [hairA, hairB]
    }

    /// The hair vertices' positions in float64 (or `points` with the
    /// vertices' weights): the limit, as det → 0, of model · meshInverse ·
    /// world · inverseBind, which is world · inverseBind, over a world chain
    /// composed here from the pose's local matrices.
    func referencePositions(at points: [Float3]? = nil) -> [SIMD3<Double>] {
        func column(_ v: Float4) -> SIMD4<Double> { SIMD4(Double(v.x), Double(v.y), Double(v.z), Double(v.w)) }
        func double(_ m: float4x4) -> simd_double4x4 {
            simd_double4x4(columns: (column(m.columns.0), column(m.columns.1), column(m.columns.2), column(m.columns.3)))
        }
        var world = [simd_double4x4](repeating: matrix_identity_double4x4, count: rig.nodes.count)
        for index in rig.order {
            let local = double(pose.localMatrices[index])
            world[index] = rig.nodes[index].parent.map { world[$0] * local } ?? local
        }
        let skin = rig.skins[0]
        return vertices.enumerated().map { index, vertex in
            let point = points?[index] ?? vertex.position
            let p = SIMD4<Double>(Double(point.x), Double(point.y), Double(point.z), 1)
            var sum = SIMD4<Double>.zero
            for lane in 0..<2 { sum += (world[skin.joints[lane]] * double(skin.inverseBindMatrices[lane]) * p) * Double(vertex.weights[lane]) }
            return SIMD3(sum.x, sum.y, sum.z)
        }
    }
}

@Test func singularScaleFallbacksKeepEveryNonsingularMatrixBitIdentical() throws {
    var random = SingularScaleSeed(state: 404)
    func value(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &random) }
    func scale() -> Float { (Bool.random(using: &random) ? 1 : -1) * value(0.05...4) }
    func rotation() -> simd_quatf {
        simd_quatf(angle: value(-.pi ... .pi), axis: simd_normalize(Float3(value(-1...1), value(-1...1), value(0.1...1))))
    }
    let basis = UnityCoordinates.basis
    var checked = 0, reflected = 0, sheared = 0, mismatches: [String] = []
    for draw in 0..<4096 {
        var m = Transform.trs(Float3(value(-3...3), value(-3...3), value(-3...3)), rotation(), Float3(scale(), scale(), scale()))
        // A nonuniform parent above a rotated child: the sheared worlds a hierarchy produces.
        if draw % 2 == 1 { m = Transform.trs(Float3(value(-1...1), 0, 0), rotation(), Float3(scale(), scale(), scale())) * m; sheared += 1 }
        let determinant = simd_determinant(m.upperLeft3x3)
        guard abs(determinant) > Transform.singularDeterminant else { continue }
        checked += 1
        if determinant < 0 { reflected += 1 }
        if bits(Transform.normalMatrix(from: m)) != bits(referenceNormalMatrix(from: m)) { mismatches.append("normalMatrix \(draw)") }
        if bits(Transform.normalMatrix3(from: m)) != bits(referenceNormalMatrix3(from: m)) { mismatches.append("normalMatrix3 \(draw)") }
        if bits(Transform.inverseSafe(m)) != bits(m.inverse) { mismatches.append("inverseSafe \(draw)") }
        let worldToObject = try SourceShaderLiveEncoder.matrix("unity_WorldToObject", model: m, state: liveState)
        if bits(worldToObject) != bits((basis * m * basis).inverse) { mismatches.append("unity_WorldToObject \(draw)") }
        let q = m.collapseSafeRotationQuaternion, old = m.rotationQuaternion
        if (0..<4).contains(where: { q.vector[$0].bitPattern != old.vector[$0].bitPattern }) { mismatches.append("rotation \(draw)") }
        let unity = UnityCoordinates.matrix(m)
        if bits(SourceStudioEyeLookGeometry.Node(unityWorld: unity)) != bits(referenceEyeNode(unity)) { mismatches.append("eye node \(draw)") }
    }
    #expect(mismatches.isEmpty, "\(mismatches.prefix(8))")
    #expect(checked > 4000 && reflected > 1500 && sheared == 2048)
    // InverseSafe division: any scale above Vector3f::epsilon divides as before.
    for scale in [1e-5 * 1.0001, 0.37, -2.5, 1e5] {
        #expect(SourceStudioEyeLookSolver.inverseSafeQuotient(0.3, scale).bitPattern == (0.3 / scale).bitPattern)
    }
    #expect(SourceStudioEyeLookSolver.inverseSafeQuotient(0.3, 1e-5) == 0)
    #expect(SourceStudioEyeLookSolver.inverseSafeQuotient(0.3, 0) == 0)
    #expect(SourceStudioEyeLookSolver.inverseSafeQuotient(0.3, -0) == 0)
}

@Test func collapsedFaceUpGivesFiniteNormalWorldToObjectAndEyeLookValues() throws {
    let fixture = try CollapsedHairFixture(faceUpScale: Float3(0, 1, 1))
    let evaluation = try fixture.rig.evaluate(fixture.pose)
    #expect(evaluation.collapsedSkins == [0])
    #expect(evaluation.model(skin: 0, meshNode: fixture.mesh) == matrix_identity_float4x4)
    let world = evaluation.worldMatrices
    for node in [fixture.faceUp, fixture.eye, fixture.mesh] + fixture.bones {
        let m = world[node]
        #expect(abs(simd_determinant(m.upperLeft3x3)) <= Transform.singularDeterminant)
        // C: the normal matrix of a collapsed node is finite.
        #expect(isFinite(Transform.normalMatrix(from: m)) && isFinite(Transform.normalMatrix3(from: m)))
        // D: so is the source shaders' unity_WorldToObject.
        #expect(isFinite(try SourceShaderLiveEncoder.matrix("unity_WorldToObject", model: m, state: liveState)))
        #expect(isFinite(Transform.inverseSafe(m)))
    }
    // The hair renderer has no rotation above it: the collapsed surface's
    // normals point along world x, and InverseSafe maps a point back onto
    // the axes that remain (local x collapses to 0).
    let mesh = world[fixture.mesh]
    let collapsedNormal = Transform.normalMatrix3(from: mesh) * simd_normalize(Float3(1, 0.5, 0.25))
    #expect(simd_length(simd_normalize(collapsedNormal) - Float3(1, 0, 0)) < 1e-6)
    let local = Float4(0.3, -0.2, 0.1, 1), back = Transform.inverseSafe(mesh) * (mesh * local)
    #expect(simd_length(back - Float4(0, -0.2, 0.1, 1)) < 1e-5)
    // E: the eye center under the collapsed FaceUp_ty. The node keeps a unit
    // rotation, InverseTransformPoint maps the collapsed axis to 0, and the
    // correct targets stay finite.
    let center = SourceStudioEyeLookGeometry.Node(unityWorld: UnityCoordinates.matrix(world[fixture.eye]))
    #expect(center.lossyScale.x == 0)
    #expect(abs(simd_length(center.rotation.vector) - 1) < 1e-6)
    let target = SIMD3<Double>(0.1, 1.6, 3)
    let toLocal = try SourceStudioEyeLookSolver.worldToLocal(target, node: center)
    #expect(isFinite(toLocal) && toLocal.x == 0)
    let targets = try SourceStudioEyeLookSolver.correctEyeTargets(target: target, trfCenter: center, centerEyeLength: 0.05)
    #expect(targets.count == 2 && targets.allSatisfy(isFinite))
    // Before #404 InverseTransformPoint divided by this zero lossyScale.
    #expect(referenceEyeNode(UnityCoordinates.matrix(world[fixture.eye])).lossyScale.x == 0)
    #expect(!(toLocal.y / center.lossyScale.x).isFinite)
}

@Test func collapsedRendererRotationsRebuildTheMissingAxes() throws {
    let rotation = simd_quatf(angle: 0.7, axis: simd_normalize(Float3(0.2, 1, 0.4)))
    for collapsed in [Float3(0, 1.5, 0.5), Float3(2, 0, 1), Float3(1, 1, 0), Float3(0, 0, 3), Float3(0, 0, 0)] {
        let m = Transform.trs(Float3(1, 2, 3), rotation, collapsed)
        let q = m.collapseSafeRotationQuaternion
        #expect(abs(simd_length(q.vector) - 1) < 1e-6)
        let alive = (0..<3).filter { collapsed[$0] != 0 }.count
        if alive == 2 || alive == 3 {
            // One collapsed axis: the remaining ones fix the rotation exactly.
            #expect(min(simd_length(q.vector - rotation.vector), simd_length(q.vector + rotation.vector)) < 1e-5)
        } else if alive == 1 {
            // Two collapsed axes: the one left keeps its direction.
            let axis = (0..<3).first { collapsed[$0] != 0 }!
            var unit = Float3.zero; unit[axis] = 1
            #expect(simd_length(q.act(unit) - rotation.act(unit)) < 1e-5)
        } else {
            #expect(q.vector == simd_quatf(ix: 0, iy: 0, iz: 0, r: 1).vector)
        }
    }
}
