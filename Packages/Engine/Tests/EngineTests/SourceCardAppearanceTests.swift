import Foundation
import Testing
import CryptoKit
import Metal
import Assets
import CoreMath
import Renderer
import Character

/// Public-format synthetic records; no source imagery or plug-in execution.
enum AppearanceTestFixture {
    typealias F = OriginalCardFixture
    static func card(bodyOverrides: [(String, F.Value)] = [], modProperty: String? = nil, guid: String = "example.mod") throws -> SourceCharacterCard {
        let rgba = F.Value.array([.float(0.25), .float(0.5), .float(0.75), .float(0.8)])
        let face = F.pack(F.map([("version", .string("0.0.2")), ("headId", .integer(0)), ("shapeValueFace", .array(F.faceValues)), ("eyebrowColor", rgba), ("pupil", .array([F.map([("id", .integer(0)), ("baseColor", rgba), ("gradBlend", .float(0.5))])]))]))
        let defaults: [(String, F.Value)] = [("version", .string("0.0.2")), ("shapeValueBody", .array(F.bodyValues)), ("skinId", .integer(0)), ("skinMainColor", rgba), ("skinSubColor", rgba)]
        let overridden = Set(bodyOverrides.map(\.0))
        let body = F.pack(F.map(defaults.filter { !overridden.contains($0.0) } + bodyOverrides))
        let hair = F.pack(F.map([("version", .string("0.0.4")), ("parts", .array([F.map([("id", .integer(2)), ("baseColor", rgba), ("startColor", rgba), ("endColor", rgba)])]))]))
        let custom = F.lengthData(face) + F.lengthData(body) + F.lengthData(hair)
        var blocks = F.blocks(custom: custom)
        if let modProperty {
            let info = F.pack(F.map([("ModID", .string(guid)), ("Property", .string(modProperty)), ("Slot", .integer(0))]))
            let plugin = F.plugin(0, data: F.map([("info", .array([.binary(info)]))]))
            blocks.append(F.extended(F.map([("com.bepis.sideloader.universalautoresolver", plugin)])))
        }
        return try SourceCharacterCard.decode(F.card(blocks: blocks))
    }
    static func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-appearance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    static func bindings(_ entries: [[String: Any]], directory: URL) throws -> SourceAppearanceBindings {
        let url = directory.appendingPathComponent("bindings-" + UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": entries, "limitations": ["Synthetic limit."]]).write(to: url)
        return try SourceAppearanceBindings.load(url: url)
    }
    static func preview(directory: URL, resources: ResourceStore, names: [String] = ["part"]) throws -> SourcePreviewAppearance {
        let file = directory.appendingPathComponent("preview.json")
        let parts = names.map { ["part": $0, "kind": "unlit", "color": [0.6, 0.7, 0.8, 1.0], "alphaMode": "OPAQUE"] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "parts": parts]).write(to: file)
        return try .load(url: file, resources: resources)
    }
    static func entry(kind: String = "tint", colors: [String] = ["body.skinMainColor"], requirements: [String: Int] = [:], resolver: [String] = []) -> [String: Any] {
        ["parts": ["part"], "pass": 0, "kind": kind, "colors": colors, "requirements": requirements, "resolverProperties": resolver]
    }
    static func texture(_ bytes: [UInt8], directory: URL) throws -> [String: Any] {
        let data = Data(bytes), name = UUID().uuidString + ".rgba"
        try data.write(to: directory.appendingPathComponent(name))
        return ["file": name, "sha256": F.hash(data), "width": bytes.count / 4, "height": 1]
    }
    static func recipe(directory: URL) throws -> [String: Any] {
        var result = entry(kind: "head", colors: ["body.skinMainColor", "body.skinSubColor"])
        result["main"] = try texture([128, 64, 255, 255], directory: directory)
        result["mask"] = try texture([255, 0, 0, 0], directory: directory)
        return result
    }
}

