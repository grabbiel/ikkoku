import Foundation
import simd
import CoreMath
import Assets
import Scene
import Renderer
import Character

// ST-A11 / ST-B03 / ST-T04: the original map a CharaStudio scene names, drawn
// runtime-only (the document and original export never change).
//
// CharaStudio 1.0.4.2 (`Studio.Map.LoadMap`) looks the record's map number up
// in `Info.dicMapLoadInfo` (the `Map_XX` tables of `studio/info/*.unity3d`)
// and loads that row's Unity scene; a number with no row, -1 included, runs
// `ReleaseMap`: no map. `MapCtrl.Reflect` then writes only the root named
// "Map": `localPosition = caMap.pos`, `localRotation = Quaternion.Euler(caMap.rot)`.
// Scale is never written, and the scene's other roots stay where they were
// authored. `sunLightType` picks the `SunLightInfo` entry, whose `visibleList`
// objects are activated while the other entries' are deactivated.
// `Tools/reverse/export_map_scene.py` converts a map to one glTF with that
// structure in its extras; see `docs/reference/studio/maps.md`.

/// The converted map catalog (`IKKOKU_STUDIO_MAP_CATALOG`): every `Map_XX` row
/// of the supplied info bundles by original number, with the converted glTF
/// relative to the catalog or `null`.
public struct SourceStudioMapCatalog: Sendable {
    public struct Entry: Sendable, Equatable, Decodable {
        public let no: Int32
        public let name: String
        public let bundlePath: String
        public let scene: String
        public let file: String?
        /// What the converted map does not reproduce (the converter's list).
        public let approximations: [String]?
    }

    /// What a scene's map number resolves to. Only `.converted` draws.
    public enum Resolution: Sendable, Equatable {
        /// -1: the scene has no map.
        case none
        /// A converted row: its glTF and the directory its files must stay in.
        case converted(Entry, file: URL, packageRoot: URL)
        /// A row of the original catalog without a conversion.
        case notConverted(Entry)
        /// No row in the supplied tables (a mod's map, or none): the original
        /// shows no map unless a mod adds the row; never substituted here.
        case notInCatalog(Int32)
    }

    public let directory: URL
    public let entries: [Int32: Entry]

    private struct File: Decodable {
        let version: Int
        let kind: String
        let maps: [Entry]
    }

    public static let kind = "ikkoku.sourceStudioMapCatalog"

    public init(entries: [Entry], directory: URL) throws {
        var byNumber: [Int32: Entry] = [:]
        for entry in entries {
            guard byNumber[entry.no] == nil else { throw RigError.invalid("Map catalog lists map \(entry.no) twice.") }
            if let file = entry.file {
                let parts = file.split(separator: "/", omittingEmptySubsequences: false)
                guard !file.isEmpty, !file.hasPrefix("/"), !file.contains("\\"),
                      !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw RigError.invalid("Map catalog entry \(entry.no) has a file outside the catalog directory: \(file)")
                }
            }
            byNumber[entry.no] = entry
        }
        self.entries = byNumber
        self.directory = directory.standardizedFileURL
    }

    public static func load(url: URL) throws -> SourceStudioMapCatalog {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.kind == kind, file.version == 1 else {
            throw RigError.invalid("\(url.lastPathComponent) is not a version 1 \(kind) (kind \(file.kind), version \(file.version)).")
        }
        return try SourceStudioMapCatalog(entries: file.maps, directory: url.deletingLastPathComponent())
    }

    /// `Map.LoadMap`'s lookup: the row for `map`, or none.
    public func resolve(_ map: Int32) -> Resolution {
        if map == -1 { return .none }
        guard let entry = entries[map] else { return .notInCatalog(map) }
        guard let file = entry.file else { return .notConverted(entry) }
        let url = directory.appendingPathComponent(file).standardizedFileURL
        return .converted(entry, file: url, packageRoot: url.deletingLastPathComponent())
    }
}

