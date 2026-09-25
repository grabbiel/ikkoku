import SwiftUI
import Assets

struct ModLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Maker mod library").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let profile = app.modProfile {
                Text("\(profile.library.packages.count) mounted mods · \(profile.library.packages.reduce(0) { $0 + $1.resources.count }) converted textures")
                Text("Textures are available to supported material bindings. Catalog entries and plug-ins may need further conversion.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(Array(profile.library.packages.enumerated()), id: \.element.source.guid) { index, package in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index + 1). \(package.source.name.isEmpty ? package.source.guid : package.source.name) · \(package.source.version)").font(.headline)
                            Text("\(package.resources.count) textures · \(package.catalogs.count) catalogs").foregroundStyle(.secondary)
                            ForEach(Array(package.diagnostics.enumerated()), id: \.offset) { _, item in
                                Text(item.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                    ForEach(profile.unresolvedConflicts, id: \.guid) { conflict in
                        VStack(alignment: .leading) {
                            Text("Selection required: \(conflict.guid)").font(.headline)
                            Text("\(conflict.archiveSHA256s.count) archives are available. None matches an unambiguous profile choice.").font(.caption)
                        }
                    }
                    if let catalog = app.modCatalog {
                        ForEach(catalog.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(entry.name) · category \(entry.key.category), item \(entry.key.sourceSlot)").font(.headline)
                                ForEach(Array(app.modDependencies.filter { $0.entry == entry.key && $0.sourceRow == entry.sourceRow && $0.sourcePath == entry.sourcePath }.enumerated()), id: \.offset) { _, dependency in
                                    Text("\(dependency.reference.assetName): \(statusLabel(dependency.status))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(Array(catalog.diagnostics.enumerated()), id: \.offset) { _, item in
                            Text(item.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(profile.diagnostics.enumerated()), id: \.offset) { _, item in
                        Text(item.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Open Library…") { app.openModLibrary() }
                    Button("Reload") { app.reloadModLibrary() }
                    Button("Unload") { app.unloadModLibrary() }
                }
            } else {
                Text("Open an imported mod library to load its selected profile and review conversion results.")
                Button("Open Library…") { app.openModLibrary() }
                Spacer()
            }
        }.padding(24).frame(width: 720, height: 520)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "convertedTexture": "texture converted"
        case "sourceOnly": "source found; conversion needed"
        case "wrongAssetType": "asset type does not match"
        case "ambiguousSourceBundle": "bundle order unknown; reimport archive"
        default: "provider not indexed"
        }
    }
}
