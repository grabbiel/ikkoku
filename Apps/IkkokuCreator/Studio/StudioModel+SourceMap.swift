import Foundation
import Renderer
import ShaderTypes
import Studio

/// The inputs of `StudioModel.sourceMapLine` that can change without the map
/// code running: the document's scene (undo, redo, New Scene) and the map
/// state, compared by identity.
struct SourceMapLineKey: Equatable {
    let documentScene: String?, requestScene: String?, map: Int32?
    let asset: ObjectIdentifier?, placed: Bool, failed: Bool, shown: Bool
}

/// ST-A11: the map an imported CharaStudio scene names, as the preview needs
/// it: the record's map number, transform and sun type, and what the
/// converted catalog (`IKKOKU_STUDIO_MAP_CATALOG`) resolves it to. Runtime
/// only: the document has no map field and original export writes the
/// record's map bytes verbatim, so nothing here reaches either. It carries
/// the scene identity, which gates every read (`refresh()`, the status line),
/// so it survives undo/redo and New Scene like `sourceSceneLight`.
struct SourceMapRequest {
    let sceneSHA256: String
    let map: Int32
    let transform: KoikatsuChangeAmount
    let sunLightType: Int32
    /// nil when no catalog could be read; `catalogProblem` says why.
    let resolution: SourceStudioMapCatalog.Resolution?
    let catalogProblem: String?

    /// The record's map, resolved against the catalog. nil when the scene has
    /// no map (-1): nothing is shown or reported. Reads one small JSON file.
    static func make(settings: KoikatsuSceneSettings, sceneSHA256: String,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> SourceMapRequest? {
        guard settings.map != -1 else { return nil }
        var resolution: SourceStudioMapCatalog.Resolution?, problem: String?
        if let path = environment["IKKOKU_STUDIO_MAP_CATALOG"] {
            do { resolution = try SourceStudioMapCatalog.load(url: URL(fileURLWithPath: path)).resolve(settings.map) }
            catch { problem = "map catalog \(path) not loaded (\(error))" }
        } else {
            problem = "no map catalog (IKKOKU_STUDIO_MAP_CATALOG is not set)"
        }
        return SourceMapRequest(sceneSHA256: sceneSHA256, map: settings.map, transform: settings.mapTransform,
                                sunLightType: settings.sunLightType, resolution: resolution, catalogProblem: problem)
    }

    /// The converted file this request draws, if any.
    var converted: (entry: SourceStudioMapCatalog.Entry, file: URL, packageRoot: URL)? {
        if case .converted(let entry, let file, let root)? = resolution { return (entry, file, root) }
        return nil
    }

    /// The line before (or without) a load.
    var pendingLine: String? {
        if let resolution { return SourceStudioMapStatus.line(resolution) }
        return SourceStudioMapStatus.catalogUnavailable(map: map, reason: catalogProblem ?? "no map catalog")
    }
}

extension StudioModel {
    /// Starts loading `request`'s converted map on a GCD worker unless the
    /// loaded asset already is that file. The caller owns the returned load
    /// (an import job until its commit, then `sourceMapLoad`).
    func startSourceMapLoad(for request: SourceMapRequest?) -> SourceStudioMapLoad? {
        guard let target = request?.converted, sourceMapAsset?.url != target.file else { return nil }
        return SourceStudioMapLoad(url: target.file, packageRoot: target.packageRoot, resources: host.renderer.resources) { [weak self] result in
            self?.finishSourceMapLoad(result, file: target.file)
        }
    }

