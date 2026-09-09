import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.host == nil {
                ContentUnavailableView("Metal is unavailable", systemImage: "exclamationmark.triangle", description: Text(app.errorMessage ?? ""))
            } else {
                switch app.mode {
                case .maker: if let m = app.maker { MakerView(model: m) }
                case .studio: if let s = app.studio { StudioView(model: s) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $app.mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
        .onAppear { app.snapshotWindowIfRequested() }
        .alert("Ikkoku", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK") { app.errorMessage = nil }
        } message: { Text(app.errorMessage ?? "") }
    }
}
