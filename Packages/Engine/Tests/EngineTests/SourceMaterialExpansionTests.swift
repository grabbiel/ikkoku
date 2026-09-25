import Foundation
import Testing
import Metal
import CoreMath
import Assets
import Renderer
import Character

private enum MakeupFixture {
    typealias F = OriginalCardFixture
    static func card(enabled: UInt8) throws -> SourceCharacterCard {
        let color = F.Value.array([.float(0.2), .float(0.3), .float(0.4), .float(0.5)])
        let base = F.map([("version", .string("0.0.0")), ("cheekId", .integer(2)), ("cheekColor", color)])
        let outfit = F.map([("version", .string("0.0.0")), ("cheekId", .integer(3)), ("cheekColor", .array([.float(0.9), .float(0.8), .float(0.7), .float(0.6)]))])
        let face = F.pack(F.map([("version", .string("0.0.2")), ("baseMakeup", base)]))
        let body = F.pack(F.map([("version", .string("0.0.2"))]))
        let hair = F.pack(F.map([("version", .string("0.0.4"))]))
        let custom = F.lengthData(face) + F.lengthData(body) + F.lengthData(hair)
        let clothes = F.pack(F.map([("version", .string("0.0.1")), ("parts", .array([]))]))
        let accessory = F.pack(F.map([("version", .string("0.0.2")), ("parts", .array([F.map([("id", .integer(17)), ("color", .array([color]))])]))]))
        let coordinate = F.lengthData(clothes) + F.lengthData(accessory) + Data([enabled]) + F.lengthData(F.pack(outfit))
        var blocks = F.blocks(custom: custom).filter { $0.name != "Coordinate" }
        blocks.append(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array([.binary(coordinate)]))))
        return try SourceCharacterCard.decode(F.card(blocks: blocks))
    }
}

@Test func sourceActiveMakeupKeepsRecordIdentityAndAccessoryColors() throws {
    for enabled: UInt8 in [0, 1, 255] {
        let card = try MakeupFixture.card(enabled: enabled)
        var appearance = try SourceCardAppearance(card: card)
        #expect(appearance.usesCoordinateMakeup == (enabled != 0))
        #expect(appearance.value("makeup.cheekId")?.integerValue == (enabled == 0 ? 2 : 3))
        #expect(appearance.color("accessory.parts.0.color.0") == Float4(0.2,0.3,0.4,0.5))
        let originalInactive = try card.recordData(enabled == 0 ? .makeup(coordinate: 0) : .face)
        try appearance.setColor("makeup.cheekColor", rgba: Float4(0.1,0.2,0.3,0.4))
        let edit = try #require(appearance.colors.first { $0.id == "makeup.cheekColor" }).edit
        #expect(edit.record == (enabled == 0 ? .face : .makeup(coordinate: 0)))
        let result = try SourceCharacterCard.decode(card.editedData(.init(colors: [edit])))
        #expect(try SourceCardAppearance(card: result).color("makeup.cheekColor") == Float4(0.1,0.2,0.3,0.4))
        #expect(try result.recordData(enabled == 0 ? .makeup(coordinate: 0) : .face) == originalInactive)
        #expect(try result.recordData(.accessory(coordinate: 0)) == card.recordData(.accessory(coordinate: 0)))
    }
}

@Test func sourceMaterialLayerIndependentShaderOracle() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_MATERIAL_LAYER_REFERENCE"] else { return }
    struct Row: Decodable { let base, texture, color, uv, layout, layer, pattern, transformedUV: [Float]; let kind: String; let mask, red: Float }
    struct Oracle: Decodable { let schemaVersion: Int; let cases: [Row] }
    let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(oracle.schemaVersion == 1 && oracle.cases.count == 128)
    for row in oracle.cases {
        let layered = SourceColorComposition.layer(base: Float4(row.base), texture: Float4(row.texture), color: Float4(row.color), mask: row.mask)
        let pattern = SourceColorComposition.patternColor(base: Float4(row.base), pattern: Float4(row.color), red: row.red)
        let uv = SourceColorComposition.faceUV(Float2(row.uv), layout: Float4(row.layout), kind: row.kind)
        for index in 0..<4 {
            #expect(abs(layered[index] - row.layer[index]) < 2e-6)
            #expect(abs(pattern[index] - row.pattern[index]) < 2e-6)
        }
        for index in 0..<2 { #expect(abs(uv[index] - row.transformedUV[index]) < 1e-5) }
    }
}

@Test func sourceAppearanceAccessoryContextPreservesCatalogRequirements() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let entry = AppearanceTestFixture.entry(colors: ["accessory.parts.0.color.0"], requirements: ["accessory.parts.0.id": 123], resolver: ["outfit{coordinate}.accessory0.ChaFileAccessory.PartsInfo.id"])
    let bindings = try AppearanceTestFixture.bindings([entry], directory: directory)
    let changed = try bindings.contextualized(accessorySlot: 7)
    #expect(changed.entries[0].colors == ["accessory.parts.7.color.0"])
    #expect(changed.entries[0].requirements == ["accessory.parts.7.id": 123])
    #expect(changed.entries[0].resolverProperties == ["outfit{coordinate}.accessory7.ChaFileAccessory.PartsInfo.id"])
    #expect(bindings.entries[0].requirements == ["accessory.parts.0.id": 123])
    #expect(changed.restricted(to: ["part"]).entries.count == 1)
    #expect(changed.restricted(to: []).entries.isEmpty)
    #expect(throws: (any Error).self) { try bindings.contextualized(accessorySlot: 128) }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMaterialExpandedTextureIndependentOracle() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_MATERIAL_IMAGE_REFERENCE"] else { return }
    struct Recipe: Decodable { let part, file: String; let width, height: Int }
    struct Oracle: Decodable { let cardFile: String; let recipes: [Recipe] }
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent(), base = directory.deletingLastPathComponent()
    let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let appearance = try SourcePreviewAppearance.load(url: base.appendingPathComponent("source-avatar.appearance.json"), resources: resources)
    let bindings = try SourceAppearanceBindings.load(url: base.appendingPathComponent("source-avatar.card-appearance.json"))
    let card = try SourceCardAppearance(card: SourceCharacterCard.load(url: directory.appendingPathComponent(oracle.cardFile)))
    let result = try appearance.applying(card, bindings: bindings.restricted(to: Set(oracle.recipes.map(\.part))), directory: base, resources: resources)
    #expect(result.appliedFields.contains("makeup.paintColor.0"))
    #expect(result.appliedFields.contains("clothes.parts.0.colorInfo.0.patternColor"))
    for recipe in oracle.recipes {
        let handle = try #require(result.appearance.materials[recipe.part]?.first?.base)
        let texture = try #require(resources.texture(handle))
        let expected = [UInt8](try Data(contentsOf: directory.appendingPathComponent(recipe.file)))
        var actual = [UInt8](repeating: 0, count: recipe.width * recipe.height * 4)
        actual.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: recipe.width * 4,
            from: MTLRegionMake2D(0,0,recipe.width,recipe.height), mipmapLevel: 0) }
        #expect(actual.count == expected.count)
        let errors = zip(actual, expected).map { abs(Int($0) - Int($1)) }
        #expect((errors.max() ?? 0) <= 1)
    }
}