    /// Installs a scene's map request: the import's commit (with the load its
    /// preparation started) and `installSourceRuntime` (rehydration). A
    /// request for the asset already loaded draws at once; a converted map
    /// otherwise loads off the main thread, and a synchronous model (captures,
    /// scenarios) waits for it here so the next frame already has it. No map,
    /// or one that cannot draw, releases the loaded asset.
    func installSourceMap(_ request: SourceMapRequest?, load: SourceStudioMapLoad? = nil) {
        sourceMapRequest = request
        sourceMapItems = nil
        sourceMapFailure = nil
        if let load, load !== sourceMapLoad { sourceMapLoad?.cancel(); sourceMapLoad = load }
        guard let target = request?.converted else {
            sourceMapLoad?.cancel(); sourceMapLoad = nil
            sourceMapAsset?.release(); sourceMapAsset = nil
            publishSourceMapLine()
            return
        }
        if let asset = sourceMapAsset, asset.url == target.file {
            sourceMapLoad?.cancel(); sourceMapLoad = nil
            applySourceMapAsset(asset)
            return
        }
        if sourceMapLoad?.url != target.file {
            sourceMapLoad?.cancel()
            sourceMapLoad = startSourceMapLoad(for: request)
        }
        publishSourceMapLine()
        if !asyncSourceBuilds { waitForSourceMap() }
    }

    /// Restarts the current document's map after a cancelled load (New Scene
    /// or a scene load during the load, then undo back to the scene). Cheap
    /// when nothing is missing; runs after every history step.
    func resumeSourceMapIfNeeded() {
        guard let request = sourceMapRequest, request.sceneSHA256 == doc.sourceSceneSHA256,
              request.converted != nil, sourceMapItems == nil, sourceMapLoad == nil, sourceMapFailure == nil else { return }
        installSourceMap(request)
    }

    /// Blocks until the in-flight map load ends and installs it. The worker
    /// never needs the main thread, so this cannot deadlock.
    func waitForSourceMap() {
        guard let load = sourceMapLoad, let result = load.wait() else { return }
        finishSourceMapLoad(result, file: load.url)
    }

    /// A load's outcome on the main thread (its completion, or `waitForSourceMap`).
    func finishSourceMapLoad(_ result: Result<SourceStudioMapAsset, Error>, file: URL) {
        if sourceMapLoad?.url == file { sourceMapLoad = nil }
        switch result {
        case .success(let asset):
            if let previous = sourceMapAsset, previous !== asset { previous.release() }
            sourceMapAsset = asset
            if sourceMapRequest?.converted?.file == asset.url {
                applySourceMapAsset(asset)
                return
            }
        case .failure(let error):
            if sourceMapRequest?.converted?.file == file { sourceMapFailure = error }
        }
        publishSourceMapLine()
        refresh()
    }

    /// The request's draws from the loaded asset: placed by the record's map
    /// transform and filtered by its sun type, computed once per request.
    private func applySourceMapAsset(_ asset: SourceStudioMapAsset) {
        guard let request = sourceMapRequest else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            sourceMapItems = try asset.items(transform: request.transform, sunLightType: request.sunLightType)
            sourceMapFailure = nil
        } catch {
            sourceMapItems = nil
            sourceMapFailure = error
        }
        sourceMapInstallSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        if let items = sourceMapItems {
            // Startup accounting (docs/reference/performance.md): the map
            // placed for drawing. An import's load usually finishes before
            // the import commits, so this runs at the commit; the report
            // keeps the first mark.
            PerfTrace.mark("sourceMapReady")
            let draws = items.map { SourceStudioMapAsset.Draw($0.material) }
            print(String(format: "[ikkoku] source map: %d draws (%d lightmapped, %d particle, %d sky), %d triangles, %d texture bytes (%d in %d lightmaps, %d in %d sky cubes; images: %d as BC blocks, %d decoded, source %@); loaded in %.1f ms on a worker, placed in %.2f ms on the main thread",
                         items.count, draws.filter { $0 == .lightmapped }.count, draws.filter { $0 == .particle }.count,
                         draws.filter { $0 == .sky }.count, asset.triangles, asset.textureBytes, asset.lightmapBytes, asset.lightmapTextures,
                         asset.cubeBytes, asset.cubeTextures, asset.blockImages, asset.decodedImages, asset.imageSource.rawValue,
                         asset.loadSeconds * 1000, sourceMapInstallSeconds * 1000))
        }
        publishSourceMapLine()
        refresh()
    }

    /// The map draws `refresh()` adds: only for the scene the request belongs
    /// to, and only while View ▸ Show Source Map is on.
    var currentSourceMapItems: [RenderItem] {
        guard showSourceMap, let items = sourceMapItems, !items.isEmpty, let request = sourceMapRequest,
              request.sceneSHA256 == doc.sourceSceneSHA256 else { return [] }
        return items
    }

