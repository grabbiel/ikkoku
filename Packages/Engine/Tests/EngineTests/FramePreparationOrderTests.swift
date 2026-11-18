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

// MARK: - Records moved in place (B2-v2)

// The sorts put the records into their order with `Renderer.permute`, which
// moves each record once along the permutation's cycles instead of mapping
// copies into a new array. The result must be the old map sort's, every record
// whole, at every size, with ties, and for any permutation.

/// The key sorts as they were before B2-v2: the same keys, then each record
/// copied into a new array.
private func referenceMappedOpaque(_ records: [Renderer.DrawRecord]) -> [Renderer.DrawRecord] {
    var keys: [(order: Int, kind: UInt32, mesh: UInt32, index: Int)] = []
    for index in records.indices {
        keys.append((records[index].item.order, records[index].item.material.uniforms.kind, records[index].item.mesh.id, index))
    }
    keys.sort { a, b in
        if a.order != b.order { return a.order < b.order }
        if a.kind != b.kind { return a.kind < b.kind }
        if a.mesh != b.mesh { return a.mesh < b.mesh }
        return a.index < b.index
    }
    return keys.map { records[$0.index] }
}

private func referenceMappedTransparent(_ records: [Renderer.DrawRecord]) -> [Renderer.DrawRecord] {
    var keys: [(queue: Int, distance: Float, order: Int, mesh: UInt32, index: Int)] = []
    for index in records.indices {
        keys.append((records[index].item.renderQueue, records[index].distance, records[index].item.order, records[index].item.mesh.id, index))
    }
    keys.sort { a, b in
        if a.queue != b.queue { return a.queue < b.queue }
        if a.distance != b.distance { return a.distance > b.distance }
        if a.order != b.order { return a.order < b.order }
        if a.mesh != b.mesh { return a.mesh < b.mesh }
        return a.index < b.index
    }
    return keys.map { records[$0.index] }
}

/// Whether two records are the same record: every field of it and of its item.
private func sameRecord(_ a: Renderer.DrawRecord, _ b: Renderer.DrawRecord) -> Bool {
    let x = a.item, y = b.item
    let item = x.mesh == y.mesh && x.material == y.material && x.model == y.model && x.objectID == y.objectID
        && x.deformKey == y.deformKey && x.skinSet == y.skinSet && x.morphWeights.count == y.morphWeights.count
        && zip(x.morphWeights, y.morphWeights).allSatisfy { $0.index == $1.index && $0.weight == $1.weight }
        && x.castsShadow == y.castsShadow && x.outline == y.outline && x.outlineScale == y.outlineScale && x.visible == y.visible
        && x.hiddenRegions == y.hiddenRegions && x.hiddenKey == y.hiddenKey && x.order == y.order
        && (x.sourceShader == nil) == (y.sourceShader == nil) && x.pickOccluder == y.pickOccluder && x.sortCenter == y.sortCenter
        && x.renderQueue == y.renderQueue && x.staticItem == y.staticItem
    return item && a.mesh === b.mesh && a.vertexBuffer === b.vertexBuffer && a.hiddenBuffer === b.hiddenBuffer
        && a.draw.buffer === b.draw.buffer && a.draw.offset == b.draw.offset
        && a.material.buffer === b.material.buffer && a.material.offset == b.material.offset
        && a.instance == b.instance && a.distance.bitPattern == b.distance.bitPattern && a.pending == b.pending && a.run == b.run
}

