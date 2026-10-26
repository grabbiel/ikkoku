import Foundation
import Character
import Assets

/// ST-T03i: the scene's plug-in (ExtendedSave) data after an export that
/// deletes, copies or adds objects, adds or deletes route points, or moves
/// objects. CharaStudio's save (`ExtendedSave` save hook) raises every
/// plug-in's scene-save event, removes nil entries and serializes the whole
/// `Dictionary<string, PluginData>` again; each plug-in writes its entry from
/// its loaded state and the objects it sees. This writer runs no plug-in, so
/// each entry ID it keeps through such an edit has a rule recovered from the
/// installed plug-in's save, load, copy and delete code
/// (docs/reference/studio/scene-editing.md, "Plug-in data"):
///
/// - Sideloader (`com.bepis.sideloader.universalautoresolver`) is rewritten:
///   one record per mod item, light or animation in the order CharaStudio
///   saves them, with each object's key and its per-kind position.
/// - Scene-global entries (no object reference) are kept.
/// - KKPE, MaterialEditor, NodesConstraints, KK_AnimationController and
///   StudioCustomMasking are kept when the part of the scene they read is
///   unchanged in the written document, or in their empty forms.
/// - Entries no installed plug-in contains (`orphanIDs`) are kept verbatim.
/// - A nil entry is inert; a rewritten trailer drops it as CharaStudio does.
///
/// Anything else refuses the whole export, naming the plug-in and the reason.
/// Unchanged entries keep their bytes, and a trailer with nothing to change
/// is returned as it was.
enum SourceScenePluginData {
    static let sideloader = "com.bepis.sideloader.universalautoresolver"
    static let kkpe = "kkpe"
    static let nodesConstraints = "nodesConstraints"
    static let animationController = "KK_AnimationController"
    static let materialEditor = "com.deathweasel.bepinex.materialeditor"
    static let customMasking = "com.deathweasel.bepinex.studiocustommasking"
    static let timeline = "timeline"
    static let cardAnimationController = "com.deathweasel.bepinex.animationcontroller"

    /// Scene entry IDs that none of the 243 DLLs installed under
    /// `BepInEx\plugins` contains, as ASCII/UTF-8 or UTF-16LE (installed
    /// inventory coverage index SHA-256
    /// e146e45a75652a6624518b17fb343d8e8705a6a7c957960cc7ed0c47f9cf9148,
    /// corpus digest d81258cce8929e62c4a69be5f35cc43b3f0cd9c41ed8ff1ecd69f7861bc91f79;
    /// no script host such as IronPython is installed either; see
    /// docs/reference/studio/scene-editing.md). Nothing in this install
    /// reads or writes them, so CharaStudio carries them verbatim through
    /// any edit, and so does this writer. Parity holds for this pinned
    /// install only: once such a plug-in is installed, its data may name
    /// objects an export changed.
    static let orphanIDs: Set<String> = ["KKVMDPlayExtSave", "rendererEditor", "com.rskoi.particleeditor", "vnge_kfa", "vnge_sss"]

    /// Entries whose data names no object: (ID, versions the recovered
    /// plug-in writes).
    static let sceneGlobal: [String: Set<Int64>] = [
        // StudioSceneSettings SceneController.OnSceneSave: map masking and
        // camera clip planes and shadow distance.
        "com.deathweasel.bepinex.studioscenesettings": [0],
        // StudioImageEmbed ImageEmbed.OnSceneSave: frame and background images.
        "com.deathweasel.bepinex.studioimageembed": [0],
        // TwoLut TwoLutPlugin.OnSceneSave: the second LUT's catalog identity.
        "TwoLutPlugin": [0],
        // StudioCharaLightLinkedToCamera: the light lock and its two angles.
        "com.jim60105.kk.studiocharalightlinkedtocamera": [3],
    ]

    static let names: [String: String] = [
        sideloader: "Sideloader", kkpe: "KKPE", nodesConstraints: "NodesConstraints",
        animationController: "KK_AnimationController", materialEditor: "MaterialEditor",
        customMasking: "StudioCustomMasking", "com.deathweasel.bepinex.studioscenesettings": "StudioSceneSettings",
        "com.deathweasel.bepinex.studioimageembed": "StudioImageEmbed", "TwoLutPlugin": "TwoLut",
        "com.jim60105.kk.studiocharalightlinkedtocamera": "StudioCharaLightLinkedToCamera", "timeline": "Timeline",
        "keelhauled.itemlayeredit": "ItemLayerEdit", "keelhauled.realpov": "RealPOV", "orange.spork.moarcamzplugin": "MoarCamz",
        "BetterScalingData": "BetterScaling", "LightSettingsData": "LightSettings", "org.njaecha.plugins.StudioItemIK": "StudioItemIK",
        "org.njaecha.plugins.objimport": "ObjImport", "com.rikkibalboa.bepinex.savecameraobjectfov": "SaveCameraObjectFov",
    ]

    /// The final scene: `data` (decoded as `final`) with its plug-in trailer
    /// following the edit, or refused with the reason. `source` is the scene
    /// before insertions; `copies` maps each copy's key to its template's.
    static func rewrite(_ data: Data, final: KoikatsuSceneDocument, source: KoikatsuSceneDocument,
                        copies: [Int32: Int32], moved: Bool) throws -> Data {
        guard !final.trailingData.isEmpty else { return data }
        let edit = Edit(source: source.snapshot, final: final.snapshot, copies: copies, moved: moved)
        guard edit.structural else { return data }
        let trailer: SourceSceneKKEx
        do { trailer = try SourceSceneKKEx.parse(final.trailingData) } catch {
            // Moves keep an unreadable trailer, as before.
            guard edit.keysChange else { return data }
            throw edit.refusal(["the scene's data after 【KStudio】 is not readable ExtendedSave data (\(error.localizedDescription))"])
        }
        var plan = Plan(trailer: trailer, edit: edit)
        try plan.decide()
        guard plan.changes else { return data }
        let rewritten = try plan.emit()
        var result = data.subdata(in: data.startIndex..<(data.startIndex + final.baseSceneEndOffset))
        result.append(contentsOf: rewritten)
        return result
    }

    // MARK: Edit

    /// What the export did to the object set, read from the source and the
    /// final documents.
    struct Edit {
        let source: KoikatsuSceneSnapshot, final: KoikatsuSceneSnapshot
        /// Each final record's source record: itself when kept, its template
        /// for a copy. New records have none.
        let origins: [Int32: Int32]
        /// The final records in CharaStudio's `dicObject` walk: roots in
        /// order, each record before its children, a character's accessory
        /// groups in ascending point order (`OICharInfo` creates them so).
        let finalRecords: [KoikatsuObjectRecord]
        let sourceRecords: [Int32: KoikatsuObjectRecord]
        /// Source records deleted (with their subtrees), and source records
        /// with a copy in the final scene.
        let deletedKeys: Set<Int32>, copiedKeys: Set<Int32>
        let added: Bool, routePoints: Bool, moved: Bool

