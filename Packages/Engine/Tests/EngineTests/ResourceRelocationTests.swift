import Testing
import Foundation
import CryptoKit
import Assets
import Character
import Studio

// A-T02 library location and relocation. Every library here is synthetic: a
// converted-library root laid out like `.local/reverse/` (Maker library, female
// base, Studio pose files and a converted prop), a native asset library with one
// catalog item, and an original-scene stand-in outside both. A document saved
// against them is moved with its library and resolved again.

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private struct RelocationFixture {
    /// Root-relative path → bytes of every converted-library file the document references.
    static let files: [String: Data] = [
        "maker-library/library.json": Data(#"{"schemaVersion":1,"entries":[]}"#.utf8),
        "rigs/source-avatar.json": Data(#"{"schemaVersion":1,"kind":"koikatsu-female-avatar","name":"synthetic"}"#.utf8),
        "studio-pose/contract.json": Data(#"{"bones":[]}"#.utf8),
        "studio-pose/attachments.json": Data(#"{"attachments":[]}"#.utf8),
        "items/prop.gltf": Data(#"{"asset":{"version":"2.0"}}"#.utf8),
    ]
    static let catalogJSON = #"{"version":1,"regions":{},"bodies":[],"hair":[],"clothes":[],"accessories":[],"items":[{"id":"chair","file":"Items/chair.glb","category":"Furniture","name":"Chair"}],"textures":{}}"#

    let base: URL, old: URL, assets: URL, scene: URL
    let sceneData = Data("synthetic original scene bytes".utf8)
    let catalog: Catalog

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ikkoku-relocation-\(UUID().uuidString)", isDirectory: true)
        let old = base.appendingPathComponent("old", isDirectory: true)
        let assets = base.appendingPathComponent("assets", isDirectory: true)
        let scene = base.appendingPathComponent("scene.png")
        for (relative, data) in Self.files {
            let url = old.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try fm.createDirectory(at: assets.appendingPathComponent("Items", isDirectory: true), withIntermediateDirectories: true)
        try Data(Self.catalogJSON.utf8).write(to: assets.appendingPathComponent("catalog.json"))
        try Data("synthetic chair".utf8).write(to: assets.appendingPathComponent("Items/chair.glb"))
        try Data("synthetic original scene bytes".utf8).write(to: scene)
        self.base = base; self.old = old; self.assets = assets; self.scene = scene
        catalog = try JSONDecoder().decode(Catalog.self, from: Data(Self.catalogJSON.utf8))
    }

    func path(_ relative: String) -> String { old.appendingPathComponent(relative).path }
    func digest(_ relative: String) -> String { sha(Self.files[relative] ?? Data()) }

    /// The converted libraries under `root` plus the asset library.
    func libraries(at root: URL) throws -> ResourceLibraryLocation {
        var records = try ResourceLibraryLocation.convertedRoot(root).libraries
        records.append(try ResourceLibraryRecord.inspect(kind: .assets, root: assets))
        return ResourceLibraryLocation(libraries: records)
    }

    /// A source character with five converted-library paths, a converted prop and a catalog item.
    func document() -> StudioDocument {
        var document = StudioDocument()
        document.sourceSceneFile = scene.path
        document.sourceSceneSHA256 = sha(sceneData)
        var character = StudioObject(name: "Source character", kind: .character)
        character.sourceCharacter = SourceStudioCharacterReference(sceneFile: scene.path, sceneSHA256: sha(sceneData),
            rigFile: path("rigs/source-avatar.json"), boneCatalogFile: path("studio-pose/contract.json"), objectKey: 7,
            makerLibraryFile: path("maker-library/library.json"), attachmentCatalogFile: path("studio-pose/attachments.json"))
        var prop = StudioObject(name: "Converted prop", kind: .item)
        prop.assetFile = path("items/prop.gltf")
        document.objects = [character, prop, StudioObject.item(id: "chair", name: "Chair")]
        return document
    }

    /// Records the binding as a save does, writes the scene card and reads it back.
    func saveAndReload(_ document: StudioDocument, libraries: ResourceLibraryLocation) throws -> StudioDocument {
        let saved = document.recordingResourceBinding(libraries: libraries.libraries)
        let url = base.appendingPathComponent("document-\(UUID().uuidString).png")
        try CardIO.encode(saved, keyword: CardIO.sceneKeyword, thumbnail: nil).write(to: url)
        return try CardIO.decode(StudioDocument.self, keyword: CardIO.sceneKeyword, from: Data(contentsOf: url))
    }

    func moveLibrary(to name: String) throws -> URL {
        let destination = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: old, to: destination)
        return destination
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// The document's five converted-library references and their root-relative files.
    static var libraryFields: [(field: StudioResourceField, relative: String)] {
        [(.rigFile, "rigs/source-avatar.json"), (.boneCatalogFile, "studio-pose/contract.json"),
         (.makerLibraryFile, "maker-library/library.json"), (.attachmentCatalogFile, "studio-pose/attachments.json"),
         (.assetFile, "items/prop.gltf")]
    }
}

@Test func relocatedLibraryResolvesEveryReferenceWithItsRecordedIdentity() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let original = try fixture.libraries(at: fixture.old)
    let loaded = try fixture.saveAndReload(fixture.document(), libraries: original)
    let binding = try #require(loaded.resourceBinding)
    #expect(binding.version == ResourceBinding.currentVersion)
    // The scene once (document and character share its path) and five library files;
    // the catalog item is not a path. Only libraries holding a recorded file are kept.
    #expect(binding.files.count == 6)
    #expect(binding.libraries.map(\.kind) == [.femaleBase, .makerLibrary])
    for (_, relative) in RelocationFixture.libraryFields {
        let identity = try #require(binding.file(fixture.path(relative)))
        #expect(identity.sha256 == fixture.digest(relative))
        #expect(identity.relativePath == relative)
    }
    let sceneIdentity = try #require(binding.file(fixture.scene.path))
    #expect(sceneIdentity.libraryRoot == nil)

    // Where it was saved, everything resolves in place and nothing is rewritten.
    let inPlace = loaded.resolvingResources(current: original, catalog: fixture.catalog)
    #expect(inPlace.report.unresolved.isEmpty)
    #expect(inPlace.report.relocated.isEmpty)
    #expect(inPlace.document == loaded)
    #expect(inPlace.diagnostics.isEmpty)

    let moved = try fixture.moveLibrary(to: "moved")
    let current = try fixture.libraries(at: moved)
    let result = loaded.resolvingResources(current: current, catalog: fixture.catalog)
    #expect(result.report.unresolved.isEmpty)
    #expect(result.blockedObjects.isEmpty)
    #expect(result.blockedFields.isEmpty)
    #expect(result.report.relocated.count == 5)
    for (field, relative) in RelocationFixture.libraryFields {
        let resolution = try #require(result.resolution(field))
        #expect(resolution.status == .relocated)
        #expect(resolution.verification == .sha256)
        #expect(resolution.expectedSHA256 == fixture.digest(relative))
        let path = try #require(resolution.path)
        #expect(path == moved.appendingPathComponent(relative).path)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(sha(bytes) == fixture.digest(relative))
    }
    // The original scene lies outside the library: verified in place by its own digest.
    let sceneResolution = try #require(result.resolution(.sourceSceneFile))
    #expect(sceneResolution.status == .resolved)
    #expect(sceneResolution.verification == .sha256)
    let chair = try #require(result.resolution(.itemID))
    #expect(chair.status == .resolved)
    #expect(chair.verification == .catalog)
    #expect(chair.path == fixture.assets.appendingPathComponent("Items/chair.glb").path)

    // The relocated document names the moved files; the binding stays as saved.
    let character = try #require(result.document.objects[0].sourceCharacter)
    #expect(character.rigFile == moved.appendingPathComponent("rigs/source-avatar.json").path)
    #expect(character.boneCatalogFile == moved.appendingPathComponent("studio-pose/contract.json").path)
    #expect(character.makerLibraryFile == moved.appendingPathComponent("maker-library/library.json").path)
    #expect(character.attachmentCatalogFile == moved.appendingPathComponent("studio-pose/attachments.json").path)
    #expect(character.sceneFile == fixture.scene.path)
    #expect(character.sceneSHA256 == sha(fixture.sceneData))
    #expect(character.objectKey == 7)
    #expect(result.document.objects[1].assetFile == moved.appendingPathComponent("items/prop.gltf").path)
    #expect(result.document.sourceSceneFile == fixture.scene.path)
    #expect(result.document.resourceBinding == loaded.resourceBinding)
    #expect(result.diagnostics.count == 1)

    // Saved again, the binding records the moved root and the next load changes nothing.
    let resaved = try fixture.saveAndReload(result.document, libraries: current)
    let resavedBinding = try #require(resaved.resourceBinding)
    #expect(resavedBinding.libraries.count == 2)
    #expect(resavedBinding.libraries.allSatisfy { $0.root.hasSuffix("/moved") })
    let again = resaved.resolvingResources(current: current, catalog: fixture.catalog)
    #expect(again.report.relocated.isEmpty)
    #expect(again.report.unresolved.isEmpty)
    #expect(again.document == resaved)
}

@Test func changedOrReplacedFilesAreReportedAndNeverUsed() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let loaded = try fixture.saveAndReload(fixture.document(), libraries: try fixture.libraries(at: fixture.old))
    let moved = try fixture.moveLibrary(to: "moved")
    // One file is edited after the move; another is replaced by a different file.
    let edited = Data(#"{"attachments":[{"edited":true}]}"#.utf8)
    try edited.write(to: moved.appendingPathComponent("studio-pose/attachments.json"))
    let replaced = moved.appendingPathComponent("items/prop.gltf")
    try FileManager.default.removeItem(at: replaced)
    try FileManager.default.copyItem(at: moved.appendingPathComponent("studio-pose/contract.json"), to: replaced)
    let current = try fixture.libraries(at: moved)
    let result = loaded.resolvingResources(current: current, catalog: fixture.catalog)

    let attachments = try #require(result.resolution(.attachmentCatalogFile))
    #expect(attachments.status == .unresolved)
    #expect(attachments.path == nil)
    #expect(attachments.failure == ResourceResolutionFailure.identityMismatch(
        path: moved.appendingPathComponent("studio-pose/attachments.json").path,
        expectedSHA256: fixture.digest("studio-pose/attachments.json"), actualSHA256: sha(edited)))
    let prop = try #require(result.resolution(.assetFile))
    #expect(prop.status == .unresolved)
    #expect(prop.failure == ResourceResolutionFailure.identityMismatch(path: replaced.path,
        expectedSHA256: fixture.digest("items/prop.gltf"), actualSHA256: fixture.digest("studio-pose/contract.json")))
    #expect(result.report.unresolved.count == 2)
    #expect(result.report.relocated.count == 3)

    // Neither replacement is used: both fields keep their saved paths, and their
    // objects are blocked. The character's verified files still relocate.
    let character = try #require(result.document.objects[0].sourceCharacter)
    #expect(character.attachmentCatalogFile == fixture.path("studio-pose/attachments.json"))
    #expect(character.rigFile == moved.appendingPathComponent("rigs/source-avatar.json").path)
    #expect(result.document.objects[1].assetFile == fixture.path("items/prop.gltf"))
    #expect(result.blockedObjects == Set([result.document.objects[0].id, result.document.objects[1].id]))
    #expect(result.blockedFields.isEmpty)
    #expect(result.diagnostics.count == 3)
    #expect(result.diagnostics.contains { $0.contains(fixture.digest("items/prop.gltf")) })

    // Saving again keeps both saved identities instead of adopting the changed files.
    let resaved = try fixture.saveAndReload(result.document, libraries: current)
    let binding = try #require(resaved.resourceBinding)
    #expect(binding.file(fixture.path("studio-pose/attachments.json"))?.sha256 == fixture.digest("studio-pose/attachments.json"))
    #expect(binding.file(fixture.path("items/prop.gltf"))?.sha256 == fixture.digest("items/prop.gltf"))
    #expect(resaved.resolvingResources(current: current, catalog: fixture.catalog).report.unresolved.count == 2)
}

