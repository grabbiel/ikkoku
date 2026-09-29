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

### Studio item shader evidence (added 2026-09-29, ST-T04)

The basic-shape Studio props use two Shader Forge shaders:
`Shader Forge/main_item_studio` (pathID 5291980238619603514, bundle SHA256
`1464352c…`) and `Shader Forge/main_item_studio_alpha` (pathID
8750429712876890764, SHA256 `c2efabe2…`). `Tools/reverse/item_shader_contract.py`
reuses `clothed_material_contract.disassemble` to disassemble both FORWARD pixel
variants of each shader (blob indices 8/9 and 4/5, keywords `DIRECTIONAL` and
`DIRECTIONAL SHADOWS_SCREEN`, `_MainTex` at `t1/s0` and `t1/s1`) and writes the
contract evidence. Both shader `m_Script` fields are empty, so no source-level
parity is claimed.

`main_item_studio` (the `cylinder00` family):

- There is no `_Cutoff` binding. The program computes `sat(2·_MainTex.a)` and
  `discard_nz` when it is below 0.5, so the alpha test is the constant
  `_MainTex.a < 0.25`. Saved `_Cutoff`/`_Mode` have no bindings and are inert.
- Surviving fragments output `o0.w = 2·sat(2a) − 1` into a `One/OneMinusSrcAlpha`
  blend: coverage is exactly 1 only for `a >= 0.5`, so glTF MASK is exact only
  when the texture has no texel in `[0.25, 0.5)`; the exporter refuses one.
- The FORWARD pass is statically `Cull Off` (serialized 0, no property
  override), so the converted material is `doubleSided: true`. Export contract:
  MASK, `alphaCutoff: 0.25`, base-factor alpha 1.

`main_item_studio_alpha` (the `cube01` family):

- Output alpha is `_MainTex.a · _alpha` (`cb0[32].z`) into a
  `SrcAlpha/OneMinusSrcAlpha` blend. The `discard_nz` guard at
  `0.001/0.501 ≈ 0.002` is an epsilon guard, not a cutoff; saved
  `_Cutoff`/`_Mode`/`_SrcBlend`/`_DstBlend` are inert (no bindings).
- FORWARD is `Cull Back` (2): single-sided. Export contract: BLEND with
  `baseColorFactor.a` carrying the saved `_alpha`.

Both shaders build albedo as `_MainTex.rgb × lerp(lerp(lerp(1, _Color, mask.r),
_Color2, mask.g), _Color3, mask.b)` from the `_ColorMask` texture. An unbound
`_ColorMask` (shader default black) leaves the tint white; a texel saturating
exactly one channel selects that `_ColorN` group exactly. The exporter refuses
a `_ColorMask` that varies across the image or blends several channels, and any
material with a bound `_PatternMask1..3` slot: the pattern gate is always
sampled, and only an unbound slot (shader default white, gate 1) keeps the base
color independent of the unmapped pattern uv/clamp/rotation transforms. The
FORWARD output RGB is not plain albedo — an HSV remap scaled by `_ShadowColor`,
`_DetailMask`/`_LineMask` detail, `_RampG`/`_AnotherRamp` toon ramps, a rim term,
the multiply by `max(_LightColor0·0.6 + 0.4, _ambientshadowG.rgb)` and an added
emission-like term all modulate it — so only the base color is exported and
patterns, line/outline, shadow color, emission and light cancel are **not**
covered. The OUTLINE pass (main shader only) and both SHADOWCASTER passes were
not disassembled.

