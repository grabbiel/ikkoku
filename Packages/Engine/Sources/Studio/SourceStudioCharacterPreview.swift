import Foundation
import CryptoKit
import simd
import CoreMath
import Scene
import Character
import Renderer

/// Native scene cards retain a verified reference to the original scene. This
/// preview applies supported settings to an explicit local clothed avatar; it
/// does not claim the referenced character's outfit/material identity matches.
public struct SourceStudioCharacterReference: Codable, Sendable, Equatable {
    public let sceneFile: String, sceneSHA256: String, rigFile: String, boneCatalogFile: String
    public let objectKey: Int32
    public init(sceneFile: String, sceneSHA256: String, rigFile: String, boneCatalogFile: String, objectKey: Int32) {
        self.sceneFile = sceneFile; self.sceneSHA256 = sceneSHA256; self.rigFile = rigFile
        self.boneCatalogFile = boneCatalogFile; self.objectKey = objectKey
    }
}

public final class SourceStudioCharacterPreview {
    public let reference: SourceStudioCharacterReference
    public let preview: SourceRigPreview
    public let pose: RigPose
    public let diagnostics: [String]
    public let record: KoikatsuCharacterRecord

    public init(reference: SourceStudioCharacterReference, resources: ResourceStore) throws {
        self.reference = reference
        let data = try Self.read(URL(fileURLWithPath: reference.sceneFile), maximum: 256 * 1024 * 1024)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference.sceneSHA256 else {
            throw RigError.invalid("The referenced source scene changed; import it again to update this preview.")
        }
        let scene = try KoikatsuSceneReader.decodeDocument(data)
        var stack = scene.snapshot.roots, match: KoikatsuCharacterRecord?
        while let object = stack.popLast() {
            if object.sourceKey == reference.objectKey { match = object.character; break }
            stack += object.children
            if let character = object.character { stack += character.accessoryChildren.values.flatMap { $0 } }
        }
        guard let record = match, record.sex == 1 else { throw RigError.invalid("Source preview requires a supported female character record.") }
        self.record = record
        let rigURL = URL(fileURLWithPath: reference.rigFile), directory = rigURL.deletingLastPathComponent()
        let source = try SourceRig.loadModel(url: rigURL)
        let contract = try SourceShapeContract.decode(Self.read(directory.appendingPathComponent("character-shape-contract.json"), maximum: 32 * 1024 * 1024))
        let appearance = try SourcePreviewAppearance.load(url: rigURL.deletingPathExtension().appendingPathExtension("appearance.json"), resources: resources)
        let expression = try SourceExpressionContract.decode(Self.read(directory.appendingPathComponent("source-expression-contract.json"), maximum: 32 * 1024 * 1024))
        preview = try SourceRigPreview(source: source, contract: contract, resources: resources, appearance: appearance, expressionContract: expression)
        let settings = try record.card().previewSettings(contract: contract)
        let baseline = try preview.pose(bodyValues: settings.bodyValues, faceValues: settings.faceValues, boneModifiers: settings.boneModifiers)
        struct Catalog: Decodable { let bones: [SourceStudioPose.Bone] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Self.read(URL(fileURLWithPath: reference.boneCatalogFile), maximum: 16 * 1024 * 1024))
        let roots = source.rig.nodes.indices.filter { source.rig.nodes[$0].parent == nil }
        guard roots.count == 1 else { throw RigError.invalid("Source scene preview requires a single assembled root.") }
        let restored = try record.makePose(rig: source.rig, catalog: catalog.bones, baseline: baseline,
            characterRoot: roots[0], bodyRoot: source.rig.uniqueNode(named: "p_cf_body_bone"),
            hairRoot: source.rig.uniqueNode(named: "cf_J_FaceUp_ty"))
        pose = restored.pose
        diagnostics = ["Clothed reference avatar with supported source card settings and saved FK. Original appearance and scene animation are not restored."]
            + settings.diagnostics + restored.diagnostics
    }

    public func frame(camera: OrbitCamera, mainLight: MainLight, effects: SceneEffects,
                      world: float4x4, objectID: UInt32) throws -> RenderFrame {
        var frame = try preview.frame(camera: camera, mainLight: mainLight, effects: effects,
            expression: preview.expressionContract?.defaults, poseOverride: pose)
        for i in frame.items.indices { frame.items[i].model = world * frame.items[i].model; frame.items[i].objectID = objectID }
        frame.sceneBounds = frame.sceneBounds.transformed(by: world)
        return frame
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximum else { throw RigError.invalid("Source preview input is not a bounded regular file.") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw RigError.invalid("Source preview input grew beyond its limit.") }
        return data
    }
}
