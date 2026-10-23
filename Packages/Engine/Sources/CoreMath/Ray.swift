import Foundation
import simd

/// A ray with a normalized direction. A ray whose origin or direction is not
/// finite (for example one built from a zero direction, which normalizes to
/// NaN) hits nothing (R4): every intersection returns nil and both distance
/// queries return infinity, instead of the slab test reporting a hit at
/// distance 0. Use `checked(origin:direction:)` to get an error instead.
public struct Ray: Sendable {
    public var origin: Float3
    public var direction: Float3   // normalised
    public init(origin: Float3, direction: Float3) {
        self.origin = origin
        self.direction = normalize(direction)
    }

    /// Checked `init` (R4): throws `MathContractError` for a nonfinite origin
    /// and for a nonfinite, zero or near-zero direction (see
    /// `Float3.checkedNormalized`); otherwise returns exactly
    /// `Ray(origin:direction:)`.
    public static func checked(origin: Float3, direction: Float3) throws -> Ray {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite else { throw MathContractError.nonfinite("ray origin") }
        _ = try direction.checkedNormalized("ray direction")
        return Ray(origin: origin, direction: direction)
    }

    /// Whether the origin and direction are finite; see the type comment.
    public var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && origin.z.isFinite
            && direction.x.isFinite && direction.y.isFinite && direction.z.isFinite
    }

    public func point(at t: Float) -> Float3 { origin + direction * t }

    public func transformed(by m: float4x4) -> Ray {
        Ray(origin: m.transformPoint(origin), direction: m.transformDirection(direction))
    }

    /// Checked `transformed(by:)` (R4): throws when `m` maps the origin to a
    /// nonfinite point (a nonfinite entry or a projective `w` of zero) or the
    /// direction to a nonfinite, zero or near-zero vector (a singular `m`);
    /// otherwise returns exactly `transformed(by:)`.
    public func checkedTransformed(by m: float4x4) throws -> Ray {
        try Ray.checked(origin: m.transformPoint(origin), direction: m.transformDirection(direction))
    }

    /// Slab test. Returns entry distance or nil.
    public func intersect(_ box: AABB) -> Float? {
        // NaN slab distances compare false and would leave the initial
        // interval in place, reporting a hit at 0 for every box.
        guard isFinite else { return nil }
        var tmin: Float = -.greatestFiniteMagnitude
        var tmax: Float = .greatestFiniteMagnitude
        for i in 0..<3 {
            let d = direction[i]
            if abs(d) < 1e-8 {
                if origin[i] < box.min[i] || origin[i] > box.max[i] { return nil }
            } else {
                var t1 = (box.min[i] - origin[i]) / d
                var t2 = (box.max[i] - origin[i]) / d
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1)
                tmax = min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        return tmax < 0 ? nil : max(tmin, 0)
    }

    public func intersectSphere(center: Float3, radius: Float) -> Float? {
        guard isFinite else { return nil }
        let oc = origin - center
        let b = dot(oc, direction)
        let c = dot(oc, oc) - radius * radius
        let disc = b * b - c
        if disc < 0 { return nil }
        let s = sqrt(disc)
        let t0 = -b - s
        if t0 >= 0 { return t0 }
        let t1 = -b + s
        return t1 >= 0 ? t1 : nil
    }

    public func intersectPlane(point: Float3, normal: Float3) -> Float? {
        guard isFinite else { return nil }
        let denom = dot(normal, direction)
        if abs(denom) < 1e-7 { return nil }
        let t = dot(point - origin, normal) / denom
        return t >= 0 ? t : nil
    }

    /// Möller–Trumbore. Returns distance along the ray.
    public func intersectTriangle(_ a: Float3, _ b: Float3, _ c: Float3, cullBackface: Bool = false) -> Float? {
        guard isFinite else { return nil }
        let e1 = b - a, e2 = c - a
        let p = cross(direction, e2)
        let det = dot(e1, p)
        if cullBackface { if det < 1e-8 { return nil } } else { if abs(det) < 1e-8 { return nil } }
        let inv = 1 / det
        let tv = origin - a
        let u = dot(tv, p) * inv
        if u < 0 || u > 1 { return nil }
        let q = cross(tv, e1)
        let v = dot(direction, q) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = dot(e2, q) * inv
        return t > 1e-6 ? t : nil
    }

    /// Closest approach between this ray and a segment. Returns (t on ray, s in 0...1 on segment, distance).
    /// A nonfinite ray returns `(0, 0, .infinity)`.
    public func closest(toSegment a: Float3, _ b: Float3) -> (t: Float, s: Float, distance: Float) {
        guard isFinite else { return (t: 0, s: 0, distance: Float.infinity) }
        let u = direction
        let v = b - a
        let w0 = origin - a
        let aa = dot(u, u), bb = dot(u, v), cc = dot(v, v), dd = dot(u, w0), ee = dot(v, w0)
        let denom = aa * cc - bb * bb
        var sc: Float, tc: Float
        if denom < 1e-8 {
            sc = 0
            tc = dd / aa
        } else {
            sc = (aa * ee - bb * dd) / denom
            tc = (bb * ee - cc * dd) / denom
        }
        sc = clamp(sc, 0, 1)
        tc = max(0, dot(a + v * sc - origin, u))
        let dist = length(origin + u * tc - (a + v * sc))
        return (tc, sc, dist)
    }

    /// A nonfinite ray returns infinity.
    public func distance(toPoint p: Float3) -> Float {
        guard isFinite else { return .infinity }
        let t = max(0, dot(p - origin, direction))
        return length(p - point(at: t))
    }
}

public struct AABB: Sendable, Equatable {
    public var min: Float3
    public var max: Float3
    public init(min: Float3, max: Float3) { self.min = min; self.max = max }
    public static let empty = AABB(min: Float3(repeating: .greatestFiniteMagnitude), max: Float3(repeating: -.greatestFiniteMagnitude))
    public var isEmpty: Bool { min.x > max.x }
    public var center: Float3 { (min + max) * 0.5 }
    public var extent: Float3 { max - min }
    public var radius: Float { length(extent) * 0.5 }
    public mutating func expand(_ p: Float3) {
        min = simd_min(min, p); max = simd_max(max, p)
    }
    public mutating func expand(_ other: AABB) {
        if other.isEmpty { return }
        min = simd_min(min, other.min); max = simd_max(max, other.max)
    }
    public func transformed(by m: float4x4) -> AABB {
        if isEmpty { return self }
        var r = AABB.empty
        for i in 0..<8 {
            let p = Float3(i & 1 == 0 ? min.x : max.x, i & 2 == 0 ? min.y : max.y, i & 4 == 0 ? min.z : max.z)
            r.expand(m.transformPoint(p))
        }
        return r
    }
    public static func of(points: [Float3]) -> AABB {
        var b = AABB.empty
        for p in points { b.expand(p) }
        return b
    }
}
