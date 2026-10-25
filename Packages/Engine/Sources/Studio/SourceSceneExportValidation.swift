import Foundation
import simd
import CoreMath
import Character
import Scene

/// Reject native workspace overrides that the original-scene writer cannot
/// represent. This checks values only and never reads assets or mutates a scene.
public enum SourceSceneExportValidation {
    /// The source scene with the document's added objects written
    /// (`KoikatsuSceneDocument.inserting`) and the record key of every
    /// document object in it: its own key for a source record, the
    /// allocated key for a copy or a new object.
    public struct Staged: Sendable {
        public let stage: SourceSceneStage
        public let keys: [UUID: Int32]
    }

    /// ST-T03 / ST-S09 / ST-D03: the records the document adds, parents
    /// first, with the object each one is written for. A copy of a source
    /// record (`sourceDuplicateOf`) becomes a duplicate of that record's
    /// bytes; a native folder, camera or light becomes a new record with the
    /// object's transform in Unity basis, closed, with its visibility. Each
    /// parent's added children keep the document's order. New characters and
    /// items are refused.
    public static func insertions(_ document: StudioDocument) throws
        -> (insertions: [SourceSceneInsertion], objects: [UUID]) {
        try document.validateHierarchy()
        let added = document.objects.filter { $0.sourceObjectKey == nil }
        let addedIDs = Set(added.map(\.id))
        var children: [UUID: [StudioObject]] = [:]
        for object in added { if let parent = object.parent, addedIDs.contains(parent) { children[parent, default: []].append(object) } }
        let byID = Dictionary(uniqueKeysWithValues: document.objects.map { ($0.id, $0) })
        var insertions: [SourceSceneInsertion] = [], objects: [UUID] = [], index: [UUID: Int] = [:]
        func visit(_ object: StudioObject) throws {
            let parent: SourceSceneInsertion.Parent
            if let id = object.parent {
                if let owner = index[id] { parent = .inserted(owner) }
                else if let key = byID[id]?.sourceObjectKey { parent = .source(key) }
                else { throw RigError.invalid("Original-scene export contains an object under a missing parent.") }
            } else { parent = .root }
            let record: SourceSceneInsertion.Record
            if let template = object.sourceDuplicateOf {
                record = .duplicate(of: template)
            } else {
                let header = SourceSceneInsertion.Header(transform: .init(
                    position: UnityCoordinates.position(object.transform.position),
                    rotationDegrees: UnityCoordinates.sourceEulerDegrees(object.transform.quaternion),
                    scale: object.transform.scale), treeState: 1, visible: object.visible)
                switch object.kind {
                case .folder: record = .folder(name: object.name, header: header)
                case .camera: record = .camera(name: object.name, header: header)
                case .light:
                    guard let light = object.light else { throw RigError.invalid("Light \(object.name) has no light settings.") }
                    let no: Int32
                    switch light.kind { case .directional: no = 0; case .point: no = 1; case .spot: no = 2 }
                    record = .light(SourceSceneNewLight(no: no, color: SIMD4(light.color, 1), intensity: light.intensity,
                        range: light.range, spotAngle: light.spotAngle, shadow: light.castsShadow, enable: light.enabled), header: header)
                case .character, .item:
                    throw RigError.invalid("Original-scene export does not add new characters or items (\(object.name)); duplicate a source one or save in native format.")
                }
            }
            index[object.id] = insertions.count
            insertions.append(.init(record, parent: parent, attachment: object.sourceDuplicateOf == nil ? nil : object.sourceAttachmentPoint))
            objects.append(object.id)
            for child in children[object.id] ?? [] { try visit(child) }
        }
        for object in added where !(object.parent.map(addedIDs.contains) ?? false) { try visit(object) }
        return (insertions, objects)
    }

    /// Writes the document's added records into `source` (see `insertions`).
    public static func stage(_ document: StudioDocument, source: KoikatsuSceneDocument) throws -> Staged {
        let (insertions, objects) = try insertions(document)
        let stage = try source.inserting(insertions)
        var keys: [UUID: Int32] = [:]
        for object in document.objects { if let key = object.sourceObjectKey { keys[object.id] = key } }
        for (index, id) in objects.enumerated() { keys[id] = stage.keys[index] }
        return Staged(stage: stage, keys: keys)
    }

