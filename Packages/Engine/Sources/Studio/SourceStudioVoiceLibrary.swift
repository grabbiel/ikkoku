import Foundation
@preconcurrency import AVFAudio
import Scene

/// What the Studio's voice plays keep between plays (#445), so a play does
/// not read, parse, hash and decode on the main thread every time:
///
/// - **The catalog**, parsed once per file. One `stat` per play checks it is
///   still the same file (size, modification time, inode); a changed file
///   is read again.
/// - **Decoded clips**, keyed only by the SHA-256 identity of the converted
///   audio (the catalog row's `sha256`). Only bytes that hashed to that
///   identity are ever decoded, so an entry is that identity's audio and
///   never goes stale. A file changed on disk is not read while its identity
///   is cached; once the entry is evicted, the next play reads, hashes and
///   fails on it as before. At most `clipCapacityBytes` of PCM are kept, the
///   least recently played dropped first; a larger clip is decoded each play
///   and never kept.
///
/// A miss loads on a background queue and completes on the main thread.
/// `releaseCaches` (memory pressure) and `releaseAll` (New Scene, Open: the
/// Studio's `stopSourceVoices`) drop both caches; a load started before a
/// release still completes for its play but caches nothing.
@MainActor public final class SourceStudioVoiceLibrary {
    /// PCM bytes the clip cache keeps: voice lines are short, and Studio
    /// memory matters as much.
    public static let clipCapacityBytes = 32 * 1024 * 1024

    public let clipCapacityBytes: Int
    /// Counters for checks and measurement: catalogs and clips read from
    /// disk, and clips served from the cache.
    public private(set) var catalogLoads = 0, clipLoads = 0, clipHits = 0
    public private(set) var clipBytes = 0
    public var clipCount: Int { clips.count }

    private let queue = DispatchQueue(label: "ikkoku.studio-voice-load", qos: .userInitiated)
    private var catalog: (path: String, stamp: SourceStudioVoiceFileStamp, value: SourceStudioVoiceCatalog)?
    private var catalogWaiters: [String: [@MainActor (Result<SourceStudioVoiceCatalog, any Error>) -> Void]] = [:]
    private var clips: [String: (buffer: AVAudioPCMBuffer, bytes: Int, used: UInt64)] = [:]
    private var clipWaiters: [String: [@MainActor (Result<AVAudioPCMBuffer, any Error>) -> Void]] = [:]
    private var useClock: UInt64 = 0
    /// Bumped by every release: a load that started before it caches nothing.
    private var epoch: UInt64 = 0
    private var requests: [AnyHashable: UInt64] = [:]
    private var requestClock: UInt64 = 0

    public init(clipCapacityBytes: Int = SourceStudioVoiceLibrary.clipCapacityBytes) {
        self.clipCapacityBytes = max(0, clipCapacityBytes)
    }

    // MARK: Catalog

    /// The parsed catalog at `path` when it is cached and the file is
    /// unchanged; nil otherwise (`loadCatalog`).
    public func cachedCatalog(at path: String) -> SourceStudioVoiceCatalog? {
        guard let cached = catalog, cached.path == path, (try? SourceStudioVoiceFileStamp(URL(fileURLWithPath: path))) == cached.stamp else { return nil }
        return cached.value
    }

