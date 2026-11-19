import Testing
import Foundation
import Metal
import simd
import Assets
import CoreMath
import ShaderTypes
@testable import GPU
@testable import Renderer

// B2-v2: `Renderer.assignRuns` and `Renderer.mergesWith` read the draw records
// in their array's buffer instead of copying each one. They must give exactly
// what the by-value versions gave: the same runs and instanced draws in the same
// order, the same instance tables and material elements, the same casters and
// the same counts.

// MARK: - The by-value versions, kept as the reference

private func referenceSameTexturesAndState(_ a: MaterialState, _ b: MaterialState) -> Bool {
    a.base == b.base && a.colorMask == b.colorMask && a.detail == b.detail && a.line == b.line && a.normal == b.normal
        && a.overlay0 == b.overlay0 && a.overlay1 == b.overlay1 && a.overlay2 == b.overlay2 && a.pattern == b.pattern
        && a.hairGloss == b.hairGloss && a.bodyMask == b.bodyMask && a.lightmap == b.lightmap
        && a.lightmapDirection == b.lightmapDirection && a.emission == b.emission && a.cubemap == b.cubemap
        && a.transparent == b.transparent && a.depthBias == b.depthBias
}

private func referenceEqualsApartFromBaseColor(_ a: MaterialState, _ b: MaterialState) -> Bool {
    let colour = MemoryLayout<MaterialUniforms>.offset(of: \.baseColor)!, after = colour + MemoryLayout<Float4>.size
    return withUnsafeBytes(of: a.uniforms) { x in withUnsafeBytes(of: b.uniforms) { y in
        memcmp(x.baseAddress!, y.baseAddress!, colour) == 0
            && memcmp(x.baseAddress! + after, y.baseAddress! + after, x.count - after) == 0
    } } && referenceSameTexturesAndState(a, b)
}

private func referenceMirrored(_ model: float4x4) -> Bool { simd_determinant(model.upperLeft3x3) < 0 }

private func referenceMergesWith(_ a: Renderer.DrawRecord, _ b: Renderer.DrawRecord) -> Bool {
    guard a.item.mesh == b.item.mesh, a.item.outline == b.item.outline,
          referenceMirrored(a.item.model) == referenceMirrored(b.item.model) else { return false }
    return referenceEqualsApartFromBaseColor(a.item.material, b.item.material)
}

private func referenceSameBytes(_ a: MaterialUniforms, _ b: MaterialUniforms) -> Bool {
    withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 } }
}

