import Foundation
import Scene

/// Optional synchronous worker-local diagnostics; never shared with the owner.
/// Samples are immutable values. Inclusive library/input preparation spans contain
/// their named leaf APIs; these nested durations must not be summed together.
public final class SourceMakerPreparationTimings {
    public enum Phase: String, Sendable {
        case manifestRead, manifestDecode, shapeRead, shapeDecode
        case expressionRead, expressionDecode, correctionRead, bodyOptions, settingsValidation
        case libraryPreparation, libraryManifestRead, libraryManifestDecode
        case verifiedFileRead, verifiedFileSHA, rigRead, rigReuseSHA, rigDecode, assembly
        case appearanceInputPreparation, bindingRead, bindingDecode, rgbaRead, rgbaSHA, rgbaCopy
    }
    public struct Interval: Sendable, Encodable {
        public let milliseconds: Double, calls: Int, failures: Int
    }
    public struct Sample: Sendable, Encodable {
        public let intervals: [String: Interval]
        /// Actual bytes returned/read, presented to SHA, or copied into RGBA arrays.
        /// Repeated SHA checks count again; these are not retained bytes or RSS.
        public let bytesRead: [String: Int], bytesHashed: [String: Int], rgbaBytesCopied: Int
        public let rgbaCacheReuses: Int, hashMismatches: Int
    }
    private var intervals: [String: Interval] = [:], bytesRead: [String: Int] = [:], bytesHashed: [String: Int] = [:]
    private var rgbaBytesCopied = 0, rgbaCacheReuses = 0, hashMismatches = 0
    public init() {}
    public var sample: Sample {
        .init(intervals: intervals, bytesRead: bytesRead, bytesHashed: bytesHashed,
              rgbaBytesCopied: rgbaBytesCopied, rgbaCacheReuses: rgbaCacheReuses, hashMismatches: hashMismatches)
    }
    static func measure<T>(_ timings: SourceMakerPreparationTimings?, _ phase: Phase, _ operation: () throws -> T) rethrows -> T {
        guard let timings else { return try operation() }
        let start = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer {
            let previous = timings.intervals[phase.rawValue]
            timings.intervals[phase.rawValue] = .init(
                milliseconds: (previous?.milliseconds ?? 0) + (ProcessInfo.processInfo.systemUptime - start) * 1000,
                calls: (previous?.calls ?? 0) + 1, failures: (previous?.failures ?? 0) + (succeeded ? 0 : 1))
        }
        let value = try operation(); succeeded = true; return value
    }
    static func read(_ timings: SourceMakerPreparationTimings?, _ phase: Phase, _ operation: () throws -> Data) rethrows -> Data {
        let data = try measure(timings, phase, operation)
        timings?.bytesRead[phase.rawValue, default: 0] += data.count
        return data
    }
    func hashed(_ count: Int, phase: Phase, matches: Bool) {
        bytesHashed[phase.rawValue, default: 0] += count
        if !matches { hashMismatches += 1 }
    }
    func copied(_ count: Int) { rgbaBytesCopied += count }
    func reusedRGBA() { rgbaCacheReuses += 1 }
}

/// CPU-only result for changing a normal head without resetting the editor.
/// Each assembly owns its shape/expression contracts and correction input.
public struct SourceMakerHeadPreparation: Sendable {
    public static let supportedIDs = [0, 200, 201]
    public let manifestURL: URL
    public let sex: Int, headID: Int, boneType: Int, coordinate: Int
    public let assets: SourceMakerLibrary.Prepared
    public let contract: SourceShapeContract
    public let expressions: SourceExpressionContract
    public let bodyOptions: SourceBodyShapePose.Options
    public let appearanceInputs: SourceMakerLibrary.Prepared.AppearanceInputs
    public let workerStages: SourceMakerPreparationTimings.Sample?
    public let rigReuseCandidate: SourceMakerRigReuse.Candidate?
    public let rigReuseSample: SourceMakerRigReuse.Sample?

