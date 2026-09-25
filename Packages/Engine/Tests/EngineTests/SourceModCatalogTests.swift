import Foundation
import Testing
import CryptoKit
import CoreGraphics
import ImageIO
import Assets

private func catalogTestHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func catalogTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceModCatalog-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func catalogTestContract() throws -> SourceModCatalogContract {
    let document: [String: Any] = ["schemaVersion": 1,
        "keyTypes": ["Category", "DistributionNo", "ID", "Possess", "Name", "MainAB", "MainData", "MainManifest", "MainTexAB", "MainTex", "ThumbAB", "ThumbTex"],
        "categories": [["number": 122, "name": "accessory", "properties": ["Access.id"]],
            ["number": 105, "name": "clothes", "properties": ["Clothes.id"]],
            ["number": 408, "name": "texture", "properties": ["Face.Pupil1", "Face.Pupil2"]]],
        "referenceRules": [
            ["role": "mainPrefab", "categories": [122], "expectedType": "GameObject", "bundleField": "MainAB", "assetField": "MainData",
                "manifestField": "MainManifest", "disabledAssetValues": [""], "disabledBundleValues": [] as [String]],
            ["role": "clothesTexture", "categories": [105], "expectedType": "Texture2D", "bundleField": "MainTexAB", "assetField": "MainTex",
                "manifestField": "MainManifest", "fallbackBundleField": "MainAB", "disabledAssetValues": ["0"], "disabledBundleValues": ["0"]],
            ["role": "texture", "categories": [408], "expectedType": "Texture2D", "bundleField": "MainTexAB", "assetField": "MainTex",
                "manifestField": "MainManifest", "disabledAssetValues": ["0"], "disabledBundleValues": ["0"]]]]
    return try SourceModCatalogContract.decode(JSONSerialization.data(withJSONObject: document))
}

func catalogTestPackage(_ directory: URL, guid: String = "fixture.mod", csvs: [String],
                                rfcMetadata: Bool = false, texture: Bool = false,
                                textureBundlePath: String = "abdata/chara/textures.unity3d") throws -> SourceModPackage {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var catalogs: [[String: Any]] = []
    for (index, csv) in csvs.enumerated() {
        let data = Data(csv.utf8), path = "catalog-\(index).csv"
        try data.write(to: directory.appendingPathComponent(path))
        var catalog: [String: Any] = ["sourcePath": "abdata/list/characustom/fixture-\(index).csv", "path": path,
            "sha256": catalogTestHash(data), "status": "preserved", "parseStatus": "unsupported"]
        if rfcMetadata {
            catalog.removeValue(forKey: "parseStatus")
            catalog["columns"] = ["ID", "Name", "Possess"]
            catalog["rows"] = [["7", "a,b", "0"]] // A valid RFC interpretation that the source game does not use.
            catalog["preamble"] = ["122", "0", "Assets/list.bytes"]; catalog["encoding"] = "utf-8"
        }
        catalogs.append(catalog)
    }
    var resources: [[String: Any]] = []
    if texture {
        let bytes = Data([255, 64, 32, 255])
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let buffer = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); try #require(CGImageDestinationFinalize(output))
        let png = buffer as Data; try png.write(to: directory.appendingPathComponent("texture.png"))
        resources = [["id": "paint", "kind": "texture2D", "status": "converted", "bundlePath": textureBundlePath, "assetName": "paint",
            "sourcePathID": 1, "sourceSHA256": catalogTestHash(bytes), "path": "texture.png", "sha256": catalogTestHash(png), "width": 1, "height": 1]]
    }
    let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ikkoku-mod-package", "converter": ["id": "ikkoku.zipmod", "version": "1.0.0"],
        "source": ["guid": guid, "version": "1", "name": guid, "games": ["Koikatsu"], "archiveSHA256": catalogTestHash(Data(guid.utf8))],
        "resources": resources, "catalogs": catalogs, "diagnostics": [] as [[String: Any]]]
    let url = directory.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    return try SourceModPackage.load(url: url)
}

