import Testing
import CoreMath
import simd

private func approximatelyEqual(_ a: float4x4, _ b: float4x4, tolerance: Float = 1e-5) -> Bool {
    (0..<4).allSatisfy { simd_length(a[$0] - b[$0]) < tolerance }
}

@Test func unityConversionPreservesMagnitudesAndRoundTrips() {
    let vector = Float3(1.5, -2, 3.25)
    #expect(UnityCoordinates.position(vector) == Float3(1.5, -2, -3.25))
    #expect(UnityCoordinates.position(UnityCoordinates.position(vector)) == vector)
    #expect(UnityCoordinates.direction(.zero) == .zero)
    #expect(UnityCoordinates.normal(vector) == UnityCoordinates.direction(vector))
    #expect(simd_length(UnityCoordinates.normal(vector)) == simd_length(vector))
    let tangent = Float4(0.2, 0.3, 0.4, -1)
    #expect(UnityCoordinates.tangent(UnityCoordinates.tangent(tangent)) == tangent)
    #expect(UnityCoordinates.axialVector(UnityCoordinates.axialVector(vector)) == vector)
}

@Test func unityQuaternionConversionCommutesWithRotatingVectors() {
    let axes = [Float3(1, 0, 0), Float3(0, 1, 0), Float3(0, 0, 1), simd_normalize(Float3(1, -2, 3))]
    let vector = Float3(2, 3, -5)
    for axis in axes {
        for angle: Float in [0, 0.4, -.pi / 2, .pi] {
            let source = simd_quatf(angle: angle, axis: axis)
            let converted = UnityCoordinates.rotation(source)
            #expect(simd_length(converted.act(UnityCoordinates.direction(vector))
                - UnityCoordinates.direction(source.act(vector))) < 1e-5)
            #expect(approximatelyEqual(float4x4(converted), UnityCoordinates.matrix(float4x4(source))))
            #expect(simd_length(UnityCoordinates.rotation(converted).vector - source.vector) < 1e-6)
        }
    }
}

@Test func unityTangentConversionPreservesBitangent() {
    let normal = simd_normalize(Float3(1, 2, -3))
    let tangent = simd_normalize(simd_cross(normal, Float3(0, 1, 0)))
    for handedness: Float in [-1, 1] {
        let sourceBitangent = simd_cross(normal, tangent) * handedness
        let convertedTangent = UnityCoordinates.tangent(Float4(tangent, handedness))
        let targetBitangent = simd_cross(UnityCoordinates.normal(normal),
            Float3(convertedTangent.x, convertedTangent.y, convertedTangent.z)) * convertedTangent.w
        #expect(simd_length(targetBitangent - UnityCoordinates.direction(sourceBitangent)) < 1e-6)
    }
}

@Test func unityEulerDegreesUsesZThenXThenY() {
    // An asymmetric vector and all three axes distinguish ZXY from engine XYZ.
    let source = Float3(2, 3, 5)
    let zThenXThenY = Transform.rotationY(Float(70).degreesToRadians)
        * Transform.rotationX(Float(20).degreesToRadians)
        * Transform.rotationZ(Float(-30).degreesToRadians)
    let converted = UnityCoordinates.eulerDegrees(Float3(20, 70, -30))
    #expect(simd_length(converted.act(UnityCoordinates.direction(source))
        - UnityCoordinates.direction(zThenXThenY.transformDirection(source))) < 1e-5)
    let yaw = UnityCoordinates.eulerDegrees(Float3(0, 90, 0))
    #expect(simd_length(yaw.act(Float3(0, 0, -1)) - Float3(1, 0, 0)) < 1e-5)
}

