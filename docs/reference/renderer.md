# Unity import and renderer contract

Reviewed 2026-09-25. See the [renderer audit](../component-audit/renderer-and-foundation.md)
for feature status, code findings and tasks R1–R8. Commands run from the repository
root. This reference separates production rendering from source-frame diagnostics.

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

## Historical chair shader evidence and production mapping

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

For this chair shader, original CG/HLSL source has not been recovered. Serialized ShaderLab properties
and platform bytecode do not establish the original source, macro expansions or
lighting equations. The existing `Toon.metal` is an authored approximation, not
a faithful translation of this shader. A production integration can map object-to-clip
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

## Production deformation and material contracts

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
chair's metallic/gloss shader. Source character fixtures now exercise joint
remapping, per-mesh inverse binds
and selected animation states; those checks do not establish complete character
or Studio rendering parity. The broader asset/runtime limits remain in R3–R7.

## Source shader translation and matched frames

`Tools/reverse/source_shader_translation.py` translates the observed DXBC subset
to MSL for `TranslatedSourceShaderProbe`. Eight character shader families have
13 recorded forward/outline vertex-fragment pairs, including five outlines.
The diagnostic consumes original-player baked geometry, camera/material/light
state and captured textures. It compiles translated programs per job. Production
`Renderer` still selects authored native toon/eye/outline materials; there is no
live source-program registry integration.

Comparing a frozen original character frame (controls in the commands below;
re-run against current code on 2026-09-26 into `.local/r1b/probe`, starting
from the original captures `.local/reverse/original-character-probe/{frame.json,frame-mips.json}`;
both frame variants reference the same source capture, SHA-256
`13bd11c2805ac99172dc7ce7539c3cb98f06edcb858af4a1136ce3570b66f039`):

| Compared path | Silhouette IoU | Color error (0–255) | Result and scope |
| --- | ---: | --- | --- |
| Geometry diagnostic | 0.9998196 | Not a color gate | 18 differing silhouette pixels; depth p99 0 m, normals 0 bytes; passes frozen geometry |
| Production native toon | See geometry diagnostic | Mean 31.2763; p99 239 | Fails source color parity |
| Translated garments | 0.9995455 | Mean 0.1169; p99 2 | Passes selected garment color gate |
| Translated full character (reference run `frame-mips.json`; identical on `frame.json`) | 0.9988685 | Mean 0.2087; p99 4 | Fails full-character silhouette gate (112 differing pixels); color gate passes |

The earlier documentation quoted mean 26.9362/p99 242 (older capture) and
mean 0.2267/p99 5 (previous code) for the full character. Current code
reduces the color residual below the p99 ≤4 gate on both frame variants; the
remaining residual is geometric — thin hair/outline edges — and concentrates
in the hair families (attribution below).

Per-family attribution — each family rendered alone, compared only where it
is front-most in both renders (`IKKOKU_ORIGINAL_FRAME_FAMILIES=1`):

| Family | Pixels | Mean | p99 | Result |
| --- | ---: | ---: | ---: | --- |
| main_opaque | 76709 | 0.117 | 2 | Passes color gate |
| main_skin | 13515 | 0.202 | 1 | Passes color gate |
| main_hair | 3528 | 0.998 | 24 | Fails p99 gate; thin hair edges |
| main_hair_front | 6181 | 0.844 | 22 | Fails p99 gate; thin hair edges |
| toon_eye_lod0 | 368 | 0.010 | 0 | Passes color gate |
| toon_eyew_lod0 | 303 | 0.002 | 0 | Passes color gate |
| toon_nose_lod0 / main_item | 0 | — | — | Never front-most in the frozen frame |

Whole-character silhouette attribution (`translatedSilhouette`): 61 pixels
are opaque only in the full translated render — attributed to main_hair
alone (30), hair/outline overlap (23), main_opaque (4), main_hair_front (3)
and main_skin (1) — and 51 pixels are opaque only in the original capture —
attributed to main_skin (31), none (11), overlap (2) and main_hair (7). Up
to 20 sample coordinates per class are recorded in
`<probe folder>/frame-comparison.json`.

A pixel counts as front-most only where the full translated render and the family-only render have identical RGB, so blended/translucent overlaps are excluded from per-family metrics.

