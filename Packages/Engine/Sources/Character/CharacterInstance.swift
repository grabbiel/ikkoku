import Foundation
import simd
import CoreMath
import Assets
import Scene
import Renderer
import ShaderTypes

/// A character placed in a scene: resolves the card into GPU assets and produces render items.
public final class CharacterInstance: Identifiable {
    public let instanceID: UInt64
    public var id: UInt64 { instanceID }
    public let library: AssetLibrary

    public var card: CharacterCard { didSet { if Self.assetsChanged(oldValue, card) { resolve() } } }
    public var transform = matrix_identity_float4x4
    public var poseDelta = PoseDelta()
    public var ikTargets: [IKChain: IKTarget] = [:]
    /// World-space point the eyes look at (nil = straight ahead). Set by the maker/studio from the gaze mode.
    public var gazeTarget: Float3? = nil
    public var visible = true
    public var clothingVisible = true
    public var accessoriesVisible = true
    /// Extra morph weights (studio expression sliders) merged on top of the card's expression.
    public var extraMorphs: [String: Float] = [:]

    public private(set) var body: LoadedAsset?
    public private(set) var skeleton: Skeleton?
    /// Hair chain bones appended to the body skeleton, root→tip per chain.
    public private(set) var hairChains: [[Int]] = []
    public let hairDynamics = HairDynamics()
    public var hairDynamicsEnabled = true
    private var hairParts: [(slot: HairSlot, asset: LoadedAsset)] = []
    private var clothParts: [(slot: ClothSlot, asset: LoadedAsset, entry: Catalog.Cloth)] = []
    private var accessoryParts: [(index: Int, asset: LoadedAsset, entry: Catalog.Accessory)] = []
    private var eyeIndexL: Int?
    private var eyeIndexR: Int?

    public init(instanceID: UInt64, library: AssetLibrary, card: CharacterCard) {
        self.instanceID = instanceID
        self.library = library
        self.card = card
        resolve()
    }

    private static func assetsChanged(_ a: CharacterCard, _ b: CharacterCard) -> Bool {
        a.body.bodyID != b.body.bodyID || a.hair.parts != b.hair.parts || a.currentOutfit != b.currentOutfit
            || a.outfit.items.mapValues(\.itemID) != b.outfit.items.mapValues(\.itemID)
            || a.accessories.map(\.itemID) != b.accessories.map(\.itemID)
    }

    /// (Re)loads every asset the card references.
    public func resolve() {
        let cat = library.catalog
        let bodyEntry = cat.body(card.body.bodyID) ?? cat.bodies.first
        body = bodyEntry.flatMap { library.asset($0.file) }
        var skel = body?.skeleton
        // Hair chain bones: append each worn style's extra bones (prefixed by slot) so hair can swing.
        hairParts = []
        hairChains = []
        var pending: [(HairSlot, Catalog.Hair)] = []
        for slot in HairSlot.allCases {
            guard let sid = card.hair.parts[slot]?.styleID, let entry = cat.hair(sid) else { continue }
            pending.append((slot, entry))
        }
        if let base = skel {
            var extras: [Skeleton.Bone] = []
            for (slot, entry) in pending {
                guard let plain = library.asset(entry.file), let hs = plain.skeleton else { continue }
                var indexMap: [Int: Int] = [:]      // hair skeleton index → extended index
                var chain: [Int] = []
                for hi in hs.order {
                    let b = hs.bones[hi]
                    if base[b.name] != nil { continue }
                    let parentIndex: Int?
                    if let hp = b.parent {
                        if let mapped = indexMap[hp] { parentIndex = mapped } else { parentIndex = base[hs.bones[hp].name] ?? base["head"] }
                    } else { parentIndex = base["head"] }
                    var nb = b
                    nb.name = "\(slot.rawValue)/\(b.name)"
                    nb.parent = parentIndex
                    nb.children = []
                    let newIndex = base.count + extras.count
                    indexMap[hi] = newIndex
                    extras.append(nb)
                    chain.append(newIndex)
                    if extras.count >= 48 { break }
                }
                if !chain.isEmpty { hairChains.append(chain) }
            }
            if !extras.isEmpty { skel = base.extended(with: extras) }
        }
        skeleton = skel
        hairDynamics.reset()
        eyeIndexL = skeleton?["eye_L"]; eyeIndexR = skeleton?["eye_R"]
        for (slot, entry) in pending {
            let key = "\(card.body.bodyID)/\(slot.rawValue)/\(pending.map { $0.1.id }.joined(separator: ","))"
            guard let a = library.asset(entry.file, skeleton: skeleton, skeletonKey: key, namePrefix: slot.rawValue) else { continue }
            hairParts.append((slot, a))
        }
        clothParts = []
        for slot in ClothSlot.allCases {
            guard let item = card.outfit.items[slot], let iid = item.itemID, let entry = cat.cloth(iid), let a = library.asset(entry.file, skeleton: skeleton, skeletonKey: card.body.bodyID) else { continue }
            clothParts.append((slot, a, entry))
        }
        accessoryParts = []
        for (i, acc) in card.accessories.enumerated() {
            guard let iid = acc.itemID, let entry = cat.accessory(iid), let a = library.asset(entry.file) else { continue }
            accessoryParts.append((i, a, entry))
        }
    }

