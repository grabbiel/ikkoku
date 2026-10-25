import Foundation
import Testing
import CryptoKit
import Assets
import Character
import Renderer
import Studio

/// Synthetic translated-program descriptors, binding sets, capture frames and
/// Maker-library evidence. Nothing here reads original data.
private enum ShaderBindingFixture {
    typealias Row = [String: Any]

    static func property(_ name: String, type: Int, defaults: [Double] = [0, 0, 0, 0], texture: String = "white") -> Row {
        var row: Row = ["m_Name": name, "m_Type": type, "m_DefTexture": ["m_DefaultName": texture]]
        for (index, value) in defaults.enumerated() { row["m_DefValue[\(index)]"] = value }
        return row
    }

    static func state(_ value: Int, _ name: String = "<noninit>") -> Row { ["val": value, "name": name] }

    /// A `program.json` in the shape `source_shader_translation.py` writes.
    static func program(shader: String, pass: String, properties: [Row], vertex: [(String, Int)], fragment: [(String, Int)],
                        textures: [String], keywords: [String] = ["DIRECTIONAL"], zWriteProperty: String? = nil) throws -> Data {
        var names: [String: String] = [:], index: [String: Int] = [:]
        for name in (vertex + fragment).map(\.0) + textures where index[name] == nil {
            index[name] = index.count; names[String(index[name]!)] = name
        }
        func vectors(_ list: [(String, Int)]) -> [Row] { list.map { ["m_NameIndex": index[$0.0]!, "m_Dim": $0.1] } }
        let passState: Row = [
            "m_Name": pass, "zTest": state(4), "zWrite": state(1, zWriteProperty ?? "<noninit>"), "culling": state(2),
            "stencilRef": state(0), "stencilReadMask": state(255), "stencilWriteMask": state(255),
            "rtBlend0": ["srcBlend": state(1), "destBlend": state(0), "colMask": state(15)],
            "stencilOp": ["comp": state(8), "pass": state(0), "fail": state(0), "zFail": state(0)],
        ]
        let root: Row = [
            "name": shader, "names": names, "properties": properties, "passState": passState,
            "programs": [
                "vertex": ["keywords": keywords, "metadata": ["m_ConstantBuffers": [["m_VectorParams": vectors(vertex)]], "m_TextureParams": []]],
                "fragment": ["keywords": keywords + ["EXTRA"], "metadata": [
                    "m_ConstantBuffers": [["m_VectorParams": vectors(fragment)]],
                    "m_TextureParams": textures.map { ["m_NameIndex": index[$0]!] }]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    static let testShader = "Shader Forge/main_test"
    static func testContract(pass: String = "FORWARD") throws -> SourceShaderProgramContract {
        try .decode(program(shader: testShader, pass: pass,
            properties: [property("_Color", type: 0, defaults: [1, 0.5, 0.25, 1]), property("_Cutoff", type: 3, defaults: [0.5]),
                         property("_Spec", type: 2, defaults: [2]), property("_MainTex", type: 4),
                         property("_Mask", type: 4, texture: "black"), property("_Unbound", type: 4, texture: "gray")],
            vertex: [("_MainTex_ST", 4), ("_Mask_ST", 4), ("_Unbound_ST", 4), ("_WorldSpaceLightPos0", 4), ("_Time", 4)],
            fragment: [("_Color", 4), ("_Cutoff", 1), ("_Spec", 1), ("_LineColorG", 4), ("_MainTex_ST", 4), ("_RampG_ST", 4)],
            textures: ["_MainTex", "_Mask", "_Unbound", "_RampG"]), program: "main_test")
    }

    typealias Set_ = SourceShaderBindingSet
    static func asset(_ name: String, pathID: String = "7", bundleSHA: String = "aaa") -> Set_.TextureIdentity {
        Set_.TextureIdentity(kind: .asset, name: name, bundle: "chara/test.unity3d", bundleSHA256: bundleSHA, pathID: pathID,
                             width: 4, height: 4, mipLevels: 3, filter: "Bilinear", wrap: "Repeat", aniso: 1)
    }
    static func texture(_ identity: Set_.TextureIdentity?, scale: [Float] = [1, 1], offset: [Float] = [0, 0]) -> Set_.Texture {
        Set_.Texture(identity: identity, identitySource: "prefab m_TexEnvs", scale: scale, offset: offset, transformSource: "prefab m_TexEnvs")
    }

    static func bindings(contract: SourceShaderProgramContract) -> Set_ {
        let material = Set_.Material(name: "m_a", shader: testShader, queue: 2000, queueSource: "prefab", keywords: ["K"], keywordsSource: "prefab",
            passStates: ["FORWARD": contract.passState],
            vectors: ["_Color": .init([0.5, 0.25, 0.125, 1], source: "card"), "_Cutoff": .init([0.500004], source: "prefab m_Floats"),
                      "_Spec": .init(unresolved: "synthetic unresolved reason")],
            textures: ["_MainTex": texture(asset("tex_a")), "_Mask": texture(asset("tex_wrong", pathID: "8"), scale: [2, 2]),
                       "_Unbound": texture(nil, scale: [3, 3])])
        func renderer(_ mesh: String, _ slot: Int, visible: Bool = true) -> Set_.Renderer {
            .init(mesh: mesh, component: "synthetic", materialSlot: slot, submesh: 0, visible: visible, visibility: "synthetic", material: material)
        }
        return Set_(scope: "synthetic", renderers: [renderer("o_a", 0), renderer("o_a", 1), renderer("o_hidden", 0, visible: false), renderer("o_extra", 0)],
            globalVectors: ["_LineColorG": .init([0.5, 0.5, 0.5, 0], source: "scene"), "_Time": .init(unresolved: "clock")],
            globalTextures: ["_RampG": texture(Set_.TextureIdentity(kind: .asset, name: "ramp", width: 256, height: 4))])
    }

    /// `color` replaces slot 0's captured `_Color` only.
    static func frame(color: [Double] = [0.5, 0.25, 0.125, 1]) -> Row {
        func material(_ color: [Double]) -> Row {
            ["shader": testShader, "name": "m_a", "queue": 2000, "keywords": ["K"], "properties": [
                "_Color": color, "_Cutoff": 0.5, "_MainTex": ["file": "a.bin", "scale": [1, 1], "offset": [0, 0]],
                "_Mask": ["file": "m.bin", "scale": [1, 1], "offset": [0, 0]]]]
        }
        func texture(_ file: String, _ name: String, pathID: Int) -> Row {
            ["file": file, "textureType": "Texture2D", "name": name, "width": 4, "height": 4, "filter": "Bilinear", "wrap": "Repeat",
             "aniso": 1, "mipLevels": 3, "authoredMipSource": ["pathID": pathID, "bundleSHA256": "bbb"]]
        }
        return ["meshes": [["name": "o_a", "submeshes": 1, "materials": [material(color), material([0.5, 0.25, 0.125, 1])]]],
                "textures": [texture("a.bin", "tex_a", pathID: 7), texture("m.bin", "tex_m", pathID: 9),
                             ["file": "ramp.bin", "textureType": "Texture2D", "name": "ramp", "width": 256, "height": 4]],
                "globals": ["_LineColorG": [0.5, 0.5, 0.5, 0], "_Time": [0, 1, 2, 3], "_RampG": "ramp.bin"]]
    }

    static func compare(_ frame: Row, bindings: Set_? = nil) throws -> SourceShaderBindingComparison {
        let contract = try testContract()
        return try SourceShaderBindingComparison.compare(bindings: bindings ?? self.bindings(contract: contract),
            frame: JSONSerialization.data(withJSONObject: frame), catalog: SourceShaderProgramCatalog(programs: [testShader: [contract]]))
    }

    static func finding(_ comparison: SourceShaderBindingComparison, _ mesh: String?, _ slot: Int?, _ category: SourceShaderBindingComparison.Category,
                        _ input: String) -> SourceShaderBindingComparison.Finding? {
        comparison.findings.first { $0.mesh == mesh && $0.materialSlot == slot && $0.category == category && $0.input == input }
    }
}

@Test func sourceShaderProgramContractClassifiesEveryProbeInputBySource() throws {
    let contract = try ShaderBindingFixture.testContract()
    let sources = Dictionary(uniqueKeysWithValues: contract.inputs.map { ($0.name, $0.source) })
    #expect(sources == ["_MainTex_ST": .materialTextureTransform, "_Mask_ST": .materialTextureTransform, "_Unbound_ST": .materialTextureTransform,
                        "_WorldSpaceLightPos0": .builtin, "_Time": .globalVector, "_Color": .materialVector, "_Cutoff": .materialVector,
                        "_Spec": .materialVector, "_LineColorG": .globalVector, "_RampG_ST": .globalVector,
                        "_MainTex": .materialTexture, "_Mask": .materialTexture, "_Unbound": .materialTexture, "_RampG": .globalTexture])
    // First-use order, merged stages and the widest lane count.
    #expect(contract.inputs.first?.name == "_MainTex_ST")
    #expect(contract.inputs.first { $0.name == "_MainTex_ST" }?.stages == ["vertex", "fragment"])
    #expect(contract.inputs.first { $0.name == "_Cutoff" }?.dimension == 1)
    #expect(contract.inputs.first { $0.name == "_RampG" }.map { $0.isTexture && $0.dimension == 0 } == true)
    #expect(contract.properties["_Color"]?.isColor == true && contract.properties["_Color"]?.defaultValue == [1, 0.5, 0.25, 1])
    #expect(contract.properties["_Mask"]?.defaultTexture == "black" && contract.properties["_Cutoff"]?.defaultTexture == nil)
    #expect(contract.passState["zTest"] == 4 && contract.passState["srcBlend"] == 1 && contract.passState["stencilComp"] == 8)
    #expect(contract.propertyDrivenPassState.isEmpty && contract.keywords == ["DIRECTIONAL", "EXTRA"])
    #expect(contract.shader == ShaderBindingFixture.testShader && contract.pass == "FORWARD" && contract.program == "main_test")
    let driven = try SourceShaderProgramContract.decode(ShaderBindingFixture.program(shader: "S", pass: "FORWARD", properties: [],
        vertex: [], fragment: [], textures: [], zWriteProperty: "_ZWrite"), program: "p")
    #expect(driven.propertyDrivenPassState == ["zWrite": "_ZWrite"])
    // An undeclared `_ST` without its texture property is a global, not a transform.
    #expect(SourceShaderProgramContract.classify("_Other_ST", isTexture: false, properties: contract.properties) == .globalVector)
    #expect(SourceShaderProgramContract.classify("_Time", isTexture: false, properties: [:]) == .globalVector)
}

@Test func sourceShaderProgramContractRejectsMalformedDescriptorsAndOrdersOutlineFirst() throws {
    typealias F = ShaderBindingFixture
    let duplicate = try F.program(shader: "S", pass: "FORWARD", properties: [F.property("_A", type: 2), F.property("_A", type: 2)],
                                  vertex: [], fragment: [], textures: [])
    let conflict = try F.program(shader: "S", pass: "FORWARD", properties: [], vertex: [("_A", 4)], fragment: [], textures: ["_A"])
    let unknownType = try F.program(shader: "S", pass: "FORWARD", properties: [F.property("_A", type: 5)], vertex: [], fragment: [], textures: [])
    let wideVector = try F.program(shader: "S", pass: "FORWARD", properties: [], vertex: [("_A", 5)], fragment: [], textures: [])
    for data in [duplicate, conflict, unknownType, wideVector, Data("{}".utf8)] {
        #expect(throws: SourceShaderProgramContract.ContractError.self) { try SourceShaderProgramContract.decode(data, program: "p") }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-programs-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, pass) in [("main_test", "FORWARD"), ("main_test_outline", "OUTLINE")] {
        let folder = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try F.program(shader: F.testShader, pass: pass, properties: [F.property("_Color", type: 0)],
                      vertex: [(pass == "OUTLINE" ? "_linewidthG" : "_Color", 4)], fragment: [("_Color", 4)], textures: [])
            .write(to: folder.appendingPathComponent("program.json"))
    }
    let catalog = try SourceShaderProgramCatalog.load(directory: directory)
    #expect(catalog.passes(for: F.testShader).map(\.program) == ["main_test_outline", "main_test"])
    #expect(catalog.inputs(for: F.testShader).map(\.name) == ["_linewidthG", "_Color"])
    #expect(catalog.passes(for: "Shader Forge/absent").isEmpty)
    let again = directory.appendingPathComponent("main_test_copy")
    try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: directory.appendingPathComponent("main_test/program.json"), to: again.appendingPathComponent("program.json"))
    #expect(throws: SourceShaderProgramContract.ContractError.self) { try SourceShaderProgramCatalog.load(directory: directory) }
}

@Test func sourceShaderBindingComparisonReportsEveryStatusWithItsCause() throws {
    typealias F = ShaderBindingFixture
    let comparison = try F.compare(F.frame())
    func status(_ mesh: String?, _ slot: Int?, _ category: SourceShaderBindingComparison.Category, _ input: String) -> SourceShaderBindingComparison.Status? {
        F.finding(comparison, mesh, slot, category, input)?.status
    }
    #expect(status("o_a", 0, .renderer, "renderer") == .exact)
    #expect(status("o_a", 0, .shader, "shader") == .exact && status("o_a", 0, .queue, "renderQueue") == .exact)
    #expect(status("o_a", 0, .keywords, "shaderKeywords") == .exact && status("o_a", 0, .passState, "FORWARD") == .exact)
    #expect(status("o_a", 0, .vector, "_Color") == .exact)
    #expect(status("o_a", 0, .vector, "_Cutoff") == .withinTolerance)
    let spec = try #require(F.finding(comparison, "o_a", 0, .vector, "_Spec"))
    #expect(spec.status == .missingNatively && spec.cause == "synthetic unresolved reason" && spec.captureSource == "program default (not recorded)")
    #expect(status("o_a", 0, .textureTransform, "_MainTex_ST") == .exact)
    let mask = try #require(F.finding(comparison, "o_a", 0, .textureTransform, "_Mask_ST"))
    #expect(mask.status == .differs && mask.cause?.contains("prefab") == true)
    // Neither side binds _Unbound, so its transform cannot change the draw.
    #expect(status("o_a", 0, .textureTransform, "_Unbound_ST") == .withinTolerance)
    let main = try #require(F.finding(comparison, "o_a", 0, .texture, "_MainTex"))
    #expect(main.status == .exact && main.note?.contains("bundle attribution differs") == true)
    #expect(status("o_a", 0, .sampler, "_MainTex") == .exact)
    let maskTexture = try #require(F.finding(comparison, "o_a", 0, .texture, "_Mask"))
    #expect(maskTexture.status == .differs && maskTexture.cause?.contains("name tex_wrong vs tex_m") == true)
    #expect(status("o_a", 0, .texture, "_Unbound") == .exact)
    // Slot 1 is beyond the mesh's single submesh: Unity and the probe draw it
    // over the last submesh, so it is compared like any drawn slot.
    let extraSlot = try #require(F.finding(comparison, "o_a", 1, .renderer, "renderer"))
    #expect(extraSlot.status == .exact && extraSlot.note?.contains("draw it over the last submesh") == true)
    #expect(status("o_extra", 0, .renderer, "renderer") == .extra && status("o_hidden", 0, .renderer, "renderer") == .exact)
    #expect(status(nil, nil, .vector, "_LineColorG") == .exact && status(nil, nil, .vector, "_Time") == .missingNatively)
    #expect(status(nil, nil, .texture, "_RampG") == .exact)
    let ramp = try #require(F.finding(comparison, nil, nil, .vector, "_RampG_ST"))
    #expect(ramp.status == .missingNatively && ramp.captureSource?.hasPrefix("probe convention") == true)
    // Four globals, plus the bound `_RampG`'s sampler (not derived here).
    #expect(comparison.findings.filter { $0.family == "global" }.count == 5)
    #expect(status(nil, nil, .sampler, "_RampG") == .missingNatively)
    #expect(comparison.overall.total == comparison.findings.count)
    #expect(comparison.byCategory.values.map(\.total).reduce(0, +) == comparison.findings.count)
    #expect(comparison.familyTotals.values.map(\.total).reduce(0, +) == comparison.findings.count)
    #expect(comparison.gaps.map(\.count).reduce(0, +) == comparison.overall.differs + comparison.overall.missingNatively + comparison.overall.extra)
    // Mutation control: one captured lane moved by 1e-4 is a difference.
    let mutated = try F.compare(F.frame(color: [0.5, 0.2501, 0.125, 1]))
    #expect(F.finding(mutated, "o_a", 0, .vector, "_Color")?.status == .differs)
    #expect(mutated.overall.differs == comparison.overall.differs + 1)
    #expect(throws: SourceShaderBindingComparison.ComparisonError.self) { try F.compare(["meshes": []]) }
}

@Test func sourceShaderBindingComparisonUsesTheCapturePlugins7DigitFloatText() {
    let value: Float = 0.307
    #expect(SourceShaderBindingComparison.sevenDigitEqual(value.nextUp, Float("0.307")!))
    #expect(SourceShaderBindingComparison.sevenDigitEqual(1.0 / 3.0, Float("0.3333333")!))
    #expect(!SourceShaderBindingComparison.sevenDigitEqual(0.3071, 0.307))
    #expect(!SourceShaderBindingComparison.sevenDigitEqual(.nan, .nan))
    #expect(SourceShaderBindingComparison.vectorTolerance == 1e-5)
}

@Test func sourceShaderBindingFrameSubstitutionReplacesOnlyResolvedNativeValues() throws {
    typealias F = ShaderBindingFixture
    let contract = try F.testContract()
    let catalog = SourceShaderProgramCatalog(programs: [F.testShader: [contract]])
    let (data, report) = try SourceShaderBindingFrameSubstitution.substitute(bindings: F.bindings(contract: contract),
        frame: JSONSerialization.data(withJSONObject: F.frame()), catalog: catalog)
    // Both slots are drawn (slot 1 over the last submesh), so both substitute.
    // Sampler state lives on the shared texture row, so each file counts once.
    #expect(report.substituted == ["queue": 2, "vector": 4, "textureTransform": 4, "texture": 4, "sampler": 1, "globalVector": 1, "globalTexture": 1])
    #expect(report.keptCapture == ["synthetic unresolved reason": 2, "clock": 1, "global not derived": 1, "sampler state not derived": 1,
                                   "native texture pixels are not available to the probe (identity differs from the capture)": 2])
    // Only the near-equal `_Cutoff` and the prefab `_Mask` scale change value, per slot.
    #expect(report.changedValues == 4)
    let frame = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let materials = try #require((frame["meshes"] as? [[String: Any]])?.first?["materials"] as? [[String: Any]])
    let properties = try #require(materials[0]["properties"] as? [String: Any])
    #expect((properties["_Cutoff"] as? NSNumber)?.floatValue == 0.500004)
    #expect(((properties["_Mask"] as? [String: Any])?["scale"] as? [NSNumber])?.map(\.floatValue) == [2, 2])
    #expect((properties["_Mask"] as? [String: Any])?["file"] as? String == "m.bin")
    #expect(properties["_Spec"] == nil && properties["_Unbound"] == nil)
    // Slot 1 is beyond the submesh count; the probe draws it over the last
    // submesh, so it is substituted too.
    #expect(((materials[1]["properties"] as? [String: Any])?["_Cutoff"] as? NSNumber)?.floatValue == 0.500004)
    #expect(frame["nativeBindingSubstitution"] != nil && (frame["globals"] as? [String: Any])?["_Time"] as? [Int] == [0, 1, 2, 3])
}