@Test func unityTriangleConversionPreservesSurfaceOrientation() throws {
    // Deliberately use a triangle not parallel to any basis plane.
    let points = [Float3(1, 0, 2), Float3(3, 1, 4), Float3(-1, 3, 1)]
    let sourceNormal = simd_normalize(simd_cross(points[1] - points[0], points[2] - points[0]))
    let converted = points.map(UnityCoordinates.position)
    let indices = try UnityCoordinates.triangleIndices([0, 1, 2])
    let a = converted[Int(indices[0])], b = converted[Int(indices[1])], c = converted[Int(indices[2])]
    let targetNormal = simd_normalize(simd_cross(b - a, c - a))
    #expect(simd_length(targetNormal - UnityCoordinates.normal(sourceNormal)) < 1e-6)
    #expect(try UnityCoordinates.triangleIndices(indices) == [0, 1, 2])
    #expect(try UnityCoordinates.triangleIndices([]).isEmpty)
    #expect(try UnityCoordinates.triangleIndices([0, 1, 2, 2, 1, 3]) == [0, 2, 1, 2, 3, 1])
    #expect(throws: UnityCoordinates.ConversionError.incompleteTriangle(indexCount: 2)) {
        try UnityCoordinates.triangleIndices([0, 1])
    }
}

@Test func unityMatrixConversionPreservesHierarchySignedScaleAndShear() {
    let parent = Transform.trs(Float3(2, 4, -3), simd_quatf(eulerXYZ: Float3(0.2, -0.7, 0.4)), Float3(-2, 3, 0.5))
    var child = Transform.trs(Float3(-1, 2, 3), simd_quatf(eulerXYZ: Float3(-0.3, 0.9, 0.2)), Float3(2, 0.5, 1.5))
    child.columns.1 += child.columns.0 * 0.2
    let world = parent * child
    let convertedWorld = UnityCoordinates.matrix(parent) * UnityCoordinates.matrix(child)
    #expect(approximatelyEqual(convertedWorld, UnityCoordinates.matrix(world)))
    #expect(approximatelyEqual(UnityCoordinates.matrix(UnityCoordinates.matrix(world)), world))
    let point = Float3(1, -2, 3)
    #expect(simd_length(convertedWorld.transformPoint(UnityCoordinates.position(point))
        - UnityCoordinates.position(world.transformPoint(point))) < 1e-5)
    let n = simd_normalize(Float3(2, 3, 4))
    let targetNormal = Transform.normalMatrix3(from: convertedWorld) * UnityCoordinates.normal(n)
    let expectedNormal = UnityCoordinates.normal(Transform.normalMatrix3(from: world) * n)
    #expect(simd_length(targetNormal - expectedNormal) < 1e-5)
}

@Test func unityConversionCommutesWithSkinningAndMorphs() {
    let bind = Transform.trs(Float3(1, 2, 3), simd_quatf(eulerXYZ: Float3(0.1, 0.2, -0.4)), Float3(repeating: 1))
    let animated = Transform.trs(Float3(-3, 1, 2), simd_quatf(eulerXYZ: Float3(-0.3, 0.4, 0.2)), Float3(1.2, 0.8, 1.1))
    let skin = animated * bind.inverse
    let convertedSkin = UnityCoordinates.matrix(animated) * UnityCoordinates.matrix(bind.inverse)
    #expect(approximatelyEqual(convertedSkin, UnityCoordinates.matrix(skin)))
    let point = Float3(2, 3, 4), delta = Float3(0.2, -0.4, 0.3)
    let morphed = point + delta * 0.35
    let targetMorphed = UnityCoordinates.position(point) + UnityCoordinates.direction(delta) * 0.35
    #expect(simd_length(convertedSkin.transformPoint(targetMorphed)
        - UnityCoordinates.position(skin.transformPoint(morphed))) < 1e-5)
}

@Test func unityAxialVectorsPreserveCrossProducts() {
    let a = Float3(2, -1, 4), b = Float3(-3, 2, 1)
    #expect(UnityCoordinates.axialVector(simd_cross(a, b))
        == simd_cross(UnityCoordinates.direction(a), UnityCoordinates.direction(b)))
}
