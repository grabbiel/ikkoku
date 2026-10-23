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
    // The `cf_O_eyeline` slot beyond its single submesh is drawn and compared
    // (it was the one `extra` while the probe drew materials.prefix(submeshes)).
    if samplerEvidence {
        #expect((overall.exact, overall.withinTolerance, overall.missingNatively, overall.extra, overall.total) == (576, 29, 8, 0, 613))
        #expect(samplers.count == 66 && samplers.allSatisfy { $0.status == .exact })
    } else {
        #expect((overall.exact, overall.withinTolerance, overall.missingNatively, overall.extra, overall.total) == (568, 29, 16, 0, 613))
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
                == (samplerEvidence ? (576, 35, 0, 2, 0, 613) : (568, 35, 0, 10, 0, 613)))
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
    #expect((bare.overall.exact, bare.overall.withinTolerance, bare.overall.differs, bare.overall.missingNatively, bare.overall.extra) == (457, 27, 2, 114, 0))
}
