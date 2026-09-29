import Foundation
import simd
import CoreMath
import Scene

/// The default `goo` state of both studio hand controllers, frozen at one
/// sampled clip time (`Tools/reverse/studio_hand_animation.py` writes the
/// JSON). Bindings resolve against `cf_s_hand_L`/`cf_s_hand_R`, so applying
/// the pose replaces only channels recorded for each hand bone. Unanimated
/// channels retain their values from the incoming pose.
public struct SourceStudioHandPose: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public let bundleSHA256: String, bundle: String
    }

    public struct Clip: Decodable, Sendable {
        public let id: String, name: String
        public let loop: Bool, startTime: Float, stopTime: Float
    }

    public struct SampleTime: Decodable, Sendable {
        public let requested: Float, clipTime: Float
    }

    public struct Bone: Decodable, Sendable {
        public let position: [Float]?, rotation: [Float]?, scale: [Float]?
    }

    public struct Hand: Decodable, Sendable {
        public let state: String, stateIndex: Int
        public let clip: Clip, sampleTime: SampleTime, bones: [String: Bone]
    }

    public let schemaVersion: Int, converterVersion: String, kind: String
    public let coordinateSpace: String, scope: String
    public let source: Source, hands: [String: Hand], diagnostics: [String]

    public static func load(url: URL) throws -> Self {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0, size <= 64 * 1024 * 1024 else {
            throw RigError.invalid("Studio hand pose must be a regular file of 1 byte through 64 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return try decode(try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data())
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else {
            throw RigError.invalid("Studio hand pose exceeds size limits.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    private func validate() throws {
        guard schemaVersion == 1, converterVersion == "1.0.0", kind == "ikkoku-studio-hands",
              coordinateSpace == "unity-left-handed-y-up", scope == "default-state-single-clip-generic-transforms",
              Set(hands.keys).isSubset(of: ["L", "R"]), !hands.isEmpty else {
            throw RigError.invalid("Unsupported studio hand pose document.")
        }
        guard source.bundleSHA256.count == 64, source.bundleSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw RigError.invalid("Studio hand pose needs a source bundle hash.")
        }
        for hand in hands.values {
            guard !hand.state.isEmpty, !hand.bones.isEmpty, hand.bones.count <= 64,
                  !hand.clip.id.isEmpty, !hand.clip.name.isEmpty, hand.clip.loop,
                  hand.clip.startTime == 0, hand.sampleTime.requested.isFinite,
                  hand.sampleTime.clipTime >= hand.clip.startTime,
                  hand.sampleTime.clipTime < hand.clip.stopTime else {
                throw RigError.invalid("Studio hand pose needs a looping clip sampled inside its interval.")
            }
            for bone in hand.bones.values {
                if let rotation = bone.rotation, rotation.count != 4 || !rotation.allSatisfy(\.isFinite) {
                    throw RigError.invalid("Studio hand rotation must be four finite components.")
                }
                if let position = bone.position, position.count != 3 || !position.allSatisfy(\.isFinite) {
                    throw RigError.invalid("Studio hand position must be three finite components.")
                }
                if let scale = bone.scale, scale.count != 3 || !scale.allSatisfy(\.isFinite) {
                    throw RigError.invalid("Studio hand scale must be three finite components.")
                }
            }
        }
    }

    /// Apply each named bone's recorded local channels at the frozen clip time.
    /// Unanimated channels keep their incoming pose values, including card shaping.
    public func applying(to rig: RigDefinition, basePose: RigPose? = nil) throws -> RigPose {
        var result = basePose ?? rig.restPose
        for hand in hands.values {
            for (bone, value) in hand.bones {
                try Self.applyChannels(value, at: try rig.uniqueNode(named: bone), to: &result)
            }
        }
        return result
    }

    /// Replace only the channels one record carries on an already-resolved node.
    /// Shared with `SourceStudioHandPatterns` so sampled pattern frames follow
    /// the same channel rule as the frozen default pose.
    static func applyChannels(_ value: Bone, at node: Int, to result: inout RigPose) throws {
        let baseline = try SourceShapePoseBaseline.components(result.localMatrices[node])
        var translation = baseline.position
        if let position = value.position {
            translation = UnityCoordinates.position(Float3(position[0], position[1], position[2]))
        }
        var rotation = baseline.rotation
        if let quaternion = value.rotation {
            let q = Float4(quaternion[0], quaternion[1], quaternion[2], quaternion[3])
            rotation = UnityCoordinates.rotation(simd_quatf(vector: q))
        }
        var scale = baseline.scale
        if let scaling = value.scale {
            scale = Float3(scaling[0], scaling[1], scaling[2])
        }
        result.localMatrices[node] = Transform.trs(translation, rotation, scale)
    }
}
