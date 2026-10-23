import Foundation
import Testing
import simd
import CoreMath
import Assets
import Character
@testable import Scene
@testable import Studio

private typealias Row = SourceMakerLibrary.CatalogRow

private func row(_ stateType: Int, _ extra: [String: String] = [:]) -> Row {
    .row(extra.merging(["StateType": String(stateType)]) { current, _ in current })
}

/// Nine catalog rows: `rows` overrides the default (every kind a StateType 0
/// garment, both shoes present).
private func rules(_ rows: [Int: Row] = [:], switches: [Int: Set<String>] = [:], ids: [Int] = Array(repeating: 1, count: 9),
                   modded: [Bool] = Array(repeating: false, count: 9)) -> SourceStudioWear {
    SourceStudioWear(catalog: (0..<9).map { rows[$0] ?? row(0) }, switchNodes: (0..<9).map { switches[$0] ?? [] }, ids: ids, modded: modded)
}

private let on = [UInt8](repeating: 0, count: 9)

@Test func sourceStudioWearStateKindsFollowAddClothesStateKind() {
    // StateType 0 -> {0,1,3}, 1 -> {0,3}, 2 -> {0,1,2,3}; an empty row (none)
    // or any other StateType is not a state kind.
    let wear = rules([4: row(1), 5: row(2), 6: .none, 7: row(7), 8: row(0)])
    #expect(wear.allowed[4] == [0, 3] && wear.allowed[5] == [0, 1, 2, 3] && wear.allowed[6] == nil && wear.allowed[7] == nil && wear.allowed[8] == [0, 1, 3])
    #expect(wear.unknownKinds.isEmpty)
    // Top/bottom widening through the top's n_bot_a node: a dressed-only top
    // (StateType 0) forces a StateType 1 bottom to the top's set.
    #expect(rules([0: row(0), 1: row(1)], switches: [0: ["n_bot_a"]]).allowed[1] == [0, 1, 3])
    #expect(rules([0: row(1), 1: row(2)], switches: [0: ["n_bot_a"]]).allowed[1] == [0, 3])
    #expect(rules([0: row(0), 1: row(1)]).allowed[1] == [0, 3])
    // ... and through the bottom's n_top_a node in the other direction.
    #expect(rules([0: row(1), 1: row(0)], switches: [1: ["n_top_a"]]).allowed[0] == [0, 1, 3])
    // Bra/shorts: a NotBra top removes the bra kind; a no-shorts bra
    // (Coordinate 2) keeps the shorts kind only while the bra exists.
    let notBra = rules([0: row(0, ["NotBra": "1"]), 2: row(0), 3: row(0)])
    #expect(notBra.notBra && notBra.allowed[2] == nil && notBra.allowed[3] == [0, 1, 3])
    let notShorts = rules([0: row(0, ["NotBra": "1"]), 2: row(0, ["Coordinate": "2"]), 3: row(1)])
    #expect(notShorts.notShorts && notShorts.allowed[2] == nil && notShorts.allowed[3] == nil)
    // HideShorts: the row's flag, or the fallback bottom-ID list when the
    // column is absent ("0" from GetInfo is not "1").
    #expect(rules([1: row(0, ["HideShorts": "1"])]).hideShortsBot)
    #expect(!rules([1: row(0, ["HideShorts": "0"])], ids: [1, 2, 1, 1, 1, 1, 1, 1, 1]).hideShortsBot)
    #expect(rules([1: row(0)], ids: [1, 2, 1, 1, 1, 1, 1, 1, 1]).hideShortsBot)
    #expect(!rules([1: row(0)], ids: [1, 4, 1, 1, 1, 1, 1, 1, 1]).hideShortsBot)
}

@Test func sourceStudioWearUnconvertedRowsKeepEveryStateAndAreReported() {
    let wear = rules([0: .unknown("reference"), 6: .unknown("reference")])
    #expect(wear.unknownKinds == [0, 1, 2, 3, 6])
    #expect(wear.allowed[0] == [0, 1, 2, 3] && wear.allowed[3] == [0, 1, 2, 3] && wear.allowed[6] == [0, 1, 2, 3])
    // The saved byte is kept, never re-guessed.
    let saved: [UInt8] = [2, 1, 2, 1, 0, 0, 2, 0, 0]
    #expect(wear.loaded(saved)[0...3] == saved[0...3] && wear.loaded(saved)[6] == 2)
    // A modded unknown bottom does not use the vanilla HideShorts ID list.
    #expect(rules([1: .unknown("x")], ids: [1, 2, 1, 1, 1, 1, 1, 1, 1]).hideShortsBot)
    #expect(!rules([1: .unknown("x")], ids: [1, 2, 1, 1, 1, 1, 1, 1, 1], modded: [false, true] + Array(repeating: false, count: 7)).hideShortsBot)
}

