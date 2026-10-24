import SwiftUI
import AppKit
import Gameplay
import Studio

/// Library browsing never changes the mounted generation. Only Mount commits
/// the explicitly chosen revisions and their visible scene-object bindings.
struct PluginLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var index: SourcePluginLibraryIndex?
    @State private var groups: [Group] = []
    @State private var choices: [Data: String] = [:]
    @State private var targets: [Data: UUID] = [:]
    @State private var loading = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?

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
                    .disabled(loading || studio.sourcePluginLibraryPending)
                    HStack {
                        Button("Mount Selection") { mount(studio) }
                            .disabled(app.mode != .studio || loading || studio.sourcePluginLibraryPending || choices.values.allSatisfy(\.isEmpty))
                        Button("Read Latest Generation") { read(index.libraryURL) }
                            .disabled(loading || studio.sourcePluginLibraryPending)
                        if studio.sourcePluginLibraryPending {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { task?.cancel(); studio.cancelSourcePluginLibraryMount() }
                        }
                    }
                } else {
                    Text("Open a converted plugin library to choose its versions and scene targets.")
                    Spacer()
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Open Plugin Library…") { open() }.disabled(loading || studio.sourcePluginLibraryPending)
                    if loading { ProgressView().controlSize(.small) }
                }
            }
        }.padding(24)
        .onDisappear { task?.cancel(); app.studio?.cancelSourcePluginLibraryMount() }
    }

    private func open() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Choose the converted plugin library.json file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read(url)
    }

    private func read(_ url: URL) {
        loading = true; message = nil
        task = Task {
            defer { loading = false }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try SourcePluginLibraryIndex.load(libraryURL: url) }.value
                try Task.checkCancellation()
                index = loaded; choices = [:]; targets = [:]
                let grouped = Dictionary(grouping: loaded.revisions, by: { Data($0.guid.utf8) })
                groups = grouped.map { Group(id: $0.key, name: $0.value[0].name, revisions: $0.value) }
                    .sorted { $0.id.lexicographicallyPrecedes($1.id) }
            } catch is CancellationError { message = "Library inspection cancelled." }
            catch { message = String(describing: error) }
        }
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
            message = nil
            task = Task {
                do {
                    try await studio.mountSourcePluginLibrary(selection: selection, configuration: .init(bindings: bindings))
                    message = studio.status
                } catch is CancellationError { message = "Mount cancelled because the task, scene or active editor changed. Current plugins were retained." }
                catch { message = "Mount failed: \(error)" }
            }
        } catch { message = String(describing: error) }
    }
}
