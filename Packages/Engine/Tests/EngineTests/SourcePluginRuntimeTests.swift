import Foundation
import Testing
import CryptoKit
import simd
import CoreMath
import Gameplay
import Studio

private enum PluginFixture {
    static let hash = String(repeating: "a", count: 64)
    static func node(_ kind: String, _ type: String? = nil, _ name: String? = nil, _ children: [[String: Any]] = [], value: Any? = nil) -> [String: Any] {
        var result: [String: Any] = ["kind": kind, "children": children]
        if let type { result["type"] = type }; if let name { result["name"] = name }; if let value { result["value"] = value }
        return result
    }
    static func literal(_ value: Float) -> [String: Any] { node("literal", "Float", value: value) }
    static func method(_ name: String, _ statements: [[String: Any]]) -> [String: Any] {
        ["name": name, "symbol": "M:Fixture." + name, "static": false, "returnType": "Void", "parameters": [], "body": node("block", nil, nil, statements), "lifecycle": name]
    }
    static func data(_ methods: [[String: Any]], fields: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "status": "ready", "mode": "component", "type": "Fixture", "source": ["sha256": hash],
            "identity": ["sourceSHA256": hash, "type": "Fixture", "symbols": methods.map { $0["symbol"]! }, "pluginGUID": "Original.Mixed_é"],
            "fields": fields, "methods": methods, "semanticSurfaceSHA256": hash, "bridgeSHA256": hash, "emitterSHA256": hash])
    }
    static func motionProgram(fail: Bool) throws -> SourceIRProgram {
        let field = node("field", "Float", "ticks"), transform = node("api", "Transform", "transform")
        let move = node("expression", nil, nil, [node("api", "Void", "translate", [transform, node("api", "Vector3", "vector.one"), node("space", "Space", "World")])])
        let assign = node("assign", "Float", "+=", [field, literal(1)])
        var statements = [assign, move]
        if fail { statements.append(node("expression", nil, nil, [node("call", "Void", "Update")])) }
        return try SourceIRProgram.decode(data([method("Update", statements)], fields: [["name": "ticks", "type": "Float", "initializer": literal(0), "serialized": true]]))
    }
    static func float(_ fields: [String: SourceIRStoredValue], _ name: String) throws -> Float {
        guard case .float(let bits) = fields[name] else { throw SourcePluginError.invalid("Missing fixture float: \(name).") }
        return Float(bitPattern: bits)
    }
    static func package(_ directory: URL, guid: String, version: String = "1.0", dependencies: [[String: Any]] = [], processes: [String] = [], incompatible: [String] = []) throws -> SourcePluginPackage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ir = try #require(JSONSerialization.jsonObject(with: data([method("Update", [])])) as? [String: Any])
        var identity = ir["identity"] as! [String: Any]; identity["pluginGUID"] = guid; ir["identity"] = identity
        let bytes = try JSONSerialization.data(withJSONObject: ir), file = directory.appendingPathComponent("program.json")
        try bytes.write(to: file)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-translated-plugin", "identity": ["guid": guid, "version": version, "name": guid],
            "processes": processes, "dependencies": dependencies, "incompatibilities": incompatible,
            "components": [["type": "Fixture", "program": ["file": "program.json", "sha256": hash]]]]
        let url = directory.appendingPathComponent("manifest.json"); try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        return try SourcePluginPackage.load(url: url)
    }
}

