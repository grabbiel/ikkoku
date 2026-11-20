import Foundation

/// The Studio editor's undo and redo steps (#384). Each step is a snapshot of
/// the document or a patch of it (#446), the newest last, and the undo side
/// keeps at most `limit`.
///
/// **Patch steps (#446).** A step can hold only what its change touched
/// (`StudioHistoryDocument.Patch`): for a Studio object edit, the objects
/// before the edit and the document's other fields. Undo and Redo
/// materialize it against the current document (`undoTarget(from:)`), which
/// gives exactly the document a whole snapshot would. That holds because the
/// history is linear: a step is only undone from the state right after its
/// change, since every newer step was undone first, and a change no step
/// records reaches the newest patch of each side
/// (`updateNewestPatches(_:)`) or turns it into a whole snapshot first
/// (`materializeNewestPatches(from:)`). A patch that names something the
/// current document lacks is a bug: `undoTarget(from:)` reports it as
/// `.broken`, never a partial document.
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
/// A document the history can keep as patch steps (#446). `Patch` is what a
/// step holds instead of the whole document; with `Never`, the default, every
/// step is a whole document.
public protocol StudioHistoryDocument {
    associatedtype Patch = Never
    /// The document that `patch`'s step restores, from `self` as the state
    /// right after that step's change. Nil when `self` lacks something the
    /// patch names (a broken history).
    func restoring(_ patch: Patch) -> Self?
    /// The patch leading from `restoring(patch)` back to `self`. Called only
    /// once `restoring(patch)` gave a document.
    func inverse(of patch: Patch) -> Patch
}

extension StudioHistoryDocument where Patch == Never {
    public func restoring(_ patch: Never) -> Self? { switch patch {} }
    public func inverse(of patch: Never) -> Never { switch patch {} }
}

/// One undo or redo step: the whole document before the change, or a patch.
public enum StudioUndoStep<Document: StudioHistoryDocument> {
    case document(Document)
    case patch(Document.Patch)
}

extension StudioUndoStep: Equatable where Document: Equatable, Document.Patch: Equatable {}
extension StudioUndoStep: Sendable where Document: Sendable, Document.Patch: Sendable {}

/// What an undo or redo would restore.
public enum StudioUndoTarget<Document> {
    case document(Document)
    /// The step names something the current document lacks (a bug: the
    /// caller refuses the undo or redo and drops the step).
    case broken
}

extension StudioUndoTarget: Equatable where Document: Equatable {}

public enum StudioUndoDiagnostics {
    /// Whether a broken step stops a Debug build with an assertion. Tests of
    /// the Release path turn it off for their task.
    @TaskLocal public static var assertsOnBrokenSteps = true
}

public struct StudioUndoHistory<Document: StudioHistoryDocument> {
    public typealias Step = StudioUndoStep<Document>
    public static var limit: Int { 60 }

    public private(set) var undoSteps: [Step] = []
    public private(set) var redoSteps: [Step] = []
    /// Parallel to the stacks: whether the change from that step to the state
    /// after it replaced the scene.
    private var undoReplaces: [Bool] = []
    private var redoReplaces: [Bool] = []

    public init() {}

    public var undoDepth: Int { undoSteps.count }
    public var redoDepth: Int { redoSteps.count }

    /// Records `current` as the newest undo step and clears redo. With
    /// `replacingScene`, the previous replacement's step and everything
    /// before it go first. The trim and the append are one call, so a
    /// replacement that fails before it records leaves both stacks as they
    /// were.
    public mutating func record(_ current: Document, replacingScene: Bool = false) {
        append(.document(current), replacingScene: replacingScene)
    }

    /// Records `patch` (the change from it to the current document) as the
    /// newest undo step and clears redo. A patch step is never a scene
    /// replacement.
    public mutating func record(patch: Document.Patch) {
        append(.patch(patch), replacingScene: false)
    }

    private mutating func append(_ step: Step, replacingScene: Bool) {
        if replacingScene, let mark = undoReplaces.lastIndex(of: true) {
            undoSteps.removeSubrange(...mark)
            undoReplaces.removeSubrange(...mark)
        }
        undoSteps.append(step)
        undoReplaces.append(replacingScene)
        if undoSteps.count > Self.limit {
            undoSteps.removeFirst()
            undoReplaces.removeFirst()
        }
        redoSteps.removeAll()
        redoReplaces.removeAll()
    }

