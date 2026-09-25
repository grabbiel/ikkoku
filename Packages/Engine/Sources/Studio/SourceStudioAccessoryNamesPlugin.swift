import Foundation

/// Native label adapter for installed KK_StudioAccessoryNames 1.1.0. Inputs are
/// the queried slot widgets and resolved accessory names at the next UI frame.
/// It changes presentation only, never card IDs, UAR records or scene objects.
public enum SourceStudioAccessoryNamesPlugin {
    public static let guid = "KK_StudioAccessoryNames", version = "1.1.0"
    public struct Row: Codable, Sendable, Equatable {
        public var text: String?
        public var active: Bool
        public var buttonX: [Float]
        public var offsetMaxX: Float?
        public init(text: String?, active: Bool = true, buttonX: [Float] = [], offsetMaxX: Float? = nil) {
            self.text = text; self.active = active; self.buttonX = buttonX; self.offsetMaxX = offsetMaxX
        }
    }
    public static func update(_ rows: [Row], accessoryNames: [Int: String]) -> [Row] {
        var slot = 0
        return rows.map { row in
            var result = row
            result.buttonX = row.buttonX.map { $0 == 100 ? 160 : $0 == 130 ? 190 : $0 }
            guard let text = row.text else { return result }
            result.offsetMaxX = 150
            // System.Char.IsDigit works on UTF-16 code units, not graphemes.
            guard text.unicodeScalars.contains(where: { $0.value <= 0xffff && $0.properties.generalCategory == .decimalNumber }) else { return result }
            let number = String(format: "%02d", slot + 1)
            result.text = row.active ? accessoryNames[slot].map { number + " " + $0 } ?? "スロット" + number : "スロット" + number
            slot += 1
            return result
        }
    }
}
