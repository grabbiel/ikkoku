// ShaderTypes.h — shared by C, Swift's importer and the Metal compiler.
// Keep it free of Foundation / Objective-C. Every GPU-visible struct is
// declared here so Swift and Metal agree on layout.
#ifndef ShaderTypes_h
#define ShaderTypes_h

#define IK_ENUM(_type, _name) enum _name : _type _name; enum _name : _type

#ifdef __METAL_VERSION__
typedef metal::int32_t EnumBackingType;
typedef metal::uint32_t IKUInt;
#else
#include <stdint.h>
typedef int32_t EnumBackingType;
typedef uint32_t IKUInt;
#endif

#include <simd/simd.h>

// MARK: - Limits
#define IK_MAX_LIGHTS        8
#define IK_MAX_ACTIVE_MORPHS 64
#define IK_MAX_BONES         256

// MARK: - Buffer bind points
typedef IK_ENUM(EnumBackingType, BufferIndex) {
    BufferIndexFrameUniforms  = 0,
    BufferIndexDrawUniforms   = 1,
    BufferIndexVertices       = 2,   // DeformedVertex[]  (skinned / static)
    BufferIndexMaterial       = 3,   // MaterialUniforms
    BufferIndexLights         = 4,   // LightsUniforms
    BufferIndexSkinMatrices   = 5,   // matrix_float4x4[] (compute)
    BufferIndexMorphWeights   = 6,   // MorphWeightEntry[] (compute)
    BufferIndexMorphDeltas    = 7,   // PackedFloat3[targets*verts] (compute)
    BufferIndexBaseVertices   = 8,   // DeformedVertex[] rest pose (compute)
    BufferIndexSkinData       = 9,   // SkinVertex[] (compute)
    BufferIndexDeformParams   = 10,  // DeformParams (compute)
    BufferIndexTexcoords      = 11,  // vector_float2[]
    BufferIndexVertexColors   = 12,  // vector_uchar4[] (optional)
    BufferIndexPostParams     = 13,  // PostParams
    BufferIndexGizmoVertices  = 14,  // GizmoVertex[]
    BufferIndexMorphNormals   = 15,  // PackedFloat3[targets*verts] (optional)
    BufferIndexVertexHidden   = 16,  // uchar[] per vertex (1 = hidden), when DrawFlagHasHiddenBuffer
};

// MARK: - Texture bind points
typedef IK_ENUM(EnumBackingType, TextureIndex) {
    TextureIndexBase       = 0,
    TextureIndexColorMask  = 1,
    TextureIndexDetail     = 2,
    TextureIndexLine       = 3,
    TextureIndexNormal     = 4,
    TextureIndexOverlay0   = 5,
    TextureIndexOverlay1   = 6,
    TextureIndexOverlay2   = 7,
    TextureIndexShadowMap  = 8,
    TextureIndexRamp       = 9,
    TextureIndexHairGloss  = 10,
    TextureIndexPattern    = 11,
    TextureIndexSceneColor = 12,
    TextureIndexBloom      = 13,
    TextureIndexSceneDepth = 14,
    TextureIndexBodyMask   = 15,
};

// MARK: - Material kinds / flags
typedef IK_ENUM(EnumBackingType, MaterialKind) {
    MaterialKindItem    = 0,  // generic toon
    MaterialKindSkin    = 1,
    MaterialKindHair    = 2,
    MaterialKindCloth   = 3,
    MaterialKindEye     = 4,
    MaterialKindEyeWhite= 5,
    MaterialKindUnlit   = 6,
    MaterialKindEyelash = 7,  // alpha-tested strips drawn over hair
};

typedef IK_ENUM(IKUInt, MaterialFlags) {
    MaterialFlagHasBaseTexture  = 1u << 0,
    MaterialFlagHasColorMask    = 1u << 1,
    MaterialFlagHasDetail       = 1u << 2,
    MaterialFlagHasLine         = 1u << 3,
    MaterialFlagHasNormal       = 1u << 4,
    MaterialFlagAlphaTest       = 1u << 5,
    MaterialFlagAlphaBlend      = 1u << 6,
    MaterialFlagHasOverlay0     = 1u << 7,
    MaterialFlagHasOverlay1     = 1u << 8,
    MaterialFlagHasOverlay2     = 1u << 9,
    MaterialFlagHasPattern      = 1u << 10,
    MaterialFlagNoOutline       = 1u << 11,
    MaterialFlagStrandUV        = 1u << 12,
    MaterialFlagDoubleSided     = 1u << 13,
    MaterialFlagReceiveShadow   = 1u << 14,
    MaterialFlagHasVertexColor  = 1u << 15,
    MaterialFlagHasBodyMask     = 1u << 16,
};

#define DrawFlagHasHiddenBuffer 0x80000000u

// MARK: - Vertex formats
typedef struct { float x, y, z; } PackedFloat3;

