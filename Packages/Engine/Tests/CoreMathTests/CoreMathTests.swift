//
//  CoreMathTests.swift
//  Engine
//
//  Created by rumpology on 8/19/26.
//

import Testing
import CoreMath
import ShaderTypes
import simd

@Test func frameUniformsStride() {
    #expect(MemoryLayout<FrameUniforms>.stride == 560)
}

@Test func drawUniformsStride() {
    #expect(MemoryLayout<DrawUniforms>.stride == 144)
}

@Test func reverseZMapsNearToOneAndFarToZero() {
    let p = Projection.perspectiveReverseZ(
        fovyRadians: .pi / 3, aspect: 16.0 / 9.0, near: 0.1, far: 1000)

    let atNear = p * SIMD4<Float>(0, 0, -0.1, 1)
    let atFar  = p * SIMD4<Float>(0, 0, -1000, 1)

    #expect(abs(atNear.z / atNear.w - 1) < 1e-4)
    #expect(abs(atFar.z / atFar.w) < 1e-4)
}

@Test func infiniteReverseZMapsNearToOne() {
    let p = Projection.perspectiveReverseZInfinite(
        fovyRadians: .pi / 3, aspect: 1, near: 0.1)
    let atNear = p * SIMD4<Float>(0, 0, -0.1, 1)
    #expect(abs(atNear.z / atNear.w - 1) < 1e-4)

    let farAway = p * SIMD4<Float>(0, 0, -1e6, 1)
    #expect(farAway.z / farAway.w < 1e-5)
}

// MARK: - Checked contracts (R4): accepted input returns exactly the unchecked result.

@Test func checkedNormalizedMatchesNormalizeAndRejectsDegenerateVectors() throws {
    for vector in [Float3(3, -4, 12), Float3(1e-5, 0, 0), Float3(-2e6, 1, 0.5)] {
        #expect(try vector.checkedNormalized() == normalize(vector))
    }
    #expect(throws: MathContractError.degenerateDirection("v")) { try Float3.zero.checkedNormalized("v") }
    #expect(throws: MathContractError.degenerateDirection("v")) { try Float3(1e-7, 0, -1e-7).checkedNormalized("v") }
    #expect(throws: MathContractError.nonfinite("v")) { try Float3(.nan, 0, 1).checkedNormalized("v") }
    #expect(throws: MathContractError.nonfinite("v")) { try Float3(0, -.infinity, 1).checkedNormalized("v") }
    // Finite components whose squared length overflows are not normalizable either.
    #expect(throws: MathContractError.nonfinite("v")) { try Float3(3e38, 3e38, 0).checkedNormalized("v") }
}

@Test func checkedRotationMatchesShortestArcAndRejectsDegenerateDirections() throws {
    let pairs: [(Float3, Float3)] = [(Float3(0, 0, 1), Float3(0.3, -0.4, 2)), (Float3(1, 0, 0), Float3(-3, 0, 0)),
                                     (Float3(0, 2, 0), Float3(0, 5, 0)), (Float3(2, -1, 0.5), Float3(-0.2, 0.7, 4))]
    for (from, to) in pairs {
        let checked = try simd_quatf.checkedRotation(from: from, to: to)
        #expect(checked.vector == simd_quatf.rotation(from: from, to: to).vector)
        #expect(simd_length(checked.act(normalize(from)) - normalize(to)) < 1e-5)
    }
    #expect(throws: MathContractError.degenerateDirection("rotation from")) {
        try simd_quatf.checkedRotation(from: .zero, to: Float3(0, 0, 1))
    }
    #expect(throws: MathContractError.degenerateDirection("rotation to")) {
        try simd_quatf.checkedRotation(from: Float3(0, 0, 1), to: Float3(0, 1e-8, 0))
    }
    #expect(throws: MathContractError.nonfinite("rotation to")) {
        try simd_quatf.checkedRotation(from: Float3(0, 0, 1), to: Float3(.nan, 0, 0))
    }
}

