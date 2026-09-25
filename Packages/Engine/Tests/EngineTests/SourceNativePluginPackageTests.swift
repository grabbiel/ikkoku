import Foundation
import Testing
import Gameplay
import Studio

@Test func sourceNativePluginPackagesRecognizeOnlyVerifiedOriginalAssembliesAndPersistReferences() throws {
    guard let root = ProcessInfo.processInfo.environment["IKKOKU_NATIVE_PLUGIN_PACKAGES"] else { return }
    for (name, guid, adapter) in [("mute-original-v1", "BepInEx.MuteInBackground", SourceNativePluginPackage.muteAdapter),
                                ("accessory-names-original-v1", "KK_StudioAccessoryNames", SourceNativePluginPackage.accessoryAdapter)] {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name + "/manifest.json")
        let package = try SourceNativePluginPackage.load(url: url), reference = SourceNativePluginReference(package: package)
        #expect(package.manifest.identity.guid.utf8.elementsEqual(guid.utf8))
        #expect(package.manifest.adapterID == adapter)
        #expect(try reference.load().manifestSHA256 == package.manifestSHA256)
        if adapter == SourceNativePluginPackage.muteAdapter {
            let config = try #require(package.configuration)
            #expect(try SourceMuteInBackgroundPlugin.readConfiguration(config) == false)
        }
        var scene = StudioDocument(); scene.sourceNativePlugins = [reference]
        let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(scene))
        #expect(decoded == scene)
        #expect(try decoded.sourceNativePlugins?.first?.load().manifestSHA256 == package.manifestSHA256)
    }
}

@Test func sourceNativePluginPackageRejectsChangedVersionAssemblyConfigAndSavedManifest() throws {
    guard let root = ProcessInfo.processInfo.environment["IKKOKU_NATIVE_PLUGIN_PACKAGES"] else { return }
    let from = URL(fileURLWithPath: root).appendingPathComponent("mute-original-v1")
    let to = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-native-adapter-" + UUID().uuidString)
    try FileManager.default.copyItem(at: from, to: to)
    defer { try? FileManager.default.removeItem(at: to) }
    let manifestURL = to.appendingPathComponent("manifest.json"), original = try Data(contentsOf: manifestURL)
    let loaded = try SourceNativePluginPackage.load(url: manifestURL), reference = SourceNativePluginReference(package: loaded)
    try (original + Data([32])).write(to: manifestURL)
    #expect(throws: (any Error).self) { try reference.load() }
    var manifest = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    var identity = manifest["identity"] as! [String: Any]; identity["version"] = "1.2"; manifest["identity"] = identity
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    #expect(throws: (any Error).self) { try SourceNativePluginPackage.load(url: manifestURL) }
    try original.write(to: manifestURL)
    let binary = to.appendingPathComponent("Original.dll"), bytes = try Data(contentsOf: binary)
    try (bytes + Data([0])).write(to: binary)
    #expect(throws: (any Error).self) { try SourceNativePluginPackage.load(url: manifestURL) }
    try bytes.write(to: binary)
    try Data("[Config]\nMute In Background = true\n".utf8).write(to: to.appendingPathComponent("Original.cfg"))
    #expect(throws: (any Error).self) { try SourceNativePluginPackage.load(url: manifestURL) }
}

@Test func sourceNativePluginPackageRejectsUnverifiedAdapterBeforeReadingSource() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-unknown-adapter-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": "ikkoku-native-plugin-adapter", "adapterID": "unknown",
        "type": "Unknown", "identity": ["guid": "Unknown", "name": "Unknown", "version": "1.0"],
        "processes": [], "source": ["file": "missing.dll", "sha256": String(repeating: "a", count: 64)]]).write(to: file)
    #expect(throws: SourcePluginError.self) { try SourceNativePluginPackage.load(url: file) }
}
