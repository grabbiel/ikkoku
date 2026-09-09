#include "Common.h"

struct ToonVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 worldNormal;
    float4 worldTangent;
    float2 uv;
    float4 color;
    float4 shadowCoord;
    float hidden;
};

vertex ToonVertexOut toon_vertex(
    uint vid [[vertex_id]],
    device const DeformedVertex* verts [[buffer(BufferIndexVertices)]],
    device const float2* uvs [[buffer(BufferIndexTexcoords)]],
    device const uchar4* colors [[buffer(BufferIndexVertexColors)]],
    constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]],
    constant MaterialUniforms& mat [[buffer(BufferIndexMaterial)]],
    device const uchar* hiddenBuf [[buffer(BufferIndexVertexHidden)]])
{
    VSInput v = fetchVertex(vid, verts, uvs, colors, (mat.flags & MaterialFlagHasVertexColor) != 0);
    ToonVertexOut o;
    float4 wp = draw.model * float4(v.position, 1.0);
    o.worldPos = wp.xyz;
    if (draw.depthBias != 0.0) wp.xyz += normalize(frame.cameraPosition.xyz - wp.xyz) * draw.depthBias;
    o.position = frame.viewProjection * wp;
    float3x3 nm = float3x3(draw.normalMatrix[0].xyz, draw.normalMatrix[1].xyz, draw.normalMatrix[2].xyz);
    o.worldNormal = normalize(nm * v.normal);
    o.worldTangent = float4(normalize(nm * v.tangent.xyz), v.tangent.w);
    o.uv = v.uv;
    o.color = v.color;
    o.shadowCoord = frame.shadowViewProjection * wp;
    o.hidden = hiddenFlag(v.region, draw.flags, hiddenBuf, vid);
    return o;
}

// ---- Lighting helpers -------------------------------------------------------

inline float sampleShadow(float4 sc, depth2d<float> shadowMap, constant FrameUniforms& frame, float3 n, float3 l) {
    if (frame.mainLightDirection.w <= 0.0) return 1.0;
    float3 p = sc.xyz / sc.w;
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float ndl = saturate(dot(n, l));
    float bias = frame.shadowParams.y + frame.shadowParams.z * (1.0 - ndl);
    float ref = p.z + bias;            // reverse-Z: lit when stored depth >= ref
    float texel = frame.shadowParams.x;
    float r = frame.shadowParams.w;
    float sum = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            sum += shadowMap.sample_compare(shadowSampler, uv + float2(x, y) * texel * r, ref);
    float s = sum / 9.0;
    return mix(1.0, s, frame.mainLightDirection.w);
}

struct Surface {
    float3 albedo;      // linear
    float  alpha;
    float3 normal;      // world
    float3 view;        // to camera
    float  specMask;    // DetailMask.r
    float  shadeDetail; // DetailMask.g (1 = none)
    float  lineMask;    // DetailMask.b + LineMask
};