/// `records(count:seed:)` with every other field of each record its own: its
/// allocations' offsets, instance, pending index, run, a tint, morph weights,
/// and for every seventh record a hidden buffer of its own.
private func distinctRecords(_ count: Int, seed: UInt64, device: any MTLDevice) throws -> [Renderer.DrawRecord] {
    try records(count, seed: seed).enumerated().map { index, record in
        var item = record.item
        item.material.uniforms.baseColor = Float4(Float(index % 11) / 11, 0.5, 0.25, 1)
        item.morphWeights = index % 3 == 0 ? [(index: index, weight: Float(0.5))] : []
        item.castsShadow = index % 4 != 0
        let hidden: (any MTLBuffer)? = index % 7 == 0 ? device.makeBuffer(length: 16, options: .storageModeShared) : nil
        return Renderer.DrawRecord(item: item, mesh: record.mesh, vertexBuffer: record.vertexBuffer, hiddenBuffer: hidden,
                                   draw: record.draw.advanced(by: 256 * index), material: record.material.advanced(by: 512 * index),
                                   instance: index, distance: record.distance, pending: index % 9 - 1, run: index % 5 - 1)
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func sortsInPlaceGiveTheMappedSortWithEveryRecordWhole() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    for (count, seed) in [(0, UInt64(11)), (1, 12), (2, 13), (3, 14), (17, 15), (64, 16), (1_000, 17), (3_506, 18)] {
        let input = try distinctRecords(count, seed: seed, device: device)
        for (label, sorted, reference) in [("opaque", Renderer.sortedOpaque(input), referenceMappedOpaque(input)),
                                           ("transparent", Renderer.sortedTransparent(input), referenceMappedTransparent(input))] {
            #expect(sorted.count == reference.count, "\(label), \(count) records")
            let mismatches = zip(sorted, reference).filter { !sameRecord($0, $1) }.count
            #expect(mismatches == 0, "\(label), \(count) records: \(mismatches) records differ from the mapped sort")
        }
        // The input is left as it was (the sorts work on their own copy).
        #expect(zip(input, try distinctRecords(count, seed: seed, device: device)).allSatisfy {
            $0.item.objectID == $1.item.objectID && $0.instance == $1.instance
        })
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func permuteMovesEveryRecordToItsPlaceForAnyPermutation() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    var state: UInt64 = 0x5EED
    func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
    func shuffled(_ n: Int) -> [Int] {
        var order = Array(0..<n)
        if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { order.swapAt(i, next(i + 1)) } }
        return order
    }
    var weakBuffers: [() -> (any MTLBuffer)?] = []
    var checked = 0
    for n in [0, 1, 2, 3, 5, 10, 100, 1_000, 3_506] {
        var permutations: [(String, [Int])] = [
            ("identity", Array(0..<n)),
            ("reversed", Array((0..<n).reversed())),
            ("one cycle", (0..<n).map { ($0 + 1) % max(n, 1) }),
        ]
        // Mostly in place: a few swapped pairs among fixed points.
        var fewSwaps = Array(0..<n)
        if n > 1 { for _ in 0..<max(1, n / 20) { fewSwaps.swapAt(next(n), next(n)) } }
        permutations.append(("a few swaps", fewSwaps))
        for k in 0..<5 { permutations.append(("shuffle \(k)", shuffled(n))) }
        for (label, order) in permutations {
            let input = try distinctRecords(n, seed: UInt64(n * 31 + label.count), device: device)
            for record in input where record.hiddenBuffer != nil {
                weak let buffer = record.hiddenBuffer
                weakBuffers.append { buffer }
            }
            var moved = input
            Renderer.permute(&moved) { order[$0] }
            #expect(moved.count == n, "\(label), \(n)")
            let wrong = (0..<n).filter { !sameRecord(moved[$0], input[order[$0]]) }.count
            #expect(wrong == 0, "\(label), \(n) records: \(wrong) records out of place or changed")
            // The original array is untouched (`moved` was its own copy before the moves).
            #expect((0..<n).allSatisfy { input[$0].instance == $0 }, "\(label), \(n)")
            checked += n
        }
    }
    #expect(checked > 40_000)
    // Every record was released exactly as often as it was retained: once the
    // arrays are gone, no hidden buffer is left alive.
    #expect(weakBuffers.allSatisfy { $0() == nil }, "a record moved by permute was leaked")
}
