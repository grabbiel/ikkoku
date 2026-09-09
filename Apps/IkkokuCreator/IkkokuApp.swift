import SwiftUI
import Character

@main
struct IkkokuApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("Ikkoku") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Female Character") { app.maker?.newCharacter(sex: .female) }.keyboardShortcut("n", modifiers: [.command])
                Button("New Male Character") { app.maker?.newCharacter(sex: .male) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Open Card…") { app.openCard() }.keyboardShortcut("o", modifiers: [.command])
                Button("Save Card…") { app.saveCard() }.keyboardShortcut("s", modifiers: [.command])
                Divider()
                Button("New Scene") { app.studio?.newScene() }
                Button("Open Scene…") { app.openScene(importing: false) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Import Scene…") { app.openScene(importing: true) }
                Button("Save Scene…") { app.saveScene() }.keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Capture Screenshot…") { app.captureScreenshot() }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { app.studio?.undo() }.keyboardShortcut("z", modifiers: [.command]).disabled(app.mode != .studio)
                Button("Redo") { app.studio?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(app.mode != .studio)
            }
            CommandMenu("Character") {
                Button("Send to Studio") { if let c = app.maker?.card { app.studio?.addCharacter(c); app.mode = .studio } }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Randomize") { app.maker?.randomize() }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                Button("Character Maker") { app.mode = .maker }.keyboardShortcut("1", modifiers: [.command])
                Button("Studio") { app.mode = .studio }.keyboardShortcut("2", modifiers: [.command])
                Divider()
                Button("Reset Camera") { app.resetCamera() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
