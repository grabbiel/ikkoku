import Foundation
import Scene

/// CPU-only result for changing a normal head without resetting the editor.
/// Each assembly owns its shape/expression contracts and correction input.
public struct SourceMakerHeadPreparation: Sendable {
    public static let supportedIDs = [0, 200, 201]
    public let manifestURL: URL
    public let sex: Int, headID: Int, boneType: Int, coordinate: Int
    public let assets: SourceMakerLibrary.Prepared
    public let contract: SourceShapeContract
    public let expressions: SourceExpressionContract
    public let bodyOptions: SourceBodyShapePose.Options

    /// `baseURL` is a configuration snapshot for the sex's head-0 assembly, not
    /// the currently displayed head-200/201 URL. Assembly and contract I/O stay
    /// here; appearance JSON/texture loads remain in the owner-side candidate.
    public static func prepare(card: SourceCharacterCard, library: SourceMakerLibrary,
                               coordinate: Int, baseURL: URL?) throws -> Self {
        try card.validateMakerSelectionMetadata()
        try SourceMakerLibrary.validateAssemblyIdentity(card: card)
        let identity = try card.customization()
        guard [0, 1].contains(identity.sex), identity.exType == 0,
              supportedIDs.contains(identity.headID), (0..<7).contains(coordinate) else {
            throw RigError.invalid("Unsupported normal head selection or outfit.")
        }
        let selected: URL?
        if identity.headID == 0 { selected = baseURL }
        else { selected = try library.assemblyURL(for: identity) }
        guard let selected else { throw RigError.invalid("This normal head has no converted assembly.") }
        let url = selected.resolvingSymlinksInPath()
        let folder = url.deletingLastPathComponent()
        func read(_ url: URL, maximum: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximum + 1) ?? Data()
            guard data.count <= maximum else { throw RigError.invalid("Head assembly input exceeds its size limit.") }
            return data
        }
        func companion(_ name: String, maximum: Int) throws -> Data {
            let target = folder.appendingPathComponent(name).resolvingSymlinksInPath()
            guard !name.isEmpty, !name.hasPrefix("/"), target.path.hasPrefix(folder.path + "/") else {
                throw RigError.invalid("Head assembly input escapes its folder.")
            }
            return try read(target, maximum: maximum)
        }
        let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: read(url, maximum: 1024 * 1024))
        let kind = identity.sex == 0 ? "koikatsu-male-avatar" : "koikatsu-female-avatar"
        guard manifest.schemaVersion == 1, manifest.kind == kind,
              (manifest.sex ?? identity.sex) == identity.sex,
              (manifest.headID ?? 0) == identity.headID else {
            throw RigError.invalid("Selected card and head assembly identities differ.")
        }
        let contract = try SourceShapeContract.decode(companion("character-shape-contract.json", maximum: 64 * 1024 * 1024))
        let expressions = try SourceExpressionContract.decode(companion("source-expression-contract.json", maximum: 16 * 1024 * 1024))
        let correction = identity.boneType == 0 ? nil : try companion(manifest.bodyCorrection ?? "shapecorrect.bytes", maximum: 1024 * 1024)
        let options = try SourceMakerAssemblyOptions.body(sex: identity.sex, exType: identity.exType,
            boneType: identity.boneType, correctionData: correction)
        _ = try card.previewSettings(contract: contract, sex: identity.sex, headID: identity.headID, boneType: identity.boneType)
        let assets = try library.prepare(card: card, coordinate: coordinate, baseURL: url)
        return Self(manifestURL: url, sex: identity.sex, headID: identity.headID,
            boneType: identity.boneType, coordinate: coordinate, assets: assets, contract: contract,
            expressions: expressions, bodyOptions: options)
    }
}
