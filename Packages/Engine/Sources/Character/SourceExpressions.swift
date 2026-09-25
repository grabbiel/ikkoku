import Foundation
import Scene

/// Inputs to the recovered source expression controllers. Rates are normalized;
/// the controller quantizes openness to an integer percentage before blending.
public struct SourceExpressionInputs: Codable, Sendable, Equatable {
    public var eyebrowPattern: Int, eyesPattern: Int, mouthPattern: Int
    public var eyebrowOpenRate: Float, eyesOpenRate: Float, mouthOpenRate: Float
    public var eyebrowOpenMax: Float, eyesOpenMax: Float, mouthOpenMax: Float
    public var blinkRate: Float, mouthFixedRate: Float
}

public struct SourceExpressionContract: Decodable, Sendable {
    public struct Channel: Decodable, Sendable {
        public let index: Int
        public let name: String?
        public let frameIndex: Int?
        public let frameWeight: Float?
    }
    public struct Pattern: Decodable, Sendable {
        public let index: Int, close: Channel, open: Channel
    }
    public struct Target: Decodable, Sendable {
        public let nodeName: String, meshName: String, meshSourceID: String
        public let channelCount: Int, controlledChannelIndices: [Int]
        public let patterns: [Pattern]
    }
    public struct Controller: Decodable, Sendable {
        public let id: String
        public let openMin: Float, openMax: Float, fixedRate: Float
        public let syncBlink: Bool?
        public let sourcePatternCount: Int, targets: [Target]
    }
    public struct Preset: Decodable, Sendable {
        public let id: String, label: String, inputs: SourceExpressionInputs
    }
    public let schemaVersion: Int, weightUnit: String, transitionSeconds: Float
    public let updateOrder: [String], controllers: [Controller]
    public let defaults: SourceExpressionInputs, presets: [Preset]
    /// Source FaceBlendShape neutral-gaze limit: 1 - EyeLookUpCorrect.
    /// Older head-00 contracts omitted this field and used 0.92.
    public let eyesOpenMaxCap: Float?

    public static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    private func validate() throws {
        let ids: Set<String> = ["eyebrow", "eyes", "mouth"]
        guard schemaVersion == 1, weightUnit == "percent", transitionSeconds.isFinite, transitionSeconds > 0,
              updateOrder == ["eyebrow", "eyes", "mouth"], controllers.count == 3,
              Set(controllers.map(\.id)) == ids, Set(presets.map(\.id)).count == presets.count else {
            throw RigError.invalid("Unsupported source expression contract.")
        }
        if let eyesOpenMaxCap {
            guard eyesOpenMaxCap.isFinite, (0...1).contains(eyesOpenMaxCap) else {
                throw RigError.invalid("Invalid head-specific eyes openness limit.")
            }
        }
        for controller in controllers {
            guard controller.openMin.isFinite, controller.openMax.isFinite, controller.fixedRate.isFinite,
                  (0...1).contains(controller.openMin), (0...1).contains(controller.openMax),
                  (-1...1).contains(controller.fixedRate), controller.sourcePatternCount > 0,
                  !controller.targets.isEmpty,
                  Set(controller.targets.map(\.meshName)).count == controller.targets.count else {
                throw RigError.invalid("Invalid source expression controller '\(controller.id)'.")
            }
            for target in controller.targets {
                guard !target.meshName.isEmpty, target.channelCount > 0,
                      target.patterns.map(\.index) == Array(0..<controller.sourcePatternCount),
                      Set(target.controlledChannelIndices).count == target.controlledChannelIndices.count else {
                    throw RigError.invalid("Invalid expression target '\(target.meshName)'.")
                }
                var controlled = Set<Int>()
                for pattern in target.patterns {
                    for channel in [pattern.close, pattern.open] {
                        guard channel.index >= -1, channel.index < target.channelCount else { throw RigError.invalid("Expression channel index out of bounds.") }
                        if channel.index >= 0 {
                            guard channel.name?.isEmpty == false, channel.frameWeight == 100 else { throw RigError.invalid("Expression channel lacks its original single-frame identity.") }
                            controlled.insert(channel.index)
                        }
                    }
                }
                guard Set(target.controlledChannelIndices.filter { $0 >= 0 }) == controlled else {
                    throw RigError.invalid("Expression controlled-channel set does not match its patterns.")
                }
            }
        }
        try validate(inputs: defaults)
        for preset in presets { try validate(inputs: preset.inputs) }
    }

