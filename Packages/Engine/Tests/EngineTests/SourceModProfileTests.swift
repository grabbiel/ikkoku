import Foundation
import Testing
import CryptoKit
import Assets

private func profileTestHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func profileTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceModProfile-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct ModProfileFixture {
    let directory: URL
    let configuration: String
    var library: [String: Any]
    var profile: [String: Any]
    var libraryURL: URL { directory.appendingPathComponent("library.json") }
    var profileURL: URL { directory.appendingPathComponent("profiles/default.json") }

    init(_ directory: URL) throws {
        self.directory = directory
        let configuration = profileTestHash(Data("synthetic configuration".utf8))
        self.configuration = configuration
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("profiles"), withIntermediateDirectories: true)
        library = ["schemaVersion": 1, "kind": "ikkoku-mod-library", "configurationSHA256": configuration,
            "converter": ["id": "ikkoku.zipmod", "version": "1.0.0"], "archives": [] as [[String: Any]],
            "diagnostics": [["code": "library_note", "severity": "info", "message": "synthetic library"]]]
        profile = ["schemaVersion": 1, "kind": "ikkoku-mod-profile", "name": "default", "configurationSHA256": configuration,
            "choices": [:] as [String: String], "mountOrder": [] as [String], "mounts": [] as [[String: Any]],
            "unresolvedConflicts": [] as [[String: Any]],
            "diagnostics": [["code": "profile_note", "severity": "info", "message": "synthetic profile"]]]
    }

    @discardableResult
    mutating func addPackage(_ guid: String, version: String = "1", mounted: Bool = true) throws -> [String: Any] {
        let archive = profileTestHash(Data((guid + ":" + version).utf8))
        let path = "generations/\(archive)/\(configuration)/manifest.json"
        let package: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-mod-package",
            "converter": ["id": "ikkoku.zipmod", "version": "1.0.0"],
            "source": ["guid": guid, "version": version, "name": guid, "games": ["Koikatsu"], "archiveSHA256": archive],
            "resources": [] as [[String: Any]], "catalogs": [] as [[String: Any]], "diagnostics": [] as [[String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys])
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        let mount: [String: Any] = ["guid": guid, "version": version, "archiveSHA256": archive,
            "generationID": archive + ":" + configuration, "packageManifest": path, "packageManifestSHA256": profileTestHash(data)]
        var archives = try #require(library["archives"] as? [[String: Any]])
        var entry = mount; entry["status"] = "ready"
        entry["diagnostics"] = [["code": "archive_note", "severity": "info", "message": guid]]
        archives.append(entry); library["archives"] = archives
        if mounted {
            var mounts = try #require(profile["mounts"] as? [[String: Any]])
            var order = try #require(profile["mountOrder"] as? [String])
            mounts.append(mount); order.append(guid)
            profile["mounts"] = mounts; profile["mountOrder"] = order
        }
        return mount
    }

    mutating func editMount(_ edit: (inout [String: Any]) -> Void) throws {
        var mounts = try #require(profile["mounts"] as? [[String: Any]])
        edit(&mounts[0]); profile["mounts"] = mounts
    }

    mutating func editArchive(_ edit: (inout [String: Any]) -> Void) throws {
        var archives = try #require(library["archives"] as? [[String: Any]])
        edit(&archives[0]); library["archives"] = archives
    }

    func write() throws {
        try JSONSerialization.data(withJSONObject: library, options: [.sortedKeys]).write(to: libraryURL)
        try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]).write(to: profileURL)
    }

    func load() throws -> SourceModProfile {
        try write()
        return try SourceModProfile.load(libraryURL: libraryURL)
    }
}

