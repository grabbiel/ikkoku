import Assets
import Character
import Renderer

/// ST-T04 (B4): the untinted item materials of one converted CharaStudio item
/// asset instance, in part order. Each is
/// `MaterialBuilder.itemMaterial(for:asset:tint:nil, emissive:0)`, built once
/// instead of on every frame refresh.
///
/// **What the materials depend on.** That call reads only:
/// - the part's own material data: base colour factor, base and normal image
///   indices, double-sided, alpha mode and cutoff;
/// - the asset instance's image cache (`LoadedAsset.imageTexture`);
/// - constants: the item kind's defaults, no tint, no emission.
///
/// No per-object state enters it (the record's colours and alpha, its
/// transform), and no per-scene state does either. The record's tint goes onto
/// a copy per record (`SourceStudioItemColor.apply`). So one set per asset
/// instance is correct, and every object that draws the asset shares it.
///
/// **Validity and lifetime.** A set is valid only for the asset instance it was
/// built from: a repeated import of the same file replaces the library's asset,
/// its meshes and its textures, and the next lookup with the new instance
/// rebuilds. The set holds that instance strongly, so the identity check cannot
/// be fooled by a reused address. The Studio keeps sets only in its item asset
/// entries, one per file per import, so an asset lives no longer than the
/// entries that draw it.
///
/// **Failed images.** When a part names an image that does not load, the
/// materials are returned but not kept, so the next refresh tries again, as the
/// builder did on every refresh before the cache.
///
/// Main actor only: the Studio builds and reads sets in `refresh()`. An import
/// or rehydration may create an empty set elsewhere and hand it over.
public final class SourceStudioItemMaterialSet: @unchecked Sendable {
    @usableFromInline var builtFor: LoadedAsset?
    @usableFromInline var built: [MaterialState] = []
    /// Material builds so far (each part counts once per build).
    public private(set) var builds = 0

    public init() {}

    /// The asset instance whose materials are kept, if any.
    public var asset: LoadedAsset? { builtFor }

    /// The untinted materials of `asset`'s parts, in part order: the kept ones
    /// when they were built for this instance, else freshly built.
    @inlinable
    public func materials(for asset: LoadedAsset) -> [MaterialState] {
        if builtFor === asset { return built }
        return rebuild(asset)
    }

    @usableFromInline
    func rebuild(_ asset: LoadedAsset) -> [MaterialState] {
        let materials = asset.parts.map { MaterialBuilder.itemMaterial(for: $0, asset: asset, tint: nil, emissive: 0) }
        builds += materials.count
        let complete = zip(asset.parts, materials).allSatisfy { part, material in
            (part.material.baseColorImage == nil || material.base != nil)
                && (part.material.normalImage == nil || material.normal != nil)
        }
        if complete {
            builtFor = asset
            built = materials
        } else {
            builtFor = nil
            built = []
        }
        return materials
    }
}
