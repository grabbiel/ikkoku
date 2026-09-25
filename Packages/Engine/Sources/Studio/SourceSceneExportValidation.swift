import Foundation
import Character
import Scene

/// Reject native workspace overrides that the original-scene writer cannot
/// represent. This checks values only and never reads assets or mutates a scene.
public enum SourceSceneExportValidation {
    public static func validate(_ document: StudioDocument, against snapshot: KoikatsuSceneSnapshot) throws {
        guard let sceneFile = document.sourceSceneFile, let sceneHash = document.sourceSceneSHA256 else {
            throw RigError.invalid("Import an original Studio scene first.")
        }
        try document.validateHierarchy()
        guard document.sourcePluginState == nil else {
            throw RigError.invalid("Original-scene export cannot serialize translated plugin runtime fields. Save this scene in native format to preserve its plugin identities and state.")
        }
        var records: [Int32: (KoikatsuObjectRecord, Bool)] = [:]
        func visit(_ record: KoikatsuObjectRecord, routeChild: Bool) {
            records[record.sourceKey] = (record, routeChild)
            for child in record.children { visit(child, routeChild: routeChild || record.kind == .route) }
            for children in (record.character?.accessoryChildren ?? [:]).values {
                for child in children { visit(child, routeChild: routeChild) }
            }
        }
        for root in snapshot.roots { visit(root, routeChild: false) }
        guard document.objects.count == records.count,
              Set(document.objects.compactMap(\.sourceObjectKey)).count == records.count else {
            throw RigError.invalid("Original-scene export does not yet support adding, duplicating or deleting objects.")
        }
        for object in document.objects {
            try SourceStudioIKEditing.validate(object.sourceIKOverrides ?? [:])
            try object.sourceKinematics?.validate()
            guard let key = object.sourceObjectKey, let (original, routeChild) = records[key] else {
                throw RigError.invalid("Original-scene export contains an unknown source object.")
            }
            let importedKind = object.sourcePreviewKind ?? (object.sourceCharacter == nil ? .folder : .character)
            guard object.kind == importedKind, importedKind == .folder || importedKind == .character else {
                throw RigError.invalid("Original-scene export does not yet support changing an object's type.")
            }
            let fallbackName: String
            if importedKind == .character {
                guard original.character != nil, !routeChild, let reference = object.sourceCharacter,
                      reference.objectKey == key, reference.sceneFile.utf8.elementsEqual(sceneFile.utf8),
                      reference.sceneSHA256.utf8.elementsEqual(sceneHash.utf8) else {
                    throw RigError.invalid("Source character reference no longer matches the original scene and object.")
                }
                fallbackName = "Source character \(key)"
            } else {
                guard object.sourceCharacter == nil, object.sourceFKRotations?.isEmpty != false, object.sourceIKOverrides?.isEmpty != false, object.sourceKinematics == nil, object.sourceAnimation == nil, object.sourceVoice == nil else {
                    throw RigError.invalid("Retained source placeholders cannot contain character references or FK edits.")
                }
                fallbackName = original.kind == .folder || (original.character != nil && !routeChild)
                    ? original.name ?? "Source object \(key)" : "Unrendered source \(original.kind) \(key)"
            }
            guard object.name.utf8.elementsEqual((object.sourcePreviewName ?? fallbackName).utf8) else {
                throw RigError.invalid("Original-scene export does not yet serialize object name edits.")
            }
            guard object.card == nil, object.handGestureL == 0, object.handGestureR == 0,
                  object.clothingVisible, object.accessoriesVisible else {
                throw RigError.invalid("Original-scene export does not yet serialize native card, hand or appearance overrides.")
            }
            guard object.itemID == nil, object.assetFile == nil, object.tint == nil, object.emissive == 0,
                  object.light == nil, object.savedCamera == nil, object.fov == 30 else {
                throw RigError.invalid("Original-scene export does not yet serialize native asset, material, light or object-camera overrides.")
            }
            guard object.animationPreset == nil, object.ikTargets.isEmpty, object.poseDelta == PoseDelta() else {
                throw RigError.invalid("Native prototype animation and pose edits cannot be serialized as original Studio data.")
            }
        }
    }
}
