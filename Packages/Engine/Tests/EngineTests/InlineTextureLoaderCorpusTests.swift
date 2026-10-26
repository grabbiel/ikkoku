import Foundation
import Metal
import MetalKit
import Testing
@testable import Renderer

/// Every texture the strict Engine suite and the app's strict Studio and Maker
/// lanes loaded through `ResourceStore`, captured once by content hash.
/// `IKKOKU_TEXTURE_CORPUS_ROOT/index.tsv` has one line per file, entry point
/// (`url` or `data`) and sRGB flag; `files/` holds the bytes, named by
/// SHA-256. Each entry loads in line and through MetalKit the way the old
/// `ResourceStore` called it: `newTexture(URL:)` for files, ImageIO then
/// `newTexture(cgImage:)` for data.
@Test("In-line loads match MetalKit for every texture the suite and the app load",
      .enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_TEXTURE_CORPUS_ROOT"]), "Requires IKKOKU_TEXTURE_CORPUS_ROOT"))
func inlineTextureLoaderMatchesMetalKitForTheCorpus() async throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_TEXTURE_CORPUS_ROOT"), isDirectory: true)
    let index = try String(contentsOf: root.appendingPathComponent("index.tsv"), encoding: .utf8)
    struct Entry: Hashable, Sendable { let file: String; let url: Bool; let srgb: Bool }
    var unique = Set<Entry>()
    for line in index.split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[1] == "url" || fields[1] == "data" else { continue }
        unique.insert(Entry(file: String(fields[0]), url: fields[1] == "url", srgb: fields[2] == "true"))
    }
    let entries = unique.sorted { "\($0.file) \($0.url) \($0.srgb)" < "\($1.file) \($1.url) \($1.srgb)" }
    #expect(entries.count > 0, "the corpus index lists no textures")
    let device = try #require(MTLCreateSystemDefaultDevice())
    let files = root.appendingPathComponent("files", isDirectory: true)
    let result = await onOwnThread { () -> (mismatches: [String], failedBoth: Int) in
        let loader = MTKTextureLoader(device: device), queue = device.makeCommandQueue()!
        var mismatches: [String] = [], failedBoth = 0
        for entry in entries {
            let url = files.appendingPathComponent(entry.file)
            let name = "\(entry.url ? "file" : "data") \(entry.file) srgb \(entry.srgb)"
            var mismatch: TextureIdentityComparison.Mismatch?
            if entry.url {
                mismatch = TextureIdentityComparison.compare(name: name, image: nil, url: url, srgb: entry.srgb,
                                                             device: device, loader: loader, queue: queue)
            } else if let data = try? Data(contentsOf: url), let decoded = InlineTextureLoader.image(data: data) {
                mismatch = TextureIdentityComparison.compare(name: name, image: decoded, url: nil, srgb: entry.srgb,
                                                             device: device, loader: loader, queue: queue)
            } else {
                failedBoth += 1 // ImageIO cannot decode it: both loaders fail, as `texture(data:)` always did
                continue
            }
            if let mismatch { mismatches.append(mismatch.description) }
        }
        return (mismatches, failedBoth)
    }
    if let path = ProcessInfo.processInfo.environment["IKKOKU_TEXTURE_CORPUS_REPORT"] {
        try ((["entries \(entries.count), undecodable \(result.failedBoth), mismatches \(result.mismatches.count)"] + result.mismatches)
            .joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    #expect(result.mismatches.isEmpty,
            "\(result.mismatches.count) of \(entries.count) corpus loads differ:\n\(result.mismatches.prefix(20).joined(separator: "\n"))")
}
