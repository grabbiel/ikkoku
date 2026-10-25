import Foundation
import Testing
import CryptoKit
@testable import Gameplay
import Studio
import simd

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
                           dependencies: [[String: Any]] = [], incompatibilities: [String] = [],
                           programData customProgram: Data? = nil) throws -> [String: Any] {
        let programData = try customProgram ?? program(guid: guid, salt: salt)
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

// Pure metadata context for public tests, not an accepted native assembly. The
// app regression separately loads the exact registered HideAllUI package.
private enum DirectPluginGraphFixture {
    static func native(incompatibilities: [String] = ["Creator.Mixed"]) throws -> SourceNativePluginPackage {
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": "ikkoku-native-plugin-adapter",
            "adapterID": "synthetic-graph-context", "type": "Synthetic.Context",
            "identity": ["guid": "Native.Graph.Context", "name": "Synthetic context", "version": "1.0"],
            "processes": [], "incompatibilities": incompatibilities,
            "source": ["file": "unavailable.dll", "sha256": PluginLibraryFixture.hash]])
        return .init(manifest: try JSONDecoder().decode(SourceNativePluginPackage.Manifest.self, from: bytes),
            manifestURL: URL(fileURLWithPath: "/synthetic/manifest.json"), manifestSHA256: PluginLibraryFixture.sha(bytes), configuration: nil)
    }
    static func profile(_ root: URL, dependencies: [[String: Any]] = [], includeDependency: Bool = false)
        throws -> (url: URL, document: StudioDocument, program: URL) {
        var program = try #require(JSONSerialization.jsonObject(with: PluginLibraryFixture.program(guid: "Creator.Mixed", salt: "graph")) as? [String: Any])
        program["fields"] = [["name": "read", "type": "Vector3", "serialized": true,
            "initializer": ["kind": "api", "type": "Vector3", "name": "position", "children": [
                ["kind": "api", "type": "Transform", "name": "transform", "children": []]]]]]
        program["methods"] = [["name": "Awake", "symbol": "M:Fixture.Awake", "static": false, "returnType": "Void",
            "parameters": [], "body": ["kind": "block", "children": []], "lifecycle": "Awake"]]
        var identity = program["identity"] as! [String: Any]; identity["symbols"] = ["M:Fixture.Awake"]; program["identity"] = identity
        let revision = try PluginLibraryFixture.translated(root, guid: "Creator.Mixed", dependencies: dependencies,
            programData: JSONSerialization.data(withJSONObject: program, options: [.sortedKeys]))
        let manifest = root.appendingPathComponent(revision["manifest"] as! String)
        let parent = StudioObject(name: "Parent", kind: .folder)
        var child = StudioObject(name: "Attached", kind: .folder); child.parent = parent.id; child.sourceAttachmentPoint = 17
        var document = StudioDocument(); document.objects = [parent, child]
        func binding(_ manifest: URL) -> [String: Any] {
            ["manifest": manifest.path, "bindings": [["type": "Fixture", "objectID": child.id.uuidString]]]
        }
        var packages = [binding(manifest)]
        if includeDependency {
            let dependency = try PluginLibraryFixture.translated(root, guid: "Creator.Dependency")
            packages.append(binding(root.appendingPathComponent(dependency["manifest"] as! String)))
        }
        let url = root.appendingPathComponent("profile.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02, "packages": packages]).write(to: url)
        return (url, document, manifest.deletingLastPathComponent().appendingPathComponent("program/translation.json"))
    }
}

@Test func sourceStudioDirectNativeGraphRejectsBeforeInitializerAndPreservesCompatibleCallbacks() throws {
    let root = try PluginLibraryFixture.directory("direct-graph-callbacks")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try DirectPluginGraphFixture.profile(root), conflict = try DirectPluginGraphFixture.native()
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1
        return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
    }
    let graphError = SourcePluginLibraryError.incompatible(guid: "Native.Graph.Context", other: "Creator.Mixed")
    do {
        _ = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, nativeContext: [conflict], attachment: attachment)
        Issue.record("A conflicting context reached session construction")
    } catch SourcePluginError.invalid(let reason) { #expect(reason == graphError.description) }
    #expect(reads == 0)
    let ordinary = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, attachment: attachment)
    #expect(reads == 1)
    #expect(ordinary.runtime.callbackTrace.count == 1 && ordinary.runtime.callbackTrace[0].hasSuffix(":Awake"))
    reads = 0
    let compatible = try DirectPluginGraphFixture.native(incompatibilities: ["Other.Plugin"])
    let mixed = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document,
        nativeContext: [compatible], attachment: attachment)
    #expect(reads == 1)
    #expect(try mixed.savedDocument() == ordinary.savedDocument())
    #expect(mixed.runtime.callbackTrace == ordinary.runtime.callbackTrace)
    // Native-after-profile uses this same pure validator against the resident
    // immutable library, without rerunning constructors or touching its session.
    let before = try mixed.savedDocument(), trace = mixed.runtime.callbackTrace
    #expect(throws: graphError) { try mixed.library.validate(nativeAdapters: [conflict]) }
    #expect(reads == 1 && mixed.runtime.callbackTrace == trace)
    #expect(try mixed.savedDocument() == before)
}

