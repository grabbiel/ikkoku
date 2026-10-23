import Foundation
import CryptoKit

// A-T02: the libraries the app reads bundled or converted content from, as a
// versioned, Codable record. A library is identified by the SHA-256 of its manifest
// (with the manifest's own format version), not by its path, so a moved copy of the
// same content is recognised as the same library. Saved documents bind their file
// references to these records and are relocated against them in
// ResourceRelocation.swift. Contract: docs/reference/native-assets.md
// ("Library location and relocation").

/// The kinds of library a location can name.
public enum ResourceLibraryKind: String, Codable, Sendable, CaseIterable {
    /// The native asset root: `catalog.json` (`version`) and its catalog-relative files.
    case assets
    /// A converted Maker library: `library.json` (`schemaVersion` 1), whose entries
    /// carry their own SHA-256s (`SourceMakerLibrary`).
    case makerLibrary
    /// An original female base: an avatar manifest of kind `koikatsu-female-avatar`.
    case femaleBase
    /// An original male base: an avatar manifest of kind `koikatsu-male-avatar`.
    case maleBase

    /// The manifest's path inside a library root. For the converted kinds this is the
    /// layout the `Tools/reverse` exporters write under `.local/reverse/`, which a
    /// user-selected converted library root keeps; the asset root holds its catalog.
    public var conventionalManifest: String {
        switch self {
        case .assets: return "catalog.json"
        case .makerLibrary: return "maker-library/library.json"
        case .femaleBase: return "rigs/source-avatar.json"
        case .maleBase: return "male/source-male-avatar.json"
        }
    }

    /// The kinds a user-selected converted library root can hold.
    public static let converted: [ResourceLibraryKind] = [.makerLibrary, .femaleBase, .maleBase]

    /// `SourceMakerLibrary.load` reads at most 16 MiB; the other manifests are small
    /// JSON headers, bounded so a wrong file cannot exhaust memory.
    var maximumManifestBytes: Int { self == .makerLibrary ? 16 * 1024 * 1024 : 64 * 1024 * 1024 }

    var label: String {
        switch self {
        case .assets: return "asset library"
        case .makerLibrary: return "Maker library"
        case .femaleBase: return "original female base"
        case .maleBase: return "original male base"
        }
    }
}

/// Failures of the location model. Each names the kind and path involved; none is
/// recovered by choosing another library.
public enum ResourceLibraryError: Error, CustomStringConvertible, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidRecord(String)
    case duplicateKind(ResourceLibraryKind)
    case manifestMissing(kind: ResourceLibraryKind, path: String)
    case manifestEscapesRoot(kind: ResourceLibraryKind, manifest: String, root: String)
    case manifestTooLarge(kind: ResourceLibraryKind, path: String, limit: Int)
    case unsupportedManifest(kind: ResourceLibraryKind, path: String, reason: String)
    case noConvertedLibrary(root: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version): return "Library location record version \(version) is unsupported (expected \(ResourceLibraryLocation.currentVersion))."
        case .invalidRecord(let reason): return "Invalid library location record: \(reason)"
        case .duplicateKind(let kind): return "Library location names more than one \(kind.label)."
        case .manifestMissing(let kind, let path): return "The \(kind.label) manifest is missing: \(path)"
        case .manifestEscapesRoot(let kind, let manifest, let root): return "The \(kind.label) manifest '\(manifest)' resolves outside its library root \(root)."
        case .manifestTooLarge(let kind, let path, let limit): return "The \(kind.label) manifest exceeds \(limit) bytes: \(path)"
        case .unsupportedManifest(let kind, let path, let reason): return "Unsupported \(kind.label) manifest \(path): \(reason)"
        case .noConvertedLibrary(let root):
            let expected = ResourceLibraryKind.converted.map(\.conventionalManifest).joined(separator: ", ")
            return "No converted library was found in \(root); expected at least one of \(expected)."
        }
    }
}

/// One library: where it is and which content it is. Two records name the same
/// library content when kind, manifest path, manifest SHA-256 and format version
/// agree (`sameContent(as:)`); their roots may differ.
public struct ResourceLibraryRecord: Codable, Sendable, Equatable, Hashable {
    public var kind: ResourceLibraryKind
    /// Absolute library directory. In a document's `ResourceBinding` it is the
    /// realpath at save time; in a location it is the path as configured.
    public var root: String
    /// Root-relative manifest path: canonical, with no empty, `.` or `..` segment.
    public var manifest: String
    /// Lowercase hex SHA-256 of the manifest bytes: the library's content identity.
    public var manifestSHA256: String
    /// The manifest's own format version: `version` for the asset catalog,
    /// `schemaVersion` for the converted manifests.
    public var formatVersion: Int

