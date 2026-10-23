import Foundation
import Testing
import CryptoKit
import Metal
import simd
import Assets
import CoreMath
import Character
import Scene
import Renderer

private enum MakerLibraryFixture {
    typealias F = OriginalCardFixture
    static func directory() throws -> URL { try AppearanceTestFixture.directory() }
    static func library(_ entries: [[String: Any]], directory: URL, assemblies: [[String: Any]] = []) throws -> SourceMakerLibrary {
        let url = directory.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": entries, "assemblies": assemblies]).write(to: url)
        return try .load(url: url)
    }
    static func empty(_ category: Int, _ id: Int, guid: String? = nil, name: String = "p_dummy") -> [String: Any] {
        var entry: [String: Any] = ["category": category, "id": id, "name": name, "empty": true]
        if let guid { entry["modGUID"] = guid }
        return entry
    }
    static func references(_ records: [(String?, String, Int, Int)]) throws -> SourceCardModReferences {
        let values = records.map { guid, property, source, local in F.Value.binary(F.pack(F.map([
            ("ModID", guid.map(F.Value.string) ?? .null), ("Property", .string(property)),
            ("Slot", .integer(Int64(source))), ("LocalSlot", .integer(Int64(local))),
            ("CategoryNo", .integer(999))]))) }
        let plugin = F.plugin(0, data: F.map([("info", .array(values))]))
        let card = try SourceCharacterCard.decode(F.card(blocks: F.blocks() + [F.extended(F.map([
            ("com.bepis.sideloader.universalautoresolver", plugin)]))]))
        return try #require(try card.modReferences())
    }
}

@Test func sourceMakerLibraryResolvesFirstOrdinalModSourceSlotWithoutChangingIdentity() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try MakerLibraryFixture.library([
        MakerLibraryFixture.empty(101, 17, guid: "Example.Mod", name: "first"),
        MakerLibraryFixture.empty(101, 17, guid: "example.mod", name: "case-distinct"),
        MakerLibraryFixture.empty(101, 17, guid: "caf\u{e9}", name: "composed"),
        MakerLibraryFixture.empty(101, 17, guid: "cafe\u{301}", name: "decomposed"),
        MakerLibraryFixture.empty(101, 900001, guid: "Example.Mod", name: "wrong-local-slot"),
        MakerLibraryFixture.empty(101, 17, name: "original")], directory: directory)
    let property = "ChaFileHair.HairBack"
    let refs = try MakerLibraryFixture.references([("Example.Mod", property, 17, 900001), ("example.mod", property, 17, 900002)])
    let selected = library.selection(category: 101, savedID: 99999, property: property, references: refs)
    #expect(selected.entry?.name == "first" && selected.savedID == 99999 && selected.sourceID == 17)
    #expect(selected.modGUID == "Example.Mod" && selected.status == "empty")
    #expect(refs.records.map(\.localSlot) == [900001, 900002])
    #expect(library.selection(category: 102, savedID: 17, property: property, references: refs).entry == nil)
    for (guid, name) in [("example.mod", "case-distinct"), ("caf\u{e9}", "composed"), ("cafe\u{301}", "decomposed")] {
        let ref = try MakerLibraryFixture.references([(guid, property, 17, 1)])
        #expect(library.selection(category: 101, savedID: 900001, property: property, references: ref).entry?.name == name)
    }
    let ordinal = try MakerLibraryFixture.references([("Example.Mod", "caf\u{e9}", 17, 1)])
    #expect(library.selection(category: 101, savedID: 17, property: "cafe\u{301}", references: ordinal).entry?.name == "original")
    #expect(library.selection(category: 101, savedID: 17, property: property, references: nil).entry?.name == "original")
    for guid: String? in [nil, ""] {
        let ref = try MakerLibraryFixture.references([(guid, property, 17, 1)])
        #expect(library.selection(category: 101, savedID: 17, property: property, references: ref).status == "compatibilityRequired")
    }
}

