#include "Common.h"

// ---- Instanced static items (ST-T04) ---------------------------------------
// One instanced draw for a run of static item records that share the mesh, the
// textures, the state and the whole MaterialUniforms, byte for byte (only the
// DrawUniforms differ). The run's material is bound once, as for one record.
// The color, outline and shadow passes draw a run through the per-draw
// pipelines themselves: toon_vertex, outline_vertex, shadow_vertex and
// pick_vertex read DrawUniforms at `instance_id` (B0), which includes the
// draw's base instance, so an instance renders exactly as its record does on
// its own. Picking needs the id per instance, hence the pair below: the text
// of pick_vertex plus the instance index, and a fragment that reads the id at
// that index (`instance` is the absolute index into the table).

struct InstancedPickOut { float4 position [[position]]; float2 uv; uint instance [[flat]]; };

vertex InstancedPickOut pick_vertex_instanced(uint vid [[vertex_id]],
                                              uint iid [[instance_id]],
                                              device const DeformedVertex* verts [[buffer(BufferIndexVertices)]],
                                              device const float2* uvs [[buffer(BufferIndexTexcoords)]],
                                              constant FrameUniforms& frame [[buffer(BufferIndexFrameUniforms)]],
                                              constant DrawUniforms* draws [[buffer(BufferIndexDrawUniforms)]])
{
    constant DrawUniforms& draw = draws[iid];
    InstancedPickOut o;
    o.position = frame.viewProjection * draw.model * float4(verts[vid].position.xyz, 1.0);
    o.uv = uvs[vid];
    o.instance = iid;
    return o;
}

fragment uint pick_fragment_instanced(InstancedPickOut in [[stage_in]], constant DrawUniforms* draws [[buffer(BufferIndexDrawUniforms)]],
                                      constant MaterialUniforms& mat [[buffer(BufferIndexMaterial)]],
                                      texture2d<float> bodyMask [[texture(TextureIndexBodyMask)]]) {
    if (bodyMaskDiscards(bodyMask, in.uv, mat)) discard_fragment();
    return draws[in.instance].objectID;
}
