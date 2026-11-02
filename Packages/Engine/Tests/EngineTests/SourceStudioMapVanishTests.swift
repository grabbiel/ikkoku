import Testing
import Foundation
import simd
import Assets
import CoreMath
import Character
import Studio

// ST-A11 PR B: `Studio.CameraControl`'s vanish list, the capsule's overlap
// test and `VanishProc`'s state.

private typealias P = SIMD3<Double>

private func cube(_ half: P = P(1, 1, 1)) -> [P] {
    [-1.0, 1].flatMap { x in [-1.0, 1].flatMap { y in [-1.0, 1].map { z in P(x, y, z) * half } } }
}

@Test func convexDistanceMatchesBoxDistancesInClosedForm() {
    let box = cube()
    // Beside a face, an edge and a corner; through the box; a point.
    #expect(abs(SourceStudioConvexDistance.distance([P(3, 0, 0), P(3, 1, 0)], box) - 2) < 1e-9)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 2, -5), P(2, 2, 5)], box) - 2.0.squareRoot()) < 1e-9)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 3, 4), P(5, 5, 5)], box) - (1.0 + 4 + 9).squareRoot()) < 1e-9)
    #expect(SourceStudioConvexDistance.distance([P(-5, 0.2, 0.1), P(5, -0.3, 0.4)], box) == 0)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 3, 0)], box) - 5.0.squareRoot()) < 1e-9)
    #expect(SourceStudioConvexDistance.distance([P(0.5, 0.5, 0.5)], box) == 0)
    #expect(abs(SourceStudioConvexDistance.pointSegment(P(0, 1, 0), P(-1, 0, 0), P(1, 0, 0)) - 1) < 1e-12)
    // A hull that is not a box: the octahedron |x| + |y| + |z| <= 1 (its face x + y + z = 1 is 2 / sqrt 3 from (1, 1, 1)),
    // with an interior point that changes nothing.
    let octahedron = [P(1, 0, 0), P(-1, 0, 0), P(0, 1, 0), P(0, -1, 0), P(0, 0, 1), P(0, 0, -1), P(0.1, 0.1, 0.1)]
    #expect(abs(SourceStudioConvexDistance.distance([P(1, 1, 1), P(2, 2, 2)], octahedron) - 2 / 3.0.squareRoot()) < 1e-9)
    #expect(abs(SourceStudioConvexDistance.distance([P(2, 2, 0), P(2, 2, 3)], octahedron) - 3 / 2.0.squareRoot()) < 1e-9)
}

@Test func convexDistanceAgreesWithSampledDistancesToRotatedBoxes() {
    var generator = SystemRandomNumberGenerator()
    func random(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &generator) }
    for _ in 0..<200 {
        let half = P(random(0.05...2), random(0.05...2), random(0.05...2))
        let rotation = simd_quatd(angle: random(0...(2 * .pi)), axis: simd_normalize(P(random(-1...1), random(-1...1), random(-1...1)) + P(0, 0, 1e-3)))
        let offset = P(random(-2...2), random(-2...2), random(-2...2))
        let points = cube(half).map { rotation.act($0) + offset }
        let a = P(random(-4...4), random(-4...4), random(-4...4)), b = P(random(-4...4), random(-4...4), random(-4...4))
        // The exact point-to-box distance in the box's frame, sampled along the segment.
        func pointBox(_ p: P) -> Double {
            let local = rotation.inverse.act(p - offset)
            return simd_length(simd_max(simd_abs(local) - half, P.zero))
        }
        let samples = 4000
        let sampled = (0...samples).map { pointBox(a + (b - a) * (Double($0) / Double(samples))) }.min()!
        let gjk = SourceStudioConvexDistance.distance([a, b], points)
        #expect(gjk <= sampled + 1e-9)
        #expect(sampled - gjk <= simd_distance(a, b) / Double(samples) + 1e-9, "gjk \(gjk) sampled \(sampled)")
    }
}

