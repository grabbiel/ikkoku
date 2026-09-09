import Foundation
import simd
import CoreMath

public struct RGB: Codable, Sendable, Equatable, Hashable {
    public var r: Float, g: Float, b: Float
    public init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) { r = Float((hex >> 16) & 0xFF) / 255; g = Float((hex >> 8) & 0xFF) / 255; b = Float(hex & 0xFF) / 255 }
    public var float3: Float3 { Float3(r, g, b) }
    public func float4(_ a: Float = 1) -> Float4 { Float4(r, g, b, a) }
    /// sRGB → linear, for material factors.
    public var linear: Float3 {
        func f(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return Float3(f(r), f(g), f(b))
    }
    public static let white = RGB(1, 1, 1)
    public static let black = RGB(0, 0, 0)
    public func mixed(_ o: RGB, _ t: Float) -> RGB { RGB(lerp(r, o.r, t), lerp(g, o.g, t), lerp(b, o.b, t)) }
    public func scaled(_ k: Float) -> RGB { RGB(min(r * k, 1), min(g * k, 1), min(b * k, 1)) }
}

public enum Sex: String, Codable, Sendable, CaseIterable { case female = "f", male = "m" }

public struct Profile: Codable, Sendable, Equatable {
    public var name = "Ikkoku"
    public var nickname = ""
    public var personality = "Cheerful"
    public var bloodType = "A"
    public var birthMonth = 4
    public var birthDay = 1
    public var club = "None"
    public var traits: [String] = []
    public var hobbies: [String] = []
    public var notes = ""
    public init() {}
}

public struct MakeupLayer: Codable, Sendable, Equatable {
    public var color: RGB
    public var strength: Float     // 0…1
    public init(color: RGB, strength: Float) { self.color = color; self.strength = strength }
}

public struct FaceDefinition: Codable, Sendable, Equatable {
    public var sliders: [String: Float] = [:]     // slider id → −100…100
    public var eyebrowStyle = 0
    public var eyebrowColor = RGB(hex: 0x4A2E2A)
    public var eyelashStyle = 0
    public var eyelashColor = RGB(hex: 0x2B1B22)
    public var irisStyle = 0
    public var irisColorLeft = RGB(hex: 0x4E8FD9)
    public var irisColorRight = RGB(hex: 0x4E8FD9)
    public var sameIrisColor = true
    public var irisSize: Float = 0                 // −100…100
    public var highlightStyle = 0
    public var highlightStrength: Float = 1
    public var eyeWhiteColor = RGB(hex: 0xFFFFFF)
    public var eyeshadow = MakeupLayer(color: RGB(hex: 0xC98BA6), strength: 0.0)
    public var blush = MakeupLayer(color: RGB(hex: 0xF2A6B4), strength: 0.35)
    public var lip = MakeupLayer(color: RGB(hex: 0xE58BA0), strength: 0.35)
    public init() {}
}

public struct BodyDefinition: Codable, Sendable, Equatable {
    public var bodyID = "body_f"
    public var sliders: [String: Float] = [:]
    public var skinTone = RGB(hex: 0xFFE3D6)
    public var skinGloss: Float = 0.35
    public var skinShadeTint = RGB(hex: 0xE3B7C0)
    public var nailColor = RGB(hex: 0xFFC8C8)
    public var sunburn: Float = 0
    public init() {}
}

public enum HairSlot: String, Codable, Sendable, CaseIterable { case back, front, side, extra }

public struct HairPart: Codable, Sendable, Equatable {
    public var styleID: String?
    public init(styleID: String? = nil) { self.styleID = styleID }
}

public struct HairDefinition: Codable, Sendable, Equatable {
    public var parts: [HairSlot: HairPart] = [.back: HairPart(styleID: "bob")]
    public var baseColor = RGB(hex: 0x6A4A3F)
    public var shadeColor = RGB(hex: 0x4A2F33)
    public var highlightColor = RGB(hex: 0xFFF4E0)
    public var outlineColor = RGB(hex: 0x2E1C22)
    public var gloss: Float = 0.6
    public var linkColors = true
    public init() {}
}

