import Foundation
import Testing
import Gameplay

@Test func hideStudioUIHasSessionLocalStateAndRecovery() {
    var plugin = SourceHideStudioUIPlugin()
    #expect(plugin.visible)
    #expect(!plugin.toggle())
    #expect(plugin.toggle())
    plugin.toggle(); plugin.reveal(); plugin.reveal()
    #expect(plugin.visible)
    plugin.toggle()
    #expect(SourceHideStudioUIPlugin().visible) // Fresh restore does not persist hidden UI.
}

@Test func hideStudioUIOwnsSpaceWithoutPlaybackOrRepeatFallthrough() {
    typealias Plugin = SourceHideStudioUIPlugin
    #expect(Plugin.shortcutAction(isSpace: true, hasModifiers: false, isRepeat: false, ownsInput: true, mounted: true) == .toggleVisibility)
    #expect(Plugin.shortcutAction(isSpace: true, hasModifiers: false, isRepeat: true, ownsInput: true, mounted: true) == .consume)
    #expect(Plugin.shortcutAction(isSpace: true, hasModifiers: true, isRepeat: false, ownsInput: true, mounted: true) == .unhandled)
    #expect(Plugin.shortcutAction(isSpace: false, hasModifiers: false, isRepeat: false, ownsInput: true, mounted: true) == .continueViewport)
    for mounted in [false, true] {
        for modifiers in [false, true] {
            #expect(Plugin.shortcutAction(isSpace: true, hasModifiers: modifiers, isRepeat: false, ownsInput: false, mounted: mounted) == .unhandled)
        }
    }
    for modifiers in [false, true] {
        for repeatKey in [false, true] {
            #expect(Plugin.shortcutAction(isSpace: true, hasModifiers: modifiers, isRepeat: repeatKey, ownsInput: true, mounted: false) == .continueViewport)
        }
    }
}

@Test func hideStudioUIConfigurationRejectsUnsupportedShortcutsInsteadOfSubstituting() throws {
    let header = "[Keyboard shortcuts]\nHide UI = "
    for value in ["", header + "Space", header + "Other\nHide UI = Space", "[Other]\nHide UI = X"] {
        try SourceHideStudioUIPlugin.validateConfiguration(Data(value.utf8))
    }
    try SourceHideStudioUIPlugin.validateConfiguration(Data([0xef, 0xbb, 0xbf]) + Data((header + "Space").utf8))
    for value in ["", "None", "space", "Space + LeftControl", "Space # comment", "X", "Space\nHide UI = X"] {
        #expect(throws: (any Error).self) {
            try SourceHideStudioUIPlugin.validateConfiguration(Data((header + value).utf8))
        }
    }
    #expect(throws: (any Error).self) { try SourceHideStudioUIPlugin.validateConfiguration(Data([0xff, 0xfe, 32, 0])) }
    #expect(throws: (any Error).self) { try SourceHideStudioUIPlugin.validateConfiguration(Data(repeating: 0, count: 1024 * 1024 + 1)) }
    #expect(throws: (any Error).self) { try SourceHideStudioUIPlugin.validateConfiguration(Data("[ Keyboard shortcuts ]\nHide UI = Space".utf8)) }
}

@Test func hideStudioUIConflictsParticipateInTheMixedPluginGraph() throws {
    typealias Node = SourcePluginGraph.Node
    let adapter = Node(kind: .nativeAdapter, guid: "keelhauled.hideallui", version: "2.3.2",
                       incompatibilities: ["HideStudioUI", "HideHInterface"])
    #expect(try SourcePluginGraph.order([adapter], process: "CharaStudio") == [0])
    for guid in ["HideStudioUI", "HideHInterface"] {
        let conflicting = Node(kind: .translated, guid: guid, version: "1.0")
        #expect(throws: (any Error).self) { try SourcePluginGraph.order([adapter, conflicting], process: "CharaStudio") }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_HIDE_STUDIO_UI_PACKAGE"]), "Requires exact original HideAllUI package"))
func hideStudioUIOriginalPackagePreservesConfigurationAndRejectsChangedIdentity() throws {
    let path = try SourceFixtureSupport.require("IKKOKU_HIDE_STUDIO_UI_PACKAGE")
    let originalURL = URL(fileURLWithPath: path)
    let original = try SourceNativePluginPackage.load(url: originalURL)
    #expect(original.manifest.adapterID == SourceNativePluginPackage.hideStudioUIAdapter)
    #expect(original.manifest.incompatibilities == ["HideStudioUI", "HideHInterface"])
    try SourceHideStudioUIPlugin.validateConfiguration(original.configuration ?? Data())
    let reference = SourceNativePluginReference(package: original)
    #expect(try reference.load().manifestSHA256 == original.manifestSHA256)
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("hide-ui-" + UUID().uuidString)
    try FileManager.default.copyItem(at: originalURL.deletingLastPathComponent(), to: destination)
    defer { try? FileManager.default.removeItem(at: destination) }
    let manifest = destination.appendingPathComponent("manifest.json"), bytes = try Data(contentsOf: manifest)
    var value = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    value["incompatibilities"] = []
    try JSONSerialization.data(withJSONObject: value).write(to: manifest)
    #expect(throws: (any Error).self) { try SourceNativePluginPackage.load(url: manifest) }
    try bytes.write(to: manifest)
    let assembly = destination.appendingPathComponent(original.manifest.source.file)
    try (Data(contentsOf: assembly) + Data([0])).write(to: assembly)
    #expect(throws: (any Error).self) { try SourceNativePluginPackage.load(url: manifest) }
}
