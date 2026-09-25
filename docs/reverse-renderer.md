# Unity import and renderer contract

The native renderer remains Swift + Metal. Its math uses column vectors, `T * R * S`,
right-handed Y-up world space, and a camera looking down view-space -Z. Projection
uses Metal depth [0, 1] with reverse Z. Existing glTF files already use a right-handed
basis and must not pass through the Unity conversion again.

## Raw Unity boundary

`Packages/Engine/Sources/CoreMath/UnityCoordinates.swift` defines the explicit basis
change `C = diag(1, 1, -1, 1)`. These basis-change operations convert in either
direction; the separate Euler helper constructs a native quaternion.

| Source data | Conversion |
| --- | --- |
| Position, direction, velocity, position morph delta | `(x, y, -z)` |
| Normal, normal morph delta | `(x, y, -z)`; preserve magnitude |
| Tangent XYZW | `(x, y, -z, -w)` when UVs are unchanged |
| Quaternion XYZW | `(-x, -y, z, w)` |
| Local/world transform, inverse bind matrix | `C * M * C` |
| Scale | Unchanged, including negative components |
| Triangle indices | `(i0, i2, i1)` for each source triangle |
| Angular velocity or other axial vector | `(-x, -y, z)` |
| Units | Unchanged; no inferred centimeters/meters correction |

Convert every local transform and every inverse bind matrix, not just mesh
positions. This makes hierarchy composition, skin matrices, and morph application
commute with the basis change. Matrix conversion preserves signed scale and shear;
it must not decompose matrices into unsigned scale lengths.

