import Foundation
import simd
import CoreMath
import Scene

/// Spring-lag simulation for hair chain bones (Koikatsu-style "dynamic bones").
/// Each chain bone keeps a swung direction in its parent's frame; head motion and gravity push it,
/// a spring pulls it back to rest, damping settles it.
public final class HairDynamics {
    public struct Params: Sendable {
        public var stiffness: Float = 28
        public var damping: Float = 6
        public var gravity: Float = 4
        public var drag: Float = 0.9        // how much head velocity swings the hair
        public var maxAngle: Float = 0.7    // radians
        public init() {}
    }
    public var params = Params()

    private struct Node { var dir: Float3; var vel: Float3 }
    private var nodes: [Int: Node] = [:]      // bone index → state
    private var lastHeadPos: Float3?
    private var headVelocity = Float3.zero
    private(set) public var rotations: [Int: simd_quatf] = [:]

    public init() {}

    public func reset() { nodes.removeAll(); rotations.removeAll(); lastHeadPos = nil }

    /// Advances the simulation. `chains` = bone indices root→tip per chain; `world` = current world matrices
    /// (character root space, computed without the dynamic rotations), `rootMatrix` = character placement.
    public func step(dt rawDt: Float, chains: [[Int]], skeleton: Skeleton, world: [float4x4], rootMatrix: float4x4, headIndex: Int?) {
        let dt = min(max(rawDt, 1.0 / 120), 1.0 / 20)
        if let hi = headIndex, hi < world.count {
            let hp = (rootMatrix * world[hi]).translation
            if let last = lastHeadPos { headVelocity = (hp - last) / dt } else { headVelocity = .zero }
            lastHeadPos = hp
        }
        let rootRot = rootMatrix.rotationQuaternion
        let gravityWorld = Float3(0, -1, 0)
        for chain in chains {
            for (k, bi) in chain.enumerated() {
                guard bi < skeleton.count, let pi = skeleton.bones[bi].parent, pi < world.count else { continue }
                // Parent frame in world space (rotation only).
                let parentWorldRot = (rootRot * world[pi].rotationQuaternion).normalized
                let restDir = normalize(skeleton.bones[bi].restRotation.act(Float3(0, 1, 0)))
                var n = nodes[bi] ?? Node(dir: restDir, vel: .zero)
                let gLocal = parentWorldRot.inverse.act(gravityWorld)
                let vLocal = parentWorldRot.inverse.act(headVelocity)
                let tipWeight = Float(k + 1) / Float(chain.count)
                var force = (restDir - n.dir) * params.stiffness
                force += (gLocal - n.dir) * params.gravity * tipWeight
                force -= vLocal * params.drag * (0.5 + tipWeight)
                force -= n.vel * params.damping
                n.vel += force * dt
                n.dir = normalize(n.dir + n.vel * dt)
                // Clamp swing away from rest.
                let cosA = dot(n.dir, restDir)
                if cosA < cos(params.maxAngle) {
                    let axis = cross(restDir, n.dir)
                    if length_squared(axis) > 1e-8 {
                        n.dir = simd_quatf(angle: params.maxAngle, axis: normalize(axis)).act(restDir)
                        n.vel *= 0.5
                    }
                }
                nodes[bi] = n
                rotations[bi] = simd_quatf.rotation(from: restDir, to: n.dir)
            }
        }
    }
}
