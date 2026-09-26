import Foundation
import Darwin
import simd
import Assets
import CoreMath
import Studio
import Character
import Scene
import CryptoKit

private func values(_ vector: SIMD3<Float>) -> [Float] { [vector.x, vector.y, vector.z] }
private func values(_ vector: SIMD4<Float>) -> [Float] { [vector.x, vector.y, vector.z, vector.w] }
private func columns(_ matrix: float4x4) -> [[Float]] {
    [values(matrix.columns.0), values(matrix.columns.1), values(matrix.columns.2), values(matrix.columns.3)]
}

private func modDependency(_ value: SourceModCatalog.Dependency) -> [String: Any] {
    ["guid": value.entry.modGUID, "category": value.entry.category, "sourceSlot": value.entry.sourceSlot,
     "sourcePath": value.sourcePath, "sourceRow": value.sourceRow,
     "role": value.reference.role, "expectedType": value.reference.expectedType,
     "manifest": value.reference.manifest, "bundlePath": value.reference.bundlePath,
     "assetName": value.reference.assetName, "status": value.status,
     "providerGUID": value.providerGUID as Any? ?? NSNull()]
}

private func cardModReferences(_ value: SourceCardModReferences.Report) -> [String: Any] {
    ["pluginID": value.pluginID as Any? ?? NSNull(), "pluginVersion": value.pluginVersion as Any? ?? NSNull(),
     "diagnostics": value.diagnostics,
     "resolutions": value.resolutions.map { resolution -> [String: Any] in
        let record = resolution.record
        var result: [String: Any] = [
            "index": record.index, "guid": record.modGUID as Any? ?? NSNull(),
            "category": record.category, "sourceSlot": record.sourceSlot, "localSlot": record.localSlot,
            "property": record.property as Any? ?? NSNull(), "author": record.author as Any? ?? NSNull(),
            "website": record.website as Any? ?? NSNull(), "name": record.name as Any? ?? NSNull(),
            "preservedBytes": record.preservedData.count, "sourceSHA256": record.sourceSHA256,
            "status": resolution.status, "dependencies": resolution.dependencies.map(modDependency),
            "destination": NSNull(), "catalogEntry": NSNull(), "appearanceApplied": false]
        if let destination = resolution.destination {
            result["destination"] = ["property": destination.property, "catalogProperty": destination.catalogProperty,
                "category": destination.category, "sourceSlot": destination.sourceSlot] as [String: Any]
        }
        if let entry = resolution.entry {
            result["catalogEntry"] = ["guid": entry.key.modGUID, "category": entry.key.category,
                "sourceSlot": entry.key.sourceSlot, "name": entry.name, "distribution": entry.distribution,
                "sourcePath": entry.sourcePath, "sourceRow": entry.sourceRow, "sourceFilePath": entry.sourceFilePath,
                "properties": entry.properties, "fields": entry.fields] as [String: Any]
        }
        return result
     }]
}


private func transform(_ source: KoikatsuChangeAmount) -> [String: Any] {
    let rotation = UnityCoordinates.eulerDegrees(source.rotationDegrees)
    let position = UnityCoordinates.position(source.position)
    return ["sourcePosition": values(source.position), "sourceEulerDegrees": values(source.rotationDegrees),
            "sourceScale": values(source.scale), "nativePosition": values(position),
            "nativeQuaternionXYZW": values(rotation.vector),
            "nativeMatrixColumns": columns(Transform.trs(position, rotation, source.scale))]
}