// MARK: - Derivation on synthetic inputs

private enum DerivationFixture {
    typealias F = OriginalCardFixture
    static let hairShader = "Shader Forge/main_hair"

    static func catalog() throws -> SourceShaderProgramCatalog {
        typealias P = ShaderBindingFixture
        let contract = try SourceShaderProgramContract.decode(P.program(shader: hairShader, pass: "FORWARD",
            properties: [P.property("_Color", type: 0), P.property("_LineColor", type: 0), P.property("_Cutoff", type: 3, defaults: [0.5]),
                         P.property("_ShadowExtend", type: 2, defaults: [1]), P.property("_HairGloss", type: 4),
                         P.property("_ColorMask", type: 4), P.property("_AnotherRamp", type: 4)],
            vertex: [("_ColorMask_ST", 4)], fragment: [("_Color", 4), ("_LineColor", 4), ("_Cutoff", 1), ("_ShadowExtend", 1), ("_HairGloss_ST", 4)],
            textures: ["_HairGloss", "_ColorMask", "_AnotherRamp"]), program: "main_hair")
        return SourceShaderProgramCatalog(programs: [hairShader: [contract]])
    }

    static func evidence() -> [String: Any] {
        let state: [String: Any] = ["zTest": ["val": 4.0, "name": "<noninit>"], "stencilOp": ["comp": ["val": 8.0, "name": "<noninit>"]]]
        let material: [String: Any] = [
            "name": "m_hair", "serializedFile": "CAB-hair", "pathID": "11", "shader": hairShader, "renderQueue": -1,
            "passes": [["name": "OUTLINE", "tags": ["QUEUE": "Transparent-150"], "state": state, "blend": ["srcBlend": ["val": 1.0, "name": "<noninit>"]]],
                       ["name": "FORWARD", "state": state], ["name": "SHADOWCASTER", "state": state]],
            "floats": ["_Cutoff": 0.25], "colors": ["_Color": [0.1, 0.2, 0.3, 1], "_LineColor": [0.7, 0.7, 0.7, 0.5]],
            "textures": ["_ColorMask": ["texture": ["serializedFile": "CAB-hair", "pathID": "5", "name": "mask"], "scale": [1, 1], "offset": [0.5, 0]],
                         "_HairGloss": ["texture": NSNull(), "scale": [1, 1], "offset": [-0.06, 0.02]]]]
        return ["category": 101, "id": 2, "source": ["bundle": "chara/test_hair.unity3d", "bundleSHA256": "hairsha"],
                "catalog": [:], "catalogTextures": [:],
                "componentTrees": [["rendHair": [["m_FileID": 0, "m_PathID": 99]], "rendAccessory": []]],
                "renderers": [["meshName": "o_hair", "nodeName": "o_hair", "materialSlot": 0, "material": material,
                               "materialTree": ["m_Name": "m_hair", "m_ShaderKeywords": "_A _B"]]]]
    }

    static func library(directory: URL) throws -> SourceMakerLibrary {
        let materials = try JSONSerialization.data(withJSONObject: evidence())
        try materials.write(to: directory.appendingPathComponent("materials.json"))
        // A converted (non-empty) entry needs a rig and mesh names; the
        // derivation reads only the material evidence.
        let rig = Data("{}".utf8)
        try rig.write(to: directory.appendingPathComponent("rig.json"))
        let entry: [String: Any] = ["category": 101, "id": 2, "name": "hair", "meshNames": ["o_hair"],
                                    "rig": ["file": "rig.json", "sha256": F.hash(rig)],
                                    "materialEvidence": ["file": "materials.json", "sha256": F.hash(materials)]]
        let url = directory.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [entry]]).write(to: url)
        return try .load(url: url)
    }

    static let headContract = Data(#"{"sources":[],"catalogRows":[],"textures":[],"drawMaterials":[],"renderers":[]}"#.utf8)

    static func supplement() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "materials": [], "drawMaterials": [],
            "textures": [["bundle": "chara/mt_ramp_00.unity3d", "bundleSHA256": "rampsha", "serializedFile": "CAB-ramp", "pathID": "3",
                          "name": "ramp_tex", "filter": "Bilinear", "wrap": "Clamp", "aniso": 1, "mipLevels": 1, "width": 256, "height": 4]],
            "catalogRows": [["table": "mt_ramp", "category": 432, "id": 1, "row": ["MainTexAB": "chara/mt_ramp_00.unity3d", "MainTex": "ramp_tex"]]]])
    }
}

