import Foundation
import Testing
import CryptoKit
import Gameplay
import Studio

// P-T02 synthetic plugin library tests. `PluginLibraryFixture` writes libraries in
// the format of Tools/translation/plugin_library.py (its own Python tests cover
// the scanner). Native adapter loading needs the exact original assembly bytes
// (SourceNativePluginPackageTests), so adapter revisions here check graph and
// selection logic, and that stand-in bytes fail verification by name.

private enum PluginLibraryFixture {
    static let hash = String(repeating: "a", count: 64)
    static let muteSource = "e494f24b73fed491d056c3c6a00ee73baf257409877ce8e5b44da1b0494ca96d"
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func directory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-plugin-library-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A valid one-component IR program; `salt` stands for changed source.
    static func program(guid: String, salt: String) throws -> Data {
        let source = sha(Data(("source:" + salt).utf8))
        let method: [String: Any] = ["name": "Update", "symbol": "M:Fixture.Update", "static": false, "returnType": "Void",
                                     "parameters": [], "body": ["kind": "block", "children": []], "lifecycle": "Update"]
        let program: [String: Any] = ["schemaVersion": 1, "status": "ready", "mode": "component", "type": "Fixture",
            "source": ["sha256": source], "identity": ["sourceSHA256": source, "type": "Fixture", "symbols": ["M:Fixture.Update"], "pluginGUID": guid],
            "fields": [], "methods": [method], "semanticSurfaceSHA256": hash, "bridgeSHA256": hash, "emitterSHA256": hash]
        return try JSONSerialization.data(withJSONObject: program, options: [.sortedKeys])
    }
    /// Writes `revisions/<manifestSHA256>/` and returns its generation record.
    static func translated(_ library: URL, guid: String, version: String = "1.0", salt: String = "",
                           dependencies: [[String: Any]] = [], incompatibilities: [String] = []) throws -> [String: Any] {
        let programData = try program(guid: guid, salt: salt)
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-translated-plugin",
            "identity": ["guid": guid, "version": version, "name": guid], "processes": [],
            "dependencies": dependencies, "incompatibilities": incompatibilities,
            "components": [["type": "Fixture", "program": ["file": "program/translation.json", "sha256": sha(programData)]]]]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let manifestSHA = sha(manifestData)
        let directory = library.appendingPathComponent("revisions/\(manifestSHA)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("program"), withIntermediateDirectories: true)
        try programData.write(to: directory.appendingPathComponent("program/translation.json"))
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
        return ["kind": "ikkoku-translated-plugin", "guid": guid, "version": version, "name": guid,
                "manifest": "revisions/\(manifestSHA)/manifest.json", "manifestSHA256": manifestSHA, "packageSHA256": hash,
                "processes": [], "dependencies": dependencies, "incompatibilities": incompatibilities, "types": ["Fixture"],
                "converter": ["id": "ikkoku.translation", "irSchemaVersion": "1", "emitterSHA256": hash, "bridgeSHA256": hash,
                              "semanticSurfaceSHA256": hash],
                "sources": [["rootID": hash, "relativePath": guid]]]
    }
    /// The verified Mute adapter identity with stand-in assembly bytes: its
    /// record joins the graph, but package verification must reject it.
    static func muteStandIn(_ library: URL) throws -> [String: Any] {
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-native-plugin-adapter",
            "adapterID": "bepinex-mute-in-background-v1", "type": "BepInEx.MuteInBackground",
            "identity": ["guid": "BepInEx.MuteInBackground", "name": "Mute In Background", "version": "1.1"], "processes": [],
            "source": ["file": "Original.dll", "sha256": muteSource]]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let manifestSHA = sha(data), directory = library.appendingPathComponent("revisions/\(manifestSHA)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        try Data("MZ stand-in".utf8).write(to: directory.appendingPathComponent("Original.dll"))
        return ["kind": "ikkoku-native-plugin-adapter", "guid": "BepInEx.MuteInBackground", "version": "1.1", "name": "Mute In Background",
                "manifest": "revisions/\(manifestSHA)/manifest.json", "manifestSHA256": manifestSHA, "packageSHA256": hash,
                "processes": [], "dependencies": [], "incompatibilities": [], "types": ["BepInEx.MuteInBackground"],
                "converter": ["id": "ikkoku.native-adapter", "adapterID": "bepinex-mute-in-background-v1", "sourceSHA256": muteSource],
                "sources": []]
    }
    static func existingPackage(_ root: URL, manifestURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL), manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let identity = manifest["identity"] as! [String: String], digest = sha(data)
        try FileManager.default.copyItem(at: manifestURL.deletingLastPathComponent(), to: root.appendingPathComponent("revisions/\(digest)"))
        let kind = manifest["kind"] as! String
        let types: [String], converter: [String: String]
        if kind == "ikkoku-translated-plugin" {
            let package = try SourcePluginPackage.load(url: manifestURL), program = try #require(package.programs.first)
            types = package.programs.map(\.type)
            converter = ["emitterSHA256": program.emitterSHA256, "bridgeSHA256": program.bridgeSHA256, "semanticSurfaceSHA256": program.semanticSurfaceSHA256]
        } else {
            let package = try SourceNativePluginPackage.load(url: manifestURL)
            types = [package.manifest.type]; converter = ["adapterID": package.manifest.adapterID]
        }
        return ["kind": kind, "guid": identity["guid"]!, "version": identity["version"]!, "name": identity["name"]!,
            "manifest": "revisions/\(digest)/manifest.json", "manifestSHA256": digest, "packageSHA256": hash,
            "processes": manifest["processes"]!, "dependencies": manifest["dependencies"] ?? [], "incompatibilities": manifest["incompatibilities"] ?? [],
            "types": types, "converter": converter, "sources": []]
    }
    /// Appends the next numbered generation and commits it in `library.json`.
    @discardableResult
    static func publish(_ library: URL, revisions: [[String: Any]], conflicts explicit: [[String: Any]]? = nil) throws -> Int {
        let pointerURL = library.appendingPathComponent("library.json")
        var records: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: pointerURL.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as? [String: Any]
            records = object?["generations"] as? [[String: Any]] ?? []
        }
        let number = (records.last?["number"] as? Int ?? 0) + 1
        var order: [Data] = [], groups: [Data: [String]] = [:], names: [Data: String] = [:]
        for revision in revisions {
            let guid = revision["guid"] as! String
            let id = Data(guid.utf8)
            if groups[id] == nil { order.append(id); names[id] = guid }
            groups[id, default: []].append(revision["manifestSHA256"] as! String)
        }
        let conflicts = explicit ?? order.compactMap { id -> [String: Any]? in
            guard let hashes = groups[id], hashes.count > 1, let guid = names[id] else { return nil }
            return ["guid": guid, "manifestSHA256s": hashes.sorted()]
        }
        let document: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-plugin-generation", "number": number, "previous": NSNull(),
            "scanner": ["id": "ikkoku.plugin-library", "version": "1.0.0"], "roots": [], "revisions": revisions,
            "conflicts": conflicts, "packages": [], "diagnostics": []]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let digits = String(number)
        let index = "generations/" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits + ".json"
        try FileManager.default.createDirectory(at: library.appendingPathComponent("generations"), withIntermediateDirectories: true)
        try data.write(to: library.appendingPathComponent(index))
        records.append(["number": number, "index": index, "indexSHA256": sha(data)])
        let pointer: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-plugin-library", "current": number, "generations": records,
                                      "roots": [], "scanner": ["id": "ikkoku.plugin-library", "version": "1.0.0"]]
        try JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys]).write(to: pointerURL)
        return number
    }
}

