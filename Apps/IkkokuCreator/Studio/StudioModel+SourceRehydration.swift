import Foundation
import CryptoKit
import Renderer
import Studio
import Scene
import Assets
import Character

/// The runtime-only half of a source scene import, rebuilt from the original
/// scene file for a document that already contains the placeholder objects:
/// route runtimes and route character previews, camera objects, converted item
/// assets, the scene character light and the file's load-winner camera.
/// A native `saveScene`/`loadScene` round trip (Studio document card) carries
/// the objects, their edits and the scene identity, but none of this —
/// `rehydrateSourceRuntime()` installs exactly these entries again, through
/// `installSourceRuntime`.
struct StudioSourceRuntimeBundle {
    var routes: [UUID: SourceRouteRuntime] = [:]
    var routeCharacterPreviews: [UUID: SourceStudioCharacterPreview] = [:]
    var cameras: [UUID: (sceneSHA256: String, objectKey: Int32, name: String)] = [:]
    var itemAssets: [UUID: (sceneSHA256: String, key: String, path: String,
        colors: [SIMD4<Float>], alpha: Float)] = [:]
    var sceneLight: MainLight?
    var activeCameraAtLoad: UUID?
}

extension StudioModel {
    /// Rebuilds the source runtime caches after a native `loadScene`, or an
    /// `undo`/`redo` that restored a source document whose runtime was pruned
    /// (New Scene drops route runtimes, play state, clocks and route character
    /// previews, and a fresh process starts with none of them) — anywhere
    /// `doc.sourceSceneSHA256` is set but some source object has no live cache
    /// entry, which `sourceCacheNeedsRehydration()` reports cheaply.
    ///
    /// The document is the input, never the output: every entry is keyed to
    /// the ids already in `doc` (records are mapped by `sourceObjectKey`),
    /// and on success nothing in the document is written, so a
    /// save→load→save round trip stays byte-identical. On failure — the file
    /// is missing or its bytes no longer hash to the document's recorded
    /// SHA-256 — the caches install EMPTY (every read site's scene-identity
    /// guard then treats the document as an ordinary native scene) and one
    /// diagnostic is appended to `doc.sourcePreviewDiagnostics`; this never
    /// throws out of its callers.
    ///
    /// After a successful rehydration `activeSourceCamera` is the FILE's load
    /// winner (`SourceStudioCameraObjects.activeAtLoad`), not any camera the
    /// user looked through before the save: live camera choice and route play
    /// clocks are runtime state a native document never carried, so they
    /// restart from the file's saved flags (see `installSourceRuntime`).
    func rehydrateSourceRuntime() {
        guard let hash = doc.sourceSceneSHA256, sourceCacheNeedsRehydration() else { return }
        sourceRehydrationCount += 1
        do {
            guard let sceneURL = sourceSceneFileURL() else {
                throw RigError.invalid("the source scene file \(doc.sourceSceneFile ?? "<unset>") is missing")
            }
            let handle = try FileHandle(forReadingFrom: sceneURL); defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
            guard bytes.count <= 256 * 1024 * 1024,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else {
                throw RigError.invalid("the source scene file changed since it was imported")
            }
            let source = try KoikatsuSceneReader.decodeDocument(bytes)
            let (rigURL, boneCatalogURL) = try sourceRigInputs()
            installSourceRuntime(try buildSourceRuntimeBundle(source: source, sceneURL: sceneURL,
                hash: hash, rigURL: rigURL, boneCatalogURL: boneCatalogURL, document: doc))
        } catch {
            // Empty install: every cache entry carries the scene identity, so
            // clearing them leaves the guards to report "ordinary native
            // scene" at each read site instead of a half-populated runtime.
            installSourceRuntime(StudioSourceRuntimeBundle())
            // Appended by direct assignment, not `update`: a rehydration
            // failure is a load-time fact, not an undoable edit.
            doc.sourcePreviewDiagnostics = (doc.sourcePreviewDiagnostics ?? [])
                + ["Source scene rehydration: \(error); the imported scene's cameras, props, routes and scene light stay unavailable until the scene file is restored or the scene is reimported."]
        }
    }