@Test func sourceShaderBindingDerivationAppliesPrefabDefaultsAndCardSettersWithoutACapture() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try DerivationFixture.library(directory: directory)
    let card = try AppearanceTestFixture.card()
    let catalog = try DerivationFixture.catalog()
    let bindings = try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: DerivationFixture.headContract, catalog: catalog)
    let hair = try #require(bindings.renderers.first { $0.mesh == "o_hair" })
    #expect(hair.visible && hair.materialSlot == 0 && hair.component == "hair.0 101:2")
    let material = hair.material
    #expect(material.shader == DerivationFixture.hairShader && material.queue == 2850 && material.queueSource == "shader QUEUE tag Transparent-150")
    #expect(material.keywords == ["_A", "_B"] && material.keywordsSource.contains("Maker library material tree"))
    #expect(material.passStates?.keys.sorted() == ["FORWARD", "OUTLINE"])
    #expect(material.passStates?["OUTLINE"] == ["zTest": 4, "stencilComp": 8, "srcBlend": 1])
    // The card colour (alpha 0.8) is raised to 1 by ChangeSettingHairColor.
    #expect(material.vectors["_Color"]?.values == [0.25, 0.5, 0.75, 1])
    #expect(material.vectors["_Color"]?.source.contains("ChangeSettingHairColor") == true)
    #expect(material.vectors["_LineColor"]?.unresolved == "card field hair.parts.0.outlineColor missing")
    #expect(material.vectors["_Cutoff"]?.values == [0.25] && material.vectors["_Cutoff"]?.source == "prefab m_Floats")
    #expect(material.vectors["_ShadowExtend"]?.values == [1] && material.vectors["_ShadowExtend"]?.source == "shader default (not saved)")
    let mask = try #require(material.textures["_ColorMask"])
    #expect(mask.identity?.name == "mask" && mask.identity?.pathID == "5" && mask.identity?.bundle == "chara/test_hair.unity3d")
    #expect(mask.offset == [0.5, 0] && mask.identity?.filter == nil)
    #expect(material.textures["_AnotherRamp"].map { $0.identity == nil && $0.identityUnresolved == nil && $0.scale == [1, 1] } == true)
    let gloss = try #require(material.textures["_HairGloss"])
    #expect(gloss.identityUnresolved == "card field hair.glossId missing" && gloss.offset == [-0.06, 0.02])
    let body = try #require(bindings.renderers.first { $0.mesh == "o_body_a" })
    #expect(body.material.unresolved?.contains("cf_m_body draw material is not converted") == true)
    #expect(body.material.textures["_MainTex"]?.identity.map { $0.kind == .runtimeComposite && $0.width == 2048 && $0.wrap == "Clamp" && $0.mipLevels == 12 } == true)
    #expect(bindings.globalVectors["_LineColorG"]?.values == [0.5, 0.5, 0.5, 0] && bindings.globalVectors["_Time"]?.unresolved != nil)
    #expect(bindings.globalTextures["_RampG"]?.identityUnresolved?.contains("mt_ramp catalog row ID 1 is not converted") == true)
    #expect(bindings.diagnostics.contains { $0.hasPrefix("No source binding supplement") })
    #expect(bindings.provenance["cardSHA256"] == card.sourceSHA256 && bindings.provenance["supplementSHA256"] == nil)

    // The supplement adds the ramp row and its sampler state; another ramp ID
    // (a scene-input mutation) is reported as missing, not substituted.
    let supplement = try DerivationFixture.supplement()
    let supplemented = try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: DerivationFixture.headContract,
                                                                 catalog: catalog, supplement: supplement)
    let ramp = try #require(supplemented.globalTextures["_RampG"]?.identity)
    #expect(ramp.name == "ramp_tex" && ramp.pathID == "3" && ramp.wrap == "Clamp" && ramp.bundleSHA256 == "rampsha")
    #expect(supplemented.provenance["supplementSHA256"] == SHA256.hash(data: supplement).map { String(format: "%02x", $0) }.joined())
    var scene = SourceShaderBindingDerivation.SceneGlobals.originalCharacterProbeHarness; scene.rampID = 2
    let other = try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: DerivationFixture.headContract,
                                                          catalog: catalog, supplement: supplement, scene: scene)
    #expect(other.globalTextures["_RampG"]?.identity == nil && other.globalTextures["_RampG"]?.identityUnresolved?.contains("ID 2") == true)
    #expect(try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: DerivationFixture.headContract,
                                                     catalog: catalog, hiPoly: false).renderers.first { $0.mesh == "o_body_a" }?
        .material.textures["_MainTex"]?.identity?.width == 512)
}

// Real BinaryWriter/MessagePack framing with synthetic catalog and material
// metadata. No original texture bytes or translated program are embedded.
private enum FaceCompositeFixture {
    typealias F = OriginalCardFixture
    typealias Row = [String: Any]
    typealias Fields = [(String, F.Value)]
    static let baseSHA = "3944a1d7a9e446f15714bcca0b2faebd7b760fdc010139fad677ce24c422175e"
    static let headSHA = "e6ded0a39b1ca521648597d31d9f868fe354963279a8ccf4140212598289cf7e"
    static let programHash = "9ec842e7b29577b0fd4ddb8ffcfc25c288471210b90ab7a312c3e7a9225df72c"
    static let cheekSHA = "d21eeb93b6737b897f916a46fb12fa9c56642986d9c886ab2b5b1123d7e9e6b7"
    static let tableSHA = "5fe4e6811dc6d2e6edd0153cd73f989991c18573c654e1cbeafec821744a0ded"
    static func vector(_ values: [Double]) -> F.Value { .array(values.map(F.Value.float)) }
    static func record(_ defaults: Fields, _ overrides: Fields) -> F.Value {
        let keys = Set(overrides.map(\.0))
        return F.map(defaults.filter { !keys.contains($0.0) } + overrides)
    }
    static func makeup(coordinate: Bool, overrides: Fields = []) -> F.Value {
        let colors: [F.Value] = coordinate
            ? [vector([0.8, 0.7, 0.6, 0.5]), vector([0.6, 0.5, 0.4, 0.3])]
            : [vector([0.1, 0.2, 0.3, 0.4]), vector([0.2, 0.3, 0.4, 0.5])]
        let layouts: [F.Value] = coordinate
            ? [vector([0.5, 0.5, 0.5, 0]), vector([0, 0, 0, 1])]
            : [vector([-1, 2, 0, 0.5]), vector([0.75, 0.25, 1, 1])]
        let fields: Fields = [("version", .string("0.0.0")), ("paintId", .array([.integer(0), .integer(0)])),
            ("paintColor", .array(colors)), ("paintLayout", .array(layouts)),
            ("cheekId", .integer(0)), ("cheekColor", vector(coordinate ? [0.9, 0.8, 0.7, 0.6] : [0.3, 0.4, 0.5, 0.6]))]
        return record(fields, overrides)
    }
    static func card(coordinate: Bool = false, baseOverrides: Fields = [], coordinateOverrides: Fields = [],
                     faceOverrides: Fields = [], bodyOverrides: Fields = [], sex: Int64 = 1, exType: Int64 = 0,
                     modProperty: String? = nil, coordinateFlag: UInt8? = nil) throws -> SourceCharacterCard {
        let faceFields: Fields = [("version", .string("0.0.2")), ("headId", .integer(0)),
            ("shapeValueFace", .array(F.faceValues)), ("baseMakeup", makeup(coordinate: false, overrides: baseOverrides)),
            ("lipLineId", .integer(0)), ("lipLineColor", vector([0.4, 0.5, 0.6, 0.7])),
            ("moleId", .integer(0)), ("moleColor", vector([0.5, 0.6, 0.7, 0.8])), ("moleLayout", vector([0.25, 0.75, 0.9, 0.5]))]
        let bodyFields: Fields = [("version", .string("0.0.2")), ("shapeValueBody", .array(F.bodyValues)),
            ("skinMainColor", vector([0.25, 0.5, 0.75, 1])), ("skinSubColor", vector([0.75, 0.5, 0.25, 1]))]
        let hair = F.pack(F.map([("version", .string("0.0.4")), ("parts", .array([]))]))
        let custom = F.lengthData(F.pack(record(faceFields, faceOverrides)))
            + F.lengthData(F.pack(record(bodyFields, bodyOverrides))) + F.lengthData(hair)
        let clothes = F.pack(F.map([("version", .string("0.0.1")), ("parts", .array([]))]))
        let accessory = F.pack(F.map([("version", .string("0.0.2")), ("parts", .array([]))]))
        let outfit = F.lengthData(clothes) + F.lengthData(accessory) + Data([coordinateFlag ?? (coordinate ? 1 : 0)])
            + F.lengthData(F.pack(makeup(coordinate: true, overrides: coordinateOverrides)))
        var blocks = F.blocks(custom: custom, sex: .integer(sex))
        let parameter = F.map([("version", .string("0.0.5")), ("sex", .integer(sex)), ("exType", .integer(exType))])
        blocks[1].data = F.pack(parameter)
        blocks.append(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array([.binary(outfit)]))))
        if let modProperty {
            let info = F.pack(F.map([("ModID", .string("synthetic.mod")), ("Property", .string(modProperty)), ("Slot", .integer(0))]))
            let plugin = F.plugin(0, data: F.map([("info", .array([.binary(info)]))]))
            blocks.append(F.extended(F.map([("com.bepis.sideloader.universalautoresolver", plugin)])))
        }
        return try SourceCharacterCard.decode(F.card(blocks: blocks))
    }
    static func head() -> Row {
        let bundle = "chara/bo_head_00.unity3d", base = "chara/mm_base.unity3d"
        let headRow: [String: String] = ["MainManifest": "abdata", "MainAB": bundle, "MainData": "p_cf_head_00",
            "MatManifest": "abdata", "MatAB": bundle, "MatData": "cf_m_face_00", "MainTexAB": bundle, "MainTex": "cf_face_00_t", "ColorMaskAB": bundle, "ColorMaskTex": "cf_face_00_mc"]
        var rows: [Row] = [["table": "bo_head", "category": 100, "selectedID": 0, "row": headRow]]
        for (category, table, key) in [(405, "mt_face_paint", "PaintTex"), (402, "mt_cheek", "CheekTex"),
                                       (404, "mt_lipline", "LiplineTex"), (415, "mt_mole", "MoleTex")] {
            rows.append(["table": table, "category": category, "selectedID": 0, "row": ["MainAB": "0", key: "0"]])
        }
        let draw: Row = ["name": "cf_m_face_00", "shader": "Shader Forge/main_skin", "serializedFile": "CAB-b45f3dc6094104fda1eb384293a73f74", "pathID": "10",
                         "renderQueue": -1, "passes": [], "floats": [:], "colors": [:], "textures": [:]]
        let paint: Row = ["serializedFile": "CAB-0d1f3d8317188244dde38c81a889d1d4", "pathID": "4688923211121552405", "name": "cf_face_00_mp"]
        var environments: Row = [:]
        for name in ["_MainTex", "_ColorMask", "_Texture3", "_Texture4", "_Texture5", "_Texture6", "_Texture7", "_paintmask"] {
            environments[name] = ["texture": name == "_paintmask" ? paint : NSNull(), "scale": [2, 3], "offset": [0.125, 0.25]] as Row
        }
        var creator = draw
        creator["name"] = "cf_m_face_create"; creator["shader"] = "Shader Forge/create_head"
        creator["serializedFile"] = "CAB-0d1f3d8317188244dde38c81a889d1d4"; creator["pathID"] = "4119387422725910578"; creator["textures"] = environments
        creator["colors"] = ["_Color": [1, 1, 1, 1], "_UnusedAuthored": [0.1, 0.2, 0.3, 0.4],
                             "_tex4uv": [0.5, 0.6399999856948853, -0.33000001311302185, -4]]
        let textures: [Row] = [("cf_face_00_t", bundle, "CAB-b45f3dc6094104fda1eb384293a73f74", "4156981771398184683"), ("cf_face_00_mc", bundle, "CAB-b45f3dc6094104fda1eb384293a73f74", "5632470389437020241"),
                               ("cf_face_00_mp", base, "CAB-0d1f3d8317188244dde38c81a889d1d4", "4688923211121552405")].map { name, bundle, file, id in
            ["name": name, "bundle": bundle, "serializedFile": file, "pathID": id, "width": 1024, "height": 1024]
        }
        let renderer: Row = ["nodeName": "cf_O_face", "activeSelf": true, "enabled": true,
            "materialSlots": [["name": "cf_m_face_00", "pathID": "10"]], "draws": [["materialSlot": 0, "submesh": 0]]]
        return ["sources": [["path": "/abdata/" + bundle, "sha256": headSHA], ["path": "/abdata/" + base, "sha256": baseSHA]],
            "catalogRows": rows, "textures": textures, "drawMaterials": [draw], "renderers": [renderer], "createMaterials": [creator],
            "verifiedCreateShaders": [["shader": "Shader Forge/create_head", "programSHA256": programHash]]]
    }
    static func cheekHead() -> Row {
        var result = head()
        var rows = result["catalogRows"] as! [Row]
        rows.append(["table": "mt_cheek_00", "category": 402, "selectedID": 1,
                     "serializedFile": "CAB-f743f6c65c10409f82c314d690dc0d13", "pathID": "-3938298771551138771",
                     "row": ["MainAB": "chara/mt_cheek_00.unity3d", "CheekTex": "cw_t_cheek_000"]])
        result["catalogRows"] = rows
        var textures = result["textures"] as! [Row]
        textures.append(["name": "cw_t_cheek_000", "bundle": "chara/mt_cheek_00.unity3d",
                         "serializedFile": "CAB-649019955dc8e0979dde865205c4d875", "pathID": "163309903755191522",
                         "width": 832, "height": 312, "format": 4, "serializedColorSpace": 1, "mipLevels": 1,
                         "filter": "Bilinear", "wrap": "Clamp", "aniso": 1])
        result["textures"] = textures
        var sources = result["sources"] as! [Row]
        sources.append(["path": "/abdata/chara/mt_cheek_00.unity3d", "sha256": cheekSHA])
        sources.append(["path": "/abdata/list/characustom/00.unity3d", "sha256": tableSHA])
        result["sources"] = sources
        return result
    }
    static func derive(directory: URL, card: SourceCharacterCard? = nil, head: Row? = nil, hiPoly: Bool = true,
                       supplement: Row? = nil) throws -> SourceShaderBindingSet.TextureIdentity? {
        let url = directory.appendingPathComponent("empty-library.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": []]).write(to: url)
        let descriptor = try ShaderBindingFixture.program(shader: "Shader Forge/main_skin", pass: "FORWARD",
            properties: [ShaderBindingFixture.property("_MainTex", type: 4)], vertex: [], fragment: [], textures: ["_MainTex"])
        let contract = try SourceShaderProgramContract.decode(descriptor, program: "main_skin")
        let bindings = try SourceShaderBindingDerivation.derive(card: card ?? self.card(), library: .load(url: url),
            headContract: JSONSerialization.data(withJSONObject: head ?? self.head()),
            catalog: .init(programs: ["Shader Forge/main_skin": [contract]]),
            supplement: try supplement.map { try JSONSerialization.data(withJSONObject: $0) }, hiPoly: hiPoly)
        return bindings.renderers.first { $0.mesh == "cf_O_face" }?.material.textures["_MainTex"]?.identity
    }
}

