import Foundation

// A-T02: relocation of a saved document's file references against the libraries in
// effect now (ResourceLibrary.swift). A document records, per referenced file, its
// SHA-256 and the library root and relative path it had at save time
// (`ResourceBinding`). On load each reference resolves at most to one file, inside
// the library that has the recorded content, whose bytes hash to the recorded
// digest. Anything else is reported as unresolved with the identity it was saved
// with; no other file is ever chosen in its place. Contract:
// docs/reference/native-assets.md ("Library location and relocation").

/// One file a saved document referred to, as recorded at save time.
public struct ResourceFileIdentity: Codable, Sendable, Equatable {
    /// The path exactly as the document records it.
    public var path: String
    /// Lowercase hex SHA-256 of the file's bytes, or the digest the document records
    /// for it itself (a source scene's `sourceSceneSHA256`).
    public var sha256: String
    /// The realpath of the root of the library that held the file at save time; nil
    /// for a file outside every library in effect then.
    public var libraryRoot: String?
    /// The file's realpath relative to `libraryRoot`.
    public var relativePath: String?

    public init(path: String, sha256: String, libraryRoot: String? = nil, relativePath: String? = nil) {
        self.path = path; self.sha256 = sha256; self.libraryRoot = libraryRoot; self.relativePath = relativePath
    }
}

/// What a saved document's file references were checked against when it was
/// saved: the libraries holding them (realpath roots) and one identity per file.
public struct ResourceBinding: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    /// Libraries that held at least one recorded file, sorted by root and kind.
    public var libraries: [ResourceLibraryRecord]
    /// One entry per recorded path, sorted by path.
    public var files: [ResourceFileIdentity]

    public init(libraries: [ResourceLibraryRecord], files: [ResourceFileIdentity]) {
        version = Self.currentVersion
        self.libraries = libraries.sorted { ($0.root, $0.kind.rawValue) < ($1.root, $1.kind.rawValue) }
        self.files = files.sorted { $0.path < $1.path }
    }

    /// The identity recorded for exactly this path (UTF-8 bytes, not canonical
    /// String equivalence).
    public func file(_ path: String) -> ResourceFileIdentity? { files.first { $0.path.utf8.elementsEqual(path.utf8) } }

    /// Records each file reference: its digest and, when it lies inside one of
    /// `libraries` after symlinks, that library's realpath root and the file's
    /// path relative to it (the longest containing root wins).
    ///
    /// `previous` is the binding the document was loaded with. Its identity for a
    /// path is kept whenever the file is now missing, unreadable or has other
    /// bytes, so saving a document whose reference failed its check never adopts
    /// the changed file as the saved identity. A file that still has its previous
    /// digest is re-recorded against the current libraries. A reference with its
    /// own digest (`expectedSHA256`) records that digest. Returns nil when no file
    /// is recorded, so a document without file references saves as before.
    public static func record(_ references: [ResourceReference], libraries: [ResourceLibraryRecord],
                              previous: ResourceBinding? = nil) -> ResourceBinding? {
        let current: [ResourceLibraryRecord] = libraries.compactMap { record in
            guard let root = ResourcePath.canonical(record.root), ResourcePath.isDirectory(root) else { return nil }
            var canonical = record
            canonical.root = root
            return canonical
        }
        let previousRecords = previous?.version == currentVersion ? previous : nil
        var files: [ResourceFileIdentity] = [], seen = Set<Data>(), kept: [ResourceLibraryRecord] = []
        func keep(_ records: [ResourceLibraryRecord], root: String?) {
            guard let root else { return }
            for record in records where record.root == root && !kept.contains(record) { kept.append(record) }
        }
        for reference in references {
            guard case .file(let path) = reference.target, seen.insert(Data(path.utf8)).inserted else { continue }
            let earlier = previousRecords?.file(path)
            let own = reference.expectedSHA256.flatMap { ResourceDigest.isSHA256($0) ? $0 : nil }
            if let file = ResourcePath.canonical(path), !ResourcePath.isDirectory(file) {
                let digest = own ?? (try? ResourceDigest.sha256(contentsOf: URL(fileURLWithPath: file)))
                if let digest, earlier == nil || earlier?.sha256 == digest {
                    let owner = current.map(\.root).filter { ResourcePath.relative(file, in: $0) != nil }.max { $0.count < $1.count }
                    files.append(ResourceFileIdentity(path: path, sha256: digest, libraryRoot: owner,
                                                      relativePath: owner.flatMap { ResourcePath.relative(file, in: $0) }))
                    keep(current, root: owner)
                    continue
                }
            }
            // Missing, unreadable or changed now: keep the identity it was saved with.
            if let earlier {
                files.append(earlier)
                keep(previousRecords?.libraries ?? [], root: earlier.libraryRoot)
            } else if let own {
                files.append(ResourceFileIdentity(path: path, sha256: own))
            }
        }
        guard !files.isEmpty else { return nil }
        return ResourceBinding(libraries: kept, files: files)
    }
}