Reproduction: build with `xcodebuild -project Ikkoku.xcodeproj -scheme
IkkokuCreator -configuration Debug -derivedDataPath .local/build
-destination 'platform=macOS,arch=arm64' build`; run
`IKKOKU_ORIGINAL_FRAME_PROBE=$PWD/.local/r1b/probe/frame-mips.json
IKKOKU_ORIGINAL_FRAME_FAMILIES=1
.local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku`;
compare with `Tools/reverse/compare_original_frame.py .local/r1b/probe`.
Swap `frame.json` for `frame-mips.json` to reproduce the original capture
variant. These are frozen-evaluated-geometry diagnostics, not
live-renderer parity.

The silhouette gate is IoU ≥0.999; the color gate is mean ≤1 and p99 ≤4.
The fixture disables shadows. Original
baked vertices isolate draw-shader behavior and do not verify native animation,
IK, dynamic particles or live scene assembly. Latest captured texture inputs total
55: 37 with generated mips, 18 without mips and zero authored chains in that run.
The authored-mip exporter exists, but its availability does not prove every
comparison used authored source chains. Shader recipes, player probes and exact
reproduction commands are in [material expansion](character/material-expansion.md).

Next: attribute the hair/outline edge residual to a concrete binding or
state difference before any gate relaxation, then integrate verified programs
with production material/queue/pass dispatch. Compare independently loaded
original/native scenes with matched time, camera, lights and effects after
that integration. Orchestrator analysis of the 2026-09-26 authored-mip run
shows the silhouette residual is not a colour or alpha-output problem. At
the hair crown (approximately x 345–423, y 96–116 of the 768x1024 frame),
some pixels with the hair-outline colour (for example RGB 46,23,11) are
covered in the `main_hair`-only render but empty in the full translated
render; neighbouring pixels show the reverse. This points to interactions
between families in the full draw, most likely inter-family depth or stencil
state/order at the hair crown (for example, the stencil that lets eyebrows
and eyelines show through front hair). Next compare the pass states
(`stencilRef`, `stencilReadMask`, `stencilWriteMask`, comparison ops and queue
order) of `main_hair`, `main_hair_front`, `toon_eyew_lod0` and their outlines.
The boundary-pixel classes are now attributed and
re-measured (2026-09-26 re-run on both frame variants: same
`sourceFrameSHA256` 13bd11c2…; 61 native-only / 51 original-only pixels),
but none of the hypotheses yields an explainable fix: no translated program
binds `_ScreenParams`, `_ProjectionParams`, `unity_MatrixV`,
`unity_CameraProjection`, `glstate_matrix_projection` or
`unity_WorldTransformParams` (only `unity_ObjectToWorld`,
`unity_WorldToObject` and `unity_MatrixVP`, bound from computed values per
the conversion tables above), every hair/outline fragment keeps the
`discard`-under-`_Cutoff`/`_alpha_a`-`_alpha_b` semantics unchanged from
the DXBC, and the stored outline pass states map to the same culling
(0→none/1→front/2→back), depth and stencil states the probe already
applies. Track R1/R2 and CMT-04; R1 remains open — per-family isolation and
silhouette-class attribution exist, but the full-character silhouette gate
still fails (112 differing pixels) and no cause has been confirmed for the
hair-edge residual.

## Resource and measurement boundaries

The live renderer supports four skin influences and a single morph frame per
target. More than 64 active morphs can be silently truncated; the light budget is
eight and the uniform ring preconditions on exceeding its 8 MiB region. glTF UV1/2,
initial morph weights and tangent morphs are not fully consumed. There is no
complete LOD, streaming or frustum-culling system. R3/R5/R6 define fixes and checks.

A recorded Release fixture on M2 Ultra at 600×800 rendered 28 items, 60,761 triangles
and 40,490 vertices. CPU pose samples (60) measured p50/p95 4.684/4.964 ms; static
GPU samples (20) measured 0.529/0.537 ms. Encode time was 0.222/0.240 ms and
completion 1.058/1.224 ms. These are separate measurements, not summed frame time.
The fixture had zero attached source DynamicBone components and an unrendered
route. RSS 379,125,760 bytes and Metal allocations 415,907,840 bytes can overlap in
unified memory; do not sum them or infer full-game throughput. See R7 for a
representative displayed-scene benchmark and the full evidence inventory.
