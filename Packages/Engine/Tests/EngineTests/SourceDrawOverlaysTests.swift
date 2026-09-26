import Foundation
import Testing
import Assets
import Character

/// Synthetic records; no source imagery or plug-in execution.
private enum DrawOverlayFixture {
    typealias F = OriginalCardFixture

    /// Binds every slot from card data: the active makeup record (coordinate
    /// outfit 0's record when `enableMakeup`, otherwise the face record's
    /// `baseMakeup`) carries lip 7 / eyeshadow 5 with the given colors
    /// (defaults all 0.25/0.5/0.75/0.8); the body record carries nip 2 /
    /// underhair 6 and the face record carries hlUp 3 / hlDown 4, so every
    /// slot has real fields to bind from.
    static func card(lip: (id: Int, color: F.Value)? = nil,
                     eyeshadow: (id: Int, color: F.Value)? = nil,
                     enableMakeup: Bool = false,
                     missingIDs: Set<String> = [], unreadableIDs: Set<String> = []) throws -> SourceCharacterCard {
        let rgba = F.Value.array([.float(0.25), .float(0.5), .float(0.75), .float(0.8)])
        func idEntry(_ name: String, _ value: Int) -> [(String, F.Value)] {
            if missingIDs.contains(name) { return [] }
            return [(name, unreadableIDs.contains(name) ? .string("invalid") : .integer(Int64(value)))]
        }
        // Each record carries every makeup slot's source entry; a supplied
        // entry overrides only its slot's entry in the record that selection
        // actually uses — mirror of `MakeupFixture` in the
        // material-expansion tests, extended with the body and face slots.
        func makeup(lip: (id: Int, color: F.Value)?, eyeshadow: (id: Int, color: F.Value)?,
                    ids: (lip: Int, eyeshadow: Int)) -> [(String, F.Value)] {
            var entries: [(String, F.Value)] = [("version", .string("0.0.0"))]
            let lip = lip ?? (ids.lip, rgba)
            let eyeshadow = eyeshadow ?? (ids.eyeshadow, rgba)
            entries += idEntry("lipId", lip.id) + [("lipColor", lip.color)]
            entries += idEntry("eyeshadowId", eyeshadow.id) + [("eyeshadowColor", eyeshadow.color)]
            return entries
        }
        let base = makeup(lip: lip, eyeshadow: eyeshadow, ids: (7, 5))
        let coordinate = makeup(lip: lip, eyeshadow: eyeshadow, ids: (11, 9))
        let face = F.pack(F.map([
            ("version", .string("0.0.2")), ("headId", .integer(0)),
            ("shapeValueFace", .array(F.faceValues)),
            ("hlUpColor", rgba), ("hlDownColor", rgba),
            ("baseMakeup", enableMakeup ? F.map([("version", .string("0.0.0"))]) : F.map(base)),
        ] + idEntry("hlUpId", 3) + idEntry("hlDownId", 4)))
        let body = F.pack(F.map([
            ("version", .string("0.0.2")), ("shapeValueBody", .array(F.bodyValues)),
            ("skinId", .integer(0)), ("skinMainColor", rgba), ("skinSubColor", rgba),
            ("nipColor", rgba), ("underhairColor", rgba),
        ] + idEntry("nipId", 2) + idEntry("underhairId", 6)))
        let hair = F.pack(F.map([("version", .string("0.0.4"))]))
        let custom = F.lengthData(face) + F.lengthData(body) + F.lengthData(hair)
        let clothes = F.pack(F.map([("version", .string("0.0.1")), ("parts", .array([]))]))
        let accessory = F.pack(F.map([("version", .string("0.0.2")),
                                       ("parts", .array([F.map([("id", .integer(17)), ("color", .array([rgba]))])]))]))
        let coordinateEntry = F.lengthData(clothes) + F.lengthData(accessory) + Data([enableMakeup ? 1 : 0])
            + F.lengthData(F.pack(F.map(enableMakeup ? coordinate : base)))
        var blocks = F.blocks(custom: custom)
        blocks.append(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array([.binary(coordinateEntry)]))))
        return try SourceCharacterCard.decode(F.card(blocks: blocks))
    }
}

@Test func sourceDrawOverlaysSelectsBaseThenCoordinateMakeup() throws {
    let rgba = SIMD4<Float>(0.25, 0.5, 0.75, 0.8)
    for enabled in [false, true] {
        let card = try DrawOverlayFixture.card(enableMakeup: enabled)
        let (bindings, diagnostics) = try SourceDrawOverlays.bindings(card: card, hohoAkaRate: 0)
        #expect(diagnostics == ["face.overtex2 blush RGB comes from the prefab material, not the card."])
        let lip = try #require(bindings.first { $0.category == "mt_lip" })
        #expect(lip == .init(material: .face, slot: .overtex1, category: "mt_lip",
                              id: enabled ? 11 : 7, rgba: rgba))
        let eyeshadow = try #require(bindings.first { $0.category == "mt_eyeshadow" })
        #expect(eyeshadow == .init(material: .face, slot: .overtex3, category: "mt_eyeshadow",
                                   id: enabled ? 9 : 5, rgba: rgba))
    }
}

