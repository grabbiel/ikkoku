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
    // A sailor/jacket composite top's sub-parts can override notBra.
    let composite = rules([0: row(0, ["Kind": "1"])])
    #expect(composite.compositeTop && composite.unknownKinds == [2, 3] && composite.allowed[2] == [0, 1, 2, 3])
    #expect(!rules([0: row(0, ["Kind": "4"])]).compositeTop)
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

/// A Studio wear assembly with converted half-state meshes: top, bottom, bra,
/// shorts (three states), pantyhose, and both shoe slots, each garment's
/// meshes under its ChaReference switch nodes.
private func halfStateRig() throws -> (SourceRig, [Int]) {
    var names: [(String, String, Int?)] = [("root", "root", nil)]
    var parts: [Int] = []
    let garments: [(String, [(String?, String)])] = [
        ("top", [("n_top_a", "top_a"), ("n_top_b", "top_b")]),
        ("bot", [("n_bot_a", "bot_a"), ("n_bot_b", "bot_b")]),
        ("bra", [("n_top_a", "bra_a"), ("n_top_b", "bra_b")]),
        ("shorts", [("n_bot_a", "shorts_a"), ("n_bot_b", "shorts_b"), ("n_bot_c", "shorts_c")]),
        ("panst", [("n_panst_a", "panst_a"), ("n_panst_b", "panst_b")]),
        ("shoes_in", [(nil, "shoes_in")]), ("shoes_out", [(nil, "shoes_out")]),
    ]
    for (index, garment) in garments.enumerated() {
        let prefix = "clothes-\(index)/p_\(garment.0)"
        names.append(("p_" + garment.0, prefix, 0)); let root = names.count - 1
        for (switchNode, mesh) in garment.1 {
            var parent = root
            if let switchNode { names.append((switchNode, prefix + "/" + switchNode, root)); parent = names.count - 1 }
            names.append((mesh, prefix + "/" + mesh, parent)); parts.append(names.count - 1)
        }
    }
    names.append(("body_mesh", "body/body_mesh", 0)); parts.append(names.count - 1)
    let nodes = names.map { RigDefinition.Node(name: $0.0, sourceID: $0.1, parent: $0.2) }
    let rig = SourceRig(sourcePrefab: "half", rig: try RigDefinition(nodes: nodes, skins: []), parts: parts.map { node in
        .init(mesh: MeshData(name: names[node].0, positions: [Float3(0, 0, 0)], normals: [Float3(0, 1, 0)],
                             joints: [SIMD4<UInt16>(0, 0, 0, 0)], weights: [Float4(1, 0, 0, 0)], indices: [0, 0, 0]),
              node: node, skin: 0, rendererEnabled: true)
    }, morphChannelCount: 0)
    return (rig, [0, 1, 2, 3, 5, 7, 8])
}