inline float3 shadeToon(Surface s, ToonVertexOut in, constant FrameUniforms& frame,
                        constant MaterialUniforms& mat, constant LightsUniforms& lights,
                        depth2d<float> shadowMap, texture2d<float> hairGloss) {
    float3 n = s.normal;
    float3 v = s.view;
    float3 l = normalize(frame.mainLightDirection.xyz);
    float ndl = dot(n, l);
    float shadow = sampleShadow(in.shadowCoord, shadowMap, frame, n, l);
    if (mat.kind == MaterialKindSkin) shadow = mix(1.0, shadow, 0.55);   // faces keep soft, high-key shadows

    float threshold = mat.shadowColor.a;          // 0..1, default ~0.5
    float softness = max(mat.params.x, 0.005);
    float lit = smoothstep(threshold - softness, threshold + softness, ndl * 0.5 + 0.5);
    lit *= shadow;
    lit *= s.shadeDetail;                         // baked darkening

    float3 darkColor = s.albedo * mat.shadowColor.rgb;
    float3 base = mix(darkColor, s.albedo, lit);

    // Lit side shows the albedo as painted; dark side is albedo × shadow colour, lifted a little by ambient.
    float hemi = n.y * 0.5 + 0.5;
    float3 ambient = mix(frame.ambientGround.rgb, frame.ambientSky.rgb, hemi);
    float3 color = base * frame.mainLightColor.rgb * 0.94 + darkColor * ambient * 0.16;

    // Extra scene lights: point/spot, toon-stepped.
    for (uint i = 0; i < lights.count; ++i) {
        LightUniform L = lights.lights[i];
        if (L.params.y < 0.5) continue;
        int type = int(L.position.w);
        float3 ld; float atten = 1.0;
        if (type == LightTypeDirectional) {
            ld = -normalize(L.direction.xyz);
        } else {
            float3 d = L.position.xyz - in.worldPos;
            float dist = length(d);
            ld = d / max(dist, 1e-4);
            float range = max(L.direction.w, 0.01);
            atten = saturate(1.0 - (dist * dist) / (range * range));
            atten *= atten;
            if (type == LightTypeSpot) {
                float cosA = dot(-ld, normalize(L.direction.xyz));
                atten *= smoothstep(L.color.a, L.params.x, cosA);
            }
        }
        float nl = dot(n, ld) * 0.5 + 0.5;
        float lt = smoothstep(threshold - softness, threshold + softness, nl) * atten;
        color += s.albedo * L.color.rgb * lt * 0.35;
    }

    // Specular
    float3 h = normalize(l + v);
    float ndh = saturate(dot(n, h));
    float specStrength = mat.params.y * s.specMask;
    if (mat.kind == MaterialKindHair) {
        // "Angel ring": a soft latitude band around the head that follows the world-space normal, so it
        // stays stable across strand cards and as the head turns (strand UVs only feed the texture).
        float lat = n.y;                                    // -1 (under) … 1 (top)
        float target = mix(0.15, 0.85, mat.hairGloss.z);    // ring position
        float w = max(mat.hairGloss.y, 0.02) * 2.0;
        float band = 1.0 - smoothstep(0.0, w, abs(lat - target));
        band *= smoothstep(0.05, 0.45, ndh);                // only on the lit/camera side
        float g = smoothstep(0.25, 0.75, band) * mat.hairGloss.x * lit * 0.45;
        color = mix(color, mat.specular.rgb, g);
    } else if (mat.kind == MaterialKindSkin) {
        float sp = pow(ndh, mat.specular.a * 1.5);
        color += mat.specular.rgb * smoothstep(0.3, 0.9, sp) * specStrength * lit * 0.3;
    } else if (mat.kind != MaterialKindUnlit) {
        float sp = pow(ndh, mat.specular.a);
        color += mat.specular.rgb * smoothstep(0.55, 0.8, sp) * specStrength * lit * 0.6;
    }

    // Rim (lit-side biased)
    float ndv = saturate(dot(n, v));
    float rim = pow(1.0 - ndv, max(mat.rim.a, 0.5));
    float rimMask = mix(1.0, saturate(ndl * 0.5 + 0.5), mat.params.z);
    color += mat.rim.rgb * rim * rimMask * frame.mainLightColor.rgb;

    // Drawn lines darken
    color *= 1.0 - s.lineMask * 0.65;

    // Soft clip: extra lights and bloom-prone albedos must not blow out to white.
    float lum = luminance(color);
    if (lum > 1.0) color *= (1.0 + (lum - 1.0) * 0.25) / lum;

    // Fog
    float dist = length(frame.cameraPosition.xyz - in.worldPos);
    float f = saturate((dist - frame.fogRange.x) / max(frame.fogRange.y - frame.fogRange.x, 0.01)) * frame.fogColor.a;
    color = mix(color, frame.fogColor.rgb, f);
    color += mat.emissive.rgb * mat.emissive.a;
    return color;
}

