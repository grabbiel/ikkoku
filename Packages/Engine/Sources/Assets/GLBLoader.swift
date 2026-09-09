import Foundation
import simd
import CoreMath

public enum GLTFError: Error, CustomStringConvertible {
    case badMagic
    case badChunk
    case missingBuffer(Int)
    case unsupportedAccessor(String)
    case missingAttribute(String)
    case io(String)

    public var description: String {
        switch self {
        case .badMagic: return "Not a GLB file."
        case .badChunk: return "Malformed GLB chunk table."
        case .missingBuffer(let i): return "glTF buffer \(i) is missing."
        case .unsupportedAccessor(let s): return "Unsupported accessor: \(s)"
        case .missingAttribute(let s): return "Primitive lacks attribute \(s)."
        case .io(let s): return s
        }
    }
}

/// Loads `.glb` (binary) and `.gltf` (JSON + external/base64 buffers).
public enum GLBLoader {

    public static func load(url: URL) throws -> GLTFAsset {
        let data = try Data(contentsOf: url)
        return try load(data: data, baseURL: url.deletingLastPathComponent(), sourceURL: url)
    }

    public static func load(data: Data, baseURL: URL?, sourceURL: URL? = nil) throws -> GLTFAsset {
        var json: Data
        var bin: Data?
        if data.count >= 12, data.readUInt32(at: 0) == 0x46546C67 { // "glTF"
            let length = Int(data.readUInt32(at: 8))
            var offset = 12
            var jsonChunk: Data?
            while offset + 8 <= min(length, data.count) {
                let clen = Int(data.readUInt32(at: offset))
                let ctype = data.readUInt32(at: offset + 4)
                let start = offset + 8
                guard start + clen <= data.count else { throw GLTFError.badChunk }
                let chunk = data.subdata(in: start..<(start + clen))
                if ctype == 0x4E4F534A { jsonChunk = chunk }          // JSON
                else if ctype == 0x004E4942 { bin = chunk }             // BIN
                offset = start + clen
            }
            guard let j = jsonChunk else { throw GLTFError.badChunk }
            json = j
        } else {
            json = data
        }
        let root = try JSONDecoder().decode(GLTFRoot.self, from: json)
        let ctx = try Context(root: root, bin: bin, baseURL: baseURL)
        var asset = try ctx.build()
        asset.url = sourceURL
        return asset
    }

    // MARK: - Decoding context

    private final class Context {
        let root: GLTFRoot
        var buffers: [Data]

        init(root: GLTFRoot, bin: Data?, baseURL: URL?) throws {
            self.root = root
            var bufs: [Data] = []
            for (i, b) in (root.buffers ?? []).enumerated() {
                if let uri = b.uri {
                    if uri.hasPrefix("data:") {
                        guard let comma = uri.firstIndex(of: ","),
                              let d = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                            throw GLTFError.missingBuffer(i)
                        }
                        bufs.append(d)
                    } else {
                        guard let base = baseURL else { throw GLTFError.missingBuffer(i) }
                        let u = base.appendingPathComponent(uri.removingPercentEncoding ?? uri)
                        bufs.append(try Data(contentsOf: u))
                    }
                } else if i == 0, let bin {
                    bufs.append(bin)
                } else {
                    throw GLTFError.missingBuffer(i)
                }
            }
            self.buffers = bufs
        }

        func bufferViewData(_ index: Int) throws -> (data: Data, stride: Int?) {
            guard let bv = root.bufferViews?[index], bv.buffer < buffers.count else { throw GLTFError.missingBuffer(index) }
            let start = bv.byteOffset ?? 0
            let d = buffers[bv.buffer].subdata(in: start..<(start + bv.byteLength))
            return (d, bv.byteStride)
        }

        static func componentSize(_ t: Int) -> Int {
            switch t {
            case 5120, 5121: return 1
            case 5122, 5123: return 2
            case 5125, 5126: return 4
            default: return 4
            }
        }
        static func componentCount(_ type: String) -> Int {
            switch type {
            case "SCALAR": return 1
            case "VEC2": return 2
            case "VEC3": return 3
            case "VEC4": return 4
            case "MAT2": return 4
            case "MAT3": return 9
            case "MAT4": return 16
            default: return 1
            }
        }

