import Foundation
import simd
import CoreMath
import Scene

/// The saved Studio hand patterns 1–21 of both hand controllers
/// (`Tools/reverse/studio_hand_animation.py --all-patterns` writes the JSON).
/// Each pattern is one looping clip whose native frames were converted at the
/// clip's own sample rate; pattern 0 disables the hand Animator and has no
/// entry. `pose(hand:pattern:elapsed:)` wraps the Studio clock into the clip,
/// interpolates between adjacent frames per component and normalizes the
/// quaternion; `apply` then replaces only the animated channels, following the
/// channel rule shared with `SourceStudioHandPose`.
public struct SourceStudioHandPatterns: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public let bundleSHA256: String, bundle: String, infoBundleSHA256: String, infoBundle: String
    }

    public struct Clip: Decodable, Sendable {
        public let startTime: Float, stopTime: Float, sampleRate: Float, loop: Bool
    }

    /// Per-channel values at each native frame time; `frames` carries the
    /// rotation and `position`/`scale` are recorded only when the clip animates them.
    public struct Bone: Decodable, Sendable {
        public let frames: [[Float]], position: [[Float]]?, scale: [[Float]]?
    }

    public struct Pattern: Decodable, Sendable {
        public let id: Int, name: String, state: String, clip: Clip, frameTimes: [Float], bones: [String: Bone]
    }

    public struct Hand: Decodable, Sendable {
        public let patterns: [Pattern]
    }

    public enum Evaluation: Sendable {
        /// The Animator is disabled (pattern 0) and the incoming pose stays untouched.
        case noChange
        /// The saved pattern has no converted clip; the second value explains why.
        case unknown(diagnostic: String)
        /// Channels sampled from the looping clip at the requested clock time.
        case channels([String: SourceStudioHandPose.Bone])
    }

    public let schemaVersion: Int, converterVersion: String, kind: String
    public let coordinateSpace: String, scope: String
    public let source: Source, hands: [String: Hand], diagnostics: [String]

    public static func load(url: URL) throws -> Self {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0, size <= 64 * 1024 * 1024 else {
            throw RigError.invalid("Studio hand pattern library must be a regular file of 1 byte through 64 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return try decode(try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data())
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else {
            throw RigError.invalid("Studio hand pattern library exceeds size limits.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    private func validate() throws {
        guard schemaVersion == 1, converterVersion == "1.0.0", kind == "ikkoku-studio-hand-patterns",
              coordinateSpace == "unity-left-handed-y-up", scope == "hand-anime-table-states-generic-transforms",
              Set(hands.keys).isSubset(of: ["L", "R"]), hands.count == 2 else {
            throw RigError.invalid("Unsupported studio hand pattern library.")
        }
        for hash in [source.bundleSHA256, source.infoBundleSHA256] {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                throw RigError.invalid("Studio hand pattern library needs both source bundle hashes.")
            }
        }
        for (hand, entry) in hands {
            let ids = entry.patterns.map { $0.id }
            guard !ids.isEmpty, ids.count <= 64, Set(ids).count == ids.count,
                  ids.sorted() == Array(1...ids.count) else {
                throw RigError.invalid("\(hand) hand pattern IDs must be unique and run from 1 without gaps.")
            }
            for pattern in entry.patterns {
                guard !pattern.name.isEmpty, !pattern.state.isEmpty, pattern.bones.count <= 64,
                      pattern.clip.loop, pattern.clip.startTime == 0, pattern.clip.stopTime > 0,
                      pattern.clip.sampleRate > 0, !pattern.frameTimes.isEmpty,
                      pattern.frameTimes.count <= 1024 else {
                    throw RigError.invalid("Studio hand pattern \(pattern.id) is outside the converted limits.")
                }
                guard pattern.bones.values.allSatisfy({ $0.frames.count == pattern.frameTimes.count
                          && ($0.position ?? $0.frames).count == pattern.frameTimes.count
                          && ($0.scale ?? $0.frames).count == pattern.frameTimes.count }) else {
                    throw RigError.invalid("Studio hand pattern \(pattern.id) channels disagree with its frame times.")
                }
                guard pattern.bones.values.allSatisfy({ bone in
                    bone.frames.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) && simd_length(Float4($0[0], $0[1], $0[2], $0[3])) > 0 })
                        && (bone.position ?? []).allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
                        && (bone.scale ?? []).allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
                }) else {
                    throw RigError.invalid("Studio hand pattern \(pattern.id) needs finite channel frames.")
                }
                if pattern.frameTimes.count > 1 {
                    let step = pattern.frameTimes[1] - pattern.frameTimes[0]
                    guard pattern.frameTimes.first == pattern.clip.startTime, step > 0,
                          abs(1 / step - pattern.clip.sampleRate) <= 0.01 * pattern.clip.sampleRate,
                          zip(pattern.frameTimes.dropFirst(), pattern.frameTimes).allSatisfy({ $0 - $1 > 0 }) else {
                        throw RigError.invalid("Studio hand pattern \(pattern.id) frame times are not one uniform dense grid.")
                    }
                }
            }
        }
    }

    /// Sample one hand's saved pattern at a Studio clock instant. Pattern 0 is
    /// `noChange`; an ID the library never converted is reported as a
    /// diagnostic instead of being guessed; anything else becomes the channel
    /// values the clip holds at the wrapped loop phase.
    public func pose(hand: String, pattern: Int, elapsed: Float) throws -> Evaluation {
        guard let entry = hands[hand] else { throw RigError.invalid("Studio hand patterns have no \(hand) hand.") }
        guard elapsed.isFinite else { throw RigError.invalid("Studio hand pattern clock time must be finite.") }
        guard pattern != 0 else { return .noChange }
        guard let converted = entry.patterns.first(where: { $0.id == pattern }) else {
            return .unknown(diagnostic: "Saved \(hand) hand pattern \(pattern) has no converted clip in \(source.infoBundle); the hand pose is left unchanged.")
        }
        let duration = converted.clip.stopTime - converted.clip.startTime
        let wrapped = elapsed - duration * (elapsed / duration).rounded(.down)
        var bones: [String: SourceStudioHandPose.Bone] = [:]
        for (name, bone) in converted.bones {
            let rotation = sample(bone.frames, times: converted.frameTimes, rate: converted.clip.sampleRate, at: wrapped)
            guard rotation.allSatisfy(\.isFinite), simd_length(Float4(rotation[0], rotation[1], rotation[2], rotation[3])) > 0 else {
                throw RigError.invalid("Studio hand pattern \(converted.id) interpolation left \(name) without a rotation.")
            }
            bones[name] = SourceStudioHandPose.Bone(
                position: bone.position.map({ sample($0, times: converted.frameTimes, rate: converted.clip.sampleRate, at: wrapped) }),
                rotation: normalized(Float4(rotation[0], rotation[1], rotation[2], rotation[3])).map({ [$0.x, $0.y, $0.z, $0.w] }),
                scale: bone.scale.map({ sample($0, times: converted.frameTimes, rate: converted.clip.sampleRate, at: wrapped) }))
        }
        return .channels(bones)
    }

    /// Apply one hand's evaluated pattern to a working pose. Returns a
    /// diagnostic when the pattern is unknown; pattern 0 changes nothing.
    @discardableResult
    public func apply(_ evaluation: Evaluation, to rig: RigDefinition, on pose: inout RigPose) throws -> String? {
        switch evaluation {
        case .noChange: return nil
        case let .unknown(diagnostic): return diagnostic
        case let .channels(bones):
            for (name, value) in bones {
                try SourceStudioHandPose.applyChannels(value, at: try rig.uniqueNode(named: name), to: &pose)
            }
            return nil
        }
    }

    /// Apply both saved Studio hand patterns (saved order `[L, R]`, matching
    /// `KoikatsuCharacterRecord.handPatterns`) to a pose that already carries
    /// the body animation. The Studio hand Animator runs at speed 1 regardless
    /// of the body animation speed, so the raw Studio clock drives each loop.
    /// A saved pattern without a converted clip leaves its hand untouched and
    /// explains itself in the returned diagnostics.
    @discardableResult
    public func applySaved(_ saved: [Int32], to rig: RigDefinition, on pose: inout RigPose, elapsed: Float) throws -> [String] {
        guard saved.count == 2 else {
            return ["Saved Studio hand patterns must hold one left and one right entry."]
        }
        var diagnostics: [String] = []
        for (index, hand) in ["L", "R"].enumerated() {
            if let diagnostic = try apply(try self.pose(hand: hand, pattern: Int(saved[index]), elapsed: elapsed), to: rig, on: &pose) {
                diagnostics.append(diagnostic)
            }
        }
        return diagnostics
    }

    /// Componentwise dense sampling between adjacent native frames, matching
    /// the converter's own curve sampler so both agree on loop-phase values.
    private func sample(_ frames: [[Float]], times: [Float], rate: Float, at time: Float) -> [Float] {
        guard times.count > 1 else { return frames[0] }
        let position = min(max((time - times[0]) * rate, 0), Float(frames.count - 1))
        let lower = Int(position), upper = min(lower + 1, frames.count - 1), fraction = position - Float(lower)
        return zip(frames[lower], frames[upper]).map { $0.0 * (1 - fraction) + $0.1 * fraction }
    }

    private func normalized(_ value: Float4) -> Float4? {
        let length = simd_length(value)
        guard length > 0, length.isFinite else { return nil }
        return Float4(value.x / length, value.y / length, value.z / length, value.w / length)
    }
}
