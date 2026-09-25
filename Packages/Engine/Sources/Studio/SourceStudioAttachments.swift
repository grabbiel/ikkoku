import Foundation
import Scene
import CoreMath
import simd

/// Source accessory-point table maps stable Studio integers to ChaReference
/// transform names. No heuristic mapping to humanoid joint names is used.
public struct SourceStudioAttachments: Decodable, Sendable {
    public struct Point: Decodable, Sendable { public let id: Int32, nodeName: String }
    public let schemaVersion: Int, points: [Point]

    public static func load(url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw RigError.invalid("Studio attachment catalog exceeds 1 MiB.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1, result.points.count <= 1024,
              Set(result.points.map(\.id)).count == result.points.count,
              result.points.allSatisfy({ !$0.nodeName.isEmpty && $0.nodeName.utf8.count <= 256 && $0.nodeName.utf8.allSatisfy { $0 < 128 } }) else {
            throw RigError.invalid("Invalid source Studio attachment catalog.")
        }
        return result
    }

    public func matrix(pointID: Int32, rig: RigDefinition, pose: RigPose) throws -> float4x4 {
        guard let point = points.first(where: { $0.id == pointID }) else { throw RigError.invalid("Unknown Studio attachment point \(pointID).") }
        let node = try rig.uniqueNode(named: point.nodeName)
        return try rig.evaluate(pose).worldMatrices[node]
    }
}
