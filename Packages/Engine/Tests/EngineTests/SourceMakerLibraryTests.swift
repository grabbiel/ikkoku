import Foundation
import Testing
import CryptoKit
import Metal
import simd
import Assets
import CoreMath
@testable import Character
import Scene
import Renderer

private enum MakerLibraryFixture {
    typealias F = OriginalCardFixture
    static func directory() throws -> URL { try AppearanceTestFixture.directory() }
    static func library(_ entries: [[String: Any]], directory: URL, assemblies: [[String: Any]] = []) throws -> SourceMakerLibrary {
        let url = directory.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": entries, "assemblies": assemblies]).write(to: url)
        return try .load(url: url)
    }
    static func empty(_ category: Int, _ id: Int, guid: String? = nil, name: String = "p_dummy") -> [String: Any] {
        var entry: [String: Any] = ["category": category, "id": id, "name": name, "empty": true]
        if let guid { entry["modGUID"] = guid }
        return entry
    }
    static func references(_ records: [(String?, String, Int, Int)]) throws -> SourceCardModReferences {
        let values = records.map { guid, property, source, local in F.Value.binary(F.pack(F.map([
            ("ModID", guid.map(F.Value.string) ?? .null), ("Property", .string(property)),
            ("Slot", .integer(Int64(source))), ("LocalSlot", .integer(Int64(local))),
            ("CategoryNo", .integer(999))]))) }
        let plugin = F.plugin(0, data: F.map([("info", .array(values))]))
        let card = try SourceCharacterCard.decode(F.card(blocks: F.blocks() + [F.extended(F.map([
            ("com.bepis.sideloader.universalautoresolver", plugin)]))]))
        return try #require(try card.modReferences())
    }
}

@Test func sourceMakerLibraryResolvesFirstOrdinalModSourceSlotWithoutChangingIdentity() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try MakerLibraryFixture.library([
        MakerLibraryFixture.empty(101, 17, guid: "Example.Mod", name: "first"),
        MakerLibraryFixture.empty(101, 17, guid: "example.mod", name: "case-distinct"),
        MakerLibraryFixture.empty(101, 17, guid: "caf\u{e9}", name: "composed"),
        MakerLibraryFixture.empty(101, 17, guid: "cafe\u{301}", name: "decomposed"),
        MakerLibraryFixture.empty(101, 900001, guid: "Example.Mod", name: "wrong-local-slot"),
        MakerLibraryFixture.empty(101, 17, name: "original")], directory: directory)
    let property = "ChaFileHair.HairBack"
    let refs = try MakerLibraryFixture.references([("Example.Mod", property, 17, 900001), ("example.mod", property, 17, 900002)])
    let selected = library.selection(category: 101, savedID: 99999, property: property, references: refs)
    #expect(selected.entry?.name == "first" && selected.savedID == 99999 && selected.sourceID == 17)
    #expect(selected.modGUID == "Example.Mod" && selected.status == "empty")
    #expect(refs.records.map(\.localSlot) == [900001, 900002])
    #expect(library.selection(category: 102, savedID: 17, property: property, references: refs).entry == nil)
    for (guid, name) in [("example.mod", "case-distinct"), ("caf\u{e9}", "composed"), ("cafe\u{301}", "decomposed")] {
        let ref = try MakerLibraryFixture.references([(guid, property, 17, 1)])
        #expect(library.selection(category: 101, savedID: 900001, property: property, references: ref).entry?.name == name)
    }
    let ordinal = try MakerLibraryFixture.references([("Example.Mod", "caf\u{e9}", 17, 1)])
    #expect(library.selection(category: 101, savedID: 17, property: "cafe\u{301}", references: ordinal).entry?.name == "original")
    #expect(library.selection(category: 101, savedID: 17, property: property, references: nil).entry?.name == "original")
    for guid: String? in [nil, ""] {
        let ref = try MakerLibraryFixture.references([(guid, property, 17, 1)])
        #expect(library.selection(category: 101, savedID: 17, property: property, references: ref).status == "compatibilityRequired")
    }
}

@Test func sourceMakerLibraryRejectsDuplicateIdentityTraversalAndChangedAssemblyBytes() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let entry = MakerLibraryFixture.empty(103, 0)
    #expect(throws: (any Error).self) { try MakerLibraryFixture.library([entry, entry], directory: directory) }
    let data = Data("{}".utf8), hash = OriginalCardFixture.hash(data)
    for path in ["../escape.json", "/absolute.json", ""] {
        var invalid = entry; invalid["rig"] = ["file": path, "sha256": hash]
        #expect(throws: (any Error).self) { try MakerLibraryFixture.library([invalid], directory: directory) }
    }
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try data.write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.json"), withDestinationURL: outside)
    var symlink = entry; symlink["rig"] = ["file": "link.json", "sha256": hash]
    #expect(throws: (any Error).self) { try MakerLibraryFixture.library([symlink], directory: directory) }
    try data.write(to: directory.appendingPathComponent("assembly.json"))
    let assembly: [String: Any] = ["sex": 1, "headID": 0, "exType": 0,
        "manifest": ["file": "assembly.json", "sha256": String(repeating: "0", count: 64)]]
    let library = try MakerLibraryFixture.library([], directory: directory, assemblies: [assembly])
    let identity = try SourceCharacterCard.decode(OriginalCardFixture.card()).customization()
    #expect(throws: (any Error).self) { try library.assemblyURL(for: identity) }
}

@Test func sourceMakerLibraryDoesNotAliasResolverBackedHeadToVanillaIdentity() throws {
    try SourceMakerLibrary.validateAssemblyIdentity(card: AppearanceTestFixture.card())
    for guid in ["original.head.mod", ""] {
        let card = try AppearanceTestFixture.card(modProperty: "ChaFileFace.headId", guid: guid)
        #expect(try card.customization().headID == 0)
        #expect(throws: RigError.self) { try SourceMakerLibrary.validateAssemblyIdentity(card: card) }
        #expect(try card.editedData(.init()) == card.preservedData)
    }
    // Property matching follows source ordinal string comparison.
    try SourceMakerLibrary.validateAssemblyIdentity(card: AppearanceTestFixture.card(modProperty: "ChaFileFace.HeadId"))
}