@Test func sourceDrawOverlaysGagEyesPinsEyeshadowAlphaToZero() throws {
    let card = try DrawOverlayFixture.card()
    let (plain, _) = try SourceDrawOverlays.bindings(card: card)
    let (gagged, _) = try SourceDrawOverlays.bindings(card: card, gagEyes: true)
    #expect(plain.first { $0.category == "mt_eyeshadow" }?.rgba == SIMD4(0.25, 0.5, 0.75, 0.8))
    #expect(gagged.first { $0.category == "mt_eyeshadow" }?.rgba == SIMD4(0.25, 0.5, 0.75, 0))
}

@Test func sourceDrawOverlaysBlushOnlyBindsAlphaFromHohoAkaRate() throws {
    let card = try DrawOverlayFixture.card()
    let rates: [(Float, Float)] = [(0, 0), (0.5, 0.1), (1, 0.2),
                                  (1.5, 0.2), (-0.5, 0), (.nan, 0)]
    for (rate, alpha) in rates {
        let (bindings, diagnostics) = try SourceDrawOverlays.bindings(card: card, hohoAkaRate: rate)
        let blush = try #require(bindings.first { $0.category == "prefab" })
        #expect(blush.material == .face && blush.slot == .overtex2 && blush.category == "prefab")
        #expect(blush.id == nil && blush.rgba == SIMD4(1, 1, 1, alpha))
        #expect(blush.rgbFromPrefab)
        #expect(diagnostics == ["face.overtex2 blush RGB comes from the prefab material, not the card."])
    }
}

@Test func sourceDrawOverlaysRequiresCatalogIDs() throws {
    let slots: [(id: String, category: String)] = [
        ("makeup.lipId", "mt_lip"), ("makeup.eyeshadowId", "mt_eyeshadow"),
        ("body.nipId", "mt_nip"), ("body.underhairId", "mt_underhair"),
        ("face.hlUpId", "mt_eye_hi_up"), ("face.hlDownId", "mt_eye_hi_down"),
    ]
    let names = Set(slots.compactMap { $0.id.split(separator: ".").last.map(String.init) })
    for unreadable in [false, true] {
        let card = try DrawOverlayFixture.card(missingIDs: unreadable ? [] : names,
                                               unreadableIDs: unreadable ? names : [])
        let (bindings, diagnostics) = try SourceDrawOverlays.bindings(card: card)
        #expect(bindings.map(\.category) == ["prefab"])
        for (id, category) in slots {
            #expect(diagnostics.contains("\(id) missing; \(category) not bound"))
            if unreadable {
                #expect(diagnostics.contains("\(id) is not a source catalog ID; original value retained."))
            }
        }
    }
}

@Test func sourceDrawOverlaysBindsBodyAndEyeSlots() throws {
    let (bindings, _) = try SourceDrawOverlays.bindings(card: DrawOverlayFixture.card())
    let nip = try #require(bindings.first { $0.category == "mt_nip" })
    #expect(nip == .init(material: .body, slot: .overtex1, category: "mt_nip", id: 2,
                          rgba: SIMD4(0.25, 0.5, 0.75, 0.8)))
    let underhair = try #require(bindings.first { $0.category == "mt_underhair" })
    #expect(underhair == .init(material: .body, slot: .overtex2, category: "mt_underhair", id: 6,
                               rgba: SIMD4(0.25, 0.5, 0.75, 0.8)))
    let up = try #require(bindings.first { $0.category == "mt_eye_hi_up" })
    #expect(up == .init(material: .eye, slot: .overtex1, category: "mt_eye_hi_up", id: 3,
                         rgba: SIMD4(0.25, 0.5, 0.75, 0.8)))
    let down = try #require(bindings.first { $0.category == "mt_eye_hi_down" })
    #expect(down == .init(material: .eye, slot: .overtex2, category: "mt_eye_hi_down", id: 4,
                           rgba: SIMD4(0.25, 0.5, 0.75, 0.8)))
}

@Test func sourceDrawOverlaysRejectsMalformedColorsWithoutInventedDefaults() throws {
    // Same rule as `SourceCardAppearance`: a malformed present value stays
    // unbound with a diagnostic; no placeholder color is substituted.
    let malformed: [DrawOverlayFixture.F.Value] = [
        .array([.float(0), .float(0), .float(0), .float(0.8), .float(1)]),
        .array([.float(0), .float(0), .float(0), .float(1.1)]),
        .array([.float(0), .null, .float(0), .float(1)]),
        .array([.float(0), .float(.nan), .float(0), .float(1)]),
        .integer(7),
    ]
    for color in malformed {
        let card = try DrawOverlayFixture.card(lip: (id: 7, color: color),
                                                 eyeshadow: (id: 5, color: color))
        let (bindings, diagnostics) = try SourceDrawOverlays.bindings(card: card)
        #expect(!bindings.contains { $0.category == "mt_lip" })
        #expect(diagnostics.contains { $0.hasPrefix("makeup.lipColor is not ") })
        #expect(!bindings.contains { $0.category == "mt_eyeshadow" })
        #expect(diagnostics.contains { $0.hasPrefix("makeup.eyeshadowColor is not ") })
        // The blush slot stays bound, as do the slots on records whose
        // fields are intact; only malformed fields lose their binding.
        #expect(Set(bindings.filter { $0.slot == .overtex2 }.map(\.category))
                    == ["prefab", "mt_underhair", "mt_eye_hi_down"])
    }
}