private func vanishJSON(option: Bool = false) -> JSONValue {
    // Row 0 names two boxes (one active for sun type 0 only), row 1 one box in
    // scene space, row 2 an option box; every box is 1 m wide around its matrix's origin.
    let unit = "[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[-0.5,0.5,-0.5],[0.5,0.5,-0.5],[-0.5,-0.5,0.5],[0.5,-0.5,0.5],[-0.5,0.5,0.5],[0.5,0.5,0.5]]"
    func matrix(_ x: Double, _ y: Double, _ z: Double) -> String { "[1,0,0,0,0,1,0,0,0,0,1,0,\(x),\(y),\(z),1]" }
    let text = """
    {"ikkokuVanish": {"kind": "ikkoku.studioMapVanish", "version": 1, "radius": 0.05, "delaySeconds": 0.3, "mapLayer": 11,
     "rows": [{"collider": "wall", "colliders": [0, 1]}, {"collider": "desk", "colliders": [2]}, {"collider": "extra", "colliders": [3]},
              {"collider": "none", "colliders": []}],
     "colliders": [
      {"name": "wall", "role": "mapRoot", "visibleFor": [0, 1], "option": false, "shape": 0, "matrix": \(matrix(0, 0, 5))},
      {"name": "wall", "role": "mapRoot", "visibleFor": [0], "option": false, "shape": 0, "matrix": \(matrix(3, 0, 5))},
      {"name": "desk", "role": "scene", "visibleFor": [0, 1], "option": false, "shape": 0, "matrix": \(matrix(0, 0, 2))},
      {"name": "extra", "role": "mapRoot", "visibleFor": [0, 1], "option": \(option), "shape": 0, "matrix": \(matrix(-3, 0, 5))}],
     "shapes": [{"type": "box", "points": \(unit)}]}}
    """
    return try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Test func vanishRowsAreTouchedByTheCapsuleBetweenCameraAndPivot() throws {
    let vanish = try #require(try SourceStudioMapVanish.parse(vanishJSON(option: true), label: "map.gltf"))
    #expect(vanish.rows.map(\.collider) == ["wall", "desk", "extra", "none"] && vanish.colliders.count == 4)
    #expect(vanish.radius == 0.05 && vanish.delaySeconds == 0.3)
    func touched(_ camera: P, _ pivot: P, sun: Int32 = 0, option: Bool = true, root: simd_double4x4 = matrix_identity_double4x4,
                 model: SourceStudioMapVanish.CapsuleModel = .segment) -> [Bool] {
        vanish.touchedRows(camera: camera, pivot: pivot, mapRoot: root, sunTypeKey: sun, mapOption: option, model: model)
    }
    // The view from z = 10 to the pivot at the origin passes the wall (z 4.5...5.5) and the desk (z 1.5...2.5).
    #expect(touched(P(0, 0, 10), .zero) == [true, true, false, false])
    // A pivot short of the desk: only the wall; a camera inside the desk box touches it.
    #expect(touched(P(0, 0, 10), P(0, 0, 3)) == [true, false, false, false])
    #expect(touched(P(0, 0, 2), P(0, 0, 0)) == [false, true, false, false])
    // The second wall box is active for sun type 0 only; the option box only with mapOption.
    #expect(touched(P(3, 0, 10), P(3, 0, 0), sun: 0) == [true, false, false, false])
    #expect(touched(P(3, 0, 10), P(3, 0, 0), sun: 1) == [false, false, false, false])
    #expect(touched(P(-3, 0, 10), P(-3, 0, 0), option: true) == [false, false, true, false])
    #expect(touched(P(-3, 0, 10), P(-3, 0, 0), option: false) == [false, false, false, false])
    // The radius reaches 0.05 past a face; the capsule's caps end at the camera and the pivot.
    #expect(touched(P(0.54, 0, 10), P(0.54, 0, 0)) == [true, true, false, false])
    #expect(touched(P(0.56, 0, 10), P(0.56, 0, 0)) == [false, false, false, false])
    #expect(touched(P(0, 0, 10), P(0, 0, 5.46)) == [true, false, false, false])
    #expect(touched(P(0, 0, 10), P(0, 0, 5.54)) == [false, false, false, false])
    // The midpoint sphere: only what holds the point halfway (z 5 here).
    #expect(touched(P(0, 0, 10), .zero, model: .midpointSphere) == [true, false, false, false])
    #expect(touched(P(0, 0, 8), P(0, 0, -4), model: .midpointSphere) == [false, true, false, false])
    // The map transform moves mapRoot colliders, not scene ones: shifted by x = 3, the view at x = 3 meets
    // the first wall (the second one, now at x = 6, is missed), and the view at x = 0 the desk and the
    // option box, now there.
    let shifted = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(3, 0, 0, 1)))
    #expect(touched(P(3, 0, 10), P(3, 0, 0), root: shifted) == [true, false, false, false])
    #expect(touched(P(0, 0, 10), .zero, root: shifted) == [false, true, true, false])
}

