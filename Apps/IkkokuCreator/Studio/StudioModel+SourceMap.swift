import Foundation
import simd
import CoreMath
import Scene
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
/// it: the record's map number, transform, sun type and map option, and what the
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
    /// `Map.visibleOption` (slice 4): the map's option objects are shown.
    let mapOption: Bool
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
                                sunLightType: settings.sunLightType, mapOption: settings.mapOption, resolution: resolution,
                                catalogProblem: problem)
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

/// PR B: `Studio.CameraControl`'s vanish for the applied map: the rows'
/// state, stepped by `refresh()` with the view from the camera to its pivot.
/// Switched on by `IKKOKU_STUDIO_MAP_VANISH` (`segment` or `midpoint`, the
/// capsule model) until the VM phase records what the player does; off, every
/// part is drawn as before.
struct SourceMapVanishRuntime {
    var state: SourceStudioMapVanishState
    let model: SourceStudioMapVanish.CapsuleModel
    /// The latest scheduled re-show step; an earlier one finds it changed.
    var timer = 0

    static func model(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SourceStudioMapVanish.CapsuleModel? {
        switch environment["IKKOKU_STUDIO_MAP_VANISH"] {
        case "segment"?, "1"?: return .segment
        case "midpoint"?: return .midpointSphere
        default: return nil
        }
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
        sourceMapVanish = nil
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
    /// transform and filtered by its sun type and map option, computed once
    /// per request.
    private func applySourceMapAsset(_ asset: SourceStudioMapAsset) {
        guard let request = sourceMapRequest else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        // LoadVanish: every row visible; the next refresh's step hides what the view touches.
        sourceMapVanish = SourceMapVanishRuntime.model().flatMap { model in
            asset.vanish.map { SourceMapVanishRuntime(state: SourceStudioMapVanishState(rows: $0.rows.count, sets: asset.vanishSets,
                                                                                        delaySeconds: $0.delaySeconds), model: model) }
        }
        do {
            sourceMapItems = try asset.items(transform: request.transform, sunLightType: request.sunLightType,
                                             mapOption: request.mapOption)
            sourceMapFailure = nil
        } catch {
            sourceMapItems = nil
            sourceMapVanish = nil
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
            print(String(format: "[ikkoku] source map: %d draws (%d lightmapped, %d particle, %d sky, %d unlit, %d silhouette; %d option parts, option %@), %d triangles, %d texture bytes (%d in %d lightmaps, %d in %d sky cubes; images: %d as BC blocks, %d decoded, source %@); loaded in %.1f ms on a worker, placed in %.2f ms on the main thread",
                         items.count, draws.filter { $0 == .lightmapped }.count, draws.filter { $0 == .particle }.count,
                         draws.filter { $0 == .sky }.count, draws.filter { $0 == .unlit }.count, draws.filter { $0 == .silhouette }.count,
                         asset.optionParts, request.mapOption ? "on" : "off",
                         asset.triangles, asset.textureBytes, asset.lightmapBytes, asset.lightmapTextures,
                         asset.cubeBytes, asset.cubeTextures, asset.blockImages, asset.decodedImages, asset.imageSource.rawValue,
                         asset.loadSeconds * 1000, sourceMapInstallSeconds * 1000))
        }
        publishSourceMapLine()
        refresh()
    }

    /// One `VanishProc` step for the applied map (PR B), with the view from
    /// the document camera to its pivot: re-places the draws when a row hides
    /// or shows, and schedules the next re-show. Returns whether the draws
    /// changed. Holds the state while a camera object is looked through
    /// (`Studio.ChangeCamera` disables CameraControl) and without a placed map.
    @discardableResult
    func stepSourceMapVanish() -> Bool {
        guard var runtime = sourceMapVanish, let asset = sourceMapAsset, let vanish = asset.vanish,
              let request = sourceMapRequest, request.converted?.file == asset.url, sourceMapItems != nil,
              activeSourceCamera == nil, let root = try? SourceStudioMapPlacement.mapRootMatrix(request.transform) else { return false }
        let camera = doc.camera
        func double(_ v: Float3) -> SIMD3<Double> { SIMD3<Double>(v) }
        let rootMatrix = simd_double4x4(columns: (SIMD4<Double>(root.columns.0), SIMD4<Double>(root.columns.1),
                                                  SIMD4<Double>(root.columns.2), SIMD4<Double>(root.columns.3)))
        let touched = vanish.touchedRows(camera: double(camera.position), pivot: double(camera.target), mapRoot: rootMatrix,
                                         sunTypeKey: SourceStudioMapPlacement.sunTypeKey(request.sunLightType),
                                         mapOption: request.mapOption, model: runtime.model)
        let changed = runtime.state.update(touched: touched, time: ProcessInfo.processInfo.systemUptime)
        if changed {
            do {
                sourceMapItems = try asset.items(transform: request.transform, sunLightType: request.sunLightType,
                                                 mapOption: request.mapOption, vanishEnabled: runtime.state.setEnabled)
            } catch {
                sourceMapFailure = error
            }
        }
        if let wait = runtime.state.secondsToNextShow {
            runtime.timer += 1
            let timer = runtime.timer
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.001) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.sourceMapVanish?.timer == timer else { return }
                    self.refresh()
                }
            }
        }
        sourceMapVanish = runtime
        return changed
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
                    line = SourceStudioMapStatus.loaded(target.entry, asset: asset, mapOption: request.mapOption)
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
        /// Unlit/Transparent and Custom/Silhouette draws, and the placed draws
        /// under a map option root (slice 4).
        let unlitDraws: Int, silhouetteDraws: Int, optionDraws: Int
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
            unlitDraws: draws.filter { $0 == .unlit }.count, silhouetteDraws: draws.filter { $0 == .silhouette }.count,
            optionDraws: items.isEmpty ? 0 : request.flatMap { r in asset?.optionDraws(sunLightType: r.sunLightType, mapOption: r.mapOption) } ?? 0,
            loadMilliseconds: asset.map { $0.loadSeconds * 1000 }, installMilliseconds: asset == nil ? nil : sourceMapInstallSeconds * 1000)
    }
}
