import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Renderer

/// Straight-alpha RGBA8 PNG bytes of `TextureIdentityCases.plain`.
private func patternPNG(width: Int, height: Int) throws -> Data {
    let image = try #require(TextureIdentityCases.plain(bpc: 8, components: 4, alpha: .last, order: [], float: false, width: width, height: height))
    return try #require(TextureIdentityCases.encode(image, as: "public.png"))
}

/// The texture upload path that replaced `MTKTextureLoader`: one upload queue
/// per device shared by every store, each upload complete before its texture
/// is handed out, and loads that need no worker thread from any pool.
@Suite struct ResourceStoreUploadTests {
    @Test("The upload queue registry gives every thread the same queue for a device")
    func uploadQueueRegistryIsOneQueuePerDeviceFromManyThreads() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let registry = UploadQueues()
        let identities = await onOwnThread { () -> [ObjectIdentifier] in
            let lock = NSLock()
            var identities: [ObjectIdentifier] = []
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                let queue = registry.queue(for: device)
                lock.lock(); identities.append(ObjectIdentifier(queue)); lock.unlock()
            }
            return identities
        }
        #expect(identities.count == 64)
        #expect(Set(identities).count == 1)
        let first = ResourceStore(device: device), second = ResourceStore(device: device)
        #expect(first.uploadQueue === second.uploadQueue)
        #expect(first.uploadQueue === UploadQueues.shared.queue(for: device))
    }

    @Test("An upload has completed when its texture is handed out, and one store's uploads run in call order")
    func uploadsCompleteBeforeHandoutInCallOrder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        var buffers: [any MTLCommandBuffer] = []
        for (width, height) in [(512, 512), (300, 200), (64, 64), (1024, 256), (37, 23)] as [(Int, Int)] {
            let image = try #require(InlineTextureLoader.image(data: try patternPNG(width: width, height: height)))
            var statusAtHandout: MTLCommandBufferStatus?
            let texture = try InlineTextureLoader.texture(image, srgb: true, device: device, queue: resources.uploadQueue) { command in
                statusAtHandout = command.status
                buffers.append(command)
            }
            #expect(statusAtHandout == .completed, "\(width)x\(height) handed out with status \(statusAtHandout.map { "\($0.rawValue)" } ?? "none")")
            #expect(texture.width == width && texture.height == height)
        }
        #expect(buffers.count == 5)
        for (earlier, later) in zip(buffers, buffers.dropFirst()) {
            #expect(earlier.commandQueue === later.commandQueue)
            #expect(earlier.gpuEndTime <= later.gpuStartTime)
        }
    }

    @Test("A loaded texture reads back whole at once from another queue")
    func loadedTextureReadsBackWholeFromAnotherQueue() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let readback = try #require(device.makeCommandQueue())
        for (index, (width, height)) in ([(1024, 1024), (1000, 700), (2048, 256)] as [(Int, Int)]).enumerated() {
            let png = try patternPNG(width: width, height: height)
            let decoded = try #require(InlineTextureLoader.image(data: png))
            let layout = try #require(InlineTextureLoader.layout(for: decoded, srgb: true))
            let staged = try InlineTextureLoader.stage(decoded.cgImage, layout: layout, device: device)
            let expected = Data(bytes: staged.contents(), count: width * height * layout.bytesPerPixel)
            let handle = try resources.texture(data: png, key: "readback-\(index)")
            let texture = try #require(resources.texture(handle))
            // No wait on the upload queue: the readback queue sees only what
            // the load had finished before it returned.
            let record = try TextureIdentityRecord(texture, device: device, queue: readback)
            #expect(record.levels.count == InlineTextureLoader.mipLevelCount(width: width, height: height))
            #expect(record.levels.first == expected, "\(width)x\(height) level 0 differs")
        }
    }

    @Test("Upload permits never let more holders in than their limit")
    func uploadPermitsBoundTheirHolders() async {
        let permits = UploadPermits(limit: 2)
        await onOwnThread {
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                permits.acquire()
                usleep(5_000)
                permits.release()
            }
        }
        #expect(permits.resetMost() == 2)
    }

    @Test("Concurrent loads hold at most the shared limit of upload permits")
    func concurrentLoadsStayWithinTheUploadPermits() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resources = ResourceStore(device: device)
        let png = try patternPNG(width: 256, height: 256)
        _ = UploadPermits.shared.resetMost()
        let failures = await withTaskGroup(of: Bool.self) { group -> Int in
            for index in 0..<64 {
                group.addTask { (try? resources.texture(data: png, key: "permits-\(index)")) == nil }
            }
            var failures = 0
            for await failed in group where failed { failures += 1 }
            return failures
        }
        #expect(failures == 0)
        #expect(UploadPermits.shared.resetMost() <= UploadPermits.limit)
    }

    /// With a command queue per store, 256 stores loading at once failed about
    /// 100 uploads with `IOGPUCommandQueueErrorDomain` 518 (the driver's queue
    /// limit). Hundreds of cooperative tasks also block every cooperative
    /// thread at once, the condition under which `MTKTextureLoader` deadlocked.
    @Test("Hundreds of stores load at once from the cooperative pool, every load counted", .timeLimit(.minutes(2)))
    func manyStoresLoadAtOnceFromTheCooperativePool() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let count = 256
        let pngs = try [(64, 64), (61, 47), (128, 32), (33, 33)].map { try patternPNG(width: $0.0, height: $0.1) }
        let stores = (0..<count).map { _ in ResourceStore(device: device) }
        let failures = await withTaskGroup(of: String?.self) { group -> [String] in
            for index in 0..<count {
                group.addTask {
                    do {
                        let handle = try stores[index].texture(data: pngs[index % pngs.count], key: "store-\(index)")
                        return stores[index].texture(handle) == nil ? "store \(index): no texture" : nil
                    } catch {
                        return "store \(index): \(error)"
                    }
                }
            }
            var failures: [String] = []
            for await failure in group { if let failure { failures.append(failure) } }
            return failures
        }
        #expect(failures.isEmpty, "\(failures.count) of \(count) loads failed:\n\(failures.prefix(5).joined(separator: "\n"))")
    }
}
