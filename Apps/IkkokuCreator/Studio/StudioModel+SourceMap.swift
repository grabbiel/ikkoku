import Foundation
import Renderer
import Studio

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
                // Startup accounting (docs/reference/performance.md): the
                // first map drawn; later loads do not move the mark.
                PerfTrace.mark("sourceMapReady")
                print(String(format: "[ikkoku] source map: %d draws, %d triangles, %d texture bytes; loaded in %.1f ms on a worker, placed in %.2f ms on the main thread",
                             sourceMapItems?.count ?? 0, asset.triangles, asset.textureBytes, asset.loadSeconds * 1000, sourceMapInstallSeconds * 1000))
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
    /// document's map, nil for a document without one.
    func publishSourceMapLine() {
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
        /// Worker wall time of the asset's load, and main-thread time of the
        /// last install (placing the draws), in milliseconds.
        let loadMilliseconds: Double?, installMilliseconds: Double?
    }
    func sourceMapCensus() -> SourceMapCensus {
        let request = sourceMapRequest.flatMap { $0.sceneSHA256 == doc.sourceSceneSHA256 ? $0 : nil }
        let asset = request?.converted.flatMap { target in sourceMapAsset.flatMap { $0.url == target.file ? $0 : nil } }
        return SourceMapCensus(map: request?.map, line: sourceMapLine, draws: currentSourceMapItems.count,
            triangles: asset?.triangles ?? 0, textureBytes: asset?.textureBytes ?? 0, loading: isLoadingSourceMap,
            loadMilliseconds: asset.map { $0.loadSeconds * 1000 }, installMilliseconds: asset == nil ? nil : sourceMapInstallSeconds * 1000)
    }
}