    /// `baseURL` is a configuration snapshot for the sex's head-0 assembly, not
    /// the currently displayed head-200/201 URL. Assembly/contract I/O and the
    /// selected appearance binding/RGBA reads and hashes stay here. Base and
    /// component image loads, GPU composition and resources remain owner-side.
    public static func prepare(card: SourceCharacterCard, library: SourceMakerLibrary,
                               coordinate: Int, baseURL: URL?, timings: SourceMakerPreparationTimings? = nil,
                               rigReuse: SourceMakerRigReuse.Input? = nil) throws -> Self {
        try card.validateMakerSelectionMetadata()
        try SourceMakerLibrary.validateAssemblyIdentity(card: card)
        let identity = try card.customization()
        guard [0, 1].contains(identity.sex), identity.exType == 0,
              supportedIDs.contains(identity.headID), (0..<7).contains(coordinate) else {
            throw RigError.invalid("Unsupported normal head selection or outfit.")
        }
        let selected: URL?
        if identity.headID == 0 { selected = baseURL }
        else { selected = try library.assemblyURL(for: identity, timings: timings) }
        guard let selected else { throw RigError.invalid("This normal head has no converted assembly.") }
        let url = selected.resolvingSymlinksInPath()
        let folder = url.deletingLastPathComponent()
        func read(_ url: URL, maximum: Int, phase: SourceMakerPreparationTimings.Phase) throws -> Data {
            let data = try SourceMakerPreparationTimings.read(timings, phase) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: maximum + 1) ?? Data()
            }
            guard data.count <= maximum else { throw RigError.invalid("Head assembly input exceeds its size limit.") }
            return data
        }
        func companion(_ name: String, maximum: Int, phase: SourceMakerPreparationTimings.Phase) throws -> Data {
            let target = folder.appendingPathComponent(name).resolvingSymlinksInPath()
            guard !name.isEmpty, !name.hasPrefix("/"), target.path.hasPrefix(folder.path + "/") else {
                throw RigError.invalid("Head assembly input escapes its folder.")
            }
            return try read(target, maximum: maximum, phase: phase)
        }
        let manifestBytes = try read(url, maximum: 1024 * 1024, phase: .manifestRead)
        let manifest = try SourceMakerPreparationTimings.measure(timings, .manifestDecode) {
            try JSONDecoder().decode(SourceAvatarManifest.self, from: manifestBytes)
        }
        let kind = identity.sex == 0 ? "koikatsu-male-avatar" : "koikatsu-female-avatar"
        guard manifest.schemaVersion == 1, manifest.kind == kind,
              (manifest.sex ?? identity.sex) == identity.sex,
              (manifest.headID ?? 0) == identity.headID else {
            throw RigError.invalid("Selected card and head assembly identities differ.")
        }
        let contract: SourceShapeContract
        do {
            let bytes = try companion("character-shape-contract.json", maximum: 64 * 1024 * 1024, phase: .shapeRead)
            contract = try SourceMakerPreparationTimings.measure(timings, .shapeDecode) { try SourceShapeContract.decode(bytes) }
        }
        let expressions: SourceExpressionContract
        do {
            let bytes = try companion("source-expression-contract.json", maximum: 16 * 1024 * 1024, phase: .expressionRead)
            expressions = try SourceMakerPreparationTimings.measure(timings, .expressionDecode) { try SourceExpressionContract.decode(bytes) }
        }
        let correction = identity.boneType == 0 ? nil : try companion(manifest.bodyCorrection ?? "shapecorrect.bytes", maximum: 1024 * 1024, phase: .correctionRead)
        let options = try SourceMakerPreparationTimings.measure(timings, .bodyOptions) {
            try SourceMakerAssemblyOptions.body(sex: identity.sex, exType: identity.exType,
                boneType: identity.boneType, correctionData: correction)
        }
        _ = try SourceMakerPreparationTimings.measure(timings, .settingsValidation) {
            try card.previewSettings(contract: contract, sex: identity.sex, headID: identity.headID, boneType: identity.boneType)
        }
        let reuseWorker = rigReuse.map(SourceRigReuseWorker.init)
        let assets = try SourceMakerPreparationTimings.measure(timings, .libraryPreparation) {
            try library.prepare(card: card, coordinate: coordinate, baseURL: url, wear: false, timings: timings, rigReuse: reuseWorker)
        }
        let appearanceInputs = try SourceMakerPreparationTimings.measure(timings, .appearanceInputPreparation) {
            try assets.prepareAppearanceInputs(card: SourceCardAppearance(card: card, coordinate: coordinate), baseURL: url, timings: timings)
        }
        let reuseResult = reuseWorker?.finish()
        return Self(manifestURL: url, sex: identity.sex, headID: identity.headID,
            boneType: identity.boneType, coordinate: coordinate, assets: assets, contract: contract,
            expressions: expressions, bodyOptions: options, appearanceInputs: appearanceInputs, workerStages: timings?.sample,
            rigReuseCandidate: reuseResult?.0, rigReuseSample: reuseResult?.1)
    }
}
