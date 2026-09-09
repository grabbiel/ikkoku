import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import simd
import CoreMath
import Assets
import GPU
import ShaderTypes

/// GPU-resident mesh: base vertices + optional skin/morph data + indices.
public final class GPUMesh: @unchecked Sendable {
    public let name: String
    public let vertexCount: Int
    public let indexCount: Int
    public let baseVertices: any MTLBuffer      // DeformedVertex[]
    public let texcoords: any MTLBuffer         // float2[]
    public let colors: (any MTLBuffer)?         // uchar4[]
    public let indices: any MTLBuffer           // uint32[]
    public let skin: (any MTLBuffer)?           // SkinVertex[]
    public let morphDeltas: (any MTLBuffer)?    // packed float3 [targets*verts]
    public let morphNormals: (any MTLBuffer)?
    public let morphNames: [String]
    public let bounds: AABB
    public let regions: [UInt8]
    public var needsDeform: Bool { skin != nil || morphDeltas != nil }

    init(name: String, vertexCount: Int, indexCount: Int, baseVertices: any MTLBuffer, texcoords: any MTLBuffer, colors: (any MTLBuffer)?,
         indices: any MTLBuffer, skin: (any MTLBuffer)?, morphDeltas: (any MTLBuffer)?, morphNormals: (any MTLBuffer)?, morphNames: [String], bounds: AABB, regions: [UInt8]) {
        self.name = name; self.vertexCount = vertexCount; self.indexCount = indexCount; self.baseVertices = baseVertices
        self.texcoords = texcoords; self.colors = colors; self.indices = indices; self.skin = skin; self.morphDeltas = morphDeltas
        self.morphNormals = morphNormals; self.morphNames = morphNames; self.bounds = bounds; self.regions = regions
    }
}

public enum ResourceError: Error { case bufferAllocation, imageDecode(String) }

/// Thread-safe owner of every GPU resource the renderer draws. Handles are stable for the app lifetime.
public final class ResourceStore: @unchecked Sendable {
    public let device: any MTLDevice
    private let lock = NSLock()
    private var meshes: [UInt32: GPUMesh] = [:]
    private var textures: [UInt32: any MTLTexture] = [:]
    private var textureKeys: [String: TextureHandle] = [:]
    private var nextMesh: UInt32 = 1
    private var nextTexture: UInt32 = 1
    private var deformBuffers: [UInt64: any MTLBuffer] = [:]
    let textureLoader: MTKTextureLoader

    public let whiteTexture: any MTLTexture
    public let blackTexture: any MTLTexture
    public let flatNormalTexture: any MTLTexture
    public let dummyBuffer: any MTLBuffer

    public init(device: any MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        whiteTexture = ResourceStore.makeSolid(device: device, rgba: [255, 255, 255, 255], label: "White")
        blackTexture = ResourceStore.makeSolid(device: device, rgba: [0, 0, 0, 0], label: "Black")
        flatNormalTexture = ResourceStore.makeSolid(device: device, rgba: [128, 128, 255, 255], label: "FlatNormal")
        dummyBuffer = device.makeBuffer(length: 256, options: .storageModeShared)!
        dummyBuffer.label = "Dummy"
    }

