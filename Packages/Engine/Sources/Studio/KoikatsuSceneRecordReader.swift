import Foundation
import Character

extension KoikatsuBinaryReader {
    mutating func bone(destination: SourceSceneEdits.Destination? = nil) throws -> KoikatsuBoneRecord {
        let key = try int32(), start = offset, transform = try changeAmount()
        if let destination { editSpans.transforms[destination] = start..<offset }
        return KoikatsuBoneRecord(sourceKey: key, transform: transform)
    }
    mutating func animation() throws -> KoikatsuAnimationRecord {
        KoikatsuAnimationRecord(group: try int32(), category: try int32(), no: try int32())
    }
    mutating func flags(_ count: Int) throws -> [Bool] {
        var result: [Bool] = []; for _ in 0..<count { result.append(try bool()) }; return result
    }
    mutating func integerMap() throws -> [Int32: Int32] {
        var result: [Int32: Int32] = [:]
        for _ in 0..<(try count()) {
            let key = try int32()
            guard result[key] == nil else { throw invalid("duplicate state dictionary key") }
            result[key] = try int32()
        }
        return result
    }
    mutating func embeddedCard() throws -> Data {
        let start = offset
        guard try int32() == 100, try string() == "【KoiKatuChara】", try string() == "0.0.0" else {
            throw invalid("unsupported embedded character-card framing")
        }
        _ = try take(byteCount()) // Face thumbnail.
        _ = try take(byteCount(maximum: 1024 * 1024))
        let payload = try uint64()
        guard payload <= 64 * 1024 * 1024 else { throw invalid("embedded character payload exceeds 64 MiB") }
        _ = try take(Int(payload))
        // The patched card reader probes exactly this legacy header, restoring
        // the stream on a nonmatch. Do not consume the following bone count.
        let signature = Data([4, 75, 75, 69, 120, 2, 0, 0, 0])
        if data.count - offset >= signature.count,
           data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + signature.count)) == signature {
            _ = try take(signature.count)
            _ = try take(byteCount())
        }
        let result = data.subdata(in: (data.startIndex + start)..<(data.startIndex + offset))
        _ = try SourceCharacterCard.decode(result)
        return result
    }
    mutating func character(depth: Int, objectKey: Int32) throws -> KoikatsuCharacterRecord {
        let sex = try int32()
        guard sex == 0 || sex == 1 else { throw invalid("unsupported character sex") }
        let cardStart = offset, card = try embeddedCard()
        editSpans.cards[objectKey] = cardStart..<offset
        var bones: [Int32: KoikatsuBoneRecord] = [:], ik: [Int32: KoikatsuBoneRecord] = [:]
        for _ in 0..<(try count()) {
            let key = try int32(); guard bones[key] == nil else { throw invalid("duplicate character FK bone ID") }
            bones[key] = try bone(destination: .characterFK(object: objectKey, bone: key))
        }
        for _ in 0..<(try count()) {
            let key = try int32(); guard ik[key] == nil else { throw invalid("duplicate character IK target ID") }
            ik[key] = try bone(destination: .characterIK(object: objectKey, target: key))
        }
        var children: [Int32: [KoikatsuObjectRecord]] = [:]
        for _ in 0..<(try count()) {
            let key = try int32(); guard children[key] == nil else { throw invalid("duplicate accessory point ID") }
            var entries: [KoikatsuObjectRecord] = []
            for _ in 0..<(try count()) { entries.append(try object(depth: depth + 1, rootKey: nil)) }
            children[key] = entries
        }
        let mode = try int32(), animationStart = offset, anime = try animation(), hands = [try int32(), try int32()]
        let nipple = try float(), fluids = try take(5), mouth = try float(), lip = try bool(), look = try bone(destination: .lookAt(object: objectKey))
        let kinematicStart = offset
        let enabledIK = try bool(), activeIK = try flags(5), enabledFK = try bool(), activeFK = try flags(7)
        editSpans.kinematics[objectKey] = .init(enableIK: kinematicStart..<(kinematicStart + 1),
            activeIK: (kinematicStart + 1)..<(kinematicStart + 6), enableFK: (kinematicStart + 6)..<(kinematicStart + 7),
            activeFK: (kinematicStart + 7)..<offset)
        let expressions = try flags(8), speedStart = offset, speed = try float(), pattern = try float(), option = try bool(), loop = try bool()
        let voicesStart = offset
        var voices: [KoikatsuAnimationRecord] = []
        for _ in 0..<(try count()) { voices.append(try animation()) }
        let voiceRepeat = try int32()
        editSpans.voices[objectKey] = voicesStart..<offset
        let visibleSon = try bool(), sonLength = try float(), simple = try bool()
        let simpleColor = try jsonVector(["r", "g", "b", "a"]), optionsStart = offset, option1 = try float(), option2 = try float()
        let neck = try take(byteCount()), eyes = try take(byteCount()), timeStart = offset, time = try float()
        editSpans.animations[objectKey] = .init(identity: animationStart..<(animationStart + 12),
            speedPattern: speedStart..<(speedStart + 8), forceLoop: (speedStart + 9)..<(speedStart + 10),
            options: optionsStart..<(optionsStart + 8), normalizedTime: timeStart..<(timeStart + 4))
        let groupStates = try integerMap(), states = try integerMap()
        return KoikatsuCharacterRecord(sex: sex, cardData: card, bones: bones, ikTargets: ik,
            accessoryChildren: children, kinematicMode: mode, animation: anime, handPatterns: hands,
            nipple: nipple, fluidLevels: fluids, mouthOpen: mouth, lipSync: lip, lookAtTarget: look,
            enableIK: enabledIK, activeIK: activeIK, enableFK: enabledFK, activeFK: activeFK, expressions: expressions,
            animationSpeed: speed, animationPattern: pattern, animationOptionVisible: option, forceLoop: loop,
            voices: voices, voiceRepeat: voiceRepeat, visibleSon: visibleSon, sonLength: sonLength,
            visibleSimple: simple, simpleColor: simpleColor, animationOptionParameters: SIMD2(option1, option2),
            neckData: neck, eyesData: eyes, animationNormalizedTime: time,
            accessoryGroupStates: groupStates, accessoryStates: states)
    }
    mutating func route() throws -> KoikatsuRouteRecord {
        var points: [KoikatsuRoutePointRecord] = []
        for _ in 0..<(try count()) {
            points.append(KoikatsuRoutePointRecord(bone: try bone(), speed: try float(), easeType: try int32(),
                connection: try int32(), aid: try bone(), aidInitialized: try bool(), linked: try bool()))
        }
        return KoikatsuRouteRecord(points: points, active: try bool(), loop: try bool(), visibleLine: try bool(),
                                  orientation: try int32(), color: try jsonVector(["r", "g", "b", "a"]))
    }
    mutating func camera(slot: Int? = nil) throws -> KoikatsuCameraRecord {
        let version = try int32()
        guard version == 2 else { throw KoikatsuReadError.unsupportedVersion("camera:\(version)") }
        let start = offset
        let result = KoikatsuCameraRecord(position: try vector3(), rotationDegrees: try vector3(), distance: try vector3(), fieldOfView: try float())
        if let slot { editSpans.cameraSlots[slot] = start..<offset } else { editSpans.currentCamera = start..<offset }
        return result
    }
    mutating func sceneLight(map: Bool) throws -> KoikatsuSceneLighting {
        let color = try jsonVector(["r", "g", "b", "a"]), intensity = try float(), x = try float(), y = try float(), shadow = try bool()
        return KoikatsuSceneLighting(color: color, intensity: intensity, rotation: SIMD2(x, y), shadow: shadow, type: map ? try int32() : nil)
    }
    mutating func sound(outside: Bool = false) throws -> KoikatsuSceneSound {
        let repeatMode = try int32(), number: Int32?, name: String?
        if outside { number = nil; name = try string() } else { number = try int32(); name = nil }
        return KoikatsuSceneSound(repeatMode: repeatMode, catalogNumber: number, fileName: name, play: try bool())
    }
    mutating func sceneSettings() throws -> KoikatsuSceneSettings {
        let map = try int32(), mapTransform = try changeAmount(), sunType = try int32(), mapOption = try bool(), correction = try int32()
        var f: [String: Float] = [:], b: [String: Bool] = [:], c: [String: SIMD4<Float>] = [:]
        f["aceBlend"] = try float()
        b["enableAOE"] = try bool(); c["aoeColor"] = try jsonVector(["r", "g", "b", "a"]); f["aoeRadius"] = try float()
        b["enableBloom"] = try bool()
        for key in ["bloomIntensity", "bloomBlur", "bloomThreshold"] { f[key] = try float() }
        b["enableDepth"] = try bool(); f["depthFocalSize"] = try float(); f["depthAperture"] = try float()
        b["enableVignette"] = try bool(); b["enableFog"] = try bool()
        c["fogColor"] = try jsonVector(["r", "g", "b", "a"])
        f["fogHeight"] = try float(); f["fogStartDistance"] = try float(); b["enableSunShafts"] = try bool()
        c["sunThresholdColor"] = try jsonVector(["r", "g", "b", "a"]); c["sunColor"] = try jsonVector(["r", "g", "b", "a"])
        let caster = try int32()
        for key in ["enableShadow", "faceNormal", "faceShadow"] { b[key] = try bool() }
        f["lineColorG"] = try float(); c["ambientShadow"] = try jsonVector(["r", "g", "b", "a"]); f["lineWidthG"] = try float()
        let ramp = try int32(); f["ambientShadowG"] = try float()
        let currentCamera = try camera()
        var cameras: [KoikatsuCameraRecord] = []; for slot in 0..<10 { cameras.append(try camera(slot: slot)) }
        let charLight = try sceneLight(map: false), mapLight = try sceneLight(map: true)
        let bgm = try sound(), env = try sound(), outside = try sound(outside: true)
        return KoikatsuSceneSettings(map: map, mapTransform: mapTransform, sunLightType: sunType, mapOption: mapOption,
            colorCorrection: correction, floatSettings: f, boolSettings: b, colorSettings: c, sunCaster: caster, ramp: ramp,
            camera: currentCamera, cameraSlots: cameras, characterLight: charLight, mapLight: mapLight,
            backgroundMusic: bgm, environmentSound: env, outsideSound: outside, background: try string(), frame: try string())
    }
}

public extension KoikatsuSceneReader {
    /// Complete installed 1.0.4.2 writer framing; keeps all bytes, including
    /// unsupported plug-in trailers. It does not instantiate runtime objects.
    static func decodeDocument(_ data: Data) throws -> KoikatsuSceneDocument {
        let snapshot = try decode(data)
        var reader = try KoikatsuBinaryReader(data)
        reader.offset = snapshot.objectSectionEndOffset
        let settings = try reader.sceneSettings()
        guard try reader.string() == "【KStudio】" else { throw reader.invalid("missing original Studio writer marker") }
        let end = reader.offset
        return KoikatsuSceneDocument(snapshot: snapshot, settings: settings, baseSceneEndOffset: end,
            trailingData: try reader.take(data.count - end), preservedData: data)
    }
}