@Test func sourceStudioDirectNativeGraphPreservesProfileDependencyAndTamperErrors() throws {
    let root = try PluginLibraryFixture.directory("direct-graph-errors")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try DirectPluginGraphFixture.profile(root, dependencies: [["guid": "Native.Graph.Context", "required": true]])
    let native = try DirectPluginGraphFixture.native()
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1
        return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
    }
    // The separate adapter must not newly satisfy an IR profile dependency, nor
    // hide its existing error behind the later mixed incompatibility check.
    let missing = SourcePluginLibraryError.missingDependency(guid: "Creator.Mixed", dependency: "Native.Graph.Context")
    do {
        _ = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, nativeContext: [native], attachment: attachment)
        Issue.record("A separate native adapter satisfied a profile dependency")
    } catch SourcePluginError.invalid(let reason) { #expect(reason == missing.description) }
    let original = try Data(contentsOf: fixture.program)
    try (original + Data([32])).write(to: fixture.program)
    do {
        _ = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, nativeContext: [native], attachment: attachment)
        Issue.record("A changed program reached mixed graph validation")
    } catch SourcePluginError.invalid(let reason) { #expect(reason == "Translated program hash changed.") }
    #expect(reads == 0)
}

@Test func sourceStudioDirectNativeGraphPreservesTranslatedExecutionOrder() throws {
    let root = try PluginLibraryFixture.directory("direct-graph-order")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try DirectPluginGraphFixture.profile(root, dependencies: [["guid": "Creator.Dependency", "required": true]], includeDependency: true)
    let native = try DirectPluginGraphFixture.native(incompatibilities: [])
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1
        return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
    }
    let ordinary = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, attachment: attachment)
    let mixed = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, nativeContext: [native], attachment: attachment)
    #expect(reads == 2)
    #expect(mixed.library.packages.map { $0.manifest.identity.guid } == ["Creator.Dependency", "Creator.Mixed"])
    #expect(mixed.library.packages.map(\.manifestData) == ordinary.library.packages.map(\.manifestData))
    #expect(mixed.runtime.callbackTrace == ordinary.runtime.callbackTrace)
    #expect(try mixed.savedDocument() == ordinary.savedDocument())
}

@Test func sourceStudioSavedNativeGraphRejectsBeforeInitializerAndRestoresCompatibleContext() throws {
    let root = try PluginLibraryFixture.directory("saved-graph-callbacks")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try DirectPluginGraphFixture.profile(root)
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1
        return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
    }
    let original = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, attachment: attachment)
    let savedDocument = try original.step(document: fixture.document, deltaTime: 0.03)
    let saved = try #require(savedDocument.sourcePluginState)
    #expect(reads == 1)
    reads = 0
    let conflict = try DirectPluginGraphFixture.native()
    let graphError = SourcePluginLibraryError.incompatible(guid: "Native.Graph.Context", other: "Creator.Mixed")
    do {
        _ = try SourceStudioPluginSession(profileURL: fixture.url, document: savedDocument,
            restoring: saved, nativeContext: [conflict], attachment: attachment)
        Issue.record("A conflicting saved context reached session construction")
    } catch SourcePluginError.invalid(let reason) { #expect(reason == graphError.description) }
    #expect(reads == 0)
    #expect(try original.savedDocument() == savedDocument)

    let compatible = try DirectPluginGraphFixture.native(incompatibilities: ["Other.Plugin"])
    let restored = try SourceStudioPluginSession(profileURL: fixture.url, document: savedDocument,
        restoring: saved, nativeContext: [compatible], attachment: attachment)
    #expect(reads == 1)
    #expect(restored.runtime.callbackTrace.isEmpty)
    #expect(try restored.savedDocument() == savedDocument)
    reads = 0
    let ordinary = try SourceStudioPluginSession(profileURL: fixture.url, document: savedDocument,
        restoring: saved, attachment: attachment)
    #expect(reads == 1 && ordinary.runtime.callbackTrace.isEmpty)
    #expect(try ordinary.savedDocument() == savedDocument)
}

@Test func sourceStudioSavedNativeGraphPreservesProfileIdentityErrorBeforeContext() throws {
    let root = try PluginLibraryFixture.directory("saved-graph-profile-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try DirectPluginGraphFixture.profile(root)
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1
        return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
    }
    let original = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, attachment: attachment)
    let savedDocument = try original.savedDocument(), saved = try #require(savedDocument.sourcePluginState)
    let bytes = try Data(contentsOf: fixture.url)
    try (bytes + Data([32, 10])).write(to: fixture.url)
    _ = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url))
    reads = 0
    let conflict = try DirectPluginGraphFixture.native()
    do {
        _ = try SourceStudioPluginSession(profileURL: fixture.url, document: savedDocument,
            restoring: saved, nativeContext: [conflict], attachment: attachment)
        Issue.record("Changed saved profile reached mixed graph construction")
    } catch SourcePluginError.invalid(let reason) {
        #expect(reason == "Saved plugin profile or library bindings changed; explicit reinstallation is required.")
    }
    #expect(reads == 0)
    #expect(try original.savedDocument() == savedDocument)
}

