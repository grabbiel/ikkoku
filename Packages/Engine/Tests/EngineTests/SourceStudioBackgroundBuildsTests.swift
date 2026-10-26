import Foundation
import Metal
import Testing
import Scene
import Studio
import Character
@testable import Renderer

// R7 phase 2 item 6, third part: `SourceStudioBackgroundBuilds`, the keyed
// background builds of an outfit selection or an export's baselines. These
// use batches without requests, so they need no fixture; the fixture tests
// with real characters are in SourceStudioCharacterBatchTests.swift.

/// What the completions saw, in order. Main-actor isolated, so the
/// completions may share it.
@MainActor final class BackgroundBuildLog {
    var entries: [String] = []
}

/// Yields the main actor until `condition` holds, so the queued main-queue
/// callbacks run; throws after `seconds`.
@MainActor func backgroundBuildsWait(seconds: Double = 120, _ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { throw RigError.invalid("timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Yields the main actor for `seconds`, so any callback still queued runs.
@MainActor func backgroundBuildsSettle(_ seconds: Double = 0.3) async throws {
    try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}

@MainActor @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device for the store"))
func sourceStudioBackgroundBuildsCompleteOnlyTheNewestBuildOfAKey() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let builds = SourceStudioBackgroundBuilds<Int>(queue: DispatchQueue(label: "test.background-builds"))
    let log = BackgroundBuildLog()
    let first = SourceStudioCharacterBatch(requests: [], resources: resources)
    let second = SourceStudioCharacterBatch(requests: [], resources: resources)
    let other = SourceStudioCharacterBatch(requests: [], resources: resources)
    #expect(builds.start(1, batch: first) { log.entries.append("first \($0.count)") } == nil)
    // A newer selection for the same key supersedes the first.
    let superseded = builds.start(1, batch: second) { log.entries.append("second \($0.count)") }
    #expect(superseded === first)
    #expect(first.isCancelled && !second.isCancelled)
    builds.start(2, batch: other) { log.entries.append("other \($0.count)") }
    #expect(builds.count == 2 && builds.batch(for: 1) === second && builds.contains(2))
    try await backgroundBuildsWait("both completions") { log.entries.count == 2 }
    try await backgroundBuildsSettle()
    #expect(log.entries.sorted() == ["other 0", "second 0"])
    #expect(builds.isEmpty)
}

@MainActor @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device for the store"))
func sourceStudioBackgroundBuildsRunNoCompletionAfterACancel() async throws {
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let queue = DispatchQueue(label: "test.background-builds")
    let builds = SourceStudioBackgroundBuilds<String>(queue: queue)
    let log = BackgroundBuildLog()
    let batches = (0..<3).map { _ in SourceStudioCharacterBatch(requests: [], resources: resources) }
    for (index, batch) in batches.enumerated() {
        builds.start("key \(index)", batch: batch) { _ in log.entries.append("key \(index)") }
    }
    // The runs finish on the queue; their callbacks wait for the main actor,
    // where the cancels below run first (an undo, a scene replacement).
    queue.sync {}
    #expect(builds.cancel("key 1") === batches[1])
    #expect(builds.cancel("missing") == nil)
    #expect(Set(builds.cancelAll().map { ObjectIdentifier($0) }) == Set([batches[0], batches[2]].map { ObjectIdentifier($0) }))
    try await backgroundBuildsSettle()
    #expect(log.entries.isEmpty)
    #expect(batches.allSatisfy { $0.isCancelled })
    #expect(builds.isEmpty)
    // The registry starts again normally.
    let again = SourceStudioCharacterBatch(requests: [], resources: resources)
    builds.start("key 0", batch: again) { _ in log.entries.append("again") }
    try await backgroundBuildsWait("the later completion") { log.entries == ["again"] }
}
