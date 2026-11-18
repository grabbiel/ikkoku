import Testing
import simd
import CoreMath
import Renderer
import ShaderTypes
@testable import Studio

// #371: `GizmoBuilder.handle` takes its vertices from a table that
// `octahedron(center: .zero, radius: 1, color:)` builds once. Every handle must
// equal the batch the code before #371 built, bit for bit.

/// The batch `handle(at:size:color:id:)` built before #371.
private func handleBeforeTable(at p: Float3, size: Float, color: Float4, id: UInt32) -> GizmoBatch {
    GizmoBatch(primitive: .triangles, vertices: GizmoBuilder.octahedron(center: .zero, radius: 1, color: color),
               model: Transform.trs(p, .identity, Float3(repeating: size)), depthTest: false, objectID: id)
}

/// Every float's bit pattern: the vertices' positions (x, y, z; the padding
/// lane is not read by the shader) and colors, then the model matrix.
private func bits(_ batch: GizmoBatch) -> [UInt32] {
    let vertices = batch.vertices.flatMap { v in
        [v.position.x, v.position.y, v.position.z, v.color.x, v.color.y, v.color.z, v.color.w].map(\.bitPattern)
    }
    return vertices + (0..<4).flatMap { c in (0..<4).map { batch.model[c][$0].bitPattern } }
}

@Test func gizmoHandleEqualsTheConstructionBeforeTheTableBitForBit() {
    let centers: [Float3] = [.zero, Float3(-0.0, -0.0, -0.0), Float3(-0.37, 1.25, -2.5), Float3(-1e-3, -7.75, -123.456),
                             Float3(1e6, -3.5e5, 98765.43), Float3(-4e7, 2.5e7, 1e8)]
    // Handle sizes are pixels × world units per pixel × 6, 7, 9 or 10.
    let sizes: [Float] = [1, 0.04, 0.3, 6 * 0.0123, 9 * 0.0071, 37.5, 1e-4, 250.7]
    let colors: [Float4] = [Float4(1, 1, 1, 1), GizmoBuilder.highlightColor, Float4(0.93, 0.28, 0.32, 1),
                            Float4(0.2, 0.75, 1, 0.7), Float4(0, 0, 0, 0), Float4(-0.0, 0.1, 0.333, 0.999)]
    var compared = 0
    for (i, p) in centers.enumerated() {
        for (j, size) in sizes.enumerated() {
            for (k, color) in colors.enumerated() {
                let id = PickIDs.bone(i * 100 + j * 10 + k)
                let table = GizmoBuilder.handle(at: p, size: size, color: color, id: id)
                let before = handleBeforeTable(at: p, size: size, color: color, id: id)
                #expect(table.primitive == before.primitive && table.depthTest == before.depthTest && table.objectID == before.objectID)
                #expect(table.vertices.count == 24 && before.vertices.count == 24)
                #expect(bits(table) == bits(before), "handle at \(p), size \(size), color \(color)")
                compared += 1
            }
        }
    }
    #expect(compared == 288)
    // The table is the unit octahedron's corners: ±1 on one axis, 0 elsewhere.
    #expect(Set(GizmoBuilder.unitOctahedron.map { [$0.x, $0.y, $0.z].map(\.bitPattern) }).count == 6)
}