        /// Reads an accessor as an array of Float per component (handles normalised ints and sparse).
        func readFloats(_ accessorIndex: Int) throws -> (values: [Float], components: Int) {
            guard let acc = root.accessors?[accessorIndex] else { throw GLTFError.unsupportedAccessor("index \(accessorIndex)") }
            let comps = Context.componentCount(acc.type)
            let csize = Context.componentSize(acc.componentType)
            var out = [Float](repeating: 0, count: acc.count * comps)
            if let bvi = acc.bufferView {
                let (data, strideOpt) = try bufferViewData(bvi)
                let stride = strideOpt ?? (comps * csize)
                let base = acc.byteOffset ?? 0
                data.withUnsafeBytes { raw in
                    for i in 0..<acc.count {
                        let off = base + i * stride
                        for c in 0..<comps {
                            out[i * comps + c] = Context.readComponent(raw, off + c * csize, acc.componentType, acc.normalized ?? false)
                        }
                    }
                }
            }
            if let sp = acc.sparse {
                let (idata, _) = try bufferViewData(sp.indices.bufferView)
                let (vdata, _) = try bufferViewData(sp.values.bufferView)
                let ioff = sp.indices.byteOffset ?? 0
                let voff = sp.values.byteOffset ?? 0
                let isize = Context.componentSize(sp.indices.componentType)
                idata.withUnsafeBytes { iraw in
                    vdata.withUnsafeBytes { vraw in
                        for k in 0..<sp.count {
                            let idx = Int(Context.readComponent(iraw, ioff + k * isize, sp.indices.componentType, false))
                            for c in 0..<comps {
                                out[idx * comps + c] = Context.readComponent(vraw, voff + (k * comps + c) * csize, acc.componentType, acc.normalized ?? false)
                            }
                        }
                    }
                }
            }
            return (out, comps)
        }

        func readUInts(_ accessorIndex: Int) throws -> (values: [UInt32], components: Int) {
            guard let acc = root.accessors?[accessorIndex] else { throw GLTFError.unsupportedAccessor("index \(accessorIndex)") }
            let comps = Context.componentCount(acc.type)
            let csize = Context.componentSize(acc.componentType)
            var out = [UInt32](repeating: 0, count: acc.count * comps)
            if let bvi = acc.bufferView {
                let (data, strideOpt) = try bufferViewData(bvi)
                let stride = strideOpt ?? (comps * csize)
                let base = acc.byteOffset ?? 0
                data.withUnsafeBytes { raw in
                    for i in 0..<acc.count {
                        let off = base + i * stride
                        for c in 0..<comps {
                            out[i * comps + c] = UInt32(Context.readComponent(raw, off + c * csize, acc.componentType, false))
                        }
                    }
                }
            }
            return (out, comps)
        }