    // MARK: - Pose

    /// Rest pose + slider bone effects + studio FK deltas.
    public func currentPose() -> Pose {
        guard let skel = skeleton else { return Pose(rotations: [], translations: [], scales: [], skinScales: []) }
        var delta = sliderPoseDelta(skeleton: skel)
        delta.merge(poseDelta)
        let pose = delta.apply(to: skel)
        var p = applyGaze(to: applyIK(to: pose, targets: ikTargets))
        if hairDynamicsEnabled {
            for (bi, q) in hairDynamics.rotations where bi < p.count { p.rotations[bi] = (p.rotations[bi] * q).normalized }
        }
        return p
    }

    /// Advance hair springs by `dt` seconds (call from a timer; cheap).
    public func stepHairDynamics(dt: Float) {
        guard hairDynamicsEnabled, !hairChains.isEmpty, let skel = skeleton else { return }
        let wasEnabled = hairDynamicsEnabled
        hairDynamicsEnabled = false                     // world matrices without the dynamic offsets
        let world = currentPose().worldMatrices(skeleton: skel)
        hairDynamicsEnabled = wasEnabled
        hairDynamics.step(dt: dt, chains: hairChains, skeleton: skel, world: world, rootMatrix: rootMatrix, headIndex: skel["head"])
    }

    /// Rotates the eye bones toward `gazeTarget` (clamped so the irises stay inside the lids).
    private func applyGaze(to pose: Pose) -> Pose {
        guard var target = gazeTarget, let skel = skeleton else { return pose }
        var p = pose
        let rootInv = rootMatrix.inverse
        // Limit convergence: a camera right in front of the face would cross the eyes.
        if let hi = skel["head"] {
            let headPos = (rootMatrix * p.worldMatrices(skeleton: skel)[hi]).translation
            let d = target - headPos
            let minDist: Float = 1.6
            if length(d) < minDist, length_squared(d) > 1e-6 { target = headPos + normalize(d) * minDist }
        }
        let localTarget = rootInv.transformPoint(target)
        if card.expression.headLook == true, let hi = skel["head"] {
            // Turn the head (and a little of the neck) toward the target, clamped.
            let w0 = p.worldMatrices(skeleton: skel)
            let m = w0[hi]
            let d = m.inverse.transformPoint(localTarget)
            if length_squared(d) > 1e-6 {
                let dn = normalize(d)
                var yaw = atan2(dn.x, max(dn.z, 0.05)), pitch = atan2(-dn.y, max(dn.z, 0.05))
                yaw = clamp(yaw, -0.6, 0.6); pitch = clamp(pitch, -0.35, 0.35)
                let qh = simd_quatf(angle: yaw * 0.7, axis: Float3(0, 1, 0)) * simd_quatf(angle: pitch * 0.7, axis: Float3(1, 0, 0))
                p.rotations[hi] = (p.rotations[hi] * qh).normalized
                if let ni = skel["neck"] {
                    let qn = simd_quatf(angle: yaw * 0.3, axis: Float3(0, 1, 0)) * simd_quatf(angle: pitch * 0.3, axis: Float3(1, 0, 0))
                    p.rotations[ni] = (p.rotations[ni] * qn).normalized
                }
            }
        }
        let world = p.worldMatrices(skeleton: skel)
        for name in ["eye_L", "eye_R"] {
            guard let ei = skel[name], ei < world.count else { continue }
            let m = world[ei]
            let dir = m.inverse.transformPoint(localTarget)
            guard length_squared(dir) > 1e-6 else { continue }
            // Eyes look along their local +Z (the mesh faces +Z); yaw about Y, pitch about X.
            let d = normalize(dir)
            var yaw = atan2(d.x, max(d.z, 0.05))
            var pitch = atan2(-d.y, max(d.z, 0.05))
            let limit: Float = 0.42   // ~24°
            yaw = clamp(yaw, -limit, limit); pitch = clamp(pitch, -limit * 0.7, limit * 0.7)
            let q = simd_quatf(angle: yaw, axis: Float3(0, 1, 0)) * simd_quatf(angle: pitch, axis: Float3(1, 0, 0))
            p.rotations[ei] = (p.rotations[ei] * q).normalized
        }
        return p
    }

    public var modelScale: Float {
        var s: Float = 1
        for def in SliderRegistry.shared.sliders {
            if case .modelScale(let amount) = def.kind { s *= 1 + card.slider(def.id) / 100 * amount }
        }
        return s
    }

    /// World matrix of the character root (transform × height scale).
    public var rootMatrix: float4x4 { transform * Transform.scale(modelScale) }

    /// Rest-pose landmark heights (root space, before `transform`), for camera framing.
    public var eyeHeight: Float {
        guard let skel = skeleton, let i = skel["eye_L"] ?? skel["head"] else { return 1.5 * modelScale }
        return skel.restWorldMatrices()[i].translation.y * modelScale + (skel["eye_L"] == nil ? 0.08 : 0)
    }
    public var height: Float {
        guard let skel = skeleton, let i = skel["head_top"] ?? skel["head"] else { return 1.65 * modelScale }
        return (skel.restWorldMatrices()[i].translation.y + (skel["head_top"] == nil ? 0.12 : 0.02)) * modelScale
    }

