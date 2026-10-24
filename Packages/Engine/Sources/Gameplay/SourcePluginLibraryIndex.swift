import Foundation
import CryptoKit

// P-T02: one dependency graph for translated IR packages and native behavior
// adapters, plus the reader for the immutable numbered generations written by
// Tools/translation/plugin_library.py. Format, selection and dependency policy:
// docs/reference/mods/plugin-execution.md ("Plugin library").

/// Explicit failures that name the identities involved. None of them is
/// recovered by choosing another revision, a newer version or another generation.
public enum SourcePluginLibraryError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidLibrary(String)
    case generationUnavailable(Int)
    case generationChanged(Int)
    case selectionMismatch(String)
    case unknownGUID(guid: String, generation: Int)
    case unresolvedConflict(guid: String, manifestSHA256s: [String])
    case choiceUnavailable(guid: String, manifestSHA256: String, generation: Int)
    case revisionUnavailable(guid: String, version: String, manifestSHA256: String, generation: Int)
    case revisionChanged(guid: String, version: String, manifestSHA256: String)
    case revisionInvalid(guid: String, manifestSHA256: String, reason: String)
    case tooManyPlugins(Int)
    case duplicateGUID(String)
    case processMismatch(guid: String, process: String)
    case invalidVersion(guid: String, version: String)
    case missingDependency(guid: String, dependency: String)
    case dependencyTooOld(guid: String, dependency: String, minimum: String, found: String)
    case incompatible(guid: String, other: String)
    case cycle([String])

    public var description: String {
        switch self {
        case .invalidLibrary(let reason): return "Invalid plugin library: \(reason)"
        case .generationUnavailable(let number): return "Plugin library generation \(number) is not published or its index is missing."
        case .generationChanged(let number): return "Plugin library generation \(number) changed after publication."
        case .selectionMismatch(let reason): return "Plugin library selection does not match: \(reason)"
        case .unknownGUID(let guid, let generation): return "No revision of plugin \(guid) exists in generation \(generation)."
        case .unresolvedConflict(let guid, let hashes):
            return "Plugin \(guid) has \(hashes.count) revisions (\(hashes.joined(separator: ", "))); choose one manifest SHA-256 explicitly."
        case .choiceUnavailable(let guid, let hash, let generation): return "Chosen revision \(hash) of plugin \(guid) is not in generation \(generation)."
        case .revisionUnavailable(let guid, let version, let hash, let generation):
            return "Plugin revision \(guid) \(version) (\(hash)) is unavailable in generation \(generation)."
        case .revisionChanged(let guid, let version, let hash): return "Plugin revision \(guid) \(version) (\(hash)) differs from its library record."
        case .revisionInvalid(let guid, let hash, let reason): return "Plugin revision \(guid) (\(hash)) failed verification: \(reason)"
        case .tooManyPlugins(let count): return "Too many plugin packages: \(count)."
        case .duplicateGUID(let guid): return "Duplicate mounted plugin GUID: \(guid)."
        case .processMismatch(let guid, let process): return "Plugin \(guid) does not target \(process)."
        case .invalidVersion(let guid, let version): return "Plugin \(guid) declares version '\(version)', which is not a 2-4 component numeric .NET version."
        case .missingDependency(let guid, let dependency): return "Missing plugin dependency: \(guid) requires \(dependency)."
        case .dependencyTooOld(let guid, let dependency, let minimum, let found):
            return "Dependency version is too old: \(guid) requires \(dependency) \(minimum), found \(found)."
        case .incompatible(let guid, let other): return "Plugin incompatibility: \(guid) / \(other)."
        case .cycle(let guids): return "Plugin dependency cycle: \(guids.joined(separator: " -> "))."
        }
    }
}

