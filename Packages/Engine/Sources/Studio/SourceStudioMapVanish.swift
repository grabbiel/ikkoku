import Foundation
import simd
import CoreMath
import Assets
import Scene

// ST-A11 slice 4 (PR B): `Studio.CameraControl`'s vanish, which hides the
// walls and furniture between the Studio camera and its pivot.
//
// CharaStudio 1.0.4.2 (recovered): the camera carries a kinematic rigidbody
// and a trigger CapsuleCollider (radius 0.05, direction Z, height
// `cameraData.distance.z`, centre halfway to the pivot). OnTriggerEnter and
// OnTriggerStay add a collider on the Map layer (mask 2048, layer 11) unless
// one of the same name is listed; OnTriggerExit clears the whole list. Each
// LateUpdate, `VanishProc` walks the map's vanish rows (`LoadVanish`: the
// catalog row's h/list table) in order: a row whose collider name no listed
// collider carries counts `delay` up by the frame time while it is hidden and
// shows its MeshRenderers once `delay` reaches 0.3 s; a listed row that is
// visible hides them at once (`delay` 0). A renderer in several rows takes
// whichever row acted on it last. LateUpdate returns early while a scene is
// added, during a loading fade, or while B is held, and the component is
// disabled while a camera object is looked through (`Studio.ChangeCamera`), so
// the state holds. `Manager.Config.EtcData.Shield` (default true) turns it
// off. Whether the player's PhysX reports the capsule's overlaps at all is
// what PR B's VM phase records; until then the app gates it.

/// The vanish rows and colliders a converted map carries (`ikkokuVanish` in
/// the glTF's top-level extras, written by `export_map_scene.py`).
public struct SourceStudioMapVanish: Sendable {
    public static let kind = "ikkoku.studioMapVanish"

    public struct Collider: Sendable {
        public let name: String
        public let role: SourceStudioMapAsset.Role
        public let visibleFor: Set<Int32>
        /// Under a map option root: active only while `mapOption` is on.
        public let option: Bool
        /// The convex shape's points in the role frame (the frame the map
        /// transform places, or the scene's world); the shape is their hull.
        public let points: [SIMD3<Double>]
        /// A sphere holding the points, for a cheap rejection.
        public let center: SIMD3<Double>
        public let boundingRadius: Double
    }

    /// How the capsule's negative height is read. The slice-4 trace saw its
    /// bounds span the camera to the pivot (`segment`); PR B's VM trigger
    /// experiment says which one the player's overlaps follow.
    public enum CapsuleModel: String, Sendable {
        /// The capsule from the camera to the pivot: its axis runs between
        /// them, `radius` in from each end.
        case segment
        /// A sphere of `radius` halfway between them (height clamped to the
        /// diameter).
        case midpointSphere

        /// The gate: `IKKOKU_STUDIO_MAP_VANISH` `segment` (or `1`) or
        /// `midpoint`; nil, the default, leaves vanish off.
        public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CapsuleModel? {
            switch environment["IKKOKU_STUDIO_MAP_VANISH"] {
            case "segment"?, "1"?: return .segment
            case "midpoint"?: return .midpointSphere
            default: return nil
            }
        }
    }

    public let radius: Double
    public let delaySeconds: Double
    /// Per row, in the list's order: its collider name and the colliders of
    /// that name it is matched by.
    public let rows: [(collider: String, colliders: [Int])]
    public let colliders: [Collider]