/// `Renderer.assignRuns` as it was before B2-v2, statement for statement, with
/// the pending uniforms and the ring passed in.
private func referenceAssignRuns(_ records: inout [Renderer.DrawRecord], casters: inout [Renderer.DrawRecord],
                                 pendingDraws: [DrawUniforms], pendingMaterials: [MaterialUniforms], frameRing: FrameRing,
                                 statistics: inout RenderFrameStatistics) throws -> [Range<Int>] {
    var draws: [Range<Int>] = []
    var members = 0
    var i = records.startIndex
    while i < records.endIndex {
        guard records[i].pending >= 0 else { i += 1; continue }
        var j = i + 1
        while j < records.endIndex, records[j].pending >= 0, referenceMergesWith(records[i], records[j]),
              referenceSameBytes(pendingMaterials[records[i].pending], pendingMaterials[records[j].pending]) { j += 1 }
        if j - i > 1 { draws.append(i..<j); members += j - i }
        i = j
    }
    statistics.mainPassRecords += records.count
    statistics.mainPassRuns += records.count - members + draws.count
    statistics.instancedRecords += members
    statistics.instancedRuns += draws.count
    let drawStride = MemoryLayout<DrawUniforms>.stride
    let materialStride = (MemoryLayout<MaterialUniforms>.stride + FrameRing.alignment - 1) / FrameRing.alignment * FrameRing.alignment
    let table = draws.isEmpty ? nil : try frameRing.allocate(byteCount: drawStride * members)
    let materials = draws.isEmpty ? nil : try frameRing.allocate(byteCount: materialStride * draws.count)
    var runs: [Range<Int>] = []
    runs.reserveCapacity(records.count - members + draws.count)
    var next = 0, instance = 0
    i = records.startIndex
    while i < records.endIndex {
        if next < draws.count, draws[next].lowerBound == i, let table, let materials {
            let run = runs.count
            var end = i
            repeat {
                let draw = draws[next]
                let element = materials.advanced(by: materialStride * next)
                element.buffer.contents().storeBytes(of: pendingMaterials[records[draw.lowerBound].pending], toByteOffset: element.offset,
                                                     as: MaterialUniforms.self)
                for k in draw {
                    table.buffer.contents().storeBytes(of: pendingDraws[records[k].pending], toByteOffset: table.offset + drawStride * instance,
                                                       as: DrawUniforms.self)
                    records[k].draw = table; records[k].material = element; records[k].instance = instance
                    records[k].pending = -1; records[k].run = run
                    instance += 1
                }
                end = draw.upperBound
                next += 1
            } while next < draws.count && draws[next].lowerBound == end && referenceMergesWith(records[i], records[end])
            runs.append(i..<end)
            i = end
            continue
        }
        if records[i].pending >= 0 {
            let index = records[i].pending
            records[i].draw = try frameRing.allocate(pendingDraws[index])
            records[i].material = try frameRing.allocate(pendingMaterials[index])
            records[i].pending = -1
            if records[i].item.castsShadow && !records[i].item.material.transparent { casters.append(records[i]) }
        }
        runs.append(i..<i + 1)
        i += 1
    }
    return runs
}

// MARK: - Frames

/// A few values per field, so neighbours often merge and often differ in
/// exactly one condition. Each record's DrawUniforms are its own (its model and
/// object id); its pending MaterialUniforms are its material's uniforms,
/// sometimes with one flag changed, as preparation adjusts the flags.
private struct Frame {
    var records: [Renderer.DrawRecord] = []
    var pendingDraws: [DrawUniforms] = []
    var pendingMaterials: [MaterialUniforms] = []
}

