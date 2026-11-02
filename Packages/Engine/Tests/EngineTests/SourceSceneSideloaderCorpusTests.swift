import Foundation
import CryptoKit
import Testing
import Character
@testable import Studio

// #322 corpus checks. Opt-in: IKKOKU_USER_PLUGIN_SCENES names a read-only copy
// of the install's scenes (on the My Book volume), read in place, recursively;
// AppleDouble `._*` files are skipped. Scenes are named by a 12-hex SHA-256
// prefix, never by file name. Decodes run on an 8 MiB thread: the deepest
// installed scene needs more stack than a test worker has in a Debug build.

enum StaleRecordCorpus {
    static let root = ProcessInfo.processInfo.environment["IKKOKU_USER_PLUGIN_SCENES"].flatMap { $0.isEmpty ? nil : $0 }
    static var enabled: Bool { root != nil }

    static func files() -> [URL] {
        guard let root, let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "png" && !url.lastPathComponent.hasPrefix("._") {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func onLargeStack(_ body: @escaping @Sendable () throws -> Void) throws {
        final class Box: @unchecked Sendable { var error: (any Error)? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let thread = Thread { do { try body() } catch { box.error = error }; done.signal() }
        thread.stackSize = 8 << 20
        thread.start()
        done.wait()
        if let error = box.error { throw error }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The scene's Sideloader entry, when it has a non-nil one.
    static func sideloader(_ document: KoikatsuSceneDocument) -> (SourceSceneKKEx, SourceSceneKKEx.Entry)? {
        guard !document.trailingData.isEmpty, let trailer = try? SourceSceneKKEx.parse(document.trailingData),
              let entry = trailer.entries.first(where: { $0.id == SourceScenePluginData.sideloader && !$0.isNil }) else { return nil }
        return (trailer, entry)
    }
}

/// Byte identity across builds: for each installed scene with a Sideloader
/// entry, the export of an unedited scene, of a delete of its first item in
/// the walk, and of a copy of its first root item without children, printed
/// as a hash of the written file or of the refusal. It uses only APIs the
/// #315 base has, so this one file compares both builds: run it in each and
/// diff the `[stale-corpus]` lines.
@Test(.enabled(if: StaleRecordCorpus.enabled, "Opt-in: IKKOKU_USER_PLUGIN_SCENES names the installed scenes"))
func installedSideloaderScenesExportDigest() throws {
    final class Lines: @unchecked Sendable { var lines: [String] = [] }
    let out = Lines()
    let files = StaleRecordCorpus.files()
    try StaleRecordCorpus.onLargeStack {
        for url in files {
            let data = try Data(contentsOf: url), id = String(StaleRecordCorpus.hash(data).prefix(12))
            guard let document = try? KoikatsuSceneReader.decodeDocument(data), StaleRecordCorpus.sideloader(document) != nil else { continue }
            let walk = SourceSceneInsertionPlan.records(document.snapshot)
            var edits: [(String, SourceSceneEdits)] = [("unedited", SourceSceneEdits())]
            if let item = walk.first(where: { $0.kind == .item }) { edits.append(("delete-item", .init(deletions: [item.sourceKey]))) }
            if let root = document.snapshot.roots.first(where: { $0.kind == .item && $0.children.isEmpty }) {
                edits.append(("copy-root-item", .init(insertions: [.init(.duplicate(of: root.sourceKey))])))
            }
            for (name, edit) in edits {
                let result: String
                do { result = String(StaleRecordCorpus.hash(try document.editedData(edit)).prefix(16)) } catch {
                    result = "refused " + String(StaleRecordCorpus.hash(Data(error.localizedDescription.utf8)).prefix(8))
                }
                out.lines.append("[stale-corpus] \(id) \(name) \(result)")
            }
        }
    }
    #expect(!out.lines.isEmpty, "no scene with a Sideloader entry under IKKOKU_USER_PLUGIN_SCENES")
    print(out.lines.sorted().joined(separator: "\n"))
}
