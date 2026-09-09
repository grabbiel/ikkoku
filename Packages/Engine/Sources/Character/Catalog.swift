import Foundation
import simd
import CoreMath
import Assets

/// `Assets/catalog.json` — the list of everything the maker and studio can pick from.
public struct Catalog: Codable, Sendable {
    public struct Body: Codable, Sendable, Identifiable {
        public var id: String; public var sex: String; public var file: String; public var regionsFile: String?
        public var textures: [String: String]?     // "skinBase", "skinDetail"
        public var bones: [String]?; public var morphs: [String]?
    }
    public struct Hair: Codable, Sendable, Identifiable {
        public var id: String; public var file: String; public var sex: String?; public var name: String; public var slot: String?
        public var strandUV: Bool?; public var chainBones: [String]?; public var parts: [String]?
    }
    public struct Cloth: Codable, Sendable, Identifiable {
        public var id: String; public var slot: String; public var file: String; public var sex: String?; public var name: String
        public var colors: [String]?; public var hideBody: [String]?; public var colorMask: String?; public var bodyMask: String?
    }
    public struct Accessory: Codable, Sendable, Identifiable {
        public var id: String; public var file: String; public var parent: String?; public var name: String; public var colors: [String]?
        public var offset: [Float]?
        public var offsetVector: Float3 { offset.flatMap { $0.count == 3 ? Float3($0[0], $0[1], $0[2]) : nil } ?? .zero }
    }
    public struct Item: Codable, Sendable, Identifiable {
        public var id: String; public var file: String; public var category: String; public var name: String
    }
    public struct Textures: Codable, Sendable {
        public var iris: [String]?; public var highlight: [String]?; public var eyebrow: [String]?; public var eyelash: [String]?; public var patterns: [String]?
        public var eyeWhite: String?
        public var hairStrand: String?
        public var faceOverlays: [String: String]?   // "blush", "eyeshadow", "lip"
        public var skin: [String: String]?           // legacy: "f_base"
        public var overlays: [String: String]?       // legacy
        public init() {}
    }

    public var version: Int = 1
    public var regions: [String: Int] = [:]
    public var bodies: [Body] = []
    public var hair: [Hair] = []
    public var clothes: [Cloth] = []
    public var accessories: [Accessory] = []
    public var items: [Item] = []
    public var textures: Textures = Textures()

    public init() {}

    public static func load(url: URL) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    public func hair(_ id: String) -> Hair? { hair.first { $0.id == id } }
    public func cloth(_ id: String) -> Cloth? { clothes.first { $0.id == id } }
    public func accessory(_ id: String) -> Accessory? { accessories.first { $0.id == id } }
    public func item(_ id: String) -> Item? { items.first { $0.id == id } }
    public func body(_ id: String) -> Body? { bodies.first { $0.id == id } }
    public func clothes(slot: String, sex: Sex) -> [Cloth] { clothes.filter { $0.slot == slot && ($0.sex == nil || $0.sex == "any" || $0.sex == sex.rawValue) } }
    public func hair(for sex: Sex) -> [Hair] { hair.filter { $0.sex == nil || $0.sex == "any" || $0.sex == sex.rawValue } }
}