@Test func sourcePluginGraphOrdersTranslatedAndNativeAdapterNodesTogether() throws {
    typealias Node = SourcePluginGraph.Node
    let mute = Node(kind: .nativeAdapter, guid: "BepInEx.MuteInBackground", version: "1.1")
    let accessory = Node(kind: .nativeAdapter, guid: "KK_StudioAccessoryNames", version: "1.1.0", processes: ["CharaStudio"])
    let consumer = Node(kind: .translated, guid: "Creator.Consumer", version: "1.0",
                        dependencies: [.init(guid: "BepInEx.MuteInBackground", minimumVersion: "1.1", required: true),
                                       .init(guid: "KK_StudioAccessoryNames", required: false)])
    #expect(try SourcePluginGraph.order([consumer, accessory, mute], process: "CharaStudio") == [2, 1, 0])
    let newer = Node(kind: .translated, guid: "Creator.Newer", version: "1.0",
                     dependencies: [.init(guid: "BepInEx.MuteInBackground", minimumVersion: "1.2", required: true)])
    #expect(throws: SourcePluginLibraryError.dependencyTooOld(guid: "Creator.Newer", dependency: "BepInEx.MuteInBackground", minimum: "1.2", found: "1.1")) {
        try SourcePluginGraph.order([newer, mute], process: "CharaStudio")
    }
    #expect(throws: SourcePluginLibraryError.missingDependency(guid: "Creator.Consumer", dependency: "BepInEx.MuteInBackground")) {
        try SourcePluginGraph.order([consumer], process: "CharaStudio")
    }
    let impostor = Node(kind: .translated, guid: "BepInEx.MuteInBackground", version: "1.1")
    #expect(throws: SourcePluginLibraryError.duplicateGUID("BepInEx.MuteInBackground")) {
        try SourcePluginGraph.order([mute, impostor], process: "CharaStudio")
    }
    let exclusive = Node(kind: .translated, guid: "Creator.Exclusive", version: "1.0", incompatibilities: ["KK_StudioAccessoryNames"])
    #expect(throws: SourcePluginLibraryError.incompatible(guid: "Creator.Exclusive", other: "KK_StudioAccessoryNames")) {
        try SourcePluginGraph.order([exclusive, accessory], process: "CharaStudio")
    }
    #expect(throws: SourcePluginLibraryError.processMismatch(guid: "KK_StudioAccessoryNames", process: "Koikatu")) {
        try SourcePluginGraph.order([accessory], process: "Koikatu")
    }
    let a = Node(kind: .translated, guid: "A", version: "1.0", dependencies: [.init(guid: "B", required: true)])
    let b = Node(kind: .translated, guid: "B", version: "1.0", dependencies: [.init(guid: "C", required: false)])
    let c = Node(kind: .translated, guid: "C", version: "1.0", dependencies: [.init(guid: "A", required: true)])
    #expect(throws: SourcePluginLibraryError.cycle(["A", "B", "C", "A"])) { try SourcePluginGraph.order([a, b, c], process: "CharaStudio") }
    let many = (0...SourcePluginGraph.maximumNodes).map { Node(kind: .translated, guid: "Plugin.\($0)", version: "1.0") }
    #expect(throws: SourcePluginLibraryError.tooManyPlugins(SourcePluginGraph.maximumNodes + 1)) {
        try SourcePluginGraph.order(many, process: "CharaStudio")
    }
}