    public func worldMatrices() -> [float4x4]? {
        guard let skel = skeleton else { return nil }
        return currentPose().worldMatrices(skeleton: skel)
    }

    private func sliderPoseDelta(skeleton: Skeleton) -> PoseDelta {
        var d = PoseDelta()
        func apply(_ kind: SliderKind, _ v: Float) {
            switch kind {
            case .morph, .modelScale: break
            case .skinScale(let bones, let axes, let amount):
                for b in bones { d.skinScales[b, default: Float3(repeating: 1)] *= Float3(repeating: 1) + axes * (v * amount) }
            case .scale(let bones, let axes, let amount):
                for b in bones { d.scales[b, default: Float3(repeating: 1)] *= Float3(repeating: 1) + axes * (v * amount) }
            case .offset(let bones, let amount, let mirror):
                for b in bones {
                    var a = amount * v
                    if mirror && b.hasSuffix("_R") { a.x = -a.x }
                    d.translations[b, default: .zero] += a
                }
            case .length(let children, let amount):
                for c in children {
                    guard let ci = skeleton[c], let pi = skeleton.bones[ci].parent else { continue }
                    let rest = skeleton.bones[ci].restTranslation
                    let len = max(length(rest), 1e-4)
                    let dir = rest / len
                    d.translations[c, default: .zero] += dir * (v * amount)
                    // Stretch the parent along the child direction so the mesh fills the gap.
                    let parentName = skeleton.bones[pi].name
                    let stretch = 1 + (v * amount) / len
                    let axis = abs(dir)
                    let s = Float3(repeating: 1) + axis * (stretch - 1)
                    d.skinScales[parentName, default: Float3(repeating: 1)] *= s
                }
            case .combined(let kinds):
                for k in kinds { apply(k, v) }
            }
        }
        for def in SliderRegistry.shared.sliders {
            let v = card.slider(def.id) / 100
            if abs(v) < 1e-4 { continue }
            apply(def.kind, v)
        }
        // Gaze: rotate eye bones toward a target (mode 3) or the camera (mode 1) is handled by the caller via poseDelta.
        return d
    }

    // MARK: - Morphs

    /// Morph weights by target name (sliders + expression).
    public func morphWeights() -> [String: Float] {
        var w: [String: Float] = [:]
        func add(_ kind: SliderKind, _ v: Float) {
            switch kind {
            case .morph(let name): w[name, default: 0] += v
            case .combined(let kinds): for k in kinds { add(k, v) }
            default: break
            }
        }
        for def in SliderRegistry.shared.sliders {
            let v = card.slider(def.id) / 100
            if abs(v) < 1e-4 { continue }
            add(def.kind, v)
        }
        let e = card.expression
        func addPattern(_ list: [(name: String, weights: [String: Float])], _ i: Int, scale: Float = 1) {
            guard i >= 0, i < list.count else { return }
            for (k, v) in list[i].weights { w[k, default: 0] += v * scale }
        }
        addPattern(ExpressionPresets.eyebrowPatterns, e.eyebrows)
        addPattern(ExpressionPresets.eyePatterns, e.eyes)
        addPattern(ExpressionPresets.mouthPatterns, e.mouth)
        let closed = 1 - clamp(e.eyeOpen, 0, 1)
        if closed > 0 { w["exp.blink_L", default: 0] += closed; w["exp.blink_R", default: 0] += closed }
        if e.mouthOpen > 0 { w["exp.mouth_open", default: 0] += e.mouthOpen }
        for (k, v) in extraMorphs { w[k, default: 0] += v }
        return w.mapValues { clamp($0, -1, 1.5) }
    }

    // MARK: - Render items

    public struct BuildResult {
        public var items: [RenderItem]
        public var skinSet: [float4x4]
        public var bounds: AABB
        public var pose: Pose
        public var worldMatrices: [float4x4]
    }

