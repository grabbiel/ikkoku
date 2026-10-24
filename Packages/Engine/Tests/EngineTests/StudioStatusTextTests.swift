import Foundation
import Testing
import Character
import Scene
import Studio

private let hana = UUID(), kai = UUID()
private let reach = "IK reach is not finite."

private func chain(_ object: UUID, _ chain: IKChain) -> StudioIKStatusReport.Chain { .init(object: object, chain: chain) }
private func failure(_ object: UUID, _ c: IKChain, _ reason: String = reach) -> StudioIKStatusReport.Failure {
    .init(chain: chain(object, c), character: object == hana ? "Hana" : "Kai", reason: reason)
}

@Test func ikStatusReportsAFailureAndClearsItsOwnMessage() {
    var report = StudioIKStatusReport()
    let enabled: Set = [chain(hana, .handL)]
    #expect(report.update(failures: [], enabled: enabled, status: "Ready") == nil)
    let unsolved = "Left hand IK left unsolved: IK reach is not finite."
    #expect(report.update(failures: [failure(hana, .handL)], enabled: enabled, status: "Ready") == unsolved)
    #expect(report.message == unsolved)
    // The same failure on the next frame writes nothing, even over another status.
    #expect(report.update(failures: [failure(hana, .handL)], enabled: enabled, status: unsolved) == nil)
    #expect(report.update(failures: [failure(hana, .handL)], enabled: enabled, status: "Selected Hana") == nil)
    // Solved again while the status line still shows the report's message.
    #expect(report.update(failures: [], enabled: enabled, status: unsolved) == "Left hand IK solved again.")
    #expect(report.message == nil && report.failures.isEmpty)
    #expect(report.update(failures: [], enabled: enabled, status: "Left hand IK solved again.") == nil)
}

@Test func ikStatusLeavesAStatusWrittenSinceTheFailure() {
    var report = StudioIKStatusReport()
    let enabled: Set = [chain(hana, .handL)]
    _ = report.update(failures: [failure(hana, .handL)], enabled: enabled, status: "Ready")
    #expect(report.update(failures: [], enabled: enabled, status: "Added Kai") == nil)
    #expect(report.message == nil)
    // A later failure is reported again.
    #expect(report.update(failures: [failure(hana, .handL)], enabled: enabled, status: "Added Kai")
        == "Left hand IK left unsolved: IK reach is not finite.")
}

@Test func ikStatusNamesEveryUnsolvedChainAndNarrowsAsTheySolve() {
    var report = StudioIKStatusReport()
    let enabled: Set = [chain(hana, .handL), chain(hana, .handR)]
    let left = "Left hand IK left unsolved: IK reach is not finite."
    let right = "Right hand IK left unsolved: IK reach is not finite."
    #expect(report.update(failures: [failure(hana, .handL)], enabled: enabled, status: "Ready") == left)
    #expect(report.update(failures: [failure(hana, .handL), failure(hana, .handR)], enabled: enabled, status: left)
        == "\(left) · \(right)")
    // The left hand solves: the owned message narrows to the right hand.
    #expect(report.update(failures: [failure(hana, .handR)], enabled: enabled, status: "\(left) · \(right)") == right)
    #expect(report.update(failures: [], enabled: enabled, status: right) == "Right hand IK solved again.")

    // Both solve in one frame.
    _ = report.update(failures: [failure(hana, .handL), failure(hana, .handR)], enabled: enabled, status: "Ready")
    #expect(report.update(failures: [], enabled: enabled, status: "\(left) · \(right)")
        == "Left hand and Right hand IK solved again.")
}

