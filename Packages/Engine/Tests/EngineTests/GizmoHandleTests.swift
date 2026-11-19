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

// #371: `GizmoBuilder.build(.rotate)` takes its ring positions from a table
// that `ring(axis:radius: 0.9, thickness: 0.025, color:)` builds once per
// axis. Every rotate gizmo must equal the batches the code before #371 built,
// bit for bit.

/// The batches `build(mode: .rotate, ...)` built before #371.
private func rotateBeforeTable(origin: Float3, orientation: simd_quatf, size: Float, highlight: GizmoAxis?) -> [GizmoBatch] {
    let axes: [(GizmoAxis, Float3, Float4)] = [(.x, Float3(1, 0, 0), GizmoBuilder.colX), (.y, Float3(0, 1, 0), GizmoBuilder.colY),
                                               (.z, Float3(0, 0, 1), GizmoBuilder.colZ)]
    let m = Transform.trs(origin, orientation, Float3(repeating: size))
    var batches: [GizmoBatch] = []
    for (axis, dir, col) in axes {
        let c = highlight == axis ? GizmoBuilder.colHi : col
        batches.append(GizmoBatch(primitive: .triangles, vertices: GizmoBuilder.ring(axis: dir, radius: 0.9, thickness: 0.025, color: c),
                                  model: m, depthTest: false, objectID: PickIDs.gizmo(axis)))
    }
    return batches
}

@Test func gizmoRotateRingsEqualTheConstructionBeforeTheTableBitForBit() {
    // Each axis's table row is that axis's ring, position for position.
    for (index, dir) in [Float3(1, 0, 0), Float3(0, 1, 0), Float3(0, 0, 1)].enumerated() {
        let ring = GizmoBuilder.ring(axis: dir, radius: 0.9, thickness: 0.025, color: GizmoBuilder.colHi)
        #expect(ring.count == 48 * 12 && GizmoBuilder.rotateRings[index].count == ring.count)
        #expect(GizmoBuilder.rotateRings[index].map { [$0.x, $0.y, $0.z].map(\.bitPattern) } == ring.map { [$0.position.x, $0.position.y, $0.position.z].map(\.bitPattern) },
                "axis \(dir)")
    }
    // Whole gizmos: origins, orientations (local space passes the bone's
    // world rotation), sizes (pixels × world units per pixel × 90) and every
    // highlight, including axes a rotate gizmo has no ring for.
    let origins: [Float3] = [.zero, Float3(-0.0, -0.0, -0.0), Float3(-0.37, 1.25, -2.5), Float3(1e6, -3.5e5, 98765.43)]
    let orientations: [simd_quatf] = [.identity, simd_quatf(angle: 0.7, axis: normalize(Float3(1, 2, 3))),
                                      simd_quatf(angle: -2.9, axis: Float3(0, 1, 0)), simd_quatf(ix: 0.5, iy: -0.5, iz: 0.5, r: -0.5)]
    let sizes: [Float] = [1, 90 * 0.0123, 0.03, 250.7]
    let highlights: [GizmoAxis?] = [nil, .x, .y, .z, .xy, .all]
    var compared = 0
    for origin in origins {
        for orientation in orientations {
            for size in sizes {
                for highlight in highlights {
                    let table = GizmoBuilder.build(mode: .rotate, origin: origin, orientation: orientation, size: size, highlight: highlight)
                    let before = rotateBeforeTable(origin: origin, orientation: orientation, size: size, highlight: highlight)
                    #expect(table.count == 3 && before.count == 3)
                    for (t, b) in zip(table, before) {
                        #expect(t.primitive == b.primitive && t.depthTest == b.depthTest && t.objectID == b.objectID)
                        #expect(bits(t) == bits(b), "rotate at \(origin), \(orientation), size \(size), highlight \(String(describing: highlight))")
                        compared += 1
                    }
                }
            }
        }
    }
    #expect(compared == 4 * 4 * 4 * 6 * 3)
}
