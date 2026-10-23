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
    public var uvs1: [Float2]              // optional source UV1; empty uses UV0 on the GPU
    public var uvs2: [Float2]              // optional source UV2; empty uses UV0 on the GPU
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
                uvs1: [Float2] = [], uvs2: [Float2] = [],
                colors: [Float4] = [], joints: [SIMD4<UInt16>] = [], weights: [Float4] = [], indices: [UInt32],
                morphTargets: [MorphTarget] = [], materialIndex: Int? = nil, regions: [UInt8] = [], extras: JSONValue? = nil) {
        self.name = name; self.positions = positions; self.normals = normals; self.tangents = tangents
        self.uvs = uvs; self.uvs1 = uvs1; self.uvs2 = uvs2
        self.colors = colors; self.joints = joints; self.weights = weights; self.indices = indices
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
    /// Authored glTF `texCoord` selection (0...2) of each texture binding. The loader keeps
    /// it; native toon materials sample UV0 only, so `LoadedAsset` rejects nonzero sets.
    public var baseColorTexCoord: Int
    public var normalTexCoord: Int
    public init(name: String, baseColorFactor: Float4 = Float4(1, 1, 1, 1), baseColorImage: Int? = nil, normalImage: Int? = nil,
                emissiveFactor: Float3 = .zero, alphaMode: String = "OPAQUE", alphaCutoff: Float = 0.5, doubleSided: Bool = false, extras: JSONValue? = nil,
                baseColorTexCoord: Int = 0, normalTexCoord: Int = 0) {
        self.name = name; self.baseColorFactor = baseColorFactor; self.baseColorImage = baseColorImage; self.normalImage = normalImage
        self.emissiveFactor = emissiveFactor; self.alphaMode = alphaMode; self.alphaCutoff = alphaCutoff; self.doubleSided = doubleSided; self.extras = extras
        self.baseColorTexCoord = baseColorTexCoord; self.normalTexCoord = normalTexCoord
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
    /// Preserve authored matrices, including reflections and shear, for static prefabs.
    public var authoredMatrix: float4x4? = nil
    /// Authored node `weights` (initial morph weights overriding the mesh's), nil when absent.
    public var weights: [Float]? = nil
    public var localMatrix: float4x4 { authoredMatrix ?? Transform.trs(translation, rotation, scale) }
}

public struct MeshGroup: Sendable {
    public var name: String
    public var primitives: [MeshData]
    public var extras: JSONValue?
    /// Authored mesh `weights` (initial morph weights, one per target), nil when absent.
    public var weights: [Float]? = nil
}

/// A loader report about authored glTF data that the native pipeline reduces, ignores or
/// does not apply. The asset still loads; data whose omission would change its meaning
/// (for example an unsupported `extensionsRequired` entry) is rejected instead.
///
/// Codes: `unsupported_extension`, `skin_influences_reduced`, `ignored_attribute`,
/// `ignored_morph_attribute`, `unsupported_texture_slot`, `unsupported_sampler` and
/// `initial_morph_weights_not_applied`.
public struct GLTFDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var description: String { "\(code): \(message)" }
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
    /// Compatibility reports produced while loading; see `GLTFDiagnostic`.
    public var diagnostics: [GLTFDiagnostic] = []

    public func node(named name: String) -> Int? { nodes.firstIndex { $0.name == name } }

    public func worldMatrix(ofNode i: Int) -> float4x4 {
        var m = nodes[i].localMatrix
        var p = nodes[i].parent
        while let pi = p { m = nodes[pi].localMatrix * m; p = nodes[pi].parent }
        return m
    }

    /// glTF initial morph weights for a mesh node: node `weights`, else mesh `weights`, else
    /// zero for every target. Empty when the node has no mesh. Native render paths do not
    /// apply these yet; the loader reports nonzero values (`initial_morph_weights_not_applied`).
    public func initialMorphWeights(ofNode i: Int) -> [Float] {
        guard nodes.indices.contains(i), let mesh = nodes[i].mesh, meshes.indices.contains(mesh) else { return [] }
        if let weights = nodes[i].weights ?? meshes[mesh].weights { return weights }
        return Array(repeating: 0, count: meshes[mesh].primitives.first?.morphTargets.count ?? 0)
    }

    /// All (node, mesh) pairs in scene order.
    public var meshNodes: [(node: Int, mesh: Int)] {
        var out: [(Int, Int)] = []
        var stack = Array(rootNodes.reversed())
        var visited = Set<Int>()
        while let i = stack.popLast() {
            guard nodes.indices.contains(i), visited.insert(i).inserted else { continue }
            let n = nodes[i]
            if let m = n.mesh { out.append((i, m)) }
            stack.append(contentsOf: n.children.reversed())
        }
        return out
    }
}