@Test func sourceCardAppearanceReadsTypedColorsPathsAndPreservesMissingFields() throws {
    let card = try AppearanceTestFixture.card(), appearance = try SourceCardAppearance(card: card)
    #expect(appearance.color("body.skinMainColor") == Float4(0.25, 0.5, 0.75, 0.8))
    #expect(appearance.color("face.pupil.0.baseColor") == Float4(0.25, 0.5, 0.75, 0.8))
    #expect(appearance.color("face.pupil.1.baseColor") == nil)
    #expect(appearance.number("face.pupil.0.gradBlend") == 0.5)
    #expect(appearance.value("hair.parts.0.id")?.integerValue == 2)
    #expect(appearance.value("hair.parts.99.id") == nil)
    #expect(appearance.value("missing") == nil)
    #expect(appearance.diagnostics.contains { $0.contains("clothes") })
    #expect(appearance.modProperties.isEmpty)
    #expect(throws: (any Error).self) { try SourceCardAppearance(card: card, coordinate: -1) }
    #expect(throws: (any Error).self) { try SourceCardAppearance(card: card, coordinate: 7) }
}

@Test func sourceCardAppearanceRejectsMalformedColorArraysWithoutCoercion() throws {
    let rgba = [OriginalCardFixture.Value.float(0.25), .float(0.5), .float(0.75), .float(1)]
    for malformed: OriginalCardFixture.Value in [.array(rgba + [.null]), .array(Array(rgba.prefix(3))),
                                                 .array([.float(0), .float(0), .float(0), .float(1.1)]),
                                                 .array([.float(0), .null, .float(0), .float(1)]),
                                                 .array([.float(0), .float(.nan), .float(0), .float(1)])] {
        let card = try AppearanceTestFixture.card(bodyOverrides: [("skinMainColor", malformed)])
        let appearance = try SourceCardAppearance(card: card)
        #expect(appearance.color("body.skinMainColor") == nil)
        #expect(appearance.diagnostics.contains { $0.contains("body.skinMainColor") })
        #expect(try card.editedData(.init()) == card.preservedData)
    }
}

