# Original CharaStudio maps (ST-A11, ST-B03, ST-T04)

Reviewed 2026-10-26 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

An imported CharaStudio scene that names an original map now shows that map in the Studio preview, placed the way CharaStudio 1.0.4.2 places it. The first slice converts one map, Map 33 `空き部室` (`bushitu`), at full texture resolution. Every other `Map_XX` row is listed in the catalog with no conversion, and a scene that names one of them says so by name. The map is runtime-only: the native document has no map field, and original export still writes the scene record's map bytes verbatim.

Since the second slice, the preview draws Map 33 with its baked lightmaps. Each surface gets the term Unity 5.6's Standard shader computes for a lightmapped draw: the albedo times the decoded directional lightmap, plus emission. The decode runs in the shader on the bundle's own lightmap blocks (see [baked lightmaps](#baked-lightmaps-slice-2)). The status line names what is still left out, word for word:

`baked lightmaps; approximated: no realtime sun or its shadows, no specular or reflections, no normal, metallic or detail maps, no fog, no camera effects`

A converted map without lightmaps (a first-slice export) still draws with the item toon material under the scene light. It keeps the first slice's label, `approximated: no baked lightmaps, map lights, sun-type lighting, fog or ambient`.

The third slice adds Map 34 `空き教室` (`akikyoushitu`). It draws with its lightmaps, its cubemap sky for the scene's sun type and its particle trees. Its light-probe-lit parts are drawn as items, and the label says so. Every converted map's DXT1/DXT5 textures now upload as BC blocks, which cuts Map 34's texture memory from 288 MB to 60 MB. Map textures are sampled the way the player samples them, with its forced anisotropy. See [map 34, the sky and block images](#map-34-the-sky-and-block-images-slice-3).

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
  - **Slice 3.** Each DXT1/DXT5 base or emission image is also written as its blocks, listed in `ikkokuBlockImages` (see [block images](#block-images)). `Skybox/Cubemap` renderers become sky meshes with `ikkokuSkybox` extras and their cubes. This needs `--builtin-resources` for the built-in `Sphere` (see [the sky](#the-sky)). `Particles/Alpha Blended` materials carry `ikkokuParticle`. `provenance.json` adds `builtinResources`, `blockImages`, `cubes`, `sky` and `lightmapCoverage` (lightmapped against probe-lit `Standard` renderers). The catalog row lists `light probes (<n> Standard renderers without a lightmap drawn as items)` when a map has them.
  - `_MainTex_ST` is baked into UV0. TEXCOORD_1 holds the lightmap UV: mesh UV1 (else UV0) × `lightmapScaleOffset`, using the `LightmapPrefab` value where it names the renderer, then V flipped like UV0.
  - **Lightmaps (slice 2).** Each `LightmapSettings` entry's light map and CombinedDirectional direction map are written as `lightmap-<index>-light.bc3` and `lightmap-<index>-dir.bc3`. Each file is the texture's serialized `image_data`, byte for byte: DXT5 blocks (BC3), all 11 mip levels largest first, rows bottom-up as in Unity's texture memory. Nothing is decoded or re-encoded, so each file's SHA-256 is the serialized data's. The glTF's top-level `ikkokuLightmaps` extras (`kind: ikkoku.unityLightmaps`, version 1) name the files with their format, size, mips, colour space (`m_ColorSpace` 1 is sRGB), byte count and SHA-256. They also record the lightmaps mode (`CombinedDirectional`), the encoding (`m_LightmapFormat` 2, RGBM), the row order and the player's colour space (Linear). The converter records any lightmap it cannot reproduce in `provenance.json`'s `lightmapExport.problems`, and then writes no `ikkokuLightmaps`, so the map draws with the item material and the first slice's label. That covers a lightmaps mode other than NonDirectional or CombinedDirectional, an encoding other than RGBM, a format that is not DXT1/DXT5, a byte count that does not match, or a shadow mask.
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
| Converted map 34 | `33-bushitu/`'s sibling `34-akikyoushitu/`: 61 meshes, 56 materials, 54 PNGs with their 54 BC files, 4 lightmap files, 3 sky cubes; 27,530 vertices, 26,355 triangles. It is in the slice-3 export, private until it is installed (see [installing the slice-3 export](#installing-the-slice-3-export)): `.local/sta11c-map34/exports/maps/` |
| Catalog | `.local/reverse/exports/maps/catalog.json`: 42 rows (0–41) from 23 info bundles; 33 converted, and 34 too in the slice-3 export |
| Source bundles | `.local/reverse/source/abdata/` (`studio/map/bushitu.unity3d`, `studio/map/akikyoushitu.unity3d`, `studio/info/*.unity3d`, `abdata`), each with a `.provenance.json`. To save disk space, `akikyoushitu.unity3d` (26.9 MB, used only for Map 34's inventory) is a symlink into the external archive (`/Volumes/My Book/ikkoku-archive/local/sta11a-maps/`), with the same SHA-256 |
| Authored scenes | `.local/reverse/studio-scenes/maps/scene-map33.png` and `scene-map33-showoff.png`, with `provenance.json`. Map 34's four scenes are in `.local/sta11c-map34/phase-map34/` (`scene-map34-{day,evening,night,showoff}.png`) |

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
- **Textures.** Since slice 3, an image listed in `ikkokuBlockImages` uploads its BC blocks on the worker (see [block images](#block-images)), and the rest load through `ResourceStore` as before. Textures are registered privately (`cacheNew: false`). `release()` retires meshes and textures through `ResourceStore.retire(meshes:)` and the new `retire(textures:)`, so a frame already in flight keeps them until a later frame is prepared. Slice 2's lightmaps and emission maps are owned and released the same way. A load that fails part-way unregisters everything it registered.
- **Lightmapped parts (slice 2).** `SourceStudioLightmapSet.parse` reads the glTF's `ikkokuLightmaps` extras. An export without them gives nil, and every part keeps the item material. A part whose mesh has a lightmap index of 0 or more, and whose material has `ikkokuStandard` extras, is drawn with the map material (`MaterialKindMap`, see [the material](#the-map-material)). The load fails by name, and registers nothing, when such a part names a lightmap the map does not carry or has no TEXCOORD_1, or when a lightmap file's size or SHA-256 differs from the extras.
- **Placement.** `SourceStudioMapPlacement.mapRootMatrix` computes `T(pos) · R(UnityCoordinates.eulerDegrees(rot))` in the engine basis, which is B · M_unity · B with B = diag(1, 1, -1, 1). A non-finite component is refused by name. `mapRoot` parts are drawn at `root × local`, and `scene` parts at their authored matrix.
- **Timing.** Each placement sets the `sourceMapReady` startup mark (the perf report keeps the first) and prints `[ikkoku] source map: <draws> draws (<n> lightmapped, <n> particle, <n> sky), <triangles> triangles, <bytes> texture bytes (<bytes> in <n> lightmaps, <bytes> in <n> sky cubes; images: <n> as BC blocks, <n> decoded, source <blocks|decoded>); loaded in <ms> on a worker, placed in <ms> on the main thread`. The scenario census has the same fields. An import's load usually ends before the import commits, so the map is placed at the commit.
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
- `native-map-depth-normals.png`: Unity's depth-normals encoding over a 25 m far plane (1000 m for map 34), `AppState.sourceMapProbeDepthFar(map:)`;
- `native-map.json`: the census, the camera matrices, the map root and every draw's model matrix, in the engine basis, column-major;
- for a lightmapped map (slice 2), `native-map-irradiance-<variant>.rgba16f.deflate`: the map drawn with `SourceStudioMapMaterial.irradiance`, read from the HDR scene target (`Renderer.captureSceneHDR`, after the MSAA resolve and before bloom, grading and the sRGB composite) as RGBA float16, rows top-down, raw DEFLATE. The variants are `decoded`, `nonDirectional` and `gammaConstants` (see [the irradiance gate](#the-irradiance-gate)). `native-map.json` lists them under `irradiance`.

- since slice 3, only the map's solid draws in the images above (item and lightmapped draws without alpha test or blending, `AppState.isSolidSourceMapDraw`), and each sky and particle group alone over transparent black with its controls (see [evidence](#evidence-the-map-34-phase)). No probe image draws the editor grid.

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

## Baked lightmaps (slice 2)

Map 33 now draws with its baked lightmaps, the way Unity 5.6's Standard shader lights a lightmapped surface. The bundle and the original player are both Unity 5.6.2f1: UnityPy reads the bundle's version, and the player reported its own in phase C. The citations below are the built-in shader sources at tag `v5.6.2f1` of `chsxf/unity-built-in-shaders`.

### Recovered formula

Map 33's 8 renderers draw with `Standard` in `ForwardBase`, with `LIGHTMAP_ON` and `DIRLIGHTMAP_COMBINED` in a Linear-colour-space player. `LightmapSettings` holds one `CombinedDirectional` pair, `Lightmap-0_comp_light` and `Lightmap-0_comp_dir`, both 1024² DXT5 with 11 mips. `m_LightmapFormat` 2 is RGBM. The sun, `Map/SunLight`, is realtime (`m_Lightmapping` 4), so `LIGHTMAP_SHADOW_MIXING` does not apply.

- **The combine.**
  - `fragForwardBaseInternal` (`UnityStandardCore.cginc` L407–L425) gives `c = UNITY_BRDF_PBS(diffColor, specColor, oneMinusReflectivity, smoothness, normal, eye, light, gi.indirect) + Emission(uv)`.
  - `BRDF1_Unity_PBS` (`UnityStandardBRDF.cginc` L304–L306) gives `diffColor * (gi.diffuse + light.color * diffuseTerm)` plus the two specular terms.
- **The baked term.** `UnityGI_Base` (`UnityGlobalIllumination.cginc` L88–L148) gives `gi.diffuse = DecodeDirectionalLightmap(DecodeLightmap(unity_Lightmap), unity_LightmapInd, normalWorld) * occlusion`.
  - With `LIGHTMAP_ON` no SH ambient is sampled (`UNITY_SHOULD_SAMPLE_SH`, `UnityCG.cginc` L49), so RenderSettings ambient never reaches a lightmapped draw.
  - Occlusion is 1: no map 33 material has an `_OcclusionMap`.
- **RGBM decode.** `DecodeLightmapRGBM` (`UnityCG.cginc` L517–L529), in its Linear branch, gives `unity_Lightmap_HDR.x * pow(data.a, unity_Lightmap_HDR.y) * data.rgb`. Its data comes from the sRGB light map, whose RGB the sampler has already linearized.
  - In Linear, `unity_Lightmap_HDR` is (`GammaToLinearSpaceExact(5)`, 2.2) = (34.4932, 2.2).
  - The original player reported `unity_Lightmap_HDR` = (34.4932442, 2.2, 0, 1) in both phase-C cases.
- **Directional term.** `DecodeDirectionalLightmap` (`UnityCG.cginc` L570–L582) gives `color * (dot(normalWorld, dir.xyz - 0.5) + 0.5) / max(1e-4, dir.w)`. Here `dir` is the linear direction map's texel.
- **Diffuse colour.**
  - `DiffuseAndSpecularFromMetallic` (`UnityStandardUtils.cginc` L35–L51) gives `diffColor = albedo * oneMinusReflectivity`.
  - `OneMinusReflectivityFromMetallic(m)` is `(1 - m) * unity_ColorSpaceDielectricSpec.a`, where `.a` is `1 - 0.04` in Linear (`UnityCG.cginc` L27).
  - `MetallicGloss` (`UnityStandardInput.cginc` L153–L164) reads `metallic` from `_MetallicGlossMap.r` under `_METALLICGLOSSMAP`, else from `_Metallic`.
  - The albedo is `_MainTex * _Color`, with `_Color` linearized by `GammaToLinearSpaceExact` (`UnityCG.cginc` L88–L96).
- **Emission.** `Emission` (`UnityStandardInput.cginc` L176–L183) gives `tex2D(_EmissionMap, uv).rgb * _EmissionColor.rgb` under `_EMISSION`.

The slice draws **`diffColor * gi.diffuse + Emission`**: the decoded directional lightmap with the albedo and emission. It leaves out the rest:

| Term | Status |
| --- | --- |
| `light.color * diffuseTerm`: the realtime sun and its shadows | not drawn. The oracle measures it below (`irradianceLit`) |
| both specular terms and the reflection probe | not drawn |
| `_BumpMap` (normal maps) | not drawn: the directional term uses the geometric normal |
| per-texel `_MetallicGlossMap` | approximated by the texture's mean red channel (one material, `doa00`) |
| detail maps (`_DETAIL_MULX2` on `glass00`, which has no detail texture) | not drawn |
| RenderSettings fog | not drawn. It was off at runtime in both phase-C scenes (`RenderSettings.fog` false), so it took nothing from these two captures |
| camera image effects | not drawn |
| RenderSettings ambient | not missing: a lightmapped Standard draw samples no SH |

### The map material

`MaterialKindMap` (8) selects `map_fragment` in `Shaders/Toon.metal`, with its own opaque and blended pipelines (`Pipelines.map`, `mapBlend`). It is sampled with the same `toon_vertex`. The fragment does the following:

- It computes the albedo as `baseColor × _MainTex` (UV0), with the item path's alpha test and blend flags.
- It samples the light map and direction map at `(u, 1 − v)` of TEXCOORD_1. The files keep Unity's bottom-up rows, while TEXCOORD_1 has the glTF top-left origin.
- It decodes RGBM with `lightmapRange` and `lightmapExponent`.
- Under `MaterialFlagMapDirectionalLightmap`, it applies the directional term with `normalize(worldNormal)`. The direction was baked in Unity's left-handed world. The engine basis reflects Z, so the direction's z is negated.
- It writes `albedo × oneMinusReflectivity × gi`, plus emission when `emissive.a > 0`.

The three uniforms `lightmapRange`, `lightmapExponent` and `oneMinusReflectivity` sit in what was `MaterialUniforms`' tail padding (offsets 340, 344 and 348). The stride stays 352: a `static_assert` in `ShaderTypes.h` and an Engine test pin it. Every other material kind leaves them zero. The main pass binds the lightmap, the direction map and the emission map at texture indices 16–18, for map draws only. A missing lightmap binds black; a missing emission map binds white, Unity's `_EmissionMap` default. Each map draw costs three texture bindings more than an item draw. Nothing is allocated per frame.

**Upload.** `SourceStudioBlockTexture.make` uploads the light map as `.bc3_rgba_srgb` and the direction map as `.bc3_rgba` into a shared-storage texture, one `replace` per mip level. `ResourceStore` is unchanged: the asset registers the finished texture with `register(texture:)`. The upload refuses:

- a byte count that does not match the size, format and mips;
- more mip levels than the size allows;
- a device without BC sampling.

The two lightmaps take 2,818,048 bytes of Metal memory. Decoded to RGBA8 with mips, they would take about 11.2 MB.

**Sampler.** Slice 2 sampled the lightmaps with linear filtering, linear mips and clamp to edge. Under the player's `QualitySettings.anisotropicFiltering` ForceEnable, the original samples them with anisotropy 9. Map 34's irradiance gate measured the difference on surfaces seen edge-on, and slice 3 samples every map texture the original's way (see [sampler state](#sampler-state)).

Slice 2 left the base textures to `ResourceStore`, decoded to RGBA8. Slice 3 uploads them as BC blocks (see [block images](#block-images)).

### Evidence (phase C)

**The oracle.** Phase C (`original_map_probe.py oracle`, `OriginalMapProbe.cs`'s oracle mode) ran in the isolated player copy under the same hygiene as phases A and B. That means one `prlctl exec`, an errno-24 count of 0 before and after, nothing written under `C:\Illusion\Koikatsu`, the private root removed and no game process left. The probe reloaded both phase-B scenes through `Studio.LoadSceneCoroutine`. For each scene it then:

- **rendered a clean colour frame** with `Camera.main`'s settings but without its image-effect components (`oracle-<case>-clean-color.png`);
- **rendered Unity's own decoded lightmap** per pixel. It replaced the map renderers' materials with copies of a keyword-free `Standard` map material (`mm_koi_stu_map49_meta00`) with metallic 0 and smoothness 0, and set every light to intensity 0. It rendered them into a linear `ARGBFloat` target, once with a white and once with a black `_Color` and `_MainTex`. White minus black, over 0.96, is `gi.indirect.diffuse`: the black render cancels emission and anything else albedo-independent. The probe rendered that image twice. The repeat differed by 0 in both scenes;
- **rendered the same image with the lights at their authored intensities** (`irradianceLit`), which measures the realtime sun this slice leaves out;
- **recorded** `unity_Lightmap_HDR`, the colour space, the lightmaps mode, each lightmap texture's filter, anisotropy, wrap and format, the lights and the runtime RenderSettings.

Float images are stored gzipped. `run.json` records each one's raw SHA-256.

#### The irradiance gate

`compare_original_map.py --oracle` adds a gated `irradiance` metric for a capture with lightmapped draws. It compares our `native-map-irradiance-decoded` image with Unity's `gi.indirect.diffuse`.

- **Pixels.** Interior pixels only: both silhouettes cover them, and their 3×3 neighbourhood lies on one smooth surface of the original's depth-normals (depth steps of at most 2% of the depth, normal steps of at most 6 bytes). The image border is excluded. This leaves out the MSAA-resolved edges, where a pixel mixes two surfaces.
- **Error.** Per pixel, the largest channel's |ours − Unity| / Unity.
- **Tolerance.** This is a new gate; no existing gate changed. The mean must be at most 2⁻¹⁰ (9.8e-4) and the p99 at most 2⁻⁹ (2.0e-3). The bounds come from the controls:
  - the oracle's repeat render differed by 0;
  - the Engine test puts the GPU decode within 1e-4 of the cited formula;
  - what remains is our float16 HDR target, whose 10-bit mantissa makes one storage step at most 2⁻¹⁰ relative.

  So the gate allows one float16 step on average and two at p99.
- **Conditions.** The oracle's repeat must have differed by 0. Two negative controls, drawn by the same probe, must fail the same gate:
  - `nonDirectional`: the direction map ignored;
  - `gammaConstants`: RGBM decoded with the gamma-space constants (range 5, exponent 1).

Results, Release build of this change (`.local/sta11b-lightmaps/comparison.json`). These images still drew the editor grid. Slice 3 removed it and reran the gate, and no number moved by more than 5e-6 (see [map 33 again](#evidence-the-map-34-phase)):

| Case | Interior pixels | Mean | p99 | `nonDirectional` mean / p99 | `gammaConstants` mean / p99 | Gate |
| --- | ---: | ---: | ---: | --- | --- | --- |
| map33 | 675,369 of 691,200 | 5.9e-4 | 9.3e-4 | 0.049 / 0.157 | 0.318 / 0.381 | pass; both controls fail |
| map33-showoff | 680,813 of 691,200 | 4.9e-4 | 9.1e-4 | 0.0030 / 0.012 | 0.302 / 0.371 | pass; both controls fail |

Unity's mean irradiance over those pixels is 1.742 in map33 and 1.725 in the showoff view; ours is 1.741 and 1.724. The largest single-pixel error is 0.37 in map33, on a few pixels the interior mask keeps, and 0.0036 in the showoff. `nonDirectional` fails the showoff view by a smaller margin than map33 (p99 0.012 against 0.157). Both controls still fail it on the mean and the p99.

Every slice-1 gate passes unchanged on the new captures: record, rule, placement, camera, silhouette IoU, depth and normals (`comparison.json`).

#### Colour before and after

Colour is still reported, not gated: the realtime sun and the camera effects are missing. Mean absolute error and p99, in channel bytes, of our `native-color.png` against two original frames. One is the phase-B frame with `Camera.main`'s image effects; the other is the phase-C clean frame without them. Before is the first slice's capture (`.local/sta11a-maps/ours/`); after is this change's Release capture (`.local/sta11b-lightmaps/ours/`).

| Case | Against | Before MAE (p99) | After MAE (p99) |
| --- | --- | --- | --- |
| map33 (map only) | original with effects | 27.4 (76) | **13.7 (48)** |
| map33 (map only) | clean original | 37.6 (70) | **9.7 (31)** |
| map33-showoff | original with effects | 58.3 (193) | 64.0 (193) |
| map33-showoff | clean original | 46.6 (147) | 52.3 (149) |

- **map33 (map only).** The error halves against the original with its effects, and falls to a quarter against the clean frame. The rest is the realtime sun, specular, the normal maps and the camera effects.
- **Showoff.** The error rises, and the rise does not measure the map:
  - In the original's showoff frame, the room is hidden behind the scene's own props, a light backdrop around the characters.
  - Our probe capture, like the first slice's, runs without the item catalog. It draws the room there, along with the source avatar's characters.
  - On the 236,140 pixels where the lightmaps changed our capture, the original shows that backdrop (mean RGB 214, 207, 212). The lit room (132, 136, 146) is darker than the unlit one (157, 155, 158), so it is further from the backdrop: 65.2 → 81.9 against the frame with effects. The other 455,060 pixels are unchanged (54.8).
  - With the props drawn (the item catalog supplied), the map changes no pixel of the showoff capture, on base or branch.
  - The map's own correctness in that view is the irradiance gate above.

The realtime sun this slice leaves out adds light to 15,692 of map33's 691,200 pixels by more than 1% (by up to 0.70, a mean of 0.010 over the frame), where the sun comes through the windows. It adds nothing in the showoff frame.

#### Tests and checks

- **Engine.** `SourceStudioMapLightmapTests.swift`:
  - `materialUniformsKeepTheirStrideWithTheMapFloatsInTheTail`: stride and size 352, the three offsets, and zero map floats for every other kind's `make`;
  - `lightmapDecodeFollowsTheCitedFormula`: the CPU decode against values computed by hand from the cited formulas;
  - `blockTextureUploadKeepsEveryMipLevelByteForByte`: a 16×8 BC3 texture with 5 mips of random blocks, sRGB and linear, blitted back to a buffer and compared byte for byte, plus the refusals;
  - `mapFragmentDrawsTheDecodedDirectionalLightmapTimesDiffColorPlusEmission`: `toon_vertex` + `map_fragment` compiled from source, drawing a two-block light map. It checks the V flip, the directional term on both sides of the direction, emission and the three irradiance variants against the CPU formula within 1e-4;
  - `lightmapRecordsParseAndRefuseWhatTheyDoNotReproduce`;
  - the `SourceStudioLightmappedMapTests` suite: a converted fixture loads with its lightmapped parts, textures and label; a changed lightmap hash or a missing TEXCOORD_1 fails the load and leaves nothing registered.
- **Python.**
  - `test_export_map_scene.py`: Standard inputs, lightmap files and extras, the lightmapped dropped terms, the label lists;
  - `test_compare_original_map.py`: the irradiance gate and both controls on synthetic images;
  - `test_original_map_probe.py`: the oracle subcommand.
- **Scenarios.** The three source-map scenarios assert the lightmapped label and `lightmappedDraws: 8`.

**Byte-identical captures.** Release builds of `main` (`b4c59e7`) and this change were run under the app lock, one launch per capture (`.local/sta11b-lightmaps/captures/{base-old,base-new,branch,branch-old}/captures.json`).

- **No-map captures, base against branch:** identical with the live source-shader opt-in OFF and ON. That covers:
  - the no-map scenario scene with the catalog supplied;
  - the half-state fixture;
  - the native Studio capture;
  - the map scene without a catalog;
  - the showoff scene without props.

  The live opt-in's reports are identical too.
- **The showoff scene with props:** identical OFF and ON, because its props hide the room.
- **Map captures with the room in view:** they change only with the slice-2 export, as intended. `scene-map33.png` and the showoff scene without props differ from base, and identically OFF and ON for map33.
- **This change with the first slice's export:** byte-identical to `main` on all 6 map captures. Its fallback path, the item material when an export has no lightmaps, is unchanged.
- **After merging `main` (`3bfcc37`, #280):** all 14 captures were rerun on Release builds of both heads (`captures/merged-{base,branch,branch-old}/`). Every no-map capture and both showoff-with-props captures are identical to `3bfcc37`, OFF and ON. Each map capture is identical to this change's capture before the merge. With the first slice's export, this change still matches `main` on all 6 map captures. `3bfcc37` itself draws all 14 captures exactly as `b4c59e7` did.
- **After merging `main` `0e6181a` (#281, #282):** the same 34 captures on new Release builds (`captures/m0e6-*`) give the same results, and every capture's hash is unchanged from the `3bfcc37` run on both sides.

**Safe for `main` after the swap.** `main`'s binary with the slice-2 export is byte-identical to `main` with the first slice's export on all 6 map captures. Its log reports the same 52,248,576 texture bytes. `main`'s four map checks (`source-map`, `reload-save-source-map`, `reload-load-source-map`, `source-map-none`) passed 4/4 under `--strict` on its Debug build with the slice-2 export (`.local/sta11b-lightmaps/swap-proof/`). The one visible difference: `main`'s status line loses its `; shaders approximated (Standard)` suffix, because the new catalog row names the omitted terms instead. `main`'s checks assert the label prefix, which is unchanged.

**Suites and lanes.**

- **Engine, private source.** On the head merged with `main` `0e6181a` (#281, #282), the suite ran 1,017 tests: 996 passed, 21 were skipped and none failed. The environment was the shared 98-key file with the slice-2 map. `liveSourceShadersMeetTheControlledOriginalFrameGates`, which failed before #282 supplied its inputs, now passes. On the earlier merges (`3bfcc37`, and before it `b4c59e7`), that test was the suite's only failure.
- **Python.** `Tools/reverse` 589 (6 skipped), `Tools/reverse/analysis` 279 and `Tools/verification` 199 pass.
- **Lanes.** On the heads merged with `3bfcc37` and with `0e6181a`, with the slice-2 export and `--strict`, `studio-scenarios` passed 78 of 78, including the four map checks, and `maker-scenarios` passed 10 of 10 (`.local/sta11b-lightmaps/lanes/`).
- **CI** passed on the PR.

### Installing the slice-2 export

The shared fixture (`.local/reverse/exports/maps/`) keeps the first slice's export until this change merges. Other branches compare captures against it, and replacing it in place mid-run could tear a read. The slice-2 export is built privately in `.local/sta11b-lightmaps/exports/maps/`. Its file hashes are in `.local/sta11b-lightmaps/new-export.sha256`, and the old export's are in `old-export.sha256`. Both trees are on the same volume, so every `mv` below is an atomic rename.

Install it from the main checkout, with no app run or lane using the map:

```sh
cd /Users/rumpology/code/repo/ikkoku
M=$PWD/.local/reverse/exports/maps            # the shared fixture (environment.json names $M/catalog.json)
N=$PWD/.local/sta11b-lightmaps/exports/maps   # the slice-2 export
B=$PWD/.local/sta11b-lightmaps/old-export     # the backup of the first slice's export
H=$PWD/.local/sta11b-lightmaps               # the two hash manifests
# 0. Both trees are what the manifests say.
(cd "$M" && shasum -a 256 -c "$H/old-export.sha256")
(cd "$N" && shasum -a 256 -c "$H/new-export.sha256")
# 1. Stage the new export beside the shared one.
mv "$N/33-bushitu" "$M/33-bushitu.sta11b" && mv "$N/catalog.json" "$M/catalog.json.sta11b"
# 2. Back up the old export and put the new one in its place.
mkdir -p "$B"
mv "$M/33-bushitu" "$B/33-bushitu" && mv "$M/33-bushitu.sta11b" "$M/33-bushitu"
mv "$M/catalog.json" "$B/catalog.json" && mv "$M/catalog.json.sta11b" "$M/catalog.json"
# 3. Check the result.
(cd "$M" && shasum -a 256 -c "$H/new-export.sha256")
(cd "$B" && shasum -a 256 -c "$H/old-export.sha256")
rmdir "$N" "$H/exports"
```

To roll back, swap the two the same way:

```sh
mv "$M/33-bushitu" "$M/33-bushitu.sta11b" && mv "$B/33-bushitu" "$M/33-bushitu"
mv "$M/catalog.json" "$M/catalog.json.sta11b" && mv "$B/catalog.json" "$M/catalog.json"
```

**Safe for branches still on `main`.** `main`'s binary (`b4c59e7`) ignores everything the new export adds:

- the lightmap files;
- the `ikkokuLightmaps` and `ikkokuStandard` extras;
- the emission image, which no `baseColorTexture` names;
- the catalog row's new `approximations`.

The renamed PNGs keep their bytes, and `bushitu.bin` is unchanged. Rendered by `main`'s binary, the six map captures are byte-identical on both exports, and `main`'s map checks pass on the new one (see [tests and checks](#tests-and-checks)).

**Storage.** The shared export grows from 3.0 MB to 6.6 MB (+3.6 MB). The backup holds the old 3.0 MB. The private copy is moved, not duplicated.

## Map 34, the sky and block images (slice 3)

Slice 3 converts Map 34 `空き教室` (`akikyoushitu`). It draws the map's lightmaps, its `Skybox/Cubemap` sky and its `Particles/Alpha Blended` trees. It also uploads every converted map's DXT1/DXT5 textures as BC blocks instead of RGBA8. The citations are the same `v5.6.2f1` built-in shader sources as slice 2.

### What map 34 draws

The conversion has 61 merged draws and 26,355 triangles, plus 768 for each of the three sky spheres. The status line counts all of them:

`Map 34 空き教室 (akikyoushitu): baked lightmaps on 30 of 57 draws (the rest as items), cubemap sky, particles (no soft-particle fade or per-renderer sorting); approximated: no realtime sun or its shadows, no specular or reflections, no normal, metallic or detail maps, no fog, no camera effects · 28659 triangles, 61 draws`

| Part | Bundle | Drawn as |
| --- | --- | --- |
| Lightmapped `Standard` | 37 renderers, 8,536 triangles, two CombinedDirectional pairs (lightmaps 0 and 1, RGBM, DXT5) | 30 draws with `MaterialKindMap`, as in slice 2 |
| `Standard` without a lightmap | 32 renderers, 17,701 triangles. Unity lights them with light probes and the realtime sun | 27 draws with the item toon material. The catalog lists `light probes (32 Standard renderers without a lightmap drawn as items)` |
| `Particles/Alpha Blended` | 2 renderers (`mo_koi_map09_sotokabe00_ha00`, `_ha01`), one material (`mm_koi_map02_eda01`) | 1 draw, see [particles](#particles) |
| `Skybox/Cubemap` | 3 spheres: `mo_koi_sky_hiru00` (day, and -1), `_yu00` (evening, `_Rotation` 291), `_yo00` (night) | the sky draw for the sun type, see [the sky](#the-sky) |
| Reflection probe | 1 | not drawn (specular and reflections are in the label) |

The sun type selects what is visible: 54 draws for day, 53 for evening and 50 for night. The main camera in the original clears to black (`clearFlags` Color), so `RenderSettings.skybox` (`Skybox/Procedural`) is never drawn there. The converter skips it.

### Block images

The converter writes each DXT1/DXT5 base or emission texture twice: its PNG (still the glTF image's `uri`) and its serialized blocks (`<n>_<name>.bc1|bc3`, every mip level).

- **Row order.** Unity's blocks are bottom-up and the PNG is top-down. The converter reverses the block rows and each block's four pixel rows. For BC1 and BC3 that is a lossless rearrangement of indices. It checks that level 0 decodes to exactly the PNG's pixels and refuses the image otherwise.
- **BC7.** A BC7 image cannot be row-flipped losslessly, so it would stay PNG-only (`provenance.json`'s `blockImages.pngOnly`). Maps 33 and 34 have none; map 34's BC7 is a sky cube, which is uploaded as stored.
- **Extras.** The glTF's top-level `ikkokuBlockImages` (`kind: ikkoku.unityBlockImages`, version 1, `rows: topDown`) lists, per image index, the file, format, size, mip count, colour space, byte count, the file's SHA-256 and the serialized data's SHA-256. It also lists the sky cubes.

At load, on the map's worker, `SourceStudioBlockImages.parse` reads the extras. `SourceStudioBlockTexture.make` (slice 2's lightmap upload) uploads each listed image as `.bc1_rgba(_srgb)` or `.bc3_rgba(_srgb)`, every level, after checking its size and SHA-256. The asset registers the texture with `register(texture:)` and owns it like the lightmaps. `ResourceStore` is unchanged. An image the extras do not list still loads its PNG through `ResourceStore`, decoded to RGBA8 with blit-generated mips.

`IKKOKU_SOURCE_MAP_DECODED_TEXTURES=1` decodes the PNGs instead of uploading the blocks. It is read once per load and exists only to measure the difference (see the [verification README](../../../Tools/verification/README.md#source-maps-st-a11)). The PNGs stay in the export, so a reader without block support still draws the map.

| Map | Images | Metal texture bytes, RGBA8 (decoded) | Metal texture bytes, BC | Change |
| --- | ---: | ---: | ---: | ---: |
| 33 | 8 | 56,492,032 | 10,207,232 | −46.3 MB |
| 34 | 54 | 288,178,176 | 59,572,224 | −228.6 MB |

Both totals include the lightmaps (2.8 MB and 3.5 MB, BC3 either way). Map 34's also includes the three sky cubes (15.7 MB, uploaded as stored either way).

### The sky

`Skybox-Cubed.shader` (Queue Background, Cull Off, ZWrite Off):

- the vertex is turned by `RotateAroundYInDegrees(v.vertex, _Rotation)` for the clip position;
- the cube is sampled at the unrotated `v.vertex.xyz`;
- the fragment is `DecodeHDR(texCUBE(_Tex, dir), _Tex_HDR) * _Tint.rgb * unity_ColorSpaceDouble.rgb * _Exposure`.

`DecodeHDR` (`UnityCG.cginc` L497–L512) in Linear gives `(x * pow(w * (a − 1) + 1, y)) * rgb`. `unity_ColorSpaceDouble` (`UnityCG.cginc` L26) is 4.59479380 in Linear.

- **Mesh.** The spheres use Unity's built-in `Sphere` (`unity default resources`, path ID 10207), which is not in the map bundle. The converter reads it from the player's own file with `--builtin-resources` (`.local/reverse/original-character-probe/source/CharaStudio_Data/Resources/unity default resources`, SHA-256 `0e611340…2812`). Each sky renderer becomes its own mesh in object space (Z reflected), under a node that carries the renderer's matrix.
- **Material.** The material is `BLEND` with a zero base colour, so a reader that does not know the sky draws nothing. Its `ikkokuSkybox` extras (`kind: ikkoku.unitySkyboxCubemap`, version 1) give the cube index, `_Tint` and `_Exposure` as a Linear player uploads them, `_Rotation`, `unity_ColorSpaceDouble` and `_Tex_HDR`.
- **Cubes.** Each cube's six faces are written as serialized (`cube-<k>-<name>.bc1|bc3|bc7`), in D3D face order (+X, −X, +Y, −Y, +Z, −Z). Metal samples that order and those rows as D3D does. The converter checks the orientation by the face seams: for `mt_koi_sky_hiru00` the mean seam error is 0.0235 as stored and 18.6 with the rows flipped. Map 34's cubes are 1024² with one level each: `hiru00` and `yu00` are BC7, `yo00` is BC1.
- **Draw.** `MaterialKindSky` draws `sky_vertex` / `sky_fragment` (`Shaders/Toon.metal`) with its own pipeline, in the main pass's `Sky` group. That group comes right after the background, with no depth test or write and no culling. It is the Background queue with ZWrite Off: the room drawn after it covers it. The sky is never a shadow caster, pick occluder or live-shader draw. `bindTextures` binds only the cube (index 19) for a sky draw. `prepare` drops a sky draw whose cube does not resolve. The depth-only and stencil pipeline sets carry the same groups, and an Engine test checks that. `MaterialUniforms` stays 352 bytes: the sky reuses `baseColor` (the scale) and `params` (rotation and decode).

The original's main camera has a far plane of 1000 m, and the spheres reach about 450–1,200 m. So the player clips the far side of its own sky in some directions, while our infinite reverse-Z projection draws all of it. The sky gate compares the sky alone at a far plane of 10,000 m on both sides. The clipped part is a colour difference of the full frame, reported under [what remains](#what-remains).

### Particles

`Particle Alpha Blend.shader`: `o.color = v.color * _TintColor`, `col = 2 * i.color * tex2D(_MainTex)`, `Blend SrcAlpha OneMinusSrcAlpha`, `ColorMask RGB`, Cull Off, ZWrite Off, no lighting.

The converter's `ikkokuParticle` extras give `_TintColor` linearized as a Linear player uploads it. The draw is `MaterialKindMap` with `MaterialFlagMapParticle`. The `map_fragment` particle branch returns `2 × vertex colour × tint × texture`, alpha included, both faces, in the transparent pass. It reads no lightmap.

Not drawn:

- soft particles (on in the player's quality settings; the fade near geometry is dropped);
- fog;
- per-renderer sorting. The two renderers are merged into one draw, so their triangles keep the mesh's order.

### Sampler state

The player runs `QualitySettings.anisotropicFiltering` `ForceEnable`. The phase-map34 trace (`.local/sta11c-map34/phase-map34/map-trace.json`) records it in every case's `capture.quality` and `oracle.quality`, beside the lightmaps' `anisoLevel` 3 and the sky and particle textures' 1. Every mipmapped texture that is not point-filtered is then sampled with anisotropy clamped into Unity's forced limits, [9, 16]. No game assembly calls `Texture.SetGlobalAnisotropicFilteringLimits` or sets the quality value: only `UnityEngine.dll` names them. So the lightmaps' `anisoLevel` 3 and the particle and base textures' 1 are raised to 9. D3D11 samples an anisotropic texture with linear mips.

`map_fragment` now samples the light map, direction map, base, emission and particle textures with anisotropy 9 and linear mips (`lightmapSampler`, `mapForcedAnisoRepeat`). Character and item draws keep `linearRepeat`.

The probe gates found it. With trilinear sampling, map 34's irradiance failed on surfaces seen edge-on (baseboards, shelf boards), and the particles failed outright. A sampler sweep, with one rebuild and the four captures per state (`.local/sta11c-map34/exp/<state>/comparison.json`):

| Lightmap sampler | Irradiance p99, day / evening / night / showoff | Pixels over 2⁻⁹, day |
| --- | --- | ---: |
| linear, linear mips, no anisotropy (slice 2) | 0.0023 / 0.0009 / 0.0018 / 0.0036 | 5,513 |
| linear, nearest mip (Unity's `Bilinear` without anisotropy) | 0.0008 / 0.0008 / 0.0008 / 0.0036 | 4,248 |
| anisotropy 3 | 0.0008 / 0.0008 / 0.0008 / 0.0008 | 2,026 |
| anisotropy 9 | 0.0008 / 0.0008 / 0.0008 / 0.0008 | 2,026 |
| anisotropy 16 | identical to 9 on every pixel | 2,026 |

The oracle separates anisotropy from none, but not 3 from 9: they differ on 10–161 compared pixels per case. The value 9 follows from the recovered quality state and Unity's clamp. The particle texture alone, with the lightmaps at 9, moved the particles from mean 0.030 / p99 0.21 (no anisotropy) to 0.0011 / 0.0040. An Engine test pins the sampler by behaviour, not by text (see [tests](#tests-slice-3)).

### Evidence (the map 34 phase)

**One VM phase** (`original_map_probe.py map34`, `OriginalMapProbe.cs`'s map 34 mode) ran under main's grant, with one `prlctl exec` for the phase. Hygiene:

- the errno-24 count was 0 before and after;
- nothing was written under `C:\Illusion\Koikatsu`;
- the isolated root, with `-logFile` inside it, was removed, and no game process was left;
- the junction targets were scanned before and after, with identical results: `abdata` 4,565 files, 443 directories, 16,606,991,941 bytes; `CharaStudio_Data` 102 files, 9 directories, 150,249,360 bytes.

The phase's `run.json` records the scans. A separate one-line read-only exec (`powershell -Command "1"`) also ran after the phase, outside the grant. It was reported to main, and errno-24 stayed 0.

In the original player, the probe authored four scenes and reloaded each through `Studio.LoadSceneCoroutine`:

| Case | Sun type (UI path `Map.sunType` → `SunLightInfo.Set`) | Map transform | Camera |
| --- | --- | --- | --- |
| `map34-day` | 0 | pos (0.3, −0.05, −0.5), rot (4, 25, −3), as in `map33` | pivot (0.5, 1.3, 0.2) in the map's frame, pitch −4°, yaw −70°, 2.5 m, fov 45 |
| `map34-evening` | 1 | zero | pivot (0.5, 1.3, −0.8), pitch −6°, yaw −105°, 2.5 m, fov 45 |
| `map34-night` | 2 | zero | pivot (0.3, 1.4, 0.6), pitch −8°, yaw −80°, 2 m, fov 45 |
| `map34-showoff` | 0 | zero (`AddMap`) | `koikatu_cs0002591.png`'s own camera, fov 23 |

For each case it rendered:

- the slice-1 images (colour, silhouette, depth-normals; far plane 1000 m for map 34, because its outside geometry reaches about 800 m);
- the slice-2 oracle (clean colour, irradiance twice, lit irradiance);
- three new images:
  - `classes`: map renderers coloured white for `Standard` with a baked lightmap, red for `Standard` without one, green for any other shader;
  - `sky` and `particles`: each group alone, as linear RGBA float over transparent black at a far plane of 10,000 m.

The map-only images on both sides hold the solid map only: the renderers whose materials are all `RenderType=Opaque`. Sky, particle, cutout and blended renderers are counted, not drawn. Runtime fog was off in all four scenes, and the probe also forces it off for its passes. The images are gzipped (22 MB).

**Our side.** `IKKOKU_SOURCE_MAP_PROBE` now writes the same split:

- solid draws only in the geometry, depth-normals and irradiance images;
- `native-map-sky-<variant>.rgba16f.deflate` (`decoded`, `rowsFlipped`, `rotationIgnored`, `gammaConstants`);
- `native-map-particles-<variant>.rgba16f.deflate` (`decoded`, `noDoubling`, `gammaTint`).

None of these HDR images draws the editor grid any more. Until this change they did (`frame.effects.showGrid` stayed on, because `IKKOKU_CAPTURE_GRID` reaches only the autocapture), and so did slice 2's irradiance images. Map 33's slice-2 numbers below were measured with the grid in the probe image. Its floor hides most of the grid, and the rerun moves no gate.

**Gates on map 34** (BC build, `.local/sta11c-map34/comparison-map34-bc.json`). Every case passes every gate:

| Gate | Tolerance | day | evening | night | showoff |
| --- | --- | --- | --- | --- | --- |
| Record (map, transform, sun type) | 1e-6 | 1.2e-8 | 0 | 0 | 0 |
| `Reflect` rule | 1e-5 m, 1e-3° | 0° | 0° | 0° | 0° |
| Map root; each sky draw against its original renderer (relative) | 1e-5 | 1.4e-7; 1.1e-7 | 0; 2.8e-8 | 0; 2.8e-8 | 0; 1.0e-8 |
| View; fov | 1e-5; 1e-4° | 2.4e-7; 0 | 9.5e-7; 0 | 1.2e-7; 0 | 1.5e-7; 0 |
| Silhouette IoU | ≥ 0.999 | 1.0 | 1.0 | 1.0 | 1.0 |
| Depth p99 (far 1000 m) | ≤ 2 steps | 0 | 0 | 0 | 0 |
| Normal p99 | ≤ 2 bytes | 0 | 0 | 0 | 0 |
| Irradiance mean / p99 (lightmapped class) | 2⁻¹⁰ / 2⁻⁹ | 8.1e-4 / 7.9e-4 | 5.5e-4 / 7.6e-4 | 6.2e-4 / 8.0e-4 | 5.5e-4 / 7.8e-4 |
| Sky mean / p99, coverage IoU | 2⁻¹⁰ / 2⁻⁹, ≥ 0.999 | 5.6e-4 / 8.3e-4, 1.0 | 5.0e-4 / 8.2e-4, 1.0 | 5.7e-4 / 8.5e-4, 1.0 | 5.5e-4 / 8.3e-4, 1.0 |
| Particles mean / p99, footprint IoU | 2⁻⁶ / 2⁻³, ≥ 0.98 | 0.0011 / 0.0040, 0.9996 | 0.0011 / 0.0033, 0.9997 | 0.0011 / 0.0038, 0.9997 | not in view on either side |

Every control fails, as it must:

- **Irradiance.** `nonDirectional` p99 0.073–0.233, `gammaConstants` p99 0.89.
- **Sky.** `rowsFlipped` p99 0.37–1.12, `gammaConstants` p99 0.565. `rotationIgnored` p99 0.129 applies to the evening sky only: the others have `_Rotation` 0, so that control is not applicable there and passes.
- **Particles.** `noDoubling` p99 0.75, `gammaTint` p99 0.285.

The irradiance gate keeps only pixels that Unity draws with a baked lightmap (the `classes` image). The `Standard` parts without a lightmap, which we draw as items, cover:

| Case | Lightmapped pixels | Light-probe-lit pixels (items here) | No solid map renderer |
| --- | ---: | ---: | ---: |
| day | 569,282 | 77,159 (11.2%) | 44,759 |
| evening | 566,873 | 72,567 (10.5%) | 51,760 |
| night | 536,609 | 92,296 (13.4%) | 62,295 |
| showoff | 691,200 | 0 | 0 |

The sky gate uses the irradiance gate's tolerance, for the same reason. Both sides sample the same faces in the same direction (the camera gate holds the matrices), so only our float16 target is left. The particle tolerance was fixed before any map 34 data was compared, allowing for filtering and blend order. With the player's sampler state, the measured error is far inside it. Particles fall outside the gate only when neither side covers a pixel, as in the showoff view.

**Map 33 again**, with the grid removed and the new samplers (`comparison-map33-bc.json`), against slice 2's numbers:

| Case | Slice 2 (grid in the image, trilinear): mean / p99 | Slice 3, BC: mean / p99 | Slice 3, RGBA8: mean / p99 |
| --- | --- | --- | --- |
| map33 | 5.95e-4 / 9.26e-4 | 5.90e-4 / 9.25e-4 | 5.90e-4 / 9.25e-4 |
| map33-showoff | 4.94e-4 / 9.09e-4 | 4.94e-4 / 9.09e-4 | 4.94e-4 / 9.09e-4 |

Every slice-1 and slice-2 gate passes on both texture paths, and the controls fail as before.

**BC against RGBA8 on map 33.** The two texture paths draw map 33 differently on 437,142 of 691,200 pixels of our own colour capture: MAE 0.35 channel bytes, p99 2, at most 7. In the showoff view it is 136,441 pixels, MAE 0.11, p99 2, at most 10. The causes are the mip chains and the decode:

- the BC path samples Unity's own serialized mips;
- the PNG path samples box-filtered mips of level 0, generated by a blit (as MetalKit generated them before 2026-10-26, byte for byte);
- the GPU decodes BC in sRGB in hardware, where the PNG path decodes it on the CPU.

BC is not further from the original. Against the phase-C clean original, map33 is MAE 9.41 (p99 30) with BC and 9.69 (p99 31) with RGBA8; the showoff is 52.26 (p99 149) with BC and 52.36 (p99 149) with RGBA8. So BC is the default and the PNG path is the measurement switch.

With the decoded switch, map 34's particles fail their gate (mean 0.080, p99 0.26), while every other gate passes. The leaf texture's box-filtered mips differ from Unity's by about 8% premultiplied (mean 0.0026 against a mean of 0.031, levels 1–6), and the trees are far away, so the PNG path's mips carry its whole error. The BC path passes.

#### Colour before and after (map 34)

The colour comparison is reported, not gated. MAE in channel bytes against the original with its image effects, then against the phase-map34 clean original:

| Case | RGBA8, trilinear | BC, trilinear | BC, anisotropy 9 (this change) |
| --- | --- | --- | --- |
| day | 42.1 / 14.9 | 42.2 / 14.7 | 42.2 / 14.6 |
| evening | 39.4 / 7.6 | 39.5 / 7.4 | 39.6 / 7.3 |
| night | 39.1 / 6.2 | 39.2 / 6.0 | 39.3 / 5.9 |
| showoff | 73.0 / 61.6 | 72.9 / 61.5 | 72.9 / 61.5 |

Against the clean original, the interior views come within 6–15 bytes. The rest is what the label lists:

- the realtime sun through the windows;
- the probe-lit parts drawn as items (10–13% of those frames);
- specular;
- the sky the player clips at its far plane.

The image effects account for the gap to the frame with effects. The showoff includes the scene's characters.

#### Tests (slice 3)

- **Engine** (`SourceStudioMapSkyTests.swift`):
  - BC images and cubes upload every face and level byte for byte (a blit back to a buffer), with the refusals;
  - every converted map in the private fixture loads its block images byte for byte;
  - the sky shaders draw the cited formula, checked on the CPU within float tolerance, including the rows-flipped and rotation controls;
  - the particle branch draws `2 × vertex colour × tint × texture`;
  - the probe variants change only their own term;
  - **`mapTexturesSampleWithThePlayersForcedAnisotropy`** draws `map_fragment` over a texture footprint of 16 texels by 1 per pixel, on a texture whose levels 0–1 are white and the rest black. Light map, base, emission and particle textures each read 1. Measured on this GPU, `max_anisotropy` 1 to 4 reads 0, so neither the textures' own levels nor trilinear passes;
  - the depth-only and stencil passes carry the same groups;
  - a converted fixture with block images, a sky and particles loads, and the decoded switch decodes the PNGs;
  - a changed or missing cube fails the load and registers nothing.
- **Python:**
  - `test_export_map_scene.py`: row-flipped blocks, cubes, sky and particle extras;
  - `test_compare_original_map.py`: the sky and particle gates and their controls, the class mask, particles out of view;
  - `test_original_map_probe.py`: the map34 subcommand and its scans.
- **Scenarios.** `studio-scenario-source-map34` checks map 34 on the day scene:
  - 54 draws (30 lightmapped, 1 particle, 1 sky), 54 BC images, and the exact label;
  - map points pick nothing;
  - the View toggle;
  - byte-identical exports;
  - reimport, New Scene and undo.

  `studio-scenario-source-map` also asserts map 33's 8 BC images. Both need the slice-3 export and `IKKOKU_STUDIO_MAP34_SCENE` (see [installing](#installing-the-slice-3-export)).

Results on the head merged with `main` `4d60b73` (`.local/sta11c-map34/lanes/`):

- **Engine.** The strict suite passed with the private fixtures and the slice-3 export: 1,036 Swift Testing tests and 21 XCTest tests, 0 failures. The 6 skips are opt-in timing probes. `IKKOKU_APPEARANCE_REFERENCE_ROOT` was set for the run only; it stays out of `environment.json`.
- **Python.** `Tools/reverse` 626 (6 skipped), `Tools/reverse/analysis` and `Tools/verification` 201 pass.
- **Lanes.** On the Debug build of `e7ac998`, with the slice-3 export and `--strict`:
  - `studio-scenarios` passed 79 of 79, including the five map checks;
  - `maker-scenarios` passed 10 of 10.
- **CI** passed on the PR.

#### Captures (slice 3)

Release captures, 16 per set, from `main` (`4d60b73`) and from this change merged with it (`147bd19`; later commits change no code). Each binary ran on the slice-2 export (the shared fixture) and on the slice-3 export: `.local/sta11c-map34/captures/{base-old,base-new,head,head-old}/captures.json`.

- **No map: byte-identical in all four sets**, with the live source-shader opt-in OFF and ON:
  - the scenario scene with the catalog;
  - the half-state fixture;
  - native Studio;
  - the showoff scene without the catalog, and with it (its props hide the room);
  - the showoff scene without props or catalog.

  The four live reports are byte-identical too. Characters and items keep their samplers.
- **`main`'s binary renders map 33 identically on both exports:** the emptied map 33 scene and the showoff scene without props, OFF and ON.
- **This change on the slice-2 export** loads map 33 from its 8 PNGs (`images: 0 as BC blocks, 8 decoded`). A scene naming map 34 draws no map, because that catalog's row has no file.
- **This change against `main`, map 33:**
  - the emptied scene differs by MAE 0.33 of 255 (p99 2, max 21);
  - anisotropy alone (this change on the slice-2 export against `main`) is MAE 0.04 on 5.1% of the pixels;
  - BC against RGBA8 is MAE 0.30;
  - the showoff scene without props differs by MAE 0.11 (p99 2).
- **Map 34.** `main`'s binary on the slice-3 export draws map 34's 54 draws from the decoded PNGs (272,449,536 texture bytes). It has no code for the sky cube or the particle formula. Ours differs from it by MAE 1.8 (p99 40), almost all of it on the alpha-tested trees through the window. Their cutout edges follow the mips (Unity's in the BC blocks against MetalKit's box filter) and the sampler. The [colour table](#colour-before-and-after-map-34) shows ours is the closer of the two to the original.

### Installing the slice-3 export

The shared fixture (`.local/reverse/exports/maps/`) keeps the slice-2 export until this change merges. The slice-3 export is built privately in `.local/sta11c-map34/exports/maps/`. Its 142 file hashes are in `.local/sta11c-map34/new-export.sha256`, and the slice-2 export's 15 are in `old-export.sha256`. Both trees are on the same volume, so every `mv` below is an atomic rename.

Install it from the main checkout, with no app run or lane using the map:

```sh
cd /Users/rumpology/code/repo/ikkoku
M=$PWD/.local/reverse/exports/maps          # the shared fixture (environment.json names $M/catalog.json)
N=$PWD/.local/sta11c-map34/exports/maps     # the slice-3 export
B=$PWD/.local/sta11c-map34/old-export       # the backup of the slice-2 export
H=$PWD/.local/sta11c-map34                  # the two hash manifests
# 0. Both trees are what the manifests say.
(cd "$M" && shasum -a 256 -c "$H/old-export.sha256")
(cd "$N" && shasum -a 256 -c "$H/new-export.sha256")
# 1. Stage the new export beside the shared one. The slice-2 catalog names no file for map 34.
mv "$N/34-akikyoushitu" "$M/34-akikyoushitu"
mv "$N/33-bushitu" "$M/33-bushitu.sta11c" && mv "$N/catalog.json" "$M/catalog.json.sta11c"
# 2. Back up the old export and put the new one in its place.
mkdir -p "$B"
mv "$M/33-bushitu" "$B/33-bushitu" && mv "$M/33-bushitu.sta11c" "$M/33-bushitu"
mv "$M/catalog.json" "$B/catalog.json" && mv "$M/catalog.json.sta11c" "$M/catalog.json"
# 3. Check the result.
(cd "$M" && shasum -a 256 -c "$H/new-export.sha256")
(cd "$B" && shasum -a 256 -c "$H/old-export.sha256")
rmdir "$N" "$H/exports"
# 4. The map 34 scene for studio-scenario-source-map34, beside the map 33 scenes.
cp "$H/phase-map34/scene-map34-day.png" "$PWD/.local/reverse/studio-scenes/maps/scene-map34-day.png"
```

Then add `IKKOKU_STUDIO_MAP34_SCENE` = `.local/reverse/studio-scenes/maps/scene-map34-day.png` (absolute) to `environment.json`.

To roll back, swap the two the same way. `34-akikyoushitu/` can stay, since the slice-2 catalog does not name it:

```sh
mv "$M/33-bushitu" "$M/33-bushitu.sta11c" && mv "$B/33-bushitu" "$M/33-bushitu"
mv "$M/catalog.json" "$M/catalog.json.sta11c" && mv "$B/catalog.json" "$M/catalog.json"
```

**Safe for branches still on `main`.** Map 33's PNGs, `bushitu.bin` and its lightmap files keep their bytes. Its glTF gains the block-image extras, which `main`'s binary ignores. Rendered by `main`'s binary, the map 33 captures are byte-identical on both exports ([captures](#captures-slice-3)). The one change `main` sees is that a scene naming map 34 now draws it, without its sky or particle formula. No `main` scene or lane names map 34.

**Storage.** The shared export grows from 5.7 MB to 88 MB (+82 MB). Map 34 takes 76 MB of that, of which its PNG copies take 17 MB. Map 33 grows from 5.7 to 13 MB with its BC files. The backup holds the old 5.7 MB, and the private copy is moved, not duplicated.

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

Slice 2 (baked lightmaps), Release, in one quiet window ([performance: slice 2](../performance.md#slice-2-baked-lightmaps)), against `main` with the first slice's export:

- **GPU.** With the room alone at 1996×1824 it costs +0.087 ms per frame (0.422 → 0.509). Behind the 7 characters it measured −0.047 ms, which is not explained. Scenes without a map are unchanged.
- **Import.** Scene ready, first draw and the main thread are unchanged. The worker's load takes 2.7–4.3 ms longer to hash and upload the lightmap blocks and to load the emission map.
- **Memory.** Metal grows by 4.2 MB: 2.8 MB of BC3 lightmaps (about 11.2 MB as RGBA8) and the 1.4 MB emission map.
- **Base M1 (estimate).** About +0.4 ms per frame for the room filling the window, +4–5 ms of worker load and +4.2 MB.

Slice 3 (map 34, the sky and block images), Release, in one quiet window ([performance: slice 3](../performance.md#slice-3-map-34-the-sky-and-block-images)). The comparison is against `main` (`4d60b73`), whose binary decodes the PNGs:

- **GPU.** Map 34 with its sky takes 0.483 ms per frame at 1996×1824, from the day and the evening camera; `main`'s binary, without the sky or particle formula, takes 0.552–0.559 ms. Anisotropy 9 costs less than the benchmark resolves: +0.005–0.007 ms on map 34 against trilinear map samplers, inside the ranges. Behind the 7 characters, map 33 costs +0.010 ms. Scenes without a map are unchanged.
- **Memory.** Metal falls by exactly the texture bytes: 46.3 MB for map 33, and 228.4 MB for map 34 against its decoded PNGs. Map 34's scene peaks at 221.6 MB of Metal instead of 449.4 MB.
- **Import.** Scene ready, the import call, the first draw and the main thread are unchanged. The worker's load falls from 97.7 to 12.7 ms in the showoff scene, and from 401 to 66 ms for map 34.
- **Base M1 (estimate).**
  - about 2.3 ms per frame for map 34 filling the window;
  - under 0.05 ms for anisotropy, the least certain estimate, since the M1 has about a twelfth of this machine's bandwidth;
  - 75–85 ms of worker load instead of about 0.5 s;
  - about 220 MB of peak Metal for map 34's scene instead of 450 MB.

## What remains

- **Light-probe-lit parts.** Map 34's 32 `Standard` renderers without a lightmap (17,701 triangles) are drawn as items. Unity lights them with light probes and the realtime sun. They cover 77,159, 72,567 and 92,296 of the 691,200 pixels in the day, evening and night views (11–13%), and none in the showoff view. Drawing them needs the scene's light probes (spherical harmonics per probe, and the tetrahedral interpolation) and the sun term below.
- **The realtime sun and its shadows.** Map 33's only map light, `Map/SunLight`, is realtime, and map 34's sun is too. Its term is `diffColor × light.color × diffuseTerm` with its soft shadows. Drawing it needs:
  - the sun as a scene light in the map's draws;
  - the `SunLightInfo` angle, colour and intensity per sun type;
  - a shadow map of the room.

  In map33 the phase-C oracle shows the sun adding up to 0.70 of irradiance on 15,692 pixels, where it comes through the windows (`irradianceLit`).
- **The rest of `Standard`.** Not drawn: specular and the reflection probe, normal maps, per-texel `_MetallicGlossMap` and detail maps.
- **Particles.** Soft particles (the fade where the cards meet geometry) and per-renderer sorting. Map 34's two particle renderers are one draw, so their blend order is the mesh's triangle order.
- **The sky's far plane.** The player's main camera clips at 1000 m, inside parts of map 34's sky spheres (about 450–1,200 m). Our infinite projection draws the whole sphere, so the full frame differs where the player shows black.
- **Fog and camera effects.** RenderSettings fog was off at runtime in every phase-C and map 34 scene. The per-sun-type fog of `SunLightInfo` and CharaStudio's camera image effects are not drawn.
- **Dropping the PNG copies.** Every map image is in the export twice, as PNG and as BC blocks. The PNGs are what `IKKOKU_SOURCE_MAP_DECODED_TEXTURES` and readers without block support use. Map 34's PNGs take 17 MB of the 88 MB export. The eager PNG read on the worker measured 1.7–2.9 ms, so the loader still reads them.
- **Forced anisotropy for characters and items.** The original forces anisotropy on every texture, character and item textures included. Only map textures sample that way here. Matching it elsewhere is a separate fidelity item with its own gates.
- **Maps beyond 33 and 34.** Every other `Map_XX` row stays `file: null` and is reported by name. A map whose lightmaps the converter cannot reproduce draws as items, with the reason recorded in `lightmapExport.problems`.
- **Mods.** Rows that mods add are not evaluated.
- **Character fidelity.** The showoff captures' character differences are the existing character-fidelity work, outside this slice.