private final class Fixture {
    let device: any MTLDevice
    let resources: ResourceStore
    let meshes: [(handle: MeshHandle, mesh: GPUMesh)]
    let allocation: FrameAllocation

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        resources = ResourceStore(device: device)
        let tri = MeshData(name: "runs-tri", positions: [Float3(0, 0, 0), Float3(1, 0, 0), Float3(1, 1, 0)],
                           normals: [Float3](repeating: Float3(0, 0, 1), count: 3), uvs: [Float2](repeating: .zero, count: 3),
                           indices: [0, 1, 2])
        var meshes: [(MeshHandle, GPUMesh)] = []
        for k in 0..<2 {
            var data = tri
            data.name = "runs-tri-\(k)"
            let handle = try resources.register(mesh: data)
            meshes.append((handle, try #require(resources.mesh(handle))))
        }
        self.meshes = meshes
        allocation = FrameAllocation(buffer: resources.dummyBuffer, offset: 0)
    }

    func ring() throws -> FrameRing {
        let ring = try #require(FrameRing(device: device, regionSize: 8 << 20, regionCount: 1))
        ring.beginFrame(0)
        return ring
    }

    /// One record. `variant` picks one condition of `mergesWith` to differ
    /// from the common record (0 changes nothing), `tint` the base colour.
    func record(_ index: Int, variant: Int, tint: Int, pending: Bool, castsShadow: Bool, flagTweak: Bool,
                into frame: inout Frame) -> Renderer.DrawRecord {
        var material = MaterialState(uniforms: .make(kind: MaterialKindItem))
        var mesh = meshes[0]
        var model = Transform.trs(Float3(Float(index) * 0.01, 0, 0), simd_quatf(angle: 0, axis: Float3(0, 1, 0)), Float3(repeating: 1))
        var outline = true
        switch variant {
        case 1: mesh = meshes[1]
        case 2: outline = false
        case 3: model.columns.0 = -model.columns.0                       // mirrored
        case 4: material.base = TextureHandle(id: 7)
        case 5: material.bodyMask = TextureHandle(id: 8)
        case 6: material.cubemap = TextureHandle(id: 9)
        case 7: material.transparent = true
        case 8: material.depthBias = 0.002
        case 9: material.uniforms.flags |= MaterialFlagDoubleSided.rawValue  // a uniforms byte after the base colour
        case 10: material.uniforms.oneMinusReflectivity = 0.5                // the uniforms' last field
        case 11: material.uniforms.shadowColor.x += 0.25                     // the field right after the base colour
        default: break
        }
        material.uniforms.baseColor = Float4(0.2 + 0.1 * Float(tint), 0.5, 0.7, 1)
        var item = RenderItem(mesh: mesh.handle, material: material, model: model, objectID: UInt32(index + 1))
        item.outline = outline
        item.castsShadow = castsShadow
        item.staticItem = true
        var record = Renderer.DrawRecord(item: item, mesh: mesh.mesh, vertexBuffer: mesh.mesh.baseVertices, hiddenBuffer: nil,
                                         draw: allocation, material: allocation, distance: Float(index % 5))
        if pending {
            var du = DrawUniforms()
            du.model = model
            du.normalMatrix = Transform.normalMatrix(from: model)
            du.objectID = item.objectID
            var mu = material.uniforms
            if flagTweak { mu.flags ^= MaterialFlagHasVertexColor.rawValue }
            record.pending = frame.pendingDraws.count
            frame.pendingDraws.append(du)
            frame.pendingMaterials.append(mu)
        }
        return record
    }
}

/// A seeded frame of `count` records: mostly instanceable common records with
/// a few tints, and some that differ in one condition or are not instanceable.
private func seededFrame(_ fixture: Fixture, count: Int, seed: UInt64) -> Frame {
    var state = seed &* 0x9E3779B97F4A7C15 | 1
    func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
    var frame = Frame()
    for index in 0..<count {
        let variant = next(3) == 0 ? next(12) : 0
        let record = fixture.record(index, variant: variant, tint: next(3), pending: next(8) != 0, castsShadow: next(6) != 0,
                                    flagTweak: next(20) == 0, into: &frame)
        frame.records.append(record)
    }
    return frame
}

// MARK: - Comparison

private struct Assigned {
    var records: [Renderer.DrawRecord]
    var casters: [Renderer.DrawRecord]
    var runs: [Range<Int>]
    var statistics: RenderFrameStatistics
    let ring: FrameRing
}

private func assign(_ frame: Frame, _ fixture: Fixture, reference: Bool) throws -> Assigned {
    var records = frame.records, casters: [Renderer.DrawRecord] = [], statistics = RenderFrameStatistics()
    let ring = try fixture.ring()
    let runs = reference
        ? try referenceAssignRuns(&records, casters: &casters, pendingDraws: frame.pendingDraws,
                                  pendingMaterials: frame.pendingMaterials, frameRing: ring, statistics: &statistics)
        : try Renderer.assignRuns(&records, casters: &casters, draws: frame.pendingDraws, materials: frame.pendingMaterials,
                                  ring: ring, statistics: &statistics)
    return Assigned(records: records, casters: casters, runs: runs, statistics: statistics, ring: ring)
}

private func bytes(_ allocation: FrameAllocation, at offset: Int, count: Int) -> [UInt8] {
    Array(UnsafeRawBufferPointer(start: allocation.buffer.contents() + allocation.offset + offset, count: count))
}

/// The record's DrawUniforms and MaterialUniforms as the GPU reads them: its
/// element of the table when it is drawn instanced, its own allocations otherwise.
private func uniformBytes(_ record: Renderer.DrawRecord) -> (draw: [UInt8], material: [UInt8]) {
    let drawOffset = record.instanced ? MemoryLayout<DrawUniforms>.stride * record.instance : 0
    return (bytes(record.draw, at: drawOffset, count: MemoryLayout<DrawUniforms>.size),
            bytes(record.material, at: 0, count: MemoryLayout<MaterialUniforms>.size))
}

/// Everything `assignRuns` decides, equal in both results; also each record's
/// uniforms are the bytes it was pending with.
private func expectSame(_ new: Assigned, _ old: Assigned, _ frame: Frame, _ label: String) {
    #expect(new.runs == old.runs, "runs, \(label)")
    #expect(new.statistics.mainPassRecords == old.statistics.mainPassRecords && new.statistics.mainPassRuns == old.statistics.mainPassRuns
            && new.statistics.instancedRecords == old.statistics.instancedRecords
            && new.statistics.instancedRuns == old.statistics.instancedRuns, "counts, \(label)")
    #expect(new.ring.frameStatistics == old.ring.frameStatistics, "ring allocations, \(label)")
    #expect(new.records.count == old.records.count && new.casters.count == old.casters.count, "sizes, \(label)")
    guard new.records.count == old.records.count, new.casters.count == old.casters.count else { return }
    for (k, (a, b)) in zip(new.records, old.records).enumerated() {
        #expect(a.item.objectID == b.item.objectID && a.mesh === b.mesh && a.vertexBuffer === b.vertexBuffer
                && a.draw.offset == b.draw.offset && a.material.offset == b.material.offset && a.instance == b.instance
                && a.pending == b.pending && a.run == b.run && a.distance == b.distance, "record \(k), \(label)")
        #expect((a.draw.buffer === new.ring.buffer) == (b.draw.buffer === old.ring.buffer)
                && (a.material.buffer === new.ring.buffer) == (b.material.buffer === old.ring.buffer), "record \(k)'s buffers, \(label)")
        // A record that was not pending keeps the allocations it came with.
        let original = frame.records[k]
        if original.pending >= 0 {
            let (newBytes, oldBytes) = (uniformBytes(a), uniformBytes(b))
            #expect(newBytes.draw == oldBytes.draw && newBytes.material == oldBytes.material, "record \(k)'s uniforms, \(label)")
            let draw = withUnsafeBytes(of: frame.pendingDraws[original.pending]) { Array($0) }
            let material = withUnsafeBytes(of: frame.pendingMaterials[original.pending]) { Array($0) }
            #expect(newBytes.draw == draw && newBytes.material == material, "record \(k)'s pending uniforms, \(label)")
        }
    }
    for (k, (a, b)) in zip(new.casters, old.casters).enumerated() {
        #expect(a.item.objectID == b.item.objectID && a.draw.offset == b.draw.offset && a.material.offset == b.material.offset
                && a.instance == b.instance && a.run == b.run, "caster \(k), \(label)")
    }
}

