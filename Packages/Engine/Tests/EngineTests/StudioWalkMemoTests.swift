import Testing
import Foundation
import simd
import Studio

// #387: `StudioWalkMemo` carries the Studio frame rebuild's world walk
// (StudioModel.sourceWorldMatrix). `WalkRun` models that walk's shape:
// - a parent chain checked with a visited set;
// - route parents, whose children compose under the route's own world (a
//   restarted chain) and report once per evaluation;
// - attached children, which compose a parent frame the walk can change
//   between queries (absent = no converted character);
// - objects whose own composition throws.
// Each run makes the walk twice: as the plain recursion (no memo) and
// through the memo. Every query must give the same matrix bits or the same
// error message, and the reports must reach the sink in the same order.

private struct WalkError: Error, CustomStringConvertible { let description: String }

private enum Outcome: Equatable {
    case matrix([UInt32])
    case error(String)
}

private func outcome(_ body: () throws -> float4x4) -> Outcome {
    do {
        let m = try body()
        return .matrix((0..<4).flatMap { c in (0..<4).map { r in m[c][r].bitPattern } })
    } catch { return .error("\(error)") }
}

/// The reports as `reportSourceRouteDiagnostics` turns them into status writes: a repeat of the last one is dropped.
private func statusWrites(_ reports: [String]) -> [String] {
    var writes: [String] = []
    for report in reports where report != writes.last { writes.append(report) }
    return writes
}

private struct WalkScene {
    var objects: [StudioObject]
    var local: [float4x4]
    var routes: Set<UUID>
    var routeOffset: [UUID: float4x4]
    var attached: [Bool]
    var throwing: [Bool]
    var attachments: [UUID: float4x4]
}

private final class WalkRun {
    var scene: WalkScene
    let lookup: StudioDocument.Lookup
    var reports: [String] = []
    var evaluations = 0
    private(set) var memo: StudioWalkMemo<UUID, float4x4, String>?

    init(_ scene: WalkScene, memoized: Bool) {
        self.scene = scene
        lookup = StudioDocument.Lookup(scene.objects)
        if memoized { memo = StudioWalkMemo(count: scene.objects.count) { [unowned self] in self.reports.append($0) } }
    }

    func world(_ id: UUID, visited: Set<UUID> = []) throws -> float4x4 {
        if let memo {
            guard let index = lookup.index(of: id) else { throw WalkError(description: "Missing Studio object.") }
            return try memo.value(at: index, cycle: { WalkError(description: "Invalid Studio parent hierarchy.") }) {
                try composed(id, visited: visited)
            }
        }
        return try composed(id, visited: visited)
    }

    private func composed(_ id: UUID, visited: Set<UUID>) throws -> float4x4 {
        evaluations += 1
        guard let index = lookup.index(of: id) else { throw WalkError(description: "Missing Studio object.") }
        var visited = visited
        if memo == nil { guard visited.insert(id).inserted else { throw WalkError(description: "Invalid Studio parent hierarchy.") } }
        var frame = matrix_identity_float4x4
        if let parentID = lookup.objects[index].parent {
            guard lookup.index(of: parentID) != nil else { throw WalkError(description: "Invalid Studio parent hierarchy.") }
            if scene.routes.contains(parentID) {
                // The route's own world restarts the chain, as routeChildRootWorld does.
                let routeWorld = try world(parentID)
                let report = "Route \(parentID.uuidString.prefix(8)) playback"
                if let memo { memo.emit(report) } else { reports.append(report) }
                frame = routeWorld * scene.routeOffset[parentID, default: matrix_identity_float4x4]
            } else {
                frame = try world(parentID, visited: visited)
                if scene.attached[index] {
                    memo?.depend(on: parentID)
                    guard let attachment = scene.attachments[parentID] else {
                        throw WalkError(description: "Attachment parent has no converted character.")
                    }
                    frame *= attachment
                }
            }
        }
        if scene.throwing[index] { throw WalkError(description: "Object \(index) failed to compose.") }
        return frame * scene.local[index]
    }
}

private func randomMatrix(_ rng: inout LookupSeed) -> float4x4 {
    var m = matrix_identity_float4x4
    for c in 0..<4 { for r in 0..<3 { m[c][r] += Float.random(in: -0.75...0.75, using: &rng) } }
    return m
}