@Test func checkedLookRotationMatchesLookRotationAndRejectsDegenerateBases() throws {
    // The last pair exercises the parallel-up fallback, which is still defined here.
    let cases: [(Float3, Float3)] = [(Float3(0, 0, 1), Float3(0, 1, 0)), (Float3(1, 2, -3), Float3(0.2, 1, 0)),
                                     (Float3(0, 1, 0), Float3(0, 3, 0))]
    for (forward, up) in cases {
        let checked = try simd_quatf.checkedLookRotation(forward: forward, up: up)
        #expect(checked.vector == simd_quatf.lookRotation(forward: forward, up: up).vector)
        #expect(simd_length(checked.forward - normalize(forward)) < 1e-5)
    }
    #expect(throws: MathContractError.degenerateDirection("look forward")) { try simd_quatf.checkedLookRotation(forward: .zero) }
    #expect(throws: MathContractError.degenerateDirection("look up")) {
        try simd_quatf.checkedLookRotation(forward: Float3(0, 0, 1), up: .zero)
    }
    #expect(throws: MathContractError.nonfinite("look forward")) {
        try simd_quatf.checkedLookRotation(forward: Float3(0, .infinity, 1))
    }
    // An up parallel to forward falls back to +X, which has no perpendicular when forward is along X too.
    #expect(throws: MathContractError.degenerateDirection("look basis")) {
        try simd_quatf.checkedLookRotation(forward: Float3(-1, 0, 0), up: Float3(2, 0, 0))
    }
}

@Test func checkedInverseMatchesInverseAndRejectsSingularMatrices() throws {
    let matrix = Transform.trs(Float3(1, -2, 3), simd_quatf(angle: 0.7, axis: normalize(Float3(1, 2, 3))), Float3(2, -0.5, 3))
    #expect(try matrix.checkedInverse() == matrix.inverse)
    #expect(throws: MathContractError.singularMatrix("scale")) { try Transform.scale(Float3(1, 0, 1)).checkedInverse("scale") }
    var nonfinite = matrix
    nonfinite.columns.2.y = .nan
    #expect(throws: MathContractError.nonfinite("matrix")) { try nonfinite.checkedInverse() }
}

@Test func checkedDecompositionKeepsReflectionsAndRejectsShear() throws {
    let rotation = simd_quatf(angle: 0.9, axis: normalize(Float3(-1, 2, 0.5)))
    let translation = Float3(0.5, 1, -2), scale = Float3(2, 0.5, 3)
    let rigid = Transform.trs(translation, rotation, scale)
    let trs = try rigid.checkedTRS()
    #expect(trs.translation == rigid.translation && trs.scale == rigid.scaleFactors)
    #expect(trs.rotation.vector == rigid.rotationQuaternion.vector)
    #expect(try rigid.checkedRotationQuaternion().vector == rigid.rotationQuaternion.vector)

    // A reflection survives as a negative X scale and `Transform.trs` rebuilds the matrix.
    for signs in [Float3(-1, 1, 1), Float3(1, -1, 1), Float3(1, 1, -1), Float3(-1, -1, -1)] {
        let reflected = Transform.trs(translation, rotation, scale * signs)
        let decomposed = try reflected.checkedTRS()
        #expect(decomposed.scale.x < 0 && decomposed.scale.y > 0 && decomposed.scale.z > 0)
        #expect(abs(simd_length(decomposed.rotation.vector) - 1) < 1e-5)
        let rebuilt = Transform.trs(decomposed.translation, decomposed.rotation, decomposed.scale)
        for column in 0..<4 { #expect(simd_length(rebuilt[column] - reflected[column]) < 1e-5) }
        #expect(throws: MathContractError.reflectedMatrix("matrix")) { try reflected.checkedRotationQuaternion() }
    }

    var shear = matrix_identity_float4x4
    shear[1].x = 0.25
    #expect(throws: MathContractError.unsupportedMatrix("matrix")) { try (rigid * shear).checkedTRS() }
    #expect(throws: MathContractError.unsupportedMatrix("matrix")) { try (rigid * shear).checkedRotationQuaternion() }
    var projective = rigid
    projective.columns.0.w = 0.5
    #expect(throws: MathContractError.unsupportedMatrix("matrix")) { try projective.checkedTRS() }
    #expect(throws: MathContractError.singularMatrix("root")) { try Transform.scale(Float3(1, 0, 1)).checkedTRS("root") }
    var dependent = matrix_identity_float4x4
    dependent.columns.1 = dependent.columns.0
    #expect(throws: MathContractError.singularMatrix("matrix")) { try dependent.checkedTRS() }
    var nonfinite = rigid
    nonfinite.columns.3.x = .infinity
    #expect(throws: MathContractError.nonfinite("matrix")) { try nonfinite.checkedTRS() }
}

// MARK: - Checked rays and projections (R4)

@Test func checkedRayMatchesInitAndRejectsDegenerateInput() throws {
    let rays: [(Float3, Float3)] = [(Float3(0, 1, 5), Float3(0, 0, -3)), (Float3(-2, 0.5, 1), Float3(1e-5, 2, -0.5))]
    for (origin, direction) in rays {
        let checked = try Ray.checked(origin: origin, direction: direction)
        let plain = Ray(origin: origin, direction: direction)
        #expect(checked.origin == plain.origin && checked.direction == plain.direction && checked.isFinite)
    }
    #expect(throws: MathContractError.degenerateDirection("ray direction")) { try Ray.checked(origin: .zero, direction: .zero) }
    #expect(throws: MathContractError.nonfinite("ray direction")) { try Ray.checked(origin: .zero, direction: Float3(.nan, 0, 1)) }
    #expect(throws: MathContractError.nonfinite("ray origin")) {
        try Ray.checked(origin: Float3(0, .infinity, 0), direction: Float3(0, 0, 1))
    }

    let ray = Ray(origin: Float3(0.5, -1, 2), direction: Float3(0, 1, -1))
    let rigid = Transform.trs(Float3(1, 2, 3), simd_quatf(angle: 0.6, axis: normalize(Float3(1, 1, 0))), Float3(2, 0.5, 1))
    let moved = try ray.checkedTransformed(by: rigid)
    let plainMoved = ray.transformed(by: rigid)
    #expect(moved.origin == plainMoved.origin && moved.direction == plainMoved.direction)
    // A singular matrix flattens the direction; a projective w of zero sends the origin to infinity.
    #expect(throws: MathContractError.degenerateDirection("ray direction")) {
        try ray.checkedTransformed(by: Transform.scale(Float3(1, 0, 0)))
    }
    var projective = matrix_identity_float4x4
    projective.columns.3.w = 0
    #expect(throws: MathContractError.nonfinite("ray origin")) { try ray.checkedTransformed(by: projective) }
}

