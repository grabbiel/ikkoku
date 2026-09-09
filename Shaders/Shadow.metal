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
    constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]],
    device const uchar* hiddenBuf [[buffer(BufferIndexVertexHidden)]])
{
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
    if ((mat.flags & MaterialFlagHasBodyMask) && bodyMask.sample(linearClamp, in.uv).r > 0.5) discard_fragment();
    if (mat.flags & MaterialFlagAlphaTest) {
        float a = (mat.flags & MaterialFlagHasBaseTexture) ? baseTex.sample(linearRepeat, in.uv).a : 1.0;
        if (a * mat.baseColor.a < mat.params.w) discard_fragment();
    }
}