    public func build(objectID: UInt32) -> BuildResult {
        var items: [RenderItem] = []
        var bounds = AABB.empty
        let root = rootMatrix
        let pose = currentPose()
        var world: [float4x4] = []
        var skin: [float4x4] = []
        if let skel = skeleton {
            world = pose.worldMatrices(skeleton: skel)
            skin = pose.skinMatrices(skeleton: skel, world: world)
        }
        guard visible, let body else {
            return BuildResult(items: [], skinSet: skin, bounds: bounds, pose: pose, worldMatrices: world)
        }
        let weights = morphWeights()
        var hidden: UInt32 = 0
        var maskPaths: [String] = []
        var coverageGarments: [(id: String, asset: LoadedAsset)] = []
        if clothingVisible {
            for c in clothParts {
                let state = card.outfit.states[c.slot] ?? .on
                guard state == .on else { continue }
                if CharacterInstance.preferPipelineMasks, let bm = c.entry.bodyMask, library.fileExists(bm) {
                    maskPaths.append(bm)          // per-garment coverage authored by the pipeline
                } else {
                    coverageGarments.append((c.entry.id, c.asset))
                    for r in c.entry.hideBody ?? [] where !["torso_upper"].contains(r) {
                        if let id = library.catalog.regions[r], id < 32 { hidden |= 1 << UInt32(id) }
                    }
                }
            }
        }
        let bodyMask = library.composedBodyMask(maskPaths)
        let hiddenKey = updateCoverage(garments: coverageGarments)
        var partIndex: UInt64 = 0
        func deformKey() -> UInt64 { let k = (instanceID << 16) | partIndex; partIndex += 1; return k }

        // Body + face parts
        let mouthOpen = (weights["exp.mouth_open"] ?? 0) + (weights["exp.mouth_a"] ?? 0) + (weights["exp.mouth_o"] ?? 0)
            + (weights["exp.mouth_e"] ?? 0) * 0.7 + (weights["exp.mouth_i"] ?? 0) * 0.5 + (weights["exp.smile"] ?? 0) * 0.6
        for part in body.parts {
            let isMouthPart = ["teeth", "tongue"].contains(part.meshName.lowercased())
            if isMouthPart && mouthOpen < 0.12 { continue }          // inside a closed mouth: nothing to see
            var mat = MaterialBuilder.material(for: part, asset: body, card: card, library: library)
            let isBody = part.meshName == "body" || mat.kind == MaterialKindSkin
            if isBody, let bodyMask { mat.bodyMask = bodyMask; mat.setFlag(MaterialFlagHasBodyMask, true) }
            var model = part.skinned ? root : root * part.worldMatrix
            if isMouthPart { model = model * Transform.translation(Float3(0, 0, -0.006)) }   // keep them behind the lips
            var item = RenderItem(mesh: part.mesh, material: mat, model: model, objectID: objectID,
                                  deformKey: deformKey(), skinSet: part.skinned ? instanceID : nil,
                                  morphWeights: weights.compactMap { k, v in part.morphIndex(k).map { ($0, v) } })
            if isBody { item.hiddenRegions = hidden; item.hiddenKey = hiddenKey }
            if mat.kind == MaterialKindEyelash { item.order = 50; item.castsShadow = false }
            if isMouthPart { item.castsShadow = false; item.outline = false }
            if mat.kind == MaterialKindEye || mat.kind == MaterialKindEyeWhite { item.order = 10 }
            if part.meshName.hasPrefix("eyebrow") { mat.depthBias = 0.03; item.material = mat; item.order = 60 }
            items.append(item)
            bounds.expand(part.bounds.transformed(by: model))
        }
        // Hair
        for h in hairParts {
            for part in h.asset.parts {
                let mat = MaterialBuilder.hairMaterial(for: part, asset: h.asset, card: card, library: library)
                let model = part.skinned ? root : root * headAttach(world) * part.worldMatrix
                var item = RenderItem(mesh: part.mesh, material: mat, model: model, objectID: objectID,
                                      deformKey: part.skinned ? deformKey() : nil, skinSet: part.skinned ? instanceID : nil)
                item.order = 20
                items.append(item)
            }
        }
        // Clothes
        if clothingVisible {
            let topOn = (card.outfit.states[.top] ?? .on) == .on && clothParts.contains { $0.slot == .top }
            let bottomOn = (card.outfit.states[.bottom] ?? .on) == .on && clothParts.contains { $0.slot == .bottom }
            for c in clothParts {
                let state = card.outfit.states[c.slot] ?? .on
                guard state != .off, let item = card.outfit.items[c.slot] else { continue }
                // Underwear sits at the same surface offset as outerwear; keep it hidden while the outer layer is fully on.
                if c.slot == .bra && topOn { continue }
                if c.slot == .underwear && bottomOn && !(card.outfit.items[.bottom]?.itemID?.contains("skirt") ?? false) { continue }
                for part in c.asset.parts {
                    var mat = MaterialBuilder.clothMaterial(for: part, asset: c.asset, item: item, library: library)
                    if state == .half { mat.uniforms.baseColor.w = 0.5; mat.transparent = true }
                    let model = part.skinned ? root : root * part.worldMatrix
                    var ri = RenderItem(mesh: part.mesh, material: mat, model: model, objectID: objectID,
                                        deformKey: part.skinned ? deformKey() : nil, skinSet: part.skinned ? instanceID : nil)
                    ri.order = 30
                    items.append(ri)
                }
            }
        }
        // Accessories
        if accessoriesVisible {
            for a in accessoryParts {
                let def = card.accessories[a.index]
                guard def.visible else { continue }
                let attach = boneMatrix(named: def.parent, world: world)
                let basePos = (def.useDefaultOffset ?? true) ? a.entry.offsetVector + def.position : def.position
                let local = Transform.trs(basePos, simd_quatf(eulerXYZ: def.rotation.degreesToRadians), def.scale)
                for part in a.asset.parts {
                    let mat = MaterialBuilder.accessoryMaterial(for: part, asset: a.asset, def: def, library: library)
                    let model = root * attach * local * part.worldMatrix
                    var ri = RenderItem(mesh: part.mesh, material: mat, model: model, objectID: objectID)
                    ri.order = 40
                    items.append(ri)
                }
            }
        }
        if bounds.isEmpty { bounds = AABB(min: Float3(-0.5, 0, -0.5), max: Float3(0.5, 1.8, 0.5)).transformed(by: root) }
        return BuildResult(items: items, skinSet: skin, bounds: bounds, pose: pose, worldMatrices: world)
    }

    /// Pipeline `_bm.png` masks are optional; the engine's own per-vertex coverage is the default.
    public nonisolated(unsafe) static var preferPipelineMasks = false
    private var coverageSignature = ""
    private var coverageKey: UInt64? = nil