@Test func sourcePluginPackageDependenciesPreserveOrdinalGUIDsAndDotNetVersions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-packages-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try PluginFixture.package(dir.appendingPathComponent("a"), guid: "Creator.é", version: "1.0")
    let b = try PluginFixture.package(dir.appendingPathComponent("b"), guid: "Creator.e\u{301}", dependencies: [["guid": "Creator.é", "required": true, "minimumVersion": "1.0"]])
    let library = try SourcePluginLibrary(packages: [b, a])
    #expect(library.packages.map(\.ordinalGUID) == [Data("Creator.é".utf8), Data("Creator.e\u{301}".utf8)])
    #expect(throws: (any Error).self) { try SourcePluginLibrary(packages: [b]) }
    #expect(throws: (any Error).self) { try SourcePluginLibrary(packages: [a, a]) }
    let newer = try PluginFixture.package(dir.appendingPathComponent("newer"), guid: "Other", dependencies: [["guid": "Creator.é", "required": true, "minimumVersion": "1.0.0"]])
    #expect(throws: (any Error).self) { try SourcePluginLibrary(packages: [a, newer]) } // 1.0 < 1.0.0
    let incompatible = try PluginFixture.package(dir.appendingPathComponent("bad"), guid: "Incompatible", incompatible: ["Creator.é"])
    #expect(throws: (any Error).self) { try SourcePluginLibrary(packages: [a, incompatible]) }
    let gameOnly = try PluginFixture.package(dir.appendingPathComponent("game"), guid: "GameOnly", processes: ["Koikatu"])
    #expect(throws: (any Error).self) { try SourcePluginLibrary(packages: [gameOnly]) }
    let executable = try PluginFixture.package(dir.appendingPathComponent("executable"), guid: "StudioOnly", processes: ["charastudio.exe"])
    #expect(try SourcePluginLibrary(packages: [executable]).packages.count == 1)
    let optional = try PluginFixture.package(dir.appendingPathComponent("optional"), guid: "Optional", dependencies: [["guid": "Creator.é", "required": false, "minimumVersion": "9.0"]])
    #expect(try SourcePluginLibrary(packages: [optional, a]).packages.count == 2)
    let cycleA = try PluginFixture.package(dir.appendingPathComponent("cycle-a"), guid: "CycleA", dependencies: [["guid": "CycleB", "required": true]])
    let cycleB = try PluginFixture.package(dir.appendingPathComponent("cycle-b"), guid: "CycleB", dependencies: [["guid": "CycleA", "required": false]])
    #expect(throws: (any Error).self) { try SourcePluginLibrary(packages: [cycleA, cycleB]) }
}

@Test func sourcePluginPackageRejectsChangedProgramsAndEscapingSymlinks() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-package-files-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let package = try PluginFixture.package(dir.appendingPathComponent("package"), guid: "Original.GUID")
    let file = package.manifestURL.deletingLastPathComponent().appendingPathComponent("program.json"), bytes = try Data(contentsOf: file)
    try (bytes + Data([32])).write(to: file)
    #expect(throws: (any Error).self) { try SourcePluginPackage.load(url: package.manifestURL) }
    let outside = dir.appendingPathComponent("outside.json"); try bytes.write(to: outside)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try SourcePluginPackage.load(url: package.manifestURL) }
}

@Test func sourcePluginCallbackFailureRestoresWorldFieldsClockAndTrace() throws {
    let object = StudioObject(name: "Fixture", kind: .folder)
    var document = StudioDocument(); document.objects = [object]
    let world = try SourceStudioPluginWorld(document: document)
    let runtime = try SourcePluginRuntime(world: world, fixedDeltaTime: 0.02)
    let index = try runtime.attach(program: PluginFixture.motionProgram(fail: true), object: world.object(id: object.id))
    try runtime.start()
    let before = try runtime.savedBindings(), clock = runtime.savedClock(), trace = runtime.callbackTrace
    #expect(throws: (any Error).self) { try runtime.step(deltaTime: 0.03) }
    #expect(world.document == document)
    #expect(try runtime.savedBindings() == before)
    #expect(runtime.savedClock() == clock && runtime.callbackTrace == trace)
    #expect(try PluginFixture.float(runtime.component(at: index).savedFields(), "ticks") == 0)
}

@Test func sourcePluginTransformUsesUnityWorldAndUnscaledSelfTranslation() throws {
    var parent = StudioObject(name: "Parent", kind: .folder)
    parent.transform.position = SIMD3(5, -2, 7); parent.transform.rotation = SIMD3(0, 0, 90); parent.transform.scale = SIMD3(3, 4, 5)
    var child = StudioObject(name: "Child", kind: .folder); child.parent = parent.id; child.transform.position = SIMD3(1, 2, 3)
    var document = StudioDocument(); document.objects = [parent, child]
    let world = try SourceStudioPluginWorld(document: document), object = try world.object(id: child.id)
    let before = object.transform.position
    object.transform.translate(SIMD3(2, 0, 0), relativeTo: .local)
    let expected = UnityCoordinates.direction(parent.transform.quaternion.act(UnityCoordinates.direction(SIMD3(2, 0, 0))))
    #expect(simd_length(object.transform.position - before - expected) < 0.00001)
    object.transform.position = SIMD3(9, 8, 7)
    #expect(simd_length(object.transform.position - SIMD3(9, 8, 7)) < 0.00001)
    try world.checkSourceFault()
    #expect(object.sourceIdentity == "native:\(child.id.uuidString)")
    #expect(world.document.objects[0] == parent)
}

