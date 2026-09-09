import Foundation
import simd
import CoreMath
import Scene
import Character

/// Keyframe animation for studio objects (transform, FK pose, IK targets, expression), like the
/// Koikatsu Timeline plugin: keyframes per object, linear interpolation, looped playback.
public struct Keyframe: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var time: Float                  // seconds
    public var object: UUID
    public var transform: StudioTransform
    public var poseDelta: PoseDelta
    public var ikTargets: [IKChain: IKTarget]
    public var expression: ExpressionState?
    public var handGestureL: Int
    public var handGestureR: Int
    public var animationPreset: String?

    public init(time: Float, object: StudioObject) {
        self.time = time
        self.object = object.id
        self.transform = object.transform
        self.poseDelta = object.poseDelta
        self.ikTargets = object.ikTargets
        self.expression = object.card?.expression
        self.handGestureL = object.handGestureL
        self.handGestureR = object.handGestureR
        self.animationPreset = object.animationPreset
    }
}

public struct Timeline: Codable, Sendable, Equatable {
    public var keyframes: [Keyframe] = []
    public var duration: Float = 5
    public var loop = true
    public init() {}

    public func keyframes(for object: UUID) -> [Keyframe] { keyframes.filter { $0.object == object }.sorted { $0.time < $1.time } }

    public mutating func insert(_ k: Keyframe) {
        keyframes.removeAll { $0.object == k.object && abs($0.time - k.time) < 0.02 }
        keyframes.append(k)
        duration = max(duration, k.time)
    }

    /// Interpolated state for one object at `time`, or nil when it has no keyframes.
    public func sample(object: UUID, time: Float) -> Keyframe? {
        let ks = keyframes(for: object)
        guard let first = ks.first else { return nil }
        if ks.count == 1 || time <= first.time { return first }
        guard let last = ks.last, time < last.time else { return ks.last }
        var a = first, b = first
        for k in ks { if k.time <= time { a = k } else { b = k; break } }
        let span = max(b.time - a.time, 1e-4)
        let t = clamp((time - a.time) / span, 0, 1)
        let s = smoothstep(0, 1, t)
        return Keyframe.blend(a, b, s)
    }
}

public extension Keyframe {
    static func blend(_ a: Keyframe, _ b: Keyframe, _ t: Float) -> Keyframe {
        var out = t < 0.5 ? a : b
        out.transform.position = lerp(a.transform.position, b.transform.position, t)
        out.transform.scale = lerp(a.transform.scale, b.transform.scale, t)
        let qa = a.transform.quaternion, qb = b.transform.quaternion
        out.transform.rotation = simd_slerp(qa, qb, t).eulerXYZ.radiansToDegrees
        // FK: union of bones, lerp Euler degrees (rest = zero)
        var rot: [String: Float3] = [:]
        for k in Set(a.poseDelta.rotations.keys).union(b.poseDelta.rotations.keys) {
            let ra = a.poseDelta.rotations[k] ?? .zero, rb = b.poseDelta.rotations[k] ?? .zero
            let v = lerp(ra, rb, t)
            if v != .zero { rot[k] = v }
        }
        out.poseDelta = PoseDelta(rotations: rot, translations: a.poseDelta.translations, scales: a.poseDelta.scales, skinScales: a.poseDelta.skinScales)
        var ik: [IKChain: IKTarget] = [:]
        for c in IKChain.allCases {
            let ta = a.ikTargets[c], tb = b.ikTargets[c]
            if let ta, let tb, ta.enabled, tb.enabled { ik[c] = IKTarget(enabled: true, position: lerp(ta.position, tb.position, t), pole: ta.pole) }
            else if let k = (t < 0.5 ? ta : tb), k.enabled { ik[c] = k }
        }
        out.ikTargets = ik
        if var ea = a.expression, let eb = b.expression {
            ea.eyeOpen = lerp(ea.eyeOpen, eb.eyeOpen, t)
            ea.mouthOpen = lerp(ea.mouthOpen, eb.mouthOpen, t)
            ea.blush = lerp(ea.blush, eb.blush, t)
            if t >= 0.5 { ea.eyes = eb.eyes; ea.mouth = eb.mouth; ea.eyebrows = eb.eyebrows; ea.gazeMode = eb.gazeMode; ea.gazeTarget = eb.gazeTarget }
            out.expression = ea
        }
        return out
    }
}