@Test func aFileChangedInPlaceKeepsItsSavedIdentityUntilItsBytesReturn() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let libraries = try fixture.libraries(at: fixture.old)
    let loaded = try fixture.saveAndReload(fixture.document(), libraries: libraries)
    let contract = fixture.old.appendingPathComponent("studio-pose/contract.json")
    let edited = Data(#"{"bones":["edited"]}"#.utf8)
    try edited.write(to: contract)

    let changed = loaded.resolvingResources(current: libraries, catalog: fixture.catalog)
    let bones = try #require(changed.resolution(.boneCatalogFile))
    #expect(bones.failure == ResourceResolutionFailure.identityMismatch(path: contract.path,
        expectedSHA256: fixture.digest("studio-pose/contract.json"), actualSHA256: sha(edited)))
    #expect(changed.blockedObjects == Set([loaded.objects[0].id]))

    let resaved = try fixture.saveAndReload(changed.document, libraries: libraries)
    #expect(resaved.resourceBinding?.file(contract.path)?.sha256 == fixture.digest("studio-pose/contract.json"))
    #expect(resaved.resolvingResources(current: libraries, catalog: fixture.catalog).report.unresolved.count == 1)

    // Restoring the saved bytes makes the reference resolve again.
    try (RelocationFixture.files["studio-pose/contract.json"] ?? Data()).write(to: contract)
    let restored = resaved.resolvingResources(current: libraries, catalog: fixture.catalog)
    #expect(restored.report.unresolved.isEmpty)
    #expect(restored.blockedObjects.isEmpty)
}

