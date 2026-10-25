import Foundation
import Assets
import Scene
import Renderer
import Character
import Studio

/// R7 phase 2 item 6 (S1): one source scene import between its start and its
/// commit (`StudioModel.importSourceScenePreview` and
/// `beginSourceSceneImport`).
///
/// `StudioModel.prepareSourceSceneImport` reads and decodes the scene on the
/// main thread, then walks it once in the import's own order to collect the
/// character references and the item records. The batch starts every
/// character's first half on worker threads at once. The commit later walks
/// the scene again with the import's original code and takes each
/// character and item from here, in that same order:
/// - a synchronous import builds each one where the walk reaches it;
/// - a background import has already built them in that order: the
///   characters' second halves on the Studio's build queue, the items on the
///   main thread (`AssetLibrary` is main-thread only).
///
/// Either way, every mesh is registered in the same order as the synchronous
/// import, the document, names and diagnostics come from the same code, and
/// nothing reaches the model before the commit.
final class SourceSceneImportJob {
    let sceneURL: URL, rigURL: URL, boneCatalogURL: URL, hash: String
    let source: KoikatsuSceneDocument
    /// The imported document and its diagnostics as far as the walk.
    let imported: StudioDocument
    let diagnostics: [String]
    let sceneLightOverride: MainLight?
    /// The model's animation catalog state the commit installs.
    let animationCatalog: SourceStudioAnimationCatalog?, animationCatalogError: String?
    let itemResolver: KoikatsuAssetResolver?
    let itemNames: [String: String]
    /// Every character record in walk order, with the reference it gets.
    let references: [SourceStudioCharacterReference]
    /// Every item record the walk loads, in walk order.
    let itemRecords: [KoikatsuItemRecord]
    /// Characters and items interleaved in walk order.
    let steps: [SourceStudioCharacterBatch.Step]
    let batch: SourceStudioCharacterBatch
    /// ST-A11: the scene's map and its load, started with the characters on
    /// its own GCD worker; the commit hands both to the model, and a cancelled
    /// or failed import cancels the load.
    var mapRequest: SourceMapRequest?
    var mapLoad: SourceStudioMapLoad?
    private(set) var characters: [Result<SourceStudioCharacterPreview, Error>?]
    private var items: [Result<(name: String, url: URL), Error>?]
    private var loadedItemAssets: [String: LoadedAsset] = [:]

    init(sceneURL: URL, rigURL: URL, boneCatalogURL: URL, hash: String, source: KoikatsuSceneDocument,
         imported: StudioDocument, diagnostics: [String], sceneLightOverride: MainLight?,
         animationCatalog: SourceStudioAnimationCatalog?, animationCatalogError: String?,
         itemResolver: KoikatsuAssetResolver?, itemNames: [String: String],
         references: [SourceStudioCharacterReference], itemRecords: [KoikatsuItemRecord],
         steps: [SourceStudioCharacterBatch.Step], batch: SourceStudioCharacterBatch) {
        self.sceneURL = sceneURL; self.rigURL = rigURL; self.boneCatalogURL = boneCatalogURL; self.hash = hash
        self.source = source; self.imported = imported; self.diagnostics = diagnostics
        self.sceneLightOverride = sceneLightOverride
        self.animationCatalog = animationCatalog; self.animationCatalogError = animationCatalogError
        self.itemResolver = itemResolver; self.itemNames = itemNames
        self.references = references; self.itemRecords = itemRecords; self.steps = steps; self.batch = batch
        characters = Array(repeating: nil, count: references.count)
        items = Array(repeating: nil, count: itemRecords.count)
    }

    /// Characters whose build finished (successfully or not).
    var builtCount: Int { characters.lazy.filter { $0 != nil }.count }

    /// Records a character the build queue finished.
    func deliver(_ delivery: SourceStudioCharacterBatch.Delivery) {
        characters[delivery.index] = delivery.result
    }

    /// Character `index`: the build the queue delivered, or its second half
    /// now, on this thread.
    func character(_ index: Int) throws -> SourceStudioCharacterPreview {
        if let result = characters[index] { return try result.get() }
        let result = Result { try batch.build(index) }
        characters[index] = result
        return try result.get()
    }

    /// Item `index`: its catalog entry, with the asset imported into
    /// `library` once per file, exactly as the import's walk loads it. The
    /// outcome is kept, so the commit's walk reads what the build queue's
    /// main-thread step loaded.
    func item(_ index: Int, library: AssetLibrary) throws -> (name: String, url: URL) {
        if let result = items[index] { return try result.get() }
        let record = itemRecords[index]
        let result = Result { () throws -> (name: String, url: URL) in
            guard let resolver = itemResolver else { throw RigError.invalid("The item catalog is not loaded.") }
            let asset = try resolver.resolve(group: record.group, category: record.category, no: record.no)
            if loadedItemAssets[asset.url.path] == nil {
                loadedItemAssets[asset.url.path] = try library.importStaticAsset(url: asset.url,
                    packageRoot: KoikatsuAssetResolver.packageRoot(of: asset.url))
            }
            return asset
        }
        items[index] = result
        return try result.get()
    }
}