        init(source: KoikatsuSceneSnapshot, final: KoikatsuSceneSnapshot, copies: [Int32: Int32], moved: Bool) {
            self.source = source; self.final = final; self.moved = moved
            var sourceRecords: [Int32: KoikatsuObjectRecord] = [:]
            for record in SourceSceneInsertionPlan.records(source) { sourceRecords[record.sourceKey] = record }
            self.sourceRecords = sourceRecords
            finalRecords = SourceSceneInsertionPlan.records(final)
            var origins: [Int32: Int32] = [:], kept = Set<Int32>(), copied = Set<Int32>(), points = false
            for record in finalRecords {
                if let template = copies[record.sourceKey] {
                    origins[record.sourceKey] = template; copied.insert(template); continue
                }
                guard let original = sourceRecords[record.sourceKey] else { continue }
                origins[record.sourceKey] = record.sourceKey; kept.insert(record.sourceKey)
                if let route = record.route, let before = original.route,
                   route.points.map(\.bone.sourceKey) != before.points.map(\.bone.sourceKey) { points = true }
            }
            self.origins = origins
            deletedKeys = Set(sourceRecords.keys).subtracting(kept)
            copiedKeys = copied
            added = finalRecords.count != origins.count
            routePoints = points
        }

        var deleted: Bool { !deletedKeys.isEmpty }
        var copied: Bool { !copiedKeys.isEmpty }
        var structural: Bool { deleted || copied || added || routePoints || moved }
        /// Objects or route points come or go. Entries without a rule
        /// refuse it; moves keep them as before.
        var keysChange: Bool { deleted || copied || added || routePoints }
        /// What data keyed by object key sees: an object deleted or copied.
        /// A new record carries no plug-in data, and route points are not
        /// objects plug-ins can name (they are not in `dicObjectCtrl`).
        var rekeys: Bool { deleted || copied }

        /// Sorted keys of the records of `kinds` (`nil`: every record): the
        /// keys of CharaStudio's `dicObjectCtrl` (`Studio.AddInfo` and
        /// `AddObjectCtrlInfo`). Route points are not among them:
        /// `AddObjectRoute.LoadPoint` registers a point with
        /// `Studio.AddCtrlInfo`, which fills `dicInfo` only.
        func keys(_ records: [KoikatsuObjectRecord], _ kinds: Set<KoikatsuObjectKind>?) -> [Int32] {
            var keys: [Int32] = []
            for record in records where kinds?.contains(record.kind) ?? true { keys.append(record.sourceKey) }
            return keys.sorted()
        }
        func unchanged(_ kinds: Set<KoikatsuObjectKind>?) -> Bool {
            keys(Array(sourceRecords.values), kinds) == keys(finalRecords, kinds)
        }
        /// Data addressing objects by their index in the key-sorted
        /// `dicObjectCtrl` still names the same objects: every source object
        /// keeps its index (the source keys are a prefix of the final ones:
        /// nothing removed, every new key above them) and nothing is copied
        /// (the plug-ins' `Studio.Duplicate` patches add data for copies).
        var positionsKept: Bool {
            !copied && keys(finalRecords, nil).starts(with: keys(Array(sourceRecords.values), nil))
        }
        /// Whether the edit deletes, or with `copies` copies, a key in `keys`.
        func touches(_ keys: Set<Int32>, copies: Bool) -> Bool {
            !keys.isDisjoint(with: deletedKeys) || (copies && !keys.isDisjoint(with: copiedKeys))
        }

        var actions: String {
            var parts: [String] = []
            if deleted { parts.append("delete objects") }
            if copied { parts.append("duplicate objects") }
            if added { parts.append("add objects") }
            if routePoints { parts.append("add or delete route points") }
            if moved && parts.isEmpty { parts.append("move objects") }
            if parts.count <= 1 { return parts.first ?? "edit objects" }
            return parts.dropLast().joined(separator: ", ") + " or " + parts.last!
        }

        func refusal(_ reasons: [String]) -> SourceSceneTopologyError {
            .unsupported("Original-scene export cannot \(actions) in this scene: \(reasons.joined(separator: "; ")). Save in native format instead.")
        }
    }

    // MARK: Plan

    struct Plan {
        enum Decision { case keep, replace([UInt8]), remove }
        let trailer: SourceSceneKKEx
        let edit: Edit
        var decisions: [Decision] = []
        var reasons: [String] = []
        /// Sideloader records expected after the rewrite, for the verifier.
        var sideloaderPlan: SideloaderPlan?

        init(trailer: SourceSceneKKEx, edit: Edit) { self.trailer = trailer; self.edit = edit }

        var changes: Bool {
            decisions.contains { if case .keep = $0 { return false } else { return true } }
        }

        private func label(_ id: String) -> String {
            names[id].map { "\($0) data ('\(id)')" } ?? "plug-in data '\(id)'"
        }

        mutating func decide() throws {
            var cardLinksChecked = false
            for entry in trailer.entries {
                var decision = Decision.keep
                if entry.isNil {
                    // nil PluginData: inert for any ID; ExtendedSave drops it.
                    decision = .remove
                } else if orphanIDs.contains(entry.id) {
                    decision = .keep
                } else {
                    var reason: String?
                    do {
                        reason = try decide(entry, cardLinksChecked: &cardLinksChecked, decision: &decision)
                    } catch {
                        // Data the rule cannot read is unknown data.
                        decision = .keep
                        reason = edit.keysChange ? "has data this writer cannot read (\(error.localizedDescription))" : nil
                    }
                    if let reason { reasons.append("\(label(entry.id)) \(reason)") }
                }
                decisions.append(decision)
            }
            if !reasons.isEmpty { throw edit.refusal(reasons) }
            // Nothing but nil entries to drop: keep the trailer as it was.
            let rewrites = zip(trailer.entries, decisions).contains { entry, decision in
                if case .keep = decision { return false }
                return !entry.isNil
            }
            if !rewrites { decisions = decisions.map { _ in .keep } }
        }