`eulerDegrees` follows Unity's Z, then X, then Y rotation order and returns a native
quaternion. The engine's existing `eulerXYZ` initializer uses a different order.
The recovered Studio `GuideObject` uses `Quaternion.Euler` for its serialized
`ChangeAmount` rotations. Unity documents the order in its
[2017.4 Quaternion.Euler API](https://docs.unity3d.com/2017.4/Documentation/ScriptReference/Quaternion.Euler.html).

This reflection maps Unity +Z to native -Z. It does not turn a source character to
face the current generated asset convention (+Z). Any presentation adjustment must
be an explicit root rotation, shared by mesh, rig, lights and scene placement as
appropriate. Do not hide a second reflection inside camera or glTF loading code.

The matrix function converts geometric transforms only. Reconstruct the camera
projection with `Projection`; copying Unity clip-space matrices would also require
accounting for Unity's platform-dependent depth and render-target conventions.

## UVs, textures, and tangent frames

Coordinate reflection alone does not require changing UVs or image pixels. Both
Unity and glTF reconstruct the bitangent as `cross(N, T) * tangent.w`; the sign
change above preserves that vector under reflection. See
[Unity Mesh.tangents](https://docs.unity3d.com/2017.4/Documentation/ScriptReference/Mesh-tangents.html)
and the [glTF mesh specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes).

An exporter that independently flips `v` must account for this second change of
tangent basis: the bitangent direction reverses again. To keep a standard UV-derived
tangent frame, flip tangent W again and invert the unpacked normal-map Y component.
Image row order and GPU normal-map packing are separate questions. Verify them
with an asymmetric checker and a known tangent-space normal; do not apply a generic
green-channel flip to an unexamined Unity platform texture. Normal morph deltas
are not unit normals and must never be normalized individually.

## Shader evidence and current mapping

The selected original studio chair (`p_koi_stu_isu01_00`) uses material
`m_koi_stu_isu01_00` and shader `Shader Forge/main_StandardMDK_studio`. The local
extraction at `.local/reverse/chair-material.json` establishes the following
serialized inputs; these are observed material values, not a recovered shader
implementation.

| Observed input | Native status |
| --- | --- |
| `_MainTex`, `_Color = (1,1,1,1)` | Base texture/factor can map to the native base inputs |
| `_BumpMap`, `_BumpScale = 0.37` | Normal input exists; original packing and scale require explicit conversion |
| `_MetallicGlossMap`, `_GlossMapScale = 0.681`, `_Glossiness = 0.5` | No equivalent metallic/gloss texture path in the current toon shader |
| `_EmissionMap`, `_EmissionColor = (0,0,0,1)` | Constant native emissive exists; source emissive texture logic is not implemented |
| `_Mode = 0`, `_CutoutClip = 1` | Inert saved values for this shader: neither is a declared property/binding; both verified FORWARD variants clip using `_Cutoff` |
| `_SrcBlend = 1`, `_DstBlend = 0`, `_ZWrite = 1` | Material values agree with opaque blending/depth writes; alpha testing still occurs before output |
| `_LightCancel = 0.5` | No verified native equivalent |

Original CG/HLSL source has not been recovered. Serialized ShaderLab properties
and platform bytecode do not establish the original source, macro expansions or
lighting equations. The existing `Toon.metal` is an authored approximation, not
a faithful translation of this shader. A future translation can map object-to-clip
to `frame.viewProjection * draw.model`, object-to-world to `draw.model`, the normal
transform to `draw.normalMatrix`, and camera position to `frame.cameraPosition`.
Lighting, texture packing, outline passes, render queue and keyword variants still
require shader-specific evidence and reference captures.

### Verified chair shader bytecode

The selected Shader object is path ID `-5772180542988040361` in
`abdata/studio/mat/00.unity3d`, bundle SHA-256
`f14c91eefaad4d4e20b466dfd1b2c90e9f6794391ba2c8e69bc2f690e3afdcf7`.
The serialized asset reports Unity version tuple `(5, 6, 2, 1)` and contains
`m_ParsedForm` plus a compressed program blob. There is **no `m_Script` field**.
Its single retained platform is D3D11 (platform ID 4); there is no retained Metal
or GLSL program. Decompression expands 9,922 bytes to 117,516 bytes.

The shader has one subshader and four passes. The counts below are serialized
stage references, not a count of original source shader permutations:

| Pass | Vertex references | Pixel references |
| --- | ---: | ---: |
| `FORWARD` | 4 | 2 |
| `FORWARD_DELTA` | 13 | 13 |
| `SHADOWCASTER` | 2 | 2 |
| `META` | 2 | 2 |

The 40 references resolve to 38 unique compiled program entries: 19 vertex
programs and 19 pixel programs, all shader model 4.0. Each contains DXBC after
a six-byte Unity prefix. Geometry, hull and domain stages are empty; no pass
declares an instancing variant. Observed keyword variants include directional,
point and spot lights, cookie lights, vertex lights, and screen/depth/cube/soft
shadows. Subshader tags are `QUEUE=AlphaTest`, `RenderType=TransparentCutout`.

The DIRECTIONAL `FORWARD` pixel entry, blob index 4, was inspected with Microsoft's
`D3DDisassemble` API in the existing Windows VM. Its 2,928-byte DXBC container has
`ISGN`, `OSGN`, and `SHDR` chunks. This disassembly establishes the alpha contract
without guessing from tags or a saved material mode:

- The serialized bindings identify `_MainTex` as `t2/s0`, and `_Cutoff` as
  byte offset 256 in constant buffer 0 (`cb0[16].x`).
- The program samples the main texture, subtracts `_Cutoff` from its alpha,
  tests for a negative value, and executes `discard_nz`. Equality survives.
- `_Color.rgb` multiplies sampled RGB separately; `_Color.a` does not participate
  in this alpha test. Surviving fragments output alpha 1.
- `_Mode` and `_CutoutClip` are saved material properties but absent from this
  shader's property/binding lists. They must not override the observed clip path.

The second and only other FORWARD pixel variant (blob index 5, keywords
`DIRECTIONAL SHADOWS_SCREEN`) was then disassembled independently. It uses the
same comparison, discard and constant output alpha, with `_MainTex` at `t2/s1`
instead of `t2/s0`. Both variants share the FORWARD pass's static Cull Back state
(serialized value 2, no named material override). Exact per-variant bindings,
assembly hashes and the bounded export contract are recorded in
`.local/reverse/shaders/chair-alpha-evidence.json`.

For this shader and the observed chair material, the appropriate converted alpha
contract is MASK with cutoff 0.5, base-factor alpha 1, and single-sided rendering.
The main UV is displaced by a sampled parallax
map before alpha sampling, so source and native silhouettes can still diverge
if parallax is later enabled. This finding covers both FORWARD pixel variants;
the other passes have not been disassembled or compared visually.

The same selected program reads the normal texture's **alpha and green** channels,
maps them to signed XY and scales them by `_BumpScale` (`cb0[9].y`). It combines
those offsets with the interpolated tangent frame and normal, then normalizes;
the native RGB normal sampling is therefore not a faithful decoder for this raw
platform texture. This is direct bytecode evidence, not a proposed shader rewrite.

Local inspection outputs live in `.local/reverse/shaders/`: `chair-summary.json`
contains pass/variant/binding metadata and hashes; `chair-shader-tree.json` retains
the serialized form; `chair-d3d11-subprograms.bin` preserves the decompressed
blob; `chair-forward-fragment-4.dxbc` / `.asm` and the corresponding `-5` files
preserve both inspected FORWARD programs.
`chair-reconstructed-not-source.shader.txt` is UnityPy's generated ShaderLab-like
outline. It explicitly identifies itself as invalid shader source and substitutes
unsupported-DXBC comments for program bodies. It must not be treated as recovered
CG/HLSL ready for mechanical Metal translation.

## Correctness fixes in this revision

The toon vertex shader transforms tangents using the model's linear matrix rather
than its inverse transpose. It adjusts tangent handedness for mirrored instances,
then orthogonalizes the interpolated tangent against the normal in the fragment
shader. A degenerate tangent gets a stable perpendicular fallback.
The fragment shader now uses the decoded RGB normal vector at its authored
strength; an extra factor of 0.5 on tangent X/Y was removed so it does not halve
the source bump scale already baked by the verified A/G texture conversion.

Material construction now shares the imported alpha mode, alpha cutoff and
double-sided contract across categories. Hair BLEND remains blended; cloth BLEND
and accessory MASK are no longer dropped. Source normal textures are loaded as
linear data for each category that uses the toon shader. Catalog iris and lash
textures keep their explicit pigment/cutout behavior. A separate blended eye
pipeline preserves the eye fragment path for transparent source eye materials.
OPAQUE and accepted MASK fragments output full coverage alpha.

### Deformation safety

The renderer uploads complete skin palettes to retained per-frame Metal buffers;
the previous silent 256-matrix truncation is removed. The palette size is supplied
explicitly in `DeformParams.boneCount`. A mesh records the largest referenced joint
across **all four lanes**, including zero-weight lanes, and checks it against each
bound palette before dispatch. Missing referenced palettes, nonfinite matrices,
and undersized palettes appear in `Renderer.lastDeformationErrors`; interactive
rendering skips the affected draw and offscreen capture fails. A mesh intentionally
drawn with no skin binding retains the existing rigid/rest-geometry convention.

GPU registration rejects mismatched influence counts, nonfinite/negative weights,
and zero-total weights. Valid positive totals are normalized in Double before
upload, preserving their proportions and accepting quantized source weights whose
sum differs slightly from one. The compute kernel independently checks every
joint and weight before reading the palette; an invalid influence retains the
pre-skin morph result. This does not validate source-to-runtime bone identity:
the caller still owns each skin's exact joint order and inverse bind matrices.

Skinned normals use the inverse transpose of the **blended** linear skin matrix.
Tangents use its linear matrix and multiply their handedness by its determinant
sign. Cofactors are computed after scaling the matrix by its largest absolute
component, avoiding magnitude-dependent determinant overflow. If the normalized
determinant has magnitude at most `1e-8`, the normal and handedness retain their
pre-skin values because a unique transformed normal is unavailable. Position and
usable tangent transforms still apply, allowing intentional zero-scale geometry;
nonfinite transformed positions retain their pre-skin position.

## Verification and remaining limits

`swift test --package-path Packages/Engine --filter 'unity|imported'` exercises
coordinate round trips, quaternion action, Unity Euler order, tangent frames,
triangle normals, parent/child composition with signed scale and shear, inverse
bind matrices, morph deformation, axial vectors, and material alpha/culling
metadata. `xcrun -sdk macosx metal -I Packages/Engine/Sources/ShaderTypes/include
-c Shaders/Toon.metal -o /tmp/ikkoku-modeler-toon.air` checks the shader compiler.

These checks establish the conversion contract, not visual parity with the game.
`swift test --package-path Packages/Engine --filter 'skinInfluences|skinPalette|deformKernel'`
checks registration and palette failures and executes the real Metal compute
kernel with GPU readback for a joint above index 255, nonuniform scaling,
reflections, singular matrices, invalid zero-weight lanes, and invalid weights.
GPU tests are explicitly disabled when no Metal device is available.

Remaining renderer limitations include missing tangent morph targets, fallback tangents for
assets lacking TANGENT, and custom toon lighting that does not implement the
chair's metallic/gloss shader. Bone names, joint remapping, per-mesh inverse bind
matrices and source animation evaluation need full character fixtures before
claiming character or CharaStudio parity.
