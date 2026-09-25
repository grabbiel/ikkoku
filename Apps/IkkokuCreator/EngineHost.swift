import Foundation
import Metal
import GPU
import Renderer
import Character

enum EngineHostError: Error, CustomStringConvertible {
    case noMetal
    case invalidSourceAvatar(String)
    var description: String {
        switch self {
        case .noMetal: return "Metal is unavailable on this system."
        case .invalidSourceAvatar(let detail): return detail
        }
    }
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

    static func locateMakerLibrary() throws -> SourceMakerLibrary? {
        let override = ProcessInfo.processInfo.environment["IKKOKU_MAKER_LIBRARY"]
        if override == "none" { return nil }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = override.map { URL(fileURLWithPath: $0) } ?? repo.appendingPathComponent(".local/reverse/maker-library/library.json")
        if override == nil && !FileManager.default.fileExists(atPath: url.path) { return nil }
        return try SourceMakerLibrary.load(url: url)
    }

    /// Original data is local and optional. An explicit override must be valid;
    /// the development default is available only after its appearance is ready.
    static func locateSourceAvatar(sex: Sex = .female) throws -> URL? {
        let fm = FileManager.default
        let variable = sex == .male ? "IKKOKU_SOURCE_MALE_AVATAR" : "IKKOKU_SOURCE_AVATAR"
        let override = ProcessInfo.processInfo.environment[variable]
        let url: URL
        if let override {
            guard !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineHostError.invalidSourceAvatar("\(variable) is empty.")
            }
            url = URL(fileURLWithPath: override).standardizedFileURL
        } else {
            let source = URL(fileURLWithPath: #filePath)
            let repo = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            url = repo.appendingPathComponent(sex == .male ? ".local/reverse/male/source-male-avatar.json" : ".local/reverse/rigs/source-avatar.json")
        }
        let appearance = url.deletingPathExtension().appendingPathExtension("appearance.json")
        for file in [url, appearance] {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue else {
                if override == nil { return nil }
                throw EngineHostError.invalidSourceAvatar("Original base file is missing: \(file.path)")
            }
        }
        struct Header: Decodable { let schemaVersion: Int; let kind: String? }
        let header = try JSONDecoder().decode(Header.self, from: Data(contentsOf: url))
        guard header.schemaVersion == 1, header.kind == (sex == .male ? "koikatsu-male-avatar" : "koikatsu-female-avatar") else {
            throw EngineHostError.invalidSourceAvatar("Original base must be a supported \(sex == .male ? "male" : "female") avatar manifest: \(url.path)")
        }
        // The complete hierarchy, palette and appearance validation happens in
        // openSourceRig before it replaces the current character.
        return url
    }
}
