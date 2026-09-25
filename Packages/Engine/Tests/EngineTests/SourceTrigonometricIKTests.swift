import Foundation
import Testing
import simd
import CoreMath
import Scene

private func simpleIKPose() -> SourceTrigonometricIK.Pose {
    .init(root: .init(position: .zero), middle: .init(position: Float3(0, 1, 0)), end: .init(position: Float3(0, 2, 0)))
}

@Test func sourceTrigonometricIKPreservesLinkLengthsAndReachesTarget() throws {
    let pose = simpleIKPose()
    let solver = try SourceTrigonometricIK(pose: pose)
    let target = Float3(0, 1, -1)
    let result = try solver.solve(pose: pose, targetPosition: target, targetRotation: .identity)
    #expect(simd_length(result.end.position - target) < 1e-5)
    #expect(abs(simd_length(result.middle.position - result.root.position) - 1) < 1e-5)
    #expect(abs(simd_length(result.end.position - result.middle.position) - 1) < 1e-5)
}

@Test func sourceTrigonometricIKClampsWeightsAndSeparatesRotation() throws {
    let pose = simpleIKPose(), rotation = simd_quatf(angle: 0.7, axis: Float3(0, 1, 0))
    let solver = try SourceTrigonometricIK(pose: pose)
    let result = try solver.solve(pose: pose, targetPosition: Float3(0, 1, -1), targetRotation: rotation, positionWeight: -1, rotationWeight: 2)
    #expect(result.root.position == pose.root.position)
    #expect(result.middle.position == pose.middle.position)
    #expect(result.end.position == pose.end.position)
    #expect(abs(simd_dot(result.end.rotation.vector, rotation.vector)) > 0.99999)
}

@Test func sourceTrigonometricIKRejectsDegenerateInputs() throws {
    var pose = simpleIKPose()
    pose.middle.position = pose.root.position
    #expect(throws: SourceTrigonometricIKError.zeroLengthBone) { try SourceTrigonometricIK(pose: pose) }
    pose = simpleIKPose()
    #expect(throws: SourceTrigonometricIKError.degenerateLookRotation) {
        try SourceTrigonometricIK(pose: pose, bendNormal: Float3(0, 1, 0))
    }
    let solver = try SourceTrigonometricIK(pose: pose)
    #expect(throws: SourceTrigonometricIKError.nonFiniteInput) {
        try solver.solve(pose: pose, targetPosition: Float3(.nan, 1, 0), targetRotation: .identity)
    }
}

@Test func sourceTrigonometricIKBendNormalUsesAxialReflection() throws {
    let pose = simpleIKPose()
    var solver = try SourceTrigonometricIK(pose: pose)
    let goal = Float3(1, 1, 0), target = Float3(0, 1, -1)
    try solver.setBendGoalPosition(goal, targetPosition: target, pose: pose, weight: 1)
    #expect(simd_length(solver.bendNormal - simd_cross(goal, target)) < 1e-6)
    let normal = solver.bendNormal
    try solver.setBendGoalPosition(.zero, targetPosition: target, pose: pose, weight: 1)
    #expect(solver.bendNormal == normal) // Source ignores zero cross products.
}

@Test func sourceTrigonometricIKIndependentMatrixOracle() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_TRIGONOMETRIC_IK_REFERENCE"] else { return }
    struct Reference: Decodable {
        struct Pose: Decodable {
            var positions: [[Float]], rotations: [[Float]]
            func native() -> SourceTrigonometricIK.Pose {
                func bone(_ index: Int) -> SourceTrigonometricIK.Bone {
                    .init(position: SIMD3(positions[index]), rotation: simd_quatf(vector: SIMD4(rotations[index])))
                }
                return .init(root: bone(0), middle: bone(1), end: bone(2))
            }
        }
        struct Goal: Decodable { var position: [Float]; var weight: Float }
        struct Case: Decodable {
            var name: String, bindPose: Pose, pose: Pose
            var initialBendNormal: [Float], bendGoal: Goal?, setBendPlaneToCurrent: Bool
            var targetPosition: [Float], targetRotation: [Float], positionWeight: Float, rotationWeight: Float
            var expectedBendNormal: [Float], expectedPositions: [[Float]], expectedRotations: [[[Float]]]
        }
        var cases: [Case]
    }
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(reference.cases.count == 60)
    for item in reference.cases {
        var solver = try SourceTrigonometricIK(pose: item.bindPose.native(), bendNormal: SIMD3(item.initialBendNormal))
        let pose = item.pose.native(), target = Float3(item.targetPosition)
        if item.setBendPlaneToCurrent { try solver.setBendPlaneToCurrent(pose) }
        if let goal = item.bendGoal { try solver.setBendGoalPosition(Float3(goal.position), targetPosition: target, pose: pose, weight: goal.weight) }
        #expect(simd_length(solver.bendNormal - Float3(item.expectedBendNormal)) < 1e-5, "\(item.name)")
        let result = try solver.solve(pose: pose, targetPosition: target, targetRotation: simd_quatf(vector: Float4(item.targetRotation)), positionWeight: item.positionWeight, rotationWeight: item.rotationWeight)
        for (index, bone) in [result.root, result.middle, result.end].enumerated() {
            #expect(simd_length(bone.position - Float3(item.expectedPositions[index])) < 0.0001, "\(item.name), bone \(index)")
            let matrix = float3x3(bone.rotation)
            for row in 0..<3 {
                for column in 0..<3 {
                    #expect(abs(matrix[column][row] - item.expectedRotations[index][row][column]) < 0.0001, "\(item.name), bone \(index)")
                }
            }
        }
    }
}