@Test func sourceStudioSavedNativeGraphPreservesPackageIdentityErrorBeforeContext() throws {
    let root = try PluginLibraryFixture.directory("saved-graph-package-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try DirectPluginGraphFixture.profile(root)
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1
        return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
    }
    let original = try SourceStudioPluginSession(profileURL: fixture.url, document: fixture.document, attachment: attachment)
    let savedDocument = try original.savedDocument(), saved = try #require(savedDocument.sourcePluginState)
    let manifest = fixture.program.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("manifest.json")
    let bytes = try Data(contentsOf: manifest)
    try (bytes + Data([32, 10])).write(to: manifest)
    _ = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
    reads = 0
    let conflict = try DirectPluginGraphFixture.native()
    do {
        _ = try SourceStudioPluginSession(profileURL: fixture.url, document: savedDocument,
            restoring: saved, nativeContext: [conflict], attachment: attachment)
        Issue.record("Changed saved package reached mixed graph construction")
    } catch SourcePluginError.invalid(let reason) {
        #expect(reason == "Saved plugin package identity or version changed.")
    }
    #expect(reads == 0)
    #expect(try original.savedDocument() == savedDocument)
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

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_HIDE_STUDIO_UI_PACKAGE"]), "Requires exact original HideAllUI package"))
func sourcePluginLibraryHideStudioUIPreservesPinnedIncompatibilities() throws {
    let root = try PluginLibraryFixture.directory("hide-ui")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("revisions"), withIntermediateDirectories: true)
    let path = try SourceFixtureSupport.require("IKKOKU_HIDE_STUDIO_UI_PACKAGE")
    let revision = try PluginLibraryFixture.existingPackage(root, manifestURL: URL(fileURLWithPath: path))
    try PluginLibraryFixture.publish(root, revisions: [revision])
    let index = try SourcePluginLibraryIndex.load(libraryURL: root.appendingPathComponent("library.json"))
    let selection = try index.select(guids: ["keelhauled.hideallui"])
    let resolved = try selection.resolve()
    #expect(resolved.nativeAdapters.count == 1 && resolved.translated.isEmpty)
    #expect(resolved.nativeAdapters[0].manifest.incompatibilities == ["HideStudioUI", "HideHInterface"])
    var altered = revision; altered["incompatibilities"] = []
    try PluginLibraryFixture.publish(root, revisions: [altered])
    let newer = try SourcePluginLibraryIndex.load(libraryURL: root.appendingPathComponent("library.json"))
    #expect(throws: (any Error).self) { try newer.select(guids: ["keelhauled.hideallui"]).resolve() }
    #expect(try selection.resolve().nativeAdapters[0].manifestSHA256 == resolved.nativeAdapters[0].manifestSHA256)
}


// These constructor fixtures use the same two public session entry points as
// native/history restore. They need no original assets or attachment adapter.
private struct PluginRestoreFixture {
    let profile: URL, selection: SourcePluginLibrarySelection, resolution: SourcePluginLibraryResolution
    let configuration = SourceStudioPluginConfiguration(bindings: [.init(guid: "Creator.Motion", type: "Fixture", sourceObjectKey: 42)])
    static let topologyError = "Restoring plugin initialization changed scene object topology, identities, or clone state."

