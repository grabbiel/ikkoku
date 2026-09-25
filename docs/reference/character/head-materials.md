# Head-00 material inputs and preview bakes

Reviewed 2026-09-25. This reference documents the original head-00 extraction,
offline preview bakes and bounded production mask/highlight implementations.
[Material expansion](material-expansion.md) describes the later runtime
composition and color-space correction. Remaining appearance work is in the
[component audit](../../component-audit/character-and-mods.md) (CM-29–32, CMT-04).
Commands run from the repository root; recorded test results below are historical.

`Tools/reverse/head_material_contract.py` resolves the installed head-00's ID0
texture selections from the MessagePack `ChaListData` tables in
`list/characustom/00.unity3d`. It exports 19 selected nonsexual head textures,
14 authored materials, the 18 renderer assignments, and three derived base-color
previews to ignored `.local/reverse/rigs/head-materials/`.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/head_material_contract.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_head_material_contract.py
```

The tool requires UnityPy, Pillow, NumPy, and msgpack in the extraction environment.
All inputs and output PNGs have SHA-256 provenance in `contract.json`. Only the
explicit source bundles are read; no runtime mods or startup character cards are
evaluated. Shader programs are checked against the inspected DXBC hashes before
the preview bakes run.

## Exact selected texture names

All entries below select catalog ID0. Paths are relative to `abdata/chara/`;
exported PNG filenames match the texture names.

| Role | Source bundle | Texture |
| --- | --- | --- |
| Face base | `bo_head_00.unity3d` | `cf_face_00_t` |
| Skin color mask | `bo_head_00.unity3d` | `cf_face_00_mc` |
| Pupil base | `mt_eye_00.unity3d` | `cw_t_hitomi_000` |
| Pupil gradient mask | `mt_eye_gradation_00.unity3d` | `cw_t_hitomigrad_000` |
| Upper highlight | `mt_eye_hi_up_00.unity3d` | `cw_t_hitomi_hi_u_000` |
| Lower highlight | `mt_eye_hi_down_00.unity3d` | `cw_t_hitomi_hi_d_000` |
| Eye white | `mt_eye_white_00.unity3d` | `cw_t_sirome_kage_000` |
| Eyebrow | `mt_eyebrow_00.unity3d` | `cw_t_mayuge_000` |
| Upper eyeline | `mt_eyeline_up_00.unity3d` | `cw_t_eyeline_up_000` |
| Eyeline shadow | `mt_eyeline_up_00.unity3d` | `cw_t_eyeline_kage_000` |
| Lower eyeline | `mt_eyeline_down_00.unity3d` | `cw_t_eyeline_down_000` |
| Nose line | `mt_nose_00.unity3d` | `cw_t_noseline_000` |

ID0 face detail, mole, cheek, lip line, lip makeup, eye shadow, and face paint
resolve to absent textures. The tool additionally exports the face detail masks,
paint mask, tooth texture, tongue masks/normal, and tear texture already referenced
by the head materials. For this offline preview and ordinary Maker path, normal
and detail textures remain raw inputs rather than proof of original lighting.
The separate source draw-shader probe has its own verified bindings and limits.

## Colors and what “default” means

The derived previews deliberately combine catalog ID0 textures with the serialized
create-material colors below. These are source-authored colors, not a claim about
the game's startup character. `ChaFileFace.MemberInit` instead initializes pupil
base black/subcolor white, other face colors white, and gradient blend zero;
`ChaFileBody.MemberInit` initializes skin colors white. A loaded card can replace
all of those values. The unmodified head prefab also refers to pupil texture 012
and highlight textures 002, which differ from ID0 constructor selections.

| Authored source material/property | RGBA |
| --- | --- |
| `cf_m_face_create._Color` | `(0.981000, 0.871536, 0.807882, 1)` |
| `cf_m_face_create._Color2` | `(0.981000, 0.710441, 0.611682, 1)` |
| `cf_m_eye_create._Color` | `(0.375000, 0.793104, 1, 1)` |
| `cf_m_eye_create._Color2` | `(0.275519, 0.327094, 0.669118, 1)` |
| Eyebrow, upper/lower eyeline, eye white | `(1, 1, 1, 1)` |
| Nose line | `(0, 0, 0, 1)` |
| Tooth | `(0.904412, 0.904412, 0.904412, 1)` |
| Tongue | `(1, 0.698529, 0.698529, 1)` |

`ChaControl.UpdateEyelineShadowColor` updates the second eyeline material to the
current skin-main color. Its serialized color `(0.941176, 0.854507, 0.830450, 1)`
is therefore not the final runtime value after customization.

## Recovered base-color equations

The inspected D3D11 fragment programs are retained locally with the shader trees,
constant bindings, and `D3DDisassemble` output in `head-materials/shaders/`.
The create programs' verified SHA-256 fingerprints are embedded in the extractor.
Recovered managed `CustomTextureCreate` and `CustomTextureControl` explain how
their outputs become the draw material's `_MainTex`.

For `create_head`, with sampled base `T`, mask `M`, and skin colors `C1`, `C2`:

```text
rgb = T.rgb * max(M.b, mix(1, C1.rgb, M.r) * mix(1, C2.rgb, M.g))
alpha = 1
```

The shader subsequently composites cheek, lip line, paint 1, paint 2, and mole,
in that order. The preview selects none of those overlays. The blue mask preserves
uncolored areas such as the mouth cavity. `preview_face_base.png` already includes
the skin colors; use a white native material factor to avoid applying tint twice.
The original `main_skin` forward fragment has no `_Color` uniform; it consumes
the completed texture.

For `create_eye`, the selected ID0 gradient mask is entirely white, so the sampled
tint is `C1`. For source red channel `v`, the fragment computes:

```text
nonlinear = saturate(v > 0.5 ? C1.rgb / (2*(1-v))
                            : 1 - (1-C1.rgb) / (2*v))