@Test func sourceShaderFaceCompositePreservesIdentityDefaultsAndLiteralSetters() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try #require(try F.derive(directory: directory)), recipe = try #require(identity.composite)
    #expect(identity.kind == .runtimeComposite && identity.width == 1024 && identity.height == 1024 && identity.mipLevels == 11)
    #expect(identity.filter == "Bilinear" && identity.wrap == "Clamp" && identity.aniso == 1)
    #expect(recipe.unresolved == nil && recipe.programSHA256 == F.programHash && recipe.pathID == "4119387422725910578" && recipe.bundleSHA256 == F.baseSHA)
    for (property, name, id, file, hash) in [("_MainTex", "cf_face_00_t", "4156981771398184683", "CAB-b45f3dc6094104fda1eb384293a73f74", F.headSHA),
        ("_ColorMask", "cf_face_00_mc", "5632470389437020241", "CAB-b45f3dc6094104fda1eb384293a73f74", F.headSHA), ("_paintmask", "cf_face_00_mp", "4688923211121552405", "CAB-0d1f3d8317188244dde38c81a889d1d4", F.baseSHA)] {
        let input = try #require(recipe.textures[property]?.identity)
        #expect(input.name == name && input.pathID == id && input.serializedFile == file && input.bundleSHA256 == hash)
    }
    for property in ["_MainTex", "_ColorMask", "_paintmask", "_Texture3", "_Texture4", "_Texture5", "_Texture6", "_Texture7"] {
        #expect(recipe.textures[property]?.scale == [2, 3] && recipe.textures[property]?.offset == [0.125, 0.25])
    }
    for property in ["_Texture3", "_Texture4", "_Texture5", "_Texture6", "_Texture7"] {
        #expect(recipe.textures[property]?.identity == nil && recipe.textures[property]?.identityUnresolved == nil)
        #expect(recipe.textures[property]?.identitySource.contains("Unity default") == true)
    }
    let expected: [String: [Float]] = ["_Color": [0.25, 0.5, 0.75, 1], "_Color2": [0.75, 0.5, 0.25, 1],
        "_Color3": [0.1, 0.2, 0.3, 0.4], "_Color7": [0.2, 0.3, 0.4, 0.5], "_Color4": [0.3, 0.4, 0.5, 0.6],
        "_Color5": [0.4, 0.5, 0.6, 0.7], "_Color6": [0.5, 0.6, 0.7, 0.8], "_UnusedAuthored": [0.1, 0.2, 0.3, 0.4]]
    for (property, values) in expected { #expect(recipe.vectors[property]?.values == values) }
    // Literal source-transform expectations, including clamp endpoints. The
    // unused mole rotation must be zero even though its saved value is 0.9.
    for (property, values): (String, [Float]) in [("_paint1", [0.25, -0.3, 1, -3.65]), ("_paint2", [-0.125, 0.15, -1, 0.7]), ("_hokuro", [0.125, -0.15, 0, 0.35])] {
        let actual = try #require(recipe.vectors[property]?.values)
        #expect(zip(actual, values).allSatisfy { abs($0 - $1) < 0.000002 })
    }
}

@Test func sourceShaderFaceCompositeUsesTheRawCoordinateFlagAndOnlyTheSelectedRecord() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let base = try #require(try F.derive(directory: directory, card: F.card(coordinateOverrides: [("version", .string("99"))]))?.composite)
    #expect(base.unresolved == nil && base.vectors["_Color3"]?.values == [0.1, 0.2, 0.3, 0.4])
    let coordinate = try #require(try F.derive(directory: directory, card: F.card(coordinate: true, baseOverrides: [("paintId", .array([.integer(42), .integer(43)]))]))?.composite)
    #expect(coordinate.unresolved == nil && coordinate.vectors["_Color3"]?.values == [0.8, 0.7, 0.6, 0.5])
    #expect(coordinate.vectors["_Color7"]?.values == [0.6, 0.5, 0.4, 0.3] && coordinate.vectors["_Color4"]?.values == [0.9, 0.8, 0.7, 0.6])
    #expect(coordinate.vectors["_paint1"]?.values == [0, 0, 0, -8])
    #expect(coordinate.vectors["_Color3"]?.source.contains("coordinate makeup") == true)
    for selected in [false, true] {
        let missing: F.Fields = [("paintColor", .array([]))]
        let card = try F.card(coordinate: selected, baseOverrides: selected ? [] : missing, coordinateOverrides: selected ? missing : [])
        let recipe = try #require(try F.derive(directory: directory, card: card)?.composite)
        #expect(recipe.vectors["_Color3"]?.values == nil && recipe.vectors["_Color3"]?.unresolved?.contains("makeup.paintColor.0") == true)
    }
}

@Test func sourceShaderFaceCompositeRejectsUnsupportedSelectionsAndInvalidValues() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    for fields: F.Fields in [[("paintId", .array([.integer(1), .integer(0)]))], [("paintId", .array([.integer(0), .integer(2)]))], [("cheekId", .integer(3))], [("version", .string("99"))]] {
        let recipe = try #require(try F.derive(directory: directory, card: F.card(baseOverrides: fields))?.composite)
        #expect(recipe.unresolved != nil)
    }
    for fields: F.Fields in [[("lipLineId", .integer(4))], [("moleId", .integer(5))]] {
        #expect(try F.derive(directory: directory, card: F.card(faceOverrides: fields))?.composite?.unresolved != nil)
    }
    #expect(try F.derive(directory: directory, card: F.card(sex: 0))?.composite?.unresolved != nil)
    #expect(try F.derive(directory: directory, card: F.card(exType: 1))?.composite?.unresolved != nil)
    #expect(try F.derive(directory: directory, hiPoly: false)?.composite?.unresolved != nil)
    #expect(try F.derive(directory: directory, card: F.card(faceOverrides: [("headId", .integer(1))])) == nil)
    for invalid in [F.vector([0, .nan, 0, 1]), F.vector([0, .infinity, 0, 1]), F.vector([0, 0, 0])] {
        let card = try F.card(baseOverrides: [("paintLayout", .array([invalid, F.vector([0, 0, 0, 1])]))], bodyOverrides: [("skinMainColor", invalid)])
        let recipe = try #require(try F.derive(directory: directory, card: card)?.composite)
        #expect(recipe.vectors["_Color"]?.values == nil && recipe.vectors["_Color"]?.unresolved != nil)
        #expect(recipe.vectors["_paint1"]?.values == nil && recipe.vectors["_paint1"]?.unresolved != nil)
    }
}

@Test func sourceShaderFaceCompositeRequiresVerifiedCatalogProgramAndAuthoredPaintmask() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    var cases: [F.Row] = []
    var head = F.head(); head["verifiedCreateShaders"] = []; cases.append(head)
    head = F.head(); head["verifiedCreateShaders"] = [["shader": "Shader Forge/create_head", "programSHA256": String(repeating: "a", count: 64)]]; cases.append(head)
    head = F.head(); head["createMaterials"] = []; cases.append(head)
    for field in ["serializedFile", "pathID"] {
        head = F.head()
        var creators = try #require(head["createMaterials"] as? [F.Row])
        creators[0][field] = "unverified-but-same-name"; head["createMaterials"] = creators; cases.append(head)
    }
    for index in 0..<2 {
        head = F.head()
        var sources = try #require(head["sources"] as? [F.Row])
        sources[index]["sha256"] = String(repeating: "a", count: 64); head["sources"] = sources; cases.append(head)
    }
    for index in 0..<3 {
        head = F.head()
        var textures = try #require(head["textures"] as? [F.Row])
        textures[index]["pathID"] = "100"; head["textures"] = textures
        if index == 2 {
            // Keep the altered reference internally consistent so a missing
            // reference cannot conceal failure to enforce the accepted ID.
            var creators = try #require(head["createMaterials"] as? [F.Row])
            var environments = try #require(creators[0]["textures"] as? F.Row)
            var environment = try #require(environments["_paintmask"] as? F.Row)
            var reference = try #require(environment["texture"] as? F.Row)
            reference["pathID"] = "100"; environment["texture"] = reference
            environments["_paintmask"] = environment; creators[0]["textures"] = environments; head["createMaterials"] = creators
        }
        cases.append(head)
    }
    for category in [100, 405, 402, 404, 415] {
        head = F.head()
        var rows = try #require(head["catalogRows"] as? [F.Row])
        rows.removeAll { ($0["category"] as? Int) == category }; head["catalogRows"] = rows; cases.append(head)
    }
    head = F.head()
    var creators = try #require(head["createMaterials"] as? [F.Row])
    var textures = try #require(creators[0]["textures"] as? F.Row); textures.removeValue(forKey: "_paintmask")
    creators[0]["textures"] = textures; head["createMaterials"] = creators; cases.append(head)
    for head in cases { #expect(try F.derive(directory: directory, head: head)?.composite?.unresolved != nil) }
    // A more specific clone/program failure survives later scope rejection.
    head = F.head(); head["createMaterials"] = []
    let reason = try F.derive(directory: directory, head: head, hiPoly: false)?.composite?.unresolved
    #expect(reason?.contains("create material cf_m_face_create is not in") == true)
}

