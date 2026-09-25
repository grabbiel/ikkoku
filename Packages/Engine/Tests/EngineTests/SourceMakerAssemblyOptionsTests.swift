import Foundation
import Testing
import Metal
import simd
import Character
import Scene
import Renderer

private func assemblyCorrection(headY: Float = 0.25) -> Data {
    var data = Data()
    func append(_ value: UInt32) {
        var word = value.littleEndian
        withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }
    append(32)
    for index in 0..<(32 * 9) { append((index == 2 * 9 + 7 ? headY : Float.zero).bitPattern) }
    return data
}

@Test func sourceMakerBodyTypeIsCorrectionChoiceAndPreservesSex() throws {
    let normal = try SourceMakerAssemblyOptions.body(sex: 0, boneType: 0)
    #expect(normal.sex == .male)
    if case .standard = normal.boneType {} else { Issue.record("Expected the uncorrected normal body") }
    for type in [1, 2, -1, Int(Int32.max)] {
        let corrected = try SourceMakerAssemblyOptions.body(sex: 1, boneType: type, correctionData: assemblyCorrection())
        #expect(corrected.sex == .female)
        if case .corrected(let table) = corrected.boneType { #expect(table.head.scale.y == 0.25) }
        else { Issue.record("Every nonzero source type applies the same correction table") }
        #expect(SourceMakerAssemblyOptions.headColliderScale(boneType: type) == 1.08)
    }
    #expect(SourceMakerAssemblyOptions.headColliderScale(boneType: 0) == 1.2)
}

@Test func sourceMakerRejectsUnrecoveredAssembliesAndMissingOrInvalidCorrection() throws {
    for sex in [-1, 2] { #expect(throws: RigError.self) { try SourceMakerAssemblyOptions.body(sex: sex, boneType: 0) } }
    #expect(throws: RigError.self) { try SourceMakerAssemblyOptions.body(sex: 0, exType: 1, boneType: 0) }
    #expect(throws: RigError.self) { try SourceMakerAssemblyOptions.body(sex: 1, boneType: 1) }
    #expect(throws: RigError.self) { try SourceMakerAssemblyOptions.body(sex: 1, boneType: Int.max) }
    for data in [Data(), assemblyCorrection(headY: -1), assemblyCorrection(headY: -.infinity)] {
        #expect(throws: RigError.self) { try SourceMakerAssemblyOptions.body(sex: 1, boneType: 1, correctionData: data) }
    }
}

private struct VariantRegistry: Decodable {
    struct Entry: Decodable {
        struct File: Decodable { let file: String }
        let sex: Int, headID: Int, exType: Int, manifest: File
    }
    let assemblies: [Entry]
}
private struct VariantExpressions: Decodable {
    struct Case: Decodable {
        struct Mesh: Decodable { let nodeName: String, weights: [Float] }
        let inputs: SourceExpressionInputs, meshes: [Mesh]
    }
    let cases: [Case]
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sourceMakerAdditionalHeadsUseOwnCurvesMorphsAndCorrectedBodyWhenSupplied() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_MAKER_ASSEMBLIES"] else { return }
    let registryURL = URL(fileURLWithPath: path)
    let root = registryURL.deletingLastPathComponent().deletingLastPathComponent()
    let registry = try JSONDecoder().decode(VariantRegistry.self, from: Data(contentsOf: registryURL))
    #expect(registry.assemblies.count == 4)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for entry in registry.assemblies {
        let url = root.appendingPathComponent(entry.manifest.file), folder = url.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: url))
        #expect(manifest.sex == entry.sex && manifest.headID == entry.headID)
        let source = try SourceRig.loadModel(url: url)
        let contract = try SourceShapeContract.decode(Data(contentsOf: folder.appendingPathComponent("character-shape-contract.json")))
        let expressions = try SourceExpressionContract.decode(Data(contentsOf: folder.appendingPathComponent("source-expression-contract.json")))
        let reference = try JSONDecoder().decode(VariantExpressions.self, from: Data(contentsOf: folder.appendingPathComponent("source-expression-reference.json")))
        let face = try #require(contract.domain("face")), body = try #require(contract.domain("body"))
        #expect(face.valueCount == 52 && body.valueCount == 44)
        for sample in reference.cases {
            let actual = try expressions.weights(source: source, inputs: sample.inputs)
            for part in source.parts where actual[part.mesh.name] != nil {
                let expected = try #require(sample.meshes.first { part.mesh.name == $0.nodeName + "/0" })
                var dense = Array(repeating: Float.zero, count: expected.weights.count)
                for weight in actual[part.mesh.name]! { dense[weight.index] = weight.weight }
                #expect(zip(dense, expected.weights).allSatisfy { abs($0 - $1 / 100) < 0.000002 })
            }
        }
        let appearanceURL = url.deletingPathExtension().appendingPathExtension("appearance.json")
        let appearance = try SourcePreviewAppearance.load(url: appearanceURL, resources: resources)
        for type in [0, 1] {
            let options = try SourceMakerAssemblyOptions.body(sex: entry.sex, boneType: type,
                correctionData: Data(contentsOf: folder.appendingPathComponent("shapecorrect.bytes")))
            let preview = try SourceRigPreview(source: source, contract: contract, resources: resources,
                appearance: appearance, expressionContract: expressions, bodyOptions: options)
            #expect(preview.supportsFaceCustomization && preview.supportsBodyCustomization && preview.supportsExpressions)
            #expect(preview.bodyCoverage?.completeSlots == Array(0..<44))
            let pose = try preview.pose(bodyValues: body.defaultValues, faceValues: face.defaultValues)
            let collider = try source.rig.uniqueNode(named: "cf_hit_head")
            let expectedScale = SourceMakerAssemblyOptions.headColliderScale(boneType: type)
            #expect(abs(simd_length(SIMD3(pose.localMatrices[collider][0].x,
                pose.localMatrices[collider][0].y, pose.localMatrices[collider][0].z)) - expectedScale) < 0.000002)
            let frame = try preview.frame(camera: OrbitCamera(), bodyValues: body.defaultValues,
                faceValues: face.defaultValues, expression: expressions.defaults)
            #expect(frame.sceneBounds.radius.isFinite && !frame.items.isEmpty)
        }
    }
}
