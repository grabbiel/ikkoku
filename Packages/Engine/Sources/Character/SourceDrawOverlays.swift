import Foundation
import Assets

/// One draw-material overlay as bound by the source: a single texture material
/// (category and source catalog ID) plus its RGBA tint for one overtex slot.
/// Derivation only: no texture is loaded here and no value was compared with
/// an original capture.
public struct SourceDrawOverlayBinding: Equatable, Sendable {
    public enum Material: String, Sendable { case face, body, eye }
    public enum Slot: Int, Sendable { case overtex1 = 1, overtex2 = 2, overtex3 = 3 }
    public let material: Material
    public let slot: Slot
    public let category: String
    public let id: Int?
    public let rgba: SIMD4<Float>
    /// True when RGB is supplied by the prefab material rather than this binding.
    public let rgbFromPrefab: Bool
    public init(material: Material, slot: Slot, category: String, id: Int?, rgba: SIMD4<Float>,
                rgbFromPrefab: Bool = false) {
        self.material = material; self.slot = slot; self.category = category; self.id = id
        self.rgba = rgba; self.rgbFromPrefab = rgbFromPrefab
    }
}

/// Native derivation of the ChaControl draw-material overlays. The slots match
/// the source exactly: face overtex1 binds lip, face overtex2 blush (a prefab
/// texture whose RGB is not in the card), face overtex3 eyeshadow, body
/// overtex1 nip, body overtex2 underhair, and the eye material binds only
/// the iris highlight pair on its first two slots.
public enum SourceDrawOverlays {
    /// Binds the slots from card records only; slots whose source fields are
    /// absent stay unbound without invented defaults. Malformed fields emit a
    /// diagnostic and stay unbound, matching how `SourceCardAppearance`
    /// retains unreadable colours. The active makeup record (coordinate
    /// makeup when `enableMakeup` is set, otherwise face `baseMakeup`) comes
    /// from `SourceCardAppearance` itself — the selection is never
    /// re-implemented here — so it is read through its record accessors for
    /// outfit coordinate 0 (its default, the only one shown in preview).
    public static func bindings(
        card: SourceCharacterCard,
        hohoAkaRate: Float = 0,
        gagEyes: Bool = false
    ) throws -> (bindings: [SourceDrawOverlayBinding], diagnostics: [String]) {
        let appearance = try SourceCardAppearance(card: card)
        var bindings: [SourceDrawOverlayBinding] = [], diagnostics: [String] = []

        // Same rules as `SourceCardAppearance.addColor`: a missing field emits
        // no binding and no diagnostic; a present-but-unreadable one emits a
        // diagnostic naming the path and still yields no binding.
        func rgba(_ path: String) -> SIMD4<Float>? {
            guard let raw = appearance.value(path) else { return nil }
            guard let values = raw.arrayValue else {
                diagnostics.append("\(path) is not an RGBA array; original value retained."); return nil
            }
            let numbers = values.compactMap { value -> Float? in
                switch value {
                case .float(let n): return Float(n)
                case .integer(let n): return Float(n)
                case .unsigned(let n): return Float(n)
                default: return nil
                }
            }
            guard values.count == 4, numbers.count == 4, numbers.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                diagnostics.append("\(path) is not a normalized RGBA color; original value retained."); return nil
            }
            return SIMD4(numbers[0], numbers[1], numbers[2], numbers[3])
        }
        // Catalog IDs live in the card records as MessagePack integers only.
        func sourceID(_ path: String) -> Int? {
            guard let value = appearance.value(path) else { return nil }
            switch value {
            case .integer(let value): return Int(value)
            case .unsigned(let value):
                if let id = Int(exactly: value) { return id }
                diagnostics.append("\(path) is not a source catalog ID; original value retained.")
                return nil
            default: diagnostics.append("\(path) is not a source catalog ID; original value retained."); return nil
            }
        }
        func bindCatalog(_ material: SourceDrawOverlayBinding.Material, _ slot: SourceDrawOverlayBinding.Slot,
                         _ category: String, _ idPath: String, _ colorPath: String,
                         transform: (SIMD4<Float>) -> SIMD4<Float> = { $0 }) {
            let id = sourceID(idPath)
            guard let rgba = rgba(colorPath) else { return }
            guard let id else {
                diagnostics.append("\(idPath) missing; \(category) not bound")
                return
            }
            bindings.append(.init(material: material, slot: slot, category: category,
                                  id: id, rgba: transform(rgba)))
        }
        func bindPrefab(_ material: SourceDrawOverlayBinding.Material, _ slot: SourceDrawOverlayBinding.Slot,
                        _ category: String, _ rgba: SIMD4<Float>?) {
            guard let rgba else { return }
            bindings.append(.init(material: material, slot: slot, category: category, id: nil,
                                  rgba: rgba, rgbFromPrefab: true))
        }

        // Lip and eyeshadow bind to the active makeup record; eyeshadow's
        // alpha is forced to 0 while gagEyes suppresses the eyeshadow draw.
        bindCatalog(.face, .overtex1, "mt_lip", "makeup.lipId", "makeup.lipColor")
        let blush = SIMD4<Float>(1, 1, 1, lerp(0, 0.2, hohoAkaRate))
        bindPrefab(.face, .overtex2, "prefab", blush)
        diagnostics.append("face.overtex2 blush RGB comes from the prefab material, not the card.")
        bindCatalog(.face, .overtex3, "mt_eyeshadow", "makeup.eyeshadowId", "makeup.eyeshadowColor") {
            gagEyesAlpha($0, suppressed: gagEyes)
        }
        // Nip and underhair stay on the body record; the iris highlight pair
        // stays on the face record's two highlight entries.
        bindCatalog(.body, .overtex1, "mt_nip", "body.nipId", "body.nipColor")
        bindCatalog(.body, .overtex2, "mt_underhair", "body.underhairId", "body.underhairColor")
        bindCatalog(.eye, .overtex1, "mt_eye_hi_up", "face.hlUpId", "face.hlUpColor")
        bindCatalog(.eye, .overtex2, "mt_eye_hi_down", "face.hlDownId", "face.hlDownColor")
        return (bindings, diagnostics)
    }

    private static func gagEyesAlpha(_ rgba: SIMD4<Float>, suppressed: Bool) -> SIMD4<Float> {
        suppressed ? SIMD4(rgba.x, rgba.y, rgba.z, 0) : rgba
    }
    private static func lerp(_ from: Float, _ to: Float, _ t: Float) -> Float {
        from + (to - from) * (t.isFinite ? min(max(t, 0), 1) : 0)
    }
}
