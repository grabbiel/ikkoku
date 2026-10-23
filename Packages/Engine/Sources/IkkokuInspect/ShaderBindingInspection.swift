import Foundation
import CryptoKit
import Character
import Renderer
import Scene

/// `ikkoku-inspect shader-bindings`: derives the native shader binding set for
/// a card and, when an original-player capture is given, compares it with the
/// inputs the translated probe binds from that capture. The capture is read
/// only after the derivation has finished, and only by the comparison.
func inspectShaderBindings(cardURL: URL, libraryURL: URL, headContractURL: URL, programsURL: URL, frameURL: URL?, supplementURL: URL? = nil,
                           substitutedFrameURL: URL? = nil) throws -> [String: Any] {
    func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let card = try SourceCharacterCard.load(url: cardURL)
    let library = try SourceMakerLibrary.load(url: libraryURL)
    let headContract = try Data(contentsOf: headContractURL)
    let catalog = try SourceShaderProgramCatalog.load(directory: programsURL)
    let libraryData = try Data(contentsOf: libraryURL)
    let supplement = try supplementURL.map { try Data(contentsOf: $0) }
    var provenance = ["card": cardURL.path, "cardSHA256": sha256(try Data(contentsOf: cardURL)), "makerLibrarySHA256": sha256(libraryData),
                      "headContract": headContractURL.path, "headContractSHA256": sha256(headContract), "programs": programsURL.path]
    if let supplementURL { provenance["supplement"] = supplementURL.path }
    let bindings = try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: headContract, catalog: catalog,
        supplement: supplement, provenance: provenance)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var report: [String: Any] = [
        "bindings": try JSONSerialization.jsonObject(with: encoder.encode(bindings)),
        "programs": catalog.programs.keys.sorted().map { shader -> [String: Any] in
            ["shader": shader, "passes": catalog.passes(for: shader).map(\.program),
             "inputs": catalog.inputs(for: shader).map { ["name": $0.name, "source": $0.source.rawValue, "dimension": $0.dimension, "stages": $0.stages] as [String: Any] }]
        },
    ]
    if let frameURL {
        let frame = try Data(contentsOf: frameURL)
        let comparison = try SourceShaderBindingComparison.compare(bindings: bindings, frame: frame, catalog: catalog,
            provenance: ["frame": frameURL.path, "frameSHA256": sha256(frame)])
        report["comparison"] = try JSONSerialization.jsonObject(with: encoder.encode(comparison))
        if let substitutedFrameURL {
            // R1 proof of concept: the capture frame with native binding values.
            guard substitutedFrameURL.deletingLastPathComponent().standardizedFileURL == frameURL.deletingLastPathComponent().standardizedFileURL,
                  substitutedFrameURL.lastPathComponent != frameURL.lastPathComponent else {
                throw RigError.invalid("--write-frame must name a new file next to the capture frame (the probe resolves its mesh and texture files there).")
            }
            let (data, substitution) = try SourceShaderBindingFrameSubstitution.substitute(bindings: bindings, frame: frame, catalog: catalog)
            try data.write(to: substitutedFrameURL, options: .withoutOverwriting)
            report["substitution"] = try JSONSerialization.jsonObject(with: encoder.encode(substitution))
            report["substitutedFrame"] = ["path": substitutedFrameURL.path, "sha256": sha256(data)]
        }
    } else if substitutedFrameURL != nil {
        throw RigError.invalid("--write-frame needs a capture frame.")
    }
    return report
}
