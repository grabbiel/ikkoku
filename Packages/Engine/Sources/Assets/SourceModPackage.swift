import Foundation
import CryptoKit
import ImageIO

public enum SourceModError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): message } }
}

/// Converted content and provenance from a source .zipmod. A package is an index,
/// not permission to execute source DLLs or evidence of whole-mod compatibility.
public struct SourceModPackage: Sendable {
    public struct Converter: Decodable, Sendable { public let id: String, version: String }
    public struct Source: Decodable, Sendable {
        public let guid: String, version: String, name: String, archiveSHA256: String
        public let games: [String]
    }
    public struct Resource: Decodable, Sendable {
        public let id: String, kind: String, bundlePath: String, assetName: String
        public let sourcePathID: Int64, sourceSHA256: String, path: String, sha256: String, status: String
        public let width: Int, height: Int
    }
    public struct Catalog: Decodable, Sendable {
        public let sourcePath: String, path: String, sha256: String, status: String
        public let encoding: String?, preamble: [String]?, columns: [String]?, rows: [[String]]?
        public let parseStatus: String?
    }
    public struct Diagnostic: Decodable, Sendable {
        public let code: String, severity: String, message: String
    }
    private struct Manifest: Decodable {
        let schemaVersion: Int, kind: String, converter: Converter, source: Source
        let resources: [Resource], catalogs: [Catalog], diagnostics: [Diagnostic]
        let bundleRegistrationOrder: [String]?
    }
    public let directory: URL
    /// Retained verbatim, including migration metadata and currently unknown fields.
    public let manifestData: Data
    public let converter: Converter, source: Source
    public let resources: [Resource], catalogs: [Catalog], diagnostics: [Diagnostic]
    /// Original ZIP iteration order. Older converted packages did not retain it.
    public let bundleRegistrationOrder: [String]?

