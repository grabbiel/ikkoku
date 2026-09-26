import Foundation
import Metal
import simd
import CoreMath
import Scene
import Character
import Renderer

/// Native-versus-original bone-transform gate for the controlled clothed fixture
/// (`Tools/reverse/compare_original_pose.py` consumes the emitted JSON).
///
/// Mirrors `AppState.captureRig`'s `IKKOKU_SOURCE_CARD` path exactly: load the
/// source avatar, take the adjacent shape contract, decode the card with
/// `SourceCharacterCard.load(url:)`, derive body/face values and bone modifiers
/// through `previewSettings(contract:)`, and pose the rig with `SourceRigPreview`.
/// The original probe captured LOCAL transforms per hierarchy path, so the native
/// side must pose the same source rig before world matrices can be compared.

private func values(_ vector: SIMD4<Float>) -> [Float] { [vector.x, vector.y, vector.z, vector.w] }

private func columns(_ matrix: float4x4) -> [[Float]] {
    [values(matrix.columns.0), values(matrix.columns.1), values(matrix.columns.2), values(matrix.columns.3)]
}

func inspectSourceCardPose(avatarURL: URL, cardURL: URL) throws -> [String: Any] {
    let source = try SourceRig.loadModel(url: avatarURL)
    // The app resolves the contract next to the avatar manifest; a missing or
    // invalid contract is an explicit error, never a silent rest-pose fallback.
    let contractURL = avatarURL.deletingLastPathComponent().appendingPathComponent("character-shape-contract.json")
    guard FileManager.default.fileExists(atPath: contractURL.path) else {
        throw RigError.invalid("Card-pose evaluation needs the source shape contract beside the avatar.")
    }
    let contract = try SourceShapeContract.decode(Data(contentsOf: contractURL))
    // Building a SourceRigPreview registers every source mesh in a ResourceStore,
    // so evaluation needs the same GPU device the app's renderer would use.
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw RigError.invalid("Source rig preview needs a Metal device to load its source meshes.")
    }
    let preview = try SourceRigPreview(source: source, contract: contract, resources: ResourceStore(device: device))
    // The app rejects cards against the unverified default assembly identity; do
    // not pose a different bone type, head or sex than the source rig exported.
    guard preview.supportsBodyCustomization, preview.supportsFaceCustomization else {
        throw RigError.invalid("Source card capture requires the recovered female shape contract.")
    }
    let settings = try SourceCharacterCard.load(url: cardURL).previewSettings(contract: contract)
    // Default coordinate 0 and standard bone type match the app's capture path.
    let pose = try preview.pose(bodyValues: settings.bodyValues, faceValues: settings.faceValues,
        boneModifiers: settings.boneModifiers)
    let evaluation = try source.rig.evaluate(pose)
    return [
        "sourcePrefab": source.sourcePrefab,
        "coordinateSpace": "native-right-handed-y-up",
        "nodeCount": source.rig.nodes.count,
        "nodeNames": source.rig.nodes.map(\.name),
        "nodeParents": source.rig.nodes.map { $0.parent ?? -1 },
        "nodeSourceIDs": source.rig.nodes.map(\.sourceID),
        "nodeWorldMatrices": evaluation.worldMatrices.map { columns($0).flatMap { $0 } },
        "appliedInputs": [
            "bodyValues": settings.bodyValues,
            "faceValues": settings.faceValues,
            "boneModifiersApplied": settings.boneModifiers != nil,
            "coordinate": 0,
            "boneType": 0,
            "diagnostics": settings.diagnostics,
        ] as [String: Any],
        "scope": """
            Native pose parity against the retained original-player capture of the \
            controlled clothed fixture: card-derived body/face values, static ABMX \
            if present, and the default coordinate-0 / standard-bone-type assembly. \
            Animated states, other coordinate outfits, corrected bone types and \
            per-variant rigs remain uncovered.
            """,
    ]
}
