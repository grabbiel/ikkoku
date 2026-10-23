import Foundation
import Scene
import Character

/// The recovered ChaControl clothes-state rules for one loaded outfit
/// (ST-C03). `ChaFileStatus.clothesState` holds one byte per
/// ChaFileDefine.ClothesKind — 0 top, 1 bot, 2 bra, 3 shorts, 4 gloves,
/// 5 panst, 6 socks, 7 shoes_inner, 8 shoes_outer — each 0 on (着衣),
/// 1 half (半脱 / 半脱１), 2 half 2 (半脱２) or 3 off (脱衣).
///
/// * `allowed` is ChaControl.dictStateType, built by AddClothesStateKind from
///   the loaded garments' catalog StateType (0 -> {0, 1, 3}, 1 -> {0, 3},
///   2 -> {0, 1, 2, 3}, anything else -> not a state kind), with the linked
///   top/bottom and bra/shorts widening that reads the other garment's
///   StateType and the prefab's n_bot_a / n_top_a switch nodes.
/// * `setting` is ChaControl.SetClothesState(kind, state, next: true): a
///   state the kind does not allow advances to the next allowed one, then the
///   one-piece (notBot), no-shorts (notShorts) and inner/outer shoe links run.
/// * `loaded` is the scene load: Reload's UpdateClothesStateAll followed by
///   AddObjectAssist.UpdateState's SetClothesState loop over the saved bytes.
/// * `visible` and `switchActive` are ChaControl.UpdateVisible: which garment
///   GameObjects and which ChaReference switch nodes (n_top_a ... n_panst_b)
///   are active for a state.
///
/// A kind whose catalog row was not converted has unknown rules: every state
/// is allowed (the saved byte is kept, never re-guessed), its one-piece flags
/// read false, and `unknownKinds` lists it for the preview's diagnostics.
public struct SourceStudioWear: Equatable, Sendable {
    public static let kindNames = ["top", "bottom", "bra", "shorts", "gloves", "pantyhose", "socks", "indoor shoes", "outdoor shoes"]
    public static let stateNames = ["on", "half", "half 2", "off"]
    /// CharaStudio's clothing-detail rows (MPCharCtrl.ClothingDetailsInfo):
    /// top, bottom, bra, shorts, gloves, pantyhose, socks, shoes. The shoes
    /// row addresses kind 7; SetClothesState mirrors it to kind 8.
    public static let studioKinds = Array(0..<8)
    /// ChaReference names the UpdateVisible switch nodes are looked up by.
    public static let switchNames: Set<String> = ["n_top_a", "n_top_b", "n_bot_a", "n_bot_b", "n_bot_c", "n_panst_a", "n_panst_b"]
    /// Switch nodes whose meshes are the alternate (half/undressed) shapes;
    /// the Maker conversion keeps only the dressed meshes, so these are
    /// assembled without renderers.
    public static let alternateSwitches: [Int: Set<String>] = [
        0: ["n_top_b", "n_bot_b", "n_bot_c"], 1: ["n_top_b", "n_bot_b", "n_bot_c"],
        2: ["n_top_b", "n_bot_b", "n_bot_c"], 3: ["n_top_b", "n_bot_b", "n_bot_c"], 5: ["n_panst_b"],
    ]
    /// Bottom IDs whose rows lack a HideShorts column but still hide the
    /// shorts (ChaControl.ChangeClothesBotAsync's fallback list).
    public static let hideShortsBottomIDs: Set<Int> = [2, 3, 9, 16, 22, 25, 28, 29, 30, 32, 34, 35, 45]

    /// dictStateType per kind; nil when the kind is not a state kind (no
    /// garment, or a StateType outside 0...2).
    public let allowed: [Set<UInt8>?]
    public let notBot: Bool, notBra: Bool, notShorts: Bool, hideShortsBot: Bool
    /// Kinds whose rules could not be recovered from a converted row.
    public let unknownKinds: [Int]

