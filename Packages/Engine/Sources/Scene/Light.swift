import Foundation
import simd
import CoreMath

public enum LightKind: String, Codable, Sendable { case directional, point, spot }

public struct SceneLight: Sendable, Codable, Equatable {
    public var kind: LightKind = .directional
    public var color: Float3 = Float3(1, 1, 1)
    public var intensity: Float = 1
    public var position: Float3 = Float3(0, 2, 0)
    public var rotation: Float3 = Float3(50, -30, 0)   // Euler degrees; light points down local -Z... we use forward = rotation applied to (0,0,-1)
    public var range: Float = 6
    public var spotAngle: Float = 40        // outer cone, degrees
    public var spotBlend: Float = 0.5       // 0…1 inner/outer ratio
    public var castsShadow: Bool = true
    public var enabled: Bool = true

    public init() {}
    public init(kind: LightKind) { self.kind = kind }

    /// Direction the light travels (world).
    public var direction: Float3 {
        let q = simd_quatf(eulerXYZ: rotation.degreesToRadians)
        return normalize(q.act(Float3(0, 0, -1)))
    }
}
