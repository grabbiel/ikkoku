#include "Common.h"

struct LineOut { float4 position [[position]]; float4 color; };

vertex LineOut gizmo_vertex(uint vid [[vertex_id]],
                            device const GizmoVertex* verts [[buffer(BufferIndexGizmoVertices)]],
                            constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
                            constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]])
{
    LineOut o;
    GizmoVertex v = verts[vid];
    o.position = frame.viewProjection * draw.model * float4(v.position, 1.0);
    o.color = v.color;
    return o;
}

fragment float4 gizmo_fragment(LineOut in [[stage_in]]) { return in.color; }

// Infinite grid on the y = 0 plane, rendered as a large quad with analytic lines.
struct GridOut { float4 position [[position]]; float3 world; };

vertex GridOut grid_vertex(uint vid [[vertex_id]],
                           constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]])
{
    const float s = 60.0;
    float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1) };
    float2 c = corners[vid] * s;
    float3 center = float3(frame.cameraPosition.x, 0.0, frame.cameraPosition.z);
    float3 w = center + float3(c.x, 0.0, c.y);
    GridOut o;
    o.world = w;
    o.position = frame.viewProjection * float4(w, 1.0);
    return o;
}

fragment float4 grid_fragment(GridOut in [[stage_in]],
                              constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]])
{
    float2 p = in.world.xz;
    float2 g1 = abs(fract(p - 0.5) - 0.5) / fwidth(p);
    float2 g2 = abs(fract(p * 0.1 - 0.5) - 0.5) / fwidth(p * 0.1);
    float l1 = 1.0 - min(min(g1.x, g1.y), 1.0);
    float l2 = 1.0 - min(min(g2.x, g2.y), 1.0);
    float dist = length(frame.cameraPosition.xyz - in.world);
    float fade = saturate(1.0 - dist / 25.0);
    float a = max(l1 * 0.35, l2 * 0.7) * fade;
    float3 col = float3(0.55, 0.58, 0.64);
    float2 ax = abs(p) / fwidth(p);
    if (ax.x < 1.0) { col = float3(0.35, 0.45, 0.95); a = max(a, (1.0 - ax.x) * fade); }
    if (ax.y < 1.0) { col = float3(0.95, 0.35, 0.4); a = max(a, (1.0 - ax.y) * fade); }
    return float4(col, a);
}

// Picking: writes object id.
struct PickOut { float4 position [[position]]; };

vertex PickOut pick_vertex(uint vid [[vertex_id]],
                           device const DeformedVertex* verts [[buffer(BufferIndexVertices)]],
                           constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
                           constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]])
{
    PickOut o;
    o.position = frame.viewProjection * draw.model * float4(verts[vid].position.xyz, 1.0);
    return o;
}

fragment uint pick_fragment(PickOut in [[stage_in]], constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]]) {
    return draw.objectID;
}

// Gizmo picking uses the same id path with gizmo vertex input.
struct PickGizmoOut { float4 position [[position]]; };
vertex PickGizmoOut pick_gizmo_vertex(uint vid [[vertex_id]],
                                      device const GizmoVertex* verts [[buffer(BufferIndexGizmoVertices)]],
                                      constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
                                      constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]])
{
    PickGizmoOut o;
    o.position = frame.viewProjection * draw.model * float4(verts[vid].position, 1.0);
    return o;
}
fragment uint pick_gizmo_fragment(PickGizmoOut in [[stage_in]], constant DrawUniforms& draw [[buffer(BufferIndexDrawUniforms)]]) {
    return draw.objectID;
}
