import Testing
import Foundation
import Metal
import simd
import Assets
import CoreMath
import ShaderTypes
@testable import GPU
@testable import Renderer

// Frame preparation sorts small keys instead of whole draw records
// (`Renderer.sortedOpaque`, `Renderer.sortedTransparent`). The order must be
// the one the record sort gave: the same comparison, and records that compare
// equal in their input order.

/// The record sorts as they were before the key sorts, kept as the reference.
private func referenceOpaque(_ records: [Renderer.DrawRecord]) -> [Renderer.DrawRecord] {
    records.sorted { a, b in
        if a.item.order != b.item.order { return a.item.order < b.item.order }
        if a.item.material.uniforms.kind != b.item.material.uniforms.kind { return a.item.material.uniforms.kind < b.item.material.uniforms.kind }
        return a.item.mesh.id < b.item.mesh.id
    }
}

private func referenceTransparent(_ records: [Renderer.DrawRecord]) -> [Renderer.DrawRecord] {
    records.sorted {
        if $0.item.renderQueue != $1.item.renderQueue { return $0.item.renderQueue < $1.item.renderQueue }
        if $0.distance != $1.distance { return $0.distance > $1.distance }
        if $0.item.order != $1.item.order { return $0.item.order < $1.item.order }
        return $0.item.mesh.id < $1.item.mesh.id
    }
}

/// Records drawn from a few values per key, so most keys tie with others. The
/// object id is the record's input index plus one.
private func records(_ count: Int, seed: UInt64) throws -> [Renderer.DrawRecord] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let resources = ResourceStore(device: device)
    let quad = MeshData(name: "order-quad", positions: [Float3(0, 0, 0), Float3(1, 0, 0), Float3(1, 1, 0)],
                        normals: [Float3](repeating: Float3(0, 0, 1), count: 3), uvs: [Float2](repeating: .zero, count: 3), indices: [0, 1, 2])
    var handles: [MeshHandle] = []
    for k in 0..<3 {
        var data = quad
        data.name = "order-quad-\(k)"
        handles.append(try resources.register(mesh: data))
    }
    let allocation = FrameAllocation(buffer: resources.dummyBuffer, offset: 0)
    let kinds = [MaterialKindItem, MaterialKindCloth, MaterialKindHair]
    var state = seed
    func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
    return try (0..<count).map { index in
        let handle = handles[next(3)]
        let mesh = try #require(resources.mesh(handle))
        var item = RenderItem(mesh: handle, material: MaterialState(uniforms: .make(kind: kinds[next(3)])),
                              model: matrix_identity_float4x4, objectID: UInt32(index + 1))
        item.order = [0, 35, 35, 100][next(4)]
        item.renderQueue = [2450, 3000, 3000, 4099][next(4)]
        return Renderer.DrawRecord(item: item, mesh: mesh, vertexBuffer: mesh.baseVertices, hiddenBuffer: nil, draw: allocation,
                                   material: allocation, distance: [1, 2, 2, 3.5][next(4)])
    }
}

/// Whether `sorted` is `input` sorted by `before` with equal records in input
/// order: a permutation whose neighbours are each strictly ordered, or equal
/// with the earlier input first. Also returns how many neighbours were equal.
private func stablySorted(_ sorted: [Renderer.DrawRecord], of input: [Renderer.DrawRecord],
                          by before: (Renderer.DrawRecord, Renderer.DrawRecord) -> Bool) -> (Bool, Int) {
    guard sorted.map(\.item.objectID).sorted() == input.map(\.item.objectID) else { return (false, 0) }
    var ties = 0
    for (a, b) in zip(sorted, sorted.dropFirst()) {
        if before(b, a) { return (false, ties) }
        if !before(a, b) {
            ties += 1
            if a.item.objectID > b.item.objectID { return (false, ties) }
        }
    }
    return (true, ties)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func keySortsGiveTheRecordSortOrderTiesIncluded() throws {
    let opaqueBefore: (Renderer.DrawRecord, Renderer.DrawRecord) -> Bool = { a, b in
        (a.item.order, a.item.material.uniforms.kind, a.item.mesh.id) < (b.item.order, b.item.material.uniforms.kind, b.item.mesh.id)
    }
    let transparentBefore: (Renderer.DrawRecord, Renderer.DrawRecord) -> Bool = { a, b in
        if a.item.renderQueue != b.item.renderQueue { return a.item.renderQueue < b.item.renderQueue }
        if a.distance != b.distance { return a.distance > b.distance }
        return (a.item.order, a.item.mesh.id) < (b.item.order, b.item.mesh.id)
    }
    for (count, seed) in [(0, UInt64(1)), (1, 2), (2, 3), (17, 4), (64, 5), (1_000, 6), (3_506, 7)] {
        let input = try records(count, seed: seed)
        let opaque = Renderer.sortedOpaque(input)
        #expect(opaque.map(\.item.objectID) == referenceOpaque(input).map(\.item.objectID), "opaque, \(count) records")
        let (opaqueStable, opaqueTies) = stablySorted(opaque, of: input, by: opaqueBefore)
        #expect(opaqueStable, "opaque, \(count) records")
        let transparent = Renderer.sortedTransparent(input)
        #expect(transparent.map(\.item.objectID) == referenceTransparent(input).map(\.item.objectID), "transparent, \(count) records")
        let (transparentStable, transparentTies) = stablySorted(transparent, of: input, by: transparentBefore)
        #expect(transparentStable, "transparent, \(count) records")
        // The check covers ties: most neighbours compare equal once there are
        // more records than keys (36 opaque keys, 48 transparent ones).
        if count >= 1_000 { #expect(opaqueTies > count / 2 && transparentTies > count / 2, "\(opaqueTies), \(transparentTies) ties") }
        // The records come out whole: each one is its input record.
        for record in opaque + transparent {
            let original = input[Int(record.item.objectID) - 1]
            #expect(record.item.mesh == original.item.mesh && record.distance == original.distance && record.mesh === original.mesh)
        }
    }
}