    /// `catalog`: the nine kinds' rows; `switchNodes`: the switch-node names
    /// each kind's loaded prefab carries (empty when unknown or absent);
    /// `ids` / `modded`: the saved bottom identity for the HideShorts fallback.
    public init(catalog: [SourceMakerLibrary.CatalogRow], switchNodes: [Set<String>], ids: [Int], modded: [Bool]) {
        precondition(catalog.count == 9 && switchNodes.count == 9 && ids.count == 9 && modded.count == 9)
        func info(_ kind: Int, _ key: String) -> String? {
            switch catalog[kind] {
            case .none: return nil
            case .row(let row): return row[key] ?? "0" // ListInfoBase.GetInfo
            case .unknown: return nil
            }
        }
        func known(_ kind: Int) -> Bool { if case .unknown = catalog[kind] { return false }; return true }
        func stateType(_ kind: Int) -> Int? {
            switch catalog[kind] {
            case .none: return 3
            case .row(let row): return UInt8(row["StateType"] ?? "0").map(Int.init)
            case .unknown: return nil
            }
        }
        func sub(_ type: Int?) -> Set<UInt8>? {
            switch type {
            case 0: return [0, 1, 3]
            case 1: return [0, 3]
            case 2: return [0, 1, 2, 3]
            default: return nil
            }
        }
        let all: Set<UInt8> = [0, 1, 2, 3]
        func has(_ kind: Int, _ node: String) -> Bool { switchNodes[kind].contains(node) }
        var allowed = [Set<UInt8>?](repeating: nil, count: 9)
        var unknown = Set<Int>()
        for kind in 4..<9 {
            if let type = stateType(kind) { allowed[kind] = sub(type) } else { allowed[kind] = all; unknown.insert(kind) }
        }
        // ChangeClothesTop: notBra = NotBra == 1, notBot = Coordinate == 2.
        notBot = info(0, "Coordinate").flatMap { Int($0) } == 2
        notBra = info(0, "NotBra").flatMap { Int($0) } == 1
        // ChangeClothesBra: notShorts = Coordinate == "2".
        notShorts = info(2, "Coordinate") == "2"
        if case .row(let row) = catalog[1] {
            if let flag = row["HideShorts"] { hideShortsBot = flag == "1" } else { hideShortsBot = Self.hideShortsBottomIDs.contains(ids[1]) }
        } else if case .unknown = catalog[1], !modded[1] {
            hideShortsBot = Self.hideShortsBottomIDs.contains(ids[1])
        } else { hideShortsBot = false }
        // AddClothesStateKind(top/bot).
        if let top = stateType(0), let bottom = stateType(1) {
            var b3 = top, b4 = bottom
            if b4 != 0, has(0, "n_bot_a") { if b3 == 0 { b4 = 0 } else if b3 == 1, b4 == 2 { b4 = 1 } }
            if b3 != 0, has(1, "n_top_a") { if b4 == 0 { b3 = 0 } else if b4 == 1, b3 == 2 { b3 = 1 } }
            allowed[0] = sub(b3); allowed[1] = sub(b4)
        } else {
            allowed[0] = all; allowed[1] = all; unknown.formUnion([0, 1])
        }
        // AddClothesStateKind(bra/shorts): notBra comes from the top's row,
        // notShorts from the bra's, so all three rows must be known.
        if known(0), known(2), known(3) {
            var b = 3, b2 = 3
            if !notBra { b = stateType(2) ?? 3 }
            if !notBra || !notShorts { b2 = stateType(3) ?? 3 }
            if b2 != 0, b2 != 2, has(2, "n_bot_a") { if b == 0 { b2 = 0 } else if b == 1, b2 == 3 { b2 = 1 } }
            if b != 0, b != 2, has(3, "n_top_a") { if b2 == 0 { b = 0 } else if b2 == 1, b == 3 { b = 1 } }
            allowed[2] = sub(b); allowed[3] = sub(b2)
        } else {
            allowed[2] = all; allowed[3] = all; unknown.formUnion([2, 3])
        }
        self.allowed = allowed
        unknownKinds = unknown.sorted()
    }