/// Ids whose parent chain (first objects of each id) comes back to them.
private func idsOnACycle(_ lookup: StudioDocument.Lookup) -> Set<UUID> {
    var onCycle: Set<UUID> = []
    for object in lookup.objects {
        var seen: Set<UUID> = [], current = lookup.index(of: object.id).flatMap { lookup.objects[$0].parent }
        while let id = current, id != object.id, seen.insert(id).inserted, let index = lookup.index(of: id) {
            current = lookup.objects[index].parent
        }
        if current == object.id { onCycle.insert(object.id) }
    }
    return onCycle
}

@Test func studioWalkMemoMatchesThePlainWalkOnMalformedHierarchies() {
    var reached: Set<String> = []
    for seed in UInt64(1)...160 {
        var rng = LookupSeed(state: seed &* 7919)
        let (document, pool, missing) = malformedStudioDocument(&rng, maxCount: seed % 4 == 0 ? 60 : 24)
        let objects = document.objects
        let lookup = StudioDocument.Lookup(objects)
        // A route on a cycle would make the plain walk recurse without end
        // (the restarted chain): that case has its own test below.
        let cyclic = idsOnACycle(lookup)
        var routes: Set<UUID> = [], routeOffset: [UUID: float4x4] = [:], attachments: [UUID: float4x4] = [:]
        for id in pool {
            if !cyclic.contains(id), Int.random(in: 0..<4, using: &rng) == 0 { routes.insert(id); routeOffset[id] = randomMatrix(&rng) }
            if Int.random(in: 0..<3, using: &rng) != 0 { attachments[id] = randomMatrix(&rng) }
        }
        let scene = WalkScene(objects: objects, local: objects.map { _ in randomMatrix(&rng) }, routes: routes, routeOffset: routeOffset,
                              attached: objects.map { _ in Int.random(in: 0..<3, using: &rng) == 0 },
                              throwing: objects.map { _ in Int.random(in: 0..<10, using: &rng) == 0 }, attachments: attachments)
        let plain = WalkRun(scene, memoized: false), memoized = WalkRun(scene, memoized: true)
        // Two passes in random orders, with the ids not in the document mixed in.
        var queries: [UUID] = []
        for _ in 0..<2 { queries += (objects.map(\.id) + missing).shuffled(using: &rng) }
        for id in queries {
            let expected = outcome { try plain.world(id) }
            #expect(outcome { try memoized.world(id) } == expected, "seed \(seed)")
            if case .error(let message) = expected { reached.insert(message.hasPrefix("Object") ? "throwing" : message) } else { reached.insert("matrix") }
            // The frame loop's iteration may install or step this object's
            // preview, then invalidates its id.
            switch Int.random(in: 0..<4, using: &rng) {
            case 0:
                let changed = randomMatrix(&rng)
                plain.scene.attachments[id] = changed; memoized.scene.attachments[id] = changed
            case 1:
                plain.scene.attachments[id] = nil; memoized.scene.attachments[id] = nil
            default: break
            }
            memoized.memo?.invalidate(id)
        }
        #expect(memoized.reports == plain.reports, "seed \(seed)")
        #expect(statusWrites(memoized.reports) == statusWrites(plain.reports), "seed \(seed)")
        #expect(memoized.evaluations <= plain.evaluations, "seed \(seed)")
        if !plain.reports.isEmpty { reached.insert("reports") }
    }
    #expect(reached == ["matrix", "throwing", "reports", "Missing Studio object.", "Invalid Studio parent hierarchy.",
                        "Attachment parent has no converted character."], "\(reached.sorted())")
}

