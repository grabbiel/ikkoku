import Foundation

/// One explicit native loader order, produced by the incremental archive importer.
/// A profile can mount valid mods while retaining conflicts for unselected GUIDs.
public struct SourceModProfile: Sendable {
    public struct Conflict: Decodable, Sendable {
        public let guid: String, archiveSHA256s: [String]
    }
    public struct Mount: Decodable, Sendable {
        public let guid: String, version: String, archiveSHA256: String, generationID: String
        public let packageManifest: String, packageManifestSHA256: String
    }
    private struct LibraryDocument: Decodable {
        struct Archive: Decodable {
            let status: String
            let guid: String?, version: String?, archiveSHA256: String?
            let generationID: String?, packageManifest: String?, packageManifestSHA256: String?
            let diagnostics: [SourceModPackage.Diagnostic]?
        }
        let schemaVersion: Int, kind: String, converter: SourceModPackage.Converter
        let configurationSHA256: String, archives: [Archive]
        let diagnostics: [SourceModPackage.Diagnostic]?
    }
    private struct ProfileDocument: Decodable {
        let schemaVersion: Int, kind: String, configurationSHA256: String
        let choices: [String: String], mountOrder: [String], mounts: [Mount]
        let unresolvedConflicts: [Conflict]
        let diagnostics: [SourceModPackage.Diagnostic]?
    }
    public let libraryURL: URL, name: String, library: SourceModLibrary
    public let mounts: [Mount], unresolvedConflicts: [Conflict]
    public let diagnostics: [SourceModPackage.Diagnostic]

    public static func load(libraryURL: URL, profile name: String = "default") throws -> Self {
        guard !name.isEmpty, name.utf8.count <= 64, name.first?.isLetter == true || name.first?.isNumber == true,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw SourceModError.invalid("Mod profile name must contain only letters, digits, hyphens or underscores.")
        }
        let directory = libraryURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let decoder = JSONDecoder()
        let document = try decoder.decode(LibraryDocument.self, from: SourceModPackage.boundedRead(libraryURL, maximum: 32 * 1024 * 1024))
        let profileURL = try SourceModPackage.contained("profiles/\(name).json", directory: directory)
        let profile = try decoder.decode(ProfileDocument.self, from: SourceModPackage.boundedRead(profileURL, maximum: 32 * 1024 * 1024))
        guard document.schemaVersion == 1, document.kind == "ikkoku-mod-library",
              document.converter.id == "ikkoku.zipmod", SourceModPackage.supportsConverter(document.converter.version),
              profile.schemaVersion == 1, profile.kind == "ikkoku-mod-profile",
              SourceModPackage.hashIsValid(document.configurationSHA256), profile.configurationSHA256 == document.configurationSHA256,
              Set(profile.mountOrder).count == profile.mountOrder.count,
              Set(profile.mounts.map(\.guid)).count == profile.mounts.count,
              Set(profile.unresolvedConflicts.map(\.guid)).count == profile.unresolvedConflicts.count else {
            throw SourceModError.invalid("Unsupported or inconsistent mod library/profile; rescan the library.")
        }
        let mounted = Set(profile.mounts.map(\.guid))
        guard profile.mountOrder.filter({ mounted.contains($0) }) == profile.mounts.map(\.guid),
              mounted.isDisjoint(with: profile.unresolvedConflicts.map(\.guid)) else {
            throw SourceModError.invalid("Mod mount order or unresolved conflict selection is inconsistent.")
        }
        var packages: [SourceModPackage] = []
        for mount in profile.mounts {
            let generation = mount.archiveSHA256 + ":" + document.configurationSHA256
            let path = "generations/\(mount.archiveSHA256)/\(document.configurationSHA256)/manifest.json"
            guard SourceModPackage.hashIsValid(mount.archiveSHA256), SourceModPackage.hashIsValid(mount.packageManifestSHA256),
                  mount.generationID == generation, mount.packageManifest == path,
                  profile.choices[mount.guid].map({ $0 == mount.archiveSHA256 }) ?? true,
                  document.archives.contains(where: {
                      $0.status == "ready" && $0.guid == mount.guid && $0.version == mount.version && $0.archiveSHA256 == mount.archiveSHA256
                      && $0.generationID == mount.generationID && $0.packageManifest == mount.packageManifest
                      && $0.packageManifestSHA256 == mount.packageManifestSHA256
                  }) else {
                throw SourceModError.invalid("Mod mount '\(mount.guid)' does not match the current archive index.")
            }
            let candidates = Set(document.archives.filter { $0.status == "ready" && $0.guid == mount.guid }.compactMap(\.archiveSHA256))
            guard candidates.count < 2 || profile.choices[mount.guid] == mount.archiveSHA256 else {
                throw SourceModError.invalid("Conflicting mod '\(mount.guid)' needs an explicit archive choice.")
            }
            let url = try SourceModPackage.contained(mount.packageManifest, directory: directory)
            _ = try SourceModPackage.checkedRead(url, hash: mount.packageManifestSHA256)
            let package = try SourceModPackage.load(url: url)
            guard package.source.guid == mount.guid, package.source.version == mount.version,
                  package.source.archiveSHA256 == mount.archiveSHA256 else {
                throw SourceModError.invalid("Mod package identity differs from the selected generation.")
            }
            packages.append(package)
        }
        for conflict in profile.unresolvedConflicts {
            guard !conflict.guid.isEmpty, !conflict.archiveSHA256s.isEmpty,
                  Set(conflict.archiveSHA256s).count == conflict.archiveSHA256s.count,
                  conflict.archiveSHA256s.allSatisfy(SourceModPackage.hashIsValid) else {
                throw SourceModError.invalid("Invalid unresolved mod conflict.")
            }
        }
        return try Self(libraryURL: libraryURL, name: name, library: SourceModLibrary(packages: packages),
            mounts: profile.mounts, unresolvedConflicts: profile.unresolvedConflicts,
            diagnostics: (document.diagnostics ?? []) + (profile.diagnostics ?? []) + document.archives.flatMap { $0.diagnostics ?? [] })
    }
}