    /// Whether a map load is still running (an import's or a resumed one).
    var isLoadingSourceMap: Bool { sourceMapLoad != nil }

    /// Rewrites `sourceMapLine` when it changes: the line for the current
    /// document's map, nil for a document without one. The map's own state
    /// changes call it directly. `refresh()` passes `onlyIfChanged`, so a
    /// frame whose inputs are the same as the last build's (`SourceMapLineKey`)
    /// compares two scene hashes and builds no string.
    func publishSourceMapLine(onlyIfChanged: Bool = false) {
        let key = SourceMapLineKey(documentScene: doc.sourceSceneSHA256, requestScene: sourceMapRequest?.sceneSHA256,
                                   map: sourceMapRequest?.map, asset: sourceMapAsset.map(ObjectIdentifier.init),
                                   placed: sourceMapItems != nil, failed: sourceMapFailure != nil, shown: showSourceMap)
        if onlyIfChanged, key == sourceMapLineKey { return }
        sourceMapLineKey = key
        var line: String?
        if let request = sourceMapRequest, request.sceneSHA256 == doc.sourceSceneSHA256 {
            if let target = request.converted {
                if let error = sourceMapFailure {
                    line = SourceStudioMapStatus.failed(target.entry, error)
                } else if let asset = sourceMapAsset, asset.url == target.file, sourceMapItems != nil {
                    line = SourceStudioMapStatus.loaded(target.entry, asset: asset)
                } else {
                    line = request.pendingLine
                }
                if line != nil, !showSourceMap { line! += " · hidden (View ▸ Show Source Map)" }
            } else {
                line = request.pendingLine
            }
        }
        if sourceMapLine != line { sourceMapLine = line }
    }

    /// For the scenario lane: the map state the render path sees now.
    struct SourceMapCensus: Encodable {
        let map: Int32?, line: String?, draws: Int, triangles: Int, textureBytes: Int, loading: Bool
        /// Draws with the baked-lightmap material (`MaterialKindMap` without the
        /// particle flag), and the bytes of the lightmap textures they sample
        /// (ST-A11 slice 2).
        let lightmappedDraws: Int, lightmapBytes: Int
        /// Particles/Alpha Blended and Skybox/Cubemap draws, the sky cubes'
        /// bytes, and the images uploaded as BC blocks or decoded (slice 3).
        let particleDraws: Int, skyDraws: Int, cubeBytes: Int, blockImages: Int, decodedImages: Int
        /// Worker wall time of the asset's load, and main-thread time of the
        /// last install (placing the draws), in milliseconds.
        let loadMilliseconds: Double?, installMilliseconds: Double?
    }
    func sourceMapCensus() -> SourceMapCensus {
        let request = sourceMapRequest.flatMap { $0.sceneSHA256 == doc.sourceSceneSHA256 ? $0 : nil }
        let asset = request?.converted.flatMap { target in sourceMapAsset.flatMap { $0.url == target.file ? $0 : nil } }
        let items = currentSourceMapItems
        let draws = items.map { SourceStudioMapAsset.Draw($0.material) }
        return SourceMapCensus(map: request?.map, line: sourceMapLine, draws: items.count,
            triangles: asset?.triangles ?? 0, textureBytes: asset?.textureBytes ?? 0, loading: isLoadingSourceMap,
            lightmappedDraws: draws.filter { $0 == .lightmapped }.count, lightmapBytes: asset?.lightmapBytes ?? 0,
            particleDraws: draws.filter { $0 == .particle }.count, skyDraws: draws.filter { $0 == .sky }.count,
            cubeBytes: asset?.cubeBytes ?? 0, blockImages: asset?.blockImages ?? 0, decodedImages: asset?.decodedImages ?? 0,
            loadMilliseconds: asset.map { $0.loadSeconds * 1000 }, installMilliseconds: asset == nil ? nil : sourceMapInstallSeconds * 1000)
    }
}
