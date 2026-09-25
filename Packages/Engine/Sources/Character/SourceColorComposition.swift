import Foundation
import CoreMath

/// Recovered create_head/create_eye/create_eyewhite/create_topN/main_hair
/// albedo equations. Inputs are normalized source texture samples, before lighting.
public enum SourceColorComposition {
    public enum Kind: String, Codable, Sendable { case head, eye, eyeWhite, clothes, hair }

    public static func sample(kind: Kind, main: Float4, mask: Float4, colors: [Float4], blend: Float = 0) throws -> Float4 {
        let count = kind == .head || kind == .eyeWhite ? 2 : kind == .eye ? 1 : 3
        guard colors.count == count, colors.allSatisfy({ c in (0..<4).allSatisfy { c[$0].isFinite && (0...1).contains(c[$0]) } }),
              (0..<4).allSatisfy({ main[$0].isFinite && mask[$0].isFinite }), blend.isFinite, (0...1).contains(blend) else {
            throw SourceCharacterCardError.invalid("Invalid source texture composition inputs.")
        }
        return compose(kind: kind, main: main, mask: mask, colors: colors, blend: blend)
    }

    /// create_topN replaces each region color with its pattern pair before the
    /// RGB region mask is applied. Alpha controls pattern intensity inversely.
    public static func patternColor(base: Float4, pattern: Float4, red: Float) -> Float4 {
        let amount = max(red, 1 - pattern.w)
        return Float4(pattern.x + amount * (base.x - pattern.x),
                      pattern.y + amount * (base.y - pattern.y),
                      pattern.z + amount * (base.z - pattern.z), base.w)
    }

    /// create_head uses ordered straight-alpha interpolation and always emits
    /// opaque output. Paint alone is attenuated by the source face paint mask.
    public static func layer(base: Float4, texture: Float4, color: Float4, mask: Float = 1) -> Float4 {
        let amount = texture.w * color.w * mask
        return Float4(base.x + amount * (texture.x * color.x - base.x),
                      base.y + amount * (texture.y * color.y - base.y),
                      base.z + amount * (texture.z * color.z - base.z), 1)
    }

    /// UV in original Unity orientation. ChaControl maps normalized layout to
    /// source shader vectors before the shader rotates/scales about (0.5,0.5).
    public static func faceUV(_ uv: Float2, layout: Float4, kind: String) -> Float2 {
        let offset = Float2(0.25 - 0.5 * layout.x, 0.3 - 0.6 * layout.y)
        let scale = kind == "mole" ? 0.7 * layout.w : -8 + 8.7 * layout.w
        let point = (uv + offset - Float2(repeating: 0.5)) * (4 * (1 - scale))
        let angle: Float = kind == "mole" ? 0 : (1 - 2 * layout.z) * 6.283185
        let sine = sin(angle), cosine = cos(angle)
        return Float2(point.x * cosine + point.y * sine,
                      -point.x * sine + point.y * cosine) + Float2(repeating: 0.5)
    }

    static func compose(kind: Kind, main: Float4, mask: Float4, colors: [Float4], blend: Float) -> Float4 {
        var result = Float4(repeating: 1)
        for channel in 0..<3 {
            switch kind {
            case .head:
                let tint = (1 + mask.x * (colors[0][channel] - 1)) * (1 + mask.y * (colors[1][channel] - 1))
                result[channel] = main[channel] * max(mask.z, tint)
            case .eye:
                let color = colors[0][channel], value = main.x
                let nonlinear = value > 0.5 ? color / (2 * (1 - value)) : 1 - (1 - color) / (2 * value)
                let bounded = nonlinear.isNaN ? 0 : min(max(nonlinear, 0), 1)
                let product = color * value
                let alpha = main.w * colors[0].w
                result[channel] = (product + blend * (bounded - product)) * alpha
                result.w = alpha * alpha
            case .eyeWhite: result[channel] = colors[1][channel] + main.x * (colors[0][channel] - colors[1][channel])
            case .clothes, .hair:
                var tint = 1 + mask.x * (colors[0][channel] - 1)
                tint += mask.y * (colors[1][channel] - tint)
                tint += mask.z * (colors[2][channel] - tint)
                result[channel] = kind == .hair ? tint : min(max(main[channel], 0), 1) * tint * main.w
                result.w = kind == .hair ? 1 : main.w * main.w
            }
        }
        return result
    }
}