@Test func sourcePluginGraphValidatesStandaloneVersionsAndLoaderEdgeCases() throws {
    typealias Node = SourcePluginGraph.Node
    for text in ["1", "1.2.3.4.5", "", "1..2", ".1", "1.", "1.-1", "+1.0", " 1.0", "1.0 ", "v1.0", "1.0-beta",
                 "2147483648.0", "\u{FF11}.0", "1.0\u{301}"] {
        let node = Node(kind: .translated, guid: "Version.Standalone", version: text)
        #expect(throws: SourcePluginLibraryError.invalidVersion(guid: "Version.Standalone", version: text), "\(text)") {
            try SourcePluginGraph.order([node], process: "CharaStudio")
        }
    }
    for text in ["0.0", "01.2", "1.2.3.4", "2147483647.0"] {
        #expect(try SourcePluginGraph.order([Node(kind: .nativeAdapter, guid: "Version.Valid", version: text)], process: "CharaStudio") == [0])
    }
    // A minimum is validated even on an absent soft dependency.
    let soft = Node(kind: .translated, guid: "Version.Minimum", version: "1.0", dependencies: [.init(guid: "Absent", minimumVersion: "v2", required: false)])
    #expect(throws: SourcePluginLibraryError.invalidVersion(guid: "Version.Minimum", version: "v2")) { try SourcePluginGraph.order([soft], process: "CharaStudio") }
    let leadingZero: [UInt32] = [1, 2]
    #expect(SourcePluginGraph.parseVersion("01.2") == leadingZero)
    #expect(!SourcePluginGraph.meets([1, 0], minimum: [1, 0, 0]))
    #expect(SourcePluginGraph.meets([1, 0, 0], minimum: [1, 0]))
    #expect(SourcePluginGraph.meets([1, 10], minimum: [1, 9]))
    // Process filters: literal lowercase ".exe" removal, then case-insensitive.
    #expect(SourcePluginGraph.targets(["CharaStudio.exe"], process: "CharaStudio"))
    #expect(SourcePluginGraph.targets(["CHARASTUDIO"], process: "CharaStudio"))
    #expect(!SourcePluginGraph.targets(["CharaStudio.EXE"], process: "CharaStudio"))
    #expect(SourcePluginGraph.targets(["Koikatu", "CharaStudio"], process: "CharaStudio"))
    #expect(SourcePluginGraph.targets([], process: "Koikatu"))
    // Dependency GUIDs are ordinal: neither case nor canonical equivalence matches.
    let package = Node(kind: .translated, guid: "Creator.Package", version: "0.1")
    let lower = Node(kind: .translated, guid: "Creator.Dependent", version: "1.0", dependencies: [.init(guid: "creator.package", required: true)])
    #expect(throws: SourcePluginLibraryError.missingDependency(guid: "Creator.Dependent", dependency: "creator.package")) {
        try SourcePluginGraph.order([lower, package], process: "CharaStudio")
    }
    let composed = Node(kind: .translated, guid: "Creator.\u{E9}", version: "1.0")
    let decomposed = Node(kind: .translated, guid: "Creator.e\u{301}", version: "1.0")
    let needsDecomposed = Node(kind: .translated, guid: "Creator.Needs", version: "1.0", dependencies: [.init(guid: "Creator.e\u{301}", required: true)])
    #expect(throws: SourcePluginLibraryError.self) { try SourcePluginGraph.order([needsDecomposed, composed], process: "CharaStudio") }
    #expect(try SourcePluginGraph.order([needsDecomposed, composed, decomposed], process: "CharaStudio") == [2, 0, 1])
    // A hard dependency without a minimum accepts any version; a soft minimum is not enforced.
    let anyVersion = Node(kind: .translated, guid: "Creator.Any", version: "1.0", dependencies: [.init(guid: "Creator.Package", required: true)])
    let outdatedSoft = Node(kind: .translated, guid: "Creator.Soft", version: "1.0",
                            dependencies: [.init(guid: "Creator.Package", minimumVersion: "9.0", required: false), .init(guid: "Absent", required: false)])
    #expect(try SourcePluginGraph.order([anyVersion, outdatedSoft, package], process: "CharaStudio") == [2, 0, 1])
    let selfIncompatible = Node(kind: .translated, guid: "Creator.Self", version: "1.0", incompatibilities: ["Creator.Self"])
    #expect(throws: SourcePluginLibraryError.incompatible(guid: "Creator.Self", other: "Creator.Self")) {
        try SourcePluginGraph.order([selfIncompatible], process: "CharaStudio")
    }
    let selfDependent = Node(kind: .translated, guid: "Creator.Loop", version: "1.0", dependencies: [.init(guid: "Creator.Loop", required: false)])
    #expect(throws: SourcePluginLibraryError.cycle(["Creator.Loop", "Creator.Loop"])) { try SourcePluginGraph.order([selfDependent], process: "CharaStudio") }
}