rgb = mix(C1.rgb * v, nonlinear, _Blend)
alpha = T.a * C1.a
```

The authored `_Blend` is 0.5. `CustomTextureCreate` clears its target to transparent
then blits with the shader's SrcAlpha/OneMinusSrcAlpha state for both RGB and alpha.
The stored result is therefore `(rgb * alpha, alpha²)`.
`preview_eye_base.png` includes that render-target blending; no highlight is baked.

For `create_eyewhite`, `rgb = mix(C2.rgb, C1.rgb, T.r)` and alpha is 1.
ID0's input is an 8×8 all-white texture; `preview_eye_white.png` is consequently
white with the authored colors.

These initial PNG bakes use byte-normalized RGB arithmetic and nearest integer
RGBA8 output. The source enables `GL.sRGBWrite`; the initial bake does not
reproduce project color-space conversion, GPU sampler precision, mipmaps or
render-target quantization.
The equations are recovered, but the offline PNGs remain appearance previews.
Runtime head/clothes composition now has a measured `sourceLinear` mode;
[material expansion](material-expansion.md) records that correction without
retroactively treating the earlier offline bakes as source-exact output.
Three focused numerical tests cover channel selection, blue-mask preservation,
both eye nonlinear branches, alpha blending, and eye-white interpolation.

## Draw assignments and render states

`contract.json` uses `materialSlots` and explicit `draws` entries. Material count
must not be treated as submesh count. In particular, `cf_O_eyeline` has **one**
submesh with 1,716 indices, yet its renderer assigns two materials: upper eyeline
followed by its skin-colored shadow. Both draws use the same submesh. The original
`ChangeSettingEyelineUp` sets both slots explicitly. Unity documents extra materials
as additional draws of an existing submesh; its older manual says the first
submesh, which is unambiguous for this one-submesh mesh. [Unity 5.3 Mesh Renderer manual](https://docs.unity3d.com/es/530/Manual/class-MeshRenderer.html)

| Parts | Shader | Forward state |
| --- | --- | --- |
| Face | `main_skin` | Cull Off, depth write, One/OneMinusSrcAlpha; output alpha 1 |
| Iris | `toon_eye_lod0` | Cull Back, no depth write, SrcAlpha/OneMinusSrcAlpha, stencil Replace/ref 2 |
| Whites, eyebrows, eyelines | `toon_eyew_lod0` | Same blend/depth/cull/stencil state as iris |
| Nose line | `toon_nose_lod0` | Cull Back, no depth write, SrcAlpha/OneMinusSrcAlpha; no stencil replacement |
| Tooth, tongue | `main_item` | Cull Off, depth write, One/OneMinusSrcAlpha; tagged AlphaTest |
| Tears | `toon_glasses_lod0` | Cull Back, depth write, One/OneMinusSrcAlpha; queue Transparent+1010 |

All these forward passes test depth LessEqual. Face/tooth/tongue also have separate
front-culled outline passes. The saved generic material `_SrcBlend` fields can
disagree with these compiled pass states and must not override them. The ordinary
native preview still uses approximate toon lighting and does not implement all
stencil-dependent or specialized tear behavior. Recovered draw programs also run
through a separate bytecode-to-MSL comparison probe; its scope and unresolved
differences are in the [renderer audit](../../component-audit/renderer-and-foundation.md).

## Verified skin clothing-mask coverage

Body and face use the same inspected `main_skin` shader. The exact coverage test is:

```text
coverage = min(max(mask.r, 1 - alpha_a), max(mask.g, 1 - alpha_b))
discard if coverage < 0.5
```

Thus, when both clothing states are 1, a fragment survives only if **both R and G
are at least 0.5**. A red-only greater-than discard has the opposite polarity.
This operation is verified in both forward variants 8/9, outline variant 2, and
shadow variant 12. Native color, depth/shadow and outline passes use this same
coverage rule, with `SourceBodyMaskTests` exercising all four paths. The shader's
null `_AlphaMask` default is white. `_MainTex.a` does not
control this coverage, and surviving forward fragments output alpha 1.

## Iris highlights require additional UV channels

The recovered iris fragment separately samples the two highlight inputs. With
their sampled alpha values `a1`, `a2` and colors `H1`, `H2`, it forms componentwise
`H = max(a1*H1, a2*H2)` and factor `f = H.a * _isHighLight`, then replaces the base
color with `mix(base.rgb, H.rgb, f)` and raises alpha to `max(base.a, f)`.
Highlights also influence the subsequent light response, so this is a prelighting
composition equation rather than the complete draw shader.

Original iris meshes have three UV channels. UV1/UV2 differ from UV0. The native
source rig now retains both additional channels, and `MeshData.uvs1/uvs2` upload
to distinct buffers at bindings 17/18. Meshes without these optional arrays reuse
the UV0 buffer, preserving their previous behavior. Nonempty extra arrays must
contain one finite coordinate per vertex. The selected source preview requires
both authored channels before enabling highlights.

`MaterialFlagSourceIrisHighlights` selects this composition in the regular toon
fragment: base texture at UV0, `overlay0.a` at UV1, and `overlay1.a` at UV2. Their
colors use `overlayColor0/1`; `eye.w` carries `_isHighLight`. The flag also routes
eye-kind materials to that fragment instead of the native synthetic eye shader.
Generic overlays retain their original UV0 tint equation. The uniform layout
remains 288 bytes.

`SourceIrisHighlightTests` runs the production Metal vertex and fragment entry
points against 12 independently calculated cases. It checks channel placement,
componentwise maximum, per-color alpha, fractional/disabled highlights, preserved
base alpha, repeat sampling, UV0 fallback, and generic overlay behavior. Two
additional tests verify buffer values, fallback identity, and rejection of
partial/nonfinite channels. The recorded four-pass source body-mask GPU probes
also passed with the extended vertex interface.

This implements the neutral highlight surface composition, with identity source
texture transforms and native toon lighting. Runtime highlight offsets, eye
tilt/gaze, expression texture sampling, and the source's subsequent light response
remain unsupported. It does not establish complete iris draw parity.
