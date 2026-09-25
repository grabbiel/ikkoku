import Foundation
import Assets

/// Destinations read from the card itself, independently of its saved resolver
/// metadata. A saved category or local slot cannot redefine these destinations.
public struct SourceCardResolverDestinationScan: Sendable {
    public let destinations: [SourceCardModReferences.Destination]
    public let diagnostics: [String]
}

extension SourceCharacterCard {
    /// Enumerate the installed Sideloader's card properties from supported source
    /// records. Missing values are not replaced with guessed constructor defaults.
    public func resolverDestinations(contract: SourceModCatalogContract) throws -> SourceCardResolverDestinationScan {
        var scanner = CardDestinationScanner(contract: contract)
        if let custom = block(named: "Custom"), custom.version == "0.0.0" {
            var reader = ResolverRecordReader(data: custom.data)
            for name in ["face", "body", "hair"] {
                do {
                    let bytes = try reader.record()
                    if let fields = scanner.record(bytes, name: name,
                        version: name == "hair" ? "0.0.4" : "0.0.2") {
                        switch name {
                        case "face": scanner.face(fields)
                        case "body": scanner.body(fields)
                        default: scanner.hair(fields)
                        }
                    }
                } catch {
                    scanner.diagnostics.append("Custom \(name) framing is unsupported: \(error). Later Custom records were not scanned.")
                    break
                }
            }
            if reader.remaining > 0 { scanner.diagnostics.append("Uninterpreted bytes remain in the Custom block.") }
        } else { scanner.diagnostics.append("No supported Custom block is available for resolver destinations.") }

        if let coordinate = block(named: "Coordinate"), coordinate.version == "0.0.0" {
            do {
                guard let outfits = try SourceMessagePack.decode(coordinate.data).arrayValue else {
                    throw SourceCharacterCardError.invalid("Coordinate is not a MessagePack byte-array list")
                }
                // ChaFile initializes seven coordinates and SetCoordinateBytes
                // loads only min(coordinate.Length, list.Count).
                if outfits.count > 7 {
                    scanner.diagnostics.append("Coordinate entries after outfit6 are preserved but ignored by the recovered seven-outfit card loader.")
                }
                if outfits.count < 7 {
                    scanner.diagnostics.append("Only \(outfits.count) serialized outfits are present; absent outfit defaults were not invented.")
                }
                for (index, value) in outfits.prefix(7).enumerated() {
                    guard let bytes = value.binaryValue else {
                        scanner.diagnostics.append("outfit\(index) is not a binary coordinate record and was not scanned.")
                        continue
                    }
                    scanner.coordinate(bytes, prefix: "outfit\(index).")
                }
            } catch { scanner.diagnostics.append("Coordinate destinations could not be scanned: \(error).") }
        } else { scanner.diagnostics.append("No supported Coordinate block is available for outfit resolver destinations.") }
        return scanner.finish()
    }
}

private struct CardDestinationScanner {
    typealias Fields = [String: SourceMessagePackValue]
    let contract: SourceModCatalogContract
    var destinations: [SourceCardModReferences.Destination] = []
    var diagnostics: [String] = []
    var missing: [String: [String]] = [:]

    mutating func finish() -> SourceCardResolverDestinationScan {
        for scope in missing.keys.sorted() {
            let values = missing[scope]!
            let examples = values.prefix(4).joined(separator: ", ")
            diagnostics.append("\(scope): \(values.count) missing or invalid resolver values were not inferred (\(examples)\(values.count > 4 ? ", …" : "")).")
        }
        return SourceCardResolverDestinationScan(destinations: destinations, diagnostics: diagnostics)
    }

    mutating func record(_ bytes: Data, name: String, version: String) -> Fields? {
        do {
            let fields = try SourceMessagePack.decode(bytes).stringKeyedMap()
            guard fields["version"]?.stringValue == version else {
                throw SourceCharacterCardError.invalid("expected record version \(version)")
            }
            return fields
        } catch { diagnostics.append("\(name) resolver destinations were not scanned: \(error)."); return nil }
    }

