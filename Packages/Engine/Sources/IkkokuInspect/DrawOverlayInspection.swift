import Foundation
import simd
import Assets
import Character

/// Prints the native card-derived draw-material bindings for a card. No texture
/// is loaded here and nothing is compared with an original capture; the
/// original-vs-native comparison runs in `Tools/reverse/compare_draw_overlays.py`.
func inspectDrawOverlays(url: URL) throws -> [String: Any] {
    let card = try SourceCharacterCard.load(url: url)
    var diagnostics: [String] = []
    // `hohoAkaRate` lives in the card's Status record. Without a record the
    // blush alpha stays at its zero default exactly like the 0 here.
    var hohoAkaRate: Float = 0
    if let block = card.block(named: "Status") {
        do {
            let status = try SourceMessagePack.decode(block.data).stringKeyedMap()
            if let value = status["hohoAkaRate"] {
                let number: Float
                switch value {
                case .float(let value): number = Float(value)
                case .integer(let value): number = Float(value)
                case .unsigned(let value): number = Float(value)
                default:
                    diagnostics.append("status.hohoAkaRate is not a source number; using 0.")
                    number = 0
                }
                if number.isFinite {
                    hohoAkaRate = number
                } else {
                    diagnostics.append("status.hohoAkaRate is not finite; using 0.")
                }
            }
        } catch { diagnostics.append("Status record unreadable; blush alpha uses 0: \(error)") }
    }
    let (bindings, bindingDiagnostics) = try SourceDrawOverlays.bindings(
        card: card, hohoAkaRate: hohoAkaRate, gagEyes: false)
    return [
        "bindings": bindings.map { binding -> [String: Any] in
            ["material": binding.material.rawValue, "slot": "overtex\(binding.slot.rawValue)",
             "category": binding.category, "id": binding.id as Any? ?? NSNull(),
             "rgba": [binding.rgba.x, binding.rgba.y, binding.rgba.z, binding.rgba.w],
             "rgbFromPrefab": binding.rgbFromPrefab]
        },
        "diagnostics": diagnostics + bindingDiagnostics,
        "hohoAkaRate": hohoAkaRate,
        "sourceSHA256": card.sourceSHA256,
        "scope": "Native card-record derivation only: bindings come from card records, "
            + "not from the original player. The original-player capture stays in "
            + "Tools/reverse; only compare_draw_overlays.py compares both sides.",
    ]
}
