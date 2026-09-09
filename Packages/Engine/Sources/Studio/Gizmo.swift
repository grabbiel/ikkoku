import Foundation
import simd
import CoreMath
import Scene
import Renderer
import ShaderTypes

public enum GizmoMode: String, CaseIterable, Sendable { case translate, rotate, scale }
public enum GizmoAxis: Int, Sendable { case x = 1, y = 2, z = 3, xy = 4, yz = 5, xz = 6, all = 7 }

/// Object ids reserved for gizmo handles and bone handles in the pick pass.
public enum PickIDs {
    public static let gizmoBase: UInt32 = 0xFF00_0000
    public static let boneBase: UInt32  = 0xFE00_0000
    public static let ikBase: UInt32    = 0xFD00_0000
    public static let objectMask: UInt32 = 0x00FF_FFFF
    public static func gizmo(_ axis: GizmoAxis) -> UInt32 { gizmoBase | UInt32(axis.rawValue) }
    public static func axis(from id: UInt32) -> GizmoAxis? { (id & 0xFF00_0000) == gizmoBase ? GizmoAxis(rawValue: Int(id & 0xFF)) : nil }
    public static func bone(_ index: Int) -> UInt32 { boneBase | UInt32(index & 0xFFFF) }
    public static func boneIndex(from id: UInt32) -> Int? { (id & 0xFF00_0000) == boneBase ? Int(id & 0xFFFF) : nil }
    public static func ik(_ chain: Int) -> UInt32 { ikBase | UInt32(chain & 0xFF) }
    public static func ikIndex(from id: UInt32) -> Int? { (id & 0xFF00_0000) == ikBase ? Int(id & 0xFF) : nil }
}

/// Builds screen-constant gizmo geometry as `GizmoBatch`es with pickable ids.
public enum GizmoBuilder {
    static let colX = Float4(0.93, 0.28, 0.32, 1)
    static let colY = Float4(0.45, 0.85, 0.30, 1)
    static let colZ = Float4(0.30, 0.55, 0.95, 1)
    static let colHi = Float4(1.0, 0.9, 0.2, 1)
    static let colAll = Float4(0.9, 0.9, 0.9, 0.7)

    /// - Parameters: origin world, orientation (identity for world space), size in world units, highlighted axis.
    public static func build(mode: GizmoMode, origin: Float3, orientation: simd_quatf, size: Float, highlight: GizmoAxis?) -> [GizmoBatch] {
        var batches: [GizmoBatch] = []
        let axes: [(GizmoAxis, Float3, Float4)] = [(.x, Float3(1, 0, 0), colX), (.y, Float3(0, 1, 0), colY), (.z, Float3(0, 0, 1), colZ)]
        let m = Transform.trs(origin, orientation, Float3(repeating: size))
        switch mode {
        case .translate:
            for (axis, dir, col) in axes {
                let c = highlight == axis ? colHi : col
                var tri: [GizmoVertex] = []
                tri += tube(from: dir * 0.12, to: dir * 0.82, radius: 0.018, color: c)
                tri += cone(base: dir * 0.8, tip: dir * 1.05, radius: 0.06, color: c)
                batches.append(GizmoBatch(primitive: .triangles, vertices: tri, model: m, depthTest: false, objectID: PickIDs.gizmo(axis)))
            }
            // Plane handles
            let planes: [(GizmoAxis, Float3, Float3, Float4)] = [(.xy, Float3(1, 0, 0), Float3(0, 1, 0), colZ), (.yz, Float3(0, 1, 0), Float3(0, 0, 1), colX), (.xz, Float3(1, 0, 0), Float3(0, 0, 1), colY)]
            for (axis, a, b, col) in planes {
                var c = highlight == axis ? colHi : col
                c.w = 0.55
                let q = quad(a * 0.25 + b * 0.25, a * 0.45 + b * 0.25, a * 0.45 + b * 0.45, a * 0.25 + b * 0.45, color: c)
                batches.append(GizmoBatch(primitive: .triangles, vertices: q, model: m, depthTest: false, objectID: PickIDs.gizmo(axis)))
            }
        case .rotate:
            for (axis, dir, col) in axes {
                let c = highlight == axis ? colHi : col
                batches.append(GizmoBatch(primitive: .triangles, vertices: ring(axis: dir, radius: 0.9, thickness: 0.025, color: c), model: m, depthTest: false, objectID: PickIDs.gizmo(axis)))
            }
        case .scale:
            for (axis, dir, col) in axes {
                let c = highlight == axis ? colHi : col
                var tri: [GizmoVertex] = []
                tri += tube(from: dir * 0.12, to: dir * 0.85, radius: 0.018, color: c)
                tri += cube(center: dir * 0.92, half: 0.07, color: c)
                batches.append(GizmoBatch(primitive: .triangles, vertices: tri, model: m, depthTest: false, objectID: PickIDs.gizmo(axis)))
            }
            batches.append(GizmoBatch(primitive: .triangles, vertices: cube(center: .zero, half: 0.09, color: highlight == .all ? colHi : colAll), model: m, depthTest: false, objectID: PickIDs.gizmo(.all)))
        }
        return batches
    }

