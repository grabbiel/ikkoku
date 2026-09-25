import Foundation
import simd
import CoreMath
import Scene

// Source controller destination order and scalar dependencies. Each dependency encodes
// sourceIndex * 9 + position/rotation/scale component. Coverage follows written axes.
extension SourceBodyShapePose {
    public static let sourceNames = [
        "cf_a_height",
        "cf_a_height_aid",
        "cf_a_head",
        "cf_a_neck",
        "cf_a_spine03",
        "cf_a_shoulder",
        "cf_a_shoulder_L_aid03",
        "cf_a_shoulder_R_aid03",
        "cf_a_arm_L_aid03",
        "cf_a_arm_R_aid03",
        "cf_a_arm02",
        "cf_a_arm03_blend01",
        "cf_a_arm03_blend02",
        "cf_a_farm01",
        "cf_a_farm02_blend01",
        "cf_a_farm02_blend03",
        "cf_a_farm03",
        "cf_a_spine02",
        "cf_a_spine02_aid_berry",
        "cf_a_spine01",
        "cf_a_berry",
        "cf_a_waist01",
        "cf_a_waist02",
        "cf_a_siri",
        "cf_a_thigh01_L",
        "cf_a_thigh01_L_aid",
        "cf_a_thigh01_R",
        "cf_a_thigh01_R_aid",
        "cf_a_thigh02_L_blend01",
        "cf_a_thigh02_L_blend03",
        "cf_a_thigh02_R_blend01",
        "cf_a_thigh02_R_blend03",
        "cf_a_thigh03_L",
        "cf_a_thigh03_R",
        "cf_a_leg01_L",
        "cf_a_leg01_R",
        "cf_a_leg02_L",
        "cf_a_leg02_R",
        "cf_a_leg03",
        "cf_a_dan",
        "cf_a_bust_ty",
        "cf_a_bust00_aid03_sz",
        "cf_a_bust00_aid02_sz",
        "cf_a_bust_L_ry",
        "cf_a_bust_rx",
        "cf_a_bust01_size",
        "cf_a_bust_L_tx",
        "cf_a_bust02_size",
        "cf_a_bust_tz",
        "cf_a_bust03_size",
        "cf_a_bust01_shape1",
        "cf_a_bust02_shape1",
        "cf_a_bust03_shape1",
        "cf_a_hit_bust_shape1",
        "cf_a_hit_bust_shape2",
        "cf_a_bnip01",
        "cf_a_bnip01_size",
        "cf_a_d_bnip01_size",
        "cf_a_bnip02_size",
        "cf_a_bnip015_size",
        "cf_a_bnip02",
        "cf_a_bnipacc_stand",
        "cf_a_bnipacc_size",
        "cf_a_bust_R_ry",
        "cf_a_bust_R_tx",
        "cf_a_hit_siri_shape1",
        "cf_a_hit_siri_shape2",
        "cf_a_hit_siri_shape3",
        "cf_a_hit_siri_shape4",
        "cf_a_hit_siri_shape5",
        "cf_a_hit_siri_shape6",
        "cf_a_hit_waist_shape1",
        "cf_a_hit_waist_shape2",
        "cf_a_hit_waist_shape3",
        "cf_a_hit_spinety_shape",
        "cf_a_hit_waist_shape4",
        "cf_a_hit_waist_shape5",
        "cf_a_hit_berry_shape",
        "cf_a_hit_berry_shape2",
        "cf_a_hit_berry_shape3",
        "cf_a_hit_spine02_shape1",
        "cf_a_hit_spine02_shape2",
        "cf_a_hit_spine02_shape3",
        "cf_a_hit_shoulder_shape1",
        "cf_a_hit_shoulder_shape2",
        "cf_a_hit_shoulder_shape3",
        "cf_a_hit_arm_shape2",
        "cf_a_hit_arm_shape3",
        "cf_a_hit_arm_shape4",
        "cf_a_hit_spine01_shape1",
        "cf_a_hit_spine01_shape2",
        "cf_a_sk_00_00",
        "cf_a_sk_00_01",
        "cf_a_sk_berry",
        "cf_a_sk_thigh01_sz",
        "cf_a_sk_01_00",
        "cf_a_sk_01_01",
        "cf_a_sk_thigh01_sx",
        "cf_a_sk_02_00",
        "cf_a_sk_02_01",
        "cf_a_sk_siri",
        "cf_a_sk_03_00",
        "cf_a_sk_03_01",
        "cf_a_sk_04_00",
        "cf_a_sk_04_01",
        "cf_a_sk_05_00",
        "cf_a_sk_05_01",
        "cf_a_sk_06_00",
        "cf_a_sk_06_01",
        "cf_a_sk_07_00",
        "cf_a_sk_07_01",
    ]
    public static let destinationNames = [
        "cf_n_height",
        "cf_s_hand_L",
        "cf_s_hand_R",
        "cf_s_head",
        "cf_s_neck",
        "cf_s_spine03",
        "cf_s_shoulder02_L",
        "cf_s_shoulder02_R",
        "cf_s_arm01_L",
        "cf_s_arm01_R",
        "cf_s_arm02_L",
        "cf_s_arm02_R",
        "cf_s_arm03_L",
        "cf_s_arm03_R",
        "cf_s_forearm01_L",
        "cf_s_forearm01_R",
        "cf_s_forearm02_L",
        "cf_s_forearm02_R",
        "cf_s_wrist_L",
        "cf_s_wrist_R",
        "cf_s_spine02",
        "cf_s_spine01",
        "cf_s_waist01",
        "cf_s_waist02",
        "cf_s_siri_L",
        "cf_s_siri_R",
        "cf_s_thigh01_L",
        "cf_s_thigh01_R",
        "cf_s_thigh02_L",
        "cf_s_thigh02_R",
        "cf_s_thigh03_L",
        "cf_s_thigh03_R",
        "cf_s_leg01_L",
        "cf_s_leg01_R",
        "cf_s_leg02_L",
        "cf_s_leg02_R",
        "cf_s_leg03_L",
        "cf_s_leg03_R",
        "cf_d_kokan",
        "cf_s_bust00_L",
        "cf_d_bust01_L",
        "cf_d_bust02_L",
        "cf_d_bust03_L",
        "cf_s_bust01_L",
        "cf_s_bust02_L",
        "cf_s_bust03_L",
        "cf_hit_bust02_L",
        "cf_d_bnip01_L",
        "cf_s_bnip01_L",
        "cf_s_bnip025_L",
        "cf_s_bnip015_L",
        "cf_s_bnip02_L",
        "cf_s_bnipacc_L",
        "cf_s_bust00_R",
        "cf_d_bust01_R",
        "cf_d_bust02_R",
        "cf_d_bust03_R",
        "cf_s_bust01_R",
        "cf_s_bust02_R",
        "cf_s_bust03_R",
        "cf_hit_bust02_R",
        "cf_d_bnip01_R",
        "cf_s_bnip01_R",
        "cf_s_bnip025_R",
        "cf_s_bnip015_R",
        "cf_s_bnip02_R",
        "cf_s_bnipacc_R",
        "cf_hit_siri_L",
        "cf_hit_siri_R",
        "cf_hit_waist_L",
        "cf_hit_berry",
        "cf_hit_spine02_L",
        "cf_hit_shoulder_L",
        "cf_hit_shoulder_R",
        "cf_hit_arm_L",
        "cf_hit_arm_R",
        "cf_hit_spine01",
        "cf_d_sk_top",
        "cf_d_sk_00_00",
        "cf_d_sk_01_00",
        "cf_d_sk_02_00",
        "cf_d_sk_03_00",
        "cf_d_sk_04_00",
        "cf_d_sk_05_00",
        "cf_d_sk_06_00",
        "cf_d_sk_07_00",
    ]
    public static let alwaysDestinationNames = ["cf_d_kokan", "cf_d_shoulder_L", "cf_d_shoulder_R"]
    static let operationOrder = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66]
    static let dependencies: [Int: Set<Int>] = [
        0: [6, 7, 8],
        1: [15, 16, 17],
        2: [15, 16, 17],
        3: [15, 16, 17, 19, 24, 25, 26],
        4: [15, 17, 29, 33, 35],
        5: [15, 17, 38, 42, 44],
        6: [16, 17, 45, 46, 51, 52, 53, 54, 62],
        7: [16, 17, 45, 46, 51, 52, 53, 63, 71],
        8: [16, 17, 46, 52, 53, 72, 80],
        9: [16, 17, 46, 52, 53, 81, 89],
        10: [16, 17, 91, 92, 97, 98],
        11: [16, 17, 91, 92, 97, 98],
        12: [16, 17, 106, 107, 115, 116],
        13: [16, 17, 106, 107, 115, 116],
        14: [16, 17, 124, 125],
        15: [16, 17, 124, 125],
        16: [16, 17, 133, 134, 142, 143],
        17: [16, 17, 133, 134, 142, 143],
        18: [16, 17, 151, 152],
        19: [16, 17, 151, 152],
        20: [15, 17, 155, 159, 161, 164, 170],
        21: [15, 17, 172, 173, 177, 179, 181, 182, 183, 186, 187, 188],
        22: [15, 17, 181, 182, 183, 186, 187, 188, 191, 195, 197],
        23: [15, 17, 200, 204, 206],
        24: [197, 200, 204, 206, 208, 209, 210, 213, 214, 215],
        25: [197, 200, 204, 206, 208, 209, 210, 213, 214, 215],
        26: [15, 17, 216, 218, 219, 221, 222, 224, 225, 231, 233],
        27: [15, 17, 234, 236, 237, 239, 240, 242, 243, 249, 251],
        28: [15, 17, 252, 254, 258, 260, 261, 263, 267, 269],
        29: [15, 17, 270, 272, 276, 278, 279, 281, 285, 287],
        30: [15, 17, 288, 290, 291, 293, 294, 296],
        31: [15, 17, 297, 299, 300, 302, 303, 305],
        32: [15, 17, 306, 308, 312, 314],
        33: [15, 17, 315, 317, 321, 323],
        34: [15, 17, 325, 326, 330, 332],
        35: [15, 17, 334, 335, 339, 341],
        36: [348, 350],
        37: [348, 350],
        67: [15, 16, 17, 585, 587, 591, 592, 593, 594, 603, 604, 605, 609, 610, 611, 612, 613, 618, 619, 620, 621, 630, 631, 632, 636],
        68: [15, 16, 17, 585, 587, 591, 592, 593, 594, 603, 604, 605, 609, 610, 611, 612, 613, 618, 619, 620, 621, 630, 631, 632, 636],
        69: [15, 16, 17, 640, 645, 649, 650, 654, 658, 659, 663, 664, 665, 667, 676, 681, 682, 683, 685, 690, 691, 692],
        70: [15, 16, 17, 667, 693, 694, 695, 699, 700, 701, 703, 704, 708, 709, 710, 712, 713, 717, 718, 719],
        71: [15, 16, 17, 721, 730, 735, 736, 737, 739, 740, 744, 745, 746],
        72: [15, 16, 17, 747, 748, 749, 753, 754, 755, 756, 757, 758, 762, 763, 764, 765, 766, 771, 772, 773],
        73: [15, 16, 17, 747, 748, 749, 753, 754, 755, 756, 757, 758, 762, 763, 764, 765, 766, 771, 772, 773],
        74: [15, 781, 782, 790, 791, 799, 800],
        75: [15, 781, 782, 790, 791, 799, 800],
        76: [15, 16, 17, 803, 807, 808, 809, 812, 816, 817, 818],
        77: [15, 16, 17],
        78: [819, 821, 822, 823, 824, 828, 830, 831, 833, 839, 849],
        79: [837, 839, 855, 857, 858, 859, 860, 864, 866, 867, 869, 849, 876],
        80: [837, 882, 884, 885, 886, 887, 891, 893, 894, 896, 900, 876],
        81: [900, 902, 903, 909, 911, 912, 913, 914, 918, 920, 921, 923, 849, 876],
        82: [902, 903, 927, 929, 930, 931, 932, 936, 938, 939, 941, 849],
        83: [900, 902, 903, 945, 947, 948, 949, 950, 954, 956, 957, 959, 849, 876],
        84: [837, 900, 963, 965, 966, 967, 968, 972, 974, 975, 977, 876],
        85: [837, 839, 981, 983, 984, 985, 986, 990, 992, 993, 995, 849, 876],
        39: [361, 362, 371, 380, 389, 398, 399],
        40: [391, 406, 407, 408, 409, 411, 412, 413, 414],
        41: [424, 425, 426, 429, 430, 431, 434],
        42: [434, 442, 443, 444, 447, 448, 449],
        43: [440, 450, 451, 452, 453, 454, 456, 457],
        44: [438, 439, 459, 460, 461, 462, 463, 465, 466, 467],
        45: [438, 439, 469, 470, 471, 474, 475],
        46: [477, 478, 479, 483, 484, 485, 488, 492],
        47: [497, 506, 519, 521],
        48: [497, 501, 502, 503, 510, 511, 512],
        49: [501, 502, 503, 528, 529],
        50: [497, 533, 537, 538, 539],
        51: [495, 524, 528, 529, 530, 542, 546, 547, 548],
        52: [528, 529, 530, 546, 547, 548, 551, 555, 556, 557, 564, 565, 566],
        53: [361, 362, 371, 380, 389, 398, 399],
        54: [406, 407, 408, 409, 411, 412, 413, 571, 576],
        55: [424, 425, 426, 429, 430, 431, 434],
        56: [434, 442, 443, 444, 447, 448, 449],
        57: [440, 450, 451, 452, 453, 454, 456, 457],
        58: [438, 439, 459, 460, 461, 462, 463, 465, 466, 467],
        59: [438, 439, 469, 470, 471, 474, 475],
        60: [477, 478, 479, 483, 484, 485, 488, 492],
        61: [497, 506, 519, 521],
        62: [497, 501, 502, 503, 510, 511, 512],
        63: [501, 502, 503, 528, 529],
        64: [497, 533, 537, 538, 539],
        65: [495, 524, 528, 529, 530, 542, 546, 547, 548],
        66: [528, 529, 530, 546, 547, 548, 551, 555, 556, 557, 564, 565, 566],
        38: [353],
    ]
    static let bindingSignatures: [[Int]] = [
        [448, 960],
        [1472],
        [1600],
        [1796],
        [23518, 24526, 25550, 29124, 30276, 29632, 29700, 32192, 27591],
        [20486],
        [22036, 32272],
        [23553, 32769],
        [22540],
        [25028, 28100],
        [25813, 26581, 27076],
        [28613, 30592],
        [30080],
        [31172, 31236],
        [2112, 4097, 4609, 3073, 3585, 42951],
        [2304, 20996, 4352, 4864, 3328, 3840, 43463],
        [8768, 40963],
        [8964, 21508, 41923],
        [9792, 38851],
        [9988, 46020, 40390, 39363],
        [9730, 37890],
        [9476, 10702, 42439, 46532, 39879, 37831, 47621],
        [10816, 36807, 48701, 50237, 51773, 53821, 54845, 55869],
        [11012, 40902, 37319, 36292, 46652, 48700, 51772, 52796, 53820, 55868],
        [11328, 12865, 13889, 33795, 49161, 50697, 52233, 54281, 55305, 56329],
        [11524, 13056, 14080, 19972, 33733, 47140, 49188, 52260, 53284, 54308, 56356],
        [12228, 34757, 51205],
        [11786, 34306, 51208],
        [12385, 14401, 13409, 15425, 35329, 49672],
        [12556, 14596, 13580, 15620, 35267, 48136],
        [14913, 16481, 15937, 16993],
        [15108, 16652, 16132, 17164],
        [17473, 17985],
        [17668, 18180],
        [18758, 19270],
        [19520],
        [19712],
        [2754, 44672, 43523],
        [2816, 44800],
        [5250, 5760, 6272, 44160],
        [5380, 5888, 6400, 44288],
        [6784, 7296, 45184],
        [6912, 7424, 45312],
        [8576, 8064],
    ]

    static func apply(operation: Int, source: [SourceShapeTransform], corrections: [SourceShapeTransform],
                      sizeFactor: Float, position: inout Float3, rotation: inout simd_quatf, scale: inout Float3) {
        // Source Euler fields can be represented in 0...360; only these skirt inputs
        // use signed values before addition to the other independently sampled angles.
        let num83 = source[94].rotationDegrees.x > 180 ? source[94].rotationDegrees.x - 360 : source[94].rotationDegrees.x
        let num84 = source[97].rotationDegrees.x > 180 ? source[97].rotationDegrees.x - 360 : source[97].rotationDegrees.x
        switch operation {
        case 0:
            scale = Float3(source[0].scale.x, source[0].scale.y, source[0].scale.z)
        case 1:
            scale = Float3(source[1].scale.x, source[1].scale.y, source[1].scale.z)
        case 2:
            scale = Float3(source[1].scale.x, source[1].scale.y, source[1].scale.z)
        case 3:
            let num: Float = corrections[2].position.y
            let num2: Float = corrections[2].scale.x
            let num3: Float = corrections[2].scale.y
            let num4: Float = corrections[2].scale.z
            position.y = source[2].position.y + num
            scale = Float3(source[2].scale.x * source[1].scale.x * sizeFactor + num2, source[2].scale.y * source[1].scale.y * sizeFactor + num3, source[2].scale.z * source[1].scale.z * sizeFactor + num4)
        case 4:
            let y: Float = corrections[1].position.y
            let x: Float = corrections[1].rotationDegrees.x
            let num5: Float = corrections[1].scale.x
            let num6: Float = corrections[1].scale.z
            position.y = y
            position.z = -(source[3].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(x, 0.0, 0.0))
            scale = Float3(source[3].scale.x * source[1].scale.x * sizeFactor + num5, 1.0, source[3].scale.z * source[1].scale.z * sizeFactor + num6)
        case 5:
            let num7: Float = corrections[5].position.z
            let x2: Float = corrections[5].rotationDegrees.x
            let num8: Float = corrections[5].scale.x
            let num9: Float = corrections[5].scale.z
            position.z = -(source[4].position.z + num7)
            rotation = UnityCoordinates.eulerDegrees(Float3(x2, 0.0, 0.0))
            scale = Float3(source[4].scale.x * source[1].scale.x + num8, 1.0, source[4].scale.z * source[1].scale.z + num9)
        case 6:
            let num10: Float = corrections[14].position.x
            let num11: Float = corrections[14].position.y
            let z: Float = corrections[14].position.z
            let num12: Float = corrections[14].scale.y
            let num13: Float = corrections[14].scale.z
            position.x = source[6].position.x + source[5].position.x + num10
            position.y = source[5].position.y + num11
            position.z = -(z)
            scale = Float3(source[5].scale.x, source[5].scale.y * source[1].scale.y + num12, source[5].scale.z * source[6].scale.z * source[1].scale.z + num13)
        case 7:
            let num14: Float = corrections[15].position.x
            let num15: Float = corrections[15].position.y
            let z2: Float = corrections[15].position.z
            let num16: Float = corrections[15].scale.y
            let num17: Float = corrections[15].scale.z
            position.x = source[7].position.x - source[5].position.x + num14
            position.y = source[5].position.y + num15
            position.z = -(z2)
            scale = Float3(source[5].scale.x, source[5].scale.y * source[1].scale.y + num16, source[5].scale.z * source[7].scale.z * source[1].scale.z + num17)
        case 8:
            let num18: Float = corrections[16].position.y
            let num19: Float = corrections[16].scale.x
            let num20: Float = corrections[16].scale.y
            let num21: Float = corrections[16].scale.z
            position.x = source[8].position.x
            position.y = source[5].position.y + num18
            scale = Float3(1.0 + num19, source[5].scale.y * source[1].scale.y + num20, source[5].scale.z * source[8].scale.z * source[1].scale.z + num21)
        case 9:
            let num22: Float = corrections[17].position.y
            let num23: Float = corrections[17].scale.x
            let num24: Float = corrections[17].scale.y
            let num25: Float = corrections[17].scale.z
            position.x = source[9].position.x
            position.y = source[5].position.y + num22
            scale = Float3(1.0 + num23, source[5].scale.y * source[1].scale.y + num24, source[5].scale.z * source[9].scale.z * source[1].scale.z + num25)
        case 10:
            let num26: Float = corrections[18].position.y
            let num27: Float = corrections[18].position.z
            let num28: Float = corrections[18].scale.y
            let num29: Float = corrections[18].scale.z
            position.y = source[10].position.y + num26
            position.z = -(source[10].position.z + num27)
            scale = Float3(1.0, source[10].scale.y * source[1].scale.y + num28, source[10].scale.z * source[1].scale.z + num29)
        case 11:
            let num30: Float = corrections[19].position.y
            let num31: Float = corrections[19].position.z
            let num32: Float = corrections[19].scale.y
            let num33: Float = corrections[19].scale.z
            position.y = source[10].position.y + num30
            position.z = -(source[10].position.z + num31)
            scale = Float3(1.0, source[10].scale.y * source[1].scale.y + num32, source[10].scale.z * source[1].scale.z + num33)
        case 12:
            let y2: Float = corrections[20].position.y
            let num34: Float = corrections[20].scale.y
            let num35: Float = corrections[20].scale.z
            position.y = y2
            scale = Float3(1.0, source[11].scale.y * source[12].scale.y * source[1].scale.y + num34, source[11].scale.z * source[12].scale.z * source[1].scale.z + num35)
        case 13:
            let y3: Float = corrections[21].position.y
            let num36: Float = corrections[21].scale.y
            let num37: Float = corrections[21].scale.z
            position.y = y3
            scale = Float3(1.0, source[11].scale.y * source[12].scale.y * source[1].scale.y + num36, source[11].scale.z * source[12].scale.z * source[1].scale.z + num37)
        case 14:
            let y4: Float = corrections[22].position.y
            position.y = y4
            scale = Float3(1.0, source[13].scale.y * source[1].scale.y, source[13].scale.z * source[1].scale.z)
        case 15:
            let y5: Float = corrections[23].position.y
            position.y = y5
            scale = Float3(1.0, source[13].scale.y * source[1].scale.y, source[13].scale.z * source[1].scale.z)
        case 16:
            let y6: Float = corrections[24].rotationDegrees.y
            let z3: Float = corrections[24].rotationDegrees.z
            let num38: Float = corrections[24].scale.y
            let num39: Float = corrections[24].scale.z
            rotation = UnityCoordinates.eulerDegrees(Float3(0.0, y6, z3))
            scale = Float3(1.0, source[14].scale.y * source[15].scale.y * source[1].scale.y + num38, source[14].scale.z * source[15].scale.z * source[1].scale.z + num39)
        case 17:
            let y7: Float = corrections[25].rotationDegrees.y
            let z4: Float = corrections[25].rotationDegrees.z
            let num40: Float = corrections[25].scale.y
            let num41: Float = corrections[25].scale.z
            rotation = UnityCoordinates.eulerDegrees(Float3(0.0, y7, z4))
            scale = Float3(1.0, source[14].scale.y * source[15].scale.y * source[1].scale.y + num40, source[14].scale.z * source[15].scale.z * source[1].scale.z + num41)
        case 18:
            let num42: Float = corrections[26].scale.x
            let num43: Float = corrections[26].scale.y
            scale = Float3(1.0 + num42, source[16].scale.y * source[1].scale.y + num43, source[16].scale.z * source[1].scale.z)
        case 19:
            let num44: Float = corrections[27].scale.x
            let num45: Float = corrections[27].scale.y
            scale = Float3(1.0 + num44, source[16].scale.y * source[1].scale.y + num45, source[16].scale.z * source[1].scale.z)
        case 20:
            let num46: Float = corrections[4].position.z
            let num47: Float = corrections[4].scale.x
            let num48: Float = corrections[4].scale.z
            position.z = -(source[17].position.z + source[18].position.z + num46)
            scale = Float3(source[17].scale.x * source[1].scale.x + num47, 1.0, source[17].scale.z * source[1].scale.z * source[18].scale.z + num48)
        case 21:
            let num49: Float = corrections[3].position.z
            let num50: Float = corrections[3].scale.x
            let num51: Float = corrections[3].scale.z
            position.y = source[19].position.y + source[20].position.y
            position.z = -(source[19].position.z + source[20].position.z + num49)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[20].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[19].scale.x * source[1].scale.x * source[20].scale.x + num50, source[20].scale.y, source[19].scale.z * source[1].scale.z * source[20].scale.z + num51)
        case 22:
            position.y = source[20].position.y
            position.z = -(source[21].position.z + source[20].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[20].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[21].scale.x * source[1].scale.x * source[20].scale.x, source[20].scale.y, source[21].scale.z * source[1].scale.z * source[20].scale.z)
        case 23:
            let num52: Float = corrections[0].scale.x
            position.z = -(source[22].position.z)
            scale = Float3(source[22].scale.x * source[1].scale.x + num52, 1.0, source[22].scale.z * source[1].scale.z)
        case 24:
            let x3: Float = corrections[28].position.x
            let num53: Float = corrections[28].rotationDegrees.x
            let z5: Float = corrections[28].rotationDegrees.z
            let num54: Float = corrections[28].scale.x
            position.x = x3
            position.y = source[23].position.y
            position.z = -(source[23].position.z + source[22].position.z * 0.3)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[23].rotationDegrees.x + num53, 0.0, z5))
            scale = Float3(source[23].scale.x + (-1.0 + source[22].scale.x) * 0.5 + num54, source[23].scale.y, source[23].scale.z + (-1.0 + source[22].scale.z) * 0.5 + (-1.0 + source[21].scale.z) * 0.5)
        case 25:
            let x4: Float = corrections[29].position.x
            let num55: Float = corrections[29].rotationDegrees.x
            let z6: Float = corrections[29].rotationDegrees.z
            let num56: Float = corrections[29].scale.x
            position.x = x4
            position.y = source[23].position.y
            position.z = -(source[23].position.z + source[22].position.z * 0.3)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[23].rotationDegrees.x + num55, 0.0, z6))
            scale = Float3(source[23].scale.x + (-1.0 + source[22].scale.x) * 0.5 + num56, source[23].scale.y, source[23].scale.z + (-1.0 + source[22].scale.z) * 0.5 + (-1.0 + source[21].scale.z) * 0.5)
        case 26:
            let num57: Float = corrections[6].position.x
            let num58: Float = corrections[6].position.z
            let num59: Float = corrections[6].rotationDegrees.x
            let y8: Float = corrections[6].rotationDegrees.y
            let num60: Float = corrections[6].rotationDegrees.z
            let num61: Float = corrections[6].scale.x
            let num62: Float = corrections[6].scale.z
            position.x = source[24].position.x + source[25].position.x + num57
            position.z = -(source[24].position.z + num58)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[24].rotationDegrees.x + num59, y8, source[24].rotationDegrees.z + num60))
            scale = Float3(source[24].scale.x * source[25].scale.x * source[1].scale.x + num61, 1.0, source[24].scale.z * source[25].scale.z * source[1].scale.z + num62)
        case 27:
            let num63: Float = corrections[7].position.x
            let num64: Float = corrections[7].position.z
            let num65: Float = corrections[7].rotationDegrees.x
            let y9: Float = corrections[7].rotationDegrees.y
            let num66: Float = corrections[7].rotationDegrees.z
            let num67: Float = corrections[7].scale.x
            let num68: Float = corrections[7].scale.z
            position.x = source[26].position.x + source[27].position.x + num63
            position.z = -(source[26].position.z + num64)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[26].rotationDegrees.x + num65, y9, source[26].rotationDegrees.z + num66))
            scale = Float3(source[26].scale.x * source[27].scale.x * source[1].scale.x + num67, 1.0, source[26].scale.z * source[27].scale.z * source[1].scale.z + num68)
        case 28:
            let num69: Float = corrections[8].position.x
            let num70: Float = corrections[8].scale.x
            let num71: Float = corrections[8].scale.z
            position.x = source[28].position.x + source[29].position.x + num69
            position.z = -(source[28].position.z + source[29].position.z)
            scale = Float3(source[28].scale.x * source[29].scale.x * source[1].scale.x + num70, 1.0, source[28].scale.z * source[29].scale.z * source[1].scale.z + num71)
        case 29:
            let num72: Float = corrections[9].position.x
            let num73: Float = corrections[9].scale.x
            let num74: Float = corrections[9].scale.z
            position.x = source[30].position.x + source[31].position.x + num72
            position.z = -(source[30].position.z + source[31].position.z)
            scale = Float3(source[30].scale.x * source[31].scale.x * source[1].scale.x + num73, 1.0, source[30].scale.z * source[31].scale.z * source[1].scale.z + num74)
        case 30:
            let num75: Float = corrections[10].position.z
            let num76: Float = corrections[10].scale.x
            position.x = source[32].position.x
            position.z = -(source[32].position.z + num75)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[32].rotationDegrees.x, 0.0, source[32].rotationDegrees.z))
            scale = Float3(source[32].scale.x * source[1].scale.x + num76, 1.0, source[32].scale.z * source[1].scale.z)
        case 31:
            let num77: Float = corrections[11].position.z
            let num78: Float = corrections[11].scale.x
            position.x = source[33].position.x
            position.z = -(source[33].position.z + num77)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[33].rotationDegrees.x, 0.0, source[33].rotationDegrees.z))
            scale = Float3(source[33].scale.x * source[1].scale.x + num78, 1.0, source[33].scale.z * source[1].scale.z)
        case 32:
            let num79: Float = corrections[12].scale.x
            let num80: Float = corrections[12].scale.z
            position.x = source[34].position.x
            position.z = -(source[34].position.z)
            scale = Float3(source[34].scale.x * source[1].scale.x + num79, 1.0, source[34].scale.z * source[1].scale.z + num80)
        case 33:
            let num81: Float = corrections[13].scale.x
            let num82: Float = corrections[13].scale.z
            position.x = source[35].position.x
            position.z = -(source[35].position.z)
            scale = Float3(source[35].scale.x * source[1].scale.x + num81, 1.0, source[35].scale.z * source[1].scale.z + num82)
        case 34:
            position.y = source[36].position.y
            position.z = -(source[36].position.z)
            scale = Float3(source[36].scale.x * source[1].scale.x, 1.0, source[36].scale.z * source[1].scale.z)
        case 35:
            position.y = source[37].position.y
            position.z = -(source[37].position.z)
            scale = Float3(source[37].scale.x * source[1].scale.x, 1.0, source[37].scale.z * source[1].scale.z)
        case 36:
            scale = Float3(source[38].scale.x, 1.0, source[38].scale.z)
        case 37:
            scale = Float3(source[38].scale.x, 1.0, source[38].scale.z)
        case 67:
            position.x = source[65].position.x + source[66].position.x + source[67].position.x + source[68].position.x + source[69].position.x + source[70].position.x
            position.y = source[67].position.y + source[68].position.y + source[70].position.y
            position.z = -(source[65].position.z + source[67].position.z + source[70].position.z)
            scale = Float3(source[65].scale.x * source[67].scale.x * source[68].scale.x * source[1].scale.x * source[70].scale.x, source[65].scale.y * source[67].scale.y * source[68].scale.y * source[1].scale.y * source[70].scale.x, source[65].scale.z * source[67].scale.z * source[68].scale.z * source[1].scale.z * source[70].scale.x)
        case 68:
            position.x = 0.0 - source[65].position.x - source[66].position.x - source[67].position.x - source[68].position.x - source[69].position.x - source[70].position.x
            position.y = source[67].position.y + source[68].position.y + source[70].position.y
            position.z = -(source[65].position.z + source[67].position.z + source[70].position.z)
            scale = Float3(source[65].scale.x * source[67].scale.x * source[68].scale.x * source[1].scale.x * source[70].scale.x, source[65].scale.y * source[67].scale.y * source[68].scale.y * source[1].scale.y * source[70].scale.x, source[65].scale.z * source[67].scale.z * source[68].scale.z * source[1].scale.z * source[70].scale.x)
        case 69:
            position.y = source[71].position.y + source[72].position.y + source[73].position.y + source[74].position.y + source[75].position.y + source[76].position.y
            position.z = -(source[72].position.z + source[73].position.z)
            scale = Float3(source[71].scale.x * source[72].scale.x * source[1].scale.x * source[73].scale.x * source[76].scale.x * source[75].scale.x, source[71].scale.x * source[72].scale.x * source[1].scale.y * source[73].scale.y * source[76].scale.y * source[75].scale.y, source[71].scale.x * source[72].scale.x * source[1].scale.z * source[73].scale.z * source[76].scale.z * source[75].scale.z)
        case 70:
            position.x = source[77].position.x
            position.y = source[77].position.y + source[74].position.y * 2.0 + source[78].position.y + source[79].position.y
            position.z = -(source[77].position.z + source[78].position.z + source[79].position.z)
            scale = Float3(source[77].scale.x * source[78].scale.x * source[1].scale.x * source[79].scale.x, source[77].scale.y * source[78].scale.y * source[1].scale.y * source[79].scale.y, source[77].scale.z * source[78].scale.z * source[1].scale.z * source[79].scale.z)
        case 71:
            position.y = source[80].position.y + source[81].position.y + source[82].position.y
            position.z = -(source[82].position.z)
            scale = Float3(source[81].scale.x * source[82].scale.x * source[1].scale.x, source[81].scale.y * source[82].scale.y * source[1].scale.y, source[81].scale.z * source[82].scale.z * source[1].scale.z)
        case 72:
            position.x = source[83].position.x + source[84].position.x + source[85].position.x
            position.y = source[83].position.y + source[84].position.y + source[85].position.y
            position.z = -(source[83].position.z + source[84].position.z)
            scale = Float3(source[83].scale.x * source[84].scale.x * source[85].scale.x * source[1].scale.x, source[83].scale.y * source[84].scale.y * source[85].scale.y * source[1].scale.y, source[83].scale.z * source[84].scale.z * source[85].scale.z * source[1].scale.z)
        case 73:
            position.x = 0.0 - source[83].position.x - source[84].position.x - source[85].position.x
            position.y = source[83].position.y + source[84].position.y + source[85].position.y
            position.z = -(source[83].position.z + source[84].position.z)
            scale = Float3(source[83].scale.x * source[84].scale.x * source[85].scale.x * source[1].scale.x, source[83].scale.y * source[84].scale.y * source[85].scale.y * source[1].scale.y, source[83].scale.z * source[84].scale.z * source[85].scale.z * source[1].scale.z)
        case 74:
            scale = Float3(1.0, source[86].scale.y * source[87].scale.y * source[88].scale.y * source[1].scale.x, source[86].scale.z * source[87].scale.z * source[88].scale.z * source[1].scale.x)
        case 75:
            scale = Float3(1.0, source[86].scale.y * source[87].scale.y * source[88].scale.y * source[1].scale.x, source[86].scale.z * source[87].scale.z * source[88].scale.z * source[1].scale.x)
        case 76:
            position.z = -(source[89].position.z + source[90].position.z)
            scale = Float3(source[89].scale.x * source[90].scale.x * source[1].scale.x, source[89].scale.y * source[90].scale.y * source[1].scale.y, source[89].scale.z * source[90].scale.z * source[1].scale.z)
        case 77:
            scale = Float3(source[1].scale.x, source[1].scale.y, source[1].scale.z)
        case 78:
            position.x = source[91].position.x + source[92].position.x
            position.z = -(source[91].position.z + source[92].position.z + source[93].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[91].rotationDegrees.x + source[92].rotationDegrees.x + source[92].rotationDegrees.z + num83, source[91].rotationDegrees.y, source[91].rotationDegrees.z))
        case 79:
            position.x = source[95].position.x + source[96].position.x - source[93].position.x * 0.5
            position.z = -(source[95].position.z + source[96].position.z + source[93].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[95].rotationDegrees.x + source[96].rotationDegrees.x + source[96].rotationDegrees.z + num83 * 0.6 + num84 * 0.6, source[95].rotationDegrees.y, source[95].rotationDegrees.z))
        case 80:
            position.x = source[98].position.x + source[99].position.x + source[100].position.x * 0.5 - source[93].position.x
            position.z = -(source[98].position.z + source[99].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[98].rotationDegrees.x + source[99].rotationDegrees.x + source[99].rotationDegrees.z + num84, source[98].rotationDegrees.y, source[98].rotationDegrees.z))
        case 81:
            position.x = source[101].position.x + source[102].position.x + source[100].position.x
            position.z = -(source[101].position.z + source[102].position.z + source[100].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[101].rotationDegrees.x + source[102].rotationDegrees.x + source[102].rotationDegrees.z + num83 * 0.6 + num84 * 0.6 + source[100].rotationDegrees.x, source[101].rotationDegrees.y, source[101].rotationDegrees.z))
        case 82:
            position.x = source[103].position.x + source[104].position.x
            position.z = -(source[103].position.z + source[104].position.z + source[100].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[103].rotationDegrees.x + source[104].rotationDegrees.x + source[104].rotationDegrees.z + num83 + source[100].rotationDegrees.x, source[103].rotationDegrees.y, source[103].rotationDegrees.z))
        case 83:
            position.x = source[105].position.x + source[106].position.x - source[100].position.x
            position.z = -(source[105].position.z + source[106].position.z + source[100].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[105].rotationDegrees.x + source[106].rotationDegrees.x + source[106].rotationDegrees.z + num83 * 0.6 + num84 * 0.6 + source[100].rotationDegrees.x, source[105].rotationDegrees.y, source[105].rotationDegrees.z))
        case 84:
            position.x = source[107].position.x + source[108].position.x - source[100].position.x * 0.5 + source[93].position.x
            position.z = -(source[107].position.z + source[108].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[107].rotationDegrees.x + source[108].rotationDegrees.x + source[108].rotationDegrees.z + num84, source[107].rotationDegrees.y, source[107].rotationDegrees.z))
        case 85:
            position.x = source[109].position.x + source[110].position.x + source[93].position.x * 0.5
            position.z = -(source[109].position.z + source[110].position.z + source[93].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[109].rotationDegrees.x + source[110].rotationDegrees.x + source[110].rotationDegrees.z + num83 * 0.6 + num84 * 0.6, source[109].rotationDegrees.y, source[109].rotationDegrees.z))
        case 39:
            position.y = source[40].position.y
            position.z = -(source[41].position.z + source[42].position.z + source[43].position.z + source[40].position.z + source[44].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[44].rotationDegrees.x, 0.0, 0.0))
        case 40:
            position.x = source[46].position.x
            position.y = source[45].position.y
            position.z = -(source[45].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[45].rotationDegrees.x, source[43].rotationDegrees.y + source[45].rotationDegrees.y, 0.0))
            scale = Float3(source[45].scale.x, source[45].scale.y, source[45].scale.z)
        case 41:
            position.y = source[47].position.y
            position.z = -(source[47].position.z + source[48].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[47].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[47].scale.x, source[47].scale.y, source[47].scale.z)
        case 42:
            position.y = source[49].position.y
            position.z = -(source[49].position.z + source[48].position.z / 2.0)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[49].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[49].scale.x, source[49].scale.y, source[49].scale.z)
        case 43:
            position.x = source[50].position.x
            position.y = source[50].position.y
            position.z = -(source[50].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[50].rotationDegrees.x, source[50].rotationDegrees.y, 0.0))
            scale = Float3(source[50].scale.x, source[50].scale.y, source[48].scale.z)
        case 44:
            position.x = source[51].position.x
            position.y = source[51].position.y
            position.z = -(source[51].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[51].rotationDegrees.x, source[51].rotationDegrees.y, 0.0))
            scale = Float3(source[51].scale.x * source[48].scale.x, source[51].scale.y * source[48].scale.y, source[51].scale.z)
        case 45:
            position.y = source[52].position.y
            position.z = -(source[52].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[52].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[52].scale.x * source[48].scale.x, source[52].scale.y * source[48].scale.y, 1.0)
        case 46:
            position.x = source[53].position.x
            position.y = source[53].position.y
            position.z = -(source[53].position.z + source[54].position.z)
            scale = Float3(source[53].scale.x * source[54].scale.x, source[53].scale.y * source[54].scale.x, source[53].scale.z * source[54].scale.x)
        case 47:
            position.z = -(source[55].position.z + source[56].position.z)
            scale = Float3(source[57].scale.x, source[57].scale.x, source[57].scale.z)
        case 48:
            position.z = -((0.0 - (source[55].position.z - 0.01)) * 1.2)
            scale = Float3(source[55].scale.x * source[56].scale.x, source[55].scale.y * source[56].scale.y, source[55].scale.z * source[56].scale.z)
        case 49:
            scale = Float3(1.0 / source[55].scale.x * (source[58].scale.x * 1.2), 1.0 / source[55].scale.y * (source[58].scale.y * 1.2), 1.0 / source[55].scale.z)
        case 50:
            position.z = -(0.0025 + source[59].position.z - (source[55].position.z - 0.01) * 1.0)
            scale = Float3(0.1 + source[59].scale.y * source[59].scale.x, 0.1 + source[59].scale.y * source[59].scale.x, 0.1 + source[59].scale.z * source[59].scale.x)
        case 51:
            position.z = -(0.004 + source[60].position.z + source[55].position.x + source[58].position.z)
            scale = Float3(source[60].scale.x * source[58].scale.x, source[60].scale.y * source[58].scale.y, source[60].scale.z * source[58].scale.z)
        case 52:
            position.z = -(source[61].position.z)
            scale = Float3(1.0 * source[61].scale.x / source[60].scale.x / source[58].scale.x * source[62].scale.x, 1.0 * source[61].scale.y / source[60].scale.y / source[58].scale.y * source[62].scale.y, 1.0 * source[61].scale.z / source[60].scale.z / source[58].scale.z * source[62].scale.z)
        case 53:
            position.y = source[40].position.y
            position.z = -(source[41].position.z + source[42].position.z + source[43].position.z + source[40].position.z + source[44].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[44].rotationDegrees.x, 0.0, 0.0))
        case 54:
            position.x = source[64].position.x
            position.y = source[45].position.y
            position.z = -(source[45].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[45].rotationDegrees.x, source[63].rotationDegrees.y - source[45].rotationDegrees.y, 0.0))
            scale = Float3(source[45].scale.x, source[45].scale.y, source[45].scale.z)
        case 55:
            position.y = source[47].position.y
            position.z = -(source[47].position.z + source[48].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[47].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[47].scale.x, source[47].scale.y, source[47].scale.z)
        case 56:
            position.y = source[49].position.y
            position.z = -(source[49].position.z + source[48].position.z / 2.0)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[49].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[49].scale.x, source[49].scale.y, source[49].scale.z)
        case 57:
            position.x = 0.0 - source[50].position.x
            position.y = source[50].position.y
            position.z = -(source[50].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[50].rotationDegrees.x, 0.0 - source[50].rotationDegrees.y, 0.0))
            scale = Float3(source[50].scale.x, source[50].scale.y, source[48].scale.z)
        case 58:
            position.x = 0.0 - source[51].position.x
            position.y = source[51].position.y
            position.z = -(source[51].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[51].rotationDegrees.x, 0.0 - source[51].rotationDegrees.y, 0.0))
            scale = Float3(source[51].scale.x * source[48].scale.x, source[51].scale.y * source[48].scale.y, source[51].scale.z)
        case 59:
            position.y = source[52].position.y
            position.z = -(source[52].position.z)
            rotation = UnityCoordinates.eulerDegrees(Float3(source[52].rotationDegrees.x, 0.0, 0.0))
            scale = Float3(source[52].scale.x * source[48].scale.x, source[52].scale.y * source[48].scale.y, 1.0)
        case 60:
            position.x = 0.0 - source[53].position.x
            position.y = source[53].position.y
            position.z = -(source[53].position.z + source[54].position.z)
            scale = Float3(source[53].scale.x * source[54].scale.x, source[53].scale.y * source[54].scale.x, source[53].scale.z * source[54].scale.x)
        case 61:
            position.z = -(source[55].position.z + source[56].position.z)
            scale = Float3(source[57].scale.x, source[57].scale.x, source[57].scale.z)
        case 62:
            position.z = -((0.0 - (source[55].position.z - 0.01)) * 1.2)
            scale = Float3(source[55].scale.x * source[56].scale.x, source[55].scale.y * source[56].scale.y, source[55].scale.z * source[56].scale.z)
        case 63:
            scale = Float3(1.0 / source[55].scale.x * (source[58].scale.x * 1.2), 1.0 / source[55].scale.y * (source[58].scale.y * 1.2), 1.0 / source[55].scale.z)
        case 64:
            position.z = -(0.0025 + source[59].position.z - (source[55].position.z - 0.01) * 1.0)
            scale = Float3(0.1 + source[59].scale.y * source[59].scale.x, 0.1 + source[59].scale.y * source[59].scale.x, 0.1 + source[59].scale.z * source[59].scale.x)
        case 65:
            position.z = -(0.004 + source[60].position.z + source[55].position.x + source[58].position.z)
            scale = Float3(source[60].scale.x * source[58].scale.x, source[60].scale.y * source[58].scale.y, source[60].scale.z * source[58].scale.z)
        case 66:
            position.z = -(source[61].position.z)
            scale = Float3(1.0 * source[61].scale.x / source[60].scale.x / source[58].scale.x * source[62].scale.x, 1.0 * source[61].scale.y / source[60].scale.y / source[58].scale.y * source[62].scale.y, 1.0 * source[61].scale.z / source[60].scale.z / source[58].scale.z * source[62].scale.z)
        default: break
        }
    }
}