    private func validate(inputs: SourceExpressionInputs) throws {
        for rate in [inputs.eyebrowOpenRate, inputs.eyesOpenRate, inputs.mouthOpenRate,
                     inputs.eyebrowOpenMax, inputs.eyesOpenMax, inputs.mouthOpenMax] {
            guard rate.isFinite, (0...1).contains(rate) else { throw RigError.invalid("Expression rates must be in 0...1.") }
        }
        guard inputs.blinkRate.isFinite, inputs.mouthFixedRate.isFinite,
              (-1...1).contains(inputs.blinkRate), (-1...1).contains(inputs.mouthFixedRate) else {
            throw RigError.invalid("Invalid fixed expression rate.")
        }
        for controller in controllers {
            guard (0..<controller.sourcePatternCount).contains(pattern(for: controller.id, inputs: inputs)) else {
                throw RigError.invalid("Expression pattern is outside the recovered controller.")
            }
        }
    }

    private func pattern(for id: String, inputs: SourceExpressionInputs) -> Int {
        switch id { case "eyebrow": inputs.eyebrowPattern; case "eyes": inputs.eyesPattern; default: inputs.mouthPattern }
    }

    /// Neutral gaze and caller-supplied blink/voice rates. Random mouth-width motion,
    /// gaze correction away from center and voice analysis are separate source systems.
    /// Missing targets (for example inactive tears excluded from an avatar) are skipped.
    public func weights(source: SourceRig, inputs: SourceExpressionInputs,
                        previous: SourceExpressionInputs? = nil, transition: Float = 1) throws -> [String: [(index: Int, weight: Float)]] {
        try validate(inputs: inputs)
        if let previous { try validate(inputs: previous) }
        guard transition.isFinite, (0...1).contains(transition) else { throw RigError.invalid("Expression transition must be in 0...1.") }
        let progress: Float = previous == nil ? 1 : transition
        var result: [String: [Int: Float]] = [:]
        for id in updateOrder {
            guard let controller = controllers.first(where: { $0.id == id }) else { throw RigError.invalid("Missing expression controller.") }
            let rate: Float, maximum: Float, fixed: Float
            switch id {
            case "eyebrow":
                rate = controller.syncBlink == true && inputs.blinkRate >= 0 ? inputs.blinkRate : inputs.eyebrowOpenRate
                maximum = inputs.eyebrowOpenMax; fixed = controller.fixedRate
            case "eyes":
                rate = inputs.blinkRate >= 0 ? inputs.blinkRate : inputs.eyesOpenRate
                maximum = min(inputs.eyesOpenMax, eyesOpenMaxCap ?? 0.92); fixed = controller.fixedRate
            default:
                rate = inputs.mouthOpenRate; maximum = inputs.mouthOpenMax; fixed = inputs.mouthFixedRate
            }
            let openness = fixed >= 0 ? fixed : controller.openMin + (maximum - controller.openMin) * rate
            let percent = Float(Int(min(max(openness * 100, 0), 100)))
            let currentPattern = pattern(for: id, inputs: inputs)
            let previousPattern = previous.map { pattern(for: id, inputs: $0) } ?? currentPattern
            for target in controller.targets {
                for part in source.parts where source.rig.skins[part.skin].name == target.meshName {
                    guard source.rig.nodes[part.node].name == target.nodeName,
                          part.mesh.morphTargets.count == target.channelCount else {
                        throw RigError.invalid("Expression target '\(target.meshName)' does not match the imported morph channels.")
                    }
                    for candidate in target.patterns {
                        for channel in [candidate.close, candidate.open] where channel.index >= 0 {
                            guard part.mesh.morphTargets[channel.index].name == channel.name else { throw RigError.invalid("Expression channel identity changed in '\(target.meshName)'.") }
                        }
                    }
                    var values = result[part.mesh.name] ?? [:]
                    for channel in target.controlledChannelIndices where channel >= 0 { values[channel] = 0 }
                    // Keep source operation order and add when Close and Open share one channel.
                    for (index, factor) in [(previousPattern, 1 - progress), (currentPattern, progress)] where factor != 0 {
                        let entry = target.patterns[index]
                        if entry.close.index >= 0 { values[entry.close.index, default: 0] += (100 - percent) * factor }
                        if entry.open.index >= 0 { values[entry.open.index, default: 0] += percent * factor }
                    }
                    result[part.mesh.name] = values
                }
            }
        }
        return try result.mapValues { values in
            let weights = values.sorted { $0.key < $1.key }.filter { $0.value != 0 }.map { (index: $0.key, weight: $0.value / 100) }
            guard weights.allSatisfy({ $0.weight.isFinite && $0.weight >= 0 && $0.weight <= 1.000001 }) else {
                throw RigError.invalid("Source expression generated an invalid weight.")
            }
            return weights.map { (index: $0.index, weight: min($0.weight, 1)) }
        }
    }
}
