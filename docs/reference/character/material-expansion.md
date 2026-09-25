# Maker material expansion and Metal translation

Reviewed 2026-09-25. This is the current bounded albedo-composition path, with
recorded source-player evidence below. [Maker coverage](maker-coverage.md) gives
the converted/catalog denominators; the
[component audit](../../component-audit/character-and-mods.md) (CM-30–32, CMT-04)
owns the remaining recipe work. Commands run from the repository root.

The material path now includes original catalog patterns, cheek makeup, lip-line
makeup, two face-paint layers and moles. These are albedo composition operations;
they do not establish original lighting, gloss, stencil or whole-frame parity.

`Tools/reverse/maker_material_contract.py` verifies the previously recovered
`create_head` and `create_topN` DXBC program hashes, extracts the original material
catalog and produces hash-checked RGBA inputs. The converted sets contain 38
nonzero pattern IDs, seven cheek IDs, six lip-line IDs, 23 face-paint IDs and three
mole IDs. The two audited source catalogs contain 40, seven, six, 26 and three
non-null IDs respectively; not every pattern/paint texture has been converted.
Null selection zero stays null. `maker_asset_materials.py` binds the
converted hair, shirt, trousers and shoes to their exact geometry catalog IDs.
The initial library has 15 component appearance sidecars; an appearance sidecar
is not proof that all of a component's original shader behavior is implemented.
Glasses retain explicit flat-color/transparency limitations.

The original `ChaControl.CreateFaceTexture` chooses coordinate makeup only when
the raw `enableMakeup` byte is nonzero. Otherwise it uses `face.baseMakeup`.
`SourceCardAppearance` follows that choice and writes color edits back into that
same record. Inactive makeup, selected asset IDs, unknown fields and opaque mod
payloads remain unchanged. Source UniversalAutoResolver properties are checked
before loading layer or pattern textures; matching a numeric ID alone cannot
substitute an unrelated original material for a saved mod identity.

Clothing composition replaces each of the three region colors with its
pattern/color pair, then applies the original RGB clothing mask. Pattern scale
is `20 - 19 * tiling`. Head composition applies cheek, lip-line, paint 1, paint 2
and mole in the recovered shader order. Paint and mole use the original layout
mapping and UV rotation/scale; face paint also samples the original paint mask.
Converted upright rows use the original bottom-up Unity UV convention exactly
once. Inputs use explicit clamp/repeat and bilinear texel-center sampling.

## MSL backend and verification

`SourceMaterialCompositor.swift` contains the Metal Shading Language translation
for `create_head`, `create_eye`, `create_eyewhite`, `create_topN` and the recovered
hair albedo equations. Maker uses that compute path by default. The CPU path is
still selectable through `SourceAppearanceCompositionBackend.cpu` for regression
comparison. Shader compilation disables fast math. Manual bilinear reads avoid
hardware sampler precision and mip-selection differences in the bounded
composition contract. Recipes tagged `sourceLinear` linearize their material
colors and encode composed RGB back to sRGB; this mode is permitted only for the
head and clothes passes measured in the original. Alpha is unchanged. Generated
bytes are exposed through an sRGB texture view for renderer sampling. Other
shader families retain their explicit earlier color-space limitation.

The independent NumPy oracle covers 128 randomized pattern/layer/layout cases.
Full-size face and clothing texture fixtures run through both CPU and Metal
backends; every channel must be within one byte of the oracle. The existing
female/male appearance image oracles also run against Metal. Tests additionally
check coordinate/base makeup edit destinations, saved mod identities, missing
files behind identity guards, accessory slot contextualization, texture budgets,
path/hash validation and transient texture lifetime.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/maker_material_contract.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/maker_asset_materials.py
IKKOKU_MATERIAL_LAYER_REFERENCE="$PWD/.local/reverse/rigs/expanded-materials/pixel-oracle.json" \
IKKOKU_MATERIAL_IMAGE_REFERENCE="$PWD/.local/reverse/rigs/expanded-materials/image-oracle.json" \
IKKOKU_APPEARANCE_REFERENCE_ROOT="$PWD/.local/reverse" \
  swift test --package-path Packages/Engine --filter 'source(CardAppearance|ActiveMakeup|Material|Appearance|Color)'
