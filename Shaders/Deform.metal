#include "Common.h"

// Morph targets + linear-blend skinning → DeformedVertex buffer.
kernel void deform_vertices(
    uint vid [[thread_position_in_grid]],
    device const DeformedVertex*  base      [[buffer(BufferIndexBaseVertices)]],
    device DeformedVertex*        out       [[buffer(BufferIndexVertices)]],
    device const SkinVertex*      skin      [[buffer(BufferIndexSkinData)]],
    device const float4x4*        bones     [[buffer(BufferIndexSkinMatrices)]],
    device const MorphWeightEntry* morphs   [[buffer(BufferIndexMorphWeights)]],
    device const packed_float3*   deltas    [[buffer(BufferIndexMorphDeltas)]],
    device const packed_float3*   nDeltas   [[buffer(BufferIndexMorphNormals)]],
    constant DeformParams&        params    [[buffer(BufferIndexDeformParams)]])
{
    if (vid >= params.vertexCount) return;
    DeformedVertex v = base[vid];
    float3 p = v.position.xyz;
    float3 n = v.normal.xyz;
    float3 t = v.tangent.xyz;

    for (uint i = 0; i < params.activeMorphCount; ++i) {
        MorphWeightEntry e = morphs[i];
        uint idx = e.index * params.vertexCount + vid;
        p += float3(deltas[idx]) * e.weight;
        if (params.hasMorphNormals) n += float3(nDeltas[idx]) * e.weight;
    }
    n = normalize(n);

    if (params.hasSkin) {
        SkinVertex s = skin[vid];
        float4x4 m = bones[s.joints.x] * s.weights.x
                   + bones[s.joints.y] * s.weights.y
                   + bones[s.joints.z] * s.weights.z
                   + bones[s.joints.w] * s.weights.w;
        p = (m * float4(p, 1.0)).xyz;
        float3x3 m3 = float3x3(m[0].xyz, m[1].xyz, m[2].xyz);
        n = normalize(m3 * n);
        t = normalize(m3 * t);
    }
    out[vid].position = float4(p, v.position.w);
    out[vid].normal = float4(n, v.normal.w);
    out[vid].tangent = float4(t, v.tangent.w);
}
