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

**Sampler.** The lightmaps are sampled with linear filtering, linear mips and clamp to edge. The original uses Bilinear with anisotropy 3, under `QualitySettings.anisotropicFiltering` ForceEnable. The difference shows only at grazing angles.

The base textures are still decoded to RGBA8 by `ResourceStore`. Native BC upload of those is the separate store change listed under [what remains](#what-remains).

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

Results, Release build of this change (`.local/sta11b-lightmaps/comparison.json`):

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

**Safe for `main` after the swap.** `main`'s binary with the slice-2 export is byte-identical to `main` with the first slice's export on all 6 map captures. Its log reports the same 52,248,576 texture bytes. `main`'s four map checks (`source-map`, `reload-save-source-map`, `reload-load-source-map`, `source-map-none`) passed 4/4 under `--strict` on its Debug build with the slice-2 export (`.local/sta11b-lightmaps/swap-proof/`). The one visible difference: `main`'s status line loses its `; shaders approximated (Standard)` suffix, because the new catalog row names the omitted terms instead. `main`'s checks assert the label prefix, which is unchanged.

**Suites.** The private-source Engine suite ran 1,008 tests: 987 passed and 20 were skipped. The 1 failure is the known `liveSourceShadersMeetTheControlledOriginalFrameGates`, which #277 did not change. The Python suites pass: `Tools/reverse` 589 (6 skipped), `Tools/reverse/analysis` 279 and `Tools/verification` 199. CI passed on the PR.

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

## What remains

- **Map 34 `空き教室` (`akikyoushitu`), and larger maps generally,** need two separate pieces of work.
  - (1) **Native BC upload in `ResourceStore`.** The converter would keep the bundle's DXT1/DXT5 blocks, and the store would upload them as BC1/BC3 instead of decoding to RGBA8. Base textures: map 33 is 51.7 MB as RGBA8 with mips against 7.2 MB as BC; map 34 is 265.3 MB against 39.8 MB.
  - (2) **The cubemap sky pass.** Map 34 draws its sky with `Skybox/Cubemap` on three meshes: `mo_koi_sky_hiru00`, `mo_koi_sky_yo00` and `mo_koi_sky_yu00`. They use Unity's built-in `Sphere` (`unity default resources` path ID 10207), which is not in the bundle. The converter currently skips skybox-shader submeshes and lists them under `skipped`.

  Map 34 also has 58 merged draws, `Particles/Alpha Blended` materials and a reflection probe. Every other `Map_XX` row stays `file: null` and is reported by name.
- **The realtime sun and its shadows.** Map 33's only map light, `Map/SunLight`, is realtime. Its term is `diffColor × light.color × diffuseTerm` with its soft shadows. Drawing it needs:
  - the sun as a scene light in the map's draws;
  - the `SunLightInfo` angle, colour and intensity per sun type;
  - a shadow map of the room.

  In map33 the phase-C oracle shows the sun adding up to 0.70 of irradiance on 15,692 pixels, where it comes through the windows (`irradianceLit`).
- **The rest of `Standard`.** Not drawn: specular and the reflection probe, normal maps, per-texel `_MetallicGlossMap` and detail maps.
- **Fog and camera effects.** RenderSettings fog was off at runtime in both phase-C scenes. The per-sun-type fog of `SunLightInfo` and CharaStudio's camera image effects are not drawn.
- **Native BC upload of the base textures.** This slice uploads only the lightmaps as BC3, outside `ResourceStore`. The base textures still decode to RGBA8: item (1) above.
- **Lightmapped maps beyond 33.** A map whose lightmaps the converter cannot reproduce draws as items, with the reason recorded in `lightmapExport.problems`. Map 34's lightmaps have not been inspected.
- **Mods.** Rows that mods add are not evaluated.
- **Character fidelity.** The showoff capture's character differences are the existing character-fidelity work, outside this slice.