@Test func missingFilesAndUnselectedLibrariesAreReportedByIdentity() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let loaded = try fixture.saveAndReload(fixture.document(), libraries: try fixture.libraries(at: fixture.old))
    let recordedLibraries = try #require(loaded.resourceBinding?.libraries)
    let moved = try fixture.moveLibrary(to: "moved")
    try FileManager.default.removeItem(at: moved.appendingPathComponent("studio-pose/contract.json"))
    let current = try fixture.libraries(at: moved)
    let result = loaded.resolvingResources(current: current, catalog: fixture.catalog)

    let bones = try #require(result.resolution(.boneCatalogFile))
    #expect(bones.status == .unresolved)
    #expect(bones.path == nil)
    #expect(bones.failure == ResourceResolutionFailure.missing(path: moved.appendingPathComponent("studio-pose/contract.json").path))
    #expect(bones.expectedSHA256 == fixture.digest("studio-pose/contract.json"))
    let library = try #require(bones.library)
    #expect(recordedLibraries.contains(library))
    #expect(bones.description.contains(bones.reference.identity))
    #expect(bones.description.contains(fixture.digest("studio-pose/contract.json")))
    #expect(bones.description.contains(library.manifestSHA256.prefix(12)))
    #expect(result.report.unresolved.count == 1)
    #expect(result.document.objects[0].sourceCharacter?.boneCatalogFile == fixture.path("studio-pose/contract.json"))

    // With no converted library in effect, each file is checked at its saved path,
    // which the move emptied: reported with the library it was saved in.
    let assetsOnly = ResourceLibraryLocation(libraries: current.libraries.filter { $0.kind == .assets })
    let unselected = loaded.resolvingResources(current: assetsOnly, catalog: fixture.catalog)
    #expect(unselected.report.unresolved.count == 5)
    #expect(unselected.report.resolved.count == 3)
    let rig = try #require(unselected.resolution(.rigFile))
    #expect(rig.failure == ResourceResolutionFailure.missing(path: fixture.path("rigs/source-avatar.json")))
    #expect(rig.expectedSHA256 == fixture.digest("rigs/source-avatar.json"))
    #expect(rig.library?.root.hasSuffix("/old") == true)

    // A catalog ID the catalog lacks, and no asset library at all.
    var renamed = loaded
    renamed.objects[2].itemID = "sofa"
    let sofa = try #require(renamed.resolvingResources(current: current, catalog: fixture.catalog).resolution(.itemID))
    #expect(sofa.failure == ResourceResolutionFailure.notInCatalog(kind: .assets))
    #expect(sofa.reference.identity.hasSuffix("itemID sofa"))
    let noAssets = ResourceLibraryLocation(libraries: current.libraries.filter { $0.kind != .assets })
    let chair = try #require(loaded.resolvingResources(current: noAssets, catalog: fixture.catalog).resolution(.itemID))
    #expect(chair.failure == ResourceResolutionFailure.libraryNotSelected(kind: .assets))
}