    /// Every object's key when the document adds nothing: each object must
    /// be a distinct source record.
    private static func sourceKeys(_ document: StudioDocument) throws -> [UUID: Int32] {
        var keys: [UUID: Int32] = [:]
        for object in document.objects {
            guard let key = object.sourceObjectKey else {
                throw RigError.invalid("Original-scene export of added or duplicated objects needs the staged scene (SourceSceneExportValidation.stage).")
            }
            keys[object.id] = key
        }
        return keys
    }

    /// ST-T03: the deletions and moves that turn the (staged) imported tree
    /// into the document's tree. `keys` maps every document object to its
    /// record in `snapshot` (`Staged.keys`); without it every object must be
    /// a source record. A missing record is deleted, and a record under
    /// another parent, or after a sibling it originally preceded, is moved
    /// (`SourceSceneTopology.edits`, which also refuses every unsupported
    /// case with its reason). Sibling order is the document's object order.
    public static func topologyEdits(_ document: StudioDocument, against snapshot: KoikatsuSceneSnapshot,
                                     keys: [UUID: Int32]? = nil) throws
        -> (deletions: Set<Int32>, reparents: [SourceSceneEdits.Reparent]) {
        let keys = try keys ?? sourceKeys(document)
        var seen = Set<Int32>()
        for object in document.objects {
            guard let key = keys[object.id], seen.insert(key).inserted else {
                throw RigError.invalid("Original-scene export contains an object without its own record.")
            }
        }
        let placements = try document.objects.map { object -> SourceSceneTopology.Placement in
            let parent = try object.parent.map { id -> Int32 in
                guard let key = keys[id] else { throw RigError.invalid("Original-scene export contains an object under a missing parent.") }
                return key
            }
            return .init(key: keys[object.id]!, parent: parent, attachment: object.sourceAttachmentPoint)
        }
        return try SourceSceneTopology.edits(from: snapshot, survivors: placements)
    }

