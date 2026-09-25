import Foundation
import CryptoKit

public struct SourceNativePluginReference: Codable, Sendable, Equatable {
    public let manifestFile: String, manifestSHA256: String, guid: String, version: String, adapterID: String
    public var enabled: Bool
    public init(package: SourceNativePluginPackage, enabled: Bool = true) {
        manifestFile = package.manifestURL.path; manifestSHA256 = package.manifestSHA256
        guid = package.manifest.identity.guid; version = package.manifest.identity.version
        adapterID = package.manifest.adapterID; self.enabled = enabled
    }
    public func load() throws -> SourceNativePluginPackage {
        let package = try SourceNativePluginPackage.load(url: URL(fileURLWithPath: manifestFile))
        guard package.manifestSHA256 == manifestSHA256, package.manifest.identity.guid.utf8.elementsEqual(guid.utf8),
              package.manifest.identity.version == version, package.manifest.adapterID == adapterID else {
            throw SourcePluginError.invalid("Saved native adapter identity or configuration changed.")
        }
        return package
    }
}

/// Only exact recovered assemblies with verified behavior oracles select these
/// adapters. Assembly bytes are identity evidence and are never executed.
public struct SourceNativePluginPackage: Sendable {
    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int, kind: String, adapterID: String, type: String
        public let identity: SourcePluginPackage.Manifest.Identity
        public let processes: [String]
        public let source: SourcePluginPackage.Manifest.File
        public let configuration: SourcePluginPackage.Manifest.File?
    }
    public let manifest: Manifest, manifestURL: URL, manifestSHA256: String
    public let configuration: Data?
    public static let muteAdapter = "bepinex-mute-in-background-v1"
    public static let accessoryAdapter = "kk-studio-accessory-names-v1"
    public static func load(url: URL) throws -> Self {
        func read(_ file: URL, limit: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let bytes = try handle.read(upToCount: limit + 1) ?? Data()
            guard bytes.count <= limit else { throw SourcePluginError.invalid("Native adapter input exceeds its limit.") }
            return bytes
        }
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let bytes = try read(url, limit: 1024 * 1024), value = try JSONDecoder().decode(Manifest.self, from: bytes)
        let expected: (String, String, String, String, String, [String])
        switch value.adapterID {
        case muteAdapter:
            expected = ("BepInEx.MuteInBackground", "Mute In Background", "1.1", "BepInEx.MuteInBackground", "e494f24b73fed491d056c3c6a00ee73baf257409877ce8e5b44da1b0494ca96d", [])
        case accessoryAdapter:
            expected = ("KK_StudioAccessoryNames", "KK_StudioAccessoryNames", "1.1.0", "KK_StudioAccessoryNames.KK_StudioAccessoryNames", "c60d740ee1037040e97bcb0ae8037f8f7a1e4350322bc7ed44699fd0dc9662bd", ["CharaStudio"])
        default: throw SourcePluginError.invalid("No verified native behavior adapter for this assembly.")
        }
        guard value.schemaVersion == 1, value.kind == "ikkoku-native-plugin-adapter",
              value.identity.guid.utf8.elementsEqual(expected.0.utf8), value.identity.name.utf8.elementsEqual(expected.1.utf8),
              value.identity.version == expected.2, value.type == expected.3,
              value.source.sha256 == expected.4, value.processes == expected.5,
              value.adapterID == muteAdapter || value.configuration == nil else {
            throw SourcePluginError.invalid("Native adapter identity differs from the verified original.")
        }
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath()
        func artifact(_ ref: SourcePluginPackage.Manifest.File, limit: Int) throws -> Data {
            let path = root.appendingPathComponent(ref.file).resolvingSymlinksInPath()
            guard !ref.file.isEmpty, !ref.file.hasPrefix("/"), path.path.hasPrefix(root.path + "/") else { throw SourcePluginError.invalid("Native adapter file escapes its package.") }
            let data = try read(path, limit: limit)
            guard hash(data) == ref.sha256 else { throw SourcePluginError.invalid("Native adapter source or configuration hash changed.") }
            return data
        }
        _ = try artifact(value.source, limit: 32 * 1024 * 1024)
        return try .init(manifest: value, manifestURL: url.resolvingSymlinksInPath(), manifestSHA256: hash(bytes),
            configuration: value.configuration.map { try artifact($0, limit: 1024 * 1024) })
    }
}
