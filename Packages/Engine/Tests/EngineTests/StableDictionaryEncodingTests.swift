import Foundation
import Testing
import Character
import Studio

// #394: dictionaries keyed by an enum, Int32 or UUID save as Swift's
// alternating key/value array. These tests pin that array to key order and
// keep the format, so old files written in hash order still decode.

private func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys] // CardIO.encode's setting
    return try encoder.encode(value)
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The keys of an alternating key/value array, in saved order.
private func keys(_ array: Any?) throws -> [Any] {
    let array = try #require(array as? [Any])
    try #require(array.count % 2 == 0)
    return stride(from: 0, to: array.count, by: 2).map { array[$0] }
}

private func slotCard(slotOrder: [ClothSlot], hairOrder: [HairSlot], capacity: Int) -> CharacterCard {
    var card = CharacterCard()
    card.id = UUID(uuidString: "6F1A7C2E-0000-4000-8000-000000000394")!
    var items: [ClothSlot: ClothItem] = [:], states: [ClothSlot: ClothState] = [:]
    items.reserveCapacity(capacity); states.reserveCapacity(capacity)
    for slot in slotOrder {
        let index = ClothSlot.allCases.firstIndex(of: slot)!
        items[slot] = ClothItem(itemID: "item_\(slot.rawValue)")
        states[slot] = ClothState.allCases[index % ClothState.allCases.count]
    }
    var parts: [HairSlot: HairPart] = [:]; parts.reserveCapacity(capacity)
    for slot in hairOrder { parts[slot] = HairPart(styleID: "style_\(slot.rawValue)") }
    card.outfits[0].items = items
    card.outfits[0].states = states
    card.hair.parts = parts
    return card
}

@Test func cardSlotDictionariesSaveInDeclarationOrderWhateverTheirInsertionOrder() throws {
    let forward = slotCard(slotOrder: ClothSlot.allCases, hairOrder: HairSlot.allCases, capacity: 0)
    let backward = slotCard(slotOrder: ClothSlot.allCases.reversed(), hairOrder: HairSlot.allCases.reversed(), capacity: 64)
    var shuffled = SystemRandomNumberGenerator()
    let random = slotCard(slotOrder: ClothSlot.allCases.shuffled(using: &shuffled), hairOrder: HairSlot.allCases.shuffled(using: &shuffled), capacity: 17)
    #expect(forward == backward && forward == random)
    let bytes = try sortedJSON(forward)
    #expect(try sortedJSON(backward) == bytes)
    #expect(try sortedJSON(random) == bytes)
    // The PNG card writes the same payload.
    let png = try CardIO.encode(forward, keyword: CardIO.cardKeyword, thumbnail: nil)
    #expect(try CardIO.encode(backward, keyword: CardIO.cardKeyword, thumbnail: nil) == png)
    #expect(try CardIO.encode(random, keyword: CardIO.cardKeyword, thumbnail: nil) == png)

    let json = try object(bytes)
    let outfit = try #require((json["outfits"] as? [[String: Any]])?.first)
    #expect(try keys(outfit["items"]) as? [String] == ClothSlot.allCases.map(\.rawValue))
    #expect(try keys(outfit["states"]) as? [String] == ClothSlot.allCases.map(\.rawValue))
    #expect(try keys((json["hair"] as? [String: Any])?["parts"]) as? [String] == HairSlot.allCases.map(\.rawValue))
}

