import Testing
import Foundation
import Metal
import simd
import CoreGraphics
import Assets
import CoreMath
import Scene
import ShaderTypes
@testable import Renderer

// Frame preparation, step 6: the shadow, main, overlay and pick passes skip an
// encoder call that repeats the state the encoder already holds (`EncoderState`,
// `Renderer.skipsRedundantEncoderState`). A frame must render, shade and pick
// byte for byte as it does with every state set for every draw.

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

/// RGBA8 4×4 of one opaque colour.
private func solidTexture(_ renderer: Renderer, _ rgba: [UInt8]) throws -> TextureHandle {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let texture = try #require(renderer.gpu.device.makeTexture(descriptor: descriptor))
    let bytes = [UInt8]((0..<16).flatMap { _ in rgba })
    texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 4 * 4)
    return renderer.resources.register(texture: texture)
}

private func itemMaterial() -> MaterialState { MaterialState(uniforms: .make(kind: MaterialKindItem)) }

private func tinted(_ material: MaterialState, _ i: Int) -> MaterialState {
    var m = material
    let h = Float(i % 17) / 17, k = Float(i % 5) / 5
    m.uniforms.baseColor = Float4(0.3 + 0.6 * h, 0.9 - 0.5 * k, 0.4 + 0.4 * (1 - h), m.uniforms.baseColor.w)
    return m
}

private func textured(_ handle: TextureHandle) -> (inout MaterialState) -> Void {
    { $0.base = handle; $0.setFlag(MaterialFlagHasBaseTexture, true) }
}

private func doubleSided(_ material: inout MaterialState) { material.setFlag(MaterialFlagDoubleSided, true) }

private func trs(_ t: Float3, yaw: Float = 0, scale: Float3 = Float3(repeating: 1)) -> float4x4 {
    Transform.trs(t, simd_quatf(angle: yaw, axis: Float3(0, 1, 0)), scale)
}

private struct Rendered {
    let hdr: [UInt16]
    let ldr: [UInt8]
    let pick: [UInt32]
}

/// The frame's HDR scene, LDR capture and pick ids, with or without skipping.
private func render(_ renderer: Renderer, _ frame: RenderFrame, skips: Bool, size: (Int, Int) = (320, 240)) throws -> Rendered {
    renderer.skipsRedundantEncoderState = skips
    defer { renderer.skipsRedundantEncoderState = true }
    let hdr = try #require(renderer.captureSceneHDR(frame: frame, width: size.0, height: size.1), "\(String(describing: renderer.lastFrameError))")
    let image = try #require(renderer.capture(frame: frame, width: size.0, height: size.1))
    let data = try #require(image.dataProvider?.data as Data?)
    let pick = try #require(renderer.pickTarget(frame: frame, size: size))
    return Rendered(hdr: hdr, ldr: [UInt8](data), pick: pick)
}

/// A record of `specs`: drawn one at a time, in this order (quads before
/// cubes, by mesh, then input order; record 11's map kind sorts it last).
private struct Spec {
    var mesh: MeshHandle
    var x: Float, y: Float, z: Float = 0
    var yaw: Float = 0
    var mirror = false
    var edit: (inout MaterialState) -> Void = { _ in }
}