        @inline(__always)
        static func readComponent(_ raw: UnsafeRawBufferPointer, _ off: Int, _ type: Int, _ normalized: Bool) -> Float {
            switch type {
            case 5126: return raw.loadUnaligned(fromByteOffset: off, as: Float.self)
            case 5123:
                let v = raw.loadUnaligned(fromByteOffset: off, as: UInt16.self)
                return normalized ? Float(v) / 65535 : Float(v)
            case 5121:
                let v = raw.loadUnaligned(fromByteOffset: off, as: UInt8.self)
                return normalized ? Float(v) / 255 : Float(v)
            case 5125:
                return Float(raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            case 5122:
                let v = raw.loadUnaligned(fromByteOffset: off, as: Int16.self)
                return normalized ? max(Float(v) / 32767, -1) : Float(v)
            case 5120:
                let v = raw.loadUnaligned(fromByteOffset: off, as: Int8.self)
                return normalized ? max(Float(v) / 127, -1) : Float(v)
            default: return 0
            }
        }

        func readFloat3(_ i: Int) throws -> [Float3] {
            let (v, c) = try readFloats(i)
            guard c >= 3 else { throw GLTFError.unsupportedAccessor("expected VEC3") }
            return (0..<(v.count / c)).map { Float3(v[$0 * c], v[$0 * c + 1], v[$0 * c + 2]) }
        }
        func readFloat2(_ i: Int) throws -> [Float2] {
            let (v, c) = try readFloats(i)
            guard c >= 2 else { throw GLTFError.unsupportedAccessor("expected VEC2") }
            return (0..<(v.count / c)).map { Float2(v[$0 * c], v[$0 * c + 1]) }
        }
        func readFloat4(_ i: Int, defaultW: Float = 1) throws -> [Float4] {
            let (v, c) = try readFloats(i)
            return (0..<(v.count / c)).map {
                c >= 4 ? Float4(v[$0 * c], v[$0 * c + 1], v[$0 * c + 2], v[$0 * c + 3])
                       : Float4(v[$0 * c], v[$0 * c + 1], c > 2 ? v[$0 * c + 2] : 0, defaultW)
            }
        }
        func readMatrices(_ i: Int) throws -> [float4x4] {
            let (v, c) = try readFloats(i)
            guard c == 16 else { throw GLTFError.unsupportedAccessor("expected MAT4") }
            return (0..<(v.count / 16)).map { k in
                let b = k * 16
                return float4x4(Float4(v[b], v[b+1], v[b+2], v[b+3]), Float4(v[b+4], v[b+5], v[b+6], v[b+7]),
                                Float4(v[b+8], v[b+9], v[b+10], v[b+11]), Float4(v[b+12], v[b+13], v[b+14], v[b+15]))
            }
        }

        func build() throws -> GLTFAsset {
            // Nodes
            var nodes: [NodeData] = []
            for n in root.nodes ?? [] {
                var t = Float3.zero, s = Float3(repeating: 1), r = simd_quatf.identity
                if let m = n.matrix, m.count == 16 {
                    let mat = float4x4(Float4(m[0], m[1], m[2], m[3]), Float4(m[4], m[5], m[6], m[7]),
                                       Float4(m[8], m[9], m[10], m[11]), Float4(m[12], m[13], m[14], m[15]))
                    t = mat.translation; s = mat.scaleFactors; r = mat.rotationQuaternion
                } else {
                    if let tt = n.translation, tt.count == 3 { t = Float3(tt[0], tt[1], tt[2]) }
                    if let ss = n.scale, ss.count == 3 { s = Float3(ss[0], ss[1], ss[2]) }
                    if let rr = n.rotation, rr.count == 4 { r = simd_quatf(ix: rr[0], iy: rr[1], iz: rr[2], r: rr[3]) }
                }
                nodes.append(NodeData(name: n.name ?? "", children: n.children ?? [], parent: nil, mesh: n.mesh, skin: n.skin,
                                      translation: t, rotation: r, scale: s, extras: n.extras))
            }
            for (i, n) in nodes.enumerated() { for c in n.children where c < nodes.count { nodes[c].parent = i } }
            let sceneIndex = root.scene ?? 0
            let roots = root.scenes?.indices.contains(sceneIndex) == true ? (root.scenes![sceneIndex].nodes ?? []) : nodes.indices.filter { nodes[$0].parent == nil }

            // Materials
            var materials: [MaterialData] = []
            for m in root.materials ?? [] {
                let pbr = m.pbrMetallicRoughness
                let bc = pbr?.baseColorFactor ?? [1, 1, 1, 1]
                let ef = m.emissiveFactor ?? [0, 0, 0]
                materials.append(MaterialData(
                    name: m.name ?? "",
                    baseColorFactor: Float4(bc[0], bc[1], bc[2], bc.count > 3 ? bc[3] : 1),
                    baseColorImage: pbr?.baseColorTexture.flatMap { root.textures?[$0.index].source },
                    normalImage: m.normalTexture.flatMap { root.textures?[$0.index].source },
                    emissiveFactor: Float3(ef[0], ef[1], ef[2]),
                    alphaMode: m.alphaMode ?? "OPAQUE", alphaCutoff: m.alphaCutoff ?? 0.5,
                    doubleSided: m.doubleSided ?? false, extras: m.extras))
            }

            // Images
            var images: [ImageData] = []
            for img in root.images ?? [] {
                if let bv = img.bufferView {
                    images.append(ImageData(name: img.name ?? "", data: try bufferViewData(bv).data, mimeType: img.mimeType))
                } else if let uri = img.uri {
                    if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","),
                       let d = Data(base64Encoded: String(uri[uri.index(after: comma)...])) {
                        images.append(ImageData(name: img.name ?? "", data: d, mimeType: img.mimeType))
                    } else {
                        images.append(ImageData(name: img.name ?? uri, data: Data(), mimeType: img.mimeType))
                    }
                } else {
                    images.append(ImageData(name: img.name ?? "", data: Data(), mimeType: nil))
                }
            }

            // Skins
            var skins: [SkinData] = []
            for s in root.skins ?? [] {
                let ibm = try s.inverseBindMatrices.map { try readMatrices($0) } ?? Array(repeating: matrix_identity_float4x4, count: s.joints.count)
                skins.append(SkinData(name: s.name ?? "", jointNodes: s.joints, inverseBindMatrices: ibm))
            }

            // Meshes
            var meshes: [MeshGroup] = []
            for m in root.meshes ?? [] {
                let targetNames = m.extras?["targetNames"]?.stringArray ?? []
                var prims: [MeshData] = []
                for (pi, p) in m.primitives.enumerated() {
                    guard (p.mode ?? 4) == 4 else { continue } // triangles only
                    guard let posAcc = p.attributes["POSITION"] else { throw GLTFError.missingAttribute("POSITION") }
                    let positions = try readFloat3(posAcc)
                    var normals = try p.attributes["NORMAL"].map { try readFloat3($0) } ?? []
                    let tangents = try p.attributes["TANGENT"].map { try readFloat4($0) } ?? []
                    let uvs = try p.attributes["TEXCOORD_0"].map { try readFloat2($0) } ?? []
                    let colors = try p.attributes["COLOR_0"].map { try readFloat4($0, defaultW: 1) } ?? []
                    var joints: [SIMD4<UInt16>] = []
                    var weights: [Float4] = []
                    if let j = p.attributes["JOINTS_0"], let w = p.attributes["WEIGHTS_0"] {
                        let (jv, jc) = try readUInts(j)
                        let wv = try readFloat4(w)
                        joints = (0..<(jv.count / jc)).map { SIMD4<UInt16>(UInt16(jv[$0*jc]), UInt16(jv[$0*jc+1]), UInt16(jv[$0*jc+2]), UInt16(jv[$0*jc+3])) }
                        weights = wv
                        // Fold a second influence set into the first four by keeping the largest weights.
                        if let j1 = p.attributes["JOINTS_1"], let w1 = p.attributes["WEIGHTS_1"] {
                            let (jv1, jc1) = try readUInts(j1)
                            let wv1 = try readFloat4(w1)
                            for v in 0..<joints.count {
                                var pairs: [(UInt16, Float)] = (0..<4).map { (joints[v][$0], weights[v][$0]) }
                                pairs += (0..<4).map { (UInt16(jv1[v*jc1+$0]), wv1[v][$0]) }
                                pairs.sort { $0.1 > $1.1 }
                                let sum = max(pairs[0].1 + pairs[1].1 + pairs[2].1 + pairs[3].1, 1e-6)
                                joints[v] = SIMD4<UInt16>(pairs[0].0, pairs[1].0, pairs[2].0, pairs[3].0)
                                weights[v] = Float4(pairs[0].1, pairs[1].1, pairs[2].1, pairs[3].1) / sum
                            }
                        }
                    }
                    var regions: [UInt8] = []
                    if let r = p.attributes["_REGION"] {
                        let (rv, rc) = try readUInts(r)
                        regions = (0..<(rv.count / rc)).map { UInt8(truncatingIfNeeded: rv[$0 * rc]) }
                    }
                    var indices: [UInt32]
                    if let ia = p.indices {
                        indices = try readUInts(ia).values
                    } else {
                        indices = Array(0..<UInt32(positions.count))
                    }
                    if normals.isEmpty { normals = MeshUtil.computeNormals(positions: positions, indices: indices) }
                    var targets: [MeshData.MorphTarget] = []
                    for (ti, t) in (p.targets ?? []).enumerated() {
                        let pd = try t["POSITION"].map { try readFloat3($0) } ?? Array(repeating: .zero, count: positions.count)
                        let nd = try t["NORMAL"].map { try readFloat3($0) } ?? []
                        let name = ti < targetNames.count ? targetNames[ti] : "target\(ti)"
                        targets.append(.init(name: name, positionDeltas: pd, normalDeltas: nd))
                    }
                    let name = m.primitives.count > 1 ? "\(m.name ?? "mesh")#\(pi)" : (m.name ?? "mesh")
                    prims.append(MeshData(name: name, positions: positions, normals: normals, tangents: tangents, uvs: uvs, colors: colors,
                                          joints: joints, weights: weights, indices: indices, morphTargets: targets,
                                          materialIndex: p.material, regions: regions, extras: p.extras))
                }
                meshes.append(MeshGroup(name: m.name ?? "", primitives: prims, extras: m.extras))
            }

            return GLTFAsset(url: nil, nodes: nodes, rootNodes: roots, meshes: meshes, materials: materials,
                             images: images, skins: skins, extras: root.extras)
        }
    }
}

