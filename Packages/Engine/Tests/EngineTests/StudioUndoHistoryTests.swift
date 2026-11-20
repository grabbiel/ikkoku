import Testing
import Foundation
import Studio

/// #384: `StudioUndoHistory`, the undo and redo steps `StudioModel` keeps.
/// Documents are strings here: "A" is scene A as loaded, "A1" after its first
/// edit, "E" an empty scene. The model records the document as it is before a
/// change; a scene replacement (New Scene, Open, an original scene import)
/// records with `replacingScene`, a merge or an edit without it.
private struct Editor {
    var document: String
    var history = StudioUndoHistory<String>()

    init(_ document: String) { self.document = document }

    mutating func edit(_ next: String) { history.record(document); document = next }
    /// New Scene, Open or an original scene import.
    mutating func replace(with next: String) { history.record(document, replacingScene: true); document = next }
    /// Import Scene or a layout import: merges into the current scene.
    mutating func merge(into next: String) { history.record(document); document = next }
    @discardableResult mutating func undo() -> Bool {
        guard let step = history.stepBack(leaving: document) else { return false }
        document = step
        return true
    }
    @discardableResult mutating func redo() -> Bool {
        guard let step = history.stepForward(leaving: document) else { return false }
        document = step
        return true
    }
    /// Every document Undo can reach, newest first.
    mutating func undoAll() -> [String] {
        var seen: [String] = []
        while undo() { seen.append(document) }
        return seen
    }
    var marks: Int { (history.undoReplacements + history.redoReplacements).filter { $0 }.count }
}

@Test func loadCyclesKeepOneEarlierScene() {
    // The studio-load workload: the startup import, then New Scene and Open of
    // the same file, 100 times. Each Open is a fresh decode ("L1", "L2", ...).
    var editor = Editor("E")
    editor.replace(with: "L0")
    for cycle in 1...100 {
        editor.replace(with: "E")
        #expect(editor.history.undoStack == ["L\(cycle - 1)"])
        editor.replace(with: "L\(cycle)")
        #expect(editor.history.undoStack == ["E"])
        #expect(editor.history.undoReplacements == [true])
    }
    // Undo brings back the empty scene the last Open replaced, and no further.
    let reached1 = editor.undoAll()
    #expect(reached1 == ["E"])
}

@Test func undoOfANewSceneRestoresTheSceneWithItsEdits() {
    var editor = Editor("A")
    editor.edit("A1"); editor.edit("A2")
    editor.replace(with: "E")
    #expect(editor.history.undoStack == ["A", "A1", "A2"])
    let reached2 = editor.undoAll()
    #expect(reached2 == ["A2", "A1", "A"])
    // Redo walks back to the empty scene, and the mark comes back with it.
    while editor.redo() {}
    #expect(editor.document == "E")
    #expect(editor.history.undoReplacements == [false, false, true])
}

@Test func secondReplacementStopsAtThePreviousScene() {
    // Scene A with edits, New Scene, an edit there, Open of B: Undo reaches
    // the empty scene and its edit, not scene A.
    var editor = Editor("A")
    editor.edit("A1")
    editor.replace(with: "E")
    editor.edit("E1")
    editor.replace(with: "B")
    #expect(editor.history.undoStack == ["E", "E1"])
    let reached3 = editor.undoAll()
    #expect(reached3 == ["E1", "E"])
    let undoneFurther = editor.undo()
    #expect(!undoneFurther)
}

@Test func mergeKeepsEveryEarlierStep() {
    var editor = Editor("A")
    editor.edit("A1")
    editor.replace(with: "B")
    editor.edit("B1")
    // Import Scene into B: an ordinary step, nothing is dropped.
    editor.merge(into: "B1+C")
    #expect(editor.history.undoStack == ["A", "A1", "B", "B1"])
    #expect(editor.history.undoReplacements == [false, true, false, false])
    // A second merge still drops nothing.
    editor.merge(into: "B1+C+D")
    #expect(editor.history.undoStack.count == 5)
    // The next replacement drops A and its edits, and keeps B's steps, the merges included.
    editor.replace(with: "E")
    #expect(editor.history.undoStack == ["B", "B1", "B1+C", "B1+C+D"])
}