```

The recorded run of 18 focused fixture tests passed with both image-oracle variables enabled;
an additional standalone test checks the sourceLinear conversion on both backends,
rejects unverified color-space modes and verifies unchanged card bytes. In recorded separate
focused runs, expanded texture validation took 27.25 seconds on the CPU route and
4.68 seconds on Metal. Those durations include hashing, loading and texture
uploads; they are not interactive frame-time measurements or a controlled
performance benchmark.

## Original-player comparison harness

`Tools/reverse/original_shader_probe.py` prepares an isolated original Studio
player under a unique `C:\Temp\IkkokuShaderProbe-*` directory. It copies the
executable, loader and BepInEx core, references the installation's assets and
managed runtime through junctions, and installs only the validation plug-in into
that temporary copy. No installed user saves, configuration or mod files are
changed. The probe launches through the current guest user so Unity can create
a graphics device. The first launch through Parallels' default SYSTEM account
failed to create its DX11 window and produced no valid comparison.

The material-blit probe renders only configured face/clothing material blits. Collection stops
only the recorded private player process after checking its executable path;
`--stop` is available if a probe fails before producing its report. It
does not capture the desktop, a card thumbnail or an arbitrary game camera.
Source texture catalog names and material parameters are recorded; every input
bundle hash is checked against the recovered local source. Original
texture filtering, mipmaps and project color-space behavior stay active. The
original ran on the Parallels Display Adapter, D3D 11.1, in Linear color space.
Its two 1024×1024 captures exposed the missing material-color conversion. That
conversion is now implemented in both CPU and Metal paths and all four alternate
head assembly sidecars were regenerated with complete pattern/layer inputs.

| Pass | Earlier mean error /255 | Corrected mean error /255 | Channels within 1 byte | Maximum error |
| --- | ---: | ---: | ---: | ---: |
| Head with makeup/paint | 3.7913 | 0.00990 | 99.8896% | 40 |
| Clothing with patterns | 4.3644 | 0.01491 | 99.99993% | 2 |

These recorded measurements compare the original GPU readbacks to the independent native
equation oracle; native CPU and Metal outputs are separately checked against that
oracle within one byte. Sparse head-edge differences remain unresolved, and the
clothing output has three channels beyond one byte. Neither pass is claimed
pixel-exact. The original blit plus readback CPU times were 14.92 ms for head and
37.26 ms for clothes; these are single composition calls, not gameplay frame times.
These isolated images cannot establish full character/scene parity.

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_shader_probe.py
# After the isolated player has exited:
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_shader_probe.py --collect
```

Local evidence, originals and generated images stay in ignored `.local/reverse`.
The probe records its exact VM directory and process ID in `run.json`. Logs and
pixel comparison results are collected under `.local/reverse/original-shader-probe`.

## Remaining limits

Lip makeup and eyeshadow remain separate unported draw-material overlays.
Body detail/paint, alternate create-shader families, accessory material coloring,
emblems, extra clothing channels and arbitrary plugin shader replacements remain
unsupported. The runtime reports omissions and preserves the original card
records. Color-space behavior outside the measured head/clothes passes, absent
mip derivatives in native composition and the native renderer's existing lighting
are explicit limits until measured
against the corresponding original passes and scene configuration.

Draw-shader bytecode translation and matched clothed-frame comparisons have a
separate probe path described in the [renderer reference](../renderer.md) and
[renderer audit](../../component-audit/renderer-and-foundation.md). Those probes
do not automatically replace Maker's normal toon draw material, and their
geometry/depth results must not be read as complete color or material parity.