public enum MeshUtil {
    public static func computeNormals(positions: [Float3], indices: [UInt32]) -> [Float3] {
        var n = [Float3](repeating: .zero, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i+1]), c = Int(indices[i+2])
            let fn = cross(positions[b] - positions[a], positions[c] - positions[a])
            n[a] += fn; n[b] += fn; n[c] += fn
            i += 3
        }
        return n.map { length_squared($0) > 0 ? normalize($0) : Float3(0, 1, 0) }
    }

    /// Area-weighted smooth normals over positions that coincide (welds split vertices), used for outlines.
    public static func computeSmoothNormals(positions: [Float3], indices: [UInt32]) -> [Float3] {
        var groups: [SIMD3<Int32>: Float3] = [:]
        let faceNormals = computeNormals(positions: positions, indices: indices)
        func key(_ p: Float3) -> SIMD3<Int32> { SIMD3<Int32>(Int32((p.x * 5000).rounded()), Int32((p.y * 5000).rounded()), Int32((p.z * 5000).rounded())) }
        for (i, p) in positions.enumerated() { groups[key(p), default: .zero] += faceNormals[i] }
        return positions.map { p in
            let g = groups[key(p)] ?? Float3(0, 1, 0)
            return length_squared(g) > 0 ? normalize(g) : Float3(0, 1, 0)
        }
    }
}

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