@Test func editsWithinOneSceneKeepEveryStepUpToTheLimit() {
    var editor = Editor("A")
    editor.replace(with: "B")
    for step in 1...(StudioUndoHistory<String>.limit + 10) { editor.edit("B\(step)") }
    // The limit drops the oldest steps, the replaced scene's mark with them.
    #expect(editor.history.undoStack.count == StudioUndoHistory<String>.limit)
    #expect(editor.history.undoStack.first == "B10")
    #expect(editor.history.undoReplacements.count == editor.history.undoStack.count)
    #expect(editor.marks == 0)
    // With no mark left, the next replacement drops nothing.
    editor.replace(with: "C")
    #expect(editor.history.undoStack.count == StudioUndoHistory<String>.limit)
    #expect(editor.history.undoStack.last == "B70")
}

@Test func undoneAndRedoneReplacementIsTheOneTheNextTrims() {
    var editor = Editor("A")
    editor.edit("A1")
    editor.replace(with: "B")
    editor.undo(); editor.redo()
    #expect(editor.document == "B")
    editor.edit("B1")
    editor.replace(with: "C")
    #expect(editor.history.undoStack == ["B", "B1"])
}

@Test func replacementAfterUndoingOneKeepsTheSceneItReplaces() {
    // New Scene over A, undo it (back in A), then Open B: B replaces A, so A
    // and its edits stay; the undone New Scene's empty scene was on the redo
    // side and goes with it.
    var editor = Editor("A")
    editor.edit("A1")
    editor.replace(with: "E")
    editor.undo()
    #expect(editor.document == "A1")
    editor.replace(with: "B")
    #expect(editor.history.undoStack == ["A", "A1"])
    #expect(editor.history.redoStack.isEmpty)
    #expect(editor.history.undoReplacements == [false, true])
}

@Test func randomHistoriesKeepAtMostOneMarkAndStepsInverse() {
    // Seeded walks over edits, merges, replacements, undo and redo: the marks
    // stay parallel to the stacks, there is never more than one, the undo side
    // stays within the limit, and Undo followed by Redo restores both stacks.
    for seed in 1...200 {
        var random = SplitMix(seed: UInt64(seed))
        var editor = Editor("S0")
        for step in 0..<400 {
            switch random.next() % 10 {
            case 0...3: editor.edit("e\(step)")
            case 4: editor.merge(into: "m\(step)")
            case 5: editor.replace(with: "r\(step)")
            case 6...7: editor.undo()
            default: editor.redo()
            }
            #expect(editor.history.undoReplacements.count == editor.history.undoStack.count)
            #expect(editor.history.redoReplacements.count == editor.history.redoStack.count)
            #expect(editor.marks <= 1)
            #expect(editor.history.undoStack.count <= StudioUndoHistory<String>.limit)
        }
        let (undo, redo, document) = (editor.history.undoStack, editor.history.redoStack, editor.document)
        if editor.undo() {
            editor.redo()
            #expect(editor.history.undoStack == undo && editor.history.redoStack == redo && editor.document == document)
        }
    }
}

// MARK: - Patch steps (#446)

extension String: StudioHistoryDocument {}

/// Today's history for the patch tests: every step a whole document.
private struct Whole: StudioHistoryDocument, Equatable { var document: StudioDocument }

private func folders(_ count: Int) -> StudioDocument {
    var document = StudioDocument()
    document.objects = (0..<count).map { StudioObject(name: "o\($0)", kind: .folder) }
    return document
}

/// One document edited through a patch history and through a whole-snapshot
/// history (today's), with the recording rules `StudioModel` follows: an
/// object edit that starts a step records a patch, one coalesced into the
/// open step updates the newest patches, a whole-document step records the
/// document, and a direct write no step records first materializes the
/// newest patches.
private struct Pair {
    var document: StudioDocument
    var shadow: StudioDocument
    var history = StudioUndoHistory<StudioDocument>()
    var whole = StudioUndoHistory<Whole>()

    init(_ document: StudioDocument) { self.document = document; shadow = document }

    var same: Bool { document == shadow }

    mutating func editObject(_ index: Int, startsStep: Bool, _ change: (inout StudioObject) -> Void) {
        let before = document.objects[index]
        if startsStep {
            history.record(patch: StudioObjectPatch(document, before: before))
            whole.record(Whole(document: shadow))
        } else {
            history.updateNewestPatches { $0.add(before) }
        }
        change(&document.objects[index]); change(&shadow.objects[index])
    }

    /// `change` runs once on each document, so it must not make new ids.
    mutating func documentStep(replacingScene: Bool = false, _ change: (inout StudioDocument) -> Void) {
        history.record(document, replacingScene: replacingScene)
        whole.record(Whole(document: shadow), replacingScene: replacingScene)
        change(&document); change(&shadow)
    }