@Test func sourceModProfilePreservesExplicitNativeMountOrderAndDiagnostics() throws {
    let directory = try profileTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModProfileFixture(directory)
    let a = try fixture.addPackage("a"), b = try fixture.addPackage("b")
    fixture.profile["mountOrder"] = ["b", "a"]; fixture.profile["mounts"] = [b, a]
    let loaded = try fixture.load()
    #expect(loaded.mounts.map(\.guid) == ["b", "a"])
    #expect(loaded.library.packages.map { $0.source.guid } == ["b", "a"])
    #expect(loaded.unresolvedConflicts.isEmpty)
    #expect(Set(loaded.diagnostics.map(\.code)) == ["library_note", "profile_note", "archive_note"])
    for order in [["a", "b"], ["b"], ["b", "a", "a"]] {
        fixture.profile["mountOrder"] = order
        #expect(throws: SourceModError.self) { try fixture.load() }
    }
}

@Test func sourceModProfileUnresolvedGUIDKeepsOtherMountsActiveAndRequiresExplicitChoice() throws {
    let directory = try profileTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModProfileFixture(directory)
    let safe = try fixture.addPackage("safe")
    let one = try fixture.addPackage("duplicate", version: "1", mounted: false)
    let two = try fixture.addPackage("duplicate", version: "99", mounted: false)
    let oneHash = try #require(one["archiveSHA256"] as? String), twoHash = try #require(two["archiveSHA256"] as? String)
    fixture.profile["unresolvedConflicts"] = [["guid": "duplicate", "archiveSHA256s": [oneHash, twoHash]]]
    let unresolved = try fixture.load()
    #expect(unresolved.library.packages.map { $0.source.guid } == ["safe"])
    #expect(unresolved.unresolvedConflicts.first?.archiveSHA256s == [oneHash, twoHash])
    fixture.profile["mountOrder"] = ["safe", "duplicate"]; fixture.profile["mounts"] = [safe, one]
    // A GUID cannot be both unresolved and mounted, and two candidates cannot be guessed.
    #expect(throws: SourceModError.self) { try fixture.load() }
    fixture.profile["unresolvedConflicts"] = [] as [[String: Any]]
    #expect(throws: SourceModError.self) { try fixture.load() }
    fixture.profile["choices"] = ["duplicate": oneHash]
    let selected = try fixture.load()
    #expect(selected.library.packages.last?.source.version == "1")
    fixture.profile["mountOrder"] = ["safe"]; fixture.profile["mounts"] = [safe]
    fixture.profile["choices"] = ["duplicate": twoHash]
    fixture.profile["unresolvedConflicts"] = [["guid": "duplicate", "archiveSHA256s": [oneHash]]]
    var archives = try #require(fixture.library["archives"] as? [[String: Any]])
    archives.removeLast(); fixture.library["archives"] = archives
    // An explicit choice that vanished can leave one candidate unresolved without auto-selecting it.
    let vanishedChoice = try fixture.load()
    #expect(vanishedChoice.mounts.map(\.guid) == ["safe"])
    #expect(vanishedChoice.unresolvedConflicts.first?.archiveSHA256s == [oneHash])
}

@Test func sourceModProfileRejectsStaleGenerationHashesAndChangedPackageIdentity() throws {
    let directory = try profileTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    for mutation in ["bytes", "guid", "version", "archiveHash", "generationID", "indexStatus", "indexHash"] {
        var fixture = try ModProfileFixture(directory.appendingPathComponent(mutation))
        let mount = try fixture.addPackage("expected")
        let path = try #require(mount["packageManifest"] as? String)
        let file = fixture.directory.appendingPathComponent(path)
        switch mutation {
        case "bytes":
            try (Data(contentsOf: file) + Data(" ".utf8)).write(to: file)
        case "guid", "version", "archiveHash":
            var package = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var source = try #require(package["source"] as? [String: Any])
            let field = mutation == "archiveHash" ? "archiveSHA256" : mutation
            source[field] = mutation == "archiveHash" ? profileTestHash(Data("wrong archive".utf8)) : "changed"
            package["source"] = source
            let bytes = try JSONSerialization.data(withJSONObject: package)
            try bytes.write(to: file)
            // Update both recorded file hashes, proving package identity is independently checked.
            try fixture.editMount { $0["packageManifestSHA256"] = profileTestHash(bytes) }
            try fixture.editArchive { $0["packageManifestSHA256"] = profileTestHash(bytes) }
        case "generationID": try fixture.editMount { $0["generationID"] = "stale:generation" }
        case "indexStatus": try fixture.editArchive { $0["status"] = "invalid" }
        case "indexHash": try fixture.editArchive { $0["packageManifestSHA256"] = profileTestHash(Data("stale".utf8)) }
        default: break
        }
        #expect(throws: SourceModError.self) { try fixture.load() }
    }
}

