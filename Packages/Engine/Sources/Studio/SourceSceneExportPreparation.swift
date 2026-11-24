import Foundation
import CryptoKit
import Renderer
import Scene

/// #462, #350: the part of an original-scene export that reads only the
/// document and the original scene file. File ▸ Export Edited Original
/// Scene runs it on a decode-stack thread (`start`), so the Studio's main
/// thread keeps only the part that reads the model: the comparison of the
/// document with the records, the thumbnail, the writer and the write
/// (`StudioModel.exportSourceScene`). A synchronous export runs it in line.
public enum SourceSceneExportPreparation {
    /// The largest original scene an export reads.
    public static let maximumSceneBytes = 256 * 1024 * 1024

    /// What an export writes from besides the model, read and checked here.
    public struct Prepared: Sendable {
        /// The original scene, decoded once its SHA-256 matched.
        public let source: KoikatsuSceneDocument
        /// The scene with the document's copies and new objects written,
        /// and every document object's record key
        /// (`SourceSceneExportValidation.stage`).
        public let staged: SourceSceneExportValidation.Staged
        /// The records the document deletes and moves
        /// (`SourceSceneExportValidation.topologyEdits`).
        public let deletions: Set<Int32>
        public let reparents: [SourceSceneEdits.Reparent]
        /// The scene's plug-in entries no installed plug-in reads, which the
        /// export carries verbatim (`KoikatsuSceneDocument.orphanPluginIDs`).
        public let orphanPluginIDs: [String]
        /// Each character with no preview's animation state at the export's
        /// clock, by object (`SourceStudioAnimationClock.savedStates`).
        public let clockStates: [UUID: Result<SourceStudioAnimationState?, Error>]
    }

    /// Reads `sceneFile` (at most `maximumSceneBytes`) and checks its
    /// SHA-256 against `sha256` before anything decodes it. Then it decodes
    /// the scene, finds its orphan plug-in entries, stages and validates
    /// `document` against it, refuses native lighting, effects and timeline
    /// edits, derives the topology edits, and computes `clockRequests`'
    /// states at `elapsed` from the decoded scene. Each step throws the
    /// error the export reports, in this order. Pure: it reads the file and
    /// `clock`'s caches and changes nothing.
    public static func prepare(document: StudioDocument, sceneFile: String, sha256: String,
                               clock: SourceStudioAnimationClock,
                               clockRequests: [(id: UUID, request: SourceStudioAnimationClock.Request)],
                               elapsed: Float) throws -> Prepared {
        let bytes: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: sceneFile)); defer { try? handle.close() }
            bytes = try handle.read(upToCount: maximumSceneBytes + 1) ?? Data()
        }
        guard bytes.count <= maximumSceneBytes, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw RigError.invalid("The original scene changed; reimport before exporting edits.")
        }
        let source = try KoikatsuSceneReader.decodeDocument(bytes)
        let orphans = SourceScenePluginData.orphanPluginIDs(trailer: source.trailingData)
        let staged = try SourceSceneExportValidation.stage(document, source: source)
        try SourceSceneExportValidation.validate(document, against: staged.stage.document.snapshot, keys: staged.keys)
        guard document.effects == SceneEffects(), document.mainLight == MainLight(), document.timeline.keyframes.isEmpty else {
            throw RigError.invalid("Original-scene export does not yet serialize native lighting, effects or timeline edits.")
        }
        let topology = try SourceSceneExportValidation.topologyEdits(document, against: staged.stage.document.snapshot, keys: staged.keys)
        let states = clockRequests.isEmpty ? []
            : clock.savedStates(clockRequests.map(\.request), elapsed: elapsed, scene: (source, sha256))
        return Prepared(source: source, staged: staged, deletions: topology.deletions, reparents: topology.reparents,
                        orphanPluginIDs: orphans,
                        clockStates: Dictionary(uniqueKeysWithValues: zip(clockRequests.map(\.id), states)))
    }

    /// Runs `prepare` on a thread of its own with the decode stack
    /// (`SourceStudioCharacterBatch.stackSize`) and passes the outcome to
    /// `deliver` on that thread. The decoded scene may be released there or
    /// on the main thread, never on a GCD worker (#326): a `deliver` that
    /// hands the outcome to the main queue keeps that rule.
    public static func start(document: StudioDocument, sceneFile: String, sha256: String,
                             clock: SourceStudioAnimationClock,
                             clockRequests: [(id: UUID, request: SourceStudioAnimationClock.Request)],
                             elapsed: Float, qos: QualityOfService = .userInitiated,
                             deliver: @escaping @Sendable (Result<Prepared, Error>) -> Void) {
        SourceStudioCharacterBatch.startThread("Ikkoku original-scene export", qos: qos) {
            deliver(Result {
                try prepare(document: document, sceneFile: sceneFile, sha256: sha256, clock: clock,
                            clockRequests: clockRequests, elapsed: elapsed)
            })
        }
    }
}