/// BepInEx-style metadata of mounted packages of either kind, ordered as one
/// graph. GUIDs compare by their UTF-8 bytes, never by Swift's canonical String
/// equality, so canonically equivalent Unicode GUIDs remain distinct.
public enum SourcePluginGraph {
    public enum Kind: String, Codable, Sendable {
        case translated = "ikkoku-translated-plugin"
        case nativeAdapter = "ikkoku-native-plugin-adapter"
    }
    public struct Dependency: Codable, Sendable {
        public let guid: String, minimumVersion: String?, required: Bool
        public init(guid: String, minimumVersion: String? = nil, required: Bool) {
            self.guid = guid; self.minimumVersion = minimumVersion; self.required = required
        }
    }
    public struct Node: Sendable {
        public let kind: Kind, guid: String, version: String
        public let processes: [String], dependencies: [Dependency], incompatibilities: [String]
        public init(kind: Kind, guid: String, version: String, processes: [String] = [],
                    dependencies: [Dependency] = [], incompatibilities: [String] = []) {
            self.kind = kind; self.guid = guid; self.version = version; self.processes = processes
            self.dependencies = dependencies; self.incompatibilities = incompatibilities
        }
        public var ordinalGUID: Data { Data(guid.utf8) }
    }
    public static let maximumNodes = 256

    /// Strict System.Version subset: 2-4 dot-separated ASCII decimal Int32
    /// parts. Whitespace, signs, prefixes and suffixes are rejected even where
    /// a .NET parser may accept them, so an unclear version fails explicitly.
    public static func parseVersion(_ text: String) -> [UInt32]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        var values: [UInt32] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt32(part), value <= UInt32(Int32.max) else { return nil }
            values.append(value)
        }
        return values
    }

    /// .NET Version ordering: an absent build/revision compares as -1, so 1.0 < 1.0.0.
    public static func meets(_ actual: [UInt32], minimum: [UInt32]) -> Bool {
        for i in 0..<4 {
            let x = i < actual.count ? Int64(actual[i]) : -1, y = i < minimum.count ? Int64(minimum[i]) : -1
            if x != y { return x > y }
        }
        return true
    }

    /// The installed Chainloader removes literal lowercase ".exe" occurrences
    /// before its invariant case-insensitive comparison.
    public static func targets(_ processes: [String], process: String) -> Bool {
        processes.isEmpty || processes.contains(where: {
            $0.replacingOccurrences(of: ".exe", with: "").compare(process, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        })
    }

    /// Indices of `nodes` in deterministic dependency order: requested order,
    /// each dependency (hard or present soft) first, in declared order.
    public static func order(_ nodes: [Node], process: String) throws -> [Int] {
        guard nodes.count <= maximumNodes else { throw SourcePluginLibraryError.tooManyPlugins(nodes.count) }
        var byID: [Data: Int] = [:]
        for (index, node) in nodes.enumerated() {
            guard byID.updateValue(index, forKey: node.ordinalGUID) == nil else { throw SourcePluginLibraryError.duplicateGUID(node.guid) }
            guard targets(node.processes, process: process) else { throw SourcePluginLibraryError.processMismatch(guid: node.guid, process: process) }
        }
        // Standalone validation: every declared version and minimum must parse,
        // whether or not another package ever compares it.
        for node in nodes {
            guard parseVersion(node.version) != nil else { throw SourcePluginLibraryError.invalidVersion(guid: node.guid, version: node.version) }
            for dependency in node.dependencies {
                if let minimum = dependency.minimumVersion, parseVersion(minimum) == nil {
                    throw SourcePluginLibraryError.invalidVersion(guid: node.guid, version: minimum)
                }
            }
        }
        var ordered: [Int] = [], visited = Set<Data>(), path: [Int] = []
        func visit(_ index: Int) throws {
            let node = nodes[index], id = node.ordinalGUID
            if visited.contains(id) { return }
            if let start = path.firstIndex(where: { nodes[$0].ordinalGUID == id }) {
                throw SourcePluginLibraryError.cycle((Array(path[start...]) + [index]).map { nodes[$0].guid })
            }
            path.append(index)
            for incompatible in node.incompatibilities where byID[Data(incompatible.utf8)] != nil {
                throw SourcePluginLibraryError.incompatible(guid: node.guid, other: incompatible)
            }
            for dependency in node.dependencies {
                guard let target = byID[Data(dependency.guid.utf8)] else {
                    if dependency.required { throw SourcePluginLibraryError.missingDependency(guid: node.guid, dependency: dependency.guid) }
                    continue
                }
                // An outdated soft dependency does not prevent loading.
                if dependency.required, let minimum = dependency.minimumVersion, let wanted = parseVersion(minimum),
                   let found = parseVersion(nodes[target].version), !meets(found, minimum: wanted) {
                    throw SourcePluginLibraryError.dependencyTooOld(guid: node.guid, dependency: dependency.guid,
                                                                    minimum: minimum, found: nodes[target].version)
                }
                try visit(target)
            }
            path.removeLast()
            visited.insert(id); ordered.append(index)
        }
        for index in nodes.indices { try visit(index) }
        return ordered
    }
}

