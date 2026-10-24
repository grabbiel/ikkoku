import SwiftUI
import AppKit
import Gameplay
import Studio

/// The library read and mount share one panel. A cancelled completion must not
/// replace a successor's message, loading state, or cancellable task handle.
@MainActor @Observable
final class PluginLibraryOperation {
    var loading = false
    var message: String?
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    func begin(loading: Bool = false) -> UUID {
        cancel()
        let id = UUID(); request = id; self.loading = loading
        return id
    }
    func isCurrent(_ id: UUID) -> Bool { request == id }
    func attach(_ task: Task<Void, Never>, to id: UUID) {
        guard isCurrent(id) else { task.cancel(); return }
        self.task = task
    }
    func finish(_ id: UUID, message: String?) {
        guard isCurrent(id) else { return }
        request = nil; task = nil; loading = false; self.message = message
    }
    func cancel(message: String? = nil) {
        request = nil
        let previous = task; task = nil; loading = false; self.message = message
        previous?.cancel()
    }
}

/// Library browsing never changes the mounted generation. Only Mount commits
/// the explicitly chosen revisions and their visible scene-object bindings.
struct PluginLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var index: SourcePluginLibraryIndex?
    @State private var groups: [Group] = []
    @State private var choices: [Data: String] = [:]
    @State private var targets: [Data: UUID] = [:]
    @State private var operation = PluginLibraryOperation()

    private struct Group: Identifiable {
        let id: Data, name: String
        let revisions: [SourcePluginLibraryIndex.Revision]
    }
    private func bindingID(_ revision: SourcePluginLibraryIndex.Revision, _ type: String) -> Data {
        Data((revision.manifestSHA256 + "/" + type).utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Studio plugins").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let studio = app.studio {
                if app.mode != .studio {
                    Text("Switch to Studio to mount plugins in its current scene.")
                    Button("Switch to Studio") { app.mode = .studio }
                }
                if let mounted = studio.doc.sourcePluginLibrary {
                    Text("Mounted generation \(mounted.generation) · \(mounted.revisions.count) plugins").font(.headline)
                    Text(mounted.revisions.map { "\($0.guid) \($0.version)" }.joined(separator: " · "))
                        .font(.caption).textSelection(.enabled)
                    HStack {
                        Button(studio.sourcePluginsRunning ? "Pause" : "Run") { studio.sourcePluginsRunning.toggle() }
                            .disabled(!studio.hasSourcePluginSession)
                        Button("Unload") { studio.unloadSourcePluginLibrary() }
                    }.disabled(app.mode != .studio || studio.sourcePluginLibraryPending)
                }
                if let index {
                    Text("Available generation \(index.generation)").font(.headline)
                    Text("Choose exact versions and scene targets. Mount replaces the current Studio plugins; saved scenes keep these versions.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 5) {
                                    Picker(group.name, selection: Binding(get: { choices[group.id] ?? "" }, set: { choices[group.id] = $0 })) {
                                        Text("Not selected").tag("")
                                        ForEach(group.revisions, id: \.manifestSHA256) { revision in
                                            Text("\(revision.version) · \(revision.manifestSHA256.prefix(8))").tag(revision.manifestSHA256)
                                        }
                                    }
                                    if let revision = group.revisions.first(where: { $0.manifestSHA256 == choices[group.id] }), revision.kind == .translated {
                                        ForEach(revision.types, id: \.self) { type in
                                            Picker("\(type) target", selection: Binding<UUID?>(get: { targets[bindingID(revision, type)] }, set: { targets[bindingID(revision, type)] = $0 })) {
                                                Text("Choose scene object…").tag(nil as UUID?)
                                                ForEach(studio.doc.objects) { object in
                                                    Text(object.name).tag(Optional(object.id))
                                                }
                                            }
                                        }
                                    }
                                    if group.revisions.count > 1 {
                                        Text("Multiple revisions are available. A version must be chosen explicitly.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.padding(.trailing, 8)
                    }
                    .disabled(operation.loading || studio.sourcePluginLibraryPending)
                    HStack {
                        Button("Mount Selection") { mount(studio) }
                            .disabled(app.mode != .studio || operation.loading || studio.sourcePluginLibraryPending || choices.values.allSatisfy(\.isEmpty))
                        Button("Read Latest Generation") { read(index.libraryURL) }
                            .disabled(operation.loading || studio.sourcePluginLibraryPending)
                        if studio.sourcePluginLibraryPending {
                            ProgressView().controlSize(.small)
                            Button("Cancel") {
                                operation.cancel(message: "Mount cancelled. Current plugins were retained.")
                                studio.cancelSourcePluginLibraryMount()
                            }
                        }
                    }
                } else {
                    Text("Open a converted plugin library to choose its versions and scene targets.")
                    Spacer()
                }
                if let message = operation.message { Text(message).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Open Plugin Library…") { open() }.disabled(operation.loading || studio.sourcePluginLibraryPending)
                    if operation.loading { ProgressView().controlSize(.small) }
                }
            }
        }.padding(24)
        .onDisappear { operation.cancel(); app.studio?.cancelSourcePluginLibraryMount() }
    }

    private func open() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Choose the converted plugin library.json file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read(url)
    }

    private func read(_ url: URL) {
        let id = operation.begin(loading: true)
        let task = Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try SourcePluginLibraryIndex.load(libraryURL: url) }.value
                try Task.checkCancellation()
                guard operation.isCurrent(id) else { return }
                index = loaded; choices = [:]; targets = [:]
                let grouped = Dictionary(grouping: loaded.revisions, by: { Data($0.guid.utf8) })
                groups = grouped.map { Group(id: $0.key, name: $0.value[0].name, revisions: $0.value) }
                    .sorted { $0.id.lexicographicallyPrecedes($1.id) }
                operation.finish(id, message: nil)
            } catch is CancellationError { operation.finish(id, message: "Library inspection cancelled.") }
            catch { operation.finish(id, message: String(describing: error)) }
        }
        operation.attach(task, to: id)
    }

    private func mount(_ studio: StudioModel) {
        guard let index else { return }
        do {
            let revisions = groups.compactMap { group in group.revisions.first { $0.manifestSHA256 == choices[group.id] } }
            let selection = try index.select(guids: revisions.map(\.guid), choosing: revisions.map { ($0.guid, $0.manifestSHA256) })
            let bindings = try revisions.filter { $0.kind == .translated }.flatMap { revision in
                try revision.types.map { type -> SourceStudioPluginConfiguration.Binding in
                    guard let id = targets[bindingID(revision, type)], let object = studio.doc.object(id) else {
                        throw SourcePluginError.invalid("Choose a scene target for \(revision.name): \(type).")
                    }
                    return .init(guid: revision.guid, type: type, sourceObjectKey: object.sourceObjectKey,
                                 objectID: object.sourceObjectKey == nil ? id : nil)
                }
            }
            let id = operation.begin()
            let task = Task {
                do {
                    try await studio.mountSourcePluginLibrary(selection: selection, configuration: .init(bindings: bindings))
                    operation.finish(id, message: studio.status)
                } catch is CancellationError { operation.finish(id, message: "Mount cancelled because the task, scene or active editor changed. Current plugins were retained.") }
                catch { operation.finish(id, message: "Mount failed: \(error)") }
            }
            operation.attach(task, to: id)
        } catch { operation.message = String(describing: error) }
    }
}
