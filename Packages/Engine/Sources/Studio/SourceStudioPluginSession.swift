import Foundation
import CryptoKit
import Gameplay

public struct SourceStudioPluginState: Codable, Sendable, Equatable {
    public struct PackageIdentity: Codable, Sendable, Equatable { public let guid: String, manifestSHA256: String }
    public let profileFile: String?, profileSHA256: String?
    public let libraryConfigurationSHA256: String?
    public let packages: [PackageIdentity], bindings: [SourcePluginBindingState], clock: SourcePluginClockState
    public let objectIdentities: [UUID: String], cloneSerial: UInt64
    /// Exact deferred roots, not their expanded descendants. Missing/null is a
    /// legacy snapshot; its lost lifecycle requests cannot be inferred safely.
    public let pendingDestructionRoots: [UUID]?
}

/// Bindings chosen in Studio for an immutable library selection. Saved inside the
/// scene, so reopening needs no generated external profile or positional IDs.
public struct SourceStudioPluginConfiguration: Codable, Sendable, Equatable {
    public struct Binding: Codable, Sendable, Equatable {
        public let guid: String, type: String
        public let sourceObjectKey: Int32?
        public let objectID: UUID?
        public init(guid: String, type: String, sourceObjectKey: Int32? = nil, objectID: UUID? = nil) {
            self.guid = guid; self.type = type; self.sourceObjectKey = sourceObjectKey; self.objectID = objectID
        }
    }
    public let fixedDeltaTime: Float, bindings: [Binding]
    public init(fixedDeltaTime: Float = 0.02, bindings: [Binding]) {
        self.fixedDeltaTime = fixedDeltaTime; self.bindings = bindings
    }
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
    /// Valid Destroy requests while replaying a saved session's construction,
    /// even if the requested root was already pending. Fresh installs keep false.
    public let initializationRequestedDestruction: Bool
    public let profileURL: URL?, profileSHA256: String?
    public let libraryConfigurationSHA256: String?
    private let packageIdentities: [SourceStudioPluginState.PackageIdentity]

