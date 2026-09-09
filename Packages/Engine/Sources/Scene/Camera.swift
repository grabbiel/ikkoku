import Foundation
import simd
import CoreMath

/// Orbit camera used by both the maker and the studio viewport.
public struct OrbitCamera: Sendable, Equatable, Codable {
    public var target: Float3 = Float3(0, 0.9, 0)
    public var distance: Float = 2.6
    public var yaw: Float = 0          // radians, around Y
    public var pitch: Float = 0.05     // radians, positive looks down
    public var fovDegrees: Float = 30
    public var near: Float = 0.05

    public init() {}

    public var position: Float3 {
        let cp = cos(pitch), sp = sin(pitch)
        let dir = Float3(sin(yaw) * cp, sp, cos(yaw) * cp)
        return target + dir * distance
    }

    public var forward: Float3 { normalize(target - position) }

    public func viewMatrix() -> float4x4 { Projection.lookAt(eye: position, center: target, up: Float3(0, 1, 0)) }

    public func projectionMatrix(aspect: Float) -> float4x4 {
        Projection.perspectiveReverseZInfinite(fovyRadians: fovDegrees.degreesToRadians, aspect: aspect, near: near)
    }

    public mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx
        pitch = clamp(pitch + dy, -1.55, 1.55)
    }

    public mutating func pan(dx: Float, dy: Float) {
        let view = viewMatrix()
        let right = Float3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = Float3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        let s = distance * 0.0015
        target += (-right * dx + up * dy) * s
    }

    public mutating func dolly(_ amount: Float) {
        distance = clamp(distance * exp(-amount * 0.1), 0.15, 50)
    }

    /// Ray through a viewport point (pixels, origin top-left).
    public func ray(atPixel p: Float2, viewport: Float2) -> Ray {
        let ndc = Float2(p.x / viewport.x * 2 - 1, 1 - p.y / viewport.y * 2)
        let invVP = (projectionMatrix(aspect: viewport.x / viewport.y) * viewMatrix()).inverse
        let nearP = invVP * Float4(ndc.x, ndc.y, 1, 1)   // reverse-Z: near = 1
        let farP = invVP * Float4(ndc.x, ndc.y, 0.001, 1)
        let a = Float3(nearP.x, nearP.y, nearP.z) / nearP.w
        let b = Float3(farP.x, farP.y, farP.z) / farP.w
        return Ray(origin: a, direction: b - a)
    }

    /// World → pixel. Returns nil when behind the camera.
    public func project(_ world: Float3, viewport: Float2) -> Float2? {
        let vp = projectionMatrix(aspect: viewport.x / viewport.y) * viewMatrix()
        let c = vp * Float4(world.x, world.y, world.z, 1)
        if c.w <= 0 { return nil }
        let ndc = Float2(c.x, c.y) / c.w
        return Float2((ndc.x + 1) * 0.5 * viewport.x, (1 - ndc.y) * 0.5 * viewport.y)
    }

    /// Pixel size of one world unit at a given world point (for screen-constant gizmos).
    public func worldUnitsPerPixel(at world: Float3, viewport: Float2) -> Float {
        let d = max(dot(world - position, forward), near)
        let h = 2 * d * tan(fovDegrees.degreesToRadians * 0.5)
        return h / viewport.y
    }
}
