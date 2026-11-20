import Testing
import Foundation
import Studio
import Character
import CoreMath

/// #390: the undo policy `StudioModel.update` and `pushUndo` use. `History`
/// makes the same calls the model makes: an object edit snapshots the
/// document before writing the object back when `edit` says so, Undo moves
/// the current document to the redo stack and restores the last snapshot,
/// and Redo does the reverse. Undo ends the coalescing window (#448); Redo
/// needs no end, because the redo stack is non-empty only after an Undo. The
/// #448 tests below document that call sequence; the app's own calls are
/// covered by the studio lane's `undo-window-after-undo` scenario.
private struct History {
    var document: StudioDocument
    var steps = StudioUndoSteps()
    var undo: [StudioDocument] = []
    var redo: [StudioDocument] = []

    init(_ document: StudioDocument) { self.document = document }

    mutating func update(_ index: Int, at now: Date, _ change: (inout StudioObject) -> Void) {
        var object = document.objects[index]
        if steps.edit(&object, at: now, change) {
            undo.append(document)
            redo.removeAll()
        }
        document.objects[index] = object
    }

    mutating func undoStep() {
        guard let last = undo.popLast() else { return }
        redo.append(document)
        document = last
        steps.endCoalescing()
    }

    mutating func redoStep() {
        guard let next = redo.popLast() else { return }
        undo.append(document)
        document = next
    }
}

/// One fixed scene (its object ids are generated once).
private let base: StudioDocument = {
    var document = StudioDocument()
    var prop = StudioObject(name: "Prop", kind: .item)
    prop.transform.position = Float3(0.123456, 1, 2)
    prop.transform.rotationOverride = Float4(0, 0.2, 0, 0.9797959)
    document.objects = [StudioObject(name: "Folder", kind: .folder), prop]
    return document
}()

private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

private func bytes(_ document: StudioDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
}

@Test func studioUndoNoOpWritePushesNothing() {
    var history = History(base)
    history.update(1, at: t0) { $0.name = $0.name }
    history.update(1, at: t0 + 1) { $0.transform.position = $0.transform.position }
    #expect(history.undo.isEmpty)
    #expect(history.document == base)
    // The no-op did not open a window: a real edit right after it is a step.
    history.update(1, at: t0 + 1.1) { $0.name = "Renamed" }
    #expect(history.undo.count == 1)
}

@Test func studioUndoRealEditsApartAreTwoStepsAndInsideTheWindowOne() {
    var history = History(base)
    history.update(1, at: t0) { $0.name = "A" }
    history.update(1, at: t0 + 0.5) { $0.name = "B" }
    #expect(history.undo.map { $0.objects[1].name } == ["Prop", "A"])

    var coalesced = History(base)
    coalesced.update(1, at: t0) { $0.name = "A" }
    coalesced.update(1, at: t0 + 0.3) { $0.name = "B" }
    #expect(coalesced.undo.map { $0.objects[1].name } == ["Prop"])
    // The window is measured from the step's first edit, not the last one.
    coalesced.update(1, at: t0 + 0.45) { $0.name = "C" }
    #expect(coalesced.undo.map { $0.objects[1].name } == ["Prop", "B"])
    // A new gesture ends the window.
    coalesced.steps.endCoalescing()
    coalesced.update(1, at: t0 + 0.5) { $0.name = "D" }
    #expect(coalesced.undo.map { $0.objects[1].name } == ["Prop", "B", "C"])
    var forced = StudioUndoSteps()
    #expect(forced.startsStep(at: t0) && forced.startsStep(at: t0 + 0.1, force: true) && !forced.startsStep(at: t0 + 0.2))
}

/// #448: Undo ends the coalescing window. A real edit 0.2 s after the
/// undone step's first edit takes its own step, so it clears the redo stack,
/// and Undo then reverts only that edit. Before, the edit joined the undone
/// step: no snapshot, the redo stack kept, and Redo dropped the edit.
@Test func studioUndoAnEditInsideTheWindowAfterUndoIsItsOwnStep() {
    var history = History(base)
    let x = base.objects[1].transform.position.x
    history.update(1, at: t0) { $0.name = "A" }
    history.undoStep()
    #expect(history.document.objects[1].name == "Prop")
    #expect(history.redo.count == 1)
    history.update(1, at: t0 + 0.2) { $0.transform.position.x = 5 }
    #expect(history.undo.count == 1)
    #expect(history.redo.isEmpty)
    history.undoStep()
    #expect(history.document.objects[1].name == "Prop")
    #expect(history.document.objects[1].transform.position.x == x)
    #expect(history.undo.isEmpty)
}