    public static func load(url: URL) throws -> Self {
        let directory = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let data = try boundedRead(url, maximum: 16 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.kind == "ikkoku-mod-package",
              manifest.converter.id == "ikkoku.zipmod", supportsConverter(manifest.converter.version),
              !manifest.source.guid.isEmpty, manifest.source.guid == manifest.source.guid.trimmingCharacters(in: .whitespacesAndNewlines),
              hashIsValid(manifest.source.archiveSHA256),
              Set(manifest.resources.map(\.id)).count == manifest.resources.count,
              Set(manifest.catalogs.map(\.sourcePath)).count == manifest.catalogs.count else {
            throw SourceModError.invalid("Unsupported or malformed source mod manifest.")
        }
        if manifest.converter.version == "1.1.0", manifest.bundleRegistrationOrder == nil {
            throw SourceModError.invalid("Mod package is missing original bundle registration order; reimport the archive.")
        }
        if let order = manifest.bundleRegistrationOrder {
            guard Set(order).count == order.count else { throw SourceModError.invalid("Duplicate source bundle registration.") }
            for path in order {
                try validateRelative(path)
                guard path.lowercased().hasSuffix(".unity3d") else { throw SourceModError.invalid("Unregistered source bundle extension.") }
            }
            guard manifest.resources.allSatisfy({ order.contains($0.bundlePath) }) else {
                throw SourceModError.invalid("Converted texture has no source bundle registration.")
            }
        }
        var identities = Set<String>(), pathHashes: [String: String] = [:]
        func registerPath(_ path: String, hash: String) throws {
            let key = path.lowercased()
            if let old = pathHashes[key], old != hash { throw SourceModError.invalid("Conflicting hashes for a shared mod cache path.") }
            pathHashes[key] = hash
        }
        for resource in manifest.resources {
            // The explicit catalog's bundle/name identity survives cache relocation.
            // Do not normalize asset names or invent source archive priority.
            try validateRelative(resource.bundlePath)
            guard resource.kind == "texture2D", resource.status == "converted",
                  !resource.id.isEmpty, !resource.assetName.isEmpty,
                  hashIsValid(resource.sourceSHA256), hashIsValid(resource.sha256),
                  (1...16384).contains(resource.width), (1...16384).contains(resource.height),
                  resource.width <= 67_108_864 / resource.height,
                  identities.insert(identity(resource.bundlePath, resource.assetName)).inserted else {
                throw SourceModError.invalid("Invalid or ambiguous mod texture '\(resource.assetName)'.")
            }
            try registerPath(resource.path, hash: resource.sha256)
            let file = try contained(resource.path, directory: directory)
            let bytes = try checkedRead(file, hash: resource.sha256)
            guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), bytes.count >= 24,
                  Array(bytes[12..<16]) == [73, 72, 68, 82] else {
                throw SourceModError.invalid("Converted mod texture is not a PNG.")
            }
            func uint32(_ offset: Int) -> Int {
                bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            }
            guard uint32(16) == resource.width, uint32(20) == resource.height else {
                throw SourceModError.invalid("Converted mod PNG dimensions differ from its manifest.")
            }
            guard let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetCount(image) == 1, CGImageSourceGetStatus(image) == .statusComplete,
                  CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                throw SourceModError.invalid("Converted mod PNG is incomplete or cannot be decoded.")
            }
        }
        for catalog in manifest.catalogs {
            try validateRelative(catalog.sourcePath)
            guard catalog.status == "preserved", hashIsValid(catalog.sha256) else {
                throw SourceModError.invalid("Invalid preserved mod catalog.")
            }
            if catalog.parseStatus != "unsupported" {
                guard let columns = catalog.columns, let rows = catalog.rows, !columns.isEmpty,
                      rows.allSatisfy({ $0.count == columns.count }) else { throw SourceModError.invalid("Invalid parsed mod catalog.") }
            }
            try registerPath(catalog.path, hash: catalog.sha256)
            _ = try checkedRead(contained(catalog.path, directory: directory), hash: catalog.sha256)
        }
        return Self(directory: directory, manifestData: data, converter: manifest.converter, source: manifest.source,
                    resources: manifest.resources, catalogs: manifest.catalogs, diagnostics: manifest.diagnostics,
                    bundleRegistrationOrder: manifest.bundleRegistrationOrder)
    }

    /// Rechecks bytes on access so a changed cache cannot silently retain its old identity.
    public func textureData(_ resource: Resource) throws -> Data {
        guard resources.contains(where: { $0.id == resource.id && $0.path == resource.path && $0.sha256 == resource.sha256 }) else {
            throw SourceModError.invalid("Texture does not belong to this mod package.")
        }
        return try Self.checkedRead(Self.contained(resource.path, directory: directory), hash: resource.sha256)
    }

    public func catalogData(_ catalog: Catalog) throws -> Data {
        guard catalogs.contains(where: { $0.sourcePath == catalog.sourcePath && $0.path == catalog.path && $0.sha256 == catalog.sha256 }) else {
            throw SourceModError.invalid("Catalog does not belong to this mod package.")
        }
        return try Self.checkedRead(Self.contained(catalog.path, directory: directory), hash: catalog.sha256)
    }

    static func hashIsValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func supportsConverter(_ version: String) -> Bool { ["1.0.0", "1.1.0"].contains(version) }
    static func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0, size.int64Value <= maximum else {
            throw SourceModError.invalid("Mod cache file is not a regular file within the size limit.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw SourceModError.invalid("Mod cache file exceeds the size limit.") }
        return bytes
    }
    static func checkedRead(_ url: URL, hash: String) throws -> Data {
        let bytes = try boundedRead(url, maximum: 256 * 1024 * 1024)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw SourceModError.invalid("Mod cache hash mismatch for '\(url.lastPathComponent)'; reimport the archive.")
        }
        return bytes
    }
    static func validateRelative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SourceModError.invalid("Mod resource path must be a canonical relative path.")
        }
    }
    static func contained(_ path: String, directory: URL) throws -> URL {
        try validateRelative(path)
        let file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path + "/") else { throw SourceModError.invalid("Mod resource escapes its package.") }
        return file
    }
    fileprivate static func identity(_ bundlePath: String, _ name: String) -> String { bundlePath + "\0" + name }
}

