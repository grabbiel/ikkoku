#include "Common.h"

struct OutlineVertexOut {
    float4 position [[position]];
    float3 color;
    float2 uv;
    float hidden;
};

// Inverted hull: extrude along the normal by a screen-constant width.
vertex OutlineVertexOut outline_vertex(
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
    OutlineVertexOut o;
    float4 wp = draw.model * float4(v.position, 1.0);
    float3x3 nm = float3x3(draw.normalMatrix[0].xyz, draw.normalMatrix[1].xyz, draw.normalMatrix[2].xyz);
    float3 wn = normalize(nm * v.normal);
    float4 clip = frame.viewProjection * wp;
    float4 clipN = frame.viewProjection * float4(wn, 0.0);
    // Screen-space width in pixels, scaled by the material and the per-vertex weight.
    float weight = v.outlineWeight * ((mat.flags & MaterialFlagHasVertexColor) ? v.color.a : 1.0);
    float px = mat.outline.a * frame.outlineParams.x * draw.outlineScale * weight;
    px = clamp(px, 0.0, frame.outlineParams.z);
    float2 dir = clipN.xy;
    float len = length(dir);
    dir = len > 1e-5 ? dir / len : float2(0.0);
    // Convert pixels to clip units: clip.w * 2 * px / viewportHeight
    float2 offset = dir * (px * 2.0 * clip.w) * float2(frame.viewport.z, frame.viewport.w);
    clip.xy += offset;
    // Push slightly away to avoid z-fighting with the surface (reverse-Z: smaller = farther).
    clip.z -= clip.w * 0.0004;
    o.position = clip;
    o.color = mat.outline.rgb;
    o.uv = v.uv;
    o.hidden = hiddenFlag(v.region, draw.flags, hiddenBuf, vid);
    return o;
}

fragment float4 outline_fragment(OutlineVertexOut in [[stage_in]],
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
    return float4(in.color, 1.0);
}