/// #448: an edit 0.2 s after a Redo is its own step too, so Undo reverts
/// only that edit and keeps the redone rename. Before, it joined the rename's
/// step and Undo reverted both. The Undo before the Redo closed the window,
/// and nothing can start a step in between without clearing redo.
@Test func studioUndoAnEditInsideTheWindowAfterRedoIsItsOwnStep() {
    var history = History(base)
    let x = base.objects[1].transform.position.x
    history.update(1, at: t0) { $0.name = "A" }
    history.undoStep()
    history.redoStep()
    #expect(history.document.objects[1].name == "A")
    history.update(1, at: t0 + 0.2) { $0.transform.position.x = 5 }
    #expect(history.undo.count == 2)
    #expect(history.redo.isEmpty)
    history.undoStep()
    #expect(history.document.objects[1].name == "A")
    #expect(history.document.objects[1].transform.position.x == x)
}

/// The rename case of #390: the name binding writes "KR" twice, 0.5 s apart.
/// Before, the second write took a snapshot of "KR" and Undo restored "KR".
@Test func studioUndoRestoresTheNameAfterASecondIdenticalWrite() {
    var history = History(base)
    history.update(1, at: t0) { $0.name = "Prop R" }
    history.update(1, at: t0 + 0.5) { $0.name = "Prop R" }
    #expect(history.undo.count == 1)
    history.undoStep()
    #expect(history.document.objects[1].name == "Prop")
}

/// Real edits record exactly the snapshots the earlier policy recorded
/// (push before every write outside the window), byte for byte, and Undo and
/// Redo restore them.
@Test func studioUndoSnapshotsOfRealEditsAreUnchanged() throws {
    let edits: [(TimeInterval, (inout StudioObject) -> Void)] = [
        (0, { $0.name = "A" }),
        (0.1, { $0.transform.position.x = 0.123 }),
        (0.6, { $0.transform.rotation = Float3(0, 23, 0) }),
        (1.5, { $0.visible = false }),
        (1.7, { $0.locked = true }),
        (2.5, { $0.transform.scale = Float3(2, 2, 2) }),
    ]
    var history = History(base)
    var reference = base, referenceUndo: [StudioDocument] = [], last = Date.distantPast
    for (offset, change) in edits {
        let now = t0 + offset
        history.update(1, at: now, change)
        // The earlier StudioModel.update: pushUndo(), then the write.
        if now.timeIntervalSince(last) >= StudioUndoSteps.coalescingWindow {
            referenceUndo.append(reference)
            last = now
        }
        change(&reference.objects[1])
    }
    #expect(try bytes(history.document) == bytes(reference))
    #expect(try history.undo.map(bytes) == referenceUndo.map(bytes))
    #expect(history.undo.count == 4)
    let final = try bytes(history.document)
    for _ in 0..<history.undo.count { history.undoStep() }
    #expect(try bytes(history.document) == bytes(base))
    for _ in 0..<history.redo.count { history.redoStep() }
    #expect(try bytes(history.document) == final)
}

/// An inspector field commits only its own component, onto the object as it
/// is now (`StudioTransform.set`), so two fields committed before the
/// inspector re-renders keep both values, each its own step. The former
/// write, the vector the fields last showed with one component replaced, lost
/// the first.
@Test func studioTransformFieldCommitsKeepBothComponentsWithoutARender() {
    let shown = base.objects[1].transform
    let rows: [(StudioTransform.Vector, KeyPath<StudioTransform, Float3>)] = [(.position, \.position), (.rotation, \.rotation), (.scale, \.scale)]
    for (vector, path) in rows {
        var history = History(base)
        history.update(1, at: t0) { $0.transform.set(vector, 0, to: 0.5) }
        history.steps.endCoalescing()
        history.update(1, at: t0 + 0.1) { $0.transform.set(vector, 1, to: 0.25) }
        #expect(history.document.objects[1].transform[keyPath: path] == Float3(0.5, 0.25, shown[keyPath: path].z))
        #expect(history.undo.count == 2)
    }
    var former = base.objects[1].transform
    var written = shown.position; written.x = 0.5; former.position = written
    written = shown.position; written.y = 0.25; former.position = written
    #expect(former.position == Float3(shown.position.x, 0.25, shown.position.z))
}

