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

The renderer writes complete skin palettes into the frame ring's palette
storage ([G4](#renderer-threads-r7-phase-2-item-2)); the previous silent
256-matrix truncation is removed. The palette size is supplied
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

### Renderer limits and resource lifetime (R6, first slice)

**Uniform ring.** `FrameRing` keeps three 8 MiB regions in one shared buffer.
It no longer calls `precondition` when a region fills. An allocation that does
not fit goes to an overflow buffer of at least one region size (larger for
larger requests). Every allocation returns its own buffer and offset
(`FrameAllocation`), and the renderer binds that pair. The ring tracks each
region as in flight from `endFrame(retainedUntilCompletionOf:)` until that
command buffer's completion handler runs. A frame never writes into a region
still in flight. If its preferred region (`frameIndex % 3`) is busy, it takes
another free region; if every region is busy, the whole frame goes into
overflow buffers. This holds in any commit order. Before this change, the
region was chosen by frame index alone, and interactive draws commit outside
the render lock. A capture or pick completing in between could therefore let a
new frame reuse the region of an older frame that had not completed. Overflow
buffers go back to a pool of at most six only after completion (or at once
when a frame is abandoned unsubmitted). Steady large scenes therefore reuse
them instead of allocating every frame. When the device refuses an overflow
buffer, the ring throws `FrameRingError.allocationFailed(bytes:)` and never
terminates. All ring allocations now happen while the frame is being prepared,
before any encoder exists. This includes the background frame uniforms and
gizmo vertices and draw uniforms, which were previously allocated mid-pass. A
failed allocation therefore leaves the command buffer empty. Interactive
`draw` skips the frame and keeps the previously presented image; `pick`
returns 0; `capture` returns nil; `benchmark` throws
`RenderBenchmarkError.frame`. The reason appears in `Renderer.lastFrameError`
as `RenderFrameError.uniformAllocation`. Command-buffer, render-target and
pick-readback allocation failures are reported there too; the pick readback
buffer is no longer force-unwrapped.

**Frame statistics.** `Renderer.lastFrameStatistics` describes the most
recently prepared frame: the last draw, pick, capture or benchmark sample.
It reports enabled and shaded lights, `droppedLights`, deform dispatches,
active morph entries, the largest morph set, and the frame's ring region,
region bytes, overflow bytes and overflow buffer count.

**Lights.** Selection is unchanged: the first `IK_MAX_LIGHTS` (8) enabled
`RenderFrame.lights`, in list order, are shaded. Enabled lights beyond that are
no longer silent. They are counted in `lastFrameStatistics.droppedLights`.

**Active morphs.** The `prefix(IK_MAX_ACTIVE_MORPHS)` truncation is removed.
`deform_vertices` already loops over `activeMorphCount` entries read from an
unbounded device buffer, so one dispatch accumulates every meaningful target.
A meaningful target has an index inside the mesh's targets and a finite weight
whose magnitude exceeds 1e-4. The kernel, `ShaderTypes.h` and every struct
layout are unchanged. For 64 or fewer entries, the entry list, its order and
the per-vertex summation order are the same as before, so output does not
change. GPU cost grows linearly with the entry count. Source expressions still
reject sets above 64 in `SourceRigPreview.expressionWeights`; that is now a
stricter source-path validation, not a renderer capacity.

**Resource store.** `deformBuffer(for:vertexCount:)` returns nil instead of
force-unwrapping a refused allocation. The renderer records that as a
deformation error, so interactive draws skip the item and captures fail. Mesh
registration now throws `ResourceError.bufferAllocation` when the
vertex-color, morph-delta or morph-normal buffer is refused. Before, a missing
morph-delta buffer left the kernel indexing the 256-byte dummy buffer.
`setHiddenBuffer` always uploads a new buffer, so a frame already submitted
keeps the mask it was encoded with. It returns false and drops the old mask
when Metal refuses the buffer. `releaseHiddenBuffers(keys:)` mirrors
`releaseDeformBuffers(keys:)`. Owners whose frames may still be pending use
the deferred `retire` instead ([second slice](#character-and-import-lifetime-r6-second-slice)).

**Tests.** `RendererLimitsTests.swift` builds the production pipelines from
`Shaders/` with `Renderer(gpu:shaderLibrary:)`, because the test bundle has no
metallib:

- `frameRingSpillsPastItsRegionWithIntactDataAndTypedErrors` covers overflow
  placement, data read-back and the typed errors.
- `frameRingNeverReusesARegionStillInFlight` holds regions with uncommitted
  command buffers.
- `frameRingRecyclesOverflowBuffersOnlyAfterCompletion` runs 24 frames that
  use one overflow buffer.
- `lightPackingKeepsTheFirstEightEnabledLightsAndCountsTheRest` and
  `activeMorphEntriesKeepEveryMeaningfulTargetInCallerOrder` check selection
  without a GPU.
- `rendererCaptureCrossesTheUniformRegionAndReportsItsLimits` runs a real
  32×32 capture that includes a 9.6 MB gizmo batch. Only its last triangle
  covers the view, in red, and the test asserts the red center pixel. The same
  capture has 12 lights (2 disabled, so 2 dropped) and a 100-target morph. Its
  deformation buffer is read back and compared with a CPU sum to 1e-4; the
  64-target truncation differs by more than 1e-2.
- `resourceStoreAddRemoveCyclesKeepResourceCountsBounded` runs 40
  mesh/texture/deform/hidden add-remove cycles.
- `frameRingArrayAllocationReachesAThrowingCallerWithoutAnError` calls
  `allocate(array:)` three times from an out-of-line throwing caller and reads
  the values back. An empty array takes one aligned slot. It guards the Release
  fault below and only means something when the suite runs optimized.

**Release fault (found and fixed 2026-10-23).** This slice was first run in
the app on 2026-10-23 (main `87cf261`, Xcode 27.0, Swift 6.4
`swiftlang-6.4.0.34.1`, macOS 27.0.1). Every render from a Release build
crashed on its first skinned frame: thumbnails, `IKKOKU_AUTOCAPTURE`, and the
interactive display link. All Debug builds and lanes passed. The crash was a
SIGSEGV in `objc_retain`, called from `Renderer.prepare` at offset 156. A
Release build of the commit before #119 (`17aef4a`) captured normally.

An lldb register trace on the Release binary isolated the cause:

1. `allocate(array:)` copied the array inside an `array.withUnsafeBytes`
   closure. In the optimized build, that non-throwing closure loaded
   `MTLBuffer.contents()` into x21, the Swift error register. It then
   tail-called `memmove` without restoring x21. Trace: x21 = `0x0` on entry,
   `0x10ac88000` at the `b memmove`.
2. The standard library's `withUnsafeBytes` saw a nonzero x21 after the closure
   returned. It treated that as an error thrown by the closure and returned it.
3. `allocate(array:)` does not check x21 after that call, because the closure
   cannot throw, so it returned normally with x21 still set.
4. `buildContext` treated that as a thrown error at its first array allocation,
   the morph entries.
5. `prepare`'s `catch` retained the "error", which is a raw buffer pointer, and
   crashed.

Before #119, `allocate(array:)` did not throw, so nothing read the clobbered
register. In an otool scan of the whole Release binary, this closure is the
only function that overwrites x21 without saving it and then tail-calls
another symbol.

The fix copies the array without a closure, through a typed-pointer helper
(`FrameRing.copy`, using implicit array-to-pointer conversion). A two-module
package of about 60 lines reproduces the fault outside ikkoku with the same
closure. `swift run -c release repro` exits 139 (SIGSEGV), while the Debug
build and the closure-free variant run cleanly. It is kept as private
evidence for a Swift compiler report, together with the traces and the
disassembly, under `.local/local-wave-verify/` (`swift-x21-repro/`,
`release-crash-x21-closure-trace.txt`).

Guards are in the local `app-smoke` lane
([Tools/verification/README.md](../../Tools/verification/README.md)):

- `build-release-app` builds the Release app.
- `release-startup-capture` renders one bundled Maker frame with that build,
  with source-tree fallbacks off.
- `engine-release-frame-ring` runs `swift test -c release -Xswiftc
  -enable-testing --filter frameRing`.

Before the fix, the smoke check exited with signal 11 (SIGSEGV) and the
optimized test run ended with signal 11. CI does not run these checks. Its
runners use Xcode 26.6 (Swift 6.3.3), and whether that compiler emits the same
code is unverified.

Run them with
`swift test --package-path Packages/Engine --filter 'frameRing|lightPacking|activeMorphEntries|rendererCapture|resourceStoreAddRemove'`.
The first slice was written without a local compiler; CI's Engine suite was
its only test run. The local run on 2026-10-23 is described above: optimized,
`--filter frameRing` passed 4/4 after the fix. The app run covered only the
Release smoke and thumbnail captures. Concurrent interactive/capture/pick
stress is still not run.

### Character and import lifetime (R6, second slice)

**What a character owns.** A prototype `CharacterInstance` owns its
deformation buffers (keys `instanceID << 16 | part`) and its body coverage
mask (`instanceID << 8 | 0x77`). Its meshes and textures come from the shared
`AssetLibrary` cache, which keeps one copy per file and skeleton key for the
app's lifetime, so removing a character does not release them.
`releaseGPUResources()` hands back the buffers. Owners call it when a
character is removed or stops being drawn, and `deinit` calls it as a safety
net. The keys are the largest part list any `build` has issued, so card
changes reuse them. The instance stays usable: the next `build` uploads its
mask again, and the renderer re-creates its deformation buffers. When a card
change leaves no covering garment, the old mask is retired as well.

**Why the release is deferred.** A `RenderFrame` names meshes, deformation
keys and hidden-mask keys, not buffers, until the renderer prepares it.
Encoded command buffers retain the resources they use, and a prepared
`FrameContext` holds strong references, so dropping a store entry never
affects GPU work in flight. The renderer's pending frame
(`Renderer.submit`) can still be prepared after its owner gives the
resources back, however, and so can a copy taken with `currentFrame()`.
An immediate release would make that frame lose its hidden mask and skip
its meshes. Its preparation would also re-create the deformation buffers
under the released keys, and nothing would release them again. Slice 1's
mask replacement uploads a new buffer, which protects encoded frames only:
a pending frame still looks the mask up by key. `SourceRigPreview` avoids
the re-creation by unregistering its own meshes first, so a pending frame
skips its items for one frame. Shared library meshes cannot be dropped that
way.

`ResourceStore.retire(meshes:deformKeys:hiddenKeys:)` therefore takes a
`ResourceClock` stamp and leaves the resources in place. Every `RenderFrame`
also takes a stamp when it is created (copies keep it), and `submit` marks
the pending snapshot as submitted. When the renderer prepares a submitted
frame created after a retirement, it completes it. That frame replaced the
pending frame, which was the only frame the interactive draw would prepare.
An unsubmitted frame passed directly to `capture`, `pick` or `benchmark`
never completes a retirement. A frame created before the newest completed
retirement gets transient deformation buffers for missing keys. The buffers
are filled by the frame's own deform pass and never stored, so a late copy
renders without re-creating a released key. Such a frame draws without the
retired hidden mask (the region bitmask applies) and skips retired meshes.
`setHiddenBuffer` on a retired key and the immediate
`unregister`/`release…` calls cancel that key's retirement.
`ResourceStore.Statistics.retiring` counts pending entries. The renderer's
frame lock and render lock order is unchanged; `retire` and completion take
only the store lock, so `deinit` can retire from any thread.

The rule for owners is to retire before building their next frame. A frame
created after the retirement counts as current, so its preparation would
re-create the deformation keys it still names.

**Owners in the app.**

- Studio prunes native character instances at the top of `refresh()`, before
  building the frame. This covers objects removed by delete (including
  characters under a deleted folder, which were never released before), undo
  and redo. New Scene, scene load and source-scene preview replace the
  instance table through the same release.
- The Maker keeps one bundled instance and releases it when an original rig
  preview replaces it; a card replacement reuses its keys.
- `AssetLibrary.importStatic` retires the previous copy's meshes when the same
  file is imported again; texture keys are shared and stay. It also
  unregisters meshes left by an import that fails after registering some of
  them.

**App reporting.** `RenderStatusReporter` turns `lastFrameError` and
`lastFrameStatistics.droppedLights` into status-line text. The Maker and
Studio poll it from their 30 Hz editor timers while active. A new problem
shows at once, and the line is rewritten only when the text changes. After
one second of frames without a problem, the status it replaced comes back.
If other code wrote the status line meanwhile, that text is kept.

**Tests.** `CharacterLifetimeTests.swift` uses the bundled prototype assets and
the production pipelines from `Shaders/` (CI-only, not compiled locally). The
character tests copy the bundled female body and the five bundled garments that
embed no image into a temporary root without `Textures/`, and they wear no hair
or accessories, so no texture is loaded. A first version that drew the fully
textured bundled characters passed when each test ran alone on CI. In the
parallel suite, however, its two tests stalled together in their first
`build`, the first synchronous `MTKTextureLoader` loads, and the Engine run
exceeded the lane's 600 s timeout. The cause was not isolated further. The GPU
tests now also run one at a time (`@Suite(.serialized)`).

The stall did not reproduce on the reference Mac (24 cores; Xcode 27.0, Swift
6.4; 2026-10-23). That run used the textured version from `dbb62d2^`, unchanged
except for timestamped progress lines, with the rest of the suite at
`claude/local-wave-verify` `5c24bb9`. `swift test --package-path
Packages/Engine` passed six times:
- four parallel runs: all 654 tests passed in 10.0–10.5 s, and the
  create–remove test took about 10 s;
- one `--no-parallel` run: 17.2 s;
- one parallel run with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, which limits
  the cooperative pool to one thread: 17.0 s.

No texture-loader deadlock was isolated, so nothing was changed. The CI runner
that stalled differs: 3 vCPUs and Xcode 26.6 / Swift 6.3.3.

- `characterCreateRemoveCyclesReturnTheResourceStoreToBaseline` runs four
  create–draw–remove cycles, alternating five and two garments. It alternates
  the explicit release with `deinit`. After each removal, the pending frame still renders with
  unchanged counts. The next submitted frame returns counts and bytes to the
  baseline, and a late copy of the old frame renders without re-creating
  anything.
- `characterDrawnAgainAfterAReleaseOwnsItsBuffersAgain` covers the Maker's
  release-then-redraw case: the mask re-upload cancels its retirement.
- `repeatedStaticImportsKeepOneCopyOfTheItemMeshes` imports the same item
  nine times. Each replaced copy stays drawable for the pending frame and is
  released after the next submitted frame.
- `onlyASubmittedFrameCreatedAfterARetirementCompletesIt` checks the
  completion rule with a synthetic mesh.
- `renderStatusReporterShowsAProblemOnceAndRestoresTheStatusAfterRecovery`
  checks the debounce.

Run them with
`swift test --package-path Packages/Engine --filter 'characterCreateRemoveCycles|characterDrawnAgain|repeatedStaticImports|onlyASubmittedFrame|renderStatusReporter'`.
None of this was run in the app. The Studio and Maker release paths and the
status line are only compiled in CI.

Remaining R6 work:

- An interactive draw, pick and capture stress run that submits concurrently:
  covered at the Engine level by
  `renderThreadDrawsWhileAnotherThreadSubmitsPicksCapturesAndRetires`
  ([Renderer threads](#renderer-threads-r7-phase-2-item-2)), not yet through
  the app's models.
- App-level import/delete/capture/pick cycles through `StudioModel` and
  `MakerModel`, including original-source characters.
- Allocation-failure injection beyond the oversized overflow request.

### Renderer threads (R7 phase 2, item 2)

**Who calls what.** Each viewport (`ViewportNSView`: one in the Studio, one in
the Maker) owns a `ViewportRenderThread`. That is a `Thread` named
`com.grabbiel.Ikkoku.viewport-render` (QoS user-interactive) whose run loop
drives the viewport's `CAMetalDisplayLink` (`preferredFrameLatency` 2, as
before). Its callback calls `Renderer.draw(to:timestamp:refreshAfter:)`, which
presents from that thread. Core Animation may still deliver an occasional callback on
the main thread. In four ThreadSanitizer Debug runs of the `viewport-lifecycle`
workload, 2 of about 2,000 callbacks did. Each came shortly after the layer
changed size: 0.3 s after a mode switch made a new viewport, and during a
window resize. Three Release runs had none, and creating the link on the
render thread instead did not prevent it. Such a callback draws on the main
thread, which is safe because every renderer entry point is. Everything else
stays on the main actor:

- The models build frames and call `Renderer.submit`, `pick`, `capture` and
  `benchmark`; their APIs are unchanged. Since item 5, the Studio's gizmo
  hover uses the asynchronous `pick`, which runs on the renderer's pick queue
  (see [picks](#picks-r7-phase-2-item-5) below).
- The 30 Hz editor timers poll the status line from `lastFrameError` and
  `lastFrameStatistics`.
- SwiftUI, AppKit and timer callbacks are unchanged.

Before this change the link was added to the main run loop. Every frame then
waited for whatever main-thread work was running: the Studio tick, input
handlers, the hover pick, SwiftUI layout.

**Locks and their order.**

- `frameLock` guards the pending frame. `submit` replaces it and
  `currentFrame()` copies it.
- `renderLock` guards everything that preparing a frame touches: the
  interactive render targets, `frameIndex`, the frame ring's open frame, the
  deformation buffers' content record (item 4) and the live encoder and its
  error. `draw`, `pick`, `capture`, `benchmark` and the live captures prepare
  and encode under it, and commit before releasing it.
- `statusLock` guards what the last prepared frame published:
  `lastFrameStatistics`, `lastFrameError`, `lastDeformationErrors` and
  `lastSourceShaderLive`. It also guards `lastFrameGPUTime`, which the draw's
  completion handler writes on a Metal thread.
- The order is a frame slot (`GPUContext.waitForFrameSlot`, at most 3 in
  flight), then `renderLock`, then `frameLock` or `statusLock`. Nothing waits
  for a slot or for the GPU while it holds `renderLock`. An unchanged-frame
  preflight takes only `renderLock` and releases it before acquiring a slot.
  Interactive draws commit and present under `renderLock` so two callbacks
  expose reusable images in draw order; neither operation waits for the GPU.
  Since item 4, picks and captures also commit before releasing it (see
  below); the wait for the GPU still happens after.
- `observerLock` guards the submit observers (item 4). It is never held while
  taking another lock, and `submit` calls the observers after releasing it.
- `ResourceStore` and the frame ring's completion state keep their own locks,
  unchanged.

**Which frame a draw prepares.** `draw` takes the pending frame once it holds
`renderLock`. Before, it took the frame on entry, which was equivalent while
everything ran on one thread. With two threads, taking it early would let a
pick or capture prepare a newer submitted frame in between. That frame would
complete a retirement ([R6](#character-and-import-lifetime-r6-second-slice))
that the older frame still needs. A frame submitted while a draw is preparing
is drawn by the next callback.

**Command buffers from two threads.** Every command buffer the renderer
commits goes to the one `gpu.commandQueue`, and since item 4 every one of
them commits while its caller still holds `renderLock`, in the same hold that
prepared and encoded it: interactive draws and keep-alive refreshes, both
picks, `pickTarget`, captures, benchmark samples and both live captures. Their
commit order, and so their order on the queue, is the order in which they
held the lock. Before item 4, picks and captures committed after releasing the
lock, so their commit order was arbitrary. That was safe only because every
command buffer was self-contained, and since deformed-vertex reuse (below) it
no longer is:

- A command buffer that dispatches the deform pass for a deformation writes
  every vertex of its buffer before any of its passes reads it.
- A command buffer that reuses a deformation dispatches nothing for it and
  reads the buffer as the last command buffer before it on the queue left it.
  Metal tracks hazards between command buffers on one queue for these
  buffers (private, tracked, not from a heap), so that read waits for that
  write, and a later write waits for the read.
- It writes its render targets before reading them.
- The frame ring never reuses a region still in flight, in any commit order
  ([R6](#renderer-limits-and-resource-lifetime-r6-first-slice)).

The record of what each buffer holds is updated in the same lock hold as the
commit (`Renderer.commit(_:writes:)`), so the record changes in queue order.
The case this rules out: a pick on the pick queue encodes a deformation of
frame A and releases the lock; the render thread then draws frame B, which
writes B's vertices and records them, and commits; the pick commits last. The
queue then runs B's write before A's, the buffer holds A, and the record would
say B: a later draw of B would reuse the buffer and draw A's vertices. With
the commit inside the lock, the pick's write is recorded before the draw is
prepared, so the draw dispatches B again.

**Published diagnostics.** These describe the most recently prepared frame,
on any thread. An offscreen caller that reads them after its own call
returns may therefore see a draw that ran in between. Inside the renderer,
`pick`, `capture`, `benchmark` and both live captures read
`lastDeformationErrors` while they still hold `renderLock`, so each sees its
own frame's errors. Before this change, the live captures read the value again
after releasing the lock. A draw publishing in between could have cleared it,
and the capture would then have waited on a command buffer it never committed.
The app reads these values after an offscreen call in two kinds of place:

- `AppState`'s launch paths (autocapture, the rig capture and the live probe).
  These run before any viewport exists.
- The status line, which only needs the latest frame.

**Unchanged interactive frames (R7 G3, #150).** `submit` advances a revision
separate from the frame's resource-retirement stamp. The last encoded interactive
image is reusable only when the revision, resource-store generation, drawable
pixel dimensions and viewport layer identity still match. The skipped callback
allocates no command buffer, opens no frame ring and presents nothing: Core
Animation retains the previously presented image. Since item 4 the display link
slows down while frames stay unchanged, and an idle viewport presents its image
again every 1/15 s (below). Every new submission redraws, even if its values
equal the old one.

Native shaders do not read `FrameUniforms.time`. A frame with any visible live
source-shader material draws continuously, conservatively preserving `_Time`
even when a particular program does not use it. New viewport threads explicitly
invalidate the image, as does a callback gap above 250 ms (minimize/occlusion) or
a backward timestamp. A failed encode is not cached; a failed GPU completion
invalidates only its own image, without invalidating a newer completed draw.

Resource mutations during encoding prevent reuse. Registered mesh/texture data
is immutable after upload; replacements and hidden-mask changes go through
`ResourceStore`, whose generation advances on handle/key changes and completed
retirements. Deformation buffers are excluded from the generation: whether a
draw may reuse one is decided per buffer (deformed-vertex reuse, below).
Captures, benchmarks and the live captures keep their complete pass graphs and
always dispatch every deformation; picks may reuse deformations like
interactive draws. No frame caches or reuses the shadow map (see
performance.md, "Phase 2, item 4"). Offscreen writes cannot change the
previously presented drawable.

`Renderer.draw` returns rendered/unchanged/failed (and, since item 4,
refreshed) plus statistics captured under the render lock. Its optional completion reports exactly that command buffer's
GPU duration and success. The harness uses these instead of polling the previous
GPU duration or counters that a concurrent pick might have replaced.

**Adaptive link rate (R7 phase 2, item 4, P2).** `DisplayLinkRatePolicy`
(Renderer) decides the rate each viewport's render thread asks its link for;
the thread applies it to `preferredFrameRateRange`.

- After 0.5 s in which every callback was unchanged or refreshed, the link
  asks for 30 Hz; after 3 s, 15 Hz. The policy only steps down on its own.
- Activity returns the link to its original range at once: a rendered or
  failed callback (a failed one is retried by the next), and a wake. The
  viewport wakes its thread on every input event (mouse, scroll, magnify,
  key), on a resize and from a submit observer that `Renderer.submit` calls
  after the frame is pending (`addSubmitObserver`). A wake schedules the rate
  change on the render thread's run loop with `CFRunLoopPerformBlock` and
  wakes it, so the link is only ever touched on its own thread. A callback
  that Core Animation delivers on the main thread draws but leaves the policy
  and the link alone.
- `IKKOKU_PERF_LINK_RATE=fixed` keeps the full rate (a policy with no tiers),
  as before item 4: a measurement control.

**Idle keep-alive (R7 phase 2, item 4).** With G3 (#154) an idle viewport
presented nothing, and after about 0.17 s without a present the first two to
four presents of the next change never reached the screen: an orbit after a
pause first showed 52–79 ms after the input instead of about 32 ms
(performance.md, "Phase 2, item 4"). `draw(to:timestamp:refreshAfter:)` now
takes a keep-alive interval, 1/15 s from the render thread
(`DisplayLinkRatePolicy.keepAliveInterval`).

- An unchanged callback whose target is at least the interval (less 1 ms of
  slack) after the viewport's last present copies the last presented image
  into its own drawable with one blit and presents it. The result is
  `.refreshed`. It encodes no frame, opens no frame ring, does not change the
  cached image and counts as idle for the rate policy.
- The source is the newest presented drawable's texture, rendered or
  refreshed, so a refresh shows exactly the bytes on screen. The layer cannot
  hand that drawable out again before a newer one is presented; when it does
  come back (its present was dropped), the callback skips the refresh. A new
  viewport thread, a resize or a different pixel format has no source until a
  frame renders.
- A refresh shares the serial of the draw it copies: a failed refresh clears
  the cached image unless a newer draw replaced it.
- The slowest tier calls back once per interval, so the keep-alive keeps its
  interval at every rate; a test pins that.
- While the viewport's window is not visible (`NSWindow.occlusionState`
  without `.visible`: occluded or minimized), nothing it presents is shown.
  The policy then asks for its slowest tier at once, turns the keep-alive off
  and ignores wakes and rendered callbacks. When the window is visible again,
  the thread invalidates the cached image, so the next callback renders the
  current frame, which returns the link to full rate; so does the first input
  or submit.
- `IKKOKU_PERF_KEEPALIVE_MS` overrides the interval (0 turns it off):
  a measurement control.

**Deformed-vertex reuse (R7 phase 2, item 4).** Each deformation key has a
persistent buffer (`ResourceStore.deformBuffer`), and the deform pass used to
rewrite it in every command buffer. The renderer now keeps, under
`renderLock`, a record of what each buffer holds, by buffer identity: the
inputs of the last committed dispatch into it (`DeformContent`).

- The deform kernel is a pure function of the mesh (base vertices, skin data,
  morph deltas and normals, vertex count), the bound skin palette and the
  meaningful morph entries, and it writes every field of each vertex. A
  registered mesh's buffers are never written again, so the mesh's identity
  stands for them. Palettes and entries compare by bit pattern; neither has
  padding, and entries carry finite nonzero weights.
- Interactive draws and both picks (`DeformMode.reuse`) skip the dispatch of
  a deformation whose buffer's record matches the frame's inputs. The frame
  still binds the buffer, its palette and its morph entries, so live
  source-shader inputs read the same vertices. Captures, benchmarks and the
  live captures always dispatch (`.always`) and record what they wrote.
- `encodeDeform` removes the record of every buffer it writes;
  `commit(_:writes:)` sets it again in the same lock hold as the commit. A
  command buffer that is abandoned after encoding, or a path that commits
  without recording, can only cost a later frame a dispatch.
- The record holds the buffer and the mesh weakly. A released, regrown or
  transient buffer (a frame older than a completed retirement) is a new
  object, which no record names, so it is always dispatched.
- A command buffer that fails removes the records it set, unless a later
  write replaced them, and invalidates the cached interactive image, which
  may have read them.
- `RenderFrameStatistics.deformDispatches` counts encoded dispatches and
  `deformReuses` the reused deformations.
- `Renderer.reusesDeformedVertices` (`IKKOKU_PERF_DEFORM_REUSE=off` in the
  harness) dispatches every deformation, as before: a measurement control.

**Thread lifetime.**

- `ViewportNSView` starts the thread when it enters a window. It stops it when
  it leaves the window, when SwiftUI dismantles it (`dismantleNSView`), and in
  `deinit`.
- `stop` is thread-safe and returns at once. It sets a flag under a lock and
  stops the thread's run loop. The thread finishes the draw in progress,
  invalidates the link and exits. The run loop also returns every 0.25 s, so a
  missed wake-up cannot keep the thread alive.
- On `NSApplication.willTerminateNotification`, the view stops its thread and
  waits for it, at most 0.5 s. Quitting during a draw therefore lets that draw
  finish before the process exits.
- When the window is minimized, the link stops calling. The thread waits in its
  run loop, which a mach port keeps alive. Since item 4 the view also follows
  the window's occlusion changes and tells the thread, which idles without the
  keep-alive while the window is not visible.
- A Studio/Maker switch replaces the viewport. Each switch stops one thread and
  starts another.
- The app has one window (its New item is replaced), so at most one render
  thread runs.

**Concurrency checking.** The app target compiles in Swift 5 mode with
`MainActor` default isolation. The types that cross threads are
`nonisolated`:

- `ViewportRenderThread` and the harness's `PresentLog` are `@unchecked
  Sendable`, each with a written invariant.
- `PerfDrawLog` is `Sendable`, behind an `OSAllocatedUnfairLock`.
- The Engine package (Swift 6 mode) gains no `@unchecked Sendable`. `Renderer`
  and `FrameRing` keep theirs, and their invariants are now written in the
  source.

**Skin palettes (G4).** Before this change, `buildContext` called
`makeBuffer(bytes:length:options:)` for every referenced skin set, on every
prepared frame: draws, picks and captures. Now `FrameRing.allocatePalettes`
copies all of a frame's palettes into the frame's region's palette buffer.
There is one shared buffer per region. Each palette starts at a 256-byte
aligned offset, and the deform passes (native and live) bind that buffer and
offset.

- The palette buffer follows the region's in-flight rule. It is rewritten only
  once every command buffer that read it has completed.
- When a frame needs more than the buffer holds, the region gets a new buffer.
  It is twice the old size, at least `FrameRing.minimumPaletteCapacity`
  (64 KiB), and doubled until the frame fits. The old buffer stays alive for
  the command buffers and allocations that still use it.
- Once every region has seen the largest frame, palettes cost no allocation.
- A frame that finds every region in flight puts its palettes in overflow
  buffers, like its other allocations.
- Validation is unchanged and still per element. Each referenced set must be
  non-empty, at most `UInt32.max` matrices, and contain only finite elements.
  The finiteness check now tests four lanes at a time
  (`Renderer.allFinite`). The error text is the same.
- A refused palette buffer adds "Could not allocate skin set N" for each set,
  as a refused per-set buffer did, so their draws are skipped and captures
  fail.
- `RenderFrameStatistics.skinPalettes` counts the palettes written.
  `uniforms.paletteBytes` and `uniforms.paletteBuffersCreated` report the
  bytes and growth.

**Tests.**

- `frameRingPalettesGrowByDoublingAndStopAllocatingOnceWarm`
  (`RendererLimitsTests.swift`) covers:
  - alignment, order and read-back;
  - growth within a frame, while the earlier palettes keep their bytes;
  - the in-flight rule, with an uncommitted command buffer;
  - the overflow path;
  - twelve steady frames that create no buffer;
  - a 640,000-byte frame that grows 128 KiB to 1 MiB.
- `skinMatrixFinitenessMatchesThePerElementCheck` compares `allFinite` with
  the former per-element check for every element position. The values tested
  are NaN, signalling NaN, ±infinity, ±greatest finite, the least nonzero
  (subnormal) magnitude and the least normal magnitude.
- `skinPalettesComeFromTheFrameRingAndStopAllocatingOnceWarm`
  (`CharacterLifetimeTests.swift`) captures a bundled skinned character 16
  times. The ring stops creating palette buffers after the warm-up. A NaN
  element or an empty set still fails the capture with the same message.
- `renderThreadDrawsWhileAnotherThreadSubmitsPicksCapturesAndRetires` draws to
  an offscreen `CAMetalLayer` from a dedicated thread. Meanwhile the test
  thread runs 16 rounds of submit, pick and capture and reads the published
  diagnostics, then retires the character. Every capture renders, and the
  retirement completes through the next submitted frame. Since item 5 the
  test thread also requests 16 asynchronous picks, and every one completes.
- Item 4 (`InteractiveFrameTests.swift`, `DisplayLinkRatePolicyTests.swift`):
  - `keepAliveRefreshPresentsExactlyTheLastImageWithoutEncodingAFrame` fills
    each drawable with a sentinel and reads it back. A refresh holds exactly
    the last rendered image's bytes, chained refreshes too, and encodes no
    deform dispatch. No refresh happens before the interval, without one, on
    a new viewport thread or after a resize, and a new submission renders.
  - `submitObserversRunAfterEverySubmitUntilRemoved`.
  - `deformReuseFollowsThePaletteTheMorphsAndTheMeshAndChangesBack`: one bit
    of one palette matrix, the morph weights (and entries below 1e-4), another
    mesh on the same key and an unskinned mesh each dispatch; equal content
    in new arrays reuses. Every reused draw's pixels equal those of a draw
    that dispatched (`reusesDeformedVertices` off), and returning to earlier
    content dispatches again.
  - `deformReuseNeverTrustsAReleasedGrownOrTransientBuffer`.
  - `offscreenWritesBetweenDrawsKeepTheContentRecordInQueueOrder`: captures,
    benchmarks and synchronous picks of other content between draws, picks
    that reuse, the same pick ids with reuse off, and twelve asynchronous
    picks interleaved with draws, each draw byte-identical.
  - `liveDrawsReadReusedDeformedVertices`: a live source-shader draw reuses
    its deformation on every continuous callback, with identical pixels and
    no fallback.
  - The policy tests: the tiers, activity and wakes, a hidden window (slowest
    tier, no keep-alive, activity ignored until it is visible again), the
    slowest tier against the keep-alive interval, and the harness's
    lowered-rate allowances.

### Studio live step threads (R7 phase 2, item 3)

**Who runs what.** The Studio's 30 Hz timer still fires on the main run
loop and calls `StudioModel.stepLive`. For a scene with source characters,
the step now runs in three parts:

1. **Start (main actor).** `startParallelLiveTick` copies every input the
   step reads into value types (`SourceStudioLiveTick.Input`):
   - the new clock value and the 1/30 s step;
   - the automatic blink flag;
   - for each neck or eye gaze, the view camera in the rig's model space and
     the document edits;
   - the frame the refresh will merge for each visible character: its world
     matrix, object id, edits, wear and face state, read from the timeline
     state as the refresh reads them.

   It writes no observed state. It then hands each preview to a
   `SourceStudioLiveTickLease` and starts a `SourceStudioLiveTickJob`.
2. **Workers.** The job runs `DispatchQueue.concurrentPerform` from a
   user-interactive global queue, one iteration per lease. Each iteration
   runs `SourceStudioLiveTick.step` for one preview, in the serial step's
   order: blink, neck gaze, eye gaze, dynamics clock, then the refresh's wear,
   face state and frame. Characters never read each other there.
3. **Commit (main actor).** The job's completion is `DispatchGroup.notify`
   on the main queue. It settles the step (below) and calls `refresh()`,
   which merges the frames in document order and submits them.

The main actor keeps the snapshot, the commit, the merge and `submit`. Route
character previews, native characters, gizmos and the live source-shader
attach still run in the refresh on the main actor, as before.

**Ownership.** `SourceStudioCharacterPreview` is a mutable class (caches,
clocks, dynamics state) and is not `Sendable`. A lease moves one preview to
one worker for one step. It is the only new `@unchecked Sendable` type, and
its invariant is written on the type:

- The job rejects two leases of one preview (`init?` returns nil), so each
  preview has exactly one owner per step.
- From `start` until `wait()` returns, the main actor neither calls a leased
  preview nor reads its mutable state. `StudioModel` enforces this in one
  place: `sourceInstances` is a computed property whose getter and setter
  settle the step first. Only `startParallelLiveTick` reads the storage
  directly, before `start`.
- The dispatch happens before a worker's first access, and the group's leave
  happens after its last, so the main actor sees every write once `wait()` or
  the completion returns. `wait()` also drops the job's references to the
  previews.
- Outputs, timings and the lease array sit behind an `OSAllocatedUnfairLock`.
  The job itself is `Sendable` without `@unchecked`.

**Settling.** Settling waits for the job if it is still running, then
commits it in the serial step's order:

1. the animation clock (with an observation mutation);
2. the neck gaze errors, in lease order, then the eye gaze errors (lease
   order is the order the serial loops iterated `sourceInstances` in);
3. the route clocks (`stepSourceRouteClocks`).

The step's frames then wait for the next refresh. Three kinds of access
settle:

| Access | Frames |
| --- | --- |
| `refresh()`, and reads or writes of `sourceAnimationTime` | kept for the next refresh |
| any read or write of `sourceInstances` | dropped; the next refresh evaluates every character on the main actor |

A refresh takes a step's frame for a character only when all of these hold:
it is the same preview object (`===`), the clock matches bit for bit, and
`FrameRequest.matches` holds. That needs the world matrix bit for bit, and
the edits, wear and face state equal under the comparisons the preview makes
before it reuses its cached pose. A second `frame` call with such a request
returns the same frame, so taking the step's frame cannot change a byte.
Otherwise the refresh applies wear and face state and calls `frame` on the
main actor, as before.

**Edits during a step.** An edit made while a step runs (a document write,
an FK drag event, undo or redo) lands after the step: "step, then edit".
The edit's own refresh settles the step, keeps the frames whose requests
still match and evaluates the rest. A write that replaces or reaches into a
preview drops all of them. The step's snapshot never sees the edit. That
is the order the serial step had, since an edit could only run between two
main-thread steps. The `live-step-edit` Studio scenario checks the five cases
in the app (no edit, an object move, an FK edit, undo, redo). For each one it
checks the clock and the number of reused frames, and that the presented
render is byte-identical to a main-thread rebuild.

**When the timer fires during a step.** A fire while a step is running, or
has settled but not yet refreshed, is skipped (`studioLiveTickSkipped`). The
clock does not move for it. Every step that runs advances the clock by
exactly 1/30 s. Under load the live animation therefore slows down instead
of jumping, as it did when a main-thread step outlasted the timer period.
Steps never overlap or queue. If the main thread is busy when the workers
finish, the completion waits for it, and the frame presents late. The
`studioLiveWait` phase records how long a settle blocked on unfinished
workers.

**Serial fallback.** The step runs on the main actor, unchanged
(`advanceLiveFrameSerially`, event `studioLiveTickSerial`), when:

- the scene has no source previews (native-only scenes);
- a character with a live neck or eye gaze hangs on an attachment point or
  under a route with a runtime, because its world matrix would read another
  preview's pose or a route clock that the step itself changes;
- the looked-through source camera is on such a chain or does not resolve.
  The serial step resolves it and reports the fallback as before.

A character whose frame world reads an attachment point or a route clock
gets no frame request. The refresh builds its frame on the main actor after
the step, as before.

**Scenarios stay deterministic.** `advanceLiveFrame` (the scenario runner's
`advance`) completes any step in flight, starts one, and completes it before
it returns. The `editDuringAdvance` op starts a step the way the timer does,
applies its edit while the step is in flight, then completes it.

**Views that hold previews.** `SourceExpressionInspector` and the Studio
Face and Clothes panels keep a preview reference from `sourceShapePreview`.
They read immutable fields, or the wear and face state. A worker only
compares those: `setWear` and `setExpressionState` return early when the
values are unchanged. They are unchanged because every document write
refreshes on the main actor, and that refresh applies the same values before
any later step's snapshot. The views' edits go through model methods, which
settle.

**Rule for new code.** Anything that reads or changes a source preview goes
through `sourceInstances`, or calls `settleLiveTick` first.

**The hover pick ([item 5](#picks-r7-phase-2-item-5)).** The hover pick
never touches a preview. It picks a copy of the model's last built `frame`
on the pick queue. `finishHoverPicks` applies the result on the main actor,
and a changed highlight calls `refresh()`, which settles like any other
refresh. `frame` is assigned only in the refresh. That refresh runs on the
main actor even when a live step's completion triggers it, so `frame`'s
`didSet` still counts every assignment (`frameSerial`) on the main actor. A
live step replaces `frame` at most 30 times a second, as the serial step
did. A click's `settleHoverPicks` and a live-step settle can block the main
thread one after the other. Neither the pick queue nor the live-step
workers ever wait for the main thread, so neither wait can deadlock.

**Concurrency checking.** `SourceStudioLiveTick.swift` is in the Engine
package (Swift 6 language mode). `Edits`, `Gaze`, `FrameRequest`, `Input`
and `Output` are `Sendable` value types. The blink draws are a `Sendable`
protocol (`SourceStudioBlinkRandom`) carried in the lease. The app target
(Swift 5 mode, `MainActor` default isolation) runs the completion through
`MainActor.assumeIsolated` on the main queue.

**Tests.** `SourceStudioLiveTickTests.swift` checks the contract against the
7-character scenario scene:

- `sourceStudioLiveTickDigestIsReproducibleWhenSupplied` hashes 180 serial
  steps. `IKKOKU_LIVE_TICK_DIGEST` pins the hash.
- `sourceStudioParallelLiveTickMatchesTheSerialDigest` runs the same steps
  through `SourceStudioLiveTickJob` and must give the serial hash. It also
  checks that a job refuses two leases of one preview.
- `sourceStudioEditDuringAParallelTickMatchesTheSerialOrder` lands an FK
  edit after every third step ("step, then edit") and compares the parallel
  and serial orders bit for bit. It also checks that an unchanged frame
  request reuses the step's own frame.
- `sourceStudioEmptyLiveTickJobJoinsAtOnce` covers the job with no leases.

The three fixture tests form one serialized suite. Each one loads the 7
characters and steps them on a thread of its own (`liveTickOffPool`), and its
checks run in the test's task. Building a preview blocks its thread in
MetalKit's synchronous texture load. When these tests ran on the test pool,
a parallel `swift test` hung with every pool thread blocked there (see
[performance](performance.md#correctness-2)).
The Studio scenario check `studio-scenario-live-step-edit` lands document,
FK, undo and redo edits while a step is in flight in the app. ThreadSanitizer
runs the Engine tests with `swift test --sanitize=thread --filter
SourceStudioLiveTick`, and the app check on a Debug build with
`-enableThreadSanitizer YES`.

### Picks (R7 phase 2, item 5)

A pick returns the object id that the pick pass writes at one pixel of a
frame (0 means nothing). The renderer has two picks, and both run the same
`commitPick`. They therefore return the same id for the same frame, pixel and
viewport size:

- **`pick(frame:pixel:size:)`** is synchronous. The calling thread waits for a
  frame slot, then prepares, encodes and commits the pick under `renderLock`
  (before item 4 it committed after releasing the lock; see "Command buffers
  from two threads"). It then waits for the GPU and reads the id. The
  Studio uses it for clicks, drag starts (`mouseDown`) and the scenario
  runner (`pickID(at:)`).
- **`pick(frame:pixel:size:completion:)`** is asynchronous and returns at
  once. A serial dispatch queue, `com.grabbiel.Ikkoku.pick` (QoS
  user-interactive), runs the same steps in the order the picks were
  requested: the frame slot, preparation, encoding and the commit under
  `renderLock`, and the wait for the GPU after releasing it. It then calls
  `completion` exactly once, on that queue, with a `RenderPickResult`: the id
  and the command buffer's GPU time. A pick that cannot run returns id 0 and
  publishes its reason, as the synchronous pick does.
  - The completion runs on the pick queue. It must not wait for the main
    thread, because the main thread may be waiting for it (a click settles
    the hover first, below).
  - The pick queue holds its frame slot while it waits for the GPU, as a
    synchronous caller does. With a pick in flight, draws keep two of the
    three slots.

**Locks and retirement.** Picks take the [lock order](#renderer-threads-r7-phase-2-item-2)
of every other frame: a frame slot, then `renderLock`, then `frameLock` or
`statusLock`. Neither pick holds `renderLock` while it waits for a slot or
for the GPU.

A pick prepares the frame its caller passes by value, and that frame is never
the submitted snapshot. A pick therefore never completes a retirement
([R6](#character-and-import-lifetime-r6-second-slice)). An asynchronous pick
can run after a retirement completed, for example after a character was
deleted. Its frame is then a late copy: it gets transient deformation buffers
for missing keys and skips retired meshes, as R6 provides. The Studio drops
such a result anyway, because the deletion rebuilt its frame.

**Command buffers.** Since item 4, picks commit inside the render lock, like
every other command buffer that may dispatch the deform pass. Each pick
command buffer dispatches the deformations whose buffers do not already hold
its frame's vertices (deformed-vertex reuse), writes the shared interactive
pick target at its pixel and then copies that pixel back. Metal orders
command buffers on the one queue and tracks the pick target, so a
synchronous pick and an asynchronous pick in flight at the same time each
read back their own pixel.

**Scissor.** The pick pass is scissored to the one pixel it reads, and a
1×1 copy brings back only that pixel (a 16-byte readback buffer). Before
item 5, the pass rasterized and shaded the whole viewport for every pick.
Rasterization, the depth test and the pick fragment shader all work per
pixel, so the scissored pass writes the same id at that pixel as the whole
pass. The pass now binds one texture per item, the body mask, with the same
black fallback as before. That is the only texture `pick_fragment` reads; its
draw and material uniforms come from `bindDraw`. The ten other material
textures and a second binding of the draw uniforms were unused.

- `pickTarget(frame:size:)` (internal, for tests) runs the unscissored pass
  and returns the whole pick target as the reference.
- A pixel outside the viewport is clamped to its edge, as the copy's origin
  was before. An empty viewport (a zero width or height) picks nothing and
  returns 0.

**The Studio's hover (`StudioModel`).** `mouseMoved` no longer waits for a
pick. `LatestPickQueue` (in `LatestPickQueue.swift`, a value type with no
threads of its own) decides what to pick:

- A move with no pick in flight starts one for its position, against the
  current context: the frame (a serial counted on every `frame` assignment)
  and the viewport size.
- A move while a pick is in flight only records its position. A later move
  replaces that position, so at most one pick is in flight and at most one
  position waits.
- When a pick finishes, its result applies only if it answers the latest
  move and was taken against the current context. The highlight then changes
  exactly as the synchronous hover changed it: `hoverAxis` is set and the
  frame refreshed, only when the axis changed.
- Any other result is stale and dropped. If the latest move has no answer
  yet, it is picked again against the current context. A move that was
  answered stays answered. A later frame change does not pick it again; the
  synchronous hover did not either, because it only picked on a move.
- When the gizmos are hidden or nothing is selected, the waiting position
  is forgotten and the result in flight is dropped.

Finished picks go from the pick queue to the main actor through a
`PickMailbox`: an `OSAllocatedUnfairLock`-guarded list and a semaphore.
`StudioModel.finishHoverPicks` applies them in order. `mouseDown` first calls
`settleHoverPicks`, which waits for the pick in flight and applies what it
finds. A click therefore sees the highlight of its last move, as with the
synchronous hover. It blocks the main thread for at most one pick round
trip, or two if a stale result is picked again. The scenario runner's
`hoverGizmo` op uses the same call. One case differs from the synchronous
hover: when the selection is cleared while a pick is in flight, `hoverAxis`
keeps its value. It only highlights a gizmo that is no longer drawn.

**Concurrency checking.** No new `@unchecked Sendable`. `LatestPickQueue`,
`RenderPickResult` and `PickMailbox` are plain `Sendable`, and the mailbox's
state is behind its lock. The asynchronous pick waits for its command buffer
on the pick queue instead of in a completion handler, so no Metal buffer
crosses threads in a `@Sendable` closure. `StudioModel.HoverPickContext` is
`nonisolated`, so the app's main-actor default isolation does not apply to it.

**Tests** (`PickTests.swift`):

- `scissoredPickMatchesTheWholePickPassAtEveryTestedPixel` renders a frame
  with every kind of pick target at 192×144. The frame has a skinned,
  deformed character, an opaque quad that discards through a body mask, a
  transparent quad, a translate gizmo with a highlighted axis, a rotate
  gizmo, a bone handle, an unpickable line batch and the background. The
  masked quad is tilted, and each mip level of its mask is a different
  checkerboard. A pass that sampled another mip level would discard other
  pixels. The test compares 4,386 of the 27,648 pixels with the unscissored
  pass: every edge pixel, a 9-pixel grid and the corners, synchronously and
  asynchronously. Together they show 11 distinct ids. The test also checks:
  - the mask is in effect: the masked quad covers 1,471 of the 2,931
    pixels the unmasked quad covers;
  - pixels outside the viewport are clamped;
  - an empty viewport returns 0.
- `staleAsynchronousPicksAreDroppedAndTheLatestMoveApplies` drives
  `LatestPickQueue` with real asynchronous picks:
  - a result for an axis pixel arrives after the pointer moved to the
    background, and it is dropped;
  - a result taken against frame 1 arrives after the frame changed, and the
    latest move is picked again against frame 2.
- Four pure tests cover the queue and the mailbox: coalescing, re-picking
  after a context change, cancelling, and delivery order with a waiter.
- A mutation control moved the scissor one row down. The scissored,
  asynchronous and stale-drop tests then failed.

## Checked math, legacy skeletons and cameras (R4)

The unchecked CoreMath helpers (`normalize`, `simd_quatf.rotation(from:to:)`,
`lookRotation`, `inverse`, `rotationQuaternion`, `scaleFactors`) keep their
formulas and assume finite, usable input. `rotationQuaternion` divides by
unsigned column lengths, so a reflected basis yields a nonunit quaternion and
shear is silently dropped. Import, decoding and editing boundaries use the
checked forms instead. For accepted input they return exactly the unchecked
result, so existing valid results do not change. Otherwise they throw
`MathContractError` naming the rejected argument:

| Checked form | Throws for |
| --- | --- |
| `Float3.checkedNormalized` | Nonfinite components or squared length; length at most `minimumDirectionLength` (1e-6) |
| `simd_quatf.checkedRotation(from:to:)` | Either direction, as above |
| `simd_quatf.checkedLookRotation(forward:up:)` | Either direction, as above; forward along ±X with a parallel up, where the +X fallback has no perpendicular |
| `float4x4.checkedInverse` | Nonfinite entries, a zero determinant or a nonfinite inverse |
| `float4x4.checkedRotationQuaternion` | Nonfinite entries, a nonaffine bottom row, a basis column of length at most 1e-8, dependent columns, a reflection, or shear (normalized columns farther than `tolerance`, default 1e-4, from orthogonal) |
| `float4x4.checkedTRS` | As above, except that a reflection is kept as a negative X scale so `Transform.trs` rebuilds the matrix |

These decompose native-basis matrices. They do not replace
`UnityCoordinates.matrix`, which converts raw Unity matrices without any
decomposition.

The legacy name-keyed `Skeleton` serves generated assets; source rigs use
`RigDefinition`. `Skeleton.init(bones:)` and `extended(with:)` throw
`SkeletonError` naming the bone for any of these:

- a duplicate name;
- an out-of-range or self parent;
- a cycle;
- a nonfinite rest translation or scale;
- a rest rotation that is not a finite unit quaternion (±1e-3);
- a nonfinite or nonaffine inverse bind.

Bones may be listed in any index order. `order` is the former parent-first
order, now computed without recursion.

`Skeleton.from` also rejects a skin with missing or repeated joint nodes, or one
whose bind count does not match its joints. It folds two kinds of non-joint node
into the child joint's rest TRS: a root joint's ancestors, and any non-identity
node between two joints. It decomposes those folded matrices, and authored joint
matrices, with `checkedTRS`. A mirrored Armature therefore becomes a negative
root scale, and shear fails as `unsupportedTransform`. A TRS joint directly under
its joint parent keeps its authored values.

On 2026-10-23, a local, uncommitted pure-Python reader checked all 44 bundled
skinned files: 42 GLBs plus the two glTF fixtures. All had unique joint names and
rest rotations within 8e-8 of unit length. Their roots had no reflection and no
shear above 7e-8. None had intermediate non-joint nodes or authored joint
matrices. Their rest data is therefore unchanged. A file that fails becomes an
`AssetLibrary` load failure instead of a trap.

`OrbitCamera.validate()` never edits the camera. It rejects:

- nonfinite fields;
- a nonpositive distance or near plane;
- a vertical field of view outside (0, 180) degrees;
- an orientation override that is not a finite unit quaternion (±1e-3);
- a position that coincides with the target.

`KoikatsuCameraRecord.nativeCamera()` validates its result. The app also
validates every camera of a native scene card it opens or imports
(`StudioDocument.validateCameras()`).

The override, field of view and near plane round-trip exactly through the
native scene card. Dolly, pan and field-of-view edits keep the override. `orbit`,
or any `yaw`/`pitch` assignment, clears it. Original camera records store only
pivot, Z-X-Y Euler rotation, distance vector and vertical field of view. An
edited export therefore re-imports to the same view and field of view, but
native-only `near` returns to its default. The viewport camera is always an
infinite reverse-Z perspective; orthographic cameras are not represented.

### Runtime callers (second slice)

The second R4 slice (2026-10-23) moved the runtime callers that receive user
edits or imported data onto checked forms. Accepted input still gives exactly
the former result. Each test compares the new path with a copy of the former
formula. The exception is two-bone IK. A later fix changed its results on
purpose ([lower-bone fix](#legacy-two-bone-ik-lower-bone-fix)).

- **Two-bone IK.** `IKSolver.checkedTwoBone` throws `MathContractError` for:
  a nonfinite joint, target or pole; an upper (`b - a`) or lower (`c - b`)
  bone no longer than `Float3.minimumDirectionLength`; a reach with no
  direction (target and end both on the root); any other nonfinite solution.
  `IKSolver.solveTwoBone` is the per-chain update of
  `CharacterInstance.applyIK`, applied to a pose. This slice kept the former
  formula, which the lower-bone fix below corrects. It also throws `PoseError`
  for a pose or bone index that does not fit the skeleton.
  `CharacterInstance.solveIK` leaves a failed chain's rotations unchanged and
  returns its error. `applyIK` keeps its signature, and `ikFailures()` reports
  the reasons; the Studio status line shows the first one.
- **Prototype gaze.** `CharacterGaze.apply` is the former
  `CharacterInstance.applyGaze`. These leave the pose unchanged:
  a nonfinite target; a character root with no finite inverse; a target the
  root maps to a nonfinite point; a pose that does not fit the skeleton. A head
  or eye whose frame has no finite inverse, or whose direction to the target is
  nonfinite, keeps its rotation. The source eye and neck look controllers
  already reject such input with `RigError` and are unchanged.
- **Poses.** `Pose.validate(for:)` throws `PoseError.countMismatch`, naming the
  first array that lacks one entry per bone. These checked forms validate
  first:
  - `checkedWorldMatrices`;
  - `checkedSkinMatrices`, which also checks a supplied world array;
  - `checkedBlended`, which checks both poses;
  - `checkedWorldRotation`, which throws `PoseError.boneOutOfRange` for a bad
    index;
  - `PoseDelta.checkedApply`, which checks a supplied base.

  The unchecked forms still trap on a mismatch. `CharacterInstance.jointPosition`
  now returns nil instead.
- **Rays.** A ray whose origin or direction is not finite hits nothing: every
  intersection returns nil and `closest`/`distance` return infinity. NaN slab
  distances used to leave the slab test's initial interval in place, so it
  reported a hit at distance 0 for every box. A zero direction produces such a
  ray, as does `OrbitCamera.ray(atPixel:viewport:)` with a zero-size viewport.
  `Ray.checked(origin:direction:)` and `checkedTransformed(by:)` throw instead.
  `OrbitCamera.project` returns nil for a nonfinite pixel.
- **Projections.** `checkedPerspectiveReverseZ`,
  `checkedPerspectiveReverseZInfinite`, `checkedOrthographicReverseZ` and
  `checkedLookAt` throw `MathContractError` for a nonfinite argument or result.
  The new `outOfRange` case covers a field of view outside (0, π), a
  nonpositive aspect or near plane, a far plane not beyond near, and coincident
  orthographic bounds. `checkedLookAt` also rejects an eye at the center, a zero
  up, and a view along ±Z with a parallel up, whose +Z fallback is parallel too.
  `OrbitCamera` keeps the unchecked builders behind `validate()`.
- **Camera-object look-through.**
  `SourceStudioCameraObjects.viewCamera(world:base:)` rejects a mirrored world
  matrix (negative determinant) with
  `SourceStudioCameraObjectError.reflectedFrame`. It rejects a singular one with
  `RigError`, and validates its result with `OrbitCamera.validate()`. The
  original copies the camera's `transform.rotation`. The ST-A06 capture shows
  that rotation unaffected by a non-uniform parent scale. A mirrored matrix,
  however, does not say which axis carries the mirror, and no capture covers a
  mirrored parent, so the case is rejected rather than guessed. The Studio walk
  (`SourceStudioWorldTransform.world`) composes a child's rotation with the
  parent frame's unchecked `rotationQuaternion`. That turns a mirror into a
  nonunit rotation, which the composed matrix no longer shows. The app
  therefore builds the camera from the parent frame with
  `viewCamera(parentFrame:localPosition:localRotation:base:)`, which rejects a
  mirrored parent by name.

Remaining R4 work found in this slice:

- A mirror further up a camera's chain still reaches the camera through
  `SourceStudioWorldTransform.world`. So does a parent with two negative scale
  components, which as a matrix is a proper rotation. Every other child of a
  mirrored source parent gets the same nonunit rotation. Supporting these needs
  the walk to carry Unity's product of local rotations, and an original
  capture.
- `CharacterInstance.applyIK` applied the upper delta to the lower bone twice,
  because `p.worldRotation(li)` already includes it. The hand or foot therefore
  missed its target. A local float64 replay of a 0.30 m + 0.28 m arm missed
  targets 0.49 m and 0.51 m from the shoulder by 0.13 m and 0.23 m. R4 kept the
  formula, because a fix changes valid results. The
  [lower-bone fix](#legacy-two-bone-ik-lower-bone-fix) has since corrected it.
- These remain unchecked: `IKSolver.ccd`, which has no runtime caller; the
  renderer's shadow light frame (unchecked `lookAt`/`orthographicReverseZ`,
  degenerate only for a nonfinite light direction or scene bounds); and the
  unused `StudioModel.applyGaze()`.
- DynamicBone and hair numerics are unchanged, because their original-parity
  tests need private fixtures that CI lacks. `HairDynamics.step` decomposes the
  character root with unchecked `rotationQuaternion`, and it keeps a NaN spring
  state until `reset()`. `SourceDynamicBone` already skips near-zero arcs and
  rejects nonfinite particles.

`swift test --package-path Packages/Engine --filter 'checked|legacySkeleton|legacyPose|solveTwoBone|nonfiniteRays|characterGaze|sourceCameraObject|sourceWorldTransform|importedCamera|DegenerateDecodedCameras'`
runs the synthetic tests for these contracts.

### Legacy two-bone IK lower-bone fix

`IKSolver.twoBone` returns world-space deltas for the bones' rotations from
before the solve: the new upper world rotation is `upper * oldUpperWorld`, and
the new lower one `lower * oldLowerWorld`. The second slice's `solveTwoBone`
read the lower bone's world rotation only after writing the upper bone. That
rotation already carried the upper delta, and the update then multiplied by
the delta again. The lower bone therefore ended at
`lower * upper * upper * oldLowerWorld`, and the hand or foot missed reachable
targets. The fix (2026-10-23) reads both world rotations before writing
either. It then makes `lower * oldLowerWorld` local to the lower bone's parent,
the upper bone as just written. `twoBone`, `checkedTwoBone` and their
`MathContractError`/`PoseError` cases are unchanged, so degenerate chains are
rejected exactly as before.

Results change for every enabled prototype IK chain, which only native
Studio characters have; Maker sets no targets. Native scenes and timeline keys
store targets and poles, not solved rotations. They need no migration, and
they now render with each end on its target.

A local, uncommitted plain-Python replay of the solver checked the fix in
float64, and in float32 with rounding after every operation (close to, but not
exactly, simd arithmetic):

| Case | Former update | Fixed update |
| --- | --- | --- |
| The R4 test's two targets (0.30 m + 0.28 m arm, upper arm FK (0, 20, 10)°) | missed by 0.156 m and 0.127 m | within 6e-17 m (float64), 1.6e-7 m (float32) |
| The same targets from the rest pose | missed by 0.239 m and 0.137 m | within 6e-17 m |
| 144 reachable targets: 4 poses, arm and leg, 3 directions, 35/70/95 % of reach, default and explicit pole | missed every one, by 0.046 m to 1.14 m | within 5.7e-16 m (float64), 2.5e-7 m (float32) |
| 96 targets at 102 % and 150 % of reach | — | end on the line to the target, 1e-4 m short of full reach; elbow or knee at most 7.7 mm off the line, at least 4.9 mm toward the pole |
| Re-solve from the solved pose, explicit pole | — | rotations change by at most 2.2e-7, joints move at most 2.5e-7 m (float32) |

The second slice's figures (0.13 m and 0.23 m) are closest to the rest-pose
case; that replay is not in the repository. The poses include root
rotations, uniform root scales of 0.85 and 1.3, a 1.1 upper-bone scale, and a
non-uniform lower-bone scale. The lower-bone scale applies after that bone's
rotation, so it only resizes the bone.

`RigTests.swift` replaces the second slice's former-formula comparison with
these cases in Float. Reachable ends must lie within 1e-4 m of the target,
and unreachable ones within 2e-4 m of full reach. It also keeps a copy of the
former update, to show it missing the R4 targets by more than 0.1 m. Further
tests check the bend side for opposite poles, a re-solve with an explicit
pole, and arm-then-leg solving in `IKChain` order. The degenerate-pose
rejections now also cover a zero-length lower bone and a nonfinite pole.
`swift test --package-path Packages/Engine --filter solveTwoBone` runs them.
Swift was not compiled locally, so the CI Engine suite is the only test run.
Studio's IK handles, drag and status line were not run interactively.

App check, 2026-10-23 (local-wave-verify, Debug build): the studio lane's
`reload-save-ik` / `reload-load-ik` pair drives a native female's Left hand IK
through the Pose tab's methods. It reads the rendered instance's pose; see
[Native IK re-solve and unsolved status](../../Tools/verification/README.md#native-ik-re-solve-and-unsolved-status-r4-115-and-110).
The end reached each target within 1.5e-7 m. A +0.02/−0.02 Stepper round trip
on X returned the same target float and a bit-identical arm. A 1e20 target
reported "Left hand IK left unsolved: IK reach is not finite." and left the arm
bit-identical to its pre-IK pose. With this section's former update patched
back in, the four reach asserts failed by 16–74 mm. Enabling IK at the hand's
own position moves the elbow about 2.3 cm, to the default pole's side.

Unsolved status, fixed 2026-10-23 (st-ux-ik-camera). After the target
returned to a reachable X, the status line used to keep the unsolved message:
the frame builder wrote it on a failure and nothing cleared it.
`StudioIKStatusReport` now owns that message. It names every unsolved chain,
narrows the message as chains solve, writes "Left hand IK solved again." when
the last one does, and leaves any status written since alone.
`reload-save-ik` asserts this for one chain, for two chains failing and
recovering independently, and for an "Added Kai" status that must survive
(36/36 on the Debug build of `34e3e4e`; 6 of the 36 fail on main `c3e83fa`).
A failed chain still shows its pre-IK pose, not its last solved pose: the
pre-IK pose follows from the document alone, while the last solved pose would
depend on edit history and is not saved. See
[Native IK re-solve and unsolved status](../../Tools/verification/README.md#native-ik-re-solve-and-unsolved-status-r4-115-and-110).

Remaining limits:

- The result is exact only when the upper bone and its ancestors have uniform
  scale, because `Pose.worldRotation` ignores scale. The replay's arm missed by
  0.078 m under a (1, 1.3, 0.8) root scale. The bundled sliders scale only the
  head, eyes, bust, hands and feet, and always uniformly.
- `simd_quatf.rotation(from:to:)` returns identity below about 1.4 mrad
  (`dot > 0.999999`), so a correction that small is skipped. An end can then
  sit up to about 1.4e-3 × the chain length (0.8 mm on the 0.58 m arm) from
  its target.
- A target closer than the difference of the two bone lengths folds the
  chain, and the end stops at that distance from the root.
- The default pole follows the current mid joint, so a re-solve from a solved
  pose can turn the bend plane. `CharacterInstance` always solves from the FK
  pose.

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
state and captured textures. Programs are parsed once and their pipelines cached
(`TranslatedSourceProgram`, `TranslatedSourcePipelineCache`), shared with the
opt-in [live source-shader path](#live-source-shader-path-r1cmt-04-opt-in-2026-10-22).
Production `Renderer` selects authored native toon/eye/outline materials unless
that opt-in is on.

Historical comparison of a frozen original character frame (controls below;
re-run against current code on 2026-09-26 into `.local/r1b/probe`, starting
from the original captures `.local/reverse/original-character-probe/{frame.json,frame-mips.json}`;
both frame variants reference the same source capture, SHA-256
`13bd11c2805ac99172dc7ce7539c3cb98f06edcb858af4a1136ce3570b66f039`):

| Compared path | Silhouette IoU | Color error (0–255) | Result and scope |
| --- | ---: | --- | --- |
| Geometry diagnostic | 0.9998196 | Not a color gate | 18 differing silhouette pixels; depth p99 0 m, normals 0 bytes; passes frozen geometry |
| Production native toon | See geometry diagnostic | Mean 31.2763; p99 239 | Fails source color parity |
| Translated garments | 0.9995455 | Mean 0.1169; p99 2 | Passes selected garment color gate |
| Translated full character (reference run `frame-mips.json`; same silhouette on `frame.json`) | 0.9988685 | Mean 0.2087; p99 4 (`frame.json`: mean 0.2268, p99 5) | Fails full-character silhouette gate (112 differing pixels) on both variants; color gate passes on `frame-mips.json` and fails on `frame.json` (found 2026-10-01) |

These rows use the legacy shader `NORMAL` input, which old captures still use.
The [2026-10-17 source-normal comparison](#preserve-source-shader-normal-magnitude-r1-2026-10-17)
gives this fixture's hair meshes their source normals. With them, the translated
full-character silhouette passes on both variants (44 differing pixels, IoU
0.9995552). The generated-mip color gate still fails.

The earlier documentation quoted mean 26.9362/p99 242 (older capture) and
mean 0.2267/p99 5 (previous code) for the full character. The authored-mip
variant passes p99 ≤4; the generated-mip variant still fails at p99 5. The
September residual concentrates in the hair families (attribution below).
Re-running the probe with the opt-in draw trace (2026-09-26) reproduced every
figure unchanged; the trace diagnostic adds records but cannot change draw
order, so no gate result moved.

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

Historical next step before the 2026-10-17 normal-input investigation: the
draw-order hypotheses were exhausted — the opt-in draw trace
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
and eyelines show through front hair). That pass-state comparison was
performed (2026-10-01): `stencilReadMask`/`stencilWriteMask` are 255
everywhere; `main_hair`, `main_skin`, `main_item`, `main_opaque`,
`toon_nose_lod0` and both hair outlines request `always`+`keep` at
`stencilRef` 0, `main_hair_front` and its outline request `notEqual`+`keep`
at reference 2, and the toon eye families request `always`+`replace` writing
2 — exactly what the probe already applies in the serialized queue order
(`main_hair` 2000 → `main_hair_front` 2850 → toon families 2900–3000), so no
mismatch exists and stencil state cannot explain the residual. The smallest family set that
reproduces it is {`main_hair`, `main_hair_front`}: the pair render is
pixel-identical to the full translated render across the crown box, which
holds 13 alpha-coverage differences (7 native-only, 6 original-only). The
remaining depth-precision hypothesis — the original D3D11 player stored
depth in 24 bits while Apple silicon exposes no depth24+stencil format — was
tested with the opt-in `IKKOKU_ORIGINAL_FRAME_DEPTH24=1` flag, which
re-emits the rasterized fragment depth quantized to the 24-bit fixed-point
grid through a `[[depth(any)]]` output member: coverage is bit-identical
everywhere (silhouette IoU 0.998868 and crown 7/6 before and after) while the
color buffer differs at 155 pixels (3 in the crown box), proving the
emulation is live — so 24-bit depth precision is not the cause either.
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
applies. Those historical runs left 112 differing pixels. The normal-input experiment
below subsequently identified a distinct vertex binding error; R1/R2 and CMT-04
remain open for the remaining coverage and production integration.

### Preserve source shader normal magnitude (R1, 2026-10-17)

Issue #94. The capture normalizes world-space normals for the geometry/depth
diagnostic. The legacy translated-probe input rebuilds the source shader
`NORMAL` from that unit vector as `transpose(ObjectToWorld) · n`, which loses the
original skinned magnitude. The four retained hair meshes have a uniform renderer
scale of 0.868346. On those meshes the legacy local normal has length 0.8683459;
the original weighted renderer-local normal has length 1 ± 3e-7. The recovered
hair forward vertex programs normalize their lighting normal (`dp3`/`rsq`).
Both hair outline programs and the skin outline program instead compute
`v0.xyz + v1.xyz · width` (`mad`) in object space before `unity_ObjectToWorld`.
With the legacy input, the hair outline shells' world-space extrusion therefore
carried an extra factor of 0.868346, about 13% too thin. Pass states and draw
order were already correct.

**Sidecar contract.** `OriginalCharacterProbe.cs` writes an additional
`mesh-<i>-source-normals.bin` for every exported mesh. The mesh row gains a
`sourceVertexNormals` descriptor:
`{file, count, space: "unity-renderer-local", sha256, geometrySHA256}`. The
binary holds `count` little-endian float32 triples and is never normalized.
Skinned meshes use the blend-shape-adjusted source normal, weighted by bone-world
× bind-pose matrices and mapped through the renderer's inverse linear transform.
Static meshes keep the original mesh normal. `geometrySHA256` is the hash of the
row's frozen `mesh-<i>.bin`. The world-normal, position, tangent and UV buffers
and every existing file are unchanged; the capture only adds files and the
descriptor.

`OriginalFrameProbe.sourceVertexNormals` validates the descriptor before
`TranslatedSourceShaderProbe` consumes it. It checks the coordinate space,
plain filenames, `count` against the frozen vertex count (1…1,000,000), byte
length, sidecar SHA-256, `geometrySHA256` against the row's geometry file and
finite values. Any malformed or mismatched descriptor fails the probe; there is
no fallback. Only the vertex `NORMAL` register changes. Positions, tangents,
UVs, matrices, materials, programs, ordering and gates are untouched.

The mapping assumes that the original player skins normals linearly, without
renormalization or an inverse transpose. In that case the outline's world
extrusion equals the weighted world normal, whatever object space the player
uses for skinned draws. The comparison below is consistent with that assumption;
no Unity skinning code was inspected. On these meshes, renormalizing would change
lengths by at most 3e-7.

**Old captures (limitation).** A mesh row without `sourceVertexNormals` keeps the
legacy reconstruction exactly. Every capture made before this change therefore
keeps outline extrusion scaled by its renderer scale: 0.868346 for this fixture's
hair and 0.904527 for its face meshes, including the `main_skin` face outline.
Results from those captures are not upgraded. Their magnitude can be recovered
only by a fresh capture with the amended probe, or offline where a hash-verified
rig exists. The amended C# compiles with the C# 5 language level used by the
player's .NET Framework `csc`, but it has not yet run in the original player.

**Offline reconstruction for retained captures.**
[original_frame_normals.py](../../Tools/reverse/original_frame_normals.py)
rebuilds selected meshes from hash-verified Maker rigs and their original bundles.
Reconstructed positions and normalized directions must match the frozen geometry
within 1e-5 m and 1e-5. The tool rejects ambiguous joint names, conflicting
duplicate bone rows, active morph weights, invalid skin weights and
non-finite data. It keeps weighted non-unit normals. Output goes to a new directory:
links to the unchanged inputs, the sidecars, `source-normal-reconstruction.json`
(provenance) and `frame-with-source-normals.json`. It neither runs the player nor
alters retained captures. Only the hair rigs (`101:2`, `102:1`) of this fixture
are in the retained library. The face, body and garment meshes kept legacy inputs.
Body and garment renderers have scale 1.

Controlled rerun (2026-10-17, M2 Ultra, one Debug build for all cases; only the
frame input differs). Inputs: `.local/r1c/probe/frame-mips.json`
(`13bd11c2…66f039`, authored mips), `.local/r1c/probe/frame.json`
(`9aa4de39…bcc750`, generated mips) and
`.local/reverse/maker-library/library.json` (`d898fea1…cbb609`). The baseline
folders link the retained capture unchanged:

```sh
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator -configuration Debug \
  -derivedDataPath .local/build -destination 'platform=macOS,arch=arm64' build
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_frame_normals.py \
  --frame .local/r1c/probe/frame-mips.json \
  --library .local/reverse/maker-library/library.json \
  --entry 101:2 --entry 102:1 --family main_hair --family main_hair_front \
  --output .local/r1-normal/<run>/candidate-mips
IKKOKU_ORIGINAL_FRAME_PROBE=$PWD/.local/r1-normal/<run>/candidate-mips/frame-with-source-normals.json \
IKKOKU_ORIGINAL_FRAME_FAMILIES=1 \
IKKOKU_ORIGINAL_FRAME_FAMILY_SETS=main_hair,main_hair_front \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_original_frame.py \
  .local/r1-normal/<run>/candidate-mips
```

Repeat with `frame.json` in another new directory for the generated-mip variant.
Run the app as a bounded subprocess (600 s was the limit; it exits after the
probe). Baseline input: a new directory of links to `.local/r1c/probe`
(excluding `native-*` and `frame-comparison.json`), run with the unmodified
`frame-mips.json`/`frame.json`.

The 15,956 reconstructed hair vertices (12,049 + 1,188 + 1,144 + 1,575) matched
positions within 3.23e-7 m and normal directions within 1.21e-7. The sidecars are
byte-identical between the two variants. They are also identical to the first
private reconstruction of the same data.

| Translated full character | Legacy NORMAL (baseline) | Source NORMAL sidecar (candidate) | Gate result |
| --- | --- | --- | --- |
| Authored mips (`frame-mips.json`) | 112 differing px (61 native-only / 51 original-only); IoU 0.9988684583; color mean 0.2087, p99 4 | **44 differing px (3 / 41); IoU 0.9995552051**; color mean 0.2089, p99 4 | Silhouette fail → **pass**; color pass → pass |
| Generated mips (`frame.json`) | 112 differing px; IoU 0.9988684583; color mean 0.2267, p99 5 | **44 differing px; IoU 0.9995552051**; color mean 0.2268, p99 5 | Silhouette fail → **pass**; color p99 **still fails** (5 > 4) |

Supporting measurements from the same runs:

- **Hair crown.** The inclusive x345–423, y96–116 box goes from 7 native-only /
  6 original-only pixels to 0/0. The wider x320–446, y90–146 box goes from
  23/8 to 0/0.
- **Hair pair.** The {`main_hair`, `main_hair_front`} pair render matches the
  full render's crown coverage before and after the change. In the wider box it
  has one extra original-only pixel in each case (9 vs 8; 1 vs 0).
- **Remaining silhouette classes.** The candidate adds no new differing pixel:
  its 44 are a subset of the baseline's 112. The 3 native-only pixels are
  `main_opaque` 1 and overlap 2. The 41 original-only pixels are `main_skin` 31,
  none 8 and `main_hair` 2. The `main_skin`-only render has identical coverage
  before and after. Its 31 pixels are not attributed by this experiment.
- **Unchanged images.** `native-geometry.png`, `native-depth-normals.png`,
  `native-color.png` and `native-main_opaque.png` are byte-identical between
  baseline and candidate. Geometry IoU stays 0.9998196.

Coverage is deterministic across repeated runs. Across two runs of this build,
translated RGB differed at ≤4 pixels by ≤4 channel bytes. Against the first
private experiment's build, it differed at ≤14 pixels by ≤6 bytes. Color means
therefore vary in the fifth decimal, and p99 values do not change.

**Supported.** For this frozen fixture, the hypothesis holds: the lost magnitude
explains the hair-crown silhouette residual and the silhouette gate failure.

**Still failing (recorded, gates unchanged):**

- Generated-mip translated color, p99 5.
- Per-family hair color, compared where each family is front-most:
  - `main_hair`: mean 1.001, p99 24 (authored mips); 1.035, p99 23 (generated
    mips).
  - `main_hair_front`: mean 0.845, p99 22 (authored mips); 0.916, p99 23
    (generated mips).
- Production native toon color, mean 31.28, p99 239. `passesAllGates` remains
  false.

This is a frozen-geometry diagnostic of one controlled character. It does not
establish live-app or whole-character source parity, other shader and asset
families, or production material integration. Those remain open under R1/R2.

Malformed real-data controls also ran against the derived authored-mip frame.
A wrong `geometrySHA256` stops the probe with exit 1, as does a mesh row
pointing at another mesh's sidecar (length/SHA-256 mismatch). Validation:

| Check | Result |
| --- | --- |
| Debug app build | Succeeded |
| `swift test --package-path Packages/Engine` | 525 tests, 460 passed, 65 named fixture skips, 0 failed; includes the 2 new sidecar tests |
| `Tools/reverse` suite | 360 run, 6 skipped, 0 failed; includes the 6 new reconstruction tests |
| `Tools/reverse/analysis` suite | 211 passed |
| Capture plugin | Roslyn compile at `-langversion:5` against the retained managed references |

Private evidence (inputs, outputs, logs, build and input hashes) is in
`.local/r1-normal/rerun-2026-10-17/`. The first private experiment is in
`.local/r1-normal/codex-2026-10-17/`. No image threshold, shader program or
texture changed.

### Native shader binding set (R1/CMT-04, 2026-10-18)

The translated probe binds every material input from the capture's material
dump. This slice derives the same inputs from native data only — the card, the
converted Maker library, the head material contract and an optional supplement
— and compares them with the capture input by input. Nothing is rendered live
yet; the comparison and the proof of concept below use the frozen R1 fixture.

**Contract.** `SourceShaderProgramContract` reads each translated
`program.json` and lists exactly the constant-buffer vectors and textures that
`TranslatedSourceShaderProbe.encodeTranslatedShader` binds. Each input is
classified by where the probe takes it from, using only the program's own
`Properties` block: builtins (`_ScreenParams`, `_ProjectionParams`,
`unity_WorldTransformParams`, `_WorldSpaceCameraPos`, `_WorldSpaceLightPos0`,
`_LightColor0`; the probe computes them from the frozen camera/light); declared
properties (material value, else the program default); `<texture>_ST` of a
declared texture (material scale/offset, else `[1, 1, 0, 0]`); declared
textures (material texture, else the Unity default `white`/`black`/`gray`/`bump`);
and everything else as a `Shader.SetGlobal*` global, including `_Time`.
Matrices are always computed by the probe and are not part of the contract.
`SourceShaderProgramCatalog` groups the programs by original shader, outline
first, as the probe draws them. For this fixture:

| Family | Programs | Inputs | Material vectors | Material textures (each also reads `_ST`) | Globals |
| --- | --- | ---: | --- | --- | --- |
| `main_hair`, `main_hair_front` | outline + forward | 30 each | `_Color`, `_Color2`, `_Color3`, `_LineColor`, `_ShadowColor`, `_ShadowExtend`, `_SpeclarHeight`, `_rimV`, `_rimpower` | `_AlphaMask`, `_AnotherRamp`, `_ColorMask`, `_DetailMask`, `_HairGloss`, `_MainTex`, `_NormalMap` | `_RampG`, `_RampG_ST`, `_ambientshadowG`, `_linewidthG` |
| `main_item` | outline + forward | 38 | `_AnotherRampFull`, `_Clock`, `_Color`, `_Color2`, `_Color3`, `_DetailBLineG`, `_DetailRLineR`, `_LineWidthS`, `_ShadowColor`, `_ShadowExtend`, `_ShadowExtendAnother`, `_SpeclarHeight`, `_SpecularPower`, `_notusetexspecular`, `_rimV`, `_rimpower` | `_AnotherRamp`, `_ColorMask`, `_DetailMask`, `_LineMask`, `_MainTex`, `_NormalMap` | `_LineColorG`, `_RampG`, `_RampG_ST`, `_Time`, `_TimeEditor`, `_ambientshadowG`, `_linewidthG` |
| `main_opaque` | outline + forward | 46 | `_DetailBLineG`, `_DetailRLineR`, `_LiquidTiling`, `_ShadowColor`, `_ShadowExtend`, `_ShadowExtendAnother`, `_SpeclarHeight`, `_SpecularColor`, `_SpecularPower`, `_SpecularPowerNail`, `_alpha_a`, `_alpha_b`, `_liquidbbot`, `_liquidbtop`, `_liquidface`, `_liquidfbot`, `_liquidftop`, `_notusetexspecular`, `_rimV`, `_rimpower` | `_AlphaMask`, `_AnotherRamp`, `_DetailMask`, `_LineMask`, `_MainTex`, `_NormalMap`, `_Texture2`, `_Texture3`, `_liquidmask` | `_LineColorG`, `_RampG`, `_RampG_ST`, `_ambientshadowG`, `_linewidthG` |
| `main_skin` | outline + forward | 61 | `_DetailNormalMapScale`, `_LiquidTiling`, `_ShadowExtend`, `_SpeclarHeight`, `_SpecularColor`, `_SpecularPower`, `_SpecularPowerNail`, `_alpha_a`, `_alpha_b`, `_linetexon`, `_liquidbbot`, `_liquidbtop`, `_liquidface`, `_liquidfbot`, `_liquidftop`, `_nip`, `_nip_specular`, `_nipsize`, `_notusetexspecular`, `_overcolor1`–`3`, `_rimV`, `_rimpower`, `_tex1mask` | `_AlphaMask`, `_DetailMask`, `_LineMask`, `_MainTex`, `_NormalMap`, `_NormalMapDetail`, `_NormalMask`, `_Texture2`, `_Texture3`, `_liquidmask`, `_overtex1`–`3` | `_FaceNormalG`, `_FaceShadowG`, `_LineColorG`, `_RampG`, `_RampG_ST`, `_ambientshadowG`, `_linewidthG` |
| `toon_eye_lod0` | forward | 18 | `_exppower`, `_isHighLight`, `_overcolor1`, `_overcolor2`, `_rotation`, `_shadowcolor` | `_MainTex`, `_expression`, `_overtex1`, `_overtex2` | `_ambientshadowG` |
| `toon_eyew_lod0` | forward | 9 | `_Color`, `_shadowcolor` | `_MainTex` | `_RampG`, `_RampG_ST`, `_ambientshadowG` |
| `toon_nose_lod0` | forward | 3 | `_Color` | `_MainTex` | — |

Every family except `toon_nose_lod0` also reads `_LightColor0` and
`_WorldSpaceLightPos0`; all but `toon_eyew_lod0` and `toon_nose_lod0` read
`_WorldSpaceCameraPos`. `toon_glasses_lod0` and `toon_textureanimation` have no
translated program; only their shader, queue and keywords are compared.
Summed over the drawn materials, the contract has 201 material-vector uses,
107 texture and 107 transform uses, 60 global-vector, 16 global-texture and 49
builtin uses. Beyond these inputs, each material also needs its shader
identity, render queue, keywords (recorded, but not bound: every translated
program is compiled for one variant) and pass state (from `program.json`; the
capture records none).

**Native recipe.** `SourceShaderBindingDerivation.derive` (Character) builds a
`SourceShaderBindingSet` (Renderer) and never opens the capture. The data model,
contract and comparison live in Renderer so the probe or live rendering can use
them without importing Character. The derivation needs the card and Maker
library types, so it lives in Character, which already depends on Renderer.
Each renderer starts from its prefab material, as Unity does: a property that
`m_SavedProperties` does not save keeps its shader default, and an unsaved
texture slot is empty with transform `[1, 1, 0, 0]`. The queue is
`m_CustomRenderQueue` when ≥0, else the shader `QUEUE` tag (Geometry 2000,
AlphaTest 2450, Transparent 3000, with offset; no tag → 2000). The
`SHADOWCASTER` pass is excluded. Keywords come from the Maker library's
serialized material tree (`m_ShaderKeywords`) or the supplement; no
`ChaControl` path toggles keywords. The `ChaControl` setters driven by the card
and status record are then applied, each cited by method in the output:

- hair colours (alpha raised to 1) and outline colour; the gloss mask from
  `mt_hairgloss[hair.glossId]`;
- the clothes `rendNormal01` composite; `siruLv` liquid levels; visibility
  from `clothesState`, `shoesType` and the top's `Coordinate`;
- the face composite, detail, lip, eyeshadow and cheek/lip gloss. The eyeshadow
  alpha is 0 for gag eyes, and `ChangeHohoAkaRate` alpha is 0 for rate 0.
- eyeline, eyebrow and nose textures and colours; eye highlights and colours;
  eye tilt `_rotation`; `_isHighLight`; and `_expression`/`_exppower` with the
  gag-eye visibility from `cha_eyeset[status.eyesPtn]` (unknown pattern → row 0);
- canine, tear and tongue visibility;
- the body draw material: nip, underhair, line and detail textures, nip size and
  gloss, `lerp(skinGlossPower, 1, skinTuyaRate)`, nail gloss, the alpha-mask
  table and the top's `OverBodyMask`.

Catalog textures follow `ChaControl.GetTexture`: an asset of `"0"` means no
texture, and `_low` is appended unless `hiPoly`. Head-specific variants for a
head other than 0 are reported as unresolved. `CustomTextureCreate` render
targets are recorded as runtime composites: their sizes, full mip chains
(`useMipMap`) and Unity's `RenderTexture` sampler defaults (Bilinear, Clamp,
aniso 1; the game sets none). The iris composites also carry their full recipe
(create material, verified program, inputs and vectors; see
[native iris composites](#native-iris-composites-r1-2026-10-23)). Scene globals are not character data: the fixture
uses the harness constants that `OriginalCharacterProbe.Capture` sets —
`ChangeLineColor(1)`, `ChangeLineWidth(.307)`, `_ambientshadowG`
(0.5, 0.5, 0.5, 0.74) and `mt_ramp` row 1. Globals that no recovered method sets
read zero. Anything the native data cannot supply carries an `unresolved`
reason instead of a value.

**Supplement.** [source_binding_supplement.py](../../Tools/reverse/source_binding_supplement.py)
exports source metadata that the existing contracts omit, without pixels:
material keywords, `Texture2D` sampler/mip state, the `chara/mm_base.unity3d`
`cf_m_body` draw material and catalog rows. The #102 fixture run covered 13 bundles
plus `mm_base` and categories 2 (`cha_eyeset`), 420, 423, 424, 432 and 433. It
exported 431 materials, 1,603 textures, 1 draw material and 80 catalog rows to
`.local/r1-live-bindings/supplement.json` (`ec8bcfc5…a05f6`).

The sampler-bundle run (2026-10-23) adds the four catalog bundles behind the 8
sampler states the #102 run could not resolve: `chara/mt_hairgloss_00.unity3d`,
`chara/mt_nip_00.unity3d`, `chara/mt_body_detail_00.unity3d` and
`chara/mt_ramp_00.unity3d`. They were located, not guessed. The fixture's
textures are hair gloss row 433/0 (`cf_hair_00_01_mh`), nip 423/0
(`cw_t_nip_000`), body detail 420/0 (`cf_body_00_n`, `cf_body_00_line`) and
ramp 432/1 (`gt_ramp_01`). In all 32 `abdata/list/characustom/*.unity3d` files
of the install, categories 420, 423 and 432 are defined only in `00.unity3d`,
and 433 in `00.unity3d` plus `06.unity3d` (rows 6–8). No ID repeats. Those rows
name the four bundles as `MainAB`/`MainTexAB`. The install's
`abdata/abdata` `AssetBundleManifest` (329 bundles) lists all four with no
dependencies. They were copied read-only from `C:\Illusion\Koikatsu\abdata`
into the same relative path under `.local/reverse/rigs/source/abdata`, each
with a `vm_source.py`-format `.provenance.json`:

| Bundle | Bytes | SHA-256 |
| --- | ---: | --- |
| `chara/mt_hairgloss_00.unity3d` | 179,507 | `bccfffb854fb8e29057b7cd185c1bd51618bd735cf5dd4877c559b3c6f107253` |
| `chara/mt_nip_00.unity3d` | 389,017 | `82311edd0eefdcdf98432ee7174c2d8a9d813a6c6254bf8f908726516719520d` |
| `chara/mt_body_detail_00.unity3d` | 2,500,686 | `7032f145fb57ed082e2162f1869bdcc5ae5b9b8fbc996195a8b6cd9901675346` |
| `chara/mt_ramp_00.unity3d` | 6,049 | `931947989e635591f4c67ca2ded6399726474214f232e70b6a2416a3a359866b` |

The copy, the list files and the manifest travelled in one batched VM read
(`.local/r1-sampler-bundles/batched_fetch.py`, the same record and provenance
format as `vm_source.py fetch`; the per-file equivalent is
`vm_source.py --output .local/reverse/rigs fetch abdata/chara/<bundle>`). The six
list files already in the mirror were byte-identical to the install's. With the
four bundles the run exports 431 materials, 1,650 textures, 1 draw material and
80 catalog rows to `.local/r1-sampler-bundles/supplement.json`
(`941f4704…63d92d7`); the #102 output is a subset of it. The new rows give
`cf_hair_00_01_mh` Bilinear/Repeat/aniso 1/11 mips, `cw_t_nip_000`
Bilinear/Clamp/1/10, `cf_body_00_n` Bilinear/Repeat/1/1, `mt_body_detail_00`'s
`cf_body_00_line` Bilinear/Repeat/1/11 and `gt_ramp_01` Bilinear/Clamp/1/1.
`mm_base` holds a different `cf_body_00_line` (1 mip). The derivation looks catalog
textures up by bundle and name, so it takes the `mt_body_detail_00` copy.

```sh
cd Tools/reverse && ../../.local/reverse/unitypy-venv/bin/python source_binding_supplement.py \
  --source ../../.local/reverse/rigs/source/abdata --output ../../.local/r1-live-bindings/supplement.json \
  --bundle chara/bo_hair_b_00.unity3d --bundle chara/bo_hair_f_00.unity3d --bundle chara/co_top_00.unity3d \
  --bundle chara/co_bot_00.unity3d --bundle chara/co_shoes_00.unity3d --bundle chara/bo_head_00.unity3d \
  --bundle chara/mt_eyebrow_00.unity3d --bundle chara/mt_eyeline_up_00.unity3d --bundle chara/mt_eyeline_down_00.unity3d \
  --bundle chara/mt_nose_00.unity3d --bundle chara/mt_eye_hi_up_00.unity3d --bundle chara/mt_eye_hi_down_00.unity3d \
  --bundle chara/mt_mask_body_00.unity3d --draw-material chara/mm_base.unity3d:cf_m_body \
  --category 2 --category 420 --category 423 --category 424 --category 432 --category 433
# sampler-bundle run: the same arguments plus the four catalog bundles
cd Tools/reverse && ../../.local/reverse/unitypy-venv/bin/python source_binding_supplement.py \
  --source ../../.local/reverse/rigs/source/abdata --output ../../.local/r1-sampler-bundles/supplement.json \
  --bundle chara/bo_hair_b_00.unity3d --bundle chara/bo_hair_f_00.unity3d --bundle chara/co_top_00.unity3d \
  --bundle chara/co_bot_00.unity3d --bundle chara/co_shoes_00.unity3d --bundle chara/bo_head_00.unity3d \
  --bundle chara/mt_eyebrow_00.unity3d --bundle chara/mt_eyeline_up_00.unity3d --bundle chara/mt_eyeline_down_00.unity3d \
  --bundle chara/mt_nose_00.unity3d --bundle chara/mt_eye_hi_up_00.unity3d --bundle chara/mt_eye_hi_down_00.unity3d \
  --bundle chara/mt_mask_body_00.unity3d --bundle chara/mt_hairgloss_00.unity3d --bundle chara/mt_nip_00.unity3d \
  --bundle chara/mt_body_detail_00.unity3d --bundle chara/mt_ramp_00.unity3d --draw-material chara/mm_base.unity3d:cf_m_body \
  --category 2 --category 420 --category 423 --category 424 --category 432 --category 433
```

(In a worktree, use absolute paths to the main checkout's `.local`; the output
path must contain a `.local` component.)

**Comparison.** `SourceShaderBindingComparison` replays the probe's effective
binding for each input. For example, an unrecorded property uses the program
default and an unrecorded texture uses the Unity default. Each input then gets
one status:

- `exact`: every lane read by the program (`m_Dim`) equals the capture after
  rounding the native float32 to the capture's 7-significant-digit .NET text.
  For textures, every identity field on both sides matches: type, name, size,
  path ID.
- `withinTolerance`: each lane is within 1e-5. That is below 1/100 of an 8-bit
  step and above float32 rounding after one or two operations. Runtime
  composites matched on type and size are also counted here, because content is
  not compared. So are transforms of textures that neither side binds.
- `differs`: both values are reported.
- `missingNatively`: the native reason is reported.
- `extra`: the native side has a renderer or texture that the probe does not
  bind.

The capture's `authoredMipSource` bundle hash is attribution only:
`original_texture_mips.py` keeps one of several byte-identical copies, so
`liquid01_t`/`_n` name `bo_head_00` although the body binds `mm_base`'s copy.
A mismatch is noted, not counted. Sampler state (filter, wrap, aniso, mip
levels) is compared for every bound texture. Each finding names both sources,
and gaps are grouped by cause.

```sh
swift build --package-path Packages/Engine --product ikkoku-inspect
Packages/Engine/.build/debug/ikkoku-inspect shader-bindings .local/r1c/probe/fixture-card.png \
  .local/reverse/maker-library/library.json .local/reverse/rigs/head-materials/contract.json \
  .local/r1c/probe/shaders .local/r1c/probe/frame-mips.json \
  --supplement .local/r1-live-bindings/supplement.json > .local/r1-live-bindings/shader-bindings.json
# the same comparison with the sampler-bundle supplement
Packages/Engine/.build/debug/ikkoku-inspect shader-bindings .local/r1c/probe/fixture-card.png \
  .local/reverse/maker-library/library.json .local/reverse/rigs/head-materials/contract.json \
  .local/r1c/probe/shaders .local/r1c/probe/frame-mips.json \
  --supplement .local/r1-sampler-bundles/supplement.json > .local/r1-sampler-bundles/shader-bindings-after.json
```

The gated Engine test `sourceShaderBindingsMatchTheControlledOriginalFrame`
(private-source lane: `IKKOKU_SHADER_BINDING_PROBE=<.local/r1c/probe>`,
`IKKOKU_MAKER_LIBRARY`, `IKKOKU_HEAD_MATERIAL_CONTRACT`,
`IKKOKU_SHADER_BINDING_SUPPLEMENT`) pins the numbers below. It checks the
`frame-mips.json` hash and adds two controls. In the capture-side mutation, one
hair `_Color` lane +0.01 gives exactly 1 `differs`. Without the supplement, the
derivation reports its gaps instead of guessing. The test accepts either
supplement and pins each one's numbers. If the supplement lists all four sampler
bundles, it expects the totals in the table and 66 of 66 samplers exact. If it
lists none of them (the #102 supplement), it expects 567/29/0/16/1 and 8
samplers missing for the "sampler state" cause. A supplement that holds only
some of the four fails. Mutation control for the sampler rows: a copy of the
new supplement with `gt_ramp_01`'s wrap changed from Clamp to Repeat
(`.local/r1-sampler-bundles/controls/`) gives 574 exact and 1 `differs`
(`_RampG` wrap). With it the gated test fails with 5 issues.

Inputs: `frame-mips.json` `13bd11c2…66f039`, card `4b892fc4…ce53c65`, library
`d898fea1…cbb609`, head contract `e77ca3f7…c39393` and supplement
`941f4704…63d92d7` (sampler-bundle run; the #102 supplement was
`ec8bcfc5…a05f6`). Native bindings against the authored-mip capture:

| Family | Exact | Within tolerance | Differs | Missing natively | Extra | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| global | 8 | 0 | 0 | 2 | 0 | 10 |
| main_hair | 29 | 3 | 0 | 0 | 0 | 32 |
| main_hair_front | 87 | 9 | 0 | 0 | 0 | 96 |
| main_item | 73 | 2 | 0 | 0 | 0 | 75 |
| main_opaque | 147 | 3 | 0 | 0 | 0 | 150 |
| main_skin | 128 | 3 | 0 | 0 | 0 | 131 |
| toon_eye_lod0 | 34 | 4 | 0 | 6 | 0 | 44 |
| toon_eyew_lod0 | 54 | 5 | 0 | 0 | 1 | 60 |
| toon_glasses_lod0 / toon_textureanimation / toon_nose_lod0 | 3 / 3 / 9 | 0 | 0 | 0 | 0 | 3 / 3 / 9 |
| **Overall** | **575** | **29** | **0** | **8** | **1** | **613** |
| Overall with the #102 supplement (before) | 567 | 29 | 0 | 16 | 1 | 613 |

By category, shader (20), queue (20), keywords (20) and pass state (31) are all
exact. Vectors are 191 exact, 18 within tolerance and 2 missing, with the largest
|Δ| 1.2e-7 from float32 colour rounding. Textures are 100 exact and 9
within-tolerance composites. Texture transforms are 100 exact, 2 within
tolerance and 6 missing; samplers are 66 of 66 exact (58 exact and 8 missing
with the #102 supplement). The four bundles closed one global sampler
(`_RampG`), one in `main_hair`, three in `main_hair_front` and three in
`main_skin`. Their 5 texture findings were already exact by type and name. They
now also match by width and height (1024², 512², 8², 1024² and 256×4). With the
#102 supplement the generated-mip `frame.json` (`9aa4de39…bcc750`) gave the same
totals; it was not rerun with the new supplement. Without the supplement
the same derivation reports 456 exact, 27 within tolerance, 2 differing, 114
missing and 1 extra of 600 (fewer inputs, because the body shader is unknown).
The step-4 fixes closed `cha_eyeset` (eye pattern, gag eyes, eyeshadow alpha), `mt_hairgloss`,
`mt_nip`, `mt_underhair`, `mt_body_detail`, `mt_ramp`, the `cf_m_body` draw
material (36 inputs), keywords (library material tree, then supplement),
sampler state including render-target defaults, and the body alpha-mask
identity. The 2 former `differs` were `_expression_ST` on the eyes: the probe's
`[1, 1, 0, 0]` convention for an empty slot versus the prefab transform. They
became within tolerance once the eye pattern established that `_expression` is
empty on both sides.

Remaining gaps by cause, none guessed. The 8 sampler states that the #102
supplement left missing (`mt_hairgloss_00`, `mt_nip_00`, `mt_body_detail_00`
and `mt_ramp_00` `_RampG`) are closed by the sampler-bundle run above:

- 6 `EyeLookMaterialControll` iris/highlight offsets: they depend on gaze, so
  they need the Studio eye-look runtime rather than the card alone. The capture
  shows x ±0.02.
- `_Time`: the frame clock is a playback input.
- `_RampG_ST`: an unset global transform, which the probe binds as
  `[1, 1, 0, 0]` by convention; Unity's value is unverified.
- 1 `extra`: `cf_O_eyeline` material slot 1. It is beyond the mesh's single
  submesh, so Unity draws it over the last submesh, but the probe's
  `materials.prefix(submeshes)` skipped it. This was a probe gap, not a native
  one, and the gap fixes below close it.

**Gap fixes (2026-10-22).** Two of these gaps are closed.

- **Eye-look offsets.** `derive(…, eyeLook:)` takes the six eye-look
  transforms. `SourceStudioIrisRendering.bindingEyeLook` computes them from a
  Studio look state: the exported `bo_head_00` eye settings, the card's
  pupil/highlight fields and the per-eye iris-shift rates (resting `(0, 0)` by
  default). The CLI takes `--eye-look <studio-look-settings.json>
  [--eye-look-rates <left-h>,<right-h>,<v>]`.
- **Extra material slots.** The probe now draws a material slot beyond the
  submesh count over the last submesh, as Unity does
  (`TranslatedDraw.slot`).

The binding counts move as follows:

| Bindings | Exact | Within tolerance | Differs | Missing natively | Extra |
| --- | ---: | ---: | ---: | ---: | ---: |
| Before | 567 | 29 | 0 | 16 | 1 |
| With the fixture look settings (`.local/stt07h/studio-look-settings.json`) | 567 | 35 | 0 | 10 | 1 |
| With the eyeline slot drawn | 568 | 29 | 0 | 16 | 0 |
| Both | 568 | 35 | 0 | 10 | 0 |
| Sampler-bundle supplement, eyeline slot drawn | 576 | 29 | 0 | 8 | 0 |
| Sampler-bundle supplement, both | 576 | 35 | 0 | 2 | 0 |

The first four rows use the #102 supplement. The last two use the sampler-bundle
supplement above, after merging `main` `b0b8cb6`. The gated
`sourceShaderBindingsMatchTheControlledOriginalFrame` pins the eyeline-slot
row of whichever supplement is supplied, and the "both" row when
`IKKOKU_STUDIO_LOOK_SETTINGS` is also set (the private-source lane now declares
it).
The source-normal frozen render with the extra eyeline slot keeps the
silhouette at 44 px / IoU 0.9995552051. The character colour goes from mean
0.20886 / p99 4 / max 105 to 0.18762 / 4 / 55. `main_skin` goes from 13,516 px,
mean 0.2019, max 105 to 13,488 px, 0.0550, max 10, because the slot covers the
face pixels the original's eyeline draws. `toon_eyew_lod0` grows from 303 to
327 px. Native-bound frames with the look settings give 0.18762 / p99 4.
Hair is unchanged: p99 24 / 22. With the sampler-bundle supplement, the
remaining binding gaps are `_Time` and `_RampG_ST`. Without a look state, the
eye-look offsets are still missing. The live measurements below used the #102
supplement. On the merged build, the gated live check passes with the
sampler-bundle supplement, at character mean 0.1913, p99 4. The native texture
store used for that measurement did not hold the four bundles' textures, so its
result remained 1 live and 19 toon.

**Proof of concept (step 5, with the #102 supplement).** `--write-frame <file>` writes a copy of the
capture frame next to it. In that copy, every resolved native value replaces
the bound value: 201 vectors, 58 transforms, 19 queues, 49 samplers and 6
globals. A slot that the native recipe leaves empty is removed. 98 texture
slots are confirmed (matching asset identity, or empty on both sides), and the
9 composites keep their captured content. Unresolved inputs keep the capture
value and are counted (13). Geometry, camera, light and pixels stay the capture's.
`SourceShaderBindingFrameSubstitution` implements this. A Debug build at
`9c0be49` ran three cases on the source-normal frame
`.local/r1-normal/rerun-2026-10-17/candidate-mips/frame-with-source-normals.json`
(`1b0b0f21…f34e690`):

| Case | Silhouette | Color (full character) | Result |
| --- | --- | --- | --- |
| Capture-bound (baseline) | 44 px, IoU 0.9995552051 | mean 0.20886, p99 4 | Both gates pass |
| Native-bound (`frame-native-bindings.json`, `91c73484…732131e`) | 44 px, IoU 0.9995552051 | mean 0.20889, p99 4 | Both gates pass; per-family p99 unchanged |
| Mutation control: native frame, `_linewidthG` ×2 | 915 px, IoU 0.9907607 | mean 0.27399, p99 5 | Both fail — the probe consumes the substituted file |

24 substituted values differ from the parsed capture text, by at most 1.2e-7.
All are colour properties (hair, face, eyebrow, eyeline, tooth, tongue, body
and clothes) that the capture printed at 7 digits. The translated
render differs from the baseline at 3 pixels by ≤3 bytes, inside the documented
run-to-run variation (≤4 pixels, ≤4 bytes). Coverage, geometry and production
toon images are identical. Per-family hair color still fails (p99 24/22) in both
runs, and `passesAllGates` stays false because of the production toon path. No
gate threshold changed.

**Limits.** One controlled female character (coordinate 0, hiPoly, head 0) on
one frozen frame. Body renderers other than `o_body_a` are not enumerated.
`N_EyeBase`/`N_Hitomi` visibility for non-zero eye patterns is not modelled.
`Config.EtcData.hohoAka` and a non-zero `hohoAkaRate` are reported as
unresolved, and composite content is not compared. Other heads, hair, clothes
and accessories, mods and male cards need their own converted evidence. Private
evidence (both comparison runs, the frame.json run, the PoC folders, logs, frame
and render diffs, and the scripts) is in `.local/r1-live-bindings/`. The
sampler-bundle run's evidence is in `.local/r1-sampler-bundles/`: the copy
manifest and provenance (`vm-copy/copy-manifest.json`), the install's list files
and `abdata` manifest, the supplement, before/after comparisons and the wrap
mutation control. The PoC substitution was not rerun with the new supplement.

### Live source-shader path (R1/CMT-04, opt-in, 2026-10-22)

An opt-in path draws converted source characters with the translated original
programs instead of the native toon shaders. Inputs come from the native binding
set above, the live deformed vertices, and the live camera and light. It is OFF by
default, and the toon path stays the production renderer. On one controlled
fixture it meets the frozen probe's gates with capture texture pixels (numbers
below). The initial native texture store drew one material; the completed asset
store draws 11 of 20 slots ([native asset completion](#native-asset-completion-r1-137-2026-10-23)),
with natively composed irises 13 of 20 ([native iris composites](#native-iris-composites-r1-2026-10-23)),
and with the eye whites 15 of 20 ([native eye-white composites](#native-eye-white-composites-r1-2026-10-23)).
This is not a production-parity claim.

**Opt-in and inputs.** `IKKOKU_LIVE_SOURCE_SHADERS=1` starts the app with the
path on. In the Studio, **View ▸ Live Source Shaders (Experimental)** toggles it.
The Studio inspector's "Live source shaders" group lists, per character, the live,
toon and hidden counts, each fallback with its reason, and the renderer's own
render-time fallbacks. `SourceShaderLiveConfiguration` reads the inputs:

| Variable | Input |
| --- | --- |
| `IKKOKU_LIVE_SOURCE_PROGRAMS` | translated programs (`<family>[_outline]/program.json` + `source.metal`; the R1 probe's `shaders/`) |
| `IKKOKU_LIVE_SOURCE_TEXTURES` | native texture store `manifest.json` ([source_texture_store.py](../../Tools/reverse/source_texture_store.py)) |
| `IKKOKU_LIVE_SOURCE_STREAMS` | source vertex streams `manifest.json` ([source_vertex_streams.py](../../Tools/reverse/source_vertex_streams.py)); optional |
| `IKKOKU_SHADER_BINDING_SUPPLEMENT` | binding supplement (keywords, sampler state, body draw material) |
| `IKKOKU_HEAD_MATERIAL_CONTRACT` | head material contract; default `head-materials/contract.json` beside the source avatar |
| `IKKOKU_MAKER_LIBRARY` | Maker library (else the card's own library lookup) |

A missing required input keeps every character on toon, with the reason. After an
autocapture, `IKKOKU_LIVE_SOURCE_REPORT=<json>` writes the Studio report, and
Studio benchmarks embed it as `liveSourceShaders`.

**Programs and pipelines.** `TranslatedSourceProgram` (Renderer) parses
`program.json` and checks the hash of `source.metal`. It records constant
buffers, textures, vertex inputs, properties and the pass state (blend, culling,
stencil, ZWrite); unknown semantics or states are rejected. One
`TranslatedSourcePipelineCache` per `ResourceStore` (`translatedPipelines`)
parses each program once. It compiles one pipeline plus depth/stencil state per
program identity (path and source hash), target (colour format, depth/stencil
format, sample count) and depth mode. The frozen-frame probe now encodes through
the same parser, packer (`TranslatedSourceProgram.pack`) and cache.

**Materials.** `SourceShaderLiveMaterial.resolve` turns one binding-set renderer
slot into bind-ready values. It takes the outline program before the forward
one and reads every vector the programs use. Colour properties are linearized as
the probe does, `<texture>_ST` comes from the binding scale/offset, and globals
come from the binding set. Each texture comes with its sampler state from a
`SourceShaderLiveTextureProvider`, and an empty slot uses the Unity default
texture. Resolution is all or nothing: any unresolved input throws a reason, and
the slot keeps its toon draw. Unresolved inputs include a vector, a global, the
render queue, a texture's pixels or sampler state, a missing program, a
non-Shader-Forge shader, or a builtin the path does not compute
(`_ProjectionParams`, other `unity_*`, `glstate_*`). Only `_RampG_ST` is bound by
a documented convention (`[1, 1, 0, 0]`, as in the probe). Each material using it
lists it, so nothing is substituted silently.

**Per-frame inputs.** `SourceShaderLiveEncoder` converts each live item's vertices
with a compute kernel, once per vertex source and register layout. The output is
the program's `SourceInput` registers:

- POSITION: the deform output with Z mirrored into Unity's basis.
- NORMAL: the rest normal plus morph normal deltas, skinned linearly by the same
  palette. It is not renormalized, which keeps the skinned magnitude the outline
  programs extrude by (#96).
- TANGENT: the deformed tangent, normalized, with the rest handedness.
- TEXCOORD0: V flipped back to Unity's convention.
- TEXCOORD1/2: the converted mesh's set when it carries one. A converted mesh
  without the set aliases UV0, so the source stream is used instead; without a
  stream the item stays toon.
- TEXCOORD3 and COLOR: the source stream.

Matrices are `unity_ObjectToWorld = B·M·B` and `unity_MatrixVP = P·V·B`, with
`B = diag(1, 1, −1)`. The clip position therefore equals the native one, and live
draws depth-test against native draws. Builtins:

- `_WorldSpaceCameraPos = B·eye`.
- `_WorldSpaceLightPos0 = (−B·d, 0)`, where d is the direction the main light
  travels.
- `_LightColor0 = linear(colour)·intensity`.
- `_ScreenParams` from the viewport.
- `unity_WorldTransformParams.w` from the model determinant.
- `_Time` from the frame clock.

**Assembly and fallbacks.** `SourceShaderLiveAssembly` (Character) derives the
card's binding set once and resolves every slot. In the Studio, scene globals
stay unresolved: CharaStudio's `SceneInfo` → `Shader.SetGlobal*` mapping is not
recovered, so the harness constants must not stand in. The binding set follows
the card's saved wear. When a Studio document changes a character's clothes
state or accessory visibility (ST-C03), that character stays toon and the reason
is reported. Each frame, the assembly marks the matching `RenderItem`s
(`RenderItem.sourceShader`). Matching uses the source
renderer name and submesh in the native mesh name (`<part>/<renderer>/<submesh>`),
and the n-th native pass of an item maps to the n-th visible material slot.
Renderers the source disables, and ShadowCaster-only slots, are hidden. Every
other case keeps the toon draw and is reported:

- an ambiguous mapping;
- no source renderer;
- an unresolved slot;
- a missing or ambiguous vertex stream.

Source slots that no native item draws are listed as unmatched. At render time,
the renderer returns an item to its toon draw, listed in
`Renderer.lastSourceShaderLive`, when it has no deformation this frame, its stream
vertex count differs, or it has an unsupported input or a UV1/UV2 that would alias
UV0. It does the same for every live item of the frame when the stencil
pipelines or the MSAA depth-stencil target cannot be created. Both are resolved
while the frame is prepared, before anything is encoded. A draw that fails to
encode is not drawn and is listed too.

**Frame graph.** Live items leave the native opaque and transparent lists. The
main pass draws them after native opaques and before native transparents, in
source queue order: outline before forward, then by character, then in the
binding set's renderer order. Unity's per-queue distance sort is not reproduced,
which is the probe's R1 rule. A frame with live draws renders its main pass into
a memoryless MSAA `depth32Float_stencil8` target, using stencil variants of the
native pipelines, because the hair-front and eye programs test and write stencil
reference 2. A frame without live draws keeps the depth-only attachment and
pipelines. Shadows and picking keep the native draws.

`Renderer.captureSourceShaderLive` is the validation capture. It renders only the
live draws (optionally one family set) into the probe's 8-bit sRGB,
depth+stencil, no-MSAA target. Its output is what `compare_original_frame.py`
gates as `native-translated*.png`. `captureSourceGeometry` renders the geometry
and depth-normal encodings of the live vertices.

**Vertex streams.** The converted rigs carry no UV3 or COLOR, and the converted
hair rigs no UV1. `source_vertex_streams.py` exports `m_UV1`/`m_UV2`/`m_UV3`/`m_Colors`
of named source renderers in source vertex order (colours are Color32 bytes ÷ 255).
Hair bundles reuse renderer names across prefabs with different meshes, so
`--prefab` scopes a bundle to the prefabs the rigs record as `sourcePrefab`.
`SourceVertexStreams.load` hash-checks schema 1–2 manifests. A channel the source
mesh lacks is bound as the capture fixture's value (UV zero, COLOR white). Each
material that uses such a value lists it as a convention, because Unity's
missing-channel value is not verified. Against the R1 capture's frozen meshes,
every exported channel matches with maximum error 0.0:

- UV1: the four hair meshes, `cf_O_face`, `cf_Ohitomi_L02`/`R02` and `o_body_a`;
- UV2: face, eyes and body;
- UV3: face and body;
- colours: body.

The hair meshes have no UV2, and the capture's UV2 for them is all zero.

```sh
cd Tools/reverse && ../../.local/reverse/unitypy-venv/bin/python source_vertex_streams.py \
  ../../.local/r1-live-b/store/streams-v2 \
  --bundle ../../.local/reverse/rigs/source/abdata/chara/bo_head_00.unity3d --bundle ../../.local/reverse/rigs/source/abdata/chara/oo_base.unity3d \
  --bundle ../../.local/reverse/rigs/source/abdata/chara/mm_base.unity3d --bundle ../../.local/reverse/rigs/source/abdata/chara/bo_hair_b_00.unity3d \
  --bundle ../../.local/reverse/rigs/source/abdata/chara/bo_hair_f_00.unity3d \
  --mesh o_body_a --mesh cf_O_face --mesh cf_Ohitomi_L02 --mesh cf_Ohitomi_R02 --mesh cf_hair_b_03_00 \
  --mesh cf_hair_idol_hair_f_00 --mesh cf_hair_idol_hair_f_01 --mesh cf_hair_idol_hair_f_02 \
  --prefab assets/illusion/assetbundle/chara/hair/00/bo_hair_b_00/p_cf_hair_b_03/p_cf_hair_b_03.prefab \
  --prefab assets/illusion/assetbundle/chara/hair/00/bo_hair_f_00/p_cf_hair_f_01/p_cf_hair_f_01.prefab \
  --verify-frame ../../.local/r1c/probe/frame-mips.json
```

**Texture store.** `source_texture_store.py` decodes every `Texture2D` identity
of a binding set from the local bundles. It keeps the authored mips and
linearizes sRGB textures, then writes a hash-checked half-float store; the
texture's own filter, wrap and aniso settings are recorded. Runtime composites
are excluded; unavailable asset identities are listed with their reasons.
`SourceShaderTextureStore`, the production provider, never substitutes. On the
initial fixture store it held 42 textures. Its 66 base-level comparisons with
same-name capture textures had a maximum error of 0.0127 (linear, half float) and a mean
of at most 0.0011. Five identities were unavailable because their bundles were
not local then: `mt_ramp_00`/`gt_ramp_01`, `mt_hairgloss_00`/`cf_hair_00_01_mh`,
`mt_nip_00` and two `mt_body_detail_00` textures.
`SourceShaderCaptureTextureProvider` is for validation only. It takes capture
pixels whose texture type, name and size match the native identity (the
substitution rule of the binding-set proof of concept).

**Measurement: controlled fixture.** The R1 fixture card is drawn on the LIVE
native rig: the source avatar, card shape and static ABMX, the fitted CharaStudio
hand pose from the [native pose gate](#native-pose-gate), and the expression
contract defaults. Bindings are native. The view is the original capture's
camera, main light, effects and `_Time.y`, and the scene globals are the capture
harness constants (`originalCharacterProbeHarness`). The capture's frozen meshes
are not drawn; it supplies only the view. `IKKOKU_LIVE_SOURCE_PROBE=<frame-mips.json>`
runs it in the app (`SourceShaderLiveFixtureProbe`, Studio module). The run
writes the comparator's `native-*.png` files, `live-report.json` (every input
with its hash, binding provenance, per-material resolution and attach lines) and
toon and live benchmarks:

```sh
IKKOKU_SOURCE_AVATAR=$L/reverse/rigs/source-avatar.json IKKOKU_SOURCE_CARD=$L/r1c/probe/fixture-card.png \
IKKOKU_STUDIO_HAND_POSE=$L/stt07d/studio-hand-fitted.json IKKOKU_STUDIO_LOOK_SETTINGS=$L/stt07h/studio-look-settings.json \
IKKOKU_SOURCE_EXPRESSION=defaults IKKOKU_LIVE_SOURCE_PROGRAMS=$L/r1c/probe/shaders \
IKKOKU_LIVE_SOURCE_TEXTURES=$L/r1-live-b/store/textures/manifest.json IKKOKU_LIVE_SOURCE_STREAMS=$L/r1-live-b/store/streams-v2/manifest.json \
IKKOKU_SHADER_BINDING_SUPPLEMENT=$L/r1-live-bindings/supplement.json IKKOKU_MAKER_LIBRARY=$L/reverse/maker-library/library.json \
IKKOKU_HEAD_MATERIAL_CONTRACT=$L/reverse/rigs/head-materials/contract.json \
IKKOKU_LIVE_SOURCE_PROBE=<run>/frame-mips.json IKKOKU_LIVE_SOURCE_OUTPUT=<run> IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER=capture \
  .local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_original_frame.py <run>
```

`$L` is the main checkout's `.local`. `<run>` links `frame-mips.json`,
`frame.json` and the `original-*.png` renders of `.local/r1c/probe`. Inputs:
capture frame `13bd11c2…66f039`, avatar `e90f6a24…e9ab5`, card
`4b892fc4…ce53c65`, hand pose `0320580d…eec33`, look settings `13e7260f…be9ab`,
texture store manifest `6b950538…c8ce2`, stream manifest `df8cfb0d…366f7`.

`IKKOKU_LIVE_SOURCE_MAKER_WEAR=1` (ST-C03 third slice) draws the card through
the Studio wear assembly instead: `prepare(wear: true)` with its half-state
meshes and indoor shoes, the saved clothes state and `shoesType` evaluated by
`SourceStudioWearLayout.saved` (hidden parts and body mask), and the Studio
appearance. A capture of a half-state card then compares its half-state
meshes; see [half-state meshes](studio/scene-editing.md#half-state-meshes-and-indoor-shoes-st-c03-third-slice).

With capture texture pixels, all 20 source slots draw live. The double tooth is
hidden (`ChaControl.VisibleDoubleTooth`). There are no fallbacks, unmatched
slots or render-time fallbacks. `compare_original_frame.py` reports the
following, with thresholds unchanged:

| Gate | Live fixture | Frozen probe, same bindings (step 1) |
| --- | --- | --- |
| Geometry (live vertices) | IoU 1.0, 0 of 99,750 px differ — pass | (frozen geometry) |
| Depth-normals | mean 4.5e-7 m, p99 0, max 1.54 mm; normal p99 2 — pass | — |
| translatedCharacter | silhouette 2 px (original-only, `main_hair`), IoU 0.99998; colour mean 0.1916, p99 4, max 237 — pass | 44 px, IoU 0.9995552; mean 0.18762, p99 4, max 55 — pass |
| translatedGarments | 0 px; mean 0.119, p99 2 — pass | — |
| Production colour (`native-color.png`: main pass, HDR, 4×MSAA, post) | mean 2.256, p99 69 — fail | toon: fail |

| Family (frontmost in both) | Pixels | Mean | p99 | Max | Gate |
| --- | ---: | ---: | ---: | ---: | --- |
| `main_opaque` | 76,556 | 0.112 | 1 | 50 | pass |
| `main_skin` | 13,484 | 0.055 | 1 | 10 | pass |
| `toon_eye_lod0` | 368 | 0.009 | 0 | 1 | pass |
| `toon_eyew_lod0` | 327 | 0.614 | 1 | 237 | pass |
| `main_hair` | 3,531 | 0.998 | 24 | 55 | fail (frozen probe: 0.999 / 24) |
| `main_hair_front` | 6,154 | 0.841 | 22 | 45 | fail (frozen probe: 0.845 / 22) |
| `main_item`, `toon_nose_lod0` | 0 | — | — | — | never frontmost |

A rerun on the merged build `51b457e` (`m1-capture-v4-merged`) gave the same
result for every gate. The character mean was 0.1915 with p99 4 and the same
2 silhouette pixels. Family pixel counts moved by at most 12 and means by at
most 0.0004. The live `main_hair` and `main_opaque` renders vary slightly from
run to run, as they do in the frozen probe.

The hair families fail by the same amount as in the frozen probe, so their
residual is not caused by live inputs. In `toon_eyew_lod0`, a single pixel
exceeds 4 bytes. The geometry and depth gates are the first live-vertex
comparison of this card with the original: native pose, native bindings and the
default expression.
The production main pass with the same live draws fails the colour gate. Over
the translated silhouette, 4,779 pixels differ by more than 4 bytes. Of these,
4,538 lie on colour or alpha edges of the original image, where an 8-neighbour
differs by more than 16 or the alpha changes. The 86,238 interior pixels have a
mean of 0.179 and a p99 of 1. The difference is therefore MSAA resolve and
post-processing at edges, not shading. Two inputs were needed to reach these
numbers. Without the source UV1 stream, hair aliased UV0 (character mean 7.65,
p99 193). Without the default expression, the eyelid geometry differed from the
capture (character mean 0.420, p99 6).

With the initial native texture store, 1 slot draws live (`cf_O_noseline`,
`toon_nose_lod0`) and 19 stay toon, each with its reason:

- 9 runtime composites that are not composed natively: the body and face
  `CustomTextureControl` textures, the `ctCreateEyeW` eye whites,
  `ctCreateEyeL`/`R` irises and three `ChangeCustomClothes` garments;
- 6 `_RampG` (`gt_ramp_01`) slots;
- 4 hair `_HairGloss` slots.

The validation capture then draws only the nose, so the character gate fails by
construction. The asset-backed gaps are closed below; natively composed textures
remain a separate step.

**Measurement: Studio scene.** `koikatu_cs0002591.png`
(`IKKOKU_STUDIO_SCENARIO_SCENE`) was captured with `IKKOKU_LIVE_SOURCE_SHADERS=1`
and the inputs above, without look settings. Six source characters loaded with
no crash. 6 slots draw live (`cf_O_noseline` per character); the renderer
reported 6 draws and no render-time fallbacks. 11 items are hidden: 6 double
teeth, and 5 loafers hidden by `clothesState`/`shoesType`. 109 slots stay toon:

| Reason | Slots |
| --- | ---: |
| `_ambientshadowG` unresolved: CharaStudio `SceneInfo` → `Shader.SetGlobal` mapping not recovered | 36 |
| No source renderer in the binding set: the native preview draws the converted avatar's default hair and clothes for selections that are not converted | 36 |
| `_linewidthG` unresolved (same mapping) | 25 |
| `_MainTex_ST`: `EyeLookMaterialControll` offsets not evaluated (no look settings supplied) | 12 |

These numbers were taken before #125 (Studio clothes state). The native preview
now applies the scene's clothes state itself, so the loafers are no longer
drawn. In one ON run on `f46f80d` with the same inputs, 6 slots draw live, 99
stay toon and 6 are hidden (the double teeth only). There are no unmatched
slots and no render-time fallbacks. The reasons are:

| Reason | Slots |
| --- | ---: |
| `_ambientshadowG` unresolved | 36 |
| No source renderer in the binding set | 26 |
| `_linewidthG` unresolved | 25 |
| `_MainTex_ST` eye-look offsets | 12 |

That run drew 105 visible items and 284,500 triangles. CPU encode was 9.59 ms,
GPU 1.351 ms and completion 11.58 ms. It is a single run, not a median, and it
has no paired OFF run.

The frame times are medians over runs of each run's p50, on an M2 Ultra at
1200×1600 with 60 measured frames (`IKKOKU_BENCHMARK_FRAMES=60`).
Opt-in OFF: 3 runs, 126 visible items, 346,590 triangles. CPU encode 15.04 ms,
GPU 1.447 ms, completion 17.01 ms. Opt-in ON: 4 runs, 115 visible items (the 11
hidden items are not drawn), 324,890 triangles. CPU encode 13.76 ms, GPU
1.452 ms, completion 15.83 ms. On the fixture at 768×1024 (20 frames), 20 live
draws took CPU 3.99 ms and GPU 1.027 ms (p95 1.101). The toon path took 2.50 ms
and 0.317 ms. With the native store (1 live draw): 2.36 / 0.323 ms against toon
2.38 / 0.306 ms. Pipelines compile on first use: once per program, target and
depth mode.

**Regression (opt-in OFF).** The `IKKOKU_AUTOCAPTURE` images of three cases were
byte-identical between Debug builds of `main` and this branch. The comparison was
repeated after each merge of `main`:

| `main` | Branch |
| --- | --- |
| `4263de3` | `e6ec395` (the live build) |
| `9caa3f3` (after #121–#124) | `51b457e` |
| `8d83f01` (after #125) | `28eba51` |
| `b0b8cb6` (after #128, #130) | `f46f80d` |
| `d9684e8` (after #129) | `685b93e` |

Each case was launched with only its own `IKKOKU_*` variables:

- `koikatu_cs0002591.png`: `a0dc50f4…`. From `8d83f01` on it is `caed346e…`
  on both sides, because #125 applies the scene's clothes state.
- the rig and fixture card: `9d973e21…`;
- `synthetic-current.png`: `6837cd63…`. Since #133, with a Maker library
  present, this capture exits 1. The scene's only character has no hair
  `parts` array that `SourceMakerLibrary` supports ("Unsupported hair part
  array."), so it is always retained without rendering, and an automated
  scene capture whose characters all fail exits 1. Run this control with
  `IKKOKU_MAKER_LIBRARY=none`; the character then renders through the bundled
  native body, and `0c51ca1` still gives `6837cd63…`.

The frozen probe's deterministic images (`--families`,
`SWIFT_DETERMINISTIC_HASHING=1`, 3 runs per build) were identical between the
step-1 build and the live build: colour, depth, geometry, hair front, item, skin,
eye and nose. Against `main`, only `toon_eyew_lod0` differs, from the intended
step-1 eyeline slot. `main_hair`, `main_opaque`, `native-translated` and
`native-main_opaque` vary between runs of one build; their hash sets overlap
across builds.

**Tests.** `SourceShaderLiveTests.swift` uses synthetic programs to cover:

- the pipeline cache: once per program, target and pass state, plus the source
  identity check;
- the register layout;
- the Unity-basis builtins and matrices;
- all-or-nothing material resolution, with every fallback reason;
- the vertex kernel: source layout, skinned normal magnitude, UV1/UV2
  native/stream/zero, UV3/COLOR defaults;
- validation-capture pixels, including the refusal to alias UV0;
- a production main-pass live draw that leaves later toon frames unchanged;
- an injected depth-stencil target failure, after which the live item is drawn
  toon (pixels equal to the toon frame) with one reported fallback, plus the
  same frame drawing live once the target is available;
- stream manifests, assembly mapping and configuration.

The gated `liveSourceShadersMeetTheControlledOriginalFrameGates` repeats the
fixture measurement in the Engine suite. It implements the comparator's
silhouette and colour metrics in Swift. It requires the gates above (hair
bounded at its frozen-probe level) and, since #137, the 11-live/9-toon complete
asset-store result below. The
private-source lane declares its fixtures: `IKKOKU_SHADER_BINDING_PROBE`,
`IKKOKU_SOURCE_AVATAR`, `IKKOKU_MAKER_LIBRARY`, `IKKOKU_HEAD_MATERIAL_CONTRACT`,
`IKKOKU_SHADER_BINDING_SUPPLEMENT`, `IKKOKU_STUDIO_HAND_POSE`,
`IKKOKU_STUDIO_LOOK_SETTINGS`, `IKKOKU_LIVE_SOURCE_STREAMS`,
`IKKOKU_LIVE_SOURCE_TEXTURES` and (since the eye-white composites)
`IKKOKU_COMPOSITE_COLOUR_PROBE`. `Tools/reverse/test_source_live_inputs.py` covers
the exporters' pure parts.

**Limits.** One controlled card, one pose and one frame. Live drawing needs
runtime-composite pixels the native store does not yet hold. The ramp and gloss
asset gaps are closed by #137 below. Studio scene globals are unresolved. Unity's per-queue
distance sort, keyword variants and the ShadowCaster pass are not reproduced.
Live items cast native shadows. The hair residual (p99 24/22) and the production
edge difference remain. Private evidence (runs, comparisons, the stores, frozen
app builds and scripts) is in `.local/r1-live-b/`.

### Native asset completion (R1, #137, 2026-10-23)

The four bundles recovered in the sampler investigation now supply the native
texture store. It contains **47 assets, zero unavailable asset identities** and
resolves **11 of 20 controlled-fixture slots**, up from 1. The six ramp users
(brows, teeth, three eyeline slots and tongue) and four hair-gloss users draw
live. The nine body, face, eye and garment composites still fall back with their
explicit reason. No captured texture pixels are used by this provider. Studio's
unrecovered scene globals remain separate blockers; this is a controlled-card
coverage result, not a Studio coverage or production-parity claim.

`source_texture_store.py` validates every requested asset identity, including
conflicting requests for the same asset, against the bundle hash, serialized
file, path ID/name, dimensions and mip count. It records the actual serialized
file and the binding report's SHA-256. `--require-complete` exits nonzero if any
asset is unavailable; runtime composites are outside that check. The store keeps
the authored mip chain and sampler settings and is built offline:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/source_texture_store.py \
  "$L/r1-sampler-bundles/shader-bindings-after.json" "$R/textures" \
  --bundle-root "$L/reverse/rigs/source/abdata" \
  --verify-frame "$L/r1c/probe/frame-mips.json" --require-complete
```

Here `$L` is the primary checkout's `.local`, and `$R` is
`$L/codex-renderer-maker-models-2026-10-23/renderer`. Generated texture pixels stay
private. Set `IKKOKU_LIVE_SOURCE_TEXTURES=$R/textures/manifest.json` when running
the app or the gated `liveSourceShadersMeetTheControlledOriginalFrameGates` test;
that test now requires the complete asset store. The retained run's raw manifest
SHA-256 (including conversion paths) is
`faf4de5026eaa26f627c7429011e2e515be128136874c08e0c4cac18f8c71160`.
The test pins 47 entries, zero unavailable assets and a canonical content hash
(`b41ca624…2f73b4`) covering the entries and source binding report hash while
excluding machine-specific roots and `source.file` paths.

There are 71 base-level comparisons with retained same-name/size GPU readbacks:
maximum error 0.0126953, maximum mean error 0.00113748 (linear half float).
`gt_ramp_01` is exact; `cf_hair_00_01_mh` has mean 0.00000315 and max 0.00392151.
The verifier also compares 430 retained lower levels, explicitly labelled as
offline authored-mip decodes rather than independent GPU observations, and lists
47 level references without retained pixels. The new gloss, body-line and nipple
assets account for 29 of those missing lower levels. Their authored mip counts,
dimensions, byte counts and hashes are checked, but their lower mip pixels have
no independent GPU oracle in this run. Capture frame and new bundle hashes are
unchanged from the earlier sampler investigation and are retained in each report.
The JSON summary separates `independentlyComparedMipLevels` (71 GPU base
readbacks), `offlineComparedMipLevels` (430), and `uncomparedMipLevels` (47).
`unverifiedMipLevels` includes every level without an independent GPU reference,
including the offline comparisons; it does not count same-decoder agreement as
independent validation.

The runtime rejects zero/excessive mip counts, invalid dimensions, unsafe or
aliased level paths, inconsistent file counts, malformed SHA-256 digests and
mismatched level bytes/hashes.
Path-ID resolution still checks the requested name, serialized file, bundle
hash, dimensions and mip count. A weak owner check distinguishes resource stores
even when an object address is reused; a lock serializes cold uploads, and dead
owner buckets are pruned when a new owner resolves a texture. Cold uploads use
the same buffers that were hashed, without reopening files. The resource cache
key includes dimensions, mip count and every level digest; rebuilding a manifest
at the same path and constructing a new store cannot reuse older texture content.
Equivalent content can reuse an already verified GPU texture. No uncompressed
CPU mip cache is retained. Existing assemblies keep their already resolved
textures; replacing files does not implicitly rebuild an assembly.
These checks run during assembly resolution, with no new per-frame texture work.

The synthetic tests cover malformed manifests, wrong identities, damaged levels,
row orientation, authored lower-mip preservation, resource-owner release, 16
concurrent requests producing one upload, and a changed lower mip at the same
path producing a new texture while the original remains intact. The 17 focused `liveSource` tests and
14 exporter tests pass. Native family colour is checked only where the family is
frontmost in both the complete capture-provider render and the native subset,
because missing composites change occlusion. The existing colour limits and hair
residual bounds are unchanged.
The eyebrow/eyeline gate requires more than 250 shared-frontmost pixels (278
observed). Tooth, tongue and nose are never frontmost in the complete controlled
view: their material resolution is checked, but this fixture supplies no visible
pixels to establish their native-store colour accuracy.

**Release measurements.** On the M2 Ultra at 768×1024, three old/new-store pairs
were interleaved under the shared app lock with other builds and captures paused.
All seven runs (six store runs plus one capture-provider control) used Release
executable SHA-256 `fdb6303169b33a01badafe4234ca86d47bf84c07e54bed81a2c035229fb87707`
(after the verified-buffer/content-cache fix).
Each synchronous offscreen benchmark warms three frames and measures 20; import,
simulation and PNG readback are excluded. The table gives the median of each
run's percentile:

| Store | Live / toon slots | CPU encode p50 | GPU p50 / p95 | Completion p50 | Registered textures | Metal allocation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Original 42 assets | 1 / 19 | 0.1500 ms | 0.3110 / 0.3284 ms | 0.8079 ms | 63 | 442.22 MiB |
| Completed 47 assets | 11 / 9 | 0.2739 ms | 0.5626 / 0.5976 ms | 1.2015 ms | 65 | 455.12 MiB |

The ten additional translated slots cost 0.1239 ms CPU encode and 0.2516 ms GPU
at p50. This measures added rendering work, not an equal-output speedup. Only two
additional native textures are uploaded for these slots (ramp and gloss); the
body-detail and nipple assets remain behind the body-composite fallback. Metal
allocation includes all renderer resources and is not a texture-only measure.
The fixture test verifies that live draws add no registered textures after
assembly. The six paired toon renders are byte-identical (SHA-256
`5762dd7c656199bec71c9329d97c7ef87c22c82cf15ffe88eef327004fc0abfd`).

For the three native-store Release renders, shared-frontmost eyebrow/eyeline
pixels have mean 0.7098 and p99 0 over 278 pixels; back hair mean
0.9895–0.9900, p99 23 over 3,530 pixels; front hair mean 0.6687,
p99 22 over 6,135 pixels. Hair still fails the strict p99≤4 colour gate,
within its existing residual bound. The complete capture-provider control has
geometry IoU 1.0, depth p99 0, normal p99 2, and translated-character IoU
0.9999798 / colour mean 0.19172 / p99 4. The production colour gate still fails
(mean 2.2565, p99 69). The native subset cannot establish whole-character parity.
Raw runs, input hashes, exact fallback lists, comparisons and the reproduction
scripts are in `$R/reviewed-*` and `$R/reviewed-summary.json`; the initial
pre-cache-fix runs remain in `$R/release-*` and `$R/summary.json`. The independent
review and follow-up are retained as `$R/claude-*-review.json`. No new
original-player capture was made.

### Native iris composites (R1, 2026-10-23)

The live path now composes one family of `CustomTextureCreate` render targets
itself: the irises (`ctCreateEyeL`/`ctCreateEyeR`, the `_MainTex` of
`cf_Ohitomi_L02`/`R02`). With the schema-2 native store the controlled fixture
resolves **13 of 20 slots** live, up from 11. Seven runtime composites still
fall back with their explicit reason: the body and face `CustomTextureControl`
textures, the two `ctCreateEyeW` eye whites and the three `ChangeCustomClothes`
garments. No capture pixels are rendered; the retained original composites
are the comparison oracle only. Scene globals stay unresolved in Studio, so
this is controlled-card coverage, not Studio or production parity.

**Recipe.** Citations are to the recovered `Koikatu/ChaControl.cs`,
`Koikatu/CustomTextureCreate.cs`, `ChaInfo.cs` and `ChaCustom/CvsEye02.cs`.

- *Target.* `InitBaseCustomTextureEtc` (ChaControl.cs:8902) creates both
  targets with `CustomTextureCreate.Initialize("chara/mm_base.unity3d",
  "cf_m_eye_create", "", n, n)`, n = 512 when `hiPoly`, else 256.
  `Initialize` (CustomTextureCreate.cs:27) clones the create material and makes
  `new RenderTexture(n, n, 0, ARGB32)` with `useMipMap = true` (line 40):
  sRGB in the linear-space player, the full chain (10 levels at 512) filled
  by Unity's default `autoGenerateMips`, and the `RenderTexture` sampler
  defaults (Bilinear, Clamp, aniso 1; the game sets none).
- *Inputs, in order* (`ChangeSettingEye(lr, updateBaseTex, updateMaskTex,
  updateColorAndOffset)`, ChaControl.cs:3859). `SetCreateTexture(main: true)`
  (line 3432) loads `mt_eye[face.pupil[i].id]` `MainAB`/`EyeTex` (`_low`
  appended unless `hiPoly`; a `"0"` row loads null) as `texMain`.
  `SetCreateTexture(main: false)` loads `mt_eye_gradation[pupil.gradMaskId]`
  `ColorMaskAB`/`ColorMaskTex` into `_ColorMask`. Then `SetColor(_Color,
  pupil.baseColor)`, `SetColor(_Color2, pupil.subColor)`, `SetFloat(_Blend,
  pupil.gradBlend)` and `SetVector4(_grad, (0, Lerp(-0.5, 0.5, gradOffsetY), 0,
  Lerp(-1, 1, gradScale)))` (lines 3897–3903). Every other value is the
  create material's own `m_SavedProperties` (`head-materials/contract.json`
  `createMaterials`); the textures keep the saved `[1, 1, 0, 0]` transforms
  because `Graphics.Blit` sets only the texture.
- *Pass.* `RebuildTextureAndSetMaterial` (CustomTextureCreate.cs:175) sets
  `GL.sRGBWrite = true`, clears to `Color.clear` and runs
  `Graphics.Blit(texMain, createTex, matCreate, 0)`. The result is bound as
  `rendEye[i].material` `_MainTex`. Pass 0 of `Shader Forge/create_eye` is one
  `FORWARD` pass (Blend SrcAlpha OneMinusSrcAlpha for colour and alpha, ZTest
  LEqual, ZWrite On, Cull Back). Its two D3D11 fragment variants are
  byte-identical (DXBC SHA-256 `c4bd7e1e…4fece`, the program
  `head_material_contract.py` verifies). Per texel, with `t` = `texMain.r` and
  `m` = `_ColorMask.r` sampled at `((uv + _grad.xy)·2(1 − _grad.w) + 0.5 −
  (1 − _grad.w))·_ColorMask_ST`: `c = lerp(_Color2, _Color, m)`, overlay =
  `saturate(t > 0.5 ? c / 2(1 − t) : 1 − (1 − c) / 2t)`, rgb = `_Blend ·
  (overlay − t·c) + t·c`, a = `texMain.a · _Color.a`. Blending over the
  cleared target stores `(rgb·a, a²)`. This is `create_eye_base` in
  `head_material_contract.py`.
- *Reruns.* `ChangeHeadAsync` (line 6931) runs the full recipe for both eyes
  on every head load and card reload. Maker iris edits rerun parts of it
  (`CvsEye02.cs` 398–515 and 707–770: base texture, mask, or colours and
  offsets for one or both eyes). Maker, H scenes and thumbnails keep the
  inputs (`releaseCustomInputTexture = false`), which the default
  (`ChaInfo.cs`:391, true) otherwise releases after each rebuild.
  `ChangeSettingEye` returns early only for `sex == 0 && exType == 1`, so it
  always runs for the female fixture. Expressions,
  outfit changes and gaze do not rerun it; gaze moves the draw material's
  `_MainTex_ST` (`EyeLookMaterialControll`) instead.

**Native composition.** `SourceShaderBindingDerivation` now writes the recipe
into the composite identity (`TextureIdentity.composite`: create material
identity and verified program hash, the two input asset identities, every
vector with its cited source). `source_texture_store.py` stores the inputs like
any other asset (`cw_t_hitomi_000`, `cw_t_hitomigrad_000`) and, with
`--create-shader-cache`, re-extracts the create pass's fragment program from the
local `mm_base` bundle. It requires the recipe's hash and byte-identical
variants, translates the retained disassembly (no VM) with the #127 translator,
and lists the program under schema-2 `composites`. `SourceShaderTextureStore`
then composes the target the first time an assembly resolves the slot:

- every input through the same identity-checked, hash-verified store path as
  material textures, or the program's Unity default where the recipe binds
  none; colours linearized at bind as the player does;
- `SourceShaderCompositor` draws the translated fragment over a native
  full-target quad (`TEXCOORD0` (0, 0) bottom-left, as `Graphics.Blit`'s quad)
  into a private `rgba8Unorm_srgb` texture cleared to transparent, with the
  pass's blend state, then generates the full mip chain with the blit encoder;
- the content key hashes the recipe version (`source-composite-v1`), the DXBC
  and MSL hashes, `program.json`, the target size, mip count and format, each
  input's content key (dimensions, mips and every level digest) with its
  sampler, and every vector's bit pattern;
- composites are not registered in the `ResourceStore`. The materials that
  bind them own them; the store's per-owner cache holds them weakly, so a
  rebuilt assembly with the same recipe shares the texture and a released
  assembly frees it. Both irises of the fixture card have one recipe and
  share one composite;
- all-or-nothing: an unresolved recipe, a program missing from the store, a
  changed program file, an input that is not in the store, an unresolved or
  undeclared vector each keep the slot toon with that reason. Body, face,
  eye-white and garment composites carry no recipe and keep
  "is not composed natively for the live path".

Metal's `saturate` returns 0 for NaN, as D3D's does, so the overlay's 0/0
case (t = 0, c = 1) matches; a synthetic test pins it.

**Evidence (offline vs GPU-independent).** The retained original composites
(`texture-21`/`texture-24` in `.local/r1c/probe`) are GPU readbacks of
the original targets' base level, exported by `Graphics.Blit` into ARGBHalf
(bottom-up). Lower mips were not read back; they have no independent oracle.
The fixture's iris is black over a white sub colour with `_Blend` 0, so this
oracle checks coverage (a²), orientation, sampling and the blend, not the overlay
colours. Native level 0 against both readbacks: max 1 byte (|linear| 0.00407),
15 of 1,048,576 channels differ, all alpha rounding; mean |linear| 5.3e-7.
The real translated program with synthetic, non-degenerate colours
(`_Color` (0.8, 0.3, 0.2, 0.9), `_Color2` (0.1, 0.5, 0.9, 1), `_Blend` 0.6,
`_grad.w` 0.5 for a 1:1 mask) matches the CPU reference within 1 byte over all
262,144 texels (31,620 in the `t > 0.5` branch). That is a check against our
reading of the program, not an independent original observation. The two input
textures have no retained readback of their own: they are `Blit` inputs, not draw
textures. The oracle observes `cw_t_hitomi_000`'s alpha (through a²) and the
mask only on the edge that `_grad` samples.

In the gated live test (`IKKOKU_LIVE_SOURCE_TEXTURES` =
`.local/r1-composite/textures/manifest.json`), the store pins 49 entries, one
composite program, zero unavailable assets or composites, and the canonical
content hash `12aaa646…78b65`. 13 slots draw live and 7 fall back. On pixels
where `toon_eye_lod0` is frontmost in both the complete capture-provider frame
and the native subset, native-store irises give 368 px, mean 0.00996, p99 0.
The limits are unchanged (mean ≤ 1, p99 ≤ 4, > 250 px). The capture-provider
irises measure 368 px, mean 0.00906, p99 0. The store is rebuilt with:

```sh
swift build --package-path Packages/Engine --product ikkoku-inspect
Packages/Engine/.build/debug/ikkoku-inspect shader-bindings .local/r1c/probe/fixture-card.png \
  .local/reverse/maker-library/library.json .local/reverse/rigs/head-materials/contract.json \
  .local/r1c/probe/shaders .local/r1c/probe/frame-mips.json \
  --supplement .local/r1-sampler-bundles/supplement.json > .local/r1-composite/shader-bindings.json
.local/reverse/unitypy-venv/bin/python Tools/reverse/source_texture_store.py \
  .local/r1-composite/shader-bindings.json .local/r1-composite/textures \
  --bundle-root .local/reverse/rigs/source/abdata \
  --create-shader-cache .local/reverse/rigs/head-materials/shaders \
  --verify-frame .local/r1c/probe/frame-mips.json --require-complete
```

`--require-complete` now also fails on an unavailable composite program. The
verifier's counts are unchanged except for the two new inputs: 71 independent
GPU base comparisons, 430 offline lower-level comparisons, and 49 levels without
retained pixels (47 before, plus the two inputs).

**Cost (Release, M2 Ultra).** Composition runs once per assembly and once per
recipe edit, never per frame. The live probe (`IKKOKU_LIVE_SOURCE_SHADERS`
fixture launch, one head Release binary, three launches) composes the left iris
once and reuses it for the right (cache hit, same content key). Every launch
compiles the create pipeline. The first launch after the build took 105.8 ms
CPU; the next two took 1.33 and 1.29 ms CPU, 9.37 and 9.14 ms GPU, and 12.2 and
11.6 ms in total, consistent with Metal's on-disk compiler cache. The GPU figure is one 512² pass and
its mip chain on an otherwise idle GPU. In the Release gated test (3 runs), the
first composition takes 2.1–3.5 ms CPU and 10.0–10.7 ms GPU. A recipe edit
there (median of 15 `_Color` changes, pipeline cached) takes 0.042–0.048 ms CPU
encode, 0.056–0.058 ms GPU and 0.39–0.41 ms until completion; a cache hit takes
0.065–0.067 ms. The composite is 1,425,408 bytes (512², 10 mips). The two
inputs stay registered with the assembly after composition, as Maker's
`releaseCustomInputTexture = false` keeps them (2 MiB each at rgba16f).

Per frame, the two iris slots now draw the translated program instead of toon.
The probe's interleaved Release pairs (one binary, #139's 47-asset store vs this
store, 3 launches each, 3 warm-up and 20 measured frames at 768×1024, median of
each run's p50) give:

| Store | Live / toon slots | CPU encode p50 | GPU p50 / p95 | Completion p50 | Registered textures | Metal allocation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| #139, 47 assets | 11 / 9 | 0.2752 ms | 0.5105 / 0.5967 ms | 1.1786 ms | 65 | 455.12 MiB |
| r1-composite, 49 assets + iris program | 13 / 7 | 0.2859 ms | 0.5788 / 0.6117 ms | 1.2426 ms | 69 | 471.44 MiB |

The two added slots cost 0.011 ms CPU encode and 0.068 ms GPU at p50. This is
added rendering work, not a regression in an equal-output path. The four new
textures are the two composite inputs and the slots' `_overtex1`/`_overtex2`
highlights, which the store already held but uploads only for a resolved slot
(14 MiB at rgba16f). The composite adds 1.36 MiB. The six toon renders stay
byte-identical (`5762dd7c…`, as in #139). The native-store family colours repeat
the gated test: irises 368 px, mean 0.00996, p99 0, max 1; eyebrow/eyeline 278
px, mean 0.7098, p99 0; back hair 3,528 px, mean 0.9896, p99 23; front hair
6,134 px, mean 0.6686, p99 22 (unchanged from the old store). The
capture-provider control has 20 of 20 slots live, geometry IoU 1.0, translated
character IoU 0.9999798, mean 0.19162, p99 4; production colour still fails at
mean 2.2565, p99 69. The Release test numbers come from:

```sh
swift build -c release --build-tests -Xswiftc -enable-testing --package-path Packages/Engine \
  --scratch-path .local/build/engine-release
swift test -c release -Xswiftc -enable-testing --package-path Packages/Engine \
  --scratch-path .local/build/engine-release --skip-build --filter liveSourceIrisComposites
```

with `.local/verification/environment.json` exported and
`IKKOKU_LIVE_SOURCE_TEXTURES` set to the new store. The launch scripts, raw
runs and `release-summary.json` stay in the git-ignored `.local/r1-composite/`.

**Regression (opt-in OFF).** Base `origin/main` `fc72839` and this branch's
Release binaries, interleaved for three rounds, each launch with only its own
`IKKOKU_*` variables. Every case's captures were byte-identical across all six
launches:

| Case | Capture SHA-256 | CPU encode p50 base / head | GPU p50 base / head |
| --- | --- | ---: | ---: |
| `koikatu_cs0002591.png` (`IKKOKU_SOURCE_SCENE`, `IKKOKU_BENCHMARK_OUTPUT`) | `cac034c1…` | 0.7284 / 0.7329 ms | 1.2344 / 1.2411 ms |
| fixture card, Maker app capture (`IKKOKU_BENCHMARK_OUTPUT`) | `26742344…` | 0.1799 / 0.1698 ms | 0.4636 / 0.4614 ms |
| rig and fixture card (`IKKOKU_CAPTURE_RIG`, no benchmark output) | `9d973e21…` | — | — |

The scene hash differs from the earlier `caed346e…`; base and head agree, so
the change predates this branch. `synthetic-current.png` is no longer a usable
control: both builds exit 1 with "Character 10 retained without rendering:
Unsupported hair part array". Its only character has no supported hair `parts`
array, so it was always retained without rendering, and since #133 an automated
scene capture whose characters all fail exits 1. With `IKKOKU_MAKER_LIBRARY=none`
it is a native-scene byte control again (see the
[regression list](#live-source-shader-path-r1cmt-04-opt-in-2026-10-22)).

**Remaining composites.** Seven slots of the fixture still fall back, each with
"is not composed natively for the live path":

| Slot | Creator | Inputs named by the derivation |
| --- | --- | --- |
| `cf_Ohitomi_L`, `cf_Ohitomi_R` (`toon_eyew_lod0`) | `ctCreateEyeW`, `cf_m_eyewhite_create` | `mt_eye_white[face.whiteId]`, `whiteBaseColor`/`whiteSubColor` |
| `o_body_a` (`main_skin`) | `CustomTextureControl` body, `cf_m_body_create` | body base, skin and paint inputs |
| `cf_O_face` (`main_skin`) | `CustomTextureControl` face, `cf_m_face_create` | head `MainTex`, skin and makeup inputs |
| `o_top_tsyats_a`, `o_bot_pants03`, `o_shoes_run01` (`main_opaque`) | `ChangeCustomClothes`, `cf_m_clothesN_create` | each garment's `_t` texture and the card's `colorInfo` |

The eye whites are the nearest. They are `CustomTextureCreate` targets like the
irises, so the same machinery applies: a recipe in the derivation, the program
in the store and an oracle check of their own. They are now composed natively
([native eye-white composites](#native-eye-white-composites-r1-2026-10-23)). The body, face and garment
targets are `CustomTextureControl`/`ChangeCustomClothes` composites with more
inputs; their recipes are not recovered here.

**Tests.** `SourceShaderCompositeTests.swift` (synthetic store, hand-written
`create_eye` fragment): GPU result against the CPU reference (≤ 1 byte) and the
mip chain against a linear box filter (≤ 2 bytes); the NaN overlay; a new
content key and target for each change of `_Color`, `_Color.a`, `_Color2`,
`_Blend`, `_grad`, either `_ST`, either input texture, a default input, the
input sampler and the target size; cache hits, per-owner composition and
release with the owner; the exact reason for 13 missing or mismatched inputs;
a material that binds the composite or falls back with its reason; and the
fragment-only program and manifest validation. Mutation controls fail them: a
flipped quad V or disabled blending fails the reference test; dropping vectors
from the content key fails the cache test. The gated
`liveSourceIrisCompositesMatchTheRetainedOriginalComposites` runs the oracle and
CPU-reference checks above. `test_source_live_inputs.py` and
`test_source_shader_translation.py` cover the recipe inputs, recipe sharing,
program export failures (no partial output) and input-signature parsing.

### Native eye-white composites (R1, 2026-10-23)

The live path now also composes the eye whites itself (`ctCreateEyeW`, the
`_MainTex` of `cf_Ohitomi_L`/`R`), the second `CustomTextureCreate` family after
the [irises](#native-iris-composites-r1-2026-10-23). With the schema-2 native
store the controlled fixture resolves **15 of 20 slots** live, up from 13. Five
runtime composites still fall back with "is not composed natively for the live
path": the body and face `CustomTextureControl` textures and the three
`ChangeCustomClothes` garments. As before, no capture pixels are rendered, the
retained original composites are the comparison oracle only, and Studio scene
globals stay unresolved, so this is controlled-card coverage, not Studio or
production parity.

**Recipe.** Citations are to the same recovered `Koikatu/ChaControl.cs`,
`Koikatu/CustomTextureCreate.cs` and `ChaCustom/CvsEye02.cs`.

- *Target.* `InitBaseCustomTextureEtc` (ChaControl.cs:8902–8915) creates
  `ctCreateEyeW` just before the two iris targets, with
  `Initialize("chara/mm_base.unity3d", "cf_m_eyewhite_create", "", n, n)`, n =
  512 when `hiPoly`, else 256. It is the same target as the irises' (ARGB32 sRGB
  `RenderTexture`, full mip chain of 10 levels at 512, Bilinear/Clamp/aniso 1).
- *Inputs* (`ChangeSettingWhiteOfEye(updateTex, updateColor)`,
  ChaControl.cs:3795). `SetCreateTexture(ctCreateEyeW, main: true, mt_eye_white,
  face.whiteId, MainAB, EyeWhiteTex, _MainTex)` (line 3810; `_low` appended unless
  `hiPoly`), then `SetColor(_Color, whiteBaseColor)` and `SetColor(_Color2,
  whiteSubColor)` (lines 3816–3817). Every other value is the create material's
  own saved properties. One target serves both eyes: the result goes to
  `rendEyeW[0].material` and `rendEyeW[1].material = rendEyeW[0].material`
  (lines 3824–3825).
- *Pass.* `RebuildTextureAndSetMaterial` as for the irises: clear to
  `Color.clear`, then `Graphics.Blit(texMain, createTex, matCreate, 0)`. Pass 0
  of `Shader Forge/create_eyewhite` is one `FORWARD` pass with Blend One Zero for
  colour and alpha, so the clear never shows. Its two D3D11 fragment variants
  are byte-identical (DXBC SHA-256 `4f4f69fd…95b1f9`). Per texel, with `t` =
  `_MainTex.r` at the `_MainTex_ST` UV: rgb = `t·(_Color − _Color2) + _Color2`
  (that is, `lerp(_Color2, _Color, t)`), a = 1.
- *Reruns.* `ChangeHeadAsync` (line 6930) runs it with both flags on every head
  load and card reload, right before the iris recipe. Maker reruns the texture
  alone on an eye-white ID change (`CvsEye02.cs`:344) and the colours alone on
  either colour edit (lines 454 and 461). Maker keeps the input
  (`releaseCustomInputTexture = false`), so each rerun rebuilds the same full
  recipe. It returns early only for `sex == 0 && exType == 1`; like the iris
  recipe, the derivation does not model that branch.
- *Catalog.* `mt_eye_white` (category 407, `chara/mt_eye_white_00.unity3d`) has
  five rows, `cw_t_sirome_kage_000` to `_004`. Row 0 is 8×8 with 4 mips and
  Repeat, and is 1 in every channel. Row 1 is 512² Repeat, rows 2–4 are 512²
  Clamp. The head contract's catalog rows hold only the fixture's ID 0; a card
  with another ID needs a supplement built with `--category 407 --bundle
  chara/mt_eye_white_00.unity3d`.

**Native composition.** The machinery is the irises': the derivation writes the
recipe (`eyeWhiteComposite()`), the store's `--create-shader-cache` exports the
eye-white program next to the iris program, and `SourceShaderTextureStore`
composes it with the input's own sampler (Repeat for row 0). The shared
`rendEyeW` material means both slots bind one recipe and share one composite.

**Evidence.** Three checks, from weakest to strongest:

1. *Retained oracle (degenerate).* The fixture card has `whiteId` 0 with white
   base and sub colours, so `texture-20` in `.local/r1c/probe` is constant
   (1, 1, 1, 1). Native level 0 matches it exactly (max byte 0, 0 differing
   channels). This checks coverage and alpha only, not sampling, orientation or
   colour.
2. *Program against the CPU reference.* The real translated program with
   synthetic colours over a non-uniform store texture (the iris pattern
   `cw_t_hitomi_000`, 512² Clamp, 176 distinct reds) matches the CPU reference
   within 1 byte. A synthetic store test also checks that the input's own
   sampler is used: the Repeat and Clamp variants of one input each match their
   own reference within 1 byte and differ from the other by more than 8 bytes.
   Both are checks against our reading of the program.
3. *Distinct-colour capture (independent).* One read-only capture through the
   isolated probe player (`original_character_probe.py --settings`, probe source
   SHA-256 `4324ce7b…e1120e`; Unity 5.6.2f1, D3D11, linear colour space,
   `status.json` error null). Its settings file (SHA-256 `a4293361…4d9f4b`) sets
   `whiteId` 3 (`cw_t_sirome_kage_003`: 512² Clamp, 253 distinct reds, sampled
   1:1 by the 512² target, so a flipped or shifted texel shows), distinct
   eye-white base and sub colours, distinct iris base and sub colours with base
   alpha below 1, and non-default `gradBlend`, `gradOffsetY` and `gradScale`.
   The values stay in `.local`. The card the probe saved (`fixture-card.png`,
   SHA-256 `5a8cc15a…a5a331`) is derived, stored and composed from the card
   alone, with its own supplement (85 catalog rows, 1,660 textures) and store;
   the capture's readbacks are only compared. Its binding comparison has the
   same counts as the fixture's (texture 100 exact and 9 within tolerance of
   109, vector 191 exact and 18 within of 211, 0 differing). Level 0:

   | Target | Readback (SHA-256) | Max byte | Differing channels of 1,048,576 | Mean byte | Distinct original colours |
   | --- | --- | ---: | ---: | ---: | ---: |
   | eye white L, R (one composite) | `texture-20` (`c8ac18ae…e65c70`) | 1 | 9,349 | 0.0089 | 213 |
   | iris L, R (one composite) | `texture-21` = `texture-24` (`8e137f89…d5dab362`) | 1 | 1,503 | 0.0014 | 743 |

   The iris row closes #143's untested colour mixing: a non-black base colour
   with alpha below 1, a non-zero `_Blend` and a non-default `_grad`, against the
   original. VM hygiene: the Parallels `errno: 24` count was 5 before and after;
   the probe root `C:\Temp\IkkokuShaderProbe-63023098…` was removed and no game
   process was left; nothing in the game install changed. Of the 129 capture
   files only the card, `frame.json`, the three readbacks, the settings and
   `status.json` are kept (with a SHA-256 list of all 129) in
   `.local/r1-eyewhite/colour/`.

The gated `liveSourceCompositesMatchTheDistinctColourCapture` runs check 3 when
`IKKOKU_COMPOSITE_COLOUR_PROBE` names that folder (`fixture-card.png`,
`frame.json`, the readbacks, `supplement.json`, `textures/manifest.json`). The
folder is rebuilt with:

```sh
L=.local; C=$L/r1-eyewhite/colour
.local/reverse/unitypy-venv/bin/python Tools/reverse/source_binding_supplement.py \
  --source $L/reverse/rigs/source/abdata --output $C/supplement.json \
  --bundle chara/bo_hair_b_00.unity3d --bundle chara/bo_hair_f_00.unity3d --bundle chara/co_top_00.unity3d \
  --bundle chara/co_bot_00.unity3d --bundle chara/co_shoes_00.unity3d --bundle chara/bo_head_00.unity3d \
  --bundle chara/mt_eyebrow_00.unity3d --bundle chara/mt_eyeline_up_00.unity3d --bundle chara/mt_eyeline_down_00.unity3d \
  --bundle chara/mt_nose_00.unity3d --bundle chara/mt_eye_hi_up_00.unity3d --bundle chara/mt_eye_hi_down_00.unity3d \
  --bundle chara/mt_mask_body_00.unity3d --bundle chara/mt_hairgloss_00.unity3d --bundle chara/mt_nip_00.unity3d \
  --bundle chara/mt_body_detail_00.unity3d --bundle chara/mt_ramp_00.unity3d --bundle chara/mt_eye_white_00.unity3d \
  --draw-material chara/mm_base.unity3d:cf_m_body \
  --category 2 --category 407 --category 420 --category 423 --category 424 --category 432 --category 433
Packages/Engine/.build/debug/ikkoku-inspect shader-bindings $C/fixture-card.png \
  $L/reverse/maker-library/library.json $L/reverse/rigs/head-materials/contract.json \
  $L/r1c/probe/shaders $C/frame.json --supplement $C/supplement.json > $C/shader-bindings.json
.local/reverse/unitypy-venv/bin/python Tools/reverse/source_texture_store.py \
  $C/shader-bindings.json $C/textures --bundle-root $L/reverse/rigs/source/abdata \
  --create-shader-cache $L/reverse/rigs/head-materials/shaders --require-complete
```

The store was built once with `--verify-frame` on the capture's `frame.json`
before the bulk of the capture was deleted: 71 independent GPU base
comparisons, maximum 0.0127, as for the fixture store. It holds 50 entries
(`cw_t_sirome_kage_003` in place of `_000`) and the same two programs; 314 of
its 324 files are APFS clones of the fixture store's.

**Fixture gates.** In the gated live test (`IKKOKU_LIVE_SOURCE_TEXTURES` =
`.local/r1-eyewhite/textures/manifest.json`, built like #143's store from
`.local/r1-eyewhite/shader-bindings.json`), the store pins 50 entries, the two
composite programs, zero unavailable assets or composites, and the content hash
`4bf874a3…dbbb5ca`. 15 slots draw live and 5 fall back; each composite is
composed once and hit once. On pixels frontmost in both the complete
capture-provider frame and the native subset, with the limits unchanged
(mean ≤ 1, p99 ≤ 4, > 250 px; hair bounds as before):

| Family | 13 live (r1-composite store) | 15 live (this store) | Capture provider |
| --- | --- | --- | --- |
| `toon_eyew_lod0` (eye whites, eyebrows, eyelines) | 278 px, mean 0.7098, p99 0 | 327 px, mean 0.6035, p99 0 | 327 px, mean 0.6137, p99 1 |
| `toon_eye_lod0` (irises) | 368 px, mean 0.00996, p99 0 | 366 px, mean 0.00455, p99 0 | 368 px, mean 0.00906, p99 0 |
| `main_hair` | 3,524 px, mean 0.9886, p99 23 | 3,524 px, mean 0.9886, p99 23 | 3,527 px, mean 0.9960, p99 24 |
| `main_hair_front` | 6,151 px, mean 0.6703, p99 22 | 6,151 px, mean 0.6703, p99 22 | 6,187 px, mean 0.8480, p99 22 |

In this full-body view the eye whites add only 49 shared-frontmost pixels. The
verifier gives 71 independent GPU base comparisons, 430 offline lower-level
comparisons (maximum 0.0127, largest mean 0.00114) and 53 levels without
retained pixels (49 before, plus the 4 levels of `cw_t_sirome_kage_000`, a
`Blit` input with no readback of its own).

**Whole-character colour.** The capture-provider control does not move: it
draws 20 of 20 slots live with capture textures (the eye whites were already
live there), translated character IoU 0.9999798, mean 0.19160, p99 4, and its
production colour still fails at mean 2.2565, p99 69. With the native store,
whole-frame production colour (`color` in `frame-comparison.json`, all 99,750
character pixels) moves from mean 87.95, p99 204 with 13 slots live to mean
87.08, p99 203 with 15, the same in all three launches of each store. The rest
of that gap is the five toon fallbacks (body and face skin and three garments),
which cover most of the character. The eye whites are a small part of this
full-body view: 49 more shared-frontmost pixels, as above.

**Cost (Release, M2 Ultra).** Composition runs once per assembly and once per
recipe edit, never per frame. In the live probe (the head Release binary, three
launches) the eye white is now the first composite of each launch and the iris
the second. The first composite carries the launch's first GPU pass and its
Metal compile: 99.3 ms CPU on the first launch after the build, then 1.30 and
1.22 ms CPU, 8.75 and 9.05 ms GPU, and 11.4 and 11.7 ms in total. The iris that
follows takes 0.20–0.26 ms CPU, 0.085–0.098 ms GPU and 0.64–0.76 ms in total,
its own pipeline compile included. So the eye whites add about 0.2 ms CPU and
0.1 ms GPU of composition at load. The ~9 ms GPU is a one-time cost of
whichever composite runs first; with the old store the iris paid it (9.73 and
8.65 ms). In the Release gated test (3 runs), an eye-white edit (median of 15
`_Color` changes, pipeline cached) takes 0.037–0.052 ms CPU encode, 0.050 ms GPU
and 0.39–0.42 ms until completion, and a cache hit 0.052–0.061 ms. The first
eye-white composition of a test store takes 2.30–2.36 ms CPU and 11.0–12.5 ms
GPU. The composite is 1,425,408 bytes (512², 10 mips); its row-0 input is 8×8.

Per frame, the two eye-white slots now draw the translated program instead of
toon. The probe's interleaved Release pairs (one binary, #143's store vs this
store, 3 launches each, 3 warm-up and 20 measured frames at 768×1024, median of
each run's p50) give:

| Store | Live / toon slots | CPU encode p50 | GPU p50 / p95 | Completion p50 | Registered textures | Metal allocation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| r1-composite (#143), 49 assets + iris program | 13 / 7 | 0.2943 ms | 0.5816 / 0.6144 ms | 1.2478 ms | 69 | 471.44 MiB |
| r1-eyewhite, 50 assets + iris and eye-white programs | 15 / 5 | 0.3000 ms | 0.5980 / 0.6321 ms | 1.2499 ms | 70 | 472.80 MiB |

The two added slots cost 0.006 ms CPU encode and 0.016 ms GPU at p50, inside
the new store's run-to-run GPU spread (0.534–0.601 ms). This is added rendering
work, not a regression in an equal-output path. The new registered texture is
the 8×8 input; the allocation grows by the composite (1.36 MiB). The six toon
renders stay byte-identical (`5762dd7c…`). The probe's family colours repeat the
gated test: eye whites, eyebrows and eyelines 327 px, mean 0.6035, p99 0;
irises 366 px, mean 0.0046, p99 0; back hair 3,527 px, mean 0.9899, p99 23;
front hair 6,134 px, mean 0.6686, p99 22 (hair unchanged). The Release test
numbers come from:

```sh
swift build -c release --build-tests -Xswiftc -enable-testing --package-path Packages/Engine \
  --scratch-path .local/build/engine-release
swift test -c release -Xswiftc -enable-testing --package-path Packages/Engine \
  --scratch-path .local/build/engine-release --skip-build \
  --filter "liveSourceEyeWhiteComposites|liveSourceIrisComposites"
```

with `.local/verification/environment.json` exported and
`IKKOKU_LIVE_SOURCE_TEXTURES` set to the new store. The launch scripts, raw runs
and `release-summary.json` stay in the git-ignored `.local/r1-eyewhite/`.

**Regression (opt-in OFF).** Base `origin/main` `9baebcb` and this branch's
Release binaries, interleaved for three rounds, each launch with only its own
`IKKOKU_*` variables. Every case's captures were byte-identical across all six
launches:

| Case | Capture SHA-256 | CPU encode p50 base / head | GPU p50 base / head |
| --- | --- | ---: | ---: |
| `koikatu_cs0002591.png` (`IKKOKU_SOURCE_SCENE`, `IKKOKU_BENCHMARK_OUTPUT`) | `cac034c1…` | 0.7282 / 0.7536 ms | 1.2702 / 1.2719 ms |
| fixture card, Maker app capture (`IKKOKU_BENCHMARK_OUTPUT`) | `26742344…` | 0.1765 / 0.1763 ms | 0.4643 / 0.4567 ms |
| rig and fixture card (`IKKOKU_CAPTURE_RIG`, no benchmark output) | `9d973e21…` | — | — |

The only code change is in the binding derivation, which does not run with the
opt-in OFF, so the scene's 0.025 ms CPU difference (base 0.709–0.738, head
0.744–0.755 ms) is not attributable to it; #143 measured 0.7284 / 0.7329 ms on
the same case. As there, `synthetic-current.png` is not a control: its only
character has no supported hair `parts` array, and since #133 an automated scene
capture whose characters all fail exits 1. With `IKKOKU_MAKER_LIBRARY=none` it
is a native-scene byte control again.

**Remaining composites.** Five slots of the fixture still fall back:

| Slot | Creator | Inputs named by the derivation |
| --- | --- | --- |
| `o_body_a` (`main_skin`) | `CustomTextureControl` body, `cf_m_body_create` | body base, skin and paint inputs |
| `cf_O_face` (`main_skin`) | `CustomTextureControl` face, `cf_m_face_create` | head `MainTex`, skin and makeup inputs |
| `o_top_tsyats_a`, `o_bot_pants03`, `o_shoes_run01` (`main_opaque`) | `ChangeCustomClothes`, `cf_m_clothesN_create` | each garment's `_t` texture and the card's `colorInfo` |

The body and face use `CustomTextureControl`. The garments do use
`CustomTextureCreate`: `InitBaseCustomTextureClothes` creates the targets,
then `ChangeCustomClothes` sets their inputs. Their recipes were not derived
in this eye-white slice; the normal-top continuation below handles one target.

**Tests.** `SourceShaderCompositeTests.swift` gains a hand-written
`create_eyewhite` fragment (Blend One Zero) and checks it against the CPU
reference with a Repeat and a Clamp input, as above. The fixture store is
generalised over the program layout and blend. The gated
`liveSourceEyeWhiteCompositesMatchTheRetainedOriginalComposite` runs checks 1
and 2, confirms the uniform row-0 input and both slots sharing one texture, and
measures the edit cost. `liveSourceCompositesMatchTheDistinctColourCapture` runs
check 3 for all four eye slots, and `liveSourceShadersMeetTheControlledOriginalFrameGates`
pins the store and the 15/5 split. `OriginalCharacterProbe.cs` accepts the new
settings keys (`whiteId`, `whiteBaseColor`, `whiteSubColor`, `pupilBaseColor`,
`pupilSubColor`, `gradBlend`, `gradOffsetY`, `gradScale`; see
[material expansion](character/material-expansion.md)).

### Native normal-top composite (R1/CMT-04, #159, 2026-10-24)

The opt-in live path now derives the first normal top target from
`InitBaseCustomTextureClothes(true, 0)` and `ChangeCustomClothes`. The verified
selection is category 105, ID 38 (`p_o_top_tsyatu02`, `o_top_tsyats_a`), with
all renderers in `rendNormal01`, high-detail inputs, and all three pattern IDs
zero. Other garment slots, mixed normal/alpha roles, low-detail inputs and
nonzero/missing pattern rows retain explicit fallbacks. This does not verify
arbitrary clothes, patterns, skin composites or Studio scene globals.

**Source contract.** The retained CharaStudio assembly is
`902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45`.
Recovered `ChaControl.cs` is `d5a09fb197f697b67bdad886d0c762fc96c08012c9ec40952e6e2a091ad62101`
and `CustomTextureCreate.cs` is `8f8cf47cfc2829515a43d1e134d89474f4e374547156103cc2c559b32577a897`.
The source sizes the target from the main texture, sets the main and colour-mask
textures using `MainTexAB`/`ColorMaskAB` with `0 → MainAB` fallback, applies each
`colorInfo` base/pattern colour and tiling, then blits with the cloned create
material. The converted `mt_pattern` category 430 row 0 proves that the three
pattern textures are null; the shader's white defaults apply. Missing card
fields or missing program proof are not replaced with guessed values.

| Identity | Exact source evidence |
| --- | --- |
| Create material | `cf_m_clothesN_create`, path ID `3922150014319152921`, serialized file `CAB-0d1f3d8317188244dde38c81a889d1d4` |
| Create shader | `Shader Forge/create_topN`, fragment DXBC SHA-256 `d709d6fc92ebecd4f8b579041c8a7abce3a13c20c18985812bde6bc42881f579` |
| Create bundle | `chara/mm_base.unity3d`, SHA-256 `3944a1d7a9e446f15714bcca0b2faebd7b760fdc010139fad677ce24c422175e` |
| Main input | `cf_top_tsyatu02_t`, path ID `-6233972938813170750`, sRGB BC1 |
| Mask input | `cf_top_tsyatu02_mc`, path ID `-1591564840063675426`, linear BC1 |
| Input bundle | `chara/co_top_00.unity3d`, SHA-256 `2df694771a8c6437f5e966e94747f48ed905d611a7f2de036a5d64956996657a`, serialized file `CAB-ea71f5c3f889c85d158dd90d78f65595` |

Both inputs are 1024² with 11 authored mips, Bilinear/Repeat/aniso 1. The
composite is 1024², 11 generated mips, sRGB ARGB32-equivalent with source
SrcAlpha/OneMinusSrcAlpha blending over transparent clear. Only level zero has
an independent original composite readback; lower target mips are structural
checks, not a GPU parity claim.

**Independent colour check.** The retained base readback (`texture-37`, SHA-256
`c9020d7ceeaf413ea4199482e52ce66b51e85bd34912493a5d21eea5adf1dd11`) is byte-exact.
A new isolated original-player capture changes the three top base colours to
`(0.72,0.13,0.04,1)`, `(0.09,0.66,0.31,1)` and `(0.16,0.23,0.84,1)`.
Its independently generated composite has SHA-256
`2ba4e150536fbe5e103430dc1ceb18f988dd169c275d8846ab394e96fb91445a`.
Native level zero differs by at most 1 byte: 1,235 of 4,194,304 channels,
mean absolute error 0.00029445 byte. Reverting the recipe returns the original
cached target and identical pixels.

The distinct-colour check exposed an offline decoder issue hidden by the equal
base colours: UnityPy's Pillow path quantizes BC1 interpolants to integer bytes
before half-float export. The original decoder produced 60 channels above one
byte (57 at two, three at three). The converter now expands RGB565 endpoints
and preserves fractional interpolation in float before half-float export, using
[the BC1 interpolation contract](https://learn.microsoft.com/en-us/windows/win32/direct3d10/d3d10-graphics-programming-guide-resources-block-compression).
[Pillow's integer palette](https://github.com/python-pillow/Pillow/blob/main/src/libImaging/BcnDecode.c)
explains the precision loss. Other compressed formats and Xbox byte-swapped
inputs keep their previous decoder paths; no card colour or shader coefficient
was fitted to the capture.

An additional original-player readback loads the same catalog main/mask after
capture and records their source bundle hash, names, format, dimensions and mip
count. The repeated edited composite is byte-identical. The main input matches
exactly; the mask's filtered `Graphics.Blit` readback retains a maximum linear
difference of 0.00683594 (previous decoder 0.0078125), only in green transition
pixels, with mean 0.0000014333. This is not a raw-texel or all-mip equality
claim; the final composite keeps the stricter one-byte output gate.

**Live fixture and resources.** The rebuilt private store contains 52 assets,
three create programs and zero unavailable entries. Its path-independent
content fingerprint is `0539171774027e0902c25610b68c543d4889bc73d0bfb34647d8d18bf11fbe43`.
The controlled native rig now resolves 16/20 live slots, with body, face, bottom
and shoes still falling back. This uses native pose and vertex streams under
the controlled capture camera, not the original's frozen vertices. In the final
Release gate, on pixels frontmost in both capture-provider and native subsets:

| Family | Shared pixels | Mean byte error | p99 |
| --- | ---: | ---: | ---: |
| Normal top (`main_opaque`) | 26,349 | 0.02908 | 1 |
| Eye whites/eyebrows/eyelines | 327 | 0.60347 | 0 |
| Irises | 366 | 0.00455 | 0 |
| Back hair | 3,528 | 0.98970 | 23 |
| Front hair | 6,153 | 0.66737 | 22 |

The prior hair and eye limits are unchanged. Tooth/nose slots have no frontmost
reference pixels here and are checked for resolution only. Hair retains its documented edge
residual; whole-character production colour and arbitrary animated scenes are
not claimed to match. Each output is composed only at assembly or recipe edit.
The store now also caches Unity-default textures and normalized sampler states
per weakly checked resource owner: unchanged top lookups allocate no new inputs,
and 15 recolours retain two asset uploads, one white default and one sampler.
Released edited targets are not retained by the weak composite cache. Synthetic
checks cover distinct Clamp/Repeat samplers and owner destruction/recreation.

The private fixture is generated by `head_material_contract.py`, native
`shader-bindings`, then `source_texture_store.py` with both the head and garment
create-shader caches. Original captures remain validation inputs, never runtime
textures. `IKKOKU_GARMENT_COMPOSITE_PROBE` points to the distinct-colour capture;
see [the verification fixture contract](../../Tools/verification/README.md#composite-colour-capture-fixture).

**Release costs and validation.** A clean Release app at commit `f52cfa87`
(binary SHA-256 `04e314a8f1fc6406a85e536c01b75b27495c87d3b2096d9098414455359d8538`)
ran seven quiet probes: old/new native stores interleaved three times, then a
capture-texture control. At 768×1024 on M2 Ultra, each used three warmup frames
and 20 measured synchronous offscreen frames with reused targets and no readback.
Both native variants drew 20 items/57,717 triangles; live slots were 15/16 and
the capture-provider control resolved 20. The native pose and source vertex
streams use the controlled capture camera; this measures frame work, not displayed
FPS or arbitrary animated Studio scenes. Old/new PNGs were deterministic within
each three-run group. The new store also changes BC1 interpolation precision, so
this is the complete store expansion cost, not a pure material-count experiment.

| Metric (median of three run p50s) | Old store, 15 live | New store, 16 live |
| --- | ---: | ---: |
| CPU encode | 0.276 ms | 0.307 ms |
| GPU | 0.536 ms | 0.623 ms |
| Completion | 1.209 ms | 1.296 ms |
| Registered textures | 70 | 76 |
| Metal allocated bytes | 495,960,064 | 543,358,976 |

Run GPU p95 ranges were 0.552–0.632 ms old and 0.658–0.669 ms new. Resolving
the extra material increases work and inputs; no speedup is claimed. The first
app composition of the top cost 113.199 ms total (102.915 ms CPU encode, including
pipeline creation). Later process-first compositions cost 15.079 and 12.931 ms.
These are assembly costs, not per-frame costs, and Metal driver caches were not
purged between launches.

Three separate Release regression runs each performed 15 warm recolours plus
unchanged lookups and a revert. Their edit medians were CPU 0.051–0.052 ms,
GPU 0.085–0.096 ms, total 0.626–0.846 ms; unchanged lookups were
0.105–0.118 ms. Each target occupied 5,652,480 Metal bytes. The isolated
process-first compositions cost 13.988–18.421 ms after the app probes; they do
not supersede the larger first-use app result. Two asset uploads, one default
and one sampler stayed constant across the edit loop; each released edited
target expired, and reverting while the original target remained live reused
that exact target and its pixels.

The fixture-backed Engine suite before the accepted-main merge passed 788 tests
with two named skips (the opt-in expression timing probe and the unavailable
independent raw appearance-reference root), plus 21 CoreMath tests. Final merged
Release checks passed the controlled live-family gate and distinct eye-colour
gate, plus all three independent top cost/output runs. Reverse tooling passed
444 tests with six optional skips; verification tooling passed 190 tests. The
focused converter suite passed 20 tests, including explicit
vertical-block/green-endpoint coverage. Debug/Release Engine and clean merged
Release app builds succeeded. Quiet runs preserve whole-frame colour failures
from the four fallbacks; family gates are not whole-character parity. Three opt-in-off production pairs
(source Studio, native Studio and Maker, 960×880) produced byte-identical PNGs
against the retained accepted-main Release app (built at `4e80d8c`, runtime-source
identical to `b2dde03`; binary SHA-256
`8c948933dee435e684bd73fa7bd959aaae41b2f66349d6d948d5f5dc7e6057ce`).
All six launches exited successfully. Private head/store/bindings and both
original captures are retained independently of the worker checkout with their
relative payloads and a complete file-hash inventory; global fixture promotion
is a separate maintainer step.

### Composite sampler allocation (R1/CMT-04, 2026-10-24)

`TranslatedSourceProgram.SamplerConfiguration` now normalizes sampler state as
an internal value before `SourceShaderTextureStore` looks up its per-resource
sampler cache. An `MTLSamplerDescriptor` is constructed only on a locked miss.
The public descriptor API uses the same normalization. Raw filter/wrap/aniso
strings still participate in composite identity, even when they normalize to
the same GPU sampler; quality settings, weak owner/device boundaries, generated
target ownership and all input validation remain unchanged. This changes
assembly/edit lookup work, not rendering per frame or live-slot coverage.

**Allocation evidence.** A private Objective-C observer in isolated Release test
processes counts public `MTLSamplerDescriptor` constructions once, excluding the
class cluster's internal forwarding. Its positive control counts exactly 44
constructions from the 22-case descriptor test. The unchanged synthetic cache
test (initial assembly, 20 unchanged hits, recolour/revert and a replacement
resource owner) falls from 48 constructions to 4: two distinct cold sampler
states for each owner, none on the unchanged hits. A concurrent test with 16
requests across two owners constructs 2 descriptors and produces exactly two
composites, one per owner. This instrumentation is private and is never linked
into the application or used in timing measurements. The machine has one Metal
device; cross-device behavior is preserved by the existing resource-owner
boundary, not established by a second-device run.

**Uninstrumented Release timing.** Three isolated pairs on M2 Ultra, ordered
old/new, new/old, old/new, each run the existing normal-top regression with 15
warm edits and 15 unchanged hits. Per-run median unchanged-hit costs are
0.130/0.103/0.107 ms before and 0.119/0.116/0.101 ms after. The ranges overlap;
median of run medians is 0.107 → 0.116 ms. These samples do not establish a timing
speedup. First composition is 12.163–13.209 ms before and 12.437–13.163 ms after
with the driver cache already warm; edit GPU medians are 0.086–0.093 ms and
0.085–0.088 ms respectively. Two asset uploads, one default texture and one
sampler stay constant through the top edit loop. No FPS, startup-compilation or
whole-app performance claim follows from this allocation reduction.

The baseline is the retained `f52cfa87` Release Engine test bundle, SHA-256
`706212cf7412c3447247b68dfdcf107a0c41419b7ce47e56bd4ce308f1cd16a9`.
All material/compositor/GPU, Character/Assets/math, package configuration and
controlled-test sources are byte-identical to the accepted `9ee3ab93` base. The
only intervening Renderer difference is an unrelated `CaptureRequest` startup
input registration, unused by these direct tests. The candidate is `60dca9bf`,
Release with `-Xswiftc -enable-testing`, test binary SHA-256
`0536c203f13d272127ea5ef972a871a116332ace6b7884c1a627f280999ecc82`.
Both use the retained normal-top inputs documented above; private provenance,
input paths/hashes, observer source/calibration and ordered logs are under
`.local/codex-continue-2026-10-24/wave-three/materials/`.

**Validation.** Debug and Release each execute 9 focused checks successfully, with
one named skip (`liveSourceCompositesMatchTheDistinctColourCapture`, missing
private inputs in those invocations). The checks include 22
literal normalization cases, raw-distinct/effective-equal sampler metadata,
concurrent cold requests and owner release/replacement. Five strict private
Release gates pass: controlled live frame, base iris, base eye-white,
distinct eye colours (including the previously skipped gate) and base/distinct
normal top. The top base is byte-exact;
the colour edit retains max 1 byte with 1,235 differing channels. Existing hair
and eye limits are unchanged, and controlled native coverage stays 16/20.
This slice adds no UI behavior and makes no new app/VM capture claim.

**Later combined application check.** The Release build at `6ff81db` has the
merged #165/#166 runtime sources (identical to `b302a27`) and passes all 24 plugin
scenario checks. Replaying the retained live-material probe keeps its 16 live
and four fallback slots, attachment report and composite content keys unchanged.
Ten native output PNGs covering toon, geometry, opaque garments, eyes, nose and
items are byte-identical to the retained run and a fresh pre-change/new pair.

Strict equality of every live image is not established. Three retained runs of
the same pre-change executable already vary by four to five hair pixels (maximum
one to two byte levels) and one full-frame pixel (maximum two). A fresh pair and
a repeat of the new executable reproduce small differences; one front-hair pixel
also varies within the new executable. The arithmetic cause remains unassigned.
This is a live-capture repeatability gap, not evidence for a new tolerance or an
all-pixels-identical claim. Existing source comparison limits are unchanged.
The private `wave-three/integration` evidence retains both the initial strict
comparison failure and the repeat measurements. These runs do not measure speed.

### Native normal-bottom composite (R1/CMT-04, #168, 2026-10-24)

The normal-clothes recipe also handles clothing slot 1, using its own saved
`colorInfo` fields. The independently checked selection is category 106, ID 3
(`p_o_bot_pants03`, `o_bot_pants03`), high detail, `rendNormal01` only, with all
three pattern IDs zero. Recovered `InitBaseCustomTextureClothes(true, 1)` loads
`cf_m_clothesN_create`; `ChangeCustomClothes(true, 1, …)` reads
`nowCoordinate.clothes.parts[1]`. This is the same verified create material and
`create_topN` program identified above, despite the shader's name. Other clothing
slots, secondary/alpha roles, low-detail inputs and unverified patterns retain
explicit fallbacks. A synthetic fixture supplies a conflicting valid top and
checks all bottom colors, tiling and source paths; missing bottom fields cannot
fall back to top values.

| Input | Exact identity | Decoding and sampler |
| --- | --- | --- |
| Main | `cf_bot_pants03_t`, path ID `1799539927781456382` | Linear BC1, 512×1024, one authored mip |
| Color mask | `cf_bot_pants03_mc`, path ID `2152893568627913941` | Linear BC7, 512×1024, one authored mip |

Both inputs use Bilinear/Repeat/aniso 1 and belong to
`chara/co_bot_00.unity3d`, SHA-256
`99ca895979e691caf55c1a68a4ffd9a6892b3d8fdfe9b260cb0812cd5fbf9d29`, serialized
file `CAB-633e5b9224bb4b60a1d0f9eeb80cf32d`. The target is 512×1024 with 11
**generated** mips, Bilinear/Clamp/aniso 1 and sRGB ARGB32-equivalent output.
Only target level zero has independent GPU readback evidence; the remaining
levels are structural checks. The existing offline BC1/BC7 conversion paths are
unchanged, and no texture decoding is added to runtime frame work.

**Independent original-player evidence.** One new capture changes only the
bottom's first three base colors to `(0.68,0.12,0.83,1)`, `(0.07,0.74,0.29,1)`
and `(0.91,0.38,0.05,1)`. `Custom`, `Parameter` and `Status` card blocks remain
byte-identical to the retained base. In all seven coordinates, only those nine
RGB lanes differ; coordinate tails and all other garment fields remain equal.
The producer source SHA-256 is
`7e0cfe8ad328438581244e890e045e00a11a1ea2662109c1cdd6f6da730838e0`.

| Target level zero | Readback SHA-256 | Native error in encoded RGBA8 |
| --- | --- | --- |
| Retained base | `e896dd7f15c967a5ca310eb46448cafcce5dd601a3b8995bee32f7a0e9e5393d` | Max 1 byte; 376 of 2,097,152 channels differ; mean 0.00017929 byte |
| Distinct bottom colors | `8b5641111b0c210c872ff26ce522de1c7846e3d511b32295e6c2a28c07d58ae6` | Max 1 byte; 1,279 channels differ; mean 0.00060987 byte |

The same capture reads back the selected source main/mask inputs and records
bundle/name/format/dimensions/mips independently. Comparing its filtered GPU
blits with the offline texels gives maximum linear error 0.001953125 for the
main (mean 0.00015604) and 0.00048828125 for the BC7 mask (mean 0.00000294).
These input diagnostics are not exact raw-texel claims. Both final target
comparisons pass the existing one-byte gate without changing shader coefficients,
card colors or tolerances.

**Live coverage and resources.** The rebuilt native store has 54 asset entries,
three create programs and zero unavailable entries; all prior 52 entries and all
program bytes are unchanged. Its path-independent content fingerprint is
`8cd05439c63bf8d4a75e1d66a88d5c7161ac709afd7312803d3141cbc3bf7a0c`.
The controlled native pose/vertex-stream fixture resolves 17/20 live slots;
body, face and shoes still fall back. On `main_opaque` pixels frontmost in both
the complete capture-provider and native subsets, 74,401 pixels have mean
0.04965 byte error and p99 1. Existing hair and eye gates pass unchanged. This
is a controlled native scene comparison, not whole-character production parity.

The base/edit/revert test retains two asset uploads, one white default and one
sampler. Unchanged requests return the same texture, 15 released edited targets
do not accumulate, and reverting returns the original cached target and pixels.
Debug and Release CPU validation each pass five tests (six parameterized cases),
including original binding and half-state checks. All six strict private Release
pixel/resource gates pass with no skips. Probe Python tests pass 15/15, texture
converter tests 20/20 and verification-tool tests 191/191.

**Release costs and output controls.** The clean runtime commit `b178932` built
binary SHA-256 `eb739a3944dd896a83081f058d52ce1b0a19ca9d9b42724c5101bc8429564fc5`.
Seven quiet launches use that same binary in old/new, new/old, old/new order,
followed by a capture-provider control. The old store has 52 entries; the new
store adds only the two bottom inputs. Each launch measures 20 synchronous
offscreen frames after three warmups at 768×1024 with reused targets and no
readback. These timings include the native rig under the controlled capture
camera/light/time; they are separate from the frozen-geometry pixel comparison.

| Frame cost, ms | Old store, median of three run p50s (range) | New store, median of three run p50s (range) |
| --- | --- | --- |
| CPU encode | 0.318 (0.258–0.331) | 0.281 (0.280–0.291) |
| GPU | 0.631 (0.578–0.635) | 0.655 (0.613–0.695) |
| Synchronous completion | 1.324 (1.189–1.355) | 1.309 (1.255–1.333) |

The overlapping ranges establish no frame-time speedup. Registered textures
increase from 76 to 81 and Metal allocation from 543,358,976 to 561,725,440 bytes
for the fuller material path; neither number is a process-wide leak test.
Three fresh Release test processes measure bottom first-use totals of
11.348–11.803 ms, including pipeline creation with a potentially warm driver
cache. Across 15 recolors per process, median CPU encode is 0.038–0.041 ms,
GPU 0.078–0.086 ms and total 0.626–0.881 ms. Unchanged lookup is
0.098–0.100 ms with no new composition or upload. Each generated mip chain
occupies 2,834,432 bytes; the lifetime/revert assertions above bound retained
edited targets.

Source Studio, native Studio and Maker each produce a byte-identical default-off
960×880 PNG pair against the preserved `f52cfa8` Release binary
`04e314a8f1fc6406a85e536c01b75b27495c87d3b2096d9098414455359d8538`.
That historical build is an output control, not the paired performance baseline.
Repeated opt-in frozen renders still vary at a few pixels: old-store runs differ
at up to four hair pixels (max 2 bytes) and two whole-frame pixels (max 14 bytes);
new-store runs differ at one hair/whole-frame pixel (max 2 bytes). Other repeated
native PNGs are identical within each provider group. The strict isolated hair,
eye and composite gates remain unchanged; no all-live byte-equality, full
character parity or window/FPS claim follows from these offscreen controls.
Private reports, source/binary hashes and preserved binaries are under
`.local/codex-continue-2026-10-24/rolling/materials-bottom/`.
**Combined application acceptance.** Release build `04225ae` combines this
material path with the accepted plugin runtime; its runtime sources match merged
`76ce58a`. Binary SHA-256
`bc9af1f86a1a60c27e084ab57b0410ad93c370dd542b2aace100e47514a5e29c` passes all 24 plugin
scenario checks. Replaying the same 54-entry input store retains 17 live and
three fallback slots, identical attachment reports and composite content keys.
Ten stable native diagnostic PNGs are byte-identical to the measured `b178932`
build, and the full-frame PNG also matches in this pair. Five hair pixels differ
by at most two channel levels and one front-hair pixel by one, consistent with
the separately retained repeatability gap. This is bounded integration evidence;
it neither establishes whole-image equality nor adds a source-parity or timing
claim. The private `rolling/integration-bottom` directory retains build/input
hashes, owned process exits and per-image differences.

The private fixture key is `IKKOKU_BOTTOM_COMPOSITE_PROBE`; see
[the fixture contract](../../Tools/verification/README.md#composite-colour-capture-fixture).

### Native normal inner-shoe composite (R1/CMT-04 #177, 2026-10-24)

The bounded normal-clothes recipe supports inner shoe slot 7, selected through
`ChaControl.ChangeClothesShoesAsync(type: 0)` and the normal `rendNormal01`
creator. The explicit supported slots are 0, 1 and 7; outer slot 8 remains
unresolved. Patterned, secondary, alpha, emblem, accessory and special-male
branches retain their existing unsupported reasons. The native path resolves
and composes at material assembly; conversion stays offline, and draws reuse
the assembled textures.

The controlled card selects catalog 112/id 3 (`p_o_shoes_run01`) with saved
`shoesType == 0`. Its active `ct_shoes_inner` renderer is `o_shoes_run01`.
Changing outer-slot colors first left the displayed target byte-identical:
that capture is a negative visibility control, not evidence for outer-shoe
composition. The subsequent inner-color capture changes only the nine RGB
components in slot 7’s first three base colors in each of seven coordinates.
Every other card block, including Status, and all other coordinate data remain
unchanged. The probe records the selected slot/type/catalog/object activity and
the direct `rendNormal01` `_MainTex` file, avoiding an ambiguous mesh-name match.

The source producer SHA-256 is
`c8188d3384241d47cc285dbf72e44373650d629c46f19f06490a8e5d65084551`.
The selected bundle `chara/co_shoes_00.unity3d` has SHA-256
`dde13cf97a4160d9d13cb8ea8102c7ba6e6c092908855180110c6391cf6066d0`,
serialized file `CAB-b9a8ff574f24c2b427e59cd30ae00421`.
Its main texture `cf_shoes_run01_t` (path ID `-7640729741191341103`) is
sRGB BC7; `cf_shoes_run01_mc` (`-2274634555552161051`) is linear RGB24.
Both are 512×512, Bilinear/Repeat/aniso 1, with one authored mip. The source
normal-clothes create program is the already verified `d709d6fc…` program;
the 512×512 sRGB target has ten generated mips. Only base-level input/target
pixels have independent original-player readbacks. Input float16 comparisons
have maximum absolute difference 0.00048828125 for both main and mask; this
does not substitute for the strict final composite comparison.

The isolated native store adds those two inputs to the accepted 54-entry store.
All prior entries and all create-program identities/bytes are unchanged; the
normal program’s use list adds the inner shoe. The path-independent content
fingerprint is `39b9ac57ffe55f523b0722468f869f4f94eda6e21fb123506c77b5eae85c3656`.
The regression selects the visible slot explicitly, checks hidden outer 8 stays
unresolved, and retains the existing base/distinct-color max-one-byte gate,
unchanged-hit, recolor/revert and released-target checks. All seven strict
Release GPU checks pass, with no skips: the base/distinct shoe targets have
maximum one-byte error in 2,295/1,495 of 1,048,576 channels. The exact live set
increases from 17 to 18 of 20 slots; body and face remain unresolved. Five
composite keys are retained, with the existing shared iris/eye-white hits.
Hair, eye, top and bottom gates retain their thresholds and pass. Each shoe
recolor releases its target; 15 edits retain two uploaded asset textures, one
default texture and one sampler, and revert returns the original target.
The Release app was built from clean `d63d601` (binary SHA-256
`7e092c7366e7819b27190bde145a2e4db46d4e58fb453320fe5a92b8b5cebfc6`).
The later `03d7c09` merge changes no app, Engine source or shader bytes relative
to that measured source. Seven launches used that same binary in the order
old54/new56/new56/old54/old54/new56/capture. Each measures the live native rig
at a held camera/time, 768×1024, with three warmup and twenty measured offscreen
frames; original captured meshes are not drawn. Median run-p50 costs (range of
three run p50s), in milliseconds, were:

| Work | Old 54-entry store, 17 live slots | New 56-entry store, 18 live slots |
| --- | ---: | ---: |
| CPU encode | 0.278 (0.277–0.287) | 0.312 (0.310–0.325) |
| GPU | 0.617 (0.611–0.696) | 0.662 (0.661–0.700) |
| Completion | 1.240 (1.238–1.338) | 1.321 (1.318–1.388) |

The additional live material increases registered textures from 81 to 85 and
Metal allocated bytes from 561,725,440 to 570,540,032. This is additional coverage,
not a speedup or an interactive FPS result. The capture-provider launch resolves
20/20 slots but is a correctness control, not an equal-work performance baseline.
Three isolated Release processes measured first-composition totals of
12.081/11.995/12.152 ms (CPU encode 2.190/2.136/2.211 ms, GPU
8.480/8.518/8.605 ms), including first pipeline creation; driver caches may
already be warm. Their fifteen warmed edits each had median total costs
0.837/0.437/0.445 ms and unchanged hits 0.100/0.106/0.106 ms. Each target uses
1,425,408 bytes. Repeated edits remain bounded by the resource checks above.

Six default-off launches compare source Studio, native Studio and Maker at
960×880 against the preserved historical `f52cfa8` app (binary `04e314a8…`).
All three baseline/current image pairs are byte-identical. That historical app
is an output control, not a newly built current-main performance baseline.

**Separate translated-draw repeatability limit.** Two same-provider opaque
captures in each process use the same frame and textures:
`native-translated-main_opaque.png` and `native-main_opaque.png`; neither is an
untranslated-renderer control. The current native provider differs by
29/28/47 shoe-local pixels (maximum channel delta 5/8/27) across the three
processes; the current captured provider differs by 19 pixels, maximum 8.
An unchanged pre-PR app, built at `f52cfa8` with binary `04e314a8…`, also draws
20/20 captured-provider slots, including the shoe, and differs by 17 shoe-local
pixels, maximum 5, between its duplicate captures. Its input hashes match the
current captured-provider run. This establishes that a draw repeatability gap
predates the new compositor; it does not equate the magnitudes or prove their
complete cause. Whole-frame repeat equality and full source-color parity are
not claimed.

Private diagnostics read all ten target mip levels before/after repeated draws
and recompose base/distinct targets under three fresh owners: every level is
stable. This is native determinism evidence, not independent source-GPU parity
for uncaptured mip levels. Fixed-LOD-zero sampling removes repeated-draw
variation, whereas postponing discard with its predicate preserved does not.
Those altered shaders are diagnostic only; production sampling and every source
gate remain unchanged. The remaining sampling behavior is tracked separately.
The diagnostic host is Apple M2 Ultra, macOS 27.0.1, with fast math disabled.
A separate JavaScript/Objective-C options query reported MSL 4.1; it did not
record the earlier test process's effective compiler options. The later
in-harness prefix control below records MSL 4.0. Neither context supports
applying the obsolete pre-Metal-2.3 discard rule.

Private evidence, exact per-run values and pixel coordinates are under
`.local/codex-continue-2026-10-24/rolling/materials-shoes/`; the private fixture key
is `IKKOKU_INNER_SHOE_COMPOSITE_PROBE`. The original-player pixel evidence remains
pinned to producer `c8188d…`. After merging the accepted `03d7c09` model probe,
the combined producer `c4df9bf4460f995d84dd240bb2e5bf64ad791ae6c1e82c3fa2cfa3d5d519f85e`
compiles against the original managed runtime with no diagnostics and no player
launch; it does not relabel the captured evidence. The affected merged Python
suites pass 78/78; Debug and Release derivation each pass seven tests with ten
parameter cases, and the verification Python suite passes 191/191.

### Native female head-0 face composite (R1/CMT-04 #219, 2026-10-24)

The opt-in live source path derives the face creator recipe for female sex 1,
`exType == 0`, head 0, high detail, material slot 0 of `cf_O_face`. It requires the
exact head catalog, `cf_m_face_00` draw material, `cf_m_face_create` creator,
`create_head` program and three input asset identities. Resolver-backed or other
head identities, low detail and nonzero selected makeup/lip-line/mole layers
remain explicitly unresolved. Coordinate makeup is selected only when the saved
raw enable byte is nonzero; otherwise the base makeup record is used. Inactive
makeup cannot substitute for that selection. Null selected layers preserve the
source material defaults and card-derived colors/layouts. Composition uses the
existing native GPU compositor during material assembly, with offline asset
conversion and cached targets reused by draws. No sampling, alpha-test or shader
language behavior changes.

The creator is `cf_m_face_create`, path ID `4119387422725910578`, in
`chara/mm_base.unity3d` (SHA-256
`3944a1d7a9e446f15714bcca0b2faebd7b760fdc010139fad677ce24c422175e`),
serialized file `CAB-0d1f3d8317188244dde38c81a889d1d4`. Its recovered program is
`9ec842e7b29577b0fd4ddb8ffcfc25c288471210b90ab7a312c3e7a9225df72c`.
The main texture `cf_face_00_t` (path `4156981771398184683`) and mask
`cf_face_00_mc` (`5632470389437020241`) are linear BC7, Bilinear/Clamp/aniso 1,
from `chara/bo_head_00.unity3d` (SHA-256
`e6ded0a39b1ca521648597d31d9f868fe354963279a8ccf4140212598289cf7e`),
serialized file `CAB-b45f3dc6094104fda1eb384293a73f74`. The authored
`cf_face_00_mp` paint mask (`4688923211121552405`) is a linear DXT1 dependency
of the exported creator material in `mm_base`, with Bilinear/Repeat/aniso 1.
All three are 1024×1024 with eleven authored mips. The target is
1024×1024 sRGB with eleven generated levels.

Fresh independent original-player base and distinct-color captures verify the
active loaded head, renderer-material object equality, creator target and input
object identities. The paint mask is obtained through the exact exported
creator material's dependency, because it is not a container-exported texture.
The original normally releases main/mask and five layer bindings after
composition. The diagnostic temporarily disables that cleanup before load,
records the bindings, calls the original face-input release, takes a second
fresh readback of the same target and verifies unchanged target bytes and draw
identity before restoring the flag. Other creators temporarily retain inputs
as well; this probe does not establish default input lifetime or original
runtime cost. Static CIL comparisons bridge the actual Studio assembly to the
retained source recovery for this lifecycle. Failed observations before these
corrections remain in the private evidence.

Only six decoded RGB components change between source cards: body skin-main
`[0.95, 0.75, 0.65]` to `[0.23, 0.61, 0.82]`, and skin-sub
`[0.8, 0.45, 0.4]` to `[0.72, 0.28, 0.16]`; alpha stays 1. These shared skin
inputs also affect body composition and eyeline shadow. Other decoded Custom values and raw face/hair Custom blocks remain unchanged;
Coordinate, Parameter and Status blocks are byte-identical. The three source input
readbacks match across cases; the face targets differ. The fixed producer SHA-256 is
`5059f6828649621fb7f399f2e29930fb13cb8bfa6fa2b3ca99b4d4b5132d0fc1`.
The base/distinct frame hashes are `09f49807…` / `08948c32…`, card hashes `262f5968…` / `8f773e48…`,
and target hashes `ebe4df22…` / `efc3326e…`. Only base-level source pixels were
read back: authored mip structure and native generated levels are not
independent original-GPU mip parity evidence.

The isolated store adds three assets and the face creator to the existing
56-entry store: 59 assets, four creator programs, zero unavailable entries.
All 56 prior entries retain exact metadata and level hashes. Its canonical
content fingerprint is
`7b7a0a65914c46d0ab31cd72f33893aca14a0178ac5adc158bbd99c5a2c37527`.
Native decoded base-input differences versus source float16 readbacks have
maximum absolute error 0.00048828125 for main/mask and 0.006591796875 for the
paint mask. These differences are retained explicitly; the decoder and strict
final composite tolerance were not changed.

Five CPU derivation regressions pass at `9f0026e`. The initial Release test
build failed at dependency-module import; a fresh scratch build with testability
enabled passed before GPU execution. Both attempts remain recorded. The face gate
passes at `f93a49b` / test binary `723b8877…`: base and distinct targets each
stay within one byte in every channel, with 1,668 and 4,702 differing channels
of 4,194,304. Fifteen distinct recolors release their targets and retain exactly
three registered inputs, one default and two sampler states. Unchanged recipes
reuse the same target without uploads; reverting reuses the held base target
with identical bytes. Six existing eye/garment gates pass at that same build.
The live-frame test initially failed only its expected face label, which omitted
the existing absent-COLOR/white/unverified convention warning. A one-literal
repair preserves that complete warning; the single live gate then passes at
`76ecee6` / `cf30e09a…`, retaining every earlier quality threshold. No earlier
run is relabeled as the repaired build.

The controlled native store resolves 19 of 20 slots, up from 18 with the
unchanged 56-entry store; the body remains the single toon fallback. Six unique
composite keys are retained, including the shared iris/eye-white hits. Seven
launches of the final `421e455` Release app (`8be2e4d8…`) use the order
old56/new59/new59/old56/old56/new59/capture. Each draws the live native rig under
held original camera/light/time, at 768×1024, with three warmup and twenty
measured synchronous offscreen frames using reused targets. Original captured
geometry is not drawn. Median run-p50 costs (range of three run p50s), in
milliseconds, are:

| Work | Old 56-entry store, 18 live slots | New 59-entry store, 19 live slots |
| --- | ---: | ---: |
| CPU encode | 0.346 (0.291–0.352) | 0.384 (0.319–0.391) |
| GPU | 0.710 (0.704–0.711) | 0.831 (0.825–0.936) |
| Completion | 1.412 (1.374–1.460) | 1.609 (1.583–1.644) |

Registered textures increase from 85 to 91 and Metal allocated bytes from
570,540,032 to 622,706,688, fixed across each condition's three runs. This is the
cost of added coverage, not an equal-work speedup. The captured-pixel control
resolves 20/20 but does not supply native compositor inputs. Other owners held
heavy work during the measurement window; the existing background VM remained
open and unmanaged, an uncontrolled host condition.

Three isolated Release processes use the archived `76ecee6` / `cf30e09a…` test
bundle. The timed compositor path, its dependencies, recipe derivation, test and
package configuration are byte-identical to `421e455`; merged Maker/Studio
setup changes are outside that timing boundary. No whole-test/setup equivalence
is claimed. First compositions, including first pipeline creation in each
process, take 12.755/13.608/13.021 ms total (CPU encode
2.430/2.239/2.313 ms, GPU 8.711/9.649/9.011 ms). Driver and filesystem caches
may already be warm. Fifteen warm recolors per process have median total costs
0.677/0.652/0.569 ms, GPU 0.108/0.108/0.108 ms and unchanged hits
0.130/0.134/0.134 ms. Each target reports 5,652,480 allocated bytes; the fixed
input/default/sampler and released-target checks pass in all three processes.
An earlier helper launch failed before tests because XCTest's search path did
not survive the shared-lock wrapper. Its failure is retained; the successful
three-process run sets those paths after the wrapper, with unchanged test and
fixture bytes. The seven successful app probes were not rerun.

All seven app runs have byte-identical toon, geometry and depth-normal control
PNGs. The duplicate same-provider opaque draws still vary: old-store runs differ
at 10/30/38 pixels (maximum channel delta 2/8/8), new-store runs at 40/44/46
(maximum 8/27/27), and the captured provider at 24 (maximum 8), in the existing
shoe-region bounds. Both images are translated draws of the same frame and
textures. These observations retain the separate #188 limit; they do not prove
its cause or whole-frame repeat equality.

Six default-OFF Release launches compare source Studio, native Studio and Maker
at 960×880. Each accepted-main/candidate PNG pair is byte-identical. The control
is the preserved `e984432` build (`ad80d4b1…`), whose Apps/Packages/Shaders bytes
match accepted main `66b637`. The final clean candidate `421e455` (`8be2e4d8…`)
differs under Apps/Engine Sources/Shaders only in the face recipe. The historical
control is not relabeled as a new main build.

This remains a controlled material-resolution and target-composition result.
Body remains unresolved; unsupported heads/layers, absent-COLOR conventions,
scene-global recovery and the separately tracked #188 translated-draw
repeatability gap remain open. It does not establish full source-color parity,
whole-frame repeat equality or an interactive FPS improvement. Private evidence
and exact commands/hashes are under
`.local/codex-continue-2026-10-24/rolling/materials-face/`; the optional original
fixture keys are `IKKOKU_FACE_COMPOSITE_BASE_PROBE` and
`IKKOKU_FACE_COMPOSITE_PROBE`.

### Native ordinary female body composite (R1/CMT-04 #231, 2026-10-24)

The opt-in live source path derives the ordinary female body creator recipe for
sex 1, `exType == 0`, high detail, body record `0.0.2`, and visible material slot
0 of `o_body_a`. It requires the exact `cf_m_body` draw material,
`cf_m_body_create` creator, `create_body` program and three input asset
identities. Unsupported body identities, low detail, resolver-backed selections,
nonzero body paint/layout and sunburn remain unresolved. The body skin-main,
skin-sub and nail colors come from the body record; conflicting face or garment
values cannot replace them. The absent sunburn layer keeps the source white
texture default, while the two absent paint layers keep black defaults. Alpha
is 1. Composition uses the existing GPU compositor during material assembly;
asset decoding stays offline and unchanged recipes reuse cached targets. No
sampling, alpha-test, language, decoder or tolerance changes are included.

The creator is `cf_m_body_create`, path ID `-8385327033008235336`, in
`chara/mm_base.unity3d` (SHA-256
`3944a1d7a9e446f15714bcca0b2faebd7b760fdc010139fad677ce24c422175e`),
serialized file `CAB-0d1f3d8317188244dde38c81a889d1d4`. Its recovered program is
`6dec09eabb8464f6b79b6a97e978631187ca77d992a99de1a6d0fd9ffc43e1c5`.
The main `cf_body_00_t` (`5340205562146712601`, 2048×2048 RGBA32) and mask
`cf_body_00_mc` (`-3685019629691781346`, 1024×1024 RGB24) are linear and each
has one authored mip, from `chara/oo_base.unity3d` (SHA-256
`2bb9017d29b12352a859f54623728e4dea587392d3677a0a7158a7f9784fba67`),
serialized file `CAB-e7b38e3d86248bd1d2c54a91cd5fca51`. The 1024×1024 sRGB
DXT1 paint mask `cf_body_01_mp` (`7680453631034146393`) is a dependency of
the exported creator material in `mm_base`, with eleven authored mips. All
three authored samplers are Bilinear/Repeat/aniso 1; the source frame's
`ForceEnable` policy is retained. The target is 2048×2048 sRGB with twelve
generated mip levels.

Two fresh independent original-player captures verify the active ordinary body,
renderer/material/creator/target object chain, and each input object identity.
The original normally releases main/mask and three layer bindings after
composition. The diagnostic temporarily retains these inputs before load, then
calls the original `ReleaseBodyCustomTexture`, reads the same target again and
requires byte-identical output and unchanged draw identity with all five
bindings cleared. It restores the release flag afterward. Other creators also
temporarily retain inputs; this does not establish default input lifetime or
original runtime cost. The actual Studio assembly is `902b9a23…`; the fixed
probe producer is `5ce751ad…`. Static lifecycle evidence and an independently
disassembled original fragment are retained separately from native compilation.

Exactly nine decoded RGB components change: skin-main `[0.95, 0.75, 0.65]` to
`[0.23, 0.61, 0.82]`, skin-sub `[0.8, 0.45, 0.4]` to `[0.72, 0.28, 0.16]`,
and nail `[1, 1, 1]` to `[0.17, 0.76, 0.31]`; alpha remains 1. Shared skin
values also affect face composition and eyeline shadow. Other decoded Custom
values and raw face/hair Custom blocks remain unchanged; Coordinate, Parameter
and Status blocks are byte-identical. All three input readbacks match across
cases, while base/distinct targets `5e3590f0…` / `745c4638…` differ. The frame
hashes are `d2adfb99…` / `57c55d57…`, and cards `cab05f69…` / `0bce8c9d…`.
Only base-level input/output source pixels were read back; authored/generated
higher mip structure is not independent original-GPU mip parity.

The isolated store adds three assets and one creator to the accepted face store:
62 assets, five creator programs and no unavailable entries. All 59 old asset
records and four creator records retain identical metadata and file bytes. The
manifest is `1b89b908…`; canonical content fingerprint is
`b9ae136b9d4537bb8809f9f6207fb4ebdafbfa66ba0a4d4466b20ac83b4eadce`.
The 442-file primary evidence copy preserves every byte and relative dependency;
absolute conversion provenance remains unchanged. No shared fixture environment
was promoted. Native decoded input comparisons retain maximum absolute errors
0.00048828125 for main alpha and mask, and 0.00634765625 for the sRGB paint
mask; main RGB and paint-mask alpha are exact. No decoder or final-target
threshold was adjusted to fit these differences.

Five CPU derivation regressions pass at `f5fdb817`. The updated contract/probe
Python suites pass 21/21 at `90ad9945`. Release test binary `fac99f9f…`, built
at `90ad9945`, passes the new body gate and all eight existing eye/garment/face/live
checks. Both body targets differ from the independent references by at most one
byte in every channel: 5,619 and 859 differing channels of 16,777,216, all error
1, with alpha 255. Fifteen distinct recolors release their targets and retain
three registered asset inputs, two default textures and two sampler states.
Unchanged recipes reuse the same target without uploads; reverting reuses the
held base with identical pixels. Seventeen distinct content keys are observed.
Each composed target reports 22,560,768 Metal allocated bytes. Existing source
quality thresholds and absent-COLOR convention warnings remain unchanged.

After merging accepted Models/Plugins main `99a6bfb0`, the final clean app source
is `69702e54`; the twelve body-owned files and earlier test archives remain
byte-identical. Its Release binary `5d8b4b75…` passes bundle inspection. Six
960×880 default-OFF launches compare source Studio, native Studio and Maker
against the retained face control `d4457c6f` / `f8fa8b97…`. Each pair is
byte-identical and each baseline matches its historical PNG. The two app
producers also differ in accepted Models/Plugins changes; this is an integrated
output check, not a claim that the face control differs only in this recipe.

Seven same-final-binary launches use old59/new62/new62/old59/old59/new62/capture.
The old store resolves 19/20 with the exact missing-body-program diagnostic;
the new store resolves 20/20, with zero fallbacks or unmatched slots. The six
prior composite keys are unchanged, and the body adds one miss: seven unique
keys and nine events. Its observed live key `4f6ed847…` matches the isolated
base key even though the card files differ; this equality was measured rather
than assumed. The captured-pixel control resolves 20/20 without native
composition events. Original captured geometry is not drawn: this is the live
native rig under held original camera/light/time, 768×1024, three warmup and
twenty measured synchronous offscreen frames with reused targets/no readback.
Median run-p50 costs (range of three run p50s), in milliseconds, are:

| Work | Old 59-entry store, 19 live slots | New 62-entry store, 20 live slots |
| --- | ---: | ---: |
| CPU encode | 0.332 (0.326–0.368) | 0.389 (0.363–0.413) |
| GPU | 0.855 (0.838–0.903) | 0.889 (0.878–0.916) |
| Completion | 1.619 (1.580–1.629) | 1.618 (1.612–1.655) |

Registered textures rise from 91 to 99 and Metal allocated bytes from
622,706,688 to 725,204,992, stable within each condition's three runs. These are
added coverage costs, not equal-work speedup or interactive FPS evidence. The
three new-provider body preparation events take 140.685/2.324/1.930 ms total,
including reported first pipeline creation in each process; CPU encode is
139.056/0.321/0.330 ms and GPU 0.210/0.209/0.208 ms. The first-process spread
is retained without assigning a cause or claiming a cold driver-cache control.
Other owners held heavy work during the bounded quiet batch. The prelaunch
snapshot still contained an unmanaged VM at 3.1% CPU and four old Cursor
processes at 0.1% each; this was not machine-wide isolation.

Three isolated quiet processes use the archived `90ad9945` / `fac99f9f…`
Release bundle. The compositor, dependencies, derivation/test/config and library
lookup prefix used by this test are byte-identical to final source. The merged
Maker appearance grouping/lease code is outside this call path and measured
regions; the whole Character module and process setup are not claimed equivalent.
First compositions including pipeline creation take 16.194/13.092/13.073 ms
(CPU 4.052/2.273/2.291, GPU 9.221/8.307/8.457). Fifteen warm recolors per
process have median total 1.137/1.091/1.126 ms, CPU 0.057/0.053/0.063 and
GPU 0.196/0.198/0.193 ms; unchanged hits take 0.117/0.109/0.122 ms. Driver
and filesystem caches may already be warm. The pixel, fixed-input/sampler,
no-op/revert and released-target checks pass in all three processes. No archived
binary is relabeled as a build of final main.

All seven app runs retain exact toon, geometry and depth-normal control PNGs.
Duplicate same-provider opaque draws still vary: old runs 16/21/17 pixels
(maximum channel delta 8/22/8), new 40/18/15 (8/7/6), and captured provider 22
(maximum 27), in the existing shoe-region bounds. Both images are translated
draws of the same frame/provider; they are not an un-translated control. This
retains the separate #188 limitation, without changing source gates or claiming
full-frame repeat equality or source-color parity.

The private compiler-reference-argument failure, rejected outside-checkout
conversion output, source-only copy/schema preflight corrections and their
successful follow-ups remain recorded. The successful original producer and
native recipe did not change during those corrections. Private evidence is
under `.local/codex-continue-2026-10-24/rolling/materials-body/`; source keys are
`IKKOKU_BODY_COMPOSITE_BASE_PROBE` and `IKKOKU_BODY_COMPOSITE_PROBE`. This bounded
20/20 fixture result does not imply support for other body identities, low detail,
paint/sunburn or recovered Studio scene globals, and does not resolve the
separate draw-fidelity limitations.

### Translated sampling repeatability investigation (#188)

[Issue #188](https://github.com/grabbiel/ikkoku/issues/188) tracks the separate
held-frame draw variation above. Production sampling, source tolerances and
composite coverage are unchanged. The following are private numerical
diagnostics on the same Apple M2 Ultra / macOS 27.0.1 host, with fast math
disabled; none is a performance measurement or a proposed quality-reducing
workaround. The earlier MSL 4.1 value came from a separate options-query process,
not these private test pipelines. The standalone synthetic tool records 4.1;
the later source-prefix test records 4.0 inside its actual pipeline creation.
Cross-context compiler-version equivalence is not established.

The first controls use the same retained private Release test binary
`eabc8275…`, immutable shader proxies, native shoe geometry and held frame.
Replacing the affected fragment samplers with equivalent constexpr samplers
at effective anisotropy 9 still produces variation. A paired version changes
only anisotropy to 1 and also varies. Across three repeats, store-provider
changed-pixel counts are 89/95/111 (maximum byte differences 18/18/27) at 9 and
81/95/77 (80/80/80) at 1. Captured-provider results are 26/29/29 (8/27/8) and
19/25/17 (80/80/12), respectively. All ten target mip levels remain stable.
Anisotropy above one is therefore not required for this observed gap; the
constexpr representation does not remove it.

A second control encodes primitive/pass IDs into final RGB while preserving
the original alpha, discard, geometry, draw order, depth and blend state. Its
7,704 possible IDs remain unique through sRGB8 quantization. Every observed ID
decodes exactly: 2,604 forward pixels cover 988 primitives, and 344 outline
pixels cover 272 primitives. All eight images (four per texture provider),
including alpha and coverage, are byte-identical. This rules out changing
visible primitive selection in that control; unused shading may be optimized
away, so it does not establish interpolation or derivative stability.

A third, temporary test-only MRT capture retains the original color output and
adds three float32 attachments. At the exact first `_MainTex` instruction it
records UV, `dfdx`, `dfdy`, sampled RGBA and primitive/pass ID in the same draw.
The source rewrite preserves every original sample statement, discard and the
original `o0` color expression; extra attachments have blending disabled while
color0 retains the original state. Its private Release binary is
`ca8da5ad171964efebb352855ef9f55d4748689542912be2bce6ae1e36ff41de`, built from
`899e99a` plus the retained temporary test patch. The tracked test file was
restored byte for byte after compilation; no runtime source was changed.

| MRT result, three repeats against the first draw | Native store | Captured textures |
| --- | ---: | ---: |
| Changed color pixels | 90 / 87 / 86 | 11 / 5 / 3 |
| Maximum color byte difference | 14 / 14 / 14 | 22 / 2 / 22 |
| Changed UV or primitive/pass pixels | 0 / 0 / 0 | 0 / 0 / 0 |
| Changed `dfdx` pixels | 87 / 85 / 84 | 9 / 4 / 3 |
| Changed `dfdy` pixels | 124 / 120 / 115 | 16 / 12 / 5 |
| Changed first MainTex sample pixels | 100 / 97 / 96 | 14 / 7 / 2 |

The sampled-value changes overlap 79/76/75 and 10/5/2 color-changing pixels,
respectively. Every observed value is finite, alpha is unchanged, and all
2,948 primitive/pass IDs match the earlier ID control. The largest recorded
absolute derivative difference is 0.111033 in normalized UV units. Thus this
instrumented draw has stable visible UVs and primitive selection but varying
derivatives and sampled values. The added outputs can perturb compilation and
execution; this does not identify a driver/compiler fault or explain every
downstream color change. Later nonlinear ramp/normal-map sampling remains
outside this first-sample observation.

The retained forward and outline fragments compute this MainTex coordinate
from the interpolated UV and its affine material transform, after the first
alpha-mask sample and **before** the discard instruction. No source branch
precedes it. The current [Metal language specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
(2026-06-04, §§6.10–6.13, pages 227–239) describes helper execution for
derivatives, requires uniform control flow, and states that Metal 2.3+ discard
does not change derivative validity. That rules out applying the obsolete
pre-2.3 discard restriction to the later in-harness MSL 4.0 reproduction below.
Quad reads also require an active source lane, so an unchecked quad-shuffle
replacement would not be a sound fix.

The [Unity 5.6 shader semantics](https://docs.unity3d.com/560/Documentation/Manual/SL-ShaderSemantics.html)
describe triangle-interpolated fragment inputs. Direct3D's
[derivative definition](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/deriv-rtx--sm4---asm-)
is hardware-dependent and describes off-primitive helper pixels in its
reference rasterizer. Its [implicit sample instruction](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/sample--sm4---asm-)
may share LOD across a 2×2 stamp or compute it per pixel, whereas
[explicit-gradient sampling](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/sample-d--sm4---asm-)
computes LOD per pixel. Replacing all source samples with explicit gradients
would therefore require fresh source-output evidence, even if it stabilized
one native capture. The [source discard instruction](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/discard--sm4---asm-)
also preserves execution for derivative calculation.

An asset-free control is now available as
[`metal_derivative_repro.swift`](../../Tools/verification/metal_derivative_repro.swift)
with [build/run instructions](../../Tools/verification/README.md#standalone-metal-derivative-diagnostic).
It uses eight deterministic CPU-authored sRGB8 mips, default language options
with fast math disabled, and same-draw color/UV/derivative/sample/ID readback.
The actual default is recorded per process; the standalone 4.1 result does not
establish equivalence to the source-prefix test's 4.0 context. Three cases cover
the same 64×64-pixel region of a 128×128 target:
a two-triangle continuous quad, a regular grid of 2,048 small triangles with
continuous UVs, and identical grid geometry with discontinuous per-triangle
UVs. Constant clip `w = 1` makes each triangle's affine gradient independently
calculable. The simple fragment has one implicit sample and no branch/discard;
the instrumented MRT shader is not the recovered fragment body.

On 2026-10-24, an optimized standalone Swift build and CPU-only layout, literal
mip-texel and floating-point classification checks pass; six CLI boundary checks
also pass. The one bounded GPU process collects four draws per case on the same
M2 Ultra / macOS 27.0.1 host. Effective language version is MSL 4.1, fast math
is disabled and `preserveInvariance` is false. **All three cases are stable:**
color, UV, both derivatives, sampled RGBA and primitive IDs have zero changed
bits between repeats. Each draw covers 4,096 pixels, every visible value is
finite, and the maximum error against its analytic affine gradient is zero.
All eight input mip levels remain byte-identical after drawing. The large and
small continuous cases also render the same checker pattern; the discontinuous
case renders a visibly distinct minified pattern.

This is a negative reproducer result, not proof that the recovered path is
stable. It excludes neither irregular/subpixel geometry, perspective
interpolation, the larger shader body nor compiler perturbation by MRT outputs.
Any eventual translation change must retain source sampling semantics and pass
independent source-color and Release cost gates. Fixed LOD zero, reduced
anisotropy and blanket explicit-gradient rewrites are not production changes.
Issue #188 remains open, and no timing/FPS claim follows from this diagnostic.

The standalone source SHA-256 is `bf69c7a98d7dea3d70e17244abc5d6efc81e90eb2c61b59579d7bf3147bac573`;
the tested executable is `8aaf5ab963600ba4c95cb260349ed232077032cb1bfd25a39701daeec8f58255`.
Build/command provenance, both reviewed coding-helper proposals and the result
are retained under `.local/codex-continue-2026-10-24/rolling/materials-sampling-reproducer/`.
Its `run-1/report.json` hashes all 60 shader/vertex/mip/raw-output artifacts;
those hashes were checked after the process exited. These synthetic results
are separate from the private original-shader MRT evidence above.

A subsequent bounded control adds two copies of the discontinuous grid while
retaining the original three cases. One shifts screen coordinates by
`(5/16, 3/16)` pixels; the other adds the same shift and the shear
`x += (originalY - 64) * 3/16`. Both preserve UVs, primitive order, depth and
clip `w = 1`. The shader, mip generator and original mesh-generation blocks
remain byte-identical. CPU checks independently pin the first three transformed
positions and the first-triangle gradients; shear changes `dUV/dy` by
`-3*dUV/dx/16`, so its expected gradient is not copied from the aligned case.

The coverage reference computes the union of triangle interiors at pixel
centers using clipped per-triangle bounds. It has literal duplicate/shared-edge,
viewport-clipping, empty and degenerate checks. Each GPU validity and alpha
pixel must match that plane, rather than assuming the shear leaves coverage
unchanged. Inclusive shared-edge membership is sufficient for these opaque
fixtures, whose outer boundaries avoid pixel centers; it is not a general
Metal rasterizer or a primitive-ownership oracle.

The optimized build and CPU checks pass at clean `b2bc839`. One locked process
collects five cases × four draws with the same MSL 4.1 options/device. **The two
added cases also do not reproduce the variation:** every repeat is bit-stable
for color, UV, derivatives, sampled values and primitive IDs; all visible
values are finite and affine-gradient error is zero. Computed and GPU coverage
agree at every pixel and yield 4,096 pixels per case. All 99 saved artifact
hashes verify; all 60 artifacts from the earlier three-case run, including its
48 color/float outputs, are byte-identical. The authored input mip chain is
unchanged after drawing.

This control covers only the stated subpixel offset and shear of a regular
affine grid. It does not test perspective interpolation, arbitrary irregular
geometry or the recovered shader body, and it does not establish the cause of
the private MRT variation. No production change, relaxed source gate or
performance claim follows. Evidence and both reviewed coding-helper proposals
are under `.local/codex-continue-2026-10-24/rolling/materials-sampling-subpixel/`.
Source SHA-256 is `ddc6dd37ec1ffd2f9518314674612aaa27643187507b1ec7e62ee0e35e037ecd`;
the executable is `66d8dbd646ea548ba1d3aa68cbc07537ee2399eba18b4a1eb5b2477f545545a2`;
the report is `bfd362c16de2a01cbe5324b1b1678b8d1b3f1d16af1d1f85f773f4e8df56f232`.

The next control retains those five cases and adds two clip-w variants of the
sheared grid. Both scale the entire clip position by factors 0.5/1/2, preserving
projected geometry, NDC depth, UVs and primitive order exactly. One uses a common
factor per triangle; the other varies it between the three vertices. The
shader, mip chain, sampler and compiler options remain unchanged.

An independent Double reference projects each triangle, computes screen
barycentrics and evaluates `sum(lambda * UV / w) / sum(lambda / w)`, with
coefficients cached once per triangle. This is the mathematical
[perspective-interpolation formula](https://registry.khronos.org/OpenGL/specs/gl/glspec33.core.pdf)
(equation 3.9), not a hardware-precision or derivative guarantee. Literal
interior, edge and endpoint checks distinguish reciprocal-w interpolation
from affine interpolation; the interior control gives `(2/11, 1/11)`.
GPU UV error is measured at pixel centers using the reported primitive ID.
The affine-gradient comparison is JSON null where vertex w varies, while raw
derivative repeat comparisons remain available.

At clean `0b92331`, the optimized standalone build and CPU checks pass. One
locked process collects seven cases × four draws on the same M2 Ultra/MSL 4.1
configuration. **All seven cases remain bit-stable** in color, UV, derivatives,
sampled values and primitive IDs. Every visible value is finite; GPU coverage
and alpha match the computed 4,096-pixel plane for each case. Constant-w cases
have zero rational UV and affine-gradient error. The varying-w case has maximum
absolute rational UV error `1.4997892061607843e-7` in every draw; this is a
numerical observation without a new tolerance and is not derivative parity.
All 135 artifact hashes verify, and all 99 artifacts from the five-case control
remain byte-identical. The input mips remain unchanged after drawing.

These affine and perspective grid controls still do not reproduce the recovered
shader's variation. The following control reduces the source shader while
retaining its varying baseline; no further geometry variant is added. No
production shader or source gate changes here. Evidence, exact
commands and both reviewed helper proposals are under
`.local/codex-continue-2026-10-24/rolling/materials-sampling-perspective/`.
Source SHA-256 is `f2ef808f32d24d019a6130d11a5cbf73b159250ee1a401a32bdad1efd1809122`;
the executable is `750f115553d92e77c404547e86482bfe36bf755f7f4e9c848534394990c35005`;
the report is `193fa0d1f3578380f9c7ebd9690607b24620de601888566dea0a17073696ffaf`.

A subsequent **private prefix reduction** retains the original shoe geometry,
vertex paths, fragment declarations and exact instructions through the only
discard. Both retained assembly programs have the same eleven-operation prefix:
alpha-mask coordinates/sample, mask combination, MainTex coordinates/sample,
then alpha comparison/discard. No branch precedes MainTex, and no later discard
is removed. The reduction removes only subsequent shading. Its color0 is
intentionally diagnostic MainTex RGB with the original constant pass alpha
(forward 1, outline 0); the three float MRT attachments, original sample calls,
depth/stencil/blend state and input bindings remain unchanged. Full color parity
between these two variants is neither expected nor tested.

The Release test bundle is built at `1ce8aef` plus a private temporary test
snippet, then the tracked test file is restored byte for byte. One locked process
collects four draws × full/reduced × native-store/captured providers. The fresh
full baseline varies with both providers, and **the prefix reduction also
varies**:

| Changed pixels in three repeats | Native full | Native prefix | Captured full | Captured prefix |
| --- | ---: | ---: | ---: | ---: |
| Color0 | 89 / 89 / 89 | 14 / 18 / 11 | 26 / 26 / 11 | 29 / 29 / 19 |
| `dfdx` | 86 / 86 / 86 | 16 / 16 / 11 | 20 / 23 / 9 | 29 / 29 / 18 |
| `dfdy` | 125 / 120 / 120 | 19 / 30 / 15 | 39 / 31 / 16 | 51 / 51 / 34 |
| First MainTex sample | 97 / 98 / 98 | 16 / 22 / 12 | 33 / 35 / 14 | 42 / 42 / 27 |

For each provider, every repeat and full/prefix comparison has identical visible
UVs, primitive/pass IDs, 2,948-pixel coverage and alpha; all observed visible
values are finite.
All 64 raw attachment hashes verify, reconstructing each full float target from
its zero-cleared exterior and exact saved ROI. All 148 bound mip-level instances
are unchanged before/after the four provider/variant groups, and all 20
provider/property mip chains match across full/prefix variants. Ten packed
constant-buffer hashes also match. Six transformer boundary checks and seven
independent literal readback checks pass, including hash-scope/row placement,
nonfinite rejection and signed-zero bit differences.

All four pipelines report MSL **4.0** (`262144`), fast math disabled and
`preserveInvariance = false` from inside the actual test process. The prior
standalone tool and separate options query report 4.1; identical default-option
construction is not proof of identical effective compiler context. Earlier
cross-context statements are qualified accordingly. This result shows that
later lighting/material shading is not required for the observed instrumented
draw variation. It does not identify a compiler/driver defect or a source-semantic
violation: removing code and adding MRT outputs can change compiled execution.
The next discriminator below retains actual geometry and the MainTex
coordinate/sample operations while removing AlphaMask/discard, comparing common
visible primitive/pass pixels if coverage changes. It is not a production fix.

Evidence and both reviewed helper proposals are under
`.local/codex-continue-2026-10-24/rolling/materials-sampling-reduction/`.
The private executable SHA-256 is `453b54565cd3850644167b756119359e9732ebcc5d0280e7174c9da12a678572`;
the report is `18530343b64474576d1927a08e2dd253ee9e8bce678205be04a55198a7b45c8b`.
All recorded source/proxy/fixture hashes remain unchanged. No production shader,
source tolerance, composite coverage or performance claim changes; #188 stays open.

A **private MainTex-only discriminator** removes the AlphaMask coordinate/sample
and mask-combination block, then the alpha predicate/discard block, from that
prefix. MainTex's UV assignment overwrites its coordinate components from the
interpolated UV and material transform; it does not depend on the removed mask
value. The exact assignment, implicit sample, vertex paths, declarations, MRT
outputs, input bindings and pass state remain unchanged. Both cases intentionally
output diagnostic MainTex RGB with the original constant pass alpha. This is a
two-block removal, not a production shader or a source-color equivalence test.

At `18a61bc`, a private temporary Release test builds successfully, after which
the tracked test file is restored byte for byte. The first launch stops before
drawing because the strict card loader rejects a private proxy symlink. That
failed attempt is retained; only the two private card paths become regular
copies with identical bytes and hashes. The same frozen binary then collects
four draws × prefix/MainTex-only × native-store/captured providers in one locked
process. No loader validation is relaxed and no source input changes.

The fresh prefix remains variable with both providers, while **MainTex-only is
bit-stable in all three repeats**:

| Changed pixels against the first draw | Native prefix | Native MainTex-only | Captured prefix | Captured MainTex-only |
| --- | ---: | ---: | ---: | ---: |
| Color0 | 73 / 74 / 71 | 0 / 0 / 0 | 5 / 21 / 12 | 0 / 0 / 0 |
| `dfdx` | 103 / 101 / 100 | 0 / 0 / 0 | 3 / 18 / 13 | 0 / 0 / 0 |
| `dfdy` | 118 / 109 / 101 | 0 / 0 / 0 | 7 / 38 / 33 | 0 / 0 / 0 |
| First MainTex sample | 93 / 94 / 90 | 0 / 0 / 0 | 7 / 30 / 20 | 0 / 0 / 0 |

For each provider, all eight draws have identical 2,948-pixel coverage,
primitive/pass identity and alpha. Within-case and cross-case UVs are bit-identical
for that provider. Its fixed common mask therefore retains all 2,948 visible
pixels; the repeat counts above also hold on that mask. Whole-plane coverage,
identity and alpha comparisons are reported separately, rather than assuming
that removing discard preserves them. All visible values are finite.

The audit verifies 64 complete attachment hashes. Float targets are retained as
losslessly compressed full planes, avoiding a fixed-region assumption when
discard is removed. All 148 bound mip-level instances are unchanged before and
after drawing; twenty provider/property chains and ten packed constant-buffer
hashes match across cases. All four actual pipelines report MSL 4.0, fast math
disabled and `preserveInvariance = false` on the same M2 Ultra/macOS host. Seven
literal transformer checks and fourteen independent readback/common-mask checks
pass, including signed-zero bits, empty common coverage, invalid IDs and corrupt
compressed input.

This localizes the difference to the combined mask/predicate/discard removal or
its effect on compilation. It does not identify which removed operation matters,
prove a compiler/driver defect, or establish a general derivative rule. Removing
alpha testing would change source behavior even though this fixture's visible
coverage is unchanged. A subsequent split control must keep mask/predicate work
observable if it removes discard, so dead-code elimination does not silently
turn it into another MainTex-only case. No production workaround, relaxed source
gate, added material coverage or timing claim follows; #188 remains open.

Evidence, the retained failed attempt and both reviewed coding-helper proposals
are under `.local/codex-continue-2026-10-24/rolling/materials-sampling-maintex/`.
The successful outputs are in `run-2`; the frozen harness's `run-1` path points
there. Private executable SHA-256 is
`2c92001a8ca1439208d1394737849f50f65006317ca3976dd510015438cd1f10`;
report SHA-256 is
`58e019865fc79c6d2ce1eb1907797f94f09623158f0b96a399fbc3ff939caabf`.

A **private discard-only split** retains the mask sampling, combination and
original comparison operations. Both variants add an `rg32Float` attachment
that records the combined mask immediately before MainTex's independent UV
assignment and converts the original comparison bits to numeric 0/1. It does
not recompute the floating-point threshold. The attachment keeps this input
chain observable when the discard is removed. The two instrumented programs
differ by exactly one original discard statement; all other source bytes,
including vertex paths, are identical. Program metadata changes only its source
hash. Color0, the existing float attachments and pass state are preserved.

The private Release bundle builds at `0bcd33c` plus a temporary test snippet;
tracked test source is restored exactly afterward. One locked process passes
four draws × observed-prefix/no-discard × native-store/captured providers.
Actual pipeline creation accepts all five attachments, whose logical color
payload is 60 bytes per pixel. The actual options remain MSL 4.0, fast math
disabled and `preserveInvariance = false` on the same M2 Ultra/macOS host.

**The fresh observed-prefix controls vary, while no-discard is bit-stable:**

| Changed pixels against the first draw | Native observed prefix | Native no-discard | Captured observed prefix | Captured no-discard |
| --- | ---: | ---: | ---: | ---: |
| Color0 | 74 / 67 / 65 | 0 / 0 / 0 | 18 / 10 / 15 | 0 / 0 / 0 |
| `dfdx` | 105 / 94 / 96 | 0 / 0 / 0 | 11 / 11 / 15 | 0 / 0 / 0 |
| `dfdy` | 116 / 106 / 116 | 0 / 0 / 0 | 27 / 15 / 23 | 0 / 0 / 0 |
| First MainTex sample | 93 / 84 / 83 | 0 / 0 / 0 | 23 / 17 / 22 | 0 / 0 / 0 |

For each provider, all eight draws retain the same 2,948-pixel coverage,
primitive/pass IDs, alpha and visible UVs. Its fixed common-ID mask includes all
visible pixels, so the repeat counts hold on that mask too. Every visible mask value
is exactly 1 and every observed predicate is 0, with no bit changes within or
between variants. These visible-pixel observations do **not** observe helper
invocations or prove that no invocation executes discard. All visible values
are finite. Eighty full-plane attachment hashes verify; all 148 bound mip-level
instances are unchanged, twenty texture chains match across variants, and ten
packed constant-buffer hashes match.

Twenty-one synthetic RG readback tests, eight transformer checks and eighteen
combined audit checks pass. They cover bounded decompression, exact packing,
visible predicate domain, signed-zero bits, fixed-coordinate comparisons and
empty common coverage. One initial static readiness assertion mistakenly counted
the outline's retained vertex sample as a fragment sample; that failed assertion
and its correction are retained, with no shader/proxy change. The GPU run has no
failed or skipped draws.

This associates the observed difference with the presence of the discard
statement in these compiled, instrumented programs. It does not establish a
source-semantic violation, compiler/driver defect or general derivative rule.
Removing discard remains unacceptable as a production fix without preserving
source alpha testing. No production shader, source gate, material coverage or
timing claim changes; #188 remains open.

Evidence and reviewed helper proposals are under
`.local/codex-continue-2026-10-24/rolling/materials-discard-observability/`.
Private executable SHA-256 is
`af9c5a3c9efdf0e1b8e5babdd5416917d84bf3e399dfe822920632a99f4e191c`;
report SHA-256 is
`6becf5cec5e4a1a99d0d096b9cf93fcaa70c7528f9a1fa94e00877131b7df3c6`.

A **private explicit-language comparison** compiles the exact observed-prefix
source and metadata above under MSL 4.0 and 4.1. Both cases use one fixture URL
and separate immutable-version pipeline caches; neither shader is rewritten.
Production `TranslatedSourcePipelineCache` sets `fastMathEnabled = false` but
leaves language selection at its default. Its actual application-process
language version remains unmeasured. The installed SDK exposes MSL 4.0 from
macOS 26 and 4.1 from macOS 27; neither can become an unconditional requirement
under the current app/Engine deployment targets of 14.6/14.

The private Release bundle builds at `4eb198c` with temporary test instrumentation
and exact source restoration. One locked process completes sixteen draws: four
repeats × two versions × two providers. Each cache compiles both passes once.
The recorded options passed to `makeLibrary` are 262144/262145 respectively,
fast math disabled and `preserveInvariance = false`. The newer option getters
are also equal in all four records: `mathMode = 0` and
`mathFloatingPointFunctions = 1`. These are compiler-input records, not
independent reflection of emitted machine code. The host is M2 Ultra/macOS
27.0.1; the private availability guard changes no deployment setting.

**The fresh MSL 4.0 controls vary, and MSL 4.1 also varies for both providers:**

| Changed pixels against the first draw | Native MSL 4.0 | Native MSL 4.1 | Captured MSL 4.0 | Captured MSL 4.1 |
| --- | ---: | ---: | ---: | ---: |
| Color0 | 69 / 66 / 64 | 15 / 21 / 16 | 16 / 20 / 17 | 6 / 6 / 2 |
| `dfdx` | 96 / 99 / 94 | 16 / 20 / 17 | 18 / 23 / 17 | 9 / 8 / 3 |
| `dfdy` | 113 / 108 / 97 | 26 / 39 / 24 | 34 / 39 / 33 | 14 / 12 / 11 |
| First MainTex sample | 87 / 84 / 80 | 19 / 28 / 21 | 28 / 33 / 28 | 13 / 14 / 6 |

Native Color0 repeat maxima are 37 bytes under 4.0 and 20 under 4.1; both captured
cases reach 20. All sixteen draws retain the same 2,948-pixel coverage,
primitive/pass IDs and alpha. Visible UVs are stable within each provider,
including across versions, and all visible pixels lie on its fixed eight-draw
common-ID mask. A separate provider-to-provider comparison has a fixed 17-pixel
UV difference (maximum 1.7881393432617188e-7); this is not a within-case repeat
change. Every visible mask remains 1 and predicate 0, with no within/between
version changes. Those observations still exclude helper invocations.

Eighty full-plane attachment hashes verify, all 148 bound mip-level instances
remain unchanged, twenty texture chains match across versions, and ten packed
constant-buffer hashes match. Thirty-nine combined literal audit checks and
21 RG readback tests pass, including independent per-version classification,
empty common coverage, modern-option differences and malformed counts. Inputs
remain unchanged; the GPU collection has no failed or skipped draws.

Selecting MSL 4.1 does not eliminate this diagnostic's repeat gap. The four
repeats do not establish a reliable reduction in its magnitude. This does not
identify a compiler/driver defect or explain why the simpler standalone program
was stable. No production language selection, shader, source gate, material
coverage, parity or timing claim changes; #188 remains open.

Evidence, retained Release bundle and corrected helper proposals are under
`.local/codex-continue-2026-10-24/rolling/materials-language-version/`.
Private executable SHA-256 is
`7599b9831234cda27160a0deb9a251935ec9ce96d887584a147b067108233f4b`;
report SHA-256 is
`e66f35112cc6503a520631be8780362f432200db0d59d33f34e1ba0731b583d5`.

A **private explicit-gradient discriminator** adds only
`gradient2d(diagnosticDX, diagnosticDY)` to the existing first MainTex sample
in each observed-prefix pass. The UV expression, already-present derivative
declarations, instruction order, original mask/comparison/discard, vertex path
and five MRT outputs are unchanged. The derivatives and MainTex sample already
precede the discard. Removing the one added argument restores each pinned source
byte for byte; program metadata changes only its source digest. Supplying these
explicit derivatives is a diagnostic, not an assumed equivalent implementation
of implicit sampling.

The private Release bundle builds at `6071394` with temporary test instrumentation
and exact source restoration. One locked process completes sixteen draws: four
repeats × implicit/explicit gradients × native-store/captured providers. Both
cases explicitly select MSL 4.0 (262144), fast math disabled and
`preserveInvariance = false`. All four compile-input records have `mathMode = 0`
and `mathFloatingPointFunctions = 1`; the host remains M2 Ultra/macOS 27.0.1.

**Fresh implicit controls vary, and explicit-gradient sampling also varies:**

| Changed pixels against the first draw | Native implicit | Native explicit | Captured implicit | Captured explicit |
| --- | ---: | ---: | ---: | ---: |
| Color0 | 61 / 64 / 67 | 7 / 8 / 15 | 25 / 13 / 20 | 28 / 13 / 13 |
| `dfdx` | 90 / 92 / 98 | 6 / 5 / 17 | 28 / 9 / 15 | 31 / 17 / 17 |
| `dfdy` | 104 / 104 / 104 | 10 / 10 / 33 | 44 / 26 / 35 | 53 / 24 / 24 |
| First MainTex sample | 77 / 81 / 84 | 9 / 10 / 22 | 36 / 17 / 25 | 43 / 23 / 23 |

Color0 repeat maxima are respectively 37, 16, 20 and 17 bytes. Per provider,
all eight draws retain the same 2,948-pixel coverage, primitive/pass IDs, alpha,
UVs, mask 1 and predicate 0; all visible pixels lie on its common-ID mask.
The fixed cross-provider UV difference remains 17 pixels, maximum
1.7881393432617188e-7. Visible observations do not describe helper invocations.

The paired implicit/explicit draws also differ substantially: sampled RGBA
changes at 794–800 native-store and 959–964 captured-provider pixels; Color0
changes at 601–605 and 610–616 pixels respectively, maximum 45 bytes in either
provider. These are cross-variant differences, separate from repeat variation.
An independent raw-readback comparison finds that every explicit-case sample
change coincides with a recorded `dfdx` or `dfdy` change. Implicit repeats have
7 / 8 / 7 native-store and 3 / 1 / 1 captured sample changes with identical
recorded UVs and derivatives; those diagnostic derivatives need not expose the
implicit sampler's internal gradient calculation. This correlation does not
establish causation or general equivalence.

Eighty full-plane attachment hashes verify; all 148 bound mip-level instances
remain unchanged, twenty paired texture chains and ten packed constant-buffer
hashes match. Ten transformer tests and 39 combined literal audit checks pass.
The RG readback module and its tests are unchanged from the prior 21-test
validation. The independent decoder's first attempt used a wrapped zlib header
instead of the recorded raw-deflate format and failed before comparison; the
corrected decoder verifies all eighty hashes. The failed script is retained,
with no capture or input mutation. The GPU collection has no failed or skipped
draws and no retry.

This explicit-gradient change neither eliminates the observed repeat gap nor
preserves the implicit case's pixels. Four repeats cannot establish a reliable
reduction in variability, and compiler perturbation remains a limit. No
production shader, source gate, material coverage, parity or timing claim
changes; #188 remains open.

Evidence, retained bundle and reviewed helper proposals are under
`.local/codex-continue-2026-10-24/rolling/materials-explicit-gradients/`.
Private executable SHA-256 is
`70cad4e29fb4df113e368b814059c088346c7aa7f43eee5465a30d42540dc29c`;
report SHA-256 is
`ff6fecc3dcc8cd49580660b452e52857fa97e4441f5d37bd041bc9610be46f61`.

Commands, hashes, helper reviews, immutable proxies and raw readbacks are under
`.local/codex-continue-2026-10-24/rolling/materials-sampling/`. The derivative
correlation is not itself proof of a boundary defect: 2,596 of 2,604 visible
forward pixels already lie on primitive boundaries in this small on-screen
shoe. The investigation remains open, with no new FPS or source-parity claim.

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
target. Every meaningful active morph is accumulated (there is no 64-entry cap).
The light budget is eight, and enabled lights beyond it are counted in
`Renderer.lastFrameStatistics.droppedLights`. Uniforms beyond the ring's 8 MiB
region go to overflow buffers; a refused buffer becomes `lastFrameError`
([R6](#renderer-limits-and-resource-lifetime-r6-first-slice)), which the Maker and
Studio status lines show. Removed characters and replaced static imports release
their GPU buffers once no pending frame names them
([second slice](#character-and-import-lifetime-r6-second-slice)). glTF UV1/2
are decoded, but native materials sample imported glTF textures on UV0 and
`LoadedAsset` rejects other selections. Initial morph weights are retained but not
applied, and tangent morphs are ignored; the loader reports both. There is no
complete LOD, streaming or frustum-culling system. R3/R5/R6 define fixes and checks.

A recorded Release fixture on M2 Ultra at 600×800 rendered 28 items, 60,761 triangles
and 40,490 vertices. CPU pose samples (60) measured p50/p95 4.684/4.964 ms; static
GPU samples (20) measured 0.529/0.537 ms. Encode time was 0.222/0.240 ms and
completion 1.058/1.224 ms. These are separate measurements, not summed frame time.
The fixture had zero attached source DynamicBone components and an unrendered
route. RSS 379,125,760 bytes and Metal allocations 415,907,840 bytes can overlap in
unified memory; do not sum them or infer full-game throughput. See R7 for a
representative displayed-scene benchmark and the full evidence inventory.


## Native stock cheek ID1 composite (R1/CMT-04, #243, 2026-10-25)

The ordinary female/head0/exType0/high-detail face compositor now accepts exact
stock cheek category 402/ID1 (`chara/mt_cheek_00.unity3d`, `cw_t_cheek_000`).
The existing creator program and `_tex4uv`, alpha, null-layer and active-makeup
selection rules remain unchanged. Base or coordinate makeup supplies the active
color; editing the inactive record preserves the recipe and texture. ID0 remains
available. Other nonzero cheek IDs, lipline/face-paint/mole layers, other heads
and resolver-backed replacements remain outside this gate. Generic head-contract
metadata behavior is unchanged; the new metadata validation applies only to this
exact cheek input and rejects conflicting supplied values.

Two independent original players provide base and distinct active-color targets.
The source cards retain exact requested color bits, bound values remain exact
before/after an inactive-record rebuild, and unrelated inputs/vectors remain
unchanged. Card-to-bound colors use the existing 1e-6 cross-API observation
threshold. The base/distinct targets differ at 74,916 pixels / 212,124 channels;
initial, inactive-rebuilt and post-cleanup targets are identical within each case.
The stronger cross-API bit-equality assertion and its failed audit are retained.

Conversion adds one 832×312 RGBA32 sRGB input with one authored mip and
Bilinear/Clamp/aniso1. Its bundle SHA-256 is
`d21eeb93b6737b897f916a46fb12fa9c56642986d9c886ab2b5b1123d7e9e6b7`;
the retained 63-asset/five-program store manifest is
`def1dfb18a7bcc5ed8036c358918e160fe42b97e969458b6bfabb08a4fe0a5e0`.
All 62 prior asset records, five programs and 396 prior level/program files
remain byte-identical. Decoded RGB matches the independent bound-input readback;
49,136 alpha components differ by at most 0.00048828125. No decoder or tolerance
changed to absorb that observation. Level-zero target comparisons are independent
source oracles; higher generated mips are not independently verified.

At source `e62c67c`, Release test binary `145b9287…` passes the strict cheek gate:
base/distinct target errors are at most one output byte (2,080 / 2,816 affected
channels), with alpha 255 throughout. No-op and inactive edits reuse the same
key/texture without more uploads or auxiliary allocations. Fifteen recolors
release transient targets; retained inputs stay at four uploaded assets, one
black default and three effective samplers. Reverting returns the original
retained target, and each target allocation is 5,652,480 bytes. The first test
attempt incorrectly expected two samplers under ForceEnable; the retained
failure was corrected only in the test expectation. Asset Clamp/linear-mip/aniso9,
paint Repeat/linear-mip/aniso9 and default Repeat/nearest-mip/aniso1 are distinct.
Nine prior strict GPU gates also pass on the accepted 62-asset store, without
skips. Earlier focused checks pass 14 CPU Engine cases and 27 Python tests.

Final integration `9aad4393` preserves all eleven cheek feature files from the
native-test producer. Its fresh inspected Release app, SHA-256
`b027d0b740b714cbf06f218b0411364f0a0db2efd2cbbc8db46b4cea579d7d3e`, passes six
default-OFF source/native/Maker captures, each byte-identical to its historical
accepted baseline. The old test binary retains its own producer identity;
accepted-main preview/plugin changes are covered by the fresh app.

Seven further functional processes use the same final app, fresh cheek card,
frame and time, in old/new/new/old/old/new/capture order:

| Provider | Live slots / fallbacks | Unique composite keys / events | Registered textures |
| --- | ---: | ---: | ---: |
| Old 62-asset store, three runs | 19 / 1 | 6 / 8 | 95 |
| New 63-asset store, three runs | 20 / 0 | 7 / 9 | 100 |
| Captured-pixel control | 20 / 0 | 0 / 0 | 72 |

The old fallback names the missing cheek input. New runs add one face-creator
miss with key `2df3fa4f28706ade77783d1914698ace4823faec97c65486ebff37159f271711`
and 5,652,480 target bytes; the six unrelated keys/eight events agree across
providers. Each provider repeats its attachment and resource records exactly:
41 meshes, 20 deform buffers and zero retiring resources. These registration
counts differ from the isolated input budget above. Toon, depth-normal and
geometry PNGs are byte-identical across all seven processes. All owned app,
compiler and original-player processes are released.

Comparative costs are deferred: these were functional runs with concurrent work
permitted. Printed timing samples do not establish a speedup or quiet-cost
result. The live native rig uses captured globals; passing composite targets
and control images does not establish whole-frame source shading, generated-mip
parity or resolution of translated-draw repeatability issue #188.

Private evidence is retained under
`.local/codex-continue-2026-10-24/rolling/materials-cheek/`: original audit v3 and
superseded failures, conversion/input reviews, `native-attempt-2/`, archived
producer sources, and `final-acceptance/`. The latter pins 5,822 inputs in
checkpoint `97a9e316…`; the seven-provider summary is `80ea9e36…`. Root reviews
record exact target, cache, resource, process and final-app controls separately.