@Test func sourceModCatalogUsesRawCommaSplitAndStopsAtFirstNoCommaLine() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let csv = "122,ignored\n0,ignored\n Assets/list.bytes ,ignored\nID,Name,Possess\n 7,\"a,b\",0 \nstop\n8,ignored,0\n"
    let package = try catalogTestPackage(directory, csvs: [csv], rfcMetadata: true)
    let library = try SourceModLibrary(packages: [package])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    #expect(catalog.entries.count == 1)
    let entry = try #require(catalog.entries.first)
    #expect(entry.key.sourceSlot == 7 && entry.name == "\"a" && entry.info("Possess") == "1")
    #expect(entry.sourceFilePath == "Assets/list.bytes" && entry.distribution == 0)
    #expect(entry.info("ID") == "7")
    #expect(package.catalogs[0].rows == [["7", "a,b", "0"]])
}

@Test func sourceModCatalogDuplicateHeadersUseLastWriteAfterFirstPossessIsForced() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let csv = "122\n3\nignored-target\nID, Name,Name,Name,Possess,Possess\n8,unknown,first,last,0,9\n"
    let empty = "122\n0\ntarget\nID,Name,MainManifest\n9,,\n"
    let library = try SourceModLibrary(packages: [catalogTestPackage(directory, csvs: [csv, empty])])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    let first = try #require(catalog.entries.first), last = try #require(catalog.entries.last)
    #expect(first.name == "last" && first.info("Possess") == "9" && first.distribution == 3)
    #expect(first.fields[" Name"] == nil)
    #expect(catalog.diagnostics.contains { $0.code == "unknown_catalog_columns" })
    #expect(last.info("Name") == "" && last.info("MainManifest") == "")
    #expect(last.info("Possess") == "0" && last.info("MainData") == "0")
    #expect(first.references.first?.manifest == "0" && last.references.first?.manifest == "abdata")
}

@Test func sourceModCatalogDistributionUsesHeaderOverrideAndInvalidIntegerSentinel() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let overridden = "122\n3\ntarget\nID,Name,DistributionNo\n1,valid,9\n2,negative,-5\n3,invalid,not-int\n4,overflow,2147483648\n5,empty,\n"
    let duplicate = "122\n3\ntarget\nID,Name,DistributionNo,DistributionNo\n6,duplicate,4,7\n"
    let library = try SourceModLibrary(packages: [catalogTestPackage(directory, csvs: [overridden, duplicate])])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    #expect(catalog.entries.map(\.distribution) == [9, -5, -1, -1, -1, 7])
    #expect(catalog.entries.map { $0.info("DistributionNo") } == ["9", "-5", "not-int", "2147483648", "", "7"])
}

@Test func sourceModCatalogResolvesOriginalGUIDCategorySlotPropertyAndFirstDuplicate() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let duplicates = "122\n0\ntarget\nID,Name\n7,first\n7,second\n"
    let laterCatalog = "122\n0\ntarget\nID,Name\n7,later catalog\n"
    let otherGUID = "122\n0\ntarget\nID,Name\n7,other GUID\n"
    let first = try catalogTestPackage(directory.appendingPathComponent("a"), csvs: [duplicates, laterCatalog])
    let second = try catalogTestPackage(directory.appendingPathComponent("b"), guid: "other.mod", csvs: [otherGUID])
    let library = try SourceModLibrary(packages: [first, second])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    #expect(catalog.resolve(modGUID: " fixture.mod \n", category: 122, sourceSlot: 7, property: "Access.id")?.name == "first")
    #expect(catalog.resolve(modGUID: "other.mod", category: 122, sourceSlot: 7)?.name == "other GUID")
    #expect(catalog.resolve(modGUID: "Fixture.mod", category: 122, sourceSlot: 7) == nil)
    #expect(catalog.resolve(modGUID: "fixture.mod", category: 123, sourceSlot: 7) == nil)
    #expect(catalog.resolve(modGUID: "fixture.mod", category: 122, sourceSlot: 8) == nil)
    #expect(catalog.resolve(modGUID: "fixture.mod", category: 122, sourceSlot: 7, property: "access.id") == nil)
    #expect(catalog.resolve(modGUID: "fixture.mod", category: 122, sourceSlot: 100_000_001) == nil)
    #expect(catalog.diagnostics.filter { $0.code == "duplicate_source_slot" }.count == 2)
    let dependencies = try catalog.dependencies(library: library).filter { $0.entry.modGUID == "fixture.mod" }
    #expect(dependencies.count == 3)
    #expect(Set(dependencies.map { $0.sourcePath + ":" + String($0.sourceRow) }).count == 3)
}