    /// The document Undo would restore from `current`, nil with nothing to
    /// undo.
    public func undoTarget(from current: Document) -> StudioUndoTarget<Document>? {
        undoSteps.last.map { Self.target(of: $0, from: current) }
    }

    /// The document Redo would restore from `current`, nil with nothing to
    /// redo.
    public func redoTarget(from current: Document) -> StudioUndoTarget<Document>? {
        redoSteps.last.map { Self.target(of: $0, from: current) }
    }

    private static func target(of step: Step, from current: Document) -> StudioUndoTarget<Document> {
        switch step {
        case .document(let document): return .document(document)
        case .patch(let patch):
            if let document = current.restoring(patch) { return .document(document) }
            assert(!StudioUndoDiagnostics.assertsOnBrokenSteps, "A Studio undo step names an object the document lacks (#446).")
            return .broken
        }
    }

    /// The step that leads from the document `step` restores back to
    /// `current`: `current` itself for a whole document, else the patch's
    /// inverse.
    private static func returning(to current: Document, from step: Step) -> Step {
        switch step {
        case .document: return .document(current)
        case .patch(let patch): return .patch(current.inverse(of: patch))
        }
    }

    /// Undo's bookkeeping: takes the newest undo step off and puts the step
    /// back to `current` on the redo side, with that step's mark. `current`
    /// is the document before the undo replaces it, and `undoTarget(from:)`
    /// gave a document for it. Returns false with nothing to undo.
    @discardableResult
    public mutating func popBack(leaving current: Document) -> Bool {
        guard let step = undoSteps.popLast() else { return false }
        redoSteps.append(Self.returning(to: current, from: step))
        redoReplaces.append(undoReplaces.removeLast())
        return true
    }

    /// Redo's bookkeeping: the reverse of `popBack`.
    @discardableResult
    public mutating func popForward(leaving current: Document) -> Bool {
        guard let step = redoSteps.popLast() else { return false }
        undoSteps.append(Self.returning(to: current, from: step))
        undoReplaces.append(redoReplaces.removeLast())
        return true
    }

    /// Undo: the target and the bookkeeping in one call. Returns the
    /// document to restore, or nil with nothing to undo or a broken step
    /// (left in place).
    @discardableResult
    public mutating func stepBack(leaving current: Document) -> Document? {
        guard case .document(let target)? = undoTarget(from: current) else { return nil }
        popBack(leaving: current)
        return target
    }

    /// Redo: the reverse of `stepBack`.
    @discardableResult
    public mutating func stepForward(leaving current: Document) -> Document? {
        guard case .document(let target)? = redoTarget(from: current) else { return nil }
        popForward(leaving: current)
        return target
    }

    /// Drops the newest undo step and its mark (a broken step the caller
    /// refused).
    public mutating func dropNewestUndo() {
        guard !undoSteps.isEmpty else { return }
        undoSteps.removeLast(); undoReplaces.removeLast()
    }

    /// Drops the newest redo step and its mark.
    public mutating func dropNewestRedo() {
        guard !redoSteps.isEmpty else { return }
        redoSteps.removeLast(); redoReplaces.removeLast()
    }

    /// A change no step records (an edit coalesced into the open step):
    /// `body` updates the newest undo step and the newest redo step, each
    /// only when it is a patch, so that it restores what the change touched
    /// as a whole snapshot would. A whole document already does.
    public mutating func updateNewestPatches(_ body: (inout Document.Patch) -> Void) {
        if case .patch(var patch)? = undoSteps.last {
            body(&patch)
            undoSteps[undoSteps.count - 1] = .patch(patch)
        }
        if case .patch(var patch)? = redoSteps.last {
            body(&patch)
            redoSteps[redoSteps.count - 1] = .patch(patch)
        }
    }