    /// nil when the glTF has no vanish list (an export before PR B, or a map
    /// without one). Refuses a shape, matrix or row it cannot read.
    public static func parse(_ extras: JSONValue?, label: String) throws -> SourceStudioMapVanish? {
        guard let value = extras?["ikkokuVanish"] else { return nil }
        func fail(_ reason: String) -> Error { RigError.invalid("\(label) vanish: \(reason).") }
        guard value["kind"]?.stringValue == kind, value["version"]?.doubleValue == 1 else { throw fail("not a version 1 \(kind)") }
        guard let radius = value["radius"]?.doubleValue, radius.isFinite, radius >= 0,
              let delay = value["delaySeconds"]?.doubleValue, delay.isFinite, delay >= 0 else {
            throw fail("no radius or delay")
        }
        func vector(_ json: JSONValue?) -> SIMD3<Double>? {
            guard let xyz = json?.arrayValue?.compactMap(\.doubleValue), xyz.count == 3, xyz.allSatisfy(\.isFinite) else { return nil }
            return SIMD3(xyz[0], xyz[1], xyz[2])
        }
        var shapes: [[SIMD3<Double>]] = []
        for (index, shape) in (value["shapes"]?.arrayValue ?? []).enumerated() {
            guard ["box", "convexMesh"].contains(shape["type"]?.stringValue ?? "") else { throw fail("shape \(index) is not a box or convex mesh") }
            let points = (shape["points"]?.arrayValue ?? []).compactMap(vector)
            guard !points.isEmpty, points.count == shape["points"]?.arrayValue?.count else { throw fail("shape \(index) has no points") }
            shapes.append(points)
        }
        var colliders: [Collider] = []
        for (index, json) in (value["colliders"]?.arrayValue ?? []).enumerated() {
            guard let name = json["name"]?.stringValue,
                  let role = json["role"]?.stringValue.flatMap(SourceStudioMapAsset.Role.init(rawValue:)),
                  let shapeNumber = json["shape"]?.doubleValue, let shape = Int(exactly: shapeNumber), shapes.indices.contains(shape),
                  let matrix = json["matrix"]?.arrayValue?.compactMap(\.doubleValue), matrix.count == 16, matrix.allSatisfy(\.isFinite) else {
                throw fail("collider \(index) has no name, role, shape or matrix")
            }
            var visible = Set<Int32>()
            for key in json["visibleFor"]?.arrayValue ?? [] {
                guard let number = key.doubleValue.flatMap({ Int32(exactly: $0) }), (-1...2).contains(number) else {
                    throw fail("collider \(index) has an invalid sun-type key")
                }
                visible.insert(number)
            }
            // Column-major, as the converter's engine_matrix writes it.
            let m = simd_double4x4(columns: (SIMD4(matrix[0], matrix[1], matrix[2], matrix[3]),
                                             SIMD4(matrix[4], matrix[5], matrix[6], matrix[7]),
                                             SIMD4(matrix[8], matrix[9], matrix[10], matrix[11]),
                                             SIMD4(matrix[12], matrix[13], matrix[14], matrix[15])))
            let points = shapes[shape].map { p -> SIMD3<Double> in
                let q = m * SIMD4(p, 1)
                return SIMD3(q.x, q.y, q.z)
            }
            let center = points.reduce(SIMD3<Double>.zero, +) / Double(points.count)
            let bound = points.map { simd_distance($0, center) }.max() ?? 0
            colliders.append(Collider(name: name, role: role, visibleFor: visible, option: json["option"]?.boolValue == true,
                                      points: points, center: center, boundingRadius: bound))
        }
        var rows: [(collider: String, colliders: [Int])] = []
        for (index, row) in (value["rows"]?.arrayValue ?? []).enumerated() {
            guard let name = row["collider"]?.stringValue, let list = row["colliders"]?.arrayValue else { throw fail("row \(index) has no collider name") }
            var members: [Int] = []
            for entry in list {
                guard let number = entry.doubleValue.flatMap({ Int(exactly: $0) }), colliders.indices.contains(number),
                      colliders[number].name == name else {
                    throw fail("row \(index) names a collider that is not one of \(name)")
                }
                members.append(number)
            }
            rows.append((name, members))
        }
        return SourceStudioMapVanish(radius: radius, delaySeconds: delay, rows: rows, colliders: colliders)
    }