@Test func sourceStudioWearSetClothesStateAdvancesAndRunsTheLinks() {
    let wear = rules([4: row(1), 6: .none])
    // A state the kind does not allow advances to the next allowed one.
    #expect(wear.setting(on, kind: 4, state: 1)[4] == 3)
    #expect(wear.setting(on, kind: 4, state: 2)[4] == 3)
    #expect(wear.setting(on, kind: 0, state: 2)[0] == 3)
    // Not a state kind: assigned as-is.
    #expect(wear.setting(on, kind: 6, state: 2)[6] == 2)
    // The shoes row (kind 7) mirrors to kind 8, both ways.
    let shoesOff = wear.setting(on, kind: 7, state: 3)
    #expect(shoesOff[7] == 3 && shoesOff[8] == 3)
    #expect(wear.setting(shoesOff, kind: 7, state: 0)[8] == 0)
    #expect(rules([8: .none]).setting([0, 0, 0, 0, 0, 0, 0, 3, 3], kind: 7, state: 0)[8] == 3)
    // A one-piece top (Coordinate 2) drags the bottom with it.
    let onePiece = rules([0: row(0, ["Coordinate": "2"])])
    #expect(onePiece.notBot)
    let topOff = onePiece.setting(on, kind: 0, state: 3)
    #expect(topOff[0] == 3 && topOff[1] == 3)
    let topHalf = onePiece.setting(topOff, kind: 0, state: 1)
    #expect(topHalf[0] == 1 && topHalf[1] == 1)
    // The whole-outfit buttons and the load replay.
    #expect(wear.settingAll(on, state: 1) == [1, 1, 1, 1, 3, 1, 1, 1, 1])
    #expect(wear.loaded([1, 0, 0, 0, 1, 0, 0, 0, 0])[4] == 3)
    #expect(wear.loaded([3, 3, 3, 3, 3, 3, 3, 3, 3]) == [3, 3, 3, 3, 3, 3, 3, 3, 3])
}

@Test func sourceStudioWearUpdateVisibleTables() {
    let wear = rules()
    #expect((0..<9).map { wear.visible(kind: $0, states: on, shoesType: 1) } == [true, true, true, true, true, true, true, false, true])
    #expect((0..<9).map { wear.visible(kind: $0, states: on, shoesType: 0) } == [true, true, true, true, true, true, true, true, false])
    // Half states: tops/bottoms/underwear stay drawn (their switch nodes
    // change), gloves/socks/shoes hide, pantyhose hides only at half 2.
    let half: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1, 1]
    #expect((0..<9).map { wear.visible(kind: $0, states: half, shoesType: 1) } == [true, true, true, true, false, true, false, false, false])
    #expect(!wear.visible(kind: 5, states: [0, 0, 0, 0, 0, 2, 0, 0, 0], shoesType: 1))
    // HideShorts hides the shorts only under a dressed, drawn bottom.
    let hide = rules([1: row(0, ["HideShorts": "1"])])
    #expect(!hide.visible(kind: 3, states: on, shoesType: 1))
    #expect(hide.visible(kind: 3, states: [0, 1, 0, 0, 0, 0, 0, 0, 0], shoesType: 1))
    #expect(!rules([0: row(0, ["Coordinate": "2"])]).visible(kind: 1, states: on, shoesType: 1))
    // Switch nodes and the body alpha mask.
    #expect(SourceStudioWear.switchActive(kind: 0, node: "n_top_a", states: on) == true)
    #expect(SourceStudioWear.switchActive(kind: 0, node: "n_top_b", states: [1, 0, 0, 0, 0, 0, 0, 0, 0]) == true)
    #expect(SourceStudioWear.switchActive(kind: 0, node: "n_bot_b", states: [3, 1, 0, 0, 0, 0, 0, 0, 0]) == false)
    #expect(SourceStudioWear.switchActive(kind: 3, node: "n_bot_c", states: [0, 0, 0, 2, 0, 0, 0, 0, 0]) == true)
    #expect(SourceStudioWear.switchActive(kind: 4, node: "n_top_a", states: on) == nil)
    #expect(SourceStudioWear.bodyAlpha(topState: 0) == SIMD2(1, 1) && SourceStudioWear.bodyAlpha(topState: 1) == SIMD2(0, 1)
        && SourceStudioWear.bodyAlpha(topState: 2) == SIMD2(0, 1) && SourceStudioWear.bodyAlpha(topState: 3) == SIMD2(0, 0))
}

