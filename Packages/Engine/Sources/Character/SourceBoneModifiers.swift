import Foundation
import CryptoKit
import simd
import Assets
import CoreMath
import Scene

/// Static baseline subset of the installed ABMX 5.4 behavior. Values retain
/// source Unity coordinates and bone names until application to a native pose.
public struct SourceBoneModifiers: Decodable, Sendable {
    public struct Diagnostic: Decodable, Sendable {
        public let code: String, severity: String, message: String
    }

    public struct Source: Decodable, Sendable {
        public let pluginGUID: String, dataGUID: String, pluginVersion: String
        public let dataKind: String, dataVersion: Int
        public let assemblySHA256: String, payloadSHA256: String
    }

    public struct Values: Decodable, Sendable, Equatable {
        public let scaleModifier: [Float], lengthModifier: Float
        public let positionModifier: [Float], rotationModifier: [Float]

        public var isIdentity: Bool {
            scaleModifier == [1, 1, 1] && lengthModifier == 1 &&
                positionModifier == [0, 0, 0] && rotationModifier == [0, 0, 0]
        }
    }

    public struct Modifier: Decodable, Sendable {
        public let boneName: String, boneLocation: Int
        public let coordinateModifiers: [Values]
        public var coordinateCount: Int { coordinateModifiers.count }

        /// ABMX treats one entry as coordinate-independent. A missing entry in a
        /// coordinate-specific record supplies no modifier for that coordinate.
        public func values(for coordinate: Int) -> Values? {
            guard coordinate >= 0 else { return nil }
            if coordinateModifiers.count == 1 { return coordinateModifiers[0] }
            return coordinateModifiers.indices.contains(coordinate) ? coordinateModifiers[coordinate] : nil
        }
    }

    public let schemaVersion: Int, kind: String, coordinateSpace: String, angleUnit: String, mode: String
    public let source: Source, modifiers: [Modifier]
    /// Repairs and unsupported source scopes retained by the wire-format adapter.
    public let diagnostics: [Diagnostic]?
    public var count: Int { modifiers.count }
    public var coordinateCounts: [Int] { modifiers.map(\.coordinateCount) }

