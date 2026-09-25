import Foundation

extension GLTFRoot {
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
        for texture in textures ?? [] { if let source = texture.source { try index(source, images, "texture source") } }
        for image in images ?? [] {
            try require((image.uri == nil) != (image.bufferView == nil), "image requires exactly one source")
            if let view = image.bufferView { try index(view, bufferViews, "image view") }
        }
        for material in materials ?? [] {
            try vector(material.pbrMetallicRoughness?.baseColorFactor, 4, "base color")
            try vector(material.emissiveFactor, 3, "emissive color")
            try require(["OPAQUE", "MASK", "BLEND"].contains(material.alphaMode ?? "OPAQUE"), "alpha mode")
            if let cutoff = material.alphaCutoff { try require(cutoff.isFinite && cutoff >= 0, "alpha cutoff") }
            for info in [material.pbrMetallicRoughness?.baseColorTexture, material.normalTexture].compactMap({ $0 }) {
                try index(info.index, textures, "material texture")
                try require((info.texCoord ?? 0) == 0, "only TEXCOORD_0 is supported")
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
            for primitive in mesh.primitives {
                try require((primitive.mode ?? 4) == 4, "only triangle lists are supported")
                if let material = primitive.material { try index(material, materials, "primitive material") }
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
                    case "TANGENT", "JOINTS_0", "JOINTS_1", "WEIGHTS_0", "WEIGHTS_1": shape = "VEC4"
                    case "TEXCOORD_0": shape = "VEC2"
                    case "_REGION": shape = "SCALAR"
                    default: shape = nil
                    }
                    if let shape { try require(accessor.type == shape, "\(semantic) shape") }
                    if semantic == "COLOR_0" { try require(["VEC3", "VEC4"].contains(accessor.type), "color shape") }
                    if semantic.hasPrefix("JOINTS_") {
                        try require([5121, 5123].contains(accessor.componentType) && !(accessor.normalized ?? false), "joint type")
                    }
                }
                for set in ["0", "1"] {
                    try require((primitive.attributes["JOINTS_\(set)"] == nil) == (primitive.attributes["WEIGHTS_\(set)"] == nil), "joint/weight pairing")
                }
                try require(primitive.attributes["JOINTS_1"] == nil || primitive.attributes["JOINTS_0"] != nil, "joint sets must start at zero")
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