/// Neighbouring records share a mesh, so their vertex buffers are skipped,
/// and each differs from the one before in exactly one state the skipping
/// must not drop: the cull mode, the winding of a mirrored model, a texture,
/// the material in another element of the same frame-ring buffer, or the
/// pipeline; the two transparent quads differ in their cull mode. The frame
/// renders, shades and picks byte for byte as it does with every state set
/// for every draw. The controls show that each change reaches the image, so
/// a dropped one would differ.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func skippingRepeatedEncoderStateNeverDropsARealChange() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let quad = try resources.register(mesh: quadMesh("state-quad"))
    let cube = try resources.register(mesh: cubeMesh("state-cube", half: 0.2))
    let red = try solidTexture(renderer, [230, 40, 30, 255]), green = try solidTexture(renderer, [30, 200, 60, 255])
    let transparent: (inout MaterialState) -> Void = { $0.transparent = true; $0.uniforms.baseColor.w = 0.6 }
    let specs: [Spec] = [
        // The camera looks down -Z: a quad at yaw 0 faces it, one at yaw π shows its back.
        Spec(mesh: quad, x: -1.5, y: 1.3),                                    // 1: cull back, front face: drawn
        Spec(mesh: quad, x: -0.9, y: 1.3, edit: doubleSided),                 // 2: cull none
        Spec(mesh: quad, x: -0.3, y: 1.3, yaw: .pi),                          // 3: cull back, back face: culled
        Spec(mesh: quad, x: 0.3, y: 1.3, yaw: .pi, edit: doubleSided),        // 4: cull none, back face: drawn
        Spec(mesh: quad, x: 0.9, y: 1.3, mirror: true),                       // 5: mirrored, clockwise front: drawn
        Spec(mesh: quad, x: 1.5, y: 1.3, yaw: .pi, mirror: true),             // 6: mirrored back face: culled
        Spec(mesh: cube, x: -1.2, y: 0.4, edit: textured(red)),               // 7
        Spec(mesh: cube, x: -0.6, y: 0.4, edit: textured(green)),             // 8: another texture
        Spec(mesh: cube, x: 0, y: 0.4),                                       // 9
        Spec(mesh: cube, x: 0.6, y: 0.4, edit: { $0 = tinted($0, 3) }),       // 10: another material element
        Spec(mesh: cube, x: 1.2, y: 0.4, edit: { $0.uniforms.kind = UInt32(MaterialKindMap.rawValue) }),  // 11: another pipeline
        // Transparent, back to front: 12 is farther from the camera.
        Spec(mesh: quad, x: -0.3, y: 2.0, z: -0.3, yaw: .pi, edit: transparent),                         // 12: cull back: culled
        Spec(mesh: quad, x: 0.3, y: 2.0, yaw: .pi, edit: { transparent(&$0); doubleSided(&$0) }),        // 13: cull none: drawn
    ]
    func frame(_ specs: [Spec]) -> RenderFrame {
        let items = specs.enumerated().map { index, spec -> RenderItem in
            var material = itemMaterial()
            spec.edit(&material)
            let scale: Float = spec.mesh == quad ? 0.5 : 1
            var item = RenderItem(mesh: spec.mesh, material: material,
                                  model: trs(Float3(spec.x, spec.y, spec.z), yaw: spec.yaw,
                                             scale: Float3(spec.mirror ? -scale : scale, scale, scale)),
                                  objectID: UInt32(index + 1))
            // A culled quad draws nothing at all: its outline shell (front faces
            // culled) would show its back.
            item.outline = spec.mesh == cube
            return item
        }
        var camera = OrbitCamera()
        camera.target = Float3(0, 1.1, 0); camera.distance = 6; camera.yaw = 0; camera.pitch = 0
        var effects = SceneEffects(); effects.showGrid = false
        return RenderFrame(camera: camera, items: items, effects: effects, sceneBounds: AABB(min: Float3(-2, 0, -1), max: Float3(2, 2.3, 1)))
    }
    let skipped = try render(renderer, frame(specs), skips: true)
    let full = try render(renderer, frame(specs), skips: false)
    #expect(skipped.hdr == full.hdr, "HDR scene differs at \(skipped.hdr.indices.filter { skipped.hdr[$0] != full.hdr[$0] }.prefix(8))")
    #expect(skipped.ldr == full.ldr, "LDR image differs")
    #expect(skipped.pick == full.pick, "Pick ids differ")

    // Controls. The pick pass draws every record with no culling, each at
    // its own place: a record drawn with the draw uniforms of the one before
    // (an offset the skipping kept) would cover it, and an id would be missing.
    let ids = Set(full.pick)
    #expect(ids.isSuperset(of: Set(1...UInt32(specs.count))), "\(ids.sorted())")
    // Given the state of the record before it (the change a skipped set would
    // drop), a record renders differently. Record 5 drawn with record 4's
    // counter-clockwise winding shows its back, as record 5 unmirrored at yaw π.
    var sameAsPrevious: [(String, [Spec])] = []
    var cull = specs; cull[2].edit = doubleSided; sameAsPrevious.append(("cull mode", cull))
    var winding = specs; winding[4].mirror = false; winding[4].yaw = .pi; sameAsPrevious.append(("winding", winding))
    var texture = specs; texture[7].edit = textured(red); sameAsPrevious.append(("texture", texture))
    var element = specs; element[9].edit = { _ in }; sameAsPrevious.append(("material element", element))
    var pipeline = specs; pipeline[10].edit = { _ in }; sameAsPrevious.append(("pipeline", pipeline))
    var transparentCull = specs; transparentCull[12].edit = transparent; sameAsPrevious.append(("transparent cull mode", transparentCull))
    for (label, variant) in sameAsPrevious {
        let other = try render(renderer, frame(variant), skips: false)
        #expect(other.hdr != full.hdr, "\(label): the change does not reach the image")
    }
}

