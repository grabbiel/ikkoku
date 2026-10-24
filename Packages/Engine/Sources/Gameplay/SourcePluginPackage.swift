import Foundation
import CryptoKit

public struct SourcePluginPackage: Sendable {
    public struct Manifest: Codable, Sendable {
        public struct Identity: Codable, Sendable { public let guid: String, version: String, name: String }
        public struct Dependency: Codable, Sendable { public let guid: String, minimumVersion: String?, required: Bool }
        public struct File: Codable, Sendable { public let file: String, sha256: String }
        public struct Component: Codable, Sendable { public let type: String, program: File }
        public let schemaVersion: Int, kind: String, identity: Identity
        public let processes: [String], dependencies: [Dependency], incompatibilities: [String], components: [Component]
    }
    public let manifest: Manifest, manifestURL: URL, manifestData: Data, programs: [SourceIRProgram]
    public var ordinalGUID: Data { Data(manifest.identity.guid.utf8) }

    public static func load(url: URL) throws -> Self {
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath()
        func read(_ path: URL, maximum: Int) throws -> Data {
            let input = try FileHandle(forReadingFrom: path); defer { try? input.close() }
            let bytes = try input.read(upToCount: maximum + 1) ?? Data()
            guard bytes.count <= maximum else { throw SourcePluginError.invalid("Plugin file exceeds \(maximum) bytes.") }; return bytes
        }
        let bytes = try read(url, maximum: 1024 * 1024)
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        func bounded(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 1024 }
        guard manifest.schemaVersion == 1, manifest.kind == "ikkoku-translated-plugin", bounded(manifest.identity.guid),
              bounded(manifest.identity.version), bounded(manifest.identity.name),
              !manifest.components.isEmpty, manifest.components.count <= 128,
              manifest.dependencies.count <= 128, manifest.incompatibilities.count <= 128, manifest.processes.count <= 32,
              manifest.processes.allSatisfy(bounded), manifest.dependencies.allSatisfy({ bounded($0.guid) }),
              manifest.incompatibilities.allSatisfy(bounded),
              Set(manifest.components.map { Data($0.type.utf8) }).count == manifest.components.count,
              Set(manifest.dependencies.map { Data($0.guid.utf8) }).count == manifest.dependencies.count else {
            throw SourcePluginError.invalid("Unsupported plugin manifest or duplicate component/dependency identity.")
        }
        var programs: [SourceIRProgram] = []
        for component in manifest.components {
            let ref = component.program, file = root.appendingPathComponent(ref.file).resolvingSymlinksInPath()
            guard bounded(component.type), !ref.file.isEmpty, !ref.file.hasPrefix("/"), file.path.hasPrefix(root.path + "/"),
                  ref.sha256.utf8.count == 64 else { throw SourcePluginError.invalid("Program reference escapes its package.") }
            let data = try read(file, maximum: 4 * 1024 * 1024)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == ref.sha256 else { throw SourcePluginError.invalid("Translated program hash changed.") }
            let program = try SourceIRProgram.decode(data)
            guard program.mode == "component", program.type.utf8.elementsEqual(component.type.utf8),
                  program.identity.pluginGUID.map({ Data($0.utf8) }) == Data(manifest.identity.guid.utf8) else {
                throw SourcePluginError.invalid("Component source identity does not match its plugin package.")
            }
            programs.append(program)
        }
        return .init(manifest: manifest, manifestURL: url.resolvingSymlinksInPath(), manifestData: bytes, programs: programs)
    }
}

/// A deterministic dependency order. Identity uses UTF-8 bytes, preserving the
/// original GUID's case and Unicode instead of Swift's canonical String equality.
/// `SourcePluginGraph` holds the rules shared with native adapters and library
/// selections; profile loads keep reporting `SourcePluginError`.
public struct SourcePluginLibrary: Sendable {
    public let packages: [SourcePluginPackage]
    /// A mixed selection has already passed the graph, including dependencies
    /// supplied by native adapters. Preserve that order for its executable subset.
    public init(resolution: SourcePluginLibraryResolution) { packages = resolution.translated }
    public init(packages requested: [SourcePluginPackage], process: String = "CharaStudio") throws {
        do {
            let nodes = requested.map { SourcePluginGraph.Node(package: $0) }
            packages = try SourcePluginGraph.order(nodes, process: process).map { requested[$0] }
        } catch let error as SourcePluginLibraryError {
            throw SourcePluginError.invalid(error.description)
        }
    }
}