@Test func sourceShaderFaceCompositeDoesNotAliasResolverBackedInputsToVanillaZero() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    for property in ["ChaFileFace.headId", "ChaFileFace.lipLineId", "ChaFileFace.moleId", "ChaFileMakeup.PaintID1", "ChaFileMakeup.PaintID2", "ChaFileMakeup.cheekId"] {
        let recipe = try #require(try F.derive(directory: directory, card: F.card(modProperty: property))?.composite)
        #expect(recipe.unresolved?.contains("resolver-backed") == true)
    }
    // UAR's ChaFileMakeup destinations address baseMakeup, not coordinate makeup.
    let recipe = try #require(try F.derive(directory: directory, card: F.card(coordinate: true, modProperty: "ChaFileMakeup.PaintID1"))?.composite)
    #expect(recipe.unresolved == nil)
}

@Test func sourceShaderCheekCompositeKeepsZeroDefaultAndSelectedRowSeparate() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let old = try F.derive(directory: directory)
    #expect(try F.derive(directory: directory, head: F.cheekHead()) == old)
    let card = try F.card(baseOverrides: [("cheekId", .integer(1))])
    let recipe = try #require(try F.derive(directory: directory, card: card, head: F.cheekHead())?.composite)
    let input = try #require(recipe.textures["_Texture4"]?.identity)
    #expect(recipe.unresolved == nil && input.bundleSHA256 == F.cheekSHA)
    #expect(input.name == "cw_t_cheek_000" && input.pathID == "163309903755191522")
    #expect(input.width == 832 && input.height == 312 && input.mipLevels == 1)
    #expect(input.filter == "Bilinear" && input.wrap == "Clamp" && input.aniso == 1)
    #expect(recipe.vectors["_Color4"]?.values == [0.3, 0.4, 0.5, 0.6])
    #expect(recipe.vectors["_tex4uv"]?.values == [0.5, 0.64, -0.33, -4])
    // SetTexture changes only the binding: authored UV transforms survive.
    #expect(recipe.textures["_Texture4"]?.scale == [2, 3] && recipe.textures["_Texture4"]?.offset == [0.125, 0.25])
    for id: Int64 in [2, 3] {
        #expect(try F.derive(directory: directory, card: F.card(baseOverrides: [("cheekId", .integer(id))]), head: F.cheekHead())?.composite?.unresolved != nil)
    }
    // Existing first matching category/ID wins, including additive rows.
    var head = F.cheekHead()
    var rows = try #require(head["catalogRows"] as? [F.Row])
    var duplicate = try #require(rows.last)
    duplicate["row"] = ["MainAB": "unverified", "CheekTex": "unverified"]
    rows.append(duplicate); head["catalogRows"] = rows
    #expect(try F.derive(directory: directory, card: card, head: head)?.composite == recipe)
    rows.insert(duplicate, at: 0); head["catalogRows"] = rows
    #expect(try F.derive(directory: directory, card: card, head: head)?.composite?.unresolved != nil)
}

@Test func sourceShaderCheekCompositeIgnoresInactiveRecordAndUsesRawEnableByte() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let active: F.Fields = [("cheekId", .integer(1)), ("cheekColor", F.vector([0.2, 0.65, 0.9, 0.75]))]
    let inactive: F.Fields = [("cheekId", .integer(3)), ("cheekColor", F.vector([0.7, 0.1, 0.8, 0.9])), ("version", .string("unsupported"))]
    for flag: UInt8 in [0, 1, 2, 255] {
        let base = flag == 0 ? active : [], coordinate = flag == 0 ? [] : active
        let initial = try F.card(baseOverrides: base, coordinateOverrides: coordinate, coordinateFlag: flag)
        let edited = try F.card(baseOverrides: flag == 0 ? active : inactive,
                                coordinateOverrides: flag == 0 ? inactive : active, coordinateFlag: flag)
        let expected = try #require(try F.derive(directory: directory, card: initial, head: F.cheekHead())?.composite)
        #expect(expected.unresolved == nil && expected.vectors["_Color4"]?.values == [0.2, 0.65, 0.9, 0.75])
        #expect(try F.derive(directory: directory, card: edited, head: F.cheekHead())?.composite == expected)
    }
    let resolver = "ChaFileMakeup.cheekId"
    let activeResolver = try F.card(baseOverrides: active, modProperty: resolver)
    #expect(try F.derive(directory: directory, card: activeResolver, head: F.cheekHead())?.composite?.unresolved?.contains("resolver-backed") == true)
    let inactiveResolver = try F.card(coordinate: true, baseOverrides: inactive, coordinateOverrides: active, modProperty: resolver)
    #expect(try F.derive(directory: directory, card: inactiveResolver, head: F.cheekHead())?.composite?.unresolved == nil)
}

@Test func sourceShaderCheekCompositeRequiresExactMetadataAndSourceRevision() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let card = try F.card(baseOverrides: [("cheekId", .integer(1))])
    var cases: [F.Row] = [F.head()]
    let replacements: [(String, Any)] = [("name", "other"), ("bundle", "other"), ("serializedFile", "other"),
        ("pathID", "other"), ("width", 1024), ("height", 1024), ("mipLevels", 2), ("format", 3),
        ("serializedColorSpace", 0), ("filter", "Point"), ("wrap", "Repeat"), ("aniso", 2)]
    for (key, value) in replacements {
        var head = F.cheekHead(), textures = try #require(head["textures"] as? [F.Row])
        textures[textures.count - 1][key] = value; head["textures"] = textures; cases.append(head)
        textures[textures.count - 1].removeValue(forKey: key)
        // Only optional fields can be absent without failing JSON decoding.
        if ["mipLevels", "format", "serializedColorSpace", "filter", "wrap", "aniso"].contains(key) {
            head["textures"] = textures; cases.append(head)
        }
    }
    for key in ["table", "serializedFile", "pathID"] {
        var head = F.cheekHead(), rows = try #require(head["catalogRows"] as? [F.Row])
        rows[rows.count - 1][key] = "other"; head["catalogRows"] = rows; cases.append(head)
    }
    for suffix in ["chara/mt_cheek_00.unity3d", "list/characustom/00.unity3d"] {
        var head = F.cheekHead(), sources = try #require(head["sources"] as? [F.Row])
        let index = try #require(sources.firstIndex { ($0["path"] as? String)?.hasSuffix(suffix) == true })
        sources[index]["sha256"] = String(repeating: "a", count: 64); head["sources"] = sources; cases.append(head)
    }
    for head in cases { #expect(try F.derive(directory: directory, card: card, head: head)?.composite?.unresolved != nil) }
}

@Test func sourceShaderCheekMetadataDoesNotChangeOlderInputsOrOverrideSupplement() throws {
    typealias F = FaceCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    var head = F.cheekHead(), textures = try #require(head["textures"] as? [F.Row])
    for index in 0..<3 {
        textures[index]["mipLevels"] = 8; textures[index]["filter"] = "Point"
        textures[index]["wrap"] = "Mirror"; textures[index]["aniso"] = 3
    }
    head["textures"] = textures
    let oldInput = try #require(textures.first)
    let oldRow: F.Row = ["bundle": oldInput["bundle"]!, "bundleSHA256": F.headSHA,
        "serializedFile": oldInput["serializedFile"]!, "pathID": oldInput["pathID"]!, "name": oldInput["name"]!,
        "width": 1024, "height": 1024, "filter": "Bilinear", "wrap": "Clamp", "aniso": 1, "mipLevels": 11]
    let partial: F.Row = ["materials": [], "textures": [oldRow], "drawMaterials": [], "catalogRows": []]
    for supplement: F.Row? in [nil, partial] {
        // Neither direct authored _paintmask nor catalog main/mask identities
        // adopt newly decoded optional metadata outside the cheek branch.
        let expected = try F.derive(directory: directory, head: F.cheekHead(), supplement: supplement)
        #expect(try F.derive(directory: directory, head: head, supplement: supplement) == expected)
    }
    let card = try F.card(baseOverrides: [("cheekId", .integer(1))])
    let expected = try F.derive(directory: directory, card: card, head: F.cheekHead())
    let cheekInput = try #require(textures.last)
    var cheekRow = cheekInput
    cheekRow["bundleSHA256"] = F.cheekSHA
    var supplement: F.Row = ["materials": [], "textures": [cheekRow], "drawMaterials": [], "catalogRows": []]
    #expect(try F.derive(directory: directory, card: card, head: F.cheekHead(), supplement: supplement) == expected)
    for (key, value): (String, Any) in [("filter", "Point"), ("wrap", "Repeat"), ("aniso", 2), ("mipLevels", 2)] {
        var conflicting = cheekRow; conflicting[key] = value; supplement["textures"] = [conflicting]
        #expect(try F.derive(directory: directory, card: card, head: F.cheekHead(), supplement: supplement)?.composite?.unresolved != nil)
    }
}

