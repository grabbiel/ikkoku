//
//  FrameRing.swift
//  Engine
//
//  Created by rumpology on 8/19/26.
//
import Metal

/// One shared-storage buffer partitioned into per-frame regions.
/// Write uniforms with `allocate`, bind with the returned offset.
public final class FrameRing {
    public static let alignment = 256

    public let buffer: any MTLBuffer
    private let regionSize: Int
    private let regionCount: Int
    private var regionIndex = 0
    private var cursor = 0

    public init?(device: any MTLDevice,
                 regionSize: Int = 64 * 1024,
                 regionCount: Int = GPUContext.maxFramesInFlight) {
        let aligned = FrameRing.align(regionSize)
        guard let buffer = device.makeBuffer(length: aligned * regionCount,
                                             options: .storageModeShared) else { return nil }
        buffer.label = "FrameRing"
        self.buffer = buffer
        self.regionSize = aligned
        self.regionCount = regionCount
    }

    /// Call once per frame, before any allocation.
    public func beginFrame(_ frameIndex: Int) {
        regionIndex = frameIndex % regionCount
        cursor = 0
    }

    /// Copies `value` into the current region. Returns its byte offset.
    public func allocate<T>(_ value: T) -> Int {
        let size = MemoryLayout<T>.stride
        precondition(cursor + size <= regionSize, "FrameRing region exhausted")
        let offset = regionIndex * regionSize + cursor
        buffer.contents().storeBytes(of: value, toByteOffset: offset, as: T.self)
        cursor += FrameRing.align(size)
        return offset
    }

    private static func align(_ n: Int) -> Int {
        (n + alignment - 1) & ~(alignment - 1)
    }
}
