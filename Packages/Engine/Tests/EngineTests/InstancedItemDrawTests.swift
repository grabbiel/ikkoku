import Testing
import Foundation
import Metal
import simd
import CoreGraphics
import Assets
import CoreMath
import Scene
import ShaderTypes
import GPU
import Character
import Studio
@testable import Renderer

// ST-T04 slice 1, part B: adjacent static item records that share mesh,
// pipeline, textures, cull and depth state and their whole MaterialUniforms
// draw as one instanced draw (`Renderer.instancesStaticItems`). B1: which
// records merge; B3: instanced frames render, shade, shadow and pick byte for
// byte like per-draw frames; B4: the Studio's item material cache.

/// A cube of half-size `half`: 6 faces of 4 vertices, outward normals,
/// counter-clockwise seen from outside.
private func cubeMesh(_ name: String, half: Float) -> MeshData {
    let faces: [(n: Float3, u: Float3, v: Float3)] = [
        (Float3(1, 0, 0), Float3(0, 0, -1), Float3(0, 1, 0)), (Float3(-1, 0, 0), Float3(0, 0, 1), Float3(0, 1, 0)),
        (Float3(0, 1, 0), Float3(1, 0, 0), Float3(0, 0, -1)), (Float3(0, -1, 0), Float3(1, 0, 0), Float3(0, 0, 1)),
        (Float3(0, 0, 1), Float3(1, 0, 0), Float3(0, 1, 0)), (Float3(0, 0, -1), Float3(-1, 0, 0), Float3(0, 1, 0)),
    ]
    var positions: [Float3] = [], normals: [Float3] = [], uvs: [Float2] = [], indices: [UInt32] = []
    for face in faces {
        let first = UInt32(positions.count)
        for (a, b, uv) in [(Float(-1), Float(-1), Float2(0, 1)), (1, -1, Float2(1, 1)), (1, 1, Float2(1, 0)), (-1, 1, Float2(0, 0))] {
            positions.append((face.n + face.u * a + face.v * b) * half); normals.append(face.n); uvs.append(uv)
        }
        indices += [first, first + 1, first + 2, first, first + 2, first + 3]
    }
    return MeshData(name: name, positions: positions, normals: normals, uvs: uvs, indices: indices)
}

/// A unit quad in the XY plane facing +Z.
private func quadMesh(_ name: String) -> MeshData {
    MeshData(name: name, positions: [Float3(-0.5, -0.5, 0), Float3(0.5, -0.5, 0), Float3(0.5, 0.5, 0), Float3(-0.5, 0.5, 0)],
             normals: [Float3](repeating: Float3(0, 0, 1), count: 4),
             uvs: [Float2(0, 1), Float2(1, 1), Float2(1, 0), Float2(0, 0)], indices: [0, 1, 2, 0, 2, 3])
}

/// RGBA8 16×16: a checkerboard of 4-pixel cells, alternately opaque and fully
/// transparent, so a MASK material discards half of every face.
private func checkerTexture(_ renderer: Renderer) throws -> TextureHandle {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 16, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let texture = try #require(renderer.gpu.device.makeTexture(descriptor: descriptor))
    var bytes = [UInt8](repeating: 255, count: 16 * 16 * 4)
    for y in 0..<16 { for x in 0..<16 where (x / 4 + y / 4) % 2 == 1 { bytes[(y * 16 + x) * 4 + 3] = 0 } }
    texture.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 16 * 4)
    return renderer.resources.register(texture: texture)
}

private func itemMaterial() -> MaterialState { MaterialState(uniforms: .make(kind: MaterialKindItem)) }

private func tinted(_ material: MaterialState, _ i: Int, alpha: Float = 1) -> MaterialState {
    var m = material
    let h = Float(i % 17) / 17, k = Float(i % 5) / 5
    m.uniforms.baseColor = Float4(0.3 + 0.6 * h, 0.9 - 0.5 * k, 0.4 + 0.4 * (1 - h), alpha)
    return m
}