// Synthetic card/material metadata. The source identity constants gate one
// ordinary-body revision; no original texture or shader bytes are included.
private enum BodyCompositeFixture {
    typealias F = OriginalCardFixture
    typealias Row = [String: Any]
    typealias Fields = [(String, F.Value)]
    static let baseSHA = FaceCompositeFixture.baseSHA
    static let bodySHA = "2bb9017d29b12352a859f54623728e4dea587392d3677a0a7158a7f9784fba67"
    static let baseFile = "CAB-0d1f3d8317188244dde38c81a889d1d4", bodyFile = "CAB-e7b38e3d86248bd1d2c54a91cd5fca51"
    static let programHash = "6dec09eabb8464f6b79b6a97e978631187ca77d992a99de1a6d0fd9ffc43e1c5"
    static func vector(_ values: [Double]) -> F.Value { FaceCompositeFixture.vector(values) }
    static func card(bodyOverrides: Fields = [], coordinate: Bool = false, sex: Int64 = 1,
                     exType: Int64 = 0, modProperty: String? = nil) throws -> SourceCharacterCard {
        let defaults: Fields = [("paintId", .array([.integer(0), .integer(0)])),
            ("paintLayoutId", .array([.integer(0), .integer(0)])), ("sunburnId", .integer(0)),
            ("paintColor", .array([vector([0.11, 0.22, 0.33, 0.44]), vector([0.55, 0.66, 0.77, 0.88])])),
            ("sunburnColor", vector([0.1, 0.2, 0.3, 0.4])), ("nailColor", vector([0.7, 0.8, 0.9, 1])),
            ("paintLayout", .array([vector([-1, 2, 0.25, 0.75]), vector([0.5, 0.5, 2, -1])]))]
        let keys = Set(bodyOverrides.map(\.0))
        return try FaceCompositeFixture.card(coordinate: coordinate,
            bodyOverrides: defaults.filter { !keys.contains($0.0) } + bodyOverrides,
            sex: sex, exType: exType, modProperty: modProperty)
    }
    static func draw() -> Row {
        ["name": "cf_m_body", "shader": "Shader Forge/main_skin", "serializedFile": baseFile,
         "pathID": "-8704185815755846451", "renderQueue": -1, "passes": [], "floats": [:], "colors": [:], "textures": [:]]
    }
    static func supplement() -> Row {
        ["materials": [], "textures": [], "catalogRows": [],
         "drawMaterials": [["bundle": "chara/mm_base.unity3d", "bundleSHA256": baseSHA, "material": draw()]]]
    }
    static func head() -> Row {
        let base = "chara/mm_base.unity3d", body = "chara/oo_base.unity3d"
        let paint: Row = ["serializedFile": baseFile, "pathID": "7680453631034146393", "name": "cf_body_01_mp"]
        var environments: Row = [:]
        for name in ["_MainTex", "_ColorMask", "_Texture3", "_Texture4", "_Texture6", "_paintmask"] {
            environments[name] = ["texture": name == "_paintmask" ? paint : NSNull(), "scale": [2, 3], "offset": [0.125, 0.25]] as Row
        }
        var creator = draw()
        creator["name"] = "cf_m_body_create"; creator["shader"] = "Shader Forge/create_body"
        creator["pathID"] = "-8385327033008235336"; creator["textures"] = environments
        creator["colors"] = ["_Color": [1, 1, 1, 1], "_UnusedAuthored": [0.1, 0.2, 0.3, 0.4]]
        let inputs: [(String, String, String, String, Int)] = [
            ("cf_body_00_t", body, bodyFile, "5340205562146712601", 2048),
            ("cf_body_00_mc", body, bodyFile, "-3685019629691781346", 1024),
            ("cf_body_01_mp", base, baseFile, "7680453631034146393", 1024)]
        let textures: [Row] = inputs.map { name, bundle, file, id, size in
            ["name": name, "bundle": bundle, "serializedFile": file, "pathID": id, "width": size, "height": size]
        }
        let layout: [String: String] = ["CenterX": "0.345", "MoveX": "0.085", "CenterY": "-0.365",
            "MoveY": "0.105", "CenterScale": "-5.5", "AddScale": "4.5"]
        let rows: [Row] = [
            ["table": "mt_body_paint_00", "category": 421, "selectedID": 0, "row": ["MainAB": "0", "PaintTex": "0"]],
            ["table": "mt_sunburn_00", "category": 422, "selectedID": 0, "row": ["MainAB": "0", "SunburnTex": "0"]],
            ["table": "bodypaint_layout_00", "category": 3, "selectedID": 0, "row": layout]]
        return ["sources": [["path": "/abdata/" + base, "sha256": baseSHA], ["path": "/abdata/" + body, "sha256": bodySHA]],
            "catalogRows": rows, "textures": textures, "drawMaterials": [], "renderers": [], "createMaterials": [creator],
            "verifiedCreateShaders": [["shader": "Shader Forge/create_body", "programSHA256": programHash]]]
    }
    static func derive(directory: URL, card: SourceCharacterCard? = nil, head: Row? = nil,
                       supplement: Row? = nil, hiPoly: Bool = true) throws -> SourceShaderBindingSet.TextureIdentity? {
        let url = directory.appendingPathComponent("empty-library.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": []]).write(to: url)
        let descriptor = try ShaderBindingFixture.program(shader: "Shader Forge/main_skin", pass: "FORWARD",
            properties: [ShaderBindingFixture.property("_MainTex", type: 4)], vertex: [], fragment: [], textures: ["_MainTex"])
        let contract = try SourceShaderProgramContract.decode(descriptor, program: "main_skin")
        let bindings = try SourceShaderBindingDerivation.derive(card: card ?? self.card(), library: .load(url: url),
            headContract: JSONSerialization.data(withJSONObject: head ?? self.head()),
            catalog: .init(programs: ["Shader Forge/main_skin": [contract]]),
            supplement: JSONSerialization.data(withJSONObject: supplement ?? self.supplement()), hiPoly: hiPoly)
        return bindings.renderers.first { $0.mesh == "o_body_a" }?.material.textures["_MainTex"]?.identity
    }
}

@Test func sourceShaderBodyCompositePreservesIdentityDimensionsDefaultsAndLiteralSetters() throws {
    typealias B = BodyCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try #require(try B.derive(directory: directory)), recipe = try #require(identity.composite)
    #expect(identity.kind == .runtimeComposite && identity.width == 2048 && identity.height == 2048 && identity.mipLevels == 12)
    #expect(identity.filter == "Bilinear" && identity.wrap == "Clamp" && identity.aniso == 1)
    #expect(recipe.unresolved == nil && recipe.programSHA256 == B.programHash && recipe.pathID == "-8385327033008235336")
    #expect(recipe.textures["_MainTex"]?.identity?.width == 2048 && recipe.textures["_ColorMask"]?.identity?.width == 1024)
    #expect(recipe.textures["_MainTex"]?.identity?.bundleSHA256 == B.bodySHA)
    #expect(recipe.textures["_paintmask"]?.identity?.pathID == "7680453631034146393")
    for property in ["_MainTex", "_ColorMask", "_paintmask", "_Texture3", "_Texture4", "_Texture6"] {
        #expect(recipe.textures[property]?.scale == [2, 3] && recipe.textures[property]?.offset == [0.125, 0.25])
    }
    // Keep distinct null bindings so the program supplies black paint and
    // white sunburn defaults. The recipe must not synthesize one shared input.
    for property in ["_Texture3", "_Texture4", "_Texture6"] {
        #expect(recipe.textures[property]?.identity == nil && recipe.textures[property]?.identityUnresolved == nil)
        #expect(recipe.textures[property]?.identitySource.contains("Unity default") == true)
    }
    let expected: [String: [Float]] = ["_Color": [0.25, 0.5, 0.75, 1], "_Color2": [0.75, 0.5, 0.25, 1],
        "_Color3": [0.11, 0.22, 0.33, 0.44], "_Color6": [0.55, 0.66, 0.77, 0.88],
        "_Color4": [0.1, 0.2, 0.3, 0.4], "_Color5": [0.7, 0.8, 0.9, 1], "_UnusedAuthored": [0.1, 0.2, 0.3, 0.4]]
    for (property, values) in expected { #expect(recipe.vectors[property]?.values == values) }
    // Independent literal catalog transform: body z is -1→1, unlike face.
    for (property, values): (String, [Float]) in [("_paint1", [0.43, -0.47, -0.5, -3.25]), ("_paint2", [0.345, -0.365, 1, -10])] {
        let actual = try #require(recipe.vectors[property]?.values)
        #expect(zip(actual, values).allSatisfy { abs($0 - $1) < 0.000002 })
    }
}

@Test func sourceShaderBodyCompositeUsesBodyFieldsIndependentlyOfCoordinateMakeupAndSkinID() throws {
    typealias B = BodyCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let base = try #require(try B.derive(directory: directory)?.composite)
    let other = try #require(try B.derive(directory: directory, card: B.card(bodyOverrides: [("skinId", .integer(72))], coordinate: true))?.composite)
    #expect(base == other)
    let changed = try #require(try B.derive(directory: directory, card: B.card(bodyOverrides: [("nailColor", B.vector([0.17, 0.76, 0.31, 1]))]))?.composite)
    #expect(changed.vectors["_Color5"]?.values == [0.17, 0.76, 0.31, 1])
    #expect(changed.vectors["_Color3"] == base.vectors["_Color3"] && changed.textures == base.textures)
}

@Test func sourceShaderBodyCompositeRejectsUnsupportedSelectionsAndMalformedValues() throws {
    typealias B = BodyCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let cases: [B.Fields] = [[("paintId", .array([.integer(1), .integer(0)]))], [("paintId", .array([.integer(0), .integer(2)]))],
        [("sunburnId", .integer(3))], [("paintLayoutId", .array([.integer(0), .integer(1)]))], [("version", .string("99"))]]
    for fields in cases { #expect(try B.derive(directory: directory, card: B.card(bodyOverrides: fields))?.composite?.unresolved != nil) }
    #expect(try B.derive(directory: directory, card: B.card(sex: 0))?.composite?.unresolved != nil)
    #expect(try B.derive(directory: directory, card: B.card(exType: 1))?.composite?.unresolved != nil)
    #expect(try B.derive(directory: directory, hiPoly: false)?.composite?.unresolved != nil)
    for invalid in [B.vector([0, .nan, 0, 1]), B.vector([0, .infinity, 0, 1]), B.vector([0, 0, 0])] {
        let card = try B.card(bodyOverrides: [("nailColor", invalid), ("skinMainColor", invalid),
            ("paintLayout", .array([invalid, B.vector([0, 0, 0, 1])]))])
        let recipe = try #require(try B.derive(directory: directory, card: card)?.composite)
        for property in ["_Color", "_Color5", "_paint1"] {
            #expect(recipe.vectors[property]?.values == nil && recipe.vectors[property]?.unresolved != nil)
        }
    }
}

@Test func sourceShaderBodyCompositeRequiresExactCreatorDrawInputsAndLayoutCatalog() throws {
    typealias B = BodyCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    var cases: [B.Row] = []
    var head = B.head(); head["createMaterials"] = []; cases.append(head)
    head = B.head(); head["verifiedCreateShaders"] = []; cases.append(head)
    for index in 0..<2 {
        head = B.head(); var sources = try #require(head["sources"] as? [B.Row])
        sources[index]["sha256"] = String(repeating: "a", count: 64); head["sources"] = sources; cases.append(head)
    }
    for property in ["pathID", "serializedFile"] {
        head = B.head(); var creators = try #require(head["createMaterials"] as? [B.Row])
        creators[0][property] = "unverified"; head["createMaterials"] = creators; cases.append(head)
        var supplement = B.supplement(); var draws = try #require(supplement["drawMaterials"] as? [B.Row])
        var draw = try #require(draws[0]["material"] as? B.Row); draw[property] = "unverified"
        draws[0]["material"] = draw; supplement["drawMaterials"] = draws
        #expect(try B.derive(directory: directory, supplement: supplement)?.composite?.unresolved != nil)
    }
    for index in 0..<3 {
        head = B.head(); var textures = try #require(head["textures"] as? [B.Row])
        textures[index]["width"] = 512; head["textures"] = textures; cases.append(head)
    }
    for category in [3, 421, 422] {
        head = B.head(); var rows = try #require(head["catalogRows"] as? [B.Row])
        rows.removeAll { ($0["category"] as? Int) == category }; head["catalogRows"] = rows; cases.append(head)
    }
    for value in ["nan", "inf", "0.3"] {
        head = B.head(); var rows = try #require(head["catalogRows"] as? [B.Row])
        var row = try #require(rows[2]["row"] as? [String: String]); row["CenterX"] = value
        rows[2]["row"] = row; head["catalogRows"] = rows; cases.append(head)
    }
    for head in cases { #expect(try B.derive(directory: directory, head: head)?.composite?.unresolved != nil) }
}

@Test func sourceShaderBodyCompositeRejectsResolverAliasesOnlyForItsInputs() throws {
    typealias B = BodyCompositeFixture
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    for property in ["ChaFileBody.PaintID1", "ChaFileBody.PaintID2", "ChaFileBody.PaintLayoutID1", "ChaFileBody.PaintLayoutID2", "ChaFileBody.sunburnId"] {
        let recipe = try #require(try B.derive(directory: directory, card: B.card(modProperty: property))?.composite)
        #expect(recipe.unresolved?.contains("resolver-backed") == true)
    }
    #expect(try B.derive(directory: directory, card: B.card(modProperty: "ChaFileMakeup.PaintID1"))?.composite?.unresolved == nil)
}

// Normal clothes are deliberately synthetic: a non-square source texture,
// non-default TexEnv and three distinct colours expose size/identity/setter
// mixups without depending on the private converted library.
private enum NormalClothesCompositeFixture {
    typealias F = OriginalCardFixture
    static func derive(directory: URL, pattern: Int = 0, patternRow: Bool = true,
                       mask: Bool = true, provenProgram: Bool = true, normalOnly: Bool = true,
                       hiPoly: Bool = true, omitColor: Bool = false, slot: Int = 0) throws -> SourceShaderBindingSet.Texture? {
        let colours = (0..<3).map { i -> F.Value in
            var fields: [(String, F.Value)] = [
                ("pattern", .integer(Int64(pattern))),
                ("patternColor", .array([.float(0.7), .float(0.6), .float(0.5), .float(1)])),
                ("tiling", .array([.float(Double(i + 2)), .float(Double(i + 3))]))]
            if !omitColor { fields.append(("baseColor", .array([.float(Double(i + 1) / 4), .float(0.5), .float(0.75), .float(0.8)]))) }
            return F.map(fields)
        }
        var parts = Array(repeating: F.map([]), count: slot == 7 ? 9 : slot + 1)
        parts[slot] = F.map([("id", .integer(38)), ("colorInfo", .array(colours))])
        if slot == 1 {
            // A valid but different top exposes any accidental parts[0]
            // lookup in the bottom recipe, including omitted bottom fields.
            let topColours: [F.Value] = (0..<3).map { i -> F.Value in
                let baseColor: [F.Value] = [.float(0.9), .float(0.1), .float(Double(i) / 8), .float(1)]
                let patternColor: [F.Value] = [.float(0.2), .float(0.3), .float(0.4), .float(0.5)]
                let tiling: [F.Value] = [.float(Double(i + 9)), .float(Double(i + 10))]
                let fields: [(String, F.Value)] = [
                    ("pattern", .integer(0)), ("baseColor", .array(baseColor)),
                    ("patternColor", .array(patternColor)), ("tiling", .array(tiling))]
                return F.map(fields)
            }
            parts[0] = F.map([("id", .integer(38)), ("colorInfo", .array(topColours))])
        }
        if slot == 7 {
            for peer in [0, 1, 8] {
                let peerColours: [F.Value] = (0..<3).map { i -> F.Value in
                    let baseColor: [F.Value] = [.float(0.9 - Double(peer) / 20), .float(0.1), .float(Double(i) / 8), .float(1)]
                    let patternColor: [F.Value] = [.float(0.2), .float(0.3), .float(0.4), .float(0.5)]
                    let tiling: [F.Value] = [.float(Double(peer + i + 9)), .float(Double(peer + i + 10))]
                    let fields: [(String, F.Value)] = [
                        ("pattern", .integer(0)), ("baseColor", .array(baseColor)),
                        ("patternColor", .array(patternColor)), ("tiling", .array(tiling))]
                    return F.map(fields)
                }
                // Slots 7 and 8 share category 112. A peer ID absent from the
                // one-row library prevents two copies of the same test mesh;
                // its saved fields still expose a wrong-slot color lookup.
                parts[peer] = F.map([("id", .integer(39)), ("colorInfo", .array(peerColours))])
            }
        }
        let clothes = F.pack(F.map([("version", .string("0.0.1")), ("parts", .array(parts))]))
        let accessory = F.pack(F.map([("version", .string("0.0.2")), ("parts", .array([]))]))
        let makeup = F.pack(F.map([("version", .string("0.0.0"))]))
        let outfit = F.lengthData(clothes) + F.lengthData(accessory) + Data([0]) + F.lengthData(makeup)
        var blocks = try AppearanceTestFixture.card().blocks.map { F.Block(name: $0.name, version: $0.version, data: $0.data) }
        blocks.append(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array([.binary(outfit)]))))
        let card = try SourceCharacterCard.decode(F.card(blocks: blocks))
        let material: [String: Any] = ["name": "m_top", "shader": ShaderBindingFixture.testShader,
            "serializedFile": "CAB-top", "pathID": "10", "renderQueue": -1,
            "passes": [], "floats": [:], "colors": [:], "textures": [:]]
        var textures: [String: Any] = ["main": ["name": "top_main", "width": 4, "height": 2]]
        if mask { textures["mask"] = ["name": "top_mask", "width": 4, "height": 2] }
        let category = min(105 + slot, 112)
        let evidence: [String: Any] = ["category": category, "id": 38,
            "source": ["bundle": "chara/top.unity3d", "bundleSHA256": "top-sha"],
            "catalog": ["MainAB": "chara/top.unity3d", "MainTexAB": "0", "MainTex": "top_main", "ColorMaskAB": "0", "ColorMaskTex": "top_mask"],
            "catalogTextures": textures,
            "componentTrees": [["rendNormal01": [["m_PathID": 3]], "rendAlpha01": normalOnly ? [] : [["m_PathID": 4]]]],
            "renderers": [["meshName": "o_top", "nodeName": "o_top", "materialSlot": 0, "material": material]]]
        let materialData = try JSONSerialization.data(withJSONObject: evidence), rig = Data("{}".utf8)
        try materialData.write(to: directory.appendingPathComponent("materials.json"))
        try rig.write(to: directory.appendingPathComponent("rig.json"))
        let entry: [String: Any] = ["category": category, "id": 38, "name": "top", "meshNames": ["o_top"],
            "rig": ["file": "rig.json", "sha256": F.hash(rig)],
            "materialEvidence": ["file": "materials.json", "sha256": F.hash(materialData)]]
        let libraryURL = directory.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [entry]]).write(to: libraryURL)
        var creator = material
        creator["name"] = "cf_m_clothesN_create"; creator["shader"] = "Shader Forge/create_topN"
        creator["pathID"] = "99"; creator["serializedFile"] = "CAB-base"
        creator["textures"] = ["_MainTex": ["texture": NSNull(), "scale": [2, 3], "offset": [0.1, 0.2]]]
        let head: [String: Any] = ["sources": [["path": "/abdata/chara/mm_base.unity3d", "sha256": "base-sha"]],
            "catalogRows": patternRow ? [["table": "mt_pattern", "category": 430, "selectedID": 0, "row": ["MainTexAB": "0", "MainTex": "0"]]] : [],
            "textures": ["top_main", "top_mask"].enumerated().map { i, name in
                ["name": name, "bundle": "chara/top.unity3d", "serializedFile": "CAB-top", "pathID": String(20 + i), "width": 4, "height": 2] as [String: Any]
            }, "drawMaterials": [], "renderers": [], "createMaterials": [creator],
            "verifiedCreateShaders": provenProgram ? [["shader": "Shader Forge/create_topN", "programSHA256": String(repeating: "a", count: 64)]] : []]
        let contract = try ShaderBindingFixture.testContract()
        let result = try SourceShaderBindingDerivation.derive(card: card, library: .load(url: libraryURL),
            headContract: JSONSerialization.data(withJSONObject: head),
            catalog: .init(programs: [ShaderBindingFixture.testShader: [contract]]), hiPoly: hiPoly)
        return result.renderers.first { $0.mesh == "o_top" }?.material.textures["_MainTex"]
    }
}

