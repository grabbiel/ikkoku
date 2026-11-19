import Foundation
import Testing
import CryptoKit
import simd
import CoreMath
import Scene
import Character
import Studio

// The engine against the original player's capture of extended (Slider
// Unlocker) and vanilla shape rates (`Tools/reverse/original_slider_probe.py`).
// The tolerances, the pass rule and the method were registered in PR #379
// before any engine result: (a) drawn rates, (b) the Animator `height` input,
// (c) every source channel, (d) every destination bone. Each process compares
// the captures of its own `IKKOKU_SHAPE_RATE_RANGE` mode (unset/extended =
// `unlocked`, `vanilla` = `vanilla`). IKKOKU_SLIDER_ORACLE is the folder of
// `<mode>-<label>.json` captures; IKKOKU_SLIDER_ORACLE_CASES is the probe's
// case table (label, scene, scene SHA-256, object key, sex, modes).
private struct SliderCapture: Decodable {
    struct Rates: Decodable { let body: [Float], face: [Float], headId: Int, typeBone: Int, sex: Int }
    struct Animator: Decodable { let floats: [String: Float] }
    struct Source: Decodable { let id: Int, names: [String]?, pos: [Float], rot: [Float], scl: [Float] }
    struct Destination: Decodable { let id: Int, bone: String?, pos: [Float]?, quat: [Float]?, scl: [Float]? }
    struct Shape: Decodable { let sources: [Source], destinations: [Destination] }
    struct Shapes: Decodable { let body: Shape, face: Shape }
    struct Bone: Decodable { let path: String, pos: [Float], quat: [Float], scl: [Float] }
    struct BoneSet: Decodable { let root: String, transforms: [Bone] }
    struct Bones: Decodable { let body: BoneSet, head: BoneSet? }
    let stage: String, mode: String, label: String, key: Int, sex: Int
    let parsed: Rates
    let animator: Animator
    let shapes: Shapes
    let bones: Bones
}

private struct SliderOracleTally {
    var compared = 0, failures: [String] = []
    var maxRate: Double = 0, maxHeight: Double = 0
    var maxChannelPosition: Double = 0, maxChannelRotation: Double = 0, maxChannelScale: Double = 0
    var maxBonePosition: Double = 0, maxBoneAngle: Double = 0, maxBoneScale: Double = 0
    var counts: [String: Int] = [:]
    mutating func check(_ item: String, _ delta: Double, tolerance: Double, max: WritableKeyPath<Self, Double>) {
        compared += 1
        if delta.isFinite { self[keyPath: max] = Swift.max(self[keyPath: max], delta) }
        if !(delta <= tolerance) { failures.append("\(item): |Δ| \(delta) > \(tolerance)") }
    }
    var json: [String: Any] {
        ["compared": compared, "failureCount": failures.count, "failures": Array(failures.prefix(200)), "counts": counts,
         "max": ["rate": maxRate, "height": maxHeight, "channelPosition": maxChannelPosition,
                 "channelRotationDegrees": maxChannelRotation, "channelScale": maxChannelScale,
                 "bonePosition": maxBonePosition, "boneAngleDegrees": maxBoneAngle, "boneScale": maxBoneScale]]
    }
}

private func sliderVector(_ values: [Float], _ item: String) throws -> Float3 {
    guard values.count == 3 else { throw RigError.invalid("\(item) is not a 3-vector.") }
    return Float3(values[0], values[1], values[2])
}

/// The engine-basis local TRS of a captured Unity transform.
private func sliderLocal(pos: [Float], quat: [Float], scl: [Float], _ item: String) throws -> (Float3, simd_quatf, Float3) {
    guard quat.count == 4 else { throw RigError.invalid("\(item) quaternion is not 4 values.") }
    return (UnityCoordinates.position(try sliderVector(pos, item)),
            UnityCoordinates.rotation(simd_quatf(ix: quat[0], iy: quat[1], iz: quat[2], r: quat[3])),
            try sliderVector(scl, item))
}

/// Double-precision decomposition of an engine local matrix.
private func sliderComponents(_ m: float4x4) -> (position: SIMD3<Double>, rotation: simd_quatd, scale: SIMD3<Double>) {
    let c = (0..<3).map { SIMD3<Double>(Double(m[$0].x), Double(m[$0].y), Double(m[$0].z)) }
    let s = SIMD3<Double>(simd_length(c[0]), simd_length(c[1]), simd_length(c[2]))
    let basis = simd_double3x3(c[0] / s.x, c[1] / s.y, c[2] / s.z)
    return (SIMD3<Double>(Double(m[3].x), Double(m[3].y), Double(m[3].z)), simd_quatd(basis).normalized, s)
}

