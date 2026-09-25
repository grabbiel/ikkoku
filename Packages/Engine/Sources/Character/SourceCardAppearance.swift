import Foundation
import CoreMath
import Assets

/// Typed color editing and source-identity checks over the original records.
/// Missing fields stay missing; this adapter never invents constructor defaults.
public struct SourceCardAppearance: Sendable {
    public struct Color: Sendable, Identifiable {
        public let id: String, label: String
        public var rgba: Float4
        public let record: SourceCharacterCard.Record, path: [SourceCharacterCard.Field]
        public var edit: SourceCharacterCard.ColorEdit { .init(record: record, path: path, rgba: [rgba.x, rgba.y, rgba.z, rgba.w]) }
    }
    public let coordinate: Int
    public private(set) var colors: [Color] = []
    public private(set) var diagnostics: [String] = []
    public let modProperties: Set<String>
    public private(set) var usesCoordinateMakeup = false
    private var records: [String: [String: SourceMessagePackValue]] = [:]

    public init(card: SourceCharacterCard, coordinate: Int = 0) throws {
        guard (0..<7).contains(coordinate) else { throw SourceCharacterCardError.invalid("Outfit index must be in 0...6.") }
        self.coordinate = coordinate
        modProperties = Set(try card.modReferences()?.records.compactMap { record in
            record.modGUID?.isEmpty == false ? record.property : nil
        } ?? [])
        for (name, record) in [("face", SourceCharacterCard.Record.face), ("body", .body), ("hair", .hair), ("clothes", .clothes(coordinate: coordinate)), ("accessory", .accessory(coordinate: coordinate))] {
            do { records[name] = try card.recordFields(record) }
            catch { diagnostics.append("\(name) appearance retained without preview: \(error)") }
        }
        // The enable flag is a raw BinaryWriter byte between the two MessagePack
        // records, not a field in the makeup record. Preserve its original value.
        if let block = card.block(named: "Coordinate"), block.version == "0.0.0",
           let entries = try? SourceMessagePack.decode(block.data).arrayValue,
           entries.indices.contains(coordinate), let data = entries[coordinate].binaryValue {
            var reader = try CardReader(data)
            _ = try reader.lengthPrefixedData(); _ = try reader.lengthPrefixedData()
            let flag = try reader.take(1)[0]
            usesCoordinateMakeup = flag != 0
        }
        if usesCoordinateMakeup {
            records["makeup"] = try card.recordFields(.makeup(coordinate: coordinate))
        } else if let value = records["face"]?["baseMakeup"] {
            let fields = try value.stringKeyedMap()
            if fields["version"]?.stringValue == "0.0.0" { records["makeup"] = fields }
            else { diagnostics.append("Base makeup record version is unsupported; original value retained.") }
        }
        for (key, label) in [("cheekColor", "Cheek makeup"), ("lipColor", "Lip makeup"), ("eyeshadowColor", "Eyeshadow") ] {
            addMakeupColor(key, label: label)
        }
        for index in 0..<2 { addMakeupColor("paintColor.\(index)", label: "Face paint \(index + 1)") }
        for (key, label) in [("moleColor", "Mole"), ("lipLineColor", "Lip line")] {
            addColor("face." + key, label: label, record: .face)
        }
        if let parts = records["accessory"]?["parts"]?.arrayValue {
            for index in 0..<min(parts.count, 128) {
                for channel in 0..<4 {
                    addColor("accessory.parts.\(index).color.\(channel)", label: "Accessory \(index + 1) color \(channel + 1)", record: .accessory(coordinate: coordinate))
                }
            }
        }
        for (key, label) in [("skinMainColor", "Skin"), ("skinSubColor", "Skin secondary")] {
            addColor("body." + key, label: label, record: .body)
        }
        for (key, label) in [("eyebrowColor", "Eyebrows"), ("eyelineColor", "Eyelines"),
                             ("whiteBaseColor", "Eye whites"), ("whiteSubColor", "Eye white shadow"),
                             ("hlUpColor", "Upper iris highlight"), ("hlDownColor", "Lower iris highlight")] {
            addColor("face." + key, label: label, record: .face)
        }
        for index in 0..<2 {
            addColor("face.pupil.\(index).baseColor", label: "\(index == 0 ? "Left" : "Right") iris", record: .face)
            addColor("face.pupil.\(index).subColor", label: "\(index == 0 ? "Left" : "Right") iris secondary", record: .face)
        }
        for index in 0..<4 {
            for (key, label) in [("baseColor", "base"), ("startColor", "roots"), ("endColor", "tips")] {
                addColor("hair.parts.\(index).\(key)", label: "\(["Back", "Front", "Side", "Extra"][index]) hair \(label)", record: .hair)
            }
        }
        for index in 0..<9 {
            for channel in 0..<4 {
                addColor("clothes.parts.\(index).colorInfo.\(channel).baseColor",
                    label: "\(["Top", "Bottom", "Inner top", "Inner bottom", "Gloves", "Legwear", "Socks", "Indoor shoes", "Outdoor shoes"][index]) color \(channel + 1)",
                    record: .clothes(coordinate: coordinate))
                addColor("clothes.parts.\(index).colorInfo.\(channel).patternColor", label: "Clothing \(index + 1) pattern \(channel + 1)", record: .clothes(coordinate: coordinate))
            }
        }
    }