    /// Small octahedron handle (bones / IK targets).
    public static func handle(at p: Float3, size: Float, color: Float4, id: UInt32) -> GizmoBatch {
        GizmoBatch(primitive: .triangles, vertices: octahedron(center: .zero, radius: 1, color: color), model: Transform.trs(p, .identity, Float3(repeating: size)), depthTest: false, objectID: id)
    }

    public static func lines(_ segments: [(Float3, Float3)], color: Float4, depthTest: Bool = false) -> GizmoBatch {
        var v: [GizmoVertex] = []
        for (a, b) in segments { v.append(GizmoVertex(position: a, color: color)); v.append(GizmoVertex(position: b, color: color)) }
        return GizmoBatch(primitive: .lines, vertices: v, depthTest: depthTest)
    }

    // MARK: primitives (unit space)

    static func basis(_ dir: Float3) -> (Float3, Float3) {
        let d = normalize(dir)
        let helper = abs(d.y) < 0.9 ? Float3(0, 1, 0) : Float3(1, 0, 0)
        let u = normalize(cross(helper, d))
        let v = cross(d, u)
        return (u, v)
    }

    static func tube(from a: Float3, to b: Float3, radius: Float, color: Float4, segments: Int = 10) -> [GizmoVertex] {
        let (u, v) = basis(b - a)
        var out: [GizmoVertex] = []
        for i in 0..<segments {
            let t0 = Float(i) / Float(segments) * 2 * .pi, t1 = Float(i + 1) / Float(segments) * 2 * .pi
            let o0 = (u * cos(t0) + v * sin(t0)) * radius, o1 = (u * cos(t1) + v * sin(t1)) * radius
            out += [GizmoVertex(position: a + o0, color: color), GizmoVertex(position: b + o0, color: color), GizmoVertex(position: b + o1, color: color),
                    GizmoVertex(position: a + o0, color: color), GizmoVertex(position: b + o1, color: color), GizmoVertex(position: a + o1, color: color)]
        }
        return out
    }

    static func cone(base: Float3, tip: Float3, radius: Float, color: Float4, segments: Int = 14) -> [GizmoVertex] {
        let (u, v) = basis(tip - base)
        var out: [GizmoVertex] = []
        for i in 0..<segments {
            let t0 = Float(i) / Float(segments) * 2 * .pi, t1 = Float(i + 1) / Float(segments) * 2 * .pi
            let p0 = base + (u * cos(t0) + v * sin(t0)) * radius, p1 = base + (u * cos(t1) + v * sin(t1)) * radius
            out += [GizmoVertex(position: p0, color: color), GizmoVertex(position: p1, color: color), GizmoVertex(position: tip, color: color)]
            out += [GizmoVertex(position: p1, color: color), GizmoVertex(position: p0, color: color), GizmoVertex(position: base, color: color)]
        }
        return out
    }

    static func ring(axis: Float3, radius: Float, thickness: Float, color: Float4, segments: Int = 48) -> [GizmoVertex] {
        let (u, v) = basis(axis)
        var out: [GizmoVertex] = []
        let ri = radius - thickness, ro = radius + thickness
        for i in 0..<segments {
            let t0 = Float(i) / Float(segments) * 2 * .pi, t1 = Float(i + 1) / Float(segments) * 2 * .pi
            let d0 = u * cos(t0) + v * sin(t0), d1 = u * cos(t1) + v * sin(t1)
            let a = d0 * ri, b = d0 * ro, c = d1 * ro, d = d1 * ri
            out += [GizmoVertex(position: a, color: color), GizmoVertex(position: b, color: color), GizmoVertex(position: c, color: color),
                    GizmoVertex(position: a, color: color), GizmoVertex(position: c, color: color), GizmoVertex(position: d, color: color)]
            // back faces so it is visible from both sides
            out += [GizmoVertex(position: c, color: color), GizmoVertex(position: b, color: color), GizmoVertex(position: a, color: color),
                    GizmoVertex(position: d, color: color), GizmoVertex(position: c, color: color), GizmoVertex(position: a, color: color)]
        }
        return out
    }

    static func quad(_ a: Float3, _ b: Float3, _ c: Float3, _ d: Float3, color: Float4) -> [GizmoVertex] {
        [GizmoVertex(position: a, color: color), GizmoVertex(position: b, color: color), GizmoVertex(position: c, color: color),
         GizmoVertex(position: a, color: color), GizmoVertex(position: c, color: color), GizmoVertex(position: d, color: color),
         GizmoVertex(position: c, color: color), GizmoVertex(position: b, color: color), GizmoVertex(position: a, color: color),
         GizmoVertex(position: d, color: color), GizmoVertex(position: c, color: color), GizmoVertex(position: a, color: color)]
    }

