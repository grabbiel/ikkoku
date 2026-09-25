import Testing
import Foundation
import Assets
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