/// An assembled rig: a top with dressed meshes under n_top_a and an empty
/// n_top_b (the conversion drops the alternate meshes), outdoor shoes, one
/// accessory in slot 3 and one hair part.
private func wearRig() throws -> SourceRig {
    let names: [(String, String, Int?)] = [
        ("root", "root", nil),
        ("p_top", "clothes-0/p_top", 0), ("n_top_a", "clothes-0/p_top/n_top_a", 1), ("top_mesh", "clothes-0/p_top/n_top_a/top_mesh", 2),
        ("n_top_b", "clothes-0/p_top/n_top_b", 1),
        ("p_shoes", "clothes-1/p_shoes", 0), ("shoes_mesh", "clothes-1/p_shoes/shoes_mesh", 5),
        ("p_acc", "accessory-3/p_acc", 0), ("acc_mesh", "accessory-3/p_acc/acc_mesh", 7),
        ("p_hair", "hair-0/p_hair", 0),
        ("body_mesh", "body/body_mesh", 0),
    ]
    let nodes = names.map { RigDefinition.Node(name: $0.0, sourceID: $0.1, parent: $0.2) }
    func part(_ node: Int) -> SourceRig.Part {
        .init(mesh: MeshData(name: names[node].0, positions: [Float3(0, 0, 0)], normals: [Float3(0, 1, 0)],
                             joints: [SIMD4<UInt16>(0, 0, 0, 0)], weights: [Float4(1, 0, 0, 0)], indices: [0, 0, 0]),
              node: node, skin: 0, rendererEnabled: true)
    }
    return SourceRig(sourcePrefab: "wear", rig: try RigDefinition(nodes: nodes, skins: []),
                     parts: [part(3), part(6), part(8), part(9), part(10)], morphChannelCount: 0)
}

@Test func sourceStudioWearLayoutMapsRenderersAndReportsUndrawableStates() throws {
    let layout = SourceStudioWearLayout(source: try wearRig(), clothingSlots: [0, 8])
    #expect(layout.parts == [.clothing(kind: 0, switches: ["n_top_a"]), .clothing(kind: 8, switches: []), .accessory(slot: 3), .hair, .other])
    #expect(layout.switchNodes == [0: ["n_top_a", "n_top_b"]] && layout.clothingKinds == [0, 8] && layout.accessorySlots == [3])
    let wear = rules()
    let shown = [Bool](repeating: true, count: 20)
    let dressed = layout.evaluate(rules: wear, states: on, shoesType: 1, showAccessory: shown, hideHairSlots: [])
    #expect(dressed.hiddenParts.isEmpty && dressed.renderedClothing == [0, 8] && dressed.renderedAccessories == [3])
    #expect(dressed.bodyAlpha == SIMD2(1, 1) && dressed.fallbacks.isEmpty && !dressed.hairHidden)
    // Off hides the garment and opens the body mask.
    let topOff = layout.evaluate(rules: wear, states: [3, 0, 0, 0, 0, 0, 0, 0, 0], shoesType: 1, showAccessory: shown, hideHairSlots: [])
    #expect(topOff.hiddenParts == [0] && topOff.renderedClothing == [8] && topOff.bodyAlpha == SIMD2(0, 0) && topOff.fallbacks.isEmpty)
    // Half activates n_top_b, which holds no converted mesh: the dressed
    // meshes and body mask stay, and the fallback is reported.
    let half: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 0]
    let topHalf = layout.evaluate(rules: wear, states: half, shoesType: 1, showAccessory: shown, hideHairSlots: [])
    #expect(topHalf.hiddenParts.isEmpty && topHalf.bodyAlpha == SIMD2(1, 1))
    #expect(topHalf.fallbacks.count == 1 && topHalf.fallbacks[0].contains("alternate meshes under n_top_b are not converted"))
    // An unconverted catalog row is named first, whatever nodes it carries.
    let unknown = layout.evaluate(rules: rules([0: .unknown("reference")]), states: half, shoesType: 1, showAccessory: shown, hideHairSlots: [])
    #expect(unknown.hiddenParts.isEmpty && unknown.fallbacks.count == 1 && unknown.fallbacks[0].contains("half state cannot be rendered"))
    // The outdoor-shoe geometry follows shoes_outer for shoesType 1 and
    // stands in for the indoor shoes (shoes_inner) for shoesType 0.
    #expect(layout.evaluate(rules: wear, states: [0, 0, 0, 0, 0, 0, 0, 0, 3], shoesType: 1, showAccessory: shown, hideHairSlots: []).hiddenParts == [1])
    #expect(layout.evaluate(rules: wear, states: [0, 0, 0, 0, 0, 0, 0, 0, 3], shoesType: 0, showAccessory: shown, hideHairSlots: []).hiddenParts.isEmpty)
    #expect(layout.evaluate(rules: wear, states: [0, 0, 0, 0, 0, 0, 0, 3, 0], shoesType: 0, showAccessory: shown, hideHairSlots: []).hiddenParts == [1])
    #expect(layout.evaluate(rules: wear, states: on, shoesType: 2, showAccessory: shown, hideHairSlots: []).hiddenParts == [1])
    // Accessory flags hide their renderers; a shown HideHair accessory hides
    // the hair, a hidden one does not.
    var accessoryOff = shown; accessoryOff[3] = false
    let hidden = layout.evaluate(rules: wear, states: on, shoesType: 1, showAccessory: accessoryOff, hideHairSlots: [3])
    #expect(hidden.hiddenParts == [2] && hidden.renderedAccessories.isEmpty && !hidden.hairHidden)
    let hairHidden = layout.evaluate(rules: wear, states: on, shoesType: 1, showAccessory: shown, hideHairSlots: [3])
    #expect(hairHidden.hiddenParts == [3] && hairHidden.hairHidden)
}