    public func value(_ path: String) -> SourceMessagePackValue? {
        let fields = path.split(separator: ".").map(String.init)
        guard fields.count >= 2, let root = records[fields[0]], var value = root[fields[1]] else { return nil }
        for field in fields.dropFirst(2) {
            if let index = Int(field), let list = value.arrayValue, list.indices.contains(index) { value = list[index] }
            else if let map = try? value.stringKeyedMap(), let next = map[field] { value = next }
            else { return nil }
        }
        return value
    }

    public func number(_ path: String) -> Float? {
        guard let value = value(path) else { return nil }
        let result: Float
        switch value {
        case .float(let n): result = Float(n)
        case .integer(let n): result = Float(n)
        case .unsigned(let n): result = Float(n)
        default: return nil
        }
        return result.isFinite ? result : nil
    }

    public func color(_ id: String) -> Float4? { colors.first { $0.id == id }?.rgba }

    public mutating func setColor(_ id: String, rgba: Float4) throws {
        guard (0..<4).allSatisfy({ rgba[$0].isFinite && (0...1).contains(rgba[$0]) }),
              let index = colors.firstIndex(where: { $0.id == id }) else {
            throw SourceCharacterCardError.invalid("Unsupported color field or value.")
        }
        colors[index].rgba = rgba
    }

    private mutating func addMakeupColor(_ key: String, label: String) {
        let fields: [SourceCharacterCard.Field] = key.split(separator: ".").map { Int($0).map(SourceCharacterCard.Field.index) ?? .key(String($0)) }
        addColor("makeup." + key, label: label,
            record: usesCoordinateMakeup ? .makeup(coordinate: coordinate) : .face,
            editPath: usesCoordinateMakeup ? fields : [.key("baseMakeup")] + fields)
    }

    private mutating func addColor(_ id: String, label: String, record: SourceCharacterCard.Record, editPath: [SourceCharacterCard.Field]? = nil) {
        guard let raw = value(id) else { return }
        guard let values = raw.arrayValue else {
            diagnostics.append("\(id) is not an RGBA array; original value retained."); return
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
            diagnostics.append("\(id) is not a normalized RGBA color; original value retained."); return
        }
        let path = id.split(separator: ".").dropFirst().map { value -> SourceCharacterCard.Field in
            Int(value).map(SourceCharacterCard.Field.index) ?? .key(String(value))
        }
        colors.append(.init(id: id, label: label, rgba: Float4(numbers), record: record, path: editPath ?? path))
    }
}
