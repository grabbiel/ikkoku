import Foundation
import Assets
import Character

// A-T02: the file and catalog references of a native Studio document, the binding a
// save records for them and the relocation a load applies. The resolver itself is
// `ResourceRelocation` (Assets); this file only maps document fields onto it.
// Contract: docs/reference/native-assets.md ("Library location and relocation").

/// A path- or catalog-valued field of a native Studio document.
public enum StudioResourceField: String, Sendable, CaseIterable {
    case sourceSceneFile
    case sourceVoiceCatalogFile
    case assetFile
    case itemID
    case characterSceneFile = "sourceCharacter.sceneFile"
    case rigFile = "sourceCharacter.rigFile"
    case boneCatalogFile = "sourceCharacter.boneCatalogFile"
    case makerLibraryFile = "sourceCharacter.makerLibraryFile"
    case attachmentCatalogFile = "sourceCharacter.attachmentCatalogFile"
    case animationCatalogFile = "sourceCharacter.animationCatalogFile"
    case dynamicsFile = "sourceCharacter.dynamicsFile"
    case handPatternsFile = "sourceCharacter.handPatternsFile"
    case lookSettingsFile = "sourceCharacter.lookSettingsFile"
}

/// One reference and where it lives in the document.
public struct StudioResourceReference: Sendable, Equatable {
    /// The object holding the field; nil for a document-level field.
    public let object: UUID?
    public let field: StudioResourceField
    public let reference: ResourceReference
}

/// A loaded document after its references were resolved.
public struct StudioResourceResolution: Sendable {
    /// The input document with each relocated path replaced by its verified file.
    /// Resolved and unresolved paths stay exactly as saved, so an unresolved
    /// reference keeps its saved identity and no other file is substituted.
    public let document: StudioDocument
    public let report: ResourceRelocationReport
    /// The references, in the same order as `report.resolutions`.
    public let references: [StudioResourceReference]
    /// Objects with at least one unresolved reference. The caller must not load
    /// their files: what is at the saved path is missing or not the saved content.
    public let blockedObjects: Set<UUID>
    /// Document-level fields that are unresolved.
    public let blockedFields: Set<StudioResourceField>

    /// The resolution of `field` (on `object`, when given).
    public func resolution(_ field: StudioResourceField, object: UUID? = nil) -> ResourceResolution? {
        guard let index = references.firstIndex(where: { $0.field == field && (object == nil || $0.object == object) }) else { return nil }
        return report.resolutions[index]
    }

    /// One summary line and one line per unresolved reference; empty when every
    /// reference resolved in place.
    public var diagnostics: [String] {
        guard !report.relocated.isEmpty || !report.unresolved.isEmpty else { return [] }
        return ["Resource check: \(report.summary)."] + report.unresolved.map { "Unresolved \($0)" }
    }
}

extension StudioDocument {
    /// Every file and catalog reference the document makes, in document order:
    /// the source scene and voice catalog, then per object its `assetFile` (or,
    /// for an item without one, its catalog `itemID`) and every path of its source
    /// character reference. Catalog items are listed only when `catalog` is given;
    /// an ID the catalog lacks becomes a `libraryFile` target with no path.
    /// Not covered: native character card catalog IDs, plugin profile and plugin
    /// library paths (P-T02) and sibling files a loader derives from a recorded
    /// path (for example `ik-bindings.json` beside the bone catalog).
    public func resourceReferences(catalog: Catalog?) -> [StudioResourceReference] {
        var references: [StudioResourceReference] = []
        func add(_ object: StudioObject?, _ field: StudioResourceField, _ target: ResourceReference.Target?,
                 expected: String? = nil, detail: String? = nil) {
            guard let target else { return }
            let owner = object.map { "object '\($0.name)' [\($0.id.uuidString)]" } ?? "scene"
            let identity = "\(owner) \(field.rawValue)" + (detail.map { " \($0)" } ?? "")
            references.append(StudioResourceReference(object: object?.id, field: field,
                reference: ResourceReference(identity: identity, target: target, expectedSHA256: expected)))
        }
        func file(_ path: String?) -> ResourceReference.Target? { path.map { .file($0) } }
        add(nil, .sourceSceneFile, file(sourceSceneFile), expected: sourceSceneSHA256)
        add(nil, .sourceVoiceCatalogFile, file(sourceVoiceCatalogFile))
        for object in objects {
            if let assetFile = object.assetFile {
                add(object, .assetFile, .file(assetFile))
            } else if object.kind == .item, let id = object.itemID, let catalog {
                // The renderer draws a catalog item from the asset library by its ID.
                add(object, .itemID, .libraryFile(kind: .assets, relativePath: catalog.item(id)?.file), detail: id)
            }
            guard let character = object.sourceCharacter else { continue }
            add(object, .characterSceneFile, .file(character.sceneFile), expected: character.sceneSHA256)
            add(object, .rigFile, .file(character.rigFile))
            add(object, .boneCatalogFile, .file(character.boneCatalogFile))
            add(object, .makerLibraryFile, file(character.makerLibraryFile))
            add(object, .attachmentCatalogFile, file(character.attachmentCatalogFile))
            add(object, .animationCatalogFile, file(character.animationCatalogFile))
            add(object, .dynamicsFile, file(character.dynamicsFile))
            add(object, .handPatternsFile, file(character.handPatternsFile))
            add(object, .lookSettingsFile, file(character.lookSettingsFile))
        }
        return references
    }