    /// `keys` as in `topologyEdits`: pass `Staged.keys` with the staged
    /// snapshot whenever the document adds objects.
    public static func validate(_ document: StudioDocument, against snapshot: KoikatsuSceneSnapshot,
                                keys: [UUID: Int32]? = nil) throws {
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
        // Deleted and moved source records become topology edits; the
        // supported cases are exactly those `SourceSceneTopology` accepts.
        let keys = try keys ?? sourceKeys(document)
        _ = try topologyEdits(document, against: snapshot, keys: keys)
        for object in document.objects {
            try SourceStudioIKEditing.validate(object.sourceIKOverrides ?? [:])
            try object.sourceKinematics?.validate()
            guard let key = keys[object.id], let (original, routeChild) = records[key] else {
                throw RigError.invalid("Original-scene export contains an unknown source object.")
            }
            // A new native folder, camera or light: its record was written
            // from the object (`insertions`), so only values that record
            // cannot carry are refused.
            guard let recordKey = object.sourceRecordKey else { try validateNew(object); continue }
            if let route = object.sourceRoute {
                guard let record = original.route else {
                    throw RigError.invalid("Original-scene export writes route edits on route records only (\(object.name)).")
                }
                try route.validate(against: record)
            }
            let importedKind = object.sourcePreviewKind ?? (object.sourceCharacter == nil ? .folder : .character)
            guard object.kind == importedKind, importedKind == .folder || importedKind == .character else {
                throw RigError.invalid("Original-scene export does not yet support changing an object's type.")
            }
            let fallbackName: String
            if let outfit = object.sourceOutfit, !(0..<7).contains(outfit) {
                throw RigError.invalid("Source outfit selection must be in 0...6.")
            }
            if let state = object.sourceClothesState, state.count != 9 || state.contains(where: { $0 > 3 }) {
                throw RigError.invalid("Source clothes state must be nine ClothesKind values, each in 0...3.")
            }
            if let flags = object.sourceShowAccessory, flags.count != 20 {
                throw RigError.invalid("Source accessory visibility must contain exactly 20 slot flags.")
            }
            if let shoes = object.sourceShoesType, !(0...1).contains(shoes) {
                throw RigError.invalid("Source shoes type must be 0 (indoor) or 1 (outdoor).")
            }
            if importedKind == .character {
                guard original.character != nil, !routeChild, let reference = object.sourceCharacter,
                      reference.objectKey == recordKey, reference.sceneFile.utf8.elementsEqual(sceneFile.utf8),
                      reference.sceneSHA256.utf8.elementsEqual(sceneHash.utf8) else {
                    throw RigError.invalid("Source character reference no longer matches the original scene and object.")
                }
                fallbackName = "Source character \(recordKey)"
            } else {
                guard object.sourceCharacter == nil, object.sourceFKRotations?.isEmpty != false, object.sourceIKOverrides?.isEmpty != false, object.sourceFaceValues == nil, object.sourceBodyValues == nil, object.sourceColorEdits == nil, object.sourceOutfit == nil, object.sourceClothesState == nil, object.sourceShowAccessory == nil, object.sourceShoesType == nil, object.sourceExpression == nil, object.sourceKinematics == nil, object.sourceAnimation == nil, object.sourceVoice == nil else {
                    throw RigError.invalid("Retained source placeholders cannot contain character references or FK edits.")
                }
                // Routes like folders: their saved name is the baseline the
                // importer shows, so a rename is measured against the record.
                fallbackName = original.kind == .folder || original.kind == .route || (original.character != nil && !routeChild)
                    ? original.name ?? "Source object \(recordKey)" : "Unrendered source \(original.kind) \(recordKey)"
            }
            guard object.name.utf8.elementsEqual((object.sourcePreviewName ?? fallbackName).utf8)
                    || original.kind == .folder || original.kind == .camera || original.kind == .route else {
                throw RigError.invalid("Original-scene export does not serialize name edits for \(original.kind) records (the name lives elsewhere).")
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

    /// A native object the export writes as a new record: only a folder, a
    /// camera or a light, with nothing a CharaStudio record cannot hold.
    private static func validateNew(_ object: StudioObject) throws {
        guard object.sourceCharacter == nil, object.sourceRecordKind == nil, object.sourceAttachmentPoint == nil, object.sourceRoute == nil,
              object.sourceFKRotations?.isEmpty != false, object.sourceIKOverrides?.isEmpty != false, object.sourceFaceValues == nil,
              object.sourceBodyValues == nil, object.sourceColorEdits == nil, object.sourceOutfit == nil, object.sourceClothesState == nil,
              object.sourceShowAccessory == nil, object.sourceShoesType == nil, object.sourceExpression == nil,
              object.sourceKinematics == nil, object.sourceAnimation == nil, object.sourceVoice == nil else {
            throw RigError.invalid("New object \(object.name) carries source character or record data without a source record.")
        }
        guard object.card == nil, object.handGestureL == 0, object.handGestureR == 0, object.clothingVisible, object.accessoriesVisible,
              object.itemID == nil, object.assetFile == nil, object.tint == nil, object.emissive == 0,
              object.animationPreset == nil, object.ikTargets.isEmpty, object.poseDelta == PoseDelta() else {
            throw RigError.invalid("Original-scene export does not serialize native card, asset, material or pose data on a new \(object.kind) (\(object.name)).")
        }
        // CharaStudio applies no scale to a folder, camera or light (the
        // GuideObject scale rule), so a scaled one would not place its
        // children, view or light the same way after a reload.
        guard object.transform.scale == Float3(repeating: 1) else {
            throw RigError.invalid("Original-scene export writes new folders, cameras and lights with unit scale only; \(object.name) is scaled.")
        }
        switch object.kind {
        case .folder:
            guard object.light == nil, object.savedCamera == nil, object.fov == 30 else {
                throw RigError.invalid("New folder \(object.name) carries light or camera settings.")
            }
        case .camera:
            // The record carries the transform the view looks through; the
            // native saved view (`savedCamera`) is not part of it.
            guard object.light == nil, object.fov == 30 else {
                throw RigError.invalid("Original-scene export does not serialize a camera object's field of view or light settings (\(object.name)).")
            }
        case .light:
            guard let light = object.light, object.savedCamera == nil, object.fov == 30 else {
                throw RigError.invalid("New light \(object.name) has no light settings, or carries camera settings.")
            }
            guard light.spotBlend == SceneLight().spotBlend else {
                throw RigError.invalid("Original-scene export does not serialize a light's spot blend (CharaStudio lights have none); reset it on \(object.name).")
            }
        case .character, .item:
            throw RigError.invalid("Original-scene export does not add new characters or items (\(object.name)); duplicate a source one or save in native format.")
        }
    }
}