    public static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    /// Decode the original PluginData.data["boneData"] bytes, retaining Unity
    /// coordinates. Supports the installed ABMX card v2 / coordinate v3 arrays,
    /// either plain MessagePack or its LZ4 extension 99 wrapper. Legacy migration
    /// and accessory/dynamic evaluation remain outside the static pose contract.
    public static func decodeBoneData(
        _ data: Data, dataKind: String, dataVersion: Int,
        assemblySHA256: String = "f3e2d9877b08b2b25187cbc101478ea0d484bcfe4856244050ba3119578e9f68"
    ) throws -> Self {
        guard (dataKind == "card" && dataVersion == 2) ||
                (dataKind == "coordinate" && dataVersion == 3), isHash(assemblySHA256) else {
            throw RigError.invalid("Supported ABMX versions are card v2 and coordinate v3 with valid assembly provenance; legacy migration is not implemented.")
        }
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else {
            throw RigError.invalid("ABMX boneData must contain 1 byte through 16 MiB.")
        }
        let decoded: SourceMessagePackValue
        do { decoded = try SourceMessagePack.decodeLZ4(data, maximumBytes: 64 * 1024 * 1024) }
        catch { throw RigError.invalid("Invalid ABMX boneData MessagePack/LZ4: \(error)") }
        guard let records = decoded.arrayValue, records.count <= 10_000 else {
            throw RigError.invalid("ABMX boneData requires at most 10000 BoneModifier records.")
        }

        func number(_ value: SourceMessagePackValue) throws -> Float {
            let scalar: Double
            switch value {
            case .integer(let integer): scalar = Double(integer)
            case .unsigned(let integer): scalar = Double(integer)
            case .float(let floating): scalar = floating
            default: throw RigError.invalid("ABMX modifier values must be finite float32 numbers.")
            }
            guard scalar.isFinite, abs(scalar) <= Double(Float.greatestFiniteMagnitude) else {
                throw RigError.invalid("ABMX modifier values must be finite float32 numbers.")
            }
            return Float(scalar)
        }
        func vector(_ value: SourceMessagePackValue) throws -> [Float] {
            guard let elements = value.arrayValue, elements.count == 3 else {
                throw RigError.invalid("ABMX source Vector3 requires exactly three scalars.")
            }
            return try elements.map(number)
        }

        let identity = Values(scaleModifier: [1, 1, 1], lengthModifier: 1,
                              positionModifier: [0, 0, 0], rotationModifier: [0, 0, 0])
        var modifiers: [Modifier] = [], diagnostics: [Diagnostic] = []
        var identities = Set<Data>()
        modifiers.reserveCapacity(records.count)
        for record in records {
            guard let fields = record.arrayValue, fields.count == 3 else {
                throw RigError.invalid("ABMX records require BoneName, CoordinateModifiers, and BoneLocation in source order.")
            }
            guard let name = fields[0].stringValue, !name.isEmpty,
                  name.unicodeScalars.count <= 1024, !name.contains("\0") else {
                throw RigError.invalid("ABMX BoneName must contain 1 through 1024 source characters and no NUL.")
            }
            guard let location = fields[2].integerValue, location >= 0 else {
                throw RigError.invalid("ABMX BoneLocation must be a nonnegative integer representable by the native index type.")
            }
            // Compare the original name bytes: Swift's canonical-equivalence
            // String equality would otherwise merge distinct source names.
            guard identities.insert(Data("\(location):\(name)".utf8)).inserted else {
                throw RigError.invalid("Duplicate ABMX location/name: \(location)/\(name).")
            }
            guard let coordinates = fields[1].arrayValue, (1...1024).contains(coordinates.count) else {
                throw RigError.invalid("ABMX CoordinateModifiers requires 1 through 1024 entries; null/empty arrays are invalid.")
            }
            var values: [Values] = []
            values.reserveCapacity(coordinates.count)
            for (index, coordinate) in coordinates.enumerated() {
                if case .null = coordinate {
                    values.append(identity)
                    diagnostics.append(Diagnostic(code: "repaired-null-coordinate", severity: "warning",
                        message: "ABMX repaired null coordinate #\(index + 1) for '\(name)' to identity; the converted document preserves this repair."))
                    continue
                }
                guard let fields = coordinate.arrayValue, fields.count == 4 else {
                    throw RigError.invalid("ABMX coordinate entries require Scale, Length, Position, and Rotation in source order.")
                }
                values.append(try Values(scaleModifier: vector(fields[0]), lengthModifier: number(fields[1]),
                                         positionModifier: vector(fields[2]), rotationModifier: vector(fields[3])))
            }
            modifiers.append(Modifier(boneName: name, boneLocation: location, coordinateModifiers: values))
            if location != 0 && location != 1 {
                diagnostics.append(Diagnostic(code: "unsupported-bone-location", severity: "warning",
                    message: "ABMX bone '\(name)' uses location \(location); the native static evaluator rejects active accessory/unknown-scope modifiers."))
            } else if dynamicInfluencePrefixes.contains(where: { name.hasPrefix($0) }) {
                diagnostics.append(Diagnostic(code: "unsupported-dynamic-bone", severity: "warning",
                    message: "ABMX bone '\(name)' uses the source dynamic-baseline/gravity path; the native static evaluator rejects active modifiers on this target."))
            }
        }
        let result = Self(schemaVersion: 1, kind: "ikkoku-source-bone-modifiers",
                          coordinateSpace: "unity-left-handed-y-up", angleUnit: "degrees", mode: "staticBaseline",
                          source: Source(pluginGUID: "KKABMX.Core", dataGUID: "KKABMPlugin.ABMData", pluginVersion: "5.4",
                              dataKind: dataKind, dataVersion: dataVersion, assemblySHA256: assemblySHA256,
                              payloadSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
                          modifiers: modifiers, diagnostics: diagnostics)
        try result.validate()
        return result
    }

    private func validate() throws {
        guard schemaVersion == 1, kind == "ikkoku-source-bone-modifiers",
              coordinateSpace == "unity-left-handed-y-up", angleUnit == "degrees", mode == "staticBaseline",
              source.pluginGUID == "KKABMX.Core", source.dataGUID == "KKABMPlugin.ABMData",
              source.pluginVersion == "5.4",
              (source.dataKind == "card" && source.dataVersion == 2) ||
                (source.dataKind == "coordinate" && source.dataVersion == 3),
              Self.isHash(source.assemblySHA256), Self.isHash(source.payloadSHA256) else {
            throw RigError.invalid("Unsupported ABMX document, data version, or coordinate convention.")
        }
        var names = Set<Data>()
        for modifier in modifiers {
            guard !modifier.boneName.isEmpty, !modifier.boneName.contains("\0"), modifier.boneLocation >= 0,
                  names.insert(Data("\(modifier.boneLocation):\(modifier.boneName)".utf8)).inserted,
                  !modifier.coordinateModifiers.isEmpty else {
                throw RigError.invalid("ABMX records require a bone name, unique location/name, and at least one coordinate entry.")
            }
            for values in modifier.coordinateModifiers {
                guard values.scaleModifier.count == 3, values.positionModifier.count == 3,
                      values.rotationModifier.count == 3, values.lengthModifier.isFinite,
                      [values.scaleModifier, values.positionModifier, values.rotationModifier]
                        .allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
                    throw RigError.invalid("ABMX modifier '\(modifier.boneName)' has invalid scalar/vector data.")
                }
            }
        }
    }