/// The angle between two rotations in degrees, stable near zero.
private func sliderAngleDegrees(_ a: simd_quatd, _ b: simd_quatd) -> Double {
    let relative = a.inverse * b
    return 2 * atan2(simd_length(relative.imag), abs(relative.real)) * 180 / .pi
}

/// |Δ| of two Euler components, modulo 360°.
private func sliderEulerDelta(_ a: Float, _ b: Float) -> Double {
    let d = abs((Double(a) - Double(b)).truncatingRemainder(dividingBy: 360))
    return min(d, 360 - d)
}

private func sliderFind(_ records: [KoikatsuObjectRecord], key: Int32) -> KoikatsuObjectRecord? {
    for record in records {
        if record.kind == .character, record.sourceKey == key { return record }
        let nested = record.children + (record.character?.accessoryChildren.keys.sorted()
            .flatMap { record.character?.accessoryChildren[$0] ?? [] } ?? [])
        if let found = sliderFind(nested, key: key) { return found }
    }
    return nil
}

/// The rest pose with every node seeded from the capture: by path under the
/// captured bone root, else by a name unique in both the capture and the rig.
private func sliderBasePose(rig: RigDefinition, capture: SliderCapture,
                            tally: inout SliderOracleTally) throws -> RigPose {
    var pose = rig.restPose
    var byPath: [String: SliderCapture.Bone] = [:], byName: [String: [SliderCapture.Bone]] = [:]
    var roots: [String] = []
    for set in [capture.bones.body] + (capture.bones.head.map { [$0] } ?? []) {
        roots.append(set.root)
        for bone in set.transforms {
            byPath["\(set.root)/\(bone.path)"] = bone
            byName[String(bone.path.split(separator: "/").last ?? ""), default: []].append(bone)
        }
    }
    var paths = [String?](repeating: nil, count: rig.nodes.count)
    for index in rig.nodes.indices {
        var parts: [String] = [], cursor: Int? = index
        while let current = cursor, !roots.contains(rig.nodes[current].name) {
            parts.insert(rig.nodes[current].name, at: 0); cursor = rig.nodes[current].parent
        }
        if let root = cursor { paths[index] = "\(rig.nodes[root].name)/" + parts.joined(separator: "/") }
    }
    var viaPath = 0, viaName = 0
    for index in rig.nodes.indices {
        let name = rig.nodes[index].name
        let bone: SliderCapture.Bone
        if let path = paths[index], let match = byPath[path] { bone = match; viaPath += 1 }
        else if let matches = byName[name], matches.count == 1, rig.nodes(named: name).count == 1 { bone = matches[0]; viaName += 1 }
        else { continue }
        let (t, q, s) = try sliderLocal(pos: bone.pos, quat: bone.quat, scl: bone.scl, "\(capture.label) bone \(name)")
        pose.localMatrices[index] = Transform.trs(t, q, s)
    }
    tally.counts["baseViaPath", default: 0] += viaPath
    tally.counts["baseViaName", default: 0] += viaName
    tally.counts["baseRest", default: 0] += rig.nodes.count - viaPath - viaName
    return pose
}

@Test(.enabled(if: SourceFixtureSupport.shouldRun(["IKKOKU_SLIDER_ORACLE", "IKKOKU_SLIDER_ORACLE_CASES", "IKKOKU_SOURCE_AVATAR",
                                                   "IKKOKU_SOURCE_MALE_AVATAR", "IKKOKU_STUDIO_ANIMATION_CATALOG"]),
               "Requires IKKOKU_SLIDER_ORACLE, IKKOKU_SLIDER_ORACLE_CASES, IKKOKU_SOURCE_AVATAR, IKKOKU_SOURCE_MALE_AVATAR and IKKOKU_STUDIO_ANIMATION_CATALOG"))
