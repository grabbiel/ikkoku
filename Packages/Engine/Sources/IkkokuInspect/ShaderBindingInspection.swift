import Foundation
import CryptoKit
import Character
import Renderer
import Scene
import Studio

/// `ikkoku-inspect shader-bindings`: derives the native shader binding set for
/// a card and, when an original-player capture is given, compares it with the
/// inputs the translated probe binds from that capture. The capture is read
/// only after the derivation has finished, and only by the comparison.
func inspectShaderBindings(cardURL: URL, libraryURL: URL, headContractURL: URL, programsURL: URL, frameURL: URL?, supplementURL: URL? = nil,
                           substitutedFrameURL: URL? = nil, eyeLookURL: URL? = nil, eyeLookRates: String? = nil) throws -> [String: Any] {
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
    // Optional look state: the Studio eye-look settings document (eyeMaterial
    // block) plus the frame's iris-shift rates, default the resting (0, 0).
    var eyeLook: SourceShaderBindingDerivation.EyeLook?
    if let eyeLookURL {
        let lookData = try Data(contentsOf: eyeLookURL)
        let eyes = try SourceStudioEyeMaterialSettings.document(json: lookData)
        var rates: (horizontal: [Double], vertical: Double)?
        if let eyeLookRates {
            let values = eyeLookRates.split(separator: ",").compactMap { Double($0) }
            guard values.count == 3, values.allSatisfy(\.isFinite) else { throw RigError.invalid("--eye-look-rates takes <left-h>,<right-h>,<v>.") }
            rates = ([values[0], values[1]], values[2])
        }
        let identity = try card.customization()
        let (cardValues, missing) = SourceStudioIrisRendering.cardValues(appearance: try SourceCardAppearance(card: card, coordinate: 0),
                                                                          sex: identity.sex, exType: identity.exType)
        let rateText = rates.map { "rates L \($0.horizontal[0]) R \($0.horizontal[1]) V \($0.vertical)" } ?? "resting rates (0, 0)"
        let cardText = cardValues != nil ? "card pupil/highlight values" : (missing.isEmpty ? "prefab snapshot (special-male skip)" : "prefab snapshot (card lacks \(missing.joined(separator: ", ")))")
        eyeLook = try SourceStudioIrisRendering.bindingEyeLook(eyes: eyes, card: cardValues, rates: rates,
            source: "Studio eye look \(eyeLookURL.lastPathComponent) (\(sha256(lookData).prefix(12))), \(rateText), \(cardText)")
        provenance["eyeLook"] = eyeLookURL.path
    } else if eyeLookRates != nil {
        throw RigError.invalid("--eye-look-rates needs --eye-look.")
    }
    let bindings = try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: headContract, catalog: catalog,
        supplement: supplement, eyeLook: eyeLook, provenance: provenance)
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