@Test func nonfiniteRaysHitNothingWhileFiniteRaysKeepTheirResults() {
    let box = AABB(min: Float3(-1, -1, -1), max: Float3(1, 1, 1))
    let a = Float3(-1, -1, 0), b = Float3(1, -1, 0), c = Float3(0, 1, 0)
    let finite = Ray(origin: Float3(0, 0, 5), direction: Float3(0, 0, -1))
    #expect(finite.isFinite)
    #expect(abs((finite.intersect(box) ?? -1) - 4) < 1e-5)
    #expect(abs((finite.intersectSphere(center: .zero, radius: 1) ?? -1) - 4) < 1e-5)
    #expect(abs((finite.intersectPlane(point: .zero, normal: Float3(0, 0, 1)) ?? -1) - 5) < 1e-5)
    #expect(abs((finite.intersectTriangle(a, b, c) ?? -1) - 5) < 1e-5)
    #expect(abs(finite.distance(toPoint: Float3(1, 0, 0)) - 1) < 1e-5)
    #expect(finite.closest(toSegment: Float3(-1, 0, 0), Float3(1, 0, 0)).distance < 1e-5)
    // A zero direction normalizes to NaN; the slab test used to keep its
    // initial interval for NaN distances and report a hit at 0 for any box.
    let zeroDirection = Ray(origin: Float3(0, 0, 5), direction: .zero)
    let nonfiniteOrigin = Ray(origin: Float3(.infinity, 0, 0), direction: Float3(-1, 0, 0))
    for ray in [zeroDirection, nonfiniteOrigin] {
        #expect(!ray.isFinite)
        let misses = ray.intersect(box) == nil && ray.intersectSphere(center: .zero, radius: 1) == nil
            && ray.intersectPlane(point: .zero, normal: Float3(1, 0, 0)) == nil && ray.intersectTriangle(a, b, c) == nil
        #expect(misses)
        #expect(ray.distance(toPoint: .zero) == .infinity)
        #expect(ray.closest(toSegment: Float3(-1, 0, 0), Float3(1, 0, 0)).distance == .infinity)
    }
}