@Test func sourceCardAppearanceNormalizedEditsRoundTripAndRetainModMetadata() throws {
    let card = try AppearanceTestFixture.card(modProperty: "ChaFileBody.detailId")
    var appearance = try SourceCardAppearance(card: card)
    let next = Float4(0.125, 0.25, 0.5, 1)
    try appearance.setColor("body.skinMainColor", rgba: next)
    let edits = appearance.colors.map(\.edit)
    let decoded = try SourceCharacterCard.decode(card.editedData(.init(colors: edits)))
    #expect(try SourceCardAppearance(card: decoded).color("body.skinMainColor") == next)
    #expect(decoded.block(named: "KKEx")?.data == card.block(named: "KKEx")?.data)
    #expect(decoded.block(named: "Parameter")?.data == card.block(named: "Parameter")?.data)
    #expect(appearance.modProperties == ["ChaFileBody.detailId"])
    for rgba in [Float4(-0.1, 0, 0, 1), Float4(.nan, 0, 0, 1), Float4(0, 0, 0, 1.1)] {
        #expect(throws: (any Error).self) { try appearance.setColor("body.skinMainColor", rgba: rgba) }
    }
    #expect(throws: (any Error).self) { try appearance.setColor("unknown", rgba: .one) }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceCardAppearanceBindingsGateSelectionAndSavedModIdentityBeforeReadingTextures() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let original = try AppearanceTestFixture.preview(directory: directory, resources: resources)
    var entry = try AppearanceTestFixture.recipe(directory: directory)
    entry["requirements"] = ["body.skinId": 2]
    entry["main"] = ["file": "does-not-exist.rgba", "width": 1, "height": 1, "sha256": "bad"]
    var appearance = try SourceCardAppearance(card: AppearanceTestFixture.card())
    var result = try original.applying(appearance, bindings: AppearanceTestFixture.bindings([entry], directory: directory), directory: directory, resources: resources)
    #expect(result.appliedFields.isEmpty && result.appearance.materials == original.materials)
    #expect(result.diagnostics.contains { $0.contains("body.skinId") })
    entry["requirements"] = ["body.skinId": 0]
    entry["resolverProperties"] = ["outfit{coordinate}.ChaFileClothes.ClothesTop"]
    appearance = try SourceCardAppearance(card: AppearanceTestFixture.card(modProperty: "outfit3.ChaFileClothes.ClothesTop"), coordinate: 3)
    result = try original.applying(appearance, bindings: AppearanceTestFixture.bindings([entry], directory: directory), directory: directory, resources: resources)
    #expect(result.appliedFields.isEmpty && result.appearance.materials == original.materials)
    #expect(result.diagnostics.contains { $0.contains("ChaFileClothes.ClothesTop") })
    // Empty GUID metadata is not evidence of a mod override.
    #expect(try SourceCardAppearance(card: AppearanceTestFixture.card(modProperty: "ChaFileBody.detailId", guid: " \t")).modProperties.isEmpty)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceCardAppearanceBindingsValidatePathsHashesDimensionsAndMaterialTargets() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let original = try AppearanceTestFixture.preview(directory: directory, resources: resources)
    let appearance = try SourceCardAppearance(card: AppearanceTestFixture.card())
    let valid = try AppearanceTestFixture.recipe(directory: directory)
    let main = try #require(valid["main"] as? [String: Any])
    var badEntries: [[String: Any]] = []
    for change in [["file": "../outside.rgba"], ["file": "/outside.rgba"], ["sha256": "0"], ["width": 4097], ["width": 2]] as [[String: Any]] {
        var entry = valid, texture = main
        texture.merge(change) { _, new in new }; entry["main"] = texture; badEntries.append(entry)
    }
    for change in [["parts": ["absent"]], ["pass": 1], ["pass": -1], ["kind": "unknown"], ["colors": ["body.skinMainColor"]]] as [[String: Any]] {
        var entry = valid; entry.merge(change) { _, new in new }; badEntries.append(entry)
    }
    for entry in badEntries {
        #expect(throws: (any Error).self) {
            try original.applying(appearance, bindings: AppearanceTestFixture.bindings([entry], directory: directory), directory: directory, resources: resources)
        }
    }
    let path = directory.appendingPathComponent(try #require(main["file"] as? String))
    try Data([1, 2, 3, 4, 5]).write(to: path)
    #expect(throws: (any Error).self) {
        try original.applying(appearance, bindings: AppearanceTestFixture.bindings([valid], directory: directory), directory: directory, resources: resources)
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceCardAppearanceTransientTextureLifetimeAndFailureCleanup() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let original = try AppearanceTestFixture.preview(directory: directory, resources: resources)
    let appearance = try SourceCardAppearance(card: AppearanceTestFixture.card())
    let recipe = try AppearanceTestFixture.recipe(directory: directory)
    let bindings = try AppearanceTestFixture.bindings([recipe], directory: directory)
    var first: SourcePreviewAppearance.CardApplication? = try original.applying(appearance, bindings: bindings, directory: directory, resources: resources)
    let firstHandle = try #require(first?.appearance.materials["part"]?.first?.base)
    var second: SourcePreviewAppearance.CardApplication? = try first!.appearance.applying(appearance, bindings: bindings, directory: directory, resources: resources)
    let secondHandle = try #require(second?.appearance.materials["part"]?.first?.base)
    #expect(firstHandle != secondHandle)
    first = nil
    #expect(resources.texture(firstHandle) == nil && resources.texture(secondHandle) != nil)
    second = nil
    #expect(resources.texture(firstHandle) == nil && resources.texture(secondHandle) == nil)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
    let sentinel = resources.register(texture: try #require(resources.device.makeTexture(descriptor: descriptor)))
    var invalid = AppearanceTestFixture.entry(); invalid["parts"] = ["absent"]
    #expect(throws: (any Error).self) {
        try original.applying(appearance, bindings: AppearanceTestFixture.bindings([recipe, invalid], directory: directory), directory: directory, resources: resources)
    }
    #expect(resources.texture(TextureHandle(id: sentinel.id + 1)) == nil)
    #expect(resources.texture(sentinel) != nil)
    resources.unregister(texture: sentinel)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceCardAppearanceDerivedMaterialKeepsUnmodifiedTextureLease() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let original = try AppearanceTestFixture.preview(directory: directory, resources: resources, names: ["part", "other"])
    let card = try SourceCardAppearance(card: AppearanceTestFixture.card())
    let recipe = try AppearanceTestFixture.recipe(directory: directory)
    var other = recipe; other["parts"] = ["other"]
    var first: SourcePreviewAppearance.CardApplication? = try original.applying(card, bindings: AppearanceTestFixture.bindings([recipe, other], directory: directory), directory: directory, resources: resources)
    let replaced = try #require(first?.appearance.materials["part"]?.first?.base)
    let retained = try #require(first?.appearance.materials["other"]?.first?.base)
    var second: SourcePreviewAppearance.CardApplication? = try first!.appearance.applying(card, bindings: AppearanceTestFixture.bindings([recipe], directory: directory), directory: directory, resources: resources)
    first = nil
    #expect(resources.texture(replaced) == nil)
    #expect(resources.texture(retained) != nil)
    #expect(second?.appearance.materials["other"]?.first?.base == retained)
    second = nil
    #expect(resources.texture(retained) == nil)
}