    init(root: URL, operation: String) throws {
        func node(_ kind: String, _ type: String? = nil, _ name: String? = nil,
                  _ children: [[String: Any]] = [], value: Any? = nil) -> [String: Any] {
            var valueNode: [String: Any] = ["kind": kind, "children": children]
            if let type { valueNode["type"] = type }; if let name { valueNode["name"] = name }
            if let value { valueNode["value"] = value }; return valueNode
        }
        let object = node("api", "Object", "gameObject")
        let clone = node("api", "Object", "world.Instantiate", [object])
        let zero = node("literal", "Float", value: 0)
        let falseValue = node("literal", "Bool", value: false)
        let operationNode: [String: Any]?
        switch operation {
        case "Instantiate", "AwakeInstantiate": operationNode = clone
        case "InstantiateDestroy": operationNode = node("api", "Void", "world.Destroy", [clone])
        case "SetActive": operationNode = node("api", "Void", "setActive", [object, falseValue])
        case "Destroy", "AwakeDestroy": operationNode = node("api", "Void", "world.Destroy", [object])
        default: operationNode = nil
        }
        var program = try #require(JSONSerialization.jsonObject(with: PluginLibraryFixture.program(guid: "Creator.Motion", salt: operation)) as? [String: Any])
        var methods: [[String: Any]], fields: [[String: Any]]
        if operation == "AwakeInstantiate" {
            // Serialized before Instantiate, then copied to the clone, so clone
            // Awake cannot recursively clone itself. Initial hidden input does
            // not run Awake; activating the saved input exercises runtime.start.
            let done = node("field", "Bool", "done")
            fields = [["name": "done", "type": "Bool", "serialized": true, "initializer": falseValue]]
            let body = node("if", nil, nil, [node("unary", "Bool", "!", [done]), node("block", nil, nil, [
                node("assign", "Bool", "=", [done, node("literal", "Bool", value: true)]),
                node("expression", nil, nil, [clone])]), node("empty")])
            methods = [["name": "Awake", "symbol": "M:Fixture.Awake", "static": false, "returnType": "Void", "parameters": [],
                        "body": node("block", nil, nil, [body]), "lifecycle": "Awake"]]
        } else if operation == "AwakeDestroy" {
            fields = []
            methods = ["Awake", "OnEnable", "Start", "OnDisable", "OnDestroy"].map { event in
                ["name": event, "symbol": "M:Fixture.\(event)", "static": false, "returnType": "Void", "parameters": [],
                 "body": node("block", nil, nil, event == "Awake" ? [node("expression", nil, nil, [operationNode!])] : []),
                 "lifecycle": event]
            }
        } else {
            fields = [["name": "value", "type": "Float", "serialized": true,
                       "initializer": node("call", "Float", "Initialize")]]
            let body = (operationNode.map { [node("expression", nil, nil, [$0])] } ?? []) + [node("return", nil, nil, [zero])]
            methods = [["name": "Initialize", "symbol": "M:Fixture.Initialize", "static": false, "returnType": "Float", "parameters": [],
                        "body": node("block", nil, nil, body)]]
        }
        program["fields"] = fields; program["methods"] = methods
        var identity = program["identity"] as! [String: Any]; identity["symbols"] = methods.map { $0["symbol"]! }; program["identity"] = identity
        let bytes = try JSONSerialization.data(withJSONObject: program, options: [.sortedKeys])
        _ = try SourceIRProgram.decode(bytes)
        let revision = try PluginLibraryFixture.translated(root, guid: "Creator.Motion", programData: bytes)
        try PluginLibraryFixture.publish(root, revisions: [revision])
        let index = try SourcePluginLibraryIndex.load(libraryURL: root.appendingPathComponent("library.json"))
        selection = try index.select(guids: ["Creator.Motion"]); resolution = try selection.resolve()
        profile = root.appendingPathComponent("profile.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02,
            "packages": [["manifest": index.manifestURL(try #require(index.revisions.first)).path,
                          "bindings": [["type": "Fixture", "sourceObjectKey": 42]]]]]).write(to: profile)
    }
    func session(_ document: StudioDocument, fromLibrary: Bool, restoring state: SourceStudioPluginState? = nil) throws -> SourceStudioPluginSession {
        if fromLibrary {
            return try SourceStudioPluginSession(selection: selection, resolution: resolution, configuration: configuration,
                document: document, restoring: state)
        }
        return try SourceStudioPluginSession(profileURL: profile, document: document, restoring: state)
    }
    static func document(visible: Bool = true) -> StudioDocument {
        var target = StudioObject(name: "Target", kind: .folder); target.sourceObjectKey = 42; target.visible = visible
        var document = StudioDocument(); document.objects = [target]; document.sourceSceneSHA256 = PluginLibraryFixture.hash
        return document
    }
    func rejectsRestore(_ document: StudioDocument, fromLibrary: Bool) throws {
        do {
            _ = try session(document, fromLibrary: fromLibrary, restoring: #require(document.sourcePluginState))
            Issue.record("Restoring constructor escaped with changed scene topology")
        } catch SourcePluginError.invalid(let reason) { #expect(reason == Self.topologyError) }
    }
    static func pendingState(_ state: SourceStudioPluginState, roots: Any?) throws -> SourceStudioPluginState {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["pendingDestructionRoots"] = roots // nil removes the key, NSNull keeps explicit null.
        return try JSONDecoder().decode(SourceStudioPluginState.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@Test(arguments: [false, true])
func sourcePluginRestoreRejectsInitializerClonesButFreshInstallationRemainsSupported(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("restore-clone")
    defer { try? FileManager.default.removeItem(at: root) }
    for operation in ["Instantiate", "InstantiateDestroy"] {
        let fixture = try PluginRestoreFixture(root: root.appendingPathComponent(operation), operation: operation)
        let fresh = try fixture.session(PluginRestoreFixture.document(), fromLibrary: fromLibrary)
        let saved = try fresh.savedDocument()
        #expect(saved.objects.count == 2 && saved.sourcePluginState?.cloneSerial == 1)
        #expect(fresh.world.pendingSourceDestruction().count == (operation == "InstantiateDestroy" ? 1 : 0))
        try fixture.rejectsRestore(saved, fromLibrary: fromLibrary)
        // The original supported session still continues after the same save.
        let continued = try fresh.step(document: saved, deltaTime: 0.02)
        #expect(continued.objects.count == (operation == "InstantiateDestroy" ? 1 : 2))
        #expect(continued.sourcePluginState?.cloneSerial == 1)
    }
}

@Test(arguments: [false, true])
func sourcePluginRestoreValidatesTopologyAfterActivation(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("restore-awake")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try PluginRestoreFixture(root: root, operation: "AwakeInstantiate")
    let fresh = try fixture.session(PluginRestoreFixture.document(visible: false), fromLibrary: fromLibrary)
    var saved = try fresh.savedDocument()
    #expect(saved.objects.count == 1 && saved.sourcePluginState?.bindings.first?.awake == false)
    saved.objects[0].visible = true
    try fixture.rejectsRestore(saved, fromLibrary: fromLibrary)
    let continued = try fresh.step(document: saved, deltaTime: 0.02)
    #expect(continued.objects.count == 2 && continued.sourcePluginState?.cloneSerial == 1)
    #expect(fresh.runtime.callbackTrace.filter { $0.hasSuffix(":Awake") }.count == 2)
}

@Test(arguments: [false, true])
func sourcePluginRestoreNormalizesMissingUnboundIdentitiesBeforeValidation(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("restore-unbound")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try PluginRestoreFixture(root: root, operation: "noop")
    let fresh = try fixture.session(PluginRestoreFixture.document(), fromLibrary: fromLibrary)
    var saved = try fresh.savedDocument()
    let unbound = StudioObject(name: "Added without a plugin binding", kind: .folder)
    saved.objects.append(unbound)
    let state = try #require(saved.sourcePluginState)
    #expect(state.objectIdentities[unbound.id] == nil)
    let restored = try fixture.session(saved, fromLibrary: fromLibrary, restoring: state)
    #expect(restored.world.identities[unbound.id] == "native:\(unbound.id.uuidString)")
    #expect(restored.world.identities.count == state.objectIdentities.count + 1)
    #expect(restored.world.cloneSerial == state.cloneSerial)
    #expect(try restored.step(document: saved, deltaTime: 0.02).objects == saved.objects)
}

@Test(arguments: [false, true])
func sourcePluginRestorePreservesSameTopologyVisibilityAndPendingDestruction(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("restore-same-topology")
    defer { try? FileManager.default.removeItem(at: root) }
    for operation in ["noop", "SetActive", "Destroy"] {
        let fixture = try PluginRestoreFixture(root: root.appendingPathComponent(operation), operation: operation)
        let fresh = try fixture.session(PluginRestoreFixture.document(), fromLibrary: fromLibrary)
        var saved = try fresh.savedDocument()
        if operation == "SetActive" { saved.objects[0].visible = true } // ordinary input edit wins at the next step
        let restored = try fixture.session(saved, fromLibrary: fromLibrary, restoring: #require(saved.sourcePluginState))
        #expect(restored.world.document.objects.count == 1 && restored.world.cloneSerial == 0)
        #expect(restored.world.pendingSourceDestruction().count == (operation == "Destroy" ? 1 : 0))
        let expected = try fresh.step(document: saved, deltaTime: 0.02)
        let actual = try restored.step(document: saved, deltaTime: 0.02)
        #expect(actual == expected)
        #expect(restored.runtime.savedClock() == fresh.runtime.savedClock())
    }
}

@Test(arguments: [false, true])
func sourcePluginPendingDestructionRestoresAwakeAndSurvivesFailedStep(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("pending-awake")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try PluginRestoreFixture(root: root, operation: "AwakeDestroy")
    let fresh = try fixture.session(PluginRestoreFixture.document(), fromLibrary: fromLibrary)
    let saved = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(fresh.savedDocument()))
    let state = try #require(saved.sourcePluginState)
    #expect(state.pendingDestructionRoots == saved.objects.map(\.id))
    #expect(state.bindings.first?.awake == true && state.bindings.first?.started == false)
    #expect(fresh.runtime.callbackTrace.count == 1 && fresh.runtime.callbackTrace[0].hasSuffix(":Awake"))
    let restored = try fixture.session(saved, fromLibrary: fromLibrary, restoring: state)
    #expect(restored.runtime.callbackTrace.isEmpty)
    #expect(!restored.world.isSourceActive(try restored.world.object(id: saved.objects[0].id)))
    let before = try restored.savedDocument()
    #expect(throws: SourcePluginError.self) {
        _ = try restored.step(document: saved, deltaTime: 0.02, afterUpdate: {
            throw SourcePluginError.runtime("Intentional failed first frame")
        })
    }
    #expect(try restored.savedDocument() == before)
    #expect(restored.runtime.callbackTrace.isEmpty)
    let expected = try fresh.step(document: saved, deltaTime: 0.02)
    let actual = try restored.step(document: saved, deltaTime: 0.02)
    #expect(actual == expected && actual.objects.isEmpty)
    #expect(actual.sourcePluginState?.pendingDestructionRoots == [])
    #expect(actual.sourcePluginState?.bindings.first?.started == false && actual.sourcePluginState?.bindings.first?.destroyed == true)
    #expect(restored.runtime.callbackTrace == Array(fresh.runtime.callbackTrace.dropFirst()))
    #expect(restored.runtime.callbackTrace.count == 1 && restored.runtime.callbackTrace[0].hasSuffix(":OnDestroy"))
    _ = try restored.step(document: actual, deltaTime: 0.02)
    #expect(restored.runtime.callbackTrace.count == 1)
}

@Test(arguments: [false, true])
func sourcePluginPendingDestructionPreservesExactOverlappingAndUnboundRoots(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("pending-subtree")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try PluginRestoreFixture(root: root, operation: "noop")
    var document = PluginRestoreFixture.document()
    let target = document.objects[0]
    var child = StudioObject(name: "Unbound child", kind: .folder); child.parent = target.id
    var grandchild = StudioObject(name: "Unbound grandchild", kind: .folder); grandchild.parent = child.id
    let other = StudioObject(name: "Unbound independent root", kind: .folder)
    document.objects += [child, grandchild, other]
    let fresh = try fixture.session(document, fromLibrary: fromLibrary)
    for id in [other.id, child.id, target.id] { fresh.world.destroy(try fresh.world.object(id: id)) }
    let saved = try fresh.savedDocument(), state = try #require(saved.sourcePluginState)
    let roots = [target.id, child.id, other.id].sorted { $0.uuidString < $1.uuidString }
    #expect(state.pendingDestructionRoots == roots)
    #expect(fresh.world.pendingSourceDestruction().count == 4)
    #expect(!roots.contains(grandchild.id))
    let restored = try fixture.session(saved, fromLibrary: fromLibrary, restoring: state)
    #expect(restored.world.pendingSourceDestructionRoots() == roots)
    #expect(try restored.savedDocument() == saved)
    #expect(try restored.step(document: saved, deltaTime: 0.02) == fresh.step(document: saved, deltaTime: 0.02))

    // A live unbound input added after the snapshot uses normal candidate
    // identity normalization before its persisted root is validated.
    let added = StudioObject(name: "New normalized unbound root", kind: .folder)
    var extended = saved; extended.objects.append(added)
    let extendedState = try PluginRestoreFixture.pendingState(state, roots: (roots + [added.id]).map(\.uuidString))
    #expect(extendedState.objectIdentities[added.id] == nil)
    let normalized = try fixture.session(extended, fromLibrary: fromLibrary, restoring: extendedState)
    #expect(normalized.world.identities[added.id] == "native:\(added.id.uuidString)")
    #expect(Set(normalized.world.pendingSourceDestructionRoots()) == Set(roots + [added.id]))
}

@Test(arguments: [false, true])
func sourcePluginPendingDestructionLegacyNullAndEmptyKeepConstructorPolicy(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("pending-legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let forms: [(String, Any?)] = [("missing", nil), ("null", NSNull()), ("empty", [String]())]
    for operation in ["noop", "Destroy", "AwakeDestroy"] {
        let fixture = try PluginRestoreFixture(root: root.appendingPathComponent(operation), operation: operation)
        let fresh = try fixture.session(PluginRestoreFixture.document(), fromLibrary: fromLibrary)
        let saved = try fresh.savedDocument()
        for (name, roots) in forms {
            let state = try PluginRestoreFixture.pendingState(#require(saved.sourcePluginState), roots: roots)
            #expect(name == "empty" ? state.pendingDestructionRoots == [] : state.pendingDestructionRoots == nil)
            let restored = try fixture.session(saved, fromLibrary: fromLibrary, restoring: state)
            // Constructor Destroy still executes; completed Awake cannot be
            // inferred/replayed from old or explicitly empty persisted state.
            #expect(restored.world.pendingSourceDestructionRoots().count == (operation == "Destroy" ? 1 : 0))
            let continued = try restored.step(document: saved, deltaTime: 0.02)
            #expect(continued.objects.count == (operation == "Destroy" ? 0 : 1))
            #expect(continued.sourcePluginState?.pendingDestructionRoots == [])
            #expect(!restored.runtime.callbackTrace.contains(where: { $0.hasSuffix(":Awake") }))
        }
    }
}

@Test(arguments: [false, true])
func sourcePluginPendingDestructionRejectsMalformedRootsBeforeCallbacks(fromLibrary: Bool) throws {
    let root = try PluginLibraryFixture.directory("pending-invalid")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try PluginRestoreFixture(root: root, operation: "noop")
    var document = PluginRestoreFixture.document()
    let tombstone = StudioObject(name: "Removed unbound object", kind: .folder)
    document.objects.append(tombstone)
    let fresh = try fixture.session(document, fromLibrary: fromLibrary)
    fresh.world.destroy(try fresh.world.object(id: tombstone.id))
    let saved = try fresh.step(document: fresh.savedDocument(), deltaTime: 0.02)
    let target = saved.objects[0].id, state = try #require(saved.sourcePluginState)
    #expect(state.objectIdentities[tombstone.id] != nil && saved.object(tombstone.id) == nil)
    let invalid = [[target.uuidString, target.uuidString.lowercased()], [UUID().uuidString], [tombstone.id.uuidString],
                   Array(repeating: target.uuidString, count: 10001)]
    for roots in invalid {
        let changed = try PluginRestoreFixture.pendingState(state, roots: roots)
        do {
            _ = try fixture.session(saved, fromLibrary: fromLibrary, restoring: changed)
            Issue.record("Invalid saved roots reached a restored session")
        } catch SourcePluginError.invalid(let reason) {
            #expect(reason == "Invalid saved pending destruction roots.")
        }
    }
    #expect(try fresh.savedDocument() == saved)
    // If validation came after callbacks, this constructor would create another
    // clone and the existing topology guard would report a different error.
    let cloning = try PluginRestoreFixture(root: root.appendingPathComponent("cloning"), operation: "Instantiate")
    let cloned = try cloning.session(PluginRestoreFixture.document(), fromLibrary: fromLibrary).savedDocument()
    let malformed = try PluginRestoreFixture.pendingState(#require(cloned.sourcePluginState), roots: [UUID().uuidString])
    do {
        _ = try cloning.session(cloned, fromLibrary: fromLibrary, restoring: malformed)
        Issue.record("Invalid roots escaped validation before constructor replay")
    } catch SourcePluginError.invalid(let reason) { #expect(reason == "Invalid saved pending destruction roots.") }
}

// Synthetic library restore oracle. The app's source-backed diagnostic uses the
// same supported IR shape, but the host here independently counts every read.
private enum LibraryAttachmentRestoreFixture {
    static func make(_ root: URL, poison: Bool = false, attachmentRead: Bool = true) throws
        -> (selection: SourcePluginLibrarySelection, resolution: SourcePluginLibraryResolution,
            configuration: SourceStudioPluginConfiguration, document: StudioDocument, parent: UUID, child: UUID) {
        let guid = "Ikkoku.Validation.LibraryAttachmentRestore"
        var program = try JSONSerialization.jsonObject(with: PluginLibraryFixture.program(guid: guid, salt: "attachment-restore")) as! [String: Any]
        let positive: [String: Any] = ["kind": "binary", "type": "Bool", "name": ">", "children": [
            ["kind": "api", "type": "Float", "name": "deltaTime", "children": []],
            ["kind": "literal", "type": "Float", "value": 0]]]
        let zero: [String: Any] = ["kind": "api", "type": "Vector3", "name": "vector.zero", "children": []]
        let read: [String: Any] = ["kind": "api", "type": "Vector3", "name": "position", "children": [
            ["kind": "api", "type": "Transform", "name": "transform", "children": []]]]
        let gated: [String: Any] = ["kind": "conditional", "type": "Vector3", "children": [positive, attachmentRead ? read : zero, zero]]
        var fields: [[String: Any]] = [
            ["name": "position", "type": "Vector3", "serialized": true, "initializer": gated],
            ["name": "positionAgain", "type": "Vector3", "serialized": false, "initializer": gated]]
        if poison {
            let arithmetic: [String: Any] = ["kind": "binary", "type": "Int32", "name": "+", "children": [
                ["kind": "literal", "type": "Int32", "value": 1], ["kind": "literal", "type": "Int32", "value": 1]]]
            fields.append(["name": "trip", "type": "Int32", "serialized": false, "initializer":
                ["kind": "conditional", "type": "Int32", "children": [positive, arithmetic,
                    ["kind": "literal", "type": "Int32", "value": 0]]]])
        }
        program["fields"] = fields
        let bytes = try JSONSerialization.data(withJSONObject: program, options: [.sortedKeys])
        _ = try SourceIRProgram.decode(bytes)
        let revision = try PluginLibraryFixture.translated(root, guid: guid, programData: bytes)
        try PluginLibraryFixture.publish(root, revisions: [revision])
        let index = try SourcePluginLibraryIndex.load(libraryURL: root.appendingPathComponent("library.json"))
        let selection = try index.select(guids: [guid]), resolution = try selection.resolve()
        let parent = StudioObject(name: "Independent parent", kind: .folder)
        var child = StudioObject(name: "Independent attached child", kind: .folder)
        child.parent = parent.id; child.sourceAttachmentPoint = 17
        let configuration = SourceStudioPluginConfiguration(bindings: [.init(guid: guid, type: "Fixture", objectID: child.id)])
        var document = StudioDocument(); document.objects = [parent, child]
        document.sourcePluginLibrary = selection; document.sourcePluginLibraryConfiguration = configuration
        return (selection, resolution, configuration, document, parent.id, child.id)
    }
}

@Test(arguments: [true, false]) func sourceStudioLibraryRestoreReadsUseSavedClockBeforeAllFieldsRestore(attachmentRead: Bool) throws {
    let root = try PluginLibraryFixture.directory("attachment-restore-clock")
    defer { try? FileManager.default.removeItem(at: root) }
    let f = try LibraryAttachmentRestoreFixture.make(root, attachmentRead: attachmentRead)
    var reads: [(UUID, UUID)] = []
    var matrix = matrix_identity_float4x4; matrix.columns.3 = SIMD4<Float>(7, 11, 13, 1)
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { child, parent in
        reads.append((child.id, parent.id)); return (matrix, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
    }
    let fresh = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
        configuration: f.configuration, document: f.document, attachment: attachment)
    let zero = try fresh.savedDocument(), zeroState = try #require(zero.sourcePluginState)
    #expect(reads.isEmpty && zeroState.clock.deltaTime == 0)
    _ = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
        configuration: f.configuration, document: zero, restoring: zeroState, attachment: attachment)
    #expect(reads.isEmpty)
    let saved = try fresh.step(document: zero, deltaTime: 0.04), state = try #require(saved.sourcePluginState)
    #expect(state.clock.deltaTime == Float(0.04) && state.clock.elapsedTime == Double(Float(0.04)))
    #expect(reads.isEmpty)
    let restored = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
        configuration: f.configuration, document: saved, restoring: state, attachment: attachment)
    #expect(reads.count == (attachmentRead ? 2 : 0))
    #expect(reads.allSatisfy { $0.0 == f.child && $0.1 == f.parent })
    let restoredState = try #require(restored.savedDocument().sourcePluginState)
    #expect(restoredState == state)
    // Native persistence restores *all* fields, unlike clone serialization.
    #expect(restoredState.bindings[0].fields["position"] == .vector([0, 0, 0]))
    #expect(restoredState.bindings[0].fields["positionAgain"] == .vector([0, 0, 0]))
}

@Test(arguments: [true, false]) func sourceStudioLibraryRestorePreservesAttachmentFaultAndLaterThrowOrdering(poison: Bool) throws {
    let root = try PluginLibraryFixture.directory("attachment-restore-error-order")
    defer { try? FileManager.default.removeItem(at: root) }
    let f = try LibraryAttachmentRestoreFixture.make(root, poison: poison)
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1; throw SourcePluginError.invalid("Synthetic installation attachment gate")
    }
    let fresh = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
        configuration: f.configuration, document: f.document, attachment: attachment)
    let saved = try fresh.step(document: f.document, deltaTime: 0.04), state = try #require(saved.sourcePluginState)
    #expect(reads == 0)
    var message: String?
    do {
        _ = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
            configuration: f.configuration, document: saved, restoring: state, attachment: attachment)
    } catch SourcePluginError.invalid(let reason) { message = reason }
    // Each API expression checks the recorded host fault immediately. The
    // second read and the later poison initializer are never evaluated here.
    #expect(reads == 1)
    #expect(message == "Synthetic installation attachment gate")
    #expect(try fresh.savedDocument() == saved)
    if poison {
        reads = 0; message = nil
        let successful: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
            reads += 1; return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
        }
        do {
            _ = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
                configuration: f.configuration, document: saved, restoring: state, attachment: successful)
        } catch SourcePluginError.runtime(let reason) { message = reason }
        #expect(reads == 2)
        #expect(message == "Unsupported arithmetic operator or Int32 arithmetic.")
        #expect(try fresh.savedDocument() == saved)
    }
}

@Test func sourceStudioLibraryRestoreChangedBindingsRejectBeforeInitializerReads() throws {
    let root = try PluginLibraryFixture.directory("attachment-restore-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let f = try LibraryAttachmentRestoreFixture.make(root)
    var reads = 0
    let attachment: SourceStudioPluginWorld.AttachmentResolver = { _, _ in
        reads += 1; return (matrix_identity_float4x4, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
    }
    let fresh = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
        configuration: f.configuration, document: f.document, attachment: attachment)
    let saved = try fresh.step(document: f.document, deltaTime: 0.04), state = try #require(saved.sourcePluginState)
    let changed = SourceStudioPluginConfiguration(fixedDeltaTime: 0.03, bindings: f.configuration.bindings)
    var reason: String?
    do {
        _ = try SourceStudioPluginSession(selection: f.selection, resolution: f.resolution,
            configuration: changed, document: saved, restoring: state, attachment: attachment)
    } catch SourcePluginError.invalid(let message) { reason = message }
    #expect(reason == "Saved plugin profile or library bindings changed; explicit reinstallation is required.")
    #expect(reads == 0)
    #expect(try fresh.savedDocument() == saved)
}
