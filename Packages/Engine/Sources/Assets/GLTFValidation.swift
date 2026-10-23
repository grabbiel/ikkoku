import Foundation

extension GLTFRoot {
    /// The set number of a canonical `PREFIX_n` attribute semantic such as `TEXCOORD_1`.
    static func attributeSet(_ semantic: String, prefix: String) -> Int? {
        guard semantic.hasPrefix(prefix), let number = Int(semantic.dropFirst(prefix.count)), number >= 0,
              "\(prefix)\(number)" == semantic else { return nil }
        return number
    }

    /// Morph target count shared by every primitive of a mesh (checked below).
    static func targetCount(_ mesh: Mesh) -> Int { mesh.primitives.first?.targets?.count ?? 0 }

    /// Validate the graph and array references before the loader touches source data.
    func validateReferences() throws {
        func require(_ condition: Bool, _ context: String) throws {
            if !condition { throw GLTFError.io("Invalid glTF: \(context).") }
        }
        func index<T>(_ value: Int, _ array: [T]?, _ context: String) throws {
            try require(array?.indices.contains(value) == true, context)
        }
        func vector(_ values: [Float]?, _ count: Int, _ context: String) throws {
            if let values { try require(values.count == count && values.allSatisfy(\.isFinite), context) }
        }
        try require(asset.version == "2.0", "only glTF 2.0 is supported")
        // A required extension changes the meaning of core data (for example compressed
        // geometry without accessor views), so it fails before any other interpretation.
        var unsupported: [String] = []
        for name in extensionsRequired ?? [] where !GLBLoader.supportedExtensions.contains(name) && !unsupported.contains(name) {
            unsupported.append(name)
        }
        if !unsupported.isEmpty { throw GLTFError.unsupportedExtensions(unsupported) }
        if let scene { try index(scene, scenes, "scene index") }
        for scene in scenes ?? [] {
            for node in scene.nodes ?? [] { try index(node, nodes, "scene root") }
        }
        let ns = nodes ?? []
        var parents = [Int?](repeating: nil, count: ns.count)
        for (i, node) in ns.enumerated() {
            if let mesh = node.mesh { try index(mesh, meshes, "node mesh") }
            if let skin = node.skin { try index(skin, skins, "node skin") }
            try vector(node.translation, 3, "translation")
            try vector(node.scale, 3, "scale")
            try vector(node.rotation, 4, "rotation")
            try vector(node.matrix, 16, "matrix")
            try require(node.matrix == nil || (node.translation == nil && node.rotation == nil && node.scale == nil), "matrix and TRS are mutually exclusive")
            if let q = node.rotation { try require(q.reduce(0) { $0 + $1 * $1 } > 0, "zero quaternion") }
            if let weights = node.weights {
                guard let mesh = node.mesh else { throw GLTFError.io("Invalid glTF: node morph weights require a mesh.") }
                try require(weights.count == Self.targetCount(meshes![mesh]) && weights.allSatisfy(\.isFinite), "node morph weight count")
            }
            for child in node.children ?? [] {
                try index(child, nodes, "child index")
                try require(parents[child] == nil, "node has multiple parents")
                parents[child] = i
            }
        }
        // Iterative traversal also catches cycles in nodes outside the active scene.
        var stack = ns.indices.filter { parents[$0] == nil }
        var visited = Set<Int>()
        while let i = stack.popLast() {
            try require(visited.insert(i).inserted, "cyclic hierarchy")
            stack.append(contentsOf: ns[i].children ?? [])
        }
        try require(visited.count == ns.count, "cyclic hierarchy")
        for scene in scenes ?? [] {
            let roots = scene.nodes ?? []
            try require(Set(roots).count == roots.count, "duplicate scene root")
            for root in roots { try require(parents[root] == nil, "scene root has a parent") }
        }
        for buffer in buffers ?? [] { try require(buffer.byteLength >= 0, "buffer length") }
        for view in bufferViews ?? [] {
            try index(view.buffer, buffers, "buffer view")
            try require((view.byteOffset ?? 0) >= 0 && view.byteLength >= 0, "buffer view range")
            if let stride = view.byteStride {
                try require((4...252).contains(stride) && stride.isMultiple(of: 4), "buffer view stride")
            }
        }
        for accessor in accessors ?? [] {
            if let view = accessor.bufferView { try index(view, bufferViews, "accessor view") }
            try require(accessor.count >= 0 && accessor.count <= 16_777_216 && (accessor.byteOffset ?? 0) >= 0, "accessor size")
            try require([5120, 5121, 5122, 5123, 5125, 5126].contains(accessor.componentType), "component type")
            try require(["SCALAR", "VEC2", "VEC3", "VEC4", "MAT4"].contains(accessor.type), "accessor shape")
            if let sparse = accessor.sparse {
                try require(sparse.count >= 0 && sparse.count <= accessor.count, "sparse count")
                try index(sparse.indices.bufferView, bufferViews, "sparse indices view")
                try index(sparse.values.bufferView, bufferViews, "sparse values view")
                try require([5121, 5123, 5125].contains(sparse.indices.componentType), "sparse index type")
            }
        }
        for texture in textures ?? [] {
            if let source = texture.source { try index(source, images, "texture source") }
            if let sampler = texture.sampler { try index(sampler, samplers, "texture sampler") }
        }
        for sampler in samplers ?? [] {
            if let filter = sampler.magFilter { try require([9728, 9729].contains(filter), "sampler magFilter") }
            if let filter = sampler.minFilter { try require([9728, 9729, 9984, 9985, 9986, 9987].contains(filter), "sampler minFilter") }
            for wrap in [sampler.wrapS, sampler.wrapT].compactMap({ $0 }) {
                try require([33071, 33648, 10497].contains(wrap), "sampler wrap mode")
            }
        }
        for image in images ?? [] {
            try require((image.uri == nil) != (image.bufferView == nil), "image requires exactly one source")
            if let view = image.bufferView { try index(view, bufferViews, "image view") }
        }
        for material in materials ?? [] {
            try vector(material.pbrMetallicRoughness?.baseColorFactor, 4, "base color")
            try vector(material.emissiveFactor, 3, "emissive color")
            try require(["OPAQUE", "MASK", "BLEND"].contains(material.alphaMode ?? "OPAQUE"), "alpha mode")
            if let cutoff = material.alphaCutoff { try require(cutoff.isFinite && cutoff >= 0, "alpha cutoff") }
            // Base color and normal bindings may select any decoded set; the native material
            // consumer decides whether it can sample that set. Other slots are only reported.
            for info in [material.pbrMetallicRoughness?.baseColorTexture, material.normalTexture].compactMap({ $0 }) {
                try index(info.index, textures, "material texture")
                try require((0...2).contains(info.texCoord ?? 0), "texture coordinate set outside TEXCOORD_0...TEXCOORD_2")
            }
            for info in [material.pbrMetallicRoughness?.metallicRoughnessTexture, material.occlusionTexture,
                         material.emissiveTexture].compactMap({ $0 }) {
                try index(info.index, textures, "material texture")
                try require((info.texCoord ?? 0) >= 0, "texture coordinate set")
            }
        }
        for skin in skins ?? [] {
            try require(Set(skin.joints).count == skin.joints.count && !skin.joints.isEmpty, "skin joint list")
            for joint in skin.joints { try index(joint, nodes, "skin joint") }
            if let skeleton = skin.skeleton { try index(skeleton, nodes, "skin skeleton") }
            if let bind = skin.inverseBindMatrices {
                try index(bind, accessors, "inverse bind accessor")
                try require(accessors![bind].type == "MAT4" && accessors![bind].componentType == 5126
                    && accessors![bind].count == skin.joints.count, "inverse bind format/count")
            }
        }
        for mesh in meshes ?? [] {
            let targets = Self.targetCount(mesh)
            try require(mesh.primitives.allSatisfy { ($0.targets?.count ?? 0) == targets }, "primitives must share morph targets")
            if let weights = mesh.weights {
                try require(weights.count == targets && weights.allSatisfy(\.isFinite), "mesh morph weight count")
            }
            for primitive in mesh.primitives {
                try require((primitive.mode ?? 4) == 4, "only triangle lists are supported")
                if let material = primitive.material {
                    try index(material, materials, "primitive material")
                    let selected = [materials![material].pbrMetallicRoughness?.baseColorTexture, materials![material].normalTexture]
                    for info in selected.compactMap({ $0 }) where (info.texCoord ?? 0) != 0 {
                        try require(primitive.attributes["TEXCOORD_\(info.texCoord ?? 0)"] != nil, "material texture coordinate set is absent from the primitive")
                    }
                }
                guard let position = primitive.attributes["POSITION"] else { throw GLTFError.missingAttribute("POSITION") }
                try index(position, accessors, "position accessor")
                let count = accessors![position].count
                for (semantic, value) in primitive.attributes {
                    try index(value, accessors, "\(semantic) accessor")
                    let accessor = accessors![value]
                    try require(accessor.count == count, "\(semantic) vertex count")
                    let shape: String?
                    switch semantic {
                    case "POSITION", "NORMAL": shape = "VEC3"
                    case "TANGENT": shape = "VEC4"
                    case "TEXCOORD_0", "TEXCOORD_1", "TEXCOORD_2": shape = "VEC2"
                    case "_REGION": shape = "SCALAR"
                    default:
                        let influence = Self.attributeSet(semantic, prefix: "JOINTS_") ?? Self.attributeSet(semantic, prefix: "WEIGHTS_")
                        shape = influence == nil ? nil : "VEC4"
                    }
                    if let shape { try require(accessor.type == shape, "\(semantic) shape") }
                    if ["TEXCOORD_0", "TEXCOORD_1", "TEXCOORD_2"].contains(semantic) {
                        // glTF 2.0 texture coordinates are float or normalized unsigned byte/short.
                        try require(accessor.componentType == 5126
                            || ([5121, 5123].contains(accessor.componentType) && accessor.normalized == true), "\(semantic) component type")
                    }
                    if semantic == "COLOR_0" { try require(["VEC3", "VEC4"].contains(accessor.type), "color shape") }
                    if semantic.hasPrefix("JOINTS_") {
                        try require([5121, 5123].contains(accessor.componentType) && !(accessor.normalized ?? false), "joint type")
                    }
                }
                let jointSets = Set(primitive.attributes.keys.compactMap { Self.attributeSet($0, prefix: "JOINTS_") })
                let weightSets = Set(primitive.attributes.keys.compactMap { Self.attributeSet($0, prefix: "WEIGHTS_") })
                try require(jointSets == weightSets, "joint/weight pairing")
                try require(jointSets == Set(0..<jointSets.count), "joint sets must start at zero")
                if let indices = primitive.indices {
                    try index(indices, accessors, "triangle index accessor")
                    let accessor = accessors![indices]
                    try require(accessor.type == "SCALAR" && [5121, 5123, 5125].contains(accessor.componentType)
                        && !(accessor.normalized ?? false), "index format")
                }
                for target in primitive.targets ?? [] {
                    for value in target.values {
                        try index(value, accessors, "morph accessor")
                        try require(accessors![value].type == "VEC3" && accessors![value].count == count, "morph shape/count")
                    }
                }
            }
        }
    }
}
