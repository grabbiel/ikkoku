#include "Common.h"

// Scale before taking a length so finite large/small vectors remain usable.
static float3 deform_unit(float3 value, float3 fallback) {
    float scale = max(max(abs(value.x), abs(value.y)), abs(value.z));
    if (!all(isfinite(value)) || !(scale > 0.0f)) return fallback;
    float3 scaled = value / scale;
    return scaled * rsqrt(dot(scaled, scaled));
}

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
    float handedness = v.tangent.w;

    for (uint i = 0; i < params.activeMorphCount; ++i) {
        MorphWeightEntry e = morphs[i];
        uint idx = e.index * params.vertexCount + vid;
        p += float3(deltas[idx]) * e.weight;
        if (params.hasMorphNormals) n += float3(nDeltas[idx]) * e.weight;
    }
    n = deform_unit(n, float3(0.0f, 1.0f, 0.0f));
    t = deform_unit(t, float3(1.0f, 0.0f, 0.0f));

    if (params.hasSkin) {
        SkinVertex s = skin[vid];
        // Check every lane before any palette read, including zero-weight lanes.
        // Invalid input retains the morph result rather than reading outside bones.
        float largestWeight = max(max(s.weights.x, s.weights.y), max(s.weights.z, s.weights.w));
        if (all(uint4(s.joints) < params.boneCount) && all(isfinite(s.weights))
            && all(s.weights >= 0.0f) && largestWeight > 0.0f) {
            float4 w = s.weights / largestWeight;
            w /= dot(w, float4(1.0f));
            float4x4 m = bones[s.joints.x] * w.x
                       + bones[s.joints.y] * w.y
                       + bones[s.joints.z] * w.z
                       + bones[s.joints.w] * w.w;
            float3 transformedPosition = (m * float4(p, 1.0)).xyz;
            if (all(isfinite(transformedPosition))) p = transformedPosition;
            float3x3 m3 = float3x3(m[0].xyz, m[1].xyz, m[2].xyz);
            float3 columnMax = max(max(abs(m3[0]), abs(m3[1])), abs(m3[2]));
            float scale = max(max(columnMax.x, columnMax.y), columnMax.z);
            if (all(isfinite(m3[0])) && all(isfinite(m3[1])) && all(isfinite(m3[2])) && scale > 0.0f) {
                float3x3 a = m3 / scale;
                float3x3 cofactors = float3x3(cross(a[1], a[2]), cross(a[2], a[0]), cross(a[0], a[1]));
                float det = dot(a[0], cofactors[0]);
                // Inverse transpose = cofactor / determinant. Its magnitude is
                // discarded by normalization; retaining the sign preserves reflections.
                // For singular/ill-conditioned matrices no unique normal exists:
                // retain the normalized pre-skin normal and tangent handedness.
                if (abs(det) > 1.0e-8f) {
                    float sign = det < 0.0f ? -1.0f : 1.0f;
                    n = deform_unit((cofactors * n) * sign, n);
                    handedness *= sign;
                }
                t = deform_unit(a * t, t);
            }
        }
    }
    out[vid].position = float4(p, v.position.w);
    out[vid].normal = float4(n, v.normal.w);
    out[vid].tangent = float4(t, handedness);
}
