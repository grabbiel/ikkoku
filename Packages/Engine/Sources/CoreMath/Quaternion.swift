import Foundation
import simd

public extension simd_quatf {
    static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    /// Euler angles in radians, applied in XYZ order (intrinsic): R = Rz·Ry·Rx? No —
    /// we use the common "rotate about X, then Y, then Z in the parent frame":
    /// q = qz * qy * qx.
    init(eulerXYZ e: Float3) {
        let qx = simd_quatf(angle: e.x, axis: Float3(1, 0, 0))
        let qy = simd_quatf(angle: e.y, axis: Float3(0, 1, 0))
        let qz = simd_quatf(angle: e.z, axis: Float3(0, 0, 1))
        self = qz * qy * qx
    }

    /// Inverse of `init(eulerXYZ:)`. Returns radians.
    var eulerXYZ: Float3 {
        let m = float3x3(self)
        // m = Rz*Ry*Rx
        let sy = -m.columns.0.z            // -sin(y)... derive from matrix
        // Using column-major: m.columns.j is column j. Element (row i, col j) = m.columns.j[i]
        let r20 = m.columns.0.z
        let y = asin(clamp(-r20, -1, 1))
        let x: Float, z: Float
        if abs(r20) < 0.9999 {
            x = atan2(m.columns.1.z, m.columns.2.z)
            z = atan2(m.columns.0.y, m.columns.0.x)
        } else {
            x = atan2(-m.columns.2.y, m.columns.1.y)
            z = 0
        }
        _ = sy
        return Float3(x, y, z)
    }

    /// Shortest rotation taking `from` onto `to`. Both need not be normalised.
    static func rotation(from: Float3, to: Float3) -> simd_quatf {
        let f = normalize(from), t = normalize(to)
        let d = dot(f, t)
        if d > 0.999999 { return .identity }
        if d < -0.999999 {
            var axis = cross(Float3(1, 0, 0), f)
            if length_squared(axis) < 1e-6 { axis = cross(Float3(0, 1, 0), f) }
            return simd_quatf(angle: .pi, axis: normalize(axis))
        }
        let axis = cross(f, t)
        let q = simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: 1 + d)
        return q.normalized
    }

    static func lookRotation(forward: Float3, up: Float3 = Float3(0, 1, 0)) -> simd_quatf {
        let f = normalize(forward)
        var u = up
        if abs(dot(f, normalize(u))) > 0.999 { u = Float3(1, 0, 0) }
        let r = normalize(cross(u, f))
        let u2 = cross(f, r)
        // Columns: right, up, forward  (object +Z faces forward)
        let m = float3x3(r, u2, f)
        return simd_quatf(m).normalized
    }

    var forward: Float3 { act(Float3(0, 0, 1)) }
    var upVector: Float3 { act(Float3(0, 1, 0)) }
    var rightVector: Float3 { act(Float3(1, 0, 0)) }
}
