import Foundation
import simd

public enum Projection {
    /// Right-handed, reverse-Z, Metal NDC depth [0,1] with near→1, far→0.
    public static func perspectiveReverseZ(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let f = 1 / tan(fovyRadians * 0.5)
        let a = near / (far - near)
        let b = (near * far) / (far - near)
        return float4x4(Float4(f / aspect, 0, 0, 0), Float4(0, f, 0, 0), Float4(0, 0, a, -1), Float4(0, 0, b, 0))
    }

    /// Infinite far plane; best depth precision.
    public static func perspectiveReverseZInfinite(fovyRadians: Float, aspect: Float, near: Float) -> float4x4 {
        let f = 1 / tan(fovyRadians * 0.5)
        return float4x4(Float4(f / aspect, 0, 0, 0), Float4(0, f, 0, 0), Float4(0, 0, 0, -1), Float4(0, 0, near, 0))
    }

    /// Orthographic reverse-Z (near→1, far→0), right-handed looking down -Z.
    public static func orthographicReverseZ(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> float4x4 {
        let sx = 2 / (right - left)
        let sy = 2 / (top - bottom)
        let sz = 1 / (far - near)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        // z_ndc = (z_view + far) / (far - near)  →  view z = -near → 1, -far → 0
        return float4x4(Float4(sx, 0, 0, 0), Float4(0, sy, 0, 0), Float4(0, 0, sz, 0), Float4(tx, ty, far * sz, 1))
    }

    public static func lookAt(eye: Float3, center: Float3, up: Float3) -> float4x4 {
        let z = normalize(eye - center)
        var upv = up
        if abs(dot(normalize(upv), z)) > 0.999 { upv = Float3(0, 0, 1) }
        let x = normalize(cross(upv, z))
        let y = cross(z, x)
        return float4x4(Float4(x.x, y.x, z.x, 0), Float4(x.y, y.y, z.y, 0), Float4(x.z, y.z, z.z, 0),
                        Float4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1))
    }

    // MARK: - Checked forms (R4)

    // The unchecked builders above keep their formulas and assume a usable
    // lens and view. These throw `MathContractError` naming the argument
    // instead of returning a nonfinite matrix, and otherwise return exactly the
    // unchecked result.

    /// Checked `perspectiveReverseZ`: the vertical field of view must be in
    /// (0, π), `aspect` and `near` positive and `far` greater than `near`, all
    /// finite, and the result finite.
    public static func checkedPerspectiveReverseZ(fovyRadians: Float, aspect: Float, near: Float, far: Float) throws -> float4x4 {
        try checkLens(fovyRadians: fovyRadians, aspect: aspect, near: near)
        guard far.isFinite else { throw MathContractError.nonfinite("far plane") }
        guard far > near else { throw MathContractError.outOfRange("far plane") }
        return try checkedResult(perspectiveReverseZ(fovyRadians: fovyRadians, aspect: aspect, near: near, far: far),
                                 "perspective projection")
    }

    /// Checked `perspectiveReverseZInfinite`: the lens rules of
    /// `checkedPerspectiveReverseZ` without a far plane.
    public static func checkedPerspectiveReverseZInfinite(fovyRadians: Float, aspect: Float, near: Float) throws -> float4x4 {
        try checkLens(fovyRadians: fovyRadians, aspect: aspect, near: near)
        return try checkedResult(perspectiveReverseZInfinite(fovyRadians: fovyRadians, aspect: aspect, near: near),
                                 "perspective projection")
    }

    /// Checked `orthographicReverseZ`: every bound finite, each pair of bounds
    /// distinct (a mirrored pair is accepted), and the result finite.
    public static func checkedOrthographicReverseZ(left: Float, right: Float, bottom: Float, top: Float,
                                                   near: Float, far: Float) throws -> float4x4 {
        let bounds: [(Float, String)] = [(left, "orthographic left"), (right, "orthographic right"),
                                         (bottom, "orthographic bottom"), (top, "orthographic top"),
                                         (near, "orthographic near"), (far, "orthographic far")]
        for (value, name) in bounds where !value.isFinite { throw MathContractError.nonfinite(name) }
        guard right != left else { throw MathContractError.outOfRange("orthographic width") }
        guard top != bottom else { throw MathContractError.outOfRange("orthographic height") }
        guard far != near else { throw MathContractError.outOfRange("orthographic depth range") }
        return try checkedResult(orthographicReverseZ(left: left, right: right, bottom: bottom, top: top, near: near, far: far),
                                 "orthographic projection")
    }

    /// Checked `lookAt`: throws for a nonfinite eye or center, an eye at the
    /// center, a nonfinite or near-zero `up`, a view along ±Z with a parallel
    /// up (whose +Z fallback has no perpendicular either), or a nonfinite result.
    public static func checkedLookAt(eye: Float3, center: Float3, up: Float3) throws -> float4x4 {
        guard eye.x.isFinite, eye.y.isFinite, eye.z.isFinite else { throw MathContractError.nonfinite("look-at eye") }
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { throw MathContractError.nonfinite("look-at center") }
        let z = try (eye - center).checkedNormalized("look-at view direction")
        let unitUp = try up.checkedNormalized("look-at up")
        // Same fallback decision as `lookAt`, with a unit up so the
        // perpendicular's length depends only on the angle.
        let u = abs(dot(unitUp, z)) > 0.999 ? Float3(0, 0, 1) : unitUp
        _ = try cross(u, z).checkedNormalized("look-at basis")
        return try checkedResult(lookAt(eye: eye, center: center, up: up), "look-at matrix")
    }

    private static func checkLens(fovyRadians: Float, aspect: Float, near: Float) throws {
        let lens: [(Float, String)] = [(fovyRadians, "field of view"), (aspect, "aspect ratio"), (near, "near plane")]
        for (value, name) in lens where !value.isFinite { throw MathContractError.nonfinite(name) }
        guard fovyRadians > 0, fovyRadians < .pi else { throw MathContractError.outOfRange("field of view") }
        guard aspect > 0 else { throw MathContractError.outOfRange("aspect ratio") }
        guard near > 0 else { throw MathContractError.outOfRange("near plane") }
    }

    private static func checkedResult(_ matrix: float4x4, _ name: String) throws -> float4x4 {
        guard matrix.entriesAreFinite else { throw MathContractError.nonfinite(name) }
        return matrix
    }
}