/// Two routes whose children are walked interleaved, with grandchildren
/// under each: every repeated answer replays its route's report, so the
/// status writes match the plain walk's.
@Test func studioWalkMemoReplaysInterleavedRouteReportsInOrder() {
    func folder(_ name: String, parent: UUID?) -> StudioObject {
        var object = StudioObject(name: name, kind: .folder)
        object.parent = parent
        return object
    }
    let routeA = folder("A", parent: nil), routeB = folder("B", parent: nil)
    let a1 = folder("a1", parent: routeA.id), b1 = folder("b1", parent: routeB.id)
    let a2 = folder("a2", parent: routeA.id), b2 = folder("b2", parent: routeB.id)
    let a1x = folder("a1x", parent: a1.id), b1x = folder("b1x", parent: b1.id), a1xy = folder("a1xy", parent: a1x.id)
    let objects = [routeA, routeB, a1, b1, a2, b2, a1x, b1x, a1xy]
    var rng = LookupSeed(state: 387)
    let scene = WalkScene(objects: objects, local: objects.map { _ in randomMatrix(&rng) }, routes: [routeA.id, routeB.id],
                          routeOffset: [routeA.id: randomMatrix(&rng), routeB.id: randomMatrix(&rng)],
                          attached: objects.map { _ in false }, throwing: objects.map { _ in false }, attachments: [:])
    for order in [objects, objects.reversed(), [a1xy, b1x, a1x, b2, a2, b1, a1, routeB, routeA]] {
        let plain = WalkRun(scene, memoized: false), memoized = WalkRun(scene, memoized: true)
        for object in order + order {
            #expect(outcome { try memoized.world(object.id) } == outcome { try plain.world(object.id) })
        }
        #expect(memoized.reports == plain.reports)
        #expect(statusWrites(memoized.reports) == statusWrites(plain.reports))
        #expect(Set(plain.reports).count == 2 && statusWrites(plain.reports).count > 2, "the routes interleave")
        #expect(memoized.evaluations == objects.count && plain.evaluations > memoized.evaluations)
    }
}

/// The one intended change (#387): a parent cycle through a route object
/// restarts the plain walk's chain at the route, so it recursed without end.
/// Through the memo, every object on it throws the cycle error.
@Test func studioWalkMemoStopsACycleThroughARoute() {
    var route = StudioObject(name: "Route", kind: .folder)
    var child = StudioObject(name: "Child", kind: .folder)
    let grandchild = { var o = StudioObject(name: "Grandchild", kind: .folder); o.parent = child.id; return o }()
    child.parent = route.id
    route.parent = grandchild.id
    let objects = [route, child, grandchild]
    let scene = WalkScene(objects: objects, local: objects.map { _ in matrix_identity_float4x4 }, routes: [route.id], routeOffset: [:],
                          attached: [false, false, false], throwing: [false, false, false], attachments: [:])
    for first in objects {
        let memoized = WalkRun(scene, memoized: true)
        for object in [first] + objects {
            #expect(outcome { try memoized.world(object.id) } == .error("Invalid Studio parent hierarchy."), "\(object.name)")
        }
        #expect(memoized.reports.isEmpty)
    }
}

/// A changed attachment parent drops the stored matrices that read it,
/// grandchildren included, and leaves the others.
@Test func studioWalkMemoInvalidatesWhatReadAChangedParent() throws {
    let character = StudioObject(name: "Character", kind: .folder)
    var prop = StudioObject(name: "Prop", kind: .folder)
    prop.parent = character.id
    var charm = StudioObject(name: "Charm", kind: .folder)
    charm.parent = prop.id
    let other = StudioObject(name: "Other", kind: .folder)
    var rng = LookupSeed(state: 3_870)
    let objects = [character, prop, charm, other]
    let scene = WalkScene(objects: objects, local: objects.map { _ in randomMatrix(&rng) }, routes: [], routeOffset: [:],
                          attached: [false, true, false, false], throwing: [false, false, false, false],
                          attachments: [character.id: randomMatrix(&rng)])
    let memoized = WalkRun(scene, memoized: true)
    for object in objects { _ = try memoized.world(object.id) }
    #expect(memoized.evaluations == 4)
    memoized.scene.attachments[character.id] = nil
    memoized.memo?.invalidate(character.id)
    for object in [charm, prop] {
        #expect(outcome { try memoized.world(object.id) } == .error("Attachment parent has no converted character."))
    }
    _ = try memoized.world(other.id)
    _ = try memoized.world(character.id)
    #expect(memoized.evaluations == 6, "only the prop and its charm were evaluated again")
    let moved = randomMatrix(&rng)
    memoized.scene.attachments[character.id] = moved
    memoized.memo?.invalidate(character.id)
    let plain = WalkRun(memoized.scene, memoized: false)
    #expect(outcome { try memoized.world(charm.id) } == outcome { try plain.world(charm.id) })
}