public enum ClothSlot: String, Codable, Sendable, CaseIterable {
    case top, bottom, bra, underwear, gloves, pantyhose, socks, shoesIn = "shoes_in", shoesOut = "shoes_out"
    public var label: String {
        switch self {
        case .top: return "Top"; case .bottom: return "Bottom"; case .bra: return "Bra"; case .underwear: return "Underwear"
        case .gloves: return "Gloves"; case .pantyhose: return "Pantyhose"; case .socks: return "Socks"
        case .shoesIn: return "Shoes (indoor)"; case .shoesOut: return "Shoes (outdoor)"
        }
    }
}

public struct ClothItem: Codable, Sendable, Equatable {
    public var itemID: String?
    public var colors: [RGB] = [RGB(hex: 0xF4F4F8), RGB(hex: 0x2E3A6B), RGB(hex: 0xD84B5A)]
    public var pattern = 0
    public var patternColor = RGB(hex: 0xFFFFFF)
    public var patternScale: Float = 4
    public var gloss: Float = 0.12
    public init(itemID: String? = nil) { self.itemID = itemID }
}

public enum ClothState: String, Codable, Sendable, CaseIterable { case on, half, off }

public struct Outfit: Codable, Sendable, Equatable {
    public var name: String
    public var items: [ClothSlot: ClothItem] = [:]
    public var states: [ClothSlot: ClothState] = [:]
    public var outdoorShoes = false
    public init(name: String) { self.name = name }
    public static let defaultNames = ["School (indoors)", "School (outdoors)", "Gym", "Swimsuit", "Club", "Casual", "Nightwear"]
}

public struct AccessoryDefinition: Codable, Sendable, Equatable {
    public var itemID: String?
    public var parent = "head"
    public var position = Float3.zero
    public var rotation = Float3.zero   // degrees
    public var scale = Float3(repeating: 1)
    public var colors: [RGB] = [RGB(hex: 0xE04E6B), RGB(hex: 0xFFFFFF), RGB(hex: 0xC9A34E)]
    public var visible = true
    /// nil/true: position is relative to the catalog's default attach offset.
    public var useDefaultOffset: Bool? = nil
    public init(itemID: String? = nil) { self.itemID = itemID }
}

public struct ExpressionState: Codable, Sendable, Equatable {
    public var eyebrows = 0        // pattern index
    public var eyes = 0
    public var mouth = 0
    public var eyeOpen: Float = 1
    public var mouthOpen: Float = 0
    public var blush: Float = 0
    public var gazeMode = 1        // 0 front, 1 follow camera, 2 avert, 3 fixed target
    public var gazeTarget = Float3(0, 1.4, 2)
    public var blink = true
    /// Head turns toward the gaze target as well (Koikatsu "neck look"). nil = off.
    public var headLook: Bool? = nil
    public init() {}
}

/// Everything about one character. Saved as JSON inside a PNG "card".
public struct CharacterCard: Codable, Sendable, Equatable, Identifiable {
    public var version = 1
    public var id = UUID()
    public var sex: Sex = .female
    public var profile = Profile()
    public var face = FaceDefinition()
    public var body = BodyDefinition()
    public var hair = HairDefinition()
    public var outfits: [Outfit] = Outfit.defaultNames.map { Outfit(name: $0) }
    public var currentOutfit = 0
    public var accessories: [AccessoryDefinition] = (0..<20).map { _ in AccessoryDefinition() }
    public var expression = ExpressionState()

    public init() {}