@Test func sourceModCatalogReferenceFallbackAndDisabledValuesUseExactSourceStrings() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let cases: [(String?, String, String, String, String?)] = [
        (nil, "tex", "chara/base.unity3d", "", "chara/base.unity3d"),
        ("0", "tex", "chara/base.unity3d", "", "chara/base.unity3d"),
        ("", "tex", "chara/base.unity3d", "", ""),
        (" 0", "tex", "chara/base.unity3d", "", " 0"),
        ("chara/alt.unity3d", "tex", "chara/base.unity3d", "custom", "chara/alt.unity3d"),
        ("0", "tex", "0", "", nil),
        ("chara/alt.unity3d", "0", "chara/base.unity3d", "", nil),
        ("chara/alt.unity3d", " 0", "chara/base.unity3d", "", "chara/alt.unity3d"),
        ("chara/alt.unity3d", "", "chara/base.unity3d", "", "chara/alt.unity3d")]
    for (index, row) in cases.enumerated() {
        var columns = ["ID", "Name", "MainAB", "MainTex", "MainManifest"]
        var values = [String(index), "fixture", row.2, row.1, row.3]
        if let explicitBundle = row.0 { columns.append("MainTexAB"); values.append(explicitBundle) }
        let csv = "105\n0\ntarget\n" + columns.joined(separator: ",") + "\n" + values.joined(separator: ",") + "\n"
        let library = try SourceModLibrary(packages: [catalogTestPackage(directory.appendingPathComponent(String(index)), csvs: [csv])])
        let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
        let entry = try #require(catalog.entries.first)
        #expect(entry.references.count == (row.4 == nil ? 0 : 1))
        if let bundle = row.4 {
            let reference = try #require(entry.references.first)
            #expect(reference.bundlePath == bundle && reference.assetName == row.1)
            #expect(reference.manifest == (row.3.isEmpty ? "abdata" : row.3))
        }
    }
}

@Test func sourceModCatalogDependenciesDistinguishConvertedSourceOnlyUnknownAndWrongType() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let textures = "408\n0\ntarget\nID,Name,MainTexAB,MainTex,MainManifest\n1,converted,chara/textures.unity3d,paint,\n2,source,chara/source.unity3d,original,\n3,unknown,chara/missing.unity3d,missing,\n4,wrong type,chara/source.unity3d,material,\n5,wrong manifest,chara/source.unity3d,original,other\n6,wrong case,chara/source.unity3d,Original,\n"
    let prefab = "122\n0\ntarget\nID,Name,MainAB,MainData,MainManifest\n7,texture as prefab,chara/textures.unity3d,paint,\n"
    let package = try catalogTestPackage(directory.appendingPathComponent("catalog"), csvs: [textures, prefab])
    let provider = try catalogTestPackage(directory.appendingPathComponent("provider"), guid: "provider.mod", csvs: [], texture: true,
        textureBundlePath: "other/chara/textures.unity3d")
    let library = try SourceModLibrary(packages: [package, provider])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    let source: [SourceModCatalog.SourceAsset] = [
        .init(bundlePath: "chara/source.unity3d", assetName: "original", type: "Sprite"),
        .init(bundlePath: "chara/source.unity3d", assetName: "original", type: "Texture2D"),
        .init(bundlePath: "chara/source.unity3d", assetName: "material", type: "Material")]
    let dependencies = try catalog.dependencies(library: library, sourceAssets: source)
    #expect(dependencies.map(\.status) == ["convertedTexture", "sourceOnly", "unresolved", "wrongAssetType", "unresolved", "unresolved", "wrongAssetType"])
    #expect(dependencies[0].providerGUID == "provider.mod" && dependencies[6].providerGUID == "provider.mod")
    #expect(dependencies[1].providerGUID == nil && dependencies[3].providerGUID == nil)
}