    /// The rows a collider the camera's capsule touches matches, in row order.
    /// `camera` and `pivot` are engine-basis world points; `mapRoot` is the
    /// record's map transform (`SourceStudioMapPlacement.mapRootMatrix`, rigid).
    /// A collider counts while its object is active: for the sun type, and for
    /// an option collider only while `mapOption` is on.
    public func touchedRows(camera: SIMD3<Double>, pivot: SIMD3<Double>, mapRoot: simd_double4x4, sunTypeKey: Int32,
                            mapOption: Bool, model: CapsuleModel) -> [Bool] {
        let axis = Self.capsuleAxis(camera: camera, pivot: pivot, radius: radius, model: model)
        let inverse = mapRoot.inverse
        func local(_ p: SIMD3<Double>) -> SIMD3<Double> { let q = inverse * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z) }
        let inMap = (local(axis.0), local(axis.1))
        var touched = [Bool](repeating: false, count: colliders.count)
        for (index, collider) in colliders.enumerated()
        where collider.visibleFor.contains(sunTypeKey) && (mapOption || !collider.option) {
            let segment = collider.role == .mapRoot ? inMap : axis
            // The rejection keeps the exact test for the colliders near the axis.
            guard SourceStudioConvexDistance.pointSegment(collider.center, segment.0, segment.1)
                    <= collider.boundingRadius + radius else { continue }
            touched[index] = SourceStudioConvexDistance.distance([segment.0, segment.1], collider.points) <= radius
        }
        return rows.map { row in row.colliders.contains { touched[$0] } }
    }

    /// The capsule's axis: from `radius` past the camera to `radius` short of
    /// the pivot (a Unity capsule's height includes its caps), a point when
    /// they are closer than the diameter; the midpoint for `midpointSphere`.
    public static func capsuleAxis(camera: SIMD3<Double>, pivot: SIMD3<Double>, radius: Double,
                                   model: CapsuleModel) -> (SIMD3<Double>, SIMD3<Double>) {
        let middle = (camera + pivot) / 2
        let length = simd_distance(camera, pivot)
        guard model == .segment, length > 2 * radius else { return (middle, middle) }
        let direction = (pivot - camera) / length
        return (camera + direction * radius, pivot - direction * radius)
    }
}

/// `VanishProc`'s per-row state and the renderers' enabled flags, per vanish
/// set (the distinct row sets the map's parts belong to: every renderer of a
/// part takes the same actions). Starts as `LoadVanish` leaves it: every row
/// visible, every renderer enabled.
public struct SourceStudioMapVanishState: Sendable, Equatable {
    public private(set) var rowVisible: [Bool]
    public private(set) var rowDelay: [Double]
    /// Per vanish set: whether its renderers are enabled.
    public private(set) var setEnabled: [Bool]
    /// The rows' touched flags of the last update, and its time.
    public private(set) var lastTouched: [Bool]?
    public private(set) var lastTime: Double?
    let rowSets: [[Int]]
    let delay: Double

    public init(rows: Int, sets: [[Int]], delaySeconds: Double) {
        rowVisible = Array(repeating: true, count: rows)
        rowDelay = Array(repeating: 0, count: rows)
        setEnabled = Array(repeating: true, count: sets.count)
        var rowSets = Array(repeating: [Int](), count: rows)
        for (set, members) in sets.enumerated() {
            for row in members where rowSets.indices.contains(row) { rowSets[row].append(set) }
        }
        self.rowSets = rowSets
        delay = delaySeconds
    }

    /// One `VanishProc` pass with the frame's time (`isFlashVisible` is never
    /// set in Studio). Returns whether a set's renderers changed.
    @discardableResult
    public mutating func frame(touched: [Bool], deltaTime: Double) -> Bool {
        var changed = false
        func act(_ row: Int, visible: Bool) {
            for set in rowSets[row] where setEnabled[set] != visible { setEnabled[set] = visible; changed = true }
            rowDelay[row] = visible ? delay : 0
            rowVisible[row] = visible
        }
        for row in rowVisible.indices {
            let isTouched = row < touched.count && touched[row]
            if !isTouched {
                guard !rowVisible[row] else { continue }
                rowDelay[row] += deltaTime
                if rowDelay[row] >= delay { act(row, visible: true) }
            } else if rowVisible[row] {
                act(row, visible: false)
            }
        }
        return changed
    }