@Test func vanishListsThatCannotBeReadAreRefusedByName() throws {
    #expect(try SourceStudioMapVanish.parse(nil, label: "m") == nil)
    func refusal(_ text: String) -> String? {
        do { _ = try SourceStudioMapVanish.parse(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), label: "m.gltf"); return nil }
        catch { return "\(error)" }
    }
    let head = #"{"ikkokuVanish": {"kind": "ikkoku.studioMapVanish", "version": 1, "radius": 0.05, "delaySeconds": 0.3, "#
    #expect(refusal(#"{"ikkokuVanish": {"kind": "other", "version": 1}}"#)?.contains("not a version 1") == true)
    #expect(refusal(head + #""shapes": [{"type": "sphere", "points": [[0,0,0]]}]}}"#)?.contains("not a box or convex mesh") == true)
    #expect(refusal(head + #""shapes": [{"type": "box", "points": [[0,0]]}]}}"#)?.contains("has no points") == true)
    #expect(refusal(head + #""shapes": [{"type": "box", "points": [[0,0,0]]}], "colliders": [{"name": "a", "role": "mapRoot", "shape": 1, "matrix": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}]}}"#)?
        .contains("collider 0 has no name, role, shape or matrix") == true)
    #expect(refusal(head + #""shapes": [{"type": "box", "points": [[0,0,0]]}], "colliders": [{"name": "a", "role": "scene", "shape": 0, "matrix": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}], "rows": [{"collider": "b", "colliders": [0]}]}}"#)?
        .contains("row 0 names a collider that is not one of b") == true)
}

@Test func vanishStateFollowsVanishProcRowByRow() {
    // Sets: 0 = row 0 only, 1 = rows 0 and 1 (a renderer both rows hide), 2 = row 1 only.
    var state = SourceStudioMapVanishState(rows: 2, sets: [[0], [0, 1], [1]], delaySeconds: 0.3)
    #expect(state.setEnabled == [true, true, true] && state.secondsToNextShow == nil)
    // Touched: hidden at once.
    let step1 = state.update(touched: [true, false], time: 0)
    #expect(step1)
    #expect(state.setEnabled == [false, false, true] && state.rowVisible == [false, true])
    // Untouched for 0.2 s: still hidden, 0.1 s to go.
    let step2 = state.update(touched: [false, false], time: 1)
    #expect(!step2)
    let step3 = state.update(touched: [false, false], time: 1.2)
    #expect(!step3)
    #expect(abs(state.secondsToNextShow! - 0.1) < 1e-9)
    // Touched again: a hidden row does not act, and its delay is not reset (only a hide resets it).
    let step4 = state.update(touched: [true, false], time: 1.25)
    #expect(!step4)
    let step5 = state.update(touched: [false, false], time: 2)
    #expect(!step5)
    #expect(state.setEnabled == [false, false, true] && abs(state.secondsToNextShow! - 0.05) < 1e-9)
    let step6 = state.update(touched: [false, false], time: 2.1)
    #expect(step6)
    #expect(state.setEnabled == [true, true, true] && state.secondsToNextShow == nil)

    // Order: row 1 hides the shared renderer while row 0 is hidden too; row 0's show
    // re-enables it although row 1 still touches (VanishProc does not look at other rows).
    var shared = SourceStudioMapVanishState(rows: 2, sets: [[0], [0, 1], [1]], delaySeconds: 0.3)
    shared.update(touched: [true, false], time: 0)
    shared.update(touched: [true, true], time: 0.1)
    #expect(shared.setEnabled == [false, false, false])
    shared.update(touched: [false, true], time: 0.2)
    shared.update(touched: [false, true], time: 0.6)
    #expect(shared.setEnabled == [true, true, false] && shared.rowVisible == [true, false])
    // A frame's own step: VanishProc adds the frame time before comparing.
    var frames = SourceStudioMapVanishState(rows: 1, sets: [[0]], delaySeconds: 0.3)
    frames.frame(touched: [true], deltaTime: 0.035)
    for _ in 0..<8 { frames.frame(touched: [false], deltaTime: 0.035) }
    #expect(frames.setEnabled == [false])
    frames.frame(touched: [false], deltaTime: 0.035)
    #expect(frames.setEnabled == [true])
}