@Test func sourceMakerHeadPreparationRejectsMissingWrongAndEscapingInputs() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try MakerLibraryFixture.library([], directory: directory)
    let card = try AppearanceTestFixture.card()
    let url = directory.appendingPathComponent("source-avatar.json")
    #expect(throws: (any Error).self) { try SourceMakerHeadPreparation.prepare(card: card, library: library, coordinate: 0, baseURL: nil) }
    #expect(throws: (any Error).self) { try SourceMakerHeadPreparation.prepare(card: card, library: library, coordinate: 7, baseURL: url) }
    let mod = try AppearanceTestFixture.card(modProperty: "ChaFileFace.headId")
    #expect(throws: (any Error).self) { try SourceMakerHeadPreparation.prepare(card: mod, library: library, coordinate: 0, baseURL: url) }
    let alternate = try SourceCharacterCard.decode(card.selectingVanillaHead(200))
    // A missing alternate never silently uses the supplied base-0 manifest.
    #expect(throws: (any Error).self) { try SourceMakerHeadPreparation.prepare(card: alternate, library: library, coordinate: 0, baseURL: url) }
    let manifest: [String: Any] = ["schemaVersion": 1, "kind": "koikatsu-female-avatar", "name": "fixture", "sex": 1, "headID": 0,
        "bodySkeleton": "body-master.json", "headSkeleton": "head-master.json", "body": ["file": "body.json"], "head": ["file": "head.json"],
        "clothes": [], "hair": []]
    for (key, value) in [("schemaVersion", 2 as Any), ("sex", 0 as Any), ("headID", 200 as Any), ("kind", "koikatsu-male-avatar" as Any)] {
        var wrong = manifest; wrong[key] = value
        try JSONSerialization.data(withJSONObject: wrong).write(to: url)
        do {
            _ = try SourceMakerHeadPreparation.prepare(card: card, library: library, coordinate: 0, baseURL: url)
            Issue.record("Wrong head manifest was accepted")
        } catch RigError.invalid(let reason) { #expect(reason == "Selected card and head assembly identities differ.") }
    }
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data("{}".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("character-shape-contract.json"), withDestinationURL: outside)
    do {
        _ = try SourceMakerHeadPreparation.prepare(card: card, library: library, coordinate: 0, baseURL: url)
        Issue.record("Escaping head companion was accepted")
    } catch RigError.invalid(let reason) { #expect(reason == "Head assembly input escapes its folder.") }
}

@Test func sourceMakerLibraryRejectsUnconditionalOrAmbiguousHalfStateMetadata() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let clause: [String: Any] = ["kind": 0, "states": [1]]
    let nested: [String: Any] = ["meshName": "half", "switches": ["n_top_b", "n_bot_a"],
                                 "activeWhen": [clause, ["kind": 1, "states": [0]]]]
    let entry: [String: Any] = ["category": 105, "id": 1, "name": "shirt", "meshNames": ["dressed"],
                               "rig": ["file": "rig.json", "sha256": String(repeating: "0", count: 64)],
                               "alternates": [nested]]
    // A real nested switch conjunction remains supported. The boundary does
    // not replace the independent source-rule/rig checks in the fixture test.
    let library = try MakerLibraryFixture.library([entry], directory: directory)
    #expect(library.entries[0].alternates?[0].activeWhen.count == 2)
    let invalidFields: [[String: Any]] = [
        ["activeWhen": []], // allSatisfy on this used to make the alternate always visible
        ["activeWhen": [clause, clause]],
        ["activeWhen": [["kind": 0, "states": [1, 1]]]],
        ["activeWhen": [["kind": 0, "states": []]]],
        ["switches": [""]], ["meshName": ""], ["meshName": "dressed"],
    ]
    for fields in invalidFields {
        var invalid = entry; invalid["alternates"] = [nested.merging(fields) { _, value in value }]
        #expect(throws: RigError.self) { try MakerLibraryFixture.library([invalid], directory: directory) }
    }
    var gloves = entry; gloves["category"] = 109
    #expect(throws: RigError.self) { try MakerLibraryFixture.library([gloves], directory: directory) }
}

@MainActor @Test func sourceMakerLibraryValidatesUnusedReferencePathsAndSelectedAssetHashes() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let card = try AppearanceTestFixture.card()
    let manifest = directory.appendingPathComponent("source-avatar.json")
    func writeManifest(hair: String) throws {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": "koikatsu-female-avatar", "name": "fixture",
            "sex": 1, "headID": 0, "bodySkeleton": "body-master.json", "headSkeleton": "head-master.json",
            "body": ["file": "body.json", "meshNames": ["body"]], "head": ["file": "head.json"],
            "hair": [["file": hair, "slot": 0]], "clothes": []] as [String: Any]).write(to: manifest)
    }
    let library = try MakerLibraryFixture.library([MakerLibraryFixture.empty(101, 2)], directory: directory)
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data().write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.json"), withDestinationURL: outside)
    for path in ["../escape.json", "/absolute.json", "", "escape.json"] {
        try writeManifest(hair: path)
        do {
            _ = try library.prepare(card: card, coordinate: 0, baseURL: manifest)
            Issue.record("An unused reference path escaped validation")
        } catch RigError.invalid(let reason) { #expect(reason == "Base component escapes its folder.") }
        let worker = SourceRigReuseWorker(SourceMakerRigReuse().input()), timings = SourceMakerPreparationTimings()
        do {
            _ = try library.prepare(card: card, coordinate: 0, baseURL: manifest, wear: false, timings: timings, rigReuse: worker)
            Issue.record("Reuse bypassed an unused reference path check")
        } catch RigError.invalid(let reason) { #expect(reason == "Base component escapes its folder.") }
        #expect(timings.sample.intervals["rigReuseSHA"] == nil && timings.sample.intervals["rigDecode"] == nil)
    }
    // The missing reference is unused, but a selected converted rig must still
    // pass its original byte hash before any geometry is accepted.
    try writeManifest(hair: "unused-missing.json")
    try Data("{}".utf8).write(to: directory.appendingPathComponent("selected.json"))
    let changed = try MakerLibraryFixture.library([["category": 101, "id": 2, "name": "selected", "meshNames": ["part"],
        "rig": ["file": "selected.json", "sha256": String(repeating: "0", count: 64)]]], directory: directory)
    do {
        _ = try changed.prepare(card: card, coordinate: 0, baseURL: manifest)
        Issue.record("A selected asset with changed bytes was accepted")
    } catch RigError.invalid(let reason) { #expect(reason == "Changed or oversized converted Maker asset: selected.json.") }
    let worker = SourceRigReuseWorker(SourceMakerRigReuse().input()), timings = SourceMakerPreparationTimings()
    do {
        _ = try changed.prepare(card: card, coordinate: 0, baseURL: manifest, wear: false, timings: timings, rigReuse: worker)
        Issue.record("Reuse bypassed a selected asset hash failure")
    } catch RigError.invalid(let reason) { #expect(reason == "Changed or oversized converted Maker asset: selected.json.") }
    #expect(timings.sample.intervals["rigRead"] == nil && timings.sample.intervals["rigReuseSHA"] == nil)
}

private struct MakerSelectionCases: Decodable {
    struct Case: Decodable {
        let file: String, sha256: String, sex: Int, headID: Int, boneType: Int
        let moved: Bool, materials: Bool, selectionCount: Int, opaqueTokenCount: Int
    }
    let library: String, femaleBase: String, maleBase: String, fixtures: [Case]
    static func load() throws -> (Self, URL) {
        let url = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_MAKER_SELECTION_FIXTURES"))
        return (try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)), url.deletingLastPathComponent())
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]) && MTLCreateSystemDefaultDevice() != nil,
    "Requires IKKOKU_MAKER_SELECTION_FIXTURES and a Metal device"))