fragment float4 toon_fragment(
    ToonVertexOut in [[stage_in]],
    bool isFront [[front_facing]],
    constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]],
    constant MaterialUniforms& mat [[buffer(BufferIndexMaterial)]],
    constant LightsUniforms& lights [[buffer(BufferIndexLights)]],
    texture2d<float> baseTex [[texture(TextureIndexBase)]],
    texture2d<float> colorMask [[texture(TextureIndexColorMask)]],
    texture2d<float> detailTex [[texture(TextureIndexDetail)]],
    texture2d<float> lineTex [[texture(TextureIndexLine)]],
    texture2d<float> normalTex [[texture(TextureIndexNormal)]],
    texture2d<float> overlay0 [[texture(TextureIndexOverlay0)]],
    texture2d<float> overlay1 [[texture(TextureIndexOverlay1)]],
    texture2d<float> overlay2 [[texture(TextureIndexOverlay2)]],
    depth2d<float> shadowMap [[texture(TextureIndexShadowMap)]],
    texture2d<float> hairGloss [[texture(TextureIndexHairGloss)]],
    texture2d<float> patternTex [[texture(TextureIndexPattern)]],
    texture2d<float> bodyMask [[texture(TextureIndexBodyMask)]])
{
    if (in.hidden > 0.5) discard_fragment();
    if ((mat.flags & MaterialFlagHasBodyMask) && bodyMask.sample(linearClamp, in.uv).r > 0.5) discard_fragment();
    float2 uv = in.uv;
    float4 base = mat.baseColor;
    if (mat.flags & MaterialFlagHasBaseTexture) {
        float4 t = baseTex.sample(linearRepeat, uv);
        base *= t;
    }
    if (mat.flags & MaterialFlagHasVertexColor && mat.kind != MaterialKindHair && mat.kind != MaterialKindCloth) {
        base.rgb *= in.color.rgb;
    }
    // ColorMask tinting (clothes): R/G/B zones get tint1/2/3
    if (mat.flags & MaterialFlagHasColorMask) {
        float3 m = colorMask.sample(linearRepeat, uv).rgb;
        float3 tint = float3(1.0);
        tint = mix(tint, mat.tint1.rgb, m.r);
        tint = mix(tint, mat.tint2.rgb, m.g);
        tint = mix(tint, mat.tint3.rgb, m.b);
        base.rgb *= tint;
        if (mat.flags & MaterialFlagHasPattern) {
            float2 puv = uv * mat.uvTransform.xy + mat.uvTransform.zw;
            float p = patternTex.sample(linearRepeat, puv).r;
            base.rgb = mix(base.rgb, base.rgb * mat.patternColor.rgb, p * mat.patternColor.a * m.r);
        }
    }
    // Overlays (blush, eyeshadow, lipstick, tan lines …): alpha masks × colour
    if (mat.flags & MaterialFlagHasOverlay0) { float a = overlay0.sample(linearRepeat, uv).a * mat.overlayColor0.a; base.rgb = mix(base.rgb, base.rgb * mat.overlayColor0.rgb, a); }
    if (mat.flags & MaterialFlagHasOverlay1) { float a = overlay1.sample(linearRepeat, uv).a * mat.overlayColor1.a; base.rgb = mix(base.rgb, base.rgb * mat.overlayColor1.rgb, a); }
    if (mat.flags & MaterialFlagHasOverlay2) { float a = overlay2.sample(linearRepeat, uv).a * mat.overlayColor2.a; base.rgb = mix(base.rgb, base.rgb * mat.overlayColor2.rgb, a); }

    float alpha = base.a;
    if (mat.flags & MaterialFlagAlphaTest) { if (alpha < mat.params.w) discard_fragment(); }

    Surface s;
    s.albedo = base.rgb;
    s.alpha = alpha;
    float3 n = normalize(in.worldNormal);
    if (!isFront && (mat.flags & MaterialFlagDoubleSided)) n = -n;
    if (mat.flags & MaterialFlagHasNormal) {
        float3 tn = normalTex.sample(linearRepeat, uv).xyz * 2.0 - 1.0;
        float3 t = normalize(in.worldTangent.xyz);
        float3 b = cross(n, t) * in.worldTangent.w;
        n = normalize(t * tn.x * 0.5 + b * tn.y * 0.5 + n * tn.z);
    }
    s.normal = n;
    s.view = normalize(frame.cameraPosition.xyz - in.worldPos);
    s.specMask = 1.0; s.shadeDetail = 1.0; s.lineMask = 0.0;
    if (mat.flags & MaterialFlagHasDetail) {
        float3 d = detailTex.sample(linearRepeat, uv).rgb;
        s.specMask = d.r; s.shadeDetail = mix(0.6, 1.0, d.g); s.lineMask = d.b;
    }
    if (mat.flags & MaterialFlagHasLine) { s.lineMask = max(s.lineMask, lineTex.sample(linearRepeat, uv).r); }

    float3 color;
    if (mat.kind == MaterialKindUnlit) {
        color = s.albedo + mat.emissive.rgb * mat.emissive.a;
    } else {
        color = shadeToon(s, in, frame, mat, lights, shadowMap, hairGloss);
    }
    return float4(color, alpha);
}