private struct AppearanceOracle: Decodable {
    struct Recipe: Decodable { let entryIndex: Int, parts: [String], kind: String, file: String, sha256: String, bytes: Int, tolerance: Int }
    let cardSHA256: String, cardFile: String, sex: Int, expectedAppliedFields: [String], expectedRecipeCount: Int, recipes: [Recipe]
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_APPEARANCE_REFERENCE_ROOT"]) && MTLCreateSystemDefaultDevice() != nil, "Requires IKKOKU_APPEARANCE_REFERENCE_ROOT and a Metal device"))
func sourceCardAppearanceFemaleAndMalePixelsMatchIndependentRawRGBAOracle() throws {
    let root = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_APPEARANCE_REFERENCE_ROOT"))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for (folder, name) in [("rigs", "source-avatar"), ("male", "source-male-avatar")] {
        let directory = root.appendingPathComponent(folder)
        let oracle = try JSONDecoder().decode(AppearanceOracle.self, from: Data(contentsOf: directory.appendingPathComponent("synthetic-appearance-oracle.json")))
        let card = try SourceCharacterCard.load(url: directory.appendingPathComponent(oracle.cardFile))
        #expect(card.sourceSHA256 == oracle.cardSHA256)
        #expect(try card.customization().sex == oracle.sex)
        let appearance = try SourceCardAppearance(card: card)
        let original = try SourcePreviewAppearance.load(url: directory.appendingPathComponent(name + ".appearance.json"), resources: resources)
        let bindings = try SourceAppearanceBindings.load(url: directory.appendingPathComponent(name + ".card-appearance.json"))
        #expect(bindings.entries.count == oracle.expectedRecipeCount)
        let result = try original.applying(appearance, bindings: bindings, directory: directory, resources: resources)
        #expect(result.appliedFields == Set(oracle.expectedAppliedFields))
        for recipe in oracle.recipes {
            let entry = bindings.entries[recipe.entryIndex]
            #expect(entry.kind == recipe.kind && entry.parts == recipe.parts)
            let handle = try #require(result.appearance.materials[entry.parts[0]]?[entry.pass].base)
            let texture = try #require(resources.texture(handle))
            #expect(texture.pixelFormat == .rgba8Unorm_srgb)
            let expected = try Data(contentsOf: directory.appendingPathComponent(recipe.file))
            #expect(OriginalCardFixture.hash(expected) == recipe.sha256)
            #expect(expected.count == recipe.bytes && expected.count == texture.width * texture.height * 4)
            var actual = [UInt8](repeating: 0, count: expected.count)
            actual.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
            let maximumDifference = zip(actual, expected).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
            #expect(maximumDifference <= recipe.tolerance, "\(folder)/\(recipe.kind)/\(entry.parts): maximum byte difference \(maximumDifference)")
            for part in entry.parts { #expect(result.appearance.materials[part]?[entry.pass].base == handle) }
        }
    }
}
