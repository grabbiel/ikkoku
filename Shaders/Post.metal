#include "Common.h"

struct FSQOut { float4 position [[position]]; float2 uv; };

vertex FSQOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSQOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Background gradient (sky) drawn before geometry; depth = far (0 in reverse-Z).
fragment float4 background_fragment(FSQOut in [[stage_in]],
                                    constant PostParams& post [[buffer(BufferIndexPostParams)]],
                                    constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]])
{
    float3 top = frame.ambientSky.rgb;
    float3 bottom = frame.ambientGround.rgb;
    float t = smoothstep(0.0, 1.0, 1.0 - in.uv.y);
    float3 c = mix(top, bottom, t);
    return float4(c, 1.0);
}

fragment float4 bloom_threshold_fragment(FSQOut in [[stage_in]],
                                         constant PostParams& post [[buffer(BufferIndexPostParams)]],
                                         texture2d<float> scene [[texture(TextureIndexSceneColor)]])
{
    float3 c = scene.sample(linearClamp, in.uv).rgb;
    float l = luminance(c);
    float t = post.bloom.x;
    float k = smoothstep(t, t + 0.3, l);
    return float4(c * k, 1.0);
}

// 13-tap downsample (Jimenez)
fragment float4 bloom_downsample_fragment(FSQOut in [[stage_in]],
                                          constant PostParams& post [[buffer(BufferIndexPostParams)]],
                                          texture2d<float> src [[texture(TextureIndexSceneColor)]])
{
    float2 ts = float2(1.0 / src.get_width(), 1.0 / src.get_height());
    float3 a = src.sample(linearClamp, in.uv + ts * float2(-2, -2)).rgb;
    float3 b = src.sample(linearClamp, in.uv + ts * float2( 0, -2)).rgb;
    float3 c = src.sample(linearClamp, in.uv + ts * float2( 2, -2)).rgb;
    float3 d = src.sample(linearClamp, in.uv + ts * float2(-2,  0)).rgb;
    float3 e = src.sample(linearClamp, in.uv).rgb;
    float3 f = src.sample(linearClamp, in.uv + ts * float2( 2,  0)).rgb;
    float3 g = src.sample(linearClamp, in.uv + ts * float2(-2,  2)).rgb;
    float3 h = src.sample(linearClamp, in.uv + ts * float2( 0,  2)).rgb;
    float3 i = src.sample(linearClamp, in.uv + ts * float2( 2,  2)).rgb;
    float3 j = src.sample(linearClamp, in.uv + ts * float2(-1, -1)).rgb;
    float3 k = src.sample(linearClamp, in.uv + ts * float2( 1, -1)).rgb;
    float3 l = src.sample(linearClamp, in.uv + ts * float2(-1,  1)).rgb;
    float3 m = src.sample(linearClamp, in.uv + ts * float2( 1,  1)).rgb;
    float3 r = e * 0.125;
    r += (a + c + g + i) * 0.03125;
    r += (b + d + f + h) * 0.0625;
    r += (j + k + l + m) * 0.125;
    return float4(r, 1.0);
}

// 3x3 tent upsample, additive blend is set on the pipeline.
fragment float4 bloom_upsample_fragment(FSQOut in [[stage_in]],
                                        constant PostParams& post [[buffer(BufferIndexPostParams)]],
                                        texture2d<float> src [[texture(TextureIndexSceneColor)]])
{
    float2 ts = float2(1.0 / src.get_width(), 1.0 / src.get_height()) * post.bloom.z;
    float3 s = float3(0.0);
    s += src.sample(linearClamp, in.uv + ts * float2(-1, -1)).rgb * 1.0;
    s += src.sample(linearClamp, in.uv + ts * float2( 0, -1)).rgb * 2.0;
    s += src.sample(linearClamp, in.uv + ts * float2( 1, -1)).rgb * 1.0;
    s += src.sample(linearClamp, in.uv + ts * float2(-1,  0)).rgb * 2.0;
    s += src.sample(linearClamp, in.uv).rgb * 4.0;
    s += src.sample(linearClamp, in.uv + ts * float2( 1,  0)).rgb * 2.0;
    s += src.sample(linearClamp, in.uv + ts * float2(-1,  1)).rgb * 1.0;
    s += src.sample(linearClamp, in.uv + ts * float2( 0,  1)).rgb * 2.0;
    s += src.sample(linearClamp, in.uv + ts * float2( 1,  1)).rgb * 1.0;
    return float4(s / 16.0, 1.0);
}