extension SourcePluginGraph.Node {
    public init(package: SourcePluginPackage) {
        let manifest = package.manifest
        self.init(kind: .translated, guid: manifest.identity.guid, version: manifest.identity.version, processes: manifest.processes,
                  dependencies: manifest.dependencies.map { SourcePluginGraph.Dependency(guid: $0.guid, minimumVersion: $0.minimumVersion, required: $0.required) },
                  incompatibilities: manifest.incompatibilities)
    }
    /// Exact adapters have no declared dependencies; incompatibilities are
    /// preserved when present (older two-adapter manifests omitted the field).
    public init(nativeAdapter package: SourceNativePluginPackage) {
        self.init(kind: .nativeAdapter, guid: package.manifest.identity.guid, version: package.manifest.identity.version,
                  processes: package.manifest.processes, incompatibilities: package.manifest.incompatibilities ?? [])
    }
}

private enum LibraryFiles {
    static let indexLimit = 32 * 1024 * 1024
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw SourcePluginLibraryError.invalidLibrary("\(url.lastPathComponent) exceeds \(maximum) bytes.") }
        return bytes
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isHash(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func bounded(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 1024 }
    static func same(_ a: [String], _ b: [String]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) } }
    static func same(_ a: [SourcePluginGraph.Dependency], _ b: [SourcePluginGraph.Dependency]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let xMinimum = x.minimumVersion.map { Array($0.utf8) }, yMinimum = y.minimumVersion.map { Array($0.utf8) }
            guard x.guid.utf8.elementsEqual(y.guid.utf8), x.required == y.required, xMinimum == yMinimum else { return false }
        }
        return true
    }
    /// Matches the scanner's `generations/%06d.json` naming.
    static func generationPath(_ number: Int) -> String {
        let digits = String(number)
        return "generations/" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits + ".json"
    }
    /// Existence is checked before symlink resolution, so a missing file
    /// reports `missing` (naming its identity) rather than a path error.
    static func contained(_ relative: String, in directory: URL, missing: SourcePluginLibraryError) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SourcePluginLibraryError.invalidLibrary("Library path is not canonical: \(relative)")
        }
        let candidate = directory.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: candidate.path) else { throw missing }
        let url = candidate.resolvingSymlinksInPath()
        guard url.path.hasPrefix(directory.path + "/") else { throw SourcePluginLibraryError.invalidLibrary("Library path escapes the library: \(relative)") }
        return url
    }
}

