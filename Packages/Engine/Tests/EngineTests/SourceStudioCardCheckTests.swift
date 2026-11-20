import Foundation
import Testing
@testable import Studio

/// #432: the hidden card check's worker block holds the check, and the
/// check held the block until `problems()`, so a cancelled import leaked
/// it. The block now lets go when it finishes, and `cancel()` drops it
/// unrun. Each way a check ends frees it once its queue drains: a cancel
/// before the worker starts (the worker never runs), a worker that finishes
/// unasked, and `problems()`, which a commit asks before it can throw.
@Test func theHiddenCardCheckIsFreedHoweverItEnds() throws {
    let document = try KoikatsuSceneReader.decodeDocument(SceneDocumentBytes.scene().data)
    let character = try #require(document.snapshot.roots[0].character)
    for ending in ["cancel", "finished", "problems"] {
        let queue = DispatchQueue(label: "com.grabbiel.Ikkoku.tests.432")
        weak var freed: SourceStudioCharacterPreview.CardCheck?
        var checked: Bool?
        do {
            // Suspended, so that the cancel comes before the worker starts.
            if ending == "cancel" { queue.suspend() }
            let check = SourceStudioCharacterPreview.CardCheck(records: [character], queue: queue)
            freed = check
            switch ending {
            case "cancel":
                check.cancel()
                queue.resume()
                queue.sync {}
                checked = check.hasChecked
            case "problems": #expect(check.problems().count == 1)
            default: break
            }
        }
        // The worker, or its cancelled item, has gone through the queue.
        queue.sync {}
        #expect(freed == nil, "\(ending): the check outlived its queue")
        if ending == "cancel" { #expect(checked == false, "the cancelled worker ran") }
    }
}