/// One reference a document makes to a file.
public struct ResourceReference: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// A path the document records: absolute, or relative to the working
        /// directory like `URL(fileURLWithPath:)`.
        case file(String)
        /// A file a library's catalog names (a native catalog item): resolved in
        /// the library of that kind in effect now. Nil when the catalog has no
        /// entry for the reference's identity.
        case libraryFile(kind: ResourceLibraryKind, relativePath: String?)
    }
    /// What refers to the file, for reports: owner, field and any catalog ID.
    public let identity: String
    public let target: Target
    /// A digest the document records for the file itself (a source scene's
    /// SHA-256). It takes precedence over the binding's.
    public let expectedSHA256: String?

    public init(identity: String, target: Target, expectedSHA256: String? = nil) {
        self.identity = identity; self.target = target; self.expectedSHA256 = expectedSHA256
    }
}

/// Why a reference did not resolve. Each case names the path or identity involved.
public enum ResourceResolutionFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// No regular file exists where the reference resolves.
    case missing(path: String)
    case unreadable(path: String, reason: String)
    /// A file exists, but its bytes are not the recorded content.
    case identityMismatch(path: String, expectedSHA256: String, actualSHA256: String)
    /// The recorded relative path is not canonical, or the file resolves outside
    /// its library root after symlinks.
    case escapesLibraryRoot(reference: String, root: String)
    /// More than one library in effect has the recorded content.
    case ambiguousLibrary(roots: [String])
    /// No library of this kind is in effect.
    case libraryNotSelected(kind: ResourceLibraryKind)
    /// The library's catalog has no entry for the reference.
    case notInCatalog(kind: ResourceLibraryKind)
    /// The document's binding has a version this build does not read.
    case unsupportedBinding(version: Int)

    public var description: String {
        switch self {
        case .missing(let path): return "no file at \(path)"
        case .unreadable(let path, let reason): return "\(path) could not be read (\(reason))"
        case .identityMismatch(let path, let expected, let actual):
            return "\(path) has SHA-256 \(actual), not the recorded \(expected)"
        case .escapesLibraryRoot(let reference, let root): return "'\(reference)' resolves outside its library root \(root)"
        case .ambiguousLibrary(let roots): return "the recorded library content is in effect at more than one root (\(roots.joined(separator: ", ")))"
        case .libraryNotSelected(let kind): return "no \(kind.label) is in effect"
        case .notInCatalog(let kind): return "the \(kind.label) catalog has no entry for it"
        case .unsupportedBinding(let version): return "the document's resource binding version \(version) is unsupported (expected \(ResourceBinding.currentVersion))"
        }
    }
}

/// The outcome for one reference.
public struct ResourceResolution: Sendable, Equatable, CustomStringConvertible {
    public enum Status: String, Sendable {
        /// The file is where the document records it.
        case resolved
        /// The library moved: the file is at `path` inside the library that has
        /// the recorded content now, and the document's path should be replaced.
        case relocated
        /// No file may be used for this reference; `failure` says why.
        case unresolved
    }
    public enum Verification: String, Sendable {
        /// The bytes hash to the recorded SHA-256.
        case sha256
        /// A catalog-relative file found through its catalog entry; the catalog
        /// records no digest, so its ID is the identity.
        case catalog
        /// Found at its recorded path, with no recorded digest to compare (a
        /// document saved before A-T02, or a file that did not exist at save time).
        case unverified
    }
    public let reference: ResourceReference
    public let status: Status
    /// The verified file to use; nil when unresolved.
    public let path: String?
    public let verification: Verification?
    /// The library the reference was recorded in (from the binding), or the
    /// library in effect for a catalog-relative file.
    public let library: ResourceLibraryRecord?
    public let expectedSHA256: String?
    public let failure: ResourceResolutionFailure?

