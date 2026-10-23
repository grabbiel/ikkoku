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
`releaseDeformBuffers(keys:)`. `CharacterInstance` still releases neither when
a character is removed.

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

Run them with
`swift test --package-path Packages/Engine --filter 'frameRing|lightPacking|activeMorphEntries|rendererCapture|resourceStoreAddRemove'`.
Swift was not compiled locally, so the CI Engine suite is the only test run.
Nothing here was run in the app.

Remaining R6 work:

- An interactive draw, pick and capture stress run that submits concurrently.
- Bounded counts across real character, scene and import/delete cycles.
  `CharacterInstance` does not release its deform or hidden buffers.
- Allocation-failure injection beyond the oversized overflow request.
- App-level reporting of `lastFrameError`.

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
state and captured textures. It compiles translated programs per job. Production
`Renderer` still selects authored native toon/eye/outline materials; there is no
live source-program registry integration.

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
aniso 1; the game sets none). Scene globals are not character data: the fixture
uses the harness constants that `OriginalCharacterProbe.Capture` sets —
`ChangeLineColor(1)`, `ChangeLineWidth(.307)`, `_ambientshadowG`
(0.5, 0.5, 0.5, 0.74) and `mt_ramp` row 1. Globals that no recovered method sets
read zero. Anything the native data cannot supply carries an `unresolved`
reason instead of a value.

**Supplement.** [source_binding_supplement.py](../../Tools/reverse/source_binding_supplement.py)
exports source metadata that the existing contracts omit, without pixels:
material keywords, `Texture2D` sampler/mip state, the `chara/mm_base.unity3d`
`cf_m_body` draw material and catalog rows. The fixture run covered 13 bundles
plus `mm_base` and categories 2 (`cha_eyeset`), 420, 423, 424, 432 and 433. It
exported 431 materials, 1,603 textures, 1 draw material and 80 catalog rows to
`.local/r1-live-bindings/supplement.json` (`ec8bcfc5…a05f6`).

```sh
cd Tools/reverse && ../../.local/reverse/unitypy-venv/bin/python source_binding_supplement.py \
  --source ../../.local/reverse/rigs/source/abdata --output ../../.local/r1-live-bindings/supplement.json \
  --bundle chara/bo_hair_b_00.unity3d --bundle chara/bo_hair_f_00.unity3d --bundle chara/co_top_00.unity3d \
  --bundle chara/co_bot_00.unity3d --bundle chara/co_shoes_00.unity3d --bundle chara/bo_head_00.unity3d \
  --bundle chara/mt_eyebrow_00.unity3d --bundle chara/mt_eyeline_up_00.unity3d --bundle chara/mt_eyeline_down_00.unity3d \
  --bundle chara/mt_nose_00.unity3d --bundle chara/mt_eye_hi_up_00.unity3d --bundle chara/mt_eye_hi_down_00.unity3d \
  --bundle chara/mt_mask_body_00.unity3d --draw-material chara/mm_base.unity3d:cf_m_body \
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
```

The gated Engine test `sourceShaderBindingsMatchTheControlledOriginalFrame`
(private-source lane: `IKKOKU_SHADER_BINDING_PROBE=<.local/r1c/probe>`,
`IKKOKU_MAKER_LIBRARY`, `IKKOKU_HEAD_MATERIAL_CONTRACT`,
`IKKOKU_SHADER_BINDING_SUPPLEMENT`) pins the numbers below. It checks the
`frame-mips.json` hash and adds two controls. In the capture-side mutation, one
hair `_Color` lane +0.01 gives exactly 1 `differs`. Without the supplement, the
derivation reports its gaps instead of guessing.

Inputs: `frame-mips.json` `13bd11c2…66f039`, card `4b892fc4…ce53c65`, library
`d898fea1…cbb609`, head contract `e77ca3f7…c39393` and supplement
`ec8bcfc5…a05f6`. Native bindings against the authored-mip capture:

| Family | Exact | Within tolerance | Differs | Missing natively | Extra | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| global | 7 | 0 | 0 | 3 | 0 | 10 |
| main_hair | 28 | 3 | 0 | 1 | 0 | 32 |
| main_hair_front | 84 | 9 | 0 | 3 | 0 | 96 |
| main_item | 73 | 2 | 0 | 0 | 0 | 75 |
| main_opaque | 147 | 3 | 0 | 0 | 0 | 150 |
| main_skin | 125 | 3 | 0 | 3 | 0 | 131 |
| toon_eye_lod0 | 34 | 4 | 0 | 6 | 0 | 44 |
| toon_eyew_lod0 | 54 | 5 | 0 | 0 | 1 | 60 |
| toon_glasses_lod0 / toon_textureanimation / toon_nose_lod0 | 3 / 3 / 9 | 0 | 0 | 0 | 0 | 3 / 3 / 9 |
| **Overall** | **567** | **29** | **0** | **16** | **1** | **613** |

By category, shader (20), queue (20), keywords (20) and pass state (31) are all
exact. Vectors are 191 exact, 18 within tolerance and 2 missing, with the largest
|Δ| 1.2e-7 from float32 colour rounding. Textures are 100 exact and 9
within-tolerance composites. Texture transforms are 100 exact, 2 within
tolerance and 6 missing; samplers are 58 exact and 8 missing. The generated-mip
`frame.json` (`9aa4de39…bcc750`) gives the same totals. Without the supplement
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

Remaining gaps by cause, none guessed:

- 8 sampler states: `mt_hairgloss_00`, `mt_nip_00`, `mt_body_detail_00` and
  `mt_ramp_00` (`_RampG`) are not in the local bundle set and need the VM to
  fetch. Their identity still matches by name.
- 6 `EyeLookMaterialControll` iris/highlight offsets: they depend on gaze, so
  they need the Studio eye-look runtime rather than the card alone. The capture
  shows x ±0.02.
- `_Time`: the frame clock is a playback input.
- `_RampG_ST`: an unset global transform, which the probe binds as
  `[1, 1, 0, 0]` by convention; Unity's value is unverified.
- 1 `extra`: `cf_O_eyeline` material slot 1. It is beyond the mesh's single
  submesh, so Unity draws it over the last submesh, but the probe's
  `materials.prefix(submeshes)` skips it. This is a probe gap, not a native one.

**Proof of concept (step 5).** `--write-frame <file>` writes a copy of the
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
and render diffs, and the scripts) is in `.local/r1-live-bindings/`.

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
([R6](#renderer-limits-and-resource-lifetime-r6-first-slice)). glTF UV1/2
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