func sourceShapeRatesMatchOriginalSliderUnlockerCaptureWhenSupplied() throws {
    let captures = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SLIDER_ORACLE"))
    let casesURL = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_SLIDER_ORACLE_CASES"))
    let table = try String(contentsOf: casesURL, encoding: .utf8)
    let catalogURL = URL(fileURLWithPath: try SourceFixtureSupport.require("IKKOKU_STUDIO_ANIMATION_CATALOG"))
    let catalog = try SourceStudioAnimationCatalog.load(url: catalogURL)
    let range = SourceShapeRateRange.configured
    let mode = range == .vanilla ? "vanilla" : "unlocked"
    var rigs: [Int: (SourceRig, SourceShapeDomain, SourceShapeDomain)] = [:]
    func rig(sex: Int) throws -> (SourceRig, SourceShapeDomain, SourceShapeDomain) {
        if let cached = rigs[sex] { return cached }
        let url = URL(fileURLWithPath: try SourceFixtureSupport.require(sex == 1 ? "IKKOKU_SOURCE_AVATAR" : "IKKOKU_SOURCE_MALE_AVATAR"))
        let contract = try SourceShapeContract.decode(Data(contentsOf: url.deletingLastPathComponent()
            .appendingPathComponent("character-shape-contract.json")))
        let source = try SourceRig.loadModel(url: url)
        let body = try #require(contract.domain("body")), face = try #require(contract.domain("face"))
        let loaded = (source, body, face)
        rigs[sex] = loaded
        return loaded
    }
    var report: [String: Any] = [:]
    var tallies: [String: SliderOracleTally] = [:]
    var expected = 0
    for line in table.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        try #require(fields.count == 6, "Case rows are label, scene, sha256, key, sex, modes.")
        guard fields[5].split(separator: ",").map(String.init).contains(mode) else { continue }
        expected += 1
        let label = fields[0], key = try #require(Int32(fields[3])), sex = try #require(Int(fields[4]))
        var tally = SliderOracleTally()
        defer { tallies[label] = tally }
        let capture = try JSONDecoder().decode(SliderCapture.self,
            from: Data(contentsOf: captures.appendingPathComponent("\(mode)-\(label).json")))
        try #require(capture.stage == "loaded" && capture.mode == mode && capture.label == label
            && capture.key == Int(key) && capture.sex == sex, "Capture \(mode)-\(label) does not match its case row.")
        // A relative scene path is relative to the case table.
        let sceneData = try Data(contentsOf: fields[1].hasPrefix("/") ? URL(fileURLWithPath: fields[1])
            : casesURL.deletingLastPathComponent().appendingPathComponent(fields[1]))
        let digest = SHA256.hash(data: sceneData).map { String(format: "%02x", $0) }.joined()
        try #require(digest == fields[2], "Scene \(label) bytes differ from the captured scene.")
        let document = try KoikatsuSceneReader.decodeDocument(sceneData)
        let record = try #require(sliderFind(document.snapshot.roots, key: key)?.character, "No character with key \(key).")
        let custom = try record.card().customization()
        if custom.sex != sex || custom.headID != capture.parsed.headId || custom.boneType != capture.parsed.typeBone
            || custom.headID != 0 || custom.boneType != 0 {
            tally.failures.append("identity: card sex \(custom.sex) head \(custom.headID) bone \(custom.boneType)")
        }
        // (a) Drawn rates against the original's parsed rates.
        for (domain, saved, original) in [("body", custom.bodyValues, capture.parsed.body), ("face", custom.faceValues, capture.parsed.face)] {
            guard saved.count == original.count, saved.count == (domain == "body" ? 44 : 52) else {
                tally.failures.append("(a) \(domain) rate count \(saved.count) vs \(original.count)"); continue
            }
            for i in saved.indices {
                tally.check("(a) \(domain)[\(i)]", abs(Double(range.drawn(saved[i])) - Double(original[i])), tolerance: 1e-4, max: \.maxRate)
            }
        }
        // (b) The Animator height input.
        do {
            let animation = try catalog.resolve(SourceStudioAnimationState(record: record), directory: catalogURL.deletingLastPathComponent())
            let input = try animation.parameters(height: SourceStudioAnimation.cardHeight(custom.bodyValues))["height"]
            if let input, let original = capture.animator.floats["height"] {
                tally.check("(b) height", abs(Double(input) - Double(original)), tolerance: 1e-4, max: \.maxHeight)
            } else { tally.failures.append("(b) height: engine \(String(describing: input)), original \(String(describing: capture.animator.floats["height"]))") }
        } catch { tally.failures.append("(b) height: \(error)") }
        let (source, bodyDomain, faceDomain) = try rig(sex: sex)
        // (c) Source channels, by their single anim-key name.
        for (domain, shape, values, channels) in [("body", bodyDomain, custom.bodyValues, capture.shapes.body.sources),
                                                  ("face", faceDomain, custom.faceValues, capture.shapes.face.sources)] {
            tally.counts["\(domain)Channels"] = channels.count
            let state: [String: SourceShapeTransform]
            do { state = try shape.makeState(values: values) } catch {
                tally.failures.append("(c) \(domain) state: \(error)"); continue
            }
            for channel in channels {
                guard let names = channel.names, names.count == 1, let value = state[names[0]] else {
                    tally.failures.append("(c) \(domain) channel \(channel.id) \(channel.names ?? []): missing in the engine"); continue
                }
                let item = "(c) \(domain) \(names[0])"
                let pos = try sliderVector(channel.pos, item), rot = try sliderVector(channel.rot, item), scl = try sliderVector(channel.scl, item)
                for axis in 0..<3 {
                    tally.check("\(item) pos[\(axis)]", abs(Double(value.position[axis]) - Double(pos[axis])), tolerance: 1e-4, max: \.maxChannelPosition)
                    tally.check("\(item) rot[\(axis)]", sliderEulerDelta(value.rotationDegrees[axis], rot[axis]), tolerance: 1e-3, max: \.maxChannelRotation)
                    tally.check("\(item) scl[\(axis)]", abs(Double(value.scale[axis]) - Double(scl[axis])), tolerance: 1e-4, max: \.maxChannelScale)
                }
            }
        }
        // (d) Destination bones, on the captured base (see sliderBasePose).
        do {
            let base = try sliderBasePose(rig: source.rig, capture: capture, tally: &tally)
            let options = SourceBodyShapePose.Options(sex: sex == 1 ? .female : .male, boneType: .standard, updateMask: 7, applyAlways: true)
            var pose = try SourceBodyShapePose.make(rig: source.rig, domain: bodyDomain, values: custom.bodyValues, options: options, basePose: base)
            pose = try SourceFaceShapePose.make(rig: source.rig, domain: faceDomain, values: custom.faceValues, basePose: pose,
                                                boneType: 0, headCorrection: 1)
            for (domain, destinations) in [("body", capture.shapes.body.destinations), ("face", capture.shapes.face.destinations)] {
                tally.counts["\(domain)Destinations"] = destinations.count
                for destination in destinations {
                    guard let name = destination.bone, let pos = destination.pos, let quat = destination.quat, let scl = destination.scl else {
                        tally.failures.append("(d) \(domain) destination \(destination.id): no captured bone"); continue
                    }
                    let item = "(d) \(domain) \(name)"
                    guard let index = try? source.rig.uniqueNode(named: name) else {
                        tally.failures.append("\(item): missing in the engine"); continue
                    }
                    let (t, q, s) = try sliderLocal(pos: pos, quat: quat, scl: scl, item)
                    let engine = sliderComponents(pose.localMatrices[index])
                    let original = simd_quatd(ix: Double(q.imag.x), iy: Double(q.imag.y), iz: Double(q.imag.z), r: Double(q.real)).normalized
                    for axis in 0..<3 {
                        tally.check("\(item) pos[\(axis)]", abs(engine.position[axis] - Double(t[axis])), tolerance: 1e-4, max: \.maxBonePosition)
                        tally.check("\(item) scl[\(axis)]", abs(engine.scale[axis] - Double(s[axis])), tolerance: 1e-4, max: \.maxBoneScale)
                    }
                    tally.check("\(item) angle", sliderAngleDegrees(engine.rotation, original), tolerance: 1e-3, max: \.maxBoneAngle)
                }
            }
        } catch { tally.failures.append("(d) \(error)") }
    }
    for (label, tally) in tallies { report["\(mode)-\(label)"] = tally.json }
    if let path = ProcessInfo.processInfo.environment["IKKOKU_SLIDER_ORACLE_REPORT"], !path.isEmpty {
        try JSONSerialization.data(withJSONObject: ["mode": mode, "captures": report], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
    #expect(expected == 3 && tallies.count == expected, "Expected the 3 registered captures of mode \(mode).")
    for (label, tally) in tallies.sorted(by: { $0.key < $1.key }) {
        #expect(tally.failures.isEmpty, "\(mode)-\(label): \(tally.failures.count) of \(tally.compared) items fail; first: \(tally.failures.prefix(5))")
    }
}