/// One published generation of an immutable plugin library. `library.json`
/// lists every generation with the SHA-256 of its index; generation indexes and
/// `revisions/<manifestSHA256>/` directories are never rewritten.
public struct SourcePluginLibraryIndex: Sendable {
    public struct Source: Codable, Sendable { public let rootID: String, relativePath: String }
    public struct Revision: Codable, Sendable {
        public let kind: SourcePluginGraph.Kind
        public let guid: String, version: String, name: String
        public let manifest: String, manifestSHA256: String, packageSHA256: String
        public let processes: [String], dependencies: [SourcePluginGraph.Dependency], incompatibilities: [String]
        public let types: [String], converter: [String: String], sources: [Source]
        public var node: SourcePluginGraph.Node {
            .init(kind: kind, guid: guid, version: version, processes: processes, dependencies: dependencies, incompatibilities: incompatibilities)
        }
        public var selection: SourcePluginLibrarySelection.Revision {
            .init(kind: kind, guid: guid, version: version, manifestSHA256: manifestSHA256)
        }
    }
    public struct Conflict: Codable, Sendable { public let guid: String, manifestSHA256s: [String] }
    private struct Record: Decodable { let number: Int, index: String, indexSHA256: String }
    private struct Pointer: Decodable { let schemaVersion: Int, kind: String, current: Int, generations: [Record] }
    private struct Generation: Decodable { let schemaVersion: Int, kind: String, number: Int, revisions: [Revision], conflicts: [Conflict] }

    /// The resolved `library.json` URL and its directory.
    public let libraryURL: URL, directoryURL: URL
    /// Newest published generation, and the generation this index describes.
    public let current: Int, generation: Int, generationSHA256: String
    public let revisions: [Revision], conflicts: [Conflict]

    private init(libraryURL: URL, directoryURL: URL, current: Int, generation: Int, generationSHA256: String,
                 revisions: [Revision], conflicts: [Conflict]) {
        self.libraryURL = libraryURL; self.directoryURL = directoryURL; self.current = current
        self.generation = generation; self.generationSHA256 = generationSHA256
        self.revisions = revisions; self.conflicts = conflicts
    }