/// Output of the deform pass and the format every draw pass reads.
typedef struct {
    vector_float4 position;   // xyz object space, w = region id (0 = none)
    vector_float4 normal;     // xyz, w = outline width multiplier (0..1)
    vector_float4 tangent;    // xyz, w = handedness
} DeformedVertex;

typedef struct {
    vector_ushort4 joints;
    vector_float4  weights;
} SkinVertex;

typedef struct {
    IKUInt index;      // morph target index
    float  weight;
} MorphWeightEntry;

typedef struct {
    IKUInt vertexCount;
    IKUInt activeMorphCount;
    IKUInt hasSkin;           // 0/1
    IKUInt hasMorphNormals;   // 0/1
} DeformParams;

typedef struct {
    vector_float3 position;
    vector_float4 color;
} GizmoVertex;

// MARK: - Uniforms
typedef struct {
    matrix_float4x4 viewProjection;
    matrix_float4x4 view;
    matrix_float4x4 projection;
    matrix_float4x4 inverseView;
    matrix_float4x4 inverseViewProjection;
    matrix_float4x4 shadowViewProjection;   // clip space of the shadow map
    vector_float4   cameraPosition;         // xyz world, w = 1
    vector_float4   viewport;               // width, height, 1/width, 1/height
    vector_float4   mainLightDirection;     // xyz = direction TO the light (world), w = shadow strength
    vector_float4   mainLightColor;         // rgb * intensity
    vector_float4   ambientSky;             // rgb from above
    vector_float4   ambientGround;          // rgb from below
    vector_float4   shadowParams;           // texel size, bias, normal bias, pcf radius
    vector_float4   fogColor;               // rgb, a = density
    vector_float4   fogRange;               // start, end, unused, unused
    vector_float4   outlineParams;          // global width scale, min px, max px, depth fade
    float           time;
    float           nearPlane;
    float           exposure;
    float           _pad0;
} FrameUniforms;

typedef struct {
    matrix_float4x4 model;
    matrix_float4x4 normalMatrix;   // upper 3x3 used; 4x4 for alignment
    IKUInt          objectID;
    IKUInt          flags;          // bitmask of hidden body regions (1 << region)
    float           outlineScale;
    float           depthBias;      // metres toward the camera (eyebrows over hair)
} DrawUniforms;

typedef struct {
    vector_float4 baseColor;      // rgba tint (multiplies texture)
    vector_float4 shadowColor;    // rgb multiplier on the dark side, a = shade threshold
    vector_float4 specular;       // rgb color, a = power (glossiness)
    vector_float4 rim;            // rgb color, a = power
    vector_float4 outline;        // rgb color, a = width (world units at 1m)
    vector_float4 tint1;          // ColorMask R zone
    vector_float4 tint2;          // ColorMask G zone
    vector_float4 tint3;          // ColorMask B zone
    vector_float4 overlayColor0;  // multiplies overlay alpha mask (blush etc.)
    vector_float4 overlayColor1;
    vector_float4 overlayColor2;
    vector_float4 patternColor;   // rgb, a = pattern strength
    vector_float4 hairGloss;      // x = strength, y = width, z = shift (v along strand), w = secondary
    vector_float4 params;         // x = shade softness, y = specular strength, z = rim light mask, w = alpha cutoff
    vector_float4 eye;            // x = iris scale, y = iris offset u, z = iris offset v, w = highlight strength
    vector_float4 emissive;       // rgb, a = strength
    vector_float4 uvTransform;    // scale u, scale v, offset u, offset v (pattern)
    IKUInt        kind;           // MaterialKind
    IKUInt        flags;          // MaterialFlags
    float         _pad0;
    float         _pad1;
} MaterialUniforms;

typedef IK_ENUM(EnumBackingType, LightType) {
    LightTypeDirectional = 0,
    LightTypePoint       = 1,
    LightTypeSpot        = 2,
};

typedef struct {
    vector_float4 position;    // xyz world, w = type
    vector_float4 direction;   // xyz (spot/directional), w = range
    vector_float4 color;       // rgb * intensity, a = spot cos(outer)
    vector_float4 params;      // x = spot cos(inner), y = enabled, z/w unused
} LightUniform;

typedef struct {
    LightUniform lights[IK_MAX_LIGHTS];
    IKUInt count;
    IKUInt _pad0, _pad1, _pad2;
} LightsUniforms;

typedef struct {
    vector_float4 bloom;        // threshold, intensity, radius, unused
    vector_float4 vignette;     // intensity, smoothness, roundness, unused
    vector_float4 grade;        // exposure, contrast, saturation, temperature
    vector_float4 texel;        // 1/width, 1/height, width, height
    IKUInt        flags;        // 1 = fxaa, 2 = bloom, 4 = vignette, 8 = grade
    IKUInt        _pad0, _pad1, _pad2;
} PostParams;

#endif /* ShaderTypes_h */