    public var description: String {
        switch status {
        case .resolved: return "\(reference.identity): \(path ?? "") (\(verification?.rawValue ?? "unverified"))"
        case .relocated: return "\(reference.identity): relocated to \(path ?? "") (\(verification?.rawValue ?? "unverified"))"
        case .unresolved:
            var text = "\(reference.identity): unresolved, \(failure.map { "\($0)" } ?? "unknown failure")"
            if let expectedSHA256 { text += "; recorded SHA-256 \(expectedSHA256)" }
            if let library { text += "; recorded in \(library.identityDescription) at \(library.root)" }
            return text
        }
    }
}

public struct ResourceRelocationReport: Sendable, Equatable {
    /// One resolution per reference, in reference order.
    public let resolutions: [ResourceResolution]

    public init(resolutions: [ResourceResolution]) { self.resolutions = resolutions }

    public var resolved: [ResourceResolution] { resolutions.filter { $0.status == .resolved } }
    public var relocated: [ResourceResolution] { resolutions.filter { $0.status == .relocated } }
    public var unresolved: [ResourceResolution] { resolutions.filter { $0.status == .unresolved } }
    public func resolution(for identity: String) -> ResourceResolution? {
        resolutions.first { $0.reference.identity.utf8.elementsEqual(identity.utf8) }
    }
    public var summary: String {
        "\(resolutions.count) references: \(resolved.count) resolved, \(relocated.count) relocated, \(unresolved.count) unresolved"
    }
}

public enum ResourceRelocation {
    /// Resolves each reference against `binding` (nil for a document saved before
    /// A-T02) and the libraries in effect now. Pure apart from reading the files.
    ///
    /// A file the binding places inside a library resolves only inside the one
    /// library in effect that has that recorded content (kind, manifest path,
    /// manifest digest and format version), at the recorded relative path, after
    /// R5's realpath containment check, and only when its bytes hash to the recorded
    /// digest. When no library in effect has that content, the file is checked at
    /// its recorded path instead, with the same digest. Any other file reference is
    /// checked at its recorded path, against a digest when one was recorded.
    public static func resolve(_ references: [ResourceReference], binding: ResourceBinding?,
                               current: ResourceLibraryLocation) -> ResourceRelocationReport {
        ResourceRelocationReport(resolutions: references.map { resolve($0, binding: binding, current: current) })
    }

