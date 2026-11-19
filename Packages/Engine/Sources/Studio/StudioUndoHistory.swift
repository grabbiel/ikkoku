import Foundation

/// The Studio editor's undo and redo steps (#384). Each step is a snapshot of
/// the document, the newest last, and the undo side keeps at most `limit`.
///
/// **Scene replacements.** A New Scene, an Open of an Ikkoku scene and an
/// import of an original scene each replace the whole document. They record
/// the replaced document as a step marked `replacingScene`. The next
/// replacement drops that marked step and every step before it, so Undo can
/// bring back the scene that was just replaced, with its own edits, but not
/// the scenes before it. Without this, a run of loads kept up to `limit / 2`
/// whole scenes alive: each Open decodes a fresh document that shares no
/// storage with the others (about 6 MB each for a 3,769-object scene).
///
/// A merge into the current scene (Import Scene, a layout import) and every
/// edit record unmarked steps, so they never trim.
///
/// Known difference from CharaStudio: the original clears its whole undo and
/// redo history whenever it starts a new scene or loads one (`InitScene`).
/// Ikkoku keeps one earlier scene on purpose.
///
/// The mark belongs to the change from a step to the state after it. Undo
/// carries it to the redo step it makes, and Redo carries it back, so a
/// replacement that is undone and redone is still the one the next
/// replacement trims. There is at most one mark in both stacks together.
///
/// **Scene generation (#410).** `sceneGeneration` counts the times the
/// document changed scene through the history: a replacement recorded, and
/// an Undo or Redo across a replacement's step. Edits, merges and Undo or
/// Redo within one scene leave it as it is. The workspace panel keys its
/// scroll view on it, so the lazy row list's per-row caches, which SwiftUI
/// and AppKit never prune, go with the scene they were built for.
public struct StudioUndoHistory<Document> {
    public static var limit: Int { 60 }

    public private(set) var undoStack: [Document] = []
    public private(set) var redoStack: [Document] = []
    /// Parallel to the stacks: whether the change from that step to the state
    /// after it replaced the scene.
    private var undoReplaces: [Bool] = []
    private var redoReplaces: [Bool] = []
    /// See **Scene generation** above. It wraps rather than traps.
    public private(set) var sceneGeneration: UInt64 = 0

    public init() {}

    /// Records `current` as the newest undo step and clears redo. With
    /// `replacingScene`, the previous replacement's step and everything
    /// before it go first. The trim and the append are one call, so a
    /// replacement that fails before it records leaves both stacks as they
    /// were.
    public mutating func record(_ current: Document, replacingScene: Bool = false) {
        if replacingScene, let mark = undoReplaces.lastIndex(of: true) {
            undoStack.removeSubrange(...mark)
            undoReplaces.removeSubrange(...mark)
        }
        undoStack.append(current)
        undoReplaces.append(replacingScene)
        if replacingScene { sceneGeneration &+= 1 }
        if undoStack.count > Self.limit {
            undoStack.removeFirst()
            undoReplaces.removeFirst()
        }
        redoStack.removeAll()
        redoReplaces.removeAll()
    }

    /// Undo: takes the newest undo step off and puts `current` on the redo
    /// side with that step's mark. Returns the step, or nil with nothing to
    /// undo.
    @discardableResult
    public mutating func stepBack(leaving current: Document) -> Document? {
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(current)
        let replaced = undoReplaces.removeLast()
        redoReplaces.append(replaced)
        if replaced { sceneGeneration &+= 1 }
        return step
    }

    /// Redo: the reverse of `stepBack`.
    @discardableResult
    public mutating func stepForward(leaving current: Document) -> Document? {
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(current)
        let replaced = redoReplaces.removeLast()
        undoReplaces.append(replaced)
        if replaced { sceneGeneration &+= 1 }
        return step
    }

    /// Which undo steps lead into a scene replacement (oldest first). Tests
    /// and diagnostics read it.
    public var undoReplacements: [Bool] { undoReplaces }
    public var redoReplacements: [Bool] { redoReplaces }
}

extension StudioUndoHistory: Sendable where Document: Sendable {}
