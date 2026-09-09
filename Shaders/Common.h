#ifndef IkkokuCommon_h
#define IkkokuCommon_h
#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

// Fetches one vertex from the deformed buffer.
struct VSInput {
    float3 position;
    float  region;
    float3 normal;
    float  outlineWeight;
    float4 tangent;
    float2 uv;
    float4 color;
};

inline VSInput fetchVertex(uint vid,
                           device const DeformedVertex* verts,
                           device const float2* uvs,
                           device const uchar4* colors,
                           bool hasColors) {
    VSInput v;
    DeformedVertex d = verts[vid];
    v.position = d.position.xyz;
    v.region = d.position.w;
    v.normal = d.normal.xyz;
    v.outlineWeight = d.normal.w;
    v.tangent = d.tangent;
    v.uv = uvs[vid];
    v.color = hasColors ? float4(colors[vid]) / 255.0 : float4(1.0);
    return v;
}

inline float hiddenFlag(float region, uint mask) {
    uint r = uint(region + 0.5);
    return (r > 0u && r < 32u && (mask & (1u << r)) != 0u) ? 1.0 : 0.0;
}
inline float hiddenFlag(float region, uint flags, device const uchar* hiddenBuf, uint vid) {
    if (flags & DrawFlagHasHiddenBuffer) return hiddenBuf[vid] ? 1.0 : 0.0;
    return hiddenFlag(region, flags);
}

inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}
inline float3 linearToSrgb(float3 c) {
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}
inline float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

constexpr sampler linearRepeat(mag_filter::linear, min_filter::linear, mip_filter::linear, address::repeat);
constexpr sampler linearClamp(mag_filter::linear, min_filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler shadowSampler(mag_filter::linear, min_filter::linear, compare_func::greater_equal, address::clamp_to_edge);

#endif