    /// Loads `generation` (default: the current one) from `library.json` after
    /// checking its recorded index hash and the recorded duplicate-GUID conflicts.
    public static func load(libraryURL: URL, generation requested: Int? = nil) throws -> Self {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            throw SourcePluginLibraryError.invalidLibrary("Plugin library index is missing: \(libraryURL.path)")
        }
        let url = libraryURL.resolvingSymlinksInPath()
        let directory = url.deletingLastPathComponent()
        let decoder = JSONDecoder()
        let pointer: Pointer
        do { pointer = try decoder.decode(Pointer.self, from: LibraryFiles.read(url, maximum: LibraryFiles.indexLimit)) }
        catch let error as DecodingError { throw SourcePluginLibraryError.invalidLibrary("library.json: \(error)") }
        guard pointer.schemaVersion == 1, pointer.kind == "ikkoku-plugin-library", !pointer.generations.isEmpty,
              pointer.generations.count <= 100_000 else { throw SourcePluginLibraryError.invalidLibrary("Unsupported plugin library index.") }
        var newest = 0
        for record in pointer.generations {
            guard record.number > newest, record.index == LibraryFiles.generationPath(record.number), LibraryFiles.isHash(record.indexSHA256) else {
                throw SourcePluginLibraryError.invalidLibrary("Generation records are not strictly numbered.")
            }
            newest = record.number
        }
        guard pointer.current == newest else { throw SourcePluginLibraryError.invalidLibrary("Current generation is not the newest published one.") }
        let number = requested ?? pointer.current
        guard let record = pointer.generations.first(where: { $0.number == number }) else { throw SourcePluginLibraryError.generationUnavailable(number) }
        let generationURL = try LibraryFiles.contained(record.index, in: directory, missing: .generationUnavailable(number))
        let data = try LibraryFiles.read(generationURL, maximum: LibraryFiles.indexLimit), hash = LibraryFiles.sha256(data)
        guard hash == record.indexSHA256 else { throw SourcePluginLibraryError.generationChanged(number) }
        let document: Generation
        do { document = try decoder.decode(Generation.self, from: data) }
        catch let error as DecodingError { throw SourcePluginLibraryError.invalidLibrary("Generation \(number): \(error)") }
        guard document.schemaVersion == 1, document.kind == "ikkoku-plugin-generation", document.number == number,
              document.revisions.count <= 4096 else { throw SourcePluginLibraryError.invalidLibrary("Unsupported plugin generation \(number).") }
        var manifests = Set<String>(), groups: [Data: [String]] = [:]
        for revision in document.revisions {
            guard LibraryFiles.isHash(revision.manifestSHA256), LibraryFiles.isHash(revision.packageSHA256),
                  manifests.insert(revision.manifestSHA256).inserted,
                  revision.manifest == "revisions/\(revision.manifestSHA256)/manifest.json",
                  [revision.guid, revision.version, revision.name].allSatisfy(LibraryFiles.bounded),
                  !revision.types.isEmpty, revision.types.allSatisfy(LibraryFiles.bounded),
                  revision.kind == .translated || (revision.dependencies.isEmpty && revision.types.count == 1) else {
                throw SourcePluginLibraryError.invalidLibrary("Generation \(number) has an invalid or duplicate revision record.")
            }
            groups[Data(revision.guid.utf8), default: []].append(revision.manifestSHA256)
        }
        let duplicated = groups.filter { $0.value.count > 1 }
        guard Set(document.conflicts.map { Data($0.guid.utf8) }).count == document.conflicts.count,
              document.conflicts.count == duplicated.count,
              document.conflicts.allSatisfy({ duplicated[Data($0.guid.utf8)]?.sorted() == $0.manifestSHA256s }) else {
            throw SourcePluginLibraryError.invalidLibrary("Generation \(number) conflicts differ from its revisions.")
        }
        return Self(libraryURL: url, directoryURL: directory, current: pointer.current, generation: number,
                    generationSHA256: hash, revisions: document.revisions, conflicts: document.conflicts)
    }

    /// Exact revisions of `guids` in this generation. A GUID with several
    /// revisions needs an explicit manifest SHA-256 choice; no version string
    /// or position decides it. The result is validated by `resolve`.
    public func select(guids: [String], choosing choices: [(guid: String, manifestSHA256: String)] = [],
                       process: String = "CharaStudio") throws -> SourcePluginLibrarySelection {
        var requested = Set<Data>(), explicit: [Data: String] = [:]
        for guid in guids { guard requested.insert(Data(guid.utf8)).inserted else { throw SourcePluginLibraryError.duplicateGUID(guid) } }
        for choice in choices {
            let id = Data(choice.guid.utf8)
            guard requested.contains(id), explicit.updateValue(choice.manifestSHA256, forKey: id) == nil else {
                throw SourcePluginLibraryError.selectionMismatch("Choice for \(choice.guid) is duplicated or names an unrequested GUID.")
            }
        }
        var picked: [SourcePluginLibrarySelection.Revision] = []
        for guid in guids {
            let id = Data(guid.utf8)
            let candidates = revisions.filter { Data($0.guid.utf8) == id }
            guard !candidates.isEmpty else { throw SourcePluginLibraryError.unknownGUID(guid: guid, generation: generation) }
            let revision: Revision
            if let hash = explicit[id] {
                guard let match = candidates.first(where: { $0.manifestSHA256 == hash }) else {
                    throw SourcePluginLibraryError.choiceUnavailable(guid: guid, manifestSHA256: hash, generation: generation)
                }
                revision = match
            } else {
                guard candidates.count == 1 else {
                    throw SourcePluginLibraryError.unresolvedConflict(guid: guid, manifestSHA256s: candidates.map(\.manifestSHA256).sorted())
                }
                revision = candidates[0]
            }
            picked.append(revision.selection)
        }
        let selection = SourcePluginLibrarySelection(libraryFile: libraryURL.path, generation: generation,
                                                     generationSHA256: generationSHA256, process: process, revisions: picked)
        _ = try resolve(selection)
        return selection
    }

    /// The selected revisions in dependency order, from this generation's
    /// records alone. A selection made against another generation, or naming a
    /// revision this generation lacks, fails instead of being remapped.
    public func resolve(_ selection: SourcePluginLibrarySelection) throws -> [Revision] {
        guard selection.schemaVersion == 1 else { throw SourcePluginLibraryError.selectionMismatch("Unsupported selection schema \(selection.schemaVersion).") }
        guard selection.generation == generation else {
            throw SourcePluginLibraryError.selectionMismatch("Selection names generation \(selection.generation); this index is generation \(generation).")
        }
        guard selection.generationSHA256 == generationSHA256 else { throw SourcePluginLibraryError.generationChanged(generation) }
        var chosen: [Revision] = [], seen = Set<Data>()
        for wanted in selection.revisions {
            guard seen.insert(Data(wanted.guid.utf8)).inserted else { throw SourcePluginLibraryError.duplicateGUID(wanted.guid) }
            guard let revision = revisions.first(where: { $0.manifestSHA256 == wanted.manifestSHA256 }) else {
                throw SourcePluginLibraryError.revisionUnavailable(guid: wanted.guid, version: wanted.version,
                                                                   manifestSHA256: wanted.manifestSHA256, generation: generation)
            }
            guard revision.kind == wanted.kind, revision.guid.utf8.elementsEqual(wanted.guid.utf8),
                  revision.version.utf8.elementsEqual(wanted.version.utf8) else {
                throw SourcePluginLibraryError.revisionChanged(guid: wanted.guid, version: wanted.version, manifestSHA256: wanted.manifestSHA256)
            }
            chosen.append(revision)
        }
        return try SourcePluginGraph.order(chosen.map(\.node), process: selection.process).map { chosen[$0] }
    }

    /// Resolves the selection, then verifies every package's bytes against its record.
    public func load(_ selection: SourcePluginLibrarySelection) throws -> SourcePluginLibraryResolution {
        let order = try resolve(selection)
        var packages: [SourcePluginLibraryResolution.Package] = []
        for revision in order {
            switch revision.kind {
            case .translated: try packages.append(.translated(loadTranslated(revision)))
            case .nativeAdapter: try packages.append(.nativeAdapter(loadNativeAdapter(revision)))
            }
        }
        return SourcePluginLibraryResolution(selection: selection, generation: generation, order: order, packages: packages)
    }

    public func manifestURL(_ revision: Revision) throws -> URL {
        try LibraryFiles.contained(revision.manifest, in: directoryURL,
            missing: .revisionUnavailable(guid: revision.guid, version: revision.version, manifestSHA256: revision.manifestSHA256, generation: generation))
    }

    /// Loads an IR revision; the manifest hash, identity, metadata and converter
    /// hashes must equal the generation record.
    public func loadTranslated(_ revision: Revision) throws -> SourcePluginPackage {
        let changed = SourcePluginLibraryError.revisionChanged(guid: revision.guid, version: revision.version, manifestSHA256: revision.manifestSHA256)
        guard revision.kind == .translated else { throw changed }
        let url = try manifestURL(revision)
        let package: SourcePluginPackage
        do { package = try SourcePluginPackage.load(url: url) }
        catch { throw SourcePluginLibraryError.revisionInvalid(guid: revision.guid, manifestSHA256: revision.manifestSHA256, reason: "\(error)") }
        let manifest = package.manifest
        let dependencies = manifest.dependencies.map { SourcePluginGraph.Dependency(guid: $0.guid, minimumVersion: $0.minimumVersion, required: $0.required) }
        let recorded = ["emitterSHA256", "bridgeSHA256", "semanticSurfaceSHA256"].map { revision.converter[$0] ?? "" }
        let converted = package.programs.allSatisfy { [$0.emitterSHA256, $0.bridgeSHA256, $0.semanticSurfaceSHA256] == recorded }
        guard LibraryFiles.sha256(package.manifestData) == revision.manifestSHA256, converted,
              manifest.identity.guid.utf8.elementsEqual(revision.guid.utf8), manifest.identity.version.utf8.elementsEqual(revision.version.utf8),
              manifest.identity.name.utf8.elementsEqual(revision.name.utf8), LibraryFiles.same(manifest.processes, revision.processes),
              LibraryFiles.same(manifest.incompatibilities, revision.incompatibilities), LibraryFiles.same(dependencies, revision.dependencies),
              LibraryFiles.same(manifest.components.map(\.type), revision.types) else {
            throw changed
        }
        return package
    }

    /// Loads an adapter revision through the exact original-assembly checks of
    /// `SourceNativePluginPackage`; its identity must equal the generation record.
    public func loadNativeAdapter(_ revision: Revision) throws -> SourceNativePluginPackage {
        let changed = SourcePluginLibraryError.revisionChanged(guid: revision.guid, version: revision.version, manifestSHA256: revision.manifestSHA256)
        guard revision.kind == .nativeAdapter else { throw changed }
        let url = try manifestURL(revision)
        let package: SourceNativePluginPackage
        do { package = try SourceNativePluginPackage.load(url: url) }
        catch { throw SourcePluginLibraryError.revisionInvalid(guid: revision.guid, manifestSHA256: revision.manifestSHA256, reason: "\(error)") }
        let manifest = package.manifest
        guard package.manifestSHA256 == revision.manifestSHA256,
              manifest.identity.guid.utf8.elementsEqual(revision.guid.utf8), manifest.identity.version.utf8.elementsEqual(revision.version.utf8),
              manifest.identity.name.utf8.elementsEqual(revision.name.utf8), LibraryFiles.same(manifest.processes, revision.processes),
              LibraryFiles.same(manifest.incompatibilities ?? [], revision.incompatibilities), revision.dependencies.isEmpty,
              LibraryFiles.same([manifest.type], revision.types), revision.converter["adapterID"] == manifest.adapterID else {
            throw changed
        }
        return package
    }
}