        /// The rule for one non-nil entry; a refusal reason, or nil.
        private mutating func decide(_ entry: SourceSceneKKEx.Entry, cardLinksChecked: inout Bool,
                                     decision: inout Decision) throws -> String? {
            let unknown = edit.keysChange ? "has no rule in this writer for following object edits (its plug-in's save, copy and delete code is not recovered here)" : nil
            guard let version = entry.version else {
                return edit.keysChange ? "is not a [version, data] PluginData value" : nil
            }
            func unknownVersion() -> String? {
                edit.keysChange ? "has version \(version), which this writer has not recovered" : nil
            }
            if let versions = sceneGlobal[entry.id] { return versions.contains(version) ? nil : unknownVersion() }
            switch entry.id {
            case sideloader:
                guard version == 0 else { return unknownVersion() }
                do {
                    let plan = try SideloaderPlan(trailer: trailer, entry: entry, edit: edit)
                    sideloaderPlan = plan
                    decision = plan.decision
                    return nil
                } catch let failure as SideloaderPlan.Failure {
                    // Moves keep the entry as before; the object set's
                    // changes need it read.
                    return edit.keysChange ? failure.reason : nil
                }
            case timeline:
                // Timeline.SceneWrite: each object interpolable's
                // `objectIndex` is its object's index in the key-sorted
                // dicObjectCtrl; global interpolables carry none.
                guard version == 0 else { return unknownVersion() }
                guard let xml = try TimelineForm.sceneInfo(trailer, entry) else { return unknown }
                if !xml.contains("objectIndex") || edit.positionsKept { return nil }
                return "addresses objects by their index among all objects in key order, and this edit removes, copies or renumbers some"
            case kkpe:
                // KKPE (HSPE/MainWindow.cs OnSceneSave, LoadSceneGeneric)
                // writes one element per item in key order and loads the
                // i-th element onto the i-th item: positional.
                guard version == 0 else { return unknownVersion() }
                if edit.unchanged([.item]) { return nil }
                return "matches its pose data to items by their position in key order, and this edit adds or removes items"
            case materialEditor:
                // MaterialEditor SceneController: edits keyed by item key;
                // only an item's delete or copy changes them.
                guard version == 0 || version == 1 else { return unknownVersion() }
                if try trailer.allNil(entry, keys: MaterialEditorForm.keys) || edit.unchanged([.item]) { return nil }
                return "keys its material edits by item, and this edit deletes or copies items"
            case nodesConstraints:
                guard version == 0 else { return unknownVersion() }
                if try NodesConstraintsForm.isEmpty(trailer, entry) {
                    return try cardLinks(&cardLinksChecked)
                }
                // Parent and child objects are indices in the key-sorted
                // dicObjectCtrl. The card fallback below adds to them on
                // load either way.
                if edit.positionsKept { return try cardLinks(&cardLinksChecked) }
                return "addresses objects by their index among all objects in key order, and this edit removes, copies or renumbers some"
            case animationController:
                guard version == 0 else { return unknownVersion() }
                switch try AnimationControllerForm(trailer, entry) {
                case .empty: return try cardLinks(&cardLinksChecked)
                case .emptyList: return nil
                case .links: return edit.rekeys ? "links characters to objects by key, and this edit deletes or copies objects" : nil
                case .unknown: return unknown
                }
            default:
                guard let rule = KeyedForm.rules[entry.id] else { return unknown }
                guard rule.versions.contains(version) else { return unknownVersion() }
                guard let found = try KeyedForm.references(trailer, entry, rule) else { return unknown }
                if edit.touches(found.keys, copies: rule.copies) {
                    return rule.copies ? "names objects by key, and this edit deletes or copies one of them"
                        : "names objects by key, and this edit deletes one of them"
                }
                if rule.lights, edit.finalRecords.contains(where: { $0.kind == .light && edit.origins[$0.sourceKey] != $0.sourceKey }) {
                    return "writes a record for every light, and this edit adds or copies a light"
                }
                if found.positional, !edit.unchanged([.camera]) {
                    return "selects a camera by its position in the camera list, and this edit adds, copies or deletes cameras"
                }
                return nil
            }
        }

        /// NodesConstraints.OnSceneLoad: with no `AnimationInfo` in the
        /// KK_AnimationController entry, every load also links each
        /// character to the objects its card's KKAnimationController data
        /// names by key (`LoadDataFromKKAnimationController`), and the next
        /// save writes those links. Refused when a character carries them.
        private func cardLinks(_ checked: inout Bool) throws -> String? {
            guard edit.rekeys, !checked else { return nil }
            checked = true
            switch try AnimationControllerForm.scene(trailer) {
            case .emptyList, .links, .unknown: return nil   // decided by its own entry
            case .empty: break
            }
            let marker = Data(cardAnimationController.utf8)
            for record in edit.finalRecords {
                guard let character = record.character, character.cardData.range(of: marker) != nil else { continue }
                let plugins: [String: SourceCharacterCard.PluginData]
                do { plugins = try character.card().extensions().plugins } catch {
                    return "cannot be checked: character \(record.sourceKey)'s card does not decode (\(error.localizedDescription))"
                }
                guard let data = plugins[cardAnimationController]?.data else { continue }
                let links = [data["Links"], data["Eyes"]].contains { value in value.map { $0 != .null } ?? false }
                if links {
                    return "would gain constraints on load: character \(record.sourceKey)'s card carries KKAnimationController links, which NodesConstraints turns into constraints by object key"
                }
            }
            return nil
        }

        /// The rewritten trailer: the source "KKEx" string and version, the
        /// new length, and the entry map with kept entries' bytes copied.
        func emit() throws -> [UInt8] {
            let bytes = trailer.bytes
            var map: [UInt8] = [], count = 0, expected: [(id: String, bytes: [UInt8])] = []
            for (entry, decision) in zip(trailer.entries, decisions) {
                var entryBytes: [UInt8]
                switch decision {
                case .remove: continue
                case .keep: entryBytes = Array(bytes[entry.span])
                case .replace(let value):
                    entryBytes = Array(bytes[entry.span.lowerBound..<entry.value.lowerBound]); entryBytes += value
                }
                map += entryBytes; count += 1; expected.append((entry.id, entryBytes))
            }
            var payload: [UInt8] = []
            payload.reserveCapacity(map.count + 5)
            SourceMessagePackWriter.header(.map, count: count, into: &payload)
            payload += map
            guard payload.count <= Int(Int32.max) else { throw KoikatsuReadError.limitExceeded("plug-in data exceeds 2 GiB") }
            var result = Array(bytes[trailer.prefix])
            withUnsafeBytes(of: Int32(payload.count).littleEndian) { result += $0 }
            result += payload
            try verify(result, expected: expected)
            return result
        }