/// Native content extension point. Callers supply an explicit loader order; the
/// source archive version/culture ordering is not yet selected automatically.
public struct SourceModLibrary: Sendable {
    public struct ResolvedTexture: Sendable {
        public let modGUID: String, modVersion: String, archiveSHA256: String
        public let resource: SourceModPackage.Resource
        public let data: Data
        public var cacheKey: String { "mod:\(modGUID):\(resource.id):\(archiveSHA256):\(resource.sha256)" }
    }
    public let packages: [SourceModPackage]
    private let textureIndex: [String: (package: Int, resource: Int)]
    private enum SourceProvider: Sendable { case texture(package: Int, resource: Int), ambiguous }
    private let sourceTextureIndex: [String: SourceProvider]
    public init(packages: [SourceModPackage]) throws {
        guard Set(packages.map { $0.source.guid }).count == packages.count else {
            throw SourceModError.invalid("Duplicate mod GUIDs require an explicit version choice before mounting.")
        }
        self.packages = packages
        var index: [String: (package: Int, resource: Int)] = [:]
        var sourceIndex: [String: SourceProvider] = [:]
        for (packageIndex, package) in packages.enumerated() {
            var sourceCandidates: [String: [(resource: Int, bundle: String)]] = [:]
            for (resourceIndex, resource) in package.resources.enumerated() {
                let key = SourceModPackage.identity(resource.bundlePath, resource.assetName)
                if index[key] == nil { index[key] = (packageIndex, resourceIndex) }
                // Sideloader strips any first path component; it does not require abdata.
                guard resource.bundlePath.lowercased().hasSuffix(".unity3d") else { continue }
                let alias = resource.bundlePath.split(separator: "/", maxSplits: 1).last.map(String.init) ?? resource.bundlePath
                let sourceKey = SourceModPackage.identity(alias, resource.assetName)
                sourceCandidates[sourceKey, default: []].append((resourceIndex, resource.bundlePath))
            }
            let order = package.bundleRegistrationOrder.map { Dictionary(uniqueKeysWithValues: $0.enumerated().map { ($1, $0) }) }
            for (key, candidates) in sourceCandidates where sourceIndex[key] == nil {
                if let order {
                    let first = candidates.min { order[$0.bundle, default: Int.max] < order[$1.bundle, default: Int.max] }!
                    sourceIndex[key] = .texture(package: packageIndex, resource: first.resource)
                } else if candidates.count == 1 {
                    sourceIndex[key] = .texture(package: packageIndex, resource: candidates[0].resource)
                } else {
                    // Resource ID sorting in old caches cannot recover ZIP registration order.
                    sourceIndex[key] = .ambiguous
                }
            }
        }
        self.textureIndex = index
        self.sourceTextureIndex = sourceIndex
    }

    /// Source catalog paths omit the archive's first component. Retained ZIP order
    /// resolves aliases within a package; the explicit profile resolves package order.
    public func sourceTextureProvider(bundlePath: String, assetName: String) throws -> (modGUID: String, resource: SourceModPackage.Resource)? {
        guard let provider = sourceTextureIndex[SourceModPackage.identity(bundlePath, assetName)] else { return nil }
        switch provider {
        case .texture(let packageIndex, let resourceIndex):
            return (packages[packageIndex].source.guid, packages[packageIndex].resources[resourceIndex])
        case .ambiguous:
            throw SourceModError.invalid("Legacy mod cache has ambiguous source bundle aliases for '\(bundlePath)/\(assetName)'; reimport it to preserve ZIP order.")
        }
    }

    /// Metadata lookup does not reread PNG bytes for every catalog dependency.
    public func textureProvider(bundlePath: String, assetName: String) -> (modGUID: String, resource: SourceModPackage.Resource)? {
        guard let entry = textureIndex[SourceModPackage.identity(bundlePath, assetName)] else { return nil }
        let package = packages[entry.package]
        return (package.source.guid, package.resources[entry.resource])
    }
    /// Like the observed source BundleManager, searches each mounted bundle for
    /// the requested asset before proceeding to the next loader at that path.
    public func texture(bundlePath: String, assetName: String) throws -> ResolvedTexture? {
        guard let entry = textureIndex[SourceModPackage.identity(bundlePath, assetName)] else { return nil }
        let package = packages[entry.package], resource = package.resources[entry.resource]
        return try ResolvedTexture(modGUID: package.source.guid, modVersion: package.source.version,
            archiveSHA256: package.source.archiveSHA256, resource: resource, data: package.textureData(resource))
    }
}