/// Exact revisions recorded in a native scene. It always resolves against its
/// recorded generation, so publishing a newer generation never changes it;
/// upgrading is a new explicit `select` against the newer generation.
public struct SourcePluginLibrarySelection: Codable, Sendable, Equatable {
    public struct Revision: Codable, Sendable, Equatable {
        public let kind: SourcePluginGraph.Kind, guid: String, version: String, manifestSHA256: String
        public init(kind: SourcePluginGraph.Kind, guid: String, version: String, manifestSHA256: String) {
            self.kind = kind; self.guid = guid; self.version = version; self.manifestSHA256 = manifestSHA256
        }
    }
    public let schemaVersion: Int
    public let libraryFile: String, generation: Int, generationSHA256: String, process: String
    public let revisions: [Revision]
    public init(libraryFile: String, generation: Int, generationSHA256: String, process: String = "CharaStudio", revisions: [Revision]) {
        schemaVersion = 1; self.libraryFile = libraryFile; self.generation = generation
        self.generationSHA256 = generationSHA256; self.process = process; self.revisions = revisions
    }
    /// Loads the recorded generation and verifies every selected package.
    public func resolve() throws -> SourcePluginLibraryResolution {
        try SourcePluginLibraryIndex.load(libraryURL: URL(fileURLWithPath: libraryFile), generation: generation).load(self)
    }
}

/// Verified packages of a selection in dependency order.
public struct SourcePluginLibraryResolution: Sendable {
    public enum Package: Sendable {
        case translated(SourcePluginPackage), nativeAdapter(SourceNativePluginPackage)
    }
    public let selection: SourcePluginLibrarySelection
    public let generation: Int
    public let order: [SourcePluginLibraryIndex.Revision]
    public let packages: [Package]
    public var translated: [SourcePluginPackage] {
        packages.compactMap { package -> SourcePluginPackage? in
            if case .translated(let value) = package { return value }
            return nil
        }
    }
    public var nativeAdapters: [SourceNativePluginPackage] {
        packages.compactMap { package -> SourceNativePluginPackage? in
            if case .nativeAdapter(let value) = package { return value }
            return nil
        }
    }
}
