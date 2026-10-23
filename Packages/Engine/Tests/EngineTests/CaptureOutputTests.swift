import Foundation
import Testing
import CoreGraphics
import ImageIO
import Renderer

// A-T05: required capture outputs are written through one checked path that
// fails loudly, and the UI capture waits for readiness with a bounded timeout.

private func captureOutputImage(width: Int, height: Int) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func captureOutputDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureOutputTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The `CaptureOutputError` thrown by `body`, or nil when it succeeds or throws something else.
private func captureOutputFailure<T>(_ body: () throws -> T) -> CaptureOutputError? {
    do { _ = try body() } catch let error as CaptureOutputError { return error } catch { return nil }
    return nil
}

private func isWriteFailure(_ error: CaptureOutputError) -> Bool {
    if case .writeFailed = error.reason { return true }
    return false
}

private func isInvalidPNG(_ error: CaptureOutputError) -> Bool {
    if case .invalidPNG = error.reason { return true }
    return false
}

private func isInvalidJSON(_ error: CaptureOutputError) -> Bool {
    if case .invalidJSON = error.reason { return true }
    return false
}

@Test func captureOutputPNGRoundTripVerifiesTheWrittenFile() throws {
    let directory = try captureOutputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("round-trip.png")
    let image = try captureOutputImage(width: 3, height: 2)

    let bytes = try CaptureOutput.writePNG(image, to: url)
    let data = try Data(contentsOf: url)
    #expect(bytes > 0)
    #expect(bytes == data.count)
    let verified = try CaptureOutput.verifyPNG(at: url, width: 3, height: 2)
    #expect(verified == bytes)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 3)
    #expect(decoded.height == 2)
    let encoded = try CaptureOutput.pngData(image)
    #expect(!encoded.isEmpty)

    let report = directory.appendingPathComponent("report.json")
    let reportBytes = try CaptureOutput.writeJSON(Data(#"{"passed": 1}"#.utf8), to: report)
    let reportVerified = try CaptureOutput.verifyJSON(at: report)
    #expect(reportBytes == reportVerified)
}

@Test func captureOutputRejectsUnwritableDestinations() throws {
    let directory = try captureOutputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = try captureOutputImage(width: 2, height: 2)

    // A destination under a directory that does not exist is not created.
    let nested = directory.appendingPathComponent("missing/deeper/out.png")
    let missingParentResult = captureOutputFailure { try CaptureOutput.writePNG(image, to: nested) }
    let missingParent = try #require(missingParentResult)
    #expect(isWriteFailure(missingParent), "\(missingParent)")
    #expect(missingParent.path == nested.path)
    #expect(missingParent.description.contains(nested.path))
    let nestedExists = FileManager.default.fileExists(atPath: nested.path)
    #expect(!nestedExists)

    // A directory at the destination is refused and left in place.
    let occupied = directory.appendingPathComponent("occupied.png", isDirectory: true)
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
    let occupiedResult = captureOutputFailure { try CaptureOutput.writePNG(image, to: occupied) }
    let occupiedFailure = try #require(occupiedResult)
    #expect(occupiedFailure.reason == .notRegularFile)
    var isDirectory: ObjCBool = false
    let stillExists = FileManager.default.fileExists(atPath: occupied.path, isDirectory: &isDirectory)
    #expect(stillExists)
    #expect(isDirectory.boolValue)

    // JSON reports take the same checked path.
    let report = directory.appendingPathComponent("missing/report.json")
    let reportResult = captureOutputFailure { try CaptureOutput.writeJSON(Data("{}".utf8), to: report) }
    let reportFailure = try #require(reportResult)
    #expect(isWriteFailure(reportFailure), "\(reportFailure)")
    #expect(reportFailure.description.contains("missing/report.json"))
    let occupiedReportResult = captureOutputFailure { try CaptureOutput.writeJSON(Data("{}".utf8), to: occupied) }
    let occupiedReport = try #require(occupiedReportResult)
    #expect(occupiedReport.reason == .notRegularFile)
}

@Test func captureOutputDetectsMissingEmptyTruncatedAndGarbageFiles() throws {
    let directory = try captureOutputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let absent = directory.appendingPathComponent("absent.png")
    let absentResult = captureOutputFailure { try CaptureOutput.verifyPNG(at: absent, width: 1, height: 1) }
    let absentFailure = try #require(absentResult)
    #expect(absentFailure.reason == .missing)
    let directoryResult = captureOutputFailure { try CaptureOutput.verifyNonempty(at: directory) }
    let directoryFailure = try #require(directoryResult)
    #expect(directoryFailure.reason == .notRegularFile)

    let empty = directory.appendingPathComponent("empty.png")
    let created = FileManager.default.createFile(atPath: empty.path, contents: Data())
    #expect(created)
    let emptyPNGResult = captureOutputFailure { try CaptureOutput.verifyPNG(at: empty, width: 1, height: 1) }
    let emptyPNG = try #require(emptyPNGResult)
    #expect(emptyPNG.reason == .empty)
    let emptyJSONResult = captureOutputFailure { try CaptureOutput.verifyJSON(at: empty) }
    let emptyJSON = try #require(emptyJSONResult)
    #expect(emptyJSON.reason == .empty)
    let emptyFileResult = captureOutputFailure { try CaptureOutput.verifyNonempty(at: empty) }
    let emptyFile = try #require(emptyFileResult)
    #expect(emptyFile.reason == .empty)
    // Writing zero bytes is itself a failure: an empty report is never "written".
    let emptyReport = directory.appendingPathComponent("empty.json")
    let emptyWriteResult = captureOutputFailure { try CaptureOutput.writeJSON(Data(), to: emptyReport) }
    let emptyWrite = try #require(emptyWriteResult)
    #expect(emptyWrite.reason == .empty)

    let garbage = directory.appendingPathComponent("garbage.png")
    try Data("not an image".utf8).write(to: garbage)
    let garbagePNGResult = captureOutputFailure { try CaptureOutput.verifyPNG(at: garbage, width: 1, height: 1) }
    let garbagePNG = try #require(garbagePNGResult)
    #expect(isInvalidPNG(garbagePNG), "\(garbagePNG)")
    let garbageJSONResult = captureOutputFailure { try CaptureOutput.verifyJSON(at: garbage) }
    let garbageJSON = try #require(garbageJSONResult)
    #expect(isInvalidJSON(garbageJSON), "\(garbageJSON)")
    let invalidReport = directory.appendingPathComponent("invalid.json")
    let invalidReportResult = captureOutputFailure { try CaptureOutput.writeJSON(Data("{\"unterminated\": ".utf8), to: invalidReport) }
    let invalidReportFailure = try #require(invalidReportResult)
    #expect(isInvalidJSON(invalidReportFailure), "\(invalidReportFailure)")

    // A PNG cut short before IEND, as an interrupted write leaves it, keeps a
    // readable header but is rejected.
    let valid = try CaptureOutput.pngData(try captureOutputImage(width: 4, height: 4))
    let truncated = directory.appendingPathComponent("truncated.png")
    try valid.prefix(valid.count - 12).write(to: truncated)
    let truncatedResult = captureOutputFailure { try CaptureOutput.verifyPNG(at: truncated, width: 4, height: 4) }
    let truncatedFailure = try #require(truncatedResult)
    #expect(isInvalidPNG(truncatedFailure), "\(truncatedFailure)")
}

@Test func captureOutputRejectsAPNGOfAnotherPixelSize() throws {
    let directory = try captureOutputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("three-by-two.png")
    try CaptureOutput.writePNG(try captureOutputImage(width: 3, height: 2), to: url)

    let result = captureOutputFailure { try CaptureOutput.verifyPNG(at: url, width: 2, height: 3) }
    let failure = try #require(result)
    #expect(failure.reason == .sizeMismatch(expectedWidth: 2, expectedHeight: 3, actualWidth: 3, actualHeight: 2))
    #expect(failure.description.contains(url.path))
}

@Test func captureOutputBatchReportsEveryFailedItem() throws {
    let directory = try captureOutputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = try captureOutputImage(width: 2, height: 2)

    let empty = CaptureOutputBatch()
    #expect(!empty.isComplete)

    let first = directory.appendingPathComponent("hair_a.png")
    let unwritable = directory.appendingPathComponent("missing/cloth_b.png")
    let unrendered = directory.appendingPathComponent("acc_c.png")
    let unloaded = directory.appendingPathComponent("item_e.png")
    let last = directory.appendingPathComponent("item_d.png")
    var batch = CaptureOutputBatch()
    batch.attempt(first) { _ = try CaptureOutput.writePNG(image, to: first) }
    batch.attempt(unwritable) { _ = try CaptureOutput.writePNG(image, to: unwritable) }
    batch.attempt(unrendered) {
        throw CaptureOutputError(path: unrendered.path, reason: .imageUnavailable("the renderer returned no image"))
    }
    batch.record(CaptureOutputError(path: unloaded.path, reason: .imageUnavailable("asset could not be loaded")))
    batch.attempt(last) { _ = try CaptureOutput.writePNG(image, to: last) }

    // Items after a failure still ran, and every failure is listed by path.
    let failedPaths = batch.failures.map(\.path)
    #expect(batch.written == [first.path, last.path])
    #expect(failedPaths == [unwritable.path, unrendered.path, unloaded.path])
    #expect(!batch.isComplete)
    let unrenderedExists = FileManager.default.fileExists(atPath: unrendered.path)
    #expect(!unrenderedExists)

    var clean = CaptureOutputBatch()
    clean.attempt(first) { _ = try CaptureOutput.writePNG(image, to: first) }
    #expect(clean.isComplete)
}

private func readinessDecisions(_ policy: UICaptureReadiness,
                                _ polls: [(UICaptureReadiness.Observation, Double)]) -> [UICaptureReadiness.Decision] {
    var tracker = UICaptureReadiness.Tracker(policy: policy)
    return polls.map { tracker.observe($0.0, elapsed: $0.1) }
}

private func readinessTimeoutReason(_ decision: UICaptureReadiness.Decision?) -> String? {
    if case .timedOut(let reason)? = decision { return reason }
    return nil
}

@Test func uiCaptureReadinessParsesItsTimeoutSetting() throws {
    let defaults = try UICaptureReadiness.fromEnvironment([:])
    #expect(defaults.timeout == UICaptureReadiness.defaultTimeout)
    #expect(defaults == UICaptureReadiness())
    let configured = try UICaptureReadiness.fromEnvironment([UICaptureReadiness.timeoutVariable: "2.5"])
    #expect(configured.timeout == 2.5)
    #expect(configured.stableObservations == UICaptureReadiness.defaultStableObservations)
    for text in ["", "0", "-1", "abc", "nan", "inf", "601"] {
        #expect(throws: UICaptureReadiness.ConfigurationError.self) {
            try UICaptureReadiness.fromEnvironment([UICaptureReadiness.timeoutVariable: text])
        }
    }
}

@Test func uiCaptureReadinessWaitsForAStableLaidOutWindow() {
    let policy = UICaptureReadiness(timeout: 10, pollInterval: 0.1, stableObservations: 3)
    let notAppeared = UICaptureReadiness.Observation(contentAppeared: false, windowVisible: true, width: 1180, height: 720)
    let hidden = UICaptureReadiness.Observation(contentAppeared: true, windowVisible: false, width: 0, height: 0)
    let zeroWidth = UICaptureReadiness.Observation(contentAppeared: true, windowVisible: true, width: 0, height: 720)
    let ready = UICaptureReadiness.Observation(contentAppeared: true, windowVisible: true, width: 1180, height: 720)
    let resized = UICaptureReadiness.Observation(contentAppeared: true, windowVisible: true, width: 1200, height: 720)
    let decisions = readinessDecisions(policy, [
        (notAppeared, 0.1), (hidden, 0.2), (zeroWidth, 0.3),
        (ready, 0.4), (ready, 0.5),
        // The size changed after two stable polls: the count restarts...
        (resized, 0.6), (resized, 0.7),
        // ...and an unready poll in between restarts it again.
        (hidden, 0.8),
        (resized, 0.9), (resized, 1.0), (resized, 1.1),
    ])
    let expected: [UICaptureReadiness.Decision] = [.wait, .wait, .wait, .wait, .wait, .wait, .wait, .wait, .wait, .wait, .capture]
    #expect(decisions == expected)
    let readyReason = ready.unreadyReason
    #expect(readyReason == nil)
    let zeroWidthReason = zeroWidth.unreadyReason ?? ""
    #expect(zeroWidthReason.contains("empty bounds"))
}

@Test func uiCaptureReadinessTimesOutNamingWhatWasNotReady() throws {
    let policy = UICaptureReadiness(timeout: 1, pollInterval: 0.25, stableObservations: 3)

    let hidden = UICaptureReadiness.Observation(contentAppeared: true, windowVisible: false, width: 0, height: 0)
    let neverShown = readinessDecisions(policy, [(hidden, 0.25), (hidden, 0.5), (hidden, 0.75), (hidden, 1.0)])
    let beforeDeadline = Array(neverShown.dropLast())
    let waits: [UICaptureReadiness.Decision] = [.wait, .wait, .wait]
    #expect(beforeDeadline == waits)
    let hiddenReason = try #require(readinessTimeoutReason(neverShown.last))
    #expect(hiddenReason.contains("no visible window"))
    #expect(hiddenReason.contains(UICaptureReadiness.timeoutVariable))

    let notAppeared = UICaptureReadiness.Observation(contentAppeared: false, windowVisible: false, width: 0, height: 0)
    let neverAppeared = readinessDecisions(policy, [(notAppeared, 1.5)])
    let appearReason = try #require(readinessTimeoutReason(neverAppeared.last))
    #expect(appearReason.contains("has not appeared"))

    // A window whose size never settles times out instead of capturing.
    var growing: [(UICaptureReadiness.Observation, Double)] = []
    for step in 1...4 {
        growing.append((UICaptureReadiness.Observation(contentAppeared: true, windowVisible: true,
                                                       width: Double(1000 + step), height: 720),
                        Double(step) * 0.25))
    }
    let settling = readinessDecisions(policy, growing)
    let settlingReason = try #require(readinessTimeoutReason(settling.last))
    #expect(settlingReason.contains("still settling"))

    // Readiness reached on the deadline poll still captures.
    let ready = UICaptureReadiness.Observation(contentAppeared: true, windowVisible: true, width: 800, height: 600)
    let onTime = readinessDecisions(policy, [(ready, 0.5), (ready, 0.75), (ready, 1.0)])
    let captured: [UICaptureReadiness.Decision] = [.wait, .wait, .capture]
    #expect(onTime == captured)
}
