#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut triangle_vertex(
    uint vid [[vertex_id]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant DrawUniforms  &draw  [[buffer(BufferIndexDrawUniforms)]])
{
    const float3 positions[3] = {
        float3( 0.0,  0.8, 0.0),
        float3(-0.8, -0.6, 0.0),
        float3( 0.8, -0.6, 0.0)
    };
    const float3 colors[3] = {
        float3(1.0, 0.35, 0.45),
        float3(0.35, 1.0, 0.55),
        float3(0.45, 0.55, 1.0)
    };

    VertexOut out;
    out.position = frame.viewProjection * draw.model * float4(positions[vid], 1.0);
    out.color = colors[vid];
    return out;
}

fragment float4 triangle_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