func sourceMakerPreparedAppearanceScopesFollowSelectedComponentsWithoutChangingResults() async throws {
    let checks = try await liveTickOffPool {
        let (fixtures, directory) = try MakerSelectionCases.load()
        let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
        let baseURL = URL(fileURLWithPath: fixtures.femaleBase)
        let card = try SourceCharacterCard.load(url: directory.appendingPathComponent("female-head0-bone0.png"))
        let cardAppearance = try SourceCardAppearance(card: card)
        let prepared = try library.prepare(card: card, coordinate: 0, baseURL: baseURL)
        let inputs = try prepared.prepareAppearanceInputs(card: cardAppearance, baseURL: baseURL)
        guard let device = MTLCreateSystemDefaultDevice() else { throw RigError.invalid("Metal device unavailable.") }
        let resources = ResourceStore(device: device)
        let base = try SourcePreviewAppearance.load(url: baseURL.deletingPathExtension().appendingPathExtension("appearance.json"), resources: resources)
        let timings = SourceAppearanceTimings()
        let appliedBase = try inputs.applyingBase(to: base, card: cardAppearance, baseURL: baseURL, resources: resources, timings: timings)
        guard let observed = try prepared.appearance(base: appliedBase?.appearance ?? base, card: cardAppearance,
            resources: resources, modLibrary: nil, timings: timings, inputs: inputs),
              let ordinary = try prepared.appearance(base: appliedBase?.appearance ?? base, card: cardAppearance,
            resources: resources, modLibrary: nil, inputs: inputs) else { throw RigError.invalid("Fixture appearance is absent.") }
        let sample = timings.sample, scopes = sample.scopes
        let components = scopes.filter { $0.identity.role == .component }
        let expected = ["hair-0/", "hair-1/", "clothes-0/", "clothes-1/", "clothes-8/", "accessory-0/"]
        var checks: [(String, Bool)] = [
            ("Base, six selected components and body mask retain execution order", scopes.map(\.identity.role) == [.base] + Array(repeating: .component, count: 6) + [.bodyMaskLoad]),
            ("Component labels retain the original selected slots", components.map(\.identity.prefix) == expected.map(Optional.some)),
            ("Component ordinals follow the prepared order", components.map(\.identity.componentIndex) == (0..<6).map(Optional.some)),
            ("Accessory and indoor-shoe context remain explicit", components.map(\.identity.accessorySlot) == [nil, nil, nil, nil, nil, 0] && components.allSatisfy { $0.identity.indoorShoes == false }),
            ("Each completed component loads once", components.allSatisfy { $0.succeeded && $0.calls["componentLoad"] == 1 }),
            ("Body mask is a separate completed operation", scopes.last?.succeeded == true && scopes.last?.calls["bodyMaskLoad"] == 1),
            ("Nil diagnostics preserve applied fields and diagnostics", observed.appliedFields == ordinary.appliedFields && observed.diagnostics == ordinary.diagnostics),
            ("Nil diagnostics preserve material targets", Set(observed.appearance.materials.keys) == Set(ordinary.appearance.materials.keys)),
        ]
        for (phase, count) in sample.calls {
            checks.append(("Scope call deltas partition aggregate \(phase)", scopes.reduce(0) { $0 + $1.calls[phase, default: 0] } == count))
        }
        if let aggregate = sample.composition {
            checks.append(("Dispatch deltas partition aggregate", scopes.reduce(0) { $0 + ($1.composition?.metalEncodeDispatches ?? 0) } == aggregate.metalEncodeDispatches))
            checks.append(("Completion deltas partition aggregate", scopes.reduce(0) { $0 + ($1.composition?.metalBatchCompletions ?? 0) } == aggregate.metalBatchCompletions))
            checks.append(("Real-input allocation deltas partition aggregate", scopes.reduce(0) { $0 + ($1.composition?.realInputAllocations ?? 0) } == aggregate.realInputAllocations))
            checks.append(("Fallback allocation deltas partition aggregate", scopes.reduce(0) { $0 + ($1.composition?.fallbackAllocations ?? 0) } == aggregate.fallbackAllocations))
            checks.append(("Fallback binding deltas partition aggregate", scopes.reduce(0) { $0 + ($1.composition?.fallbackBindings ?? 0) } == aggregate.fallbackBindings))
        }
        return checks
    }
    for (name, passed) in checks { #expect(passed, "\(name)") }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
@MainActor func sourceMakerHeadPreparationRebindsEachNormalAssemblyWithoutEditingInput() throws {
    let (fixtures, directory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    // Both sexes and standard/corrected cards use the selected assembly's own
    // controllers; this is CPU preparation, without preview/GPU allocation.
    for sample in fixtures.fixtures.prefix(6) {
        let reuse = SourceMakerRigReuse()
        let original = try SourceCharacterCard.load(url: directory.appendingPathComponent(sample.file))
        let base = URL(fileURLWithPath: sample.sex == 1 ? fixtures.femaleBase : fixtures.maleBase)
        for id in [0, 200, 201] {
            let card = try SourceCharacterCard.decode(original.selectingVanillaHead(id))
            let bytes = card.preservedData
            let timings = id == 201 ? SourceMakerPreparationTimings() : nil
            let value = try SourceMakerHeadPreparation.prepare(card: card, library: library, coordinate: 1, baseURL: base, timings: timings)
            if let timings {
                let sample = try #require(value.workerStages)
                #expect(sample.intervals["libraryPreparation"]?.calls == 1 && sample.intervals["appearanceInputPreparation"]?.calls == 1)
                #expect(sample.intervals["assembly"]?.calls == 1 && sample.intervals.values.allSatisfy { $0.failures == 0 })
                #expect(sample.bytesRead["rgbaRead"] == value.appearanceInputs.byteCount)
                #expect(sample.rgbaBytesCopied == value.appearanceInputs.byteCount && sample.hashMismatches == 0)
                #expect(timings.sample.bytesRead == sample.bytesRead)
            } else { #expect(value.workerStages == nil) }
            #expect(value.sex == sample.sex && value.headID == id && value.boneType == sample.boneType && value.coordinate == 1)
            #expect(value.bodyOptions.sex.rawValue == sample.sex)
            let manifest = try JSONDecoder().decode(SourceAvatarManifest.self, from: Data(contentsOf: value.manifestURL))
            #expect((manifest.headID ?? 0) == id)
            #expect((value.manifestURL == base.resolvingSymlinksInPath()) == (id == 0))
            #expect(value.contract.domain("face")?.valueCount == 52 && value.contract.domain("body")?.valueCount == 44)
            let body = try #require(value.contract.domain("body")), face = try #require(value.contract.domain("face"))
            let coverage = try SourceBodyShapePose.coverage(rig: value.assets.source.rig, domain: body, options: value.bodyOptions)
            #expect(coverage.completeSlots.count == 44)
            _ = try SourceFaceShapePose.make(rig: value.assets.source.rig, domain: face)
            #expect(try !value.expressions.weights(source: value.assets.source, inputs: value.expressions.defaults).isEmpty)
            #expect(value.rigReuseCandidate == nil && value.rigReuseSample == nil)
            let cached = try SourceMakerHeadPreparation.prepare(card: card, library: library, coordinate: 1, baseURL: base,
                rigReuse: reuse.input())
            try expectReusedSourceMatches(cached.assets.source, value.assets.source)
            #expect(cached.sex == value.sex && cached.headID == value.headID && cached.boneType == value.boneType)
            #expect(cached.appearanceInputs.byteCount == value.appearanceInputs.byteCount)
            #expect(reuse.commit(cached.rigReuseCandidate))
            if id == 201 {
                let warmTimings = SourceMakerPreparationTimings()
                let warm = try SourceMakerHeadPreparation.prepare(card: card, library: library, coordinate: 1, baseURL: base,
                    timings: warmTimings, rigReuse: reuse.input())
                try expectReusedSourceMatches(warm.assets.source, value.assets.source)
                let warmSample = try #require(warm.rigReuseSample)
                #expect(warmSample.hits > 0 && warmSample.misses == 0 && !warmSample.clearOnCommit)
                #expect(warmTimings.sample.intervals["rigDecode"] == nil)
                #expect(warmTimings.sample.intervals["rigRead"]?.calls == warmSample.hits)
                #expect(warmTimings.sample.intervals["rigReuseSHA"]?.calls == warmSample.hits)
                #expect(warmSample.retainedEntries <= 16 && warmSample.logicalEntryBytes <= 64 * 1024 * 1024)
                #expect(warmSample.liveEntries <= 16 && warmSample.liveLogicalEntryBytes <= 64 * 1024 * 1024 && warmSample.liveSnapshots <= 4)
                print("sourceMakerRigReuseFixture sex=\(sample.sex) bone=\(sample.boneType) entries=\(warmSample.retainedEntries) logicalBytes=\(warmSample.logicalEntryBytes) hits=\(warmSample.hits)")
            }
            #expect(card.preservedData == bytes)
        }
    }
}

private func expectReusedSourceMatches(_ actual: SourceRig, _ expected: SourceRig) throws {
    #expect(actual.sourcePrefab == expected.sourcePrefab && actual.morphChannelCount == expected.morphChannelCount)
    try #require(actual.rig.nodes.count == expected.rig.nodes.count && actual.parts.count == expected.parts.count)
    for (a, e) in zip(actual.rig.nodes, expected.rig.nodes) {
        #expect(a.name == e.name && a.sourceID == e.sourceID && a.parent == e.parent && a.active == e.active)
        for column in 0..<4 { #expect(a.localMatrix[column] == e.localMatrix[column]) }
    }
    let a = try actual.rig.evaluate(actual.rig.restPose), e = try expected.rig.evaluate(expected.rig.restPose)
    try #require(a.palettes.count == e.palettes.count)
    for (ap, ep) in zip(a.palettes, e.palettes) {
        try #require(ap.count == ep.count)
        for (am, em) in zip(ap, ep) { for column in 0..<4 { #expect(am[column] == em[column]) } }
    }
    for (a, e) in zip(actual.parts, expected.parts) {
        #expect(a.node == e.node && a.skin == e.skin && a.rendererEnabled == e.rendererEnabled && a.hasCloth == e.hasCloth)
        #expect(a.mesh.name == e.mesh.name && a.mesh.positions == e.mesh.positions && a.mesh.normals == e.mesh.normals)
        #expect(a.mesh.tangents == e.mesh.tangents && a.mesh.uvs == e.mesh.uvs && a.mesh.uvs1 == e.mesh.uvs1 && a.mesh.uvs2 == e.mesh.uvs2)
        #expect(a.mesh.indices == e.mesh.indices && a.mesh.joints == e.mesh.joints && a.mesh.weights == e.mesh.weights)
        #expect(a.mesh.colors == e.mesh.colors && a.mesh.regions == e.mesh.regions && a.mesh.materialIndex == e.mesh.materialIndex)
        try #require(a.mesh.morphTargets.count == e.mesh.morphTargets.count)
        for (am, em) in zip(a.mesh.morphTargets, e.mesh.morphTargets) {
            #expect(am.name == em.name && am.positionDeltas == em.positionDeltas && am.normalDeltas == em.normalDeltas)
        }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]) && MTLCreateSystemDefaultDevice() != nil, "Requires IKKOKU_MAKER_SELECTION_FIXTURES and a Metal device"))
func sourceMakerLibraryPreparedCaninesFollowVisibilityThroughProductionFrames() throws {
    let (fixtures, directory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    // Normal male/female head 0, 200 and 201. Geometry fixtures are independent
    // converted inputs, not a claim of new original-player captures for each.
    for sample in fixtures.fixtures.prefix(6) {
        let bytes = try Data(contentsOf: directory.appendingPathComponent(sample.file))
        #expect(OriginalCardFixture.hash(bytes) == sample.sha256)
        let card = try SourceCharacterCard.decode(bytes), identity = try card.customization()
        let base = try library.assemblyURL(for: identity) ?? URL(fileURLWithPath: sample.sex == 1 ? fixtures.femaleBase : fixtures.maleBase)
        let prepared = try library.prepare(card: card, coordinate: 0, baseURL: base)
        let canine = try #require(prepared.source.parts.firstIndex { prepared.source.rig.nodes[$0.node].name == "cf_O_canine" })
        let saved = try SourceRigPreview.savedDoubleTooth(in: card)
        let preview = try SourceRigPreview(source: prepared.source, contract: nil, resources: resources, doubleTooth: saved)
        let initial = try preview.frame(camera: OrbitCamera())
        preview.doubleTooth = true
        let on = try preview.frame(camera: OrbitCamera())
        preview.doubleTooth = false
        let off = try preview.frame(camera: OrbitCamera())
        if let saved {
            #expect(initial.items.map(\.mesh) == (saved ? on : off).items.map(\.mesh))
        } else {
            // The selection-only synthetic cards omit this field. Their
            // initial frame must preserve authored activity, then accept the
            // same explicit Boolean visibility control as a complete card.
            preview.doubleTooth = nil
            #expect(try preview.frame(camera: OrbitCamera()).items.map(\.mesh) == initial.items.map(\.mesh))
            let authored = prepared.source.rig.activeNodes[prepared.source.parts[canine].node]
            #expect(initial.items.map(\.mesh) == (authored ? on : off).items.map(\.mesh))
        }
        #expect(on.items.count == off.items.count + 1)
        let removed = Set(on.items.map(\.mesh)).subtracting(off.items.map(\.mesh))
        #expect(removed.count == 1)
        let handle = try #require(removed.first), mesh = try #require(resources.mesh(handle))
        #expect(mesh.name == prepared.source.parts[canine].mesh.name)
        #expect(on.items.filter { !removed.contains($0.mesh) }.map(\.mesh) == off.items.map(\.mesh))
        preview.doubleTooth = true
        #expect(try preview.frame(camera: OrbitCamera(), hiddenParts: [canine]).items.map(\.mesh) == off.items.map(\.mesh))
        #expect(card.preservedData == bytes)
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceMakerLibraryRejectsInvalidOrDuplicateBaseComponentSlots() throws {
    let (fixtures, fixtureDirectory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let sourceURL = URL(fileURLWithPath: fixtures.femaleBase), directory = try MakerLibraryFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any])
    var paths = [try #require(original["bodySkeleton"] as? String), try #require(original["headSkeleton"] as? String)]
    for key in ["body", "head"] { paths.append(try #require((original[key] as? [String: Any])?["file"] as? String)) }
    for key in ["hair", "clothes"] {
        paths += try #require(original[key] as? [[String: Any]]).map { try #require($0["file"] as? String) }
    }
    // Separate directory entries share immutable file bytes; no source files change.
    for path in Set(paths) {
        let target = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: sourceURL.deletingLastPathComponent().appendingPathComponent(path), to: target)
    }
    let card = try SourceCharacterCard.decode(Data(contentsOf: fixtureDirectory.appendingPathComponent("female-head0-bone0.png")))
    for (kind, slots) in [("hair", [4,1]), ("hair", [0,0]), ("clothes", [-1,1,8]), ("clothes", [0,0,8])] {
        var document = original, components = try #require(original[kind] as? [[String: Any]])
        for (index, slot) in slots.enumerated() { components[index]["slot"] = slot }
        document[kind] = components
        let url = directory.appendingPathComponent("source-avatar.json")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        do {
            _ = try library.prepare(card: card, coordinate: 0, baseURL: url)
            Issue.record("Invalid base component slots were accepted")
        } catch RigError.invalid(let reason) { #expect(reason.contains("Invalid or duplicate base")) }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceMakerLibraryLoadsOnlyRequiredReferenceGeometry() throws {
    let (fixtures, fixtureDirectory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let base = URL(fileURLWithPath: fixtures.femaleBase), directory = try MakerLibraryFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let card = try SourceCharacterCard.load(url: fixtureDirectory.appendingPathComponent("female-head0-bone0.png"))
    let original = try library.prepare(card: card, coordinate: 0, baseURL: base)
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: base)) as? [String: Any])
    var paths = [try #require(manifest["bodySkeleton"] as? String), try #require(manifest["headSkeleton"] as? String)]
    for key in ["body", "head"] { paths.append(try #require((manifest[key] as? [String: Any])?["file"] as? String)) }
    for path in Set(paths) {
        let target = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: base.deletingLastPathComponent().appendingPathComponent(path), to: target)
    }
    for kind in ["hair", "clothes"] {
        var components = try #require(manifest[kind] as? [[String: Any]])
        for index in components.indices {
            let path = "unused-\(kind)-\(index).json"
            components[index]["file"] = path
            try Data("invalid unused geometry".utf8).write(to: directory.appendingPathComponent(path))
        }
        manifest[kind] = components
    }
    let changedBase = directory.appendingPathComponent("source-avatar.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: changedBase)
    let timings = SourceMakerPreparationTimings()
    let prepared = try library.prepare(card: card, coordinate: 0, baseURL: changedBase, timings: timings)
    #expect(timings.sample.intervals["libraryManifestRead"]?.calls == 1 && timings.sample.intervals["libraryManifestDecode"]?.calls == 1)
    #expect(timings.sample.intervals["rigRead"]?.calls == timings.sample.intervals["rigDecode"]?.calls)
    #expect(timings.sample.intervals["assembly"]?.calls == 1 && timings.sample.intervals.values.allSatisfy { $0.failures == 0 })
    #expect(prepared.clothingSlots == original.clothingSlots && prepared.referenceClothingSlots == original.referenceClothingSlots)
    #expect(prepared.selections.map(\.property) == original.selections.map(\.property))
    #expect(prepared.selections.map(\.sourceID) == original.selections.map(\.sourceID))
    #expect(prepared.selections.map(\.modGUID) == original.selections.map(\.modGUID))
    #expect(prepared.diagnostics == original.diagnostics)
    let a = original.source, b = prepared.source
    #expect(a.sourcePrefab == b.sourcePrefab && a.morphChannelCount == b.morphChannelCount)
    #expect(a.rig.nodes.count == b.rig.nodes.count && a.rig.skins.count == b.rig.skins.count && a.parts.count == b.parts.count)
    #expect(a.rig.order == b.rig.order && a.rig.activeNodes == b.rig.activeNodes)
    for (left, right) in zip(a.rig.nodes, b.rig.nodes) {
        #expect(left.name == right.name && left.sourceID == right.sourceID && left.parent == right.parent)
        #expect(left.localMatrix == right.localMatrix && left.active == right.active)
    }
    for (left, right) in zip(a.rig.skins, b.rig.skins) {
        #expect(left.name == right.name && left.meshNode == right.meshNode && left.rootJoint == right.rootJoint)
        #expect(left.joints == right.joints && left.inverseBindMatrices == right.inverseBindMatrices)
    }
    for (left, right) in zip(a.parts, b.parts) {
        #expect(left.node == right.node && left.skin == right.skin && left.rendererEnabled == right.rendererEnabled && left.hasCloth == right.hasCloth)
        let x = left.mesh, y = right.mesh
        #expect(x.name == y.name && x.positions == y.positions && x.normals == y.normals && x.tangents == y.tangents)
        #expect(x.uvs == y.uvs && x.uvs1 == y.uvs1 && x.uvs2 == y.uvs2 && x.colors == y.colors)
        #expect(x.joints == y.joints && x.weights == y.weights && x.indices == y.indices)
        #expect(x.materialIndex == y.materialIndex && x.regions == y.regions && x.extras == y.extras)
        #expect(x.morphTargets.count == y.morphTargets.count)
        for (m, n) in zip(x.morphTargets, y.morphTargets) {
            #expect(m.name == n.name && m.positionDeltas == n.positionDeltas && m.normalDeltas == n.normalDeltas)
        }
    }
    // An unresolved selection really needs its reference, so its malformed
    // geometry must fail rather than silently dropping that part.
    for slot: SourceMakerSelectionSlot in [.hair(0), .clothes(coordinate: 0, slot: 0)] {
        let fallback = try SourceCharacterCard.decode(card.selectingVanillaAsset(Int(Int32.max), at: slot))
        #expect(throws: DecodingError.self) { try library.prepare(card: fallback, coordinate: 0, baseURL: changedBase) }
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]) && MTLCreateSystemDefaultDevice() != nil, "Requires IKKOKU_MAKER_SELECTION_FIXTURES and a Metal device"))
func sourceMakerLibraryPreparesSelectedClothedGeometryHeadsBoneTypesAndAccessoryTransforms() throws {
    let (fixtures, directory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    for sample in fixtures.fixtures {
        let bytes = try Data(contentsOf: directory.appendingPathComponent(sample.file))
        #expect(OriginalCardFixture.hash(bytes) == sample.sha256)
        let card = try SourceCharacterCard.decode(bytes), custom = try card.customization()
        #expect(custom.sex == sample.sex && custom.headID == sample.headID && custom.boneType == sample.boneType)
        let base = try library.assemblyURL(for: custom) ?? URL(fileURLWithPath: sample.sex == 1 ? fixtures.femaleBase : fixtures.maleBase)
        let prepared = try library.prepare(card: card, coordinate: 0, baseURL: base)
        #expect(prepared.selections.count == sample.selectionCount)
        #expect(prepared.selections.allSatisfy { $0.status == "converted" || $0.status == "empty" })
        #expect(prepared.selections.filter { $0.status == "converted" }.count == 6)
        #expect(prepared.selections.filter { $0.status == "empty" }.count == 7)
        let source = prepared.source, names = source.parts.map(\.mesh.name)
        #expect(names.contains { $0.hasPrefix("hair-0/") } && names.contains { $0.hasPrefix("hair-1/") })
        #expect(!names.contains { $0.hasPrefix("hair-2/") || $0.hasPrefix("hair-3/") })
        #expect(names.filter { $0.hasPrefix("accessory-0/") }.count == 2)
        #expect(names.contains { $0.hasPrefix("clothes-0/") } && names.contains { $0.hasPrefix("clothes-1/") })
        let move = try #require(source.rig.nodes.first { $0.sourceID.hasPrefix("accessory-0/") && $0.name == "N_move" })
        #expect(!source.rig.nodes.contains { $0.sourceID.hasPrefix("accessory-0/") && $0.name == "N_move2" })
        let accessoryRoot = try #require(source.rig.nodes.first { $0.sourceID.hasPrefix("accessory-0/") && $0.parent.map { !source.rig.nodes[$0].sourceID.hasPrefix("accessory-0/") } == true })
        #expect(source.rig.nodes[try #require(accessoryRoot.parent)].name == "a_n_megane")
        if sample.moved {
            #expect(simd_distance(move.translation, Float3(0.015, -0.0225, -0.0375)) < 1e-7)
            #expect(simd_distance(move.scale, Float3(1.1, 0.9, 1.2)) < 1e-7)
            // Independent rotation matrices: source order is Y * X * Z; reflect Z.
            let x: Float = 12 * .pi / 180, y: Float = 23 * .pi / 180, z: Float = 34 * .pi / 180
            let rx = float3x3(columns: (.init(1,0,0), .init(0,cos(x),sin(x)), .init(0,-sin(x),cos(x))))
            let ry = float3x3(columns: (.init(cos(y),0,-sin(y)), .init(0,1,0), .init(sin(y),0,cos(y))))
            let rz = float3x3(columns: (.init(cos(z),sin(z),0), .init(-sin(z),cos(z),0), .init(0,0,1)))
            let reflect = float3x3(diagonal: Float3(1,1,-1)), expected = reflect * ry * rx * rz * reflect
            let actual = float3x3(move.rotation)
            for column in 0..<3 { #expect(simd_distance(actual[column], expected[column]) < 1e-6) }
        } else { #expect(move.translation == .zero && move.scale == .one) }
        let folder = base.deletingLastPathComponent()
        let contract = try SourceShapeContract.decode(Data(contentsOf: folder.appendingPathComponent("character-shape-contract.json")))
        let correction = sample.boneType == 0 ? nil : try Data(contentsOf: folder.appendingPathComponent("shapecorrect.bytes"))
        let options = try SourceMakerAssemblyOptions.body(sex: custom.sex, boneType: custom.boneType, correctionData: correction)
        let appearance = try SourceCardAppearance(card: card)
        let baseAppearance = try SourcePreviewAppearance.load(url: base.deletingPathExtension().appendingPathExtension("appearance.json"), resources: resources)
        let applied = try #require(try prepared.appearance(base: baseAppearance, card: appearance, resources: resources, modLibrary: nil))
        #expect(!applied.appliedFields.isEmpty)
        let preview = try SourceRigPreview(source: source, contract: contract, resources: resources, appearance: applied.appearance, bodyOptions: options)
        let pose = try preview.pose(bodyValues: custom.bodyValues, faceValues: custom.faceValues)
        let frame = try preview.frame(camera: OrbitCamera(), poseOverride: pose)
        #expect(frame.items.count >= source.parts.count && frame.sceneBounds.radius.isFinite)
        #expect(frame.sceneBounds.radius > 0.5 && frame.sceneBounds.radius < 3)
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]), "Requires IKKOKU_MAKER_SELECTION_FIXTURES"))
func sourceMakerSelectedCardEditsKeepOpaqueTokensResolverAndAssetIdentity() throws {
    let (fixtures, directory) = try MakerSelectionCases.load()
    for sample in fixtures.fixtures {
        let original = try SourceCharacterCard.decode(Data(contentsOf: directory.appendingPathComponent(sample.file)))
        let body = try original.recordFields(.body), unknown = try #require(body["fixtureOpaque99"])
        #expect(try unknown.stringKeyedMap().count == sample.opaqueTokenCount)
        let beforeAppearance = try SourceCardAppearance(card: original)
        let edit = SourceCharacterCard.ColorEdit(record: .body, path: [.key("skinMainColor")], rgba: [0.8,0.7,0.6,1])
        let result = try SourceCharacterCard.decode(original.editedData(.init(bodyValues: Array(repeating: 0.45, count: 44), colors: [edit])))
        #expect(try result.recordFields(.body)["fixtureOpaque99"] == unknown)
        #expect(try result.recordData(.hair) == original.recordData(.hair))
        #expect(try result.recordData(.face) == original.recordData(.face))
        #expect(result.block(named: "Coordinate")?.data == original.block(named: "Coordinate")?.data)
        for name in ["KKEx", "FixtureUnknown", "Parameter", "Status"] {
            #expect(result.block(named: name)?.data == original.block(named: name)?.data)
        }
        #expect(result.trailingData == original.trailingData)
        let appearance = try SourceCardAppearance(card: result)
        #expect(appearance.modProperties == beforeAppearance.modProperties)
        #expect(appearance.color("body.skinMainColor") == Float4(0.8,0.7,0.6,1))
        #expect(try result.modReferences()?.records.first?.localSlot == 900001)
        #expect(try result.customization().headID == sample.headID)
        #expect(try result.customization().boneType == sample.boneType)
    }
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_MAKER_SELECTION_FIXTURES"]) && MTLCreateSystemDefaultDevice() != nil, "Requires IKKOKU_MAKER_SELECTION_FIXTURES and a Metal device"))
func sourceMakerPreparedAppearanceEnforcesAggregateBudgetAndExactComponentContext() throws {
    let (fixtures, directory) = try MakerSelectionCases.load()
    let library = try SourceMakerLibrary.load(url: URL(fileURLWithPath: fixtures.library))
    let base = URL(fileURLWithPath: fixtures.femaleBase)
    let original = try SourceCharacterCard.load(url: directory.appendingPathComponent("female-head0-bone0.png"))
    let card = try SourceCardAppearance(card: original)
    let selected = try library.prepare(card: original, coordinate: 0, baseURL: base)
    let inputs = try selected.prepareAppearanceInputs(card: card, baseURL: base)
    let largestCall = try #require(inputs.perCallByteCounts.max())
    #expect(largestCall > 0 && inputs.byteCount > largestCall)
    // Every individual input call fits this limit, but their retained sum does
    // not. The aggregate must reject using the remaining candidate allowance.
    do {
        _ = try selected.prepareAppearanceInputs(card: card, baseURL: base, maximumBytes: largestCall)
        Issue.record("Independent per-call budgets bypassed the candidate cap.")
    } catch { #expect(String(describing: error).contains("retained byte limit")) }
    #expect(throws: (any Error).self) { try selected.prepareAppearanceInputs(card: card, baseURL: base, maximumBytes: 128 * 1024 * 1024 + 1) }

    // A real unresolved hair selection uses its retained reference geometry,
    // giving a different component set while the head/base assembly stays equal.
    let fallbackCard = try SourceCharacterCard.decode(original.selectingVanillaAsset(Int(Int32.max), at: .hair(0)))
    let fallback = try library.prepare(card: fallbackCard, coordinate: 0, baseURL: base)
    let resources = ResourceStore(device: try #require(MTLCreateSystemDefaultDevice()))
    let before = resources.statistics().textures
    do {
        _ = try fallback.appearance(base: nil, card: SourceCardAppearance(card: fallbackCard), resources: resources, modLibrary: nil, inputs: inputs)
        Issue.record("Prepared pixels crossed selected component contexts.")
    } catch { #expect(String(describing: error).contains("different selected components")) }
    #expect(resources.statistics().textures == before)
    let temporary = try AppearanceTestFixture.directory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let preview = try AppearanceTestFixture.preview(directory: temporary, resources: resources)
    do {
        _ = try inputs.applyingBase(to: preview, card: card, baseURL: temporary.appendingPathComponent("other-head.json"), resources: resources)
        Issue.record("Prepared pixels crossed base assembly contexts.")
    } catch { #expect(String(describing: error).contains("different base assembly")) }
    #expect(resources.statistics().textures == before)
    #expect(try original.editedData(.init()) == original.preservedData)
}

@MainActor @Test func sourceMakerWorkerDiagnosticsPreserveRigLoadErrorOrderAndPartialReads() throws {
    let directory = try MakerLibraryFixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let library = try MakerLibraryFixture.library([], directory: directory)
    typealias F = OriginalCardFixture
    let custom = try #require(try AppearanceTestFixture.card().block(named: "Custom")?.data)
    let clothes = F.pack(F.map([("version", .string("0.0.1")), ("parts", .array([]))]))
    let accessory = F.pack(F.map([("version", .string("0.0.2")), ("parts", .array([]))]))
    let makeup = F.pack(F.map([("version", .string("0.0.0"))]))
    let outfit = F.lengthData(clothes) + F.lengthData(accessory) + Data([0]) + F.lengthData(makeup)
    var blocks = F.blocks(custom: custom)
    blocks.append(.init(name: "Coordinate", version: "0.0.0", data: F.pack(.array(Array(repeating: .binary(outfit), count: 7)))))
    let card = try SourceCharacterCard.decode(F.card(blocks: blocks))
    let url = directory.appendingPathComponent("source-avatar.json"), first = directory.appendingPathComponent("first.json")
    let manifest: [String: Any] = ["schemaVersion": 1, "kind": "koikatsu-female-avatar", "name": "fixture", "sex": 1, "headID": 0,
        "bodySkeleton": "first.json", "headSkeleton": "../must-not-resolve.json", "body": ["file": "missing-body.json"],
        "head": ["file": "missing-head.json"], "clothes": [], "hair": []]
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    let malformed = Data("malformed rig".utf8); try malformed.write(to: first)
    func failure(_ action: () throws -> Void) -> [String: String] {
        do { try action(); Issue.record("Invalid rig unexpectedly loaded"); return [:] }
        catch DecodingError.dataCorrupted(let context) {
            // NSError descriptions contain dictionary order and object addresses.
            // Compare the actual decoding case/context and underlying error identity.
            var value = ["kind": "dataCorrupted", "context": context.debugDescription,
                "codingPath": context.codingPath.map(\.stringValue).joined(separator: "/")]
            if let error = context.underlyingError as NSError? {
                value["underlyingDomain"] = error.domain; value["underlyingCode"] = String(error.code)
                value["underlyingPath"] = error.userInfo[NSFilePathErrorKey] as? String ?? ""
            }
            return value
        } catch {
            let error = error as NSError
            var value = ["kind": "error", "domain": error.domain, "code": String(error.code),
                "path": error.userInfo[NSFilePathErrorKey] as? String ?? ""]
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                value["underlyingDomain"] = underlying.domain; value["underlyingCode"] = String(underlying.code)
                value["underlyingPath"] = underlying.userInfo[NSFilePathErrorKey] as? String ?? ""
            }
            return value
        }
    }
    let reference = failure { _ = try SourceRig.load(url: first) }
    #expect(reference["kind"] == "dataCorrupted")
    #expect(failure { _ = try library.prepare(card: card, coordinate: 0, baseURL: url) } == reference)
    let timings = SourceMakerPreparationTimings()
    #expect(failure { _ = try library.prepare(card: card, coordinate: 0, baseURL: url, timings: timings) } == reference)
    #expect(timings.sample.bytesRead["rigRead"] == malformed.count)
    #expect(timings.sample.intervals["rigRead"]?.calls == 1 && timings.sample.intervals["rigRead"]?.failures == 0)
    #expect(timings.sample.intervals["rigDecode"]?.calls == 1 && timings.sample.intervals["rigDecode"]?.failures == 1)
    #expect(timings.sample.intervals["assembly"] == nil)
    let reuseTimings = SourceMakerPreparationTimings(), worker = SourceRigReuseWorker(SourceMakerRigReuse().input())
    #expect(failure { _ = try library.prepare(card: card, coordinate: 0, baseURL: url, wear: false,
        timings: reuseTimings, rigReuse: worker) } == reference)
    #expect(reuseTimings.sample.intervals["rigRead"]?.calls == 1 && reuseTimings.sample.intervals["rigReuseSHA"]?.calls == 1)
    #expect(reuseTimings.sample.intervals["rigDecode"]?.failures == 1 && reuseTimings.sample.intervals["assembly"] == nil)
    try FileManager.default.removeItem(at: first)
    let missing = SourceMakerPreparationTimings()
    #expect(failure { _ = try library.prepare(card: card, coordinate: 0, baseURL: url, timings: missing) }
        == failure { _ = try SourceRig.load(url: first) })
    #expect(missing.sample.intervals["rigRead"]?.failures == 1 && missing.sample.intervals["rigDecode"] == nil)
    #expect(missing.sample.bytesRead["rigRead"] == nil)
    let reuseMissing = SourceMakerPreparationTimings()
    #expect(failure { _ = try library.prepare(card: card, coordinate: 0, baseURL: url, wear: false,
        timings: reuseMissing, rigReuse: worker) } == failure { _ = try SourceRig.load(url: first) })
    #expect(reuseMissing.sample.intervals["rigRead"]?.failures == 1)
    #expect(reuseMissing.sample.intervals["rigReuseSHA"] == nil && reuseMissing.sample.intervals["rigDecode"] == nil)
}