    public convenience init(profileURL: URL, document: StudioDocument, restoring saved: SourceStudioPluginState? = nil,
                nativeContext: [SourceNativePluginPackage] = [],
                attachment: SourceStudioPluginWorld.AttachmentResolver? = nil) throws {
        let handle = try FileHandle(forReadingFrom: profileURL); defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw SourcePluginError.invalid("Plugin profile exceeds 1 MiB.") }
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        guard profile.schemaVersion == 1, profile.packages.count <= 256 else { throw SourcePluginError.invalid("Unsupported plugin profile.") }
        var loaded: [SourcePluginPackage] = [], requested: [Data: Profile.Package] = [:]
        for package in profile.packages {
            guard !package.manifest.isEmpty, package.bindings.count <= 1024 else { throw SourcePluginError.invalid("Invalid package bindings.") }
            let url = package.manifest.hasPrefix("/") ? URL(fileURLWithPath: package.manifest)
                : profileURL.deletingLastPathComponent().appendingPathComponent(package.manifest)
            let value = try SourcePluginPackage.load(url: url)
            guard requested.updateValue(package, forKey: value.ordinalGUID) == nil else { throw SourcePluginError.invalid("Duplicate plugin package identity.") }
            requested[value.ordinalGUID] = package; loaded.append(value)
        }
        // Preserve profile-only dependency validation and order. Saved identity
        // checks precede the mixed context check in the designated initializer.
        let library = try SourcePluginLibrary(packages: loaded)
        try self.init(profileURL: profileURL, profileSHA256: Self.hash(data), libraryConfigurationSHA256: nil,
            library: library, nativeContext: nativeContext, fixedDeltaTime: profile.fixedDeltaTime,
            requested: requested.mapValues { $0.bindings }, document: document, restoring: saved, attachment: attachment)
    }

    /// Uses packages already verified against the saved generation. No package or
    /// filesystem reads occur in construction, stepping or snapshotting this path.
    public convenience init(selection: SourcePluginLibrarySelection, resolution: SourcePluginLibraryResolution,
                            configuration: SourceStudioPluginConfiguration, document: StudioDocument,
                            restoring saved: SourceStudioPluginState? = nil,
                            attachment: SourceStudioPluginWorld.AttachmentResolver? = nil) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(selection) == encoder.encode(resolution.selection),
              configuration.bindings.count <= 1024 else {
            throw SourcePluginError.invalid("Plugin library selection or bindings differ from the verified resolution.")
        }
        let library = SourcePluginLibrary(resolution: resolution)
        var requested: [Data: [Profile.Package.Binding]] = [:]
        for binding in configuration.bindings {
            let guid = Data(binding.guid.utf8)
            guard library.packages.contains(where: { $0.ordinalGUID == guid }) else {
                throw SourcePluginError.invalid("Binding names an unselected converted plugin: \(binding.guid).")
            }
            requested[guid, default: []].append(.init(type: binding.type, sourceObjectKey: binding.sourceObjectKey, objectID: binding.objectID))
        }
        guard library.packages.allSatisfy({ requested[$0.ordinalGUID]?.isEmpty == false }) else {
            throw SourcePluginError.invalid("Every selected converted plugin requires a scene-object binding.")
        }
        try self.init(profileURL: nil, profileSHA256: nil,
            libraryConfigurationSHA256: Self.hash(encoder.encode(configuration)), library: library, nativeContext: [],
            fixedDeltaTime: configuration.fixedDeltaTime, requested: requested,
            document: document, restoring: saved, attachment: attachment)
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private init(profileURL: URL?, profileSHA256: String?, libraryConfigurationSHA256: String?, library: SourcePluginLibrary,
                 nativeContext: [SourceNativePluginPackage], fixedDeltaTime: Float,
                 requested: [Data: [Profile.Package.Binding]], document: StudioDocument,
                 restoring saved: SourceStudioPluginState?, attachment: SourceStudioPluginWorld.AttachmentResolver?) throws {
        self.profileURL = profileURL?.resolvingSymlinksInPath(); self.profileSHA256 = profileSHA256
        self.libraryConfigurationSHA256 = libraryConfigurationSHA256; self.library = library
        if let saved {
            guard saved.profileFile.map({ Data($0.utf8) }) == self.profileURL.map({ Data($0.path.utf8) }),
                  saved.profileSHA256 == profileSHA256, saved.libraryConfigurationSHA256 == libraryConfigurationSHA256 else {
                throw SourcePluginError.invalid("Saved plugin profile or library bindings changed; explicit reinstallation is required.")
            }
        }
        packageIdentities = library.packages.map { .init(guid: $0.manifest.identity.guid,
            manifestSHA256: SHA256.hash(data: $0.manifestData).map { String(format: "%02x", $0) }.joined()) }
        if let saved {
            guard saved.packages.count == packageIdentities.count,
                  zip(saved.packages, packageIdentities).allSatisfy({ Data($0.guid.utf8) == Data($1.guid.utf8) && $0.manifestSHA256 == $1.manifestSHA256 }) else {
                throw SourcePluginError.invalid("Saved plugin package identity or version changed.")
            }
        }
        // Candidate metadata is already verified by the caller. Reject an
        // incompatible union before any world, component or callback exists,
        // while retaining the saved profile/package identity error precedence.
        do { try library.validate(nativeAdapters: nativeContext) }
        catch let error as SourcePluginLibraryError { throw SourcePluginError.invalid(error.description) }
        world = try SourceStudioPluginWorld(document: document, identities: saved?.objectIdentities ?? [:], cloneSerial: saved?.cloneSerial ?? 0,
            pendingDestructionRoots: saved?.pendingDestructionRoots ?? [], attachment: attachment)
        // Normalization may add identities for unbound input objects. Snapshot
        // that candidate, including tombstones, before replaying constructors.
        // Fresh installation intentionally adopts constructor-created objects.
        let restoreBaseline: (objects: Set<UUID>, identities: [UUID: String], cloneSerial: UInt64)?
        if saved != nil {
            restoreBaseline = (Set(world.document.objects.map(\.id)), world.identities, world.cloneSerial)
        } else { restoreBaseline = nil }
        runtime = try SourcePluginRuntime(world: world, fixedDeltaTime: fixedDeltaTime)
        if let saved { try runtime.restoreClock(saved.clock) }
        let observedWorld = world
        var requestedDestruction = false
        if saved != nil { observedWorld.restoringDestructionRequested = { requestedDestruction = true } }
        defer { observedWorld.restoringDestructionRequested = nil }
        var bindingCount = 0, identities = Set<Data>()
        for package in library.packages {
            for binding in requested[package.ordinalGUID] ?? [] {
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
        initializationRequestedDestruction = requestedDestruction
        if let baseline = restoreBaseline {
            guard Set(world.document.objects.map(\.id)) == baseline.objects,
                  world.cloneSerial == baseline.cloneSerial, world.identities.count == baseline.identities.count,
                  baseline.identities.allSatisfy({ id, identity in
                      world.identities[id].map { $0.utf8.elementsEqual(identity.utf8) } == true
                  }) else {
                throw SourcePluginError.invalid("Restoring plugin initialization changed scene object topology, identities, or clone state.")
            }
        }
    }
    public func step(document: StudioDocument, deltaTime: Float, afterUpdate: (() throws -> Void)? = nil) throws -> StudioDocument {
        try world.replaceDocument(document)
        try runtime.step(deltaTime: deltaTime, afterUpdate: afterUpdate)
        return try savedDocument()
    }
    public func savedDocument() throws -> StudioDocument {
        var document = world.document
        document.sourcePluginState = .init(profileFile: profileURL?.path, profileSHA256: profileSHA256, libraryConfigurationSHA256: libraryConfigurationSHA256,
            packages: packageIdentities, bindings: try runtime.savedBindings(), clock: runtime.savedClock(),
            objectIdentities: world.identities, cloneSerial: world.cloneSerial, pendingDestructionRoots: world.pendingSourceDestructionRoots())
        return document
    }
}
