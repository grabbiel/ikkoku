import Foundation
import simd
import CoreMath
import Assets

/// Strict local interchange boundary for raw Unity rig data exported by rig_inventory.py.
/// Geometry is converted once; source metadata remains local and is never treated as code.
public struct SourceRig: Sendable {
    public struct Part: Sendable {
        public let mesh: MeshData
        public let node: Int
        public let skin: Int
        public let rendererEnabled: Bool
        public let hasCloth: Bool
        public init(mesh: MeshData, node: Int, skin: Int, rendererEnabled: Bool, hasCloth: Bool = false) {
            self.mesh = mesh; self.node = node; self.skin = skin; self.rendererEnabled = rendererEnabled; self.hasCloth = hasCloth
        }
    }
    public let sourcePrefab: String
    public let rig: RigDefinition
    public let parts: [Part]
    /// Includes metadata-only channels from legacy exports; drawable targets require full frame data.
    public let morphChannelCount: Int

    public static func load(url: URL) throws -> SourceRig { try decode(Data(contentsOf: url)) }
    public func namespacingMeshes(_ prefix: String) -> Self {
        Self(sourcePrefab: sourcePrefab, rig: rig, parts: parts.map { part in
            var mesh = part.mesh; mesh.name = prefix + mesh.name
            return Part(mesh: mesh, node: part.node, skin: part.skin, rendererEnabled: part.rendererEnabled, hasCloth: part.hasCloth)
        }, morphChannelCount: morphChannelCount)
    }
    public static func decode(_ data: Data) throws -> SourceRig {
        let raw = try JSONDecoder().decode(Document.self, from: data)
        guard raw.schemaVersion == 1, raw.coordinateSpace == "unity-left-handed-y-up",
              raw.matrixLayout == "column-major", raw.uvConvention == "unity-source" else {
            throw RigError.invalid("Unsupported source rig schema or coordinate convention.")
        }
        let nodes = try raw.nodes.map { node -> RigDefinition.Node in
            let t = try vector3(node.translation), s = try vector3(node.scale), q = try vector4(node.rotation)
            guard abs(simd_length(q) - 1) < 1e-3 else { throw RigError.invalid("Nonunit rotation for '\(node.name)'.") }
            return RigDefinition.Node(name: node.name, sourceID: node.sourceID, parent: node.parent,
                translation: UnityCoordinates.position(t), rotation: UnityCoordinates.rotation(simd_quatf(vector: q)),
                scale: s, active: node.active ?? true)
        }
        let skins = try raw.skins.map { skin in
            try RigDefinition.Skin(name: skin.name, meshNode: skin.meshNode, joints: skin.joints,
                inverseBindMatrices: skin.inverseBindMatrices.map { UnityCoordinates.matrix(try matrix($0)) }, rootJoint: skin.rootJoint)
        }
        let rig = try RigDefinition(nodes: nodes, skins: skins)
        var parts: [Part] = []
        for source in raw.meshes {
            guard rig.nodes.indices.contains(source.node), rig.skins.indices.contains(source.skin),
                  rig.skins[source.skin].meshNode == source.node else { throw RigError.invalid("Mesh '\(source.name)' has an invalid skin binding.") }
            let count = source.positions.count
            guard count > 0, source.normals.count == count, source.joints.count == count, source.weights.count == count,
                  source.tangents.isEmpty || source.tangents.count == count,
                  source.uv0.isEmpty || source.uv0.count == count else { throw RigError.invalid("Mesh '\(source.name)' has inconsistent vertex attributes.") }
            guard (source.initialMorphWeights ?? []).allSatisfy({ $0.isFinite && $0 == 0 }) else {
                throw RigError.invalid("Nonzero initial source morph weights are not yet supported.")
            }
            let positions = try source.positions.map { UnityCoordinates.position(try vector3($0)) }
            let normals = try source.normals.map { UnityCoordinates.normal(try vector3($0)) }
            // Z reflection and V inversion each flip tangent handedness; together they retain W.
            let tangents = try source.tangents.map { row -> Float4 in let v = try vector4(row); return Float4(v.x, v.y, -v.z, v.w) }
            func uvSet(_ rows: [[Float]]) throws -> [Float2] {
                guard rows.isEmpty || rows.count == count else { throw RigError.invalid("Source UV count differs from the vertex count.") }
                return try rows.map { row in
                    guard row.count == 2, row.allSatisfy(\.isFinite) else { throw RigError.invalid("Invalid source UV.") }
                    return Float2(row[0], 1 - row[1])
                }
            }
            let uvs = try uvSet(source.uv0)
            let uvs1 = try uvSet(source.uv1 ?? []), uvs2 = try uvSet(source.uv2 ?? [])
            let morphTargets = try sourceMorphTargets(source.morphChannels, vertexCount: count)
            let paletteCount = rig.skins[source.skin].joints.count
            let joints = try source.joints.map { row -> SIMD4<UInt16> in
                guard row.count == 4, row.allSatisfy({ $0 >= 0 && $0 < paletteCount && $0 <= Int(UInt16.max) }) else { throw RigError.invalid("Invalid skin joint in '\(source.name)'.") }
                return SIMD4(UInt16(row[0]), UInt16(row[1]), UInt16(row[2]), UInt16(row[3]))
            }
            let weights = try source.weights.map { row -> Float4 in
                let weights = try vector4(row), sum = weights.x + weights.y + weights.z + weights.w
                guard row.allSatisfy({ $0 >= 0 }), abs(sum - 1) <= 1e-3 else { throw RigError.invalid("Invalid or unnormalized skin weights in '\(source.name)'.") }
                return weights / sum
            }
            for (index, submesh) in source.submeshes.enumerated() {
                guard !submesh.indices.isEmpty, submesh.indices.allSatisfy({ $0 >= 0 && $0 < count && $0 <= Int(UInt32.max) }) else { throw RigError.invalid("Invalid triangle index in '\(source.name)'.") }
                let indices = try UnityCoordinates.triangleIndices(submesh.indices.map(UInt32.init))
                let mesh = MeshData(name: "\(source.name)/\(index)", positions: positions, normals: normals,
                    tangents: tangents, uvs: uvs, uvs1: uvs1, uvs2: uvs2,
                    joints: joints, weights: weights, indices: indices, morphTargets: morphTargets)
                parts.append(Part(mesh: mesh, node: source.node, skin: source.skin, rendererEnabled: source.rendererEnabled ?? true, hasCloth: source.hasCloth ?? false))
            }
        }
        return SourceRig(sourcePrefab: raw.sourcePrefab, rig: rig, parts: parts,
                         morphChannelCount: raw.meshes.reduce(0) { $0 + $1.morphChannels.count })
    }