/// A converted map's split group in the converter's layout: under "Map", the
/// unsplit group `g` as the part no row names (`g`), row 0's part (`g_v0`),
/// row 0's part with dynamic lightmap 0 (`g_v0_d0`, with a TEXCOORD_2) and
/// row 1's (`g_v1_d0`). Six triangles in the unsplit order:
/// v0 0, rest 0, v1_d0 0, v0 1, v0_d0 0, rest 1. Every vertex is distinct.
private struct JoinFixture {
    struct Part { let name: String; let triangles: Int; let rows: [Int]?; let dynamic: Bool; let runs: [[Int]]; var material = 0 }
    static let parts = [Part(name: "g", triangles: 2, rows: nil, dynamic: false, runs: [[0, 1, 1], [1, 1, 5]]),
                        Part(name: "g_v0", triangles: 2, rows: [0], dynamic: false, runs: [[0, 1, 0], [1, 1, 3]]),
                        Part(name: "g_v0_d0", triangles: 1, rows: [0], dynamic: true, runs: [[0, 1, 4]]),
                        Part(name: "g_v1_d0", triangles: 1, rows: [1], dynamic: true, runs: [[0, 1, 2]])]
    /// The corner positions of part `p`'s triangle `t`: x = part, y = triangle, z = corner.
    static func corner(_ p: Int, _ t: Int, _ c: Int) -> Float3 { Float3(Float(p), Float(t), Float(c)) }

    let root: URL
    init(parts: [Part] = JoinFixture.parts) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkoku-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var buffer = Data(), views: [[String: Any]] = [], accessors: [[String: Any]] = [], meshes: [[String: Any]] = []
        func append<T>(_ values: [T]) -> Int {
            while buffer.count % 4 != 0 { buffer.append(0) }
            let offset = buffer.count
            values.withUnsafeBytes { buffer.append(contentsOf: $0) }
            views.append(["buffer": 0, "byteOffset": offset, "byteLength": buffer.count - offset])
            return views.count - 1
        }
        for (p, part) in parts.enumerated() {
            // Each triangle's corners are its own vertices, listed in reverse so the indices are not the identity.
            let positions = (0..<part.triangles).flatMap { t in (0..<3).map { Self.corner(p, t, $0) } }.reversed().map { $0 }
            let indices = (0..<part.triangles).flatMap { t in (0..<3).map { UInt32(positions.count - 1 - (3 * t + $0)) } }
            var flat: [Float] = []
            for v in positions { flat += [v.x, v.y, v.z] }
            accessors.append(["bufferView": append(flat), "componentType": 5126, "count": positions.count, "type": "VEC3",
                              "min": [Float(p), 0, 0], "max": [Float(p), Float(part.triangles - 1), 2]])
            var attributes: [String: Int] = ["POSITION": accessors.count - 1]
            accessors.append(["bufferView": append([Float](repeating: 0.5, count: 2 * positions.count)), "componentType": 5126,
                              "count": positions.count, "type": "VEC2"])
            attributes["TEXCOORD_0"] = accessors.count - 1
            if part.dynamic {
                accessors.append(["bufferView": append([Float](repeating: 0.25, count: 2 * positions.count)), "componentType": 5126,
                                  "count": positions.count, "type": "VEC2"])
                attributes["TEXCOORD_2"] = accessors.count - 1
            }
            accessors.append(["bufferView": append(indices), "componentType": 5125, "count": indices.count, "type": "SCALAR"])
            var info: [String: Any] = ["role": "mapRoot", "visibleFor": [-1, 0, 1, 2], "lightmapIndex": -1, "renderers": 1,
                                       "join": ["name": "g", "runs": part.runs]]
            if let rows = part.rows { info["vanishRows"] = rows }
            if part.dynamic { info["dynamicLightmapIndex"] = 0 }
            meshes.append(["name": part.name, "extras": ["ikkokuMap": info],
                           "primitives": [["attributes": attributes, "indices": accessors.count - 1, "material": part.material]]])
        }
        try buffer.write(to: root.appendingPathComponent("map.bin"))
        var nodes: [[String: Any]] = [["name": "Map", "children": Array(1...parts.count), "extras": ["ikkokuMapRole": "mapRoot"]]]
        nodes += parts.indices.map { ["name": parts[$0].name, "mesh": $0] as [String: Any] }
        let gltf: [String: Any] = [
            "asset": ["version": "2.0"], "buffers": [["byteLength": buffer.count, "uri": "map.bin"]],
            "bufferViews": views, "accessors": accessors, "meshes": meshes,
            "materials": [["name": "a"], ["name": "b"]], "nodes": nodes,
            "scenes": [["nodes": [0]]], "scene": 0]
        try JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys]).write(to: url)
    }
    var url: URL { root.appendingPathComponent("map.gltf") }
    func load() throws -> GLTFAsset { try GLBLoader.load(url: url, packageRoot: root) }
    func remove() { try? FileManager.default.removeItem(at: root) }

    /// The drawn meshes in node order: name, extras and primitive.
    static func drawn(_ gltf: GLTFAsset) -> [(name: String, info: JSONValue?, primitive: MeshData)] {
        gltf.meshNodes.flatMap { node in
            gltf.meshes[node.mesh].primitives.map { (name: gltf.meshes[node.mesh].name, info: gltf.meshes[node.mesh].extras?["ikkokuMap"], primitive: $0) }
        }
    }
    /// A primitive's triangles as their corner positions.
    static func triangles(_ p: MeshData) -> [[Float3]] {
        stride(from: 0, to: p.indices.count, by: 3).map { i in (0..<3).map { p.positions[Int(p.indices[i + $0])] } }
    }
}