    public init(kind: ResourceLibraryKind, root: String, manifest: String, manifestSHA256: String, formatVersion: Int) {
        self.kind = kind; self.root = root; self.manifest = manifest
        self.manifestSHA256 = manifestSHA256; self.formatVersion = formatVersion
    }

    public func sameContent(as other: ResourceLibraryRecord) -> Bool {
        kind == other.kind && manifest == other.manifest && manifestSHA256 == other.manifestSHA256 && formatVersion == other.formatVersion
    }

    /// Short identity for messages: kind, the first 12 digest characters and the version.
    public var identityDescription: String { "\(kind.label) \(manifestSHA256.prefix(12)) (format \(formatVersion))" }

    public func validate() throws {
        guard root.hasPrefix("/"), !root.contains("\0") else { throw ResourceLibraryError.invalidRecord("\(kind.label) root '\(root)' is not an absolute path.") }
        guard ResourcePath.isCanonicalRelative(manifest) else { throw ResourceLibraryError.invalidRecord("\(kind.label) manifest '\(manifest)' is not a canonical relative path.") }
        guard ResourceDigest.isSHA256(manifestSHA256) else { throw ResourceLibraryError.invalidRecord("\(kind.label) manifest digest is not a lowercase SHA-256.") }
    }

    /// Reads the manifest of a library rooted at `root` (default: the kind's
    /// conventional manifest), checks that it stays inside the root after symlinks,
    /// that it is the kind's format, and records its digest and version.
    public static func inspect(kind: ResourceLibraryKind, root: URL, manifest: String? = nil) throws -> ResourceLibraryRecord {
        let manifest = manifest ?? kind.conventionalManifest
        let rootPath = root.standardizedFileURL.path
        guard ResourcePath.isCanonicalRelative(manifest) else {
            throw ResourceLibraryError.manifestEscapesRoot(kind: kind, manifest: manifest, root: rootPath)
        }
        let url = root.appendingPathComponent(manifest)
        guard let canonicalRoot = ResourcePath.canonical(rootPath), let canonicalFile = ResourcePath.canonical(url.path),
              !ResourcePath.isDirectory(canonicalFile) else {
            throw ResourceLibraryError.manifestMissing(kind: kind, path: url.path)
        }
        guard ResourcePath.relative(canonicalFile, in: canonicalRoot) != nil else {
            throw ResourceLibraryError.manifestEscapesRoot(kind: kind, manifest: manifest, root: rootPath)
        }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: canonicalFile)); defer { try? input.close() }
        let data = try input.read(upToCount: kind.maximumManifestBytes + 1) ?? Data()
        guard data.count <= kind.maximumManifestBytes else {
            throw ResourceLibraryError.manifestTooLarge(kind: kind, path: url.path, limit: kind.maximumManifestBytes)
        }
        struct Header: Decodable { let version: Int?, schemaVersion: Int?, kind: String? }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch { throw ResourceLibraryError.unsupportedManifest(kind: kind, path: url.path, reason: "not a JSON object (\(error))") }
        let version: Int?
        switch kind {
        case .assets: version = header.version
        case .makerLibrary: version = header.schemaVersion == 1 ? 1 : nil
        case .femaleBase: version = header.schemaVersion == 1 && header.kind == "koikatsu-female-avatar" ? 1 : nil
        case .maleBase: version = header.schemaVersion == 1 && header.kind == "koikatsu-male-avatar" ? 1 : nil
        }
        guard let version else {
            let expected: String
            switch kind {
            case .assets: expected = "a catalog with an integer version"
            case .makerLibrary: expected = "schemaVersion 1"
            case .femaleBase: expected = "schemaVersion 1 and kind koikatsu-female-avatar"
            case .maleBase: expected = "schemaVersion 1 and kind koikatsu-male-avatar"
            }
            throw ResourceLibraryError.unsupportedManifest(kind: kind, path: url.path, reason: "expected \(expected)")
        }
        return ResourceLibraryRecord(kind: kind, root: rootPath, manifest: manifest,
                                     manifestSHA256: ResourceDigest.sha256(data), formatVersion: version)
    }

    /// Inspects the library an explicit manifest file belongs to (an `IKKOKU_*`
    /// override). When the file sits at the kind's conventional path inside a
    /// directory, that directory is the root, so a library given by its manifest
    /// and the same library selected by its root record identical roots.
    /// Otherwise the manifest's own directory is the root.
    public static func inspect(kind: ResourceLibraryKind, manifestFile: URL) throws -> ResourceLibraryRecord {
        let path = manifestFile.standardizedFileURL.path
        let suffix = "/" + kind.conventionalManifest
        if path.count > suffix.count, path.hasSuffix(suffix) {
            return try inspect(kind: kind, root: URL(fileURLWithPath: String(path.dropLast(suffix.count))))
        }
        let file = URL(fileURLWithPath: path)
        return try inspect(kind: kind, root: file.deletingLastPathComponent(), manifest: file.lastPathComponent)
    }
}