@Test func referencesThatEscapeTheLibraryRootAreRejected() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let loaded = try fixture.saveAndReload(fixture.document(), libraries: try fixture.libraries(at: fixture.old))
    let moved = try fixture.moveLibrary(to: "moved")
    let current = try fixture.libraries(at: moved)
    let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideContract = outside.appendingPathComponent("contract.json")
    try (RelocationFixture.files["studio-pose/contract.json"] ?? Data()).write(to: outsideContract)

    // A symlink to an outside copy with the recorded bytes: rejected by containment
    // even though its digest matches.
    let link = moved.appendingPathComponent("studio-pose/contract.json")
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideContract)
    let linked = loaded.resolvingResources(current: current, catalog: fixture.catalog)
    let bones = try #require(linked.resolution(.boneCatalogFile))
    #expect(bones.status == .unresolved)
    #expect(bones.path == nil)
    let symlinkRejected: Bool
    if case .escapesLibraryRoot? = bones.failure { symlinkRejected = true } else { symlinkRejected = false }
    #expect(symlinkRejected)
    #expect(linked.document.objects[0].sourceCharacter?.boneCatalogFile == fixture.path("studio-pose/contract.json"))

    // A crafted binding whose relative path climbs out of the root is refused
    // before any file is read.
    var crafted = loaded
    var binding = try #require(crafted.resourceBinding)
    for index in binding.files.indices where binding.files[index].relativePath == "studio-pose/attachments.json" {
        binding.files[index].relativePath = "../outside/contract.json"
    }
    crafted.resourceBinding = binding
    let climbing = try #require(crafted.resolvingResources(current: current, catalog: fixture.catalog).resolution(.attachmentCatalogFile))
    let climbRejected: Bool
    if case .escapesLibraryRoot(let reference, _)? = climbing.failure { climbRejected = reference == "../outside/contract.json" } else { climbRejected = false }
    #expect(climbRejected)

    // A catalog path that climbs out of the asset library.
    let escapingCatalog = try JSONDecoder().decode(Catalog.self, from: Data(RelocationFixture.catalogJSON
        .replacingOccurrences(of: "Items/chair.glb", with: "../outside/contract.json").utf8))
    let item = try #require(loaded.resolvingResources(current: current, catalog: escapingCatalog).resolution(.itemID))
    let itemRejected: Bool
    if case .escapesLibraryRoot? = item.failure { itemRejected = true } else { itemRejected = false }
    #expect(itemRejected)

    // A library manifest outside its root is refused when the library is recorded.
    try Data(#"{"schemaVersion":1,"entries":[]}"#.utf8).write(to: outside.appendingPathComponent("library.json"))
    #expect(throws: ResourceLibraryError.self) {
        try ResourceLibraryRecord.inspect(kind: .makerLibrary, root: moved, manifest: "../outside/library.json")
    }
    let manifest = moved.appendingPathComponent("maker-library/library.json")
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside.appendingPathComponent("library.json"))
    #expect(throws: ResourceLibraryError.self) { try ResourceLibraryRecord.inspect(kind: .makerLibrary, root: moved) }
}

