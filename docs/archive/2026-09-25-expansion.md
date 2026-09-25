# Archived Maker, Studio and translation checkpoint — 2026-09-25

This is a historical milestone snapshot. The later [component audit](../component-audit/README.md)
documents the current working tree, including integration defects, feature-level
completion status and actionable remaining work. Prefer that audit when planning
implementation or assessing support.

This checkpoint extends the Swift + Metal port. It is not whole-game, complete
CharaStudio or arbitrary BepInEx compatibility. Original assets, decompiled code,
converted resources, comparison images and private VM probe files remain local.

## Maker selections and identity

The source loader now resolves hair, clothing and the original 20 accessory slots
from card records. Converted components retain their original catalog IDs and
ordinal mod GUIDs. UniversalAutoResolver uses the first original property record
and its source slot; runtime local slots do not replace saved identity. Unknown
selections remain diagnostic fallbacks. An unresolved mod head cannot alias a
vanilla head with the same integer ID.

Supported normal assemblies include male/female heads 0, 200 and 201 and the
original nonzero bone-type correction table. Accessory correction uses the source
centimeter units, Unity Z-X-Y rotation order and original attachment transforms;
absent optional correction nodes are skipped as in the source. Slot-local mesh
names prevent material collisions without rewriting node or bone identities.
Explicit empty catalog entries remove components. Top changes update body coverage
masks while retaining edited skin color; removed tops clear the old mask.

Ten controlled clothed fixtures cover both sexes, all three heads, corrected bones,
moved glasses, patterned clothing and makeup on default/additional heads. The
selection tests also preserve 99 opaque tokens per card, all seven outfits, original
asset/mod IDs, unknown blocks and plugin payloads. Four app edit/export/reimport
cases cover additional-head female/male cards, a patterned card and an active
coordinate cheek-color edit. All four render pixel-identically after reload;
independent token audits confirm that unedited identities and records survive.

Coverage is explicitly bounded to recovered catalogs 00 and 50:

| Category | Converted drawable entries | Catalog drawable entries |
| --- | ---: | ---: |
| Hair | 6 | 100 |
| Clothes | 8 | 213 |
| Accessories | 1 | 190 |
| Normal head IDs | 3 | 3 |

There are also 11 converted empty entries and six sex/head assembly combinations.
All 15 drawable entries have appearance and card-binding sidecars. This is not an
installed-mod coverage count. See [coverage](../reference/character/maker-coverage.md).

## Materials and original-player comparison

The recovered compositor implements clothing patterns, cheek/lip-line makeup, two
face-paint layers and moles on CPU and Metal. Active coordinate makeup edits route
back to the source coordinate record; inactive makeup and resolver IDs survive.
Expanded dependency copying now includes every pattern/layer texture for alternate
heads. Source-linear behavior is explicit on the verified head/clothes recipes.

A private copy of the original Unity 5.6.2f1 player ran controlled 1024×1024 material
inputs on Parallels D3D11.1. The captures exposed material-color linearization and
sRGB output encoding missing from the earlier byte-normalized model. After the
correction, head MAE is 0.00990/255 (99.8896% of channels within one byte; sparse
edge maximum 40), and clothing MAE is 0.01491/255 (99.99993% within one byte;
maximum 2). This is material readback comparison, **not matched whole-character
frame parity**. Original lighting, gloss, stencil, filtering/mips and remaining
shader behavior are still incomplete. The private probe processes were stopped.
See [material translation](../reference/character/material-expansion.md).

## Studio loading, posing and edited source scenes

Studio now shares the Maker card-selection path, including male/female assemblies,
additional heads/bone types, materials, saved outfit index, static ABMX and saved
expression inputs. Missing conversions remain visible diagnostics. Recovered
attachment IDs map to original ChaReference nodes and follow source FK edits.
Current and ten saved cameras preserve full distance vectors, FOV and roll;
orbit edits return to the native two-angle controls.

Source FK viewport guides retain original catalog bone IDs and Unity local Euler
values. Rotations are composed from local quaternions so a nonuniform ancestor
cannot introduce world-matrix shear into the edited rotation. Ambiguous signed or
matrix-authored local rotations are rejected. Native scene cards preserve source
references, attachment IDs and source FK edits. Object guides and focus use the
same attachment frame as rendering, including conversion of world drag deltas back
into attachment space.

The recovered IK binding contract restores 13 guides and runs the tested four-limb
kernel for eight pole/end destinations. Body/proximal IDs 0/1/4/7/10 and iterative
full-body constraints/spine mapping remain deferred. The original sequential hand
pull prepass is recovered but is not guessed into the unported spine stage.
See [IK boundaries](../reference/studio/full-body-ik.md).

