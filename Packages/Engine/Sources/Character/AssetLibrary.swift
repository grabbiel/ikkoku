import Foundation
import CoreGraphics
import ImageIO
import simd
import CoreMath
import Assets
import Scene
import Renderer

/// A glTF file registered on the GPU: meshes, skeleton and textures ready to draw.
public final class LoadedAsset: @unchecked Sendable {
    public struct Part: Sendable {
        public let mesh: MeshHandle
        public let meshName: String
        public let materialName: String
        public let material: MaterialData
        public let morphNames: [String]
        public let nodeIndex: Int
        public let worldMatrix: float4x4
        public let skinned: Bool
        public let extras: JSONValue?
        public let meshExtras: JSONValue?
        public let bounds: AABB
        public let regions: [UInt8]
        public func morphIndex(_ name: String) -> Int? { morphNames.firstIndex(of: name) }
    }

    public let url: URL
    public let asset: GLTFAsset
    public let skeleton: Skeleton?
    public let parts: [Part]
    private let resources: ResourceStore
    private var imageHandles: [String: TextureHandle] = [:]
    private let lock = NSLock()

    init(url: URL, asset: GLTFAsset, resources: ResourceStore, targetSkeleton: Skeleton? = nil, namePrefix: String? = nil) throws {
        self.url = url
        self.asset = asset
        self.resources = resources
        self.skeleton = Skeleton.from(asset: asset)
        // Joint remap: garments/hair are skinned to the body skeleton; extra bones (hair chains) follow their nearest body ancestor.
        var remap: [UInt16]? = nil
        if let target = targetSkeleton, let skin = asset.skins.first {
            let names = skin.jointNodes.map { asset.nodes[$0].name }
            if names != target.bones.map(\.name) {
                remap = skin.jointNodes.map { ni -> UInt16 in
                    var n: Int? = ni
                    while let cur = n {
                        let name = asset.nodes[cur].name
                        if let ti = target[name] { return UInt16(ti) }
                        if let pfx = namePrefix, let ti = target["\(pfx)/\(name)"] { return UInt16(ti) }
                        n = asset.nodes[cur].parent
                    }
                    return 0
                }
            }
        }
        var parts: [Part] = []
        for (ni, mi) in asset.meshNodes {
            let group = asset.meshes[mi]
            let world = asset.worldMatrix(ofNode: ni)
            for var prim in group.primitives {
                // Mouth parts sit inside the head: pin them to the head bone so head scale/rotation carries them.
                if prim.isSkinned, ["teeth", "tongue"].contains(group.name.lowercased()),
                   let skin = asset.skins.first, let hi = skin.jointNodes.firstIndex(where: { asset.nodes[$0].name == "head" }) {
                    let h = UInt16(hi)
                    prim.joints = prim.joints.map { _ in SIMD4<UInt16>(h, h, h, h) }
                    prim.weights = prim.weights.map { _ in Float4(1, 0, 0, 0) }
                }
                if let remap, prim.isSkinned {
                    prim.joints = prim.joints.map { j in
                        SIMD4<UInt16>(remap[min(Int(j.x), remap.count - 1)], remap[min(Int(j.y), remap.count - 1)], remap[min(Int(j.z), remap.count - 1)], remap[min(Int(j.w), remap.count - 1)])
                    }
                }
                let h = try resources.register(mesh: prim)
                let mat = prim.materialIndex.flatMap { $0 < asset.materials.count ? asset.materials[$0] : nil } ?? MaterialData(name: "")
                parts.append(Part(mesh: h, meshName: group.name, materialName: mat.name, material: mat, morphNames: prim.morphTargets.map(\.name),
                                  nodeIndex: ni, worldMatrix: world, skinned: prim.isSkinned && asset.nodes[ni].skin != nil,
                                  extras: prim.extras, meshExtras: group.extras, bounds: prim.bounds, regions: prim.regions))
            }
        }
        self.parts = parts
    }

    public var bounds: AABB {
        var b = AABB.empty
        for p in parts { b.expand(p.skinned ? p.bounds : p.bounds.transformed(by: p.worldMatrix)) }
        return b
    }

    /// Texture for an embedded glTF image, cached per (image, colour space).
    public func imageTexture(_ index: Int, srgb: Bool = true) -> TextureHandle? {
        guard index < asset.images.count else { return nil }
        let key = "\(url.path)#img\(index)#\(srgb)"
        lock.lock(); defer { lock.unlock() }
        if let h = imageHandles[key] { return h }
        let img = asset.images[index]
        guard !img.data.isEmpty, let h = try? resources.texture(data: img.data, key: key, srgb: srgb) else { return nil }
        imageHandles[key] = h
        return h
    }
}

