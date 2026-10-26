import Foundation
import Testing
import Scene
@testable import Studio

// R7 phase 2 item 6 follow-up: the bounded cache of dropped previews'
// donations keeps, replaces, evicts and hands out donations by their logical
// charge and its entry budget.

private func donationRig(_ name: String, vertices: Int) throws -> SourceRig {
    let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    let count = max(3, vertices)
    let positions = (0..<count).map { [Float($0), 0, 1] }
    let data = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "coordinateSpace": "unity-left-handed-y-up", "matrixLayout": "column-major",
        "uvConvention": "unity-source", "sourcePrefab": name,
        "nodes": [["name": "root", "sourceID": "root", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]]],
        "skins": [["name": "skin", "meshNode": 0, "joints": [0], "inverseBindMatrices": [identity]]],
        "meshes": [["name": "part", "node": 0, "skin": 0,
            "positions": positions, "normals": Array(repeating: [0, 0, 1], count: count),
            "tangents": [], "uv0": [], "joints": Array(repeating: [0, 0, 0, 0], count: count),
            "weights": Array(repeating: [1, 0, 0, 0], count: count),
            "submeshes": [["indices": [0, 1, 2]]], "morphChannels": []]]
    ] as [String: Any], options: .sortedKeys)
    return try SourceRig.decode(data)
}

private func donation(key: Int32, coordinate: Int = 0, vertices: Int, store: ObjectIdentifier) throws -> SourceStudioCharacterPreview.Donation {
    let reference = SourceStudioCharacterReference(sceneFile: "/scenes/scene.png", sceneSHA256: String(repeating: "a", count: 64),
        rigFile: "/rigs/source-avatar.json", boneCatalogFile: "/rigs/contract.json", objectKey: key)
    return .init(reference: reference, coordinate: coordinate, savedCoordinate: 0, resources: store,
                 rigURL: URL(fileURLWithPath: "/rigs/source-avatar.json"), directory: URL(fileURLWithPath: "/rigs"),
                 prepared: nil, source: try donationRig("rig-\(key)", vertices: vertices), contract: nil)
}

private final class DonationStore {}

@Test func sourceStudioDonationCacheEvictsTheOldestToStayWithinItsBudget() throws {
    let owner = DonationStore(), store = ObjectIdentifier(owner)
    defer { withExtendedLifetime(owner) {} }
    let a = try donation(key: 1, vertices: 400, store: store), b = try donation(key: 2, vertices: 400, store: store)
    let c = try donation(key: 3, vertices: 400, store: store)
    let charge = try #require(SourceStudioDonationCache.charge(a))
    #expect(charge == SourceStudioDonationCache.charge(b) && charge > 400 * 16)
    // Room for two of the three.
    let cache = SourceStudioDonationCache(maximumBytes: 2 * charge + charge / 2, maximumEntries: 8)
    #expect(cache.keep(a) && cache.keep(b) && cache.count == 2 && cache.bytes == 2 * charge)
    #expect(cache.keep(c))
    #expect(cache.count == 2 && cache.bytes == 2 * charge && cache.counts.evicted == 1)
    #expect(cache.take { $0.reference.objectKey == 1 } == nil, "the oldest donation is evicted first")
    let taken = try #require(cache.take { $0.reference.objectKey == 2 })
    #expect(taken.source.sourcePrefab == "rig-2" && cache.count == 1 && cache.bytes == charge)
    #expect(cache.take { $0.reference.objectKey == 2 } == nil, "a taken donation is no longer kept")
    #expect(cache.counts == .init(kept: 3, evicted: 1, taken: 1))
}

@Test func sourceStudioDonationCacheRefusesWhatExceedsItsBudgetAndReplacesTheSameCharacter() throws {
    // Both stores stay alive so that their identifiers differ.
    let owners = (DonationStore(), DonationStore())
    defer { withExtendedLifetime(owners) {} }
    let store = ObjectIdentifier(owners.0), other = ObjectIdentifier(owners.1)
    let small = try donation(key: 1, vertices: 10, store: store)
    let large = try donation(key: 2, vertices: 4_000, store: store)
    let smallCharge = try #require(SourceStudioDonationCache.charge(small))
    let cache = SourceStudioDonationCache(maximumBytes: smallCharge * 4, maximumEntries: 2)
    #expect(!cache.keep(large), "a donation larger than the whole budget is refused")
    #expect(cache.count == 0 && cache.counts.refused == 1)
    #expect(cache.keep(small))
    // The same character and outfit on the same store replaces the older one.
    let again = try donation(key: 1, vertices: 10, store: store)
    #expect(cache.keep(again) && cache.count == 1 && cache.counts.replaced == 1 && cache.bytes == smallCharge)
    // Another outfit or another store is another entry; the entry budget evicts.
    #expect(cache.keep(try donation(key: 1, coordinate: 1, vertices: 10, store: store)) && cache.count == 2)
    #expect(cache.keep(try donation(key: 1, vertices: 10, store: other)) && cache.count == 2 && cache.counts.evicted == 1)
    #expect(cache.take { $0.coordinate == 0 && $0.resources == store } == nil)
    cache.removeAll()
    #expect(cache.count == 0 && cache.bytes == 0)
    let off = SourceStudioDonationCache(maximumBytes: 1 << 30, maximumEntries: 0)
    #expect(!off.keep(small) && off.count == 0)
}
