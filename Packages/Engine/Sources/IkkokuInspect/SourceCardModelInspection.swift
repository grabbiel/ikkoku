import Foundation
import simd
import CryptoKit
import Metal
import CoreMath
import Scene
import Character
import Renderer
import Studio

/// Independent native assembly/shape/expression evaluation for the neutral
/// original-player probe. No captured bones, weights or vertices are inputs.
/// `studioWear` assembles the CharaStudio wear (half-state meshes, converted
/// indoor shoes) and selects the renderers UpdateVisible leaves on for the
/// card's saved clothes state and shoesType (ST-C03).
func inspectSourceCardModel(avatarURL: URL, cardURL: URL, libraryURL: URL, benchmarkIterations: Int = 0, studioWear: Bool = false) throws -> [String: Any] {
    func hash(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    func vector(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
    func matrix(_ m: float4x4) -> [Float] { (0..<4).flatMap { column in (0..<4).map { m[column][$0] } } }
    let card = try SourceCharacterCard.load(url: cardURL), identity = try card.customization()
    let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: avatarURL))
    let directory = avatarURL.deletingLastPathComponent()
    let contractURL = directory.appendingPathComponent("character-shape-contract.json")
    let expressionURL = directory.appendingPathComponent("source-expression-contract.json")
    let contract = try SourceShapeContract.decode(Data(contentsOf: contractURL))
    let expressions = try SourceExpressionContract.decode(Data(contentsOf: expressionURL))
    let settings = try card.previewSettings(contract: contract, sex: identity.sex, headID: identity.headID, boneType: identity.boneType)
    let library = try SourceMakerLibrary.load(url: libraryURL)
    let prepared = try library.prepare(card: card, coordinate: 0, baseURL: avatarURL, wear: studioWear)
    let saved = studioWear ? try SourceStudioWearLayout.saved(card: card, coordinate: 0, library: library, prepared: prepared) : nil
    guard saved?.evaluation.fallbacks.isEmpty ?? true else {
        throw RigError.invalid("Neutral model inspection requires native wear; fallbacks: \(saved!.evaluation.fallbacks.joined(separator: " "))")
    }
    guard prepared.selections.allSatisfy({ $0.entry != nil }) else {
        throw RigError.invalid("Neutral model inspection requires every selected part to be converted; reference fallback is not a comparison.")
    }
    let options = try SourceMakerAssemblyOptions.body(sex: identity.sex, exType: identity.exType, boneType: identity.boneType,
        correctionData: try manifest.bodyCorrection.map { try Data(contentsOf: directory.appendingPathComponent($0)) })
    guard let device = MTLCreateSystemDefaultDevice() else { throw RigError.invalid("Neutral model inspection requires Metal.") }
    let source = prepared.source
    let preview = try SourceRigPreview(source: source, contract: contract, resources: ResourceStore(device: device), expressionContract: expressions, bodyOptions: options, lateCorrectionOptions: .init())
    let pose = try preview.pose(bodyValues: settings.bodyValues, faceValues: settings.faceValues, boneModifiers: settings.boneModifiers)
    let evaluated = try source.rig.evaluate(pose)
    let weights = try preview.expressionWeights(expressions.defaults)
    let appearance = try SourceCardAppearance(card: card)
    let doubleTooth = appearance.value("face.doubleTooth") == .bool(true)
    var benchmark: [String: Any] = [:]
    guard benchmarkIterations == 0 || (32...100_000).contains(benchmarkIterations) else {
        throw RigError.invalid("Model benchmark needs 32...100000 iterations.")
    }
    if benchmarkIterations > 0 {
        let enabled = try preview.lateCorrection(restoring: pose)
        let disabled = try SourceBodyLateCorrection(rig: source.rig, sex: options.sex, options: .disabled)
        var candidate = pose
        for (name, correction) in [("disabled", disabled), ("sourceContext", enabled)] {
            for _ in 0..<32 { try correction.apply(to: &candidate) }
            var times: [UInt64] = []; times.reserveCapacity(benchmarkIterations)
            for _ in 0..<benchmarkIterations {
                let start = DispatchTime.now().uptimeNanoseconds
                try correction.apply(to: &candidate)
                times.append(DispatchTime.now().uptimeNanoseconds - start)
            }
            times.sort()
            benchmark[name] = ["p50Nanoseconds": times[times.count / 2], "p95Nanoseconds": times[(times.count - 1) * 95 / 100],
                "iterations": benchmarkIterations, "warmup": 32]
        }
        benchmark["scope"] = "Late correction only, bound indices and unique mutable pose; dispatch clock overhead included; no frame/FPS claim."
        benchmark["nodeCount"] = source.rig.nodes.count
        benchmark["checksum"] = candidate.localMatrices.reduce(Float(0)) { $0 + $1[0][0] }
    }
    let parts = try source.parts.enumerated().map { index, part -> [String: Any] in
        let active = part.rendererEnabled && source.rig.activeNodes[part.node]
        let switched = saved?.evaluation.hiddenParts.contains(index) == true
        let selected = active && !switched && (part.mesh.name != "cf_O_canine/0" || doubleTooth)
        let skin = source.rig.skins[part.skin]
        return ["name": part.mesh.name, "node": part.node, "nodeSourceID": source.rig.nodes[part.node].sourceID,
            "active": active, "selected": selected,
            "selectionReason": selected ? "active fixture component" : switched ? "ChaControl.UpdateVisible switched off for the saved clothes state" : "source VisibleDoubleTooth or inactive renderer",
            "jointNodes": skin.joints, "inverseBindMatrices": skin.inverseBindMatrices.map(matrix), "hasCloth": part.hasCloth, "vertexCount": part.mesh.vertexCount,
            "restPositions": part.mesh.positions.map(vector), "indices": part.mesh.indices,
            "morphNames": part.mesh.morphTargets.map(\.name),
            "morphWeights": (weights[part.mesh.name] ?? []).map { ["index": $0.index, "weight": $0.weight * 100] },
            "positions": try source.deformedPositions(part: part, evaluation: evaluated, morphWeights: weights[part.mesh.name] ?? []).map(vector)]
    }
    var report: [String: Any] = ["kind": "ikkoku-neutral-source-model", "schemaVersion": 1,
        "benchmark": benchmark, "coordinateSpace": "native-right-handed-y-up", "sourcePrefab": source.sourcePrefab,
        "identity": ["sex": identity.sex, "exType": identity.exType, "headID": identity.headID, "boneType": identity.boneType, "coordinate": 0],
        "inputs": ["cardSHA256": try hash(cardURL), "avatarSHA256": try hash(avatarURL), "librarySHA256": try hash(libraryURL),
            "shapeContractSHA256": try hash(contractURL), "expressionContractSHA256": try hash(expressionURL)],
        "lateCorrectionOptions": ["hiPoly": preview.lateCorrectionOptions.hiPoly, "enableCorrectArmSize": preview.lateCorrectionOptions.enableCorrectArmSize, "enableCorrectHandSize": preview.lateCorrectionOptions.enableCorrectHandSize],
        "lateCorrectionApplied": preview.lateCorrectionOptions.hiPoly && options.sex == .female,
        "bodyValues": settings.bodyValues, "faceValues": settings.faceValues,
        "nodeNames": source.rig.nodes.map(\.name), "nodeParents": source.rig.nodes.map { $0.parent ?? -1 },
        "nodeSourceIDs": source.rig.nodes.map(\.sourceID), "nodeLocalMatrices": pose.localMatrices.map(matrix),
        "nodeWorldMatrices": evaluated.worldMatrices.map(matrix), "parts": parts,
        "selections": prepared.selections.map { ["property": $0.property, "category": $0.category, "savedID": $0.savedID, "sourceID": $0.sourceID, "status": $0.status] as [String: Any] },
        "diagnostics": prepared.diagnostics + settings.diagnostics,
        "scope": "Card-selected normal assembly, original sex-specific body/face formulas, neutral expression, no fitted hands or source-evaluated vertices. Hand pattern0/no Animator tick; dynamics/gaze omitted."]
    if let saved {
        report["studioWear"] = ["savedClothesState": saved.wear.clothesState.map(Int.init), "loadedClothesState": saved.states.map(Int.init),
            "shoesType": saved.wear.shoesType, "bodyAlpha": [saved.evaluation.bodyAlpha.x, saved.evaluation.bodyAlpha.y],
            "renderedClothing": saved.evaluation.renderedClothing, "clothingSlots": prepared.clothingSlots,
            "switchedOff": saved.evaluation.hiddenParts.sorted().map { source.parts[$0].mesh.name },
            "rule": "SourceStudioWear.loaded + SourceStudioWearLayout.evaluate (ChaControl.UpdateVisible) over prepare(wear: true)"] as [String: Any]
    }
    return report
}
