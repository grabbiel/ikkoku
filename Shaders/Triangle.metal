//
//  Triangle.metal
//  Ikkoku
//
//  Created by rumpology on 8/19/26.
//
#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut triangle_vertex(
    uint vid [[vertex_id]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]])
{
    const float2 positions[3] = { float2(0, 0.6), float2(-0.6, -0.4), float2(0.6, -0.4) };
    const float3 colors[3]    = { float3(1, 0.3, 0.4), float3(0.3, 1, 0.5), float3(0.4, 0.5, 1) };

    float s = sin(frame.time);
    float c = cos(frame.time);
    float2 p = positions[vid];

    VertexOut out;
    out.position = float4(p.x * c - p.y * s, p.x * s + p.y * c, 0.5, 1.0);
    out.color = colors[vid];
    return out;
}

fragment float4 triangle_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