    /// CPU reference for verification and camera/shadow bounds; Metal uses the same palette convention.
    public func deformedPositions(part: Part, evaluation: RigEvaluation, morphWeights: [(index: Int, weight: Float)] = []) throws -> [Float3] {
        guard evaluation.palettes.indices.contains(part.skin), evaluation.worldMatrices.indices.contains(part.node) else {
            throw RigError.invalid("Rig evaluation does not contain this mesh binding.")
        }
        try Self.validateMorphWeights(morphWeights, mesh: part.mesh)
        let matrices = evaluation.palettes[part.skin], model = evaluation.worldMatrices[part.node]
        return try part.mesh.positions.indices.map { index in
            let joint = part.mesh.joints[index], weight = part.mesh.weights[index]
            var p = part.mesh.positions[index]
            for morph in morphWeights { p += part.mesh.morphTargets[morph.index].positionDeltas[index] * morph.weight }
            var transformed = Float4.zero
            for lane in 0..<4 {
                guard Int(joint[lane]) < matrices.count else { throw RigError.invalid("Pose palette is shorter than the mesh binding.") }
                transformed += (matrices[Int(joint[lane])] * Float4(p, 1)) * weight[lane]
            }
            let world = model * transformed
            guard (0..<4).allSatisfy({ world[$0].isFinite }) else { throw RigError.invalid("Skinning produced a nonfinite vertex.") }
            return Float3(world.x, world.y, world.z)
        }
    }

    /// Source expression percentages become normalized weights only after channel resolution.
    public static func validateMorphWeights(_ weights: [(index: Int, weight: Float)], mesh: MeshData) throws {
        var seen = Set<Int>()
        for entry in weights {
            guard mesh.morphTargets.indices.contains(entry.index), seen.insert(entry.index).inserted,
                  entry.weight.isFinite, (0...1).contains(entry.weight),
                  mesh.morphTargets[entry.index].positionDeltas.count == mesh.vertexCount else {
                throw RigError.invalid("Invalid source morph weight or target in '\(mesh.name)'.")
            }
        }
    }

