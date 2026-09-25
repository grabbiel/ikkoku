import Foundation
import Darwin

/// Synchronous offscreen rendering: excludes asset import, simulation and PNG
/// readback. GPU timings come from completed Metal command buffers, not FPS.
public struct RenderBenchmark: Encodable, Sendable {
    public struct Distribution: Encodable, Sendable {
        public let p50: Double, p95: Double, minimum: Double, maximum: Double
        init(_ values: [Double]) {
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)] }
            p50 = percentile(0.5); p95 = percentile(0.95)
            minimum = sorted.first!; maximum = sorted.last!
        }
    }
    public let schemaVersion = 1
    public let mode = "synchronous-offscreen-reused-targets-no-readback"
    public let device: String, width: Int, height: Int, warmupFrames: Int, measuredFrames: Int
    public let cpuEncodeMilliseconds: Distribution, completionMilliseconds: Distribution
    public let gpuMilliseconds: Distribution?
    public let residentBytesBefore: UInt64?, residentBytesAfter: UInt64?, metalAllocatedBytes: Int
    public let visibleItems: Int, missingMeshes: Int, drawnTriangles: Int, uniqueVertices: Int
    public let resources: ResourceStore.Statistics

    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}

public enum RenderBenchmarkError: Error { case invalidConfiguration, commandBuffer, deformation([String]), gpu(String) }