// ---- Eyes -------------------------------------------------------------------
// Iris texture is centred in the eye UV; `mat.eye` scales/offsets it for iris size/gaze.
fragment float4 eye_fragment(
    ToonVertexOut in [[stage_in]],
    constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]],
    constant MaterialUniforms& mat [[buffer(BufferIndexMaterial)]],
    constant LightsUniforms& lights [[buffer(BufferIndexLights)]],
    texture2d<float> irisTex [[texture(TextureIndexBase)]],
    texture2d<float> whiteTex [[texture(TextureIndexColorMask)]],
    texture2d<float> highlightTex [[texture(TextureIndexDetail)]],
    depth2d<float> shadowMap [[texture(TextureIndexShadowMap)]])
{
    if (in.hidden > 0.5) discard_fragment();
    float2 c = float2(0.5, 0.5) + mat.eye.yz;
    float2 iuv = (in.uv - c) / max(mat.eye.x, 0.05) + 0.5;
    float4 iris = irisTex.sample(linearClamp, iuv);
    float inside = float(all(iuv >= 0.0) && all(iuv <= 1.0));
    // Source-style eye textures (e.g. a transparent cornea shell) use alpha as coverage.
    if ((mat.flags & MaterialFlagAlphaTest) && iris.a < mat.params.w) discard_fragment();
    iris.a *= inside;
    float4 white = whiteTex.sample(linearClamp, in.uv);
    if (white.a == 0.0) white = float4(1.0, 1.0, 1.0, 1.0);
    float3 irisColor = iris.rgb * mat.baseColor.rgb;   // texture stores near-white where colourised
    float3 col = mix(white.rgb * mat.tint1.rgb, irisColor, iris.a);
    // Highlights (screen-stable by using the same UV but slightly offset toward the light)
    float3 l = normalize(frame.mainLightDirection.xyz);
    float2 huv = iuv + float2(-l.x, l.y) * 0.04;
    float4 hl = highlightTex.sample(linearClamp, huv);
    col = mix(col, float3(1.0), hl.a * mat.eye.w * inside);
    float3 n = normalize(in.worldNormal);
    float ndl = dot(n, l);
    float shadow = sampleShadow(in.shadowCoord, shadowMap, frame, n, l);
    if (mat.kind == MaterialKindSkin) shadow = mix(1.0, shadow, 0.55);   // faces keep soft, high-key shadows
    float lit = smoothstep(0.35, 0.55, ndl * 0.5 + 0.5) * shadow;
    col *= mix(mat.shadowColor.rgb, float3(1.0), lit);
    return float4(col, 1.0);
}