@Test func sourceStudioWearHalfStateMeshesFollowUpdateVisible() throws {
    let (source, slots) = try halfStateRig()
    let layout = SourceStudioWearLayout(source: source, clothingSlots: slots, indoorShoes: .assembled)
    #expect(layout.clothingKinds == [0, 1, 2, 3, 5, 7, 8] && !layout.outdoorShoesStandIn)
    // Catalog rows: StateType 0 garments, StateType 2 shorts, StateType 1 shoes.
    let wear = rules([3: row(2), 7: row(1), 8: row(1)])
    let shown = [Bool](repeating: true, count: 20)
    func drawn(_ s: [UInt8], _ shoesType: Int) -> (Set<String>, SIMD2<Float>, Int) {
        let result = layout.evaluate(rules: wear, states: s, shoesType: shoesType, showAccessory: shown, hideHairSlots: [])
        let names = Set(source.parts.indices.filter { index in
            if case .clothing = layout.parts[index] { return !result.hiddenParts.contains(index) }; return false
        }.map { source.parts[$0].mesh.name })
        return (names, result.bodyAlpha, result.fallbacks.count)
    }
    // The recovered UpdateVisible table, restated per case (scene-editing.md):
    // half (1) swaps _a for _b; half 2 shows neither for top/bottom/bra and
    // n_bot_c for the shorts; pantyhose hides at half 2; shoes by shoesType.
    let table: [([UInt8], Int, Set<String>, SIMD2<Float>)] = [
        ([0, 0, 0, 0, 0, 0, 0, 0, 0], 1, ["top_a", "bot_a", "bra_a", "shorts_a", "panst_a", "shoes_out"], SIMD2(1, 1)),
        ([0, 0, 0, 0, 0, 0, 0, 0, 0], 0, ["top_a", "bot_a", "bra_a", "shorts_a", "panst_a", "shoes_in"], SIMD2(1, 1)),
        ([1, 1, 0, 0, 0, 1, 0, 0, 0], 0, ["top_b", "bot_b", "bra_a", "shorts_a", "panst_b", "shoes_in"], SIMD2(0, 1)),
        ([0, 0, 1, 1, 0, 0, 0, 0, 0], 1, ["top_a", "bot_a", "bra_b", "shorts_b", "panst_a", "shoes_out"], SIMD2(1, 1)),
        ([0, 0, 0, 2, 0, 2, 0, 0, 0], 1, ["top_a", "bot_a", "bra_a", "shorts_c", "shoes_out"], SIMD2(1, 1)),
        ([2, 2, 2, 0, 0, 3, 0, 0, 0], 1, ["shorts_a", "shoes_out"], SIMD2(0, 1)),
        ([3, 3, 3, 3, 0, 3, 0, 3, 3], 0, [], SIMD2(0, 0)),
        ([0, 0, 0, 0, 0, 0, 0, 3, 0], 0, ["top_a", "bot_a", "bra_a", "shorts_a", "panst_a"], SIMD2(1, 1)),
        ([0, 0, 0, 0, 0, 0, 0, 0, 3], 1, ["top_a", "bot_a", "bra_a", "shorts_a", "panst_a"], SIMD2(1, 1)),
    ]
    for (states, shoesType, expected, alpha) in table {
        let (names, bodyAlpha, fallbacks) = drawn(states, shoesType)
        #expect(names == expected, Comment(rawValue: "\(states) shoesType \(shoesType)"))
        #expect(bodyAlpha == alpha && fallbacks == 0, Comment(rawValue: "\(states)"))
    }
    // Indoor shoes resolved to the catalog's empty row: shoesType 0 draws no
    // shoe and reports nothing; unconverted ones keep the outdoor stand-in.
    let (dressed, _) = try halfStateRig()
    let withoutIndoor = SourceRig(sourcePrefab: "half", rig: dressed.rig,
                                  parts: dressed.parts.filter { $0.mesh.name != "shoes_in" }, morphChannelCount: 0)
    for (indoor, standIn) in [(SourceMakerLibrary.IndoorShoes.empty, false), (.unconverted, true)] {
        let partial = SourceStudioWearLayout(source: withoutIndoor, clothingSlots: slots, indoorShoes: indoor)
        #expect(partial.outdoorShoesStandIn == standIn && partial.clothingKinds == [0, 1, 2, 3, 5, 8])
        let result = partial.evaluate(rules: wear, states: on, shoesType: 0, showAccessory: shown, hideHairSlots: [])
        let shoes = withoutIndoor.parts.firstIndex { $0.mesh.name == "shoes_out" }!
        #expect(result.hiddenParts.contains(shoes) != standIn)
        #expect(result.fallbacks.count == (standIn ? 1 : 0))
        #expect(!standIn || result.fallbacks[0].contains("outdoor shoe geometry stands in"))
    }
}

@Test func sourceStudioWearAlternatesWithoutMeshesStillReportTheFallback() throws {
    // The same garment assembled from a library without its half-state
    // meshes (no alternates): n_top_b exists but carries no renderer.
    let (source, slots) = try halfStateRig()
    let dressedOnly = SourceRig(sourcePrefab: "half", rig: source.rig,
                                parts: source.parts.filter { !$0.mesh.name.hasSuffix("_b") && !$0.mesh.name.hasSuffix("_c") }, morphChannelCount: 0)
    let layout = SourceStudioWearLayout(source: dressedOnly, clothingSlots: slots, indoorShoes: .assembled)
    let result = layout.evaluate(rules: rules([3: row(2)]), states: [1, 0, 0, 0, 0, 1, 0, 0, 0], shoesType: 1,
                                 showAccessory: [Bool](repeating: true, count: 20), hideHairSlots: [])
    #expect(result.fallbacks.count == 2 && result.bodyAlpha == SIMD2(1, 1))
    #expect(result.fallbacks.contains { $0.contains("under n_top_b") } && result.fallbacks.contains { $0.contains("under n_panst_b") })
}

