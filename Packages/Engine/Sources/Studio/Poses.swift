import Foundation
import simd
import CoreMath
import Scene
import Character

/// Built-in pose presets (FK deltas in degrees) and hand gestures.
public enum PosePresets {
    public struct Preset: Sendable, Identifiable { public let id: String; public let name: String; public let category: String; public let delta: PoseDelta }

    static func d(_ r: [String: Float3]) -> PoseDelta { PoseDelta(rotations: r) }

    public static let all: [Preset] = [
        Preset(id: "apose", name: "A-pose (rest)", category: "Basic", delta: PoseDelta()),
        Preset(id: "tpose", name: "T-pose", category: "Basic", delta: d(["upperarm_L": Float3(0, 0, 40), "upperarm_R": Float3(0, 0, -40)])),
        Preset(id: "idle", name: "Standing idle", category: "Basic", delta: d([
            "upperarm_L": Float3(0, 0, -28), "upperarm_R": Float3(0, 0, 28), "forearm_L": Float3(0, 0, -8), "forearm_R": Float3(0, 0, 8),
            "spine02": Float3(2, 0, 0), "head": Float3(-2, 0, 0)])),
        Preset(id: "wave", name: "Wave", category: "Basic", delta: d([
            "upperarm_L": Float3(0, 0, -30), "upperarm_R": Float3(-40, 30, 60), "forearm_R": Float3(0, 0, 70), "hand_R": Float3(0, 0, 20), "head": Float3(0, 0, 8)])),
        Preset(id: "handsonhips", name: "Hands on hips", category: "Basic", delta: d([
            "upperarm_L": Float3(0, 20, -20), "forearm_L": Float3(0, 0, -95), "hand_L": Float3(0, 0, -20),
            "upperarm_R": Float3(0, -20, 20), "forearm_R": Float3(0, 0, 95), "hand_R": Float3(0, 0, 20), "spine02": Float3(0, 0, 4), "hips": Float3(0, 0, -4)])),
        Preset(id: "peace", name: "Peace sign", category: "Cute", delta: d([
            "upperarm_L": Float3(0, 0, -30), "upperarm_R": Float3(-20, 0, 45), "forearm_R": Float3(-60, 0, 95), "hand_R": Float3(-20, 0, 10), "head": Float3(0, -10, 10)])),
        Preset(id: "thinking", name: "Thinking", category: "Cute", delta: d([
            "upperarm_L": Float3(0, 0, -25), "upperarm_R": Float3(0, 0, 40), "forearm_R": Float3(-40, 0, 120), "hand_R": Float3(-30, 0, 0), "head": Float3(8, -12, 6), "spine02": Float3(3, 0, 0)])),
        Preset(id: "walk", name: "Walking", category: "Motion", delta: d([
            "thigh_L": Float3(-25, 0, 0), "calf_L": Float3(15, 0, 0), "thigh_R": Float3(22, 0, 0), "calf_R": Float3(35, 0, 0),
            "upperarm_L": Float3(20, 0, -25), "upperarm_R": Float3(-25, 0, 25), "forearm_R": Float3(0, 0, 25), "spine02": Float3(3, 0, 0)])),
        Preset(id: "sit", name: "Sitting", category: "Motion", delta: d([
            "thigh_L": Float3(-85, 0, 0), "calf_L": Float3(85, 0, 0), "thigh_R": Float3(-85, 0, 0), "calf_R": Float3(85, 0, 0),
            "upperarm_L": Float3(0, 0, -30), "upperarm_R": Float3(0, 0, 30), "forearm_L": Float3(-40, 0, -10), "forearm_R": Float3(-40, 0, 10), "spine01": Float3(-4, 0, 0)])),
        Preset(id: "jump", name: "Jump", category: "Motion", delta: d([
            "upperarm_L": Float3(0, 0, -150), "upperarm_R": Float3(0, 0, 150), "thigh_L": Float3(-30, 0, 0), "calf_L": Float3(60, 0, 0), "thigh_R": Float3(-30, 0, 0), "calf_R": Float3(60, 0, 0), "spine02": Float3(-8, 0, 0)])),
    ]

    public static func preset(_ id: String) -> Preset? { all.first { $0.id == id } }

    /// Finger curl presets: rotation about the finger's bend axis (local X) for joints 1…3 in degrees.
    public static let handGestures: [(name: String, curl: [Float], thumb: [Float], spread: Float)] = [
        ("Relaxed", [15, 20, 15], [10, 10, 5], 0),
        ("Open", [0, 0, 0], [0, 0, 0], 8),
        ("Fist", [80, 95, 60], [30, 40, 30], 0),
        ("Point", [0, 0, 0], [20, 20, 10], 0),
        ("Peace", [0, 0, 0], [30, 40, 30], 12),
        ("Thumbs up", [80, 95, 60], [-20, 0, 0], 0),
        ("Grip", [50, 60, 40], [25, 30, 20], 0),
        ("Pinch", [30, 40, 20], [35, 45, 25], 0),
    ]

    /// Pose delta for one hand's gesture.
    public static func handDelta(gesture: Int, side: String) -> PoseDelta {
        guard gesture >= 0, gesture < handGestures.count else { return PoseDelta() }
        let g = handGestures[gesture]
        var r: [String: Float3] = [:]
        let sign: Float = side == "L" ? 1 : -1
        let fingers = ["index", "middle", "ring", "pinky"]
        for (fi, f) in fingers.enumerated() {
            for j in 1...3 {
                var curl = g.curl[j - 1]
                if g.name == "Point" && f != "index" { curl = [85, 95, 60][j - 1] }
                if g.name == "Peace" && (f == "ring" || f == "pinky") { curl = [85, 95, 60][j - 1] }
                var rot = Float3(curl, 0, 0)
                if j == 1 { rot.z = sign * g.spread * (Float(fi) - 1.5) }
                r["\(f)0\(j)_\(side)"] = rot
            }
        }
        for j in 1...3 { r["thumb0\(j)_\(side)"] = Float3(g.thumb[j - 1], 0, sign * (j == 1 ? 10 : 0)) }
        return PoseDelta(rotations: r)
    }
}