@Test func sourceMakerLibraryRejectsDuplicateIdentityTraversalAndChangedAssemblyBytes() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let entry = MakerLibraryFixture.empty(103, 0)
    #expect(throws: (any Error).self) { try MakerLibraryFixture.library([entry, entry], directory: directory) }
    let data = Data("{}".utf8), hash = OriginalCardFixture.hash(data)
    for path in ["../escape.json", "/absolute.json", ""] {
        var invalid = entry; invalid["rig"] = ["file": path, "sha256": hash]
        #expect(throws: (any Error).self) { try MakerLibraryFixture.library([invalid], directory: directory) }
    }
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try data.write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.json"), withDestinationURL: outside)
    var symlink = entry; symlink["rig"] = ["file": "link.json", "sha256": hash]
    #expect(throws: (any Error).self) { try MakerLibraryFixture.library([symlink], directory: directory) }
    try data.write(to: directory.appendingPathComponent("assembly.json"))
    let assembly: [String: Any] = ["sex": 1, "headID": 0, "exType": 0,
        "manifest": ["file": "assembly.json", "sha256": String(repeating: "0", count: 64)]]
    let library = try MakerLibraryFixture.library([], directory: directory, assemblies: [assembly])
    let identity = try SourceCharacterCard.decode(OriginalCardFixture.card()).customization()
    #expect(throws: (any Error).self) { try library.assemblyURL(for: identity) }
}

@Test func sourceMakerLibraryDoesNotAliasResolverBackedHeadToVanillaIdentity() throws {
    try SourceMakerLibrary.validateAssemblyIdentity(card: AppearanceTestFixture.card())
    for guid in ["original.head.mod", ""] {
        let card = try AppearanceTestFixture.card(modProperty: "ChaFileFace.headId", guid: guid)
        #expect(try card.customization().headID == 0)
        #expect(throws: RigError.self) { try SourceMakerLibrary.validateAssemblyIdentity(card: card) }
        #expect(try card.editedData(.init()) == card.preservedData)
    }
    // Property matching follows source ordinal string comparison.
    try SourceMakerLibrary.validateAssemblyIdentity(card: AppearanceTestFixture.card(modProperty: "ChaFileFace.HeadId"))
}