    /// The scene file the document's hashes were taken from:
    /// `doc.sourceSceneFile` while it exists, else any character reference's
    /// `sceneFile` (the import wrote both from the same read, and a loaded
    /// document carries the references verbatim).
    private func sourceSceneFileURL() -> URL? {
        if let path = doc.sourceSceneFile {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for object in doc.objects {
            if let reference = object.sourceCharacter,
               FileManager.default.fileExists(atPath: reference.sceneFile) {
                return URL(fileURLWithPath: reference.sceneFile)
            }
        }
        return nil
    }

    /// The rig and bone catalog for previews the document cannot carry a
    /// reference for (route characters stay placeholders): the first
    /// character's own `sourceCharacter` paths when the file is still there,
    /// else the same locate calls the import used.
    private func sourceRigInputs() throws -> (rigURL: URL, boneCatalogURL: URL) {
        if let reference = doc.objects.first(where: { $0.sourceCharacter != nil })?.sourceCharacter {
            let rig = URL(fileURLWithPath: reference.rigFile)
            if FileManager.default.fileExists(atPath: rig.path) {
                return (rig, URL(fileURLWithPath: reference.boneCatalogFile))
            }
        }
        guard let rig = try EngineHost.locateSourceAvatar() else {
            throw RigError.invalid("Export the original clothed avatar before previewing source scenes.")
        }
        return (rig, rig.deletingLastPathComponent()
            .appendingPathComponent("../studio-pose/contract.json").standardizedFileURL)
    }

    /// The cache-building half of `importSourceScenePreview`, aimed at an
    /// EXISTING document instead of a fresh one: the import's DFS decides
    /// which entries exist and how they look; this maps them by
    /// `sourceObjectKey` onto `document`'s UUIDs. Entries whose object is not
    /// in the document (deleted, or a scene the document never showed) are
    /// skipped, and the document is only ever read. The conversion
    /// environment (`IKKOKU_STUDIO_ITEM_CATALOG` and friends) is re-read the
    /// way the import read it; a catalog that fails to load simply leaves
    /// the items unrendered, as at import.
    private func buildSourceRuntimeBundle(source: KoikatsuSceneDocument, sceneURL: URL,
        hash: String, rigURL: URL, boneCatalogURL: URL, document: StudioDocument) throws -> StudioSourceRuntimeBundle {
        var byKey: [Int32: UUID] = [:]
        for object in document.objects { if let key = object.sourceObjectKey { byKey[key] = object.id } }
        var bundle = StudioSourceRuntimeBundle()
        let makerLibrary = try EngineHost.locateMakerLibrary()
        let attachmentURL = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_ATTACHMENT_CATALOG"].map { URL(fileURLWithPath: $0) }
            ?? boneCatalogURL.deletingLastPathComponent().appendingPathComponent("attachments.json")
        let attachmentPath = FileManager.default.fileExists(atPath: attachmentURL.path) ? attachmentURL.path : nil
        let animationPath = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_ANIMATION_CATALOG"]
        var itemResolver: KoikatsuAssetResolver?
        if let itemCatalogPath = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_ITEM_CATALOG"] {
            let itemCatalogURL = URL(fileURLWithPath: itemCatalogPath)
            if let itemCatalog = try? JSONDecoder().decode(KoikatsuAssetCatalog.self, from: Data(contentsOf: itemCatalogURL)) {
                itemResolver = try? KoikatsuAssetResolver(catalog: itemCatalog, directory: itemCatalogURL.deletingLastPathComponent())
            }
        }
        var loadedItemAssets: [String: LoadedAsset] = [:]
        var stack = source.snapshot.roots.reversed().map { ($0, false) }
        while let (record, routeChild) = stack.popLast() {
            defer {
                stack += record.children.reversed().map { ($0, routeChild || record.kind == .route) }
                if let character = record.character {
                    for key in character.accessoryChildren.keys.sorted().reversed() {
                        stack += (character.accessoryChildren[key] ?? []).reversed().map { ($0, routeChild) }
                    }
                }
            }
            guard let id = byKey[record.sourceKey] else { continue }
            if let character = record.character {
                // Only route children live here; an ordinary character's
                // preview belongs to `sourceInstances`, which `refresh()`
                // rebuilds lazily from the document's own reference.
                guard routeChild else { continue }
                let selectedRig = character.sex == 0
                    ? (try EngineHost.locateSourceAvatar(sex: .male) ?? rigURL) : rigURL
                let reference = SourceStudioCharacterReference(sceneFile: sceneURL.path, sceneSHA256: hash,
                    rigFile: selectedRig.path, boneCatalogFile: boneCatalogURL.path, objectKey: record.sourceKey,
                    makerLibraryFile: makerLibrary?.sourceURL.path, attachmentCatalogFile: attachmentPath,
                    animationCatalogFile: animationPath,
                    dynamicsFile: ProcessInfo.processInfo.environment["IKKOKU_STUDIO_DYNAMICS"],
                    handPatternsFile: ProcessInfo.processInfo.environment["IKKOKU_STUDIO_HAND_PATTERNS"],
                    lookSettingsFile: ProcessInfo.processInfo.environment["IKKOKU_STUDIO_LOOK_SETTINGS"])
                if let preview = try? SourceStudioCharacterPreview(reference: reference, resources: host.renderer.resources) {
                    preview.automaticBlink = sourceAutomaticBlink
                    bundle.routeCharacterPreviews[id] = preview
                }
            } else if record.kind == .camera {
                bundle.cameras[id] = (sceneSHA256: hash, objectKey: record.sourceKey,
                    name: record.name ?? "Source camera \(record.sourceKey)")
            } else if record.kind == .item, let item = record.item, let resolver = itemResolver {
                let itemKey = KoikatsuAssetResolver.key(group: item.group, category: item.category, no: item.no)
                do {
                    let asset = try resolver.resolve(group: item.group, category: item.category, no: item.no)
                    if loadedItemAssets[asset.url.path] == nil {
                        loadedItemAssets[asset.url.path] = try library.importStaticAsset(url: asset.url)
                    }
                    bundle.itemAssets[id] = (sceneSHA256: hash, key: itemKey, path: asset.url.path,
                        colors: item.colors, alpha: item.alpha)
                } catch {
                    // Unmapped or unreadable item: the placeholder renders
                    // nothing, exactly as the import's retained node.
                }
            }
            if record.kind == .route, let route = record.route {
                bundle.routes[id] = SourceRouteRuntime(sceneFile: sceneURL.path, sceneSHA256: hash,
                    objectKey: record.sourceKey, route: route,
                    pointLocals: SourceStudioRoutePlayback.pointLocals(from: route))
            }
        }
        // The file's saved active flags pick the load winner again; the
        // import's `ChangeCamera(camera, record.active)` rule verbatim.
        if let key = SourceStudioCameraObjects.activeAtLoad(source.snapshot),
           let cameraID = bundle.cameras.keys.first(where: { bundle.cameras[$0]?.objectKey == key }) {
            bundle.activeCameraAtLoad = cameraID
        }
        bundle.sceneLight = try? SourceStudioSceneLight.mainLight(from: source.settings.characterLight)
        return bundle
    }
}