`File → Export Edited Original Scene…` saves a new original-format scene. The pure
writer supports source object/FK/IK/look-at/item-FK transforms, kinematic flags,
bounded embedded-card edits, current/saved cameras and an explicit replacement PNG.
The app connects object/FK/camera edits and generates a fresh thumbnail when edited.
Untouched component values keep their original bytes, including unchanged Euler
angles during position edits. Adding/removing/reparenting objects and native
lighting/effects/timeline edits are rejected instead of silently lost. Export also
rejects unhandled name/type changes, replacement native cards, hand/visibility
overrides and changed source references. Native scene saves retain the imported
name/type baseline so these checks survive saving and reopening the workspace.

Empty writer edits are byte-identical. Independent audits cover two recovered
original scenes and three synthetic scenes, including variable-sized embedded
cards and preserved scene/card plugin trailers. Source serialization preserves
unknown plugin data; it does not execute unknown plugin callbacks.
Two fully clothed app scene fixtures, covering additional-head female/male cards,
render pixel-identically after position/FK edit, export and reload.
See [scene serialization](../reference/studio/scene-editing.md).

## C# semantic translation

`Tools/translation` uses Roslyn semantic symbols and AST nodes to produce explicit
IR and Swift. Supported operations include bounded scalar/vector state,
Awake/Start/Update/FixedUpdate, Transform access/Translate, clone/destroy/activation,
and selected Mathf functions. Unsupported syntax/API rejects with source locations;
a failed translation cannot leave stale generated Swift.

Eight translation tests compile/execute the generated code. They include 4,002
comparisons against two methods in the unmodified original managed DLLs, plus
lifecycle ordering, configured clocks and identity preservation. Generated components use an explicit
host bridge; live gameplay/Studio adapters and arbitrary Harmony/BepInEx behavior
remain future work. See [AST/API scope](../reference/mods/api-substitution.md).

## Performance and reproducibility

`IKKOKU_BENCHMARK_OUTPUT=/absolute/report.json` alongside `IKKOKU_AUTOCAPTURE`
measures the same Metal pass graph with reused offscreen targets. Three warmup
frames precede twenty measured frames by default (`IKKOKU_BENCHMARK_FRAMES`). CPU
encoding, synchronous completion and Metal command-buffer GPU timestamps have
separate p50/p95 distributions. Reports include process resident bytes, current
Metal allocation, store resource counts, triangles/vertices and per-card asset
selection coverage. Resident and Metal byte counts overlap on unified memory and
must not be added.

The ten-card Debug run on Apple M2 Ultra at 600×800 measured GPU p50
0.433–0.588 ms, GPU p95 0.453–1.101 ms, CPU encoding p50 2.522–3.413 ms and
completion p50 3.290–4.778 ms. Resident memory after rendering was 279–363 MiB;
Metal allocation 343–386 MiB. All ten fixtures rendered with zero missing selected
assets or mesh handles. This reused-target render baseline excludes asset import/composition,
SwiftUI, pose construction, animation/simulation and PNG readback; it is not
interactive FPS or an original-player performance comparison.

Evidence lives under `.local/reverse/maker-expansion`, `studio-expansion`,
`studio-edited`, `original-shader-probe` and `api-substitution`. The combined local
fixture environment is `maker-expansion/validation-env.json`. Source fixture
generators are `maker_selection_fixture.py`, `studio_selection_fixture.py` and
`studio_attachments.py`. Current final build/test/capture results are recorded in
`maker-expansion/checkpoint.json` alongside those artifacts.

The final arm64 Debug app build passes. Validation passes 322 Swift tests with the
local recovered fixtures, 239 Python reverse/analysis/mod tests and eight semantic
translation tests. The ten Maker app captures, four independently audited edited
card round trips and two edited Studio scene round trips pass. The last Studio
captures include the final export guards and attachment-guide fixes.

## Remaining dependencies

Complete conversion coverage, special male/modded-head assemblies, selected hair
and accessory dynamics, wear-state rendering and runtime material/plugin overrides
remain. Studio still needs complete item/map assets, iterative full-body IK,
animation/voice/routes/effects and broader plugin adapters. Full matched-scene
visual/behavior comparison and playable gameplay/NPC integration remain unfinished.
Guide editing during native timeline scrubbing still uses stored transforms while
rendering samples the timeline; animation-aware guide frames remain part of that
integration. Original-scene export already rejects native timeline edits.
