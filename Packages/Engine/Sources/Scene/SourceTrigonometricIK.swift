import Foundation
import simd
import CoreMath

public enum SourceTrigonometricIKError: Error, Equatable, LocalizedError {
    case nonFiniteInput
    case invalidQuaternion
    case zeroLengthBone
    case degenerateLookRotation
    public var errorDescription: String? {
        switch self {
        case .nonFiniteInput: "Trigonometric IK requires finite inputs."
        case .invalidQuaternion: "Trigonometric IK requires unit world rotations."
        case .zeroLengthBone: "Trigonometric IK requires two nonzero bone segments."
        case .degenerateLookRotation: "The source IK direction and bend normal do not define a unique rotation."
        }
    }
}

/// Source IKSolverTrigonometric's direct three-transform, rigid-chain kernel.
/// Input/output positions and rotations are already in the native basis. Bend
/// normals are axial vectors (UnityCoordinates.axialVector), not surface normals.
/// Nonuniform scale, intermediate hierarchy, rotation limits and FBBIK are not
/// represented here; a rig adapter must validate those conditions separately.
public struct SourceTrigonometricIK: Sendable {
    public struct Bone: Sendable {
        public var position: Float3
        public var rotation: simd_quatf
        public init(position: Float3, rotation: simd_quatf = .identity) { self.position = position; self.rotation = rotation }
    }
    public struct Pose: Sendable {
        public var root: Bone
        public var middle: Bone
        public var end: Bone
        public init(root: Bone, middle: Bone, end: Bone) { self.root = root; self.middle = middle; self.end = end }
    }
    private var sourceBendNormal: Float3
    private let rootTargetToLocal: simd_quatf
    private let middleTargetToLocal: simd_quatf
    private let rootDefaultLocalNormal: Float3
    private let middleDefaultLocalNormal: Float3
    public var bendNormal: Float3 { UnityCoordinates.axialVector(sourceBendNormal) }
    private static let sourceZeroSquared: Float = 9.99999944e-11

    public init(pose: Pose, bendNormal: Float3 = Float3(-1, 0, 0)) throws {
        try Self.validate(pose)
        guard Self.finite(bendNormal) else { throw SourceTrigonometricIKError.nonFiniteInput }
        let p = Self.convert(pose)
        var normal = UnityCoordinates.axialVector(bendNormal)
        if Self.sourceZero(normal) { normal = Float3(1, 0, 0) }
        let firstLook = try Self.look(p.middle.position - p.root.position, normal)
        let secondLook = try Self.look(p.end.position - p.middle.position, normal)
        // QuaTools.RotationToLocalSpace(space, rotation) = inverse(rotation) * space.
        rootTargetToLocal = firstLook.inverse * p.root.rotation
        middleTargetToLocal = secondLook.inverse * p.middle.rotation
        rootDefaultLocalNormal = p.root.rotation.inverse.act(normal)
        middleDefaultLocalNormal = p.middle.rotation.inverse.act(normal)
        let currentPlane = simd_cross(p.middle.position - p.root.position, p.end.position - p.middle.position)
        sourceBendNormal = Self.sourceZero(currentPlane) ? normal : currentPlane
    }

    public mutating func setBendPlaneToCurrent(_ pose: Pose) throws {
        try Self.validate(pose)
        let p = Self.convert(pose)
        let normal = simd_cross(p.middle.position - p.root.position, p.end.position - p.middle.position)
        if !Self.sourceZero(normal) { sourceBendNormal = normal }
    }

    public mutating func setBendGoalPosition(_ goal: Float3, targetPosition: Float3, pose: Pose, weight: Float) throws {
        try Self.validate(pose)
        guard Self.finite(goal), Self.finite(targetPosition), weight.isFinite else { throw SourceTrigonometricIKError.nonFiniteInput }
        guard weight > 0 else { return }
        let root = UnityCoordinates.position(pose.root.position)
        let normal = simd_cross(UnityCoordinates.position(goal) - root, UnityCoordinates.position(targetPosition) - root)
        if !Self.sourceZero(normal) {
            sourceBendNormal = weight >= 1 ? normal : Self.lerp(sourceBendNormal, normal, weight)
        }
    }