// MARK: - Tests

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func mergesWithReadInPlaceIsTheByValuePredicate() throws {
    let fixture = try Fixture()
    var frame = Frame()
    // Every pair of variants and tints, the base colour alone included: the
    // predicate read in place agrees with the by-value one on every pair, and
    // only the base colour (tint) may differ between records that merge.
    var records: [Renderer.DrawRecord] = []
    for variant in 0..<12 {
        for tint in 0..<2 {
            records.append(fixture.record(records.count, variant: variant, tint: tint, pending: true, castsShadow: true,
                                          flagTweak: false, into: &frame))
        }
    }
    var agreeing = 0, merging = 0
    records.withUnsafeBufferPointer { p in
        for i in p.indices {
            for j in p.indices {
                let inPlace = Renderer.mergesWith(p.baseAddress! + i, p.baseAddress! + j)
                let byValue = referenceMergesWith(p[i], p[j])
                #expect(inPlace == byValue, "records \(i) and \(j)")
                if inPlace == byValue { agreeing += 1 }
                if inPlace { merging += 1 }
                // Same variant, any tint: they merge. Different variants (one condition differs): they do not.
                #expect(inPlace == (i / 2 == j / 2), "records \(i) and \(j)")
            }
        }
    }
    #expect(agreeing == records.count * records.count && merging == records.count * 2)
    // The by-value comparison of MaterialState agrees too.
    for a in records { for b in records {
        #expect(a.item.material.equalsApartFromBaseColor(b.item.material) == referenceEqualsApartFromBaseColor(a.item.material, b.item.material))
    } }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func assignRunsInPlaceEqualsTheByValueVersionOnSeededFrames() throws {
    let fixture = try Fixture()
    var instanced = 0, ownDraws = 0
    for seed in UInt64(0)..<200 {
        let count = Int(seed % 7 == 0 ? seed * 3 % 400 : seed % 61)
        let frame = seededFrame(fixture, count: count, seed: seed)
        let new = try assign(frame, fixture, reference: false), old = try assign(frame, fixture, reference: true)
        expectSame(new, old, frame, "seed \(seed), \(count) records")
        instanced += new.statistics.instancedRuns
        ownDraws += new.statistics.mainPassRuns - new.statistics.instancedRuns
    }
    // The frames exercise both kinds of run.
    #expect(instanced > 100 && ownDraws > 100, "\(instanced) instanced runs, \(ownDraws) records on their own")
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func assignRunsInPlaceEqualsTheByValueVersionOnEdgeFrames() throws {
    let fixture = try Fixture()
    func frame(_ count: Int, _ make: (Int, inout Frame) -> Renderer.DrawRecord) -> Frame {
        var frame = Frame()
        for index in 0..<count { let record = make(index, &frame); frame.records.append(record) }
        return frame
    }
    // Expected: records, draws (`mainPassRuns`: a record on its own or an
    // instanced draw), runs (an instanced run binds once for all its draws) and
    // instanced draws (`instancedRuns`).
    let frames: [(String, Frame, (records: Int, draws: Int, runs: Int, instanced: Int))] = [
        ("no records", frame(0) { _, _ in fatalError() }, (0, 0, 0, 0)),
        ("one pending record", frame(1) { fixture.record($0, variant: 0, tint: 0, pending: true, castsShadow: true, flagTweak: false, into: &$1) },
         (1, 1, 1, 0)),
        ("one record not instanceable", frame(1) { fixture.record($0, variant: 0, tint: 0, pending: false, castsShadow: true, flagTweak: false, into: &$1) },
         (1, 1, 1, 0)),
        ("all mergeable, one tint: one draw", frame(64) { fixture.record($0, variant: 0, tint: 0, pending: true, castsShadow: true, flagTweak: false, into: &$1) },
         (64, 1, 1, 1)),
        ("all mergeable, a tint per pair: one run of 32 draws",
         frame(64) { fixture.record($0, variant: 0, tint: $0 / 2, pending: true, castsShadow: true, flagTweak: false, into: &$1) },
         (64, 32, 1, 32)),
        ("none mergeable: alternating meshes",
         frame(64) { fixture.record($0, variant: $0 % 2, tint: 0, pending: true, castsShadow: true, flagTweak: false, into: &$1) },
         (64, 64, 64, 0)),
        ("none mergeable: every tint differs",
         frame(64) { fixture.record($0, variant: 0, tint: $0, pending: true, castsShadow: true, flagTweak: false, into: &$1) },
         (64, 64, 64, 0)),
        ("none instanceable", frame(64) { fixture.record($0, variant: 0, tint: 0, pending: false, castsShadow: true, flagTweak: false, into: &$1) },
         (64, 64, 64, 0)),
    ]
    for (label, frame, expected) in frames {
        let new = try assign(frame, fixture, reference: false), old = try assign(frame, fixture, reference: true)
        expectSame(new, old, frame, label)
        #expect(new.statistics.mainPassRecords == expected.records && new.statistics.mainPassRuns == expected.draws
                && new.runs.count == expected.runs && new.statistics.instancedRuns == expected.instanced,
                "\(label): \(new.statistics.mainPassRecords) records, \(new.statistics.mainPassRuns) draws, \(new.runs.count) runs, \(new.statistics.instancedRuns) instanced")
    }
}
