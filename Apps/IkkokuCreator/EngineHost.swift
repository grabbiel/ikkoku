import Foundation
import Metal
import GPU
import Renderer
import Character

enum EngineHostError: Error, CustomStringConvertible {
    case noMetal
    var description: String { "Metal is unavailable on this system." }
}

/// Owns the GPU context, renderer and asset library. One per app.
@MainActor
final class EngineHost {
    let gpu: GPUContext
    let renderer: Renderer
    let library: AssetLibrary
    let assetsRoot: URL

    init() throws {
        guard let gpu = GPUContext() else { throw EngineHostError.noMetal }
        self.gpu = gpu
        self.renderer = try Renderer(gpu: gpu)
        self.assetsRoot = EngineHost.locateAssets()
        self.library = AssetLibrary(resources: renderer.resources, root: assetsRoot)
        Thumbs.root = assetsRoot
        print("[ikkoku] assets root: \(assetsRoot.path)")
        for line in library.log { print("[ikkoku] \(line)") }
    }

    /// Asset root: $IKKOKU_ASSETS, else the app bundle, else the source tree (development).
    static func locateAssets() -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["IKKOKU_ASSETS"], fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.resourceURL, fm.fileExists(atPath: res.appendingPathComponent("catalog.json").path) {
            return res
        }
        // Apps/IkkokuCreator/EngineHost.swift → repo root
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Assets")
    }
}
