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