@Test func splitMapPartsJoinBackInTheUnsplitTriangleOrder() throws {
    let fixture = try JoinFixture()
    defer { fixture.remove() }
    let corner = JoinFixture.corner
    func triangle(_ p: Int, _ t: Int) -> [Float3] { (0..<3).map { corner(p, t, $0) } }

    // Vanish off: one mesh, vertices in part order, indices rebased by each part's first vertex.
    var unsplit = try fixture.load()
    let unsplitAway = try SourceStudioMapJoin.join(&unsplit, mode: .unsplit, label: "map.gltf")
    #expect(unsplitAway == 3)
    let joined = JoinFixture.drawn(unsplit)
    #expect(joined.map(\.name) == ["g"])
    let p = try #require(joined.first?.primitive)
    #expect(p.positions.count == 18 && p.uvs.count == 18 && p.uvs2.isEmpty)
    // Part k's vertices start at 6, 12 and 15; the first triangle is g_v0's first (stored reversed: 5, 4, 3, plus 6).
    #expect(Array(p.indices.prefix(6)) == [11, 10, 9, 5, 4, 3])
    #expect(JoinFixture.triangles(p) == [triangle(1, 0), triangle(0, 0), triangle(3, 0), triangle(1, 1), triangle(2, 0), triangle(0, 1)])
    #expect(p.bounds == AABB(min: Float3(0, 0, 0), max: Float3(3, 1, 2)))
    let info = try #require(joined.first?.info)
    #expect(info["join"] == nil && info["vanishRows"] == nil && info["dynamicLightmapIndex"] == nil)
    #expect(info["renderers"]?.doubleValue == 4 && info["role"]?.stringValue == "mapRoot")
    #expect(unsplit.meshNodes.count == 1)

    // Vanish on: row 0's parts join in their unsplit order (g_v0 0, g_v0 1, g_v0_d0 0); the others stay.
    var sets = try fixture.load()
    let setsAway = try SourceStudioMapJoin.join(&sets, mode: .vanishSets, label: "map.gltf")
    #expect(setsAway == 1)
    let drawn = JoinFixture.drawn(sets)
    #expect(drawn.map(\.name) == ["g", "g_v0", "g_v1_d0"])
    #expect(JoinFixture.triangles(drawn[1].primitive) == [triangle(1, 0), triangle(1, 1), triangle(2, 0)])
    #expect(drawn[1].info?["vanishRows"] == .array([.number(0)]) && drawn[1].info?["dynamicLightmapIndex"] == nil)
    #expect(drawn[1].primitive.uvs2.isEmpty && drawn[1].info?["renderers"]?.doubleValue == 2)
    #expect(drawn[2].info?["dynamicLightmapIndex"]?.doubleValue == 0 && drawn[2].primitive.uvs2.count == 3)
    #expect(JoinFixture.triangles(drawn[0].primitive) == [triangle(0, 0), triangle(0, 1)])
}

@Test func splitMapPartsThatDoNotTileOrDifferAreRefusedByName() throws {
    var overlap = JoinFixture.parts
    overlap[3] = JoinFixture.Part(name: "g_v1_d0", triangles: 1, rows: [1], dynamic: true, runs: [[0, 1, 4]])
    var uncovered = JoinFixture.parts
    uncovered[0] = JoinFixture.Part(name: "g", triangles: 2, rows: nil, dynamic: false, runs: [[0, 1, 1]])
    var material = JoinFixture.parts
    material[1].material = 1
    for (parts, message) in [(overlap, "do not tile its triangles once"), (uncovered, "do not cover its triangles once"),
                             (material, "have different materials")] {
        let fixture = try JoinFixture(parts: parts)
        defer { fixture.remove() }
        var gltf = try fixture.load()
        let failure: String? = { do { try SourceStudioMapJoin.join(&gltf, mode: .unsplit, label: "map.gltf"); return nil } catch { return "\(error)" } }()
        #expect(failure?.contains(message) == true, "\(failure ?? "joined")")
    }
}
