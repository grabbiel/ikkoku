import Foundation
import CryptoKit
import Testing
import Studio

/// ST-T05a corpus digest (opt-in: IKKOKU_SCENE_CORPUS, a folder of scenes
/// read in place, recursively; AppleDouble `._` files are skipped). Prints
/// one line per scene, named by a 12-hex prefix of its SHA-256, never by
/// file name: its version, a digest of every decoded field
/// (`decodedDescription`) and whether an empty edit exports the input
/// bytes. It uses only APIs the base build has, so one file compares both
/// builds: run it in each and diff the `[corpus]` lines.
private let corpusFolder = ProcessInfo.processInfo.environment["IKKOKU_SCENE_CORPUS"]

@Test(.enabled(if: !(corpusFolder ?? "").isEmpty, "Opt-in corpus digest: IKKOKU_SCENE_CORPUS names a folder of scenes"))
func koikatsuSceneCorpusDigest() throws {
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let root = URL(fileURLWithPath: corpusFolder!)
    let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension.lowercased() == "png" && !$0.lastPathComponent.hasPrefix("._") }
    var lines: [String] = []
    for url in files {
        let data = try Data(contentsOf: url), id = String(hash(data).prefix(12))
        do {
            let document = try KoikatsuSceneReader.decodeDocument(data)
            let decoded = String(hash(Data(decodedDescription(document).utf8)).prefix(16))
            let exported = try document.editedData(SourceSceneEdits())
            lines.append("[corpus] \(id) \(document.snapshot.version) decoded \(decoded) export "
                + (exported == data ? "identical" : "changed \(hash(exported).prefix(12)) \(exported.count) B"))
        } catch {
            lines.append("[corpus] \(id) refused: \(error.localizedDescription.prefix(120))")
        }
    }
    #expect(!lines.isEmpty)
    print(lines.sorted().joined(separator: "\n"))
}

/// Every decoded field of a scene: the object tree, the settings, the
/// trailer and the section ends. Records are walked with `Mirror`;
/// dictionaries are sorted, and byte fields print their length and hash.
/// A route point's aid prints as its key and transform, which is how both
/// the record before ST-T05a (`aid`) and after it (`aidKey`, `aidTransform`)
/// store it.
func decodedDescription(_ document: KoikatsuSceneDocument) -> String {
    corpusDescription(document.snapshot) + "|" + corpusDescription(document.settings) + "|" + corpusDescription(document.trailingData)
        + "|\(document.baseSceneEndOffset)"
}

func corpusDescription(_ value: Any) -> String {
    if let data = value as? Data {
        return "Data(\(data.count),\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)))"
    }
    if let simd = value as? any SIMD { return String(describing: simd) }
    if let text = value as? String { return String(reflecting: text) }
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional: return mirror.children.first.map { corpusDescription($0.value) } ?? "nil"
    case .dictionary, .set:
        return "{" + mirror.children.map { corpusDescription($0.value) }.sorted().joined(separator: ",") + "}"
    case .collection, .tuple:
        return "[" + mirror.children.map { ($0.label.map { "\($0):" } ?? "") + corpusDescription($0.value) }.joined(separator: ",") + "]"
    case .struct, .class:
        var fields: [String] = []
        for child in mirror.children {
            guard let label = child.label else { continue }
            if label == "aid", let aid = child.value as? KoikatsuBoneRecord {
                fields.append("aidKey:" + corpusDescription(aid.sourceKey)); fields.append("aidTransform:" + corpusDescription(aid.transform))
            } else {
                fields.append(label + ":" + corpusDescription(child.value))
            }
        }
        return "\(type(of: value))(" + fields.joined(separator: ",") + ")"
    default:
        return String(describing: value)
    }
}
