import SwiftUI
import Character
import Studio

@main
struct IkkokuApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("Ikkoku") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1180, minHeight: 720)
                .sheet(isPresented: $app.showModLibrary) { ModLibraryView().environment(app) }
        }
        .windowStyle(.titleBar)
        // The commands read narrow Studio values (the scene file, the plugin
        // session), not the whole document, so a document edit does not
        // rebuild the menus.
        .commands {
            let _ = PerfTrace.body(.appCommands)
            CommandGroup(replacing: .newItem) {
                Button("New Female Character") { app.ensureMaker()?.newCharacter(sex: .female) }.keyboardShortcut("n", modifiers: [.command])
                Button("New Male Character") { app.ensureMaker()?.newCharacter(sex: .male) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Open Card…") { app.openCard() }.keyboardShortcut("o", modifiers: [.command])
                Button("Open Source Rig…") { app.openSourceRig() }
                Button("Import Source Card…") { app.importSourceCardSettings() }
                Button("Export Edited Source Card…") { app.exportSourceCard() }
                    .disabled(app.maker?.sourceRigPreview == nil || app.maker?.importedSourceCard == nil)
                Button("Save Card…") { app.saveCard() }.keyboardShortcut("s", modifiers: [.command]).disabled(app.makerShowsSourceRig)
                Divider()
                Button("New Scene") { app.studio?.newScene() }
                Button("Open Scene…") { app.openScene(importing: false) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Import Scene…") { app.openScene(importing: true) }
                Button("Import Model…") { app.importModel() }
                Button("Import CharaStudio Object Layout…") { app.importKoikatsuLayout() }
                Button("Preview CharaStudio Scene…") { app.openSourceScenePreview() }
                Button("Export Edited Original Scene…") { app.exportSourceScene() }.disabled(app.studio?.documentSourceSceneFile == nil)
                Button("Save Scene…") { app.saveScene() }.keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Choose Converted Library…") { app.chooseConvertedLibrary() }
                Button("Forget Converted Library") { app.forgetConvertedLibrary() }
                Divider()
                Button("Capture Screenshot…") { app.captureScreenshot() }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { app.studio?.undo() }.keyboardShortcut("z", modifiers: [.command]).disabled(app.mode != .studio)
                Button("Redo") { app.studio?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(app.mode != .studio)
            }
            CommandMenu("Character") {
                Button("Send to Studio") { if let c = app.ensureMaker()?.card { app.studio?.addCharacter(c); app.mode = .studio } }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(app.makerShowsSourceRig)
                Button("Randomize") { app.ensureMaker()?.randomize() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(app.makerShowsSourceRig)
            }
            CommandMenu("Mods") {
                Button("Open Mod Library…") { app.openModLibrary() }
                Button("Show Mod Library") { app.showModLibrary = true }
                Button("Reload Mod Library") { app.reloadModLibrary() }.disabled(app.modProfile == nil)
                Divider()
                Button("Load Translated Studio Plugins…") { app.studio?.openSourcePluginProfile() }
                    .disabled(app.studio?.sourcePluginCommandsAvailable != true)
                Button("Load Converted Original Plugin…") { app.studio?.openSourceNativePlugin() }.disabled(app.mode != .studio)
                Button(app.studio?.sourcePluginsRunning == true ? "Pause Studio Plugins" : "Run Studio Plugins") {
                    app.studio?.toggleSourcePluginPlayback()
                }.disabled(app.studio?.canToggleSourcePluginPlayback != true)
                Divider()
                Button("Load Bone Modifiers…") { app.openBoneModifiers() }.disabled(!app.makerShowsSourceRig)
                Button("Clear Bone Modifiers") { app.maker?.clearBoneModifiers() }.disabled(app.maker?.sourceBoneModifiers == nil)
            }
            CommandMenu("View") {
                Button("Character Maker") { app.mode = .maker }.keyboardShortcut("1", modifiers: [.command])
                Button("Studio") { app.mode = .studio }.keyboardShortcut("2", modifiers: [.command])
                Divider()
                Button("Show Studio Interface") { app.studio?.revealSourceInterface() }
                    .disabled(app.mode != .studio || app.studio?.sourceInterfaceVisible != false)
                Button("Reset Camera") { app.resetCamera() }.keyboardShortcut("r", modifiers: [.command, .shift])
                // ST-A11: hides the imported scene's map without unloading it.
                Toggle("Show Source Map", isOn: Binding(
                    get: { app.studio?.showSourceMap ?? true },
                    set: { app.studio?.showSourceMap = $0 }))
                    .disabled(app.studio == nil)
                Divider()
                // R1/CMT-04 opt-in: converted source characters draw with the translated
                // original shader programs; unresolved materials stay toon and are listed
                // in the Studio inspector. Off by default.
                Toggle("Live Source Shaders (Experimental)", isOn: Binding(
                    get: { app.studio?.liveSourceShaders ?? false },
                    set: { app.studio?.liveSourceShaders = $0 }))
                    .disabled(app.studio == nil)
            }
        }
    }
}