@Test func sourcePluginOriginalAttachmentParticipatesInWorldTransformAndParentWrite() throws {
    let parent = StudioObject(name: "Parent", kind: .folder)
    var child = StudioObject(name: "Attached", kind: .folder); child.parent = parent.id; child.sourceAttachmentPoint = 17
    var document = StudioDocument(); document.objects = [parent, child]
    let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)), point = SIMD3<Float>(1, 2, 3)
    let world = try SourceStudioPluginWorld(document: document, attachment: { _, _ in (Transform.trs(point, rotation, SIMD3(repeating: 1)), rotation) })
    let object = try world.object(id: child.id)
    #expect(object.transform.position == UnityCoordinates.position(point))
    object.transform.position = UnityCoordinates.position(point + SIMD3(2, 0, 0))
    #expect(simd_length(world.document.objects[1].transform.position - rotation.inverse.act(SIMD3(2, 0, 0))) < 0.00001)
    try world.checkSourceFault()
}

@Test func sourcePluginRejectsMalformedIRBeforeExecution() throws {
    let invalid = PluginFixture.node("expression", nil, nil, [PluginFixture.node("api", "Void", "translate")])
    #expect(throws: (any Error).self) { try SourceIRProgram.decode(PluginFixture.data([PluginFixture.method("Update", [invalid])])) }
    let unknown = PluginFixture.node("expression", nil, nil, [PluginFixture.node("api", "Void", "arbitrary.Reflection")])
    #expect(throws: (any Error).self) { try SourceIRProgram.decode(PluginFixture.data([PluginFixture.method("Update", [unknown])])) }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_PLUGIN_FIXTURE"]),
               "Requires IKKOKU_PLUGIN_FIXTURE"))
func sourcePluginRoslynPackageCloneDestroyAndNativeSaveReload() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_PLUGIN_FIXTURE")
    let packageURL = URL(fileURLWithPath: path), package = try SourcePluginPackage.load(url: packageURL)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-plugin-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let object = StudioObject(name: "Original", kind: .folder)
    var document = StudioDocument(); document.objects = [object]
    let profile = directory.appendingPathComponent("profile.json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixedDeltaTime": 0.02, "packages": [["manifest": packageURL.path,
        "bindings": [["type": package.programs[0].type, "objectID": object.id.uuidString]]]]]).write(to: profile)
    let session = try SourceStudioPluginSession(profileURL: profile, document: document)
    document = try session.step(document: session.savedDocument(), deltaTime: 0.01)
    #expect(document.objects.count == 2 && document.objects[0].visible == false)
    let state = try #require(document.sourcePluginState), copy = state.bindings[1]
    #expect(try PluginFixture.float(copy.fields, "publicValue") == 21)
    #expect(try PluginFixture.float(copy.fields, "serializedValue") == 41)
    #expect(try PluginFixture.float(copy.fields, "transientValue") == 3)
    #expect(try PluginFixture.float(copy.fields, "privateValue") == 4)
    #expect(try PluginFixture.float(copy.fields, "copiedPrivate") == 4)
    #expect(copy.started && copy.awake && copy.destroyed == false)
    let events = session.runtime.callbackTrace.map { $0.components(separatedBy: ":").last! }
    #expect(events == ["Awake", "OnEnable", "Start", "Update", "Awake", "OnEnable", "OnDisable", "Start", "LateUpdate"])
    let restored = try SourceStudioPluginSession(profileURL: profile, document: document, restoring: state)
    #expect(restored.runtime.callbackTrace.isEmpty)
    let advanced = try restored.step(document: document, deltaTime: 0.01)
    #expect(advanced.objects.count == 1)
    let destroyed = try #require(advanced.sourcePluginState)
    #expect(destroyed.bindings[1].destroyed == true)
    #expect(try PluginFixture.float(destroyed.bindings[1].fields, "destroys") == 1)
    let trace = restored.runtime.callbackTrace.map { $0.components(separatedBy: ":").last! }
    #expect(trace == ["FixedUpdate", "Update", "OnDisable", "OnDestroy"])
    let encoded = try JSONEncoder().encode(advanced), decoded = try JSONDecoder().decode(StudioDocument.self, from: encoded)
    let final = try SourceStudioPluginSession(profileURL: profile, document: decoded, restoring: decoded.sourcePluginState)
    #expect(try final.savedDocument() == advanced)
    // Source GUID bytes and original object UUID survive cloning and tombstones.
    #expect(final.library.packages[0].manifest.identity.guid.utf8.elementsEqual("Ikkoku.Validation.MixedCase_é".utf8))
    #expect(advanced.objects[0].id == object.id)
}
