import Foundation
import simd
import CoreMath

/// Explicit binding between original Studio item IDs and locally converted assets.
public struct KoikatsuAssetCatalog: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var group: Int32
        public var category: Int32
        public var no: Int32
        public var name: String
        public var file: String
    }
    public var version: Int
    public var items: [Item]
}

public enum KoikatsuLayoutError: Error, CustomStringConvertible {
    case catalogVersion(Int)
    case duplicateItem(String)
    case missingItem(String)
    case unsupportedKind(KoikatsuObjectKind)
    case invalidAssetPath

    public var description: String {
        switch self {
        case .catalogVersion(let version): return "Converted asset catalog version \(version) is unsupported."
        case .duplicateItem(let key): return "Converted asset catalog has duplicate item \(key)."
        case .missingItem(let key): return "No converted asset is mapped for CharaStudio item \(key)."
        case .unsupportedKind(let kind): return "Object layout import supports props and folders; source kind \(kind.rawValue) is not yet supported."
        case .invalidAssetPath: return "Converted asset entries must reference local .gltf or .glb files."
        }
    }
}

/// Imports only the prop/folder hierarchy, visibility and transforms. Source
/// material overrides, animation, physics, cameras and scene settings are not applied.
/// Unsupported or unmapped records fail before the caller changes its document.
public enum KoikatsuLayoutImporter {
    public static func convert(_ scene: KoikatsuSceneSnapshot, catalog: KoikatsuAssetCatalog,
                               catalogDirectory: URL) throws -> StudioDocument {
        guard catalog.version == 1 else { throw KoikatsuLayoutError.catalogVersion(catalog.version) }
        func key(_ group: Int32, _ category: Int32, _ no: Int32) -> String { "\(group)/\(category)/\(no)" }
        var entries: [String: KoikatsuAssetCatalog.Item] = [:]
        for item in catalog.items {
            let id = key(item.group, item.category, item.no)
            guard entries.updateValue(item, forKey: id) == nil else { throw KoikatsuLayoutError.duplicateItem(id) }
        }
        var document = StudioDocument()
        document.name = "CharaStudio object layout"
        func append(_ source: KoikatsuObjectRecord, parent: UUID?) throws {
            var object: StudioObject
            switch source.kind {
            case .folder:
                object = StudioObject(name: source.name ?? "Folder", kind: .folder)
            case .item:
                guard let item = source.item else { throw KoikatsuLayoutError.unsupportedKind(source.kind) }
                let id = key(item.group, item.category, item.no)
                guard let entry = entries[id] else { throw KoikatsuLayoutError.missingItem(id) }
                guard !entry.file.isEmpty, !entry.file.contains("://") else { throw KoikatsuLayoutError.invalidAssetPath }
                let url = entry.file.hasPrefix("/") ? URL(fileURLWithPath: entry.file)
                    : catalogDirectory.appendingPathComponent(entry.file)
                guard ["glb", "gltf"].contains(url.pathExtension.lowercased()) else { throw KoikatsuLayoutError.invalidAssetPath }
                object = StudioObject(name: entry.name, kind: .item)
                object.assetFile = url.standardizedFileURL.path
            default:
                throw KoikatsuLayoutError.unsupportedKind(source.kind)
            }
            object.sourceObjectKey = source.sourceKey
            object.parent = parent
            object.visible = source.visible
            object.transform.position = UnityCoordinates.position(source.transform.position)
            object.transform.scale = source.transform.scale
            let rotation = UnityCoordinates.eulerDegrees(source.transform.rotationDegrees)
            object.transform.rotation = rotation.eulerXYZ.radiansToDegrees
            object.transform.rotationOverride = rotation.vector
            document.objects.append(object)
            for child in source.children { try append(child, parent: object.id) }
        }
        for root in scene.roots { try append(root, parent: nil) }
        try document.validateHierarchy()
        return document
    }
}