@Test func recordedContentInEffectAtTwoRootsIsAmbiguous() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let loaded = try fixture.saveAndReload(fixture.document(), libraries: try fixture.libraries(at: fixture.old))
    let first = try fixture.moveLibrary(to: "first")
    let second = fixture.base.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.copyItem(at: first, to: second)
    let current = ResourceLibraryLocation(libraries: [
        try ResourceLibraryRecord.inspect(kind: .makerLibrary, root: first),
        try ResourceLibraryRecord.inspect(kind: .femaleBase, root: second),
        try ResourceLibraryRecord.inspect(kind: .assets, root: fixture.assets),
    ])
    let result = loaded.resolvingResources(current: current, catalog: fixture.catalog)
    let rig = try #require(result.resolution(.rigFile))
    let ambiguous: Bool
    if case .ambiguousLibrary(let roots)? = rig.failure { ambiguous = roots.count == 2 } else { ambiguous = false }
    #expect(ambiguous)
    #expect(result.report.unresolved.count == 5)
    #expect(result.report.relocated.isEmpty)
}

@Test func libraryLocationRecordsAreVersionedContentIdentities() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let location = try ResourceLibraryLocation.convertedRoot(fixture.old)
    #expect(location.version == ResourceLibraryLocation.currentVersion)
    #expect(location.libraries.map(\.kind) == [.femaleBase, .makerLibrary])
    let maker = try #require(location.library(.makerLibrary))
    #expect(maker.manifest == "maker-library/library.json")
    #expect(maker.manifestSHA256 == fixture.digest("maker-library/library.json"))
    #expect(maker.formatVersion == 1)
    #expect(try ResourceLibraryLocation.decode(location.encoded()) == location)
    // An explicit manifest at its conventional path names the same library root.
    let explicit = try ResourceLibraryRecord.inspect(kind: .makerLibrary,
        manifestFile: fixture.old.appendingPathComponent("maker-library/library.json"))
    #expect(explicit == maker)
    // Another record version is refused rather than reinterpreted.
    var future = location
    future.version = 2
    #expect(throws: ResourceLibraryError.unsupportedVersion(2)) { try ResourceLibraryLocation.decode(future.encoded()) }
    // A folder without converted manifests, and a manifest of another kind.
    #expect(throws: ResourceLibraryError.noConvertedLibrary(root: fixture.assets.standardizedFileURL.path)) {
        try ResourceLibraryLocation.convertedRoot(fixture.assets)
    }
    #expect(throws: ResourceLibraryError.self) {
        try ResourceLibraryRecord.inspect(kind: .maleBase, root: fixture.old, manifest: "rigs/source-avatar.json")
    }
    // Other bytes at the same root are another library.
    try Data(#"{"schemaVersion":1,"entries":[],"regenerated":true}"#.utf8)
        .write(to: fixture.old.appendingPathComponent("maker-library/library.json"))
    let changes = location.changedLibraries()
    #expect(changes.map { $0.recorded.kind } == [.makerLibrary])
    let regenerated = try #require(changes.first?.current)
    #expect(!regenerated.sameContent(as: maker))
    #expect(regenerated.root == maker.root)
}