Basic-shape color: both basic-shape materials (`m_koi_stu_kihon00_02`,
`m_koi_stu_kihon01_02`) bind `_ColorMask` `t_koi_stu_kihon00mc_02`, an 8×8
texture of uniform pure red (255, 0, 0, 255), so the chain reduces to a tint of
exactly `_Color` over the whole surface. Their saved `_Color` is white, which
is the exported factor. `ItemComponent.UpdateColor` writes the scene record's
`color[0]` into `_Color` for slot 0 (and pattern values only where the slot
uses a pattern), so a converted basic shape takes the record's `color[0]` as
its base color factor; the exported material now carries `itemColorSlot` in
its `extras` — the fully selected `_ColorMask` channel (0 = `_Color`,
1 = `_Color2`, 2 = `_Color3`, null when none is fully selected) — plus
`itemAlphaProperty`: `_alpha` for the alpha shader, so the app can substitute
the record's saved color and alpha through the exported factor at render time.
(The first write-up of
this slice called the mask unbound; the exporter had already read the bound
mask's pixels, so the exported factor was unaffected.)

Evidence in `.local/reverse/shaders/`: `item-studio-evidence.json` /
`item-studio-alpha-evidence.json` (contracts and refusals), `-summary.json`
(pass/variant/binding metadata), and the four preserved assemblies
`item-studio-forward-8.asm` (`2db166f9…`), `item-studio-forward-9.asm`
(`fe4821ee…`), `item-studio-alpha-forward-4.asm` (`fb1fc929…`),
`item-studio-alpha-forward-5.asm` (`9c2011ca…`). The exporter mapping is
`item_material_contract` in `Tools/reverse/export_prefab.py`, exercised on
`cube01`/`cylinder00` in `.local/reverse/exports/` and cataloged in
`.local/reverse/catalog/studio-items.json`.

### Eye (hitomi) shader evidence (added 2026-09-29, ST-T07)

`Tools/reverse/eye_shader_contract.py` resolves `cf_m_hitomi_00`'s `m_Shader`
PPtr in `chara/bo_head_00.unity3d` to `Shader Forge/toon_eye_lod0` and reuses
`item_shader_contract.shader_evidence` to preserve both FORWARD pixel variants
(blob indices 4/5, keywords `DIRECTIONAL` / `DIRECTIONAL SHADOWS_SCREEN`; both
disassemble to the same assembly digest `038462b79e…`). This checks the
transforms PR #59 assumed for the iris materials:

- **(a) `_MainTex` UV.** Not `uv * _MainTex_ST.xy + _MainTex_ST.zw` alone: a
  `_rotation` term (cb0[12]) rotates the base UV about (0.5,0.5) *before* the
  `_ST` transform. With `a = 2π·_rotation` (`sincos` writes sin to the first
  destination), the rows give `x′ = u′·cos a + v′·sin a`,
  `y′ = −u′·sin a + v′·cos a` in Unity V — the identity at `_rotation = 0`.
  Because `SourceRig` stores source UVs as `(u, 1 − v)` over upright textures,
  the native equivalent is the standard counter-clockwise `R(+a)`, and a Unity
  `_ST` becomes `(sx, sy, ox, 1 − sy − oy)` in native V
  (`SourceStudioIrisRendering.nativeST`). The first write-up of this slice read
  the `sincos` destinations swapped and reported a constant −90° term; the
  orchestrator's review corrected it, and also found that #59 had written the
  Unity V offset unconverted, inverting vertical iris motion (fixed here).
- **(b) overlay UV channels.** The `_overtex1` second sample reads the second
  UV0 channel (`TEXCOORD0.zw`), `_overtex2` reads `TEXCOORD1.xy`, and
  `_expression` reads `TEXCOORD0.xy` after a parallax nudge
  (`uv − 0.06 · dot(tan/bitangent, viewDir)`); each then gets its own `_ST`.
  This matches PR #59's independent UV1/UV2 buffers.
- **(c) what `_rotation` does.** A UV rotation of `_MainTex` only — angle
  2π·_rotation radians (turns), center (0.5,0.5), applied before `_MainTex_ST`,
  never touching `_expression`/`_overtexN`. `EyeLookMaterialControll` writes
  ±0.02 turns (±7.2°) as the eye tilt.
- **(d) sample composition.** Base, then expression tint
  `base += (expr.a · _exppower) · (expr − base)`, then the two overcolor
  premultiplied highlights combined by component maximum, factor
  `highlight.a · _isHighLight`, rgb mixed by that factor and alpha maximized
  with it — all before lighting multiplies by
  `max(_LightColor0 · 0.6 + 0.4, _ambientshadowG.rgb)`. Our pre-lighting iris
  branch implements the highlight half only; the expression tint stays an
  explicit approximation.
- **(e) cull/blend/alpha.** FORWARD is Cull Back, ZTest Less/equal class with
  ZWrite off, `SrcAlpha/OneMinusSrcAlpha` blend (the same serialized values as
  `main_item_studio_alpha`, whose alphaMode is BLEND), and there is no
  `discard`/alpha-test anywhere in FORWARD — eye transparency is pure blend,
  as PR #59's studio handling assumed.
- **(f) sampler wrap.** The DXBC carries no SAMP chunk at all (3 chunks:
  ISGN/OSGN/SHDR), so wrap state lives only in the imported texture data —
  which PR #59 already read (`m_WrapMode` 1 = Clamp for the iris textures).

Impact on PR #59: its base and overlay sampling is exact at the shipped
`_rotation = 0`, and the new `irisRotation` uniform applies only the tilt
delta (standard rotation before `irisST0`), wired in
`SourceStudioCharacterPreview` from face shape value 33 (L =
`0.02 − 0.04 · value`, R = −L, per `ChangeSettingEyeTilt`/`SetEyeRot`).
Evidence in `.local/reverse/shaders/`: `eye-hitomi-evidence.json`,
`eye-hitomi-summary.json` and `eye-hitomi-forward-4/5.asm`.

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

Source iris materials carry three extra `MaterialUniforms` _ST vectors
(`irisST0`/`irisST1`/`irisST2` for `_MainTex`/`_overtex1`/`_overtex2`, Unity
layout scale-u/scale-v/offset-u/offset-v, defaulting to identity) that the
toon fragment applies as `uv' = uv * st.xy + st.zw` to the base and both
highlight samples, gated by `MaterialFlagSourceIrisHighlights` so every other
material samples exactly as before. The imported iris textures serialize
legacy `m_WrapMode` 1 (Clamp), so those three samples use the linear
clamp-to-edge sampler rather than the repeat sampler the earlier tests
assumed. Studio writes per-frame gaze-driven values into these uniforms; the
shader change alone is identity for every existing material. A fourth float,
`irisRotation`, carries the source `_rotation` eye tilt in turns: the base
iris sample is rotated about (0.5,0.5) by 2π·irisRotation *before* `irisST0`
is applied, exactly where `toon_eye_lod0` FORWARD does it, while both
highlight samples stay unrotated. Default 0 keeps every other material and
every untilted iris bit-identical.

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
in the hair families (attribution below). Re-running the probe with the
opt-in draw trace (2026-09-26) reproduced every figure unchanged; the trace
diagnostic adds records but cannot change draw order, so no gate result
moved.

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

Draw-order trace (added 2026-09-26, opt-in via
`IKKOKU_ORIGINAL_FRAME_TRACE_PIXELS="x,y;…"`; writes
`<probe folder>/native-draw-trace.json` listing every draw in the sorted
sequence with the RGBA and reverse-Z depth remaining at each traced pixel):
re-rendering the truncated draw list locates exactly where each residual
class flips. Native-only pixels (e.g. 393,96; 363,98; 398,98; 400,101;
407,101; 352,106; 422,113; 424,116; 424,118; 429,119) are transparent
until a `main_hair` forward draw covers them and stay covered — pixels the
original render never paints at all — while some original-only pixels
(339,137; 347,116; 349,113; 352,109; 396,99) are covered by a
`main_hair`/`main_skin`/`main_hair_front` forward draw and then overwritten
by a later `main_hair_front` outline draw. Others are only ever reached by
the `main_hair` outline shell (330,171; 423,115; 431,124). Outline passes
in this capture write RGBA (0,0,0,0) together with depth, so an outline
shell that wins the depth test leaves a transparent pixel; the depth values
are reverse-Z (larger is nearer). All four candidate ordering causes were
checked and none explains the residual: (a) per-object pass order
`[outline, forward]` matches each family's serialized source pass list;
(b) within-queue ordering cannot explain the crown either — queue 2000
holds a single hair draw, and in transparent queue 2850 the three front-hair
meshes are at distinct camera distances (vertex-bounds centres 3.832 m for
`cf_hair_idol_hair_f_00`, 3.824 m for `_f_01`, 3.801 m for `_f_02`; the
capture does not record renderer bounds, so these are computed from the
captured vertices), so Unity's back-to-front sort draws them f_00, f_01,
f_02 — the same order the probe uses; (c) both the full capture and every
trace prefix clear only before their first draw, and the final trace prefix
is the full draw sequence, so no mid-sequence clear or load-action change
exists to explain the flips; (d) the `NotEqual ref 2`/`ref 2`
stencil states between `main_hair`/`main_hair`/`main_hair_front` draws are
carried across encoders exactly as serialized. Consequence: the flip between
a `main_hair`/`main_skin` draw and a later `main_hair_front` outline is not
attributable to any reordering; R1 stays open until a cause outside draw
ordering is found.

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

Next: the draw-order hypotheses are now exhausted — the opt-in draw trace
(2026-09-26, section above) shows the class flips but none of the four
ordering checks yields a fix — so attribute the hair/outline edge residual
to a concrete binding or state difference before any gate relaxation, then
integrate verified programs with production material/queue/pass dispatch.
Compare independently loaded original/native scenes with matched time,
camera, lights and effects after that integration. Orchestrator analysis of
the 2026-09-26 authored-mip run
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

### Native pose gate

The R2 transform gate compares original-player local bone transforms composed into
world space with native `card-pose` world matrices, matching hierarchy suffixes
from `p_cf_body_bone`. Generate the native snapshot with
`ikkoku-inspect card-pose <avatar.json> <card.png>`, then run
`compare_original_pose.py <probe folder> <native.json>`; the comparator takes the
avatar path from the snapshot's `source` field unless `--avatar` is supplied.

For the retained controlled clothed capture (source frame SHA-256
`9aa4de394acbae5e9a7d336b5990aa67f9619931dfce3cac6d1e8711c8bcc750`),
672 bones matched. Five ambiguous duplicate original paths were excluded; the
report lists 84 original-only keys, including clothing/accessory roots such as
`ct_clothesBot` and `ct_bra`, and 61 native-only keys. Position p50 was
7.9e-8 m; maximum scale error was 1.9e-6, with none over 1e-4. Forty-six bones
exceeded position 1e-4 m (36) and/or rotation 0.01° (46). All 46 were under
hand joints. The full gate fails; the diagnostic excluding hands passes. The
snapshot output was byte-identical across two runs.

The 46 outliers are finger joints whose original values equal the
`cf_anmShapeHand` sample-index-1 rotations. The card's hand patterns are disabled.
Recovered CharaStudio source shows that `AddObjectAssist` calls
`HandAnimeCtrl.Init(sex)` for every added character, setting pattern 0. The
Studio `HandAnime_00_00`/`HandAnime_01_00` tables list only IDs 1–21
(1 = `goo`, 2 = `scissors`, 3 = `par`, …, 17 = `ok`, 21 = `par_straight`),
so pattern 0 has no entry and `LoadAnime` disables the hand Animator. Saved
scenes apply `OICharInfo.handPtn[L/R]` through `OCIChar.ChangeHandAnime`.
The controlled probe uses `Manager.Character.CreateFemale` and never calls
`Init`, leaving the prefab hand Animators enabled to play their controller
default state `goo`, the same clip as Studio pattern 1; see
[finger-pose source attribution](studio/pose.md#finger-pose-source-attribution-st-t07).
Native `card-pose` applies no hand pattern unless `--studio-hands` names a
converted hand-pose document, so the full gate still fails on those 46 bones
without that flag. `card-pose --studio-hands <pose.json>` applies the
converted default-state `goo` clips of `cf_hand_L_00`/`cf_hand_R_00`.
The fitted document reproduces the PROBE fixture (equivalent to pattern 1);
with that document (`<pose.json>` = `.local/stt07d/studio-hand-fitted.json`,
sample time t=0.107 s fitted on a 0.001 s grid) the gate closes at 0 outliers
over 672 bones — the comparator's maximum rotation difference is 8.4e-05°.
The finger-only fit metric is 6.71e-05°. Parity holds only at that fitted
phase; the original capture never recorded its loop phase.
Studio characters with pattern 0 have no hand animation; saved patterns 1–21
need their own conversion in the next ST-T07 slice.
For this fixture, body and face shape, height and static ABMX composition match
the original player's bone transforms. Coverage is one T-posed fixture, one
outfit and standard bone type; other animated states remain untested.

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
