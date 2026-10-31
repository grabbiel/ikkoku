import CryptoKit
import Foundation
import Metal
import MetalKit
import Testing
@testable import Renderer

/// Captured loads are positive cases except for the exact synthetic corrupt input
/// from SourcePreviewAppearanceTests. Never infer an expected failure from a load
/// error: losing or corrupting the entire corpus must fail this gate.
private enum TextureCorpus {
    struct Entry: Hashable, Sendable {
        let file: String
        let url: Bool
        let srgb: Bool
        var digest: String { String(file.prefix(64)) }
        var expectsRejection: Bool { !url && srgb && file == TextureCorpus.corruptDigest }
    }

    enum Failure: Error, Equatable {
        case invalidRow(Int), emptyIndex, noPositiveEntries
        case unreadableFile(String), digestMismatch(String), undecodable(String), unexpectedlyDecoded(String)
    }

    // This one data/sRGB row was emitted by the appearance rollback test, not an
    // app texture. Pin the bytes as well as their row identity; no general opt-out.
    static let corruptBytes = Data("not an image".utf8)
    static let corruptDigest = "5464533c9647b67eb320c40ccc5959537c09102ae75388f6a7675b433e745c9d"

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func entries(_ index: String) throws -> [Entry] {
        var unique = Set<Entry>()
        for (offset, line) in index.split(whereSeparator: \.isNewline).enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[1] == "url" || fields[1] == "data",
                  fields[2] == "true" || fields[2] == "false" else { throw Failure.invalidRow(offset + 1) }
            let file = String(fields[0])
            let hash = file.hasSuffix(".png") ? file.dropLast(4) : file[...]
            guard hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidRow(offset + 1)
            }
            unique.insert(Entry(file: file, url: fields[1] == "url", srgb: fields[2] == "true"))
        }
        guard !unique.isEmpty else { throw Failure.emptyIndex }
        guard unique.contains(where: { !$0.expectsRejection }) else { throw Failure.noPositiveEntries }
        return unique.sorted { "\($0.file) \($0.url) \($0.srgb)" < "\($1.file) \($1.url) \($1.srgb)" }
    }

    static func read(_ entry: Entry, files: URL) throws -> Data {
        let data: Data
        do { data = try Data(contentsOf: files.appendingPathComponent(entry.file)) }
        catch { throw Failure.unreadableFile(entry.file) }
        guard digest(data) == entry.digest else { throw Failure.digestMismatch(entry.file) }
        return data
    }

    static func decode(_ data: Data, entry: Entry) throws -> InlineTextureLoader.Image? {
        let image = InlineTextureLoader.image(data: data)
        if entry.expectsRejection {
            guard data == corruptBytes else { throw Failure.digestMismatch(entry.file) }
            guard image == nil else { throw Failure.unexpectedlyDecoded(entry.file) }
            return nil
        }
        guard let image else { throw Failure.undecodable(entry.file) }
        return image
    }

    /// Keep the URL entry point and extension, but make both loaders consume the
    /// verified bytes. A second read of a mutable corpus path is not a pinned input.
    static func snapshot(_ data: Data, entry: Entry, directory: URL) throws -> URL {
        let parent = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent(entry.file)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}