/// #393: the Pose tab's IK "Target" row commits one component onto the
/// chain's target as it is now (`StudioObject.setIKTarget(_:component:to:)`),
/// so two fields committed before the inspector re-renders keep both, each
/// its own step. Committing the components the target already has is no
/// edit and takes no step. The former write, the target captured at the
/// render with one component replaced, lost the first field.
@Test func studioIKTargetFieldCommitsKeepBothComponentsWithoutARender() throws {
    var character = StudioObject(name: "Character", kind: .character)
    character.ikTargets[.handL] = IKTarget(enabled: true, position: Float3(0.3, 1.1, 0.2))
    var document = StudioDocument(); document.objects = [character]
    let shown = try #require(character.ikTargets[.handL]).position
    var history = History(document)
    history.update(0, at: t0) { $0.setIKTarget(.handL, component: 0, to: 0.5) }
    history.steps.endCoalescing()
    history.update(0, at: t0 + 0.1) { $0.setIKTarget(.handL, component: 1, to: 0.25) }
    #expect(history.document.objects[0].ikTargets[.handL]?.position == Float3(0.5, 0.25, shown.z))
    #expect(history.undo.count == 2)
    var former = character.ikTargets[.handL]!
    var written = shown; written.x = 0.5; former.position = written
    written = shown; written.y = 0.25; former.position = written
    #expect(former.position == Float3(shown.x, 0.25, shown.z))
    // An unedited walk over the three fields.
    var walk = History(document)
    for component in 0..<3 {
        walk.steps.endCoalescing()
        walk.update(0, at: t0 + Double(component)) { $0.setIKTarget(.handL, component: component, to: shown[component]) }
    }
    #expect(walk.document == document && walk.undo.isEmpty)
    // A chain without a target, and a component outside 0...2, are left alone.
    var other = History(document)
    other.update(0, at: t0) { $0.setIKTarget(.footR, component: 0, to: 1) }
    other.update(0, at: t0 + 1) { $0.setIKTarget(.handL, component: 3, to: 1) }
    #expect(other.document == document && other.undo.isEmpty)
}

/// #393: the Original kinematics Position and Rotate rows. Each field
/// writes one component onto the guide's value as it is when it commits
/// (`SourceStudioIKEdit.setting`). Two fields of one row, committed before
/// a re-render, keep both. A Position field does not write Rotate back from
/// the value the rows showed, and the reverse. An unedited walk returns the
/// value unchanged, which the model then does not write.
@Test func sourceIKGuideFieldCommitsKeepBothComponentsAndTheOtherRow() {
    let shown = SourceStudioIKEdit(position: Float3(0.1, 0.9, -0.2), rotationDegrees: Float3(10, 20, 30))
    // Position X then Y, with no re-render: the model reads the stored value each time.
    var stored = shown.setting(.position, 0, to: 0.5)
    stored = stored.setting(.position, 1, to: 0.25)
    #expect(stored == SourceStudioIKEdit(position: Float3(0.5, 0.25, -0.2), rotationDegrees: shown.rotationDegrees))
    // Rotate X then Z, likewise.
    stored = shown.setting(.rotation, 0, to: -5).setting(.rotation, 2, to: 90)
    #expect(stored == SourceStudioIKEdit(position: shown.position, rotationDegrees: Float3(-5, 20, 90)))
    // Rotate Y, then Position X: the rotation is kept.
    stored = shown.setting(.rotation, 1, to: 45).setting(.position, 0, to: 0.5)
    #expect(stored == SourceStudioIKEdit(position: Float3(0.5, 0.9, -0.2), rotationDegrees: Float3(10, 45, 30)))
    // Position X, then Rotate Y: the position is kept.
    stored = shown.setting(.position, 0, to: 0.5).setting(.rotation, 1, to: 45)
    #expect(stored == SourceStudioIKEdit(position: Float3(0.5, 0.9, -0.2), rotationDegrees: Float3(10, 45, 30)))
    // The former writes built each edit from the shown value: a Position
    // commit after a Rotate commit wrote the shown rotation back.
    var formerPosition = shown.position; formerPosition.x = 0.5
    let former = SourceStudioIKEdit(position: formerPosition, rotationDegrees: shown.rotationDegrees)
    #expect(former.rotationDegrees.y == 20)
    // An unedited walk over both rows, and components outside 0...2.
    var walked = shown
    for component in 0..<3 {
        walked = walked.setting(.position, component, to: shown.position[component])
        walked = walked.setting(.rotation, component, to: shown.rotationDegrees[component])
    }
    #expect(walked == shown)
    #expect(shown.setting(.position, 3, to: 1) == shown && shown.setting(.rotation, -1, to: 1) == shown)
}
