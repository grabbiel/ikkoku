import Foundation
import simd
import CoreMath

public enum SliderTab: String, Codable, Sendable, CaseIterable { case face, body }

/// How a slider value (−1…1) turns into geometry.
public enum SliderKind: Sendable, Equatable {
    /// Morph target weight = value.
    case morph(String)
    /// Non-propagating scale on bones: scale = 1 + value·amount·axes.
    case skinScale(bones: [String], axes: Float3, amount: Float)
    /// Propagating scale on bones.
    case scale(bones: [String], axes: Float3, amount: Float)
    /// Translation offset on bones (local metres at +1). `mirror` negates x for `_R` bones.
    case offset(bones: [String], amount: Float3, mirror: Bool)
    /// Bone length: child translation moves along the parent bone axis (+Y local) and the parent's
    /// skin scale stretches to fill. `children` are the bones that move; `amount` metres at +1.
    case length(children: [String], amount: Float)
    /// Whole-character uniform scale factor = 1 + value·amount.
    case modelScale(amount: Float)
    /// Several kinds driven by one slider.
    indirect case combined([SliderKind])
}

public struct SliderDef: Sendable, Identifiable, Equatable {
    public let id: String
    public let tab: SliderTab
    public let group: String
    public let label: String
    public let kind: SliderKind
    public let minValue: Float
    public let maxValue: Float
    public let defaultValue: Float
    public init(_ id: String, _ tab: SliderTab, _ group: String, _ label: String, _ kind: SliderKind, range: ClosedRange<Float> = -100...100, defaultValue: Float = 0) {
        self.id = id; self.tab = tab; self.group = group; self.label = label; self.kind = kind
        self.minValue = range.lowerBound; self.maxValue = range.upperBound; self.defaultValue = defaultValue
    }
}

/// Every slider Ikkoku exposes, grouped the way the maker shows them.
public final class SliderRegistry: Sendable {
    public static let shared = SliderRegistry()

    public let sliders: [SliderDef]
    private let byID: [String: SliderDef]