@Test func sourcePluginLibraryProfileOrderingRejectsNonNumericStandaloneVersions() throws {
    let library = try PluginLibraryFixture.directory("profile-versions")
    defer { try? FileManager.default.removeItem(at: library) }
    let beta = try PluginLibraryFixture.translated(library, guid: "Creator.Beta", version: "1.0-beta")
    let release = try PluginLibraryFixture.translated(library, guid: "Creator.Release", version: "1.0")
    let load = { (record: [String: Any]) throws -> SourcePluginPackage in
        try SourcePluginPackage.load(url: library.appendingPathComponent(record["manifest"] as! String))
    }
    let betaPackage = try load(beta), releasePackage = try load(release)
    // Previously accepted when nothing compared it; profiles report SourcePluginError.
    #expect(throws: SourcePluginError.self) { try SourcePluginLibrary(packages: [betaPackage]) }
    #expect(try SourcePluginLibrary(packages: [releasePackage]).packages.count == 1)
    #expect(SourcePluginGraph.Node(package: releasePackage).kind == .translated)
}

@Test func sourcePluginLibrarySelectionKeepsItsGenerationAfterChangedSourceIsPublished() throws {
    let library = try PluginLibraryFixture.directory("generations")
    defer { try? FileManager.default.removeItem(at: library) }
    let libraryURL = library.appendingPathComponent("library.json")
    let dependsOnMute: [[String: Any]] = [["guid": "BepInEx.MuteInBackground", "minimumVersion": "1.1", "required": true]]
    let old = try PluginLibraryFixture.translated(library, guid: "Creator.Mixed_\u{E9}", salt: "one")
    let consumer = try PluginLibraryFixture.translated(library, guid: "Creator.Consumer", dependencies: dependsOnMute)
    let mute = try PluginLibraryFixture.muteStandIn(library)
    #expect(try PluginLibraryFixture.publish(library, revisions: [old, consumer, mute]) == 1)
    let first = try SourcePluginLibraryIndex.load(libraryURL: libraryURL)
    let selection = try first.select(guids: ["Creator.Mixed_\u{E9}"])
    let crossKind = try first.select(guids: ["Creator.Consumer", "BepInEx.MuteInBackground"])
    #expect(try first.resolve(crossKind).map(\.guid) == ["BepInEx.MuteInBackground", "Creator.Consumer"])
    var scene = StudioDocument(); scene.sourcePluginLibrary = selection
    let saved = try JSONEncoder().encode(scene)

    // Changed source: same GUID and version, new program and manifest hashes.
    let changed = try PluginLibraryFixture.translated(library, guid: "Creator.Mixed_\u{E9}", salt: "two")
    let oldSHA = old["manifestSHA256"] as! String, newSHA = changed["manifestSHA256"] as! String
    #expect(oldSHA != newSHA)
    #expect(try PluginLibraryFixture.publish(library, revisions: [changed, consumer, mute]) == 2)
    let reopened = try JSONDecoder().decode(StudioDocument.self, from: saved)
    #expect(reopened == scene)
    let recorded = try #require(reopened.sourcePluginLibrary)
    #expect(recorded.generation == 1 && recorded.revisions.map(\.manifestSHA256) == [oldSHA])
    let resolution = try recorded.resolve()
    #expect(resolution.generation == 1)
    #expect(resolution.translated.map { PluginLibraryFixture.sha($0.manifestData) } == [oldSHA])

    // The newer generation never silently satisfies the saved selection.
    let current = try SourcePluginLibraryIndex.load(libraryURL: libraryURL)
    #expect(current.generation == 2 && current.current == 2)
    var mismatched = false
    do { _ = try current.resolve(recorded) } catch SourcePluginLibraryError.selectionMismatch(_) { mismatched = true }
    #expect(mismatched)
    let repinned = SourcePluginLibrarySelection(libraryFile: recorded.libraryFile, generation: 2,
                                                generationSHA256: current.generationSHA256, revisions: recorded.revisions)
    #expect(throws: SourcePluginLibraryError.revisionUnavailable(guid: "Creator.Mixed_\u{E9}", version: "1.0", manifestSHA256: oldSHA, generation: 2)) {
        try current.resolve(repinned)
    }
    #expect(try current.select(guids: ["Creator.Mixed_\u{E9}"]).revisions.map(\.manifestSHA256) == [newSHA])

    // The adapter record resolves in the graph, but stand-in bytes fail by name.
    var rejectedAdapter = false
    do { _ = try crossKind.resolve() } catch SourcePluginLibraryError.revisionInvalid(let guid, let hash, _) {
        rejectedAdapter = guid == "BepInEx.MuteInBackground" && hash == mute["manifestSHA256"] as? String
    }
    #expect(rejectedAdapter)

    // A deleted revision or a rewritten generation fails with the saved identity.
    try FileManager.default.removeItem(at: library.appendingPathComponent("revisions/\(oldSHA)"))
    #expect(throws: SourcePluginLibraryError.revisionUnavailable(guid: "Creator.Mixed_\u{E9}", version: "1.0", manifestSHA256: oldSHA, generation: 1)) {
        try recorded.resolve()
    }
    let generationOne = library.appendingPathComponent("generations/000001.json")
    try (Data(contentsOf: generationOne) + Data([32])).write(to: generationOne)
    #expect(throws: SourcePluginLibraryError.generationChanged(1)) { try recorded.resolve() }
    #expect(throws: SourcePluginLibraryError.generationUnavailable(3)) { try SourcePluginLibraryIndex.load(libraryURL: libraryURL, generation: 3) }
}

