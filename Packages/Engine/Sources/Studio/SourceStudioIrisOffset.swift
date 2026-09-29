import Foundation
import simd
import Scene

/// One eye's exported `EyeLookMaterialControll` record, as
/// Tools/reverse/studio_look_settings.py writes the settings JSON's
/// `eyeMaterial` array (sorted eyeLR 0,1; values exported from the
/// bo_head_00 prefab, never assumed from the script's Reset defaults).  The
/// waits and power drive the iris texture shift, the four limits clamp it,
/// the texStates select the shifted textures (index 1 / 2 take the highlight
/// offsets) and the Yure fields belong to the random jitter that is reported
/// but not implemented.  `offset` / `scale` / `hlUpOffsetY` / `hlDownOffsetY`
/// are the prefab-serialized snapshot of the script's private card-driven
/// fields; the card fields that drive them at runtime are not recovered, so
/// callers pass the current values to `textureTransforms` explicitly.
public struct SourceStudioEyeMaterialSettings: Decodable, Sendable, Equatable {
    /// One texStates entry: the shader texture slot and whether it is a
    /// Yure (jittered) texture, which halves its power's y factor and skips
    /// the scale subtraction / SetTextureScale write.
    public struct TexState: Decodable, Sendable, Equatable {
        public let texID: Int
        public let texName: String
        public let isYure: Bool
    }

    /// 0 = L, 1 = R.
    public let eyeLR: Int
    public let insideWait, outsideWait, upWait, downWait: Double
    public let insideLimit, outsideLimit, upLimit, downLimit: Double
    public let power: Double
    /// The exported offset / scale snapshots of the private fields.
    public let offset: SIMD2<Double>
    public let scale: SIMD2<Double>
    public let hlUpOffsetY, hlDownOffsetY: Double
    public let texStates: [TexState]
    public let yureInside, yureOutside, yureUp, yureDown: Double
    public let yureTime: Double
    /// The eye renderer's GameObject name and material names (export
    /// provenance; `textureTransforms` does not read them).
    public let gameObject: String
    public let materials: [String]