    /// A coalesced whole-document change or a direct write inside the open
    /// step: no new step.
    @discardableResult
    mutating func directWrite(_ change: (inout StudioDocument) -> Void) -> StudioUndoMaterialization {
        let result = history.materializeNewestPatches(from: document)
        change(&document); change(&shadow)
        return result
    }

    /// A change to a field other than the objects with no step (a load-time
    /// diagnostics line): the patch's other fields cover it as a snapshot
    /// would.
    mutating func unrecordedField(_ change: (inout StudioDocument) -> Void) { change(&document); change(&shadow) }

    @discardableResult mutating func undo() -> Bool {
        let expected = whole.stepBack(leaving: Whole(document: shadow))
        guard case .document(let target)? = history.undoTarget(from: document) else {
            #expect(expected == nil); return false
        }
        history.popBack(leaving: document)
        document = target
        shadow = expected?.document ?? shadow
        return expected != nil
    }

    @discardableResult mutating func redo() -> Bool {
        let expected = whole.stepForward(leaving: Whole(document: shadow))
        guard case .document(let target)? = history.redoTarget(from: document) else {
            #expect(expected == nil); return false
        }
        history.popForward(leaving: document)
        document = target
        shadow = expected?.document ?? shadow
        return expected != nil
    }

    /// The bookkeeping matches today's: depths, marks, and the documents an
    /// undo and a redo would restore.
    var agrees: Bool {
        guard history.undoDepth == whole.undoStack.count, history.redoDepth == whole.redoStack.count,
              history.undoReplacements == whole.undoReplacements, history.redoReplacements == whole.redoReplacements else { return false }
        if case .document(let d)? = history.undoTarget(from: document), d != whole.undoStack.last?.document { return false }
        if case .document(let d)? = history.redoTarget(from: document), d != whole.redoStack.last?.document { return false }
        return true
    }
}

