import Foundation

public enum SourceShapeError: Error, LocalizedError, Sendable, Equatable {
    case invalidContract(String)
    case invalidRate
    case missingChannel(String)
    case invalidSlot(Int)
    case incompleteState(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidContract(reason): return "Invalid source shape contract: \(reason)."
        case .invalidRate: return "Source shape values must be finite and between 0 and 1."
        case let .missingChannel(name): return "Source shape channel \(name) is missing."
        case let .invalidSlot(index): return "Source shape slot \(index) is out of bounds."
        case let .incompleteState(name): return "Source shape state for \(name) is missing or invalid."
        }
    }
}

/// Raw Unity local values. Source channels can be intermediate controller values rather
/// than actual bones; only the explicit directTargets have a supported destination mapping.
public struct SourceShapeTransform: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var rotationDegrees: SIMD3<Float>
    public var scale: SIMD3<Float>

    public init(position: SIMD3<Float> = .zero, rotationDegrees: SIMD3<Float> = .zero,
                scale: SIMD3<Float> = SIMD3(repeating: 1)) {
        self.position = position; self.rotationDegrees = rotationDegrees; self.scale = scale
    }

    fileprivate var isFinite: Bool {
        (0..<3).allSatisfy { position[$0].isFinite && rotationDegrees[$0].isFinite && scale[$0].isFinite }
    }
}

public struct SourceShapeSample: Codable, Sendable {
    /// Original sample number, preserved for provenance. Runtime interpolation uses array index.
    public let key: Int
    public let position: [Float]
    public let rotationDegrees: [Float]
    public let scale: [Float]

    fileprivate var transform: SourceShapeTransform {
        SourceShapeTransform(position: SIMD3(position[0], position[1], position[2]),
                             rotationDegrees: SIMD3(rotationDegrees[0], rotationDegrees[1], rotationDegrees[2]),
                             scale: SIMD3(scale[0], scale[1], scale[2]))
    }
}

public struct SourceShapeChannel: Codable, Sendable {
    public let name: String
    public let samples: [SourceShapeSample]
}

public struct SourceShapeBinding: Codable, Sendable {
    public let sourceName: String
    public let sourceIndex: Int
    public let positionMask: [Bool]
    public let rotationMask: [Bool]
    public let scaleMask: [Bool]
}

public struct SourceShapeSlot: Codable, Sendable {
    public let index: Int
    public let label: String
    public let bindings: [SourceShapeBinding]
}

public struct SourceShapeDirectTarget: Codable, Sendable {
    public let sourceName: String
    public let destinationName: String
    public let positionMask: [Bool]
    public let rotationMask: [Bool]
    public let scaleMask: [Bool]
}

public struct SourceShapeDestinationUpdate: Sendable {
    public let destinationName: String
    public let transform: SourceShapeTransform
    public let positionMask: [Bool]
    public let rotationMask: [Bool]
    public let scaleMask: [Bool]
}