    private static func makeSolid(device: any MTLDevice, rgba: [UInt8], label: String) -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        t.label = label
        rgba.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        return t
    }

    // MARK: Meshes

    public func mesh(_ h: MeshHandle) -> GPUMesh? { lock.lock(); defer { lock.unlock() }; return meshes[h.id] }

    @discardableResult
    public func register(mesh data: MeshData, smoothOutlineNormals: Bool = true) throws -> MeshHandle {
        let n = data.vertexCount
        let outlineNormals = smoothOutlineNormals ? MeshUtil.computeSmoothNormals(positions: data.positions, indices: data.indices) : data.normals
        var verts = [DeformedVertex](repeating: DeformedVertex(), count: n)
        let hasTangents = data.tangents.count == n
        let hasColors = data.colors.count == n
        let hasRegions = data.regions.count == n
        for i in 0..<n {
            let p = data.positions[i]
            let nn = data.normals[i]
            _ = outlineNormals
            let t = hasTangents ? data.tangents[i] : Float4(1, 0, 0, 1)
            let ow: Float = hasColors ? data.colors[i].w : 1
            let region: Float = hasRegions ? Float(data.regions[i]) : 0
            verts[i] = DeformedVertex(position: Float4(p.x, p.y, p.z, region), normal: Float4(nn.x, nn.y, nn.z, ow), tangent: t)
        }
        guard let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<DeformedVertex>.stride * n, options: .storageModeShared) else { throw ResourceError.bufferAllocation }
        vb.label = "\(data.name).base"
        let uvs = data.uvs.count == n ? data.uvs : [Float2](repeating: .zero, count: n)
        guard let ub = device.makeBuffer(bytes: uvs, length: MemoryLayout<Float2>.stride * n, options: .storageModeShared) else { throw ResourceError.bufferAllocation }
        ub.label = "\(data.name).uv"
        var cb: (any MTLBuffer)? = nil
        if hasColors {
            let c = data.colors.map { SIMD4<UInt8>(UInt8(clamp($0.x, 0, 1) * 255), UInt8(clamp($0.y, 0, 1) * 255), UInt8(clamp($0.z, 0, 1) * 255), UInt8(clamp($0.w, 0, 1) * 255)) }
            cb = device.makeBuffer(bytes: c, length: 4 * n, options: .storageModeShared)
            cb?.label = "\(data.name).color"
        }
        guard let ib = device.makeBuffer(bytes: data.indices, length: 4 * data.indices.count, options: .storageModeShared) else { throw ResourceError.bufferAllocation }
        ib.label = "\(data.name).idx"
        var sb: (any MTLBuffer)? = nil
        if data.isSkinned {
            let s = (0..<n).map { SkinVertex(joints: data.joints[$0], weights: data.weights[$0]) }
            sb = device.makeBuffer(bytes: s, length: MemoryLayout<SkinVertex>.stride * n, options: .storageModeShared)
            sb?.label = "\(data.name).skin"
        }
        var mb: (any MTLBuffer)? = nil
        var mnb: (any MTLBuffer)? = nil
        if !data.morphTargets.isEmpty {
            var deltas = [PackedFloat3](repeating: PackedFloat3(x: 0, y: 0, z: 0), count: n * data.morphTargets.count)
            var hasNormals = data.morphTargets.allSatisfy { $0.normalDeltas.count == n }
            var ndeltas = hasNormals ? [PackedFloat3](repeating: PackedFloat3(x: 0, y: 0, z: 0), count: n * data.morphTargets.count) : []
            for (ti, t) in data.morphTargets.enumerated() {
                if t.positionDeltas.count != n { continue }
                for i in 0..<n {
                    let d = t.positionDeltas[i]
                    deltas[ti * n + i] = PackedFloat3(x: d.x, y: d.y, z: d.z)
                    if hasNormals { let nd = t.normalDeltas[i]; ndeltas[ti * n + i] = PackedFloat3(x: nd.x, y: nd.y, z: nd.z) }
                }
            }
            mb = device.makeBuffer(bytes: deltas, length: 12 * deltas.count, options: .storageModeShared)
            mb?.label = "\(data.name).morph"
            if hasNormals {
                mnb = device.makeBuffer(bytes: ndeltas, length: 12 * ndeltas.count, options: .storageModeShared)
                mnb?.label = "\(data.name).morphN"
            } else { hasNormals = false }
        }
        let mesh = GPUMesh(name: data.name, vertexCount: n, indexCount: data.indices.count, baseVertices: vb, texcoords: ub, colors: cb,
                           indices: ib, skin: sb, morphDeltas: mb, morphNormals: mnb, morphNames: data.morphTargets.map(\.name), bounds: data.bounds, regions: data.regions)
        lock.lock(); defer { lock.unlock() }
        let h = MeshHandle(id: nextMesh); nextMesh += 1
        meshes[h.id] = mesh
        return h
    }

    public func unregister(mesh h: MeshHandle) { lock.lock(); meshes[h.id] = nil; lock.unlock() }

    func deformBuffer(for key: UInt64, vertexCount: Int) -> any MTLBuffer {
        lock.lock(); defer { lock.unlock() }
        let needed = MemoryLayout<DeformedVertex>.stride * vertexCount
        if let b = deformBuffers[key], b.length >= needed { return b }
        let b = device.makeBuffer(length: needed, options: .storageModePrivate)!
        b.label = "deform.\(key)"
        deformBuffers[key] = b
        return b
    }

    public func releaseDeformBuffers(keys: [UInt64]) { lock.lock(); for k in keys { deformBuffers[k] = nil }; lock.unlock() }

    private var hiddenBuffers: [UInt64: any MTLBuffer] = [:]

    /// Uploads (or replaces) a per-vertex hidden mask for `key`.
    public func setHiddenBuffer(key: UInt64, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let n = max(bytes.count, 1)
        if let b = hiddenBuffers[key], b.length >= n {
            bytes.withUnsafeBytes { b.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            return
        }
        guard let b = device.makeBuffer(bytes: bytes, length: n, options: .storageModeShared) else { return }
        b.label = "hidden.\(key)"
        hiddenBuffers[key] = b
    }
    func hiddenBuffer(key: UInt64) -> (any MTLBuffer)? { lock.lock(); defer { lock.unlock() }; return hiddenBuffers[key] }

    // MARK: Textures

    public func texture(_ h: TextureHandle?) -> (any MTLTexture)? {
        guard let h else { return nil }
        lock.lock(); defer { lock.unlock() }; return textures[h.id]
    }

    public func lookup(key: String) -> TextureHandle? { lock.lock(); defer { lock.unlock() }; return textureKeys[key] }

    /// Loads (or returns the cached) texture for a file. `srgb` marks colour data.
    public func texture(url: URL, srgb: Bool = true) throws -> TextureHandle {
        let key = "\(url.path)#\(srgb)"
        if let h = lookup(key: key) { return h }
        let t = try textureLoader.newTexture(URL: url, options: [.SRGB: srgb, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue])
        t.label = url.lastPathComponent
        return register(texture: t, key: key)
    }

    public func texture(data: Data, key: String, srgb: Bool = true) throws -> TextureHandle {
        let fullKey = "\(key)#\(srgb)"
        if let h = lookup(key: fullKey) { return h }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ResourceError.imageDecode(key)
        }
        return try texture(cgImage: cg, key: fullKey, srgb: srgb)
    }

    public func texture(cgImage: CGImage, key: String, srgb: Bool = true) throws -> TextureHandle {
        if let h = lookup(key: key) { return h }
        let t = try textureLoader.newTexture(cgImage: cgImage, options: [.SRGB: srgb, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue])
        t.label = key
        return register(texture: t, key: key)
    }

    /// Creates (or replaces) an 8-bit single-channel texture from raw bytes (row-major, width*height).
    public func texture(r8 bytes: [UInt8], width: Int, height: Int, key: String) -> TextureHandle? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = key
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        lock.lock()
        if let h = textureKeys[key] { textures[h.id] = t; lock.unlock(); return h }
        lock.unlock()
        return register(texture: t, key: key)
    }

    @discardableResult
    public func register(texture: any MTLTexture, key: String? = nil) -> TextureHandle {
        lock.lock(); defer { lock.unlock() }
        let h = TextureHandle(id: nextTexture); nextTexture += 1
        textures[h.id] = texture
        if let key { textureKeys[key] = h }
        return h
    }
}