        /// Reads the rewritten trailer back: the same framing, the planned
        /// entries in order with the planned bytes, and Sideloader's records
        /// decoding to their planned keys and positions.
        private func verify(_ result: [UInt8], expected: [(id: String, bytes: [UInt8])]) throws {
            func mismatch(_ what: String) -> SourceSceneTopologyError {
                .unsupported("The rewritten plug-in data differs from its plan (\(what)).")
            }
            let check: SourceSceneKKEx
            do { check = try SourceSceneKKEx.parse(Data(result)) } catch { throw mismatch("it does not parse: \(error.localizedDescription)") }
            guard check.dataVersion == trailer.dataVersion, check.entries.count == expected.count else { throw mismatch("entries") }
            for (entry, planned) in zip(check.entries, expected) {
                guard entry.id == planned.id, result[entry.span].elementsEqual(planned.bytes) else { throw mismatch("entry '\(planned.id)'") }
                if entry.id == sideloader, let plan = sideloaderPlan { try plan.verify(check, entry) }
            }
        }
    }
}

// MARK: - Recognized forms

/// MaterialEditor `SceneController.OnSceneSave`: version 1 with these ten
/// keys, each serialized bytes or nil; `OnSceneLoad` reads a list only when
/// its key is present and non-nil (version 0 entries carry fewer keys).
/// Every value nil is the empty state: nothing to delete or copy.
enum MaterialEditorForm {
    static let keys: Set<String> = ["TextureDictionary", "RendererPropertyList", "ProjectorPropertyList",
        "MaterialNamePropertyList", "MaterialFloatPropertyList", "MaterialKeywordPropertyList",
        "MaterialColorPropertyList", "MaterialTexturePropertyList", "MaterialShaderList", "MaterialCopyList"]
}

/// NodesConstraints `OnSceneSave` writes `{"constraints": xml}`: a
/// `<constraints version=…>` element with one child per constraint. With no
/// child it holds no object reference.
enum NodesConstraintsForm {
    static func isEmpty(_ trailer: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry) throws -> Bool {
        guard let fields = try trailer.fields(entry), fields.count == 1, fields[0].key == "constraints",
              let xml = try trailer.string(fields[0].value) else { return false }
        return isEmpty(xml)
    }