/// A larger per-draw frame: 48 records in a seeded mix of two meshes, three
/// tints, two textures and none, double-sided, mirrored, turned, outlined,
/// map-kind and transparent records, with the grid and depth-tested, overlay
/// and pickable gizmos. Neighbours often share a mesh, material or state, and
/// often do not. It renders, shades and picks byte for byte as with every
/// state set for every draw.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func skippingRepeatedEncoderStateKeepsAMixedFrameByteForByte() throws {
    let renderer = try makeSourceShaderRenderer()
    let resources = renderer.resources
    let quad = try resources.register(mesh: quadMesh("state-mixed-quad"))
    let cube = try resources.register(mesh: cubeMesh("state-mixed-cube", half: 0.2))
    let red = try solidTexture(renderer, [230, 40, 30, 255]), green = try solidTexture(renderer, [30, 200, 60, 255])
    let textures: [TextureHandle?] = [nil, red, green]
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next(_ n: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(n))
    }
    let count = 48
    var items: [RenderItem] = []
    for i in 0..<count {
        let mesh = next(3) == 0 ? quad : cube
        var material = tinted(itemMaterial(), next(3))
        if let texture = textures[next(textures.count)] { textured(texture)(&material) }
        if next(3) == 0 { doubleSided(&material) }
        if next(8) == 0 { material.uniforms.kind = UInt32(MaterialKindMap.rawValue) }
        if next(4) == 0 { material.transparent = true; material.uniforms.baseColor.w = 0.55 }
        let scale: Float = mesh == quad ? 0.35 : 0.7
        let position = Float3(Float(i % 8) * 0.5 - 1.75, Float(i / 8) * 0.45 - 0.2, Float(next(3)) * -0.3)
        let yaw = next(4) == 0 ? Float.pi : Float(next(5)) * 0.3
        var item = RenderItem(mesh: mesh, material: material,
                              model: trs(position, yaw: yaw, scale: Float3(next(5) == 0 ? -scale : scale, scale, scale)),
                              objectID: UInt32(i + 1))
        item.outline = next(2) == 0
        items.append(item)
    }
    func triangle(_ color: Float4) -> [GizmoVertex] {
        [GizmoVertex(position: Float3(-0.2, -0.15, 0), color: color), GizmoVertex(position: Float3(0.2, -0.15, 0), color: color),
         GizmoVertex(position: Float3(0, 0.2, 0), color: color)]
    }
    let line = [GizmoVertex(position: Float3(-1.8, 1.0, 0.2), color: Float4(1, 1, 0, 1)),
                GizmoVertex(position: Float3(1.8, 1.4, 0.2), color: Float4(1, 1, 0, 1))]
    let gizmos = [GizmoBatch(primitive: .triangles, vertices: triangle(Float4(1, 0.6, 0, 1)), model: trs(Float3(-1, 1, 0.6)), depthTest: true, objectID: 900),
                  GizmoBatch(primitive: .lines, vertices: line, depthTest: true),
                  GizmoBatch(primitive: .triangles, vertices: triangle(Float4(0, 0.6, 1, 1)), model: trs(Float3(1, 1, 0.6)), objectID: 901)]
    var camera = OrbitCamera()
    camera.target = Float3(0, 0.95, 0); camera.distance = 6; camera.yaw = 0; camera.pitch = 0.15
    let frame = RenderFrame(camera: camera, items: items, gizmos: gizmos, effects: SceneEffects(),
                            sceneBounds: AABB(min: Float3(-2.2, -0.5, -1), max: Float3(2.2, 2.5, 1)))
    let skipped = try render(renderer, frame, skips: true)
    let full = try render(renderer, frame, skips: false)
    #expect(skipped.hdr == full.hdr, "HDR scene differs at \(skipped.hdr.indices.filter { skipped.hdr[$0] != full.hdr[$0] }.prefix(8))")
    #expect(skipped.ldr == full.ldr, "LDR image differs")
    #expect(skipped.pick == full.pick, "Pick ids differ")
    // Control: the frame shows most of its records and both pickable gizmos.
    let ids = Set(full.pick)
    #expect(ids.filter { (1...UInt32(count)).contains($0) }.count > count * 3 / 4 && ids.isSuperset(of: [900, 901]), "\(ids.sorted())")
    #expect(items.contains(where: { $0.material.transparent }) && items.contains(where: { $0.material.uniforms.kind == UInt32(MaterialKindMap.rawValue) }))
}