private func object(_ source: KoikatsuObjectRecord) -> [String: Any] {
    var result: [String: Any] = ["kind": source.kind.rawValue, "sourceKey": source.sourceKey,
                               "visible": source.visible, "treeState": source.treeState,
                               "transform": transform(source.transform), "children": source.children.map(object)]
    if let key = source.rootDictionaryKey { result["rootDictionaryKey"] = key }
    if let name = source.name { result["name"] = name }
    if let active = source.cameraActive { result["cameraActive"] = active }
    if let item = source.item {
        result["item"] = ["group": item.group, "category": item.category, "no": item.no,
                          "alpha": item.alpha, "enableFK": item.enableFK, "boneCount": item.bones.count]
    }
    if let light = source.light {
        result["light"] = ["catalogNo": light.no, "color": values(light.color), "intensity": light.intensity,
                           "range": light.range, "spotAngle": light.spotAngle, "enabled": light.enable]
    }
    return result
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let inspecting = arguments.count == 2 && ["scene", "model", "camera", "change-amount", "rig", "mod", "mod-library", "card"].contains(arguments[0])
    let modCatalog = arguments.count == 3 && arguments[0] == "mod-catalog"
    let cardMods = arguments.count == 4 && arguments[0] == "card-mods"
    let logicTrace = arguments.count == 2 && ["blink-trace", "gameplay-trace", "fixed-event-trace", "adv-trace", "scene-document", "animation-library"].contains(arguments[0])
    let animationPose = arguments.count == 5 && arguments[0] == "animation-pose"
    let studioPose = arguments.count == 3 && arguments[0] == "studio-fk"
    let boneSnapshot = arguments.count == 3 && arguments[0] == "bone-modifier-snapshot"
    let cardPose = arguments.count == 3 && arguments[0] == "card-pose"
    let converting = arguments.count == 4 && arguments[0] == "layout"
    let rigSnapshot = arguments.count == 4 && ["rig-snapshot", "face-snapshot", "body-snapshot"].contains(arguments[0])
    let expressionSnapshot = arguments.count == 4 && arguments[0] == "expression-snapshot"
    guard inspecting || converting || rigSnapshot || expressionSnapshot || modCatalog || boneSnapshot || cardPose || cardMods || logicTrace || studioPose || animationPose else {
        throw GLTFError.io("""
            Usage: ikkoku-inspect <scene|model|camera|change-amount|rig|mod|card> <local-file>
                   ikkoku-inspect mod-library <library.json>
                   ikkoku-inspect mod-catalog <library.json> <catalog-contract.json>
                   ikkoku-inspect card-mods <card.png> <library.json> <catalog-contract.json>
                   ikkoku-inspect <blink-trace|gameplay-trace> <trace.json>
                   ikkoku-inspect <fixed-event-trace|adv-trace> <trace.json>
                   ikkoku-inspect scene-document <source-scene.png>
                   ikkoku-inspect animation-library <animation.json>
                   ikkoku-inspect animation-pose <animation.json> <rig-or-avatar.json> <clip-id> <seconds>
                   ikkoku-inspect studio-fk <rig-or-avatar.json> <pose-request.json>
                   ikkoku-inspect bone-modifier-snapshot <rig-or-avatar.json> <modifiers.json>
                   ikkoku-inspect card-pose <avatar.json> <card.png>
                   ikkoku-inspect layout <source-scene.png> <converted-catalog.json> <native-scene.png>
                   ikkoku-inspect rig-snapshot <source-rig.json> <shape-contract.json> <rest|height-rate>
                   ikkoku-inspect <face-snapshot|body-snapshot> <rig-or-avatar.json> <shape-contract.json> <rest|defaults|all=rate|index=rate,...>
                   ikkoku-inspect expression-snapshot <rig-or-avatar.json> <expression-contract.json> <defaults|preset-id|inputs.json>
            """)
    }
    let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    var report: [String: Any] = ["reportVersion": 1, "source": url.path]
    switch arguments[0] {
    case "blink-trace": report.merge(try inspectBlinkTrace(url: url)) { _, new in new }
    case "gameplay-trace": report.merge(try inspectGameplayTrace(url: url)) { _, new in new }
    case "fixed-event-trace": report.merge(try inspectFixedEventExecution(url: url)) { _, new in new }
    case "adv-trace": report.merge(try inspectADVExecution(url: url)) { _, new in new }
    case "scene-document": report.merge(try inspectStudioScene(url: url)) { _, new in new }
    case "animation-library": report.merge(try inspectSourceAnimation(url: url)) { _, new in new }
    case "animation-pose":
        guard let time = Float(arguments[4]), time.isFinite, time >= 0 else { throw RigError.invalid("Animation time must be finite and nonnegative.") }
        report.merge(try inspectSourceAnimation(url: url, rigURL: URL(fileURLWithPath: arguments[2]), clipID: arguments[3], time: time)) { _, new in new }
    case "studio-fk":
        report.merge(try inspectStudioPose(rigURL: url, requestURL: URL(fileURLWithPath: arguments[2]))) { _, new in new }
    case "card":
        let card = try SourceCharacterCard.load(url: url)
        report["sourceSHA256"] = card.sourceSHA256
        report["product"] = card.product; report["version"] = card.version
        report["preservedBytes"] = card.preservedData.count
        report["thumbnailBytes"] = card.thumbnailData.count; report["trailingBytes"] = card.trailingData.count
        report["blocks"] = card.blocks.map {
            ["name": $0.name, "version": $0.version, "position": $0.position, "bytes": $0.data.count,
             "sha256": SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined()] as [String: Any]
        }
        let extensions = try card.extensions()
        report["extendedSaveFormat"] = extensions.format ?? "none"
        report["plugins"] = extensions.plugins.keys.sorted().map { id -> [String: Any] in
            let plugin = extensions.plugins[id]!
            return ["id": id, "version": plugin.version, "hasData": plugin.data != nil,
                    "keys": plugin.data.map { $0.keys.sorted() } ?? []]
        }
        var diagnostics = extensions.diagnostics
        do {
            let values = try card.customization()
            report["customization"] = ["sex": values.sex, "headID": values.headID, "boneType": values.boneType,
                "faceValues": values.faceValues, "bodyValues": values.bodyValues] as [String: Any]
        } catch { diagnostics.append("Customization: \(error)") }
        do { report["boneModifierCount"] = try card.boneModifiers()?.count ?? 0 }
        catch { diagnostics.append("ABMX: \(error)") }
        do { report["modReferences"] = cardModReferences(try card.modReferenceReport()) }
        catch { diagnostics.append("Mod references: \(error)") }
        report["diagnostics"] = diagnostics
        report["scope"] = "Original bytes preserved; current character framing, shape records, supported ABMX data and saved mod-reference metadata decoded. Hair, outfits, materials, other plugins and edited-card serialization remain unfinished."
    case "card-mods":
        let card = try SourceCharacterCard.load(url: url)
        let libraryURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let contractURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        let profile = try SourceModProfile.load(libraryURL: libraryURL)
        let contract = try SourceModCatalogContract.decode(Data(contentsOf: contractURL))
        let catalog = try SourceModCatalog(library: profile.library, contract: contract)
        report["sourceSHA256"] = card.sourceSHA256
        report["preservedBytes"] = card.preservedData.count
        report["library"] = libraryURL.path; report["catalogContract"] = contractURL.path
        report["mountedGUIDs"] = profile.library.packages.map { $0.source.guid }
        report["unresolvedSelections"] = profile.unresolvedConflicts.map { ["guid": $0.guid, "archiveSHA256s": $0.archiveSHA256s] as [String: Any] }
        report["libraryDiagnostics"] = profile.diagnostics.map { ["code": $0.code, "severity": $0.severity, "message": $0.message] }
        report["catalogDiagnostics"] = catalog.diagnostics.map { ["code": $0.code, "severity": $0.severity, "message": $0.message] }
        report["modReferences"] = cardModReferences(try card.modReferenceReport(library: profile.library, catalog: catalog, contract: contract))
        report["scope"] = "Direct saved-identity lookup in the selected native profile. Catalog matches and dependency availability do not apply appearance. Runtime LocalSlot is retained as evidence only; compatibility migrations and managed plugins are not executed."
    case "mod-library", "mod-catalog":
        let profile = try SourceModProfile.load(libraryURL: url)
        report["mountedGUIDs"] = profile.library.packages.map { $0.source.guid }
        report["unresolvedSelections"] = profile.unresolvedConflicts.map { ["guid": $0.guid, "archiveSHA256s": $0.archiveSHA256s] as [String: Any] }
        report["diagnostics"] = profile.diagnostics.map { ["code": $0.code, "severity": $0.severity, "message": $0.message] }
        if modCatalog {
            let contract = try SourceModCatalogContract.decode(Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let catalog = try SourceModCatalog(library: profile.library, contract: contract)
            report["catalogEntries"] = catalog.entries.map {
                ["guid": $0.key.modGUID, "category": $0.key.category, "sourceSlot": $0.key.sourceSlot,
                 "distribution": $0.distribution, "sourcePath": $0.sourcePath, "sourceRow": $0.sourceRow,
                 "name": $0.name, "properties": $0.properties, "fields": $0.fields] as [String: Any]
            }
            report["catalogDiagnostics"] = catalog.diagnostics.map { ["code": $0.code, "severity": $0.severity, "message": $0.message] }
            report["dependencies"] = try catalog.dependencies(library: profile.library, sourceAssets: contract.sourceAssets ?? []).map {
                ["guid": $0.entry.modGUID, "category": $0.entry.category, "sourceSlot": $0.entry.sourceSlot,
                 "sourcePath": $0.sourcePath, "sourceRow": $0.sourceRow,
                 "role": $0.reference.role, "expectedType": $0.reference.expectedType,
                 "manifest": $0.reference.manifest, "bundlePath": $0.reference.bundlePath,
                 "assetName": $0.reference.assetName, "status": $0.status, "providerGUID": $0.providerGUID ?? ""] as [String: Any]
            }
        }
        report["scope"] = "Explicit native profile order, original GUID/category/slot identities and supported dependency mappings. Unresolved is not proof that an asset is absent from the original installation."
    case "bone-modifier-snapshot":
        let source = try SourceRig.loadModel(url: url)
        let modifiers = try SourceBoneModifiers.decode(Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let pose = try modifiers.applying(to: source.rig, baseline: source.rig.restPose)
        let evaluation = try source.rig.evaluate(pose)
        report["modifierCount"] = modifiers.count
        report["diagnostics"] = (modifiers.diagnostics ?? []).map { ["code": $0.code, "severity": $0.severity, "message": $0.message] }
        report["nodeNames"] = source.rig.nodes.map(\.name)
        report["nodeWorldMatrices"] = evaluation.worldMatrices.map { columns($0).flatMap { $0 } }
        report["parts"] = try source.parts.map { part -> [String: Any] in
            ["name": part.mesh.name, "positions": try source.deformedPositions(part: part, evaluation: evaluation).map(values)]
        }
        report["scope"] = "Recovered static ABMX baseline behavior at coordinate0; dynamic, animation and accessory modifier behavior remains unsupported."
    case "card-pose":
        report.merge(try inspectSourceCardPose(avatarURL: url, cardURL: URL(fileURLWithPath: arguments[2]).standardizedFileURL)) { _, new in new }
    case "mod":
        let package = try SourceModPackage.load(url: url)
        report["modGUID"] = package.source.guid
        report["modVersion"] = package.source.version
        report["archiveSHA256"] = package.source.archiveSHA256
        report["convertedTextures"] = package.resources.map {
            ["id": $0.id, "bundlePath": $0.bundlePath, "assetName": $0.assetName, "path": $0.path, "sha256": $0.sha256]
        }
        report["preservedCatalogCount"] = package.catalogs.count
        report["diagnostics"] = package.diagnostics.map { ["code": $0.code, "severity": $0.severity, "message": $0.message] }
        report["scope"] = "Verified native texture resources and preserved source catalogs. Source plugins are not executed; conversion alone does not establish whole-mod compatibility."
    case "expression-snapshot":
        let source = try SourceRig.loadModel(url: url)
        let contract = try SourceExpressionContract.decode(Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let input: SourceExpressionInputs
        if arguments[3] == "defaults" { input = contract.defaults }
        else if let preset = contract.presets.first(where: { $0.id == arguments[3] }) { input = preset.inputs }
        else { input = try JSONDecoder().decode(SourceExpressionInputs.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3]))) }
        let weights = try contract.weights(source: source, inputs: input)
        let evaluation = try source.rig.evaluate(source.rig.restPose)
        report["inputs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        report["weightUnit"] = "percent"
        report["coordinateSpace"] = "native-right-handed-y-up"
        report["parts"] = try source.parts.map { part -> [String: Any] in
            let active = weights[part.mesh.name] ?? []
            return ["name": part.mesh.name, "meshName": source.rig.skins[part.skin].name,
                    "activeWeights": active.map { ["index": $0.index, "weight": $0.weight * 100] },
                    "positions": try source.deformedPositions(part: part, evaluation: evaluation, morphWeights: active).map(values)]
        }
        report["scope"] = "Recovered morph controller weights at neutral gaze; no random mouth-width motion, voice analysis or tear visibility state."
    case "rig", "rig-snapshot", "face-snapshot", "body-snapshot":
        let source = try SourceRig.loadModel(url: url)
        var pose = source.rig.restPose
        if rigSnapshot, arguments[3] != "rest" {
            let contract = try SourceShapeContract.decode(Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            if arguments[0] == "rig-snapshot" {
                guard let rate = Float(arguments[3]) else { throw RigError.invalid("Height must be a normalized number or 'rest'.") }
                pose = try SourceRigCustomization.heightPose(source: source, contract: contract, rate: rate)
                report["heightRate"] = rate
            } else {
                let id = arguments[0] == "face-snapshot" ? "face" : "body"
                guard let domain = contract.domain(id) else { throw RigError.invalid("Missing shape domain '\(id)'.") }
                let values = try domain.values(overrides: arguments[3])
                let avatar = try? JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: url))
                let sex: SourceBodyShapePose.Sex = avatar?.kind == "koikatsu-male-avatar" ? .male : .female
                pose = id == "face" ? try SourceFaceShapePose.make(rig: source.rig, domain: domain, values: values)
                    : try SourceBodyShapePose.make(rig: source.rig, domain: domain, values: values, options: .init(sex: sex))
                if id == "body" { report["sex"] = sex.rawValue }
                report["shapeDomain"] = id
                report["shapeValues"] = values
                report["appliedSlots"] = id == "face" ? Array(0..<domain.valueCount) : SourceBodyShapePose.supportedSlots
            }
        }
        let evaluation = try source.rig.evaluate(pose)
        let bounds = try source.bounds(evaluation: evaluation)
        report["sourcePrefab"] = source.sourcePrefab
        report["nodeCount"] = source.rig.nodes.count
        report["skinCount"] = source.rig.skins.count
        report["partCount"] = source.parts.count
        report["vertexCount"] = source.parts.reduce(0) { $0 + $1.mesh.vertexCount }
        report["morphChannelCount"] = source.morphChannelCount
        report["coordinateSpace"] = "native-right-handed-y-up"
        report["skinBindings"] = source.rig.skins.enumerated().map { index, skin -> [String: Any] in
            var residual: Float = 0
            for matrix in evaluation.palettes[index] {
                for column in 0..<4 { for row in 0..<4 { residual = max(residual, abs(matrix[column][row] - (column == row ? 1 : 0))) } }
            }
            return ["name": skin.name, "jointCount": skin.joints.count, "meshNode": skin.meshNode, "paletteIdentityResidual": residual]
        }
        if !bounds.isEmpty { report["bounds"] = ["min": values(bounds.min), "max": values(bounds.max)] }
        if rigSnapshot {
            report["nodeWorldMatrices"] = evaluation.worldMatrices.map { columns($0).flatMap { $0 } }
            report["nodeNames"] = source.rig.nodes.map(\.name)
            report["nodeSourceIDs"] = source.rig.nodes.map(\.sourceID)
            report["parts"] = try source.parts.map { part -> [String: Any] in
                ["name": part.mesh.name, "node": part.node, "skin": part.skin,
                 "positions": try source.deformedPositions(part: part, evaluation: evaluation).map(values)]
            }
        }
        report["scope"] = "Full source hierarchy and per-renderer bind palettes. Source materials, runtime outfit visibility and source morph playback are not applied."
    case "layout":
        let catalogURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        guard outputURL != url, outputURL != catalogURL else { throw GLTFError.io("Output must differ from both source files.") }
        let scene = try KoikatsuSceneReader.decode(Data(contentsOf: url))
        let catalog = try JSONDecoder().decode(KoikatsuAssetCatalog.self, from: Data(contentsOf: catalogURL))
        var document = try KoikatsuLayoutImporter.convert(scene, catalog: catalog, catalogDirectory: catalogURL.deletingLastPathComponent())
        // Validate every referenced model before producing a usable native scene.
        var models: [String: GLTFAsset] = [:]
        for path in Set(document.objects.compactMap(\.assetFile)) {
            let model = try GLBLoader.load(url: URL(fileURLWithPath: path))
            guard model.skins.isEmpty, !model.meshNodes.isEmpty else { throw GLTFError.io("Layout assets must contain static meshes.") }
            models[path] = model
        }
        var bounds = AABB.empty
        for object in document.objects {
            guard let path = object.assetFile, let model = models[path] else { continue }
            for (node, mesh) in model.meshNodes {
                let matrix = document.worldMatrix(of: object.id) * model.worldMatrix(ofNode: node)
                for primitive in model.meshes[mesh].primitives { bounds.expand(primitive.bounds.transformed(by: matrix)) }
            }
        }
        if !bounds.isEmpty {
            document.camera.target = bounds.center
            document.camera.distance = max(bounds.radius, 0.1) / sin(document.camera.fovDegrees.degreesToRadians * 0.5) * 1.2
        }
        let bytes = try CardIO.encode(document, keyword: CardIO.sceneKeyword, thumbnail: nil)
        try bytes.write(to: outputURL, options: .atomic)
        report["nativeScene"] = outputURL.path
        report["objectCount"] = document.objects.count
        report["scope"] = "Prop/folder transforms and visibility only; source materials, animation, cameras and scene settings are not applied."
    case "model":
        let model = try GLBLoader.load(url: url)
        var bounds = AABB.empty
        var vertices = 0, triangles = 0
        for (node, mesh) in model.meshNodes {
            for part in model.meshes[mesh].primitives {
                bounds.expand(part.bounds.transformed(by: model.worldMatrix(ofNode: node)))
                vertices += part.vertexCount
                triangles += part.triangleCount
            }
        }
        report["nodeCount"] = model.nodes.count
        report["activeMeshNodeCount"] = model.meshNodes.count
        report["vertices"] = vertices
        report["triangles"] = triangles
        report["skinCount"] = model.skins.count
        if !bounds.isEmpty { report["bounds"] = ["min": values(bounds.min), "max": values(bounds.max)] }
        report["materials"] = model.materials.map { material -> [String: Any] in
            ["name": material.name, "alphaMode": material.alphaMode, "alphaCutoff": material.alphaCutoff,
             "doubleSided": material.doubleSided, "baseColorFactor": values(material.baseColorFactor)]
        }
        report["images"] = model.images.map { ["name": $0.name, "byteCount": $0.data.count] as [String: Any] }
    case "scene":
        let bytes = try Data(contentsOf: url)
        let scene = try KoikatsuSceneReader.decode(bytes)
        report["sceneVersion"] = scene.version
        report["roots"] = scene.roots.map(object)
        report["objectSectionEndOffset"] = scene.objectSectionEndOffset
        report["unparsedTailBytes"] = bytes.count - scene.objectSectionEndOffset
        report["scope"] = "Object section only; character/route records and scene settings are not supported."
    case "camera":
        let camera = try KoikatsuSceneReader.decodeCamera(Data(contentsOf: url))
        report["position"] = values(camera.position)
        report["rotationDegrees"] = values(camera.rotationDegrees)
        report["distance"] = values(camera.distance)
        report["fieldOfView"] = camera.fieldOfView
        report["coordinateSpace"] = "Unity LH Y-up; raw camera record, including roll and 3D distance."
    default:
        report["transform"] = transform(try KoikatsuSceneReader.decodeChangeAmount(Data(contentsOf: url)))
    }
    let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("ikkoku-inspect: \(error)\n".utf8))
    exit(1)
}
