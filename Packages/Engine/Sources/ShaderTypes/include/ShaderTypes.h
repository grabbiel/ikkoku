//
//  ShaderTypes.h
//  IkkokuCreator
//
//  Created by rumpology on 8/18/26.
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex) {
    BufferIndexFrameUniforms = 0,
    BufferIndexDrawUniforms  = 1,
    BufferIndexVertices      = 2,
};

typedef NS_ENUM(EnumBackingType, VertexAttribute) {
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