@Test func patchStepsRestoreWhatWholeSnapshotsWould() {
    // Seeded walks over object edits (each starting a step or coalesced into
    // the open one, anywhere: after an undo too), whole-document steps
    // (add, delete, scene replacement), direct writes inside the open step,
    // unrecorded field changes, undo and redo. After every action the
    // document, the depths, the marks and both targets equal today's.
    for seed in 1...150 {
        var random = SplitMix(seed: UInt64(seed))
        var pair = Pair(folders(6))
        var added = 0
        for step in 0..<300 {
            let count = pair.document.objects.count
            let index = count == 0 ? 0 : Int(random.next() % UInt64(count))
            switch random.next() % 16 {
            case 0...3 where count > 0: pair.editObject(index, startsStep: true) { $0.transform.position.x += 1 }
            case 4...6 where count > 0: pair.editObject(index, startsStep: false) { $0.name += "c" }
            case 7:
                added += 1
                let object = StudioObject(name: "a\(added)", kind: .item)
                pair.documentStep { $0.objects.append(object) }
            case 8 where count > 1: pair.documentStep { $0.objects.remove(at: index) }
            case 9 where random.next() % 4 == 0:
                let scene = folders(3 + step % 4)
                pair.documentStep(replacingScene: true) { $0 = scene }
            case 10 where count > 0: pair.directWrite { $0.objects[index].visible.toggle(); $0.camera.distance += 0.25 }
            case 11: pair.unrecordedField { $0.sourcePreviewDiagnostics = ($0.sourcePreviewDiagnostics ?? []) + ["d\(step)"] }
            case 12...13: pair.undo()
            case 14...15: pair.redo()
            default: break
            }
            #expect(pair.same, "seed \(seed) step \(step): the document differs from today's")
            #expect(pair.agrees, "seed \(seed) step \(step): the history differs from today's")
            #expect((pair.history.undoReplacements + pair.history.redoReplacements).filter { $0 }.count <= 1)
            #expect(pair.history.undoDepth <= StudioUndoHistory<StudioDocument>.limit)
            if !pair.same { break }
        }
        // Undo all, then redo all: every document on the way equals today's.
        while pair.undo() { #expect(pair.same) }
        while pair.redo() { #expect(pair.same) }
    }
}

@Test func aCoalescedEditAfterUndoRevertsInBothDirections() {
    // #446 amendment A, case 1 and 2. Edit A, edit B, Undo, then an edit of X
    // inside the 0.4 s window (coalesced: no step, redo kept). The older
    // patch (A) and the redo patch (B) both lack X. Undo must still restore
    // X's old value, and so must the original Redo, as whole snapshots do.
    var pair = Pair(folders(3))
    let x = pair.document.objects[2].id
    pair.editObject(0, startsStep: true) { $0.name = "A" }
    pair.editObject(1, startsStep: true) { $0.name = "B" }
    pair.undo()
    pair.editObject(2, startsStep: false) { $0.name = "X" }
    #expect(pair.same && pair.agrees)
    pair.undo()
    #expect(pair.document.object(x)?.name == "o2")
    #expect(pair.same && pair.agrees)
    pair.redo()
    #expect(pair.document.object(x)?.name == "X")
    #expect(pair.same && pair.agrees)
    pair.redo()
    #expect(pair.document.object(x)?.name == "o2")
    #expect(pair.document.objects.map(\.name) == ["A", "B", "o2"])
    #expect(pair.same && pair.agrees)
}

@Test func aCoalescedEditAfterUndoingAWholeStepReachesOnlyTheRedoPatch() {
    // The newest undo step is a whole document (an add) and already holds
    // X's old value; the newest redo step is a patch and gets it.
    var pair = Pair(folders(2))
    let added = StudioObject(name: "n", kind: .item)
    pair.documentStep { $0.objects.append(added) }
    pair.editObject(0, startsStep: true) { $0.name = "A" }
    pair.undo()
    pair.editObject(1, startsStep: false) { $0.name = "X" }
    #expect(pair.history.redoSteps.last.map { if case .patch(let p) = $0 { p.before.count } else { -1 } } == 2)
    pair.undo()
    #expect(pair.document.objects.map(\.name) == ["o0", "o1"])
    #expect(pair.same && pair.agrees)
    pair.redo(); pair.redo()
    #expect(pair.document.objects.map(\.name) == ["A", "o1", "n"])
    #expect(pair.same && pair.agrees)
}

@Test func aDirectWriteInsideTheOpenStepIsRevertedAsBySnapshots() {
    // #446 2.3: a coalesced whole-document step or a direct write inside a
    // patch's window turns the newest patches into whole documents first.
    var pair = Pair(folders(3))
    pair.editObject(0, startsStep: true) { $0.name = "A" }
    pair.directWrite { $0.objects[1].visible = false; $0.objects.remove(at: 2) }
    #expect(pair.history.undoSteps.last.map { if case .document = $0 { true } else { false } } == true)
    pair.undo()
    #expect(pair.document == folders(3).withIDs(of: pair.document))
    #expect(pair.same && pair.agrees)
    pair.redo()
    #expect(pair.document.objects.map(\.name) == ["A", "o1"] && pair.document.objects[1].visible == false)
    #expect(pair.same && pair.agrees)
}

@Test func aPatchIsConvertedOnceHoweverManyUnrecordedWritesFollow() {
    // A plug-in tick or an animation write can run every frame. Only the
    // first write after an edit converts the edit's patch; the writes after
    // it find a whole document, so 100 writes cost one conversion, and Undo
    // still reverts all of them as a snapshot would.
    var pair = Pair(folders(4))
    pair.editObject(1, startsStep: true) { $0.name = "edited" }
    var conversions = 0
    for frame in 0..<100 { conversions += pair.directWrite { $0.objects[2].transform.position.x = Float(frame) }.converted }
    #expect(conversions == 1)
    #expect(pair.same && pair.agrees)
    // The next edit records a new patch, and the next run of writes converts
    // that one once.
    pair.editObject(3, startsStep: true) { $0.visible = false }
    conversions = 0
    for frame in 0..<100 { conversions += pair.directWrite { $0.objects[0].transform.position.y = Float(frame) }.converted }
    #expect(conversions == 1)
    pair.undo(); #expect(pair.same && pair.agrees)
    pair.undo(); #expect(pair.same && pair.agrees)
    pair.redo(); pair.redo(); #expect(pair.same && pair.agrees)

    // An undo between two patch edits leaves a patch on each side: the
    // writes after it convert each of them once.
    var two = Pair(folders(4))
    two.editObject(0, startsStep: true) { $0.name = "first" }
    two.editObject(1, startsStep: true) { $0.name = "second" }
    two.undo()
    conversions = 0
    for frame in 0..<100 { conversions += two.directWrite { $0.objects[2].transform.position.z = Float(frame) }.converted }
    #expect(conversions == 2)
    #expect(two.same && two.agrees)
    two.redo(); #expect(two.same && two.agrees)
    two.undo(); two.undo(); #expect(two.same && two.agrees)
    // A history with no patch converts nothing.
    var whole = Pair(folders(2))
    whole.documentStep { $0.objects[0].name = "whole" }
    #expect(whole.directWrite { $0.objects[1].visible = false } == StudioUndoMaterialization())
}

@Test func aSceneReplacementInTheMiddleOfTheHistory() {
    // [P1: a patch on scene A, D2: scene A before New Scene, marked], with the
    // empty scene current. Undo D2 gives scene A after P1, Undo P1 the scene
    // as loaded, and Redo walks back to the empty scene.
    var pair = Pair(folders(2))
    let loaded = pair.document
    pair.editObject(1, startsStep: true) { $0.name = "P1" }
    let edited = pair.document
    pair.documentStep(replacingScene: true) { $0 = StudioDocument() }
    #expect(pair.history.undoReplacements == [false, true])
    pair.undo(); #expect(pair.document == edited && pair.same)
    pair.undo(); #expect(pair.document == loaded && pair.same)
    #expect(pair.history.redoReplacements == [true, false])
    pair.redo(); #expect(pair.document == edited && pair.same)
    pair.redo(); #expect(pair.document == StudioDocument() && pair.same && pair.agrees)
    // The next replacement trims through the carried mark, as today.
    let next = folders(1)
    pair.documentStep(replacingScene: true) { $0 = next }
    #expect(pair.history.undoReplacements == [true] && pair.agrees)
}

@Test func anObjectEditWritesTheObjectListInPlace() {
    // The reason for patch steps: once the step is recorded, nothing else
    // holds the document's object list, so the edit's write does not copy it.
    // The same holds for an edit coalesced into the step and for the first
    // edit after an undo.
    var document = folders(32)
    var history = StudioUndoHistory<StudioDocument>()
    func base(_ document: StudioDocument) -> UnsafeRawPointer? { document.objects.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
    let start = base(document)
    history.record(patch: StudioObjectPatch(document, before: document.objects[3]))
    document.objects[3].name = "edited"
    #expect(base(document) == start)
    history.updateNewestPatches { $0.add(document.objects[5]) }
    document.objects[5].transform.position.y = 2
    #expect(base(document) == start)
    // As in `StudioModel.undo()`, the target is not held past the undo.
    func undo() {
        guard case .document(let target)? = history.undoTarget(from: document) else { Issue.record("no undo target"); return }
        history.popBack(leaving: document)
        document = target
    }
    undo()
    let afterUndo = base(document)
    history.record(patch: StudioObjectPatch(document, before: document.objects[7]))
    document.objects[7].visible = false
    #expect(base(document) == afterUndo)
}

@Test func aBrokenPatchIsReportedNeverRestoredInPart() {
    // A patch that names an object the document lacks is a bug. Release
    // refuses it: no target, the step stays until the caller drops it, and
    // materializing drops it. The Debug assertion is off for this task.
    StudioUndoDiagnostics.$assertsOnBrokenSteps.withValue(false) {
        var document = folders(3)
        var history = StudioUndoHistory<StudioDocument>()
        history.record(patch: StudioObjectPatch(document, before: document.objects[2]))
        document.objects[0].name = "kept"
        document.objects.remove(at: 2)   // a write no step covered: the bug
        #expect(history.undoTarget(from: document) == .broken)
        #expect(history.stepBack(leaving: document) == nil)
        #expect(history.undoDepth == 1 && history.redoDepth == 0)
        history.dropNewestUndo()
        #expect(history.undoDepth == 0 && history.undoTarget(from: document) == nil)
        history.record(patch: StudioObjectPatch(document, before: document.objects[1]))
        document.objects.remove(at: 1)
        #expect(history.materializeNewestPatches(from: document) == StudioUndoMaterialization(droppedUndo: true))
        #expect(history.undoDepth == 0 && history.undoReplacements.isEmpty)
    }
}

@Test func forEachObjectReachesEveryObjectAnUndoCanRestore() {
    var document = folders(3)
    var history = StudioUndoHistory<StudioDocument>()
    history.record(document)
    let added = StudioObject(name: "n", kind: .item)
    document.objects.append(added)
    history.record(patch: StudioObjectPatch(document, before: document.objects[3]))
    document.objects[3].name = "renamed"
    _ = history.stepBack(leaving: document)
    var names: [String] = []
    history.forEachObject { names.append($0.name) }
    // The whole step's three folders, then the redo patch's renamed object.
    #expect(names == ["o0", "o1", "o2", "renamed"])
}

private extension StudioDocument {
    /// `self` with the ids of `other`'s objects, by position (folders(n)
    /// makes fresh ids on each call).
    func withIDs(of other: StudioDocument) -> StudioDocument {
        var copy = self
        for index in copy.objects.indices where index < other.objects.count { copy.objects[index].id = other.objects[index].id }
        return copy
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