inline float3 applyGrade(float3 c, constant PostParams& post) {
    c *= post.grade.x;                                   // exposure
    float3 warm = float3(1.0 + post.grade.w * 0.1, 1.0, 1.0 - post.grade.w * 0.1);
    c *= warm;                                           // temperature
    float l = luminance(c);
    c = mix(float3(l), c, post.grade.z);                 // saturation
    c = (c - 0.5) * post.grade.y + 0.5;                  // contrast
    return max(c, 0.0);
}

// Composite: scene + bloom → tone/grade → sRGB. Output is the swapchain (or capture) target.
fragment float4 composite_fragment(FSQOut in [[stage_in]],
                                   constant PostParams& post [[buffer(BufferIndexPostParams)]],
                                   texture2d<float> scene [[texture(TextureIndexSceneColor)]],
                                   texture2d<float> bloom [[texture(TextureIndexBloom)]])
{
    float4 s = scene.sample(linearClamp, in.uv);
    float3 c = s.rgb;
    if (post.flags & 2u) c += bloom.sample(linearClamp, in.uv).rgb * post.bloom.y;
    if (post.flags & 8u) c = applyGrade(c, post);
    if (post.flags & 4u) {
        float2 d = (in.uv - 0.5) * float2(post.vignette.z, 1.0);
        float v = smoothstep(0.8, 0.8 - post.vignette.y, length(d) * post.vignette.x);
        c *= mix(1.0, v, post.vignette.x > 0.0 ? 1.0 : 0.0);
    }
    c = c / (1.0 + c * 0.05);            // gentle highlight roll-off
    return float4(linearToSrgb(saturate(c)), s.a);
}

// FXAA 3.11 (console quality), on an sRGB image with luma in alpha not required: compute luma here.
inline float fxaaLuma(float3 c) { return c.g * 0.587 + c.r * 0.299 + c.b * 0.114; }

fragment float4 fxaa_fragment(FSQOut in [[stage_in]],
                              constant PostParams& post [[buffer(BufferIndexPostParams)]],
                              texture2d<float> tex [[texture(TextureIndexSceneColor)]])
{
    float2 ts = post.texel.xy;
    float3 rgbM = tex.sample(linearClamp, in.uv).rgb;
    float4 src = tex.sample(linearClamp, in.uv);
    float lumaM = fxaaLuma(rgbM);
    float lumaN = fxaaLuma(tex.sample(linearClamp, in.uv + float2(0, -ts.y)).rgb);
    float lumaS = fxaaLuma(tex.sample(linearClamp, in.uv + float2(0,  ts.y)).rgb);
    float lumaE = fxaaLuma(tex.sample(linearClamp, in.uv + float2( ts.x, 0)).rgb);
    float lumaW = fxaaLuma(tex.sample(linearClamp, in.uv + float2(-ts.x, 0)).rgb);
    float lumaMin = min(lumaM, min(min(lumaN, lumaS), min(lumaE, lumaW)));
    float lumaMax = max(lumaM, max(max(lumaN, lumaS), max(lumaE, lumaW)));
    float range = lumaMax - lumaMin;
    if (range < max(0.0312, lumaMax * 0.125)) return src;
    float lumaNW = fxaaLuma(tex.sample(linearClamp, in.uv + float2(-ts.x, -ts.y)).rgb);
    float lumaNE = fxaaLuma(tex.sample(linearClamp, in.uv + float2( ts.x, -ts.y)).rgb);
    float lumaSW = fxaaLuma(tex.sample(linearClamp, in.uv + float2(-ts.x,  ts.y)).rgb);
    float lumaSE = fxaaLuma(tex.sample(linearClamp, in.uv + float2( ts.x,  ts.y)).rgb);
    float2 dir;
    dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
    dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));
    float dirReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * 0.25 * 0.125, 1.0 / 128.0);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpDirMin, -8.0, 8.0) * ts;
    float3 rgbA = 0.5 * (tex.sample(linearClamp, in.uv + dir * (1.0 / 3.0 - 0.5)).rgb +
                         tex.sample(linearClamp, in.uv + dir * (2.0 / 3.0 - 0.5)).rgb);
    float3 rgbB = rgbA * 0.5 + 0.25 * (tex.sample(linearClamp, in.uv + dir * -0.5).rgb +
                                       tex.sample(linearClamp, in.uv + dir * 0.5).rgb);
    float lumaB = fxaaLuma(rgbB);
    if (lumaB < lumaMin || lumaB > lumaMax) return float4(rgbA, src.a);
    return float4(rgbB, src.a);
}

// Simple copy
fragment float4 blit_fragment(FSQOut in [[stage_in]], texture2d<float> tex [[texture(TextureIndexSceneColor)]]) {
    return tex.sample(linearClamp, in.uv);
}