    /// Recomputes the per-vertex body coverage when the worn garment set changes. Returns the GPU buffer key.
    private func updateCoverage(garments: [(id: String, asset: LoadedAsset)]) -> UInt64? {
        let sig = garments.map(\.id).sorted().joined(separator: "|")
        if sig == coverageSignature { return coverageKey }
        coverageSignature = sig
        guard !garments.isEmpty, let body,
              let bodyMesh = body.asset.meshes.first(where: { $0.name == "body" })?.primitives.first else { coverageKey = nil; return nil }
        var gs: [BodyCoverage.Garment] = []
        for g in garments { for group in g.asset.asset.meshes { for prim in group.primitives { gs.append(BodyCoverage.Garment(mesh: prim)) } } }
        let bytes = BodyCoverage.hiddenVertices(body: bodyMesh, garments: gs)
        let key = (instanceID << 8) | 0x77
        library.resources.setHiddenBuffer(key: key, bytes: bytes)
        coverageKey = key
        return key
    }

    /// Coarse fallback when a garment ships no body mask: what a slot normally covers.
    static func defaultHideRegions(slot: ClothSlot, itemID: String) -> [String] {
        switch slot {
        case .top: return itemID.contains("dress") ? ["torso_upper", "torso_lower"] : ["torso_upper"]
        case .bottom: return itemID.contains("skirt") ? [] : ["torso_lower"]
        case .gloves: return ["hand_L", "hand_R"]
        case .shoesIn, .shoesOut: return ["foot_L", "foot_R"]
        default: return []
        }
    }

    private func headAttach(_ world: [float4x4]) -> float4x4 {
        guard let skel = skeleton, let hi = skel["head"], hi < world.count else { return matrix_identity_float4x4 }
        // Hair authored in body space: attach = current head world × inverse rest head world.
        let rest = skel.restWorldMatrices()[hi]
        return world[hi] * rest.inverse
    }

    /// Matrix mapping a bone's rest space to its current pose (for accessories authored at the bone origin).
    public func boneMatrix(named name: String, world: [float4x4]) -> float4x4 {
        guard let skel = skeleton, let i = skel[name], i < world.count else { return matrix_identity_float4x4 }
        return world[i]
    }
}

/// Builds `MaterialState` for each mesh from the card's colours and the catalog's textures.
public enum MaterialBuilder {

    public static func kind(forMaterialName n: String, meshName m: String) -> MaterialKind {
        let s = (n + " " + m).lowercased()
        if s.contains("ik_skin") || s.contains("skin") || m == "body" { return MaterialKindSkin }
        if s.contains("ik_eyewhite") { return MaterialKindEyeWhite }
        if s.contains("eyelash") || s.contains("eyebrow") { return MaterialKindEyelash }
        if s.contains("ik_eye") || m.hasPrefix("eye_") || s.contains("eyes") { return MaterialKindEye }
        if s.contains("hair") { return MaterialKindHair }
        if s.contains("cloth") || s.contains("fabric") { return MaterialKindCloth }
        if s.contains("teeth") || s.contains("tongue") || s.contains("mouth") { return MaterialKindItem }
        return MaterialKindItem
    }

    static func baseTexture(for part: LoadedAsset.Part, asset: LoadedAsset) -> TextureHandle? {
        part.material.baseColorImage.flatMap { asset.imageTexture($0, srgb: true) }
    }

    public static func material(for part: LoadedAsset.Part, asset: LoadedAsset, card: CharacterCard, library: AssetLibrary) -> MaterialState {
        let k = kind(forMaterialName: part.materialName, meshName: part.meshName)
        switch k {
        case MaterialKindSkin: return skinMaterial(for: part, asset: asset, card: card, library: library)
        case MaterialKindEye: return eyeMaterial(for: part, asset: asset, card: card, library: library)
        case MaterialKindEyelash: return lashMaterial(for: part, asset: asset, card: card, library: library)
        case MaterialKindHair: return hairMaterial(for: part, asset: asset, card: card, library: library)
        default:
            var m = MaterialState(uniforms: .make(kind: k))
            m.base = baseTexture(for: part, asset: asset)
            let c = part.material.baseColorFactor
            m.uniforms.baseColor = c
            if m.base != nil { m.setFlag(MaterialFlagHasBaseTexture, true) }
            if part.material.doubleSided { m.setFlag(MaterialFlagDoubleSided, true) }
            if part.material.alphaMode == "MASK" { m.setFlag(MaterialFlagAlphaTest, true) }
            if part.material.alphaMode == "BLEND" { m.transparent = true; m.setFlag(MaterialFlagNoOutline, true) }
            return m
        }
    }

