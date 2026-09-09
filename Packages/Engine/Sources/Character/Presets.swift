import Foundation

/// Named slider bundles, like Koikatsu's face/body "type" presets. Values are slider units (−100…100).
public struct SliderPreset: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let tab: SliderTab
    public let values: [String: Float]
}

public enum SliderPresets {
    public static let face: [SliderPreset] = [
        SliderPreset(id: "f_default", name: "Default", tab: .face, values: [:]),
        SliderPreset(id: "f_round", name: "Round & cute", tab: .face, values: ["face.head_width": 25, "face.cheek_width": 30, "face.chin_height": -20, "face.jaw_width": 15, "eye.size": 35, "eye.height": -10, "nose.size": -30, "mouth.width": -15]),
        SliderPreset(id: "f_sharp", name: "Sharp", tab: .face, values: ["face.jaw_width": -30, "face.chin_height": 25, "face.chin_width": -25, "face.cheek_width": -20, "eye.angle": 35, "eye.width": 15, "nose.height": 10, "nose.bridge_height": 20]),
        SliderPreset(id: "f_gentle", name: "Gentle", tab: .face, values: ["eye.angle": -25, "eye.outer_height": -20, "eye.size": 15, "mouth.corner_height": 15, "face.cheek_height": 10, "nose.size": -15]),
        SliderPreset(id: "f_mature", name: "Mature", tab: .face, values: ["face.head_height": 15, "face.lower_depth": 10, "eye.size": -25, "eye.height": 10, "nose.height": 20, "nose.size": 10, "mouth.lip_lower": 20, "face.chin_height": 15]),
        SliderPreset(id: "f_child", name: "Youthful", tab: .face, values: ["face.head_width": 30, "face.head_height": -10, "eye.size": 50, "eye.spacing": 15, "nose.size": -45, "nose.height": -15, "mouth.width": -25, "face.chin_height": -30, "ear.size": 10]),
    ]

    public static let body: [SliderPreset] = [
        SliderPreset(id: "b_default", name: "Default", tab: .body, values: [:]),
        SliderPreset(id: "b_petite", name: "Petite", tab: .body, values: ["body.height": -60, "body.head_size": 20, "body.bust_size": -40, "body.shoulder_width": -20, "body.hip_width": -15, "body.leg_length": -10, "body.hand_size": -10, "body.foot_size": -10]),
        SliderPreset(id: "b_tall", name: "Tall & slim", tab: .body, values: ["body.height": 50, "body.head_size": -15, "body.leg_length": 35, "body.arm_length": 20, "body.waist_width": -25, "body.thigh_thickness": -20, "body.calf_thickness": -15, "body.neck_length": 20]),
        SliderPreset(id: "b_athletic", name: "Athletic", tab: .body, values: ["body.shoulder_width": 30, "body.waist_width": -20, "body.hip_width": -10, "body.upperarm_thickness": 15, "body.forearm_thickness": 10, "body.thigh_thickness": 15, "body.calf_thickness": 20, "body.back": 20]),
        SliderPreset(id: "b_curvy", name: "Curvy", tab: .body, values: ["body.bust_size": 45, "body.bust_softness": 30, "body.hip_width": 35, "body.butt_size": 35, "body.waist_width": -20, "body.thigh_thickness": 25]),
        SliderPreset(id: "b_broad", name: "Broad", tab: .body, values: ["body.height": 25, "body.shoulder_width": 45, "body.waist_width": 20, "body.waist_depth": 15, "body.upperarm_thickness": 30, "body.forearm_thickness": 25, "body.thigh_thickness": 25, "body.calf_thickness": 25, "body.neck_thickness": 30]),
    ]
}
