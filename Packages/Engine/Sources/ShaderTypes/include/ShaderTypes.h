// swift-tools-version note: this header is compiled by C, Swift's importer,
// and the Metal compiler. Keep it free of Foundation and Objective-C.
#ifndef ShaderTypes_h
#define ShaderTypes_h

#define IK_ENUM(_type, _name) enum _name : _type _name; enum _name : _type

#ifdef __METAL_VERSION__
typedef metal::int32_t EnumBackingType;
#else
#include <stdint.h>
typedef int32_t EnumBackingType;
#endif

#include <simd/simd.h>

typedef IK_ENUM(EnumBackingType, BufferIndex) {
    BufferIndexFrameUniforms = 0,
    BufferIndexDrawUniforms  = 1,
    BufferIndexVertices      = 2,
};

typedef IK_ENUM(EnumBackingType, VertexAttribute) {
    VertexAttributePosition = 0,
    VertexAttributeNormal   = 1,
    VertexAttributeTexcoord = 2,
};

typedef struct {
    matrix_float4x4 viewProjection;
    matrix_float4x4 inverseView;
    vector_float3   cameraPosition;
    float           time;
} FrameUniforms;

typedef struct {
    matrix_float4x4 model;
    matrix_float3x3 normalMatrix;
} DrawUniforms;

#endif /* ShaderTypes_h */
