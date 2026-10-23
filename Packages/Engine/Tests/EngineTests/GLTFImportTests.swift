import Testing
import Foundation
import Assets
@testable import Character
import CoreMath
import simd

private func gltfJSON(_ fields: [String: Any] = [:], buffer: Data? = nil, declaredLength: Int? = nil) throws -> Data {
    var root = fields
    root["asset"] = ["version": "2.0"]
    if let buffer {
        root["buffers"] = [["byteLength": declaredLength ?? buffer.count,
            "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()]]
    }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func words(_ values: [UInt32]) -> Data {
    var data = Data()
    for var value in values.map(\.littleEndian) {
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
}

private func floats(_ values: [Float]) -> Data { words(values.map(\.bitPattern)) }

private func triangleFields(extraAccessor: [String: Any]? = nil) -> [String: Any] {
    var accessors: [[String: Any]] = [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]]
    if let extraAccessor { accessors.append(extraAccessor) }
    return [
        "bufferViews": [["buffer": 0, "byteLength": 36]],
        "accessors": accessors,
        "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
        "nodes": [["mesh": 0]],
        "scenes": [["nodes": [0]]], "scene": 0
    ]
}

private let trianglePositions = floats([0, 0, 0, 1, 0, 0, 0, 1, 0])

@Test func gltfRejectsNonfiniteBinaryVertexComponentsBeforeRegistration() throws {
    for invalid: Float in [.nan, .infinity, -.infinity] {
        let positions = floats([0, 0, 0, 1, invalid, 0, 0, 1, 0])
        let json = try gltfJSON(triangleFields(), buffer: positions)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: json, baseURL: nil) }
        var fields = triangleFields(extraAccessor: ["bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"])
        fields["bufferViews"] = [["buffer": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 36]]
        fields["meshes"] = [["primitives": [["attributes": ["POSITION": 0, "NORMAL": 1]]]]]
        let normals = floats([0, 0, invalid, 0, 0, 1, 0, 0, 1])
        let withNormals = try gltfJSON(fields, buffer: trianglePositions + normals)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: withNormals, baseURL: nil) }
    }
}

@Test func gltfSmoothNormalsSupportCoordinatesBeyondInt32QuantizationRange() {
    // The old p * 5000 -> Int32 key trapped at coordinates above ~429,496.
    let positions = [Float3(1_000_000, 0, 0), Float3(1_000_001, 0, 0), Float3(1_000_000, 1, 0)]
    let normals = MeshUtil.computeSmoothNormals(positions: positions, indices: [0, 1, 2])
    #expect(normals == [Float3](repeating: Float3(0, 0, 1), count: 3))
}