    /// The app's step at `time` (seconds, any monotonic clock) with the rows
    /// touched now: the time since the last update passes under the rows
    /// touched then (they hold until the camera or map changes), then the new
    /// rows act. Returns whether a set's renderers changed.
    @discardableResult
    public mutating func update(touched: [Bool], time: Double) -> Bool {
        var changed = false
        if let previous = lastTouched, let last = lastTime, time > last {
            changed = frame(touched: previous, deltaTime: time - last)
        }
        changed = frame(touched: touched, deltaTime: 0) || changed
        lastTouched = touched
        lastTime = time
        return changed
    }

    /// Seconds after the last update until a hidden, untouched row shows
    /// again; nil when none waits.
    public var secondsToNextShow: Double? {
        let touched = lastTouched ?? []
        return rowVisible.indices.filter { !rowVisible[$0] && !($0 < touched.count && touched[$0]) }
            .map { max(0, delay - rowDelay[$0]) }.min()
    }
}

/// Distances between convex hulls of point sets (GJK, with the closest-point
/// steps of Ericson, Real-Time Collision Detection 5.1 and 9.5).
public enum SourceStudioConvexDistance {
    public typealias Point = SIMD3<Double>

    /// The distance between the hulls of `a` and `b`; 0 where they overlap.
    public static func distance(_ a: [Point], _ b: [Point]) -> Double {
        guard let first = a.first, let other = b.first else { return .infinity }
        func farthest(_ points: [Point], _ direction: Point) -> Point {
            var best = points[0], value = simd_dot(best, direction)
            for p in points.dropFirst() { let d = simd_dot(p, direction); if d > value { value = d; best = p } }
            return best
        }
        var v = first - other
        var simplex: [Point] = []
        for _ in 0..<96 {
            let vv = simd_length_squared(v)
            if vv <= 1e-24 { return 0 }
            let w = farthest(a, -v) - farthest(b, v)
            // No point of the difference lies further toward the origin.
            if vv - simd_dot(v, w) <= 1e-12 * vv || simplex.contains(where: { simd_distance_squared($0, w) <= 1e-24 }) {
                return vv.squareRoot()
            }
            simplex.append(w)
            (v, simplex) = closest(simplex)
            if simplex.count == 4 { return 0 }
        }
        return simd_length(v)
    }

    /// The distance from `p` to the segment `a`–`b`.
    public static func pointSegment(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let ab = b - a, length = simd_length_squared(ab)
        let t = length > 0 ? min(max(simd_dot(p - a, ab) / length, 0), 1) : 0
        return simd_distance(p, a + ab * t)
    }

    /// The point of the simplex's hull nearest the origin, and the smallest
    /// subset of its points that holds it (all four when the origin is inside).
    static func closest(_ s: [Point]) -> (Point, [Point]) {
        switch s.count {
        case 1: return (s[0], s)
        case 2: return segment(s[0], s[1])
        case 3: return triangle(s[0], s[1], s[2])
        default: return tetrahedron(s[0], s[1], s[2], s[3])
        }
    }

    static func segment(_ a: Point, _ b: Point) -> (Point, [Point]) {
        let ab = b - a, length = simd_length_squared(ab)
        guard length > 0 else { return (a, [a]) }
        let t = simd_dot(-a, ab) / length
        if t <= 0 { return (a, [a]) }
        if t >= 1 { return (b, [b]) }
        return (a + ab * t, [a, b])
    }