/// `index.tsv` requires hash filename, `url`/`data`, and `true`/`false` sRGB.
/// Optional following fields are capture provenance, not failure expectations.
/// `files/` contains SHA-256-named bytes (URL captures retain a `.png` suffix).
@Test("In-line loads match MetalKit for every texture the suite and the app load",
      .enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_TEXTURE_CORPUS_ROOT"]), "Requires IKKOKU_TEXTURE_CORPUS_ROOT"))
func inlineTextureLoaderMatchesMetalKitForTheCorpus() async throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_TEXTURE_CORPUS_ROOT"), isDirectory: true)
    let index = try String(contentsOf: root.appendingPathComponent("index.tsv"), encoding: .utf8)
    let entries = try TextureCorpus.entries(index)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let files = root.appendingPathComponent("files", isDirectory: true)
    let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("texture-corpus-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: snapshots) }
    let result = await onOwnThread { () -> (mismatches: [String], succeeded: Int, expectedRejections: Int) in
        let loader = MTKTextureLoader(device: device)
        var mismatches: [String] = [], succeeded = 0, expectedRejections = 0
        for entry in entries {
            let name = "\(entry.url ? "file" : "data") \(entry.file) srgb \(entry.srgb)"
            do {
                let data = try TextureCorpus.read(entry, files: files)
                guard let decoded = try TextureCorpus.decode(data, entry: entry) else {
                    expectedRejections += 1
                    continue
                }
                let url = entry.url ? try TextureCorpus.snapshot(data, entry: entry, directory: snapshots) : nil
                let mismatch = TextureIdentityComparison.compare(name: name, image: decoded, url: url, srgb: entry.srgb,
                    device: device, loader: loader, queue: queue, requireSuccess: true)
                if let url {
                    // Detect a changed snapshot as an input failure, even if both
                    // loaders happened to produce the same unexpected result.
                    _ = try TextureCorpus.read(entry, files: url.deletingLastPathComponent())
                }
                if let mismatch { mismatches.append(mismatch.description) }
                else { succeeded += 1 }
            } catch { mismatches.append("\(name): \(error)") }
        }
        return (mismatches, succeeded, expectedRejections)
    }
    let expectedSuccesses = entries.filter { !$0.expectsRejection }.count
    let report = ["entries \(entries.count), succeeded \(result.succeeded)/\(expectedSuccesses), expected rejections \(result.expectedRejections), failures \(result.mismatches.count)"] + result.mismatches
    if let path = ProcessInfo.processInfo.environment["IKKOKU_TEXTURE_CORPUS_REPORT"] {
        try (report.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    #expect(result.succeeded == expectedSuccesses)
    #expect(result.expectedRejections == entries.count - expectedSuccesses)
    #expect(result.mismatches.isEmpty, "\(report.prefix(21).joined(separator: "\n"))")
}

@Suite struct InlineTextureLoaderCorpusValidationTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("texture-corpus-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func png() throws -> Data {
        let image = try #require(TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last, order: [], float: false, width: 3, height: 2))
        return try #require(TextureIdentityCases.encode(image, as: "public.png"))
    }

    @Test("Corpus metadata rejects malformed rows instead of silently skipping or coercing them")
    func strictIndex() throws {
        let hash = String(repeating: "a", count: 64)
        let row = "\(hash)\tdata\ttrue"
        let parsed = try TextureCorpus.entries(row + "\tproducer\tprovenance\n" + row + "\n\(hash).png\turl\tfalse\n")
        #expect(parsed.count == 2)
        #expect(parsed.contains(.init(file: hash, url: false, srgb: true)))
        #expect(parsed.contains(.init(file: hash + ".png", url: true, srgb: false)))
        for invalid in ["\(hash)\tdata", "\(hash)\tunknown\ttrue", "\(hash)\turl\tyes",
                        "../\(hash)\turl\ttrue", "\(hash.uppercased())\turl\ttrue", "\(hash).png/extra\turl\ttrue"] {
            #expect(throws: TextureCorpus.Failure.invalidRow(2)) { try TextureCorpus.entries(row + "\n" + invalid) }
        }
        #expect(throws: TextureCorpus.Failure.emptyIndex) { try TextureCorpus.entries("") }
        #expect(throws: TextureCorpus.Failure.noPositiveEntries) {
            try TextureCorpus.entries("\(TextureCorpus.corruptDigest)\tdata\ttrue")
        }
    }

    @Test("Missing and changed corpus bytes fail before any texture comparison")
    func missingAndChangedFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try png(), hash = TextureCorpus.digest(data)
        for fromURL in [false, true] {
            let entry = TextureCorpus.Entry(file: hash + (fromURL ? ".png" : ""), url: fromURL, srgb: true)
            #expect(throws: TextureCorpus.Failure.unreadableFile(entry.file)) { try TextureCorpus.read(entry, files: root) }
            try Data("damaged".utf8).write(to: root.appendingPathComponent(entry.file))
            #expect(throws: TextureCorpus.Failure.digestMismatch(entry.file)) { try TextureCorpus.read(entry, files: root) }
        }
    }

    @Test("Only the pinned rollback-test negative may be undecodable")
    func rejectsUnrelatedCorruption() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(TextureCorpus.digest(TextureCorpus.corruptBytes) == TextureCorpus.corruptDigest)
        let negative = TextureCorpus.Entry(file: TextureCorpus.corruptDigest, url: false, srgb: true)
        try TextureCorpus.corruptBytes.write(to: root.appendingPathComponent(negative.file))
        #expect(try TextureCorpus.decode(TextureCorpus.read(negative, files: root), entry: negative) == nil)
        let other = Data("unrelated corrupt texture".utf8)
        for fromURL in [false, true] {
            let entry = TextureCorpus.Entry(file: TextureCorpus.digest(other) + (fromURL ? ".png" : ""), url: fromURL, srgb: true)
            try other.write(to: root.appendingPathComponent(entry.file))
            #expect(throws: TextureCorpus.Failure.undecodable(entry.file)) {
                try TextureCorpus.decode(TextureCorpus.read(entry, files: root), entry: entry)
            }
        }
        let wrongFlag = TextureCorpus.Entry(file: negative.file, url: false, srgb: false)
        #expect(throws: TextureCorpus.Failure.undecodable(negative.file)) { try TextureCorpus.decode(TextureCorpus.corruptBytes, entry: wrongFlag) }
    }

    @Test("Both entry points use verified PNG bytes; URL snapshots retain those bytes if the corpus changes")
    func verifiedSnapshots() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try png(), hash = TextureCorpus.digest(data)
        for fromURL in [false, true] {
            let entry = TextureCorpus.Entry(file: hash + (fromURL ? ".png" : ""), url: fromURL, srgb: false)
            let original = root.appendingPathComponent(entry.file)
            try data.write(to: original)
            let verified = try TextureCorpus.read(entry, files: root)
            let image = try #require(TextureCorpus.decode(verified, entry: entry))
            #expect(image.cgImage.width == 3 && image.cgImage.height == 2)
            let snapshot = try TextureCorpus.snapshot(verified, entry: entry, directory: root)
            #expect(snapshot.lastPathComponent == entry.file)
            try Data("changed after verification".utf8).write(to: original)
            #expect(try TextureCorpus.read(entry, files: snapshot.deletingLastPathComponent()) == data)
            #expect(throws: TextureCorpus.Failure.digestMismatch(entry.file)) { try TextureCorpus.read(entry, files: root) }
        }
    }

    @Test("A successful corpus comparison requires both results, while synthetic unsupported layouts still agree")
    func positiveComparisonContract() {
        enum LoadFailure: Error { case decode, upload }
        let good = TextureIdentityRecord(descriptor: "test texture", levels: [Data([1, 2, 3, 4]), Data([5])])
        let success: Result<TextureIdentityRecord, any Error> = .success(good)
        let failed: Result<TextureIdentityRecord, any Error> = .failure(LoadFailure.decode)
        let otherFailure: Result<TextureIdentityRecord, any Error> = .failure(LoadFailure.upload)
        #expect(TextureIdentityComparison.compareRecords(name: "positive", metalKit: success, inline: success, requireSuccess: true) == nil)
        for (oracle, native) in [(failed, failed), (failed, otherFailure), (failed, success), (success, failed)] {
            #expect(TextureIdentityComparison.compareRecords(name: "failure", metalKit: oracle, inline: native, requireSuccess: true) != nil)
        }
        #expect(TextureIdentityComparison.compareRecords(name: "unsupported", metalKit: failed, inline: otherFailure, requireSuccess: false) == nil)
        let changedMip: Result<TextureIdentityRecord, any Error> = .success(.init(descriptor: good.descriptor, levels: [good.levels[0], Data([6])]))
        #expect(TextureIdentityComparison.compareRecords(name: "mip", metalKit: success, inline: changedMip, requireSuccess: true) != nil)
        let changedDescriptor: Result<TextureIdentityRecord, any Error> = .success(.init(descriptor: "different format", levels: good.levels))
        #expect(TextureIdentityComparison.compareRecords(name: "descriptor", metalKit: success, inline: changedDescriptor, requireSuccess: true) != nil)
    }
}