@Test func cardSlotDictionariesKeepTheFormatAndDecodeOldHashOrderFiles() throws {
    let card = slotCard(slotOrder: ClothSlot.allCases, hairOrder: HairSlot.allCases, capacity: 0)
    let bytes = try sortedJSON(card)
    var json = try object(bytes)
    // Same format: the entries are exactly what Dictionary's own encoding writes.
    let items = try #require((json["outfits"] as? [[String: Any]])?.first?["items"] as? [Any])
    let plain = try #require(try JSONSerialization.jsonObject(with: sortedJSON(card.outfits[0].items)) as? [Any])
    #expect(items.count == plain.count && items.count == 2 * ClothSlot.allCases.count)
    func pairs(_ array: [Any]) throws -> Set<String> {
        Set(try stride(from: 0, to: array.count, by: 2).map {
            "\(array[$0])=" + String(decoding: try JSONSerialization.data(withJSONObject: array[$0 + 1], options: .sortedKeys), as: UTF8.self)
        })
    }
    #expect(try pairs(items) == pairs(plain))
    // A file written before #394 in another order decodes to the same card and saves in key order again.
    func reversedPairs(_ array: [Any]) -> [Any] {
        stride(from: array.count - 2, through: 0, by: -2).flatMap { [array[$0], array[$0 + 1]] }
    }
    var outfits = try #require(json["outfits"] as? [[String: Any]])
    outfits[0]["items"] = reversedPairs(items)
    outfits[0]["states"] = reversedPairs(try #require(outfits[0]["states"] as? [Any]))
    json["outfits"] = outfits
    var hair = try #require(json["hair"] as? [String: Any])
    hair["parts"] = reversedPairs(try #require(hair["parts"] as? [Any]))
    json["hair"] = hair
    let old = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    #expect(old != bytes)
    let decoded = try JSONDecoder().decode(CharacterCard.self, from: old)
    #expect(decoded == card)
    #expect(try sortedJSON(decoded) == bytes)
}

@Test func documentIKAndPluginIdentityDictionariesSaveInKeyOrder() throws {
    var character = StudioObject.character(CharacterCard())
    var targets: [IKChain: IKTarget] = [:]
    for (index, chain) in IKChain.allCases.reversed().enumerated() {
        targets[chain] = IKTarget(enabled: true, position: .init(Float(index), 0, 0))
    }
    character.ikTargets = targets
    character.sourceIKOverrides = [30: .init(position: .one), 2: .init(position: .zero), -1: .init(position: .one), 11: .init(position: .zero)]
    var document = StudioDocument()
    document.objects = [character]
    document.timeline.keyframes = [Keyframe(time: 0.5, object: character)]
    let identities = ["F0000000-0000-4000-8000-000000000001", "0A000000-0000-4000-8000-000000000002", "B5000000-0000-4000-8000-000000000003"]
    let state = """
    {"packages":[],"bindings":[],"clock":{"elapsedTime":0,"accumulator":0,"deltaTime":0.02,"fixedDeltaTime":0.02},
     "objectIdentities":["\(identities[0])","a","\(identities[1])","b","\(identities[2])","c"],"cloneSerial":3}
    """
    document.sourcePluginState = try JSONDecoder().decode(SourceStudioPluginState.self, from: Data(state.utf8))

    let json = try object(sortedJSON(document))
    let saved = try #require((json["objects"] as? [[String: Any]])?.first)
    #expect(try keys(saved["ikTargets"]) as? [String] == IKChain.allCases.map(\.rawValue))
    #expect(try keys(saved["sourceIKOverrides"]) as? [Int] == [-1, 2, 11, 30])
    let keyframe = try #require(((json["timeline"] as? [String: Any])?["keyframes"] as? [[String: Any]])?.first)
    #expect(try keys(keyframe["ikTargets"]) as? [String] == IKChain.allCases.map(\.rawValue))
    let plugin = try #require(json["sourcePluginState"] as? [String: Any])
    #expect(try keys(plugin["objectIdentities"]) as? [String] == identities.sorted())
    #expect((plugin["objectIdentities"] as? [Any])?.count == 6)
    // Decoding is unchanged: the document round-trips.
    #expect(try JSONDecoder().decode(StudioDocument.self, from: sortedJSON(document)) == document)
    // A nil dictionary still writes no key.
    character.sourceIKOverrides = nil
    document.objects = [character]
    let unset = try #require((try object(sortedJSON(document))["objects"] as? [[String: Any]])?.first)
    #expect(unset["sourceIKOverrides"] == nil && unset["ikTargets"] != nil)
}