@Test func convertedSelectionRecordsAndReportsItsCompanionFiles() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let fm = FileManager.default
    // The lookups read the companions beside the female base manifest; the helper is
    // exactly the former `../` expression of AppState and MakerModel.
    let rig = fixture.old.appendingPathComponent("rigs/source-avatar.json")
    #expect(ResourceCompanion.studioPoseContract.url(besideManifest: rig)
            == rig.deletingLastPathComponent().appendingPathComponent("../studio-pose/contract.json").standardizedFileURL)
    #expect(ResourceCompanion.femaleBaseAnimation.url(besideManifest: rig)
            == rig.deletingLastPathComponent().appendingPathComponent("../animation-assets/female-base/animation.json").standardizedFileURL)
    // The fixture layout has the Studio pose contract and no animation library.
    let location = try ResourceLibraryLocation.convertedRoot(fixture.old)
    let contract = fixture.old.appendingPathComponent("studio-pose/contract.json").standardizedFileURL
    #expect(location.companions == [ResourceCompanionRecord(companion: .studioPoseContract, path: contract.path,
                                                            sha256: fixture.digest("studio-pose/contract.json"))])
    #expect(try ResourceLibraryLocation.decode(location.encoded()) == location)
    let missingAnimation = location.companionProblems()
    #expect(missingAnimation.map(\.companion) == [.femaleBaseAnimation])
    #expect(missingAnimation.first?.currentSHA256 == nil)
    #expect(missingAnimation.first?.description.contains("animation-assets/female-base/animation.json is missing") == true)
    // A companion added after the selection is reported as unrecorded, not trusted.
    let animation = fixture.old.appendingPathComponent("animation-assets/female-base/animation.json")
    try fm.createDirectory(at: animation.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"states":[]}"#.utf8).write(to: animation)
    let unrecorded = try #require(location.companionProblems().first)
    #expect(unrecorded.companion == .femaleBaseAnimation && unrecorded.recordedSHA256 == nil && unrecorded.currentSHA256 != nil)
    let complete = try ResourceLibraryLocation.convertedRoot(fixture.old)
    #expect(complete.companions.map(\.companion) == [.studioPoseContract, .femaleBaseAnimation])
    #expect(complete.companionProblems().isEmpty)
    // Other contract bytes after the selection are a change.
    try Data(#"{"bones":[],"regenerated":true}"#.utf8).write(to: contract)
    let changed = complete.companionProblems()
    #expect(changed.map(\.companion) == [.studioPoseContract])
    #expect(changed.first?.recordedSHA256 == fixture.digest("studio-pose/contract.json"))
    #expect(changed.first?.description.contains("changed since the library was selected") == true)
    // The 2026-10-23 manual run: the layout copied with maker-library/ and rigs/
    // only. The selection still succeeds (the Maker needs no companion) and names
    // the missing contract instead of reporting success.
    let copy = fixture.base.appendingPathComponent("copy", isDirectory: true)
    for folder in ["maker-library", "rigs"] {
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        try fm.copyItem(at: fixture.old.appendingPathComponent(folder), to: copy.appendingPathComponent(folder))
    }
    let partial = try ResourceLibraryLocation.convertedRoot(copy)
    #expect(partial.libraries.map(\.kind) == [.femaleBase, .makerLibrary])
    #expect(partial.companions.isEmpty)
    let gaps = partial.companionProblems()
    #expect(gaps.map(\.companion) == [.studioPoseContract, .femaleBaseAnimation])
    #expect(gaps.first?.path == copy.appendingPathComponent("studio-pose/contract.json").standardizedFileURL.path)
    #expect(gaps.first?.description.contains("source scene characters cannot be previewed") == true)
    // Without a female base no companion applies.
    let makerOnly = fixture.base.appendingPathComponent("maker-only", isDirectory: true)
    try fm.createDirectory(at: makerOnly, withIntermediateDirectories: true)
    try fm.copyItem(at: fixture.old.appendingPathComponent("maker-library"), to: makerOnly.appendingPathComponent("maker-library"))
    let maker = try ResourceLibraryLocation.convertedRoot(makerOnly)
    #expect(maker.companions.isEmpty && maker.companionProblems().isEmpty)
    // A selection saved before companions were recorded decodes with none; a
    // duplicate companion record is refused.
    let legacy = try ResourceLibraryLocation.decode(Data(#"{"version":1,"libraries":[]}"#.utf8))
    #expect(legacy.companions.isEmpty)
    var duplicate = complete
    duplicate.companions.append(duplicate.companions[0])
    #expect(throws: ResourceLibraryError.self) { try ResourceLibraryLocation.decode(duplicate.encoded()) }
}

@Test func documentsWithoutABindingResolveInPlaceAndUnsupportedBindingsAreRefused() throws {
    let fixture = try RelocationFixture()
    defer { fixture.remove() }
    let libraries = try fixture.libraries(at: fixture.old)
    // A document saved before A-T02 has no binding: paths are checked where they
    // are, against the scene digest the document records itself.
    let legacy = fixture.document()
    let legacyHasBinding = legacy.resourceBinding != nil
    #expect(!legacyHasBinding)
    let result = legacy.resolvingResources(current: libraries, catalog: fixture.catalog)
    #expect(result.report.unresolved.isEmpty)
    #expect(result.document == legacy)
    let rig = try #require(result.resolution(.rigFile))
    #expect(rig.verification == ResourceResolution.Verification.unverified)
    let scene = try #require(result.resolution(.characterSceneFile))
    #expect(scene.verification == ResourceResolution.Verification.sha256)

    // A scene with only catalog items records no binding and saves as before.
    var native = StudioDocument()
    native.objects = [StudioObject.item(id: "chair", name: "Chair")]
    let nativeHasBinding = native.recordingResourceBinding(libraries: libraries.libraries).resourceBinding != nil
    #expect(!nativeHasBinding)

    // A binding version this build does not read fails every file reference.
    var future = try fixture.saveAndReload(fixture.document(), libraries: libraries)
    future.resourceBinding?.version = 2
    let refused = future.resolvingResources(current: libraries, catalog: fixture.catalog)
    #expect(refused.report.unresolved.count == 7)
    #expect(refused.resolution(.rigFile)?.failure == ResourceResolutionFailure.unsupportedBinding(version: 2))
    #expect(refused.blockedFields == Set([StudioResourceField.sourceSceneFile]))
}