    mutating func add(_ value: SourceMessagePackValue?, category: Int, property: String, prefix: String = "") {
        let full = prefix + property
        guard let slot = value?.integerValue, Int32(exactly: slot) != nil else {
            let scope = prefix + String(property.split(separator: ".").first ?? "record")
            missing[scope, default: []].append(property)
            return
        }
        guard contract.categories.contains(where: { $0.number == category && $0.properties.contains(property) }) else {
            diagnostics.append("\(full) category \(category) is absent from the recovered catalog contract and was not inferred.")
            return
        }
        destinations.append(.init(property: full, catalogProperty: property, category: category, sourceSlot: slot))
    }

    mutating func map(_ value: SourceMessagePackValue?, name: String) -> Fields? {
        guard let value else { diagnostics.append("\(name) is absent; its resolver values were not inferred."); return nil }
        do { return try value.stringKeyedMap() }
        catch { diagnostics.append("\(name) is not a supported field map and was not scanned."); return nil }
    }

    mutating func array(_ value: SourceMessagePackValue?, name: String, maximum: Int) -> [SourceMessagePackValue]? {
        guard let values = value?.arrayValue, values.count <= maximum else {
            diagnostics.append("\(name) is absent or is not an array within the \(maximum)-entry limit; its values were not inferred.")
            return nil
        }
        return values
    }

    mutating func face(_ fields: Fields) {
        for (field, category) in [("headId", 100), ("detailId", 400), ("eyebrowId", 406), ("noseId", 414),
            ("hlUpId", 410), ("hlDownId", 411), ("whiteId", 407), ("eyelineUpId", 412),
            ("eyelineDownId", 413), ("moleId", 415), ("lipLineId", 404)] {
            add(fields[field], category: category, property: "ChaFileFace." + field)
        }
        if let pupils = array(fields["pupil"], name: "face.pupil", maximum: 1024) {
            for index in 0..<min(2, pupils.count) {
                if let pupil = map(pupils[index], name: "face.pupil[\(index)]") {
                    add(pupil["id"], category: 408, property: "ChaFileFace.Pupil\(index + 1)")
                    add(pupil["gradMaskId"], category: 409, property: "ChaFileFace.PupilGradient\(index + 1)")
                }
            }
            if pupils.count < 2 { diagnostics.append("face.pupil contains fewer than two serialized entries; missing destinations were not inferred.") }
        }
        // UAR visits baseMakeup, not each coordinate's optional makeup.
        if let makeup = map(fields["baseMakeup"], name: "face.baseMakeup") {
            if makeup["version"]?.stringValue == "0.0.0" { self.makeup(makeup) }
            else { diagnostics.append("face.baseMakeup resolver destinations require record version 0.0.0.") }
        }
    }

    mutating func body(_ fields: Fields) {
        for (field, category) in [("detailId", 420), ("sunburnId", 422), ("nipId", 423), ("underhairId", 424)] {
            add(fields[field], category: category, property: "ChaFileBody." + field)
        }
        indexed(fields["paintId"], category: 421, property: "ChaFileBody.PaintID", count: 2)
        indexed(fields["paintLayoutId"], category: 3, property: "ChaFileBody.PaintLayoutID", count: 2)
    }

    mutating func hair(_ fields: Fields) {
        add(fields["glossId"], category: 433, property: "ChaFileHair.glossId")
        if let parts = array(fields["parts"], name: "hair.parts", maximum: 1024) {
            for (index, name) in ["HairBack", "HairFront", "HairSide", "HairOption"].enumerated() where index < parts.count {
                if let part = map(parts[index], name: "hair.parts[\(index)]") {
                    add(part["id"], category: 101 + index, property: "ChaFileHair." + name)
                }
            }
            if parts.count < 4 { diagnostics.append("hair.parts contains fewer than four serialized entries; missing destinations were not inferred.") }
        }
    }

    mutating func makeup(_ fields: Fields) {
        for (field, category) in [("eyeshadowId", 401), ("cheekId", 402), ("lipId", 403)] {
            add(fields[field], category: category, property: "ChaFileMakeup." + field)
        }
        indexed(fields["paintId"], category: 405, property: "ChaFileMakeup.PaintID", count: 2)
    }

    mutating func indexed(_ value: SourceMessagePackValue?, category: Int, property: String, count: Int) {
        if let values = array(value, name: property, maximum: 1024) {
            for index in 0..<count {
                add(index < values.count ? values[index] : nil, category: category, property: property + "\(index + 1)")
            }
        }
    }