    static func cube(center: Float3, half: Float, color: Float4) -> [GizmoVertex] {
        var out: [GizmoVertex] = []
        let h = half
        let faces: [(Float3, Float3, Float3)] = [(Float3(1, 0, 0), Float3(0, 1, 0), Float3(0, 0, 1)), (Float3(-1, 0, 0), Float3(0, 0, 1), Float3(0, 1, 0)),
                                                 (Float3(0, 1, 0), Float3(0, 0, 1), Float3(1, 0, 0)), (Float3(0, -1, 0), Float3(1, 0, 0), Float3(0, 0, 1)),
                                                 (Float3(0, 0, 1), Float3(1, 0, 0), Float3(0, 1, 0)), (Float3(0, 0, -1), Float3(0, 1, 0), Float3(1, 0, 0))]
        for (n, u, v) in faces {
            let c = center + n * h
            out += quad(c - u * h - v * h, c + u * h - v * h, c + u * h + v * h, c - u * h + v * h, color: color)
        }
        return out
    }

    static func octahedron(center: Float3, radius: Float, color: Float4) -> [GizmoVertex] {
        let px = center + Float3(radius, 0, 0), nx = center - Float3(radius, 0, 0)
        let py = center + Float3(0, radius, 0), ny = center - Float3(0, radius, 0)
        let pz = center + Float3(0, 0, radius), nz = center - Float3(0, 0, radius)
        let tris: [(Float3, Float3, Float3)] = [(py, px, pz), (py, pz, nx), (py, nx, nz), (py, nz, px), (ny, pz, px), (ny, nx, pz), (ny, nz, nx), (ny, px, nz)]
        var out: [GizmoVertex] = []
        for (a, b, c) in tris { out += [GizmoVertex(position: a, color: color), GizmoVertex(position: b, color: color), GizmoVertex(position: c, color: color)] }
        return out
    }
}

/// Drag math for gizmo interaction: all in world space.
public struct GizmoDrag: Sendable {
    public let mode: GizmoMode
    public let axis: GizmoAxis
    public let origin: Float3
    public let orientation: simd_quatf
    public let startRay: Ray
    private let planeNormal: Float3
    private let startHit: Float3
    private let axisDir: Float3

    public init?(mode: GizmoMode, axis: GizmoAxis, origin: Float3, orientation: simd_quatf, ray: Ray, cameraForward: Float3) {
        self.mode = mode; self.axis = axis; self.origin = origin; self.orientation = orientation; self.startRay = ray
        let ax = orientation.act(Float3(1, 0, 0)), ay = orientation.act(Float3(0, 1, 0)), az = orientation.act(Float3(0, 0, 1))
        switch axis {
        case .x: axisDir = ax
        case .y: axisDir = ay
        case .z: axisDir = az
        case .xy: axisDir = az
        case .yz: axisDir = ax
        case .xz: axisDir = ay
        case .all: axisDir = -cameraForward
        }
        if mode == .rotate || axis == .xy || axis == .yz || axis == .xz || axis == .all {
            planeNormal = axisDir
        } else {
            // Plane containing the axis and facing the camera as much as possible.
            let n = cameraForward - axisDir * dot(cameraForward, axisDir)
            planeNormal = length_squared(n) > 1e-6 ? normalize(n) : normalize(cross(axisDir, Float3(0, 1, 0)))
        }
        guard let t = ray.intersectPlane(point: origin, normal: planeNormal) ?? ray.intersectPlane(point: origin, normal: -planeNormal) else { return nil }
        startHit = ray.point(at: t)
    }

    private func hit(_ ray: Ray) -> Float3? {
        guard let t = ray.intersectPlane(point: origin, normal: planeNormal) ?? ray.intersectPlane(point: origin, normal: -planeNormal) else { return nil }
        return ray.point(at: t)
    }

    /// Translation delta since the drag started.
    public func translation(for ray: Ray) -> Float3? {
        guard let h = hit(ray) else { return nil }
        let d = h - startHit
        switch axis {
        case .x, .y, .z: return axisDir * dot(d, axisDir)
        default: return d - planeNormal * dot(d, planeNormal)
        }
    }

    /// Rotation delta (world) since the drag started, about the gizmo axis.
    public func rotation(for ray: Ray) -> simd_quatf? {
        guard let h = hit(ray) else { return nil }
        let a = startHit - origin, b = h - origin
        if length_squared(a) < 1e-8 || length_squared(b) < 1e-8 { return nil }
        let an = normalize(a), bn = normalize(b)
        let angle = atan2(dot(cross(an, bn), planeNormal), dot(an, bn))
        return simd_quatf(angle: angle, axis: planeNormal)
    }

    /// Scale factor since the drag started (per axis; uniform for `.all`).
    public func scale(for ray: Ray, size: Float) -> Float3? {
        guard let h = hit(ray) else { return nil }
        let d = h - startHit
        let amount: Float
        switch axis {
        case .x, .y, .z: amount = dot(d, axisDir) / max(size, 1e-4)
        default: amount = (length(h - origin) - length(startHit - origin)) / max(size, 1e-4)
        }
        let f = max(0.05, 1 + amount)
        switch axis {
        case .x: return Float3(f, 1, 1)
        case .y: return Float3(1, f, 1)
        case .z: return Float3(1, 1, f)
        default: return Float3(repeating: f)
        }
    }
}