/// Loads catalog + assets on demand and caches them. Safe to call from the main thread only.
public final class AssetLibrary: @unchecked Sendable {
    public let resources: ResourceStore
    public let root: URL
    public private(set) var catalog: Catalog
    private var assets: [String: LoadedAsset] = [:]
    private var failed: Set<String> = []
    private var textures: [String: TextureHandle] = [:]
    public private(set) var log: [String] = []

    public init(resources: ResourceStore, root: URL) {
        self.resources = resources
        self.root = root
        let catURL = root.appendingPathComponent("catalog.json")
        if let c = try? Catalog.load(url: catURL) { catalog = c } else { catalog = Catalog(); log.append("No catalog at \(catURL.path)") }
    }

    public func reloadCatalog() {
        if let c = try? Catalog.load(url: root.appendingPathComponent("catalog.json")) { catalog = c }
    }

    public func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    public func fileExists(_ relativePath: String) -> Bool { FileManager.default.fileExists(atPath: url(relativePath).path) }

    /// Loads a GLB/glTF relative to the assets root (or an absolute path). Pass the body skeleton for
    /// garments/hair so their joint indices are remapped onto it (cached per skeletonKey).
    public func asset(_ relativePath: String, skeleton: Skeleton? = nil, skeletonKey: String? = nil, namePrefix: String? = nil) -> LoadedAsset? {
        let key = skeleton == nil ? relativePath : "\(relativePath)@\(skeletonKey ?? "skel")"
        if let a = assets[key] { return a }
        if failed.contains(key) { return nil }
        let u = relativePath.hasPrefix("/") ? URL(fileURLWithPath: relativePath) : url(relativePath)
        do {
            let gltf = try GLBLoader.load(url: u)
            let loaded = try LoadedAsset(url: u, asset: gltf, resources: resources, targetSkeleton: skeleton, namePrefix: namePrefix)
            assets[key] = loaded
            log.append("Loaded \(relativePath): \(loaded.parts.count) parts, \(loaded.skeleton?.count ?? 0) bones")
            return loaded
        } catch {
            failed.insert(key)
            log.append("Failed \(relativePath): \(error)")
            return nil
        }
    }

    /// Texture by catalog/relative name. Bare names resolve under `Textures/`.
    public func texture(_ name: String, srgb: Bool = true) -> TextureHandle? {
        let rel = name.contains("/") ? name : "Textures/\(name)"
        let key = "\(rel)#\(srgb)"
        if let h = textures[key] { return h }
        let u = url(rel)
        guard FileManager.default.fileExists(atPath: u.path), let h = try? resources.texture(url: u, srgb: srgb) else { return nil }
        textures[key] = h
        return h
    }

    /// Sidecar texture next to an asset file: `<name>_cm.png` etc.
    public func sidecarTexture(for asset: LoadedAsset, suffix: String, srgb: Bool) -> TextureHandle? {
        let base = asset.url.deletingPathExtension().lastPathComponent
        let u = asset.url.deletingLastPathComponent().appendingPathComponent("\(base)\(suffix)")
        let key = "\(u.path)#\(srgb)"
        if let h = textures[key] { return h }
        guard FileManager.default.fileExists(atPath: u.path), let h = try? resources.texture(url: u, srgb: srgb) else { return nil }
        textures[key] = h
        return h
    }

    public func textureList(_ keyPath: KeyPath<Catalog.Textures, [String]?>) -> [String] { catalog.textures[keyPath: keyPath] ?? [] }

    // MARK: Body masks (garment coverage in body UV space)

    public static let bodyMaskSize = 1024
    private var maskBytes: [String: [UInt8]] = [:]

    /// Grayscale mask bytes (bodyMaskSize²) for a relative PNG path, cached.
    public func maskBytes(_ relativePath: String) -> [UInt8]? {
        if let b = maskBytes[relativePath] { return b }
        let u = url(relativePath)
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let n = AssetLibrary.bodyMaskSize
        var bytes = [UInt8](repeating: 0, count: n * n)
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray() as CGColorSpace?,
              let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        maskBytes[relativePath] = bytes
        return bytes
    }

    /// Union of several masks as one GPU texture (cached by the sorted path list).
    public func composedBodyMask(_ paths: [String]) -> TextureHandle? {
        let list = paths.sorted()
        guard !list.isEmpty else { return nil }
        let key = "bodymask:" + list.joined(separator: "|")
        if let h = resources.lookup(key: key) { return h }
        let n = AssetLibrary.bodyMaskSize
        var acc = [UInt8](repeating: 0, count: n * n)
        var any = false
        for p in list {
            guard let b = maskBytes(p) else { continue }
            any = true
            for i in 0..<(n * n) where b[i] > acc[i] { acc[i] = b[i] }
        }
        guard any else { return nil }
        return resources.texture(r8: acc, width: n, height: n, key: key)
    }
}