@Test func sourcePluginLibraryConflictsNeedExplicitManifestChoices() throws {
    let library = try PluginLibraryFixture.directory("conflicts")
    defer { try? FileManager.default.removeItem(at: library) }
    let libraryURL = library.appendingPathComponent("library.json")
    let v1 = try PluginLibraryFixture.translated(library, guid: "Shared.GUID", version: "1.0")
    let v2 = try PluginLibraryFixture.translated(library, guid: "Shared.GUID", version: "1.1")
    let composed = try PluginLibraryFixture.translated(library, guid: "Creator.\u{E9}")
    let decomposed = try PluginLibraryFixture.translated(library, guid: "Creator.e\u{301}")
    try PluginLibraryFixture.publish(library, revisions: [v1, v2, composed, decomposed])
    let index = try SourcePluginLibraryIndex.load(libraryURL: libraryURL)
    let hashes = [v1["manifestSHA256"] as! String, v2["manifestSHA256"] as! String].sorted()
    #expect(index.conflicts.count == 1 && index.conflicts.first?.manifestSHA256s == hashes)
    // Neither the higher version nor position chooses a revision.
    #expect(throws: SourcePluginLibraryError.unresolvedConflict(guid: "Shared.GUID", manifestSHA256s: hashes)) {
        try index.select(guids: ["Shared.GUID"])
    }
    let chosen = try index.select(guids: ["Shared.GUID"], choosing: [(guid: "Shared.GUID", manifestSHA256: hashes[0])])
    #expect(chosen.revisions.map(\.manifestSHA256) == [hashes[0]])
    #expect(try index.load(chosen).translated.map { PluginLibraryFixture.sha($0.manifestData) } == [hashes[0]])
    #expect(throws: SourcePluginLibraryError.choiceUnavailable(guid: "Shared.GUID", manifestSHA256: PluginLibraryFixture.hash, generation: 1)) {
        try index.select(guids: ["Shared.GUID"], choosing: [(guid: "Shared.GUID", manifestSHA256: PluginLibraryFixture.hash)])
    }
    #expect(throws: SourcePluginLibraryError.self) {
        try index.select(guids: ["Creator.\u{E9}"], choosing: [(guid: "Shared.GUID", manifestSHA256: hashes[0])])
    }
    #expect(throws: SourcePluginLibraryError.unknownGUID(guid: "shared.guid", generation: 1)) { try index.select(guids: ["shared.guid"]) }
    // Canonically equivalent GUIDs are two identities, not a conflict.
    let both = try index.select(guids: ["Creator.\u{E9}", "Creator.e\u{301}"])
    #expect(Set(both.revisions.map { Data($0.guid.utf8) }).count == 2)
    #expect(throws: SourcePluginLibraryError.duplicateGUID("Creator.\u{E9}")) { try index.select(guids: ["Creator.\u{E9}", "Creator.\u{E9}"]) }
    // Recorded conflicts must equal the recomputed duplicate-GUID groups.
    try PluginLibraryFixture.publish(library, revisions: [v1, v2], conflicts: [])
    #expect(throws: SourcePluginLibraryError.self) { try SourcePluginLibraryIndex.load(libraryURL: libraryURL) }
    #expect(try SourcePluginLibraryIndex.load(libraryURL: libraryURL, generation: 1).revisions.count == 4)
}