/// The lines the Studio shows for a scene's map (status and inspector).
public enum SourceStudioMapStatus {
    /// What every converted map in this slice leaves out (ST-A11 slice 1).
    public static let approximationLabel = "approximated: no baked lightmaps, map lights, sun-type lighting, fog or ambient"

    static func title(_ entry: SourceStudioMapCatalog.Entry) -> String { "Map \(entry.no) \(entry.name) (\(entry.scene))" }

    /// The line for a resolution before or without a load. nil for no map.
    public static func line(_ resolution: SourceStudioMapCatalog.Resolution) -> String? {
        switch resolution {
        case .none: return nil
        case .converted(let entry, _, _): return "\(title(entry)): loading"
        case .notConverted(let entry): return "\(title(entry)): not converted (\(entry.bundlePath)); no map shown"
        case .notInCatalog(let map): return "Map \(map): not in the map catalog (mods are not evaluated); no map shown"
        }
    }

    /// The line once a converted map is drawn.
    public static func loaded(_ entry: SourceStudioMapCatalog.Entry, asset: SourceStudioMapAsset) -> String {
        var line = "\(title(entry)): \(approximationLabel)"
        if let shaders = entry.approximations?.first(where: { $0.hasPrefix("shaders approximated") }) { line += "; \(shaders)" }
        return line + " · \(asset.triangles) triangles, \(asset.parts.count) draws"
    }

    public static func failed(_ entry: SourceStudioMapCatalog.Entry, _ error: Error) -> String {
        "\(title(entry)): not loaded (\(error)); no map shown"
    }

    /// No catalog configured, or it did not load.
    public static func catalogUnavailable(map: Int32, reason: String) -> String {
        "Map \(map): \(reason); no map shown"
    }
}

/// `MapCtrl.Reflect`: the record's map transform as the "Map" root's world
/// matrix in the engine basis, `T(pos) · R(Quaternion.Euler(rot))`. The saved
/// scale is ignored (never written), so the root keeps its authored scale,
/// which the converted glTF's "Map" node carries below this matrix.
public enum SourceStudioMapPlacement {
    public static func mapRootMatrix(_ amount: KoikatsuChangeAmount) throws -> float4x4 {
        var problems: [String] = []
        for index in 0..<3 where !amount.position[index].isFinite { problems.append("pos[\(index)]") }
        for index in 0..<3 where !amount.rotationDegrees[index].isFinite { problems.append("rot[\(index)]") }
        guard problems.isEmpty else {
            throw RigError.invalid("Scene map transform has non-finite \(problems.joined(separator: ", ")).")
        }
        let rotation = UnityCoordinates.eulerDegrees(amount.rotationDegrees)
        return Transform.trs(UnityCoordinates.position(amount.position), rotation, Float3(repeating: 1))
    }

    /// The converter's visibility key for a saved `sunLightType`: 0, 1 and 2
    /// are the three `SunLightInfo` types; any other value finds no entry,
    /// so `SunLightInfo.Set` changes nothing and the authored state (-1) holds.
    public static func sunTypeKey(_ sunLightType: Int32) -> Int32 {
        (0...2).contains(sunLightType) ? sunLightType : -1
    }
}

/// One converted map on the GPU: its merged meshes, their materials and the
/// textures it registered privately. Built on a GCD worker (`load`), drawn
/// through `items`, and given back with `release` (deferred, R6).
public final class SourceStudioMapAsset: @unchecked Sendable {
    public enum Role: String, Sendable { case mapRoot, scene }

    public struct Part: Sendable {
        public let mesh: MeshHandle
        public let material: MaterialState
        /// The part's matrix inside its role frame: under the "Map" root
        /// (`mapRoot`), or the map scene's world (`scene`).
        public let local: float4x4
        public let role: Role
        /// The sun-type keys this geometry is active for (see `sunTypeKey`).
        public let visibleFor: Set<Int32>
        public let triangles: Int
    }

    public let url: URL
    public let parts: [Part]
    public let textures: [TextureHandle]
    /// Bytes the GPU allocated for the textures (RGBA8 with mips).
    public let textureBytes: Int
    public let triangles: Int
    /// Wall time of `load` on its worker.
    public let loadSeconds: Double
    private let resources: ResourceStore
    private let lock = NSLock()
    private var released = false