    /// Supply the neutral pose after body/face customization, before skin palettes.
    /// Reuse that unmodified baseline on each application: ABMX offsets do not
    /// accumulate across frames. This does not run animation, BoneEffect callbacks,
    /// partial baseline collection, accessory lookup, or dynamic-bone corrections.
    public func applying(to rig: RigDefinition, baseline: RigPose, coordinate: Int = 0) throws -> RigPose {
        guard coordinate >= 0, baseline.localMatrices.count == rig.nodes.count else {
            throw RigError.invalid("ABMX requires a nonnegative coordinate and a baseline matching the rig.")
        }
        // Validate even inactive nodes and ancestor matrices before exposing a pose.
        _ = try rig.evaluate(baseline)
        var result = baseline
        var appliedNodes = Set<Int>()
        // Original controller iterates ascending BoneLocation, retaining record
        // order within each location. Names are never translated or mirrored.
        let ordered = modifiers.enumerated().sorted {
            $0.element.boneLocation == $1.element.boneLocation ? $0.offset < $1.offset :
                $0.element.boneLocation < $1.element.boneLocation
        }
        for (_, modifier) in ordered {
            guard let values = modifier.values(for: coordinate), !values.isIdentity else { continue }
            guard modifier.boneLocation == 0 || modifier.boneLocation == 1 else {
                throw RigError.invalid("ABMX '\(modifier.boneName)' uses unsupported bone location \(modifier.boneLocation); accessory scope is not imported.")
            }
            guard !Self.dynamicInfluencePrefixes.contains(where: { modifier.boneName.hasPrefix($0) }) else {
                throw RigError.invalid("ABMX '\(modifier.boneName)' requires the source dynamic-bone baseline/gravity path, which is not implemented.")
            }
            let node = try Self.bodyNode(named: modifier.boneName, rig: rig)
            guard appliedNodes.insert(node).inserted else {
                throw RigError.invalid("ABMX has multiple active records for '\(modifier.boneName)'; overlapping locations are unsupported.")
            }
            var matrix = baseline.localMatrices[node]
            let scale = Float3(values.scaleModifier)
            if values.rotationModifier != [0, 0, 0] {
                guard rig.nodes[node].authoredMatrix == nil,
                      (0..<3).allSatisfy({ rig.nodes[node].scale[$0] > 0 }) else {
                    throw RigError.invalid("ABMX rotation on '\(modifier.boneName)' requires positive authored TRS scales; signed or matrix-only baseline axes cannot be recovered unambiguously.")
                }
                // Remove the baseline scale before postmultiplying its rotation.
                // The supported shaping stage preserves positive local scale.
                // Matrix orthogonality/determinant alone cannot reveal two negative
                // scale components; authored signs are checked above as well.
                let x = Float3(matrix[0].x, matrix[0].y, matrix[0].z)
                let y = Float3(matrix[1].x, matrix[1].y, matrix[1].z)
                let z = Float3(matrix[2].x, matrix[2].y, matrix[2].z)
                let baselineScale = Float3(simd_length(x), simd_length(y), simd_length(z))
                guard (0..<3).allSatisfy({ baselineScale[$0].isFinite && baselineScale[$0] > 1e-8 }),
                      simd_determinant(float3x3(columns: (x, y, z))) > 0,
                      abs(simd_dot(x / baselineScale.x, y / baselineScale.y)) < 1e-4,
                      abs(simd_dot(x / baselineScale.x, z / baselineScale.z)) < 1e-4,
                      abs(simd_dot(y / baselineScale.y, z / baselineScale.z)) < 1e-4 else {
                    throw RigError.invalid("ABMX rotation on '\(modifier.boneName)' requires a positive orthogonal baseline; reflected, singular, or sheared rotation baselines are unsupported.")
                }
                let rotation = float3x3(columns: (x / baselineScale.x, y / baselineScale.y, z / baselineScale.z))
                    * float3x3(UnityCoordinates.eulerDegrees(Float3(values.rotationModifier)))
                let adjustedScale = baselineScale * scale
                matrix[0] = Float4(rotation[0] * adjustedScale.x, 0)
                matrix[1] = Float4(rotation[1] * adjustedScale.y, 0)
                matrix[2] = Float4(rotation[2] * adjustedScale.z, 0)
            } else {
                // Preserve the authored axes exactly when no rotation is requested.
                // This also supports negative/zero scale without an ambiguous TRS
                // decomposition, as long as final renderer transforms stay valid.
                matrix[0] *= scale.x
                matrix[1] *= scale.y
                matrix[2] *= scale.z
            }
            let position = Float3(matrix[3].x, matrix[3].y, matrix[3].z) * values.lengthModifier
                + UnityCoordinates.position(Float3(values.positionModifier))
            matrix[3] = Float4(position, 1)
            result.localMatrices[node] = matrix
        }
        _ = try rig.evaluate(result)
        return result
    }

    private static let dynamicInfluencePrefixes = ["cf_d_sk_", "cf_j_bust0", "cf_d_siri01_", "cf_j_siri_"]
    private static func bodyNode(named name: String, rig: RigDefinition) throws -> Int {
        let roots = rig.nodes(named: "p_cf_body_bone")
        guard roots.count <= 1 else { throw RigError.invalid("ABMX BodyTop has multiple source skeleton roots.") }
        var candidates = rig.nodes(named: name)
        if let root = roots.first {
            candidates = candidates.filter { candidate in
                var current: Int? = candidate
                while let index = current {
                    if index == root { return true }
                    // Original BoneFinder excludes embedded characters. Accessory
                    // subtrees are not imported by the supported avatar assembly.
                    if rig.nodes[index].name.hasPrefix("chaF_") || rig.nodes[index].name.hasPrefix("chaM_") { return false }
                    current = rig.nodes[index].parent
                }
                return false
            }
        }
        guard candidates.count == 1 else {
            throw RigError.invalid("ABMX expected one BodyTop bone named '\(name)', found \(candidates.count); missing or ambiguous targets are unsupported.")
        }
        return candidates[0]
    }
    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