    /// ChaControl.SetClothesState(kind, state, next: true).
    public func setting(_ current: [UInt8], kind: Int, state requested: UInt8) -> [UInt8] {
        precondition(current.count == 9 && (0..<9).contains(kind))
        var s = current, state = requested
        let saved = s[kind]
        repeat {
            guard let states = allowed[kind] else { s[kind] = state; break }
            if states.contains(state) { s[kind] = state; break }
            state = (state &+ 1) % 4
        } while saved != state
        switch kind {
        case 0 where notBot: if s[0] == 3 { s[1] = 3 } else if s[1] == 3 { s[1] = state }
        case 1 where notBot: if s[1] == 3 { s[0] = 3 } else if s[0] == 3 { s[0] = state }
        case 2 where notShorts: if s[2] == 3 { s[3] = 3 } else if s[3] == 3 { s[3] = state }
        case 3 where notShorts: if s[3] == 3 { s[2] = 3 } else if s[2] == 3 { s[2] = state }
        case 7: if state == 0 { if allowed[8] != nil { s[8] = 0 } } else { s[8] = state }
        case 8: if state == 0 { if allowed[7] != nil { s[7] = 0 } } else { s[7] = state }
        default: break
        }
        return s
    }

    /// ChaControl.SetClothesStateAll (MPCharCtrl's whole-outfit buttons).
    public func settingAll(_ current: [UInt8], state: UInt8) -> [UInt8] {
        (0..<9).reduce(current) { setting($0, kind: $1, state: state) }
    }

    /// ChaControl.UpdateClothesStateAll: SetClothesState(i, state[i]) in order.
    public func normalized(_ current: [UInt8]) -> [UInt8] {
        (0..<9).reduce(current) { setting($0, kind: $1, state: $0[$1]) }
    }

    /// The state a scene load leaves: the Reload replay, then
    /// AddObjectAssist.UpdateState's SetClothesState loop over the result.
    public func loaded(_ saved: [UInt8]) -> [UInt8] { normalized(normalized(saved)) }

    /// UpdateVisible's activity of the garment GameObject objClothes[kind]
    /// (visibleAll / visibleBodyAlways / visibleSimple at their defaults).
    public func visible(kind: Int, states s: [UInt8], shoesType: Int) -> Bool {
        switch kind {
        case 0: return s[0] != 3
        case 1: return !notBot && s[1] != 3
        case 2: return !notBra && s[2] != 3
        case 3: return !(hideShortsBot && visible(kind: 1, states: s, shoesType: shoesType) && s[1] == 0) && !notShorts && s[3] != 3
        case 4: return s[4] == 0
        case 5: return s[5] != 3 && s[5] != 2
        case 6: return s[6] == 0
        case 7: return shoesType == 0 && s[7] == 0
        case 8: return shoesType == 1 && s[8] == 0
        default: return false
        }
    }

    /// UpdateVisible's activity of one ChaReference switch node of a kind's
    /// prefab; nil for a node UpdateVisible does not switch (it keeps the
    /// prefab's authored activity).
    public static func switchActive(kind: Int, node: String, states s: [UInt8]) -> Bool? {
        switch (kind, node) {
        case (0, "n_top_a"): return s[0] == 0
        case (0, "n_top_b"): return s[0] == 1
        case (0, "n_bot_a"): return s[1] == 0 && s[0] != 3
        case (0, "n_bot_b"): return s[1] != 0 && s[0] != 3
        case (1, "n_bot_a"): return s[1] == 0
        case (1, "n_bot_b"): return s[1] == 1
        case (1, "n_top_a"): return s[0] == 0 && s[1] != 2
        case (1, "n_top_b"): return s[0] != 0 && s[1] != 2
        case (2, "n_top_a"): return s[2] == 0
        case (2, "n_top_b"): return s[2] == 1
        case (2, "n_bot_a"): return s[3] == 0 && s[2] != 3
        case (2, "n_bot_b"): return s[3] != 0 && s[2] != 3
        case (3, "n_bot_a"): return s[3] == 0
        case (3, "n_bot_b"): return s[3] == 1
        case (3, "n_bot_c"): return s[3] == 2
        case (5, "n_panst_a"): return s[5] == 0
        case (5, "n_panst_b"): return s[5] == 1
        default: return nil
        }
    }