@Test func sourceModCatalogReportsLegacySourceBundleAliasAmbiguityWithoutGuessingInventoryFallback() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let csv = "408\n0\ntarget\nID,Name,MainTexAB,MainTex,MainManifest\n1,paint,chara/textures.unity3d,paint,\n"
    let catalogPackage = try catalogTestPackage(directory.appendingPathComponent("catalog"), csvs: [csv])
    let provider = try catalogTestPackage(directory.appendingPathComponent("provider"), guid: "ambiguous.provider", csvs: [], texture: true)
    let manifestURL = provider.directory.appendingPathComponent("manifest.json")
    var document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    var resources = try #require(document["resources"] as? [[String: Any]])
    var alias = resources[0]; alias["id"] = "second-paint"; alias["bundlePath"] = "other/chara/textures.unity3d"
    resources.append(alias); document["resources"] = resources
    try JSONSerialization.data(withJSONObject: document).write(to: manifestURL)
    let library = try SourceModLibrary(packages: [catalogPackage, SourceModPackage.load(url: manifestURL)])
    let catalog = try SourceModCatalog(library: library, contract: catalogTestContract())
    let source = [SourceModCatalog.SourceAsset(bundlePath: "chara/textures.unity3d", assetName: "paint", type: "Texture2D")]
    let dependencies = try catalog.dependencies(library: library, sourceAssets: source)
    #expect(dependencies.map(\.status) == ["ambiguousSourceBundle"])
    #expect(dependencies.first?.providerGUID == nil)
}

private struct CatalogSourceOracle: Decodable {
    struct Resolver: Decodable { let GUID: String, Slot: Int, LocalSlot: Int, Property: String, CategoryNo: Int, rowOrdinal: Int }
    struct Row: Decodable { let ordinal: Int, sourceSlot: Int, runtimeLocalSlot: Int, fields: [String: String] }
    struct Generated: Decodable { let rows: [Row], resolveInfos: [Resolver] }
    struct Parsed: Decodable { let categoryNo: Int, distributionNo: Int, filePath: String }
    struct Dependency: Decodable {
        let guid: String, categoryNo: Int, sourceSlot: Int, role: String
        let sourceBundleKey: String, canonicalArchivePath: String, assetName: String, manifest: String
    }
    struct Catalog: Decodable { let sourcePath: String, sha256: String, parsed: Parsed, generated: Generated, dependencies: [Dependency] }
    struct Lookup: Decodable {
        struct Query: Decodable { let slot: Int?, local_slot: Int?, category: Int, guid: String?, property_name: String? }
        let query: Query, expected: Resolver?
    }
    struct Fixture: Decodable { let name: String, csvUTF8: String?, generated: Generated?, lookups: [Lookup]? }
    let catalogs: [Catalog], fixtures: [Fixture]
}