public struct SourceShapeDomain: Codable, Sendable {
    public let id: String
    public let valueCount: Int
    public let defaultValues: [Float]
    public let sourceNames: [String]
    public let destinationNames: [String]
    public let slots: [SourceShapeSlot]
    public let channels: [SourceShapeChannel]
    public let directTargets: [SourceShapeDirectTarget]
    public let unportedDestinationNames: [String]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        valueCount = try container.decode(Int.self, forKey: .valueCount)
        defaultValues = try container.decode([Float].self, forKey: .defaultValues)
        sourceNames = try container.decode([String].self, forKey: .sourceNames)
        destinationNames = try container.decode([String].self, forKey: .destinationNames)
        slots = try container.decode([SourceShapeSlot].self, forKey: .slots)
        channels = try container.decode([SourceShapeChannel].self, forKey: .channels)
        directTargets = try container.decode([SourceShapeDirectTarget].self, forKey: .directTargets)
        unportedDestinationNames = try container.decode([String].self, forKey: .unportedDestinationNames)
        try validate()
    }

    /// Parse bounded CLI/capture overrides over the recovered defaults.
    public func values(overrides expression: String) throws -> [Float] {
        guard !expression.isEmpty else { throw SourceShapeError.invalidContract("Shape overrides must not be empty.") }
        var values = defaultValues
        if expression == "defaults" { return values }
        var seen = Set<Int>()
        for pair in expression.split(separator: ",", omittingEmptySubsequences: false) {
            let components = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard components.count == 2, let rate = Float(components[1]), rate.isFinite, (0...1).contains(rate) else {
                throw SourceShapeError.invalidContract("Shape overrides must be defaults, all=rate, or index=rate pairs with rates in 0...1.")
            }
            if components[0] == "all" {
                guard expression == pair else { throw SourceShapeError.invalidContract("all=rate must be used alone.") }
                return Array(repeating: rate, count: values.count)
            }
            guard let index = Int(components[0]), values.indices.contains(index), seen.insert(index).inserted else {
                throw SourceShapeError.invalidContract("Invalid or duplicate shape slot index.")
            }
            values[index] = rate
        }
        return values
    }

    /// Reconstruct the source controller state in original slot order. A slot changes
    /// only its enabled axes, so separate sliders can share the same source channel.
    public func makeState(values: [Float]? = nil) throws -> [String: SourceShapeTransform] {
        let values = values ?? defaultValues
        guard values.count == valueCount else { throw SourceShapeError.invalidContract("shape value count differs from \(valueCount)") }
        var state = Dictionary(uniqueKeysWithValues: sourceNames.map { ($0, SourceShapeTransform()) })
        for index in 0..<valueCount { try apply(slot: index, value: values[index], to: &state) }
        return state
    }

    /// Applies a single normalized slider value to an existing intermediate source state.
    /// State is unchanged on failure, including an incomplete caller-supplied dictionary.
    public func apply(slot index: Int, value: Float, to state: inout [String: SourceShapeTransform]) throws {
        guard slots.indices.contains(index) else { throw SourceShapeError.invalidSlot(index) }
        guard value.isFinite, (0...1).contains(value) else { throw SourceShapeError.invalidRate }
        var changes: [String: SourceShapeTransform] = [:]
        for binding in slots[index].bindings {
            guard var current = changes[binding.sourceName] ?? state[binding.sourceName], current.isFinite else {
                throw SourceShapeError.incompleteState(binding.sourceName)
            }
            let sampled = try sample(channelName: binding.sourceName, rate: value)
            for axis in 0..<3 {
                if binding.positionMask[axis] { current.position[axis] = sampled.position[axis] }
                if binding.rotationMask[axis] { current.rotationDegrees[axis] = sampled.rotationDegrees[axis] }
                if binding.scaleMask[axis] { current.scale[axis] = sampled.scale[axis] }
            }
            changes[binding.sourceName] = current
        }
        for (name, value) in changes { state[name] = value }
    }

    /// Matches AnimationKeyInfo.GetInfo: evenly spaced array samples, linear position
    /// and scale, and Unity LerpAngle separately on each Euler component.
    public func sample(channelName: String, rate: Float) throws -> SourceShapeTransform {
        guard rate.isFinite, (0...1).contains(rate) else { throw SourceShapeError.invalidRate }
        guard let channel = channels.first(where: { $0.name == channelName }) else { throw SourceShapeError.missingChannel(channelName) }
        if rate == 0 || channel.samples.count == 1 { return channel.samples[0].transform }
        if rate == 1 { return channel.samples[channel.samples.count - 1].transform }
        let index = Float(channel.samples.count - 1) * rate
        let lower = Int(floor(index)), t = index - Float(lower)
        let a = channel.samples[lower].transform, b = channel.samples[min(lower + 1, channel.samples.count - 1)].transform
        var rotation = SIMD3<Float>.zero
        for axis in 0..<3 {
            var delta = (b.rotationDegrees[axis] - a.rotationDegrees[axis]).truncatingRemainder(dividingBy: 360)
            if delta < 0 { delta += 360 }
            if delta > 180 { delta -= 360 }
            rotation[axis] = a.rotationDegrees[axis] + delta * t
        }
        let result = SourceShapeTransform(position: a.position + (b.position - a.position) * t,
                                          rotationDegrees: rotation, scale: a.scale + (b.scale - a.scale) * t)
        guard result.isFinite else { throw SourceShapeError.invalidContract("interpolation overflow") }
        return result
    }

    /// Supported direct setter operations only. The caller applies each component mask
    /// to the destination bone's absolute local pose and handles Unity coordinate conversion.
    public func destinationUpdates(from state: [String: SourceShapeTransform]) throws -> [SourceShapeDestinationUpdate] {
        try directTargets.map { target in
            guard let transform = state[target.sourceName], transform.isFinite else { throw SourceShapeError.incompleteState(target.sourceName) }
            return SourceShapeDestinationUpdate(destinationName: target.destinationName, transform: transform,
                                                positionMask: target.positionMask, rotationMask: target.rotationMask,
                                                scaleMask: target.scaleMask)
        }
    }

    fileprivate func validate() throws {
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else { throw SourceShapeError.invalidContract("\(id): \(reason)") }
        }
        func unique(_ values: [String]) -> Bool { Set(values).count == values.count && values.allSatisfy { !$0.isEmpty } }
        func masks(_ position: [Bool], _ rotation: [Bool], _ scale: [Bool]) -> Bool {
            position.count == 3 && rotation.count == 3 && scale.count == 3
        }
        try require(!id.isEmpty && valueCount > 0 && valueCount <= 1_024, "invalid domain or slot count")
        try require(defaultValues.count == valueCount && defaultValues.allSatisfy { $0.isFinite && (0...1).contains($0) }, "invalid defaults")
        try require(slots.count == valueCount && slots.enumerated().allSatisfy { $0.offset == $0.element.index }, "slots must be contiguous and ordered")
        try require(sourceNames.count <= 10_000 && destinationNames.count <= 10_000 && unique(sourceNames) && unique(destinationNames), "invalid or duplicate bone names")
        try require(channels.count <= 10_000 && unique(channels.map(\.name)), "invalid or duplicate channels")
        let available = Set(channels.map(\.name))
        var totalSamples = 0
        for channel in channels {
            totalSamples += channel.samples.count
            try require(!channel.samples.isEmpty && totalSamples <= 1_000_000, "invalid sample count")
            for sample in channel.samples {
                try require(sample.position.count == 3 && sample.rotationDegrees.count == 3 && sample.scale.count == 3, "sample vectors must have three components")
                try require(sample.transform.isFinite, "nonfinite sample")
            }
        }
        var totalBindings = 0
        for slot in slots {
            totalBindings += slot.bindings.count
            try require(totalBindings <= 100_000, "too many bindings")
            for binding in slot.bindings {
                try require(sourceNames.indices.contains(binding.sourceIndex), "invalid source index")
                try require(sourceNames[binding.sourceIndex] == binding.sourceName && available.contains(binding.sourceName), "unresolved binding channel")
                try require(masks(binding.positionMask, binding.rotationMask, binding.scaleMask), "binding masks must have three components")
            }
        }
        try require(directTargets.count <= destinationNames.count && unique(directTargets.map(\.destinationName)), "duplicate direct destination")
        let sourceSet = Set(sourceNames), destinationSet = Set(destinationNames)
        for target in directTargets {
            try require(sourceSet.contains(target.sourceName) && available.contains(target.sourceName) && destinationSet.contains(target.destinationName), "unresolved direct operation")
            try require(masks(target.positionMask, target.rotationMask, target.scaleMask), "target masks must have three components")
        }
        let supported = Set(directTargets.map(\.destinationName)), unported = Set(unportedDestinationNames)
        try require(unique(unportedDestinationNames) && supported.isDisjoint(with: unported) && supported.union(unported) == destinationSet, "destination coverage must explicitly mark unported operations")
    }
}