    /// ChaControl.ChangeAlphaMask's (_alpha_a, _alpha_b) for the top's state.
    public static func bodyAlpha(topState: UInt8) -> SIMD2<Float> {
        switch topState {
        case 0: return SIMD2(1, 1)
        case 1, 2: return SIMD2(0, 1)
        default: return SIMD2(0, 0)
        }
    }
}

/// Which assembled renderers belong to which clothing kind, accessory slot or
/// hair, and the ChaReference switch nodes above each clothing renderer
/// (ST-C03). Built once per assembly; `evaluate` turns a clothes state into
/// the renderers UpdateVisible switches off.
public struct SourceStudioWearLayout: Equatable, Sendable {
    public enum Owner: Equatable, Sendable {
        /// `switches`: the switch-node names among the renderer's ancestors
        /// inside its garment (Unity renders it only while all are active).
        case clothing(kind: Int, switches: Set<String>)
        case accessory(slot: Int)
        case hair
        case other
    }
    public let parts: [Owner]
    /// Switch-node names each assembled clothing kind's prefab carries.
    public let switchNodes: [Int: Set<String>]

    public init(parts: [Owner], switchNodes: [Int: Set<String>]) {
        self.parts = parts; self.switchNodes = switchNodes
    }

    /// Reads the component prefixes SourceAvatar.assemble gives every node
    /// ("clothes-<index>/", "accessory-<slot>/", "hair-<index>/");
    /// `clothingSlots[index]` is the ClothesKind of clothing component index.
    public init(source: SourceRig, clothingSlots: [Int]) {
        let nodes = source.rig.nodes
        func component(_ node: Int) -> (kind: String, index: Int)? {
            let id = nodes[node].sourceID
            guard let slash = id.firstIndex(of: "/"), let dash = id[..<slash].lastIndex(of: "-"),
                  let index = Int(id[id.index(after: dash)..<slash]) else { return nil }
            return (String(id[..<dash]), index)
        }
        var switchNodes: [Int: Set<String>] = [:]
        var owners: [Int: (String, Int)] = [:]
        for node in nodes.indices {
            guard let owner = component(node) else { continue }
            owners[node] = owner
            if owner.kind == "clothes", clothingSlots.indices.contains(owner.index), (0..<9).contains(clothingSlots[owner.index]),
               SourceStudioWear.switchNames.contains(nodes[node].name) {
                switchNodes[clothingSlots[owner.index], default: []].insert(nodes[node].name)
            }
        }
        parts = source.parts.map { part in
            guard let owner = owners[part.node] else { return .other }
            switch owner.0 {
            case "clothes":
                guard clothingSlots.indices.contains(owner.1), (0..<9).contains(clothingSlots[owner.1]) else { return .other }
                var switches = Set<String>(), cursor: Int? = part.node
                while let node = cursor, let current = owners[node], current == owner {
                    if SourceStudioWear.switchNames.contains(nodes[node].name) { switches.insert(nodes[node].name) }
                    cursor = nodes[node].parent
                }
                return .clothing(kind: clothingSlots[owner.1], switches: switches)
            case "accessory": return .accessory(slot: owner.1)
            case "hair": return .hair
            default: return .other
            }
        }
        self.switchNodes = switchNodes
    }

    public var clothingKinds: [Int] {
        Array(Set(parts.compactMap { if case .clothing(let kind, _) = $0 { return kind }; return nil })).sorted()
    }
    public var accessorySlots: [Int] {
        Array(Set(parts.compactMap { if case .accessory(let slot) = $0 { return slot }; return nil })).sorted()
    }

    public struct Evaluation: Equatable, Sendable {
        public var hiddenParts: Set<Int> = []
        /// ChangeAlphaMask's pair for the body coverage mask.
        public var bodyAlpha = SIMD2<Float>(1, 1)
        /// Kinds / slots with at least one assembled renderer still drawn.
        public var renderedClothing: [Int] = [], renderedAccessories: [Int] = []
        public var hairHidden = false
        /// One line per garment whose state cannot be drawn natively.
        public var fallbacks: [String] = []
    }

