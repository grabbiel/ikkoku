import Foundation
import CryptoKit
import Gameplay

public struct SourceStudioPluginState: Codable, Sendable, Equatable {
    public struct PackageIdentity: Codable, Sendable, Equatable { public let guid: String, manifestSHA256: String }
    public let profileFile: String, profileSHA256: String
    public let packages: [PackageIdentity], bindings: [SourcePluginBindingState], clock: SourcePluginClockState
    public let objectIdentities: [UUID: String], cloneSerial: UInt64
}

public final class SourceStudioPluginSession {
    private struct Profile: Decodable {
        struct Package: Decodable {
            struct Binding: Decodable { let type: String, sourceObjectKey: Int32?, objectID: UUID? }
            let manifest: String, bindings: [Binding]
        }
        let schemaVersion: Int, fixedDeltaTime: Float, packages: [Package]
    }
    public let world: SourceStudioPluginWorld, runtime: SourcePluginRuntime, library: SourcePluginLibrary
    public let profileURL: URL, profileSHA256: String
    private let packageIdentities: [SourceStudioPluginState.PackageIdentity]

    public init(profileURL: URL, document: StudioDocument, restoring saved: SourceStudioPluginState? = nil,
                attachment: SourceStudioPluginWorld.AttachmentResolver? = nil) throws {
        let handle = try FileHandle(forReadingFrom: profileURL); defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw SourcePluginError.invalid("Plugin profile exceeds 1 MiB.") }
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        guard profile.schemaVersion == 1, profile.packages.count <= 256 else { throw SourcePluginError.invalid("Unsupported plugin profile.") }
        self.profileURL = profileURL.resolvingSymlinksInPath()
        profileSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let saved {
            guard saved.profileFile.utf8.elementsEqual(self.profileURL.path.utf8), saved.profileSHA256 == profileSHA256 else {
                throw SourcePluginError.invalid("Saved plugin profile changed; explicit reinstallation is required.")
            }
        }
        var loaded: [SourcePluginPackage] = [], requested: [Data: Profile.Package] = [:]
        for package in profile.packages {
            guard !package.manifest.isEmpty, package.bindings.count <= 1024 else { throw SourcePluginError.invalid("Invalid package bindings.") }
            let url = package.manifest.hasPrefix("/") ? URL(fileURLWithPath: package.manifest)
                : profileURL.deletingLastPathComponent().appendingPathComponent(package.manifest)
            let value = try SourcePluginPackage.load(url: url)
            guard requested.updateValue(package, forKey: value.ordinalGUID) == nil else { throw SourcePluginError.invalid("Duplicate plugin package identity.") }
            requested[value.ordinalGUID] = package; loaded.append(value)
        }
        library = try SourcePluginLibrary(packages: loaded)
        packageIdentities = library.packages.map { .init(guid: $0.manifest.identity.guid,
            manifestSHA256: SHA256.hash(data: $0.manifestData).map { String(format: "%02x", $0) }.joined()) }
        if let saved {
            guard saved.packages.count == packageIdentities.count,
                  zip(saved.packages, packageIdentities).allSatisfy({ Data($0.guid.utf8) == Data($1.guid.utf8) && $0.manifestSHA256 == $1.manifestSHA256 }) else {
                throw SourcePluginError.invalid("Saved plugin package identity or version changed.")
            }
        }
        world = try SourceStudioPluginWorld(document: document, identities: saved?.objectIdentities ?? [:], cloneSerial: saved?.cloneSerial ?? 0, attachment: attachment)
        runtime = try SourcePluginRuntime(world: world, fixedDeltaTime: profile.fixedDeltaTime)
        if let saved { try runtime.restoreClock(saved.clock) }
        var bindingCount = 0, identities = Set<Data>()
        for package in library.packages {
            for binding in requested[package.ordinalGUID]!.bindings {
                guard let program = package.programs.first(where: { $0.type.utf8.elementsEqual(binding.type.utf8) }),
                      (binding.sourceObjectKey == nil) != (binding.objectID == nil) else { throw SourcePluginError.invalid("Plugin component requires one unambiguous scene target.") }
                let state: SourcePluginBindingState?
                if let saved {
                    guard saved.bindings.indices.contains(bindingCount) else { throw SourcePluginError.invalid("Saved component bindings are missing.") }
                    state = saved.bindings[bindingCount]
                } else { state = nil }
                let object: any SourceAPIObject
                if let state, state.destroyed == true {
                    let expected: String
                    if let id = binding.objectID { expected = saved?.objectIdentities[id] ?? "" }
                    else { expected = "source:\(document.sourceSceneSHA256 ?? "")/object/\(binding.sourceObjectKey!)" }
                    guard state.objectIdentity.utf8.elementsEqual(expected.utf8) else { throw SourcePluginError.invalid("Destroyed profile target identity differs.") }
                    object = try world.restoredObject(identity: expected, destroyed: true)
                } else {
                    object = try binding.objectID.map { try world.object(id: $0) } ?? world.object(sourceKey: binding.sourceObjectKey!)
                }
                let identity = try JSONEncoder().encode([package.manifest.identity.guid, program.type, object.sourceIdentity])
                guard identities.insert(identity).inserted else { throw SourcePluginError.invalid("Duplicate plugin component/object binding.") }
                try runtime.attach(program: program, object: object, saved: state)
                bindingCount += 1
            }
        }
        guard bindingCount > 0 else { throw SourcePluginError.invalid("Plugin bindings are empty.") }
        if let saved {
            // Runtime clones follow the immutable profile's original bindings.
            for state in saved.bindings.dropFirst(bindingCount) {
                guard let package = library.packages.first(where: { $0.ordinalGUID == Data(state.pluginGUID.utf8) }),
                      let program = package.programs.first(where: { $0.type.utf8.elementsEqual(state.type.utf8) }),
                      state.objectIdentity.contains("/clone/") else { throw SourcePluginError.invalid("Saved runtime clone has no installed program.") }
                let identity = try JSONEncoder().encode([state.pluginGUID, state.type, state.objectIdentity])
                guard identities.insert(identity).inserted else { throw SourcePluginError.invalid("Duplicate saved runtime clone binding.") }
                let object = try world.restoredObject(identity: state.objectIdentity, destroyed: state.destroyed == true)
                try runtime.attach(program: program, object: object, saved: state)
            }
        }
        try runtime.start()
    }
    public func step(document: StudioDocument, deltaTime: Float, afterUpdate: (() throws -> Void)? = nil) throws -> StudioDocument {
        try world.replaceDocument(document)
        try runtime.step(deltaTime: deltaTime, afterUpdate: afterUpdate)
        return try savedDocument()
    }
    public func savedDocument() throws -> StudioDocument {
        var document = world.document
        document.sourcePluginState = .init(profileFile: profileURL.path, profileSHA256: profileSHA256,
            packages: packageIdentities, bindings: try runtime.savedBindings(), clock: runtime.savedClock(),
            objectIdentities: world.identities, cloneSerial: world.cloneSerial)
        return document
    }
}