@Test func sourceMakerLibraryValidatesUnusedReferencePathsAndSelectedAssetHashes() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let card = try AppearanceTestFixture.card()
    let manifest = directory.appendingPathComponent("source-avatar.json")
    func writeManifest(hair: String) throws {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": "koikatsu-female-avatar", "name": "fixture",
            "sex": 1, "headID": 0, "bodySkeleton": "body-master.json", "headSkeleton": "head-master.json",
            "body": ["file": "body.json", "meshNames": ["body"]], "head": ["file": "head.json"],
            "hair": [["file": hair, "slot": 0]], "clothes": []] as [String: Any]).write(to: manifest)
    }
    let library = try MakerLibraryFixture.library([MakerLibraryFixture.empty(101, 2)], directory: directory)
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data().write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.json"), withDestinationURL: outside)
    for path in ["../escape.json", "/absolute.json", "", "escape.json"] {
        try writeManifest(hair: path)
        do {
            _ = try library.prepare(card: card, coordinate: 0, baseURL: manifest)
            Issue.record("An unused reference path escaped validation")
        } catch RigError.invalid(let reason) { #expect(reason == "Base component escapes its folder.") }
    }
    // The missing reference is unused, but a selected converted rig must still
    // pass its original byte hash before any geometry is accepted.
    try writeManifest(hair: "unused-missing.json")
    try Data("{}".utf8).write(to: directory.appendingPathComponent("selected.json"))
    let changed = try MakerLibraryFixture.library([["category": 101, "id": 2, "name": "selected", "meshNames": ["part"],
        "rig": ["file": "selected.json", "sha256": String(repeating: "0", count: 64)]]], directory: directory)
    do {
        _ = try changed.prepare(card: card, coordinate: 0, baseURL: manifest)
        Issue.record("A selected asset with changed bytes was accepted")
    } catch RigError.invalid(let reason) { #expect(reason == "Changed or oversized converted Maker asset: selected.json.") }
}

private struct MakerSelectionCases: Decodable {
    struct Case: Decodable {
        let file: String, sha256: String, sex: Int, headID: Int, boneType: Int
        let moved: Bool, materials: Bool, selectionCount: Int, opaqueTokenCount: Int
    }
    let library: String, femaleBase: String, maleBase: String, fixtures: [Case]
    static func load() throws -> (Self, URL) {
        let url = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_SELECTION_FIXTURES"))
        return (try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)), url.deletingLastPathComponent())
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceMakerLibraryRejectsInvalidOrDuplicateBaseComponentSlots() throws {
    let (fixtures, fixtureDirectory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let sourceURL = URL(fileURLWithPath: fixtures.femaleBase), directory = try MakerLibraryFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any])
    var paths = [try #require(original["bodySkeleton"] as? String), try #require(original["headSkeleton"] as? String)]
    for key in ["body", "head"] { paths.append(try #require((original[key] as? [String: Any])?["file"] as? String)) }
    for key in ["hair", "clothes"] {
        paths += try #require(original[key] as? [[String: Any]]).map { try #require($0["file"] as? String) }
    }
    // Separate directory entries share immutable file bytes; no source files change.
    for path in Set(paths) {
        let target = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: sourceURL.deletingLastPathComponent().appendingPathComponent(path), to: target)
    }
    let card = try SourceCharacterCard.decode(Data(contentsOf: fixtureDirectory.appendingPathComponent("female-head0-bone0.png")))
    for (kind, slots) in [("hair", [4,1]), ("hair", [0,0]), ("clothes", [-1,1,8]), ("clothes", [0,0,8])] {
        var document = original, components = try #require(original[kind] as? [[String: Any]])
        for (index, slot) in slots.enumerated() { components[index]["slot"] = slot }
        document[kind] = components
        let url = directory.appendingPathComponent("source-avatar.json")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        do {
            _ = try library.prepare(card: card, coordinate: 0, baseURL: url)
            Issue.record("Invalid base component slots were accepted")
        } catch RigError.invalid(let reason) { #expect(reason.contains("Invalid or duplicate base")) }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceMakerLibraryLoadsOnlyRequiredReferenceGeometry() throws {
    let (fixtures, fixtureDirectory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let base = URL(fileURLWithPath: fixtures.femaleBase), directory = try MakerLibraryFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let card = try SourceCharacterCard.load(url: fixtureDirectory.appendingPathComponent("female-head0-bone0.png"))
    let original = try library.prepare(card: card, coordinate: 0, baseURL: base)
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: base)) as? [String: Any])
    var paths = [try #require(manifest["bodySkeleton"] as? String), try #require(manifest["headSkeleton"] as? String)]
    for key in ["body", "head"] { paths.append(try #require((manifest[key] as? [String: Any])?["file"] as? String)) }
    for path in Set(paths) {
        let target = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: base.deletingLastPathComponent().appendingPathComponent(path), to: target)
    }
    for kind in ["hair", "clothes"] {
        var components = try #require(manifest[kind] as? [[String: Any]])
        for index in components.indices {
            let path = "unused-\(kind)-\(index).json"
            components[index]["file"] = path
            try Data("invalid unused geometry".utf8).write(to: directory.appendingPathComponent(path))
        }
        manifest[kind] = components
    }
    let changedBase = directory.appendingPathComponent("source-avatar.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: changedBase)
    let prepared = try library.prepare(card: card, coordinate: 0, baseURL: changedBase)
    #expect(prepared.clothingSlots == original.clothingSlots && prepared.referenceClothingSlots == original.referenceClothingSlots)
    #expect(prepared.selections.map(\.property) == original.selections.map(\.property))
    #expect(prepared.selections.map(\.sourceID) == original.selections.map(\.sourceID))
    #expect(prepared.selections.map(\.modGUID) == original.selections.map(\.modGUID))
    #expect(prepared.diagnostics == original.diagnostics)
    let a = original.source, b = prepared.source
    #expect(a.sourcePrefab == b.sourcePrefab && a.morphChannelCount == b.morphChannelCount)
    #expect(a.rig.nodes.count == b.rig.nodes.count && a.rig.skins.count == b.rig.skins.count && a.parts.count == b.parts.count)
    #expect(a.rig.order == b.rig.order && a.rig.activeNodes == b.rig.activeNodes)
    for (left, right) in zip(a.rig.nodes, b.rig.nodes) {
        #expect(left.name == right.name && left.sourceID == right.sourceID && left.parent == right.parent)
        #expect(left.localMatrix == right.localMatrix && left.active == right.active)
    }
    for (left, right) in zip(a.rig.skins, b.rig.skins) {
        #expect(left.name == right.name && left.meshNode == right.meshNode && left.rootJoint == right.rootJoint)
        #expect(left.joints == right.joints && left.inverseBindMatrices == right.inverseBindMatrices)
    }
    for (left, right) in zip(a.parts, b.parts) {
        #expect(left.node == right.node && left.skin == right.skin && left.rendererEnabled == right.rendererEnabled && left.hasCloth == right.hasCloth)
        let x = left.mesh, y = right.mesh
        #expect(x.name == y.name && x.positions == y.positions && x.normals == y.normals && x.tangents == y.tangents)
        #expect(x.uvs == y.uvs && x.uvs1 == y.uvs1 && x.uvs2 == y.uvs2 && x.colors == y.colors)
        #expect(x.joints == y.joints && x.weights == y.weights && x.indices == y.indices)
        #expect(x.materialIndex == y.materialIndex && x.regions == y.regions && x.extras == y.extras)
        #expect(x.morphTargets.count == y.morphTargets.count)
        for (m, n) in zip(x.morphTargets, y.morphTargets) {
            #expect(m.name == n.name && m.positionDeltas == n.positionDeltas && m.normalDeltas == n.normalDeltas)
        }
    }
    // An unresolved selection really needs its reference, so its malformed
    // geometry must fail rather than silently dropping that part.
    for slot: SourceMakerSelectionSlot in [.hair(0), .clothes(coordinate: 0, slot: 0)] {
        let fallback = try SourceCharacterCard.decode(card.selectingVanillaAsset(Int(Int32.max), at: slot))
        #expect(throws: DecodingError.self) { try library.prepare(card: fallback, coordinate: 0, baseURL: changedBase) }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]) && MTLCreateSystemDefaultDevice() != nil, "Requires IKKOKU_MAKER_SELECTION_FIXTURES and a Metal device"))
func sourceMakerLibraryPreparesSelectedClothedGeometryHeadsBoneTypesAndAccessoryTransforms() throws {
    let (fixtures, directory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for sample in fixtures.fixtures {
        let bytes = try Data(contentsOf: directory.appendingPathComponent(sample.file))
        #expect(OriginalCardFixture.hash(bytes) == sample.sha256)
        let card = try SourceCharacterCard.decode(bytes), custom = try card.customization()
        #expect(custom.sex == sample.sex && custom.headID == sample.headID && custom.boneType == sample.boneType)
        let base = try library.assemblyURL(for: custom) ?? URL(fileURLWithPath: sample.sex == 1 ? fixtures.femaleBase : fixtures.maleBase)
        let prepared = try library.prepare(card: card, coordinate: 0, baseURL: base)
        #expect(prepared.selections.count == sample.selectionCount)
        #expect(prepared.selections.allSatisfy { $0.status == "converted" || $0.status == "empty" })
        #expect(prepared.selections.filter { $0.status == "converted" }.count == 6)
        #expect(prepared.selections.filter { $0.status == "empty" }.count == 7)
        let source = prepared.source, names = source.parts.map(\.mesh.name)
        #expect(names.contains { $0.hasPrefix("hair-0/") } && names.contains { $0.hasPrefix("hair-1/") })
        #expect(!names.contains { $0.hasPrefix("hair-2/") || $0.hasPrefix("hair-3/") })
        #expect(names.filter { $0.hasPrefix("accessory-0/") }.count == 2)
        #expect(names.contains { $0.hasPrefix("clothes-0/") } && names.contains { $0.hasPrefix("clothes-1/") })
        let move = try #require(source.rig.nodes.first { $0.sourceID.hasPrefix("accessory-0/") && $0.name == "N_move" })
        #expect(!source.rig.nodes.contains { $0.sourceID.hasPrefix("accessory-0/") && $0.name == "N_move2" })
        let accessoryRoot = try #require(source.rig.nodes.first { $0.sourceID.hasPrefix("accessory-0/") && $0.parent.map { !source.rig.nodes[$0].sourceID.hasPrefix("accessory-0/") } == true })
        #expect(source.rig.nodes[try #require(accessoryRoot.parent)].name == "a_n_megane")
        if sample.moved {
            #expect(simd_distance(move.translation, Float3(0.015, -0.0225, -0.0375)) < 1e-7)
            #expect(simd_distance(move.scale, Float3(1.1, 0.9, 1.2)) < 1e-7)
            // Independent rotation matrices: source order is Y * X * Z; reflect Z.
            let x: Float = 12 * .pi / 180, y: Float = 23 * .pi / 180, z: Float = 34 * .pi / 180
            let rx = float3x3(columns: (.init(1,0,0), .init(0,cos(x),sin(x)), .init(0,-sin(x),cos(x))))
            let ry = float3x3(columns: (.init(cos(y),0,-sin(y)), .init(0,1,0), .init(sin(y),0,cos(y))))
            let rz = float3x3(columns: (.init(cos(z),sin(z),0), .init(-sin(z),cos(z),0), .init(0,0,1)))
            let reflect = float3x3(diagonal: Float3(1,1,-1)), expected = reflect * ry * rx * rz * reflect
            let actual = float3x3(move.rotation)
            for column in 0..<3 { #expect(simd_distance(actual[column], expected[column]) < 1e-6) }
        } else { #expect(move.translation == .zero && move.scale == .one) }
        let folder = base.deletingLastPathComponent()
        let contract = try SourceShapeContract.decode(Data(contentsOf: folder.appendingPathComponent("character-shape-contract.json")))
        let correction = sample.boneType == 0 ? nil : try Data(contentsOf: folder.appendingPathComponent("shapecorrect.bytes"))
        let options = try SourceMakerAssemblyOptions.body(sex: custom.sex, boneType: custom.boneType, correctionData: correction)
        let appearance = try SourceCardAppearance(card: card)
        let baseAppearance = try SourcePreviewAppearance.load(url: base.deletingPathExtension().appendingPathExtension("appearance.json"), resources: resources)
        let applied = try #require(try prepared.appearance(base: baseAppearance, card: appearance, resources: resources, modLibrary: nil))
        #expect(!applied.appliedFields.isEmpty)
        let preview = try SourceRigPreview(source: source, contract: contract, resources: resources, appearance: applied.appearance, bodyOptions: options)
        let pose = try preview.pose(bodyValues: custom.bodyValues, faceValues: custom.faceValues)
        let frame = try preview.frame(camera: OrbitCamera(), poseOverride: pose)
        #expect(frame.items.count >= source.parts.count && frame.sceneBounds.radius.isFinite)
        #expect(frame.sceneBounds.radius > 0.5 && frame.sceneBounds.radius < 3)
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceMakerSelectedCardEditsKeepOpaqueTokensResolverAndAssetIdentity() throws {
    let (fixtures, directory) = try MakerSelectionCases.load()
    for sample in fixtures.fixtures {
        let original = try SourceCharacterCard.decode(Data(contentsOf: directory.appendingPathComponent(sample.file)))
        let body = try original.recordFields(.body), unknown = try #require(body["fixtureOpaque99"])
        #expect(try unknown.stringKeyedMap().count == sample.opaqueTokenCount)
        let beforeAppearance = try SourceCardAppearance(card: original)
        let edit = SourceCharacterCard.ColorEdit(record: .body, path: [.key("skinMainColor")], rgba: [0.8,0.7,0.6,1])
        let result = try SourceCharacterCard.decode(original.editedData(.init(bodyValues: Array(repeating: 0.45, count: 44), colors: [edit])))
        #expect(try result.recordFields(.body)["fixtureOpaque99"] == unknown)
        #expect(try result.recordData(.hair) == original.recordData(.hair))
        #expect(try result.recordData(.face) == original.recordData(.face))
        #expect(result.block(named: "Coordinate")?.data == original.block(named: "Coordinate")?.data)
        for name in ["KKEx", "FixtureUnknown", "Parameter", "Status"] {
            #expect(result.block(named: name)?.data == original.block(named: name)?.data)
        }
        #expect(result.trailingData == original.trailingData)
        let appearance = try SourceCardAppearance(card: result)
        #expect(appearance.modProperties == beforeAppearance.modProperties)
        #expect(appearance.color("body.skinMainColor") == Float4(0.8,0.7,0.6,1))
        #expect(try result.modReferences()?.records.first?.localSlot == 900001)
        #expect(try result.customization().headID == sample.headID)
        #expect(try result.customization().boneType == sample.boneType)
    }
}