private func trs(_ t: Float3, yaw: Float = 0, scale: Float3 = Float3(repeating: 1)) -> float4x4 {
    Transform.trs(t, simd_quatf(angle: yaw, axis: Float3(0, 1, 0)), scale)
}

// MARK: - B1: which records merge

/// The main pass's records and runs for `items`, instanced or not.
private func passCounts(_ renderer: Renderer, _ items: [RenderItem], instanced: Bool = true) throws -> RenderFrameStatistics {
    renderer.instancesStaticItems = instanced
    defer { renderer.instancesStaticItems = true }
    var effects = SceneEffects(); effects.showGrid = false
    let frame = RenderFrame(items: items, effects: effects)
    _ = try #require(renderer.capture(frame: frame, width: 32, height: 32), "\(String(describing: renderer.lastFrameError))")
    return renderer.lastFrameStatistics
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func instancedRunsBreakAtEveryRecordThatCannotMergeWithItsNeighbours() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let cube = try resources.register(mesh: cubeMesh("b1-cube", half: 0.1))
    let otherCube = try resources.register(mesh: cubeMesh("b1-cube-2", half: 0.1))
    let checker = try checkerTexture(renderer)
    func item(_ i: Int, order: Int, tint: Int = 0, _ edit: (inout RenderItem) -> Void = { _ in }) -> RenderItem {
        var ri = RenderItem(mesh: cube, material: tinted(itemMaterial(), tint), model: trs(Float3(Float(i) * 0.3 - 0.6, 0.9, 0)),
                            objectID: UInt32(10 + i))
        ri.order = order
        ri.staticItem = true
        edit(&ri)
        return ri
    }
    // Equal records, tint included, with different transforms and ids are one draw.
    let equal = try passCounts(renderer, [item(0, order: 0), item(1, order: 0), item(2, order: 0)])
    #expect(equal.mainPassRecords == 3 && equal.mainPassRuns == 1)
    #expect(equal.instancedRecords == 3 && equal.instancedRuns == 1)
    #expect(equal.shadowCasters == 3 && equal.shadowDraws == 1)
    // The per-draw reference: every record is its own draw.
    let perDraw = try passCounts(renderer, [item(0, order: 0), item(1, order: 0), item(2, order: 0)], instanced: false)
    #expect(perDraw.mainPassRuns == 3 && perDraw.instancedRuns == 0 && perDraw.shadowDraws == 3)
    // The offscreen benchmark reports the same counts for every measured sample (B2).
    var plain = SceneEffects(); plain.showGrid = false
    let benchmark = try renderer.benchmark(frame: RenderFrame(items: [item(0, order: 0), item(1, order: 0), item(2, order: 0)], effects: plain),
                                           width: 32, height: 32, warmupFrames: 1, measuredFrames: 2)
    for (name, value) in [("mainPassRecords", 3.0), ("mainPassRuns", 1), ("instancedRecords", 3), ("instancedRuns", 1),
                          ("shadowCasters", 3), ("shadowDraws", 1)] {
        #expect(benchmark.drawCounts[name]?.minimum == value && benchmark.drawCounts[name]?.maximum == value, "\(name)")
    }

    // The tint is part of the material: each adjacent stretch of one tint is
    // an instanced draw (one run, bound once, of two draws), and a record
    // with no equal neighbour is drawn on its own, as before.
    let tints = try passCounts(renderer, [item(0, order: 0, tint: 1), item(1, order: 0, tint: 1), item(2, order: 0, tint: 2),
                                          item(3, order: 0, tint: 2), item(4, order: 0, tint: 3)])
    #expect(tints.mainPassRuns == 3 && tints.instancedRuns == 2 && tints.instancedRecords == 4, "\(tints)")
    #expect(tints.shadowCasters == 5 && tints.shadowDraws == 3, "\(tints)")
    let ownTints = try passCounts(renderer, [item(0, order: 0, tint: 1), item(1, order: 0, tint: 2), item(2, order: 0, tint: 3)])
    #expect(ownTints.mainPassRuns == 3 && ownTints.instancedRuns == 0 && ownTints.instancedRecords == 0, "\(ownTints)")

    // A record sorted between two equal pairs (order 1 between 0 and 2) breaks
    // their draw, whether it is not instanceable at all or instanceable with
    // different bindings or state; on its own it is drawn per record.
    func pairs(_ odd: RenderItem) -> [RenderItem] { [item(0, order: 0), item(1, order: 0), odd, item(3, order: 2), item(4, order: 2)] }
    // Maps slice 5: per-vertex receive bytes (one per vertex of the 24-vertex cube).
    let receive = VertexBytes(buffer: try #require(renderer.gpu.device.makeBuffer(length: 24, options: .storageModeShared)))
    let notInstanceable: [(String, (inout RenderItem) -> Void)] = [
        ("not a Studio prop (a character part)", { $0.staticItem = false }),
        ("per-vertex receive bytes", { $0.vertexReceive = receive }),
        ("hidden regions", { $0.hiddenRegions = 1 }),
        ("hidden buffer key", { $0.hiddenKey = 77 }),
        ("deformation key", { $0.deformKey = 78 }),
        ("cloth material kind", { $0.material.uniforms.kind = UInt32(MaterialKindCloth.rawValue) }),
    ]
    for (label, edit) in notInstanceable {
        let counts = try passCounts(renderer, pairs(item(2, order: 1, edit)))
        #expect(counts.mainPassRuns == 3 && counts.instancedRuns == 2 && counts.instancedRecords == 4, "\(label): \(counts)")
    }
    // The guard itself (maps slice 5): a run binds its first record's buffers
    // once, so a record that brings its own receive bytes never instances,
    // even a static item that meets every other condition. Today only map
    // meshes carry them, and maps never instance.
    let gpuCube = try #require(resources.mesh(cube))
    #expect(Renderer.instanceable(item(2, order: 1), mesh: gpuCube, isSky: false))
    #expect(!Renderer.instanceable(item(2, order: 1) { $0.vertexReceive = receive }, mesh: gpuCube, isSky: false))
    let receiving = try passCounts(renderer, [item(0, order: 0) { $0.vertexReceive = receive }, item(1, order: 0) { $0.vertexReceive = receive },
                                              item(2, order: 0) { $0.vertexReceive = receive }])
    #expect(receiving.mainPassRuns == 3 && receiving.instancedRuns == 0 && receiving.instancedRecords == 0, "\(receiving)")
    let different: [(String, (inout RenderItem) -> Void)] = [
        ("another mesh", { $0.mesh = otherCube }),
        ("a base texture", { $0.material.base = checker; $0.material.setFlag(MaterialFlagHasBaseTexture, true) }),
        ("double-sided", { $0.material.setFlag(MaterialFlagDoubleSided, true) }),
        ("alpha test", { $0.material.setFlag(MaterialFlagAlphaTest, true); $0.material.uniforms.params.w = 0.5 }),
        ("a depth bias", { $0.material.depthBias = 0.01 }),
        ("another shadow colour", { $0.material.uniforms.shadowColor.x = 0.1 }),
        ("no outline", { $0.outline = false }),
        ("a mirrored model", { $0.model = $0.model * Transform.trs(.zero, .identity, Float3(-1, 1, 1)) }),
    ]
    for (label, edit) in different {
        let between = try passCounts(renderer, pairs(item(2, order: 1, edit)))
        #expect(between.mainPassRuns == 3 && between.instancedRuns == 2 && between.instancedRecords == 4, "\(label): \(between)")
        // The control: sorted after both pairs, the equal records are one draw again.
        let after = try passCounts(renderer, pairs(item(2, order: 3, edit)))
        #expect(after.mainPassRuns == 2 && after.instancedRuns == 1 && after.instancedRecords == 4, "\(label), after: \(after)")
    }
    // Shadow casters split a draw into stretches; a non-caster in the middle
    // leaves two shadow draws for one main-pass draw.
    let split = try passCounts(renderer, [item(0, order: 0), item(1, order: 0) { $0.castsShadow = false }, item(2, order: 0)])
    #expect(split.mainPassRuns == 1 && split.shadowCasters == 2 && split.shadowDraws == 2, "\(split)")

    // Transparent records merge in back-to-front order only: a record of
    // another material between two equal ones in distance breaks the draw.
    var glass = itemMaterial(); glass.transparent = true; glass.setFlag(MaterialFlagNoOutline, true)
    var frosted = glass; frosted.uniforms.specular.w = 4
    func pane(_ z: Float, _ material: MaterialState, _ i: Int) -> RenderItem {
        var ri = RenderItem(mesh: cube, material: tinted(material, 0, alpha: 0.5), model: trs(Float3(0, 0.9, z)), objectID: UInt32(40 + i))
        ri.staticItem = true
        return ri
    }
    let panes = try passCounts(renderer, [pane(-0.6, glass, 0), pane(-0.3, frosted, 1), pane(0, glass, 2), pane(0.3, glass, 3)])
    #expect(panes.mainPassRuns == 3 && panes.instancedRuns == 1 && panes.instancedRecords == 2, "\(panes)")
}

// MARK: - B3: byte for byte like per-draw records

/// 500 basic shapes on a grid above a ground quad: opaque cubes (a few of them
/// mirrored), alpha-tested cubes, and transparent quads of two materials whose
/// records interleave in distance. Every record has its own id; the shapes of
/// a row share a tint, so a mesh's run is one instanced draw per row, each with
/// its own material element. The quads of a material share one tint.
/// Coincident duplicates (later records at an identical transform, another
/// tint and id) check that the earlier record keeps the tied samples. A
/// column of transparent panes has an opaque record of the same mesh between
/// them in depth. Same-run shapes never intersect (see renderer.md,
/// "Instanced static items", for the one tie an instanced run resolves
/// differently).
private struct GridScene {
    var frame: RenderFrame
    var duplicateIDs: [UInt32] = []
    var originalIDs: [UInt32] = []
    var records: Int { frame.items.count }

    init(renderer: Renderer) throws {
        let resources = renderer.resources
        let ground = try resources.register(mesh: quadMesh("b3-ground"))
        let cube = try resources.register(mesh: cubeMesh("b3-cube", half: 0.05))
        let maskCube = try resources.register(mesh: cubeMesh("b3-mask-cube", half: 0.05))
        let pane = try resources.register(mesh: quadMesh("b3-pane"))
        let opaque = itemMaterial()
        var mask = itemMaterial()
        mask.base = try checkerTexture(renderer)
        mask.setFlag(MaterialFlagHasBaseTexture, true); mask.setFlag(MaterialFlagAlphaTest, true); mask.uniforms.params.w = 0.5
        var glass = itemMaterial()
        glass.transparent = true
        glass.setFlag(MaterialFlagNoOutline, true); glass.setFlag(MaterialFlagDoubleSided, true)
        var frosted = glass
        frosted.uniforms.specular = Float4(0.6, 0.7, 1, 6)

        var items: [RenderItem] = []
        var floor = RenderItem(mesh: ground, material: opaque, model: Transform.trs(.zero, simd_quatf(angle: -.pi / 2, axis: Float3(1, 0, 0)),
                                                                                     Float3(6, 6, 1)), objectID: 0)
        floor.castsShadow = false
        items.append(floor)
        var duplicates: [RenderItem] = []
        for i in 0..<500 {
            let column = i % 20, row = i / 20
            let at = Float3(-1.9 + 0.2 * Float(column), 0.06, -2.4 + 0.2 * Float(row))
            let id = UInt32(100 + i)
            var item: RenderItem
            let tint = 3 * row + 1
            switch i % 10 {
            case 0...4:
                let mirror: Float = i % 50 == 3 ? -1 : 1
                item = RenderItem(mesh: cube, material: tinted(opaque, tint), model: trs(at, yaw: Float(i) * 0.37, scale: Float3(mirror, 1, 1)), objectID: id)
            case 5, 6:
                item = RenderItem(mesh: maskCube, material: tinted(mask, tint), model: trs(at, yaw: Float(i) * 0.21), objectID: id)
            default:
                let material = i % 10 == 9 ? frosted : glass
                item = RenderItem(mesh: pane, material: tinted(material, i % 10 == 9 ? 2 : 0, alpha: i % 10 == 9 ? 0.6 : 0.4),
                                  model: trs(at + Float3(0, 0.03, 0), yaw: 0.3, scale: Float3(repeating: 0.12)), objectID: id)
            }
            item.order = 35
            items.append(item)
            if i % 50 == 1 || i % 50 == 7 {
                var twin = item
                twin.material = tinted(item.material, i + 7, alpha: item.material.uniforms.baseColor.w)
                twin.objectID = UInt32(1000 + i)
                duplicates.append(twin)
                if i % 50 == 1 { duplicateIDs.append(twin.objectID); originalIDs.append(id) }
            }
        }
        // Transparent panes at three depths with an opaque record of the same
        // mesh between the first two.
        for (k, z) in [Float(-0.9), -0.1, 0.7].enumerated() {
            var p = RenderItem(mesh: pane, material: tinted(glass, 600 + k, alpha: 0.55), model: trs(Float3(2.35, 0.35, z), scale: Float3(repeating: 0.7)),
                               objectID: UInt32(600 + k))
            p.order = 35
            items.append(p)
        }
        var solid = RenderItem(mesh: pane, material: tinted(opaque, 610), model: trs(Float3(2.5, 0.3, -0.5), scale: Float3(repeating: 0.6)), objectID: 610)
        solid.order = 35
        items.append(solid)
        items += duplicates
        // Every record is a Studio prop, as the frame builder marks item parts.
        for k in items.indices { items[k].staticItem = true }

        var camera = OrbitCamera()
        camera.target = Float3(0.25, 0.15, -0.1); camera.distance = 7; camera.yaw = 0.3; camera.pitch = 0.55
        var effects = SceneEffects(); effects.showGrid = false
        frame = RenderFrame(camera: camera, items: items, effects: effects,
                            sceneBounds: AABB(min: Float3(-3, 0, -3), max: Float3(3, 0.8, 3)))
    }
}

private struct Rendered {
    let hdr: [UInt16]
    let ldr: [UInt8]
    let pick: [UInt32]
    let statistics: RenderFrameStatistics
}

private func render(_ renderer: Renderer, _ frame: RenderFrame, instanced: Bool, skips: Bool = true,
                    size: (Int, Int) = (320, 240)) throws -> Rendered {
    renderer.instancesStaticItems = instanced
    renderer.skipsRedundantEncoderState = skips
    defer { renderer.instancesStaticItems = true; renderer.skipsRedundantEncoderState = true }
    let hdr = try #require(renderer.captureSceneHDR(frame: frame, width: size.0, height: size.1), "\(String(describing: renderer.lastFrameError))")
    let statistics = renderer.lastFrameStatistics
    let image = try #require(renderer.capture(frame: frame, width: size.0, height: size.1))
    let data = try #require(image.dataProvider?.data as Data?)
    let pick = try #require(renderer.pickTarget(frame: frame, size: size))
    return Rendered(hdr: hdr, ldr: [UInt8](data), pick: pick, statistics: statistics)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func instancedItemsShadeShadowAndPickByteForByteLikePerDrawRecords() throws {
    let renderer = try makeSourceShaderRenderer()
    let scene = try GridScene(renderer: renderer)
    let perDraw = try render(renderer, scene.frame, instanced: false)
    let instanced = try render(renderer, scene.frame, instanced: true)

    // The per-draw reference draws every record on its own; the instanced
    // frame merges most records into far fewer draws, in the shadow pass too.
    #expect(perDraw.statistics.instancedRuns == 0 && perDraw.statistics.mainPassRuns == scene.records)
    #expect(instanced.statistics.instancedRecords > scene.records * 3 / 4 && instanced.statistics.mainPassRecords == scene.records,
            "\(instanced.statistics)")
    // A row's tint is its own material, so a mesh draws once per row; most
    // transparent panes alternate with the other pane material in distance
    // and draw alone.
    #expect(instanced.statistics.mainPassRuns < scene.records / 2, "\(instanced.statistics)")
    #expect(instanced.statistics.shadowCasters == perDraw.statistics.shadowCasters)
    #expect(instanced.statistics.shadowDraws < perDraw.statistics.shadowDraws / 2, "\(instanced.statistics)")

    #expect(instanced.hdr == perDraw.hdr, "HDR scene differs at \(instanced.hdr.indices.filter { instanced.hdr[$0] != perDraw.hdr[$0] }.prefix(8))")
    #expect(instanced.ldr == perDraw.ldr, "LDR image differs")
    #expect(instanced.pick == perDraw.pick, "Pick ids differ at \(instanced.pick.indices.filter { instanced.pick[$0] != perDraw.pick[$0] }.prefix(8))")

    // The comparison covers what it should: the shadow map changes the image,
    // most shapes are pickable, and a coincident duplicate never takes the
    // earlier record's samples.
    var unshadowed = scene.frame
    unshadowed.mainLight.castsShadow = false
    let noShadow = try render(renderer, unshadowed, instanced: true)
    #expect(noShadow.hdr != instanced.hdr, "The shadow map does not reach the image")
    let ids = Set(instanced.pick)
    #expect(ids.filter { (100..<600).contains($0) }.count > 300, "\(ids.count) ids")
    // Near the camera the grid's outer columns leave the frame: one original
    // (id 401, column 1, row 20) projects left of the image, the other nine
    // fall inside it. Each one drawn keeps its samples.
    let visibleOriginals = scene.originalIDs.filter(ids.contains)
    #expect(visibleOriginals.count >= scene.originalIDs.count - 2, "\(visibleOriginals) of \(scene.originalIDs) in view")
    #expect(!scene.duplicateIDs.contains(where: ids.contains))
}

/// B3, coplanar outlined duplicates: one instanced run of outlined cubes that
/// coincide, share face planes or intersect, in two instanced draws (the first
/// five cubes in one tint, the last four in another). An exact twin; the same cube turned
/// 90° (the same faces, triangulated the other way); shifts of half and a whole
/// size (coplanar and touching faces); a slab lying on the top face; cubes a
/// little in front of others, so a later member's outline crosses an earlier
/// member's surface. Outlines are wide. Last, a record that is not a Studio prop
/// at the first cube's exact transform: drawn on its own in both frames, it ties
/// the first cube at every sample and never shows when both go through the same
/// vertex path, and shows wherever the instanced and per-draw paths round a
/// position differently.
private struct CoplanarCluster {
    var items: [RenderItem] = []
    var camera = OrbitCamera()
    var effects = SceneEffects()
    var members = 0
    var memberIDs: [UInt32] = []
    let perDrawTwinID: UInt32 = 300

    init(renderer: Renderer) throws {
        let resources = renderer.resources
        let cube = try resources.register(mesh: cubeMesh("b3-coplanar-cube", half: 0.1))
        let ground = try resources.register(mesh: quadMesh("b3-coplanar-ground"))
        let opaque = itemMaterial()
        let base = Float3(0, 0.1, 0)
        let transforms: [float4x4] = [
            trs(base),                                                  // the first member
            trs(base),                                                  // an exact twin
            trs(base, yaw: .pi / 2),                                    // the same faces, other triangulation
            trs(base + Float3(0.1, 0, 0)),                              // half a size along x: coplanar top, front and back
            trs(base + Float3(0.2, 0, 0)),                              // a whole size along x: touching faces
            trs(base + Float3(0, 0, 0.05)),                             // coplanar top and sides
            trs(base + Float3(0, 0.11, 0), scale: Float3(2, 0.1, 2)),   // a slab whose bottom is the top face (y = 0.2)
            trs(base + Float3(-0.03, 0.02, 0.04)),                      // just in front of the first ones
            trs(base + Float3(0.13, -0.01, 0.06), yaw: 0.2),
        ]
        var floor = RenderItem(mesh: ground, material: opaque,
                               model: Transform.trs(.zero, simd_quatf(angle: -.pi / 2, axis: Float3(1, 0, 0)), Float3(3, 3, 1)), objectID: 1)
        floor.castsShadow = false
        floor.order = 35
        floor.staticItem = true
        items.append(floor)
        for (k, model) in transforms.enumerated() {
            var member = RenderItem(mesh: cube, material: tinted(opaque, k < 5 ? 1 : 4), model: model, objectID: UInt32(200 + k))
            member.order = 35
            member.staticItem = true
            items.append(member)
            memberIDs.append(member.objectID)
        }
        members = transforms.count
        // Sorted after the members (same order, kind and mesh), so it never splits their run.
        var twin = RenderItem(mesh: cube, material: tinted(opaque, 40), model: transforms[0], objectID: perDrawTwinID)
        twin.order = 35
        items.append(twin)

        camera.target = Float3(0.1, 0.12, 0.02); camera.distance = 1.4; camera.yaw = 0.5; camera.pitch = 0.45
        effects.showGrid = false
        effects.outlineWidth = 3
    }

    func frame(_ items: [RenderItem]? = nil, outlineWidth: Float? = nil) -> RenderFrame {
        var fx = effects
        if let outlineWidth { fx.outlineWidth = outlineWidth }
        return RenderFrame(camera: camera, items: items ?? self.items, effects: fx,
                           sceneBounds: AABB(min: Float3(-1, 0, -1), max: Float3(1, 0.5, 1)))
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func coplanarOutlinedDuplicatesInOneRunDrawByteForByteLikePerDrawRecords() throws {
    let renderer = try makeSourceShaderRenderer()
    let scene = try CoplanarCluster(renderer: renderer)
    let perDraw = try render(renderer, scene.frame(), instanced: false)
    let instanced = try render(renderer, scene.frame(), instanced: true)

    // The cubes are one instanced run of two draws; the floor (another mesh)
    // and the twin (not a Studio prop) draw on their own.
    #expect(instanced.statistics.instancedRuns == 2 && instanced.statistics.instancedRecords == scene.members, "\(instanced.statistics)")
    #expect(instanced.statistics.mainPassRuns == 4 && perDraw.statistics.instancedRuns == 0, "\(instanced.statistics)")

    #expect(instanced.hdr == perDraw.hdr, "HDR scene differs at \(instanced.hdr.indices.filter { instanced.hdr[$0] != perDraw.hdr[$0] }.prefix(8))")
    #expect(instanced.ldr == perDraw.ldr, "LDR image differs")
    #expect(instanced.pick == perDraw.pick, "Pick ids differ at \(instanced.pick.indices.filter { instanced.pick[$0] != perDraw.pick[$0] }.prefix(8))")
    // The per-draw twin ties the first member everywhere and keeps none of its samples.
    #expect(!instanced.pick.contains(scene.perDrawTwinID) && !perDraw.pick.contains(scene.perDrawTwinID))

    // The comparison covers what it should. At least half the members show
    // (the exact twin never does); the tied samples follow the members' order
    // (reversed, the per-draw pick ids change: members of one draw share their
    // color, so a tie inside a draw shows only in the ids); the wide outlines
    // reach the image.
    let ids = Set(perDraw.pick)
    #expect(scene.memberIDs.filter(ids.contains).count >= scene.members / 2, "\(ids)")
    var reversed = scene.items
    reversed.replaceSubrange(1...scene.members, with: scene.items[1...scene.members].reversed())
    let perDrawReversed = try render(renderer, scene.frame(reversed), instanced: false)
    #expect(perDrawReversed.pick != perDraw.pick, "No tie between members is decided by their order")
    let noOutlines = try render(renderer, scene.frame(outlineWidth: 0), instanced: false)
    #expect(noOutlines.hdr != perDraw.hdr, "The outlines do not reach the image")
}

// MARK: - B4: the Studio's item material cache

@Test func sourceItemMaterialsAreBuiltOncePerAssetAndDroppedWithTheImport() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ikkoku-item-materials-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    // Two parts (two meshes, two materials) of one triangle each.
    var bytes = Data()
    for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }
    try bytes.write(to: base.appendingPathComponent("shape.bin"))
    let positions: [String: Any] = ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]]
    let normals: [String: Any] = ["bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"]
    let root: [String: Any] = [
        "asset": ["version": "2.0"], "buffers": [["byteLength": 72, "uri": "shape.bin"]],
        "bufferViews": [["buffer": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 36]],
        "accessors": [positions, normals],
        "materials": [["pbrMetallicRoughness": ["baseColorFactor": [1, 0.5, 0.25, 1]]],
                      ["pbrMetallicRoughness": ["baseColorFactor": [0.2, 0.4, 0.8, 0.5]], "alphaMode": "BLEND"]],
        "meshes": [["primitives": [["attributes": ["POSITION": 0, "NORMAL": 1], "material": 0]]],
                   ["primitives": [["attributes": ["POSITION": 0, "NORMAL": 1], "material": 1]]]],
        "nodes": [["mesh": 0], ["mesh": 1]], "scenes": [["nodes": [0, 1]]], "scene": 0]
    let url = base.appendingPathComponent("shape.gltf")
    try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)

    let gpu = try #require(GPUContext())
    let library = AssetLibrary(resources: ResourceStore(device: gpu.device), root: base)
    var cache = SourceStudioItemMaterials()
    let first = try library.importStaticAsset(url: url, packageRoot: base)
    #expect(first.parts.count == 2)
    let materials = cache.materials(for: first, file: url.path)
    // Exactly what the frame builder built on every refresh before the cache.
    #expect(materials == first.parts.map { MaterialBuilder.itemMaterial(for: $0, asset: first, tint: nil, emissive: 0) })
    #expect(materials[1].transparent && !materials[0].transparent)
    // Every later refresh reads the cache.
    for _ in 0..<5 { #expect(cache.materials(for: first, file: url.path) == materials) }
    #expect(cache.built == 2 && cache.count == 1)

    // Twelve imports of the same file: each replaces the library's asset (new
    // meshes), so its first lookup rebuilds, and the import's clear keeps the
    // cache at one file.
    var previous = first
    for cycle in 1...12 {
        cache.removeAll()
        #expect(cache.count == 0)
        let asset = try library.importStaticAsset(url: url, packageRoot: base)
        #expect(asset !== previous)
        let rebuilt = cache.materials(for: asset, file: url.path)
        #expect(rebuilt == asset.parts.map { MaterialBuilder.itemMaterial(for: $0, asset: asset, tint: nil, emissive: 0) })
        _ = cache.materials(for: asset, file: url.path)
        #expect(cache.count == 1 && cache.built == 2 * (cycle + 1), "cycle \(cycle)")
        previous = asset
    }
    // Without a clear, a replaced asset still rebuilds rather than returning
    // the previous instance's materials.
    let replaced = try library.importStaticAsset(url: url, packageRoot: base)
    _ = cache.materials(for: replaced, file: url.path)
    #expect(cache.count == 1 && cache.built == 2 * 14)
}

// MARK: - B2-v2: skipping repeated encoder state, instanced

/// The instanced grid scene, whose runs move material offsets in one bound
/// buffer (`EncoderState.setBufferOffsets`) and whose records switch
/// textures, cull and winding, renders, shades and picks byte for byte as
/// with every state set for every draw. `EncoderStateTests` covers records
/// drawn on their own.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func skippingRepeatedEncoderStateKeepsInstancedFramesByteForByte() throws {
    let renderer = try makeSourceShaderRenderer()
    let grid = try GridScene(renderer: renderer)
    let skipped = try render(renderer, grid.frame, instanced: true)
    let full = try render(renderer, grid.frame, instanced: true, skips: false)
    #expect(skipped.statistics.instancedRuns > 0)
    #expect(skipped.hdr == full.hdr && skipped.ldr == full.ldr && skipped.pick == full.pick)
}