    public func solve(pose: Pose, targetPosition: Float3, targetRotation: simd_quatf,
                      positionWeight: Float = 1, rotationWeight: Float = 1) throws -> Pose {
        try Self.validate(pose)
        guard Self.finite(targetPosition), positionWeight.isFinite, rotationWeight.isFinite else { throw SourceTrigonometricIKError.nonFiniteInput }
        try Self.validate(targetRotation)
        var p = Self.convert(pose)
        let target = UnityCoordinates.position(targetPosition)
        let targetQ = UnityCoordinates.rotation(targetRotation)
        let w = min(1, max(0, positionWeight)), rw = min(1, max(0, rotationWeight))
        if w > 0 {
            let firstSquared = simd_length_squared(p.middle.position - p.root.position)
            let secondSquared = simd_length_squared(p.end.position - p.middle.position)
            let weightedTarget = Self.lerp(p.end.position, target, w)
            let normal = Self.lerp(p.root.rotation.act(rootDefaultLocalNormal), sourceBendNormal, w)
            let targetDirection = weightedTarget - p.root.position
            var bendDirection = Float3.zero
            if !Self.sourceZero(targetDirection) {
                let distanceSquared = simd_length_squared(targetDirection)
                let distance = sqrt(distanceSquared)
                let along = (distanceSquared + firstSquared - secondSquared) / 2 / distance
                let height = sqrt(max(0, firstSquared - along * along))
                let upward = simd_cross(targetDirection, normal)
                bendDirection = try Self.look(targetDirection, upward).act(Float3(0, height, along))
            }
            var direction = Self.lerp(p.middle.position - p.root.position, bendDirection, w)
            if Self.sourceZero(direction) { direction = p.middle.position - p.root.position }
            let rootRotation = (try Self.look(direction, normal) * rootTargetToLocal).normalized
            let firstDelta = rootRotation * p.root.rotation.inverse
            // Unity world-rotation assignment propagates through both descendants.
            p.middle.position = p.root.position + firstDelta.act(p.middle.position - p.root.position)
            p.end.position = p.root.position + firstDelta.act(p.end.position - p.root.position)
            p.middle.rotation = (firstDelta * p.middle.rotation).normalized
            p.end.rotation = (firstDelta * p.end.rotation).normalized
            p.root.rotation = rootRotation
            let middleNormal = p.middle.rotation.act(middleDefaultLocalNormal)
            let middleRotation = (try Self.look(weightedTarget - p.middle.position, middleNormal) * middleTargetToLocal).normalized
            let secondDelta = middleRotation * p.middle.rotation.inverse
            p.end.position = p.middle.position + secondDelta.act(p.end.position - p.middle.position)
            p.end.rotation = (secondDelta * p.end.rotation).normalized
            p.middle.rotation = middleRotation
        }
        if rw > 0 { p.end.rotation = simd_slerp(p.end.rotation, targetQ, rw).normalized }
        try Self.validate(p)
        return Self.convert(p)
    }

    private static func finite(_ v: Float3) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
    private static func sourceZero(_ v: Float3) -> Bool { simd_length_squared(v) < sourceZeroSquared }
    private static func lerp(_ a: Float3, _ b: Float3, _ t: Float) -> Float3 { a + (b - a) * t }
    private static func validate(_ q: simd_quatf) throws {
        let v = q.vector
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite, v.w.isFinite else { throw SourceTrigonometricIKError.nonFiniteInput }
        guard abs(simd_length_squared(v) - 1) < 0.001 else { throw SourceTrigonometricIKError.invalidQuaternion }
    }
    private static func validate(_ pose: Pose) throws {
        for bone in [pose.root, pose.middle, pose.end] {
            guard finite(bone.position) else { throw SourceTrigonometricIKError.nonFiniteInput }
            try validate(bone.rotation)
        }
        guard !sourceZero(pose.middle.position - pose.root.position), !sourceZero(pose.end.position - pose.middle.position) else {
            throw SourceTrigonometricIKError.zeroLengthBone
        }
    }
    private static func convert(_ pose: Pose) -> Pose {
        func bone(_ b: Bone) -> Bone { .init(position: UnityCoordinates.position(b.position), rotation: UnityCoordinates.rotation(b.rotation)) }
        return .init(root: bone(pose.root), middle: bone(pose.middle), end: bone(pose.end))
    }
    private static func look(_ forward: Float3, _ up: Float3) throws -> simd_quatf {
        guard finite(forward), finite(up), !sourceZero(forward), !sourceZero(up) else { throw SourceTrigonometricIKError.degenerateLookRotation }
        let f = simd_normalize(forward), right = simd_cross(up, f)
        guard !sourceZero(right) else { throw SourceTrigonometricIKError.degenerateLookRotation }
        let r = simd_normalize(right), u = simd_cross(f, r)
        return simd_quatf(float3x3(r, u, f)).normalized
    }
}