    /// This document with `resourceBinding` recorded against `libraries` (the
    /// libraries in effect at save time). The binding it was loaded with is the
    /// previous one: a file that is missing or changed now keeps its saved
    /// identity (`ResourceBinding.record`). A document without file references
    /// gets no binding.
    public func recordingResourceBinding(libraries: [ResourceLibraryRecord]) -> StudioDocument {
        var document = self
        document.resourceBinding = ResourceBinding.record(resourceReferences(catalog: nil).map(\.reference),
                                                          libraries: libraries, previous: resourceBinding)
        return document
    }

    /// Resolves every reference against the binding and the libraries in effect
    /// (`ResourceRelocation.resolve`) and replaces each relocated path. The binding
    /// itself is kept as loaded, so the next save can still carry the saved
    /// identity of a reference that stays unresolved.
    public func resolvingResources(current: ResourceLibraryLocation, catalog: Catalog?) -> StudioResourceResolution {
        let references = resourceReferences(catalog: catalog)
        let report = ResourceRelocation.resolve(references.map(\.reference), binding: resourceBinding, current: current)
        var document = self
        var blockedObjects = Set<UUID>(), blockedFields = Set<StudioResourceField>()
        var characterPaths: [UUID: [StudioResourceField: String]] = [:]
        for (reference, resolution) in zip(references, report.resolutions) {
            switch resolution.status {
            case .resolved:
                continue
            case .unresolved:
                if let object = reference.object { blockedObjects.insert(object) } else { blockedFields.insert(reference.field) }
            case .relocated:
                guard let path = resolution.path else { continue }
                switch (reference.object, reference.field) {
                case (nil, .sourceSceneFile): document.sourceSceneFile = path
                case (nil, .sourceVoiceCatalogFile): document.sourceVoiceCatalogFile = path
                case (let object?, .assetFile):
                    if let index = document.index(of: object) { document.objects[index].assetFile = path }
                case (let object?, let field): characterPaths[object, default: [:]][field] = path
                default: continue
                }
            }
        }
        for (object, paths) in characterPaths {
            guard let index = document.index(of: object), let character = document.objects[index].sourceCharacter else { continue }
            document.objects[index].sourceCharacter = character.relocating(paths)
        }
        return StudioResourceResolution(document: document, report: report, references: references,
                                        blockedObjects: blockedObjects, blockedFields: blockedFields)
    }
}

extension SourceStudioCharacterReference {
    /// The same reference with relocated paths; every other field is unchanged.
    /// A field added to the reference must be carried here too.
    func relocating(_ paths: [StudioResourceField: String]) -> SourceStudioCharacterReference {
        SourceStudioCharacterReference(sceneFile: paths[.characterSceneFile] ?? sceneFile, sceneSHA256: sceneSHA256,
            rigFile: paths[.rigFile] ?? rigFile, boneCatalogFile: paths[.boneCatalogFile] ?? boneCatalogFile, objectKey: objectKey,
            makerLibraryFile: paths[.makerLibraryFile] ?? makerLibraryFile,
            attachmentCatalogFile: paths[.attachmentCatalogFile] ?? attachmentCatalogFile,
            animationCatalogFile: paths[.animationCatalogFile] ?? animationCatalogFile,
            dynamicsFile: paths[.dynamicsFile] ?? dynamicsFile, handPatternsFile: paths[.handPatternsFile] ?? handPatternsFile,
            lookSettingsFile: paths[.lookSettingsFile] ?? lookSettingsFile)
    }
}