    public static func skinMaterial(for part: LoadedAsset.Part, asset: LoadedAsset, card: CharacterCard, library: AssetLibrary) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindSkin))
        let sex = card.sex.rawValue
        let tex = library.catalog.textures
        let bodyTex = library.catalog.body(card.body.bodyID)?.textures ?? [:]
        m.base = bodyTex["skinBase"].flatMap { library.texture($0) } ?? tex.skin?["\(sex)_base"].flatMap { library.texture($0) } ?? library.texture("skin_\(sex)_base.png") ?? baseTexture(for: part, asset: asset)
        m.detail = bodyTex["skinDetail"].flatMap { library.texture($0, srgb: false) } ?? tex.skin?["\(sex)_detail"].flatMap { library.texture($0, srgb: false) } ?? library.texture("skin_\(sex)_detail.png", srgb: false)
        m.setFlag(MaterialFlagHasBaseTexture, m.base != nil)
        m.setFlag(MaterialFlagHasDetail, m.detail != nil)
        let tone = card.body.skinTone.linear
        m.uniforms.baseColor = Float4(tone.x, tone.y, tone.z, 1)
        let shade = card.body.skinShadeTint.linear
        m.uniforms.shadowColor = Float4(shade.x / max(tone.x, 0.05), shade.y / max(tone.y, 0.05), shade.z / max(tone.z, 0.05), 0.5)
        m.uniforms.shadowColor = simd_clamp(m.uniforms.shadowColor, Float4(0.3, 0.3, 0.3, 0), Float4(1, 1, 1, 1))
        m.uniforms.params.y = card.body.skinGloss
        let ol = card.body.skinTone.linear * Float3(0.45, 0.28, 0.32)
        m.uniforms.outline = Float4(ol.x, ol.y, ol.z, 1.3)
        m.setFlag(MaterialFlagDoubleSided, false)
        // Makeup overlays
        let ov = tex.faceOverlays ?? tex.overlays ?? [:]
        let blush = ov["blush"].flatMap { library.texture($0, srgb: false) } ?? library.texture("face_overlay_blush.png", srgb: false)
        let shadow = ov["eyeshadow"].flatMap { library.texture($0, srgb: false) } ?? library.texture("face_overlay_eyeshadow.png", srgb: false)
        let lip = ov["lip"].flatMap { library.texture($0, srgb: false) } ?? library.texture("face_overlay_lip.png", srgb: false)
        let e = card.expression
        if let blush { m.overlay0 = blush; m.setFlag(MaterialFlagHasOverlay0, true)
            let c = card.face.blush.color.linear / max(tone, Float3(repeating: 0.05))
            m.uniforms.overlayColor0 = Float4(min(c.x, 1.5), min(c.y, 1.5), min(c.z, 1.5), clamp(card.face.blush.strength + e.blush * 0.6, 0, 1)) }
        if let shadow { m.overlay1 = shadow; m.setFlag(MaterialFlagHasOverlay1, true)
            let c = card.face.eyeshadow.color.linear / max(tone, Float3(repeating: 0.05))
            m.uniforms.overlayColor1 = Float4(min(c.x, 1.5), min(c.y, 1.5), min(c.z, 1.5), card.face.eyeshadow.strength) }
        if let lip { m.overlay2 = lip; m.setFlag(MaterialFlagHasOverlay2, true)
            let c = card.face.lip.color.linear / max(tone, Float3(repeating: 0.05))
            m.uniforms.overlayColor2 = Float4(min(c.x, 1.5), min(c.y, 1.5), min(c.z, 1.5), card.face.lip.strength) }
        return m
    }

    public static func eyeMaterial(for part: LoadedAsset.Part, asset: LoadedAsset, card: CharacterCard, library: AssetLibrary) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindEye))
        let tex = library.catalog.textures
        let irisList = tex.iris ?? []
        let hlList = tex.highlight ?? []
        let irisName = irisList.isEmpty ? "eye_iris_0.png" : irisList[clamp(card.face.irisStyle, 0, irisList.count - 1)]
        let hlName = hlList.isEmpty ? "eye_highlight_0.png" : hlList[clamp(card.face.highlightStyle, 0, hlList.count - 1)]
        let catalogIris = library.texture(irisName)
        m.base = catalogIris ?? baseTexture(for: part, asset: asset)
        m.colorMask = library.texture("eye_white.png")
        m.detail = library.texture(hlName, srgb: false)
        m.setFlag(MaterialFlagHasBaseTexture, m.base != nil)
        if catalogIris == nil && part.material.alphaMode != "OPAQUE" { m.setFlag(MaterialFlagAlphaTest, true); m.uniforms.params.w = 0.1 }
        let isRight = part.meshName.hasSuffix("_R") || part.meshName.lowercased().contains("right")
        let iris = (isRight && !card.face.sameIrisColor ? card.face.irisColorRight : card.face.irisColorLeft).linear
        m.uniforms.baseColor = Float4(iris.x, iris.y, iris.z, 1)
        let w = card.face.eyeWhiteColor.linear
        m.uniforms.tint1 = Float4(w.x, w.y, w.z, 1)
        m.uniforms.eye = Float4(1 + card.face.irisSize / 100 * 0.35, 0, 0, card.face.highlightStrength)
        m.uniforms.shadowColor = Float4(0.85, 0.8, 0.9, 0.5)
        return m
    }

    public static func lashMaterial(for part: LoadedAsset.Part, asset: LoadedAsset, card: CharacterCard, library: AssetLibrary) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindEyelash))
        let tex = library.catalog.textures
        let isBrow = part.meshName.lowercased().contains("brow") || part.materialName.lowercased().contains("brow")
        let list = (isBrow ? tex.eyebrow : tex.eyelash) ?? []
        let style = isBrow ? card.face.eyebrowStyle : card.face.eyelashStyle
        let name = list.isEmpty ? (isBrow ? "eyebrow_0.png" : "eyelash_0.png") : list[clamp(style, 0, list.count - 1)]
        m.base = library.texture(name) ?? baseTexture(for: part, asset: asset)
        m.setFlag(MaterialFlagHasBaseTexture, m.base != nil)
        let c = (isBrow ? card.face.eyebrowColor : card.face.eyelashColor).linear
        m.uniforms.baseColor = Float4(c.x, c.y, c.z, 1)
        m.uniforms.params.w = 0.35
        m.uniforms.shadowColor = Float4(0.85, 0.85, 0.9, 0.5)
        return m
    }

    public static func hairMaterial(for part: LoadedAsset.Part, asset: LoadedAsset, card: CharacterCard, library: AssetLibrary) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindHair))
        let h = card.hair
        let base = h.baseColor.linear
        let shade = h.shadeColor.linear
        m.uniforms.baseColor = Float4(base.x, base.y, base.z, 1)
        let ratio = simd_clamp(shade / max(base, Float3(repeating: 0.03)), Float3(repeating: 0.25), Float3(repeating: 1.1))
        m.uniforms.shadowColor = Float4(ratio.x, ratio.y, ratio.z, 0.5)
        let hl = h.highlightColor.linear
        m.uniforms.specular = Float4(hl.x, hl.y, hl.z, 48)
        let ol = h.outlineColor.linear
        m.uniforms.outline = Float4(ol.x, ol.y, ol.z, 1.5)
        m.uniforms.hairGloss.x = h.gloss
        let strand = part.meshExtras?["strandUV"]?.boolValue ?? part.extras?["strandUV"]?.boolValue ?? (part.materialName.hasPrefix("ik_hair"))
        m.setFlag(MaterialFlagStrandUV, strand)
        if strand, let hs = library.catalog.textures.hairStrand, let t = library.texture(hs) { m.base = t; m.setFlag(MaterialFlagHasBaseTexture, true) }
        if let t = baseTexture(for: part, asset: asset), part.material.alphaMode != "OPAQUE" || part.material.baseColorImage != nil {
            m.base = t
            m.setFlag(MaterialFlagHasBaseTexture, true)
            if part.material.alphaMode == "MASK" || part.material.alphaMode == "BLEND" { m.setFlag(MaterialFlagAlphaTest, true); m.uniforms.params.w = 0.4 }
        }
        if part.material.doubleSided { m.setFlag(MaterialFlagDoubleSided, true) }
        return m
    }

    public static func clothMaterial(for part: LoadedAsset.Part, asset: LoadedAsset, item: ClothItem, library: AssetLibrary) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindCloth))
        m.base = baseTexture(for: part, asset: asset)
        m.setFlag(MaterialFlagHasBaseTexture, m.base != nil)
        let entry = item.itemID.flatMap { library.catalog.cloth($0) }
        m.colorMask = entry?.colorMask.flatMap { library.texture($0, srgb: false) } ?? library.sidecarTexture(for: asset, suffix: "_cm.png", srgb: false)
        m.setFlag(MaterialFlagHasColorMask, m.colorMask != nil)
        let f = part.material.baseColorFactor
        let cols = item.colors + [RGB.white, RGB.white, RGB.white]
        if m.colorMask == nil {
            // No mask: tint the whole garment with colour 1.
            let c = cols[0].linear
            m.uniforms.baseColor = Float4(f.x * c.x, f.y * c.y, f.z * c.z, f.w)
        } else {
            m.uniforms.baseColor = f
            let c1 = cols[0].linear, c2 = cols[1].linear, c3 = cols[2].linear
            m.uniforms.tint1 = Float4(c1.x, c1.y, c1.z, 1); m.uniforms.tint2 = Float4(c2.x, c2.y, c2.z, 1); m.uniforms.tint3 = Float4(c3.x, c3.y, c3.z, 1)
        }
        let patterns = library.catalog.textures.patterns ?? []
        if item.pattern > 0, item.pattern <= patterns.count, let p = library.texture(patterns[item.pattern - 1], srgb: false) {
            m.pattern = p
            m.setFlag(MaterialFlagHasPattern, true)
            let pc = item.patternColor.linear
            m.uniforms.patternColor = Float4(pc.x, pc.y, pc.z, 1)
            m.uniforms.uvTransform = Float4(item.patternScale, item.patternScale, 0, 0)
        }
        m.uniforms.params.y = item.gloss
        if part.material.doubleSided { m.setFlag(MaterialFlagDoubleSided, true) }
        if part.material.alphaMode == "MASK" { m.setFlag(MaterialFlagAlphaTest, true) }
        if part.material.normalImage != nil, let n = part.material.normalImage.flatMap({ asset.imageTexture($0, srgb: false) }) { m.normal = n; m.setFlag(MaterialFlagHasNormal, true) }
        return m
    }

    public static func accessoryMaterial(for part: LoadedAsset.Part, asset: LoadedAsset, def: AccessoryDefinition, library: AssetLibrary) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindItem))
        m.base = baseTexture(for: part, asset: asset)
        m.setFlag(MaterialFlagHasBaseTexture, m.base != nil)
        m.colorMask = library.sidecarTexture(for: asset, suffix: "_cm.png", srgb: false)
        let f = part.material.baseColorFactor
        let cols = def.colors + [RGB.white, RGB.white, RGB.white]
        if m.colorMask != nil {
            m.setFlag(MaterialFlagHasColorMask, true)
            m.uniforms.baseColor = f
            let c1 = cols[0].linear, c2 = cols[1].linear, c3 = cols[2].linear
            m.uniforms.tint1 = Float4(c1.x, c1.y, c1.z, 1); m.uniforms.tint2 = Float4(c2.x, c2.y, c2.z, 1); m.uniforms.tint3 = Float4(c3.x, c3.y, c3.z, 1)
        } else {
            let c = cols[0].linear
            m.uniforms.baseColor = Float4(f.x * c.x, f.y * c.y, f.z * c.z, f.w)
        }
        if part.material.alphaMode == "BLEND" { m.transparent = true; m.setFlag(MaterialFlagNoOutline, true) }
        if part.material.doubleSided { m.setFlag(MaterialFlagDoubleSided, true) }
        return m
    }

    /// Generic material for studio items (props).
    public static func itemMaterial(for part: LoadedAsset.Part, asset: LoadedAsset, tint: RGB?, emissive: Float = 0) -> MaterialState {
        var m = MaterialState(uniforms: .make(kind: MaterialKindItem))
        m.base = baseTexture(for: part, asset: asset)
        m.setFlag(MaterialFlagHasBaseTexture, m.base != nil)
        var f = part.material.baseColorFactor
        if let tint { let c = tint.linear; f = Float4(f.x * c.x, f.y * c.y, f.z * c.z, f.w) }
        m.uniforms.baseColor = f
        m.uniforms.emissive = Float4(f.x, f.y, f.z, emissive)
        if part.material.alphaMode == "BLEND" { m.transparent = true; m.setFlag(MaterialFlagNoOutline, true) }
        if part.material.alphaMode == "MASK" { m.setFlag(MaterialFlagAlphaTest, true) }
        if part.material.doubleSided { m.setFlag(MaterialFlagDoubleSided, true) }
        return m
    }
}

