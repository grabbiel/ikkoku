import Foundation
import simd
import CoreMath
import Assets

/// Which body vertices are covered by a garment, computed from rest-pose geometry (both are skinned to the
/// same skeleton, so rest space is shared). A body vertex is hidden when it lies just behind a garment
/// surface with a similar normal and away from the garment's open edges (necklines, hems, cuffs).
public enum BodyCoverage {

    public struct Garment {
        public let positions: [Float3]
        public let normals: [Float3]
        public let boundary: [Float3]     // vertices on open edges
        public init(mesh: MeshData) {
            positions = mesh.positions
            normals = mesh.normals
            // Open edges = edges used by exactly one triangle.
            var count: [UInt64: Int] = [:]
            var i = 0
            let idx = mesh.indices
            func key(_ a: UInt32, _ b: UInt32) -> UInt64 { a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a)) }
            while i + 2 < idx.count {
                count[key(idx[i], idx[i+1]), default: 0] += 1
                count[key(idx[i+1], idx[i+2]), default: 0] += 1
                count[key(idx[i+2], idx[i]), default: 0] += 1
                i += 3
            }
            var bset = Set<UInt32>()
            for (k, c) in count where c == 1 { bset.insert(UInt32(k >> 32)); bset.insert(UInt32(k & 0xFFFF_FFFF)) }
            boundary = bset.map { mesh.positions[Int($0)] }
        }
    }

    /// Uniform grid over points for radius queries.
    struct Grid {
        let cell: Float
        var map: [SIMD3<Int32>: [Int]] = [:]
        init(points: [Float3], cell: Float) {
            self.cell = cell
            for (i, p) in points.enumerated() { map[Grid.key(p, cell), default: []].append(i) }
        }
        static func key(_ p: Float3, _ cell: Float) -> SIMD3<Int32> { SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down))) }
        func neighbors(_ p: Float3) -> [Int] {
            let k = Grid.key(p, cell)
            var out: [Int] = []
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                if let l = map[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] { out += l }
            } } }
            return out
        }
    }

    /// Returns one byte per body vertex (1 = hidden).
    public static func hiddenVertices(body: MeshData, garments: [Garment], radius: Float = 0.03, maxBehind: Float = 0.018,
                                      openingMargin: Float = 0.032, normalAgreement: Float = 0.3) -> [UInt8] {
        var hidden = [UInt8](repeating: 0, count: body.vertexCount)
        for g in garments {
            guard !g.positions.isEmpty else { continue }
            let grid = Grid(points: g.positions, cell: radius)
            let bgrid = Grid(points: g.boundary, cell: openingMargin)
            let r2 = radius * radius, m2 = openingMargin * openingMargin
            for i in 0..<body.vertexCount where hidden[i] == 0 {
                let p = body.positions[i]
                let n = body.normals[i]
                var covered = false
                for j in grid.neighbors(p) {
                    let q = g.positions[j]
                    let d = p - q
                    if length_squared(d) > r2 { continue }
                    let gn = g.normals[j]
                    if dot(gn, n) < normalAgreement { continue }
                    let behind = -dot(d, gn)           // > 0 when the body point is under the garment surface
                    if behind > -0.003 && behind < maxBehind { covered = true; break }
                }
                if !covered { continue }
                var nearOpening = false
                for j in bgrid.neighbors(p) where length_squared(p - g.boundary[j]) < m2 { nearOpening = true; break }
                if !nearOpening { hidden[i] = 1 }
            }
        }
        return hidden
    }
}
