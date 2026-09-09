import Foundation

// Minimal glTF 2.0 schema — only what Ikkoku consumes.
struct GLTFRoot: Codable {
    struct Asset: Codable { var version: String; var generator: String? }
    struct Scene: Codable { var name: String?; var nodes: [Int]? }
    struct Node: Codable {
        var name: String?
        var children: [Int]?
        var mesh: Int?
        var skin: Int?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
        var matrix: [Float]?
        var extras: JSONValue?
    }
    struct Primitive: Codable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?
        var targets: [[String: Int]]?
        var extras: JSONValue?
    }
    struct Mesh: Codable {
        var name: String?
        var primitives: [Primitive]
        var weights: [Float]?
        var extras: JSONValue?
    }
    struct Accessor: Codable {
        struct Sparse: Codable {
            struct Indices: Codable { var bufferView: Int; var byteOffset: Int?; var componentType: Int }
            struct Values: Codable { var bufferView: Int; var byteOffset: Int? }
            var count: Int
            var indices: Indices
            var values: Values
        }
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
        var min: [Float]?
        var max: [Float]?
        var sparse: Sparse?
    }
    struct BufferView: Codable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }
    struct Buffer: Codable { var byteLength: Int; var uri: String? }
    struct TextureInfo: Codable { var index: Int; var texCoord: Int? }
    struct PBR: Codable {
        var baseColorFactor: [Float]?
        var baseColorTexture: TextureInfo?
        var metallicFactor: Float?
        var roughnessFactor: Float?
    }
    struct Material: Codable {
        var name: String?
        var pbrMetallicRoughness: PBR?
        var normalTexture: TextureInfo?
        var emissiveFactor: [Float]?
        var alphaMode: String?
        var alphaCutoff: Float?
        var doubleSided: Bool?
        var extras: JSONValue?
    }
    struct Texture: Codable { var source: Int?; var sampler: Int? }
    struct Image: Codable { var uri: String?; var mimeType: String?; var bufferView: Int?; var name: String? }
    struct Skin: Codable { var name: String?; var inverseBindMatrices: Int?; var skeleton: Int?; var joints: [Int] }

    var asset: Asset
    var scene: Int?
    var scenes: [Scene]?
    var nodes: [Node]?
    var meshes: [Mesh]?
    var accessors: [Accessor]?
    var bufferViews: [BufferView]?
    var buffers: [Buffer]?
    var materials: [Material]?
    var textures: [Texture]?
    var images: [Image]?
    var skins: [Skin]?
    var extras: JSONValue?
}