// MARK: - IK targets

public struct IKTarget: Codable, Sendable, Equatable {
    public var enabled = false
    /// Target position in character root space.
    public var position = Float3.zero
    /// Optional pole position (root space); nil uses a sensible default per chain.
    public var pole: Float3?
    public init(enabled: Bool = false, position: Float3 = .zero, pole: Float3? = nil) { self.enabled = enabled; self.position = position; self.pole = pole }
}

public enum IKChain: String, CaseIterable, Codable, Sendable {
    case handL = "hand_L", handR = "hand_R", footL = "foot_L", footR = "foot_R"
    public var bones: (upper: String, lower: String, end: String) {
        switch self {
        case .handL: return ("upperarm_L", "forearm_L", "hand_L")
        case .handR: return ("upperarm_R", "forearm_R", "hand_R")
        case .footL: return ("thigh_L", "calf_L", "foot_L")
        case .footR: return ("thigh_R", "calf_R", "foot_R")
        }
    }
    public var label: String {
        switch self { case .handL: return "Left hand"; case .handR: return "Right hand"; case .footL: return "Left foot"; case .footR: return "Right foot" }
    }
    /// Default bend direction offset (root space) added to the mid joint for the pole.
    public var defaultPoleOffset: Float3 {
        switch self {
        case .handL, .handR: return Float3(0, -0.3, -0.5)   // elbows back and down
        case .footL, .footR: return Float3(0, 0, 0.6)       // knees forward
        }
    }
}

