#include "Common.h"

struct ShadowVertexOut {
    float4 position [[position]];
    float2 uv;
    float hidden;
};

vertex ShadowVertexOut shadow_vertex(
    uint vid [[vertex_id]],
    device const DeformedVertex* verts [[buffer(BufferIndexVertices)]],
    device const float2* uvs [[buffer(BufferIndexTexcoords)]],
    constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
    uint iid [[instance_id]],
    constant DrawUniforms* draws [[buffer(BufferIndexDrawUniforms)]],
    device const uchar* hiddenBuf [[buffer(BufferIndexVertexHidden)]])
{
    // DrawUniforms by instance (ST-T04 B0): a per-draw record is bound as a one-element
    // array at its own offset (instance_id 0); an instanced draw indexes its table.
    constant DrawUniforms& draw = draws[iid];
    ShadowVertexOut o;
    float4 wp = draw.model * float4(verts[vid].position.xyz, 1.0);
    o.position = frame.shadowViewProjection * wp;
    o.uv = uvs[vid];
    o.hidden = hiddenFlag(verts[vid].position.w, draw.flags, hiddenBuf, vid);
    return o;
}

fragment void shadow_fragment(ShadowVertexOut in [[stage_in]],
                              constant MaterialUniforms& mat [[buffer(BufferIndexMaterial)]],
                              texture2d<float> baseTex [[texture(TextureIndexBase)]],
                              texture2d<float> bodyMask [[texture(TextureIndexBodyMask)]])
{
    if (in.hidden > 0.5) discard_fragment();
    if (bodyMaskDiscards(bodyMask, in.uv, mat)) discard_fragment();
    if (mat.flags & MaterialFlagAlphaTest) {
        float a = (mat.flags & MaterialFlagHasBaseTexture) ? baseTex.sample(forcedAnisoRepeat, in.uv).a : 1.0;
        if (a * mat.baseColor.a < mat.params.w) discard_fragment();
    }
}

// ---- Maps slice 5: the map sun's shadow map ---------------------------------
// One caster draw (MapShadowDrawUniforms): the map mesh's vertices, placed by its model matrix,
// moved along the normal as UnityClipSpaceShadowCasterPos (UnityCG.cginc, 5.6.2f1) does:
// wPos -= wNormal * normalBias * sqrt(1 - cos^2), normalBias = the light's normal bias times the
// shadow map's world texel size. The constant bias goes to the receiver's compare instead.
struct MapShadowVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex MapShadowVertexOut map_shadow_vertex(
    uint vid [[vertex_id]],
    device const DeformedVertex* verts [[buffer(BufferIndexVertices)]],
    device const float2* uvs [[buffer(BufferIndexTexcoords)]],
    constant MapShadowDrawUniforms& u [[buffer(BufferIndexDrawUniforms)]])
{
    MapShadowVertexOut o;
    float3 wp = (u.model * float4(verts[vid].position.xyz, 1.0)).xyz;
    if (u.toLight.w != 0.0) {
        float3x3 nm = float3x3(u.normalMatrix[0].xyz, u.normalMatrix[1].xyz, u.normalMatrix[2].xyz);
        float3 n = nm * verts[vid].normal.xyz;
        float len = length(n);
        if (len > 0.0) {
            n /= len;
            float c = dot(n, u.toLight.xyz);
            wp -= n * (u.toLight.w * sqrt(saturate(1.0 - c * c)));
        }
    }
    o.position = u.viewProjection * float4(wp, 1.0);
    o.uv = uvs[vid];
    return o;
}

// Standard's ShadowCaster (UnityStandardShadow.cginc): _ALPHATEST_ON clips alpha at _Cutoff; the
// blended modes clip the same way without the tier's dither mask.
fragment void map_shadow_fragment(MapShadowVertexOut in [[stage_in]],
                                  constant MapShadowDrawUniforms& u [[buffer(BufferIndexDrawUniforms)]],
                                  texture2d<float> baseTex [[texture(TextureIndexBase)]])
{
    if (u.alphaTest.x > 0.5) {
        float a = u.alphaTest.z * (u.alphaTest.w > 0.5 ? baseTex.sample(forcedAnisoRepeat, in.uv).a : 1.0);
        if (a < u.alphaTest.y) discard_fragment();
    }
}