    static func triangle(_ a: Point, _ b: Point, _ c: Point) -> (Point, [Point]) {
        let ab = b - a, ac = c - a
        let d1 = simd_dot(ab, -a), d2 = simd_dot(ac, -a)
        if d1 <= 0 && d2 <= 0 { return (a, [a]) }
        let d3 = simd_dot(ab, -b), d4 = simd_dot(ac, -b)
        if d3 >= 0 && d4 <= d3 { return (b, [b]) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return (a + ab * (d1 / (d1 - d3)), [a, b]) }
        let d5 = simd_dot(ab, -c), d6 = simd_dot(ac, -c)
        if d6 >= 0 && d5 <= d6 { return (c, [c]) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return (a + ac * (d2 / (d2 - d6)), [a, c]) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 {
            return (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))), [b, c])
        }
        let sum = va + vb + vc
        guard sum > 1e-30 else {
            // A degenerate (flat) triangle: the nearest of its edges.
            return [segment(a, b), segment(b, c), segment(a, c)].min { simd_length_squared($0.0) < simd_length_squared($1.0) }!
        }
        return (a + ab * (vb / sum) + ac * (vc / sum), [a, b, c])
    }

    static func tetrahedron(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> (Point, [Point]) {
        // The origin is outside a face where it and the opposite point lie on
        // different sides of its plane (a flat tetrahedron checks every face).
        func outside(_ p: Point, _ q: Point, _ r: Point, _ opposite: Point) -> Bool {
            let n = simd_cross(q - p, r - p)
            let origin = simd_dot(-p, n), other = simd_dot(opposite - p, n)
            return other * other <= 1e-30 || origin * other < 0
        }
        var best: (Point, [Point])?
        for (p, q, r, o) in [(a, b, c, d), (a, c, d, b), (a, d, b, c), (b, d, c, a)] where outside(p, q, r, o) {
            let candidate = triangle(p, q, r)
            if best == nil || simd_length_squared(candidate.0) < simd_length_squared(best!.0) { best = candidate }
        }
        return best ?? (.zero, [a, b, c, d])
    }
}

/// PR B: a converted map's parts that a vanish set or a dynamic lightmap
/// index split, joined back in the loaded glTF before any mesh is
/// registered. The converter writes `ikkokuMap.join` on every such part: the
/// unsplit mesh's name and the part's triangle runs, [part start, count,
/// joined start], the joined start counted in the unsplit group's own order
/// (its renderers in scene order). A joined mesh takes its parts' vertices in
/// mesh order, each part's indices rebased by its first vertex, and its
/// triangles in joined order, so it draws what the unsplit export's mesh
/// draws, in the same order (under LEqual, equal-depth pixels keep the first
/// triangle). Realtime GI is not drawn, so a joined mesh drops the dynamic
/// lightmap index and the TEXCOORD_2 that carried its UV.
public enum SourceStudioMapJoin {
    public enum Mode: String, Sendable, Equatable {
        /// Vanish off: every split group is one mesh again, the unsplit
        /// export's draws.
        case unsplit
        /// Vanish on: one mesh per vanish set (and one for the renderers no
        /// row names); only the dynamic lightmap split is joined.
        case vanishSets

        /// `vanishSets` while `IKKOKU_STUDIO_MAP_VANISH` turns vanish on.
        public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode {
            SourceStudioMapVanish.CapsuleModel.fromEnvironment(environment) == nil ? .unsplit : .vanishSets
        }
    }

    private struct Member {
        let node: Int, mesh: Int
        let runs: [(start: Int, count: Int, at: Int)]
        let vanishRows: [Int]
        let dynamic: Bool
    }

    /// The keys a join may differ in across its parts.
    private static let splitKeys: Set<String> = ["join", "vanishRows", "dynamicLightmapIndex", "renderers"]

