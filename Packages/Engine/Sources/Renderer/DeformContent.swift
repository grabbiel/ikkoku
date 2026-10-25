import Foundation
import Metal
import simd
import ShaderTypes

/// The inputs of one deform dispatch (`Shaders/Deform.metal`, R7 phase 2,
/// item 4). The kernel is a pure function of them and writes every field of
/// each of the mesh's vertices, so two dispatches with matching inputs write
/// byte-identical vertices into their buffer, whatever it held before.
///
/// What the kernel reads:
/// - from the mesh: the base vertices, the skin data, the morph position and
///   normal deltas and the vertex count. A registered mesh's buffers are never
///   written after `ResourceStore.register(mesh:)`, so the mesh's identity
///   stands for all of them;
/// - the bound skin palette (its matrices and count; nil without skin);
/// - the meaningful morph entries (`Renderer.activeMorphEntries`), in order.
///
/// Matrices and entries compare by bit pattern: they hold no padding, and an
/// entry's weight is finite and nonzero. The mesh is held strongly, so while
/// a record names it, no other mesh can take its address.
struct DeformContent {
    let mesh: GPUMesh
    let palette: [float4x4]?
    let morphs: [MorphWeightEntry]

    func matches(_ o: DeformContent) -> Bool {
        guard mesh === o.mesh, (palette == nil) == (o.palette == nil), Self.sameBits(morphs, o.morphs) else { return false }
        guard let palette, let other = o.palette else { return true }
        return Self.sameBits(palette, other)
    }

    /// Element bytes of two arrays of padding-free values. Arrays that share
    /// storage (an unchanged skin set handed on from frame to frame) are equal
    /// without a scan.
    static func sameBits<T: BitwiseCopyable>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        guard !a.isEmpty else { return true }
        return a.withUnsafeBytes { x in
            b.withUnsafeBytes { y in x.baseAddress == y.baseAddress || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 }
        }
    }
}

/// What one deformation key's buffer holds after the last committed command
/// buffer that wrote it: that buffer, the content the dispatch was encoded
/// from, and the write that recorded it (`Renderer.deformContent`). The
/// buffer is held strongly, so it cannot be freed and another buffer take its
/// address while the record names it. The renderer drops the records of keys
/// that the frame it prepares does not use, which releases a removed
/// character's buffers with its first frame.
final class DeformBufferRecord {
    let buffer: any MTLBuffer
    let content: DeformContent
    let serial: UInt64
    init(buffer: any MTLBuffer, content: DeformContent, serial: UInt64) {
        self.buffer = buffer; self.content = content; self.serial = serial
    }
}

/// One deform dispatch encoded into a command buffer that has not been
/// committed yet; recorded once it is (`Renderer.commit(_:writes:)`).
struct DeformWrite {
    let key: UInt64
    let buffer: any MTLBuffer
    let content: DeformContent
}

/// Whether a frame's preparation may skip deform dispatches whose buffers
/// already hold the frame's vertices.
enum DeformMode {
    /// Dispatch every deformation, as before R7 phase 2, item 4: captures,
    /// benchmarks and live validation captures, the byte-identity references.
    case always
    /// Skip a dispatch when its buffer's committed content matches
    /// (interactive draws and picks).
    case reuse
}
