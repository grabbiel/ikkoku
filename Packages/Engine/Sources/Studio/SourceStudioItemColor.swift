import Foundation
import simd
import Assets
import Character

/// The record color and alpha a converted basic-shape material asks the item
/// record to supply, decoded once per part from the glTF material `extras`.
public struct SourceStudioItemTint: Sendable, Equatable {
    /// The saved Unity `Color` components verbatim. CharaStudio is a gamma-space
    /// project, so this is the same sRGB-encoded space the serialized `_Color`
    /// was exported in. It REPLACES the exported base factor (the serialized
    /// `_Color`), as `UpdateColor` overwrites `_Color` at runtime; the caller
    /// converts it with `RGB.linear` like any native color.
    public let color: RGB
    /// The record alpha that REPLACES the exported base alpha (the serialized
    /// `_alpha` the alpha shader scales `_MainTex.a` with), as `UpdateColor`
    /// overwrites `_alpha`; nil when the material has no alpha property.
    public let alpha: Float?
}

public enum SourceStudioItemColor {
    /// Resolves `extras.itemColorSlot` (0 = `_Color`, 1 = `_Color2`,
    /// 2 = `_Color3`) to the record's saved color, and `itemAlphaProperty`
    /// `_alpha` to the record's alpha. A missing, null, out-of-range or
    /// non-integral slot, and non-finite color or alpha components, return nil
    /// so the caller leaves the exported material untouched.
    public static func tint(record: KoikatsuItemRecord, extras: JSONValue?) -> SourceStudioItemTint? {
        tint(colors: record.colors, alpha: record.alpha, extras: extras)
    }

    /// The same resolution from the values an import retained alongside the
    /// resolved asset, so the frame builder never re-reads the scene file.
    public static func tint(colors: [SIMD4<Float>], alpha: Float, extras: JSONValue?) -> SourceStudioItemTint? {
        guard let slot = extras?["itemColorSlot"]?.doubleValue, slot.isFinite,
              slot == slot.rounded(.towardZero), slot >= 0, Int(slot) < colors.count
        else { return nil }
        let color = colors[Int(slot)]
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite else { return nil }
        var recordAlpha: Float?
        if extras?["itemAlphaProperty"]?.stringValue == "_alpha" {
            guard alpha.isFinite else { return nil }
            recordAlpha = min(max(alpha, 0), 1)
        }
        return SourceStudioItemTint(color: RGB(color.x, color.y, color.z), alpha: recordAlpha)
    }
}