    /// Joins `gltf`'s split parts for `mode` in place; returns how many
    /// meshes were joined away (their nodes lose the mesh, and its data is
    /// dropped). Refuses runs that do not tile each part and each unsplit
    /// group once, and parts that differ in anything but the split.
    @discardableResult
    public static func join(_ gltf: inout GLTFAsset, mode: Mode, label: String) throws -> Int {
        func invalid(_ detail: String) -> RigError { .invalid("\(label): \(detail)") }
        var groups: [String: [Member]] = [:], order: [String] = []
        var seen = Set<Int>()
        for (node, mesh) in gltf.meshNodes {
            guard let info = gltf.meshes[mesh].extras?["ikkokuMap"], let join = info["join"] else { continue }
            let meshName = gltf.meshes[mesh].name
            guard seen.insert(mesh).inserted, gltf.meshes[mesh].primitives.count == 1,
                  let name = join["name"]?.stringValue, !name.isEmpty, let list = join["runs"]?.arrayValue else {
                throw invalid("mesh \(meshName) has a join that is not one primitive's unsplit name and runs.")
            }
            var runs: [(start: Int, count: Int, at: Int)] = []
            for entry in list {
                let numbers = entry.arrayValue?.compactMap { $0.doubleValue.flatMap { Int(exactly: $0) } } ?? []
                guard numbers.count == 3, entry.arrayValue?.count == 3, numbers[0] >= 0, numbers[1] > 0, numbers[2] >= 0 else {
                    throw invalid("mesh \(meshName) has a join run that is not [part start, count, joined start].")
                }
                runs.append((numbers[0], numbers[1], numbers[2]))
            }
            var next = 0
            for run in runs.sorted(by: { $0.start < $1.start }) {
                guard run.start == next else { throw invalid("mesh \(meshName)'s join runs do not cover its triangles once.") }
                next += run.count
            }
            guard next * 3 == gltf.meshes[mesh].primitives[0].indices.count else {
                throw invalid("mesh \(meshName)'s join runs do not cover its triangles once.")
            }
            let rows = info["vanishRows"]?.arrayValue?.compactMap { $0.doubleValue.flatMap { Int(exactly: $0) } } ?? []
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(Member(node: node, mesh: mesh, runs: runs, vanishRows: rows,
                                                    dynamic: info["dynamicLightmapIndex"] != nil))
        }
        var joinedAway = 0
        for name in order {
            let members = groups[name]!
            let total = members.reduce(0) { $0 + gltf.meshes[$1.mesh].primitives[0].indices.count / 3 }
            var at = 0
            for run in members.flatMap(\.runs).sorted(by: { $0.at < $1.at }) {
                guard run.at == at else { throw invalid("the parts joined as \(name) do not tile its triangles once.") }
                at += run.count
            }
            guard at == total else { throw invalid("the parts joined as \(name) do not tile its triangles once.") }
            try check(members, gltf: gltf) { invalid("the parts joined as \(name) \($0).") }
            var subgroups: [[Member]] = []
            switch mode {
            case .unsplit:
                subgroups = [members]
            case .vanishSets:
                var index: [[Int]: Int] = [:]
                for member in members {
                    if let k = index[member.vanishRows] { subgroups[k].append(member) }
                    else { index[member.vanishRows] = subgroups.count; subgroups.append([member]) }
                }
            }
            for parts in subgroups where parts.count > 1 || mode == .unsplit {
                let joinedName: String
                if mode == .unsplit {
                    joinedName = name
                } else {
                    let first = gltf.meshes[parts[0].mesh]
                    let index = first.extras?["ikkokuMap"]?["dynamicLightmapIndex"]?.doubleValue.flatMap { Int(exactly: $0) }
                    joinedName = index.map { first.name.hasSuffix("_d\($0)") ? String(first.name.dropLast("_d\($0)".count)) : first.name } ?? first.name
                }
                joinedAway += joinParts(parts, into: joinedName, keepRows: mode == .vanishSets, gltf: &gltf)
            }
        }
        return joinedAway
    }