@Test func gltfRejectsTruncatedBuffersAndOverflowingRanges() throws {
    let base: [String: Any] = ["bufferViews": [["buffer": 0, "byteLength": 36]],
        "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]]]
    let tooShort = try gltfJSON(base, buffer: Data(repeating: 0, count: 35), declaredLength: 36)
    #expect(throws: (any Error).self) { try GLBLoader.load(data: tooShort, baseURL: nil) }

    for accessor in [
        ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"],
        ["bufferView": 0, "byteOffset": Int.max, "componentType": 5126, "count": 1, "type": "VEC3"],
        ["bufferView": 0, "byteOffset": -1, "componentType": 5126, "count": 1, "type": "VEC3"],
        ["bufferView": 0, "componentType": 5126, "count": Int.max, "type": "VEC3"]
    ] as [[String: Any]] {
        var fields = base
        fields["accessors"] = [accessor]
        let data = try gltfJSON(fields, buffer: trianglePositions)
        #expect(throws: (any Error).self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
}

@Test func gltfRespectsDeclaredBufferLengthInsteadOfFilePadding() throws {
    let fields: [String: Any] = ["bufferViews": [["buffer": 0, "byteOffset": 1, "byteLength": 3]]]
    // Four bytes exist physically, but only one byte belongs to the declared buffer.
    let data = try gltfJSON(fields, buffer: Data([1, 2, 3, 4]), declaredLength: 1)
    #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
}

@Test func gltfReadsInterleavedAccessorWithOffsetAndRejectsShortStride() throws {
    // Padding before the accessor and between vertices is not vertex data.
    let buffer = floats([99, 0, 0, 0, 99, 1, 0, 0, 99, 0, 1, 0])
    var fields = triangleFields()
    fields["bufferViews"] = [["buffer": 0, "byteLength": buffer.count, "byteStride": 16]]
    fields["accessors"] = [["bufferView": 0, "byteOffset": 4, "componentType": 5126, "count": 3, "type": "VEC3"]]
    let asset = try GLBLoader.load(data: gltfJSON(fields, buffer: buffer), baseURL: nil)
    #expect(asset.meshes[0].primitives[0].positions == [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)])
    for stride in [0, -4, 8, 14, 256, Int.max] {
        fields["bufferViews"] = [["buffer": 0, "byteLength": buffer.count, "byteStride": stride]]
        let data = try gltfJSON(fields, buffer: buffer)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
}

private func sparseTriangle(indices: [UInt32], valueByteLength: Int? = nil, indexOffset: Int = 0) throws -> Data {
    let indexData = words(indices)
    let values = floats([1, 0, 0, 0, 1, 0])
    var fields = triangleFields()
    fields["bufferViews"] = [
        ["buffer": 0, "byteLength": indexData.count],
        ["buffer": 0, "byteOffset": indexData.count, "byteLength": valueByteLength ?? values.count]
    ]
    fields["accessors"] = [["componentType": 5126, "count": 3, "type": "VEC3",
        "sparse": ["count": indices.count,
            "indices": ["bufferView": 0, "byteOffset": indexOffset, "componentType": 5125],
            "values": ["bufferView": 1]]]]
    return try gltfJSON(fields, buffer: indexData + values)
}

@Test func gltfAppliesSparseAccessorsAndRejectsInvalidSparseIndices() throws {
    let valid = try GLBLoader.load(data: sparseTriangle(indices: [1, 2]), baseURL: nil)
    #expect(valid.meshes[0].primitives[0].positions == [Float3(0, 0, 0), Float3(1, 0, 0), Float3(0, 1, 0)])
    for indices: [UInt32] in [[1, 3], [2, 1], [1, 1], [0, .max]] {
        let data = try sparseTriangle(indices: indices)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
    let shortValues = try sparseTriangle(indices: [1, 2], valueByteLength: 20)
    #expect(throws: GLTFError.self) { try GLBLoader.load(data: shortValues, baseURL: nil) }
    let shortIndices = try sparseTriangle(indices: [1, 2], indexOffset: 4)
    #expect(throws: GLTFError.self) { try GLBLoader.load(data: shortIndices, baseURL: nil) }
}

@Test func gltfRejectsCyclesMultipleParentsAndInvalidSceneRoots() throws {
    let fixtures: [[String: Any]] = [
        ["nodes": [["children": [1]], ["children": [0]]]],
        ["nodes": [["children": [2]], ["children": [2]], [:]]],
        ["nodes": [["children": [0]]]],
        ["nodes": [["children": [-1]]]],
        ["nodes": [["children": [1]], [:]], "scenes": [["nodes": [1]]]],
        ["nodes": [[:]], "scenes": [["nodes": [0, 0]]]],
        ["nodes": [[:]], "scenes": [["nodes": [0]]], "scene": 2]
    ]
    for fields in fixtures {
        let data = try gltfJSON(fields)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
}

@Test func gltfPreservesAuthoredReflectionsAndOnlyTraversesActiveScene() throws {
    let reflected: [Float] = [-2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0.5, 0, 4, 5, 6, 1]
    var fields = triangleFields()
    fields["nodes"] = [
        ["name": "inactive", "mesh": 0],
        ["name": "parent", "matrix": reflected, "children": [2]],
        ["name": "child", "mesh": 0, "translation": [1, 2, 3]]
    ]
    fields["scenes"] = [["nodes": [0]], ["nodes": [1]]]
    fields["scene"] = 1
    let asset = try GLBLoader.load(data: gltfJSON(fields, buffer: trianglePositions), baseURL: nil)
    #expect(asset.rootNodes == [1])
    #expect(asset.meshNodes.map(\.node) == [2])
    #expect(asset.nodes[1].authoredMatrix != nil)
    #expect(asset.nodes[1].localMatrix.columns.0 == Float4(-2, 0, 0, 0))
    #expect(asset.worldMatrix(ofNode: 2).translation == Float3(2, 11, 7.5))
    #expect(simd_determinant(asset.worldMatrix(ofNode: 2).upperLeft3x3) < 0)
    fields["scene"] = 0
    let first = try GLBLoader.load(data: gltfJSON(fields, buffer: trianglePositions), baseURL: nil)
    #expect(first.meshNodes.map(\.node) == [0])
}

@Test func gltfLoadsPercentEncodedExternalImagesRelativeToAsset() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-gltf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA20AAAAASUVORK5CYII=")!
    try png.write(to: directory.appendingPathComponent("source image.png"))
    let fields: [String: Any] = ["images": [["uri": "source%20image.png", "mimeType": "image/png"]]]
    let json = try gltfJSON(fields)
    let url = directory.appendingPathComponent("asset.gltf")
    try json.write(to: url)
    let asset = try GLBLoader.load(url: url)
    #expect(asset.images[0].data == png)
    #expect(asset.images[0].mimeType == "image/png")
    #expect(asset.url == url)
    #expect(throws: GLTFError.self) { try GLBLoader.load(data: json, baseURL: nil) }
    let brokenDataURI = try gltfJSON(["images": [["uri": "data:image/png;base64,!invalid!"]]])
    #expect(throws: GLTFError.self) { try GLBLoader.load(data: brokenDataURI, baseURL: directory) }
}

@Test func gltfUInt32IndicesRemainExactAndRejectOverflowValuesSafely() throws {
    // Values above Float's exact integer range must not be rounded or trap during decoding.
    for index: UInt32 in [16_777_217, .max] {
        var fields = triangleFields(extraAccessor: ["bufferView": 1, "componentType": 5125, "count": 3, "type": "SCALAR"])
        fields["bufferViews"] = [["buffer": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 12]]
        fields["meshes"] = [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]]
        let json = try gltfJSON(fields, buffer: trianglePositions + words([0, 1, index]))
        do {
            _ = try GLBLoader.load(data: json, baseURL: nil)
            Issue.record("Out-of-range triangle index was accepted")
        } catch let error as GLTFError {
            #expect(error.description.contains("triangle index \(index) exceeds 3 vertices"))
        }
    }
}

private func glb(_ chunks: [(UInt32, Data)], version: UInt32 = 2) -> Data {
    var body = Data()
    for (type, chunk) in chunks {
        body += words([UInt32(chunk.count), type]) + chunk
    }
    return words([0x46546C67, version, UInt32(12 + body.count)]) + body
}

@Test func gltfChecksGLBChunkOrderingLengthAndPadding() throws {
    var json = try gltfJSON()
    while !json.count.isMultiple(of: 4) { json.append(0x20) }
    let valid = glb([(0x4E4F534A, json)])
    _ = try GLBLoader.load(data: valid, baseURL: nil)
    // Unknown trailing chunks are permitted by the GLB extension rules.
    _ = try GLBLoader.load(data: glb([(0x4E4F534A, json), (0x12345678, Data([0, 0, 0, 0]))]), baseURL: nil)
    let fixtures = [
        glb([(0x4E4F534A, json)], version: 1),
        glb([(0x4E4F534A, json), (0x4E4F534A, json)]),
        glb([(0x004E4942, Data()), (0x4E4F534A, json)]),
        glb([(0x4E4F534A, json), (0x004E4942, Data()), (0x004E4942, Data())]),
        glb([(0x4E4F534A, json), (0x004E4942, Data([0]))]),
        valid + Data([0]),
        Data(valid.dropLast())
    ]
    for data in fixtures {
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
}

// MARK: - R5 interchange subset: secondary UVs, texture selections, extensions, influences, morph weights

private typealias AccessorStream = (data: Data, accessor: [String: Any])

private func halves(_ values: [UInt16]) -> Data {
    var data = Data()
    for var value in values.map(\.littleEndian) {
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
}

private func stream(_ data: Data, _ componentType: Int, _ type: String, count: Int = 3, normalized: Bool = false) -> AccessorStream {
    var accessor: [String: Any] = ["componentType": componentType, "count": count, "type": type]
    if normalized { accessor["normalized"] = true }
    return (data: data, accessor: accessor)
}

/// One mesh with one primitive in the active scene; accessor `i` reads `streams[i]` from its own view.
private func singleMeshFields(_ streams: [AccessorStream], primitive: [String: Any],
                              mesh: [String: Any] = [:]) -> (fields: [String: Any], buffer: Data) {
    var buffer = Data(), views: [[String: Any]] = [], accessors: [[String: Any]] = []
    for (i, item) in streams.enumerated() {
        while !buffer.count.isMultiple(of: 4) { buffer.append(0) }
        views.append(["buffer": 0, "byteOffset": buffer.count, "byteLength": item.data.count])
        var accessor = item.accessor
        accessor["bufferView"] = i
        accessors.append(accessor)
        buffer += item.data
    }
    var meshObject = mesh
    meshObject["primitives"] = [primitive]
    let fields: [String: Any] = ["bufferViews": views, "accessors": accessors, "meshes": [meshObject],
                                 "nodes": [["mesh": 0]], "scenes": [["nodes": [0]]], "scene": 0]
    return (fields: fields, buffer: buffer)
}

private let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA20AAAAASUVORK5CYII="

@Test func gltfDecodesSecondaryTextureCoordinatesAsIndependentStreams() throws {
    let uv0: [Float] = [0, 0, 1, 0, 0, 1]
    let uv1: [Float] = [0.25, 0.5, 0.75, 0.5, 0.5, 1]
    let built = singleMeshFields([
        stream(trianglePositions, 5126, "VEC3"), stream(floats(uv0), 5126, "VEC2"), stream(floats(uv1), 5126, "VEC2"),
        stream(halves([0, 65535, 65535, 0, 0, 0]), 5123, "VEC2", normalized: true)
    ], primitive: ["attributes": ["POSITION": 0, "TEXCOORD_0": 1, "TEXCOORD_1": 2, "TEXCOORD_2": 3]])
    let asset = try GLBLoader.load(data: gltfJSON(built.fields, buffer: built.buffer), baseURL: nil)
    let mesh = try #require(asset.meshes.first?.primitives.first)
    #expect(mesh.uvs == [Float2(0, 0), Float2(1, 0), Float2(0, 1)])
    #expect(mesh.uvs1 == [Float2(0.25, 0.5), Float2(0.75, 0.5), Float2(0.5, 1)])
    #expect(mesh.uvs2 == [Float2(0, 1), Float2(1, 0), Float2(0, 0)])
    #expect(asset.diagnostics.isEmpty)

    // TEXCOORD_0-only content without extensions keeps empty secondary streams and reports nothing.
    let legacy = singleMeshFields([stream(trianglePositions, 5126, "VEC3"), stream(floats(uv0), 5126, "VEC2")],
                                  primitive: ["attributes": ["POSITION": 0, "TEXCOORD_0": 1]])
    let plain = try GLBLoader.load(data: gltfJSON(legacy.fields, buffer: legacy.buffer), baseURL: nil)
    let plainMesh = try #require(plain.meshes.first?.primitives.first)
    #expect(plainMesh.uvs == [Float2(0, 0), Float2(1, 0), Float2(0, 1)])
    #expect(plainMesh.uvs1.isEmpty && plainMesh.uvs2.isEmpty)
    #expect(plain.diagnostics.isEmpty)
}

@Test func gltfRejectsMalformedTextureCoordinateStreams() throws {
    let uv: [Float] = [0, 0, 1, 0, 0, 1]
    let invalid: [AccessorStream] = [
        stream(floats(uv + [0, 0, 0]), 5126, "VEC3"),                       // shape
        stream(floats(Array(uv.prefix(4))), 5126, "VEC2", count: 2),        // vertex count
        stream(halves([0, 1, 2, 3, 4, 5]), 5123, "VEC2"),                   // unnormalized integer
        stream(words([0, 1, 2, 3, 4, 5]), 5125, "VEC2", normalized: true)   // component type
    ]
    for semantic in ["TEXCOORD_0", "TEXCOORD_1", "TEXCOORD_2"] {
        for item in invalid {
            let built = singleMeshFields([stream(trianglePositions, 5126, "VEC3"), item],
                                         primitive: ["attributes": ["POSITION": 0, semantic: 1]])
            let data = try gltfJSON(built.fields, buffer: built.buffer)
            #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
        }
    }
}

private func texturedTriangle(baseTexCoord: Int, normalTexCoord: Int? = nil, uvSets: Int = 2) throws -> Data {
    let uv: [Float] = [0, 0, 1, 0, 0, 1]
    var streams = [stream(trianglePositions, 5126, "VEC3")]
    var attributes = ["POSITION": 0]
    for uvSet in 0..<uvSets {
        streams.append(stream(floats(uv), 5126, "VEC2"))
        attributes["TEXCOORD_\(uvSet)"] = uvSet + 1
    }
    var built = singleMeshFields(streams, primitive: ["attributes": attributes, "material": 0])
    var normal: [String: Any] = ["index": 0]
    if let normalTexCoord { normal["texCoord"] = normalTexCoord }
    let base: [String: Any] = ["index": 0, "texCoord": baseTexCoord]
    built.fields["materials"] = [["name": "uv-select", "pbrMetallicRoughness": ["baseColorTexture": base], "normalTexture": normal]]
    built.fields["textures"] = [["source": 0]]
    built.fields["images"] = [["uri": "data:image/png;base64," + onePixelPNG, "mimeType": "image/png"]]
    return try gltfJSON(built.fields, buffer: built.buffer)
}

@Test func gltfRetainsTextureCoordinateSelectionAndNativeMaterialsRejectSecondarySets() throws {
    let primary = try GLBLoader.load(data: texturedTriangle(baseTexCoord: 0), baseURL: nil)
    #expect(primary.materials[0].baseColorTexCoord == 0 && primary.materials[0].normalTexCoord == 0)
    try LoadedAsset.requirePrimaryTextureCoordinates(primary)

    let secondary = try GLBLoader.load(data: texturedTriangle(baseTexCoord: 1, normalTexCoord: 0), baseURL: nil)
    #expect(secondary.materials[0].baseColorTexCoord == 1 && secondary.materials[0].normalTexCoord == 0)
    #expect(secondary.materials[0].baseColorImage == 0)
    #expect(secondary.meshes[0].primitives[0].uvs1.count == 3)
    do {
        try LoadedAsset.requirePrimaryTextureCoordinates(secondary)
        Issue.record("A TEXCOORD_1 base color texture reached the UV0-only native material path")
    } catch let error as GLTFError {
        #expect(error.description.contains("baseColorTexture from TEXCOORD_1"))
    }
    let normalSecondary = try GLBLoader.load(data: texturedTriangle(baseTexCoord: 0, normalTexCoord: 1), baseURL: nil)
    #expect(normalSecondary.materials[0].normalTexCoord == 1)
    #expect(throws: GLTFError.self) { try LoadedAsset.requirePrimaryTextureCoordinates(normalSecondary) }

    // The selected set must exist on the primitive and be one of the decoded sets.
    let absentSet = try texturedTriangle(baseTexCoord: 1, uvSets: 1)
    let undecodedSet = try texturedTriangle(baseTexCoord: 3, uvSets: 3)
    for data in [absentSet, undecodedSet] {
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
}

@Test func gltfRejectsEachUnsupportedRequiredExtensionByName() throws {
    let names = ["KHR_draco_mesh_compression", "EXT_meshopt_compression"]
    var fields = triangleFields()
    fields["extensionsUsed"] = names + ["KHR_texture_transform"]
    fields["extensionsRequired"] = names + [names[0]]
    let data = try gltfJSON(fields, buffer: trianglePositions)
    do {
        _ = try GLBLoader.load(data: data, baseURL: nil)
        Issue.record("Unsupported required extensions were accepted")
    } catch GLTFError.unsupportedExtensions(let rejected) {
        #expect(rejected == names)
        #expect(GLTFError.unsupportedExtensions(rejected).description.contains("KHR_draco_mesh_compression, EXT_meshopt_compression"))
    }
    #expect(GLBLoader.supportedExtensions.isEmpty)
}

@Test func gltfReportsUnsupportedUsedExtensionsSamplersAndTextureSlots() throws {
    var fields = triangleFields()
    fields["extensionsUsed"] = ["KHR_texture_transform", "KHR_materials_emissive_strength", "KHR_texture_transform"]
    fields["meshes"] = [["primitives": [["attributes": ["POSITION": 0], "material": 0]]]]
    let transformed: [String: Any] = ["index": 0, "extensions": ["KHR_texture_transform": ["offset": [0.5, 0]]]]
    let pbr: [String: Any] = ["baseColorTexture": transformed, "metallicRoughnessTexture": ["index": 1]]
    fields["materials"] = [["name": "reported", "pbrMetallicRoughness": pbr, "normalTexture": ["index": 1], "emissiveTexture": ["index": 1]]]
    fields["samplers"] = [["wrapS": 33071, "wrapT": 10497], ["magFilter": 9729, "minFilter": 9987]]
    fields["textures"] = [["source": 0, "sampler": 0], ["source": 0, "sampler": 1]]
    fields["images"] = [["uri": "data:image/png;base64," + onePixelPNG]]
    let asset = try GLBLoader.load(data: gltfJSON(fields, buffer: trianglePositions), baseURL: nil)
    let codes = asset.diagnostics.map(\.code)
    #expect(codes == ["unsupported_extension", "unsupported_extension", "unsupported_texture_slot", "unsupported_sampler"])
    try #require(asset.diagnostics.count == 4)
    #expect(asset.diagnostics[0].message.contains("KHR_texture_transform"))
    #expect(asset.diagnostics[1].message.contains("KHR_materials_emissive_strength"))
    #expect(asset.diagnostics[2].message.contains("metallicRoughnessTexture, emissiveTexture"))
    #expect(asset.diagnostics[3].message.contains("baseColorTexture") && asset.diagnostics[3].message.contains("33071"))
    // The texture still binds; only the reported features are dropped.
    #expect(asset.materials[0].baseColorImage == 0 && asset.materials[0].normalImage == 0)

    let invalid: [[String: Any]] = [
        ["samplers": [["wrapS": 1234]], "textures": [["source": 0, "sampler": 0]]],
        ["samplers": [["magFilter": 9987]], "textures": [["source": 0, "sampler": 0]]],
        ["samplers": [["name": "only"]], "textures": [["source": 0, "sampler": 1]]],
        ["textures": [["source": 0]], "materials": [["emissiveTexture": ["index": 4]]]]
    ]
    for overrides in invalid {
        var broken = triangleFields()
        broken["images"] = [["uri": "data:image/png;base64," + onePixelPNG]]
        for (key, value) in overrides { broken[key] = value }
        let data = try gltfJSON(broken, buffer: trianglePositions)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
}

@Test func gltfReportsSkinInfluenceReductionBeyondFourWeights() throws {
    let joints0 = Data([0, 1, 2, 3, 0, 1, 2, 3, 0, 0, 0, 0])
    let joints1 = Data([4, 5, 6, 7, 4, 5, 6, 7, 0, 0, 0, 0])
    let weights0 = floats([0.4, 0.3, 0, 0, 0.3, 0.25, 0.2, 0.05, 1, 0, 0, 0])
    let weights1 = floats([0.2, 0.1, 0, 0, 0.15, 0.05, 0, 0, 0, 0, 0, 0])
    let streams = [stream(trianglePositions, 5126, "VEC3"), stream(joints0, 5121, "VEC4"), stream(weights0, 5126, "VEC4"),
                   stream(joints1, 5121, "VEC4"), stream(weights1, 5126, "VEC4")]
    let two = singleMeshFields(streams, primitive: ["attributes": ["POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2, "JOINTS_1": 3, "WEIGHTS_1": 4]])
    let asset = try GLBLoader.load(data: gltfJSON(two.fields, buffer: two.buffer), baseURL: nil)
    let mesh = try #require(asset.meshes.first?.primitives.first)
    #expect(mesh.joints[0] == SIMD4<UInt16>(0, 1, 4, 5))
    #expect(mesh.joints[1] == SIMD4<UInt16>(0, 1, 2, 4))
    for vertex in 0..<3 { #expect(abs(mesh.weights[vertex].sum() - 1) < 1e-6) }
    #expect(abs(mesh.weights[1].x - 0.3 / 0.9) < 1e-6)
    #expect(asset.diagnostics.map(\.code) == ["skin_influences_reduced"])
    let message = try #require(asset.diagnostics.first?.message)
    #expect(message.contains("8 skin influences per vertex (JOINTS_0...JOINTS_1)"))
    #expect(message.contains("1 of 3 vertices lost nonzero weight"))

    // Additional contiguous sets fold in the same way and are reported with their count.
    let three = singleMeshFields(streams, primitive: ["attributes": ["POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2,
        "JOINTS_1": 3, "WEIGHTS_1": 4, "JOINTS_2": 3, "WEIGHTS_2": 4]])
    let twelve = try GLBLoader.load(data: gltfJSON(three.fields, buffer: three.buffer), baseURL: nil)
    #expect(twelve.diagnostics.first?.message.contains("12 skin influences per vertex (JOINTS_0...JOINTS_2)") == true)

    for attributes in [
        ["POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2, "JOINTS_2": 3, "WEIGHTS_2": 4],  // gap in set numbering
        ["POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2, "JOINTS_1": 3],                // unpaired joints
        ["POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2, "JOINTS_1": 3, "WEIGHTS_1": 0] // VEC3 weights
    ] {
        let built = singleMeshFields(streams, primitive: ["attributes": attributes])
        let data = try gltfJSON(built.fields, buffer: built.buffer)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
}

@Test func gltfRetainsInitialMorphWeightsWithNodeOverride() throws {
    let deltas = floats([0, 0, 1, 0, 0, 1, 0, 0, 1])
    let streams = [stream(trianglePositions, 5126, "VEC3"), stream(deltas, 5126, "VEC3"), stream(deltas, 5126, "VEC3")]
    let morphed: [String: Any] = ["attributes": ["POSITION": 0], "targets": [["POSITION": 1], ["POSITION": 2]]]
    var built = singleMeshFields(streams, primitive: morphed, mesh: ["name": "morphs", "weights": [0.25, 0]])
    built.fields["nodes"] = [["name": "override", "mesh": 0, "weights": [0, 0.5]], ["name": "inherit", "mesh": 0],
                             ["name": "zero", "mesh": 0, "weights": [0, 0]]]
    built.fields["scenes"] = [["nodes": [0, 1, 2]]]
    let asset = try GLBLoader.load(data: gltfJSON(built.fields, buffer: built.buffer), baseURL: nil)
    let meshWeights: [Float] = [0.25, 0], nodeWeights: [Float] = [0, 0.5], zeroWeights: [Float] = [0, 0]
    let inheritsMesh = asset.nodes[1].weights == nil
    #expect(asset.meshes[0].weights == meshWeights)
    #expect(asset.nodes[0].weights == nodeWeights)
    #expect(inheritsMesh)
    #expect(asset.initialMorphWeights(ofNode: 0) == nodeWeights)
    #expect(asset.initialMorphWeights(ofNode: 1) == meshWeights)
    #expect(asset.initialMorphWeights(ofNode: 2) == zeroWeights)
    let reported = asset.diagnostics.filter { $0.code == "initial_morph_weights_not_applied" }
    #expect(reported.count == 2 && asset.diagnostics.count == 2)
    #expect(reported.first?.message.contains("'override'") == true)
    #expect(reported.last?.message.contains("'inherit'") == true)

    // Absent weights default to zero for every target and are not reported.
    let unweighted = singleMeshFields(streams, primitive: morphed)
    let zero = try GLBLoader.load(data: gltfJSON(unweighted.fields, buffer: unweighted.buffer), baseURL: nil)
    #expect(zero.initialMorphWeights(ofNode: 0) == zeroWeights)
    #expect(zero.diagnostics.isEmpty)

    let invalid: [(mesh: [String: Any], nodes: [[String: Any]])] = [
        (mesh: ["weights": [0.25]], nodes: [["mesh": 0]]),                     // mesh weight count
        (mesh: [:], nodes: [["mesh": 0, "weights": [0, 0, 0]]]),               // node weight count
        (mesh: [:], nodes: [["mesh": 0], ["weights": [0, 0]]])                 // node weights without a mesh
    ]
    for item in invalid {
        var broken = singleMeshFields(streams, primitive: morphed, mesh: item.mesh)
        broken.fields["nodes"] = item.nodes
        let data = try gltfJSON(broken.fields, buffer: broken.buffer)
        #expect(throws: GLTFError.self) { try GLBLoader.load(data: data, baseURL: nil) }
    }
    var mismatched = singleMeshFields(streams, primitive: morphed)
    mismatched.fields["meshes"] = [["primitives": [morphed, ["attributes": ["POSITION": 0]]]]]
    let mismatchedData = try gltfJSON(mismatched.fields, buffer: mismatched.buffer)
    #expect(throws: GLTFError.self) { try GLBLoader.load(data: mismatchedData, baseURL: nil) }
}

@Test func gltfReportsAttributesItDoesNotDecode() throws {
    let built = singleMeshFields([stream(trianglePositions, 5126, "VEC3"), stream(floats([0, 0, 1, 0, 0, 1]), 5126, "VEC2")],
        primitive: ["attributes": ["POSITION": 0, "TEXCOORD_0": 1, "TEXCOORD_3": 1, "COLOR_1": 0, "_CUSTOM": 1],
                    "targets": [["POSITION": 0, "TANGENT": 0]]])
    let asset = try GLBLoader.load(data: gltfJSON(built.fields, buffer: built.buffer), baseURL: nil)
    #expect(asset.diagnostics.map(\.code) == ["ignored_attribute", "ignored_morph_attribute"])
    #expect(asset.diagnostics.first?.message.contains("COLOR_1, TEXCOORD_3, _CUSTOM") == true)
    #expect(asset.diagnostics.last?.message.contains("TANGENT") == true)
}