    private enum CodingKeys: String, CodingKey {
        case eyeLR, InsideWait, OutsideWait, UpWait, DownWait
        case InsideLimit, OutsideLimit, UpLimit, DownLimit, power
        case offset, scale, hlUpOffsetY, hlDownOffsetY, texStates
        case YureInside, YureOutside, YureUp, YureDown, YureTime
        case gameObject, materials
    }
    // The export writes isYure as the typetree's 0/1 int, not a JSON bool.
    private struct TexStateRecord: Decodable { let texID: Int?; let texName: String; let isYure: Int }
    private struct Document: Decodable { let eyeMaterial: [SourceStudioEyeMaterialSettings] }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func scalar(_ key: CodingKeys) throws -> Double {
            let parsed = try container.decode(Double.self, forKey: key)
            guard parsed.isFinite else {
                throw RigError.invalid("Eye material \(key.rawValue) is not finite.")
            }
            return parsed
        }
        func vector(_ key: CodingKeys) throws -> SIMD2<Double> {
            try Self.checkedVector(container.decode([Double].self, forKey: key), key.rawValue)
        }
        guard let eyeLR = try container.decodeIfPresent(Int.self, forKey: .eyeLR) else {
            throw RigError.invalid("Eye material entry carries no eyeLR.")
        }
        self.eyeLR = eyeLR
        insideWait = try scalar(.InsideWait)
        outsideWait = try scalar(.OutsideWait)
        upWait = try scalar(.UpWait)
        downWait = try scalar(.DownWait)
        insideLimit = try scalar(.InsideLimit)
        outsideLimit = try scalar(.OutsideLimit)
        upLimit = try scalar(.UpLimit)
        downLimit = try scalar(.DownLimit)
        power = try scalar(.power)
        offset = try vector(.offset)
        scale = try vector(.scale)
        hlUpOffsetY = try scalar(.hlUpOffsetY)
        hlDownOffsetY = try scalar(.hlDownOffsetY)
        let texStateRecords = try container.decode([TexStateRecord].self, forKey: .texStates)
        guard !texStateRecords.isEmpty else {
            throw RigError.invalid("Eye material entry carries no texStates.")
        }
        // The exported typetree carries texID -1 sentinels; the shift indexes
        // the texStates array position, so the id is kept, defaulted to -1.
        texStates = try texStateRecords.map {
            TexState(texID: $0.texID ?? -1, texName: try Self.checkedTexName($0.texName),
                     isYure: $0.isYure != 0)
        }
        yureInside = try scalar(.YureInside)
        yureOutside = try scalar(.YureOutside)
        yureUp = try scalar(.YureUp)
        yureDown = try scalar(.YureDown)
        yureTime = try scalar(.YureTime)
        gameObject = try container.decode(String.self, forKey: .gameObject)
        materials = try container.decode([String].self, forKey: .materials)
    }

    private static func checkedVector(_ raw: [Double], _ what: String) throws -> SIMD2<Double> {
        guard raw.count == 2, raw.allSatisfy(\.isFinite) else {
            throw RigError.invalid("Eye material \(what) is not a finite two-component vector.")
        }
        return SIMD2<Double>(raw[0], raw[1])
    }

    private static func checkedTexName(_ name: String) throws -> String {
        guard !name.isEmpty else {
            throw RigError.invalid("Eye material texStates entry carries an empty texName.")
        }
        return name
    }

    /// Decode every `eyeMaterial` entry of a settings document, in exported
    /// (eyeLR 0,1) order; the sibling of `SourceStudioEyeLookSettings.init(json:)`
    /// so the solver's minimal reference fixtures stay decodable without the
    /// new block.
    public static func document(json data: Data) throws -> [SourceStudioEyeMaterialSettings] {
        try JSONDecoder().decode(Document.self, from: data).eyeMaterial
    }

    static func checked(_ value: Double, _ what: String) throws -> Double {
        guard value.isFinite else { throw RigError.invalid("\(what) is not a finite number: \(value).") }
        return value
    }

    /// The recovered EyeLookMaterialControll.Update, per texState: shift the
    /// frame's rates by the eye's offset (normalizing when the shifted vector
    /// leaves the unit circle), map v.x / v.y through the Inside/Outside and
    /// Down/Up waits, scale by power (times 0.8/0.5 for Yure textures) and the
    /// scale-driven 1...5 factors, clamp against the four limits, add the
    /// highlight offset y for texStates 1 and 2, and — only for non-Yure
    /// textures — subtract scale/2 and write texture scale 1 + scale.  The
    /// Yure branch's random YureAddScale / YureAddVec jitter (re-rolled every
    /// YureTime) is NOT modeled: Yure entries come back with the unjittered
    /// offset and identity texture scale, `yure` set, so the caller knows the
    /// value is a placeholder until the jitter is settled.
    /// `offset` / `scale` / `hlUpOffsetY` / `hlDownOffsetY` are the frame's
    /// card-driven values; the script's Reset defaults are L (-0.2, -0.2) /
    /// R (+0.2, -0.2), scale (0, 0) and hl 0, which the bo_head_00 prefab
    /// keeps (the exported `offset` / `scale` fields carry them).
    public static func textureTransforms(
        rateH: Double, rateV: Double, settings: SourceStudioEyeMaterialSettings,
        offset: SIMD2<Double>, scale: SIMD2<Double>,
        hlUpOffsetY: Double, hlDownOffsetY: Double) throws
        -> [(offset: SIMD2<Double>, scale: SIMD2<Double>, yure: Bool)] {
        var v = SIMD2<Double>(try checked(rateH, "iris rateH") + offset.x,
                              try checked(rateV, "iris rateV") + offset.y)
        // Unity Vector2 magnitude gate: only a vector outside the unit
        // circle is re-normalized onto it.
        if simd_length(v) > 1 { v = v / simd_length(v) }
        let num = try SourceStudioEyeLookSolver.lerp(
            settings.insideWait, settings.outsideWait,
            t: SourceStudioEyeLookSolver.inverseLerp(-1, 1, v.x))
        // Down comes first here, not Up: v.y = -1 reads DownWait.
        let num2 = try SourceStudioEyeLookSolver.lerp(
            settings.downWait, settings.upWait,
            t: SourceStudioEyeLookSolver.inverseLerp(-1, 1, v.y))
        let num3 = try SourceStudioEyeLookSolver.lerp(1, 5, t: scale.x)
        let num4 = try SourceStudioEyeLookSolver.lerp(1, 5, t: scale.y)
        return try settings.texStates.indices.map { index in
            let yure = settings.texStates[index].isYure
            let powerX = settings.power * (yure ? 0.8 : 1)
            let powerY = settings.power * (yure ? 0.5 : 1)
            var out = SIMD2<Double>(
                try SourceStudioEyeLookSolver.clamp(num * powerX * num3,
                                                    settings.insideLimit, settings.outsideLimit),
                try SourceStudioEyeLookSolver.clamp(num2 * powerY * num4,
                                                    settings.upLimit, settings.downLimit))
            if index == 1 { out.y += try checked(hlUpOffsetY, "hlUpOffsetY") }
            if index == 2 { out.y += try checked(hlDownOffsetY, "hlDownOffsetY") }
            guard !yure else {
                // The Yure branch writes a randomly re-rolled scale/offset the
                // trace does not model; leave both untouched.
                return (offset: out, scale: SIMD2<Double>(1, 1), yure: true)
            }
            out += scale * -0.5
            return (offset: out, scale: SIMD2<Double>(1, 1) + scale, yure: false)
        }
    }
}