    /// The parts must be one unsplit group's: one material, frame and
    /// placement, the same streams (TEXCOORD_2 only as the dynamic lightmap
    /// UV), no skin or morphs, and the same `ikkokuMap` but for the split.
    private static func check(_ members: [Member], gltf: GLTFAsset, _ refuse: (String) -> RigError) throws {
        let first = members[0]
        let base = gltf.meshes[first.mesh].primitives[0], node = gltf.nodes[first.node]
        func rest(_ mesh: Int) -> [String: JSONValue] {
            (gltf.meshes[mesh].extras?["ikkokuMap"]?.objectValue ?? [:]).filter { !splitKeys.contains($0.key) }
        }
        func streams(_ p: MeshData) -> [Bool] {
            [p.normals.isEmpty, p.tangents.isEmpty, p.uvs.isEmpty, p.uvs1.isEmpty, p.colors.isEmpty, p.regions.isEmpty]
        }
        let anyDynamic = members.contains(where: \.dynamic)
        for member in members {
            let p = gltf.meshes[member.mesh].primitives[0], n = gltf.nodes[member.node]
            guard p.materialIndex == base.materialIndex else { throw refuse("have different materials") }
            guard n.parent == node.parent, n.localMatrix == node.localMatrix, n.skin == nil else {
                throw refuse("hang under different frames or placements")
            }
            guard !p.isSkinned, p.morphTargets.isEmpty else { throw refuse("carry a skin or morphs") }
            guard streams(p) == streams(base), p.extras == base.extras else { throw refuse("carry different vertex streams") }
            guard anyDynamic ? (p.uvs2.isEmpty || member.dynamic) : p.uvs2.isEmpty == base.uvs2.isEmpty else {
                throw refuse("carry a TEXCOORD_2 that is not the dynamic lightmap UV")
            }
            guard rest(member.mesh) == rest(first.mesh) else { throw refuse("differ in more than the split") }
        }
    }

    /// Joins `parts` into the first one's mesh and node; returns how many
    /// meshes went away.
    private static func joinParts(_ parts: [Member], into name: String, keepRows: Bool, gltf: inout GLTFAsset) -> Int {
        let primitives = parts.map { gltf.meshes[$0.mesh].primitives[0] }
        let dropUV2 = parts.contains(where: \.dynamic)
        var joined = primitives[0]
        joined.name = name
        joined.positions = []; joined.normals = []; joined.tangents = []; joined.uvs = []; joined.uvs1 = []
        joined.uvs2 = []; joined.colors = []; joined.regions = []; joined.indices = []
        joined.bounds = .empty
        var firstVertex: [UInt32] = []
        for p in primitives {
            firstVertex.append(UInt32(joined.positions.count))
            joined.positions += p.positions; joined.normals += p.normals; joined.tangents += p.tangents
            joined.uvs += p.uvs; joined.uvs1 += p.uvs1; joined.colors += p.colors; joined.regions += p.regions
            if !dropUV2 { joined.uvs2 += p.uvs2 }
            joined.bounds.expand(p.bounds)
        }
        joined.indices.reserveCapacity(primitives.reduce(0) { $0 + $1.indices.count })
        let runs = parts.indices.flatMap { k in parts[k].runs.map { (part: k, run: $0) } }.sorted { $0.run.at < $1.run.at }
        for (k, run) in runs {
            let source = primitives[k].indices, base = firstVertex[k]
            for i in (3 * run.start)..<(3 * (run.start + run.count)) { joined.indices.append(source[i] + base) }
        }
        var info = gltf.meshes[parts[0].mesh].extras?["ikkokuMap"]?.objectValue ?? [:]
        info["join"] = nil
        info["dynamicLightmapIndex"] = nil
        if !keepRows { info["vanishRows"] = nil }
        let renderers = parts.reduce(0.0) { $0 + (gltf.meshes[$1.mesh].extras?["ikkokuMap"]?["renderers"]?.doubleValue ?? 0) }
        info["renderers"] = .number(renderers)
        var extras = gltf.meshes[parts[0].mesh].extras?.objectValue ?? [:]
        extras["ikkokuMap"] = .object(info)
        gltf.meshes[parts[0].mesh].name = name
        gltf.meshes[parts[0].mesh].extras = .object(extras)
        gltf.meshes[parts[0].mesh].primitives = [joined]
        gltf.nodes[parts[0].node].name = name
        for part in parts.dropFirst() {
            gltf.nodes[part.node].mesh = nil
            gltf.meshes[part.mesh].primitives = []
        }
        return parts.count - 1
    }
}