    /// UpdateVisible over the assembled renderers. A visible garment whose
    /// state activates an alternate switch node (n_top_b, n_bot_b, n_bot_c,
    /// n_panst_b) that carries no assembled renderer — the conversion keeps
    /// only the dressed meshes — or whose half state belongs to an
    /// unconverted (reference) garment renders its dressed meshes instead,
    /// and the fallback is reported; it is never drawn silently wrong. The
    /// outdoor-shoe geometry (the only shoe the assembly converts) follows
    /// shoes_outer for shoesType 1 and stands in for the indoor shoes, under
    /// shoes_inner, for shoesType 0. `hideHairSlots`: accessory slots whose
    /// catalog HideHair is set (ChaControl.CheckHideHair).
    public func evaluate(rules: SourceStudioWear, states s: [UInt8], shoesType: Int, showAccessory: [Bool],
                         hideHairSlots: Set<Int>) -> Evaluation {
        precondition(s.count == 9 && showAccessory.count == 20)
        var result = Evaluation()
        let dressed = [UInt8](repeating: 0, count: 9)
        var effective: [Int: [UInt8]] = [:], garmentVisible: [Int: Bool] = [:]
        for kind in clothingKinds {
            let visible: Bool
            if kind == 8 { visible = shoesType == 1 ? s[8] == 0 : shoesType == 0 ? s[7] == 0 : false }
            else { visible = rules.visible(kind: kind, states: s, shoesType: shoesType) }
            garmentVisible[kind] = visible
            guard visible else { continue }
            let nodes = switchNodes[kind] ?? []
            let used = Set(parts.flatMap { owner -> Set<String> in
                if case .clothing(kind, let switches) = owner { return switches }; return []
            })
            let missing = nodes.filter { node in
                SourceStudioWear.alternateSwitches[kind]?.contains(node) == true
                    && SourceStudioWear.switchActive(kind: kind, node: node, states: s) == true && !used.contains(node)
            }.sorted()
            let name = SourceStudioWear.kindNames[kind], state = SourceStudioWear.stateNames[Int(s[kind])]
            if !missing.isEmpty {
                effective[kind] = dressed
                result.fallbacks.append("\(name) is \(state) with \(stateSummary(s, around: kind)): its alternate meshes under \(missing.joined(separator: ", ")) are not converted, so the dressed meshes render instead.")
            } else if rules.unknownKinds.contains(kind), [1, 2].contains(s[kind]), [0, 1, 2, 3, 5].contains(kind) {
                effective[kind] = dressed
                result.fallbacks.append("\(name) is \(state), but its catalog row is not converted (reference geometry), so the half state cannot be rendered and the dressed meshes render instead.")
            } else { effective[kind] = s }
        }
        // A top drawn dressed in place of its half state keeps the dressed
        // body cut-out, so no body shows through the substituted mesh.
        result.bodyAlpha = SourceStudioWear.bodyAlpha(topState: effective[0] == dressed ? 0 : s[0])
        result.hairHidden = hideHairSlots.contains { showAccessory.indices.contains($0) && showAccessory[$0] }
        var clothing = Set<Int>(), accessories = Set<Int>()
        for (index, owner) in parts.enumerated() {
            switch owner {
            case .clothing(let kind, let switches):
                guard garmentVisible[kind] == true, let states = effective[kind],
                      switches.allSatisfy({ SourceStudioWear.switchActive(kind: kind, node: $0, states: states) != false }) else {
                    result.hiddenParts.insert(index); continue
                }
                clothing.insert(kind)
            case .accessory(let slot):
                guard showAccessory.indices.contains(slot), showAccessory[slot] else { result.hiddenParts.insert(index); continue }
                accessories.insert(slot)
            case .hair:
                if result.hairHidden { result.hiddenParts.insert(index) }
            case .other: break
            }
        }
        result.renderedClothing = clothing.sorted(); result.renderedAccessories = accessories.sorted()
        return result
    }

    private func stateSummary(_ s: [UInt8], around kind: Int) -> String {
        let related: [Int] = kind <= 1 ? [0, 1] : kind <= 3 ? [2, 3] : [kind]
        return related.map { "\(SourceStudioWear.kindNames[$0]) \(SourceStudioWear.stateNames[Int(s[$0])])" }.joined(separator: ", ")
    }
}
