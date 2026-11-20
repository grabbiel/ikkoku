import Testing
import Renderer

// #459: the launch-time Studio execution inputs wait for the launch scene's
// background import and run exactly once.

@MainActor
@Test func launchInputsRunAtOnceWhenTheImportAlreadyEnded() {
    // A capture, scenario or headless launch: the import ended inside startup.
    var runs = 0
    let synchronous = LaunchInputGate(waitsForImport: true)
    #expect(synchronous.open() == .held)
    #expect(!synchronous.isWaiting)
    #expect(synchronous.run { runs += 1 } == .ran)
    #expect(runs == 1)
    // No launch scene at all.
    let none = LaunchInputGate(waitsForImport: false)
    #expect(none.run { runs += 1 } == .ran)
    #expect(runs == 2)
}

@MainActor
@Test func launchInputsWaitForTheBackgroundImportAndRunOnce() {
    var runs = 0
    let gate = LaunchInputGate(waitsForImport: true)
    #expect(gate.run { runs += 1 } == .held)
    #expect(gate.isHolding && runs == 0)
    #expect(gate.open() == .ran)
    #expect(runs == 1 && !gate.isHolding && !gate.isWaiting)
    // A second end, or more work, does not apply the inputs again.
    #expect(gate.open() == .ignored)
    #expect(gate.run { runs += 1 } == .ignored)
    #expect(gate.drop() == false)
    #expect(runs == 1)
}

@MainActor
@Test func launchInputsGivenTwiceRunTheFirstWorkOnly() {
    var first = 0, second = 0
    let gate = LaunchInputGate(waitsForImport: true)
    #expect(gate.run { first += 1 } == .held)
    #expect(gate.run { second += 1 } == .ignored)
    #expect(gate.open() == .ran)
    #expect(first == 1 && second == 0)
    // After the import ended, a second run is ignored too.
    let ended = LaunchInputGate(waitsForImport: true)
    ended.open()
    #expect(ended.run { first += 1 } == .ran)
    #expect(ended.run { second += 1 } == .ignored)
    #expect(first == 2 && second == 0)
}

@MainActor
@Test func droppedLaunchInputsNeverRun() {
    var runs = 0
    let held = LaunchInputGate(waitsForImport: true)
    held.run { runs += 1 }
    #expect(held.drop() == true)
    #expect(!held.isWaiting && !held.isHolding)
    // The cancelled import's end, if it still came, runs nothing; neither does more work.
    #expect(held.open() == .ignored)
    #expect(held.run { runs += 1 } == .ignored)
    #expect(held.drop() == false)
    // Dropped before the work was given.
    let early = LaunchInputGate(waitsForImport: true)
    #expect(early.drop() == true)
    #expect(early.run { runs += 1 } == .ignored)
    #expect(early.open() == .ignored)
    // Nothing to drop once the import ended or the work ran.
    let ended = LaunchInputGate(waitsForImport: true)
    ended.open()
    #expect(ended.drop() == false)
    #expect(ended.run { runs += 1 } == .ran)
    #expect(runs == 1)
}
