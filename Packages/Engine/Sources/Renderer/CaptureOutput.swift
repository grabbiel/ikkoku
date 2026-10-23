import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Why a required capture output is missing or invalid (A-T05). The
/// description names the path, so a caller can print it and exit nonzero
/// without losing which file failed.
public struct CaptureOutputError: Error, Equatable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        /// There was no image to write: the renderer or the window snapshot
        /// returned none, or the input it needed could not be loaded.
        case imageUnavailable(String)
        /// ImageIO could not encode the image as PNG.
        case encodingFailed
        /// The destination could not be written: a missing parent directory,
        /// no permission, a full disk.
        case writeFailed(String)
        /// Nothing exists at the path.
        case missing
        /// A directory occupies the path.
        case notRegularFile
        /// The file exists but holds zero bytes.
        case empty
        /// The file exists but could not be read back.
        case unreadable(String)
        /// The bytes read back differ from the bytes that were written.
        case contentMismatch(writtenBytes: Int, readBytes: Int)
        /// Not a complete PNG stream, or ImageIO cannot decode it.
        case invalidPNG(String)
        /// The PNG holds another pixel size than the image that was captured.
        case sizeMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
        /// A report does not parse as a JSON object or array.
        case invalidJSON(String)
    }

    /// The output path; empty for an in-memory encoding.
    public let path: String
    public let reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }

    public var description: String {
        let detail: String
        switch reason {
        case .imageUnavailable(let why): detail = "no image to write (\(why))"
        case .encodingFailed: detail = "PNG encoding failed"
        case .writeFailed(let why): detail = "could not be written (\(why))"
        case .missing: detail = "no file exists at this path"
        case .notRegularFile: detail = "a directory occupies this path"
        case .empty: detail = "the file is empty (0 bytes)"
        case .unreadable(let why): detail = "the file could not be read back (\(why))"
        case .contentMismatch(writtenBytes: let written, readBytes: let read):
            detail = "read back \(read) bytes after writing \(written)"
        case .invalidPNG(let why): detail = "not a valid PNG (\(why))"
        case .sizeMismatch(expectedWidth: let width, expectedHeight: let height, actualWidth: let actualWidth, actualHeight: let actualHeight):
            detail = "the PNG is \(actualWidth)x\(actualHeight) px, expected \(width)x\(height)"
        case .invalidJSON(let why): detail = "not valid JSON (\(why))"
        }
        return path.isEmpty ? detail : "\(path): \(detail)"
    }
}

/// Checked writes for required capture outputs (A-T05).
///
/// Headless captures (window snapshots, thumbnails, offscreen renders and
/// their JSON reports) write through these functions instead of `try?`, so a
/// failure is never silent. After writing, the file is read back: it must be
/// a nonempty regular file holding exactly the bytes written. A PNG must also
/// be a complete PNG stream (signature, leading IHDR, in-bounds chunks, final
/// IEND) that ImageIO decodes at the captured image's pixel size; a report
/// must parse as a JSON object or array. Callers print "written" only after a
/// write returns, and exit nonzero on a thrown `CaptureOutputError`.
///
/// Missing parent directories are not created: a destination under a
/// directory that does not exist fails like any other unwritable path.
public enum CaptureOutput {
    /// PNG-encodes `image` in memory; nothing is written.
    public static func pngData(_ image: CGImage) throws -> Data {
        try encodePNG(image, path: "")
    }

    /// Writes `image` as a PNG at `url` and verifies the written file.
    /// - Returns: The verified file size in bytes.
    @discardableResult
    public static func writePNG(_ image: CGImage, to url: URL) throws -> Int {
        let data = try encodePNG(image, path: url.path)
        try writeVerified(data, to: url)
        try checkPNG(data, path: url.path, width: image.width, height: image.height)
        return data.count
    }

    /// Writes an encoded JSON report at `url` and verifies the written file.
    /// - Returns: The verified file size in bytes.
    @discardableResult
    public static func writeJSON(_ data: Data, to url: URL) throws -> Int {
        try writeVerified(data, to: url)
        try checkJSON(data, path: url.path)
        return data.count
    }

    /// Checks that a nonempty regular file exists at `url`, for outputs
    /// produced by another writer (for example a saved card).
    /// - Returns: The file size in bytes.
    @discardableResult
    public static func verifyNonempty(at url: URL) throws -> Int {
        try readNonempty(at: url).count
    }

    /// Checks that `url` holds a complete PNG of exactly `width`×`height` pixels.
    /// - Returns: The file size in bytes.
    @discardableResult
    public static func verifyPNG(at url: URL, width: Int, height: Int) throws -> Int {
        let data = try readNonempty(at: url)
        try checkPNG(data, path: url.path, width: width, height: height)
        return data.count
    }

    /// Checks that `url` holds a nonempty JSON object or array.
    /// - Returns: The file size in bytes.
    @discardableResult
    public static func verifyJSON(at url: URL) throws -> Int {
        let data = try readNonempty(at: url)
        try checkJSON(data, path: url.path)
        return data.count
    }

