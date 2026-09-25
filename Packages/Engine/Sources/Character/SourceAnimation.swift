import Foundation
import simd
import CoreMath
import Scene

/// Selected generic Transform clips recovered from a Unity controller. Serialized
/// curve values remain in Unity coordinates until application to the native rig.
public struct SourceAnimationLibrary: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public let bundleSHA256: String, rigSHA256: String, controllerID: String, controllerName: String
    }
    public struct Parameter: Decodable, Sendable {
        public let name: String, type: String
        public let floatDefault: Float?
        enum CodingKeys: String, CodingKey { case name, type, defaultValue }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            type = try values.decode(String.self, forKey: .type)
            if type == "float" { floatDefault = try values.decode(Float.self, forKey: .defaultValue) }
            else { floatDefault = nil }
        }
    }
    public struct State: Decodable, Sendable {
        public struct Motion: Decodable, Sendable {
            public let clipID: String
            public let threshold: Float, cycleOffset: Float
        }
        public let id: String, name: String, sourceFullPath: String
        public let speed: Float, speedParameter: String?, cycleOffset: Float, loop: Bool
        public let blendParameter: String?, motions: [Motion]
    }
    public struct Curve: Decodable, Sendable {
        public struct Key: Decodable, Sendable { public let time: Float, coefficients: [Float] }
        public let kind: String, value: Float?, keys: [Key]?, beginTime: Float?, sampleRate: Float?, samples: [Float]?

        fileprivate func sample(_ time: Float) -> Float {
            switch kind {
            case "constant": return value!
            case "dense":
                let data = samples!
                let frame = min(max((time - beginTime!) * sampleRate!, 0), Float(data.count - 1))
                let lower = Int(frame), upper = min(lower + 1, data.count - 1), t = frame - Float(lower)
                return data[lower] + (data[upper] - data[lower]) * t
            default:
                let data = keys!
                var low = 0, high = data.count
                while low < high {
                    let middle = (low + high) / 2
                    if data[middle].time <= time { low = middle + 1 } else { high = middle }
                }
                let key = data[max(0, low - 1)], t = max(0, time - key.time), c = key.coefficients
                return ((c[0] * t + c[1]) * t + c[2]) * t + c[3]
            }
        }
    }
    public struct Clip: Decodable, Sendable {
        public struct Binding: Decodable, Sendable {
            public let pathHash: UInt32, attribute: Int, curveOffset: Int
            public let sourcePath: String?, targetSourceID: String?, targetName: String?
            public var dimension: Int { attribute == 2 ? 4 : 3 }
        }
        public let id: String, name: String, startTime: Float, stopTime: Float, sampleRate: Float, loop: Bool
        public let bindings: [Binding], curves: [Curve], unboundPathHashes: [UInt32]
        public var duration: Float { stopTime - startTime }

        /// Time is absolute clip time. At an exact loop boundary playback returns
        /// the first sample; nonlooping queries clamp to the authored final sample.
        public func sample(time: Float, looping: Bool = false) throws -> [Float] {
            guard time.isFinite, time >= 0 else { throw RigError.invalid("Animation time must be finite and nonnegative.") }
            var time = time
            if looping && time >= startTime { time = startTime + (time - startTime).truncatingRemainder(dividingBy: duration) }
            else { time = min(max(time, startTime), stopTime) }
            let result = curves.map { $0.sample(time) }
            guard result.allSatisfy(\.isFinite) else { throw RigError.invalid("Animation curve evaluation overflowed.") }
            return result
        }
    }
    public let schemaVersion: Int, converterVersion: String, kind: String, coordinateSpace: String, scope: String
    public let source: Source, parameters: [Parameter], states: [State], clips: [Clip], diagnostics: [String]

    public static func load(url: URL) throws -> Self {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0, size <= 64 * 1024 * 1024 else {
            throw RigError.invalid("Animation library must be a regular file of 1 byte through 64 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
        return try decode(data)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw RigError.invalid("Animation library exceeds size limits.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    public func clip(id: String) throws -> Clip {
        guard let clip = clips.first(where: { $0.id == id }) else { throw RigError.invalid("Unknown source animation clip '\(id)'.") }
        return clip
    }
    public func state(id: String) throws -> State {
        guard let state = states.first(where: { $0.id == id }) else { throw RigError.invalid("Unknown source animation state '\(id)'.") }
        return state
    }

    public struct WeightedMotion: Sendable {
        public let clipID: String, weight: Float, cycleOffset: Float
    }
    /// Flat 1D threshold projection of an explicitly selected state. This does
    /// not execute AnyState transitions, other layers or StateMachineBehaviours.
    public func motions(stateID: String, floatParameters: [String: Float] = [:]) throws -> [WeightedMotion] {
        let state = try state(id: stateID)
        guard floatParameters.values.allSatisfy(\.isFinite) else { throw RigError.invalid("Animator parameters must be finite.") }
        if state.motions.count == 1 {
            let motion = state.motions[0]
            return [.init(clipID: motion.clipID, weight: 1, cycleOffset: state.cycleOffset + motion.cycleOffset)]
        }
        let parameter = state.blendParameter!
        let value = try parameterValue(parameter, values: floatParameters)
        let motions = state.motions
        if value <= motions[0].threshold {
            return [.init(clipID: motions[0].clipID, weight: 1, cycleOffset: state.cycleOffset + motions[0].cycleOffset)]
        }
        if value >= motions.last!.threshold {
            let motion = motions.last!
            return [.init(clipID: motion.clipID, weight: 1, cycleOffset: state.cycleOffset + motion.cycleOffset)]
        }
        let upper = motions.firstIndex { $0.threshold > value }!, lower = upper - 1
        let amount = (value - motions[lower].threshold) / (motions[upper].threshold - motions[lower].threshold)
        return [(lower, 1 - amount), (upper, amount)].map { index, weight in
            .init(clipID: motions[index].clipID, weight: weight, cycleOffset: state.cycleOffset + motions[index].cycleOffset)
        }
    }

    public func stateSpeed(stateID: String, floatParameters: [String: Float] = [:]) throws -> Float {
        let state = try state(id: stateID)
        let multiplier = try state.speedParameter.map { try parameterValue($0, values: floatParameters) } ?? 1
        let speed = state.speed * multiplier
        guard speed.isFinite, speed >= 0 else { throw RigError.invalid("Negative or overflowing state playback speed is unsupported.") }
        return speed
    }

    /// The selected state's synchronized normalized clock uses the weighted
    /// authored durations. No controller transitions are inferred here.
    public func stateDuration(stateID: String, floatParameters: [String: Float] = [:]) throws -> Float {
        let values = try motions(stateID: stateID, floatParameters: floatParameters)
        let duration = try values.reduce(Float(0)) { try $0 + clip(id: $1.clipID).duration * $1.weight }
        guard duration.isFinite, duration > 0 else { throw RigError.invalid("Invalid blended animation duration.") }
        return duration
    }

    public func applying(stateID: String, normalizedTime: Float, floatParameters: [String: Float] = [:],
                         to rig: RigDefinition, baseline: RigPose? = nil, allowingUnbound: Bool = false) throws -> RigPose {
        guard normalizedTime.isFinite else { throw RigError.invalid("Animation normalized time must be finite.") }
        let motions = try motions(stateID: stateID, floatParameters: floatParameters)
        var poses: [RigPose] = []
        var rotatedOrScaled = Set<Int>(), changed = Set<Int>()
        let indices = Dictionary(uniqueKeysWithValues: rig.nodes.enumerated().map { ($0.element.sourceID, $0.offset) })
        for motion in motions {
            let clip = try clip(id: motion.clipID)
            var phase = normalizedTime + motion.cycleOffset
            phase = clip.loop ? phase - floor(phase) : min(max(phase, 0), 1)
            poses.append(try applying(clipID: clip.id, time: clip.startTime + phase * clip.duration,
                to: rig, baseline: baseline, allowingUnbound: allowingUnbound))
            for binding in clip.bindings {
                guard let id = binding.targetSourceID, let index = indices[id] else { continue }
                changed.insert(index)
                if binding.attribute != 1 { rotatedOrScaled.insert(index) }
            }
        }
        guard poses.count == 2 else { return poses[0] }
        var result = poses[0]
        let t = motions[1].weight
        for node in changed {
            let a = poses[0].localMatrices[node], b = poses[1].localMatrices[node]
            let translation = a.translation + (b.translation - a.translation) * t
            if !rotatedOrScaled.contains(node) { result.localMatrices[node].columns.3 = Float4(translation, 1); continue }
            let ac = try Self.decompose(a), bc = try Self.decompose(b)
            result.localMatrices[node] = Transform.trs(translation, simd_slerp(ac.0, bc.0, t), ac.1 + (bc.1 - ac.1) * t)
        }
        return result
    }

    private func parameterValue(_ name: String, values: [String: Float]) throws -> Float {
        guard let parameter = parameters.first(where: { $0.name == name && $0.type == "float" }),
              let value = values[name] ?? parameter.floatDefault, value.isFinite else {
            throw RigError.invalid("Missing finite float animator parameter '\(name)'.")
        }
        return value
    }

    /// Replace the authored channels, keeping baseline components for unanimated
    /// channels. Target source IDs are exact; names never guess a binding.
    public func applying(clipID: String, time: Float, looping: Bool = false, to rig: RigDefinition,
                         baseline: RigPose? = nil, allowingUnbound: Bool = false) throws -> RigPose {
        let clip = try clip(id: clipID)
        guard allowingUnbound || clip.unboundPathHashes.isEmpty else {
            throw RigError.invalid("Clip '\(clip.name)' has \(clip.unboundPathHashes.count) unbound source paths; partial playback must be explicit.")
        }
        let values = try clip.sample(time: time, looping: looping)
        let nodeIndices = Dictionary(uniqueKeysWithValues: rig.nodes.enumerated().map { ($0.element.sourceID, $0.offset) })
        var result = baseline ?? rig.restPose
        guard result.localMatrices.count == rig.nodes.count else { throw RigError.invalid("Animation baseline differs from rig size.") }
        var channels: [Int: [Int: [Float]]] = [:]
        for binding in clip.bindings {
            guard let target = binding.targetSourceID else { continue }
            guard let node = nodeIndices[target], rig.nodes[node].name == binding.targetName else {
                throw RigError.invalid("Animation target '\(target)' is missing or changed.")
            }
            channels[node, default: [:]][binding.attribute] = Array(values[binding.curveOffset..<(binding.curveOffset + binding.dimension)])
        }
        for (index, tracks) in channels {
            let matrix = result.localMatrices[index]
            var translation = matrix.translation
            if let value = tracks[1] { translation = UnityCoordinates.position(Float3(value[0], value[1], value[2])) }
            // A position-only channel preserves arbitrary valid baseline axes.
            if tracks[2] == nil && tracks[3] == nil {
                result.localMatrices[index].columns.3 = Float4(translation, 1)
                continue
            }
            let components = try Self.decompose(matrix)
            var rotation = components.0, scale = components.1
            if let value = tracks[2] {
                let q = Float4(value[0], value[1], value[2], value[3]), length = simd_length(q)
                guard length.isFinite, length > 1e-6 else { throw RigError.invalid("Animation generated a zero quaternion.") }
                rotation = UnityCoordinates.rotation(simd_quatf(vector: q / length))
            }
            if let value = tracks[3] { scale = Float3(value[0], value[1], value[2]) }
            result.localMatrices[index] = Transform.trs(translation, rotation, scale)
        }
        return result
    }

    private static func decompose(_ matrix: float4x4) throws -> (simd_quatf, Float3) {
        let a = matrix.columns.0, b = matrix.columns.1, c = matrix.columns.2
        let x = Float3(a.x, a.y, a.z), y = Float3(b.x, b.y, b.z), z = Float3(c.x, c.y, c.z)
        let scale = Float3(simd_length(x), simd_length(y), simd_length(z))
        guard (0..<3).allSatisfy({ scale[$0].isFinite && scale[$0] > 1e-8 }), simd_determinant(matrix) > 0,
              abs(simd_dot(x / scale.x, y / scale.y)) < 1e-4,
              abs(simd_dot(x / scale.x, z / scale.z)) < 1e-4,
              abs(simd_dot(y / scale.y, z / scale.z)) < 1e-4 else {
            throw RigError.invalid("Animation requires positive orthogonal baseline TRS; reflected/singular/sheared baselines are unsupported.")
        }
        return (simd_quatf(float3x3(columns: (x / scale.x, y / scale.y, z / scale.z))), scale)
    }

    private func validate() throws {
        guard schemaVersion == 1, converterVersion == "1.0.0", kind == "ikkoku-source-animation",
              coordinateSpace == "unity-left-handed-y-up", scope == "explicit-state-base-layer-generic-transforms",
              !clips.isEmpty, clips.count <= 1000, states.count <= 10000,
              Set(clips.map(\.id)).count == clips.count, Set(states.map(\.id)).count == states.count,
              Set(parameters.map(\.name)).count == parameters.count else { throw RigError.invalid("Unsupported source animation library.") }
        for hash in [source.bundleSHA256, source.rigSHA256] {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw RigError.invalid("Invalid animation source hash.") }
        }
        var sampleCount = 0
        for clip in clips {
            guard !clip.id.isEmpty, !clip.name.isEmpty, clip.startTime.isFinite, clip.stopTime.isFinite,
                  clip.startTime >= 0, clip.stopTime > clip.startTime, clip.sampleRate.isFinite, clip.sampleRate > 0,
                  !clip.curves.isEmpty, clip.curves.count <= 100000, clip.bindings.count <= 100000 else {
                throw RigError.invalid("Invalid source animation interval or dimensions.")
            }
            var offset = 0, identities = Set<String>(), targetIdentities = Set<String>(), unbound = Set<UInt32>()
            for binding in clip.bindings {
                guard (1...3).contains(binding.attribute), binding.curveOffset == offset,
                      identities.insert("\(binding.pathHash):\(binding.attribute)").inserted else {
                    throw RigError.invalid("Invalid, duplicate or discontinuous animation binding.")
                }
                offset += binding.dimension
                if let target = binding.targetSourceID {
                    guard !target.isEmpty, binding.sourcePath != nil, binding.targetName?.isEmpty == false,
                          targetIdentities.insert("\(target):\(binding.attribute)").inserted else {
                        throw RigError.invalid("Bound animation channel lacks its source identity.")
                    }
                } else {
                    guard binding.sourcePath == nil, binding.targetName == nil else { throw RigError.invalid("Partial animation target identity.") }
                    unbound.insert(binding.pathHash)
                }
            }
            guard offset == clip.curves.count, unbound == Set(clip.unboundPathHashes), unbound.count == clip.unboundPathHashes.count else {
                throw RigError.invalid("Animation binding dimensions or unbound-path report differ.")
            }
            for curve in clip.curves {
                switch curve.kind {
                case "constant":
                    guard curve.value?.isFinite == true, curve.keys == nil, curve.samples == nil else { throw RigError.invalid("Invalid constant animation curve.") }
                    sampleCount += 1
                case "dense":
                    guard let rate = curve.sampleRate, rate.isFinite, rate > 0, let begin = curve.beginTime, begin.isFinite, begin >= 0, begin <= clip.stopTime,
                          let samples = curve.samples, !samples.isEmpty, samples.allSatisfy(\.isFinite), curve.value == nil, curve.keys == nil else {
                        throw RigError.invalid("Invalid dense animation curve.")
                    }
                    sampleCount += samples.count
                case "streamed":
                    guard let keys = curve.keys, !keys.isEmpty, keys[0].time == clip.startTime, curve.value == nil, curve.samples == nil else {
                        throw RigError.invalid("Invalid streamed animation start.")
                    }
                    var previous = -Float.infinity
                    for key in keys {
                        guard key.time.isFinite, key.time > previous, key.coefficients.count == 4, key.coefficients.allSatisfy(\.isFinite) else {
                            throw RigError.invalid("Invalid streamed animation key.")
                        }
                        previous = key.time
                    }
                    sampleCount += keys.count * 4
                default: throw RigError.invalid("Unsupported animation curve encoding.")
                }
                guard sampleCount <= 8_000_000 else { throw RigError.invalid("Animation sample limit exceeded.") }
            }
        }
        for state in states {
            guard !state.id.isEmpty, state.speed.isFinite, state.speed >= 0, state.cycleOffset.isFinite,
                  !state.motions.isEmpty, state.motions.count <= 1000,
                  state.motions.count == 1 || state.blendParameter != nil else { throw RigError.invalid("Invalid projected animation state.") }
            var previous = -Float.infinity
            for motion in state.motions {
                _ = try clip(id: motion.clipID)
                guard motion.threshold.isFinite, motion.threshold > previous, motion.cycleOffset.isFinite else {
                    throw RigError.invalid("Invalid 1D animation thresholds or cycle offset.")
                }
                previous = motion.threshold
            }
            if let parameter = state.blendParameter { _ = try parameterValue(parameter, values: [:]) }
            if let parameter = state.speedParameter { _ = try parameterValue(parameter, values: [:]) }
        }
    }
}