    private static func sourceMorphTargets(_ channels: [MorphChannel], vertexCount: Int) throws -> [MeshData.MorphTarget] {
        // Old exports keep channel names only. Never silently mix playable and metadata-only channels.
        if channels.allSatisfy({ $0.frames == nil }) { return [] }
        var names = Set<String>()
        return try channels.map { channel in
            guard !channel.name.isEmpty, names.insert(channel.name).inserted,
                  let frames = channel.frames, frames.count == 1, let frame = frames.first,
                  frame.weight == 100, frame.indices.count <= vertexCount,
                  frame.positionDeltas.count == frame.indices.count,
                  frame.normalDeltas.isEmpty || frame.normalDeltas.count == frame.indices.count,
                  frame.tangentDeltas.isEmpty || frame.tangentDeltas.count == frame.indices.count else {
                throw RigError.invalid("Source morph '\(channel.name)' needs a complete, unique single frame at weight 100.")
            }
            var seen = Set<Int>()
            var positions = [Float3](repeating: .zero, count: vertexCount)
            var normals = [Float3](repeating: .zero, count: vertexCount)
            for (offset, index) in frame.indices.enumerated() {
                guard (0..<vertexCount).contains(index), seen.insert(index).inserted else { throw RigError.invalid("Invalid sparse source morph vertex.") }
                positions[index] = UnityCoordinates.position(try vector3(frame.positionDeltas[offset]))
                if !frame.normalDeltas.isEmpty { normals[index] = UnityCoordinates.normal(try vector3(frame.normalDeltas[offset])) }
                if !frame.tangentDeltas.isEmpty, try vector3(frame.tangentDeltas[offset]) != .zero {
                    throw RigError.invalid("Nonzero source morph tangent deltas are not supported.")
                }
            }
            return MeshData.MorphTarget(name: channel.name, positionDeltas: positions, normalDeltas: normals)
        }
    }

    public func bounds(evaluation: RigEvaluation, morphWeights: [String: [(index: Int, weight: Float)]] = [:]) throws -> AABB {
        guard Set(morphWeights.keys).isSubset(of: Set(parts.map { $0.mesh.name })) else { throw RigError.invalid("Morph weights reference an unknown source mesh.") }
        var result = AABB.empty
        for part in parts where part.rendererEnabled && rig.activeNodes[part.node] {
            result.expand(AABB.of(points: try deformedPositions(part: part, evaluation: evaluation, morphWeights: morphWeights[part.mesh.name] ?? [])))
        }
        return result
    }

    private static func vector3(_ row: [Float]) throws -> Float3 {
        guard row.count == 3, row.allSatisfy(\.isFinite) else { throw RigError.invalid("Expected three finite components.") }
        return Float3(row[0], row[1], row[2])
    }
    private static func vector4(_ row: [Float]) throws -> Float4 {
        guard row.count == 4, row.allSatisfy(\.isFinite) else { throw RigError.invalid("Expected four finite components.") }
        return Float4(row[0], row[1], row[2], row[3])
    }
    private static func matrix(_ row: [Float]) throws -> float4x4 {
        guard row.count == 16, row.allSatisfy(\.isFinite) else { throw RigError.invalid("Expected 16 finite matrix components.") }
        return float4x4(columns: (Float4(row[0], row[1], row[2], row[3]), Float4(row[4], row[5], row[6], row[7]),
                                 Float4(row[8], row[9], row[10], row[11]), Float4(row[12], row[13], row[14], row[15])))
    }
    private struct Document: Decodable {
        let schemaVersion: Int, coordinateSpace: String, matrixLayout: String, uvConvention: String, sourcePrefab: String
        let nodes: [Node], skins: [Skin], meshes: [Mesh]
    }
    private struct Node: Decodable {
        let name: String, sourceID: String, parent: Int?, translation: [Float], rotation: [Float], scale: [Float], active: Bool?
    }
    private struct Skin: Decodable {
        let name: String, meshNode: Int, joints: [Int], inverseBindMatrices: [[Float]], rootJoint: Int?
    }
    private struct Mesh: Decodable {
        let name: String, node: Int, skin: Int, positions: [[Float]], normals: [[Float]], tangents: [[Float]], uv0: [[Float]]
        let uv1: [[Float]]?, uv2: [[Float]]?
        let joints: [[Int]], weights: [[Float]], submeshes: [Submesh], morphChannels: [MorphChannel]
        let initialMorphWeights: [Float]?, rendererEnabled: Bool?, hasCloth: Bool?
    }
    private struct Submesh: Decodable { let indices: [Int] }
    private struct MorphChannel: Decodable { let name: String, frames: [MorphFrame]? }
    private struct MorphFrame: Decodable {
        let weight: Float, indices: [Int]
        let positionDeltas: [[Float]], normalDeltas: [[Float]], tangentDeltas: [[Float]]
    }
}