    // MARK: - Internals

    private static func encodePNG(_ image: CGImage, path: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureOutputError(path: path, reason: .encodingFailed)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw CaptureOutputError(path: path, reason: .encodingFailed)
        }
        return data as Data
    }

    /// Writes atomically, then requires the file to hold exactly `data`.
    /// An empty `data` therefore always fails as `.empty`.
    private static func writeVerified(_ data: Data, to url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CaptureOutputError(path: url.path, reason: .notRegularFile)
        }
        do { try data.write(to: url, options: .atomic) }
        catch { throw CaptureOutputError(path: url.path, reason: .writeFailed(error.localizedDescription)) }
        let written = try readNonempty(at: url)
        guard written == data else {
            throw CaptureOutputError(path: url.path, reason: .contentMismatch(writtenBytes: data.count, readBytes: written.count))
        }
    }

    private static func readNonempty(at url: URL) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CaptureOutputError(path: url.path, reason: .missing)
        }
        guard !isDirectory.boolValue else { throw CaptureOutputError(path: url.path, reason: .notRegularFile) }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw CaptureOutputError(path: url.path, reason: .unreadable(error.localizedDescription)) }
        guard !data.isEmpty else { throw CaptureOutputError(path: url.path, reason: .empty) }
        return data
    }

    private static func checkPNG(_ data: Data, path: String, width: Int, height: Int) throws {
        // ImageIO decodes lazily from the header, so a stream cut short after
        // IHDR would still report a size; walk the chunks to reject it.
        guard let header = pngHeaderSize([UInt8](data)) else {
            throw CaptureOutputError(path: path, reason: .invalidPNG("missing signature, IHDR, in-bounds chunks or final IEND"))
        }
        guard header.width == width, header.height == height else {
            throw CaptureOutputError(path: path, reason: .sizeMismatch(expectedWidth: width, expectedHeight: height,
                                                                       actualWidth: header.width, actualHeight: header.height))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureOutputError(path: path, reason: .invalidPNG("ImageIO cannot decode it"))
        }
        guard image.width == width, image.height == height else {
            throw CaptureOutputError(path: path, reason: .sizeMismatch(expectedWidth: width, expectedHeight: height,
                                                                       actualWidth: image.width, actualHeight: image.height))
        }
    }

    private static func checkJSON(_ data: Data, path: String) throws {
        do { _ = try JSONSerialization.jsonObject(with: data) }
        catch { throw CaptureOutputError(path: path, reason: .invalidJSON(error.localizedDescription)) }
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The IHDR pixel size of a structurally complete PNG stream: the
    /// signature, IHDR as the first chunk, every chunk (length, type, data,
    /// CRC) inside the file and IEND as the last chunk ending at the last
    /// byte. Chunk CRCs are not recomputed; written files are compared with
    /// the encoded bytes instead.
    static func pngHeaderSize(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 8 + 25 + 12, Array(bytes[0..<8]) == pngSignature else { return nil }
        func bigEndian32(_ offset: Int) -> Int {
            let b0 = Int(bytes[offset]), b1 = Int(bytes[offset + 1])
            let b2 = Int(bytes[offset + 2]), b3 = Int(bytes[offset + 3])
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        var offset = 8
        var size: (width: Int, height: Int)?
        while offset + 12 <= bytes.count {
            let length = bigEndian32(offset)
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let end = offset + 12 + length
            guard end <= bytes.count else { return nil }
            if offset == 8 {
                guard type == "IHDR", length == 13 else { return nil }
                size = (width: bigEndian32(offset + 8), height: bigEndian32(offset + 12))
            }
            if type == "IEND" { return end == bytes.count ? size : nil }
            offset = end
        }
        return nil
    }
}

/// Outcome of a multi-file capture such as one thumbnail per catalog entry
/// (A-T05): every item is attempted, so each failure is reported by path
/// before the run fails, instead of stopping at, or silently skipping, the
/// first bad item.
public struct CaptureOutputBatch: Sendable {
    /// Paths whose checked write succeeded, in attempt order.
    public private(set) var written: [String] = []
    /// Failed items, in attempt order.
    public private(set) var failures: [CaptureOutputError] = []

    public init() {}

    /// Runs one required output's checked write and records its path or its
    /// failure. It never throws, so the remaining items still run.
    public mutating func attempt(_ url: URL, _ write: () throws -> Void) {
        do {
            try write()
            written.append(url.path)
        } catch let error as CaptureOutputError {
            failures.append(error)
        } catch {
            failures.append(CaptureOutputError(path: url.path, reason: .imageUnavailable(String(describing: error))))
        }
    }

    /// Records an item that failed before it could be attempted.
    public mutating func record(_ failure: CaptureOutputError) {
        failures.append(failure)
    }

    /// True only when at least one output was written and none failed; an
    /// empty batch did not produce the outputs it was asked for.
    public var isComplete: Bool { failures.isEmpty && !written.isEmpty }
}

/// Readiness policy for the windowed UI capture (`IKKOKU_CAPTURE_UI`, A-T05).
///
/// The app polls the window on the main run loop every `pollInterval` seconds
/// instead of sleeping a fixed delay. A poll is ready when the SwiftUI content
/// has appeared (`onAppear`), a visible window holds it and its bounds after a
/// forced layout pass are nonzero. Capture starts once `stableObservations`
/// consecutive ready polls report the same content size, meaning layout has
/// converged; a change of size or an unready poll restarts the count. If that
/// does not happen within `timeout` seconds of arming, the capture fails with
/// the last unready reason instead of snapshotting whatever is on screen.
public struct UICaptureReadiness: Sendable, Equatable {
    /// Overrides `timeout`, in seconds.
    public static let timeoutVariable = "IKKOKU_CAPTURE_UI_TIMEOUT"
    public static let defaultTimeout: Double = 30
    public static let maximumTimeout: Double = 600
    public static let defaultPollInterval: Double = 0.1
    public static let defaultStableObservations = 5

    public let timeout: Double
    public let pollInterval: Double
    public let stableObservations: Int

    public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
        case invalidTimeout(String)

        public var description: String {
            switch self {
            case .invalidTimeout(let text):
                return "\(UICaptureReadiness.timeoutVariable) must be a number of seconds greater than 0 and at most \(Int(UICaptureReadiness.maximumTimeout)), got '\(text)'"
            }
        }
    }

    public init(timeout: Double = UICaptureReadiness.defaultTimeout,
                pollInterval: Double = UICaptureReadiness.defaultPollInterval,
                stableObservations: Int = UICaptureReadiness.defaultStableObservations) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.stableObservations = max(1, stableObservations)
    }

    /// The default policy, with `timeout` taken from `IKKOKU_CAPTURE_UI_TIMEOUT`
    /// when it is set. A value that is not a finite number of seconds in
    /// (0, 600] is rejected rather than replaced by the default.
    public static func fromEnvironment(_ environment: [String: String]) throws -> UICaptureReadiness {
        guard let text = environment[timeoutVariable] else { return UICaptureReadiness() }
        guard let seconds = Double(text), seconds.isFinite, seconds > 0, seconds <= maximumTimeout else {
            throw ConfigurationError.invalidTimeout(text)
        }
        return UICaptureReadiness(timeout: seconds)
    }

    /// One poll of the window.
    public struct Observation: Sendable, Equatable {
        /// The SwiftUI content reported `onAppear`.
        public var contentAppeared: Bool
        /// A visible window holds the content view.
        public var windowVisible: Bool
        /// The content view's bounds after a forced layout pass, in points.
        public var width: Double
        public var height: Double

        public init(contentAppeared: Bool, windowVisible: Bool, width: Double, height: Double) {
            self.contentAppeared = contentAppeared
            self.windowVisible = windowVisible
            self.width = width
            self.height = height
        }

        /// Why this poll is not ready, or nil when it is.
        public var unreadyReason: String? {
            if !contentAppeared { return "the window content has not appeared" }
            if !windowVisible { return "no visible window" }
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                return "the content view has empty bounds (\(width)x\(height) pt)"
            }
            return nil
        }
    }

    public enum Decision: Sendable, Equatable {
        case wait
        case capture
        /// Readiness was not reached in time; the text says what was missing.
        case timedOut(String)
    }

    /// Consumes one observation per poll and decides whether to capture.
    public struct Tracker: Sendable {
        public let policy: UICaptureReadiness
        /// Consecutive ready polls with the current content size.
        public private(set) var stableCount = 0
        private var stableWidth = 0.0
        private var stableHeight = 0.0

        public init(policy: UICaptureReadiness) {
            self.policy = policy
        }

        /// - Parameter elapsed: Seconds since the capture was armed.
        public mutating func observe(_ observation: Observation, elapsed: Double) -> Decision {
            if observation.unreadyReason == nil {
                if stableCount > 0, observation.width == stableWidth, observation.height == stableHeight {
                    stableCount += 1
                } else {
                    stableCount = 1
                    stableWidth = observation.width
                    stableHeight = observation.height
                }
            } else {
                stableCount = 0
            }
            // Readiness reached on the deadline poll still captures.
            if stableCount >= policy.stableObservations { return .capture }
            guard elapsed >= policy.timeout else { return .wait }
            let reason = observation.unreadyReason
                ?? "the content size is still settling (\(stableCount) of \(policy.stableObservations) stable polls at \(observation.width)x\(observation.height) pt)"
            return .timedOut("not ready after \(String(format: "%.2f", elapsed)) s (\(UICaptureReadiness.timeoutVariable)=\(policy.timeout)): \(reason)")
        }
    }
}