    mutating func coordinate(_ bytes: Data, prefix: String) {
        var reader = ResolverRecordReader(data: bytes)
        do {
            if let fields = record(try reader.record(), name: prefix + "clothes", version: "0.0.1") { clothes(fields, prefix: prefix) }
            if let fields = record(try reader.record(), name: prefix + "accessory", version: "0.0.2"),
               let parts = array(fields["parts"], name: prefix + "accessory.parts", maximum: 4096) {
                for (index, value) in parts.enumerated() {
                    let scope = prefix + "accessory\(index)."
                    if let fields = map(value, name: scope + "parts") {
                        guard let category = fields["type"]?.integerValue, Int32(exactly: category) != nil else {
                            diagnostics.append("\(scope)PartsInfo.type is missing or invalid; its resolver category was not inferred.")
                            continue
                        }
                        add(fields["id"], category: category, property: "ChaFileAccessory.PartsInfo.id", prefix: scope)
                    }
                }
            }
            _ = try reader.take(1) // BinaryReader.ReadBoolean treats every nonzero byte as true.
            _ = try reader.record() // Coordinate makeup is not visited by IterateCoordinatePrefixes.
            if reader.remaining > 0 { diagnostics.append("\(prefix)contains uninterpreted trailing coordinate bytes.") }
        } catch { diagnostics.append("\(prefix)coordinate framing is incomplete: \(error). Only preceding supported fields were scanned.") }
    }

    mutating func clothes(_ fields: Fields, prefix: String) {
        let names = ["Top", "Bot", "Bra", "Shorts", "Gloves", "Pants", "Socks", "ShoesInner", "ShoesOuter"]
        if let parts = array(fields["parts"], name: prefix + "clothes.parts", maximum: 1024) {
            for (index, name) in names.enumerated() where index < parts.count {
                guard let part = map(parts[index], name: prefix + "clothes.parts[\(index)]") else { continue }
                let property = "ChaFileClothes.Clothes" + name
                add(part["id"], category: min(105 + index, 112), property: property, prefix: prefix)
                add(part["emblemeId"], category: 431, property: property + "Emblem", prefix: prefix)
                add(part["emblemeId2"], category: 431, property: property + "Emblem2", prefix: prefix)
                if let colors = array(part["colorInfo"], name: prefix + "clothes.parts[\(index)].colorInfo", maximum: 1024) {
                    for colorIndex in 0..<min(4, colors.count) {
                        if let color = map(colors[colorIndex], name: property + ".colorInfo[\(colorIndex)]") {
                            add(color["pattern"], category: 430, property: property + "Pattern\(colorIndex)", prefix: prefix)
                        }
                    }
                    if colors.count < 4 { diagnostics.append("\(prefix)\(property) has fewer than four serialized colorInfo entries; missing patterns were not inferred.") }
                }
            }
            if parts.count < names.count { diagnostics.append("\(prefix)clothes.parts has fewer than nine serialized entries; missing destinations were not inferred.") }
        }
        if let subparts = array(fields["subPartsId"], name: prefix + "clothes.subPartsId", maximum: 1024) {
            // The source visits both keys for the same three values; it does not
            // infer the active jacket/sailor category from the top's asset name.
            for (kind, category) in [("Jacket", 210), ("Sailor", 200)] {
                for (index, letter) in ["A", "B", "C"].enumerated() {
                    add(index < subparts.count ? subparts[index] : nil, category: category + index,
                        property: "ChaFileClothes.Clothes\(kind)Sub\(letter)", prefix: prefix)
                }
            }
        }
    }
}

/// Small read-only BinaryReader subset for the three nested card records. Bounds
/// are checked before any index operation; SourceMessagePack adds its own limits.
private struct ResolverRecordReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SourceCharacterCardError.invalid("truncated at byte \(offset)") }
        let start = data.index(data.startIndex, offsetBy: offset)
        defer { offset += count }
        return Data(data[start..<data.index(start, offsetBy: count)])
    }
    mutating func record() throws -> Data {
        let bytes = try take(4)
        let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        let count = Int32(bitPattern: bits)
        guard count >= 0 else { throw SourceCharacterCardError.invalid("negative record length") }
        return try take(Int(count))
    }
}