@Test func sourceShaderNormalTopCompositeKeepsSourceIdentitySizeAndAllThreeSetters() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let texture = try #require(try NormalClothesCompositeFixture.derive(directory: directory))
    let identity = try #require(texture.identity), recipe = try #require(identity.composite)
    #expect(identity.width == 4 && identity.height == 2 && identity.mipLevels == 3)
    #expect(identity.filter == "Bilinear" && identity.wrap == "Clamp" && identity.aniso == 1)
    #expect(recipe.unresolved == nil && recipe.programSHA256 == String(repeating: "a", count: 64))
    #expect(recipe.bundleSHA256 == "base-sha" && recipe.pathID == "99")
    for (name, asset, path) in [("_MainTex", "top_main", "20"), ("_ColorMask", "top_mask", "21")] {
        let input = try #require(recipe.textures[name]?.identity)
        #expect(input.name == asset && input.pathID == path && input.serializedFile == "CAB-top")
        #expect(input.bundle == "chara/top.unity3d" && input.bundleSHA256 == "top-sha")
    }
    #expect(recipe.textures["_MainTex"]?.scale == [2, 3] && recipe.textures["_MainTex"]?.offset == [0.1, 0.2])
    for i in 1...3 {
        #expect(recipe.vectors[i == 1 ? "_Color" : "_Color\(i)"]?.values == [Float(i) / 4, 0.5, 0.75, 0.8])
        #expect(recipe.vectors["_Color\(i)_2"]?.values == [0.7, 0.6, 0.5, 1])
        #expect(recipe.vectors["_PatternScale\(i)u"]?.values == [Float(i + 1)])
        #expect(recipe.vectors["_PatternScale\(i)v"]?.values == [Float(i + 2)])
        let pattern = try #require(recipe.textures["_PatternMask\(i)"])
        #expect(pattern.identity == nil && pattern.identityUnresolved == nil)
    }
}

@Test func sourceShaderNormalBottomCompositeReadsItsOwnSlotDespiteAValidTop() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let texture = try #require(try NormalClothesCompositeFixture.derive(directory: directory, slot: 1))
    let identity = try #require(texture.identity), recipe = try #require(identity.composite)
    #expect(identity.width == 4 && identity.height == 2 && identity.mipLevels == 3)
    #expect(recipe.unresolved == nil && recipe.programSHA256 == String(repeating: "a", count: 64))
    #expect(recipe.method == "ChaControl.InitBaseCustomTextureClothes(true, 1) → ChangeCustomClothes(true, 1, true, true, true, true, false)")
    #expect(recipe.textures["_MainTex"]?.identitySource.hasPrefix("bottom catalog") == true)
    #expect(recipe.textures["_ColorMask"]?.identitySource.hasPrefix("bottom catalog") == true)
    for i in 1...3 {
        let path = "clothes.parts.1.colorInfo.\(i - 1)"
        let base = try #require(recipe.vectors[i == 1 ? "_Color" : "_Color\(i)"])
        let pattern = try #require(recipe.vectors["_Color\(i)_2"])
        let u = try #require(recipe.vectors["_PatternScale\(i)u"])
        let v = try #require(recipe.vectors["_PatternScale\(i)v"])
        #expect(base.values == [Float(i) / 4, 0.5, 0.75, 0.8] && base.source.contains(path + ".baseColor"))
        #expect(pattern.values == [0.7, 0.6, 0.5, 1] && pattern.source.contains(path + ".patternColor"))
        #expect(u.values == [Float(i + 1)] && u.source.contains(path + ".tiling.0"))
        #expect(v.values == [Float(i + 2)] && v.source.contains(path + ".tiling.1"))
        #expect(recipe.textures["_PatternMask\(i)"]?.identity == nil)
        #expect(recipe.textures["_PatternMask\(i)"]?.identityUnresolved == nil)
    }
}

@Test func sourceShaderNormalInnerShoeCompositeReadsItsOwnSlotDespiteConflictingPeers() throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let texture = try #require(try NormalClothesCompositeFixture.derive(directory: directory, slot: 7))
    let identity = try #require(texture.identity), recipe = try #require(identity.composite)
    #expect(identity.width == 4 && identity.height == 2 && identity.mipLevels == 3)
    #expect(recipe.unresolved == nil && recipe.programSHA256 == String(repeating: "a", count: 64))
    #expect(recipe.method == "ChaControl.InitBaseCustomTextureClothes(true, 7) → ChangeCustomClothes(true, 7, true, true, true, true, false)")
    #expect(recipe.textures["_MainTex"]?.identitySource.hasPrefix("inner shoe catalog") == true)
    #expect(recipe.textures["_ColorMask"]?.identitySource.hasPrefix("inner shoe catalog") == true)
    for i in 1...3 {
        let path = "clothes.parts.7.colorInfo.\(i - 1)"
        let base = try #require(recipe.vectors[i == 1 ? "_Color" : "_Color\(i)"])
        let pattern = try #require(recipe.vectors["_Color\(i)_2"])
        let u = try #require(recipe.vectors["_PatternScale\(i)u"])
        let v = try #require(recipe.vectors["_PatternScale\(i)v"])
        #expect(base.values == [Float(i) / 4, 0.5, 0.75, 0.8] && base.source.contains(path + ".baseColor"))
        #expect(pattern.values == [0.7, 0.6, 0.5, 1] && pattern.source.contains(path + ".patternColor"))
        #expect(u.values == [Float(i + 1)] && u.source.contains(path + ".tiling.0"))
        #expect(v.values == [Float(i + 2)] && v.source.contains(path + ".tiling.1"))
        #expect(recipe.textures["_PatternMask\(i)"]?.identity == nil)
        #expect(recipe.textures["_PatternMask\(i)"]?.identityUnresolved == nil)
    }
    let missing = try #require(try NormalClothesCompositeFixture.derive(directory: directory, omitColor: true, slot: 7)?.identity?.composite)
    for i in 1...3 {
        let base = try #require(missing.vectors[i == 1 ? "_Color" : "_Color\(i)"])
        #expect(base.values == nil && base.unresolved?.contains("clothes.parts.7.colorInfo.\(i - 1).baseColor") == true)
    }
}

@Test(arguments: [2, 8])
func sourceShaderOtherNormalClothesSlotsRemainUncomposed(slot: Int) throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try #require(try NormalClothesCompositeFixture.derive(directory: directory, slot: slot)?.identity)
    #expect(identity.kind == .runtimeComposite && identity.composite == nil)
}