extension CharacterInstance {
    /// Applies enabled IK targets to a pose (root space). Returns the modified pose.
    public func applyIK(to pose: Pose, targets: [IKChain: IKTarget]) -> Pose {
        guard let skel = skeleton, targets.values.contains(where: { $0.enabled }) else { return pose }
        var p = pose
        for chain in IKChain.allCases {
            guard let t = targets[chain], t.enabled else { continue }
            let names = chain.bones
            guard let ui = skel[names.upper], let li = skel[names.lower], let ei = skel[names.end] else { continue }
            let world = p.worldMatrices(skeleton: skel)
            let a = world[ui].translation, b = world[li].translation, c = world[ei].translation
            let pole = t.pole ?? (b + chain.defaultPoleOffset)
            let r = IKSolver.twoBone(a: a, b: b, c: c, target: t.position, pole: pole)
            // Upper: world delta → local
            let upperWorldRot = p.worldRotation(ui, skeleton: skel)
            let parentRot = skel.bones[ui].parent.map { p.worldRotation($0, skeleton: skel) } ?? .identity
            p.rotations[ui] = (parentRot.inverse * (r.upper * upperWorldRot)).normalized
            // Lower: recompute its parent's new world rotation first
            let lowerWorldRot = r.upper * p.worldRotation(li, skeleton: skel)   // old lower world rotated by upper delta
            let newUpperWorld = p.worldRotation(ui, skeleton: skel)
            p.rotations[li] = (newUpperWorld.inverse * (r.lower * lowerWorldRot)).normalized
        }
        return p
    }

    /// World-space (root-space) joint position for a chain end in the current pose.
    public func jointPosition(_ boneName: String, pose: Pose) -> Float3? {
        guard let skel = skeleton, let i = skel[boneName] else { return nil }
        return pose.worldMatrices(skeleton: skel)[i].translation
    }
}
