import Foundation
import Metal
import GPU
import Renderer
import Character
import Assets

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
        for line in Self.convertedLibraryReport() { print("[ikkoku] \(line)") }
        for line in Self.companionGapReport() { print("[ikkoku] \(line)") }
    }

    // MARK: Converted library (A-T02)

    /// User-defaults key of the converted library the user chose with
    /// File → Choose Converted Library…: a `ResourceLibraryLocation` stored as a JSON
    /// string in `~/Library/Preferences/com.grabbiel.IkkokuCreator.plist`, so
    /// `plutil -p ~/Library/Preferences/com.grabbiel.IkkokuCreator.plist` shows it
    /// (`defaults read com.grabbiel.IkkokuCreator` reads a stale sandbox container's
    /// plist instead when one exists). Each converted lookup reads it after its explicit variable and
    /// before its source-tree fallback.
    static let convertedLibraryDefaultsKey = "ConvertedLibraryLocation"

    /// Automated runs (any capture or scenario mode, or `IKKOKU_CAPTURE_UI`) ignore the
    /// saved selection, so a lane's inputs come only from its environment and never from
    /// this machine's user defaults. Interactive launches use it.
    static var savedSelectionApplies: Bool {
        !((try? CaptureRequest.validate(ProcessInfo.processInfo.environment))?.isAutomated ?? false)
    }

    /// The saved selection, or nil when none is saved, it cannot be read (an
    /// unreadable record is reported once at startup and otherwise ignored), or the
    /// run is automated (`savedSelectionApplies`).
    static var selectedConvertedLibrary: ResourceLibraryLocation? {
        guard savedSelectionApplies,
              let text = UserDefaults.standard.string(forKey: convertedLibraryDefaultsKey) else { return nil }
        return try? ResourceLibraryLocation.decode(Data(text.utf8))
    }

    /// Records every converted library found under `root` (the folder layout the
    /// exporters write under `.local/reverse/`) and saves the selection.
    static func selectConvertedLibrary(root: URL) throws -> ResourceLibraryLocation {
        let location = try ResourceLibraryLocation.convertedRoot(root)
        let record = try location.encoded()
        UserDefaults.standard.set(String(decoding: record, as: UTF8.self), forKey: convertedLibraryDefaultsKey)
        return location
    }

    static func forgetConvertedLibrary() { UserDefaults.standard.removeObject(forKey: convertedLibraryDefaultsKey) }

    /// Startup lines: the saved selection, and each selected library whose manifest
    /// no longer has the identity it was selected with.
    static func convertedLibraryReport() -> [String] {
        guard let text = UserDefaults.standard.string(forKey: convertedLibraryDefaultsKey) else { return [] }
        guard savedSelectionApplies else { return ["the saved converted library selection is ignored in an automated run"] }
        let location: ResourceLibraryLocation
        do { location = try ResourceLibraryLocation.decode(Data(text.utf8)) }
        catch { return ["the saved converted library selection is ignored: \(error)"] }
        var lines = location.libraries.map { "converted library: \($0.identityDescription) at \($0.root)/\($0.manifest)" }
        for change in location.changedLibraries() {
            let now = change.current.map { "it is now \($0.identityDescription)" } ?? "its manifest is missing or invalid"
            lines.append("converted library changed since it was selected: \(change.recorded.identityDescription) at \(change.recorded.root); \(now)")
        }
        lines += location.companionProblems().map { "converted library: \($0)" }
        return lines
    }

    /// The Studio bone catalog the source scene lookups read for the original base
    /// manifest `rig`: the converted layout's `studio-pose/contract.json`
    /// (`ResourceCompanion.studioPoseContract`, A-T02).
    static func studioPoseContract(forRig rig: URL) -> URL { ResourceCompanion.studioPoseContract.url(besideManifest: rig) }

    /// A startup line for each companion file missing beside the female base an
    /// explicit `IKKOKU_SOURCE_AVATAR` or the source-tree default names, so a
    /// copied layout without `studio-pose/` or `animation-assets/` is visible in
    /// automated runs too. A selection in effect reports its own companions in
    /// `convertedLibraryReport()`.
    static func companionGapReport() -> [String] {
        let override = ProcessInfo.processInfo.environment["IKKOKU_SOURCE_AVATAR"]
        guard override != nil || selectedManifest(.femaleBase) == nil,
              let manifest = effectiveManifest(.femaleBase), FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        return ResourceCompanion.allCases.filter { $0.owner == .femaleBase }.compactMap { companion in
            let url = companion.url(besideManifest: manifest)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue { return nil }
            return "converted layout gap: no \(companion.label) at \(url.path) beside \(manifest.path): \(companion.consequence)"
        }
    }

    /// The selected converted library's manifest of `kind`, when the selection has one.
    private static func selectedManifest(_ kind: ResourceLibraryKind) -> URL? {
        guard let record = selectedConvertedLibrary?.library(kind) else { return nil }
        return URL(fileURLWithPath: record.root).appendingPathComponent(record.manifest)
    }

    /// The manifest each converted lookup reads, in the lookups' own order:
    /// explicit variable, selected converted library, source-tree default.
    private static func effectiveManifest(_ kind: ResourceLibraryKind) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let override: String?
        switch kind {
        case .assets: return nil
        case .makerLibrary: override = env["IKKOKU_MAKER_LIBRARY"]
        case .femaleBase: override = env["IKKOKU_SOURCE_AVATAR"]
        case .maleBase: override = env["IKKOKU_SOURCE_MALE_AVATAR"]
        }
        if let override {
            guard !(kind == .makerLibrary && override == "none") else { return nil }
            return URL(fileURLWithPath: override)
        }
        if let selected = selectedManifest(kind) { return selected }
        guard sourceTreeFallbacksEnabled else { return nil }
        return sourceTreeRoot.appendingPathComponent(".local/reverse").appendingPathComponent(kind.conventionalManifest)
    }

    /// The libraries in effect now, each identified by its manifest digest: the
    /// asset root and the converted libraries the lookups below would read. A
    /// library whose manifest is missing or invalid is left out, so references
    /// into it stay unresolved instead of relocating. Saves record their file
    /// references against this; loads relocate against it.
    func libraryLocation() -> ResourceLibraryLocation {
        var records: [ResourceLibraryRecord] = []
        if let assets = try? ResourceLibraryRecord.inspect(kind: .assets, root: assetsRoot) { records.append(assets) }
        for kind in ResourceLibraryKind.converted {
            guard let manifest = Self.effectiveManifest(kind),
                  let record = try? ResourceLibraryRecord.inspect(kind: kind, manifestFile: manifest) else { continue }
            records.append(record)
        }
        return ResourceLibraryLocation(libraries: records)
    }

    /// Source-tree development defaults (T-T02). Without an explicit variable, three lookups
    /// fall back to paths inside the checkout this binary was compiled from (`#filePath`):
    /// its `Assets/` when the bundle has no `catalog.json`, and the git-ignored
    /// `.local/reverse/` Maker library and original male/female bases. Those paths exist only
    /// on the build machine, where a moved or installed app would still silently find them.
    /// `IKKOKU_SOURCE_TREE_FALLBACKS=0` turns all three off, so a launch shows whether the
    /// bundle alone supplies its resources; unset or any other value keeps the defaults.
    /// Explicit `IKKOKU_ASSETS`, `IKKOKU_MAKER_LIBRARY` and `IKKOKU_SOURCE_*AVATAR` values are
    /// not fallbacks and still apply, and so does a selected converted library (A-T02),
    /// which the Maker library and base lookups read before their fallbacks. Each
    /// fallback that is used prints a `[ikkoku] source-tree fallback:` line.
    static var sourceTreeFallbacksEnabled: Bool {
        ProcessInfo.processInfo.environment["IKKOKU_SOURCE_TREE_FALLBACKS"] != "0"
    }

    /// The checkout this binary was compiled from: Apps/IkkokuCreator/EngineHost.swift → repo root.
    private static var sourceTreeRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Asset root: $IKKOKU_ASSETS, else the app bundle, else the source tree (development;
    /// see `sourceTreeFallbacksEnabled`).
    static func locateAssets() -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["IKKOKU_ASSETS"], fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.resourceURL, fm.fileExists(atPath: res.appendingPathComponent("catalog.json").path) {
            return res
        }
        guard sourceTreeFallbacksEnabled else {
            print("[ikkoku] the app bundle has no catalog.json and IKKOKU_SOURCE_TREE_FALLBACKS=0 disables the source-tree assets")
            return Bundle.main.resourceURL ?? Bundle.main.bundleURL
        }
        let assets = sourceTreeRoot.appendingPathComponent("Assets")
        print("[ikkoku] source-tree fallback: assets root \(assets.path) (the app bundle has no catalog.json)")
        return assets
    }

    /// Maker library: $IKKOKU_MAKER_LIBRARY ("none" disables it), else the selected
    /// converted library's (A-T02; a selected library that fails to load is an
    /// error, not a fallback), else the source-tree default.
    static func locateMakerLibrary() throws -> SourceMakerLibrary? {
        let override = ProcessInfo.processInfo.environment["IKKOKU_MAKER_LIBRARY"]
        if override == "none" { return nil }
        if let override { return try loadMakerLibrary(url: URL(fileURLWithPath: override)) }
        if let selected = selectedManifest(.makerLibrary) { return try loadMakerLibrary(url: selected) }
        guard sourceTreeFallbacksEnabled else { return nil }
        let url = sourceTreeRoot.appendingPathComponent(".local/reverse/maker-library/library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        print("[ikkoku] source-tree fallback: Maker library \(url.path)")
        return try loadMakerLibrary(url: url)
    }

    /// The last Maker library decoded, by its file (R7 phase 2, item 7). Every
    /// source rehydration and Maker rebuild asks for the library, and decoding
    /// and checking its JSON again took ~3.7 ms each time. A file whose resolved
    /// path, size or modification date changed decodes again; a failure is
    /// never kept.
    private static var makerLibraryCache: (file: MakerLibraryFile, library: SourceMakerLibrary)?
    private struct MakerLibraryFile: Equatable {
        let path: String, size: UInt64, modified: Date
    }

    private static func loadMakerLibrary(url: URL) throws -> SourceMakerLibrary {
        let path = url.resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let file = attributes.flatMap { attributes -> MakerLibraryFile? in
            guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return MakerLibraryFile(path: path, size: size, modified: modified)
        }
        if let file, let cached = makerLibraryCache, cached.file == file { return cached.library }
        let library = try SourceMakerLibrary.load(url: url)
        makerLibraryCache = file.map { ($0, library) }
        return library
    }

    /// A cheap configuration snapshot for asynchronous preparation. Unlike
    /// `locateSourceAvatar`, this performs no filesystem validation or decoding.
    static func sourceAvatarCandidateURL(sex: Sex) -> URL? {
        effectiveManifest(sex == .male ? .maleBase : .femaleBase)
    }

    /// Original data is local and optional. An explicit override, or the base of the
    /// selected converted library (A-T02), must be valid; the development default
    /// is available only after its appearance is ready.
    static func locateSourceAvatar(sex: Sex = .female) throws -> URL? {
        let fm = FileManager.default
        let variable = sex == .male ? "IKKOKU_SOURCE_MALE_AVATAR" : "IKKOKU_SOURCE_AVATAR"
        let override = ProcessInfo.processInfo.environment[variable]
        let url: URL
        let fallback: Bool
        if let override {
            guard !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineHostError.invalidSourceAvatar("\(variable) is empty.")
            }
            url = URL(fileURLWithPath: override).standardizedFileURL
            fallback = false
        } else if let selected = selectedManifest(sex == .male ? .maleBase : .femaleBase) {
            url = selected.standardizedFileURL
            fallback = false
        } else {
            guard sourceTreeFallbacksEnabled else { return nil }
            url = sourceTreeRoot.appendingPathComponent(sex == .male ? ".local/reverse/male/source-male-avatar.json" : ".local/reverse/rigs/source-avatar.json")
            fallback = true
        }
        let appearance = url.deletingPathExtension().appendingPathExtension("appearance.json")
        for file in [url, appearance] {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue else {
                if fallback { return nil }
                throw EngineHostError.invalidSourceAvatar("Original base file is missing: \(file.path)")
            }
        }
        struct Header: Decodable { let schemaVersion: Int; let kind: String? }
        let header = try JSONDecoder().decode(Header.self, from: Data(contentsOf: url))
        guard header.schemaVersion == 1, header.kind == (sex == .male ? "koikatsu-male-avatar" : "koikatsu-female-avatar") else {
            throw EngineHostError.invalidSourceAvatar("Original base must be a supported \(sex == .male ? "male" : "female") avatar manifest: \(url.path)")
        }
        if fallback { print("[ikkoku] source-tree fallback: original base \(url.path)") }
        // The complete hierarchy, palette and appearance validation happens in
        // openSourceRig before it replaces the current character.
        return url
    }
}
