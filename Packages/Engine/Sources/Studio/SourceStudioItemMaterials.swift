import Assets
import Character
import Renderer

/// ST-T04 (B4): the untinted item material of every part of a converted
/// CharaStudio item asset, built once instead of on every frame refresh.
///
/// Entries are keyed by the asset's file and hold the materials in part order,
/// so a part's material is keyed by file and part. An entry is valid only for
/// the asset instance it was built from: a repeated import of the same file
/// replaces the library's asset, its meshes and its textures, so the next
/// lookup rebuilds. The Studio clears the cache whenever an import replaces the
/// scene's item assets, so it never holds more than the current import's files.
public struct SourceStudioItemMaterials {
    private final class Entry {
        weak var asset: LoadedAsset?
        let materials: [MaterialState]
        init(asset: LoadedAsset, materials: [MaterialState]) { self.asset = asset; self.materials = materials }
    }
    private var entries: [String: Entry] = [:]
    /// Materials built since the cache was created (each part counts once).
    public private(set) var built = 0

    public init() {}

    /// Files with cached materials.
    public var count: Int { entries.count }

    /// `MaterialBuilder.itemMaterial(for:asset:tint:nil, emissive:0)` for each
    /// of `asset`'s parts, in part order, from the cache when it was built for
    /// this asset instance.
    public mutating func materials(for asset: LoadedAsset, file: String) -> [MaterialState] {
        if let entry = entries[file], entry.asset === asset { return entry.materials }
        let materials = asset.parts.map { MaterialBuilder.itemMaterial(for: $0, asset: asset, tint: nil, emissive: 0) }
        built += materials.count
        entries[file] = Entry(asset: asset, materials: materials)
        return materials
    }

    /// Drops every entry: the import that replaces the scene's item assets.
    public mutating func removeAll() { entries.removeAll() }
}