/// The converted library (`IKKOKU_MAKER_LIBRARY`) against the native rules:
/// every half-state tag the converter wrote agrees with `switchActive`, and a
/// Studio wear assembly of the half-state outfit draws exactly the Maker
/// assembly's (dressed) parts, with identical geometry, when every garment
/// is on with the outdoor shoes — the dressed identity — while its half
/// states draw the converted alternate meshes with no fallback.
@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_LIBRARY", "IKKOKU_MAKER_SELECTION_FIXTURES"]),
               "Requires IKKOKU_MAKER_LIBRARY and IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceStudioWearLibraryAlternatesMatchUpdateVisibleAndKeepTheDressedParts() throws {
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_LIBRARY")))
    var tagged = 0
    for entry in library.entries {
        for alternate in entry.alternates ?? [] {
            let kind = try #require([105: 0, 106: 1, 107: 2, 108: 3, 110: 5][entry.category])
            let kinds = Array(Set(alternate.activeWhen.map(\.kind) + [kind])).sorted()
            for combination in 0..<(1 << (2 * kinds.count)) {
                var s = [UInt8](repeating: 0, count: 9)
                for (i, k) in kinds.enumerated() { s[k] = UInt8((combination >> (2 * i)) & 3) }
                let native = alternate.switches.allSatisfy { SourceStudioWear.switchActive(kind: kind, node: $0, states: s) == true }
                let converted = alternate.activeWhen.allSatisfy { $0.states.contains(Int(s[$0.kind])) }
                #expect(native == converted, Comment(rawValue: "\(entry.category)-\(entry.id) \(alternate.meshName) \(s)"))
            }
            tagged += 1
        }
    }
    #expect(tagged >= 5, "IKKOKU_MAKER_LIBRARY must be a library converted with half-state alternates")

    struct Fixtures: Decodable { let femaleBase: String }
    let fixtureURL = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_SELECTION_FIXTURES"))
    let base = URL(fileURLWithPath: try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixtureURL)).femaleBase)
    var card = try SourceCharacterCard.load(url: fixtureURL.deletingLastPathComponent().appendingPathComponent("female-head0-bone0.png"))
    // T-shirt, bloomers, pantyhose and sneakers outdoor; the fixture's
    // loafers stay indoor (Maker selection refuses slot 7). The library has
    // no bra or shorts (see HALF_STATE_SELECTION).
    for (slot, id) in [(0, 38), (1, 1), (5, 1), (8, 3)] {
        card = try SourceCharacterCard.decode(card.selectingVanillaAsset(id, at: .clothes(coordinate: 0, slot: slot)))
    }
    let maker = try library.prepare(card: card, coordinate: 0, baseURL: base)
    let studio = try library.prepare(card: card, coordinate: 0, baseURL: base, wear: true)
    #expect(maker.clothingSlots == [0, 1, 5, 8] && maker.indoorShoes == .unconverted)
    #expect(studio.clothingSlots == [0, 1, 5, 7, 8] && studio.indoorShoes == .assembled)
    let layout = SourceStudioWearLayout(source: studio.source, clothingSlots: studio.clothingSlots, indoorShoes: studio.indoorShoes)
    let catalog = try library.wearCatalog(card: card, coordinate: 0)
    let rules = SourceStudioWear(catalog: catalog.clothes, switchNodes: (0..<9).map { layout.switchNodes[$0] ?? [] },
                                 ids: catalog.clothesIDs, modded: catalog.clothesModded)
    let shown = [Bool](repeating: true, count: 20)
    func drawn(_ s: [UInt8], _ shoesType: Int) -> (parts: [SourceRig.Part], fallbacks: [String], alpha: SIMD2<Float>) {
        let result = layout.evaluate(rules: rules, states: s, shoesType: shoesType, showAccessory: shown, hideHairSlots: [])
        return (studio.source.parts.indices.filter { !result.hiddenParts.contains($0) }.map { studio.source.parts[$0] }, result.fallbacks, result.bodyAlpha)
    }
    let dressed = drawn(on, 1)
    #expect(dressed.fallbacks.isEmpty && dressed.alpha == SIMD2(1, 1))
    #expect(dressed.parts.map(\.mesh.name) == maker.source.parts.map(\.mesh.name))
    for (left, right) in zip(dressed.parts, maker.source.parts) {
        let x = left.mesh, y = right.mesh
        #expect(x.positions == y.positions && x.normals == y.normals && x.uvs == y.uvs && x.indices == y.indices
                && x.joints == y.joints && x.weights == y.weights, Comment(rawValue: x.name))
        #expect(studio.source.rig.nodes[left.node].name == maker.source.rig.nodes[right.node].name)
    }
    // Top, bottom and pantyhose half with the indoor shoes.
    let half = drawn([1, 1, 0, 0, 0, 1, 0, 0, 0], 0)
    let names = Set(half.parts.map(\.mesh.name).filter { $0.hasPrefix("clothes-") })
    #expect(names == ["clothes-0/o_top_tsyats_b/0", "clothes-1/o_bot_pants01_b/0", "clothes-5/o_panst_00_b/0",
                      "clothes-7/o_shoes_roafer01/0"])
    #expect(half.fallbacks.isEmpty && half.alpha == SIMD2(0, 1))
}
