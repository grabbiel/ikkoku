import Foundation
import Assets

/// Compares a native `SourceShaderBindingSet` with what the translated probe
/// binds from an original-player capture (`frame.json`), input by input.
///
/// The capture side is the probe's *effective* binding, reproduced from
/// `TranslatedSourceShaderProbe.encodeTranslatedShader`: a recorded material
/// value, else the program default; `<texture>_ST` from the recorded texture,
/// else `[1, 1, 0, 0]`; a recorded texture, else the Unity default texture;
/// globals from the capture's global table. Each finding names which of
/// those the capture side came from. The capture is only read here, never by
/// the derivation that produced the binding set.
public struct SourceShaderBindingComparison: Codable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case exact, withinTolerance, differs, missingNatively, extra
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case renderer, shader, queue, keywords, passState, vector, textureTransform, texture, sampler
    }

    public struct Finding: Codable, Sendable, Equatable {
        public var mesh: String?
        public var materialSlot: Int?
        public var material: String?
        /// Program family (`main_hair`…), or `global` for global inputs.
        public var family: String
        public var category: Category
        public var input: String
        public var status: Status
        public var native: JSONValue?
        public var capture: JSONValue?
        public var nativeSource: String?
        public var captureSource: String?
        /// Why the input is not exact: the gap's root cause, used for grouping.
        public var cause: String?
        public var note: String?
    }

    public struct Tally: Codable, Sendable, Equatable {
        public var exact = 0, withinTolerance = 0, differs = 0, missingNatively = 0, extra = 0
        public var total: Int { exact + withinTolerance + differs + missingNatively + extra }
        public init() {}
        mutating func add(_ status: Status) {
            switch status {
            case .exact: exact += 1
            case .withinTolerance: withinTolerance += 1
            case .differs: differs += 1
            case .missingNatively: missingNatively += 1
            case .extra: extra += 1
            }
        }
        enum CodingKeys: String, CodingKey { case exact, withinTolerance, differs, missingNatively, extra, total }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exact = try c.decode(Int.self, forKey: .exact); withinTolerance = try c.decode(Int.self, forKey: .withinTolerance)
            differs = try c.decode(Int.self, forKey: .differs); missingNatively = try c.decode(Int.self, forKey: .missingNatively)
            extra = try c.decode(Int.self, forKey: .extra)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(exact, forKey: .exact); try c.encode(withinTolerance, forKey: .withinTolerance)
            try c.encode(differs, forKey: .differs); try c.encode(missingNatively, forKey: .missingNatively)
            try c.encode(extra, forKey: .extra); try c.encode(total, forKey: .total)
        }
    }

    public struct Gap: Codable, Sendable, Equatable {
        public var cause: String
        public var count: Int
        public var statuses: [String: Int]
        public var families: [String]
        public var inputs: [String]
    }

    public var schemaVersion = 1
    public var scope: String
    public var tolerances: [String: String]
    public var provenance: [String: String]
    public var findings: [Finding]
    /// Family → category → tally.
    public var byFamily: [String: [String: Tally]]
    public var familyTotals: [String: Tally]
    public var byCategory: [String: Tally]
    public var overall: Tally
    /// Contract uses (per drawn material and translated program input) by binding source.
    public var contractUses: [String: Int]
    public var gaps: [Gap]
    public var diagnostics: [String]

    /// Absolute per-lane tolerance for `withinTolerance` vectors.
    public static let vectorTolerance: Float = 1e-5

    public enum ComparisonError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): message } }
    }

    // MARK: - Comparison

    public static func compare(bindings: SourceShaderBindingSet, frame data: Data, catalog: SourceShaderProgramCatalog,
                               provenance: [String: String] = [:]) throws -> Self {
        typealias Row = [String: Any]
        guard let frame = try JSONSerialization.jsonObject(with: data) as? Row,
              let meshes = frame["meshes"] as? [Row], let textureRows = frame["textures"] as? [Row] else {
            throw ComparisonError.invalid("Capture frame lacks meshes or textures")
        }
        let globals = frame["globals"] as? Row ?? [:]
        var texturesByFile: [String: Row] = [:]
        for row in textureRows { if let file = row["file"] as? String { texturesByFile[file] = row } }
        var findings: [Finding] = [], diagnostics = bindings.diagnostics.map { "derivation: " + $0 }
        var contractUses: [String: Int] = [:]
        var matched = Set<Int>(), usedGlobals: [String: SourceShaderProgramContract.Input] = [:], globalOrder: [String] = []

        for (meshIndex, mesh) in meshes.enumerated() {
            guard let name = mesh["name"] as? String, let materials = mesh["materials"] as? [Row] else {
                throw ComparisonError.invalid("Capture mesh \(meshIndex) lacks a name or materials")
            }
            let submeshes = (mesh["submeshes"] as? NSNumber)?.intValue ?? materials.count
            for (slot, captured) in materials.enumerated() {
                guard let shader = captured["shader"] as? String, let materialName = captured["name"] as? String else {
                    throw ComparisonError.invalid("Capture material \(name)[\(slot)] lacks a shader or name")
                }
                let family = shader.split(separator: "/").last.map(String.init) ?? shader
                let drawnByProbe = slot < submeshes
                if family == "shadowcast" {
                    diagnostics.append("\(name)[\(slot)] \(shader) is a shadow caster; the probe skips it and it is not compared.")
                    continue
                }
                let candidates = bindings.renderers.indices.filter { !matched.contains($0) && bindings.renderers[$0].mesh == name && bindings.renderers[$0].materialSlot == slot }
                guard let index = candidates.first(where: { bindings.renderers[$0].visible }) ?? candidates.first else {
                    findings.append(Finding(mesh: name, materialSlot: slot, material: materialName, family: family, category: .renderer,
                        input: "renderer", status: .missingNatively, native: nil, capture: .string("drawn"), nativeSource: nil,
                        captureSource: "capture mesh row", cause: "no native renderer/material slot for this capture row", note: nil))
                    continue
                }
                matched.insert(index)
                let renderer = bindings.renderers[index]
                let probeNote = drawnByProbe ? nil : "material slot \(slot) is beyond the mesh's \(submeshes) submesh(es): Unity draws it over the last submesh, the probe's materials.prefix(submeshes) does not"
                if !renderer.visible {
                    findings.append(Finding(mesh: name, materialSlot: slot, material: materialName, family: family, category: .renderer,
                        input: "renderer", status: .differs, native: .string("hidden"), capture: .string("drawn"),
                        nativeSource: renderer.visibility, captureSource: "capture mesh row", cause: "native visibility rule hides a captured renderer", note: probeNote))
                    continue
                }
                findings.append(Finding(mesh: name, materialSlot: slot, material: materialName, family: family, category: .renderer,
                    input: "renderer", status: drawnByProbe ? .exact : .extra, native: .string("drawn"),
                    capture: .string(drawnByProbe ? "drawn" : "recorded, not drawn by probe"), nativeSource: renderer.visibility,
                    captureSource: "capture mesh row", cause: drawnByProbe ? nil : "probe draws only materials.prefix(submeshes)", note: probeNote))
                findings += compareMaterial(renderer: renderer, captured: captured, family: family, shader: shader, catalog: catalog,
                                            texturesByFile: texturesByFile, uses: &contractUses, usedGlobals: &usedGlobals, globalOrder: &globalOrder,
                                            drawnByProbe: drawnByProbe)
            }
        }
        for (index, renderer) in bindings.renderers.enumerated() where !matched.contains(index) {
            let family = renderer.material.shader?.split(separator: "/").last.map(String.init) ?? "unknown"
            if renderer.visible {
                findings.append(Finding(mesh: renderer.mesh, materialSlot: renderer.materialSlot, material: renderer.material.name, family: family,
                    category: .renderer, input: "renderer", status: .extra, native: .string("drawn"), capture: nil,
                    nativeSource: renderer.visibility, captureSource: "no capture mesh row", cause: "native renderer has no capture row", note: nil))
            } else {
                findings.append(Finding(mesh: renderer.mesh, materialSlot: renderer.materialSlot, material: renderer.material.name, family: family,
                    category: .renderer, input: "renderer", status: .exact, native: .string("hidden"), capture: .string("absent"),
                    nativeSource: renderer.visibility, captureSource: "no capture mesh row", cause: nil, note: nil))
            }
        }
        for name in globalOrder {
            guard let input = usedGlobals[name] else { continue }
            findings += compareGlobal(input, bindings: bindings, globals: globals, texturesByFile: texturesByFile)
        }
        return summarize(findings: findings, diagnostics: diagnostics, contractUses: contractUses,
                         provenance: bindings.provenance.merging(provenance) { _, new in new })
    }

    private static func compareMaterial(renderer: SourceShaderBindingSet.Renderer, captured: [String: Any], family: String, shader: String,
                                        catalog: SourceShaderProgramCatalog, texturesByFile: [String: [String: Any]],
                                        uses: inout [String: Int], usedGlobals: inout [String: SourceShaderProgramContract.Input],
                                        globalOrder: inout [String], drawnByProbe: Bool) -> [Finding] {
        let material = renderer.material
        let properties = captured["properties"] as? [String: Any] ?? [:]
        var result: [Finding] = []
        func finding(_ category: Category, _ input: String, _ status: Status, native: JSONValue?, capture: JSONValue?,
                     nativeSource: String?, captureSource: String?, cause: String? = nil, note: String? = nil) {
            result.append(Finding(mesh: renderer.mesh, materialSlot: renderer.materialSlot, material: captured["name"] as? String,
                family: family, category: category, input: input, status: status, native: native, capture: capture,
                nativeSource: nativeSource, captureSource: captureSource, cause: cause, note: note))
        }
        // Shader identity and translated pass selection.
        let passes = catalog.passes(for: shader)
        if let nativeShader = material.shader {
            let same = nativeShader == shader
            finding(.shader, "shader", same ? .exact : .differs, native: .string(nativeShader), capture: .string(shader),
                    nativeSource: "converted material evidence", captureSource: "capture material",
                    cause: same ? nil : "native material uses another shader",
                    note: passes.isEmpty ? "no translated program for this shader" : "translated passes: " + passes.map(\.pass).joined(separator: ", "))
        } else {
            finding(.shader, "shader", .missingNatively, native: nil, capture: .string(shader), nativeSource: nil, captureSource: "capture material",
                    cause: material.unresolved ?? "native shader identity not derived")
        }
        if let queue = (captured["queue"] as? NSNumber)?.intValue {
            if let nativeQueue = material.queue {
                finding(.queue, "renderQueue", nativeQueue == queue ? .exact : .differs, native: .number(Double(nativeQueue)), capture: .number(Double(queue)),
                        nativeSource: material.queueSource, captureSource: "capture material",
                        cause: nativeQueue == queue ? nil : "render queue derivation differs")
            } else {
                finding(.queue, "renderQueue", .missingNatively, native: nil, capture: .number(Double(queue)), nativeSource: material.queueSource,
                        captureSource: "capture material", cause: material.unresolved ?? "render queue not derived")
            }
        }
        let capturedKeywords = (captured["keywords"] as? [String] ?? []).sorted()
        if let keywords = material.keywords {
            let same = keywords.sorted() == capturedKeywords
            finding(.keywords, "shaderKeywords", same ? .exact : .differs, native: .array(keywords.sorted().map(JSONValue.string)),
                    capture: .array(capturedKeywords.map(JSONValue.string)), nativeSource: material.keywordsSource, captureSource: "capture material",
                    cause: same ? nil : "shader keywords differ", note: "translated programs are compiled for one variant; keywords are not bound")
        } else {
            finding(.keywords, "shaderKeywords", .missingNatively, native: nil, capture: .array(capturedKeywords.map(JSONValue.string)),
                    nativeSource: material.keywordsSource, captureSource: "capture material",
                    cause: material.unresolved ?? "converted material evidence omits m_ShaderKeywords",
                    note: "translated programs are compiled for one variant; keywords are not bound")
        }
        // Pass state: the capture does not record it, so the probe's state is
        // the translated program descriptor's (itself from the shader asset).
        for program in passes {
            let expected = program.passState.mapValues { JSONValue.number(Double($0)) }
            guard let state = material.passStates?[program.pass] else {
                finding(.passState, program.pass, .missingNatively, native: nil, capture: .object(expected), nativeSource: nil,
                        captureSource: "program descriptor \(program.program) (capture records no pass state)",
                        cause: material.unresolved ?? "pass \(program.pass) absent from converted material evidence")
                continue
            }
            // Keys the converted evidence does not record (for example the
            // depth offset) are listed, not counted as differences.
            let shared = program.passState.keys.sorted().filter { state[$0] != nil }
            let absent = program.passState.keys.sorted().filter { state[$0] == nil }
            let differing = shared.filter { state[$0] != program.passState[$0] }
            finding(.passState, program.pass, shared.isEmpty ? .missingNatively : differing.isEmpty ? .exact : .differs,
                    native: .object(state.mapValues { JSONValue.number(Double($0)) }), capture: .object(expected),
                    nativeSource: "converted material evidence pass \(program.pass)",
                    captureSource: "program descriptor \(program.program) (capture records no pass state)",
                    cause: shared.isEmpty ? "converted evidence records no comparable pass state" : differing.isEmpty ? nil : "pass state differs: " + differing.joined(separator: ", "),
                    note: absent.isEmpty ? nil : "not in converted evidence: " + absent.joined(separator: ", "))
        }
        let declared = catalog.properties(for: shader)
        for input in catalog.inputs(for: shader) {
            uses[input.source.rawValue, default: 0] += drawnByProbe ? 1 : 0
            switch input.source {
            case .builtin:
                continue
            case .globalVector, .globalTexture:
                if usedGlobals.updateValue(input, forKey: input.name) == nil { globalOrder.append(input.name) }
            case .materialVector:
                let capturedValue: [Float]?, captureSource: String
                if let number = properties[input.name] as? NSNumber { capturedValue = [number.floatValue]; captureSource = "capture material" }
                else if let list = properties[input.name] as? [NSNumber] { capturedValue = list.map(\.floatValue); captureSource = "capture material" }
                else if let property = declared[input.name] { capturedValue = property.defaultValue; captureSource = "program default (not recorded)" }
                else { capturedValue = nil; captureSource = "unavailable" }
                result.append(vectorFinding(input: input, native: material.vectors[input.name], capture: capturedValue, captureSource: captureSource,
                    category: .vector, renderer: renderer, family: family, materialName: captured["name"] as? String, bothUnbound: false))
            case .materialTextureTransform:
                let base = String(input.name.dropLast(3))
                let capturedTexture = properties[base] as? [String: Any]
                let capturedValue: [Float]?, captureSource: String
                if let capturedTexture, let scale = capturedTexture["scale"] as? [NSNumber], let offset = capturedTexture["offset"] as? [NSNumber] {
                    capturedValue = (scale + offset).map(\.floatValue); captureSource = "capture texture scale/offset"
                } else { capturedValue = [1, 1, 0, 0]; captureSource = "probe convention [1,1,0,0] (no texture recorded)" }
                let nativeTexture = material.textures[base]
                let vector: SourceShaderBindingSet.Vector?
                if let nativeTexture {
                    if let scale = nativeTexture.scale, let offset = nativeTexture.offset { vector = .init(scale + offset, source: nativeTexture.transformSource) }
                    else { vector = .init(unresolved: nativeTexture.transformUnresolved ?? "texture transform not derived") }
                } else { vector = nil }
                let nativeUnbound = nativeTexture.map { $0.identity == nil && $0.identityUnresolved == nil } ?? false
                result.append(vectorFinding(input: input, native: vector, capture: capturedValue, captureSource: captureSource,
                    category: .textureTransform, renderer: renderer, family: family, materialName: captured["name"] as? String,
                    bothUnbound: nativeUnbound && capturedTexture == nil))
            case .materialTexture:
                let capturedTexture = (properties[input.name] as? [String: Any]).flatMap { ($0["file"] as? String).flatMap { texturesByFile[$0] } }
                let fallback = declared[input.name]?.defaultTexture ?? "white"
                result += textureFindings(name: input.name, native: material.textures[input.name], capture: capturedTexture, fallback: fallback,
                                          renderer: renderer, family: family, materialName: captured["name"] as? String)
            }
        }
        return result
    }

    private static func vectorFinding(input: SourceShaderProgramContract.Input, native: SourceShaderBindingSet.Vector?, capture: [Float]?,
                                      captureSource: String, category: Category, renderer: SourceShaderBindingSet.Renderer?,
                                      family: String, materialName: String?, bothUnbound: Bool) -> Finding {
        var finding = Finding(mesh: renderer?.mesh, materialSlot: renderer?.materialSlot, material: materialName, family: family,
                              category: category, input: input.name, status: .missingNatively, native: nil,
                              capture: capture.map(json), nativeSource: native?.source, captureSource: captureSource, cause: nil, note: nil)
        let lanes = max(1, input.dimension)
        guard let native, let values = native.values else {
            finding.cause = native?.unresolved ?? renderer.flatMap { $0.material.unresolved } ?? "input not derived"
            return finding
        }
        finding.native = json(values)
        guard let capture, capture.count >= lanes, values.count >= lanes else {
            finding.status = .differs; finding.cause = "lane count differs"; return finding
        }
        let pairs = (0..<lanes).map { (values[$0], capture[$0]) }
        if pairs.allSatisfy({ sevenDigitEqual($0.0, $0.1) }) { finding.status = .exact; return finding }
        if pairs.allSatisfy({ abs($0.0 - $0.1) <= vectorTolerance }) {
            finding.status = .withinTolerance; finding.note = "max |delta| \(pairs.map { abs($0.0 - $0.1) }.max() ?? 0) over \(lanes) lane(s)"
            return finding
        }
        if bothUnbound {
            finding.status = .withinTolerance
            finding.note = "no texture is bound on either side; the probe's constant Unity default texture makes this transform irrelevant"
            return finding
        }
        finding.status = .differs
        finding.cause = differenceCause(input: input.name, nativeSource: native.source, captureSource: captureSource)
        return finding
    }

    private static func textureFindings(name: String, native: SourceShaderBindingSet.Texture?, capture: [String: Any]?, fallback: String,
                                        renderer: SourceShaderBindingSet.Renderer?, family: String, materialName: String?) -> [Finding] {
        var result: [Finding] = []
        let captureJSON: JSONValue = capture.map(textureJSON) ?? .string("Unity default '\(fallback)' (no texture recorded)")
        var base = Finding(mesh: renderer?.mesh, materialSlot: renderer?.materialSlot, material: materialName, family: family, category: .texture,
                           input: name, status: .missingNatively, native: nil, capture: captureJSON, nativeSource: native?.identitySource,
                           captureSource: capture == nil ? "Unity default texture" : "capture texture", cause: nil, note: nil)
        guard let native else {
            base.cause = renderer.flatMap { $0.material.unresolved } ?? "texture not derived"; return [base]
        }
        if let reason = native.identityUnresolved { base.cause = reason; return [base] }
        guard let identity = native.identity else {
            base.native = .string("none (Unity default '\(fallback)')")
            if capture == nil { base.status = .exact } else { base.status = .differs; base.cause = "native binds no texture where the capture has one" }
            return [base]
        }
        base.native = identityJSON(identity)
        guard let capture else {
            base.status = .extra; base.cause = "native binds a texture where the capture records none"; return [base]
        }
        let captureType = capture["textureType"] as? String ?? ""
        var compared: [String] = [], differing: [String] = []
        func check(_ field: String, _ nativeValue: String?, _ captureValue: String?) {
            guard let nativeValue, let captureValue else { return }
            compared.append(field)
            if nativeValue != captureValue { differing.append("\(field) \(nativeValue) vs \(captureValue)") }
        }
        check("type", identity.kind == .asset ? "Texture2D" : "RenderTexture", captureType)
        if identity.kind == .asset { check("name", identity.name, capture["name"] as? String) }
        check("width", identity.width.map(String.init), (capture["width"] as? NSNumber).map { String($0.intValue) })
        check("height", identity.height.map(String.init), (capture["height"] as? NSNumber).map { String($0.intValue) })
        let source = capture["authoredMipSource"] as? [String: Any]
        check("pathID", identity.pathID, (source?["pathID"] as? NSNumber).map { String($0.int64Value) })
        // `original_texture_mips.py` deduplicates byte-identical textures across
        // bundles and keeps an arbitrary bundle, so the capture's bundle hash
        // is attribution only: a mismatch is reported, not counted.
        var attribution: String?
        if let nativeBundle = identity.bundleSHA256, let captureBundle = source?["bundleSHA256"] as? String, nativeBundle != captureBundle {
            attribution = "bundle attribution differs (capture authoredMipSource keeps one of several identical copies): native \(nativeBundle.prefix(12)) vs capture \(captureBundle.prefix(12))"
        }
        if !differing.isEmpty {
            base.status = .differs; base.cause = "texture identity differs: " + differing.joined(separator: "; ")
        } else if identity.kind == .runtimeComposite {
            base.status = .withinTolerance
            base.note = "runtime composite matched on " + compared.joined(separator: ", ") + "; pixel content is not compared here"
        } else {
            base.status = .exact; base.note = (["matched on " + compared.joined(separator: ", ")] + [attribution].compactMap { $0 }).joined(separator: "; ")
        }
        result.append(base)
        // Sampler state the probe derives from the capture's texture metadata.
        let captureSampler: [String: JSONValue] = [
            "filter": .string(capture["filter"] as? String ?? "?"), "wrap": .string(capture["wrap"] as? String ?? "?"),
            "aniso": .number((capture["aniso"] as? NSNumber)?.doubleValue ?? -1), "mipLevels": .number((capture["mipLevels"] as? NSNumber)?.doubleValue ?? -1)]
        var nativeSampler: [String: JSONValue] = [:]
        if let value = identity.filter { nativeSampler["filter"] = .string(value) }
        if let value = identity.wrap { nativeSampler["wrap"] = .string(value) }
        if let value = identity.aniso { nativeSampler["aniso"] = .number(Double(value)) }
        if let value = identity.mipLevels { nativeSampler["mipLevels"] = .number(Double(value)) }
        let differs = nativeSampler.keys.sorted().filter { nativeSampler[$0] != captureSampler[$0] }
        let unknown = captureSampler.keys.sorted().filter { nativeSampler[$0] == nil }
        var sampler = base
        sampler.category = .sampler; sampler.native = nativeSampler.isEmpty ? nil : .object(nativeSampler); sampler.capture = .object(captureSampler)
        sampler.captureSource = "capture texture metadata"; sampler.note = nil; sampler.cause = nil
        if !differs.isEmpty { sampler.status = .differs; sampler.cause = "sampler/mip state differs: " + differs.joined(separator: ", ") }
        else if !unknown.isEmpty {
            sampler.status = .missingNatively
            sampler.cause = "sampler state (" + unknown.joined(separator: ", ") + ") not in converted texture evidence"
            if !nativeSampler.isEmpty { sampler.note = "matched: " + nativeSampler.keys.sorted().joined(separator: ", ") }
        } else { sampler.status = .exact }
        result.append(sampler)
        return result
    }

    private static func compareGlobal(_ input: SourceShaderProgramContract.Input, bindings: SourceShaderBindingSet,
                                      globals: [String: Any], texturesByFile: [String: [String: Any]]) -> [Finding] {
        if input.isTexture {
            // Identity and, when a texture is bound, its sampler state.
            let capture = (globals[input.name] as? String).flatMap { texturesByFile[$0] }
            return textureFindings(name: input.name, native: bindings.globalTextures[input.name], capture: capture, fallback: "none",
                                   renderer: nil, family: "global", materialName: nil)
        }
        let capture: [Float]?, captureSource: String
        if let number = globals[input.name] as? NSNumber { capture = [number.floatValue]; captureSource = "capture globals" }
        else if let list = globals[input.name] as? [NSNumber] { capture = list.map(\.floatValue); captureSource = "capture globals" }
        else if input.name.hasSuffix("_ST") { capture = [1, 1, 0, 0]; captureSource = "probe convention [1,1,0,0] (global texture transform)" }
        else { capture = nil; captureSource = "absent from capture globals" }
        return [vectorFinding(input: input, native: bindings.globalVectors[input.name], capture: capture, captureSource: captureSource,
                              category: .vector, renderer: nil, family: "global", materialName: nil, bothUnbound: false)]
    }

    // MARK: - Summary

    private static func summarize(findings: [Finding], diagnostics: [String], contractUses: [String: Int], provenance: [String: String]) -> Self {
        var byFamily: [String: [String: Tally]] = [:], familyTotals: [String: Tally] = [:], byCategory: [String: Tally] = [:], overall = Tally()
        var gapIndex: [String: Gap] = [:], gapOrder: [String] = []
        for finding in findings {
            byFamily[finding.family, default: [:]][finding.category.rawValue, default: Tally()].add(finding.status)
            familyTotals[finding.family, default: Tally()].add(finding.status)
            byCategory[finding.category.rawValue, default: Tally()].add(finding.status)
            overall.add(finding.status)
            guard finding.status != .exact, finding.status != .withinTolerance else { continue }
            let cause = finding.cause ?? "unspecified"
            if gapIndex[cause] == nil { gapOrder.append(cause); gapIndex[cause] = Gap(cause: cause, count: 0, statuses: [:], families: [], inputs: []) }
            gapIndex[cause]!.count += 1
            gapIndex[cause]!.statuses[finding.status.rawValue, default: 0] += 1
            if !gapIndex[cause]!.families.contains(finding.family) { gapIndex[cause]!.families.append(finding.family) }
            let label = (finding.mesh.map { $0 + (finding.materialSlot.map { "[\($0)]" } ?? "") + "." } ?? "global.") + finding.input
            if gapIndex[cause]!.inputs.count < 24 { gapIndex[cause]!.inputs.append(label) }
        }
        let gaps = gapOrder.compactMap { gapIndex[$0] }.sorted { ($0.count, $1.cause) > ($1.count, $0.cause) }
        return Self(scope: "Native source-derived shader bindings versus the translated probe's capture-bound inputs for one frozen fixture. "
                        + "Builtin camera/light/screen uniforms and matrices are computed by the probe and not compared.",
                    tolerances: [
                        "exact": "every compared lane equals the capture after rounding the native float32 to 7 significant digits "
                            + "(the capture's .NET Framework float text form), or equal identity fields for textures",
                        "withinTolerance": "every compared lane within \(vectorTolerance) absolute: below 1/100 of an 8-bit output step "
                            + "(1/255) and above float32 rounding of one or two operations on unit-range values; also runtime "
                            + "composites matched on type/size (content not compared) and transforms of textures bound on neither side",
                        "lanes": "only the lanes the translated program reads (m_Dim) are compared",
                    ],
                    provenance: provenance, findings: findings, byFamily: byFamily, familyTotals: familyTotals, byCategory: byCategory,
                    overall: overall, contractUses: contractUses, gaps: gaps, diagnostics: diagnostics)
    }

    // MARK: - Values

    /// True when `native` prints as `capture` at 7 significant digits, the
    /// precision of `Convert.ToString(float)` in the capture plugin.
    public static func sevenDigitEqual(_ native: Float, _ capture: Float) -> Bool {
        if native == capture { return true }
        guard native.isFinite, capture.isFinite else { return false }
        let printed = Double(String(format: "%.7g", Double(native))) ?? .nan
        return Float(printed) == capture || printed == Double(String(format: "%.7g", Double(capture)))
    }

    static func json(_ values: [Float]) -> JSONValue {
        .array(values.map { JSONValue.number(Double(String(describing: $0)) ?? Double($0)) })
    }

    private static func identityJSON(_ identity: SourceShaderBindingSet.TextureIdentity) -> JSONValue {
        var row: [String: JSONValue] = ["kind": .string(identity.kind.rawValue)]
        if let value = identity.name { row["name"] = .string(value) }
        if let value = identity.bundle { row["bundle"] = .string(value) }
        if let value = identity.pathID { row["pathID"] = .string(value) }
        if let value = identity.width { row["width"] = .number(Double(value)) }
        if let value = identity.height { row["height"] = .number(Double(value)) }
        if let value = identity.creator { row["creator"] = .string(value) }
        return .object(row)
    }

    private static func textureJSON(_ row: [String: Any]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for key in ["name", "textureType", "file"] { if let value = row[key] as? String { result[key] = .string(value) } }
        for key in ["width", "height"] { if let value = row[key] as? NSNumber { result[key] = .number(value.doubleValue) } }
        if let source = row["authoredMipSource"] as? [String: Any], let pathID = source["pathID"] as? NSNumber { result["pathID"] = .string(String(pathID.int64Value)) }
        return .object(result)
    }

    private static func differenceCause(input: String, nativeSource: String, captureSource: String) -> String {
        if captureSource.hasPrefix("probe convention") { return "probe convention differs from the native material value" }
        if nativeSource.hasPrefix("prefab") || nativeSource.hasPrefix("shader default") {
            return "runtime setter not modelled (native value is the \(nativeSource.hasPrefix("prefab") ? "prefab" : "shader default"))"
        }
        return "derived value differs (\(nativeSource))"
    }
}