@Test func sourcePluginLibraryRejectsChangedRevisionBytesAndMismatchedRecords() throws {
    let library = try PluginLibraryFixture.directory("changed")
    defer { try? FileManager.default.removeItem(at: library) }
    let a = try PluginLibraryFixture.translated(library, guid: "Creator.A")
    var mislabeled = try PluginLibraryFixture.translated(library, guid: "Creator.B")
    mislabeled["version"] = "2.0"
    try PluginLibraryFixture.publish(library, revisions: [a, mislabeled])
    let index = try SourcePluginLibraryIndex.load(libraryURL: library.appendingPathComponent("library.json"))
    let shaA = a["manifestSHA256"] as! String, shaB = mislabeled["manifestSHA256"] as! String
    let recordB = try #require(index.revisions.first { $0.manifestSHA256 == shaB })
    #expect(throws: SourcePluginLibraryError.revisionChanged(guid: "Creator.B", version: "2.0", manifestSHA256: shaB)) {
        try index.loadTranslated(recordB)
    }
    let selection = try index.select(guids: ["Creator.A"])
    #expect(try selection.resolve().translated.count == 1)
    let directory = library.appendingPathComponent("revisions/\(shaA)")
    let programURL = directory.appendingPathComponent("program/translation.json"), program = try Data(contentsOf: programURL)
    try (program + Data([32])).write(to: programURL)
    var invalid = false
    do { _ = try selection.resolve() } catch SourcePluginLibraryError.revisionInvalid(let guid, let hash, _) {
        invalid = guid == "Creator.A" && hash == shaA
    }
    #expect(invalid)
    try program.write(to: programURL)
    let manifestURL = directory.appendingPathComponent("manifest.json"), manifest = try Data(contentsOf: manifestURL)
    try (manifest + Data([32])).write(to: manifestURL)
    #expect(throws: SourcePluginLibraryError.revisionChanged(guid: "Creator.A", version: "1.0", manifestSHA256: shaA)) { try selection.resolve() }
    try manifest.write(to: manifestURL)
    #expect(try selection.resolve().translated.count == 1)
}

@Test func studioDocumentsWithoutLibrarySelectionKeepDecoding() throws {
    var scene = StudioDocument(); scene.name = "Saved before the plugin library"
    let data = try JSONEncoder().encode(scene)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(!object.keys.contains("sourcePluginLibrary"))
    let decoded = try JSONDecoder().decode(StudioDocument.self, from: data)
    #expect(decoded == scene)
    #expect(decoded.sourcePluginLibrary == nil)
    let reference: [String: Any] = ["manifestFile": "/absent/manifest.json", "manifestSHA256": PluginLibraryFixture.hash,
        "guid": "BepInEx.MuteInBackground", "version": "1.1", "adapterID": "bepinex-mute-in-background-v1", "enabled": true]
    object["sourceNativePlugins"] = [reference]
    let legacy = try JSONDecoder().decode(StudioDocument.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.sourceNativePlugins?.first?.adapterID == "bepinex-mute-in-background-v1")
    #expect(legacy.sourcePluginLibrary == nil)
}