@Test(arguments: [0, 1, 7])
func sourceShaderNormalClothesCompositeLeavesUnsupportedOrMissingInputsExplicit(slot: Int) throws {
    let directory = try AppearanceTestFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try NormalClothesCompositeFixture.derive(directory: directory, pattern: 1, slot: slot)?.identity?.composite?.unresolved?.contains("mt_pattern") == true)
    #expect(try NormalClothesCompositeFixture.derive(directory: directory, patternRow: false, slot: slot)?.identity?.composite?.unresolved?.contains("mt_pattern") == true)
    #expect(try NormalClothesCompositeFixture.derive(directory: directory, mask: false, slot: slot)?.identity?.composite?.textures["_ColorMask"]?.identityUnresolved?.contains("not converted") == true)
    #expect(try NormalClothesCompositeFixture.derive(directory: directory, provenProgram: false, slot: slot)?.identity?.composite?.unresolved?.contains("not verified") == true)
    #expect(try NormalClothesCompositeFixture.derive(directory: directory, normalOnly: false, slot: slot)?.identityUnresolved?.contains("membership") == true)
    #expect(try NormalClothesCompositeFixture.derive(directory: directory, hiPoly: false, slot: slot)?.identity?.composite?.unresolved?.contains("low-detail") == true)
    #expect(try NormalClothesCompositeFixture.derive(directory: directory, omitColor: true, slot: slot)?.identity?.composite?.vectors["_Color"]?.unresolved?.contains("baseColor") == true)
}

// MARK: - Private R1 fixture

/// The controlled R1 fixture: native bindings derived from the card, Maker
/// library, head contract and supplement, compared with the original-player
/// capture `frame-mips.json` only afterwards.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_MAKER_LIBRARY", "IKKOKU_HEAD_MATERIAL_CONTRACT", "IKKOKU_SHADER_BINDING_SUPPLEMENT"]),
               "Requires IKKOKU_SHADER_BINDING_PROBE, IKKOKU_MAKER_LIBRARY, IKKOKU_HEAD_MATERIAL_CONTRACT and IKKOKU_SHADER_BINDING_SUPPLEMENT"))
func sourceShaderBindingsMatchTheControlledOriginalFrame() throws {
    let probe = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_PROBE"))
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")))
    let head = try Data(contentsOf: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_HEAD_MATERIAL_CONTRACT")))
    let supplement = try Data(contentsOf: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_SUPPLEMENT")))
    let frameData = try Data(contentsOf: probe.appendingPathComponent("frame-mips.json"))
    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    #expect(sha(frameData) == "13bd11c2805ac99172dc7ce7539c3cb98f06edcb858af4a1136ce3570b66f039")
    let card = try SourceCharacterCard.load(url: probe.appendingPathComponent("fixture-card.png"))
    let catalog = try SourceShaderProgramCatalog.load(directory: probe.appendingPathComponent("shaders"))
    let bindings = try SourceShaderBindingDerivation.derive(card: card, library: library, headContract: head, catalog: catalog, supplement: supplement)
    let comparison = try SourceShaderBindingComparison.compare(bindings: bindings, frame: frameData, catalog: catalog)
    let overall = comparison.overall
    #expect(overall.differs == 0)
    // The #102 supplement lacks the four catalog bundles behind 8 sampler
    // states; the R1 sampler-bundle supplement (2026-10-23) adds exactly those
    // bundles, copied from the original install. Either supplement is valid
    // environment input, so the pinned numbers follow which one is supplied;
    // a supplement with only some of the four is neither and fails.
    let samplerBundles = ["chara/mt_hairgloss_00.unity3d", "chara/mt_nip_00.unity3d",
                          "chara/mt_body_detail_00.unity3d", "chara/mt_ramp_00.unity3d"]
    let supplementJSON = try #require(JSONSerialization.jsonObject(with: supplement) as? [String: Any])
    let supplementSources = supplementJSON["sources"] as? [[String: Any]] ?? []
    let bundles = Set(supplementSources.compactMap { $0["bundle"] as? String })
    let samplerEvidence = samplerBundles.allSatisfy(bundles.contains)
    #expect(samplerEvidence || !samplerBundles.contains(where: bundles.contains))
    let samplers = comparison.findings.filter { $0.category == .sampler }
    // A library with the top's half-state renderer (ST-C03) binds a hidden
    // o_top_tsyats_b, which matches the capture (it draws no such renderer):
    // one more compared row, exact.
    let half = library.entries.contains { $0.category == 105 && $0.id == 38 && $0.alternates?.isEmpty == false } ? 1 : 0
    #expect(comparison.findings.filter { $0.mesh == "o_top_tsyats_b" }.map(\.status) == (half == 1 ? [.exact] : []))
    // The `cf_O_eyeline` slot beyond its single submesh is drawn and compared
    // (it was the one `extra` while the probe drew materials.prefix(submeshes)).
    if samplerEvidence {
        #expect((overall.exact, overall.withinTolerance, overall.missingNatively, overall.extra, overall.total) == (576 + half, 29, 8, 0, 613 + half))
        #expect(samplers.count == 66 && samplers.allSatisfy { $0.status == .exact })
    } else {
        #expect((overall.exact, overall.withinTolerance, overall.missingNatively, overall.extra, overall.total) == (568 + half, 29, 16, 0, 613 + half))
        #expect(samplers.filter { $0.status == .missingNatively }.count == 8)
    }
    // Every remaining gap is one of the named, unresolvable causes.
    let causes = Set(comparison.gaps.map(\.cause))
    #expect(causes.allSatisfy { (!samplerEvidence && $0.hasPrefix("sampler state")) || $0.hasPrefix("EyeLookMaterialControll") || $0.hasPrefix("frame clock")
        || $0.hasPrefix("Unity value of an unset global") })

    // With a Studio eye-look state (the exported bo_head_00 settings at the
    // resting rates and the card's pupil/highlight values) the six iris
    // transforms resolve within tolerance of the capture's ±0.02.
    if let lookPath = ProcessInfo.processInfo.environment["IKKOKU_STUDIO_LOOK_SETTINGS"] {
        let identity = try card.customization()
        let values = SourceStudioIrisRendering.cardValues(appearance: try SourceCardAppearance(card: card, coordinate: 0),
                                                          sex: identity.sex, exType: identity.exType)
        let look = try SourceStudioIrisRendering.bindingEyeLook(eyes: SourceStudioEyeMaterialSettings.document(json: Data(contentsOf: URL(fileURLWithPath: lookPath))),
                                                                card: values.values, rates: nil, source: "fixture look settings")
        let looked = try SourceShaderBindingComparison.compare(bindings: SourceShaderBindingDerivation.derive(card: card, library: library,
            headContract: head, catalog: catalog, supplement: supplement, eyeLook: look), frame: frameData, catalog: catalog).overall
        #expect((looked.exact, looked.withinTolerance, looked.differs, looked.missingNatively, looked.extra, looked.total)
                == (samplerEvidence ? (576 + half, 35, 0, 2, 0, 613 + half) : (568 + half, 35, 0, 10, 0, 613 + half)))
    }

    // Mutation control on the capture side: one hair colour lane changed.
    var frame = try #require(JSONSerialization.jsonObject(with: frameData) as? [String: Any])
    var meshes = try #require(frame["meshes"] as? [[String: Any]])
    let hairIndex = try #require(meshes.firstIndex { $0["name"] as? String == "cf_hair_b_03_00" })
    var materials = try #require(meshes[hairIndex]["materials"] as? [[String: Any]])
    var properties = try #require(materials[0]["properties"] as? [String: Any])
    var color = try #require(properties["_Color"] as? [Double]); color[0] += 0.01
    properties["_Color"] = color; materials[0]["properties"] = properties; meshes[hairIndex]["materials"] = materials; frame["meshes"] = meshes
    let mutated = try SourceShaderBindingComparison.compare(bindings: bindings, frame: JSONSerialization.data(withJSONObject: frame), catalog: catalog)
    #expect(mutated.overall.differs == 1)
    #expect(mutated.findings.first { $0.status == .differs }.map { $0.mesh == "cf_hair_b_03_00" && $0.input == "_Color" } == true)

    // Without the supplement the same derivation reports, not guesses, the gaps.
    let bare = try SourceShaderBindingComparison.compare(bindings: SourceShaderBindingDerivation.derive(card: card, library: library,
        headContract: head, catalog: catalog), frame: frameData, catalog: catalog)
    #expect((bare.overall.exact, bare.overall.withinTolerance, bare.overall.differs, bare.overall.missingNatively, bare.overall.extra) == (457 + half, 27, 2, 114, 0))
}

/// ST-C03: a library converted with half-state alternates binds the renderers
/// under n_top_b, n_bot_b and n_panst_b with the library's UpdateVisible
/// clauses, so a saved half state draws the alternate meshes live and the
/// dressed ones are switched off; dressed bytes bind as before.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_LIBRARY", "IKKOKU_MAKER_SELECTION_FIXTURES", "IKKOKU_SHADER_BINDING_PROBE", "IKKOKU_HEAD_MATERIAL_CONTRACT"]),
               "Requires IKKOKU_MAKER_LIBRARY, IKKOKU_MAKER_SELECTION_FIXTURES, IKKOKU_SHADER_BINDING_PROBE and IKKOKU_HEAD_MATERIAL_CONTRACT"))
func sourceShaderBindingsFollowTheSavedHalfStateOverAlternateRenderers() throws {
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")))
    let head = try Data(contentsOf: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_HEAD_MATERIAL_CONTRACT")))
    let probe = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SHADER_BINDING_PROBE"))
    let catalog = try SourceShaderProgramCatalog.load(directory: probe.appendingPathComponent("shaders"))
    let fixtures = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_SELECTION_FIXTURES"))
    var card = try SourceCharacterCard.load(url: fixtures.deletingLastPathComponent().appendingPathComponent("female-head0-bone0.png"))
    for (slot, id) in [(0, 38), (1, 1), (5, 1), (8, 3)] {
        card = try SourceCharacterCard.decode(card.selectingVanillaAsset(id, at: .clothes(coordinate: 0, slot: slot)))
    }
    try #require(library.entries.contains { $0.category == 105 && $0.id == 38 && $0.alternates?.isEmpty == false },
                 "IKKOKU_MAKER_LIBRARY must be a library converted with half-state alternates")
    func visible(_ state: [UInt8], shoesType: Int) throws -> [String: Bool] {
        let edited = try SourceCharacterCard.decode(card.editedData(.init(clothesState: state, shoesType: shoesType)))
        let bindings = try SourceShaderBindingDerivation.derive(card: edited, library: library, headContract: head, catalog: catalog)
        return Dictionary(bindings.renderers.filter { $0.component.hasPrefix("clothes.") }.map { ($0.mesh, $0.visible) }, uniquingKeysWith: { $0 || $1 })
    }
    let dressed = try visible([0, 0, 0, 0, 0, 0, 0, 0, 0], shoesType: 1)
    #expect(dressed["o_top_tsyats_a"] == true && dressed["o_top_tsyats_b"] == false)
    #expect(dressed["o_bot_pants01_a"] == true && dressed["o_bot_pants01_b"] == false)
    #expect(dressed["o_panst_00_a"] == true && dressed["o_panst_00_b"] == false)
    #expect(dressed["o_shoes_run01"] == true)
    let half = try visible([1, 1, 0, 0, 0, 1, 0, 0, 0], shoesType: 0)
    #expect(half["o_top_tsyats_a"] == false && half["o_top_tsyats_b"] == true)
    #expect(half["o_bot_pants01_a"] == false && half["o_bot_pants01_b"] == true)
    #expect(half["o_panst_00_a"] == false && half["o_panst_00_b"] == true)
    #expect(half["o_shoes_run01"] == false)
    let off = try visible([3, 3, 0, 0, 0, 3, 0, 0, 0], shoesType: 1)
    #expect(["o_top_tsyats_a", "o_top_tsyats_b", "o_bot_pants01_a", "o_bot_pants01_b", "o_panst_00_a", "o_panst_00_b"].allSatisfy { off[$0] == false })
}