@Test func checkedProjectionsMatchUncheckedAndRejectDegenerateLenses() throws {
    #expect(try Projection.checkedPerspectiveReverseZ(fovyRadians: 0.9, aspect: 1.5, near: 0.05, far: 200)
        == Projection.perspectiveReverseZ(fovyRadians: 0.9, aspect: 1.5, near: 0.05, far: 200))
    #expect(try Projection.checkedPerspectiveReverseZInfinite(fovyRadians: 2.5, aspect: 0.75, near: 0.01)
        == Projection.perspectiveReverseZInfinite(fovyRadians: 2.5, aspect: 0.75, near: 0.01))
    #expect(try Projection.checkedOrthographicReverseZ(left: -2, right: 3, bottom: -1, top: 1.5, near: 0.05, far: 9)
        == Projection.orthographicReverseZ(left: -2, right: 3, bottom: -1, top: 1.5, near: 0.05, far: 9))
    // A mirrored pair of bounds is a valid, flipped projection.
    #expect(try Projection.checkedOrthographicReverseZ(left: 1, right: -1, bottom: -1, top: 1, near: 0.05, far: 9)
        == Projection.orthographicReverseZ(left: 1, right: -1, bottom: -1, top: 1, near: 0.05, far: 9))

    let fieldsOfView: [Float] = [0, -0.5, .pi, 4]
    for fov in fieldsOfView {
        #expect(throws: MathContractError.outOfRange("field of view")) {
            try Projection.checkedPerspectiveReverseZInfinite(fovyRadians: fov, aspect: 1, near: 0.05)
        }
    }
    #expect(throws: MathContractError.nonfinite("field of view")) {
        try Projection.checkedPerspectiveReverseZ(fovyRadians: .nan, aspect: 1, near: 0.05, far: 10)
    }
    #expect(throws: MathContractError.outOfRange("aspect ratio")) {
        try Projection.checkedPerspectiveReverseZ(fovyRadians: 1, aspect: 0, near: 0.05, far: 10)
    }
    #expect(throws: MathContractError.outOfRange("near plane")) {
        try Projection.checkedPerspectiveReverseZInfinite(fovyRadians: 1, aspect: 1, near: 0)
    }
    #expect(throws: MathContractError.outOfRange("far plane")) {
        try Projection.checkedPerspectiveReverseZ(fovyRadians: 1, aspect: 1, near: 1, far: 1)
    }
    #expect(throws: MathContractError.nonfinite("far plane")) {
        try Projection.checkedPerspectiveReverseZ(fovyRadians: 1, aspect: 1, near: 1, far: .infinity)
    }
    // A field of view so narrow that its focal length overflows.
    #expect(throws: MathContractError.nonfinite("perspective projection")) {
        try Projection.checkedPerspectiveReverseZInfinite(fovyRadians: .leastNonzeroMagnitude, aspect: 1, near: 0.05)
    }
    #expect(throws: MathContractError.outOfRange("orthographic width")) {
        try Projection.checkedOrthographicReverseZ(left: 1, right: 1, bottom: -1, top: 1, near: 0.05, far: 9)
    }
    #expect(throws: MathContractError.outOfRange("orthographic depth range")) {
        try Projection.checkedOrthographicReverseZ(left: -1, right: 1, bottom: -1, top: 1, near: 2, far: 2)
    }
    #expect(throws: MathContractError.nonfinite("orthographic top")) {
        try Projection.checkedOrthographicReverseZ(left: -1, right: 1, bottom: -1, top: .nan, near: 0.05, far: 9)
    }
    #expect(throws: MathContractError.nonfinite("orthographic projection")) {
        try Projection.checkedOrthographicReverseZ(left: 0, right: .leastNonzeroMagnitude, bottom: -1, top: 1, near: 0.05, far: 9)
    }
}

@Test func checkedLookAtMatchesLookAtAndRejectsDegenerateViews() throws {
    let eye = Float3(1, 2, 3), center = Float3(0, 1, 0), up = Float3(0, 1, 0)
    #expect(try Projection.checkedLookAt(eye: eye, center: center, up: up) == Projection.lookAt(eye: eye, center: center, up: up))
    // Looking straight down takes the +Z fallback up, which is still defined (the shadow light's case).
    let above = Float3(0, 5, 0)
    #expect(try Projection.checkedLookAt(eye: above, center: .zero, up: up) == Projection.lookAt(eye: above, center: .zero, up: up))
    #expect(throws: MathContractError.degenerateDirection("look-at view direction")) {
        try Projection.checkedLookAt(eye: center, center: center, up: up)
    }
    #expect(throws: MathContractError.degenerateDirection("look-at up")) { try Projection.checkedLookAt(eye: eye, center: center, up: .zero) }
    #expect(throws: MathContractError.nonfinite("look-at eye")) {
        try Projection.checkedLookAt(eye: Float3(.nan, 0, 0), center: center, up: up)
    }
    #expect(throws: MathContractError.nonfinite("look-at center")) {
        try Projection.checkedLookAt(eye: eye, center: Float3(0, -.infinity, 0), up: up)
    }
    // Viewing along Z with an up along Z: the +Z fallback is parallel too, and the unchecked form returns NaN.
    let alongZ = Float3(0, 0, 4), upZ = Float3(0, 0, 2)
    #expect(throws: MathContractError.degenerateDirection("look-at basis")) {
        try Projection.checkedLookAt(eye: alongZ, center: .zero, up: upZ)
    }
    #expect(!Projection.lookAt(eye: alongZ, center: .zero, up: upZ)[0][0].isFinite)
}