    static func resolve(_ reference: ResourceReference, binding: ResourceBinding?, current: ResourceLibraryLocation) -> ResourceResolution {
        func result(_ status: ResourceResolution.Status, path: String? = nil, verification: ResourceResolution.Verification? = nil,
                    library: ResourceLibraryRecord?, expected: String?, failure: ResourceResolutionFailure? = nil) -> ResourceResolution {
            ResourceResolution(reference: reference, status: status, path: path, verification: verification,
                               library: library, expectedSHA256: expected, failure: failure)
        }
        switch reference.target {
        case .libraryFile(let kind, let relativePath):
            let expected = reference.expectedSHA256
            guard let library = current.library(kind) else {
                return result(.unresolved, library: nil, expected: expected, failure: .libraryNotSelected(kind: kind))
            }
            guard let relativePath else { return result(.unresolved, library: library, expected: expected, failure: .notInCatalog(kind: kind)) }
            guard ResourcePath.isCanonicalRelative(relativePath) else {
                return result(.unresolved, library: library, expected: expected, failure: .escapesLibraryRoot(reference: relativePath, root: library.root))
            }
            let candidate = URL(fileURLWithPath: library.root).appendingPathComponent(relativePath).path
            switch locate(candidate, in: ResourcePath.canonical(library.root) ?? library.root) {
            case .failure(let failure): return result(.unresolved, library: library, expected: expected, failure: failure)
            case .success(let file):
                if let failure = verify(file, shown: candidate, expected: expected) {
                    return result(.unresolved, library: library, expected: expected, failure: failure)
                }
                return result(.resolved, path: candidate, verification: expected == nil ? .catalog : .sha256, library: library, expected: expected)
            }

        case .file(let path):
            if let binding, binding.version != ResourceBinding.currentVersion {
                return result(.unresolved, library: nil, expected: reference.expectedSHA256, failure: .unsupportedBinding(version: binding.version))
            }
            let identity = binding?.file(path)
            let expected = reference.expectedSHA256 ?? identity?.sha256
            func inPlace(library: ResourceLibraryRecord?) -> ResourceResolution {
                guard let file = ResourcePath.canonical(path), !ResourcePath.isDirectory(file) else {
                    return result(.unresolved, library: library, expected: expected, failure: .missing(path: path))
                }
                if let failure = verify(file, shown: path, expected: expected) {
                    return result(.unresolved, library: library, expected: expected, failure: failure)
                }
                return result(.resolved, path: path, verification: expected == nil ? .unverified : .sha256, library: library, expected: expected)
            }
            guard let binding, let identity, let ownerRoot = identity.libraryRoot else { return inPlace(library: nil) }
            let recorded = binding.libraries.filter { $0.root == ownerRoot }
            let library = recorded.first
            guard let relative = identity.relativePath, ResourcePath.isCanonicalRelative(relative) else {
                return result(.unresolved, library: library, expected: expected,
                              failure: .escapesLibraryRoot(reference: identity.relativePath ?? "", root: ownerRoot))
            }
            // The libraries in effect with the recorded content, keyed by realpath root.
            var matches: [String: ResourceLibraryRecord] = [:]
            for record in current.libraries where recorded.contains(where: { $0.sameContent(as: record) }) {
                let root = ResourcePath.canonical(record.root) ?? record.root
                if matches[root] == nil { matches[root] = record }
            }
            guard matches.count <= 1 else {
                return result(.unresolved, library: library, expected: expected, failure: .ambiguousLibrary(roots: matches.keys.sorted()))
            }
            // No library in effect has the recorded content: the file may still be
            // where it was saved, and must still have its recorded digest.
            guard let only = matches.first else { return inPlace(library: library) }
            let canonicalRoot = only.key, match = only.value
            let candidate = URL(fileURLWithPath: match.root).appendingPathComponent(relative).path
            switch locate(candidate, in: canonicalRoot) {
            case .failure(let failure): return result(.unresolved, library: library, expected: expected, failure: failure)
            case .success(let file):
                if let failure = verify(file, shown: candidate, expected: expected) {
                    return result(.unresolved, library: library, expected: expected, failure: failure)
                }
                let verification: ResourceResolution.Verification = expected == nil ? .unverified : .sha256
                // Same library location and the recorded path is the verified file:
                // keep the document's path untouched.
                if canonicalRoot == ownerRoot, ResourcePath.canonical(path) == file {
                    return result(.resolved, path: path, verification: verification, library: library, expected: expected)
                }
                return result(.relocated, path: candidate, verification: verification, library: library, expected: expected)
            }
        }
    }

    /// The canonical regular file at `candidate` when it exists inside `canonicalRoot`.
    static func locate(_ candidate: String, in canonicalRoot: String) -> Result<String, ResourceResolutionFailure> {
        guard let file = ResourcePath.canonical(candidate) else { return .failure(.missing(path: candidate)) }
        guard ResourcePath.relative(file, in: canonicalRoot) != nil else {
            return .failure(.escapesLibraryRoot(reference: candidate, root: canonicalRoot))
        }
        guard !ResourcePath.isDirectory(file) else { return .failure(.missing(path: candidate)) }
        return .success(file)
    }

    /// Nil when `expected` is nil or the file's bytes hash to it.
    static func verify(_ file: String, shown: String, expected: String?) -> ResourceResolutionFailure? {
        guard let expected else { return nil }
        do {
            let actual = try ResourceDigest.sha256(contentsOf: URL(fileURLWithPath: file))
            return actual == expected.lowercased() ? nil : .identityMismatch(path: shown, expectedSHA256: expected, actualSHA256: actual)
        } catch {
            return .unreadable(path: shown, reason: "\(error)")
        }
    }
}