/// The libraries in effect, or the converted library a user selected: at most one
/// record per kind. Persisted as JSON (`encoded()`/`decode(_:)`); a record of another
/// `version` is refused rather than reinterpreted.
public struct ResourceLibraryLocation: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var libraries: [ResourceLibraryRecord]

    public init(libraries: [ResourceLibraryRecord]) {
        version = Self.currentVersion
        self.libraries = libraries.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    public func library(_ kind: ResourceLibraryKind) -> ResourceLibraryRecord? { libraries.first { $0.kind == kind } }

    public func validate() throws {
        guard version == Self.currentVersion else { throw ResourceLibraryError.unsupportedVersion(version) }
        var kinds = Set<ResourceLibraryKind>()
        for record in libraries {
            guard kinds.insert(record.kind).inserted else { throw ResourceLibraryError.duplicateKind(record.kind) }
            try record.validate()
        }
    }

    public static func decode(_ data: Data) throws -> ResourceLibraryLocation {
        let location = try JSONDecoder().decode(ResourceLibraryLocation.self, from: data)
        try location.validate()
        return location
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Records every converted library found at its conventional manifest under a
    /// directory the user chose. A present but invalid manifest fails the selection;
    /// a directory holding none of them is `noConvertedLibrary`.
    public static func convertedRoot(_ root: URL) throws -> ResourceLibraryLocation {
        var records: [ResourceLibraryRecord] = []
        for kind in ResourceLibraryKind.converted {
            let manifest = root.appendingPathComponent(kind.conventionalManifest)
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            records.append(try ResourceLibraryRecord.inspect(kind: kind, root: root))
        }
        guard !records.isEmpty else { throw ResourceLibraryError.noConvertedLibrary(root: root.standardizedFileURL.path) }
        return ResourceLibraryLocation(libraries: records)
    }

    /// Each record whose manifest no longer has the recorded identity at its root,
    /// with the current record (nil when the manifest is missing or invalid now).
    public func changedLibraries() -> [(recorded: ResourceLibraryRecord, current: ResourceLibraryRecord?)] {
        var changed: [(recorded: ResourceLibraryRecord, current: ResourceLibraryRecord?)] = []
        for record in libraries {
            let current = try? ResourceLibraryRecord.inspect(kind: record.kind, root: URL(fileURLWithPath: record.root), manifest: record.manifest)
            if current?.sameContent(as: record) != true { changed.append((recorded: record, current: current)) }
        }
        return changed
    }
}

/// Lowercase hex SHA-256 digests of file contents.
public enum ResourceDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the file in 1 MiB chunks, so a large model is never held in memory whole.
    public static func sha256(contentsOf url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Path rules shared by the location model and the resolver. Containment uses the
/// same `realpath(3)` canonicalization as R5's `GLBLoader` package loads.
enum ResourcePath {
    /// A relative path with no leading `/`, backslash or NUL and no empty, `.` or
    /// `..` segment: it cannot name anything outside the directory it is joined to
    /// except through a symlink, which the containment check rejects.
    static func isCanonicalRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The existing item's absolute path with every symlink resolved, or nil.
    static func canonical(_ path: String) -> String? { GLBLoader.canonicalPath(URL(fileURLWithPath: path)) }

    /// `canonicalPath` relative to `canonicalRoot` when it lies strictly inside it.
    static func relative(_ canonicalPath: String, in canonicalRoot: String) -> String? {
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonicalPath.hasPrefix(prefix), canonicalPath.count > prefix.count else { return nil }
        return String(canonicalPath.dropFirst(prefix.count))
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