@Test func ikStatusNarrowingKeepsAStatusWrittenSince() {
    var report = StudioIKStatusReport()
    let enabled: Set = [chain(hana, .handL), chain(hana, .handR)]
    _ = report.update(failures: [failure(hana, .handL), failure(hana, .handR)], enabled: enabled, status: "Ready")
    // Another status replaced the report; one chain solving does not overwrite it.
    #expect(report.update(failures: [failure(hana, .handR)], enabled: enabled, status: "Added Kai") == nil)
    #expect(report.message == "Right hand IK left unsolved: IK reach is not finite.")
    #expect(report.update(failures: [], enabled: enabled, status: "Added Kai") == nil)
    // A newly failing chain, or a new reason, is always reported.
    _ = report.update(failures: [failure(hana, .handR)], enabled: enabled, status: "Ready")
    #expect(report.update(failures: [failure(hana, .handR), failure(hana, .handL)], enabled: enabled, status: "Added Kai")
        == "Right hand IK left unsolved: IK reach is not finite. · Left hand IK left unsolved: IK reach is not finite.")
    #expect(report.update(failures: [failure(hana, .handR, "IK target is degenerate.")], enabled: enabled, status: "Undo")
        == "Right hand IK left unsolved: IK target is degenerate.")
}

@Test func ikStatusClearsToReadyWhenNoReportedChainIsStillEnabled() {
    var report = StudioIKStatusReport()
    let unsolved = report.update(failures: [failure(hana, .handL)], enabled: [chain(hana, .handL)], status: "Ready")!
    // IK turned off (or the character deleted): nothing to call solved.
    #expect(report.update(failures: [], enabled: [], status: unsolved) == "Ready")
}

@Test func ikStatusNamesTheCharacterWhenChainsOfSeveralFail() {
    var report = StudioIKStatusReport()
    let enabled: Set = [chain(hana, .handL), chain(kai, .footR)]
    let both = report.update(failures: [failure(hana, .handL), failure(kai, .footR)], enabled: enabled, status: "Ready")
    #expect(both == "Left hand IK left unsolved on Hana: IK reach is not finite. · Right foot IK left unsolved on Kai: IK reach is not finite.")
    #expect(report.update(failures: [], enabled: enabled, status: both!) == "Left hand on Hana and Right foot on Kai IK solved again.")
    #expect(StudioIKStatusReport.solvedMessage([failure(hana, .handL), failure(hana, .handR), failure(hana, .footL)])
        == "Left hand, Right hand and Left foot IK solved again.")
}

@Test func sourceCameraLabelsNameTheCameraAndItsKey() {
    #expect(SourceStudioCameraLabel.title(name: "IKKOKU-MIRROR", key: 2) == "IKKOKU-MIRROR (camera 2)")
    #expect(SourceStudioCameraLabel.reference(name: "IKKOKU-MIRROR", key: 2) == "\"IKKOKU-MIRROR\" (camera 2)")
    // An unnamed record's fallback name already carries the key.
    #expect(SourceStudioCameraLabel.title(name: "Source camera 7", key: 7) == "Source camera 7")
    #expect(SourceStudioCameraLabel.reference(name: "Source camera 7", key: 7) == "7")
    #expect(SourceStudioCameraLabel.title(name: "Source camera 7", key: 8) == "Source camera 7 (camera 8)")
    #expect(SourceStudioCameraLabel.keyDetail(name: "IKKOKU-MIRROR", key: 2) == "camera 2")
    #expect(SourceStudioCameraLabel.keyDetail(name: "Source camera 7", key: 7) == nil)

    #expect(SourceStudioCameraLabel.fallbackReason(SourceStudioCameraObjectError.reflectedFrame("parent frame")) == "has a mirrored parent")
    #expect(SourceStudioCameraLabel.fallbackReason(SourceStudioCameraObjectError.reflectedFrame("world frame")) == "has a mirrored world frame")
    #expect(SourceStudioCameraLabel.fallbackReason(RigError.invalid("Missing Studio object.")).hasPrefix("cannot be placed ("))

    #expect(SourceStudioCameraLabel.indicator(name: "IKKOKU-CONTROL", key: 3, fallbackReason: nil)
        == "Viewing through source camera \"IKKOKU-CONTROL\" (camera 3) (runtime only)")
    #expect(SourceStudioCameraLabel.indicator(name: "IKKOKU-MIRROR", key: 2, fallbackReason: "has a mirrored parent")
        == "Saved camera shown: source camera \"IKKOKU-MIRROR\" (camera 2) has a mirrored parent")
    #expect(!SourceStudioCameraLabel.indicator(name: "IKKOKU-MIRROR", key: 2, fallbackReason: "has a mirrored parent").contains("Viewing through"))
}
