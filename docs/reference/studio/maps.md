# Original CharaStudio maps (ST-A11, ST-B03, ST-T04)

Reviewed 2026-10-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

An imported CharaStudio scene that names an original map now shows that map in the Studio preview, placed the way CharaStudio 1.0.4.2 places it. The first slice converts one map, Map 33 `空き部室` (`bushitu`), at full texture resolution. Every other `Map_XX` row is listed in the catalog with no conversion, and a scene that names one of them says so by name. The map is runtime-only: the native document has no map field, and original export still writes the scene record's map bytes verbatim.

Since the second slice, the preview draws Map 33 with its baked lightmaps. Each surface gets the term Unity 5.6's Standard shader computes for a lightmapped draw: the albedo times the decoded directional lightmap, plus emission. The decode runs in the shader on the bundle's own lightmap blocks (see [baked lightmaps](#baked-lightmaps-slice-2)). The status line names what is still left out, word for word:

`baked lightmaps; approximated: no realtime sun or its shadows, no specular or reflections, no normal, metallic or detail maps, no fog, no camera effects`

A converted map without lightmaps (a first-slice export) still draws with the item toon material under the scene light. It keeps the first slice's label, `approximated: no baked lightmaps, map lights, sun-type lighting, fog or ambient`.

## Recovered rules

These rules come from the recovered managed code (`Studio.Map`, `Studio.MapCtrl`, `Studio.Info`, `SunLightInfo`, `LightmapPrefab`, `Manager.Scene`). The original player confirmed them in phase B (see [evidence](#evidence)).

- **Lookup.** `Map.LoadMapCoroutine` looks the record's map number up in `Info.dicMapLoadInfo`. A number with no row, -1 included, runs `ReleaseMap` and shows no map. Mods can add rows; this slice evaluates only the installed `Map_XX` tables and never substitutes another map.
- **Loading.** The row's bundle and scene name go to `Manager.Scene.LoadBaseScene`. The scene loads additively and becomes the active scene. `Reserve` finds the scene's root GameObject named `Map`, which becomes `mapRoot`. `InitScene` (New Scene, and the start of every scene load) calls `ReleaseMap`.
- **Placement (`MapCtrl.Reflect`).** Only `mapRoot` moves: `localPosition = caMap.pos` and `localRotation = Quaternion.Euler(caMap.rot)`. The saved scale is never written, so the root keeps its authored scale, and every other root of the map scene stays where it was authored. `Quaternion.Euler` applies Z, then X, then Y (q = qy · qx · qz).
- **Scene loads.** The scene-load UI (`SceneLoadScene`) uses `Studio.LoadSceneCoroutine`. It waits for `AddMapCoroutine`, copies the record's `caMap` back, then calls `MapCtrl.Reflect()`. The synchronous `Studio.LoadScene` would leave `caMap` at the values `AddMap` reset. Adding a map through the UI (`AddMap`) resets `caMap` to zero.
- **Sun type.** `sunLightType` selects a `SunLightInfo` entry on `mapRoot` (`FirstOrDefault` by type). `SunLightInfo.Set` deactivates every other entry's `visibleList` objects and activates the chosen entry's, in array order, so a node listed twice takes the later list's value. A saved value with no entry changes nothing, so the authored state holds. The converter keys this state as `-1`.
- **Lightmaps.** `LightmapPrefab.Resetup` overwrites a listed renderer's `lightmapIndex` and `lightmapScaleOffset` at `Start` when its saved index is 0 or more. Otherwise the renderer's serialized values stand, and Unity's 0xFFFF and 0xFFFE indices mean no baked lightmap.
- **Catalog (`Info.LoadMapLoadInfo`).** The info bundles load in sorted name order. In each `Map_XX` table the two header rows are skipped, as is a row whose first cell is not an Int32, and a later row replaces an earlier one with the same number. The columns are: number, name, bundle path, scene name, manifest, and the vanish bundle and file.

## Converter and catalog

`Tools/reverse/export_map_scene.py` reads a map scene bundle with UnityPy 1.23.0. It reuses `export_prefab.py`'s conversion helpers: the Z reflection into the engine basis, winding, the UV origin and tangent handedness.

- **`inventory`** writes metadata only: renderers, triangles, built-in meshes, materials, textures, shaders and a draw and texture budget.
- **`export`** writes one glTF with external `.bin` and PNG files, plus `provenance.json`. It runs through the same `.local` output guard as the other subcommands.
  - Geometry is merged per role, material, visibility class and lightmap index. Vertices under `mapRoot` (role `mapRoot`) stay in its local frame. Vertices under other roots (role `scene`) are written in scene world space.
  - The root node is named `Map`, carries only the authored scale, and has the extra `ikkokuMapRole: "mapRoot"`. Each mesh's `ikkokuMap` extras give its role, the sun-type keys it is visible for (0, 1, 2 and -1) and its lightmap index.
  - Materials go through `MAP_SHADER_RULES`, which list the dropped terms. `Standard` keeps base colour, texture and alpha mode. `Particles/Alpha Blended` keeps 2 × tint × vertex colour. Any other shader fails the conversion by name. `Skybox/*` shaders draw nothing.
  - `_MainTex_ST` is baked into UV0. TEXCOORD_1 holds the lightmap UV: mesh UV1 (else UV0) × `lightmapScaleOffset`, using the `LightmapPrefab` value where it names the renderer, then V flipped like UV0.
  - **Lightmaps (slice 2).** Each `LightmapSettings` entry's light map and CombinedDirectional direction map are written as `lightmap-<index>-light.bc3` and `lightmap-<index>-dir.bc3`. Each file is the texture's serialized `image_data`, byte for byte: DXT5 blocks (BC3), all 11 mip levels largest first, rows bottom-up as in Unity's texture memory. Nothing is decoded or re-encoded, so each file's SHA-256 is the serialized data's. The glTF's top-level `ikkokuLightmaps` extras (`kind: ikkoku.unityLightmaps`, version 1) name the files with their format, size, mips, colour space (`m_ColorSpace` 1 is sRGB), byte count and SHA-256. They also record the lightmaps mode (`CombinedDirectional`), the encoding (`m_LightmapFormat` 2, RGBM), the row order and the player's colour space (Linear). A mode, encoding or format the app does not reproduce fails the export by name.
  - **Standard inputs (slice 2).** Each `Standard` material carries `ikkokuStandard` extras:
    - `_Color` converted to Linear with `GammaToLinearSpaceExact`, as a Linear player uploads material colours;
    - `OneMinusReflectivityFromMetallic` of `_Metallic`, or under `_METALLICGLOSSMAP` of the `_MetallicGlossMap` red channel's mean (the texture is linearized first when it is sRGB);
    - under `_EMISSION`, `_EmissionColor` in Linear and the `_EmissionMap` image. The map is sampled at UV0, where Standard samples it (`i.tex.xy`).

    A lightmapped material's `droppedTerms` list only what the lightmap material leaves out (`droppedLightmapped`). The first slice's item-material list is used where a material is drawn without a lightmap.
  - `provenance.json` records:
    - the bundle hashes and output hashes;
    - the transform rule;
    - each lightmap's name, size, format, mip count and serialized-data hash, and whether it decodes;
    - which lightmap files were written (`lightmapExport`);
    - the `SunLightInfo` entries, the lights and RenderSettings;
    - the dropped shader terms.
- **`catalog`** writes `catalog.json` (`kind: ikkoku.sourceStudioMapCatalog`, version 1). It holds every `Map_XX` row of the supplied info bundles, keyed by original number. Each row has its converted glTF path relative to the catalog, or `file: null`, plus the conversion summary and approximation list.

Outputs are refused outside the ignored `.local` directory. A symlink placed directly in `.local` counts, because a worktree links the main checkout's private folders that way. The runtime fixtures sit beside the converted items:

| Fixture | Location |
| --- | --- |
| Converted map 33 | `.local/reverse/exports/maps/33-bushitu/`: 8 meshes, 8 materials, 8 PNGs, 2 lightmap files, 2,526 vertices, 1,492 triangles. Until the slice-2 export is installed (see [installing the slice-2 export](#installing-the-slice-2-export)), this is the first slice's export (7 PNGs, no lightmaps), and the private copy is `.local/sta11b-lightmaps/exports/maps/` |
| Catalog | `.local/reverse/exports/maps/catalog.json`: 42 rows (0–41) from 23 info bundles; only 33 converted |
| Source bundles | `.local/reverse/source/abdata/` (`studio/map/bushitu.unity3d`, `studio/map/akikyoushitu.unity3d`, `studio/info/*.unity3d`, `abdata`), each with a `.provenance.json`. To save disk space, `akikyoushitu.unity3d` (26.9 MB, used only for Map 34's inventory) is a symlink into the external archive (`/Volumes/My Book/ikkoku-archive/local/sta11a-maps/`), with the same SHA-256 |
| Authored scenes | `.local/reverse/studio-scenes/maps/scene-map33.png` and `scene-map33-showoff.png`, with `provenance.json` |

Map 33's conversion has 8 merged draws for every sun type, all 8 lightmapped with lightmap 0. Its 7 base textures are 512² to 2048² DXT1/DXT5 in the bundle. They need 51,729,740 bytes as RGBA8 with mips (Metal reports 52,248,576 allocated) against 7,165,376 bytes native. Slice 2 adds the 512² emission map of `mm_koi_stu_map49_denki00` (`4_mt_koi_stu_map49_denki00_em.png`, 1,398,100 bytes as RGBA8 with mips). Because it is inserted at image index 4, the glass, metal and roof images move to indices 5–7; their bytes are unchanged. `glass00`'s emission map is its base texture, so it adds no image. The two lightmaps take 1,398,128 bytes each as BC3. Altogether Metal allocates 56,492,032 texture bytes, 2,818,048 of them for the lightmaps.

With the first slice's export, the map's only shader, `Standard`, made the catalog list `shaders approximated (Standard)`, and the status line appended it after the label. With lightmaps drawn, the catalog row's `approximations` instead name the omitted terms one by one. These are the label's terms: realtime sun and its shadows; specular and reflections; normal, metallic and detail maps; fog; camera effects. Only a shader other than `Standard` would still be listed as approximated.

## Runtime

`Packages/Engine/Sources/Studio/SourceStudioMap.swift` holds the engine side. `Apps/IkkokuCreator/Studio/StudioModel+SourceMap.swift` holds the app side.

- **Catalog.** `SourceStudioMapCatalog.load` reads `IKKOKU_STUDIO_MAP_CATALOG`. It refuses another kind or version, duplicate numbers, and a file path that leaves the catalog directory. `resolve` returns one of four cases: `.none` (-1), `.converted`, `.notConverted` or `.notInCatalog`. Only `.converted` draws.
- **Request.** `SourceMapRequest.make` reads the record's map number, transform and sun type at import (and at rehydration), with the scene SHA. A scene without a map (-1) has no request, and no catalog read happens. Without a catalog, the line says why.
- **Loading off the main thread.** `SourceStudioMapLoad` runs `SourceStudioMapAsset.load` on a GCD worker at `.userInitiated`, never on the main thread or the Swift concurrency pool. The load is blocking work: file reads, PNG decodes, MetalKit texture loads and, since slice 2, the lightmap files' SHA-256 checks and block uploads.
  - The import job starts the load beside the characters. The commit hands both to the model. A cancelled or failed import cancels the load.
  - The result returns on the main queue. Synchronous paths (captures, scenarios) wait for the load instead, so their first frame already has the map.
  - A finished load nobody took is released.
- **Textures.** Textures are registered privately (`cacheNew: false`). `release()` retires meshes and textures through `ResourceStore.retire(meshes:)` and the new `retire(textures:)`, so a frame already in flight keeps them until a later frame is prepared. Slice 2's lightmaps and emission maps are owned and released the same way. A load that fails part-way unregisters everything it registered.
- **Lightmapped parts (slice 2).** `SourceStudioLightmapSet.parse` reads the glTF's `ikkokuLightmaps` extras. An export without them gives nil, and every part keeps the item material. A part whose mesh has a lightmap index of 0 or more, and whose material has `ikkokuStandard` extras, is drawn with the map material (`MaterialKindMap`, see [the material](#the-map-material)). The load fails by name, and registers nothing, when such a part names a lightmap the map does not carry or has no TEXCOORD_1, or when a lightmap file's size or SHA-256 differs from the extras.
- **Placement.** `SourceStudioMapPlacement.mapRootMatrix` computes `T(pos) · R(UnityCoordinates.eulerDegrees(rot))` in the engine basis, which is B · M_unity · B with B = diag(1, 1, -1, 1). A non-finite component is refused by name. `mapRoot` parts are drawn at `root × local`, and `scene` parts at their authored matrix.
- **Timing.** Each placement sets the `sourceMapReady` startup mark (the perf report keeps the first) and prints `[ikkoku] source map: <draws> draws (<n> lightmapped), <triangles> triangles, <bytes> texture bytes (<bytes> in <n> lightmaps); loaded in <ms> on a worker, placed in <ms> on the main thread`. An import's load usually ends before the import commits, so the map is placed at the commit.
- **Sun type.** `sunTypeKey` maps 0–2 to themselves and any other value to -1, and parts not visible for that key are skipped.
- **Draws and picks.** Every map draw has `objectID` 0, `pickOccluder` (new on `RenderItem`), no shadow casting, no outline, and `order` 100, which puts it after the characters. The pick pass draws pick occluders with id 0. A pick or hover over map pixels therefore selects and highlights nothing, while a character in front of a wall still picks. Gizmos still draw on top.
- **Status line.** `sourceMapLine` sits under the Studio status line (`studio.status.map`). Its forms:
  - `Map 33 空き部室 (bushitu): baked lightmaps; approximated: no realtime sun or its shadows, no specular or reflections, no normal, metallic or detail maps, no fog, no camera effects · 1492 triangles, 8 draws` once the map is drawn with its lightmaps;
  - `…: baked lightmaps on <n> of <m> draws (the rest as items); approximated: …` when only some parts are lightmapped;
  - `…: approximated: no baked lightmaps, map lights, sun-type lighting, fog or ambient; shaders approximated (Standard) · …` for an export without lightmaps;
  - `…: loading`;
  - `…: not converted (<bundle>); no map shown`;
  - `Map <n>: not in the map catalog (mods are not evaluated); no map shown`;
  - `…: not loaded (<error>); no map shown`.
- **View ▸ Show Source Map.** Hides the map without unloading it, and the line adds `· hidden (View ▸ Show Source Map)`.
- **Document and history.** The request belongs to the scene SHA, like the scene light, so undo/redo and New Scene followed by undo keep it. A load cancelled by New Scene resumes after the undo (`resumeSourceMapIfNeeded`). A native save loaded in a fresh process rebuilds the request through the scene-file rehydration. Native scenes and scenes without a map are unaffected.

`IKKOKU_SOURCE_MAP_PROBE=<directory>`, used with `IKKOKU_SOURCE_SCENE` and `IKKOKU_AUTOCAPTURE`, writes the map's draws alone from the capture camera:

- `native-map-geometry.png`: white on black;
- `native-map-depth-normals.png`: Unity's depth-normals encoding over a 25 m far plane, `AppState.sourceMapProbeDepthFar`;
- `native-map.json`: the census, the camera matrices, the map root and every draw's model matrix, in the engine basis, column-major;
- for a lightmapped map (slice 2), `native-map-irradiance-<variant>.rgba16f.deflate`: the map drawn with `SourceStudioMapMaterial.irradiance`, read from the HDR scene target (`Renderer.captureSceneHDR`, after the MSAA resolve and before bloom, grading and the sRGB composite) as RGBA float16, rows top-down, raw DEFLATE. The variants are `decoded`, `nonDirectional` and `gammaConstants` (see [the irradiance gate](#the-irradiance-gate)). `native-map.json` lists them under `irradiance`.

A scene whose map is not drawn fails, and the failure names the status line.

## Evidence

All VM work used one `prlctl exec` per phase. The Parallels errno-24 count was 0 before and after each phase. Nothing was written under `C:\Illusion\Koikatsu`, the private roots were removed, and no game process was left running.

**Phase A** (`original_map_probe.py fetch`) copied the two Studio map bundles, the 23 `studio/info/*.unity3d` bundles and `abdata/abdata` out of the installed game. Each file was hashed in place and again after the copy, and the hashes recorded in `.local/sta11a-maps/fetch-a/fetch.json` match.

**Phase B** (`original_map_probe.py capture`, `Tools/reverse/fixtures/OriginalMapProbe.cs`) authored two scene records in the original player, then read each back through `Studio.LoadSceneCoroutine`.

- **`scene-map33.png`** (SHA-256 `2043b3cb…6b9c`): an emptied scene with map 33, map transform pos (0.3, -0.05, -0.5) and rot (4, 25, -3), and a camera inside the room. The load took 0.231 s.
- **`scene-map33-showoff.png`** (SHA-256 `c5a8135c…d694`): `koikatu_cs0002591.png` with map 33 added (transform reset to zero by `AddMap`) and the scene's own camera, fov 23. The load took 10.6 s, mostly characters.

After each load, the player recorded the following in `map-trace.json`:

- `mapRoot`'s pose and `localToWorld`;
- every map renderer's matrix, bounds, lightmap index and scale/offset, materials and shaders;
- the lights, lightmaps, RenderSettings and `SunLightInfo`;
- the `Camera.main` matrices.

It also rendered three images: the full colour frame, a map-only white silhouette, and the map-only `Hidden/Internal-DepthNormalsTexture` pass from `Camera.main`'s pose with far = 25.

The trace confirms the placement rule. `mapRoot`, the only root of `bushitu`, is at (0.3, -0.05, -0.5) with rotation `Quaternion.Euler(4, 25, -3)` and scale 1.

`Tools/reverse/compare_original_map.py` compares our `IKKOKU_SOURCE_MAP_PROBE` capture of each authored scene with the original at 960×720, with no registration, resizing or camera fitting. Its gates:

| Gate | Tolerance | map33 | map33-showoff |
| --- | --- | --- | --- |
| Record our parser read = the original's `sceneInfo` | 1e-6 | 1.2e-8 | 0 |
| Original `mapRoot` = `Reflect` computed independently | pos 1e-5 m, rot 1e-3°, scale 1e-5 | 0, 0°, 1.2e-7 | 0, 0°, 0 |
| Our map root (B·M·B) = original `localToWorld`; every draw uses it | 1e-5 per element | 1.4e-7; 0 | 0; 0 |
| Draw flags: id 0, pick occluder, no shadow, no outline | exact | 8/8 | 8/8 |
| Our view = original `worldToCameraMatrix` · B; vertical fov | 1e-5; 1e-4° | 2.4e-7; 0 | 1.5e-7; 0 |
| Map-only silhouette IoU | ≥ 0.999 | 1.0 (0 differing of 691,200) | 1.0 |
| Depth p99 on shared pixels | ≤ 2·25/65025 m (7.7e-4) | 0 (max 3.8e-4) | 0 (max 3.8e-4) |
| Normal p99 | ≤ 2 channel bytes | 0 | 0 |

Two controls must fail, and both do:

- our depth image shifted one pixel: p99 0.0123 m for map33 and 0.0115 m for the showoff;
- map33's rotation composed in the wrong order (X, Y, Z): 1.31° from the original.

The Euler control does not apply to the showoff scene, whose rotation is zero.

Colour is reported and not gated: mean absolute error 27.4 channel bytes (p99 76) for map33 and 58.3 (p99 193) for the showoff. The map has no baked lighting, and the showoff's characters keep the existing character-fidelity differences. The comparison is `.local/sta11a-maps/comparison.json`, and our captures are in `.local/sta11a-maps/ours/<case>/`.

The Engine tests are `SourceStudioMapTests` and `PickTests`:

- catalog parsing and path refusal;
- the four resolutions and their lines;
- the `Reflect` matrix against an independent Unity Euler;
- sun-type filtering;
- the load, wait, cancel and release ownership;
- pick occluders hiding what is behind them without selecting.

The Python tests are `test_export_map_scene.py`, `test_compare_original_map.py` and `test_original_map_probe.py`. The Studio scenario lane has four checks ([verification README](../../../Tools/verification/README.md#source-maps-st-a11)):

- **`studio-scenario-source-map`** runs on the showoff scene and covers:
  - the map, the line and the picks;
  - the View toggle;
  - an export byte-identical to the source with the map hidden or shown;
  - reimport, New Scene and undo.
- **`studio-scenario-reload-save-source-map`** saves that scene natively.
- **`studio-scenario-reload-load-source-map`** loads the save in a fresh process: one rehydration, and the map draws again.
- **`studio-scenario-source-map-none`** runs on `koikatu_cs0002591.png`, which names no map, with the catalog supplied: there is no request or line, and the export is byte-identical.

On the Debug build of `ceccafa`, the full Studio lane passed 77/77 under `--strict` and `maker-scenarios` 10/10. Both passed again on the merged head `c094f92` (main `6502803`). The private-source Engine suite there ran 999 tests: 978 passed, 20 were skipped, and 1 failed, the known `liveSourceShadersMeetTheControlledOriginalFrameGates`. Two negative controls ran on the same build, and both fail as they must (`.local/sta11a-maps/controls/`):

- a scenario of six asserts that contradict the map scene (a map-only point picks something, a character point picks nothing, map 34, no map, 8 draws while hidden, no `hidden` note): 6 of 6 asserts fail;
- `source-map.json` without `IKKOKU_STUDIO_MAP_CATALOG`: 5 of 15 steps fail, and the line reads `Map 33: no map catalog (IKKOKU_STUDIO_MAP_CATALOG is not set); no map shown`.

Reproduce:

```sh
P=.local/reverse/unitypy-venv/bin/python
$P Tools/reverse/original_map_probe.py fetch --output .local/sta11a-maps/fetch-a --errno-baseline 0
$P Tools/reverse/export_map_scene.py export --bundle .local/reverse/source/abdata/studio/map/bushitu.unity3d \
  --scene bushitu --map-no 33 --output .local/reverse/exports/maps/33-bushitu
info=(); for f in .local/reverse/source/abdata/studio/info/*.unity3d; do info+=(--info-bundle "$f"); done
$P Tools/reverse/export_map_scene.py catalog "${info[@]}" \
  --converted .local/reverse/exports/maps/33-bushitu --output .local/reverse/exports/maps/catalog.json
$P Tools/reverse/original_map_probe.py capture --output .local/sta11a-maps/phase-b --errno-baseline 0 \
  --showoff '<koikatu_cs0002591.png>'
# Per case, under the app lock: IKKOKU_SOURCE_SCENE=<authored scene> IKKOKU_STUDIO_MAP_CATALOG=<catalog>
# IKKOKU_SOURCE_AVATAR=<rig> IKKOKU_SOURCE_MAP_PROBE=.local/sta11a-maps/ours/<case>
# IKKOKU_AUTOCAPTURE=.local/sta11a-maps/ours/<case>/native-color.png IKKOKU_CAPTURE_W=960 IKKOKU_CAPTURE_H=720
# IKKOKU_CAPTURE_GRID=0 IKKOKU_CAPTURE_GIZMOS=0
$P Tools/reverse/compare_original_map.py --original .local/sta11a-maps/phase-b \
  --case map33 .local/sta11a-maps/ours/map33 --case map33-showoff .local/sta11a-maps/ours/map33-showoff \
  --output .local/sta11a-maps/comparison.json
```

Phase A wrote its copies under `.local/sta11a-maps/fetch-a/source/`. They were then moved to `.local/reverse/source/abdata/`, as `fetch.json` records.

## Performance

Release, on the reference machine, in one quiet window. The full tables are in [performance: ST-A11](../performance.md#st-a11-original-studio-maps).

- **Import.** The map takes 73–83 ms on a GCD worker beside the character builds. On the main thread it costs only the 24 KB catalog read at import and 0.01 ms of placement at the commit.
  - The showoff scene is ready at 1.45 s against 1.47 s without the map.
  - The main thread is busy 674 against 708 ms until then.
  - So no import time is added, in wall time or on the main thread.
- **First draw.** The map draws in the first frame after the import's commit (`sourceSceneReady`). The window's first frame is unchanged at 0.45 s.
- **GPU memory.** Metal grows by 52.5 MB, and the peak footprint by 50–62 MB.
- **Steady state.**
  - `studio-idle`: GPU +0.10 ms per frame. A micro-benchmark puts the map's `refresh()` cost at a few microseconds at most. The 0.08 ms higher `refresh()` p50 in the map runs was those runs' variation.
  - `refresh()` rebuilds the map line only when its inputs change (`SourceMapLineKey`).
  - `studio-orbit-bursts`: the main thread and draw CPU are unchanged.
  - With the room fully in view, offscreen at 1996×1824, the room costs 0.40 ms of GPU per frame alone, and 0.07 ms behind the 7 characters.
- **Base M1 (estimate).**
  - About 0.1 s of worker load;
  - about 1.9 ms of GPU per frame for the room filling the window, and 0.35 ms behind characters;
  - +52 MB of Metal memory.

## What remains

- **Map 34 `空き教室` (`akikyoushitu`), and larger maps generally,** need two separate pieces of work.
  - (1) **Native BC upload in `ResourceStore`.** The converter would keep the bundle's DXT1/DXT5 blocks, and the store would upload them as BC1/BC3 instead of decoding to RGBA8. Base textures: map 33 is 51.7 MB as RGBA8 with mips against 7.2 MB as BC; map 34 is 265.3 MB against 39.8 MB.
  - (2) **The cubemap sky pass.** Map 34 draws its sky with `Skybox/Cubemap` on three meshes: `mo_koi_sky_hiru00`, `mo_koi_sky_yo00` and `mo_koi_sky_yu00`. They use Unity's built-in `Sphere` (`unity default resources` path ID 10207), which is not in the bundle. The converter currently skips skybox-shader submeshes and lists them under `skipped`.

  Map 34 also has 58 merged draws, `Particles/Alpha Blended` materials and a reflection probe. Every other `Map_XX` row stays `file: null` and is reported by name.
- **Baked lightmaps for map 33 (the next slice).** It needs:
  - a second texture binding sampled with UV1, alongside the base texture, in the item material;
  - a decode path for the lightmaps;
  - and their metadata, which `provenance.json` already records.

  The lightmap UVs are already in TEXCOORD_1, with `LightmapPrefab`'s scale/offset baked in: 8 of 8 renderers take theirs from `LightmapPrefab`. Map 33 has one `CombinedDirectional` lightmap pair, both 1024² DXT5 with 11 mips: `Lightmap-0_comp_light` (colour space 1) and `Lightmap-0_comp_dir` (the direction map). UnityPy decodes both.
- **Other lighting.** Map lights, sun-type lighting (the `SunLightInfo` angle, colour, intensity and fog per type), RenderSettings fog and ambient, reflection probes and the dropped `Standard` terms remain.
- **Mods.** Rows that mods add are not evaluated.
- **Character fidelity.** The showoff capture's character differences are the existing character-fidelity work, outside this slice.