/// Schema 1 emitted by Tools/reverse/analysis/character_contracts.py. All decoded
/// contracts are validated before their fixed-size vectors or indices can be sampled.
public struct SourceShapeContract: Codable, Sendable {
    public let schemaVersion: Int
    public let coordinateSystem: String
    public let rotationUnit: String
    public let valueRange: [Float]
    public let domains: [SourceShapeDomain]

    public static func decode(_ data: Data) throws -> SourceShapeContract {
        guard data.count <= 64 * 1_048_576 else { throw SourceShapeError.invalidContract("file exceeds 64 MiB") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func domain(_ id: String) -> SourceShapeDomain? { domains.first { $0.id == id } }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        coordinateSystem = try container.decode(String.self, forKey: .coordinateSystem)
        rotationUnit = try container.decode(String.self, forKey: .rotationUnit)
        valueRange = try container.decode([Float].self, forKey: .valueRange)
        domains = try container.decode([SourceShapeDomain].self, forKey: .domains)
        guard schemaVersion == 1, coordinateSystem == "UnityLeftHandedYUp", rotationUnit == "degrees", valueRange == [0, 1] else {
            throw SourceShapeError.invalidContract("unsupported schema or coordinate convention")
        }
        guard !domains.isEmpty, domains.count <= 16, Set(domains.map(\.id)).count == domains.count else {
            throw SourceShapeError.invalidContract("invalid or duplicate domains")
        }
        for domain in domains { try domain.validate() }
    }
}