@Test func sourceStudioPluginStateRestoresFromImmutableLibraryRevisionAfterNewGeneration() throws {
    let library = try PluginLibraryFixture.directory("session"), profiles = try PluginLibraryFixture.directory("session-profile")
    defer { try? FileManager.default.removeItem(at: library); try? FileManager.default.removeItem(at: profiles) }
    try PluginLibraryFixture.publish(library, revisions: [PluginLibraryFixture.translated(library, guid: "Creator.Motion", salt: "one")])
    let index = try SourcePluginLibraryIndex.load(libraryURL: library.appendingPathComponent("library.json"))
    let revision = try #require(index.revisions.first)
    let object = StudioObject(name: "Target", kind: .folder)
    var document = StudioDocument(); document.objects = [object]
    // A profile names the immutable revision path, never the mutable source package.
    let profile = profiles.appendingPathComponent("profile.json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02, "packages": [["manifest": index.manifestURL(revision).path,
        "bindings": [["type": "Fixture", "objectID": object.id.uuidString]]]]]).write(to: profile)
    let session = try SourceStudioPluginSession(profileURL: profile, document: document)
    document = try session.step(document: session.savedDocument(), deltaTime: 0.02)
    #expect(session.runtime.callbackTrace.count == 1)
    document.sourcePluginLibrary = try index.select(guids: ["Creator.Motion"])
    let saved = try JSONEncoder().encode(document)
    try PluginLibraryFixture.publish(library, revisions: [PluginLibraryFixture.translated(library, guid: "Creator.Motion", salt: "two")])
    let reopened = try JSONDecoder().decode(StudioDocument.self, from: saved)
    let state = try #require(reopened.sourcePluginState)
    let restored = try SourceStudioPluginSession(profileURL: profile, document: reopened, restoring: state)
    #expect(restored.library.packages.map { PluginLibraryFixture.sha($0.manifestData) } == [revision.manifestSHA256])
    #expect(restored.runtime.callbackTrace.isEmpty)
    let selection = try #require(reopened.sourcePluginLibrary)
    let resolution = try selection.resolve()
    #expect(resolution.generation == 1)
    #expect(resolution.translated.map { PluginLibraryFixture.sha($0.manifestData) } == [revision.manifestSHA256])
    #expect(try SourcePluginLibraryIndex.load(libraryURL: library.appendingPathComponent("library.json")).current == 2)
}