    public static func defaultFemale() -> CharacterCard {
        var c = CharacterCard()
        c.sex = .female
        c.body.bodyID = "body_f"
        c.profile.name = "Hana"
        c.hair.parts = [.back: HairPart(styleID: "bob")]
        var o = c.outfits[0]
        o.items[.top] = ClothItem(itemID: "top_sailor")
        o.items[.bottom] = ClothItem(itemID: "bottom_skirt_pleated")
        o.items[.socks] = ClothItem(itemID: "socks_knee")
        o.items[.shoesIn] = ClothItem(itemID: "shoes_in_loafers")
        o.items[.bra] = ClothItem(itemID: "bra_plain")
        o.items[.underwear] = ClothItem(itemID: "underwear_plain")
        c.outfits[0] = o
        var casual = c.outfits[5]
        casual.items[.top] = ClothItem(itemID: "top_tshirt")
        casual.items[.bottom] = ClothItem(itemID: "bottom_shorts")
        casual.items[.socks] = ClothItem(itemID: "socks_ankle")
        casual.items[.shoesIn] = ClothItem(itemID: "shoes_out_sneakers")
        casual.items[.bra] = ClothItem(itemID: "bra_plain")
        casual.items[.underwear] = ClothItem(itemID: "underwear_plain")
        c.outfits[5] = casual
        c.accessories[0] = AccessoryDefinition(itemID: "ribbon")
        return c
    }

    public static func defaultMale() -> CharacterCard {
        var c = CharacterCard()
        c.sex = .male
        c.body.bodyID = "body_m"
        c.profile.name = "Kai"
        c.hair.parts = [.back: HairPart(styleID: "short_m")]
        c.hair.baseColor = RGB(hex: 0x2F2A33)
        c.face.irisColorLeft = RGB(hex: 0x5C4A3C); c.face.irisColorRight = c.face.irisColorLeft
        c.face.blush.strength = 0.1; c.face.lip.strength = 0.1
        var o = c.outfits[0]
        o.items[.top] = ClothItem(itemID: "top_shirt_m")
        o.items[.bottom] = ClothItem(itemID: "bottom_trousers_m")
        o.items[.socks] = ClothItem(itemID: "socks_ankle_m")
        o.items[.shoesIn] = ClothItem(itemID: "shoes_in_loafers_m")
        o.items[.underwear] = ClothItem(itemID: "underwear_plain_m")
        o.items[.top]?.colors = [RGB(hex: 0xF4F6FA), RGB(hex: 0x2E3A6B), RGB(hex: 0xD84B5A)]
        o.items[.bottom]?.colors = [RGB(hex: 0x3A3F55), RGB(hex: 0x2E3A6B), RGB(hex: 0xD84B5A)]
        c.outfits[0] = o
        var casual = c.outfits[5]
        casual.items[.top] = ClothItem(itemID: "top_shirt_m")
        casual.items[.bottom] = ClothItem(itemID: "bottom_trousers_m")
        casual.items[.socks] = ClothItem(itemID: "socks_ankle_m")
        casual.items[.shoesIn] = ClothItem(itemID: "shoes_out_sneakers_m")
        casual.items[.underwear] = ClothItem(itemID: "underwear_plain_m")
        casual.items[.top]?.colors = [RGB(hex: 0x5D8C6E), RGB(hex: 0xFFFFFF), RGB(hex: 0xFFFFFF)]
        casual.items[.bottom]?.colors = [RGB(hex: 0x4C5A7A), RGB(hex: 0xFFFFFF), RGB(hex: 0xFFFFFF)]
        c.outfits[5] = casual
        return c
    }

    public var outfit: Outfit {
        get { outfits[clamp(currentOutfit, 0, outfits.count - 1)] }
        set { outfits[clamp(currentOutfit, 0, outfits.count - 1)] = newValue }
    }

    public func slider(_ id: String) -> Float { face.sliders[id] ?? body.sliders[id] ?? 0 }

    public mutating func setSlider(_ id: String, _ value: Float) {
        let v = clamp(value, -100, 100)
        if SliderRegistry.shared.slider(id)?.tab == .face { face.sliders[id] = v } else { body.sliders[id] = v }
    }
}