    private init(url: URL, parts: [Part], textures: [TextureHandle], textureBytes: Int, loadSeconds: Double, resources: ResourceStore) {
        self.url = url; self.parts = parts; self.textures = textures; self.textureBytes = textureBytes
        self.triangles = parts.reduce(0) { $0 + $1.triangles }
        self.loadSeconds = loadSeconds; self.resources = resources
    }

    /// Reads, validates and registers a converted map. Blocking: file reads,
    /// PNG decodes and MetalKit texture loads. Run it on a GCD worker, never
    /// on the main thread or the Swift concurrency pool. A failure releases
    /// everything it registered.
    public static func load(url: URL, packageRoot: URL, resources: ResourceStore) throws -> SourceStudioMapAsset {
        let start = DispatchTime.now().uptimeNanoseconds
        let loaded = try LoadedAsset.loadStatic(url: url, packageRoot: packageRoot, resources: resources)
        var textures: [Int: TextureHandle] = [:]
        do {
            let gltf = loaded.asset
            guard let mapNode = gltf.nodes.firstIndex(where: { $0.name == "Map" && $0.parent == nil }),
                  gltf.nodes[mapNode].extras?["ikkokuMapRole"]?.stringValue == Role.mapRoot.rawValue else {
                throw RigError.invalid("\(url.lastPathComponent) is not a converted map: no root node \"Map\" with role mapRoot.")
            }
            // The converter writes the root's authored scale only; the record's
            // transform replaces its translation and rotation.
            let root = gltf.nodes[mapNode]
            guard gltf.nodes[mapNode].authoredMatrix == nil, root.translation == .zero,
                  simd_length(root.rotation.vector - simd_quatf.identity.vector) < 1e-6 else {
                throw RigError.invalid("\(url.lastPathComponent): the \"Map\" node must carry no translation or rotation.")
            }
            var parts: [Part] = []
            for part in loaded.parts {
                guard let info = part.meshExtras?["ikkokuMap"],
                      let role = info["role"]?.stringValue.flatMap(Role.init(rawValue:)),
                      let keys = info["visibleFor"]?.arrayValue else {
                    throw RigError.invalid("\(url.lastPathComponent): mesh \(part.meshName) has no ikkokuMap role and visibility.")
                }
                // The role must match the node the mesh hangs under.
                var node: Int? = part.nodeIndex, underMap = false
                while let current = node { if current == mapNode { underMap = true }; node = gltf.nodes[current].parent }
                guard underMap == (role == .mapRoot) else {
                    throw RigError.invalid("\(url.lastPathComponent): mesh \(part.meshName) has role \(role.rawValue) outside its frame.")
                }
                var visible = Set<Int32>()
                for key in keys {
                    guard let value = key.doubleValue, let number = Int32(exactly: value), (-1...2).contains(number) else {
                        throw RigError.invalid("\(url.lastPathComponent): mesh \(part.meshName) has an invalid sun-type key.")
                    }
                    visible.insert(number)
                }
                var base: TextureHandle?
                if let image = part.material.baseColorImage {
                    if let handle = textures[image] { base = handle } else {
                        guard gltf.images.indices.contains(image), !gltf.images[image].data.isEmpty else {
                            throw RigError.invalid("\(url.lastPathComponent): material \(part.materialName) names a missing image.")
                        }
                        // Private (uncached) registration: the asset owns it.
                        let handle = try resources.texture(data: gltf.images[image].data,
                            key: "\(url.path)#map-img\(image)", srgb: true, cacheNew: false)
                        textures[image] = handle
                        base = handle
                    }
                }
                let indexCount = resources.mesh(part.mesh)?.indexCount ?? 0
                parts.append(Part(mesh: part.mesh, material: MaterialBuilder.itemMaterial(for: part, base: base),
                                  local: part.worldMatrix, role: role, visibleFor: visible, triangles: indexCount / 3))
            }
            let handles = textures.keys.sorted().compactMap { textures[$0] }
            let bytes = handles.reduce(0) { $0 + (resources.texture($1)?.allocatedSize ?? 0) }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            return SourceStudioMapAsset(url: loaded.url, parts: parts, textures: handles, textureBytes: bytes,
                                        loadSeconds: seconds, resources: resources)
        } catch {
            for part in loaded.parts { resources.unregister(mesh: part.mesh) }
            for handle in textures.values { resources.unregister(texture: handle) }
            throw error
        }
    }