    /// `<constraints a="…" … />` or `<constraints …></constraints>`, with
    /// attributes only.
    static func isEmpty(_ xml: String) -> Bool {
        var text = Substring(xml.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.hasPrefix("<constraints"), !text.contains("<constraint "), !text.contains("<constraint>") else { return false }
        text = text.dropFirst("<constraints".count)
        guard let close = text.firstIndex(of: ">") else { return false }
        var attributes = text[..<close]
        let rest = text[text.index(after: close)...]
        if attributes.hasSuffix("/") {
            guard rest.isEmpty else { return false }
            attributes = attributes.dropLast()
        } else {
            guard rest.trimmingCharacters(in: .whitespacesAndNewlines) == "</constraints>" else { return false }
        }
        // name="value" pairs only.
        let pattern = #"^(\s+[A-Za-z_][A-Za-z0-9_.-]*\s*=\s*"[^"<>]*")*\s*$"#
        return attributes.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Recovered plug-ins whose scene data names objects by key, in fields that
/// hold MessagePack-serialized `[MessagePackObject(true)]` maps or integer
/// collections (KKAPI `SceneCustomFunctionController`, version 0). Each
/// rule lists the fields the plug-in writes and how its object keys are
/// read; an unknown field, or one that does not decode, makes the entry
/// unknown. The entry is kept unless the edit deletes a named object, or
/// copies one when the plug-in's `OnObjectsCopied` writes data for copies.
enum KeyedForm {
    enum Field {
        /// No object key.
        case none
        /// Every integer named `name` in the decoded maps.
        case named(String)
        /// Every integer in the decoded collection, map keys included.
        case ints
        /// A plain integer selecting by position (0: none).
        case index
    }
    struct Rule {
        var versions: Set<Int64> = [0]
        let fields: [String: Field]
        /// `OnObjectsCopied` writes data for the copy of a named object.
        let copies: Bool
        /// The save writes a record for every live light.
        var lights = false
    }

    static let rules: [String: Rule] = [
        // StudioCustomMasking SceneController: masking folder keys; a copy
        // of one is masked too.
        SourceScenePluginData.customMasking: Rule(fields: ["MaskingFolders": .ints], copies: true),
        // ItemLayerEdit SceneDataController: LayerSaveData per item with a
        // changed layer; the copy takes the layer.
        "keelhauled.itemlayeredit": Rule(fields: ["SavedLayers": .named("ObjectId")], copies: true),
        // RealPOV SceneDataController: ScenePovData's character key (-1 for
        // none); copies are not handled.
        "keelhauled.realpov": Rule(fields: ["PovData": .named("CharaId")], copies: false),
        // MoarCamz: camera slots and the current view, each with a centre
        // target key; copies are not handled.
        "orange.spork.moarcamzplugin": Rule(fields: ["MoarCamz": .named("CenterTarget"), "MoarCamzInitial": .named("CenterTarget"),
                                                     "MoarCamzLastSelection": .none], copies: false),
        // BetterScaling BetterScalingDataController: the folder-scaling flag
        // and the keys of hierarchy-scaled objects; a copy is scaled too.
        "BetterScalingData": Rule(fields: ["BetterScalingData_scaledFoldersFlag": .none, "BetterScalingData_scaledOCI": .ints],
                                  copies: true),
        // LightSettings SceneDataController: a LightSaveData per light by
        // key (-10 and -20 are the character and map lights) and the cookie
        // textures; every live studio light gets a record and a copy takes
        // its template's settings.
        "LightSettingsData": Rule(fields: ["LightSettingsData_lights": .named("ObjectId"), "LightSettingsData_cookies": .none],
                                  copies: true, lights: true),
        // StudioItemIK SceneController: IK item keys with their target and
        // pole item keys; the IK is rebuilt on a copy.
        "org.njaecha.plugins.StudioItemIK": Rule(fields: ["activeIKs": .ints, "objectTargetPairs": .ints], copies: true),
        // ObjImport SceneController: imported meshes and their item keys;
        // the mesh is copied to a copy. Empty: `[0, {}]`.
        "org.njaecha.plugins.objimport": Rule(fields: ["version": .none, "meshes": .none, "ids": .ints], copies: true),
        // SaveCameraObjectFov SceneController: field of view per camera key,
        // and the camera selector's index (0: the main camera). A copy has
        // no entry, so its save throws and keeps the loaded entry.
        "com.rikkibalboa.bepinex.savecameraobjectfov": Rule(fields: ["cameras": .ints, "mainFov": .none,
                                                                     "previousCameraIndex": .index, "cameraIndex": .index],
                                                            copies: false),
    ]

    /// The object keys the entry names, and whether it selects by position;
    /// nil when the entry has a field or value the rule does not know.
    static func references(_ trailer: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry,
                           _ rule: Rule) throws -> (keys: Set<Int32>, positional: Bool)? {
        guard let fields = try trailer.fields(entry) else { return ([], false) }
        var keys = Set<Int32>(), positional = false
        for field in fields {
            guard let reader = rule.fields[field.key] else { return nil }
            var cursor = SourceMessagePackSpans(trailer.bytes, range: field.value)
            let head = try cursor.head()
            if head == .null { continue }
            switch reader {
            case .none: continue
            case .index:
                guard let value = SourceMessagePackSpans.integer(head) else { return nil }
                if value != 0 { positional = true }
            case .named, .ints:
                guard case .binary(let count) = head,
                      let value = try? SourceMessagePack.decode(Data(trailer.bytes[try cursor.payload(count)])) else { return nil }
                var found: [Int64] = []
                collect(value, reader, into: &found)
                for number in found { if let key = Int32(exactly: number) { keys.insert(key) } }
            }
        }
        return (keys, positional)
    }

    private static func collect(_ value: SourceMessagePackValue, _ field: Field, into found: inout [Int64]) {
        switch value {
        case .integer(let number): if case .ints = field { found.append(number) }
        case .unsigned(let number): if case .ints = field, let number = Int64(exactly: number) { found.append(number) }
        case .array(let values): for value in values { collect(value, field, into: &found) }
        case .map(let entries):
            for entry in entries {
                if case .named(let name) = field, entry.key.stringValue == name, let number = entry.value.integerValue {
                    found.append(Int64(number))
                }
                collect(entry.key, field, into: &found); collect(entry.value, field, into: &found)
            }
        default: break
        }
    }
}

/// Timeline `OnSceneSave` writes `{"sceneInfo": xml}`.
enum TimelineForm {
    static func sceneInfo(_ trailer: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry) throws -> String? {
        guard let fields = try trailer.fields(entry), fields.count == 1, fields[0].key == "sceneInfo" else { return nil }
        return try trailer.string(fields[0].value)
    }
}

/// The KK_AnimationController scene entry (no installed writer; read only by
/// NodesConstraints `LoadDataFromKKAnimationController`).
enum AnimationControllerForm {
    /// No `AnimationInfo`: each character's card data is read instead.
    case empty
    /// An empty `AnimationInfo` list: no links, and no card fallback.
    case emptyList
    /// `AnimationInfo` records: character and object keys.
    case links
    case unknown

    init(_ trailer: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry) throws {
        guard !entry.isNil else { self = .empty; return }
        guard entry.version == 0, entry.data != nil else { self = .unknown; return }
        guard let fields = try trailer.fields(entry) else { self = .empty; return }
        if fields.isEmpty { self = .empty; return }
        guard fields.count == 1, fields[0].key == "AnimationInfo" else { self = .unknown; return }
        var cursor = SourceMessagePackSpans(trailer.bytes, range: fields[0].value)
        guard case .array(let count) = try cursor.head() else { self = .unknown; return }
        self = count == 0 ? .emptyList : .links
    }

    /// The scene's form: absent counts as `.empty`.
    static func scene(_ trailer: SourceSceneKKEx) throws -> Self {
        guard let entry = trailer.entries.first(where: { $0.id == SourceScenePluginData.animationController }) else { return .empty }
        return try Self(trailer, entry)
    }
}

// MARK: - Sideloader

/// Sideloader `UniversalAutoResolver.SavePrefix` (SceneInfo.Save): walking
/// `dicObject` depth first (`StudioObjectSearch`: roots in order, then item,
/// folder and route `child` lists and a character's accessory groups; route
/// points are not objects there), one `itemInfo` record per item or light
/// whose number is a mod's and per character playing a mod animation, and one
/// `patternInfo` record per item with mod patterns. `SceneDicKey` is the
/// object's key and `SceneObjectOrder` its position among the objects of its
/// own type in that walk. Then the scene's map, filter, ramp and BGM
/// identities. An empty dictionary removes the entry. Loading
/// (`ResolveStudioObjects`) reads each record's object by key unchecked, so a
/// record for a missing or repeated key would throw.
///
/// The rewrite keeps each record's bytes, writes the final key and position
/// into its two integers (MessagePack-CSharp's shortest encoding), clones a
/// template's records for each copy, drops a deleted object's records, and
/// writes the records in the final walk's order.
struct SideloaderPlan {
    struct Failure: Error { let reason: String }
    struct Record {
        let payload: Range<Int>
        let key: Int64, keySpan: Range<Int>
        let order: Int64, orderSpan: Range<Int>
    }
    struct Planned { let record: Int; let key: Int32; let order: Int32 }

    static let recordKeys: Set<String> = ["ModID", "Slot", "LocalSlot", "SceneDicKey", "SceneObjectOrder",
                                          "ResolveItem", "Group", "Category", "Author", "Website", "Name"]
    static let patternKeys: Set<String> = ["SceneDicKey", "SceneObjectOrder", "ObjectPatternInfo"]
    static let sceneKeys: [String] = ["map", "filter", "ramp", "bgm"].flatMap { group in
        ["GUID", "Author", "Website", "Name"].map { "\(group)Info\($0)" }
    }

    /// The source trailer's bytes, which every record range indexes.
    let sourceBytes: [UInt8]
    let items: [Record], patterns: [Record]
    let plannedItems: [Planned], plannedPatterns: [Planned]
    let decision: SourceScenePluginData.Plan.Decision

    init(trailer: SourceSceneKKEx, entry: SourceSceneKKEx.Entry, edit: SourceScenePluginData.Edit) throws {
        let bytes = trailer.bytes
        sourceBytes = bytes
        let read: [SourceMessagePackSpans.Field]?
        do { read = try trailer.fields(entry) } catch { throw Failure(reason: "has a data value that is not a map") }
        guard let fields = read else {
            items = []; patterns = []; plannedItems = []; plannedPatterns = []; decision = .keep; return
        }
        var lists: [String: (key: Range<Int>, records: [Record])] = [:], scene: [String: Range<Int>] = [:]
        for field in fields {
            switch field.key {
            case "itemInfo", "patternInfo":
                let pattern = field.key == "patternInfo"
                let records = try Self.records(bytes, field.value, keys: pattern ? Self.patternKeys : Self.recordKeys)
                lists[field.key] = (field.entry.lowerBound..<field.value.lowerBound, records)
            case let key where Self.sceneKeys.contains(key):
                scene[key] = field.entry
            default:
                throw Failure(reason: "has a data key '\(field.key)' this writer does not know")
            }
        }
        items = lists["itemInfo"]?.records ?? []; patterns = lists["patternInfo"]?.records ?? []
        // Every record names one source object of its kind, once.
        func index(_ records: [Record], kinds: Set<KoikatsuObjectKind>) throws -> [Int32: Int] {
            var result: [Int32: Int] = [:]
            for (position, record) in records.enumerated() {
                guard let key = Int32(exactly: record.key), let object = edit.sourceRecords[key] else {
                    throw Failure(reason: "has a record for object \(record.key), which the scene does not have")
                }
                guard kinds.contains(object.kind) else {
                    throw Failure(reason: "has a record for object \(key), a \(object.kind) rather than an item, light or character")
                }
                guard result.updateValue(position, forKey: key) == nil else { throw Failure(reason: "has two records for object \(key)") }
            }
            return result
        }
        let itemIndex = try index(items, kinds: [.item, .light, .character])
        let patternIndex = try index(patterns, kinds: [.item])
        // Positions per type in the final walk (`FindObjectInfoOrder`).
        var counters: [KoikatsuObjectKind: Int32] = [:], order: [Int32: Int32] = [:]
        for record in edit.finalRecords where record.kind == .item || record.kind == .light || record.kind == .character {
            order[record.sourceKey] = counters[record.kind, default: 0]
            counters[record.kind, default: 0] += 1
        }
        var plannedItems: [Planned] = [], plannedPatterns: [Planned] = []
        for record in edit.finalRecords {
            guard let origin = edit.origins[record.sourceKey], let position = order[record.sourceKey] else { continue }
            if let index = itemIndex[origin] { plannedItems.append(.init(record: index, key: record.sourceKey, order: position)) }
            if let index = patternIndex[origin] { plannedPatterns.append(.init(record: index, key: record.sourceKey, order: position)) }
        }
        self.plannedItems = plannedItems; self.plannedPatterns = plannedPatterns
        func same(_ planned: [Planned], _ records: [Record]) -> Bool {
            planned.count == records.count && planned.enumerated().allSatisfy { position, plan in
                plan.record == position && Int64(plan.key) == records[position].key && Int64(plan.order) == records[position].order
            }
        }
        let itemsSame = same(plannedItems, items), patternsSame = same(plannedPatterns, patterns)
        if itemsSame && patternsSame { decision = .keep; return }
        // CharaStudio's dictionary order: itemInfo, patternInfo, then the
        // scene identities.
        var map: [UInt8] = [], count = 0
        func list(_ name: String, _ planned: [Planned], _ records: [Record]) {
            guard !planned.isEmpty, let key = lists[name]?.key else { return }
            map += bytes[key]
            SourceMessagePackWriter.header(.array, count: planned.count, into: &map)
            for plan in planned { Self.emit(bytes, records[plan.record], plan, into: &map) }
            count += 1
        }
        list("itemInfo", plannedItems, items)
        list("patternInfo", plannedPatterns, patterns)
        for key in Self.sceneKeys { if let span = scene[key] { map += bytes[span]; count += 1 } }
        guard count > 0 else { decision = .remove; return }
        guard let data = entry.data else { throw Failure(reason: "has no data map") }
        var value = Array(bytes[entry.value.lowerBound..<data.lowerBound])
        SourceMessagePackWriter.header(.map, count: count, into: &value)
        value += map
        decision = .replace(value)
    }

    /// An `itemInfo`/`patternInfo` list: an array of bin, each one record map.
    private static func records(_ bytes: [UInt8], _ range: Range<Int>, keys: Set<String>) throws -> [Record] {
        var cursor = SourceMessagePackSpans(bytes, range: range)
        guard case .array(let count) = try cursor.head() else { throw Failure(reason: "has a record list that is not an array") }
        var result: [Record] = []
        for _ in 0..<count {
            guard case .binary(let length) = try cursor.head() else { throw Failure(reason: "has a record that is not bytes") }
            let payload = try cursor.payload(length)
            var record = SourceMessagePackSpans(bytes, range: payload)
            guard let fields = try record.fields(), record.offset == payload.upperBound else {
                throw Failure(reason: "has a record that is not one map")
            }
            var key: (Int64, Range<Int>)?, order: (Int64, Range<Int>)?
            for field in fields {
                guard keys.contains(field.key) else { throw Failure(reason: "has a record key '\(field.key)' this writer does not know") }
                guard field.key == "SceneDicKey" || field.key == "SceneObjectOrder" else { continue }
                var number = SourceMessagePackSpans(bytes, range: field.value)
                guard let value = SourceMessagePackSpans.integer(try number.head()), Int32(exactly: value) != nil else {
                    throw Failure(reason: "has a record whose \(field.key) is not an Int32")
                }
                if field.key == "SceneDicKey" { key = (value, field.value) } else { order = (value, field.value) }
            }
            guard let key, let order else { throw Failure(reason: "has a record without SceneDicKey and SceneObjectOrder") }
            result.append(.init(payload: payload, key: key.0, keySpan: key.1, order: order.0, orderSpan: order.1))
        }
        guard cursor.offset == range.upperBound else { throw Failure(reason: "has a malformed record list") }
        return result
    }

    /// One record's bin: its bytes with the planned key and position.
    private static func emit(_ bytes: [UInt8], _ record: Record, _ plan: Planned, into out: inout [UInt8]) {
        var patches: [(Range<Int>, Int64)] = []
        if record.key != Int64(plan.key) { patches.append((record.keySpan, Int64(plan.key))) }
        if record.order != Int64(plan.order) { patches.append((record.orderSpan, Int64(plan.order))) }
        patches.sort { $0.0.lowerBound < $1.0.lowerBound }
        var payload: [UInt8] = [], cursor = record.payload.lowerBound
        payload.reserveCapacity(record.payload.count + 8)
        for (span, value) in patches {
            payload += bytes[cursor..<span.lowerBound]
            SourceMessagePackWriter.integer(value, into: &payload)
            cursor = span.upperBound
        }
        payload += bytes[cursor..<record.payload.upperBound]
        SourceMessagePackWriter.header(.binary, count: payload.count, into: &out)
        out += payload
    }

    /// The rewritten entry decodes to the planned records: each one its
    /// source record's fields with the planned key and position.
    func verify(_ check: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry) throws {
        func mismatch(_ what: String) -> SourceSceneTopologyError {
            .unsupported("The rewritten Sideloader data differs from its plan (\(what)).")
        }
        guard let fields = try check.fields(entry) else { throw mismatch("no data") }
        func decoded(_ bytes: [UInt8], _ range: Range<Int>) throws -> [String: SourceMessagePackValue] {
            try SourceMessagePack.decode(Data(bytes[range])).stringKeyedMap()
        }
        for (name, planned, records) in [("itemInfo", plannedItems, items), ("patternInfo", plannedPatterns, patterns)] {
            let written = fields.first { $0.key == name }
            guard !planned.isEmpty else { if written != nil { throw mismatch("\(name) is written empty") }; continue }
            guard let written else { throw mismatch("\(name) is missing") }
            let rewritten = try Self.records(check.bytes, written.value, keys: name == "itemInfo" ? Self.recordKeys : Self.patternKeys)
            guard rewritten.count == planned.count else { throw mismatch("\(name) count") }
            for (record, plan) in zip(rewritten, planned) {
                var after = try decoded(check.bytes, record.payload)
                var before = try decoded(sourceBytes, records[plan.record].payload)
                guard after["SceneDicKey"]?.integerValue == Int(plan.key),
                      after["SceneObjectOrder"]?.integerValue == Int(plan.order) else { throw mismatch("\(name) record for object \(plan.key)") }
                for key in ["SceneDicKey", "SceneObjectOrder"] { after[key] = nil; before[key] = nil }
                guard after == before else { throw mismatch("\(name) record for object \(plan.key)") }
            }
        }
    }
}

// MARK: - KKEx trailer

/// The ExtendedSave scene trailer (`ExtendedSave` `SceneInfoLoadHook` and
/// save hook): the .NET string "KKEx", an Int32 data version, an Int32
/// length, then that many bytes of MessagePack `Dictionary<string,
/// PluginData>`, where `PluginData` is `[version, data]`.
struct SourceSceneKKEx {
    struct Entry {
        let id: String
        /// The entry's key and value bytes.
        let span: Range<Int>
        let value: Range<Int>
        let isNil: Bool
        /// `[version, data]`: nil when the value has another shape.
        let version: Int64?
        let data: Range<Int>?
    }
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    let bytes: [UInt8]
    let dataVersion: Int32
    /// "KKEx" and the data version, copied into a rewrite.
    let prefix: Range<Int>
    let payload: Range<Int>
    let entries: [Entry]

    static func parse(_ trailer: Data) throws -> SourceSceneKKEx {
        let bytes = [UInt8](trailer)
        guard bytes.count >= 13, bytes[0] == 4, Array(bytes[1..<5]) == Array("KKEx".utf8) else {
            throw Failure(reason: "the trailer is not ExtendedSave's KKEx block")
        }
        func int32(_ at: Int) -> Int32 {
            Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        let version = int32(5), length = Int(int32(9))
        guard length > 0, length == bytes.count - 13 else {
            throw Failure(reason: "the KKEx length \(length) does not match its \(bytes.count - 13) payload bytes")
        }
        let payload = 13..<bytes.count
        var cursor = SourceMessagePackSpans(bytes, range: payload)
        var entries: [Entry] = [], ids = Set<String>()
        switch try cursor.head() {
        case .null: break
        case .map(let count):
            for _ in 0..<count {
                let start = cursor.offset
                let id = try cursor.string()
                guard ids.insert(id).inserted else { throw Failure(reason: "the plug-in ID '\(id)' appears twice") }
                let valueStart = cursor.offset
                var shape = cursor
                let isNil: Bool, pluginVersion: Int64?, data: Range<Int>?
                switch try shape.head() {
                case .null:
                    isNil = true; pluginVersion = nil; data = nil
                case .array(2):
                    isNil = false
                    pluginVersion = SourceMessagePackSpans.integer(try shape.head())
                    let dataStart = shape.offset
                    try shape.skip()
                    data = dataStart..<shape.offset
                default:
                    isNil = false; pluginVersion = nil; data = nil
                }
                try cursor.skip()
                entries.append(Entry(id: id, span: start..<cursor.offset, value: valueStart..<cursor.offset,
                                     isNil: isNil, version: pluginVersion, data: data))
            }
        default: throw Failure(reason: "the KKEx payload is not a map")
        }
        guard cursor.offset == payload.upperBound else { throw Failure(reason: "bytes follow the KKEx map") }
        return SourceSceneKKEx(bytes: bytes, dataVersion: version, prefix: 0..<9, payload: payload, entries: entries)
    }

    /// The entry's data map fields; nil for a nil data value.
    func fields(_ entry: Entry) throws -> [SourceMessagePackSpans.Field]? {
        guard let data = entry.data else { throw Failure(reason: "'\(entry.id)' has no data value") }
        var cursor = SourceMessagePackSpans(bytes, range: data)
        return try cursor.fields()
    }

    /// The value at `range` when it is a string.
    func string(_ range: Range<Int>) throws -> String? {
        var cursor = SourceMessagePackSpans(bytes, range: range)
        guard case .string = try cursor.peek() else { return nil }
        return try cursor.string()
    }

    /// Whether the entry's data is nil, or a map of `keys` whose values are
    /// all nil.
    func allNil(_ entry: Entry, keys: Set<String>) throws -> Bool {
        guard let fields = try fields(entry) else { return true }
        return try fields.allSatisfy { field in
            guard keys.contains(field.key) else { return false }
            var cursor = SourceMessagePackSpans(bytes, range: field.value)
            return try cursor.head() == .null
        }
    }
}

public extension KoikatsuSceneDocument {
    /// The scene's ExtendedSave entries that no installed plug-in reads
    /// (`SourceScenePluginData.orphanIDs`), sorted. Every original-scene
    /// export carries them verbatim.
    var orphanPluginIDs: [String] {
        guard !trailingData.isEmpty, let trailer = try? SourceSceneKKEx.parse(trailingData) else { return [] }
        return trailer.entries.filter { !$0.isNil && SourceScenePluginData.orphanIDs.contains($0.id) }.map(\.id).sorted()
    }
}

// MARK: - MessagePack spans

/// MessagePack located rather than decoded: each value's byte span, so a
/// rewrite copies every byte it does not change. Limits follow
/// `SourceMessagePack.decode` (64 container levels, 1,000,000 values).
struct SourceMessagePackSpans {
    enum Head: Equatable {
        case map(Int), array(Int), string(Int), binary(Int), ext(Int)
        case integer(Int64), unsigned(UInt64), null, bool(Bool), float
    }
    struct Field { let key: String; let entry: Range<Int>; let value: Range<Int> }

    let bytes: [UInt8]
    let end: Int
    private(set) var offset: Int
    private var budget = 1_000_000

    init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes; offset = range.lowerBound; end = range.upperBound
    }

    static func integer(_ head: Head) -> Int64? {
        switch head {
        case .integer(let value): return value
        case .unsigned(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    private func fail(_ reason: String) -> SourceMessagePackError { .invalid(reason) }

    private mutating func byte() throws -> UInt8 {
        guard offset < end else { throw fail("truncated value") }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func word(_ count: Int) throws -> UInt64 {
        guard count <= end - offset else { throw fail("truncated numeric value") }
        var result: UInt64 = 0
        for _ in 0..<count { result = result << 8 | UInt64(bytes[offset]); offset += 1 }
        return result
    }

    /// The `count` payload bytes at the cursor, skipped.
    mutating func payload(_ count: Int) throws -> Range<Int> {
        guard count >= 0, count <= end - offset else { throw fail("truncated byte payload") }
        defer { offset += count }
        return offset..<(offset + count)
    }

    /// The next value's header without moving the cursor.
    func peek() throws -> Head { var copy = self; return try copy.head() }

    /// One value's header. A string, binary or extension leaves the cursor
    /// at its payload (an extension after its type byte).
    mutating func head() throws -> Head {
        guard budget > 0 else { throw fail("decoded value limit exceeded") }
        budget -= 1
        let code = try byte()
        switch code {
        case 0x00...0x7f: return .integer(Int64(code))
        case 0x80...0x8f: return .map(Int(code & 15))
        case 0x90...0x9f: return .array(Int(code & 15))
        case 0xa0...0xbf: return .string(Int(code & 31))
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: return .binary(Int(try word(1)))
        case 0xc5: return .binary(Int(try word(2)))
        case 0xc6: return .binary(Int(try word(4)))
        case 0xc7, 0xc8, 0xc9:
            let count = Int(try word(code == 0xc7 ? 1 : code == 0xc8 ? 2 : 4))
            _ = try byte(); return .ext(count)
        case 0xca: _ = try payload(4); return .float
        case 0xcb: _ = try payload(8); return .float
        case 0xcc: return .unsigned(try word(1))
        case 0xcd: return .unsigned(try word(2))
        case 0xce: return .unsigned(try word(4))
        case 0xcf: return .unsigned(try word(8))
        case 0xd0: return .integer(Int64(Int8(truncatingIfNeeded: try word(1))))
        case 0xd1: return .integer(Int64(Int16(truncatingIfNeeded: try word(2))))
        case 0xd2: return .integer(Int64(Int32(truncatingIfNeeded: try word(4))))
        case 0xd3: return .integer(Int64(bitPattern: try word(8)))
        case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8:
            _ = try byte(); return .ext(1 << Int(code - 0xd4))
        case 0xd9: return .string(Int(try word(1)))
        case 0xda: return .string(Int(try word(2)))
        case 0xdb: return .string(Int(try word(4)))
        case 0xdc: return .array(Int(try word(2)))
        case 0xdd: return .array(Int(try word(4)))
        case 0xde: return .map(Int(try word(2)))
        case 0xdf: return .map(Int(try word(4)))
        case 0xe0...0xff: return .integer(Int64(Int8(bitPattern: code)))
        default: throw fail("reserved code 0xc1")
        }
    }

    /// Skips one complete value.
    mutating func skip(depth: Int = 0) throws {
        switch try head() {
        case .map(let count): try children(count * 2, depth)
        case .array(let count): try children(count, depth)
        case .string(let count), .binary(let count), .ext(let count): _ = try payload(count)
        default: break
        }
    }

    private mutating func children(_ count: Int, _ depth: Int) throws {
        guard depth < 64 else { throw fail("container nesting exceeds 64") }
        // Each child takes at least one byte.
        guard count <= end - offset else { throw fail("truncated container") }
        for _ in 0..<count { try skip(depth: depth + 1) }
    }

    /// A UTF-8 string value.
    mutating func string() throws -> String {
        guard case .string(let count) = try head() else { throw fail("expected a string") }
        let range = try payload(count)
        guard let value = String(bytes: bytes[range], encoding: .utf8) else { throw fail("string is not valid UTF-8") }
        return value
    }

    /// A string-keyed map's fields in order, or nil for a nil value.
    mutating func fields() throws -> [Field]? {
        let head = try head()
        if head == .null { return nil }
        guard case .map(let count) = head else { throw fail("expected a map") }
        guard count <= end - offset else { throw fail("truncated container") }
        var result: [Field] = [], keys = Set<String>()
        for _ in 0..<count {
            let start = offset
            let key = try string()
            guard keys.insert(key).inserted else { throw fail("duplicate string map key '\(key)'") }
            let valueStart = offset
            try skip(depth: 1)
            result.append(Field(key: key, entry: start..<offset, value: valueStart..<offset))
        }
        return result
    }
}

/// MessagePack-CSharp 1.x's shortest encodings (`MessagePackBinary`
/// `WriteInt32`/`WriteInt64`, and the map, array, bin and str headers its
/// formatters write).
enum SourceMessagePackWriter {
    enum Container { case map, array, binary, string }

    static func integer(_ value: Int64, into out: inout [UInt8]) {
        func bigEndian(_ bits: UInt64, _ count: Int) {
            for index in stride(from: count - 1, through: 0, by: -1) { out.append(UInt8(truncatingIfNeeded: bits >> UInt64(8 * index))) }
        }
        let bits = UInt64(bitPattern: value)
        if value >= 0 {
            if value <= 0x7f { out.append(UInt8(value)) }
            else if value <= 0xff { out.append(0xcc); bigEndian(bits, 1) }
            else if value <= 0xffff { out.append(0xcd); bigEndian(bits, 2) }
            else if value <= 0xffff_ffff { out.append(0xce); bigEndian(bits, 4) }
            else { out.append(0xcf); bigEndian(bits, 8) }
        } else {
            if value >= -32 { out.append(UInt8(truncatingIfNeeded: value)) }
            else if value >= -128 { out.append(0xd0); bigEndian(bits, 1) }
            else if value >= -32_768 { out.append(0xd1); bigEndian(bits, 2) }
            else if value >= -2_147_483_648 { out.append(0xd2); bigEndian(bits, 4) }
            else { out.append(0xd3); bigEndian(bits, 8) }
        }
    }

    static func header(_ container: Container, count: Int, into out: inout [UInt8]) {
        let value = UInt64(count)
        func bigEndian(_ size: Int) {
            for index in stride(from: size - 1, through: 0, by: -1) { out.append(UInt8(truncatingIfNeeded: value >> UInt64(8 * index))) }
        }
        switch container {
        case .map:
            if count <= 15 { out.append(0x80 | UInt8(count)) }
            else if count <= 0xffff { out.append(0xde); bigEndian(2) } else { out.append(0xdf); bigEndian(4) }
        case .array:
            if count <= 15 { out.append(0x90 | UInt8(count)) }
            else if count <= 0xffff { out.append(0xdc); bigEndian(2) } else { out.append(0xdd); bigEndian(4) }
        case .binary:
            if count <= 0xff { out.append(0xc4); bigEndian(1) }
            else if count <= 0xffff { out.append(0xc5); bigEndian(2) } else { out.append(0xc6); bigEndian(4) }
        case .string:
            if count <= 31 { out.append(0xa0 | UInt8(count)) }
            else if count <= 0xff { out.append(0xd9); bigEndian(1) }
            else if count <= 0xffff { out.append(0xda); bigEndian(2) } else { out.append(0xdb); bigEndian(4) }
        }
    }
}