    /// Before a change no step records and no patch can describe (a
    /// coalesced whole-document step, a direct write): turns the newest undo
    /// step and the newest redo step, when they are patches, into the whole
    /// documents they restore from `current`, so the change is reverted as
    /// by a snapshot. A broken one is dropped. Returns how many were.
    @discardableResult
    public mutating func materializeNewestPatches(from current: Document) -> Int {
        var dropped = 0
        if case .patch? = undoSteps.last {
            switch Self.target(of: undoSteps[undoSteps.count - 1], from: current) {
            case .document(let document): undoSteps[undoSteps.count - 1] = .document(document)
            case .broken: dropNewestUndo(); dropped += 1
            }
        }
        if case .patch? = redoSteps.last {
            switch Self.target(of: redoSteps[redoSteps.count - 1], from: current) {
            case .document(let document): redoSteps[redoSteps.count - 1] = .document(document)
            case .broken: dropNewestRedo(); dropped += 1
            }
        }
        return dropped
    }

    /// Which undo steps lead into a scene replacement (oldest first). Tests
    /// and diagnostics read it.
    public var undoReplacements: [Bool] { undoReplaces }
    public var redoReplacements: [Bool] { redoReplaces }
}

extension StudioUndoHistory where Document.Patch == Never {
    /// The whole documents, oldest first (a history with no patch steps).
    public var undoStack: [Document] { undoSteps.map(Self.document) }
    public var redoStack: [Document] { redoSteps.map(Self.document) }
    private static func document(_ step: Step) -> Document {
        switch step {
        case .document(let document): return document
        case .patch(let patch): switch patch {}
        }
    }
}

extension StudioUndoHistory: Sendable where Document: Sendable, Document.Patch: Sendable {}

/// A Studio object edit's undo step (#446): the objects it changed, as they
/// were before it, and the document's other fields. Restoring it puts those
/// objects back by id into the current object list and takes every other
/// field from the step, as a whole snapshot would. The step holds no
/// reference to the document's object list, so the edit after it writes the
/// list in place.
public struct StudioObjectPatch: Sendable, Equatable {
    /// The document's fields other than its objects, as the step holds
    /// them. Its object list is empty.
    public private(set) var rest: StudioDocument
    /// The objects the step restores, each id once, in the order they were
    /// first changed.
    public private(set) var before: [StudioObject]

    /// The step for a change to `object` (as it is in `document`, before the
    /// change).
    public init(_ document: StudioDocument, before object: StudioObject) {
        self.init(rest: document, before: [object])
    }

    public init(rest document: StudioDocument, before objects: [StudioObject]) {
        var rest = document
        rest.objects = []
        self.rest = rest
        var seen = Set<UUID>()
        before = objects.filter { seen.insert($0.id).inserted }
    }

    public func contains(_ id: UUID) -> Bool { before.contains { $0.id == id } }

    /// Adds `object` (as it is before a change) unless the step already
    /// holds its id, whose older value is the one to restore.
    public mutating func add(_ object: StudioObject) {
        if !contains(object.id) { before.append(object) }
    }
}

extension StudioDocument: StudioHistoryDocument {
    public typealias Patch = StudioObjectPatch

    public func restoring(_ patch: StudioObjectPatch) -> StudioDocument? {
        var result = patch.rest
        result.objects = objects
        // By id, at the first object with it (as `index(of:)`), in one walk.
        var pending = [UUID: StudioObject](minimumCapacity: patch.before.count)
        for object in patch.before { pending[object.id] = object }
        var index = 0
        while !pending.isEmpty, index < result.objects.count {
            if let object = pending.removeValue(forKey: result.objects[index].id) { result.objects[index] = object }
            index += 1
        }
        return pending.isEmpty ? result : nil
    }

    public func inverse(of patch: StudioObjectPatch) -> StudioObjectPatch {
        var wanted = Set(patch.before.map(\.id))
        var current = [UUID: StudioObject](minimumCapacity: wanted.count)
        for object in objects where wanted.remove(object.id) != nil {
            current[object.id] = object
            if wanted.isEmpty { break }
        }
        return StudioObjectPatch(rest: self, before: patch.before.compactMap { current[$0.id] })
    }
}

extension StudioUndoHistory where Document == StudioDocument {
    /// Every object an undo or redo can bring back: the objects of each whole
    /// document step and each patch step's objects.
    public func forEachObject(_ body: (StudioObject) -> Void) {
        for step in undoSteps + redoSteps {
            switch step {
            case .document(let document): document.objects.forEach(body)
            case .patch(let patch): patch.before.forEach(body)
            }
        }
    }
}
