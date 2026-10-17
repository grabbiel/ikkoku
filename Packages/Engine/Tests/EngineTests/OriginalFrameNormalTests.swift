import Foundation
import CryptoKit
import Testing
import simd
@testable import Renderer

// Synthetic sidecar contract for OriginalFrameProbe.sourceVertexNormals; no
// original capture is required.

private func normalBytes(_ values: [Float]) -> Data {
    values.reduce(into: Data()) { data, value in
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private let geometryBytes = Data("synthetic frozen geometry".utf8)

private func normalDescriptor(_ bytes: Data, count: Int = 2) -> [String: Any] {
    ["file": "normals.bin", "space": "unity-renderer-local", "count": count,
     "sha256": sha256(bytes), "geometrySHA256": sha256(geometryBytes)]
}

private func fixtureFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try geometryBytes.write(to: folder.appendingPathComponent("mesh.bin"))
    return folder
}

@Test func originalFrameNormalsPreserveMagnitudeAndLegacyFallback() throws {
    let folder = try fixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = normalBytes([2, 0, 0, 0, 0.5, -0.25])
    try bytes.write(to: folder.appendingPathComponent("normals.bin"))
    // Nonunit values are returned exactly; the loader never normalizes.
    let result = try OriginalFrameProbe.sourceVertexNormals(normalDescriptor(bytes), vertexCount: 2, geometryFile: "mesh.bin", directory: folder)
    #expect(result == [SIMD3<Float>(2, 0, 0), SIMD3<Float>(0, 0.5, -0.25)])
    // Old captures have no descriptor and keep the legacy reconstruction.
    #expect(try OriginalFrameProbe.sourceVertexNormals(nil, vertexCount: 2, geometryFile: "mesh.bin", directory: folder) == nil)
}

@Test func originalFrameNormalsRejectInvalidIdentityExtentAndValues() throws {
    let folder = try fixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = normalBytes([2, 0, 0, 0, 0.5, -0.25])
    try bytes.write(to: folder.appendingPathComponent("normals.bin"))
    for (key, value) in [("file", "../normals.bin" as Any), ("file", ""), ("file", "missing.bin"), ("file", "mesh.bin"),
                         ("count", 3), ("count", 0), ("count", -1), ("count", "2"),
                         ("space", "world"), ("sha256", String(repeating: "0", count: 64)),
                         ("geometrySHA256", sha256(Data("other geometry".utf8)))] {
        var descriptor = normalDescriptor(bytes); descriptor[key] = value
        #expect(throws: (any Error).self) {
            try OriginalFrameProbe.sourceVertexNormals(descriptor, vertexCount: 2, geometryFile: "mesh.bin", directory: folder)
        }
    }
    for key in ["file", "space", "count", "sha256", "geometrySHA256"] {
        var descriptor = normalDescriptor(bytes); descriptor[key] = nil
        #expect(throws: (any Error).self) {
            try OriginalFrameProbe.sourceVertexNormals(descriptor, vertexCount: 2, geometryFile: "mesh.bin", directory: folder)
        }
    }
    // A descriptor that is not an object, or a mesh without a safe geometry file.
    let malformedRows: [(Any, Any?)] = [("normals.bin", "mesh.bin"), (normalDescriptor(bytes), nil), (normalDescriptor(bytes), "../mesh.bin")]
    for (descriptor, geometry) in malformedRows {
        #expect(throws: (any Error).self) {
            try OriginalFrameProbe.sourceVertexNormals(descriptor, vertexCount: 2, geometryFile: geometry, directory: folder)
        }
    }
    // Even correctly hashed bytes must be complete and finite.
    for invalid in [normalBytes([1, 0, 0]), normalBytes([.nan, 0, 0, 0, 1, 0]),
                    normalBytes([1, 0, 0, 0, .infinity, 0])] {
        try invalid.write(to: folder.appendingPathComponent("normals.bin"))
        #expect(throws: (any Error).self) {
            try OriginalFrameProbe.sourceVertexNormals(normalDescriptor(invalid), vertexCount: 2, geometryFile: "mesh.bin", directory: folder)
        }
    }
}
