import Foundation
import CryptoKit
import Studio

/// Full framing inspection, deliberately separate from runtime scene restoration.
func inspectStudioScene(url: URL) throws -> [String: Any] {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
    let document = try KoikatsuSceneReader.decodeDocument(data)
    func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    func transform(_ value: KoikatsuChangeAmount) -> [String: Any] {
        ["position": [value.position.x, value.position.y, value.position.z],
         "rotationDegrees": [value.rotationDegrees.x, value.rotationDegrees.y, value.rotationDegrees.z],
         "scale": [value.scale.x, value.scale.y, value.scale.z]]
    }
    func bone(_ value: KoikatsuBoneRecord) -> [String: Any] { ["sourceKey": value.sourceKey, "transform": transform(value.transform)] }
    func object(_ value: KoikatsuObjectRecord) -> [String: Any] {
        var result: [String: Any] = ["kind": value.kind.rawValue, "sourceKey": value.sourceKey,
            "transform": transform(value.transform), "visible": value.visible, "treeState": value.treeState,
            "children": value.children.map(object)]
        if let key = value.rootDictionaryKey { result["rootDictionaryKey"] = key }
        if let name = value.name { result["name"] = name }
        if let character = value.character {
            result["character"] = ["sex": character.sex, "embeddedCardBytes": character.cardData.count,
                "embeddedCardSHA256": hash(character.cardData),
                "bones": character.bones.keys.sorted().map { ["catalogID": $0, "record": bone(character.bones[$0]!)] as [String: Any] },
                "ikTargets": character.ikTargets.keys.sorted().map { ["targetID": $0, "record": bone(character.ikTargets[$0]!)] as [String: Any] },
                "accessoryChildren": character.accessoryChildren.keys.sorted().map { ["accessoryPointID": $0, "children": character.accessoryChildren[$0]!.map(object)] as [String: Any] },
                "kinematicMode": character.kinematicMode, "enableFK": character.enableFK, "activeFK": character.activeFK,
                "enableIK": character.enableIK, "activeIK": character.activeIK,
                "animation": [character.animation.group, character.animation.category, character.animation.no],
                "animationSpeed": character.animationSpeed, "animationPattern": character.animationPattern,
                "animationNormalizedTime": character.animationNormalizedTime, "forceLoop": character.forceLoop,
                "handPatterns": character.handPatterns, "expressions": character.expressions,
                "voiceCount": character.voices.count, "neckDataSHA256": hash(character.neckData), "eyesDataSHA256": hash(character.eyesData)]
        }
        if let route = value.route {
            result["route"] = ["active": route.active, "loop": route.loop, "visibleLine": route.visibleLine,
                "orientation": route.orientation, "points": route.points.map { point in
                    ["record": bone(point.bone), "speed": point.speed, "easeType": point.easeType,
                     "connection": point.connection, "aid": bone(point.aid), "aidInitialized": point.aidInitialized,
                     "linked": point.linked] as [String: Any]
                }]
        }
        return result
    }
    let extensions = document.extensions()
    let plugins = (try? extensions.payload?.stringKeyedMap()) ?? [:]
    let pluginIDs = plugins.keys.sorted()
    return ["path": url.path, "sha256": hash(data), "version": document.snapshot.version,
        "coordinateSpace": "unity-left-handed-y-up", "angleUnit": "degrees", "lengthUnit": "unity-source-unit",
        "roots": document.snapshot.roots.map(object), "objectSectionEndOffset": document.snapshot.objectSectionEndOffset,
        "baseSceneEndOffset": document.baseSceneEndOffset, "trailingBytes": document.trailingData.count,
        "trailingSHA256": hash(document.trailingData), "scenePluginIDs": pluginIDs,
        "extendedSaveVersion": extensions.version as Any? ?? NSNull(),
        "scenePluginRecords": pluginIDs.map { id in
            ["id": id, "version": plugins[id]?.arrayValue?.first?.integerValue as Any? ?? NSNull(),
             "recordSlots": plugins[id]?.arrayValue?.count as Any? ?? NSNull()] as [String: Any]
        },
        "extensionDiagnostics": extensions.diagnostics, "map": document.settings.map,
        "cameraSlotCount": document.settings.cameraSlots.count, "sceneFloatSettings": document.settings.floatSettings,
        "sceneBoolSettings": document.settings.boolSettings, "background": document.settings.background,
        "frame": document.settings.frame,
        "scope": "Complete installed 1.0.4.2 record framing with retained original bytes. Parsing does not execute source appearance assembly, animations, IK, routes, dynamics, lighting, sound or plug-in callbacks."]
}