private func compareCatalogOracle(_ catalog: SourceModCatalog, generated: CatalogSourceOracle.Generated,
                                  guid: String, knownKeys: Set<String>) throws {
    let entries = catalog.entries.filter { $0.key.modGUID == guid }
    #expect(entries.count == generated.rows.count)
    for (native, source) in zip(entries, generated.rows) {
        #expect(native.key.sourceSlot == source.sourceSlot && native.sourceRow == source.ordinal)
        for (key, value) in source.fields where knownKeys.contains(key) && key != "ID" {
            #expect(native.info(key) == value, "source row \(source.ordinal), field \(key)")
        }
        // The source rewrites ID to a load-order counter; native saves deliberately retain original slots.
        #expect(native.info("ID") == String(source.sourceSlot))
        #expect(native.info("ID") != String(source.runtimeLocalSlot))
    }
    for info in generated.resolveInfos {
        let result = catalog.resolve(modGUID: info.GUID, category: info.CategoryNo, sourceSlot: info.Slot, property: info.Property)
        let expectedFirst = try #require(generated.resolveInfos.first { $0.GUID == info.GUID && $0.CategoryNo == info.CategoryNo && $0.Slot == info.Slot && $0.Property == info.Property })
        #expect(result?.sourceRow == expectedFirst.rowOrdinal)
        #expect(catalog.resolve(modGUID: info.GUID, category: info.CategoryNo, sourceSlot: info.LocalSlot) == nil)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IKKOKU_MOD_LIBRARY"] != nil && ProcessInfo.processInfo.environment["IKKOKU_MOD_CATALOG_CONTRACT"] != nil))
func sourceModCatalogMatchesRecoveredRowsResolverOracleAndEightRealDependencies() throws {
    let libraryPath = try #require(ProcessInfo.processInfo.environment["IKKOKU_MOD_LIBRARY"])
    let contractPath = try #require(ProcessInfo.processInfo.environment["IKKOKU_MOD_CATALOG_CONTRACT"])
    let data = try Data(contentsOf: URL(fileURLWithPath: contractPath))
    let contract = try SourceModCatalogContract.decode(data), oracle = try JSONDecoder().decode(CatalogSourceOracle.self, from: data)
    let profile = try SourceModProfile.load(libraryURL: URL(fileURLWithPath: libraryPath))
    let catalog = try SourceModCatalog(library: profile.library, contract: contract)
    let expected = try #require(oracle.catalogs.first)
    let package = try #require(profile.library.packages.first { $0.source.guid == "enk.acc.bald" })
    let raw = try #require(package.catalogs.first { $0.sourcePath == expected.sourcePath })
    #expect(catalogTestHash(try package.catalogData(raw)) == expected.sha256)
    try compareCatalogOracle(catalog, generated: expected.generated, guid: package.source.guid, knownKeys: Set(contract.keyTypes))
    #expect(catalog.entries.count == 4)
    for entry in catalog.entries {
        #expect(entry.key.category == expected.parsed.categoryNo && entry.distribution == expected.parsed.distributionNo)
        #expect(entry.sourceFilePath == expected.parsed.filePath)
    }
    let dependencies = try catalog.dependencies(library: profile.library, sourceAssets: contract.sourceAssets ?? [])
    #expect(dependencies.count == 8)
    #expect(dependencies.filter { $0.status == "sourceOnly" }.count == 2)
    #expect(dependencies.filter { $0.status == "unresolved" }.count == 6)
    for source in expected.dependencies {
        let role = source.role == "thumbnail" ? "accessoryThumbnail" : source.role
        let native = try #require(dependencies.first { $0.entry.sourceSlot == source.sourceSlot && $0.reference.role == role })
        #expect(native.entry.modGUID == source.guid && native.entry.category == source.categoryNo)
        #expect(native.reference.bundlePath == source.sourceBundleKey)
        #expect(native.reference.assetName == source.assetName && native.reference.manifest == source.manifest)
        #expect(native.status == (source.sourceSlot == 1080 ? "sourceOnly" : "unresolved"))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["IKKOKU_MOD_CATALOG_CONTRACT"] != nil))
func sourceModCatalogMatchesIndependentRecoveredCSVAndResolverFixtures() throws {
    let directory = try catalogTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let path = try #require(ProcessInfo.processInfo.environment["IKKOKU_MOD_CATALOG_CONTRACT"])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let contract = try SourceModCatalogContract.decode(data), oracle = try JSONDecoder().decode(CatalogSourceOracle.self, from: data)
    var fixturesCompared = 0, lookupsCompared = 0
    for fixture in oracle.fixtures {
        guard let csv = fixture.csvUTF8, let generated = fixture.generated else { continue }
        let package = try catalogTestPackage(directory.appendingPathComponent(fixture.name), csvs: [csv])
        let library = try SourceModLibrary(packages: [package])
        let catalog = try SourceModCatalog(library: library, contract: contract)
        try compareCatalogOracle(catalog, generated: generated, guid: "fixture.mod", knownKeys: Set(contract.keyTypes))
        fixturesCompared += 1
        for lookup in fixture.lookups ?? [] {
            if let runtimeSlot = lookup.query.local_slot {
                #expect(catalog.resolve(modGUID: lookup.expected?.GUID ?? "fixture.mod", category: lookup.query.category, sourceSlot: runtimeSlot) == nil)
            } else {
                let guid = try #require(lookup.query.guid), slot = try #require(lookup.query.slot)
                let native = catalog.resolve(modGUID: guid, category: lookup.query.category, sourceSlot: slot, property: lookup.query.property_name)
                #expect(native?.sourceRow == lookup.expected?.rowOrdinal)
                #expect(native?.key.sourceSlot == lookup.expected?.Slot)
            }
            lookupsCompared += 1
        }
    }
    #expect(fixturesCompared == 3 && lookupsCompared == 5)
}
