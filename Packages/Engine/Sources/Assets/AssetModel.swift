import Foundation
import simd
import CoreMath

/// One drawable primitive: a triangle list with optional skin and morph data.
public struct MeshData: Sendable {
    public var name: String
    public var positions: [Float3]
    public var normals: [Float3]
    public var tangents: [Float4]          // empty if absent
    public var uvs: [Float2]               // empty if absent
    public var colors: [Float4]            // empty if absent (linear rgba 0…1)
    public var joints: [SIMD4<UInt16>]     // empty if not skinned
    public var weights: [Float4]
    public var indices: [UInt32]
    public var morphTargets: [MorphTarget]
    public var materialIndex: Int?
    public var regions: [UInt8]            // `_REGION` custom attribute, empty if absent
    public var extras: JSONValue?
    public var bounds: AABB

    public struct MorphTarget: Sendable {
        public var name: String
        public var positionDeltas: [Float3]
        public var normalDeltas: [Float3]  // empty if absent
        public init(name: String, positionDeltas: [Float3], normalDeltas: [Float3]) {
            self.name = name; self.positionDeltas = positionDeltas; self.normalDeltas = normalDeltas
        }
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var isSkinned: Bool { !joints.isEmpty }

    public init(name: String, positions: [Float3], normals: [Float3], tangents: [Float4] = [], uvs: [Float2] = [],
                colors: [Float4] = [], joints: [SIMD4<UInt16>] = [], weights: [Float4] = [], indices: [UInt32],
                morphTargets: [MorphTarget] = [], materialIndex: Int? = nil, regions: [UInt8] = [], extras: JSONValue? = nil) {
        self.name = name; self.positions = positions; self.normals = normals; self.tangents = tangents
        self.uvs = uvs; self.colors = colors; self.joints = joints; self.weights = weights; self.indices = indices
        self.morphTargets = morphTargets; self.materialIndex = materialIndex; self.regions = regions; self.extras = extras
        self.bounds = AABB.of(points: positions)
    }
}

public struct MaterialData: Sendable {
    public var name: String
    public var baseColorFactor: Float4
    public var baseColorImage: Int?      // index into GLTFAsset.images
    public var normalImage: Int?
    public var emissiveFactor: Float3
    public var alphaMode: String         // OPAQUE | MASK | BLEND
    public var alphaCutoff: Float
    public var doubleSided: Bool
    public var extras: JSONValue?
    public init(name: String, baseColorFactor: Float4 = Float4(1, 1, 1, 1), baseColorImage: Int? = nil, normalImage: Int? = nil,
                emissiveFactor: Float3 = .zero, alphaMode: String = "OPAQUE", alphaCutoff: Float = 0.5, doubleSided: Bool = false, extras: JSONValue? = nil) {
        self.name = name; self.baseColorFactor = baseColorFactor; self.baseColorImage = baseColorImage; self.normalImage = normalImage
        self.emissiveFactor = emissiveFactor; self.alphaMode = alphaMode; self.alphaCutoff = alphaCutoff; self.doubleSided = doubleSided; self.extras = extras
    }
}

public struct ImageData: Sendable {
    public var name: String
    public var data: Data
    public var mimeType: String?
}

public struct SkinData: Sendable {
    public var name: String
    public var jointNodes: [Int]
    public var inverseBindMatrices: [float4x4]
}

public struct NodeData: Sendable {
    public var name: String
    public var children: [Int]
    public var parent: Int?
    public var mesh: Int?
    public var skin: Int?
    public var translation: Float3
    public var rotation: simd_quatf
    public var scale: Float3
    public var extras: JSONValue?
    public var localMatrix: float4x4 { Transform.trs(translation, rotation, scale) }
}

public struct MeshGroup: Sendable {
    public var name: String
    public var primitives: [MeshData]
    public var extras: JSONValue?
}

/// A fully decoded glTF/GLB file.
public struct GLTFAsset: Sendable {
    public var url: URL?
    public var nodes: [NodeData]
    public var rootNodes: [Int]
    public var meshes: [MeshGroup]
    public var materials: [MaterialData]
    public var images: [ImageData]
    public var skins: [SkinData]
    public var extras: JSONValue?

    public func node(named name: String) -> Int? { nodes.firstIndex { $0.name == name } }

    public func worldMatrix(ofNode i: Int) -> float4x4 {
        var m = nodes[i].localMatrix
        var p = nodes[i].parent
        while let pi = p { m = nodes[pi].localMatrix * m; p = nodes[pi].parent }
        return m
    }

    /// All (node, mesh) pairs in scene order.
    public var meshNodes: [(node: Int, mesh: Int)] {
        var out: [(Int, Int)] = []
        for (i, n) in nodes.enumerated() { if let m = n.mesh { out.append((i, m)) } }
        return out
    }
}