@Test func sourceModProfileRejectsChoiceAndConfigurationMismatch() throws {
    let directory = try profileTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModProfileFixture(directory)
    try fixture.addPackage("selected")
    fixture.profile["choices"] = ["selected": profileTestHash(Data("different archive".utf8))]
    #expect(throws: SourceModError.self) { try fixture.load() }
    fixture.profile["choices"] = [:] as [String: String]
    fixture.profile["configurationSHA256"] = profileTestHash(Data("different configuration".utf8))
    #expect(throws: SourceModError.self) { try fixture.load() }
}

@Test func sourceModProfileRejectsUnsafeNamesAndManifestTraversal() throws {
    let directory = try profileTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    var fixture = try ModProfileFixture(directory)
    try fixture.addPackage("selected"); try fixture.write()
    for name in ["", "..", "../default", "a/b", "bad.name", "é", "-bad", String(repeating: "a", count: 65)] {
        #expect(throws: SourceModError.self) { try SourceModProfile.load(libraryURL: fixture.libraryURL, profile: name) }
    }
    for path in ["../outside.json", "/outside.json", "generations/../manifest.json", "generations\\outside.json"] {
        try fixture.editMount { $0["packageManifest"] = path }
        try fixture.editArchive { $0["packageManifest"] = path }
        #expect(throws: SourceModError.self) { try fixture.load() }
    }
}

@Test func sourceModProfileRejectsProfileAndGenerationSymlinkEscapes() throws {
    let directory = try profileTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    for target in ["profile", "generation"] {
        var fixture = try ModProfileFixture(directory.appendingPathComponent(target))
        let mount = try fixture.addPackage("selected"); try fixture.write()
        if target == "profile" {
            let external = directory.appendingPathComponent("outside-profile.json")
            try FileManager.default.copyItem(at: fixture.profileURL, to: external)
            try FileManager.default.removeItem(at: fixture.profileURL)
            try FileManager.default.createSymbolicLink(atPath: fixture.profileURL.path, withDestinationPath: external.path)
        } else {
            let path = try #require(mount["packageManifest"] as? String)
            let generation = fixture.directory.appendingPathComponent(path).deletingLastPathComponent()
            let external = directory.appendingPathComponent("outside-generation")
            try FileManager.default.copyItem(at: generation, to: external)
            try FileManager.default.removeItem(at: generation)
            try FileManager.default.createSymbolicLink(atPath: generation.path, withDestinationPath: external.path)
        }
        #expect(throws: SourceModError.self) { try SourceModProfile.load(libraryURL: fixture.libraryURL) }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IKKOKU_MOD_LIBRARY"] != nil))
func sourceModProfileLoadsImportedLibraryFromEnvironment() throws {
    let path = try #require(ProcessInfo.processInfo.environment["IKKOKU_MOD_LIBRARY"])
    var isDirectory: ObjCBool = false
    try #require(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
    let input = URL(fileURLWithPath: path)
    let loaded = try SourceModProfile.load(libraryURL: isDirectory.boolValue ? input.appendingPathComponent("library.json") : input)
    try #require(!loaded.mounts.isEmpty, "Integration library must contain a selected package.")
    #expect(loaded.library.packages.map { $0.source.guid } == loaded.mounts.map(\.guid))
    for (mount, package) in zip(loaded.mounts, loaded.library.packages) {
        #expect(package.source.archiveSHA256 == mount.archiveSHA256 && package.source.version == mount.version)
        for resource in package.resources {
            let resolved = try #require(try loaded.library.texture(bundlePath: resource.bundlePath, assetName: resource.assetName))
            #expect(!resolved.data.isEmpty)
        }
    }
}