    /// The map's draws for one scene record: `mapRoot` parts placed by the
    /// record's map transform, `scene` parts where they were authored, only
    /// the geometry active for the saved sun type. Unpickable but occluding
    /// picks (objectID 0, `pickOccluder`), no outline, no shadow casting;
    /// drawn after the characters (order 100), so early depth rejects the
    /// map pixels they cover.
    public func items(transform: KoikatsuChangeAmount, sunLightType: Int32) throws -> [RenderItem] {
        let root = try SourceStudioMapPlacement.mapRootMatrix(transform)
        let key = SourceStudioMapPlacement.sunTypeKey(sunLightType)
        return parts.filter { $0.visibleFor.contains(key) }.map { part in
            var item = RenderItem(mesh: part.mesh, material: part.material,
                                  model: part.role == .mapRoot ? root * part.local : part.local, objectID: 0)
            item.castsShadow = false
            item.outline = false
            item.pickOccluder = true
            item.order = 100
            return item
        }
    }

    public var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }

    /// Gives the meshes and textures back once no pending frame names them.
    /// Idempotent.
    public func release() {
        lock.lock()
        let first = !released
        released = true
        lock.unlock()
        guard first else { return }
        resources.retire(meshes: parts.map(\.mesh))
        resources.retire(textures: textures)
    }
}

/// A map load on a GCD worker (texture loads must not run on the main thread
/// or the Swift concurrency pool). The owner takes the asset either through
/// `completion` (main queue) or by blocking in `wait()` (synchronous imports
/// and captures, which must not render before the map). Whichever comes first
/// owns it; `cancel()` drops an asset nobody took.
public final class SourceStudioMapLoad: @unchecked Sendable {
    public let url: URL
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var outcome: Result<SourceStudioMapAsset, Error>?
    private var cancelled = false
    private var taken = false

    public init(url: URL, packageRoot: URL, resources: ResourceStore, qos: DispatchQoS.QoSClass = .userInitiated,
                completion: @escaping @MainActor @Sendable (Result<SourceStudioMapAsset, Error>) -> Void) {
        self.url = url
        DispatchQueue.global(qos: qos).async { [self] in
            let result = Result { try SourceStudioMapAsset.load(url: url, packageRoot: packageRoot, resources: resources) }
            condition.lock()
            let drop = cancelled
            if !drop { outcome = result }
            condition.broadcast()
            condition.unlock()
            if drop { try? result.get().release(); return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let delivered = self.take() else { return }
                    completion(delivered)
                }
            }
        }
    }

    public var isFinished: Bool {
        condition.lock(); defer { condition.unlock() }
        return outcome != nil || cancelled
    }

    /// The outcome, once, to its first taker; nil while running, after
    /// `cancel()` or once taken.
    private func take() -> Result<SourceStudioMapAsset, Error>? {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled, !taken, let outcome else { return nil }
        taken = true
        return outcome
    }

    /// Blocks until the load ends and takes its outcome (nil if cancelled or
    /// already delivered). The worker never waits on the caller's thread.
    public func wait() -> Result<SourceStudioMapAsset, Error>? {
        condition.lock()
        while outcome == nil, !cancelled { condition.wait() }
        condition.unlock()
        return take()
    }

    /// Nothing is delivered after this; a finished asset nobody took is released.
    public func cancel() {
        condition.lock()
        let wasCancelled = cancelled
        cancelled = true
        let untaken = !taken ? outcome : nil
        condition.broadcast()
        condition.unlock()
        if !wasCancelled, let asset = try? untaken?.get() { asset.release() }
    }
}