    /// Reads and parses the catalog at `path` on the background queue;
    /// `completion` runs on the main thread. Loads of the same path share one read.
    public func loadCatalog(at path: String, completion: @escaping @MainActor (Result<SourceStudioVoiceCatalog, any Error>) -> Void) {
        if catalogWaiters[path] != nil { catalogWaiters[path]!.append(completion); return }
        catalogWaiters[path] = [completion]
        let epoch = self.epoch
        queue.async {
            let result = Result { () throws -> Loaded<SourceStudioVoiceCatalog> in
                let url = URL(fileURLWithPath: path), stamp = try SourceStudioVoiceFileStamp(url)
                return Loaded(stamp: stamp, value: try SourceStudioVoiceCatalog.load(url: url))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.catalogLoaded(path, result, epoch: epoch) }
            }
        }
    }

    private func catalogLoaded(_ path: String, _ result: Result<Loaded<SourceStudioVoiceCatalog>, any Error>, epoch: UInt64) {
        catalogLoads += 1
        if case .success(let loaded) = result, epoch == self.epoch { catalog = (path, loaded.stamp, loaded.value) }
        for waiter in catalogWaiters.removeValue(forKey: path) ?? [] { waiter(result.map(\.value)) }
    }

    // MARK: Clips

    /// The decoded audio of identity `sha256`, if cached; it becomes the
    /// most recently played.
    public func clip(_ sha256: String) -> AVAudioPCMBuffer? {
        guard var entry = clips[sha256] else { return nil }
        useClock &+= 1; entry.used = useClock; clips[sha256] = entry
        clipHits += 1
        return entry.buffer
    }

    /// Reads `clip`'s file once on the background queue, checks its bytes
    /// hash to the clip's identity, decodes it (`decode`) and caches it;
    /// `completion` runs on the main thread. Loads of one identity share
    /// one read.
    public func loadClip(_ clip: SourceStudioVoiceCatalog.Clip, directory: URL,
                         completion: @escaping @MainActor (Result<AVAudioPCMBuffer, any Error>) -> Void) {
        if clipWaiters[clip.sha256] != nil { clipWaiters[clip.sha256]!.append(completion); return }
        clipWaiters[clip.sha256] = [completion]
        let epoch = self.epoch
        queue.async {
            let result = Result { Decoded(buffer: try Self.decode(clip, directory: directory)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.clipLoaded(clip.sha256, result.map(\.buffer), epoch: epoch) }
            }
        }
    }

    private func clipLoaded(_ sha256: String, _ result: Result<AVAudioPCMBuffer, any Error>, epoch: UInt64) {
        clipLoads += 1
        if case .success(let buffer) = result, epoch == self.epoch { insert(buffer, for: sha256) }
        for waiter in clipWaiters.removeValue(forKey: sha256) ?? [] { waiter(result) }
    }

    /// Keeps `buffer`, the verified decode of identity `sha256`, evicting the
    /// least recently played clips past the capacity. A clip larger than the
    /// capacity is not kept.
    public func insert(_ buffer: AVAudioPCMBuffer, for sha256: String) {
        let bytes = Self.bytes(of: buffer)
        guard bytes <= clipCapacityBytes else { return }
        if let old = clips.removeValue(forKey: sha256) { clipBytes -= old.bytes }
        while clipBytes + bytes > clipCapacityBytes, let oldest = clips.min(by: { $0.value.used < $1.value.used }) {
            clips[oldest.key] = nil; clipBytes -= oldest.value.bytes
        }
        useClock &+= 1
        clips[sha256] = (buffer, bytes, useClock); clipBytes += bytes
    }

    /// The bytes a decoded clip holds: every channel's buffer.
    public static func bytes(of buffer: AVAudioPCMBuffer) -> Int {
        UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
    }

    /// The verified decode of `clip` (any thread). The file is read once and
    /// must hash to the clip's identity before `AVAudioFile` decodes it. The
    /// decoder opens the path again, so the file's stat (size, modification
    /// time, inode) is taken before the read and after the decode, and any
    /// change refuses the clip: the window between the hash and the decode
    /// is narrowed, not closed.
    nonisolated public static func decode(_ clip: SourceStudioVoiceCatalog.Clip, directory: URL) throws -> AVAudioPCMBuffer {
        let url = try SourceStudioVoiceCatalog.contained(clip, directory: directory)
        let before = try SourceStudioVoiceFileStamp(url)
        _ = try SourceStudioVoiceCatalog.verified(url, sha256: clip.sha256)
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= 48_000 * 60 * 20, file.processingFormat.channelCount <= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RigError.invalid("Converted Studio voice exceeds its duration/channel bounds.")
        }
        try file.read(into: buffer)
        guard try SourceStudioVoiceFileStamp(url) == before else { throw RigError.invalid("Studio voice file changed while it was read; play it again.") }
        return buffer
    }

    // MARK: Requests and releases

    /// A new play request for `key` (an object), replacing its previous one.
    public func request(_ key: AnyHashable) -> UInt64 {
        requestClock &+= 1; requests[key] = requestClock
        return requestClock
    }

    /// Whether `token` is still `key`'s latest request (no newer play, stop
    /// or release since).
    public func isCurrent(_ key: AnyHashable, _ token: UInt64) -> Bool { requests[key] == token }

    /// Ends `key`'s request: a load it waits for no longer starts its play.
    public func cancelRequest(_ key: AnyHashable) { requests[key] = nil }

    /// Drops the cached catalog and clips (memory pressure). Plays waiting
    /// for a load still start; their loads cache nothing.
    public func releaseCaches() {
        epoch &+= 1
        catalog = nil
        clips.removeAll(); clipBytes = 0
    }

    /// `releaseCaches`, and every play request ends (New Scene, Open).
    public func releaseAll() {
        releaseCaches()
        requests.removeAll()
    }
}

/// A file's identity for a cache: size, modification time, device and inode.
public struct SourceStudioVoiceFileStamp: Equatable, Sendable {
    public let device: Int64, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
    public init(_ url: URL) throws {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw RigError.invalid("Studio voice input is unreadable: \(url.lastPathComponent).") }
        device = Int64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
        seconds = Int(info.st_mtimespec.tv_sec); nanoseconds = Int(info.st_mtimespec.tv_nsec)
    }
}

private struct Loaded<Value: Sendable>: Sendable {
    let stamp: SourceStudioVoiceFileStamp, value: Value
}

/// A decoded clip handed from the load queue to the main thread; nothing
/// else holds it then.
private struct Decoded: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