    public func slider(_ id: String) -> SliderDef? { byID[id] }
    public func groups(for tab: SliderTab) -> [(group: String, sliders: [SliderDef])] {
        var order: [String] = []
        var map: [String: [SliderDef]] = [:]
        for s in sliders where s.tab == tab {
            if map[s.group] == nil { order.append(s.group) }
            map[s.group, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    private init() {
        var list: [SliderDef] = []
        func m(_ id: String, _ tab: SliderTab, _ group: String, _ label: String) { list.append(SliderDef(id, tab, group, label, .morph(id))) }
        func k(_ id: String, _ tab: SliderTab, _ group: String, _ label: String, _ kind: SliderKind) { list.append(SliderDef(id, tab, group, label, kind)) }
        let LR = { (b: String) -> [String] in ["\(b)_L", "\(b)_R"] }

        // Face — Overall
        m("face.head_width", .face, "Overall", "Head width")
        m("face.head_height", .face, "Overall", "Head height")
        m("face.upper_depth", .face, "Overall", "Upper face depth")
        m("face.lower_depth", .face, "Overall", "Lower face depth")
        m("face.cheek_width", .face, "Overall", "Cheek width")
        m("face.cheek_height", .face, "Overall", "Cheek height")
        m("face.cheek_depth", .face, "Overall", "Cheek depth")
        // Jaw / chin
        m("face.jaw_width", .face, "Jaw & chin", "Jaw width")
        m("face.jaw_height", .face, "Jaw & chin", "Jaw height")
        m("face.jaw_depth", .face, "Jaw & chin", "Jaw depth")
        m("face.chin_height", .face, "Jaw & chin", "Chin height")
        m("face.chin_width", .face, "Jaw & chin", "Chin width")
        m("face.chin_depth", .face, "Jaw & chin", "Chin depth")
        // Eyebrows (bone-free: morphs on the brow mesh region are not authored; use offsets on nothing → morph names reserved)
        // Eyes
        k("eye.size", .face, "Eyes", "Eye size", .combined([.morph("eye.size"), .scale(bones: LR("eye"), axes: Float3(1, 1, 1), amount: 0.18)]))
        k("eye.height", .face, "Eyes", "Eye height", .combined([.morph("eye.height"), .offset(bones: LR("eye"), amount: Float3(0, 0.006, 0), mirror: false)]))
        k("eye.spacing", .face, "Eyes", "Eye spacing", .combined([.morph("eye.spacing"), .offset(bones: LR("eye"), amount: Float3(0.006, 0, 0), mirror: true)]))
        k("eye.depth", .face, "Eyes", "Eye depth", .combined([.morph("eye.depth"), .offset(bones: LR("eye"), amount: Float3(0, 0, -0.004), mirror: false)]))
        m("eye.width", .face, "Eyes", "Eye width")
        m("eye.angle", .face, "Eyes", "Eye angle")
        m("eye.outer_height", .face, "Eyes", "Outer corner height")
        m("eye.inner_height", .face, "Eyes", "Inner corner height")
        m("eye.lid_upper", .face, "Eyes", "Upper eyelid")
        m("eye.lid_lower", .face, "Eyes", "Lower eyelid")
        // Nose
        m("nose.height", .face, "Nose", "Nose height")
        m("nose.depth", .face, "Nose", "Nose depth")
        m("nose.size", .face, "Nose", "Nose size")
        m("nose.angle", .face, "Nose", "Nose angle")
        m("nose.bridge_height", .face, "Nose", "Bridge height")
        m("nose.bridge_width", .face, "Nose", "Bridge width")
        m("nose.wing_width", .face, "Nose", "Nostril width")
        m("nose.tip_height", .face, "Nose", "Tip height")
        // Mouth
        m("mouth.height", .face, "Mouth", "Mouth height")
        m("mouth.width", .face, "Mouth", "Mouth width")
        m("mouth.depth", .face, "Mouth", "Mouth depth")
        m("mouth.lip_upper", .face, "Mouth", "Upper lip")
        m("mouth.lip_lower", .face, "Mouth", "Lower lip")
        m("mouth.corner_height", .face, "Mouth", "Corner height")
        // Ears
        m("ear.size", .face, "Ears", "Ear size")
        m("ear.angle", .face, "Ears", "Ear angle")
        m("ear.upper", .face, "Ears", "Upper ear shape")
        m("ear.lower", .face, "Ears", "Lower ear shape")

        // Body — Overall
        k("body.height", .body, "Overall", "Height", .modelScale(amount: 0.12))
        k("body.head_size", .body, "Overall", "Head size", .scale(bones: ["head"], axes: Float3(1, 1, 1), amount: 0.15))
        k("body.neck_length", .body, "Overall", "Neck length", .length(children: ["head"], amount: 0.03))
        k("body.neck_thickness", .body, "Overall", "Neck thickness", .combined([.morph("body.neck_thickness"), .skinScale(bones: ["neck"], axes: Float3(1, 0, 1), amount: 0.2)]))
        // Chest
        k("body.bust_size", .body, "Chest", "Bust size", .combined([.morph("body.bust_size"), .scale(bones: LR("bust"), axes: Float3(1, 1, 1), amount: 0.25)]))
        m("body.bust_height", .body, "Chest", "Bust height")
        m("body.bust_spacing", .body, "Chest", "Bust spacing")
        m("body.bust_softness", .body, "Chest", "Bust softness")
        // Upper body
        k("body.shoulder_width", .body, "Upper body", "Shoulder width", .combined([.morph("body.shoulder_width"), .offset(bones: LR("shoulder"), amount: Float3(0.012, 0, 0), mirror: true)]))
        k("body.torso_length", .body, "Upper body", "Torso length", .length(children: ["spine02", "spine03"], amount: 0.02))
        m("body.waist_width", .body, "Upper body", "Waist width")
        m("body.waist_depth", .body, "Upper body", "Waist depth")
        m("body.belly", .body, "Upper body", "Belly")
        m("body.back", .body, "Upper body", "Back")
        // Lower body
        m("body.hip_width", .body, "Lower body", "Hip width")
        m("body.hip_depth", .body, "Lower body", "Hip depth")
        m("body.butt_size", .body, "Lower body", "Butt size")
        // Arms
        k("body.arm_length", .body, "Arms", "Arm length", .length(children: LR("forearm") + LR("hand"), amount: 0.025))
        k("body.upperarm_thickness", .body, "Arms", "Upper arm thickness", .combined([.morph("body.upperarm_thickness"), .skinScale(bones: LR("upperarm"), axes: Float3(1, 0, 1), amount: 0.2)]))
        k("body.forearm_thickness", .body, "Arms", "Forearm thickness", .combined([.morph("body.forearm_thickness"), .skinScale(bones: LR("forearm"), axes: Float3(1, 0, 1), amount: 0.2)]))
        k("body.hand_size", .body, "Arms", "Hand size", .scale(bones: LR("hand"), axes: Float3(1, 1, 1), amount: 0.2))
        // Legs
        k("body.leg_length", .body, "Legs", "Leg length", .length(children: LR("calf") + LR("foot"), amount: 0.035))
        k("body.thigh_thickness", .body, "Legs", "Thigh thickness", .combined([.morph("body.thigh_thickness"), .skinScale(bones: LR("thigh"), axes: Float3(1, 0, 1), amount: 0.2)]))
        k("body.calf_thickness", .body, "Legs", "Calf thickness", .combined([.morph("body.calf_thickness"), .skinScale(bones: LR("calf"), axes: Float3(1, 0, 1), amount: 0.2)]))
        k("body.foot_size", .body, "Legs", "Foot size", .scale(bones: LR("foot"), axes: Float3(1, 1, 1), amount: 0.2))

        sliders = list
        byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}

/// Expression patterns map to morph weights.
public enum ExpressionPresets {
    public static let eyebrowPatterns: [(name: String, weights: [String: Float])] = [
        ("Neutral", [:]), ("Raised", ["exp.brow_up": 1]), ("Angry", ["exp.brow_angry": 1]),
        ("Sad", ["exp.brow_sad": 1]), ("Worried", ["exp.brow_sad": 0.6, "exp.brow_up": 0.4]),
    ]
    public static let eyePatterns: [(name: String, weights: [String: Float])] = [
        ("Open", [:]), ("Smile", ["exp.eye_smile": 1]), ("Closed", ["exp.blink_L": 1, "exp.blink_R": 1]),
        ("Wink L", ["exp.blink_L": 1]), ("Wink R", ["exp.blink_R": 1]), ("Wide", ["exp.eye_wide": 1]),
        ("Squint", ["exp.squint": 1]), ("Half", ["exp.blink_L": 0.5, "exp.blink_R": 0.5]),
    ]
    public static let mouthPatterns: [(name: String, weights: [String: Float])] = [
        ("Neutral", [:]), ("Smile", ["exp.smile": 0.45]), ("Grin", ["exp.smile": 0.8, "exp.mouth_open": 0.25]),
        ("A", ["exp.mouth_a": 1]), ("I", ["exp.mouth_i": 1]), ("U", ["exp.mouth_u": 1]), ("E", ["exp.mouth_e": 1]), ("O", ["exp.mouth_o": 1]),
        ("Frown", ["exp.frown": 1]), ("Open", ["exp.mouth_open": 1]), ("Pout", ["exp.mouth_u": 0.6, "exp.frown": 0.4]),
    ]
}