@Test func sourceStudioLibrarySessionPersistsBindingsWithoutExternalProfile() throws {
    let root = try PluginLibraryFixture.directory("bound-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try PluginLibraryFixture.translated(root, guid: "Creator.Motion", salt: "first")
    try PluginLibraryFixture.publish(root, revisions: [first])
    let index = try SourcePluginLibraryIndex.load(libraryURL: root.appendingPathComponent("library.json"))
    let selection = try index.select(guids: ["Creator.Motion"])
    var object = StudioObject(name: "Source target", kind: .folder); object.sourceObjectKey = 42
    var document = StudioDocument(); document.objects = [object]; document.sourceSceneSHA256 = PluginLibraryFixture.hash
    let configuration = SourceStudioPluginConfiguration(bindings: [.init(guid: "Creator.Motion", type: "Fixture", sourceObjectKey: 42)])
    document.sourcePluginLibrary = selection; document.sourcePluginLibraryConfiguration = configuration
    let resolution = try selection.resolve()
    let session = try SourceStudioPluginSession(selection: selection, resolution: resolution, configuration: configuration, document: document)
    let stepped = try session.step(document: session.savedDocument(), deltaTime: 0.05)
    let state = try #require(stepped.sourcePluginState)
    #expect(state.profileFile == nil && state.profileSHA256 == nil)
    #expect(state.libraryConfigurationSHA256?.count == 64)
    #expect(state.bindings[0].objectIdentity == "source:\(PluginLibraryFixture.hash)/object/42")
    // A new publication cannot change a document pinned to generation one.
    try PluginLibraryFixture.publish(root, revisions: [PluginLibraryFixture.translated(root, guid: "Creator.Motion", salt: "new")])
    let saved = try JSONEncoder().encode(stepped)
    let reopened = try JSONDecoder().decode(StudioDocument.self, from: saved)
    let restoredSelection = try #require(reopened.sourcePluginLibrary)
    let restored = try SourceStudioPluginSession(selection: restoredSelection, resolution: restoredSelection.resolve(),
        configuration: #require(reopened.sourcePluginLibraryConfiguration), document: reopened, restoring: state)
    #expect(restored.runtime.callbackTrace.isEmpty)
    #expect(try restored.savedDocument() == stepped)
    #expect(restored.runtime.savedClock() == session.runtime.savedClock())
    #expect(try restored.runtime.savedBindings() == session.runtime.savedBindings())
    // Cached evaluation/snapshot needs no library access after installation.
    try FileManager.default.removeItem(at: root)
    let next = try restored.step(document: restored.savedDocument(), deltaTime: 0.02)
    #expect(next.sourcePluginLibrary == selection)
    #expect(throws: (any Error).self) { try selection.resolve() }
}

@Test func sourceStudioLibrarySessionRejectsChangedBindingsOrResolution() throws {
    let root = try PluginLibraryFixture.directory("bound-rejections")
    defer { try? FileManager.default.removeItem(at: root) }
    try PluginLibraryFixture.publish(root, revisions: [PluginLibraryFixture.translated(root, guid: "Creator.Motion")])
    let index = try SourcePluginLibraryIndex.load(libraryURL: root.appendingPathComponent("library.json"))
    let selection = try index.select(guids: ["Creator.Motion"]), resolution = try selection.resolve()
    let object = StudioObject(name: "Target", kind: .folder), other = StudioObject(name: "Other", kind: .folder)
    var document = StudioDocument(); document.objects = [object, other]
    let configuration = SourceStudioPluginConfiguration(bindings: [.init(guid: "Creator.Motion", type: "Fixture", objectID: object.id)])
    let session = try SourceStudioPluginSession(selection: selection, resolution: resolution, configuration: configuration, document: document)
    let saved = try session.savedDocument(), state = try #require(saved.sourcePluginState)
    let changed = SourceStudioPluginConfiguration(bindings: [.init(guid: "Creator.Motion", type: "Fixture", objectID: other.id)])
    #expect(throws: SourcePluginError.self) {
        try SourceStudioPluginSession(selection: selection, resolution: resolution, configuration: changed, document: saved, restoring: state)
    }
    for bindings in [[], configuration.bindings + configuration.bindings,
                     [.init(guid: "Absent", type: "Fixture", objectID: object.id)],
                     [.init(guid: "Creator.Motion", type: "Fixture", sourceObjectKey: 42, objectID: object.id)]] {
        #expect(throws: SourcePluginError.self) {
            try SourceStudioPluginSession(selection: selection, resolution: resolution,
                configuration: .init(bindings: bindings), document: document)
        }
    }
    let empty = try index.select(guids: [])
    #expect(throws: SourcePluginError.self) {
        try SourceStudioPluginSession(selection: empty, resolution: resolution, configuration: configuration, document: document)
    }
    #expect(try session.savedDocument() == saved)
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_NATIVE_PLUGIN_PACKAGES", "IKKOKU_PLUGIN_FIXTURE"]), "Requires original adapter packages and controlled lifecycle fixture"))
func sourceStudioLibraryMixedAdaptersCloneAndDestroyedBindingRoundTrip() throws {
    let root = try PluginLibraryFixture.directory("mixed-clones")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("revisions"), withIntermediateDirectories: true)
    let packages = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_NATIVE_PLUGIN_PACKAGES"))
    let lifecycle = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_PLUGIN_FIXTURE"))
    let records = try [lifecycle, packages.appendingPathComponent("mute-original-v1/manifest.json"),
        packages.appendingPathComponent("accessory-names-original-v1/manifest.json")].map {
            try PluginLibraryFixture.existingPackage(root, manifestURL: $0)
        }
    try PluginLibraryFixture.publish(root, revisions: records)
    let index = try SourcePluginLibraryIndex.load(libraryURL: root.appendingPathComponent("library.json"))
    let selection = try index.select(guids: records.map { $0["guid"] as! String }), resolution = try selection.resolve()
    #expect(resolution.nativeAdapters.count == 2 && resolution.translated.count == 1)
    let program = try #require(resolution.translated.first?.programs.first)
    var target = StudioObject(name: "Original source target", kind: .folder); target.sourceObjectKey = 42
    var document = StudioDocument(); document.objects = [target]; document.sourceSceneSHA256 = PluginLibraryFixture.hash
    let configuration = SourceStudioPluginConfiguration(bindings: [.init(guid: program.identity.pluginGUID!, type: program.type, sourceObjectKey: 42)])
    document.sourcePluginLibrary = selection; document.sourcePluginLibraryConfiguration = configuration
    document.sourceNativePlugins = resolution.nativeAdapters.map { .init(package: $0) }
    let session = try SourceStudioPluginSession(selection: selection, resolution: resolution, configuration: configuration, document: document)
    let cloned = try session.step(document: session.savedDocument(), deltaTime: 0.01)
    #expect(cloned.objects.count == 2)
    #expect(cloned.sourcePluginState?.bindings[1].objectIdentity.contains("source:\(PluginLibraryFixture.hash)/object/42/clone/") == true)
    let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(cloned))
    let restored = try SourceStudioPluginSession(selection: selection, resolution: selection.resolve(), configuration: configuration,
        document: decoded, restoring: decoded.sourcePluginState)
    #expect(restored.runtime.callbackTrace.isEmpty)
    #expect(try restored.savedDocument() == cloned)
    let destroyed = try restored.step(document: decoded, deltaTime: 0.01)
    #expect(destroyed.objects.count == 1 && destroyed.sourcePluginState?.bindings[1].destroyed == true)
    let final = try SourceStudioPluginSession(selection: selection, resolution: selection.resolve(), configuration: configuration,
        document: destroyed, restoring: destroyed.sourcePluginState)
    #expect(try final.savedDocument() == destroyed)
    #expect(destroyed.sourceNativePlugins == document.sourceNativePlugins)
}
