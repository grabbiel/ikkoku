import Metal

public enum GPUError: Error, CustomStringConvertible {
    case noDevice
    case shaderLibraryNotFound(name: String, bundle: String)

    public var description: String {
        switch self {
        case .noDevice:
            return "No Metal device is available on this system."
        case let .shaderLibraryNotFound(name, bundle):
            return "Could not find \(name).metallib in \(bundle). "
                 + "Check that the shader target is a dependency and that the "
                 + "metallib is in Copy Bundle Resources."
        }
    }
}

public final class GPUContext: @unchecked Sendable {
    public static let maxFramesInFlight = 3

    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue

    private let inFlight = DispatchSemaphore(value: GPUContext.maxFramesInFlight)

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        queue.label = "Ikkoku.main"
        self.device = device
        self.commandQueue = queue
    }

    // MARK: - Frame pacing

    /// Blocks until a frame slot frees up. Call at the top of every frame.
    public func waitForFrameSlot() { inFlight.wait() }

    /// Release a slot without a GPU round trip (error paths only).
    public func releaseFrameSlot() { inFlight.signal() }

    /// Attach to the frame's final command buffer.
    public func releaseFrameSlot(onCompletionOf commandBuffer: any MTLCommandBuffer) {
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
    }

    // MARK: - Shaders

    /// Loads a precompiled metallib produced by a separate shader target.
    /// Explicit rather than `makeDefaultLibrary()` so both app targets can
    /// share one compiled library instead of each building its own.
    public func makeShaderLibrary(
        named name: String = "IkkokuShaders",
        in bundle: Bundle = .main
    ) throws -> any MTLLibrary {
        guard let url = bundle.url(forResource: name, withExtension: "metallib") else {
            throw GPUError.shaderLibraryNotFound(
                name: name, bundle: bundle.bundleURL.lastPathComponent)
        }
        let library = try device.makeLibrary(URL: url)
        library.label = name
        return library
    }

    // MARK: - Debugging

    public func captureNextFrame() {
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.developerTools) else { return }
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = device
        descriptor.destination = .developerTools
        try? manager.startCapture(with: descriptor)
    }

    public func endCapture() {
        MTLCaptureManager.shared().stopCapture()
    }
}
